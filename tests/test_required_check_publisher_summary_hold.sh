#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"
# #2690: the CodeRabbit sweep, whose cr_surface_fp the publisher copies.
SWEEP_WORKFLOW="${CODERABBIT_SWEEP_WORKFLOW:-$ROOT/.github/workflows/coderabbit-severity-gate.yml}"

command -v ruby >/dev/null 2>&1 || { echo "ERROR: Ruby is required" >&2; exit 1; }
ruby -e 'require "yaml"' >/dev/null 2>&1 \
  || { echo "ERROR: Ruby YAML support is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 \
  || { echo "ERROR: Python 3 (python3) is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the actual live publish step, its gate() helper, and its three caller
# lines. The test supplies only fake gate executables and API responses; it does
# not reproduce the caller's flag or branching on the test side.
ruby - "$WORKFLOW" "$TMP/publish.sh" <<'RUBY'
require "yaml"
workflow = YAML.load_file(ARGV[0])
steps = workflow.fetch("jobs").fetch("publish").fetch("steps")
matches = steps.select { |step| step["name"] == "Resolve targets, evaluate gates, publish" }
abort("could not extract the publisher publish step") unless matches.length == 1 && matches[0]["run"].is_a?(String)
File.write(ARGV[1], matches[0]["run"])
RUBY

# #2689: gate() runs the Codex P1 context through codex_p1_evaluate, and
# #2690 the CodeRabbit context through coderabbit_evaluate and its copy of the
# sweep's cr_surface_fp, so all four shipped functions are extracted.
awk '
  /^(gate|codex_p1_evaluate|cr_surface_fp|coderabbit_evaluate)\(\) \{$/ { inside=1 }
  inside { print }
  inside && /^}$/ { inside=0 }
' "$TMP/publish.sh" >"$TMP/gate-helper.sh"
grep '^[[:space:]]*gate scripts/' "$TMP/publish.sh" >"$TMP/gate-calls.sh" || true
if ! grep -q '^gate() {$' "$TMP/gate-helper.sh" \
    || ! grep -q '^codex_p1_evaluate() {$' "$TMP/gate-helper.sh" \
    || ! grep -q '^cr_surface_fp() {$' "$TMP/gate-helper.sh" \
    || ! grep -q '^coderabbit_evaluate() {$' "$TMP/gate-helper.sh" \
    || [ "$(wc -l <"$TMP/gate-calls.sh" | tr -d ' ')" -ne 3 ]; then
  echo "FAIL: could not extract the gate helpers and their three live callers"
  exit 1
fi

MCG_CALL=$(grep 'merge-clearance-gate.sh' "$TMP/gate-calls.sh")
# The Codex P1 caller is found by its context, not by the script it names, so
# a caller that names another script still runs here and fails behaviorally.
CODEX_CALL=$(grep -F '"$CODEX_P1_CONTEXT"' "$TMP/gate-calls.sh")
CR_CALL=$(grep 'coderabbit-severity-gate.sh' "$TMP/gate-calls.sh")
[ -n "$MCG_CALL" ] && [ -n "$CODEX_CALL" ] && [ -n "$CR_CALL" ] \
  || { echo "FAIL: required live gate caller line missing"; exit 1; }

mkdir -p "$TMP/scripts"
cat >"$TMP/scripts/fake-gate" <<'SH'
#!/usr/bin/env bash
name=$(basename "$0")
case "$name" in
  merge-clearance-gate.sh)
    rc=$MCG_RC
    [ "$rc" -ne 0 ] || echo "Merge clearance: PASS"
    # #2247: a not-yet-cleared head. The real script writes the pending
    # verdict only when the caller names a file, and exits 1 either way.
    if [ "${MCG_PENDING:-0}" = 1 ]; then
      printf '%s\n' "${MERGEPATH_GATE_VERDICT_FILE-unset}" >>"$GATE_VERDICT_LOG"
      [ -z "${MERGEPATH_GATE_VERDICT_FILE:-}" ] \
        || printf 'pending\n' >"$MERGEPATH_GATE_VERDICT_FILE"
      echo "Merge clearance: BLOCKED — external review is NOT cleared"
    fi
    ;;
  codex-p1-gate.sh) rc=$CODEX_RC ;;
  coderabbit-severity-gate.sh)
    rc=$CR_RC
    # #2690: what the real gate is told about the surface fingerprint, and
    # what it does with it: an evidence failure holds (rc 3) a run that would
    # otherwise clear. CR_TOUCH names a surface this run changes, the way a
    # review or acknowledgement lands while the gate runs. CR_ESCALATE writes
    # the evidence report an escalating hold writes. The marker in the call
    # log orders the fingerprint reads around the evaluation.
    printf '%s\n' "${CR_EVIDENCE_FAILURE:-none}" >>"$CR_EVIDENCE_LOG"
    printf 'GATE coderabbit-severity-gate.sh\n' >>"$GH_CALL_LOG"
    : >"$SURFACE/gate-ran"
    [ -z "${CR_EVIDENCE_FAILURE:-}" ] || [ "$rc" -ne 0 ] || rc=3
    [ -z "${CR_TOUCH:-}" ] || printf 'moved\n' >>"$SURFACE/$CR_TOUCH"
    [ -z "${CR_OUTPUT:-}" ] || printf '%s\n' "$CR_OUTPUT" >&2
    [ "${CR_ESCALATE:-0}" = 0 ] \
      || printf '{"repo":"example/repo","pr":7,"head":"abc123","state":"escalate"}\n' >"$CR_EVIDENCE_REPORT"
    ;;
  *) echo "unknown fake gate: $name" >&2; exit 9 ;;
