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
# agent-doable half across thirteen rounds of Codex findings; only the
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
#   by workflow identity, not by a specific check name) that is non-green is
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
#   Rounds 11-12: evaluate branch/tag filters against the real base/head ref
#   instead of blanket-disqualifying on their mere presence, add isRequired
#   scoping for the canonical (workflow-less) required-check match, and
#   paginate the statusCheckRollup fetch (a fixed first-100-contexts page
#   silently hid every later entry on a long-lived PR).
#
#   Round 13: the branch-glob matcher switched from File.fnmatch (which
#   cannot represent a `+` quantifier, e.g. a documented semver branch
#   pattern) to a Ruby Regexp translator; a push trigger with BOTH branches
#   and tags was wrongly disqualified by tags presence alone (GitHub runs it
#   for the matching branch push too); the workflow-wide annex scan now
#   groups by check name and picks a pending-preferred/latest-completed
#   winner per name, so a stale failed rerun superseded by a later success
#   no longer blocks forever; and workflow identity for the annex scan
#   switched from the freely-editable .workflowName display string to the
#   stable, file-derived .workflowPath, closing a collision risk when two
#   workflow files declare the same top-level `name:`.
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
# config. Round 9 blanket-disqualified on branches/branches-ignore
# presence too; round 11 replaced that blanket disqualification with an
# actual evaluation (below), since GitHub schedules the workflow whenever
# the real ref matches the filter, not merely when the filter is absent.
# Round 16 replaced the paths/paths-ignore blanket-disqualify with a real
# evaluation too (see the paths_filter_excludes? assertions further
# below), which is why the standalone filter-key list variables are gone.
if grep -qF 'def paths_filter_excludes?(event, cfg, changed_files, changed_files_known)' "$SCRIPT" \
   && ! grep -qF 'pr_filter_keys = ["paths", "paths-ignore"]' "$SCRIPT" \
   && ! grep -qF 'push_filter_keys = ["paths", "paths-ignore"]' "$SCRIPT"; then
  pass "codex-review-check.sh's generic filter-key lists no longer blanket-disqualify on branches/branches-ignore or paths/paths-ignore, evaluating both instead (#655 rounds 11 and 16)"
else
  fail "codex-review-check.sh's filter-key handling does not match the expected round-16 shape (#655 round 16)"
fi

# Codex P2 (#655 round 11, "evaluate base-branch filters before passing"):
# `pull_request: {branches: [main]}` still runs for every PR targeting
# main -- blanket-disqualifying "unfiltered" on mere presence (round 9-10)
# wrongly treated a genuinely-unfiltered-for-THIS-PR annex as filtered.
# Evaluated against the real ref instead: pull_request compares the PRs
# BASE ref; push compares the ref actually being pushed, which for a
# same-repo PRs synchronize is its own HEAD ref, not base -- these must
# be genuinely different variables/inputs, not the same one reused.
# Round 16 dropped the (by-then only paths-related) filter_keys parameter
# from trigger_unfiltered's signature entirely, since paths/paths-ignore
# evaluation moved into paths_filter_excludes? and no other key used it.
if grep -qF 'def branch_filter_excludes?(cfg, branch)' "$SCRIPT" \
   && grep -qF 'def branch_matches?(pattern, branch)' "$SCRIPT" \
   && grep -qF 'pr_unfiltered = trigger_unfiltered.call("pull_request", ENV["ANNEX_BASE_BRANCH"])' "$SCRIPT" \
   && grep -qF 'push_unfiltered = trigger_unfiltered.call("push", ENV["ANNEX_HEAD_BRANCH"])' "$SCRIPT"; then
  pass "codex-review-check.sh evaluates branches/branches-ignore against the correct ref per event type (#655 round 11)"
else
  fail "codex-review-check.sh does not evaluate branches/branches-ignore against the real base/head ref (#655 round 11)"
fi

# Codex P2 (#655 round 12, "honor GitHub Actions branch glob semantics"):
# GitHub docs specify a single `*` does NOT cross a `/` (feature/* excludes
# feature/foo/bar) while `**` DOES; patterns are also evaluated IN ORDER
# with an optional `!` prefix negating a prior match, which the round-11
# `any?` check ignored entirely. Round 12 used File.fnmatch (FNM_PATHNAME
# applied only for non-globstar patterns) for the star distinction.
if grep -qF 'def branch_matches_list?(patterns, branch)' "$SCRIPT" \
   && grep -qF 'included = false if branch_matches?(raw[1..], branch)' "$SCRIPT" \
   && grep -qF 'included = true if branch_matches?(raw, branch)' "$SCRIPT"; then
  pass "codex-review-check.sh evaluates branch patterns in order with ! negation, a later pattern overriding an earlier one (#655 round 12)"
else
  fail "codex-review-check.sh does not evaluate branch patterns in order with ! negation support (#655 round 12)"
fi

# Codex P2 (#655 round 13, "use an Actions-compatible branch glob matcher"):
# the round-12 fnmatch version could not represent a `+` repetition
# quantifier (e.g. `v[12].[0-9]+.[0-9]+`, GitHub's documented semver-branch
# example) -- fnmatch always treats `+` as a literal character and returns
# false. Replaced with a translator converting each documented glob token
# (*, **, ?, [...], +) into an equivalent Ruby Regexp, matched via
# Regexp#match? -- Regexp natively supports quantifiers and character
# classes, so one mechanism now covers the full documented syntax. Round
# 14 added backslash escaping for literal special characters in branch or
# tag names, as GitHub documents for these same patterns.
if grep -qF 'def branch_pattern_to_regex(pattern)' "$SCRIPT" \
   && grep -qF 'branch_pattern_to_regex(pattern).match?(branch)' "$SCRIPT" \
   && grep -qF 'tokens << Regexp.escape(chars[i + 1])' "$SCRIPT" \
   && ! grep -qF 'File.fnmatch(pattern, branch, flags)' "$SCRIPT"; then
  pass "codex-review-check.sh translates branch glob patterns into a Ruby Regexp, including escaped literal metacharacters (#655 rounds 13-14)"
else
  fail "codex-review-check.sh does not use the expected regex translator / escaped-literal handling for branch-pattern matching (#655 rounds 13-14)"
