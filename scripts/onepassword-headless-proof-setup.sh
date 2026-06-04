#!/usr/bin/env bash
# Configure and run the 1Password headless proof workflow.
#
# This script intentionally does NOT create the 1Password service account.
# The human must create/approve the scoped service account first, then provide
# its token to this script via OP_SERVICE_ACCOUNT_TOKEN, --token-op-ref, or the
# hidden prompt. The script handles the GitHub Actions setup and proof run.

set -euo pipefail
set +x

REPO="nathanjohnpayne/mergepath"
REF="main"
WORKFLOW_NAME="1Password Headless Proof"
AGENT="codex"
TOKEN_OP_REF=""
REVIEWER_PAT_REF="${OP_PREFLIGHT_REVIEWER_PAT_REF:-}"
CANARY_REF="${OP_PREFLIGHT_CANARY_REF:-}"
CANARY_SHA256="${OP_PREFLIGHT_CANARY_SHA256:-}"
NEGATIVE_SCOPE_REF="${OP_PREFLIGHT_NEGATIVE_SCOPE_REF:-}"
SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN:-}"
RUN_WORKFLOW=true
WATCH_RUN=true
YES=false
DRY_RUN=false
SKIP_NEGATIVE_SCOPE_CHECK=false

AUTHOR_PAT_REF="op://Private/sm5kopwk6t6p3xmu2igesndzhe/token"
GCP_ADC_REF="${GCP_ADC_OP_URI:-op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential}"
CF_TOKEN_REF="${CF_TOKEN_OP_URI:-op://Private/4x6wslp3f6pal5t6h3jhhe63ie/credential}"

CLEANUP_DIRS=()
ORIGINAL_OP_PREFLIGHT_CACHE_DIR="${OP_PREFLIGHT_CACHE_DIR:-}"
ORIGINAL_OP_PREFLIGHT_CACHE_DIR_SET=false
if [ "${OP_PREFLIGHT_CACHE_DIR+x}" = "x" ]; then
  ORIGINAL_OP_PREFLIGHT_CACHE_DIR_SET=true
fi

