# bootstrap-config.sh — Repo-specific 1Password item mappings
#
# Each entry: "1password_item_id:relative_file_path"
# The item's notesPlain field stores the file contents.
#
# To add a new file:
#   1. Store it: op item create --category="Secure Note" --title="<Repo> Local Config (<filename>)" --vault=Private --tags=bootstrap "notesPlain=$(cat <file>)"
#   2. Copy the item ID and add an entry below.

BOOTSTRAP_FILES=(
  # "item_id:.env.local"
)
