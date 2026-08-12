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
# marker. Matches the badge image `![P0 Badge]`..`![P3 Badge]` (the form
# scripts/codex-p1-gate.sh and scripts/codex-record-feedback.sh already parse)
# and the text fallback `**P0`..`**P3` Codex emits when the badge image is
# absent. The FIRST marker in document order wins across BOTH forms — a
# blocking P1 must not be downgraded by a later P2/P3 in quoted/example text
# (nathanpayne-codex Phase 4b on #581). grep -oE emits matches in position
# order; head -n1 takes the earliest.
codex_tier_of() {
  local body=${1:-} marker n
  # Status-safe under `set -euo pipefail`: grep exits 1 on no match (and can
  # take SIGPIPE from `head`), which with pipefail would fail the assignment
  # and abort a caller doing `tier=$(codex_tier_of "$b")` before this function
  # returns. `|| true` keeps a markerless body as a clean empty result, rc 0
  # (nathanpayne-codex Phase 4b P1 on #581). Split into extract-then-parse so
  # the failable grep is isolated from the always-succeeding sed.
  marker=$(printf '%s' "$body" | grep -oE '!\[P[0-3] Badge\]|\*\*P[0-3]' | head -n1 || true)
  [ -n "$marker" ] || return 0
  n=$(printf '%s' "$marker" | sed -E 's/.*P([0-3]).*/\1/')
  echo "p$n"
}

# Map a CodeRabbit finding body to a tier, or empty if it is not a gradeable
# finding (a plain Note / prose comment). CodeRabbit has no numeric scale, so
# we read its category/severity MARKERS.
#
# Derived from classify_severity in scripts/lib/daily-feedback-rollup-helpers.sh
# (the repo's canonical CodeRabbit badge parser) but STRICTER: it matches ONLY
# the actual markers — the emoji badges and the distinctive "Potential issue" /
# "Outside diff range" category phrases — and DROPS classify_severity's
# bare-titlecase fallbacks. A bare `Minor`/`Trivial`/`Nitpick` word in plain
# prose must NOT be classified, per this helper's contract that unknown/
# plain-note shapes stay unclassified (nathanpayne-codex Phase 4b P1 on #581: a
# bare-word match would let the #577 gate block/clear the wrong tier, and a
# Minor badge whose prose says "Trivial" must stay p2). Anchored on the first
# 600 chars (the marker sits near the top), ordered highest-confidence first.
#
# CodeRabbit markers → tier (p0 is Codex-only; CodeRabbit never maps to p0):
#   🟠 Major / Potential issue / ⚠️  → p1
#   🧹 Nitpick                       → nitpick
#   🔵 Trivial / Outside diff range  → p3
#   🟡 Minor                         → p2
# Anything else (Refactor suggestion, plain Note, bare titlecase prose) → empty.
coderabbit_tier_of() {
  local head
  # Truncate via parameter expansion (not `printf | head -c`): under
  # `set -euo pipefail` a large body makes head close the pipe early and
  # printf exits 141 (SIGPIPE), which aborts every caller. The badge markers
  # matched below are near the start, so a 600-char cut is more than enough.
  head="${1:-}"; head="${head:0:600}"
  case "$head" in
    *"🟠 Major"*|*"Potential issue"*|*"⚠️"*)  echo p1; return 0 ;;
    *"🧹 Nitpick"*)                            echo nitpick; return 0 ;;
    *"🔵 Trivial"*|*"Outside diff range"*)     echo p3; return 0 ;;
    *"🟡 Minor"*)                              echo p2; return 0 ;;
  esac
  return 0
}
