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
echo "test_git_identity_hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
