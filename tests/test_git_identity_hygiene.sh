#!/usr/bin/env bash
# tests/test_git_identity_hygiene.sh
#
# Unit tests for scripts/ci/check_git_identity_hygiene, the regression
# guard for #777 (a repo-local git identity override that misattributed
# and unsigned every subsequent commit, twice on main).
#
# The check has three parts and each is exercised here:
#   A. the live-repo assertion (a local/worktree identity override fails);
#   B. the `--snapshot` baseline comparison (.git/config must not move
#      while the suite runs);
#   C. the static scan for unscoped `git config <identity-key> <value>`.
#
# Plus the re-run of A and B AFTER the paired regression suite, which is
# what extends the "nothing moved .git/config" guarantee to the end of
# the CI job rather than to the step before its last one.
#
# Every case pivots the check onto a fixture tree via
# MERGEPATH_GIT_IDENTITY_ROOT, so nothing here touches the real repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_git_identity_hygiene"

[[ -f "$CHECK" ]] || { echo "missing $CHECK" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/git-identity-hygiene-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a fixture tree containing the mergepath hub marker (so Part C's
# static scan is active) plus one file with the given content, then run
# the check against it. Sets OUT and RC.
FIXTURE_SEQ=0
run_on_fixture() {
  local rel="$1" content="$2"
  FIXTURE_SEQ=$((FIXTURE_SEQ + 1))
  local tree="$WORKDIR/fixture-$FIXTURE_SEQ"
  mkdir -p "$tree/scripts" "$tree/$(dirname "$rel")"
  printf '#!/usr/bin/env bash\n' > "$tree/scripts/sync-to-downstream.sh"
  printf '%s' "$content" > "$tree/$rel"
  set +e
  OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$tree" bash "$CHECK" 2>&1)"
  RC=$?
  set -e
}

# ── Part C: the static scan ───────────────────────────────────────────

# Case 1: a fixture whose every write targets a repo explicitly → PASS.
run_on_fixture "tests/clean.sh" '#!/usr/bin/env bash
git init -q "$FIX"
git -C "$FIX" config user.email "t@t"
git -C "$FIX" config user.name "t"
git -C "$FIX" config commit.gpgsign false
'
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "PASS"; then
  pass "scoped -C writes: clean"
else
  fail "scoped -C writes: rc=$RC out=$OUT"
fi

# Case 2: the #777 shape — an unscoped write in a shell script → FAIL.
run_on_fixture "tests/leaky.sh" '#!/usr/bin/env bash
cd "$FIX"
git config user.email "test@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "unscoped git identity write" \
  && printf '%s' "$OUT" | grep -q "tests/leaky.sh:3"; then
  pass "unscoped user.email in a shell script: caught, with path and line"
else
  fail "unscoped user.email in a shell script: rc=$RC out=$OUT"
fi

# Case 3: the ACTUAL #777 writer was a documented snippet, not a test —
# REVIEW_POLICY.md instructed a bare repo-local `git config user.email`
# with a fixture address, and agents ran it. Markdown must be in scope.
run_on_fixture "REVIEW_POLICY.md" '# Policy

```bash
git config user.name "nathanjohnpayne"
git config user.email "nathan@nathanjohnpayne.example"
```
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "REVIEW_POLICY.md:4" \
  && printf '%s' "$OUT" | grep -q "REVIEW_POLICY.md:5"; then
  pass "unscoped identity write in Markdown: caught (the real #777 writer)"
else
  fail "unscoped identity write in Markdown: rc=$RC out=$OUT"
fi

# Case 4: `--global` is an out-of-repo scope and is the documented form.
run_on_fixture "docs/setup.md" '# Setup

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```
'
if [ "$RC" = "0" ]; then
  pass "--global writes: allowed"
else
  fail "--global writes: rc=$RC out=$OUT"
fi

# Case 5: `git -c key=value <cmd>` is an ephemeral per-command override.
# It writes no file, so it must never be flagged. Note the lowercase -c
# is a different flag from the -C the check accepts as a repo target.
run_on_fixture "tests/ephemeral.sh" '#!/usr/bin/env bash
git -C "$FIX" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m x
'
if [ "$RC" = "0" ]; then
  pass "ephemeral git -c overrides: allowed"
else
  fail "ephemeral git -c overrides: rc=$RC out=$OUT"
fi

# Case 6: reads and removals are not identity writes.
run_on_fixture "tests/reads.sh" '#!/usr/bin/env bash
who=$(git config --get user.email)
git config --local --unset user.email
git config --local --unset-all commit.gpgsign
echo "$who"
'
if [ "$RC" = "0" ]; then
  pass "--get / --unset forms: allowed"
else
  fail "--get / --unset forms: rc=$RC out=$OUT"
fi

# Case 7: signing keys are part of the identity surface.
run_on_fixture "tests/signing.sh" '#!/usr/bin/env bash
git config commit.gpgsign false
git config tag.gpgsign false
git config user.signingkey ABC123
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/signing.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/signing.sh:3" \
  && printf '%s' "$OUT" | grep -q "tests/signing.sh:4"; then
  pass "unscoped gpgsign / signingkey writes: caught"
else
  fail "unscoped gpgsign / signingkey writes: rc=$RC out=$OUT"
fi

# Case 8: a documented exception opts a line out.
run_on_fixture "tests/exempt.sh" '#!/usr/bin/env bash
git config user.email "t@t"  # GIT_IDENTITY_SCOPE_EXEMPT: deliberate, runs only in a container
'
if [ "$RC" = "0" ]; then
  pass "GIT_IDENTITY_SCOPE_EXEMPT with a reason: allowed"
else
  fail "GIT_IDENTITY_SCOPE_EXEMPT with a reason: rc=$RC out=$OUT"
fi

# Case 9: generated PRD mirrors are excluded — a hit there is only
# fixable at the central docs canonical source, so failing on it would
# be unactionable in this repo.
run_on_fixture "docs/projects/mergepath/prds/mergepath.md" '# PRD

```bash
git config user.email "nathan@nathanjohnpayne.example"
```
'
if [ "$RC" = "0" ]; then
  pass "generated PRD mirror: excluded from the scan"
else
  fail "generated PRD mirror: rc=$RC out=$OUT"
fi

# Case 10: consumer safety — scripts/ci/ is a propagated kit, and
# consumers carry bootstrap-frozen copies of the files fixed upstream.
# Without the mergepath marker the static scan must not run at all.
CONSUMER="$WORKDIR/consumer"
mkdir -p "$CONSUMER/tests"
cat > "$CONSUMER/tests/leaky.sh" <<'EOF'
#!/usr/bin/env bash
git config user.email "test@example.com"
EOF
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$CONSUMER" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "Part C skipped (consumer checkout"; then
  pass "consumer checkout (no sync-to-downstream.sh): static scan skipped"
else
  fail "consumer checkout: rc=$RC out=$OUT"
fi

# Case 11: a backslash continuation between `git` and `config`. Neither
# physical line matches on its own — the first carries no `config`, the
# second no `git` — so a line-at-a-time scan waves through exactly the
# write this check exists to reject. The command is reported at the line
# the logical command STARTS on.
run_on_fixture "tests/split-verb.sh" '#!/usr/bin/env bash
git \
config user.email "leak@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "unscoped git identity write" \
  && printf '%s' "$OUT" | grep -q "tests/split-verb.sh:2"; then
  pass "continuation between git and config: caught"
else
  fail "continuation between git and config: rc=$RC out=$OUT"
fi

# Case 12: the other split — the value moves to the next physical line,
# so the key is followed by a line continuation rather than a value token.
run_on_fixture "tests/split-value.sh" '#!/usr/bin/env bash
git config user.email \
  "leak@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/split-value.sh:2"; then
  pass "continuation between key and value: caught"
else
  fail "continuation between key and value: rc=$RC out=$OUT"
fi

# Case 13: joining must not invent hits. A continued command whose scope
# flag sits on its own physical line is correctly scoped and must pass —
# the suppressors are read off the whole logical command, not one line.
run_on_fixture "tests/split-global.sh" '#!/usr/bin/env bash
git config \
  --global \
  user.email "you@example.com"
'
if [ "$RC" = "0" ]; then
  pass "continued --global write: allowed"
else
  fail "continued --global write: rc=$RC out=$OUT"
fi

# Case 14: a shell command cannot carry a trailing `#` comment on any
# physical line but its last, so a multi-line command has nowhere else
# to put its exemption marker. The marker must therefore exempt the
# whole logical command, not just the physical line it sits on.
run_on_fixture "tests/split-exempt.sh" '#!/usr/bin/env bash
git config user.email \
  "t@t"  # GIT_IDENTITY_SCOPE_EXEMPT: deliberate, runs only in a container
'
if [ "$RC" = "0" ]; then
  pass "exemption marker on the last line of a continued command: allowed"
else
  fail "exemption marker on a continued command: rc=$RC out=$OUT"
fi

# Case 15: the marker must not bleed across the lines a backslash joins.
# An exempt write whose line happens to end in `\` swallows the next
# physical line into its group — but that line is a self-contained
# unscoped write and nothing exempts it, so it must still be caught.
run_on_fixture "tests/bleed-first.sh" '#!/usr/bin/env bash
git config user.email "t@t"  # GIT_IDENTITY_SCOPE_EXEMPT: fixture, container only \
git config user.email "leak@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/bleed-first.sh:3" \
  && ! printf '%s' "$OUT" | grep -q "tests/bleed-first.sh:2"; then
  pass "exempt line joined to an unscoped write: only the write is caught"
else
  fail "marker bleeding forward across a join: rc=$RC out=$OUT"
fi

# Case 16: the same in the other order — the marker arriving LATER in the
# group must not reach back and exempt the write that opened it.
run_on_fixture "tests/bleed-second.sh" '#!/usr/bin/env bash
git config user.email "leak@example.com" \
git config user.email "t@t"  # GIT_IDENTITY_SCOPE_EXEMPT: fixture, container only
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/bleed-second.sh:2" \
  && ! printf '%s' "$OUT" | grep -q "tests/bleed-second.sh:3"; then
  pass "unscoped write joined to an exempt line: still caught"
else
  fail "marker bleeding backward across a join: rc=$RC out=$OUT"
fi

# Case 17: Markdown is where an accidental join is easiest to arrange —
# a trailing `\` is a hard line break there, not a shell continuation, so
# an exempt example can end in one with a live write on the next line.
run_on_fixture "docs/bleed.md" '# Doc

    git config user.email "t@t"  # GIT_IDENTITY_SCOPE_EXEMPT: fixture, container only \
    git config user.email "leak@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "docs/bleed.md:4"; then
  pass "Markdown hard break after an exempt example: next write still caught"
else
  fail "marker bleeding across a Markdown hard break: rc=$RC out=$OUT"
fi

# Case 18: a group holding more than one offending physical line reports
# EVERY one of them. Listing only the first hands an operator one line to
# fix, after which the re-run fails on the next.
run_on_fixture "tests/two-hits.sh" '#!/usr/bin/env bash
git config user.email "leak1@example.com" \
git config user.name "leak2"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/two-hits.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/two-hits.sh:3"; then
  pass "two offending lines in one joined group: both reported"
else
  fail "joined group reporting only its first offender: rc=$RC out=$OUT"
fi

# ── Part A: the live-repo identity assertion ──────────────────────────

IDREPO="$WORKDIR/idrepo"
git init -q -b main "$IDREPO"
printf '#!/usr/bin/env bash\n' > "$IDREPO/marker.sh"

# Case 19: a clean fixture repo passes.
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "fixture repo with no local identity: clean"
else
  fail "fixture repo with no local identity: rc=$RC out=$OUT"
fi

# Case 20: the exact #777 corruption — a repo-local user block plus a
# disabled gpgsign — must fail, naming every offending key.
git -C "$IDREPO" config --local user.name "nathanjohnpayne"
git -C "$IDREPO" config --local user.email "nathan@nathanjohnpayne.example"
git -C "$IDREPO" config --local commit.gpgsign false
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "repo-local git identity override" \
  && printf '%s' "$OUT" | grep -q "local: user.name = nathanjohnpayne" \
  && printf '%s' "$OUT" | grep -q "local: user.email = nathan@nathanjohnpayne.example" \
  && printf '%s' "$OUT" | grep -q "local: commit.gpgsign = false"; then
  pass "repo-local identity override: caught, naming every key"
else
  fail "repo-local identity override: rc=$RC out=$OUT"
fi

# Case 21: the remediation must clear the offenders it just reported.
# `user.signingkey` and `tag.gpgsign` are checked keys, and `--worktree`
# is a checked scope, so a fixed three-command `--local` block would
# print instructions that clear nothing and leave the next run failing
# identically. Each command is generated from a real offender.
SIGREPO="$WORKDIR/sigrepo"
git init -q -b main "$SIGREPO"
git -C "$SIGREPO" config --local extensions.worktreeConfig true
git -C "$SIGREPO" config --local user.signingkey ABC123
git -C "$SIGREPO" config --local tag.gpgsign false
git -C "$SIGREPO" config --worktree user.email "wt@example.com"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SIGREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q -- "git config --local --unset-all user.signingkey" \
  && printf '%s' "$OUT" | grep -q -- "git config --local --unset-all tag.gpgsign" \
  && printf '%s' "$OUT" | grep -q -- "git config --worktree --unset-all user.email"; then
  pass "remediation: one unset command per offender, in its own scope"
else
  fail "remediation commands: rc=$RC out=$OUT"
fi

# ... and running exactly those commands must actually clear the repo.
git -C "$SIGREPO" config --local --unset-all user.signingkey
git -C "$SIGREPO" config --local --unset-all tag.gpgsign
git -C "$SIGREPO" config --worktree --unset-all user.email
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SIGREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "remediation: following the printed commands clears the failure"
else
  fail "remediation did not clear the failure: rc=$RC out=$OUT"
fi

# Case 22: a key explicitly set to the EMPTY string is an override too.
# It is not "unset": it MASKS the machine's global value, after which
# `git var GIT_AUTHOR_IDENT` fails outright with "empty ident name", so
# treating an empty captured value as "nothing configured" would wave
# through a checkout that cannot commit at all.
EMPTYREPO="$WORKDIR/emptyrepo"
git init -q -b main "$EMPTYREPO"
git -C "$EMPTYREPO" config --local user.email ""
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$EMPTYREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = (set to the empty string)" \
  && printf '%s' "$OUT" | grep -q -- "git config --local --unset-all user.email"; then
  pass "empty-string local identity value: caught as an override"
else
  fail "empty-string local identity value: rc=$RC out=$OUT"
fi

# Case 23: the documented opt-out for a checkout that wants its own
# identity on purpose.
set +e
OUT="$(MERGEPATH_ALLOW_LOCAL_GIT_IDENTITY=1 MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "Part A skipped"; then
  pass "MERGEPATH_ALLOW_LOCAL_GIT_IDENTITY=1: opts out"
else
  fail "MERGEPATH_ALLOW_LOCAL_GIT_IDENTITY=1: rc=$RC out=$OUT"
fi

# Case 24: clearing the override restores a clean result — the guard
# tracks live state rather than latching.
git -C "$IDREPO" config --local --unset-all user.name
git -C "$IDREPO" config --local --unset-all user.email
git -C "$IDREPO" config --local --unset-all commit.gpgsign
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "override cleared: clean again"
else
  fail "override cleared: rc=$RC out=$OUT"
fi

# ── Part B: the .git/config baseline comparison ────────────────────────

# Case 25: --snapshot records a baseline and a later run confirms the
# config has not moved. This is the assertion that "running the suite
# leaves .git/config byte-identical" once the snapshot is taken before
# the suite and the plain run after it.
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" --snapshot 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "snapshot recorded"; then
  pass "--snapshot: baseline recorded"
else
  fail "--snapshot: rc=$RC out=$OUT"
fi

set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "unchanged since snapshot"; then
  pass "unmodified .git/config: byte-identical to the baseline"
else
  fail "unmodified .git/config: rc=$RC out=$OUT"
fi

# Case 26: any write to .git/config between snapshot and check fails,
# including one the identity assertion would not catch on its own.
git -C "$IDREPO" config --local core.bigFileThreshold 123m
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "changed since the snapshot" \
  && printf '%s' "$OUT" | grep -q "bigFileThreshold"; then
  pass "mutated .git/config: caught, with the diff"
else
  fail "mutated .git/config: rc=$RC out=$OUT"
fi

# ── Post-suite re-assertion ───────────────────────────────────────────
# Parts A and B finish before the paired regression suite runs, and the
# static scan deliberately excludes that suite's own file — so a suite
# that writes the live .git/config would leave the LAST step of the CI
# job reporting PASS, one step short of the job boundary the check
# claims to cover. MERGEPATH_GIT_IDENTITY_SUITE substitutes a stub suite
# that does exactly that.

STUB_SUITE="$WORKDIR/stub-suite.sh"
cat > "$STUB_SUITE" <<'EOF'
#!/usr/bin/env bash
# A "regression suite" that mutates the repository it is run against.
git -C "$MERGEPATH_GIT_IDENTITY_ROOT" config --local core.pager cat
echo "stub suite: ok"
exit 0
EOF

# Case 27: a suite that writes a non-identity key is caught by the
# post-suite baseline comparison.
PAGERREPO="$WORKDIR/pagerrepo"
git init -q -b main "$PAGERREPO"
set +e
MERGEPATH_GIT_IDENTITY_ROOT="$PAGERREPO" bash "$CHECK" --snapshot >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$PAGERREPO" MERGEPATH_GIT_IDENTITY_SUITE="$STUB_SUITE" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "changed since the snapshot" \
  && printf '%s' "$OUT" | grep -q "pager" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "suite that writes .git/config: caught after it runs, not reported PASS"
else
  fail "post-suite baseline comparison: rc=$RC out=$OUT"
fi

# Case 28: a suite that writes an identity key is caught by the
# post-suite live-repo assertion, even with no baseline recorded.
IDENTSTUB="$WORKDIR/stub-suite-identity.sh"
cat > "$IDENTSTUB" <<'EOF'
#!/usr/bin/env bash
git -C "$MERGEPATH_GIT_IDENTITY_ROOT" config --local user.email "nathan@nathanjohnpayne.example"
exit 0
EOF
LEAKREPO="$WORKDIR/leakrepo"
git init -q -b main "$LEAKREPO"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$LEAKREPO" MERGEPATH_GIT_IDENTITY_SUITE="$IDENTSTUB" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = nathan@nathanjohnpayne.example" \
  && printf '%s' "$OUT" | grep -q "the suite" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "suite that writes an identity key: caught after it runs"
else
  fail "post-suite identity assertion: rc=$RC out=$OUT"
fi

# Case 29: the post-suite pass must not turn a clean suite red.
CLEANSTUB="$WORKDIR/stub-suite-clean.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLEANSTUB"
CLEANREPO="$WORKDIR/cleanrepo"
git init -q -b main "$CLEANREPO"
set +e
MERGEPATH_GIT_IDENTITY_ROOT="$CLEANREPO" bash "$CHECK" --snapshot >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$CLEANREPO" MERGEPATH_GIT_IDENTITY_SUITE="$CLEANSTUB" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "unchanged by the regression suite" \
  && printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "clean suite: post-suite re-assertion passes"
else
  fail "clean suite post-suite re-assertion: rc=$RC out=$OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo
echo "test_git_identity_hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
