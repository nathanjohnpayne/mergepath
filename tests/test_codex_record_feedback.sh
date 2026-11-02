#!/usr/bin/env bash
# Regression coverage for scripts/codex-record-feedback.sh (#487).
#
# Runs the real script from a temp repo with a stubbed gh + a stubbed
# gh-as-reviewer.sh so the tests exercise the production solicitation-gate,
# verdict-mapping, idempotency, HEAD-pinned scan, and ledger flow without
# touching GitHub. The reaction WRITE path is asserted to go through
# gh-as-reviewer.sh under the reviewer identity (never a bare gh write).

# These cases drive the gh transport. Pin it so a cloud session's
# CLAUDE_CODE_REMOTE (or MERGEPATH_AGENT_SURFACE) cannot switch the wrappers
# to the REST transport, which tests/test_gh_rest_transport.sh covers.
export MERGEPATH_GH_TRANSPORT=gh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-record-feedback.sh"

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-record-feedback.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

SOLICIT='Useful? React with 👍 / 👎.'
# #682: byte-faithful fixture matching what chatgpt-codex-connector[bot]
# actually posts -- U+00A0 (NBSP, UTF-8 c2 a0) immediately before the slash,
# not the regular space (0x20) in $SOLICIT above.
NBSP=$'\xc2\xa0'
SOLICIT_NBSP="Useful? React with 👍${NBSP}/ 👎."

# make_case <name> — scaffolds a temp repo with the real script + lib resolver,
# a recording gh-as-reviewer.sh stub, and a configurable gh stub. Echoes the
# case directory.
make_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts/lib" "$dir/bin" "$dir/.github" "$dir/state"

  cp "$SCRIPT" "$dir/scripts/codex-record-feedback.sh"
  chmod +x "$dir/scripts/codex-record-feedback.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"  # #2913, --scan policy reader

  cat >"$dir/.github/review-policy.yml" <<'EOF'
codex:
  bot_login: "chatgpt-codex-connector[bot]"
EOF

  # Recording reviewer wrapper: logs the POST it was asked to make plus the
  # reviewer identity env it saw, then succeeds (unless CRF_REVIEWER_FAIL=1).
  cat >"$dir/scripts/gh-as-reviewer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${CRF_STATE:?}
printf '%s\n' "${GH_AS_REVIEWER_IDENTITY:-}" >>"$state/reviewer-identity"
[ "${1:-}" = "--" ] && shift
printf '%s\n' "$*" >>"$state/posts"
if [ "${CRF_REVIEWER_FAIL:-0}" = "1" ]; then
  echo "stubbed reviewer write failure" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$dir/scripts/gh-as-reviewer.sh"

  printf '%s\n' "$dir"
}

# write_gh_readonly <dir> — gh stub serving only the reaction-GET endpoints,
# returning [] (no pre-existing reviewer reaction) for every comment.
write_gh_readonly() {
  local dir=$1
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "api" ] || { echo "unexpected gh: $*" >&2; exit 9; }
shift
[ "${1:-}" = "--paginate" ] && shift
ep=${1:-}
case "$ep" in
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: $ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
}

# make_real_wrapper_case <name> — like make_case, but installs the REAL
# gh-as-reviewer.sh + gh-token-resolver.sh + identity-check.sh so the reaction
# WRITE actually travels the production reviewer-token resolution path. Used to
# exercise the ambient-GH_TOKEN bridge end-to-end (a stubbed wrapper can't).
# Echoes the case directory.
make_real_wrapper_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts/lib" "$dir/bin" "$dir/.github" "$dir/state"

  cp "$SCRIPT" "$dir/scripts/codex-record-feedback.sh"
  chmod +x "$dir/scripts/codex-record-feedback.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"  # #2913, --scan policy reader
  mkdir -p "$dir/scripts/workflow"
  cp "$ROOT/scripts/lib/gh-comment-trigger-guard.sh" "$dir/scripts/lib/gh-comment-trigger-guard.sh"
  cp "$ROOT/scripts/workflow/gh-comment-trigger-guard.py" "$dir/scripts/workflow/gh-comment-trigger-guard.py"
  cp "$ROOT/scripts/gh-as-reviewer.sh" "$dir/scripts/gh-as-reviewer.sh"
  chmod +x "$dir/scripts/gh-as-reviewer.sh"
  cp "$ROOT/scripts/lib/gh-rest-transport.sh" "$dir/scripts/lib/gh-rest-transport.sh"  # gh-as-reviewer.sh sources it (#1057 A)
  cp "$ROOT/scripts/identity-check.sh" "$dir/scripts/identity-check.sh"
  chmod +x "$dir/scripts/identity-check.sh"
  cp "$ROOT/scripts/lib/credential-class.sh" "$dir/scripts/lib/credential-class.sh"    # identity-check --expect-write-identity (#1057)

  cat >"$dir/.github/review-policy.yml" <<'EOF'
