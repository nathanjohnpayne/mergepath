#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/review-feedback-accounting.sh"
RENDER_ARCHIVE="$ROOT/scripts/render-feedback-archive.sh"
SURFACE_FINGERPRINT="$ROOT/scripts/review-feedback-surface-fingerprint.sh"
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
  repos/acme/widget/code-scanning/alerts\?ref=refs/pull/7/head)
    if [ -f "$GH_FIXTURE_DIR/code-scanning-alerts.json" ]; then
      cat "$GH_FIXTURE_DIR/code-scanning-alerts.json"
    else
      printf '[]\n'
    fi
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
code_scanning:
  bot_login: "github-advanced-security[bot]"
YAML

reset_fixtures() {
  printf '[]\n' >"$TMP/fixtures/inline.json"
  printf '[]\n' >"$TMP/fixtures/reviews.json"
  printf '[]\n' >"$TMP/fixtures/issues.json"
  printf '[]\n' >"$TMP/fixtures/code-scanning-alerts.json"
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
code_scanning:
  bot_login: "github-advanced-security[bot]"
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

cat >"$TMP/fixtures/issues.json" <<'JSON'
[
  {
    "id": 2,
    "created_at": "2026-08-18T19:00:00Z",
    "user": {"login": "github-actions[bot]"},
    "body": "<!-- mergepath-feedback-archive-relay:v1 run=12345 status=failed -->"
  }
]
JSON
run_gate
assert_eq 2 "$RUN_RC" "failed fork archive relay is a persistent infrastructure block"
assert_match 'read-only feedback archive relay.*12345' "$RUN_ERR" "relay failure names the unrecoverable source run"
jq '. + [{
  "id": 3,
  "created_at": "2026-08-18T19:01:00Z",
  "user": {"login": "github-actions[bot]"},
  "body": "<!-- mergepath-feedback-archive-relay:v1 run=12345 status=complete -->"
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "a successful rerun supersedes the same source run failure marker"
# A completion is durable in EITHER posting order. Recency cannot decide this:
# restoring an edited or deleted terminal marker reposts the exact prior body
# under a new comment id and created_at, so the restored copy always sorts last.
# Under a latest-wins rule, restoring a stale completion would mask a real
# failure — the fail-OPEN direction. Presence of a completion is the durable
# fact (the archive it records cannot be un-persisted by a later rerun that no
# longer finds its artifact), and presence is immune to that reordering.
jq '. + [{
  "id": 4,
  "created_at": "2026-08-18T19:02:00Z",
  "user": {"login": "github-actions[bot]"},
  "body": "<!-- mergepath-feedback-archive-relay:v1 run=12345 status=failed -->"
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "a completion marker survives a later spurious rerun failure for the same source run"

# ...and a restored completion cannot launder a DIFFERENT source run that only
# ever failed, so the presence rule is scoped per run rather than per PR.
jq '. + [{
  "id": 5,
  "created_at": "2026-08-18T19:03:00Z",
  "user": {"login": "github-actions[bot]"},
  "body": "<!-- mergepath-feedback-archive-relay:v1 run=67890 status=failed -->"
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 2 "$RUN_RC" "a failure-only source run still blocks alongside a completed one"
assert_match 'read-only feedback archive relay.*67890' "$RUN_ERR" "the block names the run that never completed"

# The documented direct invocation runs after op-preflight, which exports the
# scoped PAT but deliberately leaves GH_TOKEN unset. The helper must bridge the
# reviewer token itself rather than rejecting that normal environment.
reset_fixtures
run_gate preflight
assert_eq 0 "$RUN_RC" "reviewer PAT from preflight is accepted without ambient GH_TOKEN"

cat >"$TMP/bin/yq" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  echo "yq 2.0.0 (unrelated implementation)"
  exit 0
fi
echo "unsupported yq interface" >&2
exit 64
SH
chmod +x "$TMP/bin/yq"
reset_fixtures
run_gate
assert_eq 0 "$RUN_RC" "unrelated yq executable falls through to a supported YAML parser"
cat >"$TMP/bin/yq" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  echo "yq (https://github.com/mikefarah/yq/) version v4.47.2"
  exit 0
fi
echo "synthetic mikefarah parse failure" >&2
exit 1
SH
chmod +x "$TMP/bin/yq"
reset_fixtures
run_gate
assert_eq 2 "$RUN_RC" "validated mikefarah yq parse failure remains an infrastructure error"
rm -f "$TMP/bin/yq"

cp "$TMP/review-policy.yml" "$TMP/review-policy.valid.yml"
printf 'available_reviewers: [unterminated\n' >"$TMP/review-policy.yml"
reset_fixtures
run_gate
assert_eq 2 "$RUN_RC" "malformed governing review policy is an infrastructure error"
assert_match 'governing review policy.*(parse|valid)' "$RUN_ERR" "malformed policy failure names the policy contract"
mv "$TMP/review-policy.valid.yml" "$TMP/review-policy.yml"
mv "$TMP/review-policy.yml" "$TMP/review-policy.unreadable.yml"
reset_fixtures
run_gate
assert_eq 2 "$RUN_RC" "unreadable governing review policy is an infrastructure error"
assert_match 'governing review policy is unreadable' "$RUN_ERR" "unreadable policy failure names the missing surface"
mv "$TMP/review-policy.unreadable.yml" "$TMP/review-policy.yml"
cp "$TMP/review-policy.yml" "$TMP/review-policy.valid-enums.yml"
cat >"$TMP/review-policy.yml" <<'JSON'
{"feedback_policy":{"mode":"typo"}}
JSON
reset_fixtures
run_gate
assert_eq 2 "$RUN_RC" "invalid feedback policy mode fails before an empty history can clear"
cat >"$TMP/review-policy.yml" <<'JSON'
{"feedback_policy":{"mode":"by-priority","priorities":{"p1":"typo"}}}
JSON
reset_fixtures
run_gate
assert_eq 2 "$RUN_RC" "invalid feedback priority disposition fails before an empty history can clear"
mv "$TMP/review-policy.valid-enums.yml" "$TMP/review-policy.yml"

cp "$TMP/review-policy.yml" "$TMP/review-policy.block-style.yml"
cat >"$TMP/review-policy.yml" <<'JSON'
{"author_identity":"nathanjohnpayne","available_reviewers":["nathanpayne-release"],"coderabbit":{"bot_login":"coderabbitai[bot]"},"codex":{"bot_login":"chatgpt-codex-connector[bot]"},"feedback_policy":{"mode":"by-priority","priorities":{"p1":"required"}}}
JSON
reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 8,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T19:40:00Z",
    "user": {"login": "nathanpayne-release"},
    "path": "src/flow-policy.sh",
    "line": 2,
    "body": "**P1** Flow-style reviewer policy must be enforced."
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "schema-valid flow-style policy preserves registered reviewer findings"
assert_eq nathanpayne-release "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "flow-style reviewer identity is inventoried"
mv "$TMP/review-policy.block-style.yml" "$TMP/review-policy.yml"

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

TRUSTED_CHECKOUT="$TMP/trusted-default-checkout"
mkdir -p "$TRUSTED_CHECKOUT/scripts/workflow" "$TRUSTED_CHECKOUT/.github"
cp "$SCRIPT" "$TRUSTED_CHECKOUT/scripts/review-feedback-accounting.sh"
cp "$ROOT/scripts/workflow/resolve_base_policy.sh" "$TRUSTED_CHECKOUT/scripts/workflow/resolve_base_policy.sh"
cp -R "$ROOT/scripts/lib" "$TRUSTED_CHECKOUT/scripts/lib"
cp "$TMP/review-policy.yml" "$TRUSTED_CHECKOUT/.github/review-policy.yml"
git -C "$TRUSTED_CHECKOUT" init -q -b main
git -C "$TRUSTED_CHECKOUT" remote add origin https://github.com/acme/widget.git
git -C "$TRUSTED_CHECKOUT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run_gate ambient base "$TRUSTED_CHECKOUT/scripts/review-feedback-accounting.sh"
assert_eq 1 "$RUN_RC" "default-branch checkout materializes the exact PR-base policy"
assert_eq nathanpayne-release "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "stale or dirty default checkout cannot omit a base reviewer"

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
    "id": 13,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:10:00Z",
    "user": {"login": "nathanpayne-claude"},
    "path": "src/reviewer.sh",
    "line": 7,
    "body": "**P1** Reject the unsafe reviewer path before merge."
  },
  {
    "id": 14,
    "in_reply_to_id": 13,
    "created_at": "2026-08-18T20:12:00Z",
    "user": {"login": "nathanpayne-claude"},
    "path": "src/reviewer.sh",
    "line": 7,
    "body": "**P1** The unsafe reviewer path remains reachable."
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "registered reviewer re-raise cannot account for itself as a reply"
assert_eq 14 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].finding_id')" "latest registered reviewer re-raise remains unaccounted"
jq '. + [{
  "id": 15,
  "in_reply_to_id": 13,
  "created_at": "2026-08-18T20:14:00Z",
  "user": {"login": "nathanjohnpayne"},
  "path": "src/reviewer.sh",
  "line": 7,
  "body": "Fixed the re-raised path in commit abc1234."
}]' "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "distinct later reply accounts for a registered reviewer re-raise"

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

