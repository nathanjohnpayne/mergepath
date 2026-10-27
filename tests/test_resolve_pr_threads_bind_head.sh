#!/usr/bin/env bash
# tests/test_resolve_pr_threads_bind_head.sh — #2727 (ADR 0004, caller C17)
#
# `--bind-head` binds a --resolve-actioned run to one head/base pair:
#   * it refuses (exit 5) a PR that is not open against the default branch;
#   * it captures the live head and base SHAs before any evidence is read;
#   * evidence must apply to that pair: the fix-commit list must end at the
#     captured head, a reply's cited commits must be in that list, and local
#     ledger rows (which name no head) are not accepted;
#   * it re-reads the pair before every write. A pair that moves before any
#     write re-runs against a fresh capture (at most twice); after a write it
#     stops every remaining resolution (exit 5); a failed re-read stops too
#     (exit 4).
# --ci-app-identity implies it.
#
# The gh stub replays a scripted sequence of pairs: pair read k returns line k
# (the last line sticks), the HEAD read returns the next unread line's head, and
# the commit list ends at the head of the pair last served. So each case moves
# the pair at an exact point: read 1 is the capture, read 2 precedes the tag
# reply, read 3 precedes the resolve. COMMITS_LAST pins the list's last SHA.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-pr-threads.sh"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/rpt-bind.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Fixture tree: the real resolver plus no-op preflight and identity stubs, as
# in test_resolve_pr_threads_rationale_tag.sh. Identity is not under test.
FIX="$SCRATCH/repo"
mkdir -p "$FIX/scripts/lib" "$FIX/.github"
cp "$SCRIPT" "$FIX/scripts/resolve-pr-threads.sh"
printf 'auto_source_preflight() { :; }\n' > "$FIX/scripts/lib/preflight-helpers.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/scripts/identity-check.sh"
chmod +x "$FIX/scripts/identity-check.sh"

H0=1111111111111111111111111111111111111111
H1=3333333333333333333333333333333333333333
H2=4444444444444444444444444444444444444444
H3=5555555555555555555555555555555555555555
B0=2222222222222222222222222222222222222222
C1=abc1234567890abcdef1234567890abcdef12345

STATE="$SCRATCH/state"
mkdir -p "$STATE"