codex:
  bot_login: "chatgpt-codex-connector[bot]"
EOF

  printf '%s\n' "$dir"
}

run_case() {
  # run_case <dir> -- <args...>   (env via caller through `env`-style prefix)
  local dir=$1; shift
  [ "${1:-}" = "--" ] && shift
  local rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN="${CRF_GH_TOKEN:-test-token}" \
      CRF_STATE="$dir/state" \
      CODEX_FEEDBACK_LEDGER="$dir/state/ledger.jsonl" \
      GH_AS_REVIEWER_IDENTITY="${CRF_REVIEWER_IDENTITY:-nathanpayne-claude}" \
      "$dir/scripts/codex-record-feedback.sh" "$@" \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

posts_file() { printf '%s\n' "$1/state/posts"; }
ledger_lines() {
  if [ -f "$1/state/ledger.jsonl" ]; then wc -l <"$1/state/ledger.jsonl" | tr -d ' '; else printf '0\n'; fi
}

# --- tests -----------------------------------------------------------------

test_string_id_coerced_no_double_report() {
  # #618 (mirror of the #617 coderabbit-recorder fix): a digit-STRING
  # comment_id from --findings-json used to be recorded via string compare
  # while the numeric not-found pass missed it — one adjudicated finding
  # recorded AND reported skipped:not-found at once. Post-fix the id is
  # coerced to a number during normalization: exactly one ledger row (typed
  # number), the reaction posts to the right endpoint, zero not-found skips.
  local dir rc
  dir=$(make_case "string-id")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "scripts/ci/check_y", "line": 3, "priority": "P2", "comment_id": "5002",
    "body": "String id finding.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 5002=fixed)

  local row notfound
  row=$(head -1 "$dir/state/ledger.jsonl" 2>/dev/null || printf '')
  notfound=$(jq -r '[.skipped[] | select((.comment_id|tostring)=="5002" and .why=="not-found")] | length' "$dir/out.json")
  if [ "$rc" != "0" ]; then
    fail "string-id: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'gh api -X POST repos/owner/repo/pulls/comments/5002/reactions -f content=+1' "$(posts_file "$dir")"; then
    fail "string-id: did not POST +1 to comment 5002; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "string-id: ledger has $(ledger_lines "$dir") lines, expected 1"
  elif [ "$notfound" != "0" ]; then
    fail "string-id: id 5002 reported not-found $notfound time(s) despite being recorded; out=$(cat "$dir/out.json")"
  elif [ "$(printf '%s' "$row" | jq -r '.comment_id|type')" != "number" ]; then
    fail "string-id: recorded comment_id type was $(printf '%s' "$row" | jq -r '.comment_id|type'), expected number (coerced)"
  else
    pass "a digit-string comment_id is coerced at normalization: one ledger row, +1 posted, zero not-found skips (#618)"
  fi
}

test_fixed_reacts_plus1_via_reviewer() {
  local dir rc
  dir=$(make_case "fixed-plus1")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "scripts/ci/check_x", "line": 10, "priority": "P1", "comment_id": 5001,
    "body": "Sync the config test.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 5001=fixed)

  if [ "$rc" != "0" ]; then
    fail "fixed→+1: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'gh api -X POST repos/owner/repo/pulls/comments/5001/reactions -f content=+1' "$(posts_file "$dir")"; then
    fail "fixed→+1: did not POST +1 to the pull-request review-comment endpoint; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "posted" ]; then
    fail "fixed→+1: action was $(jq -r '.recorded[0].action' "$dir/out.json"), expected posted"
  elif [ "$(head -1 "$dir/state/reviewer-identity")" != "nathanpayne-claude" ]; then
    fail "fixed→+1: reviewer wrapper saw identity $(head -1 "$dir/state/reviewer-identity"), expected nathanpayne-claude"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "fixed→+1: ledger has $(ledger_lines "$dir") lines, expected 1"
  else
    pass "fixed verdict reacts +1 via gh-as-reviewer under the reviewer identity"
  fi
}

test_rebuttal_reacts_minus1() {
  local dir rc
  dir=$(make_case "rebuttal-minus1")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 6001,
    "body": "Wrong.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 6001=false-positive:"path does not exist on HEAD")

  if [ "$rc" != "0" ]; then
    fail "rebuttal→-1: exit $rc; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'content=-1' "$(posts_file "$dir")"; then
    fail "rebuttal→-1: did not POST -1; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  elif [ "$(jq -r '.recorded[0].reason' "$dir/out.json")" != "path does not exist on HEAD" ]; then
    fail "rebuttal→-1: reason not recorded; got $(jq -r '.recorded[0].reason' "$dir/out.json")"
  else
    pass "false-positive verdict reacts -1 and records the rebuttal reason"
  fi
}

test_no_solicitation_is_never_reacted() {
  local dir rc
  dir=$(make_case "no-solicit")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P2", "comment_id": 7001,
    "body": "A plain nit with no feedback prompt." }
] }
EOF
  # Even with a verdict supplied, a non-soliciting comment must not be reacted.
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 7001=fixed)

  if [ "$rc" != "0" ]; then
    fail "no-solicitation: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ -f "$(posts_file "$dir")" ]; then
    fail "no-solicitation: a reaction was POSTed for a non-soliciting comment; posts=$(cat "$(posts_file "$dir")")"
  elif [ "$(jq -r '.skipped[0].why' "$dir/out.json")" != "no-solicitation" ]; then
    fail "no-solicitation: skip reason was $(jq -r '.skipped[0].why' "$dir/out.json"), expected no-solicitation"
  elif [ "$(ledger_lines "$dir")" != "0" ]; then
    fail "no-solicitation: ledger should be empty, has $(ledger_lines "$dir") lines"
  else
    pass "a finding without the solicitation is never reacted to"
  fi
}

