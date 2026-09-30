#!/usr/bin/env bash
# Unit tests for scripts/gh-as-reviewer.sh token-based attribution.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/gh-as-reviewer.sh"

[[ -x "$WRAPPER" ]] || { echo "missing or non-executable $WRAPPER" >&2; exit 1; }

# #996: same scrub as tests/test_gh_as_author.sh — the gh stub records the
# token the wrapper selected and failure branches print that log, so the
# ambient OP_PREFLIGHT_REVIEWER_PAT / GH_TOKEN of an agent session must not
# be a candidate. Per-case `VAR=...` prefixes still apply.
unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT GH_TOKEN GITHUB_TOKEN

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-reviewer-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
printf 'GH_TOKEN=%s GITHUB_TOKEN=%s gh' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" >> "$LOG"  # TOKEN_OUTPUT_EXEMPT: records the token the wrapper selected, which every case pins inline and asserts on exactly; the ambient credential env is scrubbed above (#996)
for a in "$@"; do
  printf '\t%s' "$a" >> "$LOG"
done
printf '\n' >> "$LOG"

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "switch" ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  user=""
  shift 2
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--user" ]; then
      shift
      user="${1:-}"
      break
    fi
    shift
  done
  case "$user" in
    nathanpayne-claude) printf '%s\n' "gho_fallback-claude-token" ;;
    nathanpayne-codex) printf '%s\n' "gho_fallback-codex-token" ;;
    *) exit 3 ;;
  esac
  exit 0
fi

# --- byline readback surface (#1057) ---------------------------------
# The wrapper resolves the target through `gh <pr|issue> view`, snapshots
# reviews before a review, and reads the written object back afterwards. The
# stub records who each write landed as: the login of the token it ran under,
# or STUB_WRITE_AS when a case simulates a brokered credential.
STATE="${STUB_STATE:-/dev/null}"
login_for() {
  case "$1" in
    ghp_reviewer-token|gho_fallback-claude-token) echo nathanpayne-claude ;;
    ghp_codex-token|gho_fallback-codex-token) echo nathanpayne-codex ;;
    ghp_author-token) echo nathanjohnpayne ;;
    proxy-injected) echo nathanjohnpayne ;;
  esac
}
if { [ "${1:-}" = "pr" ] || [ "${1:-}" = "issue" ]; } && [ "${2:-}" = "view" ]; then
  [ "${STUB_VIEW_RC:-0}" = 0 ] || exit "$STUB_VIEW_RC"
  num=123
  case "${3:-}" in [0-9]*) num="$3" ;; esac
  kind=pull; [ "$1" = issue ] && kind=issues
  echo "$num https://github.com/o/r/$kind/$num"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "review" ]; then
  [ "${GH_GENERIC_RC:-0}" = 0 ] || exit "$GH_GENERIC_RC"
  echo "${STUB_WRITE_AS:-$(login_for "${GH_TOKEN:-}")}" >"$STATE/review"
  exit 0
fi
if { [ "${1:-}" = "pr" ] || [ "${1:-}" = "issue" ]; } && [ "${2:-}" = "comment" ]; then
  [ "${GH_GENERIC_RC:-0}" = 0 ] || exit "$GH_GENERIC_RC"
  echo "${STUB_WRITE_AS:-$(login_for "${GH_TOKEN:-}")}" >"$STATE/comment"
  kind=pull; [ "$1" = issue ] && kind=issues
  echo "https://github.com/o/r/$kind/${3:-1}#issuecomment-900"
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case "$*" in
    *"/reviews"*"select(.id >"*) cat "$STATE/review" 2>/dev/null; exit 0 ;;
    *"/reviews"*) echo 1; exit 0 ;;
    *"issues/comments/900"*) cat "$STATE/comment" 2>/dev/null; exit 0 ;;
  esac
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  case "${GH_TOKEN:-}" in
    ghp_reviewer-token|gho_fallback-claude-token) printf '%s\n' "nathanpayne-claude" ;;
    ghp_codex-token|gho_fallback-codex-token) printf '%s\n' "nathanpayne-codex" ;;
    ghp_author-token) printf '%s\n' "nathanjohnpayne" ;;
    proxy-injected) printf '%s\n' "nathanjohnpayne" ;;  # the #1057 placeholder READS as the human
    *) exit 4 ;;
  esac
  exit 0
