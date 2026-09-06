#!/usr/bin/env bash
# Shared parser for the identity-bearing fields in pull request bodies.

PR_BODY_CONTRACT_PARSER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-body-contract.mjs"
# shellcheck source=reviewers-helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewers-helpers.sh"

pr_body_authoring_agent() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --author
}

pr_body_authoring_agent_count() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --author-count
}

# Derives the allowed AUTHORING agents from `available_reviewers`. There is no
# `available_authoring_agents:` key; the two lists are the same list, read
# through a prefix.
#
# COUPLING, deliberate and load-bearing: the `nathanpayne-` prefix below is a
# fleet-specific fact living in a canonical library. Every repo that receives
# this file inherits it. A consumer whose `available_reviewers` entries do not
# carry that prefix derives an EMPTY list, and (before #1132) every PR there
# failed with "unknown Authoring-Agent", which blames the PR author for a
# configuration mismatch. Callers must distinguish "no agents derived" from
# "this agent is not in the list" — see pr_body_agent_is_allowed.
#
# Exit status: 2 when the policy file is unreadable, so an infrastructure
# problem cannot be mistaken for an empty allow-list.
pr_body_available_authoring_agents() {
  local policy_file=$1
  local reviewer
  [ -r "$policy_file" ] || return 2
  while IFS= read -r reviewer; do
    reviewer="$(printf '%s' "$reviewer" | tr '[:upper:]' '[:lower:]')"
    case "$reviewer" in
      nathanpayne-*) printf '%s\n' "${reviewer#nathanpayne-}" ;;
    esac
  done <<< "$(read_available_reviewers "$policy_file")"
}

# Exit status is three-valued on purpose; callers must not collapse it:
#   0 = the agent is allowed (or the allow-list check was deliberately skipped)
#   1 = the agent is genuinely absent from a policy that WAS read
#   2 = the policy could not be read, or was read and yielded no agents at all
#
# An EMPTY $policy_file skips the allow-list and returns 0. That is a
# deliberate fail-open, and it is safe only because it is unreachable from any
# gate: the required workflow and gh-as-author both pass a concrete path, and
# scripts/validate-pr-body.sh computes an absolute one. It exists so callers
# that only want the structural checks (exactly one marker, a real Self-Review
# heading) can ask for those alone. Anything enforcing policy MUST pass a path;
# passing "" to a gate would silently disable the agent check (#1132).
pr_body_agent_is_allowed() {
  local agent=$1
  local policy_file=${2:-}
  local allowed
  local rc=0

  [ -n "$policy_file" ] || return 0
  allowed="$(pr_body_available_authoring_agents "$policy_file")" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$allowed" ] || return 2
  printf '%s\n' "$allowed" | grep -Fqx -- "$(printf '%s' "$agent" | tr '[:upper:]' '[:lower:]')"
}

pr_body_has_self_review() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --has-self-review
}

pr_body_validate() {
  local body=$1
  local policy_file=${2:-}
  local author
  local author_count
  local failed=0

  author_count="$(pr_body_authoring_agent_count "$body")"
  author="$(pr_body_authoring_agent "$body")"
  if [ "$author_count" -eq 0 ]; then
    echo "PR description is missing a valid 'Authoring-Agent:' line (expected one agent identifier)." >&2
    failed=1
  elif [ "$author_count" -ne 1 ]; then
    echo "PR description must contain exactly one 'Authoring-Agent:' line." >&2
    failed=1
  elif [ -z "$author" ]; then
    echo "PR description is missing a valid 'Authoring-Agent:' line (expected one agent identifier)." >&2
    failed=1
  else
    local allowed_rc=0
    pr_body_agent_is_allowed "$author" "$policy_file" || allowed_rc=$?
    if [ "$allowed_rc" -eq 2 ]; then
      # Not the author's fault and not fixable by editing the PR body. Say so,
      # and still fail closed: a gate that cannot read its policy must not pass.
      echo "Cannot validate the Authoring-Agent: no agents could be derived from '$policy_file'." >&2
      echo "The policy file is unreadable, or its available_reviewers entries do not carry the expected prefix." >&2
      echo "This is a repository configuration problem, not a problem with this PR." >&2
      failed=1
    elif [ "$allowed_rc" -ne 0 ]; then
      echo "PR description has an unknown Authoring-Agent '$author' (expected an agent represented in available_reviewers)." >&2
      failed=1
    fi
  fi

  if ! pr_body_has_self_review "$body"; then
    echo "PR description is missing a '## Self-Review' section." >&2
    failed=1
  fi

  [ "$failed" -eq 0 ]
}