test_solicits_but_no_verdict_is_skipped() {
  local dir rc
  dir=$(make_case "no-verdict")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 8001,
    "body": "Real issue.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json)

  if [ "$rc" != "0" ]; then
    fail "no-verdict: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ -f "$(posts_file "$dir")" ]; then
    fail "no-verdict: a reaction was POSTed without a verdict"
  elif [ "$(jq -r '.skipped[0].why' "$dir/out.json")" != "no-verdict" ]; then
    fail "no-verdict: skip reason was $(jq -r '.skipped[0].why' "$dir/out.json"), expected no-verdict"
  else
    pass "a soliciting finding with no --verdict is skipped (no blanket reaction)"
  fi
}

test_nbsp_solicitation_is_matched() {
  # #682: the live Codex comment uses U+00A0 (NBSP) immediately before the
  # slash instead of a regular space. A byte-faithful fixture (not a
  # hand-typed ASCII approximation) must still be recognized as soliciting
  # feedback and reacted to, exactly like the plain-space form.
  local dir rc
  dir=$(make_case "nbsp-solicit")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "scripts/ci/check_z", "line": 7, "priority": "P1", "comment_id": 5101,
    "body": "NBSP-solicitation finding.\n\n$SOLICIT_NBSP" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 5101=fixed)

  if [ "$rc" != "0" ]; then
    fail "nbsp-solicit: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'gh api -X POST repos/owner/repo/pulls/comments/5101/reactions -f content=+1' "$(posts_file "$dir")"; then
    fail "nbsp-solicit: did not POST +1 for an NBSP-solicitation finding; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  elif [ "$(jq -r '.skipped | length' "$dir/out.json")" != "0" ]; then
    fail "nbsp-solicit: finding was skipped; out=$(cat "$dir/out.json")"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "nbsp-solicit: ledger has $(ledger_lines "$dir") lines, expected 1"
  else
    pass "a solicitation using U+00A0 (NBSP) before the slash is matched and reacted to, same as the plain-space form (#682)"
  fi
}

test_idempotent_existing_reviewer_reaction() {
  local dir rc
  dir=$(make_case "idempotent")
  # gh stub: reviewer already reacted on 9001, but not on 9002.
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "api" ] || { echo "unexpected gh: $*" >&2; exit 9; }
shift
[ "${1:-}" = "--paginate" ] && shift
ep=${1:-}
case "$ep" in
  repos/owner/repo/pulls/comments/9001/reactions)
    printf '[{"user":{"login":"nathanpayne-claude"},"content":"+1","id":1}]\n' ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: $ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 9001, "body": "done.\n\n$SOLICIT" },
  { "path": "y", "line": 2, "priority": "P1", "comment_id": 9002, "body": "done2.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 9001=fixed --verdict 9002=fixed)

  local posts_count
  posts_count=$(grep -c 'content=' "$(posts_file "$dir")" 2>/dev/null || printf '0')
  if [ "$rc" != "0" ]; then
    fail "idempotent: exit $rc; stderr=$(cat "$dir/err.log")"
  elif grep -q 'comments/9001/reactions' "$(posts_file "$dir")" 2>/dev/null; then
    fail "idempotent: re-posted on 9001 which the reviewer already reacted on"
  elif [ "$posts_count" != "1" ]; then
    fail "idempotent: expected exactly 1 POST (9002 only), got $posts_count"
  elif [ "$(jq -r '.recorded[] | select(.comment_id==9001) | .action' "$dir/out.json")" != "already_present" ]; then
    fail "idempotent: 9001 action was not already_present"
  else
    pass "existing reviewer reaction is left in place; only the un-reacted finding is posted"
  fi
}

