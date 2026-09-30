#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$AH_TEST_OUT"\n' > "$TMP/ssh"
chmod +x "$TMP/ssh"
AH_TEST_OUT="$TMP/args" PATH="$TMP:$PATH" REMOTE=fixture DEST=agent-harness-sandbox \
    bash "$ROOT/bin/test.sh" pi-turn
grep -q '^fixture cd ' "$TMP/args"
grep -q "bash bin/run-case.sh 'pi-turn'" "$TMP/args"
if bash "$ROOT/bin/test.sh" invalid.case > /dev/null 2>&1; then
    echo 'invalid case id was accepted' >&2
    exit 1
fi
echo 'ok: Linux dispatch preserves remote runner and validates case id'
