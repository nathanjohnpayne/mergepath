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
#   119 Codex P1, a reply edited into a rebuttal after a request and a Codex
#       review → no-reread (a rebuttal is dated by its last edit)
#   120 Codex P1, tag rebuttal, owner marker quoted mid-line → no-reread
#   121 Codex P1, tag rebuttal, owner marker naming a stale head → no-reread
#
# The policy is a fixture (below), not the repository's live file, so an
# edit to the live feedback_policy or bot logins cannot fail this suite.

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
c() { # [edited_at] as a sixth argument
  local type=User
  case "$2" in *"[bot]") type=Bot ;; esac
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$type" --arg at "$3" --arg b "$4" --argjson rv "${5:-null}" \
    --arg ed "${6:-}" \
    '{id: $id, login: $l, type: $t, created_at: $at, edited_at: (if $ed == "" then null else $ed end), review_id: $rv, body: $b}'
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
    --arg head "$HEAD" \
    '{pr: $n, merged_at: "2026-10-20T12:00:00Z", url: "https://github.com/o/r/pull/\($n)", head_sha: $head,
      threads: $th, reviews: $rv, comments: $ic}' >"$RAW/pr-$1.json"
}
arr() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -sc '.'; fi; }
req() { c "$1" "$AUTHOR" "$2" '@codex review'; }

HEAD=$(printf 'a%.0s' $(seq 40))
STALE=$(printf 'b%.0s' $(seq 40))
POLICY_FIX="$WORKDIR/review-policy.yml"
cat >"$POLICY_FIX" <<'YAML'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: discretionary
coderabbit:
  bot_login: "coderabbitai[bot]"
codex:
  bot_login: "chatgpt-codex-connector[bot]"
YAML

OUT="$WORKDIR/out"
RAW="$OUT/raw"
mkdir -p "$RAW"
jq -nc '{repo: "o/r", since: "2026-10-11T00:00:00Z", until: "2026-11-10T00:00:00Z"}' >"$RAW/window.json"
: >"$RAW/prs.jsonl"
for n in $(seq 101 121); do
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
  "$(arr "$(c 1183 "$AUTHOR" 2026-10-20T03:00:00Z "TIEBREAK_REBUTTAL_ACCEPTED=https://github.com/o/r/pull/118@$HEAD#1181")")"
