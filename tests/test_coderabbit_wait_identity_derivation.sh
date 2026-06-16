#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's token-derived expected
# reviewer identity (#438).
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep and a
# stubbed identity-check.sh. The write path exercised is the timeout
# status probe (the first reviewer-token write the helper can reach
# deterministically). Asserts:
#   1. With NO identity envs set, the expected identity is derived from
#      the token's login when that login is in available_reviewers —
#      not hard-defaulted to nathanpayne-claude.
#   2. A token login NOT in available_reviewers falls back to the
#      static default (fail-closed: verification then fails and no
#      write is posted).
#   3. An explicit GH_AS_REVIEWER_IDENTITY wins and no derivation
#      lookup (`gh api user`) is made.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-identity.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_case() {
  local name=$1
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  cat >"$dir/.github/review-policy.yml" <<'EOF'
available_reviewers:
  - nathanpayne-claude  # default agent
  - 'nathanpayne-cursor'
  - "nathanpayne-codex" # quoted + inline comment

coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: 1
  status_probe_enabled: true
  status_probe_wait_seconds: 1
  max_rate_limit_retries: 2
  wallclock_freshness_window_seconds: 999999999
  trust_status_context_for_clearance: false
EOF

  # identity-check stub: records the expected identity it was asked to
  # verify, succeeds iff that identity matches the stub token's login.
  cat >"$dir/scripts/identity-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
[ "${1:-}" = "--expect-token-identity" ] || exit 2
printf '%s\n' "${2:-}" >>"$state_dir/identity-args"
[ "${2:-}" = "${CODERABBIT_TEST_TOKEN_LOGIN:?}" ] || exit 1
exit 0
EOF
  chmod +x "$dir/scripts/identity-check.sh"

  cat >"$dir/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  cat "$clock_file"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$dir/bin/date"

  cat >"$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi
duration=${1:-0}
case "$duration" in
  *.*) duration=${duration%%.*} ;;
esac
current=$(cat "$clock_file")
printf '%s\n' $((current + duration)) >"$clock_file"
EOF
  chmod +x "$dir/bin/sleep"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODERABBIT_TEST_STATE_DIR:?}
head_time='2026-06-04T00:00:00Z'

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 99
fi
shift

method="GET"
if [ "${1:-}" = "--method" ]; then
  method=${2:-}
  shift 2
fi
if [ "${1:-}" = "--paginate" ]; then
  shift
fi

endpoint=${1:-}
shift || true

if [ "$method" = "POST" ]; then
  case "$endpoint" in
    repos/owner/repo/issues/999/comments)
      count=0
      if [ -f "$state_dir/post-count" ]; then
        count=$(cat "$state_dir/post-count")
      fi
      count=$((count + 1))
      printf '%s\n' "$count" >"$state_dir/post-count"
      printf '{"id":900%s,"created_at":"%s","body":"probe"}\n' "$count" "$head_time"
      ;;
    *)
      echo "unexpected gh api POST endpoint: $endpoint" >&2
      exit 99
      ;;
  esac
  exit 0
fi

case "$endpoint" in
  user)
    count=0
    if [ -f "$state_dir/api-user-count" ]; then
      count=$(cat "$state_dir/api-user-count")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$state_dir/api-user-count"
    printf '%s\n' "${CODERABBIT_TEST_TOKEN_LOGIN:?}"
    ;;
  repos/owner/repo/pulls/999)
    printf '{"head":{"sha":"head-sha"}}\n'
    ;;
  repos/owner/repo/commits/head-sha)
    if [ "${1:-}" = "--jq" ]; then
      printf '%s\n' "$head_time"
    else
      printf '{"commit":{"committer":{"date":"%s"}}}\n' "$head_time"
    fi
    ;;
  repos/owner/repo/issues/999/timeline)
    printf '[]\n'
    ;;
  repos/owner/repo/pulls/999/reviews)
    printf '[]\n'
    ;;
  repos/owner/repo/pulls/999/comments)
    printf '[]\n'
    ;;
  repos/owner/repo/issues/999/comments)
    printf '[]\n'
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1
  local token_login=$2
  local explicit_identity=${3:-}
  local rc=0

  (
    cd "$dir"
    env_args=(
      PATH="$dir/bin:$PATH"
      GH_TOKEN=test-token
      CODERABBIT_TEST_STATE_DIR="$dir/state"
      CODERABBIT_TEST_TOKEN_LOGIN="$token_login"
    )
    if [ -n "$explicit_identity" ]; then
      env_args+=(GH_AS_REVIEWER_IDENTITY="$explicit_identity")
    fi
    env -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT -u GH_AS_REVIEWER_IDENTITY \
      "${env_args[@]}" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?

  printf '%s\n' "$rc"
}

state_file() {
  local dir=$1 name=$2
  if [ -f "$dir/state/$name" ]; then
    cat "$dir/state/$name"
  else
    printf ''
  fi
}

test_derives_identity_from_allow_listed_token() {
  local dir rc args posts
  dir=$(make_case "derived-cursor")
  rc=$(run_case "$dir" nathanpayne-cursor)
  args=$(state_file "$dir" identity-args)
  posts=$(state_file "$dir" post-count)

  if [ "$args" != "nathanpayne-cursor" ]; then
    fail "derived identity: identity-check expected args 'nathanpayne-cursor', got '$args'; stderr=$(cat "$dir/err.log")"
  elif [ "${posts:-0}" -lt 1 ]; then
    fail "derived identity: probe write was not posted (post-count='$posts'); stderr=$(cat "$dir/err.log")"
  elif ! grep -q "derived expected reviewer identity 'nathanpayne-cursor'" "$dir/err.log"; then
    fail "derived identity: missing derivation log line; stderr=$(cat "$dir/err.log")"
  else
    pass "expected identity derived from allow-listed token login (rc=$rc)"
  fi
}

