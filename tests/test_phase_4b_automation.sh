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

# (#602) The approval-loop accounting hook defaults ON under an enabled
# phase_4b_automation block, so the orchestrator runs below would otherwise
# write loop-log/ledger runtime state into the repo's .mergepath/. Keep the
# suite hermetic; accounting behavior itself is covered by
# tests/test_phase_4b_accounting.sh.
export P4B_ACCT_STATE_DIR="$WORK/acct-state"

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
mk_fake fake-codex-approve-risk \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P2\",\"path\":\"x.js\",\"line\":2,\"body\":\"residual risk of stale cache reads after failover\"}]}'"
mk_fake fake-codex-approve-p3 \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P3\",\"path\":\"x.js\",\"line\":2,\"body\":\"cosmetic nit only\"}]}'"
mk_fake fake-codex-approve-2p2 \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P2\",\"path\":\"x.js\",\"line\":2,\"body\":\"first advisory\"},{\"severity\":\"P2\",\"path\":\"y.js\",\"line\":9,\"body\":\"second advisory\"}]}'"
mk_fake fake-codex-approve-p2p3 \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P2\",\"path\":\"x.js\",\"line\":2,\"body\":\"filed advisory\"},{\"severity\":\"P3\",\"path\":\"y.js\",\"line\":9,\"body\":\"suppressed nit\"}]}'"
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
      # #674 round 4: P4B_FAKE_LIVE_HEAD2 simulates a head that drifts
      # between reads — served from the SECOND live-head read on.
      cnt_file="${P4B_ISSUE_LOG:-${TMPDIR:-/tmp}/p4b-fake}.headreads"
      cnt=$(( $( [ -f "$cnt_file" ] && cat "$cnt_file" || echo 0 ) + 1 ))
      printf '%s\n' "$cnt" > "$cnt_file"
      if [ -n "${P4B_FAKE_LIVE_HEAD2:-}" ] && [ "$cnt" -ge "${P4B_FAKE_LIVE_HEAD2_FROM:-2}" ]; then
        printf '%s\n' "$P4B_FAKE_LIVE_HEAD2"
      else
        printf '%s\n' "${P4B_FAKE_LIVE_HEAD:-abc123}"
      fi
      exit 0
      ;;
  esac
fi


# dedup lookup (#674 CodeRabbit): empty by default; P4B_FAKE_EXISTING_ISSUE
# simulates a marker match from a prior partially-failed run.
if [ "${1:-}" = "search" ] && [ "${2:-}" = "issues" ]; then
  # #674 CodeRabbit Major: a search ERROR must fail the filing closed.
  [ -n "${P4B_FAKE_SEARCH_FAIL:-}" ] && exit 1
  if [ -n "${P4B_FAKE_EXISTING_ISSUE_ONCE:-}" ]; then
    scnt_file="${P4B_ISSUE_LOG:-${TMPDIR:-/tmp}/p4b-fake}.searches"
    scnt=$(( $( [ -f "$scnt_file" ] && cat "$scnt_file" || echo 0 ) + 1 ))
    printf '%s\n' "$scnt" > "$scnt_file"
    [ "$scnt" -eq 1 ] && printf 'https://github.com/o/r/issues/777\n'
    exit 0
  fi
  [ -n "${P4B_FAKE_EXISTING_ISSUE:-}" ] && printf 'https://github.com/o/r/issues/777\n'
  exit 0
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

# Author wrapper fake (#674): the step-9 issue writes route through
# gh-as-author.sh. Logs to P4B_ISSUE_LOG with the same record shapes the
# assertions key on (VIA / ARGV / CLOSE / body copies), mints incrementing
# issue URLs, honors the failure knobs.
cat > "$BIN/fake-gh-as-author" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--" ] || { echo "expected wrapper separator" >&2; exit 64; }
shift
[ "${1:-}" = "gh" ] || { echo "expected gh command" >&2; exit 64; }
shift
log="${P4B_ISSUE_LOG:-/dev/null}"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  { printf 'VIA gh-as-author\n'; printf 'ARGV gh %s\n' "$*"; } >> "$log"
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body-file" ] && [ -n "${P4B_ISSUE_LOG:-}" ]; then
      cp "$a" "${log}.body.$(grep -c '^ARGV ' "$log")"
    fi
    prev="$a"
  done
  [ -n "${P4B_FAKE_ISSUE_FAIL:-}" ] && exit 1
  if [ -n "${P4B_FAKE_ISSUE_FAIL_AFTER_1:-}" ] && [ "$(grep -c '^ARGV ' "$log")" -ge 2 ]; then
    exit 1
  fi
  printf 'https://github.com/o/r/issues/%s\n' "$((900 + $(grep -c '^ARGV ' "$log")))"
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "close" ]; then
  printf 'CLOSE #%s\n' "${3:-}" >> "$log"
  exit 0
fi
echo "unexpected fake gh-as-author invocation: $*" >&2
exit 64
SH
chmod +x "$BIN/fake-gh-as-author"

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
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"cli_version":null}'; then
  pass "valid APPROVED accepted"; else fail "valid APPROVED rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P0","path":null,"line":null,"body":"y"}],"usage":null,"cli_version":null}'; then
  pass "valid CHANGES_REQUESTED accepted"; else fail "valid CHANGES_REQUESTED rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P2","path":"x.js","line":2,"body":"follow-up"}],"usage":null,"cli_version":null}'; then
  pass "APPROVED with advisory finding accepted"; else fail "APPROVED with advisory finding rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P1","path":"x.js","line":2,"body":"blocks merge"}],"usage":null,"cli_version":null}'; then
  fail "APPROVED with blocking finding accepted"; else pass "APPROVED with blocking finding rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_P2_REQUIRED"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P2","path":"x.js","line":2,"body":"policy-required"}],"usage":null,"cli_version":null}'; then
  fail "APPROVED with policy-required P2 finding accepted"; else pass "APPROVED with policy-required P2 finding rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ADDRESS_ALL"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[{"severity":"P3","path":"x.js","line":2,"body":"address all"}],"usage":null,"cli_version":null}'; then
  fail "APPROVED with address-all finding accepted"; else pass "APPROVED with address-all finding rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_BAD_FEEDBACK"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"cli_version":null}'; then
  fail "invalid feedback_policy mode accepted"; else pass "invalid feedback_policy mode rejected"; fi
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"
if p4b_validate_verdict '{"verdict":"MAYBE","summary":"x","findings":[],"usage":null,"cli_version":null}'; then
  fail "bogus verdict value accepted"; else pass "bogus verdict value rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","findings":[],"usage":null,"cli_version":null}'; then
  fail "missing summary accepted"; else pass "missing summary rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P9","body":"y"}],"usage":null,"cli_version":null}'; then
  fail "bad severity accepted"; else pass "bad severity rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","body":"y"}],"usage":null,"cli_version":null}'; then
  fail "finding missing path/line accepted"; else pass "finding missing path/line rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","path":"x.js","line":0,"body":"y"}],"usage":null,"cli_version":null}'; then
  fail "non-positive line accepted"; else pass "non-positive line rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"extra":true}'; then
  fail "top-level extra property accepted"; else pass "top-level extra property rejected"; fi
if p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","path":"x.js","line":2,"body":"y","extra":true}],"usage":null,"cli_version":null}'; then
  fail "finding extra property accepted"; else pass "finding extra property rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":120,"output_tokens":30,"cache_creation_input_tokens":null,"cache_read_input_tokens":null,"reasoning_tokens":null,"total_cost_usd":null,"source":"claude-json-envelope"},"cli_version":null}'; then
  pass "valid usage metadata accepted"; else fail "valid usage metadata rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150}}'; then
  fail "partial usage metadata accepted"; else pass "partial usage metadata rejected"; fi
# #632: the pre-strict four-key emitter shape omits the additive #602 keys;
# required-completeness (OpenAI strict mode) must reject it.
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":120,"output_tokens":30,"source":"codex-cli-stderr"}}'; then
  fail "legacy four-key usage accepted"; else pass "legacy four-key usage rejected (#632 required-complete)"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[]}'; then
  fail "missing usage accepted"; else pass "missing usage rejected"; fi