jq '. + [{
  "id": 13,
  "in_reply_to_id": 10,
  "created_at": "2026-08-18T20:05:00Z",
  "user": {"login": "nathanpayne-codex"},
  "path": "src/a.sh",
  "line": 12,
  "body": "This reply cannot be ordered after the same-second edit."
}]' "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "same-second reply cannot prove it followed the finding edit"
jq '.[-1].created_at = "2026-08-18T20:05:01Z"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "strictly later reply accounts for the edited finding"

reset_fixtures
LARGE_INLINE_BODY="$TMP/large-inline-body.txt"
{
  printf '**P1** Large escaped inline finding. '
  awk 'BEGIN { for (i = 0; i < 65500; i++) printf "%c", 92 }'
} >"$LARGE_INLINE_BODY"
jq -n --rawfile body "$LARGE_INLINE_BODY" '[{
  "id": 14,
  "in_reply_to_id": null,
  "created_at": "2026-08-18T20:06:00Z",
  "updated_at": "2026-08-18T20:06:00Z",
  "user": {"login": "chatgpt-codex-connector[bot]"},
  "path": "src/large.sh",
  "line": 14,
  "body": $body
}]' >"$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "near-limit escaped inline finding is streamed without argv overflow"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "large inline finding remains inventoried"

reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 19,
    "in_reply_to_id": null,
    "created_at": "2026-08-18T20:50:00Z",
    "updated_at": "2026-08-18T20:50:01Z",
    "user": {"login": "coderabbitai[bot]"},
    "path": "scripts/provider-status.sh",
    "line": 4,
    "body": "<!-- This is an auto-generated reply by CodeRabbit -->\n<!-- CodeRabbit review command invocation: v2:40695c92071a7774b4a6b4f0e9eb06deacb14b457ca3ec1044886bf8782b8cc7 -->\n<details>\n<summary>⚠️ Action not completed</summary>\n\nReview rate limited.\n\n</details>"
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "inline CodeRabbit command-invocation status is not inventoried"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "inline status-only reply creates no disposition obligation"
jq '.[0].body += "\n\n_📐 Maintainability & Code Quality_ | _🟡 Minor_\n\n**Keep the retry counter bounded.**"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "inline mixed status plus real finding remains inventoried"
assert_eq inline "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "inline mixed response keeps the inline finding shape"
assert_eq p2 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "inline mixed response preserves the real finding tier"

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
jq '.[0].updated_at = "2026-08-18T21:02:00Z"
  | .[0].body += "\n\n✅ Confirmed as addressed by @nathanjohnpayne\n\n<!-- This is an auto-generated reply by CodeRabbit -->"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "CodeRabbit addressed confirmation preserves the substantive reply it confirms"
cp "$TMP/fixtures/inline.json" "$TMP/fixtures/inline-confirmed.json"
jq '.[1].user.login = "nathanpayne-codex"
  | .[1].created_at = "2026-08-18T21:03:00Z"' \
  "$TMP/fixtures/inline-confirmed.json" >"$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "strictly later configured-identity reply remains valid beside a CodeRabbit confirmation"
mv "$TMP/fixtures/inline-confirmed.json" "$TMP/fixtures/inline.json"
jq '.[0].body |= sub("✅ Confirmed as addressed by @nathanjohnpayne"; "Address confirmation removed")' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "ordinary CodeRabbit edit after a reply invalidates the earlier evidence"
jq '.[0].body += "\n\n✅ Confirmed as addressed by @nathanjohnpayne\n\n<!-- This is an auto-generated reply by CodeRabbit -->\n\nordinary trailing content"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "CodeRabbit confirmation pair before trailing content is not a trusted suffix"
jq '.[0].body += "\n\n```text\n✅ Confirmed as addressed by @nathanjohnpayne\n<!-- This is an auto-generated reply by CodeRabbit -->\n```"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "quoted CodeRabbit confirmation pair is not a trusted suffix"
jq '.[0].body += "\n\n```text\n✅ Confirmed as addressed by @nathanjohnpayne\n<!-- This is an auto-generated reply by CodeRabbit -->"' \
  "$TMP/fixtures/inline.json" >"$TMP/fixtures/inline.next"
mv "$TMP/fixtures/inline.next" "$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$RUN_RC" "unclosed fenced CodeRabbit confirmation pair is not a trusted suffix"

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
    "body": "$ACK_TOKEN\n."
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "punctuation-only acknowledgement rationale does not reconcile"

