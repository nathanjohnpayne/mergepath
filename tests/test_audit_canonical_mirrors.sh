#!/usr/bin/env bash
# tests/test_audit_canonical_mirrors.sh
#
# Unit tests for scripts/audit-canonical-mirrors.sh — the read-only
# canonical-mirror drift triage aid added in #739.
#
# Fully hermetic: builds a fixture "mergepath checkout" and fixture
# vendor files under a temp dir, points the script at them via
# MERGEPATH_ROOT + CLI args / AUDIT_CANONICAL_MIRROR_FILES, and asserts
# on the report classifications. No git, no network, no reads of the
# real ~/GitHub/CLAUDE.md.
#
# Cases exercised:
#   1. Section with no `Canonical source:` line → [missing-annotation].
#   2. Annotated + sha256-pinned section whose pin matches the current
#      canonical file → [ok].
#   3. Annotated + pinned section whose pin is stale → [drift] (and the
#      report names both the pinned and current prefixes).
#   4. Annotated section without a pin → [ok-unpinned].
#   5. Annotation pointing at a path absent from the mergepath fixture
#      → [source-missing].
#   6. A `##` heading and an annotation-looking line inside a fenced
#      code block are ignored (not a section, not an annotation).
#   7. Exit code is 0 even with findings present (triage aid, not a
#      gate), and the audited vendor file is byte-identical afterwards
#      (read-only contract).
#   8. An explicitly named missing file exits 2; a missing DEFAULT-list
#      file (via AUDIT_CANONICAL_MIRROR_FILES) is reported as skipped
#      with exit 0.
#   9. Bold `> **Canonical source:**` annotation form (the style the
#      real machine file uses) is recognized.
#  10. A 4-backtick outer fence containing a triple-backtick inner fence
#      (the standard way to nest a fenced example) is NOT closed by the
#      inner ``` lines: a fake `##` heading and annotation inside the
#      outer fence are ignored, and a real section AFTER the 4-backtick
#      closer is still parsed (CommonMark closing-fence run-length rule;
#      round-1 Codex regression).
#  11. An opener-LOOKING line with an info string (a literal ```bash
#      shown inside an open triple-backtick block) is fence CONTENT, not
#      a closer: per CommonMark a closing fence may carry only
#      whitespace after the delimiter run. The fake `##` heading and
#      annotation after it stay inside the fence, and the real section
#      after the true (bare) closer is still parsed (round-2 Codex
#      regression).
#  12. A 4-space-INDENTED ``` inside an open fence is indented CODE, not
#      a fence delimiter (CommonMark allows at most 3 leading spaces).
#      A pair of them used to close and re-open the fence, fabricating a
#      whole section out of the `##` line between them; both must now be
#      ignored so nothing inside the outer fence leaks into the report
#      (#762 finding 2).
#  13. An annotation whose path escapes MERGEPATH_ROOT via `..`
#      (`mergepath/../outside.md`) is rejected as [invalid-source] and
#      never hashed — even when the pin matches the outside file, which
#      is exactly what used to make it report [ok] (#762 finding 3).
#  14. An ABSOLUTE annotated path is rejected as [invalid-source] rather
#      than silently concatenated onto MERGEPATH_ROOT.
#  15. An in-checkout path whose final component is a SYMLINK pointing
#      outside MERGEPATH_ROOT is rejected as [invalid-source]: lexical
#      normalization cannot see it, so the physical containment check
#      has to.
#  16. A symlink whose target is ALSO inside MERGEPATH_ROOT is rejected
#      as [invalid-source] as well. The containment check refuses every
#      symlink final component, escaping or not, because lexical
#      normalization cannot follow a link and therefore cannot prove
#      the target is safe. Test 15 alone passes under either reading;
#      this fixture pins the intended one (#762 r2 P3).
#  17. `--help` emits the COMPLETE header comment block. usage() used a
#      hardcoded `sed -n '2,65p'` range that the header outgrew, so the
#      output stopped mid-sentence and dropped MERGEPATH_ROOT plus the
#      entire exit-code section. The assertion derives the expected last
#      line from the script source rather than hardcoding one, so any
#      future short range fails here too (#762 r3 P2).
#  18. `--help` survives header GROWTH, proved by perturbation rather
#      than by re-deriving the bound: a copy of the script with extra
#      comment lines appended to the end of its header must emit them.
#      Case 17 computes its expected last line with usage()'s own rule,
#      so it cannot distinguish a correct bound from a self-consistent
#      wrong one; this case never reimplements the rule (#781 item 5).
#  19. A blank (un-prefixed) line INSIDE the header does not terminate
#      the block. The dynamic bound stops at the first non-comment line,
#      so one stray line — an editor stripping a `#`-only separator, a
#      paste that drops the marker — silently truncated `--help`
#      mid-sentence exactly the way the hardcoded range did, and case 17
#      passed anyway because its expected value truncated identically
#      (#781 item 5).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-canonical-mirrors.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-mirrors-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── Fixture mergepath checkout ────────────────────────────────────────
MP="$WORKDIR/mergepath"
mkdir -p "$MP/docs/agents"
printf 'canonical content v1\n' > "$MP/docs/agents/worktree-placement.md"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
FRESH_PIN="$(sha256_of "$MP/docs/agents/worktree-placement.md")"
FRESH_PIN="${FRESH_PIN:0:12}"

