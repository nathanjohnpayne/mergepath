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
#      while the suite runs), and its per-shard `--verify` form (#2163):
#      Parts A and B only, failing closed with no snapshot to compare to;
#   C. the static scan for unscoped `git config <identity-key> <value>`.
#
# Plus the re-run of A and B AFTER the paired regression suite, which is
# what extends the "nothing moved .git/config" guarantee to the end of
# the CI job rather than to the step before its last one.
#
# Cases use isolated fixture roots or a copied check inside a fixture repo.
# No fixture setup targets the real repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_git_identity_hygiene"

[[ -f "$CHECK" ]] || { echo "missing $CHECK" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/git-identity-hygiene-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# Build a markerless consumer fixture plus one file with the given content,
# then run the shared scan against it. Sets OUT and RC. All Part C cases
# therefore protect consumers as well as the hub.
FIXTURE_SEQ=0
run_on_fixture() {
  local rel="$1" content="$2"
  FIXTURE_SEQ=$((FIXTURE_SEQ + 1))
  local tree="$WORKDIR/fixture-$FIXTURE_SEQ"
  mkdir -p "$tree/scripts" "$tree/$(dirname "$rel")"
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

# Case 4b: Git accepts the unique long-option prefixes --gl/--sy and up.
# Scan-only snippets do not write any global or system configuration.
for SCOPE in --gl --glo --glob --globa --global --sy --sys --syst --syste --system; do
  run_on_fixture "tests/scope-prefix.sh" "git config $SCOPE user.email fixture@example.com
"
  if [ "$RC" = "0" ]; then
    pass "Git-supported out-of-repo scope prefix $SCOPE: allowed"
  else
    fail "Git scope prefix $SCOPE rejected: rc=$RC out=$OUT"
  fi
done
for SCOPE in --g --s --glued --systematic; do
  run_on_fixture "tests/not-scope-prefix.sh" "git config $SCOPE user.email leak@example.com
"
  if [ "$RC" = "1" ]; then
    pass "ambiguous/non-option scope spelling $SCOPE: cannot suppress a writer"
  else
    fail "unsupported scope spelling $SCOPE suppressed writer: rc=$RC out=$OUT"
  fi
done
run_on_fixture "tests/neighbour-prefix.sh" 'git config --gl user.email fixture@example.com; git config user.email leak@example.com
'
if [ "$RC" = "1" ]; then
  pass "short scope prefix on neighbouring command cannot suppress unscoped writer"
else
  fail "neighbouring scope prefix hid writer: rc=$RC out=$OUT"
fi
run_on_fixture "tests/trailing-prefix.sh" 'git config user.email leak@example.com --sy
'
if [ "$RC" = "1" ]; then
  pass "short scope prefix after the value cannot suppress unscoped writer"
else
  fail "trailing scope prefix hid writer: rc=$RC out=$OUT"
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

# Case 10: consumers need the SAME scan on repo-owned scripts and policy.
# Use a real index and the production path, without a fixture-root override,
# to cover tracked enumeration and the separate hub-suite gate together.
CONSUMER="$WORKDIR/consumer"
mkdir -p "$CONSUMER/scripts/ci" "$CONSUMER/tests" "$CONSUMER/docs/projects/app/prds"
git init -q -b main "$CONSUMER"
cp "$CHECK" "$CONSUMER/scripts/ci/check_git_identity_hygiene"
cat > "$CONSUMER/tests/leaky.sh" <<'EOF'
#!/usr/bin/env bash
git config user.email "test@example.com"
EOF
cat > "$CONSUMER/REVIEW_POLICY.md" <<'EOF'
# Frozen consumer policy
git config user.name "fixture"
EOF
# This hub suite must remain excluded from the scan AND never run here.
cat > "$CONSUMER/tests/test_git_identity_hygiene.sh" <<'EOF'
#!/usr/bin/env bash
git config user.email "suite@example.com"
exit 91
EOF
cp "$CONSUMER/REVIEW_POLICY.md" "$CONSUMER/docs/projects/app/prds/app.md"
git -C "$CONSUMER" add .
set +e
OUT="$(bash "$CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/leaky.sh:2" \
  && printf '%s' "$OUT" | grep -q "REVIEW_POLICY.md:2" \
  && ! printf '%s' "$OUT" | grep -q "test_git_identity_hygiene.sh:" \
  && ! printf '%s' "$OUT" | grep -q "docs/projects/app/prds/app.md:"; then
  pass "markerless consumer: tracked script and policy writes caught; fixture and generated paths excluded"
else
  fail "consumer tracked scan: rc=$RC out=$OUT"
fi
cat > "$CONSUMER/tests/leaky.sh" <<'EOF'
#!/usr/bin/env bash
git -C "$FIXTURE" config user.email "fixture@example.com"
git config user.name "fixture" # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture subshell
EOF
printf '# Policy\nLegacy byte: \377\n`git config user.name <name>`\n' > "$CONSUMER/REVIEW_POLICY.md"
# Untracked source is not part of the production scan's contract.
printf 'git config user.email "untracked@example.com"\n' > "$CONSUMER/untracked.sh"
set +e
OUT="$(bash "$CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "regression test suite skipped (consumer checkout" \
  && ! printf '%s' "$OUT" | grep -q "Part C skipped"; then
  pass "markerless consumer: targeted fixture writes and explicit exemptions pass; hub suite remains skipped"
else
  fail "clean consumer with frozen hub-suite fixture: rc=$RC out=$OUT"
fi
# The hub marker changes only suite eligibility, not the scanner's verdict.
# Replace the scan-only input before executing it: suites run from the
# caller's cwd, so the forbidden fixture command must never be executed.
printf '#!/usr/bin/env bash\nexit 91\n' > "$CONSUMER/tests/test_git_identity_hygiene.sh"
printf '#!/usr/bin/env bash\n' > "$CONSUMER/scripts/sync-to-downstream.sh"
git -C "$CONSUMER" add scripts/sync-to-downstream.sh
set +e
OUT="$(bash "$CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "regression test suite failed"; then
  pass "hub marker: paired regression suite runs and failure is retained"
else
  fail "hub suite gate: rc=$RC out=$OUT"
fi

# Case 10b: the real Git index must preserve names Git normally C-quotes.
# The copied production check runs markerless; all commands below are scan
# input, never executed. Clear each writer before probing the next path so
# a previous finding cannot mask a skipped file.
PATHS_CONSUMER="$WORKDIR/consumer-paths"
mkdir -p "$PATHS_CONSUMER/scripts/ci" "$PATHS_CONSUMER/docs" "$PATHS_CONSUMER/tests" "$PATHS_CONSUMER/tools"
git init -q -b main "$PATHS_CONSUMER"
cp "$CHECK" "$PATHS_CONSUMER/scripts/ci/check_git_identity_hygiene"
for REL in 'docs/résumé.md' 'tests/署名.sh' $'docs/line\nbreak.md' $'docs/tab\tname.md' 'docs/quote"name.md' 'tools/हुक'; do
  printf '#!/usr/bin/env bash\ngit config user.email leak@example.com\n' > "$PATHS_CONSUMER/$REL"
  git -C "$PATHS_CONSUMER" add -- "$REL"
  set +e
  OUT="$(bash "$PATHS_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"
  RC=$?
  set -e
  # The human-readable report prefixes every output line, including
  # embedded newlines in a path. Assert the complete displayed pathname.
  REPORTED_REL="${REL//$'\n'/$'\n  - '}"
  if [ "$RC" = "1" ] && [[ "$OUT" == *"$REPORTED_REL:2:"* ]]; then
    pass "tracked C-quoted path retains its finding: $REL"
  else
    fail "tracked pathname skipped: '$REL' rc=$RC out=$OUT"
  fi
  printf '#!/usr/bin/env bash\ngit -C "$FIXTURE" config user.email fixture@example.com\n' > "$PATHS_CONSUMER/$REL"
done
printf 'git config user.email untracked@example.com\n' > "$PATHS_CONSUMER/docs/non-suivi-署名.md"
set +e
OUT="$(bash "$PATHS_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "scoped tracked paths pass; untracked Unicode source stays excluded"
else
  fail "clean tracked pathname corpus: rc=$RC out=$OUT"
fi
for REL in 'docs/résumé.md' $'docs/line\nbreak.md'; do
  run_on_fixture "$REL" 'git config user.email leak@example.com
'
  REPORTED_REL="${REL//$'\n'/$'\n  - '}"
  if [ "$RC" = "1" ] && [[ "$OUT" == *"$REPORTED_REL:1:"* ]]; then
    pass "fixture enumeration preserves pathname: $REL"
  else
    fail "fixture pathname skipped: '$REL' rc=$RC out=$OUT"
  fi
done

# Case 10c: tracked symlinks name link objects, not source on this machine.
# Exercise missing, clean and offending external targets in a real index.
# The companion regular source must still be scanned in every state.
LINKS_CONSUMER="$WORKDIR/consumer-links"
mkdir -p "$LINKS_CONSUMER/scripts/ci" "$LINKS_CONSUMER/docs" "$WORKDIR/external-source"
git init -q -b main "$LINKS_CONSUMER"
cp "$CHECK" "$LINKS_CONSUMER/scripts/ci/check_git_identity_hygiene"
for REL in linked.md linked.sh linked-hook; do
  ln -s "$WORKDIR/external-source/target" "$LINKS_CONSUMER/$REL"
done
printf 'git -C "$FIXTURE" config user.email fixture@example.com\n' > "$LINKS_CONSUMER/docs/regular.md"
git -C "$LINKS_CONSUMER" add .
for STATE in absent clean writer; do
  case "$STATE" in
    clean) printf '#!/usr/bin/env bash\ngit -C "$FIXTURE" config user.email fixture@example.com\n' > "$WORKDIR/external-source/target" ;;
    writer) printf '#!/usr/bin/env bash\ngit config user.email external@example.com\n' > "$WORKDIR/external-source/target" ;;
  esac
  set +e
  OUT="$(bash "$LINKS_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = "0" ]; then
    pass "tracked symlink targets excluded when external source is $STATE"
  else
    fail "symlink target affected tracked-source scan ($STATE): rc=$RC out=$OUT"
  fi
  printf 'git config user.email regular@example.com\n' > "$LINKS_CONSUMER/docs/regular.md"
  set +e
  OUT="$(bash "$LINKS_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/regular.md:1:' \
    && ! printf '%s' "$OUT" | grep -q 'linked.*:2:'; then
    pass "regular tracked companion still scanned with $STATE symlink target"
  else
    fail "regular source beside $STATE symlink: rc=$RC out=$OUT"
  fi
  printf 'git -C "$FIXTURE" config user.email fixture@example.com\n' > "$LINKS_CONSUMER/docs/regular.md"
done
# A tracked directory replaced with a symlink must not redirect regular paths.
mv "$LINKS_CONSUMER/docs" "$WORKDIR/original-source"
printf 'git config user.email external@example.com\n' > "$WORKDIR/external-source/regular.md"
ln -s "$WORKDIR/external-source" "$LINKS_CONSUMER/docs"
set +e
OUT="$(bash "$LINKS_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "symlinked directory cannot redirect tracked source to machine-local bytes"
else
  fail "symlinked parent directory followed: rc=$RC out=$OUT"
fi

# BEGIN STARTUP_ADMISSION_CONTROLS
# Case 10d: shell-startup basenames and immediate Husky hook files need no
# shebang. Exercise every admitted name at root and nested paths through a
# genuine private Git index, with no root/suite override or hub marker.
STARTUP_CONSUMER="$WORKDIR/consumer-startup-admission"
mkdir -p "$STARTUP_CONSUMER/scripts/ci" "$STARTUP_CONSUMER/tests"
git init -q -b main "$STARTUP_CONSUMER"
cp "$CHECK" "$STARTUP_CONSUMER/scripts/ci/check_git_identity_hygiene"
printf '#!/usr/bin/env bash\nexit 91\n' > "$STARTUP_CONSUMER/tests/test_git_identity_hygiene.sh"
cp "$STARTUP_CONSUMER/.git/config" "$WORKDIR/startup-config-before"
STARTUP_PATHS=()
for NAME in .profile .bashrc .bash_profile .bash_login .bash_logout .zshenv .zprofile .zshrc .zlogin .zlogout .kshrc .mkshrc .ashrc .envrc .bash_aliases .shrc; do
  STARTUP_PATHS+=("$NAME" "packages/demo/$NAME")
done
STARTUP_PATHS+=(.husky/pre-commit packages/demo/.husky/pre-push)
for CONTROL in writer scoped exempt quoted-data; do
  case "$CONTROL" in
    writer) SOURCE='git config user.email startup@example.invalid'; EXPECTED=1 ;;
    scoped) SOURCE='git -C "$FIXTURE" config user.email startup@example.invalid'; EXPECTED=0 ;;
    exempt) SOURCE='git config user.email startup@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: owning fixture'; EXPECTED=0 ;;
    quoted-data) SOURCE="printf '%s' 'git config user.email startup@example.invalid'"; EXPECTED=0 ;;
  esac
  for REL in "${STARTUP_PATHS[@]}"; do
    mkdir -p "$STARTUP_CONSUMER/$(dirname "$REL")"
    printf '%s\n' "$SOURCE" > "$STARTUP_CONSUMER/$REL"
  done
  git -C "$STARTUP_CONSUMER" add -A
  if git -C "$STARTUP_CONSUMER" ls-files --error-unmatch -- "${STARTUP_PATHS[@]}" >/dev/null 2>&1; then
    pass "all startup/Husky $CONTROL paths are genuinely tracked"
  else fail "startup/Husky control paths missing from private index: $CONTROL"; fi
  set +e
  OUT="$(bash "$STARTUP_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  for REL in "${STARTUP_PATHS[@]}"; do
    if [ "$RC" = "$EXPECTED" ] \
      && { [ "$EXPECTED" = 0 ] || [[ "$OUT" == *"  - $REL:1:"* ]]; } \
      && { [ "$EXPECTED" = 1 ] || [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]]; } \
      && cmp -s "$WORKDIR/startup-config-before" "$STARTUP_CONSUMER/.git/config"; then
      pass "tracked startup/Husky $CONTROL control: $REL"
    else fail "startup/Husky $CONTROL: path='$REL' expected=$EXPECTED rc=$RC out=$OUT"; fi
  done
done

# Case and suffix variants, other components, helper/deeper paths and a
# .husky basename without a following component gain no new admission.
STARTUP_NEGATIVES=(case-hooks/.HUSKY/pre-commit packages/case-hooks/.HUSKY/pre-push
  foo.husky/pre-commit .husky-helper/pre-commit
  .husky/_/pre-commit .husky/child/pre-commit packages/demo/.husky/_/pre-push
  packages/demo/.husky/child/pre-push packages/literal/.husky
  docs/projects/app/prds/.bashrc docs/projects/app/prds/.husky/pre-commit)
for NAME in .profile .bashrc .bash_profile .bash_login .bash_logout .zshenv .zprofile .zshrc .zlogin .zlogout .kshrc .mkshrc .ashrc .envrc .bash_aliases .shrc; do
  UPPER_NAME="$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')"
  # Separate directories avoid aliasing the positive names on macOS.
  STARTUP_NEGATIVES+=("case-startup/$UPPER_NAME" "packages/case-startup/$UPPER_NAME" "$NAME.backup" "packages/demo/$NAME.backup")
done
for REL in "${STARTUP_NEGATIVES[@]}"; do
  mkdir -p "$STARTUP_CONSUMER/$(dirname "$REL")"
  printf 'git config user.email negative@example.invalid\n' > "$STARTUP_CONSUMER/$REL"
done
git -C "$STARTUP_CONSUMER" add -A
if git -C "$STARTUP_CONSUMER" ls-files --error-unmatch -- "${STARTUP_NEGATIVES[@]}" >/dev/null 2>&1; then
  pass "startup case/suffix and Husky component/depth negatives are genuinely tracked"
else fail "startup/Husky negative paths missing from private index"; fi
printf 'git config user.email untracked@example.invalid\n' > "$STARTUP_CONSUMER/.husky/untracked-hook"
set +e
OUT="$(bash "$STARTUP_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
set -e
if [ "$RC" = 0 ] && [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]] \
  && cmp -s "$WORKDIR/startup-config-before" "$STARTUP_CONSUMER/.git/config"; then
  pass "tracked startup case/suffix and Husky component/depth negatives; exclusions retained"
else fail "startup/Husky negative admission: rc=$RC out=$OUT"; fi

# New path admission is additive: helper/deeper paths already admitted
# by extensions or shebangs must continue to expose their writer.
for REL in .husky/_/file.sh packages/demo/.husky/child/file.sh .husky/_/shebang-hook; do
  mkdir -p "$STARTUP_CONSUMER/$(dirname "$REL")"
  printf '#!/usr/bin/env bash\ngit config user.email inherited@example.invalid\n' > "$STARTUP_CONSUMER/$REL"
  git -C "$STARTUP_CONSUMER" add -- "$REL"
  set +e
  OUT="$(bash "$STARTUP_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = 1 ] && [[ "$OUT" == *"  - $REL:2:"* ]]; then
    pass "existing extension/shebang admission remains additive: $REL"
  else fail "existing Husky source globally exempted: path='$REL' rc=$RC out=$OUT"; fi
  printf '#!/usr/bin/env bash\ngit -C "$FIXTURE" config user.email inherited@example.invalid\n' > "$STARTUP_CONSUMER/$REL"
done

# Track actual link objects for both new families, then replace a tracked
# regular parent directory with a link. Neither may read external bytes.
mkdir -p "$WORKDIR/startup-external/.husky"
printf 'git config user.email external@example.invalid\n' > "$WORKDIR/startup-external/.zshrc"
printf 'git config user.email external@example.invalid\n' > "$WORKDIR/startup-external/.husky/pre-push"
for REL in .zshrc .husky/pre-commit; do
  rm "$STARTUP_CONSUMER/$REL"
  ln -s "$WORKDIR/startup-external/.zshrc" "$STARTUP_CONSUMER/$REL"
  git -C "$STARTUP_CONSUMER" add -- "$REL"
  if [[ "$(git -C "$STARTUP_CONSUMER" ls-files --stage -- "$REL")" == 120000* ]]; then
    pass "startup/Husky link is a genuine tracked symlink: $REL"
  else fail "startup symlink fixture mode not verified: $REL"; fi
done
mv "$STARTUP_CONSUMER/packages/demo" "$WORKDIR/startup-original-package"
ln -s "$WORKDIR/startup-external" "$STARTUP_CONSUMER/packages/demo"
set +e
OUT="$(bash "$STARTUP_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
set -e
if [ "$RC" = 0 ] && [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]] \
  && cmp -s "$WORKDIR/startup-config-before" "$STARTUP_CONSUMER/.git/config"; then
  pass "startup/Husky symlink files and symlinked parents retain regular-source boundary"
else fail "startup/Husky followed external link bytes: rc=$RC out=$OUT"; fi
# END STARTUP_ADMISSION_CONTROLS

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

# Case 12b: backslash-newline deletion happens inside words too. Adding a
# separator while joining turns this executable `git config` into unrelated
# `gi t con fig` tokens and makes the static scan pass open.
run_on_fixture "tests/split-words.sh" '#!/usr/bin/env bash
gi\
t con\
fig user.email "joined@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/split-words.sh:2"; then
  pass "continuation inside command words: adjacency is preserved and write is caught"
else
  fail "intra-word continuation hid identity write: rc=$RC out=$OUT"
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

# Case 19: a suppressor belongs to the command it was typed on, not to
# the line. Every predicate in the scan is a substring test, so a line
# holding two commands lets the first answer for the second: a targeted
# `-C` read followed by an untargeted write, or a `--get` read followed
# by a write, is the #777 shape with a harmless neighbour in front of it.
run_on_fixture "tests/multi-command.sh" '#!/usr/bin/env bash
git -C "$FIX" status && git config user.email "leak@example.com"
who=$(git config --get user.email); git config user.name "leak2"
echo "$who"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/multi-command.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/multi-command.sh:3"; then
  pass "suppressor on an earlier command in the line: write still caught"
else
  fail "earlier-command suppressor masking a later write: rc=$RC out=$OUT"
fi

# Case 20: the converse — cutting at separators must not invent hits.
# Each of these commands carries its OWN target or out-of-repo scope, so
# every piece is clean on its own and the line must pass.
run_on_fixture "tests/multi-command-clean.sh" '#!/usr/bin/env bash
git -C "$FIX" config user.email "t@t" && git -C "$FIX" config user.name "t"
git config --global user.email "you@example.com"; git config --global user.name "You"
git config --get user.email | tr -d "\n"
'
if [ "$RC" = "0" ]; then
  pass "separators between individually-scoped commands: no false hit"
else
  fail "separators inventing a hit: rc=$RC out=$OUT"
fi

# Case 21: a value that starts with a PATH character. Recognising the
# value token by an allow-list of letters, digits, quotes and `$` waves
# through every value the list forgot — and `user.signingkey`, the key
# that decides which key signs every commit this repo makes, is
# overwhelmingly given a path. All three of these are ordinary
# repo-local writes of a checked key.
run_on_fixture "tests/path-value.sh" '#!/usr/bin/env bash
git config user.signingkey ~/.ssh/id_ed25519.pub
git config user.signingkey /tmp/key.pub
git config user.signingkey ./key.pub
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/path-value.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/path-value.sh:3" \
  && printf '%s' "$OUT" | grep -q "tests/path-value.sh:4"; then
  pass "path-valued signingkey writes: caught"
else
  fail "path-valued signingkey writes: rc=$RC out=$OUT"
fi

# Case 22: the converse of case 21 — widening the value token must not
# turn reads into hits. What follows the key on each of these lines is
# a comment, a redirection or a closing substitution, not a value.
run_on_fixture "tests/not-values.sh" '#!/usr/bin/env bash
git config user.email  # which address is this repo using?
git config user.email > /tmp/who
who=$( git config user.email )
echo "$who"
'
if [ "$RC" = "0" ]; then
  pass "comment / redirection / closing substitution after the key: no false hit"
else
  fail "non-value token after the key: rc=$RC out=$OUT"
fi

