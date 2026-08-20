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
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true
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

# (#814) The orchestrator now consults both external providers before it will
# post an approval. Default every pre-existing case to "both have already
# reported on this head" so each still exercises the flow it was written for
# rather than stopping at the barrier; cases that want a different barrier
# outcome override these two. Every orchestrator case in this file reviews
# --head abc123.
cat >"$WORK/stub-barrier-codex.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$WORK/stub-barrier-coderabbit.sh" <<'EOF'
#!/bin/sh
printf '{"head_sha":"abc123","probe":{"mode":true,"observed":"terminal"}}'
EOF
chmod +x "$WORK/stub-barrier-codex.sh" "$WORK/stub-barrier-coderabbit.sh"
export P4B_CODEX_REVIEW_CHECK="$WORK/stub-barrier-codex.sh"
export P4B_CODERABBIT_WAIT="$WORK/stub-barrier-coderabbit.sh"

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
# #696 finding 1: the reviewer-CLI --version probe must run through the same
# SAFE_ENV scrub as the review call. These fakes record, into
# \$P4B_VERSION_PROBE_LEAK, any credential env var visible DURING the --version
# invocation; a scrubbed probe leaves the file empty. Any other invocation
# (the review call) prints a normal verdict.
mk_fake fake-codex-version-probe-leak \
  "if [ \"\${1:-}\" = '--version' ]; then
  [ -n \"\${GH_TOKEN:-}\${OP_PREFLIGHT_REVIEWER_PAT:-}\${OP_PREFLIGHT_AUTHOR_PAT:-}\${OPENAI_API_KEY:-}\${CODEX_API_KEY:-}\" ] && echo VERSION-PROBE-LEAK >> \"\${P4B_VERSION_PROBE_LEAK:-/dev/null}\"
  echo 'codex-cli 9.9.9'; exit 0
fi
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}'"
mk_fake fake-claude-version-probe-leak \
  "if [ \"\${1:-}\" = '--version' ]; then
  [ -n \"\${GH_TOKEN:-}\${OP_PREFLIGHT_REVIEWER_PAT:-}\${OP_PREFLIGHT_AUTHOR_PAT:-}\${ANTHROPIC_API_KEY:-}\${ANTHROPIC_AUTH_TOKEN:-}\" ] && echo VERSION-PROBE-LEAK >> \"\${P4B_VERSION_PROBE_LEAK:-/dev/null}\"
  echo 'claude 9.9.9'; exit 0
fi
jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\"}'"
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
  printf 'OP_PREFLIGHT_REVIEWER_PAT=%s\n' "${OP_PREFLIGHT_REVIEWER_PAT:-}"  # TOKEN_OUTPUT_EXEMPT: records the reviewer PAT the orchestrator pinned, asserted against a fixture sentinel (#996)
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

# #697: a `diff --git` header whose path contains the literal " b/" (e.g.
# `a/foo b/bar b/foo b/bar` for the edit of `foo b/bar`) must resolve to the
# correct new path in BOTH the omit report and the placeholder disclosure, not
# the greedy last-" b/" tail (`bar`). The omit decision is keyed by index, so
# the section is still dropped; the finding is that the DISCLOSURE named the
# wrong file.
TRIM_SPACEY="$WORK/trim-spacey.diff"
{
  printf 'diff --git a/keep.js b/keep.js\n+ok\n'
  printf 'diff --git a/data/foo b/bar.jsonl b/data/foo b/bar.jsonl\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+SPACEY-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_SPACEY"
set +e
rep="$(p4b_trim_review_diff "$TRIM_SPACEY" "$TRIM_OUT" 2000 'data/*')"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && printf '%s\n' "$rep" | grep -q "^data/foo b/bar.jsonl$(printf '\t')" \
   && grep -qF '[phase-4b diff-budget: data/foo b/bar.jsonl omitted' "$TRIM_OUT" \
   && ! grep -q 'SPACEY-' "$TRIM_OUT"; then
  pass "trim: header path containing \" b/\" names the correct new path in report + placeholder (#697)"
else fail "trim spacey b/ path (rc=$rc, report='${rep:-}', placeholder=$(grep -o '\[phase-4b diff-budget:[^]]*' "$TRIM_OUT" | head -1))"; fi

# #712 finding: a RENAME whose header (a != b) concatenated text carries an
# earlier SYMMETRIC " b/" split must be disclosed as its AUTHORITATIVE rename-to
# destination, not the synthetic header midpoint. Renaming `data/a b/data/a
# b/data/a` -> `data/a` yields header `a/data/a b/data/a b/data/a b/data/a`,
# whose rest `data/a b/data/a b/data/a b/data/a` has a symmetric split at the
# middle (`data/a b/data/a` == `data/a b/data/a`) — the pre-fix heuristic would
# name that midpoint. The `rename to data/a` line is authoritative. Both sides
# are under data/* so the section is omission-eligible.
TRIM_RSPLIT="$WORK/trim-rename-split.diff"
{
  printf 'diff --git a/keep.js b/keep.js\n+ok\n'
  printf 'diff --git a/data/a b/data/a b/data/a b/data/a\n'
  printf 'similarity index 95%%\nrename from data/a b/data/a b/data/a\nrename to data/a\n'
  awk 'BEGIN { for (i = 0; i < 200; i++) printf "+RSPLIT-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
} > "$TRIM_RSPLIT"
set +e
rep="$(p4b_trim_review_diff "$TRIM_RSPLIT" "$TRIM_OUT" 2000 'data/*')"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && printf '%s\n' "$rep" | grep -q "^data/a$(printf '\t')" \
   && grep -qF '[phase-4b diff-budget: data/a omitted' "$TRIM_OUT" \
   && ! grep -qF 'data/a b/data/a omitted' "$TRIM_OUT" \
   && ! grep -q 'RSPLIT-' "$TRIM_OUT"; then
  pass "trim: rename header with a spurious symmetric \" b/\" split names the real rename-to path (#712)"
else fail "trim rename-split b/ path (rc=$rc, report='${rep:-}', placeholder=$(grep -o '\[phase-4b diff-budget:[^]]*' "$TRIM_OUT" | head -1))"; fi

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

# #696 finding 2: the tail is interpolated into p4b_die messages that reach
# logs and the manual-fallback comment, so obvious credential patterns must be
# masked before it is returned. Feed a stderr line carrying several secret
# shapes and assert none survive verbatim while a [REDACTED] marker appears.
# The credential-shaped fixtures are ASSEMBLED at runtime rather than written
# as literals. This file is propagated verbatim to every consumer, and their
# CI greps TRACKED FILES for public secrets — a literal `ghp_`-shaped string
# here is reported as a leaked GitHub token and fails that gate on every
# synced copy, regardless of it being obviously fake. Observed on the
# 2026-07-28 wave: device-source-of-truth and friends-and-family-billing both
# failed with "Potential public secrets found in tracked files" pointing at
# these two lines. Splitting each prefix from its body leaves no
# scanner-matchable literal in the file while the redaction assertions below
# still exercise byte-identical input.
_ghp='ghp_'; _skp='sk-proj-'
GHP_FIXTURE="${_ghp}ABCdef0123456789ghijkl"
SKP_FIXTURE="${_skp}9zXcVbNm12345"
printf 'auth error: %s rejected; OPENAI %s bad; Authorization: Bearer eyJhbGciOi.payload.sig; token=supersecretvalue key=anotherKey123; github_pat_11ABCDEZ0_taildata\n' \
  "$GHP_FIXTURE" "$SKP_FIXTURE" > "$ERRF"
got="$(p4b_stderr_tail "$ERRF")"
if printf '%s' "$got" | grep -q 'REDACTED' \
   && ! printf '%s' "$got" | grep -q "$GHP_FIXTURE" \
   && ! printf '%s' "$got" | grep -q "$SKP_FIXTURE" \
   && ! printf '%s' "$got" | grep -q 'eyJhbGciOi.payload.sig' \
   && ! printf '%s' "$got" | grep -q 'supersecretvalue' \
   && ! printf '%s' "$got" | grep -q 'anotherKey123' \
   && ! printf '%s' "$got" | grep -q 'github_pat_11ABCDEZ0_taildata'; then
  pass "stderr tail redacts token/key/bearer/pat secret patterns (#696)"
else fail "stderr tail redaction (got '${got:-}')"; fi

# #712 finding: env-style UPPERCASE credential labels (PASSWORD=, TOKEN=,
# SECRET=, API_KEY=, AUTHORIZATION=) must be redacted too — the label match is
# fully case-insensitive, not Title/lowercase-only.
printf 'auth error: PASSWORD=hunter2upper TOKEN=UPPERtok123 SECRET=UPPERsec456 API_KEY=UPPERkey789 AUTHORIZATION=UPPERauth012\n' > "$ERRF"
got="$(p4b_stderr_tail "$ERRF")"
if printf '%s' "$got" | grep -q 'REDACTED' \
   && ! printf '%s' "$got" | grep -q 'hunter2upper' \
   && ! printf '%s' "$got" | grep -q 'UPPERtok123' \
   && ! printf '%s' "$got" | grep -q 'UPPERsec456' \
   && ! printf '%s' "$got" | grep -q 'UPPERkey789' \
   && ! printf '%s' "$got" | grep -q 'UPPERauth012'; then
  pass "stderr tail redacts UPPERCASE env-style credential labels (#712)"
else fail "stderr tail uppercase redaction (got '${got:-}')"; fi

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

# #696 finding 1: the --version probe must also run under SAFE_ENV. With the
# tokens set in the parent env, a probe that skipped the scrub would let the
# fake see them and append to the leak file. Assert the file stays empty AND
# the review still produces a verdict.
VPROBE_LEAK="$WORK/version-probe-leak-codex"; : > "$VPROBE_LEAK"
set +e
out="$(GH_TOKEN=ghp-reviewer OP_PREFLIGHT_REVIEWER_PAT=ghp-reviewer OP_PREFLIGHT_AUTHOR_PAT=ghp-author \
  OPENAI_API_KEY=sk-live-openai CODEX_API_KEY=codex-key P4B_VERSION_PROBE_LEAK="$VPROBE_LEAK" \
  CODEX_BIN="$BIN/fake-codex-version-probe-leak" bash "$AD_CODEX" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] && [ ! -s "$VPROBE_LEAK" ]; then
  pass "codex adapter runs the --version probe through SAFE_ENV (no token leak, #696)"
else fail "codex --version probe leaked env (rc=$rc, leak='$(cat "$VPROBE_LEAK")', out=$out)"; fi

VPROBE_LEAK_CL="$WORK/version-probe-leak-claude"; : > "$VPROBE_LEAK_CL"
set +e
out="$(GH_TOKEN=ghp-reviewer OP_PREFLIGHT_REVIEWER_PAT=ghp-reviewer OP_PREFLIGHT_AUTHOR_PAT=ghp-author \
  ANTHROPIC_API_KEY=sk-ant ANTHROPIC_AUTH_TOKEN=ant-tok P4B_VERSION_PROBE_LEAK="$VPROBE_LEAK_CL" \
  CLAUDE_BIN="$BIN/fake-claude-version-probe-leak" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] && [ ! -s "$VPROBE_LEAK_CL" ]; then
  pass "claude adapter runs the --version probe through SAFE_ENV (no token leak, #696)"
else fail "claude --version probe leaked env (rc=$rc, leak='$(cat "$VPROBE_LEAK_CL")', out=$out)"; fi

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

# Undispositioned feedback is a distinct no-dispatch hold, not a manual
# fallback and not a completed review round.
FEEDBACK_BLOCK_STUB="$WORK/feedback-accounting-block.sh"
cat >"$FEEDBACK_BLOCK_STUB" <<'EOF'
#!/bin/sh
printf '%s\n' '{"status":"unaccounted","posted":3,"accounted":2}'
exit 1
EOF
chmod +x "$FEEDBACK_BLOCK_STUB"
ADAPTER_RAN="$WORK/feedback-block-adapter.log"
FEEDBACK_ADAPTER_PROBE="$WORK/feedback-block-adapter.sh"
cat >"$FEEDBACK_ADAPTER_PROBE" <<EOF
#!/bin/sh
printf 'ran\n' >>"$ADAPTER_RAN"
exit 0
EOF
chmod +x "$FEEDBACK_ADAPTER_PROBE"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$FEEDBACK_BLOCK_STUB" \
  CODEX_BIN="$FEEDBACK_ADAPTER_PROBE" \
  bash "$ORCH" 122 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>&1)"; rc=$?
set -e
if [ "$rc" = 7 ] \
   && printf '%s' "$out" | grep -q 'review feedback is unaccounted' \
   && [ ! -e "$ADAPTER_RAN" ]; then
  pass "feedback accounting miss → exit 7 before Phase 4b adapter dispatch"
else fail "feedback accounting pre-dispatch gate (rc=$rc, out=$out)"; fi

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$FEEDBACK_BLOCK_STUB" \
  P4B_ADAPTER_DIR="$WORK/no-adapters" \
  bash "$ORCH" 122 --repo o/r --author claude --reviewer nathanpayne-codex --head abc123 --diff-file "$DIFF" --dry-run 2>&1)"; rc=$?
set -e
if [ "$rc" = 7 ] \
   && printf '%s' "$out" | grep -q 'review feedback is unaccounted' \
   && ! printf '%s' "$out" | grep -q 'fell_back_to_manual'; then
  pass "early adapter fallback propagates feedback hold as exit 7 without manual handoff"
else fail "early fallback feedback hold propagation (rc=$rc, out=$out)"; fi

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

# --- #814 same-head provider barrier machinery -----------------------------
#
# Additive helpers with no callers yet; the barrier itself lands separately.
# These pin the properties that decide whether a barrier built on them can be
# opened wrongly.

# shellcheck source=../scripts/phase-4b/lib.sh
. "$LIB"

cat >"$WORK/policy-barrier.yml" <<'EOF'
coderabbit:
  severity_gate:
    enabled: true
  max_wait_seconds: 900
codex:
  p1_gate:
    enabled: true
  enabled: false
phase_4b_automation:
  enabled: true
EOF

# Direct-child scoping. coderabbit has NO top-level `enabled`, only a nested
# severity_gate.enabled: a flat scan returns that nested true and the barrier
# would guard on a sub-gate toggle it was never meant to read. codex has both,
# and the direct child (false) must win over p1_gate.enabled (true).
_bp() { MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-barrier.yml" p4b_policy_block_field "$1" "$2"; }
if [ -z "$(_bp coderabbit enabled)" ] \
   && [ "$(_bp codex enabled)" = "false" ] \
   && [ "$(_bp coderabbit max_wait_seconds)" = "900" ]; then
  pass "#814: block reader matches only DIRECT children — a nested sub-gate enabled never masquerades as the master switch"
else
  fail "#814: block reader leaked a nested key (coderabbit.enabled='$(_bp coderabbit enabled)' codex.enabled='$(_bp codex enabled)')"
fi

if [ "$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-barrier.yml" p4b_automation_field enabled)" = "true" ]; then
  pass "#814: p4b_automation_field still reads its own block through the generalized reader"
else
  fail "#814: p4b_automation_field regressed after generalization"
fi

# Terminality. Only reported / will-not-report may open a barrier.
_cr() { p4b_barrier_class_coderabbit abc123 "$1" "$2"; }
bad=""
[ "$(_cr 0 '{"head_sha":"abc123"}')" = reported ]        || bad="$bad rc0-match"
# rc 2 is NOT a report. In --probe mode it is the one verdict the probe makes:
# a blocking marker carried solely by the PR-level summary, which #823 emits
# precisely because no required gate dispositions that class. The barrier is
# the only reader of that signal, so it escalates to a human rather than
# opening and letting an approval post over it (Codex P1 on #842).
[ "$(_cr 2 '{"head_sha":"abc123"}')" = escalate ]        || bad="$bad rc2-summary-only"
[ "$(_cr 2 '{"head_sha":"stale99"}')" = escalate ]       || bad="$bad rc2-stale"
# A terminal rc anchored on an OLDER head is a stale clearance — the #794 shape.
[ "$(_cr 0 '{"head_sha":"old999"}')" = not-yet ]         || bad="$bad rc0-stale"
[ "$(_cr 0 '{}')" = not-yet ]                            || bad="$bad rc0-nohead"
# EVERY exit-6 skip is not-yet. draft and non-base-branch are PR-level states
# that can change WITHOUT the head changing — marking a draft ready or
# retargeting the base makes CodeRabbit review that same head, possibly after
# the Phase 4b approval has posted, which is the ordering race this barrier
# exists to prevent (Codex P1 on #835). paused is the same shape, and an
# unmodelled reason must never open a barrier.
[ "$(_cr 6 '{"skip_reason":"draft"}')" = not-yet ]           || bad="$bad rc6-draft"
[ "$(_cr 6 '{"skip_reason":"non-base-branch"}')" = not-yet ] || bad="$bad rc6-nonbase"
[ "$(_cr 6 '{"skip_reason":"paused"}')" = not-yet ]          || bad="$bad rc6-paused"
[ "$(_cr 6 '{"skip_reason":"unmodelled"}')" = not-yet ]      || bad="$bad rc6-unknown"
[ "$(_cr 7 '{}')" = not-yet ]                            || bad="$bad rc7"
[ "$(_cr 4 '{}')" = not-yet ]                            || bad="$bad rc4"
# #869 review-objects channel (head-anchored, completion-corroborated AND
# temporally correlated — P1s on #875): an rc-7 probe whose evidence is a
# HEAD-pinned review OBJECT (endpoint "reviews") opens the barrier ONLY
# alongside a per-SHA StatusContext success (probe.context_state) whose
# refresh time (probe.context_updated_at) is at-or-after the object's own
# review.submitted_at. The object proves head identity; the status proves
# the run completed; the ordering proves the two belong to the SAME run.
# On #866 a fair-use limit note appended to the finished-review reply masked
# the summary publication while coderabbitai[bot] had two COMMENTED reviews
# on the exact head and a per-SHA success postdating them, and the barrier
# held not-yet until it escalated.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"awaiting-summary","context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = reported ] \
                                                         || bad="$bad rc7-review-object-ctx"
# At-or-after is inclusive: a status refreshed the same second as the
# object still corroborates it.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"awaiting-summary","context_state":"success","context_updated_at":"2026-06-04T00:00:06Z"}}')" = reported ] \
                                                         || bad="$bad rc7-review-object-eqctx"
# Observed-state precedence (P1 round 3 on #875): an ACTIVE adverse state
# named by the probe — a pending rate-limit / pause / in-progress notice
# beneath the review object — asserts CodeRabbit is NOT done here, and a
# postdating spurious success (#595) must not outrank it. Otherwise-valid
# evidence with an adverse observed stays not-yet; so does a missing or
# unmodelled observed (fail closed).
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"rate_limit","context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-observed-ratelimit"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"paused","context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-observed-paused"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"in_progress","context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-observed-inprogress"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-observed-missing"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"someday-new-state","context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-observed-unmodelled"
# A BARE just-posted review object must NOT open the barrier (P1 on #875):
# the PR-level summary still in flight can carry the ONLY blocking marker
# (the #535 summary-only class, e.g. the auto-pause note), and the probe
# returns rc 7 observed=awaiting-summary for that state on purpose. Missing
# context_state — including the trust-opted-out null — and every
# non-success state stay not-yet.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-bare"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"awaiting-summary","context_state":null,"context_updated_at":null}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-nullctx"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"missing","context_updated_at":null}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-missingctx"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"pending","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-pendingctx"
# The same-SHA rerun shape (#875 round 2): a success whose refresh time
# PREDATES the review object belongs to the PREVIOUS run against this sha —
# the new object's summary and status refresh are still pending, so the
# stale success must not open the barrier past them.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:00Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-stalectx"
# Either half of the correlation missing, or unparseable, fails closed —
# an old probe emission (no submitted_at / no context_updated_at) keeps
# the pre-#869 bounded wait.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-nosubmitted"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"success"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-noctxat"
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"not-a-date"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-badts"
# Stale-head evidence must not clear even fully corroborated — the same
# #794 posture as rc 0.
[ "$(_cr 7 '{"head_sha":"old999","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-review-object-stale"
# "issues" evidence on rc 7 is a pending notice or a prior-head summary,
# never head-anchored terminality — a correlated context success cannot
# upgrade it.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9982,"endpoint":"issues","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc7-issues-evidence"
# The channel is probe-only: a polling timeout (rc 4) never carries
# review-object evidence, and unmodelled shapes must not open the barrier.
[ "$(_cr 4 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = not-yet ] \
                                                         || bad="$bad rc4-no-channel"
# rc 5 is only an escalation when the #489 failover did NOT engage. When it
# did, AGENTS.md step 5 makes the stall a non-blocking note and the Codex arm
# owns terminality; escalating anyway forces a manual fallback on every
# rate-limited run where the failover worked (Codex P2 on #835, raised twice).
[ "$(_cr 5 '{}')" = escalate ]                                    || bad="$bad rc5"
[ "$(_cr 5 '{"codex_failover_requested":false}')" = escalate ]    || bad="$bad rc5-nofailover"
# WAIVED, not not-yet: not-yet still blocks until the budget expires and then
# escalates, which is the manual fallback the failover exists to avoid. The arm
# has to actually open, with the Codex arm carrying the ordering from there.
[ "$(_cr 5 '{"codex_failover_requested":true}')" = waived ]       || bad="$bad rc5-failover"
[ "$(_cr 3 '{}')" = escalate ]                           || bad="$bad rc3"
[ "$(p4b_barrier_class_codex 0)" = reported ]            || bad="$bad codex0"
[ "$(p4b_barrier_class_codex 1)" = not-yet ]             || bad="$bad codex1"
[ "$(p4b_barrier_class_codex 3)" = escalate ]            || bad="$bad codex3"
if [ -z "$bad" ]; then
  pass "#814: no rc opens the barrier except a head-matched report; every exit-6 skip and every stale head reads NOT-YET"
else
  fail "#814: terminality misclassified:$bad"
fi

# Bounded not-yet retry. The marker records only "this checkout began waiting
# at T" — terminality never comes from it — so both tamper directions must
# fail safe.
export P4B_ACCT_STATE_DIR="$WORK/barrier-state"
# Claims no longer live under the checkout's state dir (#858) — they live under
# a shared per-user root so two checkouts contend for the same one. Pin it into
# $WORK for the whole barrier section: without this the suite would write into
# the developer's real ~/.local/state, and a stale claim there could make a
# later live run decline.
export P4B_CLAIM_DIR="$WORK/barrier-claims"
_mk() { p4b_barrier_marker_path owner/repo 99 headsha; }
bad=""
[ "$(p4b_barrier_note_pending owner/repo 99 headsha)" = "0" ] || bad="$bad first"
printf '%s\n' "$(( $(date +%s) - 600 ))" >"$(_mk)"
[ "$(p4b_barrier_note_pending owner/repo 99 headsha)" -ge 590 ] || bad="$bad elapsed"
# A future-dated marker must restart the budget, never go negative — which
# would otherwise read as a huge elapsed and escalate immediately.
printf '%s\n' "$(( $(date +%s) + 9000 ))" >"$(_mk)"
[ "$(p4b_barrier_note_pending owner/repo 99 headsha)" = "0" ] || bad="$bad future"
# A garbage marker must not crash — and must be REPAIRED, not merely tolerated.
# Returning 0 without rewriting it means every later one-shot invocation reads
# the same invalid value and reports zero elapsed again, so the bounded retry
# never exhausts and the manual fallback is never reached (Codex P2 on #835).
# The first version of this assertion checked only the return value and so
# pinned the defect as correct.
printf 'not-a-number\n' >"$(_mk)"
[ "$(p4b_barrier_note_pending owner/repo 99 headsha)" = "0" ] || bad="$bad garbage"
case "$(cat "$(_mk)" 2>/dev/null)" in ''|*[!0-9]*) bad="$bad garbage-not-repaired" ;; esac
# Same for a future-dated marker: the clock must be restarted ON DISK.
printf '%s\n' "$(( $(date +%s) + 9000 ))" >"$(_mk)"
[ "$(p4b_barrier_note_pending owner/repo 99 headsha)" = "0" ] || bad="$bad future2"
[ "$(cat "$(_mk)" 2>/dev/null)" -le "$(date +%s)" ] || bad="$bad future-not-repaired"
p4b_barrier_clear_pending owner/repo 99 headsha
[ ! -f "$(_mk)" ] || bad="$bad clear"
# A different head gets its own budget rather than inheriting the last one.
[ "$(p4b_barrier_note_pending owner/repo 99 otherhead)" = "0" ] || bad="$bad perhead"
if [ -z "$bad" ]; then
  pass "#814: pending budget is per-head, restarts on a future/garbage marker, and clears"
else
  fail "#814: pending budget misbehaved:$bad"
fi

# #840: DIGIT-ONLY is not the same as USABLE. The `''|*[!0-9]*` guard above
# passes all three of these, and each then breaks a different way, so each is
# asserted on the value AND on the repair — a return-value-only assertion
# pinned the #835 defect as correct once already.
bad=""
_canon() { p4b_barrier_canon_epoch "$1" 2>/dev/null || printf 'INVALID'; }
# Canonicalisation itself: `[ -gt ]` reads base 10, `$(( ))` reads a leading
# zero as OCTAL, so the two comparisons in note_pending disagreed.
[ "$(_canon 0755)" = "755" ]      || bad="$bad canon-octal"
[ "$(_canon 0899)" = "899" ]      || bad="$bad canon-not-octal"
[ "$(_canon 0000)" = "0" ]        || bad="$bad canon-all-zero"
[ "$(_canon 1786000000)" = "1786000000" ] || bad="$bad canon-plain"
[ "$(_canon '')" = "INVALID" ]    || bad="$bad canon-empty"
[ "$(_canon 12ab)" = "INVALID" ]  || bad="$bad canon-nonnumeric"
# Wider than int64: `[ -gt ]` errors "integer expression expected" and the
# arithmetic wraps NEGATIVE, which reads as "barely started" — unbounded wait.
[ "$(_canon 999999999999999999999999999999)" = "INVALID" ] || bad="$bad canon-oversized"
[ "$(_canon 999999999999999999)" = "999999999999999999" ]  || bad="$bad canon-int64-edge"
# End to end through note_pending. Measured on origin/main: `0755` yielded an
# elapsed of ~1.79e9 (octal 493 subtracted from now) and left the marker
# unrepaired, so EVERY retry exhausted the budget and paged a human; `0899`
# failed the arithmetic outright and returned non-zero with no elapsed; the
# 30-digit value returned a negative elapsed. All three must now read 0 and
# leave a plausible epoch on disk.
for _v in 0755 0899 999999999999999999999999999999 42; do
  printf '%s\n' "$_v" >"$(_mk)"
  _rc=0
  _el="$(p4b_barrier_note_pending owner/repo 99 headsha 2>/dev/null)" || _rc=$?
  [ "$_rc" = 0 ] || bad="$bad rc-$_v"
  [ "$_el" = "0" ] || bad="$bad elapsed-$_v=$_el"
  _on_disk="$(cat "$(_mk)" 2>/dev/null)"
  case "$_on_disk" in
    ''|*[!0-9]*) bad="$bad repair-$_v" ;;
    *) [ "$_on_disk" -ge 1000000000 ] || bad="$bad floor-$_v=$_on_disk" ;;
  esac
done
# The case the plausibility floor CANNOT catch, and the reason the leading-zero
# strip is load-bearing on its own: a genuine recent epoch that acquired a
# leading zero. Base 10 accepts it and it clears the floor, so it is treated as
# a live wait — but as an octal literal it contains an 8, so the SUBTRACTION
# errors out and note_pending returns non-zero with no elapsed at all.
printf '0%s\n' "$(( $(date +%s) - 600 ))" >"$(_mk)"
_rc=0
_el="$(p4b_barrier_note_pending owner/repo 99 headsha 2>/dev/null)" || _rc=$?
[ "$_rc" = 0 ] || bad="$bad rc-leading-zero-recent"
case "$_el" in
  ''|*[!0-9]*) bad="$bad elapsed-leading-zero-recent='$_el'" ;;
  *) { [ "$_el" -ge 590 ] && [ "$_el" -le 700 ]; } || bad="$bad elapsed-leading-zero-recent=$_el" ;;
