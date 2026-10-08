#!/usr/bin/env bash
# Run an agent test case on the backend declared by that case.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CASE_ID=${1:?usage: bin/test.sh <case-id>}
[[ $CASE_ID =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid case id: $CASE_ID" >&2; exit 2; }
CASE_DIR=$ROOT/cases/$CASE_ID
[ -f "$CASE_DIR/cmd" ] || { echo "missing case: $CASE_ID" >&2; exit 2; }

TARGET=linux-vmspawn
[ -f "$CASE_DIR/target" ] && read -r TARGET < "$CASE_DIR/target"
case "$TARGET" in
    linux-vmspawn)
        EXECUTION=${EXECUTION:-remote}
        case "$EXECUTION" in
            local)
                [ "$(uname -s)" = Linux ] || { echo 'local linux-vmspawn requires a Linux host; on macOS use a linux-tart case or remote execution' >&2; exit 2; }
                for tool in systemd-vmspawn setpriv; do
                    command -v "$tool" >/dev/null || { echo "missing local tool: $tool" >&2; exit 2; }
                done
                [ "$(id -u)" != 0 ] || { echo 'local vmspawn must run as a non-root user' >&2; exit 2; }
                exec setpriv --no-new-privs bash "$ROOT/bin/run-case.sh" "$CASE_ID"
                ;;
            remote) ;;
            *) echo 'EXECUTION must be local or remote' >&2; exit 2 ;;
        esac
        REMOTE=${REMOTE:-alpha}
        DEST=${DEST:-agent-harness-sandbox}
        [[ $DEST =~ ^[a-zA-Z0-9_./-]+$ ]] || { echo "invalid remote directory: $DEST" >&2; exit 2; }
        if command -v shasum >/dev/null; then HASH=(shasum -a 256);
        elif command -v sha256sum >/dev/null; then HASH=(sha256sum);
        else echo 'missing SHA256 tool: shasum or sha256sum' >&2; exit 2; fi
        MANIFEST=$(mktemp)
        trap 'rm -f "$MANIFEST"' EXIT
        (
            cd "$ROOT"
            find bin mock "cases/$CASE_ID" -type f ! -path '*/__pycache__/*' \
                -exec "${HASH[@]}" {} + | LC_ALL=C sort
        ) > "$MANIFEST"
        ssh "$REMOTE" "cd \"\$HOME/$DEST\" &&
            check=\$(mktemp -d) &&
            trap 'rm -rf \"\$check\"' EXIT &&
            cat > \"\$check/source.sha256\" &&
            find bin mock 'cases/$CASE_ID' -type f ! -path '*/__pycache__/*' -exec sha256sum {} + > \"\$check/unsorted.sha256\" &&
            LC_ALL=C sort \"\$check/unsorted.sha256\" > \"\$check/remote.sha256\" &&
            if ! cmp -s \"\$check/source.sha256\" \"\$check/remote.sha256\"; then
                echo 'local/remote source mismatch; not running $CASE_ID. Coordinate a safe sync or set DEST to a matching checkout.' >&2
                diff -u \"\$check/source.sha256\" \"\$check/remote.sha256\" >&2 || true
                exit 2
            fi &&
            SOURCE_MANIFEST=\"\$check/source.sha256\" bash bin/run-case.sh '$CASE_ID'" < "$MANIFEST"
        ;;
    macos-tart|linux-tart)
        [ "${EXECUTION:-local}" = local ] || { echo 'Tart cases currently require EXECUTION=local' >&2; exit 2; }
        bash "$ROOT/bin/run-tart-case.sh" "$CASE_ID"
        ;;
    *) echo "unknown target for $CASE_ID: $TARGET" >&2; exit 2 ;;
esac
