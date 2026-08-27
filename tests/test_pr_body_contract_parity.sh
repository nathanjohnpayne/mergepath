#!/usr/bin/env bash
# tests/test_pr_body_contract_parity.sh — every identity-bearing consumer must
# read `Authoring-Agent:` through the SAME parser (#1121).
#
# The defect this guards against is not a parse bug in any one consumer; each
# local regex was individually reasonable. It is DIVERGENCE: gh-pr-guard.sh
# ignored a marker inside an HTML comment while agent-review.yml,
# codex-review-check.sh and phase-4b-review.sh each took the first RAW line. On
# a body carrying a commented-out marker before a visible one they disagree, so
# the same PR can be assigned to one reviewer, attributed to another by the
# guard, and evaluated by merge-clearance as if the same-agent Codex-reaction
# fallback were eligible. Parity is the property under test.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1" >&2; }

TMP_DETECTOR="$(mktemp "${TMPDIR:-/tmp}/parity-detector.XXXXXX")"
trap 'rm -f "$TMP_DETECTOR"' EXIT

. "$ROOT/scripts/lib/pr-body-contract.sh"

# --- 1. every consumer routes through the shared parser ----------------------
# Named explicitly rather than globbed: a new identity consumer should have to
# be added here deliberately, which is the moment to ask whether it parses.
for f in scripts/codex-review-check.sh scripts/phase-4b-review.sh; do
  if grep -q 'pr-body-contract.sh' "$f"; then
    ok "$f sources the shared parser"
  else
    bad "$f does not source scripts/lib/pr-body-contract.sh"
  fi
done

if grep -q 'pr-body-contract.mjs' .github/workflows/agent-review.yml; then
  ok "agent-review.yml invokes the shared parser"
else
  bad "agent-review.yml does not invoke scripts/lib/pr-body-contract.mjs"
fi

# --- 2. no consumer keeps a raw first-line regex ------------------------------
# The literal shapes that caused the divergence. A consumer may still MENTION
# the header in prose, in a `#`/`//` comment, or in a diagnostic string; what it
# may not do is EXTRACT from it. The comment exclusion is deliberately narrow --
# leading-`#` or leading-`//` only -- so a matcher cannot hide behind a trailing
# comment on a live line.
while IFS= read -r hit; do
  f="${hit%%:*}"
  bad "$f still extracts Authoring-Agent with a local matcher: ${hit#*:}"
done < <(grep -nE "(grep|sed|awk|match)[^|]*Authoring-Agent:" \
           scripts/codex-review-check.sh scripts/phase-4b-review.sh \
           .github/workflows/agent-review.yml 2>/dev/null \
         | grep -vE "^[^:]*:[0-9]+:[[:space:]]*(#|//)" \
         | grep -viE "echo|printf|fail_gate|console\.log")
[ "$fail" -eq 0 ] && ok "no consumer extracts Authoring-Agent with a local matcher"

# --- 3. the parser's answers on the divergence-producing bodies ---------------
VISIBLE_AFTER_COMMENT=$'<!--\nAuthoring-Agent: codex\n-->\n\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$VISIBLE_AFTER_COMMENT")"
got_agent="$(pr_body_authoring_agent "$VISIBLE_AFTER_COMMENT")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ]; then
  ok "commented marker before a visible one resolves to the VISIBLE agent (claude), count=1"
else
  bad "commented-then-visible body: expected count=1 agent=claude, got count=$got_count agent=$got_agent"
fi

ONLY_COMMENTED=$'<!-- Authoring-Agent: claude -->\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$ONLY_COMMENTED")"
if [ "$got_count" = "0" ]; then
  ok "a marker that exists ONLY inside a comment is not a declaration (count=0)"
else
  bad "comment-only body: expected count=0, got $got_count"
fi

TWO_VISIBLE=$'Authoring-Agent: claude\nAuthoring-Agent: codex\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$TWO_VISIBLE")"
if [ "$got_count" -gt 1 ]; then
  ok "duplicate visible markers do not silently resolve to the first (count=$got_count)"
else
  bad "duplicate markers: expected >1, got $got_count"
fi

# --- 4. the guard/wrapper delegation must agree on WHICH commands it covers ---
# gh-pr-guard exits 0 for an author-wrapped create on the promise that the
# wrapper validates the body. That promise is only kept if BOTH sides recognise
# the same command shapes. The guard canonicalises path-qualified executables
# and the `new` alias; a wrapper matching only the literal token `gh` would take
# its generic path and skip validation AND the post-create author readback,
# while the guard believed it had delegated. Reproduced as hook rc 0 for
# `gh-as-author.sh -- /opt/homebrew/bin/gh pr create --body INVALID`.
sed -n '/^is_pr_create_command()/,/^}/p' "$ROOT/scripts/gh-as-author.sh" > "$TMP_DETECTOR"
# shellcheck source=/dev/null
. "$TMP_DETECTOR"

check_shape() {
  local expect="$1"; shift
  local desc="$1"; shift
  if is_pr_create_command "$@"; then got=create; else got=other; fi
  if [ "$got" = "$expect" ]; then ok "wrapper: $desc -> $expect"; else bad "wrapper: $desc -> $got, expected $expect"; fi
}

check_shape create "bare gh create"              gh pr create --title x
check_shape create "path-qualified gh create"    /opt/homebrew/bin/gh pr create --title x
check_shape create "relative-path gh new"        ./gh pr new --title x
check_shape create "global flag before pr"       gh --repo o/r pr new --title x
check_shape other  "path-qualified gh merge"     /usr/bin/gh pr merge 1
check_shape other  "gh edit"                     gh pr edit 1
# `notgh` must NOT match: the basename rule is */gh or gh exactly, not a suffix.
check_shape other  "executable merely ending in gh" notgh pr create --title x

# --- 5. a parser that cannot run must FAIL CLOSED, not read as "no marker" ----
# An empty authoring agent does not mean "no same-agent risk": downstream it
# DISABLES the authoring-agent exclusion, so a broken parser would permit the
# same-agent APPROVED that gate (b) exists to refuse. codex-review-check.sh must
# therefore treat parser trouble as a gate error rather than an answer.
if grep -q "refusing to evaluate gate (b)" "$ROOT/scripts/codex-review-check.sh"; then
  ok "codex-review-check refuses to evaluate gate (b) on parser trouble"
else
  bad "codex-review-check has no fail-closed guard around the shared parser"
fi

# And prove the helper really does signal failure when the .mjs is missing --
# the guard clause above is only load-bearing if this returns non-zero.
BROKEN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parity-broken.XXXXXX")"
mkdir -p "$BROKEN_DIR/lib"
cp "$ROOT/scripts/lib/pr-body-contract.sh" "$BROKEN_DIR/lib/"
# .mjs deliberately NOT copied
if ( . "$BROKEN_DIR/lib/pr-body-contract.sh" >/dev/null 2>&1
     pr_body_authoring_agent_count "Authoring-Agent: claude" >/dev/null 2>&1 ); then
  bad "parser helper returned SUCCESS with the .mjs absent (fail-open)"
else
  ok "parser helper signals failure when the .mjs is absent (so the guard can fire)"
fi
rm -rf "$BROKEN_DIR"

echo
echo "test_pr_body_contract_parity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