esac
printf '%s\t%s\n' "$name" "${REQUIRE_REVIEW_SUMMARY-unset}" >>"$GATE_ENV_LOG"
echo "fixture $name rc=$rc"
exit "$rc"
SH
chmod +x "$TMP/scripts/fake-gate"
for script in merge-clearance-gate.sh codex-p1-gate.sh coderabbit-severity-gate.sh; do
  ln -s fake-gate "$TMP/scripts/$script"
done

# #2689: the Codex P1 path's three collaborators. The driver double records
# its arguments, whether it was asked for a report, and the summary flag; it
# reports CODEX_RC unless DRIVER_NO_REPORT=1. The relay double exits RELAY_RC.
mkdir -p "$TMP/scripts/workflow"
cat >"$TMP/scripts/workflow/codex-p1-snapshot-retry.py" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$*" "${CODEX_P1_VERDICT_REPORT:+report}" "${REQUIRE_REVIEW_SUMMARY-unset}" >>"$DRIVER_LOG"
echo "fixture driver rc=$CODEX_RC"
if [ -n "${CODEX_P1_VERDICT_REPORT:-}" ] && [ "${DRIVER_NO_REPORT:-0}" != 1 ]; then
  printf '{"rc":%s,"title":"fixture driver verdict rc=%s"}\n' "$CODEX_RC" "$CODEX_RC" >"$CODEX_P1_VERDICT_REPORT"
fi
exit "$CODEX_RC"
SH
cat >"$TMP/scripts/workflow/codex-p1-relay-pending.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RELAY_LOG"
echo "fixture relay rc=$RELAY_RC"
exit "$RELAY_RC"
SH
printf '#!/bin/sh\necho fixture-fingerprint\n' >"$TMP/scripts/review-feedback-surface-fingerprint.sh"
chmod +x "$TMP/scripts/workflow/codex-p1-snapshot-retry.py" "$TMP/scripts/workflow/codex-p1-relay-pending.sh" \
  "$TMP/scripts/review-feedback-surface-fingerprint.sh"

# #2690: the four CodeRabbit surfaces the fingerprint reads, one file each,
# printed as the read's (already projected) value. FP_FAIL=<surface>:<when>
# fails that surface's read before the gate runs (pre), after it (post) or
# both, the way an unreadable endpoint does.
SURFACE="$TMP/surface"
mkdir -p "$SURFACE"
cat >"$TMP/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
surface_read() {  # <surface>
  local when=pre
  [ ! -e "$SURFACE/gate-ran" ] || when=post
  case "${FP_FAIL:-}" in
    "$1:$when"|"$1:both") echo "${FP_FAIL_MESSAGE:-HTTP 502: Bad Gateway (fixture $1 read)}" >&2; exit 1 ;;
  esac
  cat "$SURFACE/$1"
  exit 0
}
case "$*" in
  *"repos/example/repo/issues/7/comments --paginate"*) surface_read comments ;;
  *"repos/example/repo/pulls/7/reviews --paginate"*) surface_read reviews ;;
  *"repos/example/repo/pulls/7/comments --paginate"*) surface_read inline ;;
  "api graphql --paginate "*"pr=7 "*) surface_read threads ;;
  *"-X POST"*"/check-runs"*)
    [ "${OPEN_FAIL:-0}" = 0 ] || exit 1
    printf '{}\n' ;;
  *"-X PATCH"*"/check-runs/"*)
    [ "${CLOSE_FAIL:-0}" = 0 ] || exit 1
    printf '{}\n' ;;
  *"/commits/"*"/check-runs"*)
    # FRESH_FAILS_FILE holds how many freshness lookups still fail (a
    # simulated transient 502) before the endpoint answers normally.
    if [ -n "${FRESH_FAILS_FILE:-}" ] && [ -s "$FRESH_FAILS_FILE" ]; then
      left=$(cat "$FRESH_FAILS_FILE")
      if [ "$left" -gt 0 ]; then
        printf '%s\n' $((left - 1)) >"$FRESH_FAILS_FILE"
        echo "HTTP 502: Bad Gateway" >&2
        exit 1
      fi
    fi
    exit 0
    ;;
  *"/pulls/"*" --jq .head.sha"*) printf '%s\n' abc123 ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$TMP/gh"
# The freshness retry backs off between attempts; record instead of waiting.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$TMP_SLEEP_LOG"\n' >"$TMP/sleep"
chmod +x "$TMP/sleep"
export TMP_SLEEP_LOG="$TMP/sleep-log"

# The real workflow declares no job- or step-wide summary flag. Clear a
# developer's ambient export so only the extracted CodeRabbit caller can set it.
unset REQUIRE_REVIEW_SUMMARY

