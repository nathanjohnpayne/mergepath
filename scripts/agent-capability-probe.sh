#!/usr/bin/env bash
# scripts/agent-capability-probe.sh — measure what this agent session can do
# on GitHub, before it tries (#1057).
#
# A cloud session (Claude Code on the web, Codex cloud) used to discover its
# limits by attempting work and failing: no reviewer credential, writes landing
# under a brokered bot identity, GraphQL refused by the proxy, pushes confined
# to one branch, other repositories unreachable. This probe answers each of
# those by measurement, side-effect free, and caches the answer so later tool
# calls can read it without probing again.
#
# Usage:
#   scripts/agent-capability-probe.sh [--repo OWNER/REPO] [--cross-repo OWNER/REPO]
#                                     [--no-cache] [--quiet]
#     Probe, print the result as JSON on stdout, a summary on stderr, and
#     write the cache.
#
#   scripts/agent-capability-probe.sh --check [--print-exports] [--repo OWNER/REPO]
#     Never probes, never touches the network. Validates the cache for this
#     repo, surface, cross-repo target, author identity, reviewer identity and
#     (in a Claude cloud session) CLAUDE_CODE_REMOTE_SESSION_ID. Bare --check reports on stderr only. With
#     --print-exports, prints `export MERGEPATH_AGENT_TIER=...` and one
#     `export MERGEPATH_CAP_<NAME>=0|1` per capability for
#       eval "$(scripts/agent-capability-probe.sh --check --print-exports)"
#     On a missing, stale, or mismatched cache it prints a statement that
#     FAILS when evaluated, so an `eval ... &&` chain stops instead of
#     proceeding with nothing exported (the #1021 fail-open shape).
#
# What is measured (never any token material, on any output):
#   read               GET repos/<repo> succeeds
#   graphql            `query { viewer { login } }` succeeds; a proxy refusal
#                      ("This GraphQL query is not enabled for this session")
#                      is reported as the graphql ceiling, not a credential gap
#   cross-repo         GET repos/<cross-repo> succeeds (default
#                      octocat/Hello-World: public, so only a repository-scope
#                      restriction can refuse it)
#   push-multi-branch  reported false in a Claude cloud session from the
#                      proxy's documented one-branch push restriction, and
#                      `not-measured` elsewhere: nothing short of a real push
#                      proves a push is accepted
#   author-writes      the wrapper token resolver finds a token for the
#                      repo's author_identity AND that token is a user-held
#                      credential (scripts/lib/credential-class.sh) whose
#                      `GET /user` is that login with type User AND it sees
#                      `push` on the repository (and `repo` scope, for a
#                      classic token)
#   reviewer-writes    the same, for the reviewer identity
#                      (GH_AS_REVIEWER_IDENTITY / MERGEPATH_AGENT / default),
#                      with `push`: an approval that satisfies branch
#                      protection and review-thread resolution both need
#                      write access (#1537)
#
# Tier: the comma-joined set of granted capabilities other than read, in the
# order above; `read-only` when read is the only one; `none` when nothing is
# granted.
#
# A result containing a transient failure (no response, 5xx, 429, or a
# rate-limited 403) is printed with `transient_failures: true` but never
# cached, so an outage cannot be replayed by --check as a denial.
#
# Surface: MERGEPATH_AGENT_SURFACE (local|claude-cloud|codex-cloud|ci) wins
# when set; otherwise CLAUDE_CODE_REMOTE=true -> claude-cloud,
# GITHUB_ACTIONS=true -> ci, else local. Codex cloud sets no documented marker
# (the codex-universal image defines no CODEX_* variable), so a Codex cloud
# environment must set MERGEPATH_AGENT_SURFACE=codex-cloud among its
# environment variables. Without it the session reads as local with
# surface_source "default", which the output shows rather than hides. The
# surface only labels where the session runs; it never selects the reviewer.
# A Codex environment also sets MERGEPATH_AGENT=codex, which the probe, the
# write wrappers and gh-pr-guard.sh all read (#1539).
#
# Environment:
#   MERGEPATH_CAPABILITY_CACHE_DIR    cache dir (default
#                                     ${XDG_CACHE_HOME:-$HOME/.cache}/mergepath)
#   MERGEPATH_CAPABILITY_TTL_SECONDS  cache lifetime for --check (default 43200)
#
# Exit codes:
#   0  probed (whatever the tier), or --check found a fresh cache
#   1  bad invocation or missing prerequisite (jq, git)
#   2  --check: cache missing, stale, unreadable, or for another repo/surface
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/credential-class.sh
. "$ROOT/scripts/lib/credential-class.sh"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"

# 2: records carry a credential fingerprint (#1537). A schema-1 reader would
# ignore the field and accept a record bound to other credentials, so the
# bump makes older readers reject these records instead.
SCHEMA=2
MODE="probe"
PRINT_EXPORTS=false
WRITE_CACHE=true
QUIET=false
REPO=""
CROSS_REPO="octocat/Hello-World"
# TIER_CAPABILITIES make up the tier string; EXPORT_CAPABILITIES are what
# --check --print-exports emits, one MERGEPATH_CAP_<NAME> each, read included.
TIER_CAPABILITIES="author-writes reviewer-writes graphql cross-repo push-multi-branch"
EXPORT_CAPABILITIES="read $TIER_CAPABILITIES"

