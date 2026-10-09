---
spec_id: owner_admin_override
---

# Scoped owner admin overrides

An admin merge through `gh-as-author.sh` requires `BREAK_GLASS_ADMIN=<full-PR-URL>@<full-head>` and `MERGEPATH_OWNER_ADMIN_AUTHORIZATION`, a version-1 JSON record with `pr_url`, `head_sha`, `authorized_at` (UTC seconds), `authorization_quote`, `allow_needs_human_review` and `allow_codex_inflight`. Both allow fields are explicit booleans. Inherited repository options before either command verb are recognized. The actual command must contain exactly one matching `--match-head-commit`.

The wrapper refuses a different PR/head, a future timestamp, an empty quote, an unreadable API, a later human-review escalation without explicit authorization, and an unanswered Codex request without explicit authorization. `human-hold` and `policy-violation` require human label removal. The wrapper posts the quote, timestamp, exact tuple and observed red gates before merging, verifies the comment's author/body, and rechecks the head and blocking labels. GitHub's head precondition closes the final push interval.

The weekly audit validates author, PR/head and authorization/comment-creation/comment-update/merge timestamp order, and reports those records separately from unexplained violations. A recorded instruction preserves the operator's account of the owner's authorization; it does not independently authenticate a local chat transcript. The audit requires an explicit needs-human-review exception whenever that label was present at merge, regardless of when it was added; human-hold and policy-violation never receive an exemption. Read failures and malformed records grant no audit exemption.

The CODEOWNERS deadlock helper accepts `--authorization-file` with an array of version-1 records and selects exactly one record for each canonical PR URL/full head. Missing, stale or duplicate matching records refuse that PR; CLEAN PRs keep the ordinary merge path. A single-PR call may use the scoped authorization environment variable instead. Provider-response observation may recognize a complete abbreviated Reviewed commit field; it grants no review clearance and cannot replace the merge gates.
