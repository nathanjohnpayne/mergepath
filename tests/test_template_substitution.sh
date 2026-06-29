#!/usr/bin/env bash
# tests/test_template_substitution.sh
#
# Unit tests for scripts/lib/template-substitution.sh. Covers v1 syntax:
# variable substitution, conditional blocks across the four expression
# forms, comment-prefix flexibility, error paths (unclosed/nested/
# unexpected markers, malformed expressions), strict-mode fact-miss,
# atomic render_to.
#
# Bash 3.2 portable. Runs without network. Invoked by
# scripts/ci/check_template_substitution (which the lib's introduction
# PR also wires up).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/template-substitution.sh"

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/template-sub-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Reset all MERGEPATH_FACT_* env vars before each test so prior cases
# can't bleed in.
reset_facts() {
  local var
  for var in $(env | awk -F= '/^MERGEPATH_FACT_/ {print $1}'); do
    unset "$var"
  done
  unset MERGEPATH_TEMPLATE_STRICT
}

# Source the lib in a subshell so test failures don't poison later
# tests. Each render_case is its own subshell.
render_case() {
  # $1: template content (heredoc-friendly), $2..: KEY=VALUE env exports
  local template_content=$1
  shift
  local src="$WORKDIR/src.$$.tpl"
  local out="$WORKDIR/out.$$.txt"
  local err="$WORKDIR/err.$$.txt"
  printf '%s' "$template_content" > "$src"
  (
    reset_facts
    for kv in "$@"; do
      export "$kv"
    done
    # shellcheck disable=SC1090
    source "$LIB"
    local render_rc=0
    template_substitution::render "$src" > "$out" 2> "$err" || render_rc=$?
    echo "$render_rc" > "$WORKDIR/rc.$$.txt"
  )
  local rc
  rc=$(cat "$WORKDIR/rc.$$.txt")
  rm -f "$src" "$WORKDIR/rc.$$.txt"
  # Echo: <rc>\t<stdout-file>\t<stderr-file>
  printf '%s\t%s\t%s\n' "$rc" "$out" "$err"
}

# Helper: assert rendered output matches expected.
expect_output() {
  local label=$1 result=$2 expected=$3
  local rc out_file err_file
  rc=$(printf '%s' "$result" | cut -f1)
  out_file=$(printf '%s' "$result" | cut -f2)
  err_file=$(printf '%s' "$result" | cut -f3)
  if [ "$rc" != "0" ]; then
    fail "$label: expected rc=0, got rc=$rc; stderr:"
    sed 's/^/    /' "$err_file" >&2
    return
  fi
  local actual
  actual=$(cat "$out_file")
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label: output mismatch"
    echo "  expected:" >&2
    printf '%s\n' "$expected" | sed 's/^/    /' >&2
    echo "  actual:" >&2
    printf '%s\n' "$actual" | sed 's/^/    /' >&2
  fi
}

