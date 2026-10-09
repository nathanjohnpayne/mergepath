---
spec_id: merge_review_disagreement
---

# Merge Review Disagreement

The PreToolUse merge guard reads every page of the PR's reviews before allowing an immediate merge command. For each non-author reviewer, its last opinionated review (`APPROVED` or `CHANGES_REQUESTED`) in the endpoint's chronological page order controls. `COMMENTED`, `PENDING` and `DISMISSED` carry no replacing opinion; dismissing the change-request object itself removes that object from the blocking set. An outstanding change request blocks even when it names an older head. Bot and human reviewers follow the same rule because either can carry an active GitHub change request.

Admin and merge-state break-glass variables never release this gate. The owner may separately authorize `BREAK_GLASS_REVIEW_DISAGREEMENT=<canonical-https-PR-URL>@<full-current-head-sha>` for that specific host, repository, PR and head, inline or exported. An immediate merge command must include exactly one `--match-head-commit` matching that full head; GitHub enforces this precondition if a push races the guard. Deleted accounts and garbage-collected review commits with non-blocking states are accepted; anonymous change requests remain blockers until dismissed or explicitly overridden. This variable does not release other gates or a `human-hold`. Read failures, incomplete identity/head metadata and malformed review inventories refuse even with an override.

`tests/test_gh_pr_guard.sh` covers summary-only and older-head change requests, multiple pages, approval, dismissal, comments, bot and author identities, exact and mismatched overrides, and unavailable/malformed reads. The existing `scripts/ci/check_gh_as_author` entrypoint runs this suite.

Consumer rollout must update each repository-owned policy snapshot with the disagreement rule and server head precondition before propagating the guard. The canonical pointer links to the hub policy so a frozen consumer snapshot cannot hide the new instructions.

Deferred `--auto` and implicit native merge-queue merges refuse because this local review snapshot cannot govern a later merge. `--disable-auto` remains an attributed retraction and bypasses merge-only checks, including review reads and the head-match requirement. Merge flags are scoped to the guarded shell command segment. A deleted PR author excludes no named reviewer from the disagreement check. Literal `export VAR=value; merge` is supported; dynamic exports never grant a tiebreak.

Every immediate merge must supply exactly one `--match-head-commit` equal to the inspected full HEAD. A dismissed review is ignored in the latest-opinion reduction; dismissing a different review cannot erase an active change request. Quoted option values are consumed before command separators are interpreted.

Command-local `GH_REPO` or `GIT_*` assignments/removals and clearing the wrapper environment are rejected before repository reads: the hook cannot inherit those command-local changes while the real writer would use them for repository discovery. Literal repository arguments and canonical PR URLs remain supported with the inherited environment. Assignments scoped to an earlier unrelated command do not affect the merge.

The required outcome in #1824 is a direct review-state read before the existing break-glass handling. This remains a client snapshot: a new change request submitted after that read can race an immediate merge on the same head where server protection permits it. An operator could therefore merge before seeing that newly submitted objection. This pre-existing interval is not enlarged by the patch; the head precondition fences pushes, and never claims to fence later review submissions. Atomic review-state enforcement at the server is a separate, stronger contract.

The hook inspects the submitted shell command, not code loaded from opaque script files. A source or directory-changing command before a visible guarded merge is rejected because it can change that merge's repository binding. A standalone `source payload.sh` with no visible `gh` command retains the existing behavior, as does execution of an arbitrary shell script: its hidden commands are not recursively inspected. An operator running such a file could invoke a bare merge outside this hook's direct-command checks. This pre-existing limitation is outside #1824's direct review-state check; a general file-execution boundary requires a separate design and owner scope decision.
