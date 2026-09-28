#!/usr/bin/env bash
# =============================================================================
#  p2.sh —— mall-swarm（P2）模块的构建 / 启停 / 体检
#  -----------------------------------------------------------------------------
#  为什么单独写一个脚本，而不是直接用 mvn + java -jar：
#
#  ① 构建必须加 -Ddocker.skip=true
#     根 pom 的 <pluginManagement> 把 fabric8 docker-maven-plugin 绑到了 package
#     阶段，而 <docker.host> 写死成原作者的内网地址 http://192.168.3.101:2375。
#     9 个模块里有 6 个（admin/auth/gateway/monitor/portal/search）声明了这个插件，
#     所以不加开关就必然在 package 阶段失败：
#
#         [ERROR] DOCKER> Cannot create docker access object [192.168.3.101:2375 failed to respond]
#
#     这个报错和「构建」本身毫无关系，很容易被误判成代码问题。
#
#  ② 启动必须清掉宿主注入的 SERVER__PORT / SERVER__HOST
#     WorkBuddy 会往它启动的每个子进程里塞这两个变量（值是它自己的后端端口），
#     Spring Boot 的松散绑定会把 SERVER__PORT 当成 server.port 读走，
#     于是模块会去抢宿主端口并以 PortInUseException 死掉。
#     use-jdk.sh 已经负责 unset，这里只要求经过它。
#
#  ③ 启动必须加 --spring.cloud.nacos.discovery.ip=127.0.0.1
#     不加的话 Nacos 客户端会挑本机的物理网卡地址注册。多网卡 / 有虚拟网卡
#     （Docker、VMware、VPN）时挑中的地址可能互不可达，
#     表现是服务注册成功、但 Feign 调用超时。本地全套统一走回环最稳。
#
#  ④ 每个模块的 stdout 落到 logs/p2-<模块>.log
#     不落盘的话，进程被 nohup 接管后日志就进了黑洞，出问题只能靠猜。
#
#  用法（**直接执行**，不需要 source）：
#     ./p2.sh build                 干净构建全部 9 个模块（约 30 秒）
#     ./p2.sh start                 启动全部 7 个可运行模块
#     ./p2.sh start gateway admin   只启动指定的（可写短名）
#     ./p2.sh stop                  全部停止
#     ./p2.sh stop portal           只停一个
#     ./p2.sh status                端口监听状态
#     ./p2.sh health                逐个打 /actuator/health
#     ./p2.sh logs admin            实时跟某个模块的日志
#
#  短名映射：gateway / admin / auth / portal / search / demo / monitor
# =============================================================================

set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM="$WS/p2-mall-swarm"
LOGDIR="$WS/logs"
PIDDIR="$WS/logs"

# 模块定义：短名|目录名|端口|说明
# 顺序 = 建议的启动顺序（gateway 先起，其余按被依赖程度排）
MODULES=(
  "gateway|mall-gateway|8201|入口网关"
  "admin|mall-admin|8080|管理后台（被 auth 通过 Feign 调用）"
  "auth|mall-auth|8401|认证中心（依赖 admin/portal）"
  "portal|mall-portal|8085|用户端（MySQL+Redis+MongoDB+RabbitMQ）"
  "search|mall-search|8081|搜索（MySQL+Redis+ES）"
  "demo|mall-demo|8082|演示模块（可选）"
  "monitor|mall-monitor|8101|监控台（可选）"
)

# -----------------------------------------------------------------------------
#  小工具
# -----------------------------------------------------------------------------
die() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }

# 短名 -> "目录名 端口 说明"
resolve() {
  local want="$1" e
  for e in "${MODULES[@]}"; do
    if [ "${e%%|*}" = "$want" ]; then printf '%s' "$e"; return 0; fi
  done
  return 1
}