fi

exit "${GH_GENERIC_RC:-0}"
STUB
chmod +x "$STUB_DIR/gh"

mkdir -p "$WORKDIR/state"
run_wrapper() {
  PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" STUB_STATE="$WORKDIR/state" "$WRAPPER" "$@"
}

reset_log() {
  : > "$WORKDIR/calls.log"
  rm -f "$WORKDIR/state/"*
}

reset_log
set +e
OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" GITHUB_TOKEN="ambient-token" \
  run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "review happy path: rc=$rc"
elif grep -q $'gh\tauth\tswitch' "$WORKDIR/calls.log"; then
  fail "review happy path: called gh auth switch"
elif ! grep -q $'GH_TOKEN=ghp_reviewer-token GITHUB_TOKEN= gh\tpr\treview\t123\t--comment' "$WORKDIR/calls.log"; then
  fail "review happy path: wrapped command did not run with reviewer token and GITHUB_TOKEN unset"
  cat "$WORKDIR/calls.log" >&2
else
  pass "review happy path: verified reviewer token, no keyring switch"
fi

reset_log
set +e
MERGEPATH_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" \
  run_wrapper -- gh issue comment 7 --body "thanks" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "MERGEPATH_AGENT fallback: rc=$rc"
elif ! grep -q $'GH_TOKEN=ghp_codex-token GITHUB_TOKEN= gh\tissue\tcomment\t7' "$WORKDIR/calls.log"; then
  fail "MERGEPATH_AGENT fallback: did not use codex token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "MERGEPATH_AGENT fallback: resolves nathanpayne-codex"
fi

reset_log
set +e
OP_PREFLIGHT_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" \
  run_wrapper -- gh issue comment 8 --body "thanks" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "OP_PREFLIGHT_AGENT fallback: rc=$rc"
elif ! grep -q $'GH_TOKEN=ghp_codex-token GITHUB_TOKEN= gh\tissue\tcomment\t8' "$WORKDIR/calls.log"; then
  fail "OP_PREFLIGHT_AGENT fallback: did not use codex token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "OP_PREFLIGHT_AGENT fallback: resolves nathanpayne-codex"
fi

reset_log
set +e
GH_AS_REVIEWER_IDENTITY=nathanpayne-codex OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" \
  run_wrapper -- gh pr comment 123 --body "ping" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "explicit identity: rc=$rc"
elif ! grep -q $'GH_TOKEN=ghp_codex-token GITHUB_TOKEN= gh\tpr\tcomment\t123' "$WORKDIR/calls.log"; then
  fail "explicit identity: did not use codex token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "explicit identity: GH_AS_REVIEWER_IDENTITY wins"
fi

reset_log
unset OP_PREFLIGHT_REVIEWER_PAT
set +e
run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fallback token: rc=$rc"
elif ! grep -q $'GH_TOKEN=gho_fallback-claude-token GITHUB_TOKEN= gh\tpr\treview' "$WORKDIR/calls.log"; then
  fail "fallback token: did not use gh auth token --user"
  cat "$WORKDIR/calls.log" >&2
else
  pass "fallback token: uses gh auth token --user without switching"
fi

reset_log
set +e
OP_PREFLIGHT_REVIEWER_PAT="ghp_author-token" run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "wrong preferred token: expected non-zero"
elif grep -q $'gh\tpr\treview' "$WORKDIR/calls.log"; then
  fail "wrong preferred token: wrapped write ran despite failed verification"
  cat "$WORKDIR/calls.log" >&2