cat >"$TMP/fixtures/issues.json" <<JSON
[
  {
    "id": 901,
    "created_at": "2026-08-18T22:10:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": "$ACK_TOKEN\n👍"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "emoji-only acknowledgement rationale does not reconcile"

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

PREVIOUS_REVIEW="$TMP/previous-review.txt"
cat >"$PREVIOUS_REVIEW" <<'EOF'
### Codex Review

![P1 Badge] Review-body finding removed by a later edit.
EOF
set +e
REVIEW_ARCHIVE=$("$RENDER_ARCHIVE" review-body 900 'chatgpt-codex-connector[bot]' \
  '2026-08-18T22:12:00Z' "$PREVIOUS_REVIEW")
REVIEW_ARCHIVE_RC=$?
set -e
assert_eq 0 "$REVIEW_ARCHIVE_RC" "review-body archive renderer accepts an edited review source"
REVIEW_ARCHIVE_DATA=$(printf '%s' "$REVIEW_ARCHIVE" \
  | sed -E 's/^<!-- mergepath-feedback-archive:v1 ([A-Za-z0-9+\/=]+) -->$/\1/' \
  | jq -Rr '@base64d | fromjson')
assert_eq review-body "$(printf '%s' "$REVIEW_ARCHIVE_DATA" | jq -r '.source_kind')" "review archive preserves its source surface"
REVIEW_ARCHIVE_FINGERPRINT=$(printf '%s' "$REVIEW_ARCHIVE_DATA" | jq -r '.body_fingerprint')
EXPECTED_REVIEW_ARCHIVE_ACK="[mergepath-review-ack: 900 $REVIEW_ARCHIVE_FINGERPRINT]"

reset_fixtures
cat >"$TMP/fixtures/reviews.json" <<'JSON'
[
  {
    "id": 900,
    "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "submitted_at": "2026-08-18T22:00:00Z",
    "state": "COMMENTED",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "body": "### Codex Review\n\nNo findings remain."
  }
]
JSON
jq -n --arg archive "$REVIEW_ARCHIVE" --arg token "$EXPECTED_REVIEW_ARCHIVE_ACK" '[
  {
    "id": 902,
    "created_at": "2026-08-18T22:11:00Z",
    "updated_at": "2026-08-18T22:11:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": ($token + "\nDisposition posted before the review-body edit.")
  },
  {
    "id": 903,
    "created_at": "2026-08-18T22:12:01Z",
    "updated_at": "2026-08-18T22:12:01Z",
    "user": {"login": "github-actions[bot]"},
    "body": $archive
  }
]' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "edited review-body finding remains in the accounting inventory"
assert_eq review-body-archive "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "edited review body is identified as archived feedback"
assert_eq "$EXPECTED_REVIEW_ARCHIVE_ACK" "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')" "archived review body retains the review acknowledgement channel"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.accounted')" "pre-edit acknowledgement cannot clear an archived review-body finding"
jq --arg token "$EXPECTED_REVIEW_ARCHIVE_ACK" '. + [{
  "id": 904,
  "created_at": "2026-08-18T22:13:00Z",
  "updated_at": "2026-08-18T22:13:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nDispositioned the archived review-body finding after its edit.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "post-edit acknowledgement reconciles archived review-body feedback"

# A top-level review keeps its immutable submitted_at across body edits. When
# the body later returns to an archived finding version, the matching archive's
# edit timestamp must become the live finding's evidence floor; otherwise the
# original acknowledgement token is accepted again after the re-raise.
reset_fixtures
jq -n --rawfile body "$PREVIOUS_REVIEW" '[{
  "id": 900,
  "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "submitted_at": "2026-08-18T22:00:00Z",
  "state": "COMMENTED",
  "user": {"login": "chatgpt-codex-connector[bot]"},
  "body": $body
}]' >"$TMP/fixtures/reviews.json"
jq -n --arg archive "$REVIEW_ARCHIVE" --arg token "$EXPECTED_REVIEW_ARCHIVE_ACK" '[
  {
    "id": 905,
    "created_at": "2026-08-18T22:11:00Z",
    "updated_at": "2026-08-18T22:11:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": ($token + "\nDisposition posted before the review-body finding was removed.")
  },
  {
    "id": 906,
    "created_at": "2026-08-18T22:12:01Z",
    "updated_at": "2026-08-18T22:12:01Z",
    "user": {"login": "github-actions[bot]"},
    "body": $archive
  }
]' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "review-body reversion rejects acknowledgement from before the archived edit"
assert_eq "$EXPECTED_REVIEW_ARCHIVE_ACK" "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')" "reverted review body keeps its content-pinned acknowledgement channel"
jq --arg token "$EXPECTED_REVIEW_ARCHIVE_ACK" '. + [{
  "id": 907,
  "created_at": "2026-08-18T22:13:00Z",
  "updated_at": "2026-08-18T22:13:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nDispositioned the review-body finding after its latest archived edit.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "post-edit acknowledgement reconciles a reverted review-body finding"

# A second edit can archive an intermediate body after the acknowledgement
# above. The live body has returned to the same A fingerprint, but the latest
# edit of this review source is now the B -> A transition. The A acknowledgement
# must not clear that later re-raise merely because the intermediate B archive
# has a different fingerprint.
INTERMEDIATE_REVIEW="$TMP/intermediate-review.txt"
printf '%s\n' '### Codex Review' '' \
  '![P2 Badge] Different finding while the original A finding is removed.' \
  >"$INTERMEDIATE_REVIEW"
INTERMEDIATE_REVIEW_ARCHIVE=$("$RENDER_ARCHIVE" review-body 900 \
  'chatgpt-codex-connector[bot]' '2026-08-18T22:14:00Z' "$INTERMEDIATE_REVIEW")
INTERMEDIATE_REVIEW_ARCHIVE_DATA=$(printf '%s' "$INTERMEDIATE_REVIEW_ARCHIVE" \
  | sed -E 's/^<!-- mergepath-feedback-archive:v1 ([A-Za-z0-9+\/=]+) -->$/\1/' \
  | jq -Rr '@base64d | fromjson')
INTERMEDIATE_REVIEW_ACK="[mergepath-review-ack: 900 $(printf '%s' \
  "$INTERMEDIATE_REVIEW_ARCHIVE_DATA" | jq -r '.body_fingerprint')]"
jq --arg archive "$INTERMEDIATE_REVIEW_ARCHIVE" '. + [{
  "id": 908,
  "created_at": "2026-08-18T22:14:01Z",
  "updated_at": "2026-08-18T22:14:01Z",
  "user": {"login": "github-actions[bot]"},
  "body": $archive
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "A to B to A review re-raise rejects acknowledgement before the latest source edit"
assert_eq "2026-08-18T22:14:00Z" "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].updated_at')" \
  "re-raised review body uses the latest archive timestamp for the review source"
