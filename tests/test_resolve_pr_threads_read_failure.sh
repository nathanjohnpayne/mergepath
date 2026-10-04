#!/usr/bin/env bash
# tests/test_resolve_pr_threads_read_failure.sh — #1104
#
# The HEAD-oid read is the FIRST call every disposition sweep makes, so its
# failure behaviour is the sweep's failure behaviour. Before #1104 it discarded
# the error body and exited 2 for every cause, which made a rate-limited
# reviewer PAT indistinguishable from a missing PR. Replies still posted (a
# separate, earlier call), so the loop looked healthy while nothing was ever
# resolved and threads accumulated until the PR could not converge.
#
# What is under test is therefore not "does it fail" but "does it fail
# DISTINGUISHABLY": a caller must be able to tell "I looked and there was
# nothing to do" from "I never managed to look".

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-pr-threads.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rpt-readfail.XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub `gh` so every call fails with the given stderr, which is what a
# rate-limited / missing / transient call looks like to this script.
# Portable bounded execution. `timeout` is GNU coreutils and is NOT present on
# a stock macOS box, where it would return 127 for every invocation below and
# fail this suite without running the resolver once. Same fallback shape as
# p4b_run_with_timeout in scripts/phase-4b/lib.sh: perl's alarm survives exec,
# so the target stays bounded.
bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"
  else
    # No bound available: run unbounded rather than reporting a false failure.
    # A hang here is visible as a stuck suite, which is honest; a 127 is not.
    echo "NOTE: neither timeout nor perl available; running unbounded" >&2
    "$@"
  fi
}

run_with_stub() {
  local stderr_line="$1"; shift
  printf '#!/usr/bin/env bash\necho %q >&2\nexit 1\n' "$stderr_line" > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"
  ( cd "$ROOT" \
    && PATH="$STUB_DIR:$PATH" \
       GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=2 \
       OP_PREFLIGHT_REVIEWER_PAT=stub-token \
       bounded 60 bash "$SCRIPT" 999 --repo owner/name --list ) >"$STUB_DIR/out" 2>&1
  echo $?
}

# --- rate limit: must be exit 4, must name the account -----------------------
rc=$(run_with_stub "gh: API rate limit exceeded for user ID 270731004. (HTTP 403)")
out="$(cat "$STUB_DIR/out")"
[ "$rc" = "4" ] && ok "rate-limited read exits 4 (could-not-look), not 2" \
                || bad "rate-limited read exited $rc, expected 4"
grep -qi "RATE LIMITED" <<<"$out" && ok "rate-limit failure says so in plain words" \
                                  || bad "rate-limit failure does not name the cause: $out"
grep -q "270731004" <<<"$out" && ok "rate-limit failure names the exhausted user ID" \
                              || bad "rate-limit failure does not name the user ID"
grep -qi "nothing was resolved" <<<"$out" \
  && ok "rate-limit failure states no work was done (not a completed pass)" \
  || bad "rate-limit failure does not distinguish itself from a completed sweep"
# The /rate_limit endpoint is exempt and reports a fresh window while real calls
# 403, so steering the operator to it would actively mislead. Guard the steer.
grep -qi "do not trust gh api rate_limit" <<<"$out" \
  && ok "rate-limit failure warns that gh api rate_limit is exempt and misleading" \
  || bad "rate-limit failure omits the /rate_limit caveat"

# --- genuine 404: still exit 2, and must NOT claim a rate limit ---------------
rc=$(run_with_stub "gh: Not Found (HTTP 404)")
out="$(cat "$STUB_DIR/out")"
[ "$rc" = "2" ] && ok "missing PR exits 2 (we looked; it is not there)" \
                || bad "missing PR exited $rc, expected 2"
grep -qi "RATE LIMITED" <<<"$out" && bad "404 wrongly reported as a rate limit" \
                                  || ok "404 is not misreported as a rate limit"

