#!/usr/bin/env bash
# scripts/bootstrap-new-repo.sh — wizard for spinning up a new repo
# from the Mergepath template. See #156 for the parent design.
#
# This is the scaffold from #156 sub-A: argument parsing, interactive
# prompts, preflight checks, and the dispatch shape. Each subsequent
# sub-issue (#156 B/C/D/E) plugs into a stage function under
# scripts/bootstrap/ — see scripts/bootstrap/_lib.sh for the helper
# contract.
#
# Usage:
#   scripts/bootstrap-new-repo.sh <new-repo-name> [options]
#
# Options:
#   --description "..."          New repo's short description (skips prompt).
#   --visibility public|private  New repo visibility (skips prompt).
#   --firebase dev|dev+prod|none Firebase scope (skips prompt + skips
#                                Phase D firebase when "none").
#   --reviewers c1,c2,...        Reviewer identities (default: claude,cursor,codex).
#                                Each entry is the agent name; the wizard
#                                resolves to nathanpayne-<agent>.
#   --codex-app y|n              Whether to display Codex App install URL.
#                                Default: prompt.
#   --project new|<N>            Project v2 board target. "new" creates a
#                                fresh board; <N> attaches to existing
#                                project number N. Default: prompt
#                                (defaulting to "new").
#   --skip-firebase              Same as --firebase=none. Doc-only repos.
#   --skip-board                 Skip Project v2 board creation entirely.
#   --dry-run                    Print what would happen; zero side
#                                effects on disk or via gh/git/op.
#   --resume [<stage>]           Resume a partially-completed run. With
#                                an explicit stage, skip up to and
#                                including <stage>. Without, read the
#                                last completed stage from
#                                $TARGET_DIR/.bootstrap-state.
#   --target-dir <path>          Override the new repo's local working
#                                tree path. Default: $HOME/GitHub/<name>.
#   --help, -h                   Show this help.
#   --version                    Print version info.
#
# Exit codes:
#   0  All in-scope stages completed (or all skipped per --resume).
#   1  Bad arguments / unknown flag / required arg missing.
#   2  Preflight failed (missing dependency, dirty target dir,
#      existing remote, etc.).
#   3  Mid-run stage failure; resumable from the last completed
#      stage. The state file at $TARGET_DIR/.bootstrap-state records
#      progress.
#   4  User aborted at a confirmation prompt.
#
# Environment:
#   BOOTSTRAP_REPO_OWNER  GitHub owner for new repos. Default:
#                         "nathanjohnpayne" (the canonical author
#                         identity in this template).
#   BOOTSTRAP_LIB_DIR     Override the per-stage module directory.
#                         Default: $(dirname $0)/bootstrap.
#
# Design notes:
#   - Side-effects are gated through bootstrap::run (defined in
#     scripts/bootstrap/_lib.sh). Stages that bypass that wrapper
#     break dry-run correctness.
#   - The state file is append-only; --resume reads the last line.
#     This keeps the resume semantics simple (last-wins) and
#     auditable (the file is the full stage-completion log).
#   - Preflight runs BEFORE prompts; we don't want to ask the human
#     six questions and then fail on a missing `gh`.

set -euo pipefail

# --- constants --------------------------------------------------------------

SCRIPT_VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_LIB_DIR="${BOOTSTRAP_LIB_DIR:-$SCRIPT_DIR/bootstrap}"
BOOTSTRAP_REPO_OWNER="${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}"

# --- collected inputs --------------------------------------------------------
#
# Individual variables instead of an associative array because bash 3.2
# (macOS default) lacks `declare -A`. Each input has a parallel
# BOOTSTRAP_FROM_FLAG_<name> sentinel — "1" iff the input came from a
# flag (skip the prompt), empty otherwise. The wizard's per-stage
# functions read these via the BOOTSTRAP_INPUT_<name> shape exported
# below; see bootstrap_input() for the read accessor.

