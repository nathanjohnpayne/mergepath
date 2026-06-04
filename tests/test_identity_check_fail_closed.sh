#!/usr/bin/env bash
# tests/test_identity_check_fail_closed.sh
#
# Regression test for #284 r3: helper absence MUST fail-closed.
#
# Before r3, every call site wired the identity-check helper via:
#
#   if [ "${OPT_OUT:-0}" != "1" ] && [ -x "$CHECKER" ]; then
#     "$CHECKER" --expect-reviewer || exit 2
#   fi
#
# The `[ -x "$CHECKER" ]` test sat as a co-equal precondition in the
# AND chain. If the helper was renamed, deleted, or had its +x bit
# stripped, the entire identity-check block was SILENTLY SKIPPED and
# the keyring-byline write went through without identity verification.
# This is fail-OPEN. nathanpayne-codex Phase 4b r2 on PR #293 / b0c8463
# reproduced this — a mutation reached `resolveReviewThread` without
# the gate firing.
#
# r3 restructures every wired site to fail-CLOSED:
#
#   if [ "${OPT_OUT:-0}" != "1" ]; then
#     CHECKER=".../identity-check.sh"
#     if [ ! -x "$CHECKER" ]; then
#       echo "ERROR: ... missing or non-executable: $CHECKER" >&2
#       exit 2  # (or `die 3` for scripts that use a die helper)
#     fi
#     "$CHECKER" --expect-reviewer || exit 2
#   fi
#
# This test has two parts:
#
#   Part A — Structural: grep each wired script and assert the new
#   shape is present and the old fail-open shape is gone. This is
#   what catches regression on future edits.
#
#   Part B — Behavioral: build a minimal harness that mirrors the
#   exact gate idiom from each script, run it with the helper missing,
#   absent, and present + non-executable, and assert exit 2 (or 3 for
#   die-style callers) + the required diagnostic.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/identity-check-fail-closed.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# -----------------------------------------------------------------------
# Part A — Structural: each wired script must use the fail-closed shape.
# -----------------------------------------------------------------------
#
# The contract for every wired site:
#   1. The opt-out test is the OUTER condition.
#   2. Inside the opt-out branch, `[ ! -x "$CHECKER" ]` (or its
#      lowercase variant) gates a hard error exit.
#   3. The fail-open shape `[ -x ... ]` ANDed with the opt-out at the
#      same depth as a precondition for entering the block is GONE.
#
# We assert (2) and (3) by grepping for the inverted helper-presence
# test AND the absence of the `&& \\` + `[ -x "$(dirname...` pattern.

check_script_shape() {
  local script="$1"
  local label="$2"
  local path="$ROOT/$script"

  if [ ! -f "$path" ]; then
    fail "$label: script not found at $path"
    return
  fi

  # Must contain the fail-closed test: `[ ! -x ... ]` against the
  # identity-check helper path. Tolerate `$CHECKER` or `$checker`.
  if ! grep -q '\[ ! -x "\$\(CHECKER\|checker\)" \]' "$path"; then
    fail "$label: missing fail-closed test '[ ! -x \"\$CHECKER\" ]' in $script"
    return
  fi

  # Must contain the missing-or-non-executable diagnostic.
  if ! grep -q 'identity-check helper missing or non-executable' "$path"; then
    fail "$label: missing 'identity-check helper missing or non-executable' diagnostic in $script"
    return
  fi

  # Must NOT contain the fail-open pattern: the opt-out env var ANDed
  # with `[ -x ".../identity-check.sh" ]` on the same chain. The marker
  # is the literal string `[ -x "$(dirname "${BASH_SOURCE[0]}")/identity-check.sh" ]`
  # used as a precondition. After r3 the helper-presence test lives
  # inside the opt-out branch as `[ ! -x "$CHECKER" ]`, so the legacy
  # form is gone.
  if grep -q '\[ -x "\$(dirname "\${BASH_SOURCE\[0\]}")/identity-check\.sh" \]' "$path"; then
    fail "$label: legacy fail-open pattern '[ -x \"\$(dirname ...)/identity-check.sh\" ]' still present in $script"
    return
  fi

  pass "$label: $script is fail-closed (helper absence rejected)"
}

check_script_shape "scripts/resolve-pr-threads.sh"     "resolve-pr-threads"
check_script_shape "scripts/coderabbit-wait.sh"        "coderabbit-wait"

RLR="$ROOT/scripts/request-label-removal.sh"
if grep -q 'gh-token-resolver helper missing' "$RLR" \
   && grep -q '\[ ! -x "\$AS_REVIEWER" \]' "$RLR" \
   && grep -q 'gh-as-reviewer.sh helper missing or non-executable' "$RLR"; then
  pass "request-label-removal: token resolver + gh-as-reviewer helper presence is fail-closed"
else
  fail "request-label-removal: missing fail-closed token resolver / gh-as-reviewer guard"
fi

if grep -qE '"\$AS_REVIEWER" -- gh pr comment ' "$RLR"; then
  pass "request-label-removal: label ask posted via \"\$AS_REVIEWER\" -- gh pr comment"
else
  fail "request-label-removal: label ask is NOT wrapped by gh-as-reviewer"
fi

# codex-review-request.sh moved its '@codex review' trigger-post guard
# from identity-check (--expect-reviewer) to gh-as-author.sh, so the
# trigger is authored by nathanjohnpayne — the Codex App only monitors
# author-authored triggers (#405). It is no longer an identity-check site,
# but it must still FAIL-CLOSED if its helper is missing, now against
# gh-as-author.
CRR="$ROOT/scripts/codex-review-request.sh"
if grep -q '\[ ! -x "\$AS_AUTHOR" \]' "$CRR" \
   && grep -q 'gh-as-author.sh helper missing or non-executable' "$CRR"; then
  pass "codex-review-request: gh-as-author helper presence is fail-closed"
