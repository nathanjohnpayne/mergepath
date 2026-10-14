#!/usr/bin/env bash
# scripts/repo-lint-latency-issue.sh — route the daily repo-lint latency
# audit verdict to ONE tracked issue (nathanjohnpayne/mergepath#2165).
#
# .github/workflows/repo-lint-latency.yml computes the alert
# (scripts/repo-lint-latency-report.sh exits 1 on a latency or duplicate-
# execution alert) and used to surface it only as a red scheduled run. A red
# cron is not a place anyone looks: the deep-lane regression it was reporting
# ran unanswered from 2026-09-02. This script gives the verdict a destination.
#
#   --rc 1 (alert)   open the tracking issue, or refresh the existing one in
#                    place. Exactly one issue: the lookup is keyed on a hidden
#                    HTML marker in the body, never on the title, so a renamed
#                    issue is still found and a human-written issue with a
#                    similar title is never mistaken for it. The body is
#                    rewritten on every run; a comment is posted only when the
#                    SET OF ALERTS changes, so a daily refresh does not post a
#                    daily comment.
#   --rc 0 (clean)   comment on every open tracking issue that the audit has
#                    recovered, and close it. A later alert opens a fresh issue.
#   any other rc     the audit produced no verdict (collection failed); the
#                    tracking issue is left untouched.
#
# The run still fails on an alert: the workflow's enforce step does that, and
# this script never changes it. Routing is additive.
#
# Usage:
#   scripts/repo-lint-latency-issue.sh --repo owner/repo --rc N --run-url URL
#                                      --summary summary.json [--summary-md summary.md]
#                                      [--labels a,b] [--author LOGIN]
#
#   --author  the login the tracking issue must have been opened by (default
#             github-actions[bot], the identity GITHUB_TOKEN writes as).
#
# Environment: GH_TOKEN with issues:write on the repository (the workflow's
# GITHUB_TOKEN is enough; its writes trigger no workflow runs, which is fine
# for a terminal notification).
#
# Exit codes:
#   0  routed (or nothing to route)
#   1  a required write or the lookup failed — the verdict is in the run log
#      only, and the step fails so that is visible
#   2  usage error

set -euo pipefail

REPO=""; RC=""; RUN_URL=""; SUMMARY=""; SUMMARY_MD=""
LABELS="area:ci-infra,audit"
# Only an issue the workflow identity itself opened is a tracker: the marker
# is public, so a body match alone would let any issue author pick the issue
# this script rewrites and closes.
AUTHOR="github-actions[bot]"
MARKER='<!-- mergepath-repo-lint-latency-audit -->'
ALERTS_PREFIX='<!-- repo-lint-latency-alerts: '
ISSUE_TITLE='Repo-lint latency audit alert'

usage() {
  echo "usage: repo-lint-latency-issue.sh --repo owner/repo --rc N --run-url URL --summary summary.json [--summary-md summary.md] [--labels a,b]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --rc) [ "$#" -ge 2 ] || usage; RC="$2"; shift 2 ;;
    --run-url) [ "$#" -ge 2 ] || usage; RUN_URL="$2"; shift 2 ;;
    --summary) [ "$#" -ge 2 ] || usage; SUMMARY="$2"; shift 2 ;;
    --summary-md) [ "$#" -ge 2 ] || usage; SUMMARY_MD="$2"; shift 2 ;;
    --labels) [ "$#" -ge 2 ] || usage; LABELS="$2"; shift 2 ;;
    --author) [ "$#" -ge 2 ] || usage; AUTHOR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$REPO" ] && [ -n "$RC" ] && [ -n "$RUN_URL" ] && [ -n "$SUMMARY" ] || usage
case "$RC" in ''|*[!0-9]*) usage ;; esac
command -v jq >/dev/null 2>&1 || { echo "repo-lint latency issue: jq is required" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "repo-lint latency issue: gh is required" >&2; exit 2; }

case "$RC" in
  0|1) ;;
  *)
    echo "repo-lint latency issue: audit exited $RC (no verdict) — tracking issue left untouched"
    exit 0
    ;;
esac

today="$(date -u '+%Y-%m-%d')"

# --- lookup: marker-keyed, author-verified, lowest open match wins ---------
# The whole open-issue list is read with --paginate (a `--limit` would
# truncate silently and the tracker could fall off the end). Plain command
# substitution on purpose: a failing list must fail the step, never read as
# "no tracking issue exists" and open a duplicate.
lookup_err="$(mktemp "${TMPDIR:-/tmp}/repo-lint-latency-lookup.XXXXXX")"
if ! open_raw="$(gh api --paginate "repos/$REPO/issues?state=open&per_page=100" 2>"$lookup_err")"; then
  echo "::error::Could not list open issues in $REPO; refusing to route the verdict without a dedupe read: $(tr '\n' ' ' < "$lookup_err")"
  rm -f "$lookup_err"
  exit 1