esac
if [ -z "$bad" ]; then
  pass "#840: a digit-only but unusable marker epoch is canonicalised, range-checked and REPAIRED, never subtracted"
else
  fail "#840: marker epoch canonicalisation wrong:$bad"
fi

# The marker must never land in the working tree when the state dir is set —
# lib.sh must not depend on accounting.sh being loaded for that.
if [ -d "$WORK/barrier-state/phase-4b-barrier" ] && [ ! -d "$ROOT/.mergepath/phase-4b-barrier" ]; then
  pass "#814: markers honour P4B_ACCT_STATE_DIR without accounting.sh loaded (no working-tree writes)"
else
  fail "#814: marker path ignored the state-dir override"
fi

if [ "$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-barrier.yml" p4b_barrier_budget_seconds)" = "900" ] \
   && [ "$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/nonexistent.yml" p4b_barrier_budget_seconds)" = "1245" ]; then
  pass "#814: budget reads coderabbit.max_wait_seconds and defaults rather than failing closed"
else
  fail "#814: budget resolution wrong"
fi

# --- #814 barrier composition and the CodeRabbit trigger --------------------

# Idempotency is anchored on a SHA-bearing marker AND the reviewer identity.
# An unscoped body search is forgeable and cannot establish that automation
# spent the head's one request.
bad=""
_m="$(p4b_barrier_trigger_marker deadbee)"
case "$_m" in *deadbee*) ;; *) bad="$bad marker-lacks-sha" ;; esac
_mine="[{\"user\":{\"login\":\"rev-bot\"},\"body\":\"@coderabbitai review $_m\"}]"
_forged="[{\"user\":{\"login\":\"someone-else\"},\"body\":\"@coderabbitai review $_m\"}]"
_oldhead="[{\"user\":{\"login\":\"rev-bot\"},\"body\":\"$(p4b_barrier_trigger_marker otherhd)\"}]"
p4b_barrier_trigger_posted deadbee rev-bot "$_mine"     || bad="$bad own-marker-missed"
! p4b_barrier_trigger_posted deadbee rev-bot "$_forged" || bad="$bad forged-author-accepted"
! p4b_barrier_trigger_posted deadbee rev-bot "$_oldhead"|| bad="$bad wrong-head-accepted"
! p4b_barrier_trigger_posted deadbee rev-bot '[]'       || bad="$bad empty-accepted"
if [ -z "$bad" ]; then
  pass "#814: trigger idempotency requires this head's marker AND the reviewer identity"
