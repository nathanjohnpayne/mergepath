#!/usr/bin/env bash
# tests/test_load_review_config.sh
#
# Hermetic coverage for scripts/workflow/load_review_config.sh — the extracted
# body of `.github/workflows/agent-review.yml`'s `load-config` step (#788).
#
# The contract under test is that `load-config` exports its four outputs from
# the policy that GOVERNS the PR (the base branch's), the same policy
# scripts/merge-clearance-gate.sh, scripts/codex-review-check.sh and the
# `triage` job already read. Before #788 the step parsed whatever
# `actions/checkout` had materialized, so on a PR targeting a non-default
# branch the pipeline could assign a reviewer the base policy does not list, or
# arm auto-merge from an identity it does not permit.
#
# Both halves of the asymmetry are pinned, because regressing either one is
# easy and only one of them is visible in the fleet today:
#
#   non-default base -> identities come from the BASE policy
#   default base     -> identical outputs AND ZERO gh calls. The no-API-call
#                       short circuit is what shaped the #769 resolver: this
#                       job runs on every push to every open PR across the
#                       fleet, so an unconditional contents fetch would put a
#                       new API dependency on the busiest path in the pipeline.
#                       Passing the `--pr` form instead of the base fields
#                       reintroduces exactly that, which is why the call log is
#                       asserted rather than assumed.
#   resolver failure -> fail-CLOSED outputs, exit 0. Exiting nonzero would skip
#                       `triage` (it declares `needs: [load-config]` without
#                       `always()`), and a skipped labeling job is fail-OPEN.
#
# Fully offline via a PATH-prepended `gh` stub. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="$ROOT/scripts/workflow/load_review_config.sh"
[ -x "$LOADER" ] || { echo "missing $LOADER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/load-review-config-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Give the run its own TMPDIR so the temp-file-cleanup assertion below observes
# only files this suite caused, not another process's leftovers.
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"

REPO="owner/repo"

# The DEFAULT-branch policy: what the checkout carries.
DEFAULT_CONFIG="$WORK/default-policy.yml"
cat > "$DEFAULT_CONFIG" <<'YAML'
external_review_threshold: 300

external_review_paths:
  - "src/auth/**"
  - ".github/**"

available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor

author_identity: nathanjohnpayne
YAML

# The NON-DEFAULT BASE branch's policy: deliberately names different
# identities, a different threshold, and different protected paths, so an
# implementation that reads the wrong file cannot accidentally agree.
BASE_POLICY="$WORK/base-policy.yml"
cat > "$BASE_POLICY" <<'YAML'
external_review_threshold: 25

external_review_paths:
  - "release/**"

available_reviewers:
  - nathanpayne-codex

author_identity: release-bot
YAML

# A base policy that repeats a scalar key. Only reachable now that the policy
# can be FETCHED from another branch rather than always being the checked-out
# file, and a second bare line in GITHUB_OUTPUT is parsed by Actions as its own
# output entry.
DUP_POLICY="$WORK/dup-policy.yml"
cat > "$DUP_POLICY" <<'YAML'
external_review_threshold: 25
external_review_threshold: 999999

available_reviewers:
  - nathanpayne-codex

author_identity: release-bot
author_identity: someone-else
YAML

# A base policy written in legal YAML spellings the old `grep key: | awk
# '{print $2}'` extraction got wrong. It matters now that `author_identity`
# leaves this script as a GITHUB_OUTPUT the auto-merge job compares against
# `gh api user --jq .login` (#788): a value that arrives still wearing its
# quotes never matches any login, so a quoted policy would become a permanent
# merge refusal, and a nested key of the same name — which the unanchored grep
# matched FIRST, being earlier in the file — would name the wrong identity
# outright.
QUIRK_POLICY="$WORK/quirk-policy.yml"
cat > "$QUIRK_POLICY" <<'YAML'
external_review_threshold: "25"  # quoted scalar with an inline comment

codex:
  author_identity: impostor-bot

available_reviewers:
  - nathanpayne-codex

author_identity: 'release-bot'  # single-quoted, inline comment
YAML

# A base policy that RESOLVES cleanly but names no TOP-LEVEL `author_identity`
# — it carries only a nested one, under `codex:`. This is the unproven-identity
# state that does not go through the resolver-failure branch: nothing failed,
# the policy is readable, and it simply authorizes nobody to merge. It is the
# more reachable of the two unproven states, because omitting a key (or nesting
# it) requires no outage at all.
NOAUTH_POLICY="$WORK/noauth-policy.yml"
cat > "$NOAUTH_POLICY" <<'YAML'
external_review_threshold: 50

external_review_paths:
  - "release/**"

available_reviewers:
  - nathanpayne-codex

codex:
  author_identity: release-bot
YAML

# A base policy whose `author_identity` opens a quote it never closes. This is
# not YAML — every real parser rejects the document — but `load-config`'s
# extraction is a line parser, and the inline form it replaced stripped the
# opening quote unconditionally, so this file used to yield a clean
# `nathanjohnpayne` and authorize that identity to merge. An unterminated scalar
# proves nothing, so it must arrive at the merge gate empty like any other
# unproven identity (CodeRabbit, PR #973). The threshold is spelled the same way
# on purpose: the guard belongs to the shared helper, not to one key.
TORN_POLICY="$WORK/torn-policy.yml"
cat > "$TORN_POLICY" <<'YAML'
external_review_threshold: "25

external_review_paths:
  - "release/**"

available_reviewers:
  - nathanpayne-codex

author_identity: "nathanjohnpayne
YAML

CALLS_LOG="$WORK/gh-calls.log"

GH_STUB="$WORK/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALLS_LOG:-/dev/null}"
[ "${1:-}" = "api" ] || { echo "{}"; exit 0; }
shift
PATHARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;;
    --jq|--paginate) if [ "$1" = "--jq" ]; then shift 2; else shift; fi ;;
    *) [ -n "$PATHARG" ] || PATHARG="$1"; shift ;;
  esac