# #622: cli_version follows the same required-but-nullable contract as usage.
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"cli_version":"codex-cli 0.137.0"}'; then
  pass "populated cli_version accepted"; else fail "populated cli_version rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null}'; then
  fail "missing cli_version accepted"; else pass "missing cli_version rejected (#622 required-complete)"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"cli_version":123}'; then
  fail "non-string cli_version accepted"; else pass "non-string cli_version rejected"; fi
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
  v="$(jq -nc --arg s "$sev" '{verdict:"CHANGES_REQUESTED",summary:"x",findings:[{severity:$s,path:"a",line:1,body:"b"}],usage:null,cli_version:null}')"
  p4b_validate_verdict "$v" && pass "schema severity enum member accepted: $sev" \
    || fail "schema declares severity $sev but validator rejects it (drift)"
done < <(jq -r '.properties.findings.items.properties.severity.enum[]' "$SCHEMA_FILE")
for bogus in P4 PX p1 P; do
  v="$(jq -nc --arg s "$bogus" '{verdict:"CHANGES_REQUESTED",summary:"x",findings:[{severity:$s,path:"a",line:1,body:"b"}],usage:null,cli_version:null}')"
  p4b_validate_verdict "$v" && fail "severity outside schema enum accepted: $bogus" \
    || pass "severity outside schema enum rejected: $bogus"
done
while IFS= read -r vd; do
  v="$(jq -nc --arg v "$vd" '{verdict:$v,summary:"x",findings:[],usage:null,cli_version:null}')"
  p4b_validate_verdict "$v" && pass "schema verdict enum member accepted: $vd" \
    || fail "schema declares verdict $vd but validator rejects it (drift)"
done < <(jq -r '.properties.verdict.enum[]' "$SCHEMA_FILE")
while IFS= read -r key; do
  v="$(jq -c --arg k "$key" 'del(.[$k])' <<<'{"verdict":"APPROVED","summary":"x","findings":[],"usage":null,"cli_version":null}')"
  p4b_validate_verdict "$v" && fail "verdict missing schema-required key accepted: $key" \
    || pass "verdict missing schema-required key rejected: $key"
done < <(jq -r '.required[]' "$SCHEMA_FILE")

# (b') Malformed schema (#594): an enum degraded to a SCALAR string must fail
# closed, not let jq's `index` do substring matching (which would accept
# "APPROVED"/"P1"). Point P4B_VERDICT_SCHEMA_PATH at a bad schema and confirm an
# otherwise-valid verdict is rejected.
BAD_SCHEMA="$WORK/bad-schema.json"
jq '.properties.verdict.enum = "APPROVED"' "$SCHEMA_FILE" > "$BAD_SCHEMA"
if P4B_VERDICT_SCHEMA_PATH="$BAD_SCHEMA" p4b_validate_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":null,"cli_version":null}'; then
  fail "scalar verdict enum in a malformed schema accepted (should fail closed)"
else pass "malformed schema (verdict enum as scalar) fails closed"; fi
jq '.properties.findings.items.properties.severity.enum = "P1"' "$SCHEMA_FILE" > "$BAD_SCHEMA"
if P4B_VERDICT_SCHEMA_PATH="$BAD_SCHEMA" p4b_validate_verdict '{"verdict":"CHANGES_REQUESTED","summary":"x","findings":[{"severity":"P1","path":"a","line":1,"body":"b"}],"usage":null,"cli_version":null}'; then
  fail "scalar severity enum in a malformed schema accepted (should fail closed)"
else pass "malformed schema (severity enum as scalar) fails closed"; fi

# (b'') Strict-mode required/properties parity (#660): the schema is passed
# to `codex exec --output-schema`, and OpenAI strict structured outputs
# require `required` to be an array listing EVERY key in `properties` (#632)
# AND reject a `required` key absent from `properties` (the #641 regression:
# `cli_version` added to required only → invalid_json_schema → every
# claude→codex adapter run failed closed to the manual handoff). The unit
# validator derives its key sets FROM the schema, so a schema-internal
# inconsistency is invisible to every other test here — pin exact set
# equality, and the strict-mode `additionalProperties: false` posture, at
# every object node so neither direction can drift again.
parity_violations="$(jq -r '
  [ .. | objects | select(has("properties"))
    | select(((.required // []) | sort) != (.properties | keys | sort)) ]
  | length' "$SCHEMA_FILE")"
[ "$parity_violations" = "0" ] \
  && pass "strict-mode parity: required == properties keys at every object node" \
  || fail "strict-mode parity: $parity_violations node(s) with required != properties keys (OpenAI rejects the whole schema)"
addprops_violations="$(jq -r '
  [ .. | objects | select(has("properties"))
    | select(.additionalProperties != false) ]
  | length' "$SCHEMA_FILE")"
[ "$addprops_violations" = "0" ] \
  && pass "strict-mode parity: additionalProperties is false at every object node" \
  || fail "strict-mode parity: $addprops_violations node(s) missing additionalProperties: false"

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
echo "lib.sh — review-diff byte budget (#635)"
# ===========================================================================
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"

# budget resolution: default, policy knob, bounds, env escape hatch
got="$(p4b_resolve_diff_max_bytes)" && [ "$got" = "$P4B_DEFAULT_DIFF_MAX_BYTES" ] \
  && pass "diff budget defaults to $P4B_DEFAULT_DIFF_MAX_BYTES when unconfigured" \
  || fail "diff budget default (got '${got:-}')"

POLICY_DIFF_BUDGET="$WORK/policy-diff-budget.yml"
cat > "$POLICY_DIFF_BUDGET" <<'YAML'
phase_4b_automation:
  enabled: true
  mode: local
  diff_max_bytes: 8192
YAML
got="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_DIFF_BUDGET" p4b_resolve_diff_max_bytes)" \
  && [ "$got" = "8192" ] \
  && pass "diff budget reads phase_4b_automation.diff_max_bytes" \
  || fail "diff budget policy read (got '${got:-}')"

POLICY_DIFF_BUDGET_BAD="$WORK/policy-diff-budget-bad.yml"
cat > "$POLICY_DIFF_BUDGET_BAD" <<'YAML'
phase_4b_automation:
  enabled: true
  diff_max_bytes: banana
YAML
set +e
got="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_DIFF_BUDGET_BAD" p4b_resolve_diff_max_bytes)"; rc=$?
set -e
[ "$rc" != 0 ] && [ -z "$got" ] \
  && pass "diff budget fails closed on a non-integer policy value" \
  || fail "diff budget non-integer policy (rc=$rc, got '${got:-}')"

POLICY_DIFF_BUDGET_RANGE="$WORK/policy-diff-budget-range.yml"
cat > "$POLICY_DIFF_BUDGET_RANGE" <<'YAML'
phase_4b_automation:
  enabled: true
  diff_max_bytes: 10
YAML
set +e
got="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_DIFF_BUDGET_RANGE" p4b_resolve_diff_max_bytes)"; rc=$?
set -e
[ "$rc" != 0 ] && [ -z "$got" ] \
  && pass "diff budget fails closed on an out-of-range policy value" \
  || fail "diff budget out-of-range policy (rc=$rc, got '${got:-}')"

got="$(P4B_DIFF_MAX_BYTES=2000 p4b_resolve_diff_max_bytes)" && [ "$got" = "2000" ] \
  && pass "diff budget env escape hatch overrides policy (unbounded)" \
  || fail "diff budget env override (got '${got:-}')"
set +e
got="$(P4B_DIFF_MAX_BYTES=not-a-number p4b_resolve_diff_max_bytes)"; rc=$?
set -e
[ "$rc" != 0 ] && [ -z "$got" ] \
  && pass "diff budget fails closed on a non-integer env override" \
  || fail "diff budget non-integer env (rc=$rc, got '${got:-}')"

# omission allowlist resolution: absent ⇒ empty, policy list read, env
# override comma-split (#636 Codex P1)
got="$(p4b_diff_omit_globs)"
[ -z "$got" ] && pass "omit allowlist defaults to empty (nothing omission-eligible)" \
  || fail "omit allowlist default (got '${got:-}')"
POLICY_OMIT_GLOBS="$WORK/policy-omit-globs.yml"
cat > "$POLICY_OMIT_GLOBS" <<'YAML'
phase_4b_automation:
  enabled: true
  diff_omit_globs:
    - "docs/audits/data/*"
    - "*.jsonl"   # trailing comment
YAML
got="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OMIT_GLOBS" p4b_diff_omit_globs)"
[ "$got" = "$(printf 'docs/audits/data/*\n*.jsonl')" ] \
  && pass "omit allowlist reads phase_4b_automation.diff_omit_globs list items" \
  || fail "omit allowlist policy read (got '${got:-}')"
