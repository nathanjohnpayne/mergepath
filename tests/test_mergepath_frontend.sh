#!/usr/bin/env bash
# tests/test_mergepath_frontend.sh
#
# Validates mockups/mergepath.html against specs/mergepath_policy_configurator.md.
# Run manually or from CI. Requires: python3, node.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGE="$ROOT/mockups/mergepath.html"
SCRIPT="$ROOT/scripts/policy-sim.sh"
CHECK_FILE="$(mktemp /tmp/mergepath-check.XXXXXX.js)"

cleanup() {
  rm -f "$CHECK_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# File existence
# ---------------------------------------------------------------------------
[[ -f "$PAGE" ]]   || { echo "missing $PAGE" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Anchors required by the spec
# ---------------------------------------------------------------------------
grep -q "<title>Mergepath</title>"              "$PAGE" || { echo "title missing"; exit 1; }
grep -q "MERGEPATH_INJECT"                       "$PAGE" || { echo "injection marker missing"; exit 1; }
grep -q "RUBRIC_INJECT"                          "$PAGE" || { echo "legacy marker missing"; exit 1; }
grep -q 'id="threshold"'                         "$PAGE" || { echo "threshold slider missing"; exit 1; }
grep -q 'id="pathChips"'                         "$PAGE" || { echo "path chips container missing"; exit 1; }
grep -q 'id="codexRounds"'                       "$PAGE" || { echo "codex rounds slider missing"; exit 1; }
grep -q 'data-preset="strict"'                   "$PAGE" || { echo "strict preset missing"; exit 1; }
grep -q 'data-preset="standard"'                 "$PAGE" || { echo "standard preset missing"; exit 1; }
grep -q 'data-preset="loose"'                    "$PAGE" || { echo "loose preset missing"; exit 1; }
grep -q 'aria-modal="true"'                      "$PAGE" || { echo "dialog aria-modal missing"; exit 1; }
grep -q 'aria-live="polite"'                     "$PAGE" || { echo "live region missing"; exit 1; }
grep -q 'prefers-reduced-motion'                 "$PAGE" || { echo "reduced-motion rule missing"; exit 1; }

# Helper script must target the injection marker the page actually ships.
grep -q "MERGEPATH_INJECT\|RUBRIC_INJECT"        "$SCRIPT" || { echo "policy-sim.sh has no marker"; exit 1; }

# ---------------------------------------------------------------------------
# XSS-safety stance: data must never flow through innerHTML.
# Also extract the script block to $CHECK_FILE for node --check.
# ---------------------------------------------------------------------------
python3 - "$PAGE" "$CHECK_FILE" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
html_no_comments = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
scripts = re.findall(r'<script\b[^>]*>(.*?)</script>', html_no_comments, flags=re.DOTALL)
if len(scripts) != 1:
    sys.exit(f"expected exactly one <script> block, found {len(scripts)}")
body = scripts[0]

# Any innerHTML assignment is suspicious. Allow only literal empty string.
bad = []
for m in re.finditer(r'\binnerHTML\s*=\s*([^\n;]+)', body):
    rhs = m.group(1).strip()
    if rhs in ("''", '""'):
        continue
    bad.append(m.group(0).strip())
if bad:
    print("Disallowed innerHTML usage found:", file=sys.stderr)
    for b in bad:
        print("  ", b, file=sys.stderr)
    sys.exit(2)

# Required symbols the spec calls out.
required = [
    'DEFAULTS', 'PRESETS', 'LIMITS',
    'compileGlob', 'matchGlob', 'simulate', 'normalizePR',
    'validatePath', 'copyText', 'openModal', 'closeModal',
    'renderChips', 'renderPRs', 'renderYaml', 'applyPreset',
    'announce',
]
missing = [name for name in required if name not in body]
if missing:
    sys.exit("missing required JS symbols: " + ", ".join(missing))

open(sys.argv[2], 'w').write(body)
PY

# ---------------------------------------------------------------------------
# JS syntax check
# ---------------------------------------------------------------------------
node --check "$CHECK_FILE"

# ---------------------------------------------------------------------------
# Injection round-trip: inject a fake PR payload, confirm marker is consumed
# and the baked copy still parses.
# ---------------------------------------------------------------------------
BAKED="$(mktemp /tmp/mergepath-baked.XXXXXX.html)"
trap 'rm -f "$CHECK_FILE" "$BAKED"' EXIT

python3 - "$PAGE" "$BAKED" <<'PY'
import sys
src = open(sys.argv[1]).read()
marker = '<!-- MERGEPATH_INJECT -->'
if marker not in src:
    sys.exit('MERGEPATH_INJECT marker missing')
injected = src.replace(
    marker,
    '<script>window.__PRS = [{"id":"#1","title":"t","author":"a","lines":1,"paths":["x"]}];</script>',
    1,
)
if '<!-- MERGEPATH_INJECT -->' in injected:
    sys.exit('marker not consumed by replacement')
if 'window.__PRS' not in injected:
    sys.exit('payload missing after injection')
open(sys.argv[2], 'w').write(injected)
PY

# Re-verify JS still parses after injection.
python3 - "$BAKED" <<'PY' > "$CHECK_FILE"
import re, sys
html = open(sys.argv[1]).read()
html_no_comments = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
scripts = re.findall(r'<script\b[^>]*>(.*?)</script>', html_no_comments, flags=re.DOTALL)
sys.stdout.write('\n'.join(scripts))
PY
node --check "$CHECK_FILE"

echo "OK: mergepath frontend checks passed"
