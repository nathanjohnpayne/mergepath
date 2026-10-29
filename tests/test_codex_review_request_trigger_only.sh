#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's --trigger-only mode (#489),
# used by coderabbit-wait.sh's rate-limit failover.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so the
# trigger-only path is deterministic and makes no GitHub writes. Verifies:
#   - fresh HEAD: posts exactly ONE @codex trigger, exits 0 WITHOUT polling and
#     WITHOUT an ack-retry (the trigger-only exit is before run_trigger_ack_gate
#     — Codex P2 #3 on #512); JSON carries trigger_only:true, trigger_posted:true.
#   - idempotent: an existing author @codex trigger on HEAD → skips the post
#     (trigger_posted:false), exits 0.
#   - author-scoped (Codex P2 #1 on #512): a *reviewer*-authored @codex review
#     does NOT count as a valid trigger → still posts.
#
# Cases D–K cover #798: the AUTOMATIC trigger must not fire on a content-free
# `update-branch` head, while an agent's explicit trigger and any head with a
# real content change still post. See the section header above case D for how
# the three layers (gate decision, call-site wiring, workflow declaration) are
# split and why each pair is non-vacuous.
#
# Bash 3.2 portable. Mirrors tests/test_codex_review_request_ack.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-trigger-only.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
# The requester counts solicited blocking reviews from the Codex review ledger
# before every new request (#1560 slice 3). This stub reports a ledger with no
# responses for whatever head the requester expects, so the blocking-review
# budget never stops these cases; test_codex_review_request_trigger_only.sh
# covers the budget itself.
LEDGER_STUB="$WORKDIR/codex-ledger-stub.sh"
cat >"$LEDGER_STUB" <<'LEDGER_EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  case "$1" in --expect-head) head=$2; shift 2 ;; --expect-policy) fp=$2; shift 2 ;; *) shift ;; esac
done
jq -nc --arg h "$head" --arg fp "${fp:-}" --arg a "${CODEX_LEDGER_STUB_AUTHOR:-nathanjohnpayne}" \
  '{head_sha: $h, author: $a, max_blocking_reviews: 10, policy_fingerprint: $fp, responses: []}'
LEDGER_EOF
chmod +x "$LEDGER_STUB"
export MERGEPATH_CODEX_LEDGER_CMD="$LEDGER_STUB"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/scripts/workflow" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"   # #799, hard-sourced
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced
  cp "$ROOT/scripts/lib/codex-request-evidence.sh" "$dir/scripts/lib/codex-request-evidence.sh"
  mkdir -p "$dir/scripts/workflow"
  cp "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" "$dir/scripts/workflow/resolve-codex-verdict-anchors.py"
  cp "$ROOT/scripts/lib/codex-failure-markers.sh" "$dir/scripts/lib/codex-failure-markers.sh"
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
  cp "$ROOT/scripts/workflow/resolve_base_policy.sh" "$dir/scripts/workflow/resolve_base_policy.sh"
  cp "$ROOT/scripts/workflow/external_review_fingerprint.sh" "$dir/state/base-fingerprint.sh"  # #2257: served at the base by the stub
  cp "$ROOT/scripts/workflow/match_protected_paths.sh" "$dir/state/base-matcher.sh"  # #2257: served at the base by the stub
  cp "$ROOT/scripts/workflow/parse_policy_list.sh" "$dir/state/base-parser.sh"  # #2257: served at the base by the stub
  cp "$ROOT/scripts/workflow/match_protected_paths.sh" "$dir/scripts/workflow/match_protected_paths.sh"  # #2272: the copy that runs
  cp "$ROOT/scripts/workflow/parse_policy_list.sh" "$dir/scripts/workflow/parse_policy_list.sh"  # #2272: the copy that runs
  chmod +x "$dir/scripts/workflow/resolve_base_policy.sh"

  cat >"$dir/.github/review-policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  request_by_default: true  # #2240: absent now means false; these cases exercise the request itself
  review_timeout_seconds: 0
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: 0
  max_ack_retries: 2
EOF
  cp "$dir/.github/review-policy.yml" "$dir/state/base-review-policy.yml"

  # gh-as-author stub: records each @codex trigger post.
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
# #2657: the request checkpoint posts through --body-file; record it apart
# from triggers so trigger counts stay exact. It must never carry the phrase.
prev=""
for arg in "$@"; do
  if [ "$prev" = "--body-file" ] && grep -Fq 'mergepath-codex-request-checkpoint:v1' "$arg"; then
    if grep -Eiq '@codex[[:space:]]+review' "$arg"; then echo "checkpoint carried the trigger phrase" >&2; exit 97; fi
    [ "${CODEX_TEST_CHECKPOINT_FAIL:-0}" != 1 ] || { echo "checkpoint write refused" >&2; exit 1; }
    n=0; [ -f "$state_dir/checkpoint-count" ] && n=$(cat "$state_dir/checkpoint-count")
    n=$((n + 1)); printf '%s\n' "$n" >"$state_dir/checkpoint-count"; cp "$arg" "$state_dir/checkpoint-$n.md"
    printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$((5000 + n))"
    exit 0
  fi
  prev="$arg"
done
if [ "${9:-}" != "@codex review" ]; then
  echo "trigger body was not exact '@codex review': $*" >&2; exit 98
