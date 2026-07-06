#!/usr/bin/env bash
# tests/test_655_repo_lint_local_observed.sh
#
# Structural regression guard for #655: a consumer's optional, never-
# propagated repo_lint_local.yml annex (#601) produces a `repo-lint-local`
# check run that branch protection does not require. Before this fix,
# neither the native auto-merge path (agent-review.yml's "Require current-
# head check success" step, hardcoded to the single `lint` check) nor the
# needs-external-review label-clearing re-evaluation trigger
# (auto-clear-blocking-labels.yml's workflow_run list) observed it, so a
# consumer could auto-merge or auto-clear with local checks red. (The
# third, deepest site — codex-review-check.sh gate (a), the script BOTH of
# these ultimately rely on for "is CI green" — has its own execution-level
# test in test_codex_review_check_required_checks.sh.)
#
# Round 6 (Codex P1/P2) rewrote how agent-review.yml enforces the annex:
# rather than forcing its derived check name(s) into the hard-required
# required_checks_json list (which deadlocked the wait loop forever on a
# path-filtered or all-matrix annex that would never report under any
# derivable name), it now captures the annex's own workflow name
# (annex_workflow) and runs a separate workflow-wide bad/pending scan each
# poll iteration — the same design codex-review-check.sh gate (a) already
# uses for the identical reason.
#
# The workflow files here cannot be unit-executed without a full Actions
# runner (same posture as test_465_fail_closed.sh), so this suite asserts
# each invariant is present in source, plus a bash-syntax check on every
# agent-review.yml `run:` block (auto-clear-blocking-labels.yml already has
# its own equivalent syntax check in scripts/ci/check_auto_clear_workflow).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

SKIP=0
# Propagation-safe: a consumer that does not carry a given workflow simply
# has nothing to regress, so skip (not fail) when the file is absent.
assert_grep() {  # <label> <file> <fixed-string>
  if [ ! -f "$2" ]; then echo "SKIP: $1 ($2 absent)"; SKIP=$((SKIP + 1)); return; fi
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing in $2: $3)"; fi
}
# Inverse of assert_grep: asserts a string is ABSENT, for regressions that
# are fixed by removing a dangerous pattern rather than adding a new one.
assert_not_grep() {  # <label> <file> <fixed-string>
  if [ ! -f "$2" ]; then echo "SKIP: $1 ($2 absent)"; SKIP=$((SKIP + 1)); return; fi
  if grep -qF -- "$3" "$2"; then fail "$1 (unexpectedly present in $2: $3)"; else pass "$1"; fi
}

W=.github/workflows

# agent-review.yml: the required-check wait probes the PR HEAD commit for
# the annex file via the Contents API (not the job's own checkout) and
# conditionally scans its check run(s) alongside lint.
assert_grep "agent-review: probes for the repo_lint_local.yml annex at the PR HEAD commit (#655)" \
  "$W/agent-review.yml" 'repos/$REPO/contents/.github/workflows/repo_lint_local.yml?ref=$sha'
assert_grep "agent-review: the wait loop iterates over the required_checks_json array, not one hardcoded name" \
  "$W/agent-review.yml" 'for ((i = 0; i < check_count; i++)); do'

# Codex P2 (#655 round 6, "avoid forcing path-filtered annex jobs to
# start"): a consumer annex scoped by workflow-level paths/paths-ignore
# legitimately never reports under ANY derived name for an out-of-scope
# PR, so forcing one into required_checks_json (rounds 4-5's approach)
# made this loop wait out the full deadline and refuse auto-merge forever.
# required_checks_json must stay scoped to only the canonical check;
# annex enforcement moves to a name-free workflow-wide scan instead.
assert_grep "agent-review: required_checks_json stays scoped to only the canonical check (#655 round 6)" \
  "$W/agent-review.yml" 'required_checks_json stays scoped to ONLY the canonical'
