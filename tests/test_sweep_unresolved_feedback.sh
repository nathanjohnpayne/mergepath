#!/usr/bin/env bash
# tests/test_sweep_unresolved_feedback.sh
#
# Unit tests for the #236 weekly feedback sweep pipeline:
#
#   scripts/sweep-unresolved-feedback/enumerate.sh
#   scripts/sweep-unresolved-feedback/render.sh
#
# Strategy
# --------
# enumerate.sh and render.sh both shell out to `gh`. We PATH-shim `gh`
# with fixture-driven stubs so the scripts can run end-to-end against
# synthetic data without touching the real API.
#
# Each test sets up a temp workdir, points the script at the stubbed
# `gh`, and asserts on:
#   - NDJSON shape from enumerate.sh
#   - rendered body from render.sh under SWEEP_DRY_RUN=1
#   - idempotency: a re-run with identical input produces the same hash
#
# Bash 3.2 compatible.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENUMERATE="$ROOT/scripts/sweep-unresolved-feedback/enumerate.sh"
RENDER="$ROOT/scripts/sweep-unresolved-feedback/render.sh"

for f in "$ENUMERATE" "$RENDER"; do
  [ -x "$f" ] || { echo "missing or non-executable: $f" >&2; exit 1; }
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/sweep-tests.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# PATH-shim `gh`. The stub dispatches by subcommand. Behavior is
# driven by fixture files in $STUB_FIXTURES.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
STUB_FIXTURES="$WORKDIR/fixtures"
mkdir -p "$STUB_FIXTURES"
GH_CALLS_LOG="$WORKDIR/gh-calls.log"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh — log every call + dispatch on subcommand.
LOG="${GH_CALLS_LOG:-/dev/null}"
{
  printf 'gh'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$LOG"

case "$1 $2" in
  "pr list")
    # Args we care about: --repo <r> ... --json number,title,url
    # Lookup fixture by repo.
    repo=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--repo" ]; then shift; repo="$1"; fi
      shift || break
    done
    fix="${STUB_FIXTURES}/pr-list-$(echo "$repo" | tr '/' '_').json"
    if [ -f "$fix" ]; then
      cat "$fix"
    else
      echo "[]"
    fi
    exit 0
    ;;
  "api graphql")
    # Fixture lookup by repo + pr (passed via -F owner / -F name / -F pr).
    owner="" name="" pr=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -F)
          shift
          case "$1" in
            owner=*) owner="${1#owner=}" ;;
            name=*)  name="${1#name=}" ;;
            pr=*)    pr="${1#pr=}" ;;
          esac
          ;;
      esac
      shift || break
    done
    fix="${STUB_FIXTURES}/threads-${owner}_${name}_${pr}.json"
    if [ -f "$fix" ]; then
      cat "$fix"
    else
      # Empty response (no threads)
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
    fi
    exit 0
    ;;
  "issue list")
    fix="${STUB_FIXTURES}/issue-list.json"
    if [ -f "$fix" ]; then cat "$fix"; else echo "[]"; fi
    exit 0
    ;;
  "issue create"|"issue edit"|"issue comment")
    # Record + succeed.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# ---------------------------------------------------------------------------
# Fixture 1 — single repo with two unresolved threads, one outdated
# (filtered), one resolved (filtered), one severity-P1 surviving.
# ---------------------------------------------------------------------------
cat >"$STUB_FIXTURES/pr-list-owner_alpha.json" <<'JSON'
[
  {"number": 1, "title": "Fix the thing", "url": "https://github.com/owner/alpha/pull/1"},
  {"number": 2, "title": "Add a feature", "url": "https://github.com/owner/alpha/pull/2"}
]
JSON

# PR #1: one unresolved P1 + one resolved (filtered) + one outdated
# (filtered).
cat >"$STUB_FIXTURES/threads-owner_alpha_1.json" <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "totalCount": 3,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": [
            {
              "id": "PRT_alpha_1_a",
              "isResolved": false,
              "isOutdated": false,
              "comments": {"nodes": [{
                "author": {"login": "coderabbitai[bot]"},
                "body": "P1 — Potential issue: this loop is O(n^2) and the input can grow.",
                "url": "https://github.com/owner/alpha/pull/1#discussion_r1001"
              }]}
            },
            {
              "id": "PRT_alpha_1_b",
              "isResolved": true,
              "isOutdated": false,
              "comments": {"nodes": [{
                "author": {"login": "human"},
                "body": "P0 - Critical: SQL injection here",
                "url": "https://github.com/owner/alpha/pull/1#discussion_r1002"
              }]}
            },
            {
              "id": "PRT_alpha_1_c",
              "isResolved": false,
              "isOutdated": true,
              "comments": {"nodes": [{
                "author": {"login": "human"},
                "body": "nit: rename",
                "url": "https://github.com/owner/alpha/pull/1#discussion_r1003"
              }]}
            }
          ]
        }
      }
    }
  }
}
JSON