fi
rm -f "$lookup_err"
if ! open_json="$(printf '%s\n' "$open_raw" | jq -s 'add // [] | [.[] | select(.pull_request == null)]' 2>&1)"; then
  echo "::error::Could not parse the open-issue list: $open_json"
  exit 1
fi
if ! tracked="$(printf '%s' "$open_json" | jq -r --arg m "$MARKER" --arg a "$AUTHOR" \
      '[.[] | select((.user.login // "") == $a) | select((.body // "") | contains($m))] | sort_by(.number) | .[] | .number' 2>&1)"; then
  echo "::error::Could not parse the open-issue list: $tracked"
  exit 1
fi
existing="$(printf '%s\n' "$tracked" | sed -n '1p')"
if [ "$(printf '%s\n' "$tracked" | grep -c .)" -gt 1 ]; then
  echo "::warning::More than one open issue carries the latency-audit marker ($(printf '%s' "$tracked" | tr '\n' ' ')); refreshing the lowest-numbered one."
fi

# --- recovery ---------------------------------------------------------------
if [ "$RC" -eq 0 ]; then
  if [ -z "$tracked" ]; then
    echo "Audit clean and no open tracking issue — nothing to do."
    exit 0
  fi
  status="$(jq -r '.status // "unknown"' "$SUMMARY" 2>/dev/null || echo unknown)"
  rc_all=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "Audit clean — closing tracking issue #${n}."
    recovery_note=":white_check_mark: Repo-lint latency audit recovered as of ${today} (UTC): status \`${status}\`, no alert raised. Closing automatically. See [run](${RUN_URL})."
    if ! gh issue close "$n" --repo "$REPO" --comment "$recovery_note"; then  # NO_BARE_GH_WRITE_EXEMPT: CI reporting surface run under the workflow GITHUB_TOKEN (issues:write), no agent identity to verify — same class as daily-feedback-rollup.sh (#412)
      echo "::error::Could not close tracking issue #${n}."
      rc_all=1
    fi
  done <<< "$tracked"
  exit "$rc_all"
fi

# --- alert ------------------------------------------------------------------
[ -r "$SUMMARY" ] || { echo "::error::summary.json missing at $SUMMARY; cannot describe the alert"; exit 1; }
alerts="$(jq -r '(.alerts // []) | join(",")' "$SUMMARY")"
[ -n "$alerts" ] || alerts="unspecified"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-latency-issue.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
body="$tmpdir/issue-body.md"
{
  echo "$MARKER"
  echo "${ALERTS_PREFIX}${alerts} -->"
  echo
  echo "## Repo-lint latency audit alert"
  echo
  echo "The daily \`repo-lint-latency.yml\` audit raised: **${alerts//,/, }**."
  echo
  echo "- **Last audit:** ${today} (UTC)"
  echo "- **Run:** ${RUN_URL}"
  echo
  echo "### Report"
  echo
  if [ -n "$SUMMARY_MD" ] && [ -r "$SUMMARY_MD" ]; then
    # Demote the report's own H1 so the issue keeps one heading hierarchy.
    sed 's/^# /#### /' "$SUMMARY_MD"
  else
    echo '```json'
    jq '{status, window, thresholds, ordinary_pr, deep_pr, alerts, duplicate_heads}' "$SUMMARY"
    echo '```'
  fi
  echo
  echo "### What to do"
  echo
  echo "- \`ordinary_pr_p50_regression\` / \`ordinary_pr_p95_regression\` / \`deep_pr_p95_regression\`: the \`repo-lint\` critical path grew past the threshold. Read the per-job and per-step timings in the run's artifact (\`repo-lint-latency-<run id>\`), find the step that grew, and either speed it up or move it out of the required critical path per \`specs/repo_lint_execution.md\`."
  echo "- \`same_sha_duplicate_execution\`: one head ran the workflow more than once inside the window; check the triggers in \`.github/workflows/repo_lint.yml\`."
  echo
  echo "---"
  echo
  echo "This issue is **maintained in place** by \`.github/workflows/repo-lint-latency.yml\` through \`scripts/repo-lint-latency-issue.sh\`: each daily run refreshes this body rather than opening a new issue, a comment is posted only when the set of alerts changes, and a clean audit closes it automatically. The run itself still fails while the alert stands."
} > "$body"

# --- labels: ensure, best-effort ---------------------------------------------
# The labels are what a human filters on; the MARKER is what dedupes. A label
# that cannot be ensured therefore degrades the filter, never the dedupe, so
# the issue is still written and the step fails afterwards to say so.
label_args=()
label_degraded=0
# Paginated, so a configured label beyond any fixed page bound is still seen
# (a bounded list would misread it as missing and degrade every run).
if ! label_names="$(gh api --paginate "repos/$REPO/labels?per_page=100" --jq '.[].name' 2>&1)"; then
  echo "::warning::Could not list labels in $REPO: $label_names"
  label_names=""
