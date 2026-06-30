#!/usr/bin/env bash
# scripts/lib/template-substitution.sh — render templated propagation
# sources with per-consumer facts.
#
# v1 syntax (intentionally minimal — see docs/agents/templated-
# propagation.md § Why this syntax for the rationale):
#
#   1. Variable substitution. Anywhere in the file:
#        {{key}}                 → ${MERGEPATH_FACT_KEY:-""}
#      Missing fact = empty string in lenient mode (default), hard
#      fail in strict mode (MERGEPATH_TEMPLATE_STRICT=1).
#
#   2. Conditional blocks. Lines matching:
#        >>> if <expr>
#        ...body...
#        <<<
#      The leading comment prefix on the marker line is stripped (the
#      lib accepts any non-alnum run before the `>>>`/`<<<` sigil so
#      `//`, `#`, `--`, `<!-- … -->`, `/* … */` all work). Body lines
#      survive verbatim if <expr> is true; the entire block (markers
#      included) is omitted otherwise.
#
#      <expr> forms accepted in v1:
#        - <key>                  truthy iff env MERGEPATH_FACT_KEY is set
#                                 and non-empty
#        - !<key>                 inverse of the above
#        - <key> contains <value> for space-separated list facts
#        - <key> == <value>       string equality
#        - <key> != <value>       string inequality
#
#      Nesting is NOT supported in v1. Two `>>> if` opens without an
#      intervening `<<<` is a malformed-template error (exit 1). Add
#      nesting later if a real source file needs it.
#
# Facts source: environment variables. Each fact key (lowercase,
# possibly with hyphens) maps to `MERGEPATH_FACT_<KEY>` (uppercase,
# hyphens → underscores). List facts are space-separated. Sync
# integration (scripts/sync-to-downstream.sh) is responsible for
# extracting per-consumer facts from .mergepath-sync.yml and
# exporting them before invoking this lib.
#
# API:
#   template_substitution::render <source_file>
#       Renders to stdout. Exit 0 success, 1 malformed template, 2
#       source-file missing, 3 unknown fact in strict mode.
#
#   template_substitution::render_to <source_file> <dest_file>
#       Atomic write via mktemp + mv. Same exit codes as render.
#
#   template_substitution::eval_expr <expr>
#       Returns 0 if expr is true, 1 if false, 2 if expr is malformed.
#       Exposed so tests can drive it directly.
#
# Bash 3.2 portable (no associative arrays, no ${var^^}). Matches
# scripts/bootstrap/substitute.sh's portability bar.
#
# This file is a SOURCED library and intentionally does NOT set
# `set -euo pipefail` at file scope — that would mutate the caller's
# shell options unexpectedly (CodeRabbit Major / Codex P1 on PR #313).
# Internal functions use the `|| rc=$?` pattern to capture exit codes
# without depending on errexit. The executed-directly guard block at
# the bottom does enable strict mode for the noop-script path.

# Convert a lowercase-with-hyphens fact name to its env var form:
# "frameworks" → "MERGEPATH_FACT_FRAMEWORKS"
# "node-version" → "MERGEPATH_FACT_NODE_VERSION"
template_substitution::_fact_var() {
  local key=$1
  local upper
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  printf 'MERGEPATH_FACT_%s' "$upper"
}

