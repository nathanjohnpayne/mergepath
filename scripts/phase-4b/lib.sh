#!/usr/bin/env bash
# scripts/phase-4b/lib.sh — shared helpers for the Phase 4b automated
# review handoff (orchestrator + reviewer adapters).
#
# REFERENCE IMPLEMENTATION (#<this-feature>). Sourced, not executed; it
# does NOT set -euo pipefail on the caller. Bash 3.2 portable (macOS).
#
# Provides: config readers for the phase_4b_automation block and the
# top-level reviewer fields in .github/review-policy.yml, reviewer/
# direction selection, JSON-verdict validation (a jq mirror of
# verdict.schema.json), and small logging helpers. See
# plans/automated-phase-4b-handoff.md for the design.

# --- logging ---------------------------------------------------------------

p4b_log()  { echo "[phase-4b] $*" >&2; }
p4b_warn() { echo "[phase-4b] WARN: $*" >&2; }
# p4b_die <exit-code> <message...>
p4b_die()  { local c="$1"; shift; echo "[phase-4b] ERROR: $*" >&2; exit "$c"; }

# --- config location -------------------------------------------------------

# This library's own directory, captured at SOURCE time (when BASH_SOURCE is
# reliable — unlike call-time inside a function). Files that ship alongside
# lib.sh (e.g. verdict.schema.json) are resolved relative to this, so they
# are found regardless of $PWD or how the caller was invoked.
P4B_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the repo root from this library's own location (follow symlinks),
# NOT $PWD — the same posture scripts/phase-4b-classifier.sh uses so a
# PATH-symlinked or subdir invocation still finds the policy file.
p4b_repo_root() {
  local src="${BASH_SOURCE[0]}" link
  while [ -L "$src" ]; do
    link="$(readlink "$src")"
    case "$link" in
      /*) src="$link" ;;
      *)  src="$(cd -P "$(dirname "$src")" && pwd)/$link" ;;
    esac
  done
  # lib.sh lives at <root>/scripts/phase-4b/lib.sh → root is two dirs up.
  ( cd -P "$(dirname "$src")/../.." && pwd )
}

# The policy file. Overridable via MERGEPATH_REVIEW_POLICY_PATH (tests).
p4b_config() {
  if [ -n "${MERGEPATH_REVIEW_POLICY_PATH:-}" ]; then
    printf '%s' "$MERGEPATH_REVIEW_POLICY_PATH"
    return 0
  fi
  printf '%s/.github/review-policy.yml' "$(p4b_repo_root)"
}

# --- YAML readers (awk; mirrors the codex_field/policy_top_field style) ----

# p4b_automation_field <field> — scalar under the top-level
# `phase_4b_automation:` block. Empty string if absent; caller defaults.
# Nesting-aware (#615 Codex round 3): only DIRECT children of the block
# match. The block carries nested sub-blocks (e.g. `accounting.enabled`),
# and the previous flat scan matched a nested key as the parent-level
# field — a downstream policy that omitted or reordered the parent
# `enabled` would read the accounting sub-toggle as the master switch and
# wrongly run the orchestrator. The direct-child indent is captured from
# the first key line inside the block (so 2- and 4-space styles both
# work); deeper-indented lines belong to sub-blocks and never match —
# sub-block readers (p4b_acct_config_field, mirroring codex_p1_gate_field)
# own those.
p4b_automation_field() {
  local field="$1" cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk -v field="$field" '
    /^phase_4b_automation:/ { inblk=1; child_indent=-1; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      indent = match($0, /[^[:space:]]/) - 1
      if (child_indent < 0) child_indent = indent
      if (indent > child_indent) next
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^["\047]/, "", $0)
        gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print; exit
      }
    }
  ' "$cfg"
}

# p4b_top_field <field> — a column-0 top-level scalar (author_identity,
# default_external_reviewer, phase_4b_default, ...).
p4b_top_field() {
  local field="$1" cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk -v field="$field" '
    /^[^[:space:]#]/ && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print; exit
    }
  ' "$cfg"
}

# --- reviewer CLI runtime bounds: timeout + effort (#589) -------------------

# Conservative defaults preserve the historical hard-coded behavior (a 900s
# timeout, Claude effort medium, Codex effort unset/no-op).
P4B_DEFAULT_ADAPTER_TIMEOUT_SECONDS=900
# Safety bounds for a POLICY-configured timeout. A value outside this range, or
# a non-integer, is rejected fail-closed so a typo (e.g. 90000000) cannot
# effectively unbound the reviewer CLI. The P4B_*_TIMEOUT_SECONDS env overrides
# the orchestrator/adapters honor are a deliberate escape hatch for tests and
# manual runs and are NOT bounded here.
P4B_MIN_ADAPTER_TIMEOUT_SECONDS=1
P4B_MAX_ADAPTER_TIMEOUT_SECONDS=3600

# p4b_resolve_adapter_timeout <adapter>
# Resolve the reviewer CLI timeout (seconds) for <adapter> from policy:
#   phase_4b_automation.<adapter>_timeout_seconds  (per-adapter override)
#   phase_4b_automation.adapter_timeout_seconds    (shared default)
#   P4B_DEFAULT_ADAPTER_TIMEOUT_SECONDS            (900)
# Prints the resolved integer on success. Returns non-zero (no output) when a
# configured value is non-integer or outside [MIN, MAX] so the caller fails
# closed instead of running the CLI mis-bounded. Env overrides are layered on
# by the orchestrator, not here.
p4b_resolve_adapter_timeout() {
  local adapter="$1" val
  val="$(p4b_automation_field "${adapter}_timeout_seconds")"
  [ -n "$val" ] || val="$(p4b_automation_field adapter_timeout_seconds)"
  [ -n "$val" ] || { printf '%s' "$P4B_DEFAULT_ADAPTER_TIMEOUT_SECONDS"; return 0; }
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$val" -lt "$P4B_MIN_ADAPTER_TIMEOUT_SECONDS" ] \
     || [ "$val" -gt "$P4B_MAX_ADAPTER_TIMEOUT_SECONDS" ]; then
    return 1
  fi
  printf '%s' "$val"
}

# p4b_resolve_adapter_effort <adapter>
# Resolve the reviewer CLI effort level for <adapter> from
# phase_4b_automation.<adapter>_effort, validated against that adapter's
# accepted set:
#   claude → low|medium|high|xhigh|max        (maps to `claude --effort`; default medium)
#   codex  → minimal|low|medium|high|xhigh    (maps to `codex -c model_reasoning_effort`;
#                                              default empty = CLI default / no-op)
# Prints the value (possibly empty for codex) on success; returns non-zero on an
# invalid configured value so the caller fails closed.
p4b_resolve_adapter_effort() {
  local adapter="$1" val
  val="$(p4b_automation_field "${adapter}_effort")"
  case "$adapter" in
    claude)
      [ -n "$val" ] || { printf 'medium'; return 0; }
      case "$val" in
        low|medium|high|xhigh|max) printf '%s' "$val" ;;
        *) return 1 ;;
      esac
      ;;
    codex)
      [ -n "$val" ] || return 0   # empty = no -c flag (CLI default)
      case "$val" in
        minimal|low|medium|high|xhigh) printf '%s' "$val" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      # Unknown adapter has no effort knob; any configured value is invalid.
      [ -n "$val" ] && return 1 || return 0
      ;;
  esac
}

# --- feedback-disposition policy (#574-compatible approval gate) -----------

# p4b_feedback_policy_mode — mode under `feedback_policy:`. The absent-block
# default mirrors today's review policy: by-priority with P0/P1 required.
p4b_feedback_policy_mode() {
  local cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || { printf '%s' "by-priority"; return 0; }
  awk '
    /^feedback_policy:/ { inblk=1; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk && $1 == "mode:" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print; exit
    }
  ' "$cfg"
}

# p4b_feedback_priority_value <p0|p1|p2|p3|nitpick>
# Returns the configured disposition value under feedback_policy.priorities,
# or the parser default if absent: P0/P1 required, lower tiers discretionary.
p4b_feedback_priority_value() {
  local tier="$1" cfg value
  cfg="$(p4b_config)"
  if [ -f "$cfg" ]; then
    value="$(
      awk -v tier="$tier" '
        /^feedback_policy:/ { inblk=1; inprio=0; next }
        inblk && /^[^[:space:]#]/ { inblk=0; inprio=0 }
        inblk && /^[[:space:]]+priorities:/ { inprio=1; next }
        inprio {
          line=$0
          gsub(/[[:space:]]*#.*$/, "", line)
          if (line ~ /^[[:space:]]*$/) next
          indent = match(line, /[^[:space:]]/) - 1
          if (indent <= 2) { inprio=0; next }
          key=line
          sub(/^[[:space:]]*/, "", key)
          sub(/:.*/, "", key)
          if (key == tier) {
            sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
            gsub(/^["\047]/, "", line)
            gsub(/["\047][[:space:]]*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line; exit
          }
        }
      ' "$cfg"
    )"
  fi
  if [ -n "${value:-}" ]; then
    printf '%s' "$value"
    return 0
  fi
  case "$tier" in
    p0|p1) printf '%s' "required" ;;
    p2|p3|nitpick) printf '%s' "discretionary" ;;
    *) return 1 ;;
  esac
}

