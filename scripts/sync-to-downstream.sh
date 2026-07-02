#!/usr/bin/env bash
# scripts/sync-to-downstream.sh — propagate Mergepath template changes
# to downstream consumer repos. See #168 for the design.
#
# This script is shipping in layers (per the issue's implementation plan):
#
#   v1 (PR #215):
#     --audit            Read-only drift detector across all consumers.
#
#   v2 (PR #217 — Layer 3 first slice):
#     <commit-ish>       Open propagation PRs for canonical files changed
#                        at the given commit. Kit and templated paths are
#                        skipped with a warning (deferred to slice 2/3).
#
#   v3 (this PR — Layer 3 steady-state reconcile):
#     --sync-all         Propagate the CURRENT HEAD state of EVERY
#                        canonical + kit path in the manifest to every
#                        consumer — ignoring the "changed at commit X"
#                        filter. Use this to bring consumers that are
#                        far behind to a clean steady state in one shot
#                        rather than replaying every historical commit.
#                        Honors .sync-overrides.yml per-consumer (an
#                        intentional divergence is never clobbered),
#                        kit allow-extras semantics, and a distinct
#                        branch-name scheme (mergepath-sync/sync-all-<sha>)
#                        so it doesn't collide with per-commit branches.
#                        Templated paths are rendered per consumer facts
#                        when the substitution lib is present (Layer 5).
#
#   future:
#     --from-pr <N>      Resolve PR N's merge commit and propagate
#                        (Layer 4).
#
# The manifest at .mergepath-sync.yml declares which paths are canonical
# (byte-identical) or kit (directory mirror with allow-extras), and which
# consumers opt in. Templated paths render from a mergepath-side source to a
# consumer-side dest using each consumer's manifest facts.
#
# Usage:
#   scripts/sync-to-downstream.sh --audit [--use-local-tree] [--repos r1,r2] [--paths glob]
#   scripts/sync-to-downstream.sh <commit-ish> [--dry-run] [--repos r1,r2] [--paths glob]
#                                 [--no-pr] [--skip-existing|--recreate-existing] [--verbose]
#   scripts/sync-to-downstream.sh --sync-all [--dry-run] [--repos r1,r2] [--paths glob]
#                                 [--no-pr] [--skip-existing|--recreate-existing] [--verbose]
#   scripts/sync-to-downstream.sh --help
#   scripts/sync-to-downstream.sh --version
#
# Flags:
#   --audit              Read-only drift detection. Exit 0 (clean), 1 (drift),
#                        2 (script/usage error), 3 (consumer fetch error).
#                        Compares each consumer's LIVE default branch (a
#                        refreshed cache clone of origin/HEAD) against
#                        mergepath HEAD, and prints the exact baseline
#                        ref@sha per consumer so the comparison basis is
#                        never ambiguous (#439). To audit a local sibling
#                        working tree instead, see --use-local-tree.
#   --sync-all           Bulk steady-state reconcile. Propagate the current
#                        HEAD state of EVERY canonical + kit path in the
#                        manifest to every consumer, ignoring the
#                        "changed at commit X" filter. One PR per consumer,
#                        branched from the consumer's main. Honors
#                        .sync-overrides.yml per-consumer (a documented
#                        divergence is never overwritten), kit allow-extras
#                        semantics (consumer-only files are kept), and the
#                        manifest's consumer opt-in. Uses a distinct branch
#                        scheme (mergepath-sync/sync-all-<sha>) so it can't
#                        collide with per-commit propagation branches.
#                        Mutually exclusive with --audit and a positional
#                        <commit-ish>. Honors the same sync-mode flags
#                        below (--dry-run, --repos, --paths/--files,
#                        --no-pr, --skip-existing/--recreate-existing,
#                        --verbose). Templated paths are rendered per
#                        consumer facts when opted in.
#   --dry-run            Sync / sync-all mode only. Print the per-consumer
#                        plan (branch name, files) without cloning,
#                        committing, pushing, or creating PRs. For
#                        --sync-all the plan lists every consumer ×
#                        every canonical/kit path, with override-skips
#                        noted. Idempotency check is skipped because it
#                        probes the consumer repo via `gh api`; a dry-run
#                        plan may show "would open PR" even when a PR
#                        already exists, but the live run will catch and
#                        skip it.
#   --repos r1,r2        Restrict to a comma-separated subset of consumer names.
#   --paths glob         Restrict to manifest paths matching the glob (e.g.
#                        "scripts/*", ".github/workflows/agent-review.yml").
#                        `--files <glob>` is accepted as an alias.
#   --files <glob>       Alias for --paths (matches #199 spec; --paths predates).
#   --no-pr              Sync mode only. Push branches but skip the
#                        `gh pr create` step. Useful for staging the
#                        propagation across N consumers; human inspects
#                        the pushed branches before deciding whether to
#                        open PRs (manually or by re-running without
#                        --no-pr).
#   --skip-existing      Sync mode only. Explicit form of the default
#                        behavior: skip any consumer where a PR already
#                        exists for the commit oid. Mutually exclusive
#                        with --recreate-existing.
#   --recreate-existing  Sync mode only. Close the existing PR (with a
#                        pointer comment) and recreate it on the same
#                        branch with a fresh synthesized body. Use when
#                        a manifest change requires the propagation PR
#                        body to be regenerated. Mutually exclusive
#                        with --skip-existing.
#   --verbose, -v        Sync mode dry-run only. Append per-file diff
#                        hunks (Mergepath parent → commit) to each
#                        affected target line in the plan, so the human
#                        sees the change set that would propagate.
#   --use-local-tree     Audit only: compare against a local sibling
#                        worktree under MERGEPATH_SIBLINGS_DIR (the
#                        pre-#439 default), falling back to the cache
#                        clone when no sibling exists. The sibling's
#                        working tree is used AS-IS (never fetched or
#                        reset), so results reflect whatever branch /
#                        commit / uncommitted edits are checked out —
#                        the audit warns loudly when that baseline
#                        differs from origin's default branch. Without
#                        this flag, --audit always compares against a
#                        refreshed cache clone of the consumer's live
#                        default branch (#439: stale siblings made the
#                        default audit confidently report false drift).
#   --no-clone           Audit only: don't clone-on-demand; only audit
#                        consumers that already have a cache clone
#                        under MERGEPATH_SYNC_CACHE (or, with
#                        --use-local-tree, a local sibling worktree
#                        under MERGEPATH_SIBLINGS_DIR).
#   --no-refresh         Audit only: don't `git fetch` cached consumer
#                        clones before comparing. Useful for offline /
#                        sandboxed audits; may report stale results if
#                        the cache is old.
#   --help, -h           Show this help.
#   --version            Print version info.
#
# Canary-first procedure for --sync-all (#264):
#   The original 263caf3 propagation wave (8 consumer PRs at once)
#   failed lint on EVERY consumer because the kit `scripts/ci/`
#   was propagated in isolation from coupled tests/fixtures it
#   depended on. The pre-wave diff audit characterized all drift
#   as staleness but did NOT exercise a consumer's CI to prove
#   the propagated set was internally consistent — a content-level
#   audit cannot catch a runtime-level closure gap.
#
#   The fix is a one-consumer canary BEFORE the full fan-out:
#
#     # 1. Pick one consumer (matchline is the canonical canary).
#     scripts/sync-to-downstream.sh --sync-all --repos matchline
#
#     # 2. Wait for that consumer's `lint` workflow to pass on the
#     #    opened PR. If it fails, fix the manifest gap in mergepath
#     #    canonical first (most often a `requires:` closure miss
#     #    flagged by `scripts/ci/check_sync_manifest`).
#
#     # 3. Once the canary's lint is green, fan out to the rest:
#     scripts/sync-to-downstream.sh --sync-all
#
#   The `requires:` manifest invariant added in #264 catches the
#   most common class of closure gap at the manifest layer, but the
#   canary remains the operational safety net for cases the
#   invariant can't see (consumer-specific repo_lint.yml steps,
#   transitively-required files outside the manifest, etc.).
#
# Environment:
#   MERGEPATH_SIBLINGS_DIR  Default: $HOME/GitHub. Used by the audit ONLY
#                           under --use-local-tree (#439). If a `.git`
#                           entry at
#                           $MERGEPATH_SIBLINGS_DIR/<consumer-name>/.git
#                           exists (directory OR file — git worktrees use
#                           a `.git` file), the audit reads from that
#                           local clone (using the working tree as-is —
#                           drift against your uncommitted edits is
#                           intentional behavior; run `git stash` first
#                           if you want main only). Sibling clones are
#                           never auto-fetched/reset; that's the user's
#                           working tree.
#                           If the local clone is missing, the script
#                           falls back to a cache clone under
#                           MERGEPATH_SYNC_CACHE.
#   MERGEPATH_SYNC_CACHE    Default: $HOME/.cache/mergepath-sync. Cache dir
#                           for clone-on-demand. Per-consumer subdir holds
#                           a depth=1 fetch of the consumer's default
#                           branch. Cached clones are refreshed via
#                           `git fetch && git reset --hard origin/HEAD`
#                           before each audit (suppress with --no-refresh).
#   MERGEPATH_AGENT         Agent name to stamp into live propagation PR
#                           metadata (default: claude).
#   MERGEPATH_SYNC_AUTHORING_AGENT
#                           Explicit override for Authoring-Agent metadata.
#                           Wins over MERGEPATH_AGENT.
#   MERGEPATH_SYNC_COAUTHOR_TRAILER
#                           Explicit `Co-Authored-By: Name <email>` trailer.
#                           Required for agents without a built-in trailer.
#   MERGEPATH_SYNC_ACTOR_OVERRIDE
#                           Override the expected author login for tests.
#   MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1
#                           Tests only: run gh shim directly instead of the
#                           token-verifying author wrapper.
#
# Prerequisites:
#   yq (mikefarah/yq, v4+)  brew install yq
#   git, gh                 standard mergepath agent prerequisites
#
# Exit codes:
#   0   Audit clean OR help/version printed.
#   1   Audit found drift on at least one consumer × path.
#   2   Usage error or missing prerequisite (yq, manifest, etc.).
#   3   Fetch error (could not access a consumer's repo).

set -euo pipefail

# --- constants --------------------------------------------------------------

SCRIPT_VERSION="0.4.0-layer3-sync-all"
SUPPORTED_MANIFEST_VERSION=1
MANIFEST_PATH=".mergepath-sync.yml"
SYNC_BRANCH_PREFIX="mergepath-sync"
OVERRIDES_PATH=".sync-overrides.yml"

# Resolve the Mergepath worktree root from the script's location (works
# regardless of cwd). Two `dirname`s: scripts/sync-to-downstream.sh →
# scripts/ → repo root. Tests can override with MERGEPATH_ROOT_OVERRIDE
# to point the script at a synthetic fixture worktree.
MERGEPATH_ROOT="${MERGEPATH_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Per-repo override library (#200). Provides override_should_skip_path
# and override_substitution_for helpers; sync_open_pr filters its
# target list through override_should_skip_path so a downstream's
# documented divergences are respected on every sync. Sourced once at
# startup so individual sync_open_pr invocations don't reload.
# shellcheck source=scripts/sync/apply-overrides.sh
. "$MERGEPATH_ROOT/scripts/sync/apply-overrides.sh"

# Read-path token helper (#412). Do not require a token at startup:
# audit/dry-run/no-pr callers may be intentionally using ambient gh/git
# auth. When an op-preflight cache or OP_PREFLIGHT_AUTHOR_PAT is already
# available, sync_read_gh below can reuse it for gh read probes so a
# normal live sync does not fail between author-token verification and
# the wrapped author writes.
if [ -r "$MERGEPATH_ROOT/scripts/lib/preflight-helpers.sh" ]; then
  # shellcheck source=scripts/lib/preflight-helpers.sh
  . "$MERGEPATH_ROOT/scripts/lib/preflight-helpers.sh"
  auto_source_preflight || true
fi

# --- logging ----------------------------------------------------------------

log() { echo "[sync-to-downstream] $*" >&2; }
warn() { echo "[sync-to-downstream] WARN: $*" >&2; }
err() { echo "[sync-to-downstream] ERROR: $*" >&2; }

sync_author_identity() {
  local expected
  expected=$(awk '/^author_identity:/ {sub(/^[^:]+:[[:space:]]*/, ""); gsub(/[[:space:]"#].*$/, ""); print; exit}' \
    "$MERGEPATH_ROOT/.github/review-policy.yml" 2>/dev/null || echo "")
  expected=${expected:-nathanjohnpayne}
  expected=${MERGEPATH_SYNC_ACTOR_OVERRIDE:-$expected}
  printf '%s\n' "$expected"
}

sync_author_wrapper() {
  printf '%s/scripts/gh-as-author.sh\n' "$MERGEPATH_ROOT"
}

SYNC_AUTHOR_IDENTITY=""

sync_verify_author_token() {
  if [ "${MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK:-0}" = "1" ]; then
    warn "MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 — skipping author token verification (tests only)"
    return 0
  fi

  local wrapper
  SYNC_AUTHOR_IDENTITY="$(sync_author_identity)"
  wrapper="$(sync_author_wrapper)"
  if [ ! -x "$wrapper" ]; then
    err "refusing to run live sync — author wrapper missing or non-executable: $wrapper"
    err "       Restore scripts/gh-as-author.sh so GitHub writes can verify the author token."
    exit 2
  fi
  if ! GH_AS_AUTHOR_IDENTITY="$SYNC_AUTHOR_IDENTITY" "$wrapper" -- gh api user --jq .login >/dev/null 2>&1; then
    err "refusing to run live sync — could not verify an author token for '$SYNC_AUTHOR_IDENTITY'"
    err "       Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\""
    err "       Then re-run. (Set MERGEPATH_SYNC_ACTOR_OVERRIDE for tests.)"
    exit 2
  fi
}

sync_author_gh() {
  if [ "${MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK:-0}" = "1" ]; then
    gh "$@"
    return $?
  fi

  local wrapper
  if [ -z "$SYNC_AUTHOR_IDENTITY" ]; then
    SYNC_AUTHOR_IDENTITY="$(sync_author_identity)"
  fi
  wrapper="$(sync_author_wrapper)"
  GH_AS_AUTHOR_IDENTITY="$SYNC_AUTHOR_IDENTITY" "$wrapper" -- gh "$@"
}

sync_read_gh() (
  if [ -z "${GH_TOKEN:-}" ] && type preflight_require_token >/dev/null 2>&1; then
    preflight_require_token author >/dev/null 2>&1 || true
  fi
  gh "$@"
)

usage() {
  # Print everything between the first `# Usage:` line and the next blank
  # comment-divider line. Keeps the help text and the script header in
  # lockstep — there's exactly one place to edit when flags change.
  sed -n '
    /^# Usage:/,/^$/{
      /^# */{
        s/^# *//
        p
      }
    }
  ' "${BASH_SOURCE[0]}"
}

# --- live PR metadata -------------------------------------------------------