assert_not_grep "agent-review: no longer force-injects a derived/fallback name into required_checks_json (#655 round 6)" \
  "$W/agent-review.yml" 'repo-lint-local", workflow: ""'
assert_grep "agent-review: captures the annex's own workflow name for the separate workflow-wide scan" \
  "$W/agent-review.yml" 'annex_workflow=$(echo "$annex_probe_raw" | jq -r '"'"'.workflow'"'"')'

# Codex P1 (#655 round 1): an indeterminate annex-probe read (token scope,
# rate limit, transient error) must not be silently treated the same as a
# confirmed 404 absence. Round 6 narrowed HOW this is handled (see above:
# forcing a guessed name here would risk the same deadlock removed from
# required_checks_json), but it must still be logged distinctly from a
# confirmed 404, and codex-review-check.sh's gate (a) remains the
# fail-closed backstop for this same annex on its own re-evaluation
# schedule.
assert_grep "agent-review: distinguishes a confirmed 404 (annex genuinely absent) from other errors" \
  "$W/agent-review.yml" "grep -q 'HTTP 404' \"\$annex_probe_err\""
assert_grep "agent-review: logs (but no longer force-enforces) an indeterminate non-404 annex-probe error, deferring to gate (a) (#655 round 6)" \
  "$W/agent-review.yml" 'Could not determine whether repo_lint_local.yml exists'

# Codex P2 (#655 round 1): the annex contract does not mandate the job (and
# therefore check-run) name be literally repo-lint-local, so the probe
# derives the actual job name(s) from the annex YAML instead of assuming
# the filename convention.
assert_grep "agent-review: derives the annex job name(s) from its YAML rather than assuming the filename" \
  "$W/agent-review.yml" 'doc["jobs"].each do |id, job|'

# Codex P2 (#655 round 6, "use the file path when the annex omits name"):
# GitHub displays (and reports into statusCheckRollup .workflowName as) the
# workflow FILE PATH when the top-level `name:` key is omitted, not an
# empty string. An empty workflow_name would disable the workflow-wide
# scan below entirely, even for a valid annex with reported job failures.
assert_grep "agent-review: falls back to the workflow file path when the annex omits a top-level name: key (#655 round 6)" \
  "$W/agent-review.yml" 'doc["name"] ? doc["name"].to_s : ".github/workflows/repo_lint_local.yml"'

# Codex P2 (#655 round 2): success/skipped/neutral are all non-blocking
# conclusions for a required check (matching codex-review-check.sh's own
# BAD_CHECKS acceptance set) -- a conditional annex job GitHub completes as
# skipped must not time out or abort native auto-merge. Values are the
# GraphQL statusCheckRollup enum casing (#655 round 4 data-source switch).
# Round 5 moved this from a per-run bash if-check to a jq computation over
# every matched workflow group's winner (see the group-by-workflow
# assertions below), so the acceptance set now lives in that jq filter.
assert_grep "agent-review: accepts SUCCESS, SKIPPED, and NEUTRAL conclusions across every matched workflow group" \
  "$W/agent-review.yml" '($r != "SUCCESS" and $r != "SKIPPED" and $r != "NEUTRAL")'

# Codex P2 (#655 round 3): a matrix-strategy annex job expands into check-run
# names this static YAML read cannot reproduce -- skip it during derivation
# (permanently waiting on a name that will never report is worse than not
# observing that job at all) instead of guessing the unexpanded name.
assert_grep "agent-review: skips matrix-strategy annex jobs during derivation instead of guessing their expanded name(s)" \
  "$W/agent-review.yml" 'job["strategy"].is_a?(Hash) && job["strategy"]["matrix"]'

# Codex P1 (#655 round 6, "observe matrix annex jobs before auto-merge"): a
# matrix job is excluded from NAME derivation above, but its annex_workflow
# is still captured, so a reported failing matrix leg (under an expanded
# name this static read could never predict) is still caught by the
# workflow-wide scan matching on .workflowName alone.
assert_grep "agent-review: workflow-wide annex scan matches by .workflowName, catching a matrix-leg failure without its expanded name" \
  "$W/agent-review.yml" '[.statusCheckRollup[] | select((.workflowName // "") == $workflow)]'
