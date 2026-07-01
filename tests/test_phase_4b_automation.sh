#!/usr/bin/env bash
# tests/test_phase_4b_automation.sh
#
# Unit tests for the Phase 4b automated-review handoff package:
#   scripts/phase-4b/lib.sh                          (selection + validation)
#   scripts/phase-4b/adapters/review-via-codex.sh    (Direction A)
#   scripts/phase-4b/adapters/review-via-claude.sh   (Direction B)
#   scripts/phase-4b-review.sh                        (orchestrator)
#
# Strategy: no network, no real models. Adapter CLIs are injected via
# CODEX_BIN / CLAUDE_BIN fakes; PR metadata is injected via orchestrator
# override flags (--author/--head/--diff-file) and a scratch
# review-policy.yml via MERGEPATH_REVIEW_POLICY_PATH. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/phase-4b/lib.sh"
ORCH="$ROOT/scripts/phase-4b-review.sh"
AD_CODEX="$ROOT/scripts/phase-4b/adapters/review-via-codex.sh"
AD_CLAUDE="$ROOT/scripts/phase-4b/adapters/review-via-claude.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }
for f in "$LIB" "$ORCH" "$AD_CODEX" "$AD_CLAUDE"; do
  [ -e "$f" ] || { echo "missing required path: $f" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-auto-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- fixtures --------------------------------------------------------------
DIFF="$WORK/diff.patch"
printf 'diff --git a/x.js b/x.js\n+const x = 1;\n' > "$DIFF"

# scratch policy with automation ENABLED
POLICY_ON="$WORK/policy-on.yml"
cat > "$POLICY_ON" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
YAML

# scratch policy with automation DISABLED
POLICY_OFF="$WORK/policy-off.yml"
cat > "$POLICY_OFF" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: false
YAML

BIN="$WORK/bin"; mkdir -p "$BIN"

mk_fake() { # mk_fake <name> <body-after-stdin-drain>
  local name="$1"; shift
  { echo '#!/usr/bin/env bash'; echo 'cat >/dev/null 2>&1 || true'; printf '%s\n' "$*"; } > "$BIN/$name"
  chmod +x "$BIN/$name"
}

# codex prints the schema-conformant verdict to stdout (final message)
mk_fake fake-codex-approve \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-codex-junk \
  "printf '%s' 'this is not json at all'"

# claude prints a print-mode JSON envelope with the verdict in .result
mk_fake fake-claude-changes \
  "jq -n --arg r '{\"verdict\":\"CHANGES_REQUESTED\",\"summary\":\"needs work\",\"findings\":[{\"severity\":\"P1\",\"path\":\"x.js\",\"line\":2,\"body\":\"bug\"}]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0}'"
mk_fake fake-claude-junk \
  "jq -n '{type:\"result\",result:\"no json here\",session_id:\"t\"}'"

# key-leak canaries: exit non-zero if the adapter did NOT scrub the
# pay-per-token API-key env vars (proves plan-only billing enforcement).
# The verdict JSON is printed raw; both adapters accept that shape.
mk_fake fake-codex-keyleak \
  "if [ -n \"\${OPENAI_API_KEY:-}\${CODEX_API_KEY:-}\" ]; then echo API-KEY-LEAKED >&2; exit 7; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-claude-keyleak \
  "if [ -n \"\${ANTHROPIC_API_KEY:-}\${ANTHROPIC_AUTH_TOKEN:-}\" ]; then echo API-KEY-LEAKED >&2; exit 7; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'"

# ===========================================================================
echo "lib.sh — reviewer selection"
# ===========================================================================
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"
# shellcheck source=../scripts/phase-4b/lib.sh
. "$LIB"

r="$(p4b_select_reviewer claude || true)"
[ "$r" = "nathanpayne-codex" ] && pass "author=claude selects nathanpayne-codex (default external)" \
  || fail "author=claude -> '$r' (expected nathanpayne-codex)"

r="$(p4b_select_reviewer codex || true)"
[ "$r" = "nathanpayne-claude" ] && pass "author=codex rotates off default to nathanpayne-claude" \
  || fail "author=codex -> '$r' (expected nathanpayne-claude)"

r="$(p4b_select_reviewer cursor || true)"
[ "$r" = "nathanpayne-codex" ] && pass "author=cursor selects nathanpayne-codex" \
  || fail "author=cursor -> '$r' (expected nathanpayne-codex)"

a="$(p4b_adapter_of_login nathanpayne-codex)"
[ "$a" = "codex" ] && pass "adapter_of_login(nathanpayne-codex)=codex" || fail "adapter_of_login codex -> '$a'"
a="$(p4b_adapter_of_login nathanpayne-claude)"
[ "$a" = "claude" ] && pass "adapter_of_login(nathanpayne-claude)=claude" || fail "adapter_of_login claude -> '$a'"

# ===========================================================================
echo "lib.sh — verdict validation (fail-closed)"
# ===========================================================================
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[]}'; then
  pass "valid APPROVED accepted"; else fail "valid APPROVED rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P0","path":null,"line":null,"body":"y"}]}'; then
  pass "valid CHANGES_REQUESTED accepted"; else fail "valid CHANGES_REQUESTED rejected"; fi
