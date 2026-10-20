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
#     14. nitpick / potential-issue default / minor / major /
#         refactor / plain-note
#   ghas_severity_tier (#1101)
#     15. critical/high/medium/low -> p0/p1/p2/p3; none/empty/unrecognized
#         -> empty (rc0, caller decides the fallback)
#   ghas_alert_number_from_body (#1113)
#     16. extracts alert number from a /security/code-scanning/N link;
#         first match wins; no link / no digits / empty / missing arg
#         -> empty (rc0)
#   read_policy_block_field (#1124)
#     17. reads a field from an arbitrary top-level block (not only
#         feedback_policy:); absent field/block/file -> empty
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

# --- resolve_tiers_by_disposition (#1672) ----------------------------------
# Exact stdout bytes matter: eq normalizes newlines and expect_rc drops output.
disposition_result() {
  local want_rc=$1 want_stdout=$2 label=$3 rc=0
  shift 3
  "$@" > "$WORKDIR/disposition.out" 2> "$WORKDIR/disposition.err" || rc=$?
  printf '%s' "$want_stdout" > "$WORKDIR/disposition.expected"
  if [ "$rc" -eq "$want_rc" ] && cmp -s "$WORKDIR/disposition.expected" "$WORKDIR/disposition.out"; then
    pass "$label"
  else
    fail "$label (expected rc=$want_rc and exact stdout, got rc=$rc)"
  fi
}

DISP_CFG_5="$WORKDIR/disposition-empty-block.yml"
cat > "$DISP_CFG_5" <<'YAML'
feedback_policy:
YAML

DISP_CFG_6="$WORKDIR/disposition-partial.yml"
cat > "$DISP_CFG_6" <<'YAML'
feedback_policy:
  priorities:
    p1: required
    p2: ignore
YAML

DISP_CFG_7="$WORKDIR/disposition-mixed.yml"
cat > "$DISP_CFG_7" <<'YAML'
feedback_policy:
  mode: "by-priority" # existing normalization
  priorities:
    p0: "ignore"
    p1: required
    p2: discretionary
    p3: ignore
    nitpick: required
YAML

DISP_CFG_8="$WORKDIR/disposition-address-all-ignored-valid-priorities.yml"
cat > "$DISP_CFG_8" <<'YAML'
feedback_policy:
  mode: address-all
  priorities:
    p0: ignore
    p1: discretionary
YAML

DISP_CFG_9="$WORKDIR/disposition-late-bad-tier.yml"
cat > "$DISP_CFG_9" <<'YAML'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: discretionary
    p2: ignore
    p3: required
    nitpick: mandatory
YAML

disposition_result 0 $'p0\np1\n' $'disposition: absent-file/required' \
  resolve_tiers_by_disposition $'required' "$WORKDIR/does-not-exist.yml"
disposition_result 0 $'p2\np3\nnitpick\n' $'disposition: absent-file/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$WORKDIR/does-not-exist.yml"
disposition_result 0 $'' $'disposition: absent-file/ignore' \
  resolve_tiers_by_disposition $'ignore' "$WORKDIR/does-not-exist.yml"
disposition_result 0 $'p0\np1\n' $'disposition: no-block/required' \
  resolve_tiers_by_disposition $'required' "$CFG_NO_BLOCK"
disposition_result 0 $'p2\np3\nnitpick\n' $'disposition: no-block/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$CFG_NO_BLOCK"
disposition_result 0 $'' $'disposition: no-block/ignore' \
  resolve_tiers_by_disposition $'ignore' "$CFG_NO_BLOCK"

# A transport/read error is not evidence that the block is absent. Inject
# grep's documented error status without relying on host file permissions.
disposition_read_error() (
  grep() { return 2; }
  resolve_tiers_by_disposition "$@"
)
for disposition in required discretionary ignore; do
  disposition_result 2 '' "disposition: unreadable policy/$disposition" \
    disposition_read_error "$disposition" "$CFG_BYPRI"
