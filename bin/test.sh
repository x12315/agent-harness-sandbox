#!/usr/bin/env bash
# Run an agent test case on the backend declared by that case.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT=
if [ "${1:-}" = --project ]; then
    PROJECT=${2:?usage: bin/test.sh --project <trusted-project> <case-id>}
    shift 2
fi
CASE_ID=${1:?usage: bin/test.sh [--project <trusted-project>] <case-id>}
[[ $CASE_ID =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid case id: $CASE_ID" >&2; exit 2; }
[ "$#" = 1 ] || { echo 'unexpected arguments' >&2; exit 2; }
CASE_DIR=$ROOT/cases/$CASE_ID
SNAPSHOT=
MANIFEST=
trap 'rm -f "${MANIFEST:-}"; [ -z "$SNAPSHOT" ] || rm -rf "$SNAPSHOT"' EXIT
if [ -n "$PROJECT" ]; then
    command -v node >/dev/null || { echo 'project cases require Node.js on the invoking host' >&2; exit 2; }
    SNAPSHOT=$(mktemp -d)
    SNAPSHOT=$(cd "$SNAPSHOT" && pwd -P)
    node "$ROOT/bin/prepare-project-case.mjs" "$PROJECT" "$CASE_ID" "$SNAPSHOT"
    CASE_DIR=$SNAPSHOT/tests/sandbox/$CASE_ID
    export AHSB_CASE_DIR="$CASE_DIR" AHSB_INPUT_ROOT="$SNAPSHOT"
fi
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
                setpriv --no-new-privs bash "$ROOT/bin/run-case.sh" "$CASE_ID"
                exit "$?"
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
        SOURCE_PATHS=(bin mock)
        [ -n "$PROJECT" ] || SOURCE_PATHS+=("cases/$CASE_ID")
        (
            cd "$ROOT"
            find "${SOURCE_PATHS[@]}" -type f ! -path '*/__pycache__/*' \
                -exec "${HASH[@]}" {} + | LC_ALL=C sort
        ) > "$MANIFEST"
        if [ -n "$PROJECT" ]; then
            cp "$MANIFEST" "$SNAPSHOT/sandbox-source.sha256"
            TAR_CREATE=(tar -czf -)
            [ "$(uname -s)" != Darwin ] || TAR_CREATE+=(--no-xattrs)
            COPYFILE_DISABLE=1 "${TAR_CREATE[@]}" -C "$SNAPSHOT" . | ssh "$REMOTE" "
                set -eu
                cd \"\$HOME/$DEST\"
                check=\$(mktemp -d)
                trap 'rm -rf \"\$check\"' EXIT
                tar -xzf - -C \"\$check\"
                find bin mock -type f ! -path '*/__pycache__/*' -exec sha256sum {} + > \"\$check/remote.unsorted\"
                LC_ALL=C sort \"\$check/remote.unsorted\" > \"\$check/remote.sha256\"
                cmp -s \"\$check/sandbox-source.sha256\" \"\$check/remote.sha256\" || {
                    echo 'local/remote sandbox source mismatch; not running $CASE_ID. Coordinate a safe sync or set DEST.' >&2
                    exit 2
                }
                rm \"\$check/remote.unsorted\" \"\$check/remote.sha256\"
                actual=\$(mktemp)
                trap 'rm -f \"\$actual\"; rm -rf \"\$check\"' EXIT
                (cd \"\$check\" && find . -type f ! -path './project-source.sha256' ! -path './sandbox-source.sha256' -exec sha256sum {} + | LC_ALL=C sort) > \"\$actual\"
                cmp -s \"\$check/project-source.sha256\" \"\$actual\" || {
                    echo 'project input snapshot checksum mismatch' >&2; exit 2
                }
                AHSB_CASE_DIR=\"\$check/tests/sandbox/$CASE_ID\" AHSB_INPUT_ROOT=\"\$check\" \\
                    SOURCE_MANIFEST=\"\$check/sandbox-source.sha256\" bash bin/run-case.sh '$CASE_ID'
            "
            exit "$?"
        fi
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
