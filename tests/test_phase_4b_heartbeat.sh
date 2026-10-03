#!/usr/bin/env bash
# #1589 lifecycle regressions: real orchestrator, hermetic adapter/GitHub
# boundaries, no lib.sh mutation. Expected ~80s; each invocation bounded 30s,
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
if ! HB_REAL_NODE="$(command -v node)"; then
  printf 'ERROR: node is required for the Phase 4b heartbeat test suite\n' >&2
  exit 1
fi
export HB_REAL_NODE
# Invoke the actual suite with only its pre-lookup utilities available. The
# missing dependency exits before reaching this fixture, so it cannot recurse.
NODELESS_BIN="$WORK/no-node-bin"
mkdir -p "$NODELESS_BIN"
for nodeless_cmd in bash dirname mktemp mkdir rm; do
  ln -s "$(command -v "$nodeless_cmd")" "$NODELESS_BIN/$nodeless_cmd"
done
rc=0
PATH="$NODELESS_BIN" bash "$ROOT/tests/test_phase_4b_heartbeat.sh" > "$WORK/no-node-out" 2> "$WORK/no-node-err" || rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/no-node-out" ] \
  && grep -qx 'ERROR: node is required for the Phase 4b heartbeat test suite' "$WORK/no-node-err" \
  && pass 'missing Node exits explicitly at the real suite boundary' || fail 'missing Node diagnostic/exit'
export PATH="$BIN:$PATH"
cat > "$BIN/node" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "${1:-}" >> "$HB_CASE/node-calls"
[ "${HB_ENTROPY:-good}" != unavailable ] || exit 90
# Intercept the crypto draw only; version and shared PR-body parser calls use
# the real runtime. Failures therefore exercise the enabled caller rather than
# replacing its existing hard dependency check with a permissive fake.
if [ "${1:-}" = -e ] && [[ "${2:-}" == *'randomBytes(16)'* ]]; then
  printf 'entropy\n' >> "$HB_CASE/entropy-calls"
  case "${HB_ENTROPY:-good}" in
    error) printf '0123456789abcdef0123456789abcdef'; printf 'injected entropy error\n' >&2; exit 1 ;;
    malformed) printf 'ABCDEF0123456789ABCDEF0123456789AB'; exit 0 ;;
    timeout) exec sleep 20 ;;
  esac
