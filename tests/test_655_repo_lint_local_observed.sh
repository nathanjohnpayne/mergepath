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
# workflow-wide scan matching on its workflow identity alone.
#
# Codex P2 (#655 round 13, "disambiguate annex workflows beyond display
# name", found on the codex-review-check.sh copy and mirrored here): the
# annex contract allows any top-level workflow name:, so two workflow files
# can share the same displayed workflowName -- matching on .workflowPath
# (derived from the GraphQL-reported resourcePath of the workflow FILE
# itself) instead closes that collision, since the annex's file path is
# fixed and not consumer-editable.
assert_grep "agent-review: workflow-wide annex scan matches by the stable .workflowPath, not the collision-prone display name (#655 round 13)" \
  "$W/agent-review.yml" '[.statusCheckRollup[] | select((.workflowPath // "") == "repo_lint_local.yml")]'
assert_grep "agent-review: a bad conclusion reported anywhere in the annex's workflow refuses auto-merge immediately (#655 round 6)" \
  "$W/agent-review.yml" 'non-passing reported check-run(s) after winner-selection on current HEAD $sha (conclusion=$annex_bad_summary); refusing auto-merge (#655)'
assert_grep "agent-review: a still-in-progress annex entry is treated as pending (keeps polling), not as a failure (#655 round 6)" \
  "$W/agent-review.yml" 'check-run(s) still in progress on current HEAD $sha; waiting for completion (#655)'
assert_grep "agent-review: workflow query requests resourcePath alongside name to derive the stable workflowPath (#655 round 13)" \
  "$W/agent-review.yml" 'checkSuite { workflowRun { workflow { name resourcePath } } }'
assert_grep "agent-review: rollup_json derives workflowPath from resourcePath's final path segment (#655 round 13)" \
  "$W/agent-review.yml" 'workflowPath: (((.checkSuite.workflowRun.workflow.resourcePath // "") | split("/") | last) // "")'
assert_grep "agent-review: annex_bad groups by check name and keeps only the latest-completed winner per name before judging bad-ness (#655 round 13)" \
  "$W/agent-review.yml" 'group_by(.name // .context // "?")'

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
  "$W/agent-review.yml" 'if (.status != null) then (.status != "COMPLETED") else ((.state // "") as $ann_state | ["PENDING","EXPECTED"] | index($ann_state)) end'

# Self-caught while porting the pending-check above into
# codex-review-check.sh for #655 round 13: the ORIGINAL form piped a bare
# array literal straight into `index(.state // "")`, which rebinds `.` to
# that array literal for the rest of the pipeline -- `.state` then tries to
# index an array with a string and jq hard-errors, but only for a
# StatusContext (no .status field), since a CheckRun never reaches this
# `else` branch at all. Latent since round 6/7 (never triggered here
# because every entry observed so far has been a CheckRun), but a classic
# Statuses-API context reaching this branch would fail the whole jq call.
# Fixed by binding .state to a variable BEFORE the array-literal pipe;
# guarded here so the fix cannot silently regress back to the broken form.
assert_not_grep "agent-review: does not regress to the pre-round-13 index(.state) expression that rebinds dot inside the array-literal pipe" \
  "$W/agent-review.yml" '(["PENDING","EXPECTED"] | index(.state // ""))'

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
assert_grep "agent-review: a dedicated helper disqualifies push only when tags/tags-ignore is present AND branches/branches-ignore is entirely absent (#655 round 13)" \
  "$W/agent-review.yml" 'def push_tag_only_excludes?(cfg)'
assert_grep "agent-review: push_tag_only_excludes? is wired into the trigger_unfiltered lambda for the push event (#655 round 13)" \
  "$W/agent-review.yml" 'next false if event == "push" && push_tag_only_excludes?(cfg)'

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

