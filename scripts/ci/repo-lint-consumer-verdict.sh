#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [[ "$1" != check_[A-Za-z0-9_]* ]]; then
  echo "usage: repo-lint-consumer-verdict.sh check_NAME" >&2
  exit 2
fi

name="$1"
if grep -Eq "^${name}: SKIP \\("; then
  echo "SKIP"
else
  echo "exit 0"
fi
