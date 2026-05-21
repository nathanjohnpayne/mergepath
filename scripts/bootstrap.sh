#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# bootstrap.sh — Restore local config files from 1Password
#
# Run this after cloning on a new machine or switching computers.
# Requires: op CLI (1Password), authenticated session, biometrics.
#
# Usage:
#   ./scripts/bootstrap.sh              # restore config + install deps
#   ./scripts/bootstrap.sh --dry-run    # show what would be done
#   ./scripts/bootstrap.sh --force      # overwrite existing files
#
# How it works:
#   1. Reads bootstrap-config.sh for the list of files to manage.
#   2. For .env.tpl files: resolves op:// references via `op inject`.
#      This is the preferred pattern — secrets stay in 1Password,
#      only the template (with op:// URIs) is committed to git.
#   3. Installs npm dependencies and runs the build.
#
# Best practices (from current 1Password Environments / CLI docs):
#   - Prefer 1Password Environments for runtime variable sets
#   - Use `op run --environment <env_id> -- <command>` for runtime use
#   - Use mounted Environment .env files when the tool requires dotenv
#   - Never pass secrets as CLI arguments (use stdin or --template)
#   - Use `op inject` only when generating a gitignored file is required
#   - Do not use Secure Note notesPlain whole-file bootstrap storage
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"

DRY_RUN=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --sync)
      echo "Error: --sync was removed with the legacy Secure Note notesPlain bootstrap path." >&2
      echo "Edit secrets directly in 1Password, update committed .env.tpl templates as needed," >&2
      echo "then run: $0 --force" >&2
      exit 2
      ;;
    --force)   FORCE=true ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--force]"
      echo "  (default)   Pull config from 1Password and install deps"
      echo "  --dry-run   Show what would be done without writing"
      echo "  --force     Overwrite existing files during restore"
      exit 0
      ;;
    *)
      echo "Error: unknown option: $arg" >&2
      echo "Usage: $0 [--dry-run] [--force]" >&2
      exit 1
      ;;
  esac
done

# ── Config ──────────────────────────────────────────────────
# INJECT_FILES: array of "template_path:output_path"
#   Template contains op:// references resolved by `op inject`.
#   This is the recommended pattern per 1Password best practices.
# BOOTSTRAP_FILES was the legacy Secure Note notesPlain path. It is
# kept only as a compatibility sentinel so stale consumer configs fail
# with a targeted migration message instead of silently doing nothing.
BOOTSTRAP_FILES=()
INJECT_FILES=()

# Source repo-specific config
if [[ -f "$REPO_ROOT/scripts/bootstrap-config.sh" ]]; then
  source "$REPO_ROOT/scripts/bootstrap-config.sh"
fi

if [[ ${#BOOTSTRAP_FILES[@]} -gt 0 ]]; then
  echo "Error: legacy BOOTSTRAP_FILES / notesPlain bootstrap entries are no longer supported." >&2
  echo "Migrate each entry to an INJECT_FILES template with op:// references, for example:" >&2
  echo '  INJECT_FILES=(' >&2
  echo '    ".env.tpl:.env.local"' >&2
  echo '  )' >&2
  exit 2
fi

if [[ ${#INJECT_FILES[@]} -eq 0 ]]; then
  echo "No files configured in scripts/bootstrap-config.sh"
  echo ""
  echo "Configure generated files with op inject templates:"
  echo '  INJECT_FILES=('
  echo '    ".env.tpl:.env.local"'
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
echo "Mode:       RESTORE (pull from 1Password templates)"
echo "Dry run:    $DRY_RUN"
echo ""

# ── Restore: op inject templates ────────────────────────────
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