# p4b_required_verdict_severities_json
# Returns a JSON array of verdict severities that cannot appear in an
# APPROVED response. Phase 4b adapter verdicts use P0-P3; CodeRabbit-only
# nitpick policy applies to the CodeRabbit gate, not this schema.
p4b_required_verdict_severities_json() {
  local mode tier value first=true
  mode="$(p4b_feedback_policy_mode)"
  mode="${mode:-by-priority}"
  case "$mode" in
    address-all)
      printf '%s' '["P0","P1","P2","P3"]'
      return 0
      ;;
    by-priority) ;;
    *) return 1 ;;
  esac

  printf '['
  for tier in p0 p1 p2 p3; do
    value="$(p4b_feedback_priority_value "$tier")" || return 1
    case "$value" in
      required)
        if [ "$first" = true ]; then first=false; else printf ','; fi
        printf '"%s"' "$(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]')"
        ;;
      discretionary|ignore) ;;
      *) return 1 ;;
    esac
  done
  printf ']'
}

# p4b_available_reviewers — newline-separated list items under
# `available_reviewers:`.
p4b_available_reviewers() {
  local cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk '
    /^available_reviewers:/ { inlist=1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["\047]/, "", line); gsub(/["\047][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
      next
    }
    inlist && /^[^[:space:]#-]/ { inlist=0 }
  ' "$cfg"
}

# --- identity / direction helpers ------------------------------------------

# Strip the reviewer-login prefix to get the agent short name.
#   nathanpayne-codex -> codex ; claude -> claude
p4b_agent_of_login() {
  local login
  login="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$login" in
    nathanpayne-*) printf '%s' "${login#nathanpayne-}" ;;
    *)             printf '%s' "$login" ;;
  esac
}

