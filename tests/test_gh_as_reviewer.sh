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
unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

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
# Enterprise credentials the wrapped command would see (Codex P1 on #1541).
[ -n "${STUB_ENT_LOG:-}" ] && printf '%s|%s|%s %s\n' "${GH_ENTERPRISE_TOKEN:-}" "${GITHUB_ENTERPRISE_TOKEN:-}" "${1:-}" "${2:-}" >>"$STUB_ENT_LOG"  # TOKEN_OUTPUT_EXEMPT: fixture tokens pinned inline by the case that sets STUB_ENT_LOG

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "switch" ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  [ -n "${STUB_NO_KEYRING:-}" ] && exit 1
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

run_wrapper() {
  PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$WRAPPER" "$@"
}

reset_log() {
  : > "$WORKDIR/calls.log"
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

# --- #1057: brokered credentials ----------------------------------------
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

# Codex P1 on #1541: gh reads GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN,
# not GH_TOKEN, for an Enterprise Server target. The write runs with both
# set to a non-credential sentinel; an ambient separate login is overwritten.
reset_log
: >"$WORKDIR/ent.log"
set +e
STUB_ENT_LOG="$WORKDIR/ent.log" OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" \
  run_wrapper -- gh pr comment 123 --body "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qx 'mergepath-guarded-write-github-com-only|mergepath-guarded-write-github-com-only|pr comment' "$WORKDIR/ent.log"; then
  pass "enterprise credentials: the write runs with both set to the non-credential sentinel"
else
  fail "enterprise pinning: rc=$rc log=$(cat "$WORKDIR/ent.log")"
fi
reset_log
: >"$WORKDIR/ent.log"
set +e
STUB_ENT_LOG="$WORKDIR/ent.log" GH_ENTERPRISE_TOKEN="ghp_other-token" GITHUB_ENTERPRISE_TOKEN="gho_other-token" \
  OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" run_wrapper -- gh pr comment 123 --body "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qx 'mergepath-guarded-write-github-com-only|mergepath-guarded-write-github-com-only|pr comment' "$WORKDIR/ent.log" \
   && ! grep -q 'other-token|.*|pr comment\|.*|other-token|pr comment' "$WORKDIR/ent.log"; then
  pass "ambient separate Enterprise login: the write proceeds and never sees it"
else
  fail "ambient enterprise token: rc=$rc log=$(cat "$WORKDIR/ent.log")"
fi

# Codex P1 on #1541: a prefix in the payload can replace the verified token
# (`env GH_TOKEN=proxy-injected gh pr comment` writes as the broker), so only
# a direct gh payload runs. An absolute path to gh is still gh.
for prefixed in "env GH_TOKEN=proxy-injected gh" "command gh" "sudo -n gh" "/usr/bin/env gh"; do
  reset_log
  set +e
  # shellcheck disable=SC2086
  OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" run_wrapper -- $prefixed pr comment 123 --body "x" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 1 ] && ! grep -q $'pr\tcomment' "$WORKDIR/calls.log"; then
    pass "prefixed payload '$prefixed': refused before any write"
  else
    fail "prefixed payload '$prefixed': rc=$rc"
    cat "$WORKDIR/calls.log" >&2
  fi
done
reset_log
set +e
OP_PREFLIGHT_REVIEWER_PAT="ghp_reviewer-token" run_wrapper -- "$STUB_DIR/gh" pr comment 123 --body "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q $'GH_TOKEN=ghp_reviewer-token GITHUB_TOKEN= gh\tpr\tcomment' "$WORKDIR/calls.log"; then
  pass "absolute path to gh: accepted and run under the verified token"
else
  fail "absolute gh path: rc=$rc"
fi

# #1539: the surface does not select the reviewer, so the wrapper, the
# capability probe and gh-pr-guard.sh (which never reads the surface) resolve
# the same one. MERGEPATH_AGENT=codex selects the Codex reviewer.
reset_log
set +e
MERGEPATH_AGENT_SURFACE=codex-cloud MERGEPATH_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" \
  run_wrapper -- gh pr comment 123 --body "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q $'GH_TOKEN=ghp_codex-token GITHUB_TOKEN= gh\tpr\tcomment' "$WORKDIR/calls.log"; then
  pass "codex-cloud surface with MERGEPATH_AGENT=codex: the wrapper writes as nathanpayne-codex"
else
  fail "codex-cloud surface: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi
# Phase 4b P1 on #1541: with only the surface set, the wrapper must resolve
# the same reviewer gh-pr-guard.sh assumes (nathanpayne-claude). It therefore
# refuses a Codex PAT rather than post an approval under a reviewer the hook's
# self-approval check never evaluated.
reset_log
set +e
env -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT -u GH_AS_REVIEWER_IDENTITY \
  MERGEPATH_AGENT_SURFACE=codex-cloud OP_PREFLIGHT_REVIEWER_PAT="ghp_codex-token" STUB_NO_KEYRING=1 \
  PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$WRAPPER" -- gh pr review 123 --approve >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q $'gh\tpr\treview' "$WORKDIR/calls.log"; then
  pass "surface-only Codex PAT: resolved as the hook's reviewer, refused, no approval posted"
else
  fail "surface-only Codex PAT approval: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi
if [ "$(env -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT MERGEPATH_AGENT_SURFACE=codex-cloud \
        bash -c '. "$1"; gh_default_reviewer_identity' _ "$ROOT/scripts/lib/gh-token-resolver.sh")" = "nathanpayne-claude" ] \
   && [ "$(env -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT MERGEPATH_AGENT_SURFACE=codex-cloud MERGEPATH_AGENT=codex \
        bash -c '. "$1"; gh_default_reviewer_identity' _ "$ROOT/scripts/lib/gh-token-resolver.sh")" = "nathanpayne-codex" ]; then
  pass "gh_default_reviewer_identity: the surface selects nothing; MERGEPATH_AGENT=codex selects codex"
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
