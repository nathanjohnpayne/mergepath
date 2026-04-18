#!/usr/bin/env bash
set -euo pipefail

# Canonical deploy wrapper for projects that use op-firebase-deploy.
#
# Enforces two guards before calling the deploy chain:
#   1. Current branch is `main`.
#   2. Local `main` is not behind `origin/main`.
#
# These two guards together prevent the stale-worktree class of deploy
# (documented in https://github.com/nathanjohnpayne/mergepath/issues/77):
# an agent working in a feature branch or stale worktree accidentally
# deploying a dist/ output that reflects an older state of main.
#
# After the guards pass, the script:
#   - Builds (default: `npm run build`; configurable via $BUILD_CMD).
#   - Deploys (`op-firebase-deploy`; any arguments after `--` are passed
#     through, e.g. `--only hosting`).
#   - Purges Cloudflare cache (if CF_API_TOKEN + CF_ZONE_ID are set).
#
# Usage:
#   scripts/deploy.sh                       # full deploy from main
#   scripts/deploy.sh -- --only hosting     # scope the op-firebase-deploy call
#   scripts/deploy.sh --force               # bypass branch + freshness guards
#   scripts/deploy.sh --skip-build          # assume dist/ is already built
#   scripts/deploy.sh --skip-cf-purge       # skip the Cloudflare purge step
#
# Environment:
#   BUILD_CMD     Build command (default: "npm run build").
#   CF_API_TOKEN  Cloudflare API token with Purge Cache permission.
#                 Typical source: 1Password (op read ...).
#   CF_ZONE_ID    Cloudflare zone ID for the project domain.
#
# See DEPLOYMENT.md § Deploy flow for full documentation.

FORCE=false
BUILD_SKIP=false
CF_PURGE_SKIP=false
DEPLOY_ARGS=()

usage() {
  sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
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

# Guard 2: must not be behind origin/main
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

if git rev-parse --verify --quiet origin/main >/dev/null; then
  BEHIND="$(git rev-list --count HEAD..origin/main)"
  if [[ "$BEHIND" -gt 0 ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "⚠️  --force: deploying despite $BEHIND commit(s) behind origin/main" >&2
    else
      cat >&2 <<EOF
Refusing to deploy: local HEAD is $BEHIND commit(s) behind origin/main.

Run: git pull --ff-only && scripts/deploy.sh

To override (break-glass only): scripts/deploy.sh --force
EOF
      exit 1
    fi
  fi
fi

# Step 1: Build
if [[ "$BUILD_SKIP" == "true" ]]; then
  echo ">> Skipping build (--skip-build)"
else
  BUILD_CMD="${BUILD_CMD:-npm run build}"
  echo ">> Building: $BUILD_CMD"
  # Use `bash -c --` so BUILD_CMD is parsed as a shell command string
  # in a controlled subshell rather than `eval`'d in the current
  # shell. Cheap defense against environment injection from whatever
  # source populated BUILD_CMD.
  bash -c -- "$BUILD_CMD"
fi

# Step 2: Deploy
echo ">> Deploying via op-firebase-deploy"
op-firebase-deploy "${DEPLOY_ARGS[@]}"

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