fi
# #2657: a refused trigger write (the loser of a concurrent request).
[ "${CODEX_TEST_TRIGGER_FAIL:-0}" != 1 ] || { echo "trigger write refused" >&2; exit 1; }
count=0
[ -f "$state_dir/trigger-count" ] && count=$(cat "$state_dir/trigger-count")
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/trigger-count"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$((1000 + count))"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${CODEX_TEST_SCENARIO:?}
head_sha=${CODEX_TEST_HEAD:-head-sha}
author='nathanjohnpayne'
reviewer='nathanpayne-codex'
t=${CODEX_TEST_HEAD_DATE-2026-06-04T00:00:00Z}
old='2026-06-03T00:00:00Z'
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
paginated=0
[ "${1:-}" = "--paginate" ] && { paginated=1; shift; }
# The #2166 check-runs read is `gh api -X GET <endpoint> -f check_name=... -F per_page=100`.
[ "${1:-}" = "-X" ] && shift 2
endpoint=${1:-}
case "$endpoint" in
  # labels and changed_files feed the #2257 Phase 4 gate derivation, which the
  # request_by_default: false cases reach; the default PR is under-threshold.
  repos/owner/repo/pulls/999)
    freshness_base=base-sha
    if [ -f "$CODEX_TEST_STATE_DIR/freshness-scan-complete" ]; then
      case "${CODEX_TEST_FRESHNESS_TRANSITION:-}" in
        shrink|expand|base-only) freshness_base=base-next ;;
        unreadable-pr) echo 'simulated changed-base metadata read failure' >&2; exit 1 ;;
      esac
    fi
    if [ "${2:-}" = "--jq" ]; then printf '%s\n' "$head_sha"   # the #2257 head re-read
    else jq -cn --arg h "$head_sha" --arg b "$freshness_base" '{head:{sha:$h,ref:"feature"},base:{ref:"main",sha:$b,repo:{default_branch:"main"}},labels:[],changed_files:1}'; fi ;;
  repos/owner/repo/pulls/999/files)      printf '%s\n' '[{"filename":"src/app.ts","additions":10,"deletions":2}]' ;;
  repos/owner/repo/branches/main)        printf '%s\n' '{"name":"main","commit":{"sha":"main-sha-1"}}' ;;  # #2257 default-branch pin
  'repos/owner/repo/contents/scripts/workflow/parse_policy_list.sh?ref=base-sha')
    jq -cn --arg c "$(base64 <"$CODEX_TEST_STATE_DIR/base-parser.sh" | tr -d '\n')" '{encoding: "base64", content: $c}' ;;
  'repos/owner/repo/contents/scripts/workflow/match_protected_paths.sh?ref=base-sha')
    jq -cn --arg c "$(base64 <"$CODEX_TEST_STATE_DIR/base-matcher.sh" | tr -d '\n')" '{encoding: "base64", content: $c}' ;;
  'repos/owner/repo/contents/scripts/workflow/external_review_fingerprint.sh?ref=base-sha')
    # #2257: the fingerprint helper at the base, for its EXCLUDE_RE constant.
    jq -cn --arg c "$(base64 <"$CODEX_TEST_STATE_DIR/base-fingerprint.sh" | tr -d '\n')" '{encoding: "base64", content: $c}' ;;
  'repos/owner/repo/contents/.github/review-policy.yml?ref=base-sha'|'repos/owner/repo/contents/.github/review-policy.yml?ref=base-next')
    printf '1\n' >>"$CODEX_TEST_STATE_DIR/base-policy-read-count"
    if [ "${CODEX_TEST_BASE_POLICY_MODE:-ok}" = fail ]; then
      echo 'simulated governing policy read failure' >&2
      exit 1
    fi
    if [ -f "$CODEX_TEST_STATE_DIR/freshness-scan-complete" ]; then
      case "${CODEX_TEST_FRESHNESS_TRANSITION:-}" in
        unreadable-policy) echo 'simulated governing policy read failure after scan' >&2; exit 1 ;;
        shrink|expand|cap-change) cat "$CODEX_TEST_STATE_DIR/base-review-policy-next.yml"; exit 0 ;;
      esac
    fi
    cat "$CODEX_TEST_STATE_DIR/base-review-policy.yml"
    ;;
  repos/owner/repo/actions/runs)
    # #2166 moving-head guard, default signal: a repo-lint workflow RUN for the
    # head SHA. Default is the ordinary production shape (a completed run) so
    # the guard passes on every pre-existing case through its intended branch.
    case "${CODEX_TEST_LINT_RUNS:-completed}" in
      unreadable) echo 'simulated actions/runs read failure' >&2; exit 1 ;;
      garbage)    printf 'not json\n' ;;
      missing|noworkflow|wfunreadable)
                  printf '{"total_count":0,"workflow_runs":[]}\n' ;;
      # Another workflow's run on the head is not repo-lint.
      otherworkflow) printf '{"total_count":1,"workflow_runs":[{"id":3,"name":"CodeQL","path":".github/workflows/codeql.yml","head_branch":"feature","status":"completed"}]}\n' ;;
      # The same SHA ran repo-lint on ANOTHER branch only: not this PR's push.
      otherbranch)  printf '{"total_count":1,"workflow_runs":[{"id":5,"name":"repo-lint","path":".github/workflows/repo_lint.yml","head_branch":"other","status":"completed"}]}\n' ;;
      # Matched by canonical path even when the display name differs.
      bypath)     printf '{"total_count":1,"workflow_runs":[{"id":4,"name":"renamed lint","path":".github/workflows/repo_lint.yml","head_branch":"feature","status":"queued"}]}\n' ;;
      # Push-dispatch anchor (Codex P2 x2 on #2175): an old run of the SAME SHA
      # on another branch (OTHER), plus two dispatches on the PR branch
      # (STARTED, and a later push of the same SHA, LATER). The anchor is the
      # LATEST dispatch on the PR branch.
      dispatched) jq -cn --arg o "${CODEX_TEST_CHECK_OTHER:-$(jq -rn 'now - 10800 | floor | todate')}" \
                    --arg a "${CODEX_TEST_CHECK_STARTED:?}" --arg b "${CODEX_TEST_CHECK_RERUN:-$CODEX_TEST_CHECK_STARTED}" \
                    --arg first_event "${CODEX_TEST_CHECK_EVENT-pull_request}" --arg last_event "${CODEX_TEST_CHECK_RERUN_EVENT-push}" \
                    '{total_count:3,workflow_runs:[
                      {id:6,name:"repo-lint",path:".github/workflows/repo_lint.yml",head_branch:"other",event:"push",status:"completed",created_at:$o},
                      {id:8,name:"repo-lint",path:".github/workflows/repo_lint.yml",head_branch:"feature",event:$first_event,status:"completed",created_at:$a},
                      {id:9,name:"repo-lint",path:".github/workflows/repo_lint.yml",head_branch:"feature",event:$last_event,status:"completed",created_at:$b}]}' ;;
      *)          jq -cn --arg st "${CODEX_TEST_LINT_RUNS:-completed}" '{total_count:1,workflow_runs:[{id:2,name:"repo-lint",path:".github/workflows/repo_lint.yml",head_branch:"feature",status:$st}]}' ;;
    esac ;;
  repos/owner/repo/actions/workflows)
    case "${CODEX_TEST_LINT_RUNS:-completed}" in
      wfunreadable) echo 'simulated actions/workflows read failure' >&2; exit 1 ;;
      noworkflow)   printf '{"total_count":1,"workflows":[{"id":30,"name":"CodeQL","path":".github/workflows/codeql.yml"}]}\n' ;;
      *)            printf '{"total_count":2,"workflows":[{"id":30,"name":"CodeQL","path":".github/workflows/codeql.yml"},{"id":31,"name":"repo-lint","path":".github/workflows/repo_lint.yml"}]}\n' ;;
    esac ;;
  repos/owner/repo/commits/*/check-suites)
    # Suite 100 is the PR branch (head.ref "feature"); suite 200 another branch.
    case "${CODEX_TEST_SUITE_BRANCH:-known}" in
      unknown) printf '{"total_count":2,"check_suites":[{"id":100,"head_branch":null},{"id":200,"head_branch":"other"}]}\n' ;;
      unrelated-unknown) printf '{"total_count":2,"check_suites":[{"id":100,"head_branch":"feature"},{"id":200,"head_branch":null}]}\n' ;;
      *) jq -cn --arg t "${CODEX_TEST_SUITE_CREATED:-}" '{total_count:2,check_suites:[
           {id:100,head_branch:"feature",created_at:(if $t == "" then null else $t end)},
           {id:200,head_branch:"other",created_at:"2020-01-01T00:00:00Z"}]}' ;;
    esac ;;
  repos/owner/repo/commits/*/check-runs)
    # The codex.request_requires_check OVERRIDE path (exact check-run name).
    # Runs carry check_suite.id 100 (the PR branch) unless the shape says not.
    case "${CODEX_TEST_CHECK_RUNS:-completed}" in
      unreadable) echo 'simulated check-runs read failure' >&2; exit 1 ;;
      dated) jq -cn --arg c "${CODEX_TEST_RUN_CREATED:-}" --arg t "${CODEX_TEST_RUN_STARTED:-}" '
               {total_count:1,check_runs:[{id:1,name:"lint-fast",status:(if $t == "" then "queued" else "completed" end),check_suite:{id:100},
                 created_at:(if $c == "" then null else $c end),
                 started_at:(if $t == "" then null else $t end)}]}' ;;
      missing)    printf '{"total_count":0,"check_runs":[]}\n' ;;
      othername)  printf '{"total_count":1,"check_runs":[{"id":1,"name":"not-lint","status":"completed","check_suite":{"id":100}}]}\n' ;;
      # The deep `lint` job alone must not satisfy an exact `lint-fast`.
      deeplint)   printf '{"total_count":1,"check_runs":[{"id":1,"name":"lint","status":"queued","check_suite":{"id":100}}]}\n' ;;
      # #2173 shards lint-fast into a matrix: lint-fast (1)..(4).
      sharded)    printf '{"total_count":4,"check_runs":[{"id":11,"name":"lint-fast (1)","status":"queued","check_suite":{"id":100}},{"id":12,"name":"lint-fast (2)","status":"queued","check_suite":{"id":100}},{"id":13,"name":"lint-fast (3)","status":"queued","check_suite":{"id":100}},{"id":14,"name":"lint-fast (4)","status":"queued","check_suite":{"id":100}}]}\n' ;;
      # An old exact-name run from the SHA's earlier use on ANOTHER branch.
      othersuite) printf '{"total_count":1,"check_runs":[{"id":21,"name":"lint-fast","status":"completed","started_at":"2026-01-01T00:00:00Z","check_suite":{"id":200}}]}\n' ;;
      # Codex P1 on #2175: the matching run is on PAGE 2, behind a full page of
      # other runs. Emitted only when the caller paginates, the way gh does.
      paged)      jq -cn '{total_count:101,check_runs:[range(100) | {id:(500 + .),name:"other-\(.)",status:"completed",check_suite:{id:100}}]}'
                  # if/fi, not `&&`: a false test must not become the stub's exit
                  # status, or an unpaginated caller reads "unreadable" and the
                  # guard's fail-open masks the missing page.
                  if [ "$paginated" = 1 ]; then printf '{"total_count":101,"check_runs":[{"id":700,"name":"lint-fast","status":"queued","check_suite":{"id":100}}]}\n'; fi ;;
      garbage)    printf 'not json\n' ;;
      *)          jq -cn --arg st "${CODEX_TEST_CHECK_RUNS:-completed}" '{total_count:1,check_runs:[{id:1,name:"lint-fast",status:$st,check_suite:{id:100}}]}' ;;
    esac ;;
  repos/owner/repo/commits/*)     printf '%s\n' "$t" ;;
  repos/owner/repo/issues/999/timeline)  printf '[]\n' ;;
  # #2591: the GraphQL force-push timeline, for heads a force-push replaced.
  graphql)
    case "${CODEX_TEST_FORCE_PUSH:-none}" in
      fail) echo 'simulated GraphQL failure' >&2; exit 1 ;;
      none) printf '%s\n' '{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
      *) jq -cn --arg b "$CODEX_TEST_FORCE_PUSH" '{data:{repository:{pullRequest:{timelineItems:{pageInfo:{hasNextPage:false,endCursor:null},
           nodes:[{beforeCommit:{oid:$b},afterCommit:{oid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}}}}}' ;;
    esac ;;
  # #2553: the PR's commits, for failover markers' heads.
  repos/owner/repo/pulls/999/commits)
    if [ "${CODEX_TEST_COMMITS_FAIL:-0}" = 1 ]; then echo 'simulated commits read failure' >&2; exit 1; fi
    printf '%s\n' '[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' ;;
  repos/owner/repo/pulls/999/reviews)
    case "$scenario" in
      reply-only|body-P1|body-P2)
        body=''; [ "$scenario" = reply-only ] || body="**${scenario#body-} finding**"
        jq -cn --arg h "$head_sha" --arg t "$t" --arg b "$body" '[{id:91,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$h,submitted_at:$t,state:"COMMENTED",body:$b}]' ;;
      *) printf '[]\n' ;;
    esac ;;
  repos/owner/repo/pulls/999/comments)
    if [ "$scenario" = reply-only ]; then
      printf '%s\n' '[{"id":92,"pull_request_review_id":91,"in_reply_to_id":90,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Review Result: Verified commit resolves the reported issue."}]'
    else printf '[]\n'; fi ;;
  repos/owner/repo/issues/999/reactions)
    # #2882: Codex's PR-open auto-review leaves a 👍 on the PR itself.
    if [ "$scenario" = pr_open_reaction ]; then
      jq -cn --arg t "$t" '[{id:9301,user:{login:"chatgpt-codex-connector[bot]"},content:"+1",created_at:$t}]'
    else printf '[]\n'; fi ;;
  repos/owner/repo/issues/999/comments)
    case "$scenario" in
      # #2882: the rest of that auto-review, as tadlockpsychiatry#206 showed
      # it: a Completed, findings-free Review Summary row naming HEAD, and no
      # review object, verdict comment or author trigger.
      pr_open_reaction)
        jq -cn --arg t "$t" --arg h "$head_sha" '[{id:9300,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,updated_at:$t,
           body:("<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 {\"code_review\":{\"commit_sha\":\"" + $h + "\",\"has_any_findings\":false,\"has_unresolved_findings\":false,\"status\":\"completed\"}} -->\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** | `" + $h[0:10] + "` | Pull request opened |\n")}]' ;;
      freshness_author)
        [ -z "${CODEX_TEST_FRESHNESS_TRANSITION:-}" ] || touch "$CODEX_TEST_STATE_DIR/freshness-scan-complete"
        jq -cn --arg who "$author" --arg t "$CODEX_TEST_TRIGGER_AT" '[{id:7050,user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      dup_author)       jq -cn --arg who "$author" --arg t "$t" '[{id:7001,user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      # #2664: the same request, posted a minute before the head was pushed,
      # so it does not hold the current head.
      dup_author_older) jq -cn --arg who "$author" --arg t "$t" '[{id:7001,user:{login:$who},created_at:(($t | fromdateiso8601) - 60 | todateiso8601),body:"@codex review"}]' ;;
      # #2582: the same request, with Codex reporting a review of HEAD Running since.
      dup_author_running)
        jq -cn --arg who "$author" --arg t "$t" --arg h "${head_sha:0:7}" '[{id:7001,user:{login:$who},created_at:$t,body:"@codex review"},
          {id:7009,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,updated_at:$t,
           body:("<!-- codex-pull-request-review-summary -->\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ⏳ **Running** | `" + $h + "` | Manual request |\n")}]' ;;
      dup_author_upper) jq -cn --arg who "$author" --arg t "$t" '[{id:7002,user:{login:$who},created_at:$t,body:"@CODEX REVIEW"}]' ;;
      author_prose)     jq -cn --arg who "$author" --arg t "$t" '[{id:7003,user:{login:$who},created_at:$t,body:"Status: @codex review was already requested."}]' ;;
      author_quoted)    jq -cn --arg who "$author" --arg t "$t" '[{id:7004,user:{login:$who},created_at:$t,body:"Earlier note:\n> @codex review\n\nDo not run it again."}]' ;;
      author_padded)    jq -cn --arg who "$author" --arg t "$t" '[{id:7005,user:{login:$who},created_at:$t,body:"@codex review "}]' ;;
      stale_author)     jq -cn --arg who "$author" --arg t "$old" '[{id:7006,user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      reviewer_only)    jq -cn --arg who "$reviewer" --arg t "$t" '[{id:7007,user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      known_usage_limit) jq -cn --arg t "$t" '[{id:8061,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"You have reached your Codex usage limits for code reviews."}]' ;;
      known_not_connected) jq -cn --arg t "$t" '[{id:8062,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"To use Codex here, create a Codex account and connect to GitHub, then comment @codex review."}]' ;;
      stale_usage_limit) jq -cn --arg t "$old" '[{id:8063,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"You have reached your Codex usage limits for code reviews."}]' ;;
      stale_not_connected) jq -cn --arg t "$old" '[{id:8064,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"To use Codex here, create a Codex account and connect to GitHub, then comment @codex review."}]' ;;
      current_usage_limit) jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[{id:8065,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"You have reached your Codex usage limits for code reviews."}]' ;;
      current_not_connected) jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[{id:8066,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"To use Codex here, create a Codex account and connect to GitHub, then comment @codex review."}]' ;;
      cap_at_limit)     jq -cn --arg who "$author" --arg t "$old" '[range(10) | {id:(8000 + .),user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      cap_at_limit_blocked) jq -cn --arg who "$author" --arg t "$old" '[range(10) | {id:(8050 + .),user:{login:$who},created_at:$t,body:"@codex review"}] + [{id:8060,user:{login:"chatgpt-codex-connector[bot]"},created_at:$t,body:"You have reached your Codex usage limits for code reviews."}]' ;;
      cap_below_limit)  jq -cn --arg who "$author" --arg t "$old" '[range(9) | {id:(8100 + .),user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      cap_three)        jq -cn --arg who "$author" --arg t "$old" '[range(3) | {id:(8150 + .),user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      cp_four)          jq -cn --arg who "$author" --arg t "$old" '[range(4) | {id:(8700 + .),user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      cp_five)          jq -cn --arg who "$author" --arg t "$old" '[range(5) | {id:(8710 + .),user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      cp_five_existing) jq -cn --arg who "$author" --arg t "$old" '[range(5) | {id:(8720 + .),user:{login:$who},created_at:$t,body:"@codex review"}] + [{id:8730,user:{login:$who},created_at:$t,body:"<!-- mergepath-codex-request-checkpoint:v1 counted=5 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\nCheckpoint."}]' ;;
      cp_five_quoted)   jq -cn --arg who "$author" --arg t "$old" '[range(5) | {id:(8760 + .),user:{login:$who},created_at:$t,body:"@codex review"}] + [{id:8770,user:{login:$who},created_at:$t,body:"Note: the requester writes <!-- mergepath-codex-request-checkpoint:v1 counted=5 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --> at five requests."}]' ;;
      cp_five_foreign)  jq -cn --arg who "$author" --arg t "$old" '[range(5) | {id:(8740 + .),user:{login:$who},created_at:$t,body:"@codex review"}] + [{id:8750,user:{login:"someone-else"},created_at:$t,body:"<!-- mergepath-codex-request-checkpoint:v1 counted=5 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->"}]' ;;
      cap_duplicate_ids) jq -cn --arg who "$author" --arg t "$old" '[range(12) | {id:(8200 + (. % 9)),user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      cap_bad_id)       jq -cn --arg who "$author" --arg t "$old" '[range(9) | {id:(8300 + .),user:{login:$who},created_at:$t,body:"@codex review"}] + [{user:{login:$who},created_at:$t,body:"@codex review"}]' ;;
      # #2534: ten prior requests, one of them a marked CodeRabbit failover.
      cap_failover)     jq -cn --arg who "$author" --arg t "$old" '[range(10) | {id:(8400 + (. * 2)),user:{login:$who},created_at:$t,body:"@codex review"}]
                          + [{id:8401,user:{login:$who},created_at:$t,updated_at:$t,
                              body:"<!-- mergepath-codex-failover:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=8400 -->"}]' ;;
      # #2553: the same, with the marker naming a head this PR never had.
      cap_failover_foreign) jq -cn --arg who "$author" --arg t "$old" '[range(10) | {id:(8400 + (. * 2)),user:{login:$who},created_at:$t,body:"@codex review"}]
                          + [{id:8401,user:{login:$who},created_at:$t,updated_at:$t,
                              body:"<!-- mergepath-codex-failover:v1 head=1111111111111111111111111111111111111111 trigger_comment_id=8400 -->"}]' ;;
      # #2591: the marker names a head a force-push replaced; only GraphQL has it.
      cap_failover_forced) jq -cn --arg who "$author" --arg t "$old" '[range(10) | {id:(8400 + (. * 2)),user:{login:$who},created_at:$t,body:"@codex review"}]
                          + [{id:8401,user:{login:$who},created_at:$t,updated_at:$t,
                              body:"<!-- mergepath-codex-failover:v1 head=9999999999999999999999999999999999999999 trigger_comment_id=8400 -->"}]' ;;
      # #2534: what the failover stub has posted so far.
      live)             if [ -f "$CODEX_TEST_STATE_DIR/live-comments.json" ]; then cat "$CODEX_TEST_STATE_DIR/live-comments.json"; else printf '[]\n'; fi ;;
      *)                printf '[]\n' ;;
    esac
    ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '%s\n' "$dir"
}

run_trigger_only() {
  local dir=$1 scenario=$2 phase4a_gated=${3:-false} base_policy_mode=${4:-ok} rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO="$scenario" \
      CODEX_TEST_BASE_POLICY_MODE="$base_policy_mode" \
      CODEX_TEST_CHECKPOINT_FAIL="${CODEX_TEST_CHECKPOINT_FAIL:-0}" \
      MERGEPATH_PHASE_4A_GATED="$phase4a_gated" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

trig_count() { if [ -f "$1/state/trigger-count" ]; then cat "$1/state/trigger-count"; else printf '0\n'; fi; }
jqf() { jq -r "$2" "$1/out.json"; }

# #2166 moving-head guard runner. Same shape as run_trigger_only, plus the
# guard inputs: CODEX_TEST_HEAD_DATE (the head's pushed-at anchor in these
# stubs), the repo-lint workflow-run shape (4th argument, CODEX_TEST_LINT_RUNS),
# CODEX_TEST_CHECK_RUNS from the caller's env (the override path), and any
# extra script flags.
run_guard() {
  local dir=$1 scenario=$2 head_date=$3 lint_runs=$4 auto=$5; shift 5
  local rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO="$scenario" \
      CODEX_TEST_HEAD_DATE="$head_date" \
      CODEX_TEST_LINT_RUNS="$lint_runs" \
      CODEX_TEST_CHECK_RUNS="${CODEX_TEST_CHECK_RUNS:-completed}" \
      MERGEPATH_CODEX_AUTO_TRIGGER="$auto" \
      ./scripts/codex-review-request.sh "$@" 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}
# A head pushed one minute ago (under the 300s default) and one pushed an hour
# ago (over it). Computed with jq so the suite stays portable across BSD and
# GNU date on every consumer. Recomputed at the start of every moving-head
# case (#2253): those cases run after the rest of the suite, and a value taken
# once at load ages past the 300s floor on a slow runner, turning the
# young-head refusals into posts.
refresh_head_dates() {
  YOUNG_HEAD=$(jq -rn 'now - 60 | floor | todate')
  OLD_HEAD=$(jq -rn 'now - 3600 | floor | todate')
}
refresh_head_dates

# #1276: losing the shared selector cannot turn a known trigger into a new POST.
dir=$(make_case missing-selector)
mv "$dir/scripts/lib/codex-request-evidence.sh" "$dir/helper-removed.sh"
rc=$(run_trigger_only "$dir" dup_author)
if [ "$rc" = 3 ] && [ "$(trig_count "$dir")" = 0 ] && grep -q 'request evidence helper unavailable' "$dir/err.log"; then
  pass "#1276: missing selector fails before a duplicate trigger can be posted"
else
  fail "#1276: missing selector rc=$rc posts=$(trig_count "$dir")"
fi

# A: fresh HEAD → posts once, exits 0, no poll, no ack-retry (#3), JSON shape
test_fresh_posts_once_no_poll() {
  local dir rc before=$FAIL
  dir=$(make_case "fresh")
  rc=$(run_trigger_only "$dir" fresh)
  [ "$rc" = "0" ] || fail "A: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "A: expected exactly 1 @codex post (no ack-retry), got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_only')" = "true" ] || fail "A: trigger_only=$(jqf "$dir" '.trigger_only'), expected true"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "A: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  jq -e 'has("terminal_determination") and (.terminal_determination == null)' "$dir/out.json" >/dev/null \
    || fail "A: terminal_determination must be present and null"
  [ "$(jqf "$dir" '.rounds_waited_seconds')" = "0" ] || fail "A: rounds_waited_seconds=$(jqf "$dir" '.rounds_waited_seconds'), expected 0 (no poll)"
  [ "$FAIL" -ne "$before" ] || pass "A: fresh HEAD posts one @codex trigger, exits 0 without polling/ack-retry"
}

# #2882: Codex's PR-open auto-review (a 👍 on the PR plus a clean Completed
# summary row, with no review object or verdict) is not clearance. The merge
# gate's same-agent branch 2 accepts only commit-anchored evidence (#1751), so
# a requester that counted this as cleared would refuse the trigger the gate
# needs and deadlock the PR, as a pre-#1855 copy did on tadlockpsychiatry#206.
test_pr_open_reaction_still_posts() {
  local dir rc before=$FAIL
  dir=$(make_case "pr-open-reaction")
  rc=$(CODEX_TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_trigger_only "$dir" pr_open_reaction)
  [ "$rc" = "0" ] || fail "#2882: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "#2882: a PR-open 👍 must not suppress the trigger → expected 1 post, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "#2882: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  ! grep -q 'already cleared' "$dir/err.log" || fail "#2882: requester treated the PR-open 👍 as clearance"
  [ "$FAIL" -ne "$before" ] || pass "#2882: PR-open 👍 + clean summary row, no trigger → requester posts the trigger branch 2 needs"
}

# B: existing AUTHOR trigger on HEAD → idempotent skip
test_dup_author_skips() {
  local dir rc before=$FAIL
  dir=$(make_case "dup")
  rc=$(run_trigger_only "$dir" dup_author)
  [ "$rc" = "0" ] || fail "B: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "B: expected 0 posts (idempotent skip), got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "B: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected false"
  [ "$FAIL" -ne "$before" ] || pass "B: existing author @codex trigger on HEAD → idempotent skip (no duplicate)"
}

# #1276: dedup evidence is the complete author command, case-insensitively.
test_uppercase_author_command_skips() {
  local dir rc before=$FAIL
  dir=$(make_case "dup-uppercase")
  rc=$(run_trigger_only "$dir" dup_author_upper)
  [ "$rc" = "0" ] || fail "B1: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "B1: uppercase exact author command must dedup, got $(trig_count "$dir") posts"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "B1: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected false"
  [ "$FAIL" -ne "$before" ] || pass "B1: uppercase exact author command retains case-insensitive idempotent skip"
}

test_author_containment_posts() {
  local scenario desc dir rc before
  for scenario in author_prose author_quoted author_padded; do
    before=$FAIL
    case "$scenario" in
      author_prose) desc="prose mention" ;;
      author_quoted) desc="quoted command" ;;
      author_padded) desc="space-padded command" ;;
    esac
    dir=$(make_case "$scenario")
    rc=$(run_trigger_only "$dir" "$scenario")
    [ "$rc" = "0" ] || fail "B2: $desc expected exit 0, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = "1" ] || fail "B2: author $desc must not suppress the exact POST, got $(trig_count "$dir") posts"
    [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "B2: $desc trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
    [ "$FAIL" -ne "$before" ] || pass "B2: author $desc is not complete-command dedup evidence → posts once"
  done
}

test_stale_author_command_posts() {
  local dir rc before=$FAIL
  dir=$(make_case "stale-author")
  rc=$(run_trigger_only "$dir" stale_author)
  [ "$rc" = "0" ] || fail "B3: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "B3: stale author command must not suppress the exact POST, got $(trig_count "$dir") posts"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "B3: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  [ "$FAIL" -ne "$before" ] || pass "B3: stale author command remains outside the freshness-qualified dedup set"
}

# C: only a REVIEWER-authored trigger → not a valid trigger, still posts (#1)
test_reviewer_trigger_does_not_count() {
  local dir rc before=$FAIL
  dir=$(make_case "reviewer")
  rc=$(run_trigger_only "$dir" reviewer_only)
  [ "$rc" = "0" ] || fail "C: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "C: reviewer-authored @codex must NOT count → expected 1 post, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "C: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  [ "$FAIL" -ne "$before" ] || pass "C: reviewer-authored @codex is not a valid trigger (author-scoped dedupe) → still posts"
}

# #813: max_review_rounds is enforced at the one request write boundary. The
# counter intentionally follows author-owned exact command evidence rather
# than provider review objects: clean summaries and reaction-only clearance do
# not reliably create a review object.
test_request_attempt_cap() {
  local scenario expected_rc expected_posts description dir rc before
  for scenario in cap_at_limit cap_below_limit cap_duplicate_ids cap_bad_id; do
    case "$scenario" in
      cap_at_limit)
        expected_rc=7; expected_posts=0
        description="ten prior author requests stop additional advisory requests" ;;
      cap_below_limit)
        expected_rc=0; expected_posts=1
        description="nine prior author requests permit the tenth" ;;
      cap_duplicate_ids)
        expected_rc=0; expected_posts=1
        description="duplicate comment IDs do not consume additional slots" ;;
      cap_bad_id)
        expected_rc=3; expected_posts=0
        description="a malformed qualifying request record fails closed" ;;
    esac
    before=$FAIL
    dir=$(make_case "request-cap-$scenario")
    rc=$(run_trigger_only "$dir" "$scenario")
    [ "$rc" = "$expected_rc" ] \
      || fail "#813: $description expected exit $expected_rc, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = "$expected_posts" ] \
      || fail "#813: $description expected $expected_posts posts, got $(trig_count "$dir")"
    if [ "$scenario" = cap_at_limit ]; then
      grep -q 'request-attempt cap reached.*10/10' "$dir/err.log" \
        || fail "#813: cap refusal did not expose consumed/limit evidence"
      [ "$(jqf "$dir" '.cap_exhausted.request_attempts')" = 10 ] \
        || fail "#813: cap exhaustion did not report consumed attempts"
      [ "$(jqf "$dir" '.cap_exhausted.max_request_attempts')" = 10 ] \
        || fail "#813: cap exhaustion did not report configured bound"
      [ "$(jqf "$dir" '.cap_exhausted.escalation')" = null ] \
        || fail "#813: advisory cap exhaustion invented caller routing"
      [ "$(jqf "$dir" '.cap_exhausted.observed_provider_block')" = null ] \
        || fail "#813: cap exhaustion fabricated provider-block diagnostics"
    fi
    [ "$FAIL" -ne "$before" ] || pass "#813: $description"
  done
}

# #2657: the five-request checkpoint reuses the ceiling's request count, is
# recorded once per PR by the author, and never blocks or changes a budget.
cp_count() { if [ -f "$1/state/checkpoint-count" ]; then cat "$1/state/checkpoint-count"; else printf '0\n'; fi; }
test_request_checkpoint() {
  local scenario dir rc before want_cp want_rec
  for scenario in cp_four cp_five cp_five_existing cp_five_foreign cp_five_quoted cap_below_limit cap_three; do
    before=$FAIL
    case "$scenario" in
      cp_four|cap_three) want_cp=0; want_rec=null ;;
      cp_five|cp_five_foreign|cp_five_quoted|cap_below_limit) want_cp=1; want_rec=posted ;;
      cp_five_existing) want_cp=0; want_rec=existing ;;
    esac
    dir=$(make_case "checkpoint-$scenario")
    rc=$(run_trigger_only "$dir" "$scenario")
    [ "$rc" = 0 ] || fail "#2657 $scenario: expected exit 0, got $rc; err=$(tail -n 3 "$dir/err.log")"
    [ "$(trig_count "$dir")" = 1 ] || fail "#2657 $scenario: the request itself was not posted exactly once ($(trig_count "$dir"))"
    [ "$(cp_count "$dir")" = "$want_cp" ] || fail "#2657 $scenario: expected $want_cp checkpoint posts, got $(cp_count "$dir")"
    [ "$(jqf "$dir" '.request_checkpoint.recorded // "null"')" = "$want_rec" ] \
      || fail "#2657 $scenario: request_checkpoint.recorded=$(jqf "$dir" '.request_checkpoint.recorded // "null"'), expected $want_rec"
    if [ "$want_cp" = 1 ]; then
      grep -Fq 'counted=' "$dir/state/checkpoint-1.md" && grep -Fq 'reassess the scope' "$dir/state/checkpoint-1.md" \
        && grep -Fq 'nathanjohnpayne/mergepath#2657' "$dir/state/checkpoint-1.md" \
        || fail "#2657 $scenario: checkpoint body lacks its count or guidance"
    fi
    [ "$FAIL" -ne "$before" ] || pass "#2657 checkpoint: $scenario posts $want_cp checkpoint(s), recorded=$want_rec, request still posts"
  done
  before=$FAIL
  dir=$(make_case "checkpoint-write-fails")
  rc=$(CODEX_TEST_CHECKPOINT_FAIL=1 run_trigger_only "$dir" cp_five)
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(jqf "$dir" '.request_checkpoint.recorded')" = failed ] \
    || fail "#2657: a failed checkpoint write blocked or hid the request (rc=$rc posts=$(trig_count "$dir"))"
  [ "$FAIL" -ne "$before" ] || pass "#2657 checkpoint: a failed checkpoint write never blocks the request"
  # Staging: the body file is created but cannot be written (a full disk or
  # quota); here the "file" is a directory, so the write fails.
  before=$FAIL
  dir=$(make_case "checkpoint-staging-fails")
  cat >"$dir/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  *codex-request-checkpoint*) path=$(/usr/bin/mktemp -d "$1") && printf '%s\n' "$path" ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
EOF
  chmod +x "$dir/bin/mktemp"
  rc=$(run_trigger_only "$dir" cp_five)
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(cp_count "$dir")" = 0 ] \
    && [ "$(jqf "$dir" '.request_checkpoint.recorded')" = failed ] \
    || fail "#2657: a checkpoint staging failure blocked or hid the request (rc=$rc posts=$(trig_count "$dir")); $(tail -3 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "#2657 checkpoint: a staging failure never blocks the request"
  # A CodeRabbit failover is not a deliberate round: it records no checkpoint,
  # so the next ordinary request still gets it.
  before=$FAIL
  dir=$(make_case "checkpoint-failover")
  rc=0
  ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" CODEX_TEST_SCENARIO=cp_five \
      ./scripts/codex-review-request.sh --trigger-only --failover 999 owner/repo >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(cp_count "$dir")" = 0 ] \
    && [ "$(jqf "$dir" '.request_checkpoint // "null"')" = null ] \
    || fail "#2657: a failover trigger recorded the checkpoint (rc=$rc posts=$(trig_count "$dir") checkpoints=$(cp_count "$dir")); $(tail -3 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "#2657 checkpoint: a failover trigger never records the checkpoint"
  # A requester whose own trigger write is refused records no checkpoint, so
  # concurrent requesters at the threshold cannot each add one.
  before=$FAIL
  dir=$(make_case "checkpoint-trigger-refused")
  rc=$(CODEX_TEST_TRIGGER_FAIL=1 run_trigger_only "$dir" cp_five)
  [ "$rc" = 3 ] && [ "$(trig_count "$dir")" = 0 ] && [ "$(cp_count "$dir")" = 0 ] \
    || fail "#2657: a refused trigger write still recorded a checkpoint (rc=$rc posts=$(trig_count "$dir") checkpoints=$(cp_count "$dir"))"
  [ "$FAIL" -ne "$before" ] || pass "#2657 checkpoint: only a request that posted records the checkpoint"
}

test_nondefault_request_attempt_cap() {
  local dir rc before=$FAIL
  dir=$(make_case "request-cap-nondefault")
  printf '  max_review_rounds: 3\n' >> "$dir/state/base-review-policy.yml"
  rc=$(run_trigger_only "$dir" cap_three)
  [ "$rc" = 7 ] || fail "#813: nondefault cap expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#813: nondefault cap posted despite three consumed requests"
  grep -q 'request-attempt cap reached.*3/3' "$dir/err.log" \
    || fail "#813: nondefault cap did not report the configured bound"
  [ "$(jqf "$dir" '.cap_exhausted.escalation')" = null ] \
    || fail "#813: nondefault advisory cap invented caller routing"
  [ "$FAIL" -ne "$before" ] || pass "#813: configured nondefault cap governs a new request"
}

test_candidate_cannot_raise_governing_request_attempt_cap() {
  local dir rc before=$FAIL
  dir=$(make_case "request-cap-governing-base")
  printf '  max_review_rounds: 999999999\n' >> "$dir/.github/review-policy.yml"
  printf '  max_review_rounds: 3\n' >> "$dir/state/base-review-policy.yml"
  rc=$(run_trigger_only "$dir" cap_three)
  [ "$rc" = 7 ] || fail "#813 governing cap: candidate-raised cap expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#813 governing cap: candidate-raised cap posted despite three consumed requests"
  grep -q 'request-attempt cap reached.*3/3' "$dir/err.log" \
    || fail "#813 governing cap: refusal did not report the base-policy bound"
  [ "$FAIL" -ne "$before" ] || pass "#813: a PR cannot raise its governing base-policy request cap"
}

test_governing_cap_read_failure_refuses_new_write() {
  local dir rc before=$FAIL
  dir=$(make_case "request-cap-base-read-failure")
  printf '  max_review_rounds: 1\n' >> "$dir/.github/review-policy.yml"
  rc=$(run_trigger_only "$dir" fresh false fail)
  [ "$rc" = 3 ] || fail "#813 governing cap read failure: expected infrastructure exit 3, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#813 governing cap read failure: posted despite unknown governing cap"
  [ "$FAIL" -ne "$before" ] || pass "#813: an unreadable governing cap fails closed before a new request write"
}

test_invalid_present_governing_cap_refuses_new_write() {
  local value dir rc before
  for value in false null "'__absent__'"; do
    before=$FAIL
    dir=$(make_case "request-cap-base-$value")
    printf '  max_review_rounds: %s\n' "$value" >> "$dir/state/base-review-policy.yml"
    rc=$(run_trigger_only "$dir" fresh)
    [ "$rc" = 3 ] || fail "#813 governing cap $value: expected infrastructure exit 3, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = 0 ] || fail "#813 governing cap $value: posted despite invalid governed value"
    [ "$FAIL" -ne "$before" ] || pass "#813: present $value governing cap remains invalid at the write boundary"
  done
}

test_invalid_present_governing_codex_block_refuses_new_write() {
  local value dir rc before
  for value in false '[]' null; do
    before=$FAIL
    dir=$(make_case "request-cap-base-codex-$value")
    printf 'author_identity: nathanjohnpayne\ncodex: %s\n' "$value" > "$dir/state/base-review-policy.yml"
    rc=$(run_trigger_only "$dir" fresh)
    [ "$rc" = 3 ] || fail "#813 governing codex $value: expected infrastructure exit 3, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = 0 ] || fail "#813 governing codex $value: posted despite invalid governed block"
    [ "$FAIL" -ne "$before" ] || pass "#813: present $value governing codex block remains invalid at the write boundary"
  done
}

test_missing_governing_codex_block_defaults_request_cap() {
  local dir rc before=$FAIL
  dir=$(make_case "request-cap-base-no-codex")
  printf 'author_identity: nathanjohnpayne\n' > "$dir/state/base-review-policy.yml"
  # An absent request_by_default now belongs to the governing target too.
  # Explicit gating reaches the cap whose default this case exercises.
  rc=$(run_trigger_only "$dir" cap_at_limit true)
  [ "$rc" = 7 ] || fail "#813 missing governing codex: expected default-cap exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#813 missing governing codex: posted despite default cap exhaustion"
  grep -q 'request-attempt cap reached.*10/10' "$dir/err.log" \
    || fail "#813 missing governing codex: did not apply the default cap"
  [ "$FAIL" -ne "$before" ] || pass "#813: missing governing codex block defaults the request cap to 10"
}

# Timing authority is now resolved even on no-spend paths; its read failure
# cannot become false freshness evidence. Cap values themselves stay deferred.
test_idempotent_skip_requires_governing_freshness() {
  local dir rc before=$FAIL
  dir=$(make_case "freshness-idempotent-unreadable")
  rc=$(run_trigger_only "$dir" dup_author false fail)
  [ "$rc" = 3 ] || fail "#1567 idempotent freshness: expected exit 3, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#1567 idempotent freshness: posted a duplicate trigger"
  [ -f "$dir/state/base-policy-read-count" ] || fail "#1567 idempotent freshness: did not read governing policy"
  [ "$FAIL" -ne "$before" ] || pass "#1567: no-spend paths fail closed on unreadable governing freshness"
}

# A one-hour-old request straddles the candidate/base windows. Run the actual
# requester rather than only comparing helper timestamps.
test_governing_request_freshness() {
  local scenario candidate governing expected_posts dir rc before trigger_at
  trigger_at=$(date -u -r "$(($(date +%s) - 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '@'"$(($(date +%s) - 3600))" +%Y-%m-%dT%H:%M:%SZ)
  for scenario in candidate-wide candidate-short candidate-invalid default-window; do
    before=$FAIL
    case "$scenario" in
      candidate-wide) candidate=999999999; governing=1800; expected_posts=1 ;;
      candidate-short) candidate=1; governing=7200; expected_posts=0 ;;
      candidate-invalid) candidate=broken; governing=7200; expected_posts=0 ;;
      default-window) candidate=999999999; governing=absent; expected_posts=1 ;;
    esac
    dir=$(make_case "freshness-$scenario")
    sed -i.bak "s/reaction_freshness_window_seconds:.*/reaction_freshness_window_seconds: $candidate/" "$dir/.github/review-policy.yml"
    if [ "$governing" = absent ]; then
      sed -i.bak '/reaction_freshness_window_seconds:/d' "$dir/state/base-review-policy.yml"
    else
      sed -i.bak "s/reaction_freshness_window_seconds:.*/reaction_freshness_window_seconds: $governing/" "$dir/state/base-review-policy.yml"
    fi
    rc=$(CODEX_TEST_HEAD_DATE=1999-01-01T00:00:00Z CODEX_TEST_TRIGGER_AT="$trigger_at" \
      run_trigger_only "$dir" freshness_author)
    [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = "$expected_posts" ] \
      || fail "#1567 $scenario: rc=$rc posts=$(trig_count "$dir") expected=$expected_posts; err=$(cat "$dir/err.log")"
    [ "$FAIL" -ne "$before" ] || pass "#1567: $scenario uses governing freshness for actual request reuse"
  done
}