cleanup() {
  local dir
  if [ "${#CLEANUP_DIRS[@]}" -gt 0 ]; then
    for dir in "${CLEANUP_DIRS[@]}"; do
      [ -n "$dir" ] && rm -rf "$dir"
    done
  fi
  if $ORIGINAL_OP_PREFLIGHT_CACHE_DIR_SET; then
    export OP_PREFLIGHT_CACHE_DIR="$ORIGINAL_OP_PREFLIGHT_CACHE_DIR"
  else
    unset OP_PREFLIGHT_CACHE_DIR
  fi
  unset SERVICE_ACCOUNT_TOKEN CANARY_SHA256 COMPUTED_CANARY_SHA256
  unset OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_TOKEN_MODE
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  scripts/onepassword-headless-proof-setup.sh [options]

What it does:
  1. Confirms the intended 1Password service-account scope.
  2. Reads or prompts for OP_SERVICE_ACCOUNT_TOKEN without echoing it.
  3. Reads the canary through that token and computes/verifies its SHA-256.
  4. Proves scripts/op-preflight.sh token mode locally for the selected agent.
  5. Verifies the token cannot read an out-of-scope shared-vault sentinel.
  6. Sets GitHub Actions values:
       secret   OP_SERVICE_ACCOUNT_TOKEN
       variable OP_PREFLIGHT_REVIEWER_PAT_REF
       variable OP_PREFLIGHT_CANARY_REF
       secret   OP_PREFLIGHT_CANARY_SHA256
  7. Dispatches and optionally watches the "1Password Headless Proof" workflow.

Options:
  --repo owner/name             GitHub repo (default: nathanjohnpayne/mergepath)
  --ref ref                     Workflow ref to run (default: main)
  --agent codex|claude|cursor   op-preflight reviewer lane to prove (default: codex)
  --token-op-ref op://...       Read the service-account token from 1Password locally
  --reviewer-pat-ref op://...   Reviewer PAT op:// ref in the service-account vault
  --canary-ref op://...         Canary op:// reference
  --canary-sha256 hex           Expected canary SHA-256. If omitted, computed from canary.
  --negative-scope-ref op://...  Shared-vault sentinel outside the service-account scope
  --skip-negative-scope-check   Do not test the negative-scope sentinel
  --skip-run                    Set GitHub values but do not dispatch the workflow
  --no-watch                    Dispatch but do not watch the workflow to completion
  --yes                         Skip the human scope confirmation prompt
  --dry-run                     Print planned actions only; do not read or write secrets
  -h, --help                    Show this help

Non-interactive inputs:
  OP_SERVICE_ACCOUNT_TOKEN      Service-account token to store and prove
  OP_PREFLIGHT_REVIEWER_PAT_REF Reviewer PAT op:// reference readable by the service account
  OP_PREFLIGHT_CANARY_REF       Canary op:// reference
  OP_PREFLIGHT_CANARY_SHA256    Optional expected canary digest
  OP_PREFLIGHT_NEGATIVE_SCOPE_REF
                                 Shared-vault sentinel op:// reference the service account must not read

Examples:
  OP_SERVICE_ACCOUNT_TOKEN="..." \
  OP_PREFLIGHT_REVIEWER_PAT_REF="op://Mergepath CI Headless/nathanpayne-codex reviewer PAT/token" \
  OP_PREFLIGHT_CANARY_REF="op://Mergepath CI Headless/Mergepath CI Headless Canary/password" \
  OP_PREFLIGHT_NEGATIVE_SCOPE_REF="op://Mergepath CI Scope Sentinel/Out Of Scope Canary/password" \
    scripts/onepassword-headless-proof-setup.sh

  scripts/onepassword-headless-proof-setup.sh \
    --token-op-ref "op://Private/Mergepath CI SA Token/token" \
    --reviewer-pat-ref "op://Mergepath CI Headless/nathanpayne-codex reviewer PAT/token" \
    --canary-ref "op://Mergepath CI Headless/Mergepath CI Headless Canary/password" \
    --negative-scope-ref "op://Mergepath CI Scope Sentinel/Out Of Scope Canary/password"
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

prompt_hidden() {
  local prompt=$1
  local value
  if [ ! -t 0 ]; then
    fail "$prompt is required, but stdin is not a terminal. Set OP_SERVICE_ACCOUNT_TOKEN or pass --token-op-ref."
  fi
  printf '%s' "$prompt" >&2
  IFS= read -r -s value
  printf '\n' >&2
  printf '%s' "$value"
}

prompt_line() {
  local prompt=$1
  local hint=${2:-"Provide the required value via env or CLI option."}
  local value
  if [ ! -t 0 ]; then
    fail "$prompt is required, but stdin is not a terminal. $hint"
  fi
  printf '%s' "$prompt" >&2
  IFS= read -r value
  printf '%s' "$value"
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    fail "need sha256sum or shasum to compute the canary digest"
  fi
}

set_actions_secret() {
  local name=$1
  local value=$2
  if $DRY_RUN; then
    log "DRY-RUN: would set Actions secret $name on $REPO"
    return 0
  fi
  printf '%s' "$value" | scripts/gh-as-author.sh -- gh secret set "$name" --repo "$REPO" --app actions >/dev/null
  log "Set Actions secret $name on $REPO"
}

set_actions_variable() {
  local name=$1
  local value=$2
  if $DRY_RUN; then
    log "DRY-RUN: would set Actions variable $name on $REPO"
    return 0
  fi
  printf '%s' "$value" | scripts/gh-as-author.sh -- gh variable set "$name" --repo "$REPO" >/dev/null
  log "Set Actions variable $name on $REPO"
}

confirm_scope() {
  $YES && return 0
  if [ ! -t 0 ]; then
    fail "scope confirmation requires a terminal. Pass --yes for non-interactive use."
  fi
  cat >&2 <<'EOF'
Confirm the 1Password service account is approved for #355/#354:
  - read-only
  - scoped to the reviewer PAT item(s) and the proof canary only
  - excludes the author PAT, GCP ADC, Cloudflare, deploy, and app secrets
  - has documented rotation / owner expectations outside this script
EOF
  printf 'Proceed with this token? [y/N] ' >&2
  local answer
  IFS= read -r answer || fail "failed to read scope confirmation"
  case "$answer" in
    y|Y|yes|YES) ;;
    *) fail "aborted before reading or writing any GitHub secret" ;;
  esac
}

