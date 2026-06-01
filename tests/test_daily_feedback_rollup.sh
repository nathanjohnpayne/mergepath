#!/usr/bin/env bash
# tests/test_daily_feedback_rollup.sh
#
# Unit tests for scripts/lib/daily-feedback-rollup-helpers.sh — the
# pure-function helpers that drive classification + routing in
# scripts/daily-feedback-rollup.sh (mergepath#299).
#
# The end-to-end integration (gh shim → script → issue creation) is
# not in scope here; this test layer asserts only the deterministic
# helper functions so the spec's per-case classification matrix is
# regression-safe. Integration coverage lives in
# scripts/ci/check_daily_feedback_rollup, which runs an actual
# `--dry-run` invocation against a shimmed gh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT/scripts/lib/daily-feedback-rollup-helpers.sh"

[ -f "$HELPERS" ] || { echo "missing $HELPERS" >&2; exit 1; }

# shellcheck disable=SC1090
. "$HELPERS"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------
# classify_severity — per-case routing from spec § Two-track rollup
# ---------------------------------------------------------------------

assert_severity() {
  local body="$1" expected="$2" label="$3"
  local got
  got=$(classify_severity "$body")
  if [ "$got" = "$expected" ]; then
    pass "classify_severity: $label → $expected"
  else
    fail "classify_severity: $label → expected=$expected got=$got"
  fi
}

# Codex badges
assert_severity '**![P0 Badge]** Some critical finding' "P0"     "Codex P0 inline"
assert_severity '**![P1 Badge]** Some major finding'    "P1"     "Codex P1 inline"
assert_severity '**![P2 Badge]** Some non-blocking'     "P2"     "Codex P2 inline"
assert_severity '**![P3 Badge]** Nit / polish item'     "P3"     "Codex P3 inline"

# CodeRabbit badges
assert_severity '_⚠️ Potential issue_ | _🟠 Major_'      "Major"  "CodeRabbit Major"
assert_severity '_🟠 Major_ | _Potential issue_'         "Major"  "CodeRabbit Major (alt order)"
assert_severity 'Just a ⚠️ thing — Potential issue'      "Major"  "CodeRabbit ⚠️ alone"
assert_severity '_🧹 Nitpick (assertive)_'               "Nitpick" "CodeRabbit Nitpick"
assert_severity '_🔵 Trivial issue_ | _Minor_'           "Trivial" "CodeRabbit Trivial wins over Minor"
assert_severity 'Outside diff range comment'             "Trivial" "Outside diff range → Trivial"

# Unknown bodies surface as Unknown (the caller routes to substantive)
assert_severity 'Some opaque finding without a badge'    "Unknown" "no badge → Unknown"
assert_severity ''                                        "Unknown" "empty body → Unknown"

# Severity-anchor: a severity word DEEP in body (past the 600-char
# anchor) must NOT match. Build a body with 700 chars of padding then
# the word "Major" at the end — should still classify as Unknown.
padding=$(printf '%.0sX' $(seq 1 700))
assert_severity "${padding} Major"                       "Unknown" "anchored: Major past char 600 ignored"

# ---------------------------------------------------------------------
# severity_to_track — spec § Two-track rollup routing table
# ---------------------------------------------------------------------

assert_track() {
  local sev="$1" expected="$2"
  local got
  got=$(severity_to_track "$sev")
  if [ "$got" = "$expected" ]; then
    pass "severity_to_track: $sev → $expected"
  else
    fail "severity_to_track: $sev → expected=$expected got=$got"
  fi
}

assert_track "P0"      "substantive"
assert_track "P1"      "substantive"
assert_track "P2"      "substantive"
assert_track "P3"      "polish"
assert_track "Major"   "substantive"
assert_track "Minor"   "substantive"
assert_track "Nitpick" "polish"
assert_track "Trivial" "polish"
assert_track "Unknown" "substantive"
assert_track ""        "substantive"

# ---------------------------------------------------------------------
# item_id_for — stable + 12 chars + deterministic
# ---------------------------------------------------------------------

