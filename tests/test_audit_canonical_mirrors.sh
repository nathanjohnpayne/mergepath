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

# summary line counts match the fixture (5 real sections)
if grep -q '5 section(s) scanned — ok: 1, ok-unpinned: 1, missing-annotation: 1, source-missing: 1, drift: 1' <<<"$OUT"; then
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

echo
echo "test_audit_canonical_mirrors: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
