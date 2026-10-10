#!/usr/bin/env bash
# Exercise the macOS runner without booting a VM or opening a host window.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "$ROOT/.test-macos.XXXXXX")
probe_pid=
cleanup() {
    [ -z "$probe_pid" ] || { kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; }
    rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/state"
printf 'seed ssh-ed25519 test-key\n' > "$TMP/known_hosts"
printf 'test-only-private-key-placeholder\n' > "$TMP/id_ed25519"

cat > "$TMP/bin/tart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
operation=$1; shift
printf '%s %s\n' "$operation" "$*" >> "$FAKE_STATE/tart-calls"
case "$operation" in
    get)
        if [ "$1" != seed ] && [ ! -f "$FAKE_STATE/present" ]; then exit 1; fi
        printf 'OS State\n%s stopped\n' "${FAKE_GUEST_OS:-darwin}"
        ;;
    set) : ;;
    clone) touch "$FAKE_STATE/present" ;;
    run)
        trap 'exit 0' TERM
        while [ ! -f "$FAKE_STATE/stopped" ]; do sleep 0.1; done
        ;;
    ip) printf '127.0.0.1\n' ;;
    stop) touch "$FAKE_STATE/stopped" ;;
    delete) rm -f "$FAKE_STATE/present"; touch "$FAKE_STATE/deleted" ;;
    *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_STATE/ssh-all-args"
if [ "${!#}" = /usr/bin/true ]; then
    if [ "${FAKE_SSH_MODE:-}" = host-key-fail ]; then
        echo 'Host key verification failed' >&2
        exit 255
    fi
    exit 0
fi
touch "$FAKE_STATE/running-case"
printf '%s\n' "$*" > "$FAKE_STATE/ssh-case-args"
cat > "$FAKE_STATE/guest-input"
if [ "${FAKE_SSH_MODE:-}" = desktop-blocked ]; then
    echo 'guest Aqua desktop not ready; configure login in the private seed' >&2
    exit 42
fi
if [[ "${FAKE_SSH_MODE:-}" = *-ready ]]; then
    case "$FAKE_SSH_MODE" in
        desktop-ready) printf 'guestCalculatorWindows=1\n' ;;
        iterm-ready) printf 'guestITermWindows=2\nguestITermPiVersion=0.87.1\n' ;;
        browser-ready) printf 'guestBrowserMode=headless PASS\nguestBrowserMode=headed PASS\nguestBrowserWindows=1\n' ;;
        *) exit 2 ;;
    esac
    printf '==AH_GUI_BEGIN==\n'
    printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1EAAAAASUVORK5CYII=\n'
    printf '==AH_GUI_END==\n'
    exit 0
fi
if [ "${FAKE_SSH_MODE:-}" = pass ]; then
    printf '{"command":"get_commands","success":true,"data":{"commands":[]}}\n'
    exit 0
fi
exec sleep 10
EOF
chmod +x "$TMP/bin/tart" "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH" FAKE_STATE="$TMP/state"
export TART_BASE_VM=seed TART_KNOWN_HOSTS="$TMP/known_hosts" TART_SSH_KEY="$TMP/id_ed25519"
run_case() {
    local name=$1 mode=$2 timeout=$3
    rm -f "$FAKE_STATE"/{stopped,deleted,running-case}
    export RUN_DIR="$TMP/$name" FAKE_SSH_MODE=$mode CASE_TIMEOUT=$timeout
    bash "$ROOT/bin/run-tart-case.sh" "${FAKE_CASE_ID:-macos-pi-discovery}" > "$TMP/$name.out" 2> "$TMP/$name.err"
}

if TART_SSH_KEY="$TMP/missing-private" run_case missing-private pass 2; then
    echo 'missing private key was accepted' >&2; exit 1
fi
grep -q 'guest SSH private key missing' "$TMP/missing-private.err"
test ! -f "$FAKE_STATE/present"
if TART_KNOWN_HOSTS="$TMP/missing-public" run_case missing-public pass 2; then
    echo 'missing pinned public key was accepted' >&2; exit 1
fi
grep -q 'pinned guest host public key file missing' "$TMP/missing-public.err"
test ! -f "$FAKE_STATE/present"
printf 'seed ssh-rsa invalid-placeholder\n' > "$TMP/wrong-key-type"
if TART_KNOWN_HOSTS="$TMP/wrong-key-type" run_case wrong-type pass 2; then
    echo 'missing pinned ED25519 key was accepted' >&2; exit 1