# Map an agent short name to a reviewer login. A value already in login
# form (contains a dash) is passed through unchanged.
p4b_login_of_agent() {
  case "$1" in
    *-*) printf '%s' "$1" ;;
    *)   printf 'nathanpayne-%s' "$1" ;;
  esac
}

# Map a reviewer login (or agent) to an adapter name.
#   nathanpayne-codex -> codex ; nathanpayne-claude -> claude
# Unknown agents echo their agent name; the orchestrator treats anything
# without a review-via-<name>.sh adapter as unsupported (manual fallback).
p4b_adapter_of_login() { p4b_agent_of_login "$1"; }

p4b_adapter_dir() {
  if [ -n "${P4B_ADAPTER_DIR:-}" ]; then
    printf '%s' "$P4B_ADAPTER_DIR"
    return 0
  fi
  printf '%s/scripts/phase-4b/adapters' "$(p4b_repo_root)"
}

p4b_adapter_supported_for_login() {
  local adapter
  adapter="$(p4b_adapter_of_login "$1")"
  [ -x "$(p4b_adapter_dir)/review-via-${adapter}.sh" ]
}

p4b_available_reviewer_contains() {
  local needle="$1" r
  while IFS= read -r r; do
    [ "$r" = "$needle" ] && return 0
  done <<EOF
$(p4b_available_reviewers)
EOF
  return 1
}

