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

[ -r "$SCRIPT_DIR/lib/feedback-policy-helpers.sh" ] \
  || { echo "review-feedback-surface-fingerprint: missing feedback-policy-helpers.sh" >&2; exit 2; }
# shellcheck source=lib/feedback-policy-helpers.sh
. "$SCRIPT_DIR/lib/feedback-policy-helpers.sh"

[ -r "$SCRIPT_DIR/lib/gh-api-scalar.sh" ] \
  || { echo "review-feedback-surface-fingerprint: missing gh-api-scalar.sh" >&2; exit 2; }
# shellcheck source=lib/gh-api-scalar.sh
. "$SCRIPT_DIR/lib/gh-api-scalar.sh"

[ -r "$SCRIPT_DIR/lib/ghas-alert-severity.sh" ] \
  || { echo "review-feedback-surface-fingerprint: missing ghas-alert-severity.sh" >&2; exit 2; }
# shellcheck source=lib/ghas-alert-severity.sh
. "$SCRIPT_DIR/lib/ghas-alert-severity.sh"
ghas_severity_cache_init || exit 2
trap 'ghas_severity_cache_cleanup' EXIT
# Extended below (not re-declared) once FINGERPRINT_TMP also exists —
# `trap ... EXIT` overwrites rather than stacks, so a second bare
# assignment there would silently drop this cleanup.

[ "$#" -eq 2 ] || { echo "usage: $0 PR_NUMBER owner/repo" >&2; exit 2; }
PR_NUMBER="$1"
REPO="$2"
case "$PR_NUMBER" in ''|*[!0-9]*) echo "invalid PR number" >&2; exit 2 ;; esac
case "$REPO" in */*) ;; *) echo "invalid repository" >&2; exit 2 ;; esac
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is required" >&2; exit 2; }

# `gh_api_array` reports WHY a read failed through the GH_API_ARRAY_* shell
# variables, so it has to be called DIRECTLY by whatever consumes them — the
# same constraint scripts/coderabbit-wait.sh records on its own wrapper. Read
# in the parent instead, as `VAR=$(gh_api_array …) || { echo "$GH_API_ARRAY_ERROR"; }`
# did until #1089, the assignment runs the function in a command-substitution
# SUBSHELL: the variables are set on the subshell and are gone by the time the
# parent's handler runs. Under `set -u` that handler then died on the unbound
# variable rather than printing anything, so an unreadable surface surfaced as
# an unbound-variable trace and exit 1 -- not the exit 2 the handler intended,
# and never the message naming which surface could not be read.
fetch_api_array() {
  gh_api_array "$1" "$2" || { echo "$GH_API_ARRAY_ERROR" >&2; return 2; }
}

INLINE=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline review comments") || exit 2
REVIEWS=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "review objects") || exit 2
ISSUES=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "PR-level comments") || exit 2

# #1113: a code-scanning alert's severity is a FOURTH mutable input
# accounting reads (via ghas_alert_severity, keyed on the alert number a
# comment body links to) that #1101 introduced without extending this
# fingerprint — a race where the alert's severity changes between
# accounting's two reads within one evaluation window (a newly posted
# alert becomes resolvable, or an existing one's severity is retriaged)
# went undetected. Scanned by BODY PATTERN across every inline comment
# regardless of author, matching render-feedback-archive.sh's own
# author-agnostic classifiers: being MORE inclusive than accounting's
# login-gated membership test only makes the fingerprint more sensitive to
# a real change, never less, which is the safe direction for a
# before/after consistency check. Lazy: zero alert-number links found
# means zero fetches, so a repo without code scanning enabled pays
# nothing extra.
GHAS_ALERT_NUMBERS=$(printf '%s' "$INLINE" | jq -r '.[].body // ""' | while IFS= read -r body; do
  ghas_alert_number_from_body "$body"
done | awk 'NF && !seen[$0]++' | sort -n)
GHAS_SEVERITIES='{}'
while IFS= read -r number; do
  [ -n "$number" ] || continue
  severity=$(ghas_alert_severity "$REPO" "$number") \
    || { echo "review-feedback-surface-fingerprint: could not read code-scanning alert #$number" >&2; exit 2; }
  GHAS_SEVERITIES=$(printf '%s' "$GHAS_SEVERITIES" \
    | jq -c --arg k "$number" --arg v "$severity" '.[$k] = $v')
done <<EOF
$GHAS_ALERT_NUMBERS
EOF

FINGERPRINT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/feedback-surface-fingerprint.XXXXXX")
trap 'ghas_severity_cache_cleanup; rm -rf "$FINGERPRINT_TMP"' EXIT
printf '%s\n' "$INLINE" >"$FINGERPRINT_TMP/inline.json"
printf '%s\n' "$REVIEWS" >"$FINGERPRINT_TMP/reviews.json"
printf '%s\n' "$ISSUES" >"$FINGERPRINT_TMP/issues.json"
printf '%s\n' "$GHAS_SEVERITIES" >"$FINGERPRINT_TMP/ghas.json"

# Keep complete histories out of argv: a long-lived PR can exceed the process
# argument limit even though each individual GitHub response is valid.
CANONICAL=$(jq -Scn \
  --slurpfile inline "$FINGERPRINT_TMP/inline.json" \
  --slurpfile reviews "$FINGERPRINT_TMP/reviews.json" \
  --slurpfile issues "$FINGERPRINT_TMP/issues.json" \
  --slurpfile ghas "$FINGERPRINT_TMP/ghas.json" '
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
      })),
      ghas_alert_severities: $ghas[0]
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