# #2027: advance the governing base after the initial signal scan. A bounded
# refusal avoids either reusing a stale window or spending from the old one.
test_governing_freshness_revalidation() {
  local variant dir rc initial next expected posts trigger_at before=$FAIL
  trigger_at=$(jq -rn 'now - 3600 | floor | todate')
  for variant in shrink expand base-only unreadable-pr unreadable-policy unchanged-wide unchanged-short malformed-cap cap-change; do
    dir=$(make_case "freshness-fence-$variant")
    initial=7200; next=7200; expected=3; posts=0
    case "$variant" in
      shrink) next=1800 ;;
      expand) initial=1800 ;;
      unchanged-wide|malformed-cap|cap-change) expected=0 ;;
      unchanged-short) initial=1800; next=1800; expected=0; posts=1 ;;
    esac
    sed -i.bak "s/reaction_freshness_window_seconds:.*/reaction_freshness_window_seconds: $initial/" "$dir/state/base-review-policy.yml"
    sed "s/reaction_freshness_window_seconds:.*/reaction_freshness_window_seconds: $next/" \
      "$dir/state/base-review-policy.yml" >"$dir/state/base-review-policy-next.yml"
    [ "$variant" != malformed-cap ] || printf '  max_review_rounds: invalid\n' >>"$dir/state/base-review-policy.yml"
    [ "$variant" != cap-change ] || printf '  max_review_rounds: invalid\n' >>"$dir/state/base-review-policy-next.yml"
    rc=$(CODEX_TEST_FRESHNESS_TRANSITION="$variant" CODEX_TEST_TRIGGER_AT="$trigger_at" \
      CODEX_TEST_HEAD_DATE=1999-01-01T00:00:00Z run_trigger_only "$dir" freshness_author)
    [ "$rc" = "$expected" ] && [ "$(trig_count "$dir")" = "$posts" ] \
      || fail "#2027: $variant expected rc=$expected posts=$posts, got rc=$rc posts=$(trig_count "$dir") ($(cat "$dir/err.log"))"
    if [ "$expected" = 3 ]; then
      grep -q 'governing request freshness' "$dir/err.log" \
        || fail "#2027: $variant must name the fresh evidence refusal"
    fi
  done
  [ "$FAIL" -ne "$before" ] || pass "#2027: freshness/base drift refuses reuse or writes; unchanged and malformed-cap no-spend paths retain behavior"
}

test_governing_freshness_validation_preserves_no_spend_caps() {
  local value dir rc before
  for value in false null '[]' '-1'; do
    before=$FAIL
    dir=$(make_case "freshness-invalid-$value")
    sed -i.bak "s/reaction_freshness_window_seconds:.*/reaction_freshness_window_seconds: $value/" "$dir/state/base-review-policy.yml"
    rc=$(run_trigger_only "$dir" dup_author)
    [ "$rc" = 3 ] && [ "$(trig_count "$dir")" = 0 ] \
      || fail "#1567 invalid freshness $value: rc=$rc posts=$(trig_count "$dir")"
    [ "$FAIL" -ne "$before" ] || pass "#1567: invalid governing freshness $value fails closed before reuse"
  done
  before=$FAIL
  dir=$(make_case "freshness-no-spend-invalid-cap")
  printf '  max_review_rounds: false\n  max_blocking_reviews: false\n' >>"$dir/state/base-review-policy.yml"
  rc=$(run_trigger_only "$dir" dup_author)
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 0 ] \
    || fail "#1567 no-spend invalid caps: rc=$rc posts=$(trig_count "$dir"); err=$(cat "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "#1567: no-spend reuse still skips malformed governing cap validation"
}

test_gated_cap_leaves_routing_to_caller() {
  local dir rc before=$FAIL
  dir=$(make_case "request-cap-gated")
  rc=$(run_trigger_only "$dir" cap_at_limit true)
  [ "$rc" = 7 ] || fail "#813 gated cap: expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#813 gated cap: posted despite exhausted request budget"
  [ "$(jqf "$dir" '.cap_exhausted.escalation')" = null ] \
    || fail "#813 gated cap invented caller routing"
  [ "$FAIL" -ne "$before" ] || pass "#813: Phase 4a-gated cap leaves routing to the caller"
}

test_cap_preserves_provider_block_as_diagnostic_only() {
  local dir rc before=$FAIL
  dir=$(make_case "request-cap-blocked")
  rc=$(run_trigger_only "$dir" cap_at_limit_blocked true)
  [ "$rc" = 7 ] || fail "#813 blocked cap: expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#813 blocked cap: posted despite exhausted request budget"
  [ "$(jqf "$dir" '.blocked_reason')" = null ] \
    || fail "#813 blocked cap elevated the provider block into Phase 4b routing"
  [ "$(jqf "$dir" '.cap_exhausted.escalation')" = null ] \
    || fail "#813 blocked cap invented caller routing"
  [ "$(jqf "$dir" '.cap_exhausted.observed_provider_block.reason')" = usage_limit ] \
    || fail "#813 blocked cap did not preserve the observed provider-block reason"
  [ "$(jqf "$dir" '.cap_exhausted.observed_provider_block.comment_id')" = 8060 ] \
    || fail "#813 blocked cap did not preserve the observed provider-block comment id"
  [ "$FAIL" -ne "$before" ] || pass "#813: cap preserves provider-block diagnostics without changing routing"
}

