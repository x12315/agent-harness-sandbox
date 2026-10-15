#!/usr/bin/env bash
# Drive the guest-owned case and a pinned, loopback-only SSH reverse tunnel.
# Requires an already-running two-request broker; never reads provider credentials.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
D=${1:?usage: run-real-provider-tart.sh <external-evidence-dir>}
for i in $(seq 1 50); do [ ! -s "$D/broker-port" ] || break; sleep 0.1; done
PORT=$(< "$D/broker-port")
node --input-type=module - "$PORT" <<'NODE'
const response=await fetch(`http://127.0.0.1:${process.argv[2]}/health`,{signal:AbortSignal.timeout(2000)});
if(response.status!==200)throw Error('native broker not ready');
NODE
: "${TART_SSH_KEY:?load a verified private Tart profile}"
: "${TART_KNOWN_HOSTS:?load the pinned guest host key file}"
: "${TART_BASE_VM:?select a prepared runtime base}"
RUN_DIR="$D/guest-run"
CONTROL=$(mktemp -d /tmp/ahsb-ds-tart-XXXXXX)
awk '$1 !~ /^#/ && $2 == "ssh-ed25519" {print "ahsb-guest " $2 " " $3; found=1; exit} END {if (!found) exit 1}' "$TART_KNOWN_HOSTS" > "$CONTROL/known_hosts"
SSH=(ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o HostKeyAlias=ahsb-guest -o ConnectTimeout=4 -o "UserKnownHostsFile=$CONTROL/known_hosts"
    -i "$TART_SSH_KEY" -o "ControlPath=$CONTROL/socket")
runner=''
cleanup() {
    rc=$?
    trap - EXIT
    [ ! -S "$CONTROL/socket" ] || "${SSH[@]}" -O exit "${TART_GUEST_USER:-admin}@${IP:-127.0.0.1}" >/dev/null 2>&1 || true
    if [ -n "$runner" ] && kill -0 "$runner" 2>/dev/null; then kill "$runner" 2>/dev/null || true; wait "$runner" 2>/dev/null || true; fi
    rm -rf "$CONTROL"
    exit "$rc"
}
trap cleanup EXIT
RUN_DIR="$RUN_DIR" CASE_TIMEOUT=100 bash "$ROOT/bin/test.sh" --project "$ROOT" macos-observer-real-provider > "$D/guest-run.log" 2>&1 &
runner=$!
for i in $(seq 1 150); do
    [ ! -s "$RUN_DIR/vm-name.txt" ] || break
    kill -0 "$runner"; sleep 0.1
done
VM=$(< "$RUN_DIR/vm-name.txt")
IP=$(tart ip "$VM" --wait 30)
ready=0
for i in $(seq 1 20); do
    if "${SSH[@]}" -M -f -N -o ExitOnForwardFailure=yes -R "28812:127.0.0.1:$PORT" "${TART_GUEST_USER:-admin}@$IP" 2> "$D/tunnel.err"; then ready=1; break; fi
    kill -0 "$runner"; sleep 0.5
done
[ "$ready" = 1 ] || { echo 'guest tunnel unavailable'; exit 1; }
"${SSH[@]}" "${TART_GUEST_USER:-admin}@$IP" '/usr/bin/curl --fail --connect-timeout 3 --max-time 5 http://127.0.0.1:28812/health && touch /tmp/observer-provider-ready'
echo 'guest-provider-tunnel-ready'
wait "$runner"
runner=''
echo 'observer-real-provider-tart PASS'