# Initial defaults — honor any env-var-set value (`${VAR:-}` keeps an
# inherited value, otherwise empty). The wizard's prompt block fills
# in defaults for empty entries.
BOOTSTRAP_INPUT_REPO_NAME="${BOOTSTRAP_INPUT_REPO_NAME:-}"
BOOTSTRAP_INPUT_DESCRIPTION="${BOOTSTRAP_INPUT_DESCRIPTION:-}"
BOOTSTRAP_INPUT_VISIBILITY="${BOOTSTRAP_INPUT_VISIBILITY:-}"
BOOTSTRAP_INPUT_FIREBASE="${BOOTSTRAP_INPUT_FIREBASE:-}"
BOOTSTRAP_INPUT_REVIEWERS="${BOOTSTRAP_INPUT_REVIEWERS:-claude,cursor,codex}"
BOOTSTRAP_INPUT_CODEX_APP="${BOOTSTRAP_INPUT_CODEX_APP:-}"
BOOTSTRAP_INPUT_PROJECT="${BOOTSTRAP_INPUT_PROJECT:-}"

# FROM_FLAG sentinels — "1" iff the input was supplied by a flag OR
# by a pre-set BOOTSTRAP_INPUT_<name> env var. Either path suppresses
# the matching interactive prompt in prompt_for_inputs(). Without the
# env-pre-seeded branch, `BOOTSTRAP_INPUT_PROJECT=7 bootstrap...` would
# still prompt for project and overwrite the env value (codex P2 on
# #246). REVIEWERS has a non-empty default ("claude,cursor,codex") and
# no prompt block, so it doesn't need a sentinel.
BOOTSTRAP_FROM_FLAG_DESCRIPTION="${BOOTSTRAP_INPUT_DESCRIPTION:+1}"
BOOTSTRAP_FROM_FLAG_VISIBILITY="${BOOTSTRAP_INPUT_VISIBILITY:+1}"
BOOTSTRAP_FROM_FLAG_FIREBASE="${BOOTSTRAP_INPUT_FIREBASE:+1}"
BOOTSTRAP_FROM_FLAG_REVIEWERS=""
BOOTSTRAP_FROM_FLAG_CODEX_APP="${BOOTSTRAP_INPUT_CODEX_APP:+1}"
BOOTSTRAP_FROM_FLAG_PROJECT="${BOOTSTRAP_INPUT_PROJECT:+1}"

BOOTSTRAP_DRY_RUN=0
BOOTSTRAP_SKIP_FIREBASE=0
BOOTSTRAP_SKIP_BOARD=0
BOOTSTRAP_RESUME_STAGE=""
BOOTSTRAP_RESUME_REQUESTED=0
BOOTSTRAP_TARGET_DIR_OVERRIDE=""

# Read accessor used by stage modules. Stages reference inputs by
# logical name (e.g., `bootstrap_input repo_name`) rather than
# touching the variable names directly. Keeps the surface for sub-B
# through sub-E stable even if the storage shape changes later
# (e.g., if we move to bash 4+ and re-introduce associative arrays).
bootstrap_input() {
  local name=$1
  case "$name" in
    repo_name)   echo "$BOOTSTRAP_INPUT_REPO_NAME" ;;
    description) echo "$BOOTSTRAP_INPUT_DESCRIPTION" ;;
    visibility)  echo "$BOOTSTRAP_INPUT_VISIBILITY" ;;
    firebase)    echo "$BOOTSTRAP_INPUT_FIREBASE" ;;
    reviewers)   echo "$BOOTSTRAP_INPUT_REVIEWERS" ;;
    codex_app)   echo "$BOOTSTRAP_INPUT_CODEX_APP" ;;
    project)     echo "$BOOTSTRAP_INPUT_PROJECT" ;;
    *)
      echo "[bootstrap-wizard] ERROR: unknown input name '$name' (allowed: repo_name, description, visibility, firebase, reviewers, codex_app, project)" >&2
      return 1
      ;;
  esac
}
export -f bootstrap_input

# --- helpers (logging only — bootstrap::run + state come from _lib.sh) ------

usage() {
  sed -n '
    /^# Usage:/,/^$/{
      /^# */{
        s/^# *//
        p
      }
    }
  ' "${BASH_SOURCE[0]}"
}

bootstrap::wizard_log() { echo "[bootstrap-wizard] $*"; }
bootstrap::wizard_err() { echo "[bootstrap-wizard] ERROR: $*" >&2; }

# --- argument parsing -------------------------------------------------------

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

