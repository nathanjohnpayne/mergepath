#!/usr/bin/env bash
# Regression coverage for scripts/ci/check_no_bare_gh_writes (#466).
#
# The check computes REPO_ROOT from its own location and scans
# REPO_ROOT/scripts. We copy it into a temp repo root, drop fixture
# scripts under scripts/, and assert the bare-gh-write detector:
#   - flags compact `gh api` write forms (-XPOST, --method=POST) that the
#     prior space-requiring matcher missed,
#   - still flags the spaced forms (-X POST),
#   - refuses a bare NO_BARE_GH_WRITE_EXEMPT: marker with no reason,
#   - honors NO_BARE_GH_WRITE_EXEMPT: WITH a reason.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_no_bare_gh_writes"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Run the check against a temp repo whose scripts/fixture.sh contains $1.
# Echoes the check's exit code.
run_check_on() {
  local content="$1"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/no-bare-gh.XXXXXX")"
  mkdir -p "$tmp/scripts/ci"
  cp "$CHECK" "$tmp/scripts/ci/check_no_bare_gh_writes"
  chmod +x "$tmp/scripts/ci/check_no_bare_gh_writes"
  printf '%s\n' "$content" > "$tmp/scripts/fixture.sh"
  local rc=0
  ( cd "$tmp" && ./scripts/ci/check_no_bare_gh_writes ) >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp"
  printf '%s' "$rc"
}

assert_flagged() {
  local label="$1" content="$2"
  local rc; rc=$(run_check_on "$content")
  if [ "$rc" -eq 1 ]; then pass "$label (flagged)"; else fail "$label: expected flag (rc 1), got rc=$rc"; fi
}

assert_clean() {
  local label="$1" content="$2"
  local rc; rc=$(run_check_on "$content")
  if [ "$rc" -eq 0 ]; then pass "$label (clean)"; else fail "$label: expected clean (rc 0), got rc=$rc"; fi
}

# Compact gh api write forms — the #466 gap.
assert_flagged "compact -XPOST merge"        'gh api -XPOST repos/o/r/pulls/1/merge'
assert_flagged "compact --method=POST"       'gh api --method=POST repos/o/r/issues/1/comments'
assert_flagged "compact -XDELETE"            'gh api -XDELETE repos/o/r/issues/comments/9'
# Spaced forms still flagged (no regression).
assert_flagged "spaced -X POST still flagged" 'gh api -X POST repos/o/r/pulls/1/merge'
assert_flagged "spaced --method PATCH"        'gh api --method PATCH repos/o/r/pulls/comments/9'
# A plain read is not flagged.
assert_clean   "gh api GET not flagged"       'gh api repos/o/r/pulls/1 --jq .state'

# Exemption marker hardening — bare marker no longer bypasses.
assert_flagged "bare exemption marker rejected" 'gh pr merge 1 --squash  # NO_BARE_GH_WRITE_EXEMPT:'

# examples/ scripts are exempt (#455 wave): a consumer's stray illustrative
# example under scripts/*/examples/ must not break the required lint.
# run_check_on writes to scripts/fixture.sh, so build the examples/ layout here.
examples_rc=0
et="$(mktemp -d "${TMPDIR:-/tmp}/no-bare-gh-ex.XXXXXX")"
mkdir -p "$et/scripts/ci" "$et/scripts/gh-projects/examples/matchline"
cp "$CHECK" "$et/scripts/ci/check_no_bare_gh_writes"
chmod +x "$et/scripts/ci/check_no_bare_gh_writes"
printf 'gh issue edit "$n" --repo "$R" --add-assignee me\n' > "$et/scripts/gh-projects/examples/matchline/create-issues.sh"
( cd "$et" && ./scripts/ci/check_no_bare_gh_writes ) >/dev/null 2>&1 || examples_rc=$?
rm -rf "$et"
if [ "$examples_rc" -eq 0 ]; then pass "bare gh write under examples/ is exempt (clean)"; else fail "examples/ exemption: expected clean (rc 0), got rc=$examples_rc"; fi
assert_clean   "exemption WITH reason honored"  'gh pr merge 1 --squash  # NO_BARE_GH_WRITE_EXEMPT: covered by gh-as-author in caller'