done

disposition_field_read_error() (
  local rc=0
  set +o pipefail
  awk() { return 2; }
  resolve_tiers_by_disposition "$@" || rc=$?
  [[ ! -o pipefail ]] || return 97
  return "$rc"
)
for disposition in required discretionary ignore; do
  disposition_result 2 '' "disposition: field read error without caller pipefail/$disposition" \
    disposition_field_read_error "$disposition" "$CFG_BYPRI"
done
disposition_result 0 $'' $'disposition: empty-block/required' \
  resolve_tiers_by_disposition $'required' "$DISP_CFG_5"
disposition_result 0 $'p0\np1\np2\np3\nnitpick\n' $'disposition: empty-block/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$DISP_CFG_5"
disposition_result 0 $'' $'disposition: empty-block/ignore' \
  resolve_tiers_by_disposition $'ignore' "$DISP_CFG_5"
disposition_result 0 $'p0\np1\n' $'disposition: hub-defaults/required' \
  resolve_tiers_by_disposition $'required' "$CFG_BYPRI"
disposition_result 0 $'p2\np3\nnitpick\n' $'disposition: hub-defaults/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$CFG_BYPRI"
disposition_result 0 $'' $'disposition: hub-defaults/ignore' \
  resolve_tiers_by_disposition $'ignore' "$CFG_BYPRI"
disposition_result 0 $'p1\n' $'disposition: partial/required' \
  resolve_tiers_by_disposition $'required' "$DISP_CFG_6"
disposition_result 0 $'p0\np3\nnitpick\n' $'disposition: partial/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$DISP_CFG_6"
disposition_result 0 $'p2\n' $'disposition: partial/ignore' \
  resolve_tiers_by_disposition $'ignore' "$DISP_CFG_6"
disposition_result 0 $'p1\nnitpick\n' $'disposition: mixed/required' \
  resolve_tiers_by_disposition $'required' "$DISP_CFG_7"
disposition_result 0 $'p2\n' $'disposition: mixed/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$DISP_CFG_7"
disposition_result 0 $'p0\np3\n' $'disposition: mixed/ignore' \
  resolve_tiers_by_disposition $'ignore' "$DISP_CFG_7"
disposition_result 0 $'p0\np1\np2\np3\nnitpick\n' $'disposition: address-all/required' \
  resolve_tiers_by_disposition $'required' "$CFG_ALL"
disposition_result 0 $'' $'disposition: address-all/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$CFG_ALL"
disposition_result 0 $'' $'disposition: address-all/ignore' \
  resolve_tiers_by_disposition $'ignore' "$CFG_ALL"
disposition_result 0 $'p0\np1\np2\np3\nnitpick\n' $'disposition: address-all-ignored-valid-priorities/required' \
  resolve_tiers_by_disposition $'required' "$DISP_CFG_8"
disposition_result 0 $'' $'disposition: address-all-ignored-valid-priorities/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$DISP_CFG_8"
disposition_result 0 $'' $'disposition: address-all-ignored-valid-priorities/ignore' \
  resolve_tiers_by_disposition $'ignore' "$DISP_CFG_8"
disposition_result 2 $'' $'disposition: bad-mode/required' \
  resolve_tiers_by_disposition $'required' "$CFG_BAD_MODE"
disposition_result 2 $'' $'disposition: bad-mode/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$CFG_BAD_MODE"
disposition_result 2 $'' $'disposition: bad-mode/ignore' \
  resolve_tiers_by_disposition $'ignore' "$CFG_BAD_MODE"
disposition_result 2 $'' $'disposition: late-bad-tier/required' \
  resolve_tiers_by_disposition $'required' "$DISP_CFG_9"
disposition_result 2 $'' $'disposition: late-bad-tier/discretionary' \
  resolve_tiers_by_disposition $'discretionary' "$DISP_CFG_9"
disposition_result 2 $'' $'disposition: late-bad-tier/ignore' \
  resolve_tiers_by_disposition $'ignore' "$DISP_CFG_9"