# shellcheck disable=SC1090,SC1091
. "$TMP/gate-helper.sh"
# The #2220 rate-limit reader gate() calls, the real one. No reset is read from
# the fake gh, so the back-off title keeps the pass-start reset set here.
# shellcheck source=scripts/workflow/installation-budget.sh
. "$ROOT/scripts/workflow/installation-budget.sh"
RATE_LIMIT_MARK="$IB_RATE_LIMIT_MARK" RATE_LIMIT_RESET_ISO=2026-09-25T01:00:00Z RATE_LIMITED=0 CLAIMED_HEADS=""
export PATH="$TMP:$PATH"
export REPO=example/repo PASS_START=2026-09-25T00:00:00Z OWN_PENDING_IDS="" OWN_GENERATIONS=""
# Gate-mapping boundary doubles. The production generation binding, interleave
# and reader contract run independently in test_required_check_generations.py.
rcg_open() {
  gh api -X POST "repos/$1/check-runs" -f name="$4" -f head_sha="$3" -f status=in_progress >/dev/null || return 1
  printf '17\n'
}
rcg_close() {
  gh api -X PATCH "repos/$1/check-runs/$5" -f status=completed -f conclusion="$6" \
    -f "output[title]=$7" -f "output[summary]=$8" >/dev/null
}
export GATE_ENV_LOG="$TMP/gate-env" GH_CALL_LOG="$TMP/gh-calls"
export SURFACE CR_EVIDENCE_LOG="$TMP/cr-evidence"
export GATE_VERDICT_LOG="$TMP/gate-verdict"
# The real workflow never names a verdict file; clear an ambient export so the
# pending case below proves the publisher does not ask for one.
unset MERGEPATH_GATE_VERDICT_FILE
export PR=7 head_sha=abc123
export MCG_CONTEXT="Merge clearance gate"
export CODEX_P1_CONTEXT="Codex P1 unresolved threads"
export CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings"
export MCG_RC=0 CODEX_RC=0 CR_RC=0 RELAY_RC=0
export DRIVER_LOG="$TMP/driver-log" RELAY_LOG="$TMP/relay-log"
unset CODEX_P1_VERDICT_REPORT DRIVER_NO_REPORT FP_FAIL FP_FAIL_MESSAGE CR_TOUCH CR_ESCALATE CR_OUTPUT CR_EVIDENCE_FAILURE

run_call() {
  local call="$1" previous="$PWD"
  cd "$TMP"
  eval "$call"
  cd "$previous"
}

reset_case() {
  : >"$GATE_ENV_LOG"
  : >"$GH_CALL_LOG"
  : >"$DRIVER_LOG"
  : >"$RELAY_LOG"
  : >"$CR_EVIDENCE_LOG"
  rm -f "$SURFACE/gate-ran"
  for s in comments reviews inline threads; do printf '%s-v1\n' "$s" >"$SURFACE/$s"; done
  had_infra_error=0
  EVIDENCE_ESCALATIONS=""
  RATE_LIMITED=0
}

one_post() {
  [ "$(grep -c -- '-X POST .*check-runs' "$GH_CALL_LOG" || true)" -eq 1 ] \
    && [ "$(grep -c -- '-X PATCH .*check-runs/' "$GH_CALL_LOG" || true)" -eq 1 ]
}

pass=0
fail=0
record() {
  local description="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $description"
    pass=$((pass + 1))
  else
    echo "FAIL: $description"
    fail=$((fail + 1))
  fi
}

reset_case
CR_RC=0; export CR_RC
run_call "$CR_CALL" >"$TMP/cr0.out"
set +e
grep -qx $'coderabbit-severity-gate.sh\ttrue' "$GATE_ENV_LOG" \
  && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "no current unknown run / recognized clean result publishes success" "$case_rc"

reset_case
CR_RC=1; export CR_RC
run_call "$CR_CALL" >"$TMP/cr1.out"
set +e
grep -qx $'coderabbit-severity-gate.sh\ttrue' "$GATE_ENV_LOG" \
  && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "recognized CodeRabbit finding publishes failure" "$case_rc"

reset_case
CR_RC=2; export CR_RC
run_call "$CR_CALL" >"$TMP/cr2.out"
set +e
grep -qx $'coderabbit-severity-gate.sh\ttrue' "$GATE_ENV_LOG" \
  && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "CodeRabbit config/infra error remains a red publication" "$case_rc"

reset_case
CR_RC=3; export CR_RC
run_call "$CR_CALL" >"$TMP/cr3.out"
set +e
grep -qx $'coderabbit-severity-gate.sh\ttrue' "$GATE_ENV_LOG" \
  && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "unknown current-head CodeRabbit run closes its owned generation red" "$case_rc"

# #2690: the CodeRabbit evaluation is bracketed by the scheduled sweep's
# pre/post surface fingerprint (coderabbit-severity-gate.yml). surface_order
# prints the calls this case made to the four surfaces and the gate, in order.
surface_order() {
  sed -n -e 's#^api repos/example/repo/issues/7/comments .*#comments#p' \
    -e 's#^api repos/example/repo/pulls/7/reviews .*#reviews#p' \
    -e 's#^api repos/example/repo/pulls/7/comments .*#inline#p' \
    -e 's#^api graphql .*#threads#p' \
    -e 's#^GATE .*#GATE#p' "$GH_CALL_LOG" | tr '\n' ' ' | sed 's/ $//'
}
closed_title() {  # the title of the one PATCH this case made
  sed -n 's/.*-f output\[title\]=\(.*\) -f output\[summary\]=.*/\1/p' "$GH_CALL_LOG"
}

