#!/usr/bin/env bash
# resolve-pr-threads.sh — Enumerate and resolve open review threads on a PR.
#
# Branch protection on `main` typically requires
# `required_conversation_resolution: true`, which means **every review
# thread on the PR must be resolved** before `mergeStateStatus` flips
# from `BLOCKED` to `CLEAN`. This includes CodeRabbit's `🧹 Nitpick` /
# `🔵 Trivial` comments that don't block merge in CodeRabbit's own
# model but DO block the conversation-resolution gate.
#
# The blocker is invisible in `gh pr checks` output — only the GitHub
# UI surfaces it. This script fills the discoverability gap.
#
# Usage:
#   scripts/resolve-pr-threads.sh <PR#> [--repo owner/name] [--list]
#                                 [--auto-resolve-bots | --resolve-actioned
#                                  | --resolve-verified-propagation]
#                                 [--dry-run] [--rationale <text>]
#                                 [--no-tag-reply]
#
# Modes — split by DISPOSITION (#575). Pick the mode that matches what
# actually HAPPENED to the feedback, because each mode records a
# different [mergepath-resolve:<class>] tag, and the daily rollup /
# weekly sweep read that tag as the disposition of record:
#
#   fixed or rebutted        → --resolve-actioned  (addressed-elsewhere /
#                                                    rebuttal-recorded)
#   explicitly deferred      → --auto-resolve-bots (deferred-to-followup)
#   propagated from upstream → --resolve-verified-propagation
#                                                   (verified-propagation)
#
#   --list                  List unresolved threads with author + path +
#                           first-comment excerpt. No mutations.
#   --auto-resolve-bots     THE tool for EXPLICIT DEFERRAL. Resolves
#                           threads whose author is a bot (CodeRabbit,
#                           Codex Connector, Dependabot) AND whose latest
#                           comment is on the current HEAD, for findings
#                           you are deliberately NOT fixing on this PR
#                           because they are tracked elsewhere — the
#                           standard case being canonical-coverage
#                           findings on sync mirrors deferred to a
#                           follow-up issue via --rationale. The tag
#                           defaults to deferred-to-followup: the honest
#                           marker for "not handled here", which the
#                           daily rollup keeps re-surfacing. That default
#                           also applies when the TAG ladder lands on a
#                           ROUTING class (canonical-coverage /
#                           templated-render) for a non-actioned thread
#                           (#616): the rollup SKIPS routing classes, so
#                           recording one here would bury the deliberate
#                           deferral forever. The routing context is
#                           logged (INFO line); the disposition of record
#                           stays deferred-to-followup until the finding
#                           is actioned or
#                           --resolve-verified-propagation proves the
#                           propagation.
#                           Do NOT reach for this mode on findings you
#                           fixed or rebutted — that silently mis-records
#                           them as deferred (the #571 failure that
#                           motivated #575). Guard: when a thread about
#                           to be tagged deferred-to-followup is
#                           demonstrably ACTIONED (the same evidence gate
#                           --resolve-actioned uses derives
#                           addressed-elsewhere / rebuttal-recorded), the
#                           tag is AUTO-UPGRADED to the truthful class
#                           with an INFO line. Auto-upgrade (not
#                           warn-only) is deliberate: the upgrade can
#                           never overclaim — it fires only on the
#                           fail-closed evidence gate — while a warning
#                           would leave the mis-tag in place for every
#                           operator who misses the log line. A thread
#                           that is NOT demonstrably actioned keeps
#                           deferred-to-followup.
#                           Per REVIEW_POLICY.md § Implementation notes
#                           for branch protection gates: this is a
#                           CLEAN-UP mechanism, not a policy override.
#                           Non-bot threads are NEVER handled by this
#                           bot-only mode. Follow REVIEW_POLICY.md's
#                           pre-merge gate for agent-reviewer vs
#                           real-human threads.
#   --resolve-actioned      THE tool for FIXED or REBUTTED feedback — the
#                           default on a PR you pushed fixes to. Like
#                           --auto-resolve-bots (same bot-author,
#                           identity, tag-reply, and readback handling)
#                           but resolves a thread ONLY when its
#                           derived class proves ACTION on this PR:
#                           addressed-elsewhere (an agent commit touching the
#                           anchored file, after the latest re-raise) or
#                           rebuttal-recorded (a substantive agent rebuttal
#                           after the latest re-raise). Routing-only classes
#                           — canonical-coverage / templated-render — are
#                           NOT actioned here: they show WHERE a fix belongs
#                           (upstream), not that one happened, so a fresh
#                           finding on a canonical path must not be resolved
#                           by routing alone (#565). The gate evaluates
#                           action INDEPENDENTLY of routing, so a
#                           canonical/templated thread that DOES carry action
#                           evidence (a fix commit touching it, or a
#                           rebuttal) is still resolved. Routing-only threads,
#                           plus
#                           nitpick-noted / deferred-to-followup and any
#                           class that can't be positively determined, are
#                           LEFT UNRESOLVED so the weekly unresolved-
#                           feedback sweep keeps surfacing them (#564).
#                           The action evidence is checked against the
#                           thread's ENTIRE comment history: threads with
#                           more comments than the enumeration window get
#                           a full paginated re-fetch, and a re-fetch
#                           failure skips the thread (fail closed) so a
#                           hidden re-raise can never be resolved over
#                           (#573 item 2). Use
#                           this to mark genuinely-handled feedback resolved
#                           without the blunt "resolve everything" of
#                           --auto-resolve-bots. To merge past a deferral on
#                           a conversation-resolution-gated repo, fix/rebut
#                           it (making it actioned) or defer it explicitly
#                           via --auto-resolve-bots --rationale.
#   --resolve-verified-propagation
#                           THE tool for the routing-class residual on
#                           CONSUMER sync PRs (#572): canonical-coverage /
#                           templated-render threads whose content has
#                           PROVABLY propagated. Routing alone (path
#                           membership in .mergepath-sync.yml) never counts
#                           as actioned — it says WHERE a fix belongs, not
#                           that one happened (#565) — but when the
#                           consumer's CURRENT content byte-matches the
#                           canonical/rendered source, the upstream state
#                           has provably propagated and the thread is
#                           handled. Routing is decided by the PATH ALONE
#                           (derive_routing_class): a previously recorded
#                           [mergepath-resolve: deferred-to-followup] (or
#                           other) marker from an earlier deferral pass
#                           never masks the manifest check — resolving
#                           exactly those previously-deferred threads once
#                           propagation lands is this mode's main use case
#                           (#616). A routed thread with demonstrable
#                           ACTION evidence (the --resolve-actioned gate:
#                           an agent fix commit touching the anchored file
#                           after the latest re-raise, or a substantive
#                           rebuttal) is resolved under its truthful
#                           addressed-elsewhere / rebuttal-recorded tag
#                           instead, with an INFO line (mirrors the #575
#                           auto-upgrade); the byte-compare is skipped for
#                           these since the action evidence is the
#                           resolution evidence. The COMPARED REF is
#                           state-dependent (#616 finding 3510170875): while
#                           the target PR is OPEN (the pre-merge
#                           conversation gate) the compare reads the PR's
#                           own HEAD sha — the PR being merged may itself
#                           change the same canonical/templated destination,
#                           so a default-branch byte-match must not resolve
#                           a thread whose candidate content still carries
#                           drift; once the PR is closed/merged the compare
#                           reads the default branch PINNED to its tip
#                           commit SHA — resolved once and reused by BOTH
#                           the contents and git-trees reads, so the two
#                           can never see different commits if the branch
#                           advances between them (#616 finding
#                           3510442271; the #562 backlog case). An
#                           unresolvable PR state, tip-SHA resolution
#                           failure, or compared-ref content fetch failure
#                           skips fail-closed.
#                           Per non-actioned thread anchored at path P:
#                           - P matches a canonical/kit entry in mergepath's
#                             .mergepath-sync.yml → byte-compare the
#                             consumer's content at P (gh contents API at
#                             the compared ref) against mergepath's
#                             canonical source file.
#                           - P matches a templated entry's dest for this
#                             consumer → re-render the source template with
#                             the consumer's facts (the SAME render engine
#                             scripts/workflow/verify-propagation-pr.sh
#                             uses: scripts/lib/template-substitution.sh +
#                             scripts/lib/manifest-fact-helpers.sh) and
#                             byte-compare against the consumer's content
#                             at the compared ref.
#                           Both arms read the mergepath source at the
#                           COMMITTED HEAD (git show HEAD:path), never the
#                           working tree (#616 finding 3510442268):
#                           uncommitted local edits never count as
#                           propagation sources — only committed content
#                           can have propagated, and the tree-entry +
#                           upstream-evidence gates below already read
#                           HEAD, so all three checks see one committed
#                           state. The templated arm's render INPUTS —
#                           consumer facts, consumer-name lookup, and the
#                           dest→source templated-entry mapping — read a
#                           committed .mergepath-sync.yml snapshot too
#                           (#616 finding 3510689518): a dirty manifest's
#                           uncommitted fact edits must never produce a
#                           rendered match (or mask a genuine committed
#                           one).
#                           A byte-match alone is NECESSARY, NOT SUFFICIENT
#                           (#616 findings 3510170883 + 3510170879). Two
#                           further gates run before any resolve:
#                           - TREE-ENTRY PARITY: the consumer tree entry at
#                             the compared ref must be a regular blob whose
#                             mode matches the mergepath source's committed
#                             mode (100644/100755) — the same mode/type
#                             check verify-propagation-pr.sh applies, so a
#                             chmod flip or symlink swap with identical raw
#                             bytes never verifies as faithful propagation.
#                             Mismatch skips as drift; a tree lookup
#                             failure (or a truncated tree listing) skips
#                             fail-closed.
#                           - UPSTREAM-FIX EVIDENCE: the local mergepath
#                             checkout (REPO_ROOT_FOR_MANIFEST, a git work
#                             tree) must carry a commit touching the
#                             mergepath source STRICTLY NEWER than the
#                             finding's staleness floor
#                             (latest_nonagent_created — the latest bot/
#                             reviewer re-raise). A byte-match only proves
#                             the consumer mirrors the CURRENT source; if
#                             the follow-up was never applied upstream, the
#                             consumer mirrors a still-problematic file and
#                             resolving would bury the deferred finding.
#                             DELIBERATE BIAS: an upstream fix that
#                             PRE-dates the finding (or an uncommitted
#                             working-tree fix, or a non-git checkout) also
#                             skips — conservative; the thread stays
#                             deferred and resurfaces, and the operator can
#                             resolve manually with evidence.
#                           All gates pass → resolve (same identity-checked
#                           resolveReviewThread + isResolved:true readback
#                           as the other modes) tagged
#                           [mergepath-resolve: verified-propagation].
#                           NO byte-match (drifted, or the upstream fix has
#                           not propagated yet) → LEAVE the thread
#                           unresolved with a per-thread reason. FAIL
#                           CLOSED — skip with reason, never resolve — on:
#                           manifest entry missing, consumer content fetch
#                           failure, render failure, facts/consumer-name
#                           missing, yq missing, unresolvable PR state,
#                           tree-entry lookup failure, missing upstream-fix
#                           evidence, or a pagination-incomplete
#                           comment list (#573/#614). Surface-class threads
#                           (nitpick-noted etc.) and non-bot authors are
#                           never touched. The PR-HEAD staleness proxy is
#                           bypassed (like --resolve-actioned): the
#                           verification evidence is the consumer's content
#                           at the compared ref (not the bot comment's
#                           anchor commit), and the primary target
#                           population is backlog threads on merged sync
#                           PRs (#562).
#                           Run from a mergepath checkout with
#                           --repo <owner/consumer-repo>; on a checkout
#                           without .mergepath-sync.yml every thread skips
#                           fail-closed.
#   --dry-run               With any resolve mode, print what would
#                           be resolved or skipped without mutating.
#   --rationale <text>      With --auto-resolve-bots, override the
#                           auto-synthesized class with a free-form
#                           rationale. Class defaults to
#                           `deferred-to-followup` (most common manual
#                           case); the free-form text follows the tag.
#                           Useful when the auto-heuristic would
#                           misclassify (e.g. P2 deferred to a tracked
#                           follow-up issue). Implies tag-reply emission.
#                           The #575 guard still applies to the CLASS: a
#                           demonstrably-actioned thread is upgraded to
#                           addressed-elsewhere / rebuttal-recorded while
#                           keeping the operator's rationale text — the
#                           override records WHY, never falsifies WHAT.
#   --no-tag-reply          With --auto-resolve-bots, suppress the
#                           pre-resolution `[mergepath-resolve:<class>]`
#                           reply emission. The resolve mutation still
#                           runs. Useful for dry-rehearsal of the
#                           resolve loop without polluting the thread
#                           history. The default IS to emit the tag —
#                           the v1 daily rollup classifier reads it.
#
# Default mode (no flags): equivalent to --list.
#
# Tag emission (mergepath#305):
#   When --auto-resolve-bots runs WITHOUT --no-tag-reply, the helper
#   posts a one-line reply on each bot thread BEFORE the resolve
#   mutation:
#
#     [mergepath-resolve: <class>] <one-line rationale>
#
#   where `<class>` is one of (taxonomy mirrored from the v1 daily
#   rollup classifier in scripts/lib/daily-feedback-rollup-helpers.sh):
#     addressed-elsewhere   fix-commit by an agent author after the
#                           comment's createdAt, touching the anchored
#                           file (or any file when per-file detection
#                           is unavailable)
#     canonical-coverage    path matches a canonical entry in
#                           .mergepath-sync.yml (propagated content)
#     nitpick-noted         severity is Nitpick/Trivial/P3 and no
#                           stronger signal applies
#     rebuttal-recorded     a substantive agent-authored reply (≥30
#                           chars) is on the thread
#     deferred-to-followup  default fallback / --rationale override
#     verified-propagation  consumer content at the anchored path (at the
#                           compared ref: PR head while open, default
#                           branch once closed/merged) byte-matches
#                           mergepath's canonical source (or the
#                           re-rendered template with the consumer's
#                           facts) at resolution time, with tree-entry
#                           mode/type parity and upstream-fix evidence
#                           (#616) — emitted only by
#                           --resolve-verified-propagation (#572)
#
#   Tag emission failure is logged + skipped (does NOT block the
#   resolve mutation). The rollup's classifier accepts any string
#   matching the regex; unknown classes route to "surface" per spec.
#
# Exit codes:
#   0 — no unresolved threads
#   1 — bad arguments
#   2 — gh failure (auth, missing PR, network), a resolve mutation that did
#       not return isResolved:true, OR a post-resolve readback that could
#       not confirm isResolved:true (#564 — fail closed). After every
#       --auto-resolve-bots run, the helper re-reads each thread it
#       resolved via a `nodes(ids:)` readback and refuses to report success
#       unless GitHub confirms isResolved:true for all of them.
#   3 — unresolved threads exist (in --list mode), or a resolve mode left
#       threads unresolved (human-authored, stale-HEAD, not-actioned,
#       comments-incomplete, not-propagation-routed, drifted,
#       verification-failed, or byte-matched without upstream-fix
#       evidence). Address the findings and retry with the
#       mode that matches the disposition, or resolve human-authored
#       threads via the GitHub UI.
#
# References:
#   nathanjohnpayne/mergepath#166 — the issue this closes
#   matchline #181, #190, #192 — observed cases of conversation-
#                                resolution blocker

set -euo pipefail
# `-u` added (#536): optionals are already defaulted (MODE/DRY_RUN/
# RATIONALE_OVERRIDE/etc. at module top, env vars via `${VAR:-}` and the
# `:=` default for MERGEPATH_AGENT_AUTHORS), and the arg parser guards
# `$2` behind a `$# -lt 2` short-circuit, so strict unset-variable
# handling surfaces genuine typos without breaking documented paths.