# Case 22b: one literal post-key > / >> target is shell data, not the
# assignment value. Use the real production index without root/suite
# overrides; the copied hub suite stays present but marker-gated.
REDIRECT_CONSUMER="$WORKDIR/consumer-redirection"
mkdir -p "$REDIRECT_CONSUMER/scripts/ci" "$REDIRECT_CONSUMER/tests"
git init -q -b main "$REDIRECT_CONSUMER"
cp "$CHECK" "$REDIRECT_CONSUMER/scripts/ci/check_git_identity_hygiene"
cp "$ROOT/tests/test_git_identity_hygiene.sh" "$REDIRECT_CONSUMER/tests/"
cp "$REDIRECT_CONSUMER/.git/config" "$WORKDIR/redirection-config-before"
while IFS='|' read -r EXPECTED LABEL SOURCE; do
  rm -f "$REDIRECT_CONSUMER/source.sh" "$REDIRECT_CONSUMER/source.md"
  REDIRECT_REL=source.sh
  [[ "$SOURCE" != \`* ]] || REDIRECT_REL=source.md
  printf '%s\n' "$SOURCE" > "$REDIRECT_CONSUMER/$REDIRECT_REL"
  git -C "$REDIRECT_CONSUMER" add -A
  set +e
  OUT="$(bash "$REDIRECT_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = "$EXPECTED" ] \
    && { [ "$EXPECTED" = 0 ] || [[ "$OUT" == *"$REDIRECT_REL:1:"* ]]; } \
    && { [ "$EXPECTED" = 1 ] || [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]]; } \
    && cmp -s "$WORKDIR/redirection-config-before" "$REDIRECT_CONSUMER/.git/config"; then
    pass "literal post-key redirection: $LABEL"
  else
    fail "post-key redirection $LABEL: expected=$EXPECTED rc=$RC out=$OUT"
  fi
done <<'REDIRECT_CASES'
1|adjacent output target before value|git config user.email >/dev/null leak@example.com
1|spaced append target before value|git config user.email >> /dev/null leak@example.com
1|paired key and target quoting|git config "User.Email" >"sink path" leak@example.com
1|target option text cannot scope the write|git config user.email >--global leak@example.com
1|Markdown code span retains the writer|`git config commit.gpgsign > /dev/null false`
0|explicit read selector remains a read|git config --get user.email > /dev/null
0|redirection target alone is not a value|git config user.email >> "sink path"
0|scoped fixture identity setup remains allowed|git -C "$FIX" config user.email >/dev/null fixture@example.com; git config --global user.name >> /dev/null "Real Human"
0|owning shell-comment exemption remains allowed|git config user.email >/dev/null fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: deliberate fixture
0|Markdown placeholder stays outside the value grammar|`git config user.email <addr>`
0|expansion target gains no coverage guarantee|git config user.email >"$SINK" leak@example.com
0|multiple redirections gain no coverage guarantee|git config user.email >/dev/null >>sink leak@example.com
REDIRECT_CASES

# Case 23: case 19 in Markdown. A prose sentence carries no shell
# separator, so the whole paragraph arrives as ONE piece and a `--global`
# example waves through the forbidden example standing beside it. That
# inverts the guard where it matters most: the correct form is exactly
# what a doc puts next to the wrong one, so writing the rule down is what
# silences it. Backticks are cut on in Markdown for this reason.
run_on_fixture "docs/prose.md" '# Identity

Use `git config --global user.email you@example.com`, never `git config user.email you@example.com`.
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "docs/prose.md:3"; then
  pass "sanctioned example beside a forbidden one in prose: still caught"
else
  fail "prose --global example suppressing the write beside it: rc=$RC out=$OUT"
fi

# Case 24: the converse of case 23 — the code-span cut must not invent
# hits. Each span here is individually scoped, and the prose between them
# is not part of any command.
run_on_fixture "docs/prose-clean.md" '# Identity

Run `git config --global user.email you@example.com`, or `git -C "$FIX" config user.email t@t` for a fixture.
'
if [ "$RC" = "0" ]; then
  pass "individually-scoped spans in one sentence: no false hit"
else
  fail "code-span cut inventing a hit in prose: rc=$RC out=$OUT"
fi

# Case 25: a doc that DESCRIBES the marker must not be exempted by
# describing it. The marker regex matched a mention anywhere on the line,
# so every paragraph documenting this check exempted itself — leaving the
# one place in the tree whose job is to write the forbidden shape down
# the one place that was never scanned. A mention inside a code span is a
# citation; a real marker sits outside the spans.
run_on_fixture "docs/describes-marker.md" '# Identity

A deliberate exception carries `GIT_IDENTITY_SCOPE_EXEMPT: <reason>`, as in `git config user.email you@example.com`.
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "docs/describes-marker.md:3"; then
  pass "marker cited inside a code span: does not exempt the line"
else
  fail "prose mention of the marker exempting a live write: rc=$RC out=$OUT"
fi

# Case 26: the converse of case 25 — a real Markdown marker still works.
# An HTML comment is the documented spelling: it sits outside the code
# spans and renders invisibly, which is what
# docs/audits/git-identity-leak-2026-07.md uses to quote the #777 writer.
run_on_fixture "docs/real-marker.md" '# Identity

The writer was `git config user.email nathan@nathanjohnpayne.example`. <!-- GIT_IDENTITY_SCOPE_EXEMPT: verbatim quote, recorded as evidence -->
'
if [ "$RC" = "0" ]; then
  pass "HTML-comment marker outside the spans: exempts the line"
else
  fail "real Markdown marker not honoured: rc=$RC out=$OUT"
fi

# Case 26b: the policy must not ship runnable global writes carrying fixture
# placeholders. A reader pasting them would replace the machine-wide human
# author identity, and the local-identity guard intentionally cannot catch it.
if ! grep -Eq '^[[:space:]]*git config --global user\.(name|email)[[:space:]]+.*(Your Name|you@example\.com)' \
     "$ROOT/REVIEW_POLICY.md" \
  && grep -qF 'verified machine setup' "$ROOT/REVIEW_POLICY.md"; then
  pass "identity policy verifies/provisions the real human identity without runnable placeholders"
else
  fail "REVIEW_POLICY.md still publishes executable global placeholder identity writes"
fi

# Case 26c: #865's "Superseded CHANGES_REQUESTED reviews" precondition
# (REVIEW_POLICY.md § Real-Time Per-Finding Disposition) must match the
# pinned decision comment
# (github.com/nathanjohnpayne/mergepath/issues/865#issuecomment-5160596834),
# not a more permissive restatement of it. The decision requires the
# dismissal precondition to name all three real dispositions (fixed,
# rebutted, deferred — a deferred-only round is not "fixed-and-pushed, or
# rebutted on-thread") and to carve out a round with an open rebuttal the
# reviewer has not yet answered: that round keeps its review standing
# until a later round's verdict supersedes it, rather than becoming
# dismissible the instant a reply lands. Losing either half re-opens the
# short-circuit § No-self-approve scoping exists to prevent: dismissing a
# cross-agent CHANGES_REQUESTED review the reviewer never accepted.
if grep -qF 'fixed with the commit pushed, or rebutted/deferred with the record posted' "$ROOT/REVIEW_POLICY.md"; then
  pass "#865: dismissal precondition names fixed/rebutted/deferred with the record posted"
else
  fail "#865: REVIEW_POLICY.md dismissal precondition dropped 'deferred' or the record-posted requirement"
fi
if grep -qF "keeps its review standing until the next round's verdict supersedes it" "$ROOT/REVIEW_POLICY.md"; then
  pass "#865: undispositioned-round carve-out (review stands until superseded) is present"
else
  fail "#865: REVIEW_POLICY.md is missing the undispositioned-round carve-out from the pinned decision"
fi
if grep -qF '(fixed-and-pushed, or rebutted on-thread)' "$ROOT/REVIEW_POLICY.md"; then
  fail "#865: REVIEW_POLICY.md still carries the pre-fix permissive precondition wording"
else
  pass "#865: pre-fix permissive precondition wording ('fixed-and-pushed, or rebutted on-thread') is gone"
fi

# ── Part A: the live-repo identity assertion ──────────────────────────

IDREPO="$WORKDIR/idrepo"
git init -q -b main "$IDREPO"
printf '#!/usr/bin/env bash\n' > "$IDREPO/marker.sh"

# Case 27: a clean fixture repo passes.
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "fixture repo with no local identity: clean"
else
  fail "fixture repo with no local identity: rc=$RC out=$OUT"
fi

# Case 27b: a repository that Git cannot inspect is NOT a non-repository.
# `GIT_CONFIG_GLOBAL=/` makes real git fail while opening its config (the
# root is a directory), without writing or chmodding any operator state.
# Treating the failed `rev-parse` exactly like a fixture tree with no .git
# turns an unreadable identity signal into a clean pass.
set +e
OUT="$(GIT_CONFIG_GLOBAL=/ MERGEPATH_GIT_IDENTITY_ROOT="$IDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && grep -q "cannot inspect repository metadata or config" <<<"$OUT" \
  && ! grep -q "check_git_identity_hygiene: PASS" <<<"$OUT"; then
  pass "git config read failure: fails closed instead of claiming non-repository"
else
  fail "git config read failure passed open: rc=$RC out=$OUT"
fi

# Case 28: the exact #777 corruption — a repo-local user block plus a
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

# Case 29: the remediation must clear the offenders it just reported.
# `user.signingkey` and `tag.gpgsign` are checked keys, and `--worktree`
# is a checked scope, so a fixed three-command `--local` block would
# print instructions that clear nothing and leave the next run failing
# identically. Each command is generated from a real offender, and each
# names the repository the check inspected. The count is asserted
# EXACTLY, so the block is neither short a key nor padded by a duplicate.
# Two of these three offenders share one scope AND one origin file, which
# is what makes the count per OFFENDER — per distinct key and scope and
# origin file — rather than per scope/origin: describing it either as
# "one per key" or as "one per scope and file" miscounts this very case.
SIGREPO="$WORKDIR/sigrepo"
git init -q -b main "$SIGREPO"
SIGREPO_REAL="$(cd "$SIGREPO" && pwd -P)"
git -C "$SIGREPO" config --local extensions.worktreeConfig true
git -C "$SIGREPO" config --local user.signingkey ABC123
git -C "$SIGREPO" config --local tag.gpgsign false
git -C "$SIGREPO" config --worktree user.email "wt@example.com"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SIGREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
REMEDY_COUNT="$(printf '%s\n' "$OUT" | grep -cE '^[[:space:]]+git -C ' || true)"
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$SIGREPO_REAL\" config --local --unset-all user.signingkey" \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$SIGREPO_REAL\" config --local --unset-all tag.gpgsign" \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$SIGREPO_REAL\" config --worktree --unset-all user.email" \
  && [ "$REMEDY_COUNT" = "3" ]; then
  pass "remediation: one unset command per offender, in its own scope"
else
  fail "remediation commands: rc=$RC count=$REMEDY_COUNT out=$OUT"
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

# Case 29b: disabling extensions.worktreeConfig does not delete the current
# worktree's config.worktree. Its identity becomes dormant, then reactivates
# immediately if the extension is re-enabled, without another identity write.
DORMANT_WT_REPO="$WORKDIR/dormant-worktree-repo"
git init -q -b main "$DORMANT_WT_REPO"
git -C "$DORMANT_WT_REPO" config --local extensions.worktreeConfig true
git -C "$DORMANT_WT_REPO" config --worktree user.email dormant-worktree@example.com
git -C "$DORMANT_WT_REPO" config --local extensions.worktreeConfig false
DORMANT_EFFECTIVE="$(git -C "$DORMANT_WT_REPO" config --local --get user.email 2>/dev/null || true)"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$DORMANT_WT_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all user.email' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
OUT_AFTER="$(MERGEPATH_GIT_IDENTITY_ROOT="$DORMANT_WT_REPO" bash "$CHECK" 2>&1)"
RC_AFTER=$?
set -e
if [ -z "$DORMANT_EFFECTIVE" ] && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "dormant worktree" \
  && [ -n "$REMEDY" ] && [ "$RC_AFTER" = "0" ]; then
  pass "disabled worktreeConfig: dormant config.worktree identity is caught and removable"
else
  fail "dormant worktree identity escaped: effective='$DORMANT_EFFECTIVE' remedy='$REMEDY' rc=$RC after=$RC_AFTER out=$OUT after_out=$OUT_AFTER"
fi

# Case 30: the remediation must act on the repository that produced the
# finding, not on wherever the operator is standing. The check is invoked
# by absolute path and MERGEPATH_GIT_IDENTITY_ROOT repoints it, so the
# inspected repo and the caller's cwd are routinely different — and a
# bare `git config --local --unset-all` run from the caller's repo clears
# the key THERE while the reported offender survives untouched. The
# printed command is run verbatim from an unrelated checkout.
OFFREPO="$WORKDIR/offrepo"
CALLERREPO="$WORKDIR/callerrepo"
git init -q -b main "$OFFREPO"
git init -q -b main "$CALLERREPO"
git -C "$OFFREPO" config --local user.email "offender@example.com"
git -C "$CALLERREPO" config --local user.email "bystander@example.com"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$OFFREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
# `|| true` because `set -o pipefail` would otherwise abort the whole
# suite here the moment the check stops printing a remediation — turning
# a regression into a truncated run instead of the FAIL below.
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all' | head -1 || true)"
set +e
( cd "$CALLERREPO" && eval "$REMEDY" ) >/dev/null 2>&1
OFF_LEFT="$(git -C "$OFFREPO" config --local --get user.email 2>/dev/null)"
CALLER_LEFT="$(git -C "$CALLERREPO" config --local --get user.email 2>/dev/null)"
set -e
if [ -n "$REMEDY" ] \
  && [ -z "$OFF_LEFT" ] \
  && [ "$CALLER_LEFT" = "bystander@example.com" ]; then
  pass "remediation run from another checkout: clears the offender, not the caller"
else
  fail "remediation targeted the caller's repo: remedy='$REMEDY' offender='$OFF_LEFT' caller='$CALLER_LEFT'"
fi

# Case 31: a key explicitly set to the EMPTY string is an override too.
# It is not "unset": it MASKS the machine's global value, after which
# `git var GIT_AUTHOR_IDENT` fails outright with "empty ident name", so
# treating an empty captured value as "nothing configured" would wave
# through a checkout that cannot commit at all.
EMPTYREPO="$WORKDIR/emptyrepo"
git init -q -b main "$EMPTYREPO"
EMPTYREPO_REAL="$(cd "$EMPTYREPO" && pwd -P)"
git -C "$EMPTYREPO" config --local user.email ""
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$EMPTYREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = (set to the empty string)" \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$EMPTYREPO_REAL\" config --local --unset-all user.email"; then
  pass "empty-string local identity value: caught as an override"
else
  fail "empty-string local identity value: rc=$RC out=$OUT"
fi

# Case 32: an identity key reached through an `include.path`. A
# scope-restricted read has includes OFF by default, so
# `--local --get-all user.email` reports nothing here — while ordinary
# lookup, and therefore every commit this repo makes, uses the included
# value. That is the #777 leak with one extra layer, and it must fail.
# The remediation has to edit the INCLUDED file: `--local --unset-all`
# does not reach into an include target and would clear nothing.
INCREPO="$WORKDIR/increpo"
git init -q -b main "$INCREPO"
printf '[user]\n\temail = included@example.com\n' > "$INCREPO/.git/identity-include"
git -C "$INCREPO" config --local include.path identity-include
EFFECTIVE="$(git -C "$INCREPO" config --get user.email)"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$INCREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$EFFECTIVE" = "included@example.com" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = included@example.com" \
  && printf '%s' "$OUT" | grep -q "via include:"; then
  pass "identity supplied by an include.path: caught, with its origin named"
else
  fail "include.path identity: effective='$EFFECTIVE' rc=$RC out=$OUT"
fi

# ... and the printed command must actually clear it.
# `|| true` because `set -o pipefail` would otherwise abort the whole
# suite here the moment the check stops printing a remediation — turning
# a regression into a truncated run instead of the FAIL below.
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$INCREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ -n "$REMEDY" ] && [ "$RC" = "0" ]; then
  pass "include.path remediation: the printed command clears the failure"
else
  fail "include.path remediation: remedy='$REMEDY' rc=$RC out=$OUT"
fi

# Case 33: a CONDITIONAL include whose condition does not match this
# checkout. `--includes` evaluates `includeIf` against the current
# branch, so an `includeIf "onbranch:release"` target that sets
# user.email reads as absent while the check runs on `main` — and takes
# effect in full the moment someone checks `release` out. Nothing is
# written at that moment, so there is no later event for the guard to
# catch and the next commit is simply misattributed. The entry sits in
# the repository's own config either way, which is the invariant the
# check states: no local identity override, not "none active right now".
CONDREPO="$WORKDIR/condrepo"
git init -q -b main "$CONDREPO"
printf '[user]\n\temail = release@example.com\n' > "$CONDREPO/.git/release-identity"
git -C "$CONDREPO" config --local includeIf.onbranch:release.path release-identity
# `|| true`: a scope-restricted lookup exits 1 when the key is absent,
# which is exactly the state being asserted.
ACTIVE="$(git -C "$CONDREPO" config --local --includes --get user.email || true)"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$CONDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ -z "$ACTIVE" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = release@example.com" \
  && printf '%s' "$OUT" | grep -q "via inactive include:"; then
  pass "identity behind an inactive includeIf: caught while its condition is off"
else
  fail "inactive includeIf identity: active='$ACTIVE' rc=$RC out=$OUT"
fi

# ... and the printed command must clear it, the same as for an active
# include: `--local --unset-all` does not reach into an include target.
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$CONDREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ -n "$REMEDY" ] && [ "$RC" = "0" ]; then
  pass "inactive includeIf remediation: the printed command clears the failure"
else
  fail "inactive includeIf remediation: remedy='$REMEDY' rc=$RC out=$OUT"
fi

# Case 34: the identity sits one hop further down. The conditional
# target only pulls in a third file, and that file carries the keys —
# so a walk that stopped at the first hop would report nothing.
NESTREPO="$WORKDIR/nestrepo"
git init -q -b main "$NESTREPO"
printf '[user]\n\temail = nested@example.com\n' > "$NESTREPO/.git/nested-identity"
printf '[include]\n\tpath = nested-identity\n' > "$NESTREPO/.git/release-identity"
git -C "$NESTREPO" config --local includeIf.onbranch:release.path release-identity
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NESTREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = nested@example.com" \
  && printf '%s' "$OUT" | grep -q "nested-identity"; then
  pass "identity two hops behind an inactive includeIf: caught"
else
  fail "nested inactive include: rc=$RC out=$OUT"
fi

# Case 35: the unconditional walk must not double-report. An `includeIf`
# whose condition DOES match is found by the ordinary `--includes`
# lookup and reached a second time by the walk, so the same value would
# be listed twice — once as active, once as inactive — and the operator
# would be handed a duplicate remediation for a single override.
ACTREPO="$WORKDIR/actrepo"
git init -q -b release "$ACTREPO"
printf '[user]\n\temail = active@example.com\n' > "$ACTREPO/.git/release-identity"
git -C "$ACTREPO" config --local includeIf.onbranch:release.path release-identity
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$ACTREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
N_ENTRIES="$(printf '%s\n' "$OUT" | grep -c "user.email = active@example.com" || true)"
N_REMEDIES="$(printf '%s\n' "$OUT" | grep -c -- "--unset-all user.email" || true)"
if [ "$RC" = "1" ] \
  && [ "$N_ENTRIES" -eq 1 ] \
  && [ "$N_REMEDIES" -eq 1 ] \
  && ! printf '%s' "$OUT" | grep -q "via inactive include:"; then
  pass "active includeIf: reported once, as an active include"
else
  fail "active includeIf double-reported: entries=$N_ENTRIES remedies=$N_REMEDIES rc=$RC out=$OUT"
fi

# Case 35b: every printed remediation is executable shell, so paths must be
# shell-quoted rather than interpolated into double quotes. Both the repository
# root and the included file deliberately contain command-substitution syntax;
# evaluating the printed command must clear the offender without executing it.
REMEDY_REPO="$WORKDIR/remedy-\"-\$(touch PWNED)-repo"
REMEDY_CWD="$WORKDIR/remedy-exec-cwd"
REMEDY_INCLUDE="$REMEDY_REPO/.git/identity-\"-\$(touch INCLUDE_PWNED)"
mkdir -p "$REMEDY_CWD"
git init -q -b main "$REMEDY_REPO"
printf '[user]\n\temail = quoted-remedy@example.com\n' > "$REMEDY_INCLUDE"
git -C "$REMEDY_REPO" config --local include.path "$REMEDY_INCLUDE"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$REMEDY_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all' | head -1 || true)"
set +e
( cd "$REMEDY_CWD" && eval "$REMEDY" ) >/dev/null 2>&1
REMEDY_RC=$?
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$REMEDY_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ -n "$REMEDY" ] && [ "$REMEDY_RC" = "0" ] && [ "$RC" = "0" ] \
  && [ ! -e "$REMEDY_CWD/PWNED" ] \
  && [ ! -e "$REMEDY_CWD/INCLUDE_PWNED" ]; then
  pass "remediation paths are shell-quoted: command clears the offender without substitution"
else
  fail "unsafe remediation path: remedy='$REMEDY' remedy_rc=$REMEDY_RC rc=$RC out=$OUT"
fi

# Case 36: the documented opt-out for a checkout that wants its own
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

# Case 37: clearing the override restores a clean result — the guard
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

# Case 38: --snapshot records a baseline and a later run confirms the
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

# Case 38b: deleting the baseline after requesting a snapshot must fail
# closed. Otherwise the plain check silently forgets that comparison was
# requested, and a config write hidden behind the deleted evidence passes.
BASELINE_REPO="$WORKDIR/missing-baseline-repo"
git init -q -b main "$BASELINE_REPO"
MERGEPATH_GIT_IDENTITY_ROOT="$BASELINE_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
git -C "$BASELINE_REPO" config --local core.pager cat
rm -f "$BASELINE_REPO/.git/mergepath-gitconfig-baseline"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$BASELINE_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "snapshot baseline is missing" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "deleted snapshot baseline: fails closed instead of forgetting the comparison"
else
  fail "deleted snapshot baseline forgotten: rc=$RC out=$OUT"
fi

# Case 39: any write to .git/config between snapshot and check fails,
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

# ── Part B, --verify: the per-shard closing form (#2163) ───────────────

# Case 39v: `--verify` is what every fast-lane shard that does NOT run the
# full check closes with. It must run Parts A and B against the snapshot
# and NOTHING else: the fixture carries a Part C offender in a tracked
# script and names a suite stub that leaves a sentinel, so a verify that
# scanned the tree or ran the suite is visible as either a hit or a file.
# The contrast run proves the fixture is not vacuous: the plain call on
# the same tree DOES fail on the offender.
VERIFY_REPO="$WORKDIR/verify-repo"
git init -q -b main "$VERIFY_REPO"
mkdir -p "$VERIFY_REPO/scripts"
printf '#!/usr/bin/env bash
git config user.email "verify-offender@example.com"
'   > "$VERIFY_REPO/scripts/offender.sh"
VERIFY_SUITE="$WORKDIR/verify-suite.sh"
VERIFY_SENTINEL="$WORKDIR/verify-suite-ran"
printf '#!/usr/bin/env bash
touch "%s"
' "$VERIFY_SENTINEL" > "$VERIFY_SUITE"
MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_REPO" MERGEPATH_GIT_IDENTITY_SUITE="$VERIFY_SUITE" bash "$CHECK" --verify 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "unchanged since snapshot" \
  && printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS (--verify" \
  && ! printf '%s' "$OUT" | grep -q "verify-offender" \
  && [ ! -e "$VERIFY_SENTINEL" ]; then
  pass "--verify: Parts A and B pass against the snapshot; no tree scan, no suite"
else
  fail "--verify ran more than Parts A and B: rc=$RC sentinel=$([ -e "$VERIFY_SENTINEL" ] && echo present || echo absent) out=$OUT"
fi
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_REPO" MERGEPATH_GIT_IDENTITY_SUITE="$VERIFY_SUITE" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "verify-offender"; then
  pass "--verify contrast: the plain call on the same tree still fails the Part C offender"
else
  fail "--verify contrast fixture is vacuous: the plain call did not fail on the offender (rc=$RC out=$OUT)"
fi

# Case 39w: `--verify` still catches a config write after the snapshot —
# the per-shard invariant it exists to assert.
git -C "$VERIFY_REPO" config --local core.bigFileThreshold 456m
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_REPO" bash "$CHECK" --verify 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "changed since the snapshot" \
  && printf '%s' "$OUT" | grep -q "bigFileThreshold" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "--verify: a config write since the snapshot fails, with the diff"
else
  fail "--verify missed a config write: rc=$RC out=$OUT"
fi

# Case 39x: `--verify` still runs Part A. The override is written BEFORE
# the snapshot so Part B is clean and only the live assertion can fail.
VERIFY_IDREPO="$WORKDIR/verify-identity-repo"
git init -q -b main "$VERIFY_IDREPO"
git -C "$VERIFY_IDREPO" config --local user.email "verify-local@example.com"
MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_IDREPO" bash "$CHECK" --snapshot >/dev/null 2>&1
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_IDREPO" bash "$CHECK" --verify 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "user.email = verify-local@example.com" \
  && printf '%s' "$OUT" | grep -q "unchanged since snapshot" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "--verify: a repo-local identity override still fails Part A"
else
  fail "--verify skipped Part A: rc=$RC out=$OUT"
fi

# Case 39y: `--verify` with no snapshot fails closed. A shard whose
# snapshot step never recorded a baseline has nothing to compare, and a
# verify that passed over that would bless the shard with no evidence.
VERIFY_NOSNAP="$WORKDIR/verify-nosnapshot-repo"
git init -q -b main "$VERIFY_NOSNAP"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_NOSNAP" bash "$CHECK" --verify 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "no snapshot was recorded for this checkout" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "--verify: no recorded snapshot fails closed"
else
  fail "--verify passed with nothing to compare against: rc=$RC out=$OUT"
fi

# Case 39z: and the same when the snapshot was requested but its baseline
# is gone — Part B's own fail-closed arm, reached through --verify.
VERIFY_GONE="$WORKDIR/verify-baseline-gone-repo"
git init -q -b main "$VERIFY_GONE"
MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_GONE" bash "$CHECK" --snapshot >/dev/null 2>&1
rm -f "$VERIFY_GONE/.git/mergepath-gitconfig-baseline"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$VERIFY_GONE" bash "$CHECK" --verify 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "snapshot baseline is missing" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "--verify: a deleted baseline fails closed"
else
  fail "--verify forgot a requested comparison: rc=$RC out=$OUT"
fi

# Case 39b: linked worktrees share `.git/config` but must not share the
# snapshot slot. Otherwise worktree B can overwrite worktree A's baseline
# after a mutation, causing A's later comparison to bless the changed config.
MULTI_REPO="$WORKDIR/multi-worktree-repo"
MULTI_B="$WORKDIR/multi-worktree-b"
git init -q -b main "$MULTI_REPO"
printf 'seed\n' > "$MULTI_REPO/seed.txt"
git -C "$MULTI_REPO" add seed.txt
git -C "$MULTI_REPO" -c user.name=fixture -c user.email=fixture@example.com \
  commit -q -m seed
git -C "$MULTI_REPO" worktree add -q -b other "$MULTI_B"
MERGEPATH_GIT_IDENTITY_ROOT="$MULTI_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
git -C "$MULTI_B" config --local core.pager cat
MERGEPATH_GIT_IDENTITY_ROOT="$MULTI_B" bash "$CHECK" --snapshot >/dev/null 2>&1
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$MULTI_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "changed since the snapshot" \
  && printf '%s' "$OUT" | grep -q "pager"; then
  pass "linked worktrees keep independent snapshot baselines"
else
  fail "linked worktree snapshot overwrote another baseline: rc=$RC out=$OUT"
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

# Case 40: a suite that writes a non-identity key is caught by the
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

# Case 41: a suite that writes an identity key is caught by the
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

# Case 42: the post-suite pass must not turn a clean suite red.
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

# ── Precision: what counts as a command, a flag, a key, a surface ─────
# The scan reasons about text. Everything below is a place where reading
# the text loosely made it reason about the WRONG text: a flag that was
# really part of a value, a key spelled in casing git accepts, an
# executable named by path, a file the classifier never opened, a marker
# that was never a comment. Each case pairs the missed shape with the
# converse, so tightening the reading does not start inventing hits.

# Case 43: identity keys are case-insensitive in git — in the section
# name and in the key name alike. `git config User.Email <addr>` writes
# `[User] Email` and a later lowercase `git config user.email` reads it
# straight back, so a lowercase-only pattern let a documented `User.Email`
# instruction through a guard whose entire subject is the write that
# instruction performs. The read-back is asserted against real git, so
# the fixture cannot be modelling a world where casing matters.
CASEREPO="$WORKDIR/caserepo"
git init -q -b main "$CASEREPO"
git -C "$CASEREPO" config User.Email "Upper@example.com"
CASE_READBACK="$(git -C "$CASEREPO" config --local --get user.email 2>/dev/null || true)"
run_on_fixture "tests/mixed-case.sh" '#!/usr/bin/env bash
git config User.Email "Upper@example.com"
git config USER.NAME "Upper"
git config Commit.GpgSign false
'
if [ "$CASE_READBACK" = "Upper@example.com" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/mixed-case.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/mixed-case.sh:3" \
  && printf '%s' "$OUT" | grep -q "tests/mixed-case.sh:4"; then
  pass "identity keys in git-accepted casing: caught"
else
  fail "mixed-case identity keys: readback='$CASE_READBACK' rc=$RC out=$OUT"
fi

# Case 44: a read flag must be recognised as a flag, not as a substring.
# `git config user.email author--get@example.com` writes that address —
# asserted against real git below — while a bare search for `--get`
# anywhere in the invocation classified it as a read. Cutting adjacent
# commands cannot help here: the suppressor is inside the value of the
# same command.
GETVALREPO="$WORKDIR/getvalrepo"
git init -q -b main "$GETVALREPO"
git -C "$GETVALREPO" config user.email "author--get@example.com"
GETVAL_READBACK="$(git -C "$GETVALREPO" config --local --get user.email 2>/dev/null || true)"
run_on_fixture "tests/flagish-value.sh" '#!/usr/bin/env bash
git config user.email author--get@example.com
git config user.name no--list-here
'
if [ "$GETVAL_READBACK" = "author--get@example.com" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/flagish-value.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/flagish-value.sh:3"; then
  pass "read flag embedded in the value: no longer suppresses the write"
else
  fail "flag-shaped value suppressing a write: readback='$GETVAL_READBACK' rc=$RC out=$OUT"
fi

# Case 44b: a value can begin with `-` or `\`. Option-looking text after the
# key is a value too: Git writes `--show-origin` when it appears there.
LEADING_REPO="$WORKDIR/leading-value-repo"
git init -q -b main "$LEADING_REPO"
git -C "$LEADING_REPO" config user.email '-leak@example.com'
LEADING_HYPHEN="$(git -C "$LEADING_REPO" config --local --get user.email 2>/dev/null || true)"
git -C "$LEADING_REPO" config user.email '\leak@example.com'
LEADING_SLASH="$(git -C "$LEADING_REPO" config --local --get user.email 2>/dev/null || true)"
git -C "$LEADING_REPO" config user.email --show-origin
LEADING_OPTION="$(git -C "$LEADING_REPO" config --local --get user.email 2>/dev/null || true)"
run_on_fixture "tests/leading-value.sh" '#!/usr/bin/env bash
git config user.email -leak@example.com
git config user.name \leaky
git config user.email --show-origin
'
if [ "$LEADING_HYPHEN" = "-leak@example.com" ] \
  && [ "$LEADING_SLASH" = '\leak@example.com' ] \
  && [ "$LEADING_OPTION" = "--show-origin" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/leading-value.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/leading-value.sh:3" \
  && printf '%s' "$OUT" | grep -q "tests/leading-value.sh:4"; then
  pass "hyphen-, backslash-, and option-shaped identity values: caught by position"
else
  fail "leading identity values skipped: hyphen='$LEADING_HYPHEN' slash='$LEADING_SLASH' option='$LEADING_OPTION' rc=$RC out=$OUT"
fi

# Case 45: a scope flag AFTER the key does not scope the write, so it
# must not suppress either. `git config user.email <addr> --global`
# writes the LOCAL config — asserted against real git below, with
# GIT_CONFIG_GLOBAL and HOME both pointed at scratch paths so that the
# assertion cannot touch the operator's real global config whatever git
# decides to do with the trailing flag.
TRAILREPO="$WORKDIR/trailrepo"
TRAILGLOBAL="$WORKDIR/trail-gitconfig-global"
git init -q -b main "$TRAILREPO"
: > "$TRAILGLOBAL"
set +e
HOME="$WORKDIR" GIT_CONFIG_GLOBAL="$TRAILGLOBAL" \
  git -C "$TRAILREPO" config user.email "trailing@example.com" --global >/dev/null 2>&1
set -e
TRAIL_LOCAL="$(git -C "$TRAILREPO" config --local --get user.email 2>/dev/null || true)"
TRAIL_GLOBAL_LEFT="$(grep -c . "$TRAILGLOBAL" 2>/dev/null || true)"
run_on_fixture "tests/trailing-global.sh" '#!/usr/bin/env bash
git config user.email trailing@example.com --global
'
if [ "$TRAIL_LOCAL" = "trailing@example.com" ] \
  && [ "$TRAIL_GLOBAL_LEFT" = "0" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/trailing-global.sh:2"; then
  pass "scope flag after the key: does not suppress the local write it is not scoping"
else
  fail "trailing --global suppressing a local write: local='$TRAIL_LOCAL' globalLines='$TRAIL_GLOBAL_LEFT' rc=$RC out=$OUT"
fi

# Case 46: the converse of cases 44 and 45 — reading flags only from the
# option region must not lose a flag that IS in it. Every legitimate
# spelling puts its target or scope between `git` and the key.
run_on_fixture "tests/flags-before-key.sh" '#!/usr/bin/env bash
git config --global user.email "you@example.com"
git -C "$FIX" config user.email "t@t"
git --git-dir="$FIX/.git" config user.email "t@t"
git config --file "$FIX/.git/config" user.email "t@t"
git config -f "$FIX/.git/config" user.name "t"
git config -f"$FIX/.git/config" user.signingkey "ABC123"
git config --glob user.email "you@example.com"
git config --syst user.name "root"
git config --fil "$FIX/.git/config" commit.gpgsign false
git config --system user.email "root@example.com"
'
if [ "$RC" = "0" ]; then
  pass "target / scope flags in the option region: still suppress"
else
  fail "option-region flags no longer suppressing: rc=$RC out=$OUT"
fi

# Case 46b: a flag spelling that is only PART of a longer word inside the
# option region is not a flag either. This is case 44 one step to the
# LEFT of the key, where restricting the search to the option region
# cannot help: the argument of another option (here an `--exec-path`
# under a directory whose name happens to contain `--get`) is inside the
# region, and a bare substring search read it as a read flag and
# suppressed the write beside it.
run_on_fixture "tests/flagish-option-arg.sh" '#!/usr/bin/env bash
git --exec-path=/opt/git--get/libexec config user.email leak@example.com
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/flagish-option-arg.sh:2"; then
  pass "flag spelling inside another option argument: does not suppress"
else
  fail "flag-shaped option argument suppressing a write: rc=$RC out=$OUT"
fi

# Case 47: a path-qualified executable is the same command. The
# character before `git` in `/usr/bin/git config …` is a `/`, which the
# word boundary used to reject outright, so an absolute-path invocation
# skipped every scope check while writing exactly the file a bare `git`
# writes.
run_on_fixture "tests/qualified-git.sh" '#!/usr/bin/env bash
/usr/bin/git config user.email absolute@example.com
/opt/homebrew/bin/git config user.name brew
./git config user.signingkey ABC123
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/qualified-git.sh:2" \
  && printf '%s' "$OUT" | grep -q "tests/qualified-git.sh:3" \
  && printf '%s' "$OUT" | grep -q "tests/qualified-git.sh:4"; then
  pass "path-qualified git executables: caught"
else
  fail "path-qualified git executables: rc=$RC out=$OUT"
fi

# Case 47b: quoting the command word does not change the executable. Both a
# quoted PATH lookup and a quoted path-qualified word run Git and write the
# same current-repository config as their unquoted counterparts.
run_on_fixture "tests/quoted-git.sh" '#!/usr/bin/env bash
"git" config user.email quoted@example.com
'
quoted_path_out="$OUT"
quoted_path_rc=$RC
run_on_fixture "tests/quoted-git-path.sh" "#!/usr/bin/env bash
'/usr/bin/git' config user.name quoted
"
if [ "$quoted_path_rc" = "1" ] \
  && printf '%s' "$quoted_path_out" | grep -q "tests/quoted-git.sh:2" \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/quoted-git-path.sh:2"; then
  pass "quoted Git executable words: caught in PATH and path-qualified forms"
else
  fail "quoted Git executable escaped scan: path_rc=$quoted_path_rc path_out=$quoted_path_out rc=$RC out=$OUT"
fi

# Case 48: the converse of case 47 — accepting a `/` before `git` must
# not turn every mention of `.git/config` into a hit, and a
# path-qualified invocation that IS scoped stays clean.
run_on_fixture "docs/paths.md" '# Paths

An unscoped write lands in `.git/config`, which every worktree of the
repository reads. The sanctioned form is `/usr/bin/git config --global
user.email you@example.com`, and a fixture takes `git -C "$FIX" config
user.email t@t`.
'
if [ "$RC" = "0" ]; then
  pass "prose naming .git/config, and a scoped qualified git: no false hit"
else
  fail "path boundary inventing a hit: rc=$RC out=$OUT"
fi

# Case 49: Markdown is more than lowercase `.md`. A doc named
# `*.markdown` or `*.MD` is a doc, and one the classifier skipped had no
# gate on it at all. The body is case 23 — a sanctioned `--global`
# example beside a forbidden one in prose — so this also proves the file
# gets the MARKDOWN treatment (cut on backticks) and not the shell one,
# which would judge the whole sentence as a single piece and let the
# first example wave the second through.
run_on_fixture "docs/prose.markdown" '# Identity

Use `git config --global user.email you@example.com`, never `git config user.email you@example.com`.
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "docs/prose.markdown:3"; then
  pass ".markdown doc: scanned, and cut on backticks like any Markdown"
else
  fail ".markdown doc: rc=$RC out=$OUT"
fi

run_on_fixture "docs/UPPER.MD" '# Identity

Never run `git config user.email leak@example.com`.
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/UPPER.MD:3"; then
  pass "uppercase .MD doc: scanned"
else
  fail "uppercase .MD doc: rc=$RC out=$OUT"
fi

# Case 50: an extensionless script is classified by its shebang, and the
# interpreter set has to cover the shells people write. `#!/usr/bin/env
# sh` in particular was missed by a `/sh` substring test — there is no
# slash before the interpreter word in the `env` form — and zsh, ksh and
# dash run `git config` exactly as bash does.
for SHEBANG in '#!/usr/bin/env zsh' '#!/bin/dash' '#!/usr/bin/env sh' '#!/bin/ksh' '#!/bin/zsh'; do
  run_on_fixture "tools/hook" "$SHEBANG
git config user.email leak@example.com
"
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "tools/hook:2"; then
    pass "extensionless script with shebang '$SHEBANG': scanned"
  else
    fail "extensionless script with shebang '$SHEBANG': rc=$RC out=$OUT"
  fi
done

# Case 51: the converse of case 50 — the shebang widening must not pull
# in files that are not shell. A python script naming the same command in
# a string is not a shell writer, and the scan has no business judging it.
run_on_fixture "tools/pyhook" '#!/usr/bin/env python3
subprocess.run("git config user.email leak@example.com", shell=True)
'
if [ "$RC" = "0" ]; then
  pass "non-shell shebang: not scanned"
else
  fail "non-shell shebang pulled into the scan: rc=$RC out=$OUT"
fi

# Case 52: the exemption marker has to BE a comment. Honouring it
# anywhere on the line meant merely PRINTING it switched the scan off for
# that line, which is the same shape as case 25 one step further out: not
# a citation inside a code span, but string data in a live command.
run_on_fixture "tests/printed-marker.sh" '#!/usr/bin/env bash
echo "GIT_IDENTITY_SCOPE_EXEMPT: merely-printed"; git config user.email leak@example.com
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/printed-marker.sh:2"; then
  pass "marker printed as string data: does not exempt the write beside it"
else
  fail "printed marker exempting a live write: rc=$RC out=$OUT"
fi

# Case 53: the same in Markdown. A sentence that names the marker in
# plain prose — outside any code span, so case 25's span-stripping does
# not reach it — is still discussing the marker, not using it. The
# documented Markdown spelling is an HTML comment.
run_on_fixture "docs/prose-marker.md" '# Identity

A deliberate exception is marked GIT_IDENTITY_SCOPE_EXEMPT: with a reason, as in `git config user.email you@example.com`.
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "docs/prose-marker.md:3"; then
  pass "marker named in Markdown prose: does not exempt the write beside it"
else
  fail "prose marker exempting a live write: rc=$RC out=$OUT"
fi

# Case 54: the converse of cases 52 and 53 — a `#` comment inside a
# Markdown code block is a real marker. That is where an exemption in a
# doc naturally sits: the line carries no spans to strip and a shell
# comment is the idiom of the block it is in.
run_on_fixture "docs/fenced-marker.md" '# Identity

```bash
git config user.email "t@t"  # GIT_IDENTITY_SCOPE_EXEMPT: fixture, container only
```
'
if [ "$RC" = "0" ]; then
  pass "shell-comment marker inside a Markdown code block: exempts the line"
else
  fail "marker in a Markdown code block not honoured: rc=$RC out=$OUT"
fi

# Case 54b: quoted or escaped shell data cannot forge a comment marker.
# These are scan-only inputs; none of the fixture commands are executed.
while IFS= read -r LINE; do
  run_on_fixture "tests/quoted-marker.sh" "$LINE
"
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "tests/quoted-marker.sh:1"; then
    pass "quoted/escaped comment-shaped marker does not exempt: $LINE"
  else
    fail "quoted/escaped marker exemption: rc=$RC out=$OUT"
  fi
done <<'EOF'
git config user.email leak@example.com; echo " # GIT_IDENTITY_SCOPE_EXEMPT: x"
git config user.email leak@example.com; echo ' # GIT_IDENTITY_SCOPE_EXEMPT: x'
git config user.email leak@example.com; echo \# GIT_IDENTITY_SCOPE_EXEMPT: x
git config user.email leak@example.com; echo \ # GIT_IDENTITY_SCOPE_EXEMPT: x
git config user.email leak@example.com; echo "escaped \" # GIT_IDENTITY_SCOPE_EXEMPT: x"
git config user.email leak@example.com; echo $'escaped \' # GIT_IDENTITY_SCOPE_EXEMPT: x'
EOF

# Case 54c: closed strings and escaped data do not hide a later real comment.
while IFS= read -r LINE; do
  run_on_fixture "tests/comment-marker.sh" "$LINE
"
  if [ "$RC" = "0" ]; then
    pass "real comment after quoted/escaped data still exempts: $LINE"
  else
    fail "real marker after quoted/escaped data: rc=$RC out=$OUT"
  fi
done <<'EOF'
git config user.email "fixture@example.com" # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email 'fixture@example.com' # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email fixture\ value # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email "escaped \" value" # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email $'escaped \' value' # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
EOF

# Case 54ca: a control operator opens a real comment boundary even when
# no space precedes the #. Quoted or escaped operators remain string data.
while IFS= read -r LINE; do
  run_on_fixture "tests/operator-comment.sh" "$LINE
"
  if [ "$RC" = "0" ]; then
    pass "real exemption after a control operator: $LINE"
  else
    fail "control-operator exemption rejected: rc=$RC out=$OUT"
  fi
done <<'EOF'
git config user.email fixture@example.com;# GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email fixture@example.com&&# GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email fixture@example.com||# GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email fixture@example.com&# GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
git config user.email fixture@example.com|# GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
(git config user.email fixture@example.com)# GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
EOF
while IFS= read -r LINE; do
  run_on_fixture "tests/operator-data.sh" "$LINE
"
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'tests/operator-data.sh:1'; then
    pass "quoted/escaped control operator cannot forge exemption: $LINE"
  else
    fail "control-operator data exempted writer: rc=$RC out=$OUT"
  fi
done <<'EOF'
git config user.email leak@example.com; echo ";# GIT_IDENTITY_SCOPE_EXEMPT: literal"
git config user.email leak@example.com; echo '|# GIT_IDENTITY_SCOPE_EXEMPT: literal'
git config user.email leak@example.com; echo \;# GIT_IDENTITY_SCOPE_EXEMPT: literal
EOF

# Case 54d: Markdown exemptions need a complete comment with its reason inside.
while IFS= read -r LINE; do
  run_on_fixture "docs/broken-marker.md" "$LINE
"
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/broken-marker.md:1"; then
    pass "invalid Markdown comment does not exempt: $LINE"
  else
    fail "invalid Markdown comment exemption: rc=$RC out=$OUT"
  fi
done <<'EOF'
git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: x
git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: -->
git config user.email leak@example.com <!-- other --> GIT_IDENTITY_SCOPE_EXEMPT: x <!-- other -->
EOF
run_on_fixture "docs/closed-marker.md" '`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: fixture value > only -->
'
if [ "$RC" = "0" ]; then
  pass "complete HTML exemption after a code span: allowed, including > in the reason"
else
  fail "complete Markdown marker: rc=$RC out=$OUT"
fi

# Case 54e: HTML markers are literal code inside either Markdown fence.
# A shorter or mismatched delimiter cannot end the fenced-code context.
for FENCE in '```' '~~~' '````' '~~~~'; do
  if [[ "$FENCE" == \`* ]]; then MISMATCH='~~~'; else MISMATCH='```'; fi
  run_on_fixture "docs/fenced-html.md" "$FENCE"'bash
'"${FENCE%?}"'
'"$MISMATCH"'
git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/fenced-html.md:4"; then
    pass "HTML marker inside $FENCE fence: cannot exempt a write"
  else
    fail "HTML marker inside $FENCE fence: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/fenced-shell.md" "$FENCE"'bash
git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
'"$FENCE"'
`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: recorded evidence -->
'
  if [ "$RC" = "0" ]; then
    pass "shell marker inside $FENCE fence and HTML marker after closing: allowed"
  else
    fail "valid exemptions around $FENCE fence: rc=$RC out=$OUT"
  fi
done
run_on_fixture "docs/continued-fenced-html.md" '   ~~~~bash
git config user.email \
fixture@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
   ~~~~~
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/continued-fenced-html.md:2"; then
  pass "continued command inside indented Markdown fence: HTML marker cannot exempt"
else
  fail "continued fenced HTML marker: rc=$RC out=$OUT"
fi
# Fence state belongs to each file, even when the preceding fence never closes.
run_on_fixture "docs/a-unclosed.md" '```bash
'
printf '%s\n' '`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: recorded evidence -->' > "$WORKDIR/fixture-$FIXTURE_SEQ/docs/b-outside.md"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$WORKDIR/fixture-$FIXTURE_SEQ" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "unclosed Markdown fence does not leak into another file"
else
  fail "Markdown fence state leaked between files: rc=$RC out=$OUT"
fi

# Case 54j: VT/FF are neither fence-closing blanks nor shell blanks.
# These are scan-only source bytes, never executed fixture commands.
for CONTROL in $'\v' $'\f' $'\r'; do
  run_on_fixture "tests/control-marker.sh" "git config user.email leak@example.com;echo X${CONTROL}# GIT_IDENTITY_SCOPE_EXEMPT: printed data
"
  if [ "$RC" = "1" ]; then
    pass "non-shell blank before hash cannot forge a comment exemption"
  else
    fail "control byte forged shell comment: rc=$RC out=$OUT"
  fi
done
for CONTROL in $'\v' $'\f'; do
  for FENCE in '```' '~~~'; do
    run_on_fixture "docs/control-fence.md" "${FENCE}bash
${FENCE}${CONTROL}
git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: fenced data -->
${FENCE}
"'`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: real outside comment -->
'
    if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/control-fence.md:3:' \
      && ! printf '%s' "$OUT" | grep -q 'docs/control-fence.md:5:'; then
      pass "control byte cannot close $FENCE fence; real closer restores HTML comments"
    else
      fail "control-byte $FENCE fence boundary: rc=$RC out=$OUT"
    fi
  done
done
for BLANK in ' ' $'\t'; do
  run_on_fixture "tests/blank-marker.sh" "git config user.email fixture@example.com${BLANK}# GIT_IDENTITY_SCOPE_EXEMPT: real shell comment
"
  if [ "$RC" = "0" ]; then
    pass "shell space/tab still opens a real exemption comment"
  else
    fail "real shell blank rejected: rc=$RC out=$OUT"
  fi
  run_on_fixture "tests/blank-marker-neighbour.sh" "git config user.email leak@example.com;echo X${BLANK}# GIT_IDENTITY_SCOPE_EXEMPT: echo only
"
  if [ "$RC" = "1" ]; then
    pass "real shell blank on later comment does not exempt earlier writer"
  else
    fail "later space/tab marker widened command exemption: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/blank-fence.md" '```bash
'"\`\`\`${BLANK}"$'\r\n'"git config user.email fixture@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: after CRLF closer -->"$'\r\n'
  if [ "$RC" = "0" ]; then
    pass "space/tab fence closer accepts CRLF and restores real HTML exemptions"
  else
    fail "real CRLF fence closer rejected: rc=$RC out=$OUT"
  fi
done

# Case 54k: comment-shaped text in inline links and HTML attributes is data.
# Quote styles, balanced/escaped parentheses, and markup escapes share the
# real lexer. A real comment after each closed construct still exempts.
for DATA in \
  '[marker](https://example.invalid "<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->")' \
  "[marker](https://example.invalid '<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->')" \
  '[marker](https://example.invalid (<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->))' \
  '[marker](<https://example.invalid/a)> "<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->")' \
  "[marker](<https://example.invalid/a)> '<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->')" \
  '[marker]( <https://example.invalid/a(b)> (<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->))' \
  '[marker](<https://example.invalid/a\>b)> "<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->")' \
  '[marker](https://example.invalid/a(b) "<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal ) title -->")' \
  '[marker](https://example.invalid/a\(b\) "<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal title -->")' \
  '<span title="<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal attribute -->">text</span>' \
  "<span title='<!-- GIT_IDENTITY_SCOPE_EXEMPT: literal attribute -->'>text</span>" \
  '<span title="literal > <!-- GIT_IDENTITY_SCOPE_EXEMPT: attribute -->">text</span>' \
  '\<!-- GIT_IDENTITY_SCOPE_EXEMPT: escaped markup -->'; do
  run_on_fixture "docs/data-marker.md" "git config user.email leak@example.com ${DATA}
"
  if [ "$RC" = "1" ]; then
    pass "HTML marker in link/attribute/escaped data cannot exempt a writer"
  else
    fail "comment-shaped Markdown data accepted: '$DATA' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/data-then-comment.md" "git config user.email fixture@example.com ${DATA} <!-- GIT_IDENTITY_SCOPE_EXEMPT: real comment after data -->
"
  if [ "$RC" = "0" ]; then
    pass "real HTML comment after closed link/attribute/escaped data still exempts"
  else
    fail "real comment after Markdown data rejected: '$DATA' rc=$RC out=$OUT"
  fi
done
run_on_fixture "docs/comments-with-quotes.md" 'git config user.email fixture@example.com "quoted prose" <!-- GIT_IDENTITY_SCOPE_EXEMPT: "real quoted reason" -->
git config user.email fixture@example.com <!-- ordinary comment --> <!-- GIT_IDENTITY_SCOPE_EXEMPT: second real comment -->
'
if [ "$RC" = "0" ]; then
  pass "prose quotes and preceding ordinary comments do not mask a true HTML exemption"
else
  fail "true HTML comment over-masked: rc=$RC out=$OUT"
fi

# Case 54f: blockquote and list containers do not make fenced HTML live.
for PREFIX in '> ' '> > ' '- ' '1. ' '> - '; do
  CONTINUATION="$PREFIX"
  case "$PREFIX" in
    '- ') CONTINUATION='  ' ;;
    '1. ') CONTINUATION='   ' ;;
    '> - ') CONTINUATION='>   ' ;;
  esac
  run_on_fixture "docs/container-html.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
'"$CONTINUATION"'```
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/container-html.md:2"; then
    pass "HTML marker in $PREFIX container fence: cannot exempt"
  else
    fail "HTML marker in $PREFIX container fence: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/container-shell.md" "$PREFIX"'~~~bash
'"$CONTINUATION"'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture
'"$CONTINUATION"'~~~

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: evidence outside container -->
git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture outside container
'
  if [ "$RC" = "0" ]; then
    pass "real shell/HTML exemptions inside and after $PREFIX container: allowed"
  else
    fail "real exemptions around $PREFIX container: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/container-continued.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email \
'"$CONTINUATION"'leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
'"$CONTINUATION"'```
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/container-continued.md:2"; then
    pass "continued write inside $PREFIX container fence: HTML cannot exempt"
  else
    fail "continued write inside $PREFIX container fence: rc=$RC out=$OUT"
  fi
  # A container can end without an explicit closing fence. Its context
  # must not suppress legitimate HTML comments in the following paragraph.
  run_on_fixture "docs/container-ended.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: outside ended container -->
'
  if [ "$RC" = "0" ]; then
    pass "ended $PREFIX container drops an unclosed fence: real HTML allowed"
  else
    fail "ended $PREFIX container kept stale fence state: rc=$RC out=$OUT"
  fi
done
# A list fence may open on a continuation line, below the item text.
run_on_fixture "docs/list-continuation-html.md" '- Example:
  ```bash
  git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
  ```
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q "docs/list-continuation-html.md:3"; then
  pass "fence opened on a list continuation: HTML cannot exempt"
else
  fail "list continuation fence: rc=$RC out=$OUT"
fi

# Case 54g: every same-line nested list marker precedes the fence.
for PREFIX in '- - ' '1. - ' '> - - '; do
  case "$PREFIX" in
    '- - ') CONTINUATION='    ' ;;
    '1. - ') CONTINUATION='     ' ;;
    '> - - ') CONTINUATION='>     ' ;;
  esac
  run_on_fixture "docs/nested-list-html.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
