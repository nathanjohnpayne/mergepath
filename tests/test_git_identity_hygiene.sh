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

# ── Part A: the live-repo identity assertion ──────────────────────────

IDREPO="$WORKDIR/idrepo"
git init -q -b main "$IDREPO"
printf '#!/usr/bin/env bash\n' > "$IDREPO/marker.sh"

# Case 11: a clean fixture repo passes.
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "fixture repo with no local identity: clean"
else
  fail "fixture repo with no local identity: rc=$RC out=$OUT"
fi

# Case 12: the exact #777 corruption — a repo-local user block plus a
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

# Case 13: the documented opt-out for a checkout that wants its own
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

# Case 14: clearing the override restores a clean result — the guard
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

# Case 15: --snapshot records a baseline and a later run confirms the
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

# Case 16: any write to .git/config between snapshot and check fails,
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

# ── Summary ───────────────────────────────────────────────────────────
echo
echo "test_git_identity_hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
