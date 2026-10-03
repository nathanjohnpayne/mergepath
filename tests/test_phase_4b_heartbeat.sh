#!/usr/bin/env bash
# #1589 lifecycle regressions: real orchestrator, hermetic adapter/GitHub
# boundaries, no lib.sh mutation. Expected ~40s; each invocation bounded 30s,
# adapter capped at 3s (timeout fixture 1s). History fixtures emit on request
# for #1590 without implementing its aggregator/provider.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-heartbeat-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
# shellcheck source=../scripts/phase-4b/heartbeat.sh
. "$ROOT/scripts/phase-4b/heartbeat.sh"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/adapters"
HEAD_FIXTURE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export HB_HEAD="$HEAD_FIXTURE" HB_WORK="$WORK"
export P4B_ADAPTER_DIR="$WORK/adapters" P4B_RESOLVE_BASE_POLICY="$BIN/resolve"
export P4B_CODEX_REVIEW_CHECK="$BIN/codex-check" P4B_CODEX_LEDGER="$BIN/ledger"
export P4B_HANDOFF="$BIN/handoff" P4B_GH_AS_REVIEWER="$BIN/reviewer"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$BIN/feedback"
export P4B_ACCT_PRIOR_RECORDS_JSONL="$WORK/empty.jsonl"
: > "$P4B_ACCT_PRIOR_RECORDS_JSONL"
export PATH="$BIN:$PATH"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "read:$*" >> "$HB_CASE/events"
[ "$1" = api ] || exit 99
shift
if [ "$1" = --paginate ]; then
  case "$2" in
    */comments)
      [ "$HB_MODE" != auth-unreadable ] || exit 1
      if [ -e "$HB_CASE/new-request" ]; then id=2; else id=1; fi
      if [ "$HB_MODE" = ceiling-stop ] || [ "$HB_MODE" = hold ]; then printf '[]\n'; else
        jq -nc --argjson id "$id" '[range(1;$id+1)|{id:.,body:"@codex review",user:{login:"nathanjohnpayne"},created_at:"2026-08-01T00:00:00Z"}]'
      fi ;;
    */timeline) printf '[]\n' ;;
    *) exit 99 ;;
  esac
  exit 0