# First positional = new repo name. Everything else is flags.
while [ $# -gt 0 ]; do
  case "$1" in
    --description)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --description"; exit 1; }
      BOOTSTRAP_INPUT_DESCRIPTION="$2"
      BOOTSTRAP_FROM_FLAG_DESCRIPTION=1
      shift 2
      ;;
    --visibility)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --visibility"; exit 1; }
      case "$2" in
        public|private) ;;
        *) bootstrap::wizard_err "--visibility must be 'public' or 'private' (got '$2')"; exit 1 ;;
      esac
      BOOTSTRAP_INPUT_VISIBILITY="$2"
      BOOTSTRAP_FROM_FLAG_VISIBILITY=1
      shift 2
      ;;
    --firebase)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --firebase"; exit 1; }
      case "$2" in
        dev|dev+prod|none) ;;
        *) bootstrap::wizard_err "--firebase must be 'dev', 'dev+prod', or 'none' (got '$2')"; exit 1 ;;
      esac
      BOOTSTRAP_INPUT_FIREBASE="$2"
      BOOTSTRAP_FROM_FLAG_FIREBASE=1
      shift 2
      ;;
    --reviewers)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --reviewers"; exit 1; }
      BOOTSTRAP_INPUT_REVIEWERS="$2"
      BOOTSTRAP_FROM_FLAG_REVIEWERS=1
      shift 2
      ;;
    --codex-app)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --codex-app"; exit 1; }
      case "$2" in
        y|n) ;;
        *) bootstrap::wizard_err "--codex-app must be 'y' or 'n' (got '$2')"; exit 1 ;;
      esac
      BOOTSTRAP_INPUT_CODEX_APP="$2"
      BOOTSTRAP_FROM_FLAG_CODEX_APP=1
      shift 2
      ;;
    --project)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --project"; exit 1; }
      # Validate as either the literal "new" or a non-empty
      # digits-only string. The naive case-glob `new|[0-9]*` accepts
      # values like `12abc` because `*` matches any chars; Codex
      # P2 caught this on PR #232. The two-step case below uses an
      # explicit reject pattern (`*[!0-9]*`) so non-digit suffixes
      # are flagged.
      case "$2" in
        new) ;;
        '') bootstrap::wizard_err "--project value cannot be empty"; exit 1 ;;
        *[!0-9]*)
          bootstrap::wizard_err "--project must be 'new' or a non-negative integer (got '$2')"; exit 1
          ;;
        *) ;;  # digits-only — accept
      esac
      BOOTSTRAP_INPUT_PROJECT="$2"
      BOOTSTRAP_FROM_FLAG_PROJECT=1
      shift 2
      ;;
    --skip-firebase)
      BOOTSTRAP_SKIP_FIREBASE=1
      BOOTSTRAP_INPUT_FIREBASE="none"
      BOOTSTRAP_FROM_FLAG_FIREBASE=1
      shift
      ;;
    --skip-board)
      BOOTSTRAP_SKIP_BOARD=1
      BOOTSTRAP_FROM_FLAG_PROJECT=1
      shift
      ;;
    --dry-run)
      BOOTSTRAP_DRY_RUN=1
      shift
      ;;
    --resume)
      BOOTSTRAP_RESUME_REQUESTED=1
      # The arg is optional. If the next token isn't a flag, take it
      # as the stage name.
      if [ $# -gt 1 ] && [[ "${2:-}" != --* ]]; then
        BOOTSTRAP_RESUME_STAGE="$2"
        shift 2
      else
        shift
      fi
      ;;
    --target-dir)
      [ -z "${2:-}" ] && { bootstrap::wizard_err "missing argument for --target-dir"; exit 1; }
      BOOTSTRAP_TARGET_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "bootstrap-new-repo.sh $SCRIPT_VERSION"
      exit 0
      ;;
    -*)
      bootstrap::wizard_err "unknown flag: $1"
      usage
      exit 1
      ;;
    *)
      if [ -n "${BOOTSTRAP_INPUT_REPO_NAME}" ]; then
        bootstrap::wizard_err "multiple positional args; expected exactly one repo-name (got '${BOOTSTRAP_INPUT_REPO_NAME}' and '$1')"
        exit 1
      fi
      BOOTSTRAP_INPUT_REPO_NAME="$1"
      shift
      ;;
  esac
