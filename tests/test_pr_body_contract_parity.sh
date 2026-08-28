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
. "$ROOT/scripts/lib/gh-command-classifier.sh"

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

if grep -q 'pr-body-contract.mjs' .github/workflows/pr-audit.yml; then
  ok "pr-audit.yml invokes the shared parser"
else
  bad "pr-audit.yml does not invoke scripts/lib/pr-body-contract.mjs"
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
           .github/workflows/agent-review.yml .github/workflows/pr-audit.yml 2>/dev/null \
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

JSON_BODY=$'Authoring-Agent: CLAUDE\n\n## Self-Review\nok'
json_contract="$(printf '%s\n' "$JSON_BODY" | node "$ROOT/scripts/lib/pr-body-contract.mjs" --json)"
if [ "$json_contract" = '{"author":"claude","authorCount":1,"hasSelfReview":true}' ]; then
  ok "the parser exposes one JSON snapshot for non-shell consumers"
else
  bad "parser JSON snapshot mismatch: $json_contract"
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

# --- 6. an autolink is inline content, not a raw HTML block ------------------
# `<https://example.com>` begins with a letter inside angle brackets, so a
# generic tag matcher classified it as a raw HTML block and discarded every
# following line until a blank one -- hiding the very markers this parser
# exists to find, so a valid body was rejected as having no author.
AUTOLINK_BODY=$'<https://example.com>\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$AUTOLINK_BODY")"
got_agent="$(pr_body_authoring_agent "$AUTOLINK_BODY")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ]; then
  ok "an autolink before a marker does not suppress it (count=1, agent=claude)"
else
  bad "autolink body: expected count=1 agent=claude, got count=$got_count agent=$got_agent"
fi

# The narrowing must NOT cost the real behaviour: a genuine HTML comment still
# suppresses, which is the property finding #1121 originally turned on.
REAL_HTML=$'<!-- Authoring-Agent: codex -->\n\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_agent="$(pr_body_authoring_agent "$REAL_HTML")"
if [ "$got_agent" = "claude" ]; then
  ok "a real HTML comment still suppresses its marker after the narrowing"
else
  bad "real HTML comment: expected agent=claude, got $got_agent"
fi

# --- 7. reviewer entries with YAML padding after the closing quote -----------
# `- "nathanpayne-codex"   ` is a supported form. Stripping the closing quote
# before trimming the padding left the value malformed and dropped the
# reviewer, so the merge gate accepted an agent that gh-as-author.sh then
# called unknown -- two parsers disagreeing, the same shape as the rest.
PADDED_POLICY="$(mktemp "${TMPDIR:-/tmp}/parity-policy.XXXXXX")"
printf 'available_reviewers:\n  - "nathanpayne-codex"   \n  - nathanpayne-claude\n' > "$PADDED_POLICY"
slugs="$(pr_body_available_authoring_agents "$PADDED_POLICY" | tr '\n' ' ')"
rm -f "$PADDED_POLICY"
case "$slugs" in
  *codex*claude*|*claude*codex*) ok "reviewer entry padded after its closing quote is still parsed ($slugs)" ;;
  *) bad "padded reviewer entry was dropped; got [$slugs]" ;;
esac

# --- 8. an ambiguous author marker must ABORT the gate, not blank it ---------
# An empty same-agent reviewer is read downstream as "accept any registered
# reviewer", so converting an ambiguous body into that sentinel is fail-open.
if grep -q "refusing to evaluate gate (b) with an ambiguous authoring agent" "$ROOT/scripts/codex-review-check.sh"; then
  ok "codex-review-check aborts on an ambiguous Authoring-Agent count"
else
  bad "codex-review-check still lets a non-1 marker count fall through to the empty sentinel"
fi

# --- 9. prefix executables the GUARD sees through -----------------------------
# `env FOO=x gh pr create` and `command gh pr create` both reach gh, and the
# guard recognises the nested create and delegates here. A wrapper that rejects
# the prefix takes its generic path, skipping body validation AND the
# post-create author readback while the guard believes it delegated.
check_shape create "env with an assignment"      env FOO=x gh pr create --title t
check_shape create "absolute env"                /usr/bin/env gh pr new --title t
check_shape create "command builtin prefix"      command gh pr create --title t
check_shape other  "command -v diagnostic"       command -v gh pr create --title t
check_shape other  "command -V diagnostic"       command -V gh pr create --title t
check_shape other  "prefixed non-create"         env FOO=x gh pr merge 1
check_shape other  "prefixed non-gh executable"  env FOO=x notgh pr create --title t

