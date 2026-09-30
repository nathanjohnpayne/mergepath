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
#   ghp_author      nathanjohnpayne, type User, X-OAuth-Scopes present,
#                   push on the repo
#   ghp_reviewer    nathanpayne-claude, type User, pull only
#   github_pat_ro   nathanjohnpayne, fine-grained (no scopes header), pull only
#   github_pat_rw   nathanjohnpayne, fine-grained (no scopes header), push
#   ghp_noscope     nathanjohnpayne, push, but X-OAuth-Scopes lacks repo
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
login=""; type=User; scopes=""; perms='{"pull":true,"push":false}'
case "$tok" in
  ghp_author) login=nathanjohnpayne; scopes="repo, workflow"; perms='{"pull":true,"push":true}' ;;
  ghp_reviewer) login=nathanpayne-claude; scopes="repo" ;;
  github_pat_ro) login=nathanjohnpayne ;;
  github_pat_rw) login=nathanjohnpayne; perms='{"pull":true,"push":true}' ;;
  ghp_noscope) login=nathanjohnpayne; scopes="gist, read:org"; perms='{"pull":true,"push":true}' ;;
  ghs_author) login=nathanjohnpayne ;;
  proxy-injected) login=nathanjohnpayne; perms='{"pull":true,"push":true}' ;;
esac
status=200; body=""
if [ "$tok" = "ghp_flap" ]; then
  # First GET /user (the resolver's, via --jq) fails; later ones succeed.
  login=nathanpayne-claude; scopes="repo"
  if [ "$path" = "user" ]; then
    n=$(wc -l <"$STUB_FLAP_COUNT" | tr -d ' '); echo x >>"$STUB_FLAP_COUNT"
    if [ "$n" -eq 0 ]; then status=503; body='{"message":"Service Unavailable"}'; fi
  fi
fi
if [ "$status" != 200 ]; then
  :
elif [ "$tok" = "ghp_flaky" ]; then
  status=503; body='{"message":"Service Unavailable"}'
elif [ -n "${STUB_FAIL_STATUS:-}" ]; then
  status="$STUB_FAIL_STATUS"; body='{"message":"Server Error"}'
elif [ -z "$login" ]; then
  status=401; body='{"message":"Bad credentials"}'
elif [ "$path" = "user" ]; then
  body="{\"login\":\"$login\",\"type\":\"$type\"}"
