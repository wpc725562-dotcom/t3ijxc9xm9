#!/usr/bin/env bash
# =============================================================================
#  svc.sh —— 便携版 MySQL / Redis 启停（Git Bash 转发壳）
#  -----------------------------------------------------------------------------
#  真正的实现在同目录的 svc.cmd 里。
#  为什么用 cmd 做实现、bash 只做转发：
#    Git Bash 在把参数传给原生 Windows 程序时会做「路径自动转换」，
#    像 /min、/D 这种开关会被它当成路径改写成 C:/Program Files/... 之类，
#    启动命令直接失败，而且报错信息完全看不出是路径转换干的。
#    把进程启动那段逻辑放在 .cmd 里执行，就绕开了整个问题。
#
#  用法（**直接执行**，不需要 source —— 它不改环境变量）：
#     ./svc.sh init                 首次初始化（建数据目录 / 设密码 / 建库）
#     ./svc.sh start [target]       target 见下
#     ./svc.sh stop  [target]
#     ./svc.sh restart [target]
#     ./svc.sh status               一次看 8 个服务的监听状态
#     ./svc.sh cli mysql8           交互式客户端（mysql8 / mysql57 / redis / mongodb）
#     ./svc.sh logs mysql8          实时跟日志
#
#     target 可选值：
#       单个服务  mysql8 | mysql57 | redis | nacos | mongodb
#                 | elasticsearch | rabbitmq | minio
#       all       mysql8 + mysql57 + redis                （P0/P1 用，快）
#       full      all + nacos + mongodb + elasticsearch
#                     + rabbitmq + minio                 （P2 用，约 60 秒）
#
#  本脚本是**通用转发壳**：参数原样透传给 svc.cmd，
#  所以新增服务时只需要改 svc.cmd，这里不用动。
# =============================================================================

set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_WIN="$(cygpath -w "$WS/svc.cmd" 2>/dev/null || echo "D:\\java-workspace\\svc.cmd")"

if [ ! -f "$WS/svc.cmd" ]; then
  printf '\033[31m[错误]\033[0m 找不到 svc.cmd（预期在 %s）\n' "$WS" >&2
  exit 1
fi

action="${1:-}"

# -----------------------------------------------------------------------------
#  这两类动作必须直连，不能走下面的临时文件中转：
#    logs —— 要实时流式跟日志，缓冲住就失去意义了
#    cli  —— 交互式会话，输出必须立刻可见
#    （无参数）—— 只打印用法，没必要绕
# -----------------------------------------------------------------------------
case "$action" in
  logs|log|cli|'')
    # cmd //c 里的双斜杠是必须的：单斜杠会被 Git Bash 改写成 C:/...
    cmd //c "$CMD_WIN" "$@"
    exit $?
    ;;
esac

# -----------------------------------------------------------------------------
#  为什么要绕一层临时文件
#  ---------------------------------------------------------------------------
#  svc.cmd 用 `start` 拉起 mysqld / redis-server。`start` 创建子进程时用的是
#  bInheritHandles = TRUE，也就是子进程会**继承父进程整张可继承句柄表** ——
#  包括 stdout 那个句柄。
#
#  于是：如果调用方把我们的输出接进了管道（`./svc.sh init | tail`），
#  守护进程就会一直握着那个管道的写端。管道读端要等所有写端关闭才 EOF，
#  而守护进程不会退出 ⇒ 命令看起来「卡死」，
#  可实际上三个服务全都起来了、建库脚本也跑完了（日志里写得清清楚楚）。
#
#  ★ 在 start 那一行上写 `>nul 2>&1` 是**没用的** ——
#    重定向只改 cmd 自己的 std handle，句柄表里的那个条目照样被继承。
#    实测过：重定向到文件正常，接到管道就挂，差别就在这里。
#
#  解决办法：让 cmd 的 stdout 指向一个**普通文件**而不是管道。
#  一个文件句柄被多方持有不会阻塞任何人；cmd 退出后 svc.sh 再把内容
#  打到真正的 stdout，管道随之正常关闭。
#
#  代价：输出不再是实时的（对 init/start/stop/status 完全无所谓）。
#  需要实时的 logs / cli 已经在上面单独放行了。
# -----------------------------------------------------------------------------
tmp="$(mktemp 2>/dev/null || echo "/tmp/svc-sh-$$.out")"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT INT TERM

cmd //c "$CMD_WIN" "$@" >"$tmp" 2>&1
rc=$?
cat "$tmp"
exit $rc