got="$(P4B_DIFF_OMIT_GLOBS='data/*, extra/*' p4b_diff_omit_globs)"
[ "$got" = "$(printf 'data/*\nextra/*')" ] \
  && pass "omit allowlist env escape hatch comma-splits" \
  || fail "omit allowlist env override (got '${got:-}')"

# trimming: under-budget passthrough, largest-first omission + placeholder +
# report, fail-closed when nothing reviewable survives
TRIM_IN="$WORK/trim-in.diff"
TRIM_OUT="$WORK/trim-out.diff"
{
  printf 'diff --git a/src/code.sh b/src/code.sh\n'
  printf '+echo real-code-change\n'
  printf 'diff --git a/data/huge.jsonl b/data/huge.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+HUGE-ARTIFACT-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_IN"

rep="$(p4b_trim_review_diff "$TRIM_IN" "$TRIM_OUT" 1000000)" && cmp -s "$TRIM_IN" "$TRIM_OUT" && [ -z "$rep" ] \
  && pass "trim: under-budget diff passes through byte-identical, no report" \
  || fail "trim under-budget passthrough"

set +e
rep="$(p4b_trim_review_diff "$TRIM_IN" "$TRIM_OUT" 2000 'data/*')"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && ! grep -q 'HUGE-ARTIFACT' "$TRIM_OUT" \
   && grep -q 'real-code-change' "$TRIM_OUT" \
   && grep -q '^\[phase-4b diff-budget: data/huge.jsonl omitted' "$TRIM_OUT" \
   && printf '%s\n' "$rep" | grep -q "^data/huge.jsonl$(printf '\t')" \
   && [ "$(wc -c < "$TRIM_OUT" | tr -d '[:space:]')" -le 2000 ]; then
  pass "trim: over-budget diff drops the largest allowlisted section, keeps code, placeholder + report emitted"
else fail "trim over-budget (rc=$rc, report='${rep:-}')"; fi

# fail-closed guards (#636 Codex P1): no allowlist ⇒ nothing omission-
# eligible; an oversized NON-allowlisted (code) section is never omitted.
set +e
p4b_trim_review_diff "$TRIM_IN" "$TRIM_OUT" 2000 >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: fails closed with an empty omission allowlist" \
  || fail "trim empty-allowlist should fail (rc=$rc)"

TRIM_CODE="$WORK/trim-code.diff"
{
  printf 'diff --git a/src/small.sh b/src/small.sh\n+echo small\n'
  printf 'diff --git a/src/big-refactor.sh b/src/big-refactor.sh\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+CODE-CHANGE-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_CODE"
set +e
p4b_trim_review_diff "$TRIM_CODE" "$TRIM_OUT" 2000 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: never omits an oversized non-allowlisted (code) section — fails closed" \
  || fail "trim non-allowlisted code section should fail (rc=$rc)"

TRIM_ONLY_HUGE="$WORK/trim-only-huge.diff"
{
  printf 'diff --git a/data/only.jsonl b/data/only.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+ONLY-ARTIFACT-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_ONLY_HUGE"
set +e
p4b_trim_review_diff "$TRIM_ONLY_HUGE" "$TRIM_OUT" 500 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: fails closed when no reviewable section survives the budget" \
  || fail "trim nothing-reviewable should fail (rc=$rc)"

# #636 round-2 P1: a large RENAME from a non-allowlisted application path into
# an allowlisted artifact path must fail closed — checking only the b/-side
# would omit the section and hide the moved-away application code from review
# while an APPROVED could still post.
TRIM_RENAME_IN="$WORK/trim-rename-in.diff"
{
  printf 'diff --git a/small.js b/small.js\n+ok\n'
  printf 'diff --git a/src/app.sh b/data/app.sh\n'
  printf 'similarity index 40%%\nrename from src/app.sh\nrename to data/app.sh\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+MOVED-CODE-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_RENAME_IN"
set +e
p4b_trim_review_diff "$TRIM_RENAME_IN" "$TRIM_OUT" 2000 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: rename from non-allowlisted app path into allowlist fails closed (a/-side checked, #636 P1)" \
  || fail "trim rename-into-allowlist should fail closed (rc=$rc)"

# ...and a COPY into the allowlist is caught the same way (copy from source).
TRIM_COPY_IN="$WORK/trim-copy-in.diff"
{
  printf 'diff --git a/small.js b/small.js\n+ok\n'
  printf 'diff --git a/src/lib.sh b/data/lib.sh\ncopy from src/lib.sh\ncopy to data/lib.sh\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+COPIED-CODE-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_COPY_IN"
set +e
p4b_trim_review_diff "$TRIM_COPY_IN" "$TRIM_OUT" 2000 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: copy from non-allowlisted app path into allowlist fails closed (#636 P1)" \
  || fail "trim copy-into-allowlist should fail closed (rc=$rc)"

# ...but a rename WITHIN the allowlist (both sides + source allowlisted) is
# still eligible and gets omitted — the guard tightens without over-blocking.
TRIM_RENAME_OK="$WORK/trim-rename-ok.diff"
{
  printf 'diff --git a/small.js b/small.js\n+ok\n'
  printf 'diff --git a/data/old.jsonl b/data/new.jsonl\nrename from data/old.jsonl\nrename to data/new.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+DATA-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_RENAME_OK"
set +e
rep="$(p4b_trim_review_diff "$TRIM_RENAME_OK" "$TRIM_OUT" 2000 'data/*')"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && printf '%s\n' "$rep" | grep -q '^data/new.jsonl' \
   && grep -q '^\[phase-4b diff-budget: data/new.jsonl omitted' "$TRIM_OUT" \
   && ! grep -q 'DATA-' "$TRIM_OUT"; then
  pass "trim: rename within the allowlist stays eligible (omitted with placeholder)"
else fail "trim rename-within-allowlist (rc=$rc, report='${rep:-}')"; fi

# #668 finding 2 hardening: a crafted section whose explicit `rename to`
# destination disagrees with the header-derived b/-side must fail closed —
# eligibility may never rest solely on the header split when the section
# carries exact rename/copy path lines.
TRIM_RTO_IN="$WORK/trim-rto-in.diff"
{
  printf 'diff --git a/small.js b/small.js\n+ok\n'
  printf 'diff --git a/data/old.jsonl b/data/new.jsonl\n'
  printf 'similarity index 40%%\nrename from data/old.jsonl\nrename to src/evil.sh\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+RTO-CODE-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_RTO_IN"
set +e
p4b_trim_review_diff "$TRIM_RTO_IN" "$TRIM_OUT" 2000 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: rename-to destination outside the allowlist fails closed even when the header b/-side matches (#668)" \
  || fail "trim rename-to-outside-allowlist should fail closed (rc=$rc)"

# #668 finding 1: omission-allowlist provenance. When the over-budget diff
# ITSELF touches .github/review-policy.yml, the allowlist read from the
# checkout is untrusted for this run — omission must be refused entirely
# (fail closed to the manual handoff), even though the bulk section is
# allowlisted and the budget would otherwise be met.
TRIM_POLICY_IN="$WORK/trim-policy-in.diff"
{
  printf 'diff --git a/.github/review-policy.yml b/.github/review-policy.yml\n'
  printf '+  diff_omit_globs:\n+    - "src/*"\n'
  printf 'diff --git a/data/huge.jsonl b/data/huge.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+POLICY-BULK-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_POLICY_IN"
set +e
p4b_trim_review_diff "$TRIM_POLICY_IN" "$TRIM_OUT" 2000 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: refuses ALL omission when the diff touches .github/review-policy.yml (#668 provenance)" \
  || fail "trim policy-touching diff should fail closed (rc=$rc)"

# ...including when the policy file is only the SOURCE of a rename (the
# a/-side / rename-from path) — moving it away still rewrites the policy.
TRIM_POLICY_MV="$WORK/trim-policy-mv.diff"
{
  printf 'diff --git a/.github/review-policy.yml b/docs/old-policy.yml\n'
  printf 'similarity index 90%%\nrename from .github/review-policy.yml\nrename to docs/old-policy.yml\n'
  printf 'diff --git a/data/huge.jsonl b/data/huge.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+POLICY-MV-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_POLICY_MV"
set +e
p4b_trim_review_diff "$TRIM_POLICY_MV" "$TRIM_OUT" 2000 'data/*' >/dev/null; rc=$?
set -e
[ "$rc" != 0 ] \
  && pass "trim: policy file as a rename SOURCE also refuses omission (#668 provenance)" \
  || fail "trim policy-rename-away diff should fail closed (rc=$rc)"

# ...but an UNDER-budget diff touching the policy file passes through
# verbatim: no omission happens, so the allowlist plays no role and the
# provenance guard must not over-block ordinary policy PRs.
rep="$(p4b_trim_review_diff "$TRIM_POLICY_IN" "$TRIM_OUT" 1000000 'data/*')" \
  && cmp -s "$TRIM_POLICY_IN" "$TRIM_OUT" && [ -z "$rep" ] \
  && pass "trim: under-budget policy-touching diff still passes through verbatim (#668)" \
  || fail "trim under-budget policy-touching passthrough"

# #636 round-2 P2: the omission loop must account for placeholder bytes.
# Construct two allowlisted sections so that omitting only the largest gets
# input-minus-omitted under budget, but the placeholder it adds pushes the
# OUTPUT back over — the old size-only loop stopped there and the final
# assertion failed (avoidable manual fallback). The fix keeps omitting.
TRIM_P2="$WORK/trim-p2.diff"
{
  printf 'diff --git a/keep.js b/keep.js\n+ok\n'
  # S1: long allowlisted path (=> long placeholder) + large body
  printf 'diff --git a/data/very/long/artifact/path/segment/one/two/three/big.jsonl b/data/very/long/artifact/path/segment/one/two/three/big.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 120; i++) printf "+S1-%06d-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n", i }'
  # S2: medium allowlisted section, comfortably larger than the two placeholders
  printf 'diff --git a/data/mid.jsonl b/data/mid.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 60; i++) printf "+S2-%06d-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n", i }'
} > "$TRIM_P2"
# Measure total and the largest section's bytes with the same accounting.
p2_total="$(wc -c < "$TRIM_P2" | tr -d '[:space:]')"
p2_s1="$(LC_ALL=C awk '
  /^diff --git /{ n++; bytes[n] = 0 } n > 0 { bytes[n] += length($0) + 1 }
  END { m = 0; for (i = 1; i <= n; i++) if (bytes[i] > m) m = bytes[i]; print m }' "$TRIM_P2")"
# max = total - bytes(S1): the OLD loop stops after omitting S1 alone
# (total-omitted == max), but S1's placeholder then pushes output over max.
p2_max=$(( p2_total - p2_s1 ))
set +e
rep="$(p4b_trim_review_diff "$TRIM_P2" "$TRIM_OUT" "$p2_max" 'data/*')"; rc=$?
set -e
p2_out="$(wc -c < "$TRIM_OUT" 2>/dev/null | tr -d '[:space:]' || echo 999999999)"
if [ "$rc" = 0 ] \
   && [ "$p2_out" -le "$p2_max" ] \
   && [ "$(printf '%s\n' "$rep" | grep -c .)" = "2" ]; then
  pass "trim: placeholder-aware loop keeps omitting so a fit-able diff isn't spuriously rejected (#636 P2)"
else fail "trim placeholder accounting (rc=$rc, out=$p2_out, max=$p2_max, omitted=$(printf '%s\n' "$rep" | grep -c .))"; fi

# stderr tail: sanitized single line; empty for a missing/empty file
ERRF="$WORK/stderr-sample.txt"
printf 'line one\nstream error: exceeded context window\n' > "$ERRF"
got="$(p4b_stderr_tail "$ERRF")"
[ "$got" = "line one stream error: exceeded context window" ] \
  && pass "stderr tail collapses to one sanitized line" \
  || fail "stderr tail (got '${got:-}')"
: > "$ERRF"
got="$(p4b_stderr_tail "$ERRF")"
[ -z "$got" ] && pass "stderr tail is empty for an empty file" \
  || fail "stderr tail empty-file (got '${got:-}')"

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
   && [ "$(printf '%s' "$out" | jq -r '.usage.source')" = "codex-cli-stderr" ] \
   && [ "$(printf '%s' "$out" | jq -r '.usage | keys | length')" = "8" ] \
   && [ "$(printf '%s' "$out" | jq -r '.usage.cache_read_input_tokens')" = "null" ]; then
  pass "codex adapter records token usage when CLI exposes it (all eight keys, additive null-filled, #632)"
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
echo "adapters — oversized-diff budget + CLI stderr surfacing (#635)"
# ===========================================================================
HUGE_DIFF="$WORK/huge.diff"
{
  printf 'diff --git a/x.js b/x.js\n+const x = 1;\n'
  printf 'diff --git a/data/bulk.jsonl b/data/bulk.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 500; i++) printf "+BULK-MARKER-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$HUGE_DIFF"
HUGE_ONLY_DIFF="$WORK/huge-only.diff"
{
  printf 'diff --git a/data/bulk.jsonl b/data/bulk.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 500; i++) printf "+BULK-MARKER-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$HUGE_ONLY_DIFF"

# Trim-asserting fakes: fail loudly if the bulk section reached the CLI, if
# the code section was lost, if the in-diff placeholder is missing (codex),
# or if no argument (the PROMPT) discloses the omitted path. These prove the
# reviewer is told an omitted file was CHANGED, not led to call it missing
# (the #629 false-positive P1 an undisclosed manual trim produced).
cat > "$BIN/fake-codex-trim-assert" <<'SH'
#!/usr/bin/env bash
stdin="$(cat)"
case "$stdin" in *BULK-MARKER-*) echo TRIM-FAILED-BULK-PRESENT >&2; exit 8 ;; esac
case "$stdin" in *'const x = 1;'*) : ;; *) echo TRIM-LOST-CODE >&2; exit 8 ;; esac
case "$stdin" in *'[phase-4b diff-budget: data/bulk.jsonl omitted'*) : ;; *) echo TRIM-NO-PLACEHOLDER >&2; exit 8 ;; esac
disclosed=false
for arg in "$@"; do
  case "$arg" in *'report these files as missing'*'data/bulk.jsonl'*) disclosed=true ;; esac
done
[ "$disclosed" = true ] || { echo PROMPT-NO-DISCLOSURE >&2; exit 8; }
printf '%s' '{"verdict":"APPROVED","summary":"looks good","findings":[]}'
SH
chmod +x "$BIN/fake-codex-trim-assert"
cat > "$BIN/fake-claude-trim-assert" <<'SH'
#!/usr/bin/env bash
stdin="$(cat)"
case "$stdin" in *BULK-MARKER-*) echo TRIM-FAILED-BULK-PRESENT >&2; exit 8 ;; esac
case "$stdin" in *'const x = 1;'*) : ;; *) echo TRIM-LOST-CODE >&2; exit 8 ;; esac
disclosed=false
for arg in "$@"; do
  case "$arg" in *'report these files as missing'*'data/bulk.jsonl'*) disclosed=true ;; esac
done
[ "$disclosed" = true ] || { echo PROMPT-NO-DISCLOSURE >&2; exit 8; }
jq -n --arg r '{"verdict":"APPROVED","summary":"ok","findings":[]}' '{type:"result",subtype:"success",result:$r,session_id:"t"}'
SH
chmod +x "$BIN/fake-claude-trim-assert"

set +e
out="$(P4B_DIFF_MAX_BYTES=2000 P4B_DIFF_OMIT_GLOBS='data/*' CODEX_BIN="$BIN/fake-codex-trim-assert" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$HUGE_DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "codex adapter trims an over-budget allowlisted diff and discloses omissions in the prompt"
else fail "codex adapter oversized-diff trim (rc=$rc, out=$out)"; fi

set +e
out="$(P4B_DIFF_MAX_BYTES=2000 P4B_DIFF_OMIT_GLOBS='data/*' CLAUDE_BIN="$BIN/fake-claude-trim-assert" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$HUGE_DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ]; then
  pass "claude adapter trims an over-budget allowlisted diff and discloses omissions in the prompt"
else fail "claude adapter oversized-diff trim (rc=$rc, out=$out)"; fi

# Without an allowlist entry the SAME over-budget diff must fail closed to
# the manual handoff, never silently omit (#636 Codex P1) — and an
# oversized CODE section is never omission-eligible regardless of budget.
set +e
P4B_DIFF_MAX_BYTES=2000 CODEX_BIN="$BIN/fake-codex-approve" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$HUGE_DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "codex adapter fails closed (exit 4) on an over-budget diff with no omission allowlist" \
  || fail "codex adapter no-allowlist over-budget should exit 4 (got $rc)"

HUGE_CODE_DIFF="$WORK/huge-code.diff"
{
  printf 'diff --git a/x.js b/x.js\n+const x = 1;\n'
  printf 'diff --git a/src/big-refactor.sh b/src/big-refactor.sh\n'
  awk 'BEGIN { for (i = 0; i < 500; i++) printf "+CODE-CHANGE-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$HUGE_CODE_DIFF"
set +e
P4B_DIFF_MAX_BYTES=2000 P4B_DIFF_OMIT_GLOBS='data/*' CODEX_BIN="$BIN/fake-codex-approve" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$HUGE_CODE_DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "codex adapter fails closed (exit 4) rather than omit an oversized non-allowlisted code section" \
  || fail "codex adapter code-section omission should exit 4 (got $rc)"

set +e
P4B_DIFF_MAX_BYTES=2000 P4B_DIFF_OMIT_GLOBS='data/*' CLAUDE_BIN="$BIN/fake-claude-approve-usage" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$HUGE_CODE_DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter fails closed (exit 4) rather than omit an oversized non-allowlisted code section" \
  || fail "claude adapter code-section omission should exit 4 (got $rc)"

set +e
P4B_DIFF_MAX_BYTES=200 P4B_DIFF_OMIT_GLOBS='data/*' CODEX_BIN="$BIN/fake-codex-approve" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$HUGE_ONLY_DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "codex adapter fails closed (exit 4) when nothing reviewable survives the budget" \
  || fail "codex adapter untrimmable diff should exit 4 (got $rc)"

set +e
P4B_DIFF_MAX_BYTES=200 P4B_DIFF_OMIT_GLOBS='data/*' CLAUDE_BIN="$BIN/fake-claude-approve-usage" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$HUGE_ONLY_DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 4 ] && pass "claude adapter fails closed (exit 4) when nothing reviewable survives the budget" \
  || fail "claude adapter untrimmable diff should exit 4 (got $rc)"

# #668 provenance: an over-budget diff that ALSO touches
# .github/review-policy.yml must exit 4 (manual fallback) instead of
# trusting the checkout's allowlist — the adapters inherit the mechanical
# guard from p4b_trim_review_diff.
HUGE_POLICY_DIFF="$WORK/huge-policy.diff"
{
  printf 'diff --git a/.github/review-policy.yml b/.github/review-policy.yml\n'
  printf '+  diff_omit_globs:\n+    - "src/*"\n'
  cat "$HUGE_DIFF"
} > "$HUGE_POLICY_DIFF"
set +e
errout="$(P4B_DIFF_MAX_BYTES=2000 P4B_DIFF_OMIT_GLOBS='data/*' CODEX_BIN="$BIN/fake-codex-approve" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$HUGE_POLICY_DIFF" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && printf '%s' "$errout" | grep -q 'review-policy.yml'; then
  pass "codex adapter refuses omission on a policy-touching over-budget diff (exit 4, cause named) (#668)"
else fail "codex adapter policy-touching diff should exit 4 naming the policy file (rc=$rc, err=$errout)"; fi

set +e
errout="$(P4B_DIFF_MAX_BYTES=2000 P4B_DIFF_OMIT_GLOBS='data/*' CLAUDE_BIN="$BIN/fake-claude-approve-usage" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$HUGE_POLICY_DIFF" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && printf '%s' "$errout" | grep -q 'review-policy.yml'; then
  pass "claude adapter refuses omission on a policy-touching over-budget diff (exit 4, cause named) (#668)"
else fail "claude adapter policy-touching diff should exit 4 naming the policy file (rc=$rc, err=$errout)"; fi

# CLI stderr must reach the failure message (#635: every nonzero rc used to
# be reported as a plan-login problem; a context-overflow rc=1 read as an
# auth error while the CLI's real complaint was discarded).
mk_fake fake-codex-stderr-fail \
  "echo 'stream error: request exceeds the model context window' >&2
exit 1"
mk_fake fake-claude-stderr-fail \
  "echo 'API Error: 529 overloaded_error upstream' >&2
exit 1"

set +e
errout="$(CODEX_BIN="$BIN/fake-codex-stderr-fail" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && printf '%s' "$errout" | grep -q 'exceeds the model context window'; then
  pass "codex adapter surfaces the CLI stderr tail on failure"
else fail "codex adapter stderr surfacing (rc=$rc, err=$errout)"; fi

set +e
errout="$(CLAUDE_BIN="$BIN/fake-claude-stderr-fail" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && printf '%s' "$errout" | grep -q '529 overloaded_error'; then
  pass "claude adapter surfaces the CLI stderr tail on failure"
else fail "claude adapter stderr surfacing (rc=$rc, err=$errout)"; fi

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

# Policy step 9 executor (#672): an APPROVED carrying discretionary findings
# now FILES the post-review issues and posts, instead of discarding the
# verdict into the manual handoff. Dry-run prints intent, files nothing, and
# still reports a dry-run APPROVED.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  bash "$ORCH" 133 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.dry_run')" = "true" ]; then
  pass "APPROVED with advisory findings dry-run → would file issues, no fallback (#672)"
else fail "approved-with-advisory dry-run (rc=$rc): $out"; fi

# #672 happy path: issues filed under the author token with the step-9 labels
# and assignee, references appended to the posted APPROVED body.
ISSUE_LOG="$WORK/issue-create.log"; : > "$ISSUE_LOG"
P4B672_BODY="$WORK/p4b672-body.txt"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b672-wrapper.log" \
  P4B_WRAPPER_BODY="$P4B672_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = "true" ]; then
  pass "#672: APPROVED with advisory findings posts after filing issues"
else fail "#672 happy path (rc=$rc): $out"; fi
grep -q -- "--label post-review" "$ISSUE_LOG" && grep -q -- "--label observation" "$ISSUE_LOG" \
  && pass "#672: filed issue carries the step-9 labels" || fail "#672: labels missing from issue create argv"
grep -q -- "--assignee nathanjohnpayne" "$ISSUE_LOG" \
  && pass "#672: filed issue assigned to the author identity" || fail "#672: assignee missing"
grep -q "^VIA gh-as-author$" "$ISSUE_LOG" \
  && pass "#672: issue writes routed through the author wrapper" || fail "#672: issue create not wrapper-routed"
grep -q "post-review issue" "$P4B672_BODY" && grep -q "#901" "$P4B672_BODY" \
  && pass "#672: posted APPROVED body carries the issue reference" || fail "#672: issue reference missing from review body"
P2_FP="$(printf '%s|%s|%s|%s' P2 x.js 2 "should be handled under stricter policy" | cksum | cut -d' ' -f1)"
grep -q "p4b-post-review o/r#134 head=abc123 finding=${P2_FP}" "${ISSUE_LOG}.body.1" \
  && pass "#674: filed issue body embeds the content-fingerprinted dedup marker" || fail "#674: content-fingerprint marker missing from issue body"
grep -q -- "--title \[Post-Review\]" "$ISSUE_LOG" || grep -q "\[Post-Review\]" "$ISSUE_LOG" \
  && pass "#674: issue title follows the documented Post-Review convention" || fail "#674: Post-Review title prefix missing"
# #675: the posted APPROVED body's accounting block records the filed advisory
# with disposition=deferred-to-follow-up + its issue link (not unresolved/null),
# and totals.advisory_issues_filed derives from it — so the machine-readable
# record matches the prose "filed as #901" reference instead of contradicting
# it. Extract the embedded p4b-accounting:v1 record and assert the enrichment.
P4B675_REC="$(awk '/<!-- p4b-accounting:v1/{f=1;next} /^-->/{f=0} f' "$P4B672_BODY")"
if [ -n "$P4B675_REC" ] && printf '%s' "$P4B675_REC" | jq -e '
    (.totals.advisory_issues_filed == [901])
    and ([ .unique_findings[]
           | select(.disposition == "deferred-to-follow-up" and .issue == 901) ]
         | length) == 1' >/dev/null 2>&1; then
  pass "#675: filed advisory enriches the posted accounting record (deferred-to-follow-up + #901)"
else fail "#675: accounting record not enriched with the filed issue (rec=$P4B675_REC)"; fi

# #674 CodeRabbit: a marker match from a prior partially-failed run is
# REUSED — no duplicate issue is created and the reference still lands.
DEDUP_ISSUE_LOG="$WORK/issue-dedup.log"; : > "$DEDUP_ISSUE_LOG"
DEDUP_BODY="$WORK/p4b674-dedup-body.txt"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$DEDUP_ISSUE_LOG" P4B_FAKE_EXISTING_ISSUE=1 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-dedup-wrapper.log" \
  P4B_WRAPPER_BODY="$DEDUP_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  bash "$ORCH" 140 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ ! -s "$DEDUP_ISSUE_LOG" ] && grep -q "#777" "$DEDUP_BODY"; then
  pass "#674: existing marker match reused (no duplicate issue; reference carried)"
else fail "#674 dedup reuse (rc=$rc)"; fi

# #674 CodeRabbit: an unrecognized post_review_issues value fails CLOSED
# instead of silently failing open into auto-filing.
POLICY_BAD_KNOB="$WORK/policy-bad-knob.yml"
cat > "$POLICY_BAD_KNOB" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
  post_review_issues: nope
YAML
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_BAD_KNOB" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  bash "$ORCH" 141 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "invalid phase_4b_automation.post_review_issues"; then
  pass "#674: invalid post_review_issues value fails closed"
else fail "#674 bad-knob fail-closed (rc=$rc): $out"; fi

# #672 fail-closed: an issue-create failure refuses the approval (no review
# POST is attempted) and falls back to the manual handoff.
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$WORK/issue-fail.log" P4B_FAKE_ISSUE_FAIL=1 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b672-fail-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 135 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "issue filing failed"; then
  pass "#672: issue-create failure refuses the approval (fail-closed)"
else fail "#672 fail-closed (rc=$rc): $out"; fi
[ ! -s "$WORK/p4b672-fail-wrapper.log" ] \
  && pass "#672: no review POST attempted after filing failure" || fail "#672: review POST attempted despite filing failure"

# #674 round 1: a head that drifted during the adapter run must refuse
# BEFORE any side-effecting issue creation (post_review would refuse the
# POST later, but by then the issues would already exist).
DRIFT_ISSUE_LOG="$WORK/issue-drift.log"; : > "$DRIFT_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$DRIFT_ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-drift-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=def456 \
  bash "$ORCH" 137 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "refusing to file post-review issues"; then
  pass "#674: head drift refuses BEFORE issue filing"
else fail "#674 head-drift pre-check (rc=$rc): $out"; fi
[ ! -s "$DRIFT_ISSUE_LOG" ] \
  && pass "#674: no issues created for a drifted head" || fail "#674: issues created despite head drift"

# #674 round 1: a finding whose wording flags a RISK files under the `risk`
# label per policy step 9, not a hard-coded `observation`.
RISK_ISSUE_LOG="$WORK/issue-risk.log"; : > "$RISK_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-risk" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$RISK_ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-risk-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  bash "$ORCH" 138 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && grep -q -- "--label risk" "$RISK_ISSUE_LOG" && ! grep -q -- "--label observation" "$RISK_ISSUE_LOG"; then
  pass "#674: risk-worded finding files under the risk label"
else fail "#674 risk classification (rc=$rc)"; fi

# #674 round 1: feedback_policy `ignore` tiers are never surfaced — no issue
# is filed for them, and the approval still posts.
POLICY_P3_IGNORE="$WORK/policy-p3-ignore.yml"
cat > "$POLICY_P3_IGNORE" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: ignore
phase_4b_automation:
  enabled: true
  mode: local
YAML
IGNORE_ISSUE_LOG="$WORK/issue-ignore.log"; : > "$IGNORE_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_P3_IGNORE" CODEX_BIN="$BIN/fake-codex-approve-p3" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$IGNORE_ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-ignore-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  bash "$ORCH" 139 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = "true" ] && [ ! -s "$IGNORE_ISSUE_LOG" ]; then
  pass "#674: ignore-tier findings file nothing and the approval still posts"
else fail "#674 ignore-tier filter (rc=$rc): $out"; fi

# #674: token ownership lives in the identity-verifying author wrapper —
# filing succeeds with an ambient reviewer token in the environment and no
# preflight author PAT, and every write routes through gh-as-author.
KEYRING_ISSUE_LOG="$WORK/issue-keyring.log"; : > "$KEYRING_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  GH_TOKEN=ambient-reviewer-token P4B_ISSUE_LOG="$KEYRING_ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
  P4B_WRAPPER_LOG="$WORK/p4b674-keyring-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  bash "$ORCH" 142 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && grep -q "^VIA gh-as-author$" "$KEYRING_ISSUE_LOG" \
   && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = "true" ]; then
  pass "#674: filing under an ambient reviewer token routes through the author wrapper"
else fail "#674 wrapper token ownership (rc=$rc)"; fi

# #674 CodeRabbit Major: a dedup search ERROR fails the filing closed —
# never read as "no existing issue".
SEARCHFAIL_LOG="$WORK/issue-searchfail.log"; : > "$SEARCHFAIL_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$SEARCHFAIL_LOG" P4B_FAKE_SEARCH_FAIL=1 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
  P4B_WRAPPER_LOG="$WORK/p4b674-searchfail-wrapper.log" P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 148 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "issue filing failed" \
   && ! grep -q "^ARGV " "$SEARCHFAIL_LOG"; then
  pass "#674: dedup search error fails closed with no issue created"
else fail "#674 search-error fail-closed (rc=$rc): $out"; fi
[ ! -s "$WORK/p4b674-searchfail-wrapper.log" ] \
  && pass "#674: no review POST after a search error" || fail "#674: review POST attempted after search error"

# #674 round 2: a partial filing failure surfaces the already-filed refs in
# the fallback reason (the dedup marker makes a rerun reuse them).
PARTIAL_ISSUE_LOG="$WORK/issue-partial.log"; : > "$PARTIAL_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-2p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$PARTIAL_ISSUE_LOG" P4B_FAKE_ISSUE_FAIL_AFTER_1=1 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-partial-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 143 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "partial refs: #901"; then
  pass "#674: partial filing failure surfaces the orphan refs in the fallback"
else fail "#674 partial-orphan surfacing (rc=$rc): $out"; fi
grep -q "^CLOSE #901$" "$PARTIAL_ISSUE_LOG" \
  && pass "#674: partial orphans closed as superseded (round-4 self-cleanup)" || fail "#674: partial orphan not closed"
[ ! -s "$WORK/p4b674-partial-wrapper.log" ] \
  && pass "#674: no review POST after a partial filing failure" || fail "#674: review POST attempted after partial failure"

# #674 round 4: a head that drifts DURING filing refuses at the post-file
# recheck, and the just-filed issues are closed as superseded.
DRIFT2_ISSUE_LOG="$WORK/issue-drift2.log"; : > "$DRIFT2_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$DRIFT2_ISSUE_LOG" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_HEAD2=def456 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-drift2-wrapper.log" \
  bash "$ORCH" 145 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "changed while filing post-review issues" \
   && grep -q "^ARGV " "$DRIFT2_ISSUE_LOG" \
   && grep -q "^CLOSE #901$" "$DRIFT2_ISSUE_LOG"; then
  pass "#674: mid-filing head drift refuses and closes the filed issues"
else fail "#674 mid-filing drift cleanup (rc=$rc): $out"; fi
[ ! -s "$WORK/p4b674-drift2-wrapper.log" ] \
  && pass "#674: no review POST after mid-filing drift" || fail "#674: review POST attempted after mid-filing drift"

# #674 round 3: a mixed filed+ignored approval body claims filing only for
# the filed subset and names the suppressed remainder.
MIXED_ISSUE_LOG="$WORK/issue-mixed.log"; : > "$MIXED_ISSUE_LOG"
MIXED_BODY="$WORK/p4b674-mixed-body.txt"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_P3_IGNORE" CODEX_BIN="$BIN/fake-codex-approve-p2p3" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$MIXED_ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-mixed-wrapper.log" \
  P4B_WRAPPER_BODY="$MIXED_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  bash "$ORCH" 144 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(grep -c '^ARGV ' "$MIXED_ISSUE_LOG")" = "1" ] \
   && grep -q "1 of the findings above were filed" "$MIXED_BODY" \
   && grep -q "ignore tiers and were deliberately not surfaced" "$MIXED_BODY"; then
  pass "#674: mixed approval body claims filing only for the filed subset"
else fail "#674 mixed filed/ignored body wording (rc=$rc)"; fi

# #674 round 5: a REUSED prior-run issue is never closed by this run's
# failure cleanup — only refs this invocation created are.
REUSE_ISSUE_LOG="$WORK/issue-reuse-fail.log"; : > "$REUSE_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-2p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$REUSE_ISSUE_LOG" \
  P4B_FAKE_EXISTING_ISSUE_ONCE=1 P4B_FAKE_ISSUE_FAIL=1 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-reuse-wrapper.log" \
  P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 146 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && ! grep -q "^CLOSE #777$" "$REUSE_ISSUE_LOG"; then
  pass "#674: reused prior-run issue is NOT closed by this run's failure cleanup"
else fail "#674 reused-ref protection (rc=$rc)"; fi

# #674 round 5: drift landing in the render window (after the post-file
# recheck, before the POST) still closes this run's filed issues.
LATE_ISSUE_LOG="$WORK/issue-late-drift.log"; : > "$LATE_ISSUE_LOG"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$LATE_ISSUE_LOG" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_HEAD2=def456 P4B_FAKE_LIVE_HEAD2_FROM=3 \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p4b674-late-wrapper.log" \
  bash "$ORCH" 147 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "changed during review" \
   && grep -q "^CLOSE #901$" "$LATE_ISSUE_LOG"; then
  pass "#674: render-window drift closes this run's filed issues before refusing"
else fail "#674 late-drift cleanup (rc=$rc): $out"; fi
[ ! -s "$WORK/p4b674-late-wrapper.log" ] \
  && pass "#674: no review POST after render-window drift" || fail "#674: review POST attempted after late drift"

# #672 opt-out: post_review_issues: false restores the pre-#672 refusal.
POLICY_NO_ISSUES="$WORK/policy-no-issues.yml"
cat > "$POLICY_NO_ISSUES" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
  post_review_issues: false
YAML
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_NO_ISSUES" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  bash "$ORCH" 136 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "post_review_issues is false"; then
  pass "#672: post_review_issues: false restores the refusal"
else fail "#672 opt-out (rc=$rc): $out"; fi

# Stale-head guard: a non-dry-run APPROVED must re-read the live head and
# fall back before the wrapper writes if the reviewed SHA is no longer live.
WRAPPER_LOG="$WORK/wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_FAKE_LIVE_HEAD=def456 \
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
  OP_PREFLIGHT_REVIEWER_PAT=wrong-current-agent-token P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 \
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
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=def456 \
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
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 \
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

# ===========================================================================
echo "lib.sh — timeout/effort resolvers (#589)"
# ===========================================================================
cat > "$WORK/policy-te.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  adapter_timeout_seconds: 1200
  codex_timeout_seconds: 120
  codex_effort: high
  claude_effort: xhigh
YAML
cat > "$WORK/policy-te-defaults.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
YAML
cat > "$WORK/policy-te-t1.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  adapter_timeout_seconds: 1
YAML
cat > "$WORK/policy-te-bad-timeout.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  codex_timeout_seconds: abc
YAML
cat > "$WORK/policy-te-range.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  adapter_timeout_seconds: 99999
YAML
cat > "$WORK/policy-te-bad-effort.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  codex_effort: bogus
YAML

export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-defaults.yml"
r="$(p4b_resolve_adapter_timeout codex)"; [ "$r" = 900 ] && pass "timeout defaults to 900 when unset" || fail "timeout default -> $r"
r="$(p4b_resolve_adapter_effort claude)"; [ "$r" = medium ] && pass "claude effort defaults to medium" || fail "claude effort default -> $r"
r="$(p4b_resolve_adapter_effort codex)"; [ -z "$r" ] && pass "codex effort defaults to empty (CLI default)" || fail "codex effort default -> [$r]"

export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te.yml"
r="$(p4b_resolve_adapter_timeout codex)"; [ "$r" = 120 ] && pass "codex per-adapter timeout override (120)" || fail "codex timeout override -> $r"
r="$(p4b_resolve_adapter_timeout claude)"; [ "$r" = 1200 ] && pass "claude falls back to shared timeout (1200)" || fail "claude shared timeout -> $r"
r="$(p4b_resolve_adapter_effort codex)"; [ "$r" = high ] && pass "codex effort from policy (high)" || fail "codex effort -> $r"
r="$(p4b_resolve_adapter_effort claude)"; [ "$r" = xhigh ] && pass "claude effort from policy (xhigh)" || fail "claude effort -> $r"

export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-bad-timeout.yml"
set +e; p4b_resolve_adapter_timeout codex >/dev/null 2>&1; rc=$?; set -e
[ "$rc" != 0 ] && pass "non-integer timeout rejected (fail closed)" || fail "non-integer timeout accepted"
export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-range.yml"
set +e; p4b_resolve_adapter_timeout codex >/dev/null 2>&1; rc=$?; set -e
[ "$rc" != 0 ] && pass "out-of-range timeout (99999 > 3600) rejected" || fail "out-of-range timeout accepted"
export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-bad-effort.yml"
set +e; p4b_resolve_adapter_effort codex >/dev/null 2>&1; rc=$?; set -e
[ "$rc" != 0 ] && pass "invalid codex effort rejected (fail closed)" || fail "invalid codex effort accepted"
unset MERGEPATH_REVIEW_POLICY_PATH

# ===========================================================================
echo "adapters — configurable effort (#589)"
# ===========================================================================
# These fakes read the effort off their OWN argv (which survives the adapter's
# env -i allowlist, unlike an env var) and echo it back in the verdict summary,
# so the test can assert what the adapter actually passed to the CLI.
mk_fake fake-codex-effort \
  "eff=none; prev=''
for a in \"\$@\"; do
  if [ \"\$prev\" = '-c' ]; then case \"\$a\" in model_reasoning_effort=*) eff=\"\${a#model_reasoning_effort=}\";; esac; fi
  prev=\"\$a\"
done
printf '{\"verdict\":\"APPROVED\",\"summary\":\"effort=%s\",\"findings\":[]}' \"\$eff\""
mk_fake fake-claude-effort \
  "eff=none; prev=''
for a in \"\$@\"; do
  if [ \"\$prev\" = '--effort' ]; then eff=\"\$a\"; fi
  prev=\"\$a\"
done
printf '{\"verdict\":\"APPROVED\",\"summary\":\"effort=%s\",\"findings\":[]}' \"\$eff\""

set +e
out="$(P4B_CODEX_EFFORT=high CODEX_BIN="$BIN/fake-codex-effort" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.summary')" = "effort=high" ]; then
  pass "codex adapter passes -c model_reasoning_effort=<v> when P4B_CODEX_EFFORT set"
else fail "codex effort wiring (rc=$rc, out=$out)"; fi

set +e
out="$(CODEX_BIN="$BIN/fake-codex-effort" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.summary')" = "effort=none" ]; then
  pass "codex adapter omits the effort flag when unset (CLI default / no-op)"
else fail "codex effort default (rc=$rc, out=$out)"; fi

set +e
P4B_CODEX_EFFORT=bogus CODEX_BIN="$BIN/fake-codex-effort" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && pass "codex adapter rejects invalid effort with exit 3" || fail "codex invalid effort should exit 3 (got $rc)"

set +e
out="$(P4B_CLAUDE_EFFORT=high CLAUDE_BIN="$BIN/fake-claude-effort" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.summary')" = "effort=high" ]; then
  pass "claude adapter passes --effort <v> when P4B_CLAUDE_EFFORT set (no adapter edit)"
else fail "claude effort wiring (rc=$rc, out=$out)"; fi

# ===========================================================================
echo "orchestrator — policy-driven timeout/effort (#589)"
# ===========================================================================
# End-to-end: a non-dry-run post captures the review body. The codex fake
# echoes the effort it saw (effort=high) into the verdict summary, so the
# posted body proves policy → orchestrator → env → adapter → CLI arg wiring.
EFFORT_BODY="$WORK/orch-effort-body.md"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te.yml" CODEX_BIN="$BIN/fake-codex-effort" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/orch-effort-wrapper.log" P4B_WRAPPER_BODY="$EFFORT_BODY" P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 140 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.reviewer_effort')" = "high" ] \
   && [ "$(printf '%s' "$out" | jq -r '.adapter_timeout_seconds')" = "120" ] \
   && grep -q "effort=high" "$EFFORT_BODY" \
   && grep -q -- "Reviewer effort: \`high\`" "$EFFORT_BODY"; then
  pass "orchestrator resolves codex effort=high + timeout=120 from policy and wires them end-to-end"
else fail "orchestrator policy codex effort/timeout (rc=$rc, out=$out, body=$(test -e "$EFFORT_BODY" && cat "$EFFORT_BODY" || true))"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te.yml" CLAUDE_BIN="$BIN/fake-claude-effort" \
  bash "$ORCH" 141 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.reviewer_effort')" = "xhigh" ]; then
  pass "orchestrator resolves claude effort=xhigh from policy (author=codex → reviewer claude)"