jq --arg token "$EXPECTED_REVIEW_ARCHIVE_ACK" \
  --arg intermediate_token "$INTERMEDIATE_REVIEW_ACK" '. + [{
  "id": 909,
  "created_at": "2026-08-18T22:15:00Z",
  "updated_at": "2026-08-18T22:15:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nDispositioned the re-raised review after its latest source edit.")
}, {
  "id": 910,
  "created_at": "2026-08-18T22:15:00Z",
  "updated_at": "2026-08-18T22:15:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($intermediate_token + "\nDispositioned the archived intermediate review finding too.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "strictly later acknowledgement reconciles an A to B to A review re-raise"

reset_fixtures
cat >"$TMP/fixtures/issues.json" <<'JSON'
[
  {
    "id": 7990,
    "created_at": "2026-08-18T22:19:00Z",
    "updated_at": "2026-08-18T22:19:01Z",
    "user": {"login": "coderabbitai[bot]"},
    "body": "<!-- This is an auto-generated reply by CodeRabbit -->\n<!-- CodeRabbit review command invocation: 209adf6e-339a-46b4-8277-9f715b45ab63 -->\n<details>\n<summary>⚠️ Action not completed</summary>\n\nReview rate limited.\n\n</details>"
  }
]
JSON
run_gate
assert_eq 0 "$RUN_RC" "CodeRabbit command-invocation rate-limit status is not inventoried (#1050)"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "status-only CodeRabbit reply creates no disposition obligation"

jq '.[0].body = "<!-- This is an auto-generated reply by CodeRabbit -->\n<details>\n<summary>⚠️ Action not completed</summary>\nReview rate limited.\n</details>"' \
  "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "status summary without the command-invocation marker fails toward classification"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "one-sided status near miss retains its warning tier"

jq '.[0].body = "<!-- CodeRabbit review command invocation: live-id -->\n<details>\n<summary>⚠️ Action not completed</summary>\nReview rate limited.\n</details>\n\n_📐 Maintainability & Code Quality_ | _🟡 Minor_\n\n**Keep the retry counter bounded.**"' \
  "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "mixed CodeRabbit status plus real finding remains inventoried"
assert_eq p2 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "mixed status preserves the real finding tier instead of the status warning"

STATUS_ARCHIVE_BODY="$TMP/status-archive-body.txt"
cat >"$STATUS_ARCHIVE_BODY" <<'EOF'
<!-- This is an auto-generated reply by CodeRabbit -->
<!-- CodeRabbit review command invocation: v2:40695c92071a7774b4a6b4f0e9eb06deacb14b457ca3ec1044886bf8782b8cc7 -->
<details>
<summary>⚠️ Action not completed</summary>

Review rate limited.

</details>
EOF
STATUS_ARCHIVE_MARKER=$("$RENDER_ARCHIVE" issue-comment 7990 'coderabbitai[bot]' \
  '2026-08-18T22:19:02Z' "$STATUS_ARCHIVE_BODY")
assert_eq "" "$STATUS_ARCHIVE_MARKER" "archived CodeRabbit command status emits no invented finding record"

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
  "created_at": "2026-08-18T22:20:00Z",
  "updated_at": "2026-08-18T22:20:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nFixed the summary-only finding in abc1234.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "same-second PR-level acknowledgement cannot prove it followed the latest raise"
jq 'map(if .id == 8001 then .created_at = "2026-08-18T22:21:00Z" | .updated_at = "2026-08-18T22:21:00Z" else . end)' \
  "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "PR-level bot acknowledgement with rationale reconciles"
assert_eq comment-ack "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "PR-level acknowledgement evidence is visible"
jq '.[0].body += " (edited)" | .[0].updated_at = "2026-08-18T22:22:00Z"' \
  "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "editing a PR-level bot finding invalidates its prior acknowledgement"

PREVIOUS_SUMMARY="$TMP/previous-summary.txt"
cat >"$PREVIOUS_SUMMARY" <<'EOF'
<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
_🟠 Major_ prior-head summary finding that must survive a rewrite.
EOF
ARCHIVE_MARKER=""
if [ -x "$RENDER_ARCHIVE" ]; then
  ARCHIVE_MARKER=$("$RENDER_ARCHIVE" issue-comment 8000 'coderabbitai[bot]' \
    '2026-08-18T22:23:00Z' "$PREVIOUS_SUMMARY") || true
fi
if printf '%s' "$ARCHIVE_MARKER" | grep -Eq '^<!-- mergepath-feedback-archive:v1 [A-Za-z0-9+/=]+ -->$'; then
  pass "edited-summary archive renderer emits a hidden version record"
else
  fail "edited-summary archive renderer emits a hidden version record"
  ARCHIVE_PAYLOAD=$(jq -nc \
    --argjson source_comment_id 8000 \
    --arg source_login 'coderabbitai[bot]' \
    --arg archived_at '2026-08-18T22:23:00Z' \
    --arg body_fingerprint '0123456789ab' \
    '{source_comment_id:$source_comment_id,source_login:$source_login,archived_at:$archived_at,body_fingerprint:$body_fingerprint,codex_tiers:[],coderabbit_tiers:["p1"]}')
  ARCHIVE_MARKER="<!-- mergepath-feedback-archive:v1 $(printf '%s' "$ARCHIVE_PAYLOAD" | jq -Rr '@base64') -->"
fi
ARCHIVE_DATA=$(printf '%s' "$ARCHIVE_MARKER" \
  | sed -E 's/^<!-- mergepath-feedback-archive:v1 ([A-Za-z0-9+\/=]+) -->$/\1/' \
  | jq -Rr '@base64d | fromjson')
assert_eq 8000 "$(printf '%s' "$ARCHIVE_DATA" | jq -r '.source_comment_id')" "archive record stays bound to the rewritten source comment"
assert_eq "$(cat "$PREVIOUS_SUMMARY")" "$(printf '%s' "$ARCHIVE_DATA" | jq -r '.body')" "archive record preserves the complete reviewer finding body"
assert_eq "$(wc -c <"$PREVIOUS_SUMMARY" | tr -d ' ')" \
  "$(printf '%s' "$ARCHIVE_DATA" | jq -j '.body' | wc -c | tr -d ' ')" \
  "archive record preserves the exact reviewer finding byte length"
ARCHIVE_FINGERPRINT=$(printf '%s' "$ARCHIVE_DATA" | jq -r '.body_fingerprint')
EXPECTED_ARCHIVE_ACK="[mergepath-comment-ack: 8000 $ARCHIVE_FINGERPRINT]"

PREVIOUS_ARCHIVE="$TMP/previous-archive-marker.txt"
printf '%s\n' "$ARCHIVE_MARKER" >"$PREVIOUS_ARCHIVE"
RESTORED_ARCHIVE=$("$RENDER_ARCHIVE" issue-comment 8002 'github-actions[bot]' \
  '2026-08-18T22:23:02Z' "$PREVIOUS_ARCHIVE")
assert_eq "$ARCHIVE_MARKER" "$RESTORED_ARCHIVE" "archive-marker mutation re-emits the immutable history record"

# Relay terminal markers are themselves the durable safety record for a
# read-only source run. Deleting either status must restore the exact marker;
# otherwise the relay can evaluate while the failed/pending state is absent.
for relay_status in failed complete; do
  RELAY_MARKER="<!-- mergepath-feedback-archive-relay:v1 run=12345 status=$relay_status -->"
  printf '%s\n' "$RELAY_MARKER" >"$PREVIOUS_ARCHIVE"
  RESTORED_RELAY_MARKER=$("$RENDER_ARCHIVE" issue-comment 8002 'github-actions[bot]' \
    '2026-08-18T22:23:03Z' "$PREVIOUS_ARCHIVE")
  assert_eq "$RELAY_MARKER" "$RESTORED_RELAY_MARKER" "relay $relay_status marker mutation re-emits the terminal record"
done
printf '%s\n' "$RELAY_MARKER" >"$PREVIOUS_ARCHIVE"
SPOOFED_RELAY_RESTORE=$("$RENDER_ARCHIVE" issue-comment 8002 nathanjohnpayne \
  '2026-08-18T22:23:03Z' "$PREVIOUS_ARCHIVE")
assert_eq "" "$SPOOFED_RELAY_RESTORE" "non-Actions relay marker cannot be promoted into a trusted record"

jq -n --arg archive "$ARCHIVE_MARKER" --arg token "$EXPECTED_ARCHIVE_ACK" '[
  {
    "id": 8000,
    "created_at": "2026-08-18T22:20:00Z",
    "updated_at": "2026-08-18T22:23:00Z",
    "user": {"login": "coderabbitai[bot]"},
    "body": "<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\n**Actionable comments posted: 0**"
  },
  {
    "id": 8001,
    "created_at": "2026-08-18T22:22:00Z",
    "updated_at": "2026-08-18T22:22:00Z",
    "user": {"login": "nathanpayne-codex"},
    "body": ($token + "\nDisposition posted before the summary rewrite.")
  },
  {
    "id": 8002,
    "created_at": "2026-08-18T22:23:01Z",
    "updated_at": "2026-08-18T22:23:01Z",
    "user": {"login": "github-actions[bot]"},
    "body": $archive
  }
]' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "rewritten summary keeps its latest archived finding in inventory"
assert_eq issue-comment-archive "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "rewritten summary is identified as archived issue-comment feedback"
assert_eq "$EXPECTED_ARCHIVE_ACK" "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')" "archived summary retains a content-pinned acknowledgement path"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.accounted')" "pre-rewrite acknowledgement cannot clear an archived summary finding"
ARCHIVE_ACK=$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')
jq --arg token "$ARCHIVE_ACK" '. + [{
  "id": 8003,
  "created_at": "2026-08-18T22:24:00Z",
  "updated_at": "2026-08-18T22:24:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nDispositioned the archived summary finding after its rewrite.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "post-rewrite acknowledgement reconciles the archived summary finding"