# Look up a fact value. Echoes the value (empty string if unset).
# In strict mode, prints a diagnostic to stderr and returns 3 if the
# fact is referenced but unset.
#
# Validates the key against [a-z0-9-] before passing to _fact_var
# because _fact_var feeds into eval below. Without this guard, a key
# containing shell metacharacters (e.g. `foo$(id)`) survives the `tr`
# transformation and is interpreted at eval time as a command
# substitution — RCE via a malicious manifest fact key (CodeRabbit
# Critical on PR #313). Keys come from the manifest in practice, but
# defense-in-depth catches a bad manifest entry or a future code
# path that synthesizes keys from less-trusted input.
template_substitution::_fact_value() {
  local key=$1
  case "$key" in
    ''|*[!a-z0-9_-]*)
      # Reject anything outside [a-z0-9_-]. Underscores stay allowed
      # because env-var-style fact keys (e.g. `node_version`) are
      # natural in templates and underscores are not eval metachars.
      # Shell metacharacters ($, (, ), backtick, ;, &, |, \) and
      # uppercase letters are blocked: the former are the injection
      # surface, the latter are reserved for the env-var form
      # (_fact_var uppercases keys to derive MERGEPATH_FACT_<KEY>).
      printf 'template: malformed fact key (must match [a-z0-9_-]+): %s\n' "$key" >&2
      return 2
      ;;
  esac
  local var
  var=$(template_substitution::_fact_var "$key")
  # bash 3.2 indirect expansion via eval. Detect set-or-unset with
  # the `${var+x}` form (echoes "x" if var is set to ANY value
  # including empty; echoes empty if unset). Earlier versions used
  # a literal sentinel string compared via `=`, which mis-classified
  # a fact legitimately set to that exact sentinel as unset
  # (Codex P3 on PR #313). The +x form has no collision surface —
  # the test is on the existence of the variable, not its value.
  local is_set
  eval "is_set=\${$var+x}"
  if [ -z "$is_set" ]; then
    if [ "${MERGEPATH_TEMPLATE_STRICT:-0}" = "1" ]; then
      printf 'template: strict mode: fact %s (env %s) is not set\n' \
        "$key" "$var" >&2
      return 3
    fi
    printf ''
    return 0
  fi
  local value
  eval "value=\${$var}"
  printf '%s' "$value"
}

# Evaluate a conditional expression. Returns 0 (true), 1 (false), or
# 2 (malformed).
template_substitution::eval_expr() {
  local expr=$1
  # Trim leading/trailing whitespace.
  expr=$(printf '%s' "$expr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  case "$expr" in
    "")
      printf 'template: empty conditional expression\n' >&2
      return 2
      ;;
    "!"*)
      local inner=${expr#!}
      inner=$(printf '%s' "$inner" | sed -e 's/^[[:space:]]*//')
      local v rc=0
      # Existence-check: strict mode must not abort here — an unset fact is
      # simply false (and therefore !key is true). Suppress strict for the
      # _fact_value call; treat rc 3 (strict-mode fact-miss) as "unset".
      v=$(MERGEPATH_TEMPLATE_STRICT=0; template_substitution::_fact_value "$inner") || rc=$?
      if [ "$rc" -eq 3 ]; then return 0; fi  # unset → !key is true
      if [ "$rc" -ne 0 ]; then return "$rc"; fi
      if [ -z "$v" ]; then return 0; else return 1; fi
      ;;
    *" contains "*)
      local key=${expr%% contains *}
      local needle=${expr#* contains }
      key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      needle=$(printf '%s' "$needle" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      local haystack
      haystack=$(template_substitution::_fact_value "$key") || return $?
      # Space-padded match so "react" doesn't match "react-native".
      case " $haystack " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *" == "*)
      local key=${expr%% == *}
      local want=${expr#* == }
      key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      want=$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      local have
      have=$(template_substitution::_fact_value "$key") || return $?
      if [ "$have" = "$want" ]; then return 0; else return 1; fi
      ;;
    *" != "*)
      local key=${expr%% != *}
      local want=${expr#* != }
      key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      want=$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      local have
      have=$(template_substitution::_fact_value "$key") || return $?
      if [ "$have" != "$want" ]; then return 0; else return 1; fi
      ;;
    *" "*)
      printf 'template: malformed conditional expression: %s\n' "$expr" >&2
      printf 'template: supported forms: <key>, !<key>, <key> contains <value>, <key> == <value>, <key> != <value>\n' >&2
      return 2
      ;;
    *)
      # Bare key — truthy iff non-empty. Strict mode must not abort here —
      # an unset fact is simply false for the existence check.
      local v rc=0
      v=$(MERGEPATH_TEMPLATE_STRICT=0; template_substitution::_fact_value "$expr") || rc=$?
      if [ "$rc" -eq 3 ]; then return 1; fi  # unset → bare-key is false
      if [ "$rc" -ne 0 ]; then return "$rc"; fi
      if [ -n "$v" ]; then return 0; else return 1; fi
      ;;
  esac
}

