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
#     asserts the response matches <login>. This answers "who does this
#     token READ as". Use it for reads; before a write use
#     --expect-write-identity. See REVIEW_POLICY.md § Operation-to-Identity
#     Matrix.
#
#   --expect-write-identity <login>
#     Everything --expect-token-identity asserts, AND positive evidence
#     that $GH_TOKEN is a user-held credential, so a write made with it
#     carries <login> as its byline (#1057). A brokered credential breaks
#     the first assumption: in a Claude Code cloud session GH_TOKEN is the
#     placeholder `proxy-injected`, `GET /user` through it reads as the
#     human, and the write lands as `claude[bot]`. The credential class is
#     decided by scripts/lib/credential-class.sh from the token's own form,
#     BEFORE any API call, and anything that is not `user-held` exits 3
#     (cannot establish), never 0. This is the mode the gh-as-* wrappers'
#     token resolver and every other pre-write check use.
#
#     MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1 accepts a token whose
#     class is `unidentifiable` (a credential form GitHub has not
#     documented), with a stderr warning. It never accepts `brokered`,
#     `app-installed` or `empty`: those are positively known not to write
#     as <login>.
#
# Exit codes:
#   0  match (proceed)
#   1  bad invocation (no mode, conflicting modes, missing argument)
#   2  mismatch — actual identity printed with remediation hint
#   3  could not read identity (gh not installed, hosts.yml corrupt,
#      gh api user failed, etc.), or --expect-write-identity could not
#      establish that the token is user-held — fail closed
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
  --expect-write-identity <login>   as above, AND $GH_TOKEN is a user-held credential

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
    --expect-write-identity)
      [ -n "$MODE" ] && { echo "identity-check: conflicting modes ($MODE and $1)" >&2; usage; exit 1; }
      MODE="write"
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        echo "identity-check: --expect-write-identity requires a login" >&2
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
  token|write)
    EXPECTED="$ARG"
    ;;
esac

# --- write mode: establish the credential class first -------------------
#
# Decided from the token itself, before any API call, because the API call
# is exactly what a broker answers truthfully for the wrong writer.

if [ "$MODE" = "write" ]; then
  CLASS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/credential-class.sh"
  if [ ! -r "$CLASS_LIB" ]; then
    echo "identity-check: credential classifier missing: $CLASS_LIB" >&2
    echo "identity-check:   Refusing to verify a write token without it." >&2
    exit 3
  fi
  # shellcheck source=lib/credential-class.sh
  . "$CLASS_LIB"
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "identity-check: GH_TOKEN is empty/unset; cannot verify write identity." >&2
    exit 3
  fi
  # gh sends GH_TOKEN only to github.com, and GH_HOST moves every bare call to
  # another server, where a later write would run under a credential this
  # check never classified (Codex P1 on #1541). Write identity is therefore
  # established for github.com only. GH_ENTERPRISE_TOKEN and
  # GITHUB_ENTERPRISE_TOKEN are not refused here: gh uses them only for an
  # Enterprise Server target, and the guarded-write wrappers overwrite both
  # with a non-credential sentinel, so an operator's separate GHES login
  # neither carries a guarded write nor blocks one (Codex on #1541).
  WRITE_HOST="$(printf '%s' "${GH_HOST:-github.com}" | tr '[:upper:]' '[:lower:]')"
  if [ "$WRITE_HOST" != "github.com" ]; then
    echo "identity-check: BLOCKED GH_HOST is '$GH_HOST'; write identity is established for github.com only." >&2
    exit 3
  fi
  # GH_HOST unset does not guarantee github.com: with a single host in
  # hosts.yml, gh targets THAT host. This check pins its own requests to
  # github.com (below), the wrappers give any non-github.com host only a
  # non-credential sentinel, and the unwrapped write-mode callers
  # (coderabbit-wait.sh, resolve-pr-threads.sh, scripts/gh-projects/) pin
  # GH_HOST=github.com on their own gh calls. hosts.yml is therefore never
  # parsed here: four YAML forms defeated a parser in review (#1541).
  CLASS_HEADERS=""
  if printf '%s' "$GH_TOKEN" | grep -Eq '^[0-9a-f]{40}$'; then
    # A legacy unprefixed token is user-held only if GitHub answers with
    # X-OAuth-Scopes; that is the one case needing the response headers.
    CLASS_HEADERS="$(mktemp "${TMPDIR:-/tmp}/identity-check-headers.XXXXXX")"
    trap 'rm -f "$CLASS_HEADERS"' EXIT
    gh api -i user --hostname github.com 2>/dev/null | tr -d '\r' | sed '/^$/q' >"$CLASS_HEADERS" || true
  fi
  WRITE_CLASS="$(credential_class "$GH_TOKEN" "$CLASS_HEADERS")"
  case "$WRITE_CLASS" in
    user-held) ;;
    unidentifiable)
      if [ "${MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN:-0}" = "1" ]; then
        echo "identity-check: WARNING GH_TOKEN is not a recognised user-held credential form; accepting it for a write as '$EXPECTED' because MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1." >&2
      else
        echo "identity-check: BLOCKED cannot establish that GH_TOKEN writes as '$EXPECTED': its credential class is 'unidentifiable'." >&2
        echo "identity-check:   Use a personal access token (ghp_ / github_pat_) or a gh login token (gho_) for '$EXPECTED'." >&2
        echo "identity-check:   A token that READS as '$EXPECTED' is not evidence it WRITES as '$EXPECTED' (#1057)." >&2
        exit 3
      fi
      ;;
    *)
      echo "identity-check: BLOCKED GH_TOKEN cannot write as '$EXPECTED': its credential class is '$WRITE_CLASS'." >&2
      case "$WRITE_CLASS" in
        brokered)
          echo "identity-check:   GH_TOKEN is the cloud proxy placeholder. Writes through it land under the proxy's GitHub App identity, whatever GET /user reports (#1057)." >&2
          echo "identity-check:   Provision OP_PREFLIGHT_AUTHOR_PAT / OP_PREFLIGHT_REVIEWER_PAT in the environment (mergepath#1057)." >&2
          ;;
        app-installed)
          echo "identity-check:   GH_TOKEN is a GitHub App installation token; writes through it land as the app's bot." >&2
          ;;
      esac
      exit 3
      ;;
  esac
fi

# --- read actual identity ---------------------------------------------

ACTUAL=""
SIGNAL=""
if [ "$MODE" = "token" ] || [ "$MODE" = "write" ]; then
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
  # Write mode pins the request to github.com. An unset GH_HOST is not enough:
  # with a single host in hosts.yml, gh targets THAT host, and a GHES login
  # would answer for a GH_TOKEN it never saw (Phase 4b P1 on #1541).
  HOST_ARGS=()
  [ "$MODE" = "write" ] && HOST_ARGS=(--hostname github.com)
  if ! ACTUAL=$(gh api user ${HOST_ARGS[@]+"${HOST_ARGS[@]}"} --jq .login 2>/dev/null); then
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
  token|write)
    echo "identity-check: BLOCKED GH_TOKEN resolves to identity '$ACTUAL', expected '$EXPECTED'." >&2
    echo "identity-check:   Signal: $SIGNAL" >&2
    echo "identity-check:   Remediation: export GH_TOKEN to the PAT for '$EXPECTED' (e.g. \$OP_PREFLIGHT_REVIEWER_PAT)." >&2
    echo "identity-check:   See REVIEW_POLICY.md § Operation-to-Identity Matrix (graphql write — PAT-attributed)." >&2
    ;;
esac
exit 2
