#!/usr/bin/env bash
# Decide whether a pull request can skip the lint-fast tooling-only checks
# (#2921).
#
# Changed paths are read from stdin, one per line, as `git diff --name-only`
# prints them against the PR's merge base. The repo declares which paths are
# content in .github/repo-lint-content-paths, one case glob per line (`*`
# also matches `/`; `#` starts a comment). The file is per repo and is NOT
# propagated: a consumer without one always runs the full set.
#
# Output, on stdout only:
#   tooling=false   every changed path is declared content and none is a
#                   tooling path; the caller may skip the tooling-only checks
#   tooling=true    anything else
# followed by `reason=<text>` and one `path: <classification> <path>` line per
# changed path, for the job log. The caller must treat any output other than
# an exact `tooling=false` first line as `tooling=true`.
#
# Fail toward running. Each of these answers tooling=true:
#   - an event other than pull_request (push to main, schedule, merge_group,
#     workflow_dispatch all run the full set);
#   - a missing, unreadable or empty glob file, or any line in it that is not
#     a well-formed relative glob;
#   - an empty changed-path list, or a path that is empty, absolute, holds a
#     `..` segment or a character outside the plain set git prints unquoted;
#   - a path that matches a tooling glob below, even when a content glob also
#     matches it (an ambiguous path is tooling);
#   - a path that matches no content glob.
# Only a list in which every path is matched content may skip.
#
# The tooling globs live HERE, not in the glob file, so a repo cannot declare
# them away. They cover this classifier, the glob file, the workflow that
# reads them, and every input the skippable checks read: scripts, tests,
# workflows, hooks, policy files and agent docs (tests/test_cloud_environment.sh
# reads docs/agents/). Editing either list is a tooling change, so the PR
# that edits them always runs the full set.

set -euo pipefail

usage() {
  echo "usage: repo-lint-tooling-scope.sh --event <event-name> [--root <dir>]" >&2
  exit 2
}

EVENT=''
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -ge 2 ] || usage
      EVENT="$2"
      shift 2
      ;;
    --root)
      [ "$#" -ge 2 ] || usage
      ROOT="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$EVENT" ] || usage
GLOB_FILE="$ROOT/.github/repo-lint-content-paths"

TOOLING_GLOBS='scripts/*
tests/*
.github/*
.claude/*
.codex/*
.cursor/*
.husky/*
docs/agents/*
docs/architecture/*
specs/*
rules/*
functions/*
packaging/*
mergepath/*
AGENTS.md
CLAUDE.md
REVIEW_POLICY.md
ai_agent_tooling_standard.md
.repo-template.yml
.mergepath-sync.yml
.mergepath-project-docs.yml
.sync-overrides.yml
.coderabbit.yml
.coderabbit.yaml
package.json
package-lock.json'

run_all() {
  printf 'tooling=true\nreason=%s\n' "$1"
  exit 0
}

if [ "$EVENT" != "pull_request" ]; then
  run_all "event $EVENT always runs the full set"
fi

if [ ! -f "$GLOB_FILE" ] || [ ! -r "$GLOB_FILE" ]; then
  run_all "no readable .github/repo-lint-content-paths"
fi
if ! glob_text=$(cat "$GLOB_FILE"); then
  run_all "cannot read .github/repo-lint-content-paths"
fi

content_globs=''
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  # A glob is a plain relative path or a directory followed by `/*`, so
  # `*`, `p*`, `*/x` or `**` cannot declare a wider tree than one directory.
  if ! printf '%s\n' "$line" | grep -Eq '^[A-Za-z0-9._-][A-Za-z0-9._/-]*(/\*)?$' \
     || [ "${line#/}" != "$line" ] \
     || case "/$line/" in */../*|*/./*) true ;; *) false ;; esac; then
    run_all "malformed content glob: $line"
  fi
  content_globs="$content_globs$line"$'\n'
done <<<"$glob_text"
[ -n "$content_globs" ] || run_all "no content globs declared"

matches_any() {
  local candidate="$1" patterns="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254 # the lists are case globs by design
    case "$candidate" in $pattern) return 0 ;; esac
  done <<<"$patterns"
  return 1
}

report=''
count=0
while IFS= read -r path || [ -n "$path" ]; do
  if [ -z "$path" ]; then
    run_all "empty line in the changed-path list"
  fi
  if ! printf '%s\n' "$path" | grep -Eq '^[A-Za-z0-9._@+,=-][A-Za-z0-9._@+,=/-]*$' \
     || case "/$path/" in */../*|*/./*|*//*) true ;; *) false ;; esac; then
    run_all "unclassifiable changed path: $path"
  fi
  if matches_any "$path" "$TOOLING_GLOBS"; then
    run_all "tooling path changed: $path"
  fi
  if ! matches_any "$path" "$content_globs"; then
    run_all "path is not declared content: $path"
  fi
  report="${report}path: content $path"$'\n'
  count=$((count + 1))
done

[ "$count" -gt 0 ] || run_all "empty changed-path list"

printf 'tooling=false\nreason=all %s changed paths are declared content\n%s' "$count" "$report"