done

if [ -z "${BOOTSTRAP_INPUT_REPO_NAME}" ]; then
  bootstrap::wizard_err "missing required positional argument: <new-repo-name>"
  usage
  exit 1
fi

# --- derived paths ----------------------------------------------------------

if [ -n "$BOOTSTRAP_TARGET_DIR_OVERRIDE" ]; then
  TARGET_DIR="$BOOTSTRAP_TARGET_DIR_OVERRIDE"
else
  TARGET_DIR="${HOME}/GitHub/${BOOTSTRAP_INPUT_REPO_NAME}"
fi
BOOTSTRAP_LOG_FILE="$TARGET_DIR/.bootstrap-log"
BOOTSTRAP_STATE_FILE="$TARGET_DIR/.bootstrap-state"

# Source root for the template-mirror stage. The wizard always lives
# at <mergepath-root>/scripts/bootstrap-new-repo.sh, so two `dirname`s
# from $SCRIPT_DIR is the mergepath root. Tests can override via
# BOOTSTRAP_MERGEPATH_ROOT to point at a synthetic fixture.
BOOTSTRAP_MERGEPATH_ROOT="${BOOTSTRAP_MERGEPATH_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

export BOOTSTRAP_DRY_RUN BOOTSTRAP_LOG_FILE BOOTSTRAP_STATE_FILE \
       TARGET_DIR BOOTSTRAP_MERGEPATH_ROOT BOOTSTRAP_LIB_DIR \
       BOOTSTRAP_REPO_OWNER BOOTSTRAP_SKIP_BOARD \
       BOOTSTRAP_INPUT_REPO_NAME BOOTSTRAP_INPUT_DESCRIPTION \
       BOOTSTRAP_INPUT_VISIBILITY BOOTSTRAP_INPUT_FIREBASE \
       BOOTSTRAP_INPUT_REVIEWERS BOOTSTRAP_INPUT_CODEX_APP \
       BOOTSTRAP_INPUT_PROJECT

# --- source the helper lib + stage modules ---------------------------------

if [ ! -d "$BOOTSTRAP_LIB_DIR" ]; then
  bootstrap::wizard_err "bootstrap library dir not found: $BOOTSTRAP_LIB_DIR"
  exit 2
fi

# shellcheck source=scripts/bootstrap/_lib.sh
. "$BOOTSTRAP_LIB_DIR/_lib.sh"
# shellcheck source=scripts/bootstrap/template-mirror.sh
. "$BOOTSTRAP_LIB_DIR/template-mirror.sh"
# shellcheck source=scripts/bootstrap/github-infra.sh
. "$BOOTSTRAP_LIB_DIR/github-infra.sh"
# shellcheck source=scripts/bootstrap/firebase-and-codereview.sh
. "$BOOTSTRAP_LIB_DIR/firebase-and-codereview.sh"
# shellcheck source=scripts/bootstrap/board-and-summary.sh
. "$BOOTSTRAP_LIB_DIR/board-and-summary.sh"

# --- preflight --------------------------------------------------------------

