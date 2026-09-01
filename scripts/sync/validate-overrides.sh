#!/usr/bin/env bash
# scripts/sync/validate-overrides.sh — schema validator for .sync-overrides.yml
#
# Each downstream consumer carries a `.sync-overrides.yml` at its repo
# root declaring intentional divergence from the Mergepath canonical
# mirror. This validator enforces the override schema BEFORE the
# propagation script (sync-to-downstream.sh) honors any entry — drift
# without a documented `reason` is the failure mode the override
# system exists to prevent.
#
# Usage:
#   scripts/sync/validate-overrides.sh [overrides-file] [manifest-file]
#
# Arguments:
#   overrides-file  Optional. Path to the .sync-overrides.yml. Defaults
#                   to ./.sync-overrides.yml relative to the cwd.
#   manifest-file   Optional. Path to the .mergepath-sync.yml manifest.
#                   Defaults to MERGEPATH_ROOT/.mergepath-sync.yml,
#                   resolved via env var MERGEPATH_ROOT_OVERRIDE (used
#                   in tests) or, if unset, the parent of the directory
#                   containing this script (i.e., scripts/sync/.. → repo
#                   root for an in-mergepath-checkout invocation).
#
# Validation rules:
#   1. Overrides file (if it exists) parses as YAML.
#   2. Top-level keys are limited to `version`, `skip_paths`, `substitutions`.
#      Unknown top-level keys exit non-zero.
#   3. `version` is required on any non-empty document and must equal
#      SUPPORTED_OVERRIDE_VERSION (currently 1). Empty / null-root
#      documents bypass at Rule 1b before this rule runs.
#   4. Every `skip_paths[].path` names an exact consumer-side manifest
#      target: `.dest` for templated entries, `.path` otherwise.
#      Skip-of-nonexistent-target exits non-zero.
#   5. Every `skip_paths[]` has a non-empty `reason` field.
#   6. Every `substitutions.<key>` matches a marker declared by a
#      manifest path with `type: templated`. A templated path may declare
#      no markers; undeclared substitutions still fail closed.
#   7. Every `substitutions.<key>` entry is a map with non-empty
#      `value` and `reason` fields. Bare scalar substitutions
#      (`marker: just-a-value`) fail validation — every override
#      must carry an audit-trail reason, matching the same posture
#      enforced on `skip_paths`. Closes a schema-contract gap caught
#      by nathanpayne-codex CHANGES_REQUESTED on PR #228.
#
# Exit codes:
#   0   Overrides file is absent OR all rules pass. Both cases are
#       valid for downstream CI: a repo with no divergences is fine.
#   1   Validation failure. One or more diagnostics on stderr.
#   2   Usage error / missing prerequisite (no `yq`, manifest absent
#       and not provided, etc.).
#
# Design notes:
#   - Read-only. Never writes to disk except diagnostics on stderr.
#   - Uses `yq` (mikefarah/yq v4+) for YAML parsing. Same dependency
#     the existing sync-to-downstream.sh uses.
#   - Absent overrides file is intentionally a pass — most consumers
#     won't have any divergences to document.

set -euo pipefail

SUPPORTED_OVERRIDE_VERSION=1

OVERRIDES_FILE="${1:-.sync-overrides.yml}"

if [ -n "${2:-}" ]; then
  MANIFEST_FILE="$2"
else
  MERGEPATH_ROOT="${MERGEPATH_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  MANIFEST_FILE="$MERGEPATH_ROOT/.mergepath-sync.yml"
fi

err() { echo "validate-overrides: ERROR: $*" >&2; }
fail() { err "$@"; exit 1; }
usage() { err "$@"; exit 2; }

if ! command -v yq >/dev/null 2>&1; then
  usage "yq (mikefarah/yq v4+) is required. Install via 'brew install yq'."
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  usage "Detected non-mikefarah yq. Install mikefarah/yq v4+ from https://github.com/mikefarah/yq."
fi

# Absent overrides file = no divergences = pass. This is intentional;
# most consumers should not have any documented overrides on day one.
if [ ! -f "$OVERRIDES_FILE" ]; then
  echo "validate-overrides: OK — no overrides file at $OVERRIDES_FILE"
  exit 0
fi