else
  fail "#814: trigger idempotency wrong:$bad"
fi

# Never re-ask a provider that is already working or has already refused:
# both spend from the same pool the barrier exists to conserve.
bad=""
for _o in none summary-without-head-review; do
  p4b_barrier_should_trigger "$_o" || bad="$bad missing-$_o"
done
for _o in in_progress rate_limit paused awaiting-summary terminal "" bogus-future-state; do
  ! p4b_barrier_should_trigger "$_o" || bad="$bad triggers-on-${_o:-empty}"
done
if [ -z "$bad" ]; then
  pass "#814: trigger fires only where nobody has asked about this head; never on rate_limit/in_progress/paused"
else
  fail "#814: trigger decision table wrong:$bad"
fi

# Composition. Stubs stand in for both provider CLIs; `gh` is stubbed on PATH
# so nothing reaches the network, and dry=true so no trigger is ever posted.
mkdir -p "$WORK/barrier-bin" "$WORK/barrier-state"
printf '#!/bin/sh\necho "[]"\n' >"$WORK/barrier-bin/gh"
chmod +x "$WORK/barrier-bin/gh"

_barrier() { # <cx_rc> <cr_rc> <cr_json> [policy]
  printf '#!/bin/sh\nexit %s\n' "$1" >"$WORK/stub-cx.sh"
  printf "#!/bin/sh\nprintf '%%s' '%s'\nexit %s\n" "$3" "$2" >"$WORK/stub-cr.sh"
  chmod +x "$WORK/stub-cx.sh" "$WORK/stub-cr.sh"
  (
    export MERGEPATH_REVIEW_POLICY_PATH="${4:-$WORK/barrier-both.yml}"
    export P4B_ACCT_STATE_DIR="$WORK/barrier-state"
    export P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx.sh"
    export P4B_CODERABBIT_WAIT="$WORK/stub-cr.sh"
    export PATH="$WORK/barrier-bin:$PATH"
    p4b_same_head_barrier owner/repo 7 abc123 rev-bot true
  )
}

cat >"$WORK/barrier-both.yml" <<'EOF'
coderabbit:
  enabled: true
  max_wait_seconds: 100
codex:
  enabled: true
EOF
cat >"$WORK/barrier-off.yml" <<'EOF'
coderabbit:
  enabled: false
codex:
  enabled: false
EOF

bad=""
out="$(_barrier 0 0 '{"head_sha":"abc123"}')" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = open ] || bad="$bad both-reported"
# The marker must be gone once the barrier opens, so a later not-yet on the
# same head starts a fresh budget instead of inheriting this wait.
[ ! -f "$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-abc123.pending" ] || bad="$bad open-left-marker"

out="$(_barrier 1 0 '{"head_sha":"abc123"}')" && rc=0 || rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = pending ] || bad="$bad codex-notyet"
[ "$(printf '%s' "$out" | jq -r .retry_after)" = 100 ] || bad="$bad retry-after"

