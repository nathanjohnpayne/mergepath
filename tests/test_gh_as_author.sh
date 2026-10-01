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
unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

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

# gh_is_pr_create_command must refuse every env split-string spelling,
# including the attached `--split-string=STR` form that also matches the
# NAME=VALUE assignment pattern (shellcheck SC2221/SC2222 ordering).
for split_form in "-S" "--split-string" "--split-string=gh pr create"; do
  if gh_is_pr_create_command env "$split_form" gh pr create --title t; then
    fail "pr-create classifier accepted env $split_form"
  else
    pass "pr-create classifier refuses env $split_form"
  fi
done
if gh_is_pr_create_command env GH_TOKEN=x gh pr create --title t; then
  pass "pr-create classifier still skips a plain env NAME=VALUE assignment"
else
  fail "pr-create classifier over-rejected env NAME=VALUE"
fi

assert_prohibited_source "bare native merge" 'gh pr merge 7 --squash'
assert_prohibited_source "path-qualified native merge" '/opt/bin/gh pr merge 7'
assert_prohibited_source "prefixed native merge" 'env GH_TOKEN=x gh pr merge 7'
assert_prohibited_source "sudo option before native merge" 'sudo -H gh pr merge 7'
assert_prohibited_source "xargs option before native merge" 'echo 7 | xargs -t gh pr merge 7'
assert_prohibited_source "xargs option before REST write" 'echo 7 | xargs -t gh api repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "clustered method before API subcommand" 'gh -iXPUT api repos/o/r/pulls/7/merge'
assert_prohibited_source "implicit write field before API subcommand" 'gh -f event=APPROVE api repos/o/r/pulls/7/reviews'
assert_prohibited_source "raw field before API subcommand" 'gh --raw-field event=APPROVE api repos/o/r/pulls/7/reviews'
assert_allowed_source "explicit GET with prefix field" 'gh -X GET -f q=repo:o/r api search/issues'
assert_allowed_source "quoted header value resembling a command" 'gh -H "gh pr merge 7" api repos/o/r'
assert_prohibited_source "globally flagged native merge" 'gh --repo owner/repo pr merge 7'
assert_prohibited_source "attached global short repo flag native merge" \
  'gh -Rowner/repo pr merge 7 --squash'
assert_prohibited_source "attached PR short repo flag native merge" \
  'gh pr -Rowner/repo merge 7 --squash'

# An option the classifier does not model must not end the scan. Enumerating
# only -R/--repo/--hostname let every one of these read as clean, so a real
# mutation walked past the guard (#1219). The option run is matched by SHAPE
# now, so an option nobody has thought of yet still cannot split the command.
assert_prohibited_source "unmodelled long global flag before the PR group" \
  'gh --verbose pr merge 7'
assert_prohibited_source "unmodelled short global flag with a separate value" \
  'gh -q .x pr merge 7'
assert_prohibited_source "unmodelled global flag with an attached value" \
  'gh --cache=5m pr merge 7'
assert_prohibited_source "several unmodelled global flags" \
  'gh --verbose --debug pr merge 7'
assert_prohibited_source "a modelled and an unmodelled global flag together" \
  'gh -R owner/repo --verbose pr merge 7'
assert_prohibited_source "unmodelled flag between the PR group and the verb" \
  'gh pr --unknown-flag merge 7'
assert_prohibited_source "unmodelled global flag before a REST write" \
  'gh --unknown-flag api repos/o/r/pulls/7/merge -X PUT'
assert_prohibited_source "unmodelled global flag before a GraphQL mutation" \
  "gh --verbose api graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'"

# The widened option run must not start swallowing ordinary read-only syntax.
# `merged`/`mergeStateStatus` are a flag VALUE and a longer word, not the
# `merge` verb, and an unmodelled option on a GET is still a GET.
assert_allowed_source "a flag value that spells merged is not the merge verb" \
  'gh pr list --state merged'
assert_allowed_source "merge as a prefix of a longer JSON field is not the verb" \
  'gh pr view 114 --json mergeStateStatus'
assert_allowed_source "an unmodelled global flag on an explicit REST GET" \
  'gh --verbose api repos/o/r/pulls -X GET -f state=open'

# Both forms below are valid reads that the first cut of the widened option run
# newly blocked (Codex P2 on #1222). Each was confirmed against gh 2.100.0 by
# running it and reaching the API rather than a flag-parse error.
#
# gh accepts a subcommand flag ahead of its subcommand, so the `merge` here is
# the jq expression and not the verb; the bare-option parse must not reinterpret
# a consumed value as a command word.
assert_allowed_source "a value-taking option whose value spells merge" \
  'gh pr -q merge view 1 --json title'
