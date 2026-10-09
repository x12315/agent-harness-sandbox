#!/usr/bin/env bash
# Test enrollment transport and ownership guards without booting a VM or touching the host GUI.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
ssh-keygen -q -t ed25519 -N '' -C test-only -f "$TMP/key"
cat > "$TMP/bin/tart" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ENROLL_STATE/calls"
case "$1" in
    get) printf 'OS State\ndarwin %s\n' "${FAKE_VM_STATE:-stopped}" ;;
    run)
        trap 'exit 0' TERM
        while [ ! -f "$ENROLL_STATE/stopped" ]; do sleep 0.05; done
        ;;
    stop) touch "$ENROLL_STATE/stopped" ;;
    exec)
        if [ "$2" = -i ]; then cat > "$ENROLL_STATE/enrolled-key";
        else printf '%s\n' "${FAKE_RPC_USER:-admin}"; fi
        ;;
    *) exit 2 ;;
esac
FAKE
chmod +x "$TMP/bin/tart"
export PATH="$TMP/bin:$PATH" ENROLL_STATE="$TMP"
bash "$ROOT/bin/enroll-tart-key.sh" owned-clone "$TMP/key.pub" > "$TMP/success.out" 2> "$TMP/success.err"
test -f "$TMP/stopped"
read -r type value comment < "$TMP/key.pub"
grep -Fxq "$type $value" "$TMP/enrolled-key"
grep -q 'run --no-graphics --no-audio --no-clipboard --no-usb-accessories' "$TMP/calls"
if grep -Eq '^run .*--(dir|vnc|disk)' "$TMP/calls"; then echo 'host sharing was enabled' >&2; exit 1; fi
if grep -q '^delete ' "$TMP/calls"; then echo 'consumer clone was deleted' >&2; exit 1; fi
rm "$TMP/stopped"
if FAKE_RPC_USER=root bash "$ROOT/bin/enroll-tart-key.sh" owned-clone "$TMP/key.pub" > "$TMP/root.out" 2> "$TMP/root.err"; then
    echo 'root RPC was accepted' >&2; exit 1
fi
grep -q 'non-root guest user' "$TMP/root.err"
test -f "$TMP/stopped"
if FAKE_VM_STATE=running bash "$ROOT/bin/enroll-tart-key.sh" occupied-clone "$TMP/key.pub" >/dev/null 2> "$TMP/occupied.err"; then
    echo 'running consumer VM was accepted' >&2; exit 1
fi
grep -q 'must be stopped' "$TMP/occupied.err"
if bash "$ROOT/bin/enroll-tart-key.sh" ghcr.io/other/vm "$TMP/key.pub" >/dev/null 2> "$TMP/remote.err"; then
    echo 'remote VM reference was accepted for enrollment' >&2; exit 1
fi
printf 'ssh-rsa invalid\n' > "$TMP/wrong-key.pub"
if bash "$ROOT/bin/enroll-tart-key.sh" owned-clone "$TMP/wrong-key.pub" >/dev/null 2> "$TMP/key.err"; then
    echo 'unapproved key type was accepted' >&2; exit 1
fi
echo 'ok: guest-user SSH enrollment uses RPC only, no host GUI/sharing, preserves the clone, rejects root and occupied VMs'
