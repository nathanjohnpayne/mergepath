#!/usr/bin/env bash
# tests/test_codex_review_check_required_checks.sh
#
# Regression coverage for gate (a)'s annex-awareness in
# scripts/codex-review-check.sh (#655): when branch protection lists SOME
# required checks (the common case), gate (a) narrows its "must be green"
# scrutiny to that list — so a consumer's optional, never-propagated #601
# repo_lint_local.yml annex check is silently excluded, even when it is red,
# entirely missing, or shares a name with an unrelated check. Branch
# protection cannot require it centrally — the annex is per-consumer and
# never propagated, so there is no canonical PR to add it fleet-wide (that
# half is a human branch-protection change; see #655). This closes the
# agent-doable half across five rounds of Codex findings:
#
#   Round 1 P1: force-include the annex's check into gate (a)'s scrutiny
#   regardless of branch protection's required-check list, including the
#   "no required checks configured" branch, which used to wipe the whole
#   rollup unconditionally.
#
#   Round 2 P2: the annex's job (and therefore check-run) name is not
#   guaranteed to be literally "repo-lint-local" — derive it from the annex
#   YAML instead of assuming the filename convention.
#
#   Round 3 P2: a matrix-strategy annex job expands into check-run names
#   this static YAML read cannot reproduce — skip matrix jobs during NAME
#   derivation instead of guessing (asserted structurally below, not via an
#   inline jq replica, since it is ruby-level logic).
#
#   Round 4 P2: a 403 on the annex probe (token lacks Contents: read) is
#   usually persistent, not transient — do not fail closed on it the way a
#   generic indeterminate error does, since that would force an
#   unresolvable check on every future PR on an under-scoped repo. Also: a
#   genuine YAML-parse failure and a valid-parse-but-all-matrix annex are
#   different failure modes and must be handled differently.
#
#   Round 5 P2 x2 (superseding rounds 2-4's MISSING-injection approach):
#   rounds 2-4 forced a synthetic MISSING requirement for a derived check
#   name that had not yet reported. Round 5 found three DISTINCT ways this
#   turns into a PERMANENT deadlock: a persistent 403 (round 4, already
#   fixed), an all-matrix annex whose unexpanded name will never exist
#   (round 4), and a path-filtered annex that legitimately never runs for a
#   given PR's diff (round 5) -- plus a blind spot in the opposite
#   direction, where excluding matrix jobs from the name-based requirement
#   also meant a REPORTED matrix-leg failure was never observed (round 5).
#   The fix replaces MISSING-injection with a workflow-wide scan: any
#   REPORTED entry belonging to the annex's own workflow (matched by
#   .workflowName, not by a specific check name) that is non-green is
#   unioned into BAD_CHECKS directly. This catches a reported matrix
#   failure without needing its expanded name, and never invents a
#   requirement for a check that has not (and may never) report, closing
#   the deadlock class entirely.
#
# The full gate (a) needs network (statusCheckRollup + branch-protection API
# reads + the annex Contents API probe); this test pins (1) the structural
# presence of each fix in the real script and (2) the jq logic inline — the
# same inline-literal pattern test_codex_review_check_verdict.sh and
# test_codex_review_check_resolution.sh use. KEEP THE INLINE FILTERS BELOW IN
# SYNC with scripts/codex-review-check.sh's gate (a).
#
# Bash 3.2 portable. Runs without network (the annex-probe + ruby-yaml
# derivation itself — including the matrix-skip and name+workflow pairing —
# is validated by real/synthetic ruby invocations during development; see
# the PR/issue #655 discussion — but is not re-exercised here since this
# suite runs offline).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review-check.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── 1. Structural: the real script probes the annex, derives (name,
#      workflow) pairs plus the annex's own workflow name, skips
#      matrix-strategy jobs during name derivation, and scans the annex's
#      workflow for any reported non-green conclusion (#655 round 5,
#      superseding the earlier MISSING-injection approach).
if grep -q 'ANNEX_CHECKS_JSON' "$SCRIPT" \
   && grep -q 'ANNEX_WORKFLOW_NAME' "$SCRIPT" \
   && grep -q 'doc\["jobs"\].each do |id, job|' "$SCRIPT" \
   && grep -q 'workflow_name = doc\["name"\].to_s' "$SCRIPT" \
   && grep -q 'ANNEX_WORKFLOW_BAD' "$SCRIPT" \
   && grep -q "#655" "$SCRIPT"; then
  pass "codex-review-check.sh gate (a) probes the annex, derives (name, workflow) pairs plus the annex workflow name, and scans it for reported failures (#655)"