# --- unclassified transient: exit 4, never silently 0 ------------------------
rc=$(run_with_stub "gh: connection reset by peer")
[ "$rc" = "4" ] && ok "unclassified read failure exits 4 rather than passing silently" \
                || bad "unclassified read failure exited $rc, expected 4"

# --- the error body must reach the operator at all ---------------------------
out="$(cat "$STUB_DIR/out")"
grep -q "gh said:" <<<"$out" && ok "the underlying gh error body is surfaced, not discarded" \
                             || bad "gh error body was discarded (the #1104 root cause)"

# --- the error body on STDOUT, with the retry helper ABSENT ------------------
# `gh api` writes its HTTP error body to STDOUT, not stderr. The degraded path
# (no gh-retry-helpers.sh) previously sent stdout into HEAD_OID and classified
# only stderr, so the one text that distinguishes a 403 rate limit from a 404
# was thrown away -- the exact discard this suite exists to prevent, one path
# over. A unique marker is used so a pass cannot come from some other message.
STDOUT_MARKER="UNIQUEBODY7f3a rate limit exceeded for user ID 270731004"
NOHELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rpt-nohelper.XXXXXX")"
mkdir -p "$NOHELPER_DIR/scripts/lib" "$NOHELPER_DIR/.github"
cp "$ROOT/scripts/resolve-pr-threads.sh" "$NOHELPER_DIR/scripts/"
for dep in preflight-helpers.sh gh-token-resolver.sh; do
  [ -f "$ROOT/scripts/lib/$dep" ] && cp "$ROOT/scripts/lib/$dep" "$NOHELPER_DIR/scripts/lib/"
done
# gh-retry-helpers.sh deliberately NOT copied: this is the degraded path.
[ -f "$ROOT/.github/review-policy.yml" ] && cp "$ROOT/.github/review-policy.yml" "$NOHELPER_DIR/.github/"

# stderr stays EMPTY; the body goes to stdout, which is what gh actually does.
printf '#!/usr/bin/env bash\necho %q\nexit 1\n' "$STDOUT_MARKER" > "$STUB_DIR/gh"
chmod +x "$STUB_DIR/gh"
( cd "$NOHELPER_DIR" \
  && PATH="$STUB_DIR:$PATH" OP_PREFLIGHT_REVIEWER_PAT=stub-token \
     bounded 60 bash scripts/resolve-pr-threads.sh 999 --repo owner/name --list ) \
  >"$STUB_DIR/nohelper.out" 2>&1
nh_rc=$?
nh_out="$(cat "$STUB_DIR/nohelper.out")"
rm -rf "$NOHELPER_DIR"

[ "$nh_rc" = "4" ] \
  && ok "stdout-only error body, retry helper absent: still exits 4" \
  || bad "stdout-only error body: exited $nh_rc, expected 4"
grep -q "UNIQUEBODY7f3a" <<<"$nh_out" \
  && ok "the stdout error body reaches the operator (not discarded into HEAD_OID)" \
  || bad "the stdout error body was discarded; output: $nh_out"
grep -qi "RATE LIMITED" <<<"$nh_out" \
  && ok "a stdout-only rate-limit body is still CLASSIFIED as a rate limit" \
  || bad "stdout-only rate-limit body was not classified: $nh_out"

# ---------------------------------------------------------------------------
# #1057 A3: the cloud GraphQL ceiling. REST reads succeed and every GraphQL
# request is refused with the proxy's documented message. That is a property
# of the session, not a failed read, so it gets its own exit (6) and a message
# that says so, never the generic "GraphQL query failed" exit 2 that invites a
# retry. A GraphQL failure WITHOUT the phrase keeps exit 2 (control).
# ---------------------------------------------------------------------------
ceiling_run() { # <graphql stderr line> -> echoes rc; output in $STUB_DIR/ceiling.out
  cat >"$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *graphql*) echo $(printf '%q' "$1") >&2; exit 1 ;;
esac
echo '{}'
STUB
  chmod +x "$STUB_DIR/gh"
  ( cd "$ROOT" \
    && PATH="$STUB_DIR:$PATH" \
       GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=2 \
       OP_PREFLIGHT_REVIEWER_PAT=stub-token \
       bounded 60 bash "$SCRIPT" 999 --repo owner/name --list ) >"$STUB_DIR/ceiling.out" 2>&1
  echo $?
}

