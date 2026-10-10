#!/usr/bin/env bash
set -euo pipefail
D=$1
test "$(cat "$D/guest/tmp/ah.rc")" = 0
test ! -s "$D/guest/tmp/ah.err"
for marker in 'clone EMPTY_PASS' 'clone-window EMPTY_PASS' 'clone PROFILE_PASS' 'clone-window PROFILE_PASS' 'clone NAMED_PASS' 'clone CHILD_PASS' 'clone ARCHIVED-CHILD_PASS' 'fork FORK_PASS' 'fork-window FORK_PASS' CLONE_LINEAGE_PASS; do
    grep -Fq "$marker" "$D/guest/tmp/ah.out"
done
echo 'ok: unused clones are recoverable; named clones, descendants, and forks retain Pi lineage'
