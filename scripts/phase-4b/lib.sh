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
p4b_automation_field() {
  local field="$1" cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk -v field="$field" '
    /^phase_4b_automation:/ { inblk=1; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk {
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
  case "$1" in
    nathanpayne-*) printf '%s' "${1#nathanpayne-}" ;;
    *)             printf '%s' "$1" ;;
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

# p4b_select_reviewer <author-agent-or-login>
# Echo the external reviewer login: a member of available_reviewers whose
# agent differs from the author, preferring default_external_reviewer.
# Exit 1 (no echo) if none can be found.
p4b_select_reviewer() {
  local author_in="$1" author_agent default def_agent r r_agent
  author_agent="$(p4b_agent_of_login "$author_in")"

  default="$(p4b_top_field default_external_reviewer)"
  if [ -n "$default" ]; then
    def_agent="$(p4b_agent_of_login "$default")"
    if [ "$def_agent" != "$author_agent" ]; then
      printf '%s' "$default"; return 0
    fi
  fi

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    r_agent="$(p4b_agent_of_login "$r")"
    if [ "$r_agent" != "$author_agent" ]; then
      printf '%s' "$r"; return 0
    fi
  done <<EOF
$(p4b_available_reviewers)
EOF
  return 1
}

# --- verdict validation (jq mirror of verdict.schema.json) -----------------

# p4b_validate_verdict <json-string>
# Returns 0 iff the string is a verdict object conforming to
# verdict.schema.json's required shape. Fail-closed: any deviation,
# empty input, or jq error returns non-zero. No stdout.
p4b_validate_verdict() {
  local json="$1"
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -e '
    def okstr: (type == "string") and (length > 0);
    ((.verdict == "APPROVED") or (.verdict == "CHANGES_REQUESTED"))
    and (.summary | okstr)
    and (.findings | type == "array")
    and all(.findings[]?;
          (.severity | type == "string" and test("^P[0-3]$"))
          and (.body | okstr))
  ' >/dev/null 2>&1
}

# p4b_extract_json_block <text>
# Best-effort: strip Markdown code fences, then emit the substring from
# the first "{" to the last "}". Leaves already-pure JSON unchanged. Used
# by the Claude adapter, whose model output may wrap the JSON in prose.
p4b_extract_json_block() {
  printf '%s\n' "$1" \
    | sed -e 's/^```[A-Za-z0-9]*[[:space:]]*$//' -e 's/^```[[:space:]]*$//' \
    | awk '
        { buf = buf $0 "\n" }
        END {
          start = index(buf, "{")
          last = 0
          for (i = 1; i <= length(buf); i++) if (substr(buf, i, 1) == "}") last = i
          if (start > 0 && last >= start) printf "%s", substr(buf, start, last - start + 1)
        }'
}