test_dry_run_posts_nothing() {
  local dir rc
  dir=$(make_case "dry-run")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 1101, "body": "real.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 1101=fixed --dry-run)

  if [ "$rc" != "0" ]; then
    fail "dry-run: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ -f "$(posts_file "$dir")" ]; then
    fail "dry-run: a reaction was POSTed under --dry-run"
  elif [ "$(jq -r '.dry_run' "$dir/out.json")" != "true" ]; then
    fail "dry-run: summary dry_run flag not true"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "dry_run" ]; then
    fail "dry-run: action was $(jq -r '.recorded[0].action' "$dir/out.json"), expected dry_run"
  elif [ "$(ledger_lines "$dir")" != "0" ]; then
    fail "dry-run: ledger written under --dry-run ($(ledger_lines "$dir") lines)"
  else
    pass "dry-run resolves verdicts but posts nothing and writes no ledger"
  fi
}

test_unrecognized_verdict_fails_before_any_post() {
  local dir rc
  dir=$(make_case "bad-verdict")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 1201, "body": "real.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 1201=maybe)

  if [ "$rc" != "2" ]; then
    fail "bad-verdict: exit $rc, expected 2; stderr=$(cat "$dir/err.log")"
  elif [ -f "$(posts_file "$dir")" ]; then
    fail "bad-verdict: a reaction was POSTed despite an invalid verdict (no partial writes allowed)"
  else
    pass "an unrecognized verdict exits 2 before any reaction is posted"
  fi
}

test_scan_is_head_pinned_to_latest_round() {
  local dir rc
  dir=$(make_case "scan-head-pinned")
  # gh stub modeling: HEAD=head-sha; a STALE review (old, not HEAD) carries
  # 1300 (named by --verdict) and 1302 (unnamed); the CURRENT-HEAD latest
  # review (id 200) carries 1301. The scan collects ONLY 1301: the unnamed
  # stale 1302 never surfaces, the named stale 1300 is fetched by id (#2565).
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "api" ] || { echo "unexpected gh: \$*" >&2; exit 9; }
shift
[ "\${1:-}" = "--paginate" ] && shift
ep=\${1:-}
bot='chatgpt-codex-connector[bot]'
case "\$ep" in
  repos/owner/repo/pulls/999)
    printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/pulls/999/reviews)
    printf '[{"id":100,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-01T00:00:00Z","commit_id":"old-sha"},{"id":200,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-02T00:00:00Z","commit_id":"head-sha"}]\n' "\$bot" "\$bot" ;;
  repos/owner/repo/pulls/999/comments)
    printf '[{"id":1300,"user":{"login":"%s"},"pull_request_review_id":100,"path":"old","line":1,"body":"STALE P1. $SOLICIT"},{"id":1301,"user":{"login":"%s"},"pull_request_review_id":200,"path":"new","line":2,"body":"![P1 Badge] current. $SOLICIT"},{"id":1302,"user":{"login":"%s"},"pull_request_review_id":100,"path":"old2","line":3,"body":"![P2 Badge] unnamed stale. $SOLICIT"}]\n' "\$bot" "\$bot" "\$bot" ;;
  repos/owner/repo/pulls/comments/1300)
    printf '{"id":1300,"user":{"login":"%s"},"pull_request_url":"https://api.github.com/repos/owner/repo/pulls/999","pull_request_review_id":100,"commit_id":"old-sha","path":"old","line":null,"original_line":1,"body":"![P1 Badge] STALE P1. $SOLICIT"}\n' "\$bot" ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: \$ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1300=fixed --verdict 1301=fixed)

  if [ "$rc" != "0" ]; then
    fail "scan head-pinned: exit $rc; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'comments/1301/reactions' "$(posts_file "$dir")" 2>/dev/null; then
    fail "scan head-pinned: did not react on the current-HEAD finding 1301; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  elif grep -q 'comments/1302/reactions' "$(posts_file "$dir")" 2>/dev/null \
    || [ "$(jq -r '[.skipped[] | select(.comment_id==1302)] | length' "$dir/out.json")" != "0" ]; then
    fail "scan head-pinned: the unnamed stale finding 1302 surfaced; out=$(cat "$dir/out.json")"
  elif ! grep -q 'gh api -X POST repos/owner/repo/pulls/comments/1300/reactions -f content=+1' "$(posts_file "$dir")" 2>/dev/null; then
    fail "scan head-pinned: named stale 1300 not fetched by id and reacted on (#2565); posts=$(cat "$(posts_file "$dir")" 2>/dev/null) stderr=$(cat "$dir/err.log")"
  elif [ "$(jq -r '[.recorded[] | select(.comment_id==1300 and .priority=="P1" and .location=="pull_request_review_comment" and .action=="posted")] | length' "$dir/out.json")" != "1" ]; then
    fail "scan head-pinned: named stale 1300 not recorded with its badge and location; out=$(cat "$dir/out.json")"
  elif [ "$(jq -r '[.skipped[] | select(.why=="not-found")] | length' "$dir/out.json")" != "0" ]; then
    fail "scan head-pinned: a named finding on this PR was reported not-found; out=$(cat "$dir/out.json")"
  else
    pass "scan picks up only the current-HEAD latest-round finding; a named earlier-round finding is fetched by id (#2565)"
  fi
}

