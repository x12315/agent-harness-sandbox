#!/usr/bin/env bash
# 带外验证：把 guest 打到内核 panic，再从 QEMU monitor 拿现场。
#
# monitor 既不在 guest 里、也不依赖 guest：vmspawn 用 --console=native 起 QEMU 时
# 是 -nographic，QEMU 的 monitor 多路复用在这同一个 console 上，Ctrl-A c 切过去即可。
# 串口 console 上的 getty 做不到这点 —— 它依赖 guest 里的 systemd。
set -euo pipefail
D=${1:?}
SES=${SES:?}
M=$D/monitor.txt
tx() { tmux -L ahsb "$@"; }
: >"$M"

echo "--- 1. 让 guest 内核 panic"
tx send-keys -t "$SES" -l -- "echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger"
tx send-keys -t "$SES" Enter
seen=0
for _ in $(seq 1 40); do
    tx capture-pane -pJ -S - -t "$SES" >"$M"
    if grep -qiE 'Kernel panic' "$M" || grep -qiE 'Kernel panic' "$D/vm.log" 2>/dev/null; then
        seen=1; break
    fi
    sleep 1
done
[ "$seen" = 1 ] || { echo "FAIL: 40 秒内没等到 guest panic" >&2; tail -5 "$M" >&2; exit 1; }
cat "$D/vm.log" >>"$M" 2>/dev/null || true
echo "ok ①: guest 内核 panic（串口上只剩 panic 现场）"

echo "--- 2. Ctrl-A c 切到 QEMU monitor，问现场"
tx send-keys -t "$SES" C-a c
sleep 2
tx send-keys -t "$SES" -l -- "info status"; tx send-keys -t "$SES" Enter; sleep 1
tx send-keys -t "$SES" -l -- "info cpus";   tx send-keys -t "$SES" Enter; sleep 2
tx capture-pane -pJ -S - -t "$SES" >>"$M"
grep -qE 'VM status: running' "$M" || { echo "FAIL: monitor 没有应答 info status" >&2; tail -6 "$M" >&2; exit 1; }
grep -qE '\* CPU #0' "$M" || { echo "FAIL: monitor 没有列出 CPU" >&2; tail -6 "$M" >&2; exit 1; }
echo "ok ②: guest 已死，QEMU monitor 仍然应答（带外通道成立）"

echo "--- 3. 用 monitor 结束 VM（不依赖 guest 内任何东西）"
tx send-keys -t "$SES" -l -- "quit"; tx send-keys -t "$SES" Enter
sleep 2
echo "ok ③: 由 monitor 结束 VM"
