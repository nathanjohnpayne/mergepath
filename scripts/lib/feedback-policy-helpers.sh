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
#   coderabbit_scan_tiers                  # stdin/stdout, LINE-wise documents
#
# cfg defaults to $CONFIG (the global the gate scripts set) and then to
# .github/review-policy.yml, matching scripts/lib/reviewers-helpers.sh.
#
# The normalized ladder (see REVIEW_POLICY.md § Feedback Disposition Policy):
#   p0  critical   p1  high   p2  minor   p3  trivial   nitpick  style
# Codex maps EXACTLY (badge markers); CodeRabbit maps HEURISTICALLY (category
# + Critical/Major/Minor qualifier — it has no numeric scale), with its
# machine-generated `cr-indicator-types` tag as a last-resort fallback for a
# body that carries no rendered badge at all (#888).

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
#   🔴 Critical / 🟠 Major / Potential issue / ⚠️  → p1
#   🧹 Nitpick                                     → nitpick
#   🔵 Trivial / Outside diff range                → p3
#   🟡 Minor                                       → p2
# Anything else (Refactor suggestion, plain Note, bare titlecase prose) → empty,
# EXCEPT the machine-tag fallback below.
#
# `🔴 Critical` completes the severity-emoji family (#888). Before it, a
# Critical-badged finding carrying no other blocking marker graded the same as
# an unbadged one — the #837 false-clear class at the TOP severity, blind in the
# advisory `coderabbit-wait.sh` count AND in the required
# `coderabbit-severity-gate.sh`, because #884 routed both through this one
# ladder.
#
# It joins the p1 rung rather than opening a CodeRabbit p0, even though p0 is
# what "critical" means in the normalized ladder. `resolve_required_tiers`
# returns `{p1}` when a consumer has no `feedback_policy` block, so a
# CodeRabbit p0 would leave the TOP severity NON-blocking in exactly the repos
# where a Major already blocks — a worse inversion than the blind spot it
# fixes. At p1, Critical blocks wherever Major blocks, in every config, which
# is the only relation that is never weaker.
#
# Machine-tag fallback (#888). CodeRabbit appends a machine-generated indicator
# tag to a finding body — `<!-- cr-indicator-types:potential_issue -->` — and
# that tag is the vendor-stable, explicitly machine-readable signal (the same
# reason the #593 rate-limit fix keyed on an auto-generated marker), while the
# rendered badge is the surface that has already drifted once. A body carrying
# ONLY the tag graded untiered, so neither counter saw it.
#
# Three deliberate properties:
#   - it is a FALLBACK, consulted only after every badge rung misses, so a body
#     that classifies today keeps exactly the tier it has. `🟡 Minor` plus the
#     tag stays p2: the tag names the CATEGORY (potential issue vs nitpick vs
#     refactor), the badge names the SEVERITY, and the badge is the one this
#     ladder grades. That property is a statement about ONE finding, not about
#     one string — CodeRabbit renders the badge and the tag on different lines,
#     so a caller grading a multi-finding document line-by-line must go through
#     `coderabbit_scan_tiers` below to keep it.
#   - it scans the FULL body, not the 600-char head, because the tag renders as
#     a trailing HTML comment after the finding prose (verbatim in the live #835
#     body, and in tests/test_coderabbit_wait_status_probe.sh's fixture of it).
#     A head-anchored match would see it only on short bodies.
#   - only the exact `potential_issue` VALUE is matched, bounded on the right
#     by a non-word character or end of string, so a longer value that merely
#     starts with it (`potential_issue_extra`) does not grade blocking
#     (CodeRabbit 🟡 Minor on #936). The bound is deliberately NOT the full
#     rendered comment `<!-- cr-indicator-types:potential_issue -->`: that
#     under-matches any rendering variation CodeRabbit ships — a comma-joined
#     value list, different inner spacing — and under-matching here means a
#     real blocking finding goes unclassified, which is the failure direction
#     this rung exists to close. Over-matching only ever grades something
#     blocking that is not; that is the safe side. The tag's other values
#     (`nitpick`, `refactor_suggestion`, …) are not blocking, and guessing at
#     an unobserved vocabulary is how a classifier over-blocks.
#
# The two rungs are separate functions so the ONE ladder can also be applied
# line-wise (`coderabbit_scan_tiers` below) without the fallback silently
# becoming an override. `coderabbit_tier_of` is their composition and is the
# entry point for grading ONE finding body; nothing else may re-implement
# either rung.

# The BADGE rung alone: the rendered severity markers, anchored on the first
# 600 chars. Empty when the text carries none.
coderabbit_badge_tier_of() {
  local head
  # Truncate via parameter expansion (not `printf | head -c`): under
  # `set -euo pipefail` a large body makes head close the pipe early and
  # printf exits 141 (SIGPIPE), which aborts every caller. The badge markers
  # matched below are near the start, so a 600-char cut is more than enough.
  head="${1:-}"; head="${head:0:600}"
  case "$head" in
    *"🔴 Critical"*|*"🟠 Major"*|*"Potential issue"*|*"⚠️"*)  echo p1; return 0 ;;
    *"🧹 Nitpick"*)                            echo nitpick; return 0 ;;
    *"🔵 Trivial"*|*"Outside diff range"*)     echo p3; return 0 ;;
    *"🟡 Minor"*)                              echo p2; return 0 ;;
  esac
  return 0
}

