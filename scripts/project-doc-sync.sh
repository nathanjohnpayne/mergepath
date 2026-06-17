#!/usr/bin/env bash
# scripts/project-doc-sync.sh
#
# Audit or materialize project documentation mirrors declared in
# .mergepath-project-docs.yml.
#
# Sync direction is asymmetric:
#   - PRDs:  central docs repo -> owning repo generated mirror
#   - specs: owning repo specs/ -> central docs repo generated mirror

set -euo pipefail

SCRIPT_VERSION="0.1.0"
SUPPORTED_VERSION=1
MANIFEST_PATH=".mergepath-project-docs.yml"
MODE="audit"
FILTER_PROJECTS=""
NO_CLONE=0

MERGEPATH_ROOT="${MERGEPATH_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SIBLINGS_DIR="${MERGEPATH_PROJECT_DOCS_SIBLINGS_DIR:-$HOME/GitHub}"
CACHE_DIR="${MERGEPATH_PROJECT_DOCS_CACHE:-$HOME/.cache/mergepath-project-docs}"

DRIFT_FOUND=0
ERROR_FOUND=0

log() { echo "[project-doc-sync] $*" >&2; }
err() { echo "[project-doc-sync] ERROR: $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  scripts/project-doc-sync.sh --audit [--projects p1,p2] [--no-clone]
  scripts/project-doc-sync.sh --materialize [--projects p1,p2]
  scripts/project-doc-sync.sh --help

Flags:
  --audit        Read-only drift check. Exit 0 clean, 1 drift, 2 error.
  --materialize  Write generated mirrors into local source/target checkouts.
  --projects     Comma-separated project slug filter.
  --no-clone     Audit only: do not clone missing read-only repos.
EOF
}

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    err "yq is required (mikefarah/yq v4+)."
    exit 2
  fi
  if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
    err "detected non-mikefarah yq: $(yq --version 2>&1)"
    exit 2
  fi
}

require_manifest() {
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"
  if [ ! -f "$manifest" ]; then
    err "manifest missing: $MANIFEST_PATH"
    exit 2
  fi
  if ! yq '.' "$manifest" >/dev/null 2>&1; then
    err "manifest does not parse as YAML"
    yq '.' "$manifest" || true
    exit 2
  fi
  local version
  version=$(yq '.version' "$manifest")
  if [ "$version" != "$SUPPORTED_VERSION" ]; then
    err "manifest version $version not supported (supports $SUPPORTED_VERSION)"
    exit 2
  fi
}

in_project_filter() {
  local slug=$1
  [ -z "$FILTER_PROJECTS" ] && return 0
  [[ ",$FILTER_PROJECTS," == *",$slug,"* ]]
}