preflight() {
  local violations=0
  local v

  # 1. Required CLI tools on PATH. Tests may set BOOTSTRAP_SKIP_TOOL_CHECK=1
  #    to bypass this (e.g., a CI runner that doesn't have firebase /
  #    gcloud installed but is still exercising the wizard's flag parser).
  #
  #    `yq` is required by stage B's `bootstrap::_clean_repo_template_yml`
  #    (drops mergepath-specific .repo-template.yml entries before
  #    substitution renames the keys to e.g. `<new-repo>_playground` — see
  #    Codex round 3 P1 on #233).
  #
  #    Note: the bootstrap mirror EXCLUDES the project-doc orchestrator
  #    surface (`.mergepath-project-docs.yml` and generated `docs/projects/`
  #    mirrors) so it never leaks into a new repo — `path_hint: .` and the
  #    generated mirrors misfire in a copied context (see template-mirror.sh
  #    BOOTSTRAP_MIRROR_EXCLUDES).
  #    Treating a missing yq as a soft warning inside the stage was
  #    unsafe: the stage would return 0 + record completion and ship
  #    a target with stale playground metadata.
  #
  #    `rsync` is required by stage B's `_rsync_template`. Preinstalled
  #    on macOS and most Linux distros, but we gate explicitly so a
  #    minimal CI image fails preflight instead of failing mid-stage.
  if [ "${BOOTSTRAP_SKIP_TOOL_CHECK:-0}" != "1" ]; then
    for tool in gh op git yq rsync; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        bootstrap::wizard_err "missing required dependency: $tool"
        violations=$((violations + 1))
      fi
    done
    # mikefarah/yq vs. kislyuk/yq mismatch detection. The latter is a
    # Python wrapper around jq with a completely different syntax;
    # accepting it here would surface as a cryptic parse error
    # downstream. Mirror the check sync-to-downstream.sh runs.
    if command -v yq >/dev/null 2>&1 \
         && ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
      bootstrap::wizard_err "detected non-mikefarah yq (yq --version: $(yq --version 2>&1 | head -1)); the bootstrap wizard requires the Go binary from brew install yq"
      violations=$((violations + 1))
    fi
    # Firebase / gcloud check is deferred to preflight_firebase_deps()
    # which runs AFTER prompts populate BOOTSTRAP_INPUT_FIREBASE. Codex
    # P1 on PR #232 round 1 caught the gap: when the user hasn't
    # explicitly set --firebase, the input is empty until prompts run;
    # gating the dep check on `!= "none"` here would reject valid
    # interactive runs whose intended (defaulted) scope is none.
  fi

  # 2. op-preflight.sh session cache. Soft-warn rather than hard-fail —
  #    not every flow needs preflight (dry-run smoke tests, for
  #    instance). The Firebase / GitHub side-effects will surface
  #    a credential error themselves if preflight wasn't run.
  if [ "${OP_PREFLIGHT_DONE:-0}" != "1" ] && [ "$BOOTSTRAP_DRY_RUN" != "1" ]; then
    bootstrap::warn "OP_PREFLIGHT_DONE not set — credential preflight may need to run before any gh/op side-effects"
  fi

  # 3. GitHub author writes are token-verified by the stage helpers.
  #    There is no machine-global gh account check here; stages B/C/E
  #    route live gh writes through scripts/gh-as-author.sh.
  if [ "${BOOTSTRAP_SKIP_TOOL_CHECK:-0}" != "1" ] && ! command -v gh >/dev/null 2>&1; then
    bootstrap::wizard_err "missing GitHub CLI: gh"
    violations=$((violations + 1))
  fi

  # 4. Target dir is empty (or absent). Refuse to overwrite a populated
  #    dir — the wizard is meant for new repos, not for re-bootstrapping
  #    an existing tree.
  if [ -d "$TARGET_DIR" ]; then
    # Allow the dir if it's empty OR contains only resume bookkeeping
    # (.bootstrap-state, .bootstrap-log).
    local extra
    extra=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 \
              ! -name '.bootstrap-state' \
              ! -name '.bootstrap-log' 2>/dev/null | head -1)
    if [ -n "$extra" ]; then
      bootstrap::wizard_err "target dir $TARGET_DIR is not empty (contains: $extra ...). Refusing to overwrite."
      violations=$((violations + 1))
    fi
  fi

  # 5. No existing remote with the same owner/name. Skip the network
  #    probe in dry-run mode + when tool check is suppressed.
  if [ "$BOOTSTRAP_DRY_RUN" != "1" ] && [ "${BOOTSTRAP_SKIP_TOOL_CHECK:-0}" != "1" ] && command -v gh >/dev/null 2>&1; then
    local full_name="$BOOTSTRAP_REPO_OWNER/${BOOTSTRAP_INPUT_REPO_NAME}"
    # Use GH_TOKEN explicitly for this read-path probe. Prefer the
    # author PAT, then reviewer PAT, and finally gh's configured
    # credential for local developer runs without preflight.
    local _gh_repo_view_rc=0
    GH_TOKEN="${OP_PREFLIGHT_AUTHOR_PAT:-${OP_PREFLIGHT_REVIEWER_PAT:-${GH_TOKEN:-}}}" \
      gh repo view "$full_name" >/dev/null 2>&1 || _gh_repo_view_rc=$?
    if [ "$_gh_repo_view_rc" -eq 0 ]; then
      bootstrap::wizard_err "remote already exists: $full_name. Refusing to bootstrap over an existing repo."
      violations=$((violations + 1))
    fi
  fi

  # 6. Mergepath itself is on main and clean. The cross-repo loop
  #    update in stage B writes to mergepath; doing that against a
  #    dirty / non-main worktree risks committing unrelated changes.
  #    Skip in dry-run.
  if [ "$BOOTSTRAP_DRY_RUN" != "1" ] && [ "${BOOTSTRAP_SKIP_MERGEPATH_GUARD:-0}" != "1" ]; then
    local mp_root
    mp_root=$(cd "$SCRIPT_DIR/.." && pwd)
    local mp_branch
    mp_branch=$(git -C "$mp_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$mp_branch" != "main" ]; then
      bootstrap::wizard_err "mergepath worktree at $mp_root is on branch '$mp_branch', not 'main'. Switch to main before bootstrapping."
      violations=$((violations + 1))
    fi
    if [ -n "$(git -C "$mp_root" status --porcelain 2>/dev/null)" ]; then
      bootstrap::wizard_err "mergepath worktree at $mp_root has uncommitted changes. Stash or commit before bootstrapping."
      violations=$((violations + 1))
    fi
  fi

  if [ "$violations" -gt 0 ]; then
    bootstrap::wizard_err "preflight failed ($violations violation(s)). Aborting."
    return 2
  fi
  return 0
}