assert_grep "agent-review: a bad conclusion reported anywhere in the annex's workflow refuses auto-merge immediately (#655 round 6)" \
  "$W/agent-review.yml" 'non-passing reported check-run(s) on current HEAD $sha (conclusion=$annex_bad_summary); refusing auto-merge (#655)'
assert_grep "agent-review: a still-in-progress annex entry is treated as pending (keeps polling), not as a failure (#655 round 6)" \
  "$W/agent-review.yml" 'check-run(s) still in progress on current HEAD $sha; waiting for completion (#655)'

# Codex P2 (#655 round 4): a 403 (token lacks Contents: read) is usually
# persistent, unlike other indeterminate errors -- forcing the synthetic
# fallback here would permanently block native auto-merge on every future
# PR, not just annex-having ones. Do not fail closed on a confirmed 403.
assert_grep "agent-review: does not fail closed on a confirmed 403 (likely a persistent token-scope gap, not transient)" \
  "$W/agent-review.yml" "grep -q 'HTTP 403' \"\$annex_probe_err\""

# Codex P2 (#655 round 4): "could not parse the YAML at all" (ruby exits
# before its `puts` line -- empty output) is a different failure mode from
# "parsed fine but every job was matrix-strategy and skipped" (ruby emits a
# jobs: [] with the workflow name still populated). Round 6 stopped forcing
# a conventional-name fallback for EITHER case (see the required_checks_json
# assertions above) -- the distinction still matters because the
# matrix-skipped case still yields a usable annex_workflow for the
# workflow-wide scan, while the genuine parse failure yields nothing to
# scan at all.
assert_grep "agent-review: distinguishes genuine YAML-parse failure from a valid parse where every job was matrix-skipped" \
  "$W/agent-review.yml" 'every job is matrix-strategy (skipped)'

# Codex P2 (#655 round 4): the annex contract does not require unique job
# names, so matching must disambiguate by workflow (not name alone) via the
# same statusCheckRollup data source codex-review-check.sh's gate (a) uses
# (switched from the check-runs REST endpoint, which has no workflow-name
# field), picking the latest run per (name, workflow) pair.
assert_grep "agent-review: disambiguates required checks by (name, workflow) via statusCheckRollup" \
  "$W/agent-review.yml" 'select($workflow == "" or (.workflowName // "") == $workflow)'

# Codex P2 (#655 round 5, superseding round 4's plain sort_by|last): matches
# are grouped by workflow identity before picking a winner. Within a group,
# any NON-COMPLETED entry (e.g. a queued rerun with neither startedAt nor
# completedAt set) takes priority over a stale completed one -- a naive
# sort_by(startedAt // completedAt) ranked an empty-timestamp queued entry
# BEFORE an older completed one, so `last` picked the stale result. Across
# groups, EVERY group's winner must be green -- so a same-named annex job
# (allowed by the annex contract, workflow=="" matches any workflow) can
# never stand in for a failing canonical `lint`.
assert_grep "agent-review: groups matching checks by workflow before picking a winner (not a bare sort_by | last)" \
  "$W/agent-review.yml" 'group_by(.workflowName // "")'
assert_grep "agent-review: picks the latest COMPLETED run within a workflow group when nothing is pending" \
  "$W/agent-review.yml" 'sort_by(.completedAt // .startedAt // "")'
assert_grep "agent-review: requires every matched workflow group to be green, not just one arbitrary winner" \
  "$W/agent-review.yml" 'Every group'"'"'s winner must be green'