# p4b_select_reviewer <author-agent-or-login>
# Echo the external reviewer login: a member of available_reviewers whose
# agent differs from the author and has a local adapter, preferring
# default_external_reviewer.
# Exit 1 (no echo) if none can be found.
p4b_select_reviewer() {
  local author_in="$1" author_agent default def_agent r r_agent
  author_agent="$(p4b_agent_of_login "$author_in")"

  default="$(p4b_top_field default_external_reviewer)"
  if [ -n "$default" ] && p4b_available_reviewer_contains "$default"; then
    def_agent="$(p4b_agent_of_login "$default")"
    if [ "$def_agent" != "$author_agent" ] && p4b_adapter_supported_for_login "$default"; then
      printf '%s' "$default"; return 0
    fi
  fi

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    r_agent="$(p4b_agent_of_login "$r")"
    if [ "$r_agent" != "$author_agent" ] && p4b_adapter_supported_for_login "$r"; then
      printf '%s' "$r"; return 0
    fi
  done <<EOF
$(p4b_available_reviewers)
EOF
  return 1
}

# --- verdict validation (structural contract derived from the schema) ------

# p4b_verdict_schema_path — location of verdict.schema.json, the single
# source of truth for the verdict's structural contract. It ships alongside
# this library, so it is resolved relative to P4B_LIB_DIR (captured at source
# time). Overridable via P4B_VERDICT_SCHEMA_PATH (tests / non-standard layouts).
p4b_verdict_schema_path() {
  if [ -n "${P4B_VERDICT_SCHEMA_PATH:-}" ]; then
    printf '%s' "$P4B_VERDICT_SCHEMA_PATH"
    return 0
  fi
  printf '%s/verdict.schema.json' "$P4B_LIB_DIR"
}

# p4b_validate_verdict <json-string>
# Returns 0 iff the string is a verdict object conforming to
# verdict.schema.json's required shape plus the semantic invariants that
# keep a posted APPROVED review from clearing a PR while still carrying
# blocking findings. Fail-closed: any deviation, empty input, missing or
# malformed schema, or jq error returns non-zero. No stdout.
#
# Drift resistance (#585): the structural constants most likely to drift —
# the top-level key set, the verdict enum, the per-finding key set, the
# severity enum, and the usage key set — are read FROM the schema at
# validation time rather than hand-mirrored in this jq program. Changing a
# key or enum value in verdict.schema.json therefore reconfigures the
# validator automatically, and tests/test_phase_4b_automation.sh adds
# schema-vs-validator parity fixtures as defense in depth. The remaining
# checks encode semantics the JSON Schema cannot express on its own: the
# config-dependent feedback_policy approval gate, the all-or-nothing usage
# object, and the 1-based line bound.
p4b_validate_verdict() {
  local json="$1" required_severities schema
  [ -n "$json" ] || return 1
  required_severities="$(p4b_required_verdict_severities_json)" || return 1
  schema="$(p4b_verdict_schema_path)"
  [ -r "$schema" ] || return 1
  printf '%s' "$json" | jq -e \
      --argjson required_severities "$required_severities" \
      --slurpfile schema_doc "$schema" '
    # Structural constants, derived from verdict.schema.json (single source
    # of truth). A missing/empty schema slurp makes these error → jq exits
    # non-zero → validation fails closed.
    ($schema_doc[0]) as $s
    | ($s.required | sort) as $top_keys
    | ($s.properties.verdict.enum) as $verdict_enum
    | ($s.properties.findings.items.required | sort) as $finding_keys
    | ($s.properties.findings.items.properties.severity.enum) as $severity_enum
    | ($s.properties.usage.required | sort) as $usage_keys
    | ($s.properties.usage.properties | keys | sort) as $usage_all_keys
    | def okstr: (type == "string") and (length > 0);
      def okintnull: (. == null) or (type == "number" and floor == . and . >= 0);
      # Guard the derived constants are the right SHAPE first. `sort` already
      # errors (→ fail closed) if a required-key field is not an array, but the
      # enums are consumed with `index`, which on a STRING does a substring
      # search instead of array membership — a malformed schema (or a hostile
      # P4B_VERDICT_SCHEMA_PATH) with an enum as a scalar would then wrongly
      # accept "APPROVED"/"P1". Assert array shape so a bad schema fails closed.
      (($verdict_enum | type) == "array")
      and (($severity_enum | type) == "array")
      and (($top_keys | type) == "array")
      and (($finding_keys | type) == "array")
      and (($usage_keys | type) == "array")
      and ((keys_unsorted | sort) == $top_keys)
      and ((.verdict) as $v | ($verdict_enum | index($v)) != null)
      and (.summary | okstr)
      and (.findings | type == "array")
      and all(.findings[]?;
            ((keys_unsorted | sort) == $finding_keys)
            and ((.severity) as $sv | ($severity_enum | index($sv)) != null)
            and ((.path == null) or (.path | type == "string"))
            and ((.line == null) or (.line | type == "number" and floor == . and . >= 1))
            and (.body | okstr))
      and ((.verdict != "APPROVED")
           or all(.findings[]?; (.severity as $s2 | ($required_severities | index($s2) | not))))
      # usage: the schema-required keys must all be present, any other key
      # must be one the schema DECLARES (the additive optional #602 fields),
      # and every field must type-check. This mirrors the JSON Schema exactly:
      # required ⊆ keys ⊆ properties, additionalProperties: false.
      and ((.usage == null)
           or ((.usage | type == "object")
               and ((.usage | keys_unsorted | sort) as $uk
                    | (($usage_keys - $uk) == []) and (($uk - $usage_all_keys) == []))
               and (.usage.token_count | okintnull)
               and (.usage.input_tokens | okintnull)
               and (.usage.output_tokens | okintnull)
               # Optional #602 fields: plain `.usage.X` yields null for an
               # ABSENT key (accepted), while a PRESENT wrong-typed value must
               # fail the type check. Never `// null` here — the jq alternative
               # operator treats `false` as absent, so a boolean field
               # (cache_read_input_tokens:false) would silently pass (#615
               # Codex; the known repo `//`-vs-false footgun).
               and (.usage.cache_creation_input_tokens | okintnull)
               and (.usage.cache_read_input_tokens | okintnull)
               and (.usage.reasoning_tokens | okintnull)
               and (.usage.total_cost_usd as $c
                    | ($c == null) or (($c | type) == "number" and $c >= 0))
               and (.usage.source | okstr)))
  ' >/dev/null 2>&1
}

