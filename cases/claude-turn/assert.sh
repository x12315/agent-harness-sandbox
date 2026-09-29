#!/usr/bin/env bash
# 断言：Claude Code 在 airgap 沙盒里跑完一轮，且三处证据齐全。
#
#   ① mock 侧收到的请求形状  ② harness 自身状态文件  ③ 退出码与输出
set -euo pipefail
D=${1:?usage: assert.sh <case-dir>}

# ① 请求形状：打到了 Messages API、是流式、带了鉴权头、且工具表不是空的
#   （工具表长度是"harness 把自己的工具面暴露给模型"的直接证据）
jq -es '
    (map(select(.path | startswith("/v1/messages"))) | length > 0)
and (map(select(.stream == true)) | length > 0)
and (map(select(.auth_header_present == true)) | length > 0)
and (map(.tool_names | length) | max >= 10)
' "$D/mock-requests.jsonl" >/dev/null \
    || { echo "FAIL: mock 侧请求形状不符（见 $D/mock-requests.jsonl）"; exit 1; }
echo "ok ①: mock 收到流式 /v1/messages，带鉴权头，工具表 >=10 项"

# ② harness 自己的状态文件必须能被回收（落在宿主可读的地方）
[ -s "$D/guest/root/.claude.json" ] || { echo "FAIL: 没回收到 ~/.claude.json"; exit 1; }
echo "ok ②: 回收到 harness 状态 ~/.claude.json（$(wc -c <"$D/guest/root/.claude.json") 字节）"

# ③ 退出码与输出
rc=$(cat "$D/guest/tmp/ah.rc")
[ "$rc" = 0 ] || { echo "FAIL: 退出码 $rc"; exit 1; }
grep -q MOCK_OK "$D/guest/tmp/ah.out" || { echo "FAIL: stdout 里没有 mock 的应答"; exit 1; }
echo "ok ③: rc=0，stdout 含 mock 应答"
