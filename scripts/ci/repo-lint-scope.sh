#!/usr/bin/env bash
# Select the expensive repo-lint wrappers affected by an invocation.
#
# Changed paths are read from stdin, one per line. Pull requests use the fast
# lane unless they touch CI/governance implementation. Direct wrapper changes
# and dependencies declared in repo-lint-dependencies.json select a partial
# deep lane. Every non-PR event and every unknown governance change runs the
# complete surface.
#
# Consumer mode. On a consumer checkout the deep lane is only the kit's
# --self-test suites: the consumer-safety and residue harnesses SKIP there
# (marker-first), and the self-tests build their own fixtures rather than
# reading the repository's specs, docs, or app code. A consumer's specs/,
# tests/, scripts/ and docs/agents/ also hold its OWN product files, which
# the hub-shaped fail-closed rules below would send to the full deep net on
# almost every feature PR (26 of 34 green fiveacross PR runs measured
# 2026-10-09 ran the full deep lane, 23-36 min each). So on a consumer:
#   - the governance-document full triggers (CONSUMER_DOC_ONLY) stop forcing
#     the full surface — their only deep readers are the hub-only harnesses;
#   - the unknown-path catch-all is narrowed to the kit-delivered CI shapes
#     (consumer_ci_surface), so consumer-local specs, app tests, and .mjs
#     scripts take the fast lane while any delivered CI file still fails
#     closed. tests/test_repo_lint_optimization.sh proves, against
#     .mergepath-sync.yml on the hub, that every manifest-delivered path the
#     hub would send to deep CI is still deep here unless it is a
#     CONSUMER_DOC_ONLY document.
# Declared wrapper dependencies and direct wrapper changes select exactly as
# on the hub, and non-PR events stay full. A checkout is a consumer only when
# BOTH hub markers (scripts/sync-to-downstream.sh, .mergepath-sync.yml) are
# absent, so a hub that loses one marker, or a consumer carrying one as
# bootstrap residue, keeps the stricter hub rules.

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

MODE=hub
if [ ! -f "$ROOT/scripts/sync-to-downstream.sh" ] && [ ! -f "$ROOT/.mergepath-sync.yml" ]; then
  MODE=consumer
fi

# Governance documents whose only deep-lane readers are the hub-only
# consumer-safety and residue harnesses. Consumer mode only.
consumer_doc_only() {
  case "$1" in
    specs/*|rules/*|docs/agents/*|docs/architecture/*|AGENTS.md|REVIEW_POLICY.md|ai_agent_tooling_standard.md|.repo-template.yml) return 0 ;;
  esac
  return 1
}

# The kit-delivered CI implementation shapes. Consumer mode only: an
# unmatched path here still fails closed to the full deep surface.
consumer_ci_surface() {
  case "$1" in
    .github/*|scripts/ci/*|scripts/lib/*|scripts/workflow/*|scripts/hooks/*|scripts/phase-4b/*|scripts/gh-projects/*|scripts/*.sh|scripts/*.cjs|tests/test_*|tests/fixtures/*) return 0 ;;
  esac
  return 1
}

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
        if [ "$MODE" = "consumer" ] && consumer_doc_only "$path"; then
          break
        fi
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
      if [ "$MODE" = "consumer" ]; then
        if consumer_ci_surface "$path"; then
          deep=true
          full=true
          break
        fi
      else
        case "$path" in
          .github/*|scripts/*|tests/*|specs/*|rules/*|docs/agents/*|docs/architecture/*|.mergepath-sync.yml|.repo-template.yml|AGENTS.md|REVIEW_POLICY.md|ai_agent_tooling_standard.md)
            deep=true
            full=true
            break
            ;;
        esac
      fi
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