assert_allowed_source "a value-taking long option whose value spells merge" \
  'gh pr --jq merge view 1 --json title'
assert_allowed_source "a pre-verb short label value that spells merge" \
  'gh pr -l merge list'
assert_allowed_source "a pre-verb long label value that spells merge" \
  'gh pr --label merge list'
assert_prohibited_source "a short label value cannot hide a later merge verb" \
  'gh pr -l merge merge 7'
# The method flag is a gh option and is legal on either side of `api`; gh sends
# the fields as a query string, so this is an explicit read.
assert_allowed_source "an explicit GET pinned before the api command" \
  'gh -X GET api search/issues -f q=x'
assert_allowed_source "an explicit long-form GET pinned before the api command" \
  'gh --method GET api search/issues -f q=x'
# The same prefix position must not become a way to launder a write.
assert_prohibited_source "a REST write method pinned before the api command" \
  'gh -X PUT api repos/o/r/pulls/7/merge'
assert_prohibited_source "a long-form REST write method pinned before api" \
  'gh --method POST api repos/o/r/pulls/7/merge'

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
# Enterprise credentials the wrapped command would see (Codex P1 on #1541).
[ -n "${STUB_MARKER_ENV_LOG:-}" ] && printf '%s\n' "${GH_AS_AUTHOR_TRACE_MARKER:-<unset>}" >>"$STUB_MARKER_ENV_LOG"
[ -n "${STUB_ENT_LOG:-}" ] && printf '%s|%s|%s %s\n' "${GH_ENTERPRISE_TOKEN:-}" "${GITHUB_ENTERPRISE_TOKEN:-}" "${1:-}" "${2:-}" >>"$STUB_ENT_LOG"  # TOKEN_OUTPUT_EXEMPT: fixture tokens pinned inline by the case that sets STUB_ENT_LOG

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "switch" ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  [ -n "${STUB_NO_KEYRING:-}" ] && exit 1
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
    nathanjohnpayne) printf '%s\n' "gho_fallback-author-token" ;;
    custom-author) printf '%s\n' "gho_fallback-custom-author-token" ;;
    *) exit 3 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  case "${GH_TOKEN:-}" in
    ghp_author-token|gho_fallback-author-token) printf '%s\n' "nathanjohnpayne" ;;
    gho_fallback-custom-author-token) printf '%s\n' "custom-author" ;;
    ghp_reviewer-token) printf '%s\n' "nathanpayne-claude" ;;
    proxy-injected) printf '%s\n' "nathanjohnpayne" ;;  # the #1057 placeholder READS as the human
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
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GITHUB_TOKEN="ambient-token" \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "merge happy path: rc=$rc"
elif grep -q $'gh\tauth\tswitch' "$WORKDIR/calls.log"; then
  fail "merge happy path: called gh auth switch"
elif ! grep -q $'GH_TOKEN=ghp_author-token GITHUB_TOKEN= gh\tpr\tmerge\t123\t--squash' "$WORKDIR/calls.log"; then
  fail "merge happy path: wrapped command did not run with author token and GITHUB_TOKEN unset"
  cat "$WORKDIR/calls.log" >&2
else
  pass "merge happy path: verified author token, no keyring switch, ambient GITHUB_TOKEN cleared"
fi

reset_log
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" --body $'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.' >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create verification: rc=$rc"
elif ! grep -q $'GH_TOKEN=ghp_author-token GITHUB_TOKEN= gh\tpr\tview\t77\t--repo\texample/repo\t--json\tauthor\t--jq\t.author.login' "$WORKDIR/calls.log"; then
  fail "pr create verification: did not verify author with same token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "pr create verification: post-create read uses same author token"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
  stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/76" GH_VIEW_AUTHOR="nathanjohnpayne" \
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
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
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
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
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
  OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
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
  stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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

# Since #1541 a prefixed payload is refused outright, even with a valid body:
# a prefix can replace the verified token after it is checked (Codex P1).
reset_log
set +e
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/79" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- sudo -b gh pr create --title "t" --body "$VALID_INLINE_BODY" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "prefixed pr create contract (sudo -b): valid body but prefixed payload should be refused; rc=$rc"
elif grep -q $'gh\tpr\tcreate' "$WORKDIR/calls.log"; then
  fail "prefixed pr create contract (sudo -b): the prefixed create ran"
