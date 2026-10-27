#!/usr/bin/env bash
# trusted-consumer-admission.sh — admission for ADR 0004's trusted workflow_run
# consumers (#2727; docs/architecture/0004-trusted-privileged-jobs.md).
#
# A trusted consumer runs on `workflow_run` from the default branch and may
# hold an authority credential, while the producer run that triggered it was a
# candidate-controlled `pull_request` / `pull_request_review` run. GitHub states
# that a workflow_run-triggered workflow "is able to access secrets and write
# tokens, even if the previous workflow was not", and `workflow_run` matches its
# producer by NAME, which any workflow on any branch can borrow. So everything
# the event carries is an untrusted nomination, and this helper decides whether
# the consumer may act at all, before any token exchange or write.
#
# Usage:
#   trusted-consumer-admission.sh admit --producer <file.yml> --events <ev[,ev]>
#       Reads the workflow_run event at $GITHUB_EVENT_PATH. On admission prints
#       one JSON line {"pr":N,"head_sha":"…","base_sha":"…","base_ref":"…"}.
#   trusted-consumer-admission.sh recheck --pr <N> --head <sha40> --base <sha40>
#       The pre-write fence: the live PR still holds exactly that pair, is
#       open, targets the default branch and is a same-repository PR.
#
# admit requires, in order (ADR 0004 § Caller mapping, the workflow_run field
# table, and invariants 5 and 9):
#   1. the event is a completed workflow_run;
#   2. head_repository.id == repository.id == $GITHUB_REPOSITORY_ID (a fork
#      PR's run, or a null head repository, is declined: invariant 9);
#   3. event is one of --events (the producer's own triggers);
#   4. path, after removing one trailing `@<ref>`, is exactly
#      .github/workflows/<producer> (a cross-check only);
#   5. workflow_id equals the id GitHub reports for that file in this
#      repository (the stable identity; a borrowed `name:` fails here);
#   6. head_sha is 40 hex, and exactly one open PR of this repository has that
#      head, nominated by workflow_run.pull_requests or, when GitHub left that
#      empty, by GET commits/{sha}/pulls;
#   7. the live PR is open, its head is head_sha, its base ref is the default
#      branch, and head.repo.id == base.repo.id == $GITHUB_REPOSITORY_ID.
# head_branch, conclusion, display_title and artifacts are never read.
#
# Environment: GITHUB_EVENT_PATH (admit), GITHUB_REPOSITORY, GITHUB_REPOSITORY_ID,
# and GH_TOKEN for gh (the job's GITHUB_TOKEN with actions: read and
# pull-requests: read suffices).
#
# Exit: 0 admitted / pair held; 3 declined, a no-op the caller reports and
# never treats as a failure of the PR (a newer run evaluates a newer head);
# 4 a read needed to decide failed (fail closed: no write); 1 usage.

set -euo pipefail

say() { printf 'trusted-consumer-admission: %s\n' "$*" >&2; }
decline() { say "DECLINED: $*"; exit 3; }
cannot_read() { say "COULD NOT READ: $*; refusing to act"; exit 4; }
usage() { say "usage: $0 admit --producer <file.yml> --events <ev[,ev]> | recheck --pr <N> --head <sha40> --base <sha40>"; exit 1; }

SHA_RE='^[0-9a-f]{40}$'

[ $# -ge 1 ] || usage
MODE="$1"; shift
PRODUCER="" EVENTS="" PR="" WANT_HEAD="" WANT_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --producer|--events|--pr|--head|--base)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      case "$1" in
        --producer) PRODUCER="$2" ;; --events) EVENTS="$2" ;; --pr) PR="$2" ;;
        --head) WANT_HEAD="$2" ;; --base) WANT_BASE="$2" ;;
      esac
      shift 2 ;;
    *) usage ;;
  esac
done