if [ ! -f "$MANIFEST_FILE" ]; then
  usage "manifest not found at $MANIFEST_FILE (set MERGEPATH_ROOT_OVERRIDE or pass as 2nd arg)"
fi

# --- Rule 1: overrides file parses as YAML --------------------------
if ! yq eval '.' "$OVERRIDES_FILE" >/dev/null 2>&1; then
  fail "$OVERRIDES_FILE is not valid YAML"
fi

# --- Rule 1b: document root must be a map ---------------------------
# Without this guard, a top-level scalar (e.g., the file contents are
# just `"not-a-map"`) or sequence (`- foo\n- bar`) would pass rules
# 2-6 silently — yq's `keys | .[]` returns nothing on non-map roots,
# so all the per-key checks no-op without complaint. CodeRabbit ⚠️
# Major on PR #228 round 2 caught this. `!!null` (empty document)
# round-trips as no overrides, same as an absent file.
ROOT_TYPE=$(yq eval '. | type' "$OVERRIDES_FILE" 2>/dev/null || echo "!!unknown")
case "$ROOT_TYPE" in
  "!!map")
    ;;
  "!!null")
    # Empty / `~` / `null` document — treat as no overrides.
    echo "validate-overrides: OK — $OVERRIDES_FILE is empty (no overrides)"
    exit 0
    ;;
  *)
    fail "$OVERRIDES_FILE document root must be a map (got $ROOT_TYPE)"
    ;;
esac

# --- Rule 2: top-level keys are restricted --------------------------
ALLOWED_KEYS=(version skip_paths substitutions)
# Portable replacement for `mapfile -t` (not available in bash 3.2 on
# macOS). Read each yq output line into an array element, preserving
# the count via ${#TOP_KEYS[@]}.
TOP_KEYS=()
while IFS= read -r _line; do
  TOP_KEYS+=("$_line")
done < <(yq eval 'keys | .[]' "$OVERRIDES_FILE" 2>/dev/null || true)
VIOLATIONS=0
for k in "${TOP_KEYS[@]:-}"; do
  [ -z "$k" ] && continue
  found=0
  for allowed in "${ALLOWED_KEYS[@]}"; do
    if [ "$k" = "$allowed" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    err "unknown top-level key: $k (allowed: ${ALLOWED_KEYS[*]})"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done

# --- Rule 3: version is required and must match -----------------------
# Schema-version is required on any non-empty overrides document so a
# downstream consumer's file declares an unambiguous schema contract
# from the start. (Empty/null-root documents already exited at Rule 1b.)
# CodeRabbit ⚠️ Major on PR #228 round 4 caught the gap — previously
# version was only validated WHEN present, so a non-empty file omitting
# it would silently pass.
HAS_VERSION=$(yq eval 'has("version")' "$OVERRIDES_FILE" 2>/dev/null || echo "false")
if [ "$HAS_VERSION" != "true" ]; then
  err "missing required top-level key: version (expected $SUPPORTED_OVERRIDE_VERSION)"
  VIOLATIONS=$((VIOLATIONS + 1))
else
  V=$(yq eval '.version' "$OVERRIDES_FILE" 2>/dev/null)
  if [ "$V" != "$SUPPORTED_OVERRIDE_VERSION" ]; then
    err "version $V not supported by this validator (expected $SUPPORTED_OVERRIDE_VERSION)"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
fi

# --- Rules 4 + 5: skip_paths validation ----------------------------
# Type-check skip_paths first — same defense as the substitutions block
# below. yq's `length` aborts on scalar values, which would otherwise
# produce a confusing diagnostic rather than a clean "skip_paths must
# be a sequence" violation. `null` round-trips as empty (no-op).
HAS_SKIP=$(yq eval 'has("skip_paths")' "$OVERRIDES_FILE" 2>/dev/null || echo "false")
SKIP_TYPE="!!null"
if [ "$HAS_SKIP" = "true" ]; then
  SKIP_TYPE=$(yq eval '.skip_paths | type' "$OVERRIDES_FILE" 2>/dev/null || echo "!!unknown")
  case "$SKIP_TYPE" in
    "!!seq"|"!!null")
      ;;
    *)
      err "skip_paths: must be a sequence (got $SKIP_TYPE)"
      VIOLATIONS=$((VIOLATIONS + 1))
      SKIP_TYPE="!!null"
      ;;
  esac
