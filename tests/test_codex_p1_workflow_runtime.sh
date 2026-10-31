#!/usr/bin/env bash
# Executes the checked-in workflow shell against hermetic GitHub API fixtures.
# The workflow steps are extracted by name, so these controls exercise the
# shipped bootstrap guard and scheduled multi-PR loop rather than a copy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${CODEX_P1_WORKFLOW:-$ROOT/.github/workflows/codex-p1-gate.yml}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-p1-workflow-runtime.XXXXXX")"
cleanup() {
  if [ -n "${CODEX_P1_RUNTIME_RECEIPTS:-}" ]; then
    python3 - "$TMP" "$CODEX_P1_RUNTIME_RECEIPTS" <<'PYTHON'
from pathlib import Path
import shutil, sys
source, target = map(Path, sys.argv[1:])
for path in source.rglob('*'):
    if path.is_file() and (path.name in ('out', 'github-output', 'native-status') or path.suffix in ('.log', '.count')):
        dest = target / path.relative_to(source)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
PYTHON
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0

pass() {
  echo "ok - $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "not ok - $1" >&2
  [ -z "${2:-}" ] || echo "  $2" >&2
  FAIL=$((FAIL + 1))
}

extract_step() {
  local job="$1" name="$2" destination="$3"
  ruby - "$WORKFLOW" "$job" "$name" "$destination" <<'RUBY'
require "yaml"
workflow, job_name, step_name, destination = ARGV
document = YAML.load_file(workflow)
job = document.fetch("jobs").fetch(job_name)
step = job.fetch("steps").find { |entry| entry["name"] == step_name }
abort("missing workflow step #{job_name}: #{step_name}") unless step
run = step["run"]
abort("workflow step has no run payload: #{job_name}: #{step_name}") unless run.is_a?(String)
File.write(destination, run)
RUBY
  chmod +x "$destination"
}

EVENT_STEP="$TMP/event-step.sh"
SWEEP_STEP="$TMP/sweep-step.sh"
CLOSE_STEP="$TMP/close-step.sh"
extract_step "codex-p1-gate" "Prepare Codex feedback snapshot evaluation" "$EVENT_STEP"
extract_step "codex-p1-gate" "Close the PR-head check lease" "$CLOSE_STEP"
extract_step "scheduled-sweep" "Re-evaluate gate per PR and post check_run" "$SWEEP_STEP"

make_common_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts/workflow" "$dir/scripts" "$dir/.github/workflows" "$dir/bin" "$dir/runner"
  cat > "$dir/scripts/codex-p1-gate.sh" <<'SH'
#!/usr/bin/env bash
printf 'gate %s\n' "$1" >> "$FIXTURE_LOG/gate.log"
echo "gate clear for PR #$1"
case "${GATE_MODE:-clear}" in
  config) exit 2 ;;
  block) echo 'Required-tier finding or disposition missing'; exit 1 ;;
  late-block)
    count=$(cat "$FIXTURE_LOG/fingerprint-$1.count")
    if [ "$count" -ge 2 ]; then echo 'New required-tier finding or disposition missing'; exit 1; fi ;;
  newer-generation)
    printf 'open-newer %s newer-lease-%s\n' "$1" "$1" >> "$FIXTURE_LOG/mutations.log" ;;
esac
SH
  chmod +x "$dir/scripts/codex-p1-gate.sh"
  cp "${CODEX_P1_SNAPSHOT_DRIVER:-$ROOT/scripts/workflow/codex-p1-snapshot-retry.py}" "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-X PATCH"*) exit 0 ;;
  *) echo head-41 ;;
esac
SH
  chmod +x "$dir/bin/gh"
}

run_event() {
  local dir="$1"
  shift
  (
    cd "$dir"
    export PATH="$dir/bin:$PATH"
    export FIXTURE_LOG="$dir" PR_NUMBER=41 REPO=owner/repo
    export EXPECTED_HEAD_SHA=head-41 HEAD_SHA=head-41 CHECK_ID=lease-41
    export GITHUB_OUTPUT="$dir/github-output" RUNNER_TEMP="$dir/runner"
    # Actions uses bash -e for these unspecified Linux shell steps.
    # Reflect the native job: any failed preparation stays failed even if the
    # always-run closing step succeeds. Recoverable drift must never do that.
    : > "$GITHUB_OUTPUT"
    prep_rc=0
    env "$@" bash -e "$EVENT_STEP" || prep_rc=$?
    GATE_READY="$(sed -n 's/^ready=//p' "$GITHUB_OUTPUT")"
    FINGERPRINT_AVAILABLE="$(sed -n 's/^fingerprint_available=//p' "$GITHUB_OUTPUT")"
    ARCHIVE_RESULT="${EVENT_ARCHIVE_RESULT:-success}"
    LEGACY_BOOTSTRAP="$(sed -n 's/^legacy_bootstrap=//p' "$GITHUB_OUTPUT")"
    export GATE_READY FINGERPRINT_AVAILABLE ARCHIVE_RESULT LEGACY_BOOTSTRAP
    close_rc=0
    env "$@" bash -e "$CLOSE_STEP" || close_rc=$?
    printf 'preparation=%s closing=%s\n' "$prep_rc" "$close_rc" > "$dir/native-status"
    [ "$prep_rc" -eq 0 ] || exit "$prep_rc"
    exit "$close_rc"
  ) >"$dir/out" 2>&1
}

