#!/usr/bin/env bash
# Shared parser for the identity-bearing fields in pull request bodies.

PR_BODY_CONTRACT_PARSER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-body-contract.mjs"
# shellcheck source=reviewers-helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewers-helpers.sh"
# Existence-guarded: this library is sourced by fixtures and consumer trees
# that may not carry every sibling helper, and a hard source turns a missing
# file into a fatal error in callers that never needed the scalar reader.
# Declared in this file's manifest `requires:` closure so it does travel.
if [ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-policy-scalar.sh" ]; then
  # shellcheck source=review-policy-scalar.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-policy-scalar.sh"
fi

# Fallback with the SAME semantics as review_policy_scalar, defined only when
# the shared reader is absent. Padding is trimmed BEFORE paired quotes are
# stripped — the reverse order left a trailing quote on
# `author_identity: "name"   ` and rejected every human-authored PR.
if ! command -v review_policy_scalar >/dev/null 2>&1; then
  review_policy_scalar() {  # <file> <key>
    [ -r "$1" ] || return 1
    grep -m1 "^$2:" "$1" 2>/dev/null \
      | sed -E "s/^$2:[[:space:]]*//; s/[[:space:]]*#.*\$//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//"
  }
fi

# Returns the CANONICAL short form of the declared writer: the parsed value
# with a leading `nathanpayne-` stripped. `nathanpayne-claude` and `claude`
# both yield `claude`; `nathanjohnpayne`, which carries no such prefix, yields
# itself.
#
# Canonicalizing HERE rather than at each call site is load-bearing (#1132).
# Consumers match the author against reviewer logins by SUFFIX --
# codex-review-check.sh looks for a reviewer ending in `-$AUTHORING_AGENT`,
# gh-pr-guard.sh compares it to the short `REVIEWER_AGENT`. Emitting the raw
# full login would satisfy pr_body_validate and then fail both: no reviewer
# ends in `-nathanpayne-claude`, so an externally reviewed PR would die with an
# infrastructure error it cannot clear, and the local guard would miss
# same-agent approval entirely. One representation leaves the consumers alone.
# The declaration EXACTLY as written, with no canonicalization. Validation must
# use this: canonicalizing first is lossy, and the loss is a security hole.
# `evil-claude` reduces to `claude`, which IS in the roster, so an undeclared
# writer passes the closed-set check (#1132). Validate the raw value against a
# roster that already carries both the full and short form of every identity,
# then canonicalize for consumers.
pr_body_authoring_agent_raw() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --author
}

pr_body_authoring_agent() {
  local agent
  agent="$(pr_body_authoring_agent_raw "$1")" || return $?
  # Canonical = short form, org prefix removed whatever it is. See
  # pr_body_available_authoring_agents for why the prefix is not hard-coded.
  case "$agent" in
    *-*) printf '%s\n' "${agent#*-}" ;;
    *)   printf '%s\n' "$agent" ;;
  esac
}

pr_body_authoring_agent_count() {
  printf '%s\n' "$1" | node "$PR_BODY_CONTRACT_PARSER" --author-count
}

# Derives the allowed `Authoring-Agent:` values. There is no
# `available_authoring_agents:` key — the roster is the UNION of the three
# identity declarations the policy already carries:
#
#   author_identity          the human author identity (a scalar)
#   available_reviewers      the agent reviewer identities
#   non_reviewer_identities  service accounts (CI), which also open PRs
#
# Every PR must name its writer, and the set of possible writers is closed and
# declared. Deriving from `available_reviewers` ALONE (the pre-#1132 behaviour)
# recognised only the agent reviewers, so a PR written by the human author
# identity or by the CI service account could not name itself without being
# rejected as an "unknown Authoring-Agent".
#
# Each identity is accepted in BOTH forms: its full login and its
# prefix-stripped short form. `nathanpayne-claude` and `claude` both validate;
# the 38 existing PRs all use the short form. An identity carrying no
# `nathanpayne-` prefix at all — `nathanjohnpayne` — yields only itself, which
# is why the prefix is stripped opportunistically here rather than used as a
# filter. The old `case` DISCARDED every entry without that prefix, so the
# human identity would have been silently dropped even once listed.
#
# Adding an identity to any of the three keys extends this set automatically;
# no change to this function is needed.
#
# Exit status: 2 when the policy file is unreadable, so an infrastructure
# problem cannot be mistaken for an empty allow-list.
pr_body_available_authoring_agents() {
  local policy_file=$1
  local identity
  [ -r "$policy_file" ] || return 2
  {
    read_available_reviewers "$policy_file"
    read_non_reviewer_identities "$policy_file" 2>/dev/null || true
    # The shared scalar reader, not a hand-rolled sed. The hand-rolled version
    # stripped the closing quote BEFORE trimming trailing padding, so valid
    # YAML spelled `author_identity: "nathanjohnpayne"   ` parsed to
    # `nathanjohnpayne"` and every human-authored PR was rejected by a REQUIRED
    # check for a quote the repo's own scalar reader accepts.
    review_policy_scalar "$policy_file" author_identity 2>/dev/null || true
  } | while IFS= read -r identity; do
    identity="$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [ -n "$identity" ] || continue
    printf '%s\n' "$identity"
    # Short form = the login minus its ORG PREFIX, whatever that prefix is.
    # Hard-coding `nathanpayne-` made this fleet-specific inside a canonical
    # library: a consumer whose reviewers are `acme-claude` derived no short
    # form at all. Splitting on the first `-` is prefix-agnostic and leaves an
    # unprefixed login (`nathanjohnpayne`) as itself.
    case "$identity" in
      *-*) printf '%s\n' "${identity#*-}" ;;
    esac
  done | sort -u
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
  # RAW, deliberately. See pr_body_authoring_agent_raw: validating the
  # canonical form lets `evil-claude` pass as `claude`.
  author="$(pr_body_authoring_agent_raw "$body")"
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