# The MACHINE-TAG rung alone: scanned over the FULL text, per the second
# deliberate property above. Empty unless the exact `potential_issue` value is
# present.
coderabbit_indicator_tag_tier_of() {
  case "${1:-}" in
    *"cr-indicator-types:potential_issue"[!A-Za-z0-9_]*|*"cr-indicator-types:potential_issue") \
      echo p1; return 0 ;;
  esac
  return 0
}

coderabbit_tier_of() {
  local tier
  tier=$(coderabbit_badge_tier_of "${1:-}")
  [ -n "$tier" ] || tier=$(coderabbit_indicator_tag_tier_of "${1:-}")
  [ -z "$tier" ] || echo "$tier"
}

# Grade a CodeRabbit DOCUMENT — a PR-level summary, which holds many finding
# stanzas — one line at a time, and emit only the lines that grade.
#
#   stdin   `<line-number><TAB><line>`   (the caller owns the numbering, so a
#                                        fence-filtered stream keeps the line
#                                        numbers of the ORIGINAL document)
#           with `--number`: raw lines, numbered from 1 by this function
#   stdout  `<line-number><TAB><tier><TAB><line>`
#
# `--number` exists so a caller that does not need positions is not forced to
# add a numbering process to reach the rule. It is not a convenience: the
# coderabbit-wait.sh caller is a BOOLEAN reached from an `if`, where `set -e`
# is suspended — a numbering step that failed there would leave the stream
# empty and the predicate would answer "no blocking marker", the exact silent
# false clear this file's callers keep closing. Both entry points are then
# builtins end to end, with no external command able to fail into a clear.
#
# Input is read with plain `read`, so each stream must end in a newline; both
# call sites produce one (`printf '%s\n'`, awk's `printf "…\n"`).
#
# WHY THIS EXISTS, rather than each caller looping over `coderabbit_tier_of`.
# The machine-tag rung is documented as a fallback that a badge always wins
# over ("`🟡 Minor` plus the tag stays p2"), and that property holds only while
# badge and tag are in the SAME string. CodeRabbit does not render them that
# way: the badge leads the finding and the tag trails it as an HTML comment
# several lines below. Graded line-by-line, the badge line and the tag line are
# separate strings, each rung fires on its own line, and the tag's p1 OVERRIDES
# the badge on every line-wise surface — including the REQUIRED
# scripts/coderabbit-severity-gate.sh, where a 🟡 Minor summary finding then
# takes an unretirable red graded [P1] under a `{p1}` blocking set that calls
# p2 discretionary (CodeRabbit's own summary surface, reported on #936).
#
# So the stanza, not the line, is the unit the fallback is defined over. The
# tag CLOSES the finding stanza it trails, which makes the rule expressible
# without parsing CodeRabbit's `<details>` scaffolding: a tag line grades only
# when no badge has graded since the previous tag line. ANY `cr-indicator-types:`
# line closes the stanza — the terminator test is the tag's presence, not its
# tier, so a `nitpick` / `refactor_suggestion` tag ends its finding exactly as a
# `potential_issue` one does, and the NEXT badge-less finding still gets its
# fallback. That reset is what keeps this a scoping rule rather than a one-shot
# suppression; keying it on the tag's tier instead latched a badged stanza
# across a non-blocking terminator and swallowed the next finding's p1
# (Codex P1 on #936).
#
# The suppression is deliberately narrow because it moves toward under-blocking,
# the unsafe direction for a classifier. It withholds a p1 only when a rendered
# badge for the same finding was already graded — i.e. only when the ladder has
# a MORE specific answer — and never when the badge rungs found nothing, which
# is the whole case #888 added the tag rung for.
coderabbit_scan_tiers() {
  local numbered lineno line tier stanza_badge_tier="" stanza_had_badge tab self_number=0 n=0
  [ "${1:-}" != "--number" ] || self_number=1
  tab=$'\t'
  while IFS= read -r numbered; do
    n=$((n + 1))
    if [ "$self_number" = 1 ]; then
      lineno=$n
      line=$numbered
    else
      [ -n "$numbered" ] || continue
      lineno=${numbered%%"$tab"*}
      line=${numbered#*"$tab"}
    fi
    [ -n "$line" ] || continue
    tier=$(coderabbit_badge_tier_of "$line")
    if [ -n "$tier" ]; then
      stanza_badge_tier=$tier
      printf '%s\t%s\t%s\n' "$lineno" "$tier" "$line"
      continue
    fi
    # A `cr-indicator-types:` line closes the stanza it trails whatever VALUE
    # the tag carries — the terminator test is the tag's presence, not its
    # tier. Keying the reset on `coderabbit_indicator_tag_tier_of` returning
    # non-empty instead left a badged stanza's tier latched across a
    # `nitpick` / `refactor_suggestion` terminator, so the NEXT finding — the
    # badge-less one the #888 fallback exists for — was suppressed as though
    # that earlier badge had graded it. That is an UNDER-block, on the
    # required gate, in exactly the direction this rung was added to close
    # (Codex P1 on #936).
    case "$line" in
      *"cr-indicator-types:"*) ;;
      *) continue ;;
    esac
    stanza_had_badge=$stanza_badge_tier
    stanza_badge_tier=""
    if [ -n "$stanza_had_badge" ]; then
      continue
    fi
    tier=$(coderabbit_indicator_tag_tier_of "$line")
    if [ -n "$tier" ]; then
      printf '%s\t%s\t%s\n' "$lineno" "$tier" "$line"
    fi
  done
  return 0
}
