#!/usr/bin/env bash
# Unit tests for scripts/gh-as-author.sh token-based attribution.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/gh-as-author.sh"
COMMAND_CLASSIFIER="$ROOT/scripts/lib/gh-command-classifier.sh"

[[ -x "$WRAPPER" ]] || { echo "missing or non-executable $WRAPPER" >&2; exit 1; }
[[ -r "$COMMAND_CLASSIFIER" ]] || { echo "missing $COMMAND_CLASSIFIER" >&2; exit 1; }

# shellcheck source=../scripts/lib/gh-command-classifier.sh
. "$COMMAND_CLASSIFIER"

# #996: the gh stub below records whichever token the wrapper selected, and
# several failure branches print that log. Every case pins its own token
# inline, but gh-as-author.sh reads the AMBIENT OP_PREFLIGHT_AUTHOR_PAT and
# GH_TOKEN when a case does not — so on an agent machine with a warm
# preflight cache a real credential could reach the log, and a failing
# assertion would print it. Scrub the ambient credential environment once
# here so "the log holds a fixture token" is true by construction rather
# than by the stub happening to reject the ambient one. Per-case `VAR=...`
# prefixes still apply; this only changes the default.
unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT GH_TOKEN GITHUB_TOKEN

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-author-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

assert_prohibited_source() {
  local label="$1" source="$2" mode="${3:-}"
  if printf '%s\n' "$source" \
      | gh_source_lacks_direct_literal_pr_mutation "$mode"; then
    fail "direct-literal mutation classifier missed $label"
  else
    pass "direct-literal mutation classifier rejects $label"
  fi
}

assert_allowed_source() {
  local label="$1" source="$2" mode="${3:-}"
  if printf '%s\n' "$source" \
      | gh_source_lacks_direct_literal_pr_mutation "$mode"; then
    pass "direct-literal mutation classifier permits $label"
  else
    fail "direct-literal mutation classifier over-rejected $label"
  fi
}

assert_prohibited_source "bare native merge" 'gh pr merge 7 --squash'
assert_prohibited_source "path-qualified native merge" '/opt/bin/gh pr merge 7'
assert_prohibited_source "prefixed native merge" 'env GH_TOKEN=x gh pr merge 7'
assert_prohibited_source "globally flagged native merge" 'gh --repo owner/repo pr merge 7'
assert_prohibited_source "attached global short repo flag native merge" \
  'gh -Rowner/repo pr merge 7 --squash'
assert_prohibited_source "attached PR short repo flag native merge" \
  'gh pr -Rowner/repo merge 7 --squash'
assert_prohibited_source "line-wrapped native merge" $'gh pr \\\n  merge 7'
assert_prohibited_source "token-internal continuation cannot split gh" \
  $'g\\\nh pr merge 7'
assert_prohibited_source "token-internal continuation cannot split pr" \
  $'gh p\\\nr merge 7'
assert_prohibited_source "token-internal continuation cannot split merge" \
  $'gh pr m\\\nerge 7'
assert_prohibited_source "token-internal continuation cannot split api" \
  $'gh a\\\npi repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "compact REST PUT" 'gh api -XPUT repos/o/r/pulls/7/merge'
assert_prohibited_source "spaced REST PUT after endpoint" 'gh api repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "equal-form REST POST" 'gh api --method=POST repos/o/r/pulls/7/merge'
assert_prohibited_source "quoted lowercase REST method" 'gh api repos/o/r/pulls/7/merge --method "patch"'
assert_prohibited_source "implicit REST POST from a raw field" \
  'gh api repos/o/r/pulls/7/merge -f merge_method=squash'
assert_prohibited_source "implicit REST POST from an input file" \
  'gh api repos/o/r/pulls/7/merge --input payload.json'
assert_prohibited_source "opaque REST method" \
  'METHOD=PUT; gh api --method "$METHOD" repos/o/r/pulls/7/merge'
assert_prohibited_source "opaque REST method followed by an unrelated GET" \
  'METHOD=PUT; gh api --method "$METHOD" repos/o/r/pulls/7/merge; gh api -X GET repos/o/r/pulls/7'
assert_prohibited_source "multiple REST method flags" \
  'gh api -X GET --method "$METHOD" repos/o/r/pulls/7/merge'