disposition_result 2 $'' $'disposition: invalid-disposition/\'\'/no-block' \
  resolve_tiers_by_disposition $'' "$CFG_NO_BLOCK"
disposition_result 2 $'' $'disposition: invalid-disposition/\'\'/hub-defaults' \
  resolve_tiers_by_disposition $'' "$CFG_BYPRI"
disposition_result 2 $'' $'disposition: invalid-disposition/\'Required\'/no-block' \
  resolve_tiers_by_disposition $'Required' "$CFG_NO_BLOCK"
disposition_result 2 $'' $'disposition: invalid-disposition/\'Required\'/hub-defaults' \
  resolve_tiers_by_disposition $'Required' "$CFG_BYPRI"
disposition_result 2 $'' $'disposition: invalid-disposition/\'unknown\'/no-block' \
  resolve_tiers_by_disposition $'unknown' "$CFG_NO_BLOCK"
disposition_result 2 $'' $'disposition: invalid-disposition/\'unknown\'/hub-defaults' \
  resolve_tiers_by_disposition $'unknown' "$CFG_BYPRI"

# A missing argument is distinct from an explicit invalid value under nounset.
disposition_result 2 '' 'disposition: missing argument' resolve_tiers_by_disposition
disposition_result 0 $'p2\np3\nnitpick\n' 'disposition: actual hub discretionary set' \
  resolve_tiers_by_disposition discretionary "$ROOT/.github/review-policy.yml"
# Pin intentional absent-block divergence; do not migrate the legacy gates.
disposition_result 0 $'p1\n' 'legacy: absent block remains p1 only' \
  resolve_required_tiers "$CFG_NO_BLOCK"
disposition_result 0 $'p1\n' 'legacy: absent file remains p1 only' \
  resolve_required_tiers "$WORKDIR/does-not-exist.yml"

# Scope CONFIG/cwd within subprocesses; keep PASS/FAIL accounting in this shell.
disposition_with_config() (
  CONFIG="$CFG_NO_BLOCK"
  resolve_tiers_by_disposition "$@"
)
disposition_result 0 $'p0\np1\n' 'disposition: CONFIG default' \
  disposition_with_config required
disposition_result 0 $'p0\np1\np2\np3\nnitpick\n' 'disposition: explicit cfg overrides CONFIG' \
  disposition_with_config required "$CFG_ALL"
mkdir -p "$WORKDIR/disposition-default/.github"
cp "$CFG_BYPRI" "$WORKDIR/disposition-default/.github/review-policy.yml"
disposition_in_default_dir() (
  unset CONFIG
  cd "$WORKDIR/disposition-default"
  resolve_tiers_by_disposition "$@"
)
disposition_result 0 $'p2\np3\nnitpick\n' 'disposition: relative default cfg' \
  disposition_in_default_dir discretionary

# --- codex_tier_of ---------------------------------------------------------
eq "p0" "$(codex_tier_of '![P0 Badge] Critical: nullptr deref')" "codex_tier_of: P0 badge"
eq "p1" "$(codex_tier_of 'foo ![P1 Badge] bar')"                 "codex_tier_of: P1 badge"
eq "p2" "$(codex_tier_of '![P2 Badge]')"                         "codex_tier_of: P2 badge"
eq "p3" "$(codex_tier_of '![P3 Badge]')"                         "codex_tier_of: P3 badge"
eq "p1" "$(codex_tier_of '**P1**: stop retrying endlessly')"     "codex_tier_of: text fallback **P1"
eq ""   "$(codex_tier_of 'just a normal comment')"               "codex_tier_of: none -> empty"
eq "p1" "$(codex_tier_of 'first ![P1 Badge] then later ![P2 Badge]')" "codex_tier_of: first badge wins over later (#581 4b F3)"
eq "p1" "$(codex_tier_of '**P1** first, then **P3** later')"          "codex_tier_of: first text marker wins over later (#581 4b F3)"
eq "p3 p1 p2" "$(codex_tiers_of '**P3** first, then ![P1 Badge], then **P2**')" "codex_tiers_of: emits every canonical marker in document order"