# Codex P2 (#655 round 6, "treat successful status contexts as complete"):
# a StatusContext entry (e.g. a legacy commit status, no .status field at
# all -- only CheckRun has one) was treated as pending FOREVER by a bare
# `.status != "COMPLETED"` check, since null != "COMPLETED" is true
# regardless of .state. A StatusContext is non-terminal only when .state is
# literally "PENDING" -- round 7 added "EXPECTED" (GitHub's "waiting for a
# status to be reported" state, distinct from PENDING but equally
# non-terminal): without it, a required external status context sitting in
# EXPECTED aborted the wait loop as a failure instead of continuing to
# poll. A CheckRun is non-terminal whenever .status is present and not
# "COMPLETED". This predicate is shared by the winner selection, the
# pending-count check, and the annex workflow-wide scan.
assert_grep "agent-review: a status-context entry is pending when .state is PENDING or EXPECTED, not merely lacking .status (#655 rounds 6-7)" \
  "$W/agent-review.yml" 'if (.status != null) then (.status != "COMPLETED") else (["PENDING","EXPECTED"] | index(.state // "")) end'

# Codex P1 (#655 round 7, "parse valid annex workflows that use YAML
# aliases"): GitHub Actions supports YAML anchors/aliases in workflow
# files, but Psych safe_load's aliases:false default rejected any alias
# and treated the whole annex as unparseable. Allowing aliases outright
# would reopen a YAML alias-expansion ("billion laughs") DoS against the
# CI runner parsing a PR's own branch content -- guarded here with a byte-
# size cap and a raw anchor/alias token-count cap, both checked BEFORE the
# actual parse (the danger is in the expansion, not the input size).
assert_grep "agent-review: allows YAML aliases when parsing the annex (#655 round 7)" \
  "$W/agent-review.yml" 'doc = YAML.safe_load(raw, aliases: true)'
assert_grep "agent-review: bounds annex YAML size before parsing, defending against a YAML alias-expansion DoS (#655 round 7)" \
  "$W/agent-review.yml" 'if raw.bytesize > 100_000'

# Codex P2 (#655 round 8, "avoid treating path globs as YAML aliases") and
# round 9 ("do not count glob hyphens as YAML aliases"): the round-7
# guard's naive `[&*]word` scan counted an ordinary glob like `**/*.ts`
# (round 8) or a hyphenated one like `component-*.ts` (round 9, since a
# bare trailing `-` was accepted as a structural position ANYWHERE in the
# text) as alias tokens -- a legitimate annex with a longer or hyphenated
# filter list could exceed the cap and be treated as too-dangerous-to-
# parse. A real anchor/alias can only appear at a structural position:
# start of text; a block-sequence dash anchored to the START OF ITS LINE
# with a mandatory space before its value (round 9, excluding a mid-string
# hyphen like a glob own); or `:`/`,`/`[`/`{` anywhere, optionally followed
# by whitespace. A glob string value (always quoted when it starts with
# `*`, since an unquoted one is itself a YAML syntax error) never
# satisfies any of these.
assert_grep "agent-review: alias token-count guard requires a line-anchored dash (or other structural position), no longer over-counting quoted or hyphenated path globs (#655 rounds 8-9)" \
  "$W/agent-review.yml" 'if raw.scan(/(?:\A|^[ \t]*-\s+|[:,\[{]\s*)[&*][A-Za-z0-9_.-]+/).length > 40'

# Codex P1 (#655 round 7, "wait for unfiltered annex workflow to appear
# before merging"): an annex with NO restricting filter is guaranteed to
# eventually produce a check run for this PR, so zero reported entries
# just means Actions has not scheduled it yet -- unlike a genuinely
# filtered annex, where zero entries is legitimately ambiguous between
# "not yet" and "never for this diff" (Finding O, round 6, which must stay
# non-blocking). YAML 1.1 coerces the bareword `on:` key to the boolean
# true (the "Norway problem"), so doc["on"] is nil for the overwhelmingly
# common unquoted `on:` and the fallback doc[true] read is required, not
# optional.
assert_grep "agent-review: reads the on: trigger via the true-key fallback (YAML 1.1 Norway-problem coercion) (#655 round 7)" \
  "$W/agent-review.yml" 'on = doc.key?("on") ? doc["on"] : doc[true]'
