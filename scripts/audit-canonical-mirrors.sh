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
#   invalid-source      annotated path is absolute, normalizes to a
#                       location OUTSIDE MERGEPATH_ROOT (e.g.
#                       `mergepath/../outside/file.md`), or is a
#                       SYMLINK. The symlink rejection is
#                       unconditional — including a symlink whose
#                       target is itself inside the checkout — because
#                       lexical normalization cannot follow a link, so
#                       "points somewhere safe" is not something this
#                       script can prove; it refuses instead. The path
#                       is rejected BEFORE it is HASHED, so a file
#                       outside the canonical checkout can never be
#                       reported as a matching canonical source. (Only
#                       the lexical proof runs before the path is
#                       stat'd; the physical/symlink proof runs after
#                       the existence check, so a DANGLING escaping
#                       symlink reports as source-missing rather than
#                       invalid-source. Both refuse to hash, which is
#                       the property that matters.)
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
# This is an on-demand / session-finalization-style LOCAL check. The
# audit RUN is deliberately not wired into any GitHub Actions workflow:
# the files it audits live outside every git repo, so repository CI
# cannot see them. Its hermetic parser regression suite
# (tests/test_audit_canonical_mirrors.sh) DOES run in CI via
# scripts/ci/check_audit_canonical_mirrors — CI guards the parser,
# never the machine-local audit itself.
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
  sed -n '2,73p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Physical (symlink-resolved) form of the root, for the containment
# check in report_section. Resolving BOTH sides the same way is what
# keeps a symlinked ancestor (macOS's /var → /private/var) from
# false-negativing the comparison — the same pattern
# scripts/worktree-cleanup.sh uses for its orphan-root boundary. An
# empty value means "could not resolve", which path_inside_root treats
# as a refusal, so the trailing-slash form is never a bare "/".
MERGEPATH_ROOT_PHYS=$(cd "$MERGEPATH_ROOT" 2>/dev/null && pwd -P) || MERGEPATH_ROOT_PHYS=""
MERGEPATH_ROOT_PHYS_TS="${MERGEPATH_ROOT_PHYS%/}/"

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
COUNT_INVALID=0
COUNT_SOURCE_MISSING=0
COUNT_DRIFT=0
COUNT_UNPINNED=0
COUNT_OK=0

# Lexically normalize an annotated relative path and prove it stays
# inside MERGEPATH_ROOT. Prints the normalized path and exits 0 ONLY
# for a relative path whose `.`/`..` segments all resolve within the
# checkout; prints nothing and exits 1 for an absolute path, a path
# whose `..` segments climb above the root, or one that normalizes to
# nothing. Purely lexical and done BEFORE any filesystem access, so a
# `mergepath/../outside/file.md` annotation is rejected rather than
# stat'd and hashed outside the canonical checkout (#762).
normalize_relpath() {
  local rel="$1" out="" seg rest
  case "$rel" in
    /*) return 1 ;;
  esac
  rest="$rel"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    case "$seg" in
      ''|'.') ;;
      '..')
        # Nothing left to pop means this `..` leaves MERGEPATH_ROOT.
        [ -n "$out" ] || return 1
        case "$out" in
          */*) out="${out%/*}" ;;
          *)   out="" ;;
        esac
        ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Physical containment proof for an already-resolved canonical file.