# ── Fixture file OUTSIDE the fixture checkout (#762 finding 3) ────────
# Sibling of $MP, so `mergepath/../outside-the-checkout.md` resolves to
# it. Pinned with its REAL sha256 so the unfixed parser reports [ok] on
# a file it had no business hashing; the fixed parser must reject the
# annotation before it ever gets there.
OUTSIDE="$WORKDIR/outside-the-checkout.md"
printf 'content that lives outside the canonical checkout\n' > "$OUTSIDE"
OUTSIDE_PIN="$(sha256_of "$OUTSIDE")"
OUTSIDE_PIN="${OUTSIDE_PIN:0:12}"

# Absolute-path fixture: a real file, named by absolute path, which must
# still be rejected rather than concatenated onto MERGEPATH_ROOT.
ABSOLUTE_TARGET="$WORKDIR/absolute-target.md"
printf 'absolute-path target\n' > "$ABSOLUTE_TARGET"

# Symlink INSIDE the checkout whose target is outside it. Lexical
# normalization sees a clean `docs/agents/...` path; only the physical
# containment check catches the escape.
ln -s "$OUTSIDE" "$MP/docs/agents/symlinked-outside.md"

# Symlink inside the checkout whose target is ALSO inside it. The
# containment check rejects ANY symlink final component, escaping or not
# (`[ -L "$abs" ]`), so this must be [invalid-source] too. Without this
# fixture the escaping symlink alone cannot distinguish "rejects symlinks
# unconditionally" from "rejects symlinks that escape" — test 15 passes
# under both readings (#762 r2 P3).
printf 'canonical content that lives INSIDE the checkout\n' > "$MP/docs/agents/inside-target.md"
ln -s "inside-target.md" "$MP/docs/agents/symlinked-inside.md"

# ── Fixture vendor file ───────────────────────────────────────────────
VENDOR="$WORKDIR/CLAUDE.md"
cat > "$VENDOR" <<EOF
# Machine-Level Instructions

Preamble before the first section is not a section.

## Local Only Section

Genuinely machine-local content, no annotation.

