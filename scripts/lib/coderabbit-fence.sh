#!/usr/bin/env bash
# scripts/lib/coderabbit-fence.sh — the ONE CommonMark fence reader shared by
# every scan that must tell CodeRabbit's own markup from content CodeRabbit is
# QUOTING.
#
# Extracted from scripts/coderabbit-severity-gate.sh (#1178 round 5). It lived
# there alone while scripts/coderabbit-wait.sh carried a raw-grep copy of the
# same range predicates, and specs/coderabbit_review_sensing.md already named
# that duplication as something "a change to either copy has to be checkable
# against one contract". The copies had diverged: the gate's summary_names_head
# was hardened to read UNFENCED text only (Codex P1 round 5 on #886, where a
# quoted `between X and Y` made a stale summary read as the current head's
# report), and the waiter's was not. A new consumer in the waiter then picked
# up the unhardened copy in a fail-OPEN direction, which is the defect this
# extraction closes rather than papers over.
#
# Sourcing contract: no top-level side effects beyond the constant below, and
# Bash 3.2 portable. The severity gate and the waiter both source this; neither
# may redefine it.

# --- shared fence-aware line filter ----------------------------------------
#
# THREE structural scans below need the same question answered — "is this line
# CodeRabbit's own markup, or content CodeRabbit is quoting?" — and each of them
# turned out to be a false clear of this required gate when it got that answer
# wrong (stanza detection, the pre-merge strip, and the commits-range match).
# They share ONE implementation rather than three copies, because the first
# attempt did carry three copies and they were three different degrees of wrong
# (Codex P1 round 5 on #886: the copies recognised only a bare three-backtick
# fence, so a `~~~` or ````` quote walked straight past two fixes made for
# exactly this).
#
# Fence recognition follows CommonMark rather than a convenient subset: an
# opener is 3+ backticks OR 3+ tildes, indented up to 3 spaces, optionally with
# an info string; a closer must use the SAME character, be at least as long,
# and carry nothing but whitespace after it. Getting any of those wrong
# reintroduces the bug — a `~~~` block whose contents are read as markup, or a
# ```` fence "closed" by an inner ``` line.
#
# Deliberately interval-free regexes (`/^ ? ? ?/`, explicit run counting): awk
# interval expressions are not portable across the BWK awk on macOS and the
# mawk/gawk on CI runners, and a silently-unsupported `{3,}` would degrade this
# to matching nothing.
CR_AWK_FENCE_PRELUDE='
function fence_info(s, out,   c, n) {
  sub(/^ ? ? ?/, "", s)
  c = substr(s, 1, 1)
  if (c != "`" && c != "~") return 0
  n = 0
  while (substr(s, n + 1, 1) == c) n++
  if (n < 3) return 0
  out["rest"] = substr(s, n + 1)
  # CommonMark: the info string of a BACKTICK fence may not contain a backtick
  # (tilde fences have no such restriction). Accepting one made an ordinary
  # prose line carrying backticks read as an opener, which puts the reader into
  # a fence that never legitimately closes and hides everything after it —
  # including the genuine commits range, which then takes the summary out of
  # scope and clears the gate. Rejecting the line here is the correct outcome
  # and not merely the safe one: such a line is not a fence in any renderer.
  if (c == "`" && index(out["rest"], "`") > 0) return 0
  out["char"] = c
  out["len"] = n
  return 1
}
function fence_update(l,   inf) {
  if (!fence_info(l, inf)) return 0
  if (!FENCE) { FENCE = 1; FCH = inf["char"]; FLEN = inf["len"]; return 1 }
  if (inf["char"] == FCH && inf["len"] >= FLEN && inf["rest"] ~ /^[ \t]*$/) {
    FENCE = 0; FCH = ""; FLEN = 0
  }
  return 1
}
'