cat > "$SCRATCH/gh" <<'GH_STUB'
#!/usr/bin/env bash
# Every call is logged; mutations are recognized from the query text.
all="$*"
printf '%s\n' "$all" >> "$STATE/argv"
current_pair() { head -1 "$STATE/pairs"; }
pop_pair() {
  local n; n=$(wc -l < "$STATE/pairs" | tr -d ' ')
  if [ "$n" -gt 1 ]; then tail -n +2 "$STATE/pairs" > "$STATE/pairs.tmp"; mv "$STATE/pairs.tmp" "$STATE/pairs"; fi
}
case "$1 $2" in
  "api graphql")
    case "$all" in
      *addPullRequestReviewThreadReply*) echo "WRITE tag" >> "$STATE/writes"
        # TAG_LOST=1: GitHub persists the first tag, but the response is lost.
        if [ -s "$STATE/tag_lost" ]; then rm -f "$STATE/tag_lost"; echo "gh: connection reset" >&2; exit 1; fi
        echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C1"}}}}' ;;
      *resolveReviewThread*) echo "WRITE resolve" >> "$STATE/writes"
        # RESOLVE_LOST=1: GitHub persists the first resolve, but the response is lost.
        if [ -s "$STATE/resolve_lost" ]; then rm -f "$STATE/resolve_lost"; echo "gh: connection reset" >&2; exit 1; fi
        echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}' ;;
      *"nodes(ids:"*) echo '{"data":{"nodes":[{"id":"PRT_1","isResolved":true}]}}' ;;
      *) cat "$STATE/threads" ;;
    esac ;;
  "api repos/test/repo")
    cat "$STATE/default" ;;
  "api repos/test/repo/pulls/7")
    line=$(current_pair)
    if [ "$line" = FAIL ]; then echo "gh: connection reset" >&2; exit 1; fi
    case "$all" in
      *".base.sha"*) echo "pair" >> "$STATE/pairreads"; pop_pair; printf '%s\n' "$line" > "$STATE/last_pair"; echo "$line" ;;
      *) echo "${line%% *}" ;;
    esac ;;
  "api repos/test/repo/pulls/7/files"*) echo '["docs/notes.md"]' ;;
  "api repos/test/repo/pulls/7/commits"*)
    # The commit list ends at the head of the pair last served (the state the
    # resolver last observed), unless the case pins a stale last commit; C1 is
    # always an earlier commit of the PR.
    h=$(cat "$STATE/last_pair" 2>/dev/null || current_pair); h="${h%% *}"
    [ -s "$STATE/stale_last" ] && h=$(cat "$STATE/stale_last")
    # COMMIT_COUNT=N pads the list with older commits to N entries in all.
    n=$(cat "$STATE/commit_count" 2>/dev/null || echo 2)
    jq -nc --arg c1 "$C1" --arg h "$h" --argjson n "$n" '
      [range(0; $n - 2) | . as $i | {sha: ("a" + ($i | tostring) + ("0" * (39 - ($i | tostring | length)))),
                                    login: "nathanpayne-claude", date: "2025-12-01T00:00:00Z"}]
      + [{sha: $c1, login: "nathanpayne-claude", date: "2026-01-02T00:00:00Z"},
         {sha: $h, login: "nathanpayne-claude", date: "2026-01-03T00:00:00Z"}]' \
    | { pg=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p'); pg=${pg:-1}
        jq -c --argjson p "$pg" '.[(($p - 1) * 100):($p * 100)]'; } ;;
  "api repos/test/repo/commits/"*)
    # C1 touches the finding's file, so it is fix-commit evidence.
    # NO_FIX=1 makes it touch nothing, so no fix-commit evidence exists.
    if [ -s "$STATE/no_fix" ]; then echo '[]'; else
      case "$2" in *"$C1"*) echo '["docs/notes.md"]' ;; *) echo '[]' ;; esac
    fi ;;
  *) echo '{}' ;;
esac
exit 0
GH_STUB
chmod +x "$SCRATCH/gh"

threads_with_reply() {
  local reply="$1"
  jq -n --arg reply "$reply" '{data:{repository:{pullRequest:{reviewThreads:{totalCount:1,pageInfo:{hasNextPage:false,endCursor:null},nodes:[
    {id:"PRT_1",isResolved:false,isOutdated:false,
     commentsFirst:{nodes:[{author:{login:"coderabbitai"},path:"docs/notes.md",body:"A finding",createdAt:"2026-01-01T00:00:00Z"}]},
     commentsLast:{nodes:[{commit:{oid:"x"}}]},
     allComments:{nodes:[
       {author:{login:"coderabbitai"},body:"A finding",databaseId:5001,createdAt:"2026-01-01T00:00:00Z"},
       {author:{login:"nathanpayne-claude"},body:$reply,databaseId:5002,createdAt:"2026-01-02T00:00:00Z"}]}}]}}}}}'
}

threads_bot_only() {
  jq -n '{data:{repository:{pullRequest:{reviewThreads:{totalCount:1,pageInfo:{hasNextPage:false,endCursor:null},nodes:[
    {id:"PRT_1",isResolved:false,isOutdated:false,
     commentsFirst:{nodes:[{author:{login:"coderabbitai"},path:"docs/notes.md",body:"A finding",createdAt:"2026-01-01T00:00:00Z"}]},
     commentsLast:{nodes:[{commit:{oid:"x"}}]},
     allComments:{nodes:[{author:{login:"coderabbitai"},body:"A finding",databaseId:5001,createdAt:"2026-01-01T00:00:00Z"}]}}]}}}}}'
}

