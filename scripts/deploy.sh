#!/usr/bin/env bash
set -euo pipefail

# Canonical deploy wrapper for projects that use op-firebase-deploy.
#
# Enforces three guards before calling the deploy chain:
#   1. Current branch is `main`.
#   2. Local `HEAD` is exactly `origin/main`: neither behind it nor
#      ahead of it (unpushed commits), and `origin/main` was fetched
#      and exists. A failed fetch or a missing `origin/main` refuses.
#   3. The working tree is clean (no modified or staged paths).
#
# These three guards together prevent the stale-worktree class of deploy
# (documented in https://github.com/nathanjohnpayne/mergepath/issues/77):
# an agent working in a feature branch, stale worktree, or with
# uncommitted in-progress edits accidentally deploying a dist/ output
# that does not match what reviewers have seen merged on main.
#
# After the guards pass, the script:
#   - Builds (default: `npm run build`; configurable via $BUILD_CMD).
#     The build command is run under `bash -euo pipefail -c --` so a
#     compound command (e.g. `npm run lint && npm run build`) fails
#     closed if any step errors, rather than masking earlier failures
#     behind the exit code of the final segment.
#   - Deploys (`op-firebase-deploy`; any arguments after `--` are passed
#     through, e.g. `--only hosting`).
#   - Purges Cloudflare cache (if CF_API_TOKEN + CF_ZONE_ID are set).
#
# Usage:
#   scripts/deploy.sh                       # full deploy from main
#   scripts/deploy.sh -- --only hosting     # scope the op-firebase-deploy call
#   scripts/deploy.sh --force               # bypass guards 1 + 2 (not the dirty-tree guard)
#   scripts/deploy.sh --skip-build          # assume dist/ is already built
#   scripts/deploy.sh --skip-cf-purge       # skip the Cloudflare purge step
#
# Environment:
#   BUILD_CMD            Build command (default: "npm run build").
#   CF_API_TOKEN         Cloudflare API token with Purge Cache permission.
#                        Typical source: 1Password (op read ...).
#   CF_ZONE_ID           Cloudflare zone ID for the project domain.
#   DEPLOY_ALLOW_DIRTY   Set to "1" to bypass the clean-working-tree guard.
#                        Break-glass only — never set during routine deploys.
#                        See DEPLOYMENT.md § Deploy guards.
#
# See DEPLOYMENT.md § Deploy flow for full documentation.

FORCE=false
BUILD_SKIP=false
CF_PURGE_SKIP=false
DEPLOY_ARGS=()

usage() {
  sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)         FORCE=true; shift ;;
    --skip-build)    BUILD_SKIP=true; shift ;;
    --skip-cf-purge) CF_PURGE_SKIP=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; DEPLOY_ARGS+=("$@"); break ;;
    *)               DEPLOY_ARGS+=("$1"); shift ;;
  esac
done

# Guard 1: must be on main
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  if [[ "$FORCE" == "true" ]]; then
    echo "⚠️  --force: deploying from '$CURRENT_BRANCH' (not main)" >&2
  else
    cat >&2 <<EOF
Refusing to deploy: current branch is '$CURRENT_BRANCH', not 'main'.