validate_ref() {
  local name=$1
  local value=$2
  case "$value" in
    op://*/*/*) ;;
    *) fail "$name must be an op:// reference" ;;
  esac
}

validate_service_account_ref() {
  local name=$1
  local value=$2
  validate_ref "$name" "$value"
  case "$value" in
    op://Private/*|op://Personal/*)
      fail "$name cannot point to Private or Personal vaults because service accounts cannot access them"
      ;;
  esac
}

validate_negative_scope_sentinel() {
  local value=$1
  validate_service_account_ref "negative scope ref" "$value"
  log "Validating negative-scope sentinel exists through the local 1Password account..."
  if ! (unset OP_SERVICE_ACCOUNT_TOKEN; op read "$value" >/dev/null); then
    fail "negative scope ref must point to an existing shared-vault item readable by the local 1Password account"
  fi
}

expected_reviewer_login_for() {
  case "$1" in
    claude) printf '%s\n' "nathanpayne-claude" ;;
    cursor) printf '%s\n' "nathanpayne-cursor" ;;
    codex) printf '%s\n' "nathanpayne-codex" ;;
    *) fail "unknown agent for reviewer identity check: $1" ;;
  esac
}

validate_sha256() {
  local value=$1
  case "$value" in
    *[!0123456789abcdefABCDEF]*|"")
      fail "--canary-sha256 must be a 64-character hex digest"
      ;;
  esac
  [ "${#value}" -eq 64 ] || fail "--canary-sha256 must be a 64-character hex digest"
}

negative_scope_check() {
  local label=$1
  local ref=$2
  if OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_ACCOUNT_TOKEN" op read "$ref" >/dev/null 2>&1; then
    fail "service account can read out-of-scope $label ($ref); narrow the 1Password scope before continuing"
  fi
  log "Scope check OK: service account cannot read $label"
}