# echo/printf substitution masking — the #533 gap. A gh WRITE hidden in an
# echo/printf command substitution must still be CAUGHT (the prior exemption
# only negative-checked gh pr|issue|api, so non-pr/issue/api write verbs and
# gh api -X POST slipped through). Read-only / non-gh substitutions stay EXEMPT.
assert_flagged "echo \$(gh repo create) caught"      'echo "$(gh repo create x)"'
assert_flagged "printf \$(gh secret set) caught"     "printf '%s' \"\$(gh secret set X)\""
assert_flagged "echo \$(gh variable set) caught"     'echo "$(gh variable set X)"'
assert_flagged "echo backtick gh repo delete caught" 'echo `gh repo delete z`'
assert_flagged "echo \$(gh api -X POST) caught"      'echo "$(gh api -X POST repos/o/r/x)"'
# Regression (#540): a ) inside '...' or "..." within $() must NOT end
# command-substitution extraction early — a gh write AFTER the quoted
# paren is still caught (the prior walk closed the span on the quoted )).
assert_flagged "quoted-paren in cmdsub before gh write caught" "echo \"\$(printf '%s' ')'; gh repo create x)\""
# A bare gh label create (not inside echo) is — and stays — caught.
assert_flagged "bare gh label create caught"         'gh label create urgent --color FF0000'
# Controls: a read inside a substitution, and a non-gh substitution, stay exempt.
assert_clean   "echo \$(gh pr view) stays exempt"    'echo "$(gh pr view 1)"'
assert_clean   "echo \$(date) stays exempt"          'echo "$(date)"'
# Control for the #540 regression: a quoted ) inside $() with NO gh write
# stays exempt (the quote-aware walk must not over-flag).
assert_clean   "quoted-paren in cmdsub, no gh write, exempt"  "echo \"\$(printf '%s' ')')\""
# #540 P2 (4a review): a $( inside SINGLE quotes, or an escaped \$( in
# double quotes, is a literal — bash runs no substitution — so an echo of
# such help/example text must NOT be flagged as a write.
assert_clean   "single-quoted dollar-paren literal exempt"   "echo '\$(gh repo create x)'"
assert_clean   "escaped dollar-paren in dquotes exempt"      'echo "\$(gh repo create x)"'
# Regression: a gh write spelled in echo TEXT but OUTSIDE the substitution
# (e.g. a log line whose only substitution is $(date)) must stay exempt —
# the masking fix must not over-match plain documentation text.
assert_clean   "gh write text outside subst exempt"  'echo "$(date -u) create Project v2: gh project create --owner o --title t"'

# #553 (Major): the echo/printf exemption must cover ONLY the echo/printf
# command, NOT a second command chained after a top-level separator. `echo ok;
# gh pr merge 1` previously slipped through because the branch returned exempt
# without scanning past the `;`. Re-check the tail after the first top-level
# (unquoted, non-substitution) separator, recursively. Echoed TEXT, pipes into
# non-gh commands, and chained WRAPPED writes stay exempt.
assert_flagged "echo then ;-chained bare gh merge caught"     'echo ok; gh pr merge 1'
assert_flagged "echo then &&-chained bare gh merge caught"    'echo done && gh pr merge 1'
assert_flagged "printf then ;-chained gh secret set caught"   "printf '%s' done; gh secret set X"
assert_flagged "double echo then chained bare gh merge caught" 'echo a; echo b; gh pr merge 1'
assert_flagged "echo piped into bare gh merge caught"         'echo body | gh pr merge 1'
assert_clean   "echoed gh-write TEXT (no chained cmd) exempt"  'echo "gh pr merge 1 is documented here"'
assert_clean   "echo piped into a non-gh command exempt"       'echo ok | grep gh'
assert_clean   "echo then ;-chained WRAPPED gh merge exempt"   'echo ok; scripts/gh-as-author.sh -- gh pr merge 1'

# #573 (Major): an exempt WRAPPED / helper write must cover ONLY the wrapped
# command, NOT a bare gh write chained after a top-level separator on the same
# line. Before the fix the wrapper exemption returned clean for the whole line,
# shielding the trailing bare `gh pr create` from detection.
assert_flagged "wrapped merge then &&-chained bare gh create caught (#573)" \
  'scripts/gh-as-author.sh -- gh pr merge 1 && gh pr create --title t --body b'
assert_flagged "wrapped merge then ;-chained bare gh create caught (#573)" \
  'scripts/gh-as-author.sh -- gh pr merge 1 ; gh pr create --title t --body b'
assert_flagged "reviewer-wrapped comment then &&-chained bare gh comment caught (#573)" \
  'scripts/gh-as-reviewer.sh -- gh pr comment 1 --body ok && gh issue comment 2 --body hi'
assert_flagged "helper-fn write then &&-chained bare gh merge caught (#573)" \
  'sync_author_gh pr merge 1 && gh pr merge 2 --admin'
# Control: two chained WRAPPED writes both stay exempt (no bare write present).
assert_clean   "wrapped merge then &&-chained WRAPPED create stays exempt (#573)" \
  'scripts/gh-as-author.sh -- gh pr merge 1 && scripts/gh-as-author.sh -- gh pr create --title t --body "Authoring-Agent: claude"'
# Control: a wrapped write with a trailing non-gh command stays exempt.
assert_clean   "wrapped merge then &&-chained non-gh command stays exempt (#573)" \
  'scripts/gh-as-author.sh -- gh pr merge 1 && echo done'

# CodeRabbit Major on #611 — the MIRROR direction: a bare gh write BEFORE an
# exempt wrapped write on the same line must also be caught. The wrapper
# regexes match anywhere in the line, so before the split-scan fix the whole
# line was exempted and the bare HEAD escaped.
assert_flagged "bare gh create then &&-chained wrapped merge caught (head shielding, #611)" \
  'gh pr create --title t --body b && scripts/gh-as-author.sh -- gh pr merge 1'
assert_flagged "bare gh comment then ;-chained reviewer-wrapped review caught (head shielding, #611)" \
  'gh issue comment 2 --body hi ; scripts/gh-as-reviewer.sh -- gh pr review 1 --comment --body ok'
assert_flagged "bare write SANDWICHED between two wrapped writes caught (#611)" \
  'scripts/gh-as-author.sh -- gh pr merge 1 && gh pr edit 2 --title x && scripts/gh-as-author.sh -- gh pr merge 3'
# Control: non-gh head then a wrapped write stays exempt.
assert_clean   "non-gh head then &&-chained wrapped merge stays exempt (#611)" \
  'echo starting && scripts/gh-as-author.sh -- gh pr merge 1'

echo ""
echo "test_check_no_bare_gh_writes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