c_rc=$(ceiling_run "gh: This GraphQL query is not enabled for this session. Use gh api repos/{owner}/{repo}/... (HTTP 403)")
c_out="$(cat "$STUB_DIR/ceiling.out")"
[ "$c_rc" = "6" ] \
  && ok "proxy GraphQL refusal on the thread read exits 6 (ceiling), not 2" \
  || bad "proxy GraphQL refusal: exited $c_rc, expected 6; output: $c_out"
grep -q "CEILING" <<<"$c_out" && grep -q "not a credential gap" <<<"$c_out" \
  && ok "the ceiling message names the ceiling and says a token cannot fix it" \
  || bad "ceiling message missing its explanation: $c_out"
grep -q "GraphQL query failed" <<<"$c_out" \
  && bad "the ceiling was ALSO reported as a generic GraphQL failure: $c_out" \
  || ok "the ceiling is not reported as a generic GraphQL failure"

g_rc=$(ceiling_run "gh: Something went wrong while executing your query. (HTTP 502)")
[ "$g_rc" = "2" ] \
  && ok "control: a GraphQL failure without the proxy phrase keeps exit 2" \
  || bad "control: generic GraphQL failure exited $g_rc, expected 2"

# The classifier itself: the phrase anywhere in captured text, nothing else.
(
  # shellcheck source=../scripts/lib/graphql-ceiling.sh
  . "$ROOT/scripts/lib/graphql-ceiling.sh"
  graphql_ceiling_hit '{"message":"This GraphQL query is not enabled for this session"}' || exit 11
  graphql_ceiling_hit 'gh: Resource not accessible by integration (HTTP 403)' && exit 12
  graphql_ceiling_hit '' && exit 13
  exit 0
)
cls_rc=$?
[ "$cls_rc" -eq 0 ] \
  && ok "graphql_ceiling_hit matches the proxy phrase and nothing else" \
  || bad "graphql_ceiling_hit misclassified (case $cls_rc)"

# The proxy's later wording (observed 2026-10-04) is the same ceiling.
UNAVAILABLE_MSG='{"message":"GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). For review threads use the CCR routes on api.github.com."}'
(
  . "$ROOT/scripts/lib/graphql-ceiling.sh"
  graphql_ceiling_hit "$UNAVAILABLE_MSG" || exit 11
  graphql_ceiling_hit 'gh: GraphQL: Could not resolve to a Repository (HTTP 200)' && exit 12
  # A wording not seen yet is still the proxy when its body points at
  # Anthropic's documentation; GitHub's own errors point at docs.github.com.
  graphql_ceiling_hit '{"message":"Some future proxy wording","documentation_url":"https://docs.anthropic.com/en/docs/claude-code/github-actions"}' || exit 13
  graphql_ceiling_hit '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/graphql"}' && exit 14
  # Pretty-printed JSON spaces the colon; the provenance match must not depend on it.
  graphql_ceiling_hit '{"message":"Some future proxy wording", "documentation_url": "https://docs.anthropic.com/en/docs/claude-code/github-actions"}' || exit 15
  graphql_ceiling_hit "$(printf '{\n  "message": "Some future proxy wording",\n  "documentation_url" :  "https://docs.anthropic.com/x"\n}')" || exit 16
  graphql_ceiling_hit '{"message":"Nope", "documentation_url": "https://docs.github.com/graphql"}' && exit 17
  graphql_ceiling_hit '{"documentation_url":"https://docsXanthropicYcom/"}' && exit 18
  exit 0
)
cls2_rc=$?
[ "$cls2_rc" -eq 0 ] \
  && ok "graphql_ceiling_hit matches the proxy's no-GraphQL wording, and any refusal carrying the proxy's documentation URL, but not GitHub's own errors" \
  || bad "graphql_ceiling_hit misclassified (case $cls2_rc)"
