#!/usr/bin/env bash
# tests/test_codex_review_request_verdict.sh
#
# Regression coverage for the HEAD-anchored Codex issue-comment verdict
# signal in scripts/codex-review-request.sh (#609).
#
# codex-review-check.sh (the merge gate) has recognized a HEAD-anchored
# "Codex Review: Didn't find any major issues" + "Reviewed commit: <sha>"
# issue comment as a clearance signal since #600/#567. Until #609 this
# poller did not — it scanned only review objects and reactions — so a
# verdict-only Codex response ran the poll to timeout (exit 4,
# FALLBACK_REQUIRED) instead of terminating on it. #609 teaches
# scan_codex_state / has_signal / has_cleared_signal / has_post_trigger_signal
# to recognize the same signal, fail-closed, mirroring the merge gate's
# #608 P1 latest-signal-wins fix.
#
# This test pins (1) the structural presence of the verdict signal in the
# real script, and (2) the verdict-matching / signal-decision jq logic
# inline — the same inline-literal pattern
# test_codex_review_check_verdict.sh uses. KEEP THE INLINE FILTERS BELOW IN
# SYNC with scan_codex_state / has_signal / has_cleared_signal /
# has_post_trigger_signal in scripts/codex-review-request.sh.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true
SCRIPT="$ROOT/scripts/codex-review-request.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── 1. Structural: scan_codex_state fetches issue comments and computes a
#      HEAD-anchored verdict signal, gated on the same anchor/affirmative
#      logic as the merge gate, referenced to #609.
if grep -q 'issue_comments=\$(fetch_api_array "repos/\$REPO/issues/\$PR_NUMBER/comments"' "$SCRIPT" \
   && grep -q "reviewed commit\[\^0-9a-f\]" "$SCRIPT" \
   && grep -qi "didn.?t find any major issues" "$SCRIPT" \
   && grep -q "startswith(\$s)" "$SCRIPT" \
   && grep -q "max_by(.created_at) // null" "$SCRIPT" \
   && grep -q "#609" "$SCRIPT"; then
  pass "scan_codex_state computes the HEAD-anchored verdict signal (#609)"
else
  fail "scan_codex_state is missing the verdict signal (issue-comments fetch / affirmative regex / reviewed-commit scan / prefix anchor / #609)"
fi

# ── 2. Structural: has_signal treats a verdict of EITHER disposition as a
#      terminal response (the poll must stop, not time out).
if grep -q '.review != null or .reaction != null or .verdict != null' "$SCRIPT"; then
  pass "has_signal treats any HEAD-anchored verdict as a response signal"
else
  fail "has_signal does not include the verdict in its ANY-signal check"
fi

# ── 3. Structural: has_cleared_signal folds the verdict into a three-way
#      latest-signal-wins decision (reaction / review / verdict), not a
#      two-way check with the verdict bolted on as a fallback.
if grep -q '\["reaction", reaction_time\], \["review", review_time\], \["verdict", verdict_time\]' "$SCRIPT" \
   && grep -q 'elif \$latest.kind == "verdict" then' "$SCRIPT" \
   && grep -q '.verdict.affirmative == true and review_clean' "$SCRIPT"; then
  pass "has_cleared_signal folds the verdict into three-way latest-signal-wins"
else
  fail "has_cleared_signal is missing the three-way latest-signal-wins verdict path"
fi

# ── 4. Structural: has_post_trigger_signal also fires on a verdict at/after
#      the trigger threshold, so a verdict-only response ends the poll.
if grep -q '.verdict != null and .verdict.created_at >= \$after' "$SCRIPT"; then
  pass "has_post_trigger_signal fires on a post-trigger verdict"
else
  fail "has_post_trigger_signal does not check the verdict against the trigger threshold"
fi

