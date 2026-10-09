---
spec_id: phase_4b_immutable_input
---

# Immutable Phase 4b Review Input

Every enabled Phase 4b run captures a coherent complete base/head pair from the PR API. A private isolated Git object store fetches those exact commit IDs, verifies them, computes their merge base, and generates one read-only binary full-index diff. The adapters require this supplied file and never query a mutable PR diff endpoint. A caller-supplied diff is accepted only when its byte digest equals the captured object-derived diff.

The reasoning model retains the existing strict verdict schema. After model validation, trusted adapter code adds the captured base, head, merge base, original diff digest, actual bounded review-diff digest and observed head-transition generation. The orchestrator validates that binding before acting on a verdict and records the commit IDs and digests in the posted review. Unbound standalone reasoning has no posting authority. Metadata or diff mutation, a changed head/base, unreadable generation evidence, and an observed A to B to A force-push cycle refuse the review write. The final review response must preserve the bound body and reviewed commit ID.

The real-object regression checks immutable A bytes while the mutable source branch names B. Lifecycle coverage executes the production orchestrator and verifies that an A to B to A cycle while the adapter runs posts no review, while unchanged authorized approval still posts. Existing policy byte-budget omissions remain explicit in the review; this change does not broaden their allowlist. Canonical propagation carries the helper and updated adapters together as part of the Phase 4b kit.