u_rc=$(ceiling_run "gh: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...). (HTTP 403)")
[ "$u_rc" = "6" ] \
  && ok "--list with the no-GraphQL wording and no proxy thread route: exits 6 (ceiling)" \
  || bad "no-GraphQL wording without a route: exited $u_rc, expected 6; output: $(cat "$STUB_DIR/ceiling.out")"

# --list through the proxy's REST thread route (reads only). The route gives
# resolution state and comment ids; the REST review-comment list gives author
# and body, and the two must describe the same threads or nothing is listed.
route_run() { # <route json> <comments json|FAIL> [args...] -> echoes rc; output in $STUB_DIR/route.out
  local route="$1" comments="$2"; shift 2
  printf '%s' "$route" >"$STUB_DIR/route.json"
  printf '%s' "$comments" >"$STUB_DIR/comments.json"
  cat >"$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$STUB_DIR/route.calls"
case "\$*" in
  *graphql*) echo '$UNAVAILABLE_MSG'; echo 'gh: HTTP 403' >&2; exit 1 ;;
  *"repo view"*) echo 'gh: GraphQL refused (HTTP 403)' >&2; exit 1 ;;
  *ccr/review_threads*) cat "$STUB_DIR/route.json"; exit 0 ;;
  *"/comments"*) if grep -qx FAIL "$STUB_DIR/comments.json"; then echo 'gh: HTTP 502' >&2; exit 1; fi; cat "$STUB_DIR/comments.json"; exit 0 ;;
esac
echo '{}'
STUB
  chmod +x "$STUB_DIR/gh"
  : >"$STUB_DIR/route.calls"
  ( cd "${ROUTE_CWD:-$ROOT}" \
    && PATH="$STUB_DIR:$PATH" GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=2 \
       OP_PREFLIGHT_REVIEWER_PAT=stub-token RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
       bounded 60 bash "$SCRIPT" 999 "$@" ) >"$STUB_DIR/route.out" 2>&1
  echo $?
}
ROUTE_TWO='[{"resolved":false,"outdated":false,"path":"a.sh","line":3,"comment_ids":[11,12]},{"resolved":true,"outdated":true,"path":"b.sh","line":null,"comment_ids":[21]}]'
COMMENTS_TWO='[{"id":11,"in_reply_to_id":null,"user":{"login":"coderabbitai[bot]"},"path":"a.sh","body":"UNIQUEFINDING91c"},{"id":12,"in_reply_to_id":11,"user":{"login":"nathanpayne-claude"},"path":"a.sh","body":"reply"},{"id":21,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"path":"b.sh","body":"resolved one"}]'

r_rc=$(route_run "$ROUTE_TWO" "$COMMENTS_TWO" --repo owner/name --list)
r_out="$(cat "$STUB_DIR/route.out")"
if [ "$r_rc" = "3" ] && grep -q "Unresolved threads on owner/name#999: 1 (read through the cloud proxy's REST thread route)" <<<"$r_out" \
   && grep -q "\[coderabbitai\[bot\]\] a.sh" <<<"$r_out" && grep -q UNIQUEFINDING91c <<<"$r_out" \
   && ! grep -q "resolved one" <<<"$r_out"; then
  ok "--list at the ceiling: unresolved threads listed from the proxy's REST route (exit 3), resolved ones omitted"
else
  bad "--list via route: rc=$r_rc output: $r_out"
fi
if grep -q "ccr/review_threads" "$STUB_DIR/route.calls" \
   && ! grep -qE -- '(^| )(-X|--method)( |$)|ccr/comments/|resolveReviewThread\(input' "$STUB_DIR/route.calls"; then
  ok "--list via route: reads only (no resolve call, no write method)"
else
  bad "--list via route made an unexpected call: $(cat "$STUB_DIR/route.calls")"
fi