# PR #2: one Nitpick + one no-prefix (Unknown).
cat >"$STUB_FIXTURES/threads-owner_alpha_2.json" <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "totalCount": 2,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": [
            {
              "id": "PRT_alpha_2_a",
              "isResolved": false,
              "isOutdated": false,
              "comments": {"nodes": [{
                "author": {"login": "coderabbitai[bot]"},
                "body": "🧹 Nitpick: this comment is misleading.",
                "url": "https://github.com/owner/alpha/pull/2#discussion_r2001"
              }]}
            },
            {
              "id": "PRT_alpha_2_b",
              "isResolved": false,
              "isOutdated": false,
              "comments": {"nodes": [{
                "author": {"login": "human"},
                "body": "Have you considered using a different approach?",
                "url": "https://github.com/owner/alpha/pull/2#discussion_r2002"
              }]}
            }
          ]
        }
      }
    }
  }
}
JSON

TARGETS="$WORKDIR/targets.txt"
cat >"$TARGETS" <<'EOF'
# comment line, ignored
owner/alpha

owner/missing
EOF

# ---------------------------------------------------------------------------
# Test 1: enumerate.sh emits expected NDJSON (3 surviving findings).
# ---------------------------------------------------------------------------
OUT_NDJSON="$WORKDIR/findings.ndjson"
: > "$GH_CALLS_LOG"

set +e
PATH="$STUB_DIR:$PATH" \
GH_TOKEN="dummy-pat" \
STUB_FIXTURES="$STUB_FIXTURES" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
SWEEP_OUTPUT="$OUT_NDJSON" \
  "$ENUMERATE" "$TARGETS" 2>"$WORKDIR/enum.stderr"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  fail "enumerate: exit $rc, expected 0"
  cat "$WORKDIR/enum.stderr" >&2
fi

LINES=$(wc -l < "$OUT_NDJSON" | tr -d ' ')
if [ "$LINES" != "3" ]; then
  fail "enumerate: expected 3 NDJSON lines, got $LINES"
  cat "$OUT_NDJSON" >&2
else
  pass "enumerate: emitted 3 NDJSON lines (filtered resolved + outdated)"
fi

# Check the surviving thread_ids are exactly the expected ones.
GOT_IDS=$(jq -r '.thread_id' "$OUT_NDJSON" | sort | tr '\n' ' ')
WANT_IDS="PRT_alpha_1_a PRT_alpha_2_a PRT_alpha_2_b "
if [ "$GOT_IDS" = "$WANT_IDS" ]; then
  pass "enumerate: surviving thread_ids match expected"
else
  fail "enumerate: thread_ids mismatch. got=[$GOT_IDS] want=[$WANT_IDS]"
fi

# Severity heuristic spot-check.
SEV_P1=$(jq -r 'select(.thread_id == "PRT_alpha_1_a") | .severity' "$OUT_NDJSON")
SEV_NIT=$(jq -r 'select(.thread_id == "PRT_alpha_2_a") | .severity' "$OUT_NDJSON")
SEV_UNK=$(jq -r 'select(.thread_id == "PRT_alpha_2_b") | .severity' "$OUT_NDJSON")

[ "$SEV_P1" = "P1" ]      && pass "enumerate: P1 classified correctly"   || fail "enumerate: P1 classification got $SEV_P1"
[ "$SEV_NIT" = "P3" ]     && pass "enumerate: Nitpick → P3"              || fail "enumerate: Nitpick classification got $SEV_NIT"
[ "$SEV_UNK" = "Unknown" ] && pass "enumerate: no-prefix → Unknown"      || fail "enumerate: unknown classification got $SEV_UNK"

