#!/usr/bin/env bash
# Fingerprint every mutable GitHub surface consumed by feedback accounting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -r "$SCRIPT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$SCRIPT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi
[ -r "$SCRIPT_DIR/lib/gh-api-array.sh" ] \
  || { echo "review-feedback-surface-fingerprint: missing gh-api-array.sh" >&2; exit 2; }
# shellcheck source=lib/gh-api-array.sh
. "$SCRIPT_DIR/lib/gh-api-array.sh"

[ "$#" -eq 2 ] || { echo "usage: $0 PR_NUMBER owner/repo" >&2; exit 2; }
PR_NUMBER="$1"
REPO="$2"
case "$PR_NUMBER" in ''|*[!0-9]*) echo "invalid PR number" >&2; exit 2 ;; esac
case "$REPO" in */*) ;; *) echo "invalid repository" >&2; exit 2 ;; esac
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is required" >&2; exit 2; }

INLINE=$(gh_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline review comments") \
  || { echo "$GH_API_ARRAY_ERROR" >&2; exit 2; }
REVIEWS=$(gh_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "review objects") \
  || { echo "$GH_API_ARRAY_ERROR" >&2; exit 2; }
ISSUES=$(gh_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "PR-level comments") \
  || { echo "$GH_API_ARRAY_ERROR" >&2; exit 2; }

FINGERPRINT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/feedback-surface-fingerprint.XXXXXX")
trap 'rm -rf "$FINGERPRINT_TMP"' EXIT
printf '%s\n' "$INLINE" >"$FINGERPRINT_TMP/inline.json"
printf '%s\n' "$REVIEWS" >"$FINGERPRINT_TMP/reviews.json"
printf '%s\n' "$ISSUES" >"$FINGERPRINT_TMP/issues.json"

# Keep complete histories out of argv: a long-lived PR can exceed the process
# argument limit even though each individual GitHub response is valid.
CANONICAL=$(jq -Scn \
  --slurpfile inline "$FINGERPRINT_TMP/inline.json" \
  --slurpfile reviews "$FINGERPRINT_TMP/reviews.json" \
  --slurpfile issues "$FINGERPRINT_TMP/issues.json" '
    def actor: (.user.login // "");
    {
      inline: ($inline[0] | sort_by(.id) | map({
        id, in_reply_to_id, actor: actor, body, created_at, updated_at,
        commit_id, original_commit_id, path, line, original_line
      })),
      reviews: ($reviews[0] | sort_by(.id) | map({
        id, actor: actor, body, state, submitted_at, commit_id
      })),
      issues: ($issues[0] | sort_by(.id) | map({
        id, actor: actor, body, created_at, updated_at
      }))
    }
  ')

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s' "$CANONICAL" | sha256sum | awk '{print $1}'
elif command -v shasum >/dev/null 2>&1; then
  printf '%s' "$CANONICAL" | shasum -a 256 | awk '{print $1}'
else
  echo "review-feedback-surface-fingerprint: no SHA-256 tool available" >&2
  exit 2
fi
