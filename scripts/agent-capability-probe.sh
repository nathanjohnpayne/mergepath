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
#     repo, surface, author identity, reviewer identity and (in a Claude cloud
#     session) CLAUDE_CODE_REMOTE_SESSION_ID. Bare --check reports on stderr only. With
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
#   push-multi-branch  `git push --dry-run --no-verify` of HEAD to a fresh
#                      branch name negotiates AND the repository reports push
#                      permission AND no ruleset restricts creating or
#                      updating that name; a dry run alone is never proof, and
#                      a Claude cloud session is reported false from its
#                      documented push restriction regardless
#   author-writes      the wrapper token resolver finds a token for the
#                      repo's author_identity AND that token is a user-held
#                      credential (scripts/lib/credential-class.sh) whose
#                      `GET /user` is that login with type User AND it sees
#                      `push` on the repository (and `repo` scope, for a
#                      classic token)
#   reviewer-writes    the same, for the reviewer identity
#                      (GH_AS_REVIEWER_IDENTITY / MERGEPATH_AGENT / default),
#                      with `pull`: reviews and comments need read access
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
# GITHUB_ACTIONS=true -> ci, else local. Codex cloud sets no documented marker,
# so its environment must set MERGEPATH_AGENT_SURFACE=codex-cloud (see
# docs/agents/cloud-environments.md); until it does it reads as local with
# surface_source "default".
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

