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

POLICY_P2_REQUIRED="$WORK/policy-p2-required.yml"
cat > "$POLICY_P2_REQUIRED" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: required
    p3: discretionary
    nitpick: discretionary
YAML

POLICY_ADDRESS_ALL="$WORK/policy-address-all.yml"
cat > "$POLICY_ADDRESS_ALL" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
feedback_policy:
  mode: address-all
YAML

POLICY_CURSOR_FIRST="$WORK/policy-cursor-first.yml"
cat > "$POLICY_CURSOR_FIRST" <<'YAML'
available_reviewers:
  - nathanpayne-cursor
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
YAML

POLICY_BAD_FEEDBACK="$WORK/policy-bad-feedback.yml"
cat > "$POLICY_BAD_FEEDBACK" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
feedback_policy:
  mode: surprise
YAML

CODEX_AUTH_CHATGPT="$WORK/codex-auth-chatgpt.json"
CODEX_AUTH_API="$WORK/codex-auth-api.json"
cat > "$CODEX_AUTH_CHATGPT" <<'JSON'
{"auth_mode":"chatgpt"}
JSON
cat > "$CODEX_AUTH_API" <<'JSON'
{"auth_mode":"api_key"}
JSON

CLAUDE_AUTH_PLAN="$WORK/claude-auth-plan.json"
CLAUDE_AUTH_OAUTH_PLAN="$WORK/claude-auth-oauth-plan.json"
CLAUDE_AUTH_API="$WORK/claude-auth-api.json"
cat > "$CLAUDE_AUTH_PLAN" <<'JSON'
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}
JSON
cat > "$CLAUDE_AUTH_OAUTH_PLAN" <<'JSON'
{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty","subscriptionType":null}
JSON
cat > "$CLAUDE_AUTH_API" <<'JSON'
{"loggedIn":true,"authMethod":"apiKey","apiProvider":"anthropic","subscriptionType":null}
JSON
export P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT"
export P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN"

BIN="$WORK/bin"; mkdir -p "$BIN"

mk_fake() { # mk_fake <name> <body-after-stdin-drain>
  local name="$1"; shift
  { echo '#!/usr/bin/env bash'; echo 'cat >/dev/null 2>&1 || true'; printf '%s\n' "$*"; } > "$BIN/$name"
  chmod +x "$BIN/$name"
}

# codex prints the schema-conformant verdict to stdout (final message)
mk_fake fake-codex-approve \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-codex-approve-p2 \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P2\",\"path\":\"x.js\",\"line\":2,\"body\":\"should be handled under stricter policy\"}]}'"
mk_fake fake-codex-junk \
  "printf '%s' 'this is not json at all'"
mk_fake fake-codex-usage \
  "printf '%s\n' 'tokens used' >&2
printf '%s\n' '1,234' >&2
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-codex-arg-order \
  "if [ \"\${1:-}\" != '--ask-for-approval' ] || [ \"\${2:-}\" != 'never' ] || [ \"\${3:-}\" != 'exec' ]; then echo BAD-CODEX-ARG-ORDER >&2; exit 8; fi
shift 3
for arg in \"\$@\"; do if [ \"\$arg\" = '--ask-for-approval' ]; then echo STALE-CODEX-EXEC-FLAG >&2; exit 9; fi; done
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"

# claude prints a print-mode JSON envelope with the verdict in .result
mk_fake fake-claude-changes \
  "jq -n --arg r '{\"verdict\":\"CHANGES_REQUESTED\",\"summary\":\"needs work\",\"findings\":[{\"severity\":\"P1\",\"path\":\"x.js\",\"line\":2,\"body\":\"bug\"}]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0}'"
mk_fake fake-claude-approve-usage \
  "jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",usage:{input_tokens:120,output_tokens:30,total_tokens:150}}'"
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
mk_fake fake-codex-gh-token-leak \
  "if [ -n \"\${GH_TOKEN:-}\${GITHUB_TOKEN:-}\${GH_ENTERPRISE_TOKEN:-}\${GITHUB_ENTERPRISE_TOKEN:-}\${OP_PREFLIGHT_REVIEWER_PAT:-}\${OP_PREFLIGHT_AUTHOR_PAT:-}\" ]; then echo GH-TOKEN-LEAKED >&2; exit 7; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-claude-gh-token-leak \
  "if [ -n \"\${GH_TOKEN:-}\${GITHUB_TOKEN:-}\${GH_ENTERPRISE_TOKEN:-}\${GITHUB_ENTERPRISE_TOKEN:-}\${OP_PREFLIGHT_REVIEWER_PAT:-}\${OP_PREFLIGHT_AUTHOR_PAT:-}\" ]; then echo GH-TOKEN-LEAKED >&2; exit 7; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'"
mk_fake fake-codex-sleep \
  "sleep 5
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"too late\",\"findings\":[]}'"
mk_fake fake-claude-sleep \
  "sleep 5
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"too late\",\"findings\":[]}'"
mk_fake fake-handoff \
  "printf '%s\n' \"\$*\" > \"\${P4B_HANDOFF_LOG:?}\""
NO_JQ_DIR="$WORK/no-jq-bin"
mkdir -p "$NO_JQ_DIR"
cat > "$NO_JQ_DIR/jq" <<'SH'
#!/usr/bin/env bash
echo "jq intentionally unavailable" >&2
exit 127
SH
chmod +x "$NO_JQ_DIR/jq"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "${2:-}" in
    repos/o/r/pulls/*)
      printf '%s\n' "${P4B_FAKE_LIVE_HEAD:-abc123}"
      exit 0
      ;;
  esac
fi
echo "unexpected fake gh invocation: $*" >&2
exit 127
SH
chmod +x "$BIN/gh"

cat > "$BIN/fake-gh-as-reviewer" <<'SH'
#!/usr/bin/env bash
{
  printf 'OP_PREFLIGHT_REVIEWER_PAT=%s\n' "${OP_PREFLIGHT_REVIEWER_PAT:-}"
  printf '%s\n' "$*"
} > "${P4B_WRAPPER_LOG:?}"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--input" ]; then
    if [ -n "${P4B_WRAPPER_PAYLOAD:-}" ]; then
      cp "${2:?}" "$P4B_WRAPPER_PAYLOAD"
    fi
    if [ -n "${P4B_WRAPPER_BODY:-}" ]; then
      jq -r '.body' "${2:?}" > "$P4B_WRAPPER_BODY"
    fi
    printf '{"id":1,"commit_id":"%s"}\n' "${P4B_FAKE_CREATED_REVIEW_HEAD:-abc123}"
    exit 0
  fi
  if [ "$1" = "--body-file" ]; then
    cp "${2:?}" "${P4B_WRAPPER_BODY:?}"
    break
  fi
  shift
done
printf '{"id":1,"commit_id":"%s"}\n' "${P4B_FAKE_CREATED_REVIEW_HEAD:-abc123}"
SH
chmod +x "$BIN/fake-gh-as-reviewer"

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

r="$(p4b_select_reviewer Codex || true)"
[ "$r" = "nathanpayne-claude" ] && pass "author=Codex normalizes case before reviewer selection" \
  || fail "author=Codex -> '$r' (expected nathanpayne-claude)"

export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_CURSOR_FIRST"
r="$(p4b_select_reviewer codex || true)"
[ "$r" = "nathanpayne-claude" ] && pass "author=codex skips unsupported reviewer when a supported adapter exists" \
  || fail "cursor-first author=codex -> '$r' (expected nathanpayne-claude)"
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"

r="$(p4b_select_reviewer cursor || true)"
[ "$r" = "nathanpayne-codex" ] && pass "author=cursor selects nathanpayne-codex" \
  || fail "author=cursor -> '$r' (expected nathanpayne-codex)"

a="$(p4b_adapter_of_login nathanpayne-codex)"
[ "$a" = "codex" ] && pass "adapter_of_login(nathanpayne-codex)=codex" || fail "adapter_of_login codex -> '$a'"
a="$(p4b_adapter_of_login NATHANPAYNE-CODEX)"
[ "$a" = "codex" ] && pass "adapter_of_login(NATHANPAYNE-CODEX)=codex" || fail "adapter_of_login uppercase codex -> '$a'"
a="$(p4b_adapter_of_login nathanpayne-claude)"
[ "$a" = "claude" ] && pass "adapter_of_login(nathanpayne-claude)=claude" || fail "adapter_of_login claude -> '$a'"

# ===========================================================================
echo "lib.sh — verdict validation (fail-closed)"
# ===========================================================================
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null}'; then
  pass "valid APPROVED accepted"; else fail "valid APPROVED rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P0","path":null,"line":null,"body":"y"}],"usage":null}'; then
  pass "valid CHANGES_REQUESTED accepted"; else fail "valid CHANGES_REQUESTED rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P2","path":"x.js","line":2,"body":"follow-up"}],"usage":null}'; then
  pass "APPROVED with advisory finding accepted"; else fail "APPROVED with advisory finding rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P1","path":"x.js","line":2,"body":"blocks merge"}],"usage":null}'; then
  fail "APPROVED with blocking finding accepted"; else pass "APPROVED with blocking finding rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_P2_REQUIRED"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P2","path":"x.js","line":2,"body":"policy-required"}],"usage":null}'; then
  fail "APPROVED with policy-required P2 finding accepted"; else pass "APPROVED with policy-required P2 finding rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ADDRESS_ALL"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P3","path":"x.js","line":2,"body":"address all"}],"usage":null}'; then
  fail "APPROVED with address-all finding accepted"; else pass "APPROVED with address-all finding rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_BAD_FEEDBACK"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null}'; then
  fail "invalid feedback_policy mode accepted"; else pass "invalid feedback_policy mode rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"
if p4b_validate_verdict '{"verdict":"MAYBE","summary":"x","findings":[],"usage":null}'; then
  fail "bogus verdict value accepted"; else pass "bogus verdict value rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","findings":[],"usage":null}'; then
  fail "missing summary accepted"; else pass "missing summary rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P9","body":"y"}],"usage":null}'; then
  fail "bad severity accepted"; else pass "bad severity rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","body":"y"}],"usage":null}'; then
  fail "finding missing path/line accepted"; else pass "finding missing path/line rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","path":"x.js","line":0,"body":"y"}],"usage":null}'; then
  fail "non-positive line accepted"; else pass "non-positive line rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"extra":true}'; then
  fail "top-level extra property accepted"; else pass "top-level extra property rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","path":"x.js","line":2,"body":"y","extra":true}],"usage":null}'; then
  fail "finding extra property accepted"; else pass "finding extra property rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":120,"output_tokens":30,"source":"claude-json-envelope"}}'; then
  pass "valid usage metadata accepted"; else fail "valid usage metadata rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150}}'; then
  fail "partial usage metadata accepted"; else pass "partial usage metadata rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[]}'; then
  fail "missing usage accepted"; else pass "missing usage rejected"; fi
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
out="$(CODEX_BIN="$BIN/fake-codex-arg-order" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter passes approval policy before exec (matches real CLI)"
else fail "codex adapter arg order (rc=$rc, out=$out)"; fi

set +e
out="$(CODEX_BIN="$BIN/fake-codex-usage" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.usage.token_count')" = "1234" ] \
   && [ "$(printf '%s' "$out" | jq -r '.usage.source')" = "codex-cli-stderr" ]; then
  pass "codex adapter records token usage when CLI exposes it"
else fail "codex adapter token usage (rc=$rc, out=$out)"; fi

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

set +e
out="$(P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_OAUTH_PLAN" CLAUDE_BIN="$BIN/fake-claude-approve-usage" \
  bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter accepts first-party Claude Code OAuth token auth"
else fail "claude adapter should accept oauth_token first-party auth (rc=$rc, out=$out)"; fi

set +e
P4B_CODEX_AUTH_FILE="$CODEX_AUTH_API" CODEX_BIN="$BIN/fake-codex-approve" \
  bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "codex adapter rejects persisted API-key auth mode" \
  || fail "codex adapter should reject API-key auth mode with exit 4 (got $rc)"

set +e
P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_API" CLAUDE_BIN="$BIN/fake-claude-approve-usage" \
  bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter rejects persisted API-key auth mode" \
  || fail "claude adapter should reject API-key auth mode with exit 4 (got $rc)"

# Reviewer CLIs may reason over hostile diffs, so they must not inherit
# GitHub write/read tokens. The parent orchestrator keeps PATs for the
# later gh-as-reviewer.sh write; the child CLI gets none of them.
set +e
out="$(GH_TOKEN=ghp-reviewer GITHUB_TOKEN=ghp-actions GH_ENTERPRISE_TOKEN=ghp-ent \
  GITHUB_ENTERPRISE_TOKEN=ghp-ent2 OP_PREFLIGHT_REVIEWER_PAT=ghp-reviewer OP_PREFLIGHT_AUTHOR_PAT=ghp-author \
  CODEX_BIN="$BIN/fake-codex-gh-token-leak" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter scrubs GitHub token env before reviewer CLI"
else fail "codex adapter leaked a GitHub token to the CLI (rc=$rc, out=$out)"; fi

set +e
out="$(GH_TOKEN=ghp-reviewer GITHUB_TOKEN=ghp-actions GH_ENTERPRISE_TOKEN=ghp-ent \
  GITHUB_ENTERPRISE_TOKEN=ghp-ent2 OP_PREFLIGHT_REVIEWER_PAT=ghp-reviewer OP_PREFLIGHT_AUTHOR_PAT=ghp-author \
  CLAUDE_BIN="$BIN/fake-claude-gh-token-leak" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter scrubs GitHub token env before reviewer CLI"
else fail "claude adapter leaked a GitHub token to the CLI (rc=$rc, out=$out)"; fi

# Bounded execution: hung auth/network/model calls fail closed to manual
# handoff instead of wedging the Phase 4b path.
set +e
P4B_REVIEW_CLI_TIMEOUT_SECONDS=1 CODEX_BIN="$BIN/fake-codex-sleep" \
  bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "codex adapter times out hung CLI with exit 4" \
  || fail "codex adapter sleep should timeout with exit 4 (got $rc)"

set +e
P4B_REVIEW_CLI_TIMEOUT_SECONDS=1 CLAUDE_BIN="$BIN/fake-claude-sleep" \
  bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter times out hung CLI with exit 4" \
  || fail "claude adapter sleep should timeout with exit 4 (got $rc)"

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

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" PATH="$NO_JQ_DIR:$PATH" bash "$ORCH" 123 --repo o/r 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(printf '%s' "$out" | jq -r '.skipped')" = "true" ]; then
  pass "automation disabled → exit 5 even when jq is unavailable"
else fail "disabled path without jq (rc=$rc, out=$out)"; fi

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
HANDOFF_LOG="$WORK/handoff-junk.log"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-junk" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" \
  bash "$ORCH" 125 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && [ "$(cat "$HANDOFF_LOG")" = "o/r#125" ]; then
  pass "junk adapter verdict → fail closed to manual handoff for target repo, no auto-approve"
else fail "fail-closed path (rc=$rc): $out"; fi

# #574 feedback_policy: a finding in a configured required tier cannot be
# carried by an approval, even when the adapter output is otherwise valid.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_P2_REQUIRED" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  bash "$ORCH" 131 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ]; then
  pass "policy-required finding in APPROVED verdict → manual fallback, no auto-approve"
else fail "policy-required finding fallback (rc=$rc): $out"; fi

# Repo policy requires post-review issues for observations/risks flagged while
# approving. The schema can carry advisory findings, but the automated poster
# cannot clear the merge gate until that follow-up path has been handled.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  bash "$ORCH" 133 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.reason')" = "approved verdict included findings; post-review issue filing is required before Phase 4b clearance" ]; then
  pass "APPROVED with advisory findings → manual fallback until post-review issues exist"
else fail "approved-with-advisory fallback (rc=$rc): $out"; fi

# Stale-head guard: a non-dry-run APPROVED must re-read the live head and
# fall back before the wrapper writes if the reviewed SHA is no longer live.
WRAPPER_LOG="$WORK/wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_FAKE_LIVE_HEAD=def456 \
  bash "$ORCH" 127 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.reason')" = "PR head changed during review (reviewed abc123, live def456)" ] \
   && [ ! -e "$WRAPPER_LOG" ]; then
  pass "live head drift before posting → manual fallback, no review write"
else fail "stale-head guard (rc=$rc, out=$out, wrapper_log=$(test -e "$WRAPPER_LOG" && cat "$WRAPPER_LOG" || true))"; fi

WRAPPER_LOG="$WORK/wrapper-success.log"
WRAPPER_BODY="$WORK/wrapper-success-body.md"
WRAPPER_PAYLOAD="$WORK/wrapper-success-payload.json"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  OP_PREFLIGHT_REVIEWER_PAT=wrong-current-agent-token P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 129 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = "true" ] \
   && grep -q -- "api repos/o/r/pulls/129/reviews --method POST --input" "$WRAPPER_LOG" \
   && jq -e '.commit_id == "abc123" and .event == "APPROVE"' "$WRAPPER_PAYLOAD" >/dev/null \
   && grep -q -- "OP_PREFLIGHT_REVIEWER_PAT=$" "$WRAPPER_LOG" \
   && grep -q -- "Reviewed head: \`abc123\`" "$WRAPPER_BODY" \
   && grep -q -- "Reviewer identity: \`nathanpayne-codex\`" "$WRAPPER_BODY" \
   && grep -q -- "Adapter runs: \`1\`" "$WRAPPER_BODY" \
   && grep -q -- "Token usage: not exposed by adapter/CLI" "$WRAPPER_BODY" \
   && grep -q -- "Model-internal turn count: not exposed" "$WRAPPER_BODY"; then
  pass "posted approval pins reviewed head, unsets stale preferred reviewer PAT, and records review metadata"
else fail "success review metadata (rc=$rc, out=$out, log=$(test -e "$WRAPPER_LOG" && cat "$WRAPPER_LOG" || true), body=$(test -e "$WRAPPER_BODY" && cat "$WRAPPER_BODY" || true))"; fi

WRAPPER_LOG="$WORK/wrapper-mismatch.log"
WRAPPER_BODY="$WORK/wrapper-mismatch-body.md"
WRAPPER_PAYLOAD="$WORK/wrapper-mismatch-payload.json"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=def456 \
  bash "$ORCH" 132 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 3 ] && jq -e '.commit_id == "abc123" and .event == "APPROVE"' "$WRAPPER_PAYLOAD" >/dev/null; then
  pass "created review commit mismatch fails closed after pinned API post"
else fail "created-review commit mismatch (rc=$rc, out=$out, payload=$(test -e "$WRAPPER_PAYLOAD" && cat "$WRAPPER_PAYLOAD" || true))"; fi

WRAPPER_LOG="$WORK/wrapper-usage.log"
WRAPPER_BODY="$WORK/wrapper-usage-body.md"
WRAPPER_PAYLOAD="$WORK/wrapper-usage-payload.json"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CLAUDE_BIN="$BIN/fake-claude-approve-usage" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 130 --repo o/r --author codex --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.token_count')" = "150" ] \
   && [ "$(printf '%s' "$out" | jq -r '.usage_source')" = "claude-json-envelope" ] \
   && jq -e '.commit_id == "abc123" and .event == "APPROVE"' "$WRAPPER_PAYLOAD" >/dev/null \
   && grep -q -- "Reviewer identity: \`nathanpayne-claude\`" "$WRAPPER_BODY" \
   && grep -q -- "Token usage: \`150\` tokens (source: \`claude-json-envelope\`)" "$WRAPPER_BODY"; then
  pass "posted approval body includes token usage when adapter exposes it"
else fail "success review token usage (rc=$rc, out=$out, log=$(test -e "$WRAPPER_LOG" && cat "$WRAPPER_LOG" || true), body=$(test -e "$WRAPPER_BODY" && cat "$WRAPPER_BODY" || true))"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-sleep" \
  P4B_ADAPTER_TIMEOUT_SECONDS=1 P4B_REVIEW_CLI_TIMEOUT_SECONDS=0 \
  bash "$ORCH" 128 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.reason')" = "adapter timed out after 1s" ]; then
  pass "orchestrator times out hung adapter and falls back"
else fail "orchestrator adapter timeout (rc=$rc): $out"; fi

# Forced reviewer override must still preserve the cross-agent invariant.
set +e
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  bash "$ORCH" 133 --repo o/r --author codex --reviewer nathanpayne-codex --head abc123 --diff-file "$DIFF" --dry-run >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && pass "forced reviewer matching author rejected with exit 3" \
  || fail "forced same-agent reviewer should exit 3 (got $rc)"

# No adapter for the selected reviewer (cursor) → manual fallback, exit 4
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  bash "$ORCH" 126 --repo o/r --author claude --reviewer nathanpayne-cursor --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
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