# --- 10. an indented backtick run is code, not a fence ------------------------
# `    \u0060\u0060\u0060` was trimmed to a fence opener that never closed, so the rest of
# the body -- including valid top-level markers -- was discarded and a correct
# PR body was rejected as having no author.
INDENTED_FENCE=$'    ```\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$INDENTED_FENCE")"
got_agent="$(pr_body_authoring_agent "$INDENTED_FENCE")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ]; then
  ok "an indented backtick line does not open a fence (count=1, agent=claude)"
else
  bad "indented-fence body: expected count=1 agent=claude, got count=$got_count agent=$got_agent"
fi
if pr_body_has_self_review "$INDENTED_FENCE"; then
  ok "an indented backtick line does not hide a following ## Self-Review"
else
  bad "indented-fence body: ## Self-Review was suppressed"
fi

# The narrowing must not cost real fence suppression.
REAL_FENCE=$'```\nAuthoring-Agent: codex\n```\n\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_agent="$(pr_body_authoring_agent "$REAL_FENCE")"
if [ "$got_agent" = "claude" ]; then
  ok "a real top-level fence still suppresses its contents"
else
  bad "real fence: expected agent=claude, got $got_agent"
fi

# HTML-comment delimiters inside a fence are literal code. Processing comments
# first leaves the parser stuck in comment state after the closing fence and
# hides the real declarations that follow it.
FENCED_COMMENT=$'```html\n<!-- literal example\n```\n\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$FENCED_COMMENT")"
got_agent="$(pr_body_authoring_agent "$FENCED_COMMENT")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ] && pr_body_has_self_review "$FENCED_COMMENT"; then
  ok "an HTML-comment opener inside a fence cannot hide later visible markers"
else
  bad "fenced-comment body: expected count=1 agent=claude and Self-Review, got count=$got_count agent=$got_agent"
fi

# A generic type-7 HTML block needs a complete open/close tag. An incomplete
# '<foo' line is ordinary text and must not swallow the declarations below it.
INCOMPLETE_TAG=$'<foo\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$INCOMPLETE_TAG")"
got_agent="$(pr_body_authoring_agent "$INCOMPLETE_TAG")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ]; then
  ok "an incomplete generic HTML tag cannot open a blank-terminated block"
else
  bad "incomplete-tag body: expected count=1 agent=claude, got count=$got_count agent=$got_agent"
fi

# CommonMark condition 6 recognizes a fixed set of block tags even when the
# opening tag ends immediately after its name. A generic incomplete tag stays
# prose (the control above), while `<div` opens a blank-terminated HTML block.
INCOMPLETE_BLOCK_TAG=$'<div\nAuthoring-Agent: claude\n## Self-Review\n\nvisible'
got_count="$(pr_body_authoring_agent_count "$INCOMPLETE_BLOCK_TAG")"
if [ "$got_count" = "0" ] && ! pr_body_has_self_review "$INCOMPLETE_BLOCK_TAG"; then
  ok "an incomplete recognized block tag suppresses markers until a blank line"
else
  bad "incomplete block-tag body: raw-HTML declarations were accepted"
fi

# A fence-looking line inside raw HTML is HTML content, not a Markdown fence.
# The raw block closes at </script>, after which declarations are visible
# without an intervening blank line.
RAW_HTML_FENCE=$'<script>\n```\n</script>\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$RAW_HTML_FENCE")"
got_agent="$(pr_body_authoring_agent "$RAW_HTML_FENCE")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ]; then
  ok "a fence-looking line inside raw HTML cannot hide later visible markers"
else
  bad "raw-html-fence body: expected count=1 agent=claude, got count=$got_count agent=$got_agent"
fi