reset_case
CR_RC=0; export CR_RC
run_call "$CR_CALL" >"$TMP/cr-bracket.out"
set +e
[ "$(surface_order)" = "comments reviews inline threads GATE comments reviews inline threads" ] \
  && [ "$(cat "$CR_EVIDENCE_LOG")" = none ] && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "an unchanged CodeRabbit surface, read before and after the gate, publishes the gate's verdict" "$case_rc"

# A review, acknowledgement, inline finding or thread resolution that lands
# while the gate runs: the evaluation is not published over it. As in the
# sweep, the generation closes red as an infrastructure error and the
# evidence report is emptied, so no hold escalation is recorded.
for touched in comments reviews inline threads; do
  reset_case
  CR_RC=0 CR_TOUCH="$touched" CR_ESCALATE=1; export CR_RC CR_TOUCH CR_ESCALATE
  run_call "$CR_CALL" >"$TMP/cr-moved-$touched.out"
  set +e
  [ "$had_infra_error" -eq 1 ] && one_post \
    && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
    && ! grep -q -- '-f conclusion=success' "$GH_CALL_LOG" \
    && grep -q 'comment surface changed while the gate ran, or one of its two reads failed' "$GH_CALL_LOG" \
    && [ -z "$EVIDENCE_ESCALATIONS" ]
  case_rc=$?
  set -e
  record "a $touched change during the CodeRabbit evaluation closes the generation red, unpublished" "$case_rc"
done
unset CR_TOUCH CR_ESCALATE

# The change outranks the summary hold, as in the sweep: an rc 3 hold over a
# moved surface is the same infrastructure red, not an evidence hold. The
# unchanged hold escalates as before.
reset_case
CR_RC=3 CR_ESCALATE=1; export CR_RC CR_ESCALATE
run_call "$CR_CALL" >"$TMP/cr-hold-escalates.out"
set +e
[ "$had_infra_error" -eq 0 ] && one_post && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && [ "$(closed_title)" = "CodeRabbit unresolved blocking findings — evidence hold; explicit recovery required after escalation" ] \
  && [ "$EVIDENCE_ESCALATIONS" = " 7" ]
case_rc=$?
set -e
record "an unchanged surface keeps the summary hold and its escalation on the bracketed path" "$case_rc"
reset_case
CR_RC=3 CR_TOUCH=reviews; export CR_RC CR_TOUCH
run_call "$CR_CALL" >"$TMP/cr-hold-moved.out"
set +e
[ "$had_infra_error" -eq 1 ] && one_post && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && [ "$(closed_title)" = "CodeRabbit unresolved blocking findings — infra/config error (rc=2)" ]
case_rc=$?
set -e
record "a surface change outranks the summary hold" "$case_rc"
unset CR_TOUCH CR_ESCALATE

# Read failures follow the sweep (the #906 contract). A failed read before
# the gate is passed to it as an evidence failure; a clean rc 0 after a
# failed read is re-run that way; any failed read is an infrastructure red.
reset_case
CR_RC=0 FP_FAIL=reviews:pre; export CR_RC FP_FAIL
run_call "$CR_CALL" >"$TMP/cr-pre-fail.out" 2>&1
set +e
[ "$(cat "$CR_EVIDENCE_LOG")" = fingerprint-read-failed ] && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" && ! grep -q -- '-f conclusion=success' "$GH_CALL_LOG" \
  && grep -q 'HTTP 502: Bad Gateway (fixture reviews read)' "$GH_CALL_LOG"
case_rc=$?
set -e
record "a failed surface read before the gate is passed to it and closes the generation red" "$case_rc"

reset_case
CR_RC=0 FP_FAIL=inline:post; export CR_RC FP_FAIL
run_call "$CR_CALL" >"$TMP/cr-post-fail.out" 2>&1
set +e
[ "$(cat "$CR_EVIDENCE_LOG" | tr '\n' ' ')" = "none fingerprint-read-failed " ] \
  && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" && ! grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "a failed surface read after a clean gate re-runs it as an evidence failure and closes red" "$case_rc"

# Both reads failed: nothing to compare, so the gate's evidence hold is what
# is published, as an infrastructure error.
reset_case
CR_RC=0 FP_FAIL=threads:both; export CR_RC FP_FAIL
run_call "$CR_CALL" >"$TMP/cr-both-fail.out" 2>&1
set +e
[ "$(cat "$CR_EVIDENCE_LOG")" = fingerprint-read-failed ] && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && [ "$(closed_title)" = "CodeRabbit unresolved blocking findings — evidence hold; explicit recovery required after escalation" ]
case_rc=$?
set -e
record "both surface reads failed: the gate's evidence hold closes the generation red as an infra error" "$case_rc"
unset FP_FAIL