assert_prohibited_source "opaque REST argument array" \
  'ARGS=(--method PUT); gh api "${ARGS[@]}" repos/o/r/pulls/7/merge'
assert_prohibited_source "opaque implicit-write argument array" \
  'ARGS=(-f merge_method=squash); gh api repos/o/r/pulls/7/merge "${ARGS[@]}"'
assert_prohibited_source "opaque REST wrapper arguments" \
  'run_api(){ gh api "$@"; }; run_api repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "opaque native PR verb" \
  'VERB=merge; gh pr "$VERB" 7'
assert_prohibited_source "concatenated dynamic gh command group" \
  'GROUP=pi; gh a"$GROUP" repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "concatenated dynamic native PR verb" \
  'VERB=erge; gh pr m"$VERB" 7'
assert_prohibited_source "concatenated dynamic REST flag" \
  'FLAG=method; gh api --"$FLAG" PUT repos/o/r/pulls/7/merge'
assert_prohibited_source "concatenated dynamic GraphQL endpoint" \
  'GROUP=raphql; gh api g"$GROUP" -f query="mutation { mergePullRequest(input: {}) { clientMutationId } }"'
assert_prohibited_source "escaped gh executable spelling" \
  'g\h pr merge 7'
assert_prohibited_source "escaped REST group spelling" \
  'gh a\pi repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "escaped native PR verb spelling" \
  'gh pr m\erge 7'
assert_prohibited_source "quoted gh executable concatenation" \
  'g"h" pr merge 7'
assert_prohibited_source "quoted REST group concatenation" \
  'gh a"pi" repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "quoted native PR verb concatenation" \
  'gh pr m"erge" 7'
assert_prohibited_source "separately quoted native command tokens" \
  'gh "pr" "merge" 7'
assert_prohibited_source "mixed quoted native command tokens" \
  'g"h" "pr" m"erge" 7'
assert_prohibited_source "separately quoted REST write tokens" \
  '"gh" "api" repos/o/r/pulls/7/merge "-X" "PUT"'
assert_prohibited_source "nested executable quoted token concatenation" \
  'echo "$(g"h" "pr" m"erge" 7)"'
assert_prohibited_source "apostrophe in a preceding comment cannot mask a dynamic PR verb" \
  $'# it\'s inert commentary\nVERB=merge; gh pr "$VERB" 7'
assert_prohibited_source "ANSI-C quoted gh executable concatenation" \
  "g\$'h' pr merge 7"
assert_prohibited_source "locale quoted gh executable concatenation" \
  'g$"h" pr merge 8'
assert_prohibited_source "literal native merge in backtick substitution" \
  'echo `gh pr merge 7`'
assert_prohibited_source "literal REST write in backtick substitution" \
  'x=`gh api repos/o/r/pulls/7/merge -X PUT`'
assert_prohibited_source "double quotes do not hide a backtick native merge" \
  'echo "`gh pr merge 7`"'
assert_prohibited_source "nested legacy backticks cannot hide a native merge" \
  'echo `echo \`gh pr merge 7\``'
assert_prohibited_source "double quotes do not hide nested legacy backticks" \
  'echo "`echo \`gh pr merge 7\``"'
assert_allowed_source "escaped backticks remain literal data" \
  'printf "%s\n" "\`gh pr merge 7\`"'
assert_prohibited_source "source text cannot collide with lexer markers" \
  'echo MERGEPATH_CLASSIFIER_LITERAL_NEWLINE MERGEPATH_CLASSIFIER_LITERAL_XNEWLINE; gh pr merge 7'
assert_prohibited_source "legacy backtick heredoc cannot poison quote state" \
  $'echo "`cat <<EOF\n\'\nEOF\ngh pr merge 7\n`"'
assert_prohibited_source "gh alias definition followed by opaque invocation" \
  "gh alias set m 'pr merge'; gh m 7"
assert_prohibited_source "gh alias import can install an opaque merger" \
  'gh alias import aliases.yml; gh m 7'
assert_prohibited_source "dynamic gh alias action cannot hide installation" \
  "ACTION=set; gh alias \"\$ACTION\" m 'pr merge'; gh m 7"