# A delimiter in a different Markdown container is literal content, not the
# close for a top-level fence. Flattening the blockquote prefix made this line
# close the fence early and exposed declarations that CommonMark still renders
# as code.
CONTAINER_FENCE=$'```text\n> ```\nAuthoring-Agent: claude\n\n## Self-Review\nok\n```'
got_count="$(pr_body_authoring_agent_count "$CONTAINER_FENCE")"
if [ "$got_count" = "0" ] && ! pr_body_has_self_review "$CONTAINER_FENCE"; then
  ok "a blockquote fence delimiter cannot close a top-level fence"
else
  bad "container-fence body: hidden markers escaped their top-level fence"
fi

UNICODE_FENCE_CLOSE=$'```text\n```\u2003\nAuthoring-Agent: claude\n\n## Self-Review\nok\n```'
got_count="$(pr_body_authoring_agent_count "$UNICODE_FENCE_CLOSE")"
if [ "$got_count" = "0" ] && ! pr_body_has_self_review "$UNICODE_FENCE_CLOSE"; then
  ok "Unicode whitespace cannot close a CommonMark fenced block"
else
  bad "Unicode fence-close body: hidden markers escaped their fence"
fi

# Contract markers are deliberately top-level. Two-space list continuations
# and explicit blockquotes render inside their containers, so accepting either
# would let nested prose satisfy the policy.
LIST_CONTINUATION=$'- note\n  Authoring-Agent: claude\n  ## Self-Review\n  nested'
got_count="$(pr_body_authoring_agent_count "$LIST_CONTINUATION")"
if [ "$got_count" = "0" ] && ! pr_body_has_self_review "$LIST_CONTINUATION"; then
  ok "list-continuation declarations are not top-level contract markers"
else
  bad "list-continuation body: nested declarations were accepted"
fi

BLOCKQUOTE_MARKERS=$'> Authoring-Agent: claude\n> ## Self-Review\n> nested'
got_count="$(pr_body_authoring_agent_count "$BLOCKQUOTE_MARKERS")"
if [ "$got_count" = "0" ] && ! pr_body_has_self_review "$BLOCKQUOTE_MARKERS"; then
  ok "blockquote declarations are not top-level contract markers"
else
  bad "blockquote body: nested declarations were accepted"
fi

MULTILINE_CODE_SPAN=$'## Self-Review\n\n`example\nAuthoring-Agent: codex\n`'
got_count="$(pr_body_authoring_agent_count "$MULTILINE_CODE_SPAN")"
if [ "$got_count" = "0" ]; then
  ok "a marker inside a multiline code span is not a contract declaration"
else
  bad "multiline-code-span body: hidden Authoring-Agent was accepted"
fi

BACKTICK_INFO=$'```foo`bar\nAuthoring-Agent: claude\n\n## Self-Review\nok'
got_count="$(pr_body_authoring_agent_count "$BACKTICK_INFO")"
got_agent="$(pr_body_authoring_agent "$BACKTICK_INFO")"
if [ "$got_count" = "1" ] && [ "$got_agent" = "claude" ]; then
  ok "a backtick in a backtick-fence info string prevents fence opening"
else
  bad "backtick-info body: expected count=1 agent=claude, got count=$got_count agent=$got_agent"
fi

# --- 11. the HOOK must fail closed on parser trouble --------------------------
# A non-2 hook exit is a NONBLOCKING error in the hook wiring, so letting `set
# -e` propagate the helper status would fail OPEN on the self-approve check --
# the opposite of the intent. Both helper calls must be caught explicitly.
guard_exit2=$(grep -c "refusing to evaluate self-approval" "$ROOT/scripts/hooks/gh-pr-guard.sh")
if [ "$guard_exit2" -ge 2 ]; then
  ok "gh-pr-guard catches BOTH parser calls and exits 2 (blocking)"
else
  bad "gh-pr-guard has $guard_exit2 explicit parser exit-2 guards, expected 2"
fi

# --- 12. the contract's own verdicts, including the #1132 bypass -------------
# A workflow assertion alone cannot see a parser regression, and "rejects the
# fenced body" alone is satisfied by a gate that rejects everything -- so the
# valid body is asserted to PASS in the same block.
POLICY="$ROOT/.github/review-policy.yml"
FENCED_SR=$'Authoring-Agent: claude\n\nSome PR.\n\n```\n## Self-Review\n```\n'
VALID_BODY=$'Authoring-Agent: claude\n\n## Self-Review\n\n- Correctness: verified.\n'
UNKNOWN_AGENT=$'Authoring-Agent: nobody\n\n## Self-Review\n\n- ok.\n'
TWO_AGENTS=$'Authoring-Agent: claude\nAuthoring-Agent: codex\n\n## Self-Review\n\n- ok.\n'

