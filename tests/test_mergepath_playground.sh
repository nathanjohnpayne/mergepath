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
# Public-repo live loader (#732) — modal controls + meta CSP.
# ---------------------------------------------------------------------------
grep -q 'id="repoSlugInput"'                     "$PAGE" || { echo "repo slug input missing (#732)"; exit 1; }
grep -q 'id="repoLimit"'                         "$PAGE" || { echo "repo limit control missing (#732)"; exit 1; }
grep -q 'id="repoLoadBtn"'                       "$PAGE" || { echo "repo load button missing (#732)"; exit 1; }
# Defense-in-depth CSP: constrains ONLY connect-src (pinned to the GitHub
# API origin), so the inline script/styles and the static zero-network base
# behavior are untouched.
grep -q 'http-equiv="Content-Security-Policy"'   "$PAGE" || { echo "meta CSP missing (#732)"; exit 1; }
grep -q "connect-src 'self' https://api.github.com" "$PAGE" || { echo "CSP connect-src allowlist missing/changed (#732)"; exit 1; }

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
    # Public-repo live loader (#732).
    'REPO_RE', 'loadPublicRepo', 'pullPublicRepo', 'rateLimitMsg',
    'currentPRs', 'renderHeaderPill', 'livePRs',
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
# Public-repo loader load-bearing shapes (#732): slug validation before URL
# interpolation, the 1-list + per-PR /files aggregation, and the accessor
# wiring that lets a runtime fetch re-render without a reload. (The
# no-new-innerHTML stance is already enforced by the innerHTML scan above.)
# ---------------------------------------------------------------------------
grep -qF 'const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/' "$CHECK_FILE" \
  || { echo "REPO_RE slug pattern missing/changed (#732)"; exit 1; }
grep -qF 'repoSlugMaxLen' "$CHECK_FILE" || { echo "slug length cap missing (#732)"; exit 1; }
grep -qF 'state=closed&per_page=' "$CHECK_FILE" || { echo "PR list request shape missing (#732)"; exit 1; }
grep -qF '/files?per_page=100' "$CHECK_FILE" || { echo "single-page /files request missing (#732)"; exit 1; }
{ grep -qF 'f.additions' "$CHECK_FILE" && grep -qF 'f.deletions' "$CHECK_FILE"; } \
  || { echo "lines must sum /files additions+deletions (#732)"; exit 1; }
grep -qF 'f.filename' "$CHECK_FILE" || { echo "paths must map /files filenames (#732)"; exit 1; }
grep -qF 'X-RateLimit-Remaining' "$CHECK_FILE" || { echo "rate-limit header message missing (#732)"; exit 1; }
grep -qF 'Authoring-Agent:' "$CHECK_FILE" || { echo "Authoring-Agent author parse missing (#732)"; exit 1; }
grep -qF 'livePRs ?? (Array.isArray(window.__PRS)' "$CHECK_FILE" \
  || { echo "currentPRs accessor fallback chain missing (#732)"; exit 1; }
grep -qF 'const prs = currentPRs()' "$CHECK_FILE" \
  || { echo "renderPRs must route through currentPRs() (#732)"; exit 1; }

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
# Shared minimal-DOM prelude for the JS-execution harnesses below (the YAML
# serialization harness and the #732 public-repo loader harness). Written
# once; each harness prepends it to the page's extracted script body.
DOM_PRELUDE="$TMPDIR_SAFE/dom_prelude.js"
cat > "$DOM_PRELUDE" <<'JS'
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
JS

YAML_HARNESS="$TMPDIR_SAFE/yaml_harness.mjs"

python3 - "$PAGE" "$YAML_HARNESS" "$DOM_PRELUDE" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
html_no_comments = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
scripts = re.findall(r'<script\b[^>]*>(.*?)</script>', html_no_comments, flags=re.DOTALL)
if len(scripts) != 1:
    sys.exit(f"expected exactly one <script> block, found {len(scripts)}")
body = scripts[0].replace("'use strict';", "", 1)

harness = open(sys.argv[3]).read()

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

# ---------------------------------------------------------------------------
# Public-repo loader execution harness (#732). Drive loadPublicRepo /
# pullPublicRepo under the same minimal DOM with a scripted fetch stub:
#   - slug validation (incl. the length cap) rejects BEFORE any network call
#   - 404 / rate-limited 403 / network failure surface distinct messages
#   - the happy path filters unmerged PRs, sums additions+deletions across
#     /files, maps filenames to paths, and honors Authoring-Agent > user.login
#   - pullPublicRepo announces failures via the live region and leaves the
#     current view (livePRs) intact; success flips the header pill to live · N
# The stub also proves the zero-network base behavior: the page body executes
# to completion before any response is queued, so an on-load fetch would have
# thrown and failed the harness.
# ---------------------------------------------------------------------------
LOADER_HARNESS="$TMPDIR_SAFE/loader_harness.mjs"

python3 - "$PAGE" "$LOADER_HARNESS" "$DOM_PRELUDE" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
html_no_comments = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
scripts = re.findall(r'<script\b[^>]*>(.*?)</script>', html_no_comments, flags=re.DOTALL)
if len(scripts) != 1:
    sys.exit(f"expected exactly one <script> block, found {len(scripts)}")
body = scripts[0].replace("'use strict';", "", 1)