assert_prohibited_source "clustered REST method flag" \
  'gh api repos/o/r/pulls/7/merge -iXPUT'
assert_prohibited_source "clustered implicit-write field flag" \
  'gh api repos/o/r/pulls/7/merge -iFmerge_method=squash'
LT_PAIR='<''<'
HEREDOC_OPEN="cat ${LT_PAIR}EOF"
ADJACENT_HEREDOC_OPEN="cat${LT_PAIR}EOF"
ADJACENT_STRIPPING_HEREDOC_OPEN="cat${LT_PAIR}-EOF"
assert_prohibited_source "heredoc data cannot mask a later literal merge" \
  "$HEREDOC_OPEN"$'\n\'\nEOF\ngh pr merge 7 --squash'
assert_prohibited_source "adjacent heredoc data cannot mask a later literal merge" \
  "$ADJACENT_HEREDOC_OPEN"$'\n\'\nEOF\ngh pr merge 7 --squash'
assert_prohibited_source "adjacent stripping heredoc cannot mask a later literal merge" \
  "$ADJACENT_STRIPPING_HEREDOC_OPEN"$'\n\t\'\nEOF\ngh pr merge 7 --squash'
assert_prohibited_source "array-shaped command argument remains a real heredoc" \
  "echo a[1${LT_PAIR}EOF]=x"$'\n\'\nEOF]=x\ngh pr merge 7 --squash'
assert_prohibited_source "digit-prefixed assignment lookalike remains a real heredoc" \
  "1a[1${LT_PAIR}EOF x]=y || true"$'\n\'\nEOF\ngh pr merge 7 --squash'
assert_prohibited_source "spaced assignment lookalike remains a real heredoc" \
  "a[1${LT_PAIR}EOF x]=y || true"$'\n\'\nEOF\ngh pr merge 7 --squash'
assert_prohibited_source "quoted arithmetic state cannot hide a later heredoc" \
  $': $((a["("]))\ncat <<EOF\n\'\nEOF\ngh pr merge 7 --squash'
assert_prohibited_source "quoted parameter state cannot hide a later heredoc" \
  $': ${x:-"{"}\ncat <<EOF\n\'\nEOF\ngh pr merge 7 --squash'
assert_allowed_source "explicit REST GET with a field" \
  'gh api repos/o/r/pulls -X GET -f state=open'
assert_allowed_source "REST GET followed by an unrelated rm flag" \
  $'gh api repos/o/r/pulls/7 --jq .state\nrm -f scratch'
assert_allowed_source "REST GET containing dash-f text" \
  "gh api 'repos/o/r/issues/comments?labels=needs-fix' --jq '.foo-far'"
assert_allowed_source "REST GET with an escaped literal jq dollar" \
  'gh api repos/o/r/pulls/7 --jq \$.state'
assert_allowed_source "an inert commented REST write" \
  '# gh api repos/o/r/pulls/7/merge -X PUT'
assert_allowed_source "double-quoted native mutation prose is one argument" \
  'echo "gh pr merge 7"'
assert_allowed_source "double-quoted REST mutation prose is one argument" \
  'printf "%s\n" "gh api repos/o/r/pulls/7/merge -X PUT"'
assert_allowed_source "a quoted multiword PR group remains one argument" \
  'gh "pr merge" 7'
assert_allowed_source "a quoted multiword PR verb remains one argument" \
  'gh pr "merge 7"'
assert_allowed_source "a quoted separator remains inert data" \
  'echo "safe; gh pr merge 7"'
assert_allowed_source "a quoted physical newline remains inert data" \
  $'echo "safe\ngh" pr merge 7'
assert_allowed_source "a here-string remains ordinary read-only syntax" \
  'value=$(gh api repos/o/r/pulls/7 --jq .state); jq -e . <<<"$value"'
assert_allowed_source "command lookup does not execute its dynamic operand" \
  'command -v "$tool" >/dev/null; gh api repos/o/r/pulls/7 --jq .state'
assert_allowed_source "nested command substitution preserves parameter quote state" \
  'ROOT="${MERGEPATH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"; gh api repos/o/r/pulls/7 --jq .state'
assert_allowed_source "quoted GitHub-output heredoc marker text is data" \
  "echo 'prs${LT_PAIR}EOF'"