sync_authoring_agent() {
  local agent="${MERGEPATH_SYNC_AUTHORING_AGENT:-${MERGEPATH_AGENT:-claude}}"
  agent=$(printf '%s' "$agent" | tr '[:upper:]' '[:lower:]')
  if [[ ! "$agent" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    err "invalid sync authoring agent '$agent'"
    err "       Set MERGEPATH_AGENT=<claude|codex|cursor> or MERGEPATH_SYNC_AUTHORING_AGENT=<agent>."
    return 1
  fi
  printf '%s\n' "$agent"
}

sync_coauthor_trailer() {
  local authoring_agent=$1
  if [ -n "${MERGEPATH_SYNC_COAUTHOR_TRAILER:-}" ]; then
    case "$MERGEPATH_SYNC_COAUTHOR_TRAILER" in
      "Co-Authored-By: "*"<"*"@"*">") ;;
      *)
        err "invalid MERGEPATH_SYNC_COAUTHOR_TRAILER; expected 'Co-Authored-By: Name <email>'"
        return 1
        ;;
    esac
    printf '%s\n' "$MERGEPATH_SYNC_COAUTHOR_TRAILER"
    return 0
  fi

  case "$authoring_agent" in
    claude)
      printf '%s\n' "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
      ;;
    codex)
      printf '%s\n' "Co-Authored-By: OpenAI Codex <noreply@openai.com>"
      ;;
    cursor)
      printf '%s\n' "Co-Authored-By: Cursor <noreply@cursor.com>"
      ;;
    *)
      err "no built-in coauthor trailer for Authoring-Agent '$authoring_agent'"
      err "       Set MERGEPATH_SYNC_COAUTHOR_TRAILER='Co-Authored-By: Name <email>' to run with this agent."
      return 1
      ;;
  esac
}

# --- prerequisite check -----------------------------------------------------

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    err "yq is required but not installed."
    err "  brew install yq"
    err "(uses mikefarah/yq v4+. Pure-Python yq from kislyuk/yq is NOT compatible — different syntax.)"
    exit 2
  fi
  # Sanity check: mikefarah/yq prints "yq (https://github.com/mikefarah/yq/) version vX.Y.Z"
  # while kislyuk/yq (pip-installed Python version) prints "yq <semver>" with no URL.
  # Reject the wrong yq early to avoid mysterious parse failures later.
  if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
    err "Detected yq from a non-mikefarah source. Install via 'brew install yq' for the Go binary."
    err "  yq --version: $(yq --version 2>&1)"
    exit 2
  fi
}

require_manifest() {
  local f="$MERGEPATH_ROOT/$MANIFEST_PATH"
  if [ ! -f "$f" ]; then
    err "manifest missing: $MANIFEST_PATH"
    exit 2
  fi
  local v
  v=$(yq '.version' "$f")
  if [ "$v" != "$SUPPORTED_MANIFEST_VERSION" ]; then
    err "manifest version $v not supported by this script (supports: $SUPPORTED_MANIFEST_VERSION)"
    err "Either upgrade scripts/sync-to-downstream.sh or pin the manifest schema."
    exit 2
  fi
}

# --- consumer worktree resolution -------------------------------------------

# Echo the path on disk where we should read the consumer's working tree.
# Returns 0 if found, 1 if not. The caller distinguishes cache vs.
# sibling by comparing the returned path's prefix against
# MERGEPATH_SYNC_CACHE — see the helper `path_is_in_cache` below.
# (An earlier draft used a $RESOLVED_FROM global, but the function is
# called via command substitution which runs in a subshell, swallowing
# the assignment. Encoding the answer in the path is subshell-safe.)
#
# Accepts both `.git` directory (regular clone) and `.git` file (git
# worktree). Codex P2 on PR #215 caught the worktree case — the original
# `-d` test misclassified worktrees as missing.
resolve_consumer_worktree() {
  local consumer_name=$1
  local siblings_dir=${MERGEPATH_SIBLINGS_DIR:-$HOME/GitHub}
  local cache_dir=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}

  if [ -e "$siblings_dir/$consumer_name/.git" ]; then
    echo "$siblings_dir/$consumer_name"
    return 0
  fi
  if [ -e "$cache_dir/$consumer_name/.git" ]; then
    echo "$cache_dir/$consumer_name"
    return 0
  fi
  return 1
}

# Cache-only resolver for the default audit baseline (#439): never
# considers sibling worktrees. Returns 0 with the path on stdout if a
# cache clone exists, 1 otherwise (caller clones on demand).
resolve_consumer_cache_clone() {
  local consumer_name=$1
  local cache_dir=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}

  if [ -e "$cache_dir/$consumer_name/.git" ]; then
    echo "$cache_dir/$consumer_name"
    return 0
  fi
  return 1
}

