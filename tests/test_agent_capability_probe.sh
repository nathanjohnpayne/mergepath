#!/usr/bin/env bash
# tests/test_agent_capability_probe.sh
#
# Unit tests for scripts/agent-capability-probe.sh and
# scripts/lib/credential-class.sh (#1057).
#
# Strategy: copy the probe and its runtime closure into a scratch git repo
# whose origin is a local bare repo (so the dry-run push is real but
# offline), and PATH-shim `gh` with a stub that answers per GH_TOKEN:
#
#   ghp_author      nathanjohnpayne, type User, X-OAuth-Scopes present
#   ghp_reviewer    nathanpayne-claude, type User
#   ghs_author      nathanjohnpayne, type User (an app installation token
#                   that nonetheless reads as the user: the class must refuse)
#   proxy-injected  nathanjohnpayne, type User, NO scopes header; repo read
#                   200, GraphQL 403 with the proxy's ceiling text, any other
#                   repo 403 (the #1057 Claude cloud measurement)
#   anything else   401
#
# `curl` is shimmed too, so a missing gh can never fall through to the real
# network. The stub records every GH_TOKEN it sees in a file the tests grep
# the probe's OUTPUT against: no token value may ever be printed.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_SRC="$ROOT/scripts/agent-capability-probe.sh"
[ -x "$PROBE_SRC" ] || { echo "missing or non-executable $PROBE_SRC" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-capability-probe-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- fixture repo ---------------------------------------------------------
FIX="$WORKDIR/repo"
mkdir -p "$FIX/scripts/lib" "$FIX/.github"
cp "$PROBE_SRC" "$FIX/scripts/"
cp "$ROOT/scripts/lib/credential-class.sh" "$ROOT/scripts/lib/gh-token-resolver.sh" "$FIX/scripts/lib/"
cp "$ROOT/scripts/identity-check.sh" "$FIX/scripts/"
printf 'author_identity: nathanjohnpayne\n' >"$FIX/.github/review-policy.yml"
git init -q --bare "$WORKDIR/origin.git"
(
  cd "$FIX"
  git init -q
  git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init
  git remote add origin "$WORKDIR/origin.git"
)
PROBE="$FIX/scripts/agent-capability-probe.sh"

# --- stubs ----------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
SEEN_TOKENS="$WORKDIR/seen-tokens"
: >"$SEEN_TOKENS"
cat >"$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
SEEN="$SEEN_TOKENS"
STUB
cat >>"$STUB_DIR/gh" <<'STUB'
tok="${GH_TOKEN:-}"
[ -n "$tok" ] && printf '%s\n' "$tok" >>"$SEEN"
if [ "$1 $2" = "auth token" ]; then
  # gh auth token --user <login>: the keyring, controlled by STUB_KEYRING_<login>
  login="$4"
  var="STUB_KEYRING_$(printf '%s' "$login" | tr -c 'A-Za-z0-9\n' '_')"
  val="${!var:-}"
  [ -n "$val" ] || exit 1
  printf '%s\n' "$val"
  exit 0
fi
[ "$1" = "api" ] || exit 0
shift
include=0; jqexpr=""; path=""; method=GET
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i) include=1; shift ;;
    -X) method="$2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    -f) shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
login=""; type=User; scopes=""
case "$tok" in
  ghp_author) login=nathanjohnpayne; scopes="repo, workflow" ;;
  ghp_reviewer) login=nathanpayne-claude; scopes="repo" ;;
  ghs_author) login=nathanjohnpayne ;;
  proxy-injected) login=nathanjohnpayne ;;
esac
status=200; body=""
if [ -z "$login" ]; then
  status=401; body='{"message":"Bad credentials"}'
elif [ "$path" = "user" ]; then
  body="{\"login\":\"$login\",\"type\":\"$type\"}"
