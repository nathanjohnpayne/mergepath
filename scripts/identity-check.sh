#!/usr/bin/env bash
# scripts/identity-check.sh — Pre-action identity assertion helper (#284).
#
# Asserts that the current execution context has the EXPECTED gh identity
# at the moment of call. The gh-as-* wrappers use token mode to verify
# the exact PAT that will sign a guarded write. Legacy compatibility
# modes below still inspect gh's stored account selection for callers
# that have not moved to token mode.
#
# Why this exists:
#
#   Guarded writes now use a process-local token selected by a wrapper.
#   That token must be verified before the write, and token material must
#   never be printed. The historical keyring checks remain available for
#   compatibility callers that have not moved to wrappers yet.
#
# Modes (mutually exclusive; exactly one is required):
#
#   --expect-author
#     gh's stored selected account must be the author identity
#     (nathanjohnpayne by default; override via
#     IDENTITY_CHECK_EXPECTED_AUTHOR).
#
#   --expect-reviewer
#     gh's stored selected account must be nathanpayne-<MERGEPATH_AGENT>.
#     MERGEPATH_AGENT is read from the environment; missing/empty
#     falls back to `claude` with a stderr warning.
#
#   --expect-external <agent>
#     gh's stored selected account must be nathanpayne-<agent>. Used in
#     Phase 4b CLI sessions where the cross-agent reviewer (e.g.
#     `codex` from a `claude` parent session) needs to assert its own
#     identity before posting the external review.
#
#   --expect-token-identity <login>
#     Runs `gh api user --jq .login` with the CURRENT $GH_TOKEN and
#     asserts the response matches <login>. This is the primary mode for
#     gh-as-* wrappers and PAT-authored writes such as `gh api graphql`
#     mutations. See REVIEW_POLICY.md § Operation-to-Identity Matrix.
#
# Exit codes:
#   0  match (proceed)
#   1  bad invocation (no mode, conflicting modes, missing argument)
#   2  mismatch — actual identity printed with remediation hint
#   3  could not read identity (gh not installed, hosts.yml corrupt,
#      gh api user failed, etc.) — fail closed
#
# All diagnostics go to stderr; no stdout output. The script is silent
# on success so it can be dropped at the top of any helper without
# noise.
#
# IDENTITY: keyring vs PAT
#
#   `--expect-author` / `--expect-reviewer` / `--expect-external` all
#   read gh's stored selected account via `gh config get -h github.com
#   user`. These modes exist for legacy compatibility paths that still
#   need a GH_TOKEN-immune stored-account assertion.
#
#   `--expect-token-identity` asserts the IDENTITY ATTACHED TO
#   $GH_TOKEN, not the keyring. This is the canonical assertion for
#   wrapper-selected write tokens.
#
# Bash 3.2 portable (macOS default).

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: identity-check.sh <mode>

Modes (exactly one required):
  --expect-author                   stored gh account == author identity (nathanjohnpayne)
  --expect-reviewer                 stored gh account == nathanpayne-$MERGEPATH_AGENT
  --expect-external <agent>         stored gh account == nathanpayne-<agent>
  --expect-token-identity <login>   gh api user .login (under $GH_TOKEN) == <login>

Exit codes: 0 match | 1 bad args | 2 mismatch | 3 read failure (fail-closed).
USAGE
}

# --- parse args -------------------------------------------------------

MODE=""
ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect-author)
      [ -n "$MODE" ] && { echo "identity-check: conflicting modes ($MODE and $1)" >&2; usage; exit 1; }
      MODE="author"
      shift
      ;;
    --expect-reviewer)
      [ -n "$MODE" ] && { echo "identity-check: conflicting modes ($MODE and $1)" >&2; usage; exit 1; }
      MODE="reviewer"
      shift
      ;;
    --expect-external)
      [ -n "$MODE" ] && { echo "identity-check: conflicting modes ($MODE and $1)" >&2; usage; exit 1; }
      MODE="external"
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        echo "identity-check: --expect-external requires an agent name" >&2
        usage
        exit 1
      fi
      ARG="$2"
      shift 2
      ;;
    --expect-token-identity)
      [ -n "$MODE" ] && { echo "identity-check: conflicting modes ($MODE and $1)" >&2; usage; exit 1; }
      MODE="token"
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        echo "identity-check: --expect-token-identity requires a login" >&2
        usage
        exit 1
      fi
      ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "identity-check: unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "identity-check: no mode specified" >&2
  usage
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "identity-check: gh CLI not on PATH; cannot verify identity." >&2
  echo "identity-check:   Install gh and run 'gh auth login' for the required identity." >&2
  exit 3
