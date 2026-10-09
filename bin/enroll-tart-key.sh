#!/usr/bin/env bash
# Add a receiver's SSH public key through guest-user RPC; never use a shared private key.
# Usage: enroll-tart-key.sh <stopped-local-clone> <ed25519-public-key-file> [guest-user]
# Stops only the VM it starts; keeps the caller's clone and private diagnostic logs.
set -euo pipefail
umask 077
VM=${1:?usage: enroll-tart-key.sh <local-vm> <public-key-file> [guest-user]}
PUBLIC_KEY=${2:?public key file required}
GUEST_USER=${3:-admin}
[[ $VM =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'enrollment requires a local VM name' >&2; exit 2; }
[[ $GUEST_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 2
for tool in tart ssh-keygen nice node; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }; done
[ -f "$PUBLIC_KEY" ] && [ -r "$PUBLIC_KEY" ] || { echo 'public key missing or unreadable' >&2; exit 2; }
[ "$(wc -l < "$PUBLIC_KEY" | tr -d ' ')" = 1 ] || { echo 'one newline-terminated public key required' >&2; exit 2; }
read -r key_type key_value key_comment < "$PUBLIC_KEY"
[ "$key_type" = ssh-ed25519 ] || { echo 'only ED25519 public keys are accepted' >&2; exit 2; }
ssh-keygen -lf "$PUBLIC_KEY" >/dev/null
[ "$(tart get "$VM" | awk 'NR==2 {print $NF}')" = stopped ] || { echo 'enrollment clone must be stopped' >&2; exit 2; }
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ahsb-enroll.XXXXXX")
started=0
cleanup() {
    local status=$?
    trap - EXIT
    if [ "$started" = 1 ]; then
        tart stop "$VM" >/dev/null 2>&1 || status=1
        wait "$RUN_PID" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
nice -n 10 tart run --no-graphics --no-audio --no-clipboard --no-usb-accessories "$VM" > "$LOG_DIR/vm.log" 2>&1 &
RUN_PID=$!
started=1
tart_rpc() {
    node -e '
        const { spawnSync } = require("node:child_process");
        const result = spawnSync("tart", process.argv.slice(1), { timeout: 5000, stdio: ["inherit", "pipe", "pipe"] });
        if (result.stdout) process.stdout.write(result.stdout);
        if (result.stderr) process.stderr.write(result.stderr);
        if (result.error) console.error(result.error.message);
        process.exit(result.status === 0 ? 0 : 1);
    ' "$@"
}
ready=0
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
    kill -0 "$RUN_PID" 2>/dev/null || { echo "Tart exited; see $LOG_DIR/vm.log" >&2; exit 1; }
    if user=$(tart_rpc exec "$VM" /usr/bin/id -un 2> "$LOG_DIR/rpc.err"); then
        [ "$user" = "$GUEST_USER" ] && [ "$user" != root ] || { echo 'RPC must run as the expected non-root guest user' >&2; exit 2; }
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" = 1 ] || { echo "guest-user RPC unavailable; see $LOG_DIR/rpc.err" >&2; exit 1; }
{ printf 'ssh-ed25519 %s\n' "$key_value"; } | tart_rpc exec -i "$VM" /bin/sh -c '
    set -eu
    umask 077
    read -r key
    [ ! -L "$HOME/.ssh" ] && [ ! -L "$HOME/.ssh/authorized_keys" ] || exit 2
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    grep -Fxq "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    /bin/sync
'
printf 'guest SSH key enrolled; clone=%s logs=%s\n' "$VM" "$LOG_DIR"