test_scan_named_offhead_rejections() {
  # #2565 boundary: another PR's comment, a non-bot comment and a 404 stay
  # not-found with no reaction; a failed direct read exits 3 and posts nothing.
  local dir rc
  dir=$(make_case "scan-named-rejections")
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "api" ] || { echo "unexpected gh: \$*" >&2; exit 9; }
shift
[ "\${1:-}" = "--paginate" ] && shift
ep=\${1:-}
bot='chatgpt-codex-connector[bot]'
case "\$ep" in
  repos/owner/repo/pulls/999) printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/pulls/999/reviews) printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments) printf '[]\n' ;;
  repos/owner/repo/pulls/comments/1310)
    printf '{"id":1310,"user":{"login":"%s"},"pull_request_url":"https://api.github.com/repos/owner/repo/pulls/998","path":"a","line":1,"body":"![P1 Badge] other PR. $SOLICIT"}\n' "\$bot" ;;
  repos/owner/repo/pulls/comments/1311)
    printf '{"id":1311,"user":{"login":"somebody-else"},"pull_request_url":"https://api.github.com/repos/owner/repo/pulls/999","path":"b","line":1,"body":"![P1 Badge] human. $SOLICIT"}\n' ;;
  repos/owner/repo/pulls/comments/1399)
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  repos/owner/repo/pulls/comments/1300)
    echo "error connecting to api.github.com" >&2; exit 1 ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: \$ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1310=fixed --verdict 1311=fixed --verdict 1399=fixed)
  if [ "$rc" != "0" ]; then
    fail "named rejections: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ -s "$(posts_file "$dir")" ]; then
    fail "named rejections: a rejected id was reacted on; posts=$(cat "$(posts_file "$dir")")"
  elif [ "$(jq -r '[.skipped[] | select(.why=="not-found") | .comment_id] | sort' "$dir/out.json" | jq -c .)" != "[1310,1311,1399]" ]; then
    fail "named rejections: expected 1310, 1311 and 1399 not-found; out=$(cat "$dir/out.json")"
  else
    pass "a named id on another PR, by a non-bot author, or missing stays not-found with no reaction (#2565)"
  fi

  rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1300=fixed)
  if [ "$rc" != "3" ]; then
    fail "named transport failure: exit $rc, expected 3; stderr=$(cat "$dir/err.log")"
  elif [ -s "$(posts_file "$dir")" ]; then
    fail "named transport failure: reacted despite the failed read"
  else
    pass "a failed direct read of a named finding exits 3 and posts nothing (#2565)"
  fi
}

test_issue_comment_endpoint_selected_by_location() {
  local dir rc
  dir=$(make_case "issue-comment-endpoint")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": null, "line": null, "priority": "P1", "comment_id": 1401,
    "location": "issue_comment", "body": "PR-level finding.\n\n$SOLICIT" }
] }
EOF
  rc=$(run_case "$dir" -- 999 owner/repo --findings-json findings.json --verdict 1401=fixed)

  if [ "$rc" != "0" ]; then
    fail "issue-comment endpoint: exit $rc; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'gh api -X POST repos/owner/repo/issues/comments/1401/reactions -f content=+1' "$(posts_file "$dir")"; then
    fail "issue-comment endpoint: did not POST to the issues/comments reactions endpoint; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  else
    pass "location=issue_comment routes the reaction to the issues/comments endpoint"
  fi
}

test_findings_from_stdin() {
  local dir rc
  dir=$(make_case "stdin-findings")
  write_gh_readonly "$dir"
  # Bare array (not the full request-script object) on stdin. The body uses
  # an escaped \n (literal backslash-n) so the piped JSON stays valid — a
  # real newline in a JSON string is an unescaped control char.
  local rc2=0
  cat >"$dir/findings-stdin.json" <<EOF
[{"path":"x","line":1,"priority":"P1","comment_id":1501,"body":"real.\\n\\n$SOLICIT"}]
EOF
  (
    cd "$dir"
    cat findings-stdin.json \
      | PATH="$dir/bin:$PATH" GH_TOKEN=test-token CRF_STATE="$dir/state" \
        CODEX_FEEDBACK_LEDGER="$dir/state/ledger.jsonl" \
        GH_AS_REVIEWER_IDENTITY=nathanpayne-claude \
        "$dir/scripts/codex-record-feedback.sh" 999 owner/repo --findings-json - --verdict 1501=fixed \
        >"$dir/out.json" 2>"$dir/err.log"
  ) || rc2=$?
  rc=$rc2

  if [ "$rc" != "0" ]; then
    fail "stdin findings: exit $rc; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'comments/1501/reactions' "$(posts_file "$dir")" 2>/dev/null; then
    fail "stdin findings: did not react on the stdin-supplied finding"
  else
    pass "findings array accepted from stdin (bare array, request-script shape tolerant)"
  fi
}

