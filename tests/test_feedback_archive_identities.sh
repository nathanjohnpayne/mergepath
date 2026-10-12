#!/usr/bin/env bash
# Offline retained-registry, renderer and inert-relay regressions (#1437).
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/scripts/lib/feedback-policy-helpers.sh"
. "$ROOT/scripts/lib/feedback-archive-identities.sh"
PASS=0
check() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; PASS=$((PASS + 1)); }
cat >"$TMP/policy.yml" <<'YAML'
available_reviewers: []
codex: {bot_login: "new-codex[bot]"}
code_scanning: {bot_login: "custom-ghas[bot]"}
feedback_archive:
  identities:
    - {login: retired-reviewer, provider: reviewer, status: retired}
    - {login: octocat_acme, provider: reviewer, status: retired}
    - {login: "old-codex[bot]", provider: codex, status: retired}
    - {login: "custom-ghas[bot]", provider: ghas, status: active}
YAML
printf '**P1** Sole previous finding body.\n' >"$TMP/body"
feedback_archive_registry_load "$TMP/policy.yml"
check test "$(feedback_archive_source_provider inline Retired-Reviewer)" = reviewer
check test "$(feedback_archive_source_provider issue-comment 'old-codex[bot]')" = codex
rc=0
feedback_archive_source_provider issue-comment retired-reviewer >/dev/null || rc=$?
check test "$rc" = 1
rc=0; feedback_archive_source_provider inline "" >/dev/null || rc=$?
check test "$rc" = 1
check test "$(feedback_archive_source_provider inline octocat_acme)" = reviewer
for login in never_acme 'bad login'; do
  rc=0; feedback_archive_source_provider inline "$login" >/dev/null || rc=$?
  check test "$rc" = 1
done
for kind in issue-comment inline review-body; do
  out=$(CONFIG="$TMP/policy.yml" "$ROOT/scripts/render-feedback-archive.sh" "$kind" 7 never-registered 2026-10-11T01:00:00Z "$TMP/body")
  check test -z "$out"
done
record=$(CONFIG="$TMP/policy.yml" "$ROOT/scripts/render-feedback-archive.sh" inline 7 retired-reviewer 2026-10-11T01:00:00Z "$TMP/body")
check test -n "$record"
jq -n --arg record "$record" '{archive_source:{kind:"inline",login:"retired-reviewer",id:7},archive_records:[$record]}' >"$TMP/handoff"
feedback_archive_validate_records "$TMP/handoff"
PASS=$((PASS + 1))
# An old workflow run cannot gain a new handoff field on rerun. Its decoded
# source still needs retained enrollment; metadata is an additional binding.
jq 'del(.archive_source)' "$TMP/handoff" >"$TMP/legacy"
feedback_archive_validate_records "$TMP/legacy"
PASS=$((PASS + 1))
jq -n --arg record "$(printf '%s' "$record" | sed -E 's/^<!-- mergepath-feedback-archive:v1 (.*) -->$/\1/' | jq -Rr '@base64d | fromjson | .source_login="never-registered" | @json | @base64')" \
  '{archive_records:[("<!-- mergepath-feedback-archive:v1 "+$record+" -->")]}' >"$TMP/legacy-ineligible"
