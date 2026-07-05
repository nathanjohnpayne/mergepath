#!/usr/bin/env bash
# tests/test_codex_review_check_required_checks.sh
#
# Regression coverage for gate (a)'s required-check scoping in
# scripts/codex-review-check.sh (#655): when branch protection lists SOME
# required checks (the common case), gate (a) narrows its "must be green"
# scrutiny to that list — so a check present in the rollup but NOT in the
# required list (e.g. a consumer's optional, never-propagated #601
# repo_lint_local.yml annex, whose check run is named `repo-lint-local`) is
# silently excluded, even when it is red. Branch protection cannot require
# it centrally — the annex is per-consumer and never propagated, so there is
# no canonical PR to add it fleet-wide (that half is a human branch-
# protection change; see #655). This closes the agent-doable half: force
# `repo-lint-local` into the required set whenever the rollup actually
# reports it, independent of what branch protection lists.
#
# The full gate (a) needs network (statusCheckRollup + branch-protection API
# reads); this test pins (1) the structural presence of the force-include in
# the real script and (2) the augmentation jq logic inline — the same
# inline-literal pattern test_codex_review_check_verdict.sh and
# test_codex_review_check_resolution.sh use. KEEP THE INLINE FILTER BELOW IN
# SYNC with the REQUIRED_JSON augmentation in scripts/codex-review-check.sh.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review-check.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── 1. Structural: the real script force-includes repo-lint-local into the
#      required-check set, referenced to #655, inside the non-empty
#      required-names branch (the "no required checks configured" and
#      "protection unreadable" branches already consider every check).
if grep -q 'repo-lint-local' "$SCRIPT" \
   && grep -q "#655" "$SCRIPT"; then
  pass "codex-review-check.sh gate (a) references the repo-lint-local force-include (#655)"
else
  fail "codex-review-check.sh gate (a) is missing the repo-lint-local force-include (#655)"
fi

# ── 2. Inline logic: the REQUIRED_JSON augmentation. KEEP IN SYNC with the
#      jq filter in scripts/codex-review-check.sh's non-empty required-names
#      branch. Force-includes repo-lint-local iff the rollup reports it (by
#      .name OR .context, matching statusCheckRollup's two entry shapes),
#      leaves the required set untouched otherwise, and never duplicates an
#      entry branch protection already lists.
augment() {
  local required_names_json=$1 rollup_json=$2
  printf '%s' "$required_names_json" | jq --argjson rollup "$rollup_json" '
    if ([$rollup.statusCheckRollup[]? | (.name // .context // "")] | index("repo-lint-local")) != null
    then . + ["repo-lint-local"] | unique
    else .
    end
  '
}

ROLLUP_WITH_LOCAL='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"FAILURE"}]}'
ROLLUP_NO_LOCAL='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"}]}'
ROLLUP_CONTEXT_SHAPE='{"statusCheckRollup":[{"context":"repo-lint-local","state":"FAILURE"}]}'

GOT=$(augment '["lint"]' "$ROLLUP_WITH_LOCAL" | jq -c 'sort')
if [ "$GOT" = '["lint","repo-lint-local"]' ]; then
  pass "annex present (.name shape) -> repo-lint-local is force-included in the required set"
else
  fail "annex present (.name shape): expected [\"lint\",\"repo-lint-local\"], got $GOT"
fi

GOT=$(augment '["lint"]' "$ROLLUP_NO_LOCAL" | jq -c 'sort')
if [ "$GOT" = '["lint"]' ]; then
  pass "annex absent -> required set is untouched (no consumer regression)"
else
  fail "annex absent: expected [\"lint\"] unchanged, got $GOT"
fi

GOT=$(augment '["lint"]' "$ROLLUP_CONTEXT_SHAPE" | jq -c 'sort')
if [ "$GOT" = '["lint","repo-lint-local"]' ]; then
  pass "annex present (.context shape -- commit-status entries) -> still force-included"
else
  fail "annex present (.context shape): expected [\"lint\",\"repo-lint-local\"], got $GOT"
fi

GOT=$(augment '["lint","repo-lint-local"]' "$ROLLUP_WITH_LOCAL" | jq -c 'sort')
if [ "$GOT" = '["lint","repo-lint-local"]' ]; then
  pass "already-required (a future branch-protection addition) -> no duplicate entry"
else
  fail "already-required: expected no duplicate, got $GOT"
fi

# ── 3. End-to-end BAD_CHECKS filter: a red repo-lint-local now surfaces as a
#      bad check even though it is absent from the required list, mirroring
#      the exact filter shape codex-review-check.sh applies after
#      augmentation (workflow/Label Gate exclusion, required-names scoping,
#      non-green selection). KEEP IN SYNC with the BAD_CHECKS filter in the
#      real script.
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

AUGMENTED=$(augment '["lint"]' "$ROLLUP_WITH_LOCAL")
GOT=$(bad_checks "$ROLLUP_WITH_LOCAL" "$AUGMENTED" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "a red repo-lint-local surfaces in BAD_CHECKS once force-included (gate (a) now blocks on it)"
else
  fail "expected BAD_CHECKS=[\"repo-lint-local\"], got $GOT"
fi

# Pre-fix regression guard: WITHOUT the augmentation (required list stays
# just branch protection's own list), the same red repo-lint-local is
# invisible to the filter — this is the #655 bug this PR fixes.
GOT=$(bad_checks "$ROLLUP_WITH_LOCAL" '["lint"]' | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "confirms the #655 bug shape: without force-include, a red repo-lint-local is invisible to BAD_CHECKS"
else
  fail "expected the unaugmented filter to reproduce the #655 miss ([]), got $GOT"
fi

echo ""
echo "test_codex_review_check_required_checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
