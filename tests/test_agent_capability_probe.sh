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
[ -n "${STUB_HOST_LOG:-}" ] && printf '%s %s\n' "${GH_HOST:-<unset>}" "$*" >>"$STUB_HOST_LOG"
if [ "$1 $2" = "auth token" ] && [ "$#" -eq 2 ]; then
  # gh auth token (no --user): the ACTIVE account, controlled by STUB_KEYRING_ACTIVE
  [ -n "${STUB_KEYRING_ACTIVE:-}" ] || exit 1
  printf '%s\n' "$STUB_KEYRING_ACTIVE"
  exit 0
fi
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
    # identity-check.sh pins its write-mode requests to github.com (#1541);
    # this fixture serves github.com only, like the real token it models.
    --hostname) [ "$2" = "github.com" ] || { echo "stub: no credentials for $2" >&2; exit 4; }; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
login=""; type=User; scopes=""; perms='{"pull":true,"push":false}'
case "$tok" in
  ghp_author) login=nathanjohnpayne; scopes="repo, workflow"; perms='{"pull":true,"push":true}' ;;
  ghp_reviewer) login=nathanpayne-claude; scopes="repo"; perms='{"pull":true,"push":true}' ;;
  ghp_readreviewer) login=nathanpayne-claude; scopes="repo" ;;
  github_pat_ro) login=nathanjohnpayne ;;
  github_pat_rw) login=nathanjohnpayne; perms='{"pull":true,"push":true}' ;;
  ghp_noscope) login=nathanjohnpayne; scopes="gist, read:org"; perms='{"pull":true,"push":true}' ;;
  ghp_pubonly) login=nathanjohnpayne; scopes="public_repo"; perms='{"pull":true,"push":true}' ;;
  ghs_author) login=nathanjohnpayne ;;
  opaque-author) login=nathanjohnpayne; perms='{"pull":true,"push":true}' ;;  # unidentifiable form
  0123456789abcdef0123456789abcdef01234567) login=nathanpayne-claude; scopes="repo" ;;  # legacy classic PAT
  proxy-injected) login=nathanjohnpayne; perms='{"pull":true,"push":true}' ;;
esac
status=200; body=""
if [ "$tok" = "opaque-flap" ]; then
  # An unidentifiable author token whose first GET /user fails transiently.
  login=nathanjohnpayne; perms='{"pull":true,"push":true}'
  if [ "$path" = "user" ]; then
    n=$(wc -l <"$STUB_FLAP_COUNT" | tr -d ' '); echo x >>"$STUB_FLAP_COUNT"
    if [ "$n" -eq 0 ]; then status=503; body='{"message":"Service Unavailable"}'; fi
  fi
fi
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
elif [ "$path" = "graphql" ] && [ -n "${STUB_GRAPHQL_RATE_LIMITED:-}" ]; then
  body='{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}'
elif [ "$path" = "graphql" ]; then
  if [ "$tok" = "proxy-injected" ] || [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    status=403; body='{"message":"This GraphQL query is not enabled for this session. Use gh api repos/{owner}/{repo}/... instead."}'
  else
    body="{\"data\":{\"viewer\":{\"login\":\"$login\"}}}"
  fi
elif [ "${path#repos/$STUB_REPO/rules/branches/}" != "$path" ]; then
  body="${STUB_RULES:-[]}"
elif [ "$path" = "repos/$STUB_REPO" ]; then
  body="{\"full_name\":\"x\",\"private\":${STUB_PRIVATE:-true},\"archived\":${STUB_ARCHIVED:-false},\"permissions\":$perms}"
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
   && [ "$(jq -r '.capabilities["author-writes"].credential_class' "$WORKDIR/cloud.json")" = "brokered" ]; then
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

# The same token reached only through the keyring fallback (no preferred PAT,
# no ambient token) is reported by its class too, not as empty (Codex on #1541).
set +e
run_probe STUB_KEYRING_nathanjohnpayne=ghs_author -- --no-cache >"$WORKDIR/app-kr.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/app-kr.json" author-writes)" = "false" ] \
   && [ "$(jq -r '.capabilities["author-writes"].credential_class' "$WORKDIR/app-kr.json")" = "app-installed" ]; then
  pass "ghs_ token in the keyring only: author-writes refused, class app-installed (not empty)"
