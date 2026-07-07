#!/usr/bin/env bash
# tests/test_mergepath_playground.sh
#
# Validates mergepath/playground/index.html against specs/mergepath_playground.md.
# Run manually or from CI. Requires: python3, node.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGE="$ROOT/mergepath/playground/index.html"
SCRIPT="$ROOT/scripts/policy-sim.sh"
# macOS mktemp only substitutes trailing Xs — `name.XXXXXX.js`
# would work once and then fail with "File exists". Use a temp
# directory and place fixed-name files inside.
#
# Use the portable `mktemp -d "$TMPDIR/name.XXXXXX"` form rather
# than `mktemp -d -t name`: GNU coreutils requires an explicit
# `XXXXXX` placeholder. See mergepath#286.
TMPDIR_SAFE="$(mktemp -d "${TMPDIR:-/tmp}/mergepath-test.XXXXXX")"
CHECK_FILE="$TMPDIR_SAFE/extracted.js"

cleanup() {
  rm -rf "$TMPDIR_SAFE"
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
grep -q 'id="postClearanceWait"'                 "$PAGE" || { echo "post-clearance wait slider missing (#727)"; exit 1; }
grep -q 'data-preset="strict"'                   "$PAGE" || { echo "strict preset missing"; exit 1; }
grep -q 'data-preset="standard"'                 "$PAGE" || { echo "standard preset missing"; exit 1; }
grep -q 'data-preset="loose"'                    "$PAGE" || { echo "loose preset missing"; exit 1; }
grep -q 'aria-modal="true"'                      "$PAGE" || { echo "dialog aria-modal missing"; exit 1; }
grep -q 'aria-live="polite"'                     "$PAGE" || { echo "live region missing"; exit 1; }
grep -q 'prefers-reduced-motion'                 "$PAGE" || { echo "reduced-motion rule missing"; exit 1; }

# Helper script must target the injection marker the page actually ships.
grep -q "MERGEPATH_INJECT\|RUBRIC_INJECT"        "$SCRIPT" || { echo "policy-sim.sh has no marker"; exit 1; }
# Helper script must target MERGEPATH_INJECT specifically (primary marker).
grep -q "MERGEPATH_INJECT"                       "$SCRIPT" || { echo "policy-sim.sh missing primary MERGEPATH_INJECT marker"; exit 1; }
# Helper script must script-safe escape injected JSON so a </script> token in
# a PR title can't terminate the inline <script> block.
grep -q '\\u003c'                                "$SCRIPT" || { echo "policy-sim.sh missing <-escape in JSON payload"; exit 1; }
# Helper script must use `mktemp -d` for output paths. macOS mktemp only
# substitutes TRAILING Xs, so `mktemp /tmp/name.XXXXXX.html` is literal —
# it succeeds once, then every subsequent run fails with "File exists".
grep -q 'mktemp -d'                              "$SCRIPT" || { echo "policy-sim.sh must use mktemp -d (macOS trailing-X limitation)"; exit 1; }
grep -qE '\$\(mktemp [^)]*\.[A-Za-z]+\)'         "$SCRIPT" && { echo "policy-sim.sh uses mktemp with non-trailing Xs; will fail on macOS second run"; exit 1; } || true

# YAML preview must emit full reviewer logins (nathanpayne-*), not short aliases.
grep -q "nathanpayne-claude"                     "$PAGE" || { echo "YAML preview missing full reviewer login nathanpayne-claude"; exit 1; }
grep -q "nathanpayne-codex"                      "$PAGE" || { echo "YAML preview missing full reviewer login nathanpayne-codex"; exit 1; }

# ---------------------------------------------------------------------------
# Feedback-policy panel (#578) — the address-all switch + per-tier checkboxes.
# ---------------------------------------------------------------------------
grep -q 'id="feedbackAddressAll"'                "$PAGE" || { echo "feedback address-all toggle missing"; exit 1; }
grep -q 'id="feedbackTiers"'                     "$PAGE" || { echo "feedback tier group missing"; exit 1; }
grep -q 'data-priority="p0"'                     "$PAGE" || { echo "feedback P0 tier checkbox missing"; exit 1; }
grep -q 'data-priority="p1"'                     "$PAGE" || { echo "feedback P1 tier checkbox missing"; exit 1; }
grep -q 'data-priority="p2"'                     "$PAGE" || { echo "feedback P2 tier checkbox missing"; exit 1; }
grep -q 'data-priority="p3"'                     "$PAGE" || { echo "feedback P3 tier checkbox missing"; exit 1; }

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
    'announce', 'initSyncScroll',
    # Feedback-policy controls (#578).
    'feedbackMode', 'feedbackPriorities', 'syncFeedbackControls',
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
BAKED="$TMPDIR_SAFE/baked.html"

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

# ---------------------------------------------------------------------------
# feedback_policy serialization (#578). Drive renderYaml() under a minimal DOM
# stub in both modes and assert the emitted YAML is a well-formed drop-in:
#   - by-priority emits `mode: by-priority` + the priorities map (required /
#     discretionary), reflecting DEFAULTS (p0/p1 required, p2/p3 discretionary).
#   - address-all emits just `mode: address-all` and OMITS priorities:.
#   - both modes carry codex.p1_gate.enabled and coderabbit.severity_gate.enabled
#     so the preview matches the real review-policy.yml schema.
# ---------------------------------------------------------------------------
YAML_HARNESS="$TMPDIR_SAFE/yaml_harness.mjs"

python3 - "$PAGE" "$YAML_HARNESS" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
html_no_comments = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
scripts = re.findall(r'<script\b[^>]*>(.*?)</script>', html_no_comments, flags=re.DOTALL)
if len(scripts) != 1:
    sys.exit(f"expected exactly one <script> block, found {len(scripts)}")
body = scripts[0].replace("'use strict';", "", 1)

harness = r'''
class FakeNode {
  constructor(){ this.children=[]; this._text=''; this.className=''; this.dataset={}; this.attrs={};
    this.classList={ _s:new Set(), add(c){this._s.add(c);}, remove(c){this._s.delete(c);},
      toggle(c,on){ if(on===undefined){ this._s.has(c)?this._s.delete(c):this._s.add(c);} else { on?this._s.add(c):this._s.delete(c);} },
      contains(c){return this._s.has(c);} }; }
  set textContent(v){ this._text=v; this.children=[]; }
  get textContent(){ return this._text + this.children.map(c=>c.textContent).join(''); }
  appendChild(c){ this.children.push(c); return c; }
  setAttribute(k,v){ this.attrs[k]=v; }
  addEventListener(){}
  querySelectorAll(){ return []; }
  querySelector(){ return new FakeNode(); }
  focus(){}
}
const _store = {};
const document = {
  createElement(){ return new FakeNode(); },
  createTextNode(t){ const n=new FakeNode(); n._text=t; return n; },
  getElementById(id){ if(!_store[id]) _store[id]=new FakeNode(); return _store[id]; },
  querySelectorAll(){ return []; },
  querySelector(){ return new FakeNode(); },
  addEventListener(){},
  activeElement: null,
  body: new FakeNode(),
};
const window = { matchMedia: () => ({ matches:false, addEventListener(){} }), isSecureContext:false };
const navigator = {};
const requestAnimationFrame = () => {};
const setTimeout = () => {};
const structuredClone = (o) => JSON.parse(JSON.stringify(o));
'''

footer = r'''
function emit(){ _store['yaml'] = new FakeNode(); renderYaml(); return _store['yaml'].textContent; }
function fail(m){ console.error("feedback_policy serialization: " + m); process.exit(1); }

state.feedbackMode = 'by-priority';
state.feedbackPriorities = { p0:true, p1:true, p2:false, p3:false };
const byPriority = emit();
state.feedbackMode = 'address-all';
const addressAll = emit();

if (!/coderabbit:\s*\n\s+enabled:.*\n\s+severity_gate:\s*\n\s+enabled:/.test(byPriority))
  fail("coderabbit.severity_gate.enabled missing or misnested");
// #727: post_clearance_max_wait_seconds nested under coderabbit, emitted after
// the severity_gate block (so the enabled→severity_gate chain above stays intact).
if (!/coderabbit:[\s\S]*?\n\s+post_clearance_max_wait_seconds: \d+/.test(byPriority))
  fail("coderabbit.post_clearance_max_wait_seconds missing (#727)");
if (!/codex:[\s\S]*?\n\s+p1_gate:\s*\n\s+enabled:/.test(byPriority))
  fail("codex.p1_gate.enabled missing or misnested");
if (!/feedback_policy:\s*\n\s+mode: by-priority\s*\n\s+priorities:\s*\n\s+p0: required\s*\n\s+p1: required\s*\n\s+p2: discretionary\s*\n\s+p3: discretionary/.test(byPriority))
  fail("by-priority block not well-formed (mode + priorities map)");

const fpStart = addressAll.indexOf('feedback_policy:');
const fpBlock = addressAll.slice(fpStart);
if (!/feedback_policy:\s*\n\s+mode: address-all/.test(fpBlock))
  fail("address-all mode line missing");
if (fpBlock.includes('priorities:'))
  fail("address-all must OMIT the priorities map");
if (!/severity_gate:\s*\n\s+enabled:/.test(addressAll) || !/p1_gate:\s*\n\s+enabled:/.test(addressAll))
  fail("both gate keys must be present in address-all mode too");

console.error("feedback_policy serialization OK (both modes + both gate keys)");
'''

open(sys.argv[2], 'w').write(harness + body + footer)
PY

node "$YAML_HARNESS"

echo "OK: Mergepath Playground checks passed"