# Consumer installations do not carry the hub manifest. Once their checked-out
# workflow references the helper, a missing or non-executable helper must fail.
for helper_state in missing non-executable; do
  dir="$TMP/event-$helper_state"
  make_common_fixture "$dir"
  printf '%s\n' 'run: scripts/review-feedback-surface-fingerprint.sh' \
    > "$dir/.github/workflows/codex-p1-gate.yml"
  if [ "$helper_state" = non-executable ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'echo fingerprint' \
      > "$dir/scripts/review-feedback-surface-fingerprint.sh"
    chmod -x "$dir/scripts/review-feedback-surface-fingerprint.sh"
  fi
  if run_event "$dir"; then
    fail "event bootstrap rejects a $helper_state referenced helper" "workflow step exited 0"
  elif ! grep -Fq 'Installed feedback-fingerprint helper is missing or not executable' "$dir/out"; then
    fail "event bootstrap rejects a $helper_state referenced helper" "missing infrastructure error"
  elif [ -e "$dir/gate.log" ]; then
    fail "event bootstrap rejects a $helper_state referenced helper" "gate ran after bootstrap failure"
  else
    pass "event bootstrap rejects a $helper_state referenced helper"
  fi
done

# A workflow with no helper reference is the sole event-driven first-delivery
# window. It warns, evaluates the gate, and records that no fingerprint exists.
dir="$TMP/event-first-delivery"
make_common_fixture "$dir"
printf '%s\n' 'name: first delivery' > "$dir/.github/workflows/codex-p1-gate.yml"
if ! run_event "$dir"; then
  fail "event first delivery without a helper reference warns and evaluates" "workflow step failed"
elif ! grep -Fq '::warning::Feedback-fingerprint helper is not installed' "$dir/out"; then
  fail "event first delivery without a helper reference warns and evaluates" "warning missing"
elif ! grep -Fxq 'gate 41' "$dir/gate.log"; then
  fail "event first delivery without a helper reference warns and evaluates" "gate did not run"
elif ! grep -Fxq 'fingerprint_available=false' "$dir/github-output"; then
  fail "event first delivery without a helper reference warns and evaluates" "bootstrap output missing"
else
  pass "event first delivery without a helper reference warns and evaluates"
fi

# GitHub can execute the PR's first copy of this workflow while the trusted
# default-branch checkout still predates both workflow and helper.
dir="$TMP/event-workflow-absent"
make_common_fixture "$dir"
if ! run_event "$dir"; then
  fail "event first delivery with an absent default-branch workflow warns and evaluates" "workflow step failed"
elif ! grep -Fq '::warning::Feedback-fingerprint helper is not installed' "$dir/out"; then
  fail "event first delivery with an absent default-branch workflow warns and evaluates" "warning missing"
elif ! grep -Fxq 'gate 41' "$dir/gate.log"; then
  fail "event first delivery with an absent default-branch workflow warns and evaluates" "gate did not run"
else
  pass "event first delivery with an absent default-branch workflow warns and evaluates"
fi

# An existing path that cannot be searched is an I/O failure, not evidence of
# first delivery. A directory produces grep rc=2 even under a privileged UID.
dir="$TMP/event-workflow-read-failure"
make_common_fixture "$dir"
mkdir "$dir/.github/workflows/codex-p1-gate.yml"
if run_event "$dir"; then
  fail "event bootstrap fails closed when the existing workflow cannot be searched" "workflow step exited 0"
elif ! grep -Fq 'Could not read the trusted Codex P1 workflow' "$dir/out"; then
  fail "event bootstrap fails closed when the existing workflow cannot be searched" "read error missing"
elif [ -e "$dir/gate.log" ]; then
  fail "event bootstrap fails closed when the existing workflow cannot be searched" "gate ran after read failure"
else
  pass "event bootstrap fails closed when the existing workflow cannot be searched"
fi

# A dangling link is an existing installation fault and must not masquerade as
# positive absence merely because its target fails the ordinary -e predicate.
dir="$TMP/event-workflow-dangling-link"
make_common_fixture "$dir"
ln -s missing-target "$dir/.github/workflows/codex-p1-gate.yml"
if run_event "$dir"; then
  fail "event bootstrap fails closed on a dangling trusted-workflow link" "workflow step exited 0"
elif ! grep -Fq 'Could not read the trusted Codex P1 workflow' "$dir/out"; then
  fail "event bootstrap fails closed on a dangling trusted-workflow link" "read error missing"
elif [ -e "$dir/gate.log" ]; then
  fail "event bootstrap fails closed on a dangling trusted-workflow link" "gate ran after read failure"
else
  pass "event bootstrap fails closed on a dangling trusted-workflow link"
fi

# With the helper installed, both reads fence the actual gate evaluation.
dir="$TMP/event-installed"
make_common_fixture "$dir"
printf '%s\n' 'run: scripts/review-feedback-surface-fingerprint.sh' \
  > "$dir/.github/workflows/codex-p1-gate.yml"
cat > "$dir/scripts/review-feedback-surface-fingerprint.sh" <<'SH'
#!/usr/bin/env bash
printf 'fingerprint %s\n' "$1" >> "$FIXTURE_LOG/fingerprint.log"
echo stable-fingerprint
SH
chmod +x "$dir/scripts/review-feedback-surface-fingerprint.sh"
if ! run_event "$dir"; then
  fail "installed event helper fences the gate" "workflow step failed"
elif [ "$(grep -Fc 'fingerprint 41' "$dir/fingerprint.log")" -ne 3 ]; then
  fail "installed event helper fences the gate" "expected pre/post fingerprint reads"
elif ! grep -Fxq 'fingerprint_available=true' "$dir/github-output"; then
  fail "installed event helper fences the gate" "fingerprint outputs missing"
else
  pass "installed event helper fences the gate"
fi

make_sweep_fixture() {
  local dir="$1"
  make_common_fixture "$dir"
  : > "$dir/mutations.log"
  : > "$dir/fingerprint.log"
  cat > "$dir/scripts/review-feedback-surface-fingerprint.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
pr="$1"
count_file="$FIXTURE_LOG/fingerprint-$pr.count"
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf 'fingerprint %s %s\n' "$pr" "$count" >> "$FIXTURE_LOG/fingerprint.log"
if [ "${FP_MODE:-stable}" = pre-fail-1 ] && [ "$pr" = 1 ] && [ "$count" -eq 1 ]; then
  exit 1
fi
if [ "${FP_MODE:-stable}" = post-fail-1 ] && [ "$pr" = 1 ] && [ "$count" -eq 2 ]; then
  exit 1
fi
if [ "${FP_MODE:-stable}" = publish-fail-1 ] && [ "$pr" = 1 ] && [ "$count" -eq 3 ]; then
  exit 1
fi
if [ "${FP_MODE:-stable}" = churn ]; then
  echo "fp-$pr-$count"
  exit 0
fi
if [ "${FP_MODE:-stable}" = publish-change ] && [ "$count" -le 2 ]; then
  echo "old-$pr"
  exit 0
fi
if [ "${FP_MODE:-stable}" = change-once ] && [ "$count" -eq 1 ]; then
  echo "old-$pr"
else
  echo "fp-$pr"
fi
SH
  chmod +x "$dir/scripts/review-feedback-surface-fingerprint.sh"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FIXTURE_LOG/gh.log"
printf '\n' >> "$FIXTURE_LOG/gh.log"
# #2910: the stalled modes' PR predates its source runs, so the sweep's
# source scan (which starts at the PR's creation) can reach run 502.
pr_created=2026-01-01T00:00:00Z
[[ "${RELAY_MODE:-empty}" != stalled* ]] || pr_created=2025-12-31T12:00:00Z
# The real relay reader probes CLI support before a deadline-bound API read.
# A successful legacy help response selects the existing timeout environment.
if [ "$*" = 'api --help' ]; then echo 'Usage: gh api <endpoint>'; exit 0; fi
[ "${1:-}" = api ] || exit 90

if [ "${2:-}" = -X ] && [ "${3:-}" = POST ] && [[ "${4:-}" == */rerun ]]; then
  run="${4#repos/owner/repo/actions/runs/}"
  printf 'rerun %s\n' "${run%/rerun}" >> "$FIXTURE_LOG/mutations.log"
  exit 0
fi
if [ "${2:-}" = -X ] && [ "${3:-}" = POST ]; then
  endpoint="$4"
  head_sha=""
  previous=""
  for arg in "$@"; do
    if [ "$previous" = -f ] && [[ "$arg" == head_sha=* ]]; then
      head_sha="${arg#head_sha=}"
    fi
    previous="$arg"
  done
  pr="${head_sha#head-}"
  printf 'open %s lease-%s\n' "$pr" "$pr" >> "$FIXTURE_LOG/mutations.log"
  echo "lease-$pr"
  exit 0
fi

if [ "${2:-}" = -X ] && [ "${3:-}" = PATCH ]; then
  endpoint="$4"
  conclusion=""
  summary=""
  previous=""
  for arg in "$@"; do
    if [ "$previous" = -f ] && [[ "$arg" == conclusion=* ]]; then
      conclusion="${arg#conclusion=}"
    fi
    if [ "$previous" = -f ] && [[ "$arg" == 'output[summary]='* ]]; then
      summary="${arg#*=}"
    fi
    previous="$arg"
  done
  if [ "${PATCH_MODE:-ok}" = fail ]; then exit 1; fi
  lease="${endpoint##*/}"
  printf 'close %s %s\n' "$lease" "$conclusion" >> "$FIXTURE_LOG/mutations.log"
  printf '%s\n' "$summary" > "$FIXTURE_LOG/summary-$lease.log"
  exit 0
fi

endpoint="$2"
if [ "$endpoint" = --method ] && [ "${3:-}" = GET ] \
  && [ "${4:-}" = repos/owner/repo/actions/workflows/codex-p1-gate.yml/runs ]; then
  source_event=""
  created_window=""
  for arg in "$@"; do
    case "$arg" in
      event=*) source_event="${arg#event=}" ;;
      created=*) created_window="${arg#created=}" ;;
    esac
  done
  if [ "$source_event" != pull_request ] || [ "${RELAY_MODE:-empty}" = empty ]; then
    echo '{"total_count":0,"workflow_runs":[]}'
  elif [ "$RELAY_MODE" = pending ]; then
    echo '{"total_count":2,"workflow_runs":[{"id":501,"display_title":"Codex P1 Gate relay-v1 PR #1"},{"id":502,"display_title":"Codex P1 Gate relay-v1 PR #1"}]}'
  elif [[ "$RELAY_MODE" == stalled* ]]; then
    # #2907: 502 completed (four hours before the fixed clock, or at it for
    # stalled-recent) and its relay never posted a terminal marker.
    done_at=2025-12-31T20:00:00Z
    [ "$RELAY_MODE" != stalled-recent ] || done_at=2026-01-01T00:00:00Z
    # Attempt 2 of 502 started at 19:58:00; stalled-prior-attempt adds a
    # failed relay from attempt 1, created at 19:57:00. Like GitHub, return
    # only runs created inside the requested `created=START..END` window
    # (#2910), so a source run before the PR's creation is never reached.
    # The window itself must run from the PR's creation to the fixed clock.
    if [ "$created_window" != "$pr_created..2026-01-01T00:00:00Z" ]; then
      echo "unexpected created window: $created_window" >&2
      exit 1
    fi
    jq -cn --arg done "$done_at" --arg window "$created_window" '
      ($window | split("..")) as [$start, $end] |
      [{id:501,display_title:"Codex P1 Gate relay-v1 PR #1",status:"completed",created_at:"2025-12-31T18:58:30Z",updated_at:"2025-12-31T19:00:00Z",run_started_at:"2025-12-31T18:59:00Z"},
       {id:502,display_title:"Codex P1 Gate relay-v1 PR #1",status:"completed",created_at:"2025-12-31T19:56:00Z",updated_at:$done,run_started_at:"2025-12-31T19:58:00Z"}]
      | map(select(.created_at >= $start and .created_at <= $end))
      | {total_count:length,workflow_runs:.}'
  else
    echo '{"total_count":1,"workflow_runs":[{"id":501,"display_title":"Codex P1 Gate relay-v1 PR #1"}]}'
  fi
  exit 0
