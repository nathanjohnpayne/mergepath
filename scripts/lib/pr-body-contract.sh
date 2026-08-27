#!/usr/bin/env bash
# Shared parser for the identity-bearing fields in pull request bodies.

PR_BODY_CONTRACT_PARSER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-body-contract.mjs"

pr_body_authoring_agent() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --author
}

pr_body_authoring_agent_count() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --author-count
}

pr_body_available_authoring_agents() {
  local policy_file=$1
  [ -r "$policy_file" ] || return 0

  awk '
    /^[^[:space:]#]/ {
      if ($1 == "available_reviewers:") { in_reviewers = 1; next }
      in_reviewers = 0
    }
    in_reviewers && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*$/, "", value)
      gsub(/^["\047]|["\047]$/, "", value)
      value = tolower(value)
      sub(/^nathanpayne-/, "", value)
      if (value ~ /^[a-z0-9_-]+$/) print value
    }
  ' "$policy_file"
}

pr_body_agent_is_allowed() {
  local agent=$1
  local policy_file=${2:-}
  local allowed

  [ -n "$policy_file" ] || return 0
  allowed="$(pr_body_available_authoring_agents "$policy_file")"
  [ -n "$allowed" ] || return 1
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
  elif ! pr_body_agent_is_allowed "$author" "$policy_file"; then
    echo "PR description has an unknown Authoring-Agent '$author' (expected an agent represented in available_reviewers)." >&2
    failed=1
  fi

  if ! pr_body_has_self_review "$body"; then
    echo "PR description is missing a '## Self-Review' section." >&2
    failed=1
  fi

  [ "$failed" -eq 0 ]
}
