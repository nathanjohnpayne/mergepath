#!/usr/bin/env bash
# scripts/phase-4b/collect-enablement-evidence.sh
#
# Capture the pre-enablement evidence #586 asks for BEFORE flipping
# phase_4b_automation.enabled: true in a repo. It reports, without ever
# printing a secret:
#
#   - codex / claude reviewer CLI versions (or "not found")
#   - reviewer plan-auth status per adapter (proves plan-only billing, not the
#     metered API) via the same lib.sh auth guards the adapters use
#   - a scan for the disallowed API-key env vars that MUST be unset for
#     plan-only billing (presence is reported, never the value)
#   - the resolved phase_4b_automation config: enabled, mode, and per-adapter
#     timeout + effort (#589)
#   - optionally, a real adapter dry-run per available direction (with
#     --diff-file, or --pr + --repo) so the enablement PR can paste a
#     successful verdict as evidence
#
# Output is Markdown by default, or a JSON object with --json. Exit status is
# 0 when READY (no disallowed API key set AND at least one direction has a
# plan-authed CLI) and 1 when BLOCKED, so an enablement step can gate on it.
#
# Reasoning-plane CLIs are injectable via CODEX_BIN / CLAUDE_BIN and the auth
# guards via P4B_CODEX_AUTH_FILE / P4B_CLAUDE_AUTH_STATUS_FILE, so the script is
# fully testable offline.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CODEX_BIN="${CODEX_BIN:-codex}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

REPO="" ; PR="" ; DIFF_FILE="" ; FORMAT="markdown" ; RUN_DRYRUN=auto

usage() {
  echo "usage: collect-enablement-evidence.sh [--repo owner/repo] [--pr N] [--diff-file F] [--json] [--no-dry-run]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="${2:-}"; shift 2 ;;
    --pr)          PR="${2:-}"; shift 2 ;;
    --diff-file)   DIFF_FILE="${2:-}"; shift 2 ;;
    --json)        FORMAT="json"; shift ;;
    --no-dry-run)  RUN_DRYRUN=off; shift ;;
    -h|--help)     usage ;;
    *) echo "collect-enablement-evidence.sh: unknown arg: $1" >&2; usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || p4b_die 3 "jq is required"

# --- CLI version (best effort; never fails the script) ---------------------
cli_version() { # cli_version <bin>
  local bin="$1" v
  command -v "$bin" >/dev/null 2>&1 || { printf 'not found'; return 1; }
  v="$("$bin" --version </dev/null 2>/dev/null | head -n1 || true)"
  printf '%s' "${v:-unknown}"
}

# --- plan-auth status (captures the guard's message; no tokens) ------------
auth_status() { # auth_status <adapter>  -> prints "ok" or "BLOCKED: <reason>"
  local adapter="$1" msg rc
  case "$adapter" in
    codex)  msg="$( ( p4b_require_codex_plan_auth ) 2>&1 )"; rc=$? ;;
    claude) msg="$( ( p4b_require_claude_plan_auth "$CLAUDE_BIN" ) 2>&1 )"; rc=$? ;;
    *) printf 'BLOCKED: unknown adapter'; return 1 ;;
  esac
  if [ "$rc" -eq 0 ]; then printf 'ok'; return 0; fi
  # Strip the "[phase-4b] ERROR: " prefix for a compact one-liner.
  printf 'BLOCKED: %s' "$(printf '%s' "$msg" | sed -e 's/^\[phase-4b\] ERROR: //' | head -n1)"
  return 1
}

# --- resolved config -------------------------------------------------------
ENABLED="$(p4b_automation_field enabled)"; ENABLED="${ENABLED:-false}"
MODE="$(p4b_automation_field mode)"; MODE="${MODE:-local}"

resolved_timeout() { p4b_resolve_adapter_timeout "$1" 2>/dev/null || printf 'INVALID'; }
resolved_effort()  { local e; e="$(p4b_resolve_adapter_effort "$1" 2>/dev/null)" || { printf 'INVALID'; return; }; printf '%s' "${e:-cli-default}"; }

