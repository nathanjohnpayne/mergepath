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

# ── #1157: mutable Codex Review Summary issue comment ---------------------
#
# The connector now creates one marker-tagged summary comment while a review
# is Running, then edits that same comment to Completed. The Code Review row
# carries an abbreviated commit, so diagnostic mode can use Completed as
# exact-head completion evidence even when a clean pass produced no review
# object and no legacy `Reviewed commit:` verdict. Running is liveness only.
SUMMARY_SELECTOR=$(sed -n \
  '/^# BEGIN codex_review_summary_selector$/,/^# END codex_review_summary_selector$/p' \
  "$SCRIPT")
if [ -n "$SUMMARY_SELECTOR" ] \
   && grep -q '^crc_select_codex_review_summary()' <<<"$SUMMARY_SELECTOR" \
   && grep -q 'codex-pull-request-review-summary' <<<"$SUMMARY_SELECTOR" \
   && grep -q 'updated_at' <<<"$SUMMARY_SELECTOR"; then
  eval "$SUMMARY_SELECTOR"
  pass "#1157: codex-review-check.sh exposes the marker-scoped mutable summary selector"
else
  fail "#1157: codex-review-check.sh is missing the marker-scoped mutable summary selector"
fi

SUMMARY_BOT="chatgpt-codex-connector[bot]"
SUMMARY_HEAD="d05ff4d0e1a2b3c4d5e6f70819a2b3c4d5e6f708"

summary_body() { # status commit trigger
  printf '<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | %s | `%s` | %s |\n\n<details><summary>ℹ️ About Codex in GitHub</summary></details>' "$1" "$2" "$3"
}

mk_summary() { # login body created updated id
  jq -n --arg login "$1" --arg body "$2" --arg created "$3" --arg updated "$4" --argjson id "$5" \
    '[{user:{login:$login},body:$body,created_at:$created,updated_at:$updated,id:$id}]'
}

run_summary() {
  crc_select_codex_review_summary "$1" "$SUMMARY_BOT" "$SUMMARY_HEAD"
}

if declare -F crc_select_codex_review_summary >/dev/null 2>&1; then
  SUMMARY_COMPLETED=$(mk_summary "$SUMMARY_BOT" \
    "$(summary_body '✅ **Completed** <relative-time datetime="2026-08-30T07:19:37Z">now</relative-time>' d05ff4d0 'Manual request')" \
    "2026-08-30T07:16:18Z" "2026-08-30T07:19:41Z" 101)
  GOT=$(run_summary "$SUMMARY_COMPLETED")
  if [ "$(echo "$GOT" | jq -r '[.status,.commit,.observed_at,.trigger] | @tsv')" = $'completed\td05ff4d0\t2026-08-30T07:19:41Z\tManual request' ]; then
    pass "#1157 summary: exact-head Completed uses edited updated_at as terminal time"
  else
    fail "#1157 summary: exact-head Completed parse mismatch: $GOT"
  fi

  SUMMARY_RUNNING=$(mk_summary "$SUMMARY_BOT" \
    "$(summary_body '🔄 **Running** since 1 minute ago' d05ff4d0 'Manual request')" \
    "2026-08-30T07:16:18Z" "2026-08-30T07:17:18Z" 102)
  GOT=$(run_summary "$SUMMARY_RUNNING")
  if [ "$(echo "$GOT" | jq -r '[.status,.commit,.observed_at] | @tsv')" = $'running\td05ff4d0\t2026-08-30T07:17:18Z' ]; then
    pass "#1157 summary: exact-head Running is represented distinctly from Completed"
  else
    fail "#1157 summary: exact-head Running parse mismatch: $GOT"
  fi

  STALE=$(mk_summary "$SUMMARY_BOT" \
    "$(summary_body '✅ **Completed** now' aaaa1111 'Manual request')" \
    "2026-08-30T07:16:18Z" "2026-08-30T07:19:41Z" 103)
  if [ "$(run_summary "$STALE")" = "null" ]; then
    pass "#1157 summary: stale commit prefix is rejected"
  else
    fail "#1157 summary: stale commit prefix was accepted"
  fi

  WRONG_AUTHOR=$(mk_summary "nathanjohnpayne" \
    "$(summary_body '✅ **Completed** now' d05ff4d0 'Manual request')" \
    "2026-08-30T07:16:18Z" "2026-08-30T07:19:41Z" 104)
  if [ "$(run_summary "$WRONG_AUTHOR")" = "null" ]; then
    pass "#1157 summary: a human-authored lookalike is rejected"
  else
    fail "#1157 summary: a human-authored lookalike was accepted"
  fi

  NO_MARKER_BODY=$(summary_body '✅ **Completed** now' d05ff4d0 'Manual request' | sed '1d')
  NO_MARKER=$(mk_summary "$SUMMARY_BOT" "$NO_MARKER_BODY" \
    "2026-08-30T07:16:18Z" "2026-08-30T07:19:41Z" 105)
  if [ "$(run_summary "$NO_MARKER")" = "null" ]; then
    pass "#1157 summary: an unmarked bot table is rejected"
  else
    fail "#1157 summary: an unmarked bot table was accepted"
  fi

  TWO=$(jq -n --arg bot "$SUMMARY_BOT" --arg old "$(summary_body '✅ **Completed** now' d05ff4d0 'PR opened')" --arg new "$(summary_body '🔄 **Running** since 1 minute ago' d05ff4d0 'Manual request')" '[
    {user:{login:$bot},body:$old,created_at:"2026-08-30T07:00:00Z",updated_at:"2026-08-30T07:05:00Z",id:106},
    {user:{login:$bot},body:$new,created_at:"2026-08-30T07:10:00Z",updated_at:"2026-08-30T07:11:00Z",id:107}
  ]')
  GOT=$(run_summary "$TWO")
  if [ "$(echo "$GOT" | jq -r '[.status,.comment_id] | @tsv')" = $'running\t107' ]; then
    pass "#1157 summary: newest exact-head edited comment wins"
  else
    fail "#1157 summary: newest exact-head edited comment did not win: $GOT"
  fi