# An rc 3 hold whose output shows the installation rate limit is the #2220
# stop's back-off red, titled with the mark due() reads, like every other
# rate-limited exit: from both surface reads failing on the limit, or from
# the gate's own output. The pass stops, so a later unclaimed head is not
# evaluated. An rc 3 without that text stays the evidence hold (above).
rate_limited_hold_case() {  # <label> <expected had_infra_error>
  run_call "$CR_CALL" >"$TMP/cr-rate-limited-hold.out" 2>&1
  : >"$GH_CALL_LOG.after"
  GH_CALL_LOG="$GH_CALL_LOG.after" run_call "$MCG_CALL" >"$TMP/cr-after-stop.out" 2>&1
  set +e
  [ "$RATE_LIMITED" -eq 1 ] && [ "$had_infra_error" -eq "$2" ] && one_post \
    && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
    && [ "$(closed_title)" = "CodeRabbit unresolved blocking findings — installation API budget exhausted (rc=3); re-evaluated after 2026-09-25T01:00:00Z" ] \
    && [ ! -s "$GH_CALL_LOG.after" ]
  case_rc=$?
  set -e
  record "$1" "$case_rc"
}
reset_case
CR_RC=0 FP_FAIL=threads:both FP_FAIL_MESSAGE="gh: API rate limit already exceeded for installation ID 4242."
export CR_RC FP_FAIL FP_FAIL_MESSAGE
rate_limited_hold_case "both surface reads failed on the rate limit: the rc 3 hold publishes the back-off red and stops the pass" 1
unset FP_FAIL FP_FAIL_MESSAGE
reset_case
CR_RC=3 CR_OUTPUT="gh: API rate limit exceeded for installation ID 4242. (HTTP 403)"; export CR_RC CR_OUTPUT
rate_limited_hold_case "an rc 3 hold whose own output shows the rate limit publishes the back-off red as an infra error" 1
unset CR_OUTPUT
CR_RC=0; export CR_RC

# The gate's own infrastructure exit outranks both comparisons. The sweep
# reads the surface again and ignores it; the publisher does not read it.
reset_case
CR_RC=2 CR_TOUCH=comments; export CR_RC CR_TOUCH
run_call "$CR_CALL" >"$TMP/cr-gate-infra.out"
set +e
[ "$(surface_order)" = "comments reviews inline threads GATE" ] && [ "$had_infra_error" -eq 1 ] && one_post \
  && [ "$(closed_title)" = "CodeRabbit unresolved blocking findings — infra/config error (rc=2)" ] \
  && ! grep -q 'comment surface changed while the gate ran' "$GH_CALL_LOG"
case_rc=$?
set -e
record "the gate's own infra exit publishes red without a second surface read" "$case_rc"
unset CR_TOUCH
CR_RC=0; export CR_RC

# The publisher's cr_surface_fp is a copy of the sweep's. Compared line by
# line without leading whitespace, the two must be identical, so a change to
# what the sweep reads cannot leave the publisher reading less.
extract_fp() {  # <run script>: the function body, leading whitespace removed
  awk 'match($0, /^[[:space:]]*cr_surface_fp\(\) \{$/) { inside=1; indent=substr($0, 1, RLENGTH - 17) }
       inside { line=$0; sub(/^[[:space:]]+/, "", line); print line }
       inside && $0 == indent "}" { exit }' "$1"
}
ruby - "$SWEEP_WORKFLOW" "$TMP/sweep.sh" <<'RUBY'
require "yaml"
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("scheduled-sweep").fetch("steps")
matches = steps.select { |step| step["run"].to_s.include?("cr_surface_fp() {") }
abort("could not extract the CodeRabbit sweep's cr_surface_fp step") unless matches.length == 1
File.write(ARGV[1], matches[0]["run"])
RUBY
set +e
extract_fp "$TMP/publish.sh" >"$TMP/fp-publisher"
extract_fp "$TMP/sweep.sh" >"$TMP/fp-sweep"
[ "$(wc -l <"$TMP/fp-sweep" | tr -d ' ')" -gt 10 ] && grep -q 'reviewThreads' "$TMP/fp-sweep" \
  && cmp -s "$TMP/fp-publisher" "$TMP/fp-sweep"
case_rc=$?
set -e
[ "$case_rc" -eq 0 ] || diff "$TMP/fp-sweep" "$TMP/fp-publisher" || true
record "the publisher's cr_surface_fp is the sweep's, line for line" "$case_rc"

reset_case
MCG_RC=3; export MCG_RC
run_call "$MCG_CALL" >"$TMP/mcg3.out"
set +e
grep -qx $'merge-clearance-gate.sh\tunset' "$GATE_ENV_LOG" \
  && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "unrelated rc 3 receives no flag and remains an infra red" "$case_rc"
MCG_RC=0; export MCG_RC

# #2689: the Codex P1 caller evaluates through the snapshot driver, behind the
# guards of codex-p1-gate.yml's scheduled sweep. Driver rc 3 is exhausted
# feedback-snapshot recovery (drift on every attempt): the sweep publishes it
# red and counts it an infrastructure error, and so does the publisher.
reset_case
CODEX_RC=3; export CODEX_RC
run_call "$CODEX_CALL" >"$TMP/codex3.out"
set +e
grep -q $'\treport\tunset$' "$DRIVER_LOG" && [ ! -s "$GATE_ENV_LOG" ] \
  && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && grep -q -- '-f output\[title\]=fixture driver verdict rc=3' "$GH_CALL_LOG"
case_rc=$?
set -e
record "Codex driver rc 3 (snapshot drift exhausted) receives no flag and remains an infra red" "$case_rc"
CODEX_RC=0; export CODEX_RC