REPO="${GITHUB_REPOSITORY:-}"
REPO_ID="${GITHUB_REPOSITORY_ID:-}"
[[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] || { say "GITHUB_REPOSITORY is unset or malformed"; exit 1; }
[[ "$REPO_ID" =~ ^[1-9][0-9]*$ ]] || { say "GITHUB_REPOSITORY_ID is unset or malformed"; exit 1; }

default_branch() {
  local b
  b=$(gh api "repos/$REPO" --jq .default_branch 2>/dev/null) || cannot_read "the default branch of $REPO"
  [ -n "$b" ] || cannot_read "the default branch of $REPO (empty)"
  printf '%s' "$b"
}

# live_pr <n> → compact JSON with the fields admission and recheck compare.
live_pr() {
  local out
  out=$(gh api "repos/$REPO/pulls/$1" 2>/dev/null) || cannot_read "PR #$1"
  printf '%s' "$out" | jq -c '{state, head_sha: .head.sha, base_sha: .base.sha, base_ref: .base.ref,
    head_repo_id: (.head.repo.id // null), base_repo_id: (.base.repo.id // null)}' 2>/dev/null \
    || cannot_read "PR #$1 (unparseable)"
}

# check_live <live-json> <head> <base-or-empty> <default-branch> → declines on any mismatch.
check_live() {
  local live="$1" head="$2" base="$3" def="$4"
  [ "$(jq -r .state <<<"$live")" = open ] || decline "PR #$PR is not open"
  [ "$(jq -r .base_ref <<<"$live")" = "$def" ] || decline "PR #$PR targets $(jq -r .base_ref <<<"$live"), not the default branch $def"
  [ "$(jq -r '.head_repo_id // "null"' <<<"$live")" = "$REPO_ID" ] \
    && [ "$(jq -r '.base_repo_id // "null"' <<<"$live")" = "$REPO_ID" ] \
    || decline "PR #$PR is not a same-repository PR (invariant 9)"
  [ "$(jq -r .head_sha <<<"$live")" = "$head" ] || decline "PR #$PR head is $(jq -r .head_sha <<<"$live"), not $head"
  if [ -n "$base" ]; then
    [ "$(jq -r .base_sha <<<"$live")" = "$base" ] || decline "PR #$PR base is $(jq -r .base_sha <<<"$live"), not $base"
  fi
  [[ "$(jq -r .base_sha <<<"$live")" =~ $SHA_RE ]] || cannot_read "PR #$PR base SHA (malformed)"
}

case "$MODE" in
  recheck)
    [[ "$PR" =~ ^[1-9][0-9]*$ ]] && [[ "$WANT_HEAD" =~ $SHA_RE ]] && [[ "$WANT_BASE" =~ $SHA_RE ]] || usage
    DEF=$(default_branch)
    # Assign first: a failed read inside an argument's $( ) would not stop set -e.
    LIVE=$(live_pr "$PR")
    check_live "$LIVE" "$WANT_HEAD" "$WANT_BASE" "$DEF"
    say "pair held for PR #$PR at ${WANT_HEAD:0:12}/${WANT_BASE:0:12}"
    exit 0
    ;;
  admit) ;;
  *) usage ;;
esac

[[ "$PRODUCER" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] && [ -n "$EVENTS" ] || usage
EVENT_FILE="${GITHUB_EVENT_PATH:-}"
[ -n "$EVENT_FILE" ] && [ -f "$EVENT_FILE" ] || { say "GITHUB_EVENT_PATH is unset or missing"; exit 1; }
WR=$(jq -c '.workflow_run // empty' "$EVENT_FILE" 2>/dev/null) || cannot_read "the event payload"
[ -n "$WR" ] || decline "not a workflow_run event"

# 1. completed
[ "$(jq -r '.action // ""' "$EVENT_FILE")" = completed ] || decline "workflow_run action is not completed"

# 2. same repository (invariant 9). Null or absent fails.
HEAD_REPO_ID=$(jq -r '.head_repository.id // "null"' <<<"$WR")
RUN_REPO_ID=$(jq -r '.repository.id // "null"' <<<"$WR")
[ "$HEAD_REPO_ID" = "$REPO_ID" ] && [ "$RUN_REPO_ID" = "$REPO_ID" ] \
  || decline "head repository $HEAD_REPO_ID / run repository $RUN_REPO_ID is not this repository ($REPO_ID) (invariant 9)"

# 3. the producer's own triggers
RUN_EVENT=$(jq -r '.event // ""' <<<"$WR")
case ",$EVENTS," in *",$RUN_EVENT,"*) ;; *) decline "producer event '$RUN_EVENT' is not one of $EVENTS" ;; esac

