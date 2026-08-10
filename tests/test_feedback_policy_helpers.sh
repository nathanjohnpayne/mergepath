#!/usr/bin/env bash
# tests/test_feedback_policy_helpers.sh
#
# Unit tests for scripts/lib/feedback-policy-helpers.sh (nathanjohnpayne/
# mergepath#574, sub-issue #576).
#
# Cases:
#   feedback_policy_field
#     1.  reads `mode` (unquoted)
#     2.  reads `mode` (double-quoted, trailing inline comment)
#     3.  reads a nested priority value (`p0`)
#     4.  missing key -> empty
#   resolve_required_tiers
#     5.  config file absent              -> "p1" (backward compat)
#     6.  block absent from config        -> "p1"
#     7.  by-priority, p0/p1 required     -> "p0 p1"
#     8.  address-all                     -> all five tiers
#     9.  by-priority, only p1 required   -> "p1"
#     10. block present, mode omitted     -> defaults by-priority
#     11. malformed mode                  -> exit 2
#     12. malformed tier value            -> exit 2
#   codex_tier_of
#     13. badge ![P0 Badge]..![P3 Badge]; text **P1; none
#   coderabbit_tier_of
#     14. nitpick / potential-issue default / critical / minor / major /
#         refactor / plain-note
#   coderabbit_scan_tiers
#     15. document-level grading: the machine-tag rung is scoped to the finding
#         stanza it trails, so a badge three lines above still wins
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/feedback-policy-helpers.sh"
[ -f "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/feedback-policy-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# eq <expected> <actual> <label> — string equality (newlines normalized to spaces).
eq() {
  local expected=$1 actual=$2 label=$3
  expected="$(printf '%s' "$expected" | tr '\n' ' ')"
  actual="$(printf '%s' "$actual" | tr '\n' ' ')"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected [$expected], got [$actual])"
  fi
}

# expect_rc <expected_rc> <label> -- <command...>
expect_rc() {
  local want=$1 label=$2; shift 2
  [ "$1" = "--" ] && shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$label"
  else
    fail "$label (expected rc=$want, got rc=$rc)"
  fi
}

# --- fixtures --------------------------------------------------------------
CFG_BYPRI="$WORKDIR/by-priority.yml"
cat > "$CFG_BYPRI" <<'YAML'
external_review_threshold: 300
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: discretionary
codex:
  enabled: true
YAML

CFG_QUOTED="$WORKDIR/quoted-mode.yml"
cat > "$CFG_QUOTED" <<'YAML'
feedback_policy:
  mode: "by-priority"   # quoted + inline comment
  priorities:
    p1: required
YAML

CFG_ALL="$WORKDIR/address-all.yml"
cat > "$CFG_ALL" <<'YAML'
feedback_policy:
  mode: address-all
codex:
  enabled: true
YAML

CFG_ONLY_P1="$WORKDIR/only-p1.yml"
cat > "$CFG_ONLY_P1" <<'YAML'
feedback_policy:
  mode: by-priority
  priorities:
    p1: required
    p2: discretionary
YAML

CFG_NO_MODE="$WORKDIR/no-mode.yml"
cat > "$CFG_NO_MODE" <<'YAML'
feedback_policy:
  priorities:
    p0: required
YAML

CFG_NO_BLOCK="$WORKDIR/no-block.yml"
cat > "$CFG_NO_BLOCK" <<'YAML'
external_review_threshold: 300
codex:
  enabled: true
YAML

CFG_BAD_MODE="$WORKDIR/bad-mode.yml"
cat > "$CFG_BAD_MODE" <<'YAML'
feedback_policy:
  mode: whenever
YAML

CFG_BAD_TIER="$WORKDIR/bad-tier.yml"
cat > "$CFG_BAD_TIER" <<'YAML'
feedback_policy:
  mode: by-priority
  priorities:
    p0: mandatory
YAML

# --- feedback_policy_field -------------------------------------------------
eq "by-priority" "$(feedback_policy_field mode "$CFG_BYPRI")"   "field: mode unquoted"
eq "by-priority" "$(feedback_policy_field mode "$CFG_QUOTED")"  "field: mode quoted + comment"
eq "required"    "$(feedback_policy_field p0 "$CFG_BYPRI")"     "field: nested priority p0"
eq ""            "$(feedback_policy_field nope "$CFG_BYPRI")"   "field: missing key -> empty"

