#!/usr/bin/env bash
# Unit tests for scripts/hooks/gh-pr-guard.sh under the #411
# wrapper-mandatory token contract.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/gh-pr-guard.sh"

[[ -x "$HOOK" ]] || { echo "missing or non-executable $HOOK" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-guard-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "config get")
    echo "${STUB_ACTIVE_USER:-nathanpayne-claude}"
    exit 0
    ;;
  "pr view")
    json_fields=""
    for ((i=1; i<=$#; i++)); do
      if [ "${!i}" = "--json" ]; then
        next=$((i+1))
        json_fields="${!next}"
        break
      fi
    done
    case "$json_fields" in
      *body*)
        printf '%s\n' "${STUB_PR_BODY:-}"
        printf '"additions": %s\n' "${STUB_PR_ADDITIONS:-0}"
        printf '"deletions": %s\n' "${STUB_PR_DELETIONS:-0}"
        printf '"head": "%s"\n' "${STUB_PR_HEAD:-feature/some-branch}"
        printf '"author": "%s"\n' "${STUB_PR_AUTHOR:-nathanjohnpayne}"
        exit 0
        ;;
      *)
        echo "${STUB_MERGE_STATE:-CLEAN}"
        if [ -n "${STUB_LABELS:-}" ]; then
          echo "$STUB_LABELS" | tr ';' '\n'
        fi
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

run_hook() {
  local cmd="$1"
  local merge_state="${2:-CLEAN}"
  local labels="${3:-}"
  local expected_reviewer="${4:-nathanpayne-claude}"
  local pr_body="${5:-}"
  local additions="${6:-0}"
  local deletions="${7:-0}"
  local pr_head="${8:-feature/some-branch}"
  local pr_author="${9:-nathanjohnpayne}"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  PATH="$STUB_DIR:$PATH" \
  STUB_MERGE_STATE="$merge_state" \
  STUB_LABELS="$labels" \
  STUB_PR_BODY="$pr_body" \
  STUB_PR_ADDITIONS="$additions" \
  STUB_PR_DELETIONS="$deletions" \
  STUB_PR_HEAD="$pr_head" \
  STUB_PR_AUTHOR="$pr_author" \
  GH_PR_GUARD_EXPECTED_REVIEWER="$expected_reviewer" \
    bash "$HOOK" <<<"$payload"
}

