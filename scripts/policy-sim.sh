#!/usr/bin/env bash
# scripts/policy-sim.sh
#
# Replay the current repo's recent merged PRs through the Mergepath
# Playground. Runs `gh pr list`, inlines the result into a copy of the
# Playground HTML, and opens it in the default browser.
#
# Usage:   ./scripts/policy-sim.sh [limit]   (default 20)
#
# Requires: gh, jq, python3.

set -euo pipefail

LIMIT="${1:-20}"
# Validate the limit is a positive integer before handing it to gh (#469):
# an arbitrary string is otherwise passed straight to `gh pr list --limit`,
# which errors opaquely (or, for `0`, silently returns nothing).
if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: limit must be a positive integer (got: '$LIMIT')" >&2
  exit 1
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/mergepath/playground/index.html"

# macOS mktemp only substitutes TRAILING Xs, so
# `mktemp /tmp/name.XXXXXX.html` treats the template as literal —
# the first run succeeds and every subsequent run fails with
# "File exists". Use a unique temp directory and place the baked
# file inside with its extension intact; the dir name carries
# uniqueness, the filename carries the .html so `open` picks the
# right handler.
#
# Use the portable `mktemp -d "$TMPDIR/name.XXXXXX"` form rather
# than `mktemp -d -t name`: BSD mktemp treats `-t` as a prefix and
# auto-appends a template, but GNU coreutils requires an explicit
# `XXXXXX` placeholder and exits non-zero without one. The portable
# form works on both. See mergepath#286.
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mergepath-sim.XXXXXX")"
OUT="$OUT_DIR/mergepath.html"

for bin in gh jq python3; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: '$bin' not on PATH" >&2
    exit 1
  }
done

[[ -f "$TEMPLATE" ]] || {
  echo "error: template not found at $TEMPLATE" >&2
  exit 1
}

echo "Fetching last $LIMIT merged PRs via gh..."

# PRs payload is intermediate; same trailing-X constraint, same
# fix. The trap only cleans up this file — OUT stays so the browser
# can open it. Portable `mktemp -d "$TMPDIR/name.XXXXXX"` per #286.
PRS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mergepath-prs.XXXXXX")"
PRS_FILE="$PRS_DIR/prs.json"
trap 'rm -rf "$PRS_DIR"' EXIT

# Run from REPO_ROOT so `gh pr list` targets THIS repo regardless of the
# caller's CWD (#469): gh resolves the repo from the current directory's
# git remote, so invoking policy-sim.sh from another checkout would
# otherwise list that repo's PRs despite REPO_ROOT being computed above.
# PRS_FILE is an absolute mktemp path, so the redirect is unaffected by cd.
( cd "$REPO_ROOT" && gh pr list \
  --state merged \
  --limit "$LIMIT" \
  --json number,title,additions,deletions,author,files,body \
  --jq '[.[] | {
    id: ("#\(.number)"),
    title: .title,
    author: (
      ((.body // "") | (try capture("Authoring-Agent:\\s*(?<a>[a-zA-Z0-9_-]+)").a catch null))
      // .author.login
    ),
    lines: (.additions + .deletions),
    paths: [.files[].path]
  }]' ) > "$PRS_FILE"

COUNT=$(jq 'length' < "$PRS_FILE")
echo "Got $COUNT PRs. Injecting and opening..."

python3 - "$TEMPLATE" "$OUT" "$PRS_FILE" <<'PY'
import json, sys
template_path, out_path, prs_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(prs_path) as f:
    data = json.load(f)
with open(template_path) as f:
    html = f.read()
# Script-safe JSON escaping: json.dumps alone does not neutralize `</script>`
# or raw `<`/`>`/`&`, so a merged PR title or path could terminate the inline
# <script> block and inject arbitrary markup. Escape those bytes as
# unicode-encoded forms per the HTML5 "script-safe JSON" guidance.
payload = (
    json.dumps(data)
    .replace("&", "\\u0026")
    .replace("<", "\\u003c")
    .replace(">", "\\u003e")
    .replace("\u2028", "\\u2028")
    .replace("\u2029", "\\u2029")
)
injection = "<script>window.__PRS = " + payload + ";</script>"
for marker in ("<!-- MERGEPATH_INJECT -->", "<!-- RUBRIC_INJECT -->"):
    if marker in html:
        html = html.replace(marker, injection, 1)
        break
else:
    print("error: no injection marker found in template", file=sys.stderr)
    sys.exit(1)
with open(out_path, "w") as f:
    f.write(html)
PY

echo "Output: $OUT"
if   command -v open     >/dev/null 2>&1; then open "$OUT"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$OUT"
else echo "(open manually in your browser)"
fi