else
  pass "wrong preferred token: fails before wrapped write"
fi

# --- ambient GH_TOKEN candidate (#533) --------------------------------
# A verified ambient GH_TOKEN (no OP_PREFLIGHT_*, picked up before the
# keyring fallback) must be used directly. ghp_reviewer-token verifies as
# nathanpayne-claude (the default reviewer). We assert the wrapped write
# ran with the AMBIENT token value, NOT the keyring's gho_fallback-claude-token
# — proving candidate 2 won, not candidate 3.
reset_log
unset OP_PREFLIGHT_REVIEWER_PAT
set +e
GITHUB_TOKEN= GH_TOKEN="ghp_reviewer-token" run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "ambient token verified: rc=$rc"
elif grep -q $'gh\tauth\tswitch' "$WORKDIR/calls.log"; then
  fail "ambient token verified: called gh auth switch"
elif ! grep -q $'GH_TOKEN=ghp_reviewer-token GITHUB_TOKEN= gh\tpr\treview\t123\t--comment' "$WORKDIR/calls.log"; then
  fail "ambient token verified: wrapped write did not run with the ambient token"
  cat "$WORKDIR/calls.log" >&2
elif grep -q "gho_fallback-claude-token" "$WORKDIR/calls.log"; then
  fail "ambient token verified: fell through to keyring despite a usable ambient token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "ambient token verified: a usable ambient GH_TOKEN is used before the keyring fallback"
fi

# An ambient GH_TOKEN that verifies to the WRONG identity must be rejected
# and fall through to the keyring fallback — never blindly trusted.
# ghp_author-token verifies as nathanjohnpayne (wrong for reviewer
# nathanpayne-claude); the keyring then yields gho_fallback-claude-token.
reset_log
unset OP_PREFLIGHT_REVIEWER_PAT
set +e
err=$(GITHUB_TOKEN= GH_TOKEN="ghp_author-token" run_wrapper -- gh pr review 123 --comment --body "ok" 2>&1 >/dev/null)
rc=$?
set -e
# The wrapped write (gh pr review) must run under the keyring token, never
# under the wrong ambient token. (The verification probe `gh api user` does
# run under ghp_author-token — that's expected; we only forbid the wrapped
# pr-review line under it.)
if [ "$rc" -ne 0 ]; then
  fail "ambient token wrong identity: rc=$rc (expected fallthrough success)"
elif ! grep -q $'GH_TOKEN=gho_fallback-claude-token GITHUB_TOKEN= gh\tpr\treview' "$WORKDIR/calls.log"; then
  fail "ambient token wrong identity: did not fall through to the keyring fallback"
  cat "$WORKDIR/calls.log" >&2
elif grep -q $'GH_TOKEN=ghp_author-token GITHUB_TOKEN= gh\tpr\treview' "$WORKDIR/calls.log"; then
  fail "ambient token wrong identity: wrong ambient token reached the wrapped write"
  cat "$WORKDIR/calls.log" >&2
elif ! echo "$err" | grep -q "ambient GH_TOKEN did not verify"; then
  fail "ambient token wrong identity: missing fallthrough diagnostic"
  echo "$err" >&2
else
  pass "ambient token wrong identity: rejected and falls through to the keyring fallback"
fi
unset GH_TOKEN

