// scripts/disagreement-detector.cjs
//
// The `.cjs` extension is load-bearing: this module is CommonJS
// (`module.exports` / `require`). A consumer repo whose package.json
// declares `"type": "module"` would treat a bare `.js` file as ESM
// and fail with "module is not defined in ES module scope" when
// agent-review.yml require()s it. `.cjs` forces CommonJS regardless
// of the consuming repo's package.json type — see #264 (caught on
// the nathanpaynedotcom propagation PR).
//
// Pure decision function for `.github/workflows/agent-review.yml`'s
// `detect-disagreement` job and its CI test (#259). Given a PR's
// review list, the configured reviewer accounts, the current HEAD
// SHA, and whether `needs-human-review` is currently applied,
// returns one of `apply` / `remove` / `noop`.
//
// Live-disagreement semantics (the pre-#259 bug was that all three
// were absent):
//
//   1. Per-reviewer collapse: keep only the LATEST review per
//      `user.login` (sorted by `submitted_at`), discarding stale
//      reviews from the same reviewer. A round-1 CHANGES_REQUESTED
//      followed by a round-2 APPROVED from the same agent is a
//      reversal, not a disagreement.
//   2. DISMISSED filtering: a DISMISSED review (state-cleared by
//      GitHub when branch churn invalidates it, or manually
//      dismissed) does NOT count toward `hasApproval` or
//      `hasChangesRequested`. Per-reviewer collapse happens first
//      so a fresher DISMISSED can't bury an earlier non-DISMISSED
//      from the same reviewer.
//   3. HEAD-SHA scoping: only reviews whose `commit_id` matches the
//      current HEAD count. A CHANGES_REQUESTED on a stale SHA is
//      superseded by any APPROVED on a fresher SHA from any
//      reviewer.
//   4. Reviewer-account allow-list: only listed agent reviewers
//      contribute. COMMENTED reviews are filtered out — they do
//      not change a reviewer's effective position.
//
// Mirrors the merge-gate's latest-state-per-reviewer pattern from
// `scripts/codex-review-check.sh` gates (b)/(c) (#170 + #218).
//
// Input shape (object):
//   {
//     reviews:           Array<{ user:{login}, state, commit_id, submitted_at }>,
//     reviewerAccounts:  Array<string>,
//     headSha:           string,
//     hasLabel:          boolean,
//   }
//
// Output: one of 'apply' | 'remove' | 'noop'.
//
// The workflow `require()`s this module after `actions/checkout`
// and calls `decide(input)`. The CI test under
// `scripts/ci/check_disagreement_detector` `require()`s the same
// module and feeds it canned fixtures.

'use strict';

function decide(input) {
  const reviews = Array.isArray(input && input.reviews) ? input.reviews : [];
  const reviewerAccounts = Array.isArray(input && input.reviewerAccounts)
    ? input.reviewerAccounts
    : [];
  const headSha = (input && input.headSha) || '';
  const hasLabel = !!(input && input.hasLabel);

  // If `headSha` is missing, refuse to decide. Without it the
  // HEAD-SHA filter below drops every review (`r.commit_id !==
  // headSha` always true) → no live disagreement → the final branch
  // returns `remove` when `hasLabel` is true, INCORRECTLY clearing
  // `needs-human-review` from a malformed input. Return `noop` on
  // malformed input so the label is never auto-cleared without a
  // real signal. (CodeRabbit Major, #272.)
  if (!headSha) return 'noop';

  const allowed = new Set(reviewerAccounts);

  // Step 1: collapse to latest review per reviewer. We collapse
  // across ALL non-COMMENTED states (APPROVED, CHANGES_REQUESTED,
  // DISMISSED) so a fresher DISMISSED can supersede an older
  // APPROVED from the same reviewer (GitHub's dismissal model:
  // the reviewer's signal is no longer valid). COMMENTED reviews
  // are dropped here because they never change a reviewer's
  // effective position.
  const latestByReviewer = new Map();
  for (const r of reviews) {
    if (!r || !r.user || !allowed.has(r.user.login)) continue;
    if (r.state !== 'APPROVED' &&
        r.state !== 'CHANGES_REQUESTED' &&
        r.state !== 'DISMISSED') continue;
    const existing = latestByReviewer.get(r.user.login);
    if (!existing) {
      latestByReviewer.set(r.user.login, r);
      continue;
    }
    const existingTs = Date.parse(existing.submitted_at || '') || 0;
    const candidateTs = Date.parse(r.submitted_at || '') || 0;
    if (candidateTs > existingTs) {
      latestByReviewer.set(r.user.login, r);
    }
  }

  // Step 2: filter to reviews on the current HEAD that are not
  // DISMISSED. The HEAD-SHA filter is what kills the #259
  // false-positive: a CHANGES_REQUESTED on a stale SHA drops out
  // here even if the same reviewer hasn't revisited.
  const liveReviews = [];
  for (const r of latestByReviewer.values()) {
    if (!headSha || r.commit_id !== headSha) continue;
    if (r.state === 'DISMISSED') continue;
    liveReviews.push(r);
  }

  const hasApproval = liveReviews.some(r => r.state === 'APPROVED');
  const hasChangesRequested = liveReviews.some(r => r.state === 'CHANGES_REQUESTED');

  const liveDisagreement = hasApproval && hasChangesRequested;

  if (liveDisagreement) {
    return hasLabel ? 'noop' : 'apply';
  }
  return hasLabel ? 'remove' : 'noop';
}

// The detect-disagreement job's whole decision (#2727 3d), so the producer
// step and the trusted consumer run one copy. `reviewersJson` is the governing
// available_reviewers list as JSON. An unproven list (missing, malformed,
// empty or without a usable name) must neither hide a live conflict nor clear
// an escalation (#975): every reviewer on the PR is classified instead, and a
// `remove` becomes `noop`. The caller fails its run when allowListProven is
// false, so the policy failure is visible.
//
// Input:  { reviews, reviewersJson, headSha, hasLabel }
// Output: { decision: 'apply' | 'remove' | 'noop', allowListProven: boolean }
function resolveDisagreement(input) {
  const reviews = Array.isArray(input && input.reviews) ? input.reviews : [];
  let reviewerAccounts = [];
  try {
    const parsed = JSON.parse((input && input.reviewersJson) || '[]');
    if (Array.isArray(parsed)) {
      reviewerAccounts = parsed.filter(r => typeof r === 'string' && r);
    }
  } catch (e) {
    reviewerAccounts = [];
  }
  const allowListProven = reviewerAccounts.length > 0;
  if (!allowListProven) {
    reviewerAccounts = [...new Set(reviews.map(r => r && r.user && r.user.login).filter(Boolean))];
  }
  let decision = decide({
    reviews,
    reviewerAccounts,
    headSha: input && input.headSha,
    hasLabel: input && input.hasLabel,
  });
  if (!allowListProven && decision === 'remove') decision = 'noop';
  return { decision, allowListProven };
}

module.exports = { decide, resolveDisagreement };