# body_excerpt has no embedded newlines, and is <= 200 chars.
LONGEST=$(jq -r '.body_excerpt' "$OUT_NDJSON" | awk '{ if (length($0) > max) max = length($0) } END { print max }')
if [ "$LONGEST" -le 200 ]; then
  pass "enumerate: body_excerpt cap (<=200 chars) respected (max=$LONGEST)"
else
  fail "enumerate: body_excerpt exceeded 200 chars (max=$LONGEST)"
fi

# ---------------------------------------------------------------------------
# Test 1b: long bodies do not trip pipefail via early-closing pipelines.
# ---------------------------------------------------------------------------
LONG_BODY=$'Potential issue: first line\n\t'
LONG_BODY="${LONG_BODY}$(printf '%0300d' 0 | tr '0' A)"

cat >"$STUB_FIXTURES/pr-list-owner_long.json" <<'JSON'
[
  {"number": 9, "title": "Long review body", "url": "https://github.com/owner/long/pull/9"}
]
JSON

jq -n --arg body "$LONG_BODY" '{
  data: {
    repository: {
      pullRequest: {
        reviewThreads: {
          totalCount: 1,
          pageInfo: {hasNextPage: false, endCursor: null},
          nodes: [
            {
              id: "PRT_long_9_a",
              isResolved: false,
              isOutdated: false,
              comments: {nodes: [{
                author: {login: "coderabbitai[bot]"},
                body: $body,
                url: "https://github.com/owner/long/pull/9#discussion_r9001"
              }]}
            }
          ]
        }
      }
    }
  }
}' >"$STUB_FIXTURES/threads-owner_long_9.json"

LONG_TARGETS="$WORKDIR/targets-long.txt"
printf '%s\n' "owner/long" >"$LONG_TARGETS"
LONG_NDJSON="$WORKDIR/findings-long.ndjson"

set +e
PATH="$STUB_DIR:$PATH" \
GH_TOKEN="dummy-pat" \
STUB_FIXTURES="$STUB_FIXTURES" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
SWEEP_OUTPUT="$LONG_NDJSON" \
  "$ENUMERATE" "$LONG_TARGETS" 2>"$WORKDIR/enum-long.stderr"
rc=$?
set -e

if [ "$rc" -eq 0 ] && [ "$(wc -l < "$LONG_NDJSON" | tr -d ' ')" = "1" ]; then
  pass "enumerate: long body does not fail under pipefail"
else
  fail "enumerate: long body exited $rc or emitted wrong count"
  cat "$WORKDIR/enum-long.stderr" >&2
fi

if jq -e '(.body_excerpt | length) == 200
          and ((.body_excerpt | contains("\n")) | not)
          and ((.body_excerpt | contains("\r")) | not)
          and ((.body_excerpt | contains("\t")) | not)' "$LONG_NDJSON" >/dev/null; then
  pass "enumerate: long body_excerpt is capped and single-line"
else
  fail "enumerate: long body_excerpt not capped/single-line"
  cat "$LONG_NDJSON" >&2
fi

# ---------------------------------------------------------------------------
# Test 2: render.sh produces a body with expected markers + counts.
# ---------------------------------------------------------------------------
BODY_OUT="$WORKDIR/body.md"
set +e
SWEEP_DRY_RUN=1 \
SWEEP_TODAY="2026-05-13" \
GH_TOKEN="dummy" \
  "$RENDER" "$OUT_NDJSON" > "$BODY_OUT" 2>"$WORKDIR/render.stderr"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  fail "render: exit $rc, expected 0"
  cat "$WORKDIR/render.stderr" >&2
fi

grep -q '<!-- sweep-unresolved-feedback v2 -->' "$BODY_OUT" \
  && pass "render: emitted marker comment" \
  || fail "render: missing marker comment"

grep -q '<!-- content-hash: ' "$BODY_OUT" \
  && pass "render: emitted content-hash marker" \
  || fail "render: missing content-hash marker"

grep -q '<!-- last-run: 2026-05-13 -->' "$BODY_OUT" \
  && pass "render: emitted last-run marker with SWEEP_TODAY override" \
  || fail "render: missing last-run marker / wrong date"

grep -q '# Unresolved reviewer feedback backlog' "$BODY_OUT" \
  && pass "render: emitted H1 title" \
  || fail "render: missing H1 title"

grep -q 'found \*\*3\*\* unresolved review threads' "$BODY_OUT" \
  && pass "render: count of 3 in summary line" \
  || fail "render: summary count incorrect"