# Print the audit comparison baseline for one consumer (#439 Option 3):
# the exact ref@sha being compared, and which kind of tree it is. For a
# local sibling tree (only reachable under --use-local-tree), also warn
# loudly when the tree is on a non-default branch or its HEAD differs
# from the last-known origin default-branch tip — the two stale-baseline
# shapes that produced confidently-false fleet-wide drift reports.
# Non-git fixture trees (tests) print "unknown" and skip the warnings.
print_audit_baseline() {
  local consumer_root=$1
  local sha branch
  sha=$(git -C "$consumer_root" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  branch=$(git -C "$consumer_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  if path_is_in_cache "$consumer_root"; then
    # The refresh resets the working tree to origin/HEAD but never
    # renames the local branch, so after a remote default-branch
    # rename the local branch label would lie about what the content
    # tracks. Label the baseline with origin/HEAD's actual target.
    local origin_default
    origin_default=$(git -C "$consumer_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
    if [ -n "$origin_default" ]; then
      branch="${origin_default#origin/}"
    fi
    if [ "${AUDIT_NO_REFRESH:-0}" = "1" ]; then
      echo "  baseline: $branch@$sha (cache clone, NOT refreshed — --no-refresh; may lag origin)"
    else
      echo "  baseline: $branch@$sha (cache clone, refreshed from origin default branch)"
    fi
    return 0
  fi

  echo "  baseline: $branch@$sha (LOCAL SIBLING TREE at $consumer_root, used as-is — never auto-fetched)"

  # Staleness warnings (best-effort; both probes read only local refs).
  local default_branch origin_sha
  default_branch=$(git -C "$consumer_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  default_branch=${default_branch#origin/}
  if [ -n "$default_branch" ] && [ "$branch" != "unknown" ] && [ "$branch" != "$default_branch" ]; then
    echo "  ⚠ sibling tree is on '$branch', not the default branch '$default_branch' — drift results reflect that branch, not origin/$default_branch; re-run without --use-local-tree for live state"
  fi
  origin_sha=$(git -C "$consumer_root" rev-parse --short "refs/remotes/origin/${default_branch:-HEAD}" 2>/dev/null || echo "")
  if [ -n "$origin_sha" ] && [ "$sha" != "unknown" ] && [ "$sha" != "$origin_sha" ]; then
    echo "  ⚠ sibling tree HEAD ($sha) != last-fetched origin/${default_branch:-HEAD} ($origin_sha) — baseline may be stale or ahead; re-run without --use-local-tree for live state"
  fi
}

# Lexical prefix check: does $1 live under MERGEPATH_SYNC_CACHE?
# Trailing slash on the cache root makes the prefix unambiguous so a
# sibling dir whose name happens to match the cache-dir prefix can't
# false-match.
path_is_in_cache() {
  local p=$1
  local cache_root=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}
  [[ "$p" == "$cache_root"/* ]]
}

# Bring a cached clone up to date with the consumer's default branch.
# Skipped silently if the path was resolved from a sibling worktree —
# refreshing a user's working tree would clobber uncommitted edits.
# Codex P1 on PR #215 caught the stale-cache hazard.
#
# Symlink guard (cursor CHANGES_REQUESTED on PR #215): a user who
# symlinks $MERGEPATH_SYNC_CACHE/<consumer> at their sibling clone
# (or vice versa) would otherwise have their working tree reset by
# the `git reset --hard` below. Resolve the physical path of the
# cache entry and the cache root, then refuse to refresh if the
# entry escapes the cache root. This catches both direct symlinks
# (cache_path itself is a symlink) and indirect symlinks
# (any ancestor in the path is symlinked elsewhere).
refresh_cached_clone() {
  local cache_path=$1
  local cache_root=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}

  # Direct-symlink guard: if the cache entry itself is a symlink, the
  # `git reset --hard` below would clobber whatever it points at. Refuse.
  if [ -L "$cache_path" ]; then
    err "refusing to refresh $cache_path — it is a symbolic link."
    err "       \`git reset --hard\` would clobber the symlink target,"
    err "       which is likely a sibling/user clone. Remove the symlink"
    err "       (the script will re-clone into the cache) or run with"
    err "       --no-refresh."
    return 3
  fi

  # Ancestor-symlink guard: if `cd && pwd -P` resolves to a path
  # outside the cache root, an ancestor in the path is symlinked
  # elsewhere. `pwd -P` is POSIX and resolves all symlinks; macOS
  # `realpath` lacks `-P` so we don't use it. cursor's
  # CHANGES_REQUESTED on PR #215 found this attack surface.
  local phys_path phys_root
  phys_path=$(cd "$cache_path" 2>/dev/null && pwd -P) || phys_path=""
  phys_root=$(cd "$cache_root" 2>/dev/null && pwd -P) || phys_root="$cache_root"

  if [ -z "$phys_path" ] || [[ "$phys_path" != "$phys_root"/* && "$phys_path" != "$phys_root" ]]; then
    err "refusing to refresh $cache_path — physical path ($phys_path)"
    err "       resolves outside MERGEPATH_SYNC_CACHE ($phys_root)."
    err "       Some ancestor of the cache entry is symlinked elsewhere."
    err "       Run with --no-refresh, or rebuild MERGEPATH_SYNC_CACHE"
    err "       without symlinks."
    return 3
  fi

  log "refreshing cached clone at $cache_path"
  # A bare `git fetch` is not enough here, for two compounding reasons
  # (Codex P2s on PR #443 rounds 1–2):
  #   - `git fetch` never updates refs/remotes/origin/HEAD when the
  #     remote's default branch changes (e.g. a main→trunk rename), so
  #     a long-lived cache clone would keep resetting to the STALE old
  #     default while the baseline header claims a refreshed
  #     default-branch comparison.
  #   - cache clones are created with --depth=1, which implies
  #     --single-branch: the clone's refspec only ever fetches the
  #     OLD default, so the renamed default's ref would never arrive.
  # Resolve the remote's CURRENT default via ls-remote --symref, fetch
  # that branch explicitly, re-point origin/HEAD at it, then reset.
  local default_ref
  default_ref=$(git -C "$cache_path" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
  if [ -z "$default_ref" ]; then
    err "could not resolve the remote default branch for $cache_path (git ls-remote --symref origin HEAD)"
    return 3
  fi
  if ! git -C "$cache_path" fetch --depth=1 --quiet origin \
       "+refs/heads/$default_ref:refs/remotes/origin/$default_ref" >&2; then
    err "git fetch failed for cached clone $cache_path (branch $default_ref)"
    return 3
  fi
  if ! git -C "$cache_path" remote set-head origin "$default_ref" >/dev/null 2>&1; then
    err "git remote set-head origin $default_ref failed for $cache_path"
    return 3
  fi
  if ! git -C "$cache_path" reset --hard --quiet "refs/remotes/origin/$default_ref" >&2; then
    err "git reset --hard origin/$default_ref failed for $cache_path"
    return 3
  fi
}

# Clone-on-demand into the cache. Depth=1 is fine for audit; we only
# need HEAD content. Returns the resolved path on stdout.
clone_consumer_to_cache() {
  local consumer_name=$1
  local consumer_repo=$2
  local cache_dir=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}
  local target="$cache_dir/$consumer_name"

  mkdir -p "$cache_dir"
  log "cloning $consumer_repo into $target (depth=1)"
  if ! gh repo clone "$consumer_repo" "$target" -- --depth=1 --quiet >&2; then
    err "could not clone $consumer_repo — check gh auth and repo permissions"
    return 3
  fi
  echo "$target"
}

# --- path-type-aware comparison --------------------------------------------

# Compare a single canonical (byte-for-byte) file. Outputs a status line
# tag in $REPLY: "ok" / "drift:<lines>" / "missing".
compare_canonical() {
  local mp_path=$1
  local consumer_root=$2
  local consumer_path="$consumer_root/$mp_path"
  local mp_full="$MERGEPATH_ROOT/$mp_path"

  if [ ! -e "$consumer_path" ]; then
    REPLY="missing"
    return 0
  fi
  if cmp -s "$mp_full" "$consumer_path"; then
    REPLY="ok"
    return 0
  fi
  # `diff` exits 1 when files differ — combined with `set -o pipefail` that
  # would kill the script. Mask the exit code so the pipeline succeeds.
  local lines
  lines=$( { diff "$mp_full" "$consumer_path" || true; } | wc -l | tr -d ' ')
  REPLY="drift:$lines"
}

# Compare a single templated entry: render mergepath@HEAD's source
# template using the consumer's facts (via scripts/lib/template-
# substitution.sh) and byte-compare against the consumer's on-disk
# destination. Outputs the same status tag scheme as compare_canonical:
#   "ok" / "drift:<lines>" / "missing"
#
# Args: mp_path (manifest identifier), source_path (where the source
# template lives in mergepath — defaults to mp_path upstream when
# omitted), dest_path (where the rendered output lives in the
# consumer), consumer_name (for facts lookup), consumer_root.
#
# Why a function-scoped subshell for the render: export_consumer_facts
# mutates MERGEPATH_FACT_* env vars; running the render inside a
# subshell scopes those exports so a subsequent consumer iteration
# doesn't see stale facts from this one. The subshell's stdout is
# captured to the tmp file via the `(...) > "$tmp"` redirection.
compare_templated() {
  local mp_path=$1
  local source_path=$2
  local dest_path=$3
  local consumer_name=$4
  local consumer_root=$5

  local mp_source="$MERGEPATH_ROOT/$source_path"
  local consumer_dest="$consumer_root/$dest_path"

  if [ ! -e "$mp_source" ]; then
    err "compare_templated: source $source_path not found in mergepath"
    REPLY="drift:0"
    return 0
  fi
  if [ ! -e "$consumer_dest" ]; then
    REPLY="missing"
    return 0
  fi

  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"
  local tmp_rendered
  tmp_rendered=$(mktemp "${TMPDIR:-/tmp}/compare-templated.XXXXXX") || {
    err "compare_templated: mktemp failed"
    REPLY="drift:0"
    return 0
  }
  local render_rc=0
  (
    export_consumer_facts "$consumer_name" "$manifest"
    # shellcheck disable=SC1091
    source "$MERGEPATH_ROOT/scripts/lib/template-substitution.sh"
    template_substitution::render "$mp_source"
  ) > "$tmp_rendered" 2>/dev/null || render_rc=$?
  if [ "$render_rc" != "0" ]; then
    rm -f "$tmp_rendered"
    err "compare_templated: render failed (rc=$render_rc) for $source_path with $consumer_name's facts"
    REPLY="drift:0"
    return 0
  fi

  if cmp -s "$tmp_rendered" "$consumer_dest"; then
    REPLY="ok"
  else
    local lines
    lines=$( { diff "$tmp_rendered" "$consumer_dest" || true; } | wc -l | tr -d ' ')
    REPLY="drift:$lines"
  fi
  rm -f "$tmp_rendered"
}

# Materialize templated targets into a consumer workspace. For each
# path in $templated_list (comma-joined manifest .path values),
# fetch source/dest from the manifest, read the source from
# mergepath@$sha, render via the substitution lib with the
# consumer's facts, and write to the consumer's dest (atomically
# via template_substitution::render_to). Honors the consumer's
# .sync-overrides.yml skip_paths on the DEST path — the consumer
# cares about the path landing in their tree, not the mergepath-
# side source path.
#
# Args:
#   $1 consumer_name        — for fact lookup + log lines
#   $2 sha                  — mergepath commit to read source from
#   $3 workspace            — consumer workspace root (writes land
#                             at $workspace/repo/<dest>)
#   $4 templated_list       — comma-joined manifest .path values
#                             (caller-supplied, typically from
#                             sync_consumer_skipped_targets in the
#                             per-commit path or
#                             sync_all_consumer_templated_targets in
#                             the sync-all path)
#   $5 consumer_overrides   — absolute path to the consumer's
#                             .sync-overrides.yml (or empty string
#                             if the consumer has no overrides file)
#
# Returns 0 on success (no targets is a clean no-op), non-zero if
# any render failed. Materializes files into the workspace;
# committing/pushing is the caller's concern.
materialize_templated_targets() {
  local consumer_name=$1
  local sha=$2
  local workspace=$3
  local templated_list=$4
  local consumer_overrides=$5

  [ -z "$templated_list" ] && return 0

  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"
  local short_sha=${sha:0:7}
  local tpl_path tpl_source tpl_dest tpl_meta tpl_tmp tpl_consumer_target
  local _tpl_paths
  IFS=',' read -ra _tpl_paths <<< "$templated_list"
  for tpl_path in "${_tpl_paths[@]}"; do
    [ -z "$tpl_path" ] && continue

    # Per-entry source + dest from the manifest. Default to .path when
    # omitted (canonical/kit's symmetric model); templated entries
    # typically declare both explicitly.
    tpl_meta=$(MERGEPATH_TPL_PATH="$tpl_path" yq -r '
      env(MERGEPATH_TPL_PATH) as $p
      | .paths[] | select(.path == $p) | (.source // .path) + "\t" + (.dest // .path)
    ' "$manifest")
    tpl_source=$(echo "$tpl_meta" | cut -f1)
    tpl_dest=$(echo "$tpl_meta" | cut -f2)
    if [ -z "$tpl_source" ] || [ -z "$tpl_dest" ]; then
      err "$consumer_name: could not resolve source/dest for templated entry '$tpl_path' (yq returned empty)"
      return 1
    fi

    # Consumer-side override filter — applied to DEST because that's
    # what lands in the consumer tree.
    if [ -n "$consumer_overrides" ] && override_should_skip_path "$consumer_overrides" "$tpl_dest"; then
      printf "  · %s skip %s (templated, per .sync-overrides.yml: %s)\n" \
        "$consumer_name" "$tpl_dest" "$OVERRIDE_SKIP_REASON"
      continue
    fi

    # Read source from mergepath@$sha into a tmp file, then render
    # via the lib in a subshell so the MERGEPATH_FACT_* exports
    # don't leak to other materializations in the same consumer
    # (multiple templated entries) or the next consumer iteration.
    tpl_tmp=$(mktemp "${TMPDIR:-/tmp}/mergepath-template-src.XXXXXX") || {
      err "$consumer_name: mktemp failed for templated source"
      return 1
    }
    if ! git -C "$MERGEPATH_ROOT" show "$sha:$tpl_source" >"$tpl_tmp" 2>/dev/null; then
      rm -f "$tpl_tmp"
      err "$consumer_name: could not read templated source $tpl_source from mergepath@$short_sha"
      return 1
    fi

    tpl_consumer_target="$workspace/repo/$tpl_dest"
    mkdir -p "$(dirname "$tpl_consumer_target")"
    if ! (
      export_consumer_facts "$consumer_name" "$manifest"
      # shellcheck disable=SC1091
      source "$MERGEPATH_ROOT/scripts/lib/template-substitution.sh"
      template_substitution::render_to "$tpl_tmp" "$tpl_consumer_target"
    ); then
      rm -f "$tpl_tmp"
      err "$consumer_name: render failed for templated $tpl_source → $tpl_dest"
      return 1
    fi
    rm -f "$tpl_tmp"
    # Mirror the source template's executable bit onto the rendered dest
    # (#471): a templated source can be executable, and render_to writes via
    # shell redirection (mode 644), so without this an executable templated
    # script would land non-executable in the consumer. Same shape as the
    # canonical mirror arm.
    tpl_src_mode=$(git -C "$MERGEPATH_ROOT" ls-tree "$sha" -- "$tpl_source" | awk '{print $1}')
    case "$tpl_src_mode" in
      100755) chmod +x "$tpl_consumer_target" ;;
      100644) chmod -x "$tpl_consumer_target" ;;
      *)
        err "$consumer_name: unexpected git mode '$tpl_src_mode' for templated source $tpl_source at mergepath@$short_sha"
        return 1
        ;;
    esac
    # Record the mode in the git INDEX, not just the working tree: under
    # core.filemode=false (some consumer clones / mode-insensitive
    # filesystems) the caller's blanket `git add -A` ignores the on-disk
    # exec bit, so a mode-only flip on an existing rendered dest would
    # silently not be staged and the propagation PR would carry the wrong
    # mode (Codex P2 on PR #475). Stage the dest and set its index mode
    # now; a subsequent `git add -A` preserves an already-staged index
    # mode (verified under core.filemode=false). Mirrors the same lesson
    # tests/test_verify_propagation_pr_templated.sh applies to its fixture.
    if [ "$tpl_src_mode" = "100755" ]; then tpl_idx_chmod="+x"; else tpl_idx_chmod="-x"; fi
    if ! git -C "$workspace/repo" add -- "$tpl_dest" \
       || ! git -C "$workspace/repo" update-index --chmod="$tpl_idx_chmod" -- "$tpl_dest"; then
      err "$consumer_name: failed to stage templated dest mode ($tpl_idx_chmod) for $tpl_dest"
      return 1
    fi
    printf "  ✎ %s rendered %s → %s\n" "$consumer_name" "$tpl_source" "$tpl_dest"
  done
}

# export_consumer_facts lives in scripts/lib/manifest-fact-helpers.sh
# so both this script AND scripts/workflow/verify-propagation-pr.sh
# can load consumer facts from a manifest without duplicating the yq
# filter. The lib has no top-level side effects (function defs only),
# so sourcing it is cheap and safe.
#
# Regression-guarded by tests/test_export_consumer_facts.sh, which
# greps the documented mikefarah-idiom yq filter directly out of
# the lib file (the test was updated alongside #323).
# shellcheck disable=SC1091
source "$MERGEPATH_ROOT/scripts/lib/manifest-fact-helpers.sh"

# Compare a kit directory: every file under Mergepath's path must
# exist (byte-identical) in the consumer; consumer-only files are
# allowed and ignored. Outputs a status tag in $REPLY:
#   "ok"
#   "missing"           — consumer dir doesn't exist at all
#   "drift:N+M"         — N drifted files, M missing files
compare_kit() {
  local mp_path=$1
  local consumer_root=$2
  local mp_full="$MERGEPATH_ROOT/$mp_path"
  local consumer_full="$consumer_root/$mp_path"

  # Strip trailing slash for find consistency.
  mp_full="${mp_full%/}"
  consumer_full="${consumer_full%/}"

  if [ ! -d "$consumer_full" ]; then
    REPLY="missing"
    return 0
  fi

  local drift_count=0
  local missing_count=0
  # Walk every file under the Mergepath kit. Ignore symlinks and
  # special files — kits are plain script directories.
  while IFS= read -r -d '' f; do
    # Quote inside the expansion so shell glob metacharacters in the
    # path (improbable in this repo, but cheap to be correct) are
    # treated as literals. CodeRabbit nitpick on PR #215.
    local rel="${f#"$mp_full/"}"
    local target="$consumer_full/$rel"
    if [ ! -e "$target" ]; then
      missing_count=$((missing_count + 1))
    elif ! cmp -s "$f" "$target"; then
      drift_count=$((drift_count + 1))
    fi
  done < <(find "$mp_full" -type f -print0)

  if [ "$drift_count" -eq 0 ] && [ "$missing_count" -eq 0 ]; then
    REPLY="ok"
  else
    REPLY="drift:${drift_count}+${missing_count}"
  fi
}

# --- audit driver -----------------------------------------------------------

# Pretty-print one line for a consumer × path result.
emit_status_line() {
  local mp_path=$1
  local status=$2

  local sym detail
  case "$status" in
    ok)
      sym="✓"; detail="in sync"
      ;;
    missing)
      sym="⊘"; detail="missing entirely"
      ;;
    drift:*)
      sym="✗"
      local payload="${status#drift:}"
      if [[ "$payload" == *"+"* ]]; then
        local d="${payload%+*}"
        local m="${payload#*+}"
        detail="drift: $d file(s) drifted, $m file(s) missing"
      else
        detail="drift: $payload diff line(s)"
      fi
      ;;
    *)
      sym="?"; detail="unknown status: $status"
      ;;
  esac
  printf "  %s %-50s %s\n" "$sym" "$mp_path" "$detail"
}

emit_skip_line() {
  local mp_path=$1
  local reason=$2
  printf "  ↷ %-50s skipped per .sync-overrides.yml: %s\n" "$mp_path" "$reason"
}

# Filter helpers — return 0 (truthy) if the entry passes the filter,
# 1 otherwise. FILTER_REPOS / FILTER_PATHS are global vars set from CLI.
in_repo_filter() {
  local name=$1
  [ -z "${FILTER_REPOS:-}" ] && return 0
  local re=",$FILTER_REPOS,"
  [[ "$re" == *",$name,"* ]]
}

in_path_filter() {
  local p=$1
  [ -z "${FILTER_PATHS:-}" ] && return 0
  # shellcheck disable=SC2053
  [[ "$p" == ${FILTER_PATHS} ]]
}

# Run the audit. Sets $AUDIT_DRIFT_FOUND=1 if any non-OK status seen.
# Sets $AUDIT_FETCH_ERROR=1 if a consumer was unreachable.
run_audit() {
  AUDIT_DRIFT_FOUND=0
  AUDIT_FETCH_ERROR=0
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  # Pull the consumer list as TSV: name<TAB>repo
  local consumers
  consumers=$(yq -r '.consumers[] | (.name + "\t" + .repo)' "$manifest")

  while IFS=$'\t' read -r consumer_name consumer_repo; do
    [ -z "$consumer_name" ] && continue
    if ! in_repo_filter "$consumer_name"; then
      continue
    fi

    echo "$consumer_name ($consumer_repo)"

    local consumer_root
    if [ "${AUDIT_USE_LOCAL_TREE:-0}" = "1" ]; then
      # Legacy baseline (#439 opt-in): sibling worktree first, cache
      # fallback. The sibling tree is used AS-IS; the baseline header
      # + staleness warnings below make that basis explicit.
      if ! consumer_root=$(resolve_consumer_worktree "$consumer_name"); then
        if [ "${AUDIT_NO_CLONE:-0}" = "1" ]; then
          echo "  ! no local worktree for $consumer_name (set MERGEPATH_SIBLINGS_DIR or drop --no-clone)"
          AUDIT_FETCH_ERROR=1
          continue
        fi
        if ! consumer_root=$(clone_consumer_to_cache "$consumer_name" "$consumer_repo"); then
          echo "  ! could not fetch $consumer_repo"
          AUDIT_FETCH_ERROR=1
          continue
        fi
      fi
    else
      # Default baseline (#439): the consumer's LIVE default branch via
      # a refreshed cache clone — never the user's sibling working
      # tree. A stale sibling (feature branch checked out, behind
      # main) previously made the audit confidently report massive
      # false drift with no hint the baseline was stale.
      if ! consumer_root=$(resolve_consumer_cache_clone "$consumer_name"); then
        if [ "${AUDIT_NO_CLONE:-0}" = "1" ]; then
          echo "  ! no cached clone for $consumer_name (drop --no-clone, or pass --use-local-tree to audit a local sibling worktree)"
          AUDIT_FETCH_ERROR=1
          continue
        fi
        if ! consumer_root=$(clone_consumer_to_cache "$consumer_name" "$consumer_repo"); then
          echo "  ! could not fetch $consumer_repo"
          AUDIT_FETCH_ERROR=1
          continue
        fi
      fi
    fi
    # If we're reading from a cache path (vs. a sibling worktree),
    # pull the latest default branch before comparing. Skip for
    # sibling worktrees; that's the user's working tree and must not
    # be auto-reset. Honors --no-refresh for offline / sandboxed runs.
    if path_is_in_cache "$consumer_root" && [ "${AUDIT_NO_REFRESH:-0}" != "1" ]; then
      if ! refresh_cached_clone "$consumer_root"; then
        echo "  ! could not refresh cached clone for $consumer_name"
        AUDIT_FETCH_ERROR=1
        continue
      fi
    fi
    print_audit_baseline "$consumer_root"
    local consumer_overrides=""
    if [ -f "$consumer_root/$OVERRIDES_PATH" ]; then
      consumer_overrides="$consumer_root/$OVERRIDES_PATH"
    fi

    # Walk the manifest's paths. yq emits TSV: path<TAB>type<TAB>consumers_csv
    # where consumers_csv is "all" or a comma-joined list. Per-path
    # exclusions land in Layer 3; for v1 the exclusions block is
    # treated as advisory (still fully audited) so no consumer × path
    # is silently skipped.
    #
    # mikefarah/yq doesn't support jq-style `if/then/else` expressions —
    # we get the same effect via `select(tag == "!!str") // <fallback>`,
    # which yields the original scalar when consumers is a string and
    # the join'd list otherwise.
    # Extended yq tuple: include source + dest so templated entries can
    # be audited with source-template / dest-rendered remapping. For
    # canonical/kit, source and dest default to .path; the audit code
    # below ignores those fields for those types.
    local paths
    paths=$(yq -r '
      .paths[]
      | (.path + "\t" + .type + "\t"
         + (.consumers | (select(tag == "!!str") // (join(","))) | tostring)
         + "\t" + (.source // .path)
         + "\t" + (.dest // .path))
    ' "$manifest")

    while IFS=$'\t' read -r mp_path mp_type mp_consumers mp_source mp_dest; do
      [ -z "$mp_path" ] && continue
      if ! in_path_filter "$mp_path"; then
        continue
      fi
      # Consumer opt-in check
      if [ "$mp_consumers" != "all" ]; then
        local re=",$mp_consumers,"
        if [[ "$re" != *",$consumer_name,"* ]]; then
          continue
        fi
      fi

      local consumer_path_for_override="$mp_path"
      if [ "$mp_type" = "templated" ]; then
        consumer_path_for_override="$mp_dest"
      fi
      if override_should_skip_path "$consumer_overrides" "$consumer_path_for_override"; then
        emit_skip_line "$consumer_path_for_override" "$OVERRIDE_SKIP_REASON"
        continue
      fi

      case "$mp_type" in
        canonical)
          compare_canonical "$mp_path" "$consumer_root"
          emit_status_line "$mp_path" "$REPLY"
          [ "$REPLY" != "ok" ] && AUDIT_DRIFT_FOUND=1
          ;;
        kit)
          compare_kit "$mp_path" "$consumer_root"
          emit_status_line "$mp_path" "$REPLY"
          [ "$REPLY" != "ok" ] && AUDIT_DRIFT_FOUND=1
          ;;
        templated)
          # Layer 5 activated (#313 lib + this PR). Render the source
          # template with the consumer's facts and byte-diff against
          # the on-disk destination.
          compare_templated "$mp_path" "$mp_source" "$mp_dest" \
                            "$consumer_name" "$consumer_root"
          emit_status_line "$mp_dest" "$REPLY"
          [ "$REPLY" != "ok" ] && AUDIT_DRIFT_FOUND=1
          ;;
        *)
          err "unknown path type '$mp_type' for $mp_path"
          AUDIT_DRIFT_FOUND=1
          ;;
      esac
    done <<< "$paths"
    echo
  done <<< "$consumers"
}

# --- sync mode --------------------------------------------------------------

# Resolve a Mergepath commit-ish to a full SHA. Errors out if the commit
# isn't reachable. Output: full SHA on stdout.
sync_resolve_commit() {
  local commit_ish=$1
  local sha
  sha=$(git -C "$MERGEPATH_ROOT" rev-parse --verify "$commit_ish^{commit}" 2>/dev/null) || {
    err "could not resolve commit-ish '$commit_ish' in Mergepath worktree"
    return 2
  }
  echo "$sha"
}

# List files that changed at the given commit. Output: one path per line,
# relative to the Mergepath repo root.
sync_changed_files() {
  local sha=$1
  git -C "$MERGEPATH_ROOT" show --name-only --pretty=format: "$sha" \
    | grep -v '^$' || true
}

# Intersect changed files with manifest canonical paths for one consumer.
# Echoes one canonical path per line that (a) exists in the changed-set
# AND (b) the consumer opts in to.
#
# Kit and templated paths are intentionally skipped in this slice. The
# audit mode already reports drift for those; sync mode for them lands in
# slice 2 (kit) and slice 5 (templated). Skipping here is silent per
# manifest path; the per-consumer summary calls out the deferral.
sync_consumer_canonical_targets() {
  local consumer_name=$1
  local changed_files=$2  # newline-separated
  local manifest=$3

  yq -r '
    .paths[]
    | select(.type == "canonical")
    | (.path + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest" | while IFS=$'\t' read -r mp_path mp_consumers; do
    # Path filter
    if ! in_path_filter "$mp_path"; then continue; fi
    # Consumer opt-in
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    # Changed at the commit?
    if grep -Fxq "$mp_path" <<< "$changed_files"; then
      echo "$mp_path"
    fi
  done
}

# --- sync-all target enumeration -------------------------------------------
#
# These two helpers back --sync-all. They differ from
# sync_consumer_canonical_targets / sync_consumer_skipped_targets above
# in one way only: there is NO "changed at commit" intersection. Every
# manifest path of the given type that the consumer opts in to (and
# passes the --paths filter) is a target. The .sync-overrides.yml
# per-consumer filter is applied later, in sync_open_pr, exactly as in
# the per-commit path — so an intentional divergence is honored
# identically whether the sync was triggered by a commit or by
# --sync-all.

# Echo every canonical manifest path the consumer opts in to (one per
# line), after the --paths filter. No changed-files intersection.
sync_all_consumer_canonical_targets() {
  local consumer_name=$1
  local manifest=$2

  yq -r '
    .paths[]
    | select(.type == "canonical")
    | (.path + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest" | while IFS=$'\t' read -r mp_path mp_consumers; do
    if ! in_path_filter "$mp_path"; then continue; fi
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    echo "$mp_path"
  done
}

# Echo every kit manifest path the consumer opts in to (one per line),
# after the --paths filter. No changed-files intersection.
sync_all_consumer_kit_targets() {
  local consumer_name=$1
  local manifest=$2

  yq -r '
    .paths[]
    | select(.type == "kit")
    | (.path + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest" | while IFS=$'\t' read -r mp_path mp_consumers; do
    if ! in_path_filter "$mp_path"; then continue; fi
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    echo "$mp_path"
  done
}

# Echo every templated manifest path the consumer opts in to (one per
# line), after the --paths filter. --sync-all defers templated paths
# (Layer 5) but names them in the plan / PR body so the human sees
# they were intentionally not synced.
sync_all_consumer_templated_targets() {
  local consumer_name=$1
  local manifest=$2

  yq -r '
    .paths[]
    | select(.type == "templated")
    | (.path + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest" | while IFS=$'\t' read -r mp_path mp_consumers; do
    if ! in_path_filter "$mp_path"; then continue; fi
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    echo "$mp_path"
  done
}

# Enumerate manifest paths the per-commit sync needs to know about
# beyond the canonical slice: kit paths that changed at the commit
# (still deferred to slice 2, included in the commit-body
# deferred-note) AND templated paths that changed (now materialized
# in slice 5 / #313+follow-up — the function name predates the
# templated activation, kept for back-compat).
#
# Echoes "kit_count\ttemplated_count\tkit_paths\ttemplated_paths".
# Caller splits the templated CSV and passes it through to
# materialize_templated_targets via sync_open_pr's 8th positional
# arg; the kit CSV is still display-only in the deferred-note.
sync_consumer_skipped_targets() {
  local consumer_name=$1
  local changed_files=$2
  local manifest=$3

  local kit_paths=()
  local templated_paths=()
  while IFS=$'\t' read -r mp_path mp_type mp_consumers; do
    [ -z "$mp_path" ] && continue
    if ! in_path_filter "$mp_path"; then continue; fi
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    # Did the change touch this path / its directory?
    case "$mp_type" in
      kit)
        local mp_dir="${mp_path%/}"
        if grep -E "^${mp_dir}/" <<< "$changed_files" >/dev/null; then
          kit_paths+=("$mp_path")
        fi
        ;;
      templated)
        if grep -Fxq "$mp_path" <<< "$changed_files"; then
          templated_paths+=("$mp_path")
        fi
        ;;
    esac
  done < <(yq -r '
    .paths[]
    | (.path + "\t" + .type + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest")

  local kp tp
  kp=$(IFS=,; echo "${kit_paths[*]:-}")
  tp=$(IFS=,; echo "${templated_paths[*]:-}")
  echo -e "${#kit_paths[@]}\t${#templated_paths[@]}\t${kp}\t${tp}"
}

# Compute the deterministic branch name. Same commit-ish always produces
# the same branch — that's how we get idempotency on re-runs.
sync_branch_name() {
  local sha=$1
  echo "${SYNC_BRANCH_PREFIX}/${sha:0:7}"
}

# Branch name for --sync-all runs. Keyed to mergepath HEAD at run time,
# with a distinct `sync-all-` infix so a bulk reconcile branch can never
# collide with a per-commit propagation branch (mergepath-sync/<sha>) —
# even in the degenerate case where the per-commit sha and the sync-all
# HEAD sha share a 7-char prefix. The distinct scheme also makes the
# idempotency probe (sync_check_existing_pr) meaningful: a prior
# --sync-all PR is found, a prior per-commit PR is not mistaken for one.
sync_all_branch_name() {
  local sha=$1
  echo "${SYNC_BRANCH_PREFIX}/sync-all-${sha:0:7}"
}

# Idempotency check: does a PR already exist on this consumer's repo from
# the deterministic sync branch? Echoes one of:
#   "open:<pr_number>"     PR is open — skip, "already in flight"
#   "closed:<pr_number>"   PR exists but closed (merged or abandoned)
#   "none"                 No prior PR; safe to open
# On API error, echoes "error" and returns non-zero.
sync_check_existing_pr() {
  local consumer_repo=$1
  local branch=$2
  local prs
  prs=$(sync_read_gh api "repos/$consumer_repo/pulls?state=all&head=$(echo "$consumer_repo" | cut -d/ -f1):$branch" \
    --jq '.[] | "\(.state)\t\(.number)"' 2>/dev/null) || {
    echo "error"
    return 1
  }
  if [ -z "$prs" ]; then
    echo "none"
    return 0
  fi
  # Take the most recent (last) — gh api returns newest first by default.
  local first
  first=$(echo "$prs" | head -1)
  local state num
  state=$(echo "$first" | cut -f1)
  num=$(echo "$first" | cut -f2)
  if [ "$state" = "open" ]; then
    echo "open:$num"
  else
    echo "closed:$num"
  fi
}

# Per-consumer sync. Echoes a summary line on stdout. Sets
# SYNC_PR_OPENED, SYNC_SKIPPED, SYNC_FAILED counters in the parent.
sync_one_consumer() {
  local consumer_name=$1
  local consumer_repo=$2
  local sha=$3
  local short_sha=${sha:0:7}
  local commit_subject=$4
  local changed_files=$5
  local dry_run=${6:-0}
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  local branch
  branch=$(sync_branch_name "$sha")

  # Deferred destructive recreate: populated below when
  # SYNC_RECREATE_EXISTING=1 + an existing open PR is detected.
  # Passed to sync_open_pr so the close+delete fires AFTER the
  # replacement commit is built and BEFORE the push. Stays empty
  # in the no-recreate case so sync_open_pr knows to skip the
  # destructive step.
  local recreate_existing_pr_num=""

  local targets
  targets=$(sync_consumer_canonical_targets "$consumer_name" "$changed_files" "$manifest")

  local skipped
  skipped=$(sync_consumer_skipped_targets "$consumer_name" "$changed_files" "$manifest")
  local kit_count=$(echo "$skipped" | cut -f1)
  local templated_count=$(echo "$skipped" | cut -f2)
  local kit_list=$(echo "$skipped" | cut -f3)
  local templated_list=$(echo "$skipped" | cut -f4)

  if [ -z "$targets" ]; then
    if [ "$kit_count" -gt 0 ] || [ "$templated_count" -gt 0 ]; then
      printf "  ⊘ %s (no canonical targets; deferred: kit=%s templated=%s)\n" \
        "$consumer_name" "${kit_list:-none}" "${templated_list:-none}"
    else
      printf "  · %s (no manifest paths touched by %s)\n" "$consumer_name" "$short_sha"
    fi
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    return 0
  fi

  # Idempotency check before any write. Skipped in dry-run mode: the
  # check probes the consumer repo via `gh api` and dry-run is meant to
  # have zero side effects + zero network dependency. The trade-off:
  # a dry-run plan may show a "would open PR" line even when a PR
  # already exists; the live run will catch and skip it.
  if [ "$dry_run" != "1" ]; then
    local pr_state
    pr_state=$(sync_check_existing_pr "$consumer_repo" "$branch") || {
      printf "  ✗ %s — could not query existing PRs from %s\n" "$consumer_name" "$consumer_repo"
      SYNC_FAILED=$((SYNC_FAILED + 1))
      return 0
    }
    case "$pr_state" in
      open:*)
        local existing_pr_num="${pr_state#open:}"
        if [ "${SYNC_RECREATE_EXISTING:-0}" = "1" ]; then
          # --recreate-existing escape hatch. The destructive close +
          # branch-delete is DEFERRED to sync_open_pr, executed only
          # AFTER the replacement commit is built locally and right
          # BEFORE the push.
          #
          # Rationale (CodeRabbit #231 round 2 caught this): the
          # original layering closed the PR and deleted the branch
          # here, before clone/materialize/commit. If any later step
          # fails (auth, network, no diff after copy, materialize
          # error) the consumer is left with NO open propagation PR
          # at all — strictly worse than the pre-recreate state.
          # Building the replacement first, then collapsing the
          # destructive step to the moment before push, keeps the
          # live PR available until we have something concrete to
          # replace it with.
          #
          # The PR number is threaded into sync_open_pr as a 9th
          # positional arg below; passing as an arg (rather than
          # exporting a global) keeps cross-consumer state isolated
          # since sync_one_consumer is called once per consumer.
          recreate_existing_pr_num="$existing_pr_num"
          # Fall through to sync_open_pr — clone/commit FIRST, then
          # close + delete + push.
        else
          printf "  · %s already in flight (PR #%s on branch %s)\n" \
            "$consumer_name" "$existing_pr_num" "$branch"
          SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
          return 0
        fi
        ;;
      closed:*)
        printf "  · %s already done (PR #%s closed/merged on branch %s)\n" \
          "$consumer_name" "${pr_state#closed:}" "$branch"
        SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
        return 0
        ;;
    esac
  fi

  local target_count
  target_count=$(echo "$targets" | wc -l | tr -d ' ')

  if [ "$dry_run" = "1" ]; then
    printf "  ⤷ %s — would open PR on branch %s (%d canonical file(s))\n" \
      "$consumer_name" "$branch" "$target_count"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      printf "      + %s\n" "$p"
      # --verbose dry-run: emit the per-file diff hunk against the
      # current Mergepath worktree at $sha vs the parent. This is the
      # change set that WOULD be propagated; consumers don't have a
      # local clone in dry-run, so we show the upstream-side diff
      # rather than the downstream effective diff. The latter requires
      # a live clone (sync_open_pr does it; this is the cheap planning
      # view).
      if [ "${SYNC_VERBOSE:-0}" = "1" ]; then
        local parent_sha
        parent_sha=$(git -C "$MERGEPATH_ROOT" rev-parse "${sha}^" 2>/dev/null || echo "")
        if [ -n "$parent_sha" ]; then
          git -C "$MERGEPATH_ROOT" --no-pager diff --no-color "$parent_sha" "$sha" -- "$p" 2>/dev/null \
            | sed 's/^/        /' || true
        fi
      fi
    done <<< "$targets"
    if [ "$kit_count" -gt 0 ] || [ "$templated_count" -gt 0 ]; then
      printf "      (deferred this slice: kit=%s templated=%s)\n" \
        "${kit_list:-none}" "${templated_list:-none}"
    fi
    SYNC_PR_OPENED=$((SYNC_PR_OPENED + 1))
    return 0
  fi

  # Live mode: clone, branch, commit, push, PR.
  # 9th arg: existing PR number to close+delete just before push,
  # used by --recreate-existing. Empty means "no destructive step".
  if ! sync_open_pr "$consumer_name" "$consumer_repo" "$sha" "$commit_subject" \
                    "$branch" "$targets" "$kit_list" "$templated_list" \
                    "$recreate_existing_pr_num"; then
    SYNC_FAILED=$((SYNC_FAILED + 1))
    return 0
  fi
  SYNC_PR_OPENED=$((SYNC_PR_OPENED + 1))
}

# Live PR-open. Clones the consumer repo into a tmpdir (writeable
# workspace, never reuses the cache or sibling worktree), copies canonical
# files from the Mergepath worktree at $sha, commits with the standard
# self-review body, pushes the branch, and creates a PR.
#
# Returns 0 on success, non-zero on failure (caller increments
# SYNC_FAILED). Stdout: human-readable progress lines.
sync_open_pr() {
  local consumer_name=$1
  local consumer_repo=$2
  local sha=$3
  local commit_subject=$4
  local branch=$5
  local targets=$6  # newline-separated paths
  local kit_list=$7
  local templated_list=$8
  # 9th arg: existing PR number to close + branch-delete just
  # before push, only when --recreate-existing fired. Empty when
  # no destructive step is needed. See sync_one_consumer for why
  # this is deferred to the moment-before-push and not done upfront.
  local recreate_existing_pr_num=${9:-}
  local short_sha=${sha:0:7}
  local authoring_agent coauthor_trailer
  authoring_agent=$(sync_authoring_agent) || return 1
  coauthor_trailer=$(sync_coauthor_trailer "$authoring_agent") || return 1

  # Portable mktemp: `-t TEMPLATE` semantics differ between BSD (macOS)
  # and GNU coreutils. macOS treats TEMPLATE as a literal prefix and
  # appends random chars; GNU treats it as a TMPDIR-rooted basename
  # but ONLY if the value contains no slash, AND the trailing X-pattern
  # rules differ. Use the explicit-path form `mktemp -d "$TMPDIR/<X...>"`
  # which both implementations honor identically. cursor CHANGES_REQUESTED
  # on PR #217 caught the GNU/Linux portability gap.
  local tmp_root=${TMPDIR:-/tmp}
  local workspace
  workspace=$(mktemp -d "$tmp_root/mergepath-sync-${consumer_name}.XXXXXX") || {
    err "could not create workspace tmpdir"
    return 1
  }
  # Single-quote the trap body so $workspace is expanded when the trap
  # FIRES (RETURN), not when it's installed — a single quote in TMPDIR
  # or a consumer name can't then break the cleanup command or inject
  # shell syntax.
  #
  # `${workspace:-}` (not bare `$workspace`) is load-bearing: a bash
  # RETURN trap set inside a function is NOT function-scoped — it stays
  # installed and ALSO fires on the return of every PARENT function
  # afterward (sync_all_one_consumer, run_sync_all, ...), where
  # `workspace` (a `local` in THIS function) is out of scope. Under
  # `set -u` a bare `$workspace` reference there aborts the whole
  # script with "unbound variable" — observed live on the first
  # --sync-all wave, right after the matchline PR was opened. The `:-`
  # default makes the spurious parent-return firings a harmless
  # `rm -rf ""` no-op, while the intended firing (this function's own
  # RETURN, workspace still in scope) still cleans up correctly.
  trap 'rm -rf "${workspace:-}"' RETURN

  printf "  ⤷ %s — cloning %s\n" "$consumer_name" "$consumer_repo"
  if ! gh repo clone "$consumer_repo" "$workspace/repo" -- --depth=10 --quiet >&2; then
    err "$consumer_name: gh repo clone failed for $consumer_repo"
    return 1
  fi

  # Per-repo override filter (#200 integration). Each consumer can carry
  # a `.sync-overrides.yml` at its repo root declaring `skip_paths` —
  # canonical/kit paths the propagation script must NOT overwrite for
  # this repo, with a documented `reason` for each. Filter the target
  # list through `override_should_skip_path` BEFORE the materialize
  # loop runs, so the diff/commit/push reflects only paths the consumer
  # has not opted out of. The reason text is logged for audit-trail.
  #
  # An absent overrides file means "no overrides" (the helper returns
  # non-zero for every path). A malformed file is the consumer's CI
  # concern (validate-overrides.sh blocks the consumer's merge); this
  # script treats it conservatively (no skip), which is safer than
  # silently propagating past what may have been a documented divergence.
  local consumer_overrides="$workspace/repo/$OVERRIDES_PATH"
  local filtered_targets=""
  local override_skip_count=0
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    if override_should_skip_path "$consumer_overrides" "$target"; then
      printf "  · %s skip %s (per .sync-overrides.yml: %s)\n" \
        "$consumer_name" "$target" "$OVERRIDE_SKIP_REASON"
      override_skip_count=$((override_skip_count + 1))
      continue
    fi
    if [ -z "$filtered_targets" ]; then
      filtered_targets="$target"
    else
      filtered_targets+=$'\n'"$target"
    fi
  done <<< "$targets"
  targets="$filtered_targets"

  # Early-exit gate. Pre-templated-activation this checked $targets
  # only (canonical-after-override-filter); now also gate on
  # $templated_list so a commit that touches ONLY a templated source
  # (no canonical changes) still materializes. Templated override
  # filtering happens inside materialize_templated_targets — its
  # skip path counters are separate from canonical's.
  if [ -z "$targets" ] && [ -z "$templated_list" ]; then
    if [ "$override_skip_count" -gt 0 ]; then
      printf "  ⊘ %s — all canonical targets skipped per .sync-overrides.yml (%d entries); no templated targets either\n" \
        "$consumer_name" "$override_skip_count"
      SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
      SYNC_PR_OPENED=$((SYNC_PR_OPENED - 1))  # pre-decrement to offset the caller's post-success increment
      return 0
    fi
    # No-targets case without overrides should already have been
    # caught upstream; treat as a no-op return rather than an error.
    return 0
  fi

  # Materialize Mergepath's $sha worktree state for the target files.
  # Using `git show $sha:<path>` is robust against the working tree
  # having other uncommitted edits.
  #
  # Deletion handling: when Mergepath drops a canonical file at $sha,
  # `git ls-tree $sha <path>` returns empty (the path no longer exists
  # in the tree). Treat that as a delete propagation: rm the consumer
  # copy if present. cursor CHANGES_REQUESTED on PR #217 caught the
  # missing delete propagation — without this branch, deletes would
  # fail noisily on `git show` and the script would abort the entire
  # consumer rather than mirroring the delete.
  local target
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    local consumer_target="$workspace/repo/$target"
    local src_mode
    src_mode=$(git -C "$MERGEPATH_ROOT" ls-tree "$sha" -- "$target" | awk '{print $1}')

    if [ -z "$src_mode" ]; then
      # Path absent at $sha → delete propagation.
      if [ -e "$consumer_target" ]; then
        rm -f "$consumer_target"
      fi
      # No mode-mirror for deletes; the path is gone in both trees.
      continue
    fi

    mkdir -p "$(dirname "$consumer_target")"
    if ! git -C "$MERGEPATH_ROOT" show "$sha:$target" >"$consumer_target" 2>/dev/null; then
      err "$consumer_name: could not read $target from mergepath@$short_sha"
      return 1
    fi
    # Mirror the executable bit from the source. Both directions matter:
    # if the source is 100755 the target must be +x (so a hook stays
    # runnable in the consumer); if the source is 100644 the target
    # must NOT be +x (otherwise mode drift accumulates whenever a
    # consumer historically had +x set on a file Mergepath later
    # decided should be plain). cursor's CHANGES_REQUESTED on PR #217
    # caught the one-way version that only added +x.
    case "$src_mode" in
      100755) chmod +x "$consumer_target" ;;
      100644) chmod -x "$consumer_target" ;;
      *)
        err "$consumer_name: unexpected git mode '$src_mode' for $target at $short_sha"
        return 1
        ;;
    esac
    # Stage the dest mode in the git INDEX, not just the working tree:
    # under core.filemode=false (some consumer clones / mode-insensitive
    # filesystems) the caller's blanket `git add -A` ignores the on-disk
    # exec bit, so a mode-only flip on an existing tracked file would not
    # be staged and the propagation PR would carry the wrong mode. Same
    # fix the templated arm got in #471 (PR #475); extended to the
    # canonical arms in #476 (executable canonical scripts are far more
    # common than templated ones). A subsequent `git add -A` preserves an
    # already-staged index mode (verified under core.filemode=false).
    local idx_chmod
    if [ "$src_mode" = "100755" ]; then idx_chmod="+x"; else idx_chmod="-x"; fi
    if ! git -C "$workspace/repo" add -- "$target" \
       || ! git -C "$workspace/repo" update-index --chmod="$idx_chmod" -- "$target"; then
      err "$consumer_name: failed to stage dest mode ($idx_chmod) for $target"
      return 1
    fi
  done <<< "$targets"

  # Templated materialize — render mergepath@$sha's source templates
  # with the consumer's facts (per scripts/lib/template-substitution.sh,
  # #313) and write to consumer dest paths. The helper handles
  # source/dest resolution from the manifest, per-entry override
  # filtering on dest, and atomic render_to. Failures abort the
  # whole consumer (same all-or-nothing semantics as canonical).
  if ! materialize_templated_targets "$consumer_name" "$sha" "$workspace" \
                                      "$templated_list" "$consumer_overrides"; then
    return 1
  fi

  # Commit-path requires-closure gate (#624 Codex P1). The manifest
  # `requires:` key is validated statically by check_sync_manifest, but the
  # per-commit path builds targets from CHANGED canonical files only — kit
  # entries never travel here (they are the sync-all layer). So a commit
  # touching .github/workflows/repo_lint.yml alone would ship the workflow
  # WITHOUT the scripts/ci wrappers its run: steps execute, turning every
  # consumer lint red on the first #601 wave (and on any consumer whose kit
  # is stale). Rather than silently materializing unrequested kit files
  # (surprising wave semantics — the operator asked to propagate one
  # commit), FAIL CLOSED per consumer: after this sync's own files are
  # materialized above, every path a target `requires:` must be
  # byte-current in the consumer clone. Files in this sync's own target
  # set pass automatically (just written); a requirement whose manifest
  # entry scopes `consumers:` away from this consumer is skipped (they
  # never receive it); a consumer-override-skipped file is the consumer's
  # documented divergence (same posture as the override filter above).
  # Anything else missing or stale aborts THIS consumer with the sync-all
  # remedy; other consumers proceed independently.
  local requires_manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"
  local req_violations="" req_target req_entry req_files req_file req_consumers
  while IFS= read -r req_target; do
    [ -z "$req_target" ] && continue
    while IFS= read -r req_entry; do
      [ -z "$req_entry" ] && continue
      # Scope the requirement: if the manifest entry covering the required
      # path names an explicit consumer list that excludes this consumer,
      # the kit never ships here and must not block.
      # mikefarah yq v4 (the engine's dialect): parameterize via strenv, not
      # the jq-style --arg (which yq does not support — a silent no-op gate
      # was the first version of this bug, caught by the reqgate1 test).
      req_consumers=$(REQ_GATE_PATH="$req_entry" yq -r '
        .paths[] | select(.path == strenv(REQ_GATE_PATH))
        | .consumers | (select(tag == "!!str") // (join(","))) | tostring
      ' "$requires_manifest" 2>/dev/null | head -n1)
      if [ -n "$req_consumers" ] && [ "$req_consumers" != "all" ]; then
        case ",$req_consumers," in
          *",$consumer_name,"*) : ;;
          *) continue ;;
        esac
      fi
      case "$req_entry" in
        */) req_files=$(git -C "$MERGEPATH_ROOT" ls-tree -r --name-only "$sha" -- "$req_entry" 2>/dev/null || true) ;;
        *)  req_files="$req_entry" ;;
      esac
      while IFS= read -r req_file; do
        [ -z "$req_file" ] && continue
        if override_should_skip_path "$consumer_overrides" "$req_file"; then
          continue
        fi
        if ! git -C "$MERGEPATH_ROOT" show "$sha:$req_file" 2>/dev/null \
             | cmp -s - "$workspace/repo/$req_file" 2>/dev/null; then
          req_violations+="${req_violations:+$'\n'}$req_file (required by $req_target)"
        fi
      done <<< "$req_files"
    done <<< "$(REQ_GATE_PATH="$req_target" yq -r '.paths[] | select(.path == strenv(REQ_GATE_PATH)) | (.requires // [])[]' "$requires_manifest" 2>/dev/null)"
  done <<< "$targets"
  if [ -n "$req_violations" ]; then
    err "$consumer_name: requires-closure gate (#624): $(echo "$req_violations" | wc -l | tr -d ' ') file(s) required by this sync's target(s) are missing or stale on the consumer (first: $(echo "$req_violations" | head -n1)). A commit-path sync must not ship a requires-bearing target ahead of its kit — run the --sync-all wave path (which carries kit targets) to bring this consumer current, then retry."
    return 1
  fi

  # Sanity: did the copy actually change anything? If the consumer was
  # already in sync (someone hand-propagated it before us, or a prior
  # sync ran but the PR was never opened), don't push an empty commit.
  # `git status --porcelain` (not `git diff HEAD`) so the no-op check
  # also catches BRAND-NEW files: a consumer missing a whole canonical
  # or kit file gets it materialized as an untracked file, which
  # `git diff --quiet HEAD` would not see — it would false-negative as
  # "already in sync" and skip a real propagation. Porcelain reports
  # tracked modifications AND untracked additions.
  if [ -n "$(git -C "$workspace/repo" status --porcelain)" ]; then
    :
  else
    printf "  · %s already in sync at HEAD (no diff after copy)\n" "$consumer_name"
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    SYNC_PR_OPENED=$((SYNC_PR_OPENED - 1))  # caller incremented eagerly
    return 0
  fi

  # Branch + commit. Use git config from the consumer clone (or
  # mergepath's, since `gh repo clone` inherits the user's local
  # git identity).
  if ! git -C "$workspace/repo" checkout -q -b "$branch"; then
    err "$consumer_name: git checkout -b $branch failed"
    return 1
  fi
  git -C "$workspace/repo" add -A
  local target_lines
  target_lines=$(while IFS= read -r p; do [ -z "$p" ] && continue; echo "  - $p"; done <<< "$targets")
  # Append templated dest paths to the commit-body file list. Use the
  # `.dest` value (where the file lands in the consumer), not `.path`
  # (the manifest identifier in mergepath), so a reader sees the same
  # paths that show up in `git status`.
  if [ -n "$templated_list" ]; then
    local _tpls _tpl _tpl_dest
    IFS=',' read -ra _tpls <<< "$templated_list"
    for _tpl in "${_tpls[@]}"; do
      [ -z "$_tpl" ] && continue
      _tpl_dest=$(MERGEPATH_TPL_PATH="$_tpl" yq -r '
        env(MERGEPATH_TPL_PATH) as $p
        | .paths[] | select(.path == $p) | (.dest // .path)
      ' "$MERGEPATH_ROOT/$MANIFEST_PATH")
      target_lines+=$'\n'"  - ${_tpl_dest} (templated, rendered from ${_tpl})"
    done
  fi
  local deferred_note=""
  if [ -n "$kit_list" ]; then
    deferred_note="
Deferred this propagation (sync-to-downstream.sh ${SCRIPT_VERSION}
handles canonical + templated paths in this slice; kit lands in
slice 2):
  kit: ${kit_list:-none}
"
  fi
  if ! git -C "$workspace/repo" commit -q -m "$(cat <<EOF
sync from mergepath@${short_sha}: ${commit_subject}

Source: https://github.com/nathanjohnpayne/mergepath/commit/${sha}
Files:
${target_lines}
${deferred_note}
Authoring-Agent: ${authoring_agent}

## Self-Review
- Correctness: mirrors mergepath@${short_sha} verbatim per .mergepath-sync.yml
- Regression risk: low; same change has been reviewed in the upstream PR
- Style: N/A (verbatim mirror)
- Test coverage: relies on the consumer repo CI
- Security: no new attack surface

${coauthor_trailer}
EOF
)"; then
    err "$consumer_name: git commit failed"
    return 1
  fi

  # --recreate-existing destructive step. Deferred from
  # sync_one_consumer to here so the live PR stays open until we
  # have a replacement commit in hand. By the time we reach this
  # point: the clone succeeded, materialize succeeded, the diff is
  # non-empty (we just committed), so closing the live PR + deleting
  # its branch is safe — failure between here and the next two
  # lines (close, delete, push) is the only window where we could
  # be left with no PR, and all three failures are loudly logged.
  if [ -n "$recreate_existing_pr_num" ]; then
    printf "  ⤷ %s — closing existing PR #%s for --recreate-existing\n" \
      "$consumer_name" "$recreate_existing_pr_num"
    if ! sync_author_gh pr close "$recreate_existing_pr_num" --repo "$consumer_repo" \
          --comment "Closed by \`scripts/sync-to-downstream.sh --recreate-existing\`. Reopening with a fresh synthesized body on a recreated \`$branch\`." >&2; then
      err "$consumer_name: PR close failed for #$recreate_existing_pr_num"
      return 1
    fi
    # Delete the remote branch so the subsequent push is a fresh-
    # branch create (not a non-fast-forward update against the
    # branch HEAD the closed PR pointed at — Codex #231 P1 caught
    # the original missing-delete bug).
    #
    # Use --include to capture the HTTP status line and switch on
    # it explicitly. Only 204 (success) and 404/422 (already-absent)
    # are safe to swallow; everything else (401/403 auth, 5xx, etc.)
    # must surface as a hard failure rather than be confused for
    # "already absent" (CodeRabbit #231 round 2 caught the too-
    # permissive fallback that masked any failed probe).
    printf "  ⤷ %s — deleting remote branch %s for --recreate-existing\n" \
      "$consumer_name" "$branch"
    local _del_response _del_status _del_rc=0
    _del_response=$(sync_author_gh api --include -X DELETE "repos/${consumer_repo}/git/refs/heads/${branch}" 2>&1) || _del_rc=$?
    _del_status=$(printf '%s\n' "$_del_response" | awk '
      /^HTTP\/[0-9.]+[[:space:]]+[0-9]+/ {
        match($0, /[0-9]+/)
        # The first numeric run in an HTTP status line is the
        # protocol minor version (e.g. "HTTP/1.1") or status code.
        # Walk the line, take the second numeric run.
        n = split($0, parts, /[^0-9]+/)
        for (i = 1; i <= n; i++) {
          if (parts[i] != "" && parts[i] != "1" && parts[i] != "2" && length(parts[i]) == 3) {
            print parts[i]; exit
          }
        }
        # Fallback: print the last numeric run (the status code is
        # always 3 digits at the end of the status line preamble).
        for (i = n; i >= 1; i--) if (parts[i] ~ /^[0-9]{3}$/) { print parts[i]; exit }
      }')
    case "$_del_status" in
      204)
        :  # ok, branch deleted
        ;;
      404|422)
        printf "    · branch %s already absent on remote (status=%s, ok)\n" "$branch" "$_del_status"
        ;;
      *)
        err "$consumer_name: failed to delete remote branch $branch (status=${_del_status:-unknown}, rc=$_del_rc); refusing to push to avoid non-fast-forward"
        return 1
        ;;
    esac
  fi

  # Push. Commit authorship is git-config based, and the #410 spike
  # verified ordinary git push is not part of the gh write-attribution
  # race. PR creation below is author-attributed through sync_author_gh.
  printf "  ⤷ %s — pushing branch %s\n" "$consumer_name" "$branch"
  if ! git -C "$workspace/repo" push -q -u origin "$branch" 2>&1; then
    err "$consumer_name: git push failed"
    return 1
  fi

  # --no-pr (#199): push the branch but stop here. Useful for staging
  # the propagation across N consumers and inspecting branches before
  # committing to PR creation.
  if [ "${SYNC_NO_PR:-0}" = "1" ]; then
    printf "  ✓ %s — pushed branch %s (--no-pr; no PR opened)\n" "$consumer_name" "$branch"
    return 0
  fi

  # Open the PR.
  printf "  ⤷ %s — opening PR\n" "$consumer_name"
  local pr_url
  pr_url=$(sync_author_gh pr create --repo "$consumer_repo" --base main --head "$branch" \
    --title "sync: ${commit_subject} (mergepath@${short_sha})" \
    --body "$(cat <<EOF
Auto-propagated from [mergepath@${short_sha}](https://github.com/nathanjohnpayne/mergepath/commit/${sha}) by \`scripts/sync-to-downstream.sh\` (v${SCRIPT_VERSION}, see [#168](https://github.com/nathanjohnpayne/mergepath/issues/168)).

## Files synced
${target_lines}
${deferred_note}
## Source

${commit_subject}

https://github.com/nathanjohnpayne/mergepath/commit/${sha}

Authoring-Agent: ${authoring_agent}

## Self-Review
- Correctness: mirrors mergepath@${short_sha} verbatim per the upstream manifest. The change has already been reviewed in the upstream Mergepath PR.
- Regression risk: low. Verbatim mirror of an already-reviewed upstream change.
- Style: N/A (mirror).
- Test coverage: relies on the consumer repo CI. No test changes shipped.
- Security: no new attack surface; the sync script never ran with elevated privileges in this consumer.
EOF
)" 2>&1) || {
    err "$consumer_name: PR create failed: $pr_url"
    return 1
  }
  printf "  ✓ %s — opened %s\n" "$consumer_name" "$pr_url"
}

# --- sync-all live PR-open --------------------------------------------------
#
# The --sync-all sibling of sync_open_pr. Structurally parallel — same
# clone-into-tmpdir, same .sync-overrides.yml filter, same mktemp
# portability form, same --recreate-existing destructive-step ordering
# (commit FIRST, then close+delete+push) — but with two differences
# the per-commit path doesn't need:
#
#   1. It materializes the CURRENT HEAD state of canonical paths
#      (`git show HEAD:<path>`) AND kit directories (recursive file
#      copy with allow-extras — consumer-only files are NOT deleted),
#      rather than the changed-at-a-commit subset.
#   2. The commit / PR body wording says "bulk sync to mergepath@<sha>"
#      and lists both canonical and kit paths plus any override-skipped
#      paths, instead of pointing at a single source commit.
#
# It is deliberately a separate function rather than a parameterized
# sync_open_pr: the per-commit path is pinned by an awk ordering test
# (destructive-recreate step placement) and a fragile signature change
# there risks regressing #231's fix. Mirroring the structure keeps both
# paths independently verifiable.
#
# Args:
#   $1 consumer_name
#   $2 consumer_repo
#   $3 sha               mergepath HEAD sha at run time
#   $4 branch            sync-all branch name (mergepath-sync/sync-all-<sha>)
#   $5 canonical_targets newline-separated canonical paths
#   $6 kit_targets       newline-separated kit paths (dir mirrors)
#   $7 templated_list    comma-joined templated paths to render
#   $8 recreate_existing_pr_num  optional; close+delete just before push
#
# Returns 0 on success, non-zero on failure (caller increments
# SYNC_FAILED). Stdout: human-readable progress lines.
sync_all_open_pr() {
  local consumer_name=$1
  local consumer_repo=$2
  local sha=$3
  local branch=$4
  local canonical_targets=$5  # newline-separated
  local kit_targets=$6        # newline-separated
  local templated_list=$7     # comma-joined, display only
  local recreate_existing_pr_num=${8:-}
  local short_sha=${sha:0:7}
  local authoring_agent coauthor_trailer
  authoring_agent=$(sync_authoring_agent) || return 1
  coauthor_trailer=$(sync_coauthor_trailer "$authoring_agent") || return 1

  local tmp_root=${TMPDIR:-/tmp}
  local workspace
  workspace=$(mktemp -d "$tmp_root/mergepath-sync-${consumer_name}.XXXXXX") || {
    err "could not create workspace tmpdir"
    return 1
  }
  # Single-quote the trap body so $workspace is expanded when the trap
  # FIRES (RETURN), not when it's installed — a single quote in TMPDIR
  # or a consumer name can't then break the cleanup command or inject
  # shell syntax.
  #
  # `${workspace:-}` (not bare `$workspace`) is load-bearing: a bash
  # RETURN trap set inside a function is NOT function-scoped — it stays
  # installed and ALSO fires on the return of every PARENT function
  # afterward (sync_all_one_consumer, run_sync_all, ...), where
  # `workspace` (a `local` in THIS function) is out of scope. Under
  # `set -u` a bare `$workspace` reference there aborts the whole
  # script with "unbound variable" — observed live on the first
  # --sync-all wave, right after the matchline PR was opened. The `:-`
  # default makes the spurious parent-return firings a harmless
  # `rm -rf ""` no-op, while the intended firing (this function's own
  # RETURN, workspace still in scope) still cleans up correctly.
  trap 'rm -rf "${workspace:-}"' RETURN

  printf "  ⤷ %s — cloning %s\n" "$consumer_name" "$consumer_repo"
  if ! gh repo clone "$consumer_repo" "$workspace/repo" -- --depth=10 --quiet >&2; then
    err "$consumer_name: gh repo clone failed for $consumer_repo"
    return 1
  fi

  # Per-repo override filter (#200 integration) — load-bearing for
  # --sync-all. A consumer's .sync-overrides.yml `skip_paths` declares
  # canonical/kit paths the propagation script must NOT overwrite for
  # that repo. --sync-all replays the FULL manifest, so without this
  # filter a bulk reconcile would clobber every documented divergence
  # in one shot — strictly worse than no --sync-all at all. The filter
  # runs against BOTH the canonical target list and the kit target
  # list, identically to the per-commit path's canonical-only filter.
  local consumer_overrides="$workspace/repo/$OVERRIDES_PATH"
  local override_skip_count=0
  local override_skipped_list=""

  local filtered_canonical=""
  local target
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    if override_should_skip_path "$consumer_overrides" "$target"; then
      printf "  · %s skip %s (per .sync-overrides.yml: %s)\n" \
        "$consumer_name" "$target" "$OVERRIDE_SKIP_REASON"
      override_skip_count=$((override_skip_count + 1))
      if [ -z "$override_skipped_list" ]; then
        override_skipped_list="$target"
      else
        override_skipped_list+=",$target"
      fi
      continue
    fi
    if [ -z "$filtered_canonical" ]; then
      filtered_canonical="$target"
    else
      filtered_canonical+=$'\n'"$target"
    fi
  done <<< "$canonical_targets"
  canonical_targets="$filtered_canonical"

  local filtered_kit=""
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    if override_should_skip_path "$consumer_overrides" "$target"; then
      printf "  · %s skip %s (per .sync-overrides.yml: %s)\n" \
        "$consumer_name" "$target" "$OVERRIDE_SKIP_REASON"
      override_skip_count=$((override_skip_count + 1))
      if [ -z "$override_skipped_list" ]; then
        override_skipped_list="$target"
      else
        override_skipped_list+=",$target"
      fi
      continue
    fi
    if [ -z "$filtered_kit" ]; then
      filtered_kit="$target"
    else
      filtered_kit+=$'\n'"$target"
    fi
  done <<< "$kit_targets"
  kit_targets="$filtered_kit"

  # Early-exit gate. Pre-templated-activation this checked canonical
  # and kit only; now also gate on $templated_list so a consumer
  # whose only opt-ins are templated entries still materializes.
  if [ -z "$canonical_targets" ] && [ -z "$kit_targets" ] && [ -z "$templated_list" ]; then
    if [ "$override_skip_count" -gt 0 ]; then
      printf "  ⊘ %s — all canonical+kit targets skipped per .sync-overrides.yml (%d entries); no templated targets either\n" \
        "$consumer_name" "$override_skip_count"
      SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
      SYNC_PR_OPENED=$((SYNC_PR_OPENED - 1))  # offset caller's eager increment
      return 0
    fi
    # No targets at all and no overrides — caller should have caught
    # this; treat as a no-op return.
    return 0
  fi

  # Materialize canonical paths verbatim from mergepath HEAD. Same
  # ls-tree-then-show logic as sync_open_pr, including delete
  # propagation (a manifest path absent at HEAD → rm the consumer
  # copy) and executable-bit mirroring.
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    local consumer_target="$workspace/repo/$target"
    local src_mode
    src_mode=$(git -C "$MERGEPATH_ROOT" ls-tree "$sha" -- "$target" | awk '{print $1}')

    if [ -z "$src_mode" ]; then
      if [ -e "$consumer_target" ]; then
        rm -f "$consumer_target"
      fi
      continue
    fi

    mkdir -p "$(dirname "$consumer_target")"
    if ! git -C "$MERGEPATH_ROOT" show "$sha:$target" >"$consumer_target" 2>/dev/null; then
      err "$consumer_name: could not read $target from mergepath@$short_sha"
      return 1
    fi
    case "$src_mode" in
      100755) chmod +x "$consumer_target" ;;
      100644) chmod -x "$consumer_target" ;;
      *)
        err "$consumer_name: unexpected git mode '$src_mode' for $target at $short_sha"
        return 1
        ;;
    esac
    # Stage the dest mode in the git INDEX as well — see the sync_open_pr
    # canonical arm above. Under core.filemode=false the caller's blanket
    # `git add -A` drops a mode-only flip, so an executable canonical file
    # would propagate non-executable (#476).
    local idx_chmod
    if [ "$src_mode" = "100755" ]; then idx_chmod="+x"; else idx_chmod="-x"; fi
    if ! git -C "$workspace/repo" add -- "$target" \
       || ! git -C "$workspace/repo" update-index --chmod="$idx_chmod" -- "$target"; then
      err "$consumer_name: failed to stage dest mode ($idx_chmod) for $target"
      return 1
    fi
  done <<< "$canonical_targets"

  # Materialize kit directories with allow-extras semantics: copy every
  # file Mergepath has under the kit path into the consumer, but do NOT
  # delete consumer-only extras. This is the same semantic compare_kit
  # uses for audit (consumer-only files are ignored, not flagged) and
  # the documented kit contract in .mergepath-sync.yml.
  #
  # `git ls-tree -r --name-only HEAD <kitpath>` enumerates the kit's
  # tracked files at HEAD; per-file `git show` materializes each one
  # verbatim with its mode mirrored. A kit path absent at HEAD entirely
  # is a no-op (nothing to copy; we never delete the consumer's dir).
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    local kit_dir="${target%/}"
    local kit_files
    kit_files=$(git -C "$MERGEPATH_ROOT" ls-tree -r --name-only "$sha" -- "$kit_dir" 2>/dev/null || true)
    if [ -z "$kit_files" ]; then
      # Kit path has no tracked files at HEAD — nothing to mirror.
      # Allow-extras means we never delete the consumer's copy, so
      # this is simply a no-op for this kit path.
      continue
    fi
    while IFS= read -r kit_file; do
      [ -z "$kit_file" ] && continue
      local consumer_kit_target="$workspace/repo/$kit_file"
      local kit_mode
      kit_mode=$(git -C "$MERGEPATH_ROOT" ls-tree "$sha" -- "$kit_file" | awk '{print $1}')
      [ -z "$kit_mode" ] && continue
      mkdir -p "$(dirname "$consumer_kit_target")"
      if ! git -C "$MERGEPATH_ROOT" show "$sha:$kit_file" >"$consumer_kit_target" 2>/dev/null; then
        err "$consumer_name: could not read $kit_file from mergepath@$short_sha"
        return 1
      fi
      case "$kit_mode" in
        100755) chmod +x "$consumer_kit_target" ;;
        100644) chmod -x "$consumer_kit_target" ;;
        *)
          err "$consumer_name: unexpected git mode '$kit_mode' for $kit_file at $short_sha"
          return 1
          ;;
      esac
      # Stage the kit dest mode in the git INDEX as well — see the
      # canonical arms above. Under core.filemode=false the caller's
      # blanket `git add -A` drops a mode-only flip, so an executable kit
      # file would propagate non-executable (#476).
      local kit_idx_chmod
      if [ "$kit_mode" = "100755" ]; then kit_idx_chmod="+x"; else kit_idx_chmod="-x"; fi
      if ! git -C "$workspace/repo" add -- "$kit_file" \
         || ! git -C "$workspace/repo" update-index --chmod="$kit_idx_chmod" -- "$kit_file"; then
        err "$consumer_name: failed to stage kit dest mode ($kit_idx_chmod) for $kit_file"
        return 1
      fi
    done <<< "$kit_files"
  done <<< "$kit_targets"

  # Templated materialize — render mergepath@$sha's source templates
  # with each consumer's facts (per scripts/lib/template-substitution.sh,
  # #313) and write to consumer dest paths. The helper handles
  # source/dest resolution from the manifest, per-entry override
  # filtering on dest, and atomic render_to. Failures abort the
  # whole consumer (same all-or-nothing semantics as canonical/kit).
  if ! materialize_templated_targets "$consumer_name" "$sha" "$workspace" \
                                      "$templated_list" "$consumer_overrides"; then
    return 1
  fi

  # Sanity: did the copy actually change anything? A consumer already
  # at HEAD state (hand-propagated, or a prior --sync-all PR merged)
  # should not get an empty commit / PR.
  # `git status --porcelain` (not `git diff HEAD`) so the no-op check
  # also catches BRAND-NEW files: a consumer missing a whole canonical
  # or kit file gets it materialized as an untracked file, which
  # `git diff --quiet HEAD` would not see — it would false-negative as
  # "already in sync" and skip a real propagation. Porcelain reports
  # tracked modifications AND untracked additions.
  if [ -n "$(git -C "$workspace/repo" status --porcelain)" ]; then
    :
  else
    printf "  · %s already in sync at HEAD (no diff after copy)\n" "$consumer_name"
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    SYNC_PR_OPENED=$((SYNC_PR_OPENED - 1))  # caller incremented eagerly
    return 0
  fi

  if ! git -C "$workspace/repo" checkout -q -b "$branch"; then
    err "$consumer_name: git checkout -b $branch failed"
    return 1
  fi
  git -C "$workspace/repo" add -A

  # Build the path lists for the commit / PR body.
  local canonical_lines kit_lines templated_lines
  canonical_lines=$(while IFS= read -r p; do [ -z "$p" ] && continue; echo "  - $p"; done <<< "$canonical_targets")
  kit_lines=$(while IFS= read -r p; do [ -z "$p" ] && continue; echo "  - $p (kit, allow-extras)"; done <<< "$kit_targets")
  templated_lines=""
  if [ -n "$templated_list" ]; then
    local _tpls_a _tpl_a _tpl_a_dest
    IFS=',' read -ra _tpls_a <<< "$templated_list"
    for _tpl_a in "${_tpls_a[@]}"; do
      [ -z "$_tpl_a" ] && continue
      _tpl_a_dest=$(MERGEPATH_TPL_PATH="$_tpl_a" yq -r '
        env(MERGEPATH_TPL_PATH) as $p
        | .paths[] | select(.path == $p) | (.dest // .path)
      ' "$MERGEPATH_ROOT/$MANIFEST_PATH")
      templated_lines+="  - ${_tpl_a_dest} (templated, rendered from ${_tpl_a})"$'\n'
    done
  fi
  [ -z "$canonical_lines" ] && canonical_lines="  (none)"
  [ -z "$kit_lines" ] && kit_lines="  (none)"
  [ -z "$templated_lines" ] && templated_lines="  (none)"

  local override_note=""
  if [ -n "$override_skipped_list" ]; then
    override_note="
Override-skipped (per the consumer's .sync-overrides.yml — intentional
divergences left untouched):
  ${override_skipped_list}
"
  fi

  if ! git -C "$workspace/repo" commit -q -m "$(cat <<EOF
bulk sync to mergepath@${short_sha} — verbatim canonical/kit mirror + per-consumer templated render per .mergepath-sync.yml

Source: https://github.com/nathanjohnpayne/mergepath/commit/${sha}
Canonical paths synced:
${canonical_lines}
Kit paths synced:
${kit_lines}
Templated paths rendered (per-consumer facts applied):
${templated_lines}
${override_note}
Authoring-Agent: ${authoring_agent}

## Self-Review
- Correctness: mirrors mergepath@${short_sha} HEAD state verbatim per .mergepath-sync.yml; .sync-overrides.yml honored per-consumer
- Regression risk: low; verbatim mirror, kit paths use allow-extras (consumer-only files kept)
- Style: N/A (verbatim mirror)
- Test coverage: relies on the consumer repo CI
- Security: no new attack surface

${coauthor_trailer}
EOF
)"; then
    err "$consumer_name: git commit failed"
    return 1
  fi

  # --recreate-existing destructive step. Deferred to here (after the
  # replacement commit is built) for the same reason as sync_open_pr:
  # the live PR stays open until we have something concrete to replace
  # it with. Close → delete remote branch → push, all loudly logged.
  if [ -n "$recreate_existing_pr_num" ]; then
    printf "  ⤷ %s — closing existing PR #%s for --recreate-existing\n" \
      "$consumer_name" "$recreate_existing_pr_num"
    if ! sync_author_gh pr close "$recreate_existing_pr_num" --repo "$consumer_repo" \
          --comment "Closed by \`scripts/sync-to-downstream.sh --sync-all --recreate-existing\`. Reopening with a fresh synthesized body on a recreated \`$branch\`." >&2; then
      err "$consumer_name: PR close failed for #$recreate_existing_pr_num"
      return 1
    fi
    printf "  ⤷ %s — deleting remote branch %s for --recreate-existing\n" \
      "$consumer_name" "$branch"
    local _del_response _del_status _del_rc=0
    _del_response=$(sync_author_gh api --include -X DELETE "repos/${consumer_repo}/git/refs/heads/${branch}" 2>&1) || _del_rc=$?
    _del_status=$(printf '%s\n' "$_del_response" | awk '
      /^HTTP\/[0-9.]+[[:space:]]+[0-9]+/ {
        n = split($0, parts, /[^0-9]+/)
        for (i = 1; i <= n; i++) {
          if (parts[i] != "" && parts[i] != "1" && parts[i] != "2" && length(parts[i]) == 3) {
            print parts[i]; exit
          }
        }
        for (i = n; i >= 1; i--) if (parts[i] ~ /^[0-9]{3}$/) { print parts[i]; exit }
      }')
    case "$_del_status" in
      204)
        :
        ;;
      404|422)
        printf "    · branch %s already absent on remote (status=%s, ok)\n" "$branch" "$_del_status"
        ;;
      *)
        err "$consumer_name: failed to delete remote branch $branch (status=${_del_status:-unknown}, rc=$_del_rc); refusing to push to avoid non-fast-forward"
        return 1
        ;;
    esac
  fi

  printf "  ⤷ %s — pushing branch %s\n" "$consumer_name" "$branch"
  if ! git -C "$workspace/repo" push -q -u origin "$branch" 2>&1; then
    err "$consumer_name: git push failed"
    return 1
  fi

  if [ "${SYNC_NO_PR:-0}" = "1" ]; then
    printf "  ✓ %s — pushed branch %s (--no-pr; no PR opened)\n" "$consumer_name" "$branch"
    return 0
  fi

  printf "  ⤷ %s — opening PR\n" "$consumer_name"
  local pr_url
  pr_url=$(sync_author_gh pr create --repo "$consumer_repo" --base main --head "$branch" \
    --title "sync: bulk reconcile to mergepath@${short_sha}" \
    --body "$(cat <<EOF
Bulk sync to [mergepath@${short_sha}](https://github.com/nathanjohnpayne/mergepath/commit/${sha}) — verbatim canonical/kit mirror per \`.mergepath-sync.yml\`.

Opened by \`scripts/sync-to-downstream.sh --sync-all\` (v${SCRIPT_VERSION}, see [#168](https://github.com/nathanjohnpayne/mergepath/issues/168)). Unlike a per-commit propagation PR, this replays the **current HEAD state of every canonical + kit path** so a consumer that has fallen behind reaches a clean steady state in one shot.

## Canonical paths synced
${canonical_lines}

## Kit paths synced
${kit_lines}

## Templated paths rendered (per-consumer facts applied)
${templated_lines}
${override_note}
Authoring-Agent: ${authoring_agent}

## Self-Review
- Correctness: mirrors mergepath@${short_sha} HEAD state verbatim per the manifest. Each path was already reviewed in its upstream PR.
- Regression risk: low. Verbatim mirror; kit paths use allow-extras semantics so consumer-only files are kept.
- Style: N/A (mirror).
- Test coverage: relies on the consumer repo CI. No test changes shipped.
- Security: no new attack surface; \`.sync-overrides.yml\` was honored per-consumer so documented divergences are untouched.
EOF
)" 2>&1) || {
    err "$consumer_name: PR create failed: $pr_url"
    return 1
  }
  printf "  ✓ %s — opened %s\n" "$consumer_name" "$pr_url"
}

# Per-consumer --sync-all orchestration. Mirrors sync_one_consumer:
# enumerate full canonical + kit target sets, idempotency-probe (skipped
# in dry-run), then dry-run plan OR live sync_all_open_pr. Sets
# SYNC_PR_OPENED / SYNC_SKIPPED / SYNC_FAILED in the parent.
sync_all_one_consumer() {
  local consumer_name=$1
  local consumer_repo=$2
  local sha=$3
  local short_sha=${sha:0:7}
  local dry_run=${4:-0}
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  local branch
  branch=$(sync_all_branch_name "$sha")

  local recreate_existing_pr_num=""

  local canonical_targets kit_targets templated_targets
  canonical_targets=$(sync_all_consumer_canonical_targets "$consumer_name" "$manifest")
  kit_targets=$(sync_all_consumer_kit_targets "$consumer_name" "$manifest")
  templated_targets=$(sync_all_consumer_templated_targets "$consumer_name" "$manifest")
  local templated_list
  templated_list=$(echo "$templated_targets" | grep -v '^$' | paste -sd, - 2>/dev/null || true)

  if [ -z "$canonical_targets" ] && [ -z "$kit_targets" ] && [ -z "$templated_targets" ]; then
    printf "  · %s (no canonical/kit/templated manifest paths opted in)\n" "$consumer_name"
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    return 0
  fi

  # Idempotency check before any write. Skipped in dry-run (probes the
  # consumer repo via `gh api`; dry-run is meant to be side-effect- and
  # network-free). Same trade-off as sync_one_consumer's check.
  if [ "$dry_run" != "1" ]; then
    local pr_state
    pr_state=$(sync_check_existing_pr "$consumer_repo" "$branch") || {
      printf "  ✗ %s — could not query existing PRs from %s\n" "$consumer_name" "$consumer_repo"
      SYNC_FAILED=$((SYNC_FAILED + 1))
      return 0
    }
    case "$pr_state" in
      open:*)
        local existing_pr_num="${pr_state#open:}"
        if [ "${SYNC_RECREATE_EXISTING:-0}" = "1" ]; then
          recreate_existing_pr_num="$existing_pr_num"
          # Fall through — clone/commit FIRST, then close+delete+push.
        else
          printf "  · %s already in flight (sync-all PR #%s on branch %s)\n" \
            "$consumer_name" "$existing_pr_num" "$branch"
          SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
          return 0
        fi
        ;;
      closed:*)
        printf "  · %s already done (sync-all PR #%s closed/merged on branch %s)\n" \
          "$consumer_name" "${pr_state#closed:}" "$branch"
        SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
        return 0
        ;;
    esac
  fi

  if [ "$dry_run" = "1" ]; then
    # Override-skips are per-consumer and depend on the consumer's
    # .sync-overrides.yml, which lives in the consumer repo. The live
    # path applies the filter inside sync_all_open_pr after cloning;
    # dry-run does not clone, so for a REMOTE consumer it cannot show
    # override-skips. For a LOCAL sibling/cache worktree, though, the
    # overrides file is on disk and we read it directly — so the
    # dry-run plan reflects the SAME skip decisions the live run would
    # make. The override-skipped paths are removed from the `+` target
    # list entirely (not synced) and surfaced as `- ... (SKIPPED ...)`
    # lines, exactly mirroring the live behavior. This is what makes
    # `--sync-all --dry-run` an honest preview of override honoring.
    local local_overrides=""
    local consumer_root
    if consumer_root=$(resolve_consumer_worktree "$consumer_name" 2>/dev/null); then
      if [ -f "$consumer_root/$OVERRIDES_PATH" ]; then
        local_overrides="$consumer_root/$OVERRIDES_PATH"
      fi
    fi

    # Partition canonical + kit + templated targets into synced vs.
    # override-skipped. Templated overrides are keyed on the consumer
    # destination path, matching materialize_templated_targets.
    local plan_canonical="" plan_kit="" plan_templated_list="" plan_skipped=""
    local p
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if [ -n "$local_overrides" ] && override_should_skip_path "$local_overrides" "$p"; then
        plan_skipped+="      - $p (SKIPPED per .sync-overrides.yml: $OVERRIDE_SKIP_REASON)"$'\n'
        continue
      fi
      plan_canonical+="$p"$'\n'
    done <<< "$canonical_targets"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if [ -n "$local_overrides" ] && override_should_skip_path "$local_overrides" "$p"; then
        plan_skipped+="      - $p (SKIPPED per .sync-overrides.yml: $OVERRIDE_SKIP_REASON)"$'\n'
        continue
      fi
      plan_kit+="$p"$'\n'
    done <<< "$kit_targets"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      local tpl_dest
      tpl_dest=$(MERGEPATH_TPL_PATH="$p" yq -r '
        env(MERGEPATH_TPL_PATH) as $p
        | .paths[] | select(.path == $p) | (.dest // .path)
      ' "$manifest")
      if [ -n "$local_overrides" ] && override_should_skip_path "$local_overrides" "$tpl_dest"; then
        plan_skipped+="      - $tpl_dest (templated, SKIPPED per .sync-overrides.yml: $OVERRIDE_SKIP_REASON)"$'\n'
        continue
      fi
      if [ -z "$plan_templated_list" ]; then
        plan_templated_list="$p"
      else
        plan_templated_list+=",$p"
      fi
    done <<< "$templated_targets"

    # Count non-empty lines. `grep -c .` exits 1 when there are zero
    # matches, which under `|| echo 0` would append a SECOND "0" and
    # corrupt the printf %d below. Use a guard that yields a clean
    # single integer for the empty case.
    local canonical_count kit_count
    if [ -n "${plan_canonical//$'\n'/}" ]; then
      canonical_count=$(printf '%s' "$plan_canonical" | grep -c .)
    else
      canonical_count=0
    fi
    if [ -n "${plan_kit//$'\n'/}" ]; then
      kit_count=$(printf '%s' "$plan_kit" | grep -c .)
    else
      kit_count=0
    fi

    # Zero-target guard — mirror sync_all_open_pr's live behavior. When
    # the consumer's .sync-overrides.yml filters out every canonical,
    # kit, and templated path, the live path skips the consumer without
    # opening a PR; the dry-run plan must report it as skipped too, or
    # it overstates the planned PR count.
    if [ "$canonical_count" -eq 0 ] && [ "$kit_count" -eq 0 ] && [ -z "$plan_templated_list" ]; then
      if [ -n "$plan_skipped" ]; then
        printf "  ⊘ %s — all effective sync targets skipped per .sync-overrides.yml\n" \
          "$consumer_name"
        printf '%s' "$plan_skipped"
      else
        printf "  ⊘ %s — no canonical+kit/templated targets\n" "$consumer_name"
      fi
      SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
      return 0
    fi

    printf "  ⤷ %s — would open PR on branch %s (%d canonical + %d kit path(s))\n" \
      "$consumer_name" "$branch" "$canonical_count" "$kit_count"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      printf "      + %s (canonical)\n" "$p"
      if [ "${SYNC_VERBOSE:-0}" = "1" ]; then
        git -C "$MERGEPATH_ROOT" --no-pager show --no-color "$sha:$p" 2>/dev/null \
          | sed 's/^/        /' || true
      fi
    done <<< "$plan_canonical"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      printf "      + %s (kit, allow-extras)\n" "$p"
    done <<< "$plan_kit"
    if [ -n "$plan_skipped" ]; then
      printf '%s' "$plan_skipped"
    fi
    if [ -n "$plan_templated_list" ]; then
      printf "      (templated, rendered per consumer facts: %s)\n" "$plan_templated_list"
    fi
    SYNC_PR_OPENED=$((SYNC_PR_OPENED + 1))
    return 0
  fi

  if ! sync_all_open_pr "$consumer_name" "$consumer_repo" "$sha" "$branch" \
                        "$canonical_targets" "$kit_targets" "$templated_list" \
                        "$recreate_existing_pr_num"; then
    SYNC_FAILED=$((SYNC_FAILED + 1))
    return 0
  fi
  SYNC_PR_OPENED=$((SYNC_PR_OPENED + 1))
}

# Run the --sync-all driver: propagate the current HEAD state of every
# canonical + kit manifest path to every consumer, ignoring the
# changed-at-a-commit filter. Mirrors run_sync's structure (author-token
# guard for live mode, per-consumer loop, summary line).
run_sync_all() {
  local dry_run=${1:-0}
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  SYNC_PR_OPENED=0
  SYNC_SKIPPED=0
  SYNC_FAILED=0

  # mergepath HEAD at run time keys the branch name + the PR body.
  local sha
  sha=$(git -C "$MERGEPATH_ROOT" rev-parse --verify "HEAD^{commit}" 2>/dev/null) || {
    err "could not resolve mergepath HEAD"
    exit 2
  }
  local short_sha=${sha:0:7}

  # Author-token guard for LIVE PR-writing mode — identical to
  # run_sync's guard. Without it, a live --sync-all could reach
  # downstream gh writes without proving the author identity that will
  # create PRs / close stale PRs / delete remote branches. Skipped in
  # dry-run and --no-pr, where no gh author writes run.
  if [ "$dry_run" != "1" ] && [ "${SYNC_NO_PR:-0}" != "1" ]; then
    sync_verify_author_token
  fi

  echo "Sync-all: bulk reconcile to mergepath@${short_sha} (verbatim canonical/kit mirror per .mergepath-sync.yml)"
  echo "Branch scheme: $(sync_all_branch_name "$sha")"
  echo

  local consumers
  consumers=$(yq -r '.consumers[] | (.name + "\t" + .repo)' "$manifest")
  while IFS=$'\t' read -r consumer_name consumer_repo; do
    [ -z "$consumer_name" ] && continue
    if ! in_repo_filter "$consumer_name"; then continue; fi
    echo "$consumer_name ($consumer_repo)"
    sync_all_one_consumer "$consumer_name" "$consumer_repo" "$sha" "$dry_run"
    echo
  done <<< "$consumers"

  echo "Summary: PRs opened/planned: $SYNC_PR_OPENED  skipped: $SYNC_SKIPPED  failed: $SYNC_FAILED"
  if [ "$SYNC_FAILED" -gt 0 ]; then return 1; fi
  return 0
}

# Run the sync driver against a single Mergepath commit-ish.
run_sync() {
  local commit_ish=$1
  local dry_run=${2:-0}
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  SYNC_PR_OPENED=0
  SYNC_SKIPPED=0
  SYNC_FAILED=0

  local sha
  sha=$(sync_resolve_commit "$commit_ish") || exit 2
  local short_sha=${sha:0:7}
  local subject
  subject=$(git -C "$MERGEPATH_ROOT" show -s --format=%s "$sha")

  local changed_files
  changed_files=$(sync_changed_files "$sha")

  if [ -z "$changed_files" ]; then
    err "no files changed at mergepath@${short_sha} — nothing to propagate"
    exit 0
  fi

  # Author-token guard for LIVE PR-writing mode (skipped in --dry-run
  # and --no-pr since neither mode performs gh author writes). Refuses
  # to proceed unless scripts/gh-as-author.sh can verify a token for
  # the manifest's author_identity. Without this guard, downstream PRs
  # and destructive recreate writes could fail later, or worse, run
  # without the author/reviewer separation promised by REVIEW_POLICY.md.
  # Override the expected login with MERGEPATH_SYNC_ACTOR_OVERRIDE for
  # tests only. cursor's CHANGES_REQUESTED on PR #217 caught the missing
  # live guard; #412 migrates it from keyring state to token proof.
  if [ "$dry_run" != "1" ] && [ "${SYNC_NO_PR:-0}" != "1" ]; then
    sync_verify_author_token
  fi

  echo "Sync from mergepath@${short_sha}: ${subject}"
  echo "Changed files at this commit:"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    echo "  $f"
  done <<< "$changed_files"
  echo

  # Per-consumer
  local consumers
  consumers=$(yq -r '.consumers[] | (.name + "\t" + .repo)' "$manifest")
  while IFS=$'\t' read -r consumer_name consumer_repo; do
    [ -z "$consumer_name" ] && continue
    if ! in_repo_filter "$consumer_name"; then continue; fi
    sync_one_consumer "$consumer_name" "$consumer_repo" "$sha" "$subject" \
                      "$changed_files" "$dry_run"
  done <<< "$consumers"

  echo
  echo "Summary: PRs opened/planned: $SYNC_PR_OPENED  skipped: $SYNC_SKIPPED  failed: $SYNC_FAILED"
  if [ "$SYNC_FAILED" -gt 0 ]; then return 1; fi
  return 0
}

# --- arg parsing ------------------------------------------------------------

MODE=""
SYNC_COMMIT_ISH=""
# Independent mode-selection trackers so the post-parse mutex check can
# detect --audit + --sync-all (or --sync-all + a positional commit-ish)
# regardless of arg order — MODE alone would silently let the last
# selector win.
SAW_AUDIT=0
SAW_SYNC_ALL=0
SAW_COMMIT_ISH=0
SYNC_DRY_RUN=0
SYNC_NO_PR=0
SYNC_SKIP_EXISTING=0
SYNC_RECREATE_EXISTING=0
SYNC_VERBOSE=0
FILTER_REPOS=""
FILTER_PATHS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --audit)
      MODE="audit"
      SAW_AUDIT=1
      shift
      ;;
    --sync-all)
      # Bulk steady-state reconcile. Mutually exclusive with --audit
      # and with a positional <commit-ish>; the mutex is enforced at
      # the post-parse validation step below (so the diagnostic can
      # name whichever mode was already set, regardless of arg order).
      MODE="sync-all"
      SAW_SYNC_ALL=1
      shift
      ;;
    --repos)
      [ -z "${2:-}" ] && { err "missing argument for --repos"; usage; exit 2; }
      FILTER_REPOS="$2"
      shift 2
      ;;
    --paths|--files)
      # `--files` is an alias for `--paths` (#199 spec uses --files;
      # the script grew up with --paths and downstream callers may
      # already pin to it). Accept both, normalized into FILTER_PATHS.
      [ -z "${2:-}" ] && { err "missing argument for $1"; usage; exit 2; }
      FILTER_PATHS="$2"
      shift 2
      ;;
    --use-local-tree)
      AUDIT_USE_LOCAL_TREE=1
      shift
      ;;
    --no-clone)
      AUDIT_NO_CLONE=1
      shift
      ;;
    --no-refresh)
      AUDIT_NO_REFRESH=1
      shift
      ;;
    --dry-run)
      SYNC_DRY_RUN=1
      shift
      ;;
    --no-pr)
      # Push branches but skip the `gh pr create` step. Useful for
      # staging the propagation as branches that a human can inspect
      # (or open PRs against manually) before committing to PR
      # creation across N consumers.
      SYNC_NO_PR=1
      shift
      ;;
    --skip-existing)
      # Default-behavior alias: skipping when a PR already exists for
      # the commit oid is the policy encoded in `sync_check_existing_pr`.
      # The flag exists for callers who want to be explicit about the
      # intent (e.g., in a documented re-run script). It must be
      # mutually exclusive with --recreate-existing — CodeRabbit
      # caught the silent-loss-of-mutex on PR #231 round 2 where the
      # flag was a true no-op and `--skip-existing --recreate-existing`
      # silently flipped to recreate. Track the bit and reject the
      # combo at the post-parse validation step below.
      SYNC_SKIP_EXISTING=1
      shift
      ;;
    --recreate-existing)
      # Escape hatch for the rare case a maintainer needs to close +
      # recreate an existing propagation PR (e.g., the branch's commit
      # got force-pushed past, or the original PR body needs an
      # updated synthesized form after a manifest change). The script
      # closes the existing PR with a comment pointing at the new one,
      # then proceeds with the standard flow.
      SYNC_RECREATE_EXISTING=1
      shift
      ;;
    --verbose|-v)
      # Per-file diff output in sync mode. Default is summary lines
      # only. Without --verbose the dry-run plan is one line per
      # affected consumer + a `+ <path>` list; with --verbose, the
      # plan additionally prints the file-by-file diff against the
      # consumer's current HEAD for each affected path.
      SYNC_VERBOSE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "sync-to-downstream.sh $SCRIPT_VERSION (manifest schema v$SUPPORTED_MANIFEST_VERSION)"
      exit 0
      ;;
    --)
      shift; break
      ;;
    -*)
      err "unknown flag: $1"
      usage
      exit 2
      ;;
    *)
      # Positional argument = commit-ish. Sync mode.
      if [ -n "$SYNC_COMMIT_ISH" ]; then
        err "multiple positional commit-ish args not supported (got '$SYNC_COMMIT_ISH' and '$1')"
        exit 2
      fi
      SYNC_COMMIT_ISH="$1"
      SAW_COMMIT_ISH=1
      # Don't clobber MODE when --sync-all / --audit was already set —
      # the post-parse mutex check below catches the conflict and emits
      # a clear diagnostic. Only claim "sync" mode when nothing else did.
      if [ "$SAW_AUDIT" = "0" ] && [ "$SAW_SYNC_ALL" = "0" ]; then
        MODE="sync"
      fi
      shift
      ;;
  esac
done

if [ -z "$MODE" ]; then
  usage
  exit 2
fi

# --sync-all mutex: it is its own mode, mutually exclusive with --audit
# and with a positional <commit-ish>. Reject the combination with a
# clear diagnostic before any I/O. (Checked via the SAW_* trackers
# rather than MODE so arg order can't mask the conflict.)
if [ "$SAW_SYNC_ALL" = "1" ] && [ "$SAW_AUDIT" = "1" ]; then
  err "--sync-all and --audit are mutually exclusive (one reconciles, the other only reports)"
  exit 2
fi
if [ "$SAW_SYNC_ALL" = "1" ] && [ "$SAW_COMMIT_ISH" = "1" ]; then
  err "--sync-all and a positional <commit-ish> are mutually exclusive"
  err "       --sync-all replays the full manifest at HEAD; a <commit-ish> propagates only that commit's changes. Pick one."
  exit 2
fi
# --audit is read-only and takes no commit-ish. A positional arg
# alongside --audit is a mixed-mode invocation: without this guard the
# commit-ish is silently dropped and audit runs anyway. Reject it with
# a usage error rather than doing the wrong thing quietly.
if [ "$SAW_AUDIT" = "1" ] && [ "$SAW_COMMIT_ISH" = "1" ]; then
  err "--audit takes no positional <commit-ish> (audit is a read-only drift scan, not a propagation)"
  err "       Drop the commit-ish for an audit, or drop --audit to propagate that commit."
  exit 2
fi

# Validate flag combinations before doing any I/O.
if [ "$SYNC_NO_PR" = "1" ] && [ "$SYNC_RECREATE_EXISTING" = "1" ]; then
  err "--no-pr is incompatible with --recreate-existing (one stops at push, the other closes-and-recreates a PR)"
  exit 2
fi
if [ "$SYNC_SKIP_EXISTING" = "1" ] && [ "$SYNC_RECREATE_EXISTING" = "1" ]; then
  # The CLI contract documents these as mutually exclusive (the --help
  # text reads "--skip-existing|--recreate-existing"). Before this
  # check landed, --skip-existing was parsed as a true no-op, so the
  # combo silently fell through as recreate — confusing and potentially
  # destructive. Reject explicitly. (CodeRabbit #231 round 2.)
  err "--skip-existing is incompatible with --recreate-existing (mutually exclusive policies for an in-flight PR on this oid)"
  exit 2
fi
if [ "$SYNC_SKIP_EXISTING" = "1" ] && [ "$MODE" = "audit" ]; then
  err "--skip-existing is a sync-mode-only flag; remove it from --audit invocations"
  exit 2
fi
if [ "$SYNC_NO_PR" = "1" ] && [ "$MODE" = "audit" ]; then
  err "--no-pr is a sync-mode-only flag; remove it from --audit invocations"
  exit 2
fi
if [ "$SYNC_RECREATE_EXISTING" = "1" ] && [ "$MODE" = "audit" ]; then
  err "--recreate-existing is a sync-mode-only flag; remove it from --audit invocations"
  exit 2
fi
if [ "${AUDIT_USE_LOCAL_TREE:-0}" = "1" ] && [ "$MODE" != "audit" ]; then
  err "--use-local-tree is an audit-mode-only flag; remove it from sync invocations"
  exit 2
fi
if [ "$SYNC_VERBOSE" = "1" ] && [ "$MODE" = "audit" ]; then
  err "--verbose is currently sync-mode-only (audit output is always per-consumer summary); remove it from --audit invocations"
  exit 2
fi
# Export the sync-mode flags so the helper functions see them via the
# environment under `set -u`. (They're already set as bash variables
# above, but several helpers reference them with `${VAR:-0}` for
# defensive defaulting — make sure they exist.)
export SYNC_NO_PR SYNC_SKIP_EXISTING SYNC_RECREATE_EXISTING SYNC_VERBOSE

require_yq
require_manifest

case "$MODE" in
  audit)
    run_audit
    if [ "${AUDIT_FETCH_ERROR:-0}" = "1" ]; then
      exit 3
    elif [ "${AUDIT_DRIFT_FOUND:-0}" = "1" ]; then
      exit 1
    else
      exit 0
    fi
    ;;
  sync)
    if ! run_sync "$SYNC_COMMIT_ISH" "$SYNC_DRY_RUN"; then
      exit 1
    fi
    exit 0
    ;;
  sync-all)
    if ! run_sync_all "$SYNC_DRY_RUN"; then
      exit 1
    fi
    exit 0
    ;;
  *)
    err "internal error: unknown MODE=$MODE"
    exit 2
    ;;
esac
