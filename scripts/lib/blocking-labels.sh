#!/usr/bin/env bash
# Shared blocking-label predicate for trusted merge-arming paths.

mergepath_is_blocking_label() {
  case "${1:-}" in
    needs-external-review|needs-human-review|policy-violation|human-hold) return 0 ;;
    *) return 1 ;;
  esac
}

# Read one label per line and print the blocking subset as a CSV value.
mergepath_blocking_labels_csv() {
  local label result=""
  while IFS= read -r label || [ -n "$label" ]; do
    if mergepath_is_blocking_label "$label"; then
      result="${result:+$result,}$label"
    fi
  done
  printf '%s' "$result"
}