fi
# Codex P2 (#655 round 16, "honor ? as an optional-character filter"):
# GitHub documents `?` as matching zero or one of the PRECEDING character
# (e.g. `release?` matches base branch `release` itself), not "exactly
# one arbitrary character" the way POSIX glob/fnmatch define it -- the
# round-13 translator emitted an independent [^/] token instead of
# quantifying whatever came before it.
if grep -qF 'tokens = []' "$SCRIPT" \
   && grep -qF 'tokens[-1] = "(?:#{tokens[-1]})?" if tokens.any?' "$SCRIPT" \
   && ! grep -qF 'result << "[^/]"' "$SCRIPT"; then
  pass "codex-review-check.sh builds a token list so ? can quantify the preceding token instead of matching one arbitrary character (#655 round 16)"
else
  fail "codex-review-check.sh does not use the round-16 token-based ? handling (#655 round 16)"
fi
# End-to-end: the exact semver pattern Codex cited, which fnmatch cannot
# represent at all (it treats `+` as a literal character). KEEP THIS
# EMBEDDED RUBY IN SYNC with scripts/codex-review-check.sh's
# branch_pattern_to_regex -- it is a verbatim copy, not a reimplementation.
branch_pattern_matches() {
  local pattern=$1 branch=$2
  ruby -e '
    def branch_pattern_to_regex(pattern)
      tokens = []
      chars = pattern.chars
      i = 0
      while i < chars.length
        c = chars[i]
        if c == "\\" && chars[i + 1]
          tokens << Regexp.escape(chars[i + 1])
          i += 2
        elsif c == "*" && chars[i + 1] == "*"
          tokens << ".*"
          i += 2
        elsif c == "*"
          tokens << "[^/]*"
          i += 1
        elsif c == "?"
          tokens[-1] = "(?:#{tokens[-1]})?" if tokens.any?
          i += 1
        elsif c == "["
          j = i + 1
          j += 1 while j < chars.length && chars[j] != "]"
          tokens << chars[i..j].join
          i = j + 1
        elsif c == "+"
          tokens << "+"
          i += 1
        else
          tokens << Regexp.escape(c)
          i += 1
        end
      end
      Regexp.new("\\A#{tokens.join}\\z")
    end
    def branch_matches?(pattern, branch)
      return false unless pattern.is_a?(String) && branch.is_a?(String)
      branch_pattern_to_regex(pattern).match?(branch)
    rescue RegexpError, ArgumentError
      false
    end
    puts branch_matches?(ARGV[0], ARGV[1])
  ' "$pattern" "$branch"
}
GOT=$(branch_pattern_matches 'v[12].[0-9]+.[0-9]+' 'v1.20.3')
if [ "$GOT" = "true" ]; then
  pass "regex translator: the documented semver pattern v[12].[0-9]+.[0-9]+ matches v1.20.3 (#655 round 13)"
else
  fail "regex translator (semver match): expected true, got $GOT"
fi
GOT=$(branch_pattern_matches 'v[12].[0-9]+.[0-9]+' 'v3.20.3')
if [ "$GOT" = "false" ]; then
  pass "regex translator: the documented semver pattern v[12].[0-9]+.[0-9]+ does not match v3.20.3 (#655 round 13)"
else
  fail "regex translator (semver non-match): expected false, got $GOT"
fi
GOT=$(branch_pattern_matches 'feature/*' 'feature/foo/bar')
if [ "$GOT" = "false" ]; then
  pass "regex translator: a lone * still does not cross / (round-12 behavior preserved, #655 round 13)"
else
  fail "regex translator (single-star no-cross regression): expected false, got $GOT"
fi
GOT=$(branch_pattern_matches 'feature/**' 'feature/foo/bar')
if [ "$GOT" = "true" ]; then
  pass "regex translator: ** still crosses / (round-12 behavior preserved, #655 round 13)"
else
  fail "regex translator (globstar-crosses regression): expected true, got $GOT"
fi
GOT=$(branch_pattern_matches 'literal/\*' 'literal/*')
if [ "$GOT" = "true" ]; then
  pass "regex translator: escaped * matches a literal * in the branch name (#655 round 14)"
else
  fail "regex translator (escaped literal star): expected true, got $GOT"
fi
GOT=$(branch_pattern_matches 'literal/\*' 'literal/foo')
if [ "$GOT" = "false" ]; then
  pass "regex translator: escaped * no longer behaves as a wildcard (#655 round 14)"
else
  fail "regex translator (escaped star wildcard regression): expected false, got $GOT"
fi
# Codex P2 (#655 round 16, "honor ? as an optional-character filter"):
# the exact example Codex cited -- release? matches base branch release
# itself (zero of the preceding character), and also matches release1
# (one of the preceding character), but not release12 (no room left in
# the pattern for a second extra character).
GOT=$(branch_pattern_matches 'release?' 'release')
if [ "$GOT" = "true" ]; then
  pass "regex translator: release? matches release (zero of the preceding character) (#655 round 16)"
else
  fail "regex translator (? zero-match): expected true, got $GOT"
fi
GOT=$(branch_pattern_matches 'release?' 'releas')
if [ "$GOT" = "true" ]; then
  pass "regex translator: release? matches releas (the preceding character e made optional) (#655 round 16)"
else
  fail "regex translator (? drops preceding char): expected true, got $GOT"
fi
GOT=$(branch_pattern_matches 'release?' 'release1')
if [ "$GOT" = "false" ]; then
  pass "regex translator: release? does not match release1 (? is not a stand-in for an arbitrary extra character) (#655 round 16)"
else
  fail "regex translator (? not a wildcard): expected false, got $GOT"
fi
GOT=$(branch_pattern_matches 'v[12]?' 'v')
if [ "$GOT" = "true" ]; then
  pass "regex translator: ? quantifies a whole preceding [...] class, not just its last character (#655 round 16)"
else
  fail "regex translator (? quantifies bracket class): expected true, got $GOT"
fi
GOT=$(branch_pattern_matches '?main' 'main')
if [ "$GOT" = "true" ]; then
  pass "regex translator: a leading ? with no preceding token is a no-op, not an error (#655 round 16)"
else
  fail "regex translator (leading ? no-op): expected true, got $GOT"
fi

# An unresolvable/unknown branch must conservatively disqualify (treat as
# filtered) rather than guess -- verified via the ruby-level fallback
# check_ci_scripts_wired-adjacent conservative-default philosophy applied
# throughout #655.
if grep -qF 'return true if (cfg.key?("branches") || cfg.key?("branches-ignore")) && !(branch.is_a?(String) && !branch.empty?)' "$SCRIPT"; then
  pass "codex-review-check.sh conservatively disqualifies unfiltered when the relevant branch cannot be resolved (#655 round 11)"
