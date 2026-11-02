#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"

if ! command -v ruby >/dev/null 2>&1; then
  echo "ERROR: required-check publisher dedup tests require ruby" >&2
  exit 1
fi
if ! ruby -e 'require "yaml"' >/dev/null 2>&1; then
  echo "ERROR: required-check publisher dedup tests require Ruby YAML support" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ruby - "$WORKFLOW" "$TMP/open.sh" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV[0])
steps = workflow.fetch("jobs").fetch("open").fetch("steps")
matches = steps.select { |step| step["name"] == "Open pending entries on the event head" }
abort("could not extract the publisher open step") unless matches.length == 1 && matches[0]["run"].is_a?(String)
File.write(ARGV[1], matches[0]["run"])
RUBY

chmod +x "$TMP/open.sh"

cat >"$TMP/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_CALL_LOG"

case "$*" in
  *"actions/runs/"*)
    reads=$(grep -c 'actions/runs/' "$GH_CALL_LOG" || true)
    if [ "$GH_FIXTURE_MODE" = "parent-completed" ] || { [ "$GH_FIXTURE_MODE" = "complete-before-burst" ] && [ "$reads" -ge 2 ]; }; then
      printf '%s\n' completed
    else
      printf '%s\n' in_progress
    fi
    ;;
  *"/commits/"*"/check-runs"*" -f filter=latest "*)
    # Bait for a reintroduced delayed-open fence (#2171): when
    # GH_FIXTURE_NEWER_PASS is set, every filter=latest read reports a fresh
    # completed publisher verdict on every context. The open path must ignore
    # it and still open all three holds.
    [ -z "${GH_FIXTURE_NEWER_PASS:-}" ] || printf '%s\n' "$GH_FIXTURE_NEWER_PASS"
    ;;
  *"/commits/"*"/check-runs"*)
    case " $* " in
      *" -f filter=all "*) ;;
      *)
        echo "check-runs probe must request filter=all" >&2
        exit 2
        ;;
    esac
    summary="Publisher phase 1: evaluation queued for $HEAD_SHA. <!-- required-check-publisher:pending:${PARENT_RUN_ID}:${PARENT_RUN_ATTEMPT} -->"
    case "$GH_FIXTURE_MODE" in
      exact)
        printf 'Merge clearance gate\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t101\n' "$summary"
        printf 'Codex P1 unresolved threads\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t102\n' "$summary"
        printf 'CodeRabbit unresolved blocking findings\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t103\n' "$summary"
        ;;
      partial)
        printf 'Merge clearance gate\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t101\n' "$summary"
        ;;
      foreign)
        printf 'Merge clearance gate\tin_progress\tforeign-summary\tgithub-actions\t2026-09-20T12:00:01Z\t101\n'
        printf 'Codex P1 unresolved threads\tin_progress\tforeign-summary\tgithub-actions\t2026-09-20T12:00:01Z\t102\n'
        printf 'CodeRabbit unresolved blocking findings\tin_progress\tforeign-summary\tgithub-actions\t2026-09-20T12:00:01Z\t103\n'
        ;;
      foreign-app)
        printf 'Merge clearance gate\tin_progress\t%s\tother-check-producer\t2026-09-20T12:00:01Z\t101\n' "$summary"
        printf 'Codex P1 unresolved threads\tin_progress\t%s\tother-check-producer\t2026-09-20T12:00:01Z\t102\n' "$summary"
        printf 'CodeRabbit unresolved blocking findings\tin_progress\t%s\tother-check-producer\t2026-09-20T12:00:01Z\t103\n' "$summary"
        ;;
      exact-but-mcg)
        # #2920: the requested delivery left Merge clearance standing on an
        # unchanged-input fingerprint and held only the other two.
        printf 'Codex P1 unresolved threads\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t102\n' "$summary"
        printf 'CodeRabbit unresolved blocking findings\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t103\n' "$summary"
        ;;
      completed-markers)
        printf 'Merge clearance gate\tcompleted\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t101\n' "$summary"
        printf 'Codex P1 unresolved threads\tcompleted\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t102\n' "$summary"
        printf 'CodeRabbit unresolved blocking findings\tcompleted\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t103\n' "$summary"
        ;;
      newer-completed)
        printf 'Merge clearance gate\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t101\n' "$summary"
        printf 'Codex P1 unresolved threads\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t102\n' "$summary"
        printf 'CodeRabbit unresolved blocking findings\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t103\n' "$summary"
        printf 'Merge clearance gate\tcompleted\tother\tgithub-actions\t2026-09-20T12:00:02Z\t201\n'
        printf 'Codex P1 unresolved threads\tcompleted\tother\tgithub-actions\t2026-09-20T12:00:02Z\t202\n'
        printf 'CodeRabbit unresolved blocking findings\tcompleted\tother\tgithub-actions\t2026-09-20T12:00:02Z\t203\n'
        ;;
      tied-completed)
        printf 'Merge clearance gate\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t101\n' "$summary"
        printf 'Codex P1 unresolved threads\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t102\n' "$summary"
        printf 'CodeRabbit unresolved blocking findings\tin_progress\t%s\tgithub-actions\t2026-09-20T12:00:01Z\t103\n' "$summary"
        printf 'Merge clearance gate\tcompleted\tother\tgithub-actions\t2026-09-20T12:00:01Z\t201\n'
        printf 'Codex P1 unresolved threads\tcompleted\tother\tgithub-actions\t2026-09-20T12:00:01Z\t202\n'
        printf 'CodeRabbit unresolved blocking findings\tcompleted\tother\tgithub-actions\t2026-09-20T12:00:01Z\t203\n'
        ;;
      unreadable)
        exit 1
        ;;
      empty|race|parent-completed|complete-before-burst|write-fails)
        ;;
      *)
        echo "unknown fixture mode: $GH_FIXTURE_MODE" >&2
        exit 2
        ;;
    esac
    ;;
  *"repos/"*"/pulls"*)
    # head<TAB>number, the open step's own --jq row shape (#2920).
    printf '%s\t42\n' "$HEAD_SHA"
    ;;
  *"check-runs"*)
    if [ "$GH_FIXTURE_MODE" = write-fails ] && [[ "$*" == *'name=Merge clearance gate'* ]]; then
      exit 1
    fi
    printf '{}\n'
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$TMP/gh"
printf '#!/bin/sh\nexit 0\n' >"$TMP/sleep"
chmod +x "$TMP/sleep"

