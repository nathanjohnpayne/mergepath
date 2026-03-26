#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# bootstrap.sh — Restore local config files from 1Password
#
# Run this after cloning on a new machine or switching computers.
# Requires: op CLI (1Password), authenticated session, biometrics.
#
# Usage:
#   ./scripts/bootstrap.sh          # restore config + install deps
#   ./scripts/bootstrap.sh --sync   # also push local changes TO 1Password
#   ./scripts/bootstrap.sh --dry-run # show what would be done
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"

DRY_RUN=false
SYNC_MODE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --sync)    SYNC_MODE=true ;;
    --help|-h)
      echo "Usage: $0 [--sync] [--dry-run]"
      echo "  (default)   Pull config from 1Password and install deps"
      echo "  --sync      Push current local config files TO 1Password"
      echo "  --dry-run   Show what would be done without writing"
      exit 0
      ;;
  esac
done

# ── Config map ──────────────────────────────────────────────
# Each entry: "1password_item_id:relative_file_path"
# Override this array in each repo's bootstrap.sh.
# The item ID stores the file contents in the notesPlain field.
BOOTSTRAP_FILES=()

# Source repo-specific config if it exists
if [[ -f "$REPO_ROOT/scripts/bootstrap-config.sh" ]]; then
  source "$REPO_ROOT/scripts/bootstrap-config.sh"
fi

if [[ ${#BOOTSTRAP_FILES[@]} -eq 0 ]]; then
  echo "No BOOTSTRAP_FILES configured in scripts/bootstrap-config.sh"
  echo "Create that file with entries like:"
  echo '  BOOTSTRAP_FILES=('
  echo '    "op_item_id:.env.local"'
  echo '    "op_item_id:firebase-config.local.js"'
  echo '  )'
  exit 1
fi

# ── Preflight ───────────────────────────────────────────────
if ! command -v op &>/dev/null; then
  echo "Error: 1Password CLI (op) not found. Install from https://1password.com/downloads/command-line"
  exit 1
fi

# Verify 1Password session (op whoami may fail even when biometric auth works,
# so we test with a lightweight vault list instead)
if ! op vault list &>/dev/null; then
  echo "Error: Cannot access 1Password. Ensure you're signed in (op signin) and biometrics are available."
  exit 1
fi

echo "Repository: $REPO_NAME"
echo "Root:       $REPO_ROOT"
echo "Mode:       $(if $SYNC_MODE; then echo 'SYNC (push to 1Password)'; else echo 'RESTORE (pull from 1Password)'; fi)"
echo "Dry run:    $DRY_RUN"
echo ""

# ── Sync mode: push local files TO 1Password ───────────────
if $SYNC_MODE; then
  for entry in "${BOOTSTRAP_FILES[@]}"; do
    item_id="${entry%%:*}"
    file_path="${entry#*:}"
    full_path="$REPO_ROOT/$file_path"

    if [[ ! -f "$full_path" ]]; then
      echo "SKIP  $file_path (file not found)"
      continue
    fi

    echo "SYNC  $file_path -> 1Password ($item_id)"
    if ! $DRY_RUN; then
      op item edit "$item_id" "notesPlain=$(cat "$full_path")" >/dev/null
      echo "  OK"
    fi
  done
  echo ""
  echo "Sync complete."
  exit 0
fi

# ── Restore mode: pull from 1Password ──────────────────────
restored=0
skipped=0

for entry in "${BOOTSTRAP_FILES[@]}"; do
  item_id="${entry%%:*}"
  file_path="${entry#*:}"
  full_path="$REPO_ROOT/$file_path"

  if [[ -f "$full_path" ]]; then
    echo "EXISTS $file_path (skipping — use --sync to update 1Password)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "RESTORE $file_path <- 1Password ($item_id)"
  if ! $DRY_RUN; then
    # Ensure parent directory exists
    mkdir -p "$(dirname "$full_path")"
    op item get "$item_id" --fields notesPlain --format json 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('value',''))" \
      > "$full_path"
    echo "  OK"
  fi
  restored=$((restored + 1))
done

echo ""
echo "Restored: $restored  Skipped: $skipped"

# ── Install dependencies ────────────────────────────────────
if [[ -f "$REPO_ROOT/package.json" ]]; then
  echo ""
  echo "Installing npm dependencies..."
  if ! $DRY_RUN; then
    cd "$REPO_ROOT" && npm install
  fi
fi

# ── Build if needed ─────────────────────────────────────────
if [[ -f "$REPO_ROOT/package.json" ]] && grep -q '"build"' "$REPO_ROOT/package.json" 2>/dev/null; then
  echo ""
  echo "Running build..."
  if ! $DRY_RUN; then
    cd "$REPO_ROOT" && npm run build 2>&1 || echo "Build had warnings/errors (non-fatal)"
  fi
fi

echo ""
echo "Bootstrap complete."
