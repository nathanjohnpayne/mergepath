---
spec_id: merge_review_disagreement
---

# Merge Review Disagreement

The PreToolUse merge guard reads every page of the PR's reviews before allowing any merge command. For each non-author reviewer, its last opinionated review in the endpoint's chronological page order controls: `COMMENTED` and `PENDING` do not supersede an opinion; `APPROVED` and `DISMISSED` release a previous `CHANGES_REQUESTED`. An outstanding change request blocks even when it names an older head. Bot and human reviewers follow the same rule because either can carry an active GitHub change request.

Admin and merge-state break-glass variables never release this gate. The owner may separately authorize `BREAK_GLASS_REVIEW_DISAGREEMENT=<PR-number>@<full-current-head-sha>` for that specific PR and head, inline or exported. The merge command must include exactly one `--match-head-commit` matching that full head; GitHub enforces this precondition if a push races the guard. Deleted accounts with non-blocking states are ignored; anonymous change requests remain blockers until dismissed or explicitly overridden. This variable does not release other gates or a `human-hold`. Read failures, incomplete identity/head metadata and malformed review inventories refuse even with an override.

`tests/test_gh_pr_guard.sh` covers summary-only and older-head change requests, multiple pages, approval, dismissal, comments, bot and author identities, exact and mismatched overrides, and unavailable/malformed reads. The existing `scripts/ci/check_gh_as_author` entrypoint runs this suite.

Consumer rollout must update each repository-owned policy snapshot with the disagreement rule and server head precondition before propagating the guard. The canonical pointer links to the hub policy so a frozen consumer snapshot cannot hide the new instructions.