else
  fail "codex-review-check.sh does not conservatively handle an unresolvable branch for branches/branches-ignore evaluation (#655 round 11)"
fi

# Codex P2 (#655 round 11, "treat tag-only push annexes as filtered",
# narrowed in round 13 -- "do not treat tag filters as excluding branch
# pushes"): a push trigger scoped ONLY by tags/tags-ignore (no branches/
# branches-ignore at all) only fires for TAG ref pushes, never an ordinary
# branch push -- which is what a same-repo PRs synchronize always is. But
# GitHub documents branches and tags as combinable on the SAME push
# trigger (runs for a matching branch push OR a matching tag push), so a
# trigger with BOTH keys must still be evaluated by its branches filter --
# round 11 put tags/tags-ignore into the generic filter_keys list checked
# BEFORE branches ever got a chance to match, wrongly disqualifying a push
# GitHub would actually run. push_tag_only_excludes? now only disqualifies
# when branches/branches-ignore is entirely absent.
if grep -qF 'def push_tag_only_excludes?(cfg)' "$SCRIPT" \
   && grep -qF '(cfg.key?("tags") || cfg.key?("tags-ignore")) && !(cfg.key?("branches") || cfg.key?("branches-ignore"))' "$SCRIPT" \
   && grep -qF 'next false if event == "push" && push_tag_only_excludes?(cfg)' "$SCRIPT"; then
  pass "codex-review-check.sh disqualifies a tag-only push trigger as unfiltered via a dedicated helper, not a blanket filter-key (#655 round 13)"
else
  fail "codex-review-check.sh does not disqualify tag-scoped push triggers via push_tag_only_excludes? (#655 round 13)"
fi
# End-to-end: the exact regression Codex found -- a push trigger with BOTH
# branches (matching) AND tags must still be treated as unfiltered, since
# GitHub runs it for the matching branch push regardless of the tags key.
# A direct ruby invocation is used (rather than reimplementing the
# predicate in jq) since the real function is Ruby -- KEEP IN SYNC with
# scripts/codex-review-check.sh's push_tag_only_excludes?.
push_tag_only_excludes_ruby() {
  local has_tags=$1 has_tags_ignore=$2 has_branches=$3 has_branches_ignore=$4
  ruby -e '
    def push_tag_only_excludes?(cfg)
      (cfg.key?("tags") || cfg.key?("tags-ignore")) && !(cfg.key?("branches") || cfg.key?("branches-ignore"))
    end
    cfg = {}
    cfg["tags"] = true if ARGV[0] == "1"
    cfg["tags-ignore"] = true if ARGV[1] == "1"
    cfg["branches"] = true if ARGV[2] == "1"
    cfg["branches-ignore"] = true if ARGV[3] == "1"
    puts push_tag_only_excludes?(cfg)
  ' "$has_tags" "$has_tags_ignore" "$has_branches" "$has_branches_ignore"
}
GOT=$(push_tag_only_excludes_ruby 1 0 1 0)
if [ "$GOT" = "false" ]; then
  pass "push_tag_only_excludes?: tags + branches (both present) does not exclude push -- branches still gets evaluated (#655 round 13, the exact regression fixed)"
else
  fail "push_tag_only_excludes? (tags+branches): expected false, got $GOT"
fi
GOT=$(push_tag_only_excludes_ruby 1 0 0 0)
if [ "$GOT" = "true" ]; then
  pass "push_tag_only_excludes?: tags alone (no branches key at all) still excludes push (#655 round 11 behavior preserved)"
else
  fail "push_tag_only_excludes? (tags only): expected true, got $GOT"
fi
GOT=$(push_tag_only_excludes_ruby 0 0 1 0)
if [ "$GOT" = "false" ]; then
  pass "push_tag_only_excludes?: branches alone (no tags at all) does not exclude push"
else
  fail "push_tag_only_excludes? (branches only): expected false, got $GOT"
fi

# Codex P2 (#655 round 16, "wait for path-matched annex workflows",
# narrowed in round 17 -- "use the event diff when emulating path
# filters"): a paths/paths-ignore key was previously treated as
# unconditionally filtered on mere presence, even when the PRs actual
# changed files match the filter. Path glob syntax documents the SAME
# tokens as branch/tag patterns, so branch_matches_list? is reused.
# `paths` requires at least one changed file to match; `paths-ignore`
# excludes only when EVERY changed file matches the ignore patterns.
# GitHub evaluates a push triggers path filter against the two-dot diff
# of JUST that push, not the whole-PR three-dot diff this fetch
# provides, so only pull_request gets the real evaluation; push keeps
# the always-filtered default. The changed-file list is capped to
# GitHub's own 300-file evaluation limit.
if grep -qF 'def paths_filter_excludes?(event, cfg, changed_files, changed_files_known)' "$SCRIPT" \
   && grep -qF 'return true if event == "push"' "$SCRIPT" \
   && grep -qF 'capped_files = changed_files.first(300)' "$SCRIPT" \
   && grep -qF 'return true unless capped_files.any? { |f| branch_matches_list?(cfg["paths"], f) }' "$SCRIPT" \
   && grep -qF 'return true if capped_files.all? { |f| branch_matches_list?(cfg["paths-ignore"], f) }' "$SCRIPT" \
   && grep -qF 'ANNEX_CHANGED_FILES_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/files"' "$SCRIPT" \
   && grep -qF 'next false if paths_filter_excludes?(event, cfg, changed_files, changed_files_known)' "$SCRIPT"; then
  pass "codex-review-check.sh evaluates paths/paths-ignore against the PRs real changed files instead of blanket-disqualifying on presence (#655 round 16)"
else
  fail "codex-review-check.sh does not evaluate paths/paths-ignore against real changed files (#655 round 16)"
fi
# Codex P2 (#655 round 17, "fail closed when the changed-file lookup
# fails", Codex; "don't silently treat changed-files API failures as
# filtered out", CodeRabbit): codex-review-check.sh already used
# fetch_api_array (dies on a genuine fetch failure), so this specific
# script never actually reaches ruby with unknown data in practice -- but
# changed_files_known still gates the evaluation for structural parity
# with agent-review.yml, whose own ad hoc fetch (no fetch_api_array
# available in a plain workflow YAML) DID have the silent-failure bug.
if grep -qF 'changed_files_known = !(ENV["ANNEX_CHANGED_FILES_JSON"] || "").empty?' "$SCRIPT"; then
  pass "codex-review-check.sh distinguishes an unknown changed-files fetch from a genuinely-empty one (#655 round 17)"