Deploys should ship main's state — the site must match what reviewers
have seen in merged PRs. Worktrees and feature branches are routinely
behind main and will silently ship stale builds (see mergepath#77).

To override (break-glass only): scripts/deploy.sh --force
EOF
    exit 1
  fi
fi

# Guard 2: local HEAD must be exactly origin/main
# Fail closed on fetch failure — stale origin/main metadata would
# silently defeat the freshness check and re-open the exact class
# of failure #77 closes.
if ! git fetch --quiet origin main 2>/dev/null; then
  if [[ "$FORCE" == "true" ]]; then
    echo "⚠️  --force: git fetch failed; skipping freshness verification" >&2
  else
    cat >&2 <<EOF
Refusing to deploy: 'git fetch origin main' failed, so freshness
against origin/main cannot be verified.

Network down? Try again once connectivity is restored.

To override (break-glass only): scripts/deploy.sh --force
EOF
    exit 1
  fi
fi

# A fetch can succeed without creating origin/main (for example, a
# remote whose fetch refspec does not map main to refs/remotes/origin/main).
# That leaves nothing to compare against, so it refuses too rather than
# skipping the check (#2704).
#
# Otherwise HEAD must equal origin/main exactly. Behind ships a stale
# build; ahead ships local commits no reviewer saw merged. Both counts
# are reported so a diverged checkout is visible as such.
if ! git rev-parse --verify --quiet origin/main >/dev/null; then
  if [[ "$FORCE" == "true" ]]; then
    echo "⚠️  --force: origin/main is unavailable after fetch; skipping exact-match verification" >&2
  else
    cat >&2 <<EOF
Refusing to deploy: origin/main is unavailable after fetch, so local
HEAD cannot be verified against the merged main commit.

Check that the 'origin' remote fetches main into origin/main.

To override (break-glass only): scripts/deploy.sh --force
EOF
    exit 1
  fi
else
  LOCAL_HEAD="$(git rev-parse HEAD)"
  ORIGIN_HEAD="$(git rev-parse origin/main)"
  if [[ "$LOCAL_HEAD" != "$ORIGIN_HEAD" ]]; then
    AHEAD="$(git rev-list --count origin/main..HEAD)"
    BEHIND="$(git rev-list --count HEAD..origin/main)"
    if [[ "$FORCE" == "true" ]]; then
      echo "⚠️  --force: deploying although local HEAD differs from origin/main ($AHEAD commit(s) ahead, $BEHIND commit(s) behind)" >&2
    else
      cat >&2 <<EOF
Refusing to deploy: local HEAD does not exactly match origin/main
($AHEAD commit(s) ahead, $BEHIND commit(s) behind).

Deploys must ship the reviewed, merged origin/main commit.
  Behind: git pull --ff-only && scripts/deploy.sh
  Ahead:  local-only commits have not been merged; land them through a
          pull request or drop them, then update main and redeploy.

To override (break-glass only): scripts/deploy.sh --force
EOF
      exit 1
    fi
  fi
fi

# Guard 3: working tree must be clean
#
# `git status --porcelain` prints one line per modified, staged, or
# untracked path and is empty when the worktree matches HEAD with the
# index. Deploying from a dirty tree silently ships whatever the
# in-progress edits compile to — that diverges from the merged-on-main
# state that reviewers signed off on (same failure class as #77).
#
# Break-glass override: DEPLOY_ALLOW_DIRTY=1 (env var, not a flag, so
# `--force` doesn't accidentally subsume this guard — keeping the
# override deliberate and audit-greppable). Logged with a clear ⚠️
# trail when used.
DIRTY="$(git status --porcelain)"
if [[ -n "$DIRTY" ]]; then
  if [[ "${DEPLOY_ALLOW_DIRTY:-0}" == "1" ]]; then
    echo "⚠️  DEPLOY_ALLOW_DIRTY=1: deploying with uncommitted changes:" >&2
    printf '%s\n' "$DIRTY" >&2
  else
    cat >&2 <<EOF
Refusing to deploy: working tree is dirty.

Modified / staged / untracked paths:
$DIRTY

Commit, stash, or revert these before deploying so the deploy reflects
the merged-on-main state that reviewers approved (see mergepath#77 for
the class of failure this guard closes).

To override (break-glass only): DEPLOY_ALLOW_DIRTY=1 scripts/deploy.sh
EOF
    exit 1
  fi
fi

# Step 1: Build
if [[ "$BUILD_SKIP" == "true" ]]; then
  echo ">> Skipping build (--skip-build)"
else
  BUILD_CMD="${BUILD_CMD:-npm run build}"
  echo ">> Building: $BUILD_CMD"
  # Use `bash -euo pipefail -c --` so BUILD_CMD is parsed as a shell
  # command string in a controlled subshell rather than `eval`'d in
  # the current shell (cheap defense against environment injection
  # from whatever source populated BUILD_CMD), AND so compound
  # commands fail closed:
  #   - `set -e`: any failing step aborts the subshell.
  #   - `set -u`: unset variables are an error (catches typos in
  #     BUILD_CMD that would otherwise silently expand to empty).
  #   - `set -o pipefail`: a failing step in a pipeline is preserved,
  #     not masked by the success of the final stage.
  # Without these flags, a BUILD_CMD like `npm run lint && npm run
  # build` would still fail if lint failed (because && short-circuits)
  # — but `npm run lint; npm run build` would mask the lint failure
  # behind the build's exit code, and `npm run build | tee log.txt`
  # would only surface tee's exit code. Strict-bash closes both.
  bash -euo pipefail -c -- "$BUILD_CMD"
fi

# Step 2: Deploy
echo ">> Deploying via op-firebase-deploy"
# Bash 3.2 + `set -u`: expanding an empty `${DEPLOY_ARGS[@]}` aborts
# with "DEPLOY_ARGS[@]: unbound variable" when no trailing deploy
# args were appended (e.g. `deploy.sh --force --skip-build
# --skip-cf-purge` with nothing after `--`). The `${ARR[@]+"${ARR[@]}"}`
# idiom expands to the array contents only when the array has been
# ASSIGNED — DEPLOY_ARGS=() at parse time qualifies as assigned, so
# this expansion is always defined regardless of length. Bash 4+
# tolerates the bare form; Bash 3.2 (still the macOS system shell)
# does not. nathanpayne-codex Phase 4b r3 on PR #296 reproduced
# the abort with `--force --skip-build --skip-cf-purge` under bash 3.2.
op-firebase-deploy ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}

# Step 3: Cloudflare cache purge (optional)
if [[ "$CF_PURGE_SKIP" == "true" ]]; then
  echo ">> Cloudflare cache purge skipped (--skip-cf-purge)"
elif [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ZONE_ID:-}" ]]; then
  echo ">> Cloudflare cache purge skipped (CF_API_TOKEN or CF_ZONE_ID not set)"
else
  echo ">> Purging Cloudflare cache"
  # The Cloudflare purge endpoint returns 200 on success with a JSON body.
  # We only care about HTTP status here.
  purge_http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 \
    --max-time 30 \
    -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data '{"purge_everything":true}')"
  if [[ "$purge_http_code" != "200" ]]; then
    echo "   Cloudflare purge failed: HTTP $purge_http_code" >&2
    exit 1
  fi
  echo "   Cache purged."
fi

echo ">> Deploy complete."
