#!/usr/bin/env bash
# Shared parser for the identity-bearing fields in pull request bodies.

PR_BODY_CONTRACT_PARSER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-body-contract.mjs"
# shellcheck source=reviewers-helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewers-helpers.sh"

# Wall-clock bound on every production parser invocation (#1281).
#
# The parser has pathological cost on some untrusted inputs -- see
# `specs/pr_body_contract.md` -- and without a bound here such a body does not
# FAIL this gate, it STALLS it for as long as the enclosing job allows. That is
# the difference this constant buys: a bounded failure instead of an unbounded
# wait.
#
# 120 seconds. The slowest legitimate parse recorded on any fixture is about 32
# seconds, for a 30,000-level blockquote near GitHub's 65,536-character body
# limit, measured on a Node 20.20.2 environment where the same fixture takes
# about 1.2 seconds locally. 120s is roughly 3.75x that worst observation, so
# runner-speed variance cannot turn a valid body into a rejected one. It
# matches the bound the parity suite already uses for the same reason, so there
# is one number to reason about rather than two.
#
# This is a resource bound, NOT a parsing-time guarantee. It says when we stop
# waiting; it says nothing about how long any parse takes. `pr_body_validate`
# makes three invocations, so its worst case is three times this bound --
# bounded, where it was previously unbounded.
PR_BODY_CONTRACT_TIMEOUT_SECONDS=120

# Node is already the parser runtime, so its synchronous child-process timeout
# is the portable watchdog: no dependency on GNU `timeout` or macOS-only
# `gtimeout`, which matters because this file is propagated to consumers whose
# runners differ. SIGKILL makes expiry non-negotiable.
#
# Two properties of the expiry path are load-bearing:
#
#   1. rc 124, the conventional timeout status, so callers can tell "the parser
#      did not finish" from "the parser answered". Every production caller
#      already tests the helper's status -- `if ! VAR="$(...)"` -- so a timeout
#      reaches their existing fail-closed guards without changing them.
#   2. NO stdout. `spawnSync` can return partial output alongside ETIMEDOUT,
#      and a partial answer must never reach a gate. In particular an empty
#      author is read downstream as "no same-agent risk", which DISABLES the
#      authoring-agent exclusion in gate (b) -- fail-open in the one place it
#      must not be. This is why the production watchdog suppresses stdout on
#      expiry where `run_with_timeout` in the parity suite does not: the suite
#      asserts on output, a gate acts on it.
pr_body_contract_run() { # mode, body -> parser stdout; rc 124 on expiry
  printf '%s\n' "$2" | node -e '
    const { readFileSync } = require("node:fs");
    const { spawnSync } = require("node:child_process");
    const seconds = Number(process.argv[1]);
    const command = process.argv.slice(2);
    const result = spawnSync(command[0], command.slice(1), {
      input: readFileSync(0), encoding: "utf8", timeout: seconds * 1000, killSignal: "SIGKILL",
    });
    if (result.error?.code === "ETIMEDOUT") {
      if (result.stderr) process.stderr.write(result.stderr);
      process.exit(124);
    }
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  ' "$PR_BODY_CONTRACT_TIMEOUT_SECONDS" node "$PR_BODY_CONTRACT_PARSER" "$1"
}

pr_body_authoring_agent() {
  pr_body_contract_run --author "$1"
}

pr_body_authoring_agent_count() {
  pr_body_contract_run --author-count "$1"
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
  pr_body_contract_run --has-self-review "$1"
}

pr_body_validate() {
  local body=$1
  local policy_file=${2:-}
  local author
  local author_count
  local failed=0

  local count_rc=0
  local author_rc=0
  author_count="$(pr_body_authoring_agent_count "$body")" || count_rc=$?
  author="$(pr_body_authoring_agent "$body")" || author_rc=$?
  # Every other caller of these helpers already tests their status; this one
  # did not, and on a non-zero status fell through to "missing a valid
  # Authoring-Agent" -- blaming the PR author for an infrastructure failure,
  # after emitting a raw `[: : integer expression expected` from the empty
  # capture. It failed closed, but by accident and with the wrong diagnosis.
  # The branch below is the same infrastructure-versus-author distinction this
  # function already draws for an unreadable policy file.
  if [ "$count_rc" -ne 0 ] || [ "$author_rc" -ne 0 ]; then
    echo "Cannot validate the Authoring-Agent: the PR-body parser did not complete (status ${count_rc}/${author_rc})." >&2
    if [ "$count_rc" -eq 124 ] || [ "$author_rc" -eq 124 ]; then
      echo "Status 124 means it exceeded the ${PR_BODY_CONTRACT_TIMEOUT_SECONDS}s wall-clock bound; see the parsing-cost limitation in specs/pr_body_contract.md." >&2
    fi
    echo "This is an infrastructure or input-complexity problem, not a missing declaration." >&2
    failed=1
  elif [ "$author_count" -eq 0 ]; then
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

  local review_rc=0
  pr_body_has_self_review "$body" || review_rc=$?
  # --has-self-review answers with its exit status (0 present, 1 absent), so a
  # watchdog expiry would otherwise read as a confident "absent".
  if [ "$review_rc" -eq 124 ]; then
    echo "Cannot validate the '## Self-Review' section: the PR-body parser exceeded the ${PR_BODY_CONTRACT_TIMEOUT_SECONDS}s wall-clock bound." >&2
    failed=1
  elif [ "$review_rc" -ne 0 ]; then
    echo "PR description is missing a '## Self-Review' section." >&2
    failed=1
  fi

  [ "$failed" -eq 0 ]
}