fi

if grep -q 'LATEST_SIGNAL_KIND="summary"' "$SCRIPT" \
   && grep -q '\[ -n "\$CODEX_SUMMARY_STATUS" \]' "$SCRIPT" \
   && grep -q 'if \[ "\$CODEX_SUMMARY_STATUS" = "completed" \]; then' "$SCRIPT" \
   && grep -q 'head-anchored Completed Codex review summary' "$SCRIPT" \
   && grep -q 'Codex review summary is Running on current HEAD' "$SCRIPT"; then
  pass "#1157: latest summary state participates in diagnostic ordering; Completed clears and Running does not"
else
  fail "#1157: diagnostic gate does not order both summary states or distinguish Completed from Running"
fi

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

# ── 1b. Structural (#705): same-content carry-forward is present, is routed
#       through the trusted workflow helper, and is only added as a fallback
#       when no current-head Codex signal exists.
if grep -q "CODEX_CARRYFORWARD_VERDICT_TIME" "$SCRIPT" \
   && grep -q "external_review_carryforward.sh" "$SCRIPT" \
   && grep -q 'LATEST_SIGNAL_KIND="carry_verdict"' "$SCRIPT" \
   && grep -q "#705" "$SCRIPT"; then
  pass "codex-review-check.sh carries forward prior clean Codex verdicts for unchanged external-review fingerprints (#705)"
else
  fail "codex-review-check.sh is missing same-content Codex verdict carry-forward (#705)"
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

# ── 3c. Structural (#727, Codex P2 on #729): the CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE
#      env var overrides the policy value, taking precedence over
#      `codex_field allow_phase_4b_substitute`. The post-clearance fast-path
#      probe sets it to false so gate (c) requires an ACTUAL Codex bot signal and
#      is NOT satisfied by the same reviewer APPROVED that clears gate (b) — the
#      env override must win, else a bare under-threshold approval would arm the
#      shortened CodeRabbit wait and reopen the pre-review merge race.
if grep -Eq 'ALLOW_PHASE_4B_SUBSTITUTE=\$\{CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE:-\$\(codex_field allow_phase_4b_substitute\)\}' "$SCRIPT"; then
  pass "gate (c) honors the CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE env override, precedence over policy (#727 fast-path probe requires an actual Codex signal)"
else
  fail "codex-review-check.sh does not let CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE override the policy value (#727)"
fi

# ── 3d. Structural (#1062): the completed-workflow continuation can reuse
#      gates (a) and (b) without imposing gate (c) on an under-threshold PR.
#      The mode is an explicit non-inheritable flag, requires a real registered
#      APPROVED review (no same-agent exclusion and no Codex branch-2
#      substitution), and returns before gate (c).
if grep -q -- '--approval-readiness-only' "$SCRIPT" \
   && grep -q 'APPROVAL_READINESS_ONLY=1' "$SCRIPT" \
   && grep -q 'GATE_B_SAME_AGENT_REVIEWER=""' "$SCRIPT" \
   && grep -q 'CURRENT_RUN_ID="\$GITHUB_RUN_ID"' "$SCRIPT" \
   && grep -q 'external clearance intentionally delegated to the threshold-aware merge-clearance gate' "$SCRIPT"; then
  pass "approval-readiness mode reuses current-head CI/annex plus registered approval without imposing Phase 4 or self-deadlocking (#1062)"