local_preflight_proof() {
  local cache_dir
  cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/mergepath-op-sa-proof.XXXXXX")
  chmod 700 "$cache_dir" 2>/dev/null || true

  local old_cache=${OP_PREFLIGHT_CACHE_DIR:-}
  local exports
  CLEANUP_DIRS+=("$cache_dir")
  export OP_PREFLIGHT_CACHE_DIR="$cache_dir"
  exports=$(OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_ACCOUNT_TOKEN" \
    OP_PREFLIGHT_REVIEWER_PAT_REF="$REVIEWER_PAT_REF" \
    scripts/op-preflight.sh --agent "$AGENT" --mode review)
  eval "$exports"

  [ "${OP_PREFLIGHT_TOKEN_MODE:-0}" = "1" ] || fail "op-preflight did not enter token mode"
  [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ] || fail "op-preflight did not export reviewer PAT"
  [ -z "${OP_PREFLIGHT_AUTHOR_PAT:-}" ] || fail "op-preflight unexpectedly exported author PAT"
  local expected_login actual_login
  expected_login=$(expected_reviewer_login_for "$AGENT")
  actual_login=$(GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login)
  if [ "$actual_login" != "$expected_login" ]; then
    fail "reviewer PAT ref resolved to $actual_login, expected $expected_login"
  fi
  log "Reviewer PAT identity OK: $actual_login"

  exports=$(OP_PREFLIGHT_QUIET=1 \
    OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_ACCOUNT_TOKEN" \
    OP_PREFLIGHT_REVIEWER_PAT_REF="$REVIEWER_PAT_REF" \
    scripts/op-preflight.sh --agent "$AGENT" --check)
  eval "$exports"
  [ "${OP_PREFLIGHT_TOKEN_MODE:-0}" = "1" ] || fail "op-preflight --check did not preserve token mode"

  unset OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_TOKEN_MODE
  rm -rf "$cache_dir"
  if [ -n "$old_cache" ]; then
    export OP_PREFLIGHT_CACHE_DIR="$old_cache"
  else
    unset OP_PREFLIGHT_CACHE_DIR
  fi
  log "Local proof OK: op-preflight token mode works for agent=$AGENT"
}

dispatch_workflow() {
  if ! $RUN_WORKFLOW; then
    log "Skipped workflow dispatch (--skip-run)."
    return 0
  fi

  if $DRY_RUN; then
    log "DRY-RUN: would dispatch workflow '$WORKFLOW_NAME' on $REPO@$REF"
    return 0
  fi

  local dispatch_epoch
  dispatch_epoch=$(date -u +%s)

  scripts/gh-as-author.sh -- \
    gh workflow run "$WORKFLOW_NAME" --repo "$REPO" --ref "$REF" >/dev/null
  log "Dispatched workflow '$WORKFLOW_NAME' on $REPO@$REF"

  local run_json run_id run_url attempt
  run_json=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 3
    run_json=$(gh run list \
      --repo "$REPO" \
      --workflow "$WORKFLOW_NAME" \
      --branch "$REF" \
      --event workflow_dispatch \
      --limit 5 \
      --json databaseId,url,status,conclusion,createdAt \
      --jq "map(select((.createdAt | fromdateiso8601) >= $dispatch_epoch)) | .[0] // empty" 2>/dev/null || true)
    [ -n "$run_json" ] && break
  done

  if [ -z "$run_json" ]; then
    log "WARN: dispatched workflow, but could not find the run yet."
    log "Open: https://github.com/$REPO/actions/workflows/onepassword-headless-proof.yml"
    return 0
  fi

  run_id=$(printf '%s' "$run_json" | jq -r '.databaseId')
  run_url=$(printf '%s' "$run_json" | jq -r '.url')
  log "Workflow run: $run_url"

  if $WATCH_RUN; then
    gh run watch "$run_id" --repo "$REPO" --exit-status
  else
    log "Not watching run (--no-watch)."
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || fail "--repo requires owner/name"
      REPO=$2
      shift 2
      ;;
    --ref)
      [ $# -ge 2 ] || fail "--ref requires a ref"
      REF=$2
      shift 2
      ;;
    --agent)
      [ $# -ge 2 ] || fail "--agent requires codex, claude, or cursor"
      AGENT=$2
      shift 2
      ;;
    --token-op-ref)
      [ $# -ge 2 ] || fail "--token-op-ref requires an op:// reference"
      TOKEN_OP_REF=$2
      shift 2
      ;;
    --reviewer-pat-ref)
      [ $# -ge 2 ] || fail "--reviewer-pat-ref requires an op:// reference"
      REVIEWER_PAT_REF=$2
      shift 2
      ;;
    --canary-ref)
      [ $# -ge 2 ] || fail "--canary-ref requires an op:// reference"
      CANARY_REF=$2
      shift 2
      ;;
    --canary-sha256)
      [ $# -ge 2 ] || fail "--canary-sha256 requires a digest"
      CANARY_SHA256=$2
      shift 2
      ;;
    --negative-scope-ref)
      [ $# -ge 2 ] || fail "--negative-scope-ref requires an op:// reference"
      NEGATIVE_SCOPE_REF=$2
      shift 2
      ;;
    --skip-negative-scope-check)
      SKIP_NEGATIVE_SCOPE_CHECK=true
      shift
      ;;
    --skip-run)
      RUN_WORKFLOW=false
      shift
      ;;
    --no-watch)
      WATCH_RUN=false
      shift
      ;;
    --yes)
      YES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$AGENT" in
  codex|claude|cursor) ;;
  *) fail "--agent must be one of: codex, claude, cursor" ;;
esac

if $DRY_RUN; then
  log "DRY-RUN plan for $REPO@$REF:"
  log "  would validate/prove service-account token for agent=$AGENT"
  log "  would set OP_SERVICE_ACCOUNT_TOKEN, OP_PREFLIGHT_REVIEWER_PAT_REF, OP_PREFLIGHT_CANARY_REF, OP_PREFLIGHT_CANARY_SHA256"
  if ! $SKIP_NEGATIVE_SCOPE_CHECK; then
    log "  would require OP_PREFLIGHT_NEGATIVE_SCOPE_REF or --negative-scope-ref for a shared-vault over-scope sentinel"
  fi
  if $RUN_WORKFLOW; then
    log "  would dispatch '$WORKFLOW_NAME'"
  else
    log "  would not dispatch workflow (--skip-run)"
  fi
  exit 0