# A probe anchored on a different head must never OPEN the barrier. Since the
# #842 drift fix that is escalate (2) rather than pending (1): the probe
# resolves the LIVE head, so a mismatch means a push landed and this run is
# void. p4b_barrier_class_coderabbit still maps the same shape to not-yet in
# isolation — asserted separately above — because it is a pure function over
# one probe result; the drift decision belongs to the composer, which is the
# only layer that knows which head is being reviewed.
out="$(_barrier 0 0 '{"head_sha":"stale99"}')" && rc=0 || rc=$?
[ "$rc" != 0 ] || bad="$bad stale-head-opened"
[ "$rc" = 2 ] || bad="$bad stale-head-not-drift"

# Infra failure escalates to a human rather than guessing.
out="$(_barrier 0 3 'null')" && rc=0 || rc=$?
[ "$rc" = 2 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = escalate ] || bad="$bad cr-infra"

# Both providers disabled: neither CLI is consulted at all. The stubs would
# escalate if they ran, so `open` here also proves they did not.
out="$(_barrier 3 3 'null' "$WORK/barrier-off.yml")" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.codex + "/" + .coderabbit')" = disabled/disabled ] \
  || bad="$bad disabled-consulted"

if [ -z "$bad" ]; then
  pass "#814: barrier opens only when every ENABLED provider is terminal on this exact head"
else
  fail "#814: barrier composition wrong:$bad"
fi

# An account-blocked Codex must WAIVE, not hold. Phase 4b is the documented
# fallback for "4a unavailable", so holding the run behind a Codex that cannot
# report meant the automated leg could never serve that role — it waited out
# the whole budget and then paged a human (Codex P1 on #842).
bad=""
[ "$(p4b_barrier_class_codex 2)" = waived ]   || bad="$bad rc2-not-waived"
[ "$(p4b_barrier_class_codex 1)" = not-yet ]  || bad="$bad rc1"
[ "$(p4b_barrier_class_codex 0)" = reported ] || bad="$bad rc0"
[ "$(p4b_barrier_class_codex 3)" = escalate ] || bad="$bad rc3"
# End to end: a blocked Codex opens the barrier so the adapter can run.
out="$(_barrier 2 0 '{"head_sha":"abc123"}')" && rc=0 || rc=$?
[ "$rc" = 0 ] || bad="$bad blocked-codex-held"
printf '%s' "$out" | jq -e '.codex == "waived"' >/dev/null 2>&1 || bad="$bad blocked-codex-class"
# ...but only where a Phase 4b APPROVED can actually clear gate (c). With the
# substitute disabled, waiving would let the leg post a review the merge gate
# rejects by design — a green run leaving the PR unmergeable (Codex P2 on #842).
cat >"$WORK/policy-nosub.yml" <<'EOF'
coderabbit:
  enabled: true
  max_wait_seconds: 100
codex:
  enabled: true
  allow_phase_4b_substitute: false
EOF
out="$(_barrier 2 0 '{"head_sha":"abc123"}' "$WORK/policy-nosub.yml")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad nosub-not-escalated"
printf '%s' "$out" | jq -e '.reason | test("allow_phase_4b_substitute")' >/dev/null 2>&1 \
  || bad="$bad nosub-reason"
if [ -z "$bad" ]; then
  pass "#842: an account-blocked Codex waives rather than holding, so the Phase 4b fallback can still run"
else
  fail "#842: blocked-Codex handling wrong:$bad"
fi

# #839: the routing above is only worth what it SAVES, and the saving is the
# whole `coderabbit.max_wait_seconds` budget (1245s in this repo) that a
# terminal account block used to burn before paging a human. Two properties
# that nothing asserted before — the issue's acceptance criteria 1-3 as
# BEHAVIOUR rather than as classifier arithmetic.
bad=""
_marker="$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-abc123.pending"
_cxlog="$WORK/stub-cx-invocation.log"

# A recording stub for the Codex delegate: same exit code, plus its argv and
# the three overrides the barrier is contracted to pass.
_barrier_recording_cx() { # <cx_rc> <cr_rc> <cr_json>
  rm -f "$_cxlog"
  cat >"$WORK/stub-cx.sh" <<EOF
#!/bin/sh
printf 'argv=%s\n' "\$*" >>"$_cxlog"
printf 'skip_ci=%s require_approval=%s allow_sub=%s\n' \\
  "\${CODEX_REVIEW_CHECK_SKIP_CI:-unset}" \\
  "\${CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD:-unset}" \\
  "\${CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE:-unset}" >>"$_cxlog"
exit $1
EOF
  printf "#!/bin/sh\nprintf '%%s' '%s'\nexit %s\n" "$3" "$2" >"$WORK/stub-cr.sh"
  chmod +x "$WORK/stub-cx.sh" "$WORK/stub-cr.sh"
  (
    export MERGEPATH_REVIEW_POLICY_PATH="$WORK/barrier-both.yml"
    export P4B_ACCT_STATE_DIR="$WORK/barrier-state"
    export P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx.sh"
    export P4B_CODERABBIT_WAIT="$WORK/stub-cr.sh"
    export PATH="$WORK/barrier-bin:$PATH"
    p4b_same_head_barrier owner/repo 7 abc123 rev-bot true
  )
}

# 1. The rc-2 CANNOT-REPORT contract is only OFFERED under
#    --diagnostic-signal-only, so the barrier has to actually ask for it. A
#    merge-gate caller passes none of this and keeps the unchanged 0/1/3
#    contract; if the barrier stopped passing the flag, the delegate would
#    answer 1 for a blocked account and the budget burn would silently return.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(_barrier_recording_cx 2 0 '{"head_sha":"abc123"}')" && rc=0 || rc=$?
grep -q -- '--diagnostic-signal-only' "$_cxlog" || bad="$bad no-diagnostic-flag"
grep -q 'argv=.*--diagnostic-signal-only 7 owner/repo' "$_cxlog" || bad="$bad wrong-argv"
grep -q 'skip_ci=1 require_approval=1 allow_sub=false' "$_cxlog" || bad="$bad missing-overrides"

# 2. Criterion 1, as the thing the issue actually complains about: a blocked
#    Codex spends NO budget. The bounded-retry marker is where elapsed time
#    accumulates, so "no marker written for this head" IS "no wait started".
[ "$rc" = 0 ] || bad="$bad blocked-not-open"
[ ! -f "$_marker" ] || bad="$bad blocked-started-the-budget"

# 3. Criterion 2: absence of a Codex signal — no block marker — is still
#    not-yet, and DOES start the bounded wait. Without this the fix could be
#    "waive everything", which would let Phase 4b approve ahead of a Codex
#    round that simply had not landed yet.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(_barrier_recording_cx 1 0 '{"head_sha":"abc123"}')" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad absent-signal-not-pending"
[ "$(printf '%s' "$out" | jq -r .codex)" = "not-yet" ] || bad="$bad absent-signal-class"
[ -f "$_marker" ] || bad="$bad absent-signal-no-marker"
rm -rf "$WORK/barrier-state/phase-4b-barrier"

unset -f _barrier_recording_cx
if [ -z "$bad" ]; then
  pass "#839: the barrier requests the diagnostic contract and a terminal block opens it without starting the retry budget"
else
  fail "#839: blocked-Codex budget routing wrong:$bad"
fi

# Codex round-1 findings on #842, all four in one place.
bad=""
# 1. Head drift is detected BEFORE any trigger. The probe resolves the LIVE
#    head, so a mismatch means a push landed after $HEAD was captured;
#    triggering would spend the one permitted request on an unrelated head and
#    then hold until the whole budget expired.
out="$(_barrier 0 0 '{"head_sha":"pushed99"}')" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad drift-not-escalated"
printf '%s' "$out" | jq -e '.reason | test("head moved")' >/dev/null 2>&1 || bad="$bad drift-reason"
printf '%s' "$out" | jq -e '.trigger == "skipped"' >/dev/null 2>&1 || bad="$bad drift-triggered"

# 2. The request waits for Codex to be terminal. If Codex is still not-yet it
#    may yet force a push that discards this head and the request with it.
out="$(_barrier 1 7 'null')" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad codexnotyet-rc"
printf '%s' "$out" | jq -e '.trigger == "awaiting-codex"' >/dev/null 2>&1 || bad="$bad codexnotyet-trigger"

# 3. Once Codex IS terminal the arm proceeds to the trigger decision.
out="$(_barrier 0 7 'null')" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad codexdone-rc"
printf '%s' "$out" | jq -e '.trigger != "awaiting-codex"' >/dev/null 2>&1 || bad="$bad codexdone-blocked"

if [ -z "$bad" ]; then
  pass "#842: head drift escalates before any trigger, and the request waits for Codex to be terminal"
else
  fail "#842 trigger sequencing wrong:$bad"
fi

# 4. The mention follows coderabbit.bot_login. coderabbit-wait.sh probes the
#    configured bot, so a hardcoded @coderabbitai would address an account that
#    never answers in a consumer that renamed it — the probe keeps seeing
#    `none` and the barrier burns its whole budget on every PR.
cat >"$WORK/policy-botlogin.yml" <<'EOF'
coderabbit:
  enabled: true
  bot_login: my-rabbit[bot]
codex:
  enabled: true
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/trigger-argv.log"\nexit 0\n' "$WORK" \
  >"$WORK/barrier-bin/fake-reviewer2"
chmod +x "$WORK/barrier-bin/fake-reviewer2"
: >"$WORK/trigger-argv.log"
(
  export MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-botlogin.yml"
  export P4B_ACCT_STATE_DIR="$WORK/barrier-state"
  export P4B_GH_AS_REVIEWER="$WORK/barrier-bin/fake-reviewer2"
  p4b_barrier_post_trigger o/r 7 abc123 rev-bot
) >/dev/null 2>&1 || true
if grep -q '^@my-rabbit review' "$WORK/trigger-argv.log" \
   && ! grep -q '@coderabbitai' "$WORK/trigger-argv.log"; then
  pass "#842: the trigger mentions the configured coderabbit.bot_login, with the REST-only [bot] suffix stripped"
else
  fail "#842: trigger ignored bot_login: $(tr '\n' ' ' < "$WORK/trigger-argv.log")"
fi

# The bound is what turns an indefinite wait into a human handoff.
mkdir -p "$WORK/barrier-state/phase-4b-barrier"
printf '%s\n' "$(( $(date +%s) - 500 ))" \
  >"$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-abc123.pending"
out="$(_barrier 1 0 '{"head_sha":"abc123"}')" && rc=0 || rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | jq -e '.reason | test("within 100s")' >/dev/null; then
  pass "#814: an exhausted bound escalates to a human instead of holding forever"
else
  fail "#814: exhausted bound did not escalate (rc=$rc out=$out)"
fi

# Orchestrator wiring. A not-yet barrier must HOLD on its OWN exit code, and a
# hold is not a fallback: no chat-side handoff is rendered, and the payload
# tells the caller to retry rather than to page a human. Exit 6 rather than 4
# because AGENTS.md, REVIEW_POLICY.md and wave-audit.sh all read 4 as a
# reviewer that will not answer — and wave-audit proceeds fail-open on it.
# Codex reports not-yet here; the CodeRabbit stub installed at the top of this
# file still reports on abc123.
printf '#!/bin/sh\nexit 1\n' >"$WORK/stub-cx-notyet.sh"
printf '#!/bin/sh\necho "REGRESSION: reviewer wrapper invoked from the hold path" >&2\nexit 9\n' \
  >"$WORK/stub-rev-guard.sh"