# ---------------------------------------------------------------------------
# #1560 slice 3: the blocking-review budget. Before every new request the
# requester counts, from the Codex review ledger, the PR's solicited responses
# that are blocking, unknown-tier or conflicting, and refuses the request once
# that count reaches codex.max_blocking_reviews (default 10, provisional).
# Each case gets its own ledger stub that prints exactly the responses under
# test; the stub records its arguments and how often it ran.
# ---------------------------------------------------------------------------
# make_budget_case <name> <responses-jq-expr>: the expression builds the
# ledger's .responses array.
make_budget_case() {
  local name=$1 expr=$2 dir
  dir=$(make_case "$name")
  jq -nc "$expr" >"$dir/state/ledger-responses.json"
  cat >"$dir/ledger-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${CODEX_TEST_STATE_DIR:?}
printf '%s\n' "$*" >>"$state/ledger-calls"
head=""
while [ $# -gt 0 ]; do
  case "$1" in --expect-head) head=$2; shift 2 ;; --expect-policy) fp=$2; shift 2 ;; *) shift ;; esac
done
[ ! -f "$state/ledger-policy" ] || fp=$(cat "$state/ledger-policy")
[ ! -f "$state/ledger-rc" ] || exit "$(cat "$state/ledger-rc")"
if [ -f "$state/ledger-raw" ]; then cat "$state/ledger-raw"; exit 0; fi
[ ! -f "$state/ledger-head" ] || head=$(cat "$state/ledger-head")
author=nathanjohnpayne
[ ! -f "$state/ledger-author" ] || author=$(cat "$state/ledger-author")
max=10
[ ! -f "$state/ledger-max" ] || max=$(cat "$state/ledger-max")
doc=$(jq -nc --arg h "$head" --arg a "$author" --argjson m "$max" --arg fp "${fp:-}" --slurpfile r "$state/ledger-responses.json" \
  '{head_sha: $h, author: $a, max_blocking_reviews: $m, policy_fingerprint: $fp, responses: $r[0]}')
printf '%s\n' "$doc"
[ ! -f "$state/ledger-twice" ] || printf '%s\n' "$doc"
EOF
  chmod +x "$dir/ledger-stub.sh"
  printf '%s\n' "$dir"
}

run_budget_case() { # <dir> <scenario>
  MERGEPATH_CODEX_LEDGER_CMD="$1/ledger-stub.sh" run_trigger_only "$1" "$2"
}

ledger_calls() { if [ -f "$1/state/ledger-calls" ]; then wc -l <"$1/state/ledger-calls" | tr -d ' '; else printf '0\n'; fi; }

# n solicited responses of one class.
responses() { # <n> <class> [unsolicited] [conflicting]
  printf '[range(%s) | {class: "%s", unsolicited: %s, conflicting: %s, first_at: "2026-06-04T00:00:00Z"}]' \
    "$1" "$2" "${3:-false}" "${4:-false}"
}

# The explicit boundary: with a budget of 10, 9 solicited blocking reviews
# permit a request (it may draw the 10th), and 10 or 11 refuse one.
test_blocking_budget_boundary() {
  local n expected_rc expected_posts dir rc before
  for n in 9 10 11; do
    before=$FAIL
    case "$n" in
      9) expected_rc=0; expected_posts=1 ;;
      *) expected_rc=7; expected_posts=0 ;;
    esac
    dir=$(make_budget_case "blocking-budget-$n" "$(responses "$n" blocking)")
    rc=$(run_budget_case "$dir" fresh)
    [ "$rc" = "$expected_rc" ] \
      || fail "#1560 budget $n/10: expected exit $expected_rc, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = "$expected_posts" ] \
      || fail "#1560 budget $n/10: expected $expected_posts posts, got $(trig_count "$dir")"
    [ "$(ledger_calls "$dir")" = 1 ] \
      || fail "#1560 budget $n/10: ledger ran $(ledger_calls "$dir") times, expected once"
    grep -qE -- '^--repo owner/repo --expect-head head-sha --expect-policy [0-9]+-[0-9]+ 999$' "$dir/state/ledger-calls" \
      || fail "#1560 budget $n/10: ledger was not asked for this PR at the requester's head: $(cat "$dir/state/ledger-calls" 2>/dev/null)"
    if [ "$expected_rc" = 7 ]; then
      [ "$(jqf "$dir" '.cap_exhausted.kind')" = blocking-reviews ] \
        || fail "#1560 budget $n/10: stop kind is $(jqf "$dir" '.cap_exhausted.kind')"
      [ "$(jqf "$dir" '.cap_exhausted.blocking_reviews')" = "$n" ] \
        || fail "#1560 budget $n/10: did not report the blocking count"
      [ "$(jqf "$dir" '.cap_exhausted.max_blocking_reviews')" = 10 ] \
        || fail "#1560 budget $n/10: did not report the default budget"
      [ "$(jqf "$dir" '.cap_exhausted.request_attempts')" = 0 ] \
        || fail "#1560 budget $n/10: did not report the request count"
      grep -q "blocking-review budget spent.*$n/10" "$dir/err.log" \
        || fail "#1560 budget $n/10: refusal did not log consumed/limit"
    fi
    [ "$FAIL" -ne "$before" ] || pass "#1560: $n solicited blocking reviews against a budget of 10 -> exit $expected_rc"
  done
}

# Only solicited blocking, unknown-tier and conflicting responses count.
test_blocking_budget_counting_rule() {
  local name expr expected_rc dir rc before
  while IFS='|' read -r name expected_rc expr; do
    [ -n "$name" ] || continue
    before=$FAIL
    dir=$(make_budget_case "blocking-count-$name" "$expr")
    rc=$(run_budget_case "$dir" fresh)
    [ "$rc" = "$expected_rc" ] \
      || fail "#1560 counting rule $name: expected exit $expected_rc, got $rc; err=$(cat "$dir/err.log")"
    [ "$FAIL" -ne "$before" ] || pass "#1560 counting rule: $name -> exit $expected_rc"
  done <<EOF
unsolicited blocking is not counted|0|$(responses 9 blocking) + $(responses 5 blocking true)
non-blocking classes are not counted|0|$(responses 9 blocking) + $(responses 3 discretionary) + $(responses 3 clean) + $(responses 3 no_findings) + $(responses 3 provider_blocked)
unknown tier counts against the budget|7|$(responses 9 blocking) + $(responses 1 unknown_tier)
a conflicting response counts against the budget|7|$(responses 9 blocking) + $(responses 1 discretionary false true)
EOF
}

# Both budgets spent: the blocking budget is checked first and names the stop.
test_blocking_budget_wins_simultaneous_exhaustion() {
  local dir rc before=$FAIL
  dir=$(make_budget_case "blocking-both-spent" "$(responses 10 blocking)")
  rc=$(run_budget_case "$dir" cap_at_limit)
  [ "$rc" = 7 ] || fail "#1560 both spent: expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#1560 both spent: posted a trigger"
  [ "$(jqf "$dir" '.cap_exhausted.kind')" = blocking-reviews ] \
    || fail "#1560 both spent: stop kind is $(jqf "$dir" '.cap_exhausted.kind'), expected blocking-reviews"
  [ "$(jqf "$dir" '.cap_exhausted.request_attempts')/$(jqf "$dir" '.cap_exhausted.max_request_attempts')" = 10/10 ] \
    || fail "#1560 both spent: did not also report the spent request ceiling"
  [ "$FAIL" -ne "$before" ] || pass "#1560: with both budgets spent, the blocking budget names the stop"

  before=$FAIL
  dir=$(make_budget_case "blocking-ceiling-only" "$(responses 9 blocking)")
  rc=$(run_budget_case "$dir" cap_at_limit)
  [ "$rc" = 7 ] || fail "#1560 ceiling only: expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.cap_exhausted.kind')" = request-ceiling ] \
    || fail "#1560 ceiling only: stop kind is $(jqf "$dir" '.cap_exhausted.kind'), expected request-ceiling"
  [ "$(jqf "$dir" '.cap_exhausted.blocking_reviews')/$(jqf "$dir" '.cap_exhausted.max_blocking_reviews')" = 9/10 ] \
    || fail "#1560 ceiling only: did not report the remaining blocking budget"
  [ "$FAIL" -ne "$before" ] || pass "#1560: a spent request ceiling with blocking budget left is a request-ceiling stop"
}

test_blocking_budget_governing_value() {
  local dir rc before=$FAIL value
  dir=$(make_budget_case "blocking-budget-three" "$(responses 3 blocking)")
  printf '  max_blocking_reviews: 3\n' >> "$dir/state/base-review-policy.yml"
  printf '3\n' >"$dir/state/ledger-max"
  rc=$(run_budget_case "$dir" fresh)
  [ "$rc" = 7 ] || fail "#1560 budget 3: expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.cap_exhausted.max_blocking_reviews')" = 3 ] \
    || fail "#1560 budget 3: did not apply the configured budget"
  [ "$FAIL" -ne "$before" ] || pass "#1560: a configured blocking-review budget governs a new request"

  before=$FAIL
  dir=$(make_budget_case "blocking-budget-candidate" "$(responses 3 blocking)")
  printf '  max_blocking_reviews: 999\n' >> "$dir/.github/review-policy.yml"
  printf '  max_blocking_reviews: 3\n' >> "$dir/state/base-review-policy.yml"
  printf '3\n' >"$dir/state/ledger-max"
  rc=$(run_budget_case "$dir" fresh)
  [ "$rc" = 7 ] || fail "#1560 candidate budget: expected exit 7, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = 0 ] || fail "#1560 candidate budget: candidate raised its own budget"
  [ "$FAIL" -ne "$before" ] || pass "#1560: a PR cannot raise its governing blocking-review budget"

  for value in false null -1 "'ten'" 1234567890; do
    before=$FAIL
    dir=$(make_budget_case "blocking-budget-invalid-$value" '[]')
    printf '  max_blocking_reviews: %s\n' "$value" >> "$dir/state/base-review-policy.yml"
    rc=$(run_budget_case "$dir" fresh)
    [ "$rc" = 3 ] || fail "#1560 invalid budget $value: expected exit 3, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = 0 ] || fail "#1560 invalid budget $value: posted despite an invalid budget"
    [ "$FAIL" -ne "$before" ] || pass "#1560: invalid governing blocking-review budget $value fails closed"
  done
}

# Missing, unreadable or conflicting ledger evidence never counts as
# available budget: each exits 3 before any request is posted.
test_blocking_budget_fails_closed() {
  local name dir rc before
  for name in missing nonzero garbage not-object head-mismatch author-mismatch class-missing unsolicited-not-bool conflicting-not-bool unknown-class two-documents budget-mismatch policy-mismatch null-timestamp; do
    before=$FAIL
    dir=$(make_budget_case "blocking-fail-$name" '[]')
    case "$name" in
      missing) rm -f "$dir/ledger-stub.sh" ;;
      nonzero) printf '3\n' >"$dir/state/ledger-rc" ;;
      garbage) printf 'not json\n' >"$dir/state/ledger-raw" ;;
      not-object) printf '[]\n' >"$dir/state/ledger-raw" ;;
      head-mismatch) printf 'other-sha\n' >"$dir/state/ledger-head" ;;
      author-mismatch) printf 'someone-else\n' >"$dir/state/ledger-author" ;;
      # One broken field each, on an otherwise valid response that would NOT
      # count (unsolicited), so accepting it would post: each case fails only
      # if its own check is missing (#1560 canary, finding 6).
      class-missing) printf '[{"unsolicited":true,"conflicting":false,"first_at":"2026-06-04T00:00:00Z"}]\n' >"$dir/state/ledger-responses.json" ;;
      unsolicited-not-bool) printf '[{"class":"blocking","unsolicited":"no","conflicting":false,"first_at":"2026-06-04T00:00:00Z"}]\n' >"$dir/state/ledger-responses.json" ;;
      conflicting-not-bool) printf '[{"class":"blocking","unsolicited":true,"conflicting":"no","first_at":"2026-06-04T00:00:00Z"}]\n' >"$dir/state/ledger-responses.json" ;;
      unknown-class) printf '[{"class":"severe","unsolicited":true,"conflicting":false,"first_at":"2026-06-04T00:00:00Z"}]\n' >"$dir/state/ledger-responses.json" ;;
      two-documents) : >"$dir/state/ledger-twice" ;;
      budget-mismatch) printf '3\n' >"$dir/state/ledger-max" ;;
      policy-mismatch) printf '1-1\n' >"$dir/state/ledger-policy" ;;
      null-timestamp) printf '[{"class":"blocking","unsolicited":true,"conflicting":false,"first_at":null}]\n' >"$dir/state/ledger-responses.json" ;;
    esac
    rc=$(run_budget_case "$dir" fresh)
    [ "$rc" = 3 ] || fail "#1560 fail-closed $name: expected exit 3, got $rc; err=$(cat "$dir/err.log")"
    [ "$(trig_count "$dir")" = 0 ] || fail "#1560 fail-closed $name: posted a trigger"
    [ "$FAIL" -ne "$before" ] || pass "#1560: ledger evidence that is $name fails closed with no trigger"
  done
}

# An idempotent skip writes nothing, so it never runs the ledger.
test_blocking_budget_not_read_without_a_write() {
  local dir rc before=$FAIL
  dir=$(make_budget_case "blocking-idempotent" "$(responses 10 blocking)")
  rc=$(run_budget_case "$dir" dup_author)
  [ "$rc" = 0 ] || fail "#1560 idempotent: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(ledger_calls "$dir")" = 0 ] || fail "#1560 idempotent: ran the ledger without a write"
  [ "$FAIL" -ne "$before" ] || pass "#1560: an idempotent skip does not read the blocking-review budget"
}

# ---------------------------------------------------------------------------
# #798 — the AUTOMATIC trigger must not fire on a content-free update-branch
# head.
#
# `gh pr update-branch` mints a new head SHA that changes no file in the PR's
# own diff. With `required_status_checks.strict: true` every merge forces one
# on every other open PR, so a batch of N PRs drew O(N²) Codex rounds that
# responded to no code change.
#
# Two layers are covered, and both directions in each:
#
#   D–G  scripts/workflow/codex_auto_trigger_gate.sh, the decision itself, run
#        for real over the real external_review_fingerprint.sh with only `gh`
#        stubbed. D and E differ ONLY in which head is passed — same PR, same
#        files, same reviewed-commit history — so a gate that ignored content
#        could not pass both.
#   H–J  the call site in codex-review-request.sh. H and I differ ONLY in
#        whether MERGEPATH_CODEX_AUTO_TRIGGER is set, against an identical
#        skip-verdict gate, so a wiring that always consulted the gate (or
#        never did) fails one of them.
#   K    agent-review.yml declares the flag on the step that reaches this
#        script, asserted by PARSING the workflow rather than grepping it.
# ---------------------------------------------------------------------------

GATE_SRC="$ROOT/scripts/workflow/codex_auto_trigger_gate.sh"
FP_SRC="$ROOT/scripts/workflow/external_review_fingerprint.sh"
# The gate delegates its whole decision to the carry-forward helper, so these
# cases run the REAL one — a stub would make them assert the stub.
CF_SRC="$ROOT/scripts/workflow/external_review_carryforward.sh"

# Distinct 40-hex commit SHAs. HEAD_UNCHANGED is the update-branch head:
# different SHA, identical tree entries for the PR's changed path at both the
# head and the (moved) merge base. HEAD_CHANGED carries a different blob.
SHA_REVIEWED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_UNCHANGED="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_CHANGED="cccccccccccccccccccccccccccccccccccccccc"

make_gate_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts/workflow" "$dir/scripts/lib" "$dir/.github" "$dir/bin"
  cp "$GATE_SRC" "$FP_SRC" "$CF_SRC" \
     "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" \
     "$ROOT/scripts/workflow/parse_policy_list.sh" \
     "$ROOT/scripts/workflow/match_protected_paths.sh" \
     "$dir/scripts/workflow/"
  chmod +x "$dir/scripts/workflow/"*.sh
  # #799: both external_review_* helpers hard-source ../lib/gh-api-scalar.sh
  # (exit 2 if absent) for their sha reads, so the fixture tree needs it.
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"

  # threshold 1 with a one-line diff makes the PR require external review, so
  # the fingerprint helper runs its full tree-fetching path.
  cat >"$dir/.github/review-policy.yml" <<'EOF'
external_review_threshold: 1
external_review_paths: []
codex:
  enabled: true
EOF

  # gh stub. Trees are keyed by commit: the reviewed head and the
  # update-branch head resolve to the SAME tree (t1); the changed head
  # resolves to t2. The merge base MOVES between them (mbold → mbnew) exactly
  # as a real update-branch moves it, and both merge-base trees omit the PR's
  # changed path — so a base-only advance leaves the fingerprint identical
  # while a content edit does not.
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
JQEXPR=""; PATHARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) JQEXPR="$2"; shift 2 ;;
    *) [ -n "$PATHARG" ] || PATHARG="$1"; shift ;;
  esac