# --- API-key env scan (presence only, never the value) ---------------------
# These MUST be unset for plan-only billing; we report presence, never values.
key_state() { [ -n "$1" ] && printf 'SET' || printf 'unset'; }
ANY_KEY_SET=0
for v in \
  "${OPENAI_API_KEY:-}" \
  "${CODEX_API_KEY:-}" \
  "${ANTHROPIC_API_KEY:-}" \
  "${ANTHROPIC_AUTH_TOKEN:-}"; do
  [ -n "$v" ] && ANY_KEY_SET=1
done

# --- gather per-adapter facts ----------------------------------------------
CODEX_VER="$(cli_version "$CODEX_BIN" || true)"
CLAUDE_VER="$(cli_version "$CLAUDE_BIN" || true)"
CODEX_PRESENT=false; command -v "$CODEX_BIN" >/dev/null 2>&1 && CODEX_PRESENT=true
CLAUDE_PRESENT=false; command -v "$CLAUDE_BIN" >/dev/null 2>&1 && CLAUDE_PRESENT=true

CODEX_AUTH="not-checked (CLI absent)"; CODEX_AUTH_OK=false
if [ "$CODEX_PRESENT" = true ]; then
  CODEX_AUTH="$(auth_status codex || true)"
  [ "$CODEX_AUTH" = ok ] && CODEX_AUTH_OK=true
fi
CLAUDE_AUTH="not-checked (CLI absent)"; CLAUDE_AUTH_OK=false
if [ "$CLAUDE_PRESENT" = true ]; then
  CLAUDE_AUTH="$(auth_status claude || true)"
  [ "$CLAUDE_AUTH" = ok ] && CLAUDE_AUTH_OK=true
fi

# --- resolver validity per adapter (INVALID config is itself a blocker) -----
# The orchestrator exits fail-closed on a malformed timeout/effort, so a config
# that would not even start is not "ready" regardless of auth (#598 Codex P2).
CODEX_CONFIG_OK=true;  p4b_resolve_adapter_timeout codex  >/dev/null 2>&1 && p4b_resolve_adapter_effort codex  >/dev/null 2>&1 || CODEX_CONFIG_OK=false
CLAUDE_CONFIG_OK=true; p4b_resolve_adapter_timeout claude >/dev/null 2>&1 && p4b_resolve_adapter_effort claude >/dev/null 2>&1 || CLAUDE_CONFIG_OK=false

