#!/usr/bin/env bash
# Run macOS/Linux Tart cases inside a private clone; never open a host viewer.
# Headed cases require an already logged-in guest desktop and return gui.png.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CASE_ID=${1:?usage: bin/run-tart-case.sh <case-id>}
[[ $CASE_ID =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid case id: $CASE_ID" >&2; exit 2; }
CASE_DIR=${AHSB_CASE_DIR:-$ROOT/cases/$CASE_ID}
INPUT_ROOT=${AHSB_INPUT_ROOT:-$ROOT}
[ -f "$CASE_DIR/cmd" ] || { echo "missing case: $CASE_ID" >&2; exit 2; }
TARGET=$(head -n 1 "$CASE_DIR/target" 2>/dev/null || true)
case "$TARGET" in
    macos-tart) GUEST_OS=darwin; GUEST_SHELL=zsh; GUEST_USER=${TART_GUEST_USER:-admin} ;;
    linux-tart) GUEST_OS=linux; GUEST_SHELL=bash; GUEST_USER=${TART_GUEST_USER:-ubuntu} ;;
    *) echo "not a Tart case: $CASE_ID" >&2; exit 2 ;;
esac
[[ $GUEST_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'invalid TART_GUEST_USER' >&2; exit 2; }
DISPLAY_MODE=cli
[ ! -f "$CASE_DIR/display" ] || read -r DISPLAY_MODE < "$CASE_DIR/display"
case "$DISPLAY_MODE" in cli|headed) ;; *) echo 'display must be cli or headed' >&2; exit 2 ;; esac
GUEST_DISPLAY=${TART_GUEST_DISPLAY:-:0}
[[ $GUEST_DISPLAY =~ ^:[0-9]+(\.[0-9]+)?$ ]] || { echo 'TART_GUEST_DISPLAY must name a guest-local X display, such as :0' >&2; exit 2; }
VM_CPUS=${TART_CPUS:-2}
VM_MEMORY=${TART_MEMORY_MB:-4096}
[[ $VM_CPUS =~ ^[1-9][0-9]*$ && $VM_MEMORY =~ ^[1-9][0-9]*$ ]] || { echo 'TART_CPUS and TART_MEMORY_MB must be positive integers' >&2; exit 2; }
: "${TART_BASE_VM:?set TART_BASE_VM to a prepared local VM}"
: "${TART_SSH_KEY:?set TART_SSH_KEY to its guest private key}"
: "${TART_KNOWN_HOSTS:?set TART_KNOWN_HOSTS to its pinned host key file}"
CASE_TIMEOUT=${CASE_TIMEOUT:-300}
[[ $CASE_TIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo 'CASE_TIMEOUT must be a positive number of seconds' >&2; exit 2; }
for tool in tart ssh scp awk nice base64 od realpath shasum; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }; done
[ -f "$TART_SSH_KEY" ] && [ -r "$TART_SSH_KEY" ] && [ -s "$TART_SSH_KEY" ] || {
    echo "guest SSH private key missing, empty, or unreadable: $TART_SSH_KEY" >&2; exit 2;
}
[ -f "$TART_KNOWN_HOSTS" ] && [ -r "$TART_KNOWN_HOSTS" ] && [ -s "$TART_KNOWN_HOSTS" ] || {
    echo "pinned guest host public key file missing, empty, or unreadable: $TART_KNOWN_HOSTS" >&2; exit 2;
}
awk '$1 !~ /^#/ && $2 == "ssh-ed25519" && NF >= 3 {found=1} END {exit !found}' "$TART_KNOWN_HOSTS" || {
    echo "no pinned ED25519 guest host public key in: $TART_KNOWN_HOSTS" >&2; exit 2;
}
tart get "$TART_BASE_VM" >/dev/null || { echo "missing base VM: $TART_BASE_VM" >&2; exit 2; }
[ "$(tart get "$TART_BASE_VM" | awk 'NR == 2 {print $1}')" = "$GUEST_OS" ] || {
    echo "base VM OS does not match $TARGET: $TART_BASE_VM" >&2; exit 2;
}
[ "$(tart get "$TART_BASE_VM" | awk 'NR == 2 {print $NF}')" = stopped ] || {
    echo "base VM must be stopped: $TART_BASE_VM" >&2; exit 2;
}