else
  fail "keyring ghs_ token: $(jq -c '.capabilities["author-writes"]' "$WORKDIR/app-kr.json")"
fi

# A rejected legacy 40-hex PAT is classified with its own response headers, so
# it reads user-held and does not mask the keyring's app token (Codex on #1541).
set +e
run_probe GH_TOKEN=0123456789abcdef0123456789abcdef01234567 STUB_KEYRING_nathanjohnpayne=ghs_author -- --no-cache >"$WORKDIR/app-hex.json" 2>/dev/null
set -e
if [ "$(jq -r '.capabilities["author-writes"].credential_class' "$WORKDIR/app-hex.json")" = "app-installed" ]; then
  pass "legacy PAT ahead of a keyring ghs_ token: classified with its headers, app-installed reported"
else
  fail "legacy PAT masking: $(jq -c '.capabilities["author-writes"]' "$WORKDIR/app-hex.json")"
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
out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"
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
out="$(run_probe GH_TOKEN=ghp_author CLAUDE_CODE_REMOTE=true -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: surface mismatch exits 2" || fail "--check surface mismatch: exit $rc"
guard_fails "--check surface mismatch" "$out"

jq '.measured_at_epoch = 1' "$CACHE/agent-capability-o_r-nathanpayne-claude.json" >"$WORKDIR/stale.json"
cp "$WORKDIR/stale.json" "$CACHE/agent-capability-o_r-nathanpayne-claude.json"
set +e
out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: stale cache exits 2" || fail "--check stale: exit $rc"
guard_fails "--check stale cache" "$out"

jq --argjson t "$(( $(date +%s) + 86400 ))" '.measured_at_epoch = $t' "$WORKDIR/stale.json" >"$CACHE/agent-capability-o_r-nathanpayne-claude.json"
set +e
out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check: future measurement time exits 2" || fail "--check future timestamp: exit $rc"
guard_fails "--check future measurement time" "$out"

rm -rf "$CACHE"
set +e
out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
bare="$(run_probe GH_TOKEN=ghp_author -- --check 2>/dev/null)"; bare_rc=$?
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
run_probe OP_PREFLIGHT_REVIEWER_PAT=ghp_readreviewer -- --no-cache >"$WORKDIR/rev.json" 2>/dev/null
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
if [ "$(cap "$WORKDIR/rev.json" reviewer-writes)" = "false" ] && reason "$WORKDIR/rev.json" reviewer-writes | grep -q "lacks 'push'"; then
  pass "reviewer with read access only: reviewer-writes refused (approvals and thread resolution need write, #1537)"
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
out="$(run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer MERGEPATH_AGENT=codex -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check for another reviewer identity finds no cache (exit 2)" || fail "--check other identity: exit $rc"
guard_fails "--check for another reviewer identity" "$out"
bogus="$CACHE/agent-capability-o_r-nathanpayne-claude.json"
jq '.capabilities["reviewer-writes"].identity = "nathanpayne-codex"' "$bogus" >"$WORKDIR/relabel.json"
cp "$WORKDIR/relabel.json" "$bogus"
set +e
out="$(run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- --check --print-exports 2>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 2 ] && pass "--check rejects a cache whose recorded identities do not match" || fail "--check recorded identity mismatch: exit $rc"
guard_fails "--check recorded identity mismatch" "$out"

# Every measured capability is exported, read included (Codex P2 on #1526).
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null || true)"
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
out="$(run_probe GH_TOKEN=proxy-injected CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=cse_two -- --check --print-exports 2>/dev/null)"; rc=$?
run_probe GH_TOKEN=proxy-injected CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=cse_one -- --check --print-exports >/dev/null 2>&1; same_rc=$?
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
out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
run_probe GH_TOKEN=ghp_author -- --cross-repo other/one --check --print-exports >/dev/null 2>&1; same_rc=$?
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

