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
# agent-doable half across ten rounds of Codex findings; only the
# architecturally-significant ones are summarized here (see git history /
# PR #687 for the full round-by-round detail):
#
#   Rounds 1-4: force-include the annex's check into gate (a)'s scrutiny
#   (including when branch protection requires nothing at all), derive its
#   real job name(s) instead of assuming the "repo-lint-local" filename
#   convention, skip matrix-strategy jobs during name derivation (their
#   expanded names cannot be predicted), and distinguish a persistent 403
#   from a transient probe error.
#
#   Round 5 (superseding rounds 2-4's MISSING-injection approach): rounds
#   2-4 forced a synthetic MISSING requirement for a derived check name
#   that had not yet reported, which turns into a PERMANENT deadlock for a
#   persistent 403, an all-matrix annex, or a path-filtered annex that
#   legitimately never runs for a given diff. Replaced with a workflow-wide
#   scan: any REPORTED entry belonging to the annex's own workflow (matched
#   by .workflowName, not by a specific check name) that is non-green is
#   unioned into BAD_CHECKS directly -- catching a matrix-leg failure
#   without its expanded name, and never inventing a requirement for a
#   check that may never report.
#
#   Rounds 6-9: fold in an omitted top-level `name:` (falls back to the
#   workflow file path GitHub itself displays), allow YAML aliases in the
#   annex (bounded by size/token-count DoS guards against "billion
#   laughs", refined twice more to stop over-counting quoted and hyphenated
#   path globs as alias tokens), and treat an annex with no restricting
#   trigger filter (paths/paths-ignore/branches/branches-ignore, and a
#   pull_request `types` list that still includes synchronize) as
#   guaranteed to eventually report -- so zero reported entries blocks
#   (not-yet-clean) instead of silently passing, including for a
#   same-repo-gated push-only annex (a push trigger never fires in this
#   repo for a fork PR).
#
#   Round 10: removed the annex-derived-name merge into REQUIRED_JSON
#   entirely (both the empty- and non-empty-required-checks branches) --
#   that merge was name-only, so a consumer whose annex job happened to
#   share a bare name with an unrelated, non-required check from a
#   DIFFERENT workflow would make that unrelated check mandatory too,
#   wrongly blocking gate (a) with a fully green annex. The workflow-wide
#   scan (round 5) already independently and safely enforces the annex by
#   workflow identity, immune to this collision, so no merge is needed at
#   all any more. Also added a conventional-name (not workflow-based, since
#   the real identity is unknown) fallback scan for when the annex probe
#   cannot determine a workflow identity at all (403 / unparseable /
#   indeterminate error) -- catching a REPORTED bad conclusion under the
#   literal name "repo-lint-local" without requiring its presence, so a
#   persistent 403 still cannot deadlock the gate.
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
   && grep -q 'workflow_name = doc\["name"\] ? doc\["name"\].to_s : "\.github/workflows/repo_lint_local\.yml"' "$SCRIPT" \
   && grep -q 'ANNEX_WORKFLOW_BAD' "$SCRIPT" \
   && grep -q "#655" "$SCRIPT"; then
  pass "codex-review-check.sh gate (a) probes the annex, derives (name, workflow) pairs plus the annex workflow name, and scans it for reported failures (#655)"
else
  fail "codex-review-check.sh gate (a) is missing the annex probe / (name, workflow) derivation / workflow-wide bad-conclusion scan (#655)"
fi

# Codex P2 (#655 round 6, "use the file path when the annex omits name"):
# an all-matrix annex with no top-level `name:` used to yield an EMPTY
# workflow name, disabling the workflow-wide scan entirely even though the
# annex genuinely exists and reports real check runs under GitHub's own
# file-path display fallback. Verify the fallback and its trigger condition
# (doc["name"] falsy) are both present, not just a change to some other line.
if grep -q 'doc\["name"\] ? doc\["name"\].to_s : "\.github/workflows/repo_lint_local\.yml"' "$SCRIPT"; then
  pass "codex-review-check.sh falls back to the workflow file path when the annex omits a top-level name: key (#655 round 6)"
