#!/usr/bin/env bash
# tests/test_audit_branch_protection.sh
#
# Fixture tests for scripts/audit-branch-protection.sh — covers the
# #285 fixes:
#   - 403/401 auth-scope failures distinguished from 404 "no classic
#     protection" (no false-unprotected verdict under reviewer PAT)
#   - ruleset fallback scoped to rulesets that ACTUALLY target the
#     audited branch (not just any target=="branch" ruleset)
#   - new include forms supported: ~ALL and branch globs
#     (e.g. refs/heads/*) in addition to ~DEFAULT_BRANCH and
#     refs/heads/<name>
#
# Mocks `gh api` via a PATH-shimmed stub that returns fixture JSON
# (or fixture headers+body for the -i flag) plus an appropriate exit
# code. Pattern mirrors tests/test_gh_pr_guard.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-branch-protection.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (audit-branch-protection.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-bp-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- gh stub ----------------------------------------------------------------
#
# The audit script makes two kinds of gh calls we care about:
#   1. `gh api -i repos/<owner>/<repo>/branches/<branch>/protection`
#      — includes HTTP headers; we emit a fixture status line + body.
#   2. `gh api repos/<owner>/<repo>/rulesets` and
#      `gh api repos/<owner>/<repo>/rulesets/<id>` — body only.
#
# Behavior is driven by STUB_SCENARIO. Each scenario controls:
#   - the HTTP status returned for branch protection (or 200 + body)
#   - the rulesets list returned (if any)
#   - the per-ruleset detail returned (if any)
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Args: gh api [-i] <path>
# We only need to recognize three path shapes:
#   .../branches/.../protection
#   .../rulesets
#   .../rulesets/<id>
include_headers=0
args=()
for a in "$@"; do
  case "$a" in
    -i) include_headers=1 ;;
    *)  args+=("$a") ;;
  esac
done
# args[0]=api, args[1]=<path>
path="${args[1]:-}"

emit_status_and_body() {
  # $1 = HTTP status (e.g. 200, 403, 404)
  # $2 = body
  local status="$1"
  local body="$2"
  if [ "$include_headers" -eq 1 ]; then
    case "$status" in
      200) echo "HTTP/2 200 OK" ;;
      404) echo "HTTP/2 404 Not Found" ;;
      403) echo "HTTP/2 403 Forbidden" ;;
      401) echo "HTTP/2 401 Unauthorized" ;;
      *)   echo "HTTP/2 $status" ;;
    esac
    echo "content-type: application/json"
    echo ""
  fi
  printf '%s\n' "$body"
  # gh exits non-zero on >=400 — mirror that so the script's `|| true`
  # plus status-line inspection works as in production.
  case "$status" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