else fail "orchestrator policy claude effort (rc=$rc, out=$out)"; fi

# Outer bound is policy-driven: disable the inner CLI timeout (env 0) so only
# the policy-resolved outer bound fires deterministically on the 5s sleep.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-t1.yml" P4B_REVIEW_CLI_TIMEOUT_SECONDS=0 CODEX_BIN="$BIN/fake-codex-sleep" \
  bash "$ORCH" 142 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r '.reason')" = "adapter timed out after 1s" ]; then
  pass "orchestrator outer timeout is policy-driven (adapter_timeout_seconds=1 → exit 4)"
else fail "orchestrator policy timeout (rc=$rc, out=$out)"; fi

set +e
MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-bad-timeout.yml" CODEX_BIN="$BIN/fake-codex-approve" \
  bash "$ORCH" 143 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && pass "orchestrator fails closed (exit 3) on invalid policy timeout" || fail "invalid policy timeout should exit 3 (got $rc)"

set +e
MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-bad-effort.yml" CODEX_BIN="$BIN/fake-codex-approve" \
  bash "$ORCH" 144 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && pass "orchestrator fails closed (exit 3) on invalid policy effort" || fail "invalid policy effort should exit 3 (got $rc)"

# ===========================================================================
echo "collect-enablement-evidence.sh (#586)"
# ===========================================================================
EVI="$ROOT/scripts/phase-4b/collect-enablement-evidence.sh"
[ -x "$EVI" ] && pass "evidence script present and executable" || fail "evidence script missing/not executable: $EVI"
mk_fake fake-codex-evi \
  "if [ \"\${1:-}\" = '--version' ]; then echo 'codex-cli 1.2.3-evi'; exit 0; fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'"