# Reposting the exact archive marker repairs storage, not the finding itself.
# The payload's original archived_at remains the evidence floor, so a durable
# acknowledgement does not become stale merely because the archive comment was
# restored under a new GitHub comment id and created_at.
jq --arg archive "$ARCHIVE_MARKER" '
  map(select(.id != 8002)) + [{
    "id": 8005,
    "created_at": "2026-08-18T22:30:00Z",
    "updated_at": "2026-08-18T22:30:00Z",
    "user": {"login": "github-actions[bot]"},
    "body": $archive
  }]
' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "restored archive retains its original evidence floor"

cat >"$PREVIOUS_SUMMARY" <<'EOF'
<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
_🟡 Minor_ a second distinct summary finding removed by a later rewrite.
EOF
ARCHIVE_MARKER_TWO=$("$RENDER_ARCHIVE" issue-comment 8000 'coderabbitai[bot]' \
  '2026-08-18T22:25:00Z' "$PREVIOUS_SUMMARY")
jq --arg archive "$ARCHIVE_MARKER_TWO" '. + [{
  "id": 8004,
  "created_at": "2026-08-18T22:25:01Z",
  "updated_at": "2026-08-18T22:25:01Z",
  "user": {"login": "github-actions[bot]"},
  "body": $archive
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 2 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "distinct removed summary versions remain separate findings"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing_count')" "acknowledging one archived version cannot erase another"

reset_fixtures
LARGE_ARCHIVE_BODY="$TMP/large-archive-body.txt"
{
  printf '**P1** Large archived finding. '
  awk 'BEGIN { for (i = 0; i < 65500; i++) printf "%c", 92 }'
} >"$LARGE_ARCHIVE_BODY"
LARGE_ARCHIVE=$("$RENDER_ARCHIVE" inline 8600 'chatgpt-codex-connector[bot]' \
  '2026-08-18T22:25:30Z' "$LARGE_ARCHIVE_BODY")
assert_match '^<!-- mergepath-feedback-archive:v2 ' "$(printf '%s\n' "$LARGE_ARCHIVE" | sed -n '1p')" "oversized archive uses chunked v2 records"
if [ "$(printf '%s\n' "$LARGE_ARCHIVE" | awk 'END { print NR }')" -gt 1 ]; then
  pass "oversized archive spans more than one durable comment"
else
  fail "oversized archive spans more than one durable comment"
fi
FIRST_LARGE_ARCHIVE=$(printf '%s\n' "$LARGE_ARCHIVE" | sed -n '1p')
printf '%s\n' "$FIRST_LARGE_ARCHIVE" >"$PREVIOUS_ARCHIVE"
RESTORED_LARGE_ARCHIVE=$("$RENDER_ARCHIVE" issue-comment 8601 'github-actions[bot]' \
  '2026-08-18T22:25:31Z' "$PREVIOUS_ARCHIVE")
if [ "$RESTORED_LARGE_ARCHIVE" = "$FIRST_LARGE_ARCHIVE" ]; then
  pass "chunked archive-marker mutation re-emits the exact record"
else
  fail "chunked archive-marker mutation re-emits the exact record"
fi
printf '%s\n' "$LARGE_ARCHIVE" | jq -Rs '
  split("\n") | map(select(length > 0)) | to_entries
  | map({
      id: (8601 + .key),
      created_at: "2026-08-18T22:25:31Z",
      updated_at: "2026-08-18T22:25:31Z",
      user: {login: "github-actions[bot]"},
      body: .value
    })
' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "complete chunked archive remains an undispositioned finding"
assert_eq "$(wc -c <"$LARGE_ARCHIVE_BODY" | tr -d ' ')" \
  "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].body | length')" \
  "chunked archive reconstructs the complete finding body"
jq 'del(.[-1])' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 2 "$RUN_RC" "incomplete chunked archive fails closed"

OVERSIZED_ARCHIVE_BODY="$TMP/oversized-archive-body.txt"
awk 'BEGIN { printf "**P1** "; for (i = 0; i < 1600000; i++) printf "x" }' \
  >"$OVERSIZED_ARCHIVE_BODY"
set +e
"$RENDER_ARCHIVE" inline 8499 'chatgpt-codex-connector[bot]' \
  '2026-08-18T22:25:59Z' "$OVERSIZED_ARCHIVE_BODY" \
  >"$TMP/oversized-archive-records" 2>"$TMP/oversized-archive-error"
OVERSIZED_ARCHIVE_RC=$?
set -e
assert_eq 2 "$OVERSIZED_ARCHIVE_RC" "archive producer rejects a payload beyond the consumer chunk limit"
assert_eq 0 "$(wc -c <"$TMP/oversized-archive-records" | tr -d ' ')" "oversized archive emits no partial record set"
assert_match '32' "$(cat "$TMP/oversized-archive-error")" "oversized archive names the shared chunk limit"

reset_fixtures
PREVIOUS_INLINE="$TMP/previous-inline.txt"
cat >"$PREVIOUS_INLINE" <<'EOF'
**P1** Inline finding deleted before it received a disposition.
EOF
INLINE_ARCHIVE=$("$RENDER_ARCHIVE" inline 8500 'chatgpt-codex-connector[bot]' \
  '2026-08-18T22:26:00Z' "$PREVIOUS_INLINE")