fi
if [ "$endpoint" = --paginate ] && [ "${3:-}" = repos/owner/repo/issues/1/comments ]; then
  if [ "${RELAY_MODE:-empty}" = empty ]; then
    echo '[]'
  else
    echo '[{"user":{"login":"github-actions[bot]"},"body":"<!-- mergepath-feedback-archive-relay:v2 run=501 publisher=900 status=complete -->"}]'
  fi
  exit 0
fi
# #2907 stalled-relay recovery: relay history, the failed relay's job log
# (bound to its source by the runner-rendered env block), and the re-run.
if [[ "$*" == *"repos/owner/repo/actions/workflows/codex-feedback-archive-relay.yml/runs?"* ]]; then
  printf '%s\n' "$*" >> "$FIXTURE_LOG/relay-list.log"
  attempt=1
  [ "${RELAY_MODE:-empty}" != stalled-exhausted ] || attempt=3
  case "${RELAY_MODE:-empty}" in
    stalled-list-fails) exit 1 ;;
    stalled-inflight) echo '[{"total_count":2,"workflow_runs":[{"id":698,"status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2025-12-31T20:00:30Z"},{"id":699,"status":"queued","created_at":"2025-12-31T23:00:00Z"}]}]' ;;
    stalled-prior-attempt)
      # The only failed relay, 651, was created for attempt 1, before attempt
      # 2 started; its log binds to 502 too. It must not be re-run.
      echo '[{"total_count":1,"workflow_runs":[{"id":651,"status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2025-12-31T19:57:00Z"}]}]' ;;
    stalled-unreadable)
      # Failed relay 650 sits nearer the stalled source than 698, and its job
      # log cannot be read.
      echo '[{"total_count":2,"workflow_runs":[{"id":650,"status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2025-12-31T20:00:05Z"},{"id":698,"status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2025-12-31T20:00:30Z"}]}]' ;;
    stalled-crowded)
      # 25 unrelated failed relays, created after the stalled attempt started
      # and before the bound relay 698, are listed ahead of it.
      jq -cn '[{total_count:26,workflow_runs:([range(0;25) | {id:(600 + .),status:"completed",conclusion:"failure",
         run_attempt:1,created_at:("2025-12-31T19:58:" + (10 + (. % 5) * 10 | tostring) + "Z")}]
         + [{id:698,status:"completed",conclusion:"failure",run_attempt:1,created_at:"2025-12-31T20:00:30Z"}])}]' ;;
    *) jq -cn --argjson attempt "$attempt" '[{total_count:2,workflow_runs:[
         {id:697,status:"completed",conclusion:"success",run_attempt:1,created_at:"2025-12-31T19:59:00Z"},
         {id:698,status:"completed",conclusion:"failure",run_attempt:$attempt,created_at:"2025-12-31T20:00:30Z"}]}]' ;;
  esac
  exit 0
fi
case "$*" in
  'api repos/owner/repo/actions/runs/698/attempts/'*'/jobs')
    echo '{"jobs":[{"id":6981}]}'; exit 0 ;;
  'api repos/owner/repo/actions/runs/6'[0-9][0-9]'/attempts/1/jobs')
    run="${2#repos/owner/repo/actions/runs/}"
    printf '{"jobs":[{"id":%s5}]}\n' "${run%%/*}"; exit 0 ;;
  'api repos/owner/repo/actions/jobs/6515/logs')
    printf '%s\n' '##[group]Run set -euo pipefail' '  env:' '    SOURCE_RUN_ID: 502' '##[endgroup]'
    exit 0 ;;
  'api repos/owner/repo/actions/jobs/6505/logs')
    [ "${RELAY_MODE:-empty}" != stalled-unreadable ] || exit 1 ;;&
  'api repos/owner/repo/actions/jobs/6'[0-9][0-9]'5/logs')
    printf '%s\n' '##[group]Run set -euo pipefail' '  env:' '    SOURCE_RUN_ID: 777' '##[endgroup]'
    exit 0 ;;
  'api repos/owner/repo/actions/jobs/6981/logs')
    source=502
    [ "${RELAY_MODE:-empty}" != stalled-unmatched ] || source=999
    printf '%s\n' '2025-12-31T20:00:31Z ##[group]Run set -euo pipefail' \
      '2025-12-31T20:00:31Z   shell: /usr/bin/bash -e {0}' \
      '2025-12-31T20:00:31Z   env:' \
      "2025-12-31T20:00:31Z     SOURCE_RUN_ID: $source" \
      '2025-12-31T20:00:31Z ##[endgroup]'
    exit 0 ;;
esac
case "${@: -1}" in
  repos/owner/repo/actions/workflows/codex-feedback-archive-relay.yml)
    # #2907 jq noise: the verifier exits 2 when its workflow identity read fails.
    [ "${RELAY_MODE:-empty}" != markers-fail ] || exit 1
    echo '{"id":89,"path":".github/workflows/codex-feedback-archive-relay.yml"}'; exit 0 ;;
  repos/owner/repo/actions/runs/900)
    echo '{"id":900,"workflow_id":89,"event":"workflow_run","path":".github/workflows/codex-feedback-archive-relay.yml","head_branch":"main","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repository":{"full_name":"owner/repo"}}'; exit 0 ;;
  repos/owner/repo/actions/runs/900/jobs\?filter=all\&per_page=100)
    echo '[{"jobs":[{"id":901,"run_id":900,"steps":[{"name":"Persist archive and publish the exact-head gate","conclusion":"success"}]}]}]'; exit 0 ;;
  repos/owner/repo/actions/jobs/901/logs)
    cat <<'LOG'
##[group]Run set -euo pipefail
  shell: /usr/bin/bash -e {0}
  env:
    PR_NUMBER: 1
    SOURCE_RUN_ID: 501
    HANDOFF_FILE: /tmp/handoff/codex-p1-read-only-handoff.json
##[endgroup]
LOG
    exit 0 ;;
esac
if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/pulls/([0-9]+)$ ]]; then
  pr="${BASH_REMATCH[1]}"
  count_file="$FIXTURE_LOG/pull-$pr.count"
  count=0
  [ ! -f "$count_file" ] || count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"
  if [ "${SWEEP_MODE:-stable}" = first-read-fails ] && [ "$pr" = 1 ]; then
    echo 'simulated PR read failure' >&2
    exit 1
  fi
  if [ "${SWEEP_MODE:-stable}" = first-json-malformed ] && [ "$pr" = 1 ] \
    && [[ " $* " != *" --jq "* ]]; then
    echo '{'
    exit 0
  fi
  sha="head-$pr"
  if [ "${SWEEP_MODE:-stable}" = head-moves ] && [ "$pr" = 1 ] && [ "$count" -gt 1 ]; then
    sha="moved-$pr"
  fi
  if [[ " $* " == *" --jq "* ]]; then
    echo "$sha"
  else
    fork=false
    if [ "${SWEEP_MODE:-stable}" = relay-fork ] && [ "$pr" = 1 ]; then fork=true; fi
    jq -cn --arg sha "$sha" --argjson fork "$fork" --arg created "$pr_created" '{head:{sha:$sha,repo:{fork:$fork}},user:{login:"owner"},created_at:$created}'
  fi
  exit 0
fi

echo "unexpected gh call: $*" >&2
exit 91
SH
  chmod +x "$dir/bin/gh"
}