'"$CONTINUATION"'```
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/nested-list-html.md:2'; then
    pass "same-line nested list $PREFIX fence: HTML cannot exempt"
  else
    fail "nested list $PREFIX fence: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/nested-list-shell.md" "$PREFIX"'~~~bash
'"$CONTINUATION"'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture
'"$CONTINUATION"'~~~

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: evidence outside -->
'
  if [ "$RC" = "0" ]; then
    pass "same-line nested list $PREFIX preserves real shell/HTML exemptions"
  else
    fail "nested list $PREFIX real exemptions rejected: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/nested-list-continued.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email \
'"$CONTINUATION"'leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
'"$CONTINUATION"'```
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/nested-list-continued.md:2'; then
    pass "same-line nested list $PREFIX continued command: HTML cannot exempt"
  else
    fail "nested list $PREFIX continued command: rc=$RC out=$OUT"
  fi
done

# Case 54h: list indentation is measured in columns, including tab stops.
run_on_fixture "docs/tab-list-html.md" $'- Example:
\t```bash
\tgit config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
\t```
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/tab-list-html.md:3'; then
  pass "tab-indented list fence: HTML cannot exempt"
else
  fail "tab-indented list fence: rc=$RC out=$OUT"
fi
run_on_fixture "docs/tab-nested-list-html.md" $'-\t-\t~~~bash
\t\tgit config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
\t\t~~~
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/tab-nested-list-html.md:2'; then
  pass "tab-separated nested list markers preserve column indentation"
else
  fail "tab-separated nested list fence: rc=$RC out=$OUT"
fi
run_on_fixture "docs/tab-list-shell.md" $'- Example:
\t```bash
\tgit config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture
\t```

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: evidence outside -->
'
if [ "$RC" = "0" ]; then
  pass "tab-indented list preserves real shell and outside HTML exemptions"
else
  fail "tab-indented list real exemptions rejected: rc=$RC out=$OUT"
fi
run_on_fixture "docs/tab-list-ended.md" $'- Example:
\t```bash
\tgit config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: outside ended list -->
'
if [ "$RC" = "0" ]; then
  pass "tab-indented list ending drops unclosed fence context"
else
  fail "ended tab-indented list kept stale fence: rc=$RC out=$OUT"
fi
run_on_fixture "docs/tab-list-continued.md" $'- Example:
\t```bash
\tgit config user.email \\\n\tleak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
\t```
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/tab-list-continued.md:3'; then
  pass "tab-indented continued command: HTML cannot exempt"
else
  fail "tab-indented continued command: rc=$RC out=$OUT"
fi

# Case 54i: quote and list containers may alternate in either order.
# Prefix frames must survive continuation lines in that same order, and
# an inner container can end while its outer containers still continue.
for PREFIX in '- > ' '> - > ' '- > - '; do
  case "$PREFIX" in
    '- > ') CONTINUATION='  > '; OUTER='  ' ;;
    '> - > ') CONTINUATION='>   > '; OUTER='>   ' ;;
    '- > - ') CONTINUATION='  >   '; OUTER='  > ' ;;
  esac
  run_on_fixture "docs/mixed-container-html.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
'"$CONTINUATION"'```
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/mixed-container-html.md:2'; then
    pass "mixed container $PREFIX fence: HTML cannot exempt"
  else
    fail "mixed container $PREFIX HTML exemption: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/mixed-container-continued.md" "$PREFIX"'~~~bash
