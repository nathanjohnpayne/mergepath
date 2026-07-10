#!/usr/bin/env bash
# scripts/bootstrap/substitute.sh — name-substitution lib for the
# bootstrap wizard. Applies a curated, allow-list-driven rewrite of
# mergepath-name references in name-bearing files of a freshly
# mirrored target repo.
#
# Surface:
#   bootstrap::apply_name_substitutions <target_dir>
#       For each entry in BOOTSTRAP_NAME_BEARING_FILES, sed-substitute
#       the three documented forms of the mergepath name to the new
#       repo's identity. Skips files that aren't present in the target
#       (e.g., because of an exclude — emits a warning, doesn't error).
#
#   bootstrap::_substitute_one_file <file> <repo_name> <repo_url>
#                                   <description>
#       Internal — performs the actual sed pipeline on a single file.
#       Exposed so tests can drive it directly.
#
# Design notes:
#
# - We use literal-name substitution (curated allow-list) rather than
#   token-marker substitution ({{REPO_NAME}}). The marker approach
#   would require either dual-rendering of mergepath's own README
#   (markers visible to direct readers — bad UX) or a sentinel-pair
#   hack. #204 acceptance § "Bootstrap-mode markers" chose option (b)
#   "mergepath-as-itself substitution" which collapses to: no markers
#   in mergepath's files, do the substitution at wizard time.
#
# - The allow-list is hard-coded by path. New name-bearing files MUST
#   be added to BOOTSTRAP_NAME_BEARING_FILES explicitly. This is
#   deliberate: a wildcard sed across the whole tree would clobber
#   historical references (e.g., commit-message embeds, incident
#   reports, the `mergepath#NN` issue-link convention).
#
# - The substitutions cover three forms:
#     "mergepath"  → $repo_name           (the canonical name)
#     "Mergepath"  → $Repo_Name           (Titlecased)
#     "MERGEPATH"  → $REPO_NAME           (uppercase, for env vars)
#   Plus URL rewrite:
#     "https://github.com/nathanjohnpayne/mergepath" → $repo_url
#   And description (only if the literal "MERGEPATH_DESCRIPTION_HERE"
#   marker is found in a file; we don't have a one-line description
#   string in the templates today, but the wizard supports passing one,
#   so we expose the substitution for future use).

set -euo pipefail

# Files that get name substitution. Each path is relative to the
# target repo root. Started as #204's "6 name-bearing files" list;
# BRAND.md and docs/agents/repository-overview.md were removed in #744
# because a lexical mergepath→<repo> swap leaves their self-referential
# hub identity ("the reference implementation", the Playground) intact
# and FALSE. They are excluded from the mirror and replaced by neutral
# consumer stubs in bootstrap::_scaffold_consumer_identity instead.
BOOTSTRAP_NAME_BEARING_FILES=(
  README.md
  .ai_context.md
  .repo-template.yml
  SECURITY.md
)

# Helper — uppercase the first character of $1, leave the rest. Used
# to derive the Titlecased form. Pure bash to avoid an awk dep for a
# one-shot transform.
bootstrap::_titlecase_first() {
  local s=$1
  if [ -z "$s" ]; then
    echo ""
    return 0
  fi
  local first=${s:0:1}
  local rest=${s:1}
  # bash 3.2 has no ${var^^} — use tr.
  local first_upper
  first_upper=$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')
  printf '%s%s' "$first_upper" "$rest"
}

# Substitute name references in a single file. Idempotent on success
# (a second invocation against an already-substituted file is a no-op).
#
# Args:
#   $1  Absolute path to the file (must exist).
#   $2  repo_name (lowercase, hyphenated — e.g., "auth-frontend").
#   $3  repo_url  (full URL — e.g., "https://github.com/.../auth-frontend").
#   $4  description (free-form; can be empty).
bootstrap::_substitute_one_file() {
  local file=$1
  local repo_name=$2
  local repo_url=$3
  local description=${4:-}

  if [ ! -f "$file" ]; then
    bootstrap::warn "substitute: file missing, skipping: $file"
    return 0
  fi

  local repo_name_title
  repo_name_title=$(bootstrap::_titlecase_first "$repo_name")
  local repo_name_upper
  repo_name_upper=$(printf '%s' "$repo_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

  # Escape sed-active chars in the replacement values. sed-active
  # chars on the replacement side are: the delimiter (we use |), &,
  # and backslash. Escape all three.
  local rn_esc=${repo_name//\\/\\\\}
  rn_esc=${rn_esc//&/\\&}
  rn_esc=${rn_esc//|/\\|}
  local rnt_esc=${repo_name_title//\\/\\\\}
  rnt_esc=${rnt_esc//&/\\&}
  rnt_esc=${rnt_esc//|/\\|}
  local rnu_esc=${repo_name_upper//\\/\\\\}
  rnu_esc=${rnu_esc//&/\\&}
  rnu_esc=${rnu_esc//|/\\|}
  local ru_esc=${repo_url//\\/\\\\}
  ru_esc=${ru_esc//&/\\&}
  ru_esc=${ru_esc//|/\\|}
  local desc_esc=${description//\\/\\\\}
  desc_esc=${desc_esc//&/\\&}
  desc_esc=${desc_esc//|/\\|}

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-sub.XXXXXX")
  # Order matters: do the URL replacement BEFORE the bare "mergepath"
  # so we don't substitute the path component of the URL twice. The
  # repo_url path component never contains "mergepath" (the new repo
  # has a different name), so this ordering keeps the URL whole.
  sed \
    -e "s|https://github.com/nathanjohnpayne/mergepath|$ru_esc|g" \
    -e "s|MERGEPATH|$rnu_esc|g" \
    -e "s|Mergepath|$rnt_esc|g" \
    -e "s|mergepath|$rn_esc|g" \
    "$file" > "$tmp"

  # If a description marker is present and a description was given,
  # apply that too. We don't have such a marker in mergepath's
  # templates today, but the substitution path is set up so a future
  # repo template can opt into a one-line description string.
  if [ -n "$desc_esc" ]; then
    local tmp2
    tmp2=$(mktemp "${TMPDIR:-/tmp}/bootstrap-sub.XXXXXX")
    sed "s|MERGEPATH_DESCRIPTION_HERE|$desc_esc|g" "$tmp" > "$tmp2"
    mv "$tmp2" "$tmp"
  fi

  mv "$tmp" "$file"
}

# Apply substitutions across all name-bearing files in $target.
bootstrap::apply_name_substitutions() {
  local target=$1

  local repo_name
  repo_name=$(bootstrap_input repo_name)
  local description
  description=$(bootstrap_input description)
  local owner="${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}"
  local repo_url="https://github.com/${owner}/${repo_name}"

  local f
  for f in "${BOOTSTRAP_NAME_BEARING_FILES[@]}"; do
    local file="$target/$f"
    if [ ! -e "$file" ]; then
      bootstrap::warn "substitute: name-bearing file not present in target, skipping: $f"
      continue
    fi
    bootstrap::run "substitute names in $f" \
      bootstrap::_substitute_one_file "$file" "$repo_name" "$repo_url" "$description"
  done
}