id1=$(item_id_for "owner/repo#123:PRT_kwAB")
id2=$(item_id_for "owner/repo#123:PRT_kwAB")
id3=$(item_id_for "owner/repo#124:PRT_kwAB")

if [ ${#id1} -eq 12 ]; then
  pass "item_id_for: produces 12-char ID"
else
  fail "item_id_for: expected 12 chars, got ${#id1} ($id1)"
fi

if [ "$id1" = "$id2" ]; then
  pass "item_id_for: same input → same ID (idempotent)"
else
  fail "item_id_for: same input gave different IDs ($id1 vs $id2)"
fi

if [ "$id1" != "$id3" ]; then
  pass "item_id_for: different inputs → different IDs"
else
  fail "item_id_for: different inputs collided ($id1 == $id3)"
fi

# ---------------------------------------------------------------------
# extract_tag_class — canonical regex + tolerant whitespace
# ---------------------------------------------------------------------

assert_tag() {
  local body="$1" expected="$2" label="$3"
  local got
  got=$(extract_tag_class "$body")
  if [ "$got" = "$expected" ]; then
    pass "extract_tag_class: $label"
  else
    fail "extract_tag_class: $label → expected=[$expected] got=[$got]"
  fi
}

assert_tag '[mergepath-resolve: deferred-to-followup] noted'   "deferred-to-followup" "canonical form"
assert_tag '[mergepath-resolve:canonical-coverage] addressed'  "canonical-coverage"   "no space after colon"
assert_tag '[mergepath-resolve:  addressed-elsewhere ] x'      "addressed-elsewhere"  "extra leading space"
assert_tag 'no tag here'                                        ""                     "no tag → empty"
assert_tag '[mergepath-resolve: deferred-to-followup] first
also has [mergepath-resolve: rebuttal-recorded]'                "deferred-to-followup" "first tag wins"
assert_tag '[mergepath-resolve: deferred-to-followup-EXTRA]'   ""                     "malformed (uppercase) → no match"

# ---------------------------------------------------------------------
# tag_class_action — the surface/skip routing matrix from spec
# ---------------------------------------------------------------------

assert_action() {
  local class="$1" expected="$2"
  local got
  got=$(tag_class_action "$class")
  if [ "$got" = "$expected" ]; then
    pass "tag_class_action: $class → $expected"
  else
    fail "tag_class_action: $class → expected=$expected got=$got"
  fi
}

assert_action "addressed-elsewhere"   "skip"
assert_action "canonical-coverage"    "skip"
assert_action "rebuttal-recorded"     "skip"
assert_action "nitpick-noted"         "surface"
assert_action "deferred-to-followup"  "surface"
assert_action "future-unknown-class"  "surface"   # spec: err on surface
assert_action ""                       ""          # caller falls through to heuristics

# ---------------------------------------------------------------------
# is_agent_author — colon-list membership, Bash 3.2 safe
# ---------------------------------------------------------------------

# Default AGENT_AUTHORS from the helper file.
if is_agent_author "nathanjohnpayne"; then
  pass "is_agent_author: nathanjohnpayne is agent"
else
  fail "is_agent_author: nathanjohnpayne should be agent"
fi

if is_agent_author "nathanpayne-claude"; then
  pass "is_agent_author: nathanpayne-claude is agent"
else
  fail "is_agent_author: nathanpayne-claude should be agent"
fi

if ! is_agent_author "coderabbitai[bot]"; then
  pass "is_agent_author: coderabbitai[bot] is not agent"
else
  fail "is_agent_author: coderabbitai[bot] should NOT be agent"
fi

if ! is_agent_author "random-external-user"; then
  pass "is_agent_author: random-external-user is not agent"
else
  fail "is_agent_author: random-external-user should NOT be agent"
fi

# Override AGENT_AUTHORS at runtime works (tests Bash 3.2-safe parsing)
(
  AGENT_AUTHORS="aliceagent:bobagent"
  # Re-source NOT needed because is_agent_author reads $AGENT_AUTHORS at
  # call time, not module load.
  if is_agent_author "aliceagent" && ! is_agent_author "nathanpayne-claude"; then
    pass "is_agent_author: AGENT_AUTHORS override applied at call time"
  else
    fail "is_agent_author: AGENT_AUTHORS override did not apply"
  fi
)

# ---------------------------------------------------------------------
# body_excerpt — single-line, length-capped
# ---------------------------------------------------------------------

# Newlines/tabs collapsed to spaces.
got=$(body_excerpt $'line1\nline2\tx')
expected="line1 line2 x"
if [ "$got" = "$expected" ]; then
  pass "body_excerpt: collapses newlines/tabs to spaces"
else
  fail "body_excerpt: expected=[$expected] got=[$got]"
fi

# Capped at default 200 chars.
long=$(printf '%.0sA' $(seq 1 500))
got=$(body_excerpt "$long")
if [ ${#got} -eq 200 ]; then
  pass "body_excerpt: default cap is 200 chars"
else
  fail "body_excerpt: expected 200 chars, got ${#got}"
fi

# Custom cap honored.
got=$(body_excerpt "$long" 50)
if [ ${#got} -eq 50 ]; then
  pass "body_excerpt: custom cap honored"
else
  fail "body_excerpt: expected 50 chars, got ${#got}"
fi

# ---------------------------------------------------------------------
# parse_triaged_ids_from_body — mergepath#304 dedupe signal matrix
# ---------------------------------------------------------------------
#
# Each test asserts the helper extracts exactly the expected set of
# triaged mp-ids from a sample rollup body. Order doesn't matter
# (helper de-dupes via awk), so we sort-compare.

assert_triaged_ids() {
  local body="$1" expected_sorted="$2" label="$3"
  local got
  got=$(parse_triaged_ids_from_body "$body" | sort | tr '\n' ' ' | sed 's/ $//')
  local expected
  expected=$(printf '%s' "$expected_sorted" | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$expected" ]; then
    pass "parse_triaged_ids_from_body: $label"
  else
    fail "parse_triaged_ids_from_body: $label → expected=[$expected] got=[$got]"
  fi
}

# 1) Plain `[x]` checkbox triages
body1='- [x] fix landed for this item <!-- mp-id:aaaa11112222 -->
- [ ] still open <!-- mp-id:bbbb11112222 -->'
assert_triaged_ids "$body1" "aaaa11112222" "[x] checkbox marks triaged; [ ] does not"

# 2) Capital `[X]` also counts
body2='- [X] handled by upstream <!-- mp-id:cccc11112222 -->'
assert_triaged_ids "$body2" "cccc11112222" "[X] uppercase checkbox marks triaged"

# 3) `[~]` marks N/A
body3='- [~] not relevant to this codepath <!-- mp-id:dddd11112222 -->
- [ ] still open <!-- mp-id:eeee11112222 -->'
assert_triaged_ids "$body3" "dddd11112222" "[~] checkbox marks triaged"

# 4) `[-]` also marks N/A (alias)
body4='- [-] obsolete <!-- mp-id:ffff11112222 -->'
assert_triaged_ids "$body4" "ffff11112222" "[-] checkbox marks triaged"

# 5) Strikethrough wraps a `[ ]` bullet
body5='~~- [ ] superseded item ~~ <!-- mp-id:1111aaaabbbb -->
- [ ] not striked <!-- mp-id:2222aaaabbbb -->'
assert_triaged_ids "$body5" "1111aaaabbbb" "~~strikethrough~~ marks triaged even with empty [ ]"

# 6) `#N` follow-up reference on same line as the item
body6='- [ ] punted to #456 for later <!-- mp-id:3333aaaabbbb -->
- [ ] no link here <!-- mp-id:4444aaaabbbb -->'
assert_triaged_ids "$body6" "3333aaaabbbb" "follow-up #N reference marks triaged"

# 7) `#N` follow-up at end of line (different spacing/punctuation)
body7='- [ ] addressed in (#789) <!-- mp-id:5555aaaabbbb -->'
assert_triaged_ids "$body7" "5555aaaabbbb" "follow-up #N inside parens marks triaged"

# 8) URL anchor like `pull/999#discussion_r1` must NOT count as `#N`
body8='- [ ] [scripts/x.sh:10](https://github.com/owner/repo/pull/999#discussion_r1) — `coderabbitai[bot]` Nitpick: "polish" <!-- mp-id:6666aaaabbbb -->'
assert_triaged_ids "$body8" "" "URL anchor #discussion_rN does NOT mark triaged"

# 9) Empty + lines-without-marker emit nothing
body9='Just some intro text.
- [x] no mp-id marker on this line
- [ ] open item, no marker either
## ## ## heading'
assert_triaged_ids "$body9" "" "lines without mp-id marker produce nothing"

# 10) Multiple triaged signals on one line — single ID emitted (dedupe)
body10='- [x] also has #123 <!-- mp-id:7777aaaabbbb -->'
assert_triaged_ids "$body10" "7777aaaabbbb" "multiple signals on one line → single mp-id"

# 11) Same mp-id appearing on two lines (both triaged) → de-duped output
body11='- [x] first <!-- mp-id:8888aaaabbbb -->
- [x] dup <!-- mp-id:8888aaaabbbb -->'
assert_triaged_ids "$body11" "8888aaaabbbb" "duplicate mp-ids → de-duped output"

# 12) Realistic rollup-body fragment with mixed states
body12='## owner/repo#42 (merged 2026-05-14T12:00Z, fix: foo)
- [x] [scripts/a.sh:10](https://github.com/owner/repo/pull/42#discussion_r1) — `coderabbitai[bot]` Major: "issue A" <!-- mp-id:aaaa00000001 -->
- [ ] [scripts/b.sh:20](https://github.com/owner/repo/pull/42#discussion_r2) — `coderabbitai[bot]` Nitpick: "issue B" <!-- mp-id:aaaa00000002 -->
- [~] [scripts/c.sh:30](https://github.com/owner/repo/pull/42#discussion_r3) — `chatgpt-codex-connector[bot]` P2: "issue C" <!-- mp-id:aaaa00000003 -->
~~- [ ] [scripts/d.sh:40](https://github.com/owner/repo/pull/42#discussion_r4) — `coderabbitai[bot]` Minor: "issue D" ~~ <!-- mp-id:aaaa00000004 -->
- [ ] [scripts/e.sh:50](https://github.com/owner/repo/pull/42#discussion_r5) — `coderabbitai[bot]` Major: "issue E, filed #999" <!-- mp-id:aaaa00000005 -->'
# Expected triaged: 1 ([x]), 3 ([~]), 4 (~~~), 5 (#999) — NOT 2 (open, no signal)
assert_triaged_ids "$body12" "aaaa00000001 aaaa00000003 aaaa00000004 aaaa00000005" "realistic mixed-state rollup fragment"

# ---------------------------------------------------------------------
# parse_all_ids_from_body — closed-host fallback
# ---------------------------------------------------------------------

assert_all_ids() {
  local body="$1" expected_sorted="$2" label="$3"
  local got
  got=$(parse_all_ids_from_body "$body" | sort | tr '\n' ' ' | sed 's/ $//')
  local expected
  expected=$(printf '%s' "$expected_sorted" | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$expected" ]; then
    pass "parse_all_ids_from_body: $label"
  else
    fail "parse_all_ids_from_body: $label → expected=[$expected] got=[$got]"
  fi
}

# 13) parse_all_ids ignores triage state — emits every mp-id
body_all1='- [ ] open <!-- mp-id:cccccc111111 -->
- [x] done <!-- mp-id:cccccc222222 -->
- [~] na  <!-- mp-id:cccccc333333 -->'
assert_all_ids "$body_all1" "cccccc111111 cccccc222222 cccccc333333" \
  "closed-host: every mp-id surfaces regardless of state"

# 14) parse_all_ids dedupes
body_all2='- [ ] one <!-- mp-id:ddd444aaaaaa -->
- [x] same id <!-- mp-id:ddd444aaaaaa -->'
assert_all_ids "$body_all2" "ddd444aaaaaa" "closed-host: duplicate mp-ids de-duped"

# 15) parse_all_ids on a body with no markers → empty
assert_all_ids "no markers here at all" "" "closed-host: no markers → empty"

# ---------------------------------------------------------------------
# render_rollup_body body-size bound (#400). Extract the real function
# from the script (reads actual source — no drift) and exercise it with
# a large synthetic NDJSON. Assert the rendered body stays under
# GitHub's 65536-byte cap, the visible checklist is capped, the "+N more"
# footer fires, P0s survive (severity-major), and the line format still
# matches unchecked_count_on()'s `- [ ]` grep.
# ---------------------------------------------------------------------
SCRIPT="$ROOT/scripts/daily-feedback-rollup.sh"
eval "$(sed -n '/^render_rollup_body()/,/^}/p' "$SCRIPT")"

DATE_STAMP="2026-06-01"; ROLLUP_MAX_VISIBLE=60
SINCE="2026-05-31T00:00:00Z"; UNTIL="2026-06-01T00:00:00Z"; pr_count=4
COUNT_FIX=0; COUNT_REPLY=0; COUNT_STALE=0; COUNT_TAGGED_SKIP=0
COUNT_TAGGED_SURFACE=0; COUNT_DEFERRED_UNTAGGED=200; COUNT_DEDUP_SKIPPED=0
DEDUPE_WINDOW_DAYS=14; DEDUP_CUTOFF="2026-05-18"

BIG_RB="$(mktemp "${TMPDIR:-/tmp}/rb-big-XXXXXX.ndjson")"
RB_OUT="$(mktemp "${TMPDIR:-/tmp}/rb-out-XXXXXX.md")"
rbi=0
while [ "$rbi" -lt 200 ]; do
  rbsev=$(printf 'P0 P1 P2 Major Minor' | tr ' ' '\n' | sed -n "$(((rbi % 5) + 1))p")
  jq -nc --arg repo "owner/repo$((rbi % 4))" --arg pr "$(( (rbi % 4) + 100 ))" \
    --arg tp "scripts/file$rbi.sh" --arg tl "$rbi" --arg sev "$rbsev" \
    --arg id "$(printf 'abc%09x' "$rbi")" \
    '{repo:$repo, pr_number:$pr, pr_title:("PR "+$pr), pr_merged_at:"2026-05-31T12:00:00Z",
      thread_path:$tp, thread_line:$tl,
      thread_url:("https://github.com/"+$repo+"/pull/"+$pr+"#discussion_r"+$tl),
      author:"chatgpt-codex-connector[bot]", severity:$sev, tag_note:"deferred-untagged",
      body_excerpt:"A representative ~150-char excerpt mirroring real bot feedback so the rendered checklist line reflects realistic per-finding size in the body ok done now yes",
      item_id:$id}' >> "$BIG_RB"
  rbi=$((rbi + 1))
done

render_rollup_body "$BIG_RB" "substantive" > "$RB_OUT"
RB_BYTES=$(wc -c < "$RB_OUT" | tr -d ' ')
RB_VISIBLE=$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]' "$RB_OUT" || true)

if [ "$RB_BYTES" -le 65536 ]; then
  pass "render_rollup_body: 200-finding body within 65536-byte cap ($RB_BYTES B)"
else
  fail "render_rollup_body: body $RB_BYTES B exceeds 65536 — bound regression"
fi
if [ "$RB_VISIBLE" -le 60 ] && [ "$RB_VISIBLE" -gt 0 ]; then
  pass "render_rollup_body: visible checklist capped ($RB_VISIBLE shown; unchecked_count_on regex matches)"
else
  fail "render_rollup_body: visible count $RB_VISIBLE (expected 1..60)"
fi
if grep -q 'more finding(s) not shown' "$RB_OUT"; then
  pass "render_rollup_body: '+N more' footer present on truncation"
else
  fail "render_rollup_body: truncation footer missing"
fi
if grep -q ' P0 \[' "$RB_OUT"; then
  pass "render_rollup_body: P0 findings survive into the shown set (severity-major)"
else
  fail "render_rollup_body: no P0 in shown set — severity ordering broken"
fi
rm -f "$BIG_RB" "$RB_OUT"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

echo
if [ "$FAIL" -gt 0 ]; then
  echo "test_daily_feedback_rollup: $FAIL FAIL / $PASS PASS" >&2
  exit 1
fi
echo "test_daily_feedback_rollup: PASS ($PASS tests)"