grep -q '\*\*owner/alpha\*\* — 3 items' "$BODY_OUT" \
  && pass "render: per-repo count rendered" \
  || fail "render: per-repo count missing"

# Severity-major bounded render (#397): summaries are now
# "<sev> — <repo> (<bucket_count>, showing <shown>)".
grep -q '<summary>P1 — owner/alpha (1, showing 1)</summary>' "$BODY_OUT" \
  && pass "render: P1 severity group rendered with count" \
  || fail "render: P1 group missing"

grep -q '<summary>P3 — owner/alpha (1, showing 1)</summary>' "$BODY_OUT" \
  && pass "render: P3 severity group rendered" \
  || fail "render: P3 group missing"

grep -q '<summary>Unknown — owner/alpha (1, showing 1)</summary>' "$BODY_OUT" \
  && pass "render: Unknown severity group rendered" \
  || fail "render: Unknown group missing"

# Headline per-severity totals line (#397).
grep -q 'Severity totals — P0: 0 · P1: 1 · P2: 0 · P3: 1 · Unknown: 1' "$BODY_OUT" \
  && pass "render: severity totals headline rendered" \
  || fail "render: severity totals headline missing"

# Codex #254 P2: the body must include the thread-ids marker block on
# BOTH the create path and the edit path, otherwise the first sweep
# after bootstrap would treat every existing thread as "new" on the
# subsequent run. SWEEP_DRY_RUN exercises the same body the create
# path would post.
grep -q '<!-- thread-ids-begin -->' "$BODY_OUT" \
  && pass "render: dry-run body includes thread-ids-begin marker" \
  || fail "render: dry-run body missing thread-ids-begin marker"

grep -q '<!-- thread-ids-end -->' "$BODY_OUT" \
  && pass "render: dry-run body includes thread-ids-end marker" \
  || fail "render: dry-run body missing thread-ids-end marker"

