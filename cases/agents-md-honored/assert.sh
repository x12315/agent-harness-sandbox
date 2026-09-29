#!/usr/bin/env bash
# 断言：指令层被注入 + 注入的规则驱动出可观测行为。
#
# 夹具有两种可能（见 docs/instruction-layer.md）：
#   · 真实投影（作者机器）：由 bin/project-agents-md.sh 从 ~/.agents/AGENTS.md 生成，
#     头部记录 `原文 sha256: <hash>`。断言**按哈希对账** —— 不猜内容措辞。
#   · 中性夹具（公开版）：仓库里那份，断言它的规则段落在。
set -euo pipefail
D=${1:?usage: assert.sh <case-dir>}
SENT=AH-SENTINEL-4F3C9A-7D21
BODY=$(jq -r '.body // ""' "$D/mock-requests.jsonl")
[ -n "$BODY" ] || { echo "FAIL: 本次没有抓到任何请求正文"; exit 1; }

grep -q "$SENT" <<<"$BODY" || { echo "FAIL: 请求正文里没有指令层哨兵（夹具没被加载）"; exit 1; }

if grep -q '原文 sha256:' <<<"$BODY"; then
    # 真实投影：文件头记的是**原始 ~/.agents/AGENTS.md** 的 sha256。
    # 断言做的是「正文 ⇄ 本机夹具」对账：证明到达模型的那份内容，就是投影脚本生成的这份。
    # （原始文件在 Mac 上，alpha 看不到；那一环由 project-agents-md.sh 生成时保证。）
    SRC=$TESTBED/mkosi.skeleton/opt/agents-fixture/AGENTS.local.md
    [ -f "$SRC" ] || { echo "FAIL: 正文记录是真实投影，但本机找不到 $SRC"; exit 1; }
    REC=$(grep -oE '原文 sha256: [0-9a-f]{64}' "$SRC" | head -1 | awk '{print $3}')
    [ -n "$REC" ] || { echo "FAIL: 本机夹具里没有记录原文 sha256"; exit 1; }
    grep -q "原文 sha256: $REC" <<<"$BODY" \
        || { echo "FAIL: 正文里的投影记录与本机夹具不一致（夹具记录 $REC）"; exit 1; }
    echo "ok ①: 请求正文里是**真实 ~/.agents/AGENTS.md 的投影**（原文 sha256 ${REC:0:12}…，与夹具记录一致）"
else
    grep -q '夹具硬规则' <<<"$BODY" || { echo "FAIL: 中性夹具没有被完整注入"; exit 1; }
    echo "ok ①: 请求正文里出现哨兵与中性夹具的硬规则（公开版路径）"
fi

jq -r '.rule_token // ""' "$D/mock-requests.jsonl" | grep -q 'AH-COMPLY-7788' \
    || { echo "FAIL: 请求里没有规则令牌，模型无从遵守"; exit 1; }
grep -q 'AH-COMPLY-7788' "$D/guest/tmp/ah.out" \
    || { echo "FAIL: 指令层的规则没有体现在 harness 的最终输出里"; exit 1; }
echo "ok ②: 指令层里的规则驱动出了可观测的行为（最终输出带 AH-COMPLY-7788）"

[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ] || { echo "FAIL: 退出码非 0"; exit 1; }
grep -q MOCK_OK "$D/guest/tmp/ah.out" || { echo "FAIL: stdout 里没有 mock 应答"; exit 1; }
echo "ok ③: rc=0，stdout 含 mock 应答"
