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

echo ""
echo "test_codex_review_request_verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
