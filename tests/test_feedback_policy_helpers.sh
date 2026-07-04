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

# ---------------------------------------------------------------------------
echo
echo "feedback-policy-helpers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