fi
endpoint=$1; shift
case "$endpoint" in
  */pulls/*)
    for a in "$@"; do case "$a" in
      *'.body'*) printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok\n'; exit 0 ;;
    esac; done
    json=$(jq -nc --arg h "$HB_HEAD" '{head:{sha:$h},base:{ref:"main",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",repo:{default_branch:"main"}}}') ;;
  */commits/*) json='{"commit":{"committer":{"date":"2026-08-01T00:00:00Z"}}}' ;;
  *) exit 99 ;;
esac
if [ "${1:-}" = --jq ]; then printf '%s' "$json" | jq -r "$2"; else printf '%s\n' "$json"; fi
EOF
cat > "$BIN/resolve" <<'EOF'
#!/usr/bin/env bash
set -eu
tmp=$(mktemp "${TMPDIR:-/tmp}/hb-policy.XXXXXX")
cp "$MERGEPATH_REVIEW_POLICY_PATH" "$tmp"
printf '%s\n' "$tmp"
EOF
cat > "$BIN/codex-check" <<'EOF'
#!/usr/bin/env bash
set -eu
# Observe that the barrier stage was published before external-boundary reads.
jq -r '.stage' "$P4B_HEARTBEAT_DIR"/p4b-*.json >> "$HB_CASE/observed" 2>/dev/null || true
cp "$P4B_HEARTBEAT_DIR"/p4b-*.json "$HB_CASE/barrier.json" 2>/dev/null || true
case "$HB_MODE" in hold|ceiling-stop) exit 1 ;; *) exit 0 ;; esac
EOF
cat > "$BIN/ledger" <<'EOF'
#!/usr/bin/env bash
set -eu
head=''; fp=''
while [ $# -gt 0 ]; do case "$1" in --expect-head) head=$2; shift 2 ;; --expect-policy) fp=$2; shift 2 ;; *) shift ;; esac; done
jq -nc --arg h "$head" --arg fp "$fp" '{head_sha:$h,author:"nathanjohnpayne",max_blocking_reviews:10,policy_fingerprint:$fp,
 requests:[{id:1,created_at:"2026-08-01T00:00:00Z",outcome:"attributed",responses:["w0"],counted:true}],rebuttals:[],
 responses:[range(10)|{rid:("w"+tostring),window:1,class:"blocking",unsolicited:false,conflicting:false,first_at:"2026-08-01T00:10:00Z",blocking_paths:["x.sh"],blocking_unlocated:false}]}'
EOF
cat > "$BIN/feedback" <<'EOF'
#!/usr/bin/env bash
set -eu
n=$(cat "$HB_CASE/feedback-count" 2>/dev/null || printf 0); n=$((n+1)); printf '%s' "$n" > "$HB_CASE/feedback-count"
printf 'feedback:%s\n' "$n" >> "$HB_CASE/events"
if [ "$HB_MODE" = feedback ] || { [ "$HB_MODE" = late-feedback ] && [ "$n" -ge 3 ]; }; then printf '{"missing":[]}\n'; exit 1; fi
# The owner contract deliberately permits the final-accounting request race:
# the writer posts with the original generation; merge-gate fixtures reject it.
if [ "$HB_MODE" = final-accounting-request ] && [ "$n" = 3 ]; then : > "$HB_CASE/new-request"; fi
printf '{"feedback_policy":{},"findings":[],"missing":[]}\n'
EOF
cat > "$BIN/reviewer" <<'EOF'
#!/usr/bin/env bash
set -eu
jq -r '.stage' "$P4B_HEARTBEAT_DIR"/p4b-*.json >> "$HB_CASE/observed" 2>/dev/null || true
printf 'post\n' >> "$HB_CASE/events"
while [ $# -gt 0 ]; do
 if [ "$1" = --input ]; then cp "$2" "$HB_CASE/posted.json"; break; fi
 shift
done
jq -nc --arg h "$HB_HEAD" '{id:42,commit_id:$h}'
EOF
cat > "$BIN/handoff" <<'EOF'
#!/usr/bin/env bash
printf 'handoff\n' >> "$HB_CASE/events"
printf 'manual handoff\n'
EOF
cat > "$WORK/adapters/review-via-codex.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
jq -r '.stage' "$P4B_HEARTBEAT_DIR"/p4b-*.json >> "$HB_CASE/observed" 2>/dev/null || true
printf 'adapter\n' >> "$HB_CASE/events"
case "$HB_MODE" in
 timeout|killed) sleep 20 ;;
 moved-request) : > "$HB_CASE/new-request" ;;
esac
if [ "$HB_MODE" = changes ]; then
 printf '{"verdict":"CHANGES_REQUESTED","summary":"repair this","findings":[{"severity":"P1","path":"x.sh","line":1,"body":"wrong behavior"}],"usage":{"token_count":123,"input_tokens":null,"output_tokens":null,"cache_creation_input_tokens":null,"cache_read_input_tokens":null,"reasoning_tokens":null,"total_cost_usd":null,"source":"fixture"},"cli_version":null}\n'
else
 printf '{"verdict":"APPROVED","summary":"looks good","findings":[],"usage":{"token_count":123,"input_tokens":null,"output_tokens":null,"cache_creation_input_tokens":null,"cache_read_input_tokens":null,"reasoning_tokens":null,"total_cost_usd":null,"source":"fixture"},"cli_version":null}\n'
fi
EOF
chmod +x "$BIN"/* "$WORK/adapters"/*
printf 'diff --git a/x.sh b/x.sh\n+true\n' > "$WORK/diff"
cat > "$WORK/policy" <<'EOF'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
  adapter_timeout_seconds: 3
coderabbit:
  enabled: false
  max_wait_seconds: 100
codex:
  enabled: true
  max_review_rounds: 10
EOF
run_case() {
  local mode="$1" expected="$2" stages="$3" storage="${4:-good}" rc=0 record
  export HB_MODE="$mode" HB_CASE="$WORK/$mode-$storage"
  mkdir -p "$HB_CASE"; : > "$HB_CASE/events"
  export P4B_HEARTBEAT_DIR="$HB_CASE/heartbeats" P4B_ACCT_STATE_DIR="$HB_CASE/accounting"
  export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy"
  if [ "$mode" = ceiling-stop ]; then
    sed 's/max_review_rounds: 10/max_review_rounds: 0/' "$WORK/policy" > "$HB_CASE/policy"
    export MERGEPATH_REVIEW_POLICY_PATH="$HB_CASE/policy"
  fi
  if [ "$storage" = blocked ]; then
    printf 'not a directory\n' > "$P4B_HEARTBEAT_DIR"
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 env P4B_ADAPTER_TIMEOUT_SECONDS="$([ "$mode" = timeout ] && printf 1 || printf 3)" \
      bash "$ROOT/scripts/phase-4b-review.sh" 1589 --repo fixture/repo --head "$HB_HEAD" --diff-file "$WORK/diff" > "$HB_CASE/out" 2> "$HB_CASE/err" || rc=$?
  else
    perl -e 'alarm shift @ARGV; exec @ARGV' 30 env P4B_ADAPTER_TIMEOUT_SECONDS="$([ "$mode" = timeout ] && printf 1 || printf 3)" \
      bash "$ROOT/scripts/phase-4b-review.sh" 1589 --repo fixture/repo --head "$HB_HEAD" --diff-file "$WORK/diff" > "$HB_CASE/out" 2> "$HB_CASE/err" || rc=$?
  fi
  if [ "$rc" = "$expected" ]; then pass "$mode/$storage exit $expected"; else fail "$mode/$storage exit $rc expected $expected: $(tail -3 "$HB_CASE/err")"; fi
  if [ "$storage" = blocked ]; then
    [ -f "$P4B_HEARTBEAT_DIR" ] && pass "$mode storage failure ignored" || fail "$mode changed blocked storage"
    # Compare the complete boundary trace, including every mocked API read,
    # POST, handoff and adapter dispatch. Storage failure cannot add a write
    # or reorder the final authority/feedback reads either.
    cmp -s "$WORK/$mode-good/events" "$HB_CASE/events" \
      && pass "$mode blocked storage preserves boundary operations and order" || fail "$mode blocked storage changed boundary trace"
    return 0
  fi
  record=$(printf '%s\n' "$P4B_HEARTBEAT_DIR"/p4b-*.json)
  if jq -e --arg stages "$stages" --argjson rc "$expected" --arg h "$HB_HEAD" '
    .schema == "p4b-heartbeat/v1" and .stage == "done" and .exit_code == $rc
    and ([.stages[].stage]|join(",")) == $stages and .head == $h
    and .run_id != null and .repo == "fixture/repo" and .pr == "1589"
    and .adapter_timeout_seconds == (if $rc == 4 then 1 else 3 end)
    and (.stages|all(.stage_at_epoch != null and (.stage_at|length)>0))
    and .process_started_at != null and (.checkout|length)>0' "$record" >/dev/null 2>&1; then
    pass "$mode records reached stages and terminal identity"
  else fail "$mode heartbeat: $(cat "$record" 2>/dev/null)"; fi
  case "$mode" in
    approve|changes|final-accounting-request)
      jq -e '.summary_emitted and .review_posted and .token_count == 123 and .adapter_elapsed_seconds != null and .adapter_started_at_epoch != null' "$record" >/dev/null \
        && pass "$mode final summary and measured adapter timing" || fail "$mode final summary/timing"
      grep -qx posting "$HB_CASE/observed" && grep -qx adapter "$HB_CASE/observed" \
        && pass "$mode published live adapter/posting stages" || fail "$mode live stage publication"
      ;;
    hold|feedback|ceiling-stop|auth-unreadable)
      jq -e '.adapter_started_at_epoch == null and .adapter_elapsed_seconds == null and .adapter_exit_code == null and .adapter_verdict == null and .verdict == null and .review_posted == false and .review_acknowledgment == null' "$record" >/dev/null \
        && ! grep -qx adapter "$HB_CASE/events" && ! grep -qx post "$HB_CASE/events" \
        && pass "$mode no fabricated adapter/post evidence" || fail "$mode invented adapter/post"
      ;;
    *)
      jq -e '.verdict == null and .review_posted == false and .adapter_elapsed_seconds != null' "$record" >/dev/null \
        && ! grep -qx post "$HB_CASE/events" && pass "$mode adapter result never claims posted approval" || fail "$mode posted evidence"
      ;;
  esac
}
# Every requested exit is exercised with normal and root-robust unwritable
# storage. The latter is a regular file at the directory path (chmod is not a
# faithful failure injection when CI runs as root).
for storage in good blocked; do
  run_case approve 0 barrier,adapter,posting,done "$storage"
  run_case changes 1 barrier,adapter,posting,done "$storage"
  run_case timeout 4 barrier,adapter,done "$storage"
  run_case hold 6 barrier,done "$storage"
  run_case feedback 7 barrier,done "$storage"
  run_case ceiling-stop 8 barrier,done "$storage"
  run_case auth-unreadable 10 barrier,done "$storage"
done
run_case moved-request 10 barrier,adapter,posting,done
run_case late-feedback 7 barrier,adapter,posting,done
run_case final-accounting-request 0 barrier,adapter,posting,done
# Last authority/feedback read is still the final pre-POST accounting call.
if [ "$(sed -n '/^post$/{x;p;};h' "$HB_CASE/events")" = feedback:3 ] \
   && jq -er '.body' "$HB_CASE/posted.json" | grep -qxF '<!-- mergepath-p4b-request-generation: [1] -->'; then
  pass 'late request remains outside original approval generation; feedback is last pre-POST read'
else fail 'request-generation race/read order changed'; fi

# An inherited value is present before REVIEW_POSTED is initialized near the
# POST. Early refusals still publish startup and terminal boolean evidence.
REVIEW_POSTED=not-json run_case hold 6 barrier,done inherited-not-json
REVIEW_POSTED=true REVIEW_ACKNOWLEDGMENT=accounted ADAPTER_RC=0 VERDICT=APPROVED \
  P4B_ACCT_LOOP_STARTED_EPOCH=123 P4B_ACCT_LOOP_ELAPSED_SECONDS=123 P4B_HB_EXIT_CODE=0 \
  run_case hold 6 barrier,done inherited-results
jq -e '.stage == "barrier" and .exit_code == null and .review_posted == false
  and .review_acknowledgment == null and .adapter_exit_code == null
  and .adapter_verdict == null and .adapter_started_at_epoch == null
  and .adapter_elapsed_seconds == null' "$HB_CASE/barrier.json" >/dev/null \
  && pass 'barrier ignores inherited result evidence' || fail 'barrier inherited results'
cmp -s "$WORK/hold-good/events" "$HB_CASE/events" \
  && pass 'inherited results preserve refusal boundary trace' || fail 'inherited results changed boundary trace'
for inherited in '' not-json null 0 '[]' false true; do
  (
    export P4B_HEARTBEAT_DIR="$WORK/inherited-$inherited"
    P4B_ACCT_RUN_ID=p4b-fixture-inherited
    # Read by the sourced heartbeat producer.
    # shellcheck disable=SC2034
    REVIEW_POSTED="$inherited"
    p4b_heartbeat_start
    expected=false; [ "$inherited" != true ] || expected=true
    jq -e --argjson expected "$expected" '.stage == "barrier" and .review_posted == $expected' "$P4B_HB_FILE" >/dev/null || exit 1
    p4b_heartbeat_finish 6
    jq -e --argjson expected "$expected" '.stage == "done" and .exit_code == 6 and .review_posted == $expected' "$P4B_HB_FILE" >/dev/null
  ) && pass "inherited REVIEW_POSTED '$inherited' publishes booleans" || fail "inherited REVIEW_POSTED '$inherited'"
done

# SIGKILL bypasses EXIT: a non-done observation is retained, and the local
# process-instance reader identifies the vanished owner. Fake adapter is itself
# capped at 3s, so no real model/long orphan survives this case.
export HB_MODE=killed HB_CASE="$WORK/killed" P4B_HEARTBEAT_DIR="$WORK/killed/heartbeats" P4B_ACCT_STATE_DIR="$WORK/killed/accounting"
mkdir -p "$HB_CASE"; : > "$HB_CASE/events"
export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy"
bash "$ROOT/scripts/phase-4b-review.sh" 1589 --repo fixture/repo --head "$HB_HEAD" --diff-file "$WORK/diff" > "$HB_CASE/out" 2> "$HB_CASE/err" &
child=$!
for (( i=0; i<100; i++ )); do grep -qx adapter "$HB_CASE/events" 2>/dev/null && break; sleep 0.05; done
record=$(printf '%s\n' "$P4B_HEARTBEAT_DIR"/p4b-*.json)
if grep -qx adapter "$HB_CASE/events"; then
  kill -9 "$child"; wait "$child" 2>/dev/null || true
  [ "$(p4b_heartbeat_status "$record")" = crashed ] && [ "$(jq -r .stage "$record")" = adapter ] \
    && pass 'killed orchestrator retains adapter stage and is detected as crashed' || fail 'killed process detection'
else kill -9 "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fail 'killed fixture never reached adapter'; fi

# Storage/encoding failure tests drive the helper under errexit and preserve
# the last complete observation. A malformed preexisting file is replaced by
# this process's in-memory stages; malformed input never becomes authority.
export P4B_HEARTBEAT_DIR="$WORK/helper"
# Read by the sourced heartbeat helper.
# shellcheck disable=SC2034
P4B_ACCT_RUN_ID=p4b-fixture-storage
p4b_heartbeat_start
printf 'broken json' > "$P4B_HB_FILE"
p4b_heartbeat_stage adapter
jq -e '.stage == "adapter" and [.stages[].stage] == ["barrier","adapter"]' "$P4B_HB_FILE" >/dev/null \
  && pass 'malformed old storage is replaced atomically from owned state' || fail 'malformed storage recovery'
# Read by the sourced heartbeat helper.
# shellcheck disable=SC2034
P4B_HB_STAGES='malformed'; p4b_heartbeat_stage posting
[ "$(jq -r .stage "$P4B_HB_FILE")" = adapter ] && pass 'encoding failure preserves prior complete record and returns zero' || fail 'encoding failure'
# PID reuse / unknown start evidence: never interpret an unrelated process as
# the in-flight owner. The actual current process supplies the live control.
jq --arg ps "$(LC_ALL=C ps -p "$$" -o lstart=)" --argjson pid "$$" '.pid=$pid|.process_started_at=$ps' "$P4B_HB_FILE" > "$WORK/live.json"
[ "$(p4b_heartbeat_status "$WORK/live.json")" = running ] && pass 'live process instance matches' || fail 'live process identity'
jq '.process_started_at="different process start"' "$WORK/live.json" > "$WORK/reused.json"
[ "$(p4b_heartbeat_status "$WORK/reused.json")" = crashed ] && pass 'reused PID is not the original process instance' || fail 'PID reuse'
jq '.process_started_at=null' "$WORK/live.json" > "$WORK/unknown.json"
[ "$(p4b_heartbeat_status "$WORK/unknown.json")" = unknown ] && pass 'missing process identity remains unknown' || fail 'unknown identity'
# Retention prunes old completed evidence while retaining live/unknown records.
cp "$WORK/approve-good/heartbeats/"*.json "$WORK/helper/p4b-old.json"
cp "$WORK/live.json" "$WORK/helper/p4b-live.json"
cp "$WORK/unknown.json" "$WORK/helper/p4b-unknown.json"
touch -t 200001010000 "$WORK/helper/"*.json
# Invalid retention cannot unexpectedly erase old evidence.
# shellcheck disable=SC2034
P4B_HEARTBEAT_RETENTION_DAYS=0; p4b_heartbeat_prune
[ -e "$WORK/helper/p4b-old.json" ] && pass 'invalid retention disables pruning' || fail 'invalid retention pruned evidence'
# Read by the sourced heartbeat helper.
# shellcheck disable=SC2034
P4B_HEARTBEAT_RETENTION_DAYS=7; p4b_heartbeat_prune
[ ! -e "$WORK/helper/p4b-old.json" ] && [ -e "$WORK/helper/p4b-live.json" ] && [ -e "$WORK/helper/p4b-unknown.json" ] \
  && pass 'retention removes old done but preserves live/unknown evidence' || fail 'retention'

printf 'Heartbeat: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
