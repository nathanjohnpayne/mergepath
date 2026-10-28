#!/usr/bin/env bash
# scripts/workflow/external_review_classify.sh — the external-review
# classifier of pr-review-policy.yml's External Review Check
# (`external-review-labeling`, step `check`), extracted verbatim so that the
# trusted policy consumer (#2727 slice 3c, C6/C7) can re-derive the producer's
# decision by running the same code from the default branch (#2727 slice 3b).
#
# Trust: the job holds the CI-actor PAT and runs no candidate code (#2775), so
# the workflow runs the DEFAULT BRANCH's copy of this file (`git show
# origin/<default>:...`), never the merge ref's. The working directory is the
# candidate checkout, read only as data (the diff and the propagation byte
# compare). Everything else the classifier trusts (the governing config, the
# fingerprint, carry-forward, pin-bump and clearance helpers, the propagation
# verifier) comes from the PR base or default-branch worktrees it materializes.
#
# Contract (unchanged from the inline step):
#   cwd            a full-history checkout of the PR (fetch-depth: 0)
#   env            GH_TOKEN, PR_NUMBER, EVENT_ACTION, BASE_SHA, HEAD_SHA,
#                  HEAD_REF, PR_AUTHOR, REPO, DEFAULT_BRANCH, GITHUB_OUTPUT,
#                  optional GITHUB_STEP_SUMMARY
#   outputs        needs_review, reasons, classification, propagation_lane,
#                  dependabot_pin_bump, dependabot_pin_bump_evidence, appended
#                  to $GITHUB_OUTPUT (a key can be written more than once; the
#                  last value wins, as in a step)
#   exit           0 on every classification, fail-closed ones included; any
#                  other status is an unexpected error, as it was inline
#
# GitHub runs a `run:` step as `bash --noprofile --norc -eo pipefail`; the
# options below reproduce that shell.
set -eo pipefail

NEEDS_REVIEW=false
REASONS=""

# A base with no .github/review-policy.yml predates the policy file.
# This used to SKIP the whole check (needs_review=false), which let a
# large or protected-path PR targeting such a base pass the label gate
# with no external review at all — flagged by the wave audit on the
# 4a8f804 wave. It now falls back to the DEFAULT-BRANCH policy, the
# same rule scripts/workflow/resolve_base_policy.sh applies for a
# confirmed 404, so every site treats "base predates the policy"
# identically instead of one of them opting out.
#
# Trade-off, stated because it is a real behaviour change: a consumer
# mid-bootstrap can have PRs whose base predates its policy file, and
# those PRs now get evaluated against the policy the repo actually has
# rather than waved through. That is the intended direction — the
# policy exists on the default branch by then — but it can newly label
# such a PR.
BASE_HAS_POLICY=true
if ! git cat-file -e "$BASE_SHA:.github/review-policy.yml" 2>/dev/null; then
  BASE_HAS_POLICY=false
  echo "NOTE: base commit has no .github/review-policy.yml (predates it) — falling back to the default-branch policy rather than skipping the external review check."
fi

# Unused since the classifier moved to the GitHub file list, but kept as it
# was inline: the diff still has to succeed under -e (#2727 3b, verbatim).
# shellcheck disable=SC2034
CHANGED_FILES=$(git diff --name-only "$BASE_SHA"..."$HEAD_SHA")