pass=0
fail=0

run_case() {
  local name="$1" action="$2" attempt="$3" mode="$4" want_calls="$5" want_posts="$6" want_probes="$7"
  local dir="$TMP/$name" calls posts probes summary rc=0 want_rc="${8:-0}"
  mkdir -p "$dir"
  : >"$dir/calls"
  summary="Publisher phase 1: evaluation queued for abc123. <!-- required-check-publisher:pending:4242:$attempt -->"

  PATH="$TMP:$PATH" \
      GH_CALL_LOG="$dir/calls" GH_FIXTURE_MODE="$mode" \
      REPO="example/repo" HEAD_SHA="abc123" PARENT_RUN_ID="4242" \
      PARENT_RUN_ATTEMPT="$attempt" EVENT_ACTION="$action" \
      MCG_CONTEXT="Merge clearance gate" \
      CODEX_P1_CONTEXT="Codex P1 unresolved threads" \
      CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings" \
      GITHUB_RUN_ID="9999" \
      bash "$TMP/open.sh" >"$dir/out" 2>&1 || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: $name: open step exited $rc instead of $want_rc"
    sed -n '1,120p' "$dir/out"
    fail=$((fail + 1))
    return
  fi

  calls=$(wc -l <"$dir/calls" | tr -d ' ')
  posts=$(grep -c -- '-X POST .*check-runs' "$dir/calls" || true)
  probes=$(grep -c -- '/commits/abc123/check-runs' "$dir/calls" || true)

  if [ "$calls" -ne "$want_calls" ] || [ "$posts" -ne "$want_posts" ] \
      || [ "$probes" -ne "$want_probes" ]; then
    echo "FAIL: $name: calls=$calls posts=$posts probes=$probes; expected $want_calls/$want_posts/$want_probes"
    sed -n '1,120p' "$dir/calls"
    fail=$((fail + 1))
    return
  fi

  if [ "$posts" -gt 0 ]; then
    if grep -q -- 'external_id' "$dir/calls"; then
      echo "FAIL: $name: pending POST must not set external_id"
      sed -n '1,120p' "$dir/calls"
      fail=$((fail + 1))
      return
    fi
    if [ "$(grep -Fc -- "-f output[summary]=$summary" "$dir/calls" || true)" -ne "$posts" ]; then
      echo "FAIL: $name: every pending POST must carry the exact summary marker"
      sed -n '1,120p' "$dir/calls"
      fail=$((fail + 1))
      return
    fi
  fi

  echo "PASS: $name ($calls HTTP fixture calls, $posts writes)"
  pass=$((pass + 1))
}