elif [ "$path" = "graphql" ]; then
  if [ "$tok" = "proxy-injected" ]; then
    status=403; body='{"message":"This GraphQL query is not enabled for this session. Use gh api repos/{owner}/{repo}/... instead."}'
  else
    body="{\"data\":{\"viewer\":{\"login\":\"$login\"}}}"
  fi
elif [ "$path" = "repos/$STUB_REPO" ]; then
  body='{"full_name":"x"}'
elif [ "$tok" = "proxy-injected" ]; then
  status=403; body='{"message":"repository not attached to this session"}'
else
  body='{"full_name":"y"}'
fi
if [ -n "$jqexpr" ]; then
  [ "$status" = 200 ] || exit 1
  printf '%s' "$body" | jq -r "$jqexpr"
  exit 0
fi
if [ "$include" = 1 ]; then
  printf 'HTTP/2.0 %s X\r\n' "$status"
  [ -n "$scopes" ] && printf 'X-Oauth-Scopes: %s\r\n' "$scopes"
  printf 'Content-Type: application/json\r\n\r\n'
fi
printf '%s\n' "$body"
[ "$status" = 200 ]
STUB
chmod +x "$STUB_DIR/gh"
cat >"$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "FATAL: probe reached curl" >&2
exit 7
STUB
chmod +x "$STUB_DIR/curl"

# A PATH with every tool the probe needs EXCEPT gh (curl stays shimmed).
NOGH_DIR="$WORKDIR/nogh-bin"
mkdir -p "$NOGH_DIR"
for tool in bash jq git sed awk tr grep mktemp date cat rm mv mkdir chmod dirname basename env head tail sort printf; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$real" in /*) ln -sf "$real" "$NOGH_DIR/$tool" ;; esac
done
cp "$STUB_DIR/curl" "$NOGH_DIR/curl"
# git's own helpers (git-remote-*, ssh for push) resolve through PATH too.
for tool in ssh git-receive-pack git-upload-pack; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$real" in /*) ln -sf "$real" "$NOGH_DIR/$tool" ;; esac
done

# run_probe <env assignments...> -- <probe args...>
# Runs with a clean credential environment: only what the case passes in.
CACHE="$WORKDIR/cache"
run_probe() {
  local -a envs
  envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -u GH_TOKEN -u GITHUB_TOKEN -u OP_PREFLIGHT_AUTHOR_PAT -u OP_PREFLIGHT_REVIEWER_PAT \
    -u CLAUDE_CODE_REMOTE -u MERGEPATH_AGENT_SURFACE -u GITHUB_ACTIONS \
    -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT \
    -u CLAUDE_CODE_REMOTE_SESSION_ID \
    PATH="$STUB_DIR:$PATH" STUB_REPO="o/r" MERGEPATH_CAPABILITY_CACHE_DIR="$CACHE" \
    ${envs[@]+"${envs[@]}"} "$PROBE" --repo o/r "$@"
}

assert_no_token_leak() { # <label> <file...>
  local label="$1" f tok leaked=0
  shift
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    [ "$tok" = "proxy-injected" ] && continue  # a documented public placeholder, not a secret
    for f in "$@"; do
      if grep -qF -- "$tok" "$f"; then leaked=1; fi
    done
  done <"$SEEN_TOKENS"
  if [ "$leaked" -eq 0 ]; then pass "$label: no token value in output"; else fail "$label: a token value reached the output"; fi
}

cap() { jq -r --arg c "$2" '.capabilities[$c].granted' "$1"; }
reason() { jq -r --arg c "$2" '.capabilities[$c].reason' "$1"; }