fi
SKIP_COUNT=0
if [ "$SKIP_TYPE" = "!!seq" ]; then
  SKIP_COUNT=$(yq eval '.skip_paths | length' "$OVERRIDES_FILE" 2>/dev/null || echo "0")
fi
if [ "$SKIP_COUNT" -gt 0 ]; then
  # Snapshot the manifest's consumer-side target keys once, for fast lookup.
  # Templated entries are selected in Mergepath by `.path` but land in the
  # consumer at `.dest`; overrides describe consumer-owned divergence and
  # therefore key those entries by destination. Canonical/kit propagation is
  # path-preserving and remains keyed by `.path`.
  MANIFEST_PATHS=()
  manifest_paths_output=""
  if ! manifest_paths_output=$(yq eval '
    .paths[]
    | . as $entry
    | (($entry.dest | select($entry.type == "templated")) // $entry.path)
  ' "$MANIFEST_FILE" 2>&1); then
    fail "failed to parse manifest at $MANIFEST_FILE: $manifest_paths_output"
  fi
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    MANIFEST_PATHS+=("$_line")
  done <<< "$manifest_paths_output"
  if [ "${#MANIFEST_PATHS[@]}" -eq 0 ]; then
    fail "manifest at $MANIFEST_FILE has no paths declared (cannot validate skip_paths)"
  fi

  for ((i = 0; i < SKIP_COUNT; i++)); do
    P=$(yq eval ".skip_paths[$i].path // \"\"" "$OVERRIDES_FILE")
    R=$(yq eval ".skip_paths[$i].reason // \"\"" "$OVERRIDES_FILE")

    if [ -z "$P" ]; then
      err "skip_paths[$i]: missing 'path' field"
      VIOLATIONS=$((VIOLATIONS + 1))
      continue
    fi
    # Strip surrounding whitespace from reason; treat trim-empty as missing.
    R_TRIMMED=$(printf '%s' "$R" | tr -d '[:space:]')
    if [ -z "$R_TRIMMED" ]; then
      err "skip_paths[$i] (path=$P): missing or empty 'reason' field — drift without a reason is the failure mode this file exists to prevent"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi

    # Match the path against the manifest's effective consumer targets.
    # These can be exact files or kit directories. The override must equal
    # one target exactly; partial-prefix skips would be ambiguous.
    found=0
    for mp in "${MANIFEST_PATHS[@]}"; do
      if [ "$mp" = "$P" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      err "skip_paths[$i] (path=$P): not found in manifest consumer targets (.dest for templated, .path otherwise) — cannot skip a path the manifest doesn't deliver"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done
fi

# --- Rule 6: substitutions validation -------------------------------
HAS_SUBS=$(yq eval 'has("substitutions")' "$OVERRIDES_FILE" 2>/dev/null || echo "false")
if [ "$HAS_SUBS" = "true" ]; then
  # Type-check substitutions before traversing keys (CodeRabbit ⚠️ Major
  # on PR #228). yq's `keys | .[]` aborts non-zero on a scalar value
  # (e.g., `substitutions: foo` where foo isn't a map), so without the
  # type check the validator would crash with `set -u`-unfriendly
  # diagnostics rather than emitting a clear "substitutions must be a
  # map" violation. `null` is allowed (treated as no-op, like an empty
  # map) so `substitutions: ~` round-trips cleanly.
  SUBS_TYPE=$(yq eval '.substitutions | type' "$OVERRIDES_FILE" 2>/dev/null || echo "!!unknown")
  case "$SUBS_TYPE" in
    "!!map"|"!!null")
      ;;
    *)
      err "substitutions: must be a map (got $SUBS_TYPE)"
      VIOLATIONS=$((VIOLATIONS + 1))
      SUBS_TYPE="!!null"
      ;;
  esac
  SUBS_COUNT=$(yq eval '.substitutions | length // 0' "$OVERRIDES_FILE" 2>/dev/null || echo "0")
  if [ "$SUBS_TYPE" = "!!map" ] && [ "$SUBS_COUNT" -gt 0 ]; then
    # Collect the set of substitution markers declared by the manifest's
    # templated paths. v1 manifest has only canonical + kit types so
    # this set is empty until templated lands; the validator then
    # rejects any substitution entries (correct strict default).
    TEMPLATED_MARKERS=()
    while IFS= read -r _line; do
      TEMPLATED_MARKERS+=("$_line")
    done < <(yq eval '.paths[] | select(.type == "templated") | .substitutions // {} | keys | .[]' "$MANIFEST_FILE" 2>/dev/null | sort -u || true)

    SUB_KEYS=()
    while IFS= read -r _line; do
      SUB_KEYS+=("$_line")
    done < <(yq eval '.substitutions | keys | .[]' "$OVERRIDES_FILE" 2>/dev/null || true)
    for k in "${SUB_KEYS[@]:-}"; do
      [ -z "$k" ] && continue
      found=0
      for marker in "${TEMPLATED_MARKERS[@]}"; do
        if [ "$marker" = "$k" ]; then
          found=1
          break
        fi
      done
      if [ "$found" -eq 0 ]; then
        if [ "${#TEMPLATED_MARKERS[@]}" -eq 0 ]; then
          err "substitutions.$k: manifest has no templated paths declared yet, so no substitution markers exist to override"
        else
          err "substitutions.$k: not declared as a substitution marker by any templated path in manifest (declared markers: ${TEMPLATED_MARKERS[*]})"
        fi
        VIOLATIONS=$((VIOLATIONS + 1))
      fi

      # --- Rule 7: substitution entries must be {value, reason} -----
      # nathanpayne-codex CHANGES_REQUESTED on PR #228 caught the
      # schema-contract gap: the docs/issue claim every divergence
      # carries an audit-trail reason, but the original schema let
      # substitutions ship as a bare scalar (`marker: value`) with
      # no reason at all. Require a structured map with both fields
      # present and non-empty — matches the posture skip_paths
      # already enforces.
      ENTRY_TYPE=$(YQ_K="$k" yq eval '.substitutions[strenv(YQ_K)] | type' "$OVERRIDES_FILE" 2>/dev/null || echo "!!unknown")
      if [ "$ENTRY_TYPE" != "!!map" ]; then
        err "substitutions.$k: must be a map with 'value' and 'reason' fields (got $ENTRY_TYPE — bare scalar substitutions are not allowed; every override must carry an audit-trail reason)"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
      fi
      ENTRY_VALUE_PRESENT=$(YQ_K="$k" yq eval '.substitutions[strenv(YQ_K)] | has("value")' "$OVERRIDES_FILE" 2>/dev/null || echo "false")
      ENTRY_VALUE_RAW=$(YQ_K="$k" yq eval '.substitutions[strenv(YQ_K)].value // ""' "$OVERRIDES_FILE" 2>/dev/null || echo "")
      ENTRY_VALUE_TRIMMED=$(printf '%s' "$ENTRY_VALUE_RAW" | tr -d '[:space:]')
      ENTRY_REASON_RAW=$(YQ_K="$k" yq eval '.substitutions[strenv(YQ_K)].reason // ""' "$OVERRIDES_FILE" 2>/dev/null || echo "")
      ENTRY_REASON_TRIMMED=$(printf '%s' "$ENTRY_REASON_RAW" | tr -d '[:space:]')
      if [ "$ENTRY_VALUE_PRESENT" != "true" ]; then
        err "substitutions.$k: missing 'value' field"
        VIOLATIONS=$((VIOLATIONS + 1))
      elif [ -z "$ENTRY_VALUE_TRIMMED" ]; then
        # Present-but-empty value (null, "", or whitespace) — the
        # `{value, reason}` contract requires non-empty value. CodeRabbit
        # ⚠️ Major on PR #228 round 4 caught the gap; the prior shape
        # accepted `value: null` / `value: ""`.
        err "substitutions.$k: missing or empty 'value' field"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      if [ -z "$ENTRY_REASON_TRIMMED" ]; then
        err "substitutions.$k: missing or empty 'reason' field — every override must carry an audit-trail reason"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
    done
  fi
fi

if [ "$VIOLATIONS" -gt 0 ]; then
  err "$VIOLATIONS validation error(s) in $OVERRIDES_FILE"
  exit 1
fi

echo "validate-overrides: OK — $OVERRIDES_FILE matches schema"
exit 0
