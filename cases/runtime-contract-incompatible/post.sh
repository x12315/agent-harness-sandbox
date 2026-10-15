#!/usr/bin/env bash
set -euo pipefail
touch "${1:?}/post-was-called"
exit 1