test_post_failure_exits_1_and_skips_ledger() {
  local dir rc
  dir=$(make_case "post-failure")
  write_gh_readonly "$dir"
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 1601, "body": "real.\n\n$SOLICIT" }
] }
EOF
  local rc3=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token CRF_STATE="$dir/state" \
      CRF_REVIEWER_FAIL=1 \
      CODEX_FEEDBACK_LEDGER="$dir/state/ledger.jsonl" \
      GH_AS_REVIEWER_IDENTITY=nathanpayne-claude \
      "$dir/scripts/codex-record-feedback.sh" 999 owner/repo --findings-json findings.json --verdict 1601=fixed \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc3=$?
  rc=$rc3

  if [ "$rc" != "1" ]; then
    fail "post-failure: exit $rc, expected 1; stderr=$(cat "$dir/err.log")"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "post_failed" ]; then
    fail "post-failure: action was $(jq -r '.recorded[0].action' "$dir/out.json"), expected post_failed"
  elif [ "$(ledger_lines "$dir")" != "0" ]; then
    fail "post-failure: a failed POST still wrote a ledger row ($(ledger_lines "$dir") lines)"
  else
    pass "a failed reaction POST exits 1 and does not write a recorded ledger row"
  fi
}

# Regression for the ambient-GH_TOKEN bridge: a fresh shell that follows the
# documented `GH_TOKEN=<reviewer PAT> ...` path with NO OP_PREFLIGHT_REVIEWER_PAT
# and NO stored `gh auth token --user <reviewer>` must still POST the reaction
# under the reviewer identity. The reaction WRITE travels the REAL
# gh-as-reviewer.sh -> gh-token-resolver.sh -> identity-check.sh chain (a stubbed
# wrapper would mask the bug). Attribution is asserted by the gh stub: it returns
# the reviewer login from `api user` ONLY when the presented token is the bridged
# ambient PAT, so a green write proves the verified byline is the reviewer.
test_ambient_gh_token_bridges_to_reviewer_write() {
  local dir rc
  dir=$(make_real_wrapper_case "ambient-token-bridge")

  local REVIEWER_PAT="ghp_reviewer-pat-sentinel-487"
  # gh stub: serves reaction GET ([]), the identity-check `api user` probe
  # (reviewer login ONLY for the bridged PAT), and the reaction POST; and FAILS
  # `gh auth token --user` so the bridge is the only viable reviewer-token source.
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "auth" ] && [ "\${2:-}" = "token" ]; then
  # No stored token for any identity in this fresh-shell scenario.
  echo "no stored token" >&2
  exit 1
fi
[ "\${1:-}" = "api" ] || { echo "unexpected gh: \$*" >&2; exit 9; }
shift
if [ "\${1:-}" = "user" ]; then
  # identity-check.sh --expect-token-identity probe. The byline is whatever
  # token signs this call; only the bridged reviewer PAT resolves to the
  # reviewer login. Any other token verifies as a non-reviewer and fails closed.
  if [ "\${GH_TOKEN:-}" = "$REVIEWER_PAT" ]; then
    printf 'nathanpayne-claude\n'
  else
    printf 'somebody-else\n'
  fi
  exit 0
fi
[ "\${1:-}" = "--paginate" ] && shift
case "\${1:-}" in
  -X)
    # Reaction POST: record the endpoint + token identity that signed it.
    shift
    [ "\${1:-}" = "POST" ] && shift
    printf '%s\n' "\$*" >>"$dir/state/posts"
    printf '%s\n' "\${GH_TOKEN:-}" >>"$dir/state/write-token"
    exit 0
    ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: \${1:-}" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 1701, "body": "real.\n\n$SOLICIT" }
] }
EOF

  # Ambient GH_TOKEN ONLY — no OP_PREFLIGHT_REVIEWER_PAT, no MERGEPATH_AGENT.
  local rc4=0
  (
    cd "$dir"
    env -u OP_PREFLIGHT_REVIEWER_PAT -u OP_PREFLIGHT_AGENT -u MERGEPATH_AGENT \
      PATH="$dir/bin:$PATH" \
      GH_TOKEN="$REVIEWER_PAT" \
      CODEX_FEEDBACK_LEDGER="$dir/state/ledger.jsonl" \
      GH_AS_REVIEWER_IDENTITY="nathanpayne-claude" \
      "$dir/scripts/codex-record-feedback.sh" 999 owner/repo --findings-json findings.json --verdict 1701=fixed \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc4=$?
  rc=$rc4

  if [ "$rc" != "0" ]; then
    fail "ambient-bridge: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'repos/owner/repo/pulls/comments/1701/reactions -f content=+1' "$dir/state/posts" 2>/dev/null; then
    fail "ambient-bridge: reaction not POSTed via the real wrapper; posts=$(cat "$dir/state/posts" 2>/dev/null), stderr=$(cat "$dir/err.log")"
  elif [ "$(head -1 "$dir/state/write-token" 2>/dev/null)" != "$REVIEWER_PAT" ]; then
    fail "ambient-bridge: write did not run under the bridged reviewer PAT (token=$(head -1 "$dir/state/write-token" 2>/dev/null))"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "posted" ]; then
    fail "ambient-bridge: action was $(jq -r '.recorded[0].action' "$dir/out.json" 2>/dev/null), expected posted"
  else
    pass "ambient GH_TOKEN bridges to the reviewer write path and posts under the verified reviewer identity"
  fi
}

