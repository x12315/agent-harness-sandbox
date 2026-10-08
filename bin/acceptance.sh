#!/usr/bin/env bash
# 从零跑一遍完整流程并留档：构建镜像 + 全部用例。
#
#   ssh alpha 'bash ~/agent-harness-sandbox/bin/acceptance.sh' | tee acceptance.log
#
# 前置：Mac 侧先 bin/sync.sh；本脚本假设 ~/ahsb-build 已经被删掉（真从零）。
set -uo pipefail
cd "$(dirname "$0")/.."

# 用法：
#   bin/acceptance.sh                     # 全套
#   bin/acceptance.sh claude-turn pi-turn # 只跑这几条（迭代时用这个，快得多）
#   SKIP_BUILD=1 bin/acceptance.sh ...    # 跳过镜像构建（镜像/配置没变时）
#   PRIVDROP=1 bin/acceptance.sh          # 零特权跑法（推荐）
ALL_CASES="claude-turn pi-turn agents-md-honored agents-md-ignored overwrite-bin-bash disk-fill port-scan out-of-band-monitor"
if [ "$#" -gt 0 ]; then CASES="$*"; else CASES="$ALL_CASES"; fi

ts() { date -u +%H:%M:%S; }
OUT=${OUT:-$HOME/ahsb-build}
# 证据要落在同步树之外：bin/sync.sh 是整目录替换，会把 cases/*/ 下的产物抹掉。
# （上一轮审计就撞到过这件事：只能看到 /tmp 里的日志，没法逐条复核。）
mkdir -p "$OUT/evidence"
EVID=$(mktemp -d "$OUT/evidence/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")

# PRIVDROP=1：把整条测试路径套进 setpriv --no-new-privs。
# 这个标志一旦设上，连 sudo 自己都拒绝以 root 运行（实测报
# "no new privileges ... prevents sudo from running as root"），
# 于是"测试路径不需要特权"就从"我们没写 sudo"升级成"结构上提不了权"。
if [ "${PRIVDROP:-0}" = 1 ]; then
    RUNNER=(setpriv --no-new-privs)
    echo "（PRIVDROP=1：全程 NoNewPrivs，qemu 也用同一套能力限制）"
else
    RUNNER=()
fi

echo "=== 环境 ==="
date -u +%FT%TZ
echo "host: $(uname -r)  user: $(id -un)  uid: $(id -u)  groups: $(id -Gn)"
echo "systemd: $(systemctl --version | head -1)"
echo "能力集: $(grep -E '^Cap(Eff|Prm|Amb)' /proc/self/status | tr '\n' ' ')"
if [ "${PRIVDROP:-0}" = 1 ]; then echo "每条用例: setpriv --no-new-privs（连 sudo 都拒绝以 root 运行）"; fi
echo "镜像目录是否存在（应为空/不存在）: $(ls -d ~/ahsb-build 2>&1)"

echo
echo "=== 1. golden 镜像 ==="
if [ "${SKIP_BUILD:-0}" = 1 ]; then
    echo "[$(ts)] SKIP_BUILD=1：跳过构建，复用现有镜像"
    sed 's/^/    /' "$OUT/SHA256SUMS" 2>/dev/null | head -4
else
    echo "[$(ts)] 开始构建（--force 重建；约数分钟，是整轮里最慢的一步）"
    bash bin/build-image.sh || { echo "BUILD FAILED"; exit 1; }
    echo "[$(ts)] 构建完成"
fi

echo
echo "=== 2. 逐条用例 ==="
fail=0
for c in $CASES; do
    RUN_DIR="$OUT/runs/$c/$(basename "$EVID")"
    echo "----- $c -----"
    case_start=$(date +%s)
    RUN_DIR="$RUN_DIR" "${RUNNER[@]}" bash bin/run-case.sh "$c" || { echo "CASE FAILED: $c"; fail=1; }
    # 把这条用例的关键证据抄一份到不会被同步抹掉的地方
    mkdir -p "$EVID/$c"
    for f in assert.txt console.txt mock-requests.jsonl window.txt post.txt monitor.txt vm.log source.sha256; do
        [ -f "$RUN_DIR/$f" ] && cp "$RUN_DIR/$f" "$EVID/$c/"
    done
    [ -d "$RUN_DIR/guest" ] && cp -a "$RUN_DIR/guest" "$EVID/$c/" 2>/dev/null || true
    echo "      [$c] 用时 $(( $(date +%s) - case_start )) 秒"
done

echo
cp "$OUT/SHA256SUMS" "$EVID/" 2>/dev/null || true
echo "证据目录（不会被同步抹掉）: $EVID"

echo "=== 结论 ==="
if [ "$fail" = 0 ]; then echo "ALL CASES PASS"; else echo "SOME CASES FAILED"; fi
exit "$fail"