# Firebase-specific dependency check. Runs AFTER prompts populate
# BOOTSTRAP_INPUT_FIREBASE so an interactive run that defaults
# firebase=none doesn't trip on missing firebase/gcloud. Codex P1
# on PR #232 round 1.
preflight_firebase_deps() {
  if [ "${BOOTSTRAP_SKIP_TOOL_CHECK:-0}" = "1" ]; then
    return 0
  fi
  if [ "$BOOTSTRAP_SKIP_FIREBASE" = "1" ]; then
    return 0
  fi
  if [ "$BOOTSTRAP_INPUT_FIREBASE" = "none" ] || [ -z "$BOOTSTRAP_INPUT_FIREBASE" ]; then
    return 0
  fi
  local violations=0
  for tool in firebase gcloud; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      bootstrap::wizard_err "missing Firebase dependency: $tool (skip with --skip-firebase if not deploying)"
      violations=$((violations + 1))
    fi
  done
  if [ "$violations" -gt 0 ]; then
    bootstrap::wizard_err "Firebase dependency check failed ($violations missing). Aborting."
    return 2
  fi
  return 0
}

# --- prompt block -----------------------------------------------------------

prompt_for_inputs() {
  # Each prompt is skipped if the corresponding --flag was passed.
  # Defaults match the issue spec.

  if [ -z "${BOOTSTRAP_FROM_FLAG_DESCRIPTION:-}" ]; then
    read -r -p "[bootstrap-wizard] Short description (one line): " v
    BOOTSTRAP_INPUT_DESCRIPTION="$v"
  fi

  if [ -z "${BOOTSTRAP_FROM_FLAG_VISIBILITY:-}" ]; then
    local v="private"
    read -r -p "[bootstrap-wizard] Visibility [public/private] (default: private): " input
    case "${input:-}" in
      public) v="public" ;;
      private|"") v="private" ;;
      *) bootstrap::wizard_err "invalid visibility '$input'; defaulting to private" ;;
    esac
    BOOTSTRAP_INPUT_VISIBILITY="$v"
  fi

  if [ -z "${BOOTSTRAP_FROM_FLAG_FIREBASE:-}" ]; then
    local v="none"
    read -r -p "[bootstrap-wizard] Firebase scope [dev/dev+prod/none] (default: none): " input
    case "${input:-}" in
      dev|dev+prod|none) v="$input" ;;
      "") v="none" ;;
      *) bootstrap::wizard_err "invalid firebase scope '$input'; defaulting to none" ;;
    esac
    BOOTSTRAP_INPUT_FIREBASE="$v"
  fi

  if [ -z "${BOOTSTRAP_FROM_FLAG_CODEX_APP:-}" ]; then
    local v="n"
    read -r -p "[bootstrap-wizard] Display Codex App install URL? [y/N]: " input
    case "${input:-}" in
      y|Y|yes) v="y" ;;
      *) v="n" ;;
    esac
    BOOTSTRAP_INPUT_CODEX_APP="$v"
  fi

  if [ -z "${BOOTSTRAP_FROM_FLAG_PROJECT:-}" ]; then
    local v="new"
    read -r -p "[bootstrap-wizard] Project v2 board [new/<N>] (default: new): " input
    # Mirror the strict --project flag validation (round-1 fix at the
     # arg-parser): `[0-9]*` would accept "12abc", which then breaks
     # later when the wizard tries `gh project ... --number 12abc`.
     # Reject anything containing a non-digit, accept empty/new + all-
     # digits. CodeRabbit caught this as a same-bug-different-path
     # finding on the interactive prompt after round 1.
    case "${input:-}" in
      new|"") v="new" ;;
      *[!0-9]*)
        bootstrap::wizard_err "invalid project value '$input'; expected 'new' or a non-negative integer"
        exit 1
        ;;
      *) v="$input" ;;  # digits-only
    esac
    BOOTSTRAP_INPUT_PROJECT="$v"
  fi

  # Defaults for inputs that have no prompt (reviewers comes from the
  # flag default; nothing to ask interactively).
  : "${BOOTSTRAP_INPUT_REVIEWERS:=claude,cursor,codex}"
}

