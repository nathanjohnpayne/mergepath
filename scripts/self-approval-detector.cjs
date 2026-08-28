// scripts/self-approval-detector.cjs
//
// Pure decision function for `.github/workflows/agent-review.yml`'s
// self-approval guard. The workflow owns the GitHub mutations; this module
// only classifies an APPROVED review so the policy boundary is regression
// testable outside Actions.
//
// Input:
//   {
//     prAuthor: string,
//     authorIdentity: string,
//     reviewer: string,
//     reviewerAccounts: string[],
//     prBody: string,
//     requiresExternalReview: boolean | undefined,
//   }
//
// A syntactically valid declaration is evidence of the policy claim, not
// proof of who authored the branch. Create-time claim authentication remains
// #928; this detector closes the review-time independence gap in #1094.

'use strict';

// BEGIN SELF-APPROVAL DETECTOR IMPLEMENTATION
function normalized(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

// BEGIN STABLE PR LABEL NAMES
function stablePrLabelNames(candidate) {
  const labels = candidate && candidate.labels;
  if (
    !Array.isArray(labels) ||
    labels.some(label =>
      !label || typeof label.name !== 'string' || !label.name.trim()
    )
  ) {
    throw new Error('live PR labels are unavailable or malformed');
  }
  return labels.map(label => label.name).sort();
}
// END STABLE PR LABEL NAMES

function decide(input) {
  const prAuthor = normalized(input && input.prAuthor);
  const authorIdentity = normalized(input && input.authorIdentity);
  const reviewer = normalized(input && input.reviewer);
  const reviewerAccounts = Array.isArray(input && input.reviewerAccounts)
    ? input.reviewerAccounts.map(normalized).filter(Boolean)
    : [];
  const reviewerIsAgent = reviewerAccounts.includes(reviewer);

  // Keep the native-account defense independent of the PR-body declaration.
  // This catches a reviewer approving a PR authored by that same GitHub
  // account even when external review would otherwise not be required.
  if (reviewer && reviewerIsAgent && prAuthor === reviewer) {
    return {
      action: 'block',
      reason: 'same-native-account-approval',
      persistentViolation: true,
    };
  }

  // Human reviews are the documented tiebreaker and reviewer accounts not in
  // this repository's configured agent allow-list are outside this guard.
  if (!reviewerIsAgent) {
    return { action: 'allow', reason: 'human-or-unregistered-reviewer' };
  }

  if (!prAuthor || !authorIdentity) {
    return { action: 'block', reason: 'indeterminate-native-author' };
  }

  // External contributors and dependency bots do not use the shared author
  // identity, so they need no Authoring-Agent declaration. Their registered
  // agent reviewer is independent by native GitHub identity.
  if (prAuthor !== authorIdentity) {
    return { action: 'allow', reason: 'non-shared-author-pr' };
  }

  if (!input || typeof input.requiresExternalReview !== 'boolean') {
    return { action: 'block', reason: 'indeterminate-review-requirement' };
  }

  if (input.requiresExternalReview === true) {
    const declarationAttempts = (
      typeof input.prBody === 'string' ? input.prBody : ''
    ).split(/\r?\n|\r/).filter(
      line => /^[ \t]*Authoring-Agent:/i.test(line),
    );
    if (declarationAttempts.length === 0) {
      return {
        action: 'block',
        reason: 'indeterminate-phase-4-author',
        detail: 'missing-authoring-agent-declaration',
      };
    }
    if (declarationAttempts.length > 1) {
      return {
        action: 'block',
        reason: 'indeterminate-phase-4-author',
        detail: 'multiple-authoring-agent-declarations',
      };
    }
    const declaration = /^Authoring-Agent:[ \t]*([A-Za-z0-9_-]+)[ \t]*$/i
      .exec(declarationAttempts[0]);
    if (!declaration) {
      return {
        action: 'block',
        reason: 'indeterminate-phase-4-author',
        detail: 'malformed-authoring-agent-declaration',
      };
    }
    const authoringAgent = normalized(declaration[1]);
    const authoringReviewers = reviewerAccounts.filter(
      account => account.endsWith(`-${authoringAgent}`),
    );
    if (authoringReviewers.length === 0) {
      return {
        action: 'block',
        reason: 'indeterminate-phase-4-author',
        detail: 'unknown-authoring-agent',
      };
    }
    if (authoringReviewers.length > 1) {
      return {
        action: 'block',
        reason: 'indeterminate-phase-4-author',
        detail: 'ambiguous-authoring-agent-mapping',
      };
    }
    const [authoringReviewer] = authoringReviewers;

    if (authoringReviewer && authoringReviewer === reviewer) {
      return {
        action: 'block',
        reason: 'same-agent-phase-4-approval',
        // The declaration is mutable and GitHub exposes no conditional label
        // write bound to the body snapshot. Dismiss the approval, but reserve
        // the human-only persistent label for immutable native-author proof.
        authoringAgent,
        authoringReviewer,
      };
    }
  } else {
    return { action: 'allow', reason: 'under-threshold-agent-approval' };
  }

  return { action: 'allow', reason: 'different-agent-phase-4-approval' };
}

function latestOpinionatedReviews(input) {
  const reviewerAccounts = Array.isArray(input && input.reviewerAccounts)
    ? input.reviewerAccounts.map(normalized).filter(Boolean)
    : [];
  const prAuthor = normalized(input && input.prAuthor);
  const includePrAuthor = Boolean(input && input.includePrAuthor);
  const reviews = Array.isArray(input && input.reviews) ? input.reviews : [];
  const latestByReviewer = new Map();

  for (const review of reviews) {
    const reviewer = normalized(review && review.user && review.user.login);
    const state = normalized(review && review.state).toUpperCase();
    if (
      !reviewer ||
      (!includePrAuthor && reviewer === prAuthor) ||
      !reviewerAccounts.includes(reviewer) ||
      !['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'].includes(state)
    ) {
      continue;
    }

    const current = latestByReviewer.get(reviewer);
    const submittedAt = String((review && review.submitted_at) || '');
    const currentSubmittedAt = String((current && current.submitted_at) || '');
    const id = Number((review && review.id) || 0);
    const currentId = Number((current && current.id) || 0);
    if (
      !current ||
      submittedAt > currentSubmittedAt ||
      (submittedAt === currentSubmittedAt && id > currentId)
    ) {
      latestByReviewer.set(reviewer, review);
    }
  }

  return reviewerAccounts
    .map(reviewer => latestByReviewer.get(reviewer))
    .filter(Boolean);
}

function latestApprovedReviews(input) {
  const headSha = normalized(input && input.headSha);
  const requireHead = Boolean(input && input.requireHead);
  return latestOpinionatedReviews(input).filter(review =>
    normalized(review.state).toUpperCase() === 'APPROVED' &&
    (!requireHead || (headSha && normalized(review.commit_id) === headSha)),
  );
}

// A direct review webhook can arrive before the list-reviews endpoint exposes
// that review. Add it only when the live list has no object with the same ID;
// if the API already reports that ID as DISMISSED or CHANGES_REQUESTED, the
// live state wins over the older APPROVED webhook payload.
function reviewsWithDirectFallback(reviews, directReview) {
  const combined = Array.isArray(reviews) ? [...reviews] : [];
  const directId = Number((directReview && directReview.id) || 0);
  if (
    directId > 0 &&
    !combined.some(review => Number((review && review.id) || 0) === directId)
  ) {
    combined.push(directReview);
  }
  return combined;
}

// Bind the webhook-only fallback to live PR state without letting event
// freshness decide whether the fallback is retained. A delayed durable
// APPROVED event must still carry its exact review object when listReviews
// lags; staleness suppresses only direct-event attribution (red run and
// persistent label), not classification or dismissal.
function prepareDirectApproval(input) {
  const directReview = input && input.directReview;
  const liveHeadSha = normalized(input && input.liveHeadSha);
  const directCommit = normalized(directReview && directReview.commit_id);
  const directAttributionCurrent = !directReview || (
    input && input.eventEnforcementCurrent === true &&
    liveHeadSha &&
    directCommit === liveHeadSha
  );

  return {
    reviews: reviewsWithDirectFallback(input && input.liveReviews, directReview),
    directAttributionCurrent,
  };
}

// Plan the complete standing-approval enforcement for one workflow event.
// Event identity controls only attribution (red run / persistent label); it
// never narrows the standing set that must be classified and dismissed.
function planApprovalEnforcement(input) {
  const directReviewId = Number((input && input.directReviewId) || 0);
  const directAttributionCurrent = !input || input.directAttributionCurrent !== false;
  // Enforcement must retain a registered reviewer whose native account is
  // also the PR author so decide() can apply the explicit native-account
  // defense. Ordinary approval-readiness callers keep excluding PR-author
  // reviews through latestApprovedReviews()'s default.
  const approvals = latestApprovedReviews({...input, includePrAuthor: true});
  let eligibleApproval = false;
  let persistentDirectViolation = false;
  const directBlockedDiagnostics = [];
  const blockedDiagnostics = [];

  const classifiedApprovals = approvals.map(review => {
    const reviewer = review && review.user && review.user.login;
    const decision = decide({...input, reviewer});
    const diagnostic = decision.detail
      ? `${decision.reason}: ${decision.detail}`
      : decision.reason;
    const reviewId = Number((review && review.id) || 0);
    const isDirectReview =
      directAttributionCurrent && directReviewId > 0 && reviewId === directReviewId;

    if (decision.action === 'allow') {
      eligibleApproval = true;
    } else {
      blockedDiagnostics.push(diagnostic);
      if (isDirectReview) {
        directBlockedDiagnostics.push(diagnostic);
        persistentDirectViolation = Boolean(decision.persistentViolation);
      }
    }

    return {review, reviewer, decision, diagnostic, isDirectReview};
  });

  return {
    approvals: classifiedApprovals,
    eligibleApproval,
    persistentDirectViolation,
    directBlockedDiagnostics,
    blockedDiagnostics,
  };
}
// END SELF-APPROVAL DETECTOR IMPLEMENTATION

// Evaluate the complete latest-state approval set for a final live readiness
// decision. The workflow still owns dismissal/comment mutations, while the
// shared continuation consumes this pure summary before reporting stable,
// unarmed readiness.
function evaluateLatestApprovals(input) {
  const headSha = normalized(input && input.headSha);
  const requireHead = Boolean(input && input.requireHead);
  const opinions = latestOpinionatedReviews({...input, includePrAuthor: true});
  const standingApprovals = opinions.filter(
    review => normalized(review && review.state).toUpperCase() === 'APPROVED',
  );
  const classified = standingApprovals.map(review => {
    const reviewer = normalized(review && review.user && review.user.login);
    return {
      id: Number((review && review.id) || 0),
      reviewer,
      commitId: normalized(review && review.commit_id),
      decision: decide({...input, reviewer}),
    };
  });
  const allowed = classified.filter(approval =>
    approval.decision.action === 'allow' &&
    (!requireHead || (headSha && approval.commitId === headSha)),
  );
  const blocking = classified.filter(approval => approval.decision.action !== 'allow');
  const relevant = classified.filter(approval =>
    approval.decision.action !== 'allow' ||
    (!requireHead || (headSha && approval.commitId === headSha)),
  );

  return {
    // The final merge seam must not leave a same-agent Phase 4 approval in
    // GitHub's native approval set, even when an independent approval also
    // exists. Otherwise the independent approval can be dismissed after this
    // read and the disallowed approval alone can still satisfy one-approval
    // branch protection. Wait for the guard to dismiss every blocking approval
    // before consuming the independent one.
    eligibleApproval: allowed.length > 0 && blocking.length === 0,
    independentApproval: allowed.length > 0,
    blockingApprovals: blocking,
    approvals: relevant,
    opinionatedReviews: opinions.map(review => ({
      id: Number((review && review.id) || 0),
      reviewer: normalized(review && review.user && review.user.login),
      state: normalized(review && review.state).toUpperCase(),
      commitId: normalized(review && review.commit_id),
      submittedAt: String((review && review.submitted_at) || ''),
    })),
  };
}

module.exports = {
  stablePrLabelNames,
  decide,
  latestApprovedReviews,
  reviewsWithDirectFallback,
  prepareDirectApproval,
  planApprovalEnforcement,
  evaluateLatestApprovals,
};
