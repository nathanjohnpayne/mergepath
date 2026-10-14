#!/usr/bin/env bash
# Select the expensive repo-lint wrappers affected by an invocation.
#
# Changed paths are read from stdin, one per line. Pull requests use the fast
# lane unless they touch CI/governance implementation. Direct wrapper changes
# and dependencies declared in repo-lint-dependencies.json select a partial
# deep lane. Every non-PR event and every unknown governance change runs the
# complete surface.
#
# Outputs (one `key=value` line each, also appended to $GITHUB_OUTPUT):
#   deep            - any deep-safety leg runs.
#   full            - every enrolled self-test and both harness lattices run
#                     in full (the fail-closed catch-all).
#   checks          - JSON array of the selected check_* wrappers.
#   consumer_replay - the sharded replay legs re-run EVERY wired wrapper on
#                     the consumer-shaped fixture. Otherwise the consumer leg
#                     runs the harness in smoke mode: only the selected
#                     wrappers plus its structural #979 guards (#1655).
#   self_tests      - at least one selected wrapper has an enrolled
#                     `--self-test` step (the graph's `self_tests` list), so
#                     the self-test legs have work to do.
#
# Trigger classes in the graph, from widest to narrowest effect:
#   full_triggers            - the lane's own definition (workflow, this
#                              classifier, the graph, the harnesses and the
#                              shared selector). Fail closed to everything.
#   consumer_replay_triggers - inputs that define the consumer SHAPE (sync
#                              manifest, bootstrap exclusions, the fixture
#                              model and the wrapper contract). Select the
#                              full consumer replay without forcing every
#                              self-test.
#   deep_triggers            - governance documents. Their only deep-lane
#                              readers are the harnesses, so they request the
#                              deep legs in smoke mode; the complete replay
#                              runs for them on push to main and on the
#                              daily schedule.
#   wrappers                 - changed path -> owning wrapper(s).
# A propagation-lane head (`--head-ref mergepath-sync/...`) runs the complete
# surface: that is the PR whose delivered shape matters, on every repo.
# The replay harness itself is hub-only (marker-first SKIP elsewhere), so
# consumer mode always reports `consumer_replay=false` and the replay legs
# never spin up on a consumer for nothing.
#
# Consumer mode. On a consumer checkout the deep lane is only the kit's
# --self-test suites: the consumer-safety and residue harnesses SKIP there
# (marker-first), and the self-tests build their own fixtures rather than
# reading the repository's specs, docs, or app code. A consumer's specs/,
# tests/, scripts/ and docs/agents/ also hold its OWN product files, which
# the hub-shaped fail-closed rules below would send to the full deep net on
# almost every feature PR (26 of 34 green fiveacross PR runs measured
# 2026-10-09 ran the full deep lane, 23-36 min each). So on a consumer:
#   - the governance-document triggers (CONSUMER_DOC_ONLY) stop requesting
#     deep CI at all — their only deep readers are the hub-only harnesses;
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
  echo "usage: repo-lint-scope.sh --event <event-name> [--head-ref <ref>]" >&2
  exit 2
}

EVENT=''
HEAD_REF=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -ge 2 ] || usage
      EVENT="$2"
      shift 2
      ;;
    --head-ref)
      [ "$#" -ge 2 ] || usage
      HEAD_REF="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$EVENT" ] || usage
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH="$ROOT/scripts/ci/repo-lint-dependencies.json"

emit() {
  printf 'deep=%s\nfull=%s\nchecks=%s\nconsumer_replay=%s\nself_tests=%s\n' "$1" "$2" "$3" "$4" "$5"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'deep=%s\nfull=%s\nchecks=%s\nconsumer_replay=%s\nself_tests=%s\n' "$1" "$2" "$3" "$4" "$5" >> "$GITHUB_OUTPUT"
  fi
}

MODE=hub
if [ ! -f "$ROOT/scripts/sync-to-downstream.sh" ] && [ ! -f "$ROOT/.mergepath-sync.yml" ]; then
  MODE=consumer
fi

# Fail closed: every leg, including the replay — except on a consumer, which
# has no replay harness to run (it SKIPs marker-first), so spinning the
# replay legs up there would only burn runners.
fail_closed() {
  local replay=true
  [ "$MODE" = "hub" ] || replay=false
  emit true true '[]' "$replay" true
  exit 0
}

