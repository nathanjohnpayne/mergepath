#!/usr/bin/env bash
# tests/test_audit_rebuttal_clearances.sh
#
# Offline fixture tests for scripts/audit-rebuttal-clearances.sh --analyze-only,
# the #2852 slice 1 baseline (#2943): which required-tier findings were
# rebutted and resolved with no later re-read by the same reviewer.
#
# The fetch phase is a thin GraphQL read loop exercised against the live API,
# not here. These cases replay synthetic raw records (the shape fetch_pr
# writes) and pin the classification: the shared tier readers, the three
# kinds of rebuttal evidence, the resolver's reply polarity (loaded from
# scripts/resolve-pr-threads.sh), the Codex request-then-response re-read,
# the provisional CodeRabbit re-read, the two rebuttal datings, and the
# not-measured accounting that keeps an unreadable PR from reading as zero.
#
# Fixture PRs (all in o/r, Codex = chatgpt-codex-connector[bot],
# CodeRabbit = coderabbitai[bot], policy = the repository's own, p0/p1
# required):
#   101 Codex P1, tag rebuttal, resolved, no request          → no-reread
#   102 Codex P1, reply rebuttal, request, clean Codex review → reread
#   103 Codex P1, reply rebuttal, Codex review but no request → no-reread
#   104 Codex P1, thumbs-down, request, no Codex response     → no-reread
#   105 Codex P2, rebutted, resolved                          → not a required finding
#   106 Codex P1, "Fixed in ..." reply, resolved              → not-rebutted
#   107 Codex P1, reply rebuttal, thread unresolved           → rebutted-unresolved
#   108 CodeRabbit p1, "Disagree:" reply, CodeRabbit replies  → reread
#   109 CodeRabbit p1, reply rebuttal, no CodeRabbit activity → no-reread
#   110 Codex P1, "Rebuttal: no" (under the 30-char floor)    → not-rebutted
#   111 Codex P1, rebuttal reply then a later "Fixed" reply   → not-rebutted
#   112 Codex P1, rebuttal, request, Codex review with a new P1 → reread-reraised
#   113 raw record carries an error                           → not measured
#   114 listed but has no raw record                          → not measured
#   115 Codex P1, reply rebuttal, request, affirmative verdict, then a tag
#       → reread by substantive dating, no-reread by latest dating
#   116 registered reviewer P1                                → out of scope
#   117 Codex P1, reply rebuttal, then a Codex reply in the thread
#       → reread (the reviewer's own in-thread reply is a re-read)
#   118 Codex P1, tag rebuttal, no request, owner TIEBREAK marker naming it
#       → owner-marker (cleared by the owner route, not matching)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-rebuttal-clearances.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (audit-rebuttal-clearances.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-rebuttal-clearances-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

CODEX="chatgpt-codex-connector[bot]"
CR="coderabbitai[bot]"
AUTHOR="nathanjohnpayne"
AGENT="nathanpayne-claude"
P1='**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Guard the empty list**'
P2='**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Name the variable**'
CR_MAJOR=$'_⚠️ Potential issue_ | _🟠 Major_\n\n**Guard the empty list.**'
REBUT='Rebuttal: the caller validates the list before this point, so it is never empty here.'
TAG='[mergepath-resolve: rebuttal-recorded] substantive agent rebuttal after the latest re-raise.'

# c <id> <login> <created_at> <body> [review_id] — one comment record.
c() {
  local type=User
  case "$2" in *"[bot]") type=Bot ;; esac
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$type" --arg at "$3" --arg b "$4" --argjson rv "${5:-null}" \
    '{id: $id, login: $l, type: $t, created_at: $at, edited_at: null, review_id: $rv, body: $b}'
}
# t <thread-id> <resolved> <downs-json> <comment-json>... — one thread record.
t() {
  local id=$1 resolved=$2 downs=$3
  shift 3
  printf '%s\n' "$@" | jq -sc --arg id "$id" --argjson r "$resolved" --argjson d "$downs" \
    '{id: $id, is_resolved: $r, path: "scripts/x.sh", root_downs: $d, root_downs_truncated: false, comments: .}'
}
# rv <id> <login> <submitted_at> <body> — one review record.
rv() {
  local type=User
  case "$2" in *"[bot]") type=Bot ;; esac
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$type" --arg at "$3" --arg b "$4" \
    '{id: $id, login: $l, type: $t, submitted_at: $at, body: $b}'
}
# pr <n> <threads-json> <reviews-json> <comments-json> — writes the raw record.
pr() {
  jq -nc --argjson n "$1" --argjson th "$2" --argjson rv "$3" --argjson ic "$4" \
    '{pr: $n, merged_at: "2026-10-20T12:00:00Z", threads: $th, reviews: $rv, comments: $ic}' >"$RAW/pr-$1.json"
}
arr() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -sc '.'; fi; }
req() { c "$1" "$AUTHOR" "$2" '@codex review'; }