if pr_body_validate "$FENCED_SR" "$POLICY" >/dev/null 2>&1; then
  bad "a ## Self-Review heading inside a code fence was ACCEPTED (the #1132 bypass)"
else
  ok "a ## Self-Review heading inside a code fence is rejected"
fi

if pr_body_validate "$VALID_BODY" "$POLICY" >/dev/null 2>&1; then
  ok "a well-formed body is accepted (the rejections are not blanket)"
else
  bad "a well-formed body was rejected — the gate would block every PR"
fi

if pr_body_validate "$UNKNOWN_AGENT" "$POLICY" >/dev/null 2>&1; then
  bad "an unknown Authoring-Agent was accepted"
else
  ok "an unknown Authoring-Agent is rejected"
fi

if pr_body_validate "$TWO_AGENTS" "$POLICY" >/dev/null 2>&1; then
  bad "two Authoring-Agent lines were accepted"
else
  ok "two Authoring-Agent lines are rejected"
fi

# --- 13. the policy argument's failure modes must be honest ------------------
# Before #1132 an unreadable policy rejected EVERY body while reporting
# "unknown Authoring-Agent" -- blaming the author for a repo misconfiguration
# no PR edit could fix. It must still fail closed, but say what actually broke.
unreadable_out=$(pr_body_validate "$VALID_BODY" "/nonexistent/review-policy.yml" 2>&1 || true)
if pr_body_validate "$VALID_BODY" "/nonexistent/review-policy.yml" >/dev/null 2>&1; then
  bad "an unreadable policy file ACCEPTED a body — the gate fails open"
else
  ok "an unreadable policy file still fails closed"
fi
if printf '%s\n' "$unreadable_out" | grep -qF 'unknown Authoring-Agent'; then
  bad "an unreadable policy is still reported as 'unknown Authoring-Agent' (blames the author)"
else
  ok "an unreadable policy is not misreported as an unknown agent"
fi
if printf '%s\n' "$unreadable_out" | grep -qiE 'configuration problem|could be derived'; then
  ok "an unreadable policy names itself as the cause"
else
  bad "an unreadable policy gives no actionable diagnostic: $unreadable_out"
fi

# The empty-policy case is a DELIBERATE fail-open for callers that want only
# the structural checks. It is pinned here so it stays a documented choice
# rather than drifting into an accident, and so any gate that starts passing
# "" is caught by the assertion below it.
if pr_body_validate "$UNKNOWN_AGENT" "" >/dev/null 2>&1; then
  ok "an empty policy arg deliberately skips the agent allow-list (documented fail-open)"
else
  bad "the empty-policy contract changed; update the exit-status docs in pr-body-contract.sh"
fi
if grep -qF 'pr_body_validate "$BODY" "$ROOT/.github/review-policy.yml"' "$ROOT/scripts/validate-pr-body.sh"; then
  ok "the gate entrypoint passes a concrete policy path, so the fail-open is unreachable from CI"
else
  bad "scripts/validate-pr-body.sh must pass an absolute policy path, or the agent check silently disables"
fi

# --- 12. the REQUIRED Self-Review gate uses the parser, not a line grep ------
# The server-side gate is the ONLY backstop for a PR created through the web UI
# or the REST API, where the local gh-as-author wrapper never runs. A
# line-based `grep -qE '^## Self-Review'` is satisfied by a heading inside a
# fenced code block, so the required check passed bodies the parser rejects
# (#1132).
PRP=".github/workflows/pr-review-policy.yml"
prp_job=$(awk '/^  self-review-check:/{f=1;next} /^  [a-z-]+:$/{f=0} f' "$ROOT/$PRP")
# Live YAML only: the job's comments explain what it does and does not use, and
# comments are readable as either half of an assertion — a positive one goes
# green on prose describing a deleted option, a negative one fires on prose
# documenting the pattern it forbids.
prp_live=$(printf '%s\n' "$prp_job" | grep -vE '^[[:space:]]*#')

