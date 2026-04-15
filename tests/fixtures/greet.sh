#!/usr/bin/env bash
# Small greeting helper used as a fixture by the smoke-test
# infrastructure. Prints "Hello, <name>!" given a name argument.
set -euo pipefail

NAME=${1:-}
echo "Hello, ${NAME}!"