test_non_allow_listed_token_fails_closed() {
  local dir rc args posts
  dir=$(make_case "mallory")
  rc=$(run_case "$dir" mallory-user)
  args=$(state_file "$dir" identity-args)
  posts=$(state_file "$dir" post-count)

  if [ "$args" != "nathanpayne-claude" ]; then
    fail "fail-closed: identity-check expected args 'nathanpayne-claude' (static default), got '$args'; stderr=$(cat "$dir/err.log")"
  elif [ -n "$posts" ]; then
    fail "fail-closed: a write was posted ($posts) despite identity verification failing"
  else
    pass "non-allow-listed token falls back to static default and posts nothing (rc=$rc)"
  fi
}

test_explicit_identity_skips_derivation() {
  local dir rc args user_calls
  dir=$(make_case "explicit-codex")
  rc=$(run_case "$dir" nathanpayne-codex nathanpayne-codex)
  args=$(state_file "$dir" identity-args)
  user_calls=$(state_file "$dir" api-user-count)

  if [ "$args" != "nathanpayne-codex" ]; then
    fail "explicit identity: identity-check expected args 'nathanpayne-codex', got '$args'; stderr=$(cat "$dir/err.log")"
  elif [ -n "$user_calls" ]; then
    fail "explicit identity: derivation lookup ran ($user_calls api-user calls) despite explicit GH_AS_REVIEWER_IDENTITY"
  else
    pass "explicit GH_AS_REVIEWER_IDENTITY wins; no derivation lookup (rc=$rc)"
  fi
}

test_derives_identity_from_quoted_commented_entry() {
  local dir rc args
  dir=$(make_case "derived-codex-quoted-commented")
  rc=$(run_case "$dir" nathanpayne-codex)
  args=$(state_file "$dir" identity-args)

  if [ "$args" != "nathanpayne-codex" ]; then
    fail "quoted+commented entry: identity-check expected args 'nathanpayne-codex', got '$args'; stderr=$(cat "$dir/err.log")"
  elif ! grep -q "derived expected reviewer identity 'nathanpayne-codex'" "$dir/err.log"; then
    fail "quoted+commented entry: missing derivation log line; stderr=$(cat "$dir/err.log")"
  else
    pass "allow-list entry with quotes AND inline comment is normalized for derivation (rc=$rc)"
  fi
}

# #453: the shared scripts/lib/reviewers-helpers.sh parses the allow-list
# with the strongest normalization (dash + inline comment + BOTH quote
# styles + whitespace), so coderabbit-wait.sh and codex-review-check.sh stay
# in lockstep and a quoted/commented reviewer is never silently dropped from
# the fail-closed token allow-list. Direct unit test of the shared lib.
test_453_shared_reviewers_helper() {
  local lib="$ROOT/scripts/lib/reviewers-helpers.sh"
  if [ ! -r "$lib" ]; then fail "#453: missing $lib"; return; fi
  local cfg; cfg="$(mktemp)"
  # `nathanpayne-cursor` is double-quoted WITH trailing padding and NO inline
  # comment — the Codex P2 on #463 shape (the closing quote must be stripped
  # despite the trailing spaces). Built with printf so the trailing spaces are
  # explicit and survive editor/linter whitespace-trimming. `nathanpayne-codex`
  # is single-quoted with a trailing comment + padding.
  {
    printf 'available_reviewers:\n'
    printf '  - nathanpayne-claude\n'
    printf '  - "nathanpayne-cursor"   \n'
    printf "  - 'nathanpayne-codex'   # single quotes + trailing comment + padding\n"
    printf 'default_external_reviewer: nathanpayne-codex\n'
  } >"$cfg"
  ( # shellcheck source=../scripts/lib/reviewers-helpers.sh
    . "$lib"
    out=$(read_available_reviewers "$cfg" | tr '\n' ',')
    [ "$out" = "nathanpayne-claude,nathanpayne-cursor,nathanpayne-codex," ] \
      || { echo "parse mismatch: [$out]" >&2; exit 1; }
    login_is_available_reviewer "nathanpayne-cursor" "$cfg" \
      || { echo "double-quoted member not recognized" >&2; exit 1; }
    login_is_available_reviewer "nathanpayne-codex" "$cfg" \
      || { echo "single-quoted+commented member not recognized" >&2; exit 1; }
    ! login_is_available_reviewer "default_external_reviewer" "$cfg" \
      || { echo "non-member (out-of-block key) wrongly matched" >&2; exit 1; }
    ! login_is_available_reviewer "" "$cfg" \
      || { echo "empty login wrongly matched" >&2; exit 1; }
  )
  local rc=$?
  rm -f "$cfg"
  if [ "$rc" = 0 ]; then
    pass "#453: shared reviewers-helpers parses quoted/commented/whitespace entries and matches members fail-closed"
  else
    fail "#453: shared reviewers-helpers parsing/membership regressed (rc=$rc)"
  fi
}

test_453_shared_reviewers_helper
test_derives_identity_from_allow_listed_token
test_derives_identity_from_quoted_commented_entry
test_non_allow_listed_token_fails_closed
test_explicit_identity_skips_derivation

echo ""
echo "test_coderabbit_wait_identity_derivation: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