jq -n --arg archive "$INLINE_ARCHIVE" '[{
  "id": 8501,
  "created_at": "2026-08-18T22:26:01Z",
  "updated_at": "2026-08-18T22:26:01Z",
  "user": {"login": "github-actions[bot]"},
  "body": $archive
}]' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "deleted inline finding remains in the accounting inventory"
assert_eq inline-archive "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].kind')" "deleted inline feedback retains its source kind"
INLINE_ARCHIVE_ACK=$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].ack_token')
assert_match '^\[mergepath-inline-ack: 8500 [0-9a-f]{12}\]$' "$INLINE_ARCHIVE_ACK" "deleted inline finding gets a content-pinned acknowledgement path"
assert_match 'archived inline .* finding' "$RUN_ERR" "deleted inline remediation names the archived source surface"
jq --arg token "$INLINE_ARCHIVE_ACK" '. + [{
  "id": 8502,
  "created_at": "2026-08-18T22:27:00Z",
  "updated_at": "2026-08-18T22:27:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": ($token + "\nDispositioned the deleted inline finding after archival.")
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
run_gate
assert_eq 0 "$RUN_RC" "post-deletion acknowledgement reconciles archived inline feedback"

reset_fixtures
cat >"$PREVIOUS_INLINE" <<'EOF'
**P1** Registered reviewer inline finding deleted before disposition.
EOF
REGISTERED_INLINE_ARCHIVE=$("$RENDER_ARCHIVE" inline 8510 'nathanpayne-claude' \
  '2026-08-18T22:28:00Z' "$PREVIOUS_INLINE")
jq -n --arg archive "$REGISTERED_INLINE_ARCHIVE" '[{
  "id": 8511,
  "created_at": "2026-08-18T22:28:01Z",
  "updated_at": "2026-08-18T22:28:01Z",
  "user": {"login": "github-actions[bot]"},
  "body": $archive
}]' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 1 "$RUN_RC" "deleted registered-reviewer inline finding remains in inventory"
assert_eq nathanpayne-claude "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "archived inline finding stays bound to the registered reviewer"

# A distinct live rewrite and its archived predecessor are separate finding
# versions. Neither may hide the other merely because they reuse a source id.
jq -n '[{
  "id": 8510,
  "in_reply_to_id": null,
  "created_at": "2026-08-18T22:28:00Z",
  "updated_at": "2026-08-18T22:29:00Z",
  "user": {"login": "nathanpayne-claude"},
  "path": "src/live.ts",
  "line": 12,
  "body": "**P1** Registered reviewer inline finding re-raised live."
}]' >"$TMP/fixtures/inline.json"
run_gate
assert_eq 2 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "live inline rewrite retains its distinct archived predecessor"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '[.findings[] | select(.kind == "inline")] | length')" "live inline finding keeps the direct inventory path"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '[.findings[] | select(.kind == "inline-archive")] | length')" "distinct archived inline finding remains independently dispositionable"

reset_fixtures
EXACT_INLINE_BODY='**P1** Identical live and archived inline finding.'
printf '%s' "$EXACT_INLINE_BODY" >"$PREVIOUS_INLINE"
EXACT_INLINE_ARCHIVE=$("$RENDER_ARCHIVE" inline 8520 'nathanpayne-claude' \
  '2026-08-18T22:31:00Z' "$PREVIOUS_INLINE")
jq -n --arg archive "$EXACT_INLINE_ARCHIVE" '[{
  "id": 8521,
  "created_at": "2026-08-18T22:31:01Z",
  "updated_at": "2026-08-18T22:31:01Z",
  "user": {"login": "github-actions[bot]"},
  "body": $archive
}]' >"$TMP/fixtures/issues.json"
jq -n --arg body "$EXACT_INLINE_BODY" '[{
  "id": 8520,
  "in_reply_to_id": null,
  "created_at": "2026-08-18T22:31:00Z",
  "updated_at": "2026-08-18T22:31:00Z",
  "user": {"login": "nathanpayne-claude"},
  "path": "src/live.ts",
  "line": 12,
  "body": $body
}]' >"$TMP/fixtures/inline.json"
run_gate
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "identical live and archived bodies collapse to one logical finding"
assert_eq inline "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].kind')" "identical archive retry defers to the direct inventory path"

reset_fixtures
PREVIOUS_SUMMARY="$TMP/previous-summary.txt"
printf '%s' '_⚠️ Potential issue_ Original CodeRabbit summary finding.' >"$PREVIOUS_SUMMARY"
SUMMARY_ARCHIVE=$("$RENDER_ARCHIVE" issue-comment 8530 'coderabbitai[bot]' \
  '2026-08-18T22:32:00Z' "$PREVIOUS_SUMMARY")
jq -n --arg archive "$SUMMARY_ARCHIVE" '[
  {
    "id": 8530,
    "created_at": "2026-08-18T22:30:00Z",
    "updated_at": "2026-08-18T22:33:00Z",
    "user": {"login": "coderabbitai[bot]"},
    "body": "_🟠 Major_ Replacement CodeRabbit summary finding."
  },
  {
    "id": 8531,
    "created_at": "2026-08-18T22:32:01Z",
    "updated_at": "2026-08-18T22:32:01Z",
    "user": {"login": "github-actions[bot]"},
    "body": $archive
  }
]' >"$TMP/fixtures/issues.json"
run_gate
assert_eq 2 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "CodeRabbit summary rewrite preserves both distinct finding versions"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '[.findings[] | select(.kind == "issue-comment-archive")] | length')" "rewritten CodeRabbit summary retains the archived predecessor"

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

# An unmatched pre-merge-check START earlier in the body must not extend the
# later, properly paired block back over the intervening text. Pairing on the
# FIRST start swallowed a real Major badge sitting between the two markers and
# the inventory reported clear with nothing to disposition (#1000 Codex P1).
jq '.[0].body = "**Actionable comments posted: 1**\n\n<!-- pre_merge_checks_walkthrough_start -->\n\n_🟠 Major_ real finding between an unpaired start and a paired block\n\n<!-- pre_merge_checks_walkthrough_start -->\n| Docstring Coverage | ⚠️ Warning |\n<!-- pre_merge_checks_walkthrough_end -->"' \
  "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 1 "$RUN_RC" "an unpaired pre-merge-check start does not suppress a later real finding"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "the re-anchored block leaves the intervening finding at its real tier"

