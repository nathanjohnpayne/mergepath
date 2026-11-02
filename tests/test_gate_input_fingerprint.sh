#!/usr/bin/env bash
# tests/test_gate_input_fingerprint.sh
#
# Behavioural suite for scripts/workflow/gate-input-fingerprint.sh (#2920):
# the review-input fingerprint a producer records beside a green verdict,
# and the decision whether a later review event may leave that verdict
# standing. A fake `gh` answers every read from fixture files and applies
# the library's own --jq expression with the real jq.
#
# Skips (the fingerprint is unchanged):
#   1. a second identical approval on the same head;
#   2. a second identical comment-only review on the same head.
# Re-evaluates (the fingerprint changes):
#   3. approve, then request changes;
#   4. a dismissal;
#   5. a push (new head), including a stored marker on the old head;
#   6. a thread resolution;
#   7. a label change, a new inline finding, a comment edit, a reaction.
# Negative controls (the published side does not allow a skip):
#   8. a missing, corrupted or truncated stored fingerprint; a red or
#      pending newest run; an older match under a newer run without one;
#      a job-native run carrying the marker; a stale verdict; an
#      unreadable listing.
# Fail toward re-evaluating (no fingerprint at all):
#   9. any failed read, more than one page of threads, a GraphQL error, a
#      live head that differs from the event head, an unsupported context,
#      a malformed trusted revision.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${GATE_INPUT_FINGERPRINT_LIB:-$ROOT/scripts/workflow/gate-input-fingerprint.sh}"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gif-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

REPO=acme/widgets
PR=7
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD2=cccccccccccccccccccccccccccccccccccccccc
REV=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CTX="Merge clearance gate"

# Fake gh: FIX names the fixture directory; FAIL_READ names one endpoint
# substring whose read fails.
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
[ "$1" = api ] || exit 2
shift
endpoint="" jqexpr="" graphql=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) ;;
    -X) shift ;;
    --jq) jqexpr="$2"; shift ;;
    -f|-F) shift ;;
    graphql) graphql=1 ;;
    *) [ -n "$endpoint" ] || endpoint="$1" ;;
  esac
  shift
done
if [ "$graphql" -eq 1 ]; then endpoint=graphql; fi
if [ -n "${FAIL_READ:-}" ] && [[ "$endpoint" == *"$FAIL_READ"* ]]; then
  echo "gh: HTTP 502" >&2
  exit 1
