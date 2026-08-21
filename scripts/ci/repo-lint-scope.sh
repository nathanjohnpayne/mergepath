#!/usr/bin/env bash
# Select the expensive repo-lint wrappers affected by an invocation.
#
# Changed paths are read from stdin, one per line. Pull requests use the fast
# lane unless they touch CI/governance implementation. Direct wrapper changes
# and dependencies declared in repo-lint-dependencies.json select a partial
# deep lane. Every non-PR event and every unknown governance change runs the
# complete surface.

set -euo pipefail

usage() {
  echo "usage: repo-lint-scope.sh --event <event-name>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
[ "$1" = "--event" ] || usage
EVENT="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH="$ROOT/scripts/ci/repo-lint-dependencies.json"

if [ ! -f "$GRAPH" ] || ! command -v jq >/dev/null 2>&1 \
   || ! jq -e '
     .version == 1
     and (.full_triggers | type == "array")
     and all(.full_triggers[]; type == "string")
     and (.wrappers | type == "object")
     and all(.wrappers | keys[]; test("^check_[A-Za-z0-9_]+$"))
     and all(.wrappers | to_entries[];
       (.value | type == "array")
       and all(.value[]; type == "string"))
   ' "$GRAPH" >/dev/null 2>&1; then
  echo "repo-lint scope: dependency graph unavailable or invalid; failing closed" >&2
  deep=true
  full=true
  checks='[]'
  printf 'deep=%s\nfull=%s\nchecks=%s\n' "$deep" "$full" "$checks"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'deep=%s\nfull=%s\nchecks=%s\n' "$deep" "$full" "$checks" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if ! full_patterns=$(jq -r '.full_triggers[]' "$GRAPH") \
   || ! wrapper_patterns=$(jq -r '.wrappers | to_entries[] | .key as $wrapper | .value[] | [$wrapper, .] | @tsv' "$GRAPH"); then
  echo "repo-lint scope: dependency graph parsing failed; failing closed" >&2
  deep=true
  full=true
  checks='[]'
  printf 'deep=%s\nfull=%s\nchecks=%s\n' "$deep" "$full" "$checks"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'deep=%s\nfull=%s\nchecks=%s\n' "$deep" "$full" "$checks" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

matches_pattern() {
  local candidate="$1" pattern="$2"
  case "$candidate" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

selected=''
select_wrapper() {
  local wrapper="$1"
  case "
$selected
" in
    *"
$wrapper
"*) ;;
    *) selected="${selected}${wrapper}
" ;;
  esac
}

deep=false
full=false
if [ "$EVENT" != "pull_request" ]; then
  deep=true
  full=true
else
  while IFS= read -r path; do
    [ -n "$path" ] || continue

    while IFS= read -r pattern; do
      if matches_pattern "$path" "$pattern"; then
        deep=true
        full=true
        break
      fi
    done <<<"$full_patterns"
    [ "$full" = "false" ] || break

    matched=false
    case "$path" in
      scripts/ci/check_*)
        select_wrapper "${path##*/}"
        deep=true
        matched=true
        ;;
    esac

    while IFS=$'\t' read -r wrapper pattern; do
      [ -n "$wrapper" ] || continue
      if matches_pattern "$path" "$pattern"; then
        select_wrapper "$wrapper"
        deep=true
        matched=true
      fi
    done <<<"$wrapper_patterns"

    # CI implementation is fail-closed. A path that is neither a direct
    # wrapper nor an explicitly declared dependency receives the full net.
    if [ "$matched" = "false" ]; then
      case "$path" in
        .github/*|scripts/*|tests/*|specs/*|rules/*|docs/agents/*|docs/architecture/*|.mergepath-sync.yml|.repo-template.yml|AGENTS.md|REVIEW_POLICY.md|ai_agent_tooling_standard.md)
          deep=true
          full=true
          break
          ;;
      esac
    fi
  done
fi

if [ -n "$selected" ]; then
  checks=$(printf '%s' "$selected" | sed '/^$/d' | LC_ALL=C sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')
else
  checks='[]'
fi

printf 'deep=%s\nfull=%s\nchecks=%s\n' "$deep" "$full" "$checks"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'deep=%s\nfull=%s\nchecks=%s\n' "$deep" "$full" "$checks" >> "$GITHUB_OUTPUT"
fi