rc=0; feedback_archive_validate_records "$TMP/legacy-ineligible" || rc=$?
check test "$rc" = 2
jq '.archive_source.login="never-registered"' "$TMP/handoff" >"$TMP/bad"
rc=0; feedback_archive_validate_records "$TMP/bad" || rc=$?
check test "$rc" = 2
jq '.archive_records += .archive_records' "$TMP/handoff" >"$TMP/bad"
rc=0; feedback_archive_validate_records "$TMP/bad" || rc=$?
check test "$rc" = 2
jq '.archive_records = [range(0;33) | "<!-- mergepath-feedback-archive-relay:v1 run=7 status=complete -->"] | .archive_source={kind:"issue-comment",login:"github-actions[bot]",id:8}' "$TMP/handoff" >"$TMP/bad"
rc=0; feedback_archive_validate_records "$TMP/bad" || rc=$?
check test "$rc" = 2
# A full near-limit prior body is bounded but lossless through inert chunking.
python3 - <<'PY' >"$TMP/large"
print('**P1** Large archived finding.\n' + 'retained text ' * 8000, end='')
PY
CONFIG="$TMP/policy.yml" "$ROOT/scripts/render-feedback-archive.sh" inline 7 retired-reviewer 2026-10-11T01:00:00Z "$TMP/large" >"$TMP/records"
jq -n --rawfile records "$TMP/records" '{archive_source:{kind:"inline",login:"retired-reviewer",id:7},archive_records:($records|split("\n")|map(select(length>0)))}' >"$TMP/chunked"
feedback_archive_validate_records "$TMP/chunked"
PASS=$((PASS + 1))
jq '.archive_records |= .[1:]' "$TMP/chunked" >"$TMP/bad"
rc=0; feedback_archive_validate_records "$TMP/bad" || rc=$?
check test "$rc" = 2
# Restoration stays the narrow Actions issue-comment path.
restored=$(CONFIG="$TMP/policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/records")
check test -z "$restored" # multiple records cannot be promoted as one restoration
printf '%s\n' "$record" >"$TMP/restoration"
restored=$(CONFIG="$TMP/policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/restoration")
check test "$restored" = "$record"
jq -n --arg record "$record" '{event_name:"issue_comment",archive_source:{kind:"issue-comment",login:"github-actions[bot]",id:8},archive_records:[$record]}' >"$TMP/restored-handoff"
feedback_archive_validate_records "$TMP/restored-handoff"
PASS=$((PASS + 1))
# Removing retained enrollment cannot erase an already trusted Actions record.
# Fresh producer bodies still require enrollment; restored history instead
# survives byte-for-byte so accounting can report the missing enrollment.
sed '/login: retired-reviewer, provider: reviewer, status: retired/d' "$TMP/policy.yml" >"$TMP/omitted-policy.yml"
feedback_archive_registry_load "$TMP/omitted-policy.yml"
restored=$(CONFIG="$TMP/omitted-policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/restoration")
check test "$restored" = "$record"
feedback_archive_validate_records "$TMP/restored-handoff"; PASS=$((PASS + 1))
rc=0; feedback_archive_validate_records "$TMP/handoff" || rc=$?
check test "$rc" = 2
for login in never-registered 'old-codex[bot]'; do
  out=$(CONFIG="$TMP/omitted-policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 "$login" 2026-10-11T02:00:00Z "$TMP/restoration")
  check test -z "$out"
done
feedback_archive_registry_load "$TMP/policy.yml"
# A no-match parser result must not vacuously validate an oversized restored
# chunk. Restoration is bounded even though only one part can be recovered.
jq -n '{event_name:"issue_comment",archive_source:{kind:"issue-comment",login:"github-actions[bot]",id:8},archive_records:[("<!-- mergepath-feedback-archive:v2 id=" + ("a" * 64) + " part=1/2 data=" + ("a" * 60001) + " -->")]}' >"$TMP/oversized-restoration"
rc=0; feedback_archive_validate_records "$TMP/oversized-restoration" || rc=$?
check test "$rc" = 2
# Complete ordinary v2 singletons decode enrollment. Trusted Actions
# restoration decodes shape independently of enrollment. No extra lines post.
encoded=$(printf '%s' "$record" | sed -E 's/^<!-- mergepath-feedback-archive:v1 (.*) -->$/\1/')
for login in retired-reviewer never-registered; do
  payload=$(printf '%s' "$encoded" | jq -Rr --arg login "$login" '@base64d | fromjson | .source_login=$login | @json | @base64')
  singleton="<!-- mergepath-feedback-archive:v2 id=$(printf '%064d' 0) part=1/1 data=$payload -->"
  for mode in legacy restoration; do
    jq -n --arg record "$singleton" --arg mode "$mode" '{archive_records:[$record]} |
      if $mode=="restoration" then .+{event_name:"issue_comment",archive_source:{kind:"issue-comment",login:"github-actions[bot]",id:8}} else . end' >"$TMP/singleton"
    rc=0; feedback_archive_validate_records "$TMP/singleton" || rc=$?
    if [ "$login" = retired-reviewer ] || [ "$mode" = restoration ]; then check test "$rc" = 0; else check test "$rc" = 2; fi
  done
  for extra in prefix suffix; do
    jq -n --arg record "$singleton" --arg extra "$extra" '{archive_source:{kind:"inline",login:"retired-reviewer",id:7},archive_records:[(if $extra=="prefix" then "junk\n"+$record else $record+"\njunk" end)]}' >"$TMP/multiline"
    rc=0; feedback_archive_validate_records "$TMP/multiline" || rc=$?
    check test "$rc" = 2
  done
done
# A real single chunk is incomplete after its sibling comments are edited or
# deleted. It can be restored only as an Actions issue-comment event.
chunk=$(head -n 1 "$TMP/records")
printf '%s\n' "$chunk" >"$TMP/chunk-restoration"
check test "$(CONFIG="$TMP/policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/chunk-restoration")" = "$chunk"
jq -n --arg record "$chunk" '{event_name:"issue_comment",archive_source:{kind:"issue-comment",login:"github-actions[bot]",id:8},archive_records:[$record]}' >"$TMP/partial"
feedback_archive_validate_records "$TMP/partial"; PASS=$((PASS + 1))
for change in 'del(.archive_source)' '.event_name="pull_request"' '.archive_source.id=0' '.archive_source.kind="inline"' '.archive_source.login="never-registered"'; do
  jq "$change" "$TMP/partial" >"$TMP/bad"
  rc=0; feedback_archive_validate_records "$TMP/bad" || rc=$?
  check test "$rc" = 2
done
terminal='<!-- mergepath-feedback-archive-relay:v2 run=42 publisher=43 status=complete -->'
jq -n --arg record "$terminal" '{event_name:"issue_comment",archive_source:{kind:"issue-comment",login:"github-actions[bot]",id:8},archive_records:[$record]}' >"$TMP/terminal"
feedback_archive_validate_records "$TMP/terminal"; PASS=$((PASS + 1))
jq 'del(.archive_source)' "$TMP/terminal" >"$TMP/bad"
rc=0; feedback_archive_validate_records "$TMP/bad" || rc=$?
check test "$rc" = 2
# Legacy restoration needs caller-verified context, not the payload event.
for original in "$TMP/partial" "$TMP/terminal"; do
  jq 'del(.archive_source)' "$original" >"$TMP/legacy-restoration"
  feedback_archive_validate_records "$TMP/legacy-restoration" issue_comment; PASS=$((PASS + 1))
  rc=0; feedback_archive_validate_records "$TMP/legacy-restoration" pull_request || rc=$?
  check test "$rc" = 2
  jq '.archive_source={kind:"issue-comment",login:"github-actions[bot]",id:0}' "$TMP/legacy-restoration" >"$TMP/bad"
  rc=0; feedback_archive_validate_records "$TMP/bad" issue_comment || rc=$?
  check test "$rc" = 2
  jq '.event_name="pull_request"' "$TMP/legacy-restoration" >"$TMP/bad"
  rc=0; feedback_archive_validate_records "$TMP/bad" issue_comment || rc=$?
  check test "$rc" = 2
done
# Unknown enrollment emits no rendered body and fails conservatively.
printf 'available_reviewers: [retired-reviewer]\n' >"$TMP/missing.yml"
rc=0; out=$(CONFIG="$TMP/missing.yml" "$ROOT/scripts/render-feedback-archive.sh" inline 7 retired-reviewer 2026-10-11T01:00:00Z "$TMP/body") || rc=$?
check test "$rc" = 2
check test -z "$out"
for schema in \
  '{"feedback_archive":{"identities":[]}}' \
  '{"feedback_archive":{"identities":[{"login":"r","provider":"reviewer","status":"typo"}]}}' \
  '{"feedback_archive":{"identities":[{"login":"r","provider":"reviewer","status":"retired"},{"login":"R","provider":"codex","status":"active"}]}}'; do
  rc=0; feedback_archive_registry_from_json "$schema" || rc=$?
  check test "$rc" = 2
done
# Active enrollment must match exactly one configured current role. Retired
# roles remain explicit historical enrollment after provider/reviewer changes.
role_policy=$(policy_yaml_to_json "$TMP/policy.yml")
for change in '.feedback_archive.identities[-1].provider="codex"' '.code_scanning.bot_login="new-ghas[bot]"' '.feedback_archive.identities += [{login:"stale-reviewer",provider:"reviewer",status:"active"}]'; do
  invalid=$(printf '%s' "$role_policy" | jq -c "$change")
  rc=0; feedback_archive_registry_from_json "$invalid" || rc=$?
  check test "$rc" = 2
done
retired_policy=$(printf '%s' "$role_policy" | jq -c '.code_scanning.bot_login="new-ghas[bot]" | .feedback_archive.identities[-1].status="retired"')
feedback_archive_registry_from_json "$retired_policy"; PASS=$((PASS + 1))
check test "$(feedback_archive_source_provider inline 'custom-ghas[bot]')" = ghas
# Current configured identities need not be enrolled. This is explicit archive
# enrollment, not an implicit grant derived from current reviewer membership.
reviewer_policy=$(printf '%s' "$role_policy" | jq -c '.available_reviewers=["current-reviewer","unenrolled-reviewer"] | .feedback_archive.identities += [{login:"current-reviewer",provider:"reviewer",status:"active"}]')
feedback_archive_registry_from_json "$reviewer_policy"; PASS=$((PASS + 1))
check test "$(feedback_archive_source_provider inline current-reviewer)" = reviewer
rc=0; feedback_archive_source_provider inline unenrolled-reviewer >/dev/null || rc=$?
check test "$rc" = 1
wrong_reviewer=$(printf '%s' "$reviewer_policy" | jq -c '.feedback_archive.identities[-1].provider="coderabbit"')
rc=0; feedback_archive_registry_from_json "$wrong_reviewer" || rc=$?
check test "$rc" = 2
# Default and explicitly empty provider-login fields match accounting defaults.
for defaults in '{}' '{"codex":{"bot_login":""}}'; do
  schema=$(printf '%s' "$defaults" | jq -c '.feedback_archive.identities=[{login:"chatgpt-codex-connector[bot]",provider:"codex",status:"active"}]')
  feedback_archive_registry_from_json "$schema"; PASS=$((PASS + 1))
done
feedback_archive_registry_load "$TMP/policy.yml"
# Exercise the checked-in producer with fake API responses and credentials.
# Unknown source bodies never reach the renderer/post path; a retired reviewer
# edit/deletion uploads its exact sole previous body on both read-only routes.
python3 - "$ROOT/.github/workflows/codex-p1-gate.yml" "$TMP/producer.sh" <<'PYTHON'
import sys,textwrap
s=open(sys.argv[1]).read().split('      - name: Prepare and persist the reviewer-feedback version',1)[1]
s=s.split('        run: |\n',1)[1].split('\n      - name:',1)[0]
open(sys.argv[2],'w').write(textwrap.dedent(s))
PYTHON
mkdir -p "$TMP/producer/.github" "$TMP/bin"
ln -s "$ROOT/scripts" "$TMP/producer/scripts"
cp "$TMP/policy.yml" "$TMP/producer/.github/review-policy.yml"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
case "$*" in
  *--method*POST*)
    [ "${GH_NATIVE_RESTORE:-false}" = true ] || { echo 'Unexpected live-write path in offline producer test' >&2; exit 99; }
    input=""; previous=""
    for arg in "$@"; do
      [ "$previous" != --input ] || input="$arg"
      previous="$arg"
    done
    if [ -n "$input" ] && [ "$input" != - ]; then cat "$input" >"$NATIVE_POST_FILE";
    else cat >"$NATIVE_POST_FILE"; fi
    jq '. + {id:88,user:{login:"github-actions[bot]"}}' "$NATIVE_POST_FILE" ;;
  *issues/7/comments*) printf '[]\n' ;;
  *actions/runs/42*) printf '2026-10-11T01:00:00Z\n' ;;
  *code-scanning/alerts/26*)
    if [ "${GHAS_MOCK:-failed}" = failed ]; then echo 'offline simulated alert read failure' >&2; exit 1; fi
    printf '{"rule":{}}\n' ;;
  *pulls/7*)
    fork=true; [ "${GH_NATIVE_RESTORE:-false}" != true ] || fork=false
    jq -n --argjson fork "$fork" '{head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{fork:$fork}},user:{login:"author"}}' ;;
  *) echo 'Unexpected API path' >&2; exit 98 ;;
