#!/usr/bin/env bash
# Executes the checked-in workflow shell against hermetic GitHub API fixtures.
# The workflow steps are extracted by name, so these controls exercise the
# shipped bootstrap guard and scheduled multi-PR loop rather than a copy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${CODEX_P1_WORKFLOW:-$ROOT/.github/workflows/codex-p1-gate.yml}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-p1-workflow-runtime.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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
extract_step "codex-p1-gate" "Run scripts/codex-p1-gate.sh" "$EVENT_STEP"
extract_step "scheduled-sweep" "Re-evaluate gate per PR and post check_run" "$SWEEP_STEP"

make_common_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/.github/workflows" "$dir/bin" "$dir/runner"
  cat > "$dir/scripts/codex-p1-gate.sh" <<'SH'
#!/usr/bin/env bash
printf 'gate %s\n' "$1" >> "$FIXTURE_LOG/gate.log"
echo "gate clear for PR #$1"
SH
  chmod +x "$dir/scripts/codex-p1-gate.sh"
}

run_event() {
  local dir="$1"
  shift
  (
    cd "$dir"
    env FIXTURE_LOG="$dir" PR_NUMBER=41 REPO=owner/repo \
      EXPECTED_HEAD_SHA=head-41 GITHUB_OUTPUT="$dir/github-output" \
      RUNNER_TEMP="$dir/runner" "$@" bash "$EVENT_STEP"
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
elif [ "$(grep -Fc 'fingerprint 41' "$dir/fingerprint.log")" -ne 2 ]; then
  fail "installed event helper fences the gate" "expected pre/post fingerprint reads"
elif ! grep -Fxq 'fingerprint_available=true' "$dir/github-output" \
  || ! grep -Fxq 'feedback_fp=stable-fingerprint' "$dir/github-output"; then
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
echo "fp-$pr"
SH
  chmod +x "$dir/scripts/review-feedback-surface-fingerprint.sh"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FIXTURE_LOG/gh.log"
printf '\n' >> "$FIXTURE_LOG/gh.log"
[ "${1:-}" = api ] || exit 90

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
  previous=""
  for arg in "$@"; do
    if [ "$previous" = -f ] && [[ "$arg" == conclusion=* ]]; then
      conclusion="${arg#conclusion=}"
    fi
    previous="$arg"
  done
  lease="${endpoint##*/}"
  printf 'close %s %s\n' "$lease" "$conclusion" >> "$FIXTURE_LOG/mutations.log"
  exit 0
fi

endpoint="$2"
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
    jq -cn --arg sha "$sha" '{head:{sha:$sha,repo:{fork:false}},user:{login:"owner"},created_at:"2026-01-01T00:00:00Z"}'
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
      bash "$SWEEP_STEP"
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

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