else
  pass "prefixed pr create contract (sudo -b): refused before any write, even with a valid body"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/78" GH_VIEW_AUTHOR="nathanjohnpayne" \
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
  OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/79" GH_VIEW_AUTHOR="nathanjohnpayne" \
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
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
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
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/88" GH_VIEW_AUTHOR="nathanpayne-claude" \
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
elif ! grep -q $'GH_TOKEN=gho_fallback-author-token GITHUB_TOKEN= gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  fail "fallback token: did not use gh auth token --user fallback"
  cat "$WORKDIR/calls.log" >&2
else
  pass "fallback token: uses gh auth token --user without switching"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="ghp_reviewer-token" run_wrapper -- gh pr merge 123 --squash 2>&1 >/dev/null)
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
  cp "$ROOT/scripts/lib/credential-class.sh" "$dir/scripts/lib/credential-class.sh"
  chmod +x "$dir/scripts/gh-as-author.sh" "$dir/scripts/identity-check.sh"
}

PIN_DIR="$WORKDIR/pin-repo"
install_wrapper_copy "$PIN_DIR"
printf 'author_identity: nathanjohnpayne\n' >"$PIN_DIR/.github/review-policy.yml"

reset_log
set +e
( cd "$PIN_DIR" && OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_AS_AUTHOR_IDENTITY="nathanpayne-codex" \
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
if [ "$rc" -eq 0 ] && grep -q $'GH_TOKEN=gho_fallback-custom-author-token GITHUB_TOKEN= gh\tpr\tmerge\t9\t--squash' "$WORKDIR/calls.log"; then
  pass "runtime pin: matching custom identity (quoted policy) proceeds with its token"
else
  fail "runtime pin: matching custom identity should proceed; rc=$rc calls=$(cat "$WORKDIR/calls.log")"
fi

# Subdirectory invocation must still load the pin (r20).
mkdir -p "$PIN_DIR/subdir"
reset_log
set +e
( cd "$PIN_DIR/subdir" && OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" GH_AS_AUTHOR_IDENTITY="nathanpayne-codex" \
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
( cd "$NO_POLICY_DIR" && OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
    PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$NO_POLICY_DIR/scripts/gh-as-author.sh" -- gh pr merge 9 --squash ) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "runtime pin: absent policy file keeps legacy behavior"
else
  fail "runtime pin: absent policy file should not block; rc=$rc"
fi

# Codex P1 on #1541: a prefix in the payload can replace the verified author
# token after verification, so only a direct gh payload runs.
reset_log
set +e
OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" run_wrapper -- env GH_TOKEN=proxy-injected gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ] && ! grep -q $'pr\tmerge' "$WORKDIR/calls.log"; then
  pass "prefixed author payload (env GH_TOKEN=...): refused before any write"
else
  fail "prefixed author payload: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi

# Codex P1 on #1541: the author write runs with the Enterprise credentials
# set to a non-credential sentinel, so an Enterprise Server target cannot use
# another credential.
reset_log
: >"$WORKDIR/ent.log"
set +e
STUB_ENT_LOG="$WORKDIR/ent.log" OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qx 'mergepath-guarded-write-github-com-only|mergepath-guarded-write-github-com-only|pr merge' "$WORKDIR/ent.log"; then
  pass "enterprise credentials: the author write runs with both set to the non-credential sentinel"
else
  fail "author enterprise pinning: rc=$rc log=$(cat "$WORKDIR/ent.log")"
fi

# #1057: the Claude cloud placeholder READS as the author through GET /user,
# so read identity alone would select it. With a keyring token the resolver
# must skip it and write under the keyring token; with no keyring it must
# refuse, never write under the placeholder.
reset_log
set +e
GITHUB_TOKEN= GH_TOKEN="proxy-injected" run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q $'GH_TOKEN=gho_fallback-author-token GITHUB_TOKEN= gh\tpr\tmerge' "$WORKDIR/calls.log" \
   && ! grep -q $'GH_TOKEN=proxy-injected GITHUB_TOKEN= gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  pass "brokered placeholder: skipped for the keyring token, never the write credential"
else
  fail "brokered placeholder with keyring: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi

reset_log
set +e
STUB_NO_KEYRING=1 GITHUB_TOKEN= GH_TOKEN="proxy-injected" run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && ! grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  pass "brokered placeholder: no keyring, so no author write at all"
else
  fail "brokered placeholder without keyring: rc=$rc"
  cat "$WORKDIR/calls.log" >&2
fi

# --- #1541: bootstrap's git push and the trace marker, on the REAL wrapper ---
# The author wrapper accepts one git form, `git [-C <dir>] push [-u] <remote>
# [<refspec>...]`, and runs it so the only credential git can present to
# github.com is the verified token. Real git throughout; the git shim below
# delegates everything to it except `push`, which it records (no network).
REAL_GIT="$(command -v git)"
GITSTUB_DIR="$WORKDIR/git-stub-bin"
mkdir -p "$GITSTUB_DIR"
printf '#!/usr/bin/env bash\nREAL_GIT=%q\n' "$REAL_GIT" >"$GITSTUB_DIR/git"
cat >>"$GITSTUB_DIR/git" <<'GITSTUB'
for a in "$@"; do
  if [ "$a" = push ]; then
    {
      printf 'GH_TOKEN=%s|HOME=%s|GIT_CONFIG_GLOBAL=%s|NOSYSTEM=%s|PROMPT=%s|ARGS=' \
        "${GH_TOKEN:-}" "${HOME:-}" "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}" "${GIT_TERMINAL_PROMPT:-}"  # TOKEN_OUTPUT_EXEMPT: fixture token pinned inline by each case
      printf '%s ' "$@"
      printf '\n'
    } >>"$PUSH_STUB_LOG"
    exit 0
  fi
done
exec "$REAL_GIT" "$@"
GITSTUB
chmod +x "$GITSTUB_DIR/git"
GIT_PUSH_LOG="$WORKDIR/git-push.log"
PUSHREPO="$WORKDIR/pushrepo"
"$REAL_GIT" init -q "$PUSHREPO"
"$REAL_GIT" -C "$PUSHREPO" remote add origin https://github.com/example/repo.git

run_git_wrapper() { # <expected rc> <label> <payload...>
  local want="$1" label="$2" rc err
  shift 2
  : >"$GIT_PUSH_LOG"
  reset_log
  set +e
  err=$(PATH="$GITSTUB_DIR:$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" PUSH_STUB_LOG="$GIT_PUSH_LOG" \
    GH_AS_AUTHOR_PUSH_REPO="${PUSH_REPO_OVERRIDE-example/repo}" \
    OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" "$WRAPPER" -- "$@" 2>&1 >/dev/null)
  rc=$?
  set -e
  GIT_CASE_ERR="$err"
  if [ "$rc" -ne "$want" ]; then
    fail "git push contract ($label): rc=$rc expected $want; err=$err"
    return 1
  fi
  return 0
}
# A fresh bootstrap-shaped repository: git init + origin, nothing else.
fresh_pushrepo() {
  rm -rf "$PUSHREPO"
  "$REAL_GIT" init -q -b main "$PUSHREPO"
  "$REAL_GIT" -C "$PUSHREPO" remote add origin "${1:-https://github.com/example/repo.git}"
}
refused_case() { # <label>  (expects exit 5 and nothing pushed)
  if run_git_wrapper 5 "$1" git -C "$PUSHREPO" push -u origin HEAD; then
    if [ -s "$GIT_PUSH_LOG" ]; then fail "$1: pushed"; else pass "$1: refused before the push"; fi
  fi
}

fresh_pushrepo
if run_git_wrapper 0 "fresh bootstrap repo" git -C "$PUSHREPO" push -u origin HEAD; then
  line="$(cat "$GIT_PUSH_LOG")"
  case "$line" in
    "GH_TOKEN=ghp_author-token|HOME=$HOME|"*) fail "git push ran with the operator's HOME (netrc/XDG reachable): $line" ;;
    "GH_TOKEN=ghp_author-token|HOME="*"|GIT_CONFIG_GLOBAL=/dev/null|NOSYSTEM=1|PROMPT=0|ARGS=-c credential.helper= -c credential.helper=!'/"*"/gh' auth git-credential -c http.extraHeader= -c core.hooksPath=/dev/null "*"push -u origin HEAD ")
      pass "fresh bootstrap repo: pushed under the verified token, global/system/prompt/hooks closed, gh's helper alone" ;;
    *) fail "fresh bootstrap repo: unexpected push environment: $line" ;;
  esac
fi

fresh_pushrepo "git@github.com:example/repo.git"
if run_git_wrapper 0 "exact ssh spelling" git -C "$PUSHREPO" push -u origin HEAD \
   && grep -q -- '-c url.https://github.com/.insteadOf=git@github.com:' "$GIT_PUSH_LOG"; then
  pass "exact git@github.com: spelling for the expected repo: accepted and pushed over HTTPS"
fi

# The destination must be exactly the expected repository.
for url in https://github.com/example/other.git https://github.com/Example/Repo.git https://github.com/example/repo \
           ssh://git@github.com/example/repo.git "https://x-access-token:EMBEDDEDSECRET@github.com/example/repo.git" \
           https://gitlab.com/example/repo.git; do
  fresh_pushrepo "$url"
  refused_case "origin $(printf '%s' "$url" | sed -E 's#//[^/@]*@#//<redacted>@#')"
  printf '%s' "$GIT_CASE_ERR" | grep -q EMBEDDEDSECRET && fail "origin URL credential was echoed"
done
fresh_pushrepo
PUSH_REPO_OVERRIDE="" refused_case "no GH_AS_AUTHOR_PUSH_REPO"
PUSH_REPO_OVERRIDE="example/other" refused_case "GH_AS_AUTHOR_PUSH_REPO names another repository"

# Any key outside the value-checked allowlist refuses the push, named without
# its value, userinfo in a URL subsection redacted.
for kv in "remote.origin.pushurl=https://github.com/example/repo.git" "remote.origin.vcs=evil" \
          "push.gpgSign=true" "gpg.program=/tmp/x" "credential.helper=!echo password=x" \
          "url.https://evil.example/.insteadOf=https://github.com/" "include.path=/tmp/other.config" \
          "extensions.worktreeConfig=true" "remote.origin.gh-resolved=base" "user.name=t" \
          "core.fsmonitor=true" "core.hooksPath=/tmp/hooks" "core.filemode=yes" \
          "branch.main.remote=Origin" "branch.main.pushRemote=origin" \
          "http.https://user:KEYSECRET@github.com/.extraheader=x: y"; do
  fresh_pushrepo
  "$REAL_GIT" -C "$PUSHREPO" config --local "${kv%%=*}" "${kv#*=}"
  refused_case "repo-local $(printf '%s' "${kv%%=*}" | sed -E 's#//[^/@]*@#//<redacted>@#')"
  if printf '%s' "$GIT_CASE_ERR" | grep -q KEYSECRET; then fail "a credential-bearing key name was echoed"; fi
done
fresh_pushrepo
"$REAL_GIT" -C "$PUSHREPO" config --local "http.https://user:KEYSECRET@github.com/.extraheader" "x: y"
run_git_wrapper 5 "redaction probe" git -C "$PUSHREPO" push -u origin HEAD \
  && printf '%s' "$GIT_CASE_ERR" | grep -q '<redacted>@github.com' \
  && pass "credential-bearing key name: named with its userinfo redacted"

fresh_pushrepo
"$REAL_GIT" -C "$PUSHREPO" config --local --add remote.origin.url https://github.com/example/repo.git
refused_case "duplicate remote.origin.url (same value)"
fresh_pushrepo
"$REAL_GIT" -C "$PUSHREPO" config --local --unset-all remote.origin.fetch
refused_case "missing remote.origin.fetch"
fresh_pushrepo
"$REAL_GIT" -C "$PUSHREPO" config --local branch.main.remote origin
"$REAL_GIT" -C "$PUSHREPO" config --local branch.main.merge refs/heads/main
if run_git_wrapper 0 "retry after push -u" git -C "$PUSHREPO" push -u origin HEAD && [ -s "$GIT_PUSH_LOG" ]; then
  pass "retry after push -u (branch.main.remote=origin, branch.main.merge=refs/heads/main): the push proceeds"
fi

# Linked worktree: its .git is a gitdir file, not the primary repository.
fresh_pushrepo
"$REAL_GIT" -C "$PUSHREPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
"$REAL_GIT" -C "$PUSHREPO" worktree add -q "$WORKDIR/linked-wt" -b side 2>/dev/null
if run_git_wrapper 5 "linked worktree" git -C "$WORKDIR/linked-wt" push -u origin HEAD; then
  [ -s "$GIT_PUSH_LOG" ] && fail "linked worktree: pushed" || pass "linked worktree: refused before the push"
fi
"$REAL_GIT" -C "$PUSHREPO" worktree remove --force "$WORKDIR/linked-wt" 2>/dev/null || true

# Crafted indirection: <dir>/.git is a DIRECTORY holding a clean config and a
# commondir pointing at another repository, whose config git actually uses
# for the push (here remote.origin.vcs=evil). Reading <dir>/.git/config alone
# would pass; the git-dir == common-dir check refuses it. Real git.
mkdir -p "$WORKDIR/vcs-bin"
printf '#!/bin/sh\nprintf "%%s" "$GH_TOKEN" >"%s"\nexit 1\n' "$WORKDIR/vcs-captured" >"$WORKDIR/vcs-bin/git-remote-evil"
chmod +x "$WORKDIR/vcs-bin/git-remote-evil"
CDA="$WORKDIR/cd-hostile"
CDW="$WORKDIR/cd-crafted"
"$REAL_GIT" init -q -b main "$CDA"
"$REAL_GIT" -C "$CDA" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
"$REAL_GIT" -C "$CDA" remote add origin https://github.com/example/repo.git
"$REAL_GIT" -C "$CDA" worktree add -q "$CDW" -b crafted 2>/dev/null
wtname="$(basename "$CDW")"
rm -f "$CDW/.git"
cp -R "$CDA/.git/worktrees/$wtname" "$CDW/.git"
printf '%s\n' "$CDA/.git" >"$CDW/.git/commondir"
cp "$CDA/.git/config" "$CDW/.git/config"
"$REAL_GIT" -C "$CDA" config --local remote.origin.vcs evil
rm -f "$WORKDIR/vcs-captured"
set +e
PATH="$WORKDIR/vcs-bin:$PATH" bash -c '. "$1"; gh_author_git_push ghp_cd-token example/repo -C "$2" push -u origin HEAD' _ \
  "$ROOT/scripts/lib/gh-token-resolver.sh" "$CDW" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 5 ] && [ ! -e "$WORKDIR/vcs-captured" ]; then
  pass "crafted commondir indirection: refused, so the other repository's helper never sees the token"
