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
  repos/acme/widget/pulls/7)
    cat "$GH_FIXTURE_DIR/pull.json"
    ;;
  repos/acme/widget/contents/.github/review-policy.yml\?ref=*)
    cat "$GH_FIXTURE_DIR/base-review-policy.yml"
    ;;
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
  cat >"$TMP/fixtures/pull.json" <<'JSON'
{
  "base": {
    "ref": "release",
    "sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "repo": {"default_branch": "main"}
  }
}
JSON
  cat >"$TMP/fixtures/base-review-policy.yml" <<'YAML'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-release
coderabbit:
  bot_login: "coderabbitai[bot]"
codex:
  bot_login: "chatgpt-codex-connector[bot]"
YAML
  rm -f "$TMP/fixtures"/reactions-*.json
  : >"$TMP/gh-calls.log"
}

RUN_RC=0
RUN_JSON=""
RUN_ERR=""
run_gate() {
  local token_mode="${1:-ambient}" config_mode="${2:-override}" gate_script="${3:-$SCRIPT}" out="$TMP/out.json" err="$TMP/err.log"
  local -a gate_env=(
    "PATH=$TMP/bin:$PATH"
    "GH_FIXTURE_DIR=$TMP/fixtures"
    "GH_CALL_LOG=$TMP/gh-calls.log"
    "CODEX_FEEDBACK_LEDGER=${CODEX_FEEDBACK_LEDGER:-$TMP/no-codex-ledger}"
    "CODERABBIT_FEEDBACK_LEDGER=${CODERABBIT_FEEDBACK_LEDGER:-$TMP/no-coderabbit-ledger}"
    "GH_FAIL_ENDPOINT=${GH_FAIL_ENDPOINT:-}"
  )
  if [ "$config_mode" = override ]; then
    gate_env+=("REVIEW_FEEDBACK_ACCOUNTING_CONFIG=$TMP/review-policy.yml")
  fi
  set +e
  if [ "$token_mode" = preflight ]; then
    env -u GH_TOKEN \
      "${gate_env[@]}" \
      OP_PREFLIGHT_REVIEWER_PAT=test-token \
      OP_PREFLIGHT_CACHE_DIR="$TMP/no-cache" \
      "$gate_script" 7 acme/widget >"$out" 2>"$err"
  else
    env "${gate_env[@]}" GH_TOKEN=test-token \
      "$gate_script" 7 acme/widget >"$out" 2>"$err"
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
    "id": 9,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T19:50:00Z",
    "user": {"login": "nathanpayne-release"},
    "path": "src/release.sh",
    "line": 3,
    "body": "**P1** Release-branch reviewer requires this guard."
  }
]
JSON
run_gate ambient base
assert_eq 1 "$RUN_RC" "non-default pull request uses its base-branch reviewer policy"
assert_eq nathanpayne-release "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "base-only reviewer finding is inventoried"
jq '.base.ref = "main"' "$TMP/fixtures/pull.json" >"$TMP/fixtures/pull.next"
mv "$TMP/fixtures/pull.next" "$TMP/fixtures/pull.json"
run_gate ambient base
assert_eq 1 "$RUN_RC" "cross-repository default-base pull request uses the target repository policy"
assert_eq nathanpayne-release "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "target-repository reviewer remains inventoried on its default base"