# --- coderabbit_tier_of ----------------------------------------------------
eq "nitpick" "$(coderabbit_tier_of '🧹 Nitpick: rename this var')"                         "cr_tier_of: nitpick"
eq "p1"      "$(coderabbit_tier_of '⚠️ Potential issue: unhandled error')"                 "cr_tier_of: potential issue -> p1"
eq "p1"      "$(coderabbit_tier_of '_⚠️ Potential issue_ | _🔴 Critical_: RCE')"            "cr_tier_of: potential-issue -> p1 even when prose names Critical"
eq "p1"      "$(coderabbit_tier_of '_⚠️ Potential issue_ | _🟠 Major_: breaks on the minor version bump')" "cr_tier_of: major wins over minor-in-prose -> p1 (#581 r1)"
eq "p2"      "$(coderabbit_tier_of '_📐 Maintainability_ | _🟡 Minor_: rename var')"        "cr_tier_of: minor (no potential-issue marker) -> p2"
eq "p3"      "$(coderabbit_tier_of '_🔵 Trivial issue_: cosmetic tweak')"                   "cr_tier_of: trivial -> p3 (#581 r2)"
eq ""        "$(coderabbit_tier_of '🛠️ Refactor suggestion to extract a security helper')" "cr_tier_of: refactor + security-in-prose -> empty (no severity badge; #581 r2)"
eq ""        "$(coderabbit_tier_of '📝 Note: verified the change')"                         "cr_tier_of: plain note -> empty"
eq ""        "$(coderabbit_tier_of 'This is a Minor cleanup note, not a CodeRabbit badge.')" "cr_tier_of: bare titlecase Minor prose -> empty (#581 4b F2)"
eq ""        "$(coderabbit_tier_of 'This is Trivial, no finding badge.')"                    "cr_tier_of: bare titlecase Trivial prose -> empty (#581 4b F2)"
eq "p2"      "$(coderabbit_tier_of '_📐 Maintainability_ | _🟡 Minor_: This cleanup is Trivial but visible')" "cr_tier_of: Minor badge beats Trivial-in-prose -> p2 (#581 4b F2)"
eq "p3 p1 p2" "$(coderabbit_tiers_of '🔵 Trivial first, 🟠 Major second, 🟡 Minor third')" "cr_tiers_of: emits every canonical marker in document order"

# #1407: these exact provider section headings describe a container, while
# the nested comment carries its own severity. Test both tier entry points:
# the gate grades individual lines and accounting extracts all body markers.
for heading in \
  '<summary>⚠️ Outside diff range comments (1)</summary>' \
  '<summary>Outside diff range comments (1)</summary><blockquote>' \
  '**⚠️ Outside diff range comments (1)**' \
  '> **⚠️ Outside diff range comments (1)**' \
  '> **Outside diff range comments (12)**'; do
  eq "" "$(coderabbit_tier_of "$heading")" "cr_heading: structural line has no tier: $heading"
  eq "" "$(coderabbit_tiers_of "$heading")" "cr_headings: structural line has no markers: $heading"
  body="$heading
> <details>
> <summary><strong>🟡 Minor</strong> · Restrict Phase 0 preflight to local sessions.</summary><blockquote>
> **🟡 Minor** Real finding.
> </blockquote></details>"
  eq p2 "$(coderabbit_tier_of "$body")" "cr_heading: nested Minor keeps p2: $heading"
  eq "p2 p2" "$(coderabbit_tiers_of "$body")" "cr_headings: only nested Minor markers remain: $heading"
  eq p1 "$(coderabbit_tier_of "$body
