#!/usr/bin/env bash
# tests/test_local_agent_handback.sh
#
# Regression suite for scripts/post-local-agent-handback.sh (#1057 item D).
#
# Runs the real script with the real reviewer wrapper (and its resolver,
# identity check and credential classifier) in a scratch repo, against a
# PATH-shimmed `gh` that records every call and answers the REST endpoints
# the handback uses. Stubs for the capability probe and the accounting
# script supply the state the comment records.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/local-agent-handback-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

FIX="$WORKDIR/repo"
mkdir -p "$FIX/scripts/lib" "$FIX/.github"
cp "$ROOT/scripts/post-local-agent-handback.sh" "$ROOT/scripts/gh-as-reviewer.sh" "$ROOT/scripts/identity-check.sh" "$FIX/scripts/"
cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$ROOT/scripts/lib/credential-class.sh" "$FIX/scripts/lib/"
cat >"$FIX/scripts/agent-capability-probe.sh" <<'P'
#!/usr/bin/env bash
printf 'export MERGEPATH_AGENT_TIER=%s\nexport MERGEPATH_AGENT_SURFACE_MEASURED=%s\n' "${STUB_TIER:-author-writes,reviewer-writes}" "${STUB_SURFACE:-claude-cloud}"
P
cat >"$FIX/scripts/review-feedback-accounting.sh" <<'A'
#!/usr/bin/env bash
echo "acct $*" >>"$GH_LOG"
echo '{"posted":7,"accounted":7}'
A
chmod +x "$FIX/scripts/"*.sh
SCRIPT="$FIX/scripts/post-local-agent-handback.sh"
HEAD=0123456789abcdef0123456789abcdef01234567

STUB_DIR="$WORKDIR/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf 'TOKEN=%s gh' "${GH_TOKEN:-}" >>"$GH_LOG"; for a in "$@"; do printf '\t%s' "$a" >>"$GH_LOG"; done; printf '\n' >>"$GH_LOG"
if [ "$1 $2" = "auth token" ]; then exit 1; fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  case "${GH_TOKEN:-}" in ghp_reviewer) echo nathanpayne-claude ;; ghp_other) echo someone-else ;; *) exit 4 ;; esac
  exit 0
fi
case "$*" in
  *"repos/o/r/pulls/12 --jq .head.sha"*)
    [ -n "${STUB_NO_HEAD:-}" ] && exit 1
    if [ -n "${STUB_HEAD_SEQ:-}" ]; then
      n=$(( $(cat "$GH_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$GH_LOG.n"
      set -- $STUB_HEAD_SEQ; [ "$n" -gt "$#" ] && n=$#; eval "echo \${$n}"; exit 0
    fi
    echo "$STUB_HEAD"; exit 0 ;;
  *"-X POST repos/o/r/issues/12/comments"*)
    [ -n "${STUB_POST_FAIL:-}" ] && exit 1
    for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$GH_BODY" ;; esac; done
    echo "{\"html_url\":\"https://github.com/o/r/pull/12#issuecomment-1\",\"user\":{\"login\":\"${STUB_POSTED_AS:-nathanpayne-claude}\"}}"
    exit 0 ;;
  *"-X POST repos/o/r/issues/12/labels"*) [ -n "${STUB_LABEL_FAIL:-}" ] && exit 1; echo '[]'; exit 0 ;;
  *"-X POST repos/o/r/labels"*) [ -n "${STUB_LABEL_CREATE_FAIL:-}" ] && exit 1; echo '{}'; exit 0 ;;
  "api repos/o/r/labels/needs-local-agent") [ -n "${STUB_LABEL_MISSING:-}" ] && exit 1; echo '{}'; exit 0 ;;
esac
echo "unexpected gh: $*" >&2
exit 9
STUB
chmod +x "$STUB_DIR/gh"

run() { # <env...> -- <args...>
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : >"$WORKDIR/gh.log"; rm -f "$WORKDIR/body.md" "$WORKDIR/gh.log.n"
  env -u GH_TOKEN -u GITHUB_TOKEN -u OP_PREFLIGHT_AUTHOR_PAT -u MERGEPATH_AGENT -u OP_PREFLIGHT_AGENT \
    -u CLAUDE_CODE_REMOTE_SESSION_ID -u GH_AS_REVIEWER_IDENTITY -u MERGEPATH_SESSION_URL \
    PATH="$STUB_DIR:$PATH" GH_LOG="$WORKDIR/gh.log" GH_BODY="$WORKDIR/body.md" STUB_HEAD="$HEAD" \
    OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer ${envs[@]+"${envs[@]}"} \
    "$SCRIPT" 12 --repo o/r "$@"
}