else
  fail "approval-readiness mode is missing its explicit flag, reviewer semantics, self-run guard, or pre-gate-(c) return (#1062)"
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

# ── #814: the diagnostic bypass is a FLAG, not an inheritable env var.
#
# This script is the delegate of a REQUIRED status check in every fleet repo.
# --diagnostic-signal-only skips gate (b) and disables the #705 carry-forward,
# which WEAKENS the gate — so the risk is not what it does when asked for, but
# whether a caller can get it without asking. An environment variable is
# inherited by every child process, so merge-clearance-gate.sh, agent-review.yml
# and the auto-clear workflow would pick it up from a runner env or a
# workflow-level `env:` block and silently stop checking reviewer approval
# (CodeRabbit Major on #835). A flag cannot be inherited.
#
# Structural, matching this file's documented approach; the behavioural check
# (env var inert, flag effective) was run live against a real PR and is not
# automated here, because driving the full flow needs a gh stub harness this
# suite does not have.
knob_ok=1
# The bypass is reachable ONLY through the flag.
grep -q -- '--diagnostic-signal-only) DIAGNOSTIC_SIGNAL_ONLY=1 ;;' "$SCRIPT" || knob_ok=0
grep -q '^SKIP_REVIEWER_APPROVAL="\$DIAGNOSTIC_SIGNAL_ONLY"' "$SCRIPT" || knob_ok=0
grep -q '^REQUIRE_HEAD_SIGNAL="\$DIAGNOSTIC_SIGNAL_ONLY"' "$SCRIPT" || knob_ok=0
# No environment variable may enable it. This is the assertion that fails if
# anyone reintroduces the inheritable form.
if grep -qE 'CODEX_REVIEW_CHECK_(SKIP_REVIEWER_APPROVAL|REQUIRE_HEAD_SIGNAL)' "$SCRIPT"; then
  knob_ok=0
fi
# Defaults off, and the skip cannot mask a real approval.
grep -q '^DIAGNOSTIC_SIGNAL_ONLY=0' "$SCRIPT" || knob_ok=0
grep -q 'if \[ -z "\$APPROVING_REVIEWER" \] && \[ "\$SKIP_REVIEWER_APPROVAL" = "1" \]; then' "$SCRIPT" || knob_ok=0
# The gate (b) hard failure is still reachable without the flag.
grep -q 'fail_gate "no reviewer identity in available_reviewers has a latest-state APPROVED' "$SCRIPT" || knob_ok=0
if [ "$knob_ok" = 1 ]; then
  pass "#814: the gate bypass is flag-only, defaults off, has no env-var path, and cannot mask a real approval"
else
  fail "#814: the gate bypass lost one of its non-inheritability guarantees"
fi

# Diagnostic mode asks only whether Codex produced a current-head signal for
# the Phase 4b barrier. Its caller supplies the author explicitly, so a legacy
# or external-contributor PR without an Authoring-Agent marker must not abort
# before that signal check runs. Execute the real script with fixture PR bodies
# and stop it at the immediately-following commit read: this proves the parser
# branch was bypassed, rather than merely proving that expected source text
# exists somewhere in the file.
BEHAVIOR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-check-body.XXXXXX")"
trap 'rm -rf "$BEHAVIOR_TMP"' EXIT
mkdir -p "$BEHAVIOR_TMP/bin"
cat >"$BEHAVIOR_TMP/policy.yml" <<'POLICY'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
codex:
  enabled: true
  require_ci_green: false
POLICY
cat >"$BEHAVIOR_TMP/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [ "$1" = api ] && [[ "$2" == repos/*/pulls/7 ]]; then
  jq -n --arg author "${FIXTURE_PR_AUTHOR:?}" --arg body "${FIXTURE_PR_BODY-}" \
    '{head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},user:{login:$author},body:$body}'
  exit 0
fi
echo "fixture commit stop" >&2
exit 1
GHSTUB
chmod +x "$BEHAVIOR_TMP/bin/gh"

run_body_fixture() {
  local author=$1 mode=$2 body=${3:-} output rc
  set +e
  output=$(PATH="$BEHAVIOR_TMP/bin:$PATH" GH_TOKEN=fixture \
    MERGEPATH_REVIEW_POLICY_PATH="$BEHAVIOR_TMP/policy.yml" \
    FIXTURE_PR_AUTHOR="$author" FIXTURE_PR_BODY="$body" \
    "$SCRIPT" $mode 7 owner/repo 2>&1)
  rc=$?
  set -e
  printf '%s\n%s\n' "$rc" "$output"
}