elif [ "$path" = "graphql" ]; then
  if [ "$tok" = "proxy-injected" ] || [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    status=403; body='{"message":"This GraphQL query is not enabled for this session. Use gh api repos/{owner}/{repo}/... instead."}'
  else
    body="{\"data\":{\"viewer\":{\"login\":\"$login\"}}}"
  fi
elif [ "${path#repos/$STUB_REPO/rules/branches/}" != "$path" ]; then
  body="${STUB_RULES:-[]}"
elif [ "$path" = "repos/$STUB_REPO" ]; then
  body="{\"full_name\":\"x\",\"private\":true,\"permissions\":$perms}"
elif [ "$tok" = "proxy-injected" ] || [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
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
# STUB_CUT_OFF: the response arrived with 200 headers, then the transfer failed.
[ -n "${STUB_CUT_OFF:-}" ] && [ "$path" = "graphql" ] && exit 1
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
if [ "$rc" -eq 0 ] && [ "$(jq -r .tier "$WORKDIR/local.json")" = "author-writes,reviewer-writes,graphql,cross-repo" ] \
   && [ "$(jq -r .surface "$WORKDIR/local.json")" = "local" ]; then
  pass "local + user-held PATs: every measurable capability granted"
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
if [ "$rc" -eq 0 ] && [ "$evald" = "author-writes,graphql,cross-repo|1|0" ]; then
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

jq '.measured_at_epoch = 1' "$CACHE/agent-capability-o_r-nathanpayne-claude.json" >"$WORKDIR/stale.json"
cp "$WORKDIR/stale.json" "$CACHE/agent-capability-o_r-nathanpayne-claude.json"
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: stale cache exits 2" || fail "--check stale: exit $rc"
guard_fails "--check stale cache" "$out"

jq --argjson t "$(( $(date +%s) + 86400 ))" '.measured_at_epoch = $t' "$WORKDIR/stale.json" >"$CACHE/agent-capability-o_r-nathanpayne-claude.json"
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: future measurement time exits 2" || fail "--check future timestamp: exit $rc"
guard_fails "--check future measurement time" "$out"

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

# ---------------------------------------------------------------------------
# Identity is not write capability (Codex P1 on #1526): the token must also
# hold the repository permission the role needs, and a classic token the
# `repo` scope.
# ---------------------------------------------------------------------------
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=github_pat_ro -- --no-cache >"$WORKDIR/ro.json" 2>/dev/null
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghp_noscope -- --no-cache >"$WORKDIR/noscope.json" 2>/dev/null
run_probe OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- --no-cache >"$WORKDIR/rev.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/ro.json" author-writes)" = "false" ] && reason "$WORKDIR/ro.json" author-writes | grep -q "lacks 'push'"; then
  pass "read-only fine-grained token for the author: author-writes refused for lack of push"
else
  fail "read-only token: $(jq -c '.capabilities["author-writes"]' "$WORKDIR/ro.json")"
fi
if [ "$(cap "$WORKDIR/noscope.json" author-writes)" = "false" ] && reason "$WORKDIR/noscope.json" author-writes | grep -q "do not include repo"; then
  pass "classic token without repo scope: author-writes refused"
else
  fail "no-scope token: $(jq -c '.capabilities["author-writes"]' "$WORKDIR/noscope.json")"
fi
if [ "$(cap "$WORKDIR/rev.json" reviewer-writes)" = "true" ]; then
  pass "reviewer with pull only: reviewer-writes granted (reviews need read access)"
else
  fail "reviewer pull-only: $(jq -c '.capabilities["reviewer-writes"]' "$WORKDIR/rev.json")"
fi

# Outside Claude cloud, multi-branch push is not measured: nothing short of a
# real push proves the server accepts one (Codex rounds 1-3 on #1526).
if [ "$(cap "$WORKDIR/local.json" push-multi-branch)" = "false" ] \
   && [ "$(jq -r '.capabilities["push-multi-branch"].basis' "$WORKDIR/local.json")" = "not-measured" ]; then
  pass "local: push-multi-branch reported not-measured, never granted from a dry run"
else
  fail "local push: $(jq -c '.capabilities["push-multi-branch"]' "$WORKDIR/local.json")"
fi

# ---------------------------------------------------------------------------
# The cache is bound to the identities it measured (Codex P1 on #1526): a
# Claude probe must not answer a Codex session's --check.
# ---------------------------------------------------------------------------
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- >/dev/null 2>&1
set +e
out="$(run_probe MERGEPATH_AGENT=codex -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check for another reviewer identity finds no cache (exit 2)" || fail "--check other identity: exit $rc"
guard_fails "--check for another reviewer identity" "$out"
bogus="$CACHE/agent-capability-o_r-nathanpayne-claude.json"
jq '.capabilities["reviewer-writes"].identity = "nathanpayne-codex"' "$bogus" >"$WORKDIR/relabel.json"
cp "$WORKDIR/relabel.json" "$bogus"
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check rejects a cache whose recorded identities do not match" || fail "--check recorded identity mismatch: exit $rc"
guard_fails "--check recorded identity mismatch" "$out"

# Every measured capability is exported, read included (Codex P2 on #1526).
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
out="$(run_probe -- --check --print-exports 2>/dev/null || true)"
evald="$(bash -c "$out"'
printf "%s" "${MERGEPATH_CAP_READ:-unset}"' 2>/dev/null || true)"
if [ "$evald" = "1" ]; then
  pass "--check --print-exports exports MERGEPATH_CAP_READ"
else
  fail "MERGEPATH_CAP_READ: got '$evald'"
fi

# ---------------------------------------------------------------------------
# Codex round 2 on #1526.
# ---------------------------------------------------------------------------
# A fine-grained token whose USER has push is still unverifiable: the token's
# own permissions cannot be read, so the capability is not granted.
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=github_pat_rw -- --no-cache >"$WORKDIR/fg.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/fg.json" author-writes)" = "false" ] \
   && [ "$(jq -r '.capabilities["author-writes"].basis' "$WORKDIR/fg.json")" = "unverifiable" ]; then
  pass "fine-grained token with a push role: author-writes unverifiable, not granted"