else
  fail "codex-review-check.sh does not fall back to the workflow file path when the annex's name: key is absent (#655 round 6)"
fi

# Codex P1 (#655 round 7, "keep rollup when annex only has matrix jobs"):
# an all-matrix annex has an empty ANNEX_CHECK_NAMES_JSON but a populated
# ANNEX_WORKFLOW_NAME. The empty-required-checks branch used to key ONLY on
# ANNEX_CHECK_NAMES_JSON's length to decide whether to wipe ROLLUP_JSON to
# `[]`, so an all-matrix annex took the "no annex" path and the workflow-
# wide scan below lost its data source, hiding a reported matrix-leg
# failure. Fixed by freezing a copy of the rollup BEFORE any
# branch-protection-driven wiping can touch it, and pointing the
# workflow-wide scan at that frozen copy instead of the (possibly wiped)
# $ROLLUP_JSON -- decoupling the two consumers entirely rather than trying
# to special-case the wiping branch.
if grep -q 'ANNEX_SCAN_ROLLUP_JSON="\$ROLLUP_JSON"' "$SCRIPT" \
   && grep -q 'ANNEX_WORKFLOW_MATCHES=\$(echo "\$ANNEX_SCAN_ROLLUP_JSON"' "$SCRIPT"; then
  pass "codex-review-check.sh freezes a pristine rollup copy for the workflow-wide scan, immune to later required-checks-driven wiping (#655 round 7)"
else
  fail "codex-review-check.sh's workflow-wide scan is not decoupled from ROLLUP_JSON wiping (#655 round 7)"
fi
# The frozen copy must be taken BEFORE the empty-required-checks branch's
# wipe, not after -- grep the line numbers to guard against a future edit
# reordering them back into the bug.
freeze_line=$(grep -n 'ANNEX_SCAN_ROLLUP_JSON="\$ROLLUP_JSON"' "$SCRIPT" | head -1 | cut -d: -f1)
wipe_line=$(grep -n "ROLLUP_JSON='{\"statusCheckRollup\":\[\]}'" "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$freeze_line" ] && [ -n "$wipe_line" ] && [ "$freeze_line" -lt "$wipe_line" ]; then
  pass "codex-review-check.sh freezes the annex-scan rollup copy before the empty-required-checks branch's wipe, not after (#655 round 7)"
else
  fail "codex-review-check.sh's frozen rollup copy is not positioned before the wipe (freeze_line=$freeze_line wipe_line=$wipe_line)"
fi

# Codex P1 (#655 round 7, "parse valid annex workflows that use YAML
# aliases"): GitHub Actions supports YAML anchors/aliases in workflow
# files, but Psych safe_load's aliases:false default rejected any alias
# and treated the whole annex as unparseable. Allowing aliases outright
# would reopen a YAML alias-expansion ("billion laughs") DoS against the
# script parsing a PR's own branch content -- guarded here with a byte-size
# cap and a raw anchor/alias token-count cap, both checked BEFORE the
# actual parse (the danger is in the expansion, not the input size).
if grep -q 'doc = YAML.safe_load(raw, aliases: true)' "$SCRIPT" \
   && grep -q 'if raw.bytesize > 100_000' "$SCRIPT"; then
  pass "codex-review-check.sh allows YAML aliases when parsing the annex, bounded by a byte-size DoS guard (#655 round 7)"
else
  fail "codex-review-check.sh does not allow YAML aliases with the expected byte-size DoS guard (#655 round 7)"
fi

