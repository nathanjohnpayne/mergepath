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

POLICY_STALE_DEFAULT="$WORK/policy-stale-default.yml"
cat > "$POLICY_STALE_DEFAULT" <<'YAML'
available_reviewers:
  - nathanpayne-claude
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
# Current Codex exposes --ask-for-approval as a global option. The real CLI
# rejects `codex exec --ask-for-approval never ...`, so the adapter pins the
# global flag before the exec subcommand.
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
mk_fake fake-claude-braces \
  "jq -n --arg r 'Here is the verdict:
{\"verdict\":\"CHANGES_REQUESTED\",\"summary\":\"body has braces\",\"findings\":[{\"severity\":\"P1\",\"path\":\"x.js\",\"line\":2,\"body\":\"snippet contains { braces } and stays valid\"}]}
Done.' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0}'"
# #587: a valid verdict object FOLLOWED by prose (with a lone brace char, no
# second object). A naive first-{-to-last-} slice would swallow the trailing
# brace and corrupt the JSON; the string-aware scanner isolates the first
# object. (A trailing balanced OBJECT instead fails closed — see #594.)
mk_fake fake-claude-trailing-braces \
  "jq -n --arg r 'Here is my verdict:
{\"verdict\":\"APPROVED\",\"summary\":\"clean\",\"findings\":[]}
Looks good to me. The } below is just prose.' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0}'"
# #594: two verdict objects (draft then correction) must fail closed, not post
# the first.
mk_fake fake-claude-multi-verdict \
  "jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"draft\",\"findings\":[]}
On reflection:
{\"verdict\":\"CHANGES_REQUESTED\",\"summary\":\"final\",\"findings\":[{\"severity\":\"P1\",\"path\":\"x.js\",\"line\":2,\"body\":\"bug\"}]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0}'"
mk_fake fake-claude-junk \
  "jq -n '{type:\"result\",result:\"no json here\",session_id:\"t\"}'"

# key-leak canaries: exit non-zero if the adapter child env allowlist includes
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
mk_fake fake-codex-secret-leak \
  "if [ -n \"\${GOOGLE_APPLICATION_CREDENTIALS:-}\${CF_API_TOKEN:-}\${CLOUDFLARE_API_TOKEN:-}\${OP_PREFLIGHT_ADC_TMPFILE:-}\${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}\${SSH_AUTH_SOCK:-}\${AWS_ACCESS_KEY_ID:-}\${AZURE_CLIENT_SECRET:-}\${FIREBASE_TOKEN:-}\" ]; then echo SECRET-ENV-LEAKED >&2; exit 7; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-claude-secret-leak \
  "if [ -n \"\${GOOGLE_APPLICATION_CREDENTIALS:-}\${CF_API_TOKEN:-}\${CLOUDFLARE_API_TOKEN:-}\${OP_PREFLIGHT_ADC_TMPFILE:-}\${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}\${SSH_AUTH_SOCK:-}\${AWS_ACCESS_KEY_ID:-}\${AZURE_CLIENT_SECRET:-}\${FIREBASE_TOKEN:-}\" ]; then echo SECRET-ENV-LEAKED >&2; exit 7; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'"
mk_fake fake-codex-sandbox \
  "shift 3
while [ \"\$#\" -gt 0 ]; do
  if [ \"\$1\" = '--sandbox' ]; then
    [ \"\${2:-}\" = 'read-only' ] || { echo BAD-SANDBOX >&2; exit 8; }
    printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'
    exit 0
  fi
  shift
done
echo MISSING-SANDBOX >&2
exit 8"
mk_fake fake-claude-readonly \
  "permission=''
effort=''
tools='__unset__'
system_prompt_seen=false
safe_mode=false
no_persist=false
slash_disabled=false
while [ \"\$#\" -gt 0 ]; do
  case \"\$1\" in
    --permission-mode) permission=\"\${2:-}\"; shift 2 ;;
    --effort) effort=\"\${2:-}\"; shift 2 ;;
    --tools) tools=\"\${2-}\"; shift 2 ;;
    --system-prompt) system_prompt_seen=true; shift 2 ;;
    --safe-mode) safe_mode=true; shift ;;
    --no-session-persistence) no_persist=true; shift ;;
    --disable-slash-commands) slash_disabled=true; shift ;;
    *) shift ;;
  esac
