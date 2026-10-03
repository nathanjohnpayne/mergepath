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

# Focused lifecycle coverage (expected about 80s; adapter calls capped at 3s).
# This mode never mutation-tests lib.sh or enters the long legacy suite.
if [ "${1:-}" = --heartbeat-only ]; then
  exec bash "$ROOT/tests/test_phase_4b_heartbeat.sh"
fi

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }
for f in "$LIB" "$ORCH" "$AD_CODEX" "$AD_CLAUDE"; do
  [ -e "$f" ] || { echo "missing required path: $f" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-auto-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Machine-local advisory telemetry must stay inside this hermetic fixture.
export P4B_HEARTBEAT_DIR="$WORK/heartbeat-state"

export P4B_TEST_POSTED_REVIEW="$WORK/posted-review.json"
cat > "$WORK/clear-feedback.sh" <<'SH'
#!/usr/bin/env bash
if [ -s "$P4B_TEST_POSTED_REVIEW" ]; then
  jq '{feedback_policy:{},findings:[{kind:"review-body",review_id:1,body:.body,accounted:true}],missing:[]}' "$P4B_TEST_POSTED_REVIEW"
else
  printf '{"feedback_policy":{},"findings":[],"missing":[]}'
fi
SH
chmod +x "$WORK/clear-feedback.sh"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORK/clear-feedback.sh"

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
# Claude-side twin of fake-codex-approve-p2 (#1143): an APPROVED carrying a
# discretionary P2, so the Direction B run reaches the step-9 issue-filing path
# and the identity fences around it are actually exercised.
mk_fake fake-claude-approve-p2-usage \
  "jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P2\",\"path\":\"x.js\",\"line\":2,\"body\":\"should be handled under stricter policy\"}]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",usage:{input_tokens:120,output_tokens:30,total_tokens:150}}'"
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
# (#1143) node became a hard runtime dependency when the identity fence started
# running the shared contract parser on every enabled run. A shim that exits
# non-zero is a faithful stand-in here precisely because the orchestrator probes
# `node --version` rather than `command -v node` — an unrunnable node is as
# fatal as an absent one, and `command -v` could not tell them apart.
NO_NODE_DIR="$WORK/no-node-bin"
mkdir -p "$NO_NODE_DIR"
cat > "$NO_NODE_DIR/node" <<'SH'
#!/usr/bin/env bash
echo "node intentionally unavailable" >&2
exit 127
SH
chmod +x "$NO_NODE_DIR/node"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  if [ "${2:-}" = "--paginate" ] \
     && [ "${3:-}" = "repos/o/r/issues/131/comments" ] \
     && [ -n "${P4B_FAKE_COMMENTS_BEFORE:-}" ] \
     && [ -n "${P4B_FAKE_COMMENTS_AFTER:-}" ]; then
    count_file="${P4B_FAKE_COMMENTS_COUNT:?}"
    count=$(( $( [ -f "$count_file" ] && cat "$count_file" || echo 0 ) + 1 ))
    printf '%s\n' "$count" > "$count_file"
    switch_after="${P4B_FAKE_COMMENTS_SWITCH_AFTER:-1}"
    if [ "$count" -le "$switch_after" ]; then
      cat "$P4B_FAKE_COMMENTS_BEFORE"
    else
      cat "$P4B_FAKE_COMMENTS_AFTER"
    fi
    exit 0
  fi
  # #1598: an approval with no request-budget snapshot reads the request
  # generation it records. Serve P4B_FAKE_ISSUE_COMMENTS (default: no
  # requests); P4B_FAKE_ISSUE_COMMENTS_FAIL makes the read fail, and once the
# file P4B_FAKE_ISSUE_COMMENTS_SENTINEL exists P4B_FAKE_ISSUE_COMMENTS_AFTER
# is served instead.
  if [ "${2:-}" = "--paginate" ]; then
    case "${3:-}" in
      repos/o/r/issues/*/comments)
        [ -z "${P4B_FAKE_ISSUE_COMMENTS_FAIL:-}" ] || exit 1
        if [ -n "${P4B_FAKE_ISSUE_COMMENTS_SENTINEL:-}" ] && [ -e "$P4B_FAKE_ISSUE_COMMENTS_SENTINEL" ]; then
          [ -z "${P4B_FAKE_ISSUE_COMMENTS_FAIL_AFTER_SENTINEL:-}" ] || exit 1
          printf '%s\n' "${P4B_FAKE_ISSUE_COMMENTS_AFTER:-[]}"
          exit 0
        fi
        printf '%s\n' "${P4B_FAKE_ISSUE_COMMENTS:-[]}"
        exit 0
        ;;
    esac
  fi
  case "${2:-}" in
    repos/o/r/pulls/*)
      # #1143: the orchestrator now reads the PR body on EVERY run, not only
      # when --author is absent, so this fake has to serve one. The two reads
      # hit the same endpoint and are told apart by the --jq expression.
      # P4B_FAKE_PR_BODY_FILE serves an arbitrary body; otherwise a
      # contract-valid default naming P4B_FAKE_PR_BODY_AGENT (default claude).
      # A fixture that wants an INVALID body points the file knob at one — the
      # skip is declared per-fixture, never implied by a flag.
      for a in "$@"; do
        case "$a" in
          *'.head.sha'*'.base.sha'*)
            # Optional expected-base fence: one API response supplies both
            # refs, so the test can model a same-head base retarget without
            # conflating it with the legacy scalar head reads below.
            if [ -n "${P4B_FAKE_LIVE_PAIR_FAIL:-}" ]; then
              printf '{"message":"Not Found","status":"404"}\n'
              exit 1
            fi
            if [ -n "${P4B_FAKE_LIVE_PAIR_MALFORMED:-}" ]; then
              printf '%s\n' "${P4B_FAKE_LIVE_PAIR_MALFORMED}"
              exit 0
            fi
            pair_count_file="${P4B_FAKE_LIVE_PAIR_COUNT:-${TMPDIR:-/tmp}/p4b-fake-pair-count}"
            pair_count=$(( $( [ -f "$pair_count_file" ] && cat "$pair_count_file" || echo 0 ) + 1 ))
            printf '%s\n' "$pair_count" > "$pair_count_file"
            pair_head="${P4B_FAKE_LIVE_HEAD:-abc123}"
            pair_base="${P4B_FAKE_LIVE_BASE:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
            if [ -n "${P4B_FAKE_LIVE_BASE2:-}" ] \
               && [ "$pair_count" -ge "${P4B_FAKE_LIVE_BASE2_FROM:-2}" ]; then
              pair_base="$P4B_FAKE_LIVE_BASE2"
            fi
            printf '%s %s\n' "$pair_head" "$pair_base"
            exit 0
            ;;
          *'.body'*)
            # Body-read counter (#1143). The orchestrator reads the body up
            # front and again at each identity fence, so a case can serve a
            # DIFFERENT body from the Nth read on and simulate a PR-body edit
            # landing mid-run. Same shape as the P4B_FAKE_LIVE_HEAD2 head-drift
            # knob below; counting happens only when a case opts in with its
            # own counter file, so cases cannot leak into each other.
            bcnt=0
            if [ -n "${P4B_FAKE_PR_BODY_COUNT:-}" ]; then
              bcnt=$(( $( [ -f "$P4B_FAKE_PR_BODY_COUNT" ] && cat "$P4B_FAKE_PR_BODY_COUNT" || echo 0 ) + 1 ))
              printf '%s\n' "$bcnt" > "$P4B_FAKE_PR_BODY_COUNT"
            fi
            # P4B_FAKE_PR_BODY_FAIL fails EVERY read; _FAIL_FROM fails from the
            # Nth on. Both reproduce the #799 shape exactly: gh puts the JSON
            # ERROR BODY on stdout and exits nonzero, so a caller that inferred
            # failure from empty output would parse the error body.
            if [ -n "${P4B_FAKE_PR_BODY_FAIL:-}" ] \
               || { [ -n "${P4B_FAKE_PR_BODY_FAIL_FROM:-}" ] \
                    && [ "$bcnt" -ge "$P4B_FAKE_PR_BODY_FAIL_FROM" ]; }; then
              printf '{"message":"Not Found","status":"404"}\n'
              exit 1
            fi
            if [ -n "${P4B_FAKE_PR_BODY_FILE2:-}" ] \
               && [ "$bcnt" -ge "${P4B_FAKE_PR_BODY2_FROM:-2}" ]; then
              # Record that the EDITED body was actually served. A case whose
              # pass arm is "the run succeeded" cannot tell a working fence
              # from an edit that never happened, and the read counter alone
              # does not close that: the reads still occur when the swap point
              # is out of reach. This marker is the only evidence that the
              # second body reached the orchestrator.
              [ -z "${P4B_FAKE_PR_BODY_SWAPPED:-}" ] \
                || printf 'served\n' >> "$P4B_FAKE_PR_BODY_SWAPPED"
              cat "$P4B_FAKE_PR_BODY_FILE2"
              exit 0
            fi
            if [ -n "${P4B_FAKE_PR_BODY_FILE:-}" ]; then
              cat "$P4B_FAKE_PR_BODY_FILE"
            else
              printf 'Authoring-Agent: %s\n\n## Self-Review\n\n- ok.\n' \
                "${P4B_FAKE_PR_BODY_AGENT:-claude}"
            fi
            exit 0
            ;;
        esac
      done
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
    cp "${2:?}" "$P4B_TEST_POSTED_REVIEW"
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

# --- #1261 approval acknowledgment regression -------------------------------
# This stub is clear before posting and inventories the actual review payload
# afterwards. It also requires the production fingerprint encoding (including
# trailing newlines), so an acknowledgment of another body cannot pass.
cat > "$WORK/approval-accounting.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${P4B_ACK_REAL_GATE:-}" = true ]; then
  PATH="$P4B_ACK_GATE_BIN:$PATH" REVIEW_FEEDBACK_ACCOUNTING_CONFIG="$P4B_ACK_POLICY" \
    GH_TOKEN=fixture-token exec "$P4B_ACK_GATE_SCRIPT" "$@"
fi
if [ ! -s "$P4B_ACK_REVIEW" ]; then
  printf '{"feedback_policy":{},"findings":[],"missing":[]}'
  exit 0
fi
[ "${P4B_ACK_READ_FAIL:-}" != true ] || exit 2
if [ "${P4B_ACK_NOT_VISIBLE:-}" = true ]; then
  printf '{"feedback_policy":{},"findings":[],"missing":[]}'
  exit 0
fi
body_json=$(jq -c '.body' "$P4B_ACK_REVIEW")
[ "${P4B_ACK_EDIT_BODY:-}" != true ] || body_json=$(printf '%s' "$body_json" | jq -c '. + "\nEdited finding"')
fp=$(printf '%s' "$body_json" | shasum -a 256 | cut -c1-12)
token="[mergepath-review-ack: 1 $fp]"
accounted=false
if [ -s "$P4B_ACK_COMMENT" ]; then
  if jq -e --arg token "$token" '.body | startswith($token + "\n")' "$P4B_ACK_COMMENT" >/dev/null; then
    accounted=true
  fi
fi
kind=review-body
[ "${P4B_ACK_ARCHIVED_BODY:-}" != true ] || kind=review-body-archive
jq -n --arg kind "$kind" --argjson body "$body_json" --arg token "$token" --argjson accounted "$accounted" '
  {kind:$kind, review_id:1, commit_id:"abc123", tier:"p2", body:$body, ack_token:$token, accounted:$accounted} as $f
  | {feedback_policy:{},findings:[$f],missing:([$f] | map(select(.accounted == false)))}'
[ "$accounted" = true ]
SH
chmod +x "$WORK/approval-accounting.sh"
cat > "$WORK/approval-reviewer.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
endpoint=${4:?}
shift 4
while [ "$#" -gt 0 ]; do
  if [ "$1" = --input ]; then
    case "$endpoint" in
      */reviews)
        jq --arg submitted "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '. + {submitted_at:$submitted}' "$2" > "$P4B_ACK_REVIEW"
        printf '{"id":1,"commit_id":"abc123"}'
        ;;
      */comments)
        [ "${P4B_ACK_POST_FAIL:-}" != true ] || exit 1
        created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        [ "${P4B_ACK_SAME_SECOND:-}" != true ] || created=$(jq -r '.submitted_at' "$P4B_ACK_REVIEW")
        jq --arg created "$created" --arg login "$GH_AS_REVIEWER_IDENTITY" \
          '. + {id:2,created_at:$created,user:{login:$login}}' "$2" > "$P4B_ACK_COMMENT"
        printf '%s' "$GH_AS_REVIEWER_IDENTITY" > "$P4B_ACK_IDENTITY"
        printf '{"id":2}'
        ;;
      *) exit 64 ;;
    esac
    exit 0
  fi
  shift
done
exit 64
SH
chmod +x "$WORK/approval-reviewer.sh"