# Every failure that can reach an `eval "$(...)"` caller must leave something
# on stdout that fails when evaluated; an empty stdout makes eval return 0.
emit_eval_guard() { # <message>
  printf 'echo %s >&2; return 1 2>/dev/null || exit 1\n' "$(printf '%q' "agent-capability-probe: $1")"
}

die() { # <exit code> <message>
  echo "agent-capability-probe: $2" >&2
  if $PRINT_EXPORTS; then
    emit_eval_guard "$2"
  fi
  exit "$1"
}

usage() {
  sed -n '2,/^# Bash 3.2 portable/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# Pre-scan so an argument error still emits the eval guard when the caller
# asked for exports, whatever order the flags came in.
for arg in "$@"; do
  [ "$arg" = "--print-exports" ] && PRINT_EXPORTS=true
done

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check|--status) MODE="check"; shift ;;
    --print-exports) PRINT_EXPORTS=true; shift ;;
    --no-cache) WRITE_CACHE=false; shift ;;
    --quiet) QUIET=true; shift ;;
    --repo|--cross-repo)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die 1 "$1 requires OWNER/REPO"
      printf '%s' "$2" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die 1 "$1 must be OWNER/REPO; got '$2'"
      if [ "$1" = "--repo" ]; then REPO="$2"; else CROSS_REPO="$2"; fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die 1 "unknown argument: $1" ;;
  esac
done

if $PRINT_EXPORTS && [ "$MODE" != "check" ]; then
  die 1 "--print-exports is only valid with --check (probing prints JSON)"
fi

command -v jq >/dev/null 2>&1 || die 1 "jq is required"
command -v git >/dev/null 2>&1 || die 1 "git is required"

TTL_SECONDS="${MERGEPATH_CAPABILITY_TTL_SECONDS:-43200}"
printf '%s' "$TTL_SECONDS" | grep -Eq '^[0-9]+$' || die 1 "MERGEPATH_CAPABILITY_TTL_SECONDS must be an integer; got '$TTL_SECONDS'"
CACHE_DIR="${MERGEPATH_CAPABILITY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mergepath}"

# --- repo -----------------------------------------------------------------

repo_from_origin() {
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  # git@github-claude:owner/repo is the documented per-identity SSH alias form
  # (github-claude / github-cursor / github-codex), so any git@github-<alias>
  # host counts (Codex P2 on #1526).
  printf '%s\n' "$url" | sed -nE 's#^(https://[^/]*github\.com/|git@github(-[A-Za-z0-9]+)?(\.com)?:|ssh://git@github(-[A-Za-z0-9]+)?(\.com)?/)([^/]+/[^/]+)$#\6#p' | sed -E 's/\.git$//'
}

if [ -z "$REPO" ]; then
  REPO="$(repo_from_origin)"
  [ -n "$REPO" ] || die 1 "could not derive OWNER/REPO from the origin remote; pass --repo"
fi
# --- identities -----------------------------------------------------------

AUTHOR_IDENTITY="nathanjohnpayne"
if [ -f "$ROOT/.github/review-policy.yml" ]; then
  policy_author="$(grep -m1 '^author_identity:' "$ROOT/.github/review-policy.yml" | awk '{print $2}' | sed -E "s/^[\"']//; s/[\"']\$//" || true)"
  [ -n "$policy_author" ] && AUTHOR_IDENTITY="$policy_author"
fi
# The reviewer comes from the one chain the write wrappers and gh-pr-guard.sh
# also use (GH_AS_REVIEWER_IDENTITY, MERGEPATH_AGENT, OP_PREFLIGHT_AGENT,
# nathanpayne-claude), so measurement, execution and the self-approval guard
# always name the same reviewer (#1539). The surface does not select an agent:
# a Codex cloud environment sets MERGEPATH_AGENT=codex explicitly.
REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"
if [ "${MERGEPATH_AGENT_SURFACE:-}" = "codex-cloud" ] \
   && [ -z "${GH_AS_REVIEWER_IDENTITY:-}${MERGEPATH_AGENT:-}${OP_PREFLIGHT_AGENT:-}" ]; then
  echo "agent-capability-probe: WARNING MERGEPATH_AGENT_SURFACE=codex-cloud but no agent is named; measuring reviewer $REVIEWER_IDENTITY. Set MERGEPATH_AGENT=codex among the Codex environment variables, beside MERGEPATH_AGENT_SURFACE." >&2
fi

