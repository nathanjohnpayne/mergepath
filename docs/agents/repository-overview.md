# Repository Overview

This repository is **Mergepath**, the reference implementation of the AI Agent Tooling Standard. It provides a canonical starting structure for projects that require consistent behavior across multiple AI coding agents and development tools.

Primary stack: Markdown documentation, shell automation, YAML review-policy configuration, and the Mergepath Playground (static HTML + JS at `mergepath/playground/`). Agent role: maintain Mergepath's structure, the review-policy tooling and Playground, and the supporting developer workflows — ensuring documentation and tooling behavior do not drift over time. See [`BRAND.md`](../../BRAND.md) at repo root for the umbrella vocabulary.

`scripts/ci/check_doc_ownership` is a fail-closed repository-integrity check. It validates the `doc_ownership` inventory and verifies that canonical agent documentation does not contain rendered relative links to hub-only documentation that consumers do not receive. Its Markdown extraction contract is defined in [`specs/doc_ownership_validation.md`](../../specs/doc_ownership_validation.md) and covered by `tests/test_check_doc_ownership.sh`.