mkdir -p "$WORK/approval-accounting-bin"
cat > "$WORK/approval-accounting-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
endpoint=""
for arg in "$@"; do case "$arg" in repos/*) endpoint="$arg" ;; esac; done
case "$endpoint" in
  repos/o/r/pulls/1261/comments) printf '[]' ;;
  repos/o/r/pulls/1261/reviews)
    if [ -s "$P4B_ACK_REVIEW" ]; then
      jq '[. + {id:1,user:{login:"nathanpayne-codex"},state:"APPROVED"}]' "$P4B_ACK_REVIEW"
    else printf '[]'; fi
    ;;
  repos/o/r/issues/1261/comments)
    if [ -s "$P4B_ACK_COMMENT" ]; then jq '[.]' "$P4B_ACK_COMMENT"; else printf '[]'; fi
    ;;
  repos/o/r/pulls/1261)
    printf '{"head":{"repo":{"id":1}},"base":{"repo":{"id":1}}}' ;;
  *) echo "unexpected approval accounting endpoint: $endpoint" >&2; exit 2 ;;
esac
SH
chmod +x "$WORK/approval-accounting-bin/gh"

run_approval_ack_case() {
  local scenario="$1" adapter="$2" author="$3"; shift 3
  local -a extra_args=()
  [ "$scenario" != dry-run ] || extra_args=(--dry-run)
  P4B_ACK_CASE="$WORK/approval-ack-$scenario"
  mkdir -p "$P4B_ACK_CASE"
  set +e
  out=$(env PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
    MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORK/approval-accounting.sh" \
    CODEX_BIN="$BIN/$adapter" CLAUDE_BIN="$BIN/$adapter" \
    P4B_FAKE_PR_BODY_AGENT="$author" \
    P4B_GH_AS_REVIEWER="$WORK/approval-reviewer.sh" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
    P4B_ISSUE_LOG="$P4B_ACK_CASE/issues" P4B_ACCT_STATE_DIR="$P4B_ACK_CASE/accounting" \
    P4B_ACK_REVIEW="$P4B_ACK_CASE/review.json" P4B_ACK_COMMENT="$P4B_ACK_CASE/comment.json" \
    P4B_ACK_IDENTITY="$P4B_ACK_CASE/identity" P4B_ACK_POLICY="$POLICY_ON" \
    P4B_ACK_GATE_BIN="$WORK/approval-accounting-bin" \
    P4B_ACK_GATE_SCRIPT="$ROOT/scripts/review-feedback-accounting.sh" "$@" \
    bash "$ORCH" 1261 --repo o/r --author "$author" --head abc123 --diff-file "$DIFF" ${extra_args[@]+"${extra_args[@]}"} \
    2>"$P4B_ACK_CASE/stderr")
  rc=$?
  set -e
}

run_approval_ack_case approved fake-codex-approve-p2 claude
if [ "$rc" = 0 ] && [ -s "$P4B_ACK_CASE/comment.json" ] \
   && [ "$(cat "$P4B_ACK_CASE/identity")" = nathanpayne-codex ] \
   && grep -q 'issue create' "$P4B_ACK_CASE/issues"; then
  pass "#1261: an approved advisory review is acknowledged under its reviewer identity after issue filing"
else
  fail "#1261: approval leaves an accounting obligation (rc=$rc; $out)"
fi

run_approval_ack_case changes fake-claude-changes codex
if [ "$rc" = 1 ] && [ -s "$P4B_ACK_CASE/review.json" ] && [ ! -e "$P4B_ACK_CASE/comment.json" ]; then
  pass "#1261: CHANGES_REQUESTED findings are never automatically acknowledged"
else fail "#1261: changes-requested review was acknowledged (rc=$rc; $out)"; fi

for failure in POST_FAIL READ_FAIL EDIT_BODY NOT_VISIBLE ARCHIVED_BODY; do
  run_approval_ack_case "$failure" fake-codex-approve-p2 claude "P4B_ACK_$failure=true"
  if [ "$rc" = 7 ] && printf '%s' "$out" | jq -e '.review_posted == true and .review_acknowledgment == "failed"' >/dev/null; then
    pass "#1261: $failure reports failure without erasing the posted approval"
  else fail "#1261: $failure lost post-state or claimed success (rc=$rc; $out)"; fi
  if { [ "$failure" = EDIT_BODY ] || [ "$failure" = ARCHIVED_BODY ]; } && [ -e "$P4B_ACK_CASE/comment.json" ]; then
    fail "#1261: body changed after posting was acknowledged"
  fi
done
run_approval_ack_case dry-run fake-codex-approve-p2 claude
if [ "$rc" = 0 ] && [ ! -e "$P4B_ACK_CASE/comment.json" ] && [ ! -e "$P4B_ACK_CASE/review.json" ]; then
  pass "#1261: dry-run posts neither review nor acknowledgment"
else fail "#1261: dry-run wrote a review or acknowledgment (rc=$rc; $out)"; fi

run_approval_ack_case real-accounting fake-codex-approve-p2 claude P4B_ACK_REAL_GATE=true
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.review_acknowledgment == "accounted"' >/dev/null; then
  pass "#1261: real accounting accepts the exact body, reviewer identity and strictly later acknowledgment"
else fail "#1261: real accounting rejected the acknowledgment (rc=$rc; $out; $(cat "$P4B_ACK_CASE/stderr"))"; fi

run_approval_ack_case same-second fake-codex-approve-p2 claude P4B_ACK_REAL_GATE=true P4B_ACK_SAME_SECOND=true
if [ "$rc" = 7 ] && [ -s "$P4B_ACK_CASE/comment.json" ] \
   && printf '%s' "$out" | jq -e '.review_posted == true and .review_acknowledgment == "failed"' >/dev/null; then
  pass "#1261: a same-second acknowledgment cannot pass the existing accounting rule"
else fail "#1261: timestamp readback failed to enforce the accounting rule (rc=$rc; $out)"; fi

for policy in "$POLICY_P2_REQUIRED" "$POLICY_ADDRESS_ALL"; do
  run_approval_ack_case "strict-$(basename "$policy")" fake-codex-approve-p2 claude \
    P4B_ACK_REAL_GATE=true "P4B_ACK_POLICY=$policy"
  if [ "$rc" = 7 ] && [ ! -e "$P4B_ACK_CASE/comment.json" ] \
     && printf '%s' "$out" | jq -e '.review_posted == true and .review_acknowledgment == "failed"' >/dev/null; then
    pass "#1261: governing $(basename "$policy") refuses acknowledgment despite a locally discretionary P2"
  else fail "#1261: stricter governing policy was bypassed (rc=$rc; $out)"; fi
done

POLICY_P2_IGNORED="$WORK/approval-p2-ignored.yml"
cp "$POLICY_ON" "$POLICY_P2_IGNORED"
printf '\nfeedback_policy: {priorities: {p2: ignore}}\n' >> "$POLICY_P2_IGNORED"
run_approval_ack_case ignored-by-base fake-codex-approve-p2 claude \
  P4B_ACK_REAL_GATE=true "P4B_ACK_POLICY=$POLICY_P2_IGNORED"
if [ "$rc" = 0 ] && [ ! -e "$P4B_ACK_CASE/comment.json" ] \
   && printf '%s' "$out" | jq -e '.review_posted == true and .review_acknowledgment == "not-needed"' >/dev/null; then
  pass "#1261: governing ignore tier creates no acknowledgment obligation despite local issue filing"
else fail "#1261: ignored governing tier created an impossible repair (rc=$rc; $out)"; fi

# A freeform summary is not represented by the structured step-9 findings.
for structured in '[]' '[{"severity":"P2","path":"x.js","line":2,"body":"filed advisory"}]'; do
  verdict=$(jq -nc --argjson findings "$structured" '{verdict:"APPROVED",summary:"**P2** unfiled summary finding",findings:$findings}')
  mk_fake fake-summary-finding "printf '%s' '$verdict'"
  run_approval_ack_case "summary-$(printf '%s' "$structured" | jq length)" fake-summary-finding claude P4B_ACK_REAL_GATE=true
  if [ "$rc" = 7 ] && [ ! -e "$P4B_ACK_CASE/comment.json" ] \
     && printf '%s' "$out" | jq -e '.review_posted == true and .review_acknowledgment == "failed"' >/dev/null; then
    pass "#1261: summary finding outside $structured is not automatically acknowledged"
  else fail "#1261: summary finding bypassed step-9 evidence (rc=$rc; $out)"; fi
done
run_approval_ack_case summary-ignored fake-summary-finding claude \
  P4B_ACK_REAL_GATE=true "P4B_ACK_POLICY=$POLICY_P2_IGNORED"
if [ "$rc" = 0 ] && [ ! -e "$P4B_ACK_CASE/comment.json" ]; then
  pass "#1261: ignored summary markers create no acknowledgment obligation"
else fail "#1261: ignored summary marker invented an obligation (rc=$rc; $out)"; fi

# --- end #1261 approval acknowledgment regression ---------------------------

# ===========================================================================
echo "lib.sh — reviewer selection"
# ===========================================================================
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"
# shellcheck source=../scripts/phase-4b/lib.sh
. "$LIB"
# p4b_codex_timeout_determination uses the orchestrator's hard-required shaped
# scalar reader for its final live-head fence.
# shellcheck source=../scripts/lib/gh-api-scalar.sh
. "$ROOT/scripts/lib/gh-api-scalar.sh"

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
# (#1143) Every orchestrator case below reads the PR body, so the fake `gh`
# has to be reachable from all of them — not just the non-dry-run cases that
# already prefixed PATH by hand. $BIN holds only the fakes this suite injects
# (`gh` plus `fake-*` shims), so prepending it shadows nothing else.
export PATH="$BIN:$PATH"
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

# (#1143) node is a hard dependency ONLY from the enabled path inward. The
# disabled path is what every consumer runs, and it must stay dependency-free —
# if the probe ever drifts above the disabled/mode gates, this fails.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" PATH="$NO_NODE_DIR:$PATH" bash "$ORCH" 123 --repo o/r 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(printf '%s' "$out" | jq -r '.skipped')" = "true" ]; then
  pass "#1143: automation disabled → exit 5 even when node is unavailable"
else fail "#1143: disabled path must not require node (rc=$rc, out=$out)"; fi

# (#1143) On the ENABLED path node is required, and the failure must NAME it.
# Before the explicit probe this surfaced as a parser error from three frames
# deeper, on a host that satisfied every documented prerequisite.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" PATH="$NO_NODE_DIR:$PATH" \
  bash "$ORCH" 1150 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>&1)"; rc=$?
set -e
case "$out" in
  *"node is required"*)
    if [ "$rc" = 3 ]; then
      pass "#1143: an unrunnable node fails closed on the enabled path and names the dependency"
    else
      fail "#1143: node check named the dependency but exited $rc (expected 3): $out"
    fi ;;
  *) fail "#1143: missing node did not produce the named dependency error (rc=$rc): $out" ;;
esac

set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" bash "$ORCH" 123 --repo $'o/r\nextra' 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && printf '%s' "$out" | jq -e '.repo == "o/r\nextra"' >/dev/null; then
  pass "automation disabled JSON escapes control characters"
else fail "disabled path JSON escaping (rc=$rc, out=$out)"; fi

# #1046: the disabled-path skip JSON names its source as "config" so a
# forced run (below) is distinguishable from an ordinary configured skip.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" bash "$ORCH" 123 --repo o/r 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ "$(printf '%s' "$out" | jq -r '.enabled_via')" = "config" ]; then
  pass "#1046: an ordinary configured-disabled skip reports enabled_via=config"
else fail "#1046: disabled-skip enabled_via (rc=$rc, out=$out)"; fi

# #1046: --force-enabled runs the automation on a single PR even though
# phase_4b_automation.enabled is false in the policy file — no repo-wide
# config edit required. Mirrors the existing "Direction A" dry-run success
# case below, but starting from POLICY_OFF instead of POLICY_ON.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" CODEX_BIN="$BIN/fake-codex-approve" \
  bash "$ORCH" 123 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run --force-enabled 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.automation_enabled')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.enabled_via')" = "override" ]; then
  pass "#1046: --force-enabled runs automation on a disabled repo, enabled_via=override"
else fail "#1046: --force-enabled dry-run (rc=$rc): $out"; fi

# #1046: P4B_FORCE_ENABLED=1 is the env-var equivalent of --force-enabled.
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_FORCE_ENABLED=1 \
  bash "$ORCH" 123 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "APPROVED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.enabled_via')" = "override" ]; then
  pass "#1046: P4B_FORCE_ENABLED=1 is equivalent to --force-enabled"
else fail "#1046: P4B_FORCE_ENABLED=1 dry-run (rc=$rc): $out"; fi

# #1046: the override touches ONLY `enabled` — a repo whose `mode` is not
# `local` still defers to the manual handoff, force-enabled or not. Without
# this, --force-enabled would be a back door around the mode gate too.
POLICY_OFF_NONLOCAL_MODE="$WORK/policy-off-nonlocal-mode.yml"
cat > "$POLICY_OFF_NONLOCAL_MODE" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: false
  mode: cloud
YAML
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF_NONLOCAL_MODE" \
  bash "$ORCH" 123 --repo o/r --force-enabled 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] \
   && [ "$(printf '%s' "$out" | jq -r '.reason')" = "mode-not-local" ] \
   && [ "$(printf '%s' "$out" | jq -r '.automation_enabled')" = "true" ] \
   && [ "$(printf '%s' "$out" | jq -r '.enabled_via')" = "override" ]; then
  pass "#1046: --force-enabled overrides ONLY enabled; a non-local mode still defers to the manual handoff"
else fail "#1046: force-enabled + non-local mode (rc=$rc): $out"; fi

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
  P4B_FAKE_PR_BODY_AGENT=codex bash "$ORCH" 124 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.verdict')" = "CHANGES_REQUESTED" ] \
   && [ "$(printf '%s' "$out" | jq -r '.direction')" = "codex->claude" ] \
   && [ "$(printf '%s' "$out" | jq -r '.findings_count')" = "1" ]; then
  pass "Direction B (codex→claude) dry-run CHANGES_REQUESTED → exit 1"
else fail "Direction B (rc=$rc): $out"; fi

# #1186: a dry run makes the complete validated verdict available to the
# caller before any publication path. The fixture includes a finding and full
# normalized usage so a count/scalar-only summary cannot pass this assertion.
expected_verdict="$(CLAUDE_BIN="$BIN/fake-claude-approve-p2-usage" \
  bash "$AD_CLAUDE" --pr 127 --repo o/r --head abc123 --diff-file "$DIFF")"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CLAUDE_BIN="$BIN/fake-claude-approve-p2-usage" \
  P4B_FAKE_PR_BODY_AGENT=codex bash "$ORCH" 127 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && printf '%s' "$out" | jq -e --argjson expected "$expected_verdict" \
     '.dry_run == true and .validated_verdict == $expected' >/dev/null; then
  pass "#1186: dry-run final JSON preserves the complete validated verdict"
else fail "#1186: dry-run validated verdict (rc=$rc): $out"; fi

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
  P4B_FAKE_PR_BODY_AGENT=codex bash "$ORCH" 126 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = "true" ] \
   && [ "$(cat "$HANDOFF_LOG")" = "nathanpayne-claude o/r#126" ]; then
  pass "manual fallback handoff targets the selected Claude reviewer for codex-authored PRs"
else fail "claude fallback target (rc=$rc): $out"; fi

# ---------------------------------------------------------------------------
# #1143 — --author is cross-checked against the PR body, never a bypass of it
# ---------------------------------------------------------------------------
# #855 put the shared-contract check on the orchestrator, but only under
# `[ -z "$AUTHOR" ]`: the contract was enforced for callers that omitted
# --author and unenforced for callers that passed it. A caller that supplied
# the identity on the command line selected a reviewer off a body the required
# Self-Review gate would have rejected — and nothing ever compared the flag
# against the agent the body declares, so a caller could pair the PR with a
# reviewer the real authoring agent must not be paired with.
#
# These drive the orchestrator for real. Every case passes --author, because
# that is precisely the path that used to skip the check.
# A MISSING fixture and a malformed body refuse with the same contract message,
# so a typo'd path would make every refusal case below pass for the wrong
# reason. Require the fixture to EXIST (empty is a legitimate fixture — case
# (b) depends on it) and report a distinct, non-matching string when it does
# not, so the case falls to its catch-all `fail` instead of its pass arm.
p4b1143_fixture_ok() {  # <path-or-"">
  [ -z "$1" ] || [ -f "$1" ]
}

P4B1143_BODY="$WORK/p4b1143-body.md"
p4b1143_run() {  # p4b1143_run <body-file-or-""> <extra orchestrator args...>
  local bodyfile="$1"; shift
  local out rc=0
  if ! p4b1143_fixture_ok "$bodyfile"; then
    printf 'FIXTURE-MISSING %s' "$bodyfile"; return 0
  fi
  set +e
  out="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
    CLAUDE_BIN="$BIN/fake-claude-approve-usage" \
    P4B_FAKE_PR_BODY_FILE="$bodyfile" \
    bash "$ORCH" 1143 --repo o/r --head abc123 --diff-file "$DIFF" --dry-run "$@" 2>&1)"
  rc=$?
  set -e
  printf 'rc=%s %s' "$rc" "$out"
}

# The validator parses the author once, then the assignment below parses the
# same body a second time. Intercept only that INNER parser command, identified
# by its real script path and `--author` mode; node version checks and every
# other parser mode delegate untouched. This exercises the production caller
# without encoding incidental outer-node or validation-call counts.
P4B1143_NODE_DIR="$WORK/p4b1143-node-bin"
P4B1143_AUTHOR_PARSE_COUNT="$WORK/p4b1143-author-parse-count"
P4B1143_PARSER_PATH="$ROOT/scripts/lib/pr-body-contract.mjs"
mkdir -p "$P4B1143_NODE_DIR"
P4B1143_REAL_NODE="$(command -v node)"
cat > "$P4B1143_NODE_DIR/node" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$P4B1143_PARSER_PATH" ] && [ "${2:-}" = "--author" ]; then
  n=$(( $( [ -f "$P4B1143_AUTHOR_PARSE_COUNT" ] && cat "$P4B1143_AUTHOR_PARSE_COUNT" || echo 0 ) + 1 ))
  printf '%s\n' "$n" > "$P4B1143_AUTHOR_PARSE_COUNT"
  # The first --author parse belongs to pr_body_validate; the second belongs to
  # BODY_AUTHOR extraction and must retain the caller's infrastructure contract.
  [ "$n" -ne 2 ] || exit 124
fi
exec "$P4B1143_REAL_NODE" "$@"
SH
chmod +x "$P4B1143_NODE_DIR/node"
printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok.\n' > "$P4B1143_BODY"
rm -f "$P4B1143_AUTHOR_PARSE_COUNT"
set +e
out="$(PATH="$P4B1143_NODE_DIR:$PATH" \
  P4B1143_REAL_NODE="$P4B1143_REAL_NODE" P4B1143_PARSER_PATH="$P4B1143_PARSER_PATH" \
  P4B1143_AUTHOR_PARSE_COUNT="$P4B1143_AUTHOR_PARSE_COUNT" \
  MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  CLAUDE_BIN="$BIN/fake-claude-approve-usage" P4B_FAKE_PR_BODY_FILE="$P4B1143_BODY" \
  bash "$ORCH" 124 --repo o/r --author claude --head abc123 --diff-file "$DIFF" --dry-run 2>&1)"
rc=$?
set -e
if [ "$rc" = 3 ] \
   && [ "$(cat "$P4B1143_AUTHOR_PARSE_COUNT" 2>/dev/null || true)" = 2 ] \
   && printf '%s' "$out" | grep -Fq 'ERROR: could not parse Authoring-Agent from PR body (parser did not complete)'; then
  pass "#1395: second Authoring-Agent parser failure maps to infrastructure exit 3"
else
  fail "#1395: second Authoring-Agent parser failure must map to exit 3 (rc=$rc author-parses=$(cat "$P4B1143_AUTHOR_PARSE_COUNT" 2>/dev/null || true) out=$out)"
fi

# Every refusal below is discriminated on the ORCHESTRATOR's own p4b_die line,
# never on pr_body_validate's stderr chatter. The chatter is printed even when
# the status that carries it is discarded, so matching it proves only that the
# validator ran — measured: with `pr_body_validate || true` in place, an
# unknown-agent body still prints "unknown Authoring-Agent" while the run is
# actually refused by a different check. The die line is the reason of record.
P4B1143_CONTRACT_DIE="ERROR: PR body does not satisfy the Authoring-Agent contract"

# (a) The three body defects the contract exists to catch — an unknown agent,
#     a duplicate marker, a `## Self-Review` heading hidden in a code fence —
#     must all refuse even though --author names a real agent.
printf 'Authoring-Agent: nobody\n\n## Self-Review\n\n- ok.\n' > "$P4B1143_BODY"
got="$(p4b1143_run "$P4B1143_BODY" --author claude)"
case "$got" in
  rc=0*) fail "#1143: --author accepted an unknown Authoring-Agent: $got" ;;
  *"$P4B1143_CONTRACT_DIE"*) pass "#1143: --author does not bypass the unknown-agent check" ;;
  *) fail "#1143: unknown-agent body refused, but not by the contract: $got" ;;
esac

printf 'Authoring-Agent: claude\nAuthoring-Agent: codex\n\n## Self-Review\n\n- ok.\n' > "$P4B1143_BODY"
got="$(p4b1143_run "$P4B1143_BODY" --author claude)"
case "$got" in
  rc=0*) fail "#1143: --author accepted a duplicate Authoring-Agent marker: $got" ;;
  *"$P4B1143_CONTRACT_DIE"*) pass "#1143: --author does not bypass the duplicate-marker check" ;;
  *) fail "#1143: duplicate-marker body refused, but not by the contract: $got" ;;
esac

printf 'Authoring-Agent: claude\n\ntext\n\n```\n## Self-Review\n```\n' > "$P4B1143_BODY"
got="$(p4b1143_run "$P4B1143_BODY" --author claude)"
case "$got" in
  rc=0*) fail "#1143: --author accepted a fenced ## Self-Review heading: $got" ;;
  *"$P4B1143_CONTRACT_DIE"*) pass "#1143: --author does not bypass the fenced-heading check" ;;
  *) fail "#1143: fenced-heading body refused, but not by the contract: $got" ;;
esac

# (b) The EMPTY form. A PR body may legitimately be the empty string, and an
#     empty body carries no identity at all — it must refuse, not fall through
#     to the flag. A detector that only handles well-formed input is the
#     fail-open shape this fix exists to remove.
: > "$P4B1143_BODY"
got="$(p4b1143_run "$P4B1143_BODY" --author claude)"
case "$got" in
  rc=0*) fail "#1143: --author accepted an EMPTY PR body: $got" ;;
  *"$P4B1143_CONTRACT_DIE"*) pass "#1143: an empty PR body refuses even with --author" ;;
  *) fail "#1143: empty body refused, but not by the contract: $got" ;;
esac

# (c) The ABSENT form. The read itself fails: gh writes its JSON error body to
#     stdout and exits nonzero (#799). The run must refuse, and must not mine
#     the error body for an agent name.
got="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" P4B_FAKE_PR_BODY_FAIL=1 \
  p4b1143_run "" --author claude)"
case "$got" in
  rc=0*) fail "#1143: --author accepted an UNREADABLE PR body: $got" ;;
  *"$P4B1143_CONTRACT_DIE"*) pass "#1143: an unreadable PR body refuses even with --author" ;;
  *) fail "#1143: unreadable body refused, but not by the contract: $got" ;;
esac

# (d) The consistency check. A valid body that declares a DIFFERENT agent than
#     --author must fail closed rather than silently preferring the flag.
printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok.\n' > "$P4B1143_BODY"
got="$(p4b1143_run "$P4B1143_BODY" --author codex)"
case "$got" in
  rc=0*) fail "#1143: --author overrode a contradicting PR body: $got" ;;
  *"ERROR: --author 'codex' contradicts the PR body's Authoring-Agent 'claude'"*)
    pass "#1143: --author contradicting the body's Authoring-Agent fails closed" ;;
  *) fail "#1143: contradicting --author refused, but not by the cross-check: $got" ;;
esac

# (e) Not a blanket refusal, and not a spelling test: --author may name the
#     reviewer LOGIN form of the same agent. The comparison is on the
#     normalized agent, which is what actually selects the reviewer, so this
#     agrees and the run proceeds to its ordinary verdict.
got="$(p4b1143_run "$P4B1143_BODY" --author nathanpayne-CLAUDE)"
case "$got" in
  *contradicts*) fail "#1143: the login form of the same agent was read as a contradiction: $got" ;;
  rc=0*direction*) pass "#1143: --author in login/mixed-case form still agrees with the body" ;;
  *) fail "#1143: agreeing login-form --author did not complete: $got" ;;
esac

# (f) The body is the source of truth downstream, not the flag. An EMPTY
#     --author value is not a cross-check to skip AND not an identity to act
#     on: the body's agent is what selects the reviewer, so a codex-authored
#     body still routes to the claude reviewer.
printf 'Authoring-Agent: codex\n\n## Self-Review\n\n- ok.\n' > "$P4B1143_BODY"
got="$(p4b1143_run "$P4B1143_BODY" --author "")"
case "$got" in
  rc=0*'"direction": "codex->claude"'*) pass "#1143: the body's agent, not the flag, selects the reviewer" ;;
  *) fail "#1143: empty --author did not fall back to the body's agent: $got" ;;
esac

# ---------------------------------------------------------------------------
# #1143 round 2 — the body can disagree with ITSELF, later
# ---------------------------------------------------------------------------
# The up-front fence reads the body once, and the adapter run after it can last
# the configured timeout. A PR-body edit moves no sha, so every drift check
# between them — all of which compare heads — is blind to it. The attack: start
# against a body declaring `codex` (so the CLAUDE reviewer is selected), edit
# the body to `claude` while the adapter reasons, and collect a cross-agent
# APPROVED from nathanpayne-claude on a PR that now declares claude.
#
# These are REAL runs, not dry-runs: the fences guard the side effects, and a
# dry-run performs none. The reviewer wrapper is a guard stub that fails loudly,
# so a regression cannot quietly post a review from any of the refusal cases.
P4B1143R2_GUARD="$WORK/stub-rev-guard-1143.sh"
printf '#!/bin/sh\necho "REGRESSION: reviewer wrapper invoked from an identity-drift refusal" >&2\nexit 9\n' \
  > "$P4B1143R2_GUARD"
chmod +x "$P4B1143R2_GUARD"

P4B1143R2_BODY1="$WORK/p4b1143r2-body1.md"
P4B1143R2_BODY2="$WORK/p4b1143r2-body2.md"
printf 'Authoring-Agent: codex\n\n## Self-Review\n\n- ok.\n' > "$P4B1143R2_BODY1"

# p4b1143r2_run <pr> <codex-or-claude-fake> <switch-from> <reviewer-wrapper> [extra env VAR=VAL...]
# Runs for real against a codex-authored body (→ claude reviewer), with the
# body switching to $P4B1143R2_BODY2 from the <switch-from>'th body read.
# Body reads in a findings run are: 1 up-front, 2 pre-issue-filing, 3 pre-POST.
p4b1143r2_run() {
  local pr="$1" fake="$2" from="$3" revwrap="$4"; shift 4
  local out rc=0
  # Same fixture precondition as the round-1 runner, for the same reason: a
  # missing body file reads to the orchestrator as an empty one, and an empty
  # body refuses with a message these cases would happily match.
  if ! p4b1143_fixture_ok "$P4B1143R2_BODY1" || ! p4b1143_fixture_ok "$P4B1143R2_BODY2"; then
    printf 'FIXTURE-MISSING %s or %s' "$P4B1143R2_BODY1" "$P4B1143R2_BODY2"; return 0
  fi
  [ -x "$revwrap" ] || { printf 'REVIEWER-STUB-NOT-EXECUTABLE %s' "$revwrap"; return 0; }
  set +e
  out="$(env MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
    CLAUDE_BIN="$BIN/$fake" \
    OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
    P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
    P4B_GH_AS_REVIEWER="$revwrap" \
    P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$WORK/p4b1143r2-handoff.log" \
    P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
    P4B_ISSUE_LOG="$WORK/p4b1143r2-issues-${pr}.log" \
    P4B_FAKE_PR_BODY_FILE="$P4B1143R2_BODY1" \
    P4B_FAKE_PR_BODY_FILE2="$P4B1143R2_BODY2" \
    P4B_FAKE_PR_BODY2_FROM="$from" \
    P4B_FAKE_PR_BODY_COUNT="$WORK/p4b1143r2-count-${pr}" \
    P4B_FAKE_PR_BODY_SWAPPED="$WORK/p4b1143r2-swapped-${pr}" \
    "$@" \
    bash "$ORCH" "$pr" --repo o/r --head abc123 --diff-file "$DIFF" 2>&1)"
  rc=$?
  set -e
  printf 'rc=%s %s' "$rc" "$out"
}

# Counting, done so that a count which could not be TAKEN can never read as
# zero. Two distinct traps meet here:
#
#   1. `grep -c` exits 1 when the count is legitimately ZERO while still
#      printing "0", so `$(grep -c … || echo 0)` yields the two-line string
#      "0\n0" and every later `-eq` on it is a syntax error the `if` swallows
#      as false. `|| true` is therefore required, which means the STATUS
#      cannot be the guard either.
#   2. With the status unusable, "could not look" and "looked, found none"
#      are indistinguishable unless something else separates them. STDOUT
#      does: a real count is digits; grep absent, file absent and file
#      unreadable all produce empty stdout.
#
# So judge the stdout SHAPE and fail closed on anything else. Returning 0 for
# an unusable count would make the "filed nothing" assertion below pass for a
# run that filed plenty — the same swallowed-failure class as trap 1, one
# level up. `grep` is resolved through PATH on purpose: it is not at
# /usr/bin/grep on every platform (NixOS, minimal containers), and $BIN holds
# only this suite's `gh` and `fake-*` shims so it cannot be shadowed.
p4b1143r2_count() {  # <pattern> <file> -> digits on stdout, or rc 1
  local n
  n="$(grep -c "$1" "$2" 2>/dev/null || true)"
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$n"
}

# (g) The attack itself, caught at the FIRST approval-side effect. The body
#     flips to `claude` — the very agent selected as reviewer — before the
#     step-9 issues are filed. Nothing may be filed and nothing may post.
printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok.\n' > "$P4B1143R2_BODY2"
: > "$WORK/p4b1143r2-issues-1144.log"
got="$(p4b1143r2_run 1144 fake-claude-approve-p2-usage 2 "$P4B1143R2_GUARD")"
_filed="$(p4b1143r2_count '^ARGV gh issue create' "$WORK/p4b1143r2-issues-1144.log")" || _filed=""
case "$got" in
  rc=0*) fail "#1143: a mid-run Authoring-Agent flip to the reviewer's own agent still APPROVED: $got" ;;
  *"Authoring-Agent changed during review"*)
    if [ -z "$_filed" ]; then
      fail "#1143: could not count filed issues — this assertion proves nothing, do not read it as a pass"
    elif [ "$_filed" -eq 0 ]; then
      pass "#1143: identity drift before the first approval-side effect refuses and files nothing"
    else
      fail "#1143: refused the drift but filed $_filed post-review issue(s) anyway"
    fi ;;
  *) fail "#1143: mid-run identity drift refused, but not by the identity fence: $got" ;;
esac

# (h) Drift that lands AFTER filing is caught by the pre-POST fence, and this
#     run's filed issues are closed as superseded — the same cleanup the
#     head-drift path at that fence already performs.
: > "$WORK/p4b1143r2-issues-1145.log"
got="$(p4b1143r2_run 1145 fake-claude-approve-p2-usage 3 "$P4B1143R2_GUARD")"
_filed="$(p4b1143r2_count '^ARGV gh issue create' "$WORK/p4b1143r2-issues-1145.log")" || _filed=""
_closed="$(p4b1143r2_count '^CLOSE #' "$WORK/p4b1143r2-issues-1145.log")" || _closed=""
case "$got" in
  rc=0*) fail "#1143: identity drift in the pre-POST window still APPROVED: $got" ;;
  *"Authoring-Agent changed during review"*)
    if [ -z "$_filed" ] || [ -z "$_closed" ]; then
      fail "#1143: could not count filed/closed issues — this assertion proves nothing, do not read it as a pass"
    elif [ "$_filed" -gt 0 ] && [ "$_closed" -eq "$_filed" ]; then
      pass "#1143: identity drift at the pre-POST fence closes this run's $_filed filed issue(s) as superseded"
    else
      fail "#1143: pre-POST identity drift left orphans (filed=$_filed closed=$_closed)"
    fi ;;
  *) fail "#1143: pre-POST identity drift refused, but not by the identity fence: $got" ;;
esac

# (i) A findings-free APPROVED files no issues at all, so the pre-POST fence is
#     the ONLY thing between the adapter and the review. It must still catch the
#     drift — otherwise the whole guarantee rests on a path that only runs when
#     the reviewer happened to return findings.
got="$(p4b1143r2_run 1146 fake-claude-approve-usage 2 "$P4B1143R2_GUARD")"
case "$got" in
  rc=0*) fail "#1143: identity drift on a findings-free approval still APPROVED: $got" ;;
  *"Authoring-Agent changed during review"*)
    pass "#1143: identity drift is caught on a findings-free approval too" ;;
  *) fail "#1143: findings-free drift refused, but not by the identity fence: $got" ;;
esac

# (j) A body that stops satisfying the CONTRACT mid-run is drift as well, not
#     just a changed agent — the fence revalidates, it does not merely compare.
printf 'Authoring-Agent: codex\n\ntext\n\n```\n## Self-Review\n```\n' > "$P4B1143R2_BODY2"
got="$(p4b1143r2_run 1147 fake-claude-approve-usage 2 "$P4B1143R2_GUARD")"
case "$got" in
  rc=0*) fail "#1143: a body that stopped satisfying the contract mid-run still APPROVED: $got" ;;
  *"no longer satisfies the Authoring-Agent contract"*)
    pass "#1143: a mid-run contract break is drift, not just an agent change" ;;
  *) fail "#1143: mid-run contract break refused, but not by the identity fence: $got" ;;
esac

# (k) The ABSENT form, mid-run: the revalidating read itself fails. Unreadable
#     must be drift, never "unchanged" — the fail-open reading would let the
#     attack through by simply making the second read fail.
got="$(p4b1143r2_run 1148 fake-claude-approve-usage 99 "$P4B1143R2_GUARD" P4B_FAKE_PR_BODY_FAIL_FROM=2)"
case "$got" in
  rc=0*) fail "#1143: an unreadable revalidation read still APPROVED: $got" ;;
  *"no longer satisfies the Authoring-Agent contract"*)
    pass "#1143: an unreadable mid-run body read refuses instead of reading as unchanged" ;;
  *) fail "#1143: unreadable revalidation refused, but not by the identity fence: $got" ;;
esac

# (l) NOT a blanket refusal of every mid-run body edit. An edit that leaves the
#     identity alone — added prose, a fixed typo — still validates and still
#     declares the same agent, so the approval proceeds and posts. Without this,
#     the fence could be "refuse whenever the body bytes changed", which would
#     break the ordinary case of an author tidying their own description.
printf 'Authoring-Agent: codex\n\nSome prose added while the adapter ran.\n\n## Self-Review\n\n- ok.\n' \
  > "$P4B1143R2_BODY2"
P4B1143R2_POSTED="$WORK/p4b1143r2-posted-body.md"
rm -f "$P4B1143R2_POSTED"
got="$(p4b1143r2_run 1149 fake-claude-approve-usage 2 "$BIN/fake-gh-as-reviewer" \
  P4B_WRAPPER_LOG="$WORK/p4b1143r2-wrapper.log" P4B_WRAPPER_BODY="$P4B1143R2_POSTED")"
# This is the ONE case whose pass arm is "the run succeeded", so it is the one
# case a swap that never fired would satisfy vacuously: if the body never
# changed, of course nothing refused. Prove the edit landed by requiring the
# fake's own "I served the second body" marker.
#
# The read COUNTER is not sufficient evidence here, measured rather than
# assumed: mutation H3 moves the swap point out of reach, and the reads still
# happen — counter 2, marker absent — so a counter-based guard passed while the
# case proved nothing. The marker is written on the serving branch itself, so
# it cannot be satisfied by anything short of the edited body reaching the
# orchestrator.
case "$got" in
  rc=0*)
    if [ ! -s "$WORK/p4b1143r2-swapped-1149" ]; then
      fail "#1143: the edited body was never served — this assertion would pass vacuously"
    elif [ -s "$P4B1143R2_POSTED" ]; then
      pass "#1143: a mid-run body edit that leaves the identity alone still posts"
    else
      fail "#1143: identity-preserving edit exited 0 but posted nothing: $got"
    fi ;;
  *) fail "#1143: an identity-preserving mid-run body edit was refused: $got" ;;
esac

# (m) #1143 round 4 (Codex P2): the loop must already say not-posted before the
#     fallback can be interrupted. fall_back_to_manual runs the GitHub-backed
#     require_feedback_accounted BEFORE it marks the loop unposted, and that
#     gate exits on a transient read failure or on feedback that genuinely
#     arrived during the adapter run — leaving the loop log asserting that this
#     UNPOSTED review was posted, with its ledger stage still staged. A
#     persisted phantom approval is worse than the refusal itself.
#
#     Modelled exactly: a gate that passes at dispatch and fails at fallback.
#     The assertion is on durable local state, not on the exit code, because
#     the exit code is the same either way — it is the loop log that lies.
P4B1143R2_GATE="$WORK/acct-gate-flaky.sh"
cat > "$P4B1143R2_GATE" <<'SH'
#!/usr/bin/env bash
c="${P4B_FAKE_GATE_COUNT:?}"
n=$(( $( [ -f "$c" ] && cat "$c" || echo 0 ) + 1 ))
printf '%s\n' "$n" > "$c"
[ "$n" -le 1 ] || { echo "simulated accounting gate failure at fallback" >&2; exit 1; }
printf '{"posted":0,"accounted":0}\n'
SH
chmod +x "$P4B1143R2_GATE"

printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok.\n' > "$P4B1143R2_BODY2"
P4B1143R2_ACCT="$WORK/acct-1151"
rm -rf "$P4B1143R2_ACCT"
got="$(p4b1143r2_run 1151 fake-claude-approve-usage 2 "$P4B1143R2_GUARD" \
  P4B_ACCT_STATE_DIR="$P4B1143R2_ACCT" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$P4B1143R2_GATE" \
  P4B_FAKE_GATE_COUNT="$WORK/acct-gate-count-1151")"
_gate_calls="$(tail -1 "$WORK/acct-gate-count-1151" 2>/dev/null || true)"
_loop="$(find "$P4B1143R2_ACCT/phase-4b-loops" -name '*.jsonl' 2>/dev/null | head -n1)"
if [ -z "$_loop" ]; then
  fail "#1143: no loop log written — this assertion proves nothing (gate calls=${_gate_calls:-none}; got=$got)"
elif [ "${_gate_calls:-0}" -lt 2 ]; then
  fail "#1143: the fallback gate was never reached (calls=${_gate_calls:-0}) — the interruption this guards was not exercised"
elif jq -e -s 'last.loop.posted == "not-posted" and last.loop.fail_closed.happened == true' "$_loop" >/dev/null 2>&1 \
     && [ -z "$(find "$P4B1143R2_ACCT/phase-4b-pending" -type f 2>/dev/null)" ] \
     && [ ! -e "$P4B1143R2_ACCT/phase-4b-ledger.jsonl" ]; then
  pass "#1143: identity drift corrects the loop to not-posted before the fallback's feedback gate can interrupt"
else
  fail "#1143: a failing fallback gate left durable state claiming a posted approval (loop=$(cat "$_loop" 2>/dev/null); pending=$(find "$P4B1143R2_ACCT/phase-4b-pending" -type f 2>/dev/null | tr '\n' ' '); got=$got)"
fi

# (n) #1143 round 5 (CodeRabbit P1): getting the ORDER right does not help if
#     the corrected write can fail silently and then mark itself done.
#     p4b_acct_hook_mark_last_loop_unposted has four `return 1` paths (an
#     unresolvable log, an empty log, a failed jq rewrite, a failed mv), and
#     p4b_acct_mark_unposted used to swallow that, clear
#     P4B_ACCT_LOOP_RECORDED and return 0 regardless — after which the fence
#     set P4B_PRE_POST_ACCT_CLEANED=true and fall_back_to_manual skipped its
#     remaining attempt. Durable outcome: a `posted` loop record for a review
#     that never posted, i.e. exactly what the round-4 ordering fix exists to
#     prevent, reached through the correction's FAILURE path.
#
#     The flag now has to mean the property ("the loop no longer says posted"),
#     not a side effect of the setup ("we called the corrector") — the same
#     distinction that made the first case-(l) guard useless.
#
#     Both directions are asserted on DURABLE state, because a swallowed
#     failure leaves the exit path byte-identical; only the loop log and the
#     attempt count separate them.
FLAKY_JQ_DIR="$WORK/flaky-jq-bin"
mkdir -p "$FLAKY_JQ_DIR"
# Fails ONLY the unposted-loop rewrite, and only the first
# P4B_FAKE_JQ_FAIL_TIMES times. Every other jq call is delegated to the real
# binary, so nothing else in the orchestrator is perturbed.
#
# The signature is `-cs` AND `--arg reason` together. `--arg reason` alone is
# NOT unique — accounting.sh uses it in four places (the two prior-record
# aggregation fallbacks, and the fail-closed sub-object built inside
# p4b_acct_hook_record_loop) — and matching on it alone broke loop RECORDING
# instead of the correction, which the direction-2 assertion caught as "no loop
# log written". Only the rewrite at accounting.sh:1611 slurps with `-cs`.
#
# The real jq path is BAKED IN rather than passed through an env var, and the
# counter knob is treated as optional. Both because the adapter runs its CLI
# under a deliberately scrubbed child environment: an env-var indirection was
# unset there, the shim exited non-zero for the adapter's own jq calls, the
# adapter produced no valid verdict, and the run fell back on "invalid verdict"
# WITHOUT ever reaching the identity fence — a green-looking rc=4 that tested
# nothing. Measured, not guessed: a tracing shim showed the correction going
# through note_fallback's `-nc` path with no `-cs` call at all.
P4B1143R5_REAL_JQ="$(command -v jq)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'slurp=false; reason=false; prev=""\n'
  printf 'for a in "$@"; do\n'
  printf '  [ "$a" = "-cs" ] && slurp=true\n'
  printf '  if [ "$prev" = "--arg" ] && [ "$a" = "reason" ]; then reason=true; fi\n'
  printf '  prev="$a"\n'
  printf 'done\n'
  printf 'if [ "$slurp" = true ] && [ "$reason" = true ] && [ -n "${P4B_FAKE_JQ_COUNT:-}" ]; then\n'
  printf '  n=$(( $( [ -f "$P4B_FAKE_JQ_COUNT" ] && cat "$P4B_FAKE_JQ_COUNT" || echo 0 ) + 1 ))\n'
  printf '  printf "%%s\\n" "$n" > "$P4B_FAKE_JQ_COUNT"\n'
  printf '  if [ "$n" -le "${P4B_FAKE_JQ_FAIL_TIMES:-0}" ]; then\n'
  printf '    echo "simulated jq failure in the unposted-loop rewrite" >&2\n'
  printf '    exit 1\n'
  printf '  fi\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$P4B1143R5_REAL_JQ"
} > "$FLAKY_JQ_DIR/jq"
chmod +x "$FLAKY_JQ_DIR/jq"

p4b1143r5_case() {  # <pr> <fail-times> <expected-attempts> <label>
  local pr="$1" failtimes="$2" want="$3" label="$4"
  local acct="$WORK/acct-r5-$pr" cnt="$WORK/jqcount-$pr" got loop attempts
  rm -rf "$acct"; rm -f "$cnt"
  printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok.\n' > "$P4B1143R2_BODY2"
  got="$(p4b1143r2_run "$pr" fake-claude-approve-usage 2 "$P4B1143R2_GUARD" \
    P4B_ACCT_STATE_DIR="$acct" \
    PATH="$FLAKY_JQ_DIR:$PATH" \
    P4B_REAL_JQ="$P4B1143R5_REAL_JQ" \
    P4B_FAKE_JQ_COUNT="$cnt" \
    P4B_FAKE_JQ_FAIL_TIMES="$failtimes")"
  attempts="$(tail -1 "$cnt" 2>/dev/null || true)"
  case "$attempts" in ''|*[!0-9]*) attempts="" ;; esac
  loop="$(find "$acct/phase-4b-loops" -name '*.jsonl' 2>/dev/null | head -n1)"
  case "$got" in
    *"Authoring-Agent changed during review"*) : ;;
    *)
      # Without this the case can pass on a run that fell back for an entirely
      # different reason (an adapter that failed under the shimmed jq, say) and
      # never exercised the fence at all.
      fail "#1143: $label — the run did not refuse at the identity fence, so nothing here was exercised (got=$got)"
      return 0 ;;
  esac
  if [ -z "$loop" ]; then
    fail "#1143: $label — no loop log written; this assertion proves nothing (got=$got)"
  elif [ -z "$attempts" ]; then
    fail "#1143: $label — the rewrite was never attempted, so the shim never intercepted (got=$got)"
  elif [ "$attempts" != "$want" ]; then
    fail "#1143: $label — expected $want correction attempt(s), saw $attempts"
  elif ! jq -e -s 'last.loop.posted == "not-posted"' "$loop" >/dev/null 2>&1; then
    fail "#1143: $label — durable loop record still claims posted: $(cat "$loop" 2>/dev/null)"
  else
    pass "#1143: $label"
  fi
}

# Direction 1 — the correction lands on the first attempt: the flag is set and
# the fallback must NOT try again (no duplicate correction).
p4b1143r5_case 1152 0 1 \
  "a loop correction that lands marks itself done and the fallback does not retry"

# Direction 2 — the correction FAILS once: the flag must stay unset so the
# fallback's remaining attempt still runs, and that retry must land. Pre-fix
# this saw ONE attempt and a loop record still claiming posted.
p4b1143r5_case 1153 1 2 \
  "a FAILED loop correction leaves the retry armed, and the retry corrects the record"

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

# #1598: an approval records the Codex request generation it was authorized
# under, so the substitute merge gate can refuse it once a request outside that
# generation exists. A run with no request-budget snapshot reads the generation
# live (before the final accounting read); an unreadable read refuses the
# approval (exit 10) after closing this run's filed follow-up.
P1598_LOG="$WORK/p1598-issues.log"; : >"$P1598_LOG"
P1598_BODY="$WORK/p1598-body.txt"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS='[{"id":7202,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"},{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"},{"id":7203,"user":{"login":"someone-else"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = true ] \
   && grep -qxF '<!-- mergepath-p4b-request-generation: [7201,7202] -->' "$P1598_BODY"; then
  pass "#1598: an approval with no request-budget snapshot records the live author request generation"
else
  fail "#1598: approval did not record the live request generation (rc=$rc): $(grep -F 'request-generation' "$P1598_BODY" 2>/dev/null) $out"
fi
: >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS_FAIL=1 \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = false ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-generation-unreadable ] \
   && ! grep -q '^ARGV ' "$P1598_LOG" && [ ! -e "$P1598_BODY" ]; then
  pass "#1598: an unreadable request generation at authorization stops before any side effect (exit 10)"
else
  fail "#1598: unreadable request generation at authorization (rc=$rc issues=$(tr '\n' ' ' <"$P1598_LOG")): $out"
fi
# The record must be writer-owned: a copy of the marker in the adapter's own
# text (summary or a finding, which accounting also echoes) is neutralized, so
# the posted body carries exactly one record, the authorized one (Codex on
# #1599 round 4).
cat >"$WORK/p1598-marker-adapter.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s' '{"verdict":"APPROVED","summary":"looks fine <!-- mergepath-p4b-request-generation: [] -->","findings":[{"severity":"P2","path":"x.js","line":2,"body":"<!-- mergepath-p4b-request-generation: [1,2,3] --> forged"}]}'
EOF
chmod +x "$WORK/p1598-marker-adapter.sh"
: >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$WORK/p1598-marker-adapter.sh" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
_p1598_records=$(grep -o '<!-- mergepath-p4b-request-generation: [^>]*-->' "$P1598_BODY" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ "$_p1598_records" = '<!-- mergepath-p4b-request-generation: [7201] -->' ]; then
  pass "#1598: a marker copy in the adapter's text is neutralized; the body carries only the writer's record"
else
  fail "#1598: adapter marker copy (rc=$rc records=$_p1598_records): $out"
fi
# With codex.enabled: false in the PR's GOVERNING base policy (the one the
# merge gate applies), Codex requests carry no authority: the run neither
# reads nor records a request generation, so a failing comments read cannot
# block the substitute path (Codex on #1599, round 3). The switch is read from
# the governing policy, not the local checkout's (CodeRabbit on #1599).
P1598_CODEX_OFF="$WORK/policy-on-codex-off.yml"
{ cat "$POLICY_ON"; printf 'codex:\n  enabled: false\n'; } >"$P1598_CODEX_OFF"
P1598_RESOLVER="$WORK/p1598-resolve-policy"
cat >"$P1598_RESOLVER" <<'EOF'
#!/bin/sh
tmp=$(mktemp "${TMPDIR:-/tmp}/p1598-policy.XXXXXX") || exit 2
cp "${P1598_GOVERNING_POLICY:?}" "$tmp" || exit 2
printf '%s\n' "$tmp"
EOF
chmod +x "$P1598_RESOLVER"
: >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$P1598_CODEX_OFF" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  P4B_RESOLVE_BASE_POLICY="$P1598_RESOLVER" P1598_GOVERNING_POLICY="$P1598_CODEX_OFF" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS_FAIL=1 \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = true ] \
   && [ -s "$P1598_BODY" ] && ! grep -q 'mergepath-p4b-request-generation' "$P1598_BODY"; then
  pass "#1598: with Codex disabled the approval neither reads nor records a request generation"
else
  fail "#1598: Codex-disabled approval (rc=$rc record=$(grep -c 'mergepath-p4b-request-generation' "$P1598_BODY" 2>/dev/null)): $out"
fi
# The local checkout says Codex is disabled, but the governing base policy
# enables it: the gate will treat Codex requests as binding, so the run must
# still capture and record the request generation.
: >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$P1598_CODEX_OFF" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  P4B_RESOLVE_BASE_POLICY="$P1598_RESOLVER" P1598_GOVERNING_POLICY="$POLICY_ON" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && grep -qxF '<!-- mergepath-p4b-request-generation: [7201] -->' "$P1598_BODY"; then
  pass "#1598: a governing policy that enables Codex is followed even when the local checkout disables it"
else
  fail "#1598: governing-enabled, local-disabled (rc=$rc record=$(grep -o 'mergepath-p4b-request-generation: [^ ]*' "$P1598_BODY" 2>/dev/null)): $out"
fi
# The reverse split (Codex on #1599, round 5): the local checkout enables
# Codex, the governing policy disables it. A failing comments read must not
# block the run, because the gate ignores Codex requests there.
: >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  P4B_RESOLVE_BASE_POLICY="$P1598_RESOLVER" P1598_GOVERNING_POLICY="$P1598_CODEX_OFF" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS_FAIL=1 \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = true ] \
   && [ -s "$P1598_BODY" ] && ! grep -q 'mergepath-p4b-request-generation' "$P1598_BODY"; then
  pass "#1598: a governing policy that disables Codex is followed even when the local checkout enables it"
else
  fail "#1598: governing-disabled, local-enabled (rc=$rc): $out"
fi
# The full local x governing matrix, each with the comments read failing: the
# GOVERNING policy alone decides. Governing-disabled posts with no record,
# and governing-enabled refuses (exit 10) whatever the local checkout says.
for _gm in on:on on:off off:on off:off; do
  _gm_local=${_gm%%:*}; _gm_gov=${_gm#*:}
  [ "$_gm_local" = on ] && _gm_local_policy="$POLICY_ON" || _gm_local_policy="$P1598_CODEX_OFF"
  [ "$_gm_gov" = on ] && _gm_gov_policy="$POLICY_ON" || _gm_gov_policy="$P1598_CODEX_OFF"
  : >"$P1598_LOG"; rm -f "$P1598_BODY"
  set +e
  out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$_gm_local_policy" CODEX_BIN="$BIN/fake-codex-approve-p2" \
    P4B_RESOLVE_BASE_POLICY="$P1598_RESOLVER" P1598_GOVERNING_POLICY="$_gm_gov_policy" \
    OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
    P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
    P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
    P4B_FAKE_ISSUE_COMMENTS_FAIL=1 \
    bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
  set -e
  if [ "$_gm_gov" = off ]; then
    if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = true ] \
       && [ -s "$P1598_BODY" ] && ! grep -q 'mergepath-p4b-request-generation' "$P1598_BODY"; then
      pass "#1598 matrix local=$_gm_local governing=$_gm_gov: posts with no record despite the failed read"
    else
      fail "#1598 matrix local=$_gm_local governing=$_gm_gov (rc=$rc): $out"
    fi
  else
    if [ "$rc" = 10 ] && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-generation-unreadable ] \
       && [ ! -e "$P1598_BODY" ]; then
      pass "#1598 matrix local=$_gm_local governing=$_gm_gov: refuses (exit 10) on the failed read"
    else
      fail "#1598 matrix local=$_gm_local governing=$_gm_gov (rc=$rc): $out"
    fi
  fi
done
# A request that arrives AFTER authorization but before the writer boundary
# (here: while the adapter runs) was never reviewed. The writer's re-read sees
# the generation moved and refuses the approval (exit 10) after closing this
# run's follow-up, instead of recording the new request as covered.
P1598_SENTINEL="$WORK/p1598-adapter-ran"; rm -f "$P1598_SENTINEL"
cat >"$WORK/p1598-adapter.sh" <<EOF
#!/usr/bin/env bash
: >'$P1598_SENTINEL'
exec '$BIN/fake-codex-approve-p2' "\$@"
EOF
chmod +x "$WORK/p1598-adapter.sh"
: >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$WORK/p1598-adapter.sh" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
  P4B_FAKE_ISSUE_COMMENTS_AFTER='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"},{"id":7204,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:01:00Z","body":"@codex review"}]' \
  P4B_FAKE_ISSUE_COMMENTS_SENTINEL="$P1598_SENTINEL" \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] && [ -e "$P1598_SENTINEL" ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = false ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-generation-changed ] \
   && grep -q '^CLOSE #901$' "$P1598_LOG" && [ ! -e "$P1598_BODY" ]; then
  pass "#1598: a request arriving after authorization refuses the approval (exit 10), closing this run's follow-up"
else
  fail "#1598: request after authorization (rc=$rc adapter=$([ -e "$P1598_SENTINEL" ] && echo ran) issues=$(tr '\n' ' ' <"$P1598_LOG")): $out"
fi
# The same moved generation under a governing policy that disables Codex is
# not a refusal: the gate ignores Codex requests there.
rm -f "$P1598_SENTINEL"; : >"$P1598_LOG"; rm -f "$P1598_BODY"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$WORK/p1598-adapter.sh" \
  P4B_RESOLVE_BASE_POLICY="$P1598_RESOLVER" P1598_GOVERNING_POLICY="$P1598_CODEX_OFF" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
  P4B_FAKE_ISSUE_COMMENTS_AFTER='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"},{"id":7204,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:01:00Z","body":"@codex review"}]' \
  P4B_FAKE_ISSUE_COMMENTS_SENTINEL="$P1598_SENTINEL" \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ -e "$P1598_SENTINEL" ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = true ]; then
  pass "#1598: a moved request generation is not a refusal when the governing policy disables Codex"
else
  fail "#1598: moved generation under governing-disabled Codex (rc=$rc): $out"
fi
# G2 (already-cleared route): a request that lands DURING the final
# accounting read (accounting call 3) is not seen by the run, which posts.
# The posted record excludes it ([7201], not 7204), so the merge gate holds
# the approval (tests/test_codex_request_evidence.sh,
# request-during-final-accounting). This is the revised contract: the run
# publishes, and a fresh gate evaluation rejects the stale approval.
cat >"$WORK/p1598-acct-touch.sh" <<'EOF'
#!/usr/bin/env bash
n=0
[ ! -f "$P4B_TEST_ACCT_COUNT" ] || n=$(cat "$P4B_TEST_ACCT_COUNT")
n=$((n + 1)); printf '%s\n' "$n" >"$P4B_TEST_ACCT_COUNT"
[ "$n" -ne 3 ] || : >"$P4B_FAKE_ISSUE_COMMENTS_SENTINEL"
# Report like the default stub, so the post-POST acknowledgment (#1261) sees
# the posted review body as accounted.
if [ -s "${P4B_TEST_POSTED_REVIEW:-}" ]; then
  jq '{feedback_policy:{},findings:[{kind:"review-body",review_id:1,body:.body,accounted:true}],missing:[]}' "$P4B_TEST_POSTED_REVIEW"
else
  printf '{"feedback_policy":{},"findings":[],"missing":[]}\n'
fi
EOF
chmod +x "$WORK/p1598-acct-touch.sh"
rm -f "$P1598_SENTINEL" "$WORK/p1598-acct.count"; : >"$P1598_LOG"; rm -f "$P1598_BODY"; rm -f "$P4B_TEST_POSTED_REVIEW"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORK/p1598-acct-touch.sh" P4B_TEST_ACCT_COUNT="$WORK/p1598-acct.count" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
  P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
  P4B_FAKE_ISSUE_COMMENTS='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
  P4B_FAKE_ISSUE_COMMENTS_AFTER='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"},{"id":7204,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:01:00Z","body":"@codex review"}]' \
  P4B_FAKE_ISSUE_COMMENTS_SENTINEL="$P1598_SENTINEL" \
  bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ -e "$P1598_SENTINEL" ] && [ "$(cat "$WORK/p1598-acct.count" 2>/dev/null || echo 0)" -ge 3 ] \
   && [ "$(grep -o '<!-- mergepath-p4b-request-generation: [^>]*-->' "$P1598_BODY" 2>/dev/null)" = '<!-- mergepath-p4b-request-generation: [7201] -->' ]; then
  pass "#1598 G2: on the already-cleared route a request during final accounting is posted outside the record [7201]"
else
  fail "#1598 G2: already-cleared route, request during final accounting (rc=$rc record=$(grep -o 'mergepath-p4b-request-generation: [^ ]*' "$P1598_BODY" 2>/dev/null)): $out"
fi
# G3: the authorization read succeeds but the writer's re-read fails. With
# the governing policy enabling Codex (unresolvable here, which counts as
# enabled) the approval is refused (exit 10) after cleanup; with it disabling
# Codex the run posts.
for _g3 in enabled disabled; do
  rm -f "$P1598_SENTINEL"; : >"$P1598_LOG"; rm -f "$P1598_BODY"
  if [ "$_g3" = disabled ]; then _g3_resolver="$P1598_RESOLVER"; else _g3_resolver="$WORK/p1598-no-resolver"; fi
  set +e
  out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$WORK/p1598-adapter.sh" \
    P4B_RESOLVE_BASE_POLICY="$_g3_resolver" P1598_GOVERNING_POLICY="$P1598_CODEX_OFF" \
    OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$P1598_LOG" \
    P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WORK/p1598-wrapper.log" \
    P4B_WRAPPER_BODY="$P1598_BODY" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_CREATED_REVIEW_HEAD=abc123 \
    P4B_FAKE_ISSUE_COMMENTS='[{"id":7201,"user":{"login":"nathanjohnpayne"},"created_at":"2026-08-01T00:00:00Z","body":"@codex review"}]' \
    P4B_FAKE_ISSUE_COMMENTS_SENTINEL="$P1598_SENTINEL" P4B_FAKE_ISSUE_COMMENTS_FAIL_AFTER_SENTINEL=1 \
    bash "$ORCH" 134 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
  set -e
  if [ "$_g3" = enabled ]; then
    if [ "$rc" = 10 ] && [ -e "$P1598_SENTINEL" ] \
       && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-generation-unrecorded ] \
       && grep -q '^CLOSE #901$' "$P1598_LOG" && [ ! -e "$P1598_BODY" ]; then
      pass "#1598 G3: an unreadable writer re-read refuses the approval (exit 10) after cleanup when Codex governs"
    else
      fail "#1598 G3 governing-enabled (rc=$rc issues=$(tr '\n' ' ' <"$P1598_LOG")): $out"
    fi
  else
    if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = true ]; then
      pass "#1598 G3: an unreadable writer re-read does not refuse when the governing policy disables Codex"
    else
      fail "#1598 G3 governing-disabled (rc=$rc): $out"
    fi
  fi
done
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
if [ "$rc" = 10 ] \
   && [ "$(printf '%s' "$out" | jq -r '.infrastructure_error')" = true ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "head moved"; then
  pass "#674: head drift stops before issue filing with no stale-head authority"
else fail "#674 head-drift pre-check (rc=$rc): $out"; fi
[ ! -s "$DRIFT_ISSUE_LOG" ] \
  && pass "#674: no issues created for a drifted head" || fail "#674: issues created despite head drift"

# Keep the post-adapter pre-filing fence covered independently of the barrier's
# earlier head read: the barrier sees the reviewed head, then the next read
# observes drift before any post-review issue can be created.
PREFILE_DRIFT_ISSUE_LOG="$WORK/issue-prefile-drift.log"; : > "$PREFILE_DRIFT_ISSUE_LOG"
PREFILE_DRIFT_WRAPPER_LOG="$WORK/p4b674-prefile-drift-wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$PREFILE_DRIFT_ISSUE_LOG" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$PREFILE_DRIFT_WRAPPER_LOG" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_HEAD2=def456 P4B_FAKE_LIVE_HEAD2_FROM=2 \
  bash "$ORCH" 1371 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "refusing to file post-review issues" \
   && [ "$(cat "$PREFILE_DRIFT_ISSUE_LOG.headreads" 2>/dev/null || printf 0)" -ge 2 ] \
   && ! grep -q '^ARGV ' "$PREFILE_DRIFT_ISSUE_LOG" \
   && ! grep -q 'pulls/.*/reviews' "$PREFILE_DRIFT_WRAPPER_LOG" 2>/dev/null; then
  pass "#674: post-adapter pre-filing fence refuses head drift before any issue or review write"