fi
exec "$HB_REAL_NODE" "$@"
EOF
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
jq -r '.run_id' "$P4B_HEARTBEAT_DIR"/p4b-*.json >> "$HB_CASE/observed-ids" 2>/dev/null || true
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
jq -r '.run_id' "$P4B_HEARTBEAT_DIR"/p4b-*.json >> "$HB_CASE/observed-ids" 2>/dev/null || true
cp "$P4B_ACCT_STATE_DIR/phase-4b-pending/fixture-repo-pr1589.json.runid" "$HB_CASE/staged-runid" 2>/dev/null || true
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
jq -r '.run_id' "$P4B_HEARTBEAT_DIR"/p4b-*.json >> "$HB_CASE/observed-ids" 2>/dev/null || true
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
  local mode="$1" expected="$2" stages="$3" storage="${4:-good}" rc=0 record id log
  export HB_MODE="$mode" HB_CASE="$WORK/$mode-$storage"
  mkdir -p "$HB_CASE"; : > "$HB_CASE/events"
  export HB_ENTROPY=good
  case "$storage" in entropy-*) export HB_ENTROPY="${storage#entropy-}" ;; esac
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
  [ "$(cat "$HB_CASE/entropy-calls" 2>/dev/null)" = entropy ] \
    && pass "$mode/$storage draws entropy exactly once" || fail "$mode/$storage entropy count"
  if [ "$storage" = blocked ]; then
    [ -f "$P4B_HEARTBEAT_DIR" ] && pass "$mode storage failure ignored" || fail "$mode changed blocked storage"
    # Compare the complete boundary trace, including every mocked API read,
    # POST, handoff and adapter dispatch. Storage failure cannot add a write
    # or reorder the final authority/feedback reads either.
    cmp -s "$WORK/$mode-good/events" "$HB_CASE/events" \
      && pass "$mode blocked storage preserves boundary operations and order" || fail "$mode blocked storage changed boundary trace"
    return 0
  fi
  case "$storage" in entropy-*)
    [ ! -e "$P4B_HEARTBEAT_DIR" ] && pass "$mode/$storage publishes no unavailable identity" || fail "$mode/$storage advertised heartbeat identity"
    cmp -s "$WORK/$mode-good/events" "$HB_CASE/events" \
      && cmp -s "$WORK/$mode-good/out" "$HB_CASE/out" \
      && pass "$mode/$storage preserves boundary operations, order and summary" || fail "$mode/$storage changed review flow"
    log="$P4B_ACCT_STATE_DIR/phase-4b-loops/fixture-repo-pr1589.jsonl"
    [ "$mode" != approve ] || log="$log.archive"
    jq -e --arg posted "$([ "$mode" = approve ] && printf posted || printf not-posted)" '
      .loop.run_id == null and .loop.verdict == "APPROVED" and .loop.posted == $posted
      and .loop.tokens.total == 123 and .loop.elapsed_seconds != null' "$log" >/dev/null \
      && pass "$mode/$storage preserves loop accounting with null identity" || fail "$mode/$storage missing/corrupt loop accounting"
    [ ! -e "$P4B_ACCT_STATE_DIR/phase-4b-pending/fixture-repo-pr1589.json" ] \
      && [ ! -e "$P4B_ACCT_STATE_DIR/phase-4b-pending/fixture-repo-pr1589.json.runid" ] \
      && pass "$mode/$storage clears this invocation's pending staging" || fail "$mode/$storage stranded pending staging"
    if [ "$mode" = approve ]; then
      [[ "$(cat "$HB_CASE/staged-runid")" =~ ^local-[0-9]+-[0-9]+-[0-9]+$ ]] \
        && pass "$storage preserves the prior staging tuple without genuine identity" || fail "$storage weakened staging ownership"
      jq -e '.loops[0].run_id == null and .totals.adapter_invocations == 1 and .totals.tokens_total == 123' \
        "$P4B_ACCT_STATE_DIR/phase-4b-ledger.jsonl" >/dev/null \
        && [ ! -s "$P4B_ACCT_STATE_DIR/phase-4b-loops/fixture-repo-pr1589.jsonl" ] \
        && pass "$storage fallback staging commits approval and rotates its loop" || fail "$storage fallback staging ownership failed"
      jq -cS '.totals | del(.elapsed_seconds_total)' "$WORK/approve-good/accounting/phase-4b-ledger.jsonl" > "$HB_CASE/expected-totals"
      jq -cS '.totals | del(.elapsed_seconds_total)' "$P4B_ACCT_STATE_DIR/phase-4b-ledger.jsonl" > "$HB_CASE/actual-totals"
      cmp -s "$HB_CASE/expected-totals" "$HB_CASE/actual-totals" \
        && pass "$storage preserves approval totals" || fail "$storage changed approval totals"
    else
      jq -e '.loop.fail_closed.happened == true' "$log" >/dev/null \
        && ! grep -qx post "$HB_CASE/events" \
        && pass "$storage refusal corrects provisional accounting without posting" || fail "$storage refusal accounting/post"
    fi
    return 0 ;;
  esac
  record=$(printf '%s\n' "$P4B_HEARTBEAT_DIR"/p4b-*.json)
  if jq -e --arg stages "$stages" --argjson rc "$expected" --arg h "$HB_HEAD" '
    .schema == "p4b-heartbeat/v1" and .stage == "done" and .exit_code == $rc
    and ([.stages[].stage]|join(",")) == $stages and .head == $h
    and (.run_id|test("^p4b-[0-9a-f]{32}$")) and .repo == "fixture/repo" and .pr == "1589"
    and .adapter_timeout_seconds == (if $rc == 4 then 1 else 3 end)
    and (.stages|all(.stage_at_epoch != null and (.stage_at|length)>0))
    and .process_started_at != null and (.checkout|length)>0' "$record" >/dev/null 2>&1; then
    pass "$mode records reached stages and terminal identity"
  else fail "$mode heartbeat: $(cat "$record" 2>/dev/null)"; fi
  id="$(jq -r .run_id "$record")"
  [ "$(sort -u "$HB_CASE/observed-ids")" = "$id" ] \
    && pass "$mode keeps one identity across live and terminal stages" || fail "$mode changed stage identity"
  case "$mode" in
    approve|changes|final-accounting-request)
      jq -e '.summary_emitted and .review_posted and .token_count == 123 and .adapter_elapsed_seconds != null and .adapter_started_at_epoch != null' "$record" >/dev/null \
        && pass "$mode final summary and measured adapter timing" || fail "$mode final summary/timing"
      grep -qx posting "$HB_CASE/observed" && grep -qx adapter "$HB_CASE/observed" \
        && pass "$mode published live adapter/posting stages" || fail "$mode live stage publication"
      log="$P4B_ACCT_STATE_DIR/phase-4b-loops/fixture-repo-pr1589.jsonl"
      [ "$mode" = changes ] || log="$log.archive"
      jq -e --arg id "$id" '.loop.run_id == $id' "$log" >/dev/null \
        && pass "$mode shares the generated identity with its loop" || fail "$mode loop identity mismatch"
      if [ "$mode" != changes ]; then
        jq -e --arg id "$id" '.loops[0].run_id == $id' "$P4B_ACCT_STATE_DIR/phase-4b-ledger.jsonl" >/dev/null \
          && pass "$mode shares the generated identity with its approval" || fail "$mode approval identity mismatch"
      fi
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