# 某个端口上是否有进程在监听，有则回显 PID
port_pid() {
  local port="$1" line
  line="$(netstat -ano 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -i 'LISTENING' | head -1)"
  [ -z "$line" ] && return 1
  printf '%s' "$line" | awk '{print $NF}'
}

# 准备 JDK 17 环境（use-jdk.sh 会顺带 unset SERVER__PORT / SERVER__HOST）
load_jdk() {
  # shellcheck disable=SC1091
  source "$WS/use-jdk.sh" 17 >/dev/null 2>&1 || die "无法加载 use-jdk.sh（需要 JDK 17）"
  [ -n "${JAVA_HOME:-}" ] || die "JAVA_HOME 未设置"
}

# -----------------------------------------------------------------------------
#  build
# -----------------------------------------------------------------------------
do_build() {
  load_jdk
  [ -d "$SWARM" ] || die "找不到 $SWARM"
  printf '构建 mall-swarm（-DskipTests -Ddocker.skip=true）...\n'
  ( cd "$SWARM" && mvn -DskipTests -B -Ddocker.skip=true clean install ) \
    || die "构建失败，完整日志见 $SWARM 输出"
  ok "构建完成：9 个模块全部 SUCCESS"
}

# -----------------------------------------------------------------------------
#  start
# -----------------------------------------------------------------------------
start_one() {
  local short="$1" entry dir port desc
  entry="$(resolve "$short")" || { warn "不认识的模块 \"$short\"，跳过"; return 1; }
  IFS='|' read -r _ dir port desc <<< "$entry"

  local existing
  if existing="$(port_pid "$port")"; then
    warn "$short 已在运行（PID $existing，端口 $port），跳过"
    return 0
  fi

  local jar="$SWARM/$dir/target/$dir-1.0-SNAPSHOT.jar"
  [ -f "$jar" ] || { warn "$short 的 jar 不存在，先跑 ./p2.sh build"; return 1; }

  # 落到文件而不是管道：nohup 的进程会继承父进程句柄，
  # 接管道会让调用方看起来「卡住」（见 svc.sh 顶部同一段说明）。
  # 用裸 `java` 而不是 "$JAVA_HOME/bin/java"：JAVA_HOME 是 Windows 风格路径
  # （C:\Program Files\...），拼出来是混合路径；use-jdk.sh 已经把 JDK17 的
  # bin 放在 PATH 最前面，直接调 `java` 更稳。
  nohup java -jar "$jar" \
        --spring.cloud.nacos.discovery.ip=127.0.0.1 \
        >> "$LOGDIR/p2-$short.log" 2>&1 &

  printf '%s\n' "$!" > "$PIDDIR/p2-$short.pid"
  printf '  %-8s 端口 %-5s PID %-7s -> logs/p2-%s.log\n' "$short" "$port" "$!" "$short"
  return 0
}