else
  fail "codex-review-check.sh does not track changed_files_known (#655 round 17)"
fi
# End-to-end: the exact scenarios the finding describes -- paths matching
# vs not matching the actual diff, paths-ignore excluding only when ALL
# files are covered, push never getting the real evaluation, the 300-file
# cap, and the changed_files_known distinction.
paths_filter_excludes_ruby() {
  local event=$1 cfg_json=$2 changed_files_json=$3
  ruby -rjson -e '
    def branch_pattern_to_regex(pattern)
      tokens = []
      chars = pattern.chars
      i = 0
      while i < chars.length
        c = chars[i]
        if c == "*" && chars[i + 1] == "*"
          tokens << ".*"
          i += 2
        elsif c == "*"
          tokens << "[^/]*"
          i += 1
        else
          tokens << Regexp.escape(c)
          i += 1
        end
      end
      Regexp.new("\\A#{tokens.join}\\z")
    end
    def branch_matches?(pattern, branch)
      return false unless pattern.is_a?(String) && branch.is_a?(String)
      branch_pattern_to_regex(pattern).match?(branch)
    rescue RegexpError, ArgumentError
      false
    end
    def branch_matches_list?(patterns, branch)
      return false unless patterns.is_a?(Array)
      included = false
      patterns.each do |raw|
        next unless raw.is_a?(String)
        if raw.start_with?("!")
          included = false if branch_matches?(raw[1..], branch)
        else
          included = true if branch_matches?(raw, branch)
        end
      end
      included
    end
    def paths_filter_excludes?(event, cfg, changed_files, changed_files_known)
      return false unless cfg.key?("paths") || cfg.key?("paths-ignore")
      return true if event == "push"
      return false unless changed_files_known
      capped_files = changed_files.first(300)
      if cfg.key?("paths")
        return true unless capped_files.any? { |f| branch_matches_list?(cfg["paths"], f) }
      end
      if cfg.key?("paths-ignore")
        return true if capped_files.all? { |f| branch_matches_list?(cfg["paths-ignore"], f) }
      end
      false
    end
    event = ARGV[0]
    cfg = JSON.parse(ARGV[1])
    changed_files_known = !ARGV[2].empty?
    changed_files = changed_files_known ? JSON.parse(ARGV[2]) : []
    puts paths_filter_excludes?(event, cfg, changed_files, changed_files_known)
  ' "$event" "$cfg_json" "$changed_files_json"
}
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' '["src/foo.py"]')
if [ "$GOT" = "false" ]; then
  pass "paths_filter_excludes?: pull_request paths matches a changed file -> not excluded, gate (a) waits for it (#655 round 16)"
else
  fail "paths_filter_excludes? (paths matches): expected false, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' '["docs/readme.md"]')
if [ "$GOT" = "true" ]; then
  pass "paths_filter_excludes?: pull_request paths matches no changed file -> excluded, consistent with GitHub never scheduling the workflow (#655 round 16)"
else
  fail "paths_filter_excludes? (paths no match): expected true, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' '["docs/readme.md","src/foo.py"]')
if [ "$GOT" = "false" ]; then
  pass "paths_filter_excludes?: pull_request paths matches at least one of several changed files -> not excluded (#655 round 16)"
else
  fail "paths_filter_excludes? (paths partial match): expected false, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths-ignore":["docs/**"]}' '["docs/readme.md"]')
if [ "$GOT" = "true" ]; then
  pass "paths_filter_excludes?: pull_request paths-ignore covers every changed file -> excluded (#655 round 16)"
else
  fail "paths_filter_excludes? (paths-ignore all covered): expected true, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths-ignore":["docs/**"]}' '["docs/readme.md","src/foo.py"]')
if [ "$GOT" = "false" ]; then
  pass "paths_filter_excludes?: pull_request paths-ignore does not cover every changed file -> not excluded, GitHub still runs it (#655 round 16)"
