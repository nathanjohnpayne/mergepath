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

# ── 3. Structural: gate (c) folds the verdict into a UNIFIED latest-signal-wins
#      decision (not a fallback after CLEARED), and the verdict path clears ONLY
#      when the latest verdict is affirmative AND there are zero unaddressed
#      P0/P1 — a non-affirmative latest verdict fails closed (#608 P1).
if grep -q "LATEST_SIGNAL_KIND" "$SCRIPT" \
   && grep -Eq 'if \[ -n "\$CODEX_HEAD_VERDICT_TIME" \] && \[ "\$UNADDRESSED_COUNT" -eq 0 \]; then' "$SCRIPT" \
   && grep -q "fail closed, does not clear (#608 P1)" "$SCRIPT"; then
  pass "gate (c) folds the verdict into latest-signal-wins; a non-affirmative latest verdict fails closed (#608 P1)"
else
  fail "gate (c) is missing the unified latest-signal-wins decision or the verdict fail-closed branch"
fi

# ── 3b. Structural (#608): latest-verdict-first (a newer non-affirmative
#      verdict supersedes an older clean one), and the latest verdict timestamp
#      (any disposition) is carried into the Phase 4b substitute freshness guard.
if grep -q "CODEX_HEAD_VERDICT_ANY_TIME" "$SCRIPT" \
   && grep -q "max_by(.created_at)" "$SCRIPT" \
   && grep -qF '(?im)^' "$SCRIPT" \
   && grep -qi "codex review:" "$SCRIPT" \
   && grep -q "#608" "$SCRIPT"; then
  pass "codex-review-check.sh selects latest verdict first, anchors the affirmative match to the Codex verdict header, and folds the any-verdict timestamp into the Phase 4b guard (#608 P1/P2/CR-Major)"
else
  fail "codex-review-check.sh is missing the latest-verdict-first restructure (max_by / CODEX_HEAD_VERDICT_ANY_TIME / #608)"
fi

# ── 4. Inline logic: the verdict-matching jq filter. KEEP IN SYNC with
#      scripts/codex-review-check.sh CODEX_VERDICT_JSON. The filter selects the
#      LATEST HEAD-anchored verdict FIRST (any disposition), then requires that
#      latest verdict to be affirmative — so a newer NON-affirmative verdict on
#      the same HEAD supersedes an older clean one and fails closed (Codex P1 on
#      #608). VERDICT_FILTER returns the affirmative-gated clearance timestamp
#      (CODEX_HEAD_VERDICT_TIME); ANY_FILTER returns the latest verdict
#      timestamp regardless of disposition (CODEX_HEAD_VERDICT_ANY_TIME, used by
#      the Phase 4b freshness guard).
BOT="chatgpt-codex-connector[bot]"
HEAD="d05ff4d0e1a2b3c4d5e6f70819a2b3c4d5e6f708"
LATEST_HEAD_VERDICT='
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
VERDICT_FILTER="$LATEST_HEAD_VERDICT"'
    | if . == null then "" elif .affirmative then .created_at else "" end'
ANY_FILTER="$LATEST_HEAD_VERDICT"'
    | if . == null then "" else .created_at end'

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
  "$(mk "$BOT" "Codex Review: Didn't find any major issues.
Reviewed commit: $HEAD" "2026-07-01T11:00:00Z")"

# 4g. accept: apostrophe-less 'Didnt' + backticked sha.
check_case "apostrophe-less 'Didnt' + backticked sha → clears" \
  "2026-07-01T09:00:00Z" \
  "$(mk "$BOT" "Codex Review: Didnt find any major issues.