assert_allowed_source "double-quoted heredoc-like text is data" \
  "echo \"literal ${LT_PAIR}EOF\""
assert_allowed_source "inline-comment heredoc-like text is inert" \
  "echo ok # cat ${LT_PAIR}EOF"
assert_allowed_source "arithmetic expansion left shift is not a heredoc" \
  "x=\$((1${LT_PAIR}2)); echo \"\$x\""
assert_allowed_source "arithmetic command left shift is not a heredoc" \
  "((x=1${LT_PAIR}2)); echo \"\$x\""
assert_allowed_source "legacy arithmetic expansion left shift is not a heredoc" \
  "x=\$[1${LT_PAIR}2]; echo \"\$x\""
assert_allowed_source "array-subscript left shift is not a heredoc" \
  "a[1${LT_PAIR}2]=x; echo \"\${a[4]}\""
assert_allowed_source "parameter-substring left shift is not a heredoc" \
  "echo \${x:1${LT_PAIR}2}"

for graphql_operation in \
  addPullRequestToMergeQueue enqueuePullRequest dequeuePullRequest \
  enablePullRequestAutoMerge disablePullRequestAutoMerge mergePullRequest; do
  graphql_source=$(printf \
    "gh api graphql -f query='mutation QueueChange {\n  %s(input: {}) { clientMutationId }\n}'" \
    "$graphql_operation")
  assert_prohibited_source "multiline GraphQL $graphql_operation" \
    "$graphql_source"
done

EXPECTED_LABEL_DELETE='del_out=$(gh api "repos/$REPO/issues/$PR/labels/needs-external-review" -X DELETE -i --silent 2>/dev/null || true)'
assert_prohibited_source "label DELETE without its explicit exception" \
  "$EXPECTED_LABEL_DELETE"
assert_allowed_source "the exact needs-external-review label DELETE" \
  "$EXPECTED_LABEL_DELETE" --allow-needs-external-review-delete
assert_prohibited_source "a different label DELETE" \
  'gh api "repos/$REPO/issues/$PR/labels/human-hold" -X DELETE -i --silent 2>/dev/null || true' \
  --allow-needs-external-review-delete
assert_prohibited_source "a POST to the exempt label endpoint" \
  'gh api "repos/$REPO/issues/$PR/labels/needs-external-review" -X POST -i --silent 2>/dev/null || true' \
  --allow-needs-external-review-delete
assert_prohibited_source "an exempt DELETE chained with a second API write" \
  "$EXPECTED_LABEL_DELETE; gh api repos/o/r/pulls/7/merge -X PUT" \
  --allow-needs-external-review-delete
assert_prohibited_source "two copies of the exempt DELETE" \
  "$EXPECTED_LABEL_DELETE; $EXPECTED_LABEL_DELETE" \
  --allow-needs-external-review-delete
assert_prohibited_source "a suffixed exempt endpoint" \
  'gh api "repos/$REPO/issues/$PR/labels/needs-external-review/extra" -X DELETE -i --silent 2>/dev/null || true' \
  --allow-needs-external-review-delete

assert_allowed_source "a REST GET" 'gh api repos/o/r/pulls/7 --jq .state'
assert_allowed_source "a GraphQL query" \
  "gh api graphql -f query='query ReadPr { repository { name } }'"
assert_allowed_source "a literal GraphQL query with variables" \
  "gh api graphql -f query='query Read(\$owner: String!) { repository(owner: \$owner) { name } }' -F owner=o"
assert_allowed_source "unrelated mutation prose cannot taint a GraphQL read" \
  "gh api graphql -f query='query ReadPr { repository { name } }'"$'\necho "mutation"'
assert_prohibited_source "an opaque GraphQL query variable" \
  'gh api graphql -f query="$QUERY"'
assert_prohibited_source "a literal GraphQL prefix with a dynamic suffix" \
  'gh api graphql -f query='\''query Safe { viewer { login } } '\''"$(payload)" -f operationName=Exploit'
assert_prohibited_source "a literal GraphQL prefix with a simple dynamic suffix" \
  'gh api graphql -f query='\''query Safe { viewer { login } } '\''"$PAYLOAD"'
assert_prohibited_source "a GraphQL input file" \
  'gh api graphql --input payload.json'