else fail "#674 post-adapter pre-filing head fence (rc=$rc): $out"; fi

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
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_HEAD2=def456 P4B_FAKE_LIVE_HEAD2_FROM=3 \
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
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_HEAD2=def456 P4B_FAKE_LIVE_HEAD2_FROM=4 \
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
echo "orchestrator — optional expected-base fence (#1475)"
P4B_EXPECTED_BASE="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
P4B_MOVED_BASE="cccccccccccccccccccccccccccccccccccccccc"

# A matching captured base preserves the ordinary approval path.
WRAPPER_LOG="$WORK/base-fence-success-wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
  P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_BASE="$P4B_EXPECTED_BASE" \
  P4B_FAKE_LIVE_PAIR_COUNT="$WORK/base-fence-success.count" \
  bash "$ORCH" 14751 --repo o/r --author claude --head abc123 --expected-base-sha "$P4B_EXPECTED_BASE" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ -s "$WRAPPER_LOG" ] && [ "$(cat "$WORK/base-fence-success.count")" -ge 2 ]; then
  pass "expected base fence allows a coherent matching head/base pair"
else fail "expected base matching pair (rc=$rc, out=$out)"; fi

# The base can move while the adapter reasons without moving HEAD. The fence
# must refuse before filing any post-review observation or approval.
BASE_MOVE_EARLY_ISSUES="$WORK/base-fence-early-issues.log"
BASE_MOVE_EARLY_WRAPPER="$WORK/base-fence-early-wrapper.log"
: > "$BASE_MOVE_EARLY_ISSUES"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$BASE_MOVE_EARLY_ISSUES" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
  P4B_WRAPPER_LOG="$BASE_MOVE_EARLY_WRAPPER" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_BASE="$P4B_EXPECTED_BASE" \
  P4B_FAKE_LIVE_BASE2="$P4B_MOVED_BASE" P4B_FAKE_LIVE_BASE2_FROM=2 P4B_FAKE_LIVE_PAIR_COUNT="$WORK/base-fence-early.count" \
  bash "$ORCH" 14752 --repo o/r --author claude --head abc123 --expected-base-sha "$P4B_EXPECTED_BASE" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "PR base changed during review" \
   && [ ! -s "$BASE_MOVE_EARLY_ISSUES" ] && [ ! -e "$BASE_MOVE_EARLY_WRAPPER" ]; then
  pass "same-head base move during adapter work refuses before post-review filing"
else fail "early expected-base drift (rc=$rc, out=$out)"; fi

# A base move after filing but before the authority POST closes this run's
# just-created follow-up, matching the existing late-head-drift cleanup.
BASE_MOVE_LATE_ISSUES="$WORK/base-fence-late-issues.log"
BASE_MOVE_LATE_WRAPPER="$WORK/base-fence-late-wrapper.log"
: > "$BASE_MOVE_LATE_ISSUES"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve-p2" \
  OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat P4B_ISSUE_LOG="$BASE_MOVE_LATE_ISSUES" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
  P4B_WRAPPER_LOG="$BASE_MOVE_LATE_WRAPPER" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_BASE="$P4B_EXPECTED_BASE" \
  P4B_FAKE_LIVE_BASE2="$P4B_MOVED_BASE" P4B_FAKE_LIVE_BASE2_FROM=3 P4B_FAKE_LIVE_PAIR_COUNT="$WORK/base-fence-late.count" \
  bash "$ORCH" 14753 --repo o/r --author claude --head abc123 --expected-base-sha "$P4B_EXPECTED_BASE" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "PR base changed during review" \
   && grep -q '^ARGV ' "$BASE_MOVE_LATE_ISSUES" && grep -q '^CLOSE #901$' "$BASE_MOVE_LATE_ISSUES" \
   && [ ! -e "$BASE_MOVE_LATE_WRAPPER" ]; then
  pass "pre-POST base fence closes raced post-review follow-ups before refusing"
else fail "late expected-base drift cleanup (rc=$rc, out=$out)"; fi

for base_case in unreadable malformed; do
  case "$base_case" in
    unreadable) base_env=(P4B_FAKE_LIVE_PAIR_FAIL=1) ;;
    malformed)  base_env=(P4B_FAKE_LIVE_PAIR_MALFORMED='not-a-base-pair') ;;
  esac
  set +e
  out="$(env PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
    "${base_env[@]}" P4B_FAKE_LIVE_HEAD=abc123 \
    bash "$ORCH" 14754 --repo o/r --author claude --head abc123 --expected-base-sha "$P4B_EXPECTED_BASE" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
  set -e
  if [ "$rc" = 3 ] && [ -z "$out" ]; then
    pass "expected base fence fails closed when the live pair is $base_case"
  else fail "expected base $base_case pair (rc=$rc, out=$out)"; fi
done

set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  bash "$ORCH" 14756 --repo o/r --head abc123 --expected-base-sha '' --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 3 ] && [ -z "$out" ]; then
  pass "explicit empty expected-base argument fails validation instead of disabling the fence"
else fail "empty expected-base validation (rc=$rc, out=$out)"; fi

set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  bash "$ORCH" 14757 --repo o/r --head abc123 --expected-base-sha 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 3 ] && [ -z "$out" ]; then
  pass "missing expected-base argument fails validation instead of a shell shift error"
else fail "missing expected-base validation (rc=$rc, out=$out)"; fi

# Existing callers pass no base, so even an unreadable pair fixture must not
# add a new network dependency or change their approval behavior.
WRAPPER_LOG="$WORK/base-fence-absent-wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" \
  P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_PAIR_FAIL=1 \
  bash "$ORCH" 14755 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ -s "$WRAPPER_LOG" ]; then
  pass "absent expected-base flag preserves the head-only approval path"
else fail "absent expected-base compatibility (rc=$rc, out=$out)"; fi

WRAPPER_LOG="$WORK/wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_FAKE_LIVE_HEAD=def456 \
  bash "$ORCH" 127 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] \
   && [ "$(printf '%s' "$out" | jq -r '.infrastructure_error')" = "true" ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "head moved" \
   && [ ! -e "$WRAPPER_LOG" ]; then
  pass "live head drift before posting → authority stop, no review write"
else fail "stale-head guard (rc=$rc, out=$out, wrapper_log=$(test -e "$WRAPPER_LOG" && cat "$WRAPPER_LOG" || true))"; fi

# A findings-free approval has no issue-filing reads between the barrier and
# post_review. Make the barrier's first head read succeed, then drift on the
# second read so this case reaches the final pre-POST head fence directly.
NO_FINDINGS_DRIFT_LOG="$WORK/no-findings-prepost-drift.log"; : > "$NO_FINDINGS_DRIFT_LOG"
NO_FINDINGS_DRIFT_WRAPPER="$WORK/no-findings-prepost-drift-wrapper.log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_ISSUE_LOG="$NO_FINDINGS_DRIFT_LOG" P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$NO_FINDINGS_DRIFT_WRAPPER" \
  P4B_FAKE_LIVE_HEAD=abc123 P4B_FAKE_LIVE_HEAD2=def456 P4B_FAKE_LIVE_HEAD2_FROM=2 \
  bash "$ORCH" 1271 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -r '.reason' | grep -q "PR head changed during review" \
   && [ "$(cat "$NO_FINDINGS_DRIFT_LOG.headreads" 2>/dev/null || printf 0)" -ge 2 ] \
   && ! grep -q '^ARGV ' "$NO_FINDINGS_DRIFT_LOG" \
   && ! grep -q 'pulls/.*/reviews' "$NO_FINDINGS_DRIFT_WRAPPER" 2>/dev/null; then
  pass "findings-free post-adapter pre-POST fence refuses head drift before review write"