else
  fail "codex-review-check.sh gate (a) is missing the annex probe / (name, workflow) derivation / workflow-wide bad-conclusion scan (#655)"
fi

if grep -q 'job\["strategy"\].is_a?(Hash) && job\["strategy"\]\["matrix"\]' "$SCRIPT" \
   && grep -q 'skipping matrix-strategy job' "$SCRIPT"; then
  pass "codex-review-check.sh skips matrix-strategy annex jobs during NAME derivation instead of guessing their expanded name(s) (#655 round 3 P2)"
else
  fail "codex-review-check.sh does not guard against matrix-strategy annex jobs"
fi

# Fail-closed on an indeterminate annex-probe error (not a confirmed 404).
if grep -q "grep -q 'HTTP 404' \"\$annex_probe_err\"" "$SCRIPT"; then
  pass "codex-review-check.sh distinguishes a confirmed 404 (annex absent) from other annex-probe errors"
else
  fail "codex-review-check.sh does not distinguish a confirmed 404 from other annex-probe errors"
fi

# Codex P2 (#655 round 4): a 403 (token lacks Contents: read) is usually
# persistent, not transient -- forcing the synthetic fallback would
# permanently block Phase 4 label-clearing / merge-gate checks on every
# future PR, not just annex-having ones. Do not fail closed on a confirmed
# 403 the way the generic indeterminate-error branch does.
if grep -q "grep -q 'HTTP 403' \"\$annex_probe_err\"" "$SCRIPT"; then
  pass "codex-review-check.sh does not fail closed on a confirmed 403 (likely a persistent token-scope gap, not transient)"
else
  fail "codex-review-check.sh does not distinguish a confirmed 403 from other (plausibly transient) annex-probe errors"
fi

# Codex P2 (#655 round 4): "could not parse the YAML at all" (ruby exits
# before its `puts` line -- empty output) is a different failure mode from
# "parsed fine but every job was matrix-strategy and skipped" (ruby emits an
# object with an empty jobs array) -- only the former falls back to the
# conventional name; the latter must not, since that name will never exist
# for a matrix-only annex and would permanently block the merge gate.
if grep -q 'every job is matrix-strategy (skipped)' "$SCRIPT"; then
  pass "codex-review-check.sh distinguishes genuine YAML-parse failure from a valid parse where every job was matrix-skipped"
else
  fail "codex-review-check.sh does not distinguish genuine parse failure from an all-matrix-jobs annex"
fi

# ── 2. Inline logic: the three REQUIRED_JSON branches, parameterized on
#      ANNEX_CHECK_NAMES_JSON (bare names derived from ANNEX_CHECKS_JSON)
#      instead of a hard-coded "repo-lint-local" string. Required-set
#      matching stays name-only (like every other required-check match in
#      this script, and like GitHub's own native required-status-checks
#      feature); workflow disambiguation happens only in the separate
#      workflow-wide bad-conclusion scan (section 3 below).
#      KEEP IN SYNC with scripts/codex-review-check.sh's gate (a).

# Non-empty required-names branch: merge in the annex's derived name(s).
merge_required() {
  local required_names_csv=$1 annex_names_json=$2
  printf '%s' "$required_names_csv" | jq -R . | jq -s . | jq --argjson annex "$annex_names_json" '. + $annex | unique'
}