# --- resolve_required_tiers ------------------------------------------------
eq "p1"             "$(resolve_required_tiers "$WORKDIR/does-not-exist.yml")" "resolve: absent file -> p1"
eq "p1"             "$(resolve_required_tiers "$CFG_NO_BLOCK")"               "resolve: absent block -> p1"
eq "p0 p1"          "$(resolve_required_tiers "$CFG_BYPRI")"                  "resolve: by-priority p0+p1"
eq "p0 p1 p2 p3 nitpick" "$(resolve_required_tiers "$CFG_ALL")"              "resolve: address-all -> all tiers"
eq "p1"             "$(resolve_required_tiers "$CFG_ONLY_P1")"               "resolve: by-priority only p1"
eq "p0"             "$(resolve_required_tiers "$CFG_NO_MODE")"               "resolve: mode omitted defaults by-priority"
expect_rc 2 "resolve: malformed mode -> rc 2" -- resolve_required_tiers "$CFG_BAD_MODE"
expect_rc 2 "resolve: malformed tier -> rc 2" -- resolve_required_tiers "$CFG_BAD_TIER"

# --- codex_tier_of ---------------------------------------------------------
eq "p0" "$(codex_tier_of '![P0 Badge] Critical: nullptr deref')" "codex_tier_of: P0 badge"
eq "p1" "$(codex_tier_of 'foo ![P1 Badge] bar')"                 "codex_tier_of: P1 badge"
eq "p2" "$(codex_tier_of '![P2 Badge]')"                         "codex_tier_of: P2 badge"
eq "p3" "$(codex_tier_of '![P3 Badge]')"                         "codex_tier_of: P3 badge"
eq "p1" "$(codex_tier_of '**P1**: stop retrying endlessly')"     "codex_tier_of: text fallback **P1"
eq ""   "$(codex_tier_of 'just a normal comment')"               "codex_tier_of: none -> empty"
eq "p1" "$(codex_tier_of 'first ![P1 Badge] then later ![P2 Badge]')" "codex_tier_of: first badge wins over later (#581 4b F3)"
eq "p1" "$(codex_tier_of '**P1** first, then **P3** later')"          "codex_tier_of: first text marker wins over later (#581 4b F3)"

# --- coderabbit_tier_of ----------------------------------------------------
eq "nitpick" "$(coderabbit_tier_of '🧹 Nitpick: rename this var')"                         "cr_tier_of: nitpick"
eq "p1"      "$(coderabbit_tier_of '⚠️ Potential issue: unhandled error')"                 "cr_tier_of: potential issue -> p1"
eq "p1"      "$(coderabbit_tier_of '_⚠️ Potential issue_ | _🔴 Critical_: RCE')"            "cr_tier_of: critical/potential-issue -> p1 (CodeRabbit tops at p1)"
eq "p1"      "$(coderabbit_tier_of '_⚠️ Potential issue_ | _🟠 Major_: breaks on the minor version bump')" "cr_tier_of: major wins over minor-in-prose -> p1 (#581 r1)"
eq "p2"      "$(coderabbit_tier_of '_📐 Maintainability_ | _🟡 Minor_: rename var')"        "cr_tier_of: minor (no potential-issue marker) -> p2"
eq "p3"      "$(coderabbit_tier_of '_🔵 Trivial issue_: cosmetic tweak')"                   "cr_tier_of: trivial -> p3 (#581 r2)"
eq ""        "$(coderabbit_tier_of '🛠️ Refactor suggestion to extract a security helper')" "cr_tier_of: refactor + security-in-prose -> empty (no severity badge; #581 r2)"
eq ""        "$(coderabbit_tier_of '📝 Note: verified the change')"                         "cr_tier_of: plain note -> empty"
eq ""        "$(coderabbit_tier_of 'This is a Minor cleanup note, not a CodeRabbit badge.')" "cr_tier_of: bare titlecase Minor prose -> empty (#581 4b F2)"
eq ""        "$(coderabbit_tier_of 'This is Trivial, no finding badge.')"                    "cr_tier_of: bare titlecase Trivial prose -> empty (#581 4b F2)"
eq "p2"      "$(coderabbit_tier_of '_📐 Maintainability_ | _🟡 Minor_: This cleanup is Trivial but visible')" "cr_tier_of: Minor badge beats Trivial-in-prose -> p2 (#581 4b F2)"