# --- happy path --------------------------------------------------------------
set +e
run CLAUDE_CODE_REMOTE_SESSION_ID=cse_abc123 -- --blocked graphql --next "scripts/resolve-pr-threads.sh 12 --resolve-actioned" >/dev/null 2>"$WORKDIR/err"
rc=$?
set -e
body="$(cat "$WORKDIR/body.md" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] \
   && printf '%s' "$body" | grep -q "<!-- mergepath-handback: v1 head=$HEAD blocked=graphql -->" \
   && printf '%s' "$body" | grep -q 'Blocked capability:\*\* `graphql`' \
   && printf '%s' "$body" | grep -q 'Session tier:\*\* `author-writes,reviewer-writes` (surface: `claude-cloud`)' \
   && printf '%s' "$body" | grep -q "Review feedback at this head:\*\* 7 posted, 7 accounted" \
   && printf '%s' "$body" | grep -q "https://claude.ai/code/session_abc123" \
   && printf '%s' "$body" | grep -q "scripts/resolve-pr-threads.sh 12 --resolve-actioned" \
   && printf '%s' "$body" | grep -q "only once the step it stands for has completed: a dispatch that returned is not completion" \
   && printf '%s' "$body" | grep -qF 'scripts/dispatch-thread-resolution-lane.sh 12` dispatches the lane and waits for its own run'; then
  pass "handback comment records capability, tier, head, accounting, session URL and the next command"
else
  fail "happy path: rc=$rc err=$(cat "$WORKDIR/err") body=$body"
fi
if grep -q $'TOKEN=ghp_reviewer gh\tapi\t-X\tPOST\trepos/o/r/issues/12/comments' "$WORKDIR/gh.log" \
   && grep -q $'TOKEN=ghp_reviewer gh\tapi\t-X\tPOST\trepos/o/r/issues/12/labels\t-f\tlabels\\[\\]=needs-local-agent' "$WORKDIR/gh.log"; then
  pass "comment and label are written through the reviewer wrapper with the verified reviewer token"
else
  fail "write path: $(cat "$WORKDIR/gh.log")"
fi
# The head read uses the provisioned PAT: a Codex task has no keyring and no
# ambient token (Codex on #1555).
if grep -q $'TOKEN=ghp_reviewer gh\tapi\trepos/o/r/pulls/12\t--jq\t.head.sha' "$WORKDIR/gh.log"; then
  pass "the head read is authenticated with the provisioned PAT, not an ambient token"
else
  fail "head read token: $(grep pulls/12 "$WORKDIR/gh.log")"
fi
if ! grep -q $'gh\tapi\tgraphql' "$WORKDIR/gh.log"; then
  pass "the handback issues no GraphQL request (it is for sessions that cannot)"
else
  fail "handback used GraphQL: $(grep graphql "$WORKDIR/gh.log")"
fi

# --- the label exists before anything is posted (Codex on #1555) -------------
lineno() { { grep -n -- "$1" "$WORKDIR/gh.log" || true; } | head -1 | cut -d: -f1; }
set +e
run STUB_LABEL_MISSING=1 -- --blocked graphql --next x >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
created="$(lineno $'POST\trepos/o/r/labels\t-f\tname=needs-local-agent')"
commented="$(lineno $'POST\trepos/o/r/issues/12/comments')"
if [ "$rc" -eq 0 ] && [ -n "$created" ] && [ -n "$commented" ] && [ "$created" -lt "$commented" ]; then
  pass "a repository without the label (a propagated consumer): the label is created before the comment is posted"
else
  fail "label create: rc=$rc created=$created commented=$commented log=$(cat "$WORKDIR/gh.log")"