OUT=${OUT:-$HOME/ahsb-build}
RUN_DIR=${RUN_DIR:-$OUT/runs/$CASE_ID/$(date -u +%Y%m%dT%H%M%SZ)-$$}
VM=ahsb-$CASE_ID-$$
mkdir -p "$(dirname "$RUN_DIR")"
mkdir "$RUN_DIR" || { echo "run directory already exists or is unavailable: $RUN_DIR" >&2; exit 2; }
mkdir -p "$RUN_DIR/guest/tmp"
printf '%s\n' "$VM" > "$RUN_DIR/vm-name.txt"
cp "$CASE_DIR/cmd" "$RUN_DIR/command.txt"
[ -z "${AHSB_INPUT_ROOT:-}" ] || cp "$INPUT_ROOT/project-source.sha256" "$RUN_DIR/project-source.sha256"
TEMP_DIR=$(mktemp -d)
awk '$1 !~ /^#/ && $2 == "ssh-ed25519" {print "ahsb-guest " $2 " " $3; found=1; exit} END {if (!found) exit 1}' \
    "$TART_KNOWN_HOSTS" > "$TEMP_DIR/known_hosts" || {
        rm -rf "$TEMP_DIR"
        echo 'no pinned ED25519 host key' >&2
        exit 2
    }