# Marker is now the v2 compact chunk form; parse both forms (#397).
MARKER_IDS=$(awk '
  /<!-- thread-ids-begin -->/ { capture=1; next }
  /<!-- thread-ids-end -->/   { capture=0 }
  capture==1 {
    line = $0
    if (line ~ /thread-ids-truncated/) { next }
    if (line ~ /thread-ids-chunk:/) {
      sub(/.*thread-ids-chunk:[[:space:]]*/, "", line)
      sub(/[[:space:]]*-->.*/, "", line)
      n = split(line, a, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    } else {
      sub(/^<!--[[:space:]]*/, "", line)
      sub(/[[:space:]]*-->.*/, "", line)
      if (line != "") print line
    }
  }
' "$BODY_OUT" | sort -u | tr '\n' ' ')
WANT_MARKER_IDS="PRT_alpha_1_a PRT_alpha_2_a PRT_alpha_2_b "
if [ "$MARKER_IDS" = "$WANT_MARKER_IDS" ]; then
  pass "render: thread-id marker block contains all current thread_ids"
else
  fail "render: marker thread_ids mismatch. got=[$MARKER_IDS] want=[$WANT_MARKER_IDS]"
fi

# ---------------------------------------------------------------------------
# Test 3: idempotency — same input produces same content-hash.
# ---------------------------------------------------------------------------
HASH1=$(grep -oE '<!-- content-hash: [a-f0-9]+ -->' "$BODY_OUT" | head -1)
set +e
BODY_OUT2="$WORKDIR/body2.md"
SWEEP_DRY_RUN=1 \
SWEEP_TODAY="2026-05-14" \
GH_TOKEN="dummy" \
  "$RENDER" "$OUT_NDJSON" > "$BODY_OUT2" 2>/dev/null
set -e
HASH2=$(grep -oE '<!-- content-hash: [a-f0-9]+ -->' "$BODY_OUT2" | head -1)

if [ "$HASH1" = "$HASH2" ] && [ -n "$HASH1" ]; then
  pass "idempotency: identical input → identical content-hash across runs"
else
  fail "idempotency: hash drift between runs ($HASH1 vs $HASH2)"
fi

# ---------------------------------------------------------------------------
# Test 4: a finding added → content-hash changes.
# ---------------------------------------------------------------------------
OUT_NDJSON_PLUS="$WORKDIR/findings-plus.ndjson"
cp "$OUT_NDJSON" "$OUT_NDJSON_PLUS"
jq -nc '{
  repo: "owner/beta",
  pr_number: 7,
  pr_title: "New finding",
  pr_url: "https://github.com/owner/beta/pull/7",
  thread_id: "PRT_new",
  author_login: "human",
  body_excerpt: "P0 - Critical bug",
  severity: "P0",
  thread_url: "https://github.com/owner/beta/pull/7#discussion_r9999"
}' >> "$OUT_NDJSON_PLUS"

BODY_OUT3="$WORKDIR/body3.md"
set +e
SWEEP_DRY_RUN=1 \
SWEEP_TODAY="2026-05-13" \
GH_TOKEN="dummy" \
  "$RENDER" "$OUT_NDJSON_PLUS" > "$BODY_OUT3" 2>/dev/null
set -e
HASH3=$(grep -oE '<!-- content-hash: [a-f0-9]+ -->' "$BODY_OUT3" | head -1)
if [ "$HASH1" != "$HASH3" ] && [ -n "$HASH3" ]; then
  pass "delta-detection: new finding changes content-hash"
else
  fail "delta-detection: hash did NOT change after adding finding ($HASH1 vs $HASH3)"
fi

# ---------------------------------------------------------------------------
# Test 5: empty NDJSON path — render emits "no unresolved threads" body.
# ---------------------------------------------------------------------------
EMPTY="$WORKDIR/empty.ndjson"
: > "$EMPTY"
BODY_EMPTY="$WORKDIR/body-empty.md"
set +e
SWEEP_DRY_RUN=1 \
SWEEP_TODAY="2026-05-13" \
GH_TOKEN="dummy" \
  "$RENDER" "$EMPTY" > "$BODY_EMPTY" 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'No unresolved threads found' "$BODY_EMPTY"; then
  pass "render: empty NDJSON → clean rollup body"
else
  fail "render: empty NDJSON did not produce clean body (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# Test 6: idempotency at the issue level — render exits 0 without
# calling 'gh issue create' or 'gh issue comment' when the existing
# rollup body already has the same content-hash. Drive this by
# stubbing issue-list.json to point at a body containing the hash
# from Test 2.
# ---------------------------------------------------------------------------
PRIOR_HASH=$(grep -oE '<!-- content-hash: [a-f0-9]+ -->' "$BODY_OUT" | head -1 | sed -E 's/.*: ([a-f0-9]+) -->/\1/')
cat >"$STUB_FIXTURES/issue-list.json" <<JSON
[
  {
    "number": 4242,
    "title": "Unresolved reviewer feedback backlog — 2026-05-06",
    "body": "<!-- sweep-unresolved-feedback v1 -->\n<!-- content-hash: $PRIOR_HASH -->\n<!-- last-run: 2026-05-06 -->\n\n# Unresolved reviewer feedback backlog\n\nstale body"
  }
]
JSON

: > "$GH_CALLS_LOG"
set +e
PATH="$STUB_DIR:$PATH" \
GH_TOKEN="dummy-pat" \
STUB_FIXTURES="$STUB_FIXTURES" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
SWEEP_TODAY="2026-05-13" \
  "$RENDER" "$OUT_NDJSON" >/dev/null 2>"$WORKDIR/render-noop.stderr"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  fail "no-op idempotency: render exited $rc, expected 0"
  cat "$WORKDIR/render-noop.stderr" >&2
fi

# Must NOT have called issue create or issue comment.
if grep -qE $'^gh\tissue\tcreate' "$GH_CALLS_LOG"; then
  fail "no-op idempotency: render called 'gh issue create' on unchanged content"
  cat "$GH_CALLS_LOG" >&2
elif grep -qE $'^gh\tissue\tcomment' "$GH_CALLS_LOG"; then
  fail "no-op idempotency: render called 'gh issue comment' on unchanged content"
  cat "$GH_CALLS_LOG" >&2
elif grep -qE $'^gh\tissue\tedit' "$GH_CALLS_LOG"; then
  fail "no-op idempotency: render called 'gh issue edit' on unchanged content"
  cat "$GH_CALLS_LOG" >&2
else
  pass "no-op idempotency: render did not call create/comment/edit on unchanged hash"
fi

# Must have called issue list (the search step).
if grep -qE $'^gh\tissue\tlist' "$GH_CALLS_LOG"; then
  pass "no-op idempotency: render queried existing issues before deciding no-op"
else
  fail "no-op idempotency: render did NOT query existing issues"
  cat "$GH_CALLS_LOG" >&2
fi

# ---------------------------------------------------------------------------
# Test 7: target-repos.txt file shipped with the repo lists exactly
# the 9 repos from the 2026-05-13 sweep (and is parseable).
# ---------------------------------------------------------------------------
SHIPPED_TARGETS="$ROOT/scripts/sweep-unresolved-feedback/target-repos.txt"
if [ ! -f "$SHIPPED_TARGETS" ]; then
  fail "shipped targets: file missing at $SHIPPED_TARGETS"
else
  N=$(grep -v '^#' "$SHIPPED_TARGETS" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
  if [ "$N" = "9" ]; then
    pass "shipped targets: 9 repos configured"
  else
    fail "shipped targets: expected 9 repos, got $N"
  fi
  for slug in friends-and-family-billing device-platform-reporting device-source-of-truth swipewatch nathanpaynedotcom overridebroadway matchline tadlockpsychiatry mergepath; do
    if grep -qE "/${slug}\$" "$SHIPPED_TARGETS"; then
      pass "shipped targets: includes $slug"
    else
      fail "shipped targets: missing $slug"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Test 8: workflow file exists with the expected cron + dispatch.
# ---------------------------------------------------------------------------
WF="$ROOT/.github/workflows/weekly-feedback-sweep.yml"
if [ ! -f "$WF" ]; then
  fail "workflow: missing $WF"
else
  grep -q "cron: '0 9 \* \* 1'" "$WF" && pass "workflow: cron set to Mondays 09:00 UTC" \
    || fail "workflow: cron not set to Mondays 09:00 UTC"
  grep -q "workflow_dispatch:" "$WF" && pass "workflow: workflow_dispatch trigger present" \
    || fail "workflow: workflow_dispatch missing"
  grep -q "REVIEWER_ASSIGNMENT_TOKEN" "$WF" && pass "workflow: uses REVIEWER_ASSIGNMENT_TOKEN secret" \
    || fail "workflow: missing REVIEWER_ASSIGNMENT_TOKEN secret reference"
  grep -q "enumerate.sh" "$WF" && pass "workflow: runs enumerate.sh" \
    || fail "workflow: does not run enumerate.sh"
  grep -q "render.sh" "$WF" && pass "workflow: runs render.sh" \
    || fail "workflow: does not run render.sh"
fi

# ---------------------------------------------------------------------------
# Test 9: body-size cap regression (#397). A large backlog must render a
# body within GitHub's 65536-byte issue cap; the full id set must still
# survive in the marker block (delta correctness), and the truncation
# footer must point at the artifact. This is the regression that broke
# the 2026-05-25 / 2026-06-01 weekly sweeps (693 findings → body too long).
# ---------------------------------------------------------------------------
BIG="$WORKDIR/big.ndjson"
: > "$BIG"
bi=0
while [ "$bi" -lt 750 ]; do
  bsev=$(printf 'P0 P1 P2 P3 Unknown' | tr ' ' '\n' | sed -n "$(((bi % 5) + 1))p")
  brepo="owner/repo$((bi % 5))"
  jq -nc --arg tid "PRT_big_$bi" --arg repo "$brepo" --arg sev "$bsev" --argjson pr "$bi" \
    '{repo:$repo,pr_number:$pr,pr_title:("Finding "+($pr|tostring)),
      pr_url:("https://github.com/"+$repo+"/pull/"+($pr|tostring)),thread_id:$tid,
      author_login:"coderabbitai[bot]",
      body_excerpt:"Potential issue: a representative ~150 char excerpt mirroring what enumerate.sh emits so the rendered per-finding line reflects realistic bloat here ok done now",
      severity:$sev,
      thread_url:("https://github.com/"+$repo+"/pull/"+($pr|tostring)+"#discussion_r"+($pr|tostring))}' >> "$BIG"
  bi=$((bi + 1))
done

BODY_BIG="$WORKDIR/body-big.md"
set +e
SWEEP_DRY_RUN=1 SWEEP_TODAY="2026-05-13" GH_TOKEN="dummy" \
  "$RENDER" "$BIG" > "$BODY_BIG" 2>/dev/null
rc=$?
set -e
BIG_BYTES=$(wc -c < "$BODY_BIG" | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$BIG_BYTES" -gt 0 ] && [ "$BIG_BYTES" -le 65536 ]; then
  pass "render: 750-finding dry-run body within 65536-byte cap ($BIG_BYTES B)"
else
  fail "render: 750-finding body is $BIG_BYTES B (rc=$rc), expected 1..65536 — bounded-render regression"
fi

# Marker block must still carry the COMPLETE id set (parse both forms).
BIG_MARKER_IDS=$(awk '
  /<!-- thread-ids-begin -->/ { capture=1; next }
  /<!-- thread-ids-end -->/   { capture=0 }
  capture==1 {
    line = $0
    if (line ~ /thread-ids-truncated/) { next }
    if (line ~ /thread-ids-chunk:/) {
      sub(/.*thread-ids-chunk:[[:space:]]*/, "", line); sub(/[[:space:]]*-->.*/, "", line)
      n = split(line, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    } else {
      sub(/^<!--[[:space:]]*/, "", line); sub(/[[:space:]]*-->.*/, "", line)
      if (line != "") print line
    }
  }
' "$BODY_BIG" | sort -u | wc -l | tr -d ' ')
if [ "$BIG_MARKER_IDS" -eq 750 ]; then
  pass "render: marker block carries all 750 ids despite bounded findings"
else
  fail "render: marker block has $BIG_MARKER_IDS ids, expected 750 — delta state would be lossy"
fi

# Truncation footer must be present and name the artifact.
if grep -q 'more findings not shown above' "$BODY_BIG" \
   && grep -q 'workflow artifact' "$BODY_BIG"; then
  pass "render: truncation footer present and references the workflow artifact"
else
  fail "render: truncation footer missing on a bounded render"
fi

# ---------------------------------------------------------------------------
# Test 10: v1 → v2 marker migration (#397). A rollup body written by the
# OLD per-line (v1) script must stay delta-diffable on the first v2 run —
# the reader accepts both the legacy per-line and the new chunk form.
# Drive the edit path with a v1 prior body whose ids differ from current
# and assert the new/resolved counts are computed from the legacy ids
# (if the legacy reader failed, PRIOR_IDS would be empty → new=3).
# ---------------------------------------------------------------------------
cat >"$STUB_FIXTURES/issue-list.json" <<'JSON'
[
  {
    "number": 4243,
    "title": "Unresolved reviewer feedback backlog — 2026-05-06",
    "body": "<!-- sweep-unresolved-feedback v1 -->\n<!-- content-hash: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef -->\n<!-- last-run: 2026-05-06 -->\n\n# Unresolved reviewer feedback backlog\n\nstale body\n\n<!-- thread-ids-begin -->\n<!-- PRT_alpha_1_a -->\n<!-- PRT_alpha_2_a -->\n<!-- PRT_old_stale -->\n<!-- thread-ids-end -->"
  }
]
JSON

: > "$GH_CALLS_LOG"
set +e
PATH="$STUB_DIR:$PATH" \
GH_TOKEN="dummy-pat" \
STUB_FIXTURES="$STUB_FIXTURES" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
SWEEP_TODAY="2026-05-13" \
  "$RENDER" "$OUT_NDJSON" >/dev/null 2>"$WORKDIR/render-migrate.stderr"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  fail "v1→v2 migration: render exited $rc, expected 0"
  cat "$WORKDIR/render-migrate.stderr" >&2
elif grep -q 'new=1, resolved=1' "$WORKDIR/render-migrate.stderr"; then
  pass "v1→v2 migration: legacy per-line marker parsed (new=1, resolved=1)"
else
  fail "v1→v2 migration: wrong delta counts (legacy reader likely broke)"
  grep 'updating issue' "$WORKDIR/render-migrate.stderr" >&2 || true
fi

# ---------------------------------------------------------------------------
# Test 11: marker truncation hard-guard (#399 Codex P2). When the complete
# marker can't fit under the byte budget, emission stops with a truncated
# sentinel and the body is still well-formed — the render NEVER posts an
# over-limit body. Force a tiny SWEEP_MARKER_MAX_BYTES so the path is
# exercised deterministically (the real budget only truncates at ~4500+ ids).
# ---------------------------------------------------------------------------
BODY_TRUNC="$WORKDIR/body-trunc.md"
set +e
SWEEP_DRY_RUN=1 SWEEP_TODAY="2026-05-13" GH_TOKEN="dummy" SWEEP_MARKER_MAX_BYTES=80 \
  "$RENDER" "$OUT_NDJSON" > "$BODY_TRUNC" 2>/dev/null
rc=$?
set -e
TRUNC_BYTES=$(wc -c < "$BODY_TRUNC" | tr -d ' ')
if [ "$rc" -eq 0 ] \
   && grep -q '<!-- thread-ids-truncated -->' "$BODY_TRUNC" \
   && grep -q '<!-- thread-ids-begin -->' "$BODY_TRUNC" \
   && grep -q '<!-- thread-ids-end -->' "$BODY_TRUNC" \
   && [ "$TRUNC_BYTES" -le 65536 ]; then
  pass "render: marker truncation guard fires under a tiny budget, body stays well-formed"
else
  fail "render: marker truncation guard did not fire / body malformed (rc=$rc, bytes=$TRUNC_BYTES)"
fi

# ---------------------------------------------------------------------------
# Test 12 (#564): actioned threads marked isResolved:true are EXCLUDED from
# the backlog. This is the explicit regression for the unresolved-feedback
# sweep contract behind #564 — when a finding is fixed/rebutted during the
# PR process and the review thread is resolved (isResolved:true), the weekly
# sweep MUST NOT re-surface it (that is the noise #562 exhibited). Mixed
# fixture on a fresh repo: one resolved/actioned thread carrying a
# [mergepath-resolve: ...] marker + one still-open thread; only the open one
# may appear. Test 1 covers this implicitly via its surviving-id set; this
# names the contract directly so a future filter change can't quietly
# re-admit resolved threads.
# ---------------------------------------------------------------------------
cat >"$STUB_FIXTURES/pr-list-owner_delta.json" <<'JSON'
[
  {"number": 5, "title": "Actioned + open mix", "url": "https://github.com/owner/delta/pull/5"}
]
JSON

cat >"$STUB_FIXTURES/threads-owner_delta_5.json" <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "totalCount": 2,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": [
            {
              "id": "PRT_delta_5_actioned",
              "isResolved": true,
              "isOutdated": false,
              "comments": {"nodes": [{
                "author": {"login": "coderabbitai[bot]"},
                "body": "P1 - Potential issue: fixed during the PR. [mergepath-resolve: addressed-elsewhere] addressed by commit abc1234.",
                "url": "https://github.com/owner/delta/pull/5#discussion_r5001"
              }]}
            },
            {
              "id": "PRT_delta_5_open",
              "isResolved": false,
              "isOutdated": false,
              "comments": {"nodes": [{
                "author": {"login": "coderabbitai[bot]"},
                "body": "P1 - Potential issue: still needs attention.",
                "url": "https://github.com/owner/delta/pull/5#discussion_r5002"
              }]}
            }
          ]
        }
      }
    }
  }
}
JSON