# Phase 4b on #1541: under the write-token opt-in, an unidentifiable token
# whose first verification failed transiently and then verifies on repeat is
# a transient failure too, not a cached stable denial.
rm -rf "$CACHE"
: >"$WORKDIR/flap-count"
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=opaque-flap MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1 STUB_FLAP_COUNT="$WORKDIR/flap-count" -- >"$WORKDIR/oflap.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/oflap.json")" = "true" ] && [ -z "$(ls "$CACHE" 2>/dev/null)" ]; then
  pass "opt-in: an unidentifiable token that verifies on repeat marks the run transient, not cached"
else
  fail "opt-in repeat: transient=$(jq -r .transient_failures "$WORKDIR/oflap.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# Codex on #1541: every probe measurement (api -i -X ...) targets github.com,
# so a sole GHES host in hosts.yml cannot answer for a rejected token.
: >"$WORKDIR/probe-hosts.log"
run_probe GH_TOKEN=ghp_author STUB_HOST_LOG="$WORKDIR/probe-hosts.log" -- --no-cache >/dev/null 2>&1 || true
if grep -q ' -X ' "$WORKDIR/probe-hosts.log" && ! grep ' -X ' "$WORKDIR/probe-hosts.log" | grep -vq '^github.com '; then
  pass "every probe measurement runs with GH_HOST=github.com"
else
  fail "probe request hosts: $(grep ' -X ' "$WORKDIR/probe-hosts.log" | cut -d' ' -f1 | sort -u | tr '\n' ' ')"
fi

# Phase 4b on #1541: with GH_HOST naming an Enterprise host the verifier
# refuses permanently; a successful repeat against that host is not a
# transient recovery, so the result is cached like any stable denial.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author GH_HOST=ghe.example.com -- >"$WORKDIR/ghehost.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/ghehost.json")" = "false" ] && [ -n "$(ls "$CACHE" 2>/dev/null)" ] \
   && [ "$(cap "$WORKDIR/ghehost.json" author-writes)" = "false" ]; then
  pass "GH_HOST on an Enterprise host: a permanent refusal, cached, not suppressed as transient"
else
  fail "GHES GH_HOST: transient=$(jq -r .transient_failures "$WORKDIR/ghehost.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
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

# Round 6 on #1526.
# A public repository reports "private": false; a public_repo-scoped classic
# token is enough there.
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghp_pubonly STUB_PRIVATE=false -- --no-cache >"$WORKDIR/pub.json" 2>/dev/null
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghp_pubonly -- --no-cache >"$WORKDIR/priv.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/pub.json" author-writes)" = "true" ] && [ "$(cap "$WORKDIR/priv.json" author-writes)" = "false" ]; then
  pass "public_repo scope: granted on a public repository, refused on a private one"
else
  fail "public_repo: public=$(cap "$WORKDIR/pub.json" author-writes) private=$(cap "$WORKDIR/priv.json" author-writes)"
fi

# A revoked PAT (401) is an authoritative denial: the result is cached.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_revoked -- >"$WORKDIR/revoked.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/revoked.json")" = "false" ] \
   && [ "$(cap "$WORKDIR/revoked.json" reviewer-writes)" = "false" ] \
   && [ -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "revoked reviewer PAT (401): denial is authoritative and cached"
else
  fail "revoked PAT: transient=$(jq -r .transient_failures "$WORKDIR/revoked.json" 2>/dev/null) cache=$(ls "$CACHE" 2>/dev/null)"
fi

# A malformed capability record fails before any export is printed
# (CodeRabbit on #1526): no partial export set for eval to run.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
CF="$CACHE/agent-capability-o_r-nathanpayne-claude.json"
for mutation in '.capabilities.read = true' '.capabilities["author-writes"].granted = "yes"' '.tier = 7' 'del(.capabilities.graphql)'; do
  jq "$mutation" "$CF" >"$WORKDIR/mal.json" && cp "$WORKDIR/mal.json" "$CF.mal"
  cp "$CF" "$WORKDIR/good.json"; cp "$CF.mal" "$CF"
  set +e
  out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
  set -e
  cp "$WORKDIR/good.json" "$CF"
  if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '^export ' && ! bash -c "$out; echo reached" 2>/dev/null | grep -q reached; then
    pass "malformed cache ($mutation): exit 2, no export printed, guard fails under eval"
  else
    fail "malformed cache ($mutation): rc=$rc out=$out"
  fi
done

# ---------------------------------------------------------------------------
# Phase 4b follow-ups on #1526 (#1533-#1536).
# ---------------------------------------------------------------------------
# #1533: a record whose identity field cannot be read (a scalar where an
# object belongs) must fail through the eval guard, never abort with an empty
# stdout that `eval ... &&` treats as success.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
CF="$CACHE/agent-capability-o_r-nathanpayne-claude.json"
cp "$CF" "$WORKDIR/good.json"
for mutation in '.capabilities["author-writes"] = true' '.capabilities["reviewer-writes"].identity = 5' '.repo = null' '.measured_at_epoch = "soon"' '.session_id = 3'; do
  jq "$mutation" "$WORKDIR/good.json" >"$CF"
  set +e
  out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
  reached="$(bash -c "eval \"\$1\" && echo REACHED" _ "$out" 2>/dev/null)"
  set -e
  if [ "$rc" -eq 2 ] && [ -n "$out" ] && [ -z "$reached" ]; then
    pass "#1533 ($mutation): exit 2 and the guard stops eval ... &&"
  else
    fail "#1533 ($mutation): rc=$rc out=$out reached=$reached"
  fi