fi
set +e
out="$(run STUB_LABEL_MISSING=1 STUB_LABEL_CREATE_FAIL=1 -- --blocked graphql --next x 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 4 ] && ! grep -q $'POST\trepos/o/r/issues/12/comments' "$WORKDIR/gh.log" \
   && printf '%s' "$out" | grep -q "## Needs a local agent" && grep -q "nothing was posted" "$WORKDIR/err"; then
  pass "label cannot be created: exit 4, nothing posted (no duplicate on retry), body on stdout"
else
  fail "label create failure: rc=$rc err=$(cat "$WORKDIR/err")"
fi

# --- the recorded state belongs to the head the comment names (CodeRabbit on #1555)
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
set +e
run STUB_HEAD_SEQ="$H1 $H2 $H2" -- --blocked graphql --next x >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
acct_runs="$(grep -c '^acct ' "$WORKDIR/gh.log" || true)"
if [ "$rc" -eq 0 ] && grep -q "head=$H2 blocked=graphql" "$WORKDIR/body.md" && ! grep -q "$H1" "$WORKDIR/body.md" \
   && [ "$acct_runs" -eq 2 ] && grep -q "head moved $H1 -> $H2" "$WORKDIR/err"; then
  pass "a push while state is collected: collection repeats on the new head, and the comment names that head"
else
  fail "head drift: rc=$rc acct_runs=$acct_runs err=$(cat "$WORKDIR/err")"
fi
set +e
run STUB_HEAD_SEQ="$H1 $H2 $H3 $H1 $H2" -- --blocked graphql --next x >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 3 ] && ! grep -q $'POST\trepos/o/r/issues/12/comments' "$WORKDIR/gh.log" && grep -q "kept moving" "$WORKDIR/err"; then
  pass "a head that keeps moving: exit 3, nothing posted"
else
  fail "head churn: rc=$rc err=$(cat "$WORKDIR/err")"
fi

# --- Codex provenance (Codex on #1555) --------------------------------------
set +e
out="$(run STUB_SURFACE=codex-cloud -- --blocked graphql --next x --print 2>/dev/null)"; r1=$?
out2="$(run STUB_SURFACE=codex-cloud -- --blocked graphql --next x --session-url https://chatgpt.com/codex/tasks/task_e_1 --print 2>/dev/null)"; r2=$?
run -- --blocked graphql --next x --session-url javascript:alert --print >/dev/null 2>&1; r3=$?
set -e
if [ "$r1" -eq 0 ] && printf '%s' "$out" | grep -q 'Session:\*\* `codex-cloud` session; no transcript URL was supplied (pass --session-url)' \
   && ! printf '%s' "$out" | grep -qi 'not a cloud session' \
   && [ "$r2" -eq 0 ] && printf '%s' "$out2" | grep -q 'Session:\*\* https://chatgpt.com/codex/tasks/task_e_1' \
   && [ "$r3" -eq 1 ]; then
  pass "a Codex task records its surface, takes --session-url, and refuses a non-https URL"
else
  fail "codex provenance: r1=$r1 r2=$r2 r3=$r3 out=$out out2=$out2"
fi

# --- the label is informational, never a gate ---------------------------------
if [ -r "$ROOT/scripts/lib/blocking-labels.sh" ]; then
  if bash -c '. "$1"; mergepath_is_blocking_label needs-local-agent' _ "$ROOT/scripts/lib/blocking-labels.sh"; then
    fail "needs-local-agent is a blocking label; it must stay informational"
  else
    pass "needs-local-agent is not a blocking label"
  fi
fi

# --- invocation errors ---------------------------------------------------------
set +e
run -- --blocked teleport --next x >/dev/null 2>&1; r1=$?
run -- --blocked graphql >/dev/null 2>&1; r2=$?
set -e
if [ "$r1" -eq 1 ] && [ "$r2" -eq 1 ] && [ ! -s "$WORKDIR/gh.log" ]; then
  pass "unknown capability or missing --next: exit 1 before any request"
else
  fail "invocation errors: unknown=$r1 no-next=$r2 log=$(cat "$WORKDIR/gh.log")"
fi

# --- no head, no handback --------------------------------------------------------
set +e
run STUB_NO_HEAD=1 -- --blocked graphql --next x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 3 ] && ! grep -q -- "-X"$'\t'"POST" "$WORKDIR/gh.log"; then
  pass "unreadable head SHA: exit 3, nothing posted"
else
  fail "no head: rc=$rc"
