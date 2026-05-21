# bootstrap-config.sh — Repo-specific 1Password template mappings
#
# Each entry: "template_path:output_path"
# Templates contain op:// references resolved by `op inject`.
# Templates are committed to git; generated output files are gitignored.
#
# Example:
#   1. Create .env.tpl with op:// references.
#   2. Add ".env.tpl:.env.local" below.
#   3. Run ./scripts/bootstrap.sh --force.

INJECT_FILES=(
  # ".env.tpl:.env.local"
)