# --- preflight auto-source (#282) ------------------------------------------
# If OP_PREFLIGHT_REVIEWER_PAT is unset and a fresh op-preflight cache
# exists for this agent, source it. The existing PAT_GH_TOKEN logic
# below already prefers OP_PREFLIGHT_REVIEWER_PAT over GH_TOKEN, so this
# block needs only to populate the env var. Silent on no-op paths.
__RESOLVE_THREADS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ] && [ -r "$__RESOLVE_THREADS_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__RESOLVE_THREADS_DIR/lib/preflight-helpers.sh"
  auto_source_preflight
fi
if [ -r "$__RESOLVE_THREADS_DIR/lib/gh-token-resolver.sh" ]; then
  # shellcheck source=lib/gh-token-resolver.sh
  . "$__RESOLVE_THREADS_DIR/lib/gh-token-resolver.sh"
fi

usage() {
  cat <<'EOF' >&2
Usage: scripts/resolve-pr-threads.sh <PR#> [--repo owner/name] [--list]
                                            [--auto-resolve-bots | --resolve-actioned
                                             | --resolve-verified-propagation]
                                            [--dry-run] [--rationale <text>] [--no-tag-reply]

Resolve modes are split by DISPOSITION (#575) — pick the one that matches
what actually happened to the feedback (the recorded tag is read by the
daily rollup / weekly sweep as the disposition of record):

  --list                List unresolved threads (default).
  --resolve-actioned    FIXED/REBUTTED feedback — the default on a PR you
                        pushed fixes to. Resolves ONLY current-HEAD bot
                        threads whose fix or rebuttal is demonstrable
                        (tags the truthful addressed-elsewhere /
                        rebuttal-recorded classes); leaves the rest
                        unresolved so the weekly sweep keeps surfacing them.
  --auto-resolve-bots   EXPLICIT DEFERRAL — resolve ALL current-HEAD
                        bot-authored threads you are deliberately not
                        fixing here (clears the conversation-resolution
                        gate; tags deferred-to-followup and the daily
                        rollup re-surfaces them). A demonstrably-actioned
                        thread is auto-upgraded to its truthful class
                        with an INFO line (#575).
  --resolve-verified-propagation
                        VERIFIED PROPAGATION on a consumer repo (#572) —
                        resolve canonical/templated routing threads whose
                        anchored content byte-matches mergepath's
                        canonical source (or the re-rendered template
                        with the consumer's facts) at the compared ref
                        (the PR head while the PR is open, the default
                        branch pinned to its tip SHA once closed/merged).
                        The mergepath source is read at the COMMITTED
                        HEAD — uncommitted working-tree edits never count
                        as propagation sources (#616). Requires a matching
                        tree-entry mode/type and an upstream fix commit
                        newer than the finding (#616); tags
                        verified-propagation. Drift or ANY verification
                        failure skips fail-closed. Routing ignores
                        previously recorded deferral markers (#616), and a
                        demonstrably-actioned thread is tagged with its
                        truthful actioned class instead (#575 upgrade).
  --dry-run             With any resolve mode, print would-resolve /
                        would-skip per thread without mutating.
  --rationale <text>    With --auto-resolve-bots, free-form rationale
                        appended after the [mergepath-resolve: deferred-to-followup]
                        tag (overrides auto-classification; the #575
                        actioned auto-upgrade still applies to the class).
  --no-tag-reply        With any resolve mode, suppress the
                        [mergepath-resolve:<class>] reply emission
                        (the resolve mutation still runs).
EOF
  exit 1
}

PR_NUM=""
REPO=""
MODE="list"
DRY_RUN=false
RATIONALE_OVERRIDE=""
RATIONALE_FLAG_USED=false
NO_TAG_REPLY=false
# Match both REST and GraphQL bot-login formats. The REST API returns
# `coderabbitai[bot]`; GraphQL `author{login}` returns `coderabbitai`
# (un-suffixed user-facing handle). The trailing `(\[bot\])?` accepts
# either form so the auto-resolve mode works with the GraphQL data
# this script reads. Caught on PR #180 review when every CR thread
# was skipped as a non-bot author — see #182.
BOT_LOGINS_RE='^(coderabbitai|chatgpt-codex-connector|dependabot)(\[bot\])?$'

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      # Codex r2 on PR #172: bare `shift 2` silently consumed nothing
      # when --repo was the last arg, leaving REPO empty and falling
      # through to gh-repo-view auto-detect. Validate the value is
      # present and non-empty so the user gets a clear error instead.
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --repo requires a non-empty value (owner/name)" >&2
        usage
      fi
      REPO="$2"; shift 2 ;;
    --list) MODE="list"; shift ;;
    --auto-resolve-bots) MODE="auto-resolve-bots"; shift ;;
    --resolve-actioned) MODE="resolve-actioned"; shift ;;
    --resolve-verified-propagation) MODE="resolve-verified-propagation"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --rationale)
      # Same defensive value check as --repo (Codex r2 on PR #172):
      # require an explicit non-empty argument so a trailing
      # `--rationale` doesn't silently produce an empty tag body.
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --rationale requires a non-empty value" >&2
        usage
      fi
      RATIONALE_OVERRIDE="$2"
      RATIONALE_FLAG_USED=true
      shift 2 ;;
    --no-tag-reply) NO_TAG_REPLY=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$PR_NUM" ]; then PR_NUM="$1"
      else echo "Unexpected positional: $1" >&2; usage
      fi
      shift
      ;;
  esac
done

[ -z "$PR_NUM" ] && usage

# PR_NUM must be a positive integer (no leading zeros, no other chars).
if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid PR number: '$PR_NUM' (must be a positive integer)" >&2
  exit 1
fi

# #565: --rationale is an --auto-resolve-bots affordance (override the class
# for a deliberate deferred resolve). It is incompatible with
# --resolve-actioned, whose whole contract is to resolve ONLY on derived
# action evidence — a free-form rationale override would resolve a thread
# while mis-tagging it deferred-to-followup, so the daily rollup would treat
# an actioned, resolved thread as deferred/unhandled. Reject the combo.
# #572: the same logic applies to --resolve-verified-propagation, whose
# contract is to resolve ONLY on byte-verified propagation evidence and whose
# rationale IS the verification result — an override would replace the
# evidence record.
if { [ "$MODE" = "resolve-actioned" ] || [ "$MODE" = "resolve-verified-propagation" ]; } \
   && $RATIONALE_FLAG_USED; then
  echo "Error: --rationale is not valid with --resolve-actioned or" >&2
  echo "       --resolve-verified-propagation (it applies only to" >&2
  echo "       --auto-resolve-bots). Those modes resolve on derived evidence" >&2
  echo "       (action / byte-verified propagation); use" >&2
  echo "       --auto-resolve-bots --rationale to deliberately resolve a" >&2
  echo "       deferred thread with a rationale." >&2
  exit 1
fi

# Resolve the reviewer PAT once + define the wrapper before any `gh`
# call. CR Major on PR #194 r4 caught that the bare `gh repo view`
# and `gh api` invocations below this point would still hit the
# empty-GH_TOKEN keyring-fallback trap. Centralizing the wrapper
# above all gh calls fixes it.
#
# `gh_pat` (renamed from `gh_read` — CodeRabbit Major #271/#272) is
# used for BOTH the read-path calls AND the resolveReviewThread
# WRITE mutation. The mutation previously used a bare `gh api
# graphql`: in a CI context where only OP_PREFLIGHT_REVIEWER_PAT is
# populated (no ambient GH_TOKEN), that bare call would fall back to
# the keyring — wrong identity, or an outright failure — after every
# read had passed. Pinning the same PAT on the mutation keeps reads
# and the write consistent. The name is now token-centric, not
# read-centric, to reflect that.
PAT_GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${GH_TOKEN:-}}"
gh_pat() {
  if [ -n "$PAT_GH_TOKEN" ]; then
    GH_TOKEN="$PAT_GH_TOKEN" gh "$@"
  else
    gh "$@"
  fi
}

if [ -z "$REPO" ]; then
  REPO=$(gh_pat repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Could not resolve repo. Pass --repo owner/name." >&2
    exit 2
  }
fi

# --repo value validation. Codex r1 on PR #172 caught the missing
# check. Must be `owner/name` where each side is GitHub-legal:
# alphanumerics, hyphens, dots, underscores; no leading dash; ≤39
# chars per GitHub's username rules but we only enforce the syntactic
# shape — gh will reject genuinely-invalid combinations downstream.
if ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid --repo value: '$REPO' (expected owner/name)" >&2
  exit 1
fi

OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# Per-commit file-list cache for the addressed-elsewhere check (#565). Keyed
# by commit SHA, stored on disk so the cache survives the command-substitution
# subshells that derive_tag_class / synth_rationale run in (a shell-var cache
# would be lost when those subshells exit). Removed on exit.
COMMIT_FILES_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resolve-pr-commitfiles.XXXXXX")"
trap 'rm -rf "$COMMIT_FILES_CACHE_DIR"' EXIT

# Fetch the PR's current HEAD commit oid — used by --auto-resolve-bots
# to verify each thread's latest comment is on the current HEAD before
# resolving. Codex P2 on PR #172 caught that the docstring promised
# this check but the code didn't enforce it.
HEAD_OID=$(gh_pat api "repos/$OWNER/$NAME/pulls/$PR_NUM" --jq .head.sha 2>/dev/null) || {
  echo "Could not resolve PR HEAD oid for $REPO#$PR_NUM" >&2
  exit 2
}

# Fetch all review threads with isResolved state. Three design
# choices, all load-bearing:
#
# 1. `-F cursor=null` (typed) on the first call, NOT `-f cursor=null`
#    (string). The prior code used `-f cursor=null` which sent the
#    literal STRING "null" as the cursor; GitHub's GraphQL endpoint
#    interpreted that as a real cursor and silently returned the
#    wrong thread set. This was the actual root cause of the
#    PR #189 undercount (May 2026 — initially misdiagnosed as
#    eventual consistency; #192 has the post-mortem). The cursor-
#    state branching below sends GraphQL null on the first call,
#    then a real cursor string on subsequent pages.
#
# 2. Two GraphQL aliases — `commentsFirst: comments(first: 1)` for
#    the original review's author/path/body (what the user/agent
#    needs to recognize the thread) AND `commentsLast: comments(last:
#    1)` for the HEAD-anchor commit_oid (the truly-latest comment).
#    Earlier draft used `comments(first: 50)` and indexed `[-1]` for
#    the last comment, but Codex P2 on PR #194 caught that >50-comment
#    threads (rare but possible — bot churn over a long-lived PR)
#    would misclassify HEAD anchor. The dual-alias shape is
#    deterministic for any thread depth.
#
# 3. `totalCount` cross-validation — after assembling THREADS_JSON,
#    compare the returned node count against the API's reported
#    totalCount. If they disagree the script reports on stderr +
#    exits 2 rather than the silent "no unresolved threads" output
#    that bit PR #189. Belt-and-suspenders: even with the cursor fix
#    above, a future API quirk could re-introduce undercount; the
#    cross-check catches it.
#
# Codex P2 on PR #172 caught that the prior `first: 100` (no pager)
# could undercount on PRs with many threads — paginating with
# `first: 50` + cursor preserves that fix.
THREADS_JSON='[]'
TOTAL_COUNT=0
# CURSOR sentinel "" means "first call — send GraphQL null". A string
# value "null" is NOT the same: passing it via `-f cursor=null` sends
# the literal string "null" which GitHub interprets as a real cursor
# and silently returns the wrong thread set. Always use `-F` (typed)
# for null on first call; switch to `-f` (string) once we have a real
# cursor. This was the actual root cause of the PR #189 undercount —
# not eventual consistency.
CURSOR=""
QUERY='
  query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 50, after: $cursor) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            # `commentsFirst` for the original review (excerpt + author).
            # `commentsLast` for the HEAD-anchor commit_oid — `last: 1`
            # guarantees the truly-latest comment regardless of thread
            # depth. Codex P2 on PR #194 caught that `first: 50` would
            # misclassify HEAD anchor on threads with >50 comments
            # (rare but possible — bot churn).
            commentsFirst: comments(first: 1) {
              nodes {
                author { login }
                path
                body
                createdAt
              }
            }
            commentsLast: comments(last: 1) {
              nodes {
                commit { oid }
              }
            }
            # `allComments` powers the rationale-tag class derivation
            # (mergepath#305): scan agent-authored replies for an
            # existing `[mergepath-resolve:...]` tag (skip re-emission)
            # and substantive rebuttal detection (≥30 chars from an
            # agent author → `rebuttal-recorded`).
            #
            # `last: 50` (not first: 50) — the staleness checks (#565) need
            # the MOST RECENT comments: latest_nonagent_created and the
            # last-word marker/rebuttal logic must see a bot re-raise even on
            # a long thread. `first: 50` truncated the newest comments, so a
            # re-raise past comment 50 was invisible and an older fix/rebuttal
            # looked like the latest word — resolving live feedback (Codex P2
            # on #565).
            #
            # #573 item 2: the newest-50 window is NOT always fail-safe on
            # its own. When the latest bot/reviewer re-raise is followed by
            # 50+ agent replies (ack/marker churn on a long-lived thread),
            # the re-raise itself falls OUT of the window, so
            # latest_nonagent_created understates the staleness floor and a
            # STALE fix/rebuttal looks like the latest word — resolving live
            # feedback. totalCount + hasPreviousPage detect that truncation;
            # truncated threads get a full cursor-paginated re-fetch
            # (complete_thread_comments) before any staleness-sensitive
            # classification, and a re-fetch failure fails closed (the
            # thread is skipped, never resolved on incomplete data).
            allComments: comments(last: 50) {
              totalCount
              pageInfo { hasPreviousPage }
              nodes {
                author { login }
                body
                databaseId
                # createdAt powers the addressed-elsewhere staleness guard
                # (#565): a fix commit must post-date the LATEST bot/reviewer
                # comment, not just the original finding, to count as actioning.
                createdAt
              }
            }
          }
        }
      }
    }
  }
'
while :; do
  # Read-path: pin to preflight reviewer PAT when available; otherwise
  # let gh use its keyring fallback (no empty-GH_TOKEN trap).
  if [ -z "$CURSOR" ]; then
    PAGE=$(gh_pat api graphql -f query="$QUERY" \
      -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_NUM" -F cursor=null 2>&1) || {
      echo "GraphQL query failed: $PAGE" >&2
      exit 2
    }
  else
    PAGE=$(gh_pat api graphql -f query="$QUERY" \
      -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_NUM" -f cursor="$CURSOR" 2>&1) || {
      echo "GraphQL query failed: $PAGE" >&2
      exit 2
    }
  fi
  THREADS_JSON=$(jq -c --argjson acc "$THREADS_JSON" \
    '$acc + .data.repository.pullRequest.reviewThreads.nodes' <<<"$PAGE")
  TOTAL_COUNT=$(jq -r '.data.repository.pullRequest.reviewThreads.totalCount' <<<"$PAGE")
  HAS_NEXT=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$PAGE")
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$PAGE")
done

# totalCount cross-validation — fail on ANY mismatch (under OR over).
# Equality check, not `< totalCount`: an over-count would indicate a
# duplicate-page / cursor-reset regression in the pagination loop and
# is just as bad as an undercount. CR Major on PR #194 r2.
RETURNED_COUNT=$(jq -r 'length' <<<"$THREADS_JSON")
if [ "$RETURNED_COUNT" != "$TOTAL_COUNT" ]; then
  cat >&2 <<EOF
ERROR: GraphQL count mismatch on $REPO#$PR_NUM.
       reviewThreads.totalCount = $TOTAL_COUNT, but the paginated query
       returned $RETURNED_COUNT nodes. Either undercount (cursor-typing
       bug per #192) or overcount (duplicate-page / cursor-reset
       regression). Do NOT trust the "no unresolved threads" output
       below; fall back to the manual GraphQL escape hatch in
       CLAUDE.md § 7.6.
EOF
  exit 2
fi