# Codex P2 (#655 round 8, "avoid treating path globs as YAML aliases") and
# round 9 ("do not count glob hyphens as YAML aliases"): the round-7
# token-count guard's naive `[&*]word` scan counted an ordinary glob like
# `**/*.ts` (round 8) or a hyphenated one like `component-*.ts` (round 9,
# since a bare trailing `-` was accepted as a structural position ANYWHERE
# in the text) as alias tokens -- a legitimate annex with a longer or
# hyphenated filter list could exceed the cap and be treated as
# too-dangerous-to-parse, disabling the workflow-wide scan for a real,
# currently-failing local check. The guard now requires a structural
# position -- start of text; a block-sequence dash anchored to the START
# OF ITS LINE with a mandatory space before its value (round 9's fix,
# excluding a mid-string hyphen like a glob own); or `:`/`,`/`[`/`{`
# anywhere, optionally followed by whitespace -- before counting a token,
# which a quoted (or otherwise validly-unquoted) glob string never
# satisfies.
if grep -qF 'if raw.scan(/(?:\A|^[ \t]*-\s+|[:,\[{]\s*)[&*][A-Za-z0-9_.-]+/).length > 40' "$SCRIPT"; then
  pass "codex-review-check.sh's alias token-count guard requires a line-anchored dash (or other structural position), no longer over-counting quoted or hyphenated path globs (#655 rounds 8-9)"
else
  fail "codex-review-check.sh's alias token-count guard does not use the round-9 line-anchored-dash regex (#655 round 9)"
fi

# Codex P2 (#655 round 8, "wait for unreported unfiltered annex checks"):
# gate (a)'s workflow-wide scan previously treated ANY zero-match case as
# non-blocking, which was too lenient for an annex whose trigger is
# guaranteed to eventually report. A synthetic PENDING entry is unioned
# into BAD_CHECKS in that specific case, mirroring how an in-progress
# entry already blocks (round 6).
if grep -q 'ANNEX_UNFILTERED' "$SCRIPT" \
   && grep -q 'ANNEX_WORKFLOW_MATCH_COUNT' "$SCRIPT" \
   && grep -q '(not yet reported)' "$SCRIPT"; then
  pass "codex-review-check.sh's workflow-wide scan blocks on an unfiltered annex with zero reported entries instead of silently passing (#655 round 8)"
else
  fail "codex-review-check.sh does not treat an unfiltered zero-match annex as not-yet-clean (#655 round 8)"
fi

# Codex P2 (#655 round 9, "honor non-path pull_request filters before
# waiting"): round 8 checked only paths/paths-ignore on the pull_request
# config. branches/branches-ignore must also disqualify "unfiltered"
# alongside paths/paths-ignore (types is handled separately below, since
# round 10 found it needs different treatment).
if grep -qF 'pr_filter_keys = ["paths", "paths-ignore", "branches", "branches-ignore"]' "$SCRIPT"; then
  pass "codex-review-check.sh disqualifies unfiltered on branches/branches-ignore, alongside paths/paths-ignore (#655 round 9)"
else
  fail "codex-review-check.sh does not check the branches/branches-ignore filter keys (#655 round 9)"
fi

# Codex P1 (#655 round 10, "treat synchronize-enabled types as runnable"):
# round 9 disqualified "unfiltered" on the MERE PRESENCE of a types key,
# but types selects WHICH pull_request activities trigger the workflow at
# all (GitHub own default when omitted is [opened, synchronize,
# reopened]) rather than narrowing by path/branch. An explicit
# `types: [opened, synchronize, reopened]` -- functionally identical to
# omitting types -- was wrongly disqualified. Only a types list that
# EXCLUDES synchronize should disqualify, since that is the activity that
# fires for a resynchronized PRs current HEAD.
if grep -qF 'next (cfg["types"].is_a?(Array) && cfg["types"].include?("synchronize")) if cfg.key?("types")' "$SCRIPT"; then
  pass "codex-review-check.sh treats a types list that includes synchronize as unfiltered, not merely absent (#655 round 10)"
else
  fail "codex-review-check.sh still disqualifies unfiltered on the mere presence of a types key (#655 round 10)"
fi