# ---------------------------------------------------------------------------
# credential-class.sh (pure)
# ---------------------------------------------------------------------------
(
  # shellcheck source=../scripts/lib/credential-class.sh
  . "$ROOT/scripts/lib/credential-class.sh"
  printf 'HTTP/2.0 200 OK\nX-OAuth-Scopes: repo\n' >"$WORKDIR/scoped.headers"
  printf 'HTTP/2.0 200 OK\n' >"$WORKDIR/plain.headers"
  check() { # <expected> <token> [headers]
    local got
    got="$(credential_class "$2" "${3:-}")"
    if [ "$got" = "$1" ]; then echo "ok"; else echo "credential_class($2) = $got, expected $1"; fi
  }
  hex40="0123456789abcdef0123456789abcdef01234567"
  for line in \
    "user-held|ghp_x" "user-held|github_pat_x" "user-held|gho_x" "user-held|ghu_x" \
    "app-installed|ghs_x" "unidentifiable|ghr_x" "brokered|proxy-injected" "empty|" \
    "unidentifiable|opaque-sentinel" "unidentifiable|ghp_" \
    "user-held|$hex40|$WORKDIR/scoped.headers" "unidentifiable|$hex40|$WORKDIR/plain.headers" \
    "unidentifiable|$hex40" "unidentifiable|not-hex-but-scoped|$WORKDIR/scoped.headers"; do
    expected="${line%%|*}"; rest="${line#*|}"
    case "$rest" in *"|"*) tok="${rest%%|*}"; hdr="${rest#*|}" ;; *) tok="$rest"; hdr="" ;; esac
    check "$expected" "$tok" "$hdr"
  done
) >"$WORKDIR/class.out"
if ! grep -v '^ok$' "$WORKDIR/class.out" >/dev/null; then
  pass "credential_class: prefixes, placeholder, legacy-hex+scopes, and opaque strings classify as specified"
else
  fail "credential_class: $(grep -v '^ok$' "$WORKDIR/class.out" | tr '\n' ';')"
fi

# ---------------------------------------------------------------------------
# Local session with provisioned user-held PATs: everything granted.
# ---------------------------------------------------------------------------
set +e
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_AUTHOR_PAT=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- \
  >"$WORKDIR/local.json" 2>"$WORKDIR/local.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(jq -r .tier "$WORKDIR/local.json")" = "author-writes,reviewer-writes,graphql,cross-repo,push-multi-branch" ] \
   && [ "$(jq -r .surface "$WORKDIR/local.json")" = "local" ]; then
  pass "local + user-held PATs: every capability granted, tier lists all five"
else
  fail "local + user-held PATs: rc=$rc tier=$(jq -r .tier "$WORKDIR/local.json" 2>/dev/null) err=$(cat "$WORKDIR/local.err")"
fi
assert_no_token_leak "local" "$WORKDIR/local.json" "$WORKDIR/local.err"

# ---------------------------------------------------------------------------
# Claude cloud, placeholder only (the #1057 measurement): read-only.
# ---------------------------------------------------------------------------
set +e
run_probe CLAUDE_CODE_REMOTE=true GH_TOKEN=proxy-injected GITHUB_TOKEN=proxy-injected -- \
  >"$WORKDIR/cloud.json" 2>"$WORKDIR/cloud.err"
rc=$?
set -e
t="$(jq -r .tier "$WORKDIR/cloud.json" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$t" = "read-only" ] && [ "$(jq -r .surface "$WORKDIR/cloud.json")" = "claude-cloud" ]; then
  pass "claude-cloud + placeholder: tier read-only"
else
  fail "claude-cloud + placeholder: rc=$rc tier=$t err=$(cat "$WORKDIR/cloud.err")"
fi
# The gap-2 shape: the placeholder READS as the author, so login-only
# verification passes; the class check must still refuse it.
if [ "$(cap "$WORKDIR/cloud.json" author-writes)" = "false" ] \
   && [ "$(jq -r '.capabilities["author-writes"].credential_class' "$WORKDIR/cloud.json")" = "brokered" ] \
   && [ "$(jq -r '.capabilities["author-writes"].login' "$WORKDIR/cloud.json")" = "nathanjohnpayne" ]; then
  pass "claude-cloud + placeholder: author-writes refused although GET /user reads as the author (class brokered)"
