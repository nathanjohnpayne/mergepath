# Bootstrap Consumer-Identity Scaffold

Feature: honest consumer identity in bootstrapped repos. Stage B of `scripts/bootstrap-new-repo.sh` (implemented in `scripts/bootstrap/template-mirror.sh`, step 5b — `bootstrap::_scaffold_consumer_identity`) rewrites or excludes every surface where a lexical `mergepath → <repo>` name substitution would leave mergepath's self-referential hub identity intact and false in a freshly bootstrapped consumer (#744, extended to `README.md` / `REVIEW_POLICY.md` by #747). The step runs AFTER name substitution so every scrub sees the substituted text, and none of its match patterns contains a `mergepath` token substitution would have rewritten.

## Acceptance criteria

### Identity docs replaced by stubs; machinery docs excluded (#744)

- `BRAND.md` and `docs/agents/repository-overview.md` (100% hub identity) are excluded from the mirror and written fresh as neutral "downstream consumer" stubs: they name and link the mergepath hub, disclaim reference-implementation status for the new repo, drop mergepath's surface vocabulary (Playground / Cockpit / Tiebreaker / Checks), and invite the operator to replace them.
- The three hub-only machinery docs — `docs/agents/bootstrap-runbook.md`, `docs/agents/propagation-ordering.md`, `docs/agents/templated-propagation.md` — are excluded from the mirror entirely (they describe processes a consumer doesn't run).
- `ai_agent_tooling_standard.md` is kept: it is the methodology-neutral Standard the consumer follows, correctly names mergepath as the reference implementation, is not name-substituted, and is link-targeted by `README.md` / `.ai_context.md`.
- The `AGENTS.md` "## Repository Layout" section — which exists solely to justify the mergepath-only `packaging/` dir, excluded from every consumer — is removed; the sections on either side of it survive.

### README.md hub-identity scrub (#747)

- The name-substituted `README.md` has its "Reference implementation of the AI Agent Tooling Standard" tagline replaced with honest downstream-consumer framing that links the hub (the file's single intentional `mergepath` reference).
- The BRAND umbrella-vocabulary sentences (the intro's "See `BRAND.md` …" tail and the `BRAND.md` Key-Files row) are rewritten to point at the neutral stub.
- Key-Files / Directory-Structure rows for consumer-excluded surfaces — the playground page, `scripts/policy-sim.sh`, the sync manifest, the reserved-surfaces `mergepath/` directory — are dropped.

### REVIEW_POLICY.md wave-audit reframe (#747)

- `REVIEW_POLICY.md` is copied verbatim (not name-substituted), so its `mergepath` references stay true; only the § Phase 3.5 "Wave audit (#662)" paragraph — hub-only machinery hard-linking the excluded `docs/agents/propagation-ordering.md` — is replaced with a short hub-side pointer paragraph. The replacement consumes the whole paragraph through its terminating blank line OR the next heading line, whichever comes first, so neither a hard-wrapped upstream variant (continuation lines) nor a heading immediately following with no blank-line separator (still valid Markdown) can be swallowed; a post-transform check additionally fails closed if the adjacent Phase 4 heading vanishes.
- A consumer note inserted directly after the "### Phase 3.5" heading frames the section's hub-script references (`scripts/sync-to-downstream.sh`, the `.mergepath-sync.yml` manifest, `scripts/wave-audit.sh`, `docs/agents/propagation-ordering.md`) as living on the hub, while distinguishing `scripts/audit-propagation-lane.sh` — which IS synced into every consumer for its CI checks; only its live fleet-audit mode is hub-side.
- Both the note and the pointer qualify fan-out mirror receipt with "once enrolled as a sync consumer": a freshly bootstrapped repo is not yet enrolled — enrollment in the hub's manifest is a separate post-bootstrap step.
- The in-section cross-reference ("see Wave audit below") and the adjacent Phase headings survive the reframe.

## Preservation boundaries

- Everything not named above flows through the mirror untouched: the genuinely shared `README.md` prose and table rows, all other `REVIEW_POLICY.md` phases, the `AGENTS.md` sections adjacent to the scrubbed one, and the mixed doc `.ai_context.md` (its one false hub line is fixed at the mergepath source so it flows through substitution honestly — no consumer-side edit here, per the #746 "true after substitution" lesson).
- The scaffold step never re-enters substitution: the stubs and rewrites it emits may intentionally carry literal `mergepath` hub references.

## Fail-closed guarantees

- Every scrub is marker-gated: when the doc no longer carries the expected marker (reshaped upstream, or absent from the target), the transform is a no-op and the file is left untouched — no blind edits.
- Inside a gate, the step fails closed (non-zero return; stage B aborts and the stage is NOT recorded as completed, so `--resume` retries it) whenever a hub marker survives the transform in a form it no longer matches: the `AGENTS.md` packaging note, any `README.md` hub marker (reference-implementation claim, playground / policy-sim / Playground / umbrella-vocabulary / propagation-manifest strings), the `REVIEW_POLICY.md` wave-audit marker, a missed consumer-note insertion, or (when the source doc had one) a vanished adjacent Phase 4 heading — the concrete check that the wave-audit paragraph consumer didn't over-consume into the next section.
- All rewrites go through a temp file that is discarded on failure — a failed scrub never leaves a half-written doc in the target.

## Non-goals

- Rewriting propagated / kit surfaces (scripts, workflows, CI checks): those stay byte-identical mirrors of the hub by design.
- Curating the consumer's real identity: the stubs are placeholders the operator replaces; the scaffold only guarantees they are not false.