chmod +x "$WORK/stub-cx-notyet.sh" "$WORK/stub-rev-guard.sh"
HANDOFF_LOG="$WORK/handoff-barrier.log"
: >"$HANDOFF_LOG"
# NOT --dry-run: the barrier is deliberately skipped on dry runs (it guards the
# POST, and a dry run posts nothing), so a dry run cannot exercise the hold at
# all. The hold happens before the adapter and before anything is posted, so a
# real run is safe here; the reviewer wrapper is stubbed to fail loudly if the
# hold path ever reaches a write.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" \
  bash "$ORCH" 814 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 6 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier_pending')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "false" ] \
   && [ "$(printf '%s' "$out" | jq -r '.retry_after > 0')" = "true" ] \
   && [ ! -s "$HANDOFF_LOG" ]; then
  pass "#814: a not-yet barrier holds on exit 6 with retry_after and renders no handoff — a wait is not a fallback"
else
  fail "#814: barrier hold path wrong (rc=$rc handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out"
fi

# A hold must leave NO accounting trace, and the way that is guaranteed is
# structural: the barrier is evaluated exactly ONCE, before the loop record and
# before the step-9 issue filing. A second evaluation inside post_review sits
# after both, so a hold there left a provisional "posted" loop that the next
# run published as a real approval — the phantom-posted-approval class #615
# exists to prevent — and re-filed follow-up issues every retry cycle.
# Asserted structurally because the two evaluations can only disagree when a
# provider CLI flaps between them, which no fixture can pin honestly.
# The ordering must be anchored on the CALL SITE, not on the helper reference
# inside run_same_head_barrier's definition (CodeRabbit on #842). That
# definition sits near the top of the file, so its line number is below the
# loop record no matter where the barrier is actually invoked — an ordering
# assertion anchored there passes even after someone moves the call after
# p4b_acct_hook_record_loop, which is precisely the regression this guards.
# Matched on the trailing quote, not a line anchor: the call is indented inside
# the dry-run guard, and `run_same_head_barrier(` is the definition.
n_eval="$(grep -c 'p4b_same_head_barrier ' "$ORCH" || true)"
n_call="$(grep -c 'run_same_head_barrier "' "$ORCH" || true)"
if [ "$n_eval" = "1" ] && [ "$n_call" = "1" ] \
   && [ "$(grep -n 'run_same_head_barrier "' "$ORCH" | cut -d: -f1)" -lt "$(grep -n 'p4b_acct_hook_record_loop ' "$ORCH" | head -1 | cut -d: -f1)" ]; then
  pass "#814: the barrier is called exactly once, before any loop is recorded — a hold cannot leave a phantom posted approval"
else
  fail "#814: barrier defined $n_eval time(s), called $n_call time(s), or the call is not before the loop record"
fi

# The trigger dedup must FAIL CLOSED on a comments-read failure. jq -s prints
# [] and exits 0 on empty stdin, so a folded read+parse would turn any gh
# failure into "no marker" and re-post on every bounded retry — a
# self-amplifying write loop against the allowance the marker conserves.
# The reviewer wrapper is stubbed so that a REGRESSION here cannot reach the
# real gh-as-reviewer.sh and attempt a live write from the test suite.
printf '#!/bin/sh\necho "boom" >&2\nexit 1\n' >"$WORK/barrier-bin/gh"
printf '#!/bin/sh\necho "REGRESSION: attempted a live trigger post" >&2\nexit 9\n' \
  >"$WORK/barrier-bin/fake-reviewer"
chmod +x "$WORK/barrier-bin/fake-reviewer"
res="$(P4B_ACCT_STATE_DIR="$WORK/barrier-state" PATH="$WORK/barrier-bin:$PATH" \
  P4B_GH_AS_REVIEWER="$WORK/barrier-bin/fake-reviewer" \
  p4b_barrier_maybe_trigger o/r 7 abc123 rev-bot '{"probe":{"observed":"none"}}' false 2>/dev/null)"
printf '#!/bin/sh\necho "[]"\n' >"$WORK/barrier-bin/gh"
if [ "$res" = "trigger-read-failed" ]; then
  pass "#814: a failed comments read declines to trigger rather than reading as 'never triggered'"
else
  fail "#814: trigger read failure did not fail closed (got '$res')"
fi

# --- #846 + #847: the barrier's write paths ---------------------------------
#
# Direct-source tests over the claimed write core and the resume path. The
# claim wraps the whole read-and-post region; the timeline marker stays the
# only durable record; a resume and a trigger carry distinct markers and can
# never satisfy each other's already-spent test.

# Marker distinctness (#847): kind is part of the spelling, trigger spelling
# is byte-identical to the pre-#847 literal, resume keys on the pause note.
bad=""
[ "$(p4b_barrier_marker trigger deadbee)" = '<!-- mergepath-coderabbit-trigger:deadbee -->' ] || bad="$bad trigger-spelling"
[ "$(p4b_barrier_marker resume pause-771)" = '<!-- mergepath-coderabbit-resume:pause-771 -->' ] || bad="$bad resume-spelling"
_rm="[{\"user\":{\"login\":\"rev-bot\"},\"body\":\"@coderabbitai resume $(p4b_barrier_marker resume pause-771)\"}]"
_tm="[{\"user\":{\"login\":\"rev-bot\"},\"body\":\"@coderabbitai review $(p4b_barrier_marker trigger deadbee)\"}]"
p4b_barrier_write_posted resume pause-771 rev-bot "$_rm"   || bad="$bad resume-marker-missed"
! p4b_barrier_write_posted trigger deadbee rev-bot "$_rm"  || bad="$bad resume-satisfies-trigger"
! p4b_barrier_write_posted resume pause-771 rev-bot "$_tm" || bad="$bad trigger-satisfies-resume"
[ "$(p4b_barrier_write_count resume pause-771 rev-bot "[$( printf '%s' "$_rm" | jq -c '.[0]'),$(printf '%s' "$_rm" | jq -c '.[0]')]")" = "2" ] || bad="$bad count"
if [ -z "$bad" ]; then
  pass "#847: resume and trigger markers are distinct and can never satisfy each other"
else
  fail "#847: marker distinctness wrong:$bad"
fi

# Claim primitives (#846): one winner, ownership is the winner's PID, only
# the next claimant breaks a dead owner's claim, and clear_pending never
# touches claims — an open/drift outcome in one invocation must not delete
# another invocation's LIVE claim mid-region (Codex P2, round 1).
bad=""
_cp="$(p4b_barrier_claim_path owner/repo 99 headsha trigger)"
case "$_cp" in *trigger.claim) ;; *) bad="$bad path-kind" ;; esac
p4b_barrier_claim "$_cp"     || bad="$bad first-claim"
p4b_barrier_claim "$_cp"     && bad="$bad live-owner-stolen"
p4b_barrier_clear_pending owner/repo 99 headsha
[ -d "$_cp" ] || bad="$bad clear-removed-live-claim"
p4b_barrier_release "$_cp"
p4b_barrier_claim "$_cp"     || bad="$bad reclaim-after-release"
p4b_barrier_release "$_cp"
# A dead owner's claim is broken by the NEXT claimant, and only then.
mkdir -p "$_cp"; ( : ) & _deadpid=$!; wait "$_deadpid"; printf '%s\n' "$_deadpid" >"$_cp/pid"
p4b_barrier_claim "$_cp"     || bad="$bad dead-owner-not-broken"
p4b_barrier_release "$_cp"
# A claim with no readable owner is treated as live (fail toward declining).
mkdir -p "$_cp"
p4b_barrier_claim "$_cp"     && bad="$bad ownerless-stolen"
rm -rf "$_cp"
# Two contenders reaping the SAME dead claim: rename is single-winner, so
# exactly one may take it over (rm+mkdir let both in — Codex P2, round 2).
mkdir -p "$_cp"; ( : ) & _deadpid=$!; wait "$_deadpid"; printf '%s\n' "$_deadpid" >"$_cp/pid"
( p4b_barrier_claim "$_cp" && echo win ) >"$WORK/reap-a" 2>/dev/null &
_rp_a=$!
( p4b_barrier_claim "$_cp" && echo win ) >"$WORK/reap-b" 2>/dev/null &
_rp_b=$!
wait "$_rp_a" || true
wait "$_rp_b" || true
_wins="$(cat "$WORK/reap-a" "$WORK/reap-b" 2>/dev/null | grep -c win || true)"
[ "${_wins:-0}" = "1" ] || bad="$bad takeover-wins=$_wins"
rm -rf "$_cp"
( P4B_CLAIM_DIR=/dev/null/nope p4b_barrier_claim "$(P4B_CLAIM_DIR=/dev/null/nope p4b_barrier_claim_path o/r 1 h trigger)" ) \
  && bad="$bad unusable-dir-claimed"
if [ -z "$bad" ]; then
  pass "#846: claim is single-winner and PID-owned; only the next claimant breaks a dead owner; clear_pending leaves live claims"
else
  fail "#846: claim primitives wrong:$bad"
fi

# #859: the recorded owner must be the process INSIDE the claimed region, not
# `$$`. Every caller reaches the write core through `out="$(...)"`, so the
# region runs in a command substitution — and `$$` does not change there.
# Driven exactly that way, through a substitution, so the assertion cannot pass
# by accident in the top-level shell.
bad=""
_cp="$(p4b_barrier_claim_path owner/repo 98 ownhead trigger)"
rm -rf "$_cp"
_took="$( p4b_barrier_claim "$_cp" && printf ok )"
[ "$_took" = ok ] || bad="$bad substitution-claim-failed"
_owner="$(cat "$_cp/pid" 2>/dev/null || true)"
# On origin/main this recorded $$ — the parent, which is still alive here, so
# the claim read as held and no later claimant could EVER reap it.
[ -n "$_owner" ] && [ "$_owner" != "$$" ] || bad="$bad owner-is-parent"
p4b_barrier_claim "$_cp" || bad="$bad exited-region-not-reclaimable"
rm -rf "$_cp"
# ...and release is ownership-aware: a claim owned by somebody else is a
# successor's LIVE reservation, and deleting it is the double-post this whole
# mechanism exists to prevent (origin/main deleted it).
mkdir -p "$_cp"; printf '999999\n' >"$_cp/pid"
p4b_barrier_release "$_cp"
[ -d "$_cp" ] || bad="$bad foreign-claim-released"
rm -rf "$_cp"
# The winner still releases its own.
p4b_barrier_claim "$_cp" || bad="$bad own-claim-failed"
p4b_barrier_release "$_cp"
[ ! -d "$_cp" ] || bad="$bad own-claim-not-released"
if [ -z "$bad" ]; then
  pass "#859: the claim owner is the process inside the region (not \$\$), and release only removes a claim this process owns"
else
  fail "#859: claim ownership wrong:$bad"
fi