mk_fake fake-claude-evi \
  "if [ \"\${1:-}\" = '--version' ]; then echo 'claude 4.5.6-evi'; exit 0; fi
jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}' '{type:\"result\",result:\$r,session_id:\"t\"}'"

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --json --no-dry-run)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.ready')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.adapters.codex.version')" = "codex-cli 1.2.3-evi" ] \
   && [ "$(printf '%s' "$out" | jq -r '.adapters.claude.plan_auth_ok')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.api_key_env.any_set')" = "false" ]; then
  pass "evidence: READY (versions + plan auth + no API keys) → exit 0"
else fail "evidence READY (rc=$rc): $out"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi" CLAUDE_BIN="$BIN/fake-claude-evi" OPENAI_API_KEY=sk-should-block \
  bash "$EVI" --json --no-dry-run)"; rc=$?
set -e
if [ "$rc" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.ready')" = "false" ] \
   && [ "$(printf '%s' "$out" | jq -r '.api_key_env.OPENAI_API_KEY')" = "SET" ] \
   && ! printf '%s' "$out" | grep -q "sk-should-block"; then
  pass "evidence: a SET API-key env var → BLOCKED (exit 1), value never printed"
else fail "evidence BLOCKED-by-key (rc=$rc): $out"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_API" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_API" \
  CODEX_BIN="$BIN/fake-codex-evi" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --json --no-dry-run)"; rc=$?
