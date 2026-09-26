#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"

command -v ruby >/dev/null 2>&1 || { echo "ERROR: Ruby is required" >&2; exit 1; }
ruby -e 'require "yaml"' >/dev/null 2>&1 \
  || { echo "ERROR: Ruby YAML support is required" >&2; exit 1; }

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

awk '
  /^gate\(\) \{$/ { inside=1 }
  inside { print }
  inside && /^}$/ { exit }
' "$TMP/publish.sh" >"$TMP/gate-helper.sh"
grep '^[[:space:]]*gate scripts/' "$TMP/publish.sh" >"$TMP/gate-calls.sh" || true
if ! grep -q '^gate() {$' "$TMP/gate-helper.sh" \
    || [ "$(wc -l <"$TMP/gate-calls.sh" | tr -d ' ')" -ne 3 ]; then
  echo "FAIL: could not extract one gate helper and its three live callers"
  exit 1
fi

MCG_CALL=$(grep 'merge-clearance-gate.sh' "$TMP/gate-calls.sh")
CODEX_CALL=$(grep 'codex-p1-gate.sh' "$TMP/gate-calls.sh")
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
    ;;
  codex-p1-gate.sh) rc=$CODEX_RC ;;
  coderabbit-severity-gate.sh) rc=$CR_RC ;;
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

cat >"$TMP/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
case "$*" in
  *"-X POST"*"/check-runs"*) printf '{}\n' ;;
  *"/commits/"*"/check-runs"*) exit 0 ;;
  *"/pulls/"*" --jq .head.sha"*) printf '%s\n' abc123 ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$TMP/gh"

# The real workflow declares no job- or step-wide summary flag. Clear a
# developer's ambient export so only the extracted CodeRabbit caller can set it.
unset REQUIRE_REVIEW_SUMMARY

# shellcheck disable=SC1090,SC1091
. "$TMP/gate-helper.sh"
export PATH="$TMP:$PATH"
export REPO=example/repo PASS_START=2026-09-25T00:00:00Z OWN_PENDING_IDS=""
export GATE_ENV_LOG="$TMP/gate-env" GH_CALL_LOG="$TMP/gh-calls"
export PR=7 head_sha=abc123
export MCG_CONTEXT="Merge clearance gate"
export CODEX_P1_CONTEXT="Codex P1 unresolved threads"
export CODERABBIT_CONTEXT="CodeRabbit unresolved blocking findings"
export MCG_RC=0 CODEX_RC=0 CR_RC=0

run_call() {
  local call="$1" previous="$PWD"
  cd "$TMP"
  eval "$call"
  cd "$previous"
}

reset_case() {
  : >"$GATE_ENV_LOG"
  : >"$GH_CALL_LOG"
  had_infra_error=0
}

one_post() {
  [ "$(grep -c -- '-X POST .*check-runs' "$GH_CALL_LOG" || true)" -eq 1 ]
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
  && [ "$had_infra_error" -eq 0 ] && [ ! -s "$GH_CALL_LOG" ] \
  && grep -qF 'withholding CodeRabbit unresolved blocking findings publication' "$TMP/cr3.out"
case_rc=$?
set -e
record "unknown current-head CodeRabbit run withholds without a write" "$case_rc"

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

reset_case
CODEX_RC=3; export CODEX_RC
run_call "$CODEX_CALL" >"$TMP/codex3.out"
set +e
grep -qx $'codex-p1-gate.sh\tunset' "$GATE_ENV_LOG" \
  && [ "$had_infra_error" -eq 1 ] && one_post \
  && grep -q -- '-f conclusion=failure' "$GH_CALL_LOG"
case_rc=$?
set -e
record "Codex rc 3 also receives no flag and remains an infra red" "$case_rc"
CODEX_RC=0; export CODEX_RC

reset_case
CR_RC=3; export CR_RC
run_call "$CR_CALL" >"$TMP/recovery-hold.out"
hold_writes=$(grep -c -- '-X POST .*check-runs' "$GH_CALL_LOG" || true)
CR_RC=0; export CR_RC
run_call "$CR_CALL" >"$TMP/recovery-clean.out"
set +e
[ "$hold_writes" -eq 0 ] \
  && [ "$(grep -c -- '-X POST .*check-runs' "$GH_CALL_LOG" || true)" -eq 1 ] \
  && grep -q -- '-f conclusion=success' "$GH_CALL_LOG"
case_rc=$?
set -e
record "recognized terminal result retires a prior rc-3 hold" "$case_rc"

if [ "$fail" -ne 0 ]; then
  echo "$fail failed, $pass passed"
  exit 1
fi

if [ "${SUMMARY_HOLD_MUTATION_CHILD:-0}" = 1 ]; then
  echo "All $pass required-check publisher summary-hold behavior tests passed."
  exit 0
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
if REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/no-opt-in.yml" \
    SUMMARY_HOLD_MUTATION_CHILD=1 bash "$0" >"$TMP/no-opt-in.out" 2>&1; then
  echo "FAIL: runtime suite accepted removal of the CodeRabbit opt-in"
  exit 1
fi
echo "PASS: runtime suite rejects removal of the CodeRabbit opt-in"

python3 - "$WORKFLOW" "$TMP/no-withhold.yml" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = 'if [ "$summary_hold" = true ] && [ "$rc" -eq 3 ]; then'
assert text.count(old) == 1
Path(sys.argv[2]).write_text(text.replace(old, 'if false; then', 1))
PY
if REQUIRED_CHECK_PUBLISHER_WORKFLOW="$TMP/no-withhold.yml" \
    SUMMARY_HOLD_MUTATION_CHILD=1 bash "$0" >"$TMP/no-withhold.out" 2>&1; then
  echo "FAIL: runtime suite accepted removal of the rc-3 withhold"
  exit 1
fi
echo "PASS: runtime suite rejects removal of the rc-3 withhold"

echo "All $pass required-check publisher summary-hold behavior tests and 2 mutations passed."