else
  fail "codex-review-request: missing gh-as-author fail-closed guard for the @codex review trigger"
fi

# The actual trigger write MUST be wrapped by gh-as-author so the
# '@codex review' byline is nathanjohnpayne — the load-bearing property
# the Codex App requires (#405). Assert the real wrapped invocation, not
# just the guard around it (Codex r2 on #405: a guard can be present
# while the post still goes out unwrapped).
if grep -qE '"\$AS_AUTHOR" -- gh pr comment .* --body "@codex review"' "$CRR"; then
  pass "codex-review-request: '@codex review' trigger posted via \"\$AS_AUTHOR\" -- gh pr comment (author byline)"
else
  fail "codex-review-request: '@codex review' trigger is NOT wrapped by gh-as-author — the byline would not be nathanjohnpayne"
fi

# -----------------------------------------------------------------------
# Part B — Behavioral: the gate idiom rejects helper absence.
# -----------------------------------------------------------------------
#
# We can't easily run the full call-site scripts end-to-end inside a
# unit test (they require live gh, jq, real PRs). Instead, build a
# minimal harness that copies the EXACT gate idiom verbatim and exercise
# it under three conditions:
#
#   1. helper missing entirely         → exit 2 + diagnostic
#   2. helper present but non-executable → exit 2 + diagnostic
#   3. helper present and executable   → identity check runs (we stub
#      it to exit 0) and the harness reaches the post-gate marker
#
# Use the resolve-pr-threads idiom (exit-2 style; the codex/coderabbit
# `die 3` variants are structurally identical with the only
# difference being the exit code on the helper-presence branch — same
# behavior, same diagnostic).

HARNESS_DIR="$WORKDIR/harness"
mkdir -p "$HARNESS_DIR"

cat >"$HARNESS_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
# Minimal harness that mirrors the resolve-pr-threads.sh r3 gate idiom.
set -euo pipefail
DRY_RUN=false
if [ "${HARNESS_SKIP_IDENTITY_CHECK:-0}" != "1" ] && ! $DRY_RUN; then
  CHECKER="$(dirname "${BASH_SOURCE[0]}")/identity-check.sh"
  if [ ! -x "$CHECKER" ]; then
    echo "ERROR: identity-check helper missing or non-executable: $CHECKER" >&2
    echo "       Refusing to mutate without identity verification." >&2
    echo "       Restore the helper, or opt out via" >&2
    echo "       HARNESS_SKIP_IDENTITY_CHECK=1 (dev only)." >&2
    exit 2
  fi
  if ! "$CHECKER" --expect-token-identity "test-user"; then
    echo "ERROR: identity-check failed before any mutation." >&2
    exit 2
  fi
fi
echo "REACHED_POST_GATE"
HARNESS
chmod +x "$HARNESS_DIR/harness.sh"

# Stage 1: helper missing entirely → exit 2, "missing or non-executable"
# diagnostic, post-gate marker NOT printed.
rm -f "$HARNESS_DIR/identity-check.sh"

set +e
out=$("$HARNESS_DIR/harness.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "stage 1 (helper missing): exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -q "identity-check helper missing or non-executable"; then
  fail "stage 1: missing 'helper missing or non-executable' diagnostic; output: $out"
elif echo "$out" | grep -q "REACHED_POST_GATE"; then
  fail "stage 1: post-gate marker leaked through (fail-OPEN); output: $out"
else
  pass "stage 1: helper missing → exit 2 + diagnostic, post-gate NOT reached"
fi

# Stage 2: helper present but non-executable (chmod -x) → exit 2,
# diagnostic, post-gate NOT printed.
cat >"$HARNESS_DIR/identity-check.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod -x "$HARNESS_DIR/identity-check.sh"

set +e
out=$("$HARNESS_DIR/harness.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "stage 2 (helper non-executable): exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -q "identity-check helper missing or non-executable"; then
  fail "stage 2: missing diagnostic; output: $out"
elif echo "$out" | grep -q "REACHED_POST_GATE"; then
  fail "stage 2: post-gate marker leaked through (fail-OPEN); output: $out"
else
  pass "stage 2: helper present but non-executable → exit 2 + diagnostic, post-gate NOT reached"
fi

# Stage 3: helper present and executable → harness reaches the post-gate
# marker (the stub helper exits 0). This confirms the normal flow still
# works and the fail-closed wiring doesn't break the happy path.
chmod +x "$HARNESS_DIR/identity-check.sh"

set +e
out=$("$HARNESS_DIR/harness.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "REACHED_POST_GATE"; then
  pass "stage 3: helper present + executable → post-gate reached, exit 0"
else
  fail "stage 3 (happy path): exit $rc, output: $out"
fi

# Stage 4: opt-out env set → gate skipped entirely, post-gate reached
# EVEN with helper missing. This confirms the opt-out is the OUTER
# branch and the helper-presence test is INSIDE it (i.e. fail-closed
# applies only when the gate is active).
rm -f "$HARNESS_DIR/identity-check.sh"

set +e
out=$(HARNESS_SKIP_IDENTITY_CHECK=1 "$HARNESS_DIR/harness.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "REACHED_POST_GATE"; then
  pass "stage 4: opt-out set + helper missing → gate skipped (dev only path works)"
else
  fail "stage 4 (opt-out): exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "test_identity_check_fail_closed: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
