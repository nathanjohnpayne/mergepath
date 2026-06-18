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
  # NB: do not suppress clone_for_audit's stderr here — it carries the
  # cache safety-guard reasons (symlinked target, path escaping the cache
  # root) and clone/fetch failures the operator needs to see. It already
  # runs git/gh with --quiet, so the happy path stays near-silent.
  if resolved=$(clone_for_audit "$name" "$repo"); then
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
    # Write via temp + atomic rename. Clean the temp on any failure so a
    # half-written dotfile never lingers in the (git-tracked) target dir.
    if cp "$expected" "$tmp_target" && mv -f "$tmp_target" "$target"; then
      printf "WRITE %s\n" "$label"
      return 0
    fi
    rm -f "$tmp_target"
    err "failed to materialize $target"
    return 1
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

is_generated_mirror() {
  local file=$1 source_repo=$2 project=$3 class=$4
  local head
  head=$(sed -n '1,14p' "$file")
  printf '%s\n' "$head" | grep -Fqx "generated_by: scripts/project-doc-sync.sh" || return 1
  # An empty source_repo skips that field (the whole-project-removal sweep
  # no longer knows the owning repo); the project + class headers still gate it.
  if [ -n "$source_repo" ]; then
    printf '%s\n' "$head" | grep -Fqx "source_repo: ${source_repo}" || return 1
  fi
  printf '%s\n' "$head" | grep -Fqx "project: ${project}" || return 1
  printf '%s\n' "$head" | grep -Fqx "document_class: ${class}"
}

