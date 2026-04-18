#!/usr/bin/env bash
set -euo pipefail

# Extract the entries of a top-level YAML list from
# `.github/review-policy.yml` (or any file with the same flat
# schema). Prints each entry on its own line with surrounding
# quotes stripped.
#
# Usage: scripts/workflow/parse_policy_list.sh <config_path> <key>
#
# Example:
#   $ scripts/workflow/parse_policy_list.sh .github/review-policy.yml external_review_paths
#   src/auth/**
#   src/payments/**
#   **/*secret*
#   **/*credential*
#   .github/**
#
# Why a state-machine awk parser (not `awk '/^key:/,/^[^ ]/'`):
# the range-start pattern also matches the range-end condition on
# the same line — the header line starts with a non-space
# character, so a naive range parser silently matches only the
# header line and drops every list entry. See mergepath#54.
#
# A real YAML parser would be more correct but brings a dependency
# (python+PyYAML / ruby yaml / yq) that this script deliberately
# avoids — GitHub Actions ubuntu-latest runners have bash+awk+sed
# reliably; YAML parsers are less reliably present across minimal
# images. The callers already assume a flat structure and quoted
# list entries; this script is scoped to that narrow shape.

CONFIG="${1:?usage: parse_policy_list.sh <config_path> <key>}"
KEY="${2:?usage: parse_policy_list.sh <config_path> <key>}"

if [ ! -f "$CONFIG" ]; then
  echo "parse_policy_list.sh: config file not found: $CONFIG" >&2
  exit 1
fi

awk -v key="$KEY" '
  # Match the header line for the requested key at column 0.
  $0 ~ "^" key ":" { in_block = 1; next }
  # Any other line that starts at column 0 (not space, not comment)
  # ends the block — this is how we detect the next top-level key.
  in_block && /^[^[:space:]#]/ { in_block = 0 }
  # Inside the block, list items are indented lines starting with
  # a `-`. Blank lines and comment-only lines inside the block are
  # ignored. Inline comments (e.g. `- ".github/**"  # note`) and
  # surrounding quotes are stripped here so the downstream matcher
  # receives clean glob patterns.
  in_block && /^ *-/ {
    line = $0
    sub(/^ *- */, "", line)
    if (line ~ /^"/) {
      # Quoted entry: strip the leading `"`, then the closing `"`
      # plus any trailing whitespace and inline comment.
      sub(/^"/, "", line)
      sub(/"[[:space:]]*(#.*)?$/, "", line)
    } else {
      # Unquoted entry: strip only the trailing whitespace + comment.
      sub(/[[:space:]]+#.*$/, "", line)
    }
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    print line
  }
' "$CONFIG"