case "$path" in
  */branches/*/protection)
    case "${STUB_SCENARIO:-}" in
      auth_403)
        emit_status_and_body 403 '{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}'
        exit $?
        ;;
      auth_401)
        emit_status_and_body 401 '{"message":"Bad credentials"}'
        exit $?
        ;;
      classic_protected)
        # Classic protection present; required_status_checks includes
        # all canonical checks plus an extra one.
        emit_status_and_body 200 '{"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings","Merge clearance gate","lint"]}}'
        exit $?
        ;;
      classic_missing_clearance_gate)
        # Classic protection present but MISSING "Merge clearance gate".
        # Regression net for #427/#428: the auditor must FAIL when the
        # HEAD-pinned merge-clearance check is not a required check.
        emit_status_and_body 200 '{"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","lint"]}}'
        exit $?
        ;;
      no_protection|ruleset_*|ruleset_all_but_main_excluded)
        # No classic protection; 404 triggers ruleset fallback.
        emit_status_and_body 404 '{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}'
        exit $?
        ;;
      *)
        emit_status_and_body 500 '{"message":"unknown STUB_SCENARIO"}'
        exit $?
        ;;
    esac
    ;;
  */rulesets)
    case "${STUB_SCENARIO:-}" in
      no_protection)
        printf '%s\n' "[]"
        exit 0
        ;;
      ruleset_all)
        printf '%s\n' '[{"id":101,"target":"branch"}]'
        exit 0
        ;;
      ruleset_glob)
        printf '%s\n' '[{"id":102,"target":"branch"}]'
        exit 0
        ;;
      ruleset_unrelated_only)
        # One ruleset that targets refs/heads/dev only — must NOT
        # contaminate the audit of main.
        printf '%s\n' '[{"id":201,"target":"branch"}]'
        exit 0
        ;;
      ruleset_unrelated_plus_default)
        # Two rulesets: one targets dev with bogus checks; one targets
        # ~DEFAULT_BRANCH with the canonical checks. Audit of main must
        # see only the canonical set.
        printf '%s\n' '[{"id":201,"target":"branch"},{"id":202,"target":"branch"}]'
        exit 0
        ;;
      ruleset_all_but_main_excluded)
        # ONE ruleset: include ~ALL, exclude refs/heads/main. Must NOT
        # protect main even though include matches. #285 r2.
        printf '%s\n' '[{"id":301,"target":"branch"}]'
        exit 0
        ;;
      *)
        printf '%s\n' "[]"
        exit 0
        ;;
    esac
    ;;
  */rulesets/101)
    # ~ALL include, canonical checks
    printf '%s\n' '{"id":101,"target":"branch","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/102)
    # refs/heads/* glob include, canonical checks
    printf '%s\n' '{"id":102,"target":"branch","conditions":{"ref_name":{"include":["refs/heads/*"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/201)
    # refs/heads/dev only — should NOT match audit of main. Has bogus
    # checks that, if leaked into the audit, would NOT include the
    # canonical set (so we can assert "FAIL: no rulesets target main"
    # rather than "FAIL: <canonical> missing").
    printf '%s\n' '{"id":201,"target":"branch","conditions":{"ref_name":{"include":["refs/heads/dev"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"dev-only-check"}]}}]}'
    exit 0
    ;;
  */rulesets/202)
    # ~DEFAULT_BRANCH with canonical checks — should match audit of main.
    printf '%s\n' '{"id":202,"target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/301)
    # ~ALL include, refs/heads/main excluded. Canonical checks in the
    # rule, but the ruleset must be IGNORED for the audit of main.
    # Without exclude handling, the prior implementation would PASS
    # — which is the bug #285 r2 closes.
    printf '%s\n' '{"id":301,"target":"branch","conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"}]}}]}'
    exit 0
    ;;
  *)
    printf '%s\n' '{}'
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Helper: run the script with a chosen scenario.
run_audit() {
  local scenario="$1"
  shift
  PATH="$STUB_DIR:$PATH" \
  STUB_SCENARIO="$scenario" \
    bash "$SCRIPT" --repo nathanjohnpayne/mergepath --branch main "$@"
}

# ---------------------------------------------------------------------------
# Test 1: insufficient token scope (403) → exit 2 with auth diagnostic.
#         Must NOT fall through to a false "unprotected" verdict.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit auth_403 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "auth 403: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "Administration:read"; then
  fail "auth 403: diagnostic missing 'Administration:read' hint; output: $out"
elif echo "$out" | grep -q "PR merges are completely unprotected"; then
  fail "auth 403: must NOT emit false 'unprotected' verdict; output: $out"
elif ! echo "$out" | grep -qi "author/admin"; then
  fail "auth 403: diagnostic missing 'author/admin' guidance; output: $out"
else
  pass "auth 403: exits 2 with auth diagnostic, no false-unprotected verdict"
fi

# ---------------------------------------------------------------------------
# Test 1b: 401 also routes through the auth diagnostic path.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit auth_401 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "auth 401: exit $rc, expected 2; output: $out"
elif echo "$out" | grep -q "PR merges are completely unprotected"; then
  fail "auth 401: must NOT emit false 'unprotected' verdict; output: $out"