OUT="$WORKDIR/out"
RAW="$OUT/raw"
mkdir -p "$RAW"
jq -nc '{repo: "o/r", since: "2026-10-11T00:00:00Z", until: "2026-11-10T00:00:00Z"}' >"$RAW/window.json"
: >"$RAW/prs.jsonl"
for n in $(seq 101 118); do
  jq -nc --argjson n "$n" '{pr: $n, merged_at: "2026-10-20T12:00:00Z", url: "https://github.com/o/r/pull/\($n)"}' >>"$RAW/prs.jsonl"
done
printf 'search\t1\npr 101\t2\n' >"$RAW/api.tsv"

pr 101 "$(arr "$(t T101 true '[]' "$(c 1011 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9101)" "$(c 1012 "$AGENT" 2026-10-20T02:00:00Z "$TAG")")")" \
  "$(arr "$(rv 9101 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'
pr 102 "$(arr "$(t T102 true '[]' "$(c 1021 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9102)" "$(c 1022 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")")")" \
  "$(arr "$(rv 9102 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')" "$(rv 9122 "$CODEX" 2026-10-20T04:00:00Z 'Codex review: no new findings')")" \
  "$(arr "$(req 1023 2026-10-20T03:00:00Z)")"
pr 103 "$(arr "$(t T103 true '[]' "$(c 1031 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9103)" "$(c 1032 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")")")" \
  "$(arr "$(rv 9103 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')" "$(rv 9133 "$CODEX" 2026-10-20T04:00:00Z 'Codex review on a later push')")" \
  "$(arr "$(req 1033 2026-10-20T00:30:00Z)")"
