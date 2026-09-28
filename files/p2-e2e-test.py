#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
p2-e2e-test.py —— mall-swarm 端到端链路验证（可重复执行）

它做的事：从网关入口开始，把 P2 真正用到的中间件逐个"用业务动作打一遍"，
而不是只看端口通不通。任何一件中间件挂了都会在这里暴露出来。

覆盖：
    Nacos   服务发现 / 配置中心      —— 通过各模块的 /actuator/health
    MySQL   读写                     —— 登录查用户、商品列表、下单写订单
    Redis   sa-token 会话            —— 会员登录后拿 token 调受保护接口
    MongoDB 读写                     —— 创建浏览记录、读购物车
    RabbitMQ 延迟队列                —— 下单后 mall.order.cancel.ttl 出现消息
    ES+IK   中文分词检索             —— importAll 后按中文关键词搜索

用法：
    python tools/p2-e2e-test.py
    python tools/p2-e2e-test.py --gateway http://127.0.0.1:8201

退出码：0 = 全部通过；非 0 = 有失败项（数量 = 失败数）。
"""

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------- 基础设施

GW = "http://127.0.0.1:8201"
ES = "http://127.0.0.1:9200"
NACOS = "http://127.0.0.1:8848"
RABBIT_CTL = None  # 由 --rabbit-ctl 指定；不给就跳过队列深度检查

ADMIN_USER, ADMIN_PASS, ADMIN_CLIENT = "macro", "macro123", "admin-app"
MEMBER_USER, MEMBER_PASS = "test", "123456"

_results = []


def record(name, ok, detail=""):
    _results.append((name, ok, detail))
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}" + (f"  -- {detail}" if detail else ""))
    return ok


def http(url, data=None, headers=None, method=None, timeout=25):
    """返回 (status, body)。body 尝试按 JSON 解析，失败则给原始字符串。"""
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        status = e.code
    except Exception as e:
        return None, str(e)
    try:
        return status, json.loads(raw)
    except Exception:
        return status, raw


def login_admin():
    q = urllib.parse.urlencode(
        {"clientId": ADMIN_CLIENT, "username": ADMIN_USER, "password": ADMIN_PASS})
    st, d = http(f"{GW}/mall-auth/auth/login?{q}", method="POST")
    if not isinstance(d, dict):
        return None
    data = d.get("data") or {}
    return data.get("token"), data.get("tokenHead", "Bearer ")


def login_member():
    q = urllib.parse.urlencode({"username": MEMBER_USER, "password": MEMBER_PASS})
    st, d = http(f"{GW}/mall-portal/sso/login?{q}", method="POST")
    if not isinstance(d, dict):
        return None
    data = d.get("data") or {}
    return data.get("token"), data.get("tokenHead", "Bearer ")


# ---------------------------------------------------------------- 各项检查

def auth_header(token, head):
    """sa-token 的 tokenHead 是 'Bearer '（自带一个尾空格），
    直接 f"{head} {token}" 会拼出 'Bearer  <token>' 两个空格，
    服务端解析不出来 → 401。必须 strip 之后再拼一个空格。"""
    return {"Authorization": f"{(head or 'Bearer').strip()} {token}"}


def check_health():
    """Nacos 服务发现 + 各模块启动状态。"""
    print("\n== 1. 模块健康（Nacos 服务发现）==")
    mods = {
        "mall-gateway": 8201, "mall-admin": 8080, "mall-auth": 8401,
        "mall-portal": 8085, "mall-search": 8081, "mall-demo": 8082,
        "mall-monitor": 8101,
    }
    up = 0
    for name, port in mods.items():
        st, d = http(f"http://127.0.0.1:{port}/actuator/health", timeout=8)
        status = (d or {}).get("status") if isinstance(d, dict) else None
        if status == "UP":
            up += 1
        detail = ""
        if status != "UP":
            if isinstance(d, dict):
                bad = [k for k, v in (d.get("components") or {}).items()
                       if v.get("status") != "UP"]
                detail = "组件异常: " + ", ".join(bad) if bad else str(d)[:80]
            else:
                detail = str(d)[:80]
        record(f"{name} ({port})", status == "UP", detail)
    record("7 个模块全部 UP", up == len(mods), f"{up}/{len(mods)}")


def check_nacos_registry():
    print("\n== 2. Nacos 注册表 ==")
    st, d = http(f"{NACOS}/nacos/v1/ns/service/list?pageNo=1&pageSize=20", timeout=8)
    doms = sorted((d or {}).get("doms") or []) if isinstance(d, dict) else []
    record("注册的服务数 = 7", len(doms) == 7, ", ".join(doms))


def check_admin_chain():
    """网关 → auth → Feign → admin → MySQL → RBAC"""
    print("\n== 3. 管理端链路（网关 → auth → Feign → admin → MySQL）==")
    tok = login_admin()
    if not tok or not tok[0]:
        record("admin 登录", False, "未拿到 token")
        return None
    token, head = tok
    record("admin 登录（mall-auth + Feign + MySQL）", True, f"token 长度 {len(token)}")

    st, d = http(f"{GW}/mall-admin/product/list?pageNum=1&pageSize=3",
                 headers=auth_header(token, head))
    ok = isinstance(d, dict) and d.get("code") == 200
    total = ((d or {}).get("data") or {}).get("total") if isinstance(d, dict) else None
    record("admin 查商品列表（sa-token + RBAC + MyBatis）", ok, f"total={total}")

    # 无 token 应被拒
    st, d = http(f"{GW}/mall-admin/product/list?pageNum=1&pageSize=3")
    code = (d or {}).get("code") if isinstance(d, dict) else None
    record("无 token 被拦截", code == 401, f"code={code}")
    return token


def check_search():
    """search → ES + IK 中文分词"""
    print("\n== 4. 搜索链路（mall-search → Elasticsearch + IK）==")
    tok = login_admin()
    if not tok or not tok[0]:
        record("search 需要 admin token", False, "未拿到 token")
        return
    token, head = tok
    auth = auth_header(token, head)

    st, d = http(f"{GW}/mall-search/esProduct/importAll", headers=auth, method="POST", timeout=90)
    ok = isinstance(d, dict) and d.get("code") == 200
    record("importAll（MySQL → ES）", ok, f"导入 {((d or {}).get('data'))} 条")

    st, d = http(f"{GW}/mall-search/esProduct/search?"
                 + urllib.parse.urlencode({"keyword": "小米", "pageNum": 1, "pageSize": 5}),
                 headers=auth, timeout=30)
    data = (d or {}).get("data") or {} if isinstance(d, dict) else {}
    hits = data.get("total")
    record("中文检索『小米』（IK 分词）", isinstance(hits, int) and hits > 0, f"命中 {hits} 条")

    # ES 侧直接确认插件
    st, d = http(f"{ES}/_cat/plugins?format=json", timeout=8)
    names = [p.get("component") for p in d] if isinstance(d, list) else []
    record("ES 插件 analysis-ik 已加载", "analysis-ik" in names, ", ".join(names))


def check_portal_chain():
    """portal → MySQL / Redis / MongoDB"""
    print("\n== 5. 用户端链路（mall-portal → MySQL / Redis / MongoDB）==")
    tok = login_member()
    if not tok or not tok[0]:
        record("会员登录", False, "未拿到 token")
        return None
    token, head = tok
    record("会员登录（Redis 存 sa-token 会话）", True, f"token 长度 {len(token)}")
    auth = auth_header(token, head)

    st, d = http(f"{GW}/mall-portal/sso/info", headers=auth)
    ok = isinstance(d, dict) and d.get("code") == 200
    record("查会员信息（sa-token 鉴权）", ok)

    st, d = http(f"{GW}/mall-portal/product/search?"
                 + urllib.parse.urlencode({"keyword": "小米", "pageNum": 1, "pageSize": 3}))
    hits = ((d or {}).get("data") or {}).get("total") if isinstance(d, dict) else None
    record("portal 商品搜索（MySQL）", isinstance(hits, int), f"命中 {hits} 条")

    # MongoDB 写
    st, d = http(f"{GW}/mall-portal/member/readHistory/create", headers=auth,
                 data={"productId": 27, "productName": "端到端测试-小米8",
                       "productPic": "http://example.com/x.jpg", "productPrice": 2599.0,
                       "productSubTitle": "e2e-test", "productSn": "7437788"},
                 method="POST")
    ok = isinstance(d, dict) and d.get("code") == 200
    record("写浏览记录（MongoDB）", ok, str((d or {}).get("data")))

    st, d = http(f"{GW}/mall-portal/cart/list", headers=auth)
    ok = isinstance(d, dict) and d.get("code") == 200
    record("读购物车（MySQL）", ok)

    st, d = http(f"{GW}/mall-portal/member/readHistory/list?"
                 + urllib.parse.urlencode({"pageNum": 1, "pageSize": 5}), headers=auth)
    n = len(((d or {}).get("data") or {}).get("list") or []) if isinstance(d, dict) else 0
    record("读浏览记录（MongoDB 回读）", n > 0, f"{n} 条")
    return token, head


def check_rabbitmq_after_order():
    """下单 → RabbitMQ 延迟队列出现消息"""
    print("\n== 6. 下单链路（MySQL 写订单 + RabbitMQ 延迟消息）==")
    if not RABBIT_CTL:
        print("  [SKIP] 未提供 --rabbit-ctl，跳过队列深度检查")
        return
    tok = login_member()
    if not tok or not tok[0]:
        record("下单需要会员 token", False)
        return
    token, head = tok
    auth = auth_header(token, head)

    before = rabbit_queue_depth("mall.order.cancel.ttl")
    record("读队列 mall.order.cancel.ttl 基线", before is not None, f"{before} 条")
    if before is None:
        return

    # 先加一条带价格的购物车（/cart/add 不会自己算价格）
    st, d = http(f"{GW}/mall-portal/cart/add", headers=auth,
                 data={"productId": 27, "productSkuId": 98, "quantity": 1,
                       "price": 2699.00, "productName": "端到端测试-小米8",
                       "productPic": "http://example.com/x.jpg", "productSubTitle": "e2e",
                       "productSn": "7437788", "productCategoryId": 19,
                       "productBrand": "小米",
                       "productAttr": '[{"key":"颜色","value":"黑色"}]'},
                 method="POST")
    record("加入购物车", isinstance(d, dict) and d.get("code") == 200)

    st, d = http(f"{GW}/mall-portal/cart/list", headers=auth)
    items = ((d or {}).get("data") or []) if isinstance(d, dict) else []
    if not items:
        record("购物车非空", False, "拿不到购物车项")
        return
    # 取 id 最大的那条 = 刚加进去的。
    # ⚠️ 不能用 items[-1]：购物车里可能有历史遗留的脏行（price 为 NULL），
    #    拿到那种行会让 generateConfirmOrder 在算钱时 NPE。
    newest = max(items, key=lambda x: x.get("id") or 0)
    cart_ids = [newest.get("id")]
    if newest.get("price") in (None, ""):
        record("刚加入的购物车行带价格", False,
               f"id={newest.get('id')} price 为空 —— /cart/add 不会自动算价，必须显式传 price")
        return
    record("购物车非空", True, f"cartIds={cart_ids} price={newest.get('price')}")

    st, d = http(f"{GW}/mall-portal/order/generateConfirmOrder", headers=auth,
                 data=cart_ids, method="POST")
    ok = isinstance(d, dict) and d.get("code") == 200
    amount = ((d or {}).get("data") or {}).get("calcAmount") if isinstance(d, dict) else None
    record("生成订单确认（算钱）", ok, f"calcAmount={amount}")
    if not ok:
        return

    st, d = http(f"{GW}/mall-portal/order/generateOrder", headers=auth,
                 data={"memberReceiveAddressId": 4, "useIntegration": 0,
                       "payType": 1, "cartIds": cart_ids}, method="POST")
    ok = isinstance(d, dict) and d.get("code") == 200
    order = ((d or {}).get("data") or {}).get("order") or {} if isinstance(d, dict) else {}
    record("下单（写 oms_order）", ok,
           f"orderId={order.get('id')} orderSn={order.get('orderSn')} "
           f"msg={(d or {}).get('message') if isinstance(d, dict) else ''}")

    after = rabbit_queue_depth("mall.order.cancel.ttl")
    record("延迟消息进入 mall.order.cancel.ttl", after is not None and after > before,
           f"{before} → {after}")


def rabbit_queue_depth(queue):
    """用 run-rabbitmq.cmd ctl 读队列深度。返回 int 或 None。"""
    import subprocess
    try:
        out = subprocess.run(
            RABBIT_CTL + ["ctl", "list_queues", "-p", "/mall", "name", "messages"],
            capture_output=True, text=True, timeout=60,
            env={**__import__("os").environ, "MSYS_NO_PATHCONV": "1"},
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == queue:
            try:
                return int(parts[1])
            except ValueError:
                return None
    return None


# ---------------------------------------------------------------- 入口

def main():
    global GW, RABBIT_CTL
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", default=GW)
    ap.add_argument("--rabbit-ctl", default=None,
                    help="run-rabbitmq.cmd 的路径（给了才检查队列深度）")
    a = ap.parse_args()
    GW = a.gateway
    if a.rabbit_ctl:
        RABBIT_CTL = [a.rabbit_ctl]

    print("=" * 66)
    print(" mall-swarm 端到端验证")
    print(f" 网关: {GW}")
    print("=" * 66)

    check_health()
    check_nacos_registry()
    check_admin_chain()
    check_search()
    check_portal_chain()
    check_rabbitmq_after_order()

    fails = [n for n, ok, _ in _results if not ok]
    print("\n" + "=" * 66)
    print(f" 合计 {len(_results)} 项，通过 {len(_results) - len(fails)}，失败 {len(fails)}")
    if fails:
        print(" 失败项：")
        for n in fails:
            print(f"   - {n}")
    print("=" * 66)
    return len(fails)


if __name__ == "__main__":
    sys.exit(main())
