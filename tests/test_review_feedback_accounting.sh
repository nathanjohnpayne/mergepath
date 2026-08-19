#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/review-feedback-accounting.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf 'ok %s - %s\n' "$PASS" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_match() {
  local pattern="$1" actual="$2" label="$3"
  if printf '%s' "$actual" | grep -Eq "$pattern"; then
    pass "$label"
  else
    fail "$label (value '$actual' did not match '$pattern')"
  fi
}

mkdir -p "$TMP/bin" "$TMP/fixtures"

cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_CALL_LOG"

endpoint=""
for arg in "$@"; do
  case "$arg" in
    repos/*) endpoint="$arg" ;;
  esac
done

if [ -n "${GH_FAIL_ENDPOINT:-}" ] && [ "$endpoint" = "$GH_FAIL_ENDPOINT" ]; then
  echo "synthetic API failure for $endpoint" >&2
  exit 1
fi

case "$endpoint" in
  repos/acme/widget/pulls/7/comments)
    cat "$GH_FIXTURE_DIR/inline.json"
    ;;
  repos/acme/widget/pulls/7/reviews)
    cat "$GH_FIXTURE_DIR/reviews.json"
    ;;
  repos/acme/widget/issues/7/comments)
    cat "$GH_FIXTURE_DIR/issues.json"
    ;;
  repos/acme/widget/pulls/comments/*/reactions)
    id="${endpoint#repos/acme/widget/pulls/comments/}"
    id="${id%/reactions}"
    if [ -f "$GH_FIXTURE_DIR/reactions-$id.json" ]; then
      cat "$GH_FIXTURE_DIR/reactions-$id.json"
    else
      printf '[]\n'
    fi
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 2
    ;;
esac
GH
chmod +x "$TMP/bin/gh"

cat >"$TMP/review-policy.yml" <<'YAML'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex
coderabbit:
  bot_login: "coderabbitai[bot]"
codex:
  bot_login: "chatgpt-codex-connector[bot]"
YAML

reset_fixtures() {
  printf '[]\n' >"$TMP/fixtures/inline.json"
  printf '[]\n' >"$TMP/fixtures/reviews.json"
  printf '[]\n' >"$TMP/fixtures/issues.json"
  rm -f "$TMP/fixtures"/reactions-*.json
  : >"$TMP/gh-calls.log"
}

RUN_RC=0
RUN_JSON=""
RUN_ERR=""
run_gate() {
  local token_mode="${1:-ambient}" out="$TMP/out.json" err="$TMP/err.log"
  local -a gate_env=(
    "PATH=$TMP/bin:$PATH"
    "GH_FIXTURE_DIR=$TMP/fixtures"
    "GH_CALL_LOG=$TMP/gh-calls.log"
    "REVIEW_FEEDBACK_ACCOUNTING_CONFIG=$TMP/review-policy.yml"
    "CODEX_FEEDBACK_LEDGER=${CODEX_FEEDBACK_LEDGER:-$TMP/no-codex-ledger}"
    "CODERABBIT_FEEDBACK_LEDGER=${CODERABBIT_FEEDBACK_LEDGER:-$TMP/no-coderabbit-ledger}"
    "GH_FAIL_ENDPOINT=${GH_FAIL_ENDPOINT:-}"
  )
  set +e
  if [ "$token_mode" = preflight ]; then
    env -u GH_TOKEN \
      "${gate_env[@]}" \
      OP_PREFLIGHT_REVIEWER_PAT=test-token \
      OP_PREFLIGHT_CACHE_DIR="$TMP/no-cache" \
      "$SCRIPT" 7 acme/widget >"$out" 2>"$err"
  else
    env "${gate_env[@]}" GH_TOKEN=test-token \
      "$SCRIPT" 7 acme/widget >"$out" 2>"$err"
  fi
  RUN_RC=$?
  set -e
  RUN_JSON="$(cat "$out")"
  RUN_ERR="$(cat "$err")"
}

if [ ! -x "$SCRIPT" ]; then
  echo "review-feedback-accounting: RED (implementation missing: $SCRIPT)" >&2
  exit 1
fi

reset_fixtures
run_gate
assert_eq 0 "$RUN_RC" "empty review history clears"
assert_eq clear "$(printf '%s' "$RUN_JSON" | jq -r '.status')" "empty history emits clear status"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "empty history reports zero posted findings"

# The documented direct invocation runs after op-preflight, which exports the
# scoped PAT but deliberately leaves GH_TOKEN unset. The helper must bridge the
# reviewer token itself rather than rejecting that normal environment.
reset_fixtures
run_gate preflight
assert_eq 0 "$RUN_RC" "reviewer PAT from preflight is accepted without ambient GH_TOKEN"

reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 10,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:00:00Z",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "path": "src/a.sh",
    "line": 12,
    "body": "![P1 Badge] Missing guard\n\nUseful? React with 👍 / 👎."
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "undispositioned inline finding blocks"
assert_eq unaccounted "$(printf '%s' "$RUN_JSON" | jq -r '.status')" "inline miss emits unaccounted status"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "inline finding contributes to posted count"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.accounted')" "inline miss contributes no accounted finding"
assert_eq inline "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "inline miss is identified by shape"

cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 10,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:00:00Z",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "path": "src/a.sh",
    "line": 12,
    "body": "![P1 Badge] Missing guard\n\nUseful? React with 👍 / 👎."
  },
  {
    "id": 11,
    "in_reply_to_id": 10,
    "created_at": "2026-08-18T20:02:00Z",
    "user": {"login": "nathanpayne-codex"},
    "path": "src/a.sh",
    "line": 12,
    "body": "Confirmed and fixed in abc1234."
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "agent reply after inline finding accounts for it"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.accounted')" "agent reply increments accounted count"
assert_eq thread-reply "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "reply evidence is visible"

cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 10,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:00:00Z",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "path": "src/a.sh",
    "line": 12,
    "body": "![P1 Badge] Missing guard\n\nUseful? React with 👍 / 👎."
  },
  {
    "id": 11,
    "in_reply_to_id": 10,
    "created_at": "2026-08-18T20:02:00Z",
    "user": {"login": "nathanpayne-codex"},
    "path": "src/a.sh",
    "line": 12,
    "body": "[mergepath-resolve: addressed-elsewhere] addressed by abc1234"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "generated resolve marker is not disposition evidence"

cat >"$TMP/codex-ledger.jsonl" <<'JSON'
{"repo":"acme/widget","comment_id":10,"verdict":"fixed","recorded_at":"2026-08-18T20:03:00Z"}
JSON
CODEX_FEEDBACK_LEDGER="$TMP/codex-ledger.jsonl"
run_gate
assert_eq 1 "$RUN_RC" "worktree-local ledger alone is not cross-checkout disposition evidence"
unset CODEX_FEEDBACK_LEDGER

printf '[{"user":{"login":"nathanpayne-codex"},"content":"+1","created_at":"2026-08-18T20:04:00Z"}]\n' >"$TMP/fixtures/reactions-10.json"
cp "$TMP/fixtures/inline.json" "$TMP/fixtures/inline-with-solicitation.json"
jq 'map(if .id == 10 then .body = "![P1 Badge] Missing guard" else . end)' \
  "$TMP/fixtures/inline-with-solicitation.json" >"$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "unrelated reaction does not account for a Codex finding without the solicitation"
mv "$TMP/fixtures/inline-with-solicitation.json" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "reviewer reaction accounts for a Codex inline finding"
assert_eq reaction "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "reaction evidence is visible"

printf '[{"user":{"login":"nathanpayne-codex"},"content":"eyes"}]\n' >"$TMP/fixtures/reactions-10.json"
run_gate
assert_eq 1 "$RUN_RC" "non-verdict reaction does not account for a Codex finding"

GH_FAIL_ENDPOINT="repos/acme/widget/pulls/comments/10/reactions"
run_gate
assert_eq 2 "$RUN_RC" "reaction API failure is an infrastructure error, not an unaccounted verdict"
assert_match 'could not verify reactions for inline finding 10' "$RUN_ERR" "reaction API failure names the unverifiable finding"
unset GH_FAIL_ENDPOINT

cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 10,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:00:00Z",
    "updated_at": "2026-08-18T20:05:00Z",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "path": "src/a.sh",
    "line": 12,
    "body": "![P1 Badge] Edited guard requirement\n\nUseful? React with 👍 / 👎."
  },
  {
    "id": 11,
    "in_reply_to_id": 10,
    "created_at": "2026-08-18T20:02:00Z",
    "user": {"login": "nathanpayne-codex"},
    "path": "src/a.sh",
    "line": 12,
    "body": "Fixed the earlier wording in abc1234."
  },
  {
    "id": 12,
    "in_reply_to_id": 10,
    "created_at": "2026-08-18T20:04:00Z",
    "updated_at": "2026-08-18T20:04:00Z",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "path": "src/a.sh",
    "line": 12,
    "body": "![P1 Badge] Re-raised guard requirement"
  }
]
JSON
printf '[{"user":{"login":"nathanpayne-codex"},"content":"+1","created_at":"2026-08-18T20:03:00Z"}]\n' >"$TMP/fixtures/reactions-10.json"
CODEX_FEEDBACK_LEDGER="$TMP/codex-ledger.jsonl"
run_gate
assert_eq 1 "$RUN_RC" "editing an inline finding invalidates earlier reply, ledger, and reaction evidence"
assert_eq 10 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].finding_id')" "latest bot event selection honors an older comment edited after a newer re-raise"
unset CODEX_FEEDBACK_LEDGER