if [ ! -f "$GRAPH" ] || ! command -v jq >/dev/null 2>&1 \
   || ! jq -e '
     .version == 1
     and (.full_triggers | type == "array")
     and all(.full_triggers[]; type == "string")
     and ((.consumer_replay_triggers // []) | type == "array")
     and all((.consumer_replay_triggers // [])[]; type == "string")
     and ((.deep_triggers // []) | type == "array")
     and all((.deep_triggers // [])[]; type == "string")
     and ((.self_tests // []) | type == "array")
     and all((.self_tests // [])[]; type == "string" and test("^check_[A-Za-z0-9_]+$"))
     and (.wrappers | type == "object")
     and all(.wrappers | keys[]; test("^check_[A-Za-z0-9_]+$"))
     and all(.wrappers | to_entries[];
       (.value | type == "array")
       and all(.value[]; type == "string"))
   ' "$GRAPH" >/dev/null 2>&1; then
  echo "repo-lint scope: dependency graph unavailable or invalid; failing closed" >&2
  fail_closed
fi

if ! full_patterns=$(jq -r '.full_triggers[]' "$GRAPH") \
   || ! replay_patterns=$(jq -r '(.consumer_replay_triggers // [])[]' "$GRAPH") \
   || ! deep_patterns=$(jq -r '(.deep_triggers // [])[]' "$GRAPH") \
   || ! self_test_wrappers=$(jq -r '(.self_tests // [])[]' "$GRAPH") \
   || ! wrapper_patterns=$(jq -r '.wrappers | to_entries[] | .key as $wrapper | .value[] | [$wrapper, .] | @tsv' "$GRAPH"); then
  echo "repo-lint scope: dependency graph parsing failed; failing closed" >&2
  fail_closed
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

# Prose beside the implementation (scripts/**/README.md and the like). No
# wrapper executes it, so it never requests the deep lane by shape alone.
implementation_doc() {
  case "$1" in
    scripts/*.md|tests/*.md) return 0 ;;
  esac
  return 1
}

matches_pattern() {
  local candidate="$1" pattern="$2"
  # shellcheck disable=SC2254 # graph entries are case globs by design
  case "$candidate" in
    $pattern) return 0 ;;
    *) return 1 ;;
  esac
}

matches_any() {
  local candidate="$1" patterns="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if matches_pattern "$candidate" "$pattern"; then
      return 0
    fi
  done <<<"$patterns"
  return 1
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
consumer_replay=false
if [ "$EVENT" != "pull_request" ]; then
  deep=true
  full=true
  consumer_replay=true
else
  case "$HEAD_REF" in
    mergepath-sync/*)
      deep=true
      full=true
      consumer_replay=true
      ;;
  esac

  while IFS= read -r path; do
    [ "$full" = "false" ] || break
    [ -n "$path" ] || continue
    # Prose beside the implementation is checked first: a README inside a
    # declared directory glob (scripts/phase-4b/*) is still prose.
    if implementation_doc "$path"; then
      continue
    fi

    if matches_any "$path" "$full_patterns"; then
      if [ "$MODE" = "consumer" ] && consumer_doc_only "$path"; then
        :
      else
        deep=true
        full=true
        consumer_replay=true
        break
      fi
    fi

    matched=false
    if matches_any "$path" "$replay_patterns"; then
      deep=true
      consumer_replay=true
      matched=true
    fi

    if matches_any "$path" "$deep_patterns"; then
      if [ "$MODE" = "consumer" ] && consumer_doc_only "$path"; then
        :
      else
        deep=true
      fi
      matched=true
    fi

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
          consumer_replay=true
          break
        fi
      else
        case "$path" in
          .github/*|scripts/*|tests/*|specs/*|rules/*|docs/agents/*|docs/architecture/*|.mergepath-sync.yml|.repo-template.yml|AGENTS.md|REVIEW_POLICY.md|ai_agent_tooling_standard.md)
            deep=true
            full=true
            consumer_replay=true
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

# The self-test legs run for a full selection, or when a selected wrapper is
# enrolled in them. A selection of lint-fast-only wrappers leaves those legs
# idle, so they are not started.
self_tests=false
if [ "$full" = "true" ]; then
  self_tests=true
elif [ -n "$selected" ]; then
  while IFS= read -r wrapper; do
    [ -n "$wrapper" ] || continue
    case "
$selected
" in
      *"
$wrapper
"*) self_tests=true ;;
    esac
  done <<<"$self_test_wrappers"
fi

if [ "$MODE" = "consumer" ]; then
  consumer_replay=false
fi

emit "$deep" "$full" "$checks" "$consumer_replay" "$self_tests"