else
  fail "paths_filter_excludes? (paths-ignore partial): expected false, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'push' '{"paths":["src/**"]}' '["src/foo.py"]')
if [ "$GOT" = "true" ]; then
  pass "paths_filter_excludes?: push never gets the real evaluation, even when the whole-PR diff would match -- avoids the two-dot-vs-three-dot diff scope mismatch (#655 round 17)"
else
  fail "paths_filter_excludes? (push scoping): expected true, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' '')
if [ "$GOT" = "false" ]; then
  pass "paths_filter_excludes?: unknown changed-files data (fetch failed) is NOT excluded -- wait for it rather than silently pass (#655 round 17)"
else
  fail "paths_filter_excludes? (unknown changed files): expected false, got $GOT"
fi
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' '[]')
if [ "$GOT" = "true" ]; then
  pass "paths_filter_excludes?: a genuinely-known EMPTY changed-file list still excludes, distinct from unknown (#655 round 17)"
else
  fail "paths_filter_excludes? (known empty changed files): expected true, got $GOT"
fi
MANY_FILES=$(ruby -rjson -e 'puts JSON.generate((0...300).map { |i| "docs/file#{i}.md" } + ["src/matching.py"])')
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' "$MANY_FILES")
if [ "$GOT" = "true" ]; then
  pass "paths_filter_excludes?: a matching file beyond the first 300 changed files is not counted, matching GitHub's own evaluation limit (#655 round 17)"
else
  fail "paths_filter_excludes? (300-file cap): expected true, got $GOT"
fi
MANY_FILES_WITHIN_CAP=$(ruby -rjson -e 'puts JSON.generate(["src/matching.py"] + (0...299).map { |i| "docs/file#{i}.md" })')
GOT=$(paths_filter_excludes_ruby 'pull_request' '{"paths":["src/**"]}' "$MANY_FILES_WITHIN_CAP")
if [ "$GOT" = "false" ]; then
  pass "paths_filter_excludes?: a matching file within the first 300 changed files is still counted (#655 round 17)"
else
  fail "paths_filter_excludes? (within 300-file cap): expected false, got $GOT"
fi

# Codex P1 (#655 round 13, "page the rollup before scanning annex
# checks"): gh pr view --json statusCheckRollup only requests the first
# 100 contexts with no pagination -- the SAME bug already fixed in
# agent-review.yml's wait loop (round 12), missed here when that fix
# landed. Switched to a Relay-cursor paginated graphql query. workflowPath
# (derived from the workflow FILE's resourcePath) is added alongside the
# existing workflowName, since the annex contract does not guarantee a
# unique display name across a consumer's workflows (round 13, Finding 5
# below).
if grep -qF 'contexts(first: 100, after: $cursor)' "$SCRIPT" \
   && grep -qF 'pageInfo { hasNextPage endCursor }' "$SCRIPT" \
   && grep -qF 'ROLLUP_CURSOR_ARGS=(-F cursor=null)' "$SCRIPT" \
   && grep -qF 'ROLLUP_CURSOR_ARGS=(-f cursor="$ROLLUP_CURSOR")' "$SCRIPT" \
   && grep -qF 'statusCheckRollup.contexts.nodes // []' "$SCRIPT" \
   && grep -qF 'statusCheckRollup.contexts.pageInfo.hasNextPage // false' "$SCRIPT" \
   && grep -qF 'statusCheckRollup.contexts.pageInfo.endCursor // ""' "$SCRIPT" \
   && grep -qF 'workflow { name resourcePath }' "$SCRIPT" \
   && grep -qF 'workflowPath: (((.checkSuite.workflowRun.workflow.resourcePath // "") | split("/") | last) // "")' "$SCRIPT"; then
  pass "codex-review-check.sh paginates statusCheckRollup via the Relay cursor, passes null on page 1, null-coalesces empty rollup pages, and derives workflowPath from resourcePath (#655 round 13)"
else
  fail "codex-review-check.sh does not paginate the rollup, pass a null first-page cursor, null-coalesce empty pages, or derive workflowPath as expected (#655 round 13)"
fi
NULL_ROLLUP_PAGE='{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}}}}'
PAGE_NODES=$(printf '%s' "$NULL_ROLLUP_PAGE" | jq -c '(.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])')
HAS_NEXT=$(printf '%s' "$NULL_ROLLUP_PAGE" | jq -r '(.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage // false)')
END_CURSOR=$(printf '%s' "$NULL_ROLLUP_PAGE" | jq -r '(.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.endCursor // "")')
if [ "$PAGE_NODES" = "[]" ] && [ "$HAS_NEXT" = "false" ] && [ -z "$END_CURSOR" ]; then
  pass "rollup pagination extraction treats a null statusCheckRollup as an empty final page"
else
  fail "rollup pagination extraction should normalize null statusCheckRollup to []/false/empty, got nodes=$PAGE_NODES has_next=$HAS_NEXT cursor=$END_CURSOR"
fi

# Self-caught while writing the round-13 winner-selection below: piping a
# bare array literal straight into `index(.state // "")` rebinds `.` to
# that array literal for the REST of the expression, so `.state` then
# tries to index an array with a string and jq hard-errors -- but only for
# a StatusContext entry (no .status field), since a CheckRun never reaches
# this branch at all. This is the exact "sub-pipeline rebinds dot" hazard
# the required-name filter above already documents and guards against for
# $label_name. Fixed by binding .state to a variable BEFORE the
# array-literal pipe; guarded here so it cannot silently regress.
if grep -qF '((.state // "") as $ann_state | ["PENDING","EXPECTED"] | index($ann_state))' "$SCRIPT"; then
  pass "codex-review-check.sh's pending-check binds .state to a variable before the array-literal pipe, avoiding the dot-rebinding jq hazard (#655 round 13)"
else
  fail "codex-review-check.sh's pending-check does not use the safe \$ann_state binding form (#655 round 13)"
fi
if grep -qF '(["PENDING","EXPECTED"] | index(.state // ""))' "$SCRIPT"; then
  fail "codex-review-check.sh regressed to the broken index(.state) form that rebinds dot inside the array-literal pipe"
else
  pass "codex-review-check.sh does not regress to the broken pre-fix index(.state) expression"
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

# Codex P2 (#655 round 16, "don't skip opened-only annex runs"),
# REVERTED in round 17 ("do not infer opened-only runs from committer
# date"): round 16 tried to treat types: [opened] (no synchronize) as
# unfiltered when the HEAD committer date predates PR creation. Confirmed
# live: a genuinely-new synchronize push whose commit preserves an OLDER
# committer date (a rebase/cherry-pick of a stale commit) still satisfies
# that comparison, so the heuristic could say "unfiltered" for a trigger
# that will NEVER report again on that HEAD -- a real, confirmed
# permanent-wait risk, worse than the narrower gap being reopened. No
# reliable, non-spoofable signal is available from data this script
# already has, so the mechanism was removed entirely rather than patched
# further.
if ! grep -qF 'head_predates_pr_creation' "$SCRIPT" \
   && ! grep -qF 'ANNEX_PR_CREATED_AT' "$SCRIPT" \
   && ! grep -qF 'ANNEX_HEAD_COMMITTER_DATE' "$SCRIPT"; then
  pass "codex-review-check.sh no longer infers an opened-only annex is unfiltered from committer date (#655 round 17)"
else
  fail "codex-review-check.sh still carries the reverted committer-date opened-only heuristic (#655 round 17)"
fi
# End-to-end: types: [opened] alone is unconditionally filtered again
# (the deadlock scenario Codex found is empirically closed), while types
# including synchronize is unaffected (round-10 behavior preserved).
opened_only_unfiltered() {
  local types_json=$1
  ruby -rjson -e '
    types = JSON.parse(ARGV[0])
    cfg_has_types = true
    result = if cfg_has_types
      (types.is_a?(Array) && types.include?("synchronize"))
    else
      true
    end
    puts result
  ' "$types_json"
}
GOT=$(opened_only_unfiltered '["opened"]')
if [ "$GOT" = "false" ]; then
  pass "opened-only annex: types: [opened] alone is unconditionally filtered, closing the deadlock Codex found (#655 round 17)"
else
  fail "opened-only annex (reverted): expected false, got $GOT"
fi
GOT=$(opened_only_unfiltered '["opened","synchronize","reopened"]')
if [ "$GOT" = "true" ]; then
  pass "opened-only annex regression guard: types including synchronize stays unfiltered (#655 round 10 behavior preserved)"
else
  fail "opened-only annex (synchronize regression): expected true, got $GOT"
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
#
# Codex P2 (#655 round 13): this fallback has the same stale-vs-fresh
# rerun exposure the workflow-wide scan below fixes (a name match alone
# doesn't dedupe multiple reported attempts under the same name), so it
# applies the same group-by-name, pending-preferred-else-latest-completed
# winner selection -- there is exactly one possible name group here
# ("repo-lint-local", enforced by the select() below), but group_by still
# resolves the zero-matches case to an empty array with no extra
# branching, so existing single-entry fixtures are unaffected.
annex_name_fallback_bad() {
  local rollup_json=$1
  printf '%s' "$rollup_json" | jq '
    [.statusCheckRollup[] | select((.name // .context // "") == "repo-lint-local")]
    | group_by(.name // .context // "?")
    | [
        .[]
        | (map(select(if (.status != null) then (.status != "COMPLETED") else ((.state // "") as $ann_state | ["PENDING","EXPECTED"] | index($ann_state)) end))) as $pending
        | if ($pending | length) > 0
          then $pending[0]
          else (sort_by(.completedAt // .startedAt // "") | last)
          end
      ] as $winners
    | [$winners[]
        | { label: (.name // .context // "?"), workflow: (.workflowName // ""), result: (.conclusion // .state // "") }
        | select((.result != "SUCCESS") and (.result != "SKIPPED") and (.result != "NEUTRAL"))
      ]'
}
annex_name_fallback_bad_after_probe() {
  local confirmed_absent=$1 rollup_json=$2
  if [ "$confirmed_absent" = "1" ]; then
    printf '[]\n'
  else
    annex_name_fallback_bad "$rollup_json"
  fi
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
ROLLUP_CONFIRMED_ABSENT_OPTIONAL_RED='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"Optional Local CI","conclusion":"FAILURE"}]}'
GOT=$(annex_name_fallback_bad_after_probe 1 "$ROLLUP_CONFIRMED_ABSENT_OPTIONAL_RED")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "conventional-name fallback scan: a confirmed-absent annex skips the repo-lint-local fallback even if an unrelated optional same-named check is red"
else
  fail "conventional-name fallback scan (confirmed absent): expected 0, got $GOT"
fi
GOT=$(annex_name_fallback_bad_after_probe 0 "$ROLLUP_CONFIRMED_ABSENT_OPTIONAL_RED" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "conventional-name fallback scan: the same red repo-lint-local remains caught when annex identity is unknown"
else
  fail "conventional-name fallback scan (unknown probe state): expected [\"repo-lint-local\"], got $GOT"
fi
if grep -qF 'ANNEX_NAME_FALLBACK_BAD=$(echo "$ANNEX_SCAN_ROLLUP_JSON" | jq' "$SCRIPT" \
   && grep -qF 'ANNEX_CONFIRMED_ABSENT=1' "$SCRIPT" \
   && grep -qF 'if [ "$ANNEX_CONFIRMED_ABSENT" -eq 1 ]; then' "$SCRIPT"; then
  pass "codex-review-check.sh's conventional-name fallback reads from the frozen rollup but skips when the annex is confirmed absent (#655)"
else
  fail "codex-review-check.sh's conventional-name fallback scan is missing, reads from the wrong rollup variable, or lacks the confirmed-absent guard (#655)"
fi
# #655 round 13: the SAME stale-vs-fresh scenario, but through the
# conventional-name fallback specifically -- a stale FAILURE superseded by
# a later SUCCESS under the same conventional name must not block forever.
ROLLUP_403_STALE_RERUN='{"statusCheckRollup":[{"name":"repo-lint-local","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-07-01T00:05:00Z"},{"name":"repo-lint-local","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-07-01T01:05:00Z"}]}'
GOT=$(annex_name_fallback_bad "$ROLLUP_403_STALE_RERUN")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "conventional-name fallback scan: a stale FAILURE superseded by a later SUCCESS under the same name is not blocking (#655 round 13)"
else
  fail "conventional-name fallback scan (stale rerun): expected 0, got $GOT"
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
   && grep -qF 'push_unfiltered = trigger_unfiltered.call("push", ENV["ANNEX_HEAD_BRANCH"])' "$SCRIPT" \
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
#      safely enforces the annex (matched by workflow identity, immune to
#      name collisions), the merge was removed entirely in both branches:
#      the empty branch now always wipes ROLLUP_JSON (matching the
#      pre-#655 no-annex behavior), and the non-empty branch uses branch
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
# injection. Round 13 added two refinements, both mirrored here: (a)
# matching switched from the freely-editable .workflowName display string
# to the stable, file-derived .workflowPath (Finding 5 -- closes a
# collision when two workflow files declare the same top-level `name:`),
# and (b) matches are grouped by check name with a pending-preferred /
# latest-completed winner picked per name before judging bad-ness (Finding
# 3 -- so a stale failed rerun superseded by a later success no longer
# blocks forever). KEEP IN SYNC with scripts/codex-review-check.sh's
# ANNEX_WORKFLOW_MATCHES / ANNEX_WORKFLOW_BAD computation.
annex_workflow_bad() {
  local rollup_json=$1 workflow_path=$2
  printf '%s' "$rollup_json" | jq --arg workflow_path "$workflow_path" '
    [.statusCheckRollup[] | select((.workflowPath // "") == $workflow_path)]
    | group_by(.name // .context // "?")
    | [
        .[]
        | (map(select(if (.status != null) then (.status != "COMPLETED") else ((.state // "") as $ann_state | ["PENDING","EXPECTED"] | index($ann_state)) end))) as $pending
        | if ($pending | length) > 0
          then $pending[0]
          else (sort_by(.completedAt // .startedAt // "") | last)
          end
      ] as $winners
    | [$winners[]
        | {
            label: (.name // .context // "?"),
            workflow: (.workflowName // ""),
            result: (.conclusion // .state // "")
          }
        | select((.result != "SUCCESS") and (.result != "SKIPPED") and (.result != "NEUTRAL"))
      ]'
}

# ── 3. Inline logic: the workflow-wide bad-conclusion scan (#655 round 5),
#      now matched by .workflowPath (round 13). Fixtures set workflowPath
#      alongside workflowName so the existing scenarios (green/red/matrix-
#      leg/never-reported/skipped) keep exercising the same conceptual
#      points -- workflow-scoped matching, immune to check-name collision
#      -- through the new mechanism.
ROLLUP_ANNEX_REPORTED_GOOD='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"repo-lint-local","workflowPath":"repo_lint_local.yml","conclusion":"SUCCESS"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_ANNEX_REPORTED_GOOD" "repo_lint_local.yml")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a green annex report -> no bad entries"
else
  fail "workflow-wide scan (green): expected 0 bad entries, got $GOT"
fi

ROLLUP_ANNEX_REPORTED_BAD='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"repo-lint-local","workflowPath":"repo_lint_local.yml","conclusion":"FAILURE"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_ANNEX_REPORTED_BAD" "repo_lint_local.yml" | jq -c '[.[].label]')
if [ "$GOT" = '["repo-lint-local"]' ]; then
  pass "workflow-wide scan: a red annex report blocks (round 1 scenario, now via workflow scan too)"
else
  fail "workflow-wide scan (red): expected [\"repo-lint-local\"], got $GOT"
fi

# #655 round 5 Codex P2: a matrix-expanded leg is invisible to the name-based
# requirement (matrix jobs are excluded from ANNEX_CHECKS_JSON), but its
# REPORTED failure still carries the annex's own workflow identity, so the
# workflow-wide scan catches it regardless.
ROLLUP_MATRIX_LEG_FAILED='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"checks (18)","workflowName":"consumer-annex","workflowPath":"consumer-annex.yml","conclusion":"SUCCESS"},{"name":"checks (20)","workflowName":"consumer-annex","workflowPath":"consumer-annex.yml","conclusion":"FAILURE"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex.yml" | jq -c '[.[].label]')
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
GOT=$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex.yml" | jq -c '[.[].label]')
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
GOT=$(annex_workflow_bad "$ROLLUP_NEVER_REPORTED" "consumer-annex.yml")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: an annex that never reported anything is NOT blocking (no deadlock for a path-filtered-out annex, #655 round 5 P2)"
else
  fail "workflow-wide scan (never reported): expected 0 (no false block), got $GOT"
fi

# Skipped/neutral reports still pass, consistent with everywhere else.
ROLLUP_ANNEX_SKIPPED='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","workflowName":"repo-lint-local","workflowPath":"repo_lint_local.yml","conclusion":"SKIPPED"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_ANNEX_SKIPPED" "repo_lint_local.yml")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a SKIPPED annex report does not block, consistent with SUCCESS/SKIPPED/NEUTRAL elsewhere"
else
  fail "workflow-wide scan (skipped): expected 0, got $GOT"
fi

# #655 round 13 Codex P2 (Finding 3, "ignore stale annex runs after a green
# rerun"): a stale FAILURE for a check name, superseded by a LATER
# completed SUCCESS of the SAME name, must not block forever -- only the
# latest-completed entry per name is judged.
ROLLUP_STALE_RERUN='{"statusCheckRollup":[{"name":"lint-python","workflowPath":"repo_lint_local.yml","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-07-01T00:05:00Z"},{"name":"lint-python","workflowPath":"repo_lint_local.yml","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-07-01T01:05:00Z"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_STALE_RERUN" "repo_lint_local.yml")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a stale FAILURE superseded by a later SUCCESS of the same name is not blocking (#655 round 13, Finding 3)"
else
  fail "workflow-wide scan (stale rerun): expected 0, got $GOT"
fi
# The reverse must still block: a stale SUCCESS followed by a LATER
# FAILURE of the same name is genuinely currently broken.
ROLLUP_NEWLY_BROKEN='{"statusCheckRollup":[{"name":"lint-python","workflowPath":"repo_lint_local.yml","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-07-01T00:05:00Z"},{"name":"lint-python","workflowPath":"repo_lint_local.yml","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-07-01T01:05:00Z"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_NEWLY_BROKEN" "repo_lint_local.yml" | jq -c '[.[].result]')
if [ "$GOT" = '["FAILURE"]' ]; then
  pass "workflow-wide scan: a stale SUCCESS followed by a later FAILURE of the same name still blocks (#655 round 13, Finding 3 sanity)"
else
  fail "workflow-wide scan (newly broken): expected [\"FAILURE\"], got $GOT"
fi
# A still-non-terminal rerun (no completedAt) must outrank an older
# COMPLETED failure of the same name -- the winner is the pending entry,
# not the stale completed one, so gate (a) correctly waits rather than
# either wrongly clearing or wrongly reporting the OLD conclusion.
ROLLUP_PENDING_RERUN='{"statusCheckRollup":[{"name":"lint-python","workflowPath":"repo_lint_local.yml","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-07-01T00:05:00Z"},{"name":"lint-python","workflowPath":"repo_lint_local.yml","status":"IN_PROGRESS","conclusion":null}]}'
GOT=$(annex_workflow_bad "$ROLLUP_PENDING_RERUN" "repo_lint_local.yml" | jq -c '[.[].result]')
if [ "$GOT" = '[""]' ]; then
  pass "workflow-wide scan: a still-in-progress rerun outranks an older completed failure of the same name (#655 round 13, Finding 3)"
else
  fail "workflow-wide scan (pending outranks stale): expected [\"\"] (pending, not the stale FAILURE), got $GOT"
fi
# A StatusContext-shaped entry (no .status field, e.g. a legacy commit
# status) must not error out reaching this branch -- this is exactly the
# self-caught index(.state) hazard above; confirm it evaluates cleanly.
ROLLUP_STATUSCONTEXT_ANNEX='{"statusCheckRollup":[{"context":"legacy-ci","workflowPath":"repo_lint_local.yml","state":"SUCCESS"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_STATUSCONTEXT_ANNEX" "repo_lint_local.yml")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a StatusContext entry (no .status field) evaluates cleanly and a SUCCESS state is not blocking (#655 round 13, self-caught index(.state) hazard)"
else
  fail "workflow-wide scan (StatusContext entry): expected 0, got $GOT"
fi

# #655 round 13 Codex P2 (Finding 5, "disambiguate annex workflows beyond
# display name"): two DIFFERENT workflow files can declare the identical
# top-level `name:` (both display as workflowName "CI"), so matching by
# workflowPath instead of workflowName must not be confused by the
# collision -- only the entry whose workflowPath actually matches the
# target is caught, regardless of a shared workflowName.
ROLLUP_WORKFLOWNAME_COLLISION='{"statusCheckRollup":[{"name":"build","workflowName":"CI","workflowPath":"repo_lint_local.yml","conclusion":"FAILURE"},{"name":"deploy","workflowName":"CI","workflowPath":"some-other-ci.yml","conclusion":"FAILURE"}]}'
GOT=$(annex_workflow_bad "$ROLLUP_WORKFLOWNAME_COLLISION" "repo_lint_local.yml" | jq -c '[.[].label]')
if [ "$GOT" = '["build"]' ]; then
  pass "workflow-wide scan: matches by workflowPath even when workflowName collides across two different workflow files (#655 round 13, Finding 5)"
else
  fail "workflow-wide scan (workflowName collision): expected [\"build\"] only, got $GOT"
fi
GOT=$(annex_workflow_bad "$ROLLUP_WORKFLOWNAME_COLLISION" "some-other-ci.yml" | jq -c '[.[].label]')
if [ "$GOT" = '["deploy"]' ]; then
  pass "workflow-wide scan (Finding 5 sanity): the OTHER same-workflowName workflow's own failure only surfaces when IT is the scanned path"
else
  fail "workflow-wide scan (Finding 5 sanity): expected [\"deploy\"] only, got $GOT"
fi

# #655 round 8 Codex P2 ("wait for unreported unfiltered annex checks"):
# refines the round-5 "never reported -> not blocking" rule above. When
# the annex's pull_request trigger is unfiltered (guaranteed to
# eventually report), zero matches means "not scheduled yet", not "may
# never run" -- a synthetic PENDING entry is unioned in instead of
# silently passing. KEEP IN SYNC with scripts/codex-review-check.sh's
# ANNEX_WORKFLOW_MATCHES / unfiltered-zero-match branch.
annex_workflow_bad_or_pending() {
  local rollup_json=$1 workflow_path=$2 unfiltered=$3
  local match_count
  match_count=$(printf '%s' "$rollup_json" | jq --arg workflow_path "$workflow_path" '[.statusCheckRollup[] | select((.workflowPath // "") == $workflow_path)] | length')
  if [ "$match_count" -eq 0 ] && [ "$unfiltered" = "true" ]; then
    jq -n --arg workflow_path "$workflow_path" '[{label: "(not yet reported)", workflow: $workflow_path, result: "PENDING"}]'
  else
    annex_workflow_bad "$rollup_json" "$workflow_path"
  fi
}

GOT=$(annex_workflow_bad_or_pending "$ROLLUP_NEVER_REPORTED" "consumer-annex.yml" "true" | jq -c '[.[].result]')
if [ "$GOT" = '["PENDING"]' ]; then
  pass "workflow-wide scan: an unfiltered annex that never reported anything is treated as not-yet-clean, not silently passed (#655 round 8 P2)"
else
  fail "workflow-wide scan (unfiltered, never reported): expected [\"PENDING\"], got $GOT"
fi

GOT=$(annex_workflow_bad_or_pending "$ROLLUP_NEVER_REPORTED" "consumer-annex.yml" "false")
if [ "$(echo "$GOT" | jq 'length')" = "0" ]; then
  pass "workflow-wide scan: a path-filtered (unfiltered=false) annex that never reported anything is still NOT blocking, preserving round 5 (#655 round 8)"
else
  fail "workflow-wide scan (path-filtered, never reported): expected 0 (round-5 behavior preserved), got $GOT"
fi

GOT=$(annex_workflow_bad_or_pending "$ROLLUP_ANNEX_REPORTED_GOOD" "repo_lint_local.yml" "true")
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
UNIONED_CONVENTIONAL=$(echo "$(bad_checks "$ROLLUP_ANNEX_REPORTED_BAD" "$BRANCH_PROTECTION_NAMES")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_ANNEX_REPORTED_BAD" "repo_lint_local.yml")" '(. + $extra) | unique')
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
UNIONED=$(echo "$(bad_checks "$ROLLUP_MATRIX_LEG_FAILED" "$BRANCH_PROTECTION_NAMES")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_MATRIX_LEG_FAILED" "consumer-annex.yml")" '(. + $extra) | unique')
GOT=$(echo "$UNIONED" | jq -c '[.[].label]')
if [ "$GOT" = '["checks (20)"]' ]; then
  pass "end-to-end: unioning the workflow-wide scan catches the matrix-leg failure the name-scoped filter alone misses (#655 round 5)"
else
  fail "end-to-end (matrix leg, unioned): expected [\"checks (20)\"], got $GOT"
fi

ROLLUP_SKIPPED_ANNEX='{"statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"},{"name":"repo-lint-local","conclusion":"SKIPPED"}]}'
UNIONED_SKIPPED=$(echo "$(bad_checks "$ROLLUP_SKIPPED_ANNEX" "$BRANCH_PROTECTION_NAMES")" | jq -c --argjson extra "$(annex_workflow_bad "$ROLLUP_SKIPPED_ANNEX" "repo_lint_local.yml")" '(. + $extra) | unique')
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
ROLLUP_NAME_COLLISION='{"statusCheckRollup":[{"name":"lint","workflowName":"repo-lint","conclusion":"SUCCESS"},{"name":"test","workflowName":"Consumer Annex","workflowPath":"consumer-annex.yml","conclusion":"FAILURE"},{"name":"test","workflowName":"Some Unrelated Optional Workflow","workflowPath":"some-unrelated-optional-workflow.yml","conclusion":"FAILURE"}]}'
GOT=$(bad_checks "$ROLLUP_NAME_COLLISION" "$BRANCH_PROTECTION_NAMES" | jq -c '[.[].workflow]')
if [ "$GOT" = '[]' ]; then
  pass "end-to-end (Finding 2): the name-scoped filter alone does not see EITHER same-named 'test' check, since neither is in required_names post-round-10"
else
  fail "end-to-end (Finding 2, name-scoped alone): expected [] (no annex-name merge to widen scope), got $GOT"
fi
GOT=$(annex_workflow_bad "$ROLLUP_NAME_COLLISION" "consumer-annex.yml" | jq -c '[.[].workflow]')
if [ "$GOT" = '["Consumer Annex"]' ]; then
  pass "end-to-end (Finding 2): the workflow-wide scan still catches the annex's own red 'test' job, unconfused by the unrelated same-named check"
else
  fail "end-to-end (Finding 2, workflow-wide scan): expected [\"Consumer Annex\"] only (not the unrelated same-named check), got $GOT"
fi
GOT=$(annex_workflow_bad "$ROLLUP_NAME_COLLISION" "some-unrelated-optional-workflow.yml" | jq -c '[.[].workflow]')
if [ "$GOT" = '["Some Unrelated Optional Workflow"]' ]; then
  pass "end-to-end (Finding 2 sanity): the unrelated workflow's own red check would ONLY surface if IT were the scanned workflow, confirming the scan is workflow-scoped not name-scoped"
else
  fail "end-to-end (Finding 2 sanity): expected the unrelated workflow scan to only see its own entry, got $GOT"
fi

echo ""
echo "test_codex_review_check_required_checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