assert_grep "agent-review: keeps polling (does not silently pass) when an unfiltered annex has zero reported entries (#655 round 7)" \
  "$W/agent-review.yml" 'if [ "$annex_match_count" -eq 0 ] && [ "$annex_unfiltered" = "true" ]; then'
assert_grep "agent-review: a path-filtered annex with zero reported entries still does not block (Finding O, round 6, preserved)" \
  "$W/agent-review.yml" 'has not reported yet (unfiltered trigger, so it is expected to)'

# Codex P2 (#655 round 9, "honor non-path pull_request filters before
# waiting") and round 11 ("evaluate base-branch filters before passing"):
# round 8 checked only paths/paths-ignore on the pull_request config.
# Round 9 blanket-disqualified on branches/branches-ignore presence too;
# round 11 replaced that with an actual evaluation against the real ref
# (below), since GitHub schedules the workflow whenever the ref matches
# the filter, not merely when the filter is absent (types is handled
# separately too, since round 10 found it needs different treatment).
assert_grep "agent-review: generic filter-key lists no longer blanket-disqualify on branches/branches-ignore (#655 round 11)" \
  "$W/agent-review.yml" 'pr_filter_keys = ["paths", "paths-ignore"]'
assert_grep "agent-review: push filter-key list disqualifies on tags/tags-ignore instead of branches/branches-ignore (#655 round 11)" \
  "$W/agent-review.yml" 'push_filter_keys = ["paths", "paths-ignore", "tags", "tags-ignore"]'

# Codex P1 (#655 round 10, found on the codex-review-check.sh copy of this
# same logic and mirrored here): round 9 disqualified "unfiltered" on the
# MERE PRESENCE of a types key, but types selects WHICH pull_request
# activities trigger the workflow at all (GitHub default when omitted is
# [opened, synchronize, reopened]) rather than narrowing by path/branch.
# An explicit `types: [opened, synchronize, reopened]` -- functionally
# identical to omitting types -- was wrongly disqualified. Only a types
# list that EXCLUDES synchronize should disqualify, since that is the
# activity that fires for a resynchronized PRs current HEAD.
assert_grep "agent-review: treats a types list that includes synchronize as unfiltered, not merely absent (#655 round 10)" \
  "$W/agent-review.yml" 'next (cfg["types"].is_a?(Array) && cfg["types"].include?("synchronize")) if cfg.key?("types")'

# Codex P2 (#655 round 11, "evaluate base-branch filters before passing",
# found on the codex-review-check.sh copy and mirrored here):
# `pull_request: {branches: [main]}` still runs for every PR targeting
# main -- evaluated against the real ref (pull_request compares the PRs
# BASE ref; push compares the ref actually pushed, which for a same-repo
# PRs synchronize is its own HEAD ref, not base) via File.fnmatch, with a
# conservative disqualify when the relevant branch cannot be resolved.
assert_grep "agent-review: evaluates branches/branches-ignore via fnmatch instead of blanket-disqualifying on presence (#655 round 11)" \
  "$W/agent-review.yml" 'def branch_filter_excludes?(cfg, branch)'
assert_grep "agent-review: pull_request branches evaluation uses the PRs base ref, not head (#655 round 11)" \
  "$W/agent-review.yml" 'trigger_unfiltered.call("pull_request", pr_filter_keys, ENV["ANNEX_BASE_BRANCH"])'
assert_grep "agent-review: push branches evaluation uses the PRs own head ref, not base (#655 round 11)" \
  "$W/agent-review.yml" 'trigger_unfiltered.call("push", push_filter_keys, ENV["ANNEX_HEAD_BRANCH"])'
assert_grep "agent-review: derives base/head branch names from the same pr_view_json call, no extra API call (#655 round 11)" \
  "$W/agent-review.yml" 'annex_base_branch=$(echo "$pr_view_json"'