SSH=(ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o HostKeyAlias=ahsb-guest -o ConnectTimeout=4 -o "UserKnownHostsFile=$TEMP_DIR/known_hosts" -i "$TART_SSH_KEY")
SCP=(scp -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o HostKeyAlias=ahsb-guest -o ConnectTimeout=4 -o "UserKnownHostsFile=$TEMP_DIR/known_hosts" -i "$TART_SSH_KEY")
created=0
cleanup() {
    local status=$?
    trap - EXIT
    if [ -n "${CASE_PID:-}" ]; then
        kill "$CASE_PID" 2>/dev/null || true
        wait "$CASE_PID" 2>/dev/null || true
    fi
    if [ -n "${WATCHDOG_PID:-}" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
    if [ "$created" = 1 ] && tart get "$VM" >/dev/null 2>&1; then
        tart stop "$VM" >/dev/null 2>&1 || true
        [ -z "${RUN_PID:-}" ] || wait "$RUN_PID" 2>/dev/null || true
        tart delete "$VM" >/dev/null 2>&1 || { echo "could not delete test VM: $VM" >&2; status=1; }
    fi
    rm -rf "$TEMP_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if tart get "$VM" >/dev/null 2>&1; then
    echo "generated test VM already exists: $VM" >&2
    exit 2
fi
created=1
TART_NO_AUTO_PRUNE=1 tart clone "$TART_BASE_VM" "$VM"
tart set "$VM" --cpu "$VM_CPUS" --memory "$VM_MEMORY" --no-display-refit
nice -n 10 tart run --no-graphics --no-audio --no-clipboard --no-usb-accessories "$VM" > "$RUN_DIR/vm.log" 2>&1 &
RUN_PID=$!
IP=
for _ in $(seq 1 30); do
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
        echo "Tart exited before guest networking; see $RUN_DIR/vm.log" >&2
        exit 1
    fi
    if IP=$(tart ip "$VM" --wait 3 2>/dev/null); then break; fi
done
[ -n "$IP" ] || { echo "guest IP unavailable; see $RUN_DIR/vm.log" >&2; exit 1; }
ready=0
for _ in $(seq 1 60); do
    if "${SSH[@]}" "$GUEST_USER@$IP" /usr/bin/true > /dev/null 2> "$RUN_DIR/ssh-check.err"; then
        ready=1
        break
    fi
    if grep -Eq 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' "$RUN_DIR/ssh-check.err"; then
        echo "guest host key rejected; see $RUN_DIR/ssh-check.err" >&2
        exit 1
    fi
    sleep 2
done
[ "$ready" = 1 ] || { echo "guest SSH unavailable; see $RUN_DIR/ssh-check.err and vm.log" >&2; exit 1; }

push_case_file() {
    local spec=$1 source_rel destination source parent
    source_rel=${spec%%:*}
    destination=${spec#*:}
    [ "$source_rel" != "$spec" ] && [ -n "$source_rel" ] && [ -n "$destination" ] || {
        echo "invalid macos-push entry: $spec" >&2; exit 2;
    }
    case "$source_rel" in /*|*'..'*) echo "macos-push source must be repository-relative: $source_rel" >&2; exit 2;; esac
    case "$destination" in /tmp/ahsb-push/*) ;; *) echo "macos-push destination must be under /tmp/ahsb-push: $destination" >&2; exit 2;; esac
    case "$destination" in *'..'*) echo "macos-push destination must not contain ..: $destination" >&2; exit 2;; esac
    source=$(realpath "$INPUT_ROOT/$source_rel")
    case "$source" in "$INPUT_ROOT"/*) ;; *) echo "push source escapes input root: $source_rel" >&2; exit 2;; esac
    [ -f "$source" ] || { echo "macos-push source is not a file: $source_rel" >&2; exit 2; }
    parent=${destination%/*}
    "${SSH[@]}" "$GUEST_USER@$IP" /bin/mkdir -p "$parent" < /dev/null
    "${SCP[@]}" "$source" "$GUEST_USER@$IP:$destination" < /dev/null
    shasum -a 256 "$source" | sed "s#  .*#  $source_rel -> $destination#" >> "$RUN_DIR/macos-push.sha256"
}

PUSH_MANIFEST=$CASE_DIR/push
if [ ! -f "$PUSH_MANIFEST" ] && [ "$GUEST_OS" = darwin ]; then
    PUSH_MANIFEST=$CASE_DIR/macos-push
fi
if [ -f "$PUSH_MANIFEST" ]; then
    while IFS= read -r spec || [ -n "$spec" ]; do
        case "$spec" in ''|'#'*) continue;; esac
        push_case_file "$spec"
    done < "$PUSH_MANIFEST"
fi

INPUT=$CASE_DIR/cmd
if [ "$DISPLAY_MODE" = headed ]; then
    INPUT=$TEMP_DIR/guest-command.sh
    {
        printf '%s\n' 'umask 077' 'job=$(mktemp -d)' 'trap '\''rm -rf "$job"'\'' EXIT'
        if [ "$GUEST_OS" = darwin ]; then
            printf '%s\n' 'aqua_ready=0' 'for attempt in $(seq 1 120); do'
            printf '%s\n' 'if [ "$(/usr/bin/stat -f %Su /dev/console)" = "$(id -un)" ] && /bin/launchctl print "gui/$(id -u)" >/dev/null 2>&1; then aqua_ready=1; break; fi'
            printf '%s\n' 'sleep 0.25' 'done'
            printf '%s\n' 'if [ "$aqua_ready" != 1 ]; then echo "guest Aqua desktop not ready; configure login in the private seed" >&2; exit 42; fi'
        else
            printf 'export DISPLAY=%s\n' "$GUEST_DISPLAY"
            printf '%s\n' 'if ! command -v xdpyinfo >/dev/null || ! xdpyinfo >/dev/null 2>&1 || ! command -v import >/dev/null; then'
            printf '%s\n' 'echo "guest X11 desktop or ImageMagick capture not ready" >&2; exit 42; fi'
        fi
        printf 'cat > "$job/case" <<'\''AHCASE_%s'\''\n' "$$"
        cat "$CASE_DIR/cmd"
        printf '\nAHCASE_%s\n' "$$"
        printf 'if /bin/%s -l "$job/case"; then rc=0; else rc=$?; fi\n' "$GUEST_SHELL"
        if [ "$GUEST_OS" = darwin ]; then
            printf '%s\n' 'if ! /usr/sbin/screencapture -x "$job/gui.png"; then echo "guest screen capture failed; check guest TCC permissions" >&2; exit 43; fi'
        else
            printf '%s\n' 'if ! import -window root "$job/gui.png"; then echo "guest screen capture failed" >&2; exit 43; fi'
        fi
        printf '%s\n' 'printf "\n==AH_GUI_BEGIN==\n"' 'base64 < "$job/gui.png"' 'echo "==AH_GUI_END=="' 'exit "$rc"'
    } > "$INPUT"
fi
"${SSH[@]}" "$GUEST_USER@$IP" "/bin/$GUEST_SHELL" -l -s < "$INPUT" \
    > "$RUN_DIR/guest/tmp/ah.out" 2> "$RUN_DIR/guest/tmp/ah.err" &
CASE_PID=$!
(
    sleep "$CASE_TIMEOUT" &
    timer=$!
    trap 'kill "$timer" 2>/dev/null || true' EXIT
    trap 'exit 0' TERM
    wait "$timer" || exit 0
    if kill -0 "$CASE_PID" 2>/dev/null; then
        printf 'guest command exceeded %s seconds\n' "$CASE_TIMEOUT" > "$RUN_DIR/timeout.txt"
        kill "$CASE_PID" 2>/dev/null || true
    fi
) &
WATCHDOG_PID=$!
set +e
wait "$CASE_PID"
RC=$?
set -e
CASE_PID=
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=
[ ! -f "$RUN_DIR/timeout.txt" ] || RC=124
if [ "$DISPLAY_MODE" = headed ] && [ "$RC" != 124 ]; then
    DECODE=-d
    [ "$(uname -s)" != Darwin ] || DECODE=-D
    if awk '/^==AH_GUI_BEGIN==$/{capture=1;next} /^==AH_GUI_END==$/{capture=0} capture' "$RUN_DIR/guest/tmp/ah.out" \
        | base64 "$DECODE" > "$RUN_DIR/gui.png" && [ -s "$RUN_DIR/gui.png" ] &&
        [ "$(od -An -tx1 -N8 "$RUN_DIR/gui.png" | tr -d ' \n')" = 89504e470d0a1a0a ]; then
        awk '/^==AH_GUI_BEGIN==$/{capture=1;next} /^==AH_GUI_END==$/{capture=0;next} !capture' \
            "$RUN_DIR/guest/tmp/ah.out" > "$TEMP_DIR/plain.out"
        mv "$TEMP_DIR/plain.out" "$RUN_DIR/guest/tmp/ah.out"
    else
        rm -f "$RUN_DIR/gui.png"
        if [ "$RC" = 0 ]; then
            echo 'headed test returned no valid guest PNG evidence' >&2
            RC=43
        fi
    fi
fi
printf '%s\n' "$RC" > "$RUN_DIR/guest/tmp/ah.rc"
tart stop "$VM" >/dev/null
wait "$RUN_PID" 2>/dev/null || true
tart delete "$VM" >/dev/null
created=0
printf 'case=%s rc=%s dir=%s\n' "$CASE_ID" "$RC" "$RUN_DIR"
if [ -f "$RUN_DIR/timeout.txt" ]; then
    echo "case timed out (see $RUN_DIR/timeout.txt)" >&2
    exit 124
fi
if [ -f "$CASE_DIR/assert.sh" ]; then
    if bash "$CASE_DIR/assert.sh" "$RUN_DIR" > "$RUN_DIR/assert.txt" 2>&1; then
        echo "assert=$CASE_ID PASS"
    else
        echo "assert=$CASE_ID FAIL (see $RUN_DIR/assert.txt)" >&2
        exit 1
    fi
fi
exit "$RC"
