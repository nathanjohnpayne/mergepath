#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# bootstrap.sh — Restore local config files from 1Password
#
# Run this after cloning on a new machine or switching computers.
# Requires: op CLI (1Password), authenticated session, biometrics.
#
# Usage:
#   ./scripts/bootstrap.sh              # restore config + install deps
#   ./scripts/bootstrap.sh --sync       # push local changes TO 1Password
#   ./scripts/bootstrap.sh --dry-run    # show what would be done
#   ./scripts/bootstrap.sh --force      # overwrite existing files
#
# How it works:
#   1. Reads bootstrap-config.sh for the list of files to manage.
#   2. For .env.tpl files: resolves op:// references via `op inject`.
#      This is the preferred pattern — secrets stay in 1Password,
#      only the template (with op:// URIs) is committed to git.
#   3. For legacy Secure Note items: reads the notesPlain field via
#      `op read` and writes it to disk.
#   4. Installs npm dependencies and runs the build.
#
# Best practices (from https://developer.1password.com/llms.txt):
#   - Prefer 1Password Environments for runtime variable sets
#   - Use `op run --environment <env_id> -- <command>` for runtime use
#   - Use mounted Environment .env files when the tool requires dotenv
#   - Never pass secrets as CLI arguments (use stdin or --template)
#   - Use `op inject` only when generating a gitignored file is required
#   - Treat Secure Note notesPlain storage as legacy compatibility
# ──────────────────────────────────────────────────────────────
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"

DRY_RUN=false
SYNC_MODE=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --sync)    SYNC_MODE=true ;;
    --force)   FORCE=true ;;
    --help|-h)
      echo "Usage: $0 [--sync] [--dry-run] [--force]"
      echo "  (default)   Pull config from 1Password and install deps"
      echo "  --sync      Push current local config files TO 1Password"
      echo "  --dry-run   Show what would be done without writing"
      echo "  --force     Overwrite existing files during restore"
      exit 0
      ;;
  esac
done

# ── Config ──────────────────────────────────────────────────
# BOOTSTRAP_FILES: array of "1password_item_id:relative_file_path"
#   The item's notesPlain field stores the file contents.
#   Prefer INJECT_FILES instead for new setups.
#
# INJECT_FILES: array of "template_path:output_path"
#   Template contains op:// references resolved by `op inject`.
#   This is the recommended pattern per 1Password best practices.
BOOTSTRAP_FILES=()
INJECT_FILES=()

# Source repo-specific config
if [[ -f "$REPO_ROOT/scripts/bootstrap-config.sh" ]]; then
  source "$REPO_ROOT/scripts/bootstrap-config.sh"
fi

if [[ ${#BOOTSTRAP_FILES[@]} -eq 0 && ${#INJECT_FILES[@]} -eq 0 ]]; then
  echo "No files configured in scripts/bootstrap-config.sh"
  echo ""
  echo "Preferred (op inject with templates):"
  echo '  INJECT_FILES=('
  echo '    ".env.tpl:.env.local"'
  echo '  )'
  echo ""
  echo "Legacy (Secure Note storage):"
  echo '  BOOTSTRAP_FILES=('
  echo '    "op_item_id:.env.local"'
  echo '  )'
  exit 1
fi

# ── Preflight ───────────────────────────────────────────────
if ! command -v op &>/dev/null; then
  echo "Error: 1Password CLI (op) not found."
  echo "Install: https://1password.com/downloads/command-line"
  exit 1
fi

if ! op vault list &>/dev/null; then
  echo "Error: Cannot access 1Password."
  echo "Run 'op signin' or enable biometrics."
  exit 1
fi

echo "Repository: $REPO_NAME"
echo "Root:       $REPO_ROOT"
if $SYNC_MODE; then
  echo "Mode:       SYNC (push to 1Password)"
else
  echo "Mode:       RESTORE (pull from 1Password)"
fi
echo "Dry run:    $DRY_RUN"
echo ""

# ── Sync mode: push local files TO 1Password ───────────────
if $SYNC_MODE; then
  for entry in "${BOOTSTRAP_FILES[@]}"; do
    item_id="${entry%%:*}"
    file_path="${entry#*:}"
    full_path="$REPO_ROOT/$file_path"

    if [[ ! -f "$full_path" ]]; then
      echo "SKIP  $file_path (not found)"
      continue
    fi

    echo "SYNC  $file_path -> 1Password ($item_id)"
    if ! $DRY_RUN; then
      # Use stdin to avoid leaking secrets in command history
      op item edit "$item_id" --stdin <<<"notesPlain=$(cat "$full_path")" >/dev/null 2>&1 \
        || op item edit "$item_id" "notesPlain=$(cat "$full_path")" >/dev/null
      echo "  OK"
    fi
  done

  if [[ ${#INJECT_FILES[@]} -gt 0 ]]; then
    echo ""
    echo "Note: INJECT_FILES use op:// references in committed templates."
    echo "To update secrets, edit them directly in 1Password."
  fi

  echo ""
  echo "Sync complete."
  exit 0
fi

# ── Restore: op inject templates (preferred) ────────────────
for entry in "${INJECT_FILES[@]}"; do
  tpl_path="${entry%%:*}"
  out_path="${entry#*:}"
  full_tpl="$REPO_ROOT/$tpl_path"
  full_out="$REPO_ROOT/$out_path"

  if [[ ! -f "$full_tpl" ]]; then
    echo "WARN  Template not found: $tpl_path"
    continue
  fi

  if [[ -f "$full_out" ]] && ! $FORCE; then
    echo "EXISTS $out_path (use --force to overwrite)"
    continue
  fi

  echo "INJECT $tpl_path -> $out_path"
  if ! $DRY_RUN; then
    mkdir -p "$(dirname "$full_out")"
    op inject -i "$full_tpl" -o "$full_out" -f
    echo "  OK"
  fi
done

# ── Restore: legacy Secure Note items ───────────────────────
for entry in "${BOOTSTRAP_FILES[@]}"; do
  item_id="${entry%%:*}"
  file_path="${entry#*:}"
  full_path="$REPO_ROOT/$file_path"

  if [[ -f "$full_path" ]] && ! $FORCE; then
    echo "EXISTS $file_path (use --force to overwrite)"
    continue
  fi

  echo "RESTORE $file_path <- 1Password ($item_id)"
  if ! $DRY_RUN; then
    mkdir -p "$(dirname "$full_path")"
    op read "op://Private/$item_id/notesPlain" > "$full_path"
    echo "  OK"
  fi
done

echo ""

# ── Install dependencies ────────────────────────────────────
if [[ -f "$REPO_ROOT/package.json" ]]; then
  echo "Installing npm dependencies..."
  if ! $DRY_RUN; then
    cd "$REPO_ROOT" && npm install
  fi
fi

# ── Build ───────────────────────────────────────────────────
if [[ -f "$REPO_ROOT/package.json" ]] && grep -q '"build"' "$REPO_ROOT/package.json" 2>/dev/null; then
  echo "Running build..."
  if ! $DRY_RUN; then
    cd "$REPO_ROOT" && npm run build 2>&1 || echo "Build had warnings/errors (non-fatal)"
  fi
fi

echo ""
echo "Bootstrap complete."