set -e
if [ "$rc" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.adapters.codex.plan_auth_ok')" = "false" ] \
   && [ "$(printf '%s' "$out" | jq -r '.adapters.claude.plan_auth_ok')" = "false" ]; then
  pass "evidence: no plan-authed CLI (API-key auth) → BLOCKED (exit 1)"
else fail "evidence BLOCKED-by-auth (rc=$rc): $out"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --json --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.adapters.codex.dry_run')" = "rc=0 verdict=APPROVED" ]; then
  pass "evidence: dry-run runs the adapter and reports its verdict"
else fail "evidence dry-run (rc=$rc): $out"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --no-dry-run)"; rc=$?
set -e
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "ENABLEMENT READINESS: READY" && printf '%s' "$out" | grep -q "Phase 4b enablement evidence"; then
  pass "evidence: markdown report renders the readiness verdict"
else fail "evidence markdown (rc=$rc): $out"; fi

# ===========================================================================
echo "phase-4b — #598 Codex review fixes (P2/P3)"
# ===========================================================================
cat > "$WORK/policy-xhigh.yml" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  codex_effort: xhigh
YAML

# (1) xhigh is a valid Codex model_reasoning_effort (#598 P2). Resolver + adapter.
export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-xhigh.yml"
r="$(p4b_resolve_adapter_effort codex)"; [ "$r" = xhigh ] && pass "resolver accepts codex effort xhigh" || fail "codex xhigh resolver -> $r"
unset MERGEPATH_REVIEW_POLICY_PATH
set +e
out="$(P4B_CODEX_EFFORT=xhigh CODEX_BIN="$BIN/fake-codex-effort" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.summary')" = "effort=xhigh" ]; then
  pass "codex adapter accepts + passes xhigh effort"