fi

require_cmd gh
require_cmd op
require_cmd jq

confirm_scope

if [ -n "$TOKEN_OP_REF" ]; then
  validate_ref "--token-op-ref" "$TOKEN_OP_REF"
  SERVICE_ACCOUNT_TOKEN=$(op read "$TOKEN_OP_REF")
fi

if [ -z "$SERVICE_ACCOUNT_TOKEN" ]; then
  SERVICE_ACCOUNT_TOKEN=$(prompt_hidden "Paste OP_SERVICE_ACCOUNT_TOKEN (input hidden): ")
fi
[ -n "$SERVICE_ACCOUNT_TOKEN" ] || fail "OP_SERVICE_ACCOUNT_TOKEN is empty"

if [ -z "$CANARY_REF" ]; then
  CANARY_REF=$(prompt_line "Canary op:// reference: " "Set OP_PREFLIGHT_CANARY_REF or pass --canary-ref.")
fi
if [ -z "$REVIEWER_PAT_REF" ]; then
  REVIEWER_PAT_REF=$(prompt_line "Reviewer PAT op:// reference readable by the service account: " "Set OP_PREFLIGHT_REVIEWER_PAT_REF or pass --reviewer-pat-ref.")
fi
validate_service_account_ref "canary ref" "$CANARY_REF"
validate_service_account_ref "reviewer PAT ref" "$REVIEWER_PAT_REF"
if ! $SKIP_NEGATIVE_SCOPE_CHECK; then
  [ -n "$NEGATIVE_SCOPE_REF" ] || fail "OP_PREFLIGHT_NEGATIVE_SCOPE_REF or --negative-scope-ref is required unless --skip-negative-scope-check is set"
  validate_negative_scope_sentinel "$NEGATIVE_SCOPE_REF"
fi
validate_ref "author PAT ref" "$AUTHOR_PAT_REF"
validate_ref "GCP ADC ref" "$GCP_ADC_REF"
validate_ref "Cloudflare token ref" "$CF_TOKEN_REF"

log "Reading canary through the service-account token..."
CANARY_VALUE=$(OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_ACCOUNT_TOKEN" op read "$CANARY_REF")
[ -n "$CANARY_VALUE" ] || fail "canary value is empty"
COMPUTED_CANARY_SHA256=$(sha256_text "$CANARY_VALUE")
unset CANARY_VALUE

if [ -n "$CANARY_SHA256" ]; then
  validate_sha256 "$CANARY_SHA256"
  if [ "$(printf '%s' "$CANARY_SHA256" | tr 'A-F' 'a-f')" != "$COMPUTED_CANARY_SHA256" ]; then
    fail "provided OP_PREFLIGHT_CANARY_SHA256 does not match the canary read by the service account"
  fi
else
  CANARY_SHA256="$COMPUTED_CANARY_SHA256"
fi
log "Canary digest computed and verified locally."

local_preflight_proof

if ! $SKIP_NEGATIVE_SCOPE_CHECK; then
  negative_scope_check "shared-vault negative sentinel" "$NEGATIVE_SCOPE_REF"
  negative_scope_check "author PAT (Private control)" "$AUTHOR_PAT_REF"
  negative_scope_check "GCP ADC (Private control)" "$GCP_ADC_REF"
  negative_scope_check "Cloudflare token (Private control)" "$CF_TOKEN_REF"
else
  log "Skipped negative scope checks."
fi

set_actions_secret "OP_SERVICE_ACCOUNT_TOKEN" "$SERVICE_ACCOUNT_TOKEN"
set_actions_variable "OP_PREFLIGHT_REVIEWER_PAT_REF" "$REVIEWER_PAT_REF"
set_actions_variable "OP_PREFLIGHT_CANARY_REF" "$CANARY_REF"
set_actions_secret "OP_PREFLIGHT_CANARY_SHA256" "$CANARY_SHA256"

unset SERVICE_ACCOUNT_TOKEN CANARY_SHA256 COMPUTED_CANARY_SHA256

dispatch_workflow

log "1Password headless proof setup complete."