# The properly paired block itself is still suppressed: re-anchoring must not
# start classifying pre-merge-check hygiene warnings as findings.
jq '.[0].body = "**Actionable comments posted: 0**\n\n<!-- pre_merge_checks_walkthrough_start -->\n\n<!-- pre_merge_checks_walkthrough_start -->\n_🟠 Major_ hygiene warning inside the paired block\n<!-- pre_merge_checks_walkthrough_end -->"' \
  "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 0 "$RUN_RC" "re-anchoring still suppresses the properly paired pre-merge-check block"

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
cp "$TMP/fixtures/inline.json" "$TMP/fixtures/ignored-inline.json"
reset_fixtures
cat >"$TMP/fixtures/reviews.json" <<'JSON'
[
  {
    "id": 904,
    "commit_id": "dddddddddddddddddddddddddddddddddddddddd",
    "submitted_at": "2026-08-18T22:55:00Z",
    "state": "COMMENTED",
    "user": {"login": "chatgpt-codex-connector[bot]"},
    "body": "### Codex Review\n\n- **P3** Cosmetic wording\n- **P1** Required safety guard"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "ignored marker before required marker does not hide the review-body finding"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "mixed-severity review body keeps its strongest tier"
jq '.[0].id = 905
  | .[0].user.login = "coderabbitai[bot]"
  | .[0].body = "**Actionable comments posted: 2**\n\n🔵 Trivial cosmetic wording\n\n🟠 Major required safety guard"' \
  "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 1 "$RUN_RC" "ignored CodeRabbit marker before required marker does not hide the review-body finding"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "mixed-severity CodeRabbit review body keeps its strongest tier"
cp "$TMP/review-policy.yml" "$TMP/review-policy.mixed.yml"
sed -e 's/p1: required/p1: ignore/' -e 's/p2: discretionary/p2: required/' \
  "$TMP/review-policy.yml" >"$TMP/review-policy.next"
mv "$TMP/review-policy.next" "$TMP/review-policy.yml"
jq '.[0].id = 906
  | .[0].user.login = "chatgpt-codex-connector[bot]"
  | .[0].body = "### Codex Review\n\n- **P1** Ignored urgent marker\n- **P2** Required lower-tier guard"' \
  "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 1 "$RUN_RC" "ignored strongest marker does not hide a required lower-tier finding"
assert_eq p2 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "mixed-severity body keeps the strongest non-ignored tier"
mv "$TMP/review-policy.mixed.yml" "$TMP/review-policy.yml"
reset_fixtures
mv "$TMP/fixtures/ignored-inline.json" "$TMP/fixtures/inline.json"
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
jq '.[0].body = "### Codex Review\n\n```text\n**P1** Preserve the exact registered-reviewer body contract\n```"' \
  "$TMP/fixtures/reviews.json" >"$TMP/fixtures/reviews.next"
mv "$TMP/fixtures/reviews.next" "$TMP/fixtures/reviews.json"
run_gate
assert_eq 1 "$RUN_RC" "CodeRabbit-only sanitization does not suppress a Codex marker"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "Codex top-level body uses the unsanitized canonical ladder"

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

reset_fixtures
FINGERPRINT_ONE=$(env PATH="$TMP/bin:$PATH" GH_TOKEN=test-token \
  GH_FIXTURE_DIR="$TMP/fixtures" GH_CALL_LOG="$TMP/gh-calls.log" \
  "$SURFACE_FINGERPRINT" 7 acme/widget)

# An unreadable surface must reach the caller as BOTH a status and a
# diagnostic. The parent-side handler removed in #1089 delivered neither:
# GH_API_ARRAY_ERROR is set inside the command-substitution SUBSHELL, so by
# the time the parent referenced it the variable was unset, and under `set -u`
# the handler itself died on the unbound variable -- exiting 1 rather than the
# 2 it was written to return. Assert the MESSAGE and not only the code: a
# code-only assertion is satisfied by any nonzero exit, which the broken form
# already produced, and that gap is what let this survive since #1018.
set +e
FINGERPRINT_ERROR=$(env PATH="$TMP/bin:$PATH" GH_TOKEN=test-token \
  GH_FIXTURE_DIR="$TMP/fixtures" GH_CALL_LOG="$TMP/gh-calls.log" \
  GH_FAIL_ENDPOINT="repos/acme/widget/pulls/7/reviews" \
  "$SURFACE_FINGERPRINT" 7 acme/widget 2>&1 >/dev/null)
FINGERPRINT_RC=$?
set -e
assert_eq 2 "$FINGERPRINT_RC" "feedback-surface fingerprint preserves API failure status"
assert_match 'failed to fetch review objects' "$FINGERPRINT_ERROR" \
  "feedback-surface fingerprint preserves API failure detail"

# #1088: the fetch case above is one of THREE gh_api_array failure kinds
# (fetch, flatten, shape — scripts/lib/gh-api-array.sh). A fix scoped to only
# the fetch path would leave the other two free to regress back into the
# unbound-variable trace #1089 removed.
reset_fixtures
printf 'not valid json\n' >"$TMP/fixtures/reviews.json"
set +e
FINGERPRINT_FLATTEN_ERROR=$(env PATH="$TMP/bin:$PATH" GH_TOKEN=test-token \
  GH_FIXTURE_DIR="$TMP/fixtures" GH_CALL_LOG="$TMP/gh-calls.log" \
  "$SURFACE_FINGERPRINT" 7 acme/widget 2>&1 >/dev/null)
FINGERPRINT_FLATTEN_RC=$?
set -e
assert_eq 2 "$FINGERPRINT_FLATTEN_RC" "feedback-surface fingerprint preserves flatten failure status"
assert_match 'failed to flatten review objects pagination output' "$FINGERPRINT_FLATTEN_ERROR" \
  "feedback-surface fingerprint preserves flatten failure detail"

reset_fixtures
printf '{"message":"Bad credentials"}\n' >"$TMP/fixtures/reviews.json"
set +e
FINGERPRINT_SHAPE_ERROR=$(env PATH="$TMP/bin:$PATH" GH_TOKEN=test-token \
  GH_FIXTURE_DIR="$TMP/fixtures" GH_CALL_LOG="$TMP/gh-calls.log" \
  "$SURFACE_FINGERPRINT" 7 acme/widget 2>&1 >/dev/null)
FINGERPRINT_SHAPE_RC=$?
set -e
assert_eq 2 "$FINGERPRINT_SHAPE_RC" "feedback-surface fingerprint preserves shape failure status"
assert_match 'came back as .*not a stream of JSON arrays' "$FINGERPRINT_SHAPE_ERROR" \
  "feedback-surface fingerprint preserves shape failure detail"

reset_fixtures
jq '. + [{
  "id": 9900,
  "created_at": "2026-08-18T23:10:00Z",
  "updated_at": "2026-08-18T23:10:00Z",
  "user": {"login": "nathanpayne-codex"},
  "body": "A new disposition changes the feedback generation."
}]' "$TMP/fixtures/issues.json" >"$TMP/fixtures/issues.next"
mv "$TMP/fixtures/issues.next" "$TMP/fixtures/issues.json"
FINGERPRINT_TWO=$(env PATH="$TMP/bin:$PATH" GH_TOKEN=test-token \
  GH_FIXTURE_DIR="$TMP/fixtures" GH_CALL_LOG="$TMP/gh-calls.log" \
  "$SURFACE_FINGERPRINT" 7 acme/widget)
if [ -n "$FINGERPRINT_ONE" ] && [ "$FINGERPRINT_ONE" != "$FINGERPRINT_TWO" ]; then
  pass "feedback-surface fingerprint changes with PR-level disposition state"
else
  fail "feedback-surface fingerprint changes with PR-level disposition state"
fi

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
if grep -F -- "--argjson c \"\$comment\"" "$SCRIPT" >/dev/null; then
  fail "inline finding inventory must stream each comment instead of passing it through argv"