done
PATHARG=${PATHARG%%\?*}
emit() { if [ -n "$JQEXPR" ]; then printf '%s' "$1" | jq -r "$JQEXPR"; else printf '%s\n' "$1"; fi; exit 0; }
tree_for() {
  case "$1" in
    t1) printf '{"truncated":false,"tree":[{"path":"foo.txt","type":"blob","mode":"100644","sha":"blob1"}]}' ;;
    t2) printf '{"truncated":false,"tree":[{"path":"foo.txt","type":"blob","mode":"100644","sha":"blob2"}]}' ;;
    *)  printf '{"truncated":false,"tree":[]}' ;;
  esac
}
commit_tree() {
  case "$1" in
    aaaa*) printf 't1' ;;
    bbbb*) printf 't1' ;;
    cccc*) printf 't2' ;;
    *)     printf 't0' ;;
  esac
}
merge_base_for() {
  case "$1" in
    aaaa*) printf 'dddddddddddddddddddddddddddddddddddddddd' ;;
    *)     printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ;;
  esac
}
case "$PATHARG" in
  repos/owner/repo/pulls/999/files)
    emit '[{"filename":"foo.txt","additions":1,"deletions":0}]' ;;
  repos/owner/repo/pulls/999/reviews)
    emit "$(cat "${GATE_TEST_REVIEWS_JSON:?}")" ;;
  repos/owner/repo/issues/999/comments)
    [ "${GATE_TEST_COMMENTS_FAIL:-0}" != "1" ] || { echo "comments-boom" >&2; exit 1; }
    emit "$(cat "${GATE_TEST_COMMENTS_JSON:?}")" ;;
  repos/owner/repo/pulls/999)
    emit '{"base":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}' ;;
  repos/owner/repo/compare/*)
    emit "$(printf '{"merge_base_commit":{"sha":"%s"}}' "$(merge_base_for "${PATHARG##*...}")")" ;;
  repos/owner/repo/commits/*)
    sha=${PATHARG##*/}
    emit "$(printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}}}' "$sha" "$(commit_tree "$sha")")" ;;
  repos/owner/repo/git/trees/*)
    emit "$(tree_for "${PATHARG##*/}")" ;;
  *) echo "unexpected gh api endpoint: $PATHARG" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  # BOTH halves are load-bearing: the `Reviewed commit:` anchor AND the
  # affirmative verdict wording. The gate asks whether a prior verdict CARRIES
  # to this head, which is strictly narrower than "Codex looked at a commit" —
  # see case L for the difference and why it matters.
  printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-07-29T10:00:00Z","body":"Codex Review: Didn'"'"'t find any major issues. :+1:\\n\\n**Reviewed commit:** %s"}]\n' \
    "$SHA_REVIEWED" >"$dir/comments.json"
  printf '[]\n' >"$dir/reviews.json"
  printf '%s\n' "$dir"
}

run_gate() {
  local dir=$1 head=$2 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GATE_TEST_COMMENTS_JSON="$dir/comments.json" \
      GATE_TEST_REVIEWS_JSON="$dir/reviews.json" \
      GATE_TEST_COMMENTS_FAIL="${GATE_TEST_COMMENTS_FAIL:-0}" \
      ./scripts/workflow/codex_auto_trigger_gate.sh \
        --repo owner/repo --pr 999 --head "$head" \
      >"$dir/gate.json" 2>"$dir/gate.err"
  ) || rc=$?
  printf '%s\n' "$rc"
}

gatef() { jq -r "$2" "$1/gate.json"; }

# D: content-free update-branch head → do NOT trigger
test_gate_skips_content_free_head() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-unchanged")
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "D: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "false" ] \
    || fail "D: trigger=$(gatef "$dir" '.trigger'), expected false; reason=$(gatef "$dir" '.reason')"
  [ "$(gatef "$dir" '.reviewed_commit')" = "$SHA_REVIEWED" ] \
    || fail "D: reviewed_commit=$(gatef "$dir" '.reviewed_commit'), expected $SHA_REVIEWED"
  case "$(gatef "$dir" '.fingerprint')" in
    external-review:v2:*) ;;
    *) fail "D: expected the existing external-review:v2 fingerprint, got $(gatef "$dir" '.fingerprint')" ;;
  esac
  [ "$FAIL" -ne "$before" ] || pass "D: content-free update-branch head → no automatic @codex trigger (#798)"
}

# E: same PR, same history, head whose content DIFFERS → still trigger
test_gate_triggers_on_real_content_change() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-changed")
  rc=$(run_gate "$dir" "$SHA_CHANGED")
  [ "$rc" = "0" ] || fail "E: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "E: trigger=$(gatef "$dir" '.trigger'), expected true — a real content change must still auto-post (#631/#648)"
  [ "$(gatef "$dir" '.reviewed_commit')" = "" ] \
    || fail "E: reviewed_commit=$(gatef "$dir" '.reviewed_commit'), expected empty on a trigger verdict"
  [ "$FAIL" -ne "$before" ] || pass "E: head with changed content still triggers (explicit-invocation requirement intact)"
}

# F: nothing Codex has reviewed → nothing to compare → trigger
test_gate_triggers_without_prior_review() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-noprior")
  printf '[]\n' >"$dir/comments.json"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "F: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "F: trigger=$(gatef "$dir" '.trigger'), expected true with no prior Codex signal"
  [ "$FAIL" -ne "$before" ] || pass "F: no Codex-reviewed commit to compare against → triggers"
}

# G: an unreadable API must fail OPEN (over-trigger), never suppress
test_gate_fails_open_on_api_error() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-apierr")
  rc=$(GATE_TEST_COMMENTS_FAIL=1 run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "G: expected exit 0 (a decision), got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "G: trigger=$(gatef "$dir" '.trigger'), expected true — an unreadable API must not suppress a review"
  [ "$FAIL" -ne "$before" ] || pass "G: API read failure fails open (posts the trigger)"
}

# L: the ONLY prior Codex signal is a COMMENTED review object — a findings
# round, not a verdict. The head is content-free in exactly the way case D is,
# so a gate that asked "did Codex LOOK at this content" would suppress here.
# It must not: external_review_carryforward.sh scores every review object
# non-affirmative, so nothing would carry to the new head. Suppressing would
# leave the head with no head-anchored signal, no carry-forward clearance, and
# no automatic caller left to re-request the review — the merge-clearance gate
# would wait forever. (Codex P1 on the #798 PR.)
test_gate_triggers_when_only_signal_is_a_review_object() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-reviewobj")
  printf '[]\n' >"$dir/comments.json"
  printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-07-29T10:00:00Z","commit_id":"%s"}]\n' \
    "$SHA_REVIEWED" >"$dir/reviews.json"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "L: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "L: trigger=$(gatef "$dir" '.trigger'), expected true — a findings round carries no clearance, so suppressing would strand the head; reason=$(gatef "$dir" '.reason')"
  [ "$(gatef "$dir" '.reviewed_commit')" = "" ] \
    || fail "L: reviewed_commit=$(gatef "$dir" '.reviewed_commit'), expected empty on a trigger verdict"
  [ "$FAIL" -ne "$before" ] || pass "L: a COMMENTED review object alone does not suppress (it carries no clearance)"
}

# M: an affirmative verdict on the reviewed commit that a LATER findings round
# on that same commit supersedes. Carry-forward revokes it; the gate must
# inherit that revocation rather than matching the stale verdict. Pins that the
# delegation is real — a gate that only copied the "affirmative verdict"
# predicate would still suppress here.
test_gate_triggers_when_verdict_is_superseded() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-superseded")
  printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-07-29T12:00:00Z","commit_id":"%s"}]\n' \
    "$SHA_REVIEWED" >"$dir/reviews.json"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "M: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "M: trigger=$(gatef "$dir" '.trigger'), expected true — a superseded verdict must not suppress; reason=$(gatef "$dir" '.reason')"
  [ "$FAIL" -ne "$before" ] || pass "M: a verdict superseded by a later findings round does not suppress"
}

# N: carry-forward reports a NON-BOOLEAN `carried`. `.carried | tostring` would
# coerce the string "true" into consent, and a JSON string is what a truncated
# or doubly-encoded payload most plausibly degrades into. `carried` is the one
# field that suppresses a review, so a wrong-typed value must read as no answer,
# not as yes. (CodeRabbit Major on #880.) The carry-forward helper is stubbed
# here on purpose: this asserts the GATE's handling of a malformed contract,
# which the real helper cannot produce.
test_gate_requires_boolean_carried() {
  local dir rc before=$FAIL payload
  for payload in '{"carried":"true"}' '{"carried":1}' '{"carried":null}' '{}'; do
    dir=$(make_gate_case "gate-carriedtype-$(printf '%s' "$payload" | tr -cd '[:alnum:]')")
    cat >"$dir/scripts/workflow/external_review_carryforward.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$payload'
EOF
    chmod +x "$dir/scripts/workflow/external_review_carryforward.sh"
    rc=$(run_gate "$dir" "$SHA_UNCHANGED")
    [ "$rc" = "0" ] || fail "N: expected exit 0 for $payload, got $rc; err=$(cat "$dir/gate.err")"
    [ "$(gatef "$dir" '.trigger')" = "true" ] \
      || fail "N: trigger=$(gatef "$dir" '.trigger') for carried=$payload, expected true — a non-boolean carried is not consent; reason=$(gatef "$dir" '.reason')"
  done
  # Control: the same stub with a real boolean DOES suppress, so N is asserting
  # the type check and not merely that a stubbed helper is ignored.
  dir=$(make_gate_case "gate-carriedtype-control")
  cat >"$dir/scripts/workflow/external_review_carryforward.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"carried":true,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_time":"2026-07-29T10:00:00Z","fingerprint":"external-review:v2:deadbeef"}'
EOF
  chmod +x "$dir/scripts/workflow/external_review_carryforward.sh"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "N: control expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "false" ] \
    || fail "N: control trigger=$(gatef "$dir" '.trigger'), expected false — a boolean true must still suppress"
  [ "$FAIL" -ne "$before" ] || pass "N: a non-boolean 'carried' is not consent (boolean true still suppresses)"
}

# --- call-site wiring in codex-review-request.sh ----------------------------

# Writes a gate stub with a fixed verdict, so H/I isolate the env flag.
write_gate_stub() {
  local dir=$1 trigger=$2
  cat >"$dir/gate-stub.sh" <<EOF
#!/usr/bin/env bash
printf '{"trigger": $trigger, "reason": "stubbed"}\n'
EOF
  chmod +x "$dir/gate-stub.sh"
  printf '%s\n' "$dir/gate-stub.sh"
}

run_trigger_only_auto() {
  local dir=$1 scenario=$2 auto=$3 gate=$4 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO="$scenario" \
      MERGEPATH_CODEX_AUTO_TRIGGER="$auto" \
      MERGEPATH_CODEX_AUTO_TRIGGER_GATE_CMD="$gate" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

# H: automatic caller + gate says "content-free" → no post
test_wiring_auto_caller_honors_skip() {
  local dir gate rc before=$FAIL
  dir=$(make_case "auto-skip")
  gate=$(write_gate_stub "$dir" false)
  rc=$(run_trigger_only_auto "$dir" fresh true "$gate")
  [ "$rc" = "0" ] || fail "H: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "H: expected 0 posts, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "H: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected false"
  [ "$FAIL" -ne "$before" ] || pass "H: automatic caller honors the gate's content-free verdict (no post)"
}

# I: SAME gate verdict, but the caller is an agent (flag unset) → still posts
test_wiring_manual_caller_ignores_gate() {
  local dir gate rc before=$FAIL
  dir=$(make_case "manual-ignores")
  gate=$(write_gate_stub "$dir" false)
  rc=$(run_trigger_only_auto "$dir" fresh "" "$gate")
  [ "$rc" = "0" ] || fail "I: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] \
    || fail "I: expected 1 post — a manual --trigger-only must never be suppressed (#631/#648), got $(trig_count "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "I: manual invocation ignores the gate entirely (explicit invocation always posts)"
}

# J: automatic caller, gate helper absent (bootstrap / mid-sync skew) → posts
test_wiring_missing_gate_fails_open() {
  local dir rc before=$FAIL
  dir=$(make_case "auto-nogate")
  rc=$(run_trigger_only_auto "$dir" fresh true "$dir/does-not-exist.sh")
  [ "$rc" = "0" ] || fail "J: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "J: expected 1 post when the gate helper is missing, got $(trig_count "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "J: missing gate helper fails open (soft-pass, posts the trigger)"
}

# O: undispositioned feedback blocks BEFORE the author-attributed trigger.
test_feedback_accounting_blocks_trigger() {
  local dir gate rc before=$FAIL
  dir=$(make_case "feedback-unaccounted")
  gate="$dir/feedback-accounting-stub.sh"
  cat >"$gate" <<'EOF'
#!/bin/sh
printf '%s\n' '{"status":"unaccounted","posted":2,"accounted":1}'
exit 1
EOF
  chmod +x "$gate"
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO=fresh \
      MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$gate" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  rc=${rc:-0}
  [ "$rc" = "6" ] || fail "O: expected feedback-unaccounted exit 6, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "O: accounting miss must block before @codex post"
  [ "$FAIL" -ne "$before" ] || pass "O: unaccounted feedback exits 6 before a new @codex trigger"
  # An exhausted request never reaches the write that accounting protects.
  rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" CODEX_TEST_SCENARIO=cap_at_limit \
      MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$gate" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  [ "$rc" = 7 ] || fail "O: exhausted cap with unaccounted feedback expected exit 7, got $rc"
  [ "$(trig_count "$dir")" = 0 ] || fail "O: cap exhaustion with feedback posted a trigger"
  [ "$(jqf "$dir" '.cap_exhausted.request_attempts')" = 10 ] \
    || fail "O: cap exhaustion with feedback lost the request count"
  [ "$FAIL" -ne "$before" ] || pass "O: exhaustion is reported before accounting without a new write"
}

# K: a registered approval stays in the candidate-controlled read-only lane.
# Parsed as YAML, not grepped: the claim is about executable job wiring, and a
# text match cannot distinguish a step body from comments elsewhere in the file.
test_workflow_declares_auto_trigger_flag() {
  local wf="$ROOT/.github/workflows/agent-review.yml" before=$FAIL
  if [ ! -f "$wf" ]; then
    echo "NOTE: K skipped — $wf not present in this checkout"
    return 0
  fi
  command -v ruby >/dev/null 2>&1 \
    || { fail "K: ruby is required to parse the workflow (refusing to pass on an unrun assertion)"; return 0; }
  if ! ruby -ryaml -e '
    wf = YAML.unsafe_load_file(ARGV[0]) rescue YAML.load_file(ARGV[0])
    job = (wf["jobs"] || {})["auto-merge-on-approval"] or abort("job auto-merge-on-approval not found")
    steps = job["steps"] || []
    abort("approval job must not wait for CodeRabbit") \
      if steps.any? { |s| s.is_a?(Hash) && s["name"].to_s.include?("CodeRabbit") }
    permissions = job["permissions"] || {}
    expected_permissions = {
      "actions" => "read",
      "checks" => "read",
      "contents" => "read",
      "issues" => "read",
      "pull-requests" => "read",
      "statuses" => "read",
    }
    abort("candidate readiness permissions must be the exact read-only allowlist") \
      unless permissions == expected_permissions
    serialized_job = job.to_s
    secrets_context_pattern = /(^|[^A-Za-z0-9_])secrets([^A-Za-z0-9_]|$)/i
    uses_secrets_context = ->(value) { value.to_s.match?(secrets_context_pattern) }
    candidate_readiness_uses_secrets_context = lambda do |candidate_job, workflow|
      candidate_job.key?("secrets") ||
        uses_secrets_context.call(candidate_job) ||
        uses_secrets_context.call(workflow["env"] || {})
    end
    expression_secret_fixtures = {
      "toJSON secrets context" => %q(${{ toJSON(secrets) }}),
      "whitespace-indexed reviewer secret" => %q(${{ secrets ["REVIEWER_ASSIGNMENT_TOKEN"] }}),
      "mixed-case dotted reviewer secret" => %q(${{ Secrets.REVIEWER_ASSIGNMENT_TOKEN }}),
      "mixed-case toJSON secrets context" => %q(${{ toJSON(SeCrEtS) }}),
    }
    expression_secret_fixtures.each do |name, fixture|
      abort("candidate readiness secrets-context matcher missed #{name}") \
        unless uses_secrets_context.call(fixture)
    end
    inherited_env_fixture = YAML.safe_load(<<~YAML)
      name: inherited-secret-fixture
      env:
        INHERITED: ${{ SeCrEtS ["REVIEWER_ASSIGNMENT_TOKEN"] }}
      jobs: {}
    YAML
    abort("candidate readiness guard missed inherited top-level env secret context") \
      unless candidate_readiness_uses_secrets_context.call({}, inherited_env_fixture)
    abort("candidate readiness must not materialize any repository secret") \
      if candidate_readiness_uses_secrets_context.call(job, wf)
    privileged_credentials_pattern = /AUTHOR_MERGE_TOKEN|MERGE_QUEUE_POLICY_TOKEN|MERGE_QUEUE_SOURCE_TOKEN/i
    abort("candidate readiness privileged-credential matcher missed mixed case") \
      unless %q(aUtHoR_mErGe_ToKeN).match?(privileged_credentials_pattern)
    privileged_credential_surface = YAML.dump(job)
      .gsub(/^(\s*id:\s*)author_merge_token\s*$/i, "\\1read_only_readiness")
      .gsub(/steps\.author_merge_token/i, "steps.read_only_readiness")
    privileged_credential_surface += YAML.dump(wf["env"] || {})
    abort("candidate readiness must not reference a privileged credential") \
      if privileged_credential_surface.match?(privileged_credentials_pattern)
    step = steps.find { |s| s.is_a?(Hash) && s["name"] == "Report stable read-only readiness" } \
      or abort("step \"Report stable read-only readiness\" not found")
    run = step["run"].to_s
    abort("read-only readiness must delegate mutable gates to the trusted continuation") \
      unless run.include?("trusted Agent Review Pipeline workflow_run continuation")
    abort("candidate readiness must not invoke the privileged continuation helper") \
      if run.include?("approval-merge-continuation.sh")
    mutation_names = /gh\s+pr\s+merge|addPullRequestToMergeQueue|enqueuePullRequest|dequeuePullRequest|enablePullRequestAutoMerge|disablePullRequestAutoMerge|mergePullRequest/
    rest_merge_endpoint = serialized_job.match?(%r{pulls/[^\s]+/merge})
    rest_write_method = serialized_job.match?(/(?:--method|-X)(?:=|\s)*(?:PUT|POST)\b/i)
    abort("candidate readiness must not invoke a merge or queue mutation") \
      if serialized_job.match?(mutation_names) || (rest_merge_endpoint && rest_write_method)
  ' "$wf" 2>"$WORKDIR/k.err"; then
    fail "K: $(cat "$WORKDIR/k.err")"
  fi
  [ "$FAIL" -ne "$before" ] || pass "K: registered approval remains read-only and delegates privileged continuation"
}

# #1543: actual requester entrypoint must post when gate-(b) evidence is
# insufficient, while a substantive discretionary-only review still deduplicates.
for scenario in reply-only body-P1 body-P2; do
  dir=$(make_case "shared-clearance-$scenario")
  expected=1; [ "$scenario" != body-P2 ] || expected=0
  rc=$(CODEX_TEST_HEAD=abcdef0123456789000000000000000000000000 run_trigger_only "$dir" "$scenario")
  if [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = "$expected" ]; then
    pass "#1543: $scenario posts exactly $expected request(s)"
  else
    fail "#1543: $scenario rc=$rc trigger-count=$(trig_count "$dir")"; cat "$dir/err.log" >&2
  fi
done

# --- #2166: the moving-head guard ------------------------------------------
# A Codex request goes out once per batch, on a head that is final for the
# round. The requester enforces two proxies before a NEW trigger write and
# refuses with exit 8 (no write) unless the caller allows a moving head.

# MH1: a head pushed 60s ago is under the 300s default → exit 8, no post
test_guard_refuses_young_head() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-young")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" completed "" --trigger-only)
  [ "$rc" = "8" ] || fail "MH1: expected exit 8, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "MH1: expected 0 posts on a young head, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "MH1: trigger_posted must be false"
  [ "$(jqf "$dir" '.moving_head.reasons | join(",")')" = "head-age" ] || fail "MH1: reasons=$(jqf "$dir" '.moving_head.reasons'), expected [head-age]"
  [ "$(jqf "$dir" '.moving_head.min_age_seconds')" = "300" ] || fail "MH1: min_age_seconds=$(jqf "$dir" '.moving_head.min_age_seconds'), expected the 300 default"
  jq -e '.moving_head.age_seconds | type == "number" and . < 300' "$dir/out.json" >/dev/null || fail "MH1: age_seconds should be a number under 300: $(jqf "$dir" '.moving_head.age_seconds')"
  [ "$(jqf "$dir" '.moving_head.check_status')" = "completed" ] || fail "MH1: check_status=$(jqf "$dir" '.moving_head.check_status'), expected completed"
  [ "$(jqf "$dir" '.moving_head.check_kind')/$(jqf "$dir" '.moving_head.check_name')" = "workflow/repo-lint" ] || fail "MH1: signal=$(jqf "$dir" '.moving_head.check_kind')/$(jqf "$dir" '.moving_head.check_name'), expected workflow/repo-lint by default"
  grep -q 'refusing to post' "$dir/err.log" || fail "MH1: refusal not logged"
  [ "$FAIL" -ne "$before" ] || pass "MH1: a head younger than request_min_head_age_seconds is refused with exit 8 and no post"
}

# MH2: same young head, --allow-moving-head → warns and posts once
test_guard_allow_flag_posts_with_warning() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-allow")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" completed "" --trigger-only --allow-moving-head)
  [ "$rc" = "0" ] || fail "MH2: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "MH2: expected 1 post with --allow-moving-head, got $(trig_count "$dir")"
  grep -q 'WARNING: head does not look final' "$dir/err.log" || fail "MH2: the allow path must still warn"
  [ "$FAIL" -ne "$before" ] || pass "MH2: --allow-moving-head downgrades the refusal to a warning and posts"
}