else
  fail "commondir indirection: rc=$rc captured=$([ -e "$WORKDIR/vcs-captured" ] && echo yes || echo no)"
fi

# Only the exact form, and nothing in front of it.
fresh_pushrepo
for shape in "git -C $PUSHREPO push origin HEAD" "git -C $PUSHREPO push -u origin main" \
             "git -C $PUSHREPO push -u upstream HEAD" "git push -u origin HEAD" \
             "git -c credential.helper=x -C $PUSHREPO push -u origin HEAD" "git -C $PUSHREPO fetch origin" \
             "git -C $PUSHREPO push -u origin HEAD --force" \
             "env GH_TOKEN=proxy-injected git -C $PUSHREPO push -u origin HEAD"; do
  # shellcheck disable=SC2086
  if run_git_wrapper 1 "refused shape: $shape" $shape; then
    if [ -s "$GIT_PUSH_LOG" ] || grep -q $'gh\tapi\tuser' "$WORKDIR/calls.log"; then
      fail "refused shape '$shape': pushed or resolved a token first"
    else
      pass "refused shape '$shape': exit 1 before token resolution, nothing pushed"
    fi
  fi
done

# No repository-controlled hook runs with the token in its environment (Codex
# on #1541). Real git, a real local push: a pre-push hook that would capture
# GH_TOKEN never runs.
HOOKREPO="$WORKDIR/hookrepo"
HOOKBARE="$WORKDIR/hookbare.git"
"$REAL_GIT" init -q "$HOOKREPO"
"$REAL_GIT" init -q --bare "$HOOKBARE"
"$REAL_GIT" -C "$HOOKREPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
printf '#!/bin/sh\nprintf "%%s" "$GH_TOKEN" >"%s"\n' "$WORKDIR/hook-captured" >"$HOOKREPO/.git/hooks/pre-push"
chmod +x "$HOOKREPO/.git/hooks/pre-push"
rm -f "$WORKDIR/hook-captured"
set +e
hook_out="$(bash -c '. "$1"; gh_author_git_exec ghp_hook-token -C "$2" push "$3" HEAD:refs/heads/main' _ \
  "$ROOT/scripts/lib/gh-token-resolver.sh" "$HOOKREPO" "$HOOKBARE" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ ! -e "$WORKDIR/hook-captured" ] && "$REAL_GIT" -C "$HOOKBARE" rev-parse -q --verify refs/heads/main >/dev/null; then
  pass "real git push: the repository's pre-push hook never runs with the token in its environment"