else
  pass "inline finding inventory streams each comment instead of passing it through argv"
fi
if grep -Eq -- '--argjson (inline|reviews|issues)([[:space:]\\]|$)' "$SURFACE_FINGERPRINT"; then
  fail "surface fingerprint must stream complete histories instead of passing them through argv"
else
  pass "surface fingerprint streams complete histories instead of passing them through argv"
fi

# --- github-advanced-security / code scanning (#1101) ----------------------
#
# Before #1101, a github-advanced-security[bot] inline comment (the form
# GitHub's CodeQL code scanning posts) was invisible to this script — not
# even counted in `posted` — so a real finding could ride through repeated
# "fully accounted" rounds unread (observed on nathanpaynedotcom#809).

reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 20,
    "in_reply_to_id": null,
    "created_at": "2026-08-26T20:49:01Z",
    "user": {"login": "github-advanced-security[bot]"},
    "path": "tests/verify-brevity.test.js",
    "line": 185,
    "body": "## CodeQL / Replacement of a substring with itself\n\nThis replaces 'title: \"Signed\"' with itself.\n\n[Show more details](https://github.com/acme/widget/security/code-scanning/25)"
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "undispositioned CodeQL finding blocks (#1101)"
assert_eq unaccounted "$(printf '%s' "$RUN_JSON" | jq -r '.status')" "CodeQL miss emits unaccounted status"
assert_eq 1 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "CodeQL finding contributes to posted count"
assert_eq github-advanced-security\[bot\] "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].reviewer')" "CodeQL finding is inventoried under its bot login"
assert_eq p2 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "unresolvable severity (no matching alert) falls back to p2, not dropped"

if grep -F 'repos/acme/widget/code-scanning/alerts' "$TMP/gh-calls.log" >/dev/null; then
  pass "a CodeQL comment on the PR triggers the code-scanning/alerts lookup"
else
  fail "a CodeQL comment on the PR triggers the code-scanning/alerts lookup"
fi

cat >"$TMP/fixtures/code-scanning-alerts.json" <<'JSON'
[
  {"number": 25, "rule": {"security_severity_level": "medium"}}
]
JSON
run_gate
assert_eq p2 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "medium security_severity_level maps to p2"

cat >"$TMP/fixtures/code-scanning-alerts.json" <<'JSON'
[
  {"number": 25, "rule": {"security_severity_level": "critical"}}
]
JSON
run_gate
assert_eq p0 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "critical security_severity_level maps to p0"

cat >"$TMP/fixtures/code-scanning-alerts.json" <<'JSON'
[
  {"number": 25, "rule": {"security_severity_level": "high"}}
]
JSON
cat >"$TMP/fixtures/inline-with-reply.json" <<'JSON'
[
  {
    "id": 20,
    "in_reply_to_id": null,
    "created_at": "2026-08-26T20:49:01Z",
    "user": {"login": "github-advanced-security[bot]"},
    "path": "tests/verify-brevity.test.js",
    "line": 185,
    "body": "## CodeQL / Replacement of a substring with itself\n\nThis replaces 'title: \"Signed\"' with itself.\n\n[Show more details](https://github.com/acme/widget/security/code-scanning/25)"
  },
  {
    "id": 21,
    "in_reply_to_id": 20,
    "created_at": "2026-08-26T21:00:00Z",
    "user": {"login": "nathanpayne-codex"},
    "path": "tests/verify-brevity.test.js",
    "line": 185,
    "body": "Confirmed and fixed the self-replace in commit abc1234."
  }
]
JSON
cp "$TMP/fixtures/inline-with-reply.json" "$TMP/fixtures/inline.json"
run_gate
assert_eq 0 "$RUN_RC" "agent reply after a CodeQL finding accounts for it"
assert_eq clear "$(printf '%s' "$RUN_JSON" | jq -r '.status')" "disposed CodeQL finding clears the gate"
assert_eq p1 "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].tier')" "high security_severity_level maps to p1"
assert_eq thread-reply "$(printf '%s' "$RUN_JSON" | jq -r '.findings[0].evidence')" "CodeQL reply evidence is visible"

# feedback_policy tiers apply uniformly across reviewers: a repo that
# marks p2 `ignore` must drop an unresolvable-severity CodeQL finding
# from inventory exactly as it would a CodeRabbit or Codex one.
reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 22,
    "in_reply_to_id": null,
    "created_at": "2026-08-26T20:49:01Z",
    "user": {"login": "github-advanced-security[bot]"},
    "path": "src/a.js",
    "line": 1,
    "body": "## CodeQL / Some quality rule\n\nNo severity assigned.\n\n[Show more details](https://github.com/acme/widget/security/code-scanning/99)"
  }
]
JSON
cp "$TMP/review-policy.yml" "$TMP/review-policy.ignore-p2.yml"
cat >>"$TMP/review-policy.yml" <<'YAML'
feedback_policy:
  mode: by-priority
  priorities:
    p2: ignore
YAML
run_gate
assert_eq 0 "$RUN_RC" "feedback_policy p2:ignore excludes an unresolvable-severity CodeQL finding"
assert_eq 0 "$(printf '%s' "$RUN_JSON" | jq -r '.posted')" "ignored CodeQL tier contributes nothing to posted count"
mv "$TMP/review-policy.ignore-p2.yml" "$TMP/review-policy.yml"

# The alerts lookup is lazy: a PR with no CodeQL comment must never call
# code-scanning/alerts, so a repo without code scanning enabled (the
# common fleet case) never pays the extra API round-trip or risks a
# permissions failure on an endpoint it has no reason to use.
reset_fixtures
run_gate
if grep -F 'repos/acme/widget/code-scanning/alerts' "$TMP/gh-calls.log" >/dev/null; then
  fail "code-scanning/alerts must not be fetched when no CodeQL comment is present"
else
  pass "code-scanning/alerts is not fetched when no CodeQL comment is present"
fi

# A CodeQL comment body with no parseable alert-number link at all (not
# just a link to an alert absent from the fetched set) must fall back to
# p2 rather than aborting the gate under `set -euo pipefail` — the grep
# pipeline that extracts the alert number legitimately produces no match.
reset_fixtures
cat >"$TMP/fixtures/inline.json" <<'JSON'
[
  {
    "id": 23,
    "in_reply_to_id": null,
    "created_at": "2026-08-26T20:49:01Z",
    "user": {"login": "github-advanced-security[bot]"},
    "path": "src/b.js",
    "line": 1,
    "body": "## CodeQL / Some rule\n\nNo alert link in this body at all."
  }
]
JSON
run_gate
assert_eq 1 "$RUN_RC" "CodeQL comment with no alert link still blocks (does not abort)"
assert_eq p2 "$(printf '%s' "$RUN_JSON" | jq -r '.missing[0].tier')" "no parseable alert link falls back to p2"

if [ "$FAIL" -ne 0 ]; then
  printf 'review-feedback-accounting: FAIL (%s failed, %s passed)\n' "$FAIL" "$PASS" >&2
  exit 1
fi

printf 'review-feedback-accounting: PASS (%s assertions)\n' "$PASS"