fixture_result="$(run_body_fixture nathanjohnpayne --diagnostic-signal-only)"
fixture_rc="${fixture_result%%$'\n'*}"
fixture_output="${fixture_result#*$'\n'}"
if [ "$fixture_rc" = "3" ] \
   && grep -q 'diagnostic-signal-only: skipping Authoring-Agent' <<<"$fixture_output" \
   && grep -q 'failed to fetch commit date' <<<"$fixture_output" \
   && ! grep -q 'PR body declares' <<<"$fixture_output"; then
  pass "#1121: diagnostic-signal-only executes past a markerless PR body"
else
  fail "#1121: diagnostic markerless fixture did not bypass identity parsing (rc=$fixture_rc output=$fixture_output)"
fi

fixture_result="$(run_body_fixture external-contributor '')"
fixture_rc="${fixture_result%%$'\n'*}"
fixture_output="${fixture_result#*$'\n'}"
if [ "$fixture_rc" = "3" ] \
   && grep -q 'non-shared-author PR: skipping Authoring-Agent' <<<"$fixture_output" \
   && grep -q 'failed to fetch commit date' <<<"$fixture_output" \
   && ! grep -q 'PR body declares' <<<"$fixture_output"; then
  pass "#1121: a markerless non-shared-author PR executes past identity parsing"
else
  fail "#1121: non-shared-author markerless fixture did not bypass identity parsing (rc=$fixture_rc output=$fixture_output)"
fi

fixture_result="$(run_body_fixture nathanjohnpayne '' 'Authoring-Agent: unknown')"
fixture_rc="${fixture_result%%$'\n'*}"
fixture_output="${fixture_result#*$'\n'}"
if [ "$fixture_rc" = "3" ] && grep -q 'does not map to exactly one configured reviewer' <<<"$fixture_output"; then
  pass "#1121: an unregistered Authoring-Agent fails closed before gate evaluation"
else
  fail "#1121: unregistered Authoring-Agent fixture did not fail closed (rc=$fixture_rc output=$fixture_output)"
fi

# Positional rather than a text scan — the header documents gate (c) long
# before it is evaluated, so a "starts matching at the first mention" filter
# reports a false leak (it did, on the first version of this assertion).
knob_last=$(grep -n 'SKIP_REVIEWER_APPROVAL\|REQUIRE_HEAD_SIGNAL' "$SCRIPT" | tail -1 | cut -d: -f1)
gatec_at=$(grep -n 'log "gate (c): checking external clearance' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$knob_last" ] && [ -n "$gatec_at" ] && [ "$knob_last" -lt "$gatec_at" ]; then
  pass "#814: every bypass reference precedes the gate (c) evaluation — it cannot influence external clearance"
else
  fail "#814: bypass reference at line ${knob_last:-?} is not before gate (c) at ${gatec_at:-?}"
fi

# #842: the CANNOT-REPORT exit must be diagnostic-mode-only. The barrier reads
# exit 2 as "Codex is account-blocked, waive it and let Phase 4b run"; a real
# merge-gate caller must never reach it, because an account-blocked Codex has
# cleared nothing and the gate has to keep failing closed on 1.
exit2_at=$(grep -n '^      exit 2$' "$SCRIPT" | head -1 | cut -d: -f1)
guard_ok=0
if [ -n "$exit2_at" ]; then
  # The guard must be within the few lines immediately above the exit, so a
  # later edit cannot leave the exit reachable from the gate path.
  guard_at=$(sed -n "$((exit2_at - 4)),$((exit2_at - 1))p" "$SCRIPT" \
    | grep -c 'DIAGNOSTIC_SIGNAL_ONLY" = "1"' || true)
  # Proximity alone is not containment (CodeRabbit on #842): moving `fi` above
  # the exit would leave the guard text nearby while the exit sits outside the
  # block. Require that no `fi` closes between the guard and the exit.
  fi_between=$(sed -n "$((exit2_at - 4)),$((exit2_at - 1))p" "$SCRIPT" \
    | grep -cE '^[[:space:]]*fi[[:space:]]*$' || true)
  [ "$guard_at" -ge 1 ] && [ "$fi_between" -eq 0 ] && guard_ok=1
fi
# And it must be the ONLY exit 2 in the script, so the documented 0/1/3
# contract still holds for every non-diagnostic caller.
n_exit2=$(grep -c '^[[:space:]]*exit 2$' "$SCRIPT" || true)
if [ "$guard_ok" = 1 ] && [ "$n_exit2" = "1" ]; then
  pass "#842: the CANNOT-REPORT exit is diagnostic-only and unique — the merge gate's 0/1/3 contract is unchanged"
else
  fail "#842: exit 2 is unguarded or duplicated (guard_ok=$guard_ok count=$n_exit2)"
fi

echo ""
echo "test_codex_review_check_verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