# Empty required-names branch: scope REQUIRED_JSON to the annex alone when
# it is present (per the probe, not merely "already in the rollup").
empty_branch_required_json() {
  local annex_names_json=$1
  if [ "$(printf '%s' "$annex_names_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$annex_names_json"
  else
    printf '[]'
  fi
}

# End-to-end BAD_CHECKS filter (the required-name-scoped half). KEEP IN SYNC
# with scripts/codex-review-check.sh.
bad_checks() {
  local rollup_json=$1 required_names_json=$2
  printf '%s' "$rollup_json" | jq --argjson required_names "$required_names_json" '
    [.statusCheckRollup[]
      | { label: (.name // .context // "?"), workflow: (.workflowName // ""), result: (.conclusion // .state // "") }
      | select((.workflow != "PR Review Policy") or (.label != "Label Gate"))
      | (.label) as $label_name
      | select(($required_names | length) == 0 or ($required_names | index($label_name)) != null)
      | select((.result != "SUCCESS") and (.result != "SKIPPED") and (.result != "NEUTRAL"))
    ]'
}

# Workflow-wide bad-conclusion scan (#655 round 5), replacing MISSING-
# injection. KEEP IN SYNC with scripts/codex-review-check.sh's
# ANNEX_WORKFLOW_BAD computation.
annex_workflow_bad() {
  local rollup_json=$1 workflow=$2
  printf '%s' "$rollup_json" | jq --arg workflow "$workflow" '
    [.statusCheckRollup[]
      | select((.workflowName // "") == $workflow)
      | {
          label: (.name // .context // "?"),
          workflow: (.workflowName // ""),
          result: (.conclusion // .state // "")
        }
      | select((.result != "SUCCESS") and (.result != "SKIPPED") and (.result != "NEUTRAL"))
    ]'
}

# Round-1 shape: annex named the conventional "repo-lint-local" (bare names,
# for the REQUIRED_JSON-merge tests, which stay name-only).
ANNEX_CONVENTIONAL='["repo-lint-local"]'
# Round-2 shape: a consumer whose annex job uses a different name entirely.
ANNEX_RENAMED='["my-custom-checks"]'
ANNEX_NONE='[]'

GOT=$(merge_required 'lint' "$ANNEX_CONVENTIONAL" | jq -c 'sort')
if [ "$GOT" = '["lint","repo-lint-local"]' ]; then
  pass "non-empty branch: conventional annex name merges into the required set"
else
  fail "non-empty branch (conventional): expected [\"lint\",\"repo-lint-local\"], got $GOT"
fi

GOT=$(merge_required 'lint' "$ANNEX_RENAMED" | jq -c 'sort')
if [ "$GOT" = '["lint","my-custom-checks"]' ]; then
  pass "non-empty branch: a renamed annex job (#655 round 2 P2) merges by its DERIVED name, not a hard-coded one"
else
  fail "non-empty branch (renamed): expected [\"lint\",\"my-custom-checks\"], got $GOT"
fi

GOT=$(merge_required 'lint' "$ANNEX_NONE" | jq -c 'sort')
if [ "$GOT" = '["lint"]' ]; then
  pass "non-empty branch: no annex -> required set is untouched (no consumer regression)"
else
  fail "non-empty branch (no annex): expected [\"lint\"] unchanged, got $GOT"
fi

GOT=$(merge_required "$(printf 'lint\nrepo-lint-local')" "$ANNEX_CONVENTIONAL" | jq -c 'sort')
if [ "$GOT" = '["lint","repo-lint-local"]' ]; then
  pass "non-empty branch: already-required (a future branch-protection addition) -> no duplicate entry"
else
  fail "non-empty branch (already-required): expected no duplicate, got $GOT"
fi

GOT=$(empty_branch_required_json "$ANNEX_CONVENTIONAL")
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "empty-required branch: annex present (probe-confirmed) -> scopes REQUIRED_JSON to it alone (#655 round 1)"
else
  fail "empty-required branch (annex present): expected [\"repo-lint-local\"], got $GOT"
fi

GOT=$(empty_branch_required_json "$ANNEX_NONE")
if [ "$GOT" = '[]' ]; then
  pass "empty-required branch: no annex -> unchanged (empty required, no enforcement)"
else
  fail "empty-required branch (no annex): expected [], got $GOT"
fi

# ── 3. Inline logic: the workflow-wide bad-conclusion scan (#655 round 5).
ROLLUP_ANNEX_REPORTED_GOOD='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"repo-lint-local","conclusion":"SUCCESS"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_ANNEX_REPORTED_GOOD" "repo-lint-local")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a green annex report -> no bad entries"
else
  fail "workflow-wide scan (green): expected 0 bad entries, got $GOT"
fi

ROLLUP_ANNEX_REPORTED_BAD='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"repo-lint-local","conclusion":"FAILURE"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_ANNEX_REPORTED_BAD" "repo-lint-local" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "workflow-wide scan: a red annex report blocks (round 1 scenario, now via workflow scan too)"
else
  fail "workflow-wide scan (red): expected [\"repo-lint-local\"], got $GOT"
fi

# #655 round 5 Codex P2: a matrix-expanded leg is invisible to the name-based
# requirement (matrix jobs are excluded from ANNEX_CHECKS_JSON), but its
# REPORTED failure still carries the annex's own workflow name, so the
# workflow-wide scan catches it regardless.
ROLLUP_MATRIX_LEG_FAILED='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"checks (18)","workflowName":"consumer-annex","conclusion":"SUCCESS"},{"name":"checks (20)","workflowName":"consumer-annex","conclusion":"FAILURE"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex" | jq -c '[.[].label]')
if [ "$GOT" = '["checks (20)"]' ]; then
  pass "workflow-wide scan: a reported matrix-leg failure is caught by workflow identity, without needing its expanded name (#655 round 5 P2)"
else
  fail "workflow-wide scan (matrix leg): expected [\"checks (20)\"], got $GOT"
fi

# #655 round 5 Codex P2: an annex that has not reported ANYTHING for its
# workflow (never started, or path-filtered out of this PR's diff entirely)
# must NOT be treated as blocking -- this is the fix for the permanent
# deadlock the removed MISSING-injection could create for a path-filtered
# annex that legitimately never runs for a given PR.
ROLLUP_NEVER_REPORTED='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_NEVER_REPORTED" "consumer-annex")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: an annex that never reported anything is NOT blocking (no deadlock for a path-filtered-out annex, #655 round 5 P2)"
else
  fail "workflow-wide scan (never reported): expected 0 (no false block), got $GOT"
fi

# Skipped/neutral reports still pass, consistent with everywhere else.
ROLLUP_ANNEX_SKIPPED='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"repo-lint-local","conclusion":"SKIPPED"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_ANNEX_SKIPPED" "repo-lint-local")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a SKIPPED annex report does not block, consistent with SUCCESS/SKIPPED/NEUTRAL elsewhere"
else
  fail "workflow-wide scan (skipped): expected 0, got $GOT"
fi

# ── 4. End-to-end: union of the required-name-scoped BAD_CHECKS and the
#      workflow-wide scan (#655 round 5), mirroring how the real script
#      merges them before computing BAD_COUNT.
AUGMENTED=$(merge_required 'lint' "$ANNEX_CONVENTIONAL")
GOT=$(bad_checks "$ROLLUP_ANNEX_REPORTED_BAD" "$AUGMENTED" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "end-to-end: a red conventional-named annex check blocks via the name-scoped filter (round 1)"
else
  fail "end-to-end (red conventional, name-scoped): expected [\"repo-lint-local\"], got $GOT"
fi

# The matrix-leg failure is invisible to the name-scoped filter (its
# required_names never contains the expanded "checks (20)"), but IS caught
# once unioned with the workflow-wide scan -- exactly like the real script.
GOT=$(bad_checks "$ROLLUP_MATRIX_LEG_FAILED" "$AUGMENTED" | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end: confirms the matrix-leg failure is invisible to the name-scoped filter alone"
else
  fail "end-to-end (matrix leg, name-scoped only): expected [] (invisible without the workflow scan), got $GOT"
fi
UNIONED=$(echo "$(bad_checks "$ROLLUP_MATRIX_LEG_FAILED" "$AUGMENTED")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex")" '(. + $extra) | unique')
GOT=$(echo "$UNIONED" | jq -c '[.[].label]')
if [ "$GOT" = '["checks (20)"]' ]; then
  pass "end-to-end: unioning the workflow-wide scan catches the matrix-leg failure the name-scoped filter alone misses (#655 round 5)"
else
  fail "end-to-end (matrix leg, unioned): expected [\"checks (20)\"], got $GOT"
fi

ROLLUP_SKIPPED_ANNEX='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"SKIPPED"}]}'
GOT=$(bad_checks "$ROLLUP_SKIPPED_ANNEX" "$AUGMENTED" | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end: a SKIPPED annex check (job-level conditional) does not block, consistent with SUCCESS/SKIPPED/NEUTRAL elsewhere"
else
  fail "end-to-end (skipped annex): expected [] (non-blocking), got $GOT"
fi

# Pre-#655 regression guard: without any annex awareness at all, a red
# conventional-named annex check was invisible to the filter.
GOT=$(bad_checks "$ROLLUP_ANNEX_REPORTED_BAD" '["lint"]' | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "confirms the pre-#655 bug shape: without annex awareness, a red repo-lint-local is invisible to BAD_CHECKS"
else
  fail "expected the unaugmented filter to reproduce the pre-#655 miss ([]), got $GOT"
fi

echo ""
echo "test_codex_review_check_required_checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