AUTHOR_CHECKOUT="$TMP/author-checkout"
mkdir -p "$AUTHOR_CHECKOUT/scripts/workflow" "$AUTHOR_CHECKOUT/.github"
cp "$SCRIPT" "$AUTHOR_CHECKOUT/scripts/review-feedback-accounting.sh"
cp "$ROOT/scripts/workflow/resolve_base_policy.sh" "$AUTHOR_CHECKOUT/scripts/workflow/resolve_base_policy.sh"
cp -R "$ROOT/scripts/lib" "$AUTHOR_CHECKOUT/scripts/lib"
cp "$TMP/review-policy.yml" "$AUTHOR_CHECKOUT/.github/review-policy.yml"
git -C "$AUTHOR_CHECKOUT" init -q -b feature
git -C "$AUTHOR_CHECKOUT" remote add origin https://github.com/acme/widget.git
git -C "$AUTHOR_CHECKOUT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run_gate ambient base "$AUTHOR_CHECKOUT/scripts/review-feedback-accounting.sh"
assert_eq 1 "$RUN_RC" "same-repository author worktree does not trust its head policy as the PR base"
assert_eq nathanpayne-release "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "author worktree still inventories the base-only reviewer"

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
cp "$TMP/fixtures/inline.json" "$TMP/fixtures/inline-with-substantive-reply.json"
jq '.[1].body = "."' "$TMP/fixtures/inline-with-substantive-reply.json" >"$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "punctuation-only reply is not substantive disposition evidence"
jq '.[1].body = "👍"' "$TMP/fixtures/inline-with-substantive-reply.json" >"$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "emoji-only reply is not substantive disposition evidence"
mv "$TMP/fixtures/inline-with-substantive-reply.json" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "agent reply after inline finding accounts for it"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.accounted')" "agent reply increments accounted count"
assert_eq thread-reply "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "reply evidence is visible"

reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 13,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:10:00Z",
    "user": {"login": "nathanpayne-claude"},
    "path": "src/reviewer.sh",
    "line": 7,
    "body": "**P1** Reject the unsafe reviewer path before merge."
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "registered reviewer root finding cannot account for itself as a reply"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.accounted')" "reviewer root finding has no reply evidence"

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
    "body": "[mergepath-resolve: addressed-elsewhere]"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "generated resolve marker is not disposition evidence"
jq '.[1].body = "[mergepath-resolve: addressed-elsewhere] Fixed by the validated guard change."' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline-with-resolve-rationale.json"
mv "$TMP/fixtures/inline-with-resolve-rationale.json" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "substantive rationale beside a resolve marker remains disposition evidence"
jq '.[1].body = "[mergepath-resolve: addressed-elsewhere]"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline-marker-only.json"
mv "$TMP/fixtures/inline-marker-only.json" "$TMP/fixtures/inline.json"

cat >"$TMP/codex-ledger.jsonl" <<'JSON'
{"repo":"acme/widget","comment_id":10,"verdict":"fixed","recorded_at":"2026-08-18T20:03:00Z"}
JSON
CODEX_FEEDBACK_LEDGER="$TMP/codex-ledger.jsonl"
run_gate
assert_eq 1 "$RUN_RC" "worktree-local ledger alone is not cross-checkout disposition evidence"
unset CODEX_FEEDBACK_LEDGER

printf '[{"user":{"login":"nathanpayne-codex"},"content":"+1","created_at":"2026-08-18T20:04:00Z"}]\n' >"$TMP/fixtures/reactions-10.json"
run_gate
assert_eq 1 "$RUN_RC" "reviewer reaction alone is not durable disposition evidence"
assert_eq null "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "reaction-only finding remains unaccounted"

printf '[{"user":{"login":"nathanpayne-codex"},"content":"eyes"}]\n' >"$TMP/fixtures/reactions-10.json"
run_gate
assert_eq 1 "$RUN_RC" "non-verdict reaction does not account for a Codex finding"

GH_FAIL_ENDPOINT="repos/acme/widget/pulls/comments/10/reactions"
run_gate
assert_eq 1 "$RUN_RC" "accounting does not depend on the deletable reaction surface"
if grep -F 'pulls/comments/10/reactions' "$TMP/gh-calls.log" >/dev/null; then
  fail "reaction endpoint must not be consulted for durable accounting"
else
  pass "reaction endpoint is not consulted for durable accounting"