# The ordinary duplicate path retains the parent-status guard, then replaces
# five later requests (PR list, second status read and three writes)
# with one check-runs read: 6 -> 2, four requests saved, zero jobs saved.
run_case first-attempt-already-covered in_progress 1 exact 2 0 1

# Any incomplete or untrustworthy evidence falls through to the full open
# path. The extra probe makes these seven one-page HTTP fixtures instead of
# the six-call ordinary path; preserving pending cover is the deliberate failure direction.
run_case partial-requested-publication in_progress 1 partial 7 3 1
run_case delayed-or-failed-requested in_progress 1 empty 7 3 1
run_case both-events-race-before-publication in_progress 1 race 7 3 1
run_case unreadable-dedup-probe in_progress 1 unreadable 7 3 1
run_case foreign-same-name-runs in_progress 1 foreign 7 3 1
run_case foreign-app-exact-marker in_progress 1 foreign-app 7 3 1
run_case completed-same-marker-runs in_progress 1 completed-markers 7 3 1
run_case newer-completed-after-exact-pending in_progress 1 newer-completed 7 3 1
run_case ambiguous-same-time-completed in_progress 1 tied-completed 7 3 1

# Reruns receive no requested event. A new attempt therefore bypasses the
# first-attempt probe and always opens, even if old attempt markers exist.
run_case rerun-new-attempt in_progress 2 exact 6 3 0

# Requested remains the prompt first-attempt path, and a runner that starts
# after the parent completed retains the old one-read/no-write behavior.
run_case requested-event requested 1 empty 6 3 0
run_case delayed-runner-after-completion in_progress 1 parent-completed 1 0 0
# Completion between the early optimization and the burst still owns the
# head: the second status fence prevents late pending entries.
run_case completion-during-enumeration in_progress 1 complete-before-burst 4 0 1
# Exhausted retries on one context still open its siblings and fail red.
run_case partial-pending-write-failure requested 1 write-fails 8 5 0 1

# #2171 (Codex round 5): no delayed-open fence. A newer completed publisher
# verdict on the head does NOT let the open job skip its holds, because a
# verdict's started_at is its POST time, not when it read PR state. With the
# bait armed, both deliveries must still open all three holds exactly as
# without it; a reintroduced timestamp fence would read the bait and skip.
GH_FIXTURE_NEWER_PASS=301; export GH_FIXTURE_NEWER_PASS
run_case newer-verdict-does-not-skip-requested requested 1 empty 6 3 0
run_case newer-verdict-does-not-skip-in-progress in_progress 1 empty 7 3 1
unset GH_FIXTURE_NEWER_PASS

# #2920: a review or review-comment parent leaves a context standing when its
# review inputs match the newest published green verdict. The decision itself
# (scripts/workflow/gate-input-fingerprint.sh) has its own suite,
# tests/test_gate_input_fingerprint.sh; here a stub library answers it, so
# these cases pin the open step's wiring: who asks, what a skip removes, and
# that every other outcome opens all three holds.
FPDIR="$TMP/fp-work"
mkdir -p "$FPDIR/.gate-input-fingerprint/scripts/workflow" "$TMP/fpbin"
cat >"$FPDIR/.gate-input-fingerprint/scripts/workflow/gate-input-fingerprint.sh" <<'SH'
gif_supported() { [ "$1" = "Merge clearance gate" ]; }
gif_budget() { printf 'budget %s\n' "${1:-none}" >>"$FP_LOG.budget"; }
gif_decide() {
  printf '%s\n' "$*" >>"$FP_LOG"
  GIF_HEX=""; GIF_REASON="stub $FP_DECISION"
  case "$FP_DECISION" in
    match) GIF_HEX=1111111111111111111111111111111111111111111111111111111111111111; return 0 ;;
    nomatch) GIF_HEX=2222222222222222222222222222222222222222222222222222222222222222; return 1 ;;
    *) return 1 ;;
  esac
}
SH
# A stub budget reader: FP_BUDGET_OK=0 is a budget short of the comparison.
cat >"$FPDIR/.gate-input-fingerprint/scripts/workflow/installation-budget.sh" <<'SH'
ib_read() { :; }
ib_affordable() { [ "${FP_BUDGET_OK:-1}" = 1 ]; }
SH
printf '#!/bin/sh\necho bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$TMP/fpbin/git"
chmod +x "$TMP/fpbin/git"