assert_grep "agent-review: gh pr view fetches baseRefName/headRefName alongside the existing fields (#655 round 11)" \
  "$W/agent-review.yml" '--json headRefOid,isCrossRepository,baseRefName,headRefName'

# Codex P2 (#655 round 11, "treat tag-only push annexes as filtered",
# mirrored): a push trigger scoped by tags/tags-ignore only fires for TAG
# ref pushes, never an ordinary branch push -- which is what a same-repo
# PRs synchronize always is. There is no PR-relative tag to evaluate
# against, so tags/tags-ignore blanket-disqualifies push (already
# confirmed by the push_filter_keys assertion above).

# Codex P2 (#655 round 9, "wait for valid push-only annex workflows"):
# check_ci_scripts_wired accepts push OR pull_request as valid annex
# wiring, but a push-only annex (no pull_request trigger at all) was never
# classified as unfiltered, so this wait never waited for it even though it
# is a contractually valid annex. A push trigger only fires IN THIS REPO
# for a same-repo PR (a fork PRs push lands in the fork, never here), so
# this is gated on annex_same_repo_pr (derived from gh pr views own
# isCrossRepository field, no extra API call) rather than applied
# unconditionally.
assert_grep "agent-review: derives same-repo-PR status via gh pr views isCrossRepository field, no extra API call (#655 round 9)" \
  "$W/agent-review.yml" 'annex_same_repo_pr=$(echo "$pr_view_json"'
assert_grep "agent-review: same-repo-PR determination inverts isCrossRepository (#655 round 9)" \
  "$W/agent-review.yml" 'if .isCrossRepository then "false" else "true" end'
assert_grep "agent-review: treats a push-only annex as unfiltered when (and only when) the PR is same-repo (#655 round 9)" \
  "$W/agent-review.yml" 'unfiltered = pr_unfiltered || (push_unfiltered && same_repo_pr)'

# Codex P2 (#655 round 11, "restrict the lint wait to the required
# workflow"): the round-5 "group by workflow, require every group green"
# rule closed the mask-the-canonical-check risk, but left the OPPOSITE
# risk open for the workflow=="" (canonical) match -- a coincidentally
# same-named but NON-required check from an unrelated workflow would ALSO
# become a mandatory group. isRequired(pullRequestNumber:) (ground truth,
# only resolvable via a direct graphql query -- gh pr views fixed --json
# shape omits it) now additionally filters the workflow=="" case to only
# entries branch protection actually requires.
assert_grep "agent-review: fetches statusCheckRollup via a direct graphql query to access isRequired (#655 round 11)" \
  "$W/agent-review.yml" 'isRequired(pullRequestNumber: $number)'
assert_grep "agent-review: the canonical (workflow==\"\") match additionally requires isRequired==true (#655 round 11)" \
  "$W/agent-review.yml" 'select($workflow != "" or (.isRequired == true))'

# Codex P1 (#655 round 12, "paginate the status check rollup"): a PR with
# more than 100 statusCheckRollup contexts (this PR itself already had
# 160+, confirmed live) silently hid every entry past the first page from
# both the required-check and annex workflow-wide scans -- auto-merge
# could arm while an unobserved check past page 1 was still red. Paged
# through with the Relay cursor rather than a bigger fixed page size,
# since the rollup can grow without bound on a long-lived PR.
assert_grep "agent-review: pages through statusCheckRollup contexts via the Relay cursor instead of a single fixed-size page (#655 round 12)" \
  "$W/agent-review.yml" 'contexts(first: 100, after: $cursor)'
assert_grep "agent-review: the pagination loop checks hasNextPage and accumulates entries across pages (#655 round 12)" \
  "$W/agent-review.yml" 'pageInfo { hasNextPage endCursor }'
assert_grep "agent-review: accumulates each page's contexts into the running rollup array (#655 round 12)" \
  "$W/agent-review.yml" 'rollup_contexts=$(jq -c -n --argjson a "$rollup_contexts" --argjson b "$page_nodes"'