pr 119 "$(arr "$(t T119 true '[]' "$(c 1191 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9119)" "$(c 1192 "$AGENT" 2026-10-20T02:00:00Z "$REBUT" null 2026-10-20T05:00:00Z)")")" \
  "$(arr "$(rv 9119 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')" "$(rv 9199 "$CODEX" 2026-10-20T04:00:00Z 'Codex review')")" \
  "$(arr "$(req 1193 2026-10-20T03:00:00Z)")"
pr 120 "$(arr "$(t T120 true '[]' "$(c 1201 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9120)" "$(c 1202 "$AGENT" 2026-10-20T02:00:00Z "$TAG")")")" \
  "$(arr "$(rv 9120 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" \
  "$(arr "$(c 1203 "$AUTHOR" 2026-10-20T03:00:00Z "The owner would type TIEBREAK_REBUTTAL_ACCEPTED=https://github.com/o/r/pull/120@$HEAD#1201 here.")")"
pr 121 "$(arr "$(t T121 true '[]' "$(c 1211 "$CODEX" 2026-10-20T01:00:00Z "$P1" 9121)" "$(c 1212 "$AGENT" 2026-10-20T02:00:00Z "$TAG")")")" \
  "$(arr "$(rv 9121 "$CODEX" 2026-10-20T01:00:00Z 'Codex review')")" \
  "$(arr "$(c 1213 "$AUTHOR" 2026-10-20T03:00:00Z "TIEBREAK_REBUTTAL_ACCEPTED=https://github.com/o/r/pull/121@$STALE#1211")")"

rc=0
bash "$SCRIPT" --analyze-only --out-dir "$OUT" --policy "$POLICY_FIX" >/dev/null 2>"$WORKDIR/err.log" || rc=$?
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
expect_status 1191 no-reread "a reply edited into a rebuttal is dated by its edit, after the Codex review"
expect_status 1201 no-reread "an owner marker quoted mid-line is not a marker (the ledger reads whole lines)"
expect_status 1211 no-reread "an owner marker naming a head other than the merged head does not count"

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
expect_total prs_merged_in_window 21
expect_total prs_not_measured 2
expect_total prs_measured 19
expect_total prs_with_required_finding 17
expect_total prs_with_rebutted_resolved_required_finding 13
expect_total prs_matching 7
expect_total prs_matching_latest_dating 8
expect_total prs_with_reraised_rebuttal 1
expect_total prs_with_owner_marker 1
expect_total prs_matching_with_later_unrequested_review 1
[ "$(jq -c '[.matching_prs[].pr]' "$S")" = '[101,103,104,109,119,120,121]' ] \
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
grep -q '^Matching PRs: #101, #103, #104, #109, #119, #120, #121$' "$OUT/summary.md" \
  && pass "summary.md names the matching PRs" || fail "summary.md does not name the matching PRs"

# A clean extract (every listed PR measured) exits 0.
CLEAN="$WORKDIR/clean"
mkdir -p "$CLEAN/raw"
cp "$RAW/window.json" "$RAW/pr-101.json" "$CLEAN/raw/"
head -n 1 "$RAW/prs.jsonl" >"$CLEAN/raw/prs.jsonl"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$CLEAN" --policy "$POLICY_FIX" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && [ "$(jq '.totals.prs_matching' "$CLEAN/summary.json")" = 1 ] \
  && pass "a fully measured extract exits 0" || fail "a fully measured extract exited $rc"

# A record whose thumbs-down list was truncated is not measured, not guessed.
TRUNC="$WORKDIR/trunc"
mkdir -p "$TRUNC/raw"
cp "$RAW/window.json" "$CLEAN/raw/prs.jsonl" "$TRUNC/raw/"
jq -c '.threads[0].root_downs_truncated = true' "$RAW/pr-101.json" >"$TRUNC/raw/pr-101.json"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$TRUNC" --policy "$POLICY_FIX" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && [ "$(jq '.totals.prs_matching' "$TRUNC/summary.json")" = 0 ] \
  && [ "$(jq -r '.not_measured[0].reason' "$TRUNC/summary.json")" = "a finding root has more than 20 thumbs-down reactions" ] \
  && pass "a truncated reaction page makes the PR not measured" || fail "a truncated reaction page was not reported (exit $rc)"

# The polarity vocabulary is loaded from the resolver, never guessed.
: >"$WORKDIR/empty-resolver.sh"
rc=0
MERGEPATH_RESOLVER_SRC="$WORKDIR/empty-resolver.sh" bash "$SCRIPT" --analyze-only --out-dir "$CLEAN" --policy "$POLICY_FIX" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "a resolver without the polarity functions stops the run (exit 2)" \
  || fail "a missing polarity vocabulary exited $rc, expected 2"

# A fetch needs an explicit window.
rc=0
GH_TOKEN=unused bash "$SCRIPT" --out-dir "$WORKDIR/nowin" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "a fetch without --since/--until is refused (exit 1)" || fail "a fetch without a window exited $rc"
rc=0
bash "$SCRIPT" --since 2026-10-11 --until 2026-11-10T00:00:00Z >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "a window bound that is not a UTC instant is refused (exit 1)" || fail "a date-only bound exited $rc"

# An extract taken before head_sha and url were fetched is not measured.
OLD="$WORKDIR/old"
mkdir -p "$OLD/raw"
cp "$RAW/window.json" "$CLEAN/raw/prs.jsonl" "$OLD/raw/"
jq -c 'del(.head_sha)' "$RAW/pr-101.json" >"$OLD/raw/pr-101.json"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$OLD" --policy "$POLICY_FIX" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && [ "$(jq '.totals.prs_matching' "$OLD/summary.json")" = 0 ] \
  && pass "a record without head_sha is not measured rather than read without its owner markers" \
  || fail "a record without head_sha exited $rc"

# A report that cannot be written fails the run (errexit is off inside analyze).
BADW="$WORKDIR/badwrite"
mkdir -p "$BADW/raw" "$BADW/summary.json"
cp "$RAW/window.json" "$RAW/pr-101.json" "$CLEAN/raw/prs.jsonl" "$BADW/raw/"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$BADW" --policy "$POLICY_FIX" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && pass "an unwritable summary.json fails the run (exit 3)" || fail "an unwritable summary.json exited $rc, expected 3"
BADM="$WORKDIR/badmd"
mkdir -p "$BADM/raw" "$BADM/summary.md"
cp "$RAW/window.json" "$RAW/pr-101.json" "$CLEAN/raw/prs.jsonl" "$BADM/raw/"
rc=0
bash "$SCRIPT" --analyze-only --out-dir "$BADM" --policy "$POLICY_FIX" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && pass "an unwritable summary.md fails the run (exit 3)" || fail "an unwritable summary.md exited $rc, expected 3"

# Fetch-side guards, against a fake gh that logs every call.
FAKE="$WORKDIR/fakebin"
mkdir -p "$FAKE"
cat >"$FAKE/gh" <<'SH'
#!/usr/bin/env bash
echo call >>"$FAKE_GH_LOG"
case "$FAKE_GH_MODE" in
  network) echo "error connecting to api.github.com" >&2; exit 1 ;;
  samecursor)
    echo '{"data":{"search":{"issueCount":2,"pageInfo":{"hasNextPage":true,"endCursor":"C1"},"nodes":[{"number":1,"mergedAt":"2026-10-20T00:00:00Z","url":"u"}]},"rateLimit":{"cost":1}}}' ;;
esac
SH
chmod +x "$FAKE/gh"
fetch_fake() { # <mode> <max-requests>; sets rc, and the log counts gh calls
  : >"$WORKDIR/gh.log"
  rc=0
  PATH="$FAKE:$PATH" FAKE_GH_LOG="$WORKDIR/gh.log" FAKE_GH_MODE="$1" GH_TOKEN=unused GH_RETRY_BACKOFF_SECONDS=0 \
    bash "$SCRIPT" --since 2026-10-11T00:00:00Z --until 2026-11-10T00:00:00Z --out-dir "$WORKDIR/fetch-$1" \
    --policy "$POLICY_FIX" --max-requests "$2" >/dev/null 2>"$WORKDIR/fetch-$1.err" || rc=$?
}
fetch_fake network 2
calls=$(wc -l <"$WORKDIR/gh.log" | tr -d ' ')
logged=$(wc -l <"$WORKDIR/fetch-network/raw/api.tsv" | tr -d ' ')
[ "$rc" -eq 3 ] && [ "$calls" = 2 ] && [ "$logged" = 2 ] \
  && pass "the request ceiling and api.tsv count every retry attempt (2 calls under --max-requests 2)" \
  || fail "retries escaped the ceiling or the count: exit $rc, $calls gh calls, $logged logged"
fetch_fake samecursor 10
calls=$(wc -l <"$WORKDIR/gh.log" | tr -d ' ')
[ "$rc" -eq 3 ] && [ "$calls" = 2 ] && grep -q 'unchanged endCursor' "$WORKDIR/fetch-samecursor.err" \
  && pass "a repeated search cursor stops the listing as a pagination error after 2 requests" \
  || fail "a repeated search cursor was not caught: exit $rc after $calls calls"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