fi
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
assert_eq 1 "$RUN_RC" "post-edit reaction alone does not durably account for the edited finding"

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
cat >"$TMP/fixtures/issues.json" <<'JSON'
[
  {
    "id": 8000,
    "created_at": "2026-08-18T22:20:00Z",
    "updated_at": "2026-08-18T22:20:00Z",
    "user": {"login": "coderabbitai[bot]"},
    "body": "<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\n_⚠️ Potential issue_ carried only by this PR-level summary.\n\n<!-- pre_merge_checks_walkthrough_start -->\n| Docstring Coverage | ⚠️ Warning |\n<!-- pre_merge_checks_walkthrough_end -->"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "unacknowledged PR-level bot finding blocks"
assert_eq issue-comment "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "PR-level bot miss is identified by shape"
COMMENT_ACK_TOKEN="$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')"
assert_match '^\[mergepath-comment-ack: 8000 [0-9a-f]{12}\]$' "$COMMENT_ACK_TOKEN" "PR-level remediation token is comment and content pinned"
jq --arg token "$COMMENT_ACK_TOKEN" '. + [{
  "id": 8001,
  "created_at": "2026-08-18T22:21:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nFixed the summary-only finding in abc1234.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "PR-level bot acknowledgement with rationale reconciles"
assert_eq comment-ack "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "PR-level acknowledgement evidence is visible"
jq '.[0].body += " (edited)" | .[0].updated_at = "2026-08-18T22:22:00Z"' \
  "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "editing a PR-level bot finding invalidates its prior acknowledgement"

reset_fixtures
cat >"$TMP/fixtures/reviews.json" <<'JSON'
[
  {
    "id": 901,
    "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "submitted_at": "2026-08-18T22:30:00Z",
    "state": "COMMENTED",
    "user": {"login": "coderabbitai[bot]"},
    "body": "**Actionable comments posted: 0**\n\n```text\n_🟠 Major_ quoted source text\n```\n\n<!-- pre_merge_checks_walkthrough_start -->\n| Docstring Coverage | ⚠️ Warning |\n<!-- pre_merge_checks_walkthrough_end -->"
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "CodeRabbit fenced markers and pre-merge warnings are not invented into review-body findings"
jq '.[0].body = "**Actionable comments posted: 1**\n\n_🟠 Major_ real review-body finding\n\n```text\n_⚠️ Potential issue_ quoted source text\n```\n\n<!-- pre_merge_checks_walkthrough_start -->\n| Docstring Coverage | ⚠️ Warning |\n<!-- pre_merge_checks_walkthrough_end -->"' \
  "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 1 "$RUN_RC" "CodeRabbit finding outside sanitized regions still blocks"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "sanitized CodeRabbit body preserves the real finding tier"

reset_fixtures
cat >"$TMP/fixtures/reviews.json" <<'JSON'
[
  {
    "id": 903,
    "commit_id": "cccccccccccccccccccccccccccccccccccccccc",
    "submitted_at": "2026-08-18T22:40:00Z",
    "state": "CHANGES_REQUESTED",
    "user": {"login": "nathanpayne-claude"},
    "body": "## Phase 4b review\n\n- **P1** Registered reviewer finding"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "registered Phase 4b reviewer body finding blocks"
assert_eq nathanpayne-claude "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "registered reviewer identity is preserved"

reset_fixtures
cp "$TMP/review-policy.yml" "$TMP/review-policy.default.yml"
cat >>"$TMP/review-policy.yml" <<'YAML'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: ignore
    nitpick: ignore
YAML
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 30,
    "created_at": "2026-08-18T22:50:00Z",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "path": "src/cosmetic.sh",
    "line": 2,
    "body": "![P3 Badge] Cosmetic wording"
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "feedback tier configured ignore is excluded from inventory"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "ignored finding does not contribute to posted count"
sed -i.bak 's/p3: ignore/p3: discretionary/' "$TMP/review-policy.yml"
rm -f "$TMP/review-policy.yml.bak"
run_gate
assert_eq 1 "$RUN_RC" "discretionary tier remains in the accounting inventory"
mv "$TMP/review-policy.default.yml" "$TMP/review-policy.yml"

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
assert_match 'failed to fetch review objects' "$RUN_ERR" "API failure names the unread surface"
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

if grep -Eq -- '--argjson (findings|missing)([[:space:]\\]|$)' "$SCRIPT"; then
  fail "final result must stream finding arrays instead of passing them through argv"
else
  pass "final result streams finding arrays instead of passing them through argv"
fi

if [ "$FAIL" -ne 0 ]; then
  printf 'review-feedback-accounting: FAIL (%s failed, %s passed)\n' "$FAIL" "$PASS" >&2
  exit 1
fi

printf 'review-feedback-accounting: PASS (%s assertions)\n' "$PASS"