fi

# --- a post that fails leaves the body on stdout for relay ---------------------
set +e
out="$(run STUB_POST_FAIL=1 -- --blocked author-writes --next x 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 4 ] && printf '%s' "$out" | grep -q "## Needs a local agent"; then
  pass "post failure: exit 4 with the rendered handback on stdout"
else
  fail "post failure: rc=$rc out=$out"
fi

# --- a comment that lands under another login is not accepted -------------------
set +e
run STUB_POSTED_AS="claude[bot]" -- --blocked graphql --next x >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "landed under 'claude\[bot\]'" "$WORKDIR/err" \
   && ! grep -q "issues/12/labels" "$WORKDIR/gh.log"; then
  pass "comment attributed to another login: exit 5, not labelled"
else
  fail "author readback: rc=$rc err=$(cat "$WORKDIR/err")"
fi

# --- --print posts nothing ---------------------------------------------------------
set +e
out="$(run -- --blocked cross-repo --next "scripts/sync-to-downstream.sh --apply" --print 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'blocked=cross-repo' && ! grep -q -- "-X"$'\t'"POST" "$WORKDIR/gh.log"; then
  pass "--print renders the handback and posts nothing"
else
  fail "--print: rc=$rc"
fi

# --- the CI lane that resumes a graphql handback (#1057 G) ---------------------
LANE="$ROOT/.github/workflows/thread-resolution-lane.yml"
# The lane is read with mikefarah/yq v4 syntax. Another program named yq (the
# Python jq wrapper the Claude cloud image ships) is reported as such, never
# run into an abort mid-suite.
if [ -r "$LANE" ] && yq --version 2>/dev/null | grep -q 'mikefarah/yq'; then
  guard="$(yq -r '.jobs.resolve.if' "$LANE")"
  ref="$(yq -r '.jobs.resolve.steps[0].with.ref' "$LANE")"
  persist="$(yq -r '.jobs.resolve.steps[0].with."persist-credentials"' "$LANE")"
  perms="$(yq -o=json -I=0 '.permissions' "$LANE")"
  if [ "$guard" = "github.ref_name == github.event.repository.default_branch" ] \
     && [ "$ref" = '${{ github.event.repository.default_branch }}' ] \
     && [ "$persist" = "false" ] && [ "$perms" = '{"contents":"read"}' ]; then
    pass "lane runs only the default branch's definition and scripts, read-only, with no persisted checkout token"
  else
    fail "lane trust boundary drifted: if=$guard ref=$ref persist=$persist perms=$perms"
  fi
  # The trigger carries no ref, so a branch cannot run its own copy of the
  # lane with the reviewer PAT (Codex P1 on #1555, ADR 0002).
  triggers="$(yq -o=json -I=0 '.on | keys' "$LANE")"
  types="$(yq -o=json -I=0 '.on.repository_dispatch.types' "$LANE")"
  if [ "$triggers" = '["repository_dispatch"]' ] && [ "$types" = '["thread-resolution-lane"]' ]; then
    pass "lane is triggered only by repository_dispatch (default-branch copy only), never workflow_dispatch"
  else
    fail "lane triggers drifted: on=$triggers types=$types"
  fi
  # Each run is titled with its PR, which is what a resumer selects on.
  if [ "$(yq -r '."run-name"' "$LANE")" = 'Thread resolution lane: PR #${{ github.event.client_payload.pr }} [${{ github.event.client_payload.nonce }}]' ]; then
    pass "lane runs are titled per dispatch (PR and nonce), so the dispatcher selects exactly its own run"
  else
    fail "lane run-name drifted: $(yq -r '."run-name"' "$LANE")"
  fi
  run_step="$(yq -r '.jobs.resolve.steps[] | select(.name == "Resolve actioned threads") | .run' "$LANE")"
  if printf '%s' "$run_step" | grep -q -- '--resolve-actioned' \
     && ! printf '%s' "$run_step" | grep -q -- '--auto-resolve-bots' \
     && ! printf '%s' "$run_step" | grep -q -- '--resolve-verified-propagation'; then
    pass "lane resolves only demonstrably-actioned threads; deferral stays a local decision"
  else
    fail "lane runs a resolve mode other than --resolve-actioned"
  fi
  if grep -q 'PR_NUMBER: ${{ github.event.client_payload.pr }}' "$LANE" && ! grep -q 'resolve-pr-threads.sh "${{' "$LANE"; then
    pass "lane passes the PR input through the environment, never interpolated into the script"
  else
    fail "lane interpolates an input into its run script"
  fi
  # The lane binds the reviewer the stored token reads as, not a hard-coded
  # Claude, and refuses a non-reviewer token (Codex on #1555). Runs the real
  # step against a gh stub and a resolver stub that records what it was given.
  LFIX="$WORKDIR/lane"
  mkdir -p "$LFIX/scripts/lib" "$LFIX/bin" "$LFIX/.github"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$LFIX/scripts/lib/"
  printf 'available_reviewers:\n  - nathanpayne-claude\n  - nathanpayne-codex\n' >"$LFIX/.github/review-policy.yml"
  printf '%s\n' "$run_step" >"$LFIX/step.sh"
  cat >"$LFIX/scripts/resolve-pr-threads.sh" <<'R'
