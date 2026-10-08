#!/usr/bin/env bash
# Clone a macOS test image, run one case over SSH, capture evidence, and discard the clone.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CASE_ID=${1:?usage: bin/run-macos-case.sh <case-id>}
[[ $CASE_ID =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid case id: $CASE_ID" >&2; exit 2; }
CASE_DIR=$ROOT/cases/$CASE_ID
[ -f "$CASE_DIR/cmd" ] || { echo "missing case: $CASE_ID" >&2; exit 2; }
[ "$(head -n 1 "$CASE_DIR/target" 2>/dev/null)" = macos-tart ] || { echo "not a macos-tart case: $CASE_ID" >&2; exit 2; }
: "${TART_BASE_VM:?set TART_BASE_VM to a prepared local VM}"
: "${TART_SSH_KEY:?set TART_SSH_KEY to its guest private key}"
: "${TART_KNOWN_HOSTS:?set TART_KNOWN_HOSTS to its pinned host key file}"
CASE_TIMEOUT=${CASE_TIMEOUT:-300}
[[ $CASE_TIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo 'CASE_TIMEOUT must be a positive number of seconds' >&2; exit 2; }
for tool in tart ssh awk; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }; done
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
[ "$(tart get "$TART_BASE_VM" | awk 'NR == 2 {print $NF}')" = stopped ] || {
    echo "base VM must be stopped: $TART_BASE_VM" >&2; exit 2;
}

OUT=${OUT:-$HOME/ahsb-build}
RUN_DIR=${RUN_DIR:-$OUT/runs/$CASE_ID/$(date -u +%Y%m%dT%H%M%SZ)-$$}
VM=ahsb-$CASE_ID-$$
mkdir -p "$RUN_DIR/guest/tmp"
printf '%s\n' "$VM" > "$RUN_DIR/vm-name.txt"
cp "$CASE_DIR/cmd" "$RUN_DIR/command.txt"
TEMP_DIR=$(mktemp -d)
awk '$1 !~ /^#/ && $2 == "ssh-ed25519" {print "ahsb-guest " $2 " " $3; found=1; exit} END {if (!found) exit 1}' \
    "$TART_KNOWN_HOSTS" > "$TEMP_DIR/known_hosts" || {
        rm -rf "$TEMP_DIR"
        echo 'no pinned ED25519 host key' >&2
        exit 2
    }
SSH=(ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
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
tart run --no-graphics --no-clipboard --no-usb-accessories "$VM" > "$RUN_DIR/vm.log" 2>&1 &
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
    if "${SSH[@]}" "admin@$IP" /usr/bin/true > /dev/null 2> "$RUN_DIR/ssh-check.err"; then
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

"${SSH[@]}" "admin@$IP" /bin/zsh -l -s < "$CASE_DIR/cmd" \
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