fi
grep -q 'no pinned ED25519 guest host public key' "$TMP/wrong-type.err"
test ! -f "$FAKE_STATE/present"

if run_case invalid pass 0; then echo 'invalid timeout was accepted' >&2; exit 1; fi
grep -q 'CASE_TIMEOUT must be a positive number' "$TMP/invalid.err"
test ! -f "$FAKE_STATE/present"

run_case success pass 2
grep -q 'assert=macos-pi-discovery PASS' "$TMP/success.out"
test "$(cat "$TMP/success/guest/tmp/ah.rc")" = 0
test -f "$FAKE_STATE/deleted" && test ! -f "$FAKE_STATE/present"
grep -q 'ControlMaster=auto.*ControlPersist=30.*ControlPath=.*ssh-control' "$FAKE_STATE/ssh-case-args"
grep -q 'StrictHostKeyChecking=yes.*HostKeyAlias=ahsb-guest' "$FAKE_STATE/ssh-case-args"
control_path=$(grep -o 'ControlPath=[^ ]*' "$FAKE_STATE/ssh-case-args" | cut -d= -f2-)
test ! -e "${control_path%/*}"

grep -q 'run --no-graphics --no-audio --no-clipboard --no-usb-accessories' "$FAKE_STATE/tart-calls"
grep -q 'set .* --cpu 2 --memory 4096 --no-display-refit' "$FAKE_STATE/tart-calls"
if grep -Eq '^run .*--(dir|vnc|capture-system-keys|disk)' "$FAKE_STATE/tart-calls"; then
    echo 'host-sharing or viewer option was enabled' >&2; exit 1
fi

FAKE_CASE_ID=linux-pi-discovery FAKE_GUEST_OS=linux run_case linux-local pass 2
grep -q 'ubuntu@127.0.0.1 /bin/bash -l -s' "$FAKE_STATE/ssh-case-args"
grep -q 'assert=linux-pi-discovery PASS' "$TMP/linux-local.out"
if FAKE_CASE_ID=linux-pi-discovery run_case wrong-os pass 2; then
    echo 'Linux case on macOS base was accepted' >&2; exit 1
fi
grep -q 'base VM OS does not match' "$TMP/wrong-os.err"

FAKE_CASE_ID=macos-desktop-smoke run_case gui-success desktop-ready 2
grep -q 'assert=macos-desktop-smoke PASS' "$TMP/gui-success.out"
test -s "$TMP/gui-success/gui.png"
grep -q 'stat -f %Su /dev/console' "$FAKE_STATE/guest-input"
grep -q 'for attempt in $(seq 1 120)' "$FAKE_STATE/guest-input"
grep -q 'screencapture -x' "$FAKE_STATE/guest-input"
# Execute only the generated readiness block with fake guest console/Aqua probes.
# Never execute the guest application code or query the host GUI.
awk '/^aqua_ready=0$/{active=1} active{print} /^if \[ "\$aqua_ready" != 1 \]; then/{exit}' \
    "$FAKE_STATE/guest-input" > "$TMP/aqua-probe.sh"