fi

# --- compute expected identity ----------------------------------------

EXPECTED=""
case "$MODE" in
  author)
    EXPECTED="${IDENTITY_CHECK_EXPECTED_AUTHOR:-nathanjohnpayne}"
    ;;
  reviewer)
    AGENT="${MERGEPATH_AGENT:-}"
    if [ -z "$AGENT" ]; then
      echo "identity-check: WARNING MERGEPATH_AGENT is unset; falling back to 'claude'." >&2
      echo "identity-check:   Set MERGEPATH_AGENT=<claude|cursor|codex> to silence this warning." >&2
      AGENT="claude"
    fi
    EXPECTED="nathanpayne-$AGENT"
    ;;
  external)
    EXPECTED="nathanpayne-$ARG"
    ;;
  token)
    EXPECTED="$ARG"
    ;;
esac

# --- read actual identity ---------------------------------------------

ACTUAL=""
SIGNAL=""
if [ "$MODE" = "token" ]; then
  # PAT-authored write. The token in $GH_TOKEN authenticates the API
  # call AND determines the byline for graphql mutations like
  # resolveReviewThread. We deliberately use `gh api user` here
  # (not `gh config get`) because we want the token's identity, not
  # the keyring's.
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "identity-check: GH_TOKEN is empty/unset; cannot verify token identity." >&2
    echo "identity-check:   Set GH_TOKEN to the PAT that will sign the API call (e.g. \$OP_PREFLIGHT_REVIEWER_PAT)." >&2
    exit 3
  fi
  SIGNAL="gh api user --jq .login (with GH_TOKEN)"
  if ! ACTUAL=$(gh api user --jq .login 2>/dev/null); then
    echo "identity-check: '$SIGNAL' failed; cannot verify token identity." >&2
    echo "identity-check:   The PAT in GH_TOKEN may be expired, revoked, or lack 'read:user' scope." >&2
    exit 3
  fi
else
  # Legacy stored-account check. Read gh's selected account via
  # `gh config get -h github.com user`, NOT `gh auth status` — the
  # latter is GH_TOKEN-poisonable (it reports the GH_TOKEN entry as
  # selected even though legacy callers use the stored account).
  SIGNAL="gh config get -h github.com user"
  ACTUAL=$($SIGNAL 2>/dev/null || true)
  if [ -z "$ACTUAL" ]; then
    echo "identity-check: '$SIGNAL' returned empty; cannot verify keyring identity." >&2
    echo "identity-check:   Either gh is not authenticated or the keyring config is corrupt." >&2
    echo "identity-check:   Run 'gh auth login' for the $EXPECTED identity, then retry." >&2
    exit 3
  fi
fi

# --- compare ----------------------------------------------------------

if [ "$ACTUAL" = "$EXPECTED" ]; then
  exit 0
fi

# Mismatch. Print a remediation hint that names the expected identity
# AND the path that exists for the calling write context (keyring switch
# vs PAT swap).
case "$MODE" in
  author|reviewer|external)
    echo "identity-check: BLOCKED stored gh account is '$ACTUAL', expected '$EXPECTED'." >&2
    echo "identity-check:   Signal: $SIGNAL" >&2
    echo "identity-check:   Remediation: use the token wrapper for guarded writes, or reselect '$EXPECTED' for legacy stored-account callers." >&2
    echo "identity-check:   See REVIEW_POLICY.md § Operation-to-Identity Matrix for the auth split." >&2
    ;;
  token)
    echo "identity-check: BLOCKED GH_TOKEN resolves to identity '$ACTUAL', expected '$EXPECTED'." >&2
    echo "identity-check:   Signal: $SIGNAL" >&2
    echo "identity-check:   Remediation: export GH_TOKEN to the PAT for '$EXPECTED' (e.g. \$OP_PREFLIGHT_REVIEWER_PAT)." >&2
    echo "identity-check:   See REVIEW_POLICY.md § Operation-to-Identity Matrix (graphql write — PAT-attributed)." >&2
    ;;
esac
exit 2