fi
case "$endpoint" in
  graphql) file=threads.json ;;
  */commits/*/check-runs) file=runs-${endpoint#*/commits/}; file=${file%%/*}.json ;;
  */pulls/*/reviews) file=reviews.json ;;
  */pulls/*/comments) file=inline.json ;;
  */issues/*/comments) file=comments.json ;;
  */pulls/*) file=pr.json ;;
  */issues/*) file=issue.json ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 2 ;;
esac
[ -f "$FIX/$file" ] || { echo "gh: HTTP 404 ($file)" >&2; exit 1; }
if [ -n "$jqexpr" ]; then
  jq -rc "$jqexpr" "$FIX/$file"
else
  cat "$FIX/$file"
fi
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_LOG="$TMP/gh.log"
: >"$GH_LOG"

# shellcheck source=../scripts/workflow/gate-input-fingerprint.sh
. "$LIB"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# A baseline PR state: one approval, one Codex finding thread, one
# PR-level comment.
base_fixture() {
  local d="$1"
  mkdir -p "$d"
  jq -n --arg head "$HEAD" '{number: 7, state: "open", draft: false, merged: false,
    title: "Add widget", body: "Body", user: {login: "nathanjohnpayne"},
    author_association: "OWNER", head: {sha: $head, ref: "feat", repo: {full_name: "acme/widgets"}},
    base: {ref: "main", sha: "dddddddddddddddddddddddddddddddddddddddd"},
    labels: [{name: "needs-external-review"}], requested_reviewers: [], requested_teams: [],
    auto_merge: null, updated_at: "2026-11-01T10:00:00Z"}' >"$d/pr.json"
  jq -n '{number: 7, reactions: {url: "x", total_count: 0, "+1": 0, eyes: 0}}' >"$d/issue.json"
  jq -n --arg head "$HEAD" '[{id: 11, user: {login: "nathanpayne-claude"}, state: "APPROVED",
    commit_id: $head, body: "", author_association: "COLLABORATOR",
    submitted_at: "2026-11-01T10:01:00Z"}]' >"$d/reviews.json"
  jq -n --arg head "$HEAD" '[{id: 21, user: {login: "chatgpt-codex-connector[bot]"}, body: "P2 nit",
    created_at: "2026-11-01T09:00:00Z", updated_at: "2026-11-01T09:00:00Z",
    pull_request_review_id: 10, in_reply_to_id: null, commit_id: $head,
    original_commit_id: $head, path: "a.sh", line: 3, original_line: 3, side: "RIGHT",
    subject_type: "line", reactions: {url: "x", total_count: 0}}]' >"$d/inline.json"
  jq -n '[{id: 31, user: {login: "nathanjohnpayne"}, body: "@codex review",
    created_at: "2026-11-01T08:00:00Z", updated_at: "2026-11-01T08:00:00Z",
    reactions: {url: "x", total_count: 1, eyes: 1, "+1": 0}}]' >"$d/comments.json"
  jq -n '{data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: false},
    nodes: [{id: "T1", isResolved: false, isOutdated: false}]}}}}}' >"$d/threads.json"
}

# runs <dir> <head> <json-array>: the check-run listing on <head>.
runs() { jq -n --argjson r "$3" '{check_runs: $r}' >"$1/runs-$2.json"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ago_iso() { jq -nr --argjson s "$1" 'now - $s | floor | todateiso8601'; }

api_run() { # id status conclusion text completed_at [details_url] [external_id]
  jq -n --argjson id "$1" --arg st "$2" --arg c "$3" --arg t "$4" --arg fin "$5" \
    --arg url "${6:-https://github.com/acme/widgets/runs/$1}" --arg ext "${7:-}" --arg ctx "$CTX" '
    {id: $id, name: $ctx, status: $st, conclusion: (if $c == "" then null else $c end),
     completed_at: (if $fin == "" then null else $fin end), external_id: $ext,
     app: {slug: "github-actions"}, details_url: $url,
     output: {title: "t", summary: "s", text: (if $t == "" then null else $t end)}}'
}

fp() { # dir [head] [revision]
  FIX="$1" gif_compute "$REPO" "$PR" "${2:-$HEAD}" "$CTX" "${3:-$REV}"
}

expect_same() { # label dirA dirB
  local a b
  a=$(fp "$2") && b=$(fp "$3") && [ "$a" = "$b" ] && pass "$1" || fail "$1 (fingerprints differ: ${a:-?} ${b:-?})"
}
expect_differ() { # label dirA dirB [headB]
  local a b
  a=$(fp "$2") || { fail "$1 (baseline did not compute)"; return; }
  b=$(fp "$3" "${4:-$HEAD}") || { fail "$1 (changed state did not compute)"; return; }
  [ "$a" != "$b" ] && pass "$1" || fail "$1 (fingerprint did not change)"
}

echo "gate-input-fingerprint: fingerprint computation"
base_fixture "$TMP/base"
h=$(fp "$TMP/base") && [[ "$h" =~ ^[0-9a-f]{64}$ ]] && pass "baseline computes a 64-hex fingerprint" \
  || fail "baseline computes a 64-hex fingerprint"

# 1. A second identical approval: a NEW review object, same content.
cp -R "$TMP/base" "$TMP/re-approve"
jq --arg head "$HEAD" '. + [{id: 12, user: {login: "nathanpayne-claude"}, state: "APPROVED",
  commit_id: $head, body: "", author_association: "COLLABORATOR",
  submitted_at: "2026-11-01T10:05:00Z"}]' "$TMP/base/reviews.json" >"$TMP/re-approve/reviews.json"
expect_same "1. repeated identical approval keeps the fingerprint" "$TMP/base" "$TMP/re-approve"

# 2. A second identical comment-only review.
cp -R "$TMP/base" "$TMP/comment1"
jq --arg head "$HEAD" '. + [{id: 13, user: {login: "nathanpayne-cursor"}, state: "COMMENTED",
  commit_id: $head, body: "Looks fine", author_association: "COLLABORATOR"}]' \
  "$TMP/base/reviews.json" >"$TMP/comment1/reviews.json"
cp -R "$TMP/comment1" "$TMP/comment2"
jq --arg head "$HEAD" '. + [{id: 14, user: {login: "nathanpayne-cursor"}, state: "COMMENTED",
  commit_id: $head, body: "Looks fine", author_association: "COLLABORATOR"}]' \
  "$TMP/comment1/reviews.json" >"$TMP/comment2/reviews.json"
expect_same "2. repeated identical comment-only review keeps the fingerprint" "$TMP/comment1" "$TMP/comment2"
expect_differ "2b. the FIRST comment-only review with a body changes it" "$TMP/base" "$TMP/comment1"

# 3. Approve, then request changes.
cp -R "$TMP/base" "$TMP/changes"
jq --arg head "$HEAD" '. + [{id: 15, user: {login: "nathanpayne-claude"}, state: "CHANGES_REQUESTED",
  commit_id: $head, body: "", author_association: "COLLABORATOR"}]' \
  "$TMP/base/reviews.json" >"$TMP/changes/reviews.json"
expect_differ "3. approve then CHANGES_REQUESTED changes the fingerprint" "$TMP/base" "$TMP/changes"
# ...and approving again after the change request is not collapsed into
# the first approval.
cp -R "$TMP/changes" "$TMP/reapproved"
jq --arg head "$HEAD" '. + [{id: 16, user: {login: "nathanpayne-claude"}, state: "APPROVED",
  commit_id: $head, body: "", author_association: "COLLABORATOR"}]' \
  "$TMP/changes/reviews.json" >"$TMP/reapproved/reviews.json"
expect_differ "3b. approve, request changes, approve differs from the first approval" "$TMP/base" "$TMP/reapproved"

# 4. A dismissal turns the review's state to DISMISSED.
cp -R "$TMP/re-approve" "$TMP/dismissed"
jq '(.[] | select(.id == 12) | .state) = "DISMISSED"' "$TMP/re-approve/reviews.json" >"$TMP/dismissed/reviews.json"
expect_differ "4. a dismissal changes the fingerprint" "$TMP/re-approve" "$TMP/dismissed"
cp -R "$TMP/base" "$TMP/dismissed-only"
jq '.[0].state = "DISMISSED"' "$TMP/base/reviews.json" >"$TMP/dismissed-only/reviews.json"
expect_differ "4b. dismissing the only approval changes the fingerprint" "$TMP/base" "$TMP/dismissed-only"

# 5. A push: the head moves. The old head's fingerprint cannot be computed
# against the new live head, and the new head's differs.
cp -R "$TMP/base" "$TMP/pushed"
jq --arg h "$HEAD2" '.head.sha = $h' "$TMP/base/pr.json" >"$TMP/pushed/pr.json"
expect_differ "5. a push changes the fingerprint" "$TMP/base" "$TMP/pushed" "$HEAD2"
if fp "$TMP/pushed" "$HEAD" >/dev/null 2>&1; then
  fail "5b. the event head no longer the live head computes no fingerprint"
else
  pass "5b. the event head no longer the live head computes no fingerprint"
fi

# 6. A thread resolution.
cp -R "$TMP/base" "$TMP/resolved"
jq '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved = true' \
  "$TMP/base/threads.json" >"$TMP/resolved/threads.json"
expect_differ "6. a thread resolution changes the fingerprint" "$TMP/base" "$TMP/resolved"

# 7. The other mutable inputs.
cp -R "$TMP/base" "$TMP/label"
jq '.labels = []' "$TMP/base/pr.json" >"$TMP/label/pr.json"
expect_differ "7a. a label change changes the fingerprint" "$TMP/base" "$TMP/label"
cp -R "$TMP/base" "$TMP/finding"
jq --arg head "$HEAD" '. + [{id: 22, user: {login: "chatgpt-codex-connector[bot]"}, body: "P1 bug",
  created_at: "x", updated_at: "x", pull_request_review_id: 17, commit_id: $head, path: "b.sh"}]' \
  "$TMP/base/inline.json" >"$TMP/finding/inline.json"
expect_differ "7b. a new inline finding changes the fingerprint" "$TMP/base" "$TMP/finding"
cp -R "$TMP/base" "$TMP/edited"
jq '.[0].body = "@codex review please" | .[0].updated_at = "2026-11-01T11:00:00Z"' \
  "$TMP/base/comments.json" >"$TMP/edited/comments.json"
expect_differ "7c. a PR-level comment edit changes the fingerprint" "$TMP/base" "$TMP/edited"
cp -R "$TMP/base" "$TMP/thumb"
jq '.[0].reactions["+1"] = 1 | .[0].reactions.total_count = 2' \
  "$TMP/base/comments.json" >"$TMP/thumb/comments.json"
expect_differ "7d. a reaction on a PR-level comment changes the fingerprint" "$TMP/base" "$TMP/thumb"
cp -R "$TMP/base" "$TMP/prthumb"
jq '.reactions["+1"] = 1' "$TMP/base/issue.json" >"$TMP/prthumb/issue.json"
expect_differ "7e. a reaction on the PR body changes the fingerprint" "$TMP/base" "$TMP/prthumb"
cp -R "$TMP/base" "$TMP/body"
jq '.body = "Body, edited"' "$TMP/base/pr.json" >"$TMP/body/pr.json"
expect_differ "7f. a PR body edit changes the fingerprint" "$TMP/base" "$TMP/body"
a=$(fp "$TMP/base") && b=$(FIX="$TMP/base" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" \
  "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee") && [ "$a" != "$b" ] \
  && pass "7g. a different trusted revision changes the fingerprint" \
  || fail "7g. a different trusted revision changes the fingerprint"
# Inert churn does not: the PR's updated_at moves on every review.
cp -R "$TMP/base" "$TMP/touched"
jq '.updated_at = "2026-11-01T12:00:00Z"' "$TMP/base/pr.json" >"$TMP/touched/pr.json"
expect_same "7h. the PR's updated_at alone keeps the fingerprint" "$TMP/base" "$TMP/touched"

echo "gate-input-fingerprint: published-run decision"
H=$(fp "$TMP/base")
MARK=$(gif_marker "$CTX" "$H")
decide() { # label expect(skip|eval) dir
  local rc=0
  FIX="$3" gif_decide "$REPO" "$PR" "$HEAD" "$CTX" "$REV" || rc=$?
  if [ "$2" = skip ] && [ "$rc" -eq 0 ]; then pass "$1"
  elif [ "$2" = eval ] && [ "$rc" -ne 0 ]; then pass "$1 ($GIF_REASON)"
  else fail "$1 (rc=$rc: $GIF_REASON)"; fi
}

runs "$TMP/base" "$HEAD" "[$(api_run 500 completed success "$MARK" "$(ago_iso 60)")]"
decide "matching fresh green carries over" skip "$TMP/base"
cp "$TMP/base/runs-$HEAD.json" "$TMP/re-approve/"
decide "1'. repeated identical approval skips" skip "$TMP/re-approve"
cp "$TMP/base/runs-$HEAD.json" "$TMP/changes/"
decide "3'. approve then request changes re-evaluates" eval "$TMP/changes"
cp "$TMP/base/runs-$HEAD.json" "$TMP/dismissed-only/"
decide "4'. a dismissal re-evaluates" eval "$TMP/dismissed-only"
cp "$TMP/base/runs-$HEAD.json" "$TMP/resolved/"
decide "6'. a thread resolution re-evaluates" eval "$TMP/resolved"
# 5'. After a push the old head's marker lives on the old head only; the
# new head has no published run with one.
cp "$TMP/base/runs-$HEAD.json" "$TMP/pushed/"
runs "$TMP/pushed" "$HEAD2" "[]"
rc=0; FIX="$TMP/pushed" gif_decide "$REPO" "$PR" "$HEAD2" "$CTX" "$REV" || rc=$?
[ "$rc" -ne 0 ] && pass "5'. a push re-evaluates ($GIF_REASON)" || fail "5'. a push re-evaluates"

# 8. Negative controls on the published side, all on the unchanged state.
neg() { # label runs-json
  cp -R "$TMP/base" "$TMP/neg"
  runs "$TMP/neg" "$HEAD" "$2"
  decide "8. $1" eval "$TMP/neg"
  rm -rf "$TMP/neg"
}
FRESH=$(ago_iso 60)
neg "missing stored fingerprint" "[$(api_run 500 completed success "" "$FRESH")]"
neg "corrupted stored fingerprint" "[$(api_run 500 completed success "${MARK/a/b}" "$FRESH")]"
neg "truncated stored fingerprint" "[$(api_run 500 completed success "${MARK:0:60}" "$FRESH")]"
neg "marker with trailing text" "[$(api_run 500 completed success "$MARK extra" "$FRESH")]"
neg "marker for another fingerprint" "[$(api_run 500 completed success \
  "$(gif_marker "$CTX" "$(printf 'x' | gif_sha256)")" "$FRESH")]"
neg "red newest run" "[$(api_run 500 completed failure "$MARK" "$FRESH")]"
neg "pending newest run (a hold)" "[$(api_run 500 completed success "$MARK" "$FRESH"), $(api_run 501 in_progress "" "" "")]"
neg "older match under a newer green without one" "[$(api_run 500 completed success "$MARK" "$FRESH"), $(api_run 501 completed success "" "$FRESH")]"
neg "job-native run carrying the marker" "[$(api_run 500 completed success "$MARK" "$FRESH" \
  "https://github.com/acme/widgets/actions/runs/9/job/1" "uuid-1")]"
neg "Actions external_id carrying the marker" "[$(api_run 500 completed success "$MARK" "$FRESH" "" "uuid-1")]"
neg "stale verdict (older than GIF_MAX_AGE_SECONDS)" "[$(api_run 500 completed success "$MARK" "$(ago_iso 4000)")]"
neg "no published run" "[]"
neg "unparseable completion time" "[$(api_run 500 completed success "$MARK" "yesterday")]"
FAIL_READ=check-runs decide "8. unreadable run listing" eval "$TMP/base"
GIF_MAX_AGE_SECONDS=abc decide "8. malformed GIF_MAX_AGE_SECONDS" eval "$TMP/base"
# The newest run decides even when an older one matches: ids, not order.
neg "newest by id, listed first" "[$(api_run 502 completed failure "" "$FRESH"), $(api_run 500 completed success "$MARK" "$FRESH")]"

echo "gate-input-fingerprint: fail toward re-evaluating"
nofp() { # label env-assignment...
  local label="$1"; shift
  if env "$@" FIX="$TMP/base" bash -c '. "$1"; gif_compute "$2" "$3" "$4" "$5" "$6"' _ \
      "$LIB" "$REPO" "$PR" "$HEAD" "${CTX_OVERRIDE:-$CTX}" "${REV_OVERRIDE:-$REV}" >/dev/null 2>&1; then
    fail "9. $label computes no fingerprint"
  else
    pass "9. $label computes no fingerprint"
  fi
}
for ep in /pulls/7/reviews /pulls/7/comments /issues/7/comments graphql; do
  nofp "failed read of $ep" FAIL_READ="$ep"
done
cp -R "$TMP/base" "$TMP/nopr"; rm "$TMP/nopr/pr.json"
FIX="$TMP/nopr" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" "$REV" >/dev/null 2>&1 \
  && fail "9. failed PR read computes no fingerprint" || pass "9. failed PR read computes no fingerprint"
cp -R "$TMP/base" "$TMP/noissue"; rm "$TMP/noissue/issue.json"
FIX="$TMP/noissue" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" "$REV" >/dev/null 2>&1 \
  && fail "9. failed issue read computes no fingerprint" || pass "9. failed issue read computes no fingerprint"
cp -R "$TMP/base" "$TMP/manythreads"
jq '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage = true' \
  "$TMP/base/threads.json" >"$TMP/manythreads/threads.json"
FIX="$TMP/manythreads" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" "$REV" >/dev/null 2>&1 \
  && fail "9. more than one page of threads computes no fingerprint" \
  || pass "9. more than one page of threads computes no fingerprint"
cp -R "$TMP/base" "$TMP/gqlerr"
jq '. + {errors: [{message: "boom"}]}' "$TMP/base/threads.json" >"$TMP/gqlerr/threads.json"
FIX="$TMP/gqlerr" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" "$REV" >/dev/null 2>&1 \
  && fail "9. a GraphQL error computes no fingerprint" || pass "9. a GraphQL error computes no fingerprint"
cp -R "$TMP/base" "$TMP/notlist"
echo '{"message": "Not Found"}' >"$TMP/notlist/reviews.json"
FIX="$TMP/notlist" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" "$REV" >/dev/null 2>&1 \
  && fail "9. a non-list review page computes no fingerprint" || pass "9. a non-list review page computes no fingerprint"
FIX="$TMP/base" gif_compute "$REPO" "$PR" "$HEAD" "Codex P1 unresolved threads" "$REV" >/dev/null 2>&1 \
  && fail "9. an unsupported context computes no fingerprint" || pass "9. an unsupported context computes no fingerprint"
FIX="$TMP/base" gif_compute "$REPO" "$PR" "$HEAD" "$CTX" "not-a-sha" >/dev/null 2>&1 \
  && fail "9. a malformed trusted revision computes no fingerprint" || pass "9. a malformed trusted revision computes no fingerprint"
gif_marker "$CTX" "${H:0:63}" >/dev/null && fail "9. a malformed hex has no marker" || pass "9. a malformed hex has no marker"
rc=0; FAIL_READ=graphql FIX="$TMP/base" gif_decide "$REPO" "$PR" "$HEAD" "$CTX" "$REV" || rc=$?
[ "$rc" -ne 0 ] && [ -z "$GIF_HEX" ] && pass "9. gif_decide without a fingerprint re-evaluates with an empty GIF_HEX" \
  || fail "9. gif_decide without a fingerprint re-evaluates with an empty GIF_HEX"

echo
echo "gate-input-fingerprint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