DELTA_TARGETS="$WORKDIR/targets-delta.txt"
printf '%s\n' "owner/delta" >"$DELTA_TARGETS"
DELTA_NDJSON="$WORKDIR/findings-delta.ndjson"
: > "$GH_CALLS_LOG"

set +e
PATH="$STUB_DIR:$PATH" \
GH_TOKEN="dummy-pat" \
STUB_FIXTURES="$STUB_FIXTURES" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
SWEEP_OUTPUT="$DELTA_NDJSON" \
  "$ENUMERATE" "$DELTA_TARGETS" 2>"$WORKDIR/enum-delta.stderr"
rc=$?
set -e

DELTA_IDS=$(jq -r '.thread_id' "$DELTA_NDJSON" 2>/dev/null | sort | tr '\n' ' ')
if [ "$rc" -eq 0 ] && [ "$DELTA_IDS" = "PRT_delta_5_open " ]; then
  pass "enumerate: actioned isResolved:true thread excluded; only the open thread surfaces (#564)"
else
  fail "enumerate: #564 exclusion failed — expected only PRT_delta_5_open, got [$DELTA_IDS] (rc=$rc)"
  cat "$DELTA_NDJSON" >&2 2>/dev/null || true
  cat "$WORKDIR/enum-delta.stderr" >&2 2>/dev/null || true
fi

# Belt-and-suspenders: the resolved thread_id must NOT appear anywhere in
# the emitted NDJSON.
if grep -q 'PRT_delta_5_actioned' "$DELTA_NDJSON" 2>/dev/null; then
  fail "enumerate: resolved/actioned thread leaked into the backlog (#564)"
else
  pass "enumerate: resolved/actioned thread_id absent from NDJSON (#564)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_sweep_unresolved_feedback: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