else
  pass "auth 401: exits 2, no false-unprotected verdict"
fi

# ---------------------------------------------------------------------------
# Test 2: no protection at all (true 404, empty rulesets list) →
#         exit 3 with "unprotected" verdict.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit no_protection 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "no protection: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "no protection: diagnostic missing 'no rulesets target main'; output: $out"
else
  pass "no protection (true 404 + empty rulesets): exits 3 with unprotected verdict"
fi

# ---------------------------------------------------------------------------
# Test 3: classic protection present → exit 0 (PASS).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_protected 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "classic protection: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "classic protection: missing PASS line; output: $out"
else
  pass "classic protection present: exits 0 with PASS"
fi

# ---------------------------------------------------------------------------
# Test 4: ruleset with ~ALL targeting main → exit 0 (PASS).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_all 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "ruleset ~ALL: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "ruleset ~ALL: missing PASS line; output: $out"
else
  pass "ruleset ~ALL targeting main: exits 0 (canonical checks present)"
fi

# ---------------------------------------------------------------------------
# Test 5: ruleset with refs/heads/* glob → exit 0 (matches main).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_glob 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "ruleset refs/heads/* glob: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "ruleset refs/heads/* glob: missing PASS line; output: $out"
else
  pass "ruleset refs/heads/* glob: matches main and exits 0"
fi

# ---------------------------------------------------------------------------
# Test 6: unrelated branch ruleset (target refs/heads/dev only) — its
#         checks must NOT contaminate the audit of main. Expect exit 3
#         with the "no rulesets target main" verdict, NOT a leaked
#         "dev-only-check" appearing in the audited set.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_unrelated_only 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "ruleset dev-only: exit $rc, expected 3; output: $out"
elif echo "$out" | grep -q "dev-only-check"; then
  fail "ruleset dev-only: 'dev-only-check' leaked into main's audit; output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "ruleset dev-only: missing 'no rulesets target main' verdict; output: $out"
else
  pass "ruleset dev-only: does NOT contaminate audit of main"
fi

# ---------------------------------------------------------------------------
# Test 7: mixed rulesets (dev-only + ~DEFAULT_BRANCH) — audit of main
#         picks up only the ~DEFAULT_BRANCH ruleset's checks, not the
#         dev-only ones. Regression net: even when SOME ruleset matches,
#         non-matching rulesets must NOT leak their checks in.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_unrelated_plus_default 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "mixed rulesets: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "dev-only-check"; then
  fail "mixed rulesets: 'dev-only-check' leaked from unrelated ruleset; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "mixed rulesets: missing PASS line; output: $out"
else
  pass "mixed rulesets: only matching ruleset's checks counted; PASS"
fi

# ---------------------------------------------------------------------------
# Test 9 (#285 r2): a ruleset with include ~ALL + exclude refs/heads/main
#         must NOT count as protecting main, even though the include
#         matches. Pre-fix this was a false PASS. (nathanpayne-codex
#         Phase 4b finding.)
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_all_but_main_excluded 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "ruleset all-but-main-excluded: exit $rc, expected 3 (excluded ruleset must not protect); output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "ruleset all-but-main-excluded: missing 'no rulesets target main' verdict; output: $out"
else
  pass "ruleset all-but-main-excluded: exclude correctly disqualifies the ~ALL include"
fi

# ---------------------------------------------------------------------------
# Test 10 (#427/#428): classic protection present but MISSING the
#         "Merge clearance gate" required check → exit 3. Regression net
#         that the HEAD-pinned merge-clearance gate is wired into the
#         canonical required-checks list.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_missing_clearance_gate 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "missing clearance gate: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "Merge clearance gate"; then
  fail "missing clearance gate: diagnostic must name 'Merge clearance gate'; output: $out"
else
  pass "missing 'Merge clearance gate' required check: exits 3 (canonical gap flagged)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_audit_branch_protection: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
