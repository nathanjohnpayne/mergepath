#!/usr/bin/env bash
# tests/test_codex_review_check_required_checks.sh
#
# Regression coverage for gate (a)'s annex-awareness in
# scripts/codex-review-check.sh (#655): when branch protection lists SOME
# required checks (the common case), gate (a) narrows its "must be green"
# scrutiny to that list — so a consumer's optional, never-propagated #601
# repo_lint_local.yml annex check is silently excluded, even when it is red
# or entirely missing. Branch protection cannot require it centrally — the
# annex is per-consumer and never propagated, so there is no canonical PR to
# add it fleet-wide (that half is a human branch-protection change; see
# #655). This closes the agent-doable half across three rounds of Codex
# findings:
#
#   Round 1 P1: force-include the annex's check into gate (a)'s scrutiny
#   regardless of branch protection's required-check list, including the
#   "no required checks configured" branch, which used to wipe the whole
#   rollup unconditionally.
#
#   Round 2 P2 x2: (a) the annex's job (and therefore check-run) name is not
#   guaranteed to be literally "repo-lint-local" — derive it from the annex
#   YAML instead of assuming the filename convention; (b) if the annex
#   workflow has not started for this PR at all (skipped by a path/job
#   conditional, or simply not run yet), it never appears in the rollup, so
#   a rollup-presence-only check is blind to it — proactively probe the
#   annex file and treat a derived-but-missing check as blocking, not absent.
#
# The full gate (a) needs network (statusCheckRollup + branch-protection API
# reads + the annex Contents API probe); this test pins (1) the structural
# presence of each fix in the real script and (2) the jq logic inline — the
# same inline-literal pattern test_codex_review_check_verdict.sh and
# test_codex_review_check_resolution.sh use. KEEP THE INLINE FILTERS BELOW IN
# SYNC with scripts/codex-review-check.sh's gate (a).
#
# Bash 3.2 portable. Runs without network (the annex-probe + ruby-yaml
# derivation itself is validated by a real invocation against a live
# consumer annex during development — see the PR/issue #655 discussion —
# but is not re-exercised here since this suite runs offline).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review-check.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── 1. Structural: the real script probes the annex, derives its job
#      name(s) rather than hard-coding "repo-lint-local", and injects a
#      synthetic MISSING entry for a derived-but-unreported check.
if grep -q 'ANNEX_CHECK_NAMES_JSON' "$SCRIPT" \
   && grep -q 'doc\["jobs"\].each do |id, job|' "$SCRIPT" \
   && grep -q 'conclusion: "MISSING"' "$SCRIPT" \
   && grep -q "#655" "$SCRIPT"; then
  pass "codex-review-check.sh gate (a) probes the annex, derives job names, and injects MISSING for unreported checks (#655)"
else
  fail "codex-review-check.sh gate (a) is missing the annex probe / job-name derivation / MISSING injection (#655)"
fi

# Fail-closed on an indeterminate annex-probe error (not a confirmed 404).
if grep -q "grep -q 'HTTP 404' \"\$annex_probe_err\"" "$SCRIPT"; then
  pass "codex-review-check.sh distinguishes a confirmed 404 (annex absent) from other annex-probe errors"
else
  fail "codex-review-check.sh does not distinguish a confirmed 404 from other annex-probe errors"
fi

# ── 2. Inline logic: the three REQUIRED_JSON branches, parameterized on
#      ANNEX_CHECK_NAMES_JSON (whatever the probe derived) instead of a
#      hard-coded "repo-lint-local" string. KEEP IN SYNC with
#      scripts/codex-review-check.sh's gate (a).

# Non-empty required-names branch: merge in the annex's derived name(s).
merge_required() {
  local required_names_csv=$1 annex_json=$2
  printf '%s' "$required_names_csv" | jq -R . | jq -s . | jq --argjson annex "$annex_json" '. + $annex | unique'
}