# The driver runs in report mode on the generation gate() opened (id 17 from
# the rcg_open double), never the gate script directly, after the relay scan;
# gate() publishes its verdict and its title through the one owned PATCH.
reset_case
run_call "$CODEX_CALL" >"$TMP/codex0.out"
set +e
[ "$(cat "$DRIVER_LOG")" = $'7 example/repo abc123 17 fingerprint\treport\tunset' ] \
  && [ "$(cat "$RELAY_LOG")" = "example/repo 7" ] && [ ! -s "$GATE_ENV_LOG" ] \
  && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=success' "$GH_CALL_LOG" \
  && grep -q -- '-f output\[title\]=fixture driver verdict rc=0' "$GH_CALL_LOG"
case_rc=$?
set -e
record "Codex P1 evaluates through the snapshot driver in report mode on its own generation" "$case_rc"

reset_case
CODEX_RC=1; export CODEX_RC
run_call "$CODEX_CALL" >"$TMP/codex1.out"
set +e
[ -s "$DRIVER_LOG" ] && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "Codex driver rc 1 (blocked) publishes failure without an infra flag" "$case_rc"
CODEX_RC=0; export CODEX_RC

# A driver that exits 0 without reporting that verdict is not a clearance.
reset_case
DRIVER_NO_REPORT=1; export DRIVER_NO_REPORT
run_call "$CODEX_CALL" >"$TMP/codex-no-report.out"
set +e
[ -s "$DRIVER_LOG" ] && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && ! grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "Codex driver exit 0 without a verdict report publishes an infra red" "$case_rc"
unset DRIVER_NO_REPORT

# Fingerprint-helper guard: missing or not executable, as in the sweep, is a
# failure and an infra error, with no relay scan and no evaluation. The same
# holds for a missing or non-executable driver.
fingerprint_guard_case() {  # <label> <path> <rm|chmod>
  local path="$TMP/$2"
  reset_case
  cp "$path" "$TMP/guard-saved"
  if [ "$3" = rm ]; then rm -f "$path"; else chmod -x "$path"; fi
  run_call "$CODEX_CALL" >"$TMP/codex-guard.out"
  set +e
  [ ! -s "$DRIVER_LOG" ] && [ ! -s "$RELAY_LOG" ] && [ ! -s "$GATE_ENV_LOG" ] \
    && [ "$had_infra_error" -eq 1 ] && one_post \
    && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
    && grep -q -- '-f output\[title\]=Codex P1 gate — fingerprint helper unavailable' "$GH_CALL_LOG"
  case_rc=$?
  set -e
  cp "$TMP/guard-saved" "$path"
  chmod +x "$path"
  record "$1" "$case_rc"
}
fingerprint_guard_case "a missing feedback-fingerprint helper publishes failure without evaluating" \
  scripts/review-feedback-surface-fingerprint.sh rm
fingerprint_guard_case "a non-executable feedback-fingerprint helper publishes failure without evaluating" \
  scripts/review-feedback-surface-fingerprint.sh chmod
fingerprint_guard_case "a non-executable snapshot driver publishes failure without evaluating" \
  scripts/workflow/codex-p1-snapshot-retry.py chmod

# Relay guard: a fork or Dependabot head whose trusted archive relay is still
# pending is withheld red (rc 1, no infra flag), and a failed relay scan is an
# infra red (rc 2), both before any evaluation, as in the sweep.
reset_case
RELAY_RC=1; export RELAY_RC
run_call "$CODEX_CALL" >"$TMP/codex-relay-pending.out"
set +e
[ -s "$RELAY_LOG" ] && [ ! -s "$DRIVER_LOG" ] && [ ! -s "$GATE_ENV_LOG" ] \
  && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && grep -q -- '-f output\[title\]=Codex P1 gate — archive preparation failed' "$GH_CALL_LOG"
case_rc=$?
set -e
record "a pending read-only archive relay withholds Codex P1 clearance without evaluating" "$case_rc"

reset_case
RELAY_RC=2; export RELAY_RC
run_call "$CODEX_CALL" >"$TMP/codex-relay-error.out"
set +e
[ -s "$RELAY_LOG" ] && [ ! -s "$DRIVER_LOG" ] \
  && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "a failed relay scan withholds Codex P1 clearance as an infra red" "$case_rc"
RELAY_RC=0; export RELAY_RC

reset_case
CR_RC=3; export CR_RC
run_call "$CR_CALL" >"$TMP/recovery-hold.out"
hold_writes=$(grep -c -- '-X POST .*check-runs' "$GH_CALL_LOG" || true)
CR_RC=0; export CR_RC
run_call "$CR_CALL" >"$TMP/recovery-clean.out"
set +e
[ "$hold_writes" -eq 1 ] \
  && [ "$(grep -c -- '-X POST .*check-runs' "$GH_CALL_LOG" || true)" -eq 2 ] \
  && grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "recognized terminal result retires a prior rc-3 hold" "$case_rc"