# #858: the claim namespace is shared across checkouts. Two Phase 4b runs from
# two trusted checkouts have different P4B_ACCT_STATE_DIRs; on origin/main that
# gave them different claim directories, so both entered the region and BOTH
# posted. Real concurrent writers with a blocking `gh` stub, released together
# so the overlap is genuine rather than simulated ordering.
bad=""
mkdir -p "$WORK/xc-bin"
cat >"$WORK/xc-bin/gh" <<EOF
#!/bin/sh
printf 'read\\n' >>"$WORK/xc-reads.log"
n=0
while [ ! -e "$WORK/xc-go" ] && [ "\$n" -lt 100 ]; do sleep 0.1; n=\$((n+1)); done
echo "[]"
EOF
cat >"$WORK/xc-wrapper.sh" <<EOF
#!/bin/sh
printf 'WRITE\\n' >>"$WORK/xc-writes.log"
exit 0
EOF
chmod +x "$WORK/xc-bin/gh" "$WORK/xc-wrapper.sh"
: >"$WORK/xc-writes.log"
rm -rf "$WORK/xc-claims" "$WORK/xc-go"
_checkout() { # <state-dir> [key] [dry]
  (
    export P4B_ACCT_STATE_DIR="$1"
    export P4B_CLAIM_DIR="$WORK/xc-claims"
    export P4B_GH_AS_REVIEWER="$WORK/xc-wrapper.sh"
    export PATH="$WORK/xc-bin:$PATH"
    p4b_barrier_maybe_write trigger owner/repo 11 "${2:-xchead}" rev-bot "${3:-false}"
  )
}
# `grep -c` PRINTS 0 and exits 1 on no match, so a `|| printf 0` fallback emits
# "0\n0" — fine for a string compare, but this one feeds `-lt`.
_xc_reads() {
  local n
  n="$(grep -c read "$WORK/xc-reads.log" 2>/dev/null)" || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
# The library owns the claim-path spelling; asking it keeps a format change
# from surfacing here as a poll timeout blamed on the claim never appearing
# (CodeRabbit, round 2).
_xc_claim() { ( P4B_CLAIM_DIR="$WORK/xc-claims" p4b_barrier_claim_path owner/repo 11 xchead trigger ); }
_checkout "$WORK/xc-state-a" >"$WORK/xc-out-a" 2>/dev/null &
_xc_a=$!
_n=0
while [ ! -d "$(_xc_claim)" ] && [ "$_n" -lt 100 ]; do
  sleep 0.1; _n=$((_n+1))
done
[ -d "$(_xc_claim)" ] || bad="$bad shared-claim-never-observed"
_checkout "$WORK/xc-state-b" >"$WORK/xc-out-b" 2>/dev/null &
_xc_b=$!
wait "$_xc_b" || true
: >"$WORK/xc-go"
wait "$_xc_a" || true
_xc_n="$(grep -c '^WRITE' "$WORK/xc-writes.log" 2>/dev/null || true)"
[ "${_xc_n:-0}" = "1" ] || bad="$bad cross-checkout-writes=$_xc_n"
grep -q 'triggered' "$WORK/xc-out-a" || bad="$bad checkout-a-output"
grep -q 'trigger-claim-declined' "$WORK/xc-out-b" || bad="$bad checkout-b-output"
# A DRY run reserves nothing: it never posts, so a claim would only make a
# concurrent REAL run decline — and now that the root is shared (above) that
# rehearsal would be blocking a real Phase 4b in another checkout, which is
# exactly what #842's dry-run isolation forbids.
#
# Asserted while the dry run is INSIDE the region, because the claim is
# released on the way out: an after-the-fact directory check passes whether or
# not the claim was ever taken, which is how the first version of this
# assertion came back vacuous under mutation.
rm -rf "$WORK/xc-claims"; rm -f "$WORK/xc-go"; : >"$WORK/xc-writes.log"; : >"$WORK/xc-reads.log"
# The dry run enters the region first and parks in the gh stub. The real run on
# the SAME key follows: it either declines on a claim the rehearsal is holding,
# or reads the timeline itself. Both outcomes are observable before `go` is
# set, so the ordering is gated, never slept.
_checkout "$WORK/xc-state-a" dryhead true >"$WORK/xc-out-dry" 2>/dev/null &
_xc_d=$!
_n=0
while [ "$(_xc_reads)" -lt 1 ] && [ "$_n" -lt 100 ]; do sleep 0.1; _n=$((_n+1)); done
[ "$(_xc_reads)" -ge 1 ] || bad="$bad dry-never-entered-region"
_checkout "$WORK/xc-state-a" dryhead false >"$WORK/xc-out-real" 2>/dev/null &
_xc_r=$!
_n=0
while [ "$(_xc_reads)" -lt 2 ] && [ ! -s "$WORK/xc-out-real" ] && [ "$_n" -lt 100 ]; do
  sleep 0.1; _n=$((_n+1))
done
: >"$WORK/xc-go"
wait "$_xc_d" || true
wait "$_xc_r" || true
[ "$(cat "$WORK/xc-out-dry")" = "would-trigger" ] || bad="$bad dry-output=$(cat "$WORK/xc-out-dry")"
grep -q 'trigger-claim-declined' "$WORK/xc-out-real" && bad="$bad dry-blocked-a-real-run"
[ "$(grep -c '^WRITE' "$WORK/xc-writes.log" 2>/dev/null || true)" = "1" ] || bad="$bad dry-suppressed-the-write"
if [ -z "$bad" ]; then
  pass "#858: two checkouts contend for ONE claim and deliver exactly one write; a dry run reserves nothing"
else
  fail "#858: cross-checkout claim coordination wrong:$bad"
fi

# p4b_barrier_claim_root itself. Everything above pins P4B_CLAIM_DIR, which is
# the FIRST branch the function takes — so #858's actual change, the default
# root, had no coverage at all and a full revert of it left the suite green
# (CodeRabbit, round 1). Each branch is asserted directly here instead, in a
# subshell so the section's pinned override is restored afterwards.
#
# `mkdir -p` reads a relative root as cwd-relative, so a relative value in ANY
# of the three operator-supplied variables would put two invocations started
# from two directories on two different roots — the split #858 removes,
# arriving through an operator-supplied directory instead of through the
# default. Every branch must therefore be absolute, and every relative value
# must be IGNORED rather than anchored: anchoring at $PWD makes the root
# absolute without making it checkout-independent, which is the guarantee under
# test (Codex P2, round 2).
bad=""
_claim_root() ( unset P4B_CLAIM_DIR XDG_STATE_HOME; "$@" >/dev/null 2>&1; p4b_barrier_claim_root )
# Default: per-user, per-HOST, and independent of the checkout.
_r="$(_claim_root export XDG_STATE_HOME="$WORK/xdg-state")"
case "$_r" in
  "$WORK/xdg-state/mergepath/write-claims/"?*) ;;
  *) bad="$bad xdg-root=$_r" ;;
esac
# The host component is load-bearing: ownership is a PID, and PIDs are
# comparable only within one machine.
[ "$_r" != "$WORK/xdg-state/mergepath/write-claims/" ] || bad="$bad host-component-empty"
# HOME is the fallback anchor when XDG_STATE_HOME is unset.
_r="$(_claim_root export HOME="$WORK/fakehome")"
case "$_r" in
  "$WORK/fakehome/.local/state/mergepath/write-claims/"?*) ;;
  *) bad="$bad home-root=$_r" ;;
esac
# A RELATIVE XDG_STATE_HOME must be ignored, not joined — what the XDG base-
# directory spec requires of a reader, and what keeps the root absolute.
_r="$( ( unset P4B_CLAIM_DIR; XDG_STATE_HOME=relative-state HOME="$WORK/fakehome"; export XDG_STATE_HOME HOME; p4b_barrier_claim_root ) )"
case "$_r" in
  "$WORK/fakehome/.local/state/mergepath/write-claims/"?*) ;;
  *) bad="$bad relative-xdg-honoured=$_r" ;;
esac
# A relative OVERRIDE is ignored the same way, and the shared default decides.
# Two runs started from two directories must not disagree about the root; the
# fall-through direction is the safe one, because the shared root is MORE
# serialized than what the operator asked for, never less. Asserted from two
# different working directories so an anchored-at-$PWD implementation, which is
# absolute but still cwd-dependent, cannot pass.
_r="$( ( cd "$WORK" && P4B_CLAIM_DIR=rel-claims HOME="$WORK/fakehome" p4b_barrier_claim_root ) )"
_r2="$( ( cd / && P4B_CLAIM_DIR=rel-claims HOME="$WORK/fakehome" p4b_barrier_claim_root ) )"
[ "$_r" = "$_r2" ] || bad="$bad relative-override-cwd-dependent=$_r/$_r2"
case "$_r" in
  "$WORK/fakehome/.local/state/mergepath/write-claims/"?*) ;;
  *) bad="$bad relative-override-honoured=$_r" ;;
esac
# An absolute override chooses the BASE and nothing else. The host component is
# part of the claim namespace, not of the base, so it survives an override —
# point one at NFS without it and host B reads host A's live PID (Codex P2,
# round 3). The default root's host suffix is reused as the expected value, so
# this cannot pass by both sides being empty.
_host="${_r##*/}"
[ -n "$_host" ] || bad="$bad host-suffix-empty"
_r="$( P4B_CLAIM_DIR="$WORK/abs-claims" p4b_barrier_claim_root )"
[ "$_r" = "$WORK/abs-claims/$_host" ] || bad="$bad absolute-override=$_r"
# No home at all: fall back to today's per-checkout location rather than fail
# closed in a configuration that has always worked.
_r="$( ( unset P4B_CLAIM_DIR XDG_STATE_HOME HOME; P4B_ACCT_STATE_DIR="$WORK/nohome-state" p4b_barrier_claim_root ) )"
[ "$_r" = "$WORK/nohome-state/$_host" ] || bad="$bad homeless-root=$_r"
# ...and P4B_ACCT_STATE_DIR is operator-supplied too, so a relative one is
# ignored on that branch as well and the repo-root default decides. That
# default is absolute by construction (`cd -P` in p4b_repo_root), which is what
# keeps the last branch honest (CodeRabbit round 2, Codex P2 round 2).
# The expected value is computed from p4b_repo_root in the SAME subshell and
# compared whole, not pattern-matched: "some absolute path containing
# /.mergepath/" is satisfied by a wrong checkout root, so the loose form would
# not have measured the contract the comment above states (CodeRabbit, round 3).
_r="$( ( cd "$WORK" && unset P4B_CLAIM_DIR XDG_STATE_HOME HOME; P4B_ACCT_STATE_DIR=rel-state p4b_barrier_claim_root ) )"
[ "$_r" = "$(p4b_repo_root)/.mergepath/$_host" ] || bad="$bad homeless-relative-root=$_r"
# The repo slug is injective: two DISTINCT repos that a `/`→`-` flattening
# collapsed onto one slug must reach two different claim paths, or one run
# declines on the other repository's live claim under the now-shared root
# (Codex P2, round 2).
_p1="$( P4B_CLAIM_DIR="$WORK/abs-claims" p4b_barrier_claim_path foo-bar/baz 3 k trigger )"
_p2="$( P4B_CLAIM_DIR="$WORK/abs-claims" p4b_barrier_claim_path foo/bar-baz 3 k trigger )"
[ "$_p1" != "$_p2" ] || bad="$bad repo-slug-collision=$_p1"
# ...and case-canonical, because GitHub repository identity is case-insensitive:
# `--repo Owner/Repo` and `--repo owner/repo` name ONE repository and must
# reserve ONE claim, which on a case-sensitive filesystem they did not (Codex
# P2, round 3).
_p3="$( P4B_CLAIM_DIR="$WORK/abs-claims" p4b_barrier_claim_path Owner/Repo 3 k trigger )"
_p4="$( P4B_CLAIM_DIR="$WORK/abs-claims" p4b_barrier_claim_path owner/repo 3 k trigger )"
[ "$_p3" = "$_p4" ] || bad="$bad repo-case-split=$_p3/$_p4"
if [ -z "$bad" ]; then
  pass "#858: the claim root is per-user and absolute on every branch, host-scoped even under an override; every relative operator value is ignored; the repo slug is injective and case-canonical"