assert_allowed_source "a native PR read" 'gh pr view 7 --json autoMergeRequest'
assert_allowed_source "an inert mutation-name string" \
  'echo enablePullRequestAutoMerge'
assert_prohibited_source "an invalid classifier mode fails closed" \
  'gh api repos/o/r/pulls/7' --unsupported-mode

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
printf 'GH_TOKEN=%s GITHUB_TOKEN=%s gh' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" >> "$LOG"  # TOKEN_OUTPUT_EXEMPT: records the token the wrapper selected, which every case pins inline and asserts on exactly; the ambient credential env is scrubbed above (#996)
for a in "$@"; do
  printf '\t%s' "$a" >> "$LOG"
done
printf '\n' >> "$LOG"

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "switch" ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  user=""
  shift 2
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--user" ]; then
      shift
      user="${1:-}"
      break
    fi
    shift
  done
  case "$user" in
    nathanjohnpayne) printf '%s\n' "fallback-author-token" ;;
    custom-author) printf '%s\n' "fallback-custom-author-token" ;;
    *) exit 3 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  case "${GH_TOKEN:-}" in
    author-token|fallback-author-token) printf '%s\n' "nathanjohnpayne" ;;
    fallback-custom-author-token) printf '%s\n' "custom-author" ;;
    reviewer-token) printf '%s\n' "nathanpayne-claude" ;;
    *) exit 4 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "pr" ] && { [ "${2:-}" = "create" ] || [ "${2:-}" = "new" ]; }; then
  echo "${GH_CREATE_PR_URL:-https://github.com/example/repo/pull/42}"
  exit "${GH_CREATE_PR_RC:-0}"
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  rc="${GH_VIEW_RC:-0}"
  if [ "$rc" -ne 0 ]; then exit "$rc"; fi
  printf '%s\n' "${GH_VIEW_AUTHOR:-nathanjohnpayne}"
  exit 0
fi

exit "${GH_GENERIC_RC:-0}"
STUB
chmod +x "$STUB_DIR/gh"

cat >"$STUB_DIR/sudo" <<'SUDO_STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -b|--background) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
SUDO_STUB
chmod +x "$STUB_DIR/sudo"

run_wrapper() {
  PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$WRAPPER" "$@"
}

reset_log() {
  : > "$WORKDIR/calls.log"
}

reset_log
OP_PREFLIGHT_AUTHOR_PAT="author-token" GITHUB_TOKEN="ambient-token" \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "merge happy path: rc=$rc"
elif grep -q $'gh\tauth\tswitch' "$WORKDIR/calls.log"; then
  fail "merge happy path: called gh auth switch"
elif ! grep -q $'GH_TOKEN=author-token GITHUB_TOKEN= gh\tpr\tmerge\t123\t--squash' "$WORKDIR/calls.log"; then
  fail "merge happy path: wrapped command did not run with author token and GITHUB_TOKEN unset"
  cat "$WORKDIR/calls.log" >&2
else
  pass "merge happy path: verified author token, no keyring switch, ambient GITHUB_TOKEN cleared"
fi

reset_log
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" --body $'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create verification: rc=$rc"
elif ! grep -q $'GH_TOKEN=author-token GITHUB_TOKEN= gh\tpr\tview\t77\t--repo\texample/repo\t--json\tauthor\t--jq\t.author.login' "$WORKDIR/calls.log"; then
  fail "pr create verification: did not verify author with same token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "pr create verification: post-create read uses same author token"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh pr create --title "t" --body "## Self-Review" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr create contract: rc=$rc expected 1"
elif ! echo "$stderr_capture" | grep -q "Authoring-Agent"; then
  fail "pr create contract: missing actionable Authoring-Agent diagnostic"
elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "pr create contract: create ran despite invalid body"
else
  pass "pr create contract: invalid inline body blocked before write"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh pr new --title "t" --body "INVALID" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr new alias contract: rc=$rc expected 1"
elif grep -q $'gh\tpr\tnew' "$WORKDIR/calls.log"; then
  fail "pr new alias contract: create alias ran despite invalid body"
else
  pass "pr new alias contract: invalid body blocked before write"
fi