else
  fail "fine-grained push role: $(jq -c '.capabilities["author-writes"]' "$WORKDIR/fg.json")"
fi

# A server error is not a denial: flagged, and never cached.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author STUB_FAIL_STATUS=502 -- >"$WORKDIR/outage.json" 2>"$WORKDIR/outage.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(jq -r .transient_failures "$WORKDIR/outage.json")" = "true" ] \
   && [ ! -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ] \
   && grep -q "not caching this result" "$WORKDIR/outage.err"; then
  pass "5xx during the probe: result flagged transient and not cached"
else
  fail "transient outage: rc=$rc transient=$(jq -r .transient_failures "$WORKDIR/outage.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# A cloud cache belongs to its session.
rm -rf "$CACHE"
run_probe CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=cse_one GH_TOKEN=proxy-injected -- >/dev/null 2>&1
set +e
out="$(run_probe CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=cse_two -- --check --print-exports 2>/dev/null)"; rc=$?
same="$(run_probe CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=cse_one -- --check --print-exports 2>/dev/null)"; same_rc=$?
set -e
if [ "$rc" -eq 2 ] && [ "$same_rc" -eq 0 ]; then
  pass "--check: another cloud session's cache is rejected; the same session's is accepted"
else
  fail "--check session binding: other=$rc same=$same_rc"
fi
guard_fails "--check another session's cache" "$out"

# The tier lists a write path even when the ambient credential cannot read.
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghp_author -- --no-cache >"$WORKDIR/noread.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/noread.json" read)" = "true" ] && [ "$(jq -r .tier "$WORKDIR/noread.json")" = "author-writes,graphql,cross-repo" ]; then
  pass "no ambient credential, author PAT only: reads are measured with the PAT and the write path is listed"
else
  fail "tier with ambient read failure: $(jq -r .tier "$WORKDIR/noread.json")"
fi

# The documented reviewer SSH aliases derive the repository.
git -C "$FIX" remote set-url origin git@github-claude:owner/aliased.git
set +e
env -u GH_TOKEN GIT_SSH_COMMAND=false PATH="$STUB_DIR:$PATH" STUB_REPO=owner/aliased MERGEPATH_CAPABILITY_CACHE_DIR="$CACHE" \
  "$PROBE" --no-cache >"$WORKDIR/alias.json" 2>/dev/null
rc=$?
set -e
git -C "$FIX" remote set-url origin "$WORKDIR/origin.git"
if [ "$rc" -eq 0 ] && [ "$(jq -r .repo "$WORKDIR/alias.json")" = "owner/aliased" ]; then
  pass "git@github-claude:owner/repo derives the repository"
else
  fail "SSH alias: rc=$rc repo=$(jq -r .repo "$WORKDIR/alias.json" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Codex round 3 on #1526.
# ---------------------------------------------------------------------------
# The cached cross-repo answer is specific to its target.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- --cross-repo other/one >/dev/null 2>&1
set +e
out="$(run_probe -- --check --print-exports 2>/dev/null)"; rc=$?
same="$(run_probe -- --cross-repo other/one --check --print-exports 2>/dev/null)"; same_rc=$?
set -e
if [ "$rc" -eq 2 ] && [ "$same_rc" -eq 0 ]; then
  pass "--check: a cache measured against another cross-repo target is rejected; the same target is accepted"
else
  fail "--check cross-repo target: default=$rc same=$same_rc"
fi
guard_fails "--check another cross-repo target" "$out"

