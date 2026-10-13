#!/usr/bin/env bash
# Shared selector for the expensive repo-lint harnesses.

if [ "${REPO_LINT_CHECK_SELECTION_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
REPO_LINT_CHECK_SELECTION_LOADED=1

REPO_LINT_SELECTION_FULL="${REPO_LINT_FULL:-true}"
REPO_LINT_SELECTION_JSON="${REPO_LINT_CHECKS_JSON:-[]}"

case "$REPO_LINT_SELECTION_FULL" in
  true|false) ;;
  *)
    echo "repo-lint selection: REPO_LINT_FULL must be true or false" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1 \
   || ! jq -e 'type == "array" and all(.[]; type == "string" and test("^check_[A-Za-z0-9_]+$"))' \
        <<<"$REPO_LINT_SELECTION_JSON" >/dev/null 2>&1; then
  echo "repo-lint selection: REPO_LINT_CHECKS_JSON must be an array of check_* names" >&2
  return 1 2>/dev/null || exit 1
fi

repo_lint_check_is_selected() {
  local wrapper="$1"
  if [ "$REPO_LINT_SELECTION_FULL" = "true" ]; then
    return 0
  fi
  jq -e --arg wrapper "$wrapper" 'index($wrapper) != null' \
    <<<"$REPO_LINT_SELECTION_JSON" >/dev/null
}

# Sharding (#1655). REPO_LINT_SHARD="<index>/<count>" splits a replay over
# independent legs: a caller numbers its candidates in one stable order and
# runs those `repo_lint_shard_owns <ordinal>` admits. The default 1/1 owns
# everything; a malformed value fails closed rather than silently running an
# empty or a duplicate shard.
REPO_LINT_SELECTION_SHARD="${REPO_LINT_SHARD:-1/1}"
case "$REPO_LINT_SELECTION_SHARD" in
  [1-9]/[1-9]|[1-9]/[1-9][0-9]|[1-9][0-9]/[1-9][0-9]) ;;
  *)
    echo "repo-lint selection: REPO_LINT_SHARD must be <index>/<count> (got '$REPO_LINT_SELECTION_SHARD')" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
REPO_LINT_SELECTION_SHARD_INDEX="${REPO_LINT_SELECTION_SHARD%%/*}"
REPO_LINT_SELECTION_SHARD_COUNT="${REPO_LINT_SELECTION_SHARD##*/}"
if [ "$REPO_LINT_SELECTION_SHARD_INDEX" -gt "$REPO_LINT_SELECTION_SHARD_COUNT" ]; then
  echo "repo-lint selection: REPO_LINT_SHARD index exceeds count (got '$REPO_LINT_SELECTION_SHARD')" >&2
  return 1 2>/dev/null || exit 1
fi

# $1 = 0-based ordinal of a candidate in the caller's stable order.
repo_lint_shard_owns() {
  local ordinal="$1"
  case "$ordinal" in
    ''|*[!0-9]*)
      echo "repo-lint selection: shard ordinal must be a non-negative integer (got '$ordinal')" >&2
      return 2
      ;;
  esac
  [ $((ordinal % REPO_LINT_SELECTION_SHARD_COUNT)) -eq $((REPO_LINT_SELECTION_SHARD_INDEX - 1)) ]
}