Reviewed commit: \`d05ff4d0e\`" "2026-07-01T09:00:00Z")"

# 4h. latest-wins: two qualifying comments → max(created_at).
check_case "two qualifying verdicts → picks the latest created_at" \
  "2026-07-01T12:00:00Z" \
  "$(jq -n --arg bot "$BOT" --arg h "$HEAD" '[
     {user:{login:$bot},body:("Codex Review: Didn'"'"'t find any major issues.\nReviewed commit: d05ff4d0"),created_at:"2026-07-01T10:00:00Z"},
     {user:{login:$bot},body:("Codex Review: Didn'"'"'t find any major issues. Keep them coming!\nReviewed commit: d05ff4d0e"),created_at:"2026-07-01T12:00:00Z"}
   ]')"

# 4i. P1 (#608) latest-wins fail-closed: older AFFIRMATIVE then a NEWER
#     NON-affirmative verdict on the same HEAD → clearance signal is EMPTY
#     (the newer negative verdict supersedes the older clean one).
NEWER_NEGATIVE="$(jq -n --arg bot "$BOT" '[
   {user:{login:$bot},body:("Codex Review: Didn'"'"'t find any major issues.\nReviewed commit: d05ff4d0"),created_at:"2026-07-01T10:00:00Z"},
   {user:{login:$bot},body:("Codex Review: Found 2 issues to address.\nReviewed commit: d05ff4d0e"),created_at:"2026-07-01T12:00:00Z"}
 ]')"
check_case "older affirmative + NEWER non-affirmative verdict → clearance empty (P1 #608)" \
  "" "$NEWER_NEGATIVE"

# 4j. latest-wins accept: older NON-affirmative then a NEWER affirmative → the
#     newer affirmative clears (returns its created_at).
check_case "older non-affirmative + NEWER affirmative verdict → clears on the newer" \
  "2026-07-01T12:00:00Z" \
  "$(jq -n --arg bot "$BOT" '[
     {user:{login:$bot},body:("Codex Review: Found 1 issue.\nReviewed commit: d05ff4d0"),created_at:"2026-07-01T10:00:00Z"},
     {user:{login:$bot},body:("Codex Review: Didn'"'"'t find any major issues.\nReviewed commit: d05ff4d0e"),created_at:"2026-07-01T12:00:00Z"}
   ]')"

# 4k. ANY-timestamp (Phase 4b guard, #608 P2): the latest HEAD-anchored verdict
#     timestamp is carried REGARDLESS of disposition, so a newer NEGATIVE
#     verdict still raises the freshness floor above a stale Phase 4b approval.
run_any() { printf '%s' "$1" | jq -r --arg bot "$BOT" --arg sha "$HEAD" "$ANY_FILTER"; }
GOT_ANY="$(run_any "$NEWER_NEGATIVE")"
if [ "$GOT_ANY" = "2026-07-01T12:00:00Z" ]; then
  pass "verdict ANY-timestamp: newer non-affirmative verdict is carried for the Phase 4b guard (#608 P2)"
else
  fail "verdict ANY-timestamp: expected 2026-07-01T12:00:00Z, got '$GOT_ANY'"
fi

# 4l. CodeRabbit Major (#608): a HEAD-anchored NEGATIVE verdict that QUOTES a
#     prior affirmative (blockquote) must NOT read as affirmative — the match is
#     anchored to the "Codex Review:" header line, so quoted text is ignored.
check_case "negative verdict quoting an affirmative (blockquote) → clearance empty (anchored, #608)" \
  "" \
  "$(mk "$BOT" "Codex Review: Found 2 issues to address.

> Codex Review: Didn't find any major issues

Reviewed commit: d05ff4d0" "2026-07-01T13:00:00Z")"

# 4m. accept: a genuine affirmative whose body has a leading preamble line, with
#     the "Codex Review:" verdict header on its own line (multiline anchor).
check_case "affirmative header on a later line (multiline anchor) → clears" \
  "2026-07-01T14:00:00Z" \
  "$(mk "$BOT" "Here are some automated review suggestions.
Codex Review: Didn't find any major issues.
Reviewed commit: d05ff4d0" "2026-07-01T14:00:00Z")"

# ── 5. Gate (c) unified latest-signal-wins (#608 P1). Model the case block in
#      codex-review-check.sh: pick the newest of {👍, review, verdict} (ties go
#      verdict > review > 👍), then clear per that signal's disposition. KEEP IN
#      SYNC with the LATEST_SIGNAL_KIND case in codex-review-check.sh.
gatec_clears() { # thumbs_t review_t verdict_any_t verdict_affirm(0/1) unaddressed
  local tt="$1" rt="$2" vt="$3" va="$4" uc="$5"
  local kind="" time="" sig k t
  for sig in "thumbs|$tt" "review|$rt" "verdict|$vt"; do
    k=${sig%%|*}; t=${sig#*|}
    [ -n "$t" ] || continue
    if [ -z "$time" ] || [[ "$t" > "$time" ]] || [ "$t" = "$time" ]; then
      time="$t"; kind="$k"
    fi
  done
  case "$kind" in
    thumbs) echo yes ;;
    review) if [ "$uc" -eq 0 ]; then echo yes; else echo no; fi ;;
    verdict) if [ "$va" = "1" ] && [ "$uc" -eq 0 ]; then echo yes; else echo no; fi ;;
    *) echo no ;;
  esac
}
gc() { # desc expected thumbs review verdict affirm unaddressed
  local desc="$1" exp="$2" got
  got=$(gatec_clears "$3" "$4" "$5" "$6" "$7")
  if [ "$got" = "$exp" ]; then pass "gate (c) latest-signal: $desc"; else fail "gate (c) latest-signal: $desc — expected $exp got $got"; fi
}
# THE #608 P1 regression: an older clean 👍/review must NOT clear when a NEWER
# non-affirmative verdict exists on HEAD.
gc "older 👍 + NEWER non-affirmative verdict → NO (P1 #608)"        no  "2026-07-01T10:00:00Z" ""                    "2026-07-01T12:00:00Z" 0 0
gc "older clean review + NEWER non-affirmative verdict → NO (#608)" no  ""                    "2026-07-01T10:00:00Z" "2026-07-01T12:00:00Z" 0 0
gc "same-second 👍 vs non-affirmative verdict → verdict wins tie → NO" no "2026-07-01T10:00:00Z" ""                 "2026-07-01T10:00:00Z" 0 0
gc "older non-affirmative verdict + NEWER 👍 → YES"                 yes "2026-07-01T12:00:00Z" ""                    "2026-07-01T10:00:00Z" 0 0
gc "verdict-only affirmative + 0 findings → YES"                    yes ""                    ""                    "2026-07-01T10:00:00Z" 1 0
gc "verdict-only affirmative + unaddressed findings → NO"           no  ""                    ""                    "2026-07-01T10:00:00Z" 1 2
gc "thumbs-only → YES"                                              yes "2026-07-01T10:00:00Z" ""                    ""                    0 0
gc "review-only clean → YES"                                        yes ""                    "2026-07-01T10:00:00Z" ""                    0 0
gc "no signals at all → NO"                                         no  ""                    ""                    ""                    0 0

echo ""
echo "test_codex_review_check_verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
