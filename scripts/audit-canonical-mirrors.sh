#!/usr/bin/env bash
# scripts/audit-canonical-mirrors.sh
#
# Read-only triage aid for canonical-source drift in machine-local
# vendor files (#739). Machine-level agent files — a machine's
# ~/GitHub/CLAUDE.md, a global ~/.codex/AGENTS.md — mirror conventions
# whose canonical source is a file in the mergepath checkout. Per
# docs/agents/documentation-rules.md § Canonical-source discipline,
# every mirrored top-level (##) section must carry a
# `> Canonical source: mergepath/<path>` annotation, optionally pinned
# with `(canonical-sha256: <hex-prefix>)` recording a SHA-256 prefix of
# the canonical file at mirror time.
#
# This script parses each vendor file's top-level `## ` sections
# (fenced code blocks are ignored, so a `##` inside a code fence is not
# a heading) and reports, per section:
#
#   missing-annotation  no `Canonical source:` line in the section —
#                       candidate for triage: either the section is
#                       genuinely machine-local (fine; annotation-free
#                       by design) or it was authored downstream-first
#                       and needs a canonical home in mergepath.
#   source-missing      annotated path does not exist in the local
#                       mergepath checkout (moved/renamed/typo).
#   drift               annotation carries a canonical-sha256 pin and
#                       the canonical file's current SHA-256 no longer
#                       matches it — the canonical source moved on
#                       since the mirror was taken; re-sync the mirror
#                       and update the pin.
#   ok-unpinned         annotation present, source exists, but no
#                       sha256 pin — drift cannot be verified.
#   ok                  annotation present, source exists, pin matches.
#
# NO auto-edits, NO auto-migration: the "is this cross-agent-worthy"
# judgment stays with whoever reviews the report. Expect false
# positives on genuinely machine-local sections — that is by design.
#
# This is an on-demand / session-finalization-style LOCAL check. It is
# deliberately NOT wired into any GitHub Actions workflow: the files it
# audits live outside every git repo, so repository CI cannot see them.
#
# Usage:
#   scripts/audit-canonical-mirrors.sh [FILE ...]
#
#   FILE ...   vendor files to audit. Default when none given:
#              ~/GitHub/CLAUDE.md and ~/.codex/AGENTS.md (absent
#              defaults are reported as skipped, not errors; a FILE
#              named explicitly must exist).
#
# Environment:
#   AUDIT_CANONICAL_MIRROR_FILES  whitespace-separated file list that
#                                 replaces the built-in defaults (CLI
#                                 args still win over this).
#   MERGEPATH_ROOT                mergepath checkout the annotated
#                                 sources resolve against (default:
#                                 this script's own repo root).
#
# Exit codes:
#   0  report produced (regardless of findings — triage aid, not a gate)
#   2  usage/environment error (unknown flag, explicit file missing,
#      MERGEPATH_ROOT not a directory, no sha256 tool)

set -euo pipefail

usage() {
  sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGEPATH_ROOT="${MERGEPATH_ROOT:-$SCRIPT_ROOT}"

FILES=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
    *) FILES+=("$arg") ;;
  esac
done

