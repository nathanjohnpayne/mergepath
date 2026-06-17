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
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/post-phase-4b-handoff.sh"

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

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  # `gh repo view --json owner,name --jq '.owner.login + "/" + .name'`
  printf '%s' "${CURRENT_REPO_OVERRIDE:-nathanjohnpayne/mergepath}"
  exit 0
fi

if [ "$1" = "api" ]; then
  shift
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
  "head": { "sha": "${head_sha}", "ref": "${head_ref}" },
  "base": { "sha": "${base_sha}" }
}
EOF
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

OUT="$("$SCRIPT" nathanjohnpayne/mergepath#281)"
if printf '%s' "$OUT" | grep -q "PR ready for external review (Phase 4b):" \
   && printf '%s' "$OUT" | grep -q "verbatim mirror of mergepath@abcdef123456" \
   && printf '%s' "$OUT" | grep -q "https://github.com/nathanjohnpayne/mergepath/pull/281" \
   && printf '%s' "$OUT" | grep -q "head 1111111" \
   && printf '%s' "$OUT" | grep -q "(base 2222222)" \
   && printf '%s' "$OUT" | grep -q "Threads: 2 unresolved" \
   && printf '%s' "$OUT" | grep -q "resolve addressed bot or agent-reviewer"; then
  pass "single-PR mirror render contains expected fields"
else
  fail "single-PR mirror render missing expected fields"
  echo "--- OUTPUT ---" >&2
  printf '%s\n' "$OUT" >&2
  echo "--- END ---" >&2
fi

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
if printf '%s' "$OUT" | grep -q "Context: novel work" \
   && printf '%s' "$OUT" | grep -q "head 3333333" \
   && printf '%s' "$OUT" | grep -q "(base 4444444)" \
   && printf '%s' "$OUT" | grep -q "Threads: 0 unresolved"; then
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
if printf '%s' "$OUT" | grep -q "| Repo | PR # | HEAD short SHA | Unresolved threads | Content note |" \
   && printf '%s' "$OUT" | grep -q "nathanjohnpayne/matchline" \
   && printf '%s' "$OUT" | grep -q "nathanjohnpayne/swipewatch" \
   && printf '%s' "$OUT" | grep -q "Context: verbatim mirror of mergepath@abcdef123456" \
   && printf '%s' "$OUT" | grep -q "real-human threads automatically" \
   && ! printf '%s' "$OUT" | grep -q "Context: mixed"; then
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
if printf '%s' "$OUT" | grep -q "Context: mixed" \
   && printf '%s' "$OUT" | grep -q "verbatim mirror of mergepath@" \
   && printf '%s' "$OUT" | grep -q "novel work"; then
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

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