# Codex P2 (#655 round 16, "do not skip opened-only annex runs"),
# REVERTED in round 17 ("do not infer opened-only runs from committer
# date", found on the codex-review-check.sh copy and mirrored here):
# round 16 tried to treat types: [opened] (no synchronize) as unfiltered
# when the HEAD committer date predates PR creation. Confirmed live: a
# genuinely-new synchronize push whose commit preserves an OLDER
# committer date (a rebase/cherry-pick of a stale commit) still satisfies
# that comparison, so the heuristic could say "unfiltered" for a trigger
# that will NEVER report again on that HEAD -- a real, confirmed
# permanent-wait risk, worse than the narrower gap being reopened. No
# reliable, non-spoofable signal is available from data this script
# already has, so the mechanism was removed entirely rather than patched
# further; only a types list that explicitly includes synchronize counts
# as unfiltered again (the simple, safe round-10 rule).
assert_not_grep "agent-review: no longer infers an opened-only annex is unfiltered from committer date (#655 round 17)" \
  "$W/agent-review.yml" 'head_predates_pr_creation'
assert_not_grep "agent-review: no longer fetches PR createdAt for the reverted opened-only heuristic (#655 round 17)" \
  "$W/agent-review.yml" ',createdAt)'
assert_not_grep "agent-review: no longer fetches the annex HEAD's own committer date for the reverted opened-only heuristic (#655 round 17)" \
  "$W/agent-review.yml" 'annex_head_committer_date='
assert_grep "agent-review: types: [opened] alone (no synchronize) is unconditionally filtered again, closing the deadlock risk (#655 round 17)" \
  "$W/agent-review.yml" 'next (cfg["types"].is_a?(Array) && cfg["types"].include?("synchronize")) if cfg.key?("types")'

# Codex P2 (#655 round 11, "evaluate base-branch filters before passing",
# found on the codex-review-check.sh copy and mirrored here):
# `pull_request: {branches: [main]}` still runs for every PR targeting
# main -- evaluated against the real ref (pull_request compares the PRs
# BASE ref; push compares the ref actually pushed, which for a same-repo
# PRs synchronize is its own HEAD ref, not base), with a conservative
# disqualify when the relevant branch cannot be resolved. Matching itself
# switched from File.fnmatch to a regex translator in round 13 (see the
# branch_pattern_to_regex assertions further below).
assert_grep "agent-review: evaluates branches/branches-ignore against the real ref instead of blanket-disqualifying on presence (#655 round 11)" \
  "$W/agent-review.yml" 'def branch_filter_excludes?(cfg, branch)'
assert_grep "agent-review: pull_request branches evaluation uses the PRs base ref, not head (#655 round 11)" \
  "$W/agent-review.yml" 'trigger_unfiltered.call("pull_request", ENV["ANNEX_BASE_BRANCH"])'
assert_grep "agent-review: push branches evaluation uses the PRs own head ref, not base (#655 round 11)" \
  "$W/agent-review.yml" 'trigger_unfiltered.call("push", ENV["ANNEX_HEAD_BRANCH"])'

# Codex P2 (#655 round 16, "wait for path-matched annex workflows",
# narrowed in round 17 -- "use the event diff when emulating path
# filters", found on the codex-review-check.sh copy and mirrored here): a
# paths/paths-ignore key was previously treated as unconditionally
# filtered on mere presence, even when the PRs actual changed files match
# the filter. Path glob syntax documents the SAME tokens as branch/tag
# patterns, so branch_matches_list? is reused. GitHub evaluates a push
# triggers path filter against the two-dot diff of JUST that push, not
# the whole-PR three-dot diff this fetch provides, so only pull_request
# gets the real evaluation; push keeps the always-filtered default. The
# changed-file list is also capped to GitHub own 300-file evaluation
# limit.
assert_grep "agent-review: evaluates paths/paths-ignore against the PRs real changed files instead of blanket-disqualifying on presence (#655 round 16)" \
  "$W/agent-review.yml" 'def paths_filter_excludes?(event, cfg, changed_files, changed_files_known)'
assert_grep "agent-review: push never gets the real path evaluation, avoiding a two-dot-vs-three-dot diff scope mismatch (#655 round 17)" \
  "$W/agent-review.yml" 'return true if event == "push"'
assert_grep "agent-review: caps the changed-file list to GitHub's own 300-file path-filter evaluation limit (#655 round 17)" \
  "$W/agent-review.yml" 'capped_files = changed_files.first(300)'
assert_grep "agent-review: paths requires at least one changed file to match (#655 round 16)" \
  "$W/agent-review.yml" 'return true unless capped_files.any? { |f| branch_matches_list?(cfg["paths"], f) }'
