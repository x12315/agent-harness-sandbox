#!/usr/bin/env bash
# 一条用例的完整生命周期：起 VM → 等就绪 → 执行 → 收产物 → 销毁。
#
#   bin/run-case.sh <case-id> '<一行命令>'
#
# 定义在 cases/<case-id>/（cmd、可选的 assert.sh / post.sh / env）；
# 产物落在 $OUT/runs/<case-id>/<run-id>/（每次独立目录，不覆盖历史）：
#   command.txt          本次跑的命令
#   console.txt          串口全文（带外通道的原始记录，出问题先看这个）
#   vm.log               QEMU 的日志（stdbuf -oL 按行刷）
#   vm.pid               该用例的 systemd-vmspawn 进程号
#   guest/tmp/ah.out     被测命令的 stdout
#   guest/tmp/ah.err     被测命令的 stderr
#   guest/tmp/ah.rc      退出码
#   guest/root/**        guest 里 /root 下的状态（harness 自己的会话文件在这里）
#   mock-requests.jsonl  本次用例时间窗内 mock 收到的请求
#
# 为什么产物要绕串口回来：guest 没有网卡，也没挂宿主目录（--ephemeral 与 virtiofsd
# 在这里都用不了）。串口是唯一不依赖 guest 内部状态的通道，所以它既是带外抢救通道，
# 也是产物通道。内容用 tar+base64 走，避免终端折行把字节弄坏。
set -euo pipefail

TESTBED=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$HOME/ahsb-build}          # 镜像与 mock 的日志都放这里（在同步树之外）
MOCK_PORT=${MOCK_PORT:-18788}
MOCK_REQUESTS=${MOCK_REQUESTS:-$OUT/mock-requests.jsonl}
CPUS=${CPUS:-2}
RAM=${RAM:-2G}

CASE_ID=${1:?usage: run-case.sh <case-id> ['<一行命令>']}; shift
CASE_DIR=$TESTBED/cases/$CASE_ID

# 产物目录必须在同步树之外，而且必须在第一次使用之前定义：
# bin/sync.sh 是整目录替换，产物留在 cases/<id>/ 下会被同步连根删掉。
RUN_DIR=${RUN_DIR:-}

# 可选的 PUSH："src:dst src:dst"（src 相对仓库根或绝对路径）。
# 走串口分块送进去，所以**改夹具/任务文件不需要重建镜像** ——
# 以前挪一个文件要花两分钟构建，现在十几秒。
PUSH=${PUSH:-}

# 用例可以用一份 env 覆盖默认值（PUSH / CPUS / RAM 等）
# shellcheck disable=SC1091
[ -f "$CASE_DIR/env" ] && . "$CASE_DIR/env"

# 命令写在 cases/<id>/cmd 里（这样用例是被 git 管理的、可重跑的定义），
# 也可以临时用参数传，方便一次性调试。
CMD=${1:-}
if [ -z "$CMD" ]; then
    [ -f "$CASE_DIR/cmd" ] || { echo "缺命令：给参数，或写 $CASE_DIR/cmd" >&2; exit 2; }
    CMD=$(cat "$CASE_DIR/cmd")
fi

mkdir -p "$OUT/runs/$CASE_ID"
if [ -n "$RUN_DIR" ]; then
    mkdir -p "$(dirname "$RUN_DIR")"
    mkdir "$RUN_DIR" || { echo "run directory already exists or is unavailable: $RUN_DIR" >&2; exit 2; }