# MH3: old head, the repo has a repo-lint workflow, but no run of it exists for
# the head yet → exit 8 (check-missing)
test_guard_refuses_unscheduled_check() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-nolint")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" missing "" --trigger-only)
  [ "$rc" = "8" ] || fail "MH3: expected exit 8, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "MH3: expected 0 posts, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.moving_head.reasons | join(",")')" = "check-missing" ] || fail "MH3: reasons=$(jqf "$dir" '.moving_head.reasons'), expected [check-missing]"
  [ "$(jqf "$dir" '.moving_head.check_name')" = "repo-lint" ] || fail "MH3: check_name=$(jqf "$dir" '.moving_head.check_name'), expected the repo-lint workflow default"
  [ "$(jqf "$dir" '.moving_head.check_status')" = "missing" ] || fail "MH3: check_status=$(jqf "$dir" '.moving_head.check_status'), expected missing"
  # Another workflow's run on the head is not repo-lint: the client-side
  # filter must not accept it.
  dir=$(make_case "guard-otherworkflow")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" otherworkflow "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(trig_count "$dir")" = "0" ] || fail "MH3b: another workflow's run must not satisfy the repo-lint signal (rc=$rc posts=$(trig_count "$dir"))"
  # Under the exact-name OVERRIDE, a run under another name is not this check.
  dir=$(make_case "guard-override-deeplint")
  printf '  request_requires_check: lint-fast\n' >>"$dir/.github/review-policy.yml"
  rc=$(CODEX_TEST_CHECK_RUNS=deeplint run_guard "$dir" fresh "$OLD_HEAD" completed "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(trig_count "$dir")" = "0" ] && [ "$(jqf "$dir" '.moving_head.check_kind')" = "check" ] \
    || fail "MH3c: under request_requires_check: lint-fast, a check-run named lint must not satisfy it (rc=$rc posts=$(trig_count "$dir"))"
  [ "$FAIL" -ne "$before" ] || pass "MH3: an old head with no repo-lint run yet is refused with exit 8 (check-missing)"
}

# MH4: both signals at once are reported together
test_guard_reports_both_reasons() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-both")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" missing "" --trigger-only)
  [ "$rc" = "8" ] || fail "MH4: expected exit 8, got $rc"
  [ "$(jqf "$dir" '.moving_head.reasons | join(",")')" = "head-age,check-missing" ] || fail "MH4: reasons=$(jqf "$dir" '.moving_head.reasons'), expected both"
  [ "$FAIL" -ne "$before" ] || pass "MH4: a young head with no scheduled check reports both reasons"
}

# MH5: a queued run counts as scheduled (the Actions backlog is not the signal);
# an old head with one posts.
test_guard_accepts_queued_check() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-queued")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" queued "" --trigger-only)
  [ "$rc" = "0" ] || fail "MH5: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "MH5: expected 1 post, got $(trig_count "$dir")"
  grep -q "'repo-lint' is queued on HEAD" "$dir/err.log" || fail "MH5: queued status not logged"
  [ "$FAIL" -ne "$before" ] || pass "MH5: a queued repo-lint run satisfies the CI-pickup signal"
}

# MH6: an unreadable check-runs read fails OPEN with a distinct log line (this
# is a cycle-time guard, not a merge gate); the age signal still decides.
test_guard_unreadable_check_runs_fails_open() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-unreadable")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" unreadable "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH6: unreadable check-runs must not refuse (rc=$rc posts=$(trig_count "$dir"))"
  grep -q 'unreadable; not enforced' "$dir/err.log" || fail "MH6: fail-open must be logged distinctly"
  dir=$(make_case "guard-garbage")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" garbage "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH6b: a non-JSON check-runs body must not refuse (rc=$rc posts=$(trig_count "$dir"))"
  # ...but an unreadable check read never masks a young head.
  dir=$(make_case "guard-unreadable-young")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" unreadable "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(trig_count "$dir")" = "0" ] || fail "MH6c: a young head is refused even when check-runs are unreadable (rc=$rc posts=$(trig_count "$dir"))"
  [ "$(jqf "$dir" '.moving_head.check_status')" = "unreadable" ] || fail "MH6c: check_status should report unreadable"
  [ "$FAIL" -ne "$before" ] || pass "MH6: an unreadable CI-pickup read fails open and is logged; it never masks the age signal"
}

# MH7: the policy knobs disable each signal: age 0 and an empty check name
test_guard_policy_knobs_disable_signals() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-knobs-off")
  printf '  request_min_head_age_seconds: 0\n  request_requires_check: ""\n' >>"$dir/.github/review-policy.yml"
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" missing "" --trigger-only)
  [ "$rc" = "0" ] || fail "MH7: expected exit 0 with both knobs off, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "MH7: expected 1 post, got $(trig_count "$dir")"
  grep -q 'moving-head guard' "$dir/err.log" && fail "MH7: no guard signal should be evaluated with both knobs off"
  # A raised age floor is honoured: an hour-old head is young under 7200s.
  dir=$(make_case "guard-knob-age")
  printf '  request_min_head_age_seconds: 7200\n' >>"$dir/.github/review-policy.yml"
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" completed "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(jqf "$dir" '.moving_head.min_age_seconds')" = "7200" ] || fail "MH7b: a configured age floor must be enforced (rc=$rc)"
  # A renamed check is looked up by its configured name.
  dir=$(make_case "guard-knob-name")
  printf '  request_requires_check: not-lint\n' >>"$dir/.github/review-policy.yml"
  # The repo-lint run is MISSING here: the override replaces the workflow
  # signal rather than adding to it.
  rc=$(CODEX_TEST_CHECK_RUNS=othername run_guard "$dir" fresh "$OLD_HEAD" missing "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH7c: a configured check name must be the one looked up, replacing the repo-lint signal (rc=$rc posts=$(trig_count "$dir"))"
  # A malformed age floor is a config error, not a silent default.
  dir=$(make_case "guard-knob-bad")
  printf '  request_min_head_age_seconds: soon\n' >>"$dir/.github/review-policy.yml"
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" completed "" --trigger-only)
  [ "$rc" = "3" ] && [ "$(trig_count "$dir")" = "0" ] || fail "MH7d: a non-integer age floor must exit 3 before any write (rc=$rc)"
  [ "$FAIL" -ne "$before" ] || pass "MH7: request_min_head_age_seconds / request_requires_check are honoured, and 0 / empty disable each signal"
}

# #2340: value and presence use YAML for flow mappings and quoted keys too.
test_guard_check_signal_yaml_forms() {
  refresh_head_dates
  local dir rc shape before=$FAIL
  for shape in flow-name quoted-name flow-empty flow-null flow-absent; do
    dir=$(make_case "guard-yaml-$shape")
    case "$shape" in
      flow-name) printf '%s\n' 'author_identity: nathanjohnpayne' 'codex: {request_by_default: true, request_requires_check: not-lint}' >"$dir/.github/review-policy.yml" ;;
      quoted-name) printf '%s\n' 'author_identity: nathanjohnpayne' 'codex:' '  request_by_default: true' '  "request_requires_check": not-lint' >"$dir/.github/review-policy.yml" ;;
      flow-empty) printf '%s\n' 'author_identity: nathanjohnpayne' 'codex: {request_by_default: true, request_requires_check: ""}' >"$dir/.github/review-policy.yml" ;;
      flow-null) printf '%s\n' 'author_identity: nathanjohnpayne' 'codex: {request_by_default: true, request_requires_check: null}' >"$dir/.github/review-policy.yml" ;;
      flow-absent) printf '%s\n' 'author_identity: nathanjohnpayne' 'codex: {request_by_default: true}' >"$dir/.github/review-policy.yml" ;;
    esac
    case "$shape" in
      *name)
        rc=$(CODEX_TEST_CHECK_RUNS=missing run_guard "$dir" fresh "$OLD_HEAD" completed "" --trigger-only)
        [ "$rc" = 8 ] && [ "$(trig_count "$dir")" = 0 ] || fail "$shape: missing named check must refuse (rc=$rc)"
        ;;
      flow-empty|flow-null)
        rc=$(run_guard "$dir" fresh "$OLD_HEAD" missing "" --trigger-only)
        [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] || fail "$shape: explicit empty must disable CI pickup (rc=$rc)"
        ;;
      flow-absent)
        rc=$(run_guard "$dir" fresh "$OLD_HEAD" missing "" --trigger-only)
        [ "$rc" = 8 ] && [ "$(trig_count "$dir")" = 0 ] || fail "$shape: absent key must retain the workflow signal (rc=$rc)"
        ;;
    esac
  done
  [ "$FAIL" -ne "$before" ] || pass "#2340: flow/quoted check names and absent/explicit-empty CI pickup meanings are preserved"
}

# MH8: an automatic caller (CI failover on a provider event) is exempt. It
# fires on CodeRabbit's rate limit, not on a push the agent is amending, and a
# refusal would strand the head with no caller left to re-request.
test_guard_exempts_automatic_caller() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-auto")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" missing true --trigger-only)
  [ "$rc" = "0" ] || fail "MH8: expected exit 0 for an automatic caller, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "MH8: expected 1 post, got $(trig_count "$dir")"
  grep -q 'WARNING: head does not look final' "$dir/err.log" || fail "MH8: the exemption must still warn"
  [ "$FAIL" -ne "$before" ] || pass "MH8: MERGEPATH_CODEX_AUTO_TRIGGER exempts the automatic caller (warns, posts)"
}

# MH9: the guard protects a NEW write only. A head Codex already cleared, or
# one that already carries a fresh author trigger, posts nothing and is never
# refused -- the dedup/idempotency contract is untouched.
test_guard_does_not_run_on_no_write_paths() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-dup")
  rc=$(run_guard "$dir" dup_author "$YOUNG_HEAD" missing "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "0" ] || fail "MH9: an existing trigger on a young head must still be the idempotent skip (rc=$rc posts=$(trig_count "$dir"))"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "MH9: trigger_posted must be false on the dedup path"
  grep -q 'moving-head guard' "$dir/err.log" && fail "MH9: the guard must not be evaluated on the dedup path"
  [ "$FAIL" -ne "$before" ] || pass "MH9: dedup and clearance paths never reach the guard"
}

# MH10: the guard also covers the full (polling) mode, which the agent runs in
# Phase 4a -- not only --trigger-only.
test_guard_applies_in_polling_mode() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-poll")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" completed "")
  [ "$rc" = "8" ] || fail "MH10: expected exit 8 in polling mode, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "MH10: expected 0 posts, got $(trig_count "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "MH10: the guard refuses in polling mode too"
}

# MH11 (Codex P2 x2 on #2175): the age signal is anchored on the CURRENT PUSH,
# not only on the commit: the latest repo-lint dispatch for the head on the
# PR's branch. Runs of the same SHA on another branch, and earlier pushes of
# it to this branch, must not make the head look settled.
test_guard_anchors_on_push_dispatch() {
  refresh_head_dates
  local dir rc before=$FAIL
  # (a) Old commit; the SHA ran repo-lint on another branch 3h ago; this
  # branch dispatched it a minute ago. Anchor = the minute-old dispatch.
  dir=$(make_case "guard-dispatch-recent")
  rc=$(CODEX_TEST_CHECK_STARTED="$YOUNG_HEAD" run_guard "$dir" fresh "$OLD_HEAD" dispatched "" --trigger-only)
  [ "$rc" = "8" ] || fail "MH11a: an old commit pushed a minute ago must be refused (exit 8) despite an old run on another branch, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "MH11a: expected 0 posts, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.moving_head.reasons | join(",")')" = "head-age" ] || fail "MH11a: reasons=$(jqf "$dir" '.moving_head.reasons'), expected [head-age]"
  [ "$(jqf "$dir" '.moving_head.head_pushed_at')" = "$YOUNG_HEAD" ] || fail "MH11a: anchor=$(jqf "$dir" '.moving_head.head_pushed_at'), expected the PR-branch dispatch $YOUNG_HEAD (not the other-branch run, not the commit date)"
  grep -q 'source: latest .repo-lint. dispatch for HEAD on the PR branch' "$dir/err.log" || fail "MH11a: the push-dispatch anchor source must be logged"
  # (b) The same SHA was pushed to this branch 2h ago and again a minute ago:
  # the latest dispatch is the current push.
  dir=$(make_case "guard-dispatch-repush")
  rc=$(CODEX_TEST_CHECK_STARTED="$(jq -rn 'now - 7200 | floor | todate')" CODEX_TEST_CHECK_RERUN="$YOUNG_HEAD" \
    run_guard "$dir" fresh "$OLD_HEAD" dispatched "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(jqf "$dir" '.moving_head.head_pushed_at')" = "$YOUNG_HEAD" ] \
    || fail "MH11b: a re-push of the same SHA must be dated by its own dispatch (rc=$rc anchor=$(jqf "$dir" '.moving_head.head_pushed_at'))"
  # (c) A dispatch OLDER than the commit date never makes a head look older:
  # the later of the two governs.
  dir=$(make_case "guard-dispatch-older")
  rc=$(CODEX_TEST_CHECK_STARTED="$(jq -rn 'now - 7200 | floor | todate')" \
    run_guard "$dir" fresh "$YOUNG_HEAD" dispatched "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(jqf "$dir" '.moving_head.head_pushed_at')" = "$YOUNG_HEAD" ] \
    || fail "MH11c: an older dispatch must not override a younger commit anchor (rc=$rc anchor=$(jqf "$dir" '.moving_head.head_pushed_at'))"
  # (d) Old commit, old dispatch on this branch: a settled head posts.
  dir=$(make_case "guard-dispatch-settled")
  rc=$(CODEX_TEST_CHECK_STARTED="$OLD_HEAD" run_guard "$dir" fresh "$OLD_HEAD" dispatched "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH11d: a settled head must post (rc=$rc posts=$(trig_count "$dir"))"
  [ "$FAIL" -ne "$before" ] || pass "MH11: the age signal is anchored on the latest repo-lint dispatch for the head on the PR branch, not only the commit date"
}

# #2198: every workflow event proves pickup, but only PR/push dispatches
# date the age guard. A later manual/scheduled run cannot reset a settled head.
test_guard_workflow_event_anchors() {
  refresh_head_dates
  local dir rc event shape first expected before
  for event in workflow_dispatch schedule '' pull_request push; do
    for shape in mixed event-only; do
      before=$FAIL
      dir=$(make_case "guard-event-${event:-missing}-$shape")
      first=pull_request; [ "$shape" != event-only ] || first=$event
      rc=$(CODEX_TEST_CHECK_EVENT="$first" CODEX_TEST_CHECK_RERUN_EVENT="$event" \
        CODEX_TEST_CHECK_STARTED="$OLD_HEAD" CODEX_TEST_CHECK_RERUN="$YOUNG_HEAD" \
        run_guard "$dir" fresh "$OLD_HEAD" dispatched "" --trigger-only)
      case "$event" in
        pull_request|push)
          [ "$rc" = 8 ] && [ "$(trig_count "$dir")" = 0 ] \
            && [ "$(jqf "$dir" '.moving_head.head_pushed_at')" = "$YOUNG_HEAD" ] \
            && jq -e '.moving_head.reasons == ["head-age"]' "$dir/out.json" >/dev/null \
            || fail "#2198: fresh $event dispatch must retain age refusal ($shape, rc=$rc)" ;;
        *)
          [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] \
            && grep -q "'repo-lint' is completed on HEAD" "$dir/err.log" \
            || fail "#2198: ${event:-missing} event must prove pickup without resetting push age ($shape, rc=$rc)" ;;
      esac
      [ "$FAIL" -ne "$before" ] || pass "#2198: ${event:-missing} workflow age anchor ($shape)"
    done
  done
}