threads_with_two_replies() {
  jq -n --arg r1 "$1" --arg r2 "$2" '{data:{repository:{pullRequest:{reviewThreads:{totalCount:1,pageInfo:{hasNextPage:false,endCursor:null},nodes:[
    {id:"PRT_1",isResolved:false,isOutdated:false,
     commentsFirst:{nodes:[{author:{login:"coderabbitai"},path:"docs/notes.md",body:"A finding",createdAt:"2026-01-01T00:00:00Z"}]},
     commentsLast:{nodes:[{commit:{oid:"x"}}]},
     allComments:{nodes:[
       {author:{login:"coderabbitai"},body:"A finding",databaseId:5001,createdAt:"2026-01-01T00:00:00Z"},
       {author:{login:"nathanpayne-claude"},body:$r1,databaseId:5002,createdAt:"2026-01-02T00:00:00Z"},
       {author:{login:"nathanpayne-claude"},body:$r2,databaseId:5003,createdAt:"2026-01-03T00:00:00Z"}]}}]}}}}}'
}

REBUTTAL="Disagree: this is intentional for the propagation path, see the design note."

# run_case <pairs (one per line)> <reply> [extra args...] — rc in $rc, output in $out.
run_case() {
  local pairs="$1" reply="$2"; shift 2
  rm -f "$STATE"/*
  printf '%s\n' "$pairs" > "$STATE/pairs"
  printf 'main\n' > "$STATE/default"
  threads_with_reply "$reply" > "$STATE/threads"
  [ -z "${COMMITS_LAST:-}" ] || printf '%s' "$COMMITS_LAST" > "$STATE/stale_last"
  [ "${BOT_ONLY:-}" != 1 ] || threads_bot_only > "$STATE/threads"
  [ "${NO_FIX:-}" != 1 ] || echo 1 > "$STATE/no_fix"
  [ "${TAG_LOST:-}" != 1 ] || echo 1 > "$STATE/tag_lost"
  [ "${RESOLVE_LOST:-}" != 1 ] || echo 1 > "$STATE/resolve_lost"
  [ -z "${COMMIT_COUNT:-}" ] || echo "$COMMIT_COUNT" > "$STATE/commit_count"
  # TWO_THREADS=1: a second, identical thread, so a second write follows.
  if [ "${TWO_THREADS:-}" = 1 ]; then
    jq -c '.data.repository.pullRequest.reviewThreads |= (.totalCount = 2
      | .nodes += [.nodes[0] | .id = "PRT_2"])' "$STATE/threads" > "$STATE/threads.2"
    mv "$STATE/threads.2" "$STATE/threads"
  fi
  [ -z "${SECOND_REPLY:-}" ] || threads_with_two_replies "$reply" "$SECOND_REPLY" > "$STATE/threads"
  : > "$STATE/argv"; : > "$STATE/writes"; : > "$STATE/pairreads"
  out=$(cd "$FIX" && STATE="$STATE" C1="$C1" PATH="$SCRATCH:$PATH" \
    RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=1 \
    MERGEPATH_FEEDBACK_LEDGER_DIR="${LEDGER_DIR:-$SCRATCH/noledger}" \
    env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN -u RESOLVE_PR_THREADS_BIND_ATTEMPT \
    bash scripts/resolve-pr-threads.sh 7 --repo test/repo "$@" 2>&1)
  rc=$?
}
writes() { wc -l < "$STATE/writes" | tr -d ' '; }
pairreads() { wc -l < "$STATE/pairreads" | tr -d ' '; }
show() { echo "    rc=$rc writes=$(writes) pairreads=$(pairreads)" >&2; echo "$out" | sed 's/^/      /' >&2; }

P0="$H0 $B0 main open"

echo "Test 1: a steady pair on a default-branch PR resolves, re-reading the pair before each write"
run_case "$P0" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 0 ] && [ "$(writes)" -eq 2 ] && [ "$(pairreads)" -ge 3 ] \
   && grep -q "BIND: captured head 111111111111 and base 222222222222 (main)" <<<"$out"; then
  ok "resolved with the capture plus a re-read before the tag reply and before the resolve"
else bad "steady-pair resolve"; show; fi

echo "Test 2: a PR targeting another branch is refused before any read of evidence or write"
run_case "$H0 $B0 release open" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && [ "$(writes)" -eq 0 ] && grep -q "not the default branch 'main'" <<<"$out" \
   && ! grep -q "reviewThreads" "$STATE/argv"; then
  ok "non-default base refused with exit 5, threads never enumerated"
else bad "non-default base"; show; fi

echo "Test 3: a closed PR is refused"
run_case "$H0 $B0 main closed" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && [ "$(writes)" -eq 0 ] && grep -q "not open" <<<"$out"; then
  ok "closed PR refused with exit 5"
else bad "closed PR"; show; fi

echo "Test 4: a pair that moves before the first write re-runs against a fresh capture"
run_case "$P0
$H1 $B0 main open" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 0 ] && [ "$(writes)" -eq 2 ] && grep -q "re-evaluating against a fresh head/base capture (restart 1 of 2" <<<"$out" \
   && grep -q "BIND: captured head 333333333333" <<<"$out"; then
  ok "restarted once, then resolved on the new head"
else bad "restart before write"; show; fi

echo "Test 5: a pair that moves after the tag reply stops before the resolve"
run_case "$P0
$P0
$H1 $B0 main open" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && grep -q "WRITE tag" "$STATE/writes" && ! grep -q "WRITE resolve" "$STATE/writes" \
   && grep -q "already attempted" <<<"$out"; then
  ok "stopped with exit 5 after the tag, no resolve"
else bad "stop after a write"; show; fi

echo "Test 5b: a tag reply whose response is lost still counts as a write"
TAG_LOST=1 run_case "$P0
$P0
$H1 $B0 main open" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && [ "$(grep -c 'WRITE tag' "$STATE/writes")" -eq 1 ] && ! grep -q "WRITE resolve" "$STATE/writes" \
   && grep -q "already attempted 1 write" <<<"$out"; then
  ok "an accepted-but-unconfirmed tag stops the run instead of restarting it"
else bad "lost tag response"; show; fi

echo "Test 5c: a resolve whose response is lost still counts as a write"
# Two threads, no tag replies: capture, then two re-reads per thread. The pair
# moves before the second thread's writes, after the first resolve was
# accepted but its response lost.
TWO_THREADS=1 RESOLVE_LOST=1 run_case "$P0
$P0
$P0
$H1 $B0 main open" "$REBUTTAL" --resolve-actioned --bind-head --no-tag-reply
# Exit 2, not 5: the unconfirmed mutation is a failure, which takes precedence.
if [ "$rc" -eq 2 ] && [ "$(grep -c 'WRITE resolve' "$STATE/writes")" -eq 1 ] \
   && grep -q "already attempted 1 write" <<<"$out"; then
  ok "an accepted-but-unconfirmed resolve stops the run (exit 2) instead of restarting it"
else bad "lost resolve response"; show; fi

echo "Test 6: a base that moves counts as a moved pair"
run_case "$P0
$P0
$H0 $H3 main open" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && ! grep -q "WRITE resolve" "$STATE/writes"; then
  ok "a moved base stops the resolve"
else bad "moved base"; show; fi

echo "Test 7: a pair that keeps moving spends the restart budget and writes nothing"
run_case "$P0
$H1 $B0 main open
$H1 $B0 main open
$H2 $B0 main open
$H2 $B0 main open
$H3 $B0 main open" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && [ "$(writes)" -eq 0 ] && grep -q "re-evaluation budget (2) is spent" <<<"$out"; then
  ok "budget spent, exit 5, no write"
else bad "restart budget"; show; fi

echo "Test 8: a commit list that does not end at the captured head is not evidence"
COMMITS_LAST="$H2" run_case "$P0" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && [ "$(writes)" -eq 0 ] && grep -q "commit list ends at $H2" <<<"$out"; then
  ok "stale commit list refused after the restart budget, no write"
else bad "stale commit list"; show; fi

echo "Test 8b: a commit list at the endpoint's 250-commit cap may be incomplete and is not evidence"
COMMIT_COUNT=250 run_case "$P0" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 5 ] && [ "$(writes)" -eq 0 ] && grep -q "commit list has 250 commits" <<<"$out"; then
  ok "a capped list stops the run with exit 5, no write"
else bad "capped commit list"; show; fi
COMMIT_COUNT=249 run_case "$P0" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "a 249-commit list ending at the head is accepted"
else bad "249-commit list"; show; fi

echo "Test 8c: a citation of the FIRST commit in a long list is bound (no SIGPIPE false negative)"
EARLY=a000000000
for attempt in 1 2 3; do
  COMMIT_COUNT=249 run_case "$P0" "Disagree: $EARLY already makes this path intentional, see the design note." --resolve-actioned --bind-head
  [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes" || break
done
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "an early citation in a 249-commit list resolves on every attempt"
else bad "early citation in a long list"; show; fi
# The race is timing-dependent, so also hold the shape: the membership test
# must not pipe into an early-exiting reader.
bind_fn=$(sed -n '/^bind_reply_commits_bound() {/,/^}/p' "$SCRIPT" | grep -v '^[[:space:]]*#')
if [ -n "$bind_fn" ] && ! grep -Eq '[|][[:space:]]*grep -q' <<<"$bind_fn"; then
  ok "bind_reply_commits_bound pipes nothing into grep -q"
else bad "bind_reply_commits_bound still pipes into grep -q"; fi

UNBOUND_REPLY="Disagree: this was already handled by deadbee1234 on another branch, intentional."
echo "Test 9: a reply citing a commit outside the captured head is not evidence"
run_case "$P0" "$UNBOUND_REPLY" --resolve-actioned --bind-head
if [ "$rc" -eq 3 ] && [ "$(writes)" -eq 0 ] && grep -q "never dispositioned" <<<"$out"; then
  ok "unbound citation left the thread open (exit 3)"
else bad "unbound citation"; show; fi
run_case "$P0" "$UNBOUND_REPLY" --resolve-actioned
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "control: the same reply resolves without --bind-head"
else bad "unbound-citation control"; show; fi

echo "Test 10: a reply citing one of the captured head's commits is evidence"
run_case "$P0" "Disagree: ${C1:0:10} already makes this path intentional, see the design note." --resolve-actioned --bind-head
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "bound citation resolves"
else bad "bound citation"; show; fi

echo "Test 11: comment IDs and plain words are not read as commit citations"
run_case "$P0" "Disagree: see comment 4383337359; the defaced example is intentional by design." --resolve-actioned --bind-head
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "numeric IDs and hex-letter words do not block the evidence"
else bad "non-SHA tokens"; show; fi

echo "Test 12: a failed re-read stops before the write (exit 4)"
COMMITS_LAST="$H0" run_case "$P0
FAIL" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 4 ] && [ "$(writes)" -eq 0 ] && grep -q "could not re-read" <<<"$out"; then
  ok "re-read failure stops with exit 4, no write"
else bad "re-read failure"; show; fi

echo "Test 13: --bind-head is only valid with --resolve-actioned"
run_case "$P0" "$REBUTTAL" --auto-resolve-bots --bind-head
if [ "$rc" -eq 1 ] && grep -q "valid only with --resolve-actioned (#2727)" <<<"$out"; then
  ok "refused with exit 1"
else bad "mode restriction"; show; fi

echo "Test 14: --ci-app-identity implies --bind-head"
run_case "$H0 $B0 release open" "$REBUTTAL" --resolve-actioned --ci-app-identity --dry-run
if [ "$rc" -eq 5 ] && grep -q "not the default branch" <<<"$out"; then
  ok "the CI-app mode refuses a non-default base without --bind-head"
else bad "ci-app implies bind"; show; fi

echo "Test 15: without --bind-head the resolver reads no pair (unchanged local path)"
run_case "$H0 $B0 release open" "$REBUTTAL" --resolve-actioned
if [ "$rc" -eq 0 ] && [ "$(pairreads)" -eq 0 ]; then
  ok "no pair read and no refusal on the default path"
else bad "default path unchanged"; show; fi

echo "Test 17: a second citation one separator after a bound one is still checked"
run_case "$P0" "Disagree: ${C1:0:10} deadbee1234 make this path intentional, see the design note." --resolve-actioned --bind-head
if [ "$rc" -eq 3 ] && [ "$(writes)" -eq 0 ]; then
  ok "the unbound second SHA left the thread open"
else bad "adjacent citations"; show; fi

echo "Test 18: an unbound rebuttal cannot set the class when a later bound reply exists"
# No fix commit, a long rebuttal citing a commit outside the head, then a short
# bound acknowledgement. Unbound, the stale rebuttal classifies the thread and
# the acknowledgement dispositions it; bound, the rebuttal is not evidence.
NO_FIX=1 SECOND_REPLY="Ack, see ${C1:0:10}." run_case "$P0" \
  "Disagree: deadbee1234 already handled this, it is intentional by design here." --resolve-actioned --bind-head
if [ "$rc" -eq 3 ] && [ "$(writes)" -eq 0 ]; then
  ok "the unbound rebuttal did not classify the thread; left open"
else bad "classification binding"; show; fi
NO_FIX=1 SECOND_REPLY="Ack, see ${C1:0:10}." run_case "$P0" \
  "Disagree: deadbee1234 already handled this, it is intentional by design here." --resolve-actioned
if [ "$rc" -eq 0 ] && grep -q "mergepath-resolve: rebuttal-recorded" "$STATE/argv"; then
  ok "control: without --bind-head the unbound rebuttal sets rebuttal-recorded and resolves"
else bad "classification control"; show; fi

echo "Test 16: a local ledger row (which names no head) is not evidence under --bind-head"
LEDGER_DIR="$SCRATCH/ledger"; mkdir -p "$LEDGER_DIR"
printf '%s\n' '{"comment_id":5001,"repo":"test/repo","verdict":"fixed","recorded_at":"2026-01-02T00:00:00Z"}' \
  > "$LEDGER_DIR/coderabbit-feedback-ledger.jsonl"
LEDGER_DIR="$LEDGER_DIR" BOT_ONLY=1 run_case "$P0" "" --resolve-actioned
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "control: the fix commit plus the ledger verdict resolve without --bind-head"
else bad "ledger control"; show; fi
LEDGER_DIR="$LEDGER_DIR" BOT_ONLY=1 run_case "$P0" "" --resolve-actioned --bind-head
if [ "$rc" -eq 3 ] && [ "$(writes)" -eq 0 ] && grep -q "never dispositioned" <<<"$out"; then
  ok "ledger-only evidence left the thread open under --bind-head"
else bad "ledger under bind"; show; fi

echo "Test 19: a stale local deferral row does not block a bound reply under --bind-head"
printf '%s\n' '{"comment_id":5001,"repo":"test/repo","verdict":"deferred","disposition":"deferred-to-followup","recorded_at":"2026-01-02T00:00:00Z"}' \
  > "$LEDGER_DIR/coderabbit-feedback-ledger.jsonl"
LEDGER_DIR="$LEDGER_DIR" run_case "$P0" "$REBUTTAL" --resolve-actioned
if [ "$rc" -eq 3 ] && [ "$(writes)" -eq 0 ]; then
  ok "control: without --bind-head the local deferral keeps the thread open"
else bad "deferral control"; show; fi
LEDGER_DIR="$LEDGER_DIR" run_case "$P0" "$REBUTTAL" --resolve-actioned --bind-head
if [ "$rc" -eq 0 ] && grep -q "WRITE resolve" "$STATE/writes"; then
  ok "the ledger is not read under --bind-head; the bound rebuttal resolves"
else bad "deferral under bind"; show; fi

echo
echo "test_resolve_pr_threads_bind_head: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