#!/usr/bin/env bash
echo "agent=${MERGEPATH_AGENT:-} identity=${GH_AS_REVIEWER_IDENTITY:-} args=$*" >>"$LANE_LOG"
R
  cat >"$LFIX/bin/gh" <<'G'
#!/usr/bin/env bash
[ "$1 $2" = "api user" ] && { [ -n "$LANE_LOGIN" ] && echo "$LANE_LOGIN"; exit 0; }
exit 9
G
  chmod +x "$LFIX/scripts/resolve-pr-threads.sh" "$LFIX/bin/gh"
  lane_run() { # <login>
    : >"$LFIX/lane.log"
    ( cd "$LFIX" && env -u MERGEPATH_AGENT -u GH_AS_REVIEWER_IDENTITY PATH="$LFIX/bin:$PATH" LANE_LOG="$LFIX/lane.log" LANE_LOGIN="$1" \
        GH_TOKEN=x OP_PREFLIGHT_REVIEWER_PAT=x PR_NUMBER=12 REPO=o/r GITHUB_STEP_SUMMARY="$LFIX/summary" bash step.sh ) >/dev/null 2>&1
  }
  set +e
  lane_run nathanpayne-codex; c1=$?; l1="$(cat "$LFIX/lane.log")"
  lane_run nathanjohnpayne; c2=$?; l2="$(cat "$LFIX/lane.log")"
  lane_run ""; c3=$?; l3="$(cat "$LFIX/lane.log")"
  lane_run nathanpayne-rogue; c4=$?; l4="$(cat "$LFIX/lane.log")"
  set -e
  if [ "$c1" -eq 0 ] && [ "$l1" = "agent=codex identity=nathanpayne-codex args=12 --repo o/r --resolve-actioned" ] \
     && [ "$c2" -ne 0 ] && [ -z "$l2" ] && [ "$c3" -ne 0 ] && [ -z "$l3" ] && [ "$c4" -ne 0 ] && [ -z "$l4" ]; then
    pass "lane resolves as the listed reviewer its token reads as, and refuses an author, unlisted reviewer-shaped or unreadable token before resolving"
  else
    fail "lane identity: codex rc=$c1 '$l1'; author rc=$c2 '$l2'; empty rc=$c3 '$l3'; unlisted rc=$c4 '$l4'"
  fi
else
  fail "thread-resolution-lane.yml missing, or no mikefarah/yq v4 to check it (yq on PATH: $(yq --version 2>&1 | head -1 || echo none); bash scripts/cloud-setup.sh installs it)"
fi

# --- dispatch-thread-resolution-lane.sh (#1057 G) -----------------------------
# The real script through the real author wrapper, against a gh stub that
# serves run lists from a sequence: the dispatch's own run must be found by
# its nonce (not the newest run), polled for until it is listed, and watched.
DFIX="$WORKDIR/dispatch"
mkdir -p "$DFIX/scripts/lib" "$DFIX/bin"
cp "$ROOT/scripts/dispatch-thread-resolution-lane.sh" "$ROOT/scripts/gh-as-author.sh" "$ROOT/scripts/identity-check.sh" "$DFIX/scripts/"
for f in gh-token-resolver.sh credential-class.sh gh-command-classifier.sh pr-body-contract.sh pr-body-contract.mjs reviewers-helpers.sh; do
  [ -f "$ROOT/scripts/lib/$f" ] && cp "$ROOT/scripts/lib/$f" "$DFIX/scripts/lib/"
