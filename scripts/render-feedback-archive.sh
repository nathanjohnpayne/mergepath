#!/usr/bin/env bash
# Render a compact, GitHub-visible history record for an edited/deleted
# PR-level or inline reviewer comment. The workflow owns the write; this
# helper is pure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/lib/feedback-policy-helpers.sh"
[ -r "$HELPERS" ] || { echo "render-feedback-archive: missing $HELPERS" >&2; exit 2; }
# shellcheck source=lib/feedback-policy-helpers.sh
. "$HELPERS"

if [ "$#" -ne 5 ]; then
  echo "usage: $0 SOURCE_KIND SOURCE_COMMENT_ID SOURCE_LOGIN ARCHIVED_AT PREVIOUS_BODY_FILE" >&2
  exit 2
fi

SOURCE_KIND="$1"
SOURCE_COMMENT_ID="$2"
SOURCE_LOGIN="$3"
ARCHIVED_AT="$4"
PREVIOUS_BODY_FILE="$5"

case "$SOURCE_KIND" in
  issue-comment|inline) ;;
  *) echo "render-feedback-archive: source kind must be issue-comment or inline" >&2; exit 2 ;;
esac
case "$SOURCE_COMMENT_ID" in
  ''|*[!0-9]*) echo "render-feedback-archive: source comment id must be an integer" >&2; exit 2 ;;
esac
[ -n "$SOURCE_LOGIN" ] || { echo "render-feedback-archive: source login is required" >&2; exit 2; }
[ -n "$ARCHIVED_AT" ] || { echo "render-feedback-archive: archived timestamp is required" >&2; exit 2; }
[ -r "$PREVIOUS_BODY_FILE" ] || { echo "render-feedback-archive: previous body is unreadable" >&2; exit 2; }

BODY_JSON=$(jq -Rs '.' "$PREVIOUS_BODY_FILE") \
  || { echo "render-feedback-archive: could not encode previous body" >&2; exit 2; }
BODY=$(jq -r '.' <<EOF
$BODY_JSON
EOF
)

CODEX_TIERS=$(codex_tiers_of "$BODY" | jq -Rsc 'split("\n") | map(select(. != ""))')
VISIBLE=$(coderabbit_finding_scan "$BODY") \
  || { echo "render-feedback-archive: could not scan CodeRabbit body" >&2; exit 2; }
CODERABBIT_TIERS=$(coderabbit_tiers_of "$VISIBLE" | jq -Rsc 'split("\n") | map(select(. != ""))')

# Markerless edits have nothing to preserve. Provider identity is deliberately
# validated later by accounting against the live source comment + base policy;
# this renderer only snapshots the marker vocabulary present in the old body.
if [ "$(printf '%s' "$CODEX_TIERS" | jq 'length')" -eq 0 ] \
   && [ "$(printf '%s' "$CODERABBIT_TIERS" | jq 'length')" -eq 0 ]; then
  exit 0
fi

if command -v sha256sum >/dev/null 2>&1; then
  BODY_FINGERPRINT=$(printf '%s' "$BODY_JSON" | sha256sum | awk '{print substr($1, 1, 12)}')
elif command -v shasum >/dev/null 2>&1; then
  BODY_FINGERPRINT=$(printf '%s' "$BODY_JSON" | shasum -a 256 | awk '{print substr($1, 1, 12)}')
else
  echo "render-feedback-archive: neither sha256sum nor shasum is available" >&2
  exit 2
fi

PAYLOAD=$(jq -nc \
  --arg source_kind "$SOURCE_KIND" \
  --argjson source_comment_id "$SOURCE_COMMENT_ID" \
  --arg source_login "$SOURCE_LOGIN" \
  --arg archived_at "$ARCHIVED_AT" \
  --arg body_fingerprint "$BODY_FINGERPRINT" \
  --argjson codex_tiers "$CODEX_TIERS" \
  --argjson coderabbit_tiers "$CODERABBIT_TIERS" '
    {
      source_kind: $source_kind,
      source_comment_id: $source_comment_id,
      source_login: $source_login,
      archived_at: $archived_at,
      body_fingerprint: $body_fingerprint,
      codex_tiers: $codex_tiers,
      coderabbit_tiers: $coderabbit_tiers
    }
  ')
ENCODED=$(printf '%s' "$PAYLOAD" | jq -Rr '@base64')
printf '<!-- mergepath-feedback-archive:v1 %s -->\n' "$ENCODED"
