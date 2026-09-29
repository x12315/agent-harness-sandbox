#!/usr/bin/env bash
# 断言带外通道真的存在：guest 内核 panic 之后，QEMU monitor 仍能给出状态。
set -euo pipefail
D=${1:?usage: assert.sh <case-dir>}
M=$D/monitor.txt

[ -s "$M" ] || { echo "FAIL: 没有 monitor.txt"; exit 1; }
grep -qiE 'Kernel panic' "$M" || { echo "FAIL: 没有 guest panic 的证据"; exit 1; }
echo "ok ①: guest 确实被搞死了（内核实录 panic）"

grep -qE 'VM status: running' "$M" || { echo "FAIL: monitor 没应答 info status"; exit 1; }
grep -qE '\* CPU #0' "$M" || { echo "FAIL: monitor 没列出 CPU"; exit 1; }
echo "ok ②: monitor 在 guest 死后仍给出 VM 状态与 CPU 列表"

grep -q 'case-done' "$D/guest/tmp/ah.out" || { echo "FAIL: 常规通道没跑通"; exit 1; }
echo "ok ③: 常规通道（串口回传产物）也在同一次运行里正常工作"
