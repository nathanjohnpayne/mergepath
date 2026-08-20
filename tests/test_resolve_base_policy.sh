#!/usr/bin/env bash
# tests/test_resolve_base_policy.sh
#
# Hermetic coverage for scripts/workflow/resolve_base_policy.sh — the single
# shared resolution of "which review policy governs this PR" (#769).
#
# The contract under test is an ASYMMETRY that is easy to regress in either
# direction:
#
#   trusted default base    -> print the default config, make NO API call
#   materialized default    -> print a temp file holding target BASE policy
#   non-default + readable  -> print a temp file holding the BASE policy
#   non-default + 404       -> trusted mode prints default config;
#                              materialized mode fetches target default policy
#   non-default + other err -> exit 2 (caller must fail closed)
#   base undeterminable     -> exit 2. Falling back is allowed ONLY when the
#                              default base is POSITIVELY PROVEN; "unknown" is
#                              not proof.
#
# Also pins that stdout carries ONLY the path: the callers capture stdout as a
# filename, so a diagnostic leaking into it would produce a garbage config path
# (the #715/#716 failure class, hit for real while wiring this).
#
# Fully offline via a PATH-prepended `gh` stub. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$ROOT/scripts/workflow/resolve_base_policy.sh"
[ -x "$RESOLVE" ] || { echo "missing $RESOLVE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/resolve-base-policy-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="owner/repo"
DEFAULT_CONFIG="$WORK/default-policy.yml"
printf 'external_review_threshold: 300\n' > "$DEFAULT_CONFIG"

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
  repos/*/pulls/*)
    if [ "${STUB_PR_FAIL:-0}" = "1" ]; then echo "gh: server error" >&2; exit 1; fi
    [ -z "${STUB_PR_STDERR:-}" ] || echo "$STUB_PR_STDERR" >&2
    cat "${STUB_PR_JSON:-/dev/null}"
    exit 0 ;;
  repos/*/commits/*)
    if [ "${STUB_COMMIT_FAIL:-0}" = "1" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo '{"sha":"basesha1"}'
    exit 0 ;;
  repos/*/contents/*)
    contents_mode="${STUB_CONTENTS_MODE:-ok}"
    if [ "$contents_mode" = "base404-default-ok" ]; then
      case "$PATHARG" in
        *ref=basesha1) contents_mode=404 ;;
        *) contents_mode=ok ;;
      esac
    fi
    case "$contents_mode" in
      ok)    [ -z "${STUB_CONTENTS_STDERR:-}" ] || echo "$STUB_CONTENTS_STDERR" >&2
             printf 'external_review_threshold: 1\n'; exit 0 ;;
      404)   echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      error) echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
      prose) echo "gh: repository not found" >&2; exit 1 ;;
    esac ;;
esac
echo "{}"
STUB
chmod +x "$GH_STUB"
export PATH="$WORK:$PATH" GH_CALLS_LOG="$CALLS_LOG"
hash -r 2>/dev/null || true

reset_env() { unset STUB_PR_FAIL STUB_CONTENTS_MODE STUB_PR_JSON STUB_CONTENTS_STDERR STUB_COMMIT_FAIL STUB_PR_STDERR; : > "$CALLS_LOG"; }

run_meta() {  # <base_ref> <default_branch>
  OUT=$(bash "$RESOLVE" --repo "$REPO" --base-ref "$1" --base-sha "basesha1" \
        --default-branch "$2" --default-config "$DEFAULT_CONFIG" 2>"$WORK/err.txt") && RC=0 || RC=$?
}

# 1. Default base: returns the default config and makes NO API call.
reset_env
run_meta main main
if [ "$RC" -eq 0 ] && [ "$OUT" = "$DEFAULT_CONFIG" ] && ! grep -q . "$CALLS_LOG"; then
  pass "default base returns the default config with no API call (#769)"
else
  fail "default base (rc=$RC out=$OUT calls=$(wc -l <"$CALLS_LOG"))"
fi

# 2. Non-default base, readable: returns a temp file holding the BASE policy.
reset_env
export STUB_CONTENTS_MODE=ok
run_meta release/1.x main
if [ "$RC" -eq 0 ] && [ "$OUT" != "$DEFAULT_CONFIG" ] && [ -f "$OUT" ] \
   && grep -q "external_review_threshold: 1" "$OUT"; then
  pass "non-default base returns the base policy contents (#769)"
  rm -f "$OUT"
else
  fail "non-default readable base (rc=$RC out=$OUT)"
fi

# 3. Non-default base, confirmed 404: falls back to the default config.
reset_env
export STUB_CONTENTS_MODE=404
run_meta release/1.x main
if [ "$RC" -eq 0 ] && [ "$OUT" = "$DEFAULT_CONFIG" ]; then
  pass "non-default base predating the policy falls back to the default (#769)"
else
  fail "non-default 404 (rc=$RC out=$OUT)"
fi

# 4. Non-default base, non-404 failure: exits 2 so callers fail closed. This is
#    the ONLY hard-failure path, and the one that closes the actual bypass.
reset_env
export STUB_CONTENTS_MODE=error
run_meta release/1.x main
if [ "$RC" -eq 2 ] && grep -q "could not read" "$WORK/err.txt"; then
  pass "non-default base with an unreadable policy exits 2 (#769)"
else
  fail "non-default error should exit 2 (rc=$RC out=$OUT)"
fi

# 5. Base undeterminable: FAILS CLOSED. Falling back is permitted only on
#    positive proof that the base is the default branch; "unknown" is not
#    proof, and codex-review-check.sh already dies on the same failed fetch
#    moments later, so falling back bought no availability.
reset_env
export STUB_PR_FAIL=1
OUT=$(bash "$RESOLVE" --repo "$REPO" --pr 42 --default-config "$DEFAULT_CONFIG" 2>"$WORK/err.txt") && RC=0 || RC=$?
if [ "$RC" -eq 2 ] && grep -q "refusing to fall back" "$WORK/err.txt"; then
  pass "undeterminable base fails closed rather than assuming the default (#768 P1)"
else
  fail "undeterminable base should exit 2 (rc=$RC out=$OUT)"
fi

# 6. stdout carries ONLY the path, even when a diagnostic is emitted. Callers
#    use stdout as a filename; a leaked warning becomes a garbage config path.
reset_env
export STUB_CONTENTS_MODE=404
OUT=$(bash "$RESOLVE" --repo "$REPO" --base-ref release/1.x --base-sha basesha1 \
      --default-branch main --default-config "$DEFAULT_CONFIG" 2>/dev/null) && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$DEFAULT_CONFIG" ] && [ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" = "0" ]; then
  pass "stdout is the path alone; diagnostics stay on stderr (#715/#716 class)"
else
  fail "stdout contained more than the path: '$OUT'"
fi

# 7. PR form resolves via metadata when the caller supplies no base fields.
reset_env
STUB_PR_JSON="$WORK/pr.json"
jq -n '{base:{ref:"release/1.x", sha:"basesha1", repo:{default_branch:"main"}}}' > "$STUB_PR_JSON"
export STUB_PR_JSON STUB_CONTENTS_MODE=ok
OUT=$(bash "$RESOLVE" --repo "$REPO" --pr 42 --default-config "$DEFAULT_CONFIG" 2>/dev/null) && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT" ] && grep -q "external_review_threshold: 1" "$OUT"; then
  pass "--pr form resolves the base from PR metadata (#769)"
  rm -f "$OUT"
else
  fail "--pr form (rc=$RC out=$OUT)"
fi

# 8. A gh warning on an otherwise-SUCCESSFUL contents fetch must not end up
#    inside the policy file. stdout here is the raw policy, so merging streams
#    would write the warning into it verbatim and silently corrupt every
#    threshold/path/reviewer decision made from it (#715/#716 class, caught by
#    CodeRabbit on #768 — this suite originally missed it because the stub only
#    emitted stderr on FAILURE).
reset_env
export STUB_CONTENTS_MODE=ok
export STUB_CONTENTS_STDERR="gh: a non-fatal informational notice on stderr"
run_meta release/1.x main
if [ "$RC" -eq 0 ] && [ -f "$OUT" ] \
   && grep -q "external_review_threshold: 1" "$OUT" \
   && ! grep -q "informational notice" "$OUT"; then
  pass "stderr noise on a successful fetch never reaches the policy file (#715/#716 class)"
  rm -f "$OUT"
else
  fail "policy file was contaminated by stderr: $(cat "$OUT" 2>/dev/null)"
fi

# 9. A non-404 failure whose stderr merely CONTAINS "not found" must NOT be
#    treated as a missing policy file. The earlier test grepped prose, so
#    "repository not found", ref errors, and some auth failures all downgraded
#    a non-default-base PR to the default-branch policy (#768 P1).
reset_env
export STUB_CONTENTS_MODE=prose
run_meta release/1.x main
if [ "$RC" -eq 2 ]; then
  pass "a non-404 error containing 'not found' fails closed, not falls back (#768 P1)"
else
  fail "prose 'not found' should not trigger the fallback (rc=$RC out=$OUT)"
fi

# 10. A contents 404 whose BASE COMMIT does not resolve is an unreadable
#     repo/ref, not a missing file — repo-404 and file-404 carry the same
#     status, so the commit probe is what distinguishes them.
reset_env
export STUB_CONTENTS_MODE=404 STUB_COMMIT_FAIL=1
run_meta release/1.x main
if [ "$RC" -eq 2 ] && grep -q "does not resolve" "$WORK/err.txt"; then
  pass "contents 404 + unresolvable base commit fails closed (#768 P1)"
else
  fail "unresolvable base commit should fail closed (rc=$RC out=$OUT)"
fi

# 11. The same stderr-contamination guarantee for the PR-METADATA fetch. Case 8
#     covers the contents response; this covers the other gh call, whose stdout
#     is parsed as JSON — merged stderr would break the parse and silently
#     erase base.ref, which now means "cannot prove default base" and a hard
#     fail rather than a wrong answer, but either way it must not happen.
reset_env
STUB_PR_JSON="$WORK/pr-noise.json"
jq -n '{base:{ref:"release/1.x", sha:"basesha1", repo:{default_branch:"main"}}}' > "$STUB_PR_JSON"
export STUB_PR_JSON STUB_CONTENTS_MODE=ok
export STUB_PR_STDERR="gh: another non-fatal notice on stderr"
OUT=$(bash "$RESOLVE" --repo "$REPO" --pr 42 --default-config "$DEFAULT_CONFIG" 2>/dev/null) && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT" ] && grep -q "external_review_threshold: 1" "$OUT"; then
  pass "stderr noise on the PR-metadata fetch does not corrupt base resolution (#715/#716 class)"
  rm -f "$OUT"
else
  fail "PR-metadata stderr broke resolution (rc=$RC out=$OUT)"
fi

# 12. A cross-repository/default-base caller materializes at the exact base
#     SHA. When that policy file is positively absent but the commit resolves,
#     the same verified-404 contract falls back to the target default branch.
reset_env
export STUB_CONTENTS_MODE=base404-default-ok
OUT=$(bash "$RESOLVE" --repo "$REPO" --base-ref main --base-sha basesha1 \
      --default-branch main --default-config "$DEFAULT_CONFIG" \
      --materialize-default 2>"$WORK/err.txt") && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" != "$DEFAULT_CONFIG" ] && [ -f "$OUT" ] \
   && grep -q "external_review_threshold: 1" "$OUT" \
   && grep -q "repos/$REPO/commits/basesha1" "$CALLS_LOG" \
   && grep -q "ref=main" "$CALLS_LOG"; then
  pass "materialized default-base 404 verifies the commit and fetches target default policy (#769)"
  rm -f "$OUT"
else
  fail "materialized default-base 404 fallback (rc=$RC out=$OUT calls=$(cat "$CALLS_LOG"))"
fi

echo
echo "== resolve_base_policy (#769) tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