'"$CONTINUATION"'git config user.email \
'"$CONTINUATION"'leak@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal -->
'"$CONTINUATION"'~~~
'
  if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/mixed-container-continued.md:2'; then
    pass "mixed container $PREFIX continued command: HTML cannot exempt"
  else
    fail "mixed container $PREFIX continued HTML exemption: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/mixed-container-shell.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture
'"$CONTINUATION"'```

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: outside -->
git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture outside
'
  if [ "$RC" = "0" ]; then
    pass "mixed container $PREFIX preserves shell and outside HTML exemptions"
  else
    fail "mixed container $PREFIX real exemptions rejected: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/mixed-container-ended.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture

`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: ended container -->
'
  if [ "$RC" = "0" ]; then
    pass "mixed container $PREFIX termination drops its unclosed fence"
  else
    fail "ended mixed container $PREFIX stale fence: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/mixed-inner-ended.md" "$PREFIX"'```bash
'"$CONTINUATION"'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: fixture
'"$OUTER"'`git config user.email fixture@example.com` <!-- GIT_IDENTITY_SCOPE_EXEMPT: outside inner container -->
'
  if [ "$RC" = "0" ]; then
    pass "mixed container $PREFIX inner termination preserves outer Markdown"
  else
    fail "mixed container $PREFIX inner termination stale fence: rc=$RC out=$OUT"
  fi
done

# ── Fail-closed: include paths the walk cannot follow ──────────────────

# Case 55: `~/…` in an include path is expanded against the operator's
# home, exactly as git expands it. HOME is repointed at a fixture so the
# expansion is observable without writing anything into the real one.
HOMEREPO="$WORKDIR/homerepo"
FAKEHOME="$WORKDIR/fakehome"
mkdir -p "$FAKEHOME"
printf '[user]\n\temail = tildehome@example.com\n' > "$FAKEHOME/identity"
git init -q -b main "$HOMEREPO"
# shellcheck disable=SC2088  # the literal `~/` IS the fixture: git
# expands it, and expanding it here would test nothing.
git -C "$HOMEREPO" config --local includeIf.onbranch:release.path "~/identity"
set +e
OUT="$(HOME="$FAKEHOME" MERGEPATH_GIT_IDENTITY_ROOT="$HOMEREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = tildehome@example.com" \
  && printf '%s' "$OUT" | grep -q "via inactive include:"; then
  pass "identity behind a ~/ include path: expanded and caught"
else
  fail "tilde-home include path: rc=$RC out=$OUT"
fi

# Case 56: `~user/…` is a git-supported spelling too, resolved through
# the passwd database. Treating it as a RELATIVE path turned it into
# `<parent-dir>/~user/…`, which never exists, so the target was dropped
# as absent while git expands the same string against that user's real
# home and obeys the identity it finds — a dormant repository-local
# override escaping the walk completely.
#
# The path is written as a walk UP from the home directory to the fixture
# file, so the case proves the expansion really lands on the user's home
# without the test writing anything inside it. The number of `../` steps
# is deliberately generous rather than counted off `$HOME`: `/..` is `/`,
# so any home shallower than that collapses to the root and the case does
# not depend on how deep the home directory happens to be — nor on $HOME
# agreeing with the passwd entry, which is what the resolver reads.
TILDEUSER="$(id -un)"
TILDEREPO="$WORKDIR/tildeuserrepo"
git init -q -b main "$TILDEREPO"
printf '[user]\n\temail = tildeuser@example.com\n' > "$WORKDIR/tilde-user-identity"
git -C "$TILDEREPO" config --local includeIf.onbranch:release.path \
  "~$TILDEUSER/../../../../../../../../../../../../${WORKDIR#/}/tilde-user-identity"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$TILDEREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = tildeuser@example.com" \
  && printf '%s' "$OUT" | grep -q "via inactive include:"; then
  pass "identity behind a ~user/ include path: expanded and caught"
else
  fail "~user/ include path: user='$TILDEUSER' rc=$RC out=$OUT"
fi

# Case 57: a `~user/…` path this machine cannot resolve FAILS CLOSED
# rather than being skipped. Git performs its own expansion and obeys
# whatever it finds, so "this check could not read it" must not be
# recorded as "there is nothing there" — that is the one outcome that
# hides a live override behind a spelling the resolver does not handle.
NOUSERREPO="$WORKDIR/nouserrepo"
git init -q -b main "$NOUSERREPO"
git -C "$NOUSERREPO" config --local includeIf.onbranch:release.path \
  "~mergepath-no-such-user-777/identity"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NOUSERREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "unresolvable include path" \
  && printf '%s' "$OUT" | grep -q "mergepath-no-such-user-777"; then
  pass "include path this machine cannot expand: fails closed"
else
  fail "unresolvable include path skipped: rc=$RC out=$OUT"
fi

# ... and the printed command must clear it, like every other offender.
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NOUSERREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ -n "$REMEDY" ] && [ "$RC" = "0" ]; then
  pass "unresolvable include remediation: the printed command clears the failure"
else
  fail "unresolvable include remediation: remedy='$REMEDY' rc=$RC out=$OUT"
fi

# Case 58: the converse — an ordinary missing include target is NOT a
# failure. Git ignores an `include.path` whose file does not exist, and
# such an entry carries no identity, so failing on one would fire on
# every templated config in the fleet. What fails closed is a path that
# could not be RESOLVED, not one that resolved to nothing.
MISSINGREPO="$WORKDIR/missingrepo"
git init -q -b main "$MISSINGREPO"
git -C "$MISSINGREPO" config --local includeIf.onbranch:release.path "not-created-yet"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$MISSINGREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ]; then
  pass "include target that resolves but does not exist: not a failure"
else
  fail "missing include target treated as an offender: rc=$RC out=$OUT"
fi

# Case 58b: a relative fixture-root override is resolved once against the
# caller's cwd. Leaving it relative makes later git-dir paths acquire the
# root twice and hides an inactive includeIf identity from the config walk.
RELATIVE_REPO="$WORKDIR/relative-root-repo"
git init -q -b main "$RELATIVE_REPO"
cat > "$RELATIVE_REPO/.git/dormant-identity" <<'EOF'
[user]
  email = dormant-relative@example.com
EOF
git -C "$RELATIVE_REPO" config --local includeIf.onbranch:release.path dormant-identity
set +e
OUT="$(cd "$WORKDIR" && MERGEPATH_GIT_IDENTITY_ROOT=relative-root-repo bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "dormant-relative@example.com" \
  && printf '%s' "$OUT" | grep -q "inactive include"; then
  pass "relative fixture root: inactive include identity is still detected"
else
  fail "relative fixture root hid include identity: rc=$RC out=$OUT"
fi

# Case 58c: Git expands `%(prefix)/...` in path-valued config entries. An
# inactive includeIf using that runtime prefix is still a repository-local
# dormant identity override and must not disappear from the unconditional walk.
PREFIX_REPO="$WORKDIR/runtime-prefix-repo"
PREFIX_IDENTITY="$WORKDIR/runtime-prefix-identity"
git init -q -b main "$PREFIX_REPO"
printf '[user]\n\temail = runtime-prefix@example.com\n' > "$PREFIX_IDENTITY"
git -C "$PREFIX_REPO" config --local includeIf.onbranch:release.path \
  "%(prefix)/../../../../../../../../../../../../${PREFIX_IDENTITY#/}"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$PREFIX_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "runtime-prefix@example.com" \
  && printf '%s' "$OUT" | grep -q "inactive include"; then
  pass "identity behind a %(prefix)/ include path: expanded with Git and caught"
else
  fail "runtime-prefix include path hid identity: rc=$RC out=$OUT"
fi

# ── Fail-closed: a suite that removes the repository metadata ──────────

# Case 59: the post-suite phase reads the repository through `.git` and
# the baseline out of its worktree git dir, so a suite whose fixture
# cleanup is aimed one directory too high — `rm -rf "$ROOT/.git"` — takes
# the evidence with the subject and every post-suite assertion then finds
# nothing to check. That is the same wrong-target mistake as an unscoped
# `git config`, and a deleted config is certainly not byte-identical to
# its snapshot, so the check must not report PASS for it.
NUKESTUB="$WORKDIR/stub-suite-nuke.sh"
cat > "$NUKESTUB" <<'EOF'
#!/usr/bin/env bash
# A "regression suite" whose cleanup targets the repository it was run
# against instead of its own scratch tree.
rm -rf "$MERGEPATH_GIT_IDENTITY_ROOT/.git"
exit 0
EOF
NUKEREPO="$WORKDIR/nukerepo"
git init -q -b main "$NUKEREPO"
set +e
MERGEPATH_GIT_IDENTITY_ROOT="$NUKEREPO" bash "$CHECK" --snapshot >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NUKEREPO" MERGEPATH_GIT_IDENTITY_SUITE="$NUKESTUB" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "removed repository metadata" \
  && printf '%s' "$OUT" | grep -q "the repository itself" \
  && printf '%s' "$OUT" | grep -q ".git/config" \
  && printf '%s' "$OUT" | grep -q "baseline recorded before the suite ran" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "suite that deletes the repository: caught, not reported PASS"
else
  fail "post-suite metadata assertion: rc=$RC out=$OUT"
fi

# Case 60: a suite that deletes the baseline while also writing the
# config must still be told WHAT it changed. The baseline lives inside
# the git common dir, so losing it used to end the comparison — the run
# could say the baseline was gone but not that the config had moved, and
# the diff is the actionable half. The copy taken before the suite ran
# sits outside the repository and carries the comparison through.
BASEKILLSTUB="$WORKDIR/stub-suite-basekill.sh"
cat > "$BASEKILLSTUB" <<'EOF'
#!/usr/bin/env bash
# Writes the repository config AND removes the recorded baseline, e.g. a
# cleanup step sweeping stray files out of the git dir.
git -C "$MERGEPATH_GIT_IDENTITY_ROOT" config --local core.pager cat
# Spelled out rather than via `rev-parse --git-common-dir`, which reports
# a path relative to the CALLER, not to the repository named by -C.
rm -f "$MERGEPATH_GIT_IDENTITY_ROOT/.git/mergepath-gitconfig-baseline"
exit 0
EOF
BASEKILLREPO="$WORKDIR/basekillrepo"
git init -q -b main "$BASEKILLREPO"
set +e
MERGEPATH_GIT_IDENTITY_ROOT="$BASEKILLREPO" bash "$CHECK" --snapshot >/dev/null 2>&1
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$BASEKILLREPO" MERGEPATH_GIT_IDENTITY_SUITE="$BASEKILLSTUB" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "baseline recorded before the suite ran" \
  && printf '%s' "$OUT" | grep -q "changed since the snapshot" \
  && printf '%s' "$OUT" | grep -q "pager"; then
  pass "suite that deletes the baseline: the config diff is still reported"
else
  fail "preserved baseline not used for the post-suite comparison: rc=$RC out=$OUT"
fi

# Case 61: the converse — the metadata assertion must not fire when the
# repository was never there to begin with. A fixture tree that is not a
# git repository has no `.git` to lose, and the check already skips parts
# A and B for it.
NOREPO="$WORKDIR/norepo"
mkdir -p "$NOREPO"
printf '#!/usr/bin/env bash\n' > "$NOREPO/marker.sh"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NOREPO" MERGEPATH_GIT_IDENTITY_SUITE="$CLEANSTUB" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS" \
  && ! printf '%s' "$OUT" | grep -q "removed repository metadata"; then
  pass "non-repository fixture tree: metadata assertion stays quiet"
else
  fail "metadata assertion firing on a non-repository: rc=$RC out=$OUT"
fi

# Case 62: the check cleans up its own scratch files, on the failure path
# as much as the passing one. They are registered in one list with one
# EXIT trap, because a second `trap … EXIT` replaces the first rather than
# adding to it — and because a registration performed inside `$( … )`
# happens in a subshell that exits immediately, leaving the parent with an
# empty list and every file on disk. TMPDIR is repointed at a scratch
# directory so the assertion sees only this invocation's files.
LEAKTMP="$WORKDIR/leaktmp"
LEAKTREE="$WORKDIR/leaktree"
mkdir -p "$LEAKTMP" "$LEAKTREE/scripts" "$LEAKTREE/tests"
printf '#!/usr/bin/env bash\n' > "$LEAKTREE/scripts/sync-to-downstream.sh"
printf '#!/usr/bin/env bash\ngit config user.email leak@example.com\n' \
  > "$LEAKTREE/tests/leaky.sh"
set +e
TMPDIR="$LEAKTMP" MERGEPATH_GIT_IDENTITY_ROOT="$LEAKTREE" bash "$CHECK" >/dev/null 2>&1
RC=$?
LEFTOVER="$(find "$LEAKTMP" -type f | wc -l | tr -d ' ')"
set -e
if [ "$RC" = "1" ] && [ "$LEFTOVER" = "0" ]; then
  pass "scratch files: removed on exit, including on the failure path"
else
  fail "scratch files left behind: rc=$RC leftover=$LEFTOVER"
fi

# ── Fail-closed: a snapshot whose subject was deleted (#803) ───────────

# Case 63: `--snapshot` and the final report run in SEPARATE processes — an
# early repo_lint step and the job's last one — so everything that carries
# between them is on disk. With the snapshot request stored under `.git`, a
# step that removed the checkout took the request away with the subject:
# the final run found no marker, no baseline and no repository, read the
# tree as an ordinary non-repository, and reported PASS for a job that had
# destroyed the very thing it was asserting about. The marker is asserted
# to live outside `.git` and to survive its deletion, because that is what
# leaves anything behind for the final run to fail on.
SNAPGONE_REPO="$WORKDIR/snapshot-subject-gone-repo"
git init -q -b main "$SNAPGONE_REPO"
MERGEPATH_GIT_IDENTITY_ROOT="$SNAPGONE_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
MARKER_UNDER_GIT="$(find "$SNAPGONE_REPO/.git" -name '*baseline.requested*' | wc -l | tr -d ' ')"
rm -rf "$SNAPGONE_REPO/.git"
MARKER_KEPT=0
if [ -f "$SNAPGONE_REPO/.mergepath/gitconfig-baseline.requested" ]; then
  MARKER_KEPT=1
fi
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPGONE_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && [ "$MARKER_UNDER_GIT" = "0" ] \
  && [ "$MARKER_KEPT" = "1" ] \
  && printf '%s' "$OUT" | grep -q "snapshotted repository is missing" \
  && ! printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS"; then
  pass "snapshot then deleted .git: the request survives outside metadata and fails closed"
else
  fail "deleted checkout blessed after --snapshot: under_git=$MARKER_UNDER_GIT kept=$MARKER_KEPT rc=$RC out=$OUT"
fi

# Case 63b: the converse — the branch above fires on a missing SUBJECT, not
# on the mere presence of a recorded snapshot. An intact checkout still
# reports the ordinary unchanged-since-snapshot result.
SNAPOK_REPO="$WORKDIR/snapshot-subject-intact-repo"
git init -q -b main "$SNAPOK_REPO"
MERGEPATH_GIT_IDENTITY_ROOT="$SNAPOK_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPOK_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "unchanged since snapshot" \
  && printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS" \
  && ! printf '%s' "$OUT" | grep -q "snapshotted repository is missing"; then
  pass "intact checkout with a recorded snapshot: still passes"
else
  fail "intact snapshotted checkout: rc=$RC out=$OUT"
fi

# Case 63c: keeping the request in the working tree also means it travels
# with a COPY of that tree, while the baseline it refers to — which lives in
# the git dir — does not. That is not hypothetical: the consumer-safety
# fixture is built by copying this checkout's working tree with `.git`
# excluded and then `git init`-ing the result, so a snapshot recorded by an
# earlier repo_lint step arrives in the fixture with nothing to compare
# against. The copy then presents the exact shape of a tampered checkout —
# a request whose evidence is gone — for a snapshot nobody took of it, and
# the resulting failure reds every consumer's repo-lint. The request names
# the config it was taken from, so the copy is recognisable as somebody
# else's and left alone.
SNAPSRC_REPO="$WORKDIR/snapshot-copy-source-repo"
git init -q -b main "$SNAPSRC_REPO"
MERGEPATH_GIT_IDENTITY_ROOT="$SNAPSRC_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
SNAPCOPY_REPO="$WORKDIR/snapshot-copy-fixture-repo"
mkdir -p "$SNAPCOPY_REPO/.mergepath"
cp "$SNAPSRC_REPO/.mergepath/gitconfig-baseline.requested" \
  "$SNAPCOPY_REPO/.mergepath/gitconfig-baseline.requested"
git init -q -b main "$SNAPCOPY_REPO"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPCOPY_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS" \
  && printf '%s' "$OUT" | grep -q "recorded for another checkout" \
  && ! printf '%s' "$OUT" | grep -q "baseline is missing" \
  && ! printf '%s' "$OUT" | grep -q "snapshotted repository is missing"; then
  pass "a working-tree copy inherits the request but not the baseline: not this checkout's snapshot"
else
  fail "copied snapshot request failed a checkout nobody snapshotted: rc=$RC out=$OUT"
fi

# Case 63d: the converse, so recognising a foreign request cannot have been
# implemented by ignoring requests generally. In the checkout the snapshot
# was actually taken in, removing the baseline while the request stands is
# still the missing-evidence failure it was before.
SNAPOWN_REPO="$WORKDIR/snapshot-own-baseline-gone-repo"
git init -q -b main "$SNAPOWN_REPO"
MERGEPATH_GIT_IDENTITY_ROOT="$SNAPOWN_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
rm -f "$SNAPOWN_REPO/.git/mergepath-gitconfig-baseline"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPOWN_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "the requested snapshot baseline is missing" \
  && ! printf '%s' "$OUT" | grep -q "recorded for another checkout"; then
  pass "own snapshot with the baseline deleted: still fails closed"
else
  fail "own request with a deleted baseline was waved through: rc=$RC out=$OUT"
fi

# Case 63e: the marker records a config PATH, and a filesystem path may
# contain a newline. Framed by newline, the recorded path split across two
# records and the reader took the first line for the whole of it — so the
# checkout failed to recognise its OWN request, reported it as somebody
# else's, and returned PASS on the deleted baseline that case 63d fails
# on. Fail-open, on a path the filesystem accepts.
SNAPNL_REPO="$WORKDIR/snapshot-newline"$'\n'"path-repo"
git init -q -b main "$SNAPNL_REPO"
MERGEPATH_GIT_IDENTITY_ROOT="$SNAPNL_REPO" bash "$CHECK" --snapshot >/dev/null 2>&1
rm -f "$SNAPNL_REPO/.git/mergepath-gitconfig-baseline"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPNL_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "the requested snapshot baseline is missing" \
  && ! printf '%s' "$OUT" | grep -q "recorded for another checkout"; then
  pass "newline in the checkout path: the marker still names this checkout"
else
  fail "newline-path marker read as a foreign request: rc=$RC out=$OUT"
fi

# Case 63f: the copy case 63c covers with the git dir it does NOT have.
# `tests/test_repo_lint_consumer_safety.sh` rsyncs this working tree with
# `.git` excluded and never `git init`s the result, so the fixture inherits
# the request and is not a repository at all. Deciding "is this mine?" from
# the recorded CONFIG could not tell that tree from the #803 case — both
# have a marker and no resolvable config — and claimed it, reporting a
# checkout nobody snapshotted as one whose metadata had been destroyed.
# That reds every consumer's repo-lint through the fixture.
SNAPNR_SRC="$WORKDIR/snapshot-nonrepo-source-repo"
git init -q -b main "$SNAPNR_SRC"
MERGEPATH_GIT_IDENTITY_ROOT="$SNAPNR_SRC" bash "$CHECK" --snapshot >/dev/null 2>&1
SNAPNR_COPY="$WORKDIR/snapshot-nonrepo-copy"
mkdir -p "$SNAPNR_COPY/.mergepath"
cp "$SNAPNR_SRC/.mergepath/gitconfig-baseline.requested" \
  "$SNAPNR_COPY/.mergepath/gitconfig-baseline.requested"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPNR_COPY" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "check_git_identity_hygiene: PASS" \
  && printf '%s' "$OUT" | grep -q "recorded for another checkout" \
  && ! printf '%s' "$OUT" | grep -q "snapshotted repository is missing"; then
  pass "non-repository tree copy inheriting the request: not this checkout's snapshot"
else
  fail "inherited request failed a non-repository fixture: rc=$RC out=$OUT"
fi

# Case 63g: the marker path is WORKING-TREE content now, so a pull request
# can make its directory a symlink. `>` follows one, which would turn
# `--snapshot` — the job's FIRST repo_lint step, before this check has
# asserted anything — into a write to whatever the link names. The old
# `.git`-local path was not checkout-controlled and had nothing to refuse.
SNAPLINK_REPO="$WORKDIR/snapshot-symlinked-state-repo"
git init -q -b main "$SNAPLINK_REPO"
SNAPLINK_TARGET="$WORKDIR/snapshot-symlink-target"
mkdir -p "$SNAPLINK_TARGET"
ln -s "$SNAPLINK_TARGET" "$SNAPLINK_REPO/.mergepath"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPLINK_REPO" bash "$CHECK" --snapshot 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "snapshot state path is a symlink" \
  && [ ! -e "$SNAPLINK_TARGET/gitconfig-baseline.requested" ]; then
  pass "symlinked snapshot state dir: refused, nothing written through the link"
else
  fail "snapshot wrote through a symlinked state dir: rc=$RC out=$OUT"
fi

# Case 63h: the converse — refusing a link cannot have been implemented by
# refusing the ordinary case. A real directory still records normally.
SNAPPLAIN_REPO="$WORKDIR/snapshot-plain-state-repo"
git init -q -b main "$SNAPPLAIN_REPO"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SNAPPLAIN_REPO" bash "$CHECK" --snapshot 2>&1)"
RC=$?
set -e
if [ "$RC" = "0" ] \
  && printf '%s' "$OUT" | grep -q "snapshot recorded" \
  && [ -f "$SNAPPLAIN_REPO/.mergepath/gitconfig-baseline.requested" ]; then
  pass "ordinary state dir: snapshot still recorded"
else
  fail "ordinary snapshot refused: rc=$RC out=$OUT"
fi

# ── Newline-safe include-target collection (#804) ──────────────────────

# Case 64: a Git include target is an ordinary filename and may contain a
# NEWLINE. Collecting the walk's targets as newline-delimited text split
# one such file into two entries that named nothing; neither existed, both
# were dropped by the file test, and the dormant identity behind it was
# never inspected — free to reactivate the moment its condition matched.
NLREPO="$WORKDIR/newline-include-repo"
git init -q -b main "$NLREPO"
NL_INCLUDE="$NLREPO/.git/dormant"$'\n'"identity"
printf '[user]\n\temail = newline-include@example.com\n' > "$NL_INCLUDE"
git -C "$NLREPO" config --local includeIf.onbranch:release.path "$NL_INCLUDE"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NLREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all user\.email' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
NL_LEFT="$(git config --file "$NL_INCLUDE" --get user.email 2>/dev/null)"
OUT_AFTER="$(MERGEPATH_GIT_IDENTITY_ROOT="$NLREPO" bash "$CHECK" 2>&1)"
RC_AFTER=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "newline-include@example.com" \
  && printf '%s' "$OUT" | grep -q "inactive include" \
  && [ -n "$REMEDY" ] && [ -z "$NL_LEFT" ] && [ "$RC_AFTER" = "0" ]; then
  pass "include target whose filename contains a newline: inspected, and its remediation lands on that file"
else
  fail "newline include target escaped the walk: rc=$RC remedy='$REMEDY' left='$NL_LEFT' after=$RC_AFTER out=$OUT after_out=$OUT_AFTER"
fi

# Case 64c: the same filename shape with the newline LAST. Case 64's name
# carries its newline in the middle, which survives a command substitution;
# a TRAILING one does not — `$( )` strips every trailing newline, so the
# canonicalised target came back one byte short, the file test asked about
# a name no file has, and the identity behind it was dropped exactly as
# before the newline-safe collection was written.
NLTREPO="$WORKDIR/newline-tail-include-repo"
git init -q -b main "$NLTREPO"
NLT_INCLUDE="$NLTREPO/.git/dormant-identity"$'\n'
printf '[user]\n\temail = newline-tail-include@example.com\n' > "$NLT_INCLUDE"
git -C "$NLTREPO" config --local includeIf.onbranch:release.path "$NLT_INCLUDE"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NLTREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "newline-tail-include@example.com" \
  && printf '%s' "$OUT" | grep -q "inactive include"; then
  pass "include target whose filename ENDS in a newline: inspected"
else
  fail "trailing-newline include target escaped the walk: rc=$RC out=$OUT"
fi

# Case 64d: the same filename shape reached by an ACTIVE include, which is
# seen twice — once by the scope read (as an origin) and once by the walk.
# The two halves of the dedupe key must be canonicalised the same way: with
# only the walk's half lossless, the truncated origin matched nothing, one
# override was reported twice, and the first `--file` remediation named a
# path no file has.
NLTA_REPO="$WORKDIR/newline-tail-active-include-repo"
git init -q -b main "$NLTA_REPO"
NLTA_INCLUDE="$NLTA_REPO/.git/active-identity"$'\n'
printf '[user]\n\temail = newline-tail-active@example.com\n' > "$NLTA_INCLUDE"
git -C "$NLTA_REPO" config --local include.path "$NLTA_INCLUDE"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$NLTA_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
N_ENTRIES="$(printf '%s\n' "$OUT" | grep -c "newline-tail-active@example.com" || true)"
if [ "$RC" = "1" ] && [ "$N_ENTRIES" -eq 1 ]; then
  pass "active include whose filename ENDS in a newline: reported once, not twice"
else
  fail "trailing-newline active include double-reported: entries=$N_ENTRIES rc=$RC out=$OUT"
fi

# Case 64b: two `includeIf` entries pointing at the SAME target still yield
# one entry and one remediation. The dedupe moved from a substring test
# over joined text to an element comparison over an array, and an array
# whose membership test is wrong duplicates instead of losing — the failure
# in the opposite direction, and just as visible to an operator.
DEDUPE_INC_REPO="$WORKDIR/dedupe-include-repo"
git init -q -b main "$DEDUPE_INC_REPO"
printf '[user]\n\temail = deduped@example.com\n' > "$DEDUPE_INC_REPO/.git/shared-identity"
git -C "$DEDUPE_INC_REPO" config --local includeIf.onbranch:release.path shared-identity
git -C "$DEDUPE_INC_REPO" config --local includeIf.onbranch:hotfix.path shared-identity
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$DEDUPE_INC_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
N_ENTRIES="$(printf '%s\n' "$OUT" | grep -c "user.email = deduped@example.com" || true)"
N_REMEDIES="$(printf '%s\n' "$OUT" | grep -c -- "--unset-all user.email" || true)"
if [ "$RC" = "1" ] && [ "$N_ENTRIES" -eq 1 ] && [ "$N_REMEDIES" -eq 1 ]; then
  pass "one include target reached by two includeIf entries: reported once"