expect_rc() {
  local label=$1 result=$2 want_rc=$3
  local rc err_file
  rc=$(printf '%s' "$result" | cut -f1)
  err_file=$(printf '%s' "$result" | cut -f3)
  if [ "$rc" = "$want_rc" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label: expected rc=$want_rc, got rc=$rc; stderr:"
    sed 's/^/    /' "$err_file" >&2
  fi
}

# ---------------------------------------------------------------------------
# 1. Variable substitution
# ---------------------------------------------------------------------------

r=$(render_case "hello {{name}}!
" "MERGEPATH_FACT_NAME=world")
expect_output "1a {{key}} basic substitution" "$r" "hello world!"

r=$(render_case "{{a}}-{{b}}-{{a}}
" "MERGEPATH_FACT_A=foo" "MERGEPATH_FACT_B=bar")
expect_output "1b multiple substitutions per line, repeats" "$r" "foo-bar-foo"

r=$(render_case "plain line, no markers
")
expect_output "1c no markers passes through" "$r" "plain line, no markers"

r=$(render_case "missing: <{{nope}}>
")
expect_output "1d lenient mode: missing fact = empty" "$r" "missing: <>"

r=$(render_case "missing: <{{nope}}>
" "MERGEPATH_TEMPLATE_STRICT=1")
expect_rc "1e strict mode: missing fact = rc 3" "$r" 3

# 1e2: regression guard for sentinel collision (Codex P3 round 2 on PR #313).
# A fact legitimately set to the OLD sentinel string must NOT be
# misclassified as unset. With the +x detection this is just an
# ordinary set-to-value case.
r=$(render_case "value: <{{collides}}>
" "MERGEPATH_FACT_COLLIDES=__MERGEPATH_FACT_UNSET__")
expect_output "1e2 sentinel-collision regression: literal sentinel as value treated as set" "$r" "value: <__MERGEPATH_FACT_UNSET__>"

# 1e3: fact set to empty string is treated as SET (distinct from unset).
# Lenient mode: empty value → empty substitution (same as before).
# Strict mode: empty value → NOT a strict-mode failure (the var IS set).
# This is the new behavior under +x detection; previously a value of
# "" round-tripped through the sentinel test as "set", but the
# documentation of strict-mode said only an "unknown fact" (set/unset
# distinction) triggers rc 3.
r=$(render_case "empty: <{{empty_fact}}>
" "MERGEPATH_FACT_EMPTY_FACT=" "MERGEPATH_TEMPLATE_STRICT=1")
expect_output "1e3 strict mode: empty-string fact is set (not a strict failure)" "$r" "empty: <>"

r=$(render_case "unclosed: {{key
")
expect_output "1f unclosed {{ left verbatim" "$r" "unclosed: {{key"

r=$(render_case "hyphen key: {{node-version}}
" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "1g hyphenated fact key → underscored env var" "$r" "hyphen key: 20"

# 1h: injection attempt — key contains shell metacharacters. Without
# input validation in _fact_value (CodeRabbit Critical on PR #313),
# this key would be interpreted at eval time as a command
# substitution. With validation, the renderer rejects with rc 2.
r=$(render_case "compromised: {{foo\$(id)}}
")
expect_rc "1h injection attempt key -> rc 1 (rejected as malformed template)" "$r" 1

# 1i: another injection vector — backticks.
r=$(render_case "compromised: {{foo\`id\`}}
")
expect_rc "1i backtick key -> rc 1 (rejected as malformed template)" "$r" 1

# 1j: uppercase keys rejected (reserved for env-var form).
r=$(render_case "{{FOO}}
" "MERGEPATH_FACT_FOO=bar")
expect_rc "1j uppercase key -> rc 1 (rejected as malformed template)" "$r" 1

# 1k: underscored keys allowed (natural shell var style).
r=$(render_case "ts: {{has_ts}}
" "MERGEPATH_FACT_HAS_TS=yes")
expect_output "1k underscored key allowed" "$r" "ts: yes"

# ---------------------------------------------------------------------------
# 2. Bare conditional: >>> if <key>
# ---------------------------------------------------------------------------

r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
" "MERGEPATH_FACT_HAS_TS=1")
expect_output "2a bare conditional, truthy fact" "$r" "before
typescript line
after"

r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
")
expect_output "2b bare conditional, unset fact (lenient)" "$r" "before
after"

r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
" "MERGEPATH_FACT_HAS_TS=")
expect_output "2c bare conditional, empty fact = falsy" "$r" "before
after"

# ---------------------------------------------------------------------------
# 3. Negation: >>> if !<key>
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if !has_ts
no typescript
// <<<
")
expect_output "3a negation, unset fact = true" "$r" "no typescript"

r=$(render_case "// >>> if !has_ts
no typescript
// <<<
" "MERGEPATH_FACT_HAS_TS=1")
expect_output "3b negation, set fact = false" "$r" ""

# ---------------------------------------------------------------------------
# 4. List membership: >>> if <key> contains <value>
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if frameworks contains react
react block
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react typescript")
expect_output "4a contains, present" "$r" "react block"

r=$(render_case "// >>> if frameworks contains vue
vue block
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react typescript")
expect_output "4b contains, absent" "$r" ""

# Word-boundary safety: "react" must NOT match "react-native".
r=$(render_case "// >>> if frameworks contains react
matched react
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react-native")
expect_output "4c contains, word-boundary (react ≠ react-native)" "$r" ""

r=$(render_case "// >>> if frameworks contains react-native
matched native
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react-native react")
expect_output "4d contains, hyphenated value matches" "$r" "matched native"

# ---------------------------------------------------------------------------
# 5. Equality / inequality
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if node_version == 20
node 20
// <<<
" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "5a equality, match" "$r" "node 20"

r=$(render_case "// >>> if node_version == 20
node 20
// <<<
" "MERGEPATH_FACT_NODE_VERSION=18")
expect_output "5b equality, no match" "$r" ""

r=$(render_case "// >>> if node_version != 18
modern node
// <<<
" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "5c inequality, match" "$r" "modern node"

r=$(render_case "// >>> if node_version != 18
modern node
// <<<
" "MERGEPATH_FACT_NODE_VERSION=18")
expect_output "5d inequality, no match" "$r" ""

# ---------------------------------------------------------------------------
# 6. Comment-prefix flexibility (each comment style must be recognized)
# ---------------------------------------------------------------------------

for prefix_label_pair in \
    "// js-line" \
    "# shell-yaml" \
    "-- sql-lua" \
    "<!-- html-open"; do
  prefix=${prefix_label_pair% *}
  label=${prefix_label_pair#* }
  # html close needs trailing -->; handle separately for marker close
  if [ "$label" = "html-open" ]; then
    template=$(printf '%s >>> if frameworks contains react\nreact-only\n%s <<< -->\n' "$prefix" "$prefix")
  else
    template=$(printf '%s >>> if frameworks contains react\nreact-only\n%s <<<\n' "$prefix" "$prefix")
  fi
  r=$(render_case "$template" "MERGEPATH_FACT_FRAMEWORKS=react")
  expect_output "6 prefix '$prefix' ($label) — block kept" "$r" "react-only"
done

# Mixed leading whitespace on marker.
r=$(render_case "    // >>> if frameworks contains react
react-only
  // <<<
" "MERGEPATH_FACT_FRAMEWORKS=react")
expect_output "6e leading whitespace on markers" "$r" "react-only"

# ---------------------------------------------------------------------------
# 7. Variable substitution INSIDE a kept block (and skipped block)
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if has_ts
ts version {{node_version}}
// <<<
" "MERGEPATH_FACT_HAS_TS=1" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "7a {{vars}} substituted inside kept block" "$r" "ts version 20"

r=$(render_case "// >>> if has_ts
ts version {{node_version}}
// <<<
")
expect_output "7b {{vars}} inside skipped block are not substituted" "$r" ""

# ---------------------------------------------------------------------------
# 8. Malformed templates → rc 1
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if has_ts
unclosed body
")
expect_rc "8a unclosed if marker -> rc 1" "$r" 1

r=$(render_case "before
// <<<
after
")
expect_rc "8b unexpected close marker -> rc 1" "$r" 1

r=$(render_case "// >>> if outer
outer body
// >>> if inner
nested body
// <<<
// <<<
")
expect_rc "8c nested if -> rc 1 (v1 doesnt support nesting)" "$r" 1

r=$(render_case "// >>> if foo bar baz quux
body
// <<<
")
expect_rc "8d unknown expression form → rc 1" "$r" 1

# ---------------------------------------------------------------------------
# 9. eval_expr direct (drives the expression evaluator in isolation)
# ---------------------------------------------------------------------------

(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS="react typescript"
  export MERGEPATH_FACT_HAS_TS=1
  # shellcheck disable=SC1090
  source "$LIB"
  set +e
  template_substitution::eval_expr "has_ts"; r1=$?
  template_substitution::eval_expr "!has_ts"; r2=$?
  template_substitution::eval_expr "frameworks contains react"; r3=$?
  template_substitution::eval_expr "frameworks contains vue"; r4=$?
  template_substitution::eval_expr "node_version == 20"; r5=$?
  template_substitution::eval_expr ""; r6=$?
  set -e
  if [ "$r1" = "0" ] && [ "$r2" = "1" ] && [ "$r3" = "0" ] && \
     [ "$r4" = "1" ] && [ "$r5" = "1" ] && [ "$r6" = "2" ]; then
    echo "PASS: 9 eval_expr direct (truthy/falsy/match/miss/empty)"
  else
    echo "FAIL: 9 eval_expr direct: got $r1/$r2/$r3/$r4/$r5/$r6 (expected 0/1/0/1/1/2)" >&2
    exit 1
  fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ---------------------------------------------------------------------------
# 10. render_to atomic write
# ---------------------------------------------------------------------------

src="$WORKDIR/atomic-src.tpl"
dest="$WORKDIR/atomic-dest.txt"
cat > "$src" <<'EOF'
rendered: {{key}}
EOF
(
  reset_facts
  export MERGEPATH_FACT_KEY=value
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render_to "$src" "$dest"
)
if [ -f "$dest" ] && [ "$(cat "$dest")" = "rendered: value" ]; then
  pass "10a render_to writes destination file"
else
  fail "10a render_to: expected 'rendered: value', got: $(cat "$dest" 2>/dev/null || echo MISSING)"
fi

# 10c: render_to preserves existing dest mode (Codex P2 round 2 on PR #313).
# Pre-create dest with mode 0644 and verify mv doesn't strip to 0600.
src="$WORKDIR/mode-src.tpl"
dest="$WORKDIR/mode-dest.txt"
echo "original content" > "$dest"
chmod 644 "$dest"
echo "new: {{key}}" > "$src"
(
  reset_facts
  export MERGEPATH_FACT_KEY=after
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render_to "$src" "$dest"
)
# Read mode in a portable way (same order as the lib — GNU first, BSD
# fallback; the inverse order breaks on Linux because GNU `stat -f`
# means filesystem status, not format, and writes garbage to stdout
# before failing).
actual_mode=$(stat -c '%a' "$dest" 2>/dev/null \
              || stat -f '%Mp%Lp' "$dest" 2>/dev/null \
              || echo "??")
# BSD stat returns "0644", GNU returns "644". Accept both.
case "$actual_mode" in
  0644|644)
    if [ "$(cat "$dest")" = "new: after" ]; then
      pass "10c render_to preserves existing dest mode (0644, not 0600)"
    else
      fail "10c render_to: content wrong after mode-preservation render: $(cat "$dest")"
    fi
    ;;
  *)
    fail "10c render_to: expected mode 0644/644, got '$actual_mode'"
    ;;
esac

# 10d: render_to writing a new file (no pre-existing dest) — verify
# render still succeeds (mode preservation skips the chmod, but the
# write must work).
src="$WORKDIR/newfile-src.tpl"
dest="$WORKDIR/newfile-dest.txt"
echo "fresh: {{key}}" > "$src"
[ -e "$dest" ] && rm "$dest"
(
  reset_facts
  export MERGEPATH_FACT_KEY=new
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render_to "$src" "$dest"
)
if [ -f "$dest" ] && [ "$(cat "$dest")" = "fresh: new" ]; then
  pass "10d render_to writes new file (no pre-existing dest)"
else
  fail "10d render_to: expected fresh write, got: $(cat "$dest" 2>/dev/null || echo MISSING)"
fi

# render_to failure: malformed template → no partial write of dest.
src="$WORKDIR/atomic-bad.tpl"
dest="$WORKDIR/atomic-bad-dest.txt"
echo "// >>> if has_ts" > "$src"
echo "body" >> "$src"
# (no <<<)
(
  reset_facts
  # shellcheck disable=SC1090
  source "$LIB"
  exit_rc=0
  template_substitution::render_to "$src" "$dest" || exit_rc=$?
  echo "$exit_rc" > "$WORKDIR/atomic-rc.txt"
)
exit_rc=$(cat "$WORKDIR/atomic-rc.txt")
if [ "$exit_rc" = "1" ] && [ ! -f "$dest" ]; then
  pass "10b render_to atomic: malformed template leaves no partial dest"
else
  fail "10b render_to: expected rc=1 + no dest, got rc=$exit_rc, dest exists: $([ -f "$dest" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# 11. End-to-end: ESLint-config-shaped template (the forcing function)
# ---------------------------------------------------------------------------

src="$WORKDIR/eslint.config.js.tpl"
cat > "$src" <<'EOF'
import js from "@eslint/js";
import globals from "globals";

// >>> if frameworks contains typescript
import tseslint from "typescript-eslint";
// <<<
// >>> if frameworks contains astro
import astro from "eslint-plugin-astro";
// <<<
// >>> if frameworks contains react
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
// <<<

export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
// >>> if frameworks contains typescript
  ...tseslint.configs.recommended,
// <<<
// >>> if frameworks contains astro
  ...astro.configs.recommended,
// <<<
// >>> if frameworks contains react
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: { react, "react-hooks": reactHooks },
    rules: {
      ...react.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
    },
  },
// <<<
];
EOF

# Case 11a: swipewatch profile (JS-only, no frameworks)
expected_swipewatch='import js from "@eslint/js";
import globals from "globals";


export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
];'
(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS=""
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render "$src" > "$WORKDIR/swipewatch.out"
)
if [ "$(cat "$WORKDIR/swipewatch.out")" = "$expected_swipewatch" ]; then
  pass "11a ESLint template, swipewatch profile (JS-only)"
else
  fail "11a swipewatch profile mismatch:"
  diff <(printf '%s\n' "$expected_swipewatch") "$WORKDIR/swipewatch.out" | sed 's/^/    /' >&2
fi

# Case 11b: matchline profile (TS + React)
expected_matchline='import js from "@eslint/js";
import globals from "globals";

import tseslint from "typescript-eslint";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";

export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: { react, "react-hooks": reactHooks },
    rules: {
      ...react.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
    },
  },
];'
(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS="react typescript"
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render "$src" > "$WORKDIR/matchline.out"
)
if [ "$(cat "$WORKDIR/matchline.out")" = "$expected_matchline" ]; then
  pass "11b ESLint template, matchline profile (TS+React)"
else
  fail "11b matchline profile mismatch:"
  diff <(printf '%s\n' "$expected_matchline") "$WORKDIR/matchline.out" | sed 's/^/    /' >&2
fi

# Case 11c: nathanpaynedotcom profile (TS + Astro)
expected_npc='import js from "@eslint/js";
import globals from "globals";

import tseslint from "typescript-eslint";
import astro from "eslint-plugin-astro";

export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...astro.configs.recommended,
];'
(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS="astro typescript"
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render "$src" > "$WORKDIR/npc.out"
)
if [ "$(cat "$WORKDIR/npc.out")" = "$expected_npc" ]; then
  pass "11c ESLint template, nathanpaynedotcom profile (TS+Astro)"
else
  fail "11c nathanpaynedotcom profile mismatch:"
  diff <(printf '%s\n' "$expected_npc") "$WORKDIR/npc.out" | sed 's/^/    /' >&2
fi

# ---------------------------------------------------------------------------
# 12. Fact-driven defaults added in mergepath#322 — testing globals,
#     jsx_in_js React glob extension, react_compiler advisory disables.
#
# These mirror the per-fact toggles that the ESLint template (post-#322)
# uses. Each case exercises one fact in isolation against a minimal
# template snippet so a regression in the lib's evaluator is caught
# by a tightly-scoped failure rather than a full-template byte diff.
# ---------------------------------------------------------------------------

# 12a: testing == vitest renders vitest block, jest block does not.
r=$(render_case "// >>> if testing contains vitest
vitest globals
// <<<
// >>> if testing contains jest
jest globals
// <<<
" "MERGEPATH_FACT_TESTING=vitest")
expect_output "12a testing=vitest renders only vitest block" "$r" "vitest globals"

# 12b: testing == jest renders jest block, vitest block does not.
r=$(render_case "// >>> if testing contains vitest
vitest globals
// <<<
// >>> if testing contains jest
jest globals
// <<<
" "MERGEPATH_FACT_TESTING=jest")
expect_output "12b testing=jest renders only jest block" "$r" "jest globals"

# 12c: testing unset → neither block renders.
r=$(render_case "// >>> if testing contains vitest
vitest globals
// <<<
// >>> if testing contains jest
jest globals
// <<<
")
expect_output "12c testing unset → no testing block" "$r" ""

# 12d: jsx_in_js: true (truthy) → js-included files glob renders.
r=$(render_case "// >>> if jsx_in_js
files: js+jsx+tsx
// <<<
" "MERGEPATH_FACT_JSX_IN_JS=true")
expect_output "12d jsx_in_js=true → jsx-in-js block renders" "$r" "files: js+jsx+tsx"

# 12e: jsx_in_js unset → block does NOT render (default behavior).
r=$(render_case "// >>> if jsx_in_js
files: js+jsx+tsx
// <<<
")
expect_output "12e jsx_in_js unset → jsx-in-js block omitted" "$r" ""

# 12f: React Compiler disable block gated on `frameworks contains
# react` ONLY (codex P1 #327 round 2). For non-React consumers, the
# block must NOT render — otherwise it'd inject react-hooks/* rule
# IDs whose plugin isn't loaded, breaking ESLint config load with
# "Definition for rule X was not found".
r=$(render_case "// >>> if frameworks contains react
react-hooks/set-state-in-effect: off
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react")
expect_output "12f React Compiler block renders for React consumers" "$r" "react-hooks/set-state-in-effect: off"

# 12g: For non-React consumers, the React Compiler disable block must
# NOT render. Codex P1 round 2 caught this concretely on JS/TS-only
# consumers — the rendered config previously emitted react-hooks/*
# rules even when the plugin wasn't loaded.
r=$(render_case "// >>> if frameworks contains react
react-hooks/set-state-in-effect: off
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=typescript")
expect_output "12g React Compiler block omitted for non-React consumers" "$r" ""

# 12h: facts.react_compiler is reserved for v2 (when the template lib
# adds compound expressions or nested conditionals). It currently has
# no effect on rendering — regression guard for accidental re-use of
# the fact in template logic.
r=$(render_case "// >>> if frameworks contains react
react-hooks/set-state-in-effect: off
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react" "MERGEPATH_FACT_REACT_COMPILER=true")
expect_output "12h react_compiler=true does NOT suppress disable block (v1 limitation)" "$r" "react-hooks/set-state-in-effect: off"

# ---------------------------------------------------------------------------
# 13. ESM/CJS template parity: render the real examples/eslint.config.{js,
#     cjs.js} files against every meaningful facts combination. The render
#     itself must succeed (parse-level marker balance is the load-bearing
#     check) AND the ESM and CJS rendered bodies must match modulo the
#     import/export shape. Without these guards, an edit that drifts the
#     CJS template's `>>> if` / `<<<` structure away from the ESM (e.g.
#     deletes the opener but leaves an orphan closer — observed during
#     the #327 round-3 cleanup, caught only when sync-to-downstream.sh
#     --sync-all hit ffb/swipewatch in prod) passes the existing fixture-
#     based tests but breaks every templated propagation.
# ---------------------------------------------------------------------------
TEMPLATE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESM_TEMPLATE="$TEMPLATE_REPO_ROOT/examples/eslint.config.js"
CJS_TEMPLATE="$TEMPLATE_REPO_ROOT/examples/eslint.config.cjs.js"

# Quick parse-level guard: marker counts must match within each file AND
# between the two files. This is the cheapest check that catches the
# orphan-`<<<` bug class without needing a renderer.
ESM_OPEN=$(grep -cE '^// >>> if' "$ESM_TEMPLATE")
ESM_CLOSE=$(grep -cE '^// <<<' "$ESM_TEMPLATE")
CJS_OPEN=$(grep -cE '^// >>> if' "$CJS_TEMPLATE")
CJS_CLOSE=$(grep -cE '^// <<<' "$CJS_TEMPLATE")
if [ "$ESM_OPEN" -ne "$ESM_CLOSE" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL: 13a ESM template has $ESM_OPEN open markers vs $ESM_CLOSE close markers" >&2
elif [ "$CJS_OPEN" -ne "$CJS_CLOSE" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL: 13a CJS template has $CJS_OPEN open markers vs $CJS_CLOSE close markers" >&2
elif [ "$ESM_OPEN" -ne "$CJS_OPEN" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL: 13a ESM/CJS templates drifted (ESM: $ESM_OPEN markers, CJS: $CJS_OPEN markers)" >&2
else
  echo "PASS: 13a ESM/CJS template markers balanced + matched ($ESM_OPEN open + $ESM_OPEN close in each)"
  PASS=$((PASS + 1))
fi

# Render-level guard: run template_substitution::render on each template
# under every load-bearing facts combination from the manifest. Render
# success (rc=0) is the actual proof that the markers parse cleanly. We
# don't byte-compare ESM vs CJS bodies here — the import/export shape
# differs by design — but a render failure on either file is a regression
# that would have caught the orphan-`<<<` bug.
RENDER_CASES=(
  "react"                    # ffb / dpr / matchline / swipewatch family
  "react typescript"         # matchline
  "typescript"               # nathanpaynedotcom (Astro+TS subset)
  "astro typescript"         # nathanpaynedotcom full
  ""                         # swipewatch + overridebroadway (no frameworks)
)
RENDER_FAIL=0
for facts in "${RENDER_CASES[@]}"; do
  for tpl in "$ESM_TEMPLATE" "$CJS_TEMPLATE"; do
    (
      reset_facts
      export MERGEPATH_FACT_FRAMEWORKS="$facts"
      # shellcheck disable=SC1090
      source "$LIB"
      template_substitution::render "$tpl" >/dev/null 2>&1
    ) || {
      RENDER_FAIL=1
      echo "FAIL: 13b render failed for $(basename "$tpl") with frameworks='$facts'" >&2
    }
  done
done
if [ "$RENDER_FAIL" -eq 0 ]; then
  echo "PASS: 13b ESM + CJS templates render cleanly under all ${#RENDER_CASES[@]} fact combos"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Case 14: the TS unused-vars tuning block extends to `.astro`, and
# stays co-gated with the `typescript` fact. Renders the REAL templates.
#   14a — an astro+ts consumer's render carries `.astro` in the glob so
#         the `^_` convention reaches astro frontmatter.
#   14b — a consumer WITHOUT the typescript fact never renders the
#         `@typescript-eslint/*` rule IDs (they would reference a plugin
#         that is only imported under the typescript fact — the #327
#         rule-without-plugin break). This is what makes the `.astro`
#         extension safe to live in the typescript-gated block rather
#         than a separate astro-gated one.
# ---------------------------------------------------------------------------
ASTRO_TS_GLOB='files: ["**/*.{ts,tsx,astro}"]'
TS_UNUSED_RULE='@typescript-eslint/no-unused-vars'
for tpl in "$ESM_TEMPLATE" "$CJS_TEMPLATE"; do
  b=$(basename "$tpl")
  out_astro=$(reset_facts; export MERGEPATH_FACT_FRAMEWORKS="astro typescript"; source "$LIB"; template_substitution::render "$tpl")
  if printf '%s' "$out_astro" | grep -qF "$ASTRO_TS_GLOB"; then
    echo "PASS: 14a $b astro+ts render carries the .astro TS unused-vars glob"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 14a $b astro+ts render missing $ASTRO_TS_GLOB" >&2
    FAIL=$((FAIL + 1))
  fi
  out_react=$(reset_facts; export MERGEPATH_FACT_FRAMEWORKS="react"; source "$LIB"; template_substitution::render "$tpl")
  if printf '%s' "$out_react" | grep -qF "$TS_UNUSED_RULE"; then
    echo "FAIL: 14b $b react-only render leaks $TS_UNUSED_RULE without the typescript fact" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: 14b $b react-only render omits @typescript-eslint rule IDs (co-gated with the plugin)"
    PASS=$((PASS + 1))
  fi
done

# ---------------------------------------------------------------------------
# 15. Strict-mode conditional existence-check regression (#555)
#     >>> if key and >>> if !key on an UNSET fact must NOT hard-fail under
#     MERGEPATH_TEMPLATE_STRICT=1. The documented contract scopes strict mode
#     to a *substitution* of an unset fact, not a set-ness test.
# ---------------------------------------------------------------------------

# 15a: strict mode + bare-key conditional on unset fact → skips block (lenient)
r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
" "MERGEPATH_TEMPLATE_STRICT=1")
expect_output "15a strict mode: bare-key conditional on unset fact skips block (no rc 3)" "$r" "before
after"

# 15b: strict mode + !key conditional on unset fact → includes block (lenient)
r=$(render_case "before
// >>> if !has_ts
no typescript
// <<<
after
" "MERGEPATH_TEMPLATE_STRICT=1")
expect_output "15b strict mode: !key conditional on unset fact includes block (no rc 3)" "$r" "before
no typescript
after"

# 15c: strict mode + bare-key on a SET fact still renders the block.
r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
" "MERGEPATH_TEMPLATE_STRICT=1" "MERGEPATH_FACT_HAS_TS=1")
expect_output "15c strict mode: bare-key conditional on set fact includes block" "$r" "before
typescript line
after"

# 15d: strict mode + substitution of an unset fact still hard-fails (rc 3).
r=$(render_case "value: {{missing_key}}
" "MERGEPATH_TEMPLATE_STRICT=1")
expect_rc "15d strict mode: {{substitution}} of unset fact still hard-fails (rc 3)" "$r" 3

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "PASS: $PASS   FAIL: $FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ]
