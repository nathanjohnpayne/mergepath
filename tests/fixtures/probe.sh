#!/usr/bin/env bash
# Probe helper: checks whether each path in $@ exists and reports
# a count, without ever failing the script even if individual probes
# error out. Used by the smoke-test infrastructure as a tolerant
# health check across a set of optional artifacts.
set +e

count=0
for path in "$@"; do
  ls "$path" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    count=$((count + 1))
  fi
done

echo "$count"