pr 104 "$(arr "$(t T104 true '[{"login":"nathanpayne-claude","created_at":"2026-10-20T02:00:00Z"}]' "$(c 1041 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9104)")")" \
  "$(arr "$(rv 9104 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" \
  "$(arr "$(req 1043 2026-10-20T03:00:00Z)")"
pr 105 "$(arr "$(t T105 true '[]' "$(c 1051 "$CODEX" 2026-10-20T01:00:00Z "$P2" 9105)" "$(c 1052 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")")")" \
  "$(arr "$(rv 9105 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'
pr 106 "$(arr "$(t T106 true '[]' "$(c 1061 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9106)" "$(c 1062 "$AGENT" 2026-10-20T02:00:00Z 'Fixed in abc1234: the guard now returns early on an empty list.')")")" \
  "$(arr "$(rv 9106 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'
pr 107 "$(arr "$(t T107 false '[]' "$(c 1071 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9107)" "$(c 1072 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")")")" \
  "$(arr "$(rv 9107 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'
pr 108 "$(arr "$(t T108 true '[]' "$(c 1081 "$CR" 2026-10-20T01:00:00Z "$CR_MAJOR" 9108)" \
    "$(c 1082 "$AGENT" 2026-10-20T02:00:00Z 'Disagree: this branch cannot run on a consumer checkout at all.')" \
    "$(c 1083 "$CR" 2026-10-20T02:05:00Z 'Thanks for the explanation; that resolves it.' 9188)")")" \
  "$(arr "$(rv 9108 "$CR" 2026-10-20T01:00:00Z 'CodeRabbit review')" "$(rv 9188 "$CR" 2026-10-20T02:05:00Z '')")" '[]'
pr 109 "$(arr "$(t T109 true '[]' "$(c 1091 "$CR" 2026-10-20T01:00:00Z "$CR_MAJOR" 9109)" "$(c 1092 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")")")" \
  "$(arr "$(rv 9109 "$CR" 2026-10-20T01:00:00Z 'CodeRabbit review')")" '[]'
pr 110 "$(arr "$(t T110 true '[]' "$(c 1101 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9110)" "$(c 1102 "$AGENT" 2026-10-20T02:00:00Z 'Rebuttal: no')")")" \
  "$(arr "$(rv 9110 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'
pr 111 "$(arr "$(t T111 true '[]' "$(c 1111 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9111)" "$(c 1112 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")" \
    "$(c 1113 "$AGENT" 2026-10-20T03:00:00Z 'Fixed in def5678 after all: the guard is now explicit.')")")" \
  "$(arr "$(rv 9111 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'
pr 112 "$(arr "$(t T112 true '[]' "$(c 1121 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9112)" "$(c 1122 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")")" \
    "$(t T112B false '[]' "$(c 1124 "$CODEX" 2026-10-20T04:00:00Z "$P1" 9142)")")" \
  "$(arr "$(rv 9112 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')" "$(rv 9142 "$CODEX" 2026-10-20T04:00:00Z 'Codex review')")" \
  "$(arr "$(req 1123 2026-10-20T03:00:00Z)")"
jq -nc '{pr: 113, error: "the PR read failed"}' >"$RAW/pr-113.json"
# 114 deliberately has no raw record.
pr 115 "$(arr "$(t T115 true '[]' "$(c 1151 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9115)" "$(c 1152 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")" \
    "$(c 1155 "$AGENT" 2026-10-20T05:00:00Z "$TAG")")")" \
  "$(arr "$(rv 9115 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" \
  "$(arr "$(req 1153 2026-10-20T03:00:00Z)" "$(c 1154 "$CODEX" 2026-10-20T04:00:00Z $'Codex Review: Didn\'t find any major issues. Nice work.')")"
pr 116 "$(arr "$(t T116 true '[]' "$(c 1161 nathanpayne-codex 2026-10-20T01:00:00Z '**P1 Guard the input**' 9116)")")" \
  "$(arr "$(rv 9116 nathanpayne-codex 2026-10-20T01:00:00Z 'Phase 4b review')")" '[]'
pr 117 "$(arr "$(t T117 true '[]' "$(c 1171 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9117)" "$(c 1172 "$AGENT" 2026-10-20T02:00:00Z "$REBUT")" \
    "$(c 1173 "$CODEX" 2026-10-20T03:00:00Z 'The caller does not validate on the retry path; this still applies.' 9177)")")" \
  "$(arr "$(rv 9117 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" '[]'

pr 118 "$(arr "$(t T118 true '[]' "$(c 1181 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9118)" "$(c 1182 "$AGENT" 2026-10-20T02:00:00Z "$TAG")")")" \
  "$(arr "$(rv 9118 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" \
  "$(arr "$(c 1183 "$AUTHOR" 2026-10-20T03:00:00Z "TIEBREAK_REBUTTAL_ACCEPTED=https://github.com/o/r/pull/118@$(printf 'a%.0s' $(seq 40))#1181")")"

rc=0
bash "$SCRIPT" --analyze-only --out-dir "$OUT" --policy "$ROOT/.github/review-policy.yml" >/dev/null 2>"$WORKDIR/err.log" || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "--analyze-only exits 4 when a listed PR could not be measured"
else
  fail "--analyze-only exited $rc, expected 4; stderr:"; cat "$WORKDIR/err.log" >&2
fi
grep -q 'PR #113 not measured: the PR read failed' "$WORKDIR/err.log" && grep -q 'PR #114 not measured: no raw record' "$WORKDIR/err.log" \
  && pass "each unmeasured PR is named on stderr with its reason" || fail "unmeasured PRs were not reported loudly"

S="$OUT/summary.json"
F="$OUT/findings.jsonl"
[ -s "$S" ] && [ -s "$OUT/summary.md" ] || { fail "summary.json / summary.md missing"; echo "$PASS passed, $FAIL failed"; exit 1; }

status_of() { jq -r --argjson f "$1" 'select(.finding == $f) | .status' "$F"; }
expect_status() { # <finding> <status> <why>
  local got
  got=$(status_of "$1")
  [ "$got" = "$2" ] && pass "$3 ($1: $2)" || fail "$3: finding $1 has status '$got', expected '$2'"
}
expect_status 1011 no-reread "a tag rebuttal with no later request is not re-read"
expect_status 1021 reread "a request after the rebuttal and a later Codex review are a re-read"
expect_status 1031 no-reread "a Codex review with no request after the rebuttal is not a re-read"
expect_status 1041 no-reread "a request after a thumbs-down rebuttal with no Codex response is not a re-read"
expect_status 1061 not-rebutted "a Fixed reply is not a rebuttal"
expect_status 1071 rebutted-unresolved "an unresolved rebutted thread is reported apart"
expect_status 1081 reread "a CodeRabbit reply in the thread after the rebuttal is a CodeRabbit re-read"
expect_status 1091 no-reread "a CodeRabbit finding with no later CodeRabbit activity is not re-read"
expect_status 1101 not-rebutted "a rebuttal under the resolver's 30-character floor is not a rebuttal"
expect_status 1111 not-rebutted "a later Fixed reply supersedes an earlier rebuttal (latest recognized reply wins)"
expect_status 1121 reread-reraised "a post-request Codex review carrying a required-tier finding is a re-raise"
expect_status 1124 not-rebutted "the re-raised finding is itself an undispositioned required finding"
expect_status 1151 reread "substantive dating: the verdict after a post-rebuttal request is a re-read"
expect_status 1171 reread "a Codex reply in the thread after the rebuttal is a re-read"
expect_status 1181 owner-marker "an owner marker naming the finding is the owner clearance route"

[ "$(jq -r 'select(.finding == 1031) | .later_unrequested_response' "$F")" = true ] \
  && [ "$(jq -r 'select(.finding == 1011) | .later_unrequested_response' "$F")" = false ] \
  && [ "$(jq -r 'select(.finding == 1091) | .later_unrequested_response' "$F")" = null ] \
  && pass "a no-reread Codex finding records whether Codex reviewed again unasked" || fail "later_unrequested_response is wrong"
[ -z "$(jq -r 'select(.finding == 1051) | .finding' "$F")" ] \
  && pass "a P2 finding is outside the required tiers and produces no record" || fail "the P2 finding was recorded"
[ "$(jq -r 'select(.finding == 1151) | .status_latest' "$F")" = no-reread ] \
  && pass "latest dating reads the post-verdict tag as the rebuttal time, so the same finding is not re-read" \
  || fail "latest dating did not move the rebuttal to the later tag"
[ "$(jq -r 'select(.finding == 1041) | .rebuttal_sources | join(",")' "$F")" = thumbs-down ] \
  && [ "$(jq -r 'select(.finding == 1011) | .rebuttal_sources | join(",")' "$F")" = tag ] \
  && [ "$(jq -r 'select(.finding == 1021) | .rebuttal_sources | join(",")' "$F")" = reply ] \
  && pass "each rebuttal records which kind of evidence it rests on" || fail "rebuttal_sources is wrong"
[ "$(jq -r 'select(.finding == 1161) | .status' "$F")" = out-of-scope ] \
  && pass "a registered reviewer's required-tier thread is recorded as out of scope" || fail "the registered-reviewer thread was not set apart"
if jq -e 'has("body")' "$F" >/dev/null 2>&1; then fail "findings.jsonl carries comment bodies"; else pass "findings.jsonl is body-free"; fi

expect_total() { # <key> <value>
  local got
  got=$(jq -r --arg k "$1" '.totals[$k]' "$S")
  [ "$got" = "$2" ] && pass "totals.$1 = $2" || fail "totals.$1 is $got, expected $2"
}
expect_total prs_merged_in_window 18
expect_total prs_not_measured 2
expect_total prs_measured 16
expect_total prs_with_required_finding 14
expect_total prs_with_rebutted_resolved_required_finding 10
expect_total prs_matching 4
expect_total prs_matching_latest_dating 5
expect_total prs_with_reraised_rebuttal 1
expect_total prs_with_owner_marker 1
expect_total prs_matching_with_later_unrequested_review 1
[ "$(jq -c '[.matching_prs[].pr]' "$S")" = '[101,103,104,109]' ] \
  && pass "matching_prs lists exactly the no-reread PRs" || fail "matching_prs is $(jq -c '[.matching_prs[].pr]' "$S")"
[ "$(jq -c '.matching_prs_latest_dating_only' "$S")" = '[115]' ] \
  && pass "the PRs only latest dating matches are listed apart" || fail "matching_prs_latest_dating_only is wrong"
[ "$(jq -c '[.not_measured[].pr]' "$S")" = '[113,114]' ] \
  && pass "summary.json lists the unmeasured PRs" || fail "not_measured is $(jq -c '.not_measured' "$S")"
[ "$(jq -c '.out_of_scope' "$S")" = '{"registered_reviewer_required_threads":1,"prs":1}' ] \
  && pass "registered-reviewer threads are counted as out of scope" || fail "out_of_scope is $(jq -c '.out_of_scope' "$S")"
[ "$(jq -c '.api' "$S")" = '{"graphql_requests":2,"graphql_points":"3"}' ] \
  && pass "the API spend is read back from api.tsv" || fail "api is $(jq -c '.api' "$S")"
[ "$(jq -c '.policy.required_tiers' "$S")" = '["p0","p1"]' ] \
  && pass "required tiers come from resolve_required_tiers on the policy file" || fail "required tiers are $(jq -c '.policy.required_tiers' "$S")"
grep -q '^Matching PRs: #101, #103, #104, #109$' "$OUT/summary.md" \
  && pass "summary.md names the matching PRs" || fail "summary.md does not name the matching PRs"

# A clean extract (every listed PR measured) exits 0.
CLEAN="$WORKDIR/clean"
mkdir -p "$CLEAN/raw"
cp "$RAW/window.json" "$RAW/pr-101.json" "$CLEAN/raw/"
head -n 1 "$RAW/prs.jsonl" >"$CLEAN/raw/prs.jsonl"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$CLEAN" --policy "$ROOT/.github/review-policy.yml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && [ "$(jq '.totals.prs_matching' "$CLEAN/summary.json")" = 1 ] \
  && pass "a fully measured extract exits 0" || fail "a fully measured extract exited $rc"

# A record whose thumbs-down list was truncated is not measured, not guessed.
TRUNC="$WORKDIR/trunc"
mkdir -p "$TRUNC/raw"
cp "$RAW/window.json" "$CLEAN/raw/prs.jsonl" "$TRUNC/raw/"
jq -c '.threads[0].root_downs_truncated = true' "$RAW/pr-101.json" >"$TRUNC/raw/pr-101.json"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$TRUNC" --policy "$ROOT/.github/review-policy.yml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && [ "$(jq '.totals.prs_matching' "$TRUNC/summary.json")" = 0 ] \
  && [ "$(jq -r '.not_measured[0].reason' "$TRUNC/summary.json")" = "a finding root has more than 20 thumbs-down reactions" ] \
  && pass "a truncated reaction page makes the PR not measured" || fail "a truncated reaction page was not reported (exit $rc)"

# The polarity vocabulary is loaded from the resolver, never guessed.
: >"$WORKDIR/empty-resolver.sh"
rc=0
MERGEPATH_RESOLVER_SRC="$WORKDIR/empty-resolver.sh" bash "$SCRIPT" --analyze-only --out-dir "$CLEAN" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "a resolver without the polarity functions stops the run (exit 2)" \
  || fail "a missing polarity vocabulary exited $rc, expected 2"

# A fetch needs an explicit window.
rc=0
GH_TOKEN=unused bash "$SCRIPT" --out-dir "$WORKDIR/nowin" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "a fetch without --since/--until is refused (exit 1)" || fail "a fetch without a window exited $rc"
rc=0
bash "$SCRIPT" --since 2026-10-11 --until 2026-11-10T00:00:00Z >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "a window bound that is not a UTC instant is refused (exit 1)" || fail "a date-only bound exited $rc"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