EXPLICIT_FILES=${#FILES[@]}
if [ ${#FILES[@]} -eq 0 ]; then
  if [ -n "${AUDIT_CANONICAL_MIRROR_FILES:-}" ]; then
    # Intentional word-splitting of the env override list.
    # shellcheck disable=SC2206
    FILES=(${AUDIT_CANONICAL_MIRROR_FILES})
  else
    FILES=("$HOME/GitHub/CLAUDE.md" "$HOME/.codex/AGENTS.md")
  fi
fi

if [ ! -d "$MERGEPATH_ROOT" ]; then
  echo "ERROR: MERGEPATH_ROOT is not a directory: $MERGEPATH_ROOT" >&2
  exit 2
fi

# Portable SHA-256: sha256sum (Linux) or shasum -a 256 (macOS).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "ERROR: neither sha256sum nor shasum found on PATH" >&2
    exit 2
  fi
}

TOTAL_SECTIONS=0
COUNT_MISSING=0
COUNT_SOURCE_MISSING=0
COUNT_DRIFT=0
COUNT_UNPINNED=0
COUNT_OK=0

# Extract the annotated canonical path from an annotation line.
# Prefers the first backtick-delimited token; falls back to the first
# whitespace token after the "canonical source:" label. A leading
# "mergepath/" prefix is stripped so the remainder resolves against
# MERGEPATH_ROOT.
annotation_path() {
  local line="$1" path
  # shellcheck disable=SC2016  # literal backticks in the sed pattern, not expansion
  path=$(printf '%s\n' "$line" | sed -n 's/[^`]*`\([^`]*\)`.*/\1/p' | head -n1)
  if [ -z "$path" ]; then
    path=$(printf '%s\n' "$line" \
      | sed -n 's/.*[Cc]anonical [Ss]ource[^:]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
      | head -n1)
  fi
  # Strip trailing punctuation a prose sentence may append.
  path="${path%%\)*}"
  path=$(printf '%s' "$path" | sed 's/[.,;]*$//')
  path="${path#mergepath/}"
  printf '%s' "$path"
}

# Extract a canonical-sha256 pin (12+ hex chars) from the section text.
annotation_pin() {
  printf '%s\n' "$1" \
    | sed -n 's/.*canonical-sha256:[[:space:]]*\([0-9a-fA-F]\{12,64\}\).*/\1/p' \
    | head -n1
}

report_section() {
  local heading="$1" annotation="$2" pin="$3"
  TOTAL_SECTIONS=$((TOTAL_SECTIONS + 1))

  if [ -z "$annotation" ]; then
    COUNT_MISSING=$((COUNT_MISSING + 1))
    printf '  [missing-annotation] ## %s\n' "$heading"
    return 0
  fi

  local src rel abs
  rel=$(annotation_path "$annotation")
  if [ -z "$rel" ]; then
    COUNT_MISSING=$((COUNT_MISSING + 1))
    printf '  [missing-annotation] ## %s (annotation present but no source path parsed: %s)\n' "$heading" "$annotation"
    return 0
  fi
  abs="$MERGEPATH_ROOT/$rel"
  if [ ! -f "$abs" ]; then
    COUNT_SOURCE_MISSING=$((COUNT_SOURCE_MISSING + 1))
    printf '  [source-missing]     ## %s -> %s (not found under %s)\n' "$heading" "$rel" "$MERGEPATH_ROOT"
    return 0
  fi
  if [ -z "$pin" ]; then
    COUNT_UNPINNED=$((COUNT_UNPINNED + 1))
    printf '  [ok-unpinned]        ## %s -> %s (no canonical-sha256 pin; drift not verifiable)\n' "$heading" "$rel"
    return 0
  fi
  src=$(sha256_of "$abs")
  local pin_lc src_prefix
  pin_lc=$(printf '%s' "$pin" | tr '[:upper:]' '[:lower:]')
  src_prefix=${src:0:${#pin_lc}}
  if [ "$src_prefix" = "$pin_lc" ]; then
    COUNT_OK=$((COUNT_OK + 1))
    printf '  [ok]                 ## %s -> %s (pin %s matches)\n' "$heading" "$rel" "$pin_lc"
  else
    COUNT_DRIFT=$((COUNT_DRIFT + 1))
    printf '  [drift]              ## %s -> %s (pinned %s, current %s)\n' "$heading" "$rel" "$pin_lc" "${src:0:12}"
  fi
}

audit_file() {
  local file="$1"
  printf '== %s\n' "$file"

  local in_fence=0 fence_marker=""
  local cur_heading="" cur_annotation="" cur_pin="" seen_section=0
  local line stripped

  while IFS= read -r line || [ -n "$line" ]; do
    # Fence tracking so a `##` inside a code block is never a heading
    # and an annotation-looking line inside one is never an annotation.
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      '```'*|'~~~'*)
        if [ "$in_fence" -eq 0 ]; then
          in_fence=1
          fence_marker="${stripped:0:3}"
        elif [ "${stripped:0:3}" = "$fence_marker" ]; then
          in_fence=0
          fence_marker=""
        fi
        continue
        ;;
    esac
    [ "$in_fence" -eq 1 ] && continue

    case "$line" in
      '## '*)
        if [ "$seen_section" -eq 1 ]; then
          report_section "$cur_heading" "$cur_annotation" "$cur_pin"
        fi
        seen_section=1
        cur_heading="${line#\#\# }"
        cur_annotation=""
        cur_pin=""
        continue
        ;;
    esac

    [ "$seen_section" -eq 1 ] || continue

    if [ -z "$cur_annotation" ]; then
      if printf '%s\n' "$line" | grep -qiE 'canonical source[^:]*:'; then
        cur_annotation="$line"
      fi
    fi
    if [ -z "$cur_pin" ]; then
      local maybe_pin
      maybe_pin=$(annotation_pin "$line")
      [ -n "$maybe_pin" ] && cur_pin="$maybe_pin"
    fi
  done < "$file"

  if [ "$seen_section" -eq 1 ]; then
    report_section "$cur_heading" "$cur_annotation" "$cur_pin"
  else
    printf '  (no top-level ## sections found)\n'
  fi
}

echo "audit-canonical-mirrors: mergepath root: $MERGEPATH_ROOT"
for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    if [ "$EXPLICIT_FILES" -gt 0 ]; then
      echo "ERROR: file not found: $file" >&2
      exit 2
    fi
    printf '== %s\n  (absent — skipped)\n' "$file"
    continue
  fi
  audit_file "$file"
done

echo
echo "audit-canonical-mirrors summary: $TOTAL_SECTIONS section(s) scanned — ok: $COUNT_OK, ok-unpinned: $COUNT_UNPINNED, missing-annotation: $COUNT_MISSING, source-missing: $COUNT_SOURCE_MISSING, drift: $COUNT_DRIFT"
echo "(triage aid: read-only, always exits 0 after a report; classifications are candidates for human/agent judgment, not verdicts)"
exit 0