done
cp "$WORKDIR/good.json" "$CF"

# #1534: a revoked preferred PAT is final for the resolver even when the
# keyring holds a valid token for the identity, so the repeat must not try the
# keyring, and the 401 is an authoritative, cacheable denial.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_revoked STUB_KEYRING_nathanpayne_claude=ghp_reviewer -- >"$WORKDIR/fu-revoked.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/fu-revoked.json")" = "false" ] \
   && [ "$(cap "$WORKDIR/fu-revoked.json" reviewer-writes)" = "false" ] \
   && [ -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "#1534: revoked preferred PAT with a valid keyring token: not transient, denial cached"
else
  fail "#1534: transient=$(jq -r .transient_failures "$WORKDIR/fu-revoked.json" 2>/dev/null) reviewer=$(cap "$WORKDIR/fu-revoked.json" reviewer-writes)"
fi

# #1535: a GraphQL rate limit answered as HTTP 200 is transient.
rm -rf "$CACHE"
set +e
run_probe GH_TOKEN=ghp_author STUB_GRAPHQL_RATE_LIMITED=1 -- >"$WORKDIR/fu-gql.json" 2>/dev/null
set -e
if [ "$(jq -r .transient_failures "$WORKDIR/fu-gql.json")" = "true" ] && [ ! -e "$CACHE/agent-capability-o_r-nathanpayne-claude.json" ]; then
  pass "#1535: GraphQL RATE_LIMITED over HTTP 200 is transient and not cached"
else
  fail "#1535: transient=$(jq -r .transient_failures "$WORKDIR/fu-gql.json" 2>/dev/null)"
fi

# #1536: an archived repository grants no writes.
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer STUB_ARCHIVED=true -- --no-cache >"$WORKDIR/fu-arch.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/fu-arch.json" author-writes)" = "false" ] && [ "$(cap "$WORKDIR/fu-arch.json" reviewer-writes)" = "false" ] \
   && reason "$WORKDIR/fu-arch.json" reviewer-writes | grep -q "archived"; then
  pass "#1536: archived repository: author and reviewer writes not granted"
else
  fail "#1536: $(jq -c '[.capabilities["author-writes"], .capabilities["reviewer-writes"]]' "$WORKDIR/fu-arch.json")"
fi

# ---------------------------------------------------------------------------
# #1537.
# ---------------------------------------------------------------------------
# The cache is bound to the credential environment: a shell without the PATs
# does not inherit another shell's grants.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- >/dev/null 2>&1
set +e
run_probe GH_TOKEN=ghp_author OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer -- --check --print-exports >/dev/null 2>&1; same_rc=$?
other="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; other_rc=$?
set -e
if [ "$same_rc" -eq 0 ] && [ "$other_rc" -eq 2 ]; then
  pass "#1537: --check accepts the same credential environment and rejects a different one"
else
  fail "#1537 credential binding: same=$same_rc other=$other_rc"