done
cat >"$DFIX/bin/gh" <<'G'
#!/usr/bin/env bash
printf 'TOKEN=%s gh' "${GH_TOKEN:-}" >>"$D_LOG"; for a in "$@"; do printf '\t%s' "$a" >>"$D_LOG"; done; printf '\n' >>"$D_LOG"
if [ "$1 $2" = "auth token" ]; then exit 1; fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  case "${GH_TOKEN:-}" in ghp_author) echo nathanjohnpayne ;; *) exit 4 ;; esac; exit 0
fi
case "$1 $2" in
  "run "*) echo "gh run does not support fine-grained PATs" >&2; exit 1 ;;
  "api repos/o/r/actions/runs/222")
    n=$(( $(cat "$D_LOG.w" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$D_LOG.w"
    jq_expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && jq_expr="$a"; prev="$a"; done
    [ -n "${D_SLOW_REQUEST:-}" ] && sleep "$D_SLOW_REQUEST"
    if [ "$n" -lt 2 ]; then printf '{"status":"in_progress","conclusion":null}'
    elif [ -n "${D_RUN_FAILS:-}" ]; then printf '{"status":"completed","conclusion":"failure"}'
    elif [ -n "${D_RUN_HANGS:-}" ]; then printf '{"status":"queued","conclusion":null}'
    else printf '{"status":"completed","conclusion":"success"}'; fi | jq -r "$jq_expr"; exit 0 ;;
  "api -X")
    [ -n "${D_DISPATCH_FAIL:-}" ] && exit 1
    for a in "$@"; do case "$a" in client_payload\[nonce\]=*) echo "${a#*=}" >"$D_NONCE" ;; esac; done
    exit 0 ;;
  "api repos/o/r/actions/workflows/thread-resolution-lane.yml/runs?event=repository_dispatch&per_page=100")
    n=$(( $(cat "$D_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$D_LOG.n"
    nonce="$(cat "$D_NONCE" 2>/dev/null || true)"
    jq_expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && jq_expr="$a"; prev="$a"; done
    # An older run of the same PR is always listed first; this dispatch's own
    # run is listed only from poll D_APPEAR_AT on.
    runs='[{"id":111,"display_title":"Thread resolution lane: PR #12 [old-nonce]"}]'
    if [ -n "${D_APPEAR_AT:-}" ] && [ "$n" -ge "$D_APPEAR_AT" ]; then
      runs="[{\"id\":222,\"display_title\":\"Thread resolution lane: PR #12 [$nonce]\"},{\"id\":111,\"display_title\":\"Thread resolution lane: PR #12 [old-nonce]\"}]"
    fi
    printf '{"workflow_runs":%s}' "$runs" | jq -r "$jq_expr"; exit 0 ;;
esac
echo "unexpected gh: $*" >&2; exit 9
G
chmod +x "$DFIX/bin/gh"
drun() { # <env...> -- <args...>
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : >"$DFIX/d.log"; rm -f "$DFIX/d.log.n" "$DFIX/d.log.w" "$DFIX/nonce"
  env -u GH_TOKEN -u GITHUB_TOKEN -u MERGEPATH_AGENT -u GH_AS_AUTHOR_IDENTITY \
    PATH="$DFIX/bin:$PATH" D_LOG="$DFIX/d.log" D_NONCE="$DFIX/nonce" OP_PREFLIGHT_AUTHOR_PAT=ghp_author \
    OP_PREFLIGHT_REVIEWER_PAT=ghp_reviewer_classic \
    DISPATCH_LANE_POLL_INTERVAL=1 ${envs[@]+"${envs[@]}"} \
    "$DFIX/scripts/dispatch-thread-resolution-lane.sh" 12 --repo o/r "$@"
}
set +e
drun D_APPEAR_AT=3 -- >/dev/null 2>"$DFIX/err"; rc=$?
set -e
nonce="$(cat "$DFIX/nonce" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ -n "$nonce" ] \
   && grep -q $'TOKEN=ghp_author gh\tapi\t-X\tPOST\trepos/o/r/dispatches\t-f\tevent_type=thread-resolution-lane\t-F\tclient_payload\\[pr\\]=12' "$DFIX/d.log" \
   && [ "$(grep -c 'actions/workflows/thread-resolution-lane.yml/runs' "$DFIX/d.log")" -eq 3 ] \
   && grep -q $'TOKEN=ghp_reviewer_classic gh\tapi\trepos/o/r/actions/runs/222' "$DFIX/d.log" \
   && ! grep -q 'actions/runs/111' "$DFIX/d.log" && ! grep -q $'gh\trun\t' "$DFIX/d.log"; then
  pass "dispatch: sends a nonce through the author wrapper, polls until its own run is listed, and follows that run over REST with the classic reviewer PAT (never gh run, never the older run)"
else
  fail "dispatch happy path: rc=$rc nonce=$nonce err=$(cat "$DFIX/err") log=$(cat "$DFIX/d.log")"
fi
set +e
drun -- --appear-timeout 2 >/dev/null 2>"$DFIX/err"; r_none=$?
drun D_APPEAR_AT=1 D_RUN_FAILS=1 -- >/dev/null 2>/dev/null; r_fail=$?
drun D_DISPATCH_FAIL=1 -- >/dev/null 2>/dev/null; r_refused=$?
drun D_APPEAR_AT=1 D_RUN_HANGS=1 -- --watch-timeout 2 >/dev/null 2>/dev/null; r_hang=$?
# Request time counts against the deadline: with 2s requests and a 3s
# budget, sleep-only accounting would poll about four times (8s+).
t0=$SECONDS
drun D_APPEAR_AT=1 D_RUN_HANGS=1 D_SLOW_REQUEST=2 -- --watch-timeout 3 >/dev/null 2>/dev/null; r_slow=$?
t_slow=$(( SECONDS - t0 ))
out="$(drun D_APPEAR_AT=1 -- --no-wait 2>/dev/null)"; r_nowait=$?
set -e
if [ "$r_none" -eq 6 ] && [ "$r_hang" -eq 9 ] && [ "$r_slow" -eq 9 ] && [ "$t_slow" -le 6 ] \
   && [ "$r_fail" -eq 8 ] && [ "$r_refused" -eq 4 ] && [ "$r_nowait" -eq 0 ] && [ "$out" = "222" ]; then
  pass "dispatch: own run never listed -> exit 6 (the older run is not watched); run failed -> 8; never completes -> 9 (a wall-clock deadline that counts request time); dispatch refused -> 4; --no-wait prints the run id"
else
  fail "dispatch exits: none=$r_none hang=$r_hang slow=$r_slow/${t_slow}s fail=$r_fail refused=$r_refused nowait=$r_nowait out=$out"
fi

# Nothing sent is not GitHub refusing: a missing author token is named as
# such (and, in a cloud session, with the variable to set), and only a refusal
# from gh itself keeps the permission hint.
set +e
drun OP_PREFLIGHT_AUTHOR_PAT= CLAUDE_CODE_REMOTE=true -- >/dev/null 2>"$DFIX/err"; r_notoken=$?
set -e
if [ "$r_notoken" -eq 4 ] && grep -q "no author token was found, so nothing was dispatched to o/r" "$DFIX/err" \
   && grep -q "set OP_PREFLIGHT_AUTHOR_PAT in the cloud environment's settings" "$DFIX/err" \
   && ! grep -q "needs Contents: write" "$DFIX/err" && ! grep -q $'\t-X\tPOST' "$DFIX/d.log"; then
  pass "dispatch: no author token -> exit 4 naming the missing token (and the cloud variable to set), nothing dispatched"
else
  fail "dispatch no token: rc=$r_notoken err=$(cat "$DFIX/err")"
fi
set +e
drun D_DISPATCH_FAIL=1 -- >/dev/null 2>"$DFIX/err"; r_refused=$?
set -e
if [ "$r_refused" -eq 4 ] && grep -q "was refused; the author PAT needs Contents: write" "$DFIX/err"; then
  pass "dispatch: GitHub refusing the dispatch keeps the permission hint"
else
  fail "dispatch refused message: rc=$r_refused err=$(cat "$DFIX/err")"
fi

echo
echo "test_local_agent_handback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