# Every prefix shape the pre-write guard delegates to this wrapper must still
# enter the create-only validation path. Otherwise an invalid body reaches the
# generic command runner while the guard believes validation happens here.
for prefixed_create in \
  "command -p gh pr create" \
  "sudo -n gh pr create" \
  "time -p gh pr create" \
  "nohup gh pr create" \
  "nice -n 5 gh pr create" \
  "ionice -c 2 gh pr create"; do
  reset_log
  set +e
  # These are deliberately plain words: the wrapper must reject the invalid
  # body before attempting to execute any prefix utility.
  stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
    run_wrapper -- $prefixed_create --title "t" --body "INVALID" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    fail "prefixed pr create contract ($prefixed_create): rc=$rc expected 1"
  elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
    fail "prefixed pr create contract ($prefixed_create): write ran despite invalid body"
  else
    pass "prefixed pr create contract ($prefixed_create): invalid body blocked before write"
  fi
done

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh pr create --title "t" \
    --body $'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' \
    -bINVALID 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr create contract: attached -b form rc=$rc expected 1"
elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "pr create contract: attached invalid -b body bypassed validation"
else
  pass "pr create contract: attached -b body is validated as the effective body"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh pr create --title "t" -dbINVALID \
    --body $'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr create contract: clustered body flag rc=$rc expected 1"
elif ! echo "$stderr_capture" | grep -q "ambiguous clustered short option"; then
  fail "pr create contract: clustered body flag missing actionable diagnostic"
elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "pr create contract: clustered body flag reached the write"
else
  pass "pr create contract: clustered short body flags are rejected before write"
fi

reset_log
VALID_INLINE_BODY=$'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.'
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/76" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" "-b=$VALID_INLINE_BODY" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create contract: equals-separated -b body should pass; rc=$rc"
else
  pass "pr create contract: equals-separated -b strips its optional equals sign"
fi

reset_log
INVALID_BODY_FILE="$WORKDIR/invalid-pr-body.md"
printf '%s\n' 'INVALID' >"$INVALID_BODY_FILE"
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh pr create --title "t" \
    --body $'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' \
    "-F$INVALID_BODY_FILE" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr create contract: attached -F form rc=$rc expected 1"
elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "pr create contract: attached invalid -F body file bypassed validation"
else
  pass "pr create contract: attached -F body file is validated as the effective body"
fi

reset_log
VALID_EQUALS_BODY_FILE="$WORKDIR/valid-equals-pr-body.md"
printf '%s\n' 'Authoring-Agent: codex' '' '## Self-Review' '' '- Correctness: verified.' >"$VALID_EQUALS_BODY_FILE"
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" "-F=$VALID_EQUALS_BODY_FILE" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create contract: equals-separated -F body file should pass; rc=$rc"
else
  pass "pr create contract: equals-separated -F strips its optional equals sign"
fi

reset_log
TEMPLATE_FILE="$WORKDIR/Form.md"
printf '%s\n' 'ignored template fixture' >"$TEMPLATE_FILE"
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" "-T$TEMPLATE_FILE" --body "$VALID_INLINE_BODY" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create contract: attached -T template should pass; rc=$rc"
elif ! grep -q -- "-T$TEMPLATE_FILE" "$WORKDIR/calls.log"; then
  fail "pr create contract: attached -T template was not preserved"
else
  pass "pr create contract: attached -T is a template value, not an ambiguous -F body flag"
fi

for boolean_flag in -d -f; do
  reset_log
  OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
    run_wrapper -- gh pr create "$boolean_flag" --title "t" --body "$VALID_INLINE_BODY" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "pr create contract: unrelated boolean flag $boolean_flag should pass; rc=$rc"
  else
    pass "pr create contract: unrelated boolean flag $boolean_flag is not a body cluster"
  fi
done

for interactive_flag in -e --editor -w --web; do
  reset_log
  set +e
  stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
    run_wrapper -- gh pr create "$interactive_flag" --title "t" --body "$VALID_INLINE_BODY" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    fail "pr create contract: interactive flag $interactive_flag rc=$rc expected 1"
  elif ! echo "$stderr_capture" | grep -q "interactive PR creation mode"; then
    fail "pr create contract: interactive flag $interactive_flag missing actionable diagnostic"
  elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
    fail "pr create contract: interactive flag $interactive_flag reached the write"
  else
    pass "pr create contract: interactive flag $interactive_flag cannot mutate the validated body"
  fi