handle_orphan_mirror() {
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

# Fail closed on any manifest slug, owner/central name, or source/mirror that
# contains a `..` path component, so a mistaken or hostile value can never make
# --materialize write (or the orphan pass remove) a file outside the generated
# mirror tree — nor make clone_for_audit place a cache clone outside its root
# (`name` feeds $CACHE_DIR/$name). owner/central `path_hint` is intentionally
# exempt: it legitimately uses `..` to point at sibling checkouts. (Codex on #509.)
validate_manifest_paths() {
  local manifest=$1
  local bad=0 val
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    case "/$val/" in
      */../*)
        err "manifest path contains a '..' traversal component: $val"
        bad=1
        ;;
    esac
  done < <(yq -r '
    .central_repo.name,
    (.projects[]
      | (.slug, .owner.name,
         ((.prds // [])[] | (.source, .mirror)),
         ((.specs // [])[] | (.source, .mirror))))
  ' "$manifest")
  [ "$bad" -eq 0 ] || exit 2
}

process_prds() {
  local manifest=$1 central_root=$2 central_repo=$3
  local rows
  rows=$(yq -r '
    .projects[]
    | .slug as $project
    | .owner.name as $owner_name
    | .owner.repo as $owner_repo
    | (.owner.path_hint // "") as $owner_hint
    | (.prds // [])[]
    | $project + "\t" + $owner_name + "\t" + $owner_repo + "\t" + $owner_hint
      + "\t" + (.slug // "") + "\t" + (.source // "") + "\t" + (.mirror // "")
  ' "$manifest")

  [ -z "$rows" ] && return 0

  while IFS=$'\t' read -r project owner_name owner_repo owner_hint slug source mirror; do
    [ -z "$project" ] && continue
    in_project_filter "$project" || continue
    if [ -z "$slug" ] || [ -z "$source" ] || [ -z "$mirror" ]; then
      err "project '$project' has a PRD entry missing slug/source/mirror"
      ERROR_FOUND=1
      continue
    fi

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
    tmp=$(mktemp "$RUN_TMPDIR/prd.XXXXXX")
    write_expected "$tmp" "$source_file" "$central_repo" "$source" "$(repo_ref "$central_root" "$source")" \
      "$project" "prd" "$slug" "central-to-repo"

    local label="$project prd:$slug -> $owner_name:$mirror"
    compare_or_materialize "$label" "$tmp" "$owner_root/$mirror"
    rm -f "$tmp"
  done <<< "$rows"
}

# Flag (audit) or remove (materialize) one orphaned generated mirror: a file
# under DIR carrying this script's generated header for PROJECT+CLASS that the
# current run did not expect (its path is absent from EXPECTED_PATHS). Only
# files matching the header are ever touched, so hand-written files are safe.
scan_orphan_dir() {
  local dir=$1 source_repo=$2 project=$3 class=$4 expected_paths=$5 label_prefix=$6 label_dest=$7
  [ -d "$dir" ] || return 0
  local target_file rel slug
  while IFS= read -r target_file; do
    [ -z "$target_file" ] && continue
    grep -Fxq "$target_file" "$expected_paths" && continue
    is_generated_mirror "$target_file" "$source_repo" "$project" "$class" || continue
    rel="${target_file#"$dir/"}"
    slug="${rel%.md}"
    handle_orphan_mirror "${label_prefix}:${slug} orphan -> ${label_dest}/${rel}" "$target_file"
  done < <(find "$dir" -type f -name '*.md' -print | LC_ALL=C sort)
}

# Project-driven orphan sweep. Runs AFTER the comparison passes. For EVERY
# project in the manifest (not just those with a live mapping of a class), it
# re-derives the set of expected mirrors from the manifest + current sources
# and flags/removes any generated mirror that is no longer expected — catching
# a slug rename, a deleted source file, an emptied source dir, OR a project's
# whole prds:/specs: list removed from the manifest. It is self-contained (does
# not rely on the comparison passes) and skips any project whose owner cannot
# be resolved, so an unreachable checkout is never mistaken for "all orphaned".
#
# Mirror dirs follow the normalized layout from the PRD:
#   PRD mirror  (owner repo):   docs/projects/<slug>/prds/
#   spec mirror (central repo): projects/<slug>/specs/
prune_orphan_mirrors() {
  local manifest=$1 central_root=$2 central_repo=$3
  local rows
  rows=$(yq -r '
    .projects[]
    | .slug + "\t" + .owner.name + "\t" + .owner.repo + "\t" + (.owner.path_hint // "")
  ' "$manifest")

  local project owner_name owner_repo owner_hint
  while IFS=$'\t' read -r project owner_name owner_repo owner_hint; do
    [ -z "$project" ] && continue
    in_project_filter "$project" || continue

    # Spec pruning only READS the owner (to enumerate current sources); the
    # removal target is the writable central repo. So a read-only owner — a
    # cloned one included — is sufficient, matching how process_specs mirrors
    # specs from a read-only clone. Resolve read-only; an owner that is wholly
    # unreachable is skipped rather than mass-flagging its mirrors.
    local owner_ro=""
    owner_ro=$(resolve_repo "$owner_name" "$owner_repo" "$owner_hint" 0 2>/dev/null) || owner_ro=""

    # spec orphans (central side): expected = mirrors of the owner's CURRENT
    # source spec files (empty when the source/mapping is gone → all stale).
    if [ -n "$owner_ro" ]; then
      local spec_dir="$central_root/projects/$project/specs"
      if [ -d "$spec_dir" ]; then
        local spec_exp
        spec_exp=$(mktemp "$RUN_TMPDIR/spec-exp.XXXXXX")
        while IFS=$'\t' read -r s_source s_mirror; do
          if [ -z "$s_source" ] || [ -z "$s_mirror" ]; then continue; fi
          local sdir="$owner_ro/${s_source%/}"
          [ -d "$sdir" ] || continue
          while IFS= read -r sf; do
            [ -z "$sf" ] && continue
            printf '%s\n' "$central_root/${s_mirror%/}/${sf#"$sdir/"}"
          done < <(find "$sdir" -type f -name '*.md' -print)
        done < <(SLUG="$project" yq -r '.projects[] | select(.slug == strenv(SLUG)) | (.specs // [])[] | (.source // "") + "\t" + (.mirror // "")' "$manifest") >"$spec_exp"
        scan_orphan_dir "$spec_dir" "$owner_repo" "$project" spec "$spec_exp" \
          "$project spec" "$central_repo:projects/$project/specs"
        rm -f "$spec_exp"
      fi
    fi

    # PRD pruning removes files IN the owner repo, so materialize needs a local
    # writable checkout (matching process_prds); audit can use the same
    # read-only checkout. A clone-only owner in materialize is skipped here —
    # process_prds already raised the error for its declared PRD mappings.
    local owner_rw=""
    if [ "$MODE" = "materialize" ]; then
      owner_rw=$(resolve_repo "$owner_name" "$owner_repo" "$owner_hint" 1 2>/dev/null) || owner_rw=""
    else
      owner_rw="$owner_ro"
    fi
    if [ -n "$owner_rw" ]; then
      local prd_dir="$owner_rw/docs/projects/$project/prds"
      if [ -d "$prd_dir" ]; then
        local prd_exp
        prd_exp=$(mktemp "$RUN_TMPDIR/prd-exp.XXXXXX")
        while IFS= read -r m; do
          [ -n "$m" ] && printf '%s\n' "$owner_rw/$m"
        done < <(SLUG="$project" yq -r '.projects[] | select(.slug == strenv(SLUG)) | (.prds // [])[] | .mirror // ""' "$manifest") >"$prd_exp"
        scan_orphan_dir "$prd_dir" "$central_repo" "$project" prd "$prd_exp" \
          "$project prd" "$owner_name:docs/projects/$project/prds"
        rm -f "$prd_exp"
      fi
    fi
  done <<< "$rows"

  # Whole-project removal (central side): a generated spec mirror whose project
  # slug is no longer in the manifest. Owner-side PRD mirrors of a fully-removed
  # project are NOT detectable — the manifest no longer names the repo to scan
  # (documented limitation). Full-audit only: a --projects run is scoped and
  # must not touch projects outside the filter.
  if [ -z "$FILTER_PROJECTS" ] && [ -d "$central_root/projects" ]; then
    prune_unlisted_central_spec_mirrors "$manifest" "$central_root"
  fi
}

# Sweep central projects/<slug>/specs/ for generated spec mirrors whose slug is
# no longer a manifest project (a fully-decommissioned project). Header-gated,
# so non-generated files and central PRD sources (projects/<slug>/prds/) are
# never touched.
prune_unlisted_central_spec_mirrors() {
  local manifest=$1 central_root=$2
  local known="," slug
  while IFS= read -r slug; do
    [ -n "$slug" ] && known="${known}${slug},"
  done < <(yq -r '.projects[].slug' "$manifest")

  local f rest pslug rel
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rest="${f#"$central_root/projects/"}"
    pslug="${rest%%/*}"
    [[ "$known" == *",$pslug,"* ]] && continue
    is_generated_mirror "$f" "" "$pslug" spec || continue
    rel="${f#"$central_root/projects/$pslug/specs/"}"
    handle_orphan_mirror \
      "$pslug spec:${rel%.md} orphan (project not in manifest) -> $central_root/projects/$pslug/specs/$rel" \
      "$f"
  done < <(find "$central_root/projects" -type f -name '*.md' -path '*/specs/*' -print | LC_ALL=C sort)
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
      + "\t" + (.source // "") + "\t" + (.mirror // "")
  ' "$manifest")

  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r project owner_name owner_repo owner_hint source mirror; do
    [ -z "$project" ] && continue
    in_project_filter "$project" || continue
    if [ -z "$source" ] || [ -z "$mirror" ]; then
      err "project '$project' has a spec entry missing source/mirror"
      ERROR_FOUND=1
      continue
    fi

    local owner_root
    if ! owner_root=$(resolve_repo "$owner_name" "$owner_repo" "$owner_hint" 0); then
      ERROR_FOUND=1
      continue
    fi

    local source_dir="$owner_root/${source%/}"
    if [ ! -d "$source_dir" ]; then
      # Source dir gone: every central mirror for this project is now stale.
      # That cleanup is the orphan pass's job (prune_orphan_mirrors), which
      # derives an empty expected set here and removes the stale mirrors.
      printf "MISS  %s specs source missing at %s:%s\n" "$project" "$owner_name" "$source"
      DRIFT_FOUND=1
      continue
    fi

    while IFS= read -r source_file; do
      [ -z "$source_file" ] && continue
      local rel="${source_file#"$source_dir/"}"
      local slug="${rel%.md}"
      local target="$central_root/${mirror%/}/$rel"
      local tmp
      tmp=$(mktemp "$RUN_TMPDIR/spec.XXXXXX")
      write_expected "$tmp" "$source_file" "$owner_repo" "${source%/}/$rel" "$(repo_ref "$owner_root" "${source%/}/$rel")" \
        "$project" "spec" "$slug" "repo-to-central"
      compare_or_materialize "$project spec:$slug -> ${central_repo}:${mirror%/}/$rel" "$tmp" "$target"
      rm -f "$tmp"
    done < <(find "$source_dir" -type f -name '*.md' -print | LC_ALL=C sort)
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

# All internal scratch files live under one run dir cleaned on every exit
# path (including a set -e abort mid-run), so temps never leak — not into
# /tmp and not into a git-tracked target dir.
RUN_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/project-doc-sync.XXXXXX")
trap 'rm -rf "$RUN_TMPDIR"' EXIT

manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"
validate_project_filter "$manifest"
validate_manifest_paths "$manifest"
central_name=$(yq -r '.central_repo.name' "$manifest")
central_repo=$(yq -r '.central_repo.repo' "$manifest")
central_hint=$(yq -r '.central_repo.path_hint // ""' "$manifest")

write_central=0
[ "$MODE" = "materialize" ] && write_central=1
if ! central_root=$(resolve_repo "$central_name" "$central_repo" "$central_hint" "$write_central"); then
  exit 2
fi

process_prds "$manifest" "$central_root" "$central_repo"
process_specs "$manifest" "$central_root" "$central_repo"
prune_orphan_mirrors "$manifest" "$central_root" "$central_repo"

if [ "$ERROR_FOUND" = "1" ]; then
  exit 2
fi
if [ "$DRIFT_FOUND" = "1" ]; then
  exit 1
fi
exit 0