# ── 5. Inline logic: the verdict-matching jq filter. KEEP IN SYNC with the
#      `verdict=$(echo "$issue_comments" | jq -c ...)` filter in
#      scan_codex_state. Selects the LATEST HEAD-anchored verdict comment
#      (any disposition) and reports whether it is affirmative.
BOT="chatgpt-codex-connector[bot]"
HEAD="d05ff4d0e1a2b3c4d5e6f70819a2b3c4d5e6f708"
VERDICT_FILTER='
    ($sha | ascii_downcase) as $head
    | [ .[]
        | select(.user.login == $bot)
        | . as $c
        | ( [ $c.body
              | ascii_downcase
              | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
              | .[0]
            ] ) as $shas
        | select( ($shas | length) > 0
                  and ($shas | any(. as $s | $head | startswith($s))) )
        | { created_at: .created_at,
            affirmative: (.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")) }
      ]
    | max_by(.created_at) // null'

mk() { jq -n --arg login "$1" --arg body "$2" --arg t "$3" \
  '[{user:{login:$login},body:$body,created_at:$t}]'; }
run_verdict() { printf '%s' "$1" | jq -c --arg bot "$BOT" --arg sha "$HEAD" "$VERDICT_FILTER"; }

check_verdict() { # desc expected_json fixture
  local desc="$1" expected="$2" fixture="$3" got
  got="$(run_verdict "$fixture")"
  if [ "$got" = "$expected" ]; then
    pass "verdict filter: $desc"
  else
    fail "verdict filter: $desc — expected '$expected', got '$got'"
  fi
}

# 5a. affirmative + prefix sha → verdict present, affirmative:true.
check_verdict "affirmative + prefix sha → clears" \
  '{"created_at":"2026-07-03T10:00:00Z","affirmative":true}' \
  "$(mk "$BOT" "Codex Review: Didn't find any major issues. Swish!
Reviewed commit: d05ff4d0" "2026-07-03T10:00:00Z")"

# 5b (acceptance criterion): stale-HEAD verdict (Reviewed commit does not
# prefix HEAD) is ignored entirely — null, not just non-affirmative.
check_verdict "stale-HEAD verdict → ignored (null)" \
  "null" \
  "$(mk "$BOT" "Codex Review: Didn't find any major issues.
Reviewed commit: aaaa1111bbbb" "2026-07-03T10:00:00Z")"

# 5c. findings-bearing (non-affirmative) verdict on HEAD → present but
# affirmative:false.
check_verdict "non-affirmative verdict on HEAD → present, affirmative:false" \
  '{"created_at":"2026-07-03T10:00:00Z","affirmative":false}' \
  "$(mk "$BOT" "Codex Review: Found 2 issues to address.
Reviewed commit: d05ff4d0" "2026-07-03T10:00:00Z")"

# 5d (acceptance criterion): a NEWER non-affirmative verdict supersedes an
# OLDER affirmative one on the same HEAD — latest-verdict-first, not
# affirmative-first (same #608 P1 shape as the merge gate).
older_affirmative="$(mk "$BOT" "Codex Review: Didn't find any major issues.
Reviewed commit: d05ff4d0" "2026-07-03T10:00:00Z")"
newer_negative="$(mk "$BOT" "Codex Review: Found a regression.
Reviewed commit: d05ff4d0e1" "2026-07-03T12:00:00Z")"
check_verdict "newer non-affirmative verdict supersedes older affirmative one" \
  '{"created_at":"2026-07-03T12:00:00Z","affirmative":false}' \
  "$(jq -s 'add' <(printf '%s' "$older_affirmative") <(printf '%s' "$newer_negative"))"

# ── 6. Inline logic: has_signal. KEEP IN SYNC with has_signal in the script.
HAS_SIGNAL_FILTER='.review != null or .reaction != null or .verdict != null'
hs() { # desc expected scan_json
  local desc="$1" expected="$2" got
  got=$(printf '%s' "$3" | jq -r "$HAS_SIGNAL_FILTER")
  if [ "$got" = "$expected" ]; then pass "has_signal: $desc"; else fail "has_signal: $desc — expected $expected got $got"; fi
}
hs "verdict-only (non-affirmative) → true (a real response, not a timeout)" \
  "true" '{"review":null,"reaction":null,"verdict":{"created_at":"2026-07-03T10:00:00Z","affirmative":false}}'
hs "no signals → false" \
  "false" '{"review":null,"reaction":null,"verdict":null}'

# ── 7. Inline logic: has_cleared_signal's three-way latest-signal-wins.
#      KEEP IN SYNC with has_cleared_signal in the script.
CLEARED_FILTER='
    def review_time: if .review == null then "" else .review.submitted_at end;
    def reaction_time: if .reaction == null then "" else .reaction.created_at end;
    def verdict_time: if .verdict == null then "" else .verdict.created_at end;
    def review_clean: ([.findings[] | select(.priority == "P0" or .blocking == true)] | length) == 0;

    ( reduce ( [["reaction", reaction_time], ["review", review_time], ["verdict", verdict_time]] | .[] ) as $sig
        ({kind: "", time: ""};
         if ($sig[1] != "" and ($sig[1] >= .time)) then {kind: $sig[0], time: $sig[1]} else . end)
    ) as $latest
    | if $latest.kind == "reaction" then "true"
      elif $latest.kind == "review" then (review_clean | tostring)
      elif $latest.kind == "verdict" then
        ((.verdict.affirmative == true and review_clean) | tostring)
      else "false"
      end'

build_scan() { # reaction_time review_time review_findings_json verdict_time verdict_affirmative
  jq -n \
    --arg rt "$1" --arg vt "$2" --argjson findings "$3" --arg vdt "$4" --arg aff "$5" '
    {
      reaction: (if $rt == "" then null else {created_at: $rt} end),
      review: (if $vt == "" then null else {submitted_at: $vt} end),
      findings: $findings,
      verdict: (if $vdt == "" then null else {created_at: $vdt, affirmative: ($aff == "true")} end)
    }'
}
cleared() { echo "$1" | jq -r "$CLEARED_FILTER"; }
cc() { # desc expected reaction_time review_time findings_json verdict_time verdict_affirmative
  local desc="$1" exp="$2" got
  got=$(cleared "$(build_scan "$3" "$4" "$5" "$6" "$7")")
  if [ "$got" = "$exp" ]; then pass "has_cleared_signal: $desc"; else fail "has_cleared_signal: $desc — expected $exp got $got"; fi
}

# 7a (acceptance criterion): verdict-only clearance — the ONLY Codex signal
# is a HEAD-anchored affirmative verdict comment, no review, no reaction.
cc "verdict-only affirmative + 0 findings → cleared" \
  "true" "" "" "[]" "2026-07-03T10:00:00Z" "true"

# 7b: verdict-only affirmative but with unaddressed findings on HEAD → NOT
# cleared (the merge gate's zero-unaddressed-findings cross-check).
cc "verdict-only affirmative + blocking finding on HEAD → NOT cleared" \
  "false" "" "" '[{"priority":"P1","blocking":true}]' "2026-07-03T10:00:00Z" "true"

# 7c (acceptance criterion): a NEWER non-affirmative verdict supersedes an
# OLDER clean reaction/review — fails closed, same #608 P1 shape.
cc "older 👍 + NEWER non-affirmative verdict → NOT cleared (#608 shape)" \
  "false" "2026-07-03T09:00:00Z" "" "[]" "2026-07-03T12:00:00Z" "false"
cc "older clean review + NEWER non-affirmative verdict → NOT cleared" \
  "false" "" "2026-07-03T09:00:00Z" "[]" "2026-07-03T12:00:00Z" "false"

# 7d: an older non-affirmative verdict does not block a NEWER clean signal.
cc "older non-affirmative verdict + NEWER 👍 → cleared" \
  "true" "2026-07-03T12:00:00Z" "" "[]" "2026-07-03T09:00:00Z" "false"

# 7e: pre-#609 paths still behave identically (no verdict present at all).
cc "thumbs-only, no verdict → cleared" \
  "true" "2026-07-03T10:00:00Z" "" "[]" "" ""
cc "review-only clean, no verdict → cleared" \
  "true" "" "2026-07-03T10:00:00Z" "[]" "" ""
cc "no signals at all → NOT cleared" \
  "false" "" "" "[]" "" ""

# ── 8. Inline logic: has_post_trigger_signal. KEEP IN SYNC with the script.
POST_TRIGGER_FILTER='
    ((.review != null and .review.submitted_at >= $after)
     or (.reaction != null and .reaction.created_at >= $after)
     or (.verdict != null and .verdict.created_at >= $after))'
pts() { # desc expected scan_json after
  local desc="$1" expected="$2" got
  got=$(printf '%s' "$3" | jq -r --arg after "$4" "$POST_TRIGGER_FILTER")
  if [ "$got" = "$expected" ]; then pass "has_post_trigger_signal: $desc"; else fail "has_post_trigger_signal: $desc — expected $expected got $got"; fi
}
pts "post-trigger verdict (at threshold, >=) → true" \
  "true" '{"review":null,"reaction":null,"verdict":{"created_at":"2026-07-03T10:00:00Z"}}' "2026-07-03T10:00:00Z"
pts "pre-trigger (stale) verdict → false" \
  "false" '{"review":null,"reaction":null,"verdict":{"created_at":"2026-07-03T09:00:00Z"}}' "2026-07-03T10:00:00Z"

# ── 9. Behavioral: a failed fetch_api_array read inside scan_codex_state
#      reaches its callers as a non-zero status FROM scan_codex_state
#      itself, not merely from the trailing `jq -n --argjson` emitter
#      crashing on empty input (#966). Extract the LIVE function body
#      (not a hand-copied stand-in) so this asserts the actual emission
#      path, stub fetch_api_array to fail on the very first read, and
#      confirm scan_codex_state's own return status is non-zero BEFORE
#      it would ever reach the emitter.
SCAN_FN="$(sed -n '/^scan_codex_state() {/,/^}/p' "$SCRIPT")"
if [ -z "$SCAN_FN" ]; then
  fail "could not extract scan_codex_state from $SCRIPT"
else
  scan_rc_output="$(bash -c '
    set -eo pipefail
    log() { :; }
    fetch_api_array() { return 3; }   # every endpoint fails
    REPO=owner/repo PR_NUMBER=1 HEAD_SHA=deadbeef BOT_LOGIN=chatgpt-codex-connector TRIGGER_SIGNAL_THRESHOLD=""
    eval "$1"
    if scan_codex_state >/dev/null 2>&1; then
      echo "rc=0"
    else
      echo "rc=$?"
    fi
  ' _ "$SCAN_FN" 2>&1)"
  if [ "$scan_rc_output" = "rc=3" ]; then
    pass "scan_codex_state propagates a failed read as its own non-zero status (#966)"
  else
    fail "scan_codex_state did not propagate the failed read; got: $scan_rc_output"
  fi
fi

# ── 10. Behavioral: fetch_api_array must not let `gh api`'s STDERR reach
#       the `jq -s` slurp. `gh api` prints diagnostics on calls that
#       succeed (deprecation notices, retry chatter), and the old
#       `2>&1` capture folded that prose into the JSON handed to jq —
#       turning a healthy fetch into a spurious "failed to flatten"
#       error, the false-failure mirror of #966's swallowed failure.
#
#       Since #1008 the algorithm lives in scripts/lib/gh-api-array.sh and
#       this script keeps only the `log` + `return 3` failure action, so the
#       driver below SOURCES the real lib alongside the extracted wrapper.
#       That is deliberate: these cases assert the COMPOSITION a caller
#       actually runs (wrapper over shared reader), which is the thing the
#       eight hand-written copies could never be tested as.
ARRAY_LIB="$ROOT/scripts/lib/gh-api-array.sh"
[ -r "$ARRAY_LIB" ] || fail "missing $ARRAY_LIB (#1008)"
FETCH_FN="$(sed -n '/^fetch_api_array() {/,/^}/p' "$SCRIPT")"
if [ -z "$FETCH_FN" ]; then
  fail "could not extract fetch_api_array from $SCRIPT"
elif [ ! -r "$ARRAY_LIB" ]; then
  : # already reported above
else
  fetch_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-fetch-stderr.XXXXXX")"
  cat >"$fetch_stub_dir/gh" <<'STUB'
#!/bin/sh
# Succeeds (exit 0) while emitting benign chatter on stderr, exactly as
# `gh api` does for deprecation/retry notices.
printf '%s\n' 'notice: benign stderr chatter from gh' >&2
printf '%s\n' '[{"id":1},{"id":2}]'
STUB
  chmod +x "$fetch_stub_dir/gh"

  fetch_ok_output="$(PATH="$fetch_stub_dir:$PATH" bash -c '
    set -eo pipefail
    log() { :; }
    . "$2"
    eval "$1"
    if out=$(fetch_api_array "repos/o/r/x" "widgets"); then
      printf "rc=0 ids=%s\n" "$(printf "%s" "$out" | jq -c "[.[].id]")"
    else
      printf "rc=%s\n" "$?"
    fi
  ' _ "$FETCH_FN" "$ARRAY_LIB" 2>/dev/null)"

  if [ "$fetch_ok_output" = "rc=0 ids=[1,2]" ]; then
    pass "fetch_api_array: benign gh stderr does not corrupt a successful fetch"
  else
    fail "fetch_api_array mishandled stderr on a successful fetch; got: $fetch_ok_output"
  fi

  # #1008: `--paginate` emits one JSON document per page, and the flatten is
  # what turns them into ONE array. A reader that kept only the first page
  # would under-report every surface it scans, which on this poller is a
  # signal it never sees.
  cat >"$fetch_stub_dir/gh" <<'STUB'
#!/bin/sh
printf '%s\n' '[{"id":1}]'
printf '%s\n' '[{"id":2},{"id":3}]'
STUB
  chmod +x "$fetch_stub_dir/gh"

  fetch_pages_output="$(PATH="$fetch_stub_dir:$PATH" bash -c '
    set -eo pipefail
    log() { :; }
    . "$2"
    eval "$1"
    out=$(fetch_api_array "repos/o/r/x" "widgets") \
      && printf "ids=%s\n" "$(printf "%s" "$out" | jq -c "[.[].id]")"
  ' _ "$FETCH_FN" "$ARRAY_LIB" 2>/dev/null)"

  if [ "$fetch_pages_output" = "ids=[1,2,3]" ]; then
    pass "fetch_api_array: a multi-page --paginate stream is concatenated into one array (#1008)"
  else
    fail "fetch_api_array lost or mis-joined pagination pages; got: $fetch_pages_output"
  fi

  # The failure path must still return 3 AND surface the stderr text in
  # the log line, so separating the streams does not cost diagnostics.
  #
  # #1008 adds the other half of the #831 contract to the same case: a failed
  # read writes NOTHING to stdout. That is what keeps a residual
  # `[ -z "$x" ]` guard honest — an outage must leave the variable empty
  # rather than filling it with gh's HTTP error body.
  cat >"$fetch_stub_dir/gh" <<'STUB'
#!/bin/sh
# gh writes the HTTP error BODY to stdout and the one-line diagnostic to
# stderr — measured in scripts/lib/gh-api-scalar.sh's header.
printf '%s\n' '{"message":"Bad Gateway","status":"502"}'
printf '%s\n' 'gh: HTTP 502 upstream exploded' >&2
exit 1
STUB
  chmod +x "$fetch_stub_dir/gh"

  fetch_err_output="$(PATH="$fetch_stub_dir:$PATH" bash -c '
    set -eo pipefail
    log() { printf "LOG:%s\n" "$*"; }
    . "$2"
    eval "$1"
    fetch_api_array "repos/o/r/x" "widgets" || printf "rc=%s\n" "$?"
  ' _ "$FETCH_FN" "$ARRAY_LIB" 2>/dev/null)"

  if printf '%s' "$fetch_err_output" | grep -q 'HTTP 502 upstream exploded' \
    && printf '%s' "$fetch_err_output" | grep -q 'rc=3'; then
    pass "fetch_api_array: a failed fetch still returns 3 and logs gh's stderr"
  else
    fail "fetch_api_array lost the failure status or the stderr diagnostic; got: $fetch_err_output"
  fi

  # Same stub, second driver: this one routes `log` to stderr (where the real
  # one writes) so the ONLY thing that can reach stdout is the reader's own
  # output. gh wrote its HTTP error body to stdout above; the value a caller
  # captures must not contain it.
  fetch_err_stdout="$(PATH="$fetch_stub_dir:$PATH" bash -c '
    set -eo pipefail
    log() { printf "LOG:%s\n" "$*" >&2; }
    . "$2"
    eval "$1"
    out=$(fetch_api_array "repos/o/r/x" "widgets") || true
    printf "stdout=[%s]\n" "$out"
  ' _ "$FETCH_FN" "$ARRAY_LIB" 2>/dev/null)"

  if [ "$fetch_err_stdout" = "stdout=[]" ]; then
    pass "fetch_api_array: a failed fetch writes NOTHING to stdout, so emptiness stays honest (#1008)"
  else
    fail "fetch_api_array leaked the HTTP error body to stdout; got: $fetch_err_stdout"
  fi

  # #1008: the lib reports WHICH step failed. coderabbit-wait.sh's
  # best-effort variant keeps two distinct messages, one per step, and
  # GH_API_ARRAY_ERROR_KIND is the only thing that can still tell them apart
  # now that the algorithm is shared. A kind that collapsed to a single value
  # would silently relabel every flatten failure as a fetch failure.
  cat >"$fetch_stub_dir/gh" <<'STUB'
#!/bin/sh
# A 200 whose body is not JSON at all: the fetch SUCCEEDS, the flatten fails.
printf '%s\n' 'this is not json'
STUB
  chmod +x "$fetch_stub_dir/gh"

  kind_output="$(PATH="$fetch_stub_dir:$PATH" bash -c '
    set -eo pipefail
    . "$1"
    gh_api_array "repos/o/r/x" "widgets" >/dev/null || true
    printf "kind=%s msg=%s\n" "$GH_API_ARRAY_ERROR_KIND" "$GH_API_ARRAY_ERROR"
  ' _ "$ARRAY_LIB" 2>/dev/null)"

  if printf '%s' "$kind_output" | grep -q 'kind=flatten' \
    && printf '%s' "$kind_output" | grep -q 'failed to flatten widgets pagination output'; then
    pass "gh_api_array: a parse failure is reported as kind=flatten, distinct from a fetch failure (#1008)"
  else
    fail "gh_api_array mislabelled a flatten failure; got: $kind_output"
  fi

  cat >"$fetch_stub_dir/gh" <<'STUB'
#!/bin/sh
printf '%s\n' 'gh: HTTP 502 upstream exploded' >&2
exit 1
STUB
  chmod +x "$fetch_stub_dir/gh"

  kind_fetch_output="$(PATH="$fetch_stub_dir:$PATH" bash -c '
    set -eo pipefail
    . "$1"
    gh_api_array "repos/o/r/x" "widgets" >/dev/null || true
    printf "kind=%s detail=%s\n" "$GH_API_ARRAY_ERROR_KIND" "$GH_API_ARRAY_DETAIL"
  ' _ "$ARRAY_LIB" 2>/dev/null)"

  if printf '%s' "$kind_fetch_output" | grep -q 'kind=fetch' \
    && printf '%s' "$kind_fetch_output" | grep -q 'HTTP 502 upstream exploded'; then
    pass "gh_api_array: a transport failure is reported as kind=fetch with gh's stderr as the detail (#1008)"
  else
    fail "gh_api_array mislabelled a fetch failure; got: $kind_fetch_output"
  fi

  rm -rf "$fetch_stub_dir"
fi

echo ""
echo "test_codex_review_request_verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
