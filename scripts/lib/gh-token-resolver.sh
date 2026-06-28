#!/usr/bin/env bash
# Shared GitHub token resolver for agent write wrappers.
#
# Source this file from a wrapper, then call:
#
#   gh_resolve_token_for_identity <expected-login> <preferred-env-var> <label>
#
# On success it sets GH_RESOLVED_TOKEN in the caller's shell. It never
# prints token material. The selected token is verified with
# scripts/identity-check.sh --expect-token-identity before the caller
# can use it for a write.
#
# Bash 3.2 portable.

gh_resolver_repo_root() {
  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$this_dir"
}

gh_default_reviewer_identity() {
  if [ -n "${GH_AS_REVIEWER_IDENTITY:-}" ]; then
    printf '%s\n' "$GH_AS_REVIEWER_IDENTITY"
  elif [ -n "${MERGEPATH_AGENT:-}" ]; then
    printf 'nathanpayne-%s\n' "$MERGEPATH_AGENT"
  elif [ -n "${OP_PREFLIGHT_AGENT:-}" ]; then
    printf 'nathanpayne-%s\n' "$OP_PREFLIGHT_AGENT"
  else
    printf '%s\n' "nathanpayne-claude"
  fi
}

gh_resolve_token_for_identity() {
  local expected_login="${1:-}"
  local preferred_var="${2:-}"
  local label="${3:-gh-token-resolver}"

  if [ -z "$expected_login" ]; then
    echo "$label: expected login is required" >&2
    return 1
  fi

  local root checker token source
  root="$(gh_resolver_repo_root)"
  checker="$root/scripts/identity-check.sh"
  if [ ! -x "$checker" ]; then
    echo "$label: identity-check helper missing or non-executable: $checker" >&2
    echo "$label: refusing to select a GitHub write token without verification." >&2
    return 2
  fi

  # Resolution order (every candidate is verified via identity-check.sh
  # --expect-token-identity before it can win — no candidate is ever blindly
  # trusted, and no token material is printed):
  #
  #   1. The preferred OP_PREFLIGHT_*_PAT env var (if set). A WRONG identity
  #      here is a hard error — the caller asked for this specific cached PAT,
  #      so a mismatch is a misconfiguration to surface, not something to
  #      paper over by silently using a different token.
  #   2. An ambient GH_TOKEN (#533). On a token-only runner
  #      (`GH_TOKEN=... scripts/gh-as-reviewer.sh ...`) with no keyring and no
  #      OP_PREFLIGHT cache, this is the only token material available. It is
  #      tried only when (1) supplied no token. A WRONG-identity ambient token
  #      is REJECTED and falls through to the keyring — never blindly trusted.
  #   3. The `gh auth token --user <login>` keyring fallback. A WRONG identity
  #      here is a hard error (the keyring returned a token for the wrong
  #      account).

  token=""
  source=""

  # --- Candidate 1: preferred OP_PREFLIGHT_*_PAT (hard-fail on mismatch) ---
  if [ -n "$preferred_var" ]; then
    # Indirect expansion is supported by the repo's Bash 3.2 baseline.
    token="${!preferred_var:-}"
    if [ -n "$token" ]; then
      source="\$$preferred_var"
      if ! GH_TOKEN="$token" "$checker" --expect-token-identity "$expected_login"; then
        echo "$label: selected token source ($source) did not verify as $expected_login." >&2
        return 2
      fi
      GH_RESOLVED_TOKEN="$token"
      return 0
    fi
  fi

  # --- Candidate 2: ambient GH_TOKEN (verify; fall through on mismatch) ---
  # Tried only when the preferred var supplied nothing. A mismatch does NOT
  # hard-fail here — it falls through to the keyring — because an ambient
  # GH_TOKEN may belong to a different identity than the one this write needs
  # (e.g. a CI-default token), and the keyring may still hold the right one.
  if [ -n "${GH_TOKEN:-}" ]; then
    if GH_TOKEN="$GH_TOKEN" "$checker" --expect-token-identity "$expected_login" 2>/dev/null; then
      GH_RESOLVED_TOKEN="$GH_TOKEN"
      return 0
    fi
    echo "$label: ambient GH_TOKEN did not verify as $expected_login; trying gh auth token --user." >&2
  fi

  # --- Candidate 3: gh auth token --user keyring fallback (hard-fail) ------
  if ! command -v gh >/dev/null 2>&1; then
    echo "$label: gh CLI not on PATH; cannot fall back to gh auth token." >&2
    return 3
  fi
  if ! token="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "$expected_login" 2>/dev/null)"; then
    echo "$label: could not read a token for $expected_login via gh auth token --user." >&2
    echo "$label: run gh auth login once for that identity, or warm op-preflight." >&2
    return 3
  fi
  source="gh auth token --user $expected_login"

  if [ -z "$token" ]; then
    echo "$label: selected token for $expected_login is empty." >&2
    return 3
  fi

  if ! GH_TOKEN="$token" "$checker" --expect-token-identity "$expected_login"; then
    echo "$label: selected token source ($source) did not verify as $expected_login." >&2
    return 2
  fi

  GH_RESOLVED_TOKEN="$token"
  return 0
}