done

reset_log
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/79" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- sudo -b gh pr create --title "t" --body "$VALID_INLINE_BODY" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "prefixed pr create contract (sudo -b): valid body should pass; rc=$rc"
elif ! grep -q $'gh\tpr\tcreate\t--title\tt\t--body\tAuthoring-Agent: codex' "$WORKDIR/calls.log"; then
  fail "prefixed pr create contract (sudo -b): prefix flag was mistaken for a PR body flag"
else
  pass "prefixed pr create contract (sudo -b): prefix flags remain outside PR body parsing"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh pr create --body INVALID --title \
    $'-bAuthoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr create contract: title value beginning -b rc=$rc expected 1"
elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "pr create contract: title value beginning -b bypassed invalid body validation"
else
  pass "pr create contract: values consumed by non-body flags cannot masquerade as body flags"
fi

reset_log
BODY_FILE="$WORKDIR/pr-body.md"
printf '%s\n' 'Authoring-Agent: codex' '' '## Self-Review' '' '- Correctness: verified.' >"$BODY_FILE"
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/78" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" --body-file "$BODY_FILE" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create contract: valid body file should pass; rc=$rc"
elif grep -q -- "--body-file\|$BODY_FILE" "$WORKDIR/calls.log"; then
  fail "pr create contract: body file path was read again by the wrapped command"
  cat "$WORKDIR/calls.log" >&2
elif ! grep -q $'gh\tpr\tcreate\t--title\tt\t--body\tAuthoring-Agent: codex' "$WORKDIR/calls.log"; then
  fail "pr create contract: captured body file snapshot was not passed inline"
  cat "$WORKDIR/calls.log" >&2
else
  pass "pr create contract: body file is validated once and passed as the captured snapshot"
fi

reset_log
VALID_STDIN_BODY=$'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.'
printf '%s' "$VALID_STDIN_BODY" | \
  OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/79" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" -F /dev/stdin >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create contract: /dev/stdin body snapshot should pass; rc=$rc"
elif grep -q -- "/dev/stdin\|\t-F\t" "$WORKDIR/calls.log"; then
  fail "pr create contract: /dev/stdin was passed to the wrapped command for a second read"
  cat "$WORKDIR/calls.log" >&2
elif ! grep -q $'gh\tpr\tcreate\t--title\tt\t--body\tAuthoring-Agent: codex' "$WORKDIR/calls.log"; then
  fail "pr create contract: captured stdin snapshot was not passed inline"
  cat "$WORKDIR/calls.log" >&2
else
  pass "pr create contract: stdin is validated once and passed as the captured snapshot"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  run_wrapper -- gh --repo example/repo pr create --title "t" --body "## Self-Review" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "pr create contract: global --repo form rc=$rc expected 1"
elif grep -q $'gh\t--repo\texample/repo\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "pr create contract: global --repo create ran despite invalid body"
else
  pass "pr create contract: global --repo form cannot bypass validation"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/88" GH_VIEW_AUTHOR="nathanpayne-claude" \
  run_wrapper -- gh pr create --title "t" --body $'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 5 ]; then
  fail "pr create mismatch: rc=$rc expected 5"
elif ! echo "$stderr_capture" | grep -q "effective token"; then
  fail "pr create mismatch: missing effective-token diagnostic"
else
  pass "pr create mismatch: fail-closed with token diagnostic"
fi

reset_log
unset OP_PREFLIGHT_AUTHOR_PAT
run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "fallback token: rc=$rc"
elif ! grep -q $'GH_TOKEN=fallback-author-token GITHUB_TOKEN= gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  fail "fallback token: did not use gh auth token --user fallback"
  cat "$WORKDIR/calls.log" >&2
else
  pass "fallback token: uses gh auth token --user without switching"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="reviewer-token" run_wrapper -- gh pr merge 123 --squash 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "wrong preferred token: expected non-zero"
elif grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  fail "wrong preferred token: wrapped write ran despite failed verification"
  cat "$WORKDIR/calls.log" >&2
else
  pass "wrong preferred token: fails before wrapped write"
fi