if p4b_validate_verdict '{"verdict":"MAYBE","summary":"x","findings":[]}'; then
  fail "bogus verdict value accepted"; else pass "bogus verdict value rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","findings":[]}'; then
  fail "missing summary accepted"; else pass "missing summary rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P9","body":"y"}]}'; then
  fail "bad severity accepted"; else pass "bad severity rejected"; fi
if p4b_validate_verdict 'not json'; then
  fail "non-JSON accepted"; else pass "non-JSON rejected"; fi
unset MERGEPATH_REVIEW_POLICY_PATH

# ===========================================================================
echo "adapters — normalized verdict output + fail-closed"
# ===========================================================================
set +e
out="$(CODEX_BIN="$BIN/fake-codex-approve" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter emits normalized APPROVED verdict"
else fail "codex adapter APPROVED (rc=$rc, out=$out)"; fi

set +e
CODEX_BIN="$BIN/fake-codex-junk" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "codex adapter fails closed (exit 4) on non-conformant output" \
  || fail "codex adapter junk should exit 4 (got $rc)"

set +e
out="$(CLAUDE_BIN="$BIN/fake-claude-changes" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "CHANGES_REQUESTED" ]; then
  pass "claude adapter extracts verdict from .result envelope"
else fail "claude adapter CHANGES_REQUESTED (rc=$rc, out=$out)"; fi

set +e
CLAUDE_BIN="$BIN/fake-claude-junk" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter fails closed (exit 4) on junk result" \
  || fail "claude adapter junk should exit 4 (got $rc)"

# ===========================================================================
echo "adapters — plan-only billing (API keys scrubbed before the CLI runs)"
# ===========================================================================
# If the adapter forwarded OPENAI_API_KEY/CODEX_API_KEY the fake exits 7
# and the adapter reports rc 4; a clean APPROVED proves the keys were scrubbed.
set +e
out="$(OPENAI_API_KEY=sk-should-scrub CODEX_API_KEY=sk-should-scrub \
  CODEX_BIN="$BIN/fake-codex-keyleak" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter scrubs OPENAI_API_KEY/CODEX_API_KEY (plan-only billing)"
else fail "codex adapter leaked an API key to the CLI (rc=$rc, out=$out)"; fi

set +e
out="$(ANTHROPIC_API_KEY=sk-should-scrub ANTHROPIC_AUTH_TOKEN=tok-should-scrub \
  CLAUDE_BIN="$BIN/fake-claude-keyleak" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter scrubs ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN (plan-only billing)"
else fail "claude adapter leaked an API key to the CLI (rc=$rc, out=$out)"; fi

# ===========================================================================
echo "orchestrator — entry decision + dispatch (dry-run, offline)"
# ===========================================================================
# automation disabled → exit 5
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" bash "$ORCH" 123 --repo o/r 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(printf '%s' "$out" | jq -r '.skipped')" = "true" ]; then
  pass "automation disabled → exit 5, skipped"
else fail "disabled path (rc=$rc, out=$out)"; fi

# Direction A: author=claude → reviewer codex → APPROVED → exit 0
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  bash "$ORCH" 123 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.reviewer_identity')" = "nathanpayne-codex" ] \
   && [ "$(printf '%s' "$out" | jq -r '.direction')" = "claude->codex" ] \
   && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = "false" ]; then
  pass "Direction A (claude→codex) dry-run APPROVED → exit 0, would post as nathanpayne-codex"
else fail "Direction A (rc=$rc): $out"; fi

# Direction B: author=codex → reviewer claude → CHANGES_REQUESTED → exit 1
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CLAUDE_BIN="$BIN/fake-claude-changes" \
  bash "$ORCH" 124 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "CHANGES_REQUESTED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.direction')" = "codex->claude" ] \
   && [ "$(printf '%s' "$out" | jq -r '.findings_count')" = "1" ]; then
  pass "Direction B (codex→claude) dry-run CHANGES_REQUESTED → exit 1"
else fail "Direction B (rc=$rc): $out"; fi

# Fail-closed: adapter returns junk → orchestrator falls back, exit 4, never APPROVED
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-junk" \
  bash "$ORCH" 125 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ]; then
  pass "junk adapter verdict → fail closed to manual handoff (exit 4), no auto-approve"
else fail "fail-closed path (rc=$rc): $out"; fi

# No adapter for the selected reviewer (cursor) → manual fallback, exit 4
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  bash "$ORCH" 126 --repo o/r --reviewer nathanpayne-cursor --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ]; then
  pass "unsupported reviewer (cursor, no adapter) → manual fallback (exit 4)"
else fail "unsupported-reviewer path (rc=$rc): $out"; fi

# Bad PR# → exit 3
set +e
bash "$ORCH" abc --repo o/r >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && pass "non-integer PR# rejected with exit 3" || fail "bad PR# should exit 3 (got $rc)"

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