# Entropy failures preserve both the successful POST/accounting transaction
# and a writer-boundary refusal with provisional-loop correction. A valid
# inherited ID must not turn failed generation into genuine persisted identity.
for entropy in error malformed timeout; do
  P4B_ACCT_RUN_ID=p4b-00000000000000000000000000000000 run_case approve 0 '' "entropy-$entropy"
  P4B_ACCT_RUN_ID=p4b-00000000000000000000000000000000 run_case late-feedback 7 '' "entropy-$entropy"
done
P4B_ACCT_RUN_ID=p4b-00000000000000000000000000000000 run_case approve 0 barrier,adapter,posting,done inherited-id
[ "$(jq -r .run_id "$P4B_HEARTBEAT_DIR"/p4b-*.json)" != p4b-00000000000000000000000000000000 ] \
  && pass 'enabled invocation replaces inherited genuine identity' || fail 'inherited identity reused'

# Disabled/non-local gates must not reach either Node's dependency probe or
# entropy source. The shim would fail every Node call on these paths.
for gate in disabled non-local; do
  export HB_MODE=approve HB_CASE="$WORK/$gate" HB_ENTROPY=unavailable
  mkdir -p "$HB_CASE"; : > "$HB_CASE/events"
  export P4B_HEARTBEAT_DIR="$HB_CASE/heartbeats" P4B_ACCT_STATE_DIR="$HB_CASE/accounting"
  if [ "$gate" = disabled ]; then sed 's/enabled: true/enabled: false/' "$WORK/policy" > "$HB_CASE/policy"
  else sed 's/mode: local/mode: manual/' "$WORK/policy" > "$HB_CASE/policy"; fi
  export MERGEPATH_REVIEW_POLICY_PATH="$HB_CASE/policy"
  rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 bash "$ROOT/scripts/phase-4b-review.sh" 1589 --repo fixture/repo \
      --head "$HB_HEAD" --diff-file "$WORK/diff" > "$HB_CASE/out" 2> "$HB_CASE/err" || rc=$?
  else
    perl -e 'alarm shift @ARGV; exec @ARGV' 30 bash "$ROOT/scripts/phase-4b-review.sh" 1589 --repo fixture/repo \
      --head "$HB_HEAD" --diff-file "$WORK/diff" > "$HB_CASE/out" 2> "$HB_CASE/err" || rc=$?
  fi
  [ "$rc" = 5 ] && [ ! -e "$HB_CASE/node-calls" ] && [ ! -e "$P4B_HEARTBEAT_DIR" ] \
    && [ ! -e "$P4B_ACCT_STATE_DIR" ] && [ ! -s "$HB_CASE/events" ] \
    && pass "$gate stays dependency-free without entropy or review operations" || fail "$gate ran enabled dependencies"