_🟠 Major_ Real required finding in the same container.")" "cr_heading: nested Major still requires disposition: $heading"
done
eq p3 "$(coderabbit_tier_of 'Outside diff range: standalone category finding')" "cr_heading: existing category marker remains gradeable"
eq p3 "$(coderabbit_tier_of '<summary>⚠️ Outside diff range comments (1)</summary>
_🔵 Trivial_ Real nested finding.')" "cr_heading: nested Trivial keeps its actual tier"
for near_miss in \
  '**⚠️ Outside diff range comments (1)** _🟠 Major_ real finding on same line' \
  '<summary>⚠️ Outside diff range comments (1): investigate this</summary>' \
  '**⚠️ Outside diff range comments (unknown)**'; do
  eq p1 "$(coderabbit_tier_of "$near_miss")" "cr_heading: nonexact heading remains classified: $near_miss"
done

# A failed heading read must discard partial output just like marker extraction.
for classifier in coderabbit_tiers_of coderabbit_tier_of; do
  if (
    awk() { printf '_🟠 Major_\n'; return 2; }
    rc=0; out=$("$classifier" '_🟠 Major_') || rc=$?
    [ "$rc" = 2 ] && [ -z "$out" ]
  ); then
    pass "$classifier: failed heading read discards partial output"
  else
    fail "$classifier: failed heading read became a classification or absence"
  fi
done

# A failed marker read is neither absence nor a usable partial classification.
for partial in '' '🟠 Major'; do
  for classifier in coderabbit_tiers_of coderabbit_tier_of; do
    if (
      grep() { printf '%s' "$partial"; return 2; }
      rc=0; out=$("$classifier" '🟠 Major') || rc=$?
      [ "$rc" = 2 ] && [ -z "$out" ]
    ); then
      pass "$classifier: failed extraction discards partial output"
    else
      fail "$classifier: failed extraction became a classification or absence"
    fi
  done
done

# Selecting from tiers already extracted in memory needs no second reader.
if (
  coderabbit_tiers_of() { printf 'p2\np1\n'; }
  grep() { return 2; }
  [ "$(coderabbit_tier_of 'body')" = p1 ]
); then
  pass "coderabbit_tier_of: selection does not lose an extracted tier to grep failure"
else
  fail "coderabbit_tier_of: selection lost an extracted tier"
fi

# #1050: a CodeRabbit command-invocation reply can use a warning glyph for
# provider status rather than reviewer feedback. The sanitizer excludes only
# the exact status-summary line when the same visible body carries the exact
# invocation marker; all near misses and mixed real findings stay classified.
coderabbit_scanned_tier() {
  local sanitized
  sanitized=$(coderabbit_finding_scan "${1:-}")
  coderabbit_tier_of "$sanitized"
}

CR_RATE_LIMIT_STATUS='<!-- This is an auto-generated reply by CodeRabbit -->
<!-- CodeRabbit review command invocation: v2:40695c92071a7774b4a6b4f0e9eb06deacb14b457ca3ec1044886bf8782b8cc7 -->
<details>
<summary>⚠️ Action not completed</summary>

Review rate limited.

</details>'
eq "" "$(coderabbit_scanned_tier "$CR_RATE_LIMIT_STATUS")" "cr_scan: command-invocation rate-limit status is not a finding (#1050)"

eq "p1" "$(coderabbit_scanned_tier '<!-- This is an auto-generated reply by CodeRabbit -->
<details>
<summary>⚠️ Action not completed</summary>
Review rate limited.
</details>')" "cr_scan: generic auto-reply marker does not suppress status-shaped warning"

eq "p1" "$(coderabbit_scanned_tier '<!-- CodeRabbit review command invocation: -->
<details>
<summary>⚠️ Action not completed</summary>
Review rate limited.
</details>')" "cr_scan: empty invocation identifier fails toward classification"

eq "p1" "$(coderabbit_scanned_tier '> <!-- CodeRabbit review command invocation: quoted-example -->
<details>
<summary>⚠️ Action not completed</summary>
Review rate limited.
</details>')" "cr_scan: quoted invocation marker fails toward classification"