else
  fail "hook isolation: rc=$rc captured=$([ -e "$WORKDIR/hook-captured" ] && echo yes || echo no) out=$hook_out"
fi

# Real git: with remote.origin.vcs=evil and git-remote-evil on PATH, the
# helper never starts, so the token is never captured (CodeRabbit on #1541).
VCSREPO="$WORKDIR/vcsrepo"
"$REAL_GIT" init -q -b main "$VCSREPO"
"$REAL_GIT" -C "$VCSREPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
"$REAL_GIT" -C "$VCSREPO" remote add origin https://github.com/example/repo.git
"$REAL_GIT" -C "$VCSREPO" config --local remote.origin.vcs evil
mkdir -p "$WORKDIR/vcs-bin"
printf '#!/bin/sh\nprintf "%%s" "$GH_TOKEN" >"%s"\nexit 1\n' "$WORKDIR/vcs-captured" >"$WORKDIR/vcs-bin/git-remote-evil"
chmod +x "$WORKDIR/vcs-bin/git-remote-evil"
rm -f "$WORKDIR/vcs-captured"
set +e
PATH="$WORKDIR/vcs-bin:$PATH" bash -c '. "$1"; gh_author_git_push ghp_vcs-token example/repo -C "$2" push -u origin HEAD' _ \
  "$ROOT/scripts/lib/gh-token-resolver.sh" "$VCSREPO" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 5 ] && [ ! -e "$WORKDIR/vcs-captured" ]; then
  pass "real git: a remote.<name>.vcs helper never starts, so it never sees the token"