else fail "findings-free post-adapter pre-POST head fence (rc=$rc): $out"; fi

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
  P4B_FAKE_PR_BODY_AGENT=codex bash "$ORCH" 130 --repo o/r --author codex --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(printf '%s' "$out" | jq -r '.token_count')" = "150" ] \
   && [ "$(printf '%s' "$out" | jq -r '.usage_source')" = "claude-json-envelope" ] \
   && [ "$(printf '%s' "$out" | jq -r 'has("validated_verdict")')" = "false" ] \
   && jq -e '.commit_id == "abc123" and .event == "APPROVE"' "$WRAPPER_PAYLOAD" >/dev/null \
   && grep -q -- "Reviewer identity: \`nathanpayne-claude\`" "$WRAPPER_BODY" \
   && grep -q -- "Token usage: \`150\` tokens (source: \`claude-json-envelope\`)" "$WRAPPER_BODY"; then
  pass "posted approval retains token usage and omits dry-run-only verdict data"
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
  P4B_FAKE_PR_BODY_AGENT=codex bash "$ORCH" 133 --repo o/r --author codex --reviewer nathanpayne-codex --head abc123 --diff-file "$DIFF" --dry-run >/dev/null 2>&1; rc=$?
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
  P4B_FAKE_PR_BODY_AGENT=codex bash "$ORCH" 141 --repo o/r --author codex --head abc123 --diff-file "$DIFF" --dry-run 2>/dev/null)"; rc=$?
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
#
# `rate_limit` is the one adverse value that no longer says not-yet (#1178).
# It still does not OPEN — which is all the #875 precedence rule ever
# asserted — but it now carries its own class, because a refusal and a delay
# need different handling and only the composer can choose between them.
[ "$(_cr 7 '{"head_sha":"abc123","review":{"id":9988,"endpoint":"reviews","submitted_at":"2026-06-04T00:00:06Z"},"probe":{"observed":"rate_limit","context_state":"success","context_updated_at":"2026-06-04T00:00:07Z"}}')" = rate-limited ] \
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
# #1178. The probe's rate_limit is the PROBE-mode sibling of rc 5, and it must
# reach a decision the same way. Three properties of the classifier half:
#
# 1. It is its own class, never `not-yet`. The barrier can neither trigger on
#    rate_limit (should_trigger declines) nor reach the polling retry from
#    --probe, so the bounded wait it used to buy could not be satisfied by
#    anything the run was allowed to do.
[ "$(_cr 7 '{"head_sha":"abc123","probe":{"observed":"rate_limit"}}')" = rate-limited ] \
                                                         || bad="$bad rc7-ratelimit-bare"
# 2. NOT head-anchored, unlike the `reported` conjunction. A rate limit is
#    provider-level state, the same shape as a pause; head identity is the
#    composer's drift check to make, and an old probe payload with no
#    head_sha must not fall back to a wait that cannot end.
[ "$(_cr 7 '{"probe":{"observed":"rate_limit"}}')" = rate-limited ] \
                                                         || bad="$bad rc7-ratelimit-nohead"
[ "$(_cr 7 '{"head_sha":"old999","probe":{"observed":"rate_limit"}}')" = rate-limited ] \
                                                         || bad="$bad rc7-ratelimit-staleheadev"
# 3. It never opens the barrier on its own. `rate-limited` is not in the
#    reported / will-not-report / waived family, so the composition below is
#    the only thing that can turn it into an `open`.
case "$(_cr 7 '{"head_sha":"abc123","probe":{"observed":"rate_limit"}}')" in
  reported|will-not-report|waived) bad="$bad rc7-ratelimit-opens" ;;
esac
# The class is probe-shaped and must not leak into the polling rcs, whose own
# rate-limit contract (rc 5) is unchanged and asserted above.
[ "$(_cr 4 '{"head_sha":"abc123","probe":{"observed":"rate_limit"}}')" = not-yet ] \
                                                         || bad="$bad rc4-ratelimit-leak"
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

# #1085: Phase 4a's ordinary timeout must survive process/checkout boundaries
# without making an unrequested head look terminal. The durable evidence is an
# author-owned, exact-head PR comment bound to the author-owned trigger it
# timed out waiting on. This table is pure so malformed/forged/stale evidence
# is pinned independently of the live API reader below.
_p4a_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_p4a_old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
_p4a_author=nathanjohnpayne
_p4a_trigger_id=4101
_p4a_marker_id=4102
_p4a_marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$_p4a_head trigger_comment_id=$_p4a_trigger_id -->"
_p4a_old_marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$_p4a_old trigger_comment_id=$_p4a_trigger_id -->"
_p4a_comments() { # marker_body marker_author [include_trigger]
  jq -cn --arg marker "$1" --arg who "$2" --arg author "$_p4a_author" \
    --argjson include "${3:-true}" --argjson tid "$_p4a_trigger_id" \
    --argjson mid "$_p4a_marker_id" '
    ((if $include then [{id:$tid,user:{login:$author},body:"@codex review",created_at:"2026-08-30T00:00:00Z"}] else [] end)
     + [{id:$mid,user:{login:$who},body:$marker,created_at:"2026-08-30T00:15:00Z"}])'
}
_p4a_state() {
  local out
  out="$(codex_phase4a_timeout_marker_state "$1" "$_p4a_author" "$2" 2>/dev/null)" \
    || out='{"state":"missing-helper"}'
  printf '%s' "$out" | jq -r '.state // "invalid-json"' 2>/dev/null || printf 'invalid-json'
}

bad=""
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author")"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad current"
[ "$(_p4a_state "$_p4a_head" '[]')" = none ] || bad="$bad none"
_comments="$(jq -cn --arg who "$_p4a_author" --argjson id "$_p4a_trigger_id" \
  '[{id:$id,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:00:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = none ] || bad="$bad trigger-still-pending"
_comments="$(_p4a_comments "$_p4a_old_marker" "$_p4a_author")"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = stale ] || bad="$bad stale"
_comments="$(_p4a_comments "$_p4a_marker" someone-else)"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = none ] || bad="$bad forged-author"
_comments="$(_p4a_comments '<!-- mergepath-phase-4a-terminal:v2 provider=codex outcome=timeout head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=4101 -->' "$_p4a_author")"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad unknown-version"
_comments="$(_p4a_comments "quoted: $_p4a_marker" "$_p4a_author")"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = none ] || bad="$bad quoted"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" false)"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad missing-trigger"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c '.[0].user.login = "someone-else"')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad wrong-author-trigger"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c '.[0].body = "@codex review please"')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad nonexact-trigger"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c '.[0].created_at = "2026-08-30T00:20:00Z"')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad later-trigger"
_comments="$(jq -cn --argjson one "$(_p4a_comments "$_p4a_marker" "$_p4a_author")" '$one + [$one[1] + {id:4103}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad idempotent-duplicate"
# A later exact author trigger on the same unchanged head starts a new review
# attempt. The old timeout is truthful history, but it may no longer waive the
# provider while that newer attempt is in flight (#1085 follow-up).
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c --arg who "$_p4a_author" \
  '. + [{id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = superseded ] || bad="$bad later-trigger-did-not-supersede"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c --arg who "$_p4a_author" \
  '. + [{id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:15:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = superseded ] || bad="$bad same-second-later-trigger"
# A marker posted after trigger B still cannot waive B by referring back to A.
# Comparing only comments with ids greater than the marker misses this shape.
_p4a_late_marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$_p4a_head trigger_comment_id=4101 -->"
_comments="$(jq -cn --arg who "$_p4a_author" --arg marker "$_p4a_late_marker" '
  [{id:4101,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:00:00Z"},
   {id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"},
   {id:4104,user:{login:$who},body:$marker,created_at:"2026-08-30T00:30:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = superseded ] || bad="$bad earlier-new-trigger-did-not-supersede"
_comments="$(printf '%s' "$_comments" | jq -c 'reverse')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = superseded ] || bad="$bad api-order-changed-latest-trigger"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c \
  '. + [{id:4103,user:{login:"nathanpayne-codex"},body:"@codex review",created_at:"2026-08-30T00:16:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad reviewer-trigger-superseded"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c --arg who "$_p4a_author" \
  '. + [{id:4103,user:{login:$who},body:"@codex review please",created_at:"2026-08-30T00:16:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad nonexact-trigger-superseded"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c --arg who "$_p4a_author" \
  '. + [{id:4103,user:{login:$who},body:"@codex review\n",created_at:"2026-08-30T00:16:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad normalized-nonexact-trigger-superseded"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c --arg who "$_p4a_author" \
  '. + [{id:"bad",user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad malformed-trigger-metadata-ignored"
_p4a_new_marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$_p4a_head trigger_comment_id=4103 -->"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c \
  --arg who "$_p4a_author" --arg marker "$_p4a_new_marker" \
  '. + [{id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"},
        {id:4104,user:{login:$who},body:$marker,created_at:"2026-08-30T00:30:00Z"}]')"
_state="$(codex_phase4a_timeout_marker_state "$_p4a_head" "$_p4a_author" "$_comments")"
[ "$(printf '%s' "$_state" | jq -r '.state')" = current ] || bad="$bad replacement-marker-not-current"
[ "$(printf '%s' "$_state" | jq -r '.trigger_comment_id')" = 4103 ] || bad="$bad replacement-marker-wrong-trigger"
# A future-version marker with the same canonical field envelope can be
# scoped to its claimed head without understanding that version's semantics.
# It must remain fail-closed on the head it names, but must not permanently
# wedge every later head or override an independently valid current record.
_p4a_old_v2="<!-- mergepath-phase-4a-terminal:v2 provider=codex outcome=timeout head=$_p4a_old trigger_comment_id=$_p4a_trigger_id -->"
_comments="$(_p4a_comments "$_p4a_old_v2" "$_p4a_author")"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = stale ] || bad="$bad stale-future-version"
_comments="$(jq -cn \
  --argjson current "$(_p4a_comments "$_p4a_marker" "$_p4a_author")" \
  --arg old_v2 "$_p4a_old_v2" --arg who "$_p4a_author" \
  '$current + [{id:4103,user:{login:$who},body:$old_v2,created_at:"2026-08-29T00:15:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad stale-future-overrode-current"
_comments="$(jq -cn \
  --argjson current "$(_p4a_comments "$_p4a_marker" "$_p4a_author")" \
  --arg marker "<!-- mergepath-phase-4a-terminal:damaged -->" --arg who "$_p4a_author" \
  '$current + [{id:4103,user:{login:$who},body:$marker,created_at:"2026-08-29T00:15:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = current ] || bad="$bad damaged-history-overrode-current"
_comments="$(jq -cn \
  --argjson current "$(_p4a_comments "$_p4a_marker" "$_p4a_author")" \
  --arg head "$_p4a_head" --arg who "$_p4a_author" \
  '$current + [{id:4103,user:{login:$who},body:("<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=" + $head + " trigger_comment_id=4999 -->"),created_at:"2026-08-30T00:16:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad bad-binding-lost-to-current"
_comments="$(_p4a_comments "$_p4a_marker" "$_p4a_author" | jq -c \
  --arg who "$_p4a_author" --arg prefix "<!-- mergepath-phase-4a-terminal:" \
  '. + [{id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"},
        {id:4104,user:{login:$who},body:($prefix + "damaged -->"),created_at:"2026-08-30T00:17:00Z"}]')"
[ "$(_p4a_state "$_p4a_head" "$_comments")" = malformed ] || bad="$bad malformed-current-sibling-lost-to-superseded"
if [ -z "$bad" ]; then
  pass "#1085: Phase 4a timeout evidence is exact-head, author/trigger-bound, and fail-closed on malformed input"
else
  fail "#1085: Phase 4a timeout evidence classification wrong:$bad"
fi
unset -f _p4a_comments _p4a_state

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
cat >"$WORK/barrier-bin/gh" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = api ] || exit 99
shift
endpoint=${1:-}
[ "$endpoint" = --paginate ] && { shift; endpoint=${1:-}; }
# (#1143) The orchestrator reads the PR body on every run; the one orchestrator
# case that runs with this bin on PATH needs a contract-valid one. Barrier
# reads never carry a `.body` filter, so this cannot shadow them.
for a in "$@"; do
  case "$a" in
    *'.body'*) printf 'Authoring-Agent: claude\n\n## Self-Review\n\n- ok.\n'; exit 0 ;;
  esac
done
# `gh api ... --jq EXPR` applies EXPR to the response; emulate that so the
# fixtures below are documents, not per-expression answers.
jqexpr=""
prev=""
for a in "$@"; do
  [ "$prev" = --jq ] && jqexpr=$a
  prev=$a
done
emit() {
  if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -rc "$jqexpr"; else printf '%s\n' "$1"; fi
}
case "$endpoint" in
  repos/owner/repo/issues/7/comments)
    comments_json=${P4B_TEST_COMMENTS_JSON-[]}
    if [ -n "${P4B_TEST_COMMENTS_RACE_FILE:-}" ]; then
      cn=$(cat "$P4B_TEST_COMMENTS_RACE_FILE" 2>/dev/null || printf 0)
      cn=$((cn + 1)); printf '%s\n' "$cn" >"$P4B_TEST_COMMENTS_RACE_FILE"
      [ "$cn" -lt "${P4B_TEST_COMMENTS_FAIL_AFTER:-999}" ] || exit 42
      if [ "$cn" -ge "${P4B_TEST_COMMENTS_CHANGE_AFTER:-999}" ]; then
        comments_json=${P4B_TEST_COMMENTS_JSON_AFTER-$comments_json}
      fi
    fi
    [ "${P4B_TEST_COMMENTS_FAIL:-false}" != true ] || exit 42
    printf '%s\n' "$comments_json" ;;
  repos/owner/repo/issues/7/timeline)
    printf '%s\n' "${P4B_TEST_TIMELINE_JSON-[]}" ;;
  repos/owner/repo/compare/*)
    # #1335: the carry-forward's changed-file set, bound to the head by the
    # compare range. Content never matters (the fingerprint delegate is
    # stubbed); the failure and file-count knobs do.
    [ "${P4B_TEST_FILES_FAIL:-false}" != true ] || exit 42
    emit "$(jq -nc --argjson n "${P4B_TEST_COMPARE_COUNT:-1}" '{files: [range($n) | {filename: "scripts/x\(.).sh"}]}')" ;;
  repos/owner/repo/commits/*)
    # #1335: a commit's tree, for the CodeRabbit-config identity. The tree sha
    # IS the commit sha here, which keeps the per-commit config knob simple.
    [ "${P4B_TEST_CFG_FAIL:-false}" != true ] || exit 42
    sha=${endpoint##*/}
    emit "{\"commit\":{\"committer\":{\"date\":\"${P4B_TEST_COMMIT_DATE:-2026-09-26T00:00:00Z}\"},\"tree\":{\"sha\":\"$sha\"}}}" ;;
  repos/owner/repo/git/trees/*)
    # P4B_TEST_CFG_<tree> is the .coderabbit.yml blob at that commit
    # (default: the same blob everywhere; "none" = no config file).
    # P4B_TEST_CFG_MODE_<tree> is its git mode (default a regular file).
    tree=${endpoint##*/}
    eval "blob=\${P4B_TEST_CFG_$tree:-cfgsame}"
    eval "mode=\${P4B_TEST_CFG_MODE_$tree:-100644}"
    if [ "$blob" = none ]; then
      emit '{"tree":[{"path":"README.md","mode":"100644","type":"blob","sha":"r"}]}'
    else
      emit "{\"tree\":[{\"path\":\"README.md\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"r\"},{\"path\":\".coderabbit.yml\",\"mode\":\"$mode\",\"type\":\"blob\",\"sha\":\"$blob\"}]}"
    fi ;;
  repos/owner/repo/pulls/7|repos/o/r/pulls/814)
    head_sha=${P4B_TEST_LIVE_HEAD:-abc123}
    if [ -n "${P4B_TEST_HEAD_RACE_FILE:-}" ]; then
      hn=$(cat "$P4B_TEST_HEAD_RACE_FILE" 2>/dev/null || printf 0)
      hn=$((hn + 1)); printf '%s\n' "$hn" >"$P4B_TEST_HEAD_RACE_FILE"
      [ "$hn" -lt "${P4B_TEST_HEAD_RACE_AFTER:-1}" ] || head_sha=${P4B_TEST_LIVE_HEAD_AFTER:-def456}
    fi
    base_sha=${P4B_TEST_BASE_SHA:-3333333333333333333333333333333333333333}
    if [ -n "${P4B_TEST_BASE_RACE_FILE:-}" ]; then
      n=$(cat "$P4B_TEST_BASE_RACE_FILE" 2>/dev/null || printf 0)
      n=$((n + 1)); printf '%s\n' "$n" >"$P4B_TEST_BASE_RACE_FILE"
      [ "$n" -lt "${P4B_TEST_BASE_RACE_AFTER:-2}" ] \
        || base_sha=${P4B_TEST_BASE_SHA_AFTER:-4444444444444444444444444444444444444444}
    fi
    emit "{\"head\":{\"sha\":\"$head_sha\"},\"base\":{\"ref\":\"${P4B_TEST_BASE_REF:-main}\",\"sha\":\"$base_sha\",\"repo\":{\"default_branch\":\"${P4B_TEST_DEFAULT_BRANCH:-main}\"}}}" ;;
  *)
    printf '[]\n' ;;
esac
EOF
chmod +x "$WORK/barrier-bin/gh"
cat >"$WORK/barrier-bin/resolve-policy" <<'EOF'
#!/bin/sh
set -eu
default=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --default-config) default=$2; shift 2 ;;
    *) shift ;;
  esac
done
source_path="${P4B_TEST_BASE_POLICY_PATH:-$default}"
[ -r "$source_path" ] || exit 2
tmp=$(mktemp "${TMPDIR:-/tmp}/p4b-test-policy.XXXXXX")
cp "$source_path" "$tmp"
printf '%s\n' "$tmp"
EOF
chmod +x "$WORK/barrier-bin/resolve-policy"
# Every later orchestrator fixture inherits the same governing-policy shim.
# It materializes the fixture's own policy unless a test supplies a distinct
# base policy, matching the production resolver's ownership contract.
export P4B_RESOLVE_BASE_POLICY="$WORK/barrier-bin/resolve-policy"

# #1560 slice 3: the barrier reads the Codex review ledger only when a spent
# request ceiling would dispatch the adapter. This stub prints a ledger for the
# expected head; P4B_TEST_LEDGER_MODE picks its evidence. The suite default,
# `blocking`, spends the default blocking-review budget, so the pre-slice-3
# ceiling cases keep their human-tiebreaker meaning; the S3-4 cases below set
# the other modes.
cat >"$WORK/stub-ledger.sh" <<'EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  case "$1" in --expect-head) head=$2; shift 2 ;; --expect-policy) fp=$2; shift 2 ;; *) shift ;; esac
done
[ -z "${P4B_TEST_LEDGER_FP:-}" ] || fp=$P4B_TEST_LEDGER_FP
mode=${P4B_TEST_LEDGER_MODE:-blocking}
# bump: stays clear, but from its second read on it moves the comments
# counter past the switch point, as if a request landed during that read.
if [ "$mode" = bump ]; then
  n=0
  [ ! -f "$P4B_TEST_LEDGER_COUNT" ] || n=$(cat "$P4B_TEST_LEDGER_COUNT")
  printf '%s\n' "$((n + 1))" >"$P4B_TEST_LEDGER_COUNT"
  [ "$((n + 1))" -ne "${P4B_TEST_LEDGER_BUMP_AT:-2}" ] || printf '1000\n' >"$P4B_TEST_COMMENTS_RACE_FILE"
  mode=clear
fi
if [ "$mode" = flip ]; then
  n=0
  [ ! -f "$P4B_TEST_LEDGER_COUNT" ] || n=$(cat "$P4B_TEST_LEDGER_COUNT")
  printf '%s\n' "$((n + 1))" >"$P4B_TEST_LEDGER_COUNT"
  # Reads before P4B_TEST_LEDGER_FLIP_AT (default 2) are clear, later ones stop.
  if [ "$((n + 1))" -lt "${P4B_TEST_LEDGER_FLIP_AT:-2}" ]; then mode=clear; else mode=untested; fi
fi
resp() { # n class unsolicited path first_at [window]
  jq -nc --argjson n "$1" --arg c "$2" --argjson u "$3" --arg p "$4" --arg t "$5" --argjson w "${6:-1}" \
    '[range($n) | {rid: ("w" + (. | tostring)), window: $w, class: $c, unsolicited: $u, conflicting: false,
      first_at: $t, blocking_paths: (if $c == "blocking" then [$p] else [] end), blocking_unlocated: false}]'
}
# Requests: one before every rebuttal; disagreement adds one after it.
reqs='[{"id":1,"created_at":"2026-08-01T00:00:00Z","outcome":"attributed","responses":["w0"],"counted":true}]'
case "$mode" in
  blocking) r=$(resp 10 blocking false x.sh 2026-08-01T00:10:00Z); rb='[]' ;;
  clear) r=$(resp 1 blocking false x.sh 2026-08-01T00:10:00Z); rb='[]' ;;
  nine) r=$(resp 9 blocking false x.sh 2026-08-01T00:10:00Z); rb='[]' ;;
  two) r=$(jq -nc --argjson a "$(resp 1 blocking false x.sh 2026-08-01T00:10:00Z 1)" \
            --argjson b "$(resp 1 blocking false y.sh 2026-08-01T01:10:00Z 2)" '$a + $b'); rb='[]'
       reqs='[{"id":1,"created_at":"2026-08-01T00:00:00Z","outcome":"attributed","responses":["w0"],"counted":true},{"id":2,"created_at":"2026-08-01T01:00:00Z","outcome":"attributed","responses":["w0"],"counted":true}]' ;;
  untested) r=$(resp 1 blocking false x.sh 2026-08-01T00:10:00Z)
            rb='[{"finding":1,"path":"x.sh","at":"2026-08-01T01:00:00Z","sources":["tag"]}]' ;;
  disagreement) r=$(jq -nc --argjson a "$(resp 1 blocking false x.sh 2026-08-01T00:10:00Z 1)" \
                     --argjson b "$(resp 1 blocking false x.sh 2026-08-01T02:00:00Z 2)" '$a + $b')
                reqs='[{"id":1,"created_at":"2026-08-01T00:00:00Z","outcome":"attributed","responses":["w0"],"counted":true},{"id":2,"created_at":"2026-08-01T01:30:00Z","outcome":"attributed","responses":["w0"],"counted":true}]'
                rb='[{"finding":1,"path":"x.sh","at":"2026-08-01T01:00:00Z","sources":["thumbs-down"]}]' ;;
  fail) exit 3 ;;
  garbage) printf 'not a ledger\n'; exit 0 ;;
  other-head) head=0000000000000000000000000000000000000000; r='[]'; rb='[]' ;;
esac
jq -nc --arg h "$head" --argjson r "$r" --argjson rb "$rb" --argjson m "${P4B_TEST_LEDGER_MAX:-10}" --arg fp "${fp:-}" \
  --argjson q "$reqs" \
  '{head_sha: $h, author: "nathanjohnpayne", max_blocking_reviews: $m, policy_fingerprint: $fp, requests: $q, responses: $r, rebuttals: $rb}'
EOF
chmod +x "$WORK/stub-ledger.sh"
export P4B_CODEX_LEDGER="$WORK/stub-ledger.sh"

_barrier() { # <cx_rc> <cr_rc> <cr_json> [policy] [head]
  printf '#!/bin/sh\nexit %s\n' "$1" >"$WORK/stub-cx.sh"
  printf "#!/bin/sh\nprintf '%%s' '%s'\nexit %s\n" "$3" "$2" >"$WORK/stub-cr.sh"
  chmod +x "$WORK/stub-cx.sh" "$WORK/stub-cr.sh"
  (
    export MERGEPATH_REVIEW_POLICY_PATH="${4:-$WORK/barrier-both.yml}"
    export P4B_ACCT_STATE_DIR="$WORK/barrier-state"
    export P4B_CODEX_REVIEW_CHECK="${P4B_TEST_CODEX_STUB:-$WORK/stub-cx.sh}"
    export P4B_TEST_CODEX_RECHECK_MARKER="${P4B_TEST_CODEX_RECHECK_MARKER:-$WORK/codex-recheck.marker}"
    export P4B_CODERABBIT_WAIT="$WORK/stub-cr.sh"
    export P4B_RESOLVE_BASE_POLICY="$WORK/barrier-bin/resolve-policy"
    export P4B_TEST_COMMENTS_JSON="${P4B_TEST_COMMENTS_JSON-[]}" P4B_TEST_LIVE_HEAD="${P4B_TEST_LIVE_HEAD:-${5:-abc123}}"
    export P4B_TEST_COMMENTS_FAIL="${P4B_TEST_COMMENTS_FAIL:-false}"
    export P4B_TEST_COMMENTS_RACE_FILE="${P4B_TEST_COMMENTS_RACE_FILE:-}" P4B_TEST_COMMENTS_FAIL_AFTER="${P4B_TEST_COMMENTS_FAIL_AFTER:-999}"
    export P4B_TEST_COMMENTS_CHANGE_AFTER="${P4B_TEST_COMMENTS_CHANGE_AFTER:-999}" P4B_TEST_COMMENTS_JSON_AFTER="${P4B_TEST_COMMENTS_JSON_AFTER:-}"
    export P4B_TEST_TIMELINE_JSON="${P4B_TEST_TIMELINE_JSON-[]}"
    export P4B_TEST_COMMIT_DATE="${P4B_TEST_COMMIT_DATE:-2026-09-26T00:00:00Z}"
    export P4B_TEST_BASE_REF="${P4B_TEST_BASE_REF:-main}" P4B_TEST_BASE_SHA="${P4B_TEST_BASE_SHA:-3333333333333333333333333333333333333333}"
    export P4B_TEST_DEFAULT_BRANCH="${P4B_TEST_DEFAULT_BRANCH:-main}" P4B_TEST_BASE_RACE_FILE="${P4B_TEST_BASE_RACE_FILE:-}" P4B_TEST_BASE_SHA_AFTER="${P4B_TEST_BASE_SHA_AFTER:-4444444444444444444444444444444444444444}"
    export P4B_TEST_BASE_RACE_AFTER="${P4B_TEST_BASE_RACE_AFTER:-2}"
    export P4B_TEST_HEAD_RACE_FILE="${P4B_TEST_HEAD_RACE_FILE:-}" P4B_TEST_HEAD_RACE_AFTER="${P4B_TEST_HEAD_RACE_AFTER:-1}" P4B_TEST_LIVE_HEAD_AFTER="${P4B_TEST_LIVE_HEAD_AFTER:-def456}"
    export P4B_TEST_BASE_POLICY_PATH="${P4B_TEST_BASE_POLICY_PATH-}"
    export PATH="$WORK/barrier-bin:$PATH"
    p4b_same_head_barrier owner/repo 7 "${5:-abc123}" rev-bot true "${6:-all}"
  )
}

cat >"$WORK/barrier-both.yml" <<'EOF'
coderabbit:
  enabled: true
  max_wait_seconds: 100
codex:
  enabled: true
author_identity: nathanjohnpayne
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

# #1085 end to end: only a valid timeout determination for the head under
# review may turn diagnostic rc=1 into a waiver. Ordinary absence/pending,
# stale evidence, malformed evidence, and head drift retain distinct states.
bad=""
_trigger=$(jq -cn --argjson id "$_p4a_trigger_id" --arg who "$_p4a_author" \
  '[{id:$id,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:00:00Z"}]')
_current=$(printf '%s' "$_trigger" | jq -c --arg body "$_p4a_marker" --arg who "$_p4a_author" --argjson id "$_p4a_marker_id" \
  '. + [{id:$id,user:{login:$who},body:$body,created_at:"2026-08-30T00:15:00Z"}]')
_superseded=$(printf '%s' "$_current" | jq -c --arg who "$_p4a_author" \
  '. + [{id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"}]')
_stale=$(printf '%s' "$_trigger" | jq -c --arg body "$_p4a_old_marker" --arg who "$_p4a_author" --argjson id "$_p4a_marker_id" \
  '. + [{id:$id,user:{login:$who},body:$body,created_at:"2026-08-30T00:15:00Z"}]')
_malformed=$(printf '%s' "$_trigger" | jq -c --arg who "$_p4a_author" --argjson id "$_p4a_marker_id" \
  '. + [{id:$id,user:{login:$who},body:"<!-- mergepath-phase-4a-terminal:v9 -->",created_at:"2026-08-30T00:15:00Z"}]')
_p4a_nosub="$WORK/policy-p4a-nosub.yml"
cat >"$_p4a_nosub" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: true
  max_wait_seconds: 100
codex:
  enabled: true
  allow_phase_4b_substitute: false
EOF
_p4a_noauthor="$WORK/policy-p4a-noauthor.yml"
cat >"$_p4a_noauthor" <<'EOF'
coderabbit:
  enabled: true
  max_wait_seconds: 100
codex:
  enabled: true
EOF

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_COMMENTS_JSON="$_current" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 0 ] || bad="$bad current-timeout-held"
[ "$(printf '%s' "$out" | jq -r '.codex')" = waived ] || bad="$bad current-timeout-class"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = timeout ] || bad="$bad current-timeout-evidence"

# The trusted author identity is policy, not a universal constant. A consumer
# that omits it cannot safely authenticate the marker/trigger pair and must
# escalate rather than silently trusting Mergepath's native author login.
out="$(P4B_TEST_COMMENTS_JSON="$_current" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$_p4a_noauthor" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad missing-author-not-escalated"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = unreadable ] || bad="$bad missing-author-evidence"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad no-determination-not-pending"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = none ] || bad="$bad no-determination-evidence"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_COMMENTS_JSON="$_stale" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad stale-not-pending"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = stale ] || bad="$bad stale-evidence"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_COMMENTS_JSON="$_superseded" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad superseded-not-pending"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = superseded ] || bad="$bad superseded-evidence"

out="$(P4B_TEST_COMMENTS_JSON="$_malformed" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad malformed-not-escalated"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = malformed ] || bad="$bad malformed-evidence"

out="$(P4B_TEST_COMMENTS_FAIL=true P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] || bad="$bad unreadable-not-fail-closed"
[ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = unreadable ] || bad="$bad unreadable-evidence"

# The canonical paginated-list reader must reject response streams that a
# naive `jq -s 'add // []'` would manufacture into [] or partially accept.
for _stream_case in empty null mixed; do
  case "$_stream_case" in
    empty) _stream='' ;;
    null) _stream='null' ;;
    mixed) _stream="$(printf 'null\n%s' "$_current")" ;;
  esac
  out="$(P4B_TEST_COMMENTS_JSON="$_stream" P4B_TEST_LIVE_HEAD="$_p4a_head" \
    _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
  [ "$rc" = 4 ] || bad="$bad ${_stream_case}-stream-not-fail-closed"
  [ "$(printf '%s' "$out" | jq -r '.codex_evidence')" = unreadable ] \
    || bad="$bad ${_stream_case}-stream-evidence"
done

out="$(P4B_TEST_COMMENTS_JSON="$_current" P4B_TEST_LIVE_HEAD="$_p4a_old" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/barrier-both.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] || bad="$bad drift-not-fail-closed"
printf '%s' "$out" | jq -e '.reason | test("head moved")' >/dev/null 2>&1 || bad="$bad drift-reason"

out="$(P4B_TEST_COMMENTS_JSON="$_current" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$_p4a_nosub" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad timeout-nosub-not-escalated"
if [ -z "$bad" ]; then
  pass "#1085: a durable current-head timeout opens Phase 4b; pending, superseded, stale, malformed, drift, and no-substitute remain distinct"
else
  fail "#1085: Phase 4a timeout handoff routing wrong:$bad"
fi

# #1305: a spent governing request budget is a human-tiebreaker stop, never
# authority for the Phase 4b adapter. The candidate policy deliberately raises
# its own cap; the separate base fixture must still govern.
cat >"$WORK/cap-candidate.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: false
  max_wait_seconds: 100
codex:
  enabled: true
  max_review_rounds: 100
  reaction_freshness_window_seconds: 1800
EOF
cat >"$WORK/cap-base.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: false
  max_wait_seconds: 100
codex:
  enabled: true
  max_review_rounds: 2
  reaction_freshness_window_seconds: 7200
EOF
cat >"$WORK/cap-base-zero-wait.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: false
  max_wait_seconds: 0
codex:
  enabled: true
  max_review_rounds: 2
  reaction_freshness_window_seconds: 1800
EOF
cat >"$WORK/cap-noauthor.yml" <<'EOF'
coderabbit:
  enabled: false
  max_wait_seconds: 100
codex:
  enabled: true
  max_review_rounds: 0
EOF
_cap_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_cap_old='[{"id":5101,"user":{"login":"nathanjohnpayne"},"body":"@codex review","created_at":"2026-08-01T00:00:00Z"},{"id":5102,"user":{"login":"nathanjohnpayne"},"body":"@CODEX REVIEW","created_at":"2026-08-02T00:00:00Z"}]'
_cap_final=$(printf '%s' "$_cap_old" | jq -c --arg now "$_cap_now" '.[1].created_at=$now')
bad=""
# Request selection must use the target branch's governing freshness window,
# not the candidate/trusted checkout's local value.
_governing_budget="$({
  export P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml"
  crqe_governing_budget owner/repo 7 "$WORK/cap-candidate.yml" nathanjohnpayne "$WORK/barrier-bin/resolve-policy"
})" || _governing_budget=''
[ "$(printf '%s' "$_governing_budget" | jq -r '.reaction_freshness_window_seconds // empty')" = 7200 ] \
  || bad="$bad governing-freshness-not-carried"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] || bad="$bad exhausted-not-tiebreak"
printf '%s' "$out" | jq -e '.decision == "human-tiebreaker" and .request_budget.request_attempts == 2 and .request_budget.max_request_attempts == 2 and (.reason | contains("request ceiling spent and a human stop holds (blocking-budget)"))' >/dev/null 2>&1 || bad="$bad exhausted-payload"

out="$(
  export MERGEPATH_REVIEW_POLICY_PATH="$WORK/cap-noauthor.yml"
  export P4B_RESOLVE_BASE_POLICY="$WORK/barrier-bin/resolve-policy"
  export P4B_TEST_BASE_POLICY_PATH="$WORK/cap-noauthor.yml"
  export P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head"
  export P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' P4B_TEST_TIMELINE_JSON='[]'
  export PATH="$WORK/barrier-bin:$PATH"
  p4b_codex_request_budget_state owner/repo 7 "$_p4a_head"
)" && rc=0 || rc=$?
[ "$rc" = 0 ] \
  && [ "$(printf '%s' "$out" | jq -r .state)" = exhausted ] \
  && [ "$(printf '%s' "$out" | jq -r .max_request_attempts)" = 0 ] \
  || bad="$bad omitted-author-default"

# Even an available request budget has no authority to classify an obsolete
# reviewed head. The live-head fence precedes every successful budget state.
out="$(
  export MERGEPATH_REVIEW_POLICY_PATH="$WORK/cap-candidate.yml"
  export P4B_RESOLVE_BASE_POLICY="$WORK/barrier-bin/resolve-policy"
  export P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml"
  export P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_old"
  export PATH="$WORK/barrier-bin:$PATH"
  p4b_codex_request_budget_state owner/repo 7 "$_p4a_head"
)" && rc=0 || rc=$?
[ "$rc" = 2 ] && [ "$(printf '%s' "$out" | jq -r .state)" = drift ] \
  && [ "$(printf '%s' "$out" | jq -r .live_head)" = "$_p4a_old" ] \
  || bad="$bad available-budget-skipped-head-fence"

# Governing policy authority is bound to the same stable PR tuple as the head.
# A base retarget/advance with an unchanged head invalidates the cap read.
_base_race="$WORK/cap-base-race.count"
rm -f "$_base_race"
out="$(P4B_TEST_BASE_RACE_FILE="$_base_race" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  && printf '%s' "$out" | jq -e '.reason | contains("base policy source changed")' >/dev/null 2>&1 \
  || bad="$bad governing-base-race-not-fail-closed"

# A diagnostic report about a newly moved live head cannot open the NEW
# cap-only missing-adapter path for the stale reviewed head.
out="$(P4B_TEST_LIVE_HEAD="$_p4a_old" _barrier 0 0 "{\"head_sha\":\"$_p4a_old\"}" "$WORK/cap-candidate.yml" "$_p4a_head" cap-only)" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  || bad="$bad cap-only-report-head-drift-opened"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad final-request-not-polled"
printf '%s' "$out" | jq -e '.codex_evidence == "request-cap-final-pending"' >/dev/null 2>&1 || bad="$bad final-request-evidence"

# A fresh final request cannot turn a terminal Codex refusal back into a wait.
# At the spent cap, preserve the refusal and stop for the human tiebreaker.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 2 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] || bad="$bad terminal-refusal-reopened-final-wait"
printf '%s' "$out" | jq -e '.decision == "human-tiebreaker" and .codex_evidence == "request-cap"' >/dev/null 2>&1 \
  || bad="$bad terminal-refusal-not-tiebreaker"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-zero-wait.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base-zero-wait.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] || bad="$bad final-wait-exhaustion-not-tiebreak"
printf '%s' "$out" | jq -e '.codex_evidence == "request-cap-final-wait-exhausted"' >/dev/null 2>&1 || bad="$bad final-wait-exhaustion-evidence"

# The final request may report while the zero/expired local wait is being
# evaluated. That terminal result wins over the non-retryable human stop.
cat >"$WORK/stub-cx-report-on-recheck.sh" <<'EOF'
#!/bin/sh
if [ -e "$P4B_TEST_CODEX_RECHECK_MARKER" ]; then
  exit 0
fi
: >"$P4B_TEST_CODEX_RECHECK_MARKER"
exit 1
EOF
chmod +x "$WORK/stub-cx-report-on-recheck.sh"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
rm -f "$WORK/codex-recheck.marker"
out="$(P4B_TEST_CODEX_STUB="$WORK/stub-cx-report-on-recheck.sh" P4B_TEST_CODEX_RECHECK_MARKER="$WORK/codex-recheck.marker" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-zero-wait.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base-zero-wait.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = signal ] \
  || bad="$bad final-wait-report-race-not-rechecked"

# A CodeRabbit terminal cause cannot bypass the authoritative final-request
# wait. Preserve the cause while Codex is still working; if the wait expires
# first, the spent request budget stops for the human. If Codex reports during
# the finishing sample, the retained CodeRabbit cause resumes the existing
# escalation path instead of incorrectly opening the barrier.
cat >"$WORK/cap-final-wait-cr.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: true
  max_wait_seconds: 100
codex:
  enabled: true
  max_review_rounds: 2
  reaction_freshness_window_seconds: 1800
EOF
cat >"$WORK/cap-final-wait-cr-zero.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: true
  max_wait_seconds: 0
codex:
  enabled: true
  max_review_rounds: 2
  reaction_freshness_window_seconds: 1800
EOF
for _cr_cause_rc in 2 3; do
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-final-wait-cr.yml" \
    P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
    _barrier 1 "$_cr_cause_rc" "{\"head_sha\":\"$_p4a_head\"}" \
      "$WORK/cap-final-wait-cr.yml" "$_p4a_head")" && rc=0 || rc=$?
  [ "$rc" = 1 ] \
    && [ "$(printf '%s' "$out" | jq -r .decision)" = pending ] \
    && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = request-cap-final-pending ] \
    && [ -n "$(printf '%s' "$out" | jq -r '.coderabbit_cause // empty')" ] \
    || bad="$bad final-request-cr${_cr_cause_rc}-bypassed-wait(rc=$rc,out=$out)"
done

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-final-wait-cr.yml" \
  P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_old\"}" \
    "$WORK/cap-final-wait-cr.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  && [ "$(printf '%s' "$out" | jq -r '.request_budget.reason')" = head-moved-during-final-request-wait ] \
  || bad="$bad final-request-head-drift-granted-handoff(rc=$rc,out=$out)"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-final-wait-cr-zero.yml" \
  P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  _barrier 1 2 "{\"head_sha\":\"$_p4a_head\"}" \
    "$WORK/cap-final-wait-cr-zero.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = human-tiebreaker ] \
  && [ -n "$(printf '%s' "$out" | jq -r '.coderabbit_cause // empty')" ] \
  || bad="$bad final-request-cr-cause-bypassed-exit8(rc=$rc,out=$out)"

rm -rf "$WORK/barrier-state/phase-4b-barrier"
rm -f "$WORK/codex-recheck.marker"
out="$(P4B_TEST_CODEX_STUB="$WORK/stub-cx-report-on-recheck.sh" \
  P4B_TEST_CODEX_RECHECK_MARKER="$WORK/codex-recheck.marker" \
  P4B_TEST_BASE_POLICY_PATH="$WORK/cap-final-wait-cr-zero.yml" \
  P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  _barrier 1 2 "{\"head_sha\":\"$_p4a_head\"}" \
    "$WORK/cap-final-wait-cr-zero.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 2 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = escalate ] \
  && [ -n "$(printf '%s' "$out" | jq -r '.coderabbit_cause // empty')" ] \
  || bad="$bad finishing-report-erased-cr-cause(rc=$rc,out=$out)"

# Unreadable terminal evidence is never equivalent to "no result" at either
# cap stop. It must take the authority-error path instead of exit 8.
for _terminal_case in immediate final-wait; do
  _comments_race="$WORK/${_terminal_case}-comments-race.count"
  rm -f "$_comments_race" "$WORK/codex-recheck.marker" "$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-$_p4a_head.pending"
  if [ "$_terminal_case" = immediate ]; then
    _race_comments="$_cap_old"; _race_policy="$WORK/cap-base.yml"
  else
    _race_comments="$_cap_final"; _race_policy="$WORK/cap-base-zero-wait.yml"
  fi
  out="$(P4B_TEST_COMMENTS_RACE_FILE="$_comments_race" P4B_TEST_COMMENTS_FAIL_AFTER=3 P4B_TEST_BASE_POLICY_PATH="$_race_policy" P4B_TEST_COMMENTS_JSON="$_race_comments" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$_race_policy" "$_p4a_head")" && rc=0 || rc=$?
  [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
    || bad="$bad ${_terminal_case}-unreadable-terminal-became-exit8"
done

# A head move visible only on the finishing sample invalidates both a newly
# reported diagnostic and an otherwise-empty terminal resample.
_head_race="$WORK/immediate-head-race.count"
rm -f "$_head_race" "$WORK/codex-recheck.marker"
out="$(P4B_TEST_CODEX_STUB="$WORK/stub-cx-report-on-recheck.sh" P4B_TEST_CODEX_RECHECK_MARKER="$WORK/codex-recheck.marker" P4B_TEST_HEAD_RACE_FILE="$_head_race" P4B_TEST_HEAD_RACE_AFTER=4 P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  || bad="$bad reported-finishing-head-drift-opened"
_head_race="$WORK/final-wait-head-race.count"
rm -f "$_head_race" "$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-$_p4a_head.pending"
out="$(P4B_TEST_HEAD_RACE_FILE="$_head_race" P4B_TEST_HEAD_RACE_AFTER=4 P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-zero-wait.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base-zero-wait.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  || bad="$bad empty-finishing-head-drift-became-exit8"

# A finishing Codex report resolves only the Codex arm. Preserve the other
# provider's state: ordinary CodeRabbit not-yet still exhausts to fallback,
# while its terminal rate-limit refusal opens under the existing #1178 rule.
cat >"$WORK/cap-base-zero-wait-cr.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: true
  max_wait_seconds: 0
codex:
  enabled: true
  max_review_rounds: 2
  reaction_freshness_window_seconds: 1800
EOF
for _cr_finish in not-yet rate-limited; do
  rm -f "$WORK/codex-recheck.marker"
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  case "$_cr_finish" in
    not-yet) _cr_json="{\"head_sha\":\"$_p4a_head\",\"probe\":{\"observed\":\"awaiting-summary\"}}" ;;
    rate-limited) _cr_json="{\"head_sha\":\"$_p4a_head\",\"probe\":{\"observed\":\"rate_limit\"}}" ;;
  esac
  out="$(P4B_TEST_CODEX_STUB="$WORK/stub-cx-report-on-recheck.sh" P4B_TEST_CODEX_RECHECK_MARKER="$WORK/codex-recheck.marker" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-zero-wait-cr.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 7 "$_cr_json" "$WORK/cap-base-zero-wait-cr.yml" "$_p4a_head")" && rc=0 || rc=$?
  case "$_cr_finish" in
    not-yet) [ "$rc" = 2 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = escalate ] || bad="$bad final-report-erased-coderabbit-wait" ;;
    rate-limited) [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = open ] || bad="$bad final-report-did-not-clear-rate-limit" ;;
  esac
done

# A trusted timeout that first appears in the finishing sample still obeys
# allow_phase_4b_substitute=false; it cannot open an unusable Phase 4b review.
cat >"$WORK/cap-base-zero-wait-nosub.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: false
  max_wait_seconds: 0
codex:
  enabled: true
  allow_phase_4b_substitute: false
  max_review_rounds: 2
  reaction_freshness_window_seconds: 1800
EOF
_cap_timeout_marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$_p4a_head trigger_comment_id=5102 -->"
_cap_final_lower=$(printf '%s' "$_cap_final" | jq -c '.[1].body="@codex review"')
_cap_final_timeout=$(printf '%s' "$_cap_final_lower" | jq -c --arg body "$_cap_timeout_marker" --arg now "$_cap_now" \
  '. + [{id:5199,user:{login:"nathanjohnpayne"},body:$body,created_at:$now}]')
_comments_race="$WORK/final-timeout-nosub-comments.count"
rm -f "$_comments_race" "$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-$_p4a_head.pending"
out="$(P4B_TEST_COMMENTS_RACE_FILE="$_comments_race" P4B_TEST_COMMENTS_CHANGE_AFTER=3 P4B_TEST_COMMENTS_JSON_AFTER="$_cap_final_timeout" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-zero-wait-nosub.yml" P4B_TEST_COMMENTS_JSON="$_cap_final_lower" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base-zero-wait-nosub.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 2 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = escalate ] \
  && printf '%s' "$out" | jq -e '.reason | contains("allow_phase_4b_substitute=false")' >/dev/null 2>&1 \
  || bad="$bad final-timeout-bypassed-no-substitute(rc=$rc,out=$out)"

# Current-head provider evidence wins before any budget read, even if that
# read would fail. A trusted pre-existing timeout also keeps its old waiver.
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/does-not-exist" P4B_TEST_COMMENTS_FAIL=true _barrier 0 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 0 ] || bad="$bad reported-did-not-win"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_current" P4B_TEST_LIVE_HEAD="$_p4a_head" _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = timeout ] || bad="$bad old-timeout-contract"

# A case-insensitive final request supersedes an earlier lowercase timeout,
# whether the final request remains eligible to poll or has expired.
_cap_superseded=$(printf '%s' "$_current" | jq -c --arg now "$_cap_now" \
  '. + [{id:9901,user:{login:"nathanjohnpayne"},body:"@CODEX REVIEW",created_at:$now}]')
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_superseded" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = request-cap-final-pending ] || bad="$bad uppercase-final-timeout-bypass"
_cap_superseded=$(printf '%s' "$_cap_superseded" | jq -c '.[-1].created_at="2026-08-30T00:16:00Z"')
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_superseded" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = human-tiebreaker ] || bad="$bad expired-uppercase-timeout-bypass"
out="$(crqe_select_trigger() { return 9; }; P4B_TEST_COMMENTS_JSON="$_current" _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = latest-request-selector-failed ] \
  || bad="$bad timeout-selector-error-not-fail-closed"

out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/does-not-exist" P4B_TEST_COMMENTS_JSON='[]' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] || bad="$bad unreadable-not-fail-closed"
out="$(crqe_select_trigger() { return 9; }; P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = final-request-selector-failed ] || bad="$bad selector-error-not-fail-closed"

# Diagnostic infrastructure errors cannot bypass the same governing cap. A
# readable exhausted budget stops for a human; unreadable budget evidence has
# no authority and takes the dedicated error path.
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 3 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = human-tiebreaker ] \
  || bad="$bad diagnostic-error-bypassed-cap"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/does-not-exist" P4B_TEST_COMMENTS_JSON='[]' _barrier 3 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  || bad="$bad diagnostic-error-unreadable-budget"

# Budget resolution is multi-read. If Codex reports during it, the terminal
# recheck must observe that report before the non-retryable exit-8 decision.
rm -f "$WORK/codex-recheck.marker"
out="$(P4B_TEST_CODEX_STUB="$WORK/stub-cx-report-on-recheck.sh" P4B_TEST_CODEX_RECHECK_MARKER="$WORK/codex-recheck.marker" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = signal ] \
  || bad="$bad terminal-report-race-not-rechecked"
if [ -z "$bad" ]; then
  pass "#1305: governing request-cap exhaustion stops for a human while final-request polling, old timeout, and current report retain precedence"
else
  fail "#1305: request-cap barrier routing wrong:$bad"
fi

# #1560 slice 3, S3-4: a spent request ceiling is cost exhaustion, not
# non-convergence. With no human stop it waives the Codex arm so the adapter
# reviews the head; a spent blocking-review budget, an untested rebuttal or a
# disagreement stops for the human (exit 8); unreadable human-stop evidence is
# an authority error (exit 10). Condition 2: after the final-request wait the
# stops are re-evaluated before anything is dispatched.
bad=""
for _mode in clear blocking untested disagreement fail garbage other-head; do
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  out="$(P4B_TEST_LEDGER_MODE="$_mode" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
  case "$_mode" in
    clear)
      [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.decision == "open" and .codex == "waived" and .codex_evidence == "request-ceiling"
          and .human_stops.state == "clear" and .human_stops.blocking_reviews == 1 and .human_stops.max_blocking_reviews == 10' >/dev/null 2>&1 \
        || bad="$bad ceiling-clear-not-waived(rc=$rc,out=$out)" ;;
    blocking|untested|disagreement)
      case "$_mode" in blocking) _stop=blocking-budget ;; untested) _stop=untested-rebuttal ;; *) _stop=disagreement ;; esac
      [ "$rc" = 3 ] && printf '%s' "$out" | jq -e --arg s "$_stop" '.decision == "human-tiebreaker" and .codex_evidence == "request-cap"
          and (.human_stops.stops | index($s)) != null and (.reason | contains($s))' >/dev/null 2>&1 \
        || bad="$bad ceiling-$_mode-not-exit8(rc=$rc,out=$out)" ;;
    *)
      [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
        || bad="$bad ceiling-$_mode-not-fail-closed(rc=$rc,out=$out)" ;;
  esac
done

# Condition 2: the final-request wait expires with no report; the stops are
# evaluated then, from fresh reads, and decide the route.
for _mode in clear untested fail; do
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  out="$(P4B_TEST_LEDGER_MODE="$_mode" P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-zero-wait.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base-zero-wait.yml" "$_p4a_head")" && rc=0 || rc=$?
  case "$_mode" in
    clear) [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = request-ceiling-final-wait ] \
             || bad="$bad final-wait-clear-not-waived(rc=$rc,out=$out)" ;;
    untested) [ "$rc" = 3 ] && printf '%s' "$out" | jq -e '.codex_evidence == "request-cap-final-wait-exhausted" and .human_stops.stops == ["untested-rebuttal"]' >/dev/null 2>&1 \
             || bad="$bad final-wait-untested-not-exit8(rc=$rc,out=$out)" ;;
    fail) [ "$rc" = 4 ] || bad="$bad final-wait-ledger-failure-not-fail-closed(rc=$rc)" ;;
  esac
done
# While the final request is still pending, the stops are not consulted: the
# wait owns the decision until it ends.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_LEDGER_MODE=fail P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .codex_evidence)" = request-cap-final-pending ] \
  || bad="$bad pending-final-request-read-stops(rc=$rc)"

# allow_phase_4b_substitute=false: a waived ceiling could never clear gate (c).
rm -rf "$WORK/barrier-state/phase-4b-barrier"
cp "$WORK/cap-base.yml" "$WORK/cap-base-nosub.yml"
printf '  allow_phase_4b_substitute: false\n' >>"$WORK/cap-base-nosub.yml"
grep -q '^  max_review_rounds: 2$' "$WORK/cap-base-nosub.yml" \
  && [ "$(grep -c 'allow_phase_4b_substitute' "$WORK/cap-base-nosub.yml")" = 1 ] \
  || bad="$bad nosub-fixture-malformed"
out="$(P4B_TEST_LEDGER_MODE=clear P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-nosub.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-base-nosub.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | jq -e '.decision == "escalate" and (.reason | contains("request ceiling is spent"))' >/dev/null 2>&1 \
  || bad="$bad ceiling-waived-without-substitute(rc=$rc,out=$out)"

# Runaway (#1560 canary, finding 1): the request ceiling (cap-base: 2) is
# reached with both requests drawing a blocking review, under the default
# budget of 10. That is non-convergence, not cost exhaustion: exit 8.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_LEDGER_MODE=two P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | jq -e '.decision == "human-tiebreaker" and .human_stops.stops == ["runaway"]
    and .human_stops.request_ceiling == 2 and (.reason | contains("runaway"))' >/dev/null 2>&1 \
  || bad="$bad runaway-at-ceiling-waived(rc=$rc,out=$out)"

# The governed blocking budget is the base policy's, and an invalid one fails
# closed rather than reading as room.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
cp "$WORK/cap-base.yml" "$WORK/cap-base-blocking9.yml"; printf '  max_blocking_reviews: 9\n' >>"$WORK/cap-base-blocking9.yml"
out="$(P4B_TEST_LEDGER_MAX=9 P4B_TEST_LEDGER_MODE=nine P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-blocking9.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | jq -e '.human_stops.stops == ["blocking-budget"] and .human_stops.max_blocking_reviews == 9' >/dev/null 2>&1 \
  || bad="$bad governing-blocking-budget-ignored(rc=$rc,out=$out)"
cp "$WORK/cap-base.yml" "$WORK/cap-base-blocking-bad.yml"; printf '  max_blocking_reviews: false\n' >>"$WORK/cap-base-blocking-bad.yml"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_LEDGER_MODE=clear P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base-blocking-bad.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = blocking-budget-invalid ] \
  || bad="$bad invalid-blocking-budget-read-as-room(rc=$rc,out=$out)"

# A ledger read under a different base-policy snapshot (its budget differs
# from the one the barrier read) is conflicting evidence, never room.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_LEDGER_MAX=7 P4B_TEST_LEDGER_MODE=clear P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = ledger-malformed ] \
  || bad="$bad snapshot-budget-mismatch-read-as-room(rc=$rc,out=$out)"
# Same budget, different snapshot: the fingerprint, not the budget, decides.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(P4B_TEST_LEDGER_FP=1-1 P4B_TEST_LEDGER_MODE=clear P4B_TEST_BASE_POLICY_PATH="$WORK/cap-base.yml" P4B_TEST_COMMENTS_JSON="$_cap_old" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-candidate.yml" "$_p4a_head")" && rc=0 || rc=$?
[ "$rc" = 4 ] && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = ledger-policy-snapshot-mismatch ] \
  || bad="$bad snapshot-fingerprint-mismatch-read-as-room(rc=$rc,out=$out)"

# The spent ceiling and the stops must be judged under one governing tuple
# (#1579): a base that moved between the two reads is an authority error.
# The route reads and sets these through bash dynamic scoping.
# shellcheck disable=SC2034
_route() { # <budget-json> <stops-json> [budget-reread-json]
  (
    cx_budget_json=$1
    _stops_json=$2
    _reread_json=${3:-$1}
    p4b_codex_human_stops() { printf '%s' "$_stops_json"; }
    p4b_codex_request_budget_state() { printf '%s' "$_reread_json"; }
    cls_cx=""; budget_unsafe=false; why=""; human_tiebreaker=false; cx_evidence=""; cx_human_stops_json=null
    p4b_barrier_ceiling_route o/r 7 head request-ceiling request-cap ""
    printf '%s|%s|%s' "$cls_cx" "$budget_unsafe" "$cx_evidence"
  )
}
_t1='{"head_sha":"h","base_ref":"main","base_sha":"1","default_branch":"main"}'
_t2='{"head_sha":"h","base_ref":"main","base_sha":"2","default_branch":"main"}'
_snap() { printf '{"state":"%s","stops":[],"governing_tuple":%s,"policy_fingerprint":"%s","request_generation":%s}' "$1" "$2" "$3" "${4:-[1]}"; }
[ "$(_route "$(_snap exhausted "$_t1" 1-1)" "$(_snap clear "$_t1" 1-1)")" = "waived|false|request-ceiling" ] \
  || bad="$bad same-snapshot-not-waived($(_route "$(_snap exhausted "$_t1" 1-1)" "$(_snap clear "$_t1" 1-1)"))"
[ "$(_route "$(_snap exhausted "$_t1" 1-1)" "$(_snap clear "$_t2" 1-1)")" = "escalate|true|pr-policy-tuple-changed-between-ceiling-and-stops" ] \
  || bad="$bad tuple-drift-between-ceiling-and-stops-read-as-clear"
# Same tuple, different policy: a base without a policy file resolves to the
# mutable default branch, which can change under an unchanged tuple.
[ "$(_route "$(_snap exhausted "$_t1" 1-1)" "$(_snap clear "$_t1" 2-2)")" = "escalate|true|pr-policy-tuple-changed-between-ceiling-and-stops" ] \
  || bad="$bad fingerprint-drift-under-same-tuple-read-as-clear"
[ "$(_route '{"state":"exhausted"}' "$(_snap clear "$_t1" 1-1)")" = "escalate|true|pr-policy-tuple-changed-between-ceiling-and-stops" ] \
  || bad="$bad missing-ceiling-snapshot-read-as-clear"
# The dispatch boundary (#1580): a request posted during the stop read (a new
# generation in the re-read) refuses the waiver before the adapter runs.
[ "$(_route "$(_snap exhausted "$_t1" 1-1)" "$(_snap clear "$_t1" 1-1)" "$(_snap final-request-pending "$_t1" 1-1 '[1,2]')")" = "escalate|true|request-generation-or-snapshot-changed-before-dispatch" ] \
  || bad="$bad generation-change-before-dispatch-waived"
p4b_same_governing_tuple "$(_snap exhausted "$_t1" 1-1)" "$(_snap clear "$(printf '%s' "$_t1" | jq -cS .)" 1-1)" \
  && ! p4b_same_governing_tuple "{\"governing_tuple\":$_t1}" "$(_snap clear "$_t1" 1-1)" \
  || bad="$bad same-snapshot-helper"

if [ -z "$bad" ]; then
  pass "#1560 S3-4: a spent ceiling waives Codex only with no human stop; blocking budget, untested rebuttal and disagreement exit 8; unreadable evidence exits 10; the final-request wait re-evaluates before dispatch"
else
  fail "#1560 S3-4: ceiling routing wrong:$bad"
fi

# A below-cap comments snapshot cannot grant fallback authority after its
# request generation changes. The third comments read is the authority fence:
# timeout detection and budget evaluation see no request, then the final
# allowed request appears without changing the PR head/base tuple.
cat >"$WORK/cap-generation-fence.yml" <<'EOF'
author_identity: nathanjohnpayne
coderabbit:
  enabled: false
  max_wait_seconds: 0
codex:
  enabled: true
  max_review_rounds: 1
  reaction_freshness_window_seconds: 1800
EOF
_cap_generation_after=$(jq -nc --arg now "$_cap_now" \
  '[{id:6101,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:$now}]')
bad=""

sed 's/max_review_rounds: 1/max_review_rounds: 2/' \
  "$WORK/cap-generation-fence.yml" >"$WORK/cap-generation-stable.yml"
out="$(P4B_TEST_BASE_POLICY_PATH="$WORK/cap-generation-stable.yml" \
  P4B_TEST_COMMENTS_JSON="$_cap_generation_after" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-generation-stable.yml" "$_p4a_head" cap-only)" && rc=0 || rc=$?
[ "$rc" = 0 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = open ] \
  && [ "$(printf '%s' "$out" | jq -r '.request_budget.governing_tuple.base_sha')" = 3333333333333333333333333333333333333333 ] \
  && [ "$(printf '%s' "$out" | jq -r '.request_budget.governing_budget.max_request_attempts')" = 2 ] \
  || bad="$bad stable-nonempty-generation(rc=$rc,out=$out)"

# The initial budget read is coherent, but the base advances before the
# barrier grants it. Request generation remains unchanged; the governing tuple
# alone must revoke the stale authority at this consumer boundary.
_generation_base_race="$WORK/cap-generation-base-race.count"
rm -f "$_generation_base_race"
out="$(P4B_TEST_BASE_RACE_FILE="$_generation_base_race" P4B_TEST_BASE_RACE_AFTER=3 \
  P4B_TEST_BASE_POLICY_PATH="$WORK/cap-generation-stable.yml" \
  P4B_TEST_COMMENTS_JSON="$_cap_generation_after" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-generation-stable.yml" "$_p4a_head" cap-only)" && rc=0 || rc=$?
[ "$rc" = 4 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = pr-policy-tuple-changed ] \
  && [ "$(cat "$_generation_base_race" 2>/dev/null || true)" = 3 ] \
  || bad="$bad barrier-base-authority-race(rc=$rc,out=$out)"

for _generation_scope in cap-only all; do
  _generation_race="$WORK/cap-generation-${_generation_scope}.count"
  rm -f "$_generation_race" "$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-$_p4a_head.pending"
  out="$(P4B_TEST_COMMENTS_RACE_FILE="$_generation_race" \
    P4B_TEST_COMMENTS_CHANGE_AFTER=3 P4B_TEST_COMMENTS_JSON_AFTER="$_cap_generation_after" \
    P4B_TEST_BASE_POLICY_PATH="$WORK/cap-generation-fence.yml" P4B_TEST_COMMENTS_JSON='[]' \
    P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
    _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-generation-fence.yml" "$_p4a_head" "$_generation_scope")" && rc=0 || rc=$?
  [ "$rc" = 4 ] \
    && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
    && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = request-generation-changed ] \
    && [ "$(cat "$_generation_race" 2>/dev/null || true)" = 3 ] \
    || bad="$bad ${_generation_scope}-generation-race(rc=$rc,out=$out)"
done

_generation_race="$WORK/cap-generation-unreadable.count"
rm -f "$_generation_race"
out="$(P4B_TEST_COMMENTS_RACE_FILE="$_generation_race" P4B_TEST_COMMENTS_FAIL_AFTER=3 \
  P4B_TEST_BASE_POLICY_PATH="$WORK/cap-generation-fence.yml" P4B_TEST_COMMENTS_JSON='[]' \
  P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  _barrier 1 0 "{\"head_sha\":\"$_p4a_head\"}" "$WORK/cap-generation-fence.yml" "$_p4a_head" cap-only)" && rc=0 || rc=$?
[ "$rc" = 4 ] \
  && [ "$(printf '%s' "$out" | jq -r .decision)" = error ] \
  && [ "$(printf '%s' "$out" | jq -r .request_budget.reason)" = request-generation-reread-failed ] \
  || bad="$bad unreadable-generation-fence(rc=$rc,out=$out)"

if [ -z "$bad" ]; then
  pass "#1305: changed or unreadable request generation cannot grant cap-only or expired full-barrier fallback authority"
else
  fail "#1305: request-generation authority fence wrong:$bad"
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
author_identity: nathanjohnpayne
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
    export P4B_RESOLVE_BASE_POLICY="$WORK/barrier-bin/resolve-policy"
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

# --- #1178: a rate-limited CodeRabbit resolves against the Codex arm --------
#
# The composition half of the classifier assertions above. Every case uses the
# rc-7 probe shape the live #946 stall produced — observed=rate_limit on the
# head under review — and varies only the Codex delegate's exit code, because
# that is the whole decision.
bad=""
_ratelimited='{"head_sha":"abc123","probe":{"observed":"rate_limit"}}'
_marker="$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-abc123.pending"

# 1. Codex reported on this head ⇒ OPEN. The barrier's guarantee is that some
#    provider has read the head about to be approved, and Codex reporting is
#    exactly that. This is the rc-5 `waived` trade reached without the #489
#    failover having to have run: cls_cx == reported is strictly better
#    evidence than codex_failover_requested, which only says a request was
#    sent.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(_barrier 0 7 "$_ratelimited")" && rc=0 || rc=$?
[ "$rc" = 0 ] || bad="$bad codexreported-not-open"
printf '%s' "$out" | jq -e '.decision == "open"' >/dev/null 2>&1 || bad="$bad codexreported-decision"
# Acceptance criterion 2: the barrier's OWN output distinguishes "has not
# reviewed yet" from "cannot review". Before this the same state reported
# `not-yet` and the distinction lived only inside coderabbit-wait.sh.
printf '%s' "$out" | jq -e '.coderabbit == "rate-limited"' >/dev/null 2>&1 || bad="$bad codexreported-class"
# No wait was started, so nothing accumulates toward a budget that had
# nothing to wait for — the #839 routing.
[ ! -f "$_marker" ] || bad="$bad codexreported-started-budget"

# 2. Codex account-blocked (rc 2 ⇒ waived) ⇒ ESCALATE, not open. This is the
#    case the whole design turns on: `waived` is in the family that opens the
#    barrier for the Codex arm, so a naive "CodeRabbit refused, is anyone
#    else terminal?" test would let an approval post with NOTHING having read
#    the head. A refusal plus a block is a human's problem.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(_barrier 2 7 "$_ratelimited")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad codexwaived-not-escalated"
printf '%s' "$out" | jq -e '.reason | test("rate limited")' >/dev/null 2>&1 || bad="$bad codexwaived-reason"
printf '%s' "$out" | jq -e '.coderabbit == "rate-limited"' >/dev/null 2>&1 || bad="$bad codexwaived-class"
[ ! -f "$_marker" ] || bad="$bad codexwaived-started-budget"

# 3. Codex still working (rc 1 ⇒ not-yet) ⇒ PENDING, and the budget DOES
#    start. Deliberately not an escalation: the wait is on Codex, which is
#    self-clearing, and the next probe can find it reported and open on it.
#    Escalating here would page a human on a PR whose Codex round was about
#    to land — the #835 objection to escalating a rate limit unconditionally.
rm -rf "$WORK/barrier-state/phase-4b-barrier"
out="$(_barrier 1 7 "$_ratelimited")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad codexnotyet-not-pending"
printf '%s' "$out" | jq -e '.coderabbit == "rate-limited"' >/dev/null 2>&1 || bad="$bad codexnotyet-class"
[ -f "$_marker" ] || bad="$bad codexnotyet-no-marker"
# And no allowance is spent in any direction while it holds: should_trigger
# declines on rate_limit, and a resume answers a pause rather than a limit.
printf '%s' "$out" | jq -e '.trigger == "skipped" and .resume == "skipped"' >/dev/null 2>&1 \
  || bad="$bad codexnotyet-spent-allowance"

# 4. When THAT wait does exhaust, the escalation names the refusal rather than
#    the clock. The manual fallback's renderer carries only this string, so
#    "did not reach the current head" would send an operator to wait longer or
#    re-nudge a provider that has already refused.
# Age case 3's marker past barrier-both.yml's 100s budget. Backdating the
# marker is how every other bound assertion in this suite exhausts a wait.
printf '%s\n' "$(( $(date +%s) - 100000 ))" >"$_marker"
out="$(_barrier 1 7 "$_ratelimited")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad exhausted-not-escalated"
printf '%s' "$out" | jq -e '.reason | test("rate limited")' >/dev/null 2>&1 || bad="$bad exhausted-reason-ratelimit"
printf '%s' "$out" | jq -e '.reason | test("Codex")' >/dev/null 2>&1 || bad="$bad exhausted-reason-codex"
rm -rf "$WORK/barrier-state/phase-4b-barrier"

# 5. Criterion 3: a CodeRabbit that is genuinely just SLOW is untouched. Every
#    other rc-7 observed still takes the bounded wait, so the fix cannot be
#    "stop waiting on CodeRabbit" — which would let Phase 4b approve ahead of
#    a review that was seconds from landing.
for _o in none in_progress paused awaiting-summary summary-without-head-review; do
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  out="$(_barrier 0 7 "{\"head_sha\":\"abc123\",\"probe\":{\"observed\":\"$_o\"}}")" && rc=0 || rc=$?
  [ "$rc" = 1 ] || bad="$bad slow-$_o-not-pending"
  printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad slow-$_o-class"
  [ -f "$_marker" ] || bad="$bad slow-$_o-no-marker"
done
rm -rf "$WORK/barrier-state/phase-4b-barrier"

if [ -z "$bad" ]; then
  pass "#1178: a rate-limited CodeRabbit opens on a head-pinned Codex report, escalates when nothing read the head, and never silently holds forever"
else
  fail "#1178 rate-limited routing wrong:$bad"
fi

# --- #1335: same-content CodeRabbit carry-forward on a base-only head --------
#
# The #1318 shape: CodeRabbit does not review merge commits, so on a base-only
# update head the probe stays rc 7 forever and the barrier used to wait out its
# whole budget, then hand off to a human. The CodeRabbit arm now carries its
# review of the last content head forward — but ONLY when the #705
# external-review fingerprint of that commit equals this head's. Every other
# case must stay exactly the not-yet it was.
bad=""
_H=1111111111111111111111111111111111111111
_L=2222222222222222222222222222222222222222
_marker="$WORK/barrier-state/phase-4b-barrier/owner-repo-pr7-$_H.pending"
_fplog="$WORK/stub-fp.log"
cat >"$WORK/stub-fp.sh" <<'EOF'
#!/bin/sh
# Fingerprint delegate stub. P4B_TEST_FP_<ref> is the fingerprint for that
# ref: unset means requires_review false (no fingerprint), FAIL means the
# delegate itself failed.
ref="" files=""
while [ $# -gt 0 ]; do
  case "$1" in --ref) ref=$2; shift 2 ;; --files-json) files=$2; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$ref" >>"$P4B_TEST_FP_LOG"
# Which changed-file list this call hashed: path + content checksum.
printf '%s %s\n' "$files" "$(cksum <"$files" 2>/dev/null || echo MISSING)" >>"$P4B_TEST_FP_LOG.files"
eval "fp=\${P4B_TEST_FP_$ref:-}"
[ "$fp" != FAIL ] || exit 2
if [ -z "$fp" ]; then
  printf '{"requires_review":false,"fingerprint":""}'
else
  printf '{"requires_review":true,"fingerprint":"%s"}' "$fp"
fi
EOF
chmod +x "$WORK/stub-fp.sh"
export P4B_EXTERNAL_REVIEW_FINGERPRINT="$WORK/stub-fp.sh" P4B_TEST_FP_LOG="$_fplog"
# <observed> <state> <permits> [reviewed]
_cfjson() {
  printf '{"head_sha":"%s","probe":{"mode":true,"observed":"%s","carryforward":{"reviewed_head":"%s","head_context_state":"%s","head_context_permits_clearance":%s}}}' \
    "$_H" "$1" "${4-$_L}" "$2" "$3"
}
_cfreset() { rm -rf "$WORK/barrier-state/phase-4b-barrier"; : >"$_fplog"; : >"$_fplog.files"; }
export "P4B_TEST_FP_$_H=external-review:v2:same" "P4B_TEST_FP_$_L=external-review:v2:same"

# 1. The #1318 head: identical PR content, CodeRabbit finished its run on the
#    head without reviewing it. OPENS, names the carry, starts no budget, and
#    fingerprints exactly the two commits involved.
for _o in summary-without-head-review none; do
  _cfreset
  out="$(_barrier 0 7 "$(_cfjson "$_o" success true)" "" "$_H")" && rc=0 || rc=$?
  [ "$rc" = 0 ] || bad="$bad carried-$_o-rc=$rc"
  printf '%s' "$out" | jq -e --arg l "$_L" '.decision == "open" and .coderabbit == "carried"
    and .coderabbit_carryforward.source_commit == $l
    and .coderabbit_carryforward.fingerprint == "external-review:v2:same"' >/dev/null 2>&1 \
    || bad="$bad carried-$_o-json"
  [ ! -f "$_marker" ] || bad="$bad carried-$_o-started-budget"
  [ "$(sort "$_fplog" | tr '\n' ' ')" = "$_H $_L " ] || bad="$bad carried-$_o-fp-refs"
  # Both fingerprints hash ONE changed-file list — the same path set — or
  # equality proves nothing about the paths only one of them saw.
  [ "$(wc -l <"$_fplog.files" | tr -d ' ')" = 2 ] && [ "$(sort -u "$_fplog.files" | wc -l | tr -d ' ')" = 1 ] \
    && ! grep -q MISSING "$_fplog.files" || bad="$bad carried-$_o-files-list"
done

# 2. FAIL CLOSED on any content change: a different fingerprint is the
#    ordinary not-yet — pending, budget started — never an open.
_cfreset
export "P4B_TEST_FP_$_L=external-review:v2:older"
out="$(_barrier 0 7 "$(_cfjson summary-without-head-review success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad changed-content-rc=$rc"
printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad changed-content-class"
[ -f "$_marker" ] || bad="$bad changed-content-no-budget"
export "P4B_TEST_FP_$_L=external-review:v2:same"

# 3. A fingerprint that cannot be computed, or proves nothing, never carries.
for _case in src-fail head-fail no-review files-fail; do
  _cfreset
  case "$_case" in
    src-fail)  export "P4B_TEST_FP_$_L=FAIL" ;;
    head-fail) export "P4B_TEST_FP_$_H=FAIL" ;;
    no-review) unset "P4B_TEST_FP_$_H" "P4B_TEST_FP_$_L" ;;
  esac
  if [ "$_case" = files-fail ]; then
    out="$(P4B_TEST_FILES_FAIL=true _barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
    [ ! -s "$_fplog" ] || bad="$bad files-fail-still-fingerprinted"
  else
    out="$(_barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
  fi
  [ "$rc" = 1 ] || bad="$bad $_case-rc=$rc"
  printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad $_case-class"
  export "P4B_TEST_FP_$_H=external-review:v2:same" "P4B_TEST_FP_$_L=external-review:v2:same"
done

# 3b. Codex P2 on #1340: the CodeRabbit configuration must be the one the
#     carried review ran under, and the changed-file set must be <head>'s own
#     and complete. Each refusal happens before any fingerprint is computed.
_cfreset
export "P4B_TEST_CFG_$_L=cfgold"
out="$(_barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad cfg-changed-rc=$rc"
printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad cfg-changed-class"
[ ! -s "$_fplog" ] || bad="$bad cfg-changed-fingerprinted"
unset "P4B_TEST_CFG_$_L"
_cfreset
export "P4B_TEST_CFG_$_H=none"
out="$(_barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad cfg-removed-rc=$rc"
unset "P4B_TEST_CFG_$_H"
# A SYMLINKED config (mode 120000) at both commits, identical link blob:
# the target could differ, so it is refused rather than compared.
_cfreset
export "P4B_TEST_CFG_MODE_$_H=120000" "P4B_TEST_CFG_MODE_$_L=120000"
out="$(_barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad cfg-symlink-rc=$rc"
printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad cfg-symlink-class"
[ ! -s "$_fplog" ] || bad="$bad cfg-symlink-fingerprinted"
unset "P4B_TEST_CFG_MODE_$_H" "P4B_TEST_CFG_MODE_$_L"
_cfreset
out="$(P4B_TEST_CFG_FAIL=true _barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad cfg-unreadable-rc=$rc"
[ ! -s "$_fplog" ] || bad="$bad cfg-unreadable-fingerprinted"
_cfreset
out="$(P4B_TEST_COMPARE_COUNT=300 _barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad compare-capped-rc=$rc"
[ ! -s "$_fplog" ] || bad="$bad compare-capped-fingerprinted"
# Control: 299 files and an unchanged config (both absent) still carry.
_cfreset
export "P4B_TEST_CFG_$_H=none" "P4B_TEST_CFG_$_L=none"
out="$(P4B_TEST_COMPARE_COUNT=299 _barrier 0 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 0 ] || bad="$bad compare-299-noconfig-rc=$rc"
unset "P4B_TEST_CFG_$_H" "P4B_TEST_CFG_$_L"

# 4. The head's own run must be FINISHED, and not the `Review rate limited`
#    kind of success: a run still underway could yet publish a finding, and
#    an unsampled status (trust opt-out) proves nothing. None of these even
#    spends the fingerprint reads.
for _st in 'pending true' 'success false' 'null false' 'failure true'; do
  _cfreset
  _state="${_st% *}" _permits="${_st#* }"
  out="$(_barrier 0 7 "$(_cfjson none "$_state" "$_permits")" "" "$_H")" && rc=0 || rc=$?
  [ "$rc" = 1 ] || bad="$bad status-$_state-$_permits-rc=$rc"
  printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad status-$_state-$_permits-class"
  [ ! -s "$_fplog" ] || bad="$bad status-$_state-$_permits-fingerprinted"
done
# The trust opt-out's real shape: JSON null state and permits, not strings.
_cfreset
out="$(_barrier 0 7 "{\"head_sha\":\"$_H\",\"probe\":{\"mode\":true,\"observed\":\"none\",\"carryforward\":{\"reviewed_head\":\"$_L\",\"head_context_state\":null,\"head_context_permits_clearance\":null}}}" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad status-jsonnull-rc=$rc"
[ ! -s "$_fplog" ] || bad="$bad status-jsonnull-fingerprinted"

# 5. Only an IDLE CodeRabbit carries. A pause, a run in progress or a
#    head-pinned object awaiting its summary is a CodeRabbit that is not done,
#    whatever it reviewed before; a refusal keeps its own #1178 routing.
for _o in paused in_progress awaiting-summary; do
  _cfreset
  out="$(_barrier 0 7 "$(_cfjson "$_o" success true)" "" "$_H")" && rc=0 || rc=$?
  [ "$rc" = 1 ] || bad="$bad observed-$_o-rc=$rc"
  printf '%s' "$out" | jq -e '.coderabbit == "not-yet"' >/dev/null 2>&1 || bad="$bad observed-$_o-class"
done
_cfreset
out="$(_barrier 0 7 "$(_cfjson rate_limit success true)" "" "$_H")" && rc=0 || rc=$?
printf '%s' "$out" | jq -e '.coderabbit == "rate-limited"' >/dev/null 2>&1 || bad="$bad observed-rate_limit-class"

# 6. A summary-only blocking finding (probe rc 2) escalates as before, even
#    when the JSON also carries evidence: carry-forward refines only a not-yet.
_cfreset
out="$(_barrier 0 2 "$(_cfjson terminal success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 2 ] || bad="$bad rc2-not-escalated"
printf '%s' "$out" | jq -e '.reason | test("summary")' >/dev/null 2>&1 || bad="$bad rc2-reason"

# 7. Evidence that names the head under review is not carry evidence, and a
#    malformed or absent reviewed commit is no evidence at all.
for _rv in "$_H" "not-a-sha" ""; do
  _cfreset
  out="$(_barrier 0 7 "$(_cfjson none success true "$_rv")" "" "$_H")" && rc=0 || rc=$?
  [ "$rc" = 1 ] || bad="$bad reviewed-'$_rv'-rc=$rc"
  [ ! -s "$_fplog" ] || bad="$bad reviewed-'$_rv'-fingerprinted"
done

# 8. Codex still working: CodeRabbit is carried, the hold is on CODEX alone,
#    and no CodeRabbit request is spent or queued behind it.
_cfreset
out="$(_barrier 1 7 "$(_cfjson none success true)" "" "$_H")" && rc=0 || rc=$?
[ "$rc" = 1 ] || bad="$bad codexnotyet-rc=$rc"
printf '%s' "$out" | jq -e '.coderabbit == "carried" and .codex == "not-yet" and .trigger == "skipped"' >/dev/null 2>&1 \
  || bad="$bad codexnotyet-json"
_cfreset

unset -f _cfjson _cfreset
unset P4B_EXTERNAL_REVIEW_FINGERPRINT P4B_TEST_FP_LOG "P4B_TEST_FP_$_H" "P4B_TEST_FP_$_L"
if [ -z "$bad" ]; then
  pass "#1335: a base-only head carries CodeRabbit's review of identical PR content, and every content change, unreadable fingerprint, unfinished run or busy CodeRabbit stays not-yet"
else
  fail "#1335 CodeRabbit carry-forward routing wrong:$bad"
fi

# #1335, end to end: an approval that posts over a CARRIED CodeRabbit says so
# in its own Review Metadata — source commit and fingerprint — for the same
# reason the #1178 partial quorum does: a reader who assumes CodeRabbit read
# this exact head would draw a stronger conclusion than the review supports.
_L=2222222222222222222222222222222222222222
cat >"$WORK/stub-cr-carried.sh" <<EOF
#!/bin/sh
printf '{"head_sha":"abc123","probe":{"mode":true,"observed":"none","carryforward":{"reviewed_head":"$_L","head_context_state":"success","head_context_permits_clearance":true}}}'
exit 7
EOF
mkdir -p "$WORK/cf-bin"
cat >"$WORK/cf-bin/gh" <<EOF
#!/usr/bin/env bash
# The orchestrator fake serves none of the carry-forward's reads: the PR base
# sha, the head-bound compare, and the commit/tree reads for the CodeRabbit
# config identity. Everything else goes to the orchestrator fake.
if [ "\${1:-}" = api ]; then
  case "\${2:-} \${4:-}" in
    "repos/o/r/pulls/1335 .base.sha") printf '3333333333333333333333333333333333333333'; exit 0 ;;
  esac
  case "\${2:-}" in
    repos/o/r/compare/*) printf '[{"filename":"scripts/x.sh"}]'; exit 0 ;;
    repos/o/r/commits/*) printf '4444444444444444444444444444444444444444'; exit 0 ;;
    repos/o/r/git/trees/*) printf '[{"path":".coderabbit.yml","mode":"100644","type":"blob","sha":"cfgsame"}]'; exit 0 ;;
  esac
fi
exec "$BIN/gh" "\$@"
EOF
chmod +x "$WORK/stub-cr-carried.sh" "$WORK/cf-bin/gh"
WRAPPER_LOG="$WORK/wrapper-carried.log"
WRAPPER_BODY="$WORK/wrapper-carried-body.md"
WRAPPER_PAYLOAD="$WORK/wrapper-carried-payload.json"
: >"$WORK/stub-fp-e2e.log"
set +e
out="$(env PATH="$WORK/cf-bin:$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_CODERABBIT_WAIT="$WORK/stub-cr-carried.sh" P4B_EXTERNAL_REVIEW_FINGERPRINT="$WORK/stub-fp.sh" \
  P4B_TEST_FP_LOG="$WORK/stub-fp-e2e.log" P4B_TEST_FP_abc123=external-review:v2:same "P4B_TEST_FP_$_L=external-review:v2:same" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" P4B_WRAPPER_LOG="$WRAPPER_LOG" P4B_WRAPPER_BODY="$WRAPPER_BODY" P4B_WRAPPER_PAYLOAD="$WRAPPER_PAYLOAD" P4B_FAKE_LIVE_HEAD=abc123 \
  bash "$ORCH" 1335 --repo o/r --author claude --head abc123 --diff-file "$DIFF" 2>"$WORK/carried-e2e.err")"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && jq -e '.commit_id == "abc123" and .event == "APPROVE"' "$WRAPPER_PAYLOAD" >/dev/null 2>&1 \
   && grep -qF -- "its review of \`$_L\` carries forward because the external-review fingerprint is unchanged (\`external-review:v2:same\`) (#1335)" "$WRAPPER_BODY" \
   && grep -qF -- "CodeRabbit did not re-review abc123" "$WORK/carried-e2e.err" \
   && ! grep -q -- "rate limited" "$WRAPPER_BODY"; then
  pass "#1335: an approval over a carried CodeRabbit records the source commit and fingerprint in its Review Metadata"
else fail "#1335 carried-approval metadata (rc=$rc, out=$out, body=$(test -e "$WRAPPER_BODY" && cat "$WRAPPER_BODY" || true), err=$(tail -20 "$WORK/carried-e2e.err" 2>/dev/null || true))"; fi

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
  PATH="$WORK/barrier-bin:$PATH" \
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

# #1305 orchestrator contract: cap exhaustion has its own terminal exit and
# cannot dispatch the adapter or render the authority-bearing Phase 4b handoff.
cat >"$WORK/policy-cap-stop.yml" <<'EOF'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
coderabbit:
  enabled: false
codex:
  enabled: true
  max_review_rounds: 0
EOF
: >"$HANDOFF_LOG"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_TEST_LIVE_HEAD="$_p4a_head" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" \
  PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 8 ] \
   && [ "$(printf '%s' "$out" | jq -r '.human_tiebreaker_required')" = true ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = false ] \
   && [ ! -s "$HANDOFF_LOG" ]; then
  pass "#1305: cap exhaustion exits 8 for a human tiebreaker without adapter dispatch or Phase 4b handoff"
else
  fail "#1305: orchestrator cap stop wrong (rc=$rc handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out"
fi

cat >"$WORK/policy-cap-final-wait.yml" <<'EOF'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
coderabbit:
  enabled: false
  max_wait_seconds: 0
codex:
  enabled: true
  max_review_rounds: 2
  reaction_freshness_window_seconds: 1800
EOF
: >"$HANDOFF_LOG"
set +e
out="$(MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-final-wait.yml" \
  P4B_TEST_COMMENTS_JSON="$_cap_final" P4B_TEST_LIVE_HEAD="$_p4a_head" \
  P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" \
  PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 8 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-cap-final-wait-exhausted ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = false ] \
   && [ ! -s "$HANDOFF_LOG" ]; then
  pass "#1305: final-request wait exhaustion also exits 8 without adapter dispatch or Phase 4b handoff"
else
  fail "#1305: final-request exhaustion stop wrong (rc=$rc handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out"
fi

# Missing/non-executable adapters cannot skip cap authority checks, but the
# fallback check must not probe or spend CodeRabbit allowance. Below the cap
# the existing manual infrastructure fallback remains available.
cat >"$WORK/cap-fallback-cr.sh" <<'EOF'
#!/usr/bin/env bash
echo invoked >>"$P4B_TEST_CR_PROBE_LOG"
exit 3
EOF
chmod +x "$WORK/cap-fallback-cr.sh"
mkdir -p "$WORK/cap-no-adapter" "$WORK/cap-nonexec-adapter"
printf '#!/usr/bin/env bash\nexit 99\n' >"$WORK/cap-nonexec-adapter/review-via-codex.sh"
chmod 644 "$WORK/cap-nonexec-adapter/review-via-codex.sh"
for _case in exhausted pending expired available; do
  _cfg="$WORK/cap-fallback-$_case.yml"
  _comments='[]'
  _adapter_dir="$WORK/cap-no-adapter"
  case "$_case" in
    exhausted) cp "$WORK/policy-cap-stop.yml" "$_cfg"; _expected=8 ;;
    pending)
      sed 's/max_wait_seconds: 0/max_wait_seconds: 100/' "$WORK/policy-cap-final-wait.yml" >"$_cfg"
      _comments="$_cap_final"; _expected=6
      _adapter_dir="$WORK/cap-nonexec-adapter"
      ;;
    expired) cp "$WORK/policy-cap-final-wait.yml" "$_cfg"; _comments="$_cap_final"; _expected=8 ;;
    available) sed 's/max_review_rounds: 0/max_review_rounds: 3/' "$WORK/policy-cap-stop.yml" >"$_cfg"; _expected=4 ;;
  esac
  sed 's/enabled: false/enabled: true/' "$_cfg" >"$_cfg.cr"
  : >"$HANDOFF_LOG"
  : >"$WORK/cap-fallback-cr.log"
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  set +e
  out="$(MERGEPATH_REVIEW_POLICY_PATH="$_cfg.cr" P4B_ADAPTER_DIR="$_adapter_dir" \
    P4B_TEST_COMMENTS_JSON="$_comments" P4B_TEST_LIVE_HEAD="$_p4a_head" \
    P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
    P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
    P4B_CODERABBIT_WAIT="$WORK/cap-fallback-cr.sh" P4B_TEST_CR_PROBE_LOG="$WORK/cap-fallback-cr.log" \
    P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
    P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" \
    PATH="$WORK/barrier-bin:$PATH" \
    bash "$ORCH" 7 --repo owner/repo --author claude --reviewer nathanpayne-codex --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/cap-fallback-stderr.log")"; rc=$?
  set -e
  if [ "$rc" = "$_expected" ] && [ ! -s "$WORK/cap-fallback-cr.log" ] \
     && { { [ "$_case" = available ] && [ -s "$HANDOFF_LOG" ]; } \
          || { [ "$_case" != available ] && [ ! -s "$HANDOFF_LOG" ]; }; }; then
    pass "#1305: unavailable adapter preserves $_case cap routing without CodeRabbit calls"
  else
    fail "#1305: unavailable adapter $_case (rc=$rc expected=$_expected): $out $(cat "$WORK/cap-fallback-stderr.log")"
  fi
done

# #1560 slice 3 at the orchestrator. With no adapter, a spent ceiling with no
# human stop renders the manual handoff (exit 4) instead of exit 8. With an
# adapter, a human stop that appears while the adapter runs is caught by the
# post-adapter recheck (acceptance condition 2): exit 8, nothing posted.
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=clear MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" P4B_ADAPTER_DIR="$WORK/cap-no-adapter" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --reviewer nathanpayne-codex --head "$_p4a_head" --diff-file "$DIFF" 2>/dev/null </dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] && [ -s "$HANDOFF_LOG" ] && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual')" = true ]; then
  pass "#1560 S3-4: with no adapter, a spent ceiling with no human stop renders the manual handoff, not exit 8"
else
  fail "#1560 S3-4: no-adapter clear ceiling (rc=$rc handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out"
fi

# The no-adapter fallback rechecks the waived ceiling before rendering the
# handoff (#1579): a stop that appears after the cap-only barrier exits 8.
_ceiling_count="$WORK/ceiling-flip-fallback.count"
rm -f "$_ceiling_count"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=flip P4B_TEST_LEDGER_COUNT="$_ceiling_count" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" P4B_ADAPTER_DIR="$WORK/cap-no-adapter" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --reviewer nathanpayne-codex --head "$_p4a_head" --diff-file "$DIFF" 2>/dev/null </dev/null)"; rc=$?
set -e
if [ "$rc" = 8 ] && [ ! -s "$HANDOFF_LOG" ] && [ "$(cat "$_ceiling_count")" -ge 2 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-ceiling-human-stop ]; then
  pass "#1560 S3-4: with no adapter, a stop that appears before the handoff is rendered exits 8 instead"
else
  fail "#1560 S3-4: no-adapter fallback ceiling recheck (rc=$rc ledger-calls=$(cat "$_ceiling_count" 2>/dev/null) handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out"
fi

# A new exact author request posted while the adapter runs changes the request
# generation; the post-adapter recheck refuses the stale ceiling authority with
# exit 10 so the next run enters the bounded final-request wait (#1579). The
# fake adapter moves the comments counter past the switch point, so every read
# after it sees the new request.
_gen_race="$WORK/ceiling-generation-race.count"
cat >"$BIN/fake-codex-ceiling-new-request" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '1000\n' >"$_gen_race"
printf '%s' '{"verdict":"APPROVED","summary":"ceiling review","findings":[]}'
EOF
chmod +x "$BIN/fake-codex-ceiling-new-request"
_gen_after=$(jq -nc --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[{id:9301,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:$now}]')
rm -f "$_gen_race"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=clear MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-new-request" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_COMMENTS_RACE_FILE="$_gen_race" P4B_TEST_COMMENTS_CHANGE_AFTER=1000 P4B_TEST_COMMENTS_FAIL_AFTER=1000000 P4B_TEST_COMMENTS_JSON_AFTER="$_gen_after" \
  P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-gen.err" </dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = false ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-ceiling-authority-changed ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.state')" = final-request-pending ] \
   && [ ! -s "$HANDOFF_LOG" ]; then
  pass "#1560 S3-4: a new final request posted during the adapter run voids the ceiling authority (exit 10, nothing posted)"
else
  fail "#1560 S3-4: request generation change during the adapter run (rc=$rc reads=$(cat "$_gen_race" 2>/dev/null)): $out $(tail -3 "$WORK/ceiling-gen.err")"
fi

# A request that lands DURING the recheck's human-stop read is caught by the
# budget read that follows it (#1579): the recheck reads stops first, budget last.
# The approving fake adapter is defined BEFORE the sweep (CodeRabbit on #1579):
# with it missing, every placement would exercise the adapter-failure path
# instead of a review that would otherwise post.
_ceiling_adapter="$WORK/ceiling-adapter.log"
cat >"$BIN/fake-codex-ceiling-approve" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'adapter-ran\n' >"$_ceiling_adapter"
printf '%s' '{"verdict":"APPROVED","summary":"ceiling review","findings":[]}'
EOF
chmod +x "$BIN/fake-codex-ceiling-approve"

# #1583: a request landing during the PRE-DISPATCH recheck's stop read (the
# 2nd ledger read, after the barrier's) holds with exit 6 and spends no
# adapter run; the next run enters that request's bounded wait.
_bump_count="$WORK/ceiling-bump.count"
rm -f "$_gen_race" "$_bump_count" "$_ceiling_adapter"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=bump P4B_TEST_LEDGER_BUMP_AT=2 P4B_TEST_LEDGER_COUNT="$_bump_count" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-approve" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_COMMENTS_RACE_FILE="$_gen_race" P4B_TEST_COMMENTS_CHANGE_AFTER=1000 P4B_TEST_COMMENTS_FAIL_AFTER=1000000 P4B_TEST_COMMENTS_JSON_AFTER="$_gen_after" \
  P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-bump.err" </dev/null)"; rc=$?
set -e
if [ "$rc" = 6 ] && [ ! -s "$_ceiling_adapter" ] && [ ! -s "$HANDOFF_LOG" ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier_pending')" = true ]; then
  pass "#1583: a request that lands before adapter dispatch holds (exit 6) and spends no adapter run"
else
  fail "#1583: pre-dispatch generation change (rc=$rc adapter=$(cat "$_ceiling_adapter" 2>/dev/null) ledger-calls=$(cat "$_bump_count" 2>/dev/null)): $(printf '%s' "$out" | jq -c . 2>/dev/null) $(tail -8 "$WORK/ceiling-bump.err" | tr '\n' ' ')"
fi

# ...but only a genuinely pending replacement holds (#1584 Codex P2). A
# generation change whose fresh state is NOT final-request-pending (here an
# old request outside the freshness window: exhausted, nothing to wait on)
# takes the authority-error path, exit 10, still before any adapter run.
_gen_after_old=$(jq -nc '[{id:9302,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-07-01T00:00:00Z"}]')
rm -f "$_gen_race" "$_bump_count" "$_ceiling_adapter"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=bump P4B_TEST_LEDGER_BUMP_AT=2 P4B_TEST_LEDGER_COUNT="$_bump_count" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-approve" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_COMMENTS_RACE_FILE="$_gen_race" P4B_TEST_COMMENTS_CHANGE_AFTER=1000 P4B_TEST_COMMENTS_FAIL_AFTER=1000000 P4B_TEST_COMMENTS_JSON_AFTER="$_gen_after_old" \
  P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-bump.err" </dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] && [ ! -s "$_ceiling_adapter" ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.state')" = exhausted ]; then
  pass "#1583: a generation change with nothing pending (exhausted) exits 10 before dispatch, not a hold"
else
  fail "#1583: non-pending generation change before dispatch (rc=$rc adapter=$(cat "$_ceiling_adapter" 2>/dev/null)): $(printf '%s' "$out" | jq -c . 2>/dev/null) $(tail -4 "$WORK/ceiling-bump.err" | tr '\n' ' ')"
fi

# The request lands during the Nth ledger read, i.e. the stop read of each
# recheck in turn. Every recheck reads stops first and the budget last, so
# every placement must exit 10; under a budget-first order the bump during the
# final recheck slips past it. The sweep ends when N passes the run's last
# ledger read (the bump never fires).
_bump_count="$WORK/ceiling-bump.count"
_bump_bad=""; _bump_fired=0
for _bump_at in 3 4 5 6 7 8 9; do
  rm -f "$_gen_race" "$_bump_count"
  : >"$HANDOFF_LOG"
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  set +e
  out="$(P4B_TEST_LEDGER_MODE=bump P4B_TEST_LEDGER_BUMP_AT="$_bump_at" P4B_TEST_LEDGER_COUNT="$_bump_count" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-approve" \
    P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_COMMENTS_RACE_FILE="$_gen_race" P4B_TEST_COMMENTS_CHANGE_AFTER=1000 P4B_TEST_COMMENTS_FAIL_AFTER=1000000 P4B_TEST_COMMENTS_JSON_AFTER="$_gen_after" \
    P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
    P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
    P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
    bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-bump.err" </dev/null)"; rc=$?
  set -e
  [ "$(cat "$_bump_count" 2>/dev/null || printf 0)" -ge "$_bump_at" ] || break
  _bump_fired=$((_bump_fired + 1))
  # The adapter ran: this placement is a real approve path, not a failure.
  [ -s "$_ceiling_adapter" ] && rm -f "$_ceiling_adapter" || _bump_bad="$_bump_bad at-read-$_bump_at(adapter-did-not-run)"
  [ "$rc" = 10 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = false ] \
    && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-ceiling-authority-changed ] \
    && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.state')" = final-request-pending ] \
    || _bump_bad="$_bump_bad at-read-$_bump_at(rc=$rc,budget=$(printf '%s' "$out" | jq -r '.barrier.request_budget.state // "?"' 2>/dev/null))"
done
# Three rechecks follow the adapter (post-adapter, and the early and final
# pre-post fences); each must have been swept.
if [ -z "$_bump_bad" ] && [ "$_bump_fired" -ge 3 ]; then
  pass "#1560 S3-4: a request that lands during any recheck's stop read is caught by the budget read after it (exit 10; $_bump_fired placements)"
else
  fail "#1560 S3-4: request during a recheck's stop read slipped through or the sweep was partial (fired=$_bump_fired):${_bump_bad:- none}"
fi

# P1a (#1579 Phase 4b): the PR is retargeted while the adapter runs. Both
# fresh reads agree with each other (new base), so only the comparison with
# the barrier's saved snapshot catches it: exit 10, nothing posted.
_base_race="$WORK/ceiling-base-race.count"
cat >"$BIN/fake-codex-ceiling-retarget" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '1000\n' >"$_base_race"
printf '%s' '{"verdict":"APPROVED","summary":"ceiling review","findings":[]}'
EOF
chmod +x "$BIN/fake-codex-ceiling-retarget"
rm -f "$_base_race"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=clear MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-retarget" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_BASE_RACE_FILE="$_base_race" P4B_TEST_BASE_RACE_AFTER=1000 \
  P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-retarget.err" </dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] && [ "$(printf '%s' "$out" | jq -r '.review_posted')" = false ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-ceiling-authority-changed ]; then
  pass "#1560 S3-4: a PR retargeted during the adapter run voids the ceiling authority against the barrier snapshot (exit 10)"
else
  fail "#1560 S3-4: retarget during the adapter run (rc=$rc base-reads=$(cat "$_base_race" 2>/dev/null)): $out $(tail -3 "$WORK/ceiling-retarget.err")"
fi

# P1c (#1579 Phase 4b): a waived spent ceiling that ESCALATES (here because
# allow_phase_4b_substitute=false) still rechecks the ceiling before the
# manual handoff: a stop that appears meanwhile exits 8, not 4.
sed 's/^  max_review_rounds: 0$/  max_review_rounds: 0\
  allow_phase_4b_substitute: false/' "$WORK/policy-cap-stop.yml" >"$WORK/policy-cap-stop-nosub.yml"
grep -q '^  allow_phase_4b_substitute: false$' "$WORK/policy-cap-stop-nosub.yml" \
  || fail "#1560 S3-4: nosub orchestrator fixture is malformed"
_esc_count="$WORK/ceiling-escalate.count"
rm -f "$_esc_count"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=flip P4B_TEST_LEDGER_COUNT="$_esc_count" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop-nosub.yml" CODEX_BIN="$BIN/fake-codex-ceiling-approve" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-escalate.err" </dev/null)"; rc=$?
set -e
if [ "$rc" = 8 ] && [ ! -s "$HANDOFF_LOG" ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-ceiling-human-stop ]; then
  pass "#1560 S3-4: an escalated spent-ceiling waiver rechecks before the manual handoff; a new stop exits 8, not 4"
else
  fail "#1560 S3-4: escalated waiver handoff recheck (rc=$rc ledger-calls=$(cat "$_esc_count" 2>/dev/null) handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out $(tail -3 "$WORK/ceiling-escalate.err")"
fi

_ceiling_count="$WORK/ceiling-flip.count"
_ceiling_adapter="$WORK/ceiling-adapter.log"
rm -f "$_ceiling_count" "$_ceiling_adapter"
: >"$HANDOFF_LOG"
rm -rf "$WORK/barrier-state/phase-4b-barrier"
set +e
out="$(P4B_TEST_LEDGER_MODE=flip P4B_TEST_LEDGER_FLIP_AT=3 P4B_TEST_LEDGER_COUNT="$_ceiling_count" \
  MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-approve" \
  P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
  bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/ceiling-flip.err" </dev/null)"; rc=$?
set -e
if [ "$rc" = 8 ] && [ -s "$_ceiling_adapter" ] && [ ! -s "$HANDOFF_LOG" ] \
   && [ "$(cat "$_ceiling_count")" = 3 ] \
   && printf '%s' "$out" | jq -e '.human_tiebreaker_required == true and .review_posted == false
        and .barrier.codex_evidence == "request-ceiling-human-stop" and .barrier.human_stops.stops == ["untested-rebuttal"]' >/dev/null 2>&1; then
  pass "#1560 S3-4: a human stop that appears during the adapter run is caught after the adapter and exits 8 with nothing posted"
else
  fail "#1560 S3-4: post-adapter ceiling recheck (rc=$rc adapter=$(cat "$_ceiling_adapter" 2>/dev/null) ledger-calls=$(cat "$_ceiling_count" 2>/dev/null) handoff='$(cat "$HANDOFF_LOG" 2>/dev/null)'): $out $(tail -3 "$WORK/ceiling-flip.err")"
fi

# #1581: feedback that becomes unaccounted while the adapter runs refuses the
# approval at the writer boundary (the 2nd accounting call, after the one
# before dispatch): exit 7, adapter ran, nothing posted.
_acct_count="$WORK/acct-late.count"
cat >"$WORK/acct-late.sh" <<'EOF'
#!/usr/bin/env bash
n=0
[ ! -f "$P4B_TEST_ACCT_COUNT" ] || n=$(cat "$P4B_TEST_ACCT_COUNT")
n=$((n + 1)); printf '%s\n' "$n" >"$P4B_TEST_ACCT_COUNT"
if [ "$n" -ge "${P4B_TEST_ACCT_FAIL_AT:-999}" ]; then
  printf '{"feedback_policy":{},"findings":[],"missing":[{"kind":"inline","finding_id":1}]}\n'
  exit 1
fi
printf '{"feedback_policy":{},"findings":[],"missing":[]}\n'
EOF
chmod +x "$WORK/acct-late.sh"
# Call 2 is the writer-boundary read before the final authority fence; call 3
# is the read after it, so a finding that lands during the final (slow) Codex
# ledger rebuild still refuses the approval (#1584 Phase 4b P1).
for _acct_at in 2 3; do
  rm -f "$_acct_count" "$_ceiling_adapter"
  : >"$HANDOFF_LOG"
  rm -rf "$WORK/barrier-state/phase-4b-barrier"
  set +e
  out="$(P4B_TEST_LEDGER_MODE=clear MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORK/acct-late.sh" \
    P4B_TEST_ACCT_COUNT="$_acct_count" P4B_TEST_ACCT_FAIL_AT="$_acct_at" \
    MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-stop.yml" CODEX_BIN="$BIN/fake-codex-ceiling-approve" \
    P4B_TEST_COMMENTS_JSON='[]' P4B_TEST_LIVE_HEAD="$_p4a_head" P4B_TEST_COMMIT_DATE='2026-08-01T00:00:00Z' \
    P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
    P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$HANDOFF_LOG" PATH="$WORK/barrier-bin:$PATH" \
    bash "$ORCH" 7 --repo owner/repo --author claude --head "$_p4a_head" --diff-file "$DIFF" 2>"$WORK/acct-late.err" </dev/null)"; rc=$?
  set -e
  if [ "$rc" = 7 ] && [ -s "$_ceiling_adapter" ] && [ ! -s "$HANDOFF_LOG" ] \
     && [ "$(cat "$_acct_count")" = "$_acct_at" ] \
     && ! grep -q 'REGRESSION: reviewer wrapper invoked' "$WORK/acct-late.err"; then
    pass "#1581: feedback unaccounted at accounting call $_acct_at (after the adapter ran) refuses the approval with exit 7, nothing posted"
  else
    fail "#1581: late feedback at accounting call $_acct_at (rc=$rc calls=$(cat "$_acct_count" 2>/dev/null) adapter=$(cat "$_ceiling_adapter" 2>/dev/null)): $(tail -4 "$WORK/acct-late.err")"
  fi
done

# A pre-side-effect hold must leave NO accounting trace. Evaluate the full
# barrier once before the adapter, then revalidate only a timeout-derived Codex
# waiver immediately afterward. A second targeted recheck belongs immediately
# before the final live-head fence and review POST; it owns explicit cleanup
# for the accounting/issues that necessarily precede it. Neither targeted read
# re-probes CodeRabbit.
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
_n_timeout_recheck="$(grep -c '^  revalidate_phase4a_timeout_generation ' "$ORCH" || true)"
_full_barrier_line="$(grep -n 'run_same_head_barrier "pre-adapter"' "$ORCH" | cut -d: -f1)"
_cap_guard_line="$(grep -n 'run_same_head_barrier "pre-fallback" cap-only' "$ORCH" | cut -d: -f1)"
_missing_adapter_line="$(grep -n 'fall_back_to_manual "no adapter for reviewer' "$ORCH" | cut -d: -f1)"
_adapter_line="$(grep -n 'VERDICT_JSON="$(p4b_run_with_timeout ' "$ORCH" | cut -d: -f1)"
_budget_post_adapter_line="$(grep -n '^  revalidate_codex_request_budget_authority post-adapter$' "$ORCH" | cut -d: -f1)"
_adapter_rc_line="$(grep -n '^if \[ "\$ADAPTER_RC" -ne 0 \]; then$' "$ORCH" | cut -d: -f1)"
_validate_line="$(grep -n '^if ! p4b_validate_verdict ' "$ORCH" | cut -d: -f1)"
_post_adapter_line="$(grep -n '^  revalidate_phase4a_timeout_generation post-adapter$' "$ORCH" | cut -d: -f1)"
_issue_line="$(grep -n '^[[:space:]]*_pri_out="$(p4b_file_post_review_issues ' "$ORCH" | cut -d: -f1)"
_first_loop_line="$(grep -n '^[[:space:]]*if p4b_acct_hook_record_loop ' "$ORCH" | head -1 | cut -d: -f1)"
_budget_fallback_line="$(grep -n '^  revalidate_codex_request_budget_authority pre-post$' "$ORCH" | head -1 | cut -d: -f1)"
_feedback_fallback_line="$(grep -n '^  require_feedback_accounted$' "$ORCH" | head -1 | cut -d: -f1)"
_fallback_accounting_line="$(grep -n '^[[:space:]]*p4b_acct_hook_note_fallback ' "$ORCH" | head -1 | cut -d: -f1)"
_budget_fallback_final_line="$(grep -n '^  revalidate_codex_request_budget_authority pre-post$' "$ORCH" | sed -n '2p' | cut -d: -f1)"
_handoff_capture_line="$(grep -n '^[[:space:]]*handoff_output=$(PHASE_4B_REVIEWER_IDENTITY=' "$ORCH" | cut -d: -f1)"
_fallback_warn_line="$(grep -n '^  p4b_warn "falling back to the manual Phase 4b handoff:' "$ORCH" | cut -d: -f1)"
_handoff_case_line="$(grep -n '^    case "\$handoff_rc" in$' "$ORCH" | cut -d: -f1)"
_fallback_json_line="$(grep -n '^  jq -n --argjson pr "\$PR" --arg repo "\$REPO" --arg head ' "$ORCH" | head -1 | cut -d: -f1)"
_budget_pre_post_line="$(grep -n '^  revalidate_codex_request_budget_authority pre-post$' "$ORCH" | tail -1 | cut -d: -f1)"
_budget_pre_post_early_line="$(grep -n '^  revalidate_codex_request_budget_authority pre-post$' "$ORCH" | sed -n '3p' | cut -d: -f1)"
_pre_post_line="$(grep -n '^  revalidate_phase4a_timeout_generation pre-post$' "$ORCH" | cut -d: -f1)"
_live_head_line="$(grep -n '^  live_head="$(gh_api_scalar --shape sha "live PR head for ' "$ORCH" | tail -1 | cut -d: -f1)"
_base_fence_line="$(grep -n '^  if ! revalidate_expected_base pre-post; then$' "$ORCH" | cut -d: -f1)"
_payload_line="$(grep -n '^  payload_file="$(mktemp ' "$ORCH" | cut -d: -f1)"
if [ "$n_eval" = "1" ] && [ "$n_call" = "2" ] && [ "$_n_timeout_recheck" = "2" ] \
   && [ "$_cap_guard_line" -lt "$_missing_adapter_line" ] \
   && [ "$_full_barrier_line" -lt "$_adapter_line" ] \
   && [ "$_adapter_line" -lt "$_budget_post_adapter_line" ] \
   && [ "$_budget_post_adapter_line" -lt "$_adapter_rc_line" ] \
   && [ "$_adapter_rc_line" -lt "$_validate_line" ] \
   && [ "$_validate_line" -lt "$_post_adapter_line" ] \
   && [ "$_post_adapter_line" -lt "$_issue_line" ] \
   && [ "$_post_adapter_line" -lt "$_first_loop_line" ] \
   && [ "$_budget_fallback_line" -lt "$_feedback_fallback_line" ] \
   && [ "$_feedback_fallback_line" -lt "$_fallback_accounting_line" ] \
   && [ "$_fallback_accounting_line" -lt "$_handoff_capture_line" ] \
   && [ "$_handoff_capture_line" -lt "$_budget_fallback_final_line" ] \
   && [ "$_budget_fallback_final_line" -lt "$_fallback_warn_line" ] \
   && [ "$_fallback_warn_line" -lt "$_handoff_case_line" ] \
   && [ "$_handoff_case_line" -lt "$_fallback_json_line" ] \
   && [ "$_issue_line" -lt "$_budget_pre_post_early_line" ] \
   && [ "$_first_loop_line" -lt "$_budget_pre_post_early_line" ] \
   && [ "$_budget_pre_post_early_line" -lt "$_pre_post_line" ] \
   && [ "$_issue_line" -lt "$_pre_post_line" ] \
   && [ "$_first_loop_line" -lt "$_pre_post_line" ] \
   && [ "$_pre_post_line" -lt "$_live_head_line" ] \
   && [ "$_live_head_line" -lt "$_base_fence_line" ] \
   && [ "$_base_fence_line" -lt "$_budget_pre_post_line" ] \
   && [ "$_budget_pre_post_line" -lt "$_payload_line" ] \
   && [ "$_live_head_line" -lt "$_payload_line" ]; then
  pass "#814/#1085/#1305: full barrier precedes the adapter; targeted authority reads fence adapter exits, fallback, side effects, and review POST"
else
  fail "#814/#1085/#1305: barrier/recheck ordering drifted (barrier=$_full_barrier_line adapter=$_adapter_line budget-post=$_budget_post_adapter_line rc=$_adapter_rc_line validate=$_validate_line timeout-post=$_post_adapter_line fallback-budget=$_budget_fallback_line fallback-feedback=$_feedback_fallback_line fallback-accounting=$_fallback_accounting_line handoff-capture=$_handoff_capture_line fallback-final=$_budget_fallback_final_line fallback-warn=$_fallback_warn_line handoff-case=$_handoff_case_line fallback-json=$_fallback_json_line issue=$_issue_line loop=$_first_loop_line budget-prepost-early=$_budget_pre_post_early_line timeout-prepost=$_pre_post_line live-head=$_live_head_line base=$_base_fence_line budget-prepost-final=$_budget_pre_post_line payload=$_payload_line; evals=$n_eval calls=$n_call rechecks=$_n_timeout_recheck)"
fi

# Behavioral form of the adapter-window race. The first timeline read carries
# a valid timeout for trigger A, so the pre-adapter barrier opens. The second
# read happens after the adapter and adds trigger B without changing HEAD. The
# obsolete timeout must hold with exit 6 before the reviewer wrapper can post.
_race_head=cccccccccccccccccccccccccccccccccccccccc
_race_marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$_race_head trigger_comment_id=4101 -->"
_race_before="$WORK/race-comments-before.json"
_race_after="$WORK/race-comments-after.json"
_race_count="$WORK/race-comments-count"
_race_wrapper="$WORK/race-wrapper.log"
_race_adapter="$WORK/race-adapter.log"
jq -cn --arg who nathanjohnpayne --arg marker "$_race_marker" '
  [{id:4101,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:00:00Z"},
   {id:4102,user:{login:$who},body:$marker,created_at:"2026-08-30T00:15:00Z"}]' >"$_race_before"
jq -c --arg who nathanjohnpayne \
  '. + [{id:4103,user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"}]' \
  "$_race_before" >"$_race_after"
cat >"$WORK/stub-race-coderabbit.sh" <<EOF
#!/bin/sh
printf '%s' '{"head_sha":"$_race_head","probe":{"mode":true,"observed":"terminal"}}'
EOF
chmod +x "$WORK/stub-race-coderabbit.sh"
cat >"$BIN/fake-codex-race-approve-p2" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'adapter-ran\n' >"$_race_adapter"
printf '%s' '{"verdict":"APPROVED","summary":"advisory only","findings":[{"severity":"P2","path":"x.js","line":2,"body":"race-window advisory"}]}'
EOF
chmod +x "$BIN/fake-codex-race-approve-p2"
rm -f "$_race_count" "$_race_wrapper" "$_race_adapter"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  CODEX_BIN="$BIN/fake-codex-race-approve-p2" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_CODERABBIT_WAIT="$WORK/stub-race-coderabbit.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_WRAPPER_LOG="$_race_wrapper" P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_race_before" P4B_FAKE_COMMENTS_AFTER="$_race_after" \
  P4B_FAKE_COMMENTS_COUNT="$_race_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=2 \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
# Read 1 is the barrier and read 2 the request-generation capture at
# authorization (#1598); the trigger lands after it, in the adapter window.
if [ "$rc" = 6 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = superseded ] \
   && [ "$(cat "$_race_count" 2>/dev/null)" = 3 ] \
   && grep -q '^adapter-ran$' "$_race_adapter" \
   && [ ! -e "$_race_wrapper" ]; then
  pass "#1085: a proven adapter-window Codex trigger retracts the old timeout before the first approval-side effect"
else
  fail "#1085: adapter-window trigger race did not hold safely (rc=$rc reads=$(cat "$_race_count" 2>/dev/null || true) adapter=$(cat "$_race_adapter" 2>/dev/null || true) wrapper=$(test -e "$_race_wrapper" && cat "$_race_wrapper" || true)): $out"
fi

# A second race lands after the post-adapter read, while step-9 filing and
# accounting are in progress. The final pre-POST read must still refuse the
# obsolete waiver, close this run's issue, correct the provisional loop to
# not-posted/fail-closed, discard its staged ledger record, and never invoke
# the reviewer wrapper.
_race_issue_log="$WORK/race-late-issue.log"
_race_acct="$WORK/race-late-acct"
_race_loop="$_race_acct/phase-4b-loops/o-r-pr131.jsonl"
_race_pending="$_race_acct/phase-4b-pending/o-r-pr131.json"
rm -rf "$_race_acct"
rm -f "$_race_count" "$_race_wrapper" "$_race_adapter" "$_race_issue_log" "$_race_issue_log.headreads"
: >"$_race_issue_log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  CODEX_BIN="$BIN/fake-codex-race-approve-p2" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_CODERABBIT_WAIT="$WORK/stub-race-coderabbit.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_WRAPPER_LOG="$_race_wrapper" P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_race_before" P4B_FAKE_COMMENTS_AFTER="$_race_after" \
  P4B_FAKE_COMMENTS_COUNT="$_race_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=3 \
  P4B_ISSUE_LOG="$_race_issue_log" P4B_ACCT_STATE_DIR="$_race_acct" \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 6 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = superseded ] \
   && [ "$(cat "$_race_count" 2>/dev/null)" = 4 ] \
   && grep -q '^adapter-ran$' "$_race_adapter" \
   && grep -q '^ARGV ' "$_race_issue_log" \
   && grep -q '^CLOSE #901$' "$_race_issue_log" \
   && [ "$(jq -sr 'last.loop.posted' "$_race_loop" 2>/dev/null)" = "not-posted" ] \
   && [ "$(jq -sr 'last.loop.fail_closed.happened' "$_race_loop" 2>/dev/null)" = "true" ] \
   && [ ! -e "$_race_pending" ] \
   && [ ! -e "$_race_wrapper" ]; then
  pass "#1085: a pre-POST trigger retracts the old timeout and cleans filed issues plus provisional accounting before holding"
else
  fail "#1085: pre-POST trigger race did not cleanly hold (rc=$rc reads=$(cat "$_race_count" 2>/dev/null || true) issue-log=$(tr '\n' ' ' <"$_race_issue_log" 2>/dev/null || true) loop=$(cat "$_race_loop" 2>/dev/null || true) wrapper=$(test -e "$_race_wrapper" && cat "$_race_wrapper" || true)): $out"
fi

# #1598 on the Phase 4a timeout route (no request-budget snapshot): a request
# that lands AFTER the timeout's last recheck (read 4) but before the writer's
# generation verification (read 5) was never reviewed. It must not be recorded
# as covered: the writer sees the generation moved since authorization (read 2)
# and refuses the approval (exit 10), closing this run's follow-up, correcting
# the provisional loop and never invoking the reviewer wrapper. Without a new
# request the same run reaches the reviewer wrapper.
for _tr_case in moved unchanged; do
  case "$_tr_case" in
    moved) _tr_switch=4; _tr_reviewer="$WORK/stub-rev-guard.sh" ;;
    *) _tr_switch=99; _tr_reviewer="$BIN/fake-gh-as-reviewer" ;;
  esac
  _tr_body="$WORK/timeout-record-body.txt"; rm -f "$_tr_body"
  rm -rf "$_race_acct"
  rm -f "$_race_count" "$_race_wrapper" "$_race_adapter" "$_race_issue_log" "$_race_issue_log.headreads"
  : >"$_race_issue_log"
  set +e
  out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
    CODEX_BIN="$BIN/fake-codex-race-approve-p2" \
    P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
    P4B_CODERABBIT_WAIT="$WORK/stub-race-coderabbit.sh" \
    P4B_GH_AS_REVIEWER="$_tr_reviewer" P4B_WRAPPER_BODY="$_tr_body" \
    P4B_TEST_POSTED_REVIEW="$WORK/timeout-record-posted.json" P4B_FAKE_CREATED_REVIEW_HEAD="$_race_head" \
    P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
    P4B_WRAPPER_LOG="$_race_wrapper" P4B_FAKE_LIVE_HEAD="$_race_head" \
    P4B_FAKE_COMMENTS_BEFORE="$_race_before" P4B_FAKE_COMMENTS_AFTER="$_race_after" \
    P4B_FAKE_COMMENTS_COUNT="$_race_count" P4B_FAKE_COMMENTS_SWITCH_AFTER="$_tr_switch" \
    P4B_ISSUE_LOG="$_race_issue_log" P4B_ACCT_STATE_DIR="$_race_acct" \
    bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
  set -e
  _tr_diag="rc=$rc reads=$(cat "$_race_count" 2>/dev/null || true) issue-log=$(tr '\n' ' ' <"$_race_issue_log" 2>/dev/null || true) wrapper=$(test -e "$_race_wrapper" && echo invoked || true)"
  if [ "$_tr_case" = unchanged ]; then
    if [ "$(cat "$_race_count" 2>/dev/null)" = 5 ] && grep -q '^adapter-ran$' "$_race_adapter" && [ -e "$_race_wrapper" ] \
       && grep -qxF '<!-- mergepath-p4b-request-generation: [4101] -->' "$_tr_body"; then
      pass "#1598: on the timeout route an unchanged request generation reaches the review POST, recording [4101]"
    else
      fail "#1598: timeout-route control did not reach the review POST ($_tr_diag): $out"
    fi
    continue
  fi
  if [ "$rc" = 10 ] \
     && [ "$(printf '%s' "$out" | jq -r '.barrier.codex_evidence')" = request-generation-changed ] \
     && [ "$(cat "$_race_count" 2>/dev/null)" = 5 ] \
     && grep -q '^adapter-ran$' "$_race_adapter" \
     && grep -q '^ARGV ' "$_race_issue_log" \
     && grep -q '^CLOSE #901$' "$_race_issue_log" \
     && [ "$(jq -sr 'last.loop.posted' "$_race_loop" 2>/dev/null)" = "not-posted" ] \
     && [ "$(jq -sr 'last.loop.fail_closed.happened' "$_race_loop" 2>/dev/null)" = "true" ] \
     && [ ! -e "$_race_pending" ] \
     && [ ! -e "$_race_wrapper" ]; then
    pass "#1598: on the timeout route a request after the last timeout recheck is refused, never recorded as covered"
  else
    fail "#1598: timeout-route request after authorization ($_tr_diag): $out"
  fi
done
# G1 (timeout route): a request that lands DURING the final accounting read
# (accounting call 3, after the writer's generation verification at read 5)
# is not seen by the run, which posts. The record excludes it ([4101], not
# 4103), so the merge gate holds the approval (revised contract).
cat >"$WORK/acct-timeout-final.sh" <<'EOF'
#!/usr/bin/env bash
n=0
[ ! -f "$P4B_TEST_ACCT_COUNT" ] || n=$(cat "$P4B_TEST_ACCT_COUNT")
n=$((n + 1)); printf '%s\n' "$n" >"$P4B_TEST_ACCT_COUNT"
[ "$n" -ne 3 ] || printf '99\n' >"$P4B_FAKE_COMMENTS_COUNT"
# Report like the default stub, so the post-POST acknowledgment (#1261) sees
# the posted review body as accounted.
if [ -s "${P4B_TEST_POSTED_REVIEW:-}" ]; then
  jq '{feedback_policy:{},findings:[{kind:"review-body",review_id:1,body:.body,accounted:true}],missing:[]}' "$P4B_TEST_POSTED_REVIEW"
else
  printf '{"feedback_policy":{},"findings":[],"missing":[]}\n'
fi
EOF
chmod +x "$WORK/acct-timeout-final.sh"
_g1_body="$WORK/timeout-final-body.txt"; _g1_acct_count="$WORK/timeout-final-acct.count"
rm -rf "$_race_acct"
rm -f "$_race_count" "$_race_wrapper" "$_race_adapter" "$_race_issue_log" "$_race_issue_log.headreads" "$_g1_body" "$_g1_acct_count"
: >"$_race_issue_log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORK/acct-timeout-final.sh" P4B_TEST_ACCT_COUNT="$_g1_acct_count" \
  CODEX_BIN="$BIN/fake-codex-race-approve-p2" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_CODERABBIT_WAIT="$WORK/stub-race-coderabbit.sh" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_WRAPPER_BODY="$_g1_body" \
  P4B_TEST_POSTED_REVIEW="$WORK/timeout-final-posted.json" P4B_FAKE_CREATED_REVIEW_HEAD="$_race_head" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_WRAPPER_LOG="$_race_wrapper" P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_race_before" P4B_FAKE_COMMENTS_AFTER="$_race_after" \
  P4B_FAKE_COMMENTS_COUNT="$_race_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=6 \
  P4B_ISSUE_LOG="$_race_issue_log" P4B_ACCT_STATE_DIR="$_race_acct" \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ -e "$_race_wrapper" ] && [ "$(cat "$_g1_acct_count" 2>/dev/null || echo 0)" -ge 3 ] \
   && [ "$(grep -o '<!-- mergepath-p4b-request-generation: [^>]*-->' "$_g1_body" 2>/dev/null)" = '<!-- mergepath-p4b-request-generation: [4101] -->' ]; then
  pass "#1598 G1: on the timeout route a request during final accounting is posted outside the record [4101]"
else
  fail "#1598 G1: timeout route, request during final accounting (rc=$rc acct=$(cat "$_g1_acct_count" 2>/dev/null) record=$(grep -o 'mergepath-p4b-request-generation: [^ ]*' "$_g1_body" 2>/dev/null)): $out"
fi

# #1305/#1474: an account-blocked Codex with budget remaining may dispatch the
# adapter, but that below-cap snapshot is not permanent authority. A final
# allowed request arriving during the adapter window invalidates approval and
# manual-fallback exits without changing HEAD. Changed authority evidence uses
# exit 10; a clean rerun observes the request and enters the ordinary bounded
# final-request wait.
cat >"$WORK/policy-cap-adapter-race.yml" <<'EOF'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
coderabbit:
  enabled: false
  max_wait_seconds: 100
codex:
  enabled: true
  max_review_rounds: 1
  reaction_freshness_window_seconds: 1800
EOF
cat >"$WORK/stub-cx-blocked.sh" <<'EOF'
#!/bin/sh
exit 2
EOF
cat >"$WORK/stub-budget-reviewer-guard.sh" <<'EOF'
#!/bin/sh
printf 'invoked\n' >"$P4B_BUDGET_REVIEWER_LOG"
exit 9
EOF
mkdir -p "$WORK/budget-bin"
cat >"$WORK/budget-bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = repos/o/r/pulls/131 ]; then
  for a in "\$@"; do
    case "\$a" in
      *'{head_sha:.head.sha'*)
        if [ -n "\${P4B_FAKE_TUPLE_FILE:-}" ] && [ -r "\$P4B_FAKE_TUPLE_FILE" ]; then
          cat "\$P4B_FAKE_TUPLE_FILE"
        else
          jq -nc --arg h "\${P4B_FAKE_LIVE_HEAD:-abc123}" \
            '{head_sha:\$h,base_ref:"main",base_sha:"3333333333333333333333333333333333333333",default_branch:"main"}'
        fi
        exit 0
        ;;
    esac
  done
  if [ -n "\${P4B_FAKE_PREP_FLIP_ARM:-}" ] && [ -e "\$P4B_FAKE_PREP_FLIP_ARM" ] \
     && [ "\$(cat "\${P4B_FAKE_COMMENTS_COUNT:?}" 2>/dev/null || printf 0)" -ge 5 ]; then
    prep_comments="\$(cat "\$P4B_FAKE_COMMENTS_COUNT")"
    cp "\${P4B_FAKE_COMMENTS_AFTER:?}" "\${P4B_FAKE_COMMENTS_BEFORE:?}"
    rm -f "\$P4B_FAKE_PREP_FLIP_ARM"
    printf 'preparation-read-flipped-after-comments-%s\n' "\$prep_comments" \
      >"\${P4B_FAKE_PREP_FLIP_LOG:?}"
  fi
fi
exec "$BIN/gh" "\$@"
EOF
_budget_fail_adapter="$WORK/budget-adapter-failure-adapter.log"
cat >"$BIN/fake-codex-budget-fail" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'adapter-ran\n' >"$_budget_fail_adapter"
exit 9
EOF
chmod +x "$WORK/stub-cx-blocked.sh" "$WORK/stub-budget-reviewer-guard.sh" \
  "$WORK/budget-bin/gh" "$BIN/fake-codex-budget-fail"
_budget_before="$WORK/budget-comments-before.json"
_budget_after="$WORK/budget-comments-after.json"
_budget_unreadable="$WORK/budget-comments-unreadable.json"
_budget_accounting_gate="$WORK/budget-accounting-gate.sh"
_budget_capture_handoff="$WORK/budget-capture-handoff.sh"
printf '[]\n' >"$_budget_before"
jq -nc --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '[{id:7101,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:$now}]' \
  >"$_budget_after"
printf 'not-json\n' >"$_budget_unreadable"
cat >"$_budget_accounting_gate" <<'EOF'
#!/usr/bin/env bash
printf 'accounting-ran\n' >>"${P4B_BUDGET_ACCOUNTING_LOG:?}"
printf '{"feedback_policy":{},"findings":[],"missing":[]}\n'
EOF
chmod +x "$_budget_accounting_gate"
cat >"$_budget_capture_handoff" <<'EOF'
#!/usr/bin/env bash
printf 'helper-ran\n' >"${P4B_HANDOFF_LOG:?}"
if [ "${P4B_HANDOFF_FLIP_TIMELINE:-false}" = true ]; then
  cp "${P4B_FAKE_COMMENTS_AFTER:?}" "${P4B_FAKE_COMMENTS_BEFORE:?}"
fi
printf 'STALE-HANDOFF-MARKER\n'
EOF
chmod +x "$_budget_capture_handoff"

for _budget_outcome in approve adapter-failure unreadable accounting-window-adapter-failure stable-failure; do
  _budget_count="$WORK/budget-${_budget_outcome}-comments.count"
  _budget_adapter="$WORK/budget-${_budget_outcome}-adapter.log"
  _budget_reviewer="$WORK/budget-${_budget_outcome}-reviewer.log"
  _budget_handoff="$WORK/budget-${_budget_outcome}-handoff.log"
  _budget_stderr="$WORK/budget-${_budget_outcome}-stderr.log"
  _budget_accounting="$WORK/budget-${_budget_outcome}-accounting.log"
  _budget_before_path="$WORK/budget-${_budget_outcome}-comments-before.json"
  rm -f "$_budget_count" "$_budget_adapter" "$_budget_reviewer" "$_budget_handoff" \
    "$_budget_stderr" "$_budget_accounting" "$_budget_before_path" "$_budget_fail_adapter"
  cp "$_budget_before" "$_budget_before_path"
  _budget_after_path="$_budget_after"
  _budget_switch_after=3
  _budget_accounting_cmd="$WORK/clear-feedback.sh"
  _budget_handoff_cmd="$BIN/fake-handoff"
  _budget_handoff_flip=false
  case "$_budget_outcome" in
    approve) _budget_codex="$BIN/fake-codex-race-approve-p2" ;;
    adapter-failure) _budget_codex="$BIN/fake-codex-budget-fail"; _budget_adapter="$_budget_fail_adapter" ;;
    unreadable) _budget_codex="$BIN/fake-codex-race-approve-p2"; _budget_after_path="$_budget_unreadable" ;;
    accounting-window-adapter-failure)
      _budget_codex="$BIN/fake-codex-budget-fail"
      _budget_adapter="$_budget_fail_adapter"
      _budget_switch_after=99
      _budget_accounting_cmd="$_budget_accounting_gate"
      _budget_handoff_cmd="$_budget_capture_handoff"
      _budget_handoff_flip=true
      ;;
    stable-failure)
      _budget_codex="$BIN/fake-codex-budget-fail"
      _budget_adapter="$_budget_fail_adapter"
      _budget_after_path="$_budget_before_path"
      _budget_handoff_cmd="$_budget_capture_handoff"
      ;;
  esac
  rm -f "$_race_adapter"
  set +e
  out="$(PATH="$WORK/budget-bin:$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
    CODEX_BIN="$_budget_codex" P4B_BUDGET_ADAPTER_LOG="$_budget_adapter" \
    P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
    P4B_GH_AS_REVIEWER="$WORK/stub-budget-reviewer-guard.sh" \
    P4B_BUDGET_REVIEWER_LOG="$_budget_reviewer" \
    MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$_budget_accounting_cmd" \
    P4B_BUDGET_ACCOUNTING_LOG="$_budget_accounting" \
    P4B_HANDOFF="$_budget_handoff_cmd" P4B_HANDOFF_LOG="$_budget_handoff" \
    P4B_HANDOFF_FLIP_TIMELINE="$_budget_handoff_flip" \
    P4B_FAKE_LIVE_HEAD="$_race_head" \
    P4B_FAKE_COMMENTS_BEFORE="$_budget_before_path" P4B_FAKE_COMMENTS_AFTER="$_budget_after_path" \
    P4B_FAKE_COMMENTS_COUNT="$_budget_count" P4B_FAKE_COMMENTS_SWITCH_AFTER="$_budget_switch_after" \
    bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" \
      2>"$_budget_stderr")"; rc=$?
  set -e
  if [ "$_budget_outcome" = approve ] || [ "$_budget_outcome" = unreadable ]; then
    _budget_adapter_evidence="$(cat "$_race_adapter" 2>/dev/null || true)"
  else
    _budget_adapter_evidence="$(cat "$_budget_adapter" 2>/dev/null || true)"
  fi
  if [ "$_budget_outcome" = accounting-window-adapter-failure ]; then
    if [ "$rc" = 10 ] \
       && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.reason')" = request-generation-changed ] \
       && [ "$(cat "$_budget_count" 2>/dev/null || true)" = 6 ] \
       && [ "$_budget_adapter_evidence" = adapter-ran ] \
       && [ "$(grep -c '^accounting-ran$' "$_budget_accounting" 2>/dev/null || true)" = 2 ] \
       && [ "$(cat "$_budget_handoff" 2>/dev/null || true)" = helper-ran ] \
       && cmp -s "$_budget_before_path" "$_budget_after" \
       && ! grep -q 'STALE-HANDOFF-MARKER' "$_budget_stderr" \
       && ! printf '%s' "$out" | grep -q 'STALE-HANDOFF-MARKER' \
       && [ ! -e "$_budget_reviewer" ] \
       && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual // false')" = false ]; then
      pass "#1474: post-helper generation drift suppresses the captured manual handoff"
    else
      fail "#1474: post-helper authority leak (rc=$rc reads=$(cat "$_budget_count" 2>/dev/null || true) adapter=$_budget_adapter_evidence accounting-calls=$(grep -c '^accounting-ran$' "$_budget_accounting" 2>/dev/null || true) helper=$(cat "$_budget_handoff" 2>/dev/null || true) stderr=$(tr '\n' ' ' <"$_budget_stderr" 2>/dev/null || true) reviewer=$(cat "$_budget_reviewer" 2>/dev/null || true)): $out"
    fi
  elif [ "$_budget_outcome" = stable-failure ]; then
    if [ "$rc" = 4 ] \
       && [ "$(printf '%s' "$out" | jq -r .fell_back_to_manual)" = true ] \
       && [ "$(cat "$_budget_count" 2>/dev/null || true)" = 6 ] \
       && [ "$_budget_adapter_evidence" = adapter-ran ] \
       && [ ! -e "$_budget_reviewer" ] \
       && [ "$(cat "$_budget_handoff" 2>/dev/null || true)" = helper-ran ] \
       && grep -q 'STALE-HANDOFF-MARKER' "$_budget_stderr"; then
      pass "#1305: unchanged below-cap generation publishes the captured manual handoff"
    else
      fail "#1305: stable adapter-failure control changed (rc=$rc reads=$(cat "$_budget_count" 2>/dev/null || true) adapter=$_budget_adapter_evidence reviewer=$(cat "$_budget_reviewer" 2>/dev/null || true) helper=$(cat "$_budget_handoff" 2>/dev/null || true) stderr=$(tr '\n' ' ' <"$_budget_stderr" 2>/dev/null || true)): $out"
    fi
  else
    _budget_expected_reason=request-generation-changed
    [ "$_budget_outcome" != unreadable ] || _budget_expected_reason=request-generation-reread-failed
    if [ "$rc" = 10 ] \
       && [ "$(printf '%s' "$out" | jq -r .infrastructure_error)" = true ] \
       && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.reason')" = "$_budget_expected_reason" ] \
       && [ "$(cat "$_budget_count" 2>/dev/null || true)" = 4 ] \
       && [ "$_budget_adapter_evidence" = adapter-ran ] \
       && [ ! -e "$_budget_reviewer" ] \
       && [ ! -e "$_budget_handoff" ]; then
      pass "#1305: adapter-window $_budget_outcome authority stops on $_budget_expected_reason with exit 10"
    else
      fail "#1305: adapter-window $_budget_outcome authority leak (rc=$rc reads=$(cat "$_budget_count" 2>/dev/null || true) adapter=$_budget_adapter_evidence reviewer=$(cat "$_budget_reviewer" 2>/dev/null || true) handoff=$(cat "$_budget_handoff" 2>/dev/null || true)): $out"
    fi
  fi
done

# The request-generation list can stay byte-for-byte stable while the policy
# authority that made it "available" changes. Exercise both halves of that
# snapshot: the full PR tuple (base advance and retarget) and the semantic
# governing budget (including an unreadable replacement). Every change occurs
# inside an adapter that records its own execution, so exit 10 cannot be an
# earlier barrier refusal.
_budget_tuple_before="$WORK/budget-tuple-before.json"
_budget_tuple_advance="$WORK/budget-tuple-advance.json"
_budget_tuple_retarget="$WORK/budget-tuple-retarget.json"
jq -nc --arg h "$_race_head" \
  '{head_sha:$h,base_ref:"main",base_sha:"3333333333333333333333333333333333333333",default_branch:"main"}' \
  >"$_budget_tuple_before"
jq -nc --arg h "$_race_head" \
  '{head_sha:$h,base_ref:"main",base_sha:"4444444444444444444444444444444444444444",default_branch:"main"}' \
  >"$_budget_tuple_advance"
jq -nc --arg h "$_race_head" \
  '{head_sha:$h,base_ref:"release",base_sha:"3333333333333333333333333333333333333333",default_branch:"main"}' \
  >"$_budget_tuple_retarget"
_budget_policy_before="$WORK/budget-policy-before.yml"
_budget_policy_lowered="$WORK/budget-policy-lowered.yml"
cp "$WORK/policy-cap-adapter-race.yml" "$_budget_policy_before"
sed 's/max_review_rounds: 1/max_review_rounds: 0/' \
  "$WORK/policy-cap-adapter-race.yml" >"$_budget_policy_lowered"

for _budget_policy_case in base-advance retarget lowered-cap unreadable-policy; do
  _budget_case_adapter="$WORK/budget-${_budget_policy_case}-adapter.sh"
  _budget_case_adapter_log="$WORK/budget-${_budget_policy_case}-adapter.log"
  _budget_case_count="$WORK/budget-${_budget_policy_case}-comments.count"
  _budget_case_reviewer="$WORK/budget-${_budget_policy_case}-reviewer.log"
  _budget_case_handoff="$WORK/budget-${_budget_policy_case}-handoff.log"
  _budget_case_tuple="$WORK/budget-${_budget_policy_case}-tuple.json"
  _budget_case_policy="$WORK/budget-${_budget_policy_case}-policy.yml"
  cp "$_budget_tuple_before" "$_budget_case_tuple"
  cp "$_budget_policy_before" "$_budget_case_policy"
  case "$_budget_policy_case" in
    base-advance)
      _budget_case_mutation="cp '$_budget_tuple_advance' '$_budget_case_tuple'"
      _budget_case_reason="pr-policy-tuple-changed"
      ;;
    retarget)
      _budget_case_mutation="cp '$_budget_tuple_retarget' '$_budget_case_tuple'"
      _budget_case_reason="pr-policy-tuple-changed"
      ;;
    lowered-cap)
      _budget_case_mutation="cp '$_budget_policy_lowered' '$_budget_case_policy'"
      _budget_case_reason="governing-budget-changed"
      ;;
    unreadable-policy)
      _budget_case_mutation="rm -f '$_budget_case_policy'"
      _budget_case_reason="governing-policy-unreadable"
      ;;
  esac
  cat >"$_budget_case_adapter" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'adapter-ran\n' >'$_budget_case_adapter_log'
$_budget_case_mutation
printf '%s' '{"verdict":"APPROVED","summary":"stale policy authority must not publish","findings":[]}'
EOF
  chmod +x "$_budget_case_adapter"
  rm -f "$_budget_case_adapter_log" "$_budget_case_count" \
    "$_budget_case_reviewer" "$_budget_case_handoff"
  set +e
  out="$(PATH="$WORK/budget-bin:$BIN:$PATH" \
    MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
    P4B_TEST_BASE_POLICY_PATH="$_budget_case_policy" \
    P4B_FAKE_TUPLE_FILE="$_budget_case_tuple" \
    CODEX_BIN="$_budget_case_adapter" P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
    P4B_GH_AS_REVIEWER="$WORK/stub-budget-reviewer-guard.sh" \
    P4B_BUDGET_REVIEWER_LOG="$_budget_case_reviewer" \
    P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$_budget_case_handoff" \
    P4B_FAKE_LIVE_HEAD="$_race_head" \
    P4B_FAKE_COMMENTS_BEFORE="$_budget_before" P4B_FAKE_COMMENTS_AFTER="$_budget_before" \
    P4B_FAKE_COMMENTS_COUNT="$_budget_case_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=99 \
    bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" \
      2>/dev/null)"; rc=$?
  set -e
  if [ "$rc" = 10 ] \
     && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.reason')" = "$_budget_case_reason" ] \
     && [ "$(cat "$_budget_case_adapter_log" 2>/dev/null || true)" = adapter-ran ] \
     && [ ! -e "$_budget_case_reviewer" ] \
     && [ ! -e "$_budget_case_handoff" ]; then
    pass "#1474: unchanged request generation rejects $_budget_policy_case authority drift after adapter dispatch"
  else
    fail "#1474: $_budget_policy_case authority drift leaked (rc=$rc reads=$(cat "$_budget_case_count" 2>/dev/null || true) adapter=$(cat "$_budget_case_adapter_log" 2>/dev/null || true) reviewer=$(cat "$_budget_case_reviewer" 2>/dev/null || true) handoff=$(cat "$_budget_case_handoff" 2>/dev/null || true)): $out"
  fi
done

# The no-adapter path shares the central fallback writer but skips adapter
# dispatch entirely. Make the handoff helper absent too: the unconditional
# final fence must still refuse fallback JSON after the feedback gate changes
# the request generation.
_budget_missing_count="$WORK/budget-missing-adapter-comments.count"
_budget_missing_accounting="$WORK/budget-missing-adapter-accounting.log"
_budget_missing_handoff="$WORK/budget-missing-adapter-handoff.log"
rm -f "$_budget_missing_count" "$_budget_missing_accounting" "$_budget_missing_handoff"
set +e
out="$(PATH="$WORK/budget-bin:$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
  P4B_ADAPTER_DIR="$WORK/cap-no-adapter" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$_budget_accounting_gate" \
  P4B_BUDGET_ACCOUNTING_LOG="$_budget_missing_accounting" \
  P4B_HANDOFF="$WORK/missing-budget-handoff" P4B_HANDOFF_LOG="$_budget_missing_handoff" \
  P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_budget_before" P4B_FAKE_COMMENTS_AFTER="$_budget_after" \
  P4B_FAKE_COMMENTS_COUNT="$_budget_missing_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=4 \
  bash "$ORCH" 131 --repo o/r --author claude --reviewer nathanpayne-codex \
    --head "$_race_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.reason')" = request-generation-changed ] \
   && [ "$(cat "$_budget_missing_count" 2>/dev/null || true)" = 5 ] \
   && [ "$(grep -c '^accounting-ran$' "$_budget_missing_accounting" 2>/dev/null || true)" = 1 ] \
   && [ "$(printf '%s' "$out" | jq -r '.fell_back_to_manual // false')" = false ] \
   && [ ! -e "$_budget_missing_handoff" ]; then
  pass "#1474: missing helper still rechecks generation before fallback JSON"
else
  fail "#1474: missing-adapter accounting-window authority leak (rc=$rc reads=$(cat "$_budget_missing_count" 2>/dev/null || true) accounting-calls=$(grep -c '^accounting-ran$' "$_budget_missing_accounting" 2>/dev/null || true) handoff=$(cat "$_budget_missing_handoff" 2>/dev/null || true)): $out"
fi

# The same request can land after the first post-adapter fence, while approval
# follow-up issues and provisional accounting are created. The final pre-POST
# fence must refuse it, close this run's issue, correct the loop to not-posted,
# and render neither a review nor a manual handoff.
_budget_count="$WORK/budget-prepost-comments.count"
_budget_reviewer="$WORK/budget-prepost-reviewer.log"
_budget_handoff="$WORK/budget-prepost-handoff.log"
_budget_issue="$WORK/budget-prepost-issue.log"
_budget_acct="$WORK/budget-prepost-acct"
_budget_loop="$_budget_acct/phase-4b-loops/o-r-pr131.jsonl"
_budget_pending="$_budget_acct/phase-4b-pending/o-r-pr131.json"
rm -rf "$_budget_acct"
rm -f "$_budget_count" "$_budget_reviewer" "$_budget_handoff" "$_budget_issue" \
  "$_budget_issue.headreads" "$_race_adapter"
: >"$_budget_issue"
set +e
out="$(PATH="$WORK/budget-bin:$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
  CODEX_BIN="$BIN/fake-codex-race-approve-p2" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-budget-reviewer-guard.sh" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_BUDGET_REVIEWER_LOG="$_budget_reviewer" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$_budget_handoff" \
  P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_budget_before" P4B_FAKE_COMMENTS_AFTER="$_budget_after" \
  P4B_FAKE_COMMENTS_COUNT="$_budget_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=4 \
  P4B_ISSUE_LOG="$_budget_issue" P4B_ACCT_STATE_DIR="$_budget_acct" \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" \
    2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.reason')" = request-generation-changed ] \
   && [ "$(cat "$_budget_count" 2>/dev/null || true)" = 5 ] \
   && grep -q '^ARGV ' "$_budget_issue" \
   && grep -q '^CLOSE #901$' "$_budget_issue" \
   && [ "$(jq -sr 'last.loop.posted' "$_budget_loop" 2>/dev/null)" = not-posted ] \
   && [ "$(jq -sr 'last.loop.fail_closed.happened' "$_budget_loop" 2>/dev/null)" = true ] \
   && [ ! -e "$_budget_pending" ] \
   && [ ! -e "$_budget_reviewer" ] \
   && [ ! -e "$_budget_handoff" ]; then
  pass "#1305: pre-POST request-generation drift cleans filed issues and provisional accounting before exit 10"
else
  fail "#1305: pre-POST request-generation cleanup failed (rc=$rc reads=$(cat "$_budget_count" 2>/dev/null || true) issue=$(tr '\n' ' ' <"$_budget_issue" 2>/dev/null || true) loop=$(cat "$_budget_loop" 2>/dev/null || true) reviewer=$(cat "$_budget_reviewer" 2>/dev/null || true) handoff=$(cat "$_budget_handoff" 2>/dev/null || true)): $out"
fi

# A request can arrive during the final review-material preparation reads,
# after the early pre-POST check. Arm the PR fake from inside the adapter, then
# flip the comments timeline on the later live-head/body/base sequence. Only
# the writer-boundary snapshot check can observe it before the review POST.
_prep_before="$WORK/budget-preparation-comments-before.json"
_prep_count="$WORK/budget-preparation-comments.count"
_prep_arm="$WORK/budget-preparation.arm"
_prep_flip_log="$WORK/budget-preparation-flip.log"
_prep_adapter="$WORK/budget-preparation-adapter.sh"
_prep_adapter_log="$WORK/budget-preparation-adapter.log"
_prep_reviewer="$WORK/budget-preparation-reviewer.log"
_prep_handoff="$WORK/budget-preparation-handoff.log"
_prep_issue="$WORK/budget-preparation-issue.log"
_prep_acct="$WORK/budget-preparation-acct"
_prep_loop="$_prep_acct/phase-4b-loops/o-r-pr131.jsonl"
_prep_pending="$_prep_acct/phase-4b-pending/o-r-pr131.json"
cp "$_budget_before" "$_prep_before"
cat >"$_prep_adapter" <<EOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'adapter-ran\n' >'$_prep_adapter_log'
: >'$_prep_arm'
printf '%s' '{"verdict":"APPROVED","summary":"writer boundary race","findings":[{"severity":"P2","path":"x.js","line":2,"body":"follow-up must be cleaned if authority changes"}]}'
EOF
chmod +x "$_prep_adapter"
rm -rf "$_prep_acct"
rm -f "$_prep_count" "$_prep_arm" "$_prep_flip_log" "$_prep_adapter_log" \
  "$_prep_reviewer" "$_prep_handoff" "$_prep_issue" "$_prep_issue.headreads"
: >"$_prep_issue"
set +e
out="$(PATH="$WORK/budget-bin:$BIN:$PATH" \
  MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
  CODEX_BIN="$_prep_adapter" P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-budget-reviewer-guard.sh" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_BUDGET_REVIEWER_LOG="$_prep_reviewer" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$_prep_handoff" \
  P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_prep_before" P4B_FAKE_COMMENTS_AFTER="$_budget_after" \
  P4B_FAKE_COMMENTS_COUNT="$_prep_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=99 \
  P4B_FAKE_PREP_FLIP_ARM="$_prep_arm" P4B_FAKE_PREP_FLIP_LOG="$_prep_flip_log" \
  P4B_ISSUE_LOG="$_prep_issue" P4B_ACCT_STATE_DIR="$_prep_acct" \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" \
    2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 10 ] \
   && [ "$(printf '%s' "$out" | jq -r '.barrier.request_budget.reason')" = request-generation-changed ] \
   && [ "$(cat "$_prep_count" 2>/dev/null || true)" = 6 ] \
   && [ "$(cat "$_prep_adapter_log" 2>/dev/null || true)" = adapter-ran ] \
   && [ "$(cat "$_prep_flip_log" 2>/dev/null || true)" = preparation-read-flipped-after-comments-5 ] \
   && grep -q '^ARGV ' "$_prep_issue" \
   && grep -q '^CLOSE #901$' "$_prep_issue" \
   && [ "$(jq -sr 'last.loop.posted' "$_prep_loop" 2>/dev/null)" = not-posted ] \
   && [ "$(jq -sr 'last.loop.fail_closed.happened' "$_prep_loop" 2>/dev/null)" = true ] \
   && [ ! -e "$_prep_pending" ] \
   && [ ! -e "$_prep_reviewer" ] \
   && [ ! -e "$_prep_handoff" ]; then
  pass "#1474: final request arriving during review preparation is refused at the writer boundary"
else
  fail "#1474: review-preparation request race leaked (rc=$rc reads=$(cat "$_prep_count" 2>/dev/null || true) flip=$(cat "$_prep_flip_log" 2>/dev/null || true) adapter=$(cat "$_prep_adapter_log" 2>/dev/null || true) issue=$(tr '\n' ' ' <"$_prep_issue" 2>/dev/null || true) loop=$(cat "$_prep_loop" 2>/dev/null || true) reviewer=$(cat "$_prep_reviewer" 2>/dev/null || true)): $out"
fi

# Mutation control for the exact writer-boundary seam above. Run a private
# orchestrator copy with only the final authority call removed; pin its ROOT to
# this checkout so it uses the same trusted libraries and fakes. The prepared
# request change must then reach the fake reviewer wrapper, proving the
# production refusal came from the final fence rather than the early one.
_prep_mutant="$WORK/phase-4b-review-no-final-authority.sh"
awk -v actual_root="$ROOT/scripts" '
  /^ROOT=/ { printf "ROOT=\"%s\"\n", actual_root; next }
  /# The timeout\/head\/body\/base reads above prepare/ { final_block=1 }
  final_block && /^  revalidate_codex_request_budget_authority pre-post$/ {
    removed += 1
    next
  }
  { print }
  END { if (removed != 1) exit 2 }
' "$ORCH" >"$_prep_mutant"
chmod +x "$_prep_mutant"
cp "$_budget_before" "$_prep_before"
rm -rf "$_prep_acct"
rm -f "$_prep_count" "$_prep_arm" "$_prep_flip_log" "$_prep_adapter_log" \
  "$_prep_reviewer" "$_prep_handoff" "$_prep_issue" "$_prep_issue.headreads"
: >"$_prep_issue"
set +e
out="$(PATH="$WORK/budget-bin:$BIN:$PATH" \
  MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
  CODEX_BIN="$_prep_adapter" P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-budget-reviewer-guard.sh" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_BUDGET_REVIEWER_LOG="$_prep_reviewer" \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$_prep_handoff" \
  P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_prep_before" P4B_FAKE_COMMENTS_AFTER="$_budget_after" \
  P4B_FAKE_COMMENTS_COUNT="$_prep_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=99 \
  P4B_FAKE_PREP_FLIP_ARM="$_prep_arm" P4B_FAKE_PREP_FLIP_LOG="$_prep_flip_log" \
  P4B_ISSUE_LOG="$_prep_issue" P4B_ACCT_STATE_DIR="$_prep_acct" \
  bash "$_prep_mutant" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" \
    2>/dev/null)"; rc=$?
set -e
if [ "$rc" != 10 ] \
   && [ "$(cat "$_prep_count" 2>/dev/null || true)" = 5 ] \
   && [ "$(cat "$_prep_adapter_log" 2>/dev/null || true)" = adapter-ran ] \
   && [ "$(cat "$_prep_flip_log" 2>/dev/null || true)" = preparation-read-flipped-after-comments-5 ] \
   && [ "$(cat "$_prep_reviewer" 2>/dev/null || true)" = invoked ]; then
  pass "#1474 mutation: removing only the final authority fence leaks the prepared request change to review POST"
else
  fail "#1474 mutation control did not isolate final writer fence (rc=$rc reads=$(cat "$_prep_count" 2>/dev/null || true) flip=$(cat "$_prep_flip_log" 2>/dev/null || true) adapter=$(cat "$_prep_adapter_log" 2>/dev/null || true) reviewer=$(cat "$_prep_reviewer" 2>/dev/null || true)): $out"
fi

# #1598's exact acceptance case on the writer side: a new author request lands
# DURING the final feedback-accounting read (the 3rd accounting call), after
# the last authority fence. The approval still posts (no read follows the final
# accounting read), but it records the generation it was authorized under,
# which excludes the new request; the substitute merge gate then refuses it
# until Codex answers (tests/test_codex_request_evidence.sh covers the gate).
_rg_count="$WORK/record-gen-comments.count"
_rg_acct_count="$WORK/record-gen-acct.count"
_rg_body="$WORK/record-gen-body.txt"
_rg_issue="$WORK/record-gen-issue.log"
_rg_acct="$WORK/record-gen-acct"
cat >"$WORK/acct-record-gen.sh" <<'EOF'
#!/usr/bin/env bash
n=0
[ ! -f "$P4B_TEST_ACCT_COUNT" ] || n=$(cat "$P4B_TEST_ACCT_COUNT")
n=$((n + 1)); printf '%s\n' "$n" >"$P4B_TEST_ACCT_COUNT"
[ "$n" -ne 3 ] || printf '99\n' >"$P4B_FAKE_COMMENTS_COUNT"
printf '{"feedback_policy":{},"findings":[],"missing":[]}\n'
EOF
chmod +x "$WORK/acct-record-gen.sh"
cat >"$WORK/record-gen-adapter.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s' '{"verdict":"APPROVED","summary":"final accounting race","findings":[]}'
EOF
chmod +x "$WORK/record-gen-adapter.sh"
rm -rf "$_rg_acct"; rm -f "$_rg_count" "$_rg_acct_count" "$_rg_body" "$_rg_issue" "$_rg_issue.headreads"
: >"$_rg_issue"
set +e
out="$(PATH="$WORK/budget-bin:$BIN:$PATH" \
  MERGEPATH_REVIEW_POLICY_PATH="$WORK/policy-cap-adapter-race.yml" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORK/acct-record-gen.sh" P4B_TEST_ACCT_COUNT="$_rg_acct_count" \
  CODEX_BIN="$WORK/record-gen-adapter.sh" P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-blocked.sh" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_WRAPPER_LOG="$WORK/record-gen-wrapper.log" \
  P4B_WRAPPER_BODY="$_rg_body" P4B_TEST_POSTED_REVIEW="$WORK/record-gen-posted.json" \
  P4B_FAKE_CREATED_REVIEW_HEAD="$_race_head" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$WORK/record-gen-handoff.log" \
  P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_budget_before" P4B_FAKE_COMMENTS_AFTER="$_budget_after" \
  P4B_FAKE_COMMENTS_COUNT="$_rg_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=99 \
  P4B_ISSUE_LOG="$_rg_issue" P4B_ACCT_STATE_DIR="$_rg_acct" \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" \
    2>"$WORK/record-gen.err")"; rc=$?
set -e
_rg_recorded=$(sed -n 's/^<!-- mergepath-p4b-request-generation: \(.*\) -->$/\1/p' "$_rg_body" 2>/dev/null)
_rg_live=$(jq -c '[.[] | select(.user.login == "nathanjohnpayne") | .id] | sort' "$_budget_after" 2>/dev/null || true)
if [ "$(cat "$_rg_acct_count" 2>/dev/null || echo 0)" -ge 3 ] \
   && [ "$(cat "$_rg_count" 2>/dev/null || true)" = 99 ] \
   && [ "$rc" = 0 ] && [ -s "$_rg_body" ] \
   && [ "$_rg_recorded" = '[]' ] && [ "$_rg_live" = '[7101]' ]; then
  pass "#1598: a request landing during the final accounting read stays outside the approval's recorded generation"
else
  fail "#1598: recorded generation under the final-accounting race (rc=$rc acct=$(cat "$_rg_acct_count" 2>/dev/null) reads=$(cat "$_rg_count" 2>/dev/null) recorded=$_rg_recorded live=$_rg_live): $out $(tail -3 "$WORK/record-gen.err")"
fi

# Unsafe evidence takes the manual-fallback route rather than a hold. Make the
# fallback's own accounting gate fail on its second invocation to prove the
# final fence corrected local state BEFORE that fallible read: even exit 7
# leaves no phantom posted loop or staged ledger record, and the filed issue is
# still closed before control reaches the failing gate.
_race_malformed_after="$WORK/race-comments-malformed-after.json"
_race_gate="$WORK/race-accounting-gate.sh"
_race_gate_count="$WORK/race-accounting-gate.count"
_race_handoff="$WORK/race-handoff.log"
jq -c --arg who nathanjohnpayne \
  '. + [{id:"bad",user:{login:$who},body:"@codex review",created_at:"2026-08-30T00:16:00Z"}]' \
  "$_race_before" >"$_race_malformed_after"
cat >"$_race_gate" <<'EOF'
#!/bin/sh
count_file="${P4B_RACE_ACCOUNTING_COUNT:?}"
count=$(( $( [ -f "$count_file" ] && cat "$count_file" || echo 0 ) + 1 ))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -eq 1 ]; then
  printf '{}\n'
  exit 0
fi
printf '{"posted":1,"accounted":0}\n'
exit 1
EOF
chmod +x "$_race_gate"
rm -rf "$_race_acct"
rm -f "$_race_count" "$_race_wrapper" "$_race_adapter" "$_race_issue_log" \
  "$_race_issue_log.headreads" "$_race_gate_count" "$_race_handoff"
: >"$_race_issue_log"
set +e
out="$(PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$_race_gate" P4B_RACE_ACCOUNTING_COUNT="$_race_gate_count" \
  CODEX_BIN="$BIN/fake-codex-race-approve-p2" \
  P4B_CODEX_REVIEW_CHECK="$WORK/stub-cx-notyet.sh" \
  P4B_CODERABBIT_WAIT="$WORK/stub-race-coderabbit.sh" \
  P4B_GH_AS_REVIEWER="$WORK/stub-rev-guard.sh" \
  P4B_GH_AS_AUTHOR="$BIN/fake-gh-as-author" OP_PREFLIGHT_AUTHOR_PAT=fake-author-pat \
  P4B_HANDOFF="$BIN/fake-handoff" P4B_HANDOFF_LOG="$_race_handoff" \
  P4B_WRAPPER_LOG="$_race_wrapper" P4B_FAKE_LIVE_HEAD="$_race_head" \
  P4B_FAKE_COMMENTS_BEFORE="$_race_before" P4B_FAKE_COMMENTS_AFTER="$_race_malformed_after" \
  P4B_FAKE_COMMENTS_COUNT="$_race_count" P4B_FAKE_COMMENTS_SWITCH_AFTER=3 \
  P4B_ISSUE_LOG="$_race_issue_log" P4B_ACCT_STATE_DIR="$_race_acct" \
  bash "$ORCH" 131 --repo o/r --author claude --head "$_race_head" --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 7 ] \
   && [ "$(cat "$_race_gate_count" 2>/dev/null)" = 2 ] \
   && [ "$(cat "$_race_count" 2>/dev/null)" = 4 ] \
   && grep -q '^CLOSE #901$' "$_race_issue_log" \
   && [ "$(jq -sr 'length' "$_race_loop" 2>/dev/null)" = 1 ] \
   && [ "$(jq -sr 'last.loop.posted' "$_race_loop" 2>/dev/null)" = "not-posted" ] \
   && [ "$(jq -sr 'last.loop.fail_closed.happened' "$_race_loop" 2>/dev/null)" = "true" ] \
   && [ ! -e "$_race_pending" ] \
   && [ ! -e "$_race_wrapper" ] \
   && [ ! -e "$_race_handoff" ]; then
  pass "#1085: unsafe pre-POST evidence corrects accounting and closes issues even when the fallback accounting gate then fails"
else
  fail "#1085: unsafe pre-POST cleanup leaked state across fallback-gate failure (rc=$rc gate=$(cat "$_race_gate_count" 2>/dev/null || true) reads=$(cat "$_race_count" 2>/dev/null || true) issue-log=$(tr '\n' ' ' <"$_race_issue_log" 2>/dev/null || true) loop=$(cat "$_race_loop" 2>/dev/null || true) wrapper=$(test -e "$_race_wrapper" && cat "$_race_wrapper" || true) handoff=$(test -e "$_race_handoff" && cat "$_race_handoff" || true)): $out"
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
cat >"$WORK/barrier-bin/gh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = api ] && [ "${2:-}" = repos/owner/repo/pulls/7 ]; then
  for prev in "$@"; do
    [ "${want_jq:-false}" = true ] && { printf '{"head":{"sha":"abc123"}}' | jq -r "$prev"; exit; }
    [ "$prev" = --jq ] && want_jq=true
  done
  printf '{"head":{"sha":"abc123"}}\n'; exit
fi
printf '[]\n'
EOF
chmod +x "$WORK/barrier-bin/gh"
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
