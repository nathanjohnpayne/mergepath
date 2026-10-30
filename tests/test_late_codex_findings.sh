#!/usr/bin/env bash
# tests/test_late_codex_findings.sh — scripts/late-codex-findings.sh (#2881).
#
# Pure selector cases, then the writer against a fake gh: the canonical
# mergepath#1120 late P2 opens one tracking issue; a rerun records nothing; an
# edit that changes the body records one new item and reopens a closed issue;
# findings from before the merge, an unmerged PR, and an impersonated bot are
# never recorded.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURE="$ROOT/tests/fixtures/codex_late_review_format_1120.json"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
# The detector reads codex.bot_login from its own checkout's policy, so the
# fixtures run a copy in a tree with no policy file: the standard login,
# whatever a consumer configures. The policy case below builds its own tree.
mkdir -p "$DIR/default/scripts"
cp "$ROOT/scripts/late-codex-findings.sh" "$DIR/default/scripts/"
SCRIPT="$DIR/default/scripts/late-codex-findings.sh"
PASS=0
ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

MERGED=$(jq -r .merged_at "$FIXTURE")
C1120=$(jq -c .comment "$FIXTURE")
select_ids() { "$SCRIPT" --select "$@" | jq -r 'map("\(.kind):\(.id)") | join(",")'; }
input() { jq -nc --arg m "$1" --argjson c "$2" --argjson r "$3" --argjson i "$4" '{merged_at: $m, comments: $c, reviews: $r, inline: $i}'; }

# --- pure selector -----------------------------------------------------------
[ "$(input "$MERGED" "[$C1120]" '[]' '[]' | select_ids)" = "issue-comment:5447842730" ] \
  || die "the #1120 late P2 issue comment was not selected"
ok "the canonical #1120 late P2 (5 min after merge) is selected"
[ "$(input "$MERGED" "[$C1120]" '[]' '[]' | "$SCRIPT" --select | jq -r '.[0].tiers | join(",")'):$(input "$MERGED" "[$C1120]" '[]' '[]' | "$SCRIPT" --select | jq -r '.[0].minutes')" = "P2:5" ] \
  || die "the #1120 item does not carry its tier and minutes after merge"