# Codex P1 (#655 round 10, "fail closed when the annex probe is
# unauthorized"): a 403 (or genuinely-unparseable annex, or indeterminate
# error) leaves ANNEX_WORKFLOW_NAME empty, so the workflow-wide scan above
# cannot run at all -- silently passing gate (a) regardless of the
# annex's real state, even for a check already reporting red under the
# conventional name outside branch protection. A name-based (not
# workflow-based, since the real identity is unknown) fallback scan now
# catches a REPORTED bad conclusion under the literal name
# "repo-lint-local" in these cases, without requiring its presence (so a
# persistent 403 still cannot deadlock the gate).
annex_name_fallback_bad() {
  local rollup_json=$1
  printf '%s' "$rollup_json" | jq '
    [.statusCheckRollup[]
      | select((.name // .context // "") == "repo-lint-local")
      | { label: (.name // .context // "?"), workflow: (.workflowName // ""), result: (.conclusion // .state // "") }
      | select((.result != "SUCCESS") and (.result != "SKIPPED") and (.result != "NEUTRAL"))
    ]'
}
ROLLUP_403_RED_CONVENTIONAL='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"Consumer Local CI","conclusion":"FAILURE"}]}'
GOT=$(annex_name_fallback_bad "$ROLLUP_403_RED_CONVENTIONAL" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "conventional-name fallback scan: a red repo-lint-local is caught even when the workflow identity is unknown (#655 round 10 P1)"
else
  fail "conventional-name fallback scan (403 case): expected [\"repo-lint-local\"], got $GOT"
fi
ROLLUP_403_NO_ANNEX='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"}]}'
GOT=$(annex_name_fallback_bad "$ROLLUP_403_NO_ANNEX")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "conventional-name fallback scan: a genuinely absent annex is not falsely flagged (no repo-lint-local entry to find)"
else
  fail "conventional-name fallback scan (no annex): expected 0, got $GOT"
fi
if grep -qF 'ANNEX_NAME_FALLBACK_BAD=$(echo "$ANNEX_SCAN_ROLLUP_JSON" | jq' "$SCRIPT"; then
  pass "codex-review-check.sh's conventional-name fallback scan reads from the frozen ANNEX_SCAN_ROLLUP_JSON, immune to required-checks-driven wiping (#655 round 10)"
else
  fail "codex-review-check.sh's conventional-name fallback scan is missing or reads from the wrong rollup variable (#655 round 10)"
fi

# Codex P2 (#655 round 9, "wait for valid push-only annex workflows"):
# check_ci_scripts_wired accepts push OR pull_request as valid annex
# wiring, but a push-only annex (no pull_request trigger at all) was never
# classified as unfiltered, so gate (a) never waited for it even though it
# is a contractually valid annex. A push trigger only fires IN THIS REPO
# for a same-repo PR (a fork PRs push lands in the fork, never here), so
# this is gated on ANNEX_SAME_REPO_PR (derived from the PR REST object
# head/base repo full_name, no extra API call) rather than applied
# unconditionally.
if grep -qF 'ANNEX_SAME_REPO_PR=$(echo "$PR_JSON" | jq -r' "$SCRIPT" \
   && grep -qF 'push_unfiltered = trigger_unfiltered.call("push", push_filter_keys)' "$SCRIPT" \
   && grep -qF 'unfiltered = pr_unfiltered || (push_unfiltered && same_repo_pr)' "$SCRIPT"; then
  pass "codex-review-check.sh treats a push-only annex as unfiltered when (and only when) the PR is same-repo (#655 round 9)"
else
  fail "codex-review-check.sh does not gate push-only annex enforcement on same-repo-PR status (#655 round 9)"
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

# ── 2. Inline logic: the REQUIRED_JSON branches. Rounds 1-9 merged the
#      annex's derived bare name(s) into REQUIRED_JSON so it would be
#      force-checked even when branch protection required nothing (empty
#      branch) or required only OTHER checks (non-empty branch). Round 10
#      Codex P2 ("preserve workflow identity for annex checks") found this
#      merge is name-only (no workflow disambiguation, unlike the
#      workflow-wide scan in section 3), so a consumer whose annex job
#      shares a bare name with an unrelated, non-required check from a
#      DIFFERENT workflow would make that unrelated check mandatory too --
#      a failing unrelated check could block gate (a) with a fully green
#      annex. Since the workflow-wide scan already independently and
#      safely enforces the annex (matched by .workflowName, immune to name
#      collisions), the merge was removed entirely in both branches: the
#      empty branch now always wipes ROLLUP_JSON (matching the pre-#655
#      no-annex behavior), and the non-empty branch uses branch
#      protection's required names alone, with no annex merge.
#      KEEP IN SYNC with scripts/codex-review-check.sh's gate (a).

if grep -qF 'REQUIRED_JSON=$(echo "$REQUIRED_CHECK_NAMES" | jq -R . | jq -s .)' "$SCRIPT" \
   && ! grep -qF '. + $annex | unique' "$SCRIPT"; then
  pass "codex-review-check.sh's non-empty-required branch no longer merges the annex bare name into REQUIRED_JSON (#655 round 10)"
else
  fail "codex-review-check.sh's non-empty-required branch still merges the annex name into REQUIRED_JSON, risking a same-named unrelated-check false block (#655 round 10)"
fi

if grep -qF "gate (a) imposes no required-check filter beyond the independent annex workflow-wide scan" "$SCRIPT"; then
  pass "codex-review-check.sh's empty-required branch always wipes the rollup now, relying on the independent workflow-wide scan for annex enforcement (#655 round 10)"
else
  fail "codex-review-check.sh's empty-required branch does not consistently defer to the workflow-wide scan (#655 round 10)"
fi

# End-to-end: reproduce Finding 2's exact scenario with the real
# (post-round-10) non-empty-branch construction -- branch protection
# already requires "lint", and the annex's OWN job is ALSO named "lint"
# (a name collision the annex contract explicitly permits). REQUIRED_JSON
# built the round-10 way (no annex merge) must stay ["lint"], so an
# unrelated FAILING check sharing that name from a different workflow does
# not matter -- only the CANONICAL lint (matched further down by BAD_CHECKS
# using $required_names) is in scope for the name-based filter, and the
# annex itself is separately covered by the workflow-wide scan regardless
# of what name it happens to share.
REQUIRED_JSON_ROUND10=$(printf 'lint' | jq -R . | jq -s .)
if [ "$(echo "$REQUIRED_JSON_ROUND10" | jq -c 'sort')" = '["lint"]' ]; then
  pass "non-empty branch (round 10): REQUIRED_JSON stays scoped to branch-protection names alone, even when the annex job shares one of those names"
else
  fail "non-empty branch (round 10): expected REQUIRED_JSON [\"lint\"] with no annex merge, got $REQUIRED_JSON_ROUND10"
fi

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

# #655 round 7 Codex P1 ("keep rollup when annex only has matrix jobs"):
# reproduces the exact bug shape -- branch protection has NO required
# checks (which post-round-10 always wipes ROLLUP_JSON unconditionally,
# per the section-2 assertion above) while the annex genuinely exists as
# all-matrix and has a REPORTED matrix-leg failure. The fixed script scans
# a rollup frozen BEFORE that wipe (ANNEX_SCAN_ROLLUP_JSON in the real
# script; simulated here by passing the ORIGINAL rollup straight to
# annex_workflow_bad, exactly as the fix does) -- confirming the failure
# is still caught even with ROLLUP_JSON wiped and REQUIRED_JSON empty.
GOT=$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex" | jq -c '[.[].label]')
if [ "$GOT" = '["checks (20)"]' ]; then
  pass "workflow-wide scan: an all-matrix annex's reported leg failure is still caught when branch protection has no required checks (#655 round 7 P1)"
else
  fail "workflow-wide scan (round-7 all-matrix + no required checks): expected [\"checks (20)\"], got $GOT"
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

# #655 round 8 Codex P2 ("wait for unreported unfiltered annex checks"):
# refines the round-5 "never reported -> not blocking" rule above. When
# the annex's pull_request trigger is unfiltered (guaranteed to
# eventually report), zero matches means "not scheduled yet", not "may
# never run" -- a synthetic PENDING entry is unioned in instead of
# silently passing. KEEP IN SYNC with scripts/codex-review-check.sh's
# ANNEX_WORKFLOW_MATCHES / unfiltered-zero-match branch.
annex_workflow_bad_or_pending() {
  local rollup_json=$1 workflow=$2 unfiltered=$3
  local match_count
  match_count=$(printf '%s' "$rollup_json" | jq --arg workflow "$workflow" '[.statusCheckRollup[] | select((.workflowName // "") == $workflow)] | length')
  if [ "$match_count" -eq 0 ] && [ "$unfiltered" = "true" ]; then
    jq -n --arg workflow "$workflow" '[{label: "(not yet reported)", workflow: $workflow, result: "PENDING"}]'
  else
    annex_workflow_bad "$rollup_json" "$workflow"
  fi
}

GOT=$(annex_workflow_bad_or_pending "$ROLLUP_NEVER_REPORTED" "consumer-annex" "true" | jq -c '[.[].result]')
if [ "$GOT" = '["PENDING"]' ]; then
  pass "workflow-wide scan: an unfiltered annex that never reported anything is treated as not-yet-clean, not silently passed (#655 round 8 P2)"
else
  fail "workflow-wide scan (unfiltered, never reported): expected [\"PENDING\"], got $GOT"
fi

GOT=$(annex_workflow_bad_or_pending "$ROLLUP_NEVER_REPORTED" "consumer-annex" "false")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a path-filtered (unfiltered=false) annex that never reported anything is still NOT blocking, preserving round 5 (#655 round 8)"
else
  fail "workflow-wide scan (path-filtered, never reported): expected 0 (round-5 behavior preserved), got $GOT"
fi

GOT=$(annex_workflow_bad_or_pending "$ROLLUP_ANNEX_REPORTED_GOOD" "repo-lint-local" "true")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: an unfiltered annex that HAS reported green is not treated as pending (real reports still win)"
else
  fail "workflow-wide scan (unfiltered, reported green): expected 0, got $GOT"
fi

# ── 4. End-to-end: union of the required-name-scoped BAD_CHECKS and the
#      workflow-wide scan, mirroring how the real script merges them
#      before computing BAD_COUNT. Post-round-10, REQUIRED_JSON is JUST
#      branch protection's own required names (BRANCH_PROTECTION_NAMES
#      below) -- the annex is no longer merged into it, so the name-scoped
#      filter alone can no longer see the annex AT ALL (whether
#      conventional-named or matrix-leg); the workflow-wide scan is the
#      SOLE annex-enforcement path now, unconditionally, regardless of
#      REQUIRED_JSON. This is the intended fix for Finding 2's
#      name-collision risk, not a regression: it means a same-named
#      unrelated check (allowed by the annex contract) can never stand in
#      for -- or be wrongly blocked by -- the annex.
BRANCH_PROTECTION_NAMES='["lint"]'
GOT=$(bad_checks "$ROLLUP_ANNEX_REPORTED_BAD" "$BRANCH_PROTECTION_NAMES" | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end: the name-scoped filter alone no longer sees a red conventional-named annex check post-round-10 (workflow-wide scan is the sole path now)"
else
  fail "end-to-end (red conventional, name-scoped alone): expected [] (annex no longer name-merged), got $GOT"
fi
UNIONED_CONVENTIONAL=$(echo "$(bad_checks "$ROLLUP_ANNEX_REPORTED_BAD" "$BRANCH_PROTECTION_NAMES")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_ANNEX_REPORTED_BAD" "repo-lint-local")" '(. + $extra) | unique')
GOT=$(echo "$UNIONED_CONVENTIONAL" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "end-to-end: unioning the workflow-wide scan catches a red conventional-named annex check the name-scoped filter alone now misses (#655 round 10)"
else
  fail "end-to-end (red conventional, unioned): expected [\"repo-lint-local\"], got $GOT"
fi

# The matrix-leg failure was ALREADY invisible to the name-scoped filter
# even before round 10 (its required_names never contained the expanded
# "checks (20)"); unioning the workflow-wide scan still catches it.
GOT=$(bad_checks "$ROLLUP_MATRIX_LEG_FAILED" "$BRANCH_PROTECTION_NAMES" | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end: confirms the matrix-leg failure is invisible to the name-scoped filter alone"
else
  fail "end-to-end (matrix leg, name-scoped only): expected [] (invisible without the workflow scan), got $GOT"
fi
UNIONED=$(echo "$(bad_checks "$ROLLUP_MATRIX_LEG_FAILED" "$BRANCH_PROTECTION_NAMES")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex")" '(. + $extra) | unique')
GOT=$(echo "$UNIONED" | jq -c '[.[].label]')
if [ "$GOT" = '["checks (20)"]' ]; then
  pass "end-to-end: unioning the workflow-wide scan catches the matrix-leg failure the name-scoped filter alone misses (#655 round 5)"
else
  fail "end-to-end (matrix leg, unioned): expected [\"checks (20)\"], got $GOT"
fi

ROLLUP_SKIPPED_ANNEX='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"SKIPPED"}]}'
UNIONED_SKIPPED=$(echo "$(bad_checks "$ROLLUP_SKIPPED_ANNEX" "$BRANCH_PROTECTION_NAMES")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_SKIPPED_ANNEX" "repo-lint-local")" '(. + $extra) | unique')
GOT=$(echo "$UNIONED_SKIPPED" | jq -c '[.[].label]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end: a SKIPPED annex check (job-level conditional) does not block, consistent with SUCCESS/SKIPPED/NEUTRAL elsewhere"
else
  fail "end-to-end (skipped annex): expected [] (non-blocking), got $GOT"
fi

# Finding 2's EXACT scenario reproduced end-to-end: branch protection
# requires ONLY "lint". The annex's OWN job happens to be named "test"
# (the annex contract does not require unique job names). An UNRELATED,
# non-required check from a completely different workflow COINCIDENTALLY
# also happens to be named "test" and is red -- pre-round-10, merging the
# annex's derived name ("test") into REQUIRED_JSON would have made this
# unrelated check "required" too, wrongly blocking gate (a) with a fully
# green annex. Post-round-10 (no merge), required_names stays ["lint"]
# alone, so neither "test"-named check is in scope for the name-based
# filter at all -- but the ANNEX's own "test" job is STILL correctly
# caught if red, via the workflow-wide scan matching by workflow identity
# (immune to the name collision the unrelated check shares).
ROLLUP_NAME_COLLISION='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"test","workflowName":"Consumer Annex","conclusion":"FAILURE"},{"name":"test","workflowName":"Some Unrelated Optional Workflow","conclusion":"FAILURE"}]}'
GOT=$(bad_checks "$ROLLUP_NAME_COLLISION" "$BRANCH_PROTECTION_NAMES" | jq -c '[.[].workflow]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end (Finding 2): the name-scoped filter alone does not see EITHER same-named 'test' check, since neither is in required_names post-round-10"
else
  fail "end-to-end (Finding 2, name-scoped alone): expected [] (no annex-name merge to widen scope), got $GOT"
fi
GOT=$(annex_workflow_bad "$ROLLUP_NAME_COLLISION" "Consumer Annex" | jq -c '[.[].workflow]')
if [ "$GOT" = '["Consumer Annex"]' ]; then
  pass "end-to-end (Finding 2): the workflow-wide scan still catches the annex's own red 'test' job, unconfused by the unrelated same-named check"
else
  fail "end-to-end (Finding 2, workflow-wide scan): expected [\"Consumer Annex\"] only (not the unrelated same-named check), got $GOT"
fi
GOT=$(annex_workflow_bad "$ROLLUP_NAME_COLLISION" "Some Unrelated Optional Workflow" | jq -c '[.[].workflow]')
if [ "$GOT" = '["Some Unrelated Optional Workflow"]' ]; then
  pass "end-to-end (Finding 2 sanity): the unrelated workflow's own red check would ONLY surface if IT were the scanned workflow, confirming the scan is workflow-scoped not name-scoped"
else
  fail "end-to-end (Finding 2 sanity): expected the unrelated workflow scan to only see its own entry, got $GOT"
fi

echo ""
echo "test_codex_review_check_required_checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