# MH12 (#2175, #2273): the target policy governs from a subdirectory or a
# foreign cwd, even when the script checkout requests by default.
test_policy_resolved_from_script_checkout() {
  local dir rc before=$FAIL
  dir=$(make_case "policy-subdir")
  sed -i.bak 's/^  request_by_default: true.*/  request_by_default: false/' "$dir/state/base-review-policy.yml"
  rc=0
  ( cd "$dir/scripts" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO=fresh ./codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
  [ "$rc" = "5" ] && [ "$(trig_count "$dir")" = "0" ] \
    || fail "MH12: run from scripts/, request_by_default: false must skip with exit 5 (rc=$rc posts=$(trig_count "$dir")); err=$(cat "$dir/err.log")"
  dir=$(make_case "policy-foreign-cwd")
  sed -i.bak 's/^  request_by_default: true.*/  request_by_default: false/' "$dir/state/base-review-policy.yml"
  rc=0
  ( cd "$WORKDIR" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO=fresh "$dir/scripts/codex-review-request.sh" --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
  [ "$rc" = "5" ] && [ "$(trig_count "$dir")" = "0" ] \
    || fail "MH12b: by absolute path from a foreign cwd, request_by_default: false must skip with exit 5 (rc=$rc posts=$(trig_count "$dir"))"
  [ "$FAIL" -ne "$before" ] || pass "MH12: the governing target policy wins over both checkout and caller cwd"
}

# MH13: the CI-pickup signal is the repo-lint WORKFLOW RUN, which survives job
# renames and sharding; a repo without the workflow is not refused forever.
test_guard_workflow_signal_shapes() {
  refresh_head_dates
  local dir rc before=$FAIL
  # (a) #2173 shards lint-fast into lint-fast (1)..(4). An exact check-name
  # match on `lint-fast` would refuse every request; the run signal does not
  # look at job names.
  dir=$(make_case "guard-sharded")
  rc=$(CODEX_TEST_CHECK_RUNS=sharded run_guard "$dir" fresh "$OLD_HEAD" queued "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH13a: sharded lint-fast (1..4) check names must not refuse while a repo-lint run exists (rc=$rc posts=$(trig_count "$dir")); err=$(cat "$dir/err.log")"
  # (b) The run exists (queued) but no job has been created yet: no check-run
  # of any name. Picked up is picked up.
  dir=$(make_case "guard-nojobs")
  rc=$(CODEX_TEST_CHECK_RUNS=missing run_guard "$dir" fresh "$OLD_HEAD" queued "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH13b: a repo-lint run with no jobs yet must satisfy the signal (rc=$rc posts=$(trig_count "$dir"))"
  # (c) The repository has no repo-lint workflow at all: warn and proceed,
  # never exit 8 on this signal.
  dir=$(make_case "guard-noworkflow")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" noworkflow "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH13c: a repo with no repo-lint workflow must not be refused (rc=$rc posts=$(trig_count "$dir")); err=$(cat "$dir/err.log")"
  grep -q "WARNING: moving-head guard: this repository has no 'repo-lint' workflow" "$dir/err.log" || fail "MH13c: the missing workflow must be warned about"
  # ...and the age signal still applies there.
  dir=$(make_case "guard-noworkflow-young")
  rc=$(run_guard "$dir" fresh "$YOUNG_HEAD" noworkflow "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(jqf "$dir" '.moving_head.reasons | join(",")')" = "head-age" ] && [ "$(jqf "$dir" '.moving_head.check_status')" = "no-workflow" ] \
    || fail "MH13d: with no repo-lint workflow, a young head is still refused on age alone (rc=$rc reasons=$(jqf "$dir" '.moving_head.reasons'))"
  # (e) An unreadable workflows list fails open, like every other read here.
  dir=$(make_case "guard-wfunreadable")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" wfunreadable "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH13e: an unreadable workflows list must not refuse (rc=$rc posts=$(trig_count "$dir"))"
  # (f) Matched by canonical path when the display name differs.
  dir=$(make_case "guard-bypath")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" bypath "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH13f: a run of .github/workflows/repo_lint.yml must count whatever its display name (rc=$rc posts=$(trig_count "$dir"))"
  # (g) A repo-lint run of the same SHA on ANOTHER branch only is not this
  # PR's push being picked up.
  dir=$(make_case "guard-otherbranch")
  rc=$(run_guard "$dir" fresh "$OLD_HEAD" otherbranch "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(jqf "$dir" '.moving_head.check_status')" = "missing" ] \
    || fail "MH13g: a repo-lint run on another branch only must read as not picked up (rc=$rc status=$(jqf "$dir" '.moving_head.check_status'))"
  [ "$FAIL" -ne "$before" ] || pass "MH13: repo-lint run signal survives sharded/absent job names, and a repo without the workflow warns instead of refusing"
}

# MH14 (Codex P1 + P2 on #2175): the exact-name OVERRIDE reads every page of
# check runs, and only runs from the PR branch's check suites count.
test_guard_override_paginates_and_scopes() {
  refresh_head_dates
  local dir rc before=$FAIL
  # (a) The matching run is on page 2 behind 100 other runs: found.
  dir=$(make_case "guard-override-paged")
  printf '  request_requires_check: lint-fast\n' >>"$dir/.github/review-policy.yml"
  rc=$(CODEX_TEST_CHECK_RUNS=paged run_guard "$dir" fresh "$OLD_HEAD" missing "" --trigger-only)
  [ "$rc" = "0" ] && [ "$(trig_count "$dir")" = "1" ] || fail "MH14a: a matching check run on page 2 must be found (rc=$rc posts=$(trig_count "$dir")); err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.moving_head // "none"')" = "none" ] && grep -q "'lint-fast' is queued on HEAD" "$dir/err.log" \
    || fail "MH14a: the page-2 run must be READ (queued), not fail open as unreadable"
  # (b) The only exact-name run belongs to another branch's suite: the SHA was
  # checked before, but CI has not scheduled THIS push.
  dir=$(make_case "guard-override-othersuite")
  printf '  request_requires_check: lint-fast\n' >>"$dir/.github/review-policy.yml"
  rc=$(CODEX_TEST_CHECK_RUNS=othersuite run_guard "$dir" fresh "$OLD_HEAD" completed "" --trigger-only)
  [ "$rc" = "8" ] && [ "$(trig_count "$dir")" = "0" ] && [ "$(jqf "$dir" '.moving_head.check_status')" = "missing" ] \
    || fail "MH14b: an exact-name run from another branch's check suite must not satisfy the override (rc=$rc status=$(jqf "$dir" '.moving_head.check_status'))"
  [ "$FAIL" -ne "$before" ] || pass "MH14: the check-run override paginates and counts only the PR branch's check suites"
}

# MH15 (#2253): the guard protects a NEW write only, so it runs after the
# request-cap branch. At a spent cap a young head must still get the real stop
# (exit 7, cap_exhausted), not exit 8 "rerun later". Polling mode's reuse of
# the existing final request is covered in tests/test_codex_review_request_ack.sh.
test_guard_runs_after_the_cap_branch() {
  refresh_head_dates
  local dir rc before=$FAIL
  dir=$(make_case "guard-cap-spent")
  rc=$(run_guard "$dir" cap_at_limit "$YOUNG_HEAD" missing "" --trigger-only)
  [ "$rc" = "7" ] && [ "$(trig_count "$dir")" = "0" ] || fail "MH15: a spent cap on a young head must exit 7 with no post (rc=$rc posts=$(trig_count "$dir")); err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.cap_exhausted.kind')" = "request-ceiling" ] || fail "MH15: expected cap_exhausted.kind request-ceiling, got $(jqf "$dir" '.cap_exhausted.kind')"
  grep -q 'moving-head guard' "$dir/err.log" && fail "MH15: the guard must not run when no new trigger can be written"
  [ "$FAIL" -ne "$before" ] || pass "MH15: a spent request cap on a young head exits 7 (cap_exhausted), not 8"
}


# #2274/#2510: queued checks need creation metadata; missing dispatch timestamps
# cannot establish old-head age or discard an independently young head.
test_guard_dates_queued_checks() {
  refresh_head_dates
  local variant dir rc created started suite head expected before=$FAIL
  for variant in run-created suite-created started unavailable unavailable-young settled invalid-run; do
    dir=$(make_case "queued-dating-$variant")
    printf '  request_requires_check: lint-fast\n' >>"$dir/.github/review-policy.yml"
    created=""; started=""; suite=""; head=$OLD_HEAD; expected=8
    case "$variant" in
      run-created) created=$YOUNG_HEAD; suite=$OLD_HEAD ;;
      suite-created) suite=$YOUNG_HEAD ;;
      started) started=$YOUNG_HEAD; suite=$OLD_HEAD ;;
      unavailable) expected=0 ;;
      unavailable-young) head=$YOUNG_HEAD ;;
      settled) created=$OLD_HEAD; suite=$OLD_HEAD; expected=0 ;;
      invalid-run) created=unreadable; suite=$YOUNG_HEAD ;;
    esac
    rc=$(CODEX_TEST_RUN_CREATED="$created" CODEX_TEST_RUN_STARTED="$started" \
      CODEX_TEST_SUITE_CREATED="$suite" CODEX_TEST_CHECK_RUNS=dated \
      run_guard "$dir" fresh "$head" completed "" --trigger-only)
    [ "$rc" = "$expected" ] || fail "#2274: $variant expected exit $expected, got $rc ($(cat "$dir/err.log"))"
    if [ "$expected" = 8 ]; then
      [ "$(trig_count "$dir")" = 0 ] \
        && [ "$(jqf "$dir" '.moving_head.head_pushed_at')" = "$YOUNG_HEAD" ] \
        && jq -e '.moving_head.reasons == ["head-age"]' "$dir/out.json" >/dev/null \
        || fail "#2274/#2510: $variant must retain young-head refusal before POST"
    else
      [ "$(trig_count "$dir")" = 1 ] || fail "#2274: $variant must retain a settled/unavailable write"
      [ "$variant" != unavailable ] || grep -q 'head-age signal unavailable, not enforced' "$dir/err.log" \
        || fail "#2274: missing dispatch timestamps must report unavailable age"
    fi
  done
  [ "$FAIL" -ne "$before" ] || pass "#2274/#2510: queued check metadata dates pickup; missing metadata preserves young-head refusal"
}

# #2200: fork check suites may not identify their branch. Unknown attribution
# is an unavailable advisory signal, never proof that a check is missing.
test_guard_unknown_suite_branch() {
  refresh_head_dates
  local variant dir rc head scenario check_run before=$FAIL
  for variant in old young unrelated known-other; do
    dir=$(make_case "unknown-suite-$variant")
    printf '  request_requires_check: lint-fast\n' >>"$dir/.github/review-policy.yml"
    head=$OLD_HEAD
    scenario=unknown
    check_run=completed
    [ "$variant" != young ] || head=$YOUNG_HEAD
    [ "$variant" != unrelated ] || scenario=unrelated-unknown
    [ "$variant" != known-other ] || scenario=known
    [ "$variant" != known-other ] || check_run=othersuite
    rc=$(CODEX_TEST_SUITE_BRANCH="$scenario" CODEX_TEST_CHECK_RUNS="$check_run" \
      run_guard "$dir" fresh "$head" completed "" --trigger-only)
    case "$variant" in
      old)
        [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] \
          && grep -q 'unavailable suite branch attribution' "$dir/err.log" \
          || fail "#2200: unknown fork branch must fail open distinctly (rc=$rc)" ;;
      young)
        [ "$rc" = 8 ] && [ "$(trig_count "$dir")" = 0 ] \
          && [ "$(jqf "$dir" '.moving_head.check_status')" = branch-unavailable ] \
          && jq -e '.moving_head.reasons == ["head-age"]' "$dir/out.json" >/dev/null \
          || fail "#2200: unavailable branch must not mask the age guard (rc=$rc)" ;;
      unrelated)
        [ "$rc" = 0 ] && grep -q "'lint-fast' is completed" "$dir/err.log" \
          || fail "#2200: unrelated unknown suite must retain known matching signal" ;;
      known-other)
        [ "$rc" = 8 ] && [ "$(jqf "$dir" '.moving_head.check_status')" = missing ] \
          || fail "#2200: known other-branch suite must still be missing" ;;
    esac
  done
  [ "$FAIL" -ne "$before" ] || pass "#2200: unknown fork attribution is unavailable; known branch and age signals retain behavior"
}

# The request generation the canonical requester observed before its write
# (#1362): the configured author's exact request ids on the fixture timeline.
observed_generation() { # <case-dir> <scenario>
  CODEX_TEST_SCENARIO="$2" CODEX_TEST_STATE_DIR="$1/state" CODEX_TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$1/bin/gh" api --paginate repos/owner/repo/issues/999/comments \
    | jq -sc '[.[][] | select(.user.login == "nathanjohnpayne" and ((.body // "") | test("\\A@codex review\\z"; "i"))) | .id] | unique | sort'
}

# #2158: fresh write-boundary authorization shares the production budgets,
# performs no POST, and cannot authorize a different expected head. #1362: it
# also refuses when the request generation the requester observed has changed
# (a concurrent request landed first) or was not supplied.
test_write_boundary_authorization() {
  local label scenario dir rc expected auto gate reason generation mode before=$FAIL
  for label in fresh cap_at_limit stale_head body-P2 dup_author content-free concurrent no-generation; do
    scenario=$label mode=""
    # concurrent: a request landed after the polling-mode requester read the
    # timeline, so the generation it names is one request short. It predates
    # the head, so the #2664 same-head hold does not refuse it first.
    case "$label" in concurrent) scenario=dup_author_older mode=poll ;; no-generation) scenario=fresh ;; esac
    dir=$(make_case "authorize-$label")
    auto=false
    gate=$(write_gate_stub "$dir" false)
    [ "$scenario" != content-free ] || auto=true
    expected=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [ "$scenario" != stale_head ] || expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    generation=$(observed_generation "$dir" "$scenario")
    case "$label" in
      concurrent) [ "$generation" = '[7001]' ] || fail "authorization: fixture generation helper read $generation"; generation='[]' ;;
      no-generation) generation='' ;;
    esac
    rc=0
    (
      cd "$dir"
      PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
        CODEX_TEST_SCENARIO="$scenario" CODEX_TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        MERGEPATH_PHASE_4A_GATED=true MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD="$expected" \
        MERGEPATH_CODEX_TRIGGER_OBSERVED_GENERATION="$generation" MERGEPATH_CODEX_TRIGGER_CALLER_MODE="$mode" \
        MERGEPATH_CODEX_AUTO_TRIGGER="$auto" MERGEPATH_CODEX_AUTO_TRIGGER_GATE_CMD="$gate" \
        ./scripts/codex-review-request.sh --authorize-trigger-write --allow-moving-head 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    ) || rc=$?
    case "$label" in
      fresh)
        [ "$rc" = 0 ] && jq -e '.authorized == true and .head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .author_identity == "nathanjohnpayne"' "$dir/out.json" >/dev/null \
          || fail "authorization: fresh governing budget should authorize (rc=$rc; $(cat "$dir/err.log"))" ;;
      cap_at_limit) [ "$rc" = 7 ] || fail "authorization: spent request ceiling must refuse (rc=$rc)" ;;
      stale_head) [ "$rc" = 3 ] || fail "authorization: stale expected head must refuse (rc=$rc)" ;;
      body-P2|dup_author|content-free|concurrent|no-generation)
        case "$label" in
          body-P2) reason=already-cleared ;;
          dup_author) reason=existing-trigger ;;
          content-free) reason=content-free-auto-trigger ;;
          concurrent|no-generation) reason=concurrent-request ;;
        esac
        [ "$rc" = 3 ] && jq -e --arg reason "$reason" \
          '.authorized == false and .reason == $reason' "$dir/out.json" >/dev/null \
          || fail "authorization: $label must explicitly refuse (rc=$rc; $(cat "$dir/err.log"))" ;;
    esac
    [ "$(trig_count "$dir")" = 0 ] || fail "authorization must never post ($scenario)"
  done
  [ "$FAIL" -ne "$before" ] || pass "write-boundary authorization enforces budget and head without a POST"
}

