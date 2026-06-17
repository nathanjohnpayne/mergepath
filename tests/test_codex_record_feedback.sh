#!/usr/bin/env bash
# Regression coverage for scripts/codex-record-feedback.sh (#487).
#
# Runs the real script from a temp repo with a stubbed gh + a stubbed
# gh-as-reviewer.sh so the tests exercise the production solicitation-gate,
# verdict-mapping, idempotency, HEAD-pinned scan, and ledger flow without
# touching GitHub. The reaction WRITE path is asserted to go through
# gh-as-reviewer.sh under the reviewer identity (never a bare gh write).

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
  cp "$ROOT/scripts/gh-as-reviewer.sh" "$dir/scripts/gh-as-reviewer.sh"
  chmod +x "$dir/scripts/gh-as-reviewer.sh"
  cp "$ROOT/scripts/identity-check.sh" "$dir/scripts/identity-check.sh"
  chmod +x "$dir/scripts/identity-check.sh"

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
  # gh stub modeling: HEAD=head-sha; a STALE review (old, not HEAD) carries a
  # P1 finding, and the CURRENT-HEAD latest review (id 200) carries 1301. The
  # scan must pick up ONLY 1301 (latest round on HEAD), never the stale one.
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
    printf '[{"id":1300,"user":{"login":"%s"},"pull_request_review_id":100,"path":"old","line":1,"body":"STALE P1. $SOLICIT"},{"id":1301,"user":{"login":"%s"},"pull_request_review_id":200,"path":"new","line":2,"body":"![P1 Badge] current. $SOLICIT"}]\n' "\$bot" "\$bot" ;;
  repos/owner/repo/pulls/comments/*/reactions) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: \$ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  rc=$(run_case "$dir" -- 999 owner/repo --scan --verdict 1300=fixed --verdict 1301=fixed)

  if [ "$rc" != "0" ]; then
    fail "scan head-pinned: exit $rc; stderr=$(cat "$dir/err.log")"
  elif grep -q 'comments/1300/reactions' "$(posts_file "$dir")" 2>/dev/null; then
    fail "scan head-pinned: reacted on the STALE (non-HEAD) finding 1300"
  elif ! grep -q 'comments/1301/reactions' "$(posts_file "$dir")" 2>/dev/null; then
    fail "scan head-pinned: did not react on the current-HEAD finding 1301; posts=$(cat "$(posts_file "$dir")" 2>/dev/null)"
  elif [ "$(jq -r '[.skipped[] | select(.comment_id==1300 and .why=="not-found")] | length' "$dir/out.json")" != "1" ]; then
    fail "scan head-pinned: verdict for stale 1300 should be reported not-found"
  else
    pass "scan picks up only the current-HEAD latest-round finding (HEAD-pinned)"
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

  local REVIEWER_PAT="reviewer-pat-sentinel-487"
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

  local CACHED_PAT="cached-reviewer-pat-487"
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

test_fixed_reacts_plus1_via_reviewer
test_rebuttal_reacts_minus1
test_no_solicitation_is_never_reacted
test_solicits_but_no_verdict_is_skipped
test_idempotent_existing_reviewer_reaction
test_dry_run_posts_nothing
test_unrecognized_verdict_fails_before_any_post
test_scan_is_head_pinned_to_latest_round
test_issue_comment_endpoint_selected_by_location
test_findings_from_stdin
test_post_failure_exits_1_and_skips_ledger
test_ambient_gh_token_bridges_to_reviewer_write
test_explicit_reviewer_pat_not_clobbered_by_ambient

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
