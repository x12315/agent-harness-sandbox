#!/usr/bin/env bash
# Verify consumer-owned cases without SSH, VM boot, or writes to sandbox cases/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/local" "$TMP/bin" "$TMP/consumer project/tests/sandbox/smoke" "$TMP/consumer project/src"
cp -R "$ROOT/bin" "$ROOT/mock" "$TMP/local/"
cat > "$TMP/local/bin/run-case.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -f "$AHSB_CASE_DIR/cmd"
test "$(cat "$AHSB_INPUT_ROOT/src/input.txt")" = fixture
test -s "$AHSB_INPUT_ROOT/project-source.sha256"
printf '%s\n' "$AHSB_INPUT_ROOT" > "$AH_LAST_INPUT"
printf '%s\n' "$1" >> "$AH_RUNS"
[ "${FAKE_RUN_FAIL:-}" != 1 ] || exit 7
EOF
cp "$TMP/local/bin/run-case.sh" "$TMP/local/bin/run-tart-case.sh"
cp -R "$TMP/local" "$TMP/agent-harness-sandbox"
cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
HOME="$FAKE_HOME" /bin/bash -c "$2"
EOF
cat > "$TMP/bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_TAR" "$@"
if [ "${FAKE_TAMPER:-}" = 1 ] && [ "$1" = -xzf ]; then
    printf 'corrupt\n' > "$4/src/input.txt"
fi
EOF
printf '#!/bin/sh\necho Linux\n' > "$TMP/bin/uname"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemd-vmspawn"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP/bin/setpriv"
printf '#!/bin/sh\necho 1001\n' > "$TMP/bin/id"
chmod +x "$TMP/bin/"*
export REAL_TAR=$(command -v tar)
export PATH="$TMP/bin:$PATH" FAKE_HOME="$TMP" AH_RUNS="$TMP/runs" AH_LAST_INPUT="$TMP/last-input"
export REMOTE=fixture DEST=agent-harness-sandbox
PROJECT="$TMP/consumer project"
printf 'true\n' > "$PROJECT/tests/sandbox/smoke/cmd"
printf 'src/input.txt:/tmp/ahsb-push/input.txt\n' > "$PROJECT/tests/sandbox/smoke/push"
printf 'fixture\n' > "$PROJECT/src/input.txt"
bash "$TMP/local/bin/test.sh" --project "$PROJECT" smoke
test "$(wc -l < "$AH_RUNS" | tr -d ' ')" = 1
test ! -d "$(cat "$AH_LAST_INPUT")"
test ! -d "$TMP/local/cases"

if FAKE_TAMPER=1 bash "$TMP/local/bin/test.sh" --project "$PROJECT" smoke > "$TMP/out" 2> "$TMP/err"; then
    echo 'corrupt project snapshot accepted' >&2; exit 1
fi
grep -q 'project input snapshot checksum mismatch' "$TMP/err"
test "$(wc -l < "$AH_RUNS" | tr -d ' ')" = 1
printf '# remote-only change\n' >> "$TMP/agent-harness-sandbox/mock/mock_llm.py"
if bash "$TMP/local/bin/test.sh" --project "$PROJECT" smoke > "$TMP/out" 2> "$TMP/err"; then
    echo 'different sandbox checkout accepted' >&2; exit 1
fi
grep -q 'sandbox source mismatch' "$TMP/err"
test "$(wc -l < "$AH_RUNS" | tr -d ' ')" = 1
EXECUTION=local bash "$TMP/local/bin/test.sh" --project "$PROJECT" smoke
test ! -d "$(cat "$AH_LAST_INPUT")"
for target in macos-tart linux-tart; do
    printf '%s\n' "$target" > "$PROJECT/tests/sandbox/smoke/target"
    EXECUTION=local bash "$TMP/local/bin/test.sh" --project "$PROJECT" smoke
    test ! -d "$(cat "$AH_LAST_INPUT")"
done
test "$(wc -l < "$AH_RUNS" | tr -d ' ')" = 4
if EXECUTION=local FAKE_RUN_FAIL=1 bash "$TMP/local/bin/test.sh" --project "$PROJECT" smoke; then
    echo 'consumer failure was ignored' >&2; exit 1
else
    test "$?" = 7
fi
test ! -d "$(cat "$AH_LAST_INPUT")"
echo 'ok: external project snapshots, remote checksums, all dispatch routes and temporary cleanup work'