# Companion guard: the bridge must NOT clobber an explicit OP_PREFLIGHT_REVIEWER_PAT.
# When the cached reviewer PAT is present it stays the resolved write token even if
# ambient GH_TOKEN differs (ambient is only a fallback when no other source exists).
test_explicit_reviewer_pat_not_clobbered_by_ambient() {
  local dir rc
  dir=$(make_real_wrapper_case "explicit-pat-wins")

  local CACHED_PAT="ghp_cached-reviewer-pat-487"
  local AMBIENT_TOKEN="ambient-read-token-487"
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "auth" ] && [ "\${2:-}" = "token" ]; then
  echo "no stored token" >&2
  exit 1
fi
[ "\${1:-}" = "api" ] || { echo "unexpected gh: \$*" >&2; exit 9; }
shift
if [ "\${1:-}" = "user" ]; then
  # Only the CACHED reviewer PAT verifies as the reviewer.
  if [ "\${GH_TOKEN:-}" = "$CACHED_PAT" ]; then
    printf 'nathanpayne-claude\n'
  else
    printf 'somebody-else\n'
  fi
  exit 0
fi
[ "\${1:-}" = "--paginate" ] && shift
case "\${1:-}" in
  -X)
    shift
    [ "\${1:-}" = "POST" ] && shift
    printf '%s\n' "\$*" >>"$dir/state/posts"
    printf '%s\n' "\${GH_TOKEN:-}" >>"$dir/state/write-token"
    exit 0
    ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: \${1:-}" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "priority": "P1", "comment_id": 1801, "body": "real.\n\n$SOLICIT" }
] }
EOF

  local rc5=0
  (
    cd "$dir"
    env -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT \
      PATH="$dir/bin:$PATH" \
      GH_TOKEN="$AMBIENT_TOKEN" \
      OP_PREFLIGHT_REVIEWER_PAT="$CACHED_PAT" \
      CODEX_FEEDBACK_LEDGER="$dir/state/ledger.jsonl" \
      GH_AS_REVIEWER_IDENTITY="nathanpayne-claude" \
      "$dir/scripts/codex-record-feedback.sh" 999 owner/repo --findings-json findings.json --verdict 1801=fixed \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc5=$?
  rc=$rc5

  if [ "$rc" != "0" ]; then
    fail "explicit-pat: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$(head -1 "$dir/state/write-token" 2>/dev/null)" != "$CACHED_PAT" ]; then
    fail "explicit-pat: write ran under '$(head -1 "$dir/state/write-token" 2>/dev/null)', expected the cached PAT (ambient must not clobber)"
  else
    pass "an explicit OP_PREFLIGHT_REVIEWER_PAT is preferred; ambient GH_TOKEN does not clobber it"
  fi
}

# #2913: --scan reads codex.bot_login from the parsed policy. The earlier
# line-oriented awk reader matched only an unquoted, block-style `bot_login:`
# key, so a quoted key or a flow mapping read as unset and the scan looked for
# the default login, missing every finding of a custom bot.
LEGACY_RECORD_BOT_LOGIN_AWK='
  /^codex:/ {in_block=1; next}
  in_block && /^[^[:space:]#]/ {in_block=0}
  in_block && $1 == field":" {
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
    gsub(/^["\047]/, "", $0)
    gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
    gsub(/[[:space:]]*#.*$/, "", $0)
    sub(/[[:space:]]+$/, "", $0)
    print
    exit
  }
'
write_gh_custom_bot() {
  local dir=$1
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "api" ] || { echo "unexpected gh: \$*" >&2; exit 9; }
shift
[ "\${1:-}" = "--paginate" ] && shift
ep=\${1:-}
bot='custom-codex[bot]'
case "\$ep" in
  repos/owner/repo/pulls/999) printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/pulls/999/reviews)
    printf '[{"id":300,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-02T00:00:00Z","commit_id":"head-sha"}]\n' "\$bot" ;;
  repos/owner/repo/pulls/999/comments)
    printf '[{"id":1501,"user":{"login":"%s"},"pull_request_review_id":300,"path":"a","line":1,"body":"![P1 Badge] custom bot. $SOLICIT"}]\n' "\$bot" ;;
  repos/owner/repo/pulls/comments/1501)
    printf '{"id":1501,"user":{"login":"%s"},"pull_request_url":"https://api.github.com/repos/owner/repo/pulls/999","pull_request_review_id":300,"commit_id":"head-sha","path":"a","line":1,"body":"![P1 Badge] custom bot. $SOLICIT"}\n' "\$bot" ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: \$ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
}