assert_rc_contains() {
  local label="$1" expected_rc="$2" needle="$3"; shift 3
  local out rc
  set +e
  out=$(run_hook "$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    fail "$label: rc=$rc expected $expected_rc; output: $out"
  elif [ -n "$needle" ] && ! echo "$out" | grep -qi "$needle"; then
    fail "$label: missing '$needle'; output: $out"
  else
    pass "$label"
  fi
}

assert_rc_contains "direct pr create blocked" 2 "token-verifying wrapper" \
  'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "inline-token pr create blocked" 2 "not hook-verifiable" \
  'GH_TOKEN=author-token gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "wrapper substring spoof still blocked" 2 "token-verifying wrapper" \
  'echo scripts/gh-as-author.sh && gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

# #466: a path-qualified gh (e.g. /usr/bin/gh) must NOT bypass the guard.
# Before the fix the quick-exit grep only matched bare `gh`, so a
# path-qualified write skipped the hook entirely (exit 0).
assert_rc_contains "path-qualified gh pr create blocked (#466)" 2 "token-verifying wrapper" \
  '/usr/bin/gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "path-qualified gh pr merge blocked (#466)" 2 "" \
  '/usr/bin/gh pr merge 123 --squash --delete-branch'

# #466 r2: a QUOTED path-qualified (or bare) gh must not bypass either.
# The closing quote glued to `gh` previously slipped past the quick-exit
# grep boundary (verified live by the nathanpayne-codex review).
assert_rc_contains "quoted path-qualified gh pr merge blocked (#466 r2)" 2 "" \
  "'/usr/bin/gh' pr merge 123 --squash --delete-branch"

assert_rc_contains "quoted bare gh pr merge blocked (#466 r2)" 2 "" \
  "'gh' pr merge 5 --squash"

assert_rc_contains "wrapper state does not cross separator" 2 "token-verifying wrapper" \
  'scripts/gh-as-author.sh -- echo ok ; gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "non-canonical author wrapper path blocked" 2 "non-canonical" \
  '/tmp/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "bare reviewer wrapper command blocked" 2 "non-canonical" \
  'gh-as-reviewer.sh -- gh pr review 123 --comment --body "review"'

assert_rc_contains "wrapper non-guarded then bare guarded compound blocked" 2 "#348" \
  'scripts/gh-as-author.sh -- gh pr view 123 && gh pr merge 123 --squash'

assert_rc_contains "author wrapper pr create valid body allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper pr create missing body blocked" 2 "Self-Review" \
  'scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude"'

assert_rc_contains "reviewer wrapper pr create blocked" 2 "author token" \
  'scripts/gh-as-reviewer.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper pr merge clean allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "direct pr merge blocked" 2 "token-verifying wrapper" \
  'gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper pr merge blocked state" 2 "mergeStateStatus is BLOCKED" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

assert_rc_contains "author wrapper pr merge human-hold blocks" 2 "human-hold" \
  'CODEX_CLEARED=1 BREAK_GLASS_ADMIN=1 BREAK_GLASS_MERGE_STATE=1 scripts/gh-as-author.sh -- gh pr merge 123 --admin --squash' "DIRTY" "human-hold"

assert_rc_contains "direct pr comment blocked" 2 "token-verifying wrapper" \
  'gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper pr comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper identity mismatch blocked" 2 "not expected reviewer" \
  'GH_AS_REVIEWER_IDENTITY=nathanpayne-codex scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "author wrapper normal pr comment blocked" 2 "reviewer token" \
  'scripts/gh-as-author.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "author wrapper codex trigger allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"'

assert_rc_contains "author wrapper codex trigger echo spoof blocked" 2 "reviewer token" \
  'echo "@codex review" && scripts/gh-as-author.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper pr review comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --comment --body "review"'

assert_rc_contains "direct issue comment blocked" 2 "token-verifying wrapper" \
  'gh issue comment 7 --body "thanks"'

assert_rc_contains "reviewer wrapper issue comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh issue comment 7 --body "thanks"'

assert_rc_contains "author wrapper issue comment blocked" 2 "reviewer token" \
  'scripts/gh-as-author.sh -- gh issue comment 7 --body "thanks"'

assert_rc_contains "direct pr edit blocked" 2 "token-verifying wrapper" \
  'gh pr edit 123 --title "new"'

assert_rc_contains "author wrapper pr edit allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr edit 123 --title "new"'

assert_rc_contains "reviewer wrapper pr edit blocked" 2 "author token" \
  'scripts/gh-as-reviewer.sh -- gh pr edit 123 --title "new"'

assert_rc_contains "self-approve over-threshold blocked from wrapper identity" 2 "self-approve detected" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "lgtm"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0"

assert_rc_contains "cross-agent approve allowed" 0 "" \
  'GH_AS_REVIEWER_IDENTITY=nathanpayne-codex scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "lgtm"' "CLEAN" "" "nathanpayne-codex" "Authoring-Agent: claude" "5000" "0"

ORIG_DIR="$(pwd)"
mkdir -p "$WORKDIR/repo-with-policy/.github"
cat >"$WORKDIR/repo-with-policy/.github/review-policy.yml" <<'YML'
external_review_threshold: 500
YML
cd "$WORKDIR/repo-with-policy"
assert_rc_contains "same-agent under-threshold approve allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "small"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "10" "5"
cd "$ORIG_DIR"

assert_rc_contains "compound direct guarded write blocked" 2 "#348" \
  'gh issue close 7 && gh pr merge --admin 123'

# --- author-wrapper identity pin (#438) -------------------------------

assert_rc_contains "author wrapper inline non-author identity blocked" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper inline matching author identity allowed" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanjohnpayne scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper inline non-author identity blocked on pr create" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-cursor scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper inline non-author identity blocked on codex trigger" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"'

# A stale inline assignment scoped to an EARLIER command segment must
# not leak into the author byline guard — the shell would not pass it
# to the wrapper (Codex P2 on PR #442).
assert_rc_contains "stale inline author identity from earlier segment does not block" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex echo ok ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# A standalone assignment (no command in its segment) persists as a
# shell variable, and IF the name carries the export attribute in the
# calling shell it ALSO reaches the wrapper (Codex P1 on PR #442 r4).
# The hook cannot observe the export attribute, so a standalone
# non-author value must fail closed even though it might be inert.
assert_rc_contains "standalone non-author identity assignment fails closed" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# ...but a standalone assignment of the EXPECTED author is fine either
# way (exported: wrapper gets the expected value; unexported: wrapper
# default is the same value).
assert_rc_contains "standalone matching author identity assignment allowed" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanjohnpayne ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# `export VAR=x ; wrapper` is DEFINITELY effective — the assignment is
# an argument of the export command, not a bare prefix, and reaches
# every later process (Codex P1 on PR #442 r11).
assert_rc_contains "exported-via-export-command non-author identity blocked" 2 "author identity" \
  'export GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "exported-via-export-command matching author identity allowed" 0 "" \
  'export GH_AS_AUTHOR_IDENTITY=nathanjohnpayne && scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "exported-via-export-command non-reviewer identity blocked" 2 "expected reviewer" \
  'export GH_AS_REVIEWER_IDENTITY=nathanpayne-codex ; scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"' "CLEAN" ""

# Prefix-assignment BEFORE the export command in the same segment
# (`VAR=x export VAR`) persists AND exports (Codex P1 on PR #442 r12).
assert_rc_contains "prefix-then-export non-author identity blocked" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex export GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"' "CLEAN" ""

assert_rc_contains "prefix-then-export matching author identity allowed" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanjohnpayne export GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# declare -x is export-equivalent (Codex P1 r12 family, preempted).
assert_rc_contains "declare -x non-author identity blocked" 2 "author identity" \
  'declare -x GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# env-prefix on the wrapper command is a definitive same-segment prefix.
assert_rc_contains "env-prefixed non-author identity blocked" 2 "author identity" \
  'env GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# eval'd assignments persist like bare standalones (preempted, r14
# family): possibly-effective, so a mismatch fails closed.
assert_rc_contains "eval'd non-author identity assignment fails closed" 2 "author identity" \
  'eval GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# readonly -x exports too (Codex P1 on PR #442 r14, hook-verified).
assert_rc_contains "readonly -x non-author identity blocked" 2 "author identity" \
  'readonly -x GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"' "CLEAN" ""

# The custom-author shape from the r3 finding: standalone assignment of
# the CUSTOM identity must NOT satisfy the guard — the wrapper would
# actually verify its stock default.
mkdir -p "$WORKDIR/repo-custom-author-standalone/.github"
cat >"$WORKDIR/repo-custom-author-standalone/.github/review-policy.yml" <<'YML'
author_identity: custom-owner
YML
cd "$WORKDIR/repo-custom-author-standalone"
assert_rc_contains "standalone custom-identity assignment does not mask the wrapper default" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner && scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# Exported (non-inline) GH_AS_AUTHOR_IDENTITY must be caught too — the
# wrapper reads its environment, so the hook must read the same.
set +e
out=$(GH_AS_AUTHOR_IDENTITY=nathanpayne-codex run_hook 'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "author wrapper exported non-author identity blocked"
else
  fail "author wrapper exported non-author identity blocked: rc=$rc; output: $out"
fi

# The expected author defaults from review-policy.yml author_identity
# when GH_PR_GUARD_EXPECTED_AUTHOR is unset (Codex P2 on PR #442 r2) —
# custom-author repos need no hook-specific variable.
mkdir -p "$WORKDIR/repo-custom-author/.github"
cat >"$WORKDIR/repo-custom-author/.github/review-policy.yml" <<'YML'
author_identity: custom-owner
YML
cd "$WORKDIR/repo-custom-author"
assert_rc_contains "author identity from review-policy.yml allows matching wrapper identity" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
assert_rc_contains "author identity from review-policy.yml blocks the stock default" 2 "author identity" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# An EMPTY inline override resets the wrapper to its hardcoded default
# (Codex P1 on PR #442 r15): in a custom-author repo that is a
# wrong-byline reset and must fail closed, even when the hook's own
# environment carries the correct custom identity.
mkdir -p "$WORKDIR/repo-custom-author-empty/.github"
cat >"$WORKDIR/repo-custom-author-empty/.github/review-policy.yml" <<'YML'
author_identity: custom-owner
YML
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'GH_AS_AUTHOR_IDENTITY= scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "empty inline author override fails closed in custom-author repo"
else
  fail "empty inline author override fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

# env -u / --unset / -i remove the identity from the WRAPPER's
# environment — the r15 empty-override semantics (Codex P2 r17).
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env -u GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "env -u identity unset fails closed in custom-author repo"
else
  fail "env -u identity unset fails closed in custom-author repo: rc=$rc; output: $out"
fi
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env --unset=GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "env --unset= identity fails closed in custom-author repo"
else
  fail "env --unset= identity fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

assert_rc_contains "env -u identity unset allowed in default repo" 0 "" \
  'env -u GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# Space-separated long form: `env --unset NAME` (Codex P1 r18) — the
# value flag must be consumed or the walk loses the wrapper entirely
# and skips ALL checks.
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env --unset GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "env --unset NAME (space form) fails closed in custom-author repo"
else
  fail "env --unset NAME (space form) fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

# ...and in a default repo the walk must still SEE the wrapper and
# evaluate the merge-state checks (BLOCKED state proves the walk
# reached the merge guard rather than bailing at the unset arg).
assert_rc_contains "env --unset NAME still reaches merge-state checks" 2 "mergeStateStatus is BLOCKED" \
  'env --unset GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

# Compact `env -uNAME` form (#451) — flag and name attached, no `=`.
# prefix_flag_takes_value matches only the bare `-u`, so this token would
# fall through as a boolean flag unless the case block models it
# explicitly. Same r15 empty-override semantics as `env -u NAME`.
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env -uGH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "#451: env -uNAME (compact) author unset fails closed in custom-author repo"
else
  fail "#451: env -uNAME (compact) author unset fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

# ...and in a default repo the compact form must still reach the merge-state
# checks (BLOCKED proves the walk didn't bail at the unset arg and skip checks).
assert_rc_contains "#451: env -uNAME (compact) author unset reaches merge-state checks in default repo" 2 "mergeStateStatus is BLOCKED" \
  'env -uGH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

# Reviewer analog: the compact unset falls the wrapper back to its default
# reviewer; with a different expected reviewer that must fail closed.
assert_rc_contains "#451: env -uNAME (compact) reviewer unset fails closed vs different expected reviewer" 2 "not expected reviewer" \
  'env -uGH_AS_REVIEWER_IDENTITY scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"' "CLEAN" "" "nathanpayne-codex"

# The unset BUILTIN persists past separators (preempted, r17 family).
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'unset GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "unset builtin identity removal fails closed in custom-author repo"
else
  fail "unset builtin identity removal fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

assert_rc_contains "unset builtin identity removal allowed in default repo" 0 "" \
  'unset GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# In a DEFAULT repo an empty override is a no-op (wrapper default ==
# expected) and must not block.
assert_rc_contains "empty inline author override allowed in default repo" 0 "" \
  'GH_AS_AUTHOR_IDENTITY= scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# Subdirectory invocation: the policy is found by upward walk (r21).
mkdir -p "$WORKDIR/repo-custom-author/subdir"
cd "$WORKDIR/repo-custom-author/subdir"
assert_rc_contains "author identity policy found from a subdirectory" 2 "author identity" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# Quoted author_identity is valid YAML — double AND single quotes must
# be stripped before comparison (Codex P2s on PR #442 r6/r7).
mkdir -p "$WORKDIR/repo-quoted-author/.github"
cat >"$WORKDIR/repo-quoted-author/.github/review-policy.yml" <<'YML'
author_identity: "custom-owner"
YML
cd "$WORKDIR/repo-quoted-author"
assert_rc_contains "double-quoted author_identity allows matching wrapper identity" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

mkdir -p "$WORKDIR/repo-squoted-author/.github"
cat >"$WORKDIR/repo-squoted-author/.github/review-policy.yml" <<'YML'
author_identity: 'custom-owner'
YML
cd "$WORKDIR/repo-squoted-author"
assert_rc_contains "single-quoted author_identity allows matching wrapper identity" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# Custom expected author: identity must match the override...
set +e
out=$(GH_PR_GUARD_EXPECTED_AUTHOR=custom-owner run_hook 'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "author wrapper custom expected author with matching identity allowed"
else
  fail "author wrapper custom expected author with matching identity allowed: rc=$rc; output: $out"
fi

# ...and an UNSET identity fails closed under a custom expected author,
# because the wrapper would verify its stock default (nathanjohnpayne),
# not the override.
set +e
out=$(GH_PR_GUARD_EXPECTED_AUTHOR=custom-owner run_hook 'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "author wrapper unset identity under custom expected author fails closed"
else
  fail "author wrapper unset identity under custom expected author fails closed: rc=$rc; output: $out"
fi

echo ""
echo "test_gh_pr_guard: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