else
    RUN_DIR=$(mktemp -d "$OUT/runs/$CASE_ID/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
fi
mkdir -p "$RUN_DIR/guest"
printf '%s\n' "$CMD" >"$RUN_DIR/command.txt"
[ -z "${SOURCE_MANIFEST:-}" ] || cp "$SOURCE_MANIFEST" "$RUN_DIR/source.sha256"

VM="ahsb-${CASE_ID}-$(date +%s)-$$"
SES="ahsb-$CASE_ID-$$"
MARK="AH${$}"

# 自己一个 tmux server：不碰用户已有的会话，也能单独把 history-limit 抬高
# （产物靠串口回传，history 太小会把 base64 冲掉）。
tx() { tmux -L ahsb "$@"; }

# ── 1. mock 必须在宿主上听着：它是 guest 唯一能到达的地方 ────────────────────
if [ ! -f "$OUT/mock.pid" ] || ! kill -0 "$(cat "$OUT/mock.pid")" 2>/dev/null; then
    MOCK_PORT="$MOCK_PORT" MOCK_REQUESTS="$MOCK_REQUESTS" \
        nohup python3 "$TESTBED/mock/mock_llm.py" >"$OUT/mock.log" 2>&1 &
    echo $! >"$OUT/mock.pid"
    sleep 1
fi

# ── 2. 起 VM：systemd-vmspawn（目标要求的就是它） ─────────────────────────────
# monitor 用 --console=native 拿：vmspawn 会以 -nographic 起 QEMU，QEMU 的 monitor
# 就多路复用在这个 console 上，tmux 里发 Ctrl-A c 即可切过去（实测 (qemu) info status
# → VM status: running）。vmspawn 命令行里那个 charmonitor 是它自己的内部 QMP，与我们无关。
tx kill-session -t "$SES" 2>/dev/null || true
tx set-option -g history-limit 100000 2>/dev/null || true
tx new-session -d -s "$SES" -x 220 -y 50 \
    "echo \$\$ > $RUN_DIR/vm.pid; exec systemd-vmspawn --machine=$VM \
        --image=$OUT/ahsb.raw --image-format=raw \
        --linux=$OUT/ahsb.vmlinuz --initrd=$OUT/ahsb.initrd \
        --ephemeral --cpus=$CPUS --ram=$RAM \
        --console=native --register=no --pass-ssh-key=no \
        2>&1 | stdbuf -oL tee $RUN_DIR/vm.log"

# ── 3. 等就绪：串口上出现 shell 提示符 ───────────────────────────────────────
for _ in $(seq 1 90); do
    tx capture-pane -pt "$SES" 2>/dev/null | grep -q 'root@archlinux' && break
    sleep 1
done
if ! tx capture-pane -pt "$SES" 2>/dev/null | grep -q 'root@archlinux'; then
    echo "guest 没能起来，见 $RUN_DIR/vm.log 与 $RUN_DIR/console.txt" >&2
    tx capture-pane -pJ -S - -t "$SES" >"$RUN_DIR/console.txt" 2>/dev/null || true
    tx kill-session -t "$SES" 2>/dev/null || true
    exit 1
fi

# ── 4. 执行并把产物打成 base64 从串口送回来 ─────────────────────────────────
# harness 的 base URL 指向 guest 内的 loopback：那是 vsock shim 桥过来的宿主 mock。
PRELUDE="export ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT ANTHROPIC_API_KEY=mock-key"
PRELUDE="$PRELUDE OPENAI_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1 OPENAI_API_KEY=mock-key"
PRELUDE="$PRELUDE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
# 把文件推进 guest。串口是唯一通道，而 tty 规范模式的**单行上限是 4096 字节**，
# 所以 base64 必须分多行送（每块 3000 字符），最后再解码 —— 一次性送长行会被静默截断
# （踩过：6 KB 的夹具被切掉尾巴，哨兵正好在尾巴上，断言就报"夹具没被加载"）。
push_file() {
    local src=$1 dst=$2 f b64 chunk
    case "$src" in /*) f=$src ;; *) f=$TESTBED/$src ;; esac
    [ -f "$f" ] || { echo "PUSH 源文件不存在：$f" >&2; exit 2; }
    b64=$(base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n')
    local tmp=/tmp/.ah-push.b64
    tx send-keys -t "$SES" -l -- ": > $tmp"; tx send-keys -t "$SES" Enter; sleep 0.2
    while [ -n "$b64" ]; do
        chunk=${b64:0:3000}; b64=${b64:3000}
        tx send-keys -t "$SES" -l -- "printf '%s' '$chunk' >> $tmp"
        tx send-keys -t "$SES" Enter; sleep 0.15
    done
    tx send-keys -t "$SES" -l -- "mkdir -p \"$(dirname "$dst")\"; base64 -d $tmp > \"$dst\"; rm -f $tmp; echo PUSHED \$(wc -c < \"$dst\") bytes"
    tx send-keys -t "$SES" Enter; sleep 0.3
}

for spec in $PUSH; do
    push_file "${spec%%:*}" "${spec#*:}"
done

REMOTE="$PRELUDE; mkdir -p /work; cd /work; { $CMD ; } >/tmp/ah.out 2>/tmp/ah.err; echo \$? >/tmp/ah.rc;"
# 只把真实存在的路径交给 tar：harness 还没跑过时 ~/.claude 不存在，
# 而 tar 遇到不存在的成员会整个不产出归档（踩过，表现为 base64: No such file）。
REMOTE="$REMOTE cd /; F='tmp/ah.out tmp/ah.err tmp/ah.rc'; for p in root/.claude root/.claude.json root/.pi root/.codex; do [ -e \"\$p\" ] && F=\"\$F \$p\"; done; tar -czf /tmp/ah.tgz \$F;"
# 标记由 guest 自己生成：串口会把命令行原样回显，如果标记写在命令里，
# 回显本身就包含它，会让人误以为命令已经跑完（踩过两次）。
# 回显里是字面量 "\$R"，只有真正的输出里才是数字，正则天然区分得开。
REMOTE="$REMOTE R=\$RANDOM; echo ==M\$R==BEGIN==; base64 /tmp/ah.tgz; echo ==M\$R==END=="

# 用带小数的时钟：只用整秒会在边界上漏掉请求（踩过：请求落在 END 之后 0.5 秒）。
START=$(date +%s.%N)
tx send-keys -t "$SES" -l -- "$REMOTE"
tx send-keys -t "$SES" Enter

# 等结束标记时必须锁行首：命令行本身会被串口回显，里面就包含这个字符串，
# 不锁行首就会在命令还没跑完时就误判为完成（踩过）。
# 等结束标记。标记是 guest 现场生成的（正则只认数字），所以回显不会误命中。
for _ in $(seq 1 600); do
    tx capture-pane -pJ -S - -t "$SES" 2>/dev/null | grep -qE '^==M[0-9]+==END==' && break
    sleep 1
done
END=$(date +%s.%N)
printf 'start=%s end=%s\n' "$START" "$END" >"$RUN_DIR/window.txt"

# ── 5. 收产物 ───────────────────────────────────────────────────────────────
# -S - ：连回滚缓冲一起拓，否则大一点的 base64 会被冲掉。
tx capture-pane -pJ -S - -t "$SES" >"$RUN_DIR/console.txt"
if ! awk '/^==M[0-9]+==BEGIN==/{f=1;next} /^==M[0-9]+==END==/{f=0} f' "$RUN_DIR/console.txt" \
    | tr -d ' \t\r\n' | base64 -d >"$RUN_DIR/guest.tgz" 2>/dev/null; then
    echo "产物回传失败（解码不了），看 $RUN_DIR/console.txt" >&2
    tx kill-session -t "$SES" 2>/dev/null || true
    exit 1
fi
tar -xzf "$RUN_DIR/guest.tgz" -C "$RUN_DIR/guest"
rm -f "$RUN_DIR/guest.tgz"

if [ -f "$MOCK_REQUESTS" ]; then
    jq -c --argjson a "$START" --argjson b "$END" 'select(.ts >= $a and .ts <= $b)' \
        "$MOCK_REQUESTS" >"$RUN_DIR/mock-requests.jsonl" 2>"$RUN_DIR/mock-jq.err" || \
        echo "mock 请求切片失败，见 mock-jq.err" >&2
fi

# ── 5.5 可选的 post.sh：VM 还活着时跑（带外通道的验证就靠它）─────
if [ -f "$CASE_DIR/post.sh" ]; then
    echo "--- post.sh（VM 仍在运行）"
    SES="$SES" OUT="$OUT" bash "$CASE_DIR/post.sh" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/post.txt" || {
        echo "post.sh 失败（见 $RUN_DIR/post.txt）" >&2
        # 失败也要把 VM 收干净，否则残留的 QEMU 会污染后面的用例
        [ -f "$RUN_DIR/vm.pid" ] && kill -9 "$(cat "$RUN_DIR/vm.pid")" 2>/dev/null || true
        tx kill-session -t "$SES" 2>/dev/null || true
        rm -f "$DISK" "$MON"
        exit 1
    }
fi

# ── 6. 销毁 ─────────────────────────────────────────────────────────────────
# 先让 monitor 把 VM 收掉（我们在 console 上，Ctrl-A x 是 QEMU 的退出键），
# 再兜底杀进程与会话。
tx send-keys -t "$SES" C-a x >/dev/null 2>&1 || true
sleep 2
if [ -f "$RUN_DIR/vm.pid" ]; then
    kill "$(cat "$RUN_DIR/vm.pid")" 2>/dev/null || true
    kill -9 "$(cat "$RUN_DIR/vm.pid")" 2>/dev/null || true
fi
tx kill-session -t "$SES" 2>/dev/null || true

RC=$(cat "$RUN_DIR/guest/tmp/ah.rc" 2>/dev/null || echo 255)
echo "case=$CASE_ID rc=$RC dir=$RUN_DIR"

# 用例自己的断言（可选）。跑在销毁之后：断言只依赖已经收回来的产物。
if [ -f "$CASE_DIR/assert.sh" ]; then
    if TESTBED="$TESTBED" CASE_ID="$CASE_ID" PUSH="$PUSH" bash "$CASE_DIR/assert.sh" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/assert.txt"; then
        echo "assert=$CASE_ID PASS"
    else
        echo "assert=$CASE_ID FAIL（见 $RUN_DIR/assert.txt）" >&2
        exit 1
    fi
fi

exit "$RC"
