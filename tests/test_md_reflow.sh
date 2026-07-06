#!/usr/bin/env bash
# test_md_reflow.sh — behavior lock for scripts/lib/md_reflow.py, the
# render-preserving Markdown prose reflow used by the md-prose-wrap gate.
#
# Run by .github/workflows/md-prose-wrap.yml (where markdown-it-py is
# installed). It is NOT wired into repo_lint.yml — that workflow has no
# markdown-it-py — so this suite self-skips (exit 0) when the dependency is
# absent, mirroring the gate's own self-bootstrap posture.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${MD_REFLOW_PYTHON:-python3}"
REFLOW="$REPO_ROOT/scripts/lib/md_reflow.py"

if ! command -v "$PYTHON" >/dev/null 2>&1 || ! "$PYTHON" -c 'import markdown_it' >/dev/null 2>&1; then
  echo "SKIP: markdown-it-py not available; skipping md_reflow tests (self-bootstrap)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
pass=0

check() { # check <label> <condition-rc>
  if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else
    echo "FAIL: $1" >&2
    fail=$((fail + 1))
  fi
}

reflow() { # reflow <file> — runs md_reflow --write and REPORTS a non-zero
  # exit as a FAIL via check(), instead of aborting the whole suite under
  # set -e (the #699 fix) or silently swallowing the failure (the bug that
  # fix introduced: `|| true` alone would let a crashed --write pass every
  # downstream assertion that merely checks the file's post-state).
  local rc=0
  "$PYTHON" "$REFLOW" --write "$1" >/dev/null 2>&1 || rc=$?
  check "reflow --write succeeded on $1" "$rc"
}

# has_line <file> <exact-line> — whole-line fixed-string match, dash-safe.
has_line() { grep -qxF -e "$2" "$1"; }

# 1. A hard-wrapped paragraph collapses to a single line.
printf 'A paragraph that was\nwrapped across three\nphysical lines.\n' >"$WORK/p.md"
reflow "$WORK/p.md"
check "wrapped paragraph joins to one line" \
  "$([ "$(grep -c . "$WORK/p.md")" -eq 1 ] && echo 0 || echo 1)"
check "joined text is correct" \
  "$(has_line "$WORK/p.md" 'A paragraph that was wrapped across three physical lines.' && echo 0 || echo 1)"

# 2. A GFM table is byte-identical (must NOT be realigned/padded). Compare the
# pipe-table lines extracted from the original vs the reflowed file.
cat >"$WORK/t.md" <<'EOF'
Intro paragraph that is
wrapped here.

| Col | Meaning |
|---|---|
| a | first |
| b | second |
EOF
before="$(grep -E '^\|' "$WORK/t.md")"
reflow "$WORK/t.md"
after="$(grep -E '^\|' "$WORK/t.md")"
check "table untouched byte-for-byte" "$([ "$before" = "$after" ] && echo 0 || echo 1)"
check "table not padded/realigned" \
  "$(grep -qF -e '| --- |' "$WORK/t.md" && echo 1 || echo 0)"

# 3. A fenced code block (with prose-looking lines) is untouched.
cat >"$WORK/c.md" <<'EOF'
Lead paragraph wrapped
onto two lines.

```text
this line is long and looks like prose
but it lives inside a fence so stays put
```
EOF
reflow "$WORK/c.md"
check "fenced code preserved" \
  "$(has_line "$WORK/c.md" 'this line is long and looks like prose' && echo 0 || echo 1)"

# 4. YAML front matter is preserved verbatim.
cat >"$WORK/f.md" <<'EOF'
---
title: Thing
tags: [a, b]
---

Body paragraph wrapped
across two lines.
EOF
reflow "$WORK/f.md"
check "front matter preserved" \
  "$(has_line "$WORK/f.md" 'tags: [a, b]' && echo 0 || echo 1)"
check "body under front matter joined" \
  "$(has_line "$WORK/f.md" 'Body paragraph wrapped across two lines.' && echo 0 || echo 1)"

# 5. Block-quote and list-item continuations join with the prefix preserved.
cat >"$WORK/q.md" <<'EOF'
> A quoted paragraph that
> wraps onto a second line.

- A list item that
  continues indented.
EOF
reflow "$WORK/q.md"
check "blockquote joined, marker kept" \
  "$(has_line "$WORK/q.md" '> A quoted paragraph that wraps onto a second line.' && echo 0 || echo 1)"
check "list item joined, bullet kept" \
  "$(has_line "$WORK/q.md" '- A list item that continues indented.' && echo 0 || echo 1)"

# 6. Idempotent: a second pass is a no-op (--check clean).
"$PYTHON" "$REFLOW" --check "$WORK/q.md" >/dev/null 2>&1 && rc=0 || rc=$?
check "reflowed file is --check clean (idempotent)" "$rc"

# 7. --check flags a not-yet-reflowed file (exit 1).
printf 'Needs\nreflow.\n' >"$WORK/n.md"
"$PYTHON" "$REFLOW" --check "$WORK/n.md" >/dev/null 2>&1 && rc=0 || rc=$?
check "--check exits 1 on un-reflowed file" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# 8. A hard line break (<br>) is left intact, not collapsed to a space.
printf 'Line one with a break  \nline two here.\n' >"$WORK/b.md"
reflow "$WORK/b.md"
check "hard line break preserved (not joined)" \
  "$(has_line "$WORK/b.md" 'Line one with a break  ' && echo 0 || echo 1)"

# 9. A GitHub alert marker (`> [!NOTE]`) must never be joined into its body —
# that silently breaks the alert on GitHub, and the CommonMark render check
# cannot see the difference. The marker+body-in-one-paragraph form is the risk.
printf '> [!NOTE]\n> Pay close\n> attention here.\n' >"$WORK/a.md"
reflow "$WORK/a.md"
check "GitHub alert marker kept on its own line" \
  "$(has_line "$WORK/a.md" '> [!NOTE]' && echo 0 || echo 1)"
check "GitHub alert not collapsed (still 3 quoted lines)" \
  "$([ "$(grep -c '^>' "$WORK/a.md")" -eq 3 ] && echo 0 || echo 1)"

# 10. A GFM footnote definition is left intact — the CommonMark render check
# cannot model footnotes, so the marker line is guarded at the source.
printf 'Ref.[^1]\n\n[^1]: A footnote that\nwraps here.\n' >"$WORK/fn.md"
reflow "$WORK/fn.md"
check "footnote definition marker not joined" \
  "$(has_line "$WORK/fn.md" '[^1]: A footnote that' && echo 0 || echo 1)"

echo "md_reflow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