run_sweep() {
  local dir="$1" sweep_mode="$2" fp_mode="$3"
  set +e
  (
    cd "$dir"
    env PATH="$dir/bin:$PATH" FIXTURE_LOG="$dir" PRS=$'1\n2' \
      REPO=owner/repo CHECK_NAME='Codex P1 unresolved threads' \
      RUNNER_TEMP="$dir/runner" SWEEP_MODE="$sweep_mode" FP_MODE="$fp_mode" \
      RELAY_MODE="${4:-empty}" \
      GATE_MODE="${GATE_MODE:-clear}" PATCH_MODE="${PATCH_MODE:-ok}" \
      bash -e "$SWEEP_STEP"
  ) >"$dir/out" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# The scheduled workflow and helper arrive from one default-branch revision;
# it never receives the event-driven bootstrap exception. The native scheduled
# job is attached to the default branch, so the missing-helper failure must also
# publish a terminal failure generation on every readable PR head.
dir="$TMP/sweep-no-bootstrap"
make_sweep_fixture "$dir"
rm "$dir/scripts/review-feedback-surface-fingerprint.sh"
rc=$(run_sweep "$dir" stable stable)
if [ "$rc" -eq 0 ]; then
  fail "scheduled missing helper fails every readable PR-head lease" "workflow step exited 0"
elif ! grep -Fq 'Installed feedback-fingerprint helper is missing or not executable' "$dir/out"; then
  fail "scheduled missing helper fails every readable PR-head lease" "infrastructure error missing"
elif grep -Fq '::warning::' "$dir/out"; then
  fail "scheduled missing helper fails every readable PR-head lease" "bootstrap warning was emitted"
elif ! grep -Fxq 'open 1 lease-1' "$dir/mutations.log" \
  || ! grep -Fxq 'close lease-1 failure' "$dir/mutations.log" \
  || ! grep -Fxq 'open 2 lease-2' "$dir/mutations.log" \
  || ! grep -Fxq 'close lease-2 failure' "$dir/mutations.log"; then
  fail "scheduled missing helper fails every readable PR-head lease" "not every exact PR-head lease was failed"
elif [ -e "$dir/gate.log" ] || [ -s "$dir/fingerprint.log" ]; then
  fail "scheduled missing helper fails every readable PR-head lease" "evaluation ran without the helper"
else
  pass "scheduled missing helper fails every readable PR-head lease"
fi

assert_failure_then_second_pr() {
  local name="$1" dir="$2" expected_first="$3"
  local rc
  rc=$(run_sweep "$dir" stable "$4")
  if [ "$rc" -eq 0 ]; then
    fail "$name" "sweep did not report its infrastructure failure"
  elif ! grep -Fxq "open 1 lease-1" "$dir/mutations.log" \
    || ! grep -Fxq "close lease-1 $expected_first" "$dir/mutations.log"; then
    fail "$name" "the first PR's exact lease was not closed as $expected_first"
  elif ! grep -Fxq 'open 2 lease-2' "$dir/mutations.log" \
    || ! grep -Fxq 'close lease-2 success' "$dir/mutations.log"; then
    fail "$name" "the later PR was not processed successfully"
  else
    pass "$name"
  fi
}

dir="$TMP/sweep-pr-read-failure"
make_sweep_fixture "$dir"
rc=$(run_sweep "$dir" first-read-fails stable)
if [ "$rc" -eq 0 ]; then
  fail "failed first PR read performs no mutation and continues" "sweep did not report its infrastructure failure"
elif grep -Eq '(^| )1( |$)|lease-1' "$dir/mutations.log"; then
  fail "failed first PR read performs no mutation and continues" "the unreadable PR received a check mutation"
elif ! grep -Fxq 'open 2 lease-2' "$dir/mutations.log" \
  || ! grep -Fxq 'close lease-2 success' "$dir/mutations.log"; then
  fail "failed first PR read performs no mutation and continues" "the later PR was not processed successfully"
else
  pass "failed first PR read performs no mutation and continues"
fi

dir="$TMP/sweep-pr-parse-failure"
make_sweep_fixture "$dir"
rc=$(run_sweep "$dir" first-json-malformed stable)
if [ "$rc" -eq 0 ]; then
  fail "malformed first PR response performs no mutation and continues" "sweep did not report its infrastructure failure"
elif grep -Eq '(^| )1( |$)|lease-1' "$dir/mutations.log"; then
  fail "malformed first PR response performs no mutation and continues" "the unparseable PR received a check mutation"
elif ! grep -Fxq 'open 2 lease-2' "$dir/mutations.log" \
  || ! grep -Fxq 'close lease-2 success' "$dir/mutations.log"; then
  fail "malformed first PR response performs no mutation and continues" "the later PR was not processed successfully"
else
  pass "malformed first PR response performs no mutation and continues"
fi

dir="$TMP/sweep-pre-fingerprint-failure"
make_sweep_fixture "$dir"
assert_failure_then_second_pr \
  "failed pre-evaluation fingerprint closes its exact lease and continues" \
  "$dir" failure pre-fail-1

dir="$TMP/sweep-post-fingerprint-failure"
make_sweep_fixture "$dir"
assert_failure_then_second_pr \
  "failed post-evaluation fingerprint closes its exact lease and continues" \
  "$dir" failure post-fail-1

dir="$TMP/sweep-publication-fingerprint-failure"
make_sweep_fixture "$dir"
assert_failure_then_second_pr \
  "failed publication-time fingerprint closes its exact lease and continues" \
  "$dir" failure publish-fail-1

dir="$TMP/sweep-head-moved"
make_sweep_fixture "$dir"
rc=$(run_sweep "$dir" head-moves stable)
if [ "$rc" -eq 0 ]; then
  fail "scheduled head drift fails closed on the opened generation" "sweep did not report head drift"
elif ! grep -Fxq 'open 1 lease-1' "$dir/mutations.log" \
  || ! grep -Fxq 'close lease-1 failure' "$dir/mutations.log"; then
  fail "scheduled head drift fails closed on the opened generation" "the exact first lease was not failed"
elif ! grep -Fxq 'close lease-2 success' "$dir/mutations.log"; then
  fail "scheduled head drift fails closed on the opened generation" "later PR processing did not continue"
else
  pass "scheduled head drift fails closed on the opened generation"
fi

# Drive the production relay predicate inside the complete two-PR sweep. The
# mixed case has one completed source run and one still awaiting its relay.
for relay_mode in empty all-terminal pending; do
  dir="$TMP/sweep-relay-$relay_mode"
  make_sweep_fixture "$dir"
  mkdir -p "$dir/scripts/workflow"
  cp "$ROOT/scripts/workflow/verified-relay-markers.py" "$dir/scripts/workflow/"
  cat > "$dir/scripts/workflow/feedback-archive-relay-source.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -c '{requires_relay:true,source_run_id:.id}'
SH
  chmod +x "$dir/scripts/workflow/feedback-archive-relay-source.sh"
  # The production scan uses GNU date syntax. Keep this fixture independent
  # of the host date implementation and clock by supplying one fixed window.
  cat > "$dir/bin/date" <<'SH'
#!/usr/bin/env bash
case "${@: -1}" in
  +%s) echo 1767225600 ;;
  +%Y-%m-%dT%H:%M:%SZ) echo 2026-01-01T00:00:00Z ;;
  *) exit 92 ;;
esac
SH
  chmod +x "$dir/bin/date"
  rc=$(run_sweep "$dir" relay-fork stable "$relay_mode")
  expected=success
  [ "$relay_mode" != pending ] || expected=failure
  if [ "$rc" -ne 0 ]; then
    fail "relay $relay_mode inventory is not an infrastructure error" "sweep exited $rc"
  elif ! grep -Fxq "close lease-1 $expected" "$dir/mutations.log"; then
    fail "relay $relay_mode inventory yields the correct first-PR verdict" "expected $expected"
  elif ! grep -Fxq 'close lease-2 success' "$dir/mutations.log" \
    || ! grep -Fxq 'gate 2' "$dir/gate.log"; then
    fail "relay $relay_mode inventory preserves later PR evaluation" "second PR was not evaluated"
  elif [ "$relay_mode" = pending ] && \
    { grep -Fxq 'gate 1' "$dir/gate.log" \
      || ! grep -Fq 'relay is still pending' "$dir/summary-lease-1.log"; }; then
    fail "pending relay holds only its PR" "pending relay was evaluated as clear"
  elif [ "$relay_mode" != pending ] && ! grep -Fxq 'gate 1' "$dir/gate.log"; then
    fail "relay $relay_mode inventory permits gate evaluation" "first PR was not evaluated"
  elif [ "$relay_mode" != empty ] && ! grep -Fxq 'api --help ' "$dir/gh.log"; then
    fail "relay $relay_mode inventory exercises CLI capability detection" "production help probe was not called"
  else
    pass "relay $relay_mode inventory yields its verdict and continues the sweep"
  fi
done