SCHEMA=1
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
REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"

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
  jq -e --argjson schema "$SCHEMA" '.schema == $schema' "$CACHE_FILE" >/dev/null 2>&1 \
    || die 2 "capability cache for $REPO is unreadable or from another schema; re-run the probe"
  cached_repo="$(jq -r '.repo' "$CACHE_FILE")"
  cached_surface="$(jq -r '.surface' "$CACHE_FILE")"
  measured_at="$(jq -r '.measured_at_epoch' "$CACHE_FILE")"
  [ "$cached_repo" = "$REPO" ] || die 2 "capability cache is for $cached_repo, not $REPO; re-run the probe"
  [ "$cached_surface" = "$SURFACE" ] || die 2 "capability cache was measured on $cached_surface, this session is $SURFACE; re-run the probe"
  # A cloud session's proxy scope and provisioned credentials belong to that
  # session, so another session's measurement never answers this one's
  # --check, even for the same repo and identities (Codex P2 on #1526).
  cached_session="$(jq -r '.session_id // empty' "$CACHE_FILE")"
  [ "$cached_session" = "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ] \
    || die 2 "capability cache was measured in session '${cached_session:-none}', this is '${CLAUDE_CODE_REMOTE_SESSION_ID:-none}'; re-run the probe"
  cached_author="$(jq -r '.capabilities["author-writes"].identity // empty' "$CACHE_FILE")"
  cached_reviewer="$(jq -r '.capabilities["reviewer-writes"].identity // empty' "$CACHE_FILE")"
  [ "$cached_author" = "$AUTHOR_IDENTITY" ] && [ "$cached_reviewer" = "$REVIEWER_IDENTITY" ] \
    || die 2 "capability cache was measured for author '$cached_author' / reviewer '$cached_reviewer', this session expects '$AUTHOR_IDENTITY' / '$REVIEWER_IDENTITY'; re-run the probe"
  printf '%s' "$measured_at" | grep -Eq '^[0-9]+$' || die 2 "capability cache has no measurement time; re-run the probe"
  age=$(( $(date +%s) - measured_at ))
  # A future timestamp makes age negative, which the TTL test alone would
  # accept for TTL seconds past that future moment (CodeRabbit on #1526).
  [ "$age" -ge 0 ] || die 2 "capability cache for $REPO has a future measurement time; re-run the probe"
  [ "$age" -le "$TTL_SECONDS" ] || die 2 "capability cache for $REPO is ${age}s old (TTL ${TTL_SECONDS}s); re-run the probe"
  tier="$(jq -r '.tier' "$CACHE_FILE")"
  if $PRINT_EXPORTS; then
    printf 'export MERGEPATH_AGENT_TIER=%s\n' "$(printf '%q' "$tier")"
    printf 'export MERGEPATH_AGENT_SURFACE_MEASURED=%s\n' "$(printf '%q' "$cached_surface")"
    for cap in $EXPORT_CAPABILITIES; do
      value="$(jq -r --arg c "$cap" 'if .capabilities[$c].granted == true then 1 else 0 end' "$CACHE_FILE")"
      printf 'export %s=%s\n' "$(cap_var_name "$cap")" "$value"
    done
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
  local raw="$prefix.raw" status
  : >"$prefix.headers"
  : >"$prefix.body"
  if $HAVE_GH; then
    local -a args
    args=(api -i -X "$method" "$path")
    [ -n "$query" ] && args+=(-f "query=$query")
    if [ -n "$token" ]; then
      ( unset GITHUB_TOKEN; GH_TOKEN="$token" gh "${args[@]}" ) >"$raw" 2>/dev/null || true
    else
      gh "${args[@]}" >"$raw" 2>/dev/null || true
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
      curl -sS --connect-timeout 10 --max-time 30 -X "$method" -H @"$hdr" -H 'Accept: application/vnd.github+json' \
        -D "$raw" -o "$prefix.body" --data "$data" "https://api.github.com/$path" 2>/dev/null || true
    else
      curl -sS --connect-timeout 10 --max-time 30 -X "$method" -H @"$hdr" -H 'Accept: application/vnd.github+json' \
        -D "$raw" -o "$prefix.body" "https://api.github.com/$path" 2>/dev/null || true
    fi
    rm -f "$hdr"
    tr -d '\r' <"$raw" >"$prefix.headers" 2>/dev/null || true
  fi
  status="$(sed -nE '1s#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' "$prefix.headers" 2>/dev/null || true)"
  status="${status:-000}"
  # No response, a server error, or a rate limit says nothing about what this
  # session may do. Record it so the result is not cached as a measurement
  # (Codex P2 on #1526): an outage must not become a 12-hour denial.
  case "$status" in
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
# also see <required permission> on the repository (`push` for the author,
# who creates and merges PRs; `pull` for a reviewer, whose reviews and
# comments need only read access), and the token's own X-OAuth-Scopes must
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
      elif [ "$class" != "user-held" ]; then
        reason="credential class is '$class'; its write identity cannot be established"
      else
        local repo_status has_perm private scopes
        repo_status="$(api_request "$GH_RESOLVED_TOKEN" GET "repos/$REPO" "$WORKDIR/write-repo")"
        has_perm="$(jq -r --arg p "$required" '.permissions[$p] // false' "$WORKDIR/write-repo.body" 2>/dev/null || echo false)"
        private="$(jq -r '.private // true' "$WORKDIR/write-repo.body" 2>/dev/null || echo true)"
        scopes="$(sed -nE 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' "$WORKDIR/write-user.headers" | tr -d ' ')"
        if [ "$repo_status" != "200" ]; then
          reason="verified $identity, but GET repos/$REPO with its token returned $repo_status"
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
  status="$(api_request "" GET "repos/$REPO" "$WORKDIR/read")"
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
  status="$(api_request "" POST graphql "$WORKDIR/graphql" 'query { viewer { login } }')"
  if [ "$status" = "200" ] && jq -e '.data.viewer.login | type == "string"' "$WORKDIR/graphql.body" >/dev/null 2>&1; then
    cap_json true measured "viewer query returned a login" "$WORKDIR/cap-graphql.json"
  elif grep -q 'not enabled for this session' "$WORKDIR/graphql.body" 2>/dev/null; then
    cap_json false measured "proxy GraphQL ceiling: query not enabled for this session" "$WORKDIR/cap-graphql.json"
  else
    cap_json false measured "viewer query returned $status" "$WORKDIR/cap-graphql.json"
  fi
fi

# cross-repo
if [ "$CROSS_REPO" = "$REPO" ]; then
  cap_json false not-measured "cross-repo target is this repository; pass --cross-repo" "$WORKDIR/cap-cross-repo.json"
elif ! $HAVE_TRANSPORT; then
  cap_json false measured "neither gh nor curl is available" "$WORKDIR/cap-cross-repo.json"
else
  status="$(api_request "" GET "repos/$CROSS_REPO" "$WORKDIR/cross")"
  if [ "$status" = "200" ]; then
    cap_json true measured "GET repos/$CROSS_REPO returned 200" "$WORKDIR/cap-cross-repo.json"
  else
    cap_json false measured "GET repos/$CROSS_REPO returned $status" "$WORKDIR/cap-cross-repo.json"
  fi
fi

# push-multi-branch
if [ "$SURFACE" = "claude-cloud" ]; then
  cap_json false documented "Claude cloud proxy accepts pushes only to the session's working branch" "$WORKDIR/cap-push-multi-branch.json"
else
  probe_branch="mergepath-capability-probe-$(date +%s)-$$"
  rules_status=""
  # A dry run never sends the ref update, so on its own it proves only that
  # the remote is reachable and would negotiate (Codex P2 on #1526). Grant
  # the capability only when the repository also reports push permission for
  # the session's credential; branch rulesets on the new name are still not
  # evaluated, which the reason states.
  ambient_push="$(jq -r '.permissions.push // false' "$WORKDIR/read.body" 2>/dev/null || echo false)"
  # Rulesets are the server-side policy a dry run never reaches (Codex P2 on
  # #1526). GitHub reports the rules that would apply to a branch by name,
  # including one that does not exist yet; a `creation` or `update` rule means
  # a real push of a new branch can be refused, and an unreadable answer is
  # not evidence either way.
  rules_status="$(api_request "" GET "repos/$REPO/rules/branches/$probe_branch" "$WORKDIR/rules")"
  restricting_rules="$(jq -r '[.[]?.type | select(. == "creation" or . == "update")] | unique | join(",")' "$WORKDIR/rules.body" 2>/dev/null || echo unreadable)"
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo \
     GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
     git -C "$ROOT" push --dry-run --no-verify --quiet origin "HEAD:refs/heads/$probe_branch" >/dev/null 2>&1; then
    cap_json false measured-dry-run "dry-run push to a second branch was refused" "$WORKDIR/cap-push-multi-branch.json"
  elif [ "$ambient_push" != "true" ]; then
    cap_json false measured-dry-run "dry-run push negotiated, but the repository does not report push permission for this session; a real push is unverified" "$WORKDIR/cap-push-multi-branch.json"
  elif [ "$rules_status" != "200" ]; then
    cap_json false unverifiable "dry-run push negotiated with push permission, but the branch rules for a new branch could not be read ($rules_status); a real push is unverified" "$WORKDIR/cap-push-multi-branch.json"
  elif [ -n "$restricting_rules" ]; then
    cap_json false measured "rulesets restrict new branches ($restricting_rules); a real push of a second branch can be refused" "$WORKDIR/cap-push-multi-branch.json"
  else
    cap_json true dry-run-permission-rules "dry-run push to a second branch negotiated, the repository reports push permission, and no ruleset restricts creating or updating it" "$WORKDIR/cap-push-multi-branch.json"
  fi
fi

measure_write "$AUTHOR_IDENTITY" "OP_PREFLIGHT_AUTHOR_PAT" push "$WORKDIR/cap-author-writes.json"
measure_write "$REVIEWER_IDENTITY" "OP_PREFLIGHT_REVIEWER_PAT" pull "$WORKDIR/cap-reviewer-writes.json"

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
  if mkdir -p "$CACHE_DIR" 2>/dev/null \
    && printf '%s\n' "$RESULT" >"$CACHE_FILE.tmp.$$" 2>/dev/null \
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