else
  fail "vcs helper isolation: rc=$rc captured=$([ -e "$WORKDIR/vcs-captured" ] && echo yes || echo no)"
fi

# The credential git itself obtains for github.com, under hostile global,
# netrc, environment and repo-local configuration: only the verified token.
CRED_DIR="$WORKDIR/cred-bin"
mkdir -p "$CRED_DIR" "$WORKDIR/hostile-home"
cat >"$CRED_DIR/gh" <<'CREDGH'
#!/usr/bin/env bash
# gh auth git-credential get: GH_TOKEN answers for github.com, as gh does.
if [ "$1 $2 $3" = "auth git-credential get" ]; then
  cat >/dev/null
  printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n' "${GH_TOKEN:-}"  # TOKEN_OUTPUT_EXEMPT: fixture token pinned inline
  exit 0
fi
exit 1
CREDGH
chmod +x "$CRED_DIR/gh"
printf '[credential]\n\thelper = "!f() { echo username=other; echo password=HOSTILE-GLOBAL; }; f"\n' >"$WORKDIR/hostile-home/.gitconfig"
printf 'machine github.com login other password HOSTILE-NETRC\n' >"$WORKDIR/hostile-home/.netrc"
fresh_pushrepo
"$REAL_GIT" -C "$PUSHREPO" config --local credential.helper '!f() { echo username=other; echo password=HOSTILE-LOCAL; }; f'
cred_out="$(cd "$PUSHREPO" && printf 'protocol=https\nhost=github.com\n\n' | \
  HOME="$WORKDIR/hostile-home" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper \
  GIT_CONFIG_VALUE_0='!f() { echo username=other; echo password=HOSTILE-ENV; }; f' PATH="$CRED_DIR:$PATH" \
  bash -c '. "$1"; gh_author_git_exec ghp_verified-token credential fill' _ "$ROOT/scripts/lib/gh-token-resolver.sh" 2>&1)"