# #2247: a pending clearance verdict keeps the job-native run of the event job
# non-failing only because the Checks-API lineage carries the block. The
# publisher is that lineage's writer, so it must keep publishing FAILURE for
# the same verdict: it never asks for the pending distinction, and rc 1 maps
# to a red verdict exactly as before, with no infra flag.
reset_case
: >"$GATE_VERDICT_LOG"
MCG_RC=1 MCG_PENDING=1; export MCG_RC MCG_PENDING
run_call "$MCG_CALL" >"$TMP/mcg-pending.out"
set +e
[ "$(cat "$GATE_VERDICT_LOG")" = unset ] \
  && [ "$had_infra_error" -eq 0 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG" \
  && ! grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "pending clearance verdict still publishes a red Checks-API run, and the publisher never asks for the pending distinction" "$case_rc"
MCG_RC=0 MCG_PENDING=0; export MCG_RC MCG_PENDING

# An opening failure authorizes no evaluation or completion; a closing
# failure leaves the owned opening pending and reports infrastructure failure.
reset_case
OPEN_FAIL=1; export OPEN_FAIL
run_call "$MCG_CALL" >"$TMP/open-failed.out" 2>&1
set +e
[ ! -s "$GATE_ENV_LOG" ] && [ "$had_infra_error" -eq 1 ] \
  && [ "$(grep -c -- '-X PATCH' "$GH_CALL_LOG" || true)" -eq 0 ]
case_rc=$?
set -e
record "opening failure cannot evaluate or mint an unleased completion" "$case_rc"
unset OPEN_FAIL

reset_case
CLOSE_FAIL=1; export CLOSE_FAIL
run_call "$MCG_CALL" >"$TMP/close-failed.out" 2>&1
set +e
one_post && [ "$had_infra_error" -eq 1 ]
case_rc=$?
set -e
record "failed owned-ID PATCH leaves a visible pending opening and infra error" "$case_rc"
unset CLOSE_FAIL

if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi

if [ "${SUMMARY_HOLD_MUTATION_CHILD:-0}" = 1 ]; then
  echo "All $pass required-check publisher summary-hold behavior tests passed."
  exit 0
fi

# A mutation counts only when the child reports its specific behavioral
# assertion. Extraction and prerequisite errors are failures, not evidence that
# the mutation was detected.
expect_mutation_failure() {
  local label="$1" rc="$2" expected="$3" output="$4"
  if [ "$rc" -eq 1 ] && grep -Fqx -- "$expected" "$output"; then
    echo "PASS: $label failed at the intended assertion"
    return 0
  fi
  echo "FAIL: $label did not fail at the intended assertion (child exit $rc; expected: $expected)"
  cat "$output"
  return 1
}

# A real failed extraction must not satisfy the mutation predicate even though
# the child exits nonzero. This keeps the expected-marker check itself covered.
python3 - "$WORKFLOW" "$TMP/no-publish-step.yml" <<'PY3'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = 'name: Resolve targets, evaluate gates, publish'
assert text.count(old) == 1
Path(sys.argv[2]).write_text(text.replace(old, 'name: unrelated step', 1))
PY3
set +e
REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/no-publish-step.yml" \
  SUMMARY_HOLD_MUTATION_CHILD=1 bash "$0" >"$TMP/unrelated-child.out" 2>&1
mutation_rc=$?
set -e
if expect_mutation_failure "unrelated extraction failure control" "$mutation_rc" \
    'FAIL: recognized CodeRabbit finding publishes failure' "$TMP/unrelated-child.out" \
    >"$TMP/unrelated-control.out" 2>&1; then
  echo "FAIL: unrelated extraction failure counted as mutation detection"
  fail=$((fail + 1))
elif grep -Fq 'did not fail at the intended assertion' "$TMP/unrelated-control.out" \
    && grep -Fq 'could not extract the publisher publish step' "$TMP/unrelated-child.out"; then
  echo "PASS: unrelated extraction failure is rejected as mutation evidence"
  pass=$((pass + 1))
else
  echo "FAIL: unrelated extraction control did not report its cause"
  cat "$TMP/unrelated-control.out" "$TMP/unrelated-child.out"
  fail=$((fail + 1))
fi

# Each mutation reruns this same extracted caller/helper suite. The failure is
# behavioral: the mutated shipped caller writes when it should hold or stops
# exporting the classifier flag, rather than a permanent spacing-sensitive pin.
python3 - "$WORKFLOW" "$TMP/no-opt-in.yml" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = '"$PR" "$head_sha" true'
assert text.count(old) == 1
Path(sys.argv[2]).write_text(text.replace(old, '"$PR" "$head_sha"', 1))
PY
set +e
REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/no-opt-in.yml" \
  SUMMARY_HOLD_MUTATION_CHILD=1 bash "$0" >"$TMP/no-opt-in.out" 2>&1
mutation_rc=$?
set -e
expect_mutation_failure "removal of the CodeRabbit opt-in" "$mutation_rc" \
  'FAIL: recognized CodeRabbit finding publishes failure' "$TMP/no-opt-in.out" \
  || fail=$((fail + 1))

python3 - "$WORKFLOW" "$TMP/no-withhold.yml" <<'PY2'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = 'title="$context — evidence hold; explicit recovery required after escalation"'
assert text.count(old) == 1
Path(sys.argv[2]).write_text(text.replace(old, 'conclusion="success"; ' + old, 1))
PY2
set +e
REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/no-withhold.yml" \
  SUMMARY_HOLD_MUTATION_CHILD=1 bash "$0" >"$TMP/no-withhold.out" 2>&1
mutation_rc=$?
set -e
expect_mutation_failure "unrecognized-evidence success mutation" "$mutation_rc" \
  'FAIL: unknown current-head CodeRabbit run closes its owned generation red' "$TMP/no-withhold.out" \
  || fail=$((fail + 1))

# #2689 and #2690: each ported sweep guard, removed from the shipped workflow,
# must fail the case that pins it. Each edit replaces exactly one shipped
# passage.
guard_mutation() {  # <label> <old> <new> <expected FAIL line>
  local out="$TMP/codex-mutation.out"
  python3 - "$WORKFLOW" "$TMP/codex-mutation.yml" "$2" "$3" <<'PY4'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old, new = sys.argv[3], sys.argv[4]
assert text.count(old) == 1, old
Path(sys.argv[2]).write_text(text.replace(old, new, 1))
PY4
  set +e
  REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/codex-mutation.yml" \
    SUMMARY_HOLD_MUTATION_CHILD=1 bash "$0" >"$out" 2>&1
  mutation_rc=$?
  set -e
  expect_mutation_failure "$1" "$mutation_rc" "$4" "$out" || fail=$((fail + 1))
}
guard_mutation "removal of the Codex P1 fingerprint-helper guard" \
  'if [ ! -x scripts/review-feedback-surface-fingerprint.sh ] || [ ! -x "$driver" ]; then' \
  'if false; then' \
  'FAIL: a missing feedback-fingerprint helper publishes failure without evaluating'
guard_mutation "a Codex P1 caller that runs the gate script instead of the snapshot driver" \
  'gate scripts/workflow/codex-p1-snapshot-retry.py "$CODEX_P1_CONTEXT"' \
  'gate scripts/codex-p1-gate.sh "$CODEX_P1_CONTEXT"' \
  'FAIL: Codex P1 evaluates through the snapshot driver in report mode on its own generation'
guard_mutation "a gate() that bypasses the Codex P1 evaluation" \
  'elif [ "$context" = "${CODEX_P1_CONTEXT:-}" ]; then' \
  'elif false; then' \
  'FAIL: Codex P1 evaluates through the snapshot driver in report mode on its own generation'
guard_mutation "removal of the Codex P1 relay-pending guard" \
  'if [ "$relay_rc" -ne 0 ]; then' \
  'if false; then' \
  'FAIL: a pending read-only archive relay withholds Codex P1 clearance without evaluating'
guard_mutation "a gate() that evaluates CodeRabbit without the surface bracket" \
  'coderabbit_evaluate "$script" "$pr"' \
  'output=$(REQUIRE_REVIEW_SUMMARY=true "$script" "$pr" "$REPO" 2>&1); rc=$?' \
  'FAIL: a comments change during the CodeRabbit evaluation closes the generation red, unpublished'
guard_mutation "removal of the CodeRabbit surface-change comparison" \
  'if [ "$pre_fp" != "$post_fp" ]; then' \
  'if false; then' \
  'FAIL: a threads change during the CodeRabbit evaluation closes the generation red, unpublished'
guard_mutation "removal of the CodeRabbit surface read-failure branch" \
  'if [ "$pre_fp_rc" -ne 0 ] || [ "$post_fp_rc" -ne 0 ]; then' \
  'if false; then' \
  'FAIL: a failed surface read after a clean gate re-runs it as an evidence failure and closes red'
guard_mutation "a first surface read failure not passed to the CodeRabbit gate" \
  '[ "$pre_fp_rc" -eq 0 ] || evidence_failure="fingerprint-read-failed"' \
  ':' \
  'FAIL: a failed surface read before the gate is passed to it and closes the generation red'
guard_mutation "a surface change that keeps the evidence report" \
  "$(printf '%s\n%s' 'closing this generation red for a fresh evaluation."' '                  : >"$CR_EVIDENCE_REPORT"')" \
  'closing this generation red for a fresh evaluation."' \
  'FAIL: a inline change during the CodeRabbit evaluation closes the generation red, unpublished'
guard_mutation "an rc 3 summary hold that ignores the rate-limit stop" \
  'if [ "$summary_hold" = true ] && [ "$rate_limit_red" -eq 0 ]; then' \
  'if [ "$summary_hold" = true ]; then' \
  'FAIL: an rc 3 hold whose own output shows the rate limit publishes the back-off red as an infra error'
guard_mutation "a back-off title written only for exits other than rc 3" \
  'if [ "$rate_limit_red" -eq 1 ]; then' \
  'if [ "$rate_limit_red" -eq 1 ] && [ "$rc" -ne 3 ]; then' \
  'FAIL: both surface reads failed on the rate limit: the rc 3 hold publishes the back-off red and stops the pass'
guard_mutation "a publisher fingerprint that drops a surface the sweep reads" \
  "printf '%s\035%s\035%s\035%s' \"\$comments\" \"\$reviews\" \"\$inline\" \"\$threads\"" \
  "printf '%s\035%s\035%s' \"\$comments\" \"\$reviews\" \"\$inline\"" \
  "FAIL: the publisher's cr_surface_fp is the sweep's, line for line"

if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi
echo "All $pass required-check publisher summary-hold behavior tests, 14 mutations, and unrelated-failure control passed."
