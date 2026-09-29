#!/usr/bin/env bash
# 断言：pi 在 airgap 沙盒里跑完一轮，且三处证据齐全。
set -euo pipefail
D=${1:?usage: assert.sh <case-dir>}

# ① 请求形状：pi 走的是自定义 provider（openai-completions），所以应打到 /v1/chat/completions
jq -es '
    (map(select(.path | startswith("/v1/chat/completions"))) | length > 0)
and (map(.model == "mock-model") | length > 0)
and (map(.tool_names | sort) | any(. == ["bash","edit","read","write"]))
' "$D/mock-requests.jsonl" >/dev/null \
    || { echo "FAIL: mock 侧请求形状不符（见 $D/mock-requests.jsonl）"; exit 1; }
echo "ok ①: mock 收到 /v1/chat/completions，模型名与工具表（read/bash/edit/write）符合预期"

# ② pi 自己的状态：会话文件落在 ~/.pi 下
[ -n "$(find "$D/guest/root/.pi" -type f 2>/dev/null | head -1)" ] \
    || { echo "FAIL: 没回收到 ~/.pi 下的状态文件"; exit 1; }
echo "ok ②: 回收到 pi 状态文件（$(find "$D/guest/root/.pi" -type f | wc -l) 个）"

# ③ 退出码与输出
rc=$(cat "$D/guest/tmp/ah.rc")
[ "$rc" = 0 ] || { echo "FAIL: 退出码 $rc"; exit 1; }
grep -q MOCK_OK "$D/guest/tmp/ah.out" || { echo "FAIL: stdout 里没有 mock 的应答"; exit 1; }
echo "ok ③: rc=0，stdout 含 mock 应答"