# #2582: authorization applies the no-write decisions of the mode the
# canonical requester writes from. Polling mode posts while a trigger is on
# HEAD by design, so only its own refusals apply; an absent or trigger-only
# mode keeps the #489 duplicate refusal, and an unknown mode fails closed.
test_write_boundary_authorization_caller_mode() {
  local label scenario mode auto want timeout dir rc gate before=$FAIL
  while IFS='|' read -r label scenario mode auto want timeout; do
    dir=$(make_case "authorize-mode-$label")
    gate=$(write_gate_stub "$dir" false)
    # The Running case needs a request still inside its own reply deadline;
    # a case may name a short timeout to put it past that deadline.
    sed -i.bak "s/^  review_timeout_seconds: 0\$/  review_timeout_seconds: ${timeout:-999999999}/" "$dir/.github/review-policy.yml"
    cp "$dir/.github/review-policy.yml" "$dir/state/base-review-policy.yml"
    rc=0
    (
      cd "$dir"
      PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
        CODEX_TEST_SCENARIO="$scenario" CODEX_TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        MERGEPATH_PHASE_4A_GATED=true MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        MERGEPATH_CODEX_TRIGGER_CALLER_MODE="$mode" \
        CODEX_TEST_LINT_RUNS=dispatched CODEX_TEST_CHECK_STARTED=2026-06-03T23:59:30Z \
        MERGEPATH_CODEX_TRIGGER_OBSERVED_GENERATION="$(observed_generation "$dir" "$scenario")" \
        MERGEPATH_CODEX_AUTO_TRIGGER="$auto" MERGEPATH_CODEX_AUTO_TRIGGER_GATE_CMD="$gate" \
        ./scripts/codex-review-request.sh --authorize-trigger-write --allow-moving-head 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    ) || rc=$?
    case "$want" in
      authorized)
        [ "$rc" = 0 ] && jq -e '.authorized == true and .head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$dir/out.json" >/dev/null \
          || fail "#2582 authorization ($label): expected authorized (rc=$rc; $(cat "$dir/err.log"))" ;;
      unknown-mode)
        [ "$rc" = 3 ] && ! jq -e '.authorized == true' "$dir/out.json" >/dev/null 2>&1 \
          && grep -q 'unknown caller mode' "$dir/err.log" \
          || fail "#2582 authorization ($label): an unknown caller mode must fail closed (rc=$rc; $(cat "$dir/err.log"))" ;;
      *)
        [ "$rc" = 3 ] && jq -e --arg reason "$want" '.authorized == false and .reason == $reason' "$dir/out.json" >/dev/null \
          || fail "#2582 authorization ($label): expected refusal '$want' (rc=$rc; $(cat "$dir/err.log"))" ;;
    esac
    [ "$(trig_count "$dir")" = 0 ] || fail "#2582 authorization must never post ($label)"
  # #2664: a same-head duplicate with no strong tie (no force-push put HEAD in
  # place before it) and no Running summary is not held, so polling mode
  # authorizes a new counted request; a workflow run is no tie.
  # #2793: a request held only on a Running summary is released once it is
  # past its own wait (it ended unattributed), so polling mode authorizes the
  # deliberate new counted request; within its wait it is still refused.
  done <<'CASES'
poll-dup|dup_author|poll|false|authorized
poll-older-head-dup|dup_author_older|poll|false|authorized
poll-fresh|fresh|poll|false|authorized
poll-content-free|fresh|poll|true|authorized
poll-running|dup_author_running|poll|false|pending-request-running
poll-running-expired|dup_author_running|poll|false|authorized|600
poll-cleared|body-P2|poll|false|already-cleared
explicit-trigger-only-dup|dup_author|trigger-only|false|existing-trigger
absent-dup|dup_author||false|existing-trigger
bogus-mode|dup_author|polling|false|unknown-mode
CASES
  [ "$FAIL" -ne "$before" ] || pass "#2582: authorization applies the caller's request mode; trigger-only stays the default"
}

test_guard_dates_queued_checks
test_guard_unknown_suite_branch
test_write_boundary_authorization
test_write_boundary_authorization_caller_mode

test_fresh_posts_once_no_poll
test_pr_open_reaction_still_posts
test_dup_author_skips
test_uppercase_author_command_skips
test_author_containment_posts
test_stale_author_command_posts
test_reviewer_trigger_does_not_count
test_request_attempt_cap
test_request_checkpoint
test_nondefault_request_attempt_cap
test_candidate_cannot_raise_governing_request_attempt_cap
test_governing_cap_read_failure_refuses_new_write
test_invalid_present_governing_cap_refuses_new_write
test_invalid_present_governing_codex_block_refuses_new_write
test_missing_governing_codex_block_defaults_request_cap
test_idempotent_skip_requires_governing_freshness
test_governing_request_freshness
test_governing_freshness_revalidation
test_governing_freshness_validation_preserves_no_spend_caps
test_gated_cap_leaves_routing_to_caller
test_cap_preserves_provider_block_as_diagnostic_only
test_blocking_budget_boundary
test_blocking_budget_counting_rule
test_blocking_budget_wins_simultaneous_exhaustion
test_blocking_budget_governing_value
test_blocking_budget_fails_closed
test_blocking_budget_not_read_without_a_write
test_gate_skips_content_free_head
test_gate_triggers_on_real_content_change
test_gate_triggers_without_prior_review
test_gate_fails_open_on_api_error
test_gate_triggers_when_only_signal_is_a_review_object
test_gate_triggers_when_verdict_is_superseded
test_gate_requires_boolean_carried
test_wiring_auto_caller_honors_skip
test_wiring_manual_caller_ignores_gate
test_wiring_missing_gate_fails_open
test_feedback_accounting_blocks_trigger
test_workflow_declares_auto_trigger_flag
test_guard_refuses_young_head
test_guard_allow_flag_posts_with_warning
test_guard_refuses_unscheduled_check
test_guard_reports_both_reasons
test_guard_accepts_queued_check
test_guard_unreadable_check_runs_fails_open
test_guard_policy_knobs_disable_signals
test_guard_check_signal_yaml_forms
test_guard_exempts_automatic_caller
test_guard_does_not_run_on_no_write_paths
test_guard_applies_in_polling_mode
test_guard_anchors_on_push_dispatch
test_guard_workflow_event_anchors
test_policy_resolved_from_script_checkout
test_guard_workflow_signal_shapes
test_guard_override_paginates_and_scopes
test_guard_runs_after_the_cap_branch

test_trigger_only_preserves_known_provider_block() {
  local reason dir rc before
  for reason in usage_limit not_connected; do
    before=$FAIL
    dir=$(make_case "known-block-$reason")
    rc=$(run_trigger_only "$dir" "known_$reason")
    [ "$rc" = 0 ] && [ "$(jqf "$dir" '.blocked_reason')" = "$reason" ] \
      && [ "$(trig_count "$dir")" = 1 ] \
      || fail "trigger-only lost known $reason diagnostic; err=$(tail -3 "$dir/err.log")"
    [ "$FAIL" -ne "$before" ] || pass "trigger-only preserves known $reason without changing request authority or budgets"
  done
}
test_trigger_only_preserves_known_provider_block

test_trigger_only_ignores_stale_provider_block() {
  local reason dir rc before
  for reason in usage_limit not_connected; do
    before=$FAIL
    dir=$(make_case "stale-block-$reason")
    rc=$(run_trigger_only "$dir" "stale_$reason")
    [ "$rc" = 0 ] && [ "$(jqf "$dir" '.blocked_reason')" = null ] \
      && [ "$(trig_count "$dir")" = 1 ] \
      || fail "trigger-only retained stale $reason diagnostic; err=$(tail -3 "$dir/err.log")"
    [ "$FAIL" -ne "$before" ] || pass "trigger-only ignores $reason before the current freshness threshold"
  done
}
test_trigger_only_ignores_stale_provider_block

test_trigger_only_future_head_preserves_recent_blocks() {
  local reason age dir rc before expected
  for reason in usage_limit not_connected; do
    for age in current stale; do
      before=$FAIL
      dir=$(make_case "future-head-$age-$reason")
      sed -i.bak 's/reaction_freshness_window_seconds:.*/reaction_freshness_window_seconds: 1800/' \
        "$dir/.github/review-policy.yml" "$dir/state/base-review-policy.yml"
      rc=$(run_guard "$dir" "${age}_$reason" 2099-01-01T00:00:00Z completed "" \
        --trigger-only --allow-moving-head)
      expected=$reason
      [ "$age" != stale ] || expected=null
      [ "$rc" = 0 ] && [ "$(jqf "$dir" '.blocked_reason')" = "$expected" ] \
        && [ "$(trig_count "$dir")" = 1 ] \
        || fail "future head mishandled $age $reason; err=$(tail -3 "$dir/err.log")"
      [ "$FAIL" -ne "$before" ] || pass "future head preserves freshness distinction for $age $reason"
    done
  done
}
# #2317: metadata that the post-write diagnostic cannot parse must refuse
# before a trigger mutation. Standard UTC, including future dates, stays valid.
test_trigger_timestamp_validation() {
  local variant dir timestamp rc expected before=$FAIL
  for variant in empty invalid fractional offset invalid-date utc future; do
    dir=$(make_case "timestamp-$variant")
    expected=3
    case "$variant" in
      empty) timestamp="" ;;
      invalid) timestamp=not-a-timestamp ;;
      fractional) timestamp=2026-06-04T00:00:00.123Z ;;
      offset) timestamp=2026-06-04T00:00:00+00:00 ;;
      invalid-date) timestamp=2026-02-30T00:00:00Z ;;
      utc) timestamp=2026-06-04T00:00:00Z; expected=0 ;;
      future) timestamp=2099-06-04T00:00:00Z; expected=0 ;;
    esac
    rc=0
    (
      cd "$dir"
      PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
        CODEX_TEST_SCENARIO=fresh CODEX_TEST_HEAD_DATE="$timestamp" \
        ./scripts/codex-review-request.sh --trigger-only --allow-moving-head 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    ) || rc=$?
    [ "$rc" = "$expected" ] || fail "#2317: $variant expected exit $expected, got $rc"
    if [ "$expected" = 0 ]; then
      [ "$(trig_count "$dir")" = 1 ] \
        && jq -e --arg t "$timestamp" '.trigger_posted == true and .head_committer_date == $t' "$dir/out.json" >/dev/null \
        || fail "#2317: $variant must preserve the post-write JSON contract"
    else
      [ "$(trig_count "$dir")" = 0 ] && [ ! -s "$dir/out.json" ] \
        && grep -q 'unsupported commit timestamp' "$dir/err.log" \
        || fail "#2317: $variant must refuse before POST with a metadata diagnostic (posts=$(trig_count "$dir"))"
    fi
  done
  [ "$FAIL" -ne "$before" ] || pass "#2317: unsupported commit metadata refuses before writes; canonical and future UTC keep JSON"
}

test_trigger_timestamp_validation

test_trigger_only_future_head_preserves_recent_blocks

# #2534: the CodeRabbit rate-limit failover does not spend the request
# ceiling. --failover marks the trigger it posts, and the ceiling skips a
# marked trigger.
test_failover_marker() {
  local dir rc before
  before=$FAIL
  # A real head, so the PR head set (#2553) is readable.
  local fo_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  dir=$(make_case failover-ceiling)
  rc=$(CODEX_TEST_HEAD=$fo_head run_trigger_only "$dir" cap_failover)
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] \
    || fail "#2534: ten requests with one marked failover must leave a slot (rc=$rc posts=$(trig_count "$dir")); err=$(tail -3 "$dir/err.log")"
  grep -q 'request attempts 9/10' "$dir/err.log" \
    || fail "#2534: the marked failover was counted: $(grep 'request attempts' "$dir/err.log")"
  # #2553: a marker naming a foreign head, or an unreadable head set, exempts nothing.
  dir=$(make_case failover-ceiling-foreign)
  rc=$(CODEX_TEST_HEAD=$fo_head run_trigger_only "$dir" cap_failover_foreign)
  [ "$rc" = 7 ] && [ "$(trig_count "$dir")" = 0 ] \
    && grep -q 'request-attempt cap reached.*10/10' "$dir/err.log" \
    || fail "#2553: a marker naming a foreign head must not exempt its trigger (rc=$rc posts=$(trig_count "$dir"))"
  # #2591: a head a force-push replaced counts when GraphQL names it, and a
  # failed GraphQL read leaves only that head out.
  dir=$(make_case failover-ceiling-forced)
  rc=$(CODEX_TEST_HEAD=$fo_head CODEX_TEST_FORCE_PUSH=9999999999999999999999999999999999999999 run_trigger_only "$dir" cap_failover_forced)
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && grep -q 'request attempts 9/10' "$dir/err.log" \
    || fail "#2591: a marker on a force-pushed-away head must exempt its trigger when GraphQL names it (rc=$rc posts=$(trig_count "$dir"))"
  dir=$(make_case failover-ceiling-forced-unreadable)
  rc=$(CODEX_TEST_HEAD=$fo_head CODEX_TEST_FORCE_PUSH=fail run_trigger_only "$dir" cap_failover_forced)
  [ "$rc" = 7 ] && [ "$(trig_count "$dir")" = 0 ] \
    || fail "#2591: without the GraphQL heads that marker must not exempt its trigger (rc=$rc posts=$(trig_count "$dir"))"
  dir=$(make_case failover-ceiling-forced-ok-without-graphql)
  rc=$(CODEX_TEST_HEAD=$fo_head CODEX_TEST_FORCE_PUSH=fail run_trigger_only "$dir" cap_failover)
  [ "$rc" = 0 ] && grep -q 'request attempts 9/10' "$dir/err.log" \
    || fail "#2591: a failed GraphQL read must not drop the REST heads (rc=$rc)"
  dir=$(make_case failover-ceiling-unreadable)
  rc=$(CODEX_TEST_HEAD=$fo_head CODEX_TEST_COMMITS_FAIL=1 run_trigger_only "$dir" cap_failover)
  [ "$rc" = 7 ] && [ "$(trig_count "$dir")" = 0 ] && grep -q "head set is unreadable" "$dir/err.log" \
    || fail "#2553: an unreadable head set must exempt nothing (rc=$rc posts=$(trig_count "$dir"))"

  # A failover stub that records both writes, so the readback sees them.
  write_failover_stub() {
    cat >"$1/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
live="$state_dir/live-comments.json"
[ -f "$live" ] || printf '[]\n' >"$live"
count=0
[ -f "$state_dir/post-count" ] && count=$(cat "$state_dir/post-count")
count=$((count + 1)); printf '%s\n' "$count" >"$state_dir/post-count"
id=$((1000 + count)); now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "${8:-}" in
  --body) [ "${9:-}" = "@codex review" ] || exit 98; body=$9
          t=0; [ -f "$state_dir/trigger-count" ] && t=$(cat "$state_dir/trigger-count")
          printf '%s\n' "$((t + 1))" >"$state_dir/trigger-count" ;;
  --body-file) [ "${CODEX_TEST_MARKER_WRITE:-ok}" = ok ] || exit 97
               [ "${MERGEPATH_CODEX_FAILOVER_MARKER_WRITE:-}" = 1 ] || exit 96
               body=$(cat "$9"); printf '%s\n' "$body" >"$state_dir/marker-body" ;;
  *) exit 95 ;;
esac
jq -c --argjson id "$id" --arg b "$body" --arg t "$now" '. + [{id: $id, user: {login: "nathanjohnpayne"}, body: $b, created_at: $t, updated_at: $t}]' "$live" >"$live.tmp"
mv "$live.tmp" "$live"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$id"
EOF
    chmod +x "$1/scripts/gh-as-author.sh"
  }
  run_failover() { # <dir> [marker-write]
    local rc=0
    ( cd "$1" && PATH="$1/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$1/state" CODEX_TEST_SCENARIO=live \
        CODEX_TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa CODEX_TEST_MARKER_WRITE="${2:-ok}" MERGEPATH_PHASE_4A_GATED=true \
        ./scripts/codex-review-request.sh --trigger-only --failover --allow-moving-head 999 owner/repo \
        >"$1/out.json" 2>"$1/err.log" ) || rc=$?
    printf '%s\n' "$rc"
  }

  dir=$(make_case failover-marker)
  write_failover_stub "$dir"
  rc=$(run_failover "$dir")
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(jqf "$dir" .failover_marker)" = recorded ] \
    && [ "$(cat "$dir/state/marker-body")" = '<!-- mergepath-codex-failover:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=1001 -->' ] \
    || fail "#2534: --failover must post one trigger and record its marker (rc=$rc marker=$(jqf "$dir" .failover_marker 2>/dev/null)); err=$(tail -3 "$dir/err.log")"
  # A second failover on the same head reuses the trigger and marks nothing.
  rc=$(run_failover "$dir")
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(jqf "$dir" .failover_marker)" = not-posted ] \
    && [ "$(jq length "$dir/state/live-comments.json")" = 2 ] \
    || fail "#2534: a reused trigger must not gain a second marker (rc=$rc marker=$(jqf "$dir" .failover_marker 2>/dev/null))"

  # A failed marker write is reported, not fatal: the trigger stands and counts.
  dir=$(make_case failover-marker-fail)
  write_failover_stub "$dir"
  rc=$(run_failover "$dir" fail)
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(jqf "$dir" .failover_marker)" = failed ] \
    && jq -e '.trigger_posted == true and .trigger_requested == true' "$dir/out.json" >/dev/null \
    || fail "#2534: a failed marker write must leave the posted trigger reported (rc=$rc marker=$(jqf "$dir" .failover_marker 2>/dev/null))"

  # Plain --trigger-only never writes a marker.
  dir=$(make_case failover-plain)
  write_failover_stub "$dir"
  rc=0
  ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" CODEX_TEST_SCENARIO=live \
      CODEX_TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa MERGEPATH_PHASE_4A_GATED=true \
      ./scripts/codex-review-request.sh --trigger-only --allow-moving-head 999 owner/repo >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
  [ "$rc" = 0 ] && [ "$(trig_count "$dir")" = 1 ] && [ "$(jqf "$dir" .failover_marker)" = null ] && [ ! -f "$dir/state/marker-body" ] \
    || fail "#2534: --trigger-only without --failover wrote a marker (rc=$rc)"
  [ "$FAIL" -ne "$before" ] || pass "#2534: --failover marks only the trigger it posts, a marked failover spends no ceiling slot, and a failed marker write is not fatal"
}
test_failover_marker

echo "----"
echo "test_codex_review_request_trigger_only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