assert_grep "agent-review: paths-ignore excludes only when EVERY changed file matches the ignore patterns (#655 round 16)" \
  "$W/agent-review.yml" 'return true if capped_files.all? { |f| branch_matches_list?(cfg["paths-ignore"], f) }'
assert_grep "agent-review: fetches the PRs real changed-file list, paginated (#655 round 16)" \
  "$W/agent-review.yml" 'annex_changed_files_raw=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files"'
assert_grep "agent-review: paths_filter_excludes? is wired into trigger_unfiltered ahead of the tag/branch checks (#655 round 16)" \
  "$W/agent-review.yml" 'next false if paths_filter_excludes?(event, cfg, changed_files, changed_files_known)'
# Codex P2 (#655 round 17, "fail closed when the changed-file lookup
# fails", Codex; "don't silently treat changed-files API failures as
# filtered out", CodeRabbit): the round-16 fetch piped stderr into stdout
# with no failure check, so a failed gh api call fed an error message
# into jq, which failed too, silently collapsing to an empty list --
# indistinguishable from "genuinely fetched, zero files", wrongly read as
# "paths definitely does not match". An explicit success/failure branch
# keeps a failure as an EXPLICITLY empty string, which changed_files_known
# treats as unresolvable rather than "no files".
assert_grep "agent-review: explicitly branches on the changed-files fetch succeeding vs failing (#655 round 17)" \
  "$W/agent-review.yml" 'if annex_changed_files_raw=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" 2>&1); then'
assert_grep "agent-review: a failed changed-files fetch leaves the JSON explicitly empty rather than silently valid (#655 round 17)" \
  "$W/agent-review.yml" 'annex_changed_files_json=""'
assert_grep "agent-review: changed_files_known distinguishes a fetch failure from a genuinely-empty changed-file list (#655 round 17)" \
  "$W/agent-review.yml" 'changed_files_known = !(ENV["ANNEX_CHANGED_FILES_JSON"] || "").empty?'
assert_grep "agent-review: derives base/head branch names from the same pr_view_json call, no extra API call (#655 round 11)" \
  "$W/agent-review.yml" 'annex_base_branch=$(echo "$pr_view_json"'
assert_grep "agent-review: gh pr view fetches baseRefName/headRefName alongside the existing fields (#655 round 11)" \
  "$W/agent-review.yml" '--json headRefOid,isCrossRepository,baseRefName,headRefName'

# Codex P2 (#655 round 11, "treat tag-only push annexes as filtered",
# narrowed in round 13 -- "do not treat tag filters as excluding branch
# pushes", mirrored): a push trigger scoped ONLY by tags/tags-ignore (no
# branches/branches-ignore at all) only fires for TAG ref pushes, never an
# ordinary branch push -- which is what a same-repo PRs synchronize always
# is. But GitHub documents branches and tags as combinable on the SAME push
# trigger, so a trigger with BOTH keys must still be evaluated by its
# branches filter (already confirmed by the push_tag_only_excludes?
# assertions above).

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
# shape omits it) now filters the workflow=="" case to required entries
# when any same-name entry reports required=true. If none do, the
# configured-check wait still honors the configured check name.
assert_grep "agent-review: fetches statusCheckRollup via a direct graphql query to access isRequired (#655 round 11)" \
  "$W/agent-review.yml" 'isRequired(pullRequestNumber: $number)'
assert_grep "agent-review: the canonical (workflow==\"\") match builds a required=true subset when GitHub reports one (#655 round 15)" \
  "$W/agent-review.yml" '([$name_matches[] | select(.isRequired == true)]) as $required_matches'
assert_grep "agent-review: the canonical (workflow==\"\") match falls back to all name matches when none report required=true (#655 round 15)" \
  "$W/agent-review.yml" 'if $workflow == "" and ($required_matches | length) > 0'

