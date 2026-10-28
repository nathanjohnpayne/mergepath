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
#     an unprivileged temporary download whose SHA-256 matches the pin
#     below, then stage beside the destination, atomically replace it,
#     and verify the installed binary runs.
#     The official ubuntu-latest image ships yq 4.x
#     preinstalled today; pinning keeps the checks resilient to runner
#     image changes.
#
# Env overrides (test seams — tests stub sudo/wget via PATH shims and
# redirect the destination so no network or root is touched; production
# uses the defaults):
#   ENSURE_YQ_VERSION  release tag to pin (default: the one below)
#   ENSURE_YQ_SHA256   expected digest (required for a version override)
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

YQ_VERSION="${ENSURE_YQ_VERSION:-v4.53.6}"
YQ_DEST="${ENSURE_YQ_DEST:-/usr/local/bin/yq}"
# The release assets below are Linux builds, and `uname -m` alone cannot tell
# Linux from macOS/BSD (both can report arm64), so refuse any other OS before
# the architecture mapping, any download, or sudo (#2748).
YQ_OS=$(uname -s)
if [ "$YQ_OS" != Linux ]; then
  echo "ensure-yq.sh: unsupported OS: $YQ_OS (only Linux release assets are pinned); refusing install. Install mikefarah/yq v4+ another way (e.g. brew install yq)." >&2
  exit 1
fi
YQ_MACHINE=$(uname -m)
case "$YQ_MACHINE" in
  x86_64)
    YQ_ARCH=amd64
    # Official v4.53.6 release asset digest from its GitHub release metadata:
    # https://github.com/mikefarah/yq/releases/tag/v4.53.6
    YQ_PINNED_SHA256=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385
    ;;
  aarch64|arm64)
    YQ_ARCH=arm64
    # Official v4.53.6 release asset digest from its GitHub release metadata:
    # https://github.com/mikefarah/yq/releases/tag/v4.53.6
    YQ_PINNED_SHA256=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09
    ;;
  *)
    echo "ensure-yq.sh: unsupported Linux architecture: $YQ_MACHINE; refusing install" >&2
    exit 1
    ;;
esac
YQ_ASSET="yq_linux_${YQ_ARCH}"
YQ_SHA256="${ENSURE_YQ_SHA256:-$YQ_PINNED_SHA256}"
if [ "$YQ_VERSION" != v4.53.6 ] && [ -z "${ENSURE_YQ_SHA256:-}" ]; then
  echo "ensure-yq.sh: a version override requires ENSURE_YQ_SHA256" >&2
  exit 1
fi
if [[ ! "$YQ_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ensure-yq.sh: expected SHA-256 must contain 64 lowercase hex digits" >&2
  exit 1
fi

YQ_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ensure-yq.XXXXXX")
YQ_STAGE_DIR=""
trap 'if [ -n "$YQ_STAGE_DIR" ]; then sudo rm -rf "$YQ_STAGE_DIR"; fi; rm -rf "$YQ_TMP_DIR"' EXIT
wget -q -O "$YQ_TMP_DIR/yq" \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_ASSET}"
if command -v sha256sum >/dev/null 2>&1; then
  YQ_ACTUAL_SHA256=$(sha256sum "$YQ_TMP_DIR/yq")
else
  YQ_ACTUAL_SHA256=$(shasum -a 256 "$YQ_TMP_DIR/yq")
fi
if [ "${YQ_ACTUAL_SHA256%% *}" != "$YQ_SHA256" ]; then
  echo "ensure-yq.sh: SHA-256 mismatch for ${YQ_VERSION}/${YQ_ASSET}; refusing install" >&2
  exit 1
fi
# Keep the existing destination intact if staging or replacement fails.
# The private root-owned directory is on the destination filesystem, so
# GNU mv -T replaces exactly that path with one rename, including a
# destination symlink; it never treats the destination as a directory.
YQ_STAGE_DIR=$(sudo mktemp -d "${YQ_DEST}.install.XXXXXX")
sudo install -m 0755 "$YQ_TMP_DIR/yq" "$YQ_STAGE_DIR/yq"
sudo mv -fT "$YQ_STAGE_DIR/yq" "$YQ_DEST"
# Verify the artifact we just installed actually runs (fail closed on a
# truncated/failed download rather than letting a later check hit it).
"$YQ_DEST" --version