# p4b_extract_json_block <text>
# Emit the SOLE complete, balanced, top-level JSON object embedded in the text.
# Used by the Claude adapter, whose model output may wrap the JSON in prose.
# Leaves already-pure JSON unchanged.
#
# Implementation (#587): a string-aware brace-depth scanner, not a naive
# first-"{"-to-last-"}" slice. It tracks JSON string literals (honoring \" and
# \\ escapes) so braces inside string VALUES do not change nesting depth, and
# it isolates the first balanced top-level object — so balanced-brace prose
# after the JSON object can no longer extend the slice and poison extraction.
#
# It then requires that to be the ONLY top-level object: if a second `{` opens
# outside a string in the remainder, the output is ambiguous (e.g. a draft
# APPROVED followed by a corrected CHANGES_REQUESTED) and this emits nothing so
# downstream schema validation fails closed rather than silently posting the
# first verdict (#594 Codex). Markdown code fences alone on a line are stripped
# first. Unbalanced, object-free, or multi-object input all emit nothing.
p4b_extract_json_block() {
  printf '%s\n' "$1" \
    | sed -e 's/^```[A-Za-z0-9]*[[:space:]]*$//' -e 's/^```[[:space:]]*$//' \
    | awk '
        { buf = buf $0 "\n" }
        END {
          n = length(buf)
          start = index(buf, "{")
          if (start == 0) exit 0
          depth = 0; instr = 0; esc = 0; endpos = 0
          for (i = start; i <= n; i++) {
            c = substr(buf, i, 1)
            if (instr) {
              if (esc)       { esc = 0;   continue }   # this char is escaped
              if (c == "\\") { esc = 1;   continue }   # begin escape sequence
              if (c == "\"") { instr = 0; continue }   # end of string literal
              continue                                  # any other in-string char
            }
            if (c == "\"") { instr = 1; continue }     # begin string literal
            if (c == "{")  { depth++ }
            else if (c == "}") {
              depth--
              if (depth == 0) { endpos = i; break }    # first object closed
            }
          }
          if (endpos == 0) exit 0                       # unbalanced → fail closed
          # Reject a SECOND top-level object in the remainder (string-aware):
          # ambiguous multi-verdict output must fail closed, not take the first.
          instr = 0; esc = 0
          for (i = endpos + 1; i <= n; i++) {
            c = substr(buf, i, 1)
            if (instr) {
              if (esc)       { esc = 0;   continue }
              if (c == "\\") { esc = 1;   continue }
              if (c == "\"") { instr = 0; continue }
              continue
            }
            if (c == "\"") { instr = 1; continue }
            if (c == "{")  { exit 0 }                   # second object → fail closed
          }
          printf "%s", substr(buf, start, endpos - start + 1)
        }'
}

