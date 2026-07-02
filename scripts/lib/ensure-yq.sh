#!/usr/bin/env bash
# scripts/lib/ensure-yq.sh — single-source pinned mikefarah/yq bootstrap.
#
# Extracted from .github/workflows/repo_lint.yml's
# install_yq_for_sync_manifest step (#616, Codex finding 3509734393) so
# the yq-dependent CI checks are self-sufficient regardless of workflow
# sync timing: consumers receive the scripts/ci kit (and this lib) via
# manifest sync in one PR, while repo_lint.yml itself travels separately
# on the template-mirror lane (#601). During that skew window a
# consumer's repo_lint.yml may not order a yq install before
# scripts/ci/check_resolve_pr_threads, whose delegated
# tests/test_resolve_pr_threads_verified_propagation.sh suite (#572)
# hard-fails without yq. check_resolve_pr_threads therefore
# self-bootstraps via this script (CI-only; see --ci-only), and
# repo_lint.yml's install step delegates here so the version pin lives in
# exactly one place.
#
# Behavior:
#   - A mikefarah yq already on PATH → no-op success (idempotent; same
#     short-circuit the workflow step always had).
#   - --ci-only: additionally a no-op success unless GITHUB_ACTIONS is
#     "true". Local runs keep the calling tool's own hard "yq is
#     required" error instead of getting a surprise sudo install.
#   - Otherwise: install the PINNED release to /usr/local/bin/yq via
#     sudo wget (the ubuntu-runner path), then verify the installed
#     binary runs. The official ubuntu-latest image ships yq 4.x
#     preinstalled today; pinning keeps the checks resilient to runner
#     image changes.
#
# Env overrides (test seams — tests stub sudo/wget via PATH shims and
# redirect the destination so no network or root is touched; production
# uses the defaults):
#   ENSURE_YQ_VERSION  release tag to pin (default: the one below)
#   ENSURE_YQ_DEST     install destination (default /usr/local/bin/yq)

set -euo pipefail

CI_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --ci-only) CI_ONLY=true ;;
    *)
      echo "ensure-yq.sh: unknown argument: $arg (supported: --ci-only)" >&2
      exit 1 ;;
  esac
done

if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "yq already present: $(yq --version)"
  exit 0
fi

if $CI_ONLY && [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "ensure-yq.sh: not a CI run (GITHUB_ACTIONS != true) — skipping the pinned sudo install. Install mikefarah/yq v4+ locally (e.g. brew install yq)."
  exit 0
fi

YQ_VERSION="${ENSURE_YQ_VERSION:-v4.44.3}"
YQ_DEST="${ENSURE_YQ_DEST:-/usr/local/bin/yq}"

sudo wget -q -O "$YQ_DEST" \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
sudo chmod +x "$YQ_DEST"
# Verify the artifact we just installed actually runs (fail closed on a
# truncated/failed download rather than letting a later check hit it).
"$YQ_DEST" --version
