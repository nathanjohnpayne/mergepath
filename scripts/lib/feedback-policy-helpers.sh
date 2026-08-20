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
#   codex_tiers_of "<comment-body>"        # every p0..p3 marker, in order
#   coderabbit_tier_of "<comment-body>"    # p0..p3|nitpick or empty
#   coderabbit_tiers_of "<comment-body>"   # every graded marker, in order
#   coderabbit_finding_scan "<body>"       # strip fenced/pre-merge regions
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
# (nathanpayne-codex Phase 4b on #581). `codex_tiers_of` exposes the same
# canonical markers in document order for callers that intentionally model a
# compound top-level body.
codex_tiers_of() {
  local body=${1:-} markers marker n
  markers=$(printf '%s' "$body" | grep -oE '!\[P[0-3] Badge\]|\*\*P[0-3]' || true)
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    n=$(printf '%s' "$marker" | sed -E 's/.*P([0-3]).*/\1/')
    echo "p$n"
  done <<EOF
$markers
EOF
}

codex_tier_of() {
  local tiers
  # Keep the single-finding contract: the first marker wins. The all-marker
  # primitive above exists for compound top-level review surfaces.
  tiers=$(codex_tiers_of "${1:-}")
  [ -n "$tiers" ] || return 0
  printf '%s\n' "$tiers" | sed -n '1p'
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
#   🧹 Nitpick                                     → nitpick
#   🔵 Trivial / Outside diff range                → p3
#   🟡 Minor                                       → p2
# Anything else (Refactor suggestion, plain Note, bare titlecase prose) → empty.
#
# CodeRabbit's other machine-readable signal — the `cr-indicator-types` tag it
# appends to a finding body — is deliberately NOT graded here. Grading it needs
# a definition of where one finding's stanza ends, because CodeRabbit renders a
# finding's badge and its tag on different lines and both merge-relevant
# callers grade a PR-level summary line by line; four successive framings of
# that boundary produced four defects on #936. It is [#945](https://github.com/nathanjohnpayne/mergepath/issues/945),
# with a spec-derived matrix, and #888 stays open for it.
coderabbit_finding_scan() {
  local body=${1:-} out
  out=$(printf '%s\n' "$body" | awk \
    -v block_start='<!-- pre_merge_checks_walkthrough_start -->' \
    -v block_end='<!-- pre_merge_checks_walkthrough_end -->' '
      function fence_info(s, out,   c, n) {
        sub(/^ ? ? ?/, "", s)
        c = substr(s, 1, 1)
        if (c != "`" && c != "~") return 0
        n = 0
        while (substr(s, n + 1, 1) == c) n++
        if (n < 3) return 0
        out["rest"] = substr(s, n + 1)
        if (c == "`" && index(out["rest"], "`") > 0) return 0
        out["char"] = c
        out["len"] = n
        return 1
      }
      function fence_update(line,   info) {
        if (!fence_info(line, info)) return 0
        if (!in_fence) {
          in_fence = 1
          fence_char = info["char"]
          fence_len = info["len"]
          return 1
        }
        if (info["char"] == fence_char && info["len"] >= fence_len \
            && info["rest"] ~ /^[ \t]*$/) {
          in_fence = 0
          fence_char = ""
          fence_len = 0
        }
        return 1
      }
      {
        line = $0
        sub(/\r$/, "", line)
        lines[NR] = line
        delimiter = fence_update(line)
        visible[NR] = (!delimiter && !in_fence)
        structural = line
        sub(/[ \t]+$/, "", structural)
        # Pair the block on the NEWEST start seen before the end, not the
        # oldest. Anchoring on the first start (the old "&& !start_line")
        # let an unmatched start earlier in the body swallow everything up to
        # a LATER, properly paired block: a real Major badge sitting between
        # the two was suppressed, and the inventory then reported clear with
        # nothing to disposition (#1000 Codex P1). An unpaired start is not a
        # block, so it must not extend one; re-anchoring keeps the intervening
        # text classified. Still at most one suppressed region per body -- only
        # the first properly closed pair is dropped -- so this can never
        # suppress more than the previous rule did.
        if (visible[NR] && structural == block_start && !end_line) {
          pending_start = NR
        } else if (visible[NR] && structural == block_end \
                   && pending_start && !end_line) {
          start_line = pending_start
          end_line = NR
          pending_start = 0
        }
      }
      END {
        for (i = 1; i <= NR; i++) {
          if (!visible[i]) continue
          if (end_line && i >= start_line && i <= end_line) continue
          print lines[i]
        }
      }
    ') || {
      echo "ERROR: could not sanitize a CodeRabbit finding surface" >&2
      return 2
    }
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}

coderabbit_tiers_of() {
  local body=${1:-} markers marker
  markers=$(printf '%s' "$body" \
    | grep -oE '🟠 Major|Potential issue|⚠️|🧹 Nitpick|🔵 Trivial|Outside diff range|🟡 Minor' || true)
  while IFS= read -r marker; do
    case "$marker" in
      "🟠 Major"|"Potential issue"|"⚠️") echo p1 ;;
      "🟡 Minor") echo p2 ;;
      "🔵 Trivial"|"Outside diff range") echo p3 ;;
      "🧹 Nitpick") echo nitpick ;;
    esac
  done <<EOF
$markers
EOF
}

coderabbit_tier_of() {
  local head tiers wanted
  # Truncate via parameter expansion (not `printf | head -c`): under
  # `set -euo pipefail` a large body makes head close the pipe early and
  # printf exits 141 (SIGPIPE), which aborts every caller. The badge markers
  # matched below are near the start, so a 600-char cut is more than enough.
  head="${1:-}"; head="${head:0:600}"
  tiers=$(coderabbit_tiers_of "$head")
  for wanted in p1 nitpick p3 p2; do
    if printf '%s\n' "$tiers" | grep -Fxq "$wanted"; then
      echo "$wanted"
      return 0
    fi
  done
  return 0
}
