#!/usr/bin/env bash
# Render complete, GitHub-visible history records for an edited/deleted PR-level
# comment, inline comment, or top-level review body. Near-limit bodies are split
# across records that accounting must reconstruct completely. The workflow owns
# the write; this helper is pure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/lib/feedback-policy-helpers.sh"
[ -r "$HELPERS" ] || { echo "render-feedback-archive: missing $HELPERS" >&2; exit 2; }
# shellcheck source=lib/feedback-policy-helpers.sh
. "$HELPERS"

if [ "$#" -ne 5 ]; then
  echo "usage: $0 SOURCE_KIND SOURCE_ID SOURCE_LOGIN ARCHIVED_AT PREVIOUS_BODY_FILE" >&2
  exit 2
fi

SOURCE_KIND="$1"
SOURCE_ID="$2"
SOURCE_LOGIN="$3"
ARCHIVED_AT="$4"
PREVIOUS_BODY_FILE="$5"

case "$SOURCE_KIND" in
  issue-comment|inline|review-body) ;;
  *) echo "render-feedback-archive: source kind must be issue-comment, inline, or review-body" >&2; exit 2 ;;
esac
case "$SOURCE_ID" in
  ''|*[!0-9]*) echo "render-feedback-archive: source id must be an integer" >&2; exit 2 ;;
esac
[ -n "$SOURCE_LOGIN" ] || { echo "render-feedback-archive: source login is required" >&2; exit 2; }
[ -n "$ARCHIVED_AT" ] || { echo "render-feedback-archive: archived timestamp is required" >&2; exit 2; }
[ -r "$PREVIOUS_BODY_FILE" ] || { echo "render-feedback-archive: previous body is unreadable" >&2; exit 2; }

# Archive and relay-terminal comments are themselves part of the immutable
# history surface. If github-actions[bot]'s record is edited or deleted, the
# issue_comment event gives us its previous exact body. Re-emit a single valid
# record byte-for-byte so the workflow can restore it instead of silently
# dropping the only durable copy. Never promote a lookalike from another login
# into a trusted Actions-authored record.
if [ "$SOURCE_LOGIN" = 'github-actions[bot]' ] && awk '
  NR == 1 && $0 ~ /^<!-- mergepath-feedback-archive:v1 [A-Za-z0-9+\/=]+ -->$/ \
    { record=$0; next }
  NR == 1 && $0 ~ /^<!-- mergepath-feedback-archive:v2 id=[0-9a-f]{64} part=[0-9]+\/[0-9]+ data=[A-Za-z0-9+\/=]+ -->$/ \
    { record=$0; next }
  NR == 1 && $0 ~ /^<!-- mergepath-feedback-archive-relay:v1 run=[0-9]+ status=(complete|failed) -->$/ \
    { record=$0; next }
  { extra=1 }
  END { if (record != "" && !extra) print record; else exit 1 }
' "$PREVIOUS_BODY_FILE"; then
  exit 0
fi

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
  --rawfile body "$PREVIOUS_BODY_FILE" \
  --arg source_kind "$SOURCE_KIND" \
  --argjson source_comment_id "$SOURCE_ID" \
  --arg source_login "$SOURCE_LOGIN" \
  --arg archived_at "$ARCHIVED_AT" \
  --arg body_fingerprint "$BODY_FINGERPRINT" \
  --argjson codex_tiers "$CODEX_TIERS" \
  --argjson coderabbit_tiers "$CODERABBIT_TIERS" '
    {
      archive_version: 2,
      source_kind: $source_kind,
      source_comment_id: $source_comment_id,
      source_login: $source_login,
      archived_at: $archived_at,
      body_fingerprint: $body_fingerprint,
      body: $body,
      codex_tiers: $codex_tiers,
      coderabbit_tiers: $coderabbit_tiers
    }
  ')
ENCODED=$(printf '%s' "$PAYLOAD" | jq -Rr '@base64')
if [ "${#ENCODED}" -le 60000 ]; then
  printf '<!-- mergepath-feedback-archive:v1 %s -->\n' "$ENCODED"
  exit 0
fi

# One GitHub comment cannot hold the worst-case JSON/base64 expansion of a
# near-limit reviewer body. Split the encoded payload into independently
# restorable comments; accounting reconstructs the complete set and rejects a
# missing part. The archive id binds every part to this exact payload.
if command -v sha256sum >/dev/null 2>&1; then
  ARCHIVE_ID=$(printf '%s' "$PAYLOAD" | sha256sum | awk '{print $1}')
else
  ARCHIVE_ID=$(printf '%s' "$PAYLOAD" | shasum -a 256 | awk '{print $1}')
fi
CHUNK_SIZE=60000
TOTAL=$(( (${#ENCODED} + CHUNK_SIZE - 1) / CHUNK_SIZE ))
MAX_CHUNKS=32
if [ "$TOTAL" -gt "$MAX_CHUNKS" ]; then
  echo "render-feedback-archive: encoded archive requires $TOTAL chunks; maximum is $MAX_CHUNKS" >&2
  exit 2
fi
PART=1
OFFSET=0
while [ "$OFFSET" -lt "${#ENCODED}" ]; do
  CHUNK=${ENCODED:$OFFSET:$CHUNK_SIZE}
  printf '<!-- mergepath-feedback-archive:v2 id=%s part=%s/%s data=%s -->\n' \
    "$ARCHIVE_ID" "$PART" "$TOTAL" "$CHUNK"
  PART=$((PART + 1))
  OFFSET=$((OFFSET + CHUNK_SIZE))
done