reset_log
set +e
run_wrapper -- >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "empty command: exits 1"
else
  fail "empty command: rc=$rc expected 1"
fi

# --- runtime byline pin (#438) ----------------------------------------
# Runs IN the wrapper process: environment-manipulation-proof, unlike
# the PreToolUse hook's static analysis.

# The pin resolves the policy from the WRAPPER's repo root (r20), so
# each fixture repo gets its own copy of the wrapper + its lib deps.
install_wrapper_copy() {
  local dir=$1
  mkdir -p "$dir/scripts/lib" "$dir/.github"
  cp "$ROOT/scripts/gh-as-author.sh" "$dir/scripts/gh-as-author.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/gh-command-classifier.sh" "$dir/scripts/lib/gh-command-classifier.sh"
  cp "$ROOT/scripts/lib/pr-body-contract.sh" "$dir/scripts/lib/pr-body-contract.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  cp "$ROOT/scripts/identity-check.sh" "$dir/scripts/identity-check.sh"
  chmod +x "$dir/scripts/gh-as-author.sh" "$dir/scripts/identity-check.sh"
}

PIN_DIR="$WORKDIR/pin-repo"
install_wrapper_copy "$PIN_DIR"
printf 'author_identity: nathanjohnpayne\n' >"$PIN_DIR/.github/review-policy.yml"

reset_log
set +e
( cd "$PIN_DIR" && OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_AS_AUTHOR_IDENTITY="nathanpayne-codex" \
    PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$PIN_DIR/scripts/gh-as-author.sh" -- gh pr merge 9 --squash ) >/dev/null 2>"$WORKDIR/pin.err"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q "runtime byline pin" "$WORKDIR/pin.err"; then
  pass "runtime pin: non-policy identity refused before any gh call"
else
  fail "runtime pin: expected rc=2 with pin message; rc=$rc err=$(cat "$WORKDIR/pin.err")"
fi
if grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  fail "runtime pin: wrapped command ran despite the refusal"
else
  pass "runtime pin: no wrapped command executed on refusal"
fi

PIN_DIR2="$WORKDIR/pin-repo-custom"
install_wrapper_copy "$PIN_DIR2"
printf "author_identity: 'custom-author'\n" >"$PIN_DIR2/.github/review-policy.yml"

reset_log
set +e
( cd "$PIN_DIR2" && GH_AS_AUTHOR_IDENTITY="custom-author" \
    PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$PIN_DIR2/scripts/gh-as-author.sh" -- gh pr merge 9 --squash ) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q $'GH_TOKEN=fallback-custom-author-token GITHUB_TOKEN= gh\tpr\tmerge\t9\t--squash' "$WORKDIR/calls.log"; then
  pass "runtime pin: matching custom identity (quoted policy) proceeds with its token"
else
  fail "runtime pin: matching custom identity should proceed; rc=$rc calls=$(cat "$WORKDIR/calls.log")"
fi

# Subdirectory invocation must still load the pin (r20).
mkdir -p "$PIN_DIR/subdir"
reset_log
set +e
( cd "$PIN_DIR/subdir" && OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_AS_AUTHOR_IDENTITY="nathanpayne-codex" \
    PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" ../scripts/gh-as-author.sh -- gh pr merge 9 --squash ) >/dev/null 2>"$WORKDIR/pin-sub.err"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q "runtime byline pin" "$WORKDIR/pin-sub.err"; then
  pass "runtime pin: subdirectory invocation still loads the repo-root policy"
else
  fail "runtime pin: subdirectory invocation should refuse; rc=$rc err=$(cat "$WORKDIR/pin-sub.err")"
fi

NO_POLICY_DIR="$WORKDIR/pin-repo-none"
install_wrapper_copy "$NO_POLICY_DIR"
rm -rf "$NO_POLICY_DIR/.github"
reset_log
set +e
( cd "$NO_POLICY_DIR" && OP_PREFLIGHT_AUTHOR_PAT="author-token" \
    PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$NO_POLICY_DIR/scripts/gh-as-author.sh" -- gh pr merge 9 --squash ) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "runtime pin: absent policy file keeps legacy behavior"
else
  fail "runtime pin: absent policy file should not block; rc=$rc"
fi

echo ""
echo "test_gh_as_author: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