eq "p1" "$(coderabbit_scanned_tier '```text
<!-- CodeRabbit review command invocation: fenced-example -->
```
<details>
<summary>⚠️ Action not completed</summary>
Review rate limited.
</details>')" "cr_scan: fenced invocation marker cannot activate the exclusion"

eq "p1" "$(coderabbit_scanned_tier '<!-- pre_merge_checks_walkthrough_start -->
<!-- CodeRabbit review command invocation: excluded-example -->
<!-- pre_merge_checks_walkthrough_end -->
<details>
<summary>⚠️ Action not completed</summary>
Review rate limited.
</details>')" "cr_scan: invocation inside another excluded region cannot activate the exclusion"

eq "p1" "$(coderabbit_scanned_tier '<details>
<summary>⚠️ Action not completed</summary>
Review rate limited.
</details>
<!-- CodeRabbit review command invocation: too-late -->')" "cr_scan: reordered status markers fail toward classification"

eq "p1" "$(coderabbit_scanned_tier '<!-- CodeRabbit review command invocation: live-id -->
<details>
<summary>⚠️ Action not completed — retry manually</summary>
Review rate limited.
</details>')" "cr_scan: non-exact action summary fails toward classification"

eq "p2" "$(coderabbit_scanned_tier "$CR_RATE_LIMIT_STATUS

_📐 Maintainability & Code Quality_ | _🟡 Minor_

**Keep the retry counter bounded.**")" "cr_scan: mixed status plus real Minor preserves the finding"

eq "p1" "$(coderabbit_scanned_tier '<!-- CodeRabbit review command invocation: live-id -->
<details>
<summary>⚠️ Action not completed</summary>
_🟠 Major_ Real finding embedded beside the provider status.
</details>')" "cr_scan: real finding inside status details remains classified"

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

# --- ghas_severity_tier (#1101) ---------------------------------------------
eq "p0" "$(ghas_severity_tier critical)" "ghas_severity_tier: critical -> p0"
eq "p1" "$(ghas_severity_tier high)"     "ghas_severity_tier: high -> p1"
eq "p2" "$(ghas_severity_tier medium)"   "ghas_severity_tier: medium -> p2"
eq "p3" "$(ghas_severity_tier low)"      "ghas_severity_tier: low -> p3"
eq ""   "$(ghas_severity_tier none)"     "ghas_severity_tier: none -> empty (caller decides the fallback)"
eq ""   "$(ghas_severity_tier '')"       "ghas_severity_tier: empty input -> empty"
eq ""   "$(ghas_severity_tier warning)"  "ghas_severity_tier: unrecognized value -> empty"

rc=0; out=$(ghas_severity_tier bogus) || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "ghas_severity_tier: unrecognized is rc0+empty under set -e"; else fail "ghas_severity_tier: unrecognized rc=$rc out=[$out]"; fi

# --- ghas_alert_number_from_body (#1113) ------------------------------------
eq "25" "$(ghas_alert_number_from_body 'See [Show more details](https://github.com/acme/widget/security/code-scanning/25)')" \
  "ghas_alert_number_from_body: extracts the number from a real CodeQL comment link"
eq "25" "$(ghas_alert_number_from_body 'text before /security/code-scanning/25 text after')" \
  "ghas_alert_number_from_body: matches without requiring markdown link syntax"
eq "7" "$(ghas_alert_number_from_body 'https://github.com/owner/repo-name/security/code-scanning/7')" \
  "ghas_alert_number_from_body: works with hyphenated owner/repo names"
eq "3" "$(ghas_alert_number_from_body 'first /security/code-scanning/3 then /security/code-scanning/9')" \
  "ghas_alert_number_from_body: takes the FIRST match when a body links multiple alerts"
eq "" "$(ghas_alert_number_from_body 'no alert link here at all')" \
  "ghas_alert_number_from_body: no link -> empty"
eq "" "$(ghas_alert_number_from_body '')" \
  "ghas_alert_number_from_body: empty body -> empty"
eq "" "$(ghas_alert_number_from_body)" \
  "ghas_alert_number_from_body: missing arg -> empty (does not abort under set -u)"
eq "" "$(ghas_alert_number_from_body '/security/code-scanning/ (no digits)')" \
  "ghas_alert_number_from_body: path with no trailing digits -> empty"

rc=0; out=$(ghas_alert_number_from_body 'no link here') || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "ghas_alert_number_from_body: no match is rc0+empty under set -e"; else fail "ghas_alert_number_from_body: no-match rc=$rc out=[$out]"; fi

# --- read_policy_block_field (#1124) ----------------------------------------
CFG_BLOCK="$WORKDIR/code-scanning-block.yml"
cat > "$CFG_BLOCK" <<'YAML'
external_review_threshold: 300
code_scanning:
  enabled: true
  bot_login: "custom-ghas-bot[bot]"   # inline comment + quotes to strip
feedback_policy:
  mode: by-priority
YAML
eq "custom-ghas-bot[bot]" "$(read_policy_block_field code_scanning bot_login "$CFG_BLOCK")" \
  "read_policy_block_field: reads a field from an arbitrary top-level block, not only feedback_policy:"
eq "true" "$(read_policy_block_field code_scanning enabled "$CFG_BLOCK")" \
  "read_policy_block_field: reads a second field from the same block"
eq "" "$(read_policy_block_field code_scanning missing_field "$CFG_BLOCK")" \
  "read_policy_block_field: absent field in a present block -> empty"
eq "" "$(read_policy_block_field nonexistent_block bot_login "$CFG_BLOCK")" \
  "read_policy_block_field: absent block -> empty"
eq "" "$(read_policy_block_field code_scanning bot_login "$WORKDIR/does-not-exist.yml")" \
  "read_policy_block_field: missing config file -> empty (not an error)"

# Header tolerance (CodeRabbit, PR #1124). resolve_base_policy.sh writes raw
# policy content, so a block header may legitimately carry trailing whitespace
# or a comment; an exact `$0 == block":"` match silently skipped those blocks
# and the caller fell back to the default login only.
CFG_HDR="$WORKDIR/header-shapes.yml"
cat > "$CFG_HDR" <<'YAML'
code_scanning:  # GHAS
  bot_login: "commented-header[bot]"
YAML
eq "commented-header[bot]" "$(read_policy_block_field code_scanning bot_login "$CFG_HDR")" \
  "read_policy_block_field: block header with a trailing comment still matches"

CFG_WS="$WORKDIR/header-trailing-space.yml"
printf 'code_scanning:   \n  bot_login: "spaced-header[bot]"\n' > "$CFG_WS"
eq "spaced-header[bot]" "$(read_policy_block_field code_scanning bot_login "$CFG_WS")" \
  "read_policy_block_field: block header with trailing whitespace still matches"

# The false-positive guard for that relaxation: a DIFFERENT block whose name
# merely starts with the requested one must still not match, or a scan would
# silently read another block's configuration.
CFG_PREFIX="$WORKDIR/header-prefix.yml"
cat > "$CFG_PREFIX" <<'YAML'
code_scanning_extra:
  bot_login: "wrong-block[bot]"
YAML
eq "" "$(read_policy_block_field code_scanning bot_login "$CFG_PREFIX")" \
  "read_policy_block_field: a longer block sharing the prefix does NOT match (no over-capture)"

# And a value that itself looks like a header must not be mistaken for one.
CFG_NEST="$WORKDIR/header-nested.yml"
cat > "$CFG_NEST" <<'YAML'
code_scanning:
  bot_login: "real[bot]"
other_block:
  bot_login: "later[bot]"
YAML
eq "real[bot]" "$(read_policy_block_field code_scanning bot_login "$CFG_NEST")" \
  "read_policy_block_field: a following top-level block still closes the previous one"

# Codex P2, PR #1124: flow-style YAML is valid and accounting (which parses the
# file as YAML) resolves it, but the line-oriented reader cannot see it at all.
# That split let a consumer's custom GHAS bot be inventoried by accounting while
# the fingerprint and archive workflow silently used the default login.
CFG_FLOW="$WORKDIR/flow-style.yml"
cat > "$CFG_FLOW" <<'YAML'
code_scanning: {enabled: true, bot_login: "custom-ghas[bot]"}
YAML
eq "" "$(read_policy_block_field code_scanning bot_login "$CFG_FLOW")" \
  "read_policy_block_field: flow style is invisible to the line reader (the defect, pinned)"
eq "custom-ghas[bot]" "$(policy_block_field_parsed code_scanning bot_login "$CFG_FLOW")" \
  "policy_block_field_parsed: flow-style block resolves (Codex P2, #1124)"
eq "custom-ghas-bot[bot]" "$(policy_block_field_parsed code_scanning bot_login "$CFG_BLOCK")" \
  "policy_block_field_parsed: block style resolves identically, incl. quote + inline-comment stripping"
eq "" "$(policy_block_field_parsed code_scanning missing_field "$CFG_FLOW")" \
  "policy_block_field_parsed: absent field in a present block -> empty"
eq "" "$(policy_block_field_parsed nonexistent_block bot_login "$CFG_FLOW")" \
  "policy_block_field_parsed: absent block -> empty"

# Unreadable/unparseable must be rc 1 ("unknown"), NOT rc 0 with empty output
# ("unset") -- the fingerprint narrows its scan on rc 0 and must never do so on
# a read it could not actually perform.
PARSED_RC=0
policy_block_field_parsed code_scanning bot_login "$WORKDIR/does-not-exist.yml" >/dev/null 2>&1 || PARSED_RC=$?
eq 1 "$PARSED_RC" "policy_block_field_parsed: missing file is rc 1 (unknown), not rc 0 (unset)"

CFG_BROKEN="$WORKDIR/broken.yml"
printf 'code_scanning: {bot_login: "unterminated\n' > "$CFG_BROKEN"
BROKEN_RC=0
policy_block_field_parsed code_scanning bot_login "$CFG_BROKEN" >/dev/null 2>&1 || BROKEN_RC=$?
eq 1 "$BROKEN_RC" "policy_block_field_parsed: unparseable YAML is rc 1 (unknown), not a silent empty"

# Exercise the actual optional Ruby branch independently of whichever parser
# this runner normally selects. Parsing only document1 must not discard later
# policy documents before a caller can reject them.
if ruby -ryaml -rjson -e 'YAML.safe_load("codex: {}")' >/dev/null 2>&1; then
  RUBY_ONLY="$WORKDIR/ruby-only-bin"
  mkdir -p "$RUBY_ONLY"
  for parser in yq python3; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$RUBY_ONLY/$parser"
    chmod +x "$RUBY_ONLY/$parser"
  done
  RUBY_JSON=$(PATH="$RUBY_ONLY:$PATH" policy_yaml_to_json "$CFG_FLOW")
  eq custom-ghas\[bot\] "$(printf '%s' "$RUBY_JSON" | jq -r '.code_scanning.bot_login')" \
    "Ruby fallback preserves a valid flow mapping"
  for suffix in 'code_scanning: {}' '[broken'; do
    printf 'code_scanning: {}\n---\n%s\n' "$suffix" > "$WORKDIR/ruby-multiple.yml"
    RUBY_RC=0
    RUBY_JSON=$(PATH="$RUBY_ONLY:$PATH" policy_yaml_to_json "$WORKDIR/ruby-multiple.yml") || RUBY_RC=$?
    eq 1 "$RUBY_RC" "Ruby fallback rejects additional YAML documents: $suffix"
    eq '' "$RUBY_JSON" "Ruby fallback emits no partial document: $suffix"
  done
fi

# ---------------------------------------------------------------------------
echo
echo "feedback-policy-helpers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