\`\`\`bash
## this heading is inside a fence and must be ignored
# Canonical source: mergepath/inside/a/fence.md
\`\`\`

## Pinned Fresh Mirror

> Canonical source: \`mergepath/docs/agents/worktree-placement.md\` (canonical-sha256: $FRESH_PIN)

## Pinned Stale Mirror

> **Canonical source:** \`mergepath/docs/agents/worktree-placement.md\` (canonical-sha256: 000000000000)

## Unpinned Mirror

> Canonical source: mergepath/docs/agents/worktree-placement.md

## Dangling Mirror

> Canonical source: \`mergepath/docs/agents/does-not-exist.md\`

## Nested Fence Mirror

> Canonical source: mergepath/docs/agents/worktree-placement.md

\`\`\`\`markdown
\`\`\`bash
## fake heading inside a nested fence
\`\`\`
## still inside the 4-backtick outer fence
# Canonical source: mergepath/inside/nested/fence.md
\`\`\`\`

## After Nested Fence

Real section after the 4-backtick closer, no annotation.

## Info String Closer Mirror

> Canonical source: mergepath/docs/agents/worktree-placement.md

\`\`\`text
\`\`\`bash
## fake heading after an opener-like info-string line
# Canonical source: mergepath/inside/info-string/fence.md
\`\`\`

## After Info String Closer

Real section after the whitespace-only closer, no annotation.

## Indented Fence Mirror

> Canonical source: mergepath/docs/agents/worktree-placement.md

\`\`\`markdown
A doc example that shows a fence indented four spaces:

    \`\`\`
## fake heading between two 4-space-indented delimiters
# Canonical source: mergepath/inside/indented/fence.md
    \`\`\`
\`\`\`

## After Indented Fence

Real section after the true closer, no annotation.

## Escaping Source Mirror

> Canonical source: \`mergepath/../outside-the-checkout.md\` (canonical-sha256: $OUTSIDE_PIN)

## Absolute Source Mirror

> Canonical source: \`$ABSOLUTE_TARGET\`

## Symlinked Source Mirror

> Canonical source: \`mergepath/docs/agents/symlinked-outside.md\`

## Symlinked Inside Source Mirror

> Canonical source: \`mergepath/docs/agents/symlinked-inside.md\`
EOF

cp "$VENDOR" "$WORKDIR/CLAUDE.md.orig"

# ── Run the audit ─────────────────────────────────────────────────────
set +e
OUT="$(MERGEPATH_ROOT="$MP" "$SCRIPT" "$VENDOR" 2>&1)"
RC=$?
set -e

# 7a. exit 0 despite findings
if [ "$RC" -eq 0 ]; then
  pass "exits 0 with findings present (triage aid, not a gate)"
else
  fail "expected exit 0, got $RC; output: $OUT"
fi

# 1. missing annotation flagged
if grep -q '\[missing-annotation\] ## Local Only Section' <<<"$OUT"; then
  pass "unannotated section flagged missing-annotation"
else
  fail "missing-annotation not reported for Local Only Section"
fi

# 2. fresh pin → ok
if grep -q '\[ok\] *## Pinned Fresh Mirror' <<<"$OUT"; then
  pass "matching sha256 pin classified ok"
else
  fail "Pinned Fresh Mirror not classified ok"
fi

# 3. stale pin → drift, with both prefixes named
if grep -q '\[drift\] *## Pinned Stale Mirror' <<<"$OUT" \
  && grep -q 'pinned 000000000000' <<<"$OUT" \
  && grep -q "current $FRESH_PIN" <<<"$OUT"; then
  pass "stale sha256 pin classified drift with pinned+current prefixes"
else
  fail "Pinned Stale Mirror drift report wrong; output: $OUT"
fi

# 9. bold annotation form recognized (it classified as drift above, not
# missing-annotation — assert explicitly for clarity)
if grep -q '\[missing-annotation\] ## Pinned Stale Mirror' <<<"$OUT"; then
  fail "bold **Canonical source:** form not recognized as an annotation"
else
  pass "bold **Canonical source:** annotation form recognized"
fi

# 4. unpinned → ok-unpinned
if grep -q '\[ok-unpinned\] *## Unpinned Mirror' <<<"$OUT"; then
  pass "unpinned annotation classified ok-unpinned"
else
  fail "Unpinned Mirror not classified ok-unpinned"
fi

# 5. dangling source → source-missing
if grep -q '\[source-missing\] *## Dangling Mirror' <<<"$OUT"; then
  pass "dangling canonical path classified source-missing"
else
  fail "Dangling Mirror not classified source-missing"
fi

# 6. fenced heading/annotation ignored
if grep -q 'inside a fence' <<<"$OUT"; then
  fail "fenced-block heading or annotation leaked into the report"
else
  pass "fenced-block ## heading and annotation line ignored"
fi

# 10a. inner ``` lines do not close the 4-backtick outer fence: the fake
# heading and annotation inside it must never surface in the report.
if grep -q 'inside a nested fence' <<<"$OUT" || grep -q '4-backtick outer fence' <<<"$OUT"; then
  fail "content inside a 4-backtick outer fence leaked into the report (inner \`\`\` closed it)"
