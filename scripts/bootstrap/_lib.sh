#!/usr/bin/env bash
# scripts/bootstrap/_lib.sh — shared helpers sourced by the
# bootstrap-new-repo.sh wizard and its per-stage modules.
#
# Surface:
#   bootstrap::log <message>           Log a non-side-effect line to stdout.
#   bootstrap::warn <message>          Log a warning to stderr.
#   bootstrap::err <message>           Log an error to stderr.
#   bootstrap::stage_banner <name>     Emit "==> Starting stage: <name>".
#   bootstrap::run <label> <cmd> [...] Execute (or dry-run echo) a side-effect.
#   bootstrap::author_gh [...]         Run gh through the verified author wrapper
#                                      unless dry-run/test bypass is active.
#   bootstrap::run_author_gh <label> [...]  Logged bootstrap::run wrapper around
#                                      bootstrap::author_gh for gh side-effects.
#   bootstrap::record_stage <name>     Append a completed stage name to the
#                                      state file at $BOOTSTRAP_STATE_FILE.
#   bootstrap::last_completed_stage    Echo the last recorded stage name,
#                                      or empty if no state file.
#
# Globals (set by the wizard before sourcing this file):
#   BOOTSTRAP_DRY_RUN     "1" iff --dry-run was passed; otherwise "0".
#   BOOTSTRAP_LOG_FILE    Path to a transcript log file. Each side-effect's
#                         label + command line is appended. The file's
#                         directory is created on first use.
#   BOOTSTRAP_STATE_FILE  Path to the state file used by --resume.
#
# Design notes:
#   - The bootstrap::run wrapper is the ONLY interface for side-effects.
#     Every gh/git/op/firebase call from a stage module must go through
#     it. Dry-run correctness depends on no stage cheating around the
#     wrapper.
#   - GitHub write attribution is token-verified per command. Bootstrap
#     stages never mutate machine-global gh account selection; author
#     writes route through scripts/gh-as-author.sh or, for stdin-heavy
#     calls, bootstrap::author_gh.
#   - Logs are deliberately verbose (full command line, not abbreviated).
#     The .bootstrap-log transcript is the audit trail.
#   - Stage modules read the wizard's collected inputs from a shared
#     associative array `BOOTSTRAP_INPUTS` (declared in the wizard,
#     populated by prompts/flags). This file does NOT redeclare it —
#     the wizard owns the lifecycle.

set -euo pipefail

# Prevent double-sourcing — useful if a stage file mistakenly sources
# the lib redundantly.
if [ "${_BOOTSTRAP_LIB_SOURCED:-0}" = "1" ]; then
  return 0
fi
_BOOTSTRAP_LIB_SOURCED=1

bootstrap::log() {
  echo "[bootstrap] $*"
}

bootstrap::warn() {
  echo "[bootstrap] WARN: $*" >&2
}

bootstrap::err() {
  echo "[bootstrap] ERROR: $*" >&2
}

bootstrap::stage_banner() {
  local stage_name=$1
  echo
  echo "==> Starting stage: $stage_name"
}

# Run a side-effecting command, or echo it in dry-run mode. The
# command is logged to $BOOTSTRAP_LOG_FILE either way (so dry-run
# produces a transcript readable as a do-it-yourself runbook).
#
# Usage:
#   bootstrap::run "create repo" gh repo create owner/name --private
#
# Args:
#   $1     Human-readable label (one line, no trailing punctuation).
#   $2..   Command + args, passed verbatim to exec.
#
# Returns the command's exit code, or 0 in dry-run mode.
bootstrap::run() {
  local label=$1
  shift
  if [ "$#" -eq 0 ]; then
    bootstrap::err "bootstrap::run requires a command after the label"
    return 64
  fi

  # Ensure log dir exists on first use.
  if [ -n "${BOOTSTRAP_LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$BOOTSTRAP_LOG_FILE")"
  fi

  local cmd_repr
  cmd_repr=$(printf '%q ' "$@")
  cmd_repr=${cmd_repr% }  # strip trailing space from printf

  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    echo "[DRY-RUN] $label: $cmd_repr"
    if [ -n "${BOOTSTRAP_LOG_FILE:-}" ]; then
      echo "[DRY-RUN] $label: $cmd_repr" >>"$BOOTSTRAP_LOG_FILE"
    fi
    return 0
  fi

  echo "[bootstrap] $label: $cmd_repr"
  if [ -n "${BOOTSTRAP_LOG_FILE:-}" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $label: $cmd_repr" >>"$BOOTSTRAP_LOG_FILE"
  fi
  "$@"
}

bootstrap::repo_root() {
  if [ -n "${BOOTSTRAP_MERGEPATH_ROOT:-}" ]; then
    printf '%s\n' "$BOOTSTRAP_MERGEPATH_ROOT"
    return 0
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

bootstrap::author_identity() {
  printf '%s\n' "${BOOTSTRAP_AUTHOR_IDENTITY:-nathanjohnpayne}"
}

bootstrap::author_wrapper() {
  local root
  root="$(bootstrap::repo_root)"
  printf '%s/scripts/gh-as-author.sh\n' "$root"
}

bootstrap::author_gh() {
  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ] || [ "${BOOTSTRAP_SKIP_AUTHOR_TOKEN:-0}" = "1" ]; then
    gh "$@"
    return $?
  fi

  local wrapper author_identity
  wrapper="$(bootstrap::author_wrapper)"
  author_identity="$(bootstrap::author_identity)"
  if [ ! -x "$wrapper" ]; then
    bootstrap::err "author gh wrapper missing or non-executable: $wrapper"
    bootstrap::err "refusing to run GitHub write without token verification"
    return 2
  fi

  GH_AS_AUTHOR_IDENTITY="$author_identity" "$wrapper" -- gh "$@"
}

bootstrap::run_author_gh() {
  local label=$1
  shift
  if [ "$#" -eq 0 ]; then
    bootstrap::err "bootstrap::run_author_gh requires gh arguments after the label"
    return 64
  fi

  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ] || [ "${BOOTSTRAP_SKIP_AUTHOR_TOKEN:-0}" = "1" ]; then
    bootstrap::run "$label" gh "$@"
    return $?
  fi

  local wrapper author_identity
  wrapper="$(bootstrap::author_wrapper)"
  author_identity="$(bootstrap::author_identity)"
  if [ ! -x "$wrapper" ]; then
    bootstrap::err "author gh wrapper missing or non-executable: $wrapper"
    bootstrap::err "refusing to run GitHub write without token verification"
    return 2
  fi

  bootstrap::run "$label" env GH_AS_AUTHOR_IDENTITY="$author_identity" "$wrapper" -- gh "$@"
}

# Append a completed-stage name to the resume state file. Idempotent —
# repeated calls just re-append (last entry wins). State file is a
# simple newline-separated list of stage names; --resume reads the
# LAST line.
bootstrap::record_stage() {
  local stage_name=$1
  if [ -z "${BOOTSTRAP_STATE_FILE:-}" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BOOTSTRAP_STATE_FILE")"
  echo "$stage_name" >>"$BOOTSTRAP_STATE_FILE"
}

# Echo the last recorded stage name, or empty string if the state
# file is absent / empty. Used by --resume to skip already-completed
# stages on a re-run.
bootstrap::last_completed_stage() {
  if [ -z "${BOOTSTRAP_STATE_FILE:-}" ] || [ ! -f "$BOOTSTRAP_STATE_FILE" ]; then
    return 0
  fi
  tail -n 1 "$BOOTSTRAP_STATE_FILE" 2>/dev/null || true
}