resolve_hint() {
  local name=$1 hint=$2
  [ -z "$hint" ] && return 1

  case "$hint" in
    /*)
      [ -e "$hint/.git" ] || [ -d "$hint" ] || return 1
      printf '%s\n' "$hint"
      return 0
      ;;
    .)
      printf '%s\n' "$MERGEPATH_ROOT"
      return 0
      ;;
    ..|../*|./*)
      local p="$MERGEPATH_ROOT/$hint"
      [ -d "$p" ] || return 1
      (cd "$p" && pwd)
      return 0
      ;;
    *)
      if [ -d "$SIBLINGS_DIR/$hint" ]; then
        printf '%s\n' "$SIBLINGS_DIR/$hint"
        return 0
      fi
      if [ -d "$MERGEPATH_ROOT/$hint" ]; then
        (cd "$MERGEPATH_ROOT/$hint" && pwd)
        return 0
      fi
      if [ -d "$SIBLINGS_DIR/$name" ]; then
        printf '%s\n' "$SIBLINGS_DIR/$name"
        return 0
      fi
      ;;
  esac
  return 1
}

clone_for_audit() {
  local name=$1 repo=$2
  local target="$CACHE_DIR/$name"
  if [ -e "$target/.git" ]; then
    local phys_target phys_cache
    if [ -L "$target" ]; then
      err "refusing to refresh $target - it is a symbolic link"
      return 1
    fi
    phys_target=$(cd "$target" 2>/dev/null && pwd -P) || return 1
    phys_cache=$(mkdir -p "$CACHE_DIR" && cd "$CACHE_DIR" 2>/dev/null && pwd -P) || return 1
    case "$phys_target/" in
      "$phys_cache"/*) ;;
      *)
        err "refusing to refresh $target - physical path escapes cache root"
        return 1
        ;;
    esac

    if [ "$(git -C "$target" rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
      git -C "$target" fetch --unshallow --quiet origin >&2 || return 1
    fi
    git -C "$target" fetch --quiet origin HEAD >&2 || return 1
    git -C "$target" reset --hard --quiet FETCH_HEAD >&2 || return 1
    printf '%s\n' "$target"
    return 0
  fi
  [ "$NO_CLONE" = "1" ] && return 1
  mkdir -p "$CACHE_DIR"
  gh repo clone "$repo" "$target" -- --quiet >&2 || return 1
  printf '%s\n' "$target"
}

resolve_repo() {
  local name=$1 repo=$2 hint=$3 write_required=$4
  local resolved=""
  if resolved=$(resolve_hint "$name" "$hint" 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi
  if [ "$write_required" = "1" ]; then
    err "local writable checkout for '$name' not found (hint: ${hint:-none})"
    return 1
  fi
  if resolved=$(clone_for_audit "$name" "$repo" 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi
  err "could not resolve repo '$name' ($repo)"
  return 1
}

repo_ref() {
  local root=$1 path=${2:-}
  local ref
  if [ -n "$path" ]; then
    ref=$(git -C "$root" log -n 1 --format=%h -- "$path" 2>/dev/null || true)
  else
    ref=""
  fi
  if [ -z "$ref" ]; then
    ref=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
  fi
  if [ "$ref" != "unknown" ]; then
    local path_args=()
    if [ -n "$path" ]; then
      path_args=(-- "$path")
    else
      path_args=(--)
    fi

    if ! git -C "$root" diff --quiet --ignore-submodules "${path_args[@]}" 2>/dev/null ||
      ! git -C "$root" diff --cached --quiet --ignore-submodules "${path_args[@]}" 2>/dev/null ||
      [ -n "$(git -C "$root" ls-files --others --exclude-standard "${path_args[@]}" 2>/dev/null)" ]; then
      ref="${ref}-dirty"
    fi
  fi
  printf '%s\n' "$ref"
}

render_header() {
  local source_repo=$1 source_path=$2 source_ref=$3 project=$4 class=$5 slug=$6 direction=$7
  cat <<EOF
<!--
generated_by: scripts/project-doc-sync.sh
do_not_edit: true
source_repo: ${source_repo}
source_path: ${source_path}
source_ref: ${source_ref}
project: ${project}
document_class: ${class}
document_slug: ${slug}
sync_direction: ${direction}
-->

EOF
}

write_expected() {
  local out=$1 source_file=$2 source_repo=$3 source_path=$4 source_ref=$5 project=$6 class=$7 slug=$8 direction=$9
  render_header "$source_repo" "$source_path" "$source_ref" "$project" "$class" "$slug" "$direction" >"$out"
  cat "$source_file" >>"$out"
}

compare_or_materialize() {
  local label=$1 expected=$2 target=$3
  if [ "$MODE" = "materialize" ]; then
    mkdir -p "$(dirname "$target")"
    local tmp_target
    tmp_target=$(mktemp "$(dirname "$target")/.project-doc-sync.XXXXXX")
    cp "$expected" "$tmp_target"
    mv -f "$tmp_target" "$target"
    printf "WRITE %s\n" "$label"
    return 0
  fi
  if [ ! -e "$target" ]; then
    printf "MISS  %s\n" "$label"
    DRIFT_FOUND=1
    return 0
  fi
  if cmp -s "$expected" "$target"; then
    printf "OK    %s\n" "$label"
  else
    printf "DRIFT %s\n" "$label"
    DRIFT_FOUND=1
  fi
}

is_generated_spec_mirror() {
  local file=$1 source_repo=$2 project=$3
  sed -n '1,14p' "$file" | grep -Fqx "generated_by: scripts/project-doc-sync.sh" &&
    sed -n '1,14p' "$file" | grep -Fqx "source_repo: ${source_repo}" &&
    sed -n '1,14p' "$file" | grep -Fqx "project: ${project}" &&
    sed -n '1,14p' "$file" | grep -Fqx "document_class: spec"
}

handle_orphan_spec_mirror() {
  local label=$1 target=$2
  if [ "$MODE" = "materialize" ]; then
    rm -f "$target"
    printf "REMOVE %s\n" "$label"
    return 0
  fi
  printf "DRIFT %s\n" "$label"
  DRIFT_FOUND=1
}

validate_project_filter() {
  local manifest=$1
  [ -z "$FILTER_PROJECTS" ] && return 0

  local known=","
  local slug
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    known="${known}${slug},"
  done < <(yq -r '.projects[].slug' "$manifest")

  local old_ifs=$IFS
  IFS=,
  for slug in $FILTER_PROJECTS; do
    [ -n "$slug" ] || continue
    if [[ "$known" != *",$slug,"* ]]; then
      err "unknown project in --projects: $slug"
      IFS=$old_ifs
      exit 2
    fi
  done
  IFS=$old_ifs
}

process_prds() {
  local manifest=$1 central_root=$2 central_repo=$3 central_hint=$4
  local rows
  rows=$(yq -r '
    .projects[]
    | .slug as $project
    | .owner.name as $owner_name
    | .owner.repo as $owner_repo
    | (.owner.path_hint // "") as $owner_hint
    | (.prds // [])[]
    | $project + "\t" + $owner_name + "\t" + $owner_repo + "\t" + $owner_hint
      + "\t" + .slug + "\t" + .source + "\t" + .mirror
  ' "$manifest")

  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r project owner_name owner_repo owner_hint slug source mirror; do
    [ -z "$project" ] && continue
    in_project_filter "$project" || continue

    local owner_root
    if ! owner_root=$(resolve_repo "$owner_name" "$owner_repo" "$owner_hint" "$([ "$MODE" = "materialize" ] && echo 1 || echo 0)"); then
      ERROR_FOUND=1
      continue
    fi

    local source_file="$central_root/$source"
    if [ ! -f "$source_file" ]; then
      printf "MISS  %s prd:%s source missing at %s\n" "$project" "$slug" "$source"
      DRIFT_FOUND=1
      continue
    fi

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/project-doc-prd.XXXXXX")
    write_expected "$tmp" "$source_file" "$central_repo" "$source" "$(repo_ref "$central_root" "$source")" \
      "$project" "prd" "$slug" "central-to-repo"

    local label="$project prd:$slug -> $owner_name:$mirror"
    compare_or_materialize "$label" "$tmp" "$owner_root/$mirror"
    rm -f "$tmp"
  done <<< "$rows"
}

process_specs() {
  local manifest=$1 central_root=$2 central_repo=$3
  local rows
  rows=$(yq -r '
    .projects[]
    | .slug as $project
    | .owner.name as $owner_name
    | .owner.repo as $owner_repo
    | (.owner.path_hint // "") as $owner_hint
    | (.specs // [])[]
    | $project + "\t" + $owner_name + "\t" + $owner_repo + "\t" + $owner_hint
      + "\t" + .source + "\t" + .mirror
  ' "$manifest")

  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r project owner_name owner_repo owner_hint source mirror; do
    [ -z "$project" ] && continue
    in_project_filter "$project" || continue

    local owner_root
    if ! owner_root=$(resolve_repo "$owner_name" "$owner_repo" "$owner_hint" 0); then
      ERROR_FOUND=1
      continue
    fi

    local source_dir="$owner_root/${source%/}"
    if [ ! -d "$source_dir" ]; then
      printf "MISS  %s specs source missing at %s:%s\n" "$project" "$owner_name" "$source"
      DRIFT_FOUND=1
      continue
    fi

    local expected_rels
    expected_rels=$(mktemp "${TMPDIR:-/tmp}/project-doc-expected-specs.XXXXXX")
    local target_dir="$central_root/${mirror%/}"

    while IFS= read -r source_file; do
      [ -z "$source_file" ] && continue
      local rel="${source_file#"$source_dir/"}"
      printf '%s\n' "$rel" >>"$expected_rels"
      local slug="${rel%.md}"
      local target="$central_root/${mirror%/}/$rel"
      local tmp
      tmp=$(mktemp "${TMPDIR:-/tmp}/project-doc-spec.XXXXXX")
      write_expected "$tmp" "$source_file" "$owner_repo" "${source%/}/$rel" "$(repo_ref "$owner_root" "${source%/}/$rel")" \
        "$project" "spec" "$slug" "repo-to-central"
      compare_or_materialize "$project spec:$slug -> ${central_repo}:${mirror%/}/$rel" "$tmp" "$target"
      rm -f "$tmp"
    done < <(find "$source_dir" -type f -name '*.md' -print | LC_ALL=C sort)

    if [ -d "$target_dir" ]; then
      while IFS= read -r target_file; do
        [ -z "$target_file" ] && continue
        local rel="${target_file#"$target_dir/"}"
        grep -Fxq "$rel" "$expected_rels" && continue
        is_generated_spec_mirror "$target_file" "$owner_repo" "$project" || continue

        local slug="${rel%.md}"
        handle_orphan_spec_mirror \
          "$project spec:$slug orphan -> ${central_repo}:${mirror%/}/$rel" \
          "$target_file"
      done < <(find "$target_dir" -type f -name '*.md' -print | LC_ALL=C sort)
    fi
    rm -f "$expected_rels"
  done <<< "$rows"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit)
      MODE="audit"; shift ;;
    --materialize)
      MODE="materialize"; shift ;;
    --projects)
      [ -n "${2:-}" ] || { err "missing argument for --projects"; exit 2; }
      FILTER_PROJECTS=$2; shift 2 ;;
    --no-clone)
      NO_CLONE=1; shift ;;
    --help|-h)
      usage; exit 0 ;;
    --version)
      echo "project-doc-sync.sh $SCRIPT_VERSION"; exit 0 ;;
    *)
      err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

require_yq
require_manifest

manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"
validate_project_filter "$manifest"
central_name=$(yq -r '.central_repo.name' "$manifest")
central_repo=$(yq -r '.central_repo.repo' "$manifest")
central_hint=$(yq -r '.central_repo.path_hint // ""' "$manifest")

write_central=0
[ "$MODE" = "materialize" ] && write_central=1
if ! central_root=$(resolve_repo "$central_name" "$central_repo" "$central_hint" "$write_central"); then
  exit 2
fi

process_prds "$manifest" "$central_root" "$central_repo" "$central_hint"
process_specs "$manifest" "$central_root" "$central_repo"

if [ "$ERROR_FOUND" = "1" ]; then
  exit 2
fi
if [ "$DRIFT_FOUND" = "1" ]; then
  exit 1
fi
exit 0