fi
guard_fails "#1537 different credentials" "$other"
if ! grep -qF ghp_reviewer "$CACHE/agent-capability-o_r-nathanpayne-claude.json"; then
  pass "#1537: the credential fingerprint holds no token value"
else
  fail "#1537: a token value reached the cache"
fi

# #1539: the surface never selects the reviewer, because the write wrappers
# and gh-pr-guard.sh do not read it. A Codex cloud surface with no agent named
# measures the default reviewer, as the wrapper would use, and says how to fix
# it; MERGEPATH_AGENT=codex selects the Codex reviewer everywhere.
set +e
run_probe MERGEPATH_AGENT_SURFACE=codex-cloud GH_TOKEN=ghp_author -- --no-cache >"$WORKDIR/cx.json" 2>"$WORKDIR/cx.err"
run_probe MERGEPATH_AGENT_SURFACE=codex-cloud MERGEPATH_AGENT=codex GH_TOKEN=ghp_author -- --no-cache >"$WORKDIR/cx2.json" 2>"$WORKDIR/cx2.err"
set -e
if [ "$(jq -r '.capabilities["reviewer-writes"].identity' "$WORKDIR/cx.json")" = "$(env -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT MERGEPATH_AGENT_SURFACE=codex-cloud bash -c '. "$1"; gh_default_reviewer_identity' _ "$ROOT/scripts/lib/gh-token-resolver.sh")" ] \
   && grep -q "Set MERGEPATH_AGENT=codex" "$WORKDIR/cx.err"; then
  pass "#1539: a codex-cloud surface alone measures the reviewer the wrapper resolves, and warns"
else
  fail "#1539 surface-only reviewer: $(jq -r '.capabilities["reviewer-writes"].identity' "$WORKDIR/cx.json")"
fi
if [ "$(jq -r '.capabilities["reviewer-writes"].identity' "$WORKDIR/cx2.json")" = "nathanpayne-codex" ] \
   && ! grep -q "Set MERGEPATH_AGENT=codex" "$WORKDIR/cx2.err"; then
  pass "#1539: MERGEPATH_AGENT=codex on a codex-cloud surface measures nathanpayne-codex, no warning"
else
  fail "#1539 explicit codex agent: $(jq -r '.capabilities["reviewer-writes"].identity' "$WORKDIR/cx2.json")"
fi

# A timestamp that is not a plain non-negative integer is rejected by the
# validator, before any shell arithmetic.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
CF="$CACHE/agent-capability-o_r-nathanpayne-claude.json"
cp "$CF" "$WORKDIR/good.json"
for mutation in '.measured_at_epoch = "09"' '.measured_at_epoch = [1]' '.measured_at_epoch = 1.5' '.measured_at_epoch = -1' '.measured_at_epoch = 1e20'; do
  jq "$mutation" "$WORKDIR/good.json" >"$CF"
  set +e
  out="$(run_probe GH_TOKEN=ghp_author -- --check --print-exports 2>/dev/null)"; rc=$?
  reached="$(bash -c "eval \"\$1\" && echo REACHED" _ "$out" 2>/dev/null)"
  set -e
  if [ "$rc" -eq 2 ] && [ -z "$reached" ]; then
    pass "#1537 timestamp ($mutation): exit 2, guard stops eval ... &&"
  else
    fail "#1537 timestamp ($mutation): rc=$rc reached=$reached"
  fi
done
cp "$WORKDIR/good.json" "$CF"

# Repository names compare case-insensitively.
set +e
run_probe GH_TOKEN=ghp_author -- --cross-repo O/R --no-cache >"$WORKDIR/case.json" 2>/dev/null
set -e
if [ "$(cap "$WORKDIR/case.json" cross-repo)" = "false" ] && [ "$(jq -r '.capabilities["cross-repo"].basis' "$WORKDIR/case.json")" = "not-measured" ]; then
  pass "#1537: --cross-repo naming this repository in other casing is not cross-repo evidence"
else
  fail "#1537 casing: $(jq -c '.capabilities["cross-repo"]' "$WORKDIR/case.json")"
fi