else
  fail "#858: claim root resolution wrong:$bad"
fi

# The claimed write core, end to end against stubs. The wrapper stub records
# one LINE per delivered write; the gh stub BLOCKS until told to go, which is
# what makes the concurrency test below deterministic on any runner — no
# fixed sleeps, every step gated on an observable file (Codex P2, round 1).
mkdir -p "$WORK/wp-bin" "$WORK/wp-state"
cat >"$WORK/wp-bin/gh" <<EOF
#!/bin/sh
if [ -e "$WORK/wp-hold" ]; then
  n=0
  while [ ! -e "$WORK/wp-go" ] && [ "\$n" -lt 100 ]; do sleep 0.1; n=\$((n+1)); done
fi
echo "[]"
EOF
cat >"$WORK/wp-wrapper.sh" <<EOF
#!/bin/sh
printf 'WRITE: %s\\n' "\$(printf '%s' "\$*" | tr '\\n' ' ')" >>"$WORK/wp-writes.log"
exit 0
EOF
chmod +x "$WORK/wp-bin/gh" "$WORK/wp-wrapper.sh"

_write() { # <kind> <key> [dry]
  (
    export P4B_ACCT_STATE_DIR="$WORK/wp-state"
    export P4B_CLAIM_DIR="$WORK/wp-claims"
    export P4B_GH_AS_REVIEWER="$WORK/wp-wrapper.sh"
    export PATH="$WORK/wp-bin:$PATH"
    p4b_barrier_maybe_write "$1" owner/repo 7 "$2" rev-bot "${3:-false}"
  )
}
# Ask the library for the path rather than re-spelling its format here
# (CodeRabbit, round 2): a hand-written copy turns a format change into a
# poll-loop timeout reported as "claim never observed", which names the wrong
# cause. p4b_barrier_claim_path owns the one spelling.
_wp_claim() { ( P4B_CLAIM_DIR="$WORK/wp-claims" p4b_barrier_claim_path owner/repo 7 "$1" "${2:-trigger}" ); }

# Two concurrent invocations on one head. A takes the claim and blocks inside
# the claimed region (the gh stub waits for wp-go); the test starts B only
# once A's claim is OBSERVABLY held, so B always loses; then A is released.
# Exactly one write is delivered and the loser names the claim.
bad=""
: >"$WORK/wp-writes.log"
rm -f "$WORK/wp-go"; : >"$WORK/wp-hold"
_write trigger race1 >"$WORK/wp-out-a" &
_wp_a=$!
_n=0
while [ ! -d "$(_wp_claim race1)" ] && [ "$_n" -lt 100 ]; do
  sleep 0.1; _n=$((_n+1))
done
[ -d "$(_wp_claim race1)" ] || bad="$bad claim-never-observed"
_write trigger race1 >"$WORK/wp-out-b" &
_wp_b=$!
wait "$_wp_b" || true
: >"$WORK/wp-go"
wait "$_wp_a" || true
rm -f "$WORK/wp-hold" "$WORK/wp-go"
_delivered="$(grep -c '^WRITE:' "$WORK/wp-writes.log" 2>/dev/null || true)"
[ "${_delivered:-0}" = "1" ] || bad="$bad delivered=$_delivered"
grep -q 'triggered' "$WORK/wp-out-a" || bad="$bad winner-output"
grep -q 'trigger-claim-declined' "$WORK/wp-out-b" || bad="$bad loser-output"
if [ -z "$bad" ]; then
  pass "#846: two concurrent write attempts deliver exactly one comment; the loser declines on the claim"
else
  fail "#846: concurrency wrong:$bad"
fi

# The same race for the RESUME class, across two DIFFERENT heads (Codex P1,
# round 1). This is the combination #862's per-head marker key made reachable:
# a bounded retry still running against the old head overlaps a run started
# after a push, both observe the SAME pause note, and neither can see the
# other's comment yet because it has not been posted. The marker scan cannot
# help here — it only counts writes that have landed — so mutual exclusion has
# to come from the claim, which means the claim is keyed on the pause note and
# not on the head. Head-scoping it delivers two resumes against the same note.
bad=""
: >"$WORK/wp-writes.log"
_paused_probe() { # <pause_id> <fresh_at>
  printf '{"probe":{"observed":"paused"},"review":{"id":%s,"fresh_at":"%s"}}' "$1" "$2"
}
_resume_bg() { # <head> <pause_id> <fresh_at> — the CROSS-HEAD race helper.
  (
    export P4B_ACCT_STATE_DIR="$WORK/wp-state"
    export P4B_CLAIM_DIR="$WORK/wp-claims"
    export P4B_GH_AS_REVIEWER="$WORK/wp-wrapper.sh"
    export PATH="$WORK/wp-bin:$PATH"
    p4b_barrier_maybe_resume owner/repo 7 "$1" rev-bot "$(_paused_probe "$2" "$3")" false
  )
}
rm -f "$WORK/wp-go"; : >"$WORK/wp-hold"
_resume_bg oldhead 771 2026-01-01T00:00:00Z >"$WORK/wp-out-r-old" &
_wp_a=$!
_n=0
while [ ! -d "$(_wp_claim pause-771 resume)" ] && [ "$_n" -lt 100 ]; do
  sleep 0.1; _n=$((_n+1))
done
[ -d "$(_wp_claim pause-771 resume)" ] || bad="$bad note-level-claim-never-observed"
# A head-scoped claim would leave this path free and let the second run in.
[ ! -d "$(_wp_claim pause-771-newhead resume)" ] || bad="$bad claim-was-head-scoped"
_resume_bg newhead 771 2026-01-01T00:00:00Z >"$WORK/wp-out-r-new" &
_wp_b=$!
wait "$_wp_b" || true
: >"$WORK/wp-go"
wait "$_wp_a" || true
rm -f "$WORK/wp-hold" "$WORK/wp-go"
_delivered="$(grep -c '^WRITE:' "$WORK/wp-writes.log" 2>/dev/null || true)"
[ "${_delivered:-0}" = "1" ] || bad="$bad delivered=$_delivered"
grep -q '^resumed$' "$WORK/wp-out-r-old" || bad="$bad winner-output=$(cat "$WORK/wp-out-r-old")"
grep -q 'resume-claim-declined' "$WORK/wp-out-r-new" || bad="$bad loser-output=$(cat "$WORK/wp-out-r-new")"
if [ -z "$bad" ]; then
  pass "#862/#846: two heads probing ONE pause note serialize on a note-level claim and deliver exactly one resume"
else
  fail "#862/#846: cross-head resume concurrency wrong:$bad"
fi

# Failure directions of the claimed core, each on a fresh head so claims and
# markers cannot leak between cases.
bad=""
# gh read failure: decline, deliver nothing, and release the claim so the next
# bounded retry can attempt again (over-spend is not traded for starvation).
printf '#!/bin/sh\nexit 1\n' >"$WORK/wp-bin/gh"
: >"$WORK/wp-writes.log"
[ "$(_write trigger rfail1)" = "trigger-read-failed" ] || bad="$bad read-fail-output"
[ ! -s "$WORK/wp-writes.log" ] || bad="$bad read-fail-delivered"
[ ! -d "$(_wp_claim rfail1)" ] || bad="$bad read-fail-claim-held"
# Post failure: reported as failed, claim released — the retry can re-post.
printf '#!/bin/sh\necho "[]"\n' >"$WORK/wp-bin/gh"
printf '#!/bin/sh\nexit 1\n' >"$WORK/wp-wrapper.sh"
[ "$(_write trigger pfail1)" = "trigger-failed" ] || bad="$bad post-fail-output"
[ ! -d "$(_wp_claim pfail1)" ] || bad="$bad post-fail-claim-held"
printf '#!/bin/sh\nprintf "WRITE: %%s\\n" "$(printf "%%s" "$*" | tr "\\n" " ")" >>"%s"\nexit 0\n' "$WORK/wp-writes.log" >"$WORK/wp-wrapper.sh"
chmod +x "$WORK/wp-wrapper.sh"
# Already spent: the timeline marker wins over everything, including dry-run.
cat >"$WORK/wp-bin/gh" <<EOF
#!/bin/sh
printf '[{"user":{"login":"rev-bot"},"body":"x $(p4b_barrier_marker trigger spent1)"}]\n'
EOF
chmod +x "$WORK/wp-bin/gh"
[ "$(_write trigger spent1)" = "already-trigger" ] || bad="$bad spent-output"
if [ -z "$bad" ]; then
  pass "#846: read failure, post failure and already-spent each decline without starving the head"
else
  fail "#846: failure directions wrong:$bad"
fi

# The resume path (#847): fires only on observed=paused WITH an identified
# pause note, posts `@<bot> resume` through the same wrapper, dedups per pause
# NOTE across heads — never on the head alone.
bad=""
printf '#!/bin/sh\necho "[]"\n' >"$WORK/wp-bin/gh"
chmod +x "$WORK/wp-bin/gh"
_resume() { # <probe_json> [dry] [head]
  (
    export P4B_ACCT_STATE_DIR="$WORK/wp-state"
    export P4B_CLAIM_DIR="$WORK/wp-claims"
    export P4B_GH_AS_REVIEWER="$WORK/wp-wrapper.sh"
    export PATH="$WORK/wp-bin:$PATH"
    p4b_barrier_maybe_resume owner/repo 7 "${3:-rhead1}" rev-bot "$1" "${2:-false}"
  )
}
# Two resume keys (#862 and its regression): the EXACT key is the note id plus
# the head, the FAMILY is every key for that note id. `_pj` defaults the note's
# fresh_at to 12:00:00Z and takes an override, because an in-place edit of one
# pause note is exactly a fresh_at that moves while the id does not.
_ek() { printf 'pause-%s-%s' "$1" "${2:-rhead1}"; }
_pj() { printf '{"probe":{"observed":"%s"},"review":{"id":%s,"fresh_at":"%s"}}' "$1" "$2" "${3:-2026-06-04T12:00:00Z}"; }
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj none 771)")" = "skipped" ]       || bad="$bad none-not-skipped"
[ "$(_resume "$(_pj rate_limit 771)")" = "skipped" ] || bad="$bad ratelimit-not-skipped"
[ "$(_resume '{"probe":{"observed":"paused"}}')" = "resume-unidentified" ]  || bad="$bad no-id-not-declined"
[ "$(_resume "$(_pj paused 771)" true)" = "would-resume" ] || bad="$bad dry-not-would"
[ ! -s "$WORK/wp-writes.log" ] || bad="$bad gated-cases-delivered"
[ "$(_resume "$(_pj paused 771)")" = "resumed" ] || bad="$bad paused-not-resumed"
grep -q 'resume' "$WORK/wp-writes.log" || bad="$bad resume-verb-missing"
grep -q 'review' "$WORK/wp-writes.log" && bad="$bad resume-posted-review"
# #862: a PRIOR episode's marked resume must not spend the current one. A new
# pause episode costs the bot new reviewed commits, so it arrives on a new
# HEAD, and CodeRabbit rewrites its one pause note rather than posting another
# — same comment id, fresh_at bumped past the resume that answered the last
# episode. Keyed on the id alone, that old marker was still on the timeline and
# the new episode returned `already-resumed` (measured on origin/main): a
# paused bot left paused until the bound escalated to a human, the one outcome
# the recovery exists to avoid. The old resume's bare first line does not
# rescue it either — its created_at predates the new note's fresh_at, so the
# interop arm excludes it too.
jq -n --arg m "$(p4b_barrier_marker resume "$(_ek 771 oldhead)")" \
  '[{user:{login:"rev-bot"},created_at:"2026-06-04T11:00:00Z",body:("@coderabbitai resume\n\n"+$m)}]' \
  >"$WORK/wp-comments.json"