UNRESOLVED=$(echo "$THREADS_JSON" | jq -c '
  .[]
  # `!= true` instead of `== false` so a null/missing isResolved
  # field is treated as unresolved (defensive — prefer to surface
  # noise over silently skip).
  | select(.isResolved != true)
  | {
      id: .id,
      outdated: .isOutdated,
      # commentsFirst = original review (excerpt + author for display).
      # commentsLast = guaranteed-latest comment (HEAD anchor commit_oid).
      # allComments = full reply chain for tag-emission heuristics
      #   (mergepath#305): existing-tag detection + rebuttal scan.
      author: (.commentsFirst.nodes[0].author.login // "unknown"),
      path: (.commentsFirst.nodes[0].path // "(no path)"),
      created: (.commentsFirst.nodes[0].createdAt // ""),
      commit_oid: (.commentsLast.nodes[0].commit.oid // ""),
      body: (.commentsFirst.nodes[0].body // ""),
      excerpt: ((.commentsFirst.nodes[0].body // "") | .[0:160]),
      all_comments: (.allComments.nodes // []),
      # all_comments_truncated (#573 item 2): true when the last-50 window
      # provably misses older comments — either the connection reports a
      # previous page, or its totalCount exceeds the nodes returned. A
      # truncated thread MUST have its full comment list re-fetched
      # (complete_thread_comments) before latest_nonagent_created is
      # trusted; missing pageInfo/totalCount (older stubs/fixtures) reads
      # as not-truncated, preserving the pre-#573 shape.
      all_comments_truncated: (
        ((.allComments.pageInfo.hasPreviousPage // false) == true)
        or ((.allComments.totalCount // 0) > ((.allComments.nodes // []) | length))
      )
    }
')

if [ -z "$UNRESOLVED" ]; then
  echo "No unresolved threads on PR #$PR_NUM."
  exit 0
fi

UNRESOLVED_COUNT=$(echo "$UNRESOLVED" | wc -l | tr -d ' ')
echo "Unresolved threads on $REPO#$PR_NUM: $UNRESOLVED_COUNT"
echo ""

# List mode: print and exit 3.
if [ "$MODE" = "list" ]; then
  echo "$UNRESOLVED" | jq -r '
    "  [\(.author)] \(.path)" + (if .outdated then " (outdated)" else "" end) +
    "\n    " + .excerpt + "\n"
  '
  echo "To resolve bot-authored threads where you have already addressed"
  echo "the finding: re-run with --auto-resolve-bots."
  echo "Non-bot threads are not handled by --auto-resolve-bots. Follow"
  echo "REVIEW_POLICY.md's pre-merge gate for agent-reviewer vs real-human"
  echo "threads."
  exit 3
fi

# Identity check (#284 r2 / #412): the resolveReviewThread mutation is
# a GraphQL write, and its byline follows the PAT in GH_TOKEN. Verify
# that PAT resolves to the expected reviewer identity BEFORE entering
# the per-thread mutation loop.
# Opt-out via RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1.
#
# nathanpayne-codex Phase 4b r1 on PR #293 caught the prior shape's
# hole: the check used to fire inside the loop with an
# IDENTITY_CHECK_FIRED once-only guard. On FAILED, that guard still
# evaluated to "fired" on subsequent iterations, so the loop's
# `IDENTITY_CHECK_FIRED != 1` predicate falsely short-circuited the
# re-check and the mutation ran without identity verification on
# every thread AFTER the first failure. Lifting the check out of
# the loop entirely makes it a single up-front gate.
#
# r3 (#284): fail CLOSED if the helper is missing or non-executable.
# The previous shape bundled `[ -x "$CHECKER" ]` into the same AND
# chain as the opt-out — so if the helper got renamed, deleted, or
# lost its +x bit, the entire identity-check block was silently
# SKIPPED and the mutation ran without verification. nathanpayne-codex
# Phase 4b r2 reproduced this. The fix: the helper-presence test
# becomes a hard error inside the opt-out branch rather than a
# precondition for entering it.
if [ "${RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK:-0}" != "1" ] && ! $DRY_RUN; then
  CHECKER="$(dirname "${BASH_SOURCE[0]}")/identity-check.sh"
  if [ ! -x "$CHECKER" ]; then
    echo "ERROR: identity-check helper missing or non-executable: $CHECKER" >&2
    echo "       Refusing to mutate without identity verification." >&2
    echo "       Restore the helper, or opt out via" >&2
    echo "       RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 (dev only)." >&2
    exit 2
  fi
  if command -v gh_default_reviewer_identity >/dev/null 2>&1; then
    expected_login="$(gh_default_reviewer_identity)"
  else
    expected_login="nathanpayne-${MERGEPATH_AGENT:-claude}"
  fi
  if ! GH_TOKEN="$PAT_GH_TOKEN" "$CHECKER" \
       --expect-token-identity "$expected_login"; then
    echo "ERROR: identity-check failed before any mutation. Refusing to" >&2
    echo "       resolve threads. Confirm GH_TOKEN / OP_PREFLIGHT_REVIEWER_PAT" >&2
    echo "       resolves to $expected_login, then re-run." >&2
    echo "       Opt-out (dev only): RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------
# mergepath#305 — agent-side `[mergepath-resolve:<class>]` tag emission
# ---------------------------------------------------------------------
#
# Before each resolveReviewThread mutation, post a one-line reply on
# the thread with `[mergepath-resolve: <class>] <rationale>`. The
# v1 daily rollup classifier in
# scripts/lib/daily-feedback-rollup-helpers.sh reads this tag and
# prioritizes it over its own heuristics. The taxonomy (the five
# valid `<class>` values) MUST match what the classifier accepts —
# unknown class strings route to "surface" per the rollup spec,
# which is acceptable but defeats the purpose.
#
# We intentionally do NOT source the rollup helpers file: it is not
# in .mergepath-sync.yml, and sourcing it would either break
# propagation OR force the helpers to travel with the canonical
# resolve script. Instead we inline the small bits we need here
# (regex shape, agent-author check, severity sniff). The
# canonical taxonomy lives in the helpers file's case-statement
# comments — this script must stay in step.

# is_agent_author_local <login> → exit 0 if agent, 1 otherwise.
# Mirrors the helpers' `is_agent_author` exactly. Bash 3.2 compatible
# (no associative arrays). Reads MERGEPATH_AGENT_AUTHORS (colon-sep)
# with the same default set as the rollup helpers.
: "${MERGEPATH_AGENT_AUTHORS:=nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}"
is_agent_author_local() {
  local login="$1"
  local oldIFS="$IFS"
  IFS=':'
  set -- $MERGEPATH_AGENT_AUTHORS
  IFS="$oldIFS"
  for a; do
    [ "$login" = "$a" ] && return 0
  done
  return 1
}

# latest_nonagent_created <thread_json> → ISO timestamp on stdout.
#
# THE STALENESS FLOOR. The createdAt of the most recent NON-agent (bot /
# real-reviewer) comment on the thread, floored at the original finding's
# createdAt (`.created`). This is the "bot's last word" timestamp used by
# the addressed-elsewhere staleness guard (#565): a fix commit (or a
# rebuttal, via the index-based variant in derive_tag_class step 0/3) only
# counts as actioning the thread if it post-dates this — otherwise a stale
# fix that predates a later bot re-raise would falsely clear live feedback.
# ISO 8601 sorts lexicographically, so the `\>` string comparison is
# chronological. Single-sourced here so derive_tag_class and
# synth_rationale apply the identical predicate.
#
# COMPLETENESS PRECONDITION (#573 item 2): the floor is only correct when
# `.all_comments` covers the ENTIRE thread. The enumeration query fetches
# only the newest 50 comments; on a longer thread whose latest re-raise is
# buried under 50+ agent replies, that window omits the re-raise and this
# function silently falls back to an OLDER timestamp — understating the
# floor and letting --resolve-actioned resolve live feedback. Callers on
# any staleness-sensitive path MUST first run the thread JSON through
# complete_thread_comments (below), which re-fetches the full comment list
# for truncated threads and FAILS CLOSED (thread skipped, left unresolved)
# when the full list cannot be assembled. Later work (verified-propagation
# resolution) builds on this floor — keep the complete-thread invariant.
latest_nonagent_created() {
  local tj="$1"
  local latest cnt i login created
  latest=$(printf '%s' "$tj" | jq -r '.created // ""')
  cnt=$(printf '%s' "$tj" | jq '.all_comments | length' 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt "$cnt" ]; do
    login=$(printf '%s' "$tj" | jq -r ".all_comments[$i].author.login // \"\"")
    if ! is_agent_author_local "$login"; then
      created=$(printf '%s' "$tj" | jq -r ".all_comments[$i].createdAt // \"\"")
      if [ -n "$created" ] && { [ -z "$latest" ] || [ "$created" \> "$latest" ]; }; then
        latest="$created"
      fi
    fi
    i=$((i + 1))
  done
  printf '%s' "$latest"
}

# --- #573 item 2: full-thread comment pagination ----------------------------
#
# fetch_all_thread_comments <thread-node-id> → the thread's COMPLETE comment
# list (JSON array, same node shape as allComments.nodes) on stdout.
#
# Forward cursor pagination via the top-level `node(id:)` lookup +
# `comments(first: 100, after: $cursor)`, mirroring the enumeration loop's
# two load-bearing patterns: the typed-null-first-call cursor handling
# (#192 — `-F cursor=null` sends GraphQL null; `-f` would send the string
# "null") and the totalCount cross-validation (an assembled count that
# disagrees with the API's totalCount is never trusted).
#
# FAIL CLOSED — returns non-zero (and callers must NOT classify the thread)
# on ANY of:
#   - a gh/GraphQL error on any page
#   - a page missing `.data.node.comments.nodes` (null node / partial page)
#   - hasNextPage=true without a usable endCursor
#   - hasNextPage missing entirely (cannot prove the walk terminated)
#   - more than THREAD_COMMENTS_MAX_PAGES pages (runaway-loop guard)
#   - an assembled count != totalCount
THREAD_COMMENTS_MAX_PAGES=20  # 20 × 100 = 2,000 comments; beyond any real thread
fetch_all_thread_comments() {
  local thread_id="$1"
  local query='
    query($id: ID!, $cursor: String) {
      node(id: $id) {
        ... on PullRequestReviewThread {
          comments(first: 100, after: $cursor) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              author { login }
              body
              databaseId
              createdAt
            }
          }
        }
      }
    }
  '
  local merged='[]' cursor="" resp nodes total="null" has_next pages=0 have
  while :; do
    pages=$((pages + 1))
    if [ "$pages" -gt "$THREAD_COMMENTS_MAX_PAGES" ]; then
      echo "thread-comments pagination exceeded $THREAD_COMMENTS_MAX_PAGES pages for $thread_id — failing closed" >&2
      return 1
    fi
    # Cursor-typing discipline per #192: typed null (-F) on the first
    # call, string cursor (-f) on every subsequent page.
    if [ -z "$cursor" ]; then
      resp=$(gh_pat api graphql -f query="$query" -F id="$thread_id" -F cursor=null 2>&1) || {
        echo "thread-comments page fetch failed for $thread_id: $resp" >&2
        return 1
      }
    else
      resp=$(gh_pat api graphql -f query="$query" -F id="$thread_id" -f cursor="$cursor" 2>&1) || {
        echo "thread-comments page fetch failed for $thread_id: $resp" >&2
        return 1
      }
    fi
    nodes=$(printf '%s' "$resp" | jq -c '.data.node.comments.nodes // null' 2>/dev/null) || nodes="null"
    if [ -z "$nodes" ] || [ "$nodes" = "null" ]; then
      echo "thread-comments page for $thread_id returned no nodes (null node / partial page) — failing closed" >&2
      return 1
    fi
    merged=$(printf '%s' "$nodes" | jq -c --argjson acc "$merged" '$acc + .' 2>/dev/null) || {
      echo "thread-comments page merge failed for $thread_id — failing closed" >&2
      return 1
    }
    total=$(printf '%s' "$resp" | jq -r '.data.node.comments.totalCount // "null"' 2>/dev/null) || total="null"
    # NB: `// "null"` would be wrong for hasNextPage — jq's `//` treats
    # `false` as empty, so a legitimate final page (hasNextPage=false)
    # would read as missing. Use an explicit null check instead.
    has_next=$(printf '%s' "$resp" \
      | jq -r '.data.node.comments.pageInfo.hasNextPage
               | if . == null then "null" else tostring end' 2>/dev/null) || has_next="null"
    if [ "$has_next" = "true" ]; then
      cursor=$(printf '%s' "$resp" | jq -r '.data.node.comments.pageInfo.endCursor // ""' 2>/dev/null) || cursor=""
      if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
        echo "thread-comments page for $thread_id has hasNextPage=true but no endCursor — failing closed" >&2
        return 1
      fi
      continue
    fi
    if [ "$has_next" != "false" ]; then
      echo "thread-comments page for $thread_id missing pageInfo.hasNextPage — failing closed" >&2
      return 1
    fi
    break
  done
  have=$(printf '%s' "$merged" | jq -r 'length' 2>/dev/null) || have="-1"
  if [ "$total" = "null" ] || [ "$have" != "$total" ]; then
    echo "thread-comments count mismatch for $thread_id (assembled=$have totalCount=$total) — failing closed" >&2
    return 1
  fi
  printf '%s' "$merged"
}

# complete_thread_comments <thread_json> → thread JSON on stdout whose
# `.all_comments` is the COMPLETE comment list; the exit status is the
# completeness verdict:
#   0 — .all_comments covers the whole thread (it already did — the
#       enumeration window was not truncated — or the windowed re-fetch
#       above succeeded and replaced it)
#   1 — the comment list could NOT be completed (pagination error / page
#       cap / count mismatch). The input JSON is echoed back unchanged.
#       Callers on a staleness-sensitive path MUST fail closed: treat the
#       thread as NOT actioned and leave it unresolved. Never classify —
#       and never resolve — on a comment list that may be missing the
#       latest bot/reviewer re-raise (#573 item 2; extends the #564
#       fail-closed guarantee).
complete_thread_comments() {
  local tj="$1"
  local truncated thread_id full
  truncated=$(printf '%s' "$tj" | jq -r '.all_comments_truncated // false' 2>/dev/null) || truncated="true"
  if [ "$truncated" != "true" ]; then
    printf '%s' "$tj"
    return 0
  fi
  thread_id=$(printf '%s' "$tj" | jq -r '.id // ""' 2>/dev/null) || thread_id=""
  if [ -z "$thread_id" ]; then
    printf '%s' "$tj"
    return 1
  fi
  if ! full=$(fetch_all_thread_comments "$thread_id"); then
    printf '%s' "$tj"
    return 1
  fi
  printf '%s' "$tj" | jq -c --argjson fc "$full" \
    '.all_comments = $fc | .all_comments_truncated = false'
}

# commit_files <sha> → JSON array of the filenames a commit touched, on
# stdout ("" if the per-commit fetch fails). Disk-cached under
# COMMIT_FILES_CACHE_DIR so each sha is fetched at most once across the
# per-thread command-substitution subshells. The PR /commits cache carries
# no file list, so addressed-elsewhere needs this per-commit lookup (#565).
commit_files() {
  local sha="$1"
  [ -z "$sha" ] && return 0
  local cf="$COMMIT_FILES_CACHE_DIR/$sha"
  if [ ! -f "$cf" ]; then
    gh_pat api "repos/$OWNER/$NAME/commits/$sha" --jq '[.files[].filename]' \
      >"$cf" 2>/dev/null || : >"$cf"
  fi
  cat "$cf"
}

# commit_touches_file <sha> <path> → exit 0 if the commit's file list
# includes <path>, 1 otherwise. FAIL CLOSED (#565): a commit whose files
# cannot be read (empty result) does NOT match, so a fetch failure can never
# make a thread look actioned, and an agent commit on an UNRELATED file no
# longer satisfies addressed-elsewhere for this thread.
commit_touches_file() {
  local sha="$1" path="$2" files
  { [ -z "$sha" ] || [ -z "$path" ] || [ "$path" = "(no path)" ]; } && return 1
  files=$(commit_files "$sha")
  [ -z "$files" ] && return 1
  printf '%s' "$files" | jq -e --arg p "$path" 'any(. == $p)' >/dev/null 2>&1
}

# classify_severity_local <body> → P0|P1|...|Nitpick|Trivial|Unknown
# Mirrors the rollup helpers' classify_severity, anchored on the
# first ~600 chars to avoid false-matching severity words deep in
# quoted context.
classify_severity_local() {
  local body_head
  body_head=$(printf '%s' "$1" | head -c 600)
  case "$body_head" in
    *"![P0 Badge]"*|*"P0 Badge"*) echo "P0"; return ;;
    *"![P1 Badge]"*|*"P1 Badge"*) echo "P1"; return ;;
    *"![P2 Badge]"*|*"P2 Badge"*) echo "P2"; return ;;
    *"![P3 Badge]"*|*"P3 Badge"*) echo "P3"; return ;;
    *"🟠 Major"*|*"Potential issue"*|*"⚠️"*) echo "Major"; return ;;
    *"🧹 Nitpick"*|*Nitpick*) echo "Nitpick"; return ;;
    *"🔵 Trivial"*|*Trivial*) echo "Trivial"; return ;;
    *"Outside diff range"*) echo "Trivial"; return ;;
    *Minor*) echo "Minor"; return ;;
  esac
  echo "Unknown"
}

# One-shot fetch of PR file paths + agent-author commits, used by
# derive_tag_class for the addressed-elsewhere heuristic. Cached so
# we make at most one REST call per resolve invocation regardless of
# thread count. Failure is non-fatal: tag derivation falls back to
# the rollup's per-PR weak heuristic if files can't be retrieved.
PR_FILES_CACHE=""
PR_COMMITS_CACHE=""
TAG_DATA_FETCHED=false
fetch_pr_tag_data() {
  $TAG_DATA_FETCHED && return 0
  TAG_DATA_FETCHED=true
  # REST /pulls/{pr}/files and /pulls/{pr}/commits both paginate at
  # 100 items per page. Without pagination, threads anchored on
  # files beyond page 1 silently misclassify on PRs with >100
  # changed files (Codex P2 on #308). We use a manual page loop
  # rather than gh's --paginate so the URL stays in argv-position
  # 2 (gh injects --paginate as $2, which breaks stubs that route
  # on $2 — including test_resolve_pr_threads_rationale_tag.sh).
  PR_FILES_CACHE=$(_fetch_paginated \
    "repos/$OWNER/$NAME/pulls/$PR_NUM/files" \
    '[.[].filename]')
  # PR_COMMITS_CACHE now includes `sha` so synth_rationale can cite
  # the matching commit. The predicate the rationale builds must
  # match derive_tag_class's predicate (CodeRabbit major on #308).
  # login fallback chain (#565 round 8): .author.login is null for commits
  # whose author email is not linked to a GitHub account — which is THIS
  # repo's normal case (commits are authored as nathanjohnpayne with a
  # placeholder .example email). So fall back to .commit.author.name (the git
  # config name, e.g. "nathanjohnpayne", which IS in MERGEPATH_AGENT_AUTHORS)
  # BEFORE the email, or agent fix commits are never recognized as
  # agent-authored and addressed-elsewhere never fires.
  PR_COMMITS_CACHE=$(_fetch_paginated \
    "repos/$OWNER/$NAME/pulls/$PR_NUM/commits" \
    '[.[] | {sha: (.sha // ""), login: (.author.login // .commit.author.name // .commit.author.email // ""), date: (.commit.author.date // .commit.committer.date // "")}]')
}

# _fetch_paginated <base-url> <jq-projection> → JSON array on stdout.
# Manually walks `?per_page=100&page=N` until a page returns fewer
# than 100 items OR a defensive 50-page cap (5,000 items) is hit.
# Falls back to `[]` on first-page failure so downstream treats as
# match-any rather than under-classifying. Test stubs that return a
# pre-transformed JSON array still work: this helper applies a
# `--jq` projection that the stubs ignore (stubs return their own
# canned output), and the per-page-merging stops naturally because
# the canned single-page output has fewer than 100 items.
_fetch_paginated() {
  local base_url="$1"
  local projection="$2"
  local page=1
  local max_pages=50
  local merged='[]'
  local raw count
  while [ "$page" -le "$max_pages" ]; do
    if ! raw=$(gh_pat api "${base_url}?per_page=100&page=${page}" \
        --jq "$projection" 2>/dev/null); then
      [ "$page" -eq 1 ] && { echo '[]'; return; }
      break
    fi
    [ -z "${raw//[[:space:]]/}" ] && break
    count=$(printf '%s' "$raw" | jq 'length' 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && break
    merged=$(printf '%s\n%s\n' "$merged" "$raw" | jq -s -c '.[0] + .[1]' 2>/dev/null || printf '%s' "$merged")
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  printf '%s' "$merged"
}

# manifest_canonical_paths — extract canonical + kit paths from the
# repo's .mergepath-sync.yml once. Cached. Returns a newline-separated
# list of path strings (kit entries end with `/`, canonical entries
# do not). Used to classify a thread as `canonical-coverage` when the
# comment's anchored file matches a manifest entry.
MANIFEST_PATHS_CACHE=""
MANIFEST_FETCHED=false
fetch_manifest_paths() {
  $MANIFEST_FETCHED && return 0
  MANIFEST_FETCHED=true
  local manifest="$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml"
  [ -f "$manifest" ] || return 0
  # Prefer yq when available — same parser the manifest validator uses.
  # Fall back to a grep-based extraction so the helper still functions
  # in environments without yq (the rollup-classifier-side reading is
  # the same shape).
  # RESOLVE_PR_THREADS_FORCE_NO_YQ=1 forces the grep/awk fallback — a test
  # hook for the #521 no-yq path (CI installs yq, so PATH curation is not
  # portable). Inert in production. Mirrors RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK.
  if [ -z "${RESOLVE_PR_THREADS_FORCE_NO_YQ:-}" ] && command -v yq >/dev/null 2>&1; then
    MANIFEST_PATHS_CACHE=$(yq -r '.paths[].path' "$manifest" 2>/dev/null || true)
  else
    # Best-effort: read `- path: VALUE` lines. Tolerates surrounding
    # whitespace and optional quotes.
    MANIFEST_PATHS_CACHE=$(grep -E '^[[:space:]]*-[[:space:]]*path:' "$manifest" \
      | sed -E 's/^[[:space:]]*-[[:space:]]*path:[[:space:]]*["'\'']?([^"'\'']+)["'\'']?[[:space:]]*$/\1/')
  fi
}

# _path_matches_entry_list <file-path> <newline-separated-paths> — shared
# matcher for the manifest path predicates: a file matches an entry if the
# entry path equals the file path, or if the entry path ends with `/`
# (kit) and the file path starts with it. Empty list never matches.
_path_matches_entry_list() {
  local file_path="$1" entry_list="$2" mp
  [ -z "$file_path" ] && return 1
  [ "$file_path" = "(no path)" ] && return 1
  [ -z "$entry_list" ] && return 1
  while IFS= read -r mp; do
    [ -z "$mp" ] && continue
    if [ "${mp: -1}" = "/" ]; then
      case "$file_path" in
        "$mp"*) return 0 ;;
      esac
    else
      [ "$file_path" = "$mp" ] && return 0
    fi
  done <<< "$entry_list"
  return 1
}

# path_matches_manifest <file-path> → exit 0 on match, 1 otherwise.
# Matches ANY manifest entry's .path (canonical, kit, or a templated
# entry's SOURCE) — the broad routing signal the TAG ladder uses.
path_matches_manifest() {
  fetch_manifest_paths
  _path_matches_entry_list "$1" "$MANIFEST_PATHS_CACHE"
}

# fetch_manifest_canonical_paths — like fetch_manifest_paths but ONLY the
# canonical + kit entries (#616, Codex finding 3509930343). A templated
# entry's `.path` is the MERGEPATH SOURCE — consumers receive `.dest`, not
# the source — so a consumer file that coincidentally sits at a templated
# source path is NOT propagated content and must never byte-verify against
# it. --resolve-verified-propagation's canonical branch therefore routes on
# this cache; templated routing goes by dest (path_matches_templated_dest).
MANIFEST_CANONICAL_PATHS_CACHE=""
MANIFEST_CANONICAL_FETCHED=false
fetch_manifest_canonical_paths() {
  $MANIFEST_CANONICAL_FETCHED && return 0
  MANIFEST_CANONICAL_FETCHED=true
  local manifest="$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml"
  [ -f "$manifest" ] || return 0
  # RESOLVE_PR_THREADS_FORCE_NO_YQ=1 forces the awk fallback — same test
  # hook as the sibling caches (#521). Inert in production.
  if [ -z "${RESOLVE_PR_THREADS_FORCE_NO_YQ:-}" ] && command -v yq >/dev/null 2>&1; then
    MANIFEST_CANONICAL_PATHS_CACHE=$(yq -r '
      .paths[] | select(.type == "canonical" or .type == "kit") | .path
    ' "$manifest" 2>/dev/null || true)
  else
    # awk fallback — entry-boundary emission mirroring
    # fetch_manifest_templated_dests: pair `path:` with `type:` within a
    # paths-block entry, emit ONLY canonical/kit entries. Positive
    # selection is deliberate: an entry with no recognized type is
    # excluded (conservative under-match → the verified-propagation mode
    # skips fail-closed rather than byte-comparing a non-canonical path).
    MANIFEST_CANONICAL_PATHS_CACHE=$(awk '
      function emit() {
        if ((cur_type == "canonical" || cur_type == "kit") && cur_path != "")
          print cur_path
      }
      /^paths:/ { in_p = 1; next }
      in_p && /^[^[:space:]#]/ { emit(); in_p = 0 }
      !in_p { next }
      /^[[:space:]]*-[[:space:]]*path:/ {
        emit()
        cur_path = $0
        sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", cur_path)
        sub(/[[:space:]]*#.*$/, "", cur_path)
        gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_path)
        cur_type = ""
      }
      /^[[:space:]]*type:[[:space:]]*["\047]?canonical["\047]?[[:space:]]*(#.*)?$/ {
        cur_type = "canonical"
      }
      /^[[:space:]]*type:[[:space:]]*["\047]?kit["\047]?[[:space:]]*(#.*)?$/ {
        cur_type = "kit"
      }
      END { emit() }
    ' "$manifest" 2>/dev/null || true)
  fi
}

# path_matches_canonical_entry <file-path> → exit 0 when the path matches
# a canonical/kit manifest entry (templated sources excluded), 1 otherwise.
path_matches_canonical_entry() {
  fetch_manifest_canonical_paths
  _path_matches_entry_list "$1" "$MANIFEST_CANONICAL_PATHS_CACHE"
}

# fetch_manifest_templated_dests — extract dest + eligible consumer
# slugs for every templated entry in the manifest (#323). Templated
# entries decouple source from dest (the whole point), so a thread
# anchored on a templated dest path doesn't match path_matches_manifest
# above (which reads only .path). Cached.
#
# Cache format: one line per entry, `dest<TAB>repo1,repo2,...` where
# each repoN is the full owner/name slug looked up from
# `.consumers[].repo` via the entry's `.consumers[] (name)` list. The
# repo-slug scoping closes the codex P2 from PR #329 round 1: without
# it, ANY repo whose local file matched the dest path got the
# `templated-render` class, even repos not opted into that entry —
# suppressing substantive unresolved feedback on unrelated files in
# the daily rollup.
MANIFEST_TEMPLATED_DESTS_CACHE=""
MANIFEST_TEMPLATED_FETCHED=false
fetch_manifest_templated_dests() {
  $MANIFEST_TEMPLATED_FETCHED && return 0
  MANIFEST_TEMPLATED_FETCHED=true
  local manifest="$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml"
  [ -f "$manifest" ] || return 0
  # RESOLVE_PR_THREADS_FORCE_NO_YQ=1 forces the grep/awk fallback — a test
  # hook for the #521 no-yq path (CI installs yq, so PATH curation is not
  # portable). Inert in production. Mirrors RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK.
  if [ -z "${RESOLVE_PR_THREADS_FORCE_NO_YQ:-}" ] && command -v yq >/dev/null 2>&1; then
    # #467: a path entry's `consumers` is EITHER a sequence of names OR
    # the scalar literal `all`. The prior single-pass expression did
    # `.consumers // [] | map(...)`, which on the scalar `all` tried to
    # `map` over a string — a yq runtime error that, under `|| true`,
    # blanked the ENTIRE templated-dest cache. One `consumers: all`
    # templated entry thus silently disabled templated-render
    # classification for every entry. Resolve the two shapes in two
    # passes (mirrors check_sync_manifest, which splits the same way to
    # dodge mikefarah/yq's inline if/then/else limits), then merge.
    #
    # Pass 1 — scalar `consumers: all` → every consumer's repo slug.
    # Bind the full repo list inline with `as $all`; mikefarah yq has no
    # jq-style `--arg`, but it supports `... as $var` (same mechanism as
    # the `. as $root` lookup in pass 2).
    local _all_rows _seq_rows
    _all_rows=$(yq -r '
      . as $root |
      ($root.consumers | map(.repo) | join(",")) as $all |
      .paths[]
      | select(.type == "templated")
      | select(.consumers == "all")
      | (.dest // .path) + "\t" + $all
    ' "$manifest" 2>/dev/null || true)
    # Pass 2 — sequence consumers → resolve each name to its repo slug.
    # `. as $root` exposes the top-level consumers table for the inner
    # lookup. The `tag == "!!seq"` guard keeps the scalar form away from
    # the `map` that errored before. Output: `dest<TAB>repo,repo,...`.
    _seq_rows=$(yq -r '
      . as $root |
      .paths[]
      | select(.type == "templated")
      | select(.consumers | tag == "!!seq")
      | [ (.dest // .path),
          (.consumers | map(. as $name |
             $root.consumers[] | select(.name == $name) | .repo) | join(",")) ]
        | @tsv
    ' "$manifest" 2>/dev/null || true)
    MANIFEST_TEMPLATED_DESTS_CACHE=$(printf '%s\n%s\n' "$_all_rows" "$_seq_rows" | grep -v '^[[:space:]]*$' || true)
  else
    # awk fallback — mirrors the canonical-paths fallback above. Pair
    # `type:` and `dest:` (or fall back to `path:`) within a `paths:`
    # block entry. Less precise than yq in two ways, both addressed
    # below per CR Major #329 round 2:
    #
    # 1. Order-independent emission. The prior version emitted on the
    #    `type: templated` line, which broke when `dest:` appeared
    #    AFTER `type:` (legal YAML, common in manifest practice). Now
    #    we emit at entry boundaries (start of next entry / end of
    #    paths block / EOF) so `dest:` and `type:` can appear in any
    #    order within an entry.
    #
    # 2. Strict no-match instead of loose-match. The prior version
    #    emitted the dest with an empty consumers field, which
    #    path_matches_templated_dest interpreted as "match any repo"
    #    — reintroducing the exact cross-repo misclassification this
    #    fix is trying to close. Now the awk path emits a sentinel
    #    `__AWK_NO_CONSUMER_SCOPE__` token in the consumers field,
    #    which path_matches_templated_dest treats as "no match" (the
    #    cautious failure mode: under-classify rather than over-
    #    classify; templated-render is a skip-class, and a missed
    #    skip just falls back to the rollup's general heuristics).
    #
    # 3. `consumers: all` parity with the yq path (#521). The yq pass-1
    #    resolves a scalar `consumers: all` to EVERY consumer's repo slug,
    #    i.e. match-any-consumer. The awk fallback previously could not
    #    distinguish `all` from a name list (it never parsed `consumers:`),
    #    so an `all` templated entry was under-classified along with every
    #    other entry. We now detect the scalar `consumers: all` per entry
    #    and emit a dedicated `__AWK_CONSUMERS_ALL__` sentinel, which
    #    path_matches_templated_dest treats as "match any repo" — mirroring
    #    the yq semantics. A `consumers:` followed by a name SEQUENCE stays
    #    the cautious no-scope sentinel (awk can't reliably resolve
    #    name→repo cross-references), matching the prior behavior for lists.
    # Pre-extract top-level consumer repos so the awk path can resolve
    # `consumers: all` to an actual repo slug list — matching what the yq
    # pass-1 does via `$root.consumers | map(.repo) | join(",")`. Without
    # this, the `consumers: all` sentinel matched every repo unconditionally,
    # including foreign repos not in the consumers list (#554 item 1 / #556).
    local _awk_all_repos
    _awk_all_repos=$(awk '
      /^consumers:/ { in_c=1; next }
      in_c && /^[^[:space:]#]/ { in_c=0 }
      in_c && /^[[:space:]]*repo:/ {
        v=$0
        sub(/^[[:space:]]*repo:[[:space:]]*/, "", v)
        sub(/[[:space:]]*#.*$/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$|^["\047]|["\047]$/, "", v)
        if (v != "") repos = repos (repos=="" ? "" : ",") v
      }
      END { print repos }
    ' "$manifest" 2>/dev/null || true)
    MANIFEST_TEMPLATED_DESTS_CACHE=$(awk -v all_repos="$_awk_all_repos" '
      function emit() {
        if (cur_type == "templated") {
          out = (cur_dest != "" ? cur_dest : cur_path)
          if (out != "") {
            if (cur_consumers_all) {
              # Resolve `consumers: all` to the actual consumer repo list so
              # path_matches_templated_dest can check $REPO membership, mirroring
              # the yq pass-1 behaviour. Fall back to no-scope if the list is
              # empty (cannot determine membership → conservative non-match).
              if (all_repos != "") {
                printf "%s\t%s\n", out, all_repos
              } else {
                printf "%s\t__AWK_NO_CONSUMER_SCOPE__\n", out
              }
            } else {
              printf "%s\t__AWK_NO_CONSUMER_SCOPE__\n", out
            }
          }
        }
      }
      /^paths:/ { in_p = 1; next }
      in_p && /^[^[:space:]#]/ { emit(); in_p = 0 }
      !in_p { next }
      /^[[:space:]]*-[[:space:]]*path:/ {
        emit()
        cur_path = $0
        sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", cur_path)
        sub(/[[:space:]]*#.*$/, "", cur_path)
        gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_path)
        cur_dest = ""; cur_type = ""; cur_consumers_all = 0
      }
      /^[[:space:]]*dest:/ {
        cur_dest = $0
        sub(/^[[:space:]]*dest:[[:space:]]*/, "", cur_dest)
        sub(/[[:space:]]*#.*$/, "", cur_dest)
        gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_dest)
      }
      /^[[:space:]]*type:[[:space:]]*templated/ {
        cur_type = "templated"
      }
      # Scalar `consumers: all` (optionally quoted / trailing comment).
      # A sequence form (`consumers:` then `- name` lines) does NOT match
      # this pattern, so it correctly falls through to the no-scope sentinel.
      /^[[:space:]]*consumers:[[:space:]]*["\047]?all["\047]?[[:space:]]*(#.*)?$/ {
        cur_consumers_all = 1
      }
      END { emit() }
    ' "$manifest")
  fi
}

# path_matches_templated_dest <file-path> → exit 0 if it matches a
# templated entry's dest path AND the current repo ($REPO) is in that
# entry's consumers list, 1 otherwise. Used by derive_tag_class to
# emit the `templated-render` class (#323). The consumer-scope check
# closes codex P2 from PR #329 round 1.
path_matches_templated_dest() {
  local file_path="$1"
  [ -z "$file_path" ] && return 1
  [ "$file_path" = "(no path)" ] && return 1
  fetch_manifest_templated_dests
  [ -z "$MANIFEST_TEMPLATED_DESTS_CACHE" ] && return 1
  local line dest consumers
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Split on the first tab. Two-field TSV: dest<TAB>repo1,repo2,...
    dest="${line%%$'\t'*}"
    consumers="${line#*$'\t'}"
    [ "$file_path" = "$dest" ] || continue
    # Legacy sentinel — the awk fallback previously emitted this when it
    # detected `consumers: all` but could not resolve the consumer repo list.
    # The awk path now resolves `all` to the actual repo slug list (matching
    # the yq path), so this sentinel is no longer emitted in practice (#556).
    # Kept as a safety net: if somehow emitted, fall through to no-scope
    # (conservative non-match) rather than matching unconditionally.
    if [ "$consumers" = "__AWK_CONSUMERS_ALL__" ]; then
      continue
    fi
    # The awk fallback emits this sentinel when it can't resolve
    # consumer-name → repo-slug (cross-references in awk are
    # brittle). Treat sentinel as "no scope information available"
    # and DO NOT match — better to miss the templated-render skip
    # tag (falling through to other heuristics in the rollup) than
    # to over-classify and silently suppress substantive feedback
    # on unrelated files. (CR Major #329 round 2.)
    if [ "$consumers" = "__AWK_NO_CONSUMER_SCOPE__" ]; then
      continue
    fi
    # Empty consumers field — yq returned no consumer matches for
    # this entry (entry has no `consumers:` list, or none of the
    # named consumers resolve to a repo). Treat as no-scope
    # information, same as the awk sentinel: don't match.
    if [ -z "$consumers" ]; then
      continue
    fi
    # The current repo ($REPO, populated from --repo arg or origin
    # remote at module-load) MUST appear in the comma-separated
    # consumers list. Anchored grep avoids partial-name false hits
    # (e.g., `owner/matchline` vs `owner/matchline-app`).
    if printf ',%s,' "$consumers" | grep -qF ",$REPO,"; then
      return 0
    fi
  done <<< "$MANIFEST_TEMPLATED_DESTS_CACHE"
  return 1
}

# Module-load-time: pin the manifest base. We resolve REPO_ROOT_FOR_MANIFEST
# from the script's on-disk location, NOT $REPO (which is the gh repo
# slug). This intentionally reads the LOCAL working-tree manifest —
# the same file scripts/sync-to-downstream.sh authors against — so the
# helper's canonical-coverage class agrees with what would actually
# propagate.
REPO_ROOT_FOR_MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------
# #572 — verified-propagation resolution helpers
# ---------------------------------------------------------------------
#
# All of these FAIL CLOSED: any lookup/fetch/render failure returns
# non-zero and the caller must SKIP the thread (leave it unresolved),
# never resolve on partial evidence. The byte-compare is the resolution
# evidence; routing (path membership) alone never resolves (#565).

# The templated arm REUSES the exact render engine
# scripts/workflow/verify-propagation-pr.sh uses — the same
# template-substitution lib + manifest-fact-helpers pair, sourced in a
# subshell so the MERGEPATH_FACT_* exports don't leak between threads.
# Do NOT reimplement the render here; divergence between the two
# byte-compare surfaces would make "verified" mean two different things.
VP_TEMPLATE_LIB="$__RESOLVE_THREADS_DIR/lib/template-substitution.sh"
VP_FACTS_HELPER="$__RESOLVE_THREADS_DIR/lib/manifest-fact-helpers.sh"

# fetch_consumer_default_branch — resolve (once) the consumer repo's
# default branch NAME, which resolve_consumer_compare_ref pins to its
# tip commit SHA for CLOSED/MERGED PRs (#616 finding 3510442271).
# Cached; returns non-zero (fail closed) when it cannot be resolved.
CONSUMER_DEFAULT_BRANCH=""
CONSUMER_DEFAULT_BRANCH_FETCHED=false
fetch_consumer_default_branch() {
  if ! $CONSUMER_DEFAULT_BRANCH_FETCHED; then
    CONSUMER_DEFAULT_BRANCH_FETCHED=true
    CONSUMER_DEFAULT_BRANCH=$(gh_pat api "repos/$OWNER/$NAME" \
      --jq .default_branch 2>/dev/null) || CONSUMER_DEFAULT_BRANCH=""
    [ "$CONSUMER_DEFAULT_BRANCH" = "null" ] && CONSUMER_DEFAULT_BRANCH=""
  fi
  [ -n "$CONSUMER_DEFAULT_BRANCH" ]
}

# resolve_consumer_compare_ref — resolve (once) the ref every #572
# byte-compare and tree-entry read targets (#616 finding 3510170875):
#   PR OPEN          → the PR's own HEAD sha ($HEAD_OID). The pre-merge
#                      conversation gate runs this mode on OPEN consumer
#                      PRs, and the PR being merged may itself change the
#                      same canonical/templated destination — comparing
#                      the default branch there would resolve a thread
#                      while the candidate content still carries drift.
#   PR CLOSED/MERGED → the default branch's TIP COMMIT SHA (the #562
#                      backlog case: the thread's own PR is history; the
#                      consumer's current state is the propagation
#                      evidence). Pinned to a SHA ONCE (#616 finding
#                      3510442271): the branch NAME is a moving ref — the
#                      contents fetch and the git-trees fetch would each
#                      re-resolve it at request time and could read
#                      DIFFERENT commits if the branch advances between
#                      the two reads, letting the byte-compare and the
#                      mode/type gate pass against inconsistent states.
#                      One immutable SHA keeps every read coherent; an
#                      unresolvable tip fails closed like every other
#                      lookup here.
#   anything else    → FAIL CLOSED (state fetch failure / unknown state
#                      never verifies).
# Cached like the default-branch lookup; the warm-cache call in the mode
# gate runs this in the parent shell so the per-thread verification
# subshells inherit one resolution for the whole run.
CONSUMER_COMPARE_REF=""
CONSUMER_COMPARE_REF_KIND=""
CONSUMER_COMPARE_REF_FETCHED=false
resolve_consumer_compare_ref() {
  local pr_state tip_sha
  if ! $CONSUMER_COMPARE_REF_FETCHED; then
    CONSUMER_COMPARE_REF_FETCHED=true
    pr_state=$(gh_pat api "repos/$OWNER/$NAME/pulls/$PR_NUM" \
      --jq .state 2>/dev/null) || pr_state=""
    case "$pr_state" in
      open)
        if [ -n "$HEAD_OID" ] && [ "$HEAD_OID" != "null" ]; then
          CONSUMER_COMPARE_REF="$HEAD_OID"
          CONSUMER_COMPARE_REF_KIND="pr-head"
        fi
        ;;
      closed|merged)
        # REST reports merged PRs as state=closed; `merged` is accepted
        # defensively for any future/GraphQL-shaped stub.
        if fetch_consumer_default_branch; then
          tip_sha=$(gh_pat api \
            "repos/$OWNER/$NAME/git/ref/heads/$CONSUMER_DEFAULT_BRANCH" \
            --jq .object.sha 2>/dev/null) || tip_sha=""
          [ "$tip_sha" = "null" ] && tip_sha=""
          if [ -n "$tip_sha" ]; then
            CONSUMER_COMPARE_REF="$tip_sha"
            CONSUMER_COMPARE_REF_KIND="default-branch-tip"
          fi
        fi
        ;;
      *) : ;;  # unknown/empty state → fail closed below
    esac
  fi
  [ -n "$CONSUMER_COMPARE_REF" ]
}

# resolve_consumer_compare_tree — echo the TREE sha of the compared
# ref's commit (#616 finding 3510689525). CONSUMER_COMPARE_REF is a
# COMMIT sha (the PR head, or the pinned default-branch tip), but the
# git/trees endpoint's documented contract takes "the SHA1 value or ref
# (branch or tag) name of the TREE" — peel the commit to its tree
# explicitly (repos/{o}/{r}/commits/{sha} → .commit.tree.sha, the same
# commits endpoint the commit-files cache reads) rather than leaning on
# undocumented commit-sha acceptance. One commits read per run, cached
# to a FILE under COMMIT_FILES_CACHE_DIR alongside the compare ref's
# tree listing (same subshell-survival rule as that cache). Non-zero
# (fail closed) when the compare ref is unresolvable or the commit read
# does not yield a tree sha.
resolve_consumer_compare_tree() {
  local cache="$COMMIT_FILES_CACHE_DIR/consumer-compare-tree.sha" tree_sha
  if [ -s "$cache" ]; then
    cat "$cache"
    return 0
  fi
  resolve_consumer_compare_ref || return 1
  tree_sha=$(gh_pat api "repos/$OWNER/$NAME/commits/$CONSUMER_COMPARE_REF" \
    --jq .commit.tree.sha 2>/dev/null) || tree_sha=""
  [ "$tree_sha" = "null" ] && tree_sha=""
  [ -n "$tree_sha" ] || return 1
  printf '%s' "$tree_sha" > "$cache"
  printf '%s' "$tree_sha"
}

# fetch_consumer_content <path> <out-file> — write the consumer repo's
# content at <path> at the COMPARED REF (raw bytes via the contents
# endpoint) into <out-file>. Non-zero on any failure — including an
# unresolvable compare ref or a PR-head fetch failure (#616 finding
# 3510170875: fail closed, never fall back to the default branch for an
# open PR). The content goes to a FILE, not a command substitution, so
# trailing newlines survive and the compare is truly byte-for-byte.
fetch_consumer_content() {
  local vp_path="$1" out="$2"
  resolve_consumer_compare_ref || return 1
  gh_pat api -H "Accept: application/vnd.github.raw" \
    "repos/$OWNER/$NAME/contents/$vp_path?ref=$CONSUMER_COMPARE_REF" \
    > "$out" 2>/dev/null
}

# fetch_consumer_tree_entry <path> — echo the consumer's git tree entry
# ("<mode> <type>", e.g. "100644 blob") for <path> at the compared ref.
# The recursive git-trees fetch targets the compared commit's PEELED
# TREE sha (resolve_consumer_compare_tree, #616 finding 3510689525) —
# the endpoint's documented parameter is a tree sha or ref name, not a
# commit sha. One recursive git-trees fetch per run, cached to a FILE
# under COMMIT_FILES_CACHE_DIR so the cache survives the
# command-substitution subshells verify_propagation_content runs in.
# Non-zero (fail closed) on: unresolvable compare ref, commit→tree
# resolution failure, fetch failure, a TRUNCATED tree listing (GitHub
# caps recursive listings — a truncated response cannot prove the
# entry's shape), or the path missing from the tree.
CONSUMER_TREE_CACHE=""
fetch_consumer_tree_entry() {
  local vp_path="$1"
  local truncated entry tree_sha
  resolve_consumer_compare_ref || return 1
  tree_sha=$(resolve_consumer_compare_tree) || return 1
  CONSUMER_TREE_CACHE="$COMMIT_FILES_CACHE_DIR/consumer-tree.json"
  if [ ! -s "$CONSUMER_TREE_CACHE" ]; then
    if ! gh_pat api "repos/$OWNER/$NAME/git/trees/$tree_sha?recursive=1" \
        > "$CONSUMER_TREE_CACHE.tmp" 2>/dev/null; then
      rm -f "$CONSUMER_TREE_CACHE.tmp"
      return 1
    fi
    mv "$CONSUMER_TREE_CACHE.tmp" "$CONSUMER_TREE_CACHE"
  fi
  truncated=$(jq -r '.truncated // false' "$CONSUMER_TREE_CACHE" 2>/dev/null) || return 1
  [ "$truncated" = "false" ] || return 1
  entry=$(jq -r --arg p "$vp_path" \
    '[.tree[]? | select(.path == $p) | .mode + " " + .type] | .[0] // ""' \
    "$CONSUMER_TREE_CACHE" 2>/dev/null) || return 1
  [ -n "$entry" ] || return 1
  printf '%s' "$entry"
}

# expected_source_tree_entry <mergepath-src-rel> — echo the tree entry
# ("100644 blob" / "100755 blob") the consumer's file must carry, derived
# from the mergepath source. Mirrors verify-propagation-pr.sh exactly:
# prefer the COMMITTED git mode (`git ls-tree HEAD`) when
# REPO_ROOT_FOR_MANIFEST is a git checkout (always so in production —
# the on-disk exec bit can drift from the recorded git mode); fall back
# to the on-disk exec bit only for non-git fixture trees. Fails closed
# (non-zero) unless the source resolves to a regular-file blob — a
# symlink/submodule source is a misconfiguration, not a comparable
# entry.
expected_source_tree_entry() {
  local src_rel="$1"
  local entry=""
  if [ -d "$REPO_ROOT_FOR_MANIFEST/.git" ] || [ -f "$REPO_ROOT_FOR_MANIFEST/.git" ]; then
    entry=$(git -C "$REPO_ROOT_FOR_MANIFEST" ls-tree HEAD -- "$src_rel" 2>/dev/null \
      | awk '{print $1, $2}')
  elif [ -f "$REPO_ROOT_FOR_MANIFEST/$src_rel" ]; then
    if [ -x "$REPO_ROOT_FOR_MANIFEST/$src_rel" ]; then
      entry="100755 blob"
    else
      entry="100644 blob"
    fi
  fi
  case "$entry" in
    "100644 blob"|"100755 blob") printf '%s' "$entry"; return 0 ;;
    *) return 1 ;;
  esac
}

# committed_source_content <mergepath-src-rel> <out-file> — write the
# mergepath SOURCE bytes AT THE COMMITTED HEAD into <out-file> (#616
# finding 3510442268). The byte-compare (and the templated render input)
# must read the same committed state the other two gates read — the
# tree-entry gate (`git ls-tree HEAD`) and the upstream-evidence gate
# (`git log`) — so uncommitted working-tree edits NEVER count as
# propagation sources: a consumer byte-matching a local edit that has
# not been committed (and so cannot have propagated) must not resolve,
# and a dirty source file must not mask a genuine committed match.
# Mirrors expected_source_tree_entry's git detection exactly: a non-git
# fixture tree falls back to the on-disk file, the same fallback the
# mode/type check uses. Non-zero (fail closed) when the path is absent
# from HEAD (e.g. an uncommitted new file) or, in the fallback, from
# the fixture tree.
committed_source_content() {
  local src_rel="$1" out="$2"
  if [ -d "$REPO_ROOT_FOR_MANIFEST/.git" ] || [ -f "$REPO_ROOT_FOR_MANIFEST/.git" ]; then
    git -C "$REPO_ROOT_FOR_MANIFEST" show "HEAD:$src_rel" > "$out" 2>/dev/null
  elif [ -f "$REPO_ROOT_FOR_MANIFEST/$src_rel" ]; then
    cat "$REPO_ROOT_FOR_MANIFEST/$src_rel" > "$out" 2>/dev/null
  else
    return 1
  fi
}

# committed_manifest_file — echo the path of a .mergepath-sync.yml
# snapshot AT THE COMMITTED HEAD (#616 finding 3510689518). The
# templated arm's render INPUTS — the consumer facts, the consumer-name
# lookup, and the dest→source templated-entry mapping — must come from
# the same committed state the template bytes come from
# (committed_source_content): with a DIRTY working-tree manifest, an
# uncommitted fact or templated-entry edit could render output the
# consumer happens to match, resolving a thread as verified-propagation
# even though the COMMITTED manifest that could actually have propagated
# renders different bytes. Materialized once per run under
# COMMIT_FILES_CACHE_DIR (a file, so the snapshot survives the
# verification command-substitution subshells); mirrors
# committed_source_content's git detection exactly — a non-git fixture
# tree falls back to the on-disk manifest, the same fallback the source
# reads use. Non-zero (fail closed) when the manifest is absent from
# HEAD (or, in the fallback, from the fixture tree).
#
# NB: the ROUTING predicates (path_matches_canonical_entry /
# path_matches_templated_dest) intentionally keep reading the
# working-tree manifest (see the REPO_ROOT_FOR_MANIFEST note above) —
# routing alone never resolves; only the verification inputs here are
# resolution evidence.
committed_manifest_file() {
  local snap="$COMMIT_FILES_CACHE_DIR/committed-manifest.yml"
  if [ -s "$snap" ]; then
    printf '%s' "$snap"
    return 0
  fi
  if [ -d "$REPO_ROOT_FOR_MANIFEST/.git" ] || [ -f "$REPO_ROOT_FOR_MANIFEST/.git" ]; then
    if ! git -C "$REPO_ROOT_FOR_MANIFEST" show "HEAD:.mergepath-sync.yml" \
        > "$snap.tmp" 2>/dev/null; then
      rm -f "$snap.tmp"
      return 1
    fi
    mv "$snap.tmp" "$snap"
    printf '%s' "$snap"
    return 0
  fi
  if [ -f "$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml" ]; then
    printf '%s' "$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml"
    return 0
  fi
  return 1
}

# verify_consumer_tree_entry <consumer-path> <mergepath-src-rel> — the
# #616 (finding 3510170883) mode/type gate, mirroring the tree-entry
# check in scripts/workflow/verify-propagation-pr.sh: byte equality is
# necessary but not sufficient — a chmod flip or a symlink swap keeps
# the raw bytes identical while changing the consumer's on-disk file
# behavior, and the real propagation verifier rejects exactly that. The
# consumer tree entry at the compared ref must be a regular blob whose
# mode matches the mergepath source's committed mode (100644/100755; a
# symlink is mode 120000 even though its git type is blob, so the
# mode+type tuple catches the swap). stdout: a one-line reason on
# non-zero. Exit: 0 parity, 1 mismatch (drift-shaped — not a faithful
# mirror), 2 lookup failure (fail closed).
verify_consumer_tree_entry() {
  local vp_path="$1" src_rel="$2"
  local expected consumer_entry
  if ! expected=$(expected_source_tree_entry "$src_rel"); then
    echo "unsupported/absent mergepath source tree entry for $src_rel (expected a regular 100644/100755 blob)"
    return 2
  fi
  if ! consumer_entry=$(fetch_consumer_tree_entry "$vp_path"); then
    echo "could not read the consumer tree entry for $vp_path at the compared ref (git trees API failure, truncated listing, or path absent)"
    return 2
  fi
  if [ "$consumer_entry" != "$expected" ]; then
    echo "consumer tree entry for $vp_path is [$consumer_entry], expected [$expected] from the mergepath source (mode/type drift — chmod flip or symlink swap; not a faithful mirror)"
    return 1
  fi
  return 0
}

# upstream_fix_evidence <mergepath-src-rel> <floor-iso> — the #616
# (finding 3510170879) upstream-fix evidence gate. A byte-match only
# proves the consumer mirrors the CURRENT mergepath source; it does not
# prove the upstream finding was ever fixed — a never-applied follow-up
# whose consumer already mirrors the still-problematic canonical file
# must NOT be resolved and buried. Evidence = the local mergepath
# checkout (REPO_ROOT_FOR_MANIFEST, required to be a git work tree) has
# a commit touching <mergepath-src-rel> STRICTLY NEWER than <floor-iso>
# (the staleness floor the caller derives via latest_nonagent_created —
# the latest bot/reviewer re-raise, floored at the finding's createdAt).
# The commit timestamp is rendered as UTC ISO-8601 Z so the strictly-
# greater comparison is the same lexicographic-chronological compare the
# staleness machinery uses. Exit 0 = evidence present; non-zero = no
# evidence (missing floor, non-git checkout, no commit touching the
# source — e.g. shallow-clone truncation or an uncommitted working-tree
# fix — or the latest commit does not post-date the floor).
# DELIBERATE BIAS (documented in the header): an upstream fix that
# PRE-dates the finding also fails this gate — conservative; the thread
# stays deferred and resurfaces, and the operator can resolve manually
# with evidence.
upstream_fix_evidence() {
  local src_rel="$1" floor_iso="$2"
  local commit_iso
  [ -n "$floor_iso" ] || return 1
  git -C "$REPO_ROOT_FOR_MANIFEST" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || return 1
  commit_iso=$(TZ=UTC git -C "$REPO_ROOT_FOR_MANIFEST" log -1 \
    --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd -- "$src_rel" \
    2>/dev/null) || commit_iso=""
  [ -n "$commit_iso" ] || return 1
  [ "$commit_iso" \> "$floor_iso" ]
}

# manifest_consumer_name_for_repo — resolve (once) the manifest consumer
# NAME whose .repo slug equals $REPO, needed to load the consumer's
# facts for the templated re-render. Reads the COMMITTED manifest
# snapshot (#616 finding 3510689518), the same committed state the
# template bytes come from. Cached; non-zero (fail closed) when the
# manifest is absent from HEAD, yq is unavailable, or $REPO is not a
# declared consumer.
MANIFEST_CONSUMER_NAME=""
MANIFEST_CONSUMER_NAME_FETCHED=false
manifest_consumer_name_for_repo() {
  if ! $MANIFEST_CONSUMER_NAME_FETCHED; then
    MANIFEST_CONSUMER_NAME_FETCHED=true
    local manifest
    manifest=$(committed_manifest_file) || manifest=""
    if [ -n "$manifest" ] && [ -f "$manifest" ] && command -v yq >/dev/null 2>&1; then
      MANIFEST_CONSUMER_NAME=$(MP_VP_REPO="$REPO" yq -r '
        .consumers[] | select(.repo == env(MP_VP_REPO)) | .name
      ' "$manifest" 2>/dev/null | head -1) || MANIFEST_CONSUMER_NAME=""
      [ "$MANIFEST_CONSUMER_NAME" = "null" ] && MANIFEST_CONSUMER_NAME=""
    fi
  fi
  [ -n "$MANIFEST_CONSUMER_NAME" ]
}

# manifest_templated_source_for_dest <dest> <consumer_name> — echo the
# SOURCE template path of the templated manifest entry whose dest is
# <dest> AND whose consumers scope includes <consumer_name> (or is the
# scalar `all`). Consumer scoping matters: two templated entries can
# legitimately share one dest with disjoint consumer lists (the live
# ESM/CJS eslint.config.js pair). Two yq passes mirror
# fetch_manifest_templated_dests (mikefarah/yq rejects the inline
# if/then/else that would branch on the consumers tag in one pass); the
# seq-membership check runs in bash with the same anchored comma-grep
# path_matches_templated_dest uses. Reads the COMMITTED manifest
# snapshot (#616 finding 3510689518) so an uncommitted templated-entry
# edit never redirects the byte-compare source. Non-zero (fail closed)
# on no match, missing manifest, or missing yq.
manifest_templated_source_for_dest() {
  local vp_dest="$1" consumer_name="$2"
  local manifest
  manifest=$(committed_manifest_file) || return 1
  [ -f "$manifest" ] || return 1
  command -v yq >/dev/null 2>&1 || return 1
  local src rows line src_field names
  # Pass 1 — scalar `consumers: all` (every consumer is in scope).
  src=$(MP_VP_DEST="$vp_dest" yq -r '
    .paths[]
    | select(.type == "templated")
    | select((.dest // .path) == env(MP_VP_DEST))
    | select(.consumers == "all")
    | (.source // .path)
  ' "$manifest" 2>/dev/null | head -1) || src=""
  if [ -n "$src" ] && [ "$src" != "null" ]; then
    printf '%s' "$src"
    return 0
  fi
  # Pass 2 — sequence consumers: emit source + name list, membership in
  # bash.
  rows=$(MP_VP_DEST="$vp_dest" yq -r '
    .paths[]
    | select(.type == "templated")
    | select((.dest // .path) == env(MP_VP_DEST))
    | select(.consumers | tag == "!!seq")
    | (.source // .path) + "\t" + (.consumers | join(","))
  ' "$manifest" 2>/dev/null) || rows=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    src_field="${line%%$'\t'*}"
    names="${line#*$'\t'}"
    if printf ',%s,' "$names" | grep -qF ",$consumer_name,"; then
      printf '%s' "$src_field"
      return 0
    fi
  done <<< "$rows"
  return 1
}

# derive_routing_class <thread_json> — ROUTING-ONLY classification for
# --resolve-verified-propagation (#616, Codex finding 3509734391).
# Pure PATH predicate: emits `canonical-coverage` when the anchored path
# is a manifest canonical/kit entry, `templated-render` when it is a
# templated entry's dest for this consumer, `not-routed` otherwise.
#
# The canonical branch matches CANONICAL/KIT entries only
# (path_matches_canonical_entry, NOT the broad path_matches_manifest) —
# a templated entry's `.path` is the mergepath SOURCE while the consumer
# receives `.dest`, so a consumer file coincidentally at a templated
# source path with matching bytes must not resolve as verified
# propagation (#616, Codex finding 3509930343). Templated routing goes
# by dest, below.
#
# Deliberately IGNORES recorded [mergepath-resolve: ...] markers, unlike
# derive_tag_class's default TAG ladder (whose step 0 honors a surface
# marker BEFORE the path checks). The mode's target population is exactly
# the previously-DEFERRED routing threads (the #562 backlog): a sync
# finding tagged [mergepath-resolve: deferred-to-followup] on an earlier
# deferral pass would, under the TAG ladder, classify as
# deferred-to-followup forever and be skipped as "not propagation-routed"
# even after the consumer content byte-matches — defeating the mode's
# main use case. Routing is a property of the PATH, not of the thread's
# reply history; the byte-compare (or the actioned-evidence upgrade in
# the mode gate) still decides the actual resolve.
derive_routing_class() {
  local thread_path
  thread_path=$(printf '%s' "$1" | jq -r '.path // ""')
  if path_matches_canonical_entry "$thread_path"; then
    echo "canonical-coverage"
    return
  fi
  if path_matches_templated_dest "$thread_path"; then
    echo "templated-render"
    return
  fi
  echo "not-routed"
}

# verify_propagation_content <class> <path> <floor-iso> — the #572
# verification: byte-compare at the compared ref, then the #616 gates
# (tree-entry parity + upstream-fix evidence). <floor-iso> is the
# thread's staleness floor (latest_nonagent_created over the COMPLETE
# comment list) the evidence gate compares against.
# stdout: a one-line detail message (the tag rationale on success, the
# skip reason otherwise). Exit status is the verdict:
#   0 — VERIFIED: the consumer's content at <path> (compared ref)
#       byte-matches mergepath's canonical source (canonical-coverage)
#       or the re-rendered template with this consumer's facts
#       (templated-render) — both read at the COMMITTED HEAD via
#       committed_source_content, never the working tree (#616 finding
#       3510442268) — the consumer tree entry's mode/type matches
#       the mergepath source, AND the source carries an upstream fix
#       commit newer than <floor-iso>. The thread may be resolved.
#   1 — DRIFT: the compare ran and the bytes differ (consumer drifted,
#       or the upstream fix has not propagated), or the bytes match but
#       the tree entry's mode/type does not (chmod flip / symlink swap —
#       not a faithful mirror, #616 finding 3510170883). Leave
#       unresolved.
#   2 — verification error (fail closed): manifest entry missing,
#       compare-ref/PR-state resolution failure, content fetch failure,
#       source absent from the committed mergepath HEAD, render
#       failure, facts/consumer-name missing, tree-entry lookup
#       failure, or libs/yq unavailable. Leave unresolved.
#   3 — NO UPSTREAM-FIX EVIDENCE (fail closed, #616 finding 3510170879):
#       the bytes (and tree entry) match, but the local mergepath
#       checkout has no commit touching the source strictly newer than
#       <floor-iso> — the match may mirror a still-problematic source.
#       Leave unresolved (stays deferred and resurfaces — safe).
verify_propagation_content() {
  local vp_class="$1" vp_path="$2" vp_floor="${3:-}"
  local consumer_tmp mp_src src_tmp rendered render_err render_rc consumer_name
  local vte_rc vte_msg
  case "$vp_class" in
    canonical-coverage|templated-render) : ;;
    *) echo "internal: unexpected class '$vp_class' reached verification"; return 2 ;;
  esac
  if [ -z "$vp_path" ] || [ "$vp_path" = "(no path)" ]; then
    echo "thread has no anchored file path to verify"
    return 2
  fi
  # mktemp failures (unwritable/full TMPDIR) must be a logged fail-closed
  # skip, not an ambiguous-redirect bash error (CodeRabbit on #616).
  if ! consumer_tmp=$(mktemp "${TMPDIR:-/tmp}/resolve-vp-consumer.XXXXXX"); then
    echo "mktemp failed for consumer content (TMPDIR unwritable or full?)"
    return 2
  fi
  if ! fetch_consumer_content "$vp_path" "$consumer_tmp"; then
    rm -f "$consumer_tmp"
    echo "could not fetch $REPO:$vp_path at the compared ref (${CONSUMER_COMPARE_REF_KIND:-unresolved PR state or default-branch tip}; contents API)"
    return 2
  fi

  if [ "$vp_class" = "canonical-coverage" ]; then
    # Re-check manifest membership. The #616 mode gate derives the class
    # from this same predicate (derive_routing_class), so this is
    # belt-and-braces for any future caller whose class arrives another
    # way (e.g. a recorded marker): the byte-compare source must be a
    # real canonical/kit entry in THIS manifest — templated sources are
    # excluded (#616, Codex finding 3509930343).
    if ! path_matches_canonical_entry "$vp_path"; then
      rm -f "$consumer_tmp"
      echo "no canonical/kit entry in .mergepath-sync.yml covers $vp_path"
      return 2
    fi
    # #616 finding 3510442268: compare against the COMMITTED HEAD bytes
    # (git show), not the working-tree file — the tree-entry and
    # upstream-evidence gates below read HEAD, and an uncommitted local
    # edit cannot have propagated.
    if ! src_tmp=$(mktemp "${TMPDIR:-/tmp}/resolve-vp-src.XXXXXX"); then
      rm -f "$consumer_tmp"
      echo "mktemp failed for committed source content (TMPDIR unwritable or full?)"
      return 2
    fi
    if ! committed_source_content "$vp_path" "$src_tmp"; then
      rm -f "$consumer_tmp" "$src_tmp"
      echo "canonical source $vp_path is missing from the committed mergepath HEAD (uncommitted working-tree files never count as propagation sources)"
      return 2
    fi
    if cmp -s "$src_tmp" "$consumer_tmp"; then
      rm -f "$consumer_tmp" "$src_tmp"
      # #616 finding 3510170883: byte equality is necessary, not
      # sufficient — the tree entry's mode/type must match too.
      vte_rc=0
      vte_msg=$(verify_consumer_tree_entry "$vp_path" "$vp_path") || vte_rc=$?
      if [ "$vte_rc" -ne 0 ]; then
        echo "$vte_msg"
        return "$vte_rc"
      fi
      # #616 finding 3510170879: require an upstream fix commit newer
      # than the finding's staleness floor before resolving.
      if ! upstream_fix_evidence "$vp_path" "$vp_floor"; then
        echo "byte-match without upstream-fix evidence: no commit in the local mergepath checkout touches $vp_path strictly after the finding floor (${vp_floor:-unknown}) — the mirrored source may still carry the flagged issue"
        return 3
      fi
      echo "consumer content at $vp_path byte-matches the mergepath canonical source; propagation verified."
      return 0
    fi
    rm -f "$consumer_tmp" "$src_tmp"
    echo "consumer content at $vp_path does NOT byte-match the mergepath canonical source (drifted, or the upstream fix has not propagated)"
    return 1
  fi

  # templated-render — consumer facts + source lookup, then the shared
  # render engine.
  if ! manifest_consumer_name_for_repo; then
    rm -f "$consumer_tmp"
    echo "cannot resolve a consumer name for $REPO in .mergepath-sync.yml (facts unavailable)"
    return 2
  fi
  consumer_name="$MANIFEST_CONSUMER_NAME"
  if ! mp_src=$(manifest_templated_source_for_dest "$vp_path" "$consumer_name"); then
    rm -f "$consumer_tmp"
    echo "no templated manifest entry maps dest $vp_path for consumer $consumer_name"
    return 2
  fi
  # #616 finding 3510442268: render the COMMITTED HEAD template bytes
  # (git show), not the working-tree file — same committed-state rule as
  # the canonical arm; an uncommitted template edit cannot have
  # propagated.
  if ! src_tmp=$(mktemp "${TMPDIR:-/tmp}/resolve-vp-src.XXXXXX"); then
    rm -f "$consumer_tmp"
    echo "mktemp failed for committed source content (TMPDIR unwritable or full?)"
    return 2
  fi
  if ! committed_source_content "$mp_src" "$src_tmp"; then
    rm -f "$consumer_tmp" "$src_tmp"
    echo "templated source $mp_src is missing from the committed mergepath HEAD (uncommitted working-tree files never count as propagation sources)"
    return 2
  fi
  if [ ! -r "$VP_FACTS_HELPER" ] || [ ! -r "$VP_TEMPLATE_LIB" ]; then
    rm -f "$consumer_tmp" "$src_tmp"
    echo "render libs missing (need scripts/lib/manifest-fact-helpers.sh + scripts/lib/template-substitution.sh)"
    return 2
  fi
  # #616 finding 3510689518: the facts fed to the render must come from
  # the COMMITTED manifest — the same committed state as the template
  # bytes above — never the working-tree .mergepath-sync.yml, whose
  # uncommitted fact edits cannot have propagated.
  local manifest_snapshot
  if ! manifest_snapshot=$(committed_manifest_file); then
    rm -f "$consumer_tmp" "$src_tmp"
    echo ".mergepath-sync.yml is missing from the committed mergepath HEAD (uncommitted manifest state never feeds the verification render)"
    return 2
  fi
  if ! rendered=$(mktemp "${TMPDIR:-/tmp}/resolve-vp-rendered.XXXXXX"); then
    rm -f "$consumer_tmp" "$src_tmp"
    echo "mktemp failed for render output (TMPDIR unwritable or full?)"
    return 2
  fi
  if ! render_err=$(mktemp "${TMPDIR:-/tmp}/resolve-vp-render-err.XXXXXX"); then
    rm -f "$consumer_tmp" "$src_tmp" "$rendered"
    echo "mktemp failed for render stderr (TMPDIR unwritable or full?)"
    return 2
  fi
  render_rc=0
  # Subshell render — identical shape to verify-propagation-pr.sh: facts
  # exports stay contained, and `|| exit $?` propagates a fail-closed
  # export rc (set -e is suppressed on the left of `||`; see #457).
  (
    # shellcheck source=lib/manifest-fact-helpers.sh
    . "$VP_FACTS_HELPER" || exit 2
    # shellcheck source=lib/template-substitution.sh
    . "$VP_TEMPLATE_LIB" || exit 2
    export_consumer_facts "$consumer_name" "$manifest_snapshot" || exit $?
    # $src_tmp carries the COMMITTED HEAD bytes of $mp_src (#616
    # finding 3510442268); render errors are re-labeled with the real
    # source path in the wrapper message below.
    template_substitution::render "$src_tmp"
  ) > "$rendered" 2> "$render_err" || render_rc=$?
  if [ "$render_rc" != "0" ]; then
    if [ -s "$render_err" ]; then
      sed 's/^/    /' "$render_err" >&2
    fi
    rm -f "$consumer_tmp" "$src_tmp" "$rendered" "$render_err"
    echo "templated re-render failed for source $mp_src (consumer=$consumer_name, rc=$render_rc)"
    return 2
  fi
  rm -f "$render_err" "$src_tmp"
  if cmp -s "$rendered" "$consumer_tmp"; then
    rm -f "$consumer_tmp" "$rendered"
    # #616 finding 3510170883: the rendered dest must inherit the
    # TEMPLATE SOURCE's committed mode (mode+type only — the render
    # changes content by design), mirroring the templated arm of
    # verify-propagation-pr.sh.
    vte_rc=0
    vte_msg=$(verify_consumer_tree_entry "$vp_path" "$mp_src") || vte_rc=$?
    if [ "$vte_rc" -ne 0 ]; then
      echo "$vte_msg"
      return "$vte_rc"
    fi
    # #616 finding 3510170879: evidence gate on the TEMPLATE SOURCE —
    # the mergepath path an upstream fix for a templated finding lands
    # on. (A facts-only change in .mergepath-sync.yml does not count as
    # evidence — conservative, per the documented bias.)
    if ! upstream_fix_evidence "$mp_src" "$vp_floor"; then
      echo "byte-match without upstream-fix evidence: no commit in the local mergepath checkout touches $mp_src strictly after the finding floor (${vp_floor:-unknown}) — the mirrored render may still carry the flagged issue"
      return 3
    fi
    echo "consumer content at $vp_path byte-matches the re-rendered template $mp_src (consumer=$consumer_name); propagation verified."
    return 0
  fi
  rm -f "$consumer_tmp" "$rendered"
  echo "consumer content at $vp_path does NOT byte-match the re-rendered template $mp_src (consumer=$consumer_name)"
  return 1
}

# derive_tag_class — given the thread JSON (one line of UNRESOLVED),
# return one of the rollup's class strings on stdout.
#
# Decision ladder (highest-confidence first; matches the
# spec § Class taxonomy from issue #305):
#   1. canonical-coverage     anchored path is in the manifest
#   1b. templated-render      anchored path is a templated dest
#                             (#323) — same "mergepath concern" class
#                             as canonical-coverage but on the
#                             templated surface; emitted only when the
#                             path is NOT also matched by 1 (the dests
#                             never appear as .path entries by
#                             construction — source ≠ dest is the
#                             point — so the two branches don't
#                             overlap in practice).
#   2. addressed-elsewhere    agent-author commit after createdAt
#                             touching the anchored file
#   3. rebuttal-recorded      ≥30-char agent-author reply on thread
#   4. nitpick-noted          severity is Nitpick/Trivial/P3
#   5. deferred-to-followup   fallback
#
# Why canonical-coverage wins over addressed-elsewhere: a finding on
# a propagated canonical path is structurally a mergepath concern;
# the rollup should route it to mergepath regardless of whether the
# local PR happened to also touch the file. (Addressed-elsewhere is
# stronger evidence for a one-off finding but doesn't say anything
# about WHERE the durable fix should live.)
derive_tag_class() {
  local thread_json="$1"
  # skip_routing (#565): when non-empty (the --resolve-actioned GATE path),
  # the routing-only classes canonical-coverage / templated-render are NOT
  # emitted — neither from a recorded marker (step 0) nor from the path
  # checks (steps 1 / 1b) — so the ladder falls through to real ACTION
  # evidence (addressed-elsewhere / rebuttal-recorded). The default (empty)
  # keeps the routing-first ladder for the --auto-resolve-bots tag / daily
  # rollup, where routing context is wanted. This decouples the actioned
  # GATE (needs proof of action) from the routing TAG (proof of where a fix
  # belongs): a fresh canonical-path finding is still NOT actioned, but a
  # canonical-path thread that WAS fixed or rebutted now is (nathanpayne-codex
  # P1 CHANGES_REQUESTED on #565 — routing was masking real action evidence).
  local skip_routing="${2:-}"
  local thread_path
  local thread_body
  thread_path=$(printf '%s' "$thread_json" | jq -r '.path // ""')
  thread_body=$(printf '%s' "$thread_json" | jq -r '.body // ""')
  # NB: the original-finding timestamp (.created) is intentionally NOT used
  # directly for the addressed-elsewhere check — that compares against the
  # LATEST bot/reviewer comment via latest_nonagent_created (#565).

  # 0. honor an existing [mergepath-resolve: <class>] marker (#564, Codex
  # P2 + CodeRabbit Major on #565). A prior resolve attempt — e.g. a
  # deferred-to-followup that was tagged but whose resolve readback-failed,
  # or a thread re-opened after tagging — leaves an agent-authored marker
  # reply on the thread. That marker records an explicit classification
  # decision and is preferred over the heuristic ladder below: without it,
  # the rebuttal-recorded step (#3) mis-reads the marker reply itself (it is
  # ≥30 chars and agent-authored) as a rebuttal. Mirrors
  # daily-feedback-rollup-helpers.sh, which also prefers the recorded tag.
  #
  # STALENESS GUARD (CodeRabbit Major on #565): a marker is authoritative
  # only as the agent's "last word". An ACTIONED marker followed by fresh
  # non-agent (bot/reviewer) feedback is stale — honoring it would resolve a
  # thread the bot just re-raised — so it is honored ONLY when it post-dates
  # the most recent non-agent comment; otherwise it falls through to the
  # ladder (which applies the same last-word rule to rebuttals). A SURFACE
  # marker (nitpick-noted / deferred-to-followup) is honored regardless,
  # because it only ever causes a skip — the fail-closed/safe outcome — even
  # if later replies exist. Most-recent valid marker wins; an unrecognized
  # class is ignored. `last_nonagent_idx` is reused by step 3.
  local recorded_class="" rc_count rc_i rc_login rc_body rc_tag
  local last_marker_idx=-1 last_nonagent_idx=-1
  rc_count=$(printf '%s' "$thread_json" | jq '.all_comments | length' 2>/dev/null || echo 0)
  rc_i=0
  while [ "$rc_i" -lt "$rc_count" ]; do
    rc_login=$(printf '%s' "$thread_json" | jq -r ".all_comments[$rc_i].author.login // \"\"")
    if is_agent_author_local "$rc_login"; then
      rc_body=$(printf '%s' "$thread_json" | jq -r ".all_comments[$rc_i].body // \"\"")
      rc_tag=$(printf '%s' "$rc_body" \
        | sed -n 's/.*\[mergepath-resolve:[[:space:]]*\([a-z][a-z-]*\)[[:space:]]*\].*/\1/p' | head -1)
      if [ -n "$rc_tag" ]; then recorded_class="$rc_tag"; last_marker_idx=$rc_i; fi
    else
      last_nonagent_idx=$rc_i
    fi
    rc_i=$((rc_i + 1))
  done
  # Honor a recorded marker ONLY in the TAG path (default). The GATE path
  # (--resolve-actioned / skip_routing) treats ANY marker as rationale only
  # and falls through to re-derive fresh evidence below — so a stale marker
  # (from an earlier deferral, a readback-failed resolve, or the older weak
  # heuristic this patch replaces) can never resolve a thread without
  # re-checking the fix commit / rebuttal against the latest comments. This
  # closes the marker-staleness cluster on #565 (re-verify actioned markers;
  # let later fixes override stale surface markers; don't let stale deferral
  # tags mask later rebuttals). `last_nonagent_idx` is reused by step 3.
  if [ -z "$skip_routing" ]; then
    case "$recorded_class" in
      addressed-elsewhere|rebuttal-recorded)
        # Genuinely-actioned marker: honor only if it is the agent's last
        # word, so a stale marker followed by fresh bot feedback cannot
        # resolve a re-raised thread.
        if [ "$last_marker_idx" -gt "$last_nonagent_idx" ]; then
          echo "$recorded_class"
          return
        fi ;;
      canonical-coverage|templated-render|nitpick-noted|deferred-to-followup)
        # Routing / surface markers: honoring even a stale one only routes or
        # skips (never a wrong resolve), so the TAG path honors it
        # unconditionally to keep the recorded class flowing to the rollup.
        echo "$recorded_class"
        return ;;
    esac
  fi

  # 1. canonical-coverage (routing — skipped in the GATE path so real action
  # evidence on a canonical path is not masked, #565).
  if [ -z "$skip_routing" ] && path_matches_manifest "$thread_path"; then
    echo "canonical-coverage"
    return
  fi

  # 1b. templated-render (#323) — path matches a templated entry's
  # dest. Same "mergepath concern" routing as canonical-coverage; the
  # rendered output came from a template in mergepath, so the fix
  # should land in mergepath too. We don't (and can't, from here)
  # re-run verify-propagation-pr.sh to confirm the bytes match — but
  # the path predicate alone is the right signal: if a thread is
  # anchored on the templated dest, the durable fix is either in
  # mergepath's template or in the consumer's facts:* block.
  if [ -z "$skip_routing" ] && path_matches_templated_dest "$thread_path"; then
    echo "templated-render"
    return
  fi

  # 2. addressed-elsewhere — an agent-authored commit that BOTH (a)
  # post-dates the latest bot/reviewer comment (the #565 staleness guard)
  # AND (b) actually TOUCHES the anchored file. Both are required.
  #
  # The earlier form gated on two independent PR-level facts — "the anchored
  # file is in the PR's overall changed-file list" AND "some agent commit
  # post-dates the re-raise" — which do not compose: an agent commit on an
  # UNRELATED file could satisfy the date check while a stale/earlier commit
  # was the only one touching the anchored file, so live feedback got
  # resolved (nathanpayne-codex CHANGES_REQUESTED on #565). The PR /commits
  # cache has no per-commit file list, so confirm per commit via
  # commit_touches_file (cached). Fail closed: a commit whose files cannot
  # be read does not qualify, and a pathless thread cannot be proven here.
  fetch_pr_tag_data
  local last_nonagent_created
  last_nonagent_created=$(latest_nonagent_created "$thread_json")
  if [ -n "$last_nonagent_created" ] && [ -n "$PR_COMMITS_CACHE" ] \
     && [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
    # Cheap PR-level pre-filter: if the PR's overall changed-file list is
    # known and does NOT include the anchored file, no commit touched it —
    # skip the per-commit fetches. When the list is empty/unavailable we
    # cannot pre-filter, so fall through to the authoritative per-commit
    # check below (which is itself fail-closed).
    local pr_touched_file=true
    if [ -n "$PR_FILES_CACHE" ] && [ "$PR_FILES_CACHE" != "[]" ]; then
      if ! printf '%s' "$PR_FILES_CACHE" \
           | jq -e --arg p "$thread_path" 'any(. == $p)' >/dev/null 2>&1; then
        pr_touched_file=false
      fi
    fi
    if $pr_touched_file; then
      local commit_count
      commit_count=$(printf '%s' "$PR_COMMITS_CACHE" | jq 'length' 2>/dev/null || echo 0)
      local i=0
      while [ "$i" -lt "$commit_count" ]; do
        local c_login
        local c_date
        local c_sha
        c_login=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].login // \"\"")
        c_date=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].date // \"\"")
        c_sha=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].sha // \"\"")
        # Order matters: cheap date/identity checks short-circuit BEFORE the
        # per-commit file fetch, so we only fetch files for an agent commit
        # that post-dates the re-raise.
        if [ -n "$c_login" ] && [ -n "$c_date" ] \
           && [ "$c_date" \> "$last_nonagent_created" ] \
           && is_agent_author_local "$c_login" \
           && commit_touches_file "$c_sha" "$thread_path"; then
          echo "addressed-elsewhere"
          return
        fi
        i=$((i + 1))
      done
    fi
  fi

  # 3. rebuttal-recorded — ≥30-char reply from an agent author.
  # Skip index 0 (the original review comment).
  local reply_count
  reply_count=$(printf '%s' "$thread_json" | jq '.all_comments | length' 2>/dev/null || echo 0)
  if [ "$reply_count" -gt 1 ]; then
    # Only replies AFTER the bot's most recent comment count (CodeRabbit
    # Major on #565): a rebuttal that predates a later bot re-raise is stale
    # and must not mark the thread actioned. last_nonagent_idx was computed
    # in step 0. Start the scan just past the last non-agent comment (but at
    # least index 1, to always skip the original finding at index 0).
    local k=$((last_nonagent_idx + 1))
    [ "$k" -lt 1 ] && k=1
    while [ "$k" -lt "$reply_count" ]; do
      local r_login
      local r_body
      local r_body_len
      r_login=$(printf '%s' "$thread_json" | jq -r ".all_comments[$k].author.login // \"\"")
      r_body=$(printf '%s' "$thread_json" | jq -r ".all_comments[$k].body // \"\"")
      r_body_len=${#r_body}
      # Skip our own [mergepath-resolve: ...] marker replies — a resolution
      # marker is not a rebuttal (step 0 already honored a recognized one;
      # this also covers an unrecognized-class marker). Codex P2 on #565.
      case "$r_body" in
        *"[mergepath-resolve:"*) k=$((k + 1)); continue ;;
      esac
      if [ -n "$r_login" ] && [ "$r_body_len" -ge 30 ] && is_agent_author_local "$r_login"; then
        echo "rebuttal-recorded"
        return
      fi
      k=$((k + 1))
    done
  fi

  # 4. nitpick-noted
  local sev
  sev=$(classify_severity_local "$thread_body")
  case "$sev" in
    Nitpick|Trivial|P3) echo "nitpick-noted"; return ;;
  esac

  # 5. fallback
  echo "deferred-to-followup"
}

# class_is_actioned <class> — exit 0 if the class is a DEMONSTRABLY-ACTIONED
# class, 1 otherwise. This is the gate for --resolve-actioned (#564): only
# resolve threads whose fix or accepted rebuttal is demonstrable from the
# current PR state, leaving the rest unresolved so the weekly sweep keeps
# surfacing them.
#
# Only two classes prove ACTION on this PR:
#   addressed-elsewhere  an agent commit that touches the anchored file and
#                        post-dates the latest re-raise (verified per-commit)
#   rebuttal-recorded    a substantive agent rebuttal that post-dates the
#                        latest re-raise on the thread
#
# This is intentionally STRICTER than (a subset of) the rollup's skip-set in
# scripts/lib/daily-feedback-rollup-helpers.sh `tag_class_action`, which also
# skips canonical-coverage and templated-render. Those are ROUTING classes —
# derived from path/manifest membership alone, before any fix-commit or
# rebuttal evidence. Routing tells you WHERE a durable fix belongs (upstream
# in mergepath), NOT that one happened: a fresh, unfixed bot finding on a
# canonical path (e.g. scripts/resolve-pr-threads.sh is itself canonical)
# would classify as canonical-coverage. Treating that as actioned would
# resolve live, unactioned feedback — the exact failure #564 guards against
# (nathanpayne-codex P1 CHANGES_REQUESTED on #565). So routing classes are
# EXCLUDED from the actioned gate; --auto-resolve-bots / the daily rollup
# may still record canonical/templated context, but the actioned-only
# resolver must not equate routing with action. Unknown classes are NOT
# actioned — fail safe.
class_is_actioned() {
  case "$1" in
    addressed-elsewhere|rebuttal-recorded)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# synth_rationale <class> <thread_json> → one-line free-form rationale
# matching the class. Kept short (≤120 chars) so the reply stays
# compact in the GitHub UI. The classifier reads only the tag in
# brackets; the rationale is purely human-facing.
synth_rationale() {
  local class="$1"
  local thread_json="$2"
  local thread_path
  thread_path=$(printf '%s' "$thread_json" | jq -r '.path // ""')
  local short_sha=""
  case "$class" in
    addressed-elsewhere)
      # Surface the SHA of a commit that actually satisfies
      # derive_tag_class's predicate (agent-authored AND authoredDate >
      # the latest bot/reviewer comment). Re-run the SAME check here — using
      # the same last_nonagent_created floor (#565) — so the cited SHA
      # matches the one that triggered the classification rather than a
      # pre-thread or stale commit.
      local last_nonagent_created
      last_nonagent_created=$(latest_nonagent_created "$thread_json")
      local commit_count i
      commit_count=$(printf '%s' "$PR_COMMITS_CACHE" | jq 'length' 2>/dev/null || echo 0)
      i=0
      while [ "$i" -lt "$commit_count" ]; do
        local c_login c_date c_sha
        c_login=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].login // \"\"")
        c_date=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].date // \"\"")
        c_sha=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].sha // \"\"")
        if [ -n "$c_login" ] && [ -n "$c_date" ] \
           && { [ -z "$last_nonagent_created" ] || [ "$c_date" \> "$last_nonagent_created" ]; } \
           && is_agent_author_local "$c_login" \
           && commit_touches_file "$c_sha" "$thread_path"; then
          short_sha="$c_sha"
          break
        fi
        i=$((i + 1))
      done
      if [ -n "$short_sha" ] && [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
        echo "addressed by commit ${short_sha:0:7} (touching $thread_path)."
      elif [ -n "$short_sha" ]; then
        echo "addressed by commit ${short_sha:0:7}."
      else
        echo "addressed by a follow-up commit on this PR."
      fi
      ;;
    canonical-coverage)
      if [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
        echo "path $thread_path is propagated canonical content (.mergepath-sync.yml)."
      else
        echo "thread is on propagated canonical content (.mergepath-sync.yml)."
      fi
      ;;
    templated-render)
      # #323 — the dest is rendered from a mergepath template with
      # consumer facts. verify-propagation-pr.sh re-renders and
      # byte-compares as part of the propagation-lane gate; if a
      # thread persists on a templated dest, the durable fix lives in
      # mergepath's template or the consumer's facts:* block.
      if [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
        echo "$thread_path is a templated dest rendered from mergepath; fix belongs in the template or consumer facts."
      else
        echo "thread is on a templated dest rendered from mergepath; fix belongs in the template or consumer facts."
      fi
      ;;
    nitpick-noted)
      echo "nitpick/trivial severity; noted, no code change."
      ;;
    rebuttal-recorded)
      echo "agent rebuttal posted on thread; resolving."
      ;;
    deferred-to-followup|*)
      echo "deferred to follow-up; resolving for branch-protection conversation gate."
      ;;
  esac
}

# We also want to capture the SHA in PR_COMMITS_CACHE for the
# rationale — re-pull with .sha included. (Earlier fetch_pr_tag_data
# elided it to keep the cache small. Refetch in a backwards-compatible
# way: only add the column when the original fetch already populated.)
augment_pr_commits_with_sha() {
  $TAG_DATA_FETCHED || return 0
  # If already augmented (cache has .sha), skip.
  if printf '%s' "$PR_COMMITS_CACHE" | jq -e '.[0].sha // empty' >/dev/null 2>&1; then
    return 0
  fi
  # Same login fallback chain as fetch_pr_tag_data (#565 round 8):
  # .commit.author.name before the (often-unlinked) email so agent-authored
  # commits are recognized.
  #
  # #573 item 2: paginate via _fetch_paginated — the prior single
  # `?per_page=100` fetch capped this shim at 100 commits, so a
  # qualifying fix commit beyond page 1 of a large PR was invisible.
  # That truncation is fail-SAFE for the actioned gate (a missing
  # commit can only REMOVE addressed-elsewhere evidence, never add it —
  # the thread is just left unresolved), but it wrongly skipped
  # genuinely-actioned threads. Only overwrite the cache when the
  # refetch produced something, so a transient failure (which
  # _fetch_paginated maps to `[]`) cannot blank a populated cache.
  local refreshed
  refreshed=$(_fetch_paginated \
    "repos/$OWNER/$NAME/pulls/$PR_NUM/commits" \
    '[.[] | {sha: (.sha // ""), login: (.author.login // .commit.author.name // .commit.author.email // ""), date: (.commit.author.date // .commit.committer.date // "")}]')
  if [ -n "$refreshed" ] && [ "$refreshed" != "[]" ]; then
    PR_COMMITS_CACHE="$refreshed"
  fi
}

# post_tag_reply — emit a `[mergepath-resolve: <class>] <rationale>`
# reply on the thread via the GraphQL addPullRequestReviewThreadReply
# mutation. Logs and returns non-zero on failure; the caller should
# log a warning and proceed to the resolve mutation regardless.
#
# The mutation requires the `pullRequestReviewThreadId` (the same id
# resolveReviewThread takes) plus a body. The reply author follows
# the PAT used for the call — same identity verification as the
# resolve mutation, no separate gate needed.
post_tag_reply() {
  local thread_id="$1"
  local class="$2"
  local rationale="$3"
  local body
  body="[mergepath-resolve: $class] $rationale"
  # Suppress stdout (the mutation response is noise), but capture
  # stderr for failure-mode logging. The redirection order matters:
  # `2>&1 1>/dev/null` first dups stderr to stdout (so it lands in
  # the command substitution), then redirects the original stdout to
  # /dev/null. The reversed form (`>/dev/null 2>&1`) discards both
  # streams and leaves $err empty — see #shellcheck SC2327/SC2328.
  local err
  if ! err=$(gh_pat api graphql \
    -f query='mutation($id: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) {
        comment { id }
      }
    }' \
    -F id="$thread_id" \
    -F body="$body" \
    2>&1 1>/dev/null); then
    printf 'tag-reply mutation failed: %s\n' "$err" >&2
    return 1
  fi
  return 0
}

# auto-resolve-bots mode: resolve bot threads, leave human threads alone.
# Use process substitution (`< <(...)`) instead of `echo $UNRESOLVED | while`
# so the loop runs in the parent shell — counter increments survive past the
# loop and the trailing summary is accurate.
RESOLVED_COUNT=0
SKIPPED_HUMAN=0
SKIPPED_STALE=0
# #564 --resolve-actioned: threads skipped because their derived class is
# NOT demonstrably actioned (surface-set: nitpick-noted / deferred-to-
# followup). Left unresolved on purpose so the weekly sweep still surfaces
# them; counted so the exit code reflects that work remains.
SKIPPED_NOT_ACTIONED=0
# #573 item 2 --resolve-actioned: threads skipped because their comment
# list is TRUNCATED (>50 comments) and the full re-fetch failed — the
# staleness floor cannot be trusted, so the thread is left unresolved
# (fail closed) rather than classified on a window that may be missing
# the latest bot/reviewer re-raise. Counted into the exit-3 predicate.
SKIPPED_COMMENTS_INCOMPLETE=0
# #572 --resolve-verified-propagation skip counters, all in the exit-3
# predicate:
#   SKIPPED_NOT_PROPAGATION  the thread's class is not canonical-coverage /
#                            templated-render — this mode only handles
#                            routing-class threads (surface + actioned
#                            classes have their own modes).
#   SKIPPED_DRIFT            the byte-compare RAN and MISMATCHED — the
#                            consumer content drifted or the upstream fix
#                            has not propagated; left unresolved on purpose.
#   SKIPPED_VERIFY_ERROR     the verification could not run (manifest entry
#                            missing, compare-ref/PR-state resolution
#                            failure, fetch/render failure, tree-entry
#                            lookup failure, facts missing) — fail closed,
#                            left unresolved.
#   SKIPPED_NO_UPSTREAM_EVIDENCE
#                            the bytes (and tree entry) matched but the
#                            local mergepath checkout has no commit
#                            touching the source strictly newer than the
#                            finding's staleness floor (#616 finding
#                            3510170879) — the consumer may be mirroring a
#                            still-problematic source; fail closed, left
#                            unresolved (stays deferred and resurfaces).
SKIPPED_NOT_PROPAGATION=0
SKIPPED_DRIFT=0
SKIPPED_VERIFY_ERROR=0
SKIPPED_NO_UPSTREAM_EVIDENCE=0
WOULD_RESOLVE_COUNT=0
FAILED_COUNT=0
TAG_REPLY_POSTED=0
TAG_REPLY_FAILED=0
TAG_REPLY_SKIPPED=0
# #564 — post-resolve readback. RESOLVED_IDS collects the GraphQL node IDs
# of threads whose resolve mutation reported isResolved:true, so the
# consolidated readback after the loop can re-read each and confirm the
# state actually persisted. The loop runs in the parent shell (process
# substitution below), so a plain array survives past it. READBACK_FAILED
# counts threads that did NOT read back isResolved:true — a fail-closed
# signal that forces a non-zero exit.
RESOLVED_IDS=()
READBACK_FAILED=0
while IFS= read -r thread; do
  AUTHOR=$(echo "$thread" | jq -r .author)
  THREAD_ID=$(echo "$thread" | jq -r .id)
  PATH_=$(echo "$thread" | jq -r .path)
  EXCERPT=$(echo "$thread" | jq -r .excerpt)
  COMMIT_OID=$(echo "$thread" | jq -r .commit_oid)

  if ! [[ "$AUTHOR" =~ $BOT_LOGINS_RE ]]; then
    echo "  SKIP (non-bot author $AUTHOR): $PATH_"
    echo "    $EXCERPT"
    SKIPPED_HUMAN=$((SKIPPED_HUMAN + 1))
    continue
  fi

  # Current-HEAD check — applies to --auto-resolve-bots ONLY. The contract
  # there is "resolve only when the latest comment is on the current HEAD":
  # a thread anchored to an older commit means the agent's most recent push
  # has not been re-reviewed by the bot, so resolving it would force-clear
  # an unaddressed finding.
  #
  # --resolve-actioned BYPASSES this proxy (#565): pushing a fix commit
  # advances HEAD while the bot's last comment still points at the previous
  # commit, so this gate would skip a fixed-by-commit thread as "stale"
  # before derive_tag_class could see the fix. Instead, --resolve-actioned
  # relies on its stronger, direct evidence check (a fix commit touching the
  # anchored file AFTER the latest bot/reviewer comment, or a rebuttal after
  # the bot's last word) — so a later fix commit is recognized even when the
  # bot has not re-commented on the new HEAD.
  #
  # --resolve-verified-propagation ALSO bypasses it (#572): its evidence is
  # the consumer's content at the COMPARED REF (the PR's own head while the
  # PR is open, the default branch once closed/merged — #616 finding
  # 3510170875), not the bot comment's anchor commit, and its primary
  # target population is backlog threads on long-merged sync PRs — where
  # the PR-HEAD anchor proxy is meaningless.
  #
  # Codex r1 on PR #172 caught that the previous check
  # `if [ -n "$COMMIT_OID" ] && [ "$COMMIT_OID" != "$HEAD_OID" ]`
  # treated EMPTY commit_oid as "matches HEAD" → bot threads with no
  # commit linkage in the GraphQL response would be force-resolved
  # silently. The safe default is the opposite: missing oid is
  # treated as stale.
  if [ "$MODE" != "resolve-actioned" ] && [ "$MODE" != "resolve-verified-propagation" ] \
     && { [ -z "$COMMIT_OID" ] || [ "$COMMIT_OID" = "null" ] || [ "$COMMIT_OID" != "$HEAD_OID" ]; }; then
    if [ -z "$COMMIT_OID" ] || [ "$COMMIT_OID" = "null" ]; then
      reason="no commit linkage"
    else
      reason="latest comment on ${COMMIT_OID:0:7}, HEAD is ${HEAD_OID:0:7}"
    fi
    echo "  SKIP (stale: $reason): [$AUTHOR] $PATH_"
    echo "    Push a fix commit (or rebuttal reply) to re-trigger the bot, then retry."
    SKIPPED_STALE=$((SKIPPED_STALE + 1))
    continue
  fi

  # #564 --resolve-actioned: gate the resolve on demonstrable action.
  # Derive the thread's class BEFORE the dry-run / tag steps, but ONLY in
  # resolve-actioned mode — auto-resolve-bots keeps its existing behavior
  # (resolve every current-HEAD bot thread to clear the conversation gate;
  # the daily rollup re-surfaces deferrals), and in particular must NOT
  # make tag-data API calls on a --dry-run. Threads whose class is not in
  # the actioned skip-set are left unresolved so the weekly sweep keeps
  # surfacing them.
  thread_class=""
  thread_class_computed=false
  if [ "$MODE" = "resolve-actioned" ]; then
    fetch_pr_tag_data
    augment_pr_commits_with_sha
    # #573 item 2: the staleness floor (latest_nonagent_created) is only
    # trustworthy over the COMPLETE thread. If the enumeration's last-50
    # window truncated this thread, re-fetch every comment before
    # classifying; on ANY pagination failure, FAIL CLOSED — skip the
    # thread (left unresolved for the sweep) rather than classify on a
    # window that may be missing the latest bot/reviewer re-raise.
    if ! thread=$(complete_thread_comments "$thread"); then
      echo "  SKIP (comment list incomplete — pagination failed; failing closed): [$AUTHOR] $PATH_"
      echo "    $EXCERPT"
      echo "    The thread has more comments than one window returns and the full"
      echo "    re-fetch failed, so the latest re-raise may be invisible. Left"
      echo "    unresolved; retry, or resolve deliberately via --auto-resolve-bots."
      SKIPPED_COMMENTS_INCOMPLETE=$((SKIPPED_COMMENTS_INCOMPLETE + 1))
      continue
    fi
    # GATE path: classify with routing skipped, so a canonical/templated
    # thread that was actually fixed/rebutted resolves on its action
    # evidence, while a fresh routing-only finding still falls through to a
    # non-actioned class and is left for the sweep (#565).
    thread_class=$(derive_tag_class "$thread" skip-routing)
    thread_class_computed=true
    if ! class_is_actioned "$thread_class"; then
      echo "  SKIP (not demonstrably actioned: $thread_class): [$AUTHOR] $PATH_"
      echo "    $EXCERPT"
      echo "    Left unresolved so the weekly sweep still surfaces it. Fix or"
      echo "    rebut the finding, or defer it via --auto-resolve-bots --rationale."
      SKIPPED_NOT_ACTIONED=$((SKIPPED_NOT_ACTIONED + 1))
      continue
    fi
  fi

  # #572 --resolve-verified-propagation: gate the resolve on a byte-verified
  # propagation match. The gate runs in dry-run too (all reads, no writes)
  # so the would-resolve / would-skip preview is the real verdict — dry-run-
  # first is the operating contract.
  VERIFIED_RATIONALE=""
  if [ "$MODE" = "resolve-verified-propagation" ]; then
    # Same complete-thread precondition as --resolve-actioned (#573 item 2 /
    # #614): never classify on a truncated comment window — a hidden
    # re-raise or marker must not be invisible to the ladder. Fail closed.
    if ! thread=$(complete_thread_comments "$thread"); then
      echo "  SKIP (comment list incomplete — pagination failed; failing closed): [$AUTHOR] $PATH_"
      echo "    $EXCERPT"
      echo "    The thread has more comments than one window returns and the full"
      echo "    re-fetch failed, so the classification inputs are untrustworthy."
      echo "    Left unresolved; retry."
      SKIPPED_COMMENTS_INCOMPLETE=$((SKIPPED_COMMENTS_INCOMPLETE + 1))
      continue
    fi
    # Warm every cache in THIS shell before the classify/verify command-
    # substitution subshells (same subshell-cache rule as the tag path; the
    # subshells inherit warmed caches but cannot write back).
    fetch_pr_tag_data
    augment_pr_commits_with_sha
    fetch_manifest_canonical_paths
    fetch_manifest_templated_dests
    fetch_consumer_default_branch || true
    # Compare-ref resolution (#616 finding 3510170875) is cached here in
    # the parent shell so every verification subshell inherits one
    # PR-state read for the whole run; a failure stays cached and each
    # verify fails closed on it.
    resolve_consumer_compare_ref || true
    manifest_consumer_name_for_repo || true
    # Routing classification is a PURE PATH predicate (#616 finding
    # 3509734391): derive_routing_class checks manifest membership /
    # templated dests and IGNORES recorded surface markers, so a
    # previously-deferred [mergepath-resolve: deferred-to-followup] tag on
    # a sync finding never masks the routing check — resolving exactly
    # those previously-deferred canonical findings once propagation lands
    # IS this mode's main use case. Only canonical-coverage /
    # templated-render paths are this mode's population; everything else
    # skips here (surface threads on non-routed paths included).
    thread_class=$(derive_routing_class "$thread")
    case "$thread_class" in
      canonical-coverage|templated-render) : ;;
      *)
        echo "  SKIP (not propagation-routed): [$AUTHOR] $PATH_"
        echo "    $EXCERPT"
        echo "    --resolve-verified-propagation handles only threads anchored on a"
        echo "    manifest canonical/kit path or a templated dest for this consumer."
        echo "    Use --resolve-actioned for fixed or rebutted feedback,"
        echo "    --auto-resolve-bots for an explicit deferral."
        SKIPPED_NOT_PROPAGATION=$((SKIPPED_NOT_PROPAGATION + 1))
        continue ;;
    esac
    thread_class_computed=true
    # Actioned-evidence upgrade (#616 finding 3509734396), mirroring the
    # #575 auto-upgrade guard in --auto-resolve-bots: a routing-path
    # thread that ALSO carries demonstrable action evidence — an agent fix
    # commit touching the anchored file after the latest re-raise, or a
    # substantive rebuttal (the same fail-closed GATE classification
    # --resolve-actioned trusts) — is resolved under its truthful
    # addressed-elsewhere / rebuttal-recorded tag, not blanket-tagged
    # verified-propagation. The action evidence IS the resolution evidence
    # for these (exactly what --resolve-actioned would resolve on), so the
    # byte-compare is skipped; non-actioned threads fall through to it.
    upgraded_class=$(derive_tag_class "$thread" skip-routing)
    if class_is_actioned "$upgraded_class"; then
      echo "  INFO: tag auto-upgraded verified-propagation → $upgraded_class for [$AUTHOR] $PATH_ (demonstrably actioned; #575)"
      thread_class="$upgraded_class"
      VERIFIED_RATIONALE=$(synth_rationale "$upgraded_class" "$thread")
    else
      vp_rc=0
      # Staleness floor for the upstream-evidence gate (#616 finding
      # 3510170879): the latest bot/reviewer re-raise, floored at the
      # finding's createdAt — the same complete-thread floor the
      # actioned machinery trusts (complete_thread_comments ran above).
      vp_floor=$(latest_nonagent_created "$thread")
      vp_msg=$(verify_propagation_content "$thread_class" "$PATH_" "$vp_floor") || vp_rc=$?
      if [ "$vp_rc" -eq 1 ]; then
        echo "  SKIP (propagation NOT verified — content drift): [$AUTHOR] $PATH_"
        echo "    $vp_msg"
        echo "    Left unresolved: the byte-compare is the resolution evidence and it"
        echo "    did not match. Propagate the upstream fix (or fix it upstream), then"
        echo "    retry."
        SKIPPED_DRIFT=$((SKIPPED_DRIFT + 1))
        continue
      elif [ "$vp_rc" -eq 3 ]; then
        echo "  SKIP (no upstream-fix evidence — failing closed): [$AUTHOR] $PATH_"
        echo "    $vp_msg"
        echo "    A byte-match alone only proves the consumer mirrors the CURRENT"
        echo "    mergepath source — not that the upstream finding was ever fixed."
        echo "    Left unresolved (stays deferred and resurfaces). Deliberate bias:"
        echo "    an upstream fix that PRE-dates the finding also skips here;"
        echo "    resolve manually with evidence in that case."
        SKIPPED_NO_UPSTREAM_EVIDENCE=$((SKIPPED_NO_UPSTREAM_EVIDENCE + 1))
        continue
      elif [ "$vp_rc" -ne 0 ]; then
        echo "  SKIP (propagation verification failed — failing closed): [$AUTHOR] $PATH_"
        echo "    $vp_msg"
        echo "    Left unresolved: a verification that cannot run never resolves."
        SKIPPED_VERIFY_ERROR=$((SKIPPED_VERIFY_ERROR + 1))
        continue
      fi
      # Byte-match — resolve with the verified-propagation tag; the
      # verification message IS the tag rationale.
      thread_class="verified-propagation"
      VERIFIED_RATIONALE="$vp_msg"
    fi
  fi

  if $DRY_RUN; then
    echo "  WOULD RESOLVE [$AUTHOR] $PATH_"
    echo "    $EXCERPT"
    if [ "$MODE" = "resolve-verified-propagation" ]; then
      # thread_class is verified-propagation for a byte-verified thread,
      # or the truthful actioned class after the #616 upgrade above.
      echo "    → [mergepath-resolve: $thread_class] $VERIFIED_RATIONALE"
    fi
    WOULD_RESOLVE_COUNT=$((WOULD_RESOLVE_COUNT + 1))
    continue
  fi

  # mergepath#305 — emit `[mergepath-resolve: <class>] <rationale>`
  # reply BEFORE the resolve mutation. The classifier in
  # scripts/lib/daily-feedback-rollup-helpers.sh reads this tag and
  # prioritizes it over its own heuristics; the tag therefore must
  # land on the thread BEFORE the thread is resolved (otherwise the
  # rollup that runs next is reading a closed thread with no marker).
  #
  # Failure to post the tag is logged + counted, but does NOT block
  # the resolve mutation. The rollup's heuristic fallback is the same
  # behavior the script had before #305 — losing the tag is a soft
  # regression, not a correctness bug.
  if ! $NO_TAG_REPLY; then
    if $RATIONALE_FLAG_USED; then
      tag_class="deferred-to-followup"
      tag_rationale="$RATIONALE_OVERRIDE"
      # #575 guard on the EXPLICIT-DEFERRAL override: --rationale is exactly
      # how the #571 mis-marking happened — a blanket
      # `--auto-resolve-bots --rationale` run over a thread set that included
      # FIXED findings recorded them all as deferred-to-followup. The class
      # is the machine-read disposition of record (the free-form text is
      # human-facing), so when the thread is demonstrably ACTIONED — the
      # same fail-closed evidence gate --resolve-actioned trusts derives
      # addressed-elsewhere / rebuttal-recorded — upgrade the CLASS to the
      # truthful value and keep the operator's rationale text. Auto-upgrade
      # over warn-only is deliberate: the upgrade can never overclaim (it
      # fires only on demonstrated evidence), while a warning leaves the
      # mis-tag in place for every operator who misses the log line. A
      # pagination-incomplete thread keeps the deferred class — action
      # cannot be demonstrated on a truncated window (fail safe, #573).
      fetch_pr_tag_data
      augment_pr_commits_with_sha
      if thread=$(complete_thread_comments "$thread"); then
        upgraded_class=$(derive_tag_class "$thread" skip-routing)
        if class_is_actioned "$upgraded_class"; then
          echo "  INFO: tag auto-upgraded deferred-to-followup → $upgraded_class for [$AUTHOR] $PATH_ (demonstrably actioned; #575)"
          tag_class="$upgraded_class"
        fi
      fi
    elif [ "$MODE" = "resolve-verified-propagation" ]; then
      # #572: the gate above already byte-verified the propagation (or
      # upgraded the class to the truthful addressed-elsewhere /
      # rebuttal-recorded on demonstrated action evidence, #616);
      # thread_class + VERIFIED_RATIONALE carry the verdict of record.
      tag_class="$thread_class"
      tag_rationale="$VERIFIED_RATIONALE"
    else
      # Warm the tag-data cache (PR_FILES_CACHE / PR_COMMITS_CACHE +
      # the TAG_DATA_FETCHED guard) in THIS shell BEFORE the command-
      # substitution subshells below. Without this, fetch_pr_tag_data
      # runs inside derive_tag_class's subshell, populates the caches
      # in that subshell, and the parent shell never sees them — so
      # synth_rationale (also in a subshell) finds PR_COMMITS_CACHE
      # empty, emits `[: : integer expression expected` on line ~773,
      # and falls back to the generic no-SHA rationale. nathanpayne-
      # codex Phase 4b on #308 reproduced this with a page-2 files
      # fixture. Calling here also fulfills the "one-shot cache reused
      # across threads" intention — fetch_pr_tag_data's TAG_DATA_FETCHED
      # short-circuit only works if it's set in the loop's shell.
      #
      # #564: resolve-actioned mode already derived the class (and warmed
      # the caches) above — reuse it so derive_tag_class / synth_rationale
      # run at most once per thread.
      if ! $thread_class_computed; then
        fetch_pr_tag_data
        # Need the augmented commits cache (with .sha) for the
        # addressed-elsewhere rationale; the bare cache from
        # fetch_pr_tag_data doesn't carry .sha. derive_tag_class only
        # needs login + date so it runs against either shape.
        augment_pr_commits_with_sha
        # #573 item 2: the TAG class needs the same complete-thread rule as
        # the gate — a truncated window can hide the latest re-raise and
        # mis-tag live feedback as addressed/rebutted, which the daily
        # rollup would then read as handled. On a re-fetch failure don't
        # guess from the truncated window: record the honest fail-safe
        # class deferred-to-followup (the rollup keeps re-surfacing it).
        # The resolve mutation itself still proceeds — that is
        # --auto-resolve-bots' documented blunt contract, gated on the
        # current-HEAD anchor (commentsLast), not on this classification.
        if thread=$(complete_thread_comments "$thread"); then
          thread_class=$(derive_tag_class "$thread")
          # #575 guard on the auto-derived class: the TAG ladder can land on
          # deferred-to-followup even when the thread was actually actioned —
          # the concrete case is a stale recorded
          # `[mergepath-resolve: deferred-to-followup]` marker (honored by
          # the TAG path's step 0) sitting above a LATER fix commit or
          # rebuttal. Re-derive with the GATE classification
          # (--resolve-actioned's skip-routing path, which ignores markers
          # and re-checks fresh evidence); if it proves action, upgrade the
          # tag to the truthful class with an INFO line. A thread that is
          # not demonstrably actioned keeps deferred-to-followup. See the
          # header's --auto-resolve-bots entry for why auto-upgrade beats
          # warn-only.
          #
          # #616 (Codex finding 3509930338): the ROUTING classes the ladder
          # emits first — canonical-coverage / templated-render — get the
          # same actioned re-check, and when NOT actioned they are recorded
          # as deferred-to-followup, not the routing tag. This mode is THE
          # tool for EXPLICIT DEFERRAL, and the daily rollup SKIPS routing
          # classes — a routing tag here would bury a deliberate deferral so
          # it never resurfaces, contrary to the #575 disposition contract.
          # Routing says WHERE a fix belongs, not that one happened (#565);
          # once propagation provably lands, --resolve-verified-propagation
          # is the mode that closes these under a verified tag.
          case "$thread_class" in
            deferred-to-followup|canonical-coverage|templated-render)
              orig_class="$thread_class"
              upgraded_class=$(derive_tag_class "$thread" skip-routing)
              if class_is_actioned "$upgraded_class"; then
                echo "  INFO: tag auto-upgraded $orig_class → $upgraded_class for [$AUTHOR] $PATH_ (demonstrably actioned; #575)"
                thread_class="$upgraded_class"
              elif [ "$orig_class" != "deferred-to-followup" ]; then
                echo "  INFO: routing class $orig_class recorded as deferred-to-followup for [$AUTHOR] $PATH_ (explicit deferral, not actioned; #616)"
                thread_class="deferred-to-followup"
              fi
              ;;
          esac
        else
          echo "  WARN: comment pagination incomplete for [$AUTHOR] $PATH_ — tagging deferred-to-followup (fail-safe)" >&2
          # #575 guard intentionally NOT applied here: action cannot be
          # demonstrated on a truncated comment window (the hidden tail may
          # carry a re-raise), so the fail-safe deferred class stands.
          thread_class="deferred-to-followup"
        fi
        thread_class_computed=true
      fi
      tag_class="$thread_class"
      tag_rationale=$(synth_rationale "$tag_class" "$thread")
    fi
    if post_tag_reply "$THREAD_ID" "$tag_class" "$tag_rationale"; then
      echo "  TAGGED [$AUTHOR] $PATH_ → [mergepath-resolve: $tag_class]"
      TAG_REPLY_POSTED=$((TAG_REPLY_POSTED + 1))
    else
      echo "  WARN: tag-reply post failed for [$AUTHOR] $PATH_ (resolving anyway)" >&2
      TAG_REPLY_FAILED=$((TAG_REPLY_FAILED + 1))
    fi
  else
    TAG_REPLY_SKIPPED=$((TAG_REPLY_SKIPPED + 1))
  fi

  # Identity check moved out of the loop in #293 r2 — see the
  # single-gate block above the loop.
  #
  # #564: capture the mutation's returned `thread.isResolved` rather than
  # discarding the response. A mutation that returns HTTP 200 but
  # isResolved!=true did NOT actually resolve the thread, so it must count
  # as FAILED, not RESOLVED. Threads confirmed true here are collected into
  # RESOLVED_IDS for the consolidated reviewThreads readback after the loop.
  resolve_state=""
  if mutation_out=$(gh_pat api graphql -f query='
    mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { isResolved }
      }
    }
  ' -F id="$THREAD_ID" 2>/dev/null); then
    resolve_state=$(printf '%s' "$mutation_out" \
      | jq -r '.data.resolveReviewThread.thread.isResolved' 2>/dev/null || echo "")
  fi
  if [ "$resolve_state" = "true" ]; then
    echo "  RESOLVED [$AUTHOR] $PATH_"
    RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
    RESOLVED_IDS+=("$THREAD_ID")
  else
    echo "  FAILED [$AUTHOR] $PATH_ — mutation rejected (returned isResolved=${resolve_state:-none})" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done < <(printf '%s\n' "$UNRESOLVED")

echo ""
if $DRY_RUN; then
  echo "(dry-run; no threads modified) — would-resolve: $WOULD_RESOLVE_COUNT, skipped (human): $SKIPPED_HUMAN, skipped (stale-HEAD): $SKIPPED_STALE, skipped (not-actioned): $SKIPPED_NOT_ACTIONED, skipped (comments-incomplete): $SKIPPED_COMMENTS_INCOMPLETE, skipped (not-propagation): $SKIPPED_NOT_PROPAGATION, skipped (drift): $SKIPPED_DRIFT, skipped (verify-error): $SKIPPED_VERIFY_ERROR, skipped (no-upstream-evidence): $SKIPPED_NO_UPSTREAM_EVIDENCE"
  # Codex r2 on PR #172: dry-run previously exited 0 when only
  # current-HEAD bot threads remained (because dry-run does not mutate
  # them and they didn't increment SKIPPED_*). Callers would treat
  # the PR as "all clear" and proceed to merge into a still-BLOCKED PR.
  # Fix: dry-run exits 3 if ANY actionable items remain (would-resolve,
  # human-skipped, or stale-skipped). The only exit-0 path through
  # auto-resolve-bots --dry-run is "no unresolved threads at all"
  # which is already short-circuited above (UNRESOLVED is empty).
  if [ "$WOULD_RESOLVE_COUNT" -gt 0 ] || [ "$SKIPPED_HUMAN" -gt 0 ] || [ "$SKIPPED_STALE" -gt 0 ] || [ "$SKIPPED_NOT_ACTIONED" -gt 0 ] || [ "$SKIPPED_COMMENTS_INCOMPLETE" -gt 0 ] || [ "$SKIPPED_NOT_PROPAGATION" -gt 0 ] || [ "$SKIPPED_DRIFT" -gt 0 ] || [ "$SKIPPED_VERIFY_ERROR" -gt 0 ] || [ "$SKIPPED_NO_UPSTREAM_EVIDENCE" -gt 0 ]; then
    exit 3
  fi
  exit 0
fi

# --- post-resolve readback (#564) ------------------------------------------
# Acceptance criterion: "Actioned review feedback is resolved through an
# identity-checked resolveReviewThread path before merge, with a follow-up
# reviewThreads readback confirming isResolved: true." The per-thread
# mutation return value is checked in the loop above; this is the SEPARATE
# confirming read. We re-read each just-resolved thread via the top-level
# `nodes(ids:)` lookup — O(resolved), no pagination, and it reads back
# exactly the set we mutated (and is syntactically distinct from the
# enumeration `reviewThreads` query).
#
# Fail CLOSED: any thread that does not read back isResolved:true (state
# drift, eventual-consistency lag, an id that no longer resolves, or a
# token that could write but a later read that cannot) increments
# READBACK_FAILED and forces a non-zero exit, so a caller never treats an
# unconfirmed resolve as a clean conversation-resolution gate. A readback
# that confirms nothing is never treated as "all good".
#
# `nodes(ids:)` caps at 100 nodes per query, so batch — a single PR run
# resolving >100 threads is vanishingly rare, but the batch loop keeps the
# confirmation complete if it ever happens.
if [ "${#RESOLVED_IDS[@]}" -gt 0 ]; then
  rb_total=${#RESOLVED_IDS[@]}
  rb_start=0
  while [ "$rb_start" -lt "$rb_total" ]; do
    rb_batch=("${RESOLVED_IDS[@]:$rb_start:100}")
    rb_start=$((rb_start + 100))
    # Build the GraphQL ID-array literal by JSON-encoding the ids. GitHub
    # node IDs are documented as OPAQUE, so do not assume a charset or parse
    # them — JSON encoding (jq) escapes any content correctly, making the
    # inlined literal injection-safe for any id without a charset whitelist
    # (CodeRabbit on #565). A JSON string array is also a valid GraphQL
    # list-of-strings literal. Empty / drifted ids simply fail the per-id
    # readback below (fail closed).
    rb_ids_json=$(printf '%s\n' "${rb_batch[@]}" | jq -R . | jq -s -c .)
    rb_query="query { nodes(ids: ${rb_ids_json}) { ... on PullRequestReviewThread { id isResolved } } }"
    if ! rb_resp=$(gh_pat api graphql -f query="$rb_query" 2>&1); then
      echo "  READBACK FAILED: reviewThreads readback query errored: $rb_resp" >&2
      # Fail closed — count every id in this batch as unconfirmed.
      for rb_id in "${rb_batch[@]}"; do READBACK_FAILED=$((READBACK_FAILED + 1)); done
      continue
    fi
    for rb_id in "${rb_batch[@]}"; do
      rb_state=$(printf '%s' "$rb_resp" \
        | jq -r --arg id "$rb_id" \
            '(.data.nodes // []) | map(select(.id == $id)) | .[0].isResolved
             | if . == null then "missing" else tostring end' 2>/dev/null \
        || echo "missing")
      if [ "$rb_state" != "true" ]; then
        echo "  READBACK FAILED [$rb_id]: isResolved=$rb_state (expected true)" >&2
        READBACK_FAILED=$((READBACK_FAILED + 1))
      fi
    done
  done
  if [ "$READBACK_FAILED" -gt 0 ]; then
    echo "Readback: $READBACK_FAILED of $rb_total resolved thread(s) did NOT confirm isResolved:true — failing closed." >&2
  else
    echo "Readback: all $rb_total resolved thread(s) confirmed isResolved:true."
  fi
fi

echo "Resolved: $RESOLVED_COUNT  Skipped (human): $SKIPPED_HUMAN  Skipped (stale-HEAD): $SKIPPED_STALE  Skipped (not-actioned): $SKIPPED_NOT_ACTIONED  Skipped (comments-incomplete): $SKIPPED_COMMENTS_INCOMPLETE  Skipped (not-propagation): $SKIPPED_NOT_PROPAGATION  Skipped (drift): $SKIPPED_DRIFT  Skipped (verify-error): $SKIPPED_VERIFY_ERROR  Skipped (no-upstream-evidence): $SKIPPED_NO_UPSTREAM_EVIDENCE  Failed: $FAILED_COUNT  Readback-failed: $READBACK_FAILED"
if ! $NO_TAG_REPLY; then
  echo "Tag replies: posted=$TAG_REPLY_POSTED  failed=$TAG_REPLY_FAILED"
fi
# Codex r1 on PR #172: previously this exited 0 even with stale or
# human-authored threads remaining — callers would treat it as "all
# clear" and proceed to merge into a still-BLOCKED PR. Exit codes:
#   2 = mutation failure (transient: gh/network), a resolve mutation that
#       did not return isResolved:true, OR a post-resolve readback that
#       could not confirm isResolved:true (#564 — fail closed)
#   3 = unresolved threads remain (human, stale-bot, not-actioned,
#       comments-incomplete — the #573 truncated-thread fail-closed skip —
#       or the #572 skips: not-propagation-routed, drifted,
#       verification-failed, or byte-matched without upstream-fix
#       evidence, #616) — PR still conversation-resolution-blocked;
#       address and retry
#   0 = no unresolved threads on current HEAD
# Explicit `if` (not `[ a ] && exit`): two OR-ed conditions, and an
# `&& exit` chain would be ambiguous under set -e (see the SKIPPED block
# below). A readback failure is as fail-closed as a mutation failure.
if [ "$FAILED_COUNT" -gt 0 ] || [ "$READBACK_FAILED" -gt 0 ]; then
  exit 2
fi
# Use an explicit `if`, not `[ a ] || [ b ] && exit 3`. In that
# one-liner `&&` and `||` are equal-precedence and left-associative,
# so it parses as `([ a ] || [ b ]) && exit 3` — and under
# `set -e`, when BOTH skip counts are 0 the `[ b ]` that ends the
# `||` chain returns non-zero, making the whole list's status
# non-zero; whether that trips `set -e` depends on subtle list-tail
# rules. The `if` form is unambiguous and matches the block above.
# (CodeRabbit Major, #271/#272.)
if [ "$SKIPPED_HUMAN" -gt 0 ] || [ "$SKIPPED_STALE" -gt 0 ] || [ "$SKIPPED_NOT_ACTIONED" -gt 0 ] || [ "$SKIPPED_COMMENTS_INCOMPLETE" -gt 0 ] || [ "$SKIPPED_NOT_PROPAGATION" -gt 0 ] || [ "$SKIPPED_DRIFT" -gt 0 ] || [ "$SKIPPED_VERIFY_ERROR" -gt 0 ] || [ "$SKIPPED_NO_UPSTREAM_EVIDENCE" -gt 0 ]; then
  exit 3
fi
exit 0