else
  fail "duplicate include-target reporting: entries=$N_ENTRIES remedies=$N_REMEDIES rc=$RC out=$OUT"
fi

# ── Precision: the protected keys are COMPLETE keys (#805) ─────────────

# Case 65: the identity-key pattern carried no boundary in front of it, so
# it matched the TAIL of any key ending in the same letters.
# `notuser.email`, `precommit.gpgsign` and `retag.gpgsign` are all valid
# git config keys, none of them protected and none of them touching commit
# attribution, and every one of them was reported as a write to the key it
# merely ends with.
run_on_fixture "tests/suffix-keys.sh" '#!/usr/bin/env bash
git config notuser.email "not-protected@example.com"
git config precommit.gpgsign false
git config retag.gpgsign false
git config myuser.name "not-protected"
'
if [ "$RC" = "0" ]; then
  pass "config keys that merely END in a protected key: not reported"
else
  fail "suffix-sharing config keys falsely flagged: rc=$RC out=$OUT"
fi

# Case 65b: the converse, so anchoring the pattern cannot have been
# achieved by turning the scan off. Suffix-sharing keys sit either side of
# a real write, and only the real write is reported.
run_on_fixture "tests/suffix-mixed.sh" '#!/usr/bin/env bash
git config notuser.email "not-protected@example.com"
git config user.email "leak@example.com"
git config retag.gpgsign false
'
N_HITS="$(printf '%s\n' "$OUT" | grep -cE '^  - tests/suffix-mixed\.sh:' || true)"
if [ "$RC" = "1" ] \
  && [ "$N_HITS" -eq 1 ] \
  && printf '%s' "$OUT" | grep -q "tests/suffix-mixed.sh:3:"; then
  pass "suffix keys around a real write: only the exact protected key is reported"
else
  fail "mixed suffix/protected keys: hits=$N_HITS rc=$RC out=$OUT"
fi

# Case 65c: the same mix inside ONE logical command. The line is cut at
# shell separators and each piece judged alone, so the suffix key must not
# stand in for the protected one in either direction: the write is still
# reported, and the piece that only carries a suffix key contributes
# nothing of its own.
run_on_fixture "tests/suffix-same-line.sh" '#!/usr/bin/env bash
git config retag.gpgsign false && git config user.email "leak@example.com"
git config precommit.gpgsign false && git config notuser.email "not-protected@example.com"
'
N_HITS="$(printf '%s\n' "$OUT" | grep -cE '^  - tests/suffix-same-line\.sh:' || true)"
if [ "$RC" = "1" ] \
  && [ "$N_HITS" -eq 1 ] \
  && printf '%s' "$OUT" | grep -q "tests/suffix-same-line.sh:2:"; then
  pass "suffix and protected keys in one command: only the protected write is reported"
else
  fail "same-line suffix/protected mix: hits=$N_HITS rc=$RC out=$OUT"
fi

# Case 65d: a git config SUBSECTION accepts any byte, so a key can end in
# a protected key behind a separator no character class can call a
# boundary. `git config foo.bar/user.email x` stores `foo.bar/user.email`
# and leaves `git config --get user.email` unset (git 2.50.1); the `:`
# spelling behaves the same. Neither is a write to a protected key, and
# neither may red repo_lint.
run_on_fixture "tests/subsection-keys.sh" '#!/usr/bin/env bash
git config foo.bar/user.email "not-protected@example.com"
git config foo.bar:user.email "not-protected@example.com"
git config a.b/commit.gpgsign true
git config a.b:tag.gpgsign true
git config x.y/user.signingkey ABC123
'
if [ "$RC" = "0" ]; then
  pass "subsection keys ending in a protected key: not reported"
else
  fail "subsection-qualified config keys falsely flagged: rc=$RC out=$OUT"
fi

# Case 65e: the converse, so the word boundary cannot have been achieved
# by narrowing the scan away from real writes standing beside one.
run_on_fixture "tests/subsection-mixed.sh" '#!/usr/bin/env bash
git config foo.bar/user.email "not-protected@example.com"
git config user.email "leak@example.com"
git config a.b:commit.gpgsign true
'
N_HITS="$(printf '%s\n' "$OUT" | grep -cE '^  - tests/subsection-mixed\.sh:' || true)"
if [ "$RC" = "1" ] \
  && [ "$N_HITS" -eq 1 ] \
  && printf '%s' "$OUT" | grep -q "tests/subsection-mixed.sh:3:"; then
  pass "subsection keys around a real write: only the exact protected key is reported"
else
  fail "mixed subsection/protected keys: hits=$N_HITS rc=$RC out=$OUT"
fi

# Case 65h: the key may be QUOTED as a whole word. The shell removes the
# quotes and Git is handed the protected key, so the write happens; the
# closing quote is also what stands between the key and the whitespace the
# matcher requires after it, so both ends have to be admitted together.
run_on_fixture "tests/quoted-key.sh" '#!/usr/bin/env bash
git config "user.email" "leak@example.com"
git config '"'"'commit.gpgsign'"'"' false
'
N_HITS="$(printf '%s\n' "$OUT" | grep -cE '^  - tests/quoted-key\.sh:' || true)"
if [ "$RC" = "1" ] && [ "$N_HITS" -eq 2 ]; then
  pass "protected key quoted as a whole word: reported in both quote styles"
else
  fail "quoted protected key missed: hits=$N_HITS rc=$RC out=$OUT"
fi

# Case 65i: the converse. Admitting a quote PAIR must not admit a quote
# anywhere — a subsection-qualified key inside quotes is still not a write
# to a protected key, and an unterminated word is not one Git ever receives.
run_on_fixture "tests/quoted-subsection-keys.sh" '#!/usr/bin/env bash
git config "foo.bar/user.email" "not-protected@example.com"
git config '"'"'a.b:commit.gpgsign'"'"' true
'
if [ "$RC" = "0" ]; then
  pass "quoted subsection-qualified keys: still not reported"
else
  fail "quoted subsection keys falsely flagged: rc=$RC out=$OUT"
fi

# Case 65j: the key may be quoted in PART, not just as a whole word or
# not at all (#921). The shell still delivers the protected key to Git
# once its quote characters are removed, in any of these three shapes:
# a quote around a trailing segment, a quote around a leading segment,
# and a quote that splits a single segment in two.
run_on_fixture "tests/partially-quoted-key.sh" '#!/usr/bin/env bash
git config user.'"'"'email'"'"' "leak@example.com"
git config "user".email "leak2@example.com"
git config us"er".email "leak3@example.com"
'
N_PARTIAL_HITS="$(printf '%s\n' "$OUT" | grep -cE '^  - tests/partially-quoted-key\.sh:' || true)"
if [ "$RC" = "1" ] && [ "$N_PARTIAL_HITS" -eq 3 ]; then
  pass "partially-quoted protected key: reported in all three shapes"
else
  fail "partially-quoted protected key missed: hits=$N_PARTIAL_HITS rc=$RC out=$OUT"
fi

# Case 65k: the converse of 65j — a subsection-qualified key must not
# start over-matching just because dequoting now happens per-word. The
# quotes here still fall inside a word whose dequoted form carries the
# `foo.bar/` subsection prefix, so it never equals the bare protected key.
run_on_fixture "tests/partially-quoted-subsection.sh" '#!/usr/bin/env bash
git config foo.bar/us"er".email "not-protected@example.com"
'
if [ "$RC" = "0" ]; then
  pass "partially-quoted subsection-qualified key: still not reported"
else
  fail "partially-quoted subsection key falsely flagged: rc=$RC out=$OUT"
fi

# Case 65g: a shell escape may stand between the boundary and the key.
# `git config \user.email x` writes the identity — the shell drops the
# backslash and Git is handed `user.email` — while the word as written does
# not begin with `u`. A word boundary that admits nothing between itself
# and the key reads this as no write at all.
run_on_fixture "tests/escaped-key.sh" '#!/usr/bin/env bash
git config \user.email "leak@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/escaped-key.sh:2:"; then
  pass "shell-escaped protected key: still reported"
else
  fail "escaped protected key missed: rc=$RC out=$OUT"
fi

# Case 65l: the escape may stand INSIDE the key, not just before it
# (CodeRabbit, #1011). The shell removes an unquoted backslash escape at
# any position in the word, so `git config us\er.email x` hands Git
# `user.email` too — a rule that only stripped a single LEADING
# backslash missed this one.
run_on_fixture "tests/internally-escaped-key.sh" '#!/usr/bin/env bash
git config us\er.email "leak@example.com"
'
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "tests/internally-escaped-key.sh:2:"; then
  pass "internally-escaped protected key: reported"
else
  fail "internally-escaped protected key missed: rc=$RC out=$OUT"
fi

# Case 65m: dequoting follows the shell, so an UNMATCHED quote is not
# removed (Codex P2 on #1011). `git config "user.email leak@example.com`
# never reaches Git — the shell is still waiting for the closing quote —
# so reporting it reds repo_lint over a fragment nothing can run. The
# fixture asserts BOTH directions at once: the two unterminated lines are
# not reported, while the genuine partially-quoted write below them,
# which this scanner exists to catch, still is. Exactly one hit, on the
# genuine line.
run_on_fixture "tests/unmatched-quote-key.sh" '#!/usr/bin/env bash
git config "user.email leak@example.com
git config '"'"'user.email leak2@example.com
git config "user".email "leak3@example.com"
'
N_UNMATCHED_HITS="$(printf '%s\n' "$OUT" | grep -cE '^  - tests/unmatched-quote-key\.sh:' || true)"
if [ "$RC" = "1" ] \
  && [ "$N_UNMATCHED_HITS" -eq 1 ] \
  && printf '%s' "$OUT" | grep -q "tests/unmatched-quote-key.sh:4:"; then
  pass "unmatched quote: not reported; paired quote on the same fixture still is"
else
  fail "unmatched-quote dequoting wrong: hits=$N_UNMATCHED_HITS rc=$RC out=$OUT"
fi

# Case 65n: literal Git executable words dequote exactly, without expanding
# variables or guessing executable lookup. All snippets below are scan input.
for GIT_WORD in 'g\it' 'gi\t' 'g"i"t' "g'it'" '/usr/bin/g\it'; do
  run_on_fixture "tests/literal-git.sh" "$GIT_WORD config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then
    pass "literal escaped/partially quoted Git word still reports its writer"
  else
    fail "literal Git executable missed: '$GIT_WORD' rc=$RC out=$OUT"
  fi
  run_on_fixture "tests/scoped-literal-git.sh" "$GIT_WORD -C \"\$FIXTURE\" config user.email fixture@example.invalid
"
  if [ "$RC" = "0" ]; then
    pass "literal Git word retains explicit fixture target"
  else
    fail "scoped literal Git rejected: '$GIT_WORD' rc=$RC out=$OUT"
  fi
done
for GIT_WORD in "'g\it'" '"g\it"' 'notgit' 'git-helper' '$GIT'; do
  run_on_fixture "tests/not-literal-git.sh" "$GIT_WORD config user.email leak@example.invalid
"
  if [ "$RC" = "0" ]; then
    pass "non-Git/unresolved executable token is not rewritten to Git"
  else
    fail "non-Git word overmatched: '$GIT_WORD' rc=$RC out=$OUT"
  fi
done

# Case 65o: quoted/escaped command separators before config are option data.
for VALUE in "'a;b'" '"a&b"' "'a|b'" 'a\;b' '"a ; b"'; do
  run_on_fixture "tests/quoted-option.sh" "git -c foo.bar=$VALUE config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then
    pass "quoted/escaped option separator keeps executable and config together"
  else
    fail "option separator hid writer: '$VALUE' rc=$RC out=$OUT"
  fi
  run_on_fixture "tests/targeted-quoted-option.sh" "git -c foo.bar=$VALUE -C \"\$FIXTURE\" config user.email fixture@example.invalid
"
  if [ "$RC" = "0" ]; then
    pass "quoted option separator retains explicit repository target"
  else
    fail "targeted option data rejected: '$VALUE' rc=$RC out=$OUT"
  fi
done
run_on_fixture "tests/quoted-neighbour.sh" "git -c foo.bar='a;b' -C \"\$FIXTURE\" config user.email fixture@example.invalid; g\\it config user.name leak
"
if [ "$RC" = "1" ]; then
  pass "real separator still isolates neighbouring targeted and unscoped commands"
else
  fail "real command boundary suppressed neighbour: rc=$RC out=$OUT"
fi
run_on_fixture "tests/quoted-continued.sh" "git -c foo.bar='a;b' \\
config user.email leak@example.invalid
"
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'tests/quoted-continued.sh:1:'; then
  pass "quoted option separator preserves continued-command finding"
else
  fail "continued quoted-option writer missed: rc=$RC out=$OUT"
fi
run_on_fixture "docs/quoted-spans.md" "Use \`git -c foo.bar='a;b' config --global user.email fixture@example.invalid\`, never \`git -c foo.bar='a;b' config user.email leak@example.invalid\`.
"
if [ "$RC" = "1" ]; then
  pass "quoted shell separators do not merge independent Markdown code spans"
else
  fail "Markdown spans merged through quoted option: rc=$RC out=$OUT"
fi

# Case 65r: scope/read spellings inside complete option-value words are
# data. Paired real options still exempt, including quoted option tokens.
for FLAG in --global --system --get --get-all --list --unset --unset-all --remove-section --rename-section; do
  for QUOTE in "'" '"'; do
    run_on_fixture "tests/quoted-flag-data.sh" "git -c foo.bar=${QUOTE}a; $FLAG b${QUOTE} config user.email leak@example.invalid
"
    if [ "$RC" = "1" ]; then
      pass "quoted option value containing $FLAG cannot supply scope/read exemption"
    else
      fail "quoted data became an option: flag='$FLAG' quote='$QUOTE' rc=$RC out=$OUT"
    fi
  done
  run_on_fixture "tests/real-flag.sh" "git -c foo.bar='a;b' config \"$FLAG\" user.email fixture@example.invalid
"
  if [ "$RC" = "0" ]; then
    pass "complete real scope/read option $FLAG retains exemption"
  else
    fail "real quoted option rejected: flag='$FLAG' rc=$RC out=$OUT"
  fi
done
for VALUE in "'a; git -C b'" "'a; git --global b'" "'a; config --get b'"; do
  run_on_fixture "tests/quoted-command-data.sh" "git -c foo.bar=$VALUE config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then
    pass "Git/config words inside quoted data cannot move the option-region start"
  else
    fail "quoted command data replaced real prefix: value='$VALUE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  "git --namespace '--global' config user.email leak@example.invalid" \
  "git --work-tree '--get' config user.email leak@example.invalid" \
  "git config --type '--global' user.email leak@example.invalid" \
  "git config set --comment '--get' user.email leak@example.invalid"; do
  run_on_fixture "tests/option-operand.sh" "$SOURCE
"
  if [ "$RC" = "1" ]; then
    pass "separate option operand cannot masquerade as scope/read flag"
  else
    fail "option operand supplied exemption: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture "tests/git-directory-operand.sh" 'git -C "git" config user.email fixture@example.invalid
'
if [ "$RC" = "0" ]; then
  pass "repository directory named Git does not replace the executable prefix"
else
  fail "Git-named target operand clipped actual -C option: rc=$RC out=$OUT"
fi
run_on_fixture "tests/options-ended.sh" 'git config -- "--global" user.email leak@example.invalid
'
if [ "$RC" = "1" ]; then
  pass "option terminator prevents later word from supplying a scope exemption"
else
  fail "option data after terminator exempted writer: rc=$RC out=$OUT"
fi

# Case 65s: prose punctuation cannot supply shell quote state before Git.
# Keep argument quotes and independent command/code-span boundaries intact.
for SOURCE in \
  "If you can't, run git config user.email leak@example.invalid" \
  'Use "git config user.email leak@example.invalid"' \
  "Use 'git config user.email leak@example.invalid'" \
  "If you can't, run g\\it config user.email leak@example.invalid" \
  "If you can't, run /usr/bin/git config user.email leak@example.invalid" \
  "If you can't, run \"git\" config user.email leak@example.invalid" \
  "Use \"git -c foo.bar='a; --global b' config user.email leak@example.invalid\"" \
  "Use 'git -c foo.bar=\"a; --get b\" config user.email leak@example.invalid'" \
  'Use "git -c foo.bar="a; --system b" config user.email leak@example.invalid"'; do
  run_on_fixture "docs/prose-command.md" "$SOURCE
"
  if [ "$RC" = "1" ]; then
    pass "Markdown prose punctuation cannot hide unscoped literal Git command"
  else
    fail "prose swallowed command: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/prose-exempt.md" "$SOURCE <!-- GIT_IDENTITY_SCOPE_EXEMPT: intentional documented fixture -->
"
  if [ "$RC" = "0" ]; then
    pass "true HTML exemption after prose command remains valid"
  else
    fail "true prose HTML exemption rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/prose-shell-exempt.md" "$SOURCE # GIT_IDENTITY_SCOPE_EXEMPT: intentional documented fixture
"
  if [ "$RC" = "0" ]; then
    pass "true shell exemption after prose command remains valid"
  else
    fail "true prose shell exemption rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  "If you can't, run git -c foo.bar=\"# GIT_IDENTITY_SCOPE_EXEMPT: string\" config user.email leak@example.invalid" \
  "If you can't, run git config user.email leak@example.invalid; echo \" # GIT_IDENTITY_SCOPE_EXEMPT: string\"" \
  "If you can't, run git config user.email leak@example.invalid \\# GIT_IDENTITY_SCOPE_EXEMPT: escaped" \
  'Use "git -c foo.bar=" # GIT_IDENTITY_SCOPE_EXEMPT: string" config user.email leak@example.invalid"'; do
  run_on_fixture "docs/prose-shell-impostor.md" "$SOURCE
"
  if [ "$RC" = "1" ]; then
    pass "prose command extraction preserves quoted/escaped marker data"
  else
    fail "prose marker data exempted writer: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  "If you can't, run git config --global user.email fixture@example.invalid" \
  'Use "git config --system user.email fixture@example.invalid"'; do
  run_on_fixture "docs/scoped-prose.md" "$SOURCE
"
  if [ "$RC" = "0" ]; then
    pass "real scope in prose-wrapped command remains valid"
  else
    fail "scoped prose command rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'Use "git config --global user.email fixture@example.invalid"; git config user.email leak@example.invalid' \
  "Use 'git config --system user.email fixture@example.invalid'; git config user.email leak@example.invalid" \
  "If you can't use --global, run git config user.email leak@example.invalid"; do
  run_on_fixture "docs/prose-neighbour.md" "$SOURCE
"
  if [ "$RC" = "1" ]; then
    pass "prose wrappers/preceding flags cannot scope neighbouring unscoped writer"
  else
    fail "prose neighbour supplied scope: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture "docs/prose-continued.md" "If you can't, run git \\
config user.email leak@example.invalid
"
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/prose-continued.md:1:'; then
  pass "prose quote handling preserves continued-command finding"
else
  fail "continued prose command missed: rc=$RC out=$OUT"
fi
for SOURCE in 'echo "git config user.email data@example.invalid"' 'echo "git config user.email data@example.invalid'; do
  run_on_fixture "tests/shell-quote-data.sh" "$SOURCE
"
  if [ "$RC" = "0" ]; then
    pass "shell quoted/open-quote data does not become a Git command"
  else
    fail "shell data treated as prose command: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/fenced-quote-data.md" '```bash
'"$SOURCE"'
```
'
  if [ "$RC" = "0" ]; then
    pass "fenced shell quote data retains shell-word rules"
  else
    fail "fenced data treated as prose command: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/span-quote-data.md" "Use \`$SOURCE\`.
"
  if [ "$RC" = "0" ]; then
    pass "code-span shell quote data retains shell-word rules"
  else
    fail "span data treated as prose command: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture "docs/span-quoted-option.md" "If you can't, use \`git -c foo.bar='a; --global b' config user.email leak@example.invalid\`.
"
if [ "$RC" = "1" ]; then
  pass "code-span command with quoted option data is still scanned independently"
else
  fail "quoted option data in span hid writer: rc=$RC out=$OUT"
fi

# Case 65s1: a literal colon may precede a complete prose Git instruction.
# Keep option operands, complete words, scopes, spans and genuine markers.
while IFS='|' read -r EXPECTED LABEL SOURCE; do
  run_on_fixture docs/colon-instruction.md "$SOURCE
"
  if [ "$RC" = "$EXPECTED" ] \
    && { [ "$EXPECTED" = 0 ] || [[ "$OUT" == *"docs/colon-instruction.md:1:"* ]]; }; then
    pass "literal-colon prose boundary: $LABEL"
  else
    fail "colon prose $LABEL: expected=$EXPECTED rc=$RC out=$OUT"
  fi
done <<'COLON_CASES'
1|compact label before literal writer|Run:git config user.email leak@example.com
1|compact label before path-qualified writer|Run:/usr/bin/git config user.email leak@example.com
1|paired command and argument quotes remain literal|Run:"git" "config" "user.email" "leak@example.com"
1|quoted colon and scope data cannot exempt outer writer|Run:git -c foo.bar="before;git --global" config user.email leak@example.com
1|adjacent code span remains independently scanned|Run:`git config user.email leak@example.com`
0|explicit fixture repository remains scoped|Run:git -C "$FIX" config user.email fixture@example.com
0|global identity instruction remains scoped|Run:git config --global user.email fixture@example.com
0|read remains a read|Run:git config --get user.email
0|genuine Markdown comment exemption remains valid|Run:git config user.email fixture@example.com <!-- GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture -->
0|quoted prefix operand cannot become another instruction|Run:git -c foo.bar="Run:git config user.email leak@example.com" status
0|unrelated executable suffix is not Git|Run:mygit config user.email leak@example.com
0|unprotected complete key remains allowed|Run:git config notuser.email leak@example.com
COLON_CASES

# Case 65t: a standalone Git mention cannot anchor a later prose command.
for PREFIX in \
  "Use git if you can't, then " \
  "Use git status if you can't, then " \
  "Use git -c foo.bar='config --global' status if you can't, then " \
  "Use git -c foo.bar='git config --global x' status if you can't, then "; do
  run_on_fixture "docs/earlier-git.md" "${PREFIX}git config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then pass "earlier Git mention cannot hide actual prose config writer"; else
    fail "earlier Git anchored writer: prefix='$PREFIX' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/earlier-git-scoped.md" "${PREFIX}git config --global user.email fixture@example.invalid
"
  if [ "$RC" = "0" ]; then pass "actual scope survives earlier Git mention"; else
    fail "actual prose scope rejected: prefix='$PREFIX' rc=$RC out=$OUT"
  fi
  for MARKER in '<!-- GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture -->' '# GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture'; do
    run_on_fixture "docs/earlier-git-exempt.md" "${PREFIX}git config user.email fixture@example.invalid $MARKER
"
    if [ "$RC" = "0" ]; then pass "real exemption survives earlier Git mention"; else
      fail "actual prose exemption rejected: prefix='$PREFIX' marker='$MARKER' rc=$RC out=$OUT"
    fi
  done
done
for SPAN in '`' '``'; do
  SOURCE="If you can't, run ${SPAN}git config user.email fixture@example.invalid${SPAN}"
  for TAIL in '# GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture' 'echo "ordinary data";# GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture' '# GIT_IDENTITY_SCOPE_EXEMPT: fixture `reason`'; do
    run_on_fixture "docs/span-trailing-marker.md" "$SOURCE $TAIL
"
    if [ "$RC" = "0" ]; then pass "real trailing shell exemption after code span resets prose quote state"; else
      fail "trailing span comment rejected: span='$SPAN' tail='$TAIL' rc=$RC out=$OUT"
    fi
  done
  for TAIL in 'echo " # GIT_IDENTITY_SCOPE_EXEMPT: string"' '\# GIT_IDENTITY_SCOPE_EXEMPT: escaped' '" # GIT_IDENTITY_SCOPE_EXEMPT: open string' 'echo "data `literal` # GIT_IDENTITY_SCOPE_EXEMPT: string"'; do
    run_on_fixture "docs/span-trailing-impostor.md" "$SOURCE $TAIL
"
    if [ "$RC" = "1" ]; then pass "quoted/escaped trailing markers after code spans cannot exempt"; else
      fail "trailing span data exempted writer: span='$SPAN' tail='$TAIL' rc=$RC out=$OUT"
    fi
  done
  run_on_fixture "docs/span-cited-marker.md" "If you can't, run ${SPAN}git config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: citation${SPAN}
"
  if [ "$RC" = "1" ]; then pass "marker inside code span remains a citation after prose apostrophe"; else
    fail "cited span marker exempted writer: span='$SPAN' rc=$RC out=$OUT"
  fi
  for QUOTE in '"' "'"; do
    run_on_fixture "docs/span-wrapper-marker.md" "Use ${QUOTE}${SPAN}git config user.email fixture@example.invalid${SPAN} # GIT_IDENTITY_SCOPE_EXEMPT: string${QUOTE}
"
    if [ "$RC" = "1" ]; then pass "quote wrapping code span protects literal marker data"; else
      fail "wrapped span marker exempted writer: span='$SPAN' quote='$QUOTE' rc=$RC out=$OUT"
    fi
    run_on_fixture "docs/span-wrapper-real-marker.md" "Use ${QUOTE}${SPAN}git config user.email fixture@example.invalid${SPAN}${QUOTE} # GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture
"
    if [ "$RC" = "0" ]; then pass "real shell comment after closed span wrapper remains valid"; else
      fail "real comment after span wrapper rejected: span='$SPAN' quote='$QUOTE' rc=$RC out=$OUT"
    fi
  done
done

# Case 65u: literal targets, opaque substitution operands and complete
# Markdown delimiters retain the same instruction/exemption boundaries.
for OPENER in '<!-->' '<!--->'; do
  run_on_fixture "docs/short-html-marker.md" "git config user.email leak@example.invalid $OPENER GIT_IDENTITY_SCOPE_EXEMPT: literal -->
"
  if [ "$RC" = "1" ]; then pass "marker after complete empty HTML comment remains ordinary text"; else
    fail "short HTML opener borrowed later closer: opener='$OPENER' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/short-html-real.md" "git config user.email fixture@example.invalid $OPENER <!-- GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture -->
"
  if [ "$RC" = "0" ]; then pass "real comment after complete empty HTML comment remains valid"; else
    fail "real comment after short HTML rejected: opener='$OPENER' rc=$RC out=$OUT"
  fi