printf '#!/bin/sh\ncat "%s"\n' "$WORK/wp-comments.json" >"$WORK/wp-bin/gh"
chmod +x "$WORK/wp-bin/gh"
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj paused 771)")" = "resumed" ] || bad="$bad stale-episode-suppressed"
# The cross-head half round 1 asked for, which is what keeps that recovery from
# firing on every Codex-forced push: the SAME standing note, unedited since our
# resume answered it, is still answered from a different head. Note the marker
# below sits on an `oldhead` key and the retry runs on `rhead1`. The command is
# NOT the first line in these two fixtures, deliberately: the bare interop arm
# matches only a first-line command, so putting it lower isolates the marker
# arm — with a realistic body, both arms fire and neither is being measured.
jq -n --arg m "$(p4b_barrier_marker resume "$(_ek 771 oldhead)")" \
  '[{user:{login:"rev-bot"},created_at:"2026-06-04T12:00:30Z",body:($m+"\n\n@coderabbitai resume")}]' \
  >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj paused 771)")" = "already-resumed" ] || bad="$bad standing-note-re-resumed"
[ ! -s "$WORK/wp-writes.log" ] || bad="$bad standing-note-delivered"
# The pre-#862 id-only marker spelling still counts, so the first run after
# this ships does not re-resume a PR that already carries one.
jq -n --arg m "$(p4b_barrier_marker resume pause-771)" \
  '[{user:{login:"rev-bot"},created_at:"2026-06-04T12:00:30Z",body:($m+"\n\n@coderabbitai resume")}]' \
  >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj paused 771)")" = "already-resumed" ] || bad="$bad legacy-marker-missed"
# ...and the OTHER direction, pinned because it is a decision rather than an
# oversight (Codex P2, round 2). A legacy marker OLDER than the note's current
# fresh_at does NOT count, so an in-place edit during the upgrade window buys
# one more resume. Exempting the legacy arm from the floor would suppress that
# resume — but a legacy marker carries no head and no episode, so the exemption
# is at-most-once-per-note-id-forever, which is #862's original defect: a note
# genuinely re-paused after the marker was written would never be answered and
# the bound would page a human. #862 ranks a missed resume above a duplicated
# one, so the floor stays and the duplicate is the priced side. Bounded at one
# per head, and only on a PR that straddles the upgrade.
jq -n --arg m "$(p4b_barrier_marker resume pause-771)" \
  '[{user:{login:"rev-bot"},created_at:"2026-06-04T11:59:00Z",body:($m+"\n\n@coderabbitai resume")}]' \
  >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj paused 771)")" = "resumed" ] || bad="$bad legacy-marker-exempted-from-floor"
# A spent pause note stays spent within its OWN episode — and note this
# marker's created_at TIES the note's fresh_at, which is why the family arm
# compares `>=` and not `>`: GitHub timestamps carry second precision, so our
# own resume can tie the note it answers, and a tie is an answer. A NEW pause
# note is still a fresh recovery, and a bare resume from coderabbit-wait.sh's
# own path INSIDE the episode is recognised (round-2 interop): two paths, one
# spent test.
jq -n --arg m "$(p4b_barrier_marker resume "$(_ek 771)")" --arg t "x $(p4b_barrier_marker trigger rhead1)" \
  '[{user:{login:"rev-bot"},created_at:"2026-06-04T12:00:00Z",body:("@coderabbitai resume\n\n"+$m)},
    {user:{login:"rev-bot"},created_at:"2026-06-04T11:00:00Z",body:$t}]' >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj paused 771)")" = "already-resumed" ] || bad="$bad pause-not-deduped"
[ "$(_resume "$(_pj paused 888)")" = "resumed" ] || bad="$bad new-pause-blocked"
[ -s "$WORK/wp-writes.log" ] || bad="$bad new-pause-not-delivered"
# coderabbit-wait.sh's markerless resume, created after the note's fresh_at.
jq -n '[{user:{login:"rev-bot"},created_at:"2026-06-04T12:30:00Z",body:"@coderabbitai resume"}]' >"$WORK/wp-comments.json"
printf '#!/bin/sh\ncat "%s"\n' "$WORK/wp-comments.json" >"$WORK/wp-bin/gh"
chmod +x "$WORK/wp-bin/gh"
: >"$WORK/wp-writes.log"
[ "$(_resume "$(_pj paused 999)")" = "already-resumed" ] || bad="$bad wait-resume-not-recognised"
[ ! -s "$WORK/wp-writes.log" ] || bad="$bad interop-delivered"
# ...and one posted under a DIFFERENT trusted identity (the authoring
# session's PAT vs this Phase 4b session's) counts too, per
# available_reviewers — while an identity outside the allowlist never does.
cat >"$WORK/wp-policy.yml" <<'EOF2'
available_reviewers:
  - other-rev
EOF2
jq -n '[{user:{login:"other-rev"},created_at:"2026-06-04T12:30:00Z",body:"@coderabbitai resume"}]' >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
_out="$( ( export MERGEPATH_REVIEW_POLICY_PATH="$WORK/wp-policy.yml"; _resume "$(_pj paused 555)" ) )"
[ "$_out" = "already-resumed" ] || bad="$bad other-identity-not-recognised"
jq -n '[{user:{login:"randomer"},created_at:"2026-06-04T12:30:00Z",body:"@coderabbitai resume"}]' >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
_out="$( ( export MERGEPATH_REVIEW_POLICY_PATH="$WORK/wp-policy.yml"; _resume "$(_pj paused 556)" ) )"
[ "$_out" = "resumed" ] || bad="$bad untrusted-identity-counted"
# A trusted reviewer resuming a DIFFERENT bot is not the CodeRabbit recovery.
jq -n '[{user:{login:"other-rev"},created_at:"2026-06-04T12:30:00Z",body:"@renovate resume"}]' >"$WORK/wp-comments.json"
: >"$WORK/wp-writes.log"
_out="$( ( export MERGEPATH_REVIEW_POLICY_PATH="$WORK/wp-policy.yml"; _resume "$(_pj paused 557)" ) )"
[ "$_out" = "resumed" ] || bad="$bad other-bot-counted"
if [ -z "$bad" ]; then
  pass "#847/#862: resume fires only on an identified pause, dedups per pause NOTE across heads, never on the trigger marker"
else
  fail "#847/#862: resume path wrong:$bad"
fi

# The DUAL of the #862 property, and the regression that shipped with this
# branch's first shape. `fresh_at` is max(created_at, updated_at) of the pause
# note — its EDIT time, not an episode identity. CodeRabbit edits ONE pause
# comment in place, and coderabbit-wait.sh documents the same for its summary
# ("a Finishing-Touches checkbox edit bumped it"), so any identity derived from
# fresh_at alone mints a brand-new episode on every such edit: the marker
# written for the previous one goes invisible, the bare arm cannot rescue it
# (our resume necessarily predates the newer edit), and the barrier posts
# again — once per edit, against the five-per-hour allowance the marker exists
# to conserve. Measured on the fresh_at-keyed shape: four retries against ONE
# note, THREE resumes delivered, every one of them reported `resumed` rather
# than `already-resume-duplicate`, so the duplicate surfacing could not see the
# class either.
#
# Real p4b_barrier_maybe_resume, a gh stub serving a timeline that the
# reviewer-wrapper stub APPENDS each posted resume to, one note id, one head,
# fresh_at advancing underneath: exactly one resume is delivered.
bad=""
echo '[]' >"$WORK/wp-comments.json"
printf '#!/bin/sh\ncat "%s"\n' "$WORK/wp-comments.json" >"$WORK/wp-bin/gh"
chmod +x "$WORK/wp-bin/gh"
cat >"$WORK/wp-wrapper.sh" <<EOF
#!/bin/sh
printf 'WRITE: %s\\n' "\$(printf '%s' "\$*" | tr '\\n' ' ')" >>"$WORK/wp-writes.log"
body=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--body" ]; then body="\$2"; break; fi
  shift
done
jq --arg b "\$body" '. + [{user:{login:"rev-bot"},created_at:"2026-06-04T12:00:10Z",body:\$b}]' \\
  "$WORK/wp-comments.json" >"$WORK/wp-comments.next" || exit 1
mv "$WORK/wp-comments.next" "$WORK/wp-comments.json"
exit 0
EOF
chmod +x "$WORK/wp-wrapper.sh"
: >"$WORK/wp-writes.log"
_seq=""
for _f in 2026-06-04T12:00:00Z 2026-06-04T12:00:00Z 2026-06-04T12:00:55Z 2026-06-04T12:01:50Z; do
  _seq="$_seq $(_resume "$(_pj paused 771 "$_f")")"
done
[ "$_seq" = " resumed already-resumed already-resumed already-resumed" ] || bad="$bad seq=$_seq"
_n="$(grep -c '^WRITE:' "$WORK/wp-writes.log" 2>/dev/null || true)"
[ "${_n:-0}" = "1" ] || bad="$bad delivered=$_n"
# ...while a genuinely NEW episode is still recovered: re-pausing costs the bot
# new reviewed commits, so the rewritten note arrives on a new head, and
# neither half of the marker arm answers it.
[ "$(_resume "$(_pj paused 771 2026-06-04T13:00:00Z)" false newhead)" = "resumed" ] \
  || bad="$bad new-episode-blocked"
_n="$(grep -c '^WRITE:' "$WORK/wp-writes.log" 2>/dev/null || true)"
[ "${_n:-0}" = "2" ] || bad="$bad new-episode-delivered=$_n"
if [ -z "$bad" ]; then
  pass "#862 dual: in-place edits of one pause note buy no second resume; a note rewritten on a new head still does"
else
  fail "#862 dual: in-episode resume dedup wrong:$bad"
fi
# Restore the non-appending wrapper for anything after this.
printf '#!/bin/sh\nprintf "WRITE: %%s\\n" "$(printf "%%s" "$*" | tr "\\n" " ")" >>"%s"\nexit 0\n' \
  "$WORK/wp-writes.log" >"$WORK/wp-wrapper.sh"
chmod +x "$WORK/wp-wrapper.sh"

# Composition: the barrier surfaces the resume outcome and keeps the trigger
# declined on paused (asking a refusing provider is still forbidden).
bad=""
out="$(_barrier 0 7 '{"head_sha":"abc123","probe":{"observed":"paused"},"review":{"id":771}}')" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad paused-rc"
printf '%s' "$out" | jq -e '.resume == "would-resume"' >/dev/null 2>&1 || bad="$bad paused-resume-field"
printf '%s' "$out" | jq -e '.trigger == "declined"' >/dev/null 2>&1 || bad="$bad paused-trigger"
out="$(_barrier 0 7 '{"head_sha":"abc123","probe":{"observed":"none"}}')" && rc=0 || rc=$?
printf '%s' "$out" | jq -e '.resume == "skipped"' >/dev/null 2>&1 || bad="$bad none-resume-field"
if [ -z "$bad" ]; then
  pass "#847: the barrier surfaces resume in its JSON and still declines the trigger on paused"
else
  fail "#847: barrier resume wiring wrong:$bad"
fi

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