# --- #888: the two blind spots ---------------------------------------------
# 1. A `🔴 Critical` badge carrying NO other blocking marker. Before the rung
#    it graded the same as an unbadged body — unclassified — so neither the
#    advisory coderabbit-wait.sh count nor the required
#    coderabbit-severity-gate.sh saw the TOP severity. It joins p1 (not p0):
#    resolve_required_tiers returns {p1} when a consumer has no
#    feedback_policy block, so a CodeRabbit p0 would leave Critical
#    non-blocking exactly where Major blocks.
eq "p1"      "$(coderabbit_tier_of '_🔒 Security \& Privacy_ | _🔴 Critical_: remote code execution')" "cr_tier_of #888: bare 🔴 Critical badge -> p1 (top severity is no longer unclassified)"
eq "p1"      "$(coderabbit_tier_of '_🔴 Critical_ | _🟡 Minor_ in the prose below')"                    "cr_tier_of #888: 🔴 Critical outranks a 🟡 Minor badge on the same line"

# 2. The machine tag with no rendered severity badge. `cr-indicator-types` is
#    the vendor-stable, explicitly machine-readable signal (the #593
#    precedent); the badge is the surface that already drifted once (#835/#837).
#    It is a FALLBACK — a body that already classifies keeps its tier — and it
#    is matched over the FULL body, because the tag renders as a trailing HTML
#    comment AFTER the finding prose, i.e. routinely past the 600-char badge
#    anchor.
CR_TAG='<!-- cr-indicator-types:potential_issue -->'
eq "p1"      "$(coderabbit_tier_of "**Reject the diagnostic bypass in merge-gate callers.**

The caller accepts a bypass flag that skips the gate.

$CR_TAG")" "cr_tier_of #888: machine tag with no severity badge -> p1"
# The live shape: the tag sits far past the 600-char badge anchor.
cr_pad=$(head -c 2000 /dev/zero | tr '\0' 'x')
eq "p1"      "$(coderabbit_tier_of "**A finding with a long body.**

$cr_pad

$CR_TAG")" "cr_tier_of #888: machine tag beyond the 600-char badge anchor still -> p1"
# Fallback, not an override: a badged body keeps the badge's tier. The tag
# names the CATEGORY, the badge names the SEVERITY.
eq "p2"      "$(coderabbit_tier_of "_📐 Maintainability_ | _🟡 Minor_: rename var

$CR_TAG")" "cr_tier_of #888: badge still wins over the machine tag (Minor + potential_issue -> p2)"
eq "nitpick" "$(coderabbit_tier_of '_🧹 Nitpick_: tidy this

<!-- cr-indicator-types:nitpick -->')" "cr_tier_of #888: a nitpick-valued tag is not upgraded"
# Only the exact `potential_issue` value is blocking; other values are not.
eq ""        "$(coderabbit_tier_of 'A plain suggestion with no badge.

<!-- cr-indicator-types:refactor_suggestion -->')" "cr_tier_of #888: a non-potential_issue tag value stays unclassified"
# The value is bounded on the right: a longer value that merely STARTS with
# `potential_issue` is a different value (CodeRabbit 🟡 Minor on #936).
eq ""        "$(coderabbit_tier_of 'A finding with no badge.

<!-- cr-indicator-types:potential_issue_extra -->')" "cr_tier_of #936: a suffixed tag value (potential_issue_extra) is NOT the potential_issue tag"
# ...and the bound must not cost the tag at end-of-body, or in a comma-joined
# value list, both of which are the same value.
eq "p1"      "$(coderabbit_tier_of 'A finding with no badge.

<!-- cr-indicator-types:potential_issue -->
')" "cr_tier_of #936: the tag still matches with trailing whitespace"
eq "p1"      "$(coderabbit_tier_of 'A finding with no badge.

cr-indicator-types:potential_issue')" "cr_tier_of #936: the tag still matches at end of body (no trailing character)"
eq "p1"      "$(coderabbit_tier_of 'A finding with no badge.

<!-- cr-indicator-types:potential_issue,nitpick -->')" "cr_tier_of #936: a comma-joined value list containing potential_issue still grades p1"

