#!/usr/bin/env bash
# tests/test_label_removal_guard.sh
#
# Unit tests for scripts/hooks/label-removal-guard.sh — the PreToolUse
# hook that blocks `gh pr edit --remove-label / --add-label` for the
# human-action labels (needs-external-review, needs-human-review,
# policy-violation) and the asymmetric human-hold label.
#
# Coverage focus is the consolidated `gh ... pr edit` detection plus
# the `-R` / `--repo` interspersed-argument cases (#287). Earlier
# revisions of the hook (#172 → #271 → #277) used multiple `case` glob
# patterns to handle different positions of `-R` / `--repo`; the
# current adjacency-anchored regex (`gh.*pr[[:space:]]+edit`) plus a
# whole-token walk subsumes those variants. These tests prove the
# simplified form still catches every position the older patterns
# explicitly enumerated.
#
# Hook contract: reads a JSON envelope on stdin (PreToolUse passes
# `{tool_input: {command: "..."}}`). Tokenizes with shlex. Exits 0 to
# allow, 2 to block.
#
# Bash 3.2 portable. Mirrors the shape of tests/test_gh_pr_guard.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/label-removal-guard.sh"

[[ -x "$HOOK" ]] || { echo "missing or non-executable $HOOK" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available (label-removal-guard.sh requires python3 for tokenization)" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (test builds JSON payloads with jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/label-removal-guard-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Run the hook with the given command. Returns the hook's exit code
# (no STDERR capture — assert_block_blocked / assert_allow only care
# about the code).
run_hook() {
  local cmd="$1"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  bash "$HOOK" <<<"$payload"
}

# Helper assertions. Each takes a description + command, runs the hook,
# and tallies PASS/FAIL according to the expected exit code.
assert_blocked() {
  local desc="$1"
  local cmd="$2"
  local rc=0
  run_hook "$cmd" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "$desc"
  else
    fail "$desc (expected exit 2, got $rc)"
  fi
}

assert_allowed() {
  local desc="$1"
  local cmd="$2"
  local rc=0
  run_hook "$cmd" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc (expected exit 0, got $rc)"
  fi
}

# ─── Baseline: the bare form blocks for each prohibited label ───────
assert_blocked "baseline: --remove-label needs-external-review (bare)" \
  "gh pr edit 1 --remove-label needs-external-review"
assert_blocked "baseline: --remove-label needs-human-review (bare)" \
  "gh pr edit 1 --remove-label needs-human-review"
assert_blocked "baseline: --remove-label policy-violation (bare)" \
  "gh pr edit 1 --remove-label policy-violation"
assert_blocked "baseline: --add-label policy-violation (bare)" \
  "gh pr edit 1 --add-label policy-violation"
assert_blocked "baseline: --remove-label human-hold (bare)" \
  "gh pr edit 1 --remove-label human-hold"
assert_allowed "baseline: --add-label human-hold (bare)" \
  "gh pr edit 1 --add-label human-hold"

# ─── -R / --repo interspersed BEFORE `pr edit` ──────────────────────
# gh accepts a global -R/--repo before the subcommand. The simplified
# adjacency-anchored regex (`gh.*pr[[:space:]]+edit`) plus the
# post-tokenize token walk must still catch every position.
assert_blocked "global -R before pr: gh -R owner/repo pr edit ... --remove-label needs-external-review" \
  "gh -R nathanjohnpayne/mergepath pr edit 1 --remove-label needs-external-review"
assert_blocked "global --repo before pr: gh --repo owner/repo pr edit ... --remove-label needs-human-review" \
  "gh --repo nathanjohnpayne/mergepath pr edit 1 --remove-label needs-human-review"
assert_blocked "global --repo= form: gh --repo=owner/repo pr edit ... --remove-label policy-violation" \
  "gh --repo=nathanjohnpayne/mergepath pr edit 1 --remove-label policy-violation"

# ─── -R / --repo interspersed AFTER `pr edit` ───────────────────────
# gh also accepts the repo selector after the subcommand (the more
# common form in CI scripts).
assert_blocked "post-edit -R: gh pr edit 1 -R owner/repo --remove-label needs-external-review" \
  "gh pr edit 1 -R nathanjohnpayne/mergepath --remove-label needs-external-review"
assert_blocked "post-edit --repo: gh pr edit 1 --repo owner/repo --remove-label needs-human-review" \
  "gh pr edit 1 --repo nathanjohnpayne/mergepath --remove-label needs-human-review"
assert_blocked "post-edit --repo before PR#: gh pr edit --repo owner/repo 1 --remove-label policy-violation" \
  "gh pr edit --repo nathanjohnpayne/mergepath 1 --remove-label policy-violation"

# ─── -R / --repo with --remove-label= flag-value syntax ─────────────
assert_blocked "post-edit -R + --remove-label= form" \
  "gh pr edit 1 -R owner/repo --remove-label=needs-external-review"
assert_blocked "pre-edit --repo + --remove-label= form" \
  "gh --repo owner/repo pr edit 1 --remove-label=policy-violation"
assert_blocked "pre-edit --repo + --remove-label=human-hold form" \
  "gh --repo owner/repo pr edit 1 --remove-label=human-hold"

# ─── -R / --repo with comma-separated label list ────────────────────
# Per the existing comma-split logic, each segment is checked. A
# prohibited label hiding in a multi-label remove must still block,
# regardless of where -R appears.
assert_blocked "comma-list with prohibited segment, -R after edit" \
  "gh pr edit 1 -R owner/repo --remove-label foo,needs-external-review,bar"
assert_blocked "comma-list with prohibited segment, --repo before pr" \
  "gh --repo owner/repo pr edit 1 --remove-label foo,policy-violation"
assert_blocked "comma-list with human-hold removal segment" \
  "gh pr edit 1 --remove-label foo,human-hold,bar"
padded_human_hold_remove=$'gh pr edit 1 --remove-label "foo,\t human-hold \t,bar"'
assert_blocked "comma-list with whitespace-padded human-hold removal segment" \
  "$padded_human_hold_remove"
padded_policy_add=$'gh pr edit 1 --add-label "foo,\t policy-violation \t,bar"'
assert_blocked "comma-list with whitespace-padded policy-violation add segment" \
  "$padded_policy_add"

# ─── Allow paths: -R / --repo present, non-prohibited label ─────────
# The simplified pattern must not over-block — `gh pr edit` with a
# non-prohibited label, with -R / --repo in either position, stays
# allowed.
assert_allowed "allow: gh pr edit ... --remove-label some-unrelated-label" \
  "gh pr edit 1 --remove-label some-unrelated-label"
assert_allowed "allow: -R before pr, unrelated remove" \
  "gh -R owner/repo pr edit 1 --remove-label some-unrelated-label"
assert_allowed "allow: --repo after edit, unrelated remove" \
  "gh pr edit 1 --repo owner/repo --remove-label some-unrelated-label"
assert_allowed "allow: --add-label needs-foo (not in prohibited set)" \
  "gh pr edit 1 --add-label needs-foo"
assert_allowed "allow: --add-label=human-hold (hard hold is agent-addable)" \
  "gh pr edit 1 --add-label=human-hold"
# decision-needed is an issue-triage label, NOT a Label-Gate merge-stop
# (its blocking set is exactly needs-external-review / needs-human-review /
# policy-violation / human-hold). So the removal guard must not treat it as
# protected — agents may add or remove it freely. Pins the #496 resolution:
# the label's description no longer implies a merge block it never enforced.
assert_allowed "allow: --remove-label decision-needed (issue-triage, not protected; #496)" \
  "gh pr edit 1 --remove-label decision-needed"
assert_allowed "allow: --add-label decision-needed (not in the merge blocking set; #496)" \
  "gh pr edit 1 --add-label decision-needed"

# ─── Allow paths: non-edit subcommands with -R / --repo ─────────────
# `gh pr view`, `gh pr create` etc. must never be blocked by this
# hook, regardless of where -R lives.
assert_allowed "allow: gh -R owner/repo pr view 1" \
  "gh -R owner/repo pr view 1"
assert_allowed "allow: gh --repo owner/repo pr create --title x --body y" \
  "gh --repo owner/repo pr create --title x --body y"
assert_allowed "allow: gh pr list --repo owner/repo" \
  "gh pr list --repo owner/repo"

# ─── Shell-expansion guard (#172): still blocked under -R / --repo ──
assert_blocked "expansion under -R: --remove-label \"\$BLOCK_LABEL\"" \
  'gh -R owner/repo pr edit 1 --remove-label "$BLOCK_LABEL"'
assert_blocked "expansion under --repo: --remove-label \`echo policy-violation\`" \
  'gh pr edit 1 --repo owner/repo --remove-label `echo policy-violation`'

echo
echo "Total: $((PASS + FAIL)) — PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
