#!/usr/bin/env bash
# tests/test_codex_review_check_verdict.sh
#
# Regression coverage for the HEAD-anchored Codex issue-comment verdict
# clearance path in scripts/codex-review-check.sh (#600 / #567).
#
# Codex posts its review verdict as a PR ISSUE COMMENT
# (issues/{pr}/comments) — "Codex Review: Didn't find any major issues.
# <quip>" + a "Reviewed commit: <sha>" line — NOT always a review object,
# and its 👍 reaction expires after reaction_freshness_window_seconds. So a
# genuinely-clean Codex clearance can exist ONLY as that comment. #600
# extends gate (b) branch 2 and gate (c) to honor it, fail-closed.
#
# The full gate (c) runs the entire codex-review-check flow (CI + gate (b) +
# issue comments + reactions + reviewThreads), which needs network; this
# test pins (1) the structural presence of the verdict signal + both gate
# hooks in the real script, and (2) the verdict-matching jq logic inline —
# the same inline-literal pattern test_codex_review_check_resolution.sh uses.
# KEEP THE INLINE FILTER BELOW IN SYNC with the CODEX_HEAD_VERDICT_TIME
# filter in scripts/codex-review-check.sh.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review-check.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── 1. Structural: the shared verdict signal is computed from issue
#      comments, gated on codex.enabled, HEAD-anchored + affirmative-matched,
#      and referenced to #600.
if grep -q "CODEX_HEAD_VERDICT_TIME" "$SCRIPT" \
   && grep -q 'issues/\$PR_NUMBER/comments' "$SCRIPT" \
   && grep -qi "didn.?t find any major issues" "$SCRIPT" \
   && grep -q "reviewed commit\[\^0-9a-f\]" "$SCRIPT" \
   && grep -q "startswith(\$s)" "$SCRIPT" \
   && grep -q "#600" "$SCRIPT"; then
  pass "codex-review-check.sh computes the HEAD-anchored affirmative issue-comment verdict signal (#600)"
else
  fail "codex-review-check.sh is missing the verdict signal (CODEX_HEAD_VERDICT_TIME / issue-comments fetch / affirmative regex / reviewed-commit scan / prefix anchor / #600)"
fi

# ── 2. Structural: gate (b) branch 2 accepts the verdict comment as a
#      same-agent cross-review signal (elif after the 👍 branch).
if grep -q 'elif \[ -n "\$CODEX_HEAD_VERDICT_TIME" \]; then' "$SCRIPT" \
   && grep -q "branch 2: same-agent + Codex verdict comment" "$SCRIPT"; then
  pass "gate (b) branch 2 accepts the HEAD-anchored verdict comment (#600)"
else
  fail "gate (b) branch 2 does not accept the verdict comment"
fi

# ── 3. Structural: gate (c) accepts the verdict comment ONLY with the
#      fail-closed UNADDRESSED_COUNT==0 cross-check.
if grep -Eq 'if \[ "\$CLEARED" != "true" \] && \[ -n "\$CODEX_HEAD_VERDICT_TIME" \] && \[ "\$UNADDRESSED_COUNT" -eq 0 \]; then' "$SCRIPT"; then
  pass "gate (c) honors the verdict comment gated on zero unaddressed P0/P1 findings (fail-closed, #600)"
else
  fail "gate (c) is missing the verdict clearance path or its UNADDRESSED_COUNT==0 cross-check"
fi

# ── 4. Inline logic: the verdict-matching jq filter. KEEP IN SYNC with
#      scripts/codex-review-check.sh CODEX_HEAD_VERDICT_TIME.
BOT="chatgpt-codex-connector[bot]"
HEAD="d05ff4d0e1a2b3c4d5e6f70819a2b3c4d5e6f708"
VERDICT_FILTER='
    ($sha | ascii_downcase) as $head
    | [ .[]
        | select(.user.login == $bot)
        | select(.body | test("(?i)didn.?t find any major issues"))
        | . as $c
        | ( [ $c.body
              | ascii_downcase
              | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
              | .[0]
            ] ) as $shas
        | select( ($shas | length) > 0
                  and ($shas | any(. as $s | $head | startswith($s))) )
        | $c.created_at
      ]
    | max // ""'

# fixture builder — guarantees valid JSON encoding (real newlines, apostrophes)
mk() { jq -n --arg login "$1" --arg body "$2" --arg t "$3" \
  '[{user:{login:$login},body:$body,created_at:$t}]'; }
run_verdict() { printf '%s' "$1" | jq -r --arg bot "$BOT" --arg sha "$HEAD" "$VERDICT_FILTER"; }

check_case() { # desc expected fixture
  local desc="$1" expected="$2" fixture="$3" got
  got="$(run_verdict "$fixture")"
  if [ "$got" = "$expected" ]; then
    pass "verdict filter: $desc"
  else
    fail "verdict filter: $desc — expected '$expected', got '$got'"
  fi
}

