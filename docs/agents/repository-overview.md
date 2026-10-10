# Repository Overview

This repository is **Mergepath**, the reference implementation of the AI Agent Tooling Standard. It provides a canonical starting structure for projects that require consistent behavior across multiple AI coding agents and development tools.

Primary stack: Markdown documentation, shell automation, YAML review-policy configuration, and the Mergepath Playground (static HTML + JS at `mergepath/playground/`). Agent role: maintain Mergepath's structure, the review-policy tooling and Playground, and the supporting developer workflows — ensuring documentation and tooling behavior do not drift over time. See [`BRAND.md`](../../BRAND.md) at repo root for the umbrella vocabulary.

The publisher structural fence prevents workflow and job concurrency for all three native required producers. The contract and mutation coverage are in `specs/required_check_publisher.md` and `tests/test_merge_clearance_gate.sh`.

The shared pull-request body parser and its standalone generated runtime are specified in [`specs/pr_body_contract.md`](../../specs/pr_body_contract.md).

The Playground's local simulator and public-repository loader read author-agent declarations at source column zero and fall back to the GitHub login for prose mentions or indented lines. Their reporting contract and regression coverage live in specs/mergepath_playground.md and tests/test_mergepath_playground.sh.

The hub-only Cockpit includes a read-only Fleet audit source: a thirty-minute schedule and authenticated manual refresh share one bounded subprocess and retain last-good rows on failure. Audit workers use the cached reviewer credential in an isolated cache; refresh does not invoke propagation. The separate confirmed-sync flow previews current hub/consumer evidence, requires explicit confirmation and runs the fixed author-wrapped executor; its contract is [Cockpit confirmed sync](https://github.com/nathanjohnpayne/mergepath/blob/main/specs/cockpit_sync.md). Its contract is [Cockpit Fleet](https://github.com/nathanjohnpayne/mergepath/blob/main/specs/cockpit_fleet.md).

The shared CI yq bootstrap installs mikefarah/yq v4.53.6 only after checking the downloaded Linux binary against its pinned SHA-256. Its local no-op behavior, test overrides and fail-closed install contract are specified in [`specs/yq_bootstrap.md`](../../specs/yq_bootstrap.md).

`scripts/ci/check_doc_ownership` is a fail-closed repository-integrity check. It validates the `doc_ownership` inventory and verifies that canonical agent documentation does not contain rendered relative links to hub-only documentation that consumers do not receive. Its Markdown extraction contract is defined in [`specs/doc_ownership_validation.md`](../../specs/doc_ownership_validation.md) and covered by `tests/test_check_doc_ownership.sh`.

The Codex requester and same-agent merge fallback share the substantive review-run selector and approval predicate. Threaded replies alone cannot suppress a needed request, and P0/P1 findings in review bodies retain their approval boundary. See [`specs/codex_request_evidence.md`](../../specs/codex_request_evidence.md).

Blocked review diagnostics bind request age and acknowledgement to an exact `@codex review` command comment; later prose mentions do not replace that evidence. The diagnostic filter preserves requester deduplication and clearance behavior. Its contract and coverage are in [`specs/codex_request_evidence.md`](../../specs/codex_request_evidence.md) and `tests/test_codex_request_evidence.sh`.

The publisher structural fence pins both complete permission maps, excludes extra Checks-API writers and requires the phase-1 token binding. Its contract and mutation coverage are in `specs/required_check_publisher.md` and `tests/test_merge_clearance_gate.sh`.

Cockpit live observations read bounded local Phase 4b heartbeat records independently of accounting history. The launch-owned default directory, canonical process identity, observed adapter clock and separate POST/final-summary facts are specified in `specs/cockpit_live_agents.md`; shared HTTP/SSE and scheduling remain in `specs/cockpit_foundation.md`.

The Cockpit header shows nathanjohnpayne’s author GraphQL allowance first, obtained by a bounded fixed read-only worker using the canonical noninteractive cached-author check; the resident server retains only its reviewer credential and displays that active reviewer’s response-header pools separately. Independent identity, reset, stale and backoff evidence is specified in `specs/cockpit_foundation.md`; telemetry never warms credentials or invokes confirmed sync.

The propagated publisher structural fence also prevents scheduled and manually dispatched runs of the native body/label gate. Its parsed-YAML contract is in `specs/required_check_publisher.md` and its mutation cases are in `tests/test_merge_clearance_gate.sh`.

Phase 4b adapter availability uses the manual-handoff status independently of immutable-input integrity refusals. Missing reviewer CLI/schema and unavailable subscription auth use exit 4; missing jq remains an orchestrator prerequisite with exit 3; binding and live head/base refusals retain exit 3 and cannot enable wave fan-out. See [`specs/phase_4b_immutable_input.md`](../../specs/phase_4b_immutable_input.md).