else
  fail "claude-cloud + placeholder: author-writes $(jq -c '.capabilities["author-writes"]' "$WORKDIR/cloud.json")"
fi
if reason "$WORKDIR/cloud.json" graphql | grep -q 'proxy GraphQL ceiling'; then
  pass "claude-cloud: GraphQL refusal reported as the proxy ceiling"
else
  fail "claude-cloud: graphql reason = $(reason "$WORKDIR/cloud.json" graphql)"
fi
if [ "$(cap "$WORKDIR/cloud.json" cross-repo)" = "false" ] \
   && [ "$(cap "$WORKDIR/cloud.json" push-multi-branch)" = "false" ] \
   && [ "$(jq -r '.capabilities["push-multi-branch"].basis' "$WORKDIR/cloud.json")" = "documented" ]; then
  pass "claude-cloud: cross-repo refused, multi-branch push false from the documented restriction"
else
  fail "claude-cloud: cross-repo=$(cap "$WORKDIR/cloud.json" cross-repo) push=$(jq -c '.capabilities["push-multi-branch"]' "$WORKDIR/cloud.json")"
fi
if [ "$(jq -r .ambient_credential.class "$WORKDIR/cloud.json")" = "brokered" ]; then
  pass "claude-cloud: ambient credential classified brokered"
else
  fail "claude-cloud: ambient class = $(jq -r .ambient_credential.class "$WORKDIR/cloud.json")"
fi

# ---------------------------------------------------------------------------
# Claude cloud with PATs provisioned in the environment (#1057 item B).
# ---------------------------------------------------------------------------
set +e
run_probe CLAUDE_CODE_REMOTE=true GH_TOKEN=proxy-injected \
  OP_PREFLIGHT_AUTHOR_PAT=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- \
  >"$WORKDIR/cloudpat.json" 2>"$WORKDIR/cloudpat.err"
rc=$?
set -e
t="$(jq -r .tier "$WORKDIR/cloudpat.json" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$t" = "author-writes,reviewer-writes" ]; then
  pass "claude-cloud + provisioned PATs: author and reviewer writes granted, ceilings still refused"
else
  fail "claude-cloud + provisioned PATs: rc=$rc tier=$t"
fi
assert_no_token_leak "claude-cloud + PATs" "$WORKDIR/cloudpat.json" "$WORKDIR/cloudpat.err"

# ---------------------------------------------------------------------------
# An app installation token that reads as the user is still refused.
# ---------------------------------------------------------------------------
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghs_author -- >"$WORKDIR/app.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/app.json" author-writes)" = "false" ] \
   && [ "$(jq -r '.capabilities["author-writes"].credential_class' "$WORKDIR/app.json")" = "app-installed" ]; then
  pass "ghs_ token reading as the author: author-writes refused (class app-installed)"
else
  fail "ghs_ token: $(jq -c '.capabilities["author-writes"]' "$WORKDIR/app.json")"
fi

# ---------------------------------------------------------------------------
# Surface override and validation.
# ---------------------------------------------------------------------------
set +e
run_probe MERGEPATH_AGENT_SURFACE=codex-cloud CLAUDE_CODE_REMOTE=true -- --no-cache >"$WORKDIR/codex.json" 2>/dev/null
set -e
if [ "$(jq -r .surface "$WORKDIR/codex.json")" = "codex-cloud" ] && [ "$(jq -r .surface_source "$WORKDIR/codex.json")" = "MERGEPATH_AGENT_SURFACE" ]; then
  pass "MERGEPATH_AGENT_SURFACE overrides detection"
else
  fail "surface override: $(jq -c '{surface,surface_source}' "$WORKDIR/codex.json")"
fi
set +e
run_probe MERGEPATH_AGENT_SURFACE=moon -- >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then pass "invalid MERGEPATH_AGENT_SURFACE rejected (exit 1)"; else fail "invalid surface: exit $rc"; fi