# Empty required-names branch: scope REQUIRED_JSON to the annex alone when
# it is present (per the probe, not merely "already in the rollup").
empty_branch_required_json() {
  local annex_json=$1
  if [ "$(printf '%s' "$annex_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$annex_json"
  else
    printf '[]'
  fi
}

# MISSING-injection: a derived annex check name with no rollup entry at all
# gets a synthetic MISSING entry so it is not indistinguishable from "not
# required at all".
inject_missing() {
  local rollup_json=$1 annex_json=$2
  printf '%s' "$rollup_json" | jq --argjson annex "$annex_json" '
    (.statusCheckRollup // []) as $existing
    | ($existing | map(.name // .context // "")) as $present
    | .statusCheckRollup = ($existing + [
        $annex[] | select(. as $n | ($present | index($n)) == null) | { name: ., conclusion: "MISSING" }
      ])
  '
}

# End-to-end BAD_CHECKS filter. KEEP IN SYNC with scripts/codex-review-check.sh.
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

# Round-1 shape: annex named the conventional "repo-lint-local".
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

# ── 3. Inline logic: MISSING injection (#655 round 2 P2 — annex workflow
#      never started / was skipped for this PR).
ROLLUP_NO_ANNEX_ENTRY='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"}]}'
GOT=$(inject_missing "$ROLLUP_NO_ANNEX_ENTRY" "$ANNEX_CONVENTIONAL" | jq -c '.statusCheckRollup | map(.name) | sort')
if [ "$GOT" = '["lint","repo-lint-local"]' ]; then
  pass "MISSING injection: an annex check absent from the rollup gets a synthetic entry"
else
  fail "MISSING injection: expected [lint, repo-lint-local], got $GOT"
fi

ROLLUP_ANNEX_ALREADY_REPORTED='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"SUCCESS"}]}'
GOT=$(inject_missing "$ROLLUP_ANNEX_ALREADY_REPORTED" "$ANNEX_CONVENTIONAL" | jq -c '.statusCheckRollup | length')
if [ "$GOT" = "2" ]; then
  pass "MISSING injection: an annex check already in the rollup is not duplicated"
else
  fail "MISSING injection: expected 2 rollup entries (no duplicate), got $GOT"
fi

GOT=$(inject_missing "$ROLLUP_NO_ANNEX_ENTRY" "$ANNEX_NONE" | jq -c .)
if [ "$GOT" = "$ROLLUP_NO_ANNEX_ENTRY" ]; then
  pass "MISSING injection: no annex -> the rollup is untouched (no consumer regression)"
else
  fail "MISSING injection: no-annex case should be a no-op, got $GOT"
fi

# ── 4. End-to-end BAD_CHECKS: every #655 scenario in one pass.
ROLLUP_RED_ANNEX='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"FAILURE"}]}'
AUGMENTED=$(merge_required 'lint' "$ANNEX_CONVENTIONAL")
GOT=$(bad_checks "$ROLLUP_RED_ANNEX" "$AUGMENTED" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "end-to-end: a red conventional-named annex check blocks (round 1)"
else
  fail "end-to-end (red conventional): expected [\"repo-lint-local\"], got $GOT"
fi

ROLLUP_RED_RENAMED='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"my-custom-checks","conclusion":"FAILURE"}]}'
AUGMENTED_RENAMED=$(merge_required 'lint' "$ANNEX_RENAMED")
GOT=$(bad_checks "$ROLLUP_RED_RENAMED" "$AUGMENTED_RENAMED" | jq -c '[.[].label]')
if [ "$GOT" = '["my-custom-checks"]' ]; then
  pass "end-to-end: a red RENAMED annex check blocks too (round 2 P2 — no longer invisible to a hard-coded name match)"
else
  fail "end-to-end (red renamed): expected [\"my-custom-checks\"], got $GOT"
fi

MISSING_INJECTED=$(inject_missing "$ROLLUP_NO_ANNEX_ENTRY" "$ANNEX_CONVENTIONAL")
GOT=$(bad_checks "$MISSING_INJECTED" "$AUGMENTED" | jq -c '[.[] | select(.label=="repo-lint-local") | .result]')
if [ "$GOT" = '["MISSING"]' ]; then
  pass "end-to-end: an annex check that never started blocks as MISSING, not silently passing (round 2 P2)"
else
  fail "end-to-end (missing annex): expected [\"MISSING\"], got $GOT"
fi

ROLLUP_SKIPPED_ANNEX='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"SKIPPED"}]}'
GOT=$(bad_checks "$ROLLUP_SKIPPED_ANNEX" "$AUGMENTED" | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end: a SKIPPED annex check (job-level conditional) does not block, consistent with SUCCESS/SKIPPED/NEUTRAL elsewhere"
else
  fail "end-to-end (skipped annex): expected [] (non-blocking), got $GOT"
fi

# Pre-round-1-fix regression guard: without any annex awareness at all, a
# red conventional-named annex check was invisible to the filter.
GOT=$(bad_checks "$ROLLUP_RED_ANNEX" '["lint"]' | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "confirms the pre-#655 bug shape: without annex awareness, a red repo-lint-local is invisible to BAD_CHECKS"
else
  fail "expected the unaugmented filter to reproduce the pre-#655 miss ([]), got $GOT"
fi

echo ""
echo "test_codex_review_check_required_checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