# --- #1057: brokered credentials and byline readback ------------------
# The Claude cloud placeholder READS as the human through GET /user. Before
# #1057 the resolver's ambient candidate accepted it on that basis and the
# write landed as claude[bot]. It must now be refused before any write, and
# with no keyring token the wrapper must stop.
reset_log
unset OP_PREFLIGHT_REVIEWER_PAT
set +e
err=$(GITHUB_TOKEN= GH_TOKEN="proxy-injected" GH_AS_REVIEWER_IDENTITY=nathanjohnpayne \
  run_wrapper -- gh pr comment 123 --body "x" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "brokered placeholder: expected refusal, got rc=0"
elif grep -q $'gh\tpr\tcomment' "$WORKDIR/calls.log"; then
  fail "brokered placeholder: the write ran"
  cat "$WORKDIR/calls.log" >&2
elif grep -q $'GH_TOKEN=proxy-injected GITHUB_TOKEN= gh\tapi\tuser' "$WORKDIR/calls.log"; then
  fail "brokered placeholder: GET /user was consulted before the class refused it"
else
  pass "brokered placeholder: refused on its credential class before GET /user and before the write"
fi

# A review that lands under another login (a broker substituting its own
# credential) is caught by the readback: exit 5, with the #241 recovery text.
reset_log
set +e
err=$(OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" STUB_WRITE_AS="claude[bot]" \
  run_wrapper -- gh pr review 123 --comment --body "ok" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q "landed under 'claude\[bot\]'" \
   && printf '%s' "$err" | grep -q '#241'; then
  pass "review readback: a review landing under another login exits 5 with recovery text"
else
  fail "review readback: rc=$rc err=$err"
fi

reset_log
set +e
err=$(MERGEPATH_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" STUB_WRITE_AS="claude[bot]" \
  run_wrapper -- gh issue comment 7 --body "x" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q "comment 900 on o/r#7 landed under 'claude\[bot\]'"; then
  pass "comment readback: an issue comment landing under another login exits 5"
else
  fail "comment readback: rc=$rc err=$err"
fi

reset_log
set +e
err=$(OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" run_wrapper -- gh pr comment 123 --body "x" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q "verified comment 900 author=nathanpayne-claude"; then
  pass "comment readback: a correctly attributed comment is verified and exits 0"
else
  fail "comment readback happy path: rc=$rc err=$err"
fi

# A target the wrapper cannot resolve cannot be read back, so it is not written.
reset_log
set +e
OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" STUB_VIEW_RC=1 \
  run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 5 ] && ! grep -q $'gh\tpr\treview' "$WORKDIR/calls.log"; then
  pass "readback prepare failure: exits 5 before the write"
else
  fail "readback prepare failure: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi

# A failed write propagates its own exit code and skips the readback.
reset_log
set +e
OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" GH_GENERIC_RC=4 \
  run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 4 ]; then
  pass "failed write: its exit code propagates, no readback verdict"
else
  fail "failed write: rc=$rc expected 4"
fi

# #1539: a codex-cloud surface with no explicit agent resolves the Codex
# reviewer, in the shared resolver the capability probe also uses.
reset_log
set +e
MERGEPATH_AGENT_SURFACE=codex-cloud OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" \
  run_wrapper -- gh pr comment 123 --body "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q $'GH_TOKEN=ghp_codex-token GITHUB_TOKEN= gh\tpr\tcomment' "$WORKDIR/calls.log"; then
  pass "codex-cloud surface: the wrapper resolves nathanpayne-codex, as the probe does"
else
  fail "codex-cloud surface: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi
if [ "$(env -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT MERGEPATH_AGENT_SURFACE=codex-cloud \
        bash -c '. "$1"; gh_default_reviewer_identity' _ "$ROOT/scripts/lib/gh-token-resolver.sh")" = "nathanpayne-codex" ] \
   && [ "$(env -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT MERGEPATH_AGENT_SURFACE=codex-cloud MERGEPATH_AGENT=claude \
        bash -c '. "$1"; gh_default_reviewer_identity' _ "$ROOT/scripts/lib/gh-token-resolver.sh")" = "nathanpayne-claude" ]; then
  pass "gh_default_reviewer_identity: codex-cloud surface selects codex, an explicit agent still wins"
else
  fail "gh_default_reviewer_identity surface fallback"
fi

reset_log
set +e
run_wrapper -- >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "empty command: exits 1"
else
  fail "empty command: rc=$rc expected 1"
fi

echo ""
echo "test_gh_as_reviewer: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
