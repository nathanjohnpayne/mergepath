#!/usr/bin/env bash
# Regression coverage for scripts/workflow/match_protected_paths.sh (#471):
# repo-relative path glob semantics where * and ? are segment-local (do not
# cross /) and ** is cross-directory. Keep these cases in parity with the
# Mergepath Playground's compileGlob (mergepath/playground/index.html).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/scripts/workflow/match_protected_paths.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# assert_match <label> <expected: yes|no> <file> <pattern...>
assert_match() {
  local label=$1 expect=$2 file=$3; shift 3
  local out got
  # No `|| true`: the matcher exits 0 on both match and no-match (its
  # while-read loop returns 0 at EOF), so a non-zero exit means the matcher
  # actually crashed — let that abort the suite loudly instead of silently
  # passing the assertion (CodeRabbit on PR #475).
  out=$(printf '%s\n' "$file" | bash "$M" "$@" 2>/dev/null)
  if [ "$out" = "$file" ]; then got=yes; else got=no; fi
  if [ "$got" = "$expect" ]; then pass "$label"; else fail "$label: $file vs [$*] -> $got, expected $expect"; fi
}

# The core bug: * is segment-local (does NOT cross /).
assert_match "src/*.js matches a file in src/"            yes 'src/foo.js'         'src/*.js'
assert_match "src/*.js does NOT match a nested file"      no  'src/nested/file.js' 'src/*.js'

# ** is cross-directory.
assert_match ".github/** matches a nested workflow"       yes '.github/workflows/foo.yml' '.github/**'
assert_match ".github/** matches a deeply nested path"    yes '.github/a/b/c.yml'         '.github/**'
assert_match "src/**/*.js matches deep nesting"           yes 'src/a/b/file.js'           'src/**/*.js'

# Top-level * does not cross / either.
assert_match "*.md matches a top-level file"              yes 'README.md'         '*.md'
assert_match "*.md does NOT match a nested file"          no  'docs/README.md'    '*.md'

# ? is segment-local (single non-/ char).
assert_match "?oo.txt matches foo.txt"                    yes 'foo.txt'           '?oo.txt'
assert_match "?oo.txt does NOT match foobar.txt"          no  'foobar.txt'        '?oo.txt'
assert_match "a/?.txt does NOT cross / via ?"             no  'a/b/c.txt'         'a/?.txt'

# Regex metacharacters in patterns are literal, not regex.
assert_match "a.b matches literal a.b"                    yes 'a.b'               'a.b'
assert_match "a.b does NOT match axb (dot is literal)"    no  'axb'               'a.b'
assert_match "paren pattern is literal"                   yes 'f(x).js'          'f(x).js'

# Multiple patterns: match if ANY matches.
assert_match "multi-pattern: second matches"              yes 'src/auth/x.ts'     '.github/**' 'src/auth/**'
assert_match "multi-pattern: none matches"                no  'lib/x.ts'          '.github/**' 'src/auth/**'

echo ""
echo "test_match_protected_paths: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