else fail "codex xhigh adapter (rc=$rc, out=$out)"; fi

# (2) A P4B_ADAPTER_TIMEOUT_SECONDS override extends BOTH the outer bound AND the
# adapter's inner CLI timeout (#598 P2). policy=1s would kill a 2s CLI under the
# old bug; override=5s must let it complete.
mk_fake fake-codex-sleep2 \
  "sleep 2
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-t1.yml" P4B_ADAPTER_TIMEOUT_SECONDS=5 CODEX_BIN="$BIN/fake-codex-sleep2" \
  bash "$ORCH" 150 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.adapter_timeout_seconds')" = "5" ]; then
  pass "P4B_ADAPTER_TIMEOUT_SECONDS override reaches the adapter inner timeout (2s CLI survives policy=1s)"
else fail "timeout override propagation (rc=$rc, out=$out)"; fi

# (3) An explicit P4B_CODEX_EFFORT override is what the adapter runs, so the
# recorded reviewer_effort must reflect the override, not the policy (#598 P3).
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te.yml" P4B_CODEX_EFFORT=low CODEX_BIN="$BIN/fake-codex-effort" \
  bash "$ORCH" 151 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.reviewer_effort')" = "low" ]; then
  pass "orchestrator records the effective effort override (low), not policy (high)"
