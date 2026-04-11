#!/usr/bin/env bash
# op-preflight.sh — Front-load all 1Password credential reads for a session.
#
# Triggers biometric prompts once at the start, then exports secrets as
# environment variables so the rest of the session runs without prompting.
#
# Usage:
#   eval "$(scripts/op-preflight.sh --agent claude --mode all)"
#
# Modes:
#   review  — reviewer PAT + author PAT + SSH key warming
#   deploy  — GCP ADC credential
#   all     — everything (default)
#
# Flags:
#   --agent <name>   Agent name: claude, cursor, or codex (required for review)
#   --mode <mode>    review, deploy, or all (default: all)
#   --dry-run        Show what would be fetched without prompting
#   --skip-ssh       Skip SSH key warming (useful in CI or non-interactive)
#
# After eval, downstream scripts and agent commands use the exported env
# vars instead of calling op directly:
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh pr review ...
#   GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"   gh pr merge ...
#   # gcloud/firebase use GOOGLE_APPLICATION_CREDENTIALS automatically

set -eo pipefail

# ── PAT lookup table ──────────────────────────────────────────────────
# Must match REVIEW_POLICY.md § PAT lookup table.
AUTHOR_PAT_ITEM="sm5kopwk6t6p3xmu2igesndzhe"

reviewer_pat_item_for() {
  case "$1" in
    claude) echo "pvbq24vl2h6gl7yjclxy2hbote" ;;
    cursor) echo "bslrih4spwxgookzfy6zedz5g4" ;;
    codex)  echo "o6ekjxjjl5gq6rmcneomrjahpu" ;;
    *)      return 1 ;;
  esac
}

ssh_host_for() {
  case "$1" in
    claude) echo "github-claude" ;;
    cursor) echo "github-cursor" ;;
    codex)  echo "github-codex" ;;
    *)      return 1 ;;
  esac
}

# ── GCP ADC ───────────────────────────────────────────────────────────
DEFAULT_ADC_OP_URI="${GCP_ADC_OP_URI:-op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential}"
SSH_AUTHOR_HOST="github.com"

# ── Parse arguments ───────────────────────────────────────────────────
AGENT=""
MODE="all"
DRY_RUN=false
SKIP_SSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENT="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-ssh) SKIP_SSH=true; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode all)\"" >&2
      exit 1
      ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────
if [[ "$MODE" == "review" || "$MODE" == "all" ]] && [[ -z "$AGENT" ]]; then
  echo "Error: --agent is required for review or all mode." >&2
  echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode all)\"" >&2
  exit 1
fi

if [[ -n "$AGENT" ]] && [[ -z "$(reviewer_pat_item_for "$AGENT" 2>/dev/null || true)" ]]; then
  echo "Error: unknown agent '$AGENT'. Valid: claude, cursor, codex" >&2
  exit 1
fi

# ── Preflight checks ─────────────────────────────────────────────────
if ! command -v op &>/dev/null; then
  echo "Error: 1Password CLI (op) not found." >&2
  exit 1
fi

# ── Dry run ───────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo "# op-preflight.sh --agent $AGENT --mode $MODE (dry run)" >&2
  echo "#" >&2
  if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
    echo "# Would read: reviewer PAT ($(reviewer_pat_item_for "$AGENT"))" >&2
    echo "# Would read: author PAT ($AUTHOR_PAT_ITEM)" >&2
    if ! $SKIP_SSH; then
      echo "# Would warm SSH: $SSH_AUTHOR_HOST (author key)" >&2
      echo "# Would warm SSH: $(ssh_host_for "$AGENT") (reviewer key)" >&2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    echo "# Would read: GCP ADC ($DEFAULT_ADC_OP_URI)" >&2
  fi
  exit 0
fi

# ── Collect export statements ─────────────────────────────────────────
EXPORTS=()
SUMMARY=()

# ── Phase 1: CLI credentials (one biometric prompt + session reuse) ───
if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
  reviewer_item="$(reviewer_pat_item_for "$AGENT")"

  # Build an op inject template for both PATs.
  # op inject resolves all op:// references in a single process — one
  # biometric prompt covers both reads.
  tpl_file="$(mktemp "${TMPDIR:-/tmp}/op-preflight-tpl-XXXXXX")"
  trap 'rm -f "$tpl_file"' EXIT

  cat > "$tpl_file" <<TPL