# Print the collected inputs + confirm. Skipped in dry-run mode and
# when BOOTSTRAP_AUTO_CONFIRM=1 (tests).
confirm_inputs() {
  bootstrap::wizard_log "----- collected inputs -----"
  bootstrap::wizard_log "repo_name:    ${BOOTSTRAP_INPUT_REPO_NAME}"
  bootstrap::wizard_log "description:  ${BOOTSTRAP_INPUT_DESCRIPTION}"
  bootstrap::wizard_log "visibility:   ${BOOTSTRAP_INPUT_VISIBILITY}"
  bootstrap::wizard_log "firebase:     ${BOOTSTRAP_INPUT_FIREBASE}"
  bootstrap::wizard_log "reviewers:    ${BOOTSTRAP_INPUT_REVIEWERS}"
  bootstrap::wizard_log "codex_app:    ${BOOTSTRAP_INPUT_CODEX_APP}"
  bootstrap::wizard_log "project:      ${BOOTSTRAP_INPUT_PROJECT}"
  bootstrap::wizard_log "target_dir:   $TARGET_DIR"
  bootstrap::wizard_log "----------------------------"

  if [ "$BOOTSTRAP_DRY_RUN" = "1" ] || [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" = "1" ]; then
    return 0
  fi
  read -r -p "[bootstrap-wizard] Proceed? [y/N]: " input
  case "${input:-}" in
    y|Y|yes) return 0 ;;
    *) bootstrap::wizard_err "user aborted at confirmation"; return 4 ;;
  esac
}

# --- dispatch ---------------------------------------------------------------

# Stages in execution order. The wizard runs them sequentially; on
# failure, records the last-completed stage to BOOTSTRAP_STATE_FILE
# and exits 3 with a "resume with --resume <stage>" message.
STAGES=(
  template-mirror
  github-infra
  firebase-and-codereview
  board-and-summary
)