else fail "effective effort recording (rc=$rc, out=$out)"; fi

# (4)+(5) evidence dry-run runs under the resolved settings, and readiness
# blocks on a failed dry-run / invalid config (#598 P2).
mk_fake fake-codex-evi-effort \
  "if [ \"\${1:-}\" = '--version' ]; then echo 'codex-cli 1.2.3-evi'; exit 0; fi
seen=0; prev=''
for a in \"\$@\"; do if [ \"\$prev\" = '-c' ] && [ \"\$a\" = 'model_reasoning_effort=high' ]; then seen=1; fi; prev=\"\$a\"; done
if [ \"\$seen\" = 1 ]; then printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'; else echo MISSING-EFFORT >&2; exit 4; fi"

# With policy codex_effort=high, the evidence dry-run applies it, so the
# effort-requiring fake approves and readiness stays READY.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te.yml" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi-effort" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --json --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.ready')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.adapters.codex.dry_run')" = "rc=0 verdict=APPROVED" ]; then
  pass "evidence dry-run applies the resolved codex effort (high) to the adapter"
else fail "evidence dry-run resolved settings (rc=$rc): $out"; fi

# With policy that does NOT set codex_effort, the same fake fails (no high), the
# dry-run fails, and readiness flips to BLOCKED.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi-effort" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --json --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.ready')" = "false" ] \
   && printf '%s' "$out" | jq -r '.blockers' | grep -q "codex dry-run failed"; then
  pass "evidence readiness BLOCKS on a failed requested dry-run"
else fail "evidence dry-run failure blocks readiness (rc=$rc): $out"; fi

# An INVALID resolver value for an authed direction blocks readiness even
# without a dry-run.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-te-bad-timeout.yml" P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT" P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN" \
  CODEX_BIN="$BIN/fake-codex-evi" CLAUDE_BIN="$BIN/fake-claude-evi" \
  env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bash "$EVI" --json --no-dry-run)"; rc=$?
set -e
if [ "$rc" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.ready')" = "false" ] \
   && printf '%s' "$out" | jq -r '.blockers' | grep -q "codex config resolves INVALID"; then
  pass "evidence readiness BLOCKS on an INVALID resolved config"
else fail "evidence invalid-config blocks readiness (rc=$rc): $out"; fi

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