# Codex on #1538: the fingerprint covers GITHUB_TOKEN and the keyring, stays
# out of stdout, and schema-1 records are rejected.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author GITHUB_TOKEN=ghp_author STUB_KEYRING_nathanpayne_claude=ghp_reviewer -- >"$WORKDIR/fp.json" 2>/dev/null
set +e
run_probe GH_TOKEN=ghp_author GITHUB_TOKEN=ghp_author STUB_KEYRING_nathanpayne_claude=ghp_reviewer -- --check >/dev/null 2>&1; same_rc=$?
run_probe GH_TOKEN=ghp_author STUB_KEYRING_nathanpayne_claude=ghp_reviewer -- --check >/dev/null 2>&1; gt_rc=$?
run_probe GH_TOKEN=ghp_author GITHUB_TOKEN=ghp_author -- --check >/dev/null 2>&1; kr_rc=$?
set -e
if [ "$same_rc" -eq 0 ] && [ "$gt_rc" -eq 2 ] && [ "$kr_rc" -eq 2 ]; then
  pass "credential fingerprint covers GITHUB_TOKEN and the keyring token"
else
  fail "fingerprint coverage: same=$same_rc github_token=$gt_rc keyring=$kr_rc"
fi
if [ "$(jq 'has("credential_fingerprint")' "$WORKDIR/fp.json")" = "false" ] \
   && [ "$(jq 'has("credential_fingerprint")' "$CACHE/agent-capability-o_r-nathanpayne-claude.json")" = "true" ]; then
  pass "the fingerprint is in the private cache only, never in probe stdout"
else
  fail "fingerprint placement: stdout=$(jq 'has("credential_fingerprint")' "$WORKDIR/fp.json") cache=$(jq 'has("credential_fingerprint")' "$CACHE/agent-capability-o_r-nathanpayne-claude.json")"
fi
# GNU stat first: on Linux `stat -f` means filesystem status and still exits 0.
perm="$(stat -c '%a' "$CACHE/agent-capability-o_r-nathanpayne-claude.json" 2>/dev/null || stat -f '%Lp' "$CACHE/agent-capability-o_r-nathanpayne-claude.json")"
if [ "$perm" = "600" ]; then
  pass "the cache file is owner-only (600)"
else
  fail "cache file mode is $perm, expected 600"
fi
jq '.schema = 1' "$CACHE/agent-capability-o_r-nathanpayne-claude.json" >"$WORKDIR/s1.json" && cp "$WORKDIR/s1.json" "$CACHE/agent-capability-o_r-nathanpayne-claude.json"
set +e
run_probe GH_TOKEN=ghp_author GITHUB_TOKEN=ghp_author STUB_KEYRING_nathanpayne_claude=ghp_reviewer -- --check >/dev/null 2>&1; s1_rc=$?
set -e
[ "$s1_rc" -eq 2 ] && pass "a schema-1 record (no credential binding) is rejected" || fail "schema-1 record: exit $s1_rc"

