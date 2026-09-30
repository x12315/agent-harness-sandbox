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
        REMOTE=${REMOTE:-alpha}
        DEST=${DEST:-agent-harness-sandbox}
        [[ $DEST =~ ^[a-zA-Z0-9_./-]+$ ]] || { echo "invalid remote directory: $DEST" >&2; exit 2; }
        ssh "$REMOTE" "cd \"\$HOME/$DEST\" && bash bin/run-case.sh '$CASE_ID'"
        ;;
    macos-tart)
        bash "$ROOT/bin/run-macos-case.sh" "$CASE_ID"
        ;;
    *) echo "unknown target for $CASE_ID: $TARGET" >&2; exit 2 ;;
esac