# Codex P2 (#655 round 12, "honor GitHub Actions branch glob semantics",
# found on the codex-review-check.sh copy and mirrored here): GitHub docs
# specify a single `*` does NOT cross a `/` while `**` DOES; patterns are
# also evaluated IN ORDER with an optional `!` prefix negating a prior
# match, which the round-11 `any?` check ignored entirely.
assert_grep "agent-review: applies FNM_PATHNAME only for non-globstar patterns, so single * does not cross / while ** does (#655 round 12)" \
  "$W/agent-review.yml" 'flags = pattern.include?("**") ? 0 : File::FNM_PATHNAME'
assert_grep "agent-review: evaluates branch patterns in order with ! negation, a later pattern overriding an earlier one (#655 round 12)" \
  "$W/agent-review.yml" 'def branch_matches_list?(patterns, branch)'

# auto-clear-blocking-labels.yml: the workflow_run trigger list observes the
# annex's completion too (verified against a live consumer's repo_lint_local.yml
# workflow name, per #655).
assert_grep "auto-clear: workflow_run trigger list includes repo-lint-local (#655)" \
  "$W/auto-clear-blocking-labels.yml" '- "repo-lint-local"'

# Codex P3 (#655 round 11, "include the unnamed annex workflow trigger"):
# workflow_run matches by the target workflow's displayed NAME, which for
# an annex omitting a top-level `name:` is the workflow FILE PATH (round
# 6's fallback), not the literal "repo-lint-local" string.
assert_grep "auto-clear: workflow_run trigger list also includes the unnamed-annex file-path fallback name (#655 round 11)" \
  "$W/auto-clear-blocking-labels.yml" '- ".github/workflows/repo_lint_local.yml"'

# ── Bash syntax check on every agent-review.yml `run:` block. Catches
#    heredoc/subshell/loop errors the grep assertions above cannot (mirrors
#    check_auto_clear_workflow's equivalent check for its own file — no
#    such check previously existed for agent-review.yml).
echo
echo "agent-review.yml bash syntax test"

if [ -f "$W/agent-review.yml" ]; then
  block_dir=$(mktemp -d)
  awk -v outdir="$block_dir" '
    /^[[:space:]]+run:[[:space:]]+\|[[:space:]]*$/ {
      if (in_run) { close(outfile) }
      n++; outfile = outdir "/block-" n ".sh"
      match($0, /^[[:space:]]+/); base_indent = RLENGTH
      in_run = 1; next
    }
    in_run && NF == 0 { print > outfile; next }
    in_run {
      match($0, /^[[:space:]]*/); cur_indent = RLENGTH
      if (cur_indent <= base_indent) {
        close(outfile); in_run = 0; next
      }
      sub("^[[:space:]]{" (base_indent + 2) "}", "")
      print > outfile
    }
    END { if (in_run) close(outfile) }
  ' "$W/agent-review.yml"

  extracted_count=$(ls -1 "$block_dir" 2>/dev/null | wc -l | tr -d ' ')
  syntax_errors=0
  for f in "$block_dir"/block-*.sh; do
    [ -f "$f" ] || continue
    if ! err=$(bash -n "$f" 2>&1); then
      fail "bash syntax error in $(basename "$f") (agent-review.yml)"
      echo "$err" | sed 's/^/    /' >&2
      syntax_errors=$((syntax_errors + 1))
    fi
  done
  rm -rf "$block_dir"

  if [ "$syntax_errors" -eq 0 ] && [ "$extracted_count" -gt 0 ]; then
    pass "all $extracted_count agent-review.yml run blocks have valid bash syntax"
  elif [ "$extracted_count" = "0" ]; then
    fail "extracted 0 run blocks from agent-review.yml (extraction logic broken?)"
  fi
else
  echo "SKIP: agent-review.yml bash syntax test (file absent)"; SKIP=$((SKIP + 1))
fi

echo ""
echo "test_655_repo_lint_local_observed: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