if printf '%s\n' "$prp_live" | grep -qE "grep -q[A-Za-z]*[[:space:]]+.\^## Self-Review"; then
  bad "$PRP still gates Self-Review with a line grep (a fenced heading defeats it)"
else
  ok "the Self-Review gate no longer relies on a line grep"
fi
if printf '%s\n' "$prp_live" | grep -qF 'pr-body-contract.mjs'; then
  ok "the Self-Review gate routes through the markdown-aware parser"
else
  bad "$PRP does not call the parser; the gate cannot see fenced headings"
fi
# Scope guard: this gate checks the HEADING only. Enforcing the identity
# contract here is a POLICY change (#1137) and must be a deliberate edit to
# this assertion, not a silent widening.
if printf '%s\n' "$prp_live" | grep -qF -- '--has-self-review'; then
  ok "the gate asks only the heading question; the identity contract is not bundled in"
else
  bad "$PRP no longer passes --has-self-review; widening this required check is a policy change"
fi
# The gate must call an interface the DEFAULT BRANCH already provides: the
# validator is loaded from there, so a flag added in the same PR that uses it
# does not exist when the gate runs and the required check fails `usage:` on
# its own PR.
if printf '%s\n' "$prp_live" | grep -qF -- '--self-review-only'; then
  bad "$PRP calls --self-review-only, a flag added in this same change; the gate loads the validator from the default branch and will fail usage: on its own PR"
else
  ok "the gate uses no flag introduced alongside it (no bootstrap window)"
fi
if printf '%s\n' "$prp_live" | grep -qF 'uses: actions/checkout@'; then
  if printf '%s\n' "$prp_live" | grep -qF 'ref: ${{ github.event.repository.default_branch }}'; then
    ok "the gate checks the validator out from the TRUSTED default branch"
  else
    bad "$PRP checks out without pinning ref to default_branch — a PR could edit its own validator"
  fi
  if printf '%s\n' "$prp_live" | grep -qF 'persist-credentials: false'; then
    ok "the trusted validator checkout does not persist credentials"
  else
    bad "$PRP trusted checkout must set persist-credentials: false (#548)"
  fi
else
  bad "$PRP self-review-check has no checkout, so it cannot run the trusted validator"
fi
if printf '%s\n' "$prp_live" | grep -qF 'node-version-file'; then
  bad "$PRP uses node-version-file; canonical workflows must not depend on a consumer-owned .nvmrc"
else
  ok "the gate pins Node by literal version, not a consumer-owned .nvmrc"
fi

# --- 13. the heading semantics the gate now enforces -------------------------
FENCED_SR=$'Authoring-Agent: claude\n\ntext\n\n```\n## Self-Review\n```\n'
REAL_SR=$'Authoring-Agent: claude\n\n## Self-Review\n\n- Correctness: verified.\n'
NO_SR=$'Authoring-Agent: claude\n\nno heading at all\n'
pr_body_has_self_review "$FENCED_SR" >/dev/null 2>&1 \
  && bad "a ## Self-Review heading inside a code fence was ACCEPTED (the #1132 bypass)" \
  || ok "a ## Self-Review heading inside a code fence is rejected"
pr_body_has_self_review "$REAL_SR" >/dev/null 2>&1 \
  && ok "a real ## Self-Review heading is accepted (the rejection is not blanket)" \
  || bad "a real ## Self-Review heading was rejected — the gate would block every PR"
pr_body_has_self_review "$NO_SR" >/dev/null 2>&1 \
  && bad "a body with no heading was accepted" \
  || ok "a body with no ## Self-Review heading is rejected"

# The narrowed gate must NOT enforce the identity contract. A body with no
# Authoring-Agent line at all has to pass, or this PR is silently carrying a
# policy change it does not claim to.
NO_AGENT=$'## Self-Review\n\n- no Authoring-Agent line anywhere.\n'
if printf '%s\n' "$NO_AGENT" | node "$ROOT/scripts/lib/pr-body-contract.mjs" --has-self-review >/dev/null 2>&1; then
  ok "the gate's question accepts a body with no Authoring-Agent (scope is the heading alone)"
else
  bad "the gate's question rejected a body with no Authoring-Agent; it has silently widened to the identity contract"
fi

echo
echo "test_pr_body_contract_parity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