# Apply {{key}} substitutions to a single line. Echoes the rewritten
# line. In strict mode, an unset fact reference returns 3 (caller
# handles).
template_substitution::_substitute_vars() {
  local line=$1
  # Fast path: no `{{` on the line.
  case "$line" in
    *"{{"*) ;;
    *) printf '%s' "$line"; return 0 ;;
  esac

  # Walk left-to-right, replacing each {{key}} occurrence.
  local out=""
  local remaining=$line
  while :; do
    case "$remaining" in
      *"{{"*)
        local before=${remaining%%\{\{*}
        local rest=${remaining#*\{\{}
        case "$rest" in
          *"}}"*)
            local key=${rest%%\}\}*}
            local after=${rest#*\}\}}
            local value
            value=$(template_substitution::_fact_value "$key") || return $?
            out="$out$before$value"
            remaining=$after
            ;;
          *)
            # Unclosed {{: emit as-is, stop.
            out="$out$remaining"
            remaining=""
            break
            ;;
        esac
        ;;
      *)
        out="$out$remaining"
        remaining=""
        break
        ;;
    esac
  done
  printf '%s' "$out"
}

# Regex helpers — POSIX BREs, anchored, comment-prefix-agnostic.
# Marker line pattern: optional whitespace, optional non-alnum prefix
# (the comment chars), optional whitespace, then the sigil, then space-
# separated payload. We use grep -E with explicit anchors.
template_substitution::_is_if_open() {
  # $1: line. Returns 0 if it's a `>>> if ...` marker, echoing the
  # expression on stdout. Returns 1 otherwise (no output).
  local line=$1
  printf '%s' "$line" | grep -E '^[[:space:]]*[^[:alnum:]{]*[[:space:]]*>>>[[:space:]]+if[[:space:]]+' >/dev/null || return 1
  # Extract the expression after `>>> if `.
  printf '%s' "$line" | sed -E 's/^[[:space:]]*[^[:alnum:]{]*[[:space:]]*>>>[[:space:]]+if[[:space:]]+//' \
    | sed -e 's/[[:space:]]*$//' \
    | sed -E 's,[[:space:]]*(\*/|-->)[[:space:]]*$,,'
  return 0
}

template_substitution::_is_close() {
  # $1: line. Returns 0 if it's a `<<<` marker line, 1 otherwise.
  local line=$1
  printf '%s' "$line" | grep -E '^[[:space:]]*[^[:alnum:]{]*[[:space:]]*<<<[[:space:]]*([^[:alnum:]{]*[[:space:]]*)?$' >/dev/null
}

# Render a template file to stdout. Implements the v1 syntax.
template_substitution::render() {
  local source=$1
  if [ ! -f "$source" ]; then
    printf 'template: source file not found: %s\n' "$source" >&2
    return 2
  fi

  local in_conditional=0      # 0 outside, 1 inside (active), 2 inside (skipped)
  local conditional_lineno=0  # for error diagnostics on unclosed `if`
  local lineno=0
  local line
  # IFS= + -r preserves leading whitespace and backslashes. The trailing
  # `|| [ -n "$line" ]` catches a file without a final newline.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    # `<<<` close marker?
    if template_substitution::_is_close "$line"; then
      if [ "$in_conditional" = "0" ]; then
        printf 'template: %s:%d: unexpected `<<<` (no open `>>> if`)\n' \
          "$source" "$lineno" >&2
        return 1
      fi
      in_conditional=0
      continue
    fi

    # `>>> if ...` open marker?
    local expr
    if expr=$(template_substitution::_is_if_open "$line"); then
      if [ "$in_conditional" != "0" ]; then
        printf 'template: %s:%d: nested `>>> if` is not supported in v1 (open at line %d)\n' \
          "$source" "$lineno" "$conditional_lineno" >&2
        return 1
      fi
      conditional_lineno=$lineno
      local rc=0
      template_substitution::eval_expr "$expr" || rc=$?
      case $rc in
        0) in_conditional=1 ;;
        1) in_conditional=2 ;;
        2) return 1 ;;  # malformed expr → malformed template
        3) return 3 ;;  # strict-mode fact-miss
        *) printf 'template: eval_expr returned unexpected rc=%d\n' "$rc" >&2; return 1 ;;
      esac
      continue
    fi

    # Body line.
    if [ "$in_conditional" = "2" ]; then
      # Inside a skipped block — drop the line.
      continue
    fi

    local rendered
    local rc=0
    rendered=$(template_substitution::_substitute_vars "$line") || rc=$?
    case "$rc" in
      0) ;;
      2) return 1 ;;  # malformed fact key in template body → malformed template
      3) return 3 ;;  # strict-mode unset fact
      *) return $rc ;;
    esac
    printf '%s\n' "$rendered"
  done < "$source"

  if [ "$in_conditional" != "0" ]; then
    printf 'template: %s: unclosed `>>> if` (opened at line %d)\n' \
      "$source" "$conditional_lineno" >&2
    return 1
  fi
}

