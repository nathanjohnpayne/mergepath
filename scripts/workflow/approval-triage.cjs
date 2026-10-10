'use strict';

// Read-only GitHub operations: retry transport failures, never policy drift or
// a permanent authorization/not-found response. Three attempts, 750ms backoff.
async function retryGithubRead(read, wait = ms => new Promise(resolve => setTimeout(resolve, ms))) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await read();
    } catch (error) {
      const status = Number(error && error.status || 0);
      const detail = [error && error.code, error && error.message,
        error && error.cause && error.cause.code,
        error && error.cause && error.cause.message].join(' ');
      const permanent = status >= 400 && status < 500 && status !== 429;
      const transient = status === 429 || (status >= 500 && status <= 599) ||
        /EPIPE|ECONNRESET|ETIMEDOUT|fetch failed/i.test(detail);
      if (attempt >= 2 || permanent || !transient) throw error;
      await wait(250 * (attempt + 1));
    }
  }
}

// This only preserves an existing exact-event approval; it never classifies,
// grants eligibility or permits merge while triage remains unsuccessful.
async function preserveApprovalAfterTriageFailure(input) {
  const {review, registered, eventPr, readPr, snapshot} = input;
  if (registered !== true || !review || !Number.isInteger(review.id) || review.id <= 0 ||
      String(review.state).toUpperCase() !== 'APPROVED' ||
      !eventPr || !eventPr.head || !eventPr.head.sha ||
      !eventPr.base || !eventPr.base.ref || !eventPr.base.sha ||
      !eventPr.user || typeof eventPr.user.login !== 'string' || !eventPr.user.login ||
      typeof eventPr.body !== 'string' || review.commit_id !== eventPr.head.sha) return false;
  try {
    const expected = snapshot(eventPr);
    const before = await retryGithubRead(readPr);
    if (snapshot(before) !== expected) return false;
    const after = await retryGithubRead(readPr);
    return snapshot(after) === expected;
  } catch {
    return false;
  }
}

module.exports = {retryGithubRead, preserveApprovalAfterTriageFailure};
