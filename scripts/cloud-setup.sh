#!/usr/bin/env bash
# scripts/cloud-setup.sh — provision the tools the guarded write path needs in
# a cloud agent container (#1057 items A and F).
#
# Every guarded GitHub write in this repo goes through `gh` (via
# scripts/gh-as-author.sh / scripts/gh-as-reviewer.sh), and the helpers read
# JSON with `jq`. A Claude Code cloud session has both pre-installed; the Codex
# cloud base image (`codex-universal`) has `jq` but no `gh`, so a Codex task
# could read but never write. This script closes that gap and does nothing
# where the tools already exist, so it is safe as the setup script of either
# environment (docs/agents/cloud-environments.md).
#
# `gh` is installed from the official cli/cli GitHub release at a pinned
# version, and the tarball must match a SHA-256 pinned IN THIS SCRIPT before
# anything is extracted. The expected hash never comes from the same place as
# the download: a checksums file fetched from the release would prove only
# that the two downloads agree. The pins below were taken from the release's
# checksums file and cross-checked against the GitHub API's asset digests.
# Overriding the version requires supplying its hash too. Nothing is installed
# from a mutable URL, and nothing runs with a failed or missing checksum.
#
# Usage:
#   bash scripts/cloud-setup.sh [--dry-run]
#
# Environment:
#   MERGEPATH_GH_VERSION   gh release to install when gh is absent
#                          (default below). An already-installed gh is kept,
#                          whatever its version.
#   MERGEPATH_GH_SHA256    the tarball's SHA-256; required when
#                          MERGEPATH_GH_VERSION names a version not pinned here.
#   MERGEPATH_TOOL_PREFIX  install prefix; the binary goes to <prefix>/bin
#                          (default /usr/local when writable, else ~/.local)
#
# Exit codes:
#   0  every required tool is present (installed now or already)
#   1  a tool could not be installed or verified
#
# Bash 3.2 portable. Needs curl, tar and a SHA-256 tool (sha256sum or shasum)
# only when gh is actually missing.

set -euo pipefail

GH_VERSION="${MERGEPATH_GH_VERSION:-2.101.0}"

# Pinned SHA-256 of each supported release asset (gh_<version>_linux_<arch>.tar.gz).
pinned_sha256() { # <asset>
  case "$1" in
    gh_2.101.0_linux_amd64.tar.gz) echo 9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8 ;;
    gh_2.101.0_linux_arm64.tar.gz) echo b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f ;;
    *) return 1 ;;
  esac
}
DRY_RUN=false
# Only the documented forms: an unknown or extra argument (a typo such as
# --dryrun) must refuse, never fall through to a real install (Codex on #1552).
case "$#:${1:-}" in
  0:) ;;
  1:--dry-run) DRY_RUN=true ;;
  *) echo "cloud-setup: usage: bash scripts/cloud-setup.sh [--dry-run]" >&2; exit 2 ;;
esac

log() { echo "cloud-setup: $*" >&2; }

CLEANUP_DIR=""
cleanup_tmp() { [ -z "$CLEANUP_DIR" ] || rm -rf "$CLEANUP_DIR"; }

