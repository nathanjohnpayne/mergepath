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

function normalized(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

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
        persistentViolation: true,
        authoringAgent,
        authoringReviewer,
      };
    }
  } else {
    return { action: 'allow', reason: 'under-threshold-agent-approval' };
  }

  return { action: 'allow', reason: 'different-agent-phase-4-approval' };
}

function latestApprovedReviews(input) {
  const reviewerAccounts = Array.isArray(input && input.reviewerAccounts)
    ? input.reviewerAccounts.map(normalized).filter(Boolean)
    : [];
  const prAuthor = normalized(input && input.prAuthor);
  const reviews = Array.isArray(input && input.reviews) ? input.reviews : [];
  const latestByReviewer = new Map();

  for (const review of reviews) {
    const reviewer = normalized(review && review.user && review.user.login);
    const state = normalized(review && review.state).toUpperCase();
    if (
      !reviewer ||
      reviewer === prAuthor ||
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
    .filter(review => review && normalized(review.state).toUpperCase() === 'APPROVED');
}

module.exports = { decide, latestApprovedReviews };