# #2907: a relay that ended without a terminal marker (its own failure path
# could not post `status=failed`) is re-run by the sweep, which still holds
# the PR pending. An unrelated relay in flight does not defer it (#2908
# review). A recent source run, an exhausted or unbindable relay, or
# unreadable relay history re-runs nothing.
for relay_mode in stalled stalled-crowded stalled-unreadable stalled-prior-attempt stalled-inflight stalled-recent stalled-list-fails stalled-unmatched stalled-exhausted; do
  dir="$TMP/sweep-relay-$relay_mode"
  make_sweep_fixture "$dir"
  mkdir -p "$dir/scripts/workflow"
  cp "$ROOT/scripts/workflow/verified-relay-markers.py" "$ROOT/scripts/workflow/relay-stall-recovery.py" "$dir/scripts/workflow/"
  cat > "$dir/scripts/workflow/feedback-archive-relay-source.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -c '{requires_relay:true,source_run_id:.id}'
SH
  chmod +x "$dir/scripts/workflow/feedback-archive-relay-source.sh"
  # #2910: convert real timestamps so the source scan's `created` window is
  # the PR's creation through the fixed clock 2026-01-01T00:00:00Z. jq does
  # the conversion, so the stub behaves the same under GNU and BSD date.
  cat > "$dir/bin/date" <<'SH'
#!/usr/bin/env bash
value=""
while [ $# -gt 1 ]; do
  case "$1" in
    -u) shift ;;
    -d) value="$2"; shift 2 ;;
    *) exit 92 ;;
  esac
done
case "${1:-}:$value" in
  +%s:) echo 1767225600 ;;
  +%s:*) jq -rn --arg v "$value" '$v | fromdateiso8601' ;;
  +%Y-%m-%dT%H:%M:%SZ:@*) jq -rn --arg v "${value#@}" '$v | tonumber | todate' ;;
  *) exit 92 ;;
esac
SH
  chmod +x "$dir/bin/date"
  rc=$(run_sweep "$dir" relay-fork stable "$relay_mode")
  reruns=$(grep -c '^rerun ' "$dir/mutations.log" || true)
  if [ "$rc" -ne 0 ]; then
    fail "relay $relay_mode is not an infrastructure error" "sweep exited $rc: $(tail -5 "$dir/out")"
  elif ! grep -Fxq 'close lease-1 failure' "$dir/mutations.log" \
    || grep -Fxq 'gate 1' "$dir/gate.log" \
    || ! grep -Fq 'relay is still pending' "$dir/summary-lease-1.log"; then
    fail "relay $relay_mode keeps its PR pending" "$(cat "$dir/mutations.log")"
  elif ! grep -Fxq 'close lease-2 success' "$dir/mutations.log"; then
    fail "relay $relay_mode preserves later PR evaluation"
  elif { [ "$relay_mode" = stalled ] || [ "$relay_mode" = stalled-crowded ] || [ "$relay_mode" = stalled-unreadable ] || [ "$relay_mode" = stalled-inflight ]; } && \
    { [ "$reruns" -ne 1 ] || ! grep -Fxq 'rerun 698' "$dir/mutations.log" \
      || ! grep -Fq 'Re-ran stalled relay run(s) 698 for PR #1' "$dir/out" \
      || ! grep -Fq 'created=%3E%3D2025-12-31T19:58:00Z' "$dir/relay-list.log"; }; then
    fail "stalled relay is re-run exactly once" "$(cat "$dir/out")"
  elif [ "$relay_mode" != stalled ] && [ "$relay_mode" != stalled-crowded ] && [ "$relay_mode" != stalled-unreadable ] && [ "$relay_mode" != stalled-inflight ] && [ "$reruns" -ne 0 ]; then
    fail "relay $relay_mode re-runs nothing" "$(cat "$dir/mutations.log")"
  elif [ "$relay_mode" = stalled-recent ] && [ -e "$dir/relay-list.log" ]; then
    fail "a recent source run spends no relay history read"
  elif [ "$relay_mode" = stalled-list-fails ] && ! grep -Fq 'could not read relay history for PR #1' "$dir/out"; then
    fail "unreadable relay history is reported"
  elif { [ "$relay_mode" = stalled-unmatched ] || [ "$relay_mode" = stalled-exhausted ] || [ "$relay_mode" = stalled-prior-attempt ]; } \
    && ! grep -Fq 'No re-runnable failed relay run found for stalled source run(s) 502 on PR #1' "$dir/out"; then
    fail "relay $relay_mode names the unrecovered source run"
  else
    pass "relay $relay_mode stays pending and re-runs $reruns relay(s)"
  fi
done

# #2908 review: 25 unrelated failed relays sit NEARER the stalled source's
# completion than its own delayed relay 698, so nearest-first ordering puts
# 698 last. The bounded window must rotate across sweep slots: the slot at
# 21:00:00Z starts at offset 0 and misses 698, the next slot starts at 20
# and re-runs it.
dir="$TMP/relay-window-rotation"
mkdir -p "$dir/bin"
cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'api --help') echo 'Usage: gh api <endpoint>' ;;
  *'codex-feedback-archive-relay.yml/runs?'*)
    jq -cn '[{total_count:26,workflow_runs:([range(1;26) | {id:(600 + .),status:"completed",conclusion:"failure",
      run_attempt:1,created_at:("2025-12-31T20:00:" + (if . < 10 then "0" else "" end) + (. | tostring) + "Z")}]
      + [{id:698,status:"completed",conclusion:"failure",run_attempt:1,created_at:"2025-12-31T20:00:30Z"}])}]' ;;
  'api repos/owner/repo/actions/runs/'*'/attempts/1/jobs')
    run="${2#repos/owner/repo/actions/runs/}"
    printf '{"jobs":[{"id":%s0}]}\n' "${run%%/*}" ;;
  'api repos/owner/repo/actions/jobs/'*'/logs')
    job="${2#repos/owner/repo/actions/jobs/}"
    source=777
    [ "${job%/logs}" != 6980 ] || source=502
    printf '%s\n' '##[group]Run set -euo pipefail' '  env:' "    SOURCE_RUN_ID: $source" '##[endgroup]' ;;
  'api -X POST repos/owner/repo/actions/runs/'*'/rerun')
    run="${4#repos/owner/repo/actions/runs/}"
    printf 'rerun %s\n' "${run%/rerun}" >> "$FIXTURE_LOG/rerun.log" ;;
  *) echo "unexpected gh call: $*" >&2; exit 91 ;;
esac
SH
chmod +x "$dir/bin/gh"
pending='[{"id":502,"status":"completed","updated_at":"2025-12-31T20:00:00Z","run_started_at":"2025-12-31T19:58:00Z"}]'
first=$(printf '%s' "$pending" | PATH="$dir/bin:$PATH" FIXTURE_LOG="$dir" \
  python3 "$ROOT/scripts/workflow/relay-stall-recovery.py" --repo owner/repo --now 1767214800 --stall-seconds 3600)
second=$(printf '%s' "$pending" | PATH="$dir/bin:$PATH" FIXTURE_LOG="$dir" \
  python3 "$ROOT/scripts/workflow/relay-stall-recovery.py" --repo owner/repo --now 1767216600 --stall-seconds 3600)
if [ "$(jq -c '[.rerun, .incomplete]' <<<"$first")" != '[[],true]' ]; then
  fail "the first sweep slot reports a capped window that misses the delayed relay" "$first"
elif [ "$(jq -c '.rerun' <<<"$second")" != '[698]' ] || [ "$(cat "$dir/rerun.log")" != 'rerun 698' ]; then
  fail "the next sweep slot rotates the window onto the delayed relay" "$second"
else
  pass "the bounded relay window rotates across sweep slots onto a delayed relay"
fi

# #2907: a failed relay verifier (exit 2) fails the PR closed without feeding
# its empty output to jq --argjson.
dir="$TMP/sweep-relay-markers-fail"
make_sweep_fixture "$dir"
mkdir -p "$dir/scripts/workflow"
cp "$ROOT/scripts/workflow/verified-relay-markers.py" "$ROOT/scripts/workflow/relay-stall-recovery.py" "$dir/scripts/workflow/"
cat > "$dir/scripts/workflow/feedback-archive-relay-source.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -c '{requires_relay:true,source_run_id:.id}'
SH
chmod +x "$dir/scripts/workflow/feedback-archive-relay-source.sh"
cat > "$dir/bin/date" <<'SH'
#!/usr/bin/env bash
case "${@: -1}" in
  +%s) echo 1767225600 ;;
  +%Y-%m-%dT%H:%M:%SZ) echo 2026-01-01T00:00:00Z ;;
  *) exit 92 ;;
esac
SH
chmod +x "$dir/bin/date"
rc=$(run_sweep "$dir" relay-fork stable markers-fail)
if [ "$rc" -eq 0 ]; then
  fail "failed relay verifier is an infrastructure error" "sweep exited 0"
