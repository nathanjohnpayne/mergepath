#!/usr/bin/env bash
# Tests for the per-repository author-token class gate (#2728,
# specs/author_merge_token.md): credential_meets_author_token_class in
# scripts/lib/credential-class.sh, and the shipped Dependabot merge step that
# reads `author_merge_token_class` from the base-SHA policy and calls it.
#
# The approval-continuation wiring is covered in
# tests/test_approval_merge_continuation.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/credential-class.sh"
WORKFLOW="$ROOT/.github/workflows/dependabot-auto-merge.yml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/author-merge-token.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# shellcheck source=../scripts/lib/credential-class.sh
. "$LIB"

expect_class() {  # <expected-rc> <required> <token> <label>
  local want="$1" required="$2" token="$3" label="$4" rc
  set +e
  credential_meets_author_token_class "$required" "$token"
  rc=$?
  set -e
  if [ "$rc" -eq "$want" ]; then pass "$label"; else fail "$label (rc=$rc, want $want)"; fi
}

# ── Library ───────────────────────────────────────────────────────────
expect_class 0 ""             "ghp_sharedclassic"   "absent requirement accepts a classic token"
expect_class 0 "any"          "ghp_sharedclassic"   "any accepts a classic token"
expect_class 0 "any"          ""                    "any leaves an empty token to the caller's own check"
expect_class 0 "fine-grained" "github_pat_11ABCDEF" "fine-grained accepts github_pat_"
expect_class 1 "fine-grained" "ghp_sharedclassic"   "fine-grained rejects a classic PAT"
expect_class 1 "fine-grained" "gho_oauth"           "fine-grained rejects an OAuth token"
expect_class 1 "fine-grained" "ghs_installation"    "fine-grained rejects an installation token"
expect_class 1 "fine-grained" "proxy-injected"      "fine-grained rejects the brokered placeholder"
expect_class 1 "fine-grained" "github_pat_"         "fine-grained rejects a bare prefix"
expect_class 1 "fine-grained" "x_github_pat_abc"    "fine-grained anchors the prefix"
expect_class 1 "fine-grained" ""                    "fine-grained rejects an empty token"
expect_class 2 "classic"      "ghp_sharedclassic"   "an unknown requirement fails closed"
expect_class 2 "Fine-grained" "github_pat_11ABCDEF" "the requirement is case-sensitive"

# ── Shipped Dependabot merge step ─────────────────────────────────────
# Execute the literal block from the workflow, not a copy, from the comment
# that opens it to the first step-level `fi` after its awk reader.
BLOCK="$TMP/dependabot-class-block.sh"
awk '
  /# After this repository.s cutover, the base-SHA policy requires the/ {on=1}
  !on {next}
  {raw=$0; sub(/^          /, ""); print}
  raw ~ /^          fi$/ && seen_reader {exit}
  raw ~ /REQUIRED_AUTHOR_CLASS=\$\(awk/ {seen_reader=1}
' "$WORKFLOW" > "$BLOCK"
if grep -q 'credential_meets_author_token_class' "$BLOCK" && [ "$(tail -n 1 "$BLOCK")" = "fi" ]; then
  pass "extracted the Dependabot class block"
else
  fail "could not extract the Dependabot class block from $WORKFLOW"
fi

mkdir -p "$TMP/base/.github" "$TMP/base/scripts/lib"
cp "$LIB" "$TMP/base/scripts/lib/credential-class.sh"

run_block() {  # <policy-line or empty> <token>; prints the exit code
  local line="$1" token="$2" rc
  {
    printf 'author_identity: nathanjohnpayne\n'
    [ -z "$line" ] || printf '%s\n' "$line"
  } > "$TMP/base/.github/review-policy.yml"
  set +e
  (
    cd "$TMP/base"
    POLICY=".github/review-policy.yml" AUTHOR_MERGE_TOKEN="$token" \
      bash -c 'set -euo pipefail; . "$1"; echo REACHED' _ "$BLOCK"
  ) >"$TMP/block.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && ! grep -qx REACHED "$TMP/block.out"; then rc=99; fi
  echo "$rc"
}

expect_block() {  # <want-rc> <policy-line> <token> <label> [<stderr-substring>]
  local want="$1" line="$2" token="$3" label="$4" needle="${5:-}" got
  got=$(run_block "$line" "$token")
  if [ "$got" -eq "$want" ] && { [ -z "$needle" ] || grep -Fq "$needle" "$TMP/block.out"; }; then
    pass "$label"
  else
    fail "$label (rc=$got, want $want): $(cat "$TMP/block.out")"
  fi
}

expect_block 0 ""                                           "ghp_sharedclassic"   "workflow: absent key keeps the classic token"
expect_block 0 "author_merge_token_class: any"              "ghp_sharedclassic"   "workflow: any keeps the classic token"
expect_block 0 "author_merge_token_class: fine-grained"     "github_pat_11ABCDEF" "workflow: fine-grained accepts github_pat_ and says so" "meets author_merge_token_class 'fine-grained'"
expect_block 1 "author_merge_token_class: fine-grained"     "ghp_sharedclassic"   "workflow: fine-grained rejects the classic fallback" "Is the merge-queue-policy environment copy missing?"
expect_block 1 'author_merge_token_class: "fine-grained"'   "ghp_sharedclassic"   "workflow: a quoted value is still enforced"
expect_block 1 "author_merge_token_class: fine-grained # cut over" "ghp_sharedclassic" "workflow: a trailing comment is still enforced"
expect_block 1 "author_merge_token_class: classic"          "ghp_sharedclassic"   "workflow: an unknown value fails closed" "unknown author_merge_token_class 'classic'"

sed '/^credential_meets_author_token_class()/,$d' "$LIB" > "$TMP/base/scripts/lib/credential-class.sh"
expect_block 1 "author_merge_token_class: fine-grained"     "github_pat_11ABCDEF" "workflow: an older library fails closed" "predates the class check"
expect_block 0 "author_merge_token_class: any"              "ghp_sharedclassic"   "workflow: an older library is harmless under any"

rm "$TMP/base/scripts/lib/credential-class.sh"
expect_block 1 "author_merge_token_class: fine-grained"     "github_pat_11ABCDEF" "workflow: a missing library fails closed" "credential-class.sh is missing"
expect_block 0 "author_merge_token_class: any"              "ghp_sharedclassic"   "workflow: any needs no library (first rollout)"

echo "test_author_merge_token: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
