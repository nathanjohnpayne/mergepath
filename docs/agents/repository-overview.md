# Repository Overview

This repository is **Mergepath**, the reference implementation of the AI Agent Tooling Standard. It provides a canonical starting structure for projects that require consistent behavior across multiple AI coding agents and development tools.

Primary stack: Markdown documentation, shell automation, YAML review-policy configuration, and the Mergepath Playground (static HTML + JS at `mergepath/playground/`). Agent role: maintain Mergepath's structure, the review-policy tooling and Playground, and the supporting developer workflows — ensuring documentation and tooling behavior do not drift over time. See [`BRAND.md`](../../BRAND.md) at repo root for the umbrella vocabulary.

The shared pull-request body parser and its standalone generated runtime are specified in [`specs/pr_body_contract.md`](../../specs/pr_body_contract.md).

`scripts/ci/check_doc_ownership` is a fail-closed repository-integrity check. It validates the `doc_ownership` inventory and verifies that canonical agent documentation does not contain rendered relative links to hub-only documentation that consumers do not receive. Its Markdown extraction contract is defined in [`specs/doc_ownership_validation.md`](../../specs/doc_ownership_validation.md) and covered by `tests/test_check_doc_ownership.sh`.

Blocked review diagnostics bind request age and acknowledgement to an exact `@codex review` command comment; later prose mentions do not replace that evidence. The diagnostic filter preserves requester deduplication and clearance behavior. Its contract and coverage are in [`specs/codex_request_evidence.md`](../../specs/codex_request_evidence.md) and `tests/test_codex_request_evidence.sh`.