else
  pass "4-backtick outer fence not closed by inner triple-backtick lines"
fi

# 10b. the section owning the nested fence keeps its pre-fence annotation.
if grep -q '\[ok-unpinned\] *## Nested Fence Mirror' <<<"$OUT"; then
  pass "section containing a nested fence classified from its real annotation"
else
  fail "Nested Fence Mirror not classified ok-unpinned; output: $OUT"
fi

# 10c. the 4-backtick closer really closes the fence: the next real
# section is parsed (with old truncated-marker tracking the closer
# re-opened a fence and swallowed it).
if grep -q '\[missing-annotation\] ## After Nested Fence' <<<"$OUT"; then
  pass "real section after the 4-backtick closer still parsed"
else
  fail "After Nested Fence section swallowed — 4-backtick closer did not close the fence"
fi

# 11a. an opener-looking ```bash line inside an open ``` fence is fence
# CONTENT, not a closer: the fake heading + annotation after it must
# never surface in the report.
if grep -q 'info-string' <<<"$OUT"; then
  fail "content after an opener-like \`\`\`bash line inside an open fence leaked into the report (info-string line treated as a closer)"
else
  pass "opener-like info-string line inside an open fence not treated as a closer"
fi

# 11b. the section owning that fence keeps its pre-fence annotation.
if grep -q '\[ok-unpinned\] *## Info String Closer Mirror' <<<"$OUT"; then
  pass "section containing the info-string fence classified from its real annotation"
else
  fail "Info String Closer Mirror not classified ok-unpinned; output: $OUT"
fi

# 11c. the bare ``` line after it really closes the fence: the next real
# section is parsed.
if grep -q '\[missing-annotation\] ## After Info String Closer' <<<"$OUT"; then
  pass "real section after the whitespace-only closer still parsed"
else
  fail "After Info String Closer section swallowed — bare closer did not close the fence"
fi

# 12a. a 4-space-indented ``` is indented CODE, not a fence delimiter:
# nothing between the two indented delimiters may reach the report. With
# the whitespace-stripping parser the first one CLOSED the outer fence,
# so the `##` line below it became a fabricated real section.
if grep -q 'between two 4-space-indented delimiters' <<<"$OUT" \
  || grep -q 'indented/fence.md' <<<"$OUT"; then
  fail "a 4-space-indented \`\`\` toggled fence state and leaked in-fence content into the report"
else
  pass "4-space-indented \`\`\` inside a fence ignored (CommonMark 3-space limit)"
fi

# 12b. the section owning that fence keeps its pre-fence annotation.
if grep -q '\[ok-unpinned\] *## Indented Fence Mirror' <<<"$OUT"; then
  pass "section containing the indented fence classified from its real annotation"
else
  fail "Indented Fence Mirror not classified ok-unpinned; output: $OUT"
fi

# 12c. the real (unindented) closer still closes the fence.
if grep -q '\[missing-annotation\] ## After Indented Fence' <<<"$OUT"; then
  pass "real section after the unindented closer still parsed"
else
  fail "After Indented Fence section swallowed — the unindented closer did not close the fence"
fi

# 13. a `..` escape is rejected before hashing. The fixture pin MATCHES the
# outside file, so the unfixed parser reported [ok] on it.
ESCAPE_LABEL=$(grep -o '\[[a-z-]*\] *## Escaping Source Mirror' <<<"$OUT" | head -n1)
if grep -q '\[invalid-source\] *## Escaping Source Mirror' <<<"$OUT"; then
  pass "annotation escaping MERGEPATH_ROOT via .. classified invalid-source"
else
  fail "escaping annotation not rejected (label='$ESCAPE_LABEL'); output: $OUT"