"$REAL_GIT" -C "$PUSHREPO" config --local --unset-all credential.helper
if printf '%s\n' "$cred_out" | grep -qx 'password=ghp_verified-token' && ! printf '%s' "$cred_out" | grep -q HOSTILE; then
  pass "real git: the credential it obtains for github.com is the verified token, past hostile global/env/local helpers"
else
  fail "real git credential under hostile config: $cred_out"
fi

# Every inherited GIT_* variable is dropped before git runs with the token
# (Codex on #1541): GIT_EXEC_PATH could substitute git-remote-https, and
# GIT_TRACE_CURL with GIT_TRACE_REDACT=0 would log the Authorization header.
mkdir -p "$WORKDIR/fake-exec"
env_out="$(GIT_EXEC_PATH="$WORKDIR/fake-exec" GIT_TRACE_CURL="$WORKDIR/trace.log" GIT_TRACE_REDACT=0 \
  GIT_SSL_NO_VERIFY=1 PATH="$CRED_DIR:$PATH" \
  bash -c '. "$1"; gh_author_git_exec ghp_env-token -c alias.showenv="!env" showenv' _ "$ROOT/scripts/lib/gh-token-resolver.sh" 2>&1)"
if printf '%s\n' "$env_out" | grep -q "GIT_EXEC_PATH=$WORKDIR/fake-exec" \
   || printf '%s\n' "$env_out" | grep -qE '^GIT_(TRACE_CURL|TRACE_REDACT|SSL_NO_VERIFY)='; then
  fail "inherited GIT_* reached the token-bearing git: $(printf '%s\n' "$env_out" | grep '^GIT_' | tr '\n' ' ')"