ok "the #1120 item carries tier P2 and 5 minutes after merge"
[ "$(input 2026-08-28T03:10:00Z "[$C1120]" '[]' '[]' | select_ids)" = "" ] || die "a finding from before the merge was selected"
ok "a finding created before the merge is not late"
[ "$(input 2026-08-28T02:59:24Z "[$C1120]" '[]' '[]' | select_ids)" = "" ] || die "a same-second finding was selected"
ok "a finding in the merge's own second is not after it"
EDITED=$(printf '%s' "$C1120" | jq -c '.created_at = "2026-08-28T02:00:00Z" | .updated_at = "2026-08-28T03:30:00Z"')
[ "$(input "$MERGED" "[$EDITED]" '[]' '[]' | select_ids)" = "issue-comment:5447842730" ] || die "a post-merge edit was not selected"
ok "a pre-merge comment edited after merge is selected"
[ "$(input "$MERGED" "[$(printf '%s' "$C1120" | jq -c '.user.type = "User"')]" '[]' '[]' | select_ids)" = "" ] || die "a non-Bot user type was trusted"
ok "a comment whose user.type is not Bot is ignored"
CLEAN=$(printf '%s' "$C1120" | jq -c '.body = "Codex Review: Didn'"'"'t find any major issues."')
[ "$(input "$MERGED" "[$CLEAN]" '[]' '[]' | select_ids)" = "" ] || die "a clean verdict was selected"
ok "a clean post-merge verdict is not a finding"
# Codex P2 on #2898: the text-only `**Pn` fallback (tests/test_codex_p1_gate.sh
# exercises `**P1: ...`) is a finding, with its tier, in both of its forms.
FB_BASE='{"id":901,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"created_at":"2026-08-28T03:01:00Z","updated_at":"2026-08-28T03:01:00Z","html_url":"u","body":""}'
for form in '**P1: Text-only fallback.|P1' '**P2** Text-only fallback.|P2'; do
  body=${form%|*} want=${form##*|}
  FALLBACK=$(printf '%s' "$FB_BASE" | jq -c --arg b "$body" '.body = $b')
  [ "$(input "$MERGED" '[]' '[]' "[$FALLBACK]" | "$SCRIPT" --select | jq -r 'map("\(.id):\(.tiers | join(","))") | join(";")')" = "901:$want" ] \
    || die "the text-only fallback '$body' was not selected as $want"
done
ok "the text-only **P1: and **P2** fallbacks are findings with their tiers"
# Parity with codex_tiers_of: every body it reads a tier from is a finding
# here, with the same tiers.
# shellcheck source=../scripts/lib/feedback-policy-helpers.sh
. "$ROOT/scripts/lib/feedback-policy-helpers.sh"
for body in '![P0 Badge](x) badge' '**P1: colon fallback' '**P3** bold fallback' '**<sub>![P2 Badge](x)</sub>** wrapped badge' '![P1 Badge](x) and **P2: two markers'; do
  want=$(codex_tiers_of "$body" | tr 'p' 'P' | sort -u | paste -sd, -)
  got=$(input "$MERGED" '[]' '[]' "[$(printf '%s' "$FB_BASE" | jq -c --arg b "$body" '.body = $b')]" | "$SCRIPT" --select | jq -r '.[0].tiers // [] | join(",")')
  [ -n "$want" ] && [ "$got" = "$want" ] || die "tiers for '$body': codex_tiers_of says '$want', the detector '$got'"
done
ok "every body codex_tiers_of reads is a finding with the same tiers"
REVIEW='{"id":801,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"submitted_at":"2026-08-28T03:00:00Z","html_url":"u","body":"### 💡 Codex Review\n![P1 Badge](x) late"}'
OLD_REVIEW='{"id":802,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"submitted_at":"2026-08-27T03:00:00Z","html_url":"u","body":"![P1 Badge](x) old"}'
INLINE='{"id":901,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"created_at":"2026-08-28T03:01:00Z","updated_at":"2026-08-28T03:01:00Z","html_url":"u","body":"**<sub><sub>![P0 Badge](x)</sub></sub> late inline"}'
[ "$(input "$MERGED" '[]' "[$REVIEW,$OLD_REVIEW]" "[$INLINE]" | select_ids)" = "review:801,inline-comment:901" ] \
  || die "late review/inline selection is wrong: $(input "$MERGED" '[]' "[$REVIEW,$OLD_REVIEW]" "[$INLINE]" | select_ids)"
ok "a late review and a late inline comment are selected, an old review is not"
[ "$(input "$MERGED" '[]' "[$OLD_REVIEW]" '[]' | select_ids --touched review:802)" = "review:802" ] \
  || die "an edited pre-merge review was not selected via --touched"
ok "--touched selects a pre-merge review edited after merge"
# Phase 4b round 2 on #2886: a Codex finding with an unreadable time fails the
# run rather than being skipped as not late.
for bad in "[$(printf '%s' "$C1120" | jq -c '.updated_at = "soon"')]|[]|[]" "[]|[$(printf '%s' "$OLD_REVIEW" | jq -c '.submitted_at = null')]|[]" "[]|[]|[$(printf '%s' "$INLINE" | jq -c '.created_at = "?"')]"; do
  IFS='|' read -r bc br bi <<<"$bad"
  if input "$MERGED" "$bc" "$br" "$bi" | "$SCRIPT" --select >/dev/null 2>&1; then die "an unreadable finding time was skipped ($bad)"; fi
done
ok "an unreadable finding time (comment, review or inline) fails instead of being skipped"
[ "$(input "$MERGED" '[]' "[$(printf '%s' "$OLD_REVIEW" | jq -c '.edited_at = "2026-08-28T04:00:00Z"')]" '[]' | select_ids)" = "review:802" ] \
  || die "a pre-merge review with a post-merge lastEditedAt was not selected"
[ "$(input "$MERGED" '[]' "[$(printf '%s' "$OLD_REVIEW" | jq -c '.edited_at = "2026-08-27T04:00:00Z"')]" '[]' | select_ids)" = "" ] \
  || die "a review edited before the merge was selected"
ok "a review's GraphQL edit time selects it without --touched, only when after merge"

# --- writer against a fake gh -------------------------------------------------
mkdir -p "$DIR/bin"
cat >"$DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
# State in $STATE: {pr, comments, reviews, inline, issues: [{number, state, body, labels, comments: []}]}
set -euo pipefail
[ "$1" = api ] || exit 99; shift
method=GET; input=""; jqf=""; endpoint=""; fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    -X) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    --jq) jqf=$2; shift 2 ;;
    -f|-F) fields+=("$2"); shift 2 ;;
    *) endpoint=$1; shift ;;
  esac