r_rc=$(route_run '[{"resolved":true,"outdated":false,"path":"a.sh","line":3,"comment_ids":[11,12]},{"resolved":true,"outdated":true,"path":"b.sh","line":null,"comment_ids":[21]}]' "$COMMENTS_TWO" --repo owner/name --list)
[ "$r_rc" = "0" ] && grep -q "No unresolved threads on PR #999 (read through the cloud proxy's REST thread route)" "$STUB_DIR/route.out" \
  && ok "--list via route: every thread resolved exits 0" \
  || bad "--list via route, all resolved: rc=$r_rc output: $(cat "$STUB_DIR/route.out")"

# The route drops the unresolved thread: a root comment no route thread names.
r_rc=$(route_run '[{"resolved":true,"outdated":true,"path":"b.sh","line":null,"comment_ids":[21]}]' "$COMMENTS_TWO" --repo owner/name --list)
[ "$r_rc" = "2" ] && grep -q "disagree" "$STUB_DIR/route.out" && ! grep -q "No unresolved threads" "$STUB_DIR/route.out" \
  && ok "--list via route: a thread missing from the route fails closed (exit 2), never 'no unresolved threads'" \
  || bad "--list via route, truncated route: rc=$r_rc output: $(cat "$STUB_DIR/route.out")"

r_rc=$(route_run "$ROUTE_TWO" FAIL --repo owner/name --list)
[ "$r_rc" = "2" ] && ! grep -q "No unresolved threads" "$STUB_DIR/route.out" \
  && ok "--list via route: unreadable review comments fail closed (exit 2)" \
  || bad "--list via route, comments unreadable: rc=$r_rc output: $(cat "$STUB_DIR/route.out")"

r_rc=$(route_run "$ROUTE_TWO" "$COMMENTS_TWO" --repo owner/name --auto-resolve-bots)
[ "$r_rc" = "6" ] && ! grep -q "ccr/review_threads" "$STUB_DIR/route.calls" \
  && ok "a resolve mode at the ceiling still exits 6 and never uses the proxy route" \
  || bad "resolve mode with a route available: rc=$r_rc calls: $(cat "$STUB_DIR/route.calls")"

# Without --repo, `gh repo view` is GraphQL and refused; the github.com origin
# remote names the repository instead.
ORIGIN_DIR="$STUB_DIR/origin-repo"
mkdir -p "$ORIGIN_DIR" && git -C "$ORIGIN_DIR" init -q \
  && git -C "$ORIGIN_DIR" remote add origin https://github.com/acme/widgets.git
r_rc=$(ROUTE_CWD="$ORIGIN_DIR" route_run "$ROUTE_TWO" "$COMMENTS_TWO" --list)
[ "$r_rc" = "3" ] && grep -q "repos/acme/widgets/pulls/999/ccr/review_threads" "$STUB_DIR/route.calls" \
  && ok "no --repo and gh repo view refused: the repository comes from the github.com origin remote" \
  || bad "origin fallback: rc=$r_rc calls: $(cat "$STUB_DIR/route.calls") output: $(cat "$STUB_DIR/route.out")"
git -C "$ORIGIN_DIR" remote set-url origin https://example.com/acme/widgets.git
r_rc=$(ROUTE_CWD="$ORIGIN_DIR" route_run "$ROUTE_TWO" "$COMMENTS_TWO" --list)
[ "$r_rc" = "2" ] && grep -q "Could not resolve repo" "$STUB_DIR/route.out" \
  && ok "a non-github.com origin is not read as the repository" \
  || bad "non-github origin: rc=$r_rc output: $(cat "$STUB_DIR/route.out")"