dispatch() {
  local resume_after=""

  if [ "$BOOTSTRAP_RESUME_REQUESTED" = "1" ]; then
    if [ -n "$BOOTSTRAP_RESUME_STAGE" ]; then
      resume_after="$BOOTSTRAP_RESUME_STAGE"
    else
      resume_after=$(bootstrap::last_completed_stage)
    fi
    if [ -n "$resume_after" ]; then
      # Validate resume_after against the known STAGES list BEFORE
      # entering the dispatch loop. Without this, an unknown stage
      # name (typo on the CLI, or a stale state file from an older
      # wizard version) sets `skipping=1` and never finds a matching
      # stage to flip it back to 0 — every stage is treated as
      # already completed and the wizard exits 0 with no work done
      # (silent false-success). Codex P1 on PR #232 round 1.
      local known=0
      for s in "${STAGES[@]}"; do
        if [ "$s" = "$resume_after" ]; then
          known=1
          break
        fi
      done
      if [ "$known" != "1" ]; then
        bootstrap::wizard_err "unknown resume stage: '$resume_after' (known stages: ${STAGES[*]})"
        bootstrap::wizard_err "If the state file is the source: edit or remove $BOOTSTRAP_STATE_FILE and re-run."
        return 1
      fi
      bootstrap::wizard_log "resume: skipping stages up to and including '$resume_after'"
    fi
  fi

  local skipping=0
  if [ -n "$resume_after" ]; then
    skipping=1
  fi

  for stage in "${STAGES[@]}"; do
    if [ "$skipping" = "1" ]; then
      bootstrap::wizard_log "resume: skip $stage (already completed)"
      if [ "$stage" = "$resume_after" ]; then
        skipping=0
      fi
      continue
    fi

    # Per-flag stage skips. --skip-firebase suppresses stage D's
    # Firebase substeps but the stage function still runs (it
    # handles --skip-firebase / firebase=none internally). --skip-board
    # suppresses stage E's Project v2 board sub-step but the stage
    # function still runs — the final summary block + PRD/spec/plan
    # scaffold writes are too valuable to gate on whether the operator
    # wanted a board. The stage reads BOOTSTRAP_SKIP_BOARD and skips
    # only sub-step 1 internally.

    # General-purpose stage skip via env var. BOOTSTRAP_SKIP_STAGES is
    # a comma-separated list of stage names to skip entirely (no
    # dispatch, no record). Useful for tests that want to scope to a
    # single stage, and for operators who want to mirror the template
    # locally without yet creating remote GitHub infra (e.g., to
    # inspect the result before committing to a name).
    if [ -n "${BOOTSTRAP_SKIP_STAGES:-}" ]; then
      case ",${BOOTSTRAP_SKIP_STAGES},"  in
        *",${stage},"*)
          bootstrap::wizard_log "skip $stage (BOOTSTRAP_SKIP_STAGES)"
          continue
          ;;
      esac
    fi

    # Dispatch to bootstrap::stage_<name with hyphens to underscores>.
    local fn="bootstrap::stage_${stage//-/_}"
    if ! type "$fn" >/dev/null 2>&1; then
      bootstrap::wizard_err "stage function $fn not found (sourced from $BOOTSTRAP_LIB_DIR)"
      return 3
    fi
    # Capture the stage's real exit code BEFORE the branch test. The
    # `! "$fn"` form runs `$fn` and then negates; inside the if-block,
    # `$?` reflects the negation step (always 0), not the function's
    # rc. Use a then/else split so we can record the actual rc with $?.
    local stage_rc=0
    "$fn" || stage_rc=$?
    if [ "$stage_rc" -ne 0 ]; then
      bootstrap::wizard_err "stage '$stage' failed (rc=$stage_rc). Resume with: $0 ${BOOTSTRAP_INPUT_REPO_NAME} --resume $stage"
      return 3
    fi
  done

  return 0
}

# --- main -------------------------------------------------------------------

preflight || exit $?

# Skip prompts under --dry-run when all inputs came from flags; also
# skip when BOOTSTRAP_AUTO_PROMPT=skip (tests). The flag-only path
# means a `--dry-run --visibility private --firebase none ...`
# invocation runs non-interactively, which is what CI smoke tests
# need.
if [ "${BOOTSTRAP_AUTO_PROMPT:-}" != "skip" ]; then
  prompt_for_inputs
fi

# Firebase deps check runs HERE — after prompts populate
# BOOTSTRAP_INPUT_FIREBASE — so the interactive default-to-none path
# doesn't trip on missing firebase/gcloud (Codex P1 on PR #232 round 1).
preflight_firebase_deps || exit $?

confirm_inputs || exit $?

bootstrap::wizard_log "starting bootstrap of ${BOOTSTRAP_INPUT_REPO_NAME} into $TARGET_DIR"
mkdir -p "$TARGET_DIR"

dispatch_rc=0
dispatch || dispatch_rc=$?

if [ "$dispatch_rc" = "0" ]; then
  bootstrap::wizard_log "all stages completed for ${BOOTSTRAP_INPUT_REPO_NAME}"
fi
exit "$dispatch_rc"