done
for EMPTY in "''" '""' "''\"\""; do
  run_on_fixture "tests/empty-C.sh" "git -C $EMPTY config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then pass "literal empty -C path cannot supply a repository target"; else
    fail "empty C supplied target: operand='$EMPTY' rc=$RC out=$OUT"
  fi
  for SOURCE in \
    "git -C $EMPTY config --global user.email fixture@example.invalid" \
    "git -C $EMPTY -C \"\$FIX\" config user.email fixture@example.invalid" \
    "git -C \"\$FIX\" -C $EMPTY config user.email fixture@example.invalid" \
    "git -C $EMPTY config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture"; do
    run_on_fixture "tests/empty-C-independent-scope.sh" "$SOURCE
"
    if [ "$RC" = "0" ]; then pass "independent real scope/target/comment remains valid with empty -C"; else
      fail "empty C hid independent scope: source='$SOURCE' rc=$RC out=$OUT"
    fi
  done
done
run_on_fixture "tests/named-C.sh" 'git -C . config user.email fixture@example.invalid
'
if [ "$RC" = "0" ]; then pass "named target remains shape-based without filesystem resolution"; else
  fail "named target was resolved or rejected: rc=$RC out=$OUT"
fi
for OPERAND in \
  '$(printf a; printf b)' \
  '$(printf "%s" "$(printf "a;b")")' \
  '$(printf "%s" ")a;b(")' \
  '$(printf --global)' \
  '$(printf "%s" "# GIT_IDENTITY_SCOPE_EXEMPT: string")'; do
  run_on_fixture "tests/substitution-outer.sh" "git -c foo.bar=$OPERAND config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then pass "substitution operand cannot split or exempt literal outer identity command"; else
    fail "substitution hid literal outer command: operand='$OPERAND' rc=$RC out=$OUT"
  fi
  run_on_fixture "tests/substitution-targeted.sh" "git -C \"\$FIX\" -c foo.bar=$OPERAND config user.email fixture@example.invalid
"
  if [ "$RC" = "0" ]; then pass "real target remains valid beside opaque substitution operand"; else
    fail "substitution rejected real target: operand='$OPERAND' rc=$RC out=$OUT"
  fi
done
run_on_fixture "tests/substitution-neighbour.sh" 'git -c foo.bar=$(printf a; printf b) config --global user.email fixture@example.invalid;git config user.email leak@example.invalid
'
if [ "$RC" = "1" ]; then pass "real outer separator remains independent after substitution"; else
  fail "substitution swallowed outer separator: rc=$RC out=$OUT"
fi
run_on_fixture "tests/substitution-real-comment.sh" 'git -c foo.bar=$(printf a; printf b) config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture
'
if [ "$RC" = "0" ]; then pass "real outer shell comment remains valid after opaque substitution"; else
  fail "substitution swallowed real outer comment: rc=$RC out=$OUT"
fi
for SOURCE in \
  'echo "$(printf "git config user.email data@example.invalid")"' \
  "echo '\$(git config user.email data@example.invalid)'" \
  'echo "\$(git config user.email data@example.invalid)"' \
  '$(printf git) config user.email data@example.invalid' \
  'git config $(printf user.email) data@example.invalid'; do
  run_on_fixture "tests/substitution-no-evaluation.sh" "$SOURCE
"
  if [ "$RC" = "0" ]; then pass "substitution output does not derive executable/key or turn printed data into instruction"; else
    fail "substitution output was interpreted: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'echo $(git config user.email fixture@example.invalid)' \
  'echo "$(git config user.email fixture@example.invalid)"' \
  'echo $(git config user.email fixture@example.invalid'; do
  run_on_fixture "tests/substitution-literal-body.sh" "$SOURCE
"
  if [ "$RC" = "1" ]; then pass "direct literal body writer retains detection with contained/unknown extent"; else
    fail "opaque output erased direct body instruction: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture "tests/substitution-targeted-body.sh" 'echo $(git -C "$FIX" config user.email fixture@example.invalid)
'
if [ "$RC" = "0" ]; then pass "literal fixture target remains valid inside contained source body"; else
  fail "body instruction lost real target: rc=$RC out=$OUT"
fi
for SPAN_PREFIX in '``literal ` tick``' '```literal ` tick `` data```'; do
  run_on_fixture "docs/equal-width-prose.md" "Use $SPAN_PREFIX. If you can't, run git config user.email leak@example.invalid
"
  if [ "$RC" = "1" ]; then pass "unequal inner backtick runs cannot shift following prose into shell quoting"; else
    fail "unequal span run hid prose writer: prefix='$SPAN_PREFIX' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/equal-width-scoped.md" "Use $SPAN_PREFIX. If you can't, run git config --global user.email fixture@example.invalid
"
  if [ "$RC" = "0" ]; then pass "real scope survives equal-width span partition"; else
    fail "equal-width partition rejected scope: rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/equal-width-cited-marker.md" "git config user.email leak@example.invalid $SPAN_PREFIX
"
  if [ "$RC" = "1" ]; then pass "closed span data cannot hide preceding literal writer"; else
    fail "closed span data hid writer: rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'git config user.email leak@example.invalid ``literal ` # GIT_IDENTITY_SCOPE_EXEMPT: citation``' \
  'git config user.email leak@example.invalid ```literal ` # GIT_IDENTITY_SCOPE_EXEMPT: citation `` data```'; do
  run_on_fixture "docs/equal-width-marker.md" "$SOURCE
"
  if [ "$RC" = "1" ]; then pass "marker inside equal-width span with shorter runs remains cited data"; else
    fail "inner backtick spilled literal marker: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/equal-width-real-marker.md" "$SOURCE <!-- GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture -->
"
  if [ "$RC" = "0" ]; then pass "real comment after equal-width cited-marker span remains valid"; else
    fail "real equal-width comment rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done

# Case 65x: complete literal config words and effective known selectors.
for CONFIG_WORD in 'c\onfig' 'con"fig"' "'config'"; do
  for REL in tests/literal-config.sh docs/literal-config.md; do
    run_on_fixture "$REL" "git $CONFIG_WORD user.email leak@example.invalid
"
    if [ "$RC" = 1 ]; then pass "ordinary quoted/escaped config subcommand remains an instruction"; else
      fail "literal config hidden: word='$CONFIG_WORD' rel=$REL rc=$RC out=$OUT"
    fi
    run_on_fixture "$REL" "git -C \"\$FIX\" $CONFIG_WORD user.email fixture@example.invalid
"
    if [ "$RC" = 0 ]; then pass "quoted config retains real fixture target"; else
      fail "quoted config target rejected: rc=$RC out=$OUT"
    fi
  done
  run_on_fixture docs/literal-config-prose.md "If you can't, run git $CONFIG_WORD user.email leak@example.invalid
"
  if [ "$RC" = 1 ]; then pass "literal config normalization survives prose punctuation"; else
    fail "quoted config prose hidden: rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'git -c foo.bar="config --global" config user.email leak@example.invalid' \
  'git -c foo.bar="--no-global" config --global --no-global user.email leak@example.invalid' \
  'git config --global --no-global user.email leak@example.invalid' \
  'git config --gl --no-global user.email leak@example.invalid' \
  'git config --system --no-system user.email leak@example.invalid' \
  'git config --file "$FIX/config" --no-file user.email leak@example.invalid' \
  'git config --blob HEAD:config --no-blob user.email leak@example.invalid' \
  'git config --get --no-get user.email leak@example.invalid' \
  'git config --get-all --no-get-all user.email leak@example.invalid' \
  'git config --unset --no-unset user.email leak@example.invalid'; do
  run_on_fixture tests/cancelled-selector.sh "$SOURCE
"
  if [ "$RC" = 1 ]; then pass "cancelled known scope/read selector cannot clear literal writer"; else
    fail "cancelled selector cleared writer: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture tests/cancelled-selector-marker.sh "$SOURCE # GIT_IDENTITY_SCOPE_EXEMPT: intentional isolated fixture
"
  if [ "$RC" = 0 ]; then pass "cancelled selector retains genuine explicit exemption"; else
    fail "cancelled selector marker rejected: rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'git config --global --no-global --global user.email fixture@example.invalid' \
  'git config --system --no-system --sy user.email fixture@example.invalid' \
  'git config --get --no-get --get user.email fixture@example.invalid' \
  'git -C "$FIX" config --global --no-global user.email fixture@example.invalid' \
  'git config --global --no-global --file "$FIX/config" user.email fixture@example.invalid' \
  'git config --default "--no-get" --get user.email fixture@example.invalid' \
  'git -c foo.bar="--no-global" config --global user.email fixture@example.invalid' \
  'git -C "config" status user.email fixture@example.invalid' \
  'git status "config" user.email fixture@example.invalid'; do
  run_on_fixture tests/retained-selector.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "real final/independent safety mode survives; config operands stay data"; else
    fail "retained selector/data rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done

# Case 65y: only an open ordinary substitution gains physical continuation.
for SOURCE in \
  $'git -c foo.bar=$(printf a\nprintf b) config user.email leak@example.invalid' \
  $'git -c foo.bar="$(printf a\nprintf b)" config user.email leak@example.invalid' \
  $'git -c foo.bar=$(printf "$(printf a\nprintf b)") config user.email leak@example.invalid' \
  $'echo $(printf a\ngit config user.email leak@example.invalid\n)' \
  $'echo $(printf a\ngit config user.email leak@example.invalid'; do
  run_on_fixture tests/multiline-substitution.sh "$SOURCE
"
  if [ "$RC" = 1 ]; then pass "multiline ordinary substitution preserves literal outer/body writer"; else
    fail "multiline substitution writer hidden: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  $'git -C "$FIX" -c foo.bar=$(printf a\nprintf b) config user.email fixture@example.invalid' \
  $'git -c foo.bar=$(printf a\nprintf b) config --global user.email fixture@example.invalid' \
  $'git -c foo.bar=$(printf a\nprintf b) config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture' \
  $'echo $(printf a\ngit -C "$FIX" config user.email fixture@example.invalid\n)' \
  $'echo $(printf a\nprintf "git config user.email fixture@example.invalid"\n)' \
  $'git -c foo.bar=$(printf a\nprintf b) config $(printf user.email) fixture@example.invalid'; do
  run_on_fixture tests/multiline-substitution-control.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "multiline literal target/marker/data boundaries retained without evaluation"; else
    fail "multiline control rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for PREFIX in "printf '%s' '\$(printf a'" 'printf "%s" \$(printf a' '# $(printf a'; do
  run_on_fixture tests/literal-dollar-lines.sh "$PREFIX
git config --global user.email fixture@example.invalid
git config user.email leak@example.invalid
"
  if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'literal-dollar-lines.sh:3'; then
    pass "quoted/escaped/comment dollar does not absorb following physical writer"
  else
    fail "literal dollar joined unrelated commands: prefix='$PREFIX' rc=$RC out=$OUT"
  fi
done
# EOF must not join a substitution to another tracked source file.
MULTIFILE="$WORKDIR/multiline-substitution-files"
mkdir -p "$MULTIFILE"
printf 'git -c foo.bar=$(printf a\n' > "$MULTIFILE/a.sh"
printf 'printf b) config user.email fixture@example.invalid\n' > "$MULTIFILE/b.sh"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$MULTIFILE" bash "$CHECK" 2>&1)"; RC=$?
set -e
if [ "$RC" = 0 ]; then pass "open substitution buffer resets at file boundary"; else
  fail "substitution crossed source files: rc=$RC out=$OUT"
fi

# Independent review controls: comment data cannot close a substitution,
# and an actual body newline separates a plain read from the next command.
for SOURCE in \
  $'git -c foo.bar=$(\nprintf a # )\nprintf b\n) config user.email leak@example.invalid' \
  $'git -c foo.bar=$(\nprintf "# )"\nprintf b\n) config user.email leak@example.invalid' \
  $'git -c foo.bar=$(\nprintf a \\#\n) config user.email leak@example.invalid' \
  $'git -c foo.bar=$(\nprintf a#data\n) config user.email leak@example.invalid' \
  $'value=$(git config user.email fixture@example.invalid\nprintf "%s" "$suffix")'; do
  run_on_fixture tests/substitution-comment-and-body.sh "$SOURCE
"
  if [ "$RC" = 1 ]; then pass "comment/hash data and genuine closer retain actual literal writer"; else
    fail "substitution extent/body writer hidden: source='$SOURCE' rc=$RC out=$OUT"
  fi
  run_on_fixture tests/substitution-comment-marker.sh "$SOURCE # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture
"
  if [[ "$SOURCE" == value=* ]]; then
    if [ "$RC" = 1 ]; then pass "later marker cannot exempt an independently offending body physical line"; else
      fail "later marker widened physical exemption: rc=$RC out=$OUT"
    fi
  elif [ "$RC" = 0 ]; then pass "genuine trailing exemption survives comment/body newline handling"; else
    fail "substitution trailing exemption rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  $'git -C "$FIX" -c foo.bar=$(\nprintf a # )\nprintf b\n) config user.email fixture@example.invalid' \
  $'value=$(git config user.email\nprintf "%s" "$suffix")' \
  $'value="$(git config user.email\nprintf "%s" "$suffix")"' \
  $'value=$(git config user.email\nprintf "%s" "git config user.email fixture@example.invalid")' \
  $'value=$(git config user.email\ngit -C "$FIX" config user.email fixture@example.invalid)'; do
  run_on_fixture tests/substitution-newline-read.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "unquoted body newline keeps a plain read distinct from later command/data"; else
    fail "body newline read became assignment: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture tests/substitution-newline-neighbour.sh $'value=$(git config user.email\nprintf "%s" "$suffix"); git config user.email leak@example.invalid\n'
if [ "$RC" = 1 ]; then pass "body read cannot suppress a following outer identity writer"; else
  fail "body newline read hid neighbouring writer: rc=$RC out=$OUT"
fi

run_on_fixture tests/substitution-body-line-marker.sh $'value=$(git config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture\nprintf "%s" "$suffix")\n'
if [ "$RC" = 0 ]; then pass "actual marker on body writer physical line retains explicit exemption"; else
  fail "body physical-line marker rejected: rc=$RC out=$OUT"
fi
run_on_fixture tests/substitution-body-neighbour-marker.sh $'value=$(git config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture\ngit config user.name leak\n)\n'
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'substitution-body-neighbour-marker.sh:2'; then
  pass "body physical-line marker cannot exempt a second independent body writer"
else
  fail "body marker widened to later writer: rc=$RC out=$OUT"
fi

# Comment prose in a contained body cannot quote a later continued writer.
for NOTE in "# someone's note" '# plain note' '# ) ; $( data'; do
  run_on_fixture tests/body-comment-state.sh "value=\$(
git config --get user.email $NOTE
git \\
config user.name leak
)
"
  if [ "$RC" = 1 ]; then pass "body comment punctuation cannot hide following continued writer"; else
    fail "body comment changed command state: note='$NOTE' rc=$RC out=$OUT"
  fi
  run_on_fixture tests/body-comment-scope.sh "value=\$(
git config --get user.email $NOTE
git -C \"\$FIX\" \\
config user.name fixture
)
"
  if [ "$RC" = 0 ]; then pass "comment punctuation preserves following real fixture target"; else
    fail "body comment scoped control rejected: note='$NOTE' rc=$RC out=$OUT"
  fi
done
run_on_fixture tests/body-comment-actual-marker.sh $'value=$(\ngit config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: someone\'s isolated fixture\ngit config --get user.email\n)\n'
if [ "$RC" = 0 ]; then pass "original body comment bytes retain genuine exemption with apostrophe reason"; else
  fail "body comment marker lost: rc=$RC out=$OUT"
fi
run_on_fixture tests/body-comment-marker-neighbour.sh $'value=$(\ngit config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: someone\'s isolated fixture\ngit \\\nconfig user.name leak\n)\n'
if [ "$RC" = 1 ]; then pass "body comment exemption does not widen to continued unmarked neighbour"; else
  fail "body comment marker swallowed neighbour: rc=$RC out=$OUT"
fi
run_on_fixture tests/body-comment-quoted-data.sh $'value=$(\ngit -c foo.bar="# someone\'s note" \\\nconfig user.email leak@example.invalid\n)\n'
if [ "$RC" = 1 ]; then pass "quoted hash/apostrophe stays option data and cannot exempt a writer"; else
  fail "quoted comment data changed writer: rc=$RC out=$OUT"
fi
run_on_fixture tests/body-comment-printed-data.sh $'value=$(\nprintf "%s" "# someone\'s git config user.email fixture@example.invalid"\n)\n'
if [ "$RC" = 0 ]; then pass "quoted printed comment/command data does not become an instruction"; else
  fail "printed comment data became instruction: rc=$RC out=$OUT"
fi

# Case 65y1: literal env split-string admission reuses known interpreters.
# Source is scan-only; neither a shebang nor its dynamic operands executes.
# Keep a real index, the authentic paired suite and consumer marker gate.
ENV_CONSUMER="$WORKDIR/consumer-env-split"
mkdir -p "$ENV_CONSUMER/scripts/ci" "$ENV_CONSUMER/tests"
git init -q -b main "$ENV_CONSUMER"
cp "$CHECK" "$ENV_CONSUMER/scripts/ci/check_git_identity_hygiene"
cp "$ROOT/tests/test_git_identity_hygiene.sh" "$ENV_CONSUMER/tests/"
cp "$ENV_CONSUMER/.git/config" "$WORKDIR/env-config-before"
while IFS='|' read -r EXPECTED SHEBANG BODY; do
  printf '%s\n%s\n' "$SHEBANG" "$BODY" > "$ENV_CONSUMER/tool"
  git -C "$ENV_CONSUMER" add -A
  set +e
  OUT="$(bash "$ENV_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = "$EXPECTED" ] \
    && { [ "$EXPECTED" = 0 ] || [[ "$OUT" == *"tool:2:"* ]]; } \
    && { [ "$EXPECTED" = 1 ] || [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]]; } \
    && cmp -s "$WORKDIR/env-config-before" "$ENV_CONSUMER/.git/config"; then
    pass "literal env split-string admission: $SHEBANG"
  else
    fail "env admission $SHEBANG: expected=$EXPECTED rc=$RC out=$OUT"
  fi
  [ "$EXPECTED" = 1 ] || continue
  for SAFE_BODY in \
    'git -C "$FIX" config user.email fixture@example.com' \
    'git config --get user.email' \
    'git config user.email fixture@example.com # GIT_IDENTITY_SCOPE_EXEMPT: intentional fixture'; do
    printf '%s\n%s\n' "$SHEBANG" "$SAFE_BODY" > "$ENV_CONSUMER/tool"
    git -C "$ENV_CONSUMER" add -A
    set +e
    OUT="$(bash "$ENV_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
    set -e
    if [ "$RC" = 0 ] \
      && [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]] \
      && cmp -s "$WORKDIR/env-config-before" "$ENV_CONSUMER/.git/config"; then
      pass "literal env split-string preserves scope/read/exemption: $SHEBANG"
    else
      fail "env safe body rejected: shebang='$SHEBANG' source='$SAFE_BODY' rc=$RC out=$OUT"
    fi
  done
done <<'ENV_SPLIT_CASES'
1|#!/usr/bin/env -Sbash|git config user.email leak@example.com
1|#!/usr/bin/env --split-string=bash|git config user.email leak@example.com
1|#!/usr/bin/env -Ssh|git config user.name leak
1|#!/usr/bin/env --split-string=mksh|git config commit.gpgsign false
1|#!/usr/bin/env -Sbats|git config tag.gpgsign false
1|#!/usr/bin/env -S bash|git config user.signingkey key
0|#!/usr/bin/env -Sbashman|git config user.email leak@example.com
0|#!/usr/bin/env --split-string=bashman|git config user.email leak@example.com
0|#!/usr/bin/env -S${SHELL}|git config user.email leak@example.com
0|#!/usr/bin/env --split-string=${SHELL}|git config user.email leak@example.com
0|#!/usr/bin/env -Spython|git config user.email leak@example.com
0|#!/usr/bin/notenv -Sbash|git config user.email leak@example.com
ENV_SPLIT_CASES

# Case 65z: owner-ratified Bats admission is bounded to .bats/env-bats.
for REL in tests/setup.bats tests/setup.BATS tests/setup; do
  run_on_fixture "$REL" $'#!/usr/bin/env bats\n@test "fixture" {\n  git config user.email leak@example.invalid\n}\n'
  if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "$REL:3"; then pass "Bats extension/shebang admits literal fixture setup"; else
    fail "Bats source skipped: rel=$REL rc=$RC out=$OUT"
  fi
  run_on_fixture "$REL" $'#!/usr/bin/env bats\n@test "fixture" {\n  git -C "$FIX" config user.email fixture@example.invalid\n  git config user.name fixture # GIT_IDENTITY_SCOPE_EXEMPT: intentional isolated fixture\n}\n'
  if [ "$RC" = 0 ]; then pass "Bats setup retains explicit fixture target and genuine exemption"; else
    fail "Bats legitimate setup rejected: rc=$RC out=$OUT"
  fi
done
run_on_fixture tests/setup.bats $'@test "fixture" {\n  git config user.email leak@example.invalid\n}\n'
if [ "$RC" = 1 ]; then pass "Bats extension works independently of shebang"; else
  fail "extension-only Bats skipped: rc=$RC out=$OUT"
fi
run_on_fixture tests/other $'#!/usr/bin/env batsman\ngit config user.email fixture@example.invalid\n'
if [ "$RC" = 0 ]; then pass "Bats admission does not match arbitrary interpreter suffixes"; else
  fail "Bats interpreter matcher broadened: rc=$RC out=$OUT"
fi

# Case 65aa: a shell-file marker belongs to its terminating command.
for SEP in ';' '&&' '||' '&' '|'; do
  for LAST in 'echo ok' 'git config --get user.email' 'git -C "$FIX" config user.name fixture'; do
    run_on_fixture tests/command-marker-neighbour.sh "git config user.email leak@example.invalid $SEP $LAST # GIT_IDENTITY_SCOPE_EXEMPT: last command only
"
    if [ "$RC" = 1 ]; then pass "later harmless/read/targeted command marker cannot exempt earlier writer"; else
      fail "later marker widened exemption: sep='$SEP' last='$LAST' rc=$RC out=$OUT"
    fi
  done
  run_on_fixture tests/command-marker-last-writer.sh "git config --get user.email $SEP git config user.name fixture # GIT_IDENTITY_SCOPE_EXEMPT: last fixture writer
"
  if [ "$RC" = 0 ]; then pass "genuine marker on last writer does not turn preceding read into a finding"; else
    fail "last writer genuine marker rejected: sep='$SEP' rc=$RC out=$OUT"
  fi
  run_on_fixture tests/command-marker-two-writers.sh "git config user.email leak@example.invalid $SEP git config user.name fixture # GIT_IDENTITY_SCOPE_EXEMPT: last fixture writer
"
  if [ "$RC" = 1 ]; then pass "exempt last writer cannot clear independent earlier writer"; else
    fail "last exempt writer cleared earlier writer: sep='$SEP' rc=$RC out=$OUT"
  fi
  run_on_fixture tests/command-marker-terminal.sh "git config user.email fixture@example.invalid$SEP# GIT_IDENTITY_SCOPE_EXEMPT: terminal operator
"
  if [ "$RC" = 0 ]; then pass "terminal operator without intervening command preserves true exemption"; else
    fail "terminal operator marker rejected: sep='$SEP' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  $'git \\\nconfig user.email leak@example.invalid; echo ok # GIT_IDENTITY_SCOPE_EXEMPT: echo only' \
  $'value=$(\ngit \\\nconfig user.email leak@example.invalid; echo ok # GIT_IDENTITY_SCOPE_EXEMPT: echo only\n)' \
  'git config user.email "fixture # GIT_IDENTITY_SCOPE_EXEMPT: quoted data"' \
  'git config user.email leak@example.invalid; echo "# GIT_IDENTITY_SCOPE_EXEMPT: quoted data"' \
  'git config user.email leak@example.invalid; echo \# GIT_IDENTITY_SCOPE_EXEMPT: escaped data'; do
  run_on_fixture tests/command-marker-continued-data.sh "$SOURCE
"
  if [ "$RC" = 1 ]; then pass "continued/multiline writer and quoted/escaped marker data remain findings"; else
    fail "command marker continuation/data cleared writer: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  $'echo prep; git \\\nconfig user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: fixture writer' \
  $'value=$(\ngit \\\nconfig user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: fixture writer\n)' \
  $'value=$(git config user.email fixture@example.invalid;# GIT_IDENTITY_SCOPE_EXEMPT: fixture writer\n)' \
  'git config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: reason with ; quoted data'; do
  run_on_fixture tests/command-marker-continued-real.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "genuine shell marker retains owning continued/body writer and comment reason"; else
    fail "owning command marker rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/markdown-physical-marker.md 'Use `git config user.email fixture@example.invalid`; echo ok # GIT_IDENTITY_SCOPE_EXEMPT: intentional physical-line examples
'
if [ "$RC" = 0 ]; then pass "Markdown deliberately retains existing physical-line marker scope"; else
  fail "shell command marker binding changed Markdown exemption contract: rc=$RC out=$OUT"
fi

# Findings in opaque operands stay pending until the owning command ends:
# its real marker still applies, while a later command cannot supply one.
for SOURCE in \
  'echo $(git config user.email fixture@example.invalid) # GIT_IDENTITY_SCOPE_EXEMPT: intentional owning fixture command' \
  'value=$(git config user.email fixture@example.invalid) # GIT_IDENTITY_SCOPE_EXEMPT: intentional owning fixture command' \
  'git config --get user.email; echo $(git config user.email fixture@example.invalid) # GIT_IDENTITY_SCOPE_EXEMPT: intentional owning fixture command' \
  $'echo $(git \\\nconfig user.email fixture@example.invalid) # GIT_IDENTITY_SCOPE_EXEMPT: intentional owning fixture command'; do
  run_on_fixture tests/owning-substitution-marker.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "real owning-command marker retains direct contained fixture exemption"; else
    fail "owning substitution marker rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'echo $(git config user.email leak@example.invalid); echo ok # GIT_IDENTITY_SCOPE_EXEMPT: harmless echo' \
  'git config user.email leak@example.invalid; echo $(git config user.email fixture@example.invalid) # GIT_IDENTITY_SCOPE_EXEMPT: last owning command' \
  $'echo $(git \\\nconfig user.email leak@example.invalid); echo ok # GIT_IDENTITY_SCOPE_EXEMPT: harmless echo'; do
  run_on_fixture tests/later-substitution-marker.sh "$SOURCE
"
  if [ "$RC" = 1 ]; then pass "owning-command marker cannot exempt prior independent outer/substitution writer"; else
    fail "later substitution marker widened: source='$SOURCE' rc=$RC out=$OUT"
  fi
done

# Case 65aa1: equal-width spans retain marker-data context across physical
# lines only inside the existing inline block. An unmatched opener is text.
for SPAN in '`' '``' '```'; do
  run_on_fixture docs/crossline-marker.md "Paragraph ${SPAN}marker citation
