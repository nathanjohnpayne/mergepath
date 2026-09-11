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

# #1085: an automated Phase 4b substitute reached through a durable Phase 4a
# timeout must carry that exact timeout generation into its review body. The
# later merge-clearance read validates the binding against the LIVE timeout
# state, so a same-head author trigger landing after Phase 4b's final timeline
# read invalidates the old approval instead of clearing gate (c). Manual
# external approvals and non-timeout automated evidence retain their existing
# paths.
P4B_SELECTOR=$(sed -n \
  '/^# BEGIN phase4b_approver_selector$/,/^# END phase4b_approver_selector$/p' \
  "$SCRIPT")
if [ -n "$P4B_SELECTOR" ] \
   && grep -q '^crc_select_phase4b_approver()' <<<"$P4B_SELECTOR" \
   && grep -q 'clearance record' <<<"$P4B_SELECTOR"; then
  # The selector delegates the marker grammar to the same shared parser used
  # by the automated-review writer.
  # shellcheck source=../scripts/lib/codex-failure-markers.sh
  . "$ROOT/scripts/lib/codex-failure-markers.sh"
  eval "$P4B_SELECTOR"
  pass "#1085: codex-review-check.sh exposes the timeout-generation-bound Phase 4b selector"
else
  fail "#1085: codex-review-check.sh is missing the timeout-generation-bound Phase 4b selector"
fi