REVIEWER_PAT={{ op://Private/${reviewer_item}/token }}
AUTHOR_PAT={{ op://Private/${AUTHOR_PAT_ITEM}/token }}
TPL

  echo "# Preflight: reading PATs (one biometric prompt)..." >&2
  resolved="$(op inject -i "$tpl_file")"
  rm -f "$tpl_file"

  reviewer_pat="$(echo "$resolved" | grep '^REVIEWER_PAT=' | cut -d= -f2-)"
  author_pat="$(echo "$resolved" | grep '^AUTHOR_PAT=' | cut -d= -f2-)"

  if [[ -z "$reviewer_pat" ]]; then
    echo "Error: failed to read reviewer PAT for $AGENT." >&2
    exit 1
  fi
  if [[ -z "$author_pat" ]]; then
    echo "Error: failed to read author PAT." >&2
    exit 1
  fi

  EXPORTS+=("export OP_PREFLIGHT_REVIEWER_PAT='${reviewer_pat}'")
  EXPORTS+=("export OP_PREFLIGHT_AUTHOR_PAT='${author_pat}'")
  SUMMARY+=("Reviewer PAT ($AGENT): loaded")
  SUMMARY+=("Author PAT: loaded")
fi

if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
  echo "# Preflight: reading GCP ADC (reuses session)..." >&2

  adc_tmpfile="$(mktemp "${TMPDIR:-/tmp}/op-preflight-adc-XXXXXX")"
  umask 077

  if op read "$DEFAULT_ADC_OP_URI" > "$adc_tmpfile" 2>/dev/null && [[ -s "$adc_tmpfile" ]]; then
    EXPORTS+=("export GOOGLE_APPLICATION_CREDENTIALS='${adc_tmpfile}'")
    EXPORTS+=("export OP_PREFLIGHT_ADC_TMPFILE='${adc_tmpfile}'")
    SUMMARY+=("GCP ADC: loaded -> $adc_tmpfile")
  else
    rm -f "$adc_tmpfile"
    echo "# Warning: could not read GCP ADC. Deploy credentials not cached." >&2
    SUMMARY+=("GCP ADC: SKIPPED (not available)")
  fi
fi

# ── Phase 2: SSH key warming ──────────────────────────────────────────
if [[ "$MODE" == "review" || "$MODE" == "all" ]] && ! $SKIP_SSH; then
  echo "# Preflight: warming SSH keys..." >&2

  # Author key
  if ssh -T "git@${SSH_AUTHOR_HOST}" 2>&1 | grep -qi "successfully authenticated"; then
    SUMMARY+=("SSH key ($SSH_AUTHOR_HOST): authorized")
  else
    SUMMARY+=("SSH key ($SSH_AUTHOR_HOST): warming attempted")
  fi

  # Reviewer key
  reviewer_host="$(ssh_host_for "$AGENT")"
  if ssh -T "git@${reviewer_host}" 2>&1 | grep -qi "successfully authenticated"; then
    SUMMARY+=("SSH key ($reviewer_host): authorized")
  else
    SUMMARY+=("SSH key ($reviewer_host): warming attempted")
  fi
fi

# ── Output ────────────────────────────────────────────────────────────
EXPORTS+=("export OP_PREFLIGHT_DONE=1")
EXPORTS+=("export OP_PREFLIGHT_AGENT='${AGENT}'")

# Print export statements to stdout (caller evals them)
for exp in "${EXPORTS[@]}"; do
  echo "$exp"
done

# Print summary to stderr (visible to user, not eval'd)
echo "" >&2
echo "# ── Preflight complete ──────────────────────────────" >&2
for line in "${SUMMARY[@]}"; do
  echo "#   $line" >&2
done
echo "# OP_PREFLIGHT_DONE=1" >&2
echo "# Human can step away." >&2
echo "# ──────────────────────────────────────────────────────" >&2
