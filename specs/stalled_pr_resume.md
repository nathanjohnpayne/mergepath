# Stalled pull-request finder and resume entry point (#2165)

The largest share of pull-request wall-clock in the fleet is time when nothing is waiting on a machine: a reviewer verdict lands outside working hours and no session is alive to act on it. Two scripts in the `scripts/workflow/` kit close that gap from the tooling side; the end-of-session rule in `docs/agents/shared-operating-rules.md` closes it from the behavior side.

## Finder: `scripts/workflow/stalled-prs.sh`

Read-only. Lists the open, non-draft pull requests of one repository (`--repo`, default the current repo) and classifies each by whose turn it is and how long nothing has happened. The only GitHub calls are paginated REST GETs (open PRs, each PR's reviews, issue comments and inline comments, the head commit date) and one read-only GraphQL scalar (the head's `statusCheckRollup.state`). It never comments, labels, requests or merges.

Classes, one per PR:

- `stalled` — an agent must act and nothing has happened for at least the threshold (`--threshold-minutes`, default 60). Reasons: `unanswered-verdict` (the newest event is a bot review, a bot verdict comment, a reviewer-identity review or comment, or a human reply, with nothing after it); `head-unrequested` (the newest event is author-side, the head is CI-complete, and no review was requested and no Codex signal exists on it); `idle` (author activity after the verdict, then nothing); `request-unanswered` and `ci-pending-stale` (a machine wait outlived the threshold).
- `live` — an agent must act and the newest event is younger than the threshold.
- `waiting-on-ci` — the newest event is author-side and the head's check rollup is `PENDING`.
- `waiting-on-bot` — a review request (`@codex review` / `@coderabbitai …` in any markup) is newer than the head with no verdict after it, Codex's Review Summary reports the head `Running`, or the newest event is bot activity that is not a verdict (a rate-limit notice, a resolve acknowledgement).
- `waiting-on-human` — a `human-hold`, `needs-human-review` or `policy-violation` label, or the newest event is a handoff comment (`[mergepath-handoff]`, `<!-- mergepath-handback:`, or the `## External Review Required` heading). Never picked up by the resume entry point.

Next action, reported for every PR: `push fix` (CI red, the latest verdict requested changes, or findings on the head with no agent reply), `merge` (`scripts/codex-review-check.sh` exits 0 on the head), `request codex` (no Codex signal on the head and CI green, or a request outlived the threshold unanswered), `investigate` (the gate's one-line reason, or a stale CI wait), `wait` (a machine or a human acts next). The gate runs only for stalled PRs on an agent's turn, under a bounded timeout, and only in live runs; `--no-gate` skips it.

Verdict bodies are read with U+00A0 normalized to a space, because Codex posts NBSP inside `Reviewed commit:` lines. Draft PRs are excluded. The report is sorted stalled-first, oldest newest-event first. `--json` emits `stalled-prs-report/v1`; the human table prints one line per PR. `--dump FILE` writes the `stalled-prs/v1` snapshot after the gate stage, and `--input FILE` classifies a snapshot without any network call, which is how the suite builds its fixtures. `--now` pins the clock.

Exit codes: 0 nothing stalled; 1 at least one stalled PR; 2 usage; 3 a read failed (nothing is decided — a failed list is a status, never an empty report).

## Resume: `scripts/workflow/resume-stalled-pr.sh`

Runs the finder, selects the stalled PR whose newest event is oldest (or `--pr N`, which must still be stalled), and prints a work order: PR, head, reason, next action, the worktree checkout under the hidden per-repo folder, and the exact commands the review policy prescribes for that action. The calling session executes the round per `AGENTS.md` § Workflow Summary.

Under `--execute` it performs exactly one action itself: `request codex`, through `scripts/codex-review-request.sh --trigger-only` with `MERGEPATH_PHASE_4A_GATED=true`, which posts through the author wrapper and is idempotent on an existing head trigger. `push fix` needs code and `merge` needs the accounting and thread gates plus the author identity, so both stay with the session; the script never merges. `--execute` is refused on a replayed `--input` snapshot.

Exit codes: 0 a stalled PR was selected (and the executed step, if any, succeeded); 1 nothing to resume; 2 usage; 3 the finder could not read the repository or the executed step failed.

## Scheduled routine

The routine itself is configured outside the repository. From a checkout at the default branch, with a read-only token for the finder and the author credential the request wrapper resolves, it runs `scripts/workflow/resume-stalled-pr.sh --repo <owner/repo> --execute` and then continues the printed work order; `docs/agents/operating-rules.md` § Session finalization carries the operator detail.

## Coverage

`tests/test_stalled_pr_resume.sh` replays a fixture snapshot through `--input` for every class and reason above, the next-action derivation, NBSP tolerance, markup-tolerant trigger matching, draft exclusion, ordering and the exit-code contracts of both scripts; then runs the live fetch against a PATH-shimmed `gh` with stub gate and requester scripts to assert pagination on every list read, gate delegation once per stalled agent-turn PR, `--dump`/`--input` round-tripping, the `--execute` hand-off shape, and that an unreadable PR list exits 3 with nothing on stdout. `scripts/ci/check_stalled_pr_resume` wires it into `repo_lint.yml`.