elif ! grep -Fxq 'close lease-1 failure' "$dir/mutations.log" \
  || ! grep -Fq 'source run scan failed closed' "$dir/summary-lease-1.log"; then
  fail "failed relay verifier fails its PR closed" "$(cat "$dir/mutations.log")"
elif grep -Fq -- '--argjson' "$dir/out"; then
  fail "failed relay verifier emits no jq --argjson noise" "$(grep -F -- '--argjson' "$dir/out")"
elif ! grep -Fxq 'close lease-2 success' "$dir/mutations.log"; then
  fail "failed relay verifier preserves later PR evaluation"
else
  pass "failed relay verifier fails closed without jq --argjson noise"
fi

# #1825: a bot posts once while the gate evaluates, then the full surface
# stays clear. The same native execution and lease must recover automatically.
dir="$TMP/sweep-one-change"
make_sweep_fixture "$dir"
rc=$(run_sweep "$dir" stable change-once)
if [ "$rc" -ne 0 ] || ! grep -Fxq 'close lease-1 success' "$dir/mutations.log"; then
  fail "one feedback change recovers scheduled native execution and its lease" "native rc=$rc"
else
  pass "one feedback change recovers scheduled native execution and its lease"
fi

dir="$TMP/event-one-change"
make_sweep_fixture "$dir"
printf '%s\n' 'run: scripts/review-feedback-surface-fingerprint.sh' > "$dir/.github/workflows/codex-p1-gate.yml"
if run_event "$dir" PATH="$dir/bin:$PATH" FP_MODE=change-once; then
  event_rc=0
else
  event_rc=$?
fi
if [ "$event_rc" -ne 0 ]; then
  fail "one feedback change keeps native event eligible for automatic recovery" "native evaluation rc=$event_rc"
else
  pass "one feedback change keeps native event eligible for automatic recovery"
fi

# Exercise the real native preparation + closing steps, and the same driver
# under the complete scheduled loop. No step has continue-on-error semantics.
for producer in event scheduled; do
  for scenario in publish-change change-block eval-block churn config archive-failed patch-failed newer-generation; do
    dir="$TMP/$producer-$scenario"
    make_sweep_fixture "$dir"
    fp=stable; gate=clear; archive=success; patch=ok; expected=failure
    case "$scenario" in
      publish-change) fp=publish-change; expected=success ;;
      change-block) fp=publish-change; gate=late-block ;;
      eval-block) fp=change-once; gate=late-block ;;
      newer-generation) fp=change-once; gate=newer-generation; expected=success ;;
      churn) fp=churn ;;
      config) gate=config ;;
      archive-failed) archive=failure ;;
      patch-failed) patch=fail ;;
    esac
    if [ "$producer" = event ]; then
      if run_event "$dir" FP_MODE="$fp" GATE_MODE="$gate" ARCHIVE_RESULT="$archive" PATCH_MODE="$patch"; then rc=0; else rc=$?; fi
      lease="lease-41"
    else
      # Scheduled relay preparation failures are already covered above.
      [ "$scenario" != archive-failed ] || continue
      rc=$(GATE_MODE="$gate" PATCH_MODE="$patch" run_sweep "$dir" stable "$fp")
      lease="lease-1"
    fi
    if [ "$scenario" = newer-generation ] && grep -q '^close newer-lease-' "$dir/mutations.log"; then
      fail "$producer cannot close a competing generation"
    elif [ "$scenario" = patch-failed ]; then
      if [ "$rc" -ne 0 ] && ! grep -q '^close ' "$dir/mutations.log" && grep -Fq 'remains pending' "$dir/out"; then
        pass "$producer exhausted publication reserve stays pending and reports failure"
      else
        fail "$producer exhausted publication reserve stays pending and reports failure" "rc=$rc"
      fi
    elif ! grep -Fxq "close $lease $expected" "$dir/mutations.log"; then
      fail "$producer $scenario closes original lease as $expected" "rc=$rc"
    elif [ "$expected" = success ] && [ "$rc" -ne 0 ]; then
      fail "$producer recovery also clears its native execution" "rc=$rc"
    elif [ "$producer" = event ] && [ "$expected" = failure ] && [ "$rc" -eq 0 ]; then
      fail "$producer blocked lease also fails its native execution"
    elif [ "$scenario" = churn ] && { ! grep -Fq '3 snapshot attempts exhausted' "$dir/out" || grep -Fq 'config/usage error' "$dir/out"; }; then
      fail "$producer churn has actionable, distinct budget diagnostics"
    else
      pass "$producer $scenario returns native rc=$rc and closes original lease as $expected"
    fi
  done
done

# A trusted old default branch may lack the newly introduced driver; once its
# own workflow references it, absence/non-executable is an installation error.
for state in pre-reference installed-missing installed-nonexec; do
  dir="$TMP/driver-skew-$state"
  make_sweep_fixture "$dir"
  if [ "$state" = installed-nonexec ]; then
    chmod -x "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
  else
    rm "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
  fi
  if [ "$state" != pre-reference ]; then
    echo 'run: scripts/workflow/codex-p1-snapshot-retry.py' > "$dir/.github/workflows/codex-p1-gate.yml"
  fi
  if run_event "$dir"; then rc=0; else rc=$?; fi
  if [ "$state" = pre-reference ] && [ "$rc" -eq 0 ] && grep -Fxq 'close lease-41 success' "$dir/mutations.log"; then
    pass 'first delivery retains fenced native evaluation on pre-reference main'
  elif [ "$state" != pre-reference ] && [ "$rc" -ne 0 ] && ! [ -e "$dir/gate.log" ]; then
    pass "$state driver fails before gate evaluation"
  else
    fail "$state driver skew control" "rc=$rc"
  fi
done


# Exercise the unchanged REAL fingerprint over edited/deleted/review/archive
# bodies and consumed GHAS severity. Only transport + the gate verdict is faked;
# accounting's real finding/disposition semantics have their own existing suite.
for surface in inline-edit review-edit deletion-archive severity malformed; do
  dir="$TMP/real-fingerprint-$surface"
  make_sweep_fixture "$dir"
  cp "$ROOT/scripts/review-feedback-surface-fingerprint.sh" "$dir/scripts/"
  cp -R "$ROOT/scripts/lib" "$dir/scripts/"
  echo 'code_scanning: {bot_login: "github-advanced-security[bot]"}' > "$dir/.github/review-policy.yml"
  mv "$dir/bin/gh" "$dir/bin/transport"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