fi
if grep -q "pin $OUTSIDE_PIN matches" <<<"$OUT"; then
  fail "SECURITY: the escaping annotation was hashed and reported as a pin match"
else
  pass "escaping annotation was never hashed (no pin-match line for the outside file)"
fi

# 14. an absolute annotated path is rejected, not concatenated.
if grep -q '\[invalid-source\] *## Absolute Source Mirror' <<<"$OUT"; then
  pass "absolute annotated path classified invalid-source"
else
  fail "absolute annotated path not rejected; output: $OUT"
fi

# 15. a symlink inside the checkout pointing outside it is rejected by the
# physical containment check (lexical normalization cannot see it).
if grep -q '\[invalid-source\] *## Symlinked Source Mirror' <<<"$OUT"; then
  pass "in-checkout symlink resolving outside MERGEPATH_ROOT classified invalid-source"
else
  fail "symlink escaping MERGEPATH_ROOT not rejected; output: $OUT"
fi

# 16 (#762 r2 P3). a symlink whose target is INSIDE the checkout is rejected
# too — the containment check refuses every symlink final component, because
# lexical normalization cannot follow a link and so cannot PROVE the target is
# safe. Pins the intended semantics, which test 15 alone cannot distinguish
# from "reject only escaping symlinks".
if grep -q '\[invalid-source\] *## Symlinked Inside Source Mirror' <<<"$OUT"; then
  pass "symlink pointing INSIDE MERGEPATH_ROOT also classified invalid-source (unconditional)"
else
  fail "inside-pointing symlink not rejected — containment check is not unconditional; output: $OUT"
fi

# summary line counts match the fixture (15 real sections)
if grep -q '15 section(s) scanned — ok: 1, ok-unpinned: 4, missing-annotation: 4, source-missing: 1, invalid-source: 4, drift: 1' <<<"$OUT"; then
  pass "summary counters match fixture"
else
  fail "summary counters wrong; output: $OUT"
fi

# 7b. read-only: vendor file unchanged
if cmp -s "$VENDOR" "$WORKDIR/CLAUDE.md.orig"; then
  pass "vendor file byte-identical after audit (read-only)"
else
  fail "vendor file was modified by the audit"
fi

# 8a. explicitly named missing file → exit 2
set +e
MERGEPATH_ROOT="$MP" "$SCRIPT" "$WORKDIR/nope.md" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -eq 2 ]; then
  pass "explicitly named missing file exits 2"
else
  fail "expected exit 2 for missing explicit file, got $RC"
fi

# 8b. missing default-list file (env override) → skipped, exit 0
set +e
OUT2="$(MERGEPATH_ROOT="$MP" AUDIT_CANONICAL_MIRROR_FILES="$WORKDIR/absent-default.md $VENDOR" "$SCRIPT" 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q 'absent — skipped' <<<"$OUT2" \
  && grep -q '\[ok\] *## Pinned Fresh Mirror' <<<"$OUT2"; then
  pass "absent default-list file skipped; remaining files still audited; exit 0"
else
  fail "env-override default list handling wrong (rc=$RC); output: $OUT2"
fi

# ── 17. `--help` emits the COMPLETE header block (#762 r3 P2) ─────────
# usage() used to be `sed -n '2,73p'`. The header outgrew the hardcoded end
# line, so --help stopped mid-sentence at "whitespace-separated file list
# that" and silently dropped the MERGEPATH_ROOT entry and the ENTIRE "Exit
# codes" section — the part a caller wiring this into a script most needs.
set +e
HELP="$("$SCRIPT" --help)"
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
  pass "--help exits 0"
else
  fail "--help exited $RC, expected 0"
fi
if grep -q '^Exit codes:' <<<"$HELP" && grep -q '^  MERGEPATH_ROOT ' <<<"$HELP"; then
  pass "--help includes the MERGEPATH_ROOT entry and the Exit codes section"
else
  fail "--help truncated; tail was: $(tail -3 <<<"$HELP")"
fi