done
echo "$method $endpoint" >>"$CALLS"
s=$(cat "$STATE")
out() { if [ -n "$jqf" ]; then printf '%s' "$1" | jq -r "$jqf"; else printf '%s\n' "$1"; fi; }
case "$method:$endpoint" in
  GET:repos/o/r/pulls/7) out "$(printf '%s' "$s" | jq -c .pr)" ;;
  GET:repos/o/r/pulls/6) echo "HTTP 502" >&2; exit 1 ;;
  GET:repos/o/r/issues\?state=closed*) out "$(printf '%s' "$s" | jq -c '.closed // []')" ;;
  GET:repos/o/r/issues/7/comments*) out "$(printf '%s' "$s" | jq -c .comments)" ;;
  GET:repos/o/r/pulls/7/reviews*) out "$(printf '%s' "$s" | jq -c .reviews)" ;;
  GET:repos/o/r/pulls/7/comments*) out "$(printf '%s' "$s" | jq -c .inline)" ;;
  GET:repos/o/r/issues\?labels=*) out "$(printf '%s' "$s" | jq -c '[.issues[] | del(.comments) | .user //= {login: "github-actions[bot]"}]')" ;;
  GET:repos/o/r/issues/*/comments*) n=${endpoint#repos/o/r/issues/}; n=${n%%/*}
    out "$(printf '%s' "$s" | jq -c --argjson n "$n" '[.issues[] | select(.number == $n) | .comments[] | if type == "string" then {body: ., user: {login: "github-actions[bot]"}} else . end]')" ;;
  GET:graphql) out "$(printf '%s' "$s" | jq -c '{data: {repository: {pullRequest: {reviews: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: (.review_edits // [])}}}}}')" ;;
  POST:repos/o/r/labels) echo '{}' ;;
  POST:repos/o/r/issues) b=$(cat "$input")
    # A concurrent run (state.race) opens its own tracker, numbered lower, just before ours.
    s=$(printf '%s' "$s" | jq -c 'if .race then .race = false | .issues += [{number: 50, state: "open", user: {login: "github-actions[bot]"}, body: "<!-- mergepath-late-codex-finding: o/r#7 -->\nconcurrent", comments: []}] else . end')
    n=$(printf '%s' "$s" | jq '100 + ([.issues[] | select(.number >= 100)] | length)')
    printf '%s' "$s" | jq -c --argjson b "$b" --argjson n "$n" '.issues += [{number: $n, state: "open", user: {login: "github-actions[bot]"}, body: $b.body, title: $b.title, labels: $b.labels, comments: []}]' >"$STATE"
    out "{\"number\":$n,\"html_url\":\"https://example.test/issues/$n\"}" ;;
  POST:repos/o/r/issues/*/comments) n=${endpoint#repos/o/r/issues/}; n=${n%%/*}; b=$(cat "$input")
    printf '%s' "$s" | jq -c --argjson n "$n" --argjson b "$b" '(.issues[] | select(.number == $n) | .comments) += [$b.body]' >"$STATE"
    out '{"html_url":"https://example.test/c"}' ;;
  PATCH:repos/o/r/issues/*) [ "$(printf '%s' "$s" | jq -r '.fail_reopen // false')" != true ] || { echo "HTTP 502" >&2; exit 1; }
    n=${endpoint#repos/o/r/issues/}
    st=open; for f in ${fields[@]+"${fields[@]}"}; do case "$f" in state=*) st=${f#state=} ;; esac; done
    printf '%s' "$s" | jq -c --argjson n "$n" --arg st "$st" '(.issues[] | select(.number == $n) | .state) = $st' >"$STATE"
    echo '{}' ;;
  *) echo "unexpected $method $endpoint" >&2; exit 99 ;;
esac
GH
chmod +x "$DIR/bin/gh"
export CALLS="$DIR/calls" STATE="$DIR/state"
run() { : >"$CALLS"; PATH="$DIR/bin:$PATH" TMPDIR="$DIR" "$SCRIPT" --repo o/r --pr 7 "$@" >"$DIR/out" 2>&1; }
jq -nc --arg m "$MERGED" --argjson c "$C1120" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: []}' >"$STATE"
run || { cat "$DIR/out"; die "the first run failed"; }
[ "$(jq '.issues | length' "$STATE")" = 1 ] && [ "$(jq -r '.issues[0].labels[0]' "$STATE")" = late-codex-finding ] \
  && jq -r '.issues[0].body' "$STATE" | grep -qF '<!-- mergepath-late-codex-finding: o/r#7 -->' \
  && jq -r '.issues[0].body' "$STATE" | grep -qF 'mergepath-late-codex-item: issue-comment:5447842730:' \
  || { cat "$DIR/out"; jq . "$STATE"; die "the #1120 finding did not open one labelled tracking issue with its item marker"; }
ok "the #1120 late finding opens one labelled tracking issue carrying the PR and item markers"
run || die "the rerun failed"
[ "$(jq '.issues | length' "$STATE")" = 1 ] && [ "$(jq '.issues[0].comments | length' "$STATE")" = 0 ] \
  && ! grep -q '^POST' "$CALLS" || { cat "$CALLS"; die "a rerun wrote again"; }
ok "a rerun over the same finding writes nothing"
jq -c '.issues[0].state = "closed" | .comments[0].body += "\n\n**[P1]** added by a post-merge edit" | .comments[0].updated_at = "2026-08-28T04:00:00Z"' "$STATE" >"$DIR/s2" && mv "$DIR/s2" "$STATE"
run || { cat "$DIR/out"; die "the edit run failed"; }
[ "$(jq '.issues | length' "$STATE")" = 1 ] && [ "$(jq '.issues[0].comments | length' "$STATE")" = 1 ] \
  && [ "$(jq -r '.issues[0].state' "$STATE")" = open ] \
  && jq -r '.issues[0].comments[0]' "$STATE" | grep -q 'mergepath-late-codex-item: issue-comment:5447842730:' \
  || { cat "$DIR/out"; jq . "$STATE"; die "a post-merge edit did not add one item and reopen the issue"; }
ok "an edit that changes the body after merge adds one item and reopens the closed issue"
# A reopen that fails records nothing, so the next run retries both writes.
jq -c '.issues[0].state = "closed" | .fail_reopen = true | .comments[0].body += "\n\n**[P2]** a second post-merge edit" | .comments[0].updated_at = "2026-08-28T05:00:00Z"' "$STATE" >"$DIR/s2" && mv "$DIR/s2" "$STATE"
if run; then die "a failed reopen was reported as success"; fi
[ "$(jq '.issues[0].comments | length' "$STATE")" = 1 ] && [ "$(jq -r '.issues[0].state' "$STATE")" = closed ] \
  || { jq . "$STATE"; die "a failed reopen still recorded the item"; }
jq -c '.fail_reopen = false' "$STATE" >"$DIR/s2" && mv "$DIR/s2" "$STATE"
run || { cat "$DIR/out"; die "the retry after a failed reopen failed"; }
[ "$(jq '.issues[0].comments | length' "$STATE")" = 2 ] && [ "$(jq -r '.issues[0].state' "$STATE")" = open ] \
  || { jq . "$STATE"; die "the retry did not reopen and record the item"; }
ok "a failed reopen records nothing, and the next run reopens and records the item"
jq -nc --argjson c "$C1120" '{pr: {state: "closed"}, comments: [$c], reviews: [], inline: [], issues: []}' >"$STATE"
if run; then die "a PR read without merged_at read as not merged"; fi
grep -q 'unreadable merge state' "$DIR/out" || die "a PR read without merged_at was not named unreadable"
ok "a PR read without a merged_at key is unreadable, never not-merged"
jq -nc --argjson c "$C1120" '{pr: {merged_at: null}, comments: [$c], reviews: [], inline: [], issues: []}' >"$STATE"
run || die "the unmerged run failed"
[ "$(jq '.issues | length' "$STATE")" = 0 ] && grep -q 'is not merged' "$DIR/out" || die "an unmerged PR was recorded"
ok "an unmerged (closed) PR records nothing"
jq -nc --arg m "$MERGED" --argjson c "$C1120" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: []}' >"$STATE"
run --dry-run || die "the dry run failed"
[ "$(jq '.issues | length' "$STATE")" = 0 ] && grep -q 'dry run, would record' "$DIR/out" || die "a dry run wrote"
ok "--dry-run reports the finding and writes nothing"
# The sweep isolates a failing PR: #6 cannot be read, #7 is still recorded,
# and the sweep exits 3 after the loop.
jq -nc --arg m "$MERGED" --argjson c "$C1120" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: [],
  closed: [{number: 6, pull_request: {merged_at: $m}}, {number: 7, pull_request: {merged_at: $m}}, {number: 5}]}' >"$STATE"
: >"$CALLS"
rc=0
PATH="$DIR/bin:$PATH" TMPDIR="$DIR" "$SCRIPT" --repo o/r --sweep --since 2026-08-27T00:00:00Z >"$DIR/out" 2>&1 || rc=$?
[ "$rc" = 3 ] && [ "$(jq '.issues | length' "$STATE")" = 1 ] && grep -q 'sweep failed on o/r#6; continuing' "$DIR/out" \
  && ! grep -q 'repos/o/r/pulls/5$' "$CALLS" \
  || { cat "$DIR/out"; cat "$CALLS"; die "the sweep did not isolate the failing PR (rc=$rc)"; }
ok "the sweep records #7 although #6 fails, skips unmerged issues, and exits 3"
# Phase 4b on #2886: the sweep has no --touched hint; a pre-merge review whose
# GraphQL lastEditedAt is after merge (e.g. a fork PR's read-only event run
# could not write) is still recorded.
jq -nc --arg m "$MERGED" --argjson r "$OLD_REVIEW" '{pr: {merged_at: $m}, comments: [], reviews: [$r], inline: [], issues: [],
  review_edits: [{fullDatabaseId: "802", lastEditedAt: "2026-08-28T04:00:00Z"}],
  closed: [{number: 7, pull_request: {merged_at: $m}}]}' >"$STATE"
PATH="$DIR/bin:$PATH" TMPDIR="$DIR" "$SCRIPT" --repo o/r --sweep --since 2026-08-27T00:00:00Z >"$DIR/out" 2>&1 \
  || { cat "$DIR/out"; die "the edited-review sweep failed"; }
jq -r '.issues[0].body // ""' "$STATE" | grep -q 'mergepath-late-codex-item: review:802:' \
  || { cat "$DIR/out"; jq . "$STATE"; die "the sweep missed a pre-merge review edited after merge"; }
ok "the sweep records a pre-merge review edited after merge, without --touched"
# Phase 4b on #2886: only the recorder's own records count. A marker someone
# else posts on the tracker, or a tracker someone else opened, suppresses
# nothing.
FP=$(printf '%s' "$C1120" | jq -j .body | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -c1-16)
jq -nc --arg m "$MERGED" --argjson c "$C1120" --arg fp "$FP" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: [
  {number: 90, state: "closed", user: {login: "github-actions[bot]"}, body: "<!-- mergepath-late-codex-finding: o/r#7 -->",
   comments: [{body: "<!-- mergepath-late-codex-item: issue-comment:5447842730:\($fp) -->", user: {login: "drive-by"}}]}]}' >"$STATE"
run || { cat "$DIR/out"; die "the forged-marker run failed"; }
[ "$(jq '[.issues[] | select(.number == 90) | .comments[]] | length' "$STATE")" = 2 ] && [ "$(jq -r '.issues[] | select(.number == 90) | .state' "$STATE")" = open ] \
  || { jq . "$STATE"; die "a marker from another commenter suppressed the finding"; }
ok "a dedup marker posted by someone else does not suppress the finding"
jq -nc --arg m "$MERGED" --argjson c "$C1120" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: [
  {number: 80, state: "open", user: {login: "drive-by"}, body: "<!-- mergepath-late-codex-finding: o/r#7 -->", comments: []}]}' >"$STATE"
run || { cat "$DIR/out"; die "the foreign-tracker run failed"; }
[ "$(jq '[.issues[] | select(.number >= 100)] | length' "$STATE")" = 1 ] && [ "$(jq '.issues[] | select(.number == 80) | .comments | length' "$STATE")" = 0 ] \
  || { jq . "$STATE"; die "a tracker opened by someone else was trusted"; }
ok "a tracker opened by someone else is ignored; the recorder opens its own"
# Two runs race to open a tracker: the lower-numbered one is canonical, and
# the run that lost records its items there, then closes its own duplicate.
jq -nc --arg m "$MERGED" --argjson c "$C1120" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: [], race: true}' >"$STATE"
run || { cat "$DIR/out"; die "the race run failed"; }
[ "$(jq -r '.issues[] | select(.number == 100) | .state' "$STATE")" = closed ] \
  && [ "$(jq -r '.issues[] | select(.number == 50) | .state' "$STATE")" = open ] \
  && jq -r '.issues[] | select(.number == 50) | .comments[] | if type == "string" then . else .body end' "$STATE" | grep -q 'mergepath-late-codex-item: issue-comment:5447842730:' \
  || { cat "$DIR/out"; jq . "$STATE"; die "a tracker race did not converge on the canonical tracker"; }
ok "a tracker race converges: items land on the lowest tracker and the duplicate is closed"
# Phase 4b round 3 on #2886: a duplicate left open by an earlier run is
# reconciled even when nothing new arrived.
jq -nc --arg m "$MERGED" --argjson c "$C1120" --arg fp "$FP" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: [
  {number: 50, state: "open", user: {login: "github-actions[bot]"}, body: "<!-- mergepath-late-codex-finding: o/r#7 -->", comments: []},
  {number: 60, state: "open", user: {login: "github-actions[bot]"}, body: "<!-- mergepath-late-codex-finding: o/r#7 -->\n- item <!-- mergepath-late-codex-item: issue-comment:5447842730:\($fp) -->", comments: []}]}' >"$STATE"
run || { cat "$DIR/out"; die "the stale-duplicate run failed"; }
[ "$(jq -r '.issues[] | select(.number == 60) | .state' "$STATE")" = closed ] \
  && jq -r '.issues[] | select(.number == 50) | .comments[] | if type == "string" then . else .body end' "$STATE" | grep -q 'mergepath-late-codex-item: issue-comment:5447842730:' \
  && [ "$(jq '[.issues[] | select(.number == 50) | .comments[]] | length' "$STATE")" = 1 ] \
  || { cat "$DIR/out"; jq . "$STATE"; die "a stale duplicate tracker was not reconciled"; }
ok "a duplicate left open by an earlier run is reconciled although nothing new arrived"
# The edit-time join uses fullDatabaseId; a node without a usable one fails.
jq -nc --arg m "$MERGED" --argjson r "$OLD_REVIEW" '{pr: {merged_at: $m}, comments: [], reviews: [$r], inline: [], issues: [],
  review_edits: [{databaseId: 802, lastEditedAt: "2026-08-28T04:00:00Z"}]}' >"$STATE"
if run; then die "a review edit node without fullDatabaseId was accepted"; fi
ok "a review edit node without fullDatabaseId fails instead of matching nothing"
# codex.bot_login comes from the governing policy.
mkdir -p "$DIR/tree/scripts/lib" "$DIR/tree/.github"
cp "$ROOT/scripts/late-codex-findings.sh" "$DIR/tree/scripts/"; cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$DIR/tree/scripts/lib/"
printf 'codex:\n  bot_login: "custom-codex[bot]"\n' >"$DIR/tree/.github/review-policy.yml"
CUSTOM=$(printf '%s' "$C1120" | jq -c '.user.login = "custom-codex[bot]"')
[ "$(input "$MERGED" "[$CUSTOM,$C1120]" '[]' '[]' | "$DIR/tree/scripts/late-codex-findings.sh" --select | jq -r 'map(.id) | join(",")')" = 5447842730 ] \
  && [ "$(input "$MERGED" "[$C1120]" '[]' '[]' | "$DIR/tree/scripts/late-codex-findings.sh" --select | jq 'length')" = 0 ] \
  || die "the configured codex.bot_login was not honoured"
printf 'codex: [unterminated\n' >"$DIR/tree/.github/review-policy.yml"
rc=0; input "$MERGED" "[$C1120]" '[]' '[]' | "$DIR/tree/scripts/late-codex-findings.sh" --select >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || die "an unparseable policy was not refused (rc=$rc)"
ok "the bot login comes from codex.bot_login; an unparseable policy exits 2"
if PATH="$DIR/bin:$PATH" "$SCRIPT" --repo o/r >/dev/null 2>&1; then die "a missing --pr/--sweep was accepted"; fi
if PATH="$DIR/bin:$PATH" "$SCRIPT" --repo o/r --pr 7 --touched comment:1 >/dev/null 2>&1; then die "a malformed --touched was accepted"; fi
ok "usage errors exit nonzero"

echo "test_late_codex_findings: $PASS passed"