# Exits 0 ONLY when the file is a real (non-symlink) entry whose
# physical directory sits under the physical MERGEPATH_ROOT. Lexical
# normalization alone cannot see a symlink that lands the target
# outside the checkout, so this second check runs before any hashing.
# Every resolution failure exits 1 — the safe case is stated
# positively and everything else is a refusal.
path_inside_root() {
  local abs="$1" abs_dir
  if [ -L "$abs" ]; then
    return 1
  fi
  if [ -z "$MERGEPATH_ROOT_PHYS" ]; then
    return 1
  fi
  abs_dir=$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P) || return 1
  if [ -z "$abs_dir" ]; then
    return 1
  fi
  case "${abs_dir}/" in
    "$MERGEPATH_ROOT_PHYS_TS"*) return 0 ;;
    *) return 1 ;;
  esac
}

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

  local src rel norm abs
  rel=$(annotation_path "$annotation")
  if [ -z "$rel" ]; then
    COUNT_MISSING=$((COUNT_MISSING + 1))
    printf '  [missing-annotation] ## %s (annotation present but no source path parsed: %s)\n' "$heading" "$annotation"
    return 0
  fi
  # Containment proof #1 (lexical), before the path is ever stat'd.
  if ! norm=$(normalize_relpath "$rel"); then
    COUNT_INVALID=$((COUNT_INVALID + 1))
    printf '  [invalid-source]     ## %s -> %s (absolute or escapes %s — rejected, not hashed)\n' "$heading" "$rel" "$MERGEPATH_ROOT"
    return 0
  fi
  abs="$MERGEPATH_ROOT/$norm"
  if [ ! -f "$abs" ]; then
    COUNT_SOURCE_MISSING=$((COUNT_SOURCE_MISSING + 1))
    printf '  [source-missing]     ## %s -> %s (not found under %s)\n' "$heading" "$norm" "$MERGEPATH_ROOT"
    return 0
  fi
  # Containment proof #2 (physical), before the file is hashed.
  if ! path_inside_root "$abs"; then
    COUNT_INVALID=$((COUNT_INVALID + 1))
    printf '  [invalid-source]     ## %s -> %s (symlink or resolves outside %s — rejected, not hashed)\n' "$heading" "$norm" "$MERGEPATH_ROOT"
    return 0
  fi
  if [ -z "$pin" ]; then
    COUNT_UNPINNED=$((COUNT_UNPINNED + 1))
    printf '  [ok-unpinned]        ## %s -> %s (no canonical-sha256 pin; drift not verifiable)\n' "$heading" "$norm"
    return 0
  fi
  src=$(sha256_of "$abs")
  local pin_lc src_prefix
  pin_lc=$(printf '%s' "$pin" | tr '[:upper:]' '[:lower:]')
  src_prefix=${src:0:${#pin_lc}}
  if [ "$src_prefix" = "$pin_lc" ]; then
    COUNT_OK=$((COUNT_OK + 1))
    printf '  [ok]                 ## %s -> %s (pin %s matches)\n' "$heading" "$norm" "$pin_lc"
  else
    COUNT_DRIFT=$((COUNT_DRIFT + 1))
    printf '  [drift]              ## %s -> %s (pinned %s, current %s)\n' "$heading" "$norm" "$pin_lc" "${src:0:12}"
  fi
}

audit_file() {
  local file="$1"
  printf '== %s\n' "$file"

  local in_fence=0 fence_char="" fence_len=0
  local cur_heading="" cur_annotation="" cur_pin="" seen_section=0
  local line indent fence_indent_ok stripped run_char run_len remainder

  while IFS= read -r line || [ -n "$line" ]; do
    # Fence tracking so a `##` inside a code block is never a heading
    # and an annotation-looking line inside one is never an annotation.
    # Per the CommonMark closing-fence rule, a fence closes only on a
    # run of the SAME character at least as LONG as the opening run,
    # followed by NOTHING but whitespace — a closing fence may not
    # carry an info string. Tracking the char and full run length (not
    # a truncated 3-char marker) keeps a 4+-backtick outer fence (the
    # standard way to nest a triple-backtick example) from being closed
    # by an inner ``` line, and the whitespace-only-remainder check
    # keeps an opener-LOOKING line with an info string (e.g. a literal
    # ```bash shown inside an open triple-backtick block) from being
    # misread as the closer — such a line is fence CONTENT.
    indent="${line%%[![:space:]]*}"
    stripped="${line#"$indent"}"
    # CommonMark allows at most THREE spaces of indentation before a
    # fence delimiter; at four or more columns the line is indented
    # CODE, not a delimiter. A leading tab advances to the next
    # four-column tab stop, so any tab in the indent already exceeds
    # the limit. Measuring the indent (rather than discarding it, as
    # the original strip did) is what keeps a 4-space-indented literal
    # ``` — the ordinary way to show a fence inside an indented example
    # — from toggling fence state and swallowing or fabricating whole
    # sections (#762).
    fence_indent_ok=1
    if [ "${#indent}" -ge 4 ]; then
      fence_indent_ok=0
    else
      case "$indent" in
        *$'\t'*) fence_indent_ok=0 ;;
      esac
    fi
    if [ "$fence_indent_ok" -eq 1 ]; then
      case "$stripped" in
        '```'*|'~~~'*)
          run_char="${stripped:0:1}"
          run_len=0
          while [ "${stripped:$run_len:1}" = "$run_char" ]; do
            run_len=$((run_len + 1))
          done
          remainder="${stripped:$run_len}"
          if [ "$in_fence" -eq 0 ]; then
            in_fence=1
            fence_char="$run_char"
            fence_len="$run_len"
          elif [ "$run_char" = "$fence_char" ] && [ "$run_len" -ge "$fence_len" ]; then
            case "$remainder" in
              *[![:space:]]*)
                # Non-whitespace after the delimiter run: not a valid
                # closing fence (CommonMark) — treat as fence content.
                ;;
              *)
                in_fence=0
                fence_char=""
                fence_len=0
                ;;
            esac
          fi
          continue
          ;;
      esac
    fi
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
echo "audit-canonical-mirrors summary: $TOTAL_SECTIONS section(s) scanned — ok: $COUNT_OK, ok-unpinned: $COUNT_UNPINNED, missing-annotation: $COUNT_MISSING, source-missing: $COUNT_SOURCE_MISSING, invalid-source: $COUNT_INVALID, drift: $COUNT_DRIFT"
echo "(triage aid: read-only, always exits 0 after a report; classifications are candidates for human/agent judgment, not verdicts)"
exit 0
