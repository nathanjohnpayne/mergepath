# scripts/lib/feedback-policy-helpers.sh
#
# Shared reader + classifiers for the `feedback_policy` block in
# .github/review-policy.yml (nathanjohnpayne/mergepath#574, sub-issue #576).
#
# `feedback_policy` controls WHICH bot-review findings must be dispositioned
# (fixed OR rebutted + thread resolved) before merge, by normalized severity
# tier. This file is the single source of truth that both severity gates
# (scripts/codex-p1-gate.sh and the #577 scripts/coderabbit-severity-gate.sh)
# and the wait/request helpers consult, so the tier vocabulary and the
# blocking-set resolution cannot drift between them.
#
# NOTE: this is the FOUNDATION (#576). It ships the readers + classifiers and
# unit tests; nothing consumes them to BLOCK a merge yet — the gates that act
# on `resolve_required_tiers` land in #577. So sourcing this file is inert.
#
# Sourcing contract: NO top-level side effects, only function defs.
# Bash 3.2 portable (no mapfile, no associative arrays). Pure awk/sed/grep —
# no yq, no gh, no network. Fail closed.
#
#   source scripts/lib/feedback-policy-helpers.sh
#   feedback_policy_field <key> [cfg]      # scalar under feedback_policy:
#   resolve_required_tiers [cfg]           # one blocking tier per line
#   codex_tier_of "<comment-body>"         # p0..p3 or empty
#   coderabbit_tier_of "<comment-body>"    # p0..p3|nitpick or empty
#
# cfg defaults to $CONFIG (the global the gate scripts set) and then to
# .github/review-policy.yml, matching scripts/lib/reviewers-helpers.sh.
#
# The normalized ladder (see REVIEW_POLICY.md § Feedback Disposition Policy):
#   p0  critical   p1  high   p2  minor   p3  trivial   nitpick  style
# Codex maps EXACTLY (badge markers); CodeRabbit maps HEURISTICALLY (category
# + Critical/Major/Minor qualifier — it has no numeric scale).

# Read a scalar field directly under the feedback_policy: block. Mirrors the
# block-scoped awk reader used by codex_field (scripts/codex-p1-gate.sh) and
# the sed normalization used by read_available_reviewers
# (scripts/lib/reviewers-helpers.sh): strip the `key:` prefix in awk, then
# strip a trailing inline comment, surrounding quotes (single OR double), and
# trailing whitespace in sed. Every key under feedback_policy: is unique
# (mode, priorities, p0..p3, nitpick), so an exact-name match is unambiguous.
feedback_policy_field() {
  local field=$1 cfg="${2:-${CONFIG:-.github/review-policy.yml}}"
  [ -f "$cfg" ] || return 0
  awk -v field="$field" '
    /^feedback_policy:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ' "$cfg" | sed -E "s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]+$//"
}

# Emit the gate's BLOCKING tier set, one tier per line.
#
#   feedback_policy block ABSENT  -> "p1" only. This preserves today's
#       gate behavior byte-for-byte: before #574 the only enforced tier was
#       Codex P1 (scripts/codex-p1-gate.sh). Disposition DEFAULTS (p0/p1
#       required for the agent) are a separate, prose-level concept; this
#       function is specifically the merge-gate blocking set.
#   mode: address-all             -> every tier (p0 p1 p2 p3 nitpick).
#   mode: by-priority (default)   -> the tiers whose value is `required`.
#
# A present block with `by-priority` and a tier left unset treats that tier as
# discretionary (not required) — an explicit block is an explicit opt-in.
# Fails closed (return 2) on a malformed mode or tier value.
resolve_required_tiers() {
  local cfg="${1:-${CONFIG:-.github/review-policy.yml}}"
  if [ ! -f "$cfg" ] || ! grep -qE '^feedback_policy:' "$cfg"; then
    echo p1
    return 0
  fi

  local mode tier val
  mode=$(feedback_policy_field mode "$cfg")
  mode=${mode:-by-priority}

  case "$mode" in
    address-all)
      printf '%s\n' p0 p1 p2 p3 nitpick
      ;;
    by-priority)
      for tier in p0 p1 p2 p3 nitpick; do
        val=$(feedback_policy_field "$tier" "$cfg")
        case "$val" in
          ""|required|discretionary|ignore) ;;
          *)
            echo "ERROR: feedback_policy.priorities.$tier must be required|discretionary|ignore; got '$val'" >&2
            return 2
            ;;
        esac
        [ "$val" = required ] && echo "$tier"
      done
      ;;
    *)
      echo "ERROR: feedback_policy.mode must be by-priority|address-all; got '$mode'" >&2
      return 2
      ;;
  esac
}

# Map a Codex finding body to a tier, or empty if it carries no Codex priority
# marker. EXACT match: the badge image `![P0 Badge]`..`![P3 Badge]` (the form
# scripts/codex-p1-gate.sh and scripts/codex-record-feedback.sh already parse),
# then the text fallback `**P0`..`**P3` Codex emits when the badge image is
# absent. First marker wins.
codex_tier_of() {
  local body=${1:-} n
  n=$(printf '%s' "$body" | sed -nE 's/.*\!\[P([0-3]) Badge\].*/\1/p' | head -n1)
  [ -z "$n" ] && n=$(printf '%s' "$body" | sed -nE 's/.*\*\*P([0-3]).*/\1/p' | head -n1)
  [ -n "$n" ] && echo "p$n"
  return 0
}

# Map a CodeRabbit finding body to a tier, or empty if it is not a gradeable
# finding (a plain Note / verification comment). HEURISTIC: CodeRabbit has no
# numeric scale, so we read its category marker plus an optional
# Critical/Major/Minor qualifier (see REVIEW_POLICY.md § Feedback Disposition
# Policy mapping table). Best-effort — the #577 gate validates this against
# real CodeRabbit fixtures and may refine it.
#
# This MIRRORS classify_severity in scripts/lib/daily-feedback-rollup-helpers.sh
# — the repo's canonical CodeRabbit badge parser — kept as a separate mapping to
# avoid cross-lib coupling (a future refactor may extract one shared severity
# module). Anchored on the first 600 chars (the badge sits near the top; deeper
# prose must not false-match) and ordered highest-confidence first.
#
# CodeRabbit canonical badges → tier:
#   🟠 Major / Potential issue / ⚠️  → p1   (CodeRabbit's top severity; p0 is
#                                            Codex-only, so CodeRabbit never maps
#                                            to p0 — matches classify_severity)
#   🧹 Nitpick                       → nitpick
#   🔵 Trivial / Outside diff range  → p3
#   🟡 Minor                         → p2
# Anything else (Refactor suggestion, plain Note, a stray "security" mention in
# prose) is unclassified → empty. Keying off the badge, NOT prose keywords, is
# deliberate: a refactor whose text mentions "security" must not escalate to p0
# (Codex P2 #581 r2), and a Major finding whose prose says "minor" must not
# downgrade (Codex P2 #581 r1).
coderabbit_tier_of() {
  local head
  head=$(printf '%s' "${1:-}" | head -c 600)
  case "$head" in
    *"🟠 Major"*|*"Potential issue"*|*"⚠️"*)          echo p1; return 0 ;;
    *"🧹 Nitpick"*|*Nitpick*)                          echo nitpick; return 0 ;;
    *"🔵 Trivial"*|*Trivial*|*"Outside diff range"*)   echo p3; return 0 ;;
    *"🟡 Minor"*|*Minor*)                              echo p2; return 0 ;;
  esac
  return 0
}