# A refusal raised inside nested command substitutions (the per-thread
# comment refetch runs two levels down) must still end the run with 6, not
# collapse into an ordinary "pagination failed" (Codex P2 on #1529).
nest_out=$(bash -c '
  set -euo pipefail
  . "$1/scripts/lib/graphql-ceiling.sh"
  graphql_ceiling_install_trap
  inner() { graphql_ceiling_refuse probe "a nested read"; }
  outer() { local x; x=$(inner) || return 1; printf "%s" "$x"; }
  y=$(outer) || echo "caller saw an ordinary failure"
  echo "REACHED-AFTER-REFUSAL"
' _ "$ROOT" 2>&1)
nest_rc=$?
if [ "$nest_rc" -eq 6 ] && ! grep -q "REACHED-AFTER-REFUSAL" <<<"$nest_out"; then
  ok "a refusal two subshells deep ends the main shell with 6"
else
  bad "nested refusal: rc=$nest_rc output: $nest_out"
fi

# End to end: the thread enumeration is served, but the full-comment refetch
# for a truncated thread (60 comments, 50-comment window) is refused, with the
# refusal only in the response BODY that gh writes to stdout. Every resolve
# mode must end with 6 and resolve nothing (CodeRabbit and Codex on #1529).
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"node(id"*) echo '{"message":"This GraphQL query is not enabled for this session"}'; echo 'gh: HTTP 403' >&2; exit 1 ;;
  *resolveReviewThread*|*addPullRequestReviewThreadReply*) echo "MUTATION-ATTEMPTED" >&2; exit 1 ;;
  *reviewThreads*) cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_1","isResolved":false,"isOutdated":false,"commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"a.sh","body":"finding","createdAt":"2026-01-01T00:00:00Z"}]},"commentsLast":{"nodes":[{"commit":{"oid":"abc123"}}]},"allComments":{"totalCount":60,"pageInfo":{"hasPreviousPage":true},"nodes":[{"author":{"login":"coderabbitai"},"body":"finding","databaseId":1,"createdAt":"2026-01-01T00:00:00Z"}]}}]}}}}}
JSON
  exit 0 ;;
  *".head.sha"*) echo abc123; exit 0 ;;
esac
echo '[]'
STUB
chmod +x "$STUB_DIR/gh"
for mode in --resolve-actioned --auto-resolve-bots; do
  ( cd "$ROOT" \
    && PATH="$STUB_DIR:$PATH" GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=2 \
       OP_PREFLIGHT_REVIEWER_PAT=stub-token RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
       bounded 60 bash "$SCRIPT" 999 --repo owner/name "$mode" ) >"$STUB_DIR/refetch.out" 2>&1
  r_rc=$?
  if [ "$r_rc" -eq 6 ] && grep -q "CEILING — re-fetching the full comment history of review thread PRRT_1" "$STUB_DIR/refetch.out" \
     && ! grep -q "MUTATION-ATTEMPTED" "$STUB_DIR/refetch.out"; then
    ok "$mode: a refused comment refetch (body-only refusal) ends the run with 6 before any mutation"
  else
    bad "$mode: refused refetch exited $r_rc; output: $(cat "$STUB_DIR/refetch.out")"
  fi
done

# #1541: every gh call made with the PAT is pinned to github.com, the only
# host the write-identity check verifies.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${GH_HOST:-<unset>}" >>"%s"\necho "gh: HTTP 500" >&2\nexit 1\n' "$STUB_DIR/hosts.log" >"$STUB_DIR/gh"
chmod +x "$STUB_DIR/gh"
: >"$STUB_DIR/hosts.log"
( cd "$ROOT" && PATH="$STUB_DIR:$PATH" GH_RETRY_BACKOFF_SECONDS=0 GH_RETRY_ATTEMPTS=1 \
    OP_PREFLIGHT_REVIEWER_PAT=stub-token bounded 60 bash "$SCRIPT" 999 --repo owner/name --list ) >/dev/null 2>&1 || true
if [ -s "$STUB_DIR/hosts.log" ] && ! grep -vqx 'github.com' "$STUB_DIR/hosts.log"; then
  ok "every gh call made with the PAT runs with GH_HOST=github.com"
else
  bad "gh_pat host pinning: $(sort -u "$STUB_DIR/hosts.log" | tr '\n' ' ')"
fi

echo
echo "test_resolve_pr_threads_read_failure: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
