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
    if [ "$GH_FIXTURE_MODE" = "parent-completed" ]; then
      printf '%s\n' completed
    else
      printf '%s\n' in_progress
    fi
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
      empty|race|parent-completed)
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
    printf '{}\n'
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$TMP/gh"

pass=0
fail=0

run_case() {
  local name="$1" action="$2" attempt="$3" mode="$4" want_calls="$5" want_posts="$6" want_probes="$7"
  local dir="$TMP/$name" calls posts probes summary
  mkdir -p "$dir"
  : >"$dir/calls"
  summary="Publisher phase 1: evaluation queued for abc123. <!-- required-check-publisher:pending:4242:$attempt -->"

  if ! PATH="$TMP:$PATH" \
      GH_CALL_LOG="$dir/calls" GH_FIXTURE_MODE="$mode" \
      REPO="example/repo" HEAD_SHA="abc123" PARENT_RUN_ID="4242" \
      PARENT_RUN_ATTEMPT="$attempt" EVENT_ACTION="$action" \
      MCG_CONTEXT="Merge clearance gate" \
      CODEX_P1_CONTEXT="Codex P1 unresolved threads" \
      CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings" \
      GITHUB_RUN_ID="9999" \
      bash "$TMP/open.sh" >"$dir/out" 2>&1; then
    echo "FAIL: $name: open step exited nonzero"
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
# six later requests (PR list, second status read, three writes, final status
# read) with one check-runs read: 7 -> 2, five requests saved, zero jobs saved.
run_case first-attempt-already-covered in_progress 1 exact 2 0 1

# Any incomplete or untrustworthy evidence falls through to the full open
# path. The extra probe makes these eight one-page HTTP fixtures instead of
# the old seven; preserving pending cover is the deliberate failure direction.
run_case partial-requested-publication in_progress 1 partial 8 3 1
run_case delayed-or-failed-requested in_progress 1 empty 8 3 1
run_case both-events-race-before-publication in_progress 1 race 8 3 1
run_case unreadable-dedup-probe in_progress 1 unreadable 8 3 1
run_case foreign-same-name-runs in_progress 1 foreign 8 3 1
run_case foreign-app-exact-marker in_progress 1 foreign-app 8 3 1
run_case completed-same-marker-runs in_progress 1 completed-markers 8 3 1
run_case newer-completed-after-exact-pending in_progress 1 newer-completed 8 3 1
run_case ambiguous-same-time-completed in_progress 1 tied-completed 8 3 1

# Reruns receive no requested event. A new attempt therefore bypasses the
# first-attempt probe and always opens, even if old attempt markers exist.
run_case rerun-new-attempt in_progress 2 exact 7 3 0

# Requested remains the prompt first-attempt path, and a runner that starts
# after the parent completed retains the old one-read/no-write behavior.
run_case requested-event requested 1 empty 7 3 0
run_case delayed-runner-after-completion in_progress 1 parent-completed 1 0 0

if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi

echo "All $pass required-check publisher dedup tests passed."