elif printf '%s\n' "$env_out" | grep -q '^GH_TOKEN=ghp_env-token$'; then
  pass "inherited GIT_EXEC_PATH, GIT_TRACE_CURL, GIT_TRACE_REDACT and GIT_SSL_NO_VERIFY never reach the token-bearing git"
else
  fail "GIT_* isolation probe did not run: $env_out"
fi

# A gh the repository ships is never the credential helper, even with "."
# on PATH: git resolves a bare helper name after entering the repository, so
# the runner names gh by the absolute path it resolved first (Codex on #1541).
PATHREPO="$WORKDIR/pathrepo"
"$REAL_GIT" init -q "$PATHREPO"
printf '#!/bin/sh\nprintf "%%s" "$GH_TOKEN" >"%s"\nprintf "password=REPO-GH\\n"\n' "$WORKDIR/path-captured" >"$PATHREPO/gh"
chmod +x "$PATHREPO/gh"
rm -f "$WORKDIR/path-captured"
path_out="$(cd "$WORKDIR" && printf 'protocol=https\nhost=github.com\n\n' | PATH=".:$CRED_DIR:$PATH" \
  bash -c '. "$1"; gh_author_git_exec ghp_path-token -C "$2" credential fill' _ "$ROOT/scripts/lib/gh-token-resolver.sh" "$PATHREPO" 2>&1)"
if printf '%s\n' "$path_out" | grep -qx 'password=ghp_path-token' && [ ! -e "$WORKDIR/path-captured" ]; then
  pass "a gh inside the repository never runs as the credential helper, even with . on PATH"
else
  fail "repo-shipped gh: out=$path_out captured=$([ -e "$WORKDIR/path-captured" ] && echo yes || echo no)"
fi

# The trace marker: written after every check, immediately before the gh
# write; never on a refusal; exit 70 when unwritable; never inherited.
MARKER="$WORKDIR/reached-marker"
rm -f "$MARKER"; reset_log; : >"$WORKDIR/marker-env.log"
set +e
STUB_MARKER_ENV_LOG="$WORKDIR/marker-env.log" GH_AS_AUTHOR_TRACE_MARKER="$MARKER" OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -f "$MARKER" ] && grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log" && ! grep -vqx '<unset>' "$WORKDIR/marker-env.log"; then
  pass "trace marker: written when the write runs, and no gh call inherits the variable"
else
  fail "trace marker success: rc=$rc marker=$([ -f "$MARKER" ] && echo yes || echo no) env=$(sort -u "$WORKDIR/marker-env.log" | tr '\n' ' ')"
fi
rm -f "$MARKER"; reset_log
set +e
GITHUB_TOKEN= GH_TOKEN= GH_AS_AUTHOR_TRACE_MARKER="$MARKER" GH_AS_AUTHOR_IDENTITY=custom-author-nokeyring \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ ! -e "$MARKER" ] && ! grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  pass "trace marker: absent when verification refuses (rc=$rc), and gh never ran"
else
  fail "trace marker on refusal: rc=$rc marker=$([ -e "$MARKER" ] && echo present || echo absent)"
fi
reset_log
set +e
GH_AS_AUTHOR_TRACE_MARKER="$WORKDIR/no-such-dir/marker" OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 70 ] && ! grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  pass "trace marker: unwritable, so exit 70 and the write never runs"
else
  fail "unwritable trace marker: rc=$rc"
fi
set +e
fresh_pushrepo
PATH="$GITSTUB_DIR:$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" PUSH_STUB_LOG="$GIT_PUSH_LOG" GH_AS_AUTHOR_TRACE_MARKER="$MARKER" \
  GH_AS_AUTHOR_PUSH_REPO=example/repo OP_PREFLIGHT_AUTHOR_PAT="ghp_author-token" "$WRAPPER" -- git -C "$PUSHREPO" push -u origin HEAD >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] && pass "trace marker with a git payload: refused (the marker means the gh write ran)" \
  || fail "trace marker with git payload: rc=$rc"

echo ""
echo "test_gh_as_author: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
