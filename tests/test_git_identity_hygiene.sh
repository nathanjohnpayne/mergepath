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
# an option, a comment, a redirection or a closing substitution, and
# none of them is a value being written.
run_on_fixture "tests/not-values.sh" '#!/usr/bin/env bash
git config user.email --show-origin
git config user.email  # which address is this repo using?
git config user.email > /tmp/who
who=$( git config user.email )
echo "$who"
'
if [ "$RC" = "0" ]; then
  pass "option / comment / redirection after the key: no false hit"
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
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$SIGREPO\" config --local --unset-all user.signingkey" \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$SIGREPO\" config --local --unset-all tag.gpgsign" \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$SIGREPO\" config --worktree --unset-all user.email" \
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
git -C "$EMPTYREPO" config --local user.email ""
set +e
OUT="$(MERGEPATH_GIT_IDENTITY_ROOT="$EMPTYREPO" bash "$CHECK" 2>&1)"
RC=$?
set -e
if [ "$RC" = "1" ] \
  && printf '%s' "$OUT" | grep -q "local: user.email = (set to the empty string)" \
  && printf '%s' "$OUT" | grep -qF -- "git -C \"$EMPTYREPO\" config --local --unset-all user.email"; then
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

# ── Fail-closed: a suite that removes the repository metadata ──────────

# Case 59: the post-suite phase reads the repository through `.git` and
# the baseline out of the git common dir, so a suite whose fixture
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

# ── Summary ───────────────────────────────────────────────────────────
echo
echo "test_git_identity_hygiene: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