# A transient failure inside the resolver's own GET /user is not cached.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_flaky -- >"$WORKDIR/flaky.json" 2>"$WORKDIR/flaky.err"
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/flaky.json")" = "true" ] \
   && [ "$(cap "$WORKDIR/flaky.json" reviewer-writes)" = "false" ] \
   && [ ! -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "resolver GET /user answered 503: marked transient, reviewer-writes not cached as a denial"
else
  fail "resolver transient: transient=$(jq -r .transient_failures "$WORKDIR/flaky.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# curl behind an HTTPS proxy: the origin's status is the last status line.
CONNECT_DIR="$WORKDIR/connect-bin"
mkdir -p "$CONNECT_DIR"
for tool in "$NOGH_DIR"/*; do ln -sf "$(readlink "$tool" 2>/dev/null || echo "$tool")" "$CONNECT_DIR/$(basename "$tool")"; done
rm -f "$CONNECT_DIR/curl"
cat >"$CONNECT_DIR/curl" <<'STUB'
#!/usr/bin/env bash
hdr=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) hdr="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 403\r\ncontent-type: application/json\r\n\r\n' >"$hdr"
printf '{"message":"Forbidden"}' >"$out"
STUB
chmod +x "$CONNECT_DIR/curl"
set +e
env -i HOME="$HOME" PATH="$CONNECT_DIR" MERGEPATH_CAPABILITY_CACHE_DIR="$CACHE" GH_TOKEN=ghp_author \
  "$CONNECT_DIR/bash" "$PROBE" --repo o/r --no-cache >"$WORKDIR/connect.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/connect.json" read)" = "false" ] && reason "$WORKDIR/connect.json" read | grep -q "returned 403"; then
  pass "curl path: a proxy CONNECT 200 before an origin 403 reads as 403"
else
  fail "curl CONNECT parse: $(jq -c '.capabilities.read' "$WORKDIR/connect.json" 2>/dev/null)"
fi

# A 200 whose transfer then failed is an incomplete answer, not a measurement
# (CodeRabbit on #1526): flagged transient, never cached.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author STUB_CUT_OFF=1 -- >"$WORKDIR/cut.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/cut.json")" = "true" ] && [ ! -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "200 headers followed by a failed transfer: flagged transient and not cached"
else
  fail "cut-off transfer: transient=$(jq -r .transient_failures "$WORKDIR/cut.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# The resolver's GET /user fails, but the candidate verifies on the repeat:
# the resolver's failure was the transient one, so nothing is cached (Codex P2
# on #1526, round 4).
rm -rf "$CACHE"
: >"$WORKDIR/flap-count"
set +e
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_flap STUB_FLAP_COUNT="$WORKDIR/flap-count" -- >"$WORKDIR/flap.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/flap.json")" = "true" ] && [ ! -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "resolver failed but the candidate verified on repeat: marked transient, not cached"
else
  fail "resolver flap: transient=$(jq -r .transient_failures "$WORKDIR/flap.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# Round 5 on #1526.
# An outage while the resolver verifies the KEYRING candidate is transient
# too: no preferred PAT, no ambient token, the keyring token's GET /user 503s.
rm -rf "$CACHE"
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghp_author STUB_KEYRING_nathanpayne_claude=ghp_flaky -- >"$WORKDIR/kr.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/kr.json")" = "true" ] && [ ! -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "keyring candidate's GET /user answered 503: marked transient, not cached"
else
  fail "keyring transient: transient=$(jq -r .transient_failures "$WORKDIR/kr.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# A read that fails does not hide a verified write path: the reviewer PAT
# (the read credential) is refused, the author PAT verifies.
set +e
run_probe OP_PREFLIGHT_REVIEWER_PAT=ghp_revoked OP_PREFLIGHT_AUTHOR_PAT=ghp_author -- --no-cache >"$WORKDIR/rw.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/rw.json" read)" = "false" ] && [ "$(jq -r .tier "$WORKDIR/rw.json")" = "author-writes" ]; then
  pass "read refused but author PAT verified: tier is author-writes, not none"
else
  fail "tier with read refused: read=$(cap "$WORKDIR/rw.json" read) tier=$(jq -r .tier "$WORKDIR/rw.json" 2>/dev/null)"
fi

echo
echo "agent-capability-probe tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