do_start() {
  load_jdk
  local targets=("$@")
  [ ${#targets[@]} -eq 0 ] && targets=(gateway admin auth portal search demo monitor)

  # 清掉上一轮的日志，避免新旧混在一起看不出是哪次的
  local short
  for short in "${targets[@]}"; do
    : > "$LOGDIR/p2-$short.log" 2>/dev/null || true
  done

  printf '启动 mall-swarm 模块：\n'
  for short in "${targets[@]}"; do
    start_one "$short"
  done

  printf '\n等待端口就绪（最多 90 秒）...\n'
  local waited=0 ready
  while [ "$waited" -lt 90 ]; do
    ready=0
    for short in "${targets[@]}"; do
      IFS='|' read -r _ _ port _ <<< "$(resolve "$short")"
      port_pid "$port" >/dev/null 2>&1 && ready=$((ready+1))
    done
    [ "$ready" -eq "${#targets[@]}" ] && break
    sleep 3; waited=$((waited+3))
  done

  printf '\n'
  do_status "${targets[@]}"
}

# -----------------------------------------------------------------------------
#  stop
# -----------------------------------------------------------------------------
stop_one() {
  local short="$1" entry dir port pid
  entry="$(resolve "$short")" || { warn "不认识的模块 \"$short\"，跳过"; return 1; }
  IFS='|' read -r _ dir port _ <<< "$entry"

  pid="$(port_pid "$port")" || { printf '  %-8s 未在运行\n' "$short"; return 0; }
  # taskkill 连带子进程一起收，避免留孤儿（用 /T 而不是只杀 PID）
  taskkill //PID "$pid" //T //F >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null
  printf '  %-8s 已停止（PID %s）\n' "$short" "$pid"
  rm -f "$PIDDIR/p2-$short.pid"
}

do_stop() {
  local targets=("$@")
  # 停止顺序反过来：先停上游调用方，再停被调用方，减少停止期间的无谓报错
  if [ ${#targets[@]} -eq 0 ]; then
    targets=(monitor demo search portal auth admin gateway)
  fi
  printf '停止 mall-swarm 模块：\n'
  local short
  for short in "${targets[@]}"; do stop_one "$short"; done
}

# -----------------------------------------------------------------------------
#  status / health
# -----------------------------------------------------------------------------
do_status() {
  local targets=("$@")
  [ ${#targets[@]} -eq 0 ] && targets=(gateway admin auth portal search demo monitor)
  printf '  %-10s %-6s %-12s %s\n' MODULE PORT STATUS NOTE
  printf '  %s\n' '--------------------------------------------------------------'
  local short entry port desc pid
  for short in "${targets[@]}"; do
    entry="$(resolve "$short")" || continue
    IFS='|' read -r _ _ port desc <<< "$entry"
    if pid="$(port_pid "$port")"; then
      printf '  %-10s %-6s \033[32m%-12s\033[0m PID %s\n' "$short" "$port" LISTENING "$pid"
    else
      printf '  %-10s %-6s \033[33m%-12s\033[0m %s\n' "$short" "$port" "-" "$desc"
    fi
  done
}

do_health() {
  local targets=("$@")
  [ ${#targets[@]} -eq 0 ] && targets=(gateway admin auth portal search demo monitor)
  printf '  %-10s %-6s %-8s %s\n' MODULE PORT HTTP BODY
  printf '  %s\n' '--------------------------------------------------------------'
  local short entry port body code
  for short in "${targets[@]}"; do
    entry="$(resolve "$short")" || continue
    IFS='|' read -r _ _ port _ <<< "$entry"
    body="$(curl -s --max-time 8 "http://127.0.0.1:$port/actuator/health" 2>/dev/null)"
    if [ -z "$body" ]; then
      printf '  %-10s %-6s %-8s %s\n' "$short" "$port" "-" "(无响应)"
    else
      code="$(printf '%s' "$body" | grep -o '"status":"[A-Z]*"' | head -1 | cut -d'"' -f4)"
      printf '  %-10s %-6s %-8s %s\n' "$short" "$port" "${code:-?}" \
        "$(printf '%s' "$body" | head -c 150)"
    fi
  done
}

# -----------------------------------------------------------------------------
#  logs
# -----------------------------------------------------------------------------
do_logs() {
  local short="${1:-}"
  [ -z "$short" ] && die "用法：./p2.sh logs <模块短名>"
  local f="$LOGDIR/p2-$short.log"
  [ -f "$f" ] || die "没有日志文件 $f"
  tail -f "$f"
}

# -----------------------------------------------------------------------------
#  入口
# -----------------------------------------------------------------------------
case "${1:-}" in
  build|b)              do_build ;;
  start|up|s)           shift; do_start "$@" ;;
  stop|down|t)          shift; do_stop "$@" ;;
  status|st|ps)         shift; do_status "$@" ;;
  health|h)             shift; do_health "$@" ;;
  logs|log|l)           shift; do_logs "$@" ;;
  ''|-h|--help|help)
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "不认识的参数 \"$1\"。可用：build | start | stop | status | health | logs"
    ;;
esac