test_scan_reads_bot_login_from_parsed_policy() {
  local label yaml dir rc legacy n=0
  while IFS='|' read -r label yaml; do
    n=$((n + 1))
    dir=$(make_case "scan-bot-login-$n")
    printf '%b\n' "$yaml" >"$dir/.github/review-policy.yml"
    write_gh_custom_bot "$dir"
    rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1501=fixed)
    if [ "$rc" = "0" ] && grep -q 'comments/1501/reactions' "$(posts_file "$dir")" 2>/dev/null; then
      pass "#2913 $label: the scan finds the custom bot's finding"
    else
      fail "#2913 $label: the scan missed the custom bot (rc=$rc); stderr=$(cat "$dir/err.log") posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
    fi
    # Mutation self-check: the legacy reader misreads this spelling, so the
    # case above would fail against it.
    legacy=$(awk -v field=bot_login "$LEGACY_RECORD_BOT_LOGIN_AWK" "$dir/.github/review-policy.yml")
    if [ "$legacy" != "custom-codex[bot]" ]; then
      pass "#2913 mutation $label: the legacy awk reader misreads bot_login ('$legacy')"
    else
      fail "#2913 mutation $label: the legacy awk reader already reads bot_login; the case proves nothing"
    fi
  done <<'CASES'
quoted key|codex:\n  "bot_login": "custom-codex[bot]"
single-quoted key|codex:\n  'bot_login': custom-codex[bot]
flow mapping|codex: {bot_login: "custom-codex[bot]"}
flow mapping, quoted key|codex: {"enabled": true, "bot_login": "custom-codex[bot]"}
CASES

  # A policy that cannot be parsed, or a bot_login of the wrong kind, refuses
  # before any read or reaction instead of scanning for the default login.
  while IFS='|' read -r label yaml; do
    n=$((n + 1))
    dir=$(make_case "scan-bot-login-$n")
    printf '%b\n' "$yaml" >"$dir/.github/review-policy.yml"
    write_gh_custom_bot "$dir"
    rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1501=fixed)
    if [ "$rc" = "3" ] && [ ! -s "$(posts_file "$dir")" ] && grep -q 'codex.bot_login' "$dir/err.log"; then
      pass "#2913 $label: --scan refuses (exit 3) and posts nothing"
    else
      fail "#2913 $label: expected exit 3 and no post (rc=$rc); stderr=$(cat "$dir/err.log")"
    fi
  done <<'CASES'
unparseable policy|codex:\n  bot_login: [unclosed
list bot_login|codex:\n  bot_login: [custom-codex]
empty bot_login|codex: {bot_login: ""}
CASES

  # No policy file keeps the default login, as before.
  dir=$(make_case "scan-bot-login-absent")
  rm -f "$dir/.github/review-policy.yml"
  write_gh_custom_bot "$dir"
  rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1501=fixed)
  if [ "$rc" = "0" ] && [ ! -s "$(posts_file "$dir")" ] \
     && [ "$(jq -c '[.skipped[] | select(.why=="not-found") | .comment_id]' "$dir/out.json")" = "[1501]" ]; then
    pass "#2913: with no policy file the scan keeps the default login (the custom bot's finding is not-found)"
  else
    fail "#2913: absent policy changed behaviour (rc=$rc); stderr=$(cat "$dir/err.log")"
  fi
}


test_string_id_coerced_no_double_report
test_fixed_reacts_plus1_via_reviewer
test_rebuttal_reacts_minus1
test_no_solicitation_is_never_reacted
test_nbsp_solicitation_is_matched
test_solicits_but_no_verdict_is_skipped
test_idempotent_existing_reviewer_reaction
test_dry_run_posts_nothing
test_unrecognized_verdict_fails_before_any_post
test_scan_is_head_pinned_to_latest_round
test_scan_named_offhead_rejections
test_issue_comment_endpoint_selected_by_location
test_findings_from_stdin
test_post_failure_exits_1_and_skips_ledger
test_ambient_gh_token_bridges_to_reviewer_write
test_explicit_reviewer_pat_not_clobbered_by_ambient
test_scan_reads_bot_login_from_parsed_policy

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
