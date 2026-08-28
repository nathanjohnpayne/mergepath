#!/usr/bin/env bash
# Validate the repository's identity-bearing PR description contract.
#
# This is the single entrypoint for PR-body validation. The required
# `Self-Review Required` gate, `scripts/gh-as-author.sh`, and any local check
# all route through it rather than re-implementing the checks, so there is one
# tested path instead of a shell copy and a YAML copy that must stay in sync
# (#1132).
#
# The body arrives on STDIN, never in argv: a PR body is attacker-controlled
# text on a fork PR, and stdin keeps it out of process listings and away from
# ARG_MAX. It reaches the markdown parser as stdin too, so it is never eval'd.
#
# $ROOT is resolved from this script's own location rather than the caller's
# CWD, so the policy path is absolute and a caller that runs from a
# subdirectory still validates against the right file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/pr-body-contract.sh
. "$ROOT/scripts/lib/pr-body-contract.sh"

PRINT_AUTHOR=false
case "${1:-}" in
  "") ;;
  --print-author) PRINT_AUTHOR=true ;;
  *)
    echo "usage: scripts/validate-pr-body.sh [--print-author] < pr-body.md" >&2
    exit 2
    ;;
esac

BODY="$(cat)"
# A concrete policy path is passed unconditionally. Passing "" here would skip
# the Authoring-Agent allow-list entirely and fail OPEN — see the exit-status
# contract on pr_body_agent_is_allowed.
pr_body_validate "$BODY" "$ROOT/.github/review-policy.yml"

if [ "$PRINT_AUTHOR" = true ]; then
  pr_body_authoring_agent "$BODY"
fi
