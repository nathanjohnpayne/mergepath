#!/usr/bin/env bash
# scripts/policy-sim.sh
#
# Replay the current repo's recent merged PRs through the Mergepath
# dashboard. Runs `gh pr list`, inlines the result into a copy of the
# mockup HTML, and opens it in the default browser.
#
# Usage:   ./scripts/policy-sim.sh [limit]   (default 20)
#
# Requires: gh, jq, python3.

set -euo pipefail

LIMIT="${1:-20}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/mockups/mergepath.html"
OUT="$(mktemp -t mergepath-sim.XXXXXX).html"

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

PRS_FILE="$(mktemp -t mergepath-prs.XXXXXX).json"
trap 'rm -f "$PRS_FILE"' EXIT

gh pr list \
  --state merged \
  --limit "$LIMIT" \
  --json number,title,additions,deletions,author,files,body \
  --jq '[.[] | {
    id: ("#\(.number)"),
    title: .title,
    author: (
      (.body // "")
      | capture("Authoring-Agent:\\s*(?<a>[a-zA-Z0-9_-]+)")?.a
      // .author.login
    ),
    lines: (.additions + .deletions),
    paths: [.files[].path]
  }]' > "$PRS_FILE"

COUNT=$(jq 'length' < "$PRS_FILE")
echo "Got $COUNT PRs. Injecting and opening..."

python3 - "$TEMPLATE" "$OUT" "$PRS_FILE" <<'PY'
import json, sys
template_path, out_path, prs_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(prs_path) as f:
    data = json.load(f)
with open(template_path) as f:
    html = f.read()
injection = "<script>window.__PRS = " + json.dumps(data) + ";</script>"
marker = "<!-- RUBRIC_INJECT -->"
if marker not in html:
    print("error: marker not found in template", file=sys.stderr)
    sys.exit(1)
html = html.replace(marker, injection)
with open(out_path, "w") as f:
    f.write(html)
PY

echo "Output: $OUT"
if   command -v open     >/dev/null 2>&1; then open "$OUT"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$OUT"
else echo "(open manually in your browser)"
fi