endpoint=""
for arg in "$@"; do
  case "$arg" in repos/*) endpoint="$arg" ;; esac
done
case "$endpoint" in
  repos/owner/repo/pulls/41/comments)
    count_file="$FIXTURE_LOG/fingerprint-41.count"
    count=0; [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1)); echo "$count" > "$count_file"
    if [ "$REAL_SURFACE" = malformed ] && [ "$count" -gt 1 ]; then echo '{'; exit 0; fi
    body=before
    [ "$count" -eq 1 ] || body='P1 edited finding'
    case "$REAL_SURFACE" in
      inline-edit) jq -cn --arg body "$body" '[{id:1,user:{login:"coderabbitai[bot]"},body:$body}]' ;;
      deletion-archive)
        if [ "$count" -eq 1 ]; then echo '[{"id":1,"user":{"login":"coderabbitai[bot]"},"body":"P1 original"}]'; else echo '[]'; fi ;;
      severity) echo '[{"id":1,"user":{"login":"github-advanced-security[bot]"},"body":"https://github.com/owner/repo/security/code-scanning/7"}]' ;;
      *) echo '[]' ;;
    esac
    exit 0 ;;
  repos/owner/repo/pulls/41/reviews)
    if [ "$REAL_SURFACE" = review-edit ]; then
      count=$(cat "$FIXTURE_LOG/fingerprint-41.count")
      jq -cn --arg body "review-$((count > 1))" '[{id:2,user:{login:"chatgpt-codex-connector[bot]"},body:$body}]'
    else echo '[]'; fi
    exit 0 ;;
  repos/owner/repo/issues/41/comments)
    if [ "$REAL_SURFACE" = deletion-archive ] && [ "$(cat "$FIXTURE_LOG/fingerprint-41.count")" -gt 1 ]; then
      echo '[{"id":3,"user":{"login":"github-actions[bot]"},"body":"archived original finding"}]'
    else echo '[]'; fi
    exit 0 ;;
  repos/owner/repo/code-scanning/alerts/7)
    if [ "$(cat "$FIXTURE_LOG/fingerprint-41.count")" -eq 1 ]; then echo low; else echo high; fi
    exit 0 ;;
esac
exec "$FIXTURE_LOG/bin/transport" "$@"
SH
  chmod +x "$dir/bin/gh"
  if run_event "$dir" GH_TOKEN=fixture REAL_SURFACE="$surface" GATE_MODE=late-block; then rc=0; else rc=$?; fi
  expected_rc=1; [ "$surface" != malformed ] || expected_rc=2
  if [ "$rc" -eq "$expected_rc" ] && grep -Fxq 'close lease-41 failure' "$dir/mutations.log"; then
    pass "real fingerprint $surface cannot clear a stale native verdict"
  else
    fail "real fingerprint $surface cannot clear a stale native verdict" "rc=$rc: $(tail -3 "$dir/out")"
  fi
done

# Arm a real communicate timeout after bounded descendant readiness. A slow
# launcher must not spend that interval before the child can advertise itself.
# Check the driver's shared timeout before shortening the real wait. Its clock
# calculation, kill handler and failure lease stay intact in the source copy.
dir="$TMP/deadline"
make_sweep_fixture "$dir"
mv "$dir/scripts/workflow/codex-p1-snapshot-retry.py" "$dir/scripts/workflow/deadline-driver.py"
cat > "$dir/scripts/workflow/codex-p1-snapshot-retry.py" <<'PYTHON'
#!/usr/bin/env python3
from pathlib import Path
import os, runpy, signal, subprocess, time

root = Path(os.environ['FIXTURE_LOG'])
original_popen = subprocess.Popen
original_monotonic = time.monotonic
clock_started = False

def clock():
    global clock_started
    if not clock_started:
        clock_started = True
        return 0
    return 10

def popen(command, *args, **kwargs):
    process = original_popen(command, *args, **kwargs)
    if command[0] == 'scripts/codex-p1-gate.sh':
        original_communicate = process.communicate
        armed = False
        def communicate(input=None, timeout=None):
            nonlocal armed
            if not armed:
                # Production must pass its 180-second bound minus the ten
                # elapsed seconds from the controlled clock. A missing,
                # constant or miswired timeout must fail before we replace it.
                if timeout != 170:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=2)
                    raise AssertionError(f'production shared timeout is {timeout!r}, expected170')
                (root / 'production-timeout.log').write_text('remaining=170\n')
                ready_end = original_monotonic() + 10
                while not (root / 'deadline-descendant.pid').exists():
                    if process.poll() is not None:
                        raise RuntimeError('evaluator exited before descendant readiness')
                    if original_monotonic() >= ready_end:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=2)
                        raise RuntimeError('descendant readiness exceeded ten seconds')
                    time.sleep(0.02)
                (root / 'readiness-observation.log').write_text('ready before timeout armed\n')
                armed = True
                timeout = 1
            return original_communicate(input=input, timeout=timeout)
        process.communicate = communicate
    return process

subprocess.Popen = popen
time.monotonic = clock
runpy.run_path(str(Path(__file__).with_name('deadline-driver.py')), run_name='__main__')
PYTHON
chmod +x "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
cat > "$dir/scripts/codex-p1-gate.sh" <<'SH'
#!/usr/bin/env bash
# Deliberately exceed the old fixture's entire one-second deadline.
sleep 1.5
# Closed stdio lets a leader-only kill return without waiting for this child.
# The child stays in the evaluator's group and advertises readiness first.
python3 - "$FIXTURE_LOG" <<'PYTHON' >/dev/null 2>&1 &
from pathlib import Path
import os, sys, time
root = Path(sys.argv[1])
pending_pid = root / 'deadline-descendant.pid.pending'
pending_pid.write_text(str(os.getpid()))
pending_pid.replace(root / 'deadline-descendant.pid')
end = time.monotonic() + 20
while not (root / 'release-descendant').exists() and time.monotonic() < end:
    time.sleep(0.02)
# A survivor acknowledges release, or its own bounded escape timeout.
(root / 'escaped-deadline').touch()
PYTHON
wait
SH
if run_event "$dir"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 3 ] && grep -Fxq 'close lease-41 failure' "$dir/mutations.log" \
   && [ -s "$dir/deadline-descendant.pid" ] \
   && grep -Fxq 'remaining=170' "$dir/production-timeout.log" \
   && grep -Fxq 'ready before timeout armed' "$dir/readiness-observation.log"; then
  pass 'shared deadline kills evaluation and reserves fail-closed lease closure'
else
  fail 'shared deadline kills evaluation and reserves fail-closed lease closure' "rc=$rc"
fi
if python3 - "$dir" >"$dir/descendant-observation.log" 2>&1 <<'PYTHON'
from pathlib import Path
import subprocess, sys, time
root = Path(sys.argv[1])
pid = int((root / 'deadline-descendant.pid').read_text())
assert pid > 1, 'invalid descendant identity'
(root / 'release-descendant').touch()
end = time.monotonic() + 5
while True:
    assert not (root / 'escaped-deadline').exists(), 'descendant escaped process-group termination'
    state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                           capture_output=True, text=True, timeout=1)
    status = state.stdout.strip()
    absent = state.returncode == 1 and not status and not state.stderr.strip()
    zombie = state.returncode == 0 and status.startswith('Z')
    if absent or zombie:
        # Recheck after observing death: an exited survivor may have just acked.
        assert not (root / 'escaped-deadline').exists(), 'exited descendant acknowledged escape'
        print(f'descendant {pid} terminated; release cannot resume it')
        break
    assert state.returncode == 0 and status, f'unreadable descendant status: {state}'
    assert time.monotonic() < end, f'descendant {pid} remained live after release'
    time.sleep(0.02)
PYTHON
then
  pass 'deadline descendant death is observed before asserting no escape'
else
  fail 'deadline descendant death is observed before asserting no escape' "$(cat "$dir/descendant-observation.log")"
fi

# Real transaction ceiling: force more than 200 commands from one evaluator.
dir="$TMP/api-budget"
make_sweep_fixture "$dir"
cat > "$dir/scripts/codex-p1-gate.sh" <<'SH'
#!/usr/bin/env bash
set -e
for ((i=0; i<210; i++)); do gh api repos/owner/repo/pulls/41 --jq .head.sha >/dev/null; done
SH
if run_event "$dir"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 3 ] && grep -Fq '200 GitHub API-command budget reached' "$dir/out" && grep -Fxq 'close lease-41 failure' "$dir/mutations.log"; then
  pass 'nested transport command budget closes lease without clearing a stale result'
else
  fail 'nested transport command budget closes lease without clearing a stale result' "rc=$rc"
fi

if [ -e "$TMP/deadline/escaped-deadline" ]; then
  fail 'timed-out evaluator descendants cannot resume after lease failure'
else
  pass 'timed-out evaluator descendants cannot resume after lease failure'
fi

# Exercise launcher failures and timeout/exit races at the actual driver boundary.
# The wrapper injects process API failures; the checked-in driver and workflow
# still own verdict classification, retry count, lease choice and native status.
for producer in event scheduled; do
  for fault in launch-once launch-always close-race evaluation-race unexpected clear blocked; do
    dir="$TMP/$producer-publisher-$fault"
    make_sweep_fixture "$dir"
    mv "$dir/scripts/workflow/codex-p1-snapshot-retry.py" "$dir/scripts/workflow/driver-under-test.py"
    printf '%s' "$fault" > "$dir/fault"
    cat > "$dir/scripts/workflow/codex-p1-snapshot-retry.py" <<'PYTHON'
#!/usr/bin/env python3
from pathlib import Path
import os
import runpy
import subprocess
import tempfile

root = Path(os.environ['FIXTURE_LOG'])
fault = (root / 'fault').read_text()
original_popen = subprocess.Popen
original_killpg = os.killpg
attempts = 0
race_pid = 99999999

class ExitedProcess:
    pid = race_pid
    returncode = 0
    calls = 0

    def wait(self, timeout=None):
        self.calls += 1
        if self.calls == 1:
            raise subprocess.TimeoutExpired('publisher', timeout)
        return 0

    def communicate(self, timeout=None):
        self.calls += 1
        if self.calls == 1:
            raise subprocess.TimeoutExpired('evaluator', timeout)
        return '', ''

def popen(command, *args, **kwargs):
    global attempts
    if '-X' in command and 'PATCH' in command:
        attempts += 1
        with (root / 'launch.log').open('a') as log:
            log.write(f'{attempts} {command[4]}\n')
        if fault == 'launch-always' or (fault == 'launch-once' and attempts == 1):
            raise OSError('fixture publisher launch failed')
        if fault == 'close-race' and attempts == 1:
            return ExitedProcess()
    elif fault == 'evaluation-race' and command[0] == 'scripts/codex-p1-gate.sh':
        return ExitedProcess()
    return original_popen(command, *args, **kwargs)

def killpg(pid, sig):
    if pid == race_pid:
        raise ProcessLookupError('fixture process exited before killpg')
    return original_killpg(pid, sig)

def unexpected(*args, **kwargs):
    raise RuntimeError('fixture unexpected setup error')

subprocess.Popen = popen
os.killpg = killpg
if fault == 'unexpected':
    tempfile.TemporaryDirectory = unexpected
runpy.run_path(str(Path(__file__).with_name('driver-under-test.py')), run_name='__main__')
PYTHON
    chmod +x "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
    gate=clear
    [ "$fault" != blocked ] || gate=block
    if [ "$producer" = event ]; then
      if run_event "$dir" GATE_MODE="$gate"; then rc=0; else rc=$?; fi
      lease="lease-41"
      expected_rc=2
      [ "$fault" != clear ] || expected_rc=0
      [ "$fault" != blocked ] || expected_rc=1
      [ "$fault" != evaluation-race ] || expected_rc=3
      expected_launches=2
      [ "$fault" != launch-always ] || expected_launches=3
    else
      rc=$(GATE_MODE="$gate" run_sweep "$dir" stable stable)
      lease="lease-1"
      expected_rc=1
      case "$fault" in clear|blocked) expected_rc=0 ;; esac
      expected_launches=4
      [ "$fault" != launch-always ] || expected_launches=6
    fi
    conclusion=failure
    [ "$fault" != clear ] || conclusion=success
    if [ "$rc" -ne "$expected_rc" ]; then
      fail "$producer $fault keeps honest native status" "rc=$rc expected=$expected_rc"
    elif [ "$fault" = launch-always ] || [ "$fault" = unexpected ]; then
      if grep -q '^close ' "$dir/mutations.log" 2>/dev/null \
        || ! grep -Eq 'Could not close check lease|lease closure is unconfirmed' "$dir/out"; then
        fail "$producer $fault reports unconfirmed closure without a fabricated close"
      elif [ "$fault" = launch-always ] && [ "$(wc -l < "$dir/launch.log" | tr -d ' ')" -ne "$expected_launches" ]; then
        fail "$producer $fault spends only the bounded closing reserve"
      else
        pass "$producer $fault remains infrastructure failure with honest unclosed lease"
      fi
    elif ! grep -Fxq "close $lease $conclusion" "$dir/mutations.log" \
      || { [ "$fault" != clear ] && grep -q '^close .* success$' "$dir/mutations.log"; }; then
      fail "$producer $fault publishes only the permitted original-lease conclusion"
    elif { [ "$fault" = launch-once ] || [ "$fault" = close-race ]; } \
      && [ "$(wc -l < "$dir/launch.log" | tr -d ' ')" -ne "$expected_launches" ]; then
      fail "$producer $fault uses one failure-only retry after the failed launch"
    else
      pass "$producer $fault preserves native status and original-lease closure"
    fi
  done
done

# First delivery uses the old trusted gate, whose ordinary nonzero verdict
# must be captured even with the Actions default bash -e invocation.
for driver_state in missing nonexec; do
  for verdict in clear block config; do
    dir="$TMP/bootstrap-$driver_state-$verdict"
    make_sweep_fixture "$dir"
    if [ "$driver_state" = missing ]; then
      rm "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
    else
      chmod -x "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
    fi
    # Positive trusted-workflow reference absence is the bootstrap authority.
    echo 'run: scripts/codex-p1-gate.sh' > "$dir/.github/workflows/codex-p1-gate.yml"
    if run_event "$dir" GATE_MODE="$verdict"; then rc=0; else rc=$?; fi
    expected_rc=0
    conclusion=success
    case "$verdict" in
      block) expected_rc=1; conclusion=failure ;;
      config) expected_rc=2; conclusion=failure ;;
    esac
    if [ "$rc" -eq "$expected_rc" ] \
      && grep -Fxq "close lease-41 $conclusion" "$dir/mutations.log" \
      && grep -Fq 'using the legacy fenced evaluation' "$dir/out"; then
      pass "Actions shell bootstrap $driver_state $verdict closes its original lease"
    else
      fail "Actions shell bootstrap $driver_state $verdict closes its original lease" "rc=$rc expected=$expected_rc"
    fi
  done
done

# Installed scheduled helpers share the workflow revision. Both unavailable
# driver shapes must reach the existing per-PR failure publisher before eval.
for driver_state in missing nonexec; do
  dir="$TMP/scheduled-driver-$driver_state"
  make_sweep_fixture "$dir"
  if [ "$driver_state" = missing ]; then
    rm "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
  else
    chmod -x "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
  fi
  rc=$(run_sweep "$dir" stable stable)
  if [ "$rc" -ne 1 ] || [ -e "$dir/gate.log" ] \
    || ! grep -Fq 'Installed feedback snapshot retry driver is missing or not executable' "$dir/out"; then
    fail "Actions shell scheduled $driver_state driver reports infrastructure failure" "rc=$rc"
  elif ! grep -Fxq 'open 1 lease-1' "$dir/mutations.log" \
    || ! grep -Fxq 'close lease-1 failure' "$dir/mutations.log" \
    || ! grep -Fxq 'open 2 lease-2' "$dir/mutations.log" \
    || ! grep -Fxq 'close lease-2 failure' "$dir/mutations.log" \
    || grep -q '^close .* success$' "$dir/mutations.log"; then
    fail "Actions shell scheduled $driver_state driver closes each readable original lease"
  else
    pass "Actions shell scheduled $driver_state driver fails each original lease and processes later PRs"
  fi
done

# The lease title names which question failed (#2536). The check keeps the
# historical "Codex P1" name, but a feedback-accounting red can be another
# provider's undispositioned finding, so its title must not send the author
# looking for a Codex P1 thread. Drive the shipped driver directly.
for verdict in accounting legacy clear; do
  dir="$TMP/title-$verdict"
  mkdir -p "$dir/scripts/workflow" "$dir/bin"
  cp "${CODEX_P1_SNAPSHOT_DRIVER:-$ROOT/scripts/workflow/codex-p1-snapshot-retry.py}" \
    "$dir/scripts/workflow/codex-p1-snapshot-retry.py"
  printf '%s\n' '#!/usr/bin/env bash' 'echo fp-stable' \
    > "$dir/scripts/review-feedback-surface-fingerprint.sh"
  cat > "$dir/scripts/codex-p1-gate.sh" <<'SH'
#!/usr/bin/env bash
case "$TITLE_VERDICT" in
  accounting)
    echo 'posted=2 accounted=1'
    echo '[codex-p1-gate] ERROR: review feedback is unaccounted; disposition every finding before merge' >&2
    exit 1 ;;
  legacy) echo 'Codex blocking-tier unresolved: 1'; exit 1 ;;
  *) echo 'Codex blocking-tier unresolved: 0' ;;
esac
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = -X ] && [ "${3:-}" = PATCH ]; then
  previous=""
  for arg in "$@"; do
    if [ "$previous" = -f ] && [[ "$arg" == 'output[title]='* ]]; then
      printf '%s\n' "${arg#*=}" > "$FIXTURE_LOG/title.log"
    fi
    previous="$arg"
  done
  exit 0
fi
echo head-41
SH
  chmod +x "$dir/scripts/workflow/codex-p1-snapshot-retry.py" \
    "$dir/scripts/review-feedback-surface-fingerprint.sh" "$dir/scripts/codex-p1-gate.sh" "$dir/bin/gh"
  rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" FIXTURE_LOG="$dir" TITLE_VERDICT="$verdict" \
      scripts/workflow/codex-p1-snapshot-retry.py 41 owner/repo head-41 lease-41 fingerprint
  ) >"$dir/out" 2>&1 || rc=$?
  title=$(cat "$dir/title.log" 2>/dev/null || true)
  case "$verdict" in
    accounting) want_rc=1 want='Review feedback unaccounted: run scripts/review-feedback-accounting.sh <PR#>' ;;
    legacy) want_rc=1 want='Codex blocking-tier review threads unresolved on the current head' ;;
    clear) want_rc=0 want='Codex feedback gate (leased re-evaluation)' ;;
  esac
  if [ "$rc" -ne "$want_rc" ] || [ "$title" != "$want" ]; then
    fail "driver titles a $verdict verdict by what failed" "rc=$rc title=$title"
  else
    pass "driver titles a $verdict verdict by what failed"
  fi
done

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
