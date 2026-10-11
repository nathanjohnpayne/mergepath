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
feedback_archive:
  identities:
    - {login: retired-reviewer, provider: reviewer, status: retired}
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
check test "$rc" = 2
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
jq -n --arg record "$record" '{archive_source:{kind:"issue-comment",login:"github-actions[bot]",id:8},archive_records:[$record]}' >"$TMP/restored-handoff"
feedback_archive_validate_records "$TMP/restored-handoff"
PASS=$((PASS + 1))
# A no-match parser result must not vacuously validate an oversized restored
# chunk. Restoration is bounded even though only one part can be recovered.
jq -n '{archive_source:{kind:"issue-comment",login:"github-actions[bot]"},archive_records:[("<!-- mergepath-feedback-archive:v2 id=" + ("a" * 64) + " part=1/2 data=" + ("a" * 60001) + " -->")]}' >"$TMP/oversized-restoration"
rc=0; feedback_archive_validate_records "$TMP/oversized-restoration" || rc=$?
check test "$rc" = 2
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
  *--method*POST*) echo 'Unexpected live-write path in offline producer test' >&2; exit 99 ;;
  *pulls/7*) printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"fork":true}},"user":{"login":"author"}}\n' ;;
  *) echo 'Unexpected API path' >&2; exit 98 ;;
esac
SH
chmod +x "$TMP/bin/gh"
for actor in ordinary 'dependabot[bot]'; do
  for action in edited deleted; do
    for login in never-registered retired-reviewer; do
      jq -n --arg action "$action" --arg login "$login" --arg actor "$actor" --rawfile old "$TMP/body" '{action:$action,comment:{id:7,user:{login:$login},body:$old,updated_at:"2026-10-11T01:00:00Z"},changes:{body:{from:$old}},pull_request:{number:7,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:{fork:($actor=="ordinary")}},user:{login:$actor}}}' >"$TMP/event"
      : >"$TMP/output"; : >"$TMP/api-calls"
      (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" GH_TOKEN=fake-offline GH_CALL_LOG="$TMP/api-calls" \
        CONFIG="$TMP/producer/.github/review-policy.yml" REPO=acme/widget EVENT_NAME=pull_request_review_comment EVENT_ACTION="$action" \
        GITHUB_EVENT_PATH="$TMP/event" GITHUB_OUTPUT="$TMP/output" RUNNER_TEMP="$TMP" \
        SOURCE_RUN_ID=42 GITHUB_RUN_ID=42 bash "$TMP/producer.sh") >/dev/null
      handoff="$TMP/codex-p1-read-only-handoff.json"
      if [ "$login" = never-registered ]; then
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
printf 'feedback-archive-identities: PASS (%s assertions)\n' "$PASS"