if declare -F crc_select_phase4b_approver >/dev/null 2>&1; then
  P4B_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  P4B_REVIEWERS='["nathanpayne-claude"]'
  P4B_TIMEOUT_BODY="$(printf '%s\n\n**Automated Phase 4b review**' \
    "$(codex_phase4b_clearance_marker_body "$P4B_HEAD" timeout 4101)")"
  P4B_SIGNAL_BODY="$(printf '%s\n\n**Automated Phase 4b review**' \
    "$(codex_phase4b_clearance_marker_body "$P4B_HEAD" signal none)")"
  P4B_REVIEWS=$(jq -cn --arg body "$P4B_TIMEOUT_BODY" --arg head "$P4B_HEAD" '[
    {id:1,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:00:00Z",commit_id:$head,body:$body}
  ]')
  p4b_pick() {
    crc_select_phase4b_approver "$P4B_REVIEWS" "$P4B_REVIEWERS" nathanjohnpayne nathanpayne-codex "$P4B_HEAD" "$1"
  }
  _picked="$(p4b_pick '{"state":"current","trigger_comment_id":4101}')"
  [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 1 ] \
    && pass "#1085 Phase 4b binding: exact live timeout generation is accepted" \
    || fail "#1085 Phase 4b binding: exact live timeout generation was rejected: $_picked"

  for _state in \
    '{"state":"superseded","superseding_trigger_comment_id":4103}' \
    '{"state":"current","trigger_comment_id":4103}'; do
    _picked="$(p4b_pick "$_state")"
    [ "$_picked" = null ] \
      && pass "#1085 Phase 4b binding: changed timeout generation is rejected" \
      || fail "#1085 Phase 4b binding: changed timeout generation cleared: $_picked"
  done

  P4B_REVIEWS=$(jq -cn --arg head "$P4B_HEAD" '[
    {id:2,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:01:00Z",commit_id:$head,body:"Manual external review: approved."}
  ]')
  _picked="$(p4b_pick '{"state":"superseded","superseding_trigger_comment_id":4103}')"
  [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 2 ] \
    && pass "#1085 Phase 4b binding: manual external approval remains independent of the automated marker" \
    || fail "#1085 Phase 4b binding: manual external approval was rejected: $_picked"

  P4B_REVIEWS=$(jq -cn --arg body "$P4B_SIGNAL_BODY" --arg head "$P4B_HEAD" '[
    {id:3,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:02:00Z",commit_id:$head,body:$body}
  ]')
  _picked="$(p4b_pick '{"state":"none"}')"
  [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 3 ] \
    && pass "#1085 Phase 4b binding: non-timeout automated evidence stays eligible" \
    || fail "#1085 Phase 4b binding: non-timeout automated evidence was rejected: $_picked"

  for _evidence in account-or-connection-block disabled; do
    _body="$(printf '%s\n\n**Automated Phase 4b review**' \
      "$(codex_phase4b_clearance_marker_body "$P4B_HEAD" "$_evidence" none)")"
    P4B_REVIEWS=$(jq -cn --arg body "$_body" --arg head "$P4B_HEAD" '[
      {id:31,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:02:30Z",commit_id:$head,body:$body}
    ]')
    _picked="$(p4b_pick '{"state":"none"}')"
    [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 31 ] \
      && pass "#1085 Phase 4b binding: $_evidence automated evidence stays eligible without a timeout timeline" \
      || fail "#1085 Phase 4b binding: $_evidence evidence was rejected: $_picked"
  done

  P4B_REVIEWS=$(jq -cn --arg head "$P4B_HEAD" '[
    {id:4,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:03:00Z",commit_id:$head,body:"**Automated Phase 4b review**"}
  ]')
  _picked="$(p4b_pick '{"state":"current","trigger_comment_id":4101}')"
  [ "$_picked" = null ] \
    && pass "#1085 Phase 4b binding: unmarked automated approval fails closed" \
    || fail "#1085 Phase 4b binding: unmarked automated approval cleared: $_picked"

  P4B_BAD_BODY="$(printf '%s\n%s\n\n**Automated Phase 4b review**' \
    "$(codex_phase4b_clearance_marker_body "$P4B_HEAD" timeout 4101)" \
    "$(codex_phase4b_clearance_marker_body "$P4B_HEAD" timeout 4101)")"
  P4B_REVIEWS=$(jq -cn --arg body "$P4B_BAD_BODY" --arg head "$P4B_HEAD" '[
    {id:5,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:04:00Z",commit_id:$head,body:$body}
  ]')
  _picked="$(p4b_pick '{"state":"current","trigger_comment_id":4101}')"
  [ "$_picked" = null ] \
    && pass "#1085 Phase 4b binding: duplicate automated clearance records fail closed" \
    || fail "#1085 Phase 4b binding: duplicate clearance records cleared: $_picked"

  P4B_REVIEWS=$(jq -cn --arg body "$P4B_TIMEOUT_BODY" --arg head "$P4B_HEAD" '[
    {id:6,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:05:00Z",commit_id:$head,body:$body},
    {id:7,user:{login:"nathanpayne-claude"},state:"CHANGES_REQUESTED",submitted_at:"2026-09-01T00:06:00Z",commit_id:$head,body:"newer objection"}
  ]')
  _picked="$(p4b_pick '{"state":"current","trigger_comment_id":4101}')"
  [ "$_picked" = null ] \
    && pass "#1085 Phase 4b binding: a reviewer's newer objection supersedes its bound approval" \
    || fail "#1085 Phase 4b binding: a stale approval survived the reviewer's newer objection: $_picked"

  P4B_REVIEWS=$(jq -cn --arg timeout "$P4B_TIMEOUT_BODY" --arg head "$P4B_HEAD" '[
    {id:8,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:07:00Z",commit_id:$head,body:$timeout},
    {id:9,user:{login:"nathanpayne-claude"},state:"CHANGES_REQUESTED",submitted_at:"2026-09-01T00:08:00Z",commit_id:$head,body:"supersedes timeout"},
    {id:10,user:{login:"nathanpayne-cursor"},state:"APPROVED",submitted_at:"2026-09-01T00:09:00Z",commit_id:$head,body:"Manual external review: approved."}
  ]')
  _scan_rc=0
  crc_phase4b_needs_timeout_timeline "$P4B_REVIEWS" \
    '["nathanpayne-claude","nathanpayne-cursor"]' nathanjohnpayne nathanpayne-codex "$P4B_HEAD" \
    || _scan_rc=$?
  [ "$_scan_rc" = 1 ] \
    && pass "#1085 Phase 4b binding: a superseded timeout approval imposes no live-timeline dependency" \
    || fail "#1085 Phase 4b binding: stale timeout approval requested a timeline read (rc=$_scan_rc)"

  P4B_REVIEWS=$(jq -cn --arg timeout "$P4B_TIMEOUT_BODY" --arg head "$P4B_HEAD" '[
    {id:11,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:10:00Z",commit_id:$head,body:$timeout}
  ]')
  _scan_rc=0
  crc_phase4b_needs_timeout_timeline "$P4B_REVIEWS" \
    '["nathanpayne-claude"]' nathanjohnpayne nathanpayne-codex "$P4B_HEAD" \
    || _scan_rc=$?
  [ "$_scan_rc" = 0 ] \
    && pass "#1085 Phase 4b binding: a strict current-head timeout approval requests the live timeline" \
    || fail "#1085 Phase 4b binding: valid timeout approval skipped the timeline read (rc=$_scan_rc)"

  P4B_REVIEWS=$(jq -cn --arg timeout "$P4B_TIMEOUT_BODY" --arg head "$P4B_HEAD" '[
    {id:111,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:10:10Z",commit_id:$head,body:$timeout},
    {id:112,user:{login:"nathanpayne-cursor"},state:"APPROVED",submitted_at:"2026-09-01T00:10:20Z",commit_id:$head,body:"Manual external review: approved."}
  ]')
  _scan_rc=0
  crc_phase4b_needs_timeout_timeline "$P4B_REVIEWS" \
    '["nathanpayne-claude","nathanpayne-cursor"]' nathanjohnpayne nathanpayne-codex "$P4B_HEAD" \
    || _scan_rc=$?
  _picked="$(crc_select_phase4b_approver "$P4B_REVIEWS" \
    '["nathanpayne-claude","nathanpayne-cursor"]' nathanjohnpayne nathanpayne-codex \
    "$P4B_HEAD" '{"state":"unreadable"}')"
  [ "$_scan_rc" = 1 ] \
    && [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 112 ] \
    && pass "#1085 Phase 4b binding: an independent manual approval avoids the timeout candidate's timeline dependency" \
    || fail "#1085 Phase 4b binding: valid timeout history masked an independent manual approval (scan_rc=$_scan_rc picked=$_picked)"

  P4B_WRONG_HEAD_BODY="$(printf '%s\n\n**Automated Phase 4b review**' \
    "$(codex_phase4b_clearance_marker_body bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb timeout 4101)")"
  P4B_MALFORMED_BODY="<!-- mergepath-phase-4b-clearance:v1 head=$P4B_HEAD codex_evidence=timeout timeout_trigger_comment_id=none -->

**Automated Phase 4b review**"
  for _body in "$P4B_WRONG_HEAD_BODY" "$P4B_MALFORMED_BODY"; do
    P4B_REVIEWS=$(jq -cn --arg body "$_body" --arg head "$P4B_HEAD" '[
      {id:12,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:11:00Z",commit_id:$head,body:$body},
      {id:13,user:{login:"nathanpayne-cursor"},state:"APPROVED",submitted_at:"2026-09-01T00:12:00Z",commit_id:$head,body:"Manual external review: approved."}
    ]')
    _scan_rc=0
    crc_phase4b_needs_timeout_timeline "$P4B_REVIEWS" \
      '["nathanpayne-claude","nathanpayne-cursor"]' nathanjohnpayne nathanpayne-codex "$P4B_HEAD" \
      || _scan_rc=$?
    [ "$_scan_rc" = 1 ] \
      && pass "#1085 Phase 4b binding: malformed or wrong-head timeout-like history cannot impose a timeline read" \
      || fail "#1085 Phase 4b binding: invalid timeout-like history requested a timeline read (rc=$_scan_rc)"
  done

  P4B_REVIEWS=$(jq -cn --arg head "$P4B_HEAD" '[
    {id:14,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:13:00Z",commit_id:$head,body:"Manual external review: approved."}
  ]')
  unset -f codex_phase4b_clearance_marker_parse
  _picked="$(p4b_pick '{"state":"unreadable"}')"
  [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 14 ] \
    && pass "#1085 Phase 4b binding: manual approval remains usable during marker-parser propagation skew" \
    || fail "#1085 Phase 4b binding: manual approval gained an automated-marker dependency: $_picked"

  P4B_REVIEWERS='["nathanpayne-claude","nathanpayne-cursor"]'
  P4B_REVIEWS=$(jq -cn --arg auto "$P4B_SIGNAL_BODY" --arg head "$P4B_HEAD" '[
    {id:15,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:14:00Z",commit_id:$head,body:$auto},
    {id:16,user:{login:"nathanpayne-cursor"},state:"APPROVED",submitted_at:"2026-09-01T00:15:00Z",commit_id:$head,body:"Manual external review: approved."}
  ]')
  _picked="$(p4b_pick '{"state":"unreadable"}')"
  [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 16 ] \
    && pass "#1085 Phase 4b binding: unreadable automated history cannot mask an independent manual approval" \
    || fail "#1085 Phase 4b binding: propagation skew masked the manual approval: $_picked"

  P4B_REVIEWS=$(jq -cn --arg head "$P4B_HEAD" '[
    {id:18,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:14:30Z",commit_id:$head,body:"**Automated Phase 4b review**\n\nLegacy body."},
    {id:19,user:{login:"nathanpayne-cursor"},state:"APPROVED",submitted_at:"2026-09-01T00:15:30Z",commit_id:$head,body:"Manual external review: approved."}
  ]')
  _picked="$(p4b_pick '{"state":"unreadable"}')"
  [ "$(printf '%s' "$_picked" | jq -r '.id // empty')" = 19 ] \
    && pass "#1085 Phase 4b binding: a legacy unmarked automated review cannot mask a manual approval during propagation skew" \
    || fail "#1085 Phase 4b binding: legacy unmarked history masked the manual approval: $_picked"

  P4B_REVIEWERS='["nathanpayne-claude"]'
  P4B_REVIEWS=$(jq -cn --arg auto "$P4B_SIGNAL_BODY" --arg head "$P4B_HEAD" '[
    {id:17,user:{login:"nathanpayne-claude"},state:"APPROVED",submitted_at:"2026-09-01T00:16:00Z",commit_id:$head,body:$auto}
  ]')
  _pick_rc=0
  _picked="$(p4b_pick '{"state":"unreadable"}')" || _pick_rc=$?
  [ "$_pick_rc" = 2 ] \
    && pass "#1085 Phase 4b binding: automated-only propagation skew still fails closed as infrastructure" \
    || fail "#1085 Phase 4b binding: unreadable automated-only approval did not fail closed (rc=$_pick_rc; $_picked)"
  . "$ROOT/scripts/lib/codex-failure-markers.sh"
  unset -f p4b_pick
fi

echo ""
echo "test_codex_review_check_verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