done
[ \"\$permission\" = 'plan' ] || { echo BAD-PERMISSION-MODE >&2; exit 8; }
[ \"\$effort\" = 'medium' ] || { echo BAD-EFFORT >&2; exit 8; }
[ \"\$tools\" = '' ] || { echo BAD-TOOLS >&2; exit 8; }
[ \"\$system_prompt_seen\" = true ] || { echo MISSING-SYSTEM-PROMPT >&2; exit 8; }
[ \"\$safe_mode\" = true ] || { echo MISSING-SAFE-MODE >&2; exit 8; }
[ \"\$no_persist\" = true ] || { echo MISSING-NO-PERSIST >&2; exit 8; }
[ \"\$slash_disabled\" = true ] || { echo MISSING-DISABLE-SLASH >&2; exit 8; }
jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\"}'"
PARENT_HOME_FOR_TEST="$HOME"
mk_fake fake-codex-isolated \
  "cd_arg=''
while [ \"\$#\" -gt 0 ]; do
  case \"\$1\" in
    --cd) cd_arg=\"\${2:-}\"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n \"\$cd_arg\" ] || { echo MISSING-CD >&2; exit 8; }
[ \"\${HOME:-}\" != '$PARENT_HOME_FOR_TEST' ] || { echo PARENT-HOME-LEAKED >&2; exit 8; }
[ -n \"\${CODEX_HOME:-}\" ] || { echo MISSING-CODEX-HOME >&2; exit 8; }
[ -r \"\$CODEX_HOME/auth.json\" ] || { echo MISSING-ISOLATED-AUTH >&2; exit 8; }
case \"\$CODEX_HOME\" in \"\$cd_arg\"/*|\"\$cd_arg\") echo AUTH-INSIDE-REVIEW-ROOT >&2; exit 8 ;; esac
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-codex-sleep \
  "sleep 5
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"too late\",\"findings\":[]}'"
mk_fake fake-claude-sleep \
  "sleep 5
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"too late\",\"findings\":[]}'"
mk_fake fake-handoff \
  "printf '%s %s\n' \"\${PHASE_4B_REVIEWER_IDENTITY:-}\" \"\$*\" > \"\${P4B_HANDOFF_LOG:?}\""
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
[ "${1:-}" = "--" ] || { echo "expected wrapper separator" >&2; exit 64; }
[ "${2:-}" = "gh" ] || { echo "expected gh command" >&2; exit 64; }
[ "${3:-}" = "api" ] || { echo "expected gh api subcommand" >&2; exit 64; }
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

export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_STALE_DEFAULT"
r="$(p4b_select_reviewer cursor || true)"
[ "$r" = "nathanpayne-claude" ] && pass "stale default_external_reviewer is ignored unless listed in available_reviewers" \
  || fail "stale-default author=cursor -> '$r' (expected nathanpayne-claude)"
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

CODEX_HOME_ALT="$WORK/codex-home-alt"
mkdir -p "$CODEX_HOME_ALT"
cp "$CODEX_AUTH_CHATGPT" "$CODEX_HOME_ALT/auth.json"
SAVED_P4B_CODEX_AUTH_FILE="${P4B_CODEX_AUTH_FILE:-}"
SAVED_CODEX_HOME="${CODEX_HOME:-}"
unset P4B_CODEX_AUTH_FILE
CODEX_HOME="$CODEX_HOME_ALT"
auth_path="$(p4b_codex_auth_file)"
P4B_CODEX_AUTH_FILE="$SAVED_P4B_CODEX_AUTH_FILE"
CODEX_HOME="$SAVED_CODEX_HOME"
export P4B_CODEX_AUTH_FILE CODEX_HOME
[ "$auth_path" = "$CODEX_HOME_ALT/auth.json" ] && pass "codex auth lookup honors CODEX_HOME/auth.json" \
  || fail "codex auth lookup with CODEX_HOME -> '$auth_path' (expected $CODEX_HOME_ALT/auth.json)"

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
echo "lib.sh — JSON extraction hardening (#587)"
# ===========================================================================
# p4b_extract_json_block must emit the FIRST complete, balanced, top-level
# JSON object — string-aware so braces inside string values do not miscount,
# and stopping at the first object so balanced-brace prose AFTER it cannot
# extend the slice. Unbalanced input emits nothing so validation fails closed.
chk_extract() { # chk_extract <label> <input> <expected-exact-output>
  local label="$1" input="$2" want="$3" got
  got="$(p4b_extract_json_block "$input")"
  [ "$got" = "$want" ] && pass "$label" || fail "$label (got=[$got] want=[$want])"
}
chk_extract "extract: pure JSON unchanged" \
  '{"a":1}' '{"a":1}'
chk_extract "extract: leading prose skipped" \
  'blah blah {"a":1}' '{"a":1}'
chk_extract "extract: trailing prose (no second object) is ignored" \
  '{"a":1}
Looks good, ship it. The } char in prose is harmless.' '{"a":1}'
chk_extract "extract: trailing balanced-brace OBJECT prose fails closed (#594)" \
  '{"a":1}
For example { "x": { "y": 1 } } is fine.' ''
chk_extract "extract: braces inside string value preserved" \
  '{"body":"has } and { inside"}' '{"body":"has } and { inside"}'
chk_extract "extract: escaped quote before brace stays in string" \
  '{"body":"quote \" then } still in"}' '{"body":"quote \" then } still in"}'
chk_extract "extract: nested object emitted whole" \
  '{"a":{"b":2}}' '{"a":{"b":2}}'
chk_extract "extract: multiple top-level objects fail closed (#594)" \
  '{"a":1} {"b":2}' ''
chk_extract "extract: draft-then-correction multi-verdict fails closed (#594)" \
  '{"verdict":"APPROVED"}
Actually, correcting:
{"verdict":"CHANGES_REQUESTED"}' ''
chk_extract "extract: unbalanced object emits nothing (fail closed)" \
  '{"a":' ''
chk_extract "extract: no object at all emits nothing" \
  'no json here' ''
chk_extract "extract: fenced block unwrapped" \
  '```json
{"a":1}
```' '{"a":1}'

# ===========================================================================
echo "lib.sh — schema↔validator parity (#585)"
# ===========================================================================
# Pin the default policy so structural validity == validator validity for the
# fixtures (P0/P1 required, P2/P3 discretionary).
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"
SCHEMA_FILE="$ROOT/scripts/phase-4b/verdict.schema.json"
FIXTURES="$ROOT/tests/fixtures/phase_4b_verdicts.jsonl"

# (a) Behavior-locking parity fixtures: every curated verdict validates
# exactly as its `valid` label says.
[ -r "$FIXTURES" ] || fail "parity fixtures missing: $FIXTURES"
fixture_count=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  fixture_count=$((fixture_count + 1))
  name="$(printf '%s' "$line" | jq -r '.name')"
  want="$(printf '%s' "$line" | jq -r '.valid')"
  vj="$(printf '%s' "$line" | jq -c '.verdict')"
  if p4b_validate_verdict "$vj"; then got=true; else got=false; fi
  [ "$got" = "$want" ] && pass "parity fixture [$name]: validator=$got" \
    || fail "parity fixture [$name]: validator=$got but fixture says valid=$want ($vj)"
done < "$FIXTURES"
[ "$fixture_count" -ge 20 ] && pass "parity fixture corpus is non-trivial ($fixture_count cases)" \
  || fail "parity fixture corpus too small ($fixture_count)"

# (b) Anti-drift: the validator's structural constants are DERIVED from the
# schema, so its accept/reject boundaries must track the schema's own enums
# and required-key sets. If a future edit changes the schema but not the
# validator (or vice versa), one of these fails.
while IFS= read -r sev; do
  v="$(jq -nc --arg s "$sev" '{verdict:"CHANGES_REQUESTED",summary:"x",findings:[{severity:$s,path:"a",line:1,body:"b"}],usage:null}')"
  p4b_validate_verdict "$v" && pass "schema severity enum member accepted: $sev" \
    || fail "schema declares severity $sev but validator rejects it (drift)"
done < <(jq -r '.properties.findings.items.properties.severity.enum[]' "$SCHEMA_FILE")
for bogus in P4 PX p1 P; do
  v="$(jq -nc --arg s "$bogus" '{verdict:"CHANGES_REQUESTED",summary:"x",findings:[{severity:$s,path:"a",line:1,body:"b"}],usage:null}')"
  p4b_validate_verdict "$v" && fail "severity outside schema enum accepted: $bogus" \
    || pass "severity outside schema enum rejected: $bogus"
done
while IFS= read -r vd; do
  v="$(jq -nc --arg v "$vd" '{verdict:$v,summary:"x",findings:[],usage:null}')"
  p4b_validate_verdict "$v" && pass "schema verdict enum member accepted: $vd" \
    || fail "schema declares verdict $vd but validator rejects it (drift)"
done < <(jq -r '.properties.verdict.enum[]' "$SCHEMA_FILE")
while IFS= read -r key; do
  v="$(jq -c --arg k "$key" 'del(.[$k])' <<<'{"verdict":"APPROVED","summary":"x","findings":[],"usage":null}')"
  p4b_validate_verdict "$v" && fail "verdict missing schema-required key accepted: $key" \
    || pass "verdict missing schema-required key rejected: $key"
done < <(jq -r '.required[]' "$SCHEMA_FILE")

# (b') Malformed schema (#594): an enum degraded to a SCALAR string must fail
# closed, not let jq's `index` do substring matching (which would accept
# "APPROVED"/"P1"). Point P4B_VERDICT_SCHEMA_PATH at a bad schema and confirm an
# otherwise-valid verdict is rejected.
BAD_SCHEMA="$WORK/bad-schema.json"
jq '.properties.verdict.enum = "APPROVED"' "$SCHEMA_FILE" > "$BAD_SCHEMA"
if P4B_VERDICT_SCHEMA_PATH="$BAD_SCHEMA" p4b_validate_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":null}'; then
  fail "scalar verdict enum in a malformed schema accepted (should fail closed)"
else pass "malformed schema (verdict enum as scalar) fails closed"; fi
jq '.properties.findings.items.properties.severity.enum = "P1"' "$SCHEMA_FILE" > "$BAD_SCHEMA"
if P4B_VERDICT_SCHEMA_PATH="$BAD_SCHEMA" p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","path":"a","line":1,"body":"b"}],"usage":null}'; then
  fail "scalar severity enum in a malformed schema accepted (should fail closed)"
else pass "malformed schema (severity enum as scalar) fails closed"; fi

# (c) Optional independent cross-check against the JSON Schema itself. The
# validator is a superset of the schema (it adds the feedback_policy gate), so
# every fixture the validator ACCEPTS must also be schema-valid. Runs only when
# a JSON Schema validator is installed; when none is present it skips cleanly,
# the same optional-tool posture the lint step uses.
schema_validate() { # schema_validate <datafile> -> rc 0 valid / non-zero invalid
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$SCHEMA_FILE" "$1" >/dev/null 2>&1
  elif command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$SCHEMA_FILE" -d "$1" >/dev/null 2>&1
  else
    return 2
  fi
}
if command -v check-jsonschema >/dev/null 2>&1 || command -v ajv >/dev/null 2>&1; then
  xcheck=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | jq -r '.valid')" = "true" ] || continue
    name="$(printf '%s' "$line" | jq -r '.name')"
    df="$WORK/xcheck.json"
    printf '%s' "$line" | jq -c '.verdict' > "$df"
    if schema_validate "$df"; then pass "schema cross-check: validator-accepted [$name] is schema-valid"
    else fail "schema cross-check: validator accepts [$name] but JSON Schema rejects it"; fi
    xcheck=$((xcheck + 1))
  done < "$FIXTURES"
  [ "$xcheck" -gt 0 ] && pass "external JSON Schema cross-check ran on $xcheck accepted fixtures" \
    || fail "external JSON Schema cross-check found no accepted fixtures"
else
  echo "  SKIP: no JSON Schema validator (check-jsonschema/ajv) — schema cross-check skipped"
fi
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
out="$(CLAUDE_BIN="$BIN/fake-claude-braces" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.findings[0].body == "snippet contains { braces } and stays valid"' >/dev/null; then
  pass "claude adapter extracts verdict when finding text contains braces"
else fail "claude adapter braces extraction (rc=$rc, out=$out)"; fi

# #587: prose (no second object) AFTER the JSON object must not poison
# extraction; the adapter still returns the first object's clean verdict.
set +e
out="$(CLAUDE_BIN="$BIN/fake-claude-trailing-braces" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.findings | length')" = "0" ]; then
  pass "claude adapter ignores trailing prose after the JSON object (#587)"
else fail "claude adapter trailing-prose extraction (rc=$rc, out=$out)"; fi

# #594: two verdict objects (draft + correction) → fail closed, never post the
# first (which could be an APPROVED the model then retracted).
set +e
CLAUDE_BIN="$BIN/fake-claude-multi-verdict" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter fails closed (exit 4) on multi-verdict output (#594)" \
  || fail "claude adapter multi-verdict should exit 4 (got $rc)"

set +e
CLAUDE_BIN="$BIN/fake-claude-junk" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter fails closed (exit 4) on junk result" \
  || fail "claude adapter junk should exit 4 (got $rc)"

# ===========================================================================
echo "adapters — plan-only billing (child env allowlist before the CLI runs)"
# ===========================================================================
# If the adapter forwarded OPENAI_API_KEY/CODEX_API_KEY the fake exits 7
# and the adapter reports rc 4; a clean APPROVED proves the keys were excluded.
set +e
out="$(OPENAI_API_KEY=sk-should-scrub CODEX_API_KEY=sk-should-scrub \
  CODEX_BIN="$BIN/fake-codex-keyleak" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter excludes OPENAI_API_KEY/CODEX_API_KEY (plan-only billing)"
else fail "codex adapter leaked an API key to the CLI (rc=$rc, out=$out)"; fi

set +e
out="$(ANTHROPIC_API_KEY=sk-should-scrub ANTHROPIC_AUTH_TOKEN=tok-should-scrub \
  CLAUDE_BIN="$BIN/fake-claude-keyleak" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter excludes ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN (plan-only billing)"
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
  pass "codex adapter excludes GitHub token env before reviewer CLI"
else fail "codex adapter leaked a GitHub token to the CLI (rc=$rc, out=$out)"; fi

set +e
out="$(GH_TOKEN=ghp-reviewer GITHUB_TOKEN=ghp-actions GH_ENTERPRISE_TOKEN=ghp-ent \
  GITHUB_ENTERPRISE_TOKEN=ghp-ent2 OP_PREFLIGHT_REVIEWER_PAT=ghp-reviewer OP_PREFLIGHT_AUTHOR_PAT=ghp-author \
  CLAUDE_BIN="$BIN/fake-claude-gh-token-leak" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter excludes GitHub token env before reviewer CLI"
else fail "claude adapter leaked a GitHub token to the CLI (rc=$rc, out=$out)"; fi

set +e
out="$(GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json CF_API_TOKEN=cf-token CLOUDFLARE_API_TOKEN=cf-token2 \
  OP_PREFLIGHT_ADC_TMPFILE=/tmp/adc OP_PREFLIGHT_FIREBASE_SA_TMPFILE=/tmp/firebase SSH_AUTH_SOCK=/tmp/ssh.sock \
  AWS_ACCESS_KEY_ID=aws-key AZURE_CLIENT_SECRET=azure-secret FIREBASE_TOKEN=firebase-token \
  CODEX_BIN="$BIN/fake-codex-secret-leak" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter allowlists child env and strips deploy/cloud credentials"
else fail "codex adapter leaked deploy/cloud credential env to CLI (rc=$rc, out=$out)"; fi

set +e
out="$(GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json CF_API_TOKEN=cf-token CLOUDFLARE_API_TOKEN=cf-token2 \
  OP_PREFLIGHT_ADC_TMPFILE=/tmp/adc OP_PREFLIGHT_FIREBASE_SA_TMPFILE=/tmp/firebase SSH_AUTH_SOCK=/tmp/ssh.sock \
  AWS_ACCESS_KEY_ID=aws-key AZURE_CLIENT_SECRET=azure-secret FIREBASE_TOKEN=firebase-token \
  CLAUDE_CODE_OAUTH_TOKEN=oauth-ok CLAUDE_BIN="$BIN/fake-claude-secret-leak" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter allowlists child env and strips deploy/cloud credentials"
else fail "claude adapter leaked deploy/cloud credential env to CLI (rc=$rc, out=$out)"; fi

set +e
out="$(P4B_CODEX_SANDBOX=danger-full-access CODEX_BIN="$BIN/fake-codex-sandbox" \
  bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter pins sandbox to read-only despite env override"
else fail "codex adapter honored unsafe sandbox override (rc=$rc, out=$out)"; fi

set +e
out="$(P4B_CLAUDE_PERMISSION_MODE=bypassPermissions P4B_CLAUDE_ALLOWED_TOOLS='Write,Bash(rm *)' \
  CLAUDE_BIN="$BIN/fake-claude-readonly" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter disables tools and pins permission mode despite env override"
else fail "claude adapter honored unsafe permission/tool override (rc=$rc, out=$out)"; fi

set +e
out="$(CODEX_BIN="$BIN/fake-codex-isolated" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter uses isolated HOME/CODEX_HOME outside review root"
else fail "codex adapter did not isolate HOME/CODEX_HOME from review root (rc=$rc, out=$out)"; fi

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

PREFLIGHT_TRAP_DIR="$WORK/preflight-trap"
mkdir -p "$PREFLIGHT_TRAP_DIR"
cat > "$PREFLIGHT_TRAP_DIR/op-preflight-codex.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH='$(date +%s)'
echo PREFLIGHT_SHOULD_NOT_SOURCE >&2
exit 97
EOF
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" OP_PREFLIGHT_CACHE_DIR="$PREFLIGHT_TRAP_DIR" MERGEPATH_AGENT=codex bash "$ORCH" 123 --repo o/r 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(printf '%s' "$out" | jq -r '.skipped')" = "true" ]; then
  pass "automation disabled does not source reviewer preflight"
else fail "disabled path sourced preflight or failed unexpectedly (rc=$rc, out=$out)"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" PATH="$NO_JQ_DIR:$PATH" bash "$ORCH" 123 --repo o/r 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(printf '%s' "$out" | jq -r '.skipped')" = "true" ]; then
  pass "automation disabled → exit 5 even when jq is unavailable"
else fail "disabled path without jq (rc=$rc, out=$out)"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" bash "$ORCH" 123 --repo $'o/r\nextra' 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && printf '%s' "$out" | jq -e '.repo == "o/r\nextra"' >/dev/null; then
  pass "automation disabled JSON escapes control characters"
else fail "disabled path JSON escaping (rc=$rc, out=$out)"; fi

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
   && [ "$(cat "$HANDOFF_LOG")" = "nathanpayne-codex o/r#125" ]; then
  pass "junk adapter verdict → fail closed to manual handoff for target repo, no auto-approve"
else fail "fail-closed path (rc=$rc): $out"; fi

HANDOFF_LOG="$WORK/handoff-claude.log"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CLAUDE_BIN="$BIN/fake-claude-junk" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" \
  bash "$ORCH" 126 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && [ "$(cat "$HANDOFF_LOG")" = "nathanpayne-claude o/r#126" ]; then
  pass "manual fallback handoff targets the selected Claude reviewer for codex-authored PRs"
else fail "claude fallback target (rc=$rc): $out"; fi

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