# p4b_run_with_timeout <seconds> <command> [args...]
# Portable bounded execution for reviewer CLIs/adapters. GNU coreutils
# `timeout` is common on Linux; macOS has perl, and the inherited alarm
# timer survives exec so the target process is still bounded.
p4b_run_with_timeout() {
  local seconds="$1"
  shift
  case "$seconds" in
    ''|0) "$@"; return $? ;;
    *[!0-9]*) p4b_die 3 "timeout seconds must be a non-negative integer; got '$seconds'" ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return $?
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$seconds" "$@"
    return $?
  fi
  p4b_die 3 "bounded review execution requires GNU timeout or perl"
}

p4b_is_timeout_rc() {
  case "$1" in
    124|142) return 0 ;;
    *)       return 1 ;;
  esac
}

# --- plan-only reviewer CLI auth guards ------------------------------------

p4b_codex_auth_file() {
  if [ -n "${P4B_CODEX_AUTH_FILE:-}" ]; then
    printf '%s' "$P4B_CODEX_AUTH_FILE"
    return 0
  fi
  if [ -n "${CODEX_HOME:-}" ]; then
    printf '%s/auth.json' "$CODEX_HOME"
    return 0
  fi
  printf '%s/.codex/auth.json' "$HOME"
}

p4b_require_codex_plan_auth() {
  local auth_file mode
  auth_file="$(p4b_codex_auth_file)"
  [ -r "$auth_file" ] || p4b_die 4 "codex plan login not found at $auth_file; run codex login (API-key auth is not allowed for Phase 4b)"
  mode="$(jq -r '.auth_mode // empty' "$auth_file" 2>/dev/null || true)"
  [ "$mode" = "chatgpt" ] || p4b_die 4 "codex auth_mode is '${mode:-unknown}', not 'chatgpt'; API-key auth is not allowed for Phase 4b"
}

p4b_claude_auth_status() {
  local claude_bin="$1"
  if [ -n "${P4B_CLAUDE_AUTH_STATUS_FILE:-}" ]; then
    cat "$P4B_CLAUDE_AUTH_STATUS_FILE"
    return 0
  fi
  "$claude_bin" auth status --json 2>/dev/null
}

p4b_require_claude_plan_auth() {
  local claude_bin="$1" status logged_in auth_method api_provider subscription_type
  status="$(p4b_claude_auth_status "$claude_bin")" \
    || p4b_die 4 "claude plan login status could not be read; run claude auth login (API-key auth is not allowed for Phase 4b)"
  logged_in="$(printf '%s' "$status" | jq -r '.loggedIn // false' 2>/dev/null || true)"
  auth_method="$(printf '%s' "$status" | jq -r '.authMethod // empty' 2>/dev/null || true)"
  api_provider="$(printf '%s' "$status" | jq -r '.apiProvider // empty' 2>/dev/null || true)"
  subscription_type="$(printf '%s' "$status" | jq -r '.subscriptionType // empty' 2>/dev/null || true)"
  [ "$logged_in" = "true" ] || p4b_die 4 "claude is not logged in; run claude auth login (API-key auth is not allowed for Phase 4b)"
  case "$auth_method" in
    claude.ai|oauth_token) ;;
    *) p4b_die 4 "claude authMethod is '${auth_method:-unknown}', not a first-party subscription method; API-key auth is not allowed for Phase 4b" ;;
  esac
  [ "$api_provider" = "firstParty" ] || p4b_die 4 "claude apiProvider is '${api_provider:-unknown}', not 'firstParty'; API-key auth is not allowed for Phase 4b"
  if [ "$auth_method" = "claude.ai" ]; then
    [ -n "$subscription_type" ] && [ "$subscription_type" != "null" ] \
      || p4b_die 4 "claude subscriptionType is missing; a Claude Code subscription login is required for Phase 4b"
  fi
}
