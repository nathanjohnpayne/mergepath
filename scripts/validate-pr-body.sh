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
# --self-review-only checks ONLY that a real `## Self-Review` heading is
# present, through the same markdown-aware parser as full validation. It reads
# no policy and makes no claim about `Authoring-Agent:`.
#
# It exists so the required `Self-Review Required` gate can route through this
# single entrypoint rather than invoking the parser directly, without that gate
# also enforcing the identity contract -- which is a separate policy change
# (#1137).
#
# LANDS BEFORE ITS CALLER, deliberately. The gate loads this script from the
# repository's DEFAULT BRANCH, so a flag added in the same change that uses it
# does not exist when the gate runs and the required check dies on `usage:`
# (#1132, hit twice). Adding the flag in its own change means the default
# branch already understands it by the time any workflow passes it.
SELF_REVIEW_ONLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --print-author) PRINT_AUTHOR=true; shift ;;
    --self-review-only) SELF_REVIEW_ONLY=true; shift ;;
    *)
      echo "usage: scripts/validate-pr-body.sh [--print-author] [--self-review-only] < pr-body.md" >&2
      exit 2
      ;;
  esac
done

BODY="$(cat)"
if [ "$SELF_REVIEW_ONLY" = true ]; then
  if pr_body_has_self_review "$BODY"; then
    echo "Self-Review section found."
    exit 0
  fi
  echo "PR description must contain a '## Self-Review' section." >&2
  echo "A heading inside a fenced code block does not count." >&2
  echo "Required items: correctness, regression risk, style/conventions, test coverage, security/dependency hygiene." >&2
  exit 1
fi
# A concrete policy path is passed unconditionally. Passing "" here would skip
# the Authoring-Agent allow-list entirely and fail OPEN — see the exit-status
# contract on pr_body_agent_is_allowed.
pr_body_validate "$BODY" "$ROOT/.github/review-policy.yml"

if [ "$PRINT_AUTHOR" = true ]; then
  pr_body_authoring_agent "$BODY"
fi
