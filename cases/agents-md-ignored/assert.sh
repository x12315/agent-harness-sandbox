#!/usr/bin/env bash
# 反例：同一份夹具、同一条命令，只多了 --no-context-files。
# 夹具内容与规则令牌都必须消失 —— 否则正例断言区分不出"加载"和"碰巧命中"。
set -euo pipefail
D=${1:?usage: assert.sh <case-dir>}
BODY=$(jq -r '.body // ""' "$D/mock-requests.jsonl")

grep -q 'AH-SENTINEL-4F3C9A-7D21' <<<"$BODY" && { echo "FAIL: 关掉上下文文件后哨兵仍然出现"; exit 1; }
grep -qE '原文 sha256:|夹具硬规则' <<<"$BODY" && { echo "FAIL: 关掉上下文文件后夹具内容仍然出现"; exit 1; }
echo "ok ①: 关掉上下文文件后夹具内容整体消失 —— 正反例可区分"

grep -q 'AH-COMPLY-7788' "$D/guest/tmp/ah.out" && { echo "FAIL: 规则没被注入，输出里却有规则令牌"; exit 1; }
echo "ok ②: 规则没有被注入，最终输出里也没有规则令牌（行为层面同样可区分）"

[ "$(cat "$D/guest/tmp/ah.rc")" = 0 ] || { echo "FAIL: 退出码非 0"; exit 1; }
grep -q MOCK_OK "$D/guest/tmp/ah.out" || { echo "FAIL: stdout 里没有 mock 应答"; exit 1; }
echo "ok ③: rc=0，stdout 含 mock 应答（除开关外条件相同）"
