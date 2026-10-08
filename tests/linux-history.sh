#!/usr/bin/env bash
# Verify historical run directories with a fake serial console, not a real VM.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/bin" "$TMP/repo/cases/history" "$TMP/tools" "$TMP/out" "$TMP/archive/tmp"
cp "$ROOT/bin/run-case.sh" "$TMP/repo/bin/"
printf 'true\n' > "$TMP/repo/cases/history/cmd"
printf '%s\n' "$$" > "$TMP/out/mock.pid"
printf '0\n' > "$TMP/archive/tmp/ah.rc"
printf 'original evidence\n' > "$TMP/archive/tmp/ah.out"
: > "$TMP/archive/tmp/ah.err"
tar czf "$TMP/guest.tgz" -C "$TMP/archive" tmp
base64 < "$TMP/guest.tgz" > "$TMP/payload"
cat > "$TMP/tools/tmux" <<'EOF'
#!/bin/sh
if [ "$3" = capture-pane ]; then
    printf 'root@archlinux\n==M123==BEGIN==\n%s\n==M123==END==\n' "$(cat "$FAKE_PAYLOAD")"
fi
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/tools/sleep"
chmod +x "$TMP/tools/tmux" "$TMP/tools/sleep"
export PATH="$TMP/tools:$PATH" OUT="$TMP/out" FAKE_PAYLOAD="$TMP/payload"
export MOCK_REQUESTS="$TMP/absent-requests"
unset RUN_DIR PUSH SOURCE_MANIFEST
for i in 1 2; do bash "$TMP/repo/bin/run-case.sh" history > "$TMP/run$i.log"; done
first=$(grep '^case=' "$TMP/run1.log" | cut -d= -f4)
second=$(grep '^case=' "$TMP/run2.log" | cut -d= -f4)
test "$first" != "$second"
for dir in "$first" "$second"; do
    test -f "$dir/guest/tmp/ah.rc"
    grep -q 'original evidence' "$dir/guest/tmp/ah.out"
done
if RUN_DIR="$first" bash "$TMP/repo/bin/run-case.sh" history > "$TMP/reuse.log" 2>&1; then
    echo 'existing run directory was overwritten' >&2; exit 1
fi
grep -q 'run directory already exists' "$TMP/reuse.log"
grep -q 'original evidence' "$first/guest/tmp/ah.out"

# Acceptance must preserve past runs too, including when run twice in one second.
cp "$ROOT/bin/acceptance.sh" "$TMP/repo/bin/"
cat > "$TMP/repo/bin/run-case.sh" <<'EOF'
#!/bin/sh
mkdir -p "$(dirname "$RUN_DIR")"
mkdir "$RUN_DIR" || exit 2
mkdir "$RUN_DIR/guest"
printf 'evidence\n' > "$RUN_DIR/assert.txt"
EOF
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP/tools/setpriv"
printf '#!/bin/sh\nprintf "systemd fixture\\n"\n' > "$TMP/tools/systemctl"
chmod +x "$TMP/tools/setpriv" "$TMP/tools/systemctl"
for i in 1 2; do
    SKIP_BUILD=1 PRIVDROP=1 bash "$TMP/repo/bin/acceptance.sh" history > "$TMP/accept$i.log" 2> "$TMP/accept$i.err"
done
test "$(find "$OUT/runs/history" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 4
grep -q '^ALL CASES PASS$' "$TMP/accept1.log"
grep -q '^ALL CASES PASS$' "$TMP/accept2.log"
echo 'ok: Linux runs and acceptance retain separate history; existing RUN_DIR is rejected'
