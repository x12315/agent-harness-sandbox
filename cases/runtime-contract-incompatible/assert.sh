#!/usr/bin/env bash
set -euo pipefail
touch "${1:?}/assert-was-called"
exit 1