# --- rc-safety under set -euo pipefail (#581 4b F1) ------------------------
# A markerless / unclassified call must return rc 0 + empty output, NOT abort a
# `tier=$(fn "$body")` caller. Asserted directly: the eq cases above nest the
# call in a command substitution passed as an argument, which masks the rc.
# (This file runs under `set -euo pipefail`.)
rc=0; out=$(codex_tier_of 'plain comment, no priority markers here') || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "codex_tier_of: markerless is rc0+empty under set -e"; else fail "codex_tier_of: markerless rc=$rc out=[$out]"; fi
rc=0; out=$(coderabbit_tier_of 'plain comment, no CodeRabbit badge here') || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "coderabbit_tier_of: markerless is rc0+empty under set -e"; else fail "coderabbit_tier_of: markerless rc=$rc out=[$out]"; fi

# #652: a body larger than the pipe buffer must not SIGPIPE-abort the
# classifier under set -e (the old `printf | head -c 600` exited 141 when
# head closed the pipe early).
rc=0; big=$(head -c 100000 /dev/zero | tr '\0' 'x'); out=$(coderabbit_tier_of "🟠 Major $big") || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "p1" ]; then pass "coderabbit_tier_of: large body classifies without SIGPIPE abort (#652)"; else fail "coderabbit_tier_of: large body rc=$rc out=[$out]"; fi

# --- 15. coderabbit_scan_tiers: the ladder over a DOCUMENT (#936) ----------
#
# The badge-wins property asserted above ("cr_tier_of #888: badge still wins
# over the machine tag") is a claim about ONE FINDING, and it held only because
# those cases hand the whole finding to the classifier as one string. CodeRabbit
# does not render it that way: the severity badge leads the finding and the
# `cr-indicator-types` tag trails it as an HTML comment several lines below. Both
# line-wise callers — the REQUIRED scripts/coderabbit-severity-gate.sh summary
# loop and scripts/coderabbit-wait.sh's crw_scan_has_blocking_marker — grade a
# summary one line at a time, so each rung fired on its own line and the tag's
# p1 overrode the badge on the surface that actually gates.
#
# These cases pin the document-level contract those callers now share.

# Render the graded stream compactly as `<line>:<tier>` pairs, so an assertion
# names WHICH line graded and at what tier — a bare "is anything blocking"
# check would pass on the defect (it blocks, just for the wrong reason).
cr_scan_pairs() {
  printf '%s\n' "$1" \
    | coderabbit_scan_tiers --number \
    | awk -F'\t' '{ printf "%s%s:%s", (NR > 1 ? " " : ""), $1, $2 }'
}

# The live stanza shape (verbatim structure of the #835 body, and of
# tests/test_coderabbit_wait_status_probe.sh's fixture of it): badge line,
# blank, bold title, blank, prose, blank, trailing tag.
CR_MINOR_TAGGED='_🔒 Security & Privacy_ | _🟡 Minor_ | _⚡ Quick win_

**Bound the retry delay.**

The delay grows without a ceiling.

<!-- cr-indicator-types:potential_issue -->'
CR_TAG_ONLY='**Reject the diagnostic bypass in merge-gate callers.**

The caller accepts a bypass flag that skips the gate.

<!-- cr-indicator-types:potential_issue -->'

eq "1:p2" "$(cr_scan_pairs "$CR_MINOR_TAGGED")" \
  "cr_scan_tiers #936: a 🟡 Minor stanza keeps its badge tier — the trailing tag does not re-grade the same finding p1"
eq "5:p1" "$(cr_scan_pairs "$CR_TAG_ONLY")" \
  "cr_scan_tiers #888: a stanza with NO rendered badge still grades p1 off the tag (the rung the scoping must not cost)"
# Both in one document, in that order: the scoping is per stanza, not a
# one-shot suppression. The tag CLOSES the stanza it trails whether or not it
# graded, so the second, badge-less finding still gets its fallback. Without
# that reset this reads `1:p2` alone and the #888 rung dies after the first
# badge in the document.
eq "1:p2 13:p1" "$(cr_scan_pairs "$CR_MINOR_TAGGED

$CR_TAG_ONLY")" \
  "cr_scan_tiers #936: the tag rung is scoped to its own stanza — a later badge-less finding still grades p1"