# A non-secret fingerprint of every credential the measurements can use
# (#1537): the two preflight PATs, both ambient token variables, the gh config
# directory, the keyring tokens for both identities and the active account (read locally with
# `gh auth token --user`, no network). Each value contributes a truncated
# SHA-256; two shells with different effective credentials then never share a
# cached answer. The fingerprint lives only in the cache file and is never
# printed (it would let one token be correlated across logs).
credential_fingerprint() {
  # The keyring and config-dir values are read below by indirect expansion.
  # shellcheck disable=SC2034
  local var val h out="" keyring_author="" keyring_reviewer="" keyring_active=""
  if command -v gh >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    keyring_author="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "$AUTHOR_IDENTITY" 2>/dev/null || true)"
    # The ACTIVE account is what a bare `gh api` uses when no token variable is
    # set, and `gh auth switch` changes it without touching either per-user
    # token (Codex on #1538).
    # shellcheck disable=SC2034
    keyring_active="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null || true)"
    # shellcheck disable=SC2034
    keyring_reviewer="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "$REVIEWER_IDENTITY" 2>/dev/null || true)"
  fi
  # shellcheck disable=SC2034
  local GH_CONFIG_DIR_VALUE="${GH_CONFIG_DIR:-}"
  # GH_HOST selects which server every bare gh call reaches (#1540).
  # shellcheck disable=SC2034
  local GH_HOST_VALUE="${GH_HOST:-}"
  # The write-token opt-in changes what the wrappers accept, so a cache
  # measured under one setting must not answer for the other (Codex on #1541).
  # shellcheck disable=SC2034
  local ALLOW_UNIDENTIFIABLE_VALUE="0"
  [ "${MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN:-0}" = "1" ] && ALLOW_UNIDENTIFIABLE_VALUE="1"
  for var in OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR_VALUE GH_HOST_VALUE ALLOW_UNIDENTIFIABLE_VALUE keyring_author keyring_reviewer keyring_active; do
    val="${!var:-}"
    if [ -z "$val" ]; then
      h="-"
    elif command -v shasum >/dev/null 2>&1; then
      h="$(printf '%s' "$val" | shasum -a 256 | cut -c1-16)"
    elif command -v sha256sum >/dev/null 2>&1; then
      h="$(printf '%s' "$val" | sha256sum | cut -c1-16)"
    else
      h=""
    fi
    # No hash tool, or a hash that came out empty, cannot bind the cache to
    # this credential. An unmatchable value makes every later --check re-probe
    # rather than letting two different tokens share one fingerprint
    # (CodeRabbit on #1538).
    if [ -z "$h" ]; then
      printf 'unbindable-%s-%s-%s' "$$" "$(date +%s)" "${RANDOM:-0}"
      return 0
    fi
    out="$out$var:$h;"
  done
  printf '%s' "$out"
}
CREDENTIAL_FINGERPRINT="$(credential_fingerprint)"

# The write capabilities are facts about two identities, so the cache is keyed
# on them as well as the repo: local agents share the cache directory, and a
# Claude probe must never answer a Codex session's --check (Codex P1 on
# #1526). --check also re-validates the recorded identities below.
CACHE_FILE="$CACHE_DIR/agent-capability-$(printf '%s' "$REPO" | tr '/' '_')-$(printf '%s' "$REVIEWER_IDENTITY" | tr -c 'A-Za-z0-9._-' '_').json"

# --- surface --------------------------------------------------------------

SURFACE_SOURCE="default"
SURFACE="local"
if [ -n "${MERGEPATH_AGENT_SURFACE:-}" ]; then
  case "$MERGEPATH_AGENT_SURFACE" in
    local|claude-cloud|codex-cloud|ci) ;;
    *) die 1 "MERGEPATH_AGENT_SURFACE must be local|claude-cloud|codex-cloud|ci; got '$MERGEPATH_AGENT_SURFACE'" ;;
  esac
  SURFACE="$MERGEPATH_AGENT_SURFACE"
  SURFACE_SOURCE="MERGEPATH_AGENT_SURFACE"
