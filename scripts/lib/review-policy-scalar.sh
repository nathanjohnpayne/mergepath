#!/usr/bin/env bash
# Shared reader for one top-level scalar in .github/review-policy.yml.

review_policy_scalar() {  # <file> <key>
  awk -v key="$2:" '
    /^[^[:space:]]/ && $1 == key {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^"/, "", $0)
      gsub(/^\047/, "", $0)
      gsub(/"[[:space:]]*(#.*)?$/, "", $0)
      gsub(/\047[[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$1"
}