choose_prefix() {
  if [ -n "${MERGEPATH_TOOL_PREFIX:-}" ]; then
    printf '%s\n' "$MERGEPATH_TOOL_PREFIX"
  elif [ -w /usr/local/bin ] 2>/dev/null; then
    printf '%s\n' /usr/local
  else
    printf '%s\n' "$HOME/.local"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

install_gh() {
  local os arch asset base tmp expected actual prefix
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macOS ;;
    *) log "unsupported OS $(uname -s) for a gh release install"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "unsupported architecture $(uname -m) for a gh release install"; return 1 ;;
  esac
  [ "$os" = "linux" ] || { log "gh is missing on macOS; install it with Homebrew (brew install gh)"; return 1; }
  asset="gh_${GH_VERSION}_${os}_${arch}.tar.gz"
  base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"
  prefix="$(choose_prefix)"
  # A prefix set in an environment's settings arrives unexpanded, so a leading
  # ~ means $HOME here, as the recipe writes it (Codex on #1552). Then an
  # absolute prefix, so the result does not depend on this directory.
  # shellcheck disable=SC2088  # the literal ~ is what is being matched
  case "$prefix" in
    "~") prefix="$HOME" ;;
    "~/"*) prefix="$HOME/${prefix#"~/"}" ;;
  esac
  case "$prefix" in /*) ;; *) prefix="$(pwd)/$prefix" ;; esac
  if ! expected="$(pinned_sha256 "$asset")"; then
    expected="${MERGEPATH_GH_SHA256:-}"
    case "$expected" in
      *[!0-9a-f]*|'') log "no pinned SHA-256 for $asset; set MERGEPATH_GH_SHA256 to its 64-hex digest or use the default version"; return 1 ;;
    esac
    [ "${#expected}" -eq 64 ] || { log "MERGEPATH_GH_SHA256 must be a 64-hex SHA-256 digest"; return 1; }
  fi
  if $DRY_RUN; then
    log "would install $asset from $base into $prefix/bin after verifying SHA-256 $expected"
    return 0
  fi
  for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || { log "$tool is required to install gh"; return 1; }
  done
  # install_gh runs in an `||` list, where `set -e` does not apply inside the
  # function, so every step checks its own status (CodeRabbit and Codex on
  # #1552): a failed step must fail the install, never log "installed".
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-setup.XXXXXX")" || { log "could not create a temporary directory"; return 1; }
  # The path is expanded when the trap runs, never re-parsed as shell code: a
  # TMPDIR with a quote in it would break a trap string (Codex on #1552).
  CLEANUP_DIR="$tmp"
  trap cleanup_tmp EXIT
  curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp/$asset" "$base/$asset" \
    || { log "download failed: $base/$asset"; return 1; }
  actual="$(sha256_of "$tmp/$asset")" || { log "no SHA-256 tool (sha256sum or shasum); refusing to install unverified"; return 1; }
  if [ "$actual" != "$expected" ]; then
    log "checksum mismatch for $asset (expected $expected, got $actual); refusing to install"
    return 1
  fi
  tar -xzf "$tmp/$asset" -C "$tmp" || { log "could not unpack $asset"; return 1; }
  mkdir -p "$prefix/bin" || { log "could not create $prefix/bin"; return 1; }
  cp "$tmp/gh_${GH_VERSION}_${os}_${arch}/bin/gh" "$prefix/bin/gh" || { log "could not copy gh into $prefix/bin"; return 1; }
  chmod 755 "$prefix/bin/gh" || { log "could not make $prefix/bin/gh executable"; return 1; }
  [ -x "$prefix/bin/gh" ] || { log "$prefix/bin/gh is not executable after install"; return 1; }
  # Executable bits are not proof it runs (a noexec mount, an incompatible
  # build): the installed binary must answer --version (Codex on #1552).
  "$prefix/bin/gh" --version >/dev/null 2>&1 || { log "$prefix/bin/gh does not run (gh --version failed; noexec mount or incompatible build?)"; return 1; }
  log "installed gh $GH_VERSION to $prefix/bin/gh (sha256 verified)"
  # Exit 0 means every required tool is usable afterwards: a gh the guarded
  # writes cannot find is not installed for them (Codex on #1552).
  # Tested by real command resolution, not a string match on PATH, so an
  # equivalent entry (a trailing slash, a symlinked directory) counts (Codex on
  # #1552).
  hash -r 2>/dev/null || true
  local resolved
  resolved="$(command -v gh 2>/dev/null || true)"
  # A relative resolution only holds from this directory: a later command run
  # elsewhere would not find gh, so it is refused (Codex on #1552).
  case "$resolved" in
    /*) [ "$resolved" -ef "$prefix/bin/gh" ] && return 0 ;;
    ?*) if [ "$resolved" -ef "$prefix/bin/gh" ]; then
          log "gh resolves through a relative PATH entry ($resolved), which works only from this directory; put the absolute $prefix/bin on PATH"
          return 1
        fi ;;
  esac
  log "$prefix/bin is not on PATH, so later commands cannot find gh; add $prefix/bin to the environment's PATH, or set MERGEPATH_TOOL_PREFIX to the PARENT of a directory already on PATH (gh goes to <prefix>/bin, so for ~/.local/bin on PATH use ~/.local)"
  return 1
}

status=0

# A tool already on PATH must resolve absolutely, as an installed one must: a
# relative PATH entry finds it only from this directory, and a re-run must not
# accept what the install path refuses (Phase 4b on #1552, #1554).
resolves_absolutely() { # <tool>
  local resolved
  resolved="$(command -v "$1" 2>/dev/null)" || return 1
  case "$resolved" in
    /*) return 0 ;;
    *) log "$1 resolves through a relative PATH entry ($resolved), which works only from this directory; put its absolute directory on PATH"
       return 1 ;;
  esac
}

# A tool counts as present only if it actually runs: a stale or corrupt binary
# on PATH must fail setup, not pass it (Codex on #1552).
if command -v gh >/dev/null 2>&1; then
  if ! resolves_absolutely gh; then
    status=1
  elif gh_v="$(gh --version 2>/dev/null)"; then
    log "gh present: $(printf '%s\n' "$gh_v" | head -1)"
  else
    log "gh is on PATH ($(command -v gh)) but does not run (gh --version failed); replace it or remove it so this script can install a pinned one"
    status=1
  fi
else
  install_gh || status=1
fi

if command -v jq >/dev/null 2>&1; then
  if ! resolves_absolutely jq; then
    status=1
  elif jq_v="$(jq --version 2>/dev/null)"; then
    log "jq present: $jq_v"
  else
    log "jq is on PATH ($(command -v jq)) but does not run (jq --version failed); reinstall it with the image's package manager"
    status=1
  fi
else
  log "jq is missing and is required by every helper; install it with the image's package manager (apt-get install -y jq)"
  status=1
fi

exit "$status"