esac
SH
chmod +x "$TMP/bin/gh"
# Non-capture events need no archive installation on trusted main. Exercise
# the actual producer with neither its new helper nor renderer installed;
# genuine edit/delete captures must still fail closed in that same checkout.
mkdir -p "$TMP/uninstalled/scripts/lib" "$TMP/uninstalled/.github"
cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$TMP/uninstalled/scripts/lib/"
printf 'available_reviewers: []\n' >"$TMP/uninstalled/.github/review-policy.yml"
for event_action in pull_request:opened pull_request:synchronize pull_request:edited pull_request_review:submitted pull_request_review_comment:created issue_comment:created pull_request_review_comment:edited pull_request_review_comment:deleted; do
  event=${event_action%:*}; action=${event_action#*:}
  for route in native fork; do
    native=false; [ "$route" != native ] || native=true
    fork=true; [ "$route" != native ] || fork=false
    jq -n --arg action "$action" --argjson fork "$fork" --rawfile old "$TMP/body" '{action:$action,issue:{number:7},comment:{id:7,user:{login:"retired-reviewer"},body:$old,updated_at:"2026-10-11T01:00:00Z"},changes:{body:{from:$old}},pull_request:{number:7,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{fork:$fork}},user:{login:"author"}}}' >"$TMP/event"
    : >"$TMP/output"; : >"$TMP/api-calls"
    rm -f "$TMP/codex-p1-read-only-handoff.json" "$TMP/native-post"
    rc=0
    (cd "$TMP/uninstalled" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" GH_NATIVE_RESTORE="$native" NATIVE_POST_FILE="$TMP/native-post" \
      CONFIG="$TMP/uninstalled/.github/review-policy.yml" REPO=acme/widget EVENT_NAME="$event" EVENT_ACTION="$action" \
      GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >"$TMP/uninstalled-$event-$action-$route.log" 2>&1 || rc=$?
    if [ "$event" = pull_request_review_comment ] && [ "$action" != created ]; then
      check test "$rc" != 0
      check test ! -e "$TMP/codex-p1-read-only-handoff.json"
    else
      check test "$rc" = 0
      if [ "$route" = fork ]; then
        check test "$(jq '.archive_records|length' "$TMP/codex-p1-read-only-handoff.json")" = 0
      else
        check grep -Fq 'requires_relay=false' "$TMP/output"
      fi
    fi
    check test ! -e "$TMP/native-post"
    check test "$(grep -c -- '--method POST' "$TMP/api-calls" || true)" = 0
  done
done
for actor in ordinary 'dependabot[bot]'; do
  for action in edited deleted; do
    for login in never-registered never_acme 'bad login' retired-reviewer octocat_acme; do
      jq -n --arg action "$action" --arg login "$login" --arg actor "$actor" --rawfile old "$TMP/body" '{action:$action,comment:{id:7,user:{login:$login},body:$old,updated_at:"2026-10-11T01:00:00Z"},changes:{body:{from:$old}},pull_request:{number:7,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{fork:($actor=="ordinary")}},user:{login:$actor}}}' >"$TMP/event"
      : >"$TMP/output"; : >"$TMP/api-calls"
      rm -f "$TMP/codex-p1-read-only-handoff.json"
      (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" \
        CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=pull_request_review_comment EVENT_ACTION="$action" \
        GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" \
        SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >/dev/null
      handoff="$TMP/codex-p1-read-only-handoff.json"
      if [[ "$login" == never* || "$login" == 'bad login' ]]; then
        check test "$(jq '.archive_records|length' "$handoff")" = 0
      else
        check test "$(jq '.archive_records|length' "$handoff")" = 1
        feedback_archive_registry_load "$TMP/policy.yml"
        feedback_archive_validate_records "$handoff"
        check test "$(jq -r '.archive_records[0] | capture("^<!-- mergepath-feedback-archive:v1 (?<data>.+) -->$").data | @base64d | fromjson | .body' "$handoff")" = "$(cat "$TMP/body")"
      fi
      check test ! -s "$TMP/api-calls"
    done
  done
done
# Real Actions restoration reaches the issue-comment PR binding read and
# preserves the exact previous v1, partial v2, and terminal records. An empty
# non-archive event carries no archive source and also has a fresh handoff.
cp "$TMP/omitted-policy.yml" "$TMP/producer/.github/review-policy.yml"
for prior in "$record" "$chunk" "$terminal" "plain Actions narration"; do
  jq -n --arg prior "$prior" '{action:"deleted",issue:{number:7},comment:{id:8,user:{login:"github-actions[bot]"},body:$prior,updated_at:"2026-10-11T02:00:00Z"}}' >"$TMP/event"
  : >"$TMP/output"; : >"$TMP/api-calls"
  rm -f "$TMP/codex-p1-read-only-handoff.json"
  (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" \
    CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=issue_comment EVENT_ACTION=deleted \
    GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >/dev/null
  handoff="$TMP/codex-p1-read-only-handoff.json"
  if [ "$prior" = "plain Actions narration" ]; then
    check test "$(jq '.archive_records|length' "$handoff")" = 0
  else
    check test "$(jq -r '.archive_records[0]' "$handoff")" = "$prior"
    feedback_archive_validate_records "$handoff"; PASS=$((PASS + 1))
  fi
  check test "$(wc -l <"$TMP/api-calls" | tr -d ' ')" = 1
  check grep -Fq 'repos/acme/widget/pulls/7' "$TMP/api-calls"
done
# Native same-repository restoration must precede registry loading too: there
# is no relay marker to hold this path if the sole Actions record disappears.
for damage in missing malformed invalid-yaml; do
  case "$damage" in
    missing) printf 'available_reviewers: []\n' >"$TMP/producer/.github/review-policy.yml" ;;
    malformed) printf 'feedback_archive: {identities: invalid}\n' >"$TMP/producer/.github/review-policy.yml" ;;
    invalid-yaml) printf 'feedback_archive: [\n' >"$TMP/producer/.github/review-policy.yml" ;;
  esac
  # The paired renderer calls prove damaged enrollment cannot change either
  # the restoration result or the inert result for unrelated Actions text.
  out=$(CONFIG="$TMP/producer/.github/review-policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/restoration")
  check test "$out" = "$record"
  printf '**P1** Actions narration is not an enrolled review.\n' >"$TMP/actions-narration"
  rc=0
  out=$(CONFIG="$TMP/producer/.github/review-policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/actions-narration") || rc=$?
  check test "$rc" = 0
  check test -z "$out"
  printf '<!-- mergepath-feedback-archive:v1 AA== -->\n' >"$TMP/invalid-actions-record"
  rc=0
  out=$(CONFIG="$TMP/producer/.github/review-policy.yml" "$ROOT/scripts/render-feedback-archive.sh" issue-comment 8 'github-actions[bot]' 2026-10-11T02:00:00Z "$TMP/invalid-actions-record") || rc=$?
  check test "$rc" = 2
  check test -z "$out"
  jq -n --arg prior "$record" '{action:"deleted",issue:{number:7},comment:{id:8,user:{login:"github-actions[bot]"},body:$prior,updated_at:"2026-10-11T02:00:00Z"}}' >"$TMP/event"
  : >"$TMP/output"; : >"$TMP/api-calls"; rm -f "$TMP/native-post"
  (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" GH_NATIVE_RESTORE=true NATIVE_POST_FILE="$TMP/native-post" \
    CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=issue_comment EVENT_ACTION=deleted \
    GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >"$TMP/native-$damage.log" 2>&1
  check test "$(jq -r '.body' "$TMP/native-post")" = "$record"
  check grep -Fq 'requires_relay=false' "$TMP/output"
  jq '.comment.user.login="never-registered"' "$TMP/event" >"$TMP/fresh-event"
  rm -f "$TMP/native-post"
  rc=0
  (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" GH_NATIVE_RESTORE=true NATIVE_POST_FILE="$TMP/native-post" \
    CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=issue_comment EVENT_ACTION=deleted \
    GITHUB_EVENT_PATH="$TMP/fresh-event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >"$TMP/fresh-$damage.log" 2>&1 || rc=$?
  check test "$rc" != 0
  check test ! -e "$TMP/native-post"
  for action in edited deleted; do
    jq -n --arg action "$action" --rawfile prior "$TMP/actions-narration" '{action:$action,issue:{number:7},comment:{id:8,user:{login:"github-actions[bot]"},body:$prior,updated_at:"2026-10-11T02:00:00Z"},changes:{body:{from:$prior}}}' >"$TMP/event"
    : >"$TMP/output"; : >"$TMP/api-calls"
    rc=0
    (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" GH_NATIVE_RESTORE=true NATIVE_POST_FILE="$TMP/native-post" \
      CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=issue_comment EVENT_ACTION="$action" \
      GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >"$TMP/narration-$damage-$action.log" 2>&1 || rc=$?
    check test "$rc" = 0
    check test ! -e "$TMP/native-post"
    check grep -Fq 'requires_relay=false' "$TMP/output"
    check test "$(wc -l <"$TMP/api-calls" | tr -d ' ')" = 1
    check grep -Fq 'repos/acme/widget/pulls/7' "$TMP/api-calls"
  done
done
# Archive-time GHAS failed-read and successful markerless-read behavior is
# exercised through the actual producer, preserving its one-shot API lookup.
for role in retained current delayed; do
  cp "$TMP/policy.yml" "$TMP/producer/.github/review-policy.yml"
  if [ "$role" != retained ]; then
    sed 's/provider: ghas, status: active/provider: coderabbit, status: retired/' "$TMP/policy.yml" >"$TMP/producer/.github/review-policy.yml"
  fi
  if [ "$role" = delayed ]; then
    sed 's/code_scanning: {bot_login: "custom-ghas\[bot\]"}/code_scanning: {bot_login: "third-ghas[bot]"}/' "$TMP/producer/.github/review-policy.yml" >"$TMP/third-policy.yml"
    mv "$TMP/third-policy.yml" "$TMP/producer/.github/review-policy.yml"
  fi
  for result in failed empty; do
    jq -n '{action:"deleted",comment:{id:9,user:{login:"custom-ghas[bot]"},body:"Alert https://github.com/acme/widget/security/code-scanning/26",updated_at:"2026-10-11T01:00:00Z"},pull_request:{number:7,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{fork:true}},user:{login:"author"}}}' >"$TMP/event"
    : >"$TMP/output"; : >"$TMP/api-calls"
    rm -f "$TMP/codex-p1-read-only-handoff.json"
    (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" GHAS_MOCK="$result" \
      CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=pull_request_review_comment EVENT_ACTION=deleted \
      GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >"$TMP/ghas-$result.log" 2>&1
    handoff="$TMP/codex-p1-read-only-handoff.json"
    tiers='["p2"]'; { [ "$result" != failed ] && [ "$role" != delayed ]; } || tiers='["p0","p1","p2","p3"]'
    check test "$(jq -c '.archive_records[0] | capture("^<!-- mergepath-feedback-archive:v1 (?<data>.+) -->$").data | @base64d | fromjson | .ghas_tiers' "$handoff")" = "$tiers"
    feedback_archive_validate_records "$handoff"; PASS=$((PASS + 1))
    if [ "$role" = delayed ]; then
      check test ! -s "$TMP/api-calls"
      check test "$(jq -r '.archive_records[0] | capture("^<!-- mergepath-feedback-archive:v1 (?<data>.+) -->$").data | @base64d | fromjson | .body' "$handoff")" = 'Alert https://github.com/acme/widget/security/code-scanning/26'
    else
      check test "$(wc -l <"$TMP/api-calls" | tr -d ' ')" = 1
      check grep -Fq 'code-scanning/alerts/26' "$TMP/api-calls"
    fi
  done
done
# Alert-link recognition grants neither fresh enrollment nor new source kinds.
for boundary in never-enrolled non-inline-retained-cr non-inline-retained-ghas; do
  cp "$TMP/omitted-policy.yml" "$TMP/producer/.github/review-policy.yml"
  login='custom-ghas[bot]'; event=pull_request_review; action=edited
  if [ "$boundary" = never-enrolled ]; then login=never-registered; event=pull_request_review_comment; action=deleted;
  elif [ "$boundary" = non-inline-retained-cr ]; then
    sed 's/provider: ghas, status: active/provider: coderabbit, status: retired/' "$TMP/policy.yml" >"$TMP/producer/.github/review-policy.yml"
  fi
  jq -n --arg login "$login" --arg action "$action" '{action:$action,comment:{id:9,user:{login:$login},body:"Alert https://github.com/acme/widget/security/code-scanning/26",updated_at:"2026-10-11T01:00:00Z"},review:{id:9,user:{login:$login},body:"Alert https://github.com/acme/widget/security/code-scanning/26",submitted_at:"2026-10-11T01:00:00Z"},changes:{body:{from:"Alert https://github.com/acme/widget/security/code-scanning/26"}},pull_request:{number:7,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{fork:true}},user:{login:"author"}}}' >"$TMP/event"
  : >"$TMP/output"; : >"$TMP/api-calls"
  rm -f "$TMP/codex-p1-read-only-handoff.json"
  (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" \
    CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME="$event" EVENT_ACTION="$action" \
    GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >"$TMP/boundary-$boundary.log" 2>&1
  check test "$(jq '.archive_records|length' "$TMP/codex-p1-read-only-handoff.json")" = 0
  if [ "$boundary" = never-enrolled ]; then check test ! -s "$TMP/api-calls";
  else check grep -Fq 'actions/runs/42' "$TMP/api-calls"; fi
  check test "$(grep -c 'code-scanning/alerts/' "$TMP/api-calls" || true)" = 0
done
printf 'feedback-archive-identities: PASS (%s assertions)\n' "$PASS"