(
    fake_guest_stat() { id -un; }
    fake_guest_launchctl() {
        local count=0
        [ ! -f "$TMP/aqua-count" ] || read -r count < "$TMP/aqua-count"
        count=$((count + 1))
        printf '%s\n' "$count" > "$TMP/aqua-count"
        [ "$count" -ge 3 ]
    }
    sleep() { :; }
    probe=$(< "$TMP/aqua-probe.sh")
    probe=${probe//\/usr\/bin\/stat/fake_guest_stat}
    probe=${probe//\/bin\/launchctl/fake_guest_launchctl}
    eval "$probe"
    test "$aqua_ready" = 1
    test "$(< "$TMP/aqua-count")" = 3
)
if (
    fake_guest_stat() { printf 'root\n'; }
    fake_guest_launchctl() { return 1; }
    sleep() { :; }
    probe=$(< "$TMP/aqua-probe.sh")
    probe=${probe//\/usr\/bin\/stat/fake_guest_stat}
    probe=${probe//\/bin\/launchctl/fake_guest_launchctl}
    eval "$probe"
); then echo 'permanently unavailable Aqua was accepted' >&2; exit 1; else test "$?" = 42; fi
grep -q 'CGWindowListCopyWindowInfo' "$FAKE_STATE/guest-input"
if grep -q 'tell application "Calculator" to count windows' "$FAKE_STATE/guest-input"; then
    echo 'unsupported Calculator AppleScript window query returned' >&2; exit 1
fi
FAKE_CASE_ID=macos-iterm-smoke run_case iterm-gui iterm-ready 2
grep -q 'assert=macos-iterm-smoke PASS' "$TMP/iterm-gui.out"
FAKE_CASE_ID=macos-browser-smoke run_case browser-gui browser-ready 2
grep -q 'assert=macos-browser-smoke PASS' "$TMP/browser-gui.out"
grep -q 'Google Chrome for Testing' "$FAKE_STATE/guest-input"
grep -q 'result.data.text' "$FAKE_STATE/guest-input"
# A single browser mode or absent GUI evidence must not pass the host assertion.
grep -v 'guestBrowserMode=headed' "$TMP/browser-gui/guest/tmp/ah.out" > "$TMP/incomplete-browser.out"
cp "$TMP/incomplete-browser.out" "$TMP/browser-gui/guest/tmp/ah.out"
if bash "$ROOT/cases/macos-browser-smoke/assert.sh" "$TMP/browser-gui" >/dev/null 2>&1; then
    echo 'incomplete browser modes were accepted' >&2; exit 1
fi
mkdir -p "$TMP/linux-fixture/bin" "$TMP/linux-fixture/cases/linux-headed"
cp "$ROOT/bin/run-tart-case.sh" "$TMP/linux-fixture/bin/"
printf 'linux-tart\n' > "$TMP/linux-fixture/cases/linux-headed/target"
printf 'headed\n' > "$TMP/linux-fixture/cases/linux-headed/display"
printf 'true\n' > "$TMP/linux-fixture/cases/linux-headed/cmd"
ROOT="$TMP/linux-fixture" FAKE_CASE_ID=linux-headed FAKE_GUEST_OS=linux run_case linux-gui desktop-ready 2
test -s "$TMP/linux-gui/gui.png"
grep -q 'export DISPLAY=:0' "$FAKE_STATE/guest-input"
grep -q 'xdpyinfo' "$FAKE_STATE/guest-input"
grep -q 'import -window root' "$FAKE_STATE/guest-input"
if FAKE_CASE_ID=macos-desktop-smoke run_case gui-blocked desktop-blocked 2; then
    echo 'unprepared desktop was accepted' >&2; exit 1
fi
test "$(cat "$TMP/gui-blocked/guest/tmp/ah.rc")" = 42
test -f "$FAKE_STATE/deleted" && test ! -f "$FAKE_STATE/present"
if FAKE_CASE_ID=macos-desktop-smoke run_case missing-screenshot pass 2; then
    echo 'headed case without screenshot evidence was accepted' >&2; exit 1
fi
test "$(cat "$TMP/missing-screenshot/guest/tmp/ah.rc")" = 43
test ! -f "$TMP/missing-screenshot/gui.png"

if run_case timeout hang 1; then echo 'hung guest was accepted' >&2; exit 1; else rc=$?; fi
test "$rc" = 124 && test -f "$TMP/timeout/timeout.txt"
test "$(cat "$TMP/timeout/guest/tmp/ah.rc")" = 124
test -f "$FAKE_STATE/deleted" && test ! -f "$FAKE_STATE/present"

if run_case rejected host-key-fail 2; then echo 'rejected host key was accepted' >&2; exit 1; fi
grep -q 'guest host key rejected' "$TMP/rejected.err"
test -f "$FAKE_STATE/deleted" && test ! -f "$FAKE_STATE/present"

rm -f "$FAKE_STATE"/{stopped,deleted,running-case}
export RUN_DIR="$TMP/interrupted" FAKE_SSH_MODE=hang CASE_TIMEOUT=30
bash "$ROOT/bin/run-macos-case.sh" macos-pi-discovery > "$TMP/interrupted.out" 2> "$TMP/interrupted.err" &
probe_pid=$!
ready=0
for _ in $(seq 1 50); do
    if [ -f "$FAKE_STATE/running-case" ]; then ready=1; break; fi
    if ! kill -0 "$probe_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
test "$ready" = 1
kill -TERM "$probe_pid"
if wait "$probe_pid"; then echo 'interrupted guest was accepted' >&2; exit 1; fi
probe_pid=
test -f "$FAKE_STATE/deleted" && test ! -f "$FAKE_STATE/present"

echo 'ok: Tart OS routing, host-interference guards, guest-only GUI evidence, timeout and cleanup work'