elif [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  SURFACE="claude-cloud"
  SURFACE_SOURCE="CLAUDE_CODE_REMOTE"
elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  SURFACE="ci"
  SURFACE_SOURCE="GITHUB_ACTIONS"
fi

# --- --check --------------------------------------------------------------

cap_var_name() { # author-writes -> MERGEPATH_CAP_AUTHOR_WRITES
  printf 'MERGEPATH_CAP_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

if [ "$MODE" = "check" ]; then
  [ -r "$CACHE_FILE" ] || die 2 "no capability cache for $REPO; run: scripts/agent-capability-probe.sh"
  # Read the cache ONCE. A concurrent probe can replace the file between two
  # reads, so validating one generation and exporting another would bypass
  # every check below (Codex P2 on #1526); all reads use this snapshot.
  CACHE_SNAPSHOT="$(cat "$CACHE_FILE" 2>/dev/null || true)"
  snap() { printf '%s' "$CACHE_SNAPSHOT" | jq "$@"; }
  snap -e --argjson schema "$SCHEMA" '.schema == $schema' >/dev/null 2>&1 \
    || die 2 "capability cache for $REPO is unreadable or from another schema; re-run the probe"
  # Validate the WHOLE record before reading any field from it (#1533). A
  # field read that fails inside `$(...)` would abort under set -e with an
  # empty stdout, and `eval ""` returns 0, so the caller's `&&` would proceed:
  # the #1021 fail-open. Every field --check reads is typed here, so nothing
  # after this point can fail, and a malformed record goes through die and
  # its eval guard. The exports are then assembled in full and printed at
  # once, so there is never a partial export set either.
  caps_json="$(printf '%s\n' $EXPORT_CAPABILITIES | jq -R . | jq -s -c .)"
  snap -e --argjson caps "$caps_json" '
      . as $r
      | ($r.repo | type == "string")
        and ($r.surface | type == "string")
        and ($r.measured_at_epoch | type == "number" and . >= 0 and . < 100000000000 and floor == .)
        and (($r.credential_fingerprint // "") | type == "string")
        and (($r.session_id // "") | type == "string")
        and (($r.cross_repo_target // "") | type == "string")
        and ($r.tier | type == "string" and test("^[a-z,-]+$"))
        and ($r.capabilities | type == "object")
        and all($caps[]; ($r.capabilities[.] | type == "object") and ($r.capabilities[.].granted | type == "boolean"))
        and ((($r.capabilities["author-writes"].identity // "") | type) == "string")
        and ((($r.capabilities["reviewer-writes"].identity // "") | type) == "string")' \
      >/dev/null 2>&1 \
    || die 2 "capability cache for $REPO is malformed (a field --check reads has the wrong type or is missing); re-run the probe"
  cached_repo="$(snap -r '.repo')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  cached_surface="$(snap -r '.surface')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  measured_at="$(snap -r '.measured_at_epoch')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  [ "$cached_repo" = "$REPO" ] || die 2 "capability cache is for $cached_repo, not $REPO; re-run the probe"
  [ "$cached_surface" = "$SURFACE" ] || die 2 "capability cache was measured on $cached_surface, this session is $SURFACE; re-run the probe"
  # A cloud session's proxy scope and provisioned credentials belong to that
  # session, so another session's measurement never answers this one's
  # --check, even for the same repo and identities (Codex P2 on #1526).
  cached_session="$(snap -r '.session_id // empty')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  [ "$cached_session" = "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ] \
    || die 2 "capability cache was measured in session '${cached_session:-none}', this is '${CLAUDE_CODE_REMOTE_SESSION_ID:-none}'; re-run the probe"
  cached_cross="$(snap -r '.cross_repo_target // empty')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  # Repository names are case-insensitive, as in the measurement (#1540).
  [ "$(printf '%s' "$cached_cross" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$CROSS_REPO" | tr 'A-Z' 'a-z')" ] \
    || die 2 "capability cache measured cross-repo against '$cached_cross', this check asks about '$CROSS_REPO'; re-run the probe"
  cached_fp="$(snap -r '.credential_fingerprint // empty')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  [ "$cached_fp" = "$CREDENTIAL_FINGERPRINT" ] \
    || die 2 "capability cache was measured with different credentials in the environment; re-run the probe"
  cached_author="$(snap -r '.capabilities["author-writes"].identity // empty')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  cached_reviewer="$(snap -r '.capabilities["reviewer-writes"].identity // empty')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  [ "$cached_author" = "$AUTHOR_IDENTITY" ] && [ "$cached_reviewer" = "$REVIEWER_IDENTITY" ] \
    || die 2 "capability cache was measured for author '$cached_author' / reviewer '$cached_reviewer', this session expects '$AUTHOR_IDENTITY' / '$REVIEWER_IDENTITY'; re-run the probe"
  printf '%s' "$measured_at" | grep -Eq '^[0-9]+$' || die 2 "capability cache has no measurement time; re-run the probe"
  age=$(( $(date +%s) - measured_at ))
  # A future timestamp makes age negative, which the TTL test alone would
  # accept for TTL seconds past that future moment (CodeRabbit on #1526).
  [ "$age" -ge 0 ] || die 2 "capability cache for $REPO has a future measurement time; re-run the probe"
  [ "$age" -le "$TTL_SECONDS" ] || die 2 "capability cache for $REPO is ${age}s old (TTL ${TTL_SECONDS}s); re-run the probe"
  tier="$(snap -r '.tier')" || die 2 "capability cache for $REPO could not be read; re-run the probe"
  if $PRINT_EXPORTS; then
    exports="$(printf 'export MERGEPATH_AGENT_TIER=%s\n' "$(printf '%q' "$tier")")"
    exports="$exports
$(printf 'export MERGEPATH_AGENT_SURFACE_MEASURED=%s' "$(printf '%q' "$cached_surface")")"
    for cap in $EXPORT_CAPABILITIES; do
      value="$(snap -r --arg c "$cap" 'if .capabilities[$c].granted then 1 else 0 end')" \
        || die 2 "capability cache for $REPO could not be read for $cap; re-run the probe"
      exports="$exports
$(printf 'export %s=%s' "$(cap_var_name "$cap")" "$value")"
    done
    printf '%s\n' "$exports"
  fi
  echo "agent-capability-probe: $REPO on $cached_surface: tier=$tier (measured ${age}s ago)" >&2
  exit 0
fi

# --- probing helpers ------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-capability-probe.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

HAVE_GH=false
command -v gh >/dev/null 2>&1 && HAVE_GH=true
HAVE_OP=false
command -v op >/dev/null 2>&1 && HAVE_OP=true
HAVE_CURL=false
command -v curl >/dev/null 2>&1 && HAVE_CURL=true

# api_request <token|""> <method> <path> <prefix> [<graphql query>]
# Writes <prefix>.headers and <prefix>.body; prints the HTTP status (000 when
# no transport or no response). An empty token means "the ambient credential":
# gh with the caller's own environment. Token material never reaches argv.
api_request() {
  local token="$1" method="$2" path="$3" prefix="$4" query="${5:-}"
  local raw="$prefix.raw" status request_rc=0
  : >"$prefix.headers"
  : >"$prefix.body"
  if $HAVE_GH; then
    local -a args
    args=(api -i -X "$method" "$path")
    [ -n "$query" ] && args+=(-f "query=$query")
    # Every measurement targets github.com, as the curl path below does: a
    # bare `gh api` follows a sole GHES host in hosts.yml, whose stored login
    # could answer for a token github.com rejected (Codex on #1541).
    if [ -n "$token" ]; then
      ( unset GITHUB_TOKEN; GH_HOST=github.com GH_TOKEN="$token" gh "${args[@]}" ) >"$raw" 2>/dev/null || request_rc=$?
    else
      GH_HOST=github.com gh "${args[@]}" >"$raw" 2>/dev/null || request_rc=$?
    fi
    tr -d '\r' <"$raw" | awk -v h="$prefix.headers" -v b="$prefix.body" '
      !done && /^$/ { done = 1; next }
      !done { print > h; next }
      { print > b }'
  elif $HAVE_CURL; then
    local auth_token="${token:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
    local hdr="$prefix.auth" data=""
    : >"$hdr"
    chmod 600 "$hdr"
    [ -n "$auth_token" ] && printf 'Authorization: token %s\n' "$auth_token" >"$hdr"
    [ -n "$query" ] && data="$(jq -cn --arg q "$query" '{query: $q}')"
    if [ -n "$data" ]; then
      curl -sS --suppress-connect-headers --connect-timeout 10 --max-time 30 -X "$method" -H @"$hdr" -H 'Accept: application/vnd.github+json' \
        -D "$raw" -o "$prefix.body" --data "$data" "https://api.github.com/$path" 2>/dev/null || request_rc=$?
    else
      curl -sS --suppress-connect-headers --connect-timeout 10 --max-time 30 -X "$method" -H @"$hdr" -H 'Accept: application/vnd.github+json' \
        -D "$raw" -o "$prefix.body" "https://api.github.com/$path" 2>/dev/null || request_rc=$?
    fi
    rm -f "$hdr"
    tr -d '\r' <"$raw" >"$prefix.headers" 2>/dev/null || true
  fi
  # The LAST status line is the origin's: a proxy's "200 Connection
  # established" block can precede it (Codex P2 on #1526), which
  # --suppress-connect-headers also drops on the curl path.
  status="$(sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' "$prefix.headers" 2>/dev/null | tail -1 || true)"
  status="${status:-000}"
  # No response, a server error, or a rate limit says nothing about what this
  # session may do. Record it so the result is not cached as a measurement
  # (Codex P2 on #1526): an outage must not become a 12-hour denial.
  # A 2xx status with a non-zero transfer exit is a response cut off after its
  # headers (a curl timeout, a dropped connection): its body is incomplete,
  # so it is transient too (CodeRabbit on #1526). A non-2xx exit is gh's
  # normal way of reporting an HTTP error and is classified by status below.
  # GitHub's GraphQL primary rate limit answers HTTP 200 with a RATE_LIMITED
  # error and no data, and the transfer succeeds, so neither the status nor
  # the exit code shows it (#1535). Read the body for it.
  if [ "$status" = "200" ] && jq -e '[.errors[]?.type] | index("RATE_LIMITED")' "$prefix.body" >/dev/null 2>&1; then
    echo "$path -> 200 with a RATE_LIMITED error" >>"$WORKDIR/transient"
  fi
  case "$status" in
    2??) [ "$request_rc" -eq 0 ] || echo "$path -> $status, transfer exit $request_rc" >>"$WORKDIR/transient" ;;
    000|429|5??) echo "$path -> $status" >>"$WORKDIR/transient" ;;
    403) if grep -Eiq '^x-ratelimit-remaining:[[:space:]]*0' "$prefix.headers" 2>/dev/null \
            || grep -qi 'rate limit' "$prefix.body" 2>/dev/null; then
           echo "$path -> 403 (rate limited)" >>"$WORKDIR/transient"
         fi ;;
  esac
  printf '%s\n' "$status"
}

# measure_write <identity> <preferred var> <required permission> <json out>
# Resolves the token the guarded wrappers would use, then classifies it. The
# resolver already verifies GET /user; the class check is what catches a
# brokered credential that reads as the right user and writes as a bot.
# Identity alone is not write capability (Codex P1 on #1526): the token must
# also see <required permission> on the repository (`push` for both: the
# author creates and merges PRs, and a reviewer's approval must satisfy branch
# protection and resolve review threads, which read access cannot, #1537),
# and the token's own X-OAuth-Scopes must
# be readable and carry `repo` (or `public_repo` on a public repository). A
# fine-grained or app-user token sends no scopes header and GitHub offers no
# way to read its own permissions, so for one the capability is reported
# unverifiable and not granted.
measure_write() {
  local identity="$1" preferred="$2" required="$3" out="$4"
  local granted=false basis="measured" reason="" class="empty" login="" login_type="" status
  if ! $HAVE_GH; then
    reason="gh-absent"
  else
    local rc=0
    GH_RESOLVED_TOKEN=""
    gh_resolve_token_for_identity "$identity" "$preferred" "agent-capability-probe" >/dev/null 2>"$WORKDIR/resolve.err" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "${GH_RESOLVED_TOKEN:-}" ]; then
      reason="no-verified-token (resolver exit $rc)"
      # The resolver's own GET /user runs inside identity-check.sh, outside
      # api_request's classifier, so its outcome cannot tell an outage from a
      # denial. Repeat GET /user once for every candidate the resolver tried
      # (see the candidate order below) through
      # api_request, which classifies by HTTP status: no response, 5xx, 429
      # and a rate-limited 403 mark the run transient, while an authoritative
      # denial such as a revoked token's 401 does not (Codex P2 on #1526,
      # rounds 3-6). A candidate that NOW verifies means the resolver's own
      # failure was the transient one, so that is marked too.
      # Mirror the resolver's candidate order exactly (#1534): a set preferred
      # PAT is the ONLY candidate (a failure there is final, it never falls
      # through), otherwise the ambient token and then the keyring token. A
      # fallback the resolver never tried says nothing about its failure.
      # The resolver also refuses a brokered or app-installed candidate before
      # it reads GET /user, so report the class of what it refused: the first
      # tried candidate that is not user-held, keyring fallback included (Codex
      # on #1541), else the first one tried. That is the actionable half.
      local candidate repeat_status repeat_login cand_class n=0
      local -a tried=()
      if [ -n "${!preferred:-}" ]; then
        tried=("${!preferred}")
      else
        tried=("${GH_TOKEN:-}" "$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "$identity" 2>/dev/null || true)")
      fi
      # Each candidate is classified with its own repeat response's headers,
      # which a legacy 40-hex PAT needs (its X-OAuth-Scopes); without them it
      # would read unidentifiable and could mask a later app-installed one
      # (Codex on #1541).
      class="empty"
      for candidate in "${tried[@]}"; do
        [ -n "$candidate" ] || continue
        n=$((n + 1))
        repeat_status="$(api_request "$candidate" GET user "$WORKDIR/resolve-user-$n")"
        repeat_login="$(jq -r '.login // empty' "$WORKDIR/resolve-user-$n.body" 2>/dev/null || true)"
        cand_class="$(credential_class "$candidate" "$WORKDIR/resolve-user-$n.headers")"
        if [ "$class" = "empty" ] || { [ "$class" = "user-held" ] && [ "$cand_class" != "user-held" ]; }; then
          class="$cand_class"
        fi
        # A candidate the verifier would accept, by the same class rule as
        # the grant below (user-held, or unidentifiable under the opt-in),
        # that now verifies means the resolver's failure was transient (Phase
        # 4b on #1541).
        # ...and only on a host the verifier accepts: with GH_HOST set to
        # anything but github.com the refusal is permanent, not transient.
        if [ "$repeat_status" = "200" ] && [ "$repeat_login" = "$identity" ] \
           && { [ -z "${GH_HOST:-}" ] || [ "$(printf '%s' "$GH_HOST" | tr '[:upper:]' '[:lower:]')" = "github.com" ]; } \
           && { [ "$cand_class" = "user-held" ] \
                || { [ "$cand_class" = "unidentifiable" ] && [ "${MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN:-0}" = "1" ]; }; }; then
          echo "resolver for $identity failed, then candidate $n verified on repeat" >>"$WORKDIR/transient"
        fi
      done
      candidate=""
    else
      status="$(api_request "$GH_RESOLVED_TOKEN" GET user "$WORKDIR/write-user")"
      class="$(credential_class "$GH_RESOLVED_TOKEN" "$WORKDIR/write-user.headers")"
      login="$(jq -r '.login // empty' "$WORKDIR/write-user.body" 2>/dev/null || true)"
      login_type="$(jq -r '.type // empty' "$WORKDIR/write-user.body" 2>/dev/null || true)"
      if [ "$status" != "200" ]; then
        reason="GET /user returned $status"
      elif [ "$login" != "$identity" ]; then
        reason="token reads as '$login', not '$identity'"
      elif [ "$login_type" != "User" ]; then
        reason="token identity type is '$login_type', not User"
      elif [ "$class" != "user-held" ] \
           && ! { [ "$class" = "unidentifiable" ] && [ "${MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN:-0}" = "1" ]; }; then
        # The opt-in that makes the wrappers accept an unidentifiable token
        # lets it continue through the same login, role and scope checks
        # here, so the cached capability matches the verifier (Codex on #1541).
        reason="credential class is '$class'; its write identity cannot be established"
      else
        local repo_status has_perm private scopes
        repo_status="$(api_request "$GH_RESOLVED_TOKEN" GET "repos/$REPO" "$WORKDIR/write-repo")"
        has_perm="$(jq -r --arg p "$required" '.permissions[$p] // false' "$WORKDIR/write-repo.body" 2>/dev/null || echo false)"
        # `//` would replace a real `false` too, so test for absence explicitly
        # (Codex P2 on #1526): only a missing field defaults to private.
        private="$(jq -r 'if .private == null then true else .private end' "$WORKDIR/write-repo.body" 2>/dev/null || echo true)"
        scopes="$(sed -nE 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' "$WORKDIR/write-user.headers" | tr -d ' ')"
        if [ "$repo_status" != "200" ]; then
          reason="verified $identity, but GET repos/$REPO with its token returned $repo_status"
        elif [ "$(jq -r '.archived // false' "$WORKDIR/write-repo.body" 2>/dev/null || echo false)" = "true" ]; then
          # An archived repository stays readable but refuses every write,
          # reviews and comments included (#1536).
          reason="verified $identity, but $REPO is archived (read-only)"
        elif [ "$has_perm" != "true" ]; then
          reason="verified $identity, but its token lacks '$required' permission on $REPO"
        elif ! grep -Eiq '^x-oauth-scopes:' "$WORKDIR/write-user.headers"; then
          # .permissions is the USER's repository role. A fine-grained or
          # app-user token can hold less than its user, and GitHub exposes no
          # way to read that token's own permissions, so its write capability
          # is unverifiable rather than granted (Codex P1 on #1526). The
          # wrappers still attempt the write and read its byline back; this
          # only keeps the tier from promising what was not measured.
          basis="unverifiable"
          reason="verified $identity with '$required' role on $REPO, but this token's own permissions cannot be read (fine-grained or app-user token); not granted"
        elif ! printf ',%s,' "$scopes" | grep -q ',repo,' \
             && ! { [ "$private" = "false" ] && printf ',%s,' "$scopes" | grep -q ',public_repo,'; }; then
          reason="verified $identity with '$required' on $REPO, but the token's scopes ($scopes) do not include repo"
        else
          granted=true
          reason="verified user-held credential for $identity with '$required' permission and repo scope on $REPO"
        fi
      fi
    fi
    GH_RESOLVED_TOKEN=""
  fi
  jq -n --argjson g "$granted" --arg b "$basis" --arg r "$reason" --arg i "$identity" \
    --arg c "$class" --arg l "$login" --arg t "$login_type" \
    '{granted: $g, basis: $b, reason: $r, identity: $i, credential_class: $c, login: $l, login_type: $t}' >"$out"
}

cap_json() { # <granted> <basis> <reason> <out>
  jq -n --argjson g "$1" --arg b "$2" --arg r "$3" '{granted: $g, basis: $b, reason: $r}' >"$4"
}

# --- measurements ---------------------------------------------------------

HAVE_TRANSPORT=true
if ! $HAVE_GH && ! $HAVE_CURL; then
  HAVE_TRANSPORT=false
fi

# The read-only measurements use the credential a session's read path uses:
# the provisioned reviewer PAT (AGENTS.md: read-path calls run under
# $OP_PREFLIGHT_REVIEWER_PAT), else the author PAT, else the ambient
# credential. Measuring with the ambient credential alone recorded read=false
# for a token-only session whose PAT reads fine (Codex P2 on #1526).
READ_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${OP_PREFLIGHT_AUTHOR_PAT:-}}"

# Ambient credential class, for the report only (never its value).
AMBIENT_VAR=""
AMBIENT_TOKEN=""
if [ -n "${GH_TOKEN:-}" ]; then
  AMBIENT_VAR="GH_TOKEN"; AMBIENT_TOKEN="$GH_TOKEN"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  AMBIENT_VAR="GITHUB_TOKEN"; AMBIENT_TOKEN="$GITHUB_TOKEN"
fi
AMBIENT_CLASS="$(credential_class "$AMBIENT_TOKEN")"
AMBIENT_TOKEN=""

# read
: >"$WORKDIR/read.body"
if ! $HAVE_TRANSPORT; then
  cap_json false measured "neither gh nor curl is available" "$WORKDIR/cap-read.json"
else
  status="$(api_request "$READ_TOKEN" GET "repos/$REPO" "$WORKDIR/read")"
  if [ "$status" = "200" ]; then
    cap_json true measured "GET repos/$REPO returned 200" "$WORKDIR/cap-read.json"
  else
    cap_json false measured "GET repos/$REPO returned $status" "$WORKDIR/cap-read.json"
  fi
fi

# graphql
if ! $HAVE_TRANSPORT; then
  cap_json false measured "neither gh nor curl is available" "$WORKDIR/cap-graphql.json"
else
  status="$(api_request "$READ_TOKEN" POST graphql "$WORKDIR/graphql" 'query { viewer { login } }')"
  if [ "$status" = "200" ] && jq -e '.data.viewer.login | type == "string"' "$WORKDIR/graphql.body" >/dev/null 2>&1; then
    cap_json true measured "viewer query returned a login" "$WORKDIR/cap-graphql.json"
  elif grep -q 'not enabled for this session' "$WORKDIR/graphql.body" 2>/dev/null; then
    cap_json false measured "proxy GraphQL ceiling: query not enabled for this session" "$WORKDIR/cap-graphql.json"
  else
    cap_json false measured "viewer query returned $status" "$WORKDIR/cap-graphql.json"
  fi
fi

# cross-repo
# Repository names are case-insensitive on GitHub (#1537).
if [ "$(printf '%s' "$CROSS_REPO" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$REPO" | tr 'A-Z' 'a-z')" ]; then
  cap_json false not-measured "cross-repo target is this repository; pass --cross-repo" "$WORKDIR/cap-cross-repo.json"
elif ! $HAVE_TRANSPORT; then
  cap_json false measured "neither gh nor curl is available" "$WORKDIR/cap-cross-repo.json"
else
  status="$(api_request "$READ_TOKEN" GET "repos/$CROSS_REPO" "$WORKDIR/cross")"
  if [ "$status" = "200" ]; then
    cap_json true measured "GET repos/$CROSS_REPO returned 200" "$WORKDIR/cap-cross-repo.json"
  else
    cap_json false measured "GET repos/$CROSS_REPO returned $status" "$WORKDIR/cap-cross-repo.json"
  fi
fi

# push-multi-branch
# Only the documented Claude cloud restriction is reported. Everywhere else
# this is NOT measured: a dry-run push never sends the ref update, so it cannot
# show the server would accept one, and neither can the API permission of a
# credential that is not necessarily the one `origin` pushes with (SSH remotes
# authenticate separately). Earlier rounds of #1526 tried to prove it from
# those pieces; each addition exposed another gap, so the probe states the
# limit instead of approximating past it.
if [ "$SURFACE" = "claude-cloud" ]; then
  cap_json false documented "Claude cloud proxy accepts pushes only to the session's working branch" "$WORKDIR/cap-push-multi-branch.json"
else
  cap_json false not-measured "not measurable without pushing: a dry run never reaches the server's decision, and the API credential need not be the one origin pushes with" "$WORKDIR/cap-push-multi-branch.json"
fi

measure_write "$AUTHOR_IDENTITY" "OP_PREFLIGHT_AUTHOR_PAT" push "$WORKDIR/cap-author-writes.json"
measure_write "$REVIEWER_IDENTITY" "OP_PREFLIGHT_REVIEWER_PAT" push "$WORKDIR/cap-reviewer-writes.json"

# --- assemble -------------------------------------------------------------

# The tier lists every granted capability. An ambient read failure does not
# hide a write path a provisioned PAT does have (Codex P2 on #1526): `none`
# means nothing at all was granted.
READ_GRANTED="$(jq -r '.granted' "$WORKDIR/cap-read.json")"
TIER_PARTS=""
for cap in $TIER_CAPABILITIES; do
  if [ "$(jq -r '.granted' "$WORKDIR/cap-$cap.json")" = "true" ]; then
    TIER_PARTS="${TIER_PARTS:+$TIER_PARTS,}$cap"
  fi
done
if [ -n "$TIER_PARTS" ]; then
  TIER="$TIER_PARTS"
elif [ "$READ_GRANTED" = "true" ]; then
  TIER="read-only"
else
  TIER="none"
fi
TRANSIENT=false
[ -s "$WORKDIR/transient" ] && TRANSIENT=true

HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
NOW="$(date +%s)"

RESULT="$(jq -n \
  --argjson schema "$SCHEMA" \
  --argjson now "$NOW" \
  --arg repo "$REPO" \
  --arg head "$HEAD_SHA" \
  --arg surface "$SURFACE" \
  --arg surface_source "$SURFACE_SOURCE" \
  --arg session_id "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" \
  --argjson gh "$HAVE_GH" --argjson op "$HAVE_OP" --argjson curl "$HAVE_CURL" \
  --arg ambient_var "$AMBIENT_VAR" --arg ambient_class "$AMBIENT_CLASS" \
  --arg cross "$CROSS_REPO" \
  --arg tier "$TIER" \
  --argjson transient "$TRANSIENT" \
  --slurpfile read "$WORKDIR/cap-read.json" \
  --slurpfile author "$WORKDIR/cap-author-writes.json" \
  --slurpfile reviewer "$WORKDIR/cap-reviewer-writes.json" \
  --slurpfile graphql "$WORKDIR/cap-graphql.json" \
  --slurpfile crossrepo "$WORKDIR/cap-cross-repo.json" \
  --slurpfile push "$WORKDIR/cap-push-multi-branch.json" \
  '{
     schema: $schema,
     measured_at_epoch: $now,
     repo: $repo,
     head_sha: $head,
     surface: $surface,
     surface_source: $surface_source,
     session_id: $session_id,
     tools: {gh: $gh, op: $op, curl: $curl},
     ambient_credential: {variable: $ambient_var, class: $ambient_class},
     cross_repo_target: $cross,
     capabilities: {
       "read": $read[0],
       "author-writes": $author[0],
       "reviewer-writes": $reviewer[0],
       "graphql": $graphql[0],
       "cross-repo": $crossrepo[0],
       "push-multi-branch": $push[0]
     },
     tier: $tier,
     transient_failures: $transient
   }')"

if $WRITE_CACHE && $TRANSIENT; then
  {
    echo "agent-capability-probe: WARNING some requests failed transiently (no response, 5xx, or rate limit); not caching this result:"
    sed 's/^/  /' "$WORKDIR/transient"
  } >&2
elif $WRITE_CACHE; then
  # The cache holds the credential fingerprint, so it is created owner-only.
  if mkdir -p "$CACHE_DIR" 2>/dev/null \
    && ( umask 077; printf '%s\n' "$RESULT" | jq --arg fp "$CREDENTIAL_FINGERPRINT" '. + {credential_fingerprint: $fp}' >"$CACHE_FILE.tmp.$$" ) 2>/dev/null \
    && mv -f "$CACHE_FILE.tmp.$$" "$CACHE_FILE" 2>/dev/null; then
    :
  else
    rm -f "$CACHE_FILE.tmp.$$" 2>/dev/null || true
    echo "agent-capability-probe: WARNING could not write cache $CACHE_FILE; --check will report it missing" >&2
  fi
fi

printf '%s\n' "$RESULT"

if ! $QUIET; then
  {
    echo "agent-capability-probe: $REPO on $SURFACE ($SURFACE_SOURCE): tier=$TIER"
    printf '%s\n' "$RESULT" | jq -r '.capabilities | to_entries[] | "  \(if .value.granted then "yes" else "no " end)  \(.key): \(.value.reason)"'
  } >&2
fi
exit 0