fetch_stub = r'''
const __fetchQueue = [];
const __fetchLog = [];
function __queue(status, body, headers) { __fetchQueue.push({ status, body, headers: headers || {} }); }
const fetch = async (url) => {
  __fetchLog.push(String(url));
  if (__fetchQueue.length === 0) throw new TypeError('Failed to fetch');
  const r = __fetchQueue.shift();
  return {
    ok: r.status >= 200 && r.status < 300,
    status: r.status,
    headers: { get: (k) => (Object.prototype.hasOwnProperty.call(r.headers, k) ? r.headers[k] : null) },
    json: async () => r.body,
  };
};
'''

footer = r'''
function fail(m){ console.error('public-repo loader: ' + m); process.exit(1); }

// 1. Validation rejects bad slugs BEFORE any network call. The over-long
//    slug passes REPO_RE, so it exercises the length cap specifically.
const badSlugs = ['no-slash', 'a b/c', 'own/rep/extra', '../../evil', 'x'.repeat(200) + '/y'];
for (const bad of badSlugs) {
  let rejected = false;
  try { await loadPublicRepo(bad, 5); } catch (e) { rejected = /owner\/repo/.test(String(e.message)); }
  if (!rejected) fail('invalid slug accepted: ' + JSON.stringify(bad));
}
if (__fetchLog.length !== 0) fail('slug validation must precede any fetch');

// 2. 404 → repo missing/private message.
__queue(404, {});
let msg404 = '';
try { await loadPublicRepo('octo/gone', 5); } catch (e) { msg404 = String(e.message); }
if (!/not found or private/i.test(msg404)) fail('404 message wrong: ' + msg404);

// 3. 403 with X-RateLimit-Remaining: 0 → rate-limit guidance.
__queue(403, {}, { 'X-RateLimit-Remaining': '0' });
let msg403 = '';
try { await loadPublicRepo('octo/limited', 5); } catch (e) { msg403 = String(e.message); }
if (!/rate limit/i.test(msg403)) fail('403 rate-limit message wrong: ' + msg403);

// 4. Happy path: merged filter, /files aggregation, author precedence.
__queue(200, [
  { number: 7, title: 'Fix a', merged_at: '2026-01-01T00:00:00Z',
    body: 'Body\nAuthoring-Agent: claude\n', user: { login: 'someone' } },
  { number: 6, title: 'Closed, never merged', merged_at: null, body: '', user: { login: 'x' } },
  { number: 5, title: 'Fix b', merged_at: '2026-01-02T00:00:00Z', body: 'no marker', user: { login: 'octocat' } },
]);
__queue(200, [
  { filename: 'src/a.ts', additions: 3, deletions: 1 },
  { filename: 'src/b.ts', additions: 2, deletions: 0 },
]);
__queue(200, [{ filename: 'docs/readme.md', additions: 10, deletions: 5 }]);
const mark = __fetchLog.length;
const got = await loadPublicRepo('octo/demo', 5);
if (__fetchLog.length - mark !== 3) fail('expected 1 list + 2 /files requests, got ' + (__fetchLog.length - mark));
if (!/\/repos\/octo\/demo\/pulls\?state=closed&per_page=5&sort=updated&direction=desc$/.test(__fetchLog[mark]))
  fail('list URL wrong: ' + __fetchLog[mark]);
if (!/\/repos\/octo\/demo\/pulls\/7\/files\?per_page=100$/.test(__fetchLog[mark + 1]))
  fail('files URL wrong: ' + __fetchLog[mark + 1]);
if (got.length !== 2) fail('unmerged PR must be filtered out (got ' + got.length + ')');
if (got[0].id !== '#7' || got[0].author !== 'claude') fail('Authoring-Agent parse failed: ' + JSON.stringify(got[0]));
if (got[0].lines !== 6) fail('lines must sum additions+deletions across files (got ' + got[0].lines + ')');
if (got[0].paths.join(',') !== 'src/a.ts,src/b.ts') fail('paths must be /files filenames: ' + JSON.stringify(got[0].paths));
if (got[1].author !== 'octocat') fail('author must fall back to user.login: ' + got[1].author);
if (got[1].lines !== 15) fail('second PR lines wrong: ' + got[1].lines);

// 5. pullPublicRepo network failure: announces, leaves the view intact.
await pullPublicRepo('octo/down', 5);       // queue empty → network failure
if (livePRs !== null) fail('failed load must leave livePRs untouched');
if (!/Could not load octo\/down/.test(_store['live'].textContent)) fail('failure not announced via live region');

// 6. pullPublicRepo success: sets livePRs, flips the pill, announces.
__queue(200, [{ number: 9, title: 't', merged_at: '2026-01-03T00:00:00Z', body: '', user: { login: 'u' } }]);
__queue(200, [{ filename: 'f.txt', additions: 1, deletions: 1 }]);
await pullPublicRepo('octo/demo', 3);
if (!Array.isArray(livePRs) || livePRs.length !== 1) fail('successful load must set livePRs');
if (_store['livePill'].textContent !== 'live · 1')
  fail('header pill must read "live · 1", got: ' + JSON.stringify(_store['livePill'].textContent));
if (!/Loaded 1 merged PRs from octo\/demo/.test(_store['live'].textContent)) fail('success not announced');

console.error('public-repo loader OK (validation, error surfaces, /files aggregation, accessor wiring)');
'''

open(sys.argv[2], 'w').write(open(sys.argv[3]).read() + fetch_stub + body + footer)
PY

node "$LOADER_HARNESS"

echo "OK: Mergepath Playground checks passed"
