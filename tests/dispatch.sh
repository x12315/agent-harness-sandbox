#!/usr/bin/env bash
# Verify source matching before remote dispatch, without contacting an SSH server.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/local" "$TMP/bin"
cp -R "$ROOT/bin" "$ROOT/mock" "$ROOT/cases" "$TMP/local/"
printf '#!/bin/sh\nprintf "ran\\n" >> "$AH_TEST_RUNS"\n' > "$TMP/local/bin/run-case.sh"
cp -R "$TMP/local" "$TMP/agent-harness-sandbox"
cat > "$TMP/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$AH_TEST_OUT"
HOME="$FAKE_HOME" /bin/bash -c "$2"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_HOST_SYSTEM:-Darwin}"\n' > "$TMP/bin/uname"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemd-vmspawn"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP/bin/setpriv"
printf '#!/bin/sh\necho 1001\n' > "$TMP/bin/id"
chmod +x "$TMP/bin/ssh" "$TMP/bin/uname" "$TMP/bin/systemd-vmspawn" "$TMP/bin/setpriv" "$TMP/bin/id"
export AH_TEST_OUT="$TMP/args" AH_TEST_RUNS="$TMP/runs" FAKE_HOME="$TMP"
export PATH="$TMP/bin:$PATH" REMOTE=fixture DEST=agent-harness-sandbox
bash "$TMP/local/bin/test.sh" pi-turn
grep -q '^fixture cd ' "$TMP/args"
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 1
printf 'remote change\n' >> "$TMP/agent-harness-sandbox/cases/pi-turn/cmd"
if bash "$TMP/local/bin/test.sh" pi-turn > "$TMP/out" 2> "$TMP/err"; then
    echo 'different remote case was accepted' >&2; exit 1
fi
grep -q 'local/remote source mismatch' "$TMP/err"
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 1
cp "$TMP/local/cases/pi-turn/cmd" "$TMP/agent-harness-sandbox/cases/pi-turn/cmd"
printf '# remote change\n' >> "$TMP/agent-harness-sandbox/mock/mock_llm.py"
if bash "$TMP/local/bin/test.sh" pi-turn > "$TMP/out" 2> "$TMP/err"; then
    echo 'different remote mock was accepted' >&2; exit 1
fi
grep -q 'local/remote source mismatch' "$TMP/err"
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 1
cp "$TMP/local/mock/mock_llm.py" "$TMP/agent-harness-sandbox/mock/mock_llm.py"
printf '# unexpected remote-only env\n' > "$TMP/agent-harness-sandbox/cases/pi-turn/env"
if bash "$TMP/local/bin/test.sh" pi-turn > "$TMP/out" 2> "$TMP/err"; then
    echo 'remote-only case env was accepted' >&2; exit 1
fi
grep -q 'local/remote source mismatch' "$TMP/err"
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 1
if bash "$TMP/local/bin/test.sh" invalid.case > /dev/null 2>&1; then
    echo 'invalid case id was accepted' >&2; exit 1
fi
if EXECUTION=local FAKE_HOST_SYSTEM=Darwin bash "$TMP/local/bin/test.sh" pi-turn > "$TMP/out" 2> "$TMP/err"; then
    echo 'local vmspawn on macOS was accepted' >&2; exit 1
fi
grep -q 'requires a Linux host' "$TMP/err"
EXECUTION=local FAKE_HOST_SYSTEM=Linux bash "$TMP/local/bin/test.sh" pi-turn
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 2
if EXECUTION=invalid bash "$TMP/local/bin/test.sh" pi-turn > "$TMP/out" 2> "$TMP/err"; then
    echo 'invalid execution route was accepted' >&2; exit 1
fi
bash "$TMP/local/bin/test.sh" browser-debug-headless
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 3
printf '// different browser fixture\n' >> "$TMP/agent-harness-sandbox/bin/browser-debug/server.mjs"
if bash "$TMP/local/bin/test.sh" browser-debug-headed > "$TMP/out" 2> "$TMP/err"; then
    echo 'different remote browser fixture was accepted' >&2; exit 1
fi
grep -q 'local/remote source mismatch' "$TMP/err"
test "$(wc -l < "$TMP/runs" | tr -d ' ')" = 3
if EXECUTION=local FAKE_HOST_SYSTEM=Darwin bash "$TMP/local/bin/test.sh" browser-debug-headed > "$TMP/out" 2> "$TMP/err"; then
    echo 'headed browser case fell back to macOS host execution' >&2; exit 1
fi
grep -q 'requires a Linux host' "$TMP/err"
echo 'ok: local dispatch and remote source checks include browser helpers; host fallback is rejected'