# 4. path cross-check: one trailing @<ref> may be removed, nothing else.
RUN_PATH=$(jq -r '.path // ""' <<<"$WR")
case "$RUN_PATH" in *@*) RUN_PATH="${RUN_PATH%@*}" ;; esac
[ "$RUN_PATH" = ".github/workflows/$PRODUCER" ] || decline "producer path '$RUN_PATH' is not .github/workflows/$PRODUCER"

# 5. workflow_id is the identity.
WANT_WF_ID=$(gh api "repos/$REPO/actions/workflows/$PRODUCER" --jq .id 2>/dev/null) || cannot_read "the workflow id of $PRODUCER"
[[ "$WANT_WF_ID" =~ ^[1-9][0-9]*$ ]] || cannot_read "the workflow id of $PRODUCER (malformed)"
[ "$(jq -r '.workflow_id // ""' <<<"$WR")" = "$WANT_WF_ID" ] \
  || decline "workflow_id $(jq -r '.workflow_id // "null"' <<<"$WR") is not $PRODUCER's ($WANT_WF_ID): a borrowed name"

# 6. the nominated PR: exactly one open same-repository PR with this head.
HEAD_SHA=$(jq -r '.head_sha // ""' <<<"$WR")
[[ "$HEAD_SHA" =~ $SHA_RE ]] || decline "head_sha is not 40 hex"
CANDIDATES=$(jq -c --arg h "$HEAD_SHA" --arg rid "$REPO_ID" '
  [.pull_requests[]? | select(.head.sha == $h and ((.base.repo.id // 0) | tostring) == $rid) | .number] | unique' <<<"$WR")
if [ "$(jq 'length' <<<"$CANDIDATES")" -eq 0 ]; then
  # GitHub leaves pull_requests empty in some cases; resolve from the commit.
  PULLS=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" 2>/dev/null) || cannot_read "the PRs for commit $HEAD_SHA"
  CANDIDATES=$(jq -c --arg h "$HEAD_SHA" --arg rid "$REPO_ID" '
    [.[]? | select(.state == "open" and .head.sha == $h
                   and ((.head.repo.id // 0) | tostring) == $rid
                   and ((.base.repo.id // 0) | tostring) == $rid) | .number] | unique' <<<"$PULLS") \
    || cannot_read "the PRs for commit $HEAD_SHA (unparseable)"
fi
case "$(jq 'length' <<<"$CANDIDATES")" in
  1) PR=$(jq -r '.[0]' <<<"$CANDIDATES") ;;
  0) decline "no open same-repository PR has head $HEAD_SHA" ;;
  *) decline "more than one PR has head $HEAD_SHA ($(jq -c . <<<"$CANDIDATES")); refusing to choose" ;;
esac

# 7. the live PR.
DEF=$(default_branch)
LIVE=$(live_pr "$PR")
check_live "$LIVE" "$HEAD_SHA" "" "$DEF"

jq -cn --argjson pr "$PR" --arg h "$HEAD_SHA" --arg b "$(jq -r .base_sha <<<"$LIVE")" --arg r "$DEF" \
  '{pr: $pr, head_sha: $h, base_sha: $b, base_ref: $r}'
say "ADMITTED: PR #$PR at ${HEAD_SHA:0:12} from a $RUN_EVENT run of $PRODUCER"
