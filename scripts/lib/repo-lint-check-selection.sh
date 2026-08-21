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