printf '[{"user":{"login":"nathanpayne-codex"},"content":"+1","created_at":"2026-08-18T20:06:00Z"}]\n' >"$TMP/fixtures/reactions-10.json"
run_gate
assert_eq 0 "$RUN_RC" "post-edit reaction accounts for the edited inline finding"

reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 20,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T21:00:00Z",
    "user": {"login": "coderabbitai[bot]"},
    "path": "scripts/a.sh",
    "line": 4,
    "body": "_🟡 Minor_ Clarify the error"
  },
  {
    "id": 21,
    "in_reply_to_id": 20,
    "created_at": "2026-08-18T21:01:00Z",
    "user": {"login": "nathanjohnpayne"},
    "path": "scripts/a.sh",
    "line": 4,
    "body": "Fixed in def5678."
  }
]
JSON
cp "$TMP/fixtures/inline.json" "$TMP/fixtures/inline-with-reply.json"
jq '.[0:1]' "$TMP/fixtures/inline-with-reply.json" >"$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "undispositioned CodeRabbit finding blocks"
assert_match 'post a substantive disposition reply on the thread' "$RUN_ERR" "CodeRabbit remediation names the only cross-checkout evidence path"
if printf '%s' "$RUN_ERR" | grep -Eq 'record|react'; then
  fail "CodeRabbit remediation must not suggest a ledger or reaction"
else
  pass "CodeRabbit remediation does not suggest unsupported ledger/reaction evidence"
fi
mv "$TMP/fixtures/inline-with-reply.json" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "CodeRabbit finding and author reply reconcile"

reset_fixtures
cat >"$TMP/fixtures/reviews.json" <<'JSON'
[
  {
    "id": 900,
    "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "submitted_at": "2026-08-18T22:00:00Z",
    "state": "COMMENTED",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "body": "### Codex Review\n\n![P2 Badge] Synchronize theme tokens with the app"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "unacknowledged review-body finding blocks"
assert_eq review-body "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "review-body miss is identified by shape"
ACK_TOKEN="$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')"
assert_match '^\[mergepath-review-ack: 900 [0-9a-f]{12}\]$' "$ACK_TOKEN" "review-body remediation token is review and content pinned"

cat >"$TMP/fixtures/issues.json" <<JSON
[
  {
    "id": 901,
    "created_at": "2026-08-18T22:10:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": "$ACK_TOKEN\nFixed in commit abc1234."
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "review-body acknowledgement with rationale reconciles"
assert_eq review-ack "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "review acknowledgement evidence is visible"

cat >"$TMP/fixtures/issues.json" <<JSON
[
  {
    "id": 901,
    "created_at": "2026-08-18T22:10:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": "$ACK_TOKEN"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "bare acknowledgement token without rationale does not reconcile"

cat >"$TMP/fixtures/issues.json" <<JSON
[
  {
    "id": 901,
    "created_at": "2026-08-18T22:10:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": "$ACK_TOKEN\nFixed in commit abc1234."
  }
]
JSON
jq '.[0].body += " (edited)"' "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 1 "$RUN_RC" "editing a review body invalidates its prior acknowledgement"

reset_fixtures
cat >"$TMP/fixtures/reviews.json" <<'JSON'
[
  {
    "id": 902,
    "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "submitted_at": "2026-08-18T23:00:00Z",
    "state": "COMMENTED",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "body": "### Codex Review\n\nNo findings in this review."
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "markerless COMMENTED review is not invented into a finding"

reset_fixtures
GH_FAIL_ENDPOINT="repos/acme/widget/pulls/7/reviews"
run_gate
assert_eq 2 "$RUN_RC" "API read failure is an infrastructure error"
assert_match 'could not read review objects' "$RUN_ERR" "API failure names the unread surface"
unset GH_FAIL_ENDPOINT

reset_fixtures
run_gate

for endpoint in \
  repos/acme/widget/pulls/7/comments \
  repos/acme/widget/pulls/7/reviews \
  repos/acme/widget/issues/7/comments; do
  if grep -F -- "--paginate $endpoint" "$TMP/gh-calls.log" >/dev/null; then
    pass "$endpoint read is paginated"
  else
    fail "$endpoint read is paginated"
  fi
done

for caller in \
  scripts/codex-review-request.sh \
  scripts/phase-4b-review.sh \
  scripts/post-phase-4b-handoff.sh \
  scripts/codex-p1-gate.sh; do
  if grep -F 'MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD' "$ROOT/$caller" >/dev/null; then
    pass "$caller invokes the accounting gate"
  else
    fail "$caller invokes the accounting gate"
  fi
done

if [ "$FAIL" -ne 0 ]; then
  printf 'review-feedback-accounting: FAIL (%s failed, %s passed)\n' "$FAIL" "$PASS" >&2
  exit 1
fi

printf 'review-feedback-accounting: PASS (%s assertions)\n' "$PASS"