done
export HB_ENTROPY=good

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
# A representable but absent process remains a genuine crash control.
jq '.pid=2147483647' "$WORK/live.json" > "$WORK/dead.json"
[ "$(p4b_heartbeat_status "$WORK/dead.json")" = crashed ] \
  && pass 'absent bounded PID remains crashed' || fail 'absent PID identity'
# Retention prunes old completed evidence while retaining live/unknown records.
cp "$WORK/approve-good/heartbeats/"*.json "$WORK/helper/p4b-old.json"
cp "$WORK/live.json" "$WORK/helper/p4b-live.json"
cp "$WORK/reused.json" "$WORK/helper/p4b-reused.json"
cp "$WORK/dead.json" "$WORK/helper/p4b-dead.json"
cp "$WORK/unknown.json" "$WORK/helper/p4b-unknown.json"
# Corrupted/incompatible process identity must not become a confident crash,
# which would allow retention to erase the evidence. Exercise every non-string
# JSON type and empty text against the same genuinely live process control.
IDENTITY_CASES=('number:123' 'true:true' 'false:false' 'array:[]' 'object:{}' 'null:null' 'empty:""' 'missing:missing')
for identity_case in "${IDENTITY_CASES[@]}"; do
  identity_label=${identity_case%%:*}; identity_json=${identity_case#*:}
  identity_record="$WORK/helper/p4b-invalid-$identity_label.json"
  if [ "$identity_label" = missing ]; then
    jq 'del(.process_started_at)' "$WORK/live.json" > "$identity_record"
  else
    jq --argjson value "$identity_json" '.process_started_at=$value' "$WORK/live.json" > "$identity_record"
  fi
  [ "$(p4b_heartbeat_status "$identity_record")" = unknown ] \
    && pass "$identity_label process identity remains unknown" || fail "$identity_label process identity"
  jq '.stage="done"' "$identity_record" > "$WORK/helper/p4b-terminal-start-$identity_label.json"
  terminal_status=unknown
  [ "$identity_label" != null ] || terminal_status='done'
  [ "$(p4b_heartbeat_status "$WORK/helper/p4b-terminal-start-$identity_label.json")" = "$terminal_status" ] \
    && pass "done/$identity_label process identity is $terminal_status" || fail "done/$identity_label process identity"
done
# A completed observation can legitimately lack ps start evidence. Its valid
# nullable identity is classified without consulting the process probe.
(
  ps() { : > "$WORK/terminal-ps-probe"; return 2; }
  [ "$(p4b_heartbeat_status "$WORK/helper/p4b-terminal-start-null.json")" = 'done' ] \
    && [ ! -e "$WORK/terminal-ps-probe" ]
) && pass 'done with explicit null start needs no ps probe' || fail 'done/null process probe'
# Numeric shape alone does not prove ps can parse a PID. Keep invalid and
# oversized values unknown rather than treating ps argument failure as death.
PID_CASES=('oversize:2147483648' 'huge:1e20' 'scientific:1e50' 'bool:true'
  'fraction:1.5' 'zero:0' 'negative:-1' 'string:"123"' 'null:null'
  'array:[]' 'object:{}' 'missing:missing')
for pid_case in "${PID_CASES[@]}"; do
  pid_label=${pid_case%%:*}; pid_json=${pid_case#*:}
  pid_record="$WORK/helper/p4b-invalid-pid-$pid_label.json"
  if [ "$pid_label" = missing ]; then
    jq 'del(.pid)' "$WORK/live.json" > "$pid_record"
  else
    jq --argjson value "$pid_json" '.pid=$value' "$WORK/live.json" > "$pid_record"
  fi
  [ "$(p4b_heartbeat_status "$pid_record")" = unknown ] \
    && pass "$pid_label PID remains unknown" || fail "$pid_label PID identity"
  jq '.stage="done"' "$pid_record" > "$WORK/helper/p4b-terminal-pid-$pid_label.json"
  [ "$(p4b_heartbeat_status "$WORK/helper/p4b-terminal-pid-$pid_label.json")" = unknown ] \
    && pass "done/$pid_label PID remains unknown" || fail "done/$pid_label PID identity"
done
# The reader consumes one observation object; an empty/compound/non-object
# file or invalid schema/stage cannot establish terminal process evidence.
READER_CASES=(empty multiple array null scalar schema stage)
for reader_case in "${READER_CASES[@]}"; do
  reader_record="$WORK/helper/p4b-invalid-reader-$reader_case.json"
  case "$reader_case" in
    empty) : > "$reader_record" ;;
    multiple) cat "$WORK/live.json" "$WORK/live.json" > "$reader_record" ;;
    array) printf '[]\n' > "$reader_record" ;;
    null) printf 'null\n' > "$reader_record" ;;
    scalar) printf '42\n' > "$reader_record" ;;
    schema) jq '.schema={}' "$WORK/live.json" > "$reader_record" ;;
    stage) jq '.stage=[]' "$WORK/live.json" > "$reader_record" ;;
  esac
  [ "$(p4b_heartbeat_status "$reader_record")" = unknown ] \
    && pass "$reader_case observation remains unknown" || fail "$reader_case reader identity"
