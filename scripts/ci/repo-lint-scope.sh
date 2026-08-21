#!/usr/bin/env bash
# Classify whether a repo-lint invocation needs the expensive regression lane.
#
# Changed paths are read from stdin, one per line. Pull requests use the fast
# lane unless they touch CI/governance implementation. Every non-PR event runs
# deep CI so main pushes, the daily backstop, and manual diagnostics retain the
# complete regression surface.

set -euo pipefail

usage() {
  echo "usage: repo-lint-scope.sh --event <event-name>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
[ "$1" = "--event" ] || usage
EVENT="$2"

deep=false
if [ "$EVENT" != "pull_request" ]; then
  deep=true
else
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      .github/*|scripts/*|tests/*|specs/*|rules/*|docs/agents/*|docs/architecture/*|.mergepath-sync.yml|.repo-template.yml|AGENTS.md|REVIEW_POLICY.md|ai_agent_tooling_standard.md)
        deep=true
        break
        ;;
    esac
  done
fi

echo "deep=$deep"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "deep=$deep" >> "$GITHUB_OUTPUT"
fi