# ---------------------------------------------------------------------------
# No gh on PATH: writes refused as gh-absent, and the probe never reaches
# the network through curl on its own.
# ---------------------------------------------------------------------------
set +e
env -i HOME="$HOME" PATH="$NOGH_DIR" MERGEPATH_CAPABILITY_CACHE_DIR="$CACHE" \
  OP_PREFLIGHT_AUTHOR_PAT=ghp_author "$NOGH_DIR/bash" "$PROBE" --repo o/r --no-cache \
  >"$WORKDIR/nogh.json" 2>"$WORKDIR/nogh.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(cap "$WORKDIR/nogh.json" author-writes)" = "false" ] \
   && [ "$(reason "$WORKDIR/nogh.json" author-writes)" = "gh-absent" ] \
   && [ "$(jq -r .tools.gh "$WORKDIR/nogh.json")" = "false" ]; then
  pass "no gh: author-writes refused as gh-absent"
else
  fail "no gh: rc=$rc $(jq -c '.capabilities["author-writes"]' "$WORKDIR/nogh.json" 2>/dev/null) err=$(head -3 "$WORKDIR/nogh.err")"
fi

# ---------------------------------------------------------------------------
# --check: fresh cache -> exports that eval; everything else -> a guard that
# FAILS when evaluated.
# ---------------------------------------------------------------------------
rm -rf "$CACHE"
# The ambient GH_TOKEN is the author's, so the reviewer identity has no
# verified token anywhere: reviewer-writes must export 0.
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"
rc=$?
set -e
evald="$(bash -c "$out"'
printf "%s|%s|%s" "$MERGEPATH_AGENT_TIER" "$MERGEPATH_CAP_AUTHOR_WRITES" "$MERGEPATH_CAP_REVIEWER_WRITES"' 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$evald" = "author-writes,graphql,cross-repo,push-multi-branch|1|0" ]; then
  pass "--check --print-exports on a fresh cache: exports evaluate to the cached tier and flags"
else
  fail "--check --print-exports fresh: rc=$rc evald=$evald out=$out"
fi

guard_fails() { # <label> <stdout of a --print-exports call>
  if [ -n "$2" ] && ! bash -c "$2; echo reached" 2>/dev/null | grep -q reached; then
    pass "$1: stdout carries a guard that fails under eval"
  else
    fail "$1: stdout '$2' does not fail under eval"
  fi
}

set +e
out="$(run_probe CLAUDE_CODE_REMOTE=true -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: surface mismatch exits 2" || fail "--check surface mismatch: exit $rc"
guard_fails "--check surface mismatch" "$out"

jq '.measured_at_epoch = 1' "$CACHE/agent-capability-o_r.json" >"$WORKDIR/stale.json"
cp "$WORKDIR/stale.json" "$CACHE/agent-capability-o_r.json"
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: stale cache exits 2" || fail "--check stale: exit $rc"
guard_fails "--check stale cache" "$out"

rm -rf "$CACHE"
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"; rc=$?
bare="$(run_probe -- --check 2>/dev/null)"; bare_rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: missing cache exits 2" || fail "--check missing: exit $rc"
guard_fails "--check missing cache" "$out"
if [ "$bare_rc" -eq 2 ] && [ -z "$bare" ]; then
  pass "bare --check: status only, empty stdout"
else
  fail "bare --check: exit $bare_rc stdout '$bare'"
fi

set +e
out="$(run_probe -- --bogus --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 1 ] && pass "unknown argument exits 1" || fail "unknown argument: exit $rc"
guard_fails "unknown argument with --print-exports" "$out"

set +e
run_probe -- --print-exports >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 1 ] && pass "--print-exports without --check is rejected" || fail "--print-exports without --check: exit $rc"

echo
echo "agent-capability-probe tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