fi
IFS=',' read -r -a wanted <<< "$LABELS"
for label in "${wanted[@]}"; do
  label="$(printf '%s' "$label" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$label" ] || continue
  if printf '%s\n' "$label_names" | grep -qx -- "$label"; then
    label_args+=(--label "$label")
    continue
  fi
  if gh label create "$label" --repo "$REPO" --color "C5DEF5" --description "Repo-lint latency audit tracking (repo-lint-latency.yml)" >/dev/null 2>&1; then  # NO_BARE_GH_WRITE_EXEMPT: CI reporting surface run under the workflow GITHUB_TOKEN (issues:write), no agent identity to verify — same class as daily-feedback-rollup.sh (#412)
    echo "Created label '$label'."
    label_args+=(--label "$label")
  else
    echo "::warning::Could not ensure label '$label'; the tracking issue is written without it."
    label_degraded=1
  fi
done

if [ -n "$existing" ]; then
  previous_alerts="$(printf '%s' "$open_json" | jq -r --argjson n "$existing" --arg p "$ALERTS_PREFIX" \
    '[.[] | select(.number == $n)][0].body // "" | split("\n") | map(select(startswith($p))) | (.[0] // "") | ltrimstr($p) | rtrimstr(" -->")' 2>/dev/null || true)"
  echo "Refreshing tracking issue #${existing} (alerts: ${alerts}; previously: ${previous_alerts:-unknown})."
  # The transition comment is posted BEFORE the body refresh. If it fails,
  # the refreshed body keeps the PREVIOUS alert set in its marker, so the
  # next run still sees a change and retries the comment instead of losing
  # it; the step then fails to say so.
  comment_failed=0
  if [ "$previous_alerts" != "$alerts" ]; then
    change_note=":warning: Alert set changed as of ${today} (UTC): now **${alerts//,/, }** (was: ${previous_alerts:-unknown}). The issue body is refreshed in the same run — see [latest run](${RUN_URL})."
    if ! gh issue comment "$existing" --repo "$REPO" --body "$change_note"; then  # NO_BARE_GH_WRITE_EXEMPT: CI reporting surface run under the workflow GITHUB_TOKEN (issues:write), no agent identity to verify — same class as daily-feedback-rollup.sh (#412)
      echo "::warning::Could not comment the alert change on #${existing}; keeping the previous alert set in the marker so the next run retries."
      comment_failed=1
      prev_line="${ALERTS_PREFIX}${previous_alerts} -->"
      awk -v p="$ALERTS_PREFIX" -v l="$prev_line" 'index($0, p) == 1 { print l; next } { print }' "$body" > "$body.retry" && mv "$body.retry" "$body"
    fi
  fi
  if ! gh issue edit "$existing" --repo "$REPO" --title "$ISSUE_TITLE" --body-file "$body"; then  # NO_BARE_GH_WRITE_EXEMPT: CI reporting surface run under the workflow GITHUB_TOKEN (issues:write), no agent identity to verify — same class as daily-feedback-rollup.sh (#412)
    echo "::error::Alert WAS raised, but tracking issue #${existing} could not be refreshed. The report is in this run's job summary only: ${RUN_URL}"
    exit 1
  fi
  if [ "${#label_args[@]}" -gt 0 ]; then
    add_labels="$(printf '%s\n' "${label_args[@]}" | grep -v -- '^--label$' | paste -sd, -)"
    gh issue edit "$existing" --repo "$REPO" --add-label "$add_labels" >/dev/null 2>&1 || { echo "::warning::Could not re-apply labels to #${existing}."; label_degraded=1; }  # NO_BARE_GH_WRITE_EXEMPT: CI reporting surface run under the workflow GITHUB_TOKEN (issues:write), no agent identity to verify — same class as daily-feedback-rollup.sh (#412)
  fi
  echo "issue=${existing}"
  if [ "$comment_failed" -eq 1 ]; then
    echo "::error::The alert-set change on #${existing} could not be commented; the next run retries it."
    exit 1
  fi
else
  echo "No open tracking issue — opening one (alerts: ${alerts})."
  if ! created="$(gh issue create --repo "$REPO" --title "$ISSUE_TITLE" ${label_args[@]+"${label_args[@]}"} --body-file "$body" 2>&1)"; then  # NO_BARE_GH_WRITE_EXEMPT: CI reporting surface run under the workflow GITHUB_TOKEN (issues:write), no agent identity to verify — same class as daily-feedback-rollup.sh (#412)
    echo "::error::Alert WAS raised, but no tracking issue could be opened: ${created}. The report is in this run's job summary only: ${RUN_URL}"
    exit 1
  fi
  echo "issue=${created##*/}"
fi

if [ "$label_degraded" -eq 1 ]; then
  echo "::error::A tracking label could not be ensured; the issue exists but is not fully labelled. Create the missing label(s) by hand: ${LABELS}"
  exit 1
fi
exit 0