<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->${SPAN} then \`git config user.email fixture@example.invalid\`
"
  if [ "$RC" = 1 ] && [[ "$OUT" == *"docs/crossline-marker.md:2:"* ]]; then
    pass "crossline equal-width span cannot supply an HTML exemption"
  else fail "crossline span cleared writer: span='$SPAN' rc=$RC out=$OUT"; fi
  run_on_fixture docs/sameline-marker.md "Paragraph ${SPAN}<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->${SPAN} then \`git config user.email fixture@example.invalid\`
"
  if [ "$RC" = 1 ]; then pass "same-line cited marker remains data"; else
    fail "same-line span cleared writer: span='$SPAN' rc=$RC out=$OUT"
  fi
  run_on_fixture docs/crossline-real-marker.md "Paragraph ${SPAN}marker citation
<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->${SPAN} then \`git config user.email fixture@example.invalid\` <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine outside comment -->
"
  if [ "$RC" = 0 ]; then pass "genuine physical-line comment after closed crossline span exempts"; else
    fail "genuine outside marker rejected: span='$SPAN' rc=$RC out=$OUT"
  fi
  run_on_fixture docs/unmatched-marker.md "Paragraph ${SPAN}unmatched opener
Use git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine outside comment -->
"
  if [ "$RC" = 0 ]; then pass "unmatched backtick opener cannot hide a genuine comment"; else
    fail "unmatched opener consumed marker: span='$SPAN' rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/unequal-marker.md $'Paragraph ``unclosed wider opener\nUse git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine comment -->`\n'
if [ "$RC" = 0 ]; then pass "unequal delimiter runs do not close a span or hide genuine comment"; else
  fail "unequal opener consumed genuine marker: rc=$RC out=$OUT"
fi
run_on_fixture docs/shorter-inner-run.md $'Paragraph ``marker citation with `shorter run\n<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->`` then `git config user.email fixture@example.invalid`\n'
if [ "$RC" = 1 ]; then pass "shorter inner delimiter stays data in a crossline equal-width span"; else
  fail "shorter inner run cleared writer: rc=$RC out=$OUT"
fi
for BOUNDARY in '' '# Heading' '---' '===' '```bash
```' '> New container' '- New item'; do
  run_on_fixture docs/span-boundary.md "Paragraph \`unmatched opener
$BOUNDARY
Use git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine comment -->\`
"
  if [ "$RC" = 0 ]; then pass "inline span cannot cross existing block boundary"; else
    fail "span crossed block boundary: boundary='$BOUNDARY' rc=$RC out=$OUT"
  fi
done
for PREFIX in '> ' '- ' '> - '; do
  case "$PREFIX" in
    '> ') CONTINUATION='> ' ;;
    '- ') CONTINUATION='  ' ;;
    '> - ') CONTINUATION='>   ' ;;
  esac
  run_on_fixture docs/span-container.md "${PREFIX}Paragraph \`marker citation
${CONTINUATION}<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->\` then \`git config user.email fixture@example.invalid\`
"
  if [ "$RC" = 1 ]; then pass "crossline span remains inside retained quote/list container"; else
    fail "container span cleared writer: prefix='$PREFIX' rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/span-physical-scope.md $'Paragraph `citation\nclosed` then `git config user.email fixture@example.invalid` <!-- GIT_IDENTITY_SCOPE_EXEMPT: this physical line -->\nUse git config user.name fixture\n'
if [ "$RC" = 1 ] && [[ "$OUT" == *"docs/span-physical-scope.md:3:"* ]] \
  && [[ "$OUT" != *"  - docs/span-physical-scope.md:2:"* ]]; then
  pass "crossline span preserves exact physical-line exemption scope"
else fail "crossline marker widened line scope: rc=$RC out=$OUT"; fi

run_on_fixture docs/fenced-logical-span.md $'```bash\n`git \\\nconfig user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: cited inside logical backticks`\n```\n'
if [ "$RC" = 1 ]; then pass "fenced logical command retains original paired-backtick exemption cut"; else
  fail "fenced logical span gained an exemption: rc=$RC out=$OUT"
fi

# Independently exercise tracked-index enumeration and the authentic
# consumer suite skip, without either a fixture-root or suite override.
SPAN_CONSUMER="$WORKDIR/consumer-crossline-spans"
mkdir -p "$SPAN_CONSUMER/scripts/ci" "$SPAN_CONSUMER/tests"
git init -q -b main "$SPAN_CONSUMER"
cp "$CHECK" "$SPAN_CONSUMER/scripts/ci/check_git_identity_hygiene"
cp "$ROOT/tests/test_git_identity_hygiene.sh" "$SPAN_CONSUMER/tests/"
cp "$SPAN_CONSUMER/.git/config" "$WORKDIR/span-config-before"
for CONTROL in crossline same-line genuine-comment; do
  case "$CONTROL" in
    crossline) SOURCE=$'Paragraph `citation\n<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->` then `git config user.email fixture@example.invalid`\n'; EXPECTED=1; HIT_LINE=2 ;;
    same-line) SOURCE=$'Paragraph `<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited data -->` then `git config user.email fixture@example.invalid`\n'; EXPECTED=1; HIT_LINE=1 ;;
    genuine-comment) SOURCE=$'Paragraph `citation\nclosed` then `git config user.email fixture@example.invalid` <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine outside comment -->\n'; EXPECTED=0 ;;
  esac
  printf '%s' "$SOURCE" > "$SPAN_CONSUMER/REVIEW_POLICY.md"
  git -C "$SPAN_CONSUMER" add -A
  set +e
  OUT="$(bash "$SPAN_CONSUMER/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = "$EXPECTED" ] \
    && { [ "$EXPECTED" = 0 ] || [[ "$OUT" == *"REVIEW_POLICY.md:$HIT_LINE:"* ]]; } \
    && { [ "$EXPECTED" = 1 ] || [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]]; } \
    && cmp -s "$WORKDIR/span-config-before" "$SPAN_CONSUMER/.git/config"; then
    pass "real tracked-index span control: $CONTROL"
  else fail "tracked-index span control: $CONTROL expected=$EXPECTED rc=$RC out=$OUT"; fi
done

# Case 65aa1b: owner-admitted literal repairs after the bounded contract review.
# Every SOURCE below is inert scanner input, never an executed command.
for SOURCE in \
  '**git config user.email fixture@example.invalid**' \
  '<code>git config user.email fixture@example.invalid</code>' \
  'Then:<br>git config user.email fixture@example.invalid' \
  '[git config user.email fixture@example.invalid](https://example.invalid)' \
  '~~git config user.email fixture@example.invalid~~' \
  '{git config user.email fixture@example.invalid}' \
  'First,git config user.email fixture@example.invalid' \
  'Setup—git config user.email fixture@example.invalid' \
  '*git config user.email fixture@example.invalid' \
  $'Use `git config user.email fixture@example.invalid\n<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->` here'; do
  run_on_fixture docs/literal-prose-anchor.md "$SOURCE
"
  if [ "$RC" = 1 ] && [[ "$OUT" == *'docs/literal-prose-anchor.md:1:'* ]]; then
    pass "punctuation/markup or crossline opener retains literal instruction"
  else fail "literal prose anchor erased writer: source='$SOURCE' rc=$RC out=$OUT"; fi
  run_on_fixture docs/literal-prose-real-marker.md "$SOURCE <!-- GIT_IDENTITY_SCOPE_EXEMPT: deliberate isolated fixture -->
"
  # The crossline case places the real marker on line 2, so line 1 remains
  # unexempted by the documented physical-line scope.
  EXPECTED=0; [[ "$SOURCE" != *$'\n'* ]] || EXPECTED=1
  if [ "$RC" = "$EXPECTED" ]; then pass "real prose marker retains physical-line scope"; else
    fail "prose marker scope changed: expected=$EXPECTED rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'Run $git config user.email fixture@example.invalid' \
  'Run ${git} config user.email fixture@example.invalid' \
  'Run mygit config user.email fixture@example.invalid' \
  "Run git -c core.editor='git config user.email fixture@example.invalid' status" \
  '**git -C fixture config user.email fixture@example.invalid**' \
  '<code>git config --global user.email fixture@example.invalid</code>'; do
  run_on_fixture docs/literal-prose-control.md "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "prose executable/option-data/scoping boundary retained"; else
    fail "prose control rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  "bash -c 'git config user.email fixture@example.invalid'" \
  "sh -c 'git config user.email fixture@example.invalid'" \
  "sudo bash -c 'git config user.email fixture@example.invalid'" \
  "env bash -c 'git config user.email fixture@example.invalid'" \
  "env NAME=literal OTHER='literal value' bash -xc 'git config user.email fixture@example.invalid'" \
  "exec bash -c 'git config user.email fixture@example.invalid'" \
  "command bash -c 'git config user.email fixture@example.invalid'" \
  "nohup bash -c 'git config user.email fixture@example.invalid'" \
  "bash -ec 'git config user.email fixture@example.invalid'" \
  "bash -e -c 'git config user.email fixture@example.invalid'" \
  "bash -x -e -c 'git config user.email fixture@example.invalid'" \
  "zsh -c 'git config user.email fixture@example.invalid'" \
  "zsh -O -c 'git config user.email fixture@example.invalid'" \
  "zsh -Oc 'git config user.email fixture@example.invalid'" \
  "ksh -c 'git config user.email fixture@example.invalid'" \
  "dash -c 'git config user.email fixture@example.invalid'" \
  "ash -c 'git config user.email fixture@example.invalid'" \
  "mksh -c 'git config user.email fixture@example.invalid'" \
  "/bin/zsh -c 'git config user.email fixture@example.invalid'" \
  "bash -lc 'git config user.email fixture@example.invalid'" \
  '/bin/bash -c "git config user.email fixture@example.invalid"' \
  "'sh' '-c' 'git config user.email fixture@example.invalid'" \
  "bash -c 'git config --global user.email allowed@example.invalid; git config user.name Fixture'" \
  'bash -c "git config user.email \$EMAIL"'; do
  for REL in tests/literal-shell-c.sh docs/literal-shell-c.md; do
    # Markdown uses a complete code span, preserving the shell argv model.
    TEXT="$SOURCE"; [[ "$REL" != *.md ]] || TEXT="\`$SOURCE\`"
    run_on_fixture "$REL" "$TEXT
"
    if [ "$RC" = 1 ]; then pass "one-hop literal supported shell command-string writer caught"; else
      fail "literal shell command hidden: source='$SOURCE' rel=$REL rc=$RC out=$OUT"
    fi
    run_on_fixture "$REL" "$TEXT # GIT_IDENTITY_SCOPE_EXEMPT: owning isolated fixture
"
    if [ "$RC" = 0 ]; then pass "owning marker retains literal shell-command exemption"; else
      fail "owning literal shell marker rejected: source='$SOURCE' rc=$RC out=$OUT"
    fi
  done
done
for SOURCE in \
  "printf '%s' 'git config user.email fixture@example.invalid'" \
  "grep -c 'git config user.email fixture@example.invalid' file" \
  'bash -c "$COMMAND"' \
  'bash -c "git config user.email $EMAIL"' \
  '$SHELL -c '\''git config user.email fixture@example.invalid'\''' \
  "sudo -u somebody bash -c 'git config user.email fixture@example.invalid'" \
  "env -u NAME bash -c 'git config user.email fixture@example.invalid'" \
  'env NAME="$VALUE" bash -c '\''git config user.email fixture@example.invalid'\''' \
  "bash -ce 'git config user.email fixture@example.invalid'" \
  "bash -o errexit -c 'git config user.email fixture@example.invalid'" \
  "bash -o -c 'git config user.email fixture@example.invalid'" \
  "bash -O -c 'git config user.email fixture@example.invalid'" \
  "bash -oc 'git config user.email fixture@example.invalid'" \
  "bash -Oc 'git config user.email fixture@example.invalid'" \
  "zsh -o -c 'git config user.email fixture@example.invalid'" \
  "zsh -oc 'git config user.email fixture@example.invalid'" \
  "eval 'git config user.email fixture@example.invalid'" \
  "ssh host 'git config user.email fixture@example.invalid'" \
  "docker exec container sh -c 'git config user.email fixture@example.invalid'" \
  "bash --noprofile -c 'git config user.email fixture@example.invalid'" \
  "bash -c 'git -C fixture config user.email fixture@example.invalid'" \
  "bash -c 'git config --global user.email fixture@example.invalid'" \
  "bash -c 'git config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: child fixture'" \
  "bash -c \"bash -c 'git config user.email fixture@example.invalid'\""; do
  for REL in tests/literal-shell-c-control.sh docs/literal-shell-c-control.md; do
    TEXT="$SOURCE"; [[ "$REL" != *.md ]] || TEXT="\`$SOURCE\`"
    run_on_fixture "$REL" "$TEXT
"
    if [ "$RC" = 0 ]; then pass "shell-c data/runtime/scope/depth boundaries retained"; else
      fail "literal shell-c control rejected: source='$SOURCE' rel=$REL rc=$RC out=$OUT"
    fi
  done
done
# Literal-word admission must distinguish runtime expansion from protected
# source bytes; these fake paths and command strings are never executed.
for EXECUTABLE in '*/bash' '~/bin/bash' '?/bash' '[ab]/bash' '{a,b}/bash'; do
  for QUOTING in unquoted single double; do
    EXPECTED=1; WORD="$EXECUTABLE"
    case "$QUOTING" in
      unquoted) EXPECTED=0 ;;
      single) WORD="'$EXECUTABLE'" ;;
      double) WORD="\"$EXECUTABLE\"" ;;
    esac
    for REL in tests/shell-c-expansion-executable.sh docs/shell-c-expansion-executable.md; do
      SOURCE="$WORD -c 'git config user.email fixture@example.invalid'"
      [[ "$REL" != *.md ]] || SOURCE="\`$SOURCE\`"
      run_on_fixture "$REL" "$SOURCE
"
      if [ "$RC" = "$EXPECTED" ]; then pass "shell-c executable expansion/quote boundary: $QUOTING $EXECUTABLE"; else
        fail "shell-c executable boundary: source='$SOURCE' expected=$EXPECTED rc=$RC out=$OUT"
      fi
    done
  done
done
for EXECUTABLE in '\*/bash' '\~/bin/bash' '\?/bash' '\[ab\]/bash' '\{a,b\}/bash'; do
  run_on_fixture tests/shell-c-escaped-executable.sh "$EXECUTABLE -c 'git config user.email fixture@example.invalid'
"
  if [ "$RC" = 1 ]; then pass "escaped executable metacharacters remain literal"; else
    fail "escaped literal executable lost: word='$EXECUTABLE' rc=$RC out=$OUT"
  fi
done
for VALUE in 'fixture*' 'fixture?' 'fixture[ab]' 'fixture{a,b}' '~fixture'; do
  for QUOTING in unquoted single double; do
    EXPECTED=1
    case "$QUOTING" in
      unquoted) WORD="git\ config\ user.email\ $VALUE"; EXPECTED=0 ;;
      single) WORD="'git config user.email $VALUE'" ;;
      double) WORD="\"git config user.email $VALUE\"" ;;
    esac
    # A tilde in the middle of an unquoted word does not expand. Only a
    # leading tilde is excluded; the value is already part of the command.
    [ "$VALUE" != '~fixture' ] || EXPECTED=1
    for REL in tests/shell-c-expansion-command.sh docs/shell-c-expansion-command.md; do
      SOURCE="bash -c $WORD"; [[ "$REL" != *.md ]] || SOURCE="\`$SOURCE\`"
      run_on_fixture "$REL" "$SOURCE
"
      if [ "$RC" = "$EXPECTED" ]; then pass "shell-c command-word expansion/quote boundary: $QUOTING $VALUE"; else
        fail "shell-c command-word boundary: source='$SOURCE' expected=$EXPECTED rc=$RC out=$OUT"
      fi
    done
  done
done
for SOURCE in \
  'bash -c git\ config\ user.email\ fixture\*' \
  'bash -c git\ config\ user.email\ fixture\?' \
  'bash -c git\ config\ user.email\ fixture\[ab\]' \
  'bash -c git\ config\ user.email\ fixture\{a,b\}' \
  "bash -c 'git config user.email fixture'*" \
  "bash -c 'git config user.email fixture'{a,b}"; do
  EXPECTED=1; [[ "$SOURCE" != *"'"* ]] || EXPECTED=0
  run_on_fixture tests/shell-c-escaped-command.sh "$SOURCE
"
  if [ "$RC" = "$EXPECTED" ]; then pass "escaped command bytes stay literal; unquoted suffix expansion stays opaque"; else
    fail "shell-c mixed/escape boundary: source='$SOURCE' expected=$EXPECTED rc=$RC out=$OUT"
  fi
done
run_on_fixture tests/shell-c-leading-tilde.sh 'bash -c ~/git\ config\ user.email\ fixture@example.invalid
'
if [ "$RC" = 0 ]; then pass "leading tilde command word remains runtime-derived and opaque"; else
  fail "leading tilde command value was evaluated: rc=$RC out=$OUT"
fi

for SOURCE in \
  'git config --blob HEAD:config --no-bl user.email fixture@example.invalid' \
  'git config --blob HEAD:config --no-blo user.email fixture@example.invalid' \
  'git config --list --no-li user.email fixture@example.invalid' \
  'git config --remove-section --no-rem user.email fixture@example.invalid' \
  'git config --get-all --no-get-a user.email fixture@example.invalid' \
  'git config --unset-all --no-unset-a user.email fixture@example.invalid' \
  'git config --system --no-sy user.email fixture@example.invalid'; do
  run_on_fixture tests/negative-selector-prefix.sh "$SOURCE
"
  if [ "$RC" = 1 ]; then pass "unique negative prefix cancels existing selector"; else
    fail "unique negative prefix hid writer: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'git config --blob HEAD:config --no-bl --blob HEAD:config user.email fixture@example.invalid' \
  'git config --list --no-li --list user.email fixture@example.invalid' \
  'git config --global --no-g user.email fixture@example.invalid' \
  'git config --list --no-unknown user.email fixture@example.invalid' \
  'git config --default "--no-li" --list user.email fixture@example.invalid' \
  'git -C fixture config --list --no-li user.email fixture@example.invalid'; do
  run_on_fixture tests/negative-selector-control.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "ambiguous/data/final/independent selector boundary retained"; else
    fail "negative selector control rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
for ESCAPES in '\' '\\\'; do
  run_on_fixture docs/escaped-span-opener.md "${ESCAPES}\`literal then \`code <!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->\` and run git config user.email fixture@example.invalid\`
"
  if [ "$RC" = 1 ]; then pass "odd escaped opener cannot expose cited HTML marker"; else
    fail "odd escape parity hid writer: escapes='$ESCAPES' rc=$RC out=$OUT"
  fi
done
for ESCAPES in '\\' '\\\\'; do
  run_on_fixture docs/even-span-opener.md "${ESCAPES}\`literal then \`code <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine outside span -->\` and run git config user.email fixture@example.invalid\`
"
  if [ "$RC" = 0 ]; then pass "even opener escape parity retains actual outside HTML comment"; else
    fail "even escape parity rejected real marker: escapes='$ESCAPES' rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/escaped-span-closer.md '`citation\` git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine outside span -->
'
if [ "$RC" = 0 ]; then pass "backslash inside span cannot escape its equal-width closer"; else
  fail "closing delimiter used opener escape rule: rc=$RC out=$OUT"
fi
for SCOPE in GLOBAL SYSTEM; do
  FLAG="$(printf '%s' "$SCOPE" | tr '[:upper:]' '[:lower:]')"
  for TARGET in .git/config ./.git/config .git/config.worktree '".git/config"' "'$ROOT/.git/config'"; do
    for REL in tests/scope-file-override.sh docs/scope-file-override.md; do
      run_on_fixture "$REL" "GIT_CONFIG_$SCOPE=$TARGET git config --$FLAG user.email fixture@example.invalid
"
      # Absolute paths are matched against the scanned root, not the source
      # checkout; this fixture path is an independent explicit target.
      EXPECTED=1; [[ "$TARGET" != *"$ROOT"* ]] || EXPECTED=0
      if [ "$RC" = "$EXPECTED" ]; then pass "literal leading scope-file assignment honors repository target boundary"; else
        fail "scope-file override: target='$TARGET' expected=$EXPECTED rc=$RC out=$OUT"
      fi
    done
  done
  for SOURCE in \
    "GIT_CONFIG_$SCOPE=fixture/config git config --$FLAG user.email fixture@example.invalid" \
    "GIT_CONFIG_$SCOPE=\"\$FIX/.git/config\" git config --$FLAG user.email fixture@example.invalid" \
    "GIT_CONFIG_$SCOPE=.git/config git -C fixture config --$FLAG user.email fixture@example.invalid" \
    "GIT_CONFIG_$SCOPE=.git/config git config --$FLAG user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: owning fixture"; do
    run_on_fixture tests/scope-file-control.sh "$SOURCE
"
    if [ "$RC" = 0 ]; then pass "ordinary/dynamic/explicit-target/exempt scope-file control retained"; else
      fail "scope-file control rejected: source='$SOURCE' rc=$RC out=$OUT"
    fi
  done
done

# Literal file operands cannot disguise a same-repository identity write.
for OPTIONS in \
  '--file .git/config' '--file=./.git/config' '-f.git/config' '-f .git/config' \
  '--file ".git/config"' '"--file=.git/config"' '--fil=.git/config' \
  '--file .git/config.worktree' '-f./.git/config.worktree'; do
  run_on_fixture tests/literal-config-file.sh "git config $OPTIONS user.email fixture@example.invalid
"
  if [ "$RC" = 1 ]; then pass "literal repo config file operand is not a scope exemption"; else
    fail "literal file operand escaped: options='$OPTIONS' rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  'git config --file fixture/config user.email fixture@example.invalid' \
  'git config -ffixture/config user.email fixture@example.invalid' \
  'git config -f=.git/config user.email fixture@example.invalid' \
  'git config --file "$FIX/.git/config" user.email fixture@example.invalid' \
  'git -C fixture config --file .git/config user.email fixture@example.invalid' \
  'git config --file .git/config --get user.email fixture@example.invalid'; do
  run_on_fixture tests/literal-config-file-control.sh "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "external/runtime/other-target/read file control retains exemption"; else
    fail "file operand control rejected: source='$SOURCE' rc=$RC out=$OUT"
  fi
done

# These private tracked-index controls exercise the production enumeration
# and authentic consumer skip without root/suite overrides or a hub marker.
LITERAL_CONSUMER="$WORKDIR/consumer-literal-repairs"
mkdir -p "$LITERAL_CONSUMER/scripts/ci" "$LITERAL_CONSUMER/tests"
git init -q -b main "$LITERAL_CONSUMER"
cp "$CHECK" "$LITERAL_CONSUMER/scripts/ci/check_git_identity_hygiene"
cp "$ROOT/tests/test_git_identity_hygiene.sh" "$LITERAL_CONSUMER/tests/"
cp "$LITERAL_CONSUMER/.git/config" "$WORKDIR/literal-config-before"
LITERAL_PHYSICAL_ROOT="$(cd "$LITERAL_CONSUMER" && pwd -P)"
for CONTROL in prose opener shell-c lazy-quote wrapper-sudo wrapper-env bundled-shell separate-shell zsh-shell grep-data escaped-opener negative-selector override-global override-system quoted-data runtime option-data ordinary-global explicit-file absolute-file absolute-worktree-file absolute-override runtime-glob literal-glob; do
  REL=REVIEW_POLICY.md; EXPECTED=1
  case "$CONTROL" in
    prose) SOURCE='**git config user.email fixture@example.invalid**' ;;
    opener) SOURCE=$'Use `git config user.email fixture@example.invalid\n<!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->`' ;;
    shell-c) REL=literal.sh; SOURCE="bash -c 'git config user.email fixture@example.invalid'" ;;
    lazy-quote) SOURCE=$'> Use `literal\ngit config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->`' ;;
    wrapper-sudo) REL=literal.sh; SOURCE="sudo bash -c 'git config user.email fixture@example.invalid'" ;;
    wrapper-env) REL=literal.sh; SOURCE="env NAME=literal bash -c 'git config user.email fixture@example.invalid'" ;;
    bundled-shell) REL=literal.sh; SOURCE="bash -ec 'git config user.email fixture@example.invalid'" ;;
    separate-shell) REL=literal.sh; SOURCE="bash -e -c 'git config user.email fixture@example.invalid'" ;;
    zsh-shell) REL=literal.sh; SOURCE="zsh -c 'git config user.email fixture@example.invalid'" ;;
    grep-data) REL=literal.sh; SOURCE="grep -c 'git config user.email fixture@example.invalid' file"; EXPECTED=0 ;;
    escaped-opener) SOURCE='\`literal then `code <!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->` run git config user.email fixture@example.invalid`' ;;
    negative-selector) REL=literal.sh; SOURCE='git config --list --no-li user.email fixture@example.invalid' ;;
    override-global) SOURCE='GIT_CONFIG_GLOBAL=.git/config git config --global user.email fixture@example.invalid' ;;
    override-system) REL=literal.sh; SOURCE='GIT_CONFIG_SYSTEM=.git/config git config --system user.email fixture@example.invalid' ;;
    absolute-override) REL=literal.sh; SOURCE="GIT_CONFIG_GLOBAL='$LITERAL_PHYSICAL_ROOT/.git/config' git config --global user.email fixture@example.invalid" ;;
    runtime-glob) REL=literal.sh; SOURCE="*/bash -c 'git config user.email fixture@example.invalid'"; EXPECTED=0 ;;
    literal-glob) REL=literal.sh; SOURCE="'*/bash' -c 'git config user.email fixture@example.invalid'" ;;
    quoted-data) REL=literal.sh; SOURCE="printf '%s' 'git config user.email fixture@example.invalid'"; EXPECTED=0 ;;
    runtime) SOURCE='Run $git config user.email fixture@example.invalid'; EXPECTED=0 ;;
    option-data) SOURCE="Run git -c core.editor='git config user.email fixture@example.invalid' status"; EXPECTED=0 ;;
    ordinary-global) SOURCE='git config --global user.email fixture@example.invalid'; EXPECTED=0 ;;
    explicit-file) SOURCE='git config --file=.git/config user.email fixture@example.invalid' ;;
    absolute-file) REL=literal.sh; SOURCE="git config --file='$LITERAL_PHYSICAL_ROOT/.git/config' user.email fixture@example.invalid" ;;
    absolute-worktree-file) REL=literal.sh; SOURCE="git config -f '$LITERAL_PHYSICAL_ROOT/.git/config.worktree' user.email fixture@example.invalid" ;;
  esac
  rm -f "$LITERAL_CONSUMER/REVIEW_POLICY.md" "$LITERAL_CONSUMER/literal.sh"
  printf '%s\n' "$SOURCE" > "$LITERAL_CONSUMER/$REL"
  git -C "$LITERAL_CONSUMER" add -A
  set +e
  OUT="$(bash "$LITERAL_PHYSICAL_ROOT/scripts/ci/check_git_identity_hygiene" 2>&1)"; RC=$?
  set -e
  if [ "$RC" = "$EXPECTED" ] \
    && { [ "$EXPECTED" = 0 ] || [[ "$OUT" == *"$REL:1:"* ]] || { [ "$CONTROL" = lazy-quote ] && [[ "$OUT" == *"$REL:2:"* ]]; }; } \
    && { [ "$EXPECTED" = 1 ] || [[ "$OUT" == *"regression test suite skipped (consumer checkout"* ]]; } \
    && cmp -s "$WORKDIR/literal-config-before" "$LITERAL_CONSUMER/.git/config"; then
    pass "real tracked-index literal repair/control: $CONTROL"
  else fail "tracked-index literal repair: $CONTROL expected=$EXPECTED rc=$RC out=$OUT"; fi
