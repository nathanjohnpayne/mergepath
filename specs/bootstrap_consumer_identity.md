# Bootstrap Consumer-Identity Scaffold

Feature: honest consumer identity in bootstrapped repos. Stage B of `scripts/bootstrap-new-repo.sh` (implemented in `scripts/bootstrap/template-mirror.sh`, step 5b — `bootstrap::_scaffold_consumer_identity`) rewrites or excludes every surface where a lexical `mergepath → <repo>` name substitution would leave mergepath's self-referential hub identity intact and false in a freshly bootstrapped consumer (#744, extended to `README.md` / `REVIEW_POLICY.md` by #747). The step runs AFTER name substitution so every scrub sees the substituted text, and none of its match patterns contains a `mergepath` token substitution would have rewritten.

## Acceptance criteria

### Identity docs replaced by stubs; machinery docs excluded (#744)

- `BRAND.md` and `docs/agents/repository-overview.md` (100% hub identity) are excluded from the mirror and written fresh as neutral "downstream consumer" stubs: they name and link the mergepath hub, disclaim reference-implementation status for the new repo, drop mergepath's surface vocabulary (Playground / Cockpit / Tiebreaker / Checks), and invite the operator to replace them.
- The hub-only machinery docs — every `class: hub-only` entry in the `doc_ownership:` block of `.mergepath-sync.yml`, currently `docs/agents/bootstrap-runbook.md`, `docs/agents/propagation-ordering.md`, `docs/agents/templated-propagation.md`, `docs/agents/coderabbit-audit.md`, `docs/agents/high-priority-scope-discipline.md` — are excluded from the mirror entirely. That exclusion is **derived** from the class rather than restated: `bootstrap::_derive_hub_only_excludes` reads the inventory out of the source manifest on every run and appends the result to the rsync patterns, so classifying a doc `hub-only` is by itself sufficient to keep it out of a new repo, and there is no second list an author has to remember. The derivation fails closed — a missing manifest, a missing `doc_ownership:` block, an empty hub-only set, or a path carrying an rsync wildcard aborts the mirror rather than proceeding with no hub-only exclusions. The first three describe processes a consumer doesn't run (the propagation wave, the bootstrap wizard, the templated-render engine). `coderabbit-audit.md` joined them in #780's ownership class audit: it is not a shared convention but a record of the template repo's own `.coderabbit.yml` posture (an "our value" column) plus a fleet-wide author-seat sweep across consumers, so a verbatim copy reads as if the new repo were the hub deciding fleet policy. Its two inbound relative links live in `REVIEW_POLICY.md` and are rewritten as absolute hub URLs at the mergepath source — per the #746 "true after substitution, fixed at the source" lesson — rather than added to the consumer-side scrub, so the exclusion strands no reference. `high-priority-scope-discipline.md` is the newest member and the least permanent one: its rules are stated in mergepath issue numbers (#1188/#1189/#1196) and in this repo's Codex/CodeRabbit review-round machinery, so a verbatim copy would hand a new repo evidence it cannot resolve and a review cadence it does not run. `shared-operating-rules.md` deliberately carries only the rules proven true *and* usable everywhere, and this one is not yet either; the manifest note records what promotion to `canonical` would require.
- `CONTEXT.md` (the hub glossary) is excluded from the mirror entirely, not stubbed (#864). Its opening line states hub identity ("the reference implementation … hub of the fleet") that is false in a consumer, and its definitions point at the propagation manifest the mirror deliberately strips — but unlike `BRAND.md` there is no neutral consumer stub worth generating: a glossary is wholly hub-authored voice, so consumers author their own if they want one. It is a root file outside `docs/agents/`, so the `doc_ownership` derivation cannot carry it; it is hand-listed in `BOOTSTRAP_MIRROR_EXCLUDES`.
- `ai_agent_tooling_standard.md` is kept: it is the methodology-neutral Standard the consumer follows, correctly names mergepath as the reference implementation, is not name-substituted, and is link-targeted by `README.md` / `.ai_context.md`.
- The `AGENTS.md` "## Repository Layout" section — which exists solely to justify the mergepath-only `packaging/` dir, excluded from every consumer — is removed; the sections on either side of it survive.

### Canonical agent docs delivered and ordered (#780)

- After the identity scaffold finishes, Stage B derives the complete required agent-doc set from the source `.mergepath-sync.yml`: every `doc_ownership` entry with `class: canonical` whose `pending_manifest` flag is not true. The required set is not duplicated in bootstrap code, so backing a pending canonical doc makes it required on the next bootstrap run automatically.
- Every derived canonical agent doc must exist in the mirrored target. This is a positive post-rsync assertion that a future exclude pattern cannot silently strip a fleet-wide rulebook.
- The target `AGENTS.md` must reference `docs/agents/shared-operating-rules.md` before `docs/agents/operating-rules.md`. Ordering compares both line and column, so two links on one physical line cannot bypass the shared-before-local invariant.

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
- Stage B also fails closed when the source manifest cannot supply a valid, non-empty canonical agent-doc set, when any required canonical agent doc is absent from the target, or when the target `AGENTS.md` omits or misorders the shared and local operating-rule links.
- All rewrites go through a temp file that is discarded on failure — a failed scrub never leaves a half-written doc in the target.

## Non-goals

- Rewriting propagated / kit surfaces (scripts, workflows, CI checks): those stay byte-identical mirrors of the hub by design.
- Curating the consumer's real identity: the stubs are placeholders the operator replaces; the scaffold only guarantees they are not false.