done
touch -t 200001010000 "$WORK/helper/"*.json
# Invalid retention cannot unexpectedly erase old evidence.
# shellcheck disable=SC2034
P4B_HEARTBEAT_RETENTION_DAYS=0; p4b_heartbeat_prune
[ -e "$WORK/helper/p4b-old.json" ] && pass 'invalid retention disables pruning' || fail 'invalid retention pruned evidence'
# Read by the sourced heartbeat helper.
# shellcheck disable=SC2034
P4B_HEARTBEAT_RETENTION_DAYS=7; p4b_heartbeat_prune
[ ! -e "$WORK/helper/p4b-old.json" ] && [ ! -e "$WORK/helper/p4b-reused.json" ] && [ ! -e "$WORK/helper/p4b-dead.json" ] \
  && [ -e "$WORK/helper/p4b-live.json" ] && [ -e "$WORK/helper/p4b-unknown.json" ] \
  && pass 'retention removes old done/crashed but preserves live/unknown evidence' || fail 'retention'
for identity_case in "${IDENTITY_CASES[@]}"; do
  identity_label=${identity_case%%:*}
  [ -e "$WORK/helper/p4b-invalid-$identity_label.json" ] \
    && pass "retention preserves $identity_label process identity" || fail "retention removed $identity_label process identity"
  if [ "$identity_label" = null ]; then
    [ ! -e "$WORK/helper/p4b-terminal-start-null.json" ] \
      && pass 'retention prunes valid done with explicit null start' || fail 'done/null retention'
  else
    [ -e "$WORK/helper/p4b-terminal-start-$identity_label.json" ] \
      && pass "retention preserves done/$identity_label process identity" || fail "retention removed done/$identity_label identity"
  fi
done
for pid_case in "${PID_CASES[@]}"; do
  pid_label=${pid_case%%:*}
  [ -e "$WORK/helper/p4b-invalid-pid-$pid_label.json" ] \
    && pass "retention preserves $pid_label PID" || fail "retention removed $pid_label PID"
  [ -e "$WORK/helper/p4b-terminal-pid-$pid_label.json" ] \
    && pass "retention preserves done/$pid_label PID" || fail "retention removed done/$pid_label PID"
done
for reader_case in "${READER_CASES[@]}"; do
  [ -e "$WORK/helper/p4b-invalid-reader-$reader_case.json" ] \
    && pass "retention preserves $reader_case observation" || fail "retention removed $reader_case observation"
done

printf 'Heartbeat: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
