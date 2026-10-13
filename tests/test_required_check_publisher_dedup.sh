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
    # The #2171 delayed-open ordering fence: completed publisher verdict ids
    # that started at or after the parent was created. Empty by default.
    if [ "$GH_FIXTURE_MODE" = guard-unreadable ]; then
      exit 1
    fi
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
      empty|race|parent-completed|complete-before-burst|write-fails|guard-unreadable)
        ;;
      *)
        echo "unknown fixture mode: $GH_FIXTURE_MODE" >&2
        exit 2
        ;;
    esac
    ;;
  *"repos/"*"/pulls"*)
    printf '%s\n' "$HEAD_SHA"
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
      PARENT_CREATED_AT="2026-09-20T11:59:00Z" \
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
# path. The extra probe makes these eight one-page HTTP fixtures instead of
# the seven-call ordinary path (the #2171 ordering-fence read is one of the
# seven and also hits the commits/check-runs endpoint, so probes=2);
# preserving pending cover is the deliberate failure direction.
run_case partial-requested-publication in_progress 1 partial 8 3 2
run_case delayed-or-failed-requested in_progress 1 empty 8 3 2
run_case both-events-race-before-publication in_progress 1 race 8 3 2
run_case unreadable-dedup-probe in_progress 1 unreadable 8 3 2
run_case foreign-same-name-runs in_progress 1 foreign 8 3 2
run_case foreign-app-exact-marker in_progress 1 foreign-app 8 3 2
run_case completed-same-marker-runs in_progress 1 completed-markers 8 3 2
run_case newer-completed-after-exact-pending in_progress 1 newer-completed 8 3 2
run_case ambiguous-same-time-completed in_progress 1 tied-completed 8 3 2

# Reruns receive no requested event. A new attempt therefore bypasses the
# first-attempt probe and always opens, even if old attempt markers exist.
run_case rerun-new-attempt in_progress 2 exact 7 3 1

# Requested remains the prompt first-attempt path, and a runner that starts
# after the parent completed retains the old one-read/no-write behavior.
run_case requested-event requested 1 empty 7 3 1
run_case delayed-runner-after-completion in_progress 1 parent-completed 1 0 0
# Completion between the early optimization and the burst still owns the
# head: the second status fence prevents late pending entries.
run_case completion-during-enumeration in_progress 1 complete-before-burst 5 0 2
# Exhausted retries on one context still open its siblings and fail red.
run_case partial-pending-write-failure requested 1 write-fails 9 5 1 1

# #2171 round 3 — the delayed-open ordering fence. A completed publisher
# verdict that started at or after the parent was created means a full pass
# already evaluated this head; opening a hold then would re-pend three
# freshly published contexts until the delayed parent ran (the #2112 shape).
# Both deliveries skip at the fence: status read, PR list, fence read — and
# for in_progress the dedup probe before them. No write.
GH_FIXTURE_NEWER_PASS=301; export GH_FIXTURE_NEWER_PASS
run_case newer-pass-owns-head-requested requested 1 empty 3 0 1
run_case newer-pass-owns-head-in-progress in_progress 1 empty 4 0 2
unset GH_FIXTURE_NEWER_PASS
# A fence read that fails is unknown ordering: open anyway (fail closed).
run_case ordering-fence-unreadable-opens requested 1 guard-unreadable 7 3 1

if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi

if [ "${DEDUP_MUTATION_CHILD:-0}" = 1 ]; then
  echo "All $pass required-check publisher dedup tests passed."
  exit 0
fi

# Mutation: disarm the ordering fence in a copy of the live step. The
# newer-pass cases must then observe three writes and fail, proving the
# fence (not the fixture) is what withholds the hold.
python3 - "$WORKFLOW" "$TMP/no-fence.yml" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = 'if [ -n "$PARENT_CREATED_AT" ] && [ -n "$newer_completed" ]; then'
assert text.count(old) == 1
Path(sys.argv[2]).write_text(text.replace(old, 'if false; then', 1))
PY
if REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/no-fence.yml" DEDUP_MUTATION_CHILD=1 \
    bash "$0" >"$TMP/no-fence.out" 2>&1; then
  echo "FAIL: dedup suite accepted a publisher with the #2171 ordering fence disarmed"
  exit 1
fi
echo "PASS: dedup suite rejects a publisher with the #2171 ordering fence disarmed"

echo "All $pass required-check publisher dedup tests and 1 mutation passed."