# --- optional adapter dry-run per available direction ----------------------
# A "direction is ready" when its CLI is present AND plan-authed. Run the
# adapter directly (no orchestrator, so enabled:true is not required) UNDER THE
# SAME resolved timeout/effort the orchestrator would apply, so the dry-run
# actually exercises the config being enabled (#598 Codex P2). Sets a global
# <ADAPTER>_DRYRUN_STATUS of ok|failed|skipped.
# Emits "<status>\t<display>" (status ∈ ok|failed|skipped) so the caller gets
# BOTH from the command substitution — a status global set inside $(...) would
# not reach the parent shell.
run_dryrun() { # run_dryrun <adapter> <bin-ok>
  local adapter="$1" ok="$2" script args verdict rc out timeout effort
  script="$HERE/adapters/review-via-${adapter}.sh"
  [ "$ok" = true ] || { printf 'skipped\tskipped (CLI absent or not plan-authed)'; return; }
  [ -x "$script" ] || { printf 'skipped\tskipped (adapter missing)'; return; }
  if [ -z "$DIFF_FILE" ] && { [ -z "$PR" ] || [ -z "$REPO" ]; }; then
    printf 'skipped\tskipped (pass --diff-file, or --pr and --repo)'; return
  fi
  timeout="$(p4b_resolve_adapter_timeout "$adapter" 2>/dev/null)" \
    || { printf 'failed\tfailed (invalid timeout config)'; return; }
  effort="$(p4b_resolve_adapter_effort "$adapter" 2>/dev/null)" \
    || { printf 'failed\tfailed (invalid effort config)'; return; }
  args=( --pr "${PR:-0}" )
  [ -n "$REPO" ]      && args+=( --repo "$REPO" )
  [ -n "$DIFF_FILE" ] && args+=( --diff-file "$DIFF_FILE" )
  local env_prefix=( "P4B_REVIEW_CLI_TIMEOUT_SECONDS=$timeout" )
  case "$adapter" in
    codex)  [ -n "$effort" ] && env_prefix+=( "P4B_CODEX_EFFORT=$effort" ) ;;
    claude) env_prefix+=( "P4B_CLAUDE_EFFORT=${effort:-medium}" ) ;;
  esac
  set +e
  out="$(env "${env_prefix[@]}" "$script" "${args[@]}" 2>/dev/null)"; rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    verdict="$(printf '%s' "$out" | jq -r '.verdict // "?"' 2>/dev/null || printf '?')"
    printf 'ok\trc=0 verdict=%s' "$verdict"
  else
    printf 'failed\trc=%s verdict=- (fail-closed)' "$rc"
  fi
}
CODEX_DRYRUN="not-run"; CLAUDE_DRYRUN="not-run"
CODEX_DRYRUN_STATUS=skipped; CLAUDE_DRYRUN_STATUS=skipped
if [ "$RUN_DRYRUN" != off ]; then
  _r="$(run_dryrun codex "$CODEX_AUTH_OK")"
  CODEX_DRYRUN_STATUS="${_r%%$'\t'*}"; CODEX_DRYRUN="${_r#*$'\t'}"
  _r="$(run_dryrun claude "$CLAUDE_AUTH_OK")"
  CLAUDE_DRYRUN_STATUS="${_r%%$'\t'*}"; CLAUDE_DRYRUN="${_r#*$'\t'}"
  unset _r
fi

# --- readiness verdict -----------------------------------------------------
READY=true; BLOCKERS=""
if [ "$ANY_KEY_SET" -eq 1 ]; then
  READY=false; BLOCKERS="${BLOCKERS}a disallowed API-key env var is SET (plan-only billing requires them unset); "
fi
if [ "$CODEX_AUTH_OK" != true ] && [ "$CLAUDE_AUTH_OK" != true ]; then
  READY=false; BLOCKERS="${BLOCKERS}no direction has a plan-authed reviewer CLI; "
fi
# A plan-authed direction whose config is INVALID or whose requested dry-run
# FAILED is not ready — the orchestrator would fail closed on it (#598 Codex P2).
if [ "$CODEX_AUTH_OK" = true ] && [ "$CODEX_CONFIG_OK" != true ]; then
  READY=false; BLOCKERS="${BLOCKERS}codex config resolves INVALID (timeout/effort out of range); "
fi
if [ "$CLAUDE_AUTH_OK" = true ] && [ "$CLAUDE_CONFIG_OK" != true ]; then
  READY=false; BLOCKERS="${BLOCKERS}claude config resolves INVALID (timeout/effort out of range); "
fi
if [ "$CODEX_AUTH_OK" = true ] && [ "$CODEX_DRYRUN_STATUS" = failed ]; then
  READY=false; BLOCKERS="${BLOCKERS}codex dry-run failed; "
fi
if [ "$CLAUDE_AUTH_OK" = true ] && [ "$CLAUDE_DRYRUN_STATUS" = failed ]; then
  READY=false; BLOCKERS="${BLOCKERS}claude dry-run failed; "
fi

