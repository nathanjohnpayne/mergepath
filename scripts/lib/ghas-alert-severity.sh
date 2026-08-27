# scripts/lib/ghas-alert-severity.sh
#
# `ghas_alert_severity <repo> <alert_number>` — resolve one GitHub Advanced
# Security code-scanning alert's severity BY NUMBER (nathanjohnpayne/
# mergepath#1113), not via a ref-scoped list.
#
# ─────────────────────────────────────────────────────────────────────
# Why by number, not by list
# ─────────────────────────────────────────────────────────────────────
#
# #1101 originally resolved severity by fetching
# `code-scanning/alerts?ref=refs/pull/{pr}/head` — a list scoped to the
# CURRENT head, because the unscoped list silently omits an alert that
# exists only on a PR branch (confirmed live on
# nathanjohnpayne/nathanpaynedotcom#809). That fix traded one gap for
# another: a comment raised on an EARLIER head, whose alert no longer
# shows up when the CURRENT head is queried (the PR moved on, or the
# alert was fixed by a later push before anyone replied), can't resolve
# its severity either — #1113 item 3.
#
# `GET /repos/{owner}/{repo}/code-scanning/alerts/{alert_number}` is keyed
# on the alert's permanent identity, not on any ref at all. Confirmed live
# (same nathanpaynedotcom#809 fixtures): alert #26 — the PR-branch-only,
# `high`-severity alert the list form needed `?ref=` to see — resolves
# correctly through the single-alert form with NO ref parameter at all,
# for any head that ever raised it. One mechanism now serves the live
# accounting path, archive-time resolution for an edited/deleted comment,
# and the surface fingerprint, all keyed on nothing but the alert number
# parsed from the comment body.
#
# ─────────────────────────────────────────────────────────────────────
# Contract
# ─────────────────────────────────────────────────────────────────────
#
#   rc 0 — the alert WAS read. Its `rule.security_severity_level` (or
#          empty, e.g. a non-security CodeQL quality rule with no
#          assigned severity) is on stdout.
#   rc 3 — the read failed (network, auth, 404, rate limit — gh_api_scalar
#          does not distinguish these), OR the cache was never
#          initialized. Nothing is written to stdout; the diagnostic is
#          on stderr. Callers in this repo treat a failed READ as an
#          infrastructure failure for LIVE evaluation (loud, not silently
#          downgraded — a systemic security-events permission gap must
#          surface, not disappear as a confident p2) and as a best-effort
#          warning for ARCHIVE-time resolution, where failing the whole
#          archival over one transient read would risk losing the only
#          surviving copy of a disappearing finding. Each caller decides;
#          this function only reports.
#
# ─────────────────────────────────────────────────────────────────────
# Memoization is FILE-backed, not variable-backed
# ─────────────────────────────────────────────────────────────────────
#
# Every caller in this repo invokes this function (or something that
# calls it, like ghas_finding_tier) inside a command substitution —
# `severity=$(ghas_alert_severity ...)` — because that is also how it
# returns its VALUE. Command substitution forks a subshell, so a plain
# shell-variable cache (`GHAS_SEVERITY_CACHE='{}'; GHAS_SEVERITY_CACHE=$(jq
# ...)`) would have every write silently discarded the instant that
# subshell exits — the next call, even for the SAME alert number, would
# see the cache exactly as it was before the first fetch. A file survives
# the subshell boundary because it is process-wide OS state, not shell
# state, so the cache is a path (in `GHAS_SEVERITY_CACHE`) to a JSON
# object on disk, not the object itself.
#
# Call `ghas_severity_cache_init` once, before the first call, to create
# it; call `ghas_severity_cache_cleanup` (or just let the caller's own
# `mktemp`-cleanup trap remove it) when done.
#
# Sourcing contract: NO top-level side effects, only function defs. No
# shell options are set. Requires scripts/lib/gh-api-scalar.sh already
# sourced by the caller (gh_api_scalar is not re-sourced here to avoid
# each consumer needing to know this file's own dependency graph twice).
#
#   source scripts/lib/gh-api-scalar.sh
#   source scripts/lib/ghas-alert-severity.sh
#   ghas_severity_cache_init || exit 2
#   trap 'ghas_severity_cache_cleanup' EXIT
#   ghas_alert_severity <owner/repo> <alert_number>

ghas_severity_cache_init() {
  GHAS_SEVERITY_CACHE=$(mktemp "${TMPDIR:-/tmp}/ghas-severity-cache.XXXXXX") || {
    printf '[ghas-alert-severity] ERROR: could not create severity cache file\n' >&2
    return 3
  }
  printf '{}' >"$GHAS_SEVERITY_CACHE" || {
    printf '[ghas-alert-severity] ERROR: could not initialize severity cache file\n' >&2
    return 3
  }
}

ghas_severity_cache_cleanup() {
  [ -n "${GHAS_SEVERITY_CACHE:-}" ] && rm -f "$GHAS_SEVERITY_CACHE"
}

ghas_alert_severity() {
  local repo="$1" number="$2" cache_key value rc

  if [ -z "$repo" ] || [ -z "$number" ]; then
    printf '[ghas-alert-severity] ERROR: usage: ghas_alert_severity <owner/repo> <alert_number>\n' >&2
    return 3
  fi
  if ! command -v gh_api_scalar >/dev/null 2>&1; then
    printf '[ghas-alert-severity] ERROR: gh_api_scalar is not defined — source scripts/lib/gh-api-scalar.sh first\n' >&2
    return 3
  fi
  if [ -z "${GHAS_SEVERITY_CACHE:-}" ] || [ ! -f "$GHAS_SEVERITY_CACHE" ]; then
    printf '[ghas-alert-severity] ERROR: GHAS_SEVERITY_CACHE is not initialized — call ghas_severity_cache_init first\n' >&2
    return 3
  fi

  cache_key="${repo}#${number}"
  if jq -e --arg k "$cache_key" 'has($k)' "$GHAS_SEVERITY_CACHE" >/dev/null 2>&1; then
    jq -r --arg k "$cache_key" '.[$k] // empty' "$GHAS_SEVERITY_CACHE"
    return 0
  fi

  rc=0
  value=$(gh_api_scalar --shape any "code-scanning alert $repo#$number severity" \
    "repos/$repo/code-scanning/alerts/$number" --jq '.rule.security_severity_level // empty') || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 3
  fi

  # Read-modify-write via a sibling temp file + rename: safe for this
  # library's actual (sequential) callers, and an atomic rename means a
  # reader never observes a half-written cache file even if it did race.
  jq -c --arg k "$cache_key" --arg v "$value" '.[$k] = $v' "$GHAS_SEVERITY_CACHE" \
    >"$GHAS_SEVERITY_CACHE.tmp" && mv "$GHAS_SEVERITY_CACHE.tmp" "$GHAS_SEVERITY_CACHE"
  printf '%s' "$value"
}