# 4a. accept: affirmative + 8-char prefix + markdown-bold, over newlines.
check_case "affirmative + prefix sha + markdown-bold anchor → clears" \
  "2026-07-01T10:00:00Z" \
  "$(mk "$BOT" "Codex Review: Didn't find any major issues. Swish!
**Reviewed commit:** d05ff4d0" "2026-07-01T10:00:00Z")"

# 4b. fail-closed: Reviewed commit does not prefix HEAD (stale head).
check_case "stale-HEAD verdict (Reviewed commit != HEAD prefix) → empty" \
  "" \
  "$(mk "$BOT" "Didn't find any major issues. Breezy!
Reviewed commit: aaaa1111bbbb" "2026-07-01T10:00:00Z")"

# 4c. fail-closed: findings verdict (not the affirmative shape).
check_case "findings verdict (non-affirmative body) → empty" \
  "" \
  "$(mk "$BOT" "Codex Review: Found 2 issues to address.
Reviewed commit: d05ff4d0" "2026-07-01T10:00:00Z")"

# 4d. fail-closed: affirmative but NO Reviewed-commit anchor line.
check_case "affirmative but no Reviewed-commit line → empty" \
  "" \
  "$(mk "$BOT" "Didn't find any major issues. Chef's kiss." "2026-07-01T10:00:00Z")"

# 4e. fail-closed: right phrase + anchor but WRONG author (human quote-reply).
check_case "wrong author echoing the phrase + anchor → empty" \
  "" \
  "$(mk "nathanpayne-claude" "Codex said: Didn't find any major issues.
Reviewed commit: d05ff4d0" "2026-07-01T10:00:00Z")"

# 4f. accept: full 40-char sha (exact match is a prefix of itself).
check_case "full 40-char Reviewed-commit sha → clears" \
  "2026-07-01T11:00:00Z" \
  "$(mk "$BOT" "Didn't find any major issues.
Reviewed commit: $HEAD" "2026-07-01T11:00:00Z")"

# 4g. accept: apostrophe-less 'Didnt' + backticked sha.
check_case "apostrophe-less 'Didnt' + backticked sha → clears" \
  "2026-07-01T09:00:00Z" \
  "$(mk "$BOT" "Didnt find any major issues.
Reviewed commit: \`d05ff4d0e\`" "2026-07-01T09:00:00Z")"

# 4h. latest-wins: two qualifying comments → max(created_at).
check_case "two qualifying verdicts → picks the latest created_at" \
  "2026-07-01T12:00:00Z" \
  "$(jq -n --arg bot "$BOT" --arg h "$HEAD" '[
     {user:{login:$bot},body:("Didn'"'"'t find any major issues.\nReviewed commit: d05ff4d0"),created_at:"2026-07-01T10:00:00Z"},
     {user:{login:$bot},body:("Didn'"'"'t find any major issues. Keep them coming!\nReviewed commit: d05ff4d0e"),created_at:"2026-07-01T12:00:00Z"}
   ]')"

# ── 5. Gate (c) fail-closed cross-check: the verdict clears ONLY when there
#      are zero unaddressed P0/P1 findings on HEAD. Model the exact shell
#      condition `CLEARED!=true && VERDICT!="" && UNADDRESSED_COUNT==0`.
gatec_verdict_clears() { # cleared verdict_time unaddressed_count -> "yes"/"no"
  local cleared="$1" vt="$2" uc="$3"
  if [ "$cleared" != "true" ] && [ -n "$vt" ] && [ "$uc" -eq 0 ]; then
    echo yes
  else
    echo no
  fi
}
# not-yet-cleared ("false") models the verdict path being reached after the
# review / 👍 paths did not clear.
if [ "$(gatec_verdict_clears false "2026-07-01T10:00:00Z" 0)" = "yes" ]; then
  pass "gate (c): verdict present + 0 unaddressed P0/P1 → clears"
else
  fail "gate (c): verdict + 0 findings should clear"
fi
if [ "$(gatec_verdict_clears false "2026-07-01T10:00:00Z" 2)" = "no" ]; then
  pass "gate (c): verdict present + 2 unaddressed P0/P1 → does NOT clear (fail-closed)"
else
  fail "gate (c): verdict + unresolved findings must NOT clear"
fi
if [ "$(gatec_verdict_clears false "" 0)" = "no" ]; then
  pass "gate (c): no verdict comment → verdict path is a no-op"
else
  fail "gate (c): absent verdict must not clear via this path"
fi
# already-cleared ("true", e.g. via 👍/review) short-circuits the verdict path.
if [ "$(gatec_verdict_clears true "2026-07-01T10:00:00Z" 0)" = "no" ]; then
  pass "gate (c): already-cleared short-circuits the verdict path (no double-eval)"
else
  fail "gate (c): CLEARED=true should short-circuit the verdict path"
fi

echo ""
echo "test_codex_review_check_verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