# Render to a destination file atomically.
#
# Atomicity contract: the destination either contains the fully-
# rendered output OR is unchanged from its prior state — never a
# partial write. Implemented by rendering into a sibling temp file
# and `mv`-renaming it over the destination. The temp file lives in
# `$(dirname "$dest")` (NOT $TMPDIR) so the rename is guaranteed to
# stay on the same filesystem; a cross-filesystem mv would degrade
# to copy+unlink, breaking atomicity under interrupt (CodeRabbit
# Major / Codex P2 on PR #313).
#
# mv failure (permission, ENOSPC, racing process) is checked
# explicitly — without that, render_to could return 0 with no
# destination write, silently losing the rendered output.
#
# Mode preservation: if the destination already exists, its file
# mode is captured before the rename and re-applied after, so a
# pre-existing executable or world-readable file keeps its bits
# rather than inheriting mktemp's 0600 (Codex P2 round 2 on PR
# #313). When dest doesn't yet exist, the temp file's 0600 mode
# stands — callers that need a specific mode on a new file set it
# explicitly after rendering.
template_substitution::render_to() {
  local source=$1
  local dest=$2
  local dest_dir
  dest_dir=$(dirname "$dest")
  if [ ! -d "$dest_dir" ]; then
    printf 'template: destination directory not found: %s\n' "$dest_dir" >&2
    return 2
  fi
  # Capture existing dest mode (if any) before render — we need it
  # before the rename clobbers the dest inode. `stat -c` is GNU/
  # Linux; `stat -f` is BSD/macOS. Try GNU first because that's the
  # CI runner — and crucially because GNU `stat -f` means "filesystem
  # status" (not "format"), so a BSD-first fallback chain writes
  # filesystem text to stdout on Linux before failing, contaminating
  # dest_mode with multi-line garbage (Codex P1 round 3 on PR #313).
  # GNU `stat -c '%a'` and BSD `stat -f '%Mp%Lp'` both yield the
  # mode in a chmod-acceptable form (e.g. "644" or "0644").
  local dest_mode=""
  if [ -e "$dest" ]; then
    dest_mode=$(stat -c '%a' "$dest" 2>/dev/null \
                || stat -f '%Mp%Lp' "$dest" 2>/dev/null \
                || printf '')
  fi
  local tmp
  tmp=$(mktemp "$dest_dir/.template-render.XXXXXX")
  local rc=0
  template_substitution::render "$source" >"$tmp" || rc=$?
  if [ "$rc" != "0" ]; then
    rm -f "$tmp"
    return $rc
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    printf 'template: mv failed writing %s\n' "$dest" >&2
    return 1
  fi
  # Re-apply captured mode. chmod failure is non-fatal — the content
  # is already correctly written, and a mode-preservation failure is
  # less bad than reporting a render failure when the render itself
  # succeeded. Surfaced via stderr only.
  if [ -n "$dest_mode" ]; then
    chmod "$dest_mode" "$dest" 2>/dev/null \
      || printf 'template: warning: failed to restore mode %s on %s\n' \
           "$dest_mode" "$dest" >&2
  fi
}

# Inline self-check: if invoked directly as a script (not sourced),
# enable strict mode (safe because nothing else is sourcing us) and
# emit a usage hint. Matches the convention used by other lib files
# under scripts/lib/. Strict mode is intentionally NOT enabled at
# file scope; see the comment near the top of this file.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  cat >&2 <<EOF
$(basename "$0") is a library. Source it from another bash script:

  source "scripts/lib/template-substitution.sh"
  template_substitution::render path/to/source.template

See docs/agents/templated-propagation.md for the syntax reference.
EOF
  exit 2
fi