done
case "$PATHARG" in
  user)
    # `gh api user --jq .login` — the auto-merge job's AUTHOR_MERGE_TOKEN
    # identity probe (section 6).
    printf '%s\n' "${STUB_TOKEN_LOGIN:-nathanjohnpayne}"
    exit 0 ;;
  repos/*/pulls/*)
    cat "${STUB_PR_JSON:-/dev/null}"
    exit 0 ;;
  repos/*/commits/*)
    echo '{"sha":"basesha1"}'
    exit 0 ;;
  repos/*/contents/*)
    case "${STUB_CONTENTS_MODE:-ok}" in
      ok)     cat "${STUB_BASE_POLICY:?}"; exit 0 ;;
      dup)    cat "${STUB_DUP_POLICY:?}"; exit 0 ;;
      quirk)  cat "${STUB_QUIRK_POLICY:?}"; exit 0 ;;
      noauth) cat "${STUB_NOAUTH_POLICY:?}"; exit 0 ;;
      torn)   cat "${STUB_TORN_POLICY:?}"; exit 0 ;;
      error) echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
    esac ;;
esac
echo "{}"
STUB
chmod +x "$GH_STUB"
export PATH="$WORK:$PATH" GH_CALLS_LOG="$CALLS_LOG" STUB_BASE_POLICY="$BASE_POLICY" STUB_DUP_POLICY="$DUP_POLICY" STUB_QUIRK_POLICY="$QUIRK_POLICY" STUB_NOAUTH_POLICY="$NOAUTH_POLICY" STUB_TORN_POLICY="$TORN_POLICY"
hash -r 2>/dev/null || true

OUT_FILE="$WORK/github-output.txt"

run_loader() {  # <base_ref> <default_branch>
  : > "$OUT_FILE"
  : > "$CALLS_LOG"
  LOG=$(bash "$LOADER" --repo "$REPO" --base-ref "$1" --base-sha "basesha1" \
        --default-branch "$2" --default-config "$DEFAULT_CONFIG" \
        --output "$OUT_FILE" 2>"$WORK/err.txt") && RC=0 || RC=$?
}

out_value() {  # <key>
  # Last wins, mirroring how Actions folds duplicate GITHUB_OUTPUT keys.
  grep "^$1=" "$OUT_FILE" | tail -n 1 | sed "s/^$1=//"
}

val_in() {  # <output-file> <key>
  grep "^$2=" "$1" | tail -n 1 | sed "s/^$2=//"
}

# ---------------------------------------------------------------------------
# 1. Non-default base: every identity comes from the BASE policy, not the
#    checked-out default-branch one. This is the #788 defect.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=ok
run_loader release/1.x main
if [ "$RC" -eq 0 ] \
   && [ "$(out_value reviewers)" = '["nathanpayne-codex"]' ] \
   && [ "$(out_value author_identity)" = "release-bot" ]; then
  pass "non-default base exports identities from the BASE policy (#788)"
else
  fail "non-default base identities (rc=$RC reviewers=$(out_value reviewers) author=$(out_value author_identity))"
fi

if [ "$(out_value threshold)" = "25" ] && [ "$(out_value paths)" = '["release/**"]' ]; then
  pass "non-default base exports threshold/paths from the BASE policy (#788)"
else
  fail "non-default base threshold/paths (threshold=$(out_value threshold) paths=$(out_value paths))"
fi

# The resolver hands back a TEMP file on this path and the caller owns cleanup;
# the checkout's own config must survive untouched either way.
if [ -f "$DEFAULT_CONFIG" ] && [ "$(find "$TMPDIR" -maxdepth 1 -name 'base-review-policy.*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "the resolver's temp policy file is cleaned up and the checkout config is left in place"
else
  fail "temp policy file leaked, or the default config was deleted"
fi

# ---------------------------------------------------------------------------
# 2. Default base: identical outputs AND no API call. The short circuit is the
#    constraint that shaped the #769 resolver — see the header.
# ---------------------------------------------------------------------------
run_loader main main
if [ "$RC" -eq 0 ] \
   && [ "$(out_value threshold)" = "300" ] \
   && [ "$(out_value paths)" = '["src/auth/**",".github/**"]' ] \
   && [ "$(out_value reviewers)" = '["nathanpayne-claude","nathanpayne-cursor"]' ] \
   && [ "$(out_value author_identity)" = "nathanjohnpayne" ]; then
  pass "default base exports the checked-out policy unchanged (#788 no-regression)"
else
  fail "default base outputs (rc=$RC threshold=$(out_value threshold) paths=$(out_value paths) reviewers=$(out_value reviewers) author=$(out_value author_identity))"
fi

if ! grep -q . "$CALLS_LOG"; then
  pass "default base makes ZERO gh API calls (#769 short circuit preserved)"
else
  fail "default base made API calls: $(cat "$CALLS_LOG")"
fi

# ---------------------------------------------------------------------------
# 3. Every output is a single GITHUB_OUTPUT line. Multi-line JSON cannot be
#    written through the `key=value` format and silently truncates (#30/#58).
# ---------------------------------------------------------------------------
if [ "$(grep -c '' "$OUT_FILE" | tr -d ' ')" = "4" ] \
   && [ "$(grep -c '^threshold=\|^paths=\|^reviewers=\|^author_identity=' "$OUT_FILE" | tr -d ' ')" = "4" ]; then
  pass "emits exactly the four load-config outputs, one line each"
else
  fail "unexpected GITHUB_OUTPUT shape: $(cat "$OUT_FILE")"
fi

# ---------------------------------------------------------------------------
# 3b. A base policy that repeats a scalar key must still emit exactly four
#     GITHUB_OUTPUT lines. A stray second line is not inert — Actions parses it
#     as another `key=value` entry.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=dup
run_loader release/1.x main
if [ "$RC" -eq 0 ] \
   && [ "$(grep -c '' "$OUT_FILE" | tr -d ' ')" = "4" ] \
   && [ "$(out_value threshold)" = "25" ] \
   && [ "$(out_value author_identity)" = "release-bot" ]; then
  pass "a duplicated policy key still emits one line per output"
else
  fail "duplicated policy key broke the output shape (rc=$RC): $(cat "$OUT_FILE")"
fi

# ---------------------------------------------------------------------------
# 3c. Scalar spellings. The emitted `author_identity` is no longer just an
#     input to a string comparison inside a script — since #788 it IS the
#     identity the auto-merge job requires AUTHOR_MERGE_TOKEN to resolve to, so
#     a value carrying its YAML quotes refuses every merge, and a nested key of
#     the same name (matched first by an unanchored grep) authorizes the wrong
#     one. Both spellings are legal YAML.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=quirk
run_loader release/1.x main
if [ "$RC" -eq 0 ] && [ "$(out_value author_identity)" = "release-bot" ]; then
  pass "a quoted, inline-commented author_identity is emitted unquoted, and a nested key of the same name does not win"
else
  fail "scalar spellings: author=$(out_value author_identity) (rc=$RC)"
fi

if [ "$(out_value threshold)" = "25" ]; then
  pass "a quoted, inline-commented threshold is emitted as a bare number"
else
  fail "scalar spellings: threshold=$(out_value threshold)"
fi

# ---------------------------------------------------------------------------
# 3d. A governing policy that RESOLVES but names no top-level `author_identity`
#     must emit an EMPTY one.
#
#     This is the unproven-identity state that does NOT arrive through the
#     resolver-failure branch of section 4: the fetch succeeded, the policy is
#     readable, its threshold and reviewer list are exported normally — it just
#     authorizes nobody to merge. It is also the more reachable of the two
#     states, needing no outage: a policy can omit the key, or nest it under a
#     block, which `policy_scalar` deliberately declines to match.
#
#     Emitting a hard-coded login here instead would make EXPECTED_AUTHOR
#     non-empty in the auto-merge step, skipping the `[ -z ]` fail-closed branch
#     that section 6b pins, and enabling a merge under an identity the governing
#     policy never named. Section 6e runs that consequence end to end.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=noauth
run_loader release/1.x main
if [ "$RC" -eq 0 ] && [ "$(out_value author_identity)" = "" ]; then
  pass "a resolved policy with no top-level author_identity emits an empty identity, not a hard-coded login (#788 fail-closed)"
else
  fail "policy without author_identity emitted '$(out_value author_identity)' (rc=$RC)"
fi

# Non-vacuity: the policy really was resolved and parsed. Without this the
# assertion above would also pass on the fail-closed branch, which empties the
# identity for an entirely different reason.
if [ "$(out_value threshold)" = "50" ] \
   && [ "$(out_value reviewers)" = '["nathanpayne-codex"]' ] \
   && [ "$(out_value paths)" = '["release/**"]' ]; then
  pass "the same policy still exports its threshold, reviewers and paths (the empty identity is not the fail-closed branch)"
else
  fail "policy without author_identity mis-parsed its other keys (threshold=$(out_value threshold) reviewers=$(out_value reviewers) paths=$(out_value paths))"
fi

if [ "$(grep -c '' "$OUT_FILE" | tr -d ' ')" = "4" ]; then
  pass "an empty author_identity is still emitted as its own output line"
else
  fail "missing-identity output shape: $(cat "$OUT_FILE")"
fi

# ---------------------------------------------------------------------------
# 3e. A scalar that OPENS a quote and never closes it is the third route to an
#     unproven identity, and the only one the extraction could invent a value
#     for. The inline parser this helper replaced dropped the opening quote
#     before anything proved a closing one existed, so
#     `author_identity: "nathanjohnpayne` — malformed YAML, rejected outright by
#     the parsers the other gates use — produced a clean `nathanjohnpayne` and
#     authorized that identity at the merge gate.
#
#     Section 3c pins the opposite direction (a properly PAIRED quote must be
#     stripped, or a legal spelling becomes a permanent merge refusal), so the
#     two together say: unwrap a quote only as a pair.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=torn
run_loader release/1.x main
if [ "$RC" -eq 0 ] && [ "$(out_value author_identity)" = "" ]; then
  pass "an unterminated quoted author_identity emits nothing rather than an unquoted login (CodeRabbit, #973)"
else
  fail "unterminated quoted identity emitted '$(out_value author_identity)' (rc=$RC)"
fi

if [ "$(out_value threshold)" = "" ]; then
  pass "the same guard applies to every scalar, not just the identity (unterminated threshold emits nothing)"
else
  fail "unterminated quoted threshold emitted '$(out_value threshold)'"
fi

# Non-vacuity: the file really was fetched and parsed. Without this, both
# assertions above would also hold on the fail-closed branch, which empties
# every scalar for an unrelated reason.
if [ "$(out_value reviewers)" = '["nathanpayne-codex"]' ] \
   && [ "$(out_value paths)" = '["release/**"]' ]; then
  pass "the torn policy was still resolved and its list keys parsed (the empty scalars are not the fail-closed branch)"
else
  fail "torn policy mis-parsed its list keys (reviewers=$(out_value reviewers) paths=$(out_value paths))"
fi

# ---------------------------------------------------------------------------
# 4. Resolver failure on a non-default base: FAIL CLOSED but exit 0.
#    reviewers=[] is the operative guard — `assign` assigns nobody and the
#    auto-merge arming gate rejects every approver. threshold=0 makes triage's
#    preliminary calculation require external review. Exit 0 keeps `triage`
#    from being SKIPPED, which would be fail-open (#59's class).
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=error
run_loader release/1.x main
if [ "$RC" -eq 0 ] \
   && [ "$(out_value reviewers)" = "[]" ] \
   && [ "$(out_value paths)" = "[]" ] \
   && [ "$(out_value threshold)" = "0" ] \
   && [ "$(out_value author_identity)" = "" ]; then
  pass "unreadable base policy emits fail-closed outputs and stays green (#788)"
else
  fail "fail-closed path (rc=$RC threshold=$(out_value threshold) reviewers=$(out_value reviewers) author=$(out_value author_identity))"
fi

if printf '%s' "$LOG" | grep -q '::warning::'; then
  pass "the fail-closed path annotates the run rather than failing silently"
else
  fail "fail-closed path emitted no ::warning:: annotation: $LOG"
fi

# The fail-closed values must never come from the default-branch policy: that
# substitution is precisely the bypass #768/#769 closed.
if [ "$(out_value reviewers)" != '["nathanpayne-claude","nathanpayne-cursor"]' ]; then
  pass "an unreadable base policy never silently falls back to the default-branch identities (#768 P1)"
else
  fail "unreadable base policy fell back to the default-branch reviewer list"
fi

# ---------------------------------------------------------------------------
# 5. The `load-config` STEP as the runner executes it — bootstrap skew.
#
#    The step's `actions/checkout` is pinned to the DEFAULT branch so the
#    helper code is trusted. That makes the helper's own absence a reachable
#    state twice: on the PR that introduces it, and on each consumer's first
#    sync wave (.mergepath-sync.yml makes agent-review.yml and
#    scripts/workflow/ travel together, but they land IN that PR, not on the
#    consumer's default branch before it runs). An unguarded `bash <missing
#    file>` exits 127 and hard-fails the job, which SKIPS `triage`
#    (`needs: [load-config]`, no `always()`) and `auto-merge-on-approval` —
#    the fail-OPEN outcome the loader's own fail-closed handling exists to
#    prevent.
#
#    The step's shell is LIFTED VERBATIM out of the workflow rather than
#    retyped here, so this executes the bytes the runner would execute; a copy
#    would keep passing while the workflow itself was broken.
# ---------------------------------------------------------------------------
WORKFLOW="$ROOT/.github/workflows/agent-review.yml"
STEP="$WORK/load-config-step.sh"

awk '
  /^  load-config:/            { injob = 1; next }
  injob && /^  [A-Za-z._-]+:/  { injob = 0 }
  injob && /^        run: \|$/ { inrun = 1; next }
  inrun && /^          /       { print substr($0, 11); next }
  inrun && /^[[:space:]]*$/    { print ""; next }
  inrun                        { inrun = 0 }
' "$WORKFLOW" > "$STEP"

if [ -s "$STEP" ] && grep -q 'load_review_config.sh' "$STEP"; then
  pass "lifted the load-config run block out of agent-review.yml"
else
  fail "could not lift the load-config run block out of $WORKFLOW — sections 5a/5b assert nothing"
fi

# The Actions default shell for a `run:` block is `bash -e {0}`.
run_step() {  # <tree> <base_ref> <default_branch> ; sets SRC / STEP_OUT / STEP_LOG
  STEP_OUT="$WORK/step-output.txt"
  : > "$STEP_OUT"
  : > "$CALLS_LOG"
  STEP_LOG=$(cd "$1" && GITHUB_OUTPUT="$STEP_OUT" REPO="$REPO" BASE_REF="$2" \
    BASE_SHA="basesha1" DEFAULT_BRANCH="$3" bash -e "$STEP" 2>&1) && SRC=0 || SRC=$?
}

# 5a. Default-branch tree that predates the helper: soft-pass, fail-closed.
BOOT_TREE="$WORK/bootstrap-tree"
mkdir -p "$BOOT_TREE/.github"
cp "$DEFAULT_CONFIG" "$BOOT_TREE/.github/review-policy.yml"

run_step "$BOOT_TREE" main main
if [ "$SRC" -eq 0 ] \
   && [ "$(val_in "$STEP_OUT" reviewers)" = "[]" ] \
   && [ "$(val_in "$STEP_OUT" paths)" = "[]" ] \
   && [ "$(val_in "$STEP_OUT" threshold)" = "0" ] \
   && [ "$(val_in "$STEP_OUT" author_identity)" = "" ]; then
  pass "a default-branch tree without the helper soft-passes with fail-closed outputs, so triage is not skipped (#788 bootstrap)"
else
  fail "bootstrap skew (rc=$SRC threshold=$(val_in "$STEP_OUT" threshold) paths=$(val_in "$STEP_OUT" paths) reviewers=$(val_in "$STEP_OUT" reviewers) author=$(val_in "$STEP_OUT" author_identity)): $STEP_LOG"
fi

if [ "$(grep -c '' "$STEP_OUT" | tr -d ' ')" = "4" ]; then
  pass "the bootstrap soft-pass emits exactly the four load-config outputs"
else
  fail "bootstrap soft-pass output shape: $(cat "$STEP_OUT")"
fi

# 5b. Positive control. The same lifted step against a tree that DOES carry the
#     helper must run it and export the real policy values — otherwise 5a would
#     pass just as well against a step that always short-circuits.
LIVE_TREE="$WORK/live-tree"
mkdir -p "$LIVE_TREE/.github" "$LIVE_TREE/scripts"
cp "$DEFAULT_CONFIG" "$LIVE_TREE/.github/review-policy.yml"
cp -R "$ROOT/scripts/workflow" "$LIVE_TREE/scripts/workflow"

run_step "$LIVE_TREE" main main
if [ "$SRC" -eq 0 ] \
   && [ "$(val_in "$STEP_OUT" threshold)" = "300" ] \
   && [ "$(val_in "$STEP_OUT" paths)" = '["src/auth/**",".github/**"]' ] \
   && [ "$(val_in "$STEP_OUT" reviewers)" = '["nathanpayne-claude","nathanpayne-cursor"]' ] \
   && [ "$(val_in "$STEP_OUT" author_identity)" = "nathanjohnpayne" ]; then
  pass "the same step against a tree carrying the helper exports the real policy values (the guard is not an unconditional short circuit)"
else
  fail "positive control (rc=$SRC threshold=$(val_in "$STEP_OUT" threshold) paths=$(val_in "$STEP_OUT" paths) reviewers=$(val_in "$STEP_OUT" reviewers) author=$(val_in "$STEP_OUT" author_identity)): $STEP_LOG"
fi

if ! grep -q . "$CALLS_LOG"; then
  pass "the step's default-base path makes ZERO gh API calls end to end (#769 short circuit preserved through the workflow)"
else
  fail "the step made API calls on a default-base PR: $(cat "$CALLS_LOG")"
fi

# ---------------------------------------------------------------------------
# 6. The CONSUMER of `author_identity` that gates a real merge: the auto-merge
#    job's `Check author merge token` step, as the runner executes it.
#
#    Exporting the identity from the governing policy is only half of #788. The
#    step that decides whether AUTHOR_MERGE_TOKEN may call `gh pr merge` parsed
#    `author_identity` out of its OWN checkout, and that job's
#    `actions/checkout` carries no `ref:` — on a `pull_request` event it is
#    `refs/pull/N/merge`, the PR's own copy of the policy, and on a
#    `pull_request_review` event it is a different file again. Two answers for
#    one PR, neither of them the base branch's.
#
#    So the assertions below are about SOURCE, not about parsing: each runs the
#    lifted step inside a tree whose `.github/review-policy.yml` names
#    `nathanjohnpayne`, and varies only the load-config output. A step that
#    still reads the checked-out file agrees with itself in every case and
#    fails 6a and 6b.
#
#    Lifted from the workflow rather than retyped, for the same reason as
#    section 5: a copy keeps passing while the shipped step is broken.
# ---------------------------------------------------------------------------
STEP2="$WORK/author-token-step.sh"

awk '
  /^      - name: Check author merge token$/ { instep = 1; next }
  instep && /^      - name: /                { instep = 0 }
  instep && /^        run: \|$/              { inrun = 1; next }
  inrun && /^          /                     { print substr($0, 11); next }
  inrun && /^[[:space:]]*$/                  { print ""; next }
  inrun                                      { inrun = 0 }
' "$WORKFLOW" > "$STEP2"

if [ -s "$STEP2" ] && grep -q 'AUTHOR_MERGE_TOKEN' "$STEP2"; then
  pass "lifted the auto-merge author-token step out of agent-review.yml"
else
  fail "could not lift the author-token run block out of $WORKFLOW — section 6 asserts nothing"
fi

AUTH_TREE="$WORK/auth-tree"
mkdir -p "$AUTH_TREE/.github"
cp "$DEFAULT_CONFIG" "$AUTH_TREE/.github/review-policy.yml"   # names nathanjohnpayne

# <expected_author> <token_login> ; sets ASRC / ASTEP_OUT / ASTEP_LOG
run_author_step() {
  ASTEP_OUT="$WORK/author-step-output.txt"
  : > "$ASTEP_OUT"
  ASTEP_LOG=$(cd "$AUTH_TREE" && GITHUB_OUTPUT="$ASTEP_OUT" GH_TOKEN="stub-author-token" \
    EXPECTED_AUTHOR="$1" STUB_TOKEN_LOGIN="$2" BASE_REF="release/1.x" \
    bash -e "$STEP2" 2>&1) && ASRC=0 || ASRC=$?
}

# 6a. The governing (base) policy names a different identity than the checked-out
#     one, and the token is the checked-out one's. Refuse.
run_author_step "release-bot" "nathanjohnpayne"
if [ "$ASRC" -ne 0 ] && [ "$(val_in "$ASTEP_OUT" enabled)" != "true" ]; then
  pass "a token that does not match the BASE policy's author_identity is refused, even when the checked-out policy names it (#788)"
else
  fail "base-policy mismatch was not refused (rc=$ASRC enabled=$(val_in "$ASTEP_OUT" enabled)): $ASTEP_LOG"
fi

# 6b. load-config could not prove the governing policy (its fail-closed output
#     is an empty author_identity). Disable the merge path; do NOT fall back to
#     a hard-coded login, which is the substitution #768/#769/#788 close.
run_author_step "" "nathanjohnpayne"
if [ "$ASRC" -eq 0 ] && [ "$(val_in "$ASTEP_OUT" enabled)" = "false" ]; then
  pass "an unproven author_identity disables automatic merge rather than defaulting to a hard-coded login (#788 fail-closed)"
else
  fail "unproven identity path (rc=$ASRC enabled=$(val_in "$ASTEP_OUT" enabled)): $ASTEP_LOG"
fi

# 6c. Positive control against a step that simply always disables: the ordinary
#     fleet case, where the governing policy IS the checked-out one.
run_author_step "nathanjohnpayne" "nathanjohnpayne"
if [ "$ASRC" -eq 0 ] && [ "$(val_in "$ASTEP_OUT" enabled)" = "true" ]; then
  pass "a token matching the governing author_identity still enables automatic merge (#788 no-regression)"
else
  fail "positive control (rc=$ASRC enabled=$(val_in "$ASTEP_OUT" enabled)): $ASTEP_LOG"
fi

# 6d. The mirror of 6a, against a step hard-wired to expect nathanjohnpayne: a
#     base policy naming release-bot, with a token that IS release-bot, merges —
#     the checked-out policy's nathanjohnpayne is not consulted in either
#     direction.
run_author_step "release-bot" "release-bot"
if [ "$ASRC" -eq 0 ] && [ "$(val_in "$ASTEP_OUT" enabled)" = "true" ]; then
  pass "a token matching a NON-default base policy's author_identity is accepted (the identity comes from the policy, not from a hard-coded name)"
else
  fail "non-default base identity accepted path (rc=$ASRC enabled=$(val_in "$ASTEP_OUT" enabled)): $ASTEP_LOG"
fi

# 6e. The two halves joined: the loader's real output for a governing policy
#     that names no author_identity is handed to the lifted merge-gate step,
#     exactly as `needs.load-config.outputs.author_identity` hands it over.
#
#     Sections 3d and 6b each pin one end and can both pass while the pipeline
#     still merges: 6b feeds a hand-written empty string, so it never observes
#     what the loader actually produces. Here the value is not written by this
#     test at all. If the loader substitutes a login, EXPECTED_AUTHOR arrives
#     non-empty, the token (which IS that login) matches, and automatic merge is
#     enabled under an identity the governing policy never named.
export STUB_CONTENTS_MODE=noauth
run_loader release/1.x main
run_author_step "$(out_value author_identity)" "nathanjohnpayne"
if [ "$ASRC" -eq 0 ] && [ "$(val_in "$ASTEP_OUT" enabled)" = "false" ]; then
  pass "a governing policy naming no author_identity disables automatic merge end to end, loader output through merge gate (#788)"
else
  fail "end-to-end missing-identity path enabled the merge (rc=$ASRC enabled=$(val_in "$ASTEP_OUT" enabled)): $ASTEP_LOG"
fi

# 6f. The same end-to-end join for the torn-quote route, and the one where the
#     consequence is worst: here the value the extraction would have invented is
#     a REAL login (`nathanjohnpayne`, the fleet's author identity), so a step
#     fed that value matches its own token and merges. Nothing in this test
#     writes the identity — it is whatever the loader produced from a malformed
#     policy — so section 3e alone cannot stand in for it.
export STUB_CONTENTS_MODE=torn
run_loader release/1.x main
run_author_step "$(out_value author_identity)" "nathanjohnpayne"
if [ "$ASRC" -eq 0 ] && [ "$(val_in "$ASTEP_OUT" enabled)" = "false" ]; then
  pass "a governing policy with an unterminated quoted author_identity disables automatic merge end to end (CodeRabbit, #973)"
else
  fail "end-to-end torn-quote path enabled the merge (rc=$ASRC enabled=$(val_in "$ASTEP_OUT" enabled)): $ASTEP_LOG"
fi

echo
echo "== load_review_config (#788) tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
