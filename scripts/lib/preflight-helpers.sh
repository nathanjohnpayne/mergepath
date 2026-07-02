#!/usr/bin/env bash
# scripts/lib/preflight-helpers.sh — shared auto-source logic for helpers.
#
# Sourced by the read-path helper scripts that previously required the
# caller to set GH_TOKEN inline (codex-review-request.sh,
# codex-review-check.sh, coderabbit-wait.sh, resolve-pr-threads.sh,
# request-label-removal.sh). The contract:
#
#   * If GH_TOKEN is already set, do nothing (preserve existing behavior).
#   * Otherwise, locate the op-preflight cache file for the current agent
#     (or the agent inferred from MERGEPATH_AGENT / $USER / hostname) and
#     source it if it is fresh per the TTL anchored on
#     OP_PREFLIGHT_CREATED_AT_EPOCH.
#   * After sourcing, helpers pick the right env var
#     (OP_PREFLIGHT_REVIEWER_PAT vs OP_PREFLIGHT_AUTHOR_PAT) themselves —
#     this library does NOT assign GH_TOKEN.
#
# Closes #282 (op-preflight contract): before this library, helpers that
# required GH_TOKEN exited 3 when called from a fresh subshell even when
# a warm preflight cache was sitting on disk for this agent. Auto-
# sourcing means agents can drop the explicit `GH_TOKEN="$OP_PREFLIGHT_
# REVIEWER_PAT" scripts/foo.sh` prefix without re-burning a biometric.
#
# Bash 3.2 portable.

# Locate the cache directory the same way op-preflight.sh does.
preflight_cache_dir() {
  local override="${OP_PREFLIGHT_CACHE_DIR:-}"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi
  local base="${XDG_CACHE_HOME:-$HOME/.cache}"
  printf '%s/mergepath' "$base"
}

