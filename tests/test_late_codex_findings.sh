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
SCRIPT="$ROOT/scripts/late-codex-findings.sh"
FIXTURE="$ROOT/tests/fixtures/codex_late_review_format_1120.json"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
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
REVIEW='{"id":801,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"submitted_at":"2026-08-28T03:00:00Z","html_url":"u","body":"### 💡 Codex Review\n![P1 Badge](x) late"}'
OLD_REVIEW='{"id":802,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"submitted_at":"2026-08-27T03:00:00Z","html_url":"u","body":"![P1 Badge](x) old"}'
INLINE='{"id":901,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"created_at":"2026-08-28T03:01:00Z","updated_at":"2026-08-28T03:01:00Z","html_url":"u","body":"**<sub><sub>![P0 Badge](x)</sub></sub> late inline"}'
[ "$(input "$MERGED" '[]' "[$REVIEW,$OLD_REVIEW]" "[$INLINE]" | select_ids)" = "review:801,inline-comment:901" ] \
  || die "late review/inline selection is wrong: $(input "$MERGED" '[]' "[$REVIEW,$OLD_REVIEW]" "[$INLINE]" | select_ids)"
ok "a late review and a late inline comment are selected, an old review is not"
[ "$(input "$MERGED" '[]' "[$OLD_REVIEW]" '[]' | select_ids --touched review:802)" = "review:802" ] \
  || die "an edited pre-merge review was not selected via --touched"
ok "--touched selects a pre-merge review edited after merge"

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
    -f) fields+=("$2"); shift 2 ;;
    *) endpoint=$1; shift ;;
  esac
done
echo "$method $endpoint" >>"$CALLS"
s=$(cat "$STATE")
out() { if [ -n "$jqf" ]; then printf '%s' "$1" | jq -r "$jqf"; else printf '%s\n' "$1"; fi; }
case "$method:$endpoint" in
  GET:repos/o/r/pulls/7) out "$(printf '%s' "$s" | jq -c .pr)" ;;
  GET:repos/o/r/issues/7/comments*) out "$(printf '%s' "$s" | jq -c .comments)" ;;
  GET:repos/o/r/pulls/7/reviews*) out "$(printf '%s' "$s" | jq -c .reviews)" ;;
  GET:repos/o/r/pulls/7/comments*) out "$(printf '%s' "$s" | jq -c .inline)" ;;
  GET:repos/o/r/issues\?labels=*) out "$(printf '%s' "$s" | jq -c '[.issues[] | del(.comments)]')" ;;
  GET:repos/o/r/issues/*/comments*) n=${endpoint#repos/o/r/issues/}; n=${n%%/*}
    out "$(printf '%s' "$s" | jq -c --argjson n "$n" '[.issues[] | select(.number == $n) | .comments[] | {body: .}]')" ;;
  POST:repos/o/r/labels) echo '{}' ;;
  POST:repos/o/r/issues) b=$(cat "$input")
    printf '%s' "$s" | jq -c --argjson b "$b" '.issues += [{number: (100 + (.issues | length)), state: "open", body: $b.body, title: $b.title, labels: $b.labels, comments: []}]' >"$STATE"
    out '{"html_url":"https://example.test/issues/100"}' ;;
  POST:repos/o/r/issues/*/comments) n=${endpoint#repos/o/r/issues/}; n=${n%%/*}; b=$(cat "$input")
    printf '%s' "$s" | jq -c --argjson n "$n" --argjson b "$b" '(.issues[] | select(.number == $n) | .comments) += [$b.body]' >"$STATE"
    out '{"html_url":"https://example.test/c"}' ;;
  PATCH:repos/o/r/issues/*) n=${endpoint#repos/o/r/issues/}
    printf '%s' "$s" | jq -c --argjson n "$n" '(.issues[] | select(.number == $n) | .state) = "open"' >"$STATE"
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
jq -nc --argjson c "$C1120" '{pr: {merged_at: null}, comments: [$c], reviews: [], inline: [], issues: []}' >"$STATE"
run || die "the unmerged run failed"
[ "$(jq '.issues | length' "$STATE")" = 0 ] && grep -q 'is not merged' "$DIR/out" || die "an unmerged PR was recorded"
ok "an unmerged (closed) PR records nothing"
jq -nc --arg m "$MERGED" --argjson c "$C1120" '{pr: {merged_at: $m}, comments: [$c], reviews: [], inline: [], issues: []}' >"$STATE"
run --dry-run || die "the dry run failed"
[ "$(jq '.issues | length' "$STATE")" = 0 ] && grep -q 'dry run, would record' "$DIR/out" || die "a dry run wrote"
ok "--dry-run reports the finding and writes nothing"
if PATH="$DIR/bin:$PATH" "$SCRIPT" --repo o/r >/dev/null 2>&1; then die "a missing --pr/--sweep was accepted"; fi
if PATH="$DIR/bin:$PATH" "$SCRIPT" --repo o/r --pr 7 --touched comment:1 >/dev/null 2>&1; then die "a malformed --touched was accepted"; fi
ok "usage errors exit nonzero"

echo "test_late_codex_findings: $PASS passed"