fp_case() {  # name action attempt mode parent decision want_calls want_posts want_probes want_mcg_posts want_decisions
  local name="$1" dir="$TMP/$1" rc=0 calls posts probes mcg decisions
  mkdir -p "$dir"; : >"$dir/calls"; : >"$dir/fp"
  (
    cd "$FPDIR"
    [ "${FP_NO_LIB:-}" != 1 ] || mv .gate-input-fingerprint .gate-input-fingerprint.off
    PATH="$TMP/fpbin:$TMP:$PATH" \
      GH_CALL_LOG="$dir/calls" GH_FIXTURE_MODE="$4" FP_LOG="$dir/fp" FP_DECISION="$6" FP_BUDGET_OK="${FP_BUDGET_OK:-1}" \
      REPO="example/repo" HEAD_SHA="abc123" PARENT_RUN_ID="4242" \
      PARENT_RUN_ATTEMPT="$3" EVENT_ACTION="$2" PARENT_EVENT="$5" \
      MCG_CONTEXT="Merge clearance gate" \
      CODEX_P1_CONTEXT="Codex P1 unresolved threads" \
      CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings" \
      GITHUB_RUN_ID="9999" \
      bash "$TMP/open.sh" >"$dir/out" 2>&1
    rc=$?
    [ "${FP_NO_LIB:-}" != 1 ] || mv .gate-input-fingerprint.off .gate-input-fingerprint
    exit "$rc"
  ) || rc=$?
  calls=$(wc -l <"$dir/calls" | tr -d ' ')
  posts=$(grep -c -- '-X POST .*check-runs' "$dir/calls" || true)
  probes=$(grep -c -- '/commits/abc123/check-runs' "$dir/calls" || true)
  mcg=$(grep -- '-X POST .*check-runs' "$dir/calls" | grep -c -- 'name=Merge clearance gate' || true)
  decisions=$(wc -l <"$dir/fp" | tr -d ' ')
  if [ "$rc" -ne 0 ] || [ "$calls" -ne "$7" ] || [ "$posts" -ne "$8" ] || [ "$probes" -ne "$9" ] \
      || [ "$mcg" -ne "${10}" ] || [ "$decisions" -ne "${11}" ]; then
    echo "FAIL: $name: rc=$rc calls=$calls posts=$posts probes=$probes mcg_posts=$mcg decisions=$decisions; expected 0/$7/$8/$9/${10}/${11}"
    sed -n '1,60p' "$dir/out" "$dir/calls"
    fail=$((fail + 1))
    return
  fi
  if grep -q 'number' "$dir/fp" || ! { [ "$decisions" -eq 0 ] || grep -q '^example/repo 42 abc123 Merge clearance gate bbbbbbbb' "$dir/fp"; }; then
    echo "FAIL: $name: the decision must name the repo, the head's PR, the head, the context and the trusted revision"
    cat "$dir/fp"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $name ($calls HTTP fixture calls, $posts writes, $decisions fingerprint decision(s))"
  pass=$((pass + 1))
}

# A review parent whose Merge clearance inputs match: two holds, none for it.
fp_case fp-review-match requested 1 empty pull_request_review match 5 2 0 0 1
fp_case fp-review-comment-match requested 1 empty pull_request_review_comment match 5 2 0 0 1
# A push (or any non-review parent) never asks, even when a match is armed.
fp_case fp-push-never-skips requested 1 empty pull_request match 6 3 0 1 0
fp_case fp-label-never-skips requested 1 empty pull_request_target match 6 3 0 1 0
# A mismatch, or no decision at all, opens all three.
fp_case fp-review-mismatch requested 1 empty pull_request_review nomatch 6 3 0 1 1
fp_case fp-review-unreadable requested 1 empty pull_request_review fail 6 3 0 1 1
FP_NO_LIB=1 fp_case fp-review-no-library requested 1 empty pull_request_review match 6 3 0 1 0
# A budget short of the comparison opens every hold and asks nothing.
FP_BUDGET_OK=0 fp_case fp-review-budget-short requested 1 empty pull_request_review match 6 3 0 1 0
# The in_progress delivery: a context the requested delivery left standing
# is covered by the same decision, and costs one PR-list read, no writes.
fp_case fp-in-progress-covered in_progress 1 exact-but-mcg pull_request_review match 3 0 1 0 1
# ...and when the decision no longer holds, the full open path runs.
fp_case fp-in-progress-uncovered in_progress 1 exact-but-mcg pull_request_review nomatch 7 3 1 1 1
# A completion-before-burst still owns the head after a skip decision.
fp_case fp-complete-before-burst in_progress 1 complete-before-burst pull_request_review match 4 0 1 0 1

if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi

echo "All $pass required-check publisher dedup tests passed."
