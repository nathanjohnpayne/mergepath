#!/usr/bin/env bash
# tests/test_post_phase_4b_handoff.sh
#
# Unit tests for scripts/post-phase-4b-handoff.sh (chat-side Phase 4b
# handoff block renderer — see nathanjohnpayne/mergepath#281).
#
# Strategy: PATH-shim `gh` so the script's `gh api repos/.../pulls/N`
# and `gh api graphql` calls return canned fixture JSON. No live
# GitHub network. Mirrors the shim pattern from
# tests/test_codex_p1_gate.sh.
#
# Cases covered:
#   1. Single-PR render — sync branch → "verbatim mirror" line.
#   2. Single-PR render — non-sync branch → "novel work" line.
#   3. Batch render — both rows mirror-typed → shared context surfaces
#      the mirror classification (not "mixed").
#   4. Batch render — mixed mirror + novel → "mixed — see table above".
#   5. Usage (no args) → exit 2.
#   6. Invalid ref format → exit 2.
#   7. Unaccounted feedback → exit 4 before handoff metadata/rendering.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/post-phase-4b-handoff.sh"

export GH_TOKEN=test-token

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (post-phase-4b-handoff.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/post-4b-handoff-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# PATH-shim `gh`. The shim routes by endpoint:
#   - `gh api repos/<owner>/<repo>/pulls/<num>` → $FIXTURE_DIR/<owner>__<repo>__<num>.pr.json
#   - `gh api graphql ...` → $FIXTURE_DIR/<owner>__<repo>__<num>.threads.json
#     (the owner/name/num is read from the -F flags the script passes).
# Anything else: empty success.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
FIXTURE_DIR="$WORKDIR/fixtures"
mkdir -p "$FIXTURE_DIR"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh shim for post-phase-4b-handoff tests.
FIXTURE_DIR="${FIXTURE_DIR:?FIXTURE_DIR must be set}"
[ -z "${HANDOFF_GH_LOG:-}" ] || printf '%s\n' "$*" >>"$HANDOFF_GH_LOG"

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  # `gh repo view --json owner,name --jq '.owner.login + "/" + .name'`
  printf '%s' "${CURRENT_REPO_OVERRIDE-nathanjohnpayne/mergepath}"
  exit "${CURRENT_REPO_RC:-0}"
fi

if [ "$1" = "api" ]; then
  shift
  raw_args="$*"
  endpoint=""
  owner=""
  name=""
  num=""

  # Walk remaining args. `gh api graphql -F owner=... -F name=... -F num=...`
  # or `gh api repos/<owner>/<repo>/pulls/<num>`.
  while [ $# -gt 0 ]; do
    case "$1" in
      graphql)
        endpoint="graphql"; shift ;;
      -F)
        case "$2" in
          owner=*) owner="${2#owner=}" ;;
          name=*)  name="${2#name=}" ;;
          num=*)   num="${2#num=}" ;;
        esac
        shift 2 ;;
      -f)
        shift 2 ;;
      repos/*)
        endpoint="$1"
        # Parse repos/<owner>/<repo>/pulls/<num>
        rest="${endpoint#repos/}"
        owner="${rest%%/*}"; rest="${rest#*/}"
        name="${rest%%/*}"; rest="${rest#*/}"
        # rest now "pulls/<num>"
        num="${rest##*/}"
        shift ;;
      *)
        shift ;;
    esac
  done

  if [[ "$endpoint" == */contents/.github/review-policy.yml* ]]; then
    [ "${MOCK_POLICY_UNREADABLE:-0}" != 1 ] || exit 1
    cat "$FIXTURE_DIR/review-policy.yml"
    exit 0
  fi

  if [[ "$endpoint" =~ ^repos/([^/]+)/([^/]+)/(pulls|issues)/([0-9]+)/(comments|reviews)$ ]]; then
    owner="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[4]}"
    kind="${BASH_REMATCH[3]}-${BASH_REMATCH[5]}"
    [ "${MOCK_HISTORY_UNREADABLE:-0}" != 1 ] || exit 1
    f="$FIXTURE_DIR/${owner}__${name}__${num}.$kind.json"
    if [ -f "$f" ]; then jq -s '.' "$f"; else printf '[[]]'; fi
    exit 0
  fi
  if [[ "$endpoint" == repos/*/events?per_page=100 ]]; then
    [ "${MOCK_EVENTS_UNREADABLE:-0}" != 1 ] || exit 1
    printf '[%s]' "${MOCK_EVENTS_JSON:-[]}"
    exit 0
  fi
  if [[ "$endpoint" == repos/*/issues/*/timeline ]]; then
    [ "${MOCK_TIMELINE_UNREADABLE:-0}" != 1 ] || exit 1
    printf '[%s]' "${MOCK_TIMELINE_JSON:-[]}"
    exit 0
  fi
  if [[ "$endpoint" == repos/*/commits/* ]]; then
    printf '%s' "${MOCK_HEAD_TIME:-2026-01-01T00:00:00Z}"
    exit 0
  fi
  if [[ "$raw_args" == *"--jq .head.sha"* ]]; then
    [ "${MOCK_HEAD_MOVED:-0}" != 1 ] || { printf moved; exit 0; }
    jq -r .head.sha "$FIXTURE_DIR/${owner}__${name}__${num}.pr.json"
    exit 0
  fi
  if [ "$endpoint" = "graphql" ]; then
    f="$FIXTURE_DIR/${owner}__${name}__${num}.threads.json"
  else
    f="$FIXTURE_DIR/${owner}__${name}__${num}.pr.json"
  fi

  if [ -r "$f" ]; then
    cat "$f"
    exit 0
  fi
  exit 1
fi

exit 0
STUB
chmod +x "$STUB_DIR/gh"

export PATH="$STUB_DIR:$PATH"
export FIXTURE_DIR
cat >"$WORKDIR/accounting.sh" <<'STUB'
#!/bin/sh
[ -z "${HANDOFF_ACCOUNTING_LOG:-}" ] || printf '%s\t%s\n' "$1" "$2" >>"$HANDOFF_ACCOUNTING_LOG"
jq -nc --arg repo "$2" --argjson pr "$1" '{status:"clear",repo:$repo,pr_number:$pr,posted:2,accounted:2,missing_count:0}'
STUB
chmod +x "$WORKDIR/accounting.sh"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$WORKDIR/accounting.sh"
cat >"$FIXTURE_DIR/review-policy.yml" <<'YAML'
available_reviewers:
  - nathanpayne-codex
  - nathanpayne-claude
  - nathanpayne-cursor
YAML

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------
write_pr_fixture() {
  # write_pr_fixture <owner> <repo> <num> <head_ref> <head_sha> <base_sha> <commits>
  local owner="$1" repo="$2" num="$3" head_ref="$4" head_sha="$5" base_sha="$6" commits="$7"
  local f="$FIXTURE_DIR/${owner}__${repo}__${num}.pr.json"
  cat >"$f" <<EOF
{
  "html_url": "https://github.com/${owner}/${repo}/pull/${num}",
  "commits": ${commits},
  "head": { "sha": "${head_sha}", "ref": "${head_ref}", "repo": {"id":12345,"full_name":"${owner}/${repo}"} },
  "base": { "sha": "${base_sha}", "ref": "main", "repo": {"default_branch": "main"} }
}
EOF
  jq --arg body "${8-Authoring-Agent: codex}" '. + {body: $body}' "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

write_threads_fixture() {
  # write_threads_fixture <owner> <repo> <num> <unresolved_count>
  local owner="$1" repo="$2" num="$3" n="$4"
  local f="$FIXTURE_DIR/${owner}__${repo}__${num}.threads.json"
  local nodes=""
  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ -z "$nodes" ]; then
      nodes='{"isResolved": false}'
    else
      nodes="${nodes}, {\"isResolved\": false}"
    fi
    i=$((i + 1))
  done
  # Always include at least one resolved node so the array isn't empty
  # in the n=0 case (the script filters by isResolved=false anyway).
  if [ -z "$nodes" ]; then
    nodes='{"isResolved": true}'
  else
    nodes="${nodes}, {\"isResolved\": true}"
  fi
  cat >"$f" <<EOF
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [ ${nodes} ]
        }
      }
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Case 1: Single-PR — sync branch → "verbatim mirror".
# ---------------------------------------------------------------------------
write_pr_fixture nathanjohnpayne mergepath 281 \
  "mergepath-sync/abcdef1234567890" \
  "1111111111111111111111111111111111111111" \
  "2222222222222222222222222222222222222222" \
  1
write_threads_fixture nathanjohnpayne mergepath 281 2

OUT="$("$SCRIPT" nathanjohnpayne/mergepath#281 2>"$WORKDIR/render-error")"
if [ ! -s "$WORKDIR/render-error" ] \
   && printf '%s' "$OUT" | grep "PR ready for external review (Phase 4b):" >/dev/null \
   && printf '%s' "$OUT" | grep "verbatim mirror of mergepath@abcdef123456" >/dev/null \
   && printf '%s' "$OUT" | grep "https://github.com/nathanjohnpayne/mergepath/pull/281" >/dev/null \
   && printf '%s' "$OUT" | grep "head 1111111" >/dev/null \
   && printf '%s' "$OUT" | grep "(base 2222222)" >/dev/null \
   && printf '%s' "$OUT" | grep "Threads: 0 undispositioned findings" >/dev/null \
   && printf '%s' "$OUT" | grep "resolve addressed bot or agent-reviewer" >/dev/null \
   && printf '%s' "$OUT" | grep "(b) APPROVED as nathanpayne-claude on the listed HEAD, AND" >/dev/null \
   && ! printf '%s' "$OUT" | grep "reaction newer" >/dev/null; then
  pass "single-PR mirror render contains expected fields"
else
  fail "single-PR mirror render missing expected fields"
  echo "--- OUTPUT ---" >&2
  printf '%s\n' "$OUT" >&2
  echo "--- END ---" >&2
fi

# Scoped sync-all branches retain the mirror classification while malformed
# suffixes do not widen the trusted branch grammar.
write_pr_fixture nathanjohnpayne mergepath 283 \
  "mergepath-sync/sync-all-abcdef1234567890-0123456789ab" \
  "3333333333333333333333333333333333333333" \
  "2222222222222222222222222222222222222222" \
  1
write_threads_fixture nathanjohnpayne mergepath 283 0
SCOPED_OUT="$("$SCRIPT" nathanjohnpayne/mergepath#283)"
printf '%s' "$SCOPED_OUT" | grep "verbatim mirror of mergepath@abcdef123456" >/dev/null \
  && pass "scoped sync-all branch retains mirror classification" \
  || fail "scoped sync-all branch was not classified as a mirror"

write_pr_fixture nathanjohnpayne mergepath 286 \
  "mergepath-sync/sync-all-ABCDEF1234567890-0123456789ab" \
  "6666666666666666666666666666666666666666" \
  "2222222222222222222222222222222222222222" \
  1
write_threads_fixture nathanjohnpayne mergepath 286 0
UPPER_SCOPED_OUT="$("$SCRIPT" nathanjohnpayne/mergepath#286)"
printf '%s' "$UPPER_SCOPED_OUT" | grep "novel work" >/dev/null \
  && pass "uppercase source SHA is rejected in the scoped sync-all form" \
  || fail "uppercase source SHA widened the scoped sync-all grammar"

write_pr_fixture nathanjohnpayne mergepath 284 \
  "mergepath-sync/sync-all-abcdef1234567890-bad" \
  "4444444444444444444444444444444444444444" \
  "2222222222222222222222222222222222222222" \
  1
write_threads_fixture nathanjohnpayne mergepath 284 0
MALFORMED_OUT="$("$SCRIPT" nathanjohnpayne/mergepath#284)"
printf '%s' "$MALFORMED_OUT" | grep "novel work" >/dev/null \
  && pass "malformed sync-all scope suffix is not trusted as a mirror" \
  || fail "malformed sync-all scope suffix widened mirror classification"

write_pr_fixture nathanjohnpayne mergepath 285 \
  "mergepath-sync/sync-all-a-0123456789ab" \
  "5555555555555555555555555555555555555555" \
  "2222222222222222222222222222222222222222" \
  1
write_threads_fixture nathanjohnpayne mergepath 285 0
SHORT_SHA_OUT="$("$SCRIPT" nathanjohnpayne/mergepath#285)"
printf '%s' "$SHORT_SHA_OUT" | grep "novel work" >/dev/null \
  && pass "short source sha in scoped sync-all branch is not trusted as a mirror" \
  || fail "short source sha widened scoped mirror classification"

# ---------------------------------------------------------------------------
# Case 2: Single-PR — non-sync branch → "novel work".
# ---------------------------------------------------------------------------
write_pr_fixture nathanjohnpayne mergepath 42 \
  "feat/some-feature" \
  "3333333333333333333333333333333333333333" \
  "4444444444444444444444444444444444444444" \
  3
write_threads_fixture nathanjohnpayne mergepath 42 0

OUT="$("$SCRIPT" nathanjohnpayne/mergepath#42)"
if printf '%s' "$OUT" | grep "Context: novel work" >/dev/null \
   && printf '%s' "$OUT" | grep "head 3333333" >/dev/null \
   && printf '%s' "$OUT" | grep "(base 4444444)" >/dev/null \
   && printf '%s' "$OUT" | grep "Threads: 0 undispositioned findings" >/dev/null; then
  pass "single-PR novel-work render contains expected fields"
else
  fail "single-PR novel-work render missing expected fields"
  echo "--- OUTPUT ---" >&2
  printf '%s\n' "$OUT" >&2
  echo "--- END ---" >&2
fi

# ---------------------------------------------------------------------------
# Case 3: Batch — all-same mirror → shared context surfaces mirror.
# ---------------------------------------------------------------------------
SHA="abcdef1234567890"
write_pr_fixture nathanjohnpayne matchline 100 \
  "mergepath-sync/${SHA}" \
  "5555555555555555555555555555555555555555" \
  "6666666666666666666666666666666666666666" \
  1
write_threads_fixture nathanjohnpayne matchline 100 1
write_pr_fixture nathanjohnpayne swipewatch 200 \
  "mergepath-sync/${SHA}" \
  "7777777777777777777777777777777777777777" \
  "8888888888888888888888888888888888888888" \
  1
write_threads_fixture nathanjohnpayne swipewatch 200 0

OUT="$("$SCRIPT" nathanjohnpayne/matchline#100 nathanjohnpayne/swipewatch#200)"
if printf '%s' "$OUT" | grep "| Repo | PR # | HEAD short SHA | Undispositioned findings | Content note | Reviewer |" >/dev/null \
   && printf '%s' "$OUT" | grep "nathanjohnpayne/matchline" >/dev/null \
   && printf '%s' "$OUT" | grep "nathanjohnpayne/swipewatch" >/dev/null \
   && printf '%s' "$OUT" | grep "Context: verbatim mirror of mergepath@abcdef123456" >/dev/null \
   && printf '%s' "$OUT" | grep "real-human threads automatically" >/dev/null \
   && ! printf '%s' "$OUT" | grep "Context: mixed" >/dev/null \
   && printf '%s' "$OUT" | grep "(c) a HEAD-anchored Codex clearance" >/dev/null \
   && ! printf '%s' "$OUT" | grep "reaction newer" >/dev/null; then
  pass "batch all-same-mirror render surfaces shared context"
else
  fail "batch all-same-mirror render missing expected shared context"
  echo "--- OUTPUT ---" >&2
  printf '%s\n' "$OUT" >&2
  echo "--- END ---" >&2
fi

# ---------------------------------------------------------------------------
# Case 4: Batch — mixed mirror + novel → "mixed — see table above".
# ---------------------------------------------------------------------------
write_pr_fixture nathanjohnpayne matchline 101 \
  "mergepath-sync/${SHA}" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  1
write_threads_fixture nathanjohnpayne matchline 101 0
write_pr_fixture nathanjohnpayne swipewatch 201 \
  "feat/unrelated" \
  "cccccccccccccccccccccccccccccccccccccccc" \
  "dddddddddddddddddddddddddddddddddddddddd" \
  5
write_threads_fixture nathanjohnpayne swipewatch 201 2

OUT="$("$SCRIPT" nathanjohnpayne/matchline#101 nathanjohnpayne/swipewatch#201)"
if printf '%s' "$OUT" | grep "Context: mixed" >/dev/null \
   && printf '%s' "$OUT" | grep "verbatim mirror of mergepath@" >/dev/null \
   && printf '%s' "$OUT" | grep "novel work" >/dev/null; then
  pass "batch mixed render flags 'mixed — see table above'"
else
  fail "batch mixed render did not flag mixed context"
  echo "--- OUTPUT ---" >&2
  printf '%s\n' "$OUT" >&2
  echo "--- END ---" >&2
fi

# ---------------------------------------------------------------------------
# Case 5: Usage (no args) → exit 2.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  pass "no-args invocation exits 2"
else
  fail "no-args invocation returned rc=$rc (expected 2)"
fi

# ---------------------------------------------------------------------------
# Case 6: Invalid ref format → exit 2.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" "not-a-valid-ref" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  pass "invalid ref format exits 2"
else
  fail "invalid ref returned rc=$rc (expected 2)"
fi

# ---------------------------------------------------------------------------
# Case 6b: malformed successful resolution must not produce an empty artifact.
# Empty is distinct from an unset fixture override; account every valid ref
# only after the complete parsed input has passed validation (#1441).
# ---------------------------------------------------------------------------
for scenario in empty failed empty-pr empty-row later-empty-pr mixed-empty; do
  resolved_repo=''; resolver_rc=0; diagnostic='empty repository'
  refs=(281)
  case "$scenario" in
    failed) resolver_rc=1; diagnostic='not a gh-resolvable repo' ;;
    empty-pr) resolved_repo=$'\t'; diagnostic='invalid parsed pr-ref' ;;
    empty-row) resolved_repo=$'\nnathanjohnpayne/mergepath'; diagnostic='invalid parsed pr-ref' ;;
    later-empty-pr) resolved_repo=$'nathanjohnpayne/mergepath\t281\n\t'; diagnostic='invalid parsed pr-ref' ;;
    mixed-empty) refs=(nathanjohnpayne/mergepath#281 281) ;;
  esac
  : >"$WORKDIR/ref-accounting.log"
  rc=0
  OUT=$(CURRENT_REPO_OVERRIDE="$resolved_repo" CURRENT_REPO_RC="$resolver_rc" \
    HANDOFF_ACCOUNTING_LOG="$WORKDIR/ref-accounting.log" \
    "$SCRIPT" "${refs[@]}" 2>"$WORKDIR/ref-error") || rc=$?
  if [ "$rc" -eq 3 ] && [ -z "$OUT" ] && [ ! -s "$WORKDIR/ref-accounting.log" ] \
     && grep -Fq "$diagnostic" "$WORKDIR/ref-error"; then
    pass "#1441 $scenario resolution refuses before accounting or rendering"
  else
    fail "#1441 $scenario returned rc=$rc, accounting=$(cat "$WORKDIR/ref-accounting.log"), stdout=$OUT"
    cat "$WORKDIR/ref-error" >&2
  fi
done

for form in bare explicit; do
  refs=(281)
  resolver_rc=0
  [ "$form" != explicit ] || { refs=(nathanjohnpayne/mergepath#281); resolver_rc=1; }
  : >"$WORKDIR/ref-accounting.log"
  : >"$WORKDIR/ref-gh.log"
  rc=0
  OUT=$(CURRENT_REPO_OVERRIDE=$'nathanjohnpayne/mergepath\n' CURRENT_REPO_RC="$resolver_rc" \
    HANDOFF_ACCOUNTING_LOG="$WORKDIR/ref-accounting.log" HANDOFF_GH_LOG="$WORKDIR/ref-gh.log" \
    "$SCRIPT" "${refs[@]}" 2>"$WORKDIR/ref-error") || rc=$?
  if [ "$rc" -eq 0 ] && grep -Fq 'PR ready for external review' <<<"$OUT" \
     && [ "$(cat "$WORKDIR/ref-accounting.log")" = $'281\tnathanjohnpayne/mergepath' ] \
     && { [ "$form" != explicit ] || ! grep -q '^repo view ' "$WORKDIR/ref-gh.log"; }; then
    pass "#1441 $form ref preserves accounting and ready artifact with structural newlines"
  else
    fail "#1441 $form ref returned rc=$rc or lost its valid artifact/accounting"
    cat "$WORKDIR/ref-error" >&2
  fi
done

# ---------------------------------------------------------------------------
# Case 7: The manual handoff path is a reviewer dispatch too. It must stop on
# unaccounted feedback before reading PR metadata or rendering a paste prompt.
# ---------------------------------------------------------------------------
BLOCK_GATE="$WORKDIR/block-feedback.sh"
cat >"$BLOCK_GATE" <<'EOF'
#!/bin/sh
printf '%s\n' '{"status":"unaccounted","posted":2,"accounted":1}'
exit 1
EOF
chmod +x "$BLOCK_GATE"
set +e
OUT=$(MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$BLOCK_GATE" \
  "$SCRIPT" nathanjohnpayne/mergepath#281 2>&1)
rc=$?
set -e
if [ "$rc" -eq 4 ] \
   && printf '%s' "$OUT" | grep "no handoff rendered" >/dev/null \
   && ! printf '%s' "$OUT" | grep "PR ready for external review" >/dev/null; then
  pass "unaccounted feedback blocks the manual Phase 4b handoff"
else
  fail "unaccounted feedback returned rc=$rc or rendered a handoff"
  printf '%s\n' "$OUT" >&2
fi

# Cross-agent selection is per PR, including mixed-author batches.
write_pr_fixture nathanjohnpayne mergepath 43 feat/claude \
  3333333333333333333333333333333333333333 \
  4444444444444444444444444444444444444444 1 'Authoring-Agent: claude'
write_threads_fixture nathanjohnpayne mergepath 43 0
OUT=$("$SCRIPT" nathanjohnpayne/mergepath#43)
if printf '%s' "$OUT" | grep '(b) APPROVED as nathanpayne-codex' >/dev/null \
   && ! printf '%s' "$OUT" | grep 'HEAD, OR' >/dev/null; then
  pass "Claude author selects a registered cross-agent reviewer and AND gate"
else
  fail "Claude author got an invalid reviewer or gate"
fi
OUT=$("$SCRIPT" nathanjohnpayne/mergepath#42 nathanjohnpayne/mergepath#43)
if printf '%s' "$OUT" | grep 'head 3333333.*reviewer nathanpayne-claude' >/dev/null \
   && printf '%s' "$OUT" | grep 'head 3333333.*reviewer nathanpayne-codex' >/dev/null \
   && printf '%s' "$OUT" | grep 'its listed reviewer on HEAD, AND' >/dev/null; then
  pass "mixed-author batch retains each PR's cross-agent reviewer"
else
  fail "mixed-author batch lost its reviewer association or conjunction"
fi
OUT=$(PHASE_4B_REVIEWER_IDENTITY=nathanpayne-cursor "$SCRIPT" nathanjohnpayne/mergepath#42)
printf '%s' "$OUT" | grep '(b) APPROVED as nathanpayne-cursor' >/dev/null \
  && pass "registered cross-agent override is honored" \
  || fail "valid cross-agent override was lost"
# The governing default wins over list order, but cannot select the author.
cp "$FIXTURE_DIR/review-policy.yml" "$WORKDIR/default-policy.yml"
printf '\ndefault_external_reviewer: nathanpayne-cursor\n' >> "$FIXTURE_DIR/review-policy.yml"
OUT=$("$SCRIPT" nathanjohnpayne/mergepath#43)
printf '%s' "$OUT" | grep '(b) APPROVED as nathanpayne-cursor' >/dev/null \
  && pass "governing default reviewer wins over available-reviewer order" \
  || fail "configured default reviewer was ignored"
cp "$WORKDIR/default-policy.yml" "$FIXTURE_DIR/review-policy.yml"
printf '\ndefault_external_reviewer: nathanpayne-claude\n' >> "$FIXTURE_DIR/review-policy.yml"
OUT=$("$SCRIPT" nathanjohnpayne/mergepath#43)
printf '%s' "$OUT" | grep '(b) APPROVED as nathanpayne-codex' >/dev/null \
  && pass "same-author default falls back to a registered cross-agent reviewer" \
  || fail "same-author default bypassed cross-agent selection"
cp "$WORKDIR/default-policy.yml" "$FIXTURE_DIR/review-policy.yml"
for override in nathanpayne-codex NathanPayne-Codex unregistered-reviewer; do
  rc=0
  OUT=$(PHASE_4B_REVIEWER_IDENTITY="$override" "$SCRIPT" nathanjohnpayne/mergepath#42 2>"$WORKDIR/error") || rc=$?
  if [ "$rc" -eq 3 ] && [ -z "$OUT" ]; then
    pass "invalid reviewer override $override renders no handoff"
  else
    fail "invalid reviewer override $override returned $rc or rendered"
  fi
done
for body in '' 'Authoring-Agent: unknown' $'Authoring-Agent: codex\nAuthoring-Agent: claude' $'```\nAuthoring-Agent: codex\n```'; do
  write_pr_fixture nathanjohnpayne mergepath 44 feat/invalid \
    3333333333333333333333333333333333333333 \
    4444444444444444444444444444444444444444 1 "$body"
  rc=0
  OUT=$("$SCRIPT" nathanjohnpayne/mergepath#44 2>"$WORKDIR/error") || rc=$?
  if [ "$rc" -eq 3 ] && [ -z "$OUT" ]; then
    pass "missing, unknown, ambiguous or fenced author renders no handoff"
  else
    fail "invalid author returned $rc or rendered"
  fi
done
rc=0
OUT=$(MOCK_POLICY_UNREADABLE=1 "$SCRIPT" nathanjohnpayne/mergepath#42 2>"$WORKDIR/error") || rc=$?
if [ "$rc" -eq 3 ] && [ -z "$OUT" ]; then
  pass "unreadable governing policy renders no handoff"
else
  fail "unreadable policy returned $rc or rendered"
fi


# #2157: shared Running summary and outstanding current-head requests suppress
# every artifact, including a batch whose other PR is already ready.
HEAD=3333333333333333333333333333333333333333
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REQUEST=$(jq -nc --arg now "$NOW" '[{id:801,user:{login:"nathanjohnpayne"},created_at:$now,body:"@codex review"}]')
RUNNING=$(jq -nc --arg now "$NOW" --arg head "$HEAD" \
  '[{id:802,user:{login:"chatgpt-codex-connector[bot]"},created_at:$now,updated_at:$now,body:("<!-- codex-pull-request-review-summary -->\n| 📝 **Code Review** | **Running** | `" + $head + "` | New commits |")}]')
for scenario in running requested completed stale-summary timed-out history-unreadable head-moved batch-running invalid-accounting stale-response newer-response malformed-history disabled terminal-usage terminal-connection stale-terminal spoofed-terminal renewed-request terminal-after-running running-after-terminal before-force after-force running-after-force future-date-request future-date-running future-date-timeout timeline-unreadable malformed-transition ordinary-before ordinary-after ordinary-same-second ordinary-running ordinary-unknown ordinary-wrong-id ordinary-wrong-name ordinary-wrong-ref ordinary-wrong-head ordinary-short-head ordinary-malformed ordinary-unavailable ordinary-absent ordinary-no-change ordinary-created-branch ordinary-out-of-order; do
  history='[]'; reviews='[]'; expected=0; timeline='[]'; events='[]'; head_time=2026-01-01T00:00:00Z
  case "$scenario" in
    ordinary-*)
      history="$REQUEST"; expected=5
      events=$(jq -nc --arg now "$NOW" --arg head "$HEAD" --arg scenario "$scenario" '
        [{type:"PushEvent",repo:{id:12345,name:"nathanjohnpayne/mergepath"},
          payload:{ref:"refs/heads/feat/some-feature",head:$head,before:"4444444444444444444444444444444444444444"},
          created_at:($now | fromdateiso8601 | . + (if $scenario == "ordinary-after" then -1 elif $scenario == "ordinary-same-second" then 0 else 1 end) | todateiso8601)}]
        | if $scenario == "ordinary-wrong-id" then .[0].repo.id=98765
          elif $scenario == "ordinary-wrong-name" then .[0].repo.name="other/fork"
          elif $scenario == "ordinary-wrong-ref" then .[0].payload.ref="refs/heads/other"
          elif $scenario == "ordinary-wrong-head" then .[0].payload.head=.[0].payload.before
          elif $scenario == "ordinary-short-head" then .[0].payload.head=($head[0:12])
          elif $scenario == "ordinary-malformed" then .[0].created_at="invalid"
          elif $scenario == "ordinary-no-change" then .[0].payload.before=$head
          elif $scenario == "ordinary-created-branch" then .[0].payload.before="0000000000000000000000000000000000000000"
          elif $scenario == "ordinary-absent" then []
          elif $scenario == "ordinary-out-of-order" then [.[0] | .created_at=($now | fromdateiso8601 | .-1 | todateiso8601)] + .
          else . end')
      case "$scenario" in
        ordinary-before|ordinary-out-of-order) expected=0; head_time=2999-01-01T00:00:00Z ;;
        ordinary-running|ordinary-unknown)
          history=$(jq -nc --argjson request "$REQUEST" --argjson running "$RUNNING" --arg scenario "$scenario" \
            '$request + (if $scenario == "ordinary-unknown" then $running | .[0].body |= sub("Running";"Unrecognized") else $running end)') ;;
      esac
      ;;
    running|batch-running) history="$RUNNING"; expected=5 ;;
    requested) history="$REQUEST"; expected=5 ;;
    before-force|after-force|running-after-force|malformed-transition)
      history="$REQUEST"
      timeline=$(jq -nc --arg now "$NOW" --arg scenario "$scenario" '
        [{event:"head_ref_force_pushed",created_at:(if $scenario == "malformed-transition" then "invalid"
          else ($now | fromdateiso8601) + (if $scenario == "after-force" then -1 else 1 end) | todateiso8601 end)}]')
      case "$scenario" in
        after-force) expected=5 ;;
        running-after-force) history=$(jq -nc --argjson request "$REQUEST" --argjson running "$RUNNING" '$request + $running'); expected=5 ;;
        malformed-transition) expected=3 ;;
      esac
      ;;
    future-date-request) history="$REQUEST"; head_time=2999-01-01T00:00:00Z; expected=5 ;;
    future-date-running) history="$RUNNING"; head_time=2999-01-01T00:00:00Z; expected=5 ;;
    future-date-timeout) history=$(jq '.[0].created_at="2026-01-02T00:00:00Z"' <<<"$REQUEST"); head_time=2999-01-01T00:00:00Z ;;
    timeline-unreadable) history="$REQUEST"; expected=3 ;;
    terminal-usage|terminal-connection|stale-terminal|spoofed-terminal|renewed-request|terminal-after-running|running-after-terminal)
      history=$(jq -nc --argjson request "$REQUEST" --arg scenario "$scenario" --argjson running "$RUNNING" --arg now "$NOW" '
        ($now | fromdateiso8601) as $epoch
        | (if $scenario == "stale-terminal" then $epoch - 1 else $epoch + 1 end | todateiso8601) as $failed
        | ($epoch + 2 | todateiso8601) as $later
        | {id:804,user:{login:(if $scenario == "spoofed-terminal" then "someone-else" else "chatgpt-codex-connector[bot]" end)},created_at:$failed,
           body:(if $scenario == "terminal-connection" then "To use Codex here, configure an environment." else "You have reached your Codex usage limits for code reviews." end)} as $failure
        | $request + [$failure]
        + (if $scenario == "renewed-request" then [$request[0] | .id=805 | .created_at=$later]
           elif $scenario == "terminal-after-running" then $running
           elif $scenario == "running-after-terminal" then [$running[0] | .updated_at=$later]
           else [] end)')
      case "$scenario" in stale-terminal|spoofed-terminal|renewed-request|running-after-terminal) expected=5 ;; esac
      ;;
    completed) history="$REQUEST"; reviews=$(jq -nc --arg now "$NOW" --arg head "$HEAD" '[{id:803,user:{login:"chatgpt-codex-connector[bot]"},submitted_at:$now,commit_id:$head,state:"COMMENTED",body:"Completed review"}]') ;;
    stale-response) history="$REQUEST"; expected=5; reviews=$(jq -nc --arg head "$HEAD" '[{id:803,user:{login:"chatgpt-codex-connector[bot]"},submitted_at:"2026-01-02T00:00:00Z",commit_id:$head,state:"COMMENTED",body:"Old same-head review"}]') ;;
    newer-response) history=$(jq '.[0].updated_at="2026-01-02T00:00:00Z"' <<<"$RUNNING"); reviews=$(jq -nc --arg now "$NOW" --arg head "$HEAD" '[{id:803,user:{login:"chatgpt-codex-connector[bot]"},submitted_at:$now,commit_id:$head,state:"COMMENTED",body:"Completed review"}]') ;;
    malformed-history) history='[[]]'; expected=3 ;;
    disabled) history="$REQUEST" ;;
    stale-summary) history=$(jq '.[0].body |= sub("3333333333333333333333333333333333333333";"4444444444444444444444444444444444444444")' <<<"$RUNNING") ;;
    timed-out) history=$(jq '.[0].created_at="2026-01-02T00:00:00Z"' <<<"$REQUEST") ;;
    history-unreadable|head-moved|invalid-accounting) expected=3 ;;
  esac
  printf '%s' "$history" > "$FIXTURE_DIR/nathanjohnpayne__mergepath__42.issues-comments.json"
  printf '%s' "$reviews" > "$FIXTURE_DIR/nathanjohnpayne__mergepath__42.pulls-reviews.json"
  refs=(nathanjohnpayne/mergepath#42)
  [ "$scenario" != batch-running ] || refs=(nathanjohnpayne/mergepath#281 nathanjohnpayne/mergepath#42)
  cp "$FIXTURE_DIR/review-policy.yml" "$WORKDIR/policy-before-case.yml"
  [ "$scenario" != disabled ] || printf '\ncodex:\n  enabled: false\n' >> "$FIXTURE_DIR/review-policy.yml"
  gate="$MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD"
  [ "$scenario" != invalid-accounting ] || gate=true
  rc=0
  OUT=$(MOCK_HISTORY_UNREADABLE="$([ "$scenario" = history-unreadable ] && echo 1 || echo 0)" \
    MOCK_TIMELINE_UNREADABLE="$([ "$scenario" = timeline-unreadable ] && echo 1 || echo 0)" \
    MOCK_EVENTS_UNREADABLE="$([ "$scenario" = ordinary-unavailable ] && echo 1 || echo 0)" \
    MOCK_EVENTS_JSON="$events" \
    MOCK_TIMELINE_JSON="$timeline" MOCK_HEAD_TIME="$head_time" \
    MOCK_HEAD_MOVED="$([ "$scenario" = head-moved ] && echo 1 || echo 0)" \
    MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$gate" \
    "$SCRIPT" "${refs[@]}" 2>"$WORKDIR/error") || rc=$?
  cp "$WORKDIR/policy-before-case.yml" "$FIXTURE_DIR/review-policy.yml"
  if [ "$rc" -eq "$expected" ] && { [ "$expected" -eq 0 ] || [ -z "$OUT" ]; }; then
    pass "#2157 $scenario obeys no-artifact hold / complete accounting"
  else
    fail "#2157 $scenario returned $rc (wanted $expected), stdout=$OUT"
    cat "$WORKDIR/error" >&2
  fi
done

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
