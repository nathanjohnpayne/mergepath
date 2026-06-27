#!/usr/bin/env bash
# scripts/lib/gh-retry-helpers.sh
#
# with_gh_retry — wrap a gh/gh-api call in 3-attempt retry with 30s backoff.
# Distinguishes transient (HTTP 5xx, rate-limit, "Resource not accessible by
# integration") from permanent (HTTP 4xx other than 429/403, malformed JSON)
# failures. Only retries the transient class.
#
# Usage:
#   with_gh_retry gh pr view 123 --json statusCheckRollup
#   with_gh_retry gh api ...
#
# Exit codes:
#   0  — call succeeded on attempt N
#   non-zero — call failed after 3 attempts or hit a permanent error
#
# Env tuning:
#   GH_RETRY_ATTEMPTS (default 3)
#   GH_RETRY_BACKOFF_SECONDS (default 30)

set -euo pipefail

with_gh_retry() {
  local attempts=${GH_RETRY_ATTEMPTS:-3}
  local backoff=${GH_RETRY_BACKOFF_SECONDS:-30}
  # Validate env knobs (CR Major #328 round 2, Minor round 3). Non-
  # numeric or non-positive values previously could skip the loop
  # entirely (returning success with empty output) or break `sleep`
  # under `set -e`. Fall back to the defaults with a stderr warning
  # rather than silently no-op'ing.
  #
  # Two-phase validation: first reject non-numeric strings via case
  # pattern, then reject non-positive integers via arithmetic. The
  # arithmetic phase closes the leading-zero hole CR caught on round
  # 2 — `case "00" in 0)` doesn't match (case patterns are literal,
  # not numeric) but bash arithmetic treats "00" as 0, so the prior
  # validation passed but the while loop never entered.
  case "$attempts" in
    ''|*[!0-9]*) printf '[gh-retry] WARN: GH_RETRY_ATTEMPTS=%q non-numeric; using default 3\n' "$attempts" >&2; attempts=3 ;;
  esac
  if [ "$attempts" -le 0 ] 2>/dev/null; then
    printf '[gh-retry] WARN: GH_RETRY_ATTEMPTS=%q non-positive; using default 3\n' "$attempts" >&2
    attempts=3
  fi
  case "$backoff" in
    ''|*[!0-9]*) printf '[gh-retry] WARN: GH_RETRY_BACKOFF_SECONDS=%q non-numeric; using default 30\n' "$backoff" >&2; backoff=30 ;;
  esac
  # Backoff can legitimately be 0 (no sleep between retries — useful
  # for tests), so the arithmetic-positivity check applies only to
  # `attempts`. A negative `backoff` would only occur if a user
  # passed e.g. `-1`, which fails the case pattern above and is
  # already caught.
  local attempt=1
  local rc=0
  local out=""
  local errtext=""
  local output=""

  # Separate stderr capture (#536): gh writes deprecation notices and
  # other warnings to stderr even on a successful call. The prior
  # implementation captured `2>&1` and re-emitted the combined stream on
  # success, so that stderr chatter contaminated JSON / exact-text
  # consumers (e.g. codex-review-check.sh parsing statusCheckRollup). We
  # now route stderr to a tmpfile, emit ONLY stdout on success, and fold
  # the two streams together (`output`) solely for failure
  # classification + logging. A tmpfile (not process substitution) keeps
  # this bash 3.2 safe and avoids the subshell-scoping traps of `<(...)`.
  local err
  err=$(mktemp "${TMPDIR:-/tmp}/gh-retry-err.XXXXXX") || {
    printf '[gh-retry] WARN: mktemp failed; falling back to combined stream\n' >&2
    err=""
  }
  # Clean up the tmpfile on any return path (success, permanent-fail,
  # exhausted retries) via a RETURN trap that CLEARS ITSELF (trap -
  # RETURN) as it fires. Self-clearing is required: a bare RETURN trap
  # lingers after with_gh_retry returns and re-fires on the caller's own
  # function / source return, where the local `err` is out of scope —
  # under set -u that aborts the caller with `err: unbound variable`
  # (#545 P2). No caller in this repo installs its own RETURN trap, so
  # clearing (rather than save/restore) clobbers nothing.
  if [ -n "$err" ]; then
    trap 'rm -f "$err"; trap - RETURN' RETURN
  fi

  while [ "$attempt" -le "$attempts" ]; do
    # Capture stdout and the exit code; stderr goes to the tmpfile.
    # Using `if out=...; then` would discard `$?` after the failed
    # `if` test (bash resets $? to 0 in that position), so we
    # invoke + check separately. `|| rc=$?` keeps `set -e` happy
    # because the `||` short-circuit consumes the non-zero exit.
    rc=0
    if [ -n "$err" ]; then
      out=$("$@" 2>"$err") || rc=$?
      errtext=$(cat "$err" 2>/dev/null || true)
    else
      # Fallback path (mktemp unavailable): preserve prior combined
      # behavior rather than dropping stderr entirely.
      out=$("$@" 2>&1) || rc=$?
      errtext=""
    fi
    if [ "$rc" -eq 0 ]; then
      # Success: emit ONLY stdout. Any stderr (warnings/deprecations)
      # is intentionally dropped so downstream parsers see clean output.
      printf '%s' "$out"
      return 0
    fi

    # Combined stream for classification + logging on the FAILURE path
    # only. Joining with a newline keeps grep line-anchored matches
    # working across the stdout/stderr boundary.
    if [ -n "$errtext" ]; then
      output="$out
$errtext"
    else
      output="$out"
    fi

    # Classify the failure. Permanent failures break out immediately.
    #
    # Retry only:
    #   - HTTP 5xx (server-side, transient)
    #   - HTTP 429 (rate-limit, always)
    #   - HTTP 403 with "rate limit" in the body (GitHub rate-limit
    #     can surface as 403 in some flows)
    # Fail-fast on:
    #   - HTTP 4xx other than 429 or rate-limited 403 (auth, perms,
    #     validation — retrying is futile and costs sweep budget)
    #   - "Resource not accessible by integration" (token permission
    #     issue, fixed by adding the perm to the workflow — codex P2
    #     #328 round 3 caught the prior pattern wasting 2×30s sleeps
    #     on this surface, missing the auto-clear window)
    is_permanent=false
    if printf '%s' "$output" | grep -q 'Resource not accessible by integration'; then
      is_permanent=true
    elif printf '%s' "$output" | grep -qE 'HTTP 4[0-9]{2}'; then
      if printf '%s' "$output" | grep -qE 'HTTP 429'; then
        : # transient rate-limit
      elif printf '%s' "$output" | grep -qE 'HTTP 403' \
           && printf '%s' "$output" | grep -qiE 'rate.?limit'; then
        : # transient rate-limit surfaced as 403
      else
        is_permanent=true
      fi
    fi
    if $is_permanent; then
      printf '%s' "$output" >&2
      return "$rc"
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      printf '[gh-retry] attempt %d/%d failed (rc=%d), sleeping %ds before retry. tail: %s\n' \
        "$attempt" "$attempts" "$rc" "$backoff" "$(printf '%s' "$output" | tail -1)" >&2
      sleep "$backoff"
    fi
    attempt=$((attempt + 1))
  done

  printf '%s' "$output" >&2
  return "$rc"
}

export -f with_gh_retry