# --- emit ------------------------------------------------------------------
if [ "$FORMAT" = json ]; then
  jq -n \
    --arg enabled "$ENABLED" --arg mode "$MODE" \
    --arg codex_ver "$CODEX_VER" --arg claude_ver "$CLAUDE_VER" \
    --argjson codex_present "$CODEX_PRESENT" --argjson claude_present "$CLAUDE_PRESENT" \
    --arg codex_auth "$CODEX_AUTH" --arg claude_auth "$CLAUDE_AUTH" \
    --argjson codex_auth_ok "$CODEX_AUTH_OK" --argjson claude_auth_ok "$CLAUDE_AUTH_OK" \
    --arg codex_timeout "$(resolved_timeout codex)" --arg claude_timeout "$(resolved_timeout claude)" \
    --arg codex_effort "$(resolved_effort codex)" --arg claude_effort "$(resolved_effort claude)" \
    --argjson any_key_set "$( [ "$ANY_KEY_SET" -eq 1 ] && echo true || echo false )" \
    --arg codex_dryrun "$CODEX_DRYRUN" --arg claude_dryrun "$CLAUDE_DRYRUN" \
    --argjson ready "$READY" --arg blockers "$BLOCKERS" \
    --arg openai_key "$(key_state "${OPENAI_API_KEY:-}")" \
    --arg codex_key "$(key_state "${CODEX_API_KEY:-}")" \
    --arg anthropic_key "$(key_state "${ANTHROPIC_API_KEY:-}")" \
    --arg anthropic_tok "$(key_state "${ANTHROPIC_AUTH_TOKEN:-}")" '
    {
      config: {enabled: $enabled, mode: $mode},
      adapters: {
        codex:  {present: $codex_present,  version: $codex_ver,  plan_auth: $codex_auth,  plan_auth_ok: $codex_auth_ok,  timeout_seconds: $codex_timeout,  effort: $codex_effort,  dry_run: $codex_dryrun},
        claude: {present: $claude_present, version: $claude_ver, plan_auth: $claude_auth, plan_auth_ok: $claude_auth_ok, timeout_seconds: $claude_timeout, effort: $claude_effort, dry_run: $claude_dryrun}
      },
      api_key_env: {any_set: $any_key_set, OPENAI_API_KEY: $openai_key, CODEX_API_KEY: $codex_key, ANTHROPIC_API_KEY: $anthropic_key, ANTHROPIC_AUTH_TOKEN: $anthropic_tok},
      ready: $ready,
      blockers: (if $blockers == "" then null else $blockers end)
    }'
else
  echo "## Phase 4b enablement evidence"
  echo
  echo "### Config (phase_4b_automation)"
  echo "- enabled: \`$ENABLED\`"
  echo "- mode: \`$MODE\`"
  echo
  echo "### Reviewer CLIs (plan-only billing)"
  echo "| adapter | present | version | plan auth | timeout | effort | dry-run |"
  echo "|---------|---------|---------|-----------|---------|--------|---------|"
  echo "| codex  | $CODEX_PRESENT  | $CODEX_VER  | $CODEX_AUTH  | $(resolved_timeout codex)s  | $(resolved_effort codex)  | $CODEX_DRYRUN |"
  echo "| claude | $CLAUDE_PRESENT | $CLAUDE_VER | $CLAUDE_AUTH | $(resolved_timeout claude)s | $(resolved_effort claude) | $CLAUDE_DRYRUN |"
  echo
  echo "### API-key env scan (must all be \`unset\` for plan-only billing)"
  echo "- OPENAI_API_KEY: $(key_state "${OPENAI_API_KEY:-}")"
  echo "- CODEX_API_KEY: $(key_state "${CODEX_API_KEY:-}")"
  echo "- ANTHROPIC_API_KEY: $(key_state "${ANTHROPIC_API_KEY:-}")"
  echo "- ANTHROPIC_AUTH_TOKEN: $(key_state "${ANTHROPIC_AUTH_TOKEN:-}")"
  echo
  if [ "$READY" = true ]; then
    echo "**ENABLEMENT READINESS: READY** — plan-authed reviewer available and no API-key env vars set."
  else
    echo "**ENABLEMENT READINESS: BLOCKED** — ${BLOCKERS%%; }."
  fi
fi

[ "$READY" = true ]