# --- Propagation PR review lane (mergepath#264 / #268) ---------
# A PR opened by scripts/sync-to-downstream.sh is a verbatim
# mirror of canonical/kit content ALREADY reviewed in its
# upstream mergepath PR. It is huge by design and always
# touches .github/** — so the line-count threshold and the
# external_review_paths check below would flag every sync PR
# for a redundant Phase 4 review of non-novel content.
#
# The lane exempts such a PR from external-review labeling —
# but ONLY when it is PROVABLY a faithful mirror. Codex P1 on
# #268 caught that a path-confinement-only check is a hole:
# `.github/workflows/*` IS a manifest path, so a sync-branch
# PR could hand-edit a workflow and skip review. The teeth is
# therefore a byte-level comparison against mergepath itself.
#
# Recognition + verification, all sourced from TRUSTED inputs
# (never the PR's own checkout, which the PR could tamper):
#   1. config (enabled / branch_prefix / author_identity) is
#      read from the BASE commit's review-policy.yml — a PR
#      cannot self-qualify by editing policy in the PR.
#      The lane defaults ON when the propagation_prs block is
#      absent (mergepath#434): the enable flag lived only in
#      consumer review-policy.yml, which is intentionally NOT
#      synced, so no consumer ever had the block and the lane
#      was dormant fleet-wide. An explicit `enabled: false`
#      remains the opt-out. The default adds no new trust —
#      recognition is still gated on the byte-level verify in
#      step 3, and a PR cannot grant itself the default
#      because it cannot edit its own BASE commit.
#   2. branch name must start with propagation_prs.branch_prefix
#      and PR author must be author_identity.
#   3. the <sha> in the branch name (mergepath-sync/<sha> or
#      mergepath-sync/sync-all-<sha>[-<scope-digest>]) is resolved
#      to one full commit that must be ON mergepath's default
#      branch's first-parent history, checked
#      out from PUBLIC nathanjohnpayne/
#      mergepath, and mergepath@<sha>'s OWN
#      verify-propagation-pr.sh byte-compares every changed
#      file against mergepath@<sha>'s content + manifest. A
#      hand-edit of any file — manifest path or not — fails
#      the byte-compare and the PR falls through to normal
#      Phase 3/4 review.
# See REVIEW_POLICY.md § Propagation PR review lane.
PROPAGATION_LANE=false
# Read a 2-space-indented scalar from a named YAML block in a
# given file, anchored to the block header and stopping at the
# next column-0 key (comment lines between header and field
# don't matter). Quote- and inline-comment-stripped.
prop_field() {  # <file> <block> <key>
  awk -v blk="$2" -v key="$3" '
    $0 ~ "^" blk ":" { in_blk = 1; next }
    in_blk && /^[^[:space:]#]/ { in_blk = 0 }
    in_blk && $1 == key":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      sub(/[[:space:]]*#.*$/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }
  ' "$1"
}
# Read a TOP-LEVEL scalar (author_identity), stripping BOTH YAML
# quote styles + a trailing comment + whitespace (#452). Mirrors
# audit-propagation-lane.sh's policy_top_scalar so the live lane and
# its weekly audit normalize author_identity identically — a
# quoted-but-correct `author_identity: "nathanjohnpayne"` passes the
# PR-author fingerprint below instead of failing on retained quotes.
top_field() {  # <file> <key>
  awk -v key="$2" '
    /^[^[:space:]#]/ && $1 == key":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\x27]/, "", $0)
      gsub(/["\x27][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$1"
}
# Lane config + author identity from the BASE commit, not the
# PR. `git show` the base blobs into tempfiles.
BASE_POLICY=$(mktemp)
if ! git show "$BASE_SHA:.github/review-policy.yml" > "$BASE_POLICY" 2>/dev/null; then
  : > "$BASE_POLICY"   # absent on base → lane simply won't match
fi
PROP_ENABLED=$(prop_field "$BASE_POLICY" propagation_prs enabled)
# Default ON when the key/block is absent (mergepath#434);
# explicit `enabled: false` opts out.
PROP_ENABLED=${PROP_ENABLED:-true}
PROP_PREFIX=$(prop_field "$BASE_POLICY" propagation_prs branch_prefix)
# Must match SYNC_BRANCH_PREFIX in scripts/sync-to-downstream.sh.
PROP_PREFIX=${PROP_PREFIX:-mergepath-sync/}
AUTHOR_ID=$(top_field "$BASE_POLICY" author_identity)
rm -f "$BASE_POLICY"

if [ "$PROP_ENABLED" = "true" ] && [ -n "$PROP_PREFIX" ] \
   && [ "${HEAD_REF#"$PROP_PREFIX"}" != "$HEAD_REF" ] \
   && [ "$PR_AUTHOR" = "$AUTHOR_ID" ]; then
  # Branch + author fingerprint matched. Now the teeth:
  # extract the source <sha> from the branch name, check out
  # PUBLIC mergepath at that sha, and run mergepath@<sha>'s
  # OWN verifier against this PR. Anything off → no lane.
  SYNC_KEY="${HEAD_REF#"$PROP_PREFIX"}"     # strip "mergepath-sync/"
  # Scoped keys are newly generated lowercase syntax. Preserve the
  # pre-existing mixed-case acceptance only for legacy SHA-only keys.
  if [[ "$SYNC_KEY" =~ ^sync-all-([0-9a-f]{7,40})-[0-9a-f]{12}$ ]]; then
    SYNC_SHA="${BASH_REMATCH[1]}"
  elif [[ "$SYNC_KEY" =~ ^sync-all-([0-9a-fA-F]{7,40})$ ]]; then
    SYNC_SHA="${BASH_REMATCH[1]}"
  else
    SYNC_SHA="$SYNC_KEY"
  fi
  if printf '%s' "$SYNC_SHA" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
    MP_DIR=$(mktemp -d)
    # mergepath is public — no token needed. blob:none keeps
    # it cheap; the checkout fetches only the blobs it needs.
    #
    # Source-commit provenance: the branch-name SHA is chosen by
    # whoever pushed the branch and may name ANY commit in the
    # public repo, including one on an unmerged branch. Resolve
    # the (normally 7-char) key to exactly ONE full 40-hex commit
    # — an ambiguous abbreviation fails rev-parse — and require it
    # on the FIRST-PARENT history of mergepath's default branch, so
    # only a tree that existed there after mergepath's own review
    # can qualify (generic ancestry would also admit an
    # intermediate commit of a PR branch merged with a true merge). The base verifier re-checks both (it receives
    # the full SHA as its 5th argument); checking here too keeps a
    # consumer whose base verifier predates that check safe.
    SYNC_FULL_SHA=""
    MP_DEFAULT_REF=""
    if git clone --quiet --filter=blob:none \
         https://github.com/nathanjohnpayne/mergepath "$MP_DIR" \
       && SYNC_FULL_SHA=$(git -C "$MP_DIR" rev-parse --verify --quiet "${SYNC_SHA}^{commit}" 2>/dev/null) \
       && [[ "$SYNC_FULL_SHA" =~ ^[0-9a-f]{40}$ ]] \
       && MP_DEFAULT_REF=$(git -C "$MP_DIR" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) \
       && [ -n "$MP_DEFAULT_REF" ] \
       && MP_FIRST_PARENT=$(git -C "$MP_DIR" rev-list --first-parent "$MP_DEFAULT_REF" 2>/dev/null) \
       && grep -Fxq "$SYNC_FULL_SHA" <<<"$MP_FIRST_PARENT" \
       && git -C "$MP_DIR" checkout --quiet "$SYNC_FULL_SHA" 2>/dev/null; then
      SYNC_SHA="$SYNC_FULL_SHA"
      # #531: run the TRUSTED in-repo verifier from the PR's
      # BASE commit (propagated + reviewed; the PR cannot edit
      # its own base), NOT the verifier shipped inside the
      # runtime-cloned mergepath@<sha>. The clone ($MP_DIR) is
      # passed only as a DATA source (manifest + canonical
      # content); no shell is executed out of it. This removes
      # the RCE surface of running runtime-fetched code under a
      # `pull-requests: write` workflow. The base verifier
      # sources its helpers from its own dir, so they are the
      # base commit's trusted copies too. fetch-depth:0 above
      # guarantees BASE_SHA is present for the worktree add.
      BASE_TREE=$(mktemp -d)
      if git worktree add --quiet --detach "$BASE_TREE" "$BASE_SHA" 2>/dev/null; then
        VERIFIER="$BASE_TREE/scripts/workflow/verify-propagation-pr.sh"
        if [ ! -f "$VERIFIER" ]; then
          echo "Propagation lane: base commit has no scripts/workflow/verify-propagation-pr.sh (consumer not yet on the vendored verifier) — not lane-eligible; falls through to normal review."
        elif ! grep -q 'mergepath-verifier-contract: self-sourced-helpers-v1' "$VERIFIER"; then
          # #545 (4a P1): a base verifier predating the #531
          # self-sourcing hardening would source its helpers from
          # the runtime-cloned mergepath ($MP_DIR) — fetched shell
          # under a pull-requests: write job (RCE). Fail closed: do
          # NOT run it; fall through to normal review. The lane turns
          # on once the hardened verifier itself has propagated into
          # the consumer base.
          echo "Propagation lane: base verifier predates the #531 self-sourcing contract (no self-sourced-helpers-v1 tag) — not lane-eligible; falls through to normal review."
        elif bash "$VERIFIER" "$MP_DIR" "$PWD" "$BASE_SHA" "$HEAD_SHA" "$SYNC_FULL_SHA"; then
          PROPAGATION_LANE=true
        fi
        git worktree remove --force "$BASE_TREE" 2>/dev/null || rm -rf "$BASE_TREE"
      else
        echo "Propagation lane: could not materialize the base-commit verifier (worktree add failed) — not lane-eligible."
        rm -rf "$BASE_TREE"
      fi
    else
      echo "Propagation lane: mergepath@$SYNC_SHA does not resolve to exactly one commit on mergepath's default branch (resolved='${SYNC_FULL_SHA:-none}', default='${MP_DEFAULT_REF:-unknown}'), or could not be checked out — not lane-eligible."
    fi
    rm -rf "$MP_DIR"
  else
    echo "Propagation lane: branch '$HEAD_REF' has no resolvable mergepath SHA — not lane-eligible."
  fi
fi
if [ "$PROPAGATION_LANE" = "true" ]; then
  echo "Propagation PR review lane: VERIFIED faithful mirror of mergepath@$SYNC_SHA (branch=$HEAD_REF, author=$PR_AUTHOR)."
  echo "needs_review=false" >> "$GITHUB_OUTPUT"
  echo "propagation_lane=true" >> "$GITHUB_OUTPUT"
  echo "classification=propagation" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "propagation_lane=false" >> "$GITHUB_OUTPUT"

# Compute the external-review trigger and same-content fingerprint
# from GitHub's PR file list. The helper itself must come from the
# trusted base tree, not the PR checkout: this job can write labels
# and comments, and same-repo PRs can edit scripts/workflow/**.
FILES_JSON=$(mktemp)
set +e
FILES_RAW=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files")
files_rc=$?
set -e
if [ "$files_rc" -ne 0 ] || ! printf '%s\n' "$FILES_RAW" | jq -s 'add // []' > "$FILES_JSON"; then
  echo "External-review fail-closed: could not fetch PR files; requiring review."
  echo "needs_review=true" >> "$GITHUB_OUTPUT"
  echo "reasons=- Could not fetch PR files for external-review fingerprint; requiring review fail-closed" >> "$GITHUB_OUTPUT"
  echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Materialize the trusted trees. Neither the helper nor the config may
# come from the PR checkout: this job can write labels and comments,
# and same-repo PRs can edit scripts/workflow/** (#531 / #545).
#
# CONFIG always comes from the PR BASE tree, never the default branch
# (#763, Codex P1). The policy that governs a PR is the policy of the
# branch it targets: a PR onto a stricter non-default branch (a
# release branch with a lower threshold or extra protected paths) must
# be judged by THAT branch's .github/review-policy.yml. Reading config
# from the default branch would silently ignore it. The earlier guard
# in this job already proved BASE_SHA carries a review-policy.yml, so
# this source is always available.
#
# HELPER prefers the PR base too, and falls back to the default branch
# ONLY when the base predates the helper (#763). Pinning the helper to
# the base alone made POLICY a function of the base's age: a PR opened
# against any base predating these helpers forced needs_review=true for
# every PR in this workflow, bypassing the threshold logic entirely and
# staying stuck until the branch was rebased. Both trees are equally
# untouchable by the PR, so the #531 trust property holds either way.
#
# The fallback can pair a NEWER helper with an OLDER config. That is
# the safe skew direction — a current helper tolerates an older config
# (missing keys take documented defaults); the reverse, an old helper
# against a newer config, is the unsafe one and cannot arise here.
TRUSTED_BASE_TREE=""
TRUSTED_HELPER_TREE=""
TRUSTED_CONFIG_TREE=""
cleanup_trusted_trees() {
  # The helper tree IS the base tree in the common case; only remove
  # it once so the second pass can't log a spurious failure.
  for _t in "$TRUSTED_CONFIG_TREE" "$TRUSTED_HELPER_TREE" "$TRUSTED_BASE_TREE"; do
    [ -n "$_t" ] || continue
    git worktree remove --force "$_t" >/dev/null 2>&1 || rm -rf "$_t"
    # Stop after the base tree: in the common case the helper tree
    # IS the base tree, so a second pass would log a spurious failure.
    [ "$_t" != "$TRUSTED_BASE_TREE" ] || break
  done
}
trap cleanup_trusted_trees EXIT

TRUSTED_BASE_TREE=$(mktemp -d)
rmdir "$TRUSTED_BASE_TREE" 2>/dev/null || true
if ! git worktree add --quiet --detach "$TRUSTED_BASE_TREE" "$BASE_SHA" 2>/dev/null; then
  echo "External-review fail-closed: could not materialize the PR base tree; requiring review."
  echo "needs_review=true" >> "$GITHUB_OUTPUT"
  echo "reasons=- Could not materialize the PR base tree for the external-review calculation; requiring review fail-closed" >> "$GITHUB_OUTPUT"
  echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
  exit 0
fi
# Pair the config with the base tree, EXCEPT when the base predates
# the policy file — then the default-branch copy is the only policy
# that exists (see BASE_HAS_POLICY above).
#
# The fallback MUST come from a trusted origin/$DEFAULT_BRANCH
# worktree, never a bare `.github/review-policy.yml` path: this job
# is checked out at the PR MERGE COMMIT, so a bare path resolves
# against the PR's own content and would let a PR whose base predates
# the policy file supply the policy that judges it (CodeRabbit
# Major on #768 — a regression introduced by this PR's earlier draft).
# If neither the base nor the default branch yields a policy, fail
# closed rather than fall back to anything the PR can write.
if [ "$BASE_HAS_POLICY" = "true" ]; then
  TRUSTED_CONFIG="$TRUSTED_BASE_TREE/.github/review-policy.yml"
else
  if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH^{commit}" >/dev/null 2>&1; then
    TRUSTED_CONFIG_TREE=$(mktemp -d)
    rmdir "$TRUSTED_CONFIG_TREE" 2>/dev/null || true
    if ! git worktree add --quiet --detach "$TRUSTED_CONFIG_TREE" "origin/$DEFAULT_BRANCH" 2>/dev/null \
       || [ ! -f "$TRUSTED_CONFIG_TREE/.github/review-policy.yml" ]; then
      git worktree remove --force "$TRUSTED_CONFIG_TREE" >/dev/null 2>&1 || rm -rf "$TRUSTED_CONFIG_TREE"
      TRUSTED_CONFIG_TREE=""
    fi
  fi
  if [ -z "$TRUSTED_CONFIG_TREE" ]; then
    echo "External-review fail-closed: PR base has no .github/review-policy.yml and no trusted origin/$DEFAULT_BRANCH copy is available; requiring review."
    echo "needs_review=true" >> "$GITHUB_OUTPUT"
    echo "reasons=- No trusted review-policy.yml on the PR base or the default branch; requiring review fail-closed" >> "$GITHUB_OUTPUT"
    echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  TRUSTED_CONFIG="$TRUSTED_CONFIG_TREE/.github/review-policy.yml"
  echo "NOTE: using the trusted origin/$DEFAULT_BRANCH review policy (the PR base predates the policy file)."
fi

TRUSTED_SOURCE=""
if [ -x "$TRUSTED_BASE_TREE/scripts/workflow/external_review_fingerprint.sh" ]; then
  TRUSTED_HELPER_TREE="$TRUSTED_BASE_TREE"
  TRUSTED_SOURCE="the PR base ($BASE_SHA)"
elif git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH^{commit}" >/dev/null 2>&1; then
  TRUSTED_HELPER_TREE=$(mktemp -d)
  rmdir "$TRUSTED_HELPER_TREE" 2>/dev/null || true
  if git worktree add --quiet --detach "$TRUSTED_HELPER_TREE" "origin/$DEFAULT_BRANCH" 2>/dev/null \
     && [ -x "$TRUSTED_HELPER_TREE/scripts/workflow/external_review_fingerprint.sh" ]; then
    TRUSTED_SOURCE="origin/$DEFAULT_BRANCH (fallback: the PR base predates the helper)"
  else
    git worktree remove --force "$TRUSTED_HELPER_TREE" >/dev/null 2>&1 || rm -rf "$TRUSTED_HELPER_TREE"
    TRUSTED_HELPER_TREE=""
  fi
fi

if [ -z "$TRUSTED_SOURCE" ]; then
  echo "External-review fail-closed: neither the PR base nor origin/$DEFAULT_BRANCH carries an executable fingerprint helper; requiring review."
  echo "needs_review=true" >> "$GITHUB_OUTPUT"
  echo "reasons=- Trusted external-review fingerprint helper is unavailable on the PR base and the default branch; requiring review fail-closed" >> "$GITHUB_OUTPUT"
  echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "External-review: config from the PR base; helpers from $TRUSTED_SOURCE."

TRUSTED_HELPER_DIR="$TRUSTED_HELPER_TREE/scripts/workflow"
FINGERPRINT_HELPER="$TRUSTED_HELPER_DIR/external_review_fingerprint.sh"
CARRY_HELPER="$TRUSTED_HELPER_DIR/external_review_carryforward.sh"
CLEARANCE_HELPER="$TRUSTED_HELPER_TREE/scripts/codex-review-check.sh"

set +e
FINGERPRINT_JSON=$(bash "$FINGERPRINT_HELPER" \
  --repo "$REPO" \
  --pr "$PR_NUMBER" \
  --ref "$HEAD_SHA" \
  --config "$TRUSTED_CONFIG" \
  --files-json "$FILES_JSON")
fingerprint_rc=$?
set -e
if [ "$fingerprint_rc" -ne 0 ]; then
  echo "External-review fail-closed: fingerprint helper failed (rc=$fingerprint_rc); requiring review."
  echo "needs_review=true" >> "$GITHUB_OUTPUT"
  echo "reasons=- External-review fingerprint helper failed; requiring review fail-closed" >> "$GITHUB_OUTPUT"
  echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
  exit 0
fi

NEEDS_REVIEW=$(echo "$FINGERPRINT_JSON" | jq -r '.requires_review')
FINGERPRINT=$(echo "$FINGERPRINT_JSON" | jq -r '.fingerprint // ""')
REASONS=$(echo "$FINGERPRINT_JSON" | jq -r '.reasons | map("- " + .) | join("%0A")')
if [ "$NEEDS_REVIEW" = "false" ]; then
  echo "classification=under-threshold" >> "$GITHUB_OUTPUT"
else
  echo "classification=external-required" >> "$GITHUB_OUTPUT"
fi

# --- Dependabot action-pin bump lane (mergepath#2164) ----------
# `.github/**` is a protected path so a human-authored workflow
# edit gets a cross-agent review. A Dependabot bump of a pinned
# action matches that rule too, and Codex never reviews Dependabot
# PRs, so the label sat until a human admin override (#2131/#2132/
# #2133, ~17h each). Same shape as the propagation lane above:
# exempt on PROOF, never on the author login or the file name. The
# proof is the trusted helper's: every commit on the PR is
# Dependabot-authored, GitHub-committed and signature-verified
# (scripts/lib/dependabot-commit-provenance.sh), and every changed
# line is a `uses: owner/repo@<ref> # vX.Y.Z` pin whose text up to
# the `@` is unchanged, in `.github/workflows/*.yml` and nowhere
# else. The helper and the libs it sources come from the TRUSTED
# tree (base, or default-branch fallback), never the PR checkout.
#
# Scope: only the protected-path reason is carved out. A diff that
# also crosses the line threshold, or a files read GitHub capped,
# keeps the label. This path only DECLINES TO APPLY the label and
# publishes a diagnostic; it removes nothing. The authority that
# clears a label already present (an older labeler, a fail-closed
# earlier head, a race) is the trusted pull_request_target /
# workflow_run / scheduled path in auto-clear-blocking-labels.yml,
# which re-runs this same helper from the default branch against
# the LIVE head/base pair. See REVIEW_POLICY.md § Dependabot
# action-pin bump lane.
echo "dependabot_pin_bump=false" >> "$GITHUB_OUTPUT"
if [ "$NEEDS_REVIEW" = "true" ] && [ "$PR_AUTHOR" = 'dependabot[bot]' ]; then
  PIN_HELPER="$TRUSTED_HELPER_DIR/dependabot_pin_bump_exemption.sh"
  if [ ! -f "$PIN_HELPER" ]; then
    echo "Dependabot pin-bump lane: no trusted helper at $PIN_HELPER (helpers from $TRUSTED_SOURCE predate mergepath#2164) — not lane-eligible; falls through to normal review."
  elif ! jq -e '(.lines_changed < .threshold) and (.reasons | length) == 1 and (.reasons[0] | startswith("protected paths modified: "))' <<<"$FINGERPRINT_JSON" >/dev/null; then
    echo "Dependabot pin-bump lane: external review is required for more than the protected-path rule ($(jq -r '.reasons | join("; ")' <<<"$FINGERPRINT_JSON")) — not lane-eligible."
  else
    set +e
    PIN_JSON=$(bash "$PIN_HELPER" \
      --repo "$REPO" \
      --pr "$PR_NUMBER" \
      --head "$HEAD_SHA" \
      --base "$BASE_SHA" \
      --config "$TRUSTED_CONFIG" \
      --files-json "$FILES_JSON")
    pin_rc=$?
    set -e
    PIN_REASON=$(jq -r '.reason // ""' <<<"$PIN_JSON" 2>/dev/null || true)
    case "$pin_rc" in
      0)
        echo "Dependabot pin-bump lane: VERIFIED at head $HEAD_SHA / base $BASE_SHA — $PIN_REASON"
        {
          echo "### Dependabot action-pin bump lane"
          echo
          echo "Exempt from the \`.github/**\` protected-path external-review rule at head \`$HEAD_SHA\` / base \`$BASE_SHA\` (REVIEW_POLICY.md § Dependabot action-pin bump lane):"
          echo
          echo "- Commit provenance: $(jq -r '.provenance' <<<"$PIN_JSON")"
          echo "- Diff shape: $(jq -r '.pins' <<<"$PIN_JSON") action pin line(s) across $(jq -r '.files | length' <<<"$PIN_JSON") workflow file(s); every changed line is a \`uses:\` ref or its pin comment"
          jq -r '.files[] | "  - `\(.filename)`: \(.pins) pin line(s)"' <<<"$PIN_JSON"
        } >> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"
        echo "needs_review=false" >> "$GITHUB_OUTPUT"
        echo "reasons=" >> "$GITHUB_OUTPUT"
        echo "classification=dependabot-pin-bump" >> "$GITHUB_OUTPUT"
        echo "dependabot_pin_bump=true" >> "$GITHUB_OUTPUT"
        echo "dependabot_pin_bump_evidence=$PIN_JSON" >> "$GITHUB_OUTPUT"
        exit 0
        ;;
      1)
        echo "Dependabot pin-bump lane: not exempt — $PIN_REASON. Normal external review applies."
        ;;
      *)
        echo "Dependabot pin-bump lane: the proof could not be reached (rc=$pin_rc${PIN_REASON:+: $PIN_REASON}); requiring review fail-closed. The next head or label event re-evaluates it."
        ;;
    esac
  fi
fi

# A label delivery can arrive after Phase 4 already
# cleared this exact head. Ask the canonical merge predicate rather
# than reimplementing Codex / Phase 4b authority here. Its normal
# mode retains reviewer identity, no-self-approval, latest-signal,
# blocking-label, and current-head rules; only CI is skipped because
# this required workflow would otherwise wait on itself.
#
# The governing config came from the event base. Bracket the helper
# with live head+base reads so a push or retarget cannot turn that
# event policy into a clearance claim about a different PR state.
read_live_pair() {
  local pair
  if ! pair=$(gh api "repos/$REPO/pulls/$PR_NUMBER" \
    --jq '{head:.head.sha,base:.base.sha}'); then
    return 1
  fi
  if ! jq -e '
      select((.head | type) == "string" and (.head | test("^[0-9a-fA-F]{40}$")))
      | select((.base | type) == "string" and (.base | test("^[0-9a-fA-F]{40}$")))
    ' <<<"$pair" >/dev/null; then
    return 1
  fi
  printf '%s\n' "$pair"
}
publish_stale_event() {
  echo "External-review classification event no longer matches the live PR head/base; skipping stale result."
  echo "classification=stale-event" >> "$GITHUB_OUTPUT"
  echo "needs_review=false" >> "$GITHUB_OUTPUT"
  echo "reasons=" >> "$GITHUB_OUTPUT"
}
publish_clearance_failure() {
  echo "External-review clearance lookup failed closed: $1"
  echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
  echo "needs_review=true" >> "$GITHUB_OUTPUT"
  echo "reasons=- External-review clearance lookup failed; requiring review fail-closed" >> "$GITHUB_OUTPUT"
}

if [ "$NEEDS_REVIEW" = "true" ] && [ -n "$FINGERPRINT" ] && [ -x "$CARRY_HELPER" ]; then
  set +e
  CARRY_JSON=$(bash "$CARRY_HELPER" \
    --repo "$REPO" \
    --pr "$PR_NUMBER" \
    --head "$HEAD_SHA" \
    --current-fingerprint "$FINGERPRINT" \
    --config "$TRUSTED_CONFIG" \
    --files-json "$FILES_JSON")
  carry_rc=$?
  set -e
  if [ "$carry_rc" -eq 0 ] && [ "$(echo "$CARRY_JSON" | jq -r '.carried')" = "true" ]; then
    SOURCE_COMMIT=$(echo "$CARRY_JSON" | jq -r '.source_commit')
    SOURCE_TIME=$(echo "$CARRY_JSON" | jq -r '.source_time')
    echo "External-review carry-forward: Codex already cleared the same external-review fingerprint on $SOURCE_COMMIT at $SOURCE_TIME; skipping needs-external-review on base-only sync (#705)."
    echo "classification=carried-forward" >> "$GITHUB_OUTPUT"
    echo "needs_review=false" >> "$GITHUB_OUTPUT"
    echo "reasons=" >> "$GITHUB_OUTPUT"
    exit 0
  elif [ "$carry_rc" -ne 0 ]; then
    echo "External-review carry-forward failed (rc=$carry_rc); requiring current-head review fail-closed."
    echo "classification=fail-closed" >> "$GITHUB_OUTPUT"
    echo "needs_review=true" >> "$GITHUB_OUTPUT"
    echo "reasons=- External-review carry-forward lookup failed (rc=$carry_rc); requiring review fail-closed" >> "$GITHUB_OUTPUT"
    exit 0
  fi
fi

# Preserve the distinct carried-forward classification above so it
# remains eligible for #1321 reconciliation alongside under-threshold.
# A later canonical gate clearance suppresses application but grants
# no additional label-removal authority.
if [ "$NEEDS_REVIEW" = "true" ] \
   && { [ "$EVENT_ACTION" = labeled ] || [ "$EVENT_ACTION" = unlabeled ]; }; then
  if [ ! -x "$CLEARANCE_HELPER" ]; then
    publish_clearance_failure "trusted canonical helper is unavailable"
    exit 0
  fi
  if ! LIVE_PAIR_BEFORE=$(read_live_pair); then
    publish_clearance_failure "could not read a valid live PR head/base pair"
    exit 0
  fi
  if [ "$(jq -r '.head' <<<"$LIVE_PAIR_BEFORE")" != "$HEAD_SHA" ] \
     || [ "$(jq -r '.base' <<<"$LIVE_PAIR_BEFORE")" != "$BASE_SHA" ]; then
    publish_stale_event
    exit 0
  fi

  set +e
  CODEX_REVIEW_CHECK_SKIP_CI=1 \
    CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
    MERGEPATH_REVIEW_POLICY_PATH="$TRUSTED_CONFIG" \
    bash "$CLEARANCE_HELPER" "$PR_NUMBER" "$REPO"
  clearance_rc=$?
  set -e

  if [ "$clearance_rc" -eq 0 ]; then
    if ! LIVE_PAIR_AFTER=$(read_live_pair); then
      publish_clearance_failure "could not re-read a valid live PR head/base pair"
      exit 0
    fi
    if [ "$(jq -r '.head' <<<"$LIVE_PAIR_AFTER")" != "$HEAD_SHA" ] \
       || [ "$(jq -r '.base' <<<"$LIVE_PAIR_AFTER")" != "$BASE_SHA" ]; then
      publish_stale_event
      exit 0
    fi
    echo "External review is already cleared by the canonical current-head gate; suppressing label application."
    echo "classification=external-cleared" >> "$GITHUB_OUTPUT"
    echo "needs_review=false" >> "$GITHUB_OUTPUT"
    echo "reasons=" >> "$GITHUB_OUTPUT"
    exit 0
  elif [ "$clearance_rc" -ne 1 ]; then
    publish_clearance_failure "canonical helper exited $clearance_rc"
    exit 0
  fi
fi

echo "needs_review=$NEEDS_REVIEW" >> "$GITHUB_OUTPUT"
echo "reasons=$REASONS" >> "$GITHUB_OUTPUT"
