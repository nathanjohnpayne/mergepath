#!/usr/bin/env bash
# Shared reader for one top-level scalar in .github/review-policy.yml.

review_policy_scalar() {  # <file> <key>
  awk -v key="$2:" '
    function strip_yaml_comment(value,    i, c, next_c, quote, escaped, sq) {
      sq = sprintf("%c", 39)
      for (i = 1; i <= length(value); i++) {
        c = substr(value, i, 1)
        next_c = substr(value, i + 1, 1)
        if (quote == "\"") {
          if (escaped) {
            escaped = 0
          } else if (c == "\\") {
            escaped = 1
          } else if (c == "\"") {
            quote = ""
          }
        } else if (quote == sq) {
          if (c == sq && next_c == sq) {
            i++
          } else if (c == sq) {
            quote = ""
          }
        } else if (i == 1 && (c == "\"" || c == sq)) {
          quote = c
        } else if (c == "#" && (i == 1 || substr(value, i - 1, 1) ~ /[[:space:]]/)) {
          return substr(value, 1, i - 1)
        }
      }
      return value
    }
    /^[^[:space:]]/ && $1 == key {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      $0 = strip_yaml_comment($0)
      sub(/[[:space:]]+$/, "", $0)
      if ((substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") \
          || (substr($0, 1, 1) == sprintf("%c", 39) && substr($0, length($0), 1) == sprintf("%c", 39))) {
        $0 = substr($0, 2, length($0) - 2)
      }
      print
      exit
    }
  ' "$1"
}