# Same shape at the OTHER discretionary rungs: the tag must not promote them
# either, since `resolve_required_tiers` calls nitpick/p3 discretionary by
# default exactly as it does p2.
eq "1:nitpick" "$(cr_scan_pairs '_🧹 Nitpick_ | _⚡ Quick win_

**Rename the temp variable.**

<!-- cr-indicator-types:potential_issue -->')" \
  "cr_scan_tiers #936: a 🧹 Nitpick stanza is not promoted to p1 by its trailing tag"
# A genuinely blocking stanza still grades blocking, and exactly ONCE — the
# badge line — so a required gate lists one finding rather than two rows for
# one finding.
eq "1:p1" "$(cr_scan_pairs '_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_

**Reject the bypass.**

<!-- cr-indicator-types:potential_issue -->')" \
  "cr_scan_tiers: a 🟠 Major stanza grades p1 once, on its badge line"
# Line numbers come from the CALLER's numbering, never from a rescan: the
# severity gate feeds a fence-FILTERED stream and reports positions in the
# original summary, so a self-counted number would point at the wrong line.
eq "31:p1" "$(printf '31\t_🟠 Major_: the retry loop never terminates.\n' | coderabbit_scan_tiers \
  | awk -F'\t' '{ printf "%s:%s", $1, $2 }')" \
  "cr_scan_tiers: the emitted line number is the caller's, so a fence-filtered stream keeps original positions"
# `--number` numbers the stream itself, and must agree with a caller that
# numbered it — the coderabbit-wait.sh predicate uses the self-numbering form
# precisely so no external command sits between the body and the rule.
eq "$(cr_scan_pairs "$CR_MINOR_TAGGED")" \
   "$(printf '%s\n' "$CR_MINOR_TAGGED" | awk '{ printf "%d\t%s\n", NR, $0 }' | coderabbit_scan_tiers \
      | awk -F'\t' '{ printf "%s%s:%s", (NR > 1 ? " " : ""), $1, $2 }')" \
  "cr_scan_tiers: --number agrees line-for-line with a caller-numbered stream"
# The stanza TERMINATOR is the tag's presence, not its tier. CodeRabbit's tag
# vocabulary is wider than the one blocking value: a `nitpick` or
# `refactor_suggestion` tag closes its finding just as a `potential_issue` one
# does. Keying the reset on "the tag graded" instead left the badged stanza's
# tier latched across such a terminator, and the NEXT finding — the badge-less
# one the #888 rung exists for — was suppressed as though that earlier badge
# had graded it. An UNDER-block, on the required gate. Without the fix this
# reads `1:p2` and the p1 on line 11 is silently gone (Codex P1 on #936).
eq "1:p2 11:p1" "$(cr_scan_pairs '_🔒 Security & Privacy_ | _🟡 Minor_ | _⚡ Quick win_

**Bound the retry delay.**

<!-- cr-indicator-types:nitpick -->

**Reject the diagnostic bypass in merge-gate callers.**

The caller accepts a bypass flag that skips the gate.

<!-- cr-indicator-types:potential_issue -->')" \
  "cr_scan_tiers #936: a non-blocking tag value still CLOSES its stanza, so the next badge-less finding keeps the #888 fallback"
# And the terminator does not become a promoter: an unrecognized tag value on a
# badge-less stanza grades nothing, because only `potential_issue` is blocking.
eq "" "$(cr_scan_pairs '**Rename the temp variable.**

<!-- cr-indicator-types:refactor_suggestion -->')" \
  "cr_scan_tiers #936: closing a stanza is not grading it — a non-blocking tag value alone emits no tier"
# rc-safety under `set -euo pipefail`, the same contract the two classifiers
# carry: no graded line is rc 0 + empty, not a failure that aborts the caller.
rc=0; out=$(printf 'ordinary prose with no marker\n' | coderabbit_scan_tiers --number) || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "coderabbit_scan_tiers: a document with no marker is rc0+empty under set -e"; else fail "coderabbit_scan_tiers: markerless rc=$rc out=[$out]"; fi
rc=0; out=$(printf '' | coderabbit_scan_tiers) || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "coderabbit_scan_tiers: empty input is rc0+empty under set -e"; else fail "coderabbit_scan_tiers: empty rc=$rc out=[$out]"; fi

# ---------------------------------------------------------------------------
echo
echo "feedback-policy-helpers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