# No SHA-256 tool: the fingerprint is unmatchable, so --check never reuses
# the cache (CodeRabbit on #1538).
HASHLESS="$WORKDIR/hashless-bin"
mkdir -p "$HASHLESS"
for tool in "$NOGH_DIR"/*; do ln -sf "$(readlink "$tool" 2>/dev/null || echo "$tool")" "$HASHLESS/$(basename "$tool")"; done
rm -f "$HASHLESS/shasum" "$HASHLESS/sha256sum"
ln -sf "$STUB_DIR/gh" "$HASHLESS/gh"
rm -rf "$CACHE"
set +e
env -i HOME="$HOME" PATH="$HASHLESS" STUB_REPO=o/r MERGEPATH_CAPABILITY_CACHE_DIR="$CACHE" GH_TOKEN=ghp_author \
  "$HASHLESS/bash" "$PROBE" --repo o/r >/dev/null 2>&1
env -i HOME="$HOME" PATH="$HASHLESS" STUB_REPO=o/r MERGEPATH_CAPABILITY_CACHE_DIR="$CACHE" GH_TOKEN=ghp_author \
  "$HASHLESS/bash" "$PROBE" --repo o/r --check >/dev/null 2>&1; hl_rc=$?
set -e
if [ "$hl_rc" -eq 2 ] && jq -e '.credential_fingerprint | startswith("unbindable-")' "$CACHE/agent-capability-o_r-nathanpayne-claude.json" >/dev/null 2>&1; then
  pass "no SHA-256 tool: fingerprint is unbindable and --check re-probes"
else
  fail "hashless: check rc=$hl_rc fp=$(jq -r .credential_fingerprint "$CACHE/agent-capability-o_r-nathanpayne-claude.json" 2>/dev/null)"
fi

# Switching the active gh account invalidates the cache (Codex on #1538).
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author STUB_KEYRING_ACTIVE=ghp_author -- >/dev/null 2>&1
set +e
run_probe GH_TOKEN=ghp_author STUB_KEYRING_ACTIVE=ghp_author -- --check >/dev/null 2>&1; same_rc=$?
run_probe GH_TOKEN=ghp_author STUB_KEYRING_ACTIVE=ghp_reviewer -- --check >/dev/null 2>&1; sw_rc=$?
set -e
if [ "$same_rc" -eq 0 ] && [ "$sw_rc" -eq 2 ]; then
  pass "a gh auth switch (different active account) invalidates the cache"
else
  fail "active account binding: same=$same_rc switched=$sw_rc"
fi

# #1540: GH_HOST is part of the cache identity, and the stored cross-repo
# target compares case-insensitively.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- --cross-repo Other/Repo >/dev/null 2>&1
set +e
run_probe GH_TOKEN=ghp_author -- --cross-repo other/repo --check >/dev/null 2>&1; case_rc=$?
run_probe GH_TOKEN=ghp_author GH_HOST=ghe.example.com -- --cross-repo Other/Repo --check >/dev/null 2>&1; host_rc=$?
set -e
if [ "$case_rc" -eq 0 ] && [ "$host_rc" -eq 2 ]; then
  pass "#1540: a cross-repo casing change keeps the cache; a GH_HOST change invalidates it"
else
  fail "#1540: casing=$case_rc gh_host=$host_rc"
fi

# Codex on #1541: with the opt-in, an unidentifiable token is not denied on
# its class; it continues through the same login, role and scope checks.
set +e
run_probe OP_PREFLIGHT_AUTHOR_PAT=opaque-author -- --no-cache >"$WORKDIR/opaque.json" 2>/dev/null
run_probe OP_PREFLIGHT_AUTHOR_PAT=opaque-author MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1 -- --no-cache >"$WORKDIR/opaque-in.json" 2>/dev/null
set -e
r_off="$(jq -r '.capabilities["author-writes"].reason' "$WORKDIR/opaque.json")"
r_on="$(jq -r '.capabilities["author-writes"].reason' "$WORKDIR/opaque-in.json")"
# Without the opt-in the resolver refuses the token outright; with it, the
# probe measures it through the login/role/scope checks (here it verifies the
# login and then stops on unreadable token permissions), never on its class.
if [ "$(jq -r '.capabilities["author-writes"].granted' "$WORKDIR/opaque.json")" = "false" ] \
   && ! printf '%s' "$r_on" | grep -q "cannot be established" \
   && printf '%s' "$r_on" | grep -q "^verified nathanjohnpayne"; then
  pass "opt-in: an unidentifiable token is measured through login/role/scope checks, not denied on its class"
else
  fail "opt-in grant: off=$r_off on=$r_on"
fi

# Codex on #1541: the write-token opt-in is part of the cache identity.
rm -rf "$CACHE"
run_probe GH_TOKEN=ghp_author -- >/dev/null 2>&1
set +e
run_probe GH_TOKEN=ghp_author -- --check >/dev/null 2>&1; same_rc=$?
run_probe GH_TOKEN=ghp_author MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1 -- --check >/dev/null 2>&1; optin_rc=$?
set -e
if [ "$same_rc" -eq 0 ] && [ "$optin_rc" -eq 2 ]; then
  pass "write-token opt-in: toggling it invalidates the capability cache"
else
  fail "opt-in cache identity: same=$same_rc optin=$optin_rc"
fi

echo
echo "agent-capability-probe tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