# The anti-rot assertion: --help must run to the LAST line of the header
# comment block, whatever that line happens to be. Derived independently from
# the script source, so a range that stops short — for any reason, including a
# future hardcoded one — fails here rather than shipping a truncated --help.
HEADER_LAST="$(awk '
  NR == 1 { next }
  /^#/    { line = $0; sub(/^# ?/, "", line); last = line; next }
            { exit }
  END     { print last }
' "$SCRIPT")"
if [ "$(tail -1 <<<"$HELP")" = "$HEADER_LAST" ]; then
  pass "--help runs to the last header-comment line (no truncation)"
else
  fail "--help ends at '$(tail -1 <<<"$HELP")', expected '$HEADER_LAST'"
fi

# ...and must not run PAST it into executable code.
if grep -q 'set -euo pipefail' <<<"$HELP"; then
  fail "--help leaked script body past the header comment block"
else
  pass "--help stops at the header block (no script body leaked)"
fi

# ── 18/19. `--help` bound proved by PERTURBATION (#781 item 5) ────────
# Case 17 derives its expected last line with the same rule usage() uses, so
# it agrees with any self-consistent bound — including a wrong one. These two
# cases never reimplement the rule: they grow the header of a COPY of the
# script and assert the new text reaches `--help`. A hardcoded range fails
# variant A; a bound that stops at the first blank line fails variant B.
#
# The injection point is the first line after the shebang that is not a
# comment, i.e. the end of the header block, located without a line number.
grow_header() {
  # $1 = destination script, $2 = file whose lines are spliced in
  awk -v extra="$2" '
    NR == 1 { print; next }
    !injected && $0 !~ /^#/ {
      while ((getline extra_line < extra) > 0) print extra_line
      close(extra)
      injected = 1
    }
            { print }
  ' "$SCRIPT" > "$1"
  chmod +x "$1"
}

# Variant A — the header simply grows. Under the historical
# `sed -n '2,NNp'` form the appended lines fall outside the range and vanish.
printf '#   HEADER-SENTINEL-GROWTH  an entry appended below the old end line\n#                           and its continuation line\n' \
  > "$WORKDIR/extra-growth.txt"
grow_header "$WORKDIR/grown.sh" "$WORKDIR/extra-growth.txt"
GROWN_HELP="$("$WORKDIR/grown.sh" --help)"
if grep -q 'HEADER-SENTINEL-GROWTH' <<<"$GROWN_HELP" \
  && grep -q 'and its continuation line' <<<"$GROWN_HELP"; then
  pass "--help emits header lines appended after the previous end (no hardcoded range)"
else
  fail "--help dropped appended header lines; tail was: $(tail -3 <<<"$GROWN_HELP")"
fi
if grep -q 'set -euo pipefail' <<<"$GROWN_HELP"; then
  fail "grown-header --help leaked script body past the header block"
else
  pass "grown-header --help still stops before the script body"
fi

# Variant B — a stray un-prefixed blank line lands INSIDE the header. The
# comment lines after it are still header, and must still be emitted.
printf '#\n\n#   HEADER-SENTINEL-AFTER-BLANK  header text following a stray blank line\n' \
  > "$WORKDIR/extra-blank.txt"
grow_header "$WORKDIR/blank-in-header.sh" "$WORKDIR/extra-blank.txt"
BLANK_HELP="$("$WORKDIR/blank-in-header.sh" --help)"
if grep -q 'HEADER-SENTINEL-AFTER-BLANK' <<<"$BLANK_HELP"; then
  pass "--help does not truncate at a blank line inside the header block"
else
  fail "--help truncated at an interior blank line; tail was: $(tail -3 <<<"$BLANK_HELP")"
fi
if grep -q 'set -euo pipefail' <<<"$BLANK_HELP"; then
  fail "blank-in-header --help leaked script body past the header block"
else
  pass "blank-in-header --help still stops before the script body"
fi
# The trailing blank that separates header from code is NOT emitted, so the
# last line stays real usage text rather than an empty line.
if [ -n "$(tail -1 <<<"$BLANK_HELP")" ]; then
  pass "--help does not emit the blank line separating header from code"
else
  fail "--help ended with an empty line (trailing blanks flushed)"
fi

echo
echo "test_audit_canonical_mirrors: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