if command -v jq >/dev/null 2>&1; then
  agent_review_winners() {
    local rollup_json=$1 check_name=$2 check_workflow=$3
    printf '%s' "$rollup_json" | jq -c --arg name "$check_name" --arg workflow "$check_workflow" '
      [.statusCheckRollup[]
        | select((.name // .context // "") == $name)
        | select($workflow == "" or (.workflowName // "") == $workflow)
      ] as $name_matches
      | ([$name_matches[] | select(.isRequired == true)]) as $required_matches
      | (if $workflow == "" and ($required_matches | length) > 0
         then $required_matches
         else $name_matches
         end) as $matches
      | ($matches | group_by(.workflowName // "")) as $groups
      | [
          $groups[]
          | (map(select(if (.status != null) then (.status != "COMPLETED") else ((.state // "") as $ann_state | ["PENDING","EXPECTED"] | index($ann_state)) end))) as $pending
          | if ($pending | length) > 0
            then $pending[0]
            else (sort_by(.completedAt // .startedAt // "") | last)
            end
        ]'
  }
  ROLLUP_OPTIONAL_ONLY_LINT='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","status":"COMPLETED","conclusion":"SUCCESS","isRequired":false,"completedAt":"2026-07-01T00:00:00Z"}]}'
  GOT=$(agent_review_winners "$ROLLUP_OPTIONAL_ONLY_LINT" "lint" "" | jq -c '[.[].workflowName]')
  if [ "$GOT" = '["repo-lint"]' ]; then
    pass "agent-review jq: configured lint wait still observes a same-named check when no matching entry reports isRequired=true (#655 round 15)"
  else
    fail "agent-review jq (no required metadata fallback): expected [\"repo-lint\"], got $GOT"
  fi
  ROLLUP_REQUIRED_PLUS_OPTIONAL_LINT='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"completedAt":"2026-07-01T00:00:00Z"},{"name":"lint","workflowName":"optional-local","status":"COMPLETED","conclusion":"FAILURE","isRequired":false,"completedAt":"2026-07-01T00:01:00Z"}]}'
  GOT=$(agent_review_winners "$ROLLUP_REQUIRED_PLUS_OPTIONAL_LINT" "lint" "" | jq -c '[.[].workflowName]')
  if [ "$GOT" = '["repo-lint"]' ]; then
    pass "agent-review jq: optional same-named collisions are dropped when a required=true lint entry is present (#655 round 15)"
  else
    fail "agent-review jq (required metadata narrowing): expected [\"repo-lint\"], got $GOT"
  fi
else
  echo "SKIP: agent-review jq winner-selection regression fixtures (jq unavailable)"
  SKIP=$((SKIP + 1))
fi

# Codex P1 (#655 round 12, "paginate the status check rollup"): a PR with
# more than 100 statusCheckRollup contexts (this PR itself already had
# 160+, confirmed live) silently hid every entry past the first page from
# both the required-check and annex workflow-wide scans -- auto-merge
# could arm while an unobserved check past page 1 was still red. Paged
# through with the Relay cursor rather than a bigger fixed page size,
# since the rollup can grow without bound on a long-lived PR.
assert_grep "agent-review: pages through statusCheckRollup contexts via the Relay cursor instead of a single fixed-size page (#655 round 12)" \
  "$W/agent-review.yml" 'contexts(first: 100, after: $cursor)'
assert_grep "agent-review: passes a null GraphQL cursor on the first statusCheckRollup page (#655 round 14)" \
  "$W/agent-review.yml" 'cursor_args=(-F cursor=null)'
assert_grep "agent-review: passes the returned Relay cursor after the first statusCheckRollup page (#655 round 14)" \
  "$W/agent-review.yml" 'cursor_args=(-f cursor="$cursor")'
assert_grep "agent-review: null statusCheckRollup pages normalize to an empty contexts array (#655 round 15)" \
  "$W/agent-review.yml" 'statusCheckRollup.contexts.nodes // []'
assert_grep "agent-review: null statusCheckRollup pages stop pagination instead of hard-erroring (#655 round 15)" \
  "$W/agent-review.yml" 'statusCheckRollup.contexts.pageInfo.hasNextPage // false'
assert_grep "agent-review: null statusCheckRollup pages use an empty cursor (#655 round 15)" \
  "$W/agent-review.yml" 'statusCheckRollup.contexts.pageInfo.endCursor // ""'
assert_grep "agent-review: the pagination loop checks hasNextPage and accumulates entries across pages (#655 round 12)" \
  "$W/agent-review.yml" 'pageInfo { hasNextPage endCursor }'
assert_grep "agent-review: accumulates each page's contexts into the running rollup array (#655 round 12)" \
  "$W/agent-review.yml" 'rollup_contexts=$(jq -c -n --argjson a "$rollup_contexts" --argjson b "$page_nodes"'

# Codex P2 (#655 round 12, "honor GitHub Actions branch glob semantics",
# found on the codex-review-check.sh copy and mirrored here): GitHub docs
# specify a single `*` does NOT cross a `/` while `**` DOES; patterns are
# also evaluated IN ORDER with an optional `!` prefix negating a prior
# match, which the round-11 `any?` check ignored entirely. Round 12 used
# File.fnmatch (with FNM_PATHNAME applied only for non-globstar patterns)
# for the single-star/double-star distinction.
assert_grep "agent-review: evaluates branch patterns in order with ! negation, a later pattern overriding an earlier one (#655 round 12)" \
  "$W/agent-review.yml" 'def branch_matches_list?(patterns, branch)'

# Codex P2 (#655 round 13, "use an Actions-compatible branch glob matcher",
# found on the codex-review-check.sh copy and mirrored here): the round-12
# fnmatch version could not represent a `+` repetition quantifier (e.g.
# `v[12].[0-9]+.[0-9]+`, GitHub's documented semver-branch example) --
# fnmatch always treats `+` as a literal character and returns false.
# Replaced with a translator that converts each documented glob token into
# an equivalent Ruby Regexp (which natively supports quantifiers and
# character classes), matched via Regexp#match?. Round 14 added backslash
# escaping for literal special characters in branch or tag names.
assert_grep "agent-review: translates branch glob patterns into a Ruby Regexp instead of using File.fnmatch (#655 round 13)" \
  "$W/agent-review.yml" 'def branch_pattern_to_regex(pattern)'
assert_grep "agent-review: a lone * translates to a single-path-segment match, not crossing / (#655 round 13)" \
  "$W/agent-review.yml" 'tokens << "[^/]*"'
assert_grep "agent-review: ** translates to a cross-segment match (#655 round 13)" \
  "$W/agent-review.yml" 'tokens << ".*"'
assert_grep "agent-review: a + quantifier is copied through verbatim, since Ruby Regexp supports it natively (#655 round 13)" \
  "$W/agent-review.yml" 'elsif c == "+"'
assert_grep "agent-review: backslash escapes the next branch glob metacharacter into a literal match (#655 round 14)" \
  "$W/agent-review.yml" 'tokens << Regexp.escape(chars[i + 1])'
assert_grep "agent-review: branch_matches? now delegates to the regex translator instead of File.fnmatch (#655 round 13)" \
  "$W/agent-review.yml" 'branch_pattern_to_regex(pattern).match?(branch)'
assert_not_grep "agent-review: no longer uses File.fnmatch for branch matching (#655 round 13)" \
  "$W/agent-review.yml" 'File.fnmatch(pattern, branch, flags)'

# Codex P2 (#655 round 16, "honor ? as an optional-character filter",
# found on the codex-review-check.sh copy and mirrored here): GitHub
# documents `?` as matching zero or one of the PRECEDING character (e.g.
# `release?` matches base branch `release` itself), not "exactly one
# arbitrary character" the way POSIX glob/fnmatch define it -- the
# round-13 translator emitted an independent [^/] token for `?` instead of
# quantifying whatever came before it. Building a token LIST (rather than
# one flat string) lets `?` wrap the last token in `(?:...)?`.
assert_grep "agent-review: builds a token list instead of a flat string, so ? can quantify the preceding token (#655 round 16)" \
  "$W/agent-review.yml" 'tokens = []'
assert_grep "agent-review: ? wraps the preceding token in an optional non-capturing group instead of emitting an independent [^/] (#655 round 16)" \
  "$W/agent-review.yml" 'tokens[-1] = "(?:#{tokens[-1]})?" if tokens.any?'
assert_not_grep "agent-review: no longer treats ? as an unconditional single-character wildcard (#655 round 16)" \
  "$W/agent-review.yml" 'result << "[^/]"'

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