done

# Case 65aa1: omitted blockquote markers can lazily continue the same
# paragraph. Complete equal-width spans still make cited markers data;
# real comments and actual paragraph/block boundaries retain their scope.
for PREFIX in '> ' '> > ' '- > ' '> - ' '> 1. > '; do
  for CONTINUATION in '' '  '; do
  for TICKS in '`' '``'; do
    UNEQUAL='`'; [ "$TICKS" != '`' ] || UNEQUAL='``'
    run_on_fixture docs/lazy-quote-citation.md "${PREFIX}Use ${TICKS}literal $UNEQUAL unequal run
${CONTINUATION}git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->${TICKS}
"
    if [ "$RC" = 1 ] && [[ "$OUT" == *'docs/lazy-quote-citation.md:2:'* ]]; then
      pass "lazy quote paragraph preserves complete equal-width span citation"
    else fail "lazy quote cited marker cleared writer: prefix='$PREFIX' ticks='$TICKS' rc=$RC out=$OUT"; fi
    run_on_fixture docs/lazy-quote-real-comment.md "${PREFIX}Use ${TICKS}literal
${CONTINUATION}git config user.email fixture@example.invalid${TICKS} <!-- GIT_IDENTITY_SCOPE_EXEMPT: actual comment -->
"
    if [ "$RC" = 0 ]; then pass "real comment after lazily continued closed span remains valid"; else
      fail "lazy quote rejected real outside comment: prefix='$PREFIX' ticks='$TICKS' rc=$RC out=$OUT"
    fi
  done
  done
done
run_on_fixture docs/lazy-partial-quote.md $'> > Use `literal\n> git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: cited -->`\n'
if [ "$RC" = 1 ]; then pass "partially omitted nested quote marker keeps cited marker inside span"; else
  fail "partial lazy quote accepted citation: rc=$RC out=$OUT"
fi
for PREFIX in '> ' '- > ' '> - ' '> 1. > '; do
  for BOUNDARY in '' '# heading' '---' '===' '- new item' '1. new item'; do
  run_on_fixture docs/lazy-quote-boundary.md "${PREFIX}Use \`literal
$BOUNDARY
git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: actual comment -->\`
"
  if [ "$RC" = 0 ]; then pass "actual lazy-quote paragraph/block boundary preserves outside marker"; else
    fail "lazy quote crossed boundary: boundary='$BOUNDARY' rc=$RC out=$OUT"
  fi
  done
done
for SOURCE in \
  $'> Paragraph\ngit config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: actual comment -->' \
  $'> Use `unmatched\ngit config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: actual comment -->'; do
  run_on_fixture docs/lazy-quote-unmatched.md "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "ordinary or unmatched lazy-quote prose retains real exemption"; else
    fail "lazy quote unvalidated opener hid real exemption: rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/lazy-quote-fence.md $'> Use `literal\n~~~bash\ngit config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->`\n'
if [ "$RC" = 1 ]; then pass "actual fence interrupts lazy quote and keeps HTML code marker literal"; else
  fail "lazy quote absorbed new fenced block: rc=$RC out=$OUT"
fi

# Case 65aa2: only one through nine digits form an ordered list marker.
for ENDING in '.' ')'; do
  for NUMBER in 123456789 1234567890; do
    EXPECTED=1; [ "$NUMBER" != 1234567890 ] || EXPECTED=0
    INDENT="$(printf '%*s' "$((${#NUMBER} + 2))" '')"
    run_on_fixture docs/ordered-width.md "$NUMBER$ENDING \`\`\`bash
${INDENT}git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal if valid list fence -->
"
    if [ "$RC" = "$EXPECTED" ]; then pass "ordered marker width boundary: $NUMBER$ENDING"; else
      fail "ordered width wrong: marker=$NUMBER$ENDING expected=$EXPECTED rc=$RC out=$OUT"
    fi
    run_on_fixture docs/ordered-width-unexempted.md "$NUMBER$ENDING \`\`\`bash
${INDENT}git config user.email fixture@example.invalid
"
    if [ "$RC" = 1 ]; then pass "ordered width control retains unexempted writer"; else
      fail "ordered width hid writer: marker=$NUMBER$ENDING rc=$RC out=$OUT"
    fi
  done
done

# Case 65ab: only ordered start 1 can interrupt an open paragraph.
for NUMBER in 0 2 3 10; do
  ORDERED_INDENT="$(printf '%*s' "$((${#NUMBER} + 2))" '')"
  run_on_fixture docs/ordered-paragraph.md "Paragraph
$NUMBER. \`\`\`bash
   git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: actual paragraph -->
"
  if [ "$RC" = 0 ]; then pass "non-1 ordered marker cannot turn paragraph HTML exemption into code data"; else
    fail "ordered paragraph interruption rejected genuine marker: number=$NUMBER rc=$RC out=$OUT"
  fi
  run_on_fixture docs/ordered-after-blank.md "Paragraph

$NUMBER. \`\`\`bash
${ORDERED_INDENT}git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
"
  if [ "$RC" = 1 ]; then pass "blank boundary allows non-1 ordered fence; literal HTML remains data"; else
    fail "blank-separated ordered fence accepted literal marker: number=$NUMBER rc=$RC out=$OUT"
  fi
done
for NUMBER in 1 01; do
  run_on_fixture docs/ordered-one-paragraph.md "Paragraph
$NUMBER. \`\`\`bash
    git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
"
  if [ "$RC" = 1 ]; then pass "ordered start 1 interrupts paragraph and keeps fenced HTML literal"; else
    fail "ordered1 interruption missed literal writer: number=$NUMBER rc=$RC out=$OUT"
  fi
done
for SOURCE in \
  $'> Paragraph\n> 2. ```bash\n>    git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: paragraph -->' \
  $'- Paragraph\n  2. ```bash\n     git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: paragraph -->' \
  $'> - Paragraph\n>   2. ```bash\n>      git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: paragraph -->'; do
  run_on_fixture docs/nested-ordered-paragraph.md "$SOURCE
"
  if [ "$RC" = 0 ]; then pass "numeric interruption uses retained outer quote/list paragraph context"; else
    fail "nested numeric paragraph became fence: source='$SOURCE' rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/nested-ordered-one.md $'> Paragraph\n> 1. ```bash\n>    git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->\n'
if [ "$RC" = 1 ]; then pass "valid nested ordered1 fence keeps HTML marker literal"; else
  fail "nested ordered1 fence cleared writer: rc=$RC out=$OUT"
fi
run_on_fixture docs/ordered-sibling.md $'1. Paragraph\n2. ```bash\n   git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->\n'
if [ "$RC" = 1 ]; then pass "sibling ordered item ends prior paragraph container before opening fence"; else
  fail "sibling ordered2 fence treated as interrupted prose: rc=$RC out=$OUT"
fi
run_on_fixture docs/ordered-paragraph-no-exemption.md $'Paragraph\n2. ```bash\n   git config user.email leak@example.invalid\n'
if [ "$RC" = 1 ]; then pass "corrected paragraph context still flags unexempted literal writer"; else
  fail "numeric context correction hid writer: rc=$RC out=$OUT"
fi

# Case 65ac: empty list items cannot interrupt a paragraph either.
for MARKER in '1.' '01.' '*' '+'; do
  EMPTY_CODE_INDENT="$(printf '%*s' "$((${#MARKER} + 5))" '')"
  run_on_fixture docs/empty-list-paragraph.md "Paragraph
$MARKER
       git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine paragraph -->
"
  if [ "$RC" = 0 ]; then pass "empty numeric/bullet item preserves paragraph and real HTML marker"; else
    fail "empty marker interrupted paragraph: marker='$MARKER' rc=$RC out=$OUT"
  fi
  run_on_fixture docs/empty-list-after-blank.md "Paragraph

$MARKER
${EMPTY_CODE_INDENT}git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal indented code -->
"
  if [ "$RC" = 1 ]; then pass "blank boundary retains standalone empty-child indentation/code behavior"; else
    fail "empty first child after blank cleared code writer: marker='$MARKER' rc=$RC out=$OUT"
  fi
  run_on_fixture docs/empty-list-unexempted.md "Paragraph
$MARKER
       git config user.email leak@example.invalid
"
  if [ "$RC" = 1 ]; then pass "paragraph preservation still catches unexempted literal instruction"; else
    fail "empty marker context erased writer: marker='$MARKER' rc=$RC out=$OUT"
  fi
done
run_on_fixture docs/empty-list-spaced.md $'Paragraph\n1.   \n       git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine paragraph -->\n'
if [ "$RC" = 0 ]; then pass "blank-only first content cannot interrupt paragraph"; else
  fail "space-only list child became code container: rc=$RC out=$OUT"
fi
run_on_fixture docs/empty-list-crlf.md $'Paragraph\r\n1.\r\n       git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: genuine paragraph -->\r\n'
if [ "$RC" = 0 ]; then pass "CRLF empty item preserves actual paragraph comment"; else
  fail "CRLF empty item interrupted paragraph: rc=$RC out=$OUT"
fi
run_on_fixture docs/nonempty-list-seven-spaces.md $'Paragraph\n1. content\n       git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal indented code -->\n'
if [ "$RC" = 0 ]; then pass "nonempty ordered1 starts its own paragraph; indentation cannot interrupt it"; else
  fail "nonempty item paragraph comment rejected: rc=$RC out=$OUT"
fi
run_on_fixture docs/nonempty-list-fence-seven-spaces.md $'Paragraph\n1. ```bash\n       git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->\n'
if [ "$RC" = 1 ]; then pass "nonempty ordered1 fence still interrupts outer paragraph with seven-space code"; else
  fail "nonempty ordered1 fence lost: rc=$RC out=$OUT"
fi
run_on_fixture docs/empty-list-01-seven-spaces.md $'Paragraph\n\n01.\n       git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: actual child paragraph -->\n'
if [ "$RC" = 0 ]; then pass "empty01 child requires eight total spaces for code; seven remains paragraph"; else
  fail "empty01 seven-space paragraph became code: rc=$RC out=$OUT"
fi
run_on_fixture docs/empty-dash-setext.md $'Paragraph\n-\n       git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code after heading -->\n'
if [ "$RC" = 1 ]; then pass "empty dash retains existing setext heading boundary"; else
  fail "empty list guard weakened setext/code boundary: rc=$RC out=$OUT"
fi

# Case 65p: the modern rename verb moves a section, not the protected key.
for ACTION in 'rename-section' '"rename-section"' "'rename-section'" '--rename-section'; do
  run_on_fixture "tests/rename-section.sh" "git config $ACTION user.email archived
"
  if [ "$RC" = "0" ]; then
    pass "literal modern/legacy rename-section is a nonwrite"
  else
    fail "section rename misclassified: '$ACTION' rc=$RC out=$OUT"
  fi
done
run_on_fixture "tests/rename-neighbour.sh" 'git config rename-section user.email archived; git config user.email leak@example.invalid
'
if [ "$RC" = "1" ]; then
  pass "section rename cannot suppress neighbouring identity assignment"
else
  fail "rename suppressed neighbouring writer: rc=$RC out=$OUT"
fi
run_on_fixture "tests/rename-value.sh" "git -c foo.bar='config rename-section value' config user.email leak@example.invalid
"
if [ "$RC" = "1" ]; then
  pass "rename-section inside quoted option value is not a subcommand"
else
  fail "quoted rename data suppressed writer: rc=$RC out=$OUT"
fi

# Actual Git oracles run only in a private fixture repo, never caller cwd.
LITERAL_ORACLE="$WORKDIR/literal-git-oracle"
git init -q -b main "$LITERAL_ORACLE"
for SOURCE in \
  "git -c foo.bar='a;b' config user.email fixture@example.invalid" \
  'g\it config user.email fixture@example.invalid' \
  'git c\onfig user.email fixture@example.invalid' \
  'git con"fig" user.email fixture@example.invalid' \
  "git 'config' user.email fixture@example.invalid" \
  'git config --global --no-global user.email fixture@example.invalid' \
  $'git -c foo.bar=$(printf a\nprintf b) config user.email fixture@example.invalid'; do
  (cd "$LITERAL_ORACLE" && bash -c "$SOURCE")
  VALUE="$(git -C "$LITERAL_ORACLE" config --local --get user.email)"
  if [ "$VALUE" = fixture@example.invalid ]; then
    pass "private Git oracle confirms literal config/selector/substitution command writes identity"
  else
    fail "private Git oracle differed: source='$SOURCE' value='$VALUE'"
  fi
  git -C "$LITERAL_ORACLE" config --local --unset-all user.email
done
# Version gates only this runtime oracle; static modern-syntax assertions
# above still run on every toolchain. A supported operation/readback failure
# is a failure, never evidence that the operation is unsupported.
modern_rename_oracle() {
  local repo="$1" git_cmd="${2:-git}" version major minor value renamed value_rc renamed_rc rc
  if ! version="$("$git_cmd" --version 2>&1)"; then
    fail "modern rename oracle cannot read Git version: $version"; return
  fi
  if [[ ! "$version" =~ ^git[[:space:]]version[[:space:]]([0-9]+)\.([0-9]+)(\.|[[:space:]]|$) ]]; then
    fail "modern rename oracle cannot classify Git version: $version"; return
  fi
  major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]}))
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 46 ]; }; then
    skip "modern rename runtime oracle requires Git 2.46+: $version"; return
  fi
  if ! "$git_cmd" -C "$repo" config user.email.old fixture; then
    fail "modern rename oracle fixture setup failed: $version"; return
  fi
  if "$git_cmd" -C "$repo" config rename-section user.email archived; then
    if value="$("$git_cmd" -C "$repo" config --local --get user.email 2>/dev/null)"; then value_rc=0; else value_rc=$?; fi
    if renamed="$("$git_cmd" -C "$repo" config --local --get archived.old 2>/dev/null)"; then renamed_rc=0; else renamed_rc=$?; fi
    if [ "$value_rc" = 1 ] && [ "$renamed_rc" = 0 ] && [ -z "$value" ] && [ "$renamed" = fixture ]; then
      pass "private Git oracle confirms modern rename leaves protected key unset"
    else
      fail "private rename oracle readback failed: protected='$value' rc=$value_rc renamed='$renamed' rc=$renamed_rc"
    fi
  else
    rc=$?
    fail "modern rename operation failed on supported Git: rc=$rc $version"
  fi
}
modern_rename_oracle "$LITERAL_ORACLE"

# Exercise version/operation/readback boundaries without installing Git or
# altering PATH. Wrappers delegate all actual configuration to private repos.
ORACLE_REAL_GIT="$(command -v git)"
for CASE in old-239 old-243 unknown-version supported-failure supported-readback-failure; do
  ORACLE_WRAPPER="$WORKDIR/oracle-$CASE"
  cat > "$ORACLE_WRAPPER" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
  case "$ORACLE_CASE" in
    old-239) echo 'git version 2.39.5 (Apple Git-154)' ;;
    old-243) echo 'git version 2.43.0' ;;
    unknown-version) echo 'git version unknown' ;;
    *) echo 'git version 2.54.0' ;;
  esac
  exit 0
fi
case "$ORACLE_CASE" in
  old-*) echo unexpected-operation >&2; exit 91 ;;
  supported-failure)
    if [ "$4" = rename-section ]; then exit 61; fi ;;
  supported-readback-failure)
    if [ "${6:-}" = archived.old ]; then exit 62; fi ;;
esac
exec "$ORACLE_REAL_GIT" "$@"
EOF
  chmod +x "$ORACLE_WRAPPER"
  ORACLE_REPO="$WORKDIR/oracle-repo-$CASE"
  git init -q -b main "$ORACLE_REPO"
  RESULT="$( {
    PASS=0; FAIL=0; SKIP=0
    export ORACLE_CASE="$CASE" ORACLE_REAL_GIT
    modern_rename_oracle "$ORACLE_REPO" "$ORACLE_WRAPPER"
    echo "COUNTS:$PASS:$FAIL:$SKIP:AFTER"
  } 2>&1)"
  case "$CASE" in
    old-*)
      if [[ "$RESULT" == *'COUNTS:0:0:1:AFTER'* ]] && [[ "$RESULT" == *'SKIP:'* ]] && [[ "$RESULT" != *'unexpected-operation'* ]]; then
        pass "unsupported Git runtime oracle genuinely skips without executing operation or inventing a pass"
      else
        fail "unsupported Git oracle did not skip honestly: case=$CASE result=$RESULT"
      fi ;;
    *)
      if [[ "$RESULT" == *'COUNTS:0:1:0:AFTER'* ]] && [[ "$RESULT" == *'FAIL:'* ]]; then
        pass "supported Git operation/readback failure is recorded and does not abort suite"
      else
        fail "supported Git oracle failure hidden or aborted: case=$CASE result=$RESULT"
      fi ;;
  esac
done

# Case 65q: indented Markdown code contains literal HTML, including in
# list/quote containers. Shell exemptions and real comments after code survive.
for PREFIX in '    ' $'\t' '>     ' '-     ' '1.     ' '> -     '; do
  run_on_fixture "docs/indented-html.md" "${PREFIX}git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
"
  if [ "$RC" = "1" ]; then
    pass "HTML marker in indented/container code cannot exempt a writer"
  else
    fail "indented code exempted writer: prefix='$PREFIX' rc=$RC out=$OUT"
  fi
  run_on_fixture "docs/indented-shell.md" "${PREFIX}git config user.email fixture@example.invalid # GIT_IDENTITY_SCOPE_EXEMPT: isolated fixture

"'git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: outside code -->
'
  if [ "$RC" = "0" ]; then
    pass "real shell marker in indented code and outside HTML marker remain valid"
  else
    fail "true comment around indented code rejected: prefix='$PREFIX' rc=$RC out=$OUT"
  fi
done
for BEFORE in '# Heading' '- # Heading' '- ' '-' '* * *' '> # Heading'; do
  INDENT='    '
  case "$BEFORE" in '- '|'--'|'-'|'- # Heading') INDENT='      ' ;; '> # Heading') INDENT='>     ' ;; esac
  run_on_fixture "docs/indented-boundary.md" "${BEFORE}
${INDENT}git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
"
  if [ "$RC" = "1" ]; then
    pass "heading/empty-item/thematic boundary permits indented code, not HTML exemptions"
  else
    fail "indented block boundary missed: before='$BEFORE' rc=$RC out=$OUT"
  fi
done
for BEFORE in 'Paragraph' '- Paragraph' '> Paragraph'; do
  INDENT='    '
  case "$BEFORE" in '- Paragraph') INDENT='      ' ;; '> Paragraph') INDENT='>     ' ;; esac
  run_on_fixture "docs/paragraph-continuation.md" "${BEFORE}
${INDENT}git config user.email fixture@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: true paragraph comment -->
"
  if [ "$RC" = "0" ]; then
    pass "four-column indentation cannot interrupt a paragraph; true HTML comment remains valid"
  else
    fail "paragraph continuation treated as code: before='$BEFORE' rc=$RC out=$OUT"
  fi
done
run_on_fixture "docs/indented-continued.md" '    git \
    config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->
'
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/indented-continued.md:1:'; then
  pass "continued command in indented code cannot use literal HTML exemption"
else
  fail "continued indented writer missed: rc=$RC out=$OUT"
fi
run_on_fixture "docs/a-paragraph.md" 'Paragraph
'
printf '    git config user.email leak@example.invalid <!-- GIT_IDENTITY_SCOPE_EXEMPT: literal code -->\n' > "$WORKDIR/fixture-$FIXTURE_SEQ/docs/b-code.md"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$WORKDIR/fixture-$FIXTURE_SEQ" bash "$CHECK" 2>&1)"; RC=$?
set -e
if [ "$RC" = "1" ] && printf '%s' "$OUT" | grep -q 'docs/b-code.md:1:'; then
  pass "paragraph context resets between Markdown files"
else
  fail "paragraph state leaked between files: rc=$RC out=$OUT"
fi

# ── Linked worktrees: identity lives in every one of them (#806) ───────

# Case 66: `git config --worktree` reads the INVOKING worktree's
# config.worktree and nothing else, so a protected key parked in a SIBLING
# linked worktree passed a check run from the main worktree — while every
# commit made in that sibling was attributed and signed under it. The
# offending file is what the remediation has to name: no scope reachable
# from the main worktree would clear it.
LWMAIN="$WORKDIR/linked-identity-main"
LWSIB="$WORKDIR/linked-identity-sibling"
git init -q -b main "$LWMAIN"
printf 'seed\n' > "$LWMAIN/seed.txt"
git -C "$LWMAIN" add seed.txt
git -C "$LWMAIN" -c user.name=fixture -c user.email=fixture@example.com \
  commit -q -m seed
git -C "$LWMAIN" worktree add -q -b linked "$LWSIB"
git -C "$LWMAIN" config --local extensions.worktreeConfig true
git -C "$LWSIB" config --worktree user.email "linked-worktree@example.com"
# Invisible to every scope the main worktree can read for ITSELF, which is
# exactly what made the old check report success on this repository.
LW_OWN_SCOPE="$(git -C "$LWMAIN" config --worktree --get user.email 2>/dev/null || true)"
LW_LOCAL="$(git -C "$LWMAIN" config --local --includes --get user.email 2>/dev/null || true)"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$LWMAIN" bash "$CHECK" 2>&1)"
RC=$?
set -e
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all user\.email' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
LW_LEFT="$(git -C "$LWSIB" config --worktree --get user.email 2>/dev/null)"
OUT_AFTER="$(MERGEPATH_GIT_IDENTITY_ROOT="$LWMAIN" bash "$CHECK" 2>&1)"
RC_AFTER=$?
set -e
if [ -z "$LW_OWN_SCOPE" ] && [ -z "$LW_LOCAL" ] \
  && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "linked-worktree@example.com" \
  && printf '%s' "$OUT" | grep -q "worktrees/linked-identity-sibling/config.worktree" \
  && [ -n "$REMEDY" ] && [ -z "$LW_LEFT" ] && [ "$RC_AFTER" = "0" ]; then
  pass "identity in a sibling linked worktree: caught from the main worktree and cleared by the printed command"
else
  fail "sibling linked-worktree identity escaped: own='$LW_OWN_SCOPE' local='$LW_LOCAL' rc=$RC remedy='$REMEDY' left='$LW_LEFT' after=$RC_AFTER out=$OUT"
fi

# Case 66b: a sibling's file is read outright rather than through a scope,
# so a DORMANT one is inspected on the same terms as an active one.
# Disabling extensions.worktreeConfig deletes nobody's config.worktree, and
# re-enabling it reactivates every identity in them with no fresh write for
# a later run to catch.
DLWMAIN="$WORKDIR/dormant-linked-main"
DLWSIB="$WORKDIR/dormant-linked-sibling"
git init -q -b main "$DLWMAIN"
printf 'seed\n' > "$DLWMAIN/seed.txt"
git -C "$DLWMAIN" add seed.txt
git -C "$DLWMAIN" -c user.name=fixture -c user.email=fixture@example.com \
  commit -q -m seed
git -C "$DLWMAIN" worktree add -q -b dormant-linked "$DLWSIB"
git -C "$DLWMAIN" config --local extensions.worktreeConfig true
git -C "$DLWSIB" config --worktree user.signingkey DORMANTKEY
git -C "$DLWMAIN" config --local extensions.worktreeConfig false
DLW_FILE="$DLWMAIN/.git/worktrees/dormant-linked-sibling/config.worktree"
DLW_PRESENT=0
if [ -f "$DLW_FILE" ]; then
  DLW_PRESENT=1
fi
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$DLWMAIN" bash "$CHECK" 2>&1)"
RC=$?
set -e
REMEDY="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+git .*--unset-all user\.signingkey' | head -1 || true)"
set +e
eval "$REMEDY" >/dev/null 2>&1
DLW_LEFT="$(git config --file "$DLW_FILE" --get user.signingkey 2>/dev/null)"
OUT_AFTER="$(MERGEPATH_GIT_IDENTITY_ROOT="$DLWMAIN" bash "$CHECK" 2>&1)"
RC_AFTER=$?
set -e
if [ "$DLW_PRESENT" = "1" ] && [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "dormant linked worktree" \
  && printf '%s' "$OUT" | grep -q "DORMANTKEY" \
  && [ -n "$REMEDY" ] && [ -z "$DLW_LEFT" ] && [ "$RC_AFTER" = "0" ]; then
  pass "dormant sibling config.worktree: inspected and cleared like an active one"
else
  fail "dormant sibling worktree identity escaped: present=$DLW_PRESENT rc=$RC remedy='$REMEDY' left='$DLW_LEFT' after=$RC_AFTER out=$OUT"
fi

# Case 66c: the converse — the invoking worktree's OWN config.worktree is
# not also enumerated as a sibling. It is reachable through its scope, and
# reporting it twice would hand an operator two remediation commands for
# one override.
SELFWT_REPO="$WORKDIR/self-worktree-repo"
git init -q -b main "$SELFWT_REPO"
git -C "$SELFWT_REPO" config --local extensions.worktreeConfig true
git -C "$SELFWT_REPO" config --worktree user.email "self-worktree@example.com"
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$SELFWT_REPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
N_ENTRIES="$(printf '%s\n' "$OUT" | grep -c "user.email = self-worktree@example.com" || true)"
N_REMEDIES="$(printf '%s\n' "$OUT" | grep -c -- "--unset-all user.email" || true)"
if [ "$RC" = "1" ] && [ "$N_ENTRIES" -eq 1 ] && [ "$N_REMEDIES" -eq 1 ] \
  && ! printf '%s' "$OUT" | grep -q "linked worktree"; then
  pass "the invoking worktree's own config.worktree: reported once, not also as a sibling"
else
  fail "own config.worktree double-reported: entries=$N_ENTRIES remedies=$N_REMEDIES rc=$RC out=$OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo
echo "test_git_identity_hygiene: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