# Determine which agent's cache file to consult. Order of precedence:
#   1. $MERGEPATH_AGENT (explicit override)
#   2. $OP_PREFLIGHT_AGENT (left over from a prior eval in this shell)
#   3. The single cache file under the cache dir (if exactly one exists)
# Returns empty string if no agent can be determined.
# Reject agent names that are not a safe path component (#466). The
# resolved name is interpolated into a cache file path that
# auto_source_preflight then SOURCES, so a value like "../../etc/evil" or
# one with shell metacharacters must never reach the path builder. Allow
# only [A-Za-z0-9_-]; anything else is treated as "no agent" (fail-closed:
# auto-source skips and no credentials are loaded). Bash 3.2 portable.
_preflight_agent_name_is_safe() {
  case "$1" in
    "" | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

preflight_agent() {
  if [[ -n "${MERGEPATH_AGENT:-}" ]]; then
    if _preflight_agent_name_is_safe "$MERGEPATH_AGENT"; then
      printf '%s' "$MERGEPATH_AGENT"
    else
      echo "preflight: ignoring unsafe MERGEPATH_AGENT (must match [A-Za-z0-9_-]+)" >&2
    fi
    return 0
  fi
  if [[ -n "${OP_PREFLIGHT_AGENT:-}" ]]; then
    if _preflight_agent_name_is_safe "$OP_PREFLIGHT_AGENT"; then
      printf '%s' "$OP_PREFLIGHT_AGENT"
    else
      echo "preflight: ignoring unsafe OP_PREFLIGHT_AGENT (must match [A-Za-z0-9_-]+)" >&2
    fi
    return 0
  fi
  local cache_dir
  cache_dir="$(preflight_cache_dir)"
  [[ -d "$cache_dir" ]] || return 0
  local files=( "$cache_dir"/op-preflight-*.env )
  if [[ ${#files[@]} -eq 1 && -f "${files[0]}" ]]; then
    local base="${files[0]##*/}"
    base="${base#op-preflight-}"
    base="${base%.env}"
    # Defense in depth: a glob match cannot contain '/', but still refuse
    # to emit a name that is not a safe path component.
    if _preflight_agent_name_is_safe "$base"; then
      printf '%s' "$base"
    fi
    return 0
  fi
  return 0
}

# Internal: returns 0 if the session file is fresh per its embedded
# OP_PREFLIGHT_CREATED_AT_EPOCH (NOT mtime) and the active TTL.
preflight_session_is_fresh() {
  local session_file="$1"
  [[ -f "$session_file" ]] || return 1
  local created_at now age ttl
  created_at=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$session_file" 2>/dev/null \
    | cut -d= -f2- | tr -d "'\"" || true)
  [[ -z "$created_at" ]] && return 1
  [[ "$created_at" =~ ^[0-9]+$ ]] || return 1
  ttl="${OP_PREFLIGHT_TTL_SECONDS:-14400}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=14400
  now=$(date +%s)
  age=$((now - created_at))
  [[ "$age" -lt "$ttl" ]]
}

# Auto-source the op-preflight cache into the current shell IF:
#   * GH_TOKEN is not already set (preserve caller-provided creds), AND
#   * the cache file for the resolved agent exists and is fresh.
#
# Silent on the no-op paths (GH_TOKEN already set, no cache found,
# stale cache). Emits a single-line diagnostic to stderr ONLY when it
# actually sources, so noisy helpers don't accumulate prefix lines on
# every tool call. Returns 0 in all cases — callers decide what to do
# when GH_TOKEN is still unset after this returns.
auto_source_preflight() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    return 0
  fi
  local agent cache_dir session_file
  agent="$(preflight_agent)"
  if [[ -z "$agent" ]]; then
    return 0
  fi
  cache_dir="$(preflight_cache_dir)"
  session_file="$cache_dir/op-preflight-${agent}.env"
  if ! preflight_session_is_fresh "$session_file"; then
    return 0
  fi
  # Scrub ambient GH_TOKEN / GITHUB_TOKEN before sourcing the cache (#573).
  # GH_TOKEN is guaranteed unset here by the early return above, but a stray
  # ambient GITHUB_TOKEN would otherwise survive and — because gh prefers
  # GITHUB_TOKEN over the freshly-sourced GH_TOKEN — shadow the cached PAT
  # the cache is about to export. Unset both so the resolved environment
  # ends with ONLY the cache's own credentials, never a leaked ambient one.
  #
  # #611 (Codex P2): the scrub must not DESTROY the caller's auth when the
  # cache provides no replacement. A fresh cache from `--mode deploy` (or any
  # cache without a GitHub PAT) exports no GH_TOKEN and no OP_PREFLIGHT_*_PAT,
  # and unconditionally dropping the ambient GITHUB_TOKEN would leave the
  # caller with no GitHub credential at all. Snapshot the ambient value and
  # restore it below iff sourcing produced NO GitHub credential of any kind —
  # the shadowing hazard the scrub exists for only arises when the cache
  # actually supplies one.
  local _ambient_github_token_set=0 _ambient_github_token=""
  if [[ -n "${GITHUB_TOKEN+x}" ]]; then
    _ambient_github_token_set=1
    _ambient_github_token="$GITHUB_TOKEN"
  fi
  unset GH_TOKEN GITHUB_TOKEN
  # Source the cache file. Permissions are 0600 in a 0700 cache dir,
  # owner-only; we trust the file the same way op-preflight.sh itself
  # does on the cache-hit path.
  # shellcheck disable=SC1090
  . "$session_file"
  # #611 r10: do NOT synthesize a GH_TOKEN from the cache reviewer PAT here.
  # The round-9 reviewer-export imposed the reviewer identity on every
  # auto_source caller, but callers that need a specific identity for bare
  # gh — notably scripts/sync-to-downstream.sh, whose sync_read_gh calls
  # `preflight_require_token author` precisely WHEN GH_TOKEN is empty —
  # depend on GH_TOKEN staying unset so they can acquire the RIGHT token.
  # A review-mode cache therefore leaves GH_TOKEN unset (callers pin
  # $OP_PREFLIGHT_{REVIEWER,AUTHOR}_PAT per command, or require_token).
  #
  # Restore the caller's ambient GITHUB_TOKEN whenever the cache did NOT
  # export a GH_TOKEN of its own (#611 r13). This preserves bare-`gh`
  # callers (that rely on ambient GITHUB_TOKEN, not require_token) in
  # token-only environments, and unifies the r7/r9/r10/r11 special cases.
  #
  # It is SAFE against the #573 shadowing concern: gh resolves GH_TOKEN
  # BEFORE GITHUB_TOKEN (verified empirically — with both set, gh reports
  # "using token (GH_TOKEN)"; the manual lists them "in order of
  # precedence"), so a per-command `GH_TOKEN=$OP_PREFLIGHT_*_PAT` pin (and a
  # require_token-set GH_TOKEN) ALWAYS wins over the restored fallback. The
  # earlier #573 auto-source comment had this precedence backwards; the real
  # #573 protection (a cache that computes a PAT from a leaked $GITHUB_TOKEN)
  # lives in load_preflight_env_vars' subshell scrub, which is unchanged.
  # A cache that DOES export its own GH_TOKEN needs no restore (GH_TOKEN is
  # already set and wins). Decided by the CACHE FILE, not post-source env
  # (#611 r7): a stale ambient PAT must not affect the decision.
  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" \
        && "$_ambient_github_token_set" -eq 1 ]] \
     && ! grep -qE '^(export[[:space:]]+)?GH_TOKEN=' "$session_file"; then
    export GITHUB_TOKEN="$_ambient_github_token"
  fi
  if [[ "${OP_PREFLIGHT_QUIET:-0}" != "1" ]]; then
    echo "# auto-source: loaded op-preflight cache for agent=$agent (no biometric)" >&2
  fi
  return 0
}

# Load OP_PREFLIGHT_* env vars from the cache file unconditionally —
# even when GH_TOKEN is already set. auto_source_preflight skips when
# GH_TOKEN is present (to preserve caller-provided creds), but callers
# that build a per-command token pin like
#   GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${GH_TOKEN:-}}" gh api ...
# need OP_PREFLIGHT_REVIEWER_PAT populated from disk even when an ambient
# GH_TOKEN is already exported. GH_TOKEN is restored to its prior value
# after sourcing so the caller's ambient token is not displaced.
# Returns 0 in all cases (callers tolerate a missing cache gracefully).
load_preflight_env_vars() {
  local agent cache_dir session_file _saved_gh_token _r _a
  agent="$(preflight_agent)"
  [[ -z "$agent" ]] && return 0
  cache_dir="$(preflight_cache_dir)"
  session_file="$cache_dir/op-preflight-${agent}.env"
  preflight_session_is_fresh "$session_file" || return 0
  _saved_gh_token="${GH_TOKEN:-}"
  # Source in a subshell and copy back only the two PAT vars. The session file
  # can include deploy credentials (GOOGLE_APPLICATION_CREDENTIALS, CF_API_TOKEN)
  # from a prior --mode deploy run; subshell isolation prevents those from
  # leaking into the caller's process. (#554/#556 CodeRabbit Major)
  #
  # Scrub ambient GH_TOKEN / GITHUB_TOKEN INSIDE each subshell before sourcing
  # (#573): the subshell inherits the caller's environment, so a stray ambient
  # token would otherwise be visible while the cache is sourced and could leak
  # into the resolved PAT (a cache/legacy file that computes a PAT from
  # $GH_TOKEN / $GITHUB_TOKEN would capture the ambient value). Unsetting both
  # first pins the resolved PATs to the cache's OWN credentials. The caller's
  # ambient GH_TOKEN is restored from _saved_gh_token below, so this scoping
  # never disturbs the caller's process.
  # shellcheck disable=SC1090
  _r=$(unset GH_TOKEN GITHUB_TOKEN; . "$session_file" 2>/dev/null && printf '%s' "${OP_PREFLIGHT_REVIEWER_PAT:-}") || true
  # shellcheck disable=SC1090
  _a=$(unset GH_TOKEN GITHUB_TOKEN; . "$session_file" 2>/dev/null && printf '%s' "${OP_PREFLIGHT_AUTHOR_PAT:-}") || true
  [[ -n "${_r:-}" ]] && OP_PREFLIGHT_REVIEWER_PAT="$_r"
  [[ -n "${_a:-}" ]] && OP_PREFLIGHT_AUTHOR_PAT="$_a"
  if [[ -n "$_saved_gh_token" ]]; then
    GH_TOKEN="$_saved_gh_token"
  fi
  return 0
}

# Convenience wrappers: helpers that need a reviewer-scoped token call
# `preflight_require_token reviewer`; helpers that want author scope
# pass `author`. The function auto-sources the cache (if needed) and
# exports GH_TOKEN from the matching OP_PREFLIGHT_*_PAT. Returns 0 if
# GH_TOKEN ends up populated (either pre-existing or just exported by
# auto-source), 1 otherwise. Callers that already validate
# `[ -z "${GH_TOKEN:-}" ] && exit 3` get a no-op when this helper
# succeeded and the same hard-error when it didn't — no regression.
preflight_require_token() {
  local scope="${1:-reviewer}"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    return 0
  fi
  auto_source_preflight
  local var_name
  case "$scope" in
    reviewer) var_name="OP_PREFLIGHT_REVIEWER_PAT" ;;
    author)   var_name="OP_PREFLIGHT_AUTHOR_PAT" ;;
    *)
      echo "ERROR: preflight_require_token: unknown scope '$scope' (expected reviewer|author)" >&2
      return 1
      ;;
  esac
  local val="${!var_name:-}"
  if [[ -n "$val" ]]; then
    export GH_TOKEN="$val"
    return 0
  fi
  return 1
}
