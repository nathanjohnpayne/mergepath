# Mergepath rules catalog

This catalog documents every normative rule of Mergepath in English, in one place, with a stable ID per rule. It is a **derived model**, like the root [`CONTEXT.md`](https://github.com/nathanjohnpayne/mergepath/blob/main/CONTEXT.md) glossary: the canonical sources — `REVIEW_POLICY.md`, `AGENTS.md`, `DEPLOYMENT.md`, `.github/review-policy.yml`, `rules/repo_rules.md`, `ai_agent_tooling_standard.md`, the `docs/agents/` tree, and the propagation manifest — remain the normative homes, and on any divergence the source wins. Each entry cites its source; nothing here adds a rule that does not exist at a source.

IDs are stable and never reused or renumbered, so a rule added later takes the next free ID in its part and is filed under the section matching its source. Numeric order therefore need not follow document order — read the section headings, not the numbers, to find a topic.

Legend: **●** marks a configuration rule — it constrains an observable arrangement of entities (identities, PRs, reviews, labels, threads, docs, manifest entries) and is machine-checkable in principle; the OWL companion ([`mergepath-rules.ttl`](mergepath-rules.ttl), see [`README.md`](README.md)) formalizes a core subset of these as axioms whose violation a reasoner detects. **○** marks a procedural rule — it constrains ordering, waiting, or judgment, and is enforced by agents, reviewers, and the shell gates rather than a logic reasoner.

The catalog has two parts mirroring the corpus: **Part R** (the review pipeline: `REVIEW_POLICY.md`, `AGENTS.md` § Code Review Policy, `review-policy.yml`) and **Part G** (structure and governance: the Standard, `rules/`, `docs/agents/`, the manifest). The sources themselves overlap — AGENTS.md summarizes REVIEW_POLICY.md, the overlay restates parts of the shared core as recorded transitional debt — so a handful of rules appear in both parts under their respective sources; load-bearing duplicates carry cross-references.

## Source inconsistencies surfaced while building this catalog

- **Post-review issue timing** — AGENTS.md step 9 mandates creating post-review issues "before merging", while `REVIEW_POLICY.md` § Post-Merge Issue Creation permits "before or immediately after merging" (its Phase 4b step ordering sides with AGENTS.md). See R-152.
- **SSH signing-key paths** — `REVIEW_POLICY.md` § SSH Signing Keys names `~/.ssh/keys/github_<bot>.pub`, while § 1Password SSH agent setup and § Adding a New Agent use `~/.ssh/id_nathanpayne_{agent}.pub` — two path conventions for the same artifact.
- **Operating-rules duplication** — `docs/agents/operating-rules.md` restates several shared-core rules verbatim; the file itself and the manifest's `doc_ownership` note record this as transitional debt to split (G-62), so it is a known, tracked exception to G-27.
- **Deploy-auth retry instruction** — the fleet stop-and-prompt rule (G-192: on a sign-in failure, stop immediately — no retries, no workarounds) is contradicted in two places, one of them inside a single file. `docs/agents/deployment-process.md` mandates the pause-and-prompt procedure for exactly this failure ("Do not retry or work around the failure without the human present") and then, in its credential-source debugging list, instructs "If `op item get` errors with a sign-in failure, run `op signin` and retry" — a direct internal conflict (G-287 vs. the same file's own diagnosis steps). DEPLOYMENT.md § Rotating a Firebase deploy SA key repeats the same "Run `op signin` and re-try" advice, and two weaker occurrences share the self-remediation framing: § Auth Maintenance opens auth-failure handling with "first make sure the 1Password CLI is signed in", and § Reviewer PAT quick check counsels proceeding through an apparent not-signed-in state because the read itself may trigger the biometric prompt. (§ New Machine Setup's bare `op signin` is first-time provisioning, not failure recovery, and is out of scope.)
- **On-disk headless deploy keys** — DEPLOYMENT.md § CI/CD & Headless Deploy instructs writing the deployer SA key JSON to persistent on-disk paths, contradicting both the same file's § Secrets Management ("not stored on disk except as a tempfile during a single deploy invocation") and G-284.
- **Branch-protection posture** — DEPLOYMENT.md § Machine User Setup (G-346/G-347: one approving review, two required checks, admin bypass left available) predates and contradicts REVIEW_POLICY.md § Required status checks and ADR 0002 (the canonical five checks, hub admin enforcement); the ADR posture governs.

## Part R — Review pipeline rules

### Default disposition and deferral

**R-1.** An agent must drive every PR autonomously from author through review to merge and must never pause to ask the human for merge permission. ○ — REVIEW_POLICY.md § Default disposition

**R-2.** An agent may defer to a human for exactly two reasons: an explicit human instruction or a `human-hold` / `needs-human-review` / `policy-violation` label, or a required Phase 4b handoff or Phase 4a escalation. ● — REVIEW_POLICY.md § Default disposition

**R-3.** An agent must never present a "how far should I take this PR?" disposition prompt on the happy path; doing so is a policy deviation, not a courtesy. ○ — REVIEW_POLICY.md § Default disposition

**R-4.** An agent must never work around a stuck required gate in order to merge, and must never ask permission to merge a green one. ○ — REVIEW_POLICY.md § Default disposition

**R-5.** A red required check, unresolved review conversations, or a CodeRabbit rate-limit stall are non-discretionary blockers, never disposition choices. ● — REVIEW_POLICY.md § Default disposition

**R-6.** A CodeRabbit wait exit `5` with `codex_failover_requested: false` must be escalated to the human and the PR must not proceed; with `codex_failover_requested: true` it is a non-blocking note. ● — REVIEW_POLICY.md § Default disposition, § Phase 2.5

**R-7.** Phase 4b is the only sanctioned place at which an agent may post a handoff message and wait for a human-mediated external review. ○ — REVIEW_POLICY.md § Default disposition

### Identity model

**R-8.** An agent must never review its own code under the same identity that authored it. ● — REVIEW_POLICY.md § Identity Rules

**R-9.** Only the author identity `nathanjohnpayne` merges to the target branch, always. ● — REVIEW_POLICY.md § Identity Rules

**R-10.** Reviewer identities may only post review comments, request changes, and approve; they must never merge. ● — REVIEW_POLICY.md § Identity Rules

**R-11.** All agents author and commit as `nathanjohnpayne`; each agent reviews under its own registered reviewer identity (`nathanpayne-{agent}`). ● — AGENTS.md § Identity Rules

**R-12.** The machine-global gh keyring's active account must never be relied on for author or reviewer bylines; the per-command token is the attribution source. ○ — REVIEW_POLICY.md § Reviewer PAT Quick Start

**R-13.** On a PR meeting the external-review threshold or matching a protected path, the authoring agent's own reviewer identity must post comments only and must never approve. ● — REVIEW_POLICY.md § No-self-approve scoping

**R-14.** On an under-threshold PR, reviewer-identity self-approval (after CodeRabbit clears the current HEAD) is the intended path, not a violation. ● — REVIEW_POLICY.md § No-self-approve scoping

**R-15.** A same-agent approve on an over-threshold PR is hard-blocked by the guard hook. ● — REVIEW_POLICY.md § Operation-to-Identity Matrix

### Credentials, wrappers, and guarded writes

**R-16.** The guarded write surface — `gh pr create|merge|edit|comment|review` and `gh issue comment` — must go through the identity-verifying author or reviewer wrapper. ● — REVIEW_POLICY.md § Operation-to-Identity Matrix

**R-17.** Bare and inline-token guarded writes fail closed in the guard hook; an inline `GH_TOKEN` is not a wrapper substitute because it proves nothing about the token's identity. ● — REVIEW_POLICY.md § Reviewer PAT Quick Start

**R-18.** The guard must also block wrapper spoofing (a wrapper path appearing in a command that does not actually invoke it). ● — REVIEW_POLICY.md § Operation-to-Identity Matrix

**R-19.** A wrapper must resolve the expected token, verify its effective login, and exit before the wrapped write on any mismatch. ● — REVIEW_POLICY.md § Reviewer PAT Quick Start

**R-20.** Wrappers must never mutate machine-global gh account selection. ● — REVIEW_POLICY.md § Reviewer PAT Quick Start

**R-21.** For `gh pr create`, the author wrapper must additionally verify the created PR's author login and exit non-zero on mismatch. ● — REVIEW_POLICY.md § Recovery § Prevention

**R-22.** `gh auth status` must never be used as attribution proof. ○ — REVIEW_POLICY.md § PAT lookup table

**R-23.** The `@codex review` trigger comment must be authored by `nathanjohnpayne` through the author wrapper; a reviewer- or bot-authored trigger is silently ignored and must not be used. ● — REVIEW_POLICY.md § Phase 4a

**R-24.** Reviewer-side comments, reviews, and issue comments must carry the reviewer-identity byline via the reviewer wrapper. ● — REVIEW_POLICY.md § Operation-to-Identity Matrix

**R-25.** The `resolveReviewThread` mutation must run under the reviewer PAT with an identity check performed before the mutation. ● — REVIEW_POLICY.md § Operation-to-Identity Matrix

**R-26.** Legacy keyring assertion modes are compatibility checks only, never the canonical path for guarded writes. ○ — REVIEW_POLICY.md § Operation-to-Identity Matrix

**R-27.** Reviewer identities never author commits; the commit byline always comes from the machine-global git config author identity. ● — REVIEW_POLICY.md § Git commit identity

**R-28.** An agent must never run a bare (non-global) `git config user.name` / `user.email` inside a managed checkout. ● — REVIEW_POLICY.md § Git commit identity

**R-29.** If a verified git identity value is absent or wrong, the agent must stop and run the approved machine-setup flow; the policy publishes no pasteable identity setter. ○ — REVIEW_POLICY.md § Git commit identity

**R-30.** On a 1Password sign-in or biometric failure, the agent must pause and prompt — never hardcode tokens, skip review, or retry in a loop. ○ — REVIEW_POLICY.md § GitHub API authentication

**R-31.** Reviewer PATs must be classic PATs with `repo` scope, stored in 1Password with a concealed token field, and accessed by item ID, never by title. ● — REVIEW_POLICY.md § PAT requirements

**R-32.** Credential preflight runs once at session start, is re-validated with `--check` on every subsequent tool call, and is purged at session end. ○ — REVIEW_POLICY.md § Phase 0

**R-33.** `--check` must never invoke `op`, never warm SSH, and must exit non-zero on a missing or stale cache. ● — REVIEW_POLICY.md § Phase 0

**R-34.** Inline `op read` is setup-only; routine work uses the cached preflight variables. ○ — REVIEW_POLICY.md § Fallback / setup-only

### Authoring and internal review

**R-35.** Every PR description must include an `Authoring-Agent:` line naming the agent that wrote the code. ● — REVIEW_POLICY.md § Phase 1

**R-36.** A PR's title and description must describe the work, not the session that produced it. ○ — REVIEW_POLICY.md § Phase 1 (see G-211)

**R-37.** Internal review repeats until the reviewer identity signs off with no outstanding issues. ○ — REVIEW_POLICY.md § Phase 2

**R-38.** All review rounds must be captured as PR comments and commits. ● — REVIEW_POLICY.md § Phase 2

### CodeRabbit (Phase 2.5)

**R-39.** The agent must wait for CodeRabbit's review on the current HEAD before proceeding past Phase 2.5 exactly when `scripts/coderabbit-should-invoke.sh <PR#>` exits 0. `coderabbit.enabled: true` is necessary but not sufficient — the `coderabbit.invoke` mode (`always` / `complex-changes` / `never`) decides whether THIS PR gets the wait, and the decider resolves every ambiguous policy to invoking. ○ — REVIEW_POLICY.md § Phase 2.5

**R-40.** The agent must not hand-wait a folkloric interval and escalate early; the wait helper's measured windows govern. ○ — review-policy.yml § CodeRabbit

**R-41.** Both comment endpoints — issue comments and inline review comments — must be read. ● — REVIEW_POLICY.md § Phase 2.5

**R-42.** Every CodeRabbit `Potential issue` / `⚠️` finding must be explicitly fixed or dismissed with reasoning. ● — REVIEW_POLICY.md § Phase 2.5

**R-43.** CodeRabbit review is advisory: it must not block merge via CI and never submits a changes-requested state — where a repo opts in, the severity gate enforcing the shared resolved required-tier set (R-143) as a required check is what makes required-tier findings merge-blocking, while the fleet safety floor (G-149) is what keeps the review itself advisory. ● — REVIEW_POLICY.md § Phase 2.5

**R-44.** Advisory status never overrides the conversation-resolution gate: an unresolved CodeRabbit thread still blocks merge until fixed-or-rebutted and resolved. ● — REVIEW_POLICY.md § Phase 2.5

**R-45.** The CodeRabbit **App** reviews all PRs in enabled repos regardless of size — `.coderabbit.yml` governs it and `coderabbit.invoke` does not, so a skipped Phase 2.5 still accrues App findings as unresolved threads (wave fan-out mirrors, opened with the ignore marker, are the exception — R-201). What is now selective is the **agent's wait**, which R-39 keys to the decider; the two must not be conflated. ● — REVIEW_POLICY.md § Phase 2.5

**R-46.** A wait exit `6` (skip: paused / non-base-branch / draft) must have its named cause resolved and is never a clean clearance. ● — REVIEW_POLICY.md § Phase 2.5

**R-47.** A status-probe reply is narration only, never a review or clearance signal. ● — REVIEW_POLICY.md § Phase 2.5

**R-48.** The StatusContext fast path is never unconditional clearance: current-HEAD inline findings must still be scanned and reported. ● — review-policy.yml § trust_status_context_for_clearance

### Pre-merge conversation gate and thread resolution

**R-49.** Every merge path must pass the pre-merge review conversation gate immediately before merging, and must repeat it after any push or thread reply. ○ — REVIEW_POLICY.md § Pre-Merge Review Conversation Gate

**R-50.** The gate must query review-thread state (`isResolved`), never flat comment lists or `gh pr checks`. ● — REVIEW_POLICY.md § Pre-Merge Review Conversation Gate

**R-51.** Zero unresolved review conversations must be confirmed before merge. ● — REVIEW_POLICY.md § Pre-Merge Review Conversation Gate

**R-52.** Thread resolution and both feedback recorders run unconditionally before every merge — never gated on merge state or on whether the repo enforces conversation resolution. ○ — REVIEW_POLICY.md § Pre-Merge Review Conversation Gate

**R-53.** The resolve mode must match the actual disposition: actioned for fixed-or-rebutted, auto-resolve for explicit deferral, verified-propagation for byte-verified mirrors. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-54.** The deferral mode must not be used on findings that were fixed or rebutted — that mis-records them. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-55.** Routing-only classes (canonical-coverage, templated-render) are never treated as actioned by routing alone. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-56.** Verified-propagation resolution requires byte-match at the compared ref, matching tree-entry mode and type, and a source fix commit strictly newer than the finding; any lookup, fetch, or render failure is a fail-closed skip. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-57.** Every resolve runs an identity-checked mutation plus a readback confirming resolution, and fails closed when unconfirmed. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-58.** A mutation returning success without a resolved readback is a failure, never a resolution. ● — REVIEW_POLICY.md § resolveReviewThread

**R-59.** Registered agent-reviewer threads may be resolved only after the finding was fixed or rebutted and that reviewer identity accepted, approved, or acknowledged. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-60.** Agents must never auto-resolve real human-authored threads, regardless of state; an unresolved human thread stops the merge until the human acts. ● — REVIEW_POLICY.md § Pre-Merge gate

**R-61.** An agent may use the resolve mutation only when the finding is demonstrably addressed on the current HEAD or rebutted on the thread. ● — REVIEW_POLICY.md § resolveReviewThread

**R-62.** Thread resolution is a clean-up mechanism, never a policy override: it authorizes no label removal, no review bypass, no merging past unaddressed findings. ○ — REVIEW_POLICY.md § resolveReviewThread

**R-63.** If a resolution is not demonstrable, the agent requests a fresh bot review rather than resolving. ○ — REVIEW_POLICY.md § Pre-Merge gate

**R-64.** The conversation gate applies to under-threshold, Phase 4a, Phase 4b, and lane PRs alike. ● — REVIEW_POLICY.md § Pre-Merge Review Conversation Gate

**R-65.** The weekly sweep is not a ledger audit: it catches a skipped thread-resolution run, never a skipped recorder. ○ — REVIEW_POLICY.md § Pre-Merge gate

### Decision records (policy-side; detail in Part G § X)

**R-66.** A PR that reverses a recorded position must carry a `## Path taken` section in its body. ● — REVIEW_POLICY.md § Decision records (= G-221)

**R-67.** Struck acceptance criteria stay visible as strikethrough, never deleted. ● — REVIEW_POLICY.md § Decision records (= G-225)

**R-68.** The path record goes in the PR body, never the title. ● — REVIEW_POLICY.md § Decision records (= G-226)

**R-69.** The non-triggers are as binding as the triggers: fixing a finding and pushing is not a reversal, and neither is implementing an issue in a different shape from the outset. ○ — REVIEW_POLICY.md § Decision records (= G-222)

**R-70.** A material decision landing in an issue comment must be surfaced by a one-sentence body callout linking the exact comment permalink, both writes idempotency-markered and read back. ● — REVIEW_POLICY.md § Decision records (= G-229)

**R-71.** Decision records are not CI-enforced; reviewers are the enforcement point. ○ — REVIEW_POLICY.md § Decision records (= G-247)

### Threshold, trigger, and Phase 3

**R-72.** Under request-by-default, the agent (not any workflow) posts the Codex trigger on every PR, including under-threshold ones. ● — REVIEW_POLICY.md § Phase 3

**R-73.** The under-threshold Codex trigger is advisory and never gates the merge; a timeout or skip does not block. ● — REVIEW_POLICY.md § Phase 3

**R-74.** Findings capture is HEAD-pinned and happens before the fix push; recording afterwards runs only against the captured findings. ○ — REVIEW_POLICY.md § Phase 3

**R-75.** No handoff message is posted from Phase 3; only Phase 4b posts one. ● — REVIEW_POLICY.md § Phase 3

### Propagation lane and wave audit (policy side)

**R-76.** A propagation PR is exempt from external review only when all four lane criteria hold: lane enabled, branch-prefix match, author-identity author, and verified byte-for-byte mirror. ● — REVIEW_POLICY.md § Phase 3.5

**R-77.** Path confinement alone never qualifies a PR for the lane; the byte-level comparison is the load-bearing criterion. ● — REVIEW_POLICY.md § Phase 3.5

**R-78.** All lane trust inputs come from outside the PR's own checkout: config from the base commit, verifier and manifest and content from immutable public Mergepath at the declared commit. ● — REVIEW_POLICY.md § Phase 3.5

**R-79.** An enable flag must not live solely in a never-propagated file (hence the lane defaults ON when its block is absent). ○ — REVIEW_POLICY.md § Phase 3.5

**R-80.** A lane PR is not un-reviewed: required CI, advisory review (on the canary), and an internal approval still apply; only the cross-agent external review is removed. ● — REVIEW_POLICY.md § Phase 3.5

**R-81.** Lane clearance is re-derived from the head-pinned verified-head marker on the current head; label events are never head-pinned proof. ● — REVIEW_POLICY.md § Phase 3.5

**R-82.** The wave audit fails closed unless the canary head is lane-verified, and newly manifest-added paths are audited in full against the empty tree. ● — REVIEW_POLICY.md § Phase 3.5

**R-83.** On a wave-audit changes-requested, the fix lands at the source and the wave is re-cut — never patched in the mirror. ○ — REVIEW_POLICY.md § Phase 3.5

**R-84.** The wave-audit watermark advances only on a posted approval (or a scope-empty range — G-95). ● — REVIEW_POLICY.md § Phase 3.5

### Phase 4a — Codex loop

**R-85.** Phase 4a applies only when Codex is enabled and the App is review-ready; otherwise skip directly to Phase 4b. ● — REVIEW_POLICY.md § Phase 4a

**R-86.** App review-readiness is verified only by observation of a recent Codex review, never by the installation API. ○ — REVIEW_POLICY.md § Phase 4a

**R-87.** Posting the trigger is mandatory on every round including the first; a fix push never re-triggers Codex, and on-open auto-review must not be relied on. ● — REVIEW_POLICY.md § Phase 4a

**R-88.** Codex completion is checked as the union of both endpoints, filtered to the Codex bot, HEAD-anchored; single-endpoint watchers are prohibited. ● — REVIEW_POLICY.md § Phase 4a

**R-89.** A Codex signal counts only when its HEAD anchor matches the PR HEAD — the review's commit id, or the reviewed-commit line prefixing HEAD. ● — REVIEW_POLICY.md § Phase 4a

**R-90.** The eyes reaction is acknowledgment only, never clearance. ● — REVIEW_POLICY.md § Phase 4a

**R-91.** Silence is never implicit approval; a timeout exits to the fallback path. ● — REVIEW_POLICY.md § Phase 4a

**R-92.** An ambiguous, stale-HEAD, findings-bearing, or unrecognized verdict comment must fail closed, never clear the gate. ● — REVIEW_POLICY.md § Phase 4a

**R-93.** An account- or connection-level block is terminal: short-circuit immediately, route to Phase 4b naming the real cause, never report it as generic latency. ● — REVIEW_POLICY.md § Phase 4a

**R-94.** A Codex thumbs-up clears gate (c) only within the reaction freshness window and at-or-after the HEAD anchor. ● — review-policy.yml § reaction_freshness_window_seconds

**R-95.** The CodeRabbit HEAD anchor is floored by the wallclock freshness window against rewritten committer dates. ● — review-policy.yml § wallclock_freshness_window_seconds

### The merge gate

**R-96.** Gate (a): all required CI checks green; the require-CI-green knob is not disabled without explicit human authorization. ● — REVIEW_POLICY.md § Phase 4a

**R-97.** Gate (b) branch 1: an APPROVED review from a registered reviewer identity different from the authoring agent. ● — REVIEW_POLICY.md § Phase 4a

**R-98.** Gate (b) branch 2 (same-agent fallback): with Codex enabled and the authoring agent registered, a fresh Codex thumbs-up or a HEAD-anchored affirmative verdict substitutes for the approval state. ● — REVIEW_POLICY.md § Phase 4a

**R-99.** Gate (c): Codex clearance on the current HEAD in one of the three recognized forms, or a same-fingerprint carry-forward, or a Phase 4b substitute approval. ● — REVIEW_POLICY.md § Phase 4a

**R-100.** The fingerprint carry-forward covers base-only churn exclusively; any changed reviewed content invalidates it. ● — REVIEW_POLICY.md § Phase 4a

**R-101.** With Codex disabled, Codex signals are ignored and gate (c) clears only through the Phase 4b substitute. ● — REVIEW_POLICY.md § Phase 4a

**R-102.** The merge gate must never require an APPROVED state from the Codex bot — the App does not emit that state. ● — REVIEW_POLICY.md § Phase 4a

**R-103.** On a passing merge gate, the conversation gate still runs; any unresolved thread stops the merge. ○ — REVIEW_POLICY.md § Phase 4a

**R-104.** After both gates are clean, the author identity merges (squash, delete branch). ● — REVIEW_POLICY.md § Phase 4a

**R-105.** An agent never uses an admin merge without an explicit human break-glass authorization in chat. ● — REVIEW_POLICY.md § Phase 4a

### Auto-merge and Dependabot

**R-106.** Non-Dependabot unattended merging is disabled pending #1058's merge-group boundary; Agent Review never arms, enqueues, or merges those PRs. ● — REVIEW_POLICY.md § Agent prohibitions

**R-107.** `AUTHOR_MERGE_TOKEN` may authenticate privileged readiness evaluation, but it does not authorize a non-Dependabot merge mutation; ordinary one-shot author merge remains the path. ● — REVIEW_POLICY.md § Agent prohibitions

**R-108.** Reviewer tokens are never used for merges. ● — REVIEW_POLICY.md § Phase 4a

**R-109.** Automatic merge is not a sanctioned reviewer-identity exception. ○ — REVIEW_POLICY.md § Agent prohibitions

**R-110.** Every approval-readiness evaluation requires an existing non-author latest-state approval; a push with no approval never becomes ready, and no evaluation creates a durable arm. ● — REVIEW_POLICY.md § Phase 4a

**R-111.** Every readiness gate re-applies on the new HEAD and governing base, and every exit performs workflow-token arm cleanup; ambiguous cleanup fails closed. ● — REVIEW_POLICY.md § Phase 4a

**R-112.** Rate-limit protection is never derived from label events; it uses the intrinsic threshold and protected-path computation on the live head. ● — REVIEW_POLICY.md § Phase 2.5

**R-113.** An external gate counts as protective only when enforced — enabled in the governing policy and observably required on the base branch; undeterminable enforcement counts as not-enforced. ● — REVIEW_POLICY.md § Phase 2.5

**R-114.** Unprotected or vacuously gated rate-limit stalls keep blocking auto-merge. ● — REVIEW_POLICY.md § Phase 2.5

**R-115.** Blocking-label removals are performed with a PAT, because default-token events fire no workflows. ● — REVIEW_POLICY.md § Phase 4a

### Phase 4b

**R-116.** With automation enabled, the agent runs the orchestrator itself and does not post the manual handoff. ● — REVIEW_POLICY.md § Phase 4b

**R-117.** The orchestrator, adapters, and reviewer wrapper execute from a trusted main-ref checkout, never from the PR-under-review's own checkout. ● — REVIEW_POLICY.md § Phase 4b

**R-118.** Exit 1 (changes-requested posted) is a completed round: address, push, rerun — never the manual handoff. ● — REVIEW_POLICY.md § Phase 4b

**R-119.** Exit 6 is held, not failed: wait the carried retry interval and rerun; never post the manual handoff for a hold. ● — REVIEW_POLICY.md § Phase 4b

**R-120.** Only exits 2, 3, 4, and 5 fall through to the manual handoff. ● — REVIEW_POLICY.md § Phase 4b

**R-121.** Action-shaped holds (draft PR, non-base target) get their cause fixed, not retried. ○ — REVIEW_POLICY.md § Phase 4b

**R-122.** The hold's resume field is read before any manual resume is posted; manual recovery only when the automated one is already spent. ● — REVIEW_POLICY.md § Phase 4b

**R-123.** Retries run from the same trusted checkout, and a hold that never advances is investigated, not looped. ○ — REVIEW_POLICY.md § Phase 4b

**R-124.** Reviewer CLIs run on subscription plans only — never a metered API key; adapters scrub the key variables and fail closed to the manual handoff if not plan-logged-in. ● — REVIEW_POLICY.md § Phase 4b

**R-125.** An ambiguous or non-schema-conformant adapter verdict never becomes an approval. ● — review-policy.yml § fail_closed

**R-126.** A posted approval can never carry a required-tier finding. ● — REVIEW_POLICY.md § Phase 4b accounting

**R-127.** A review-diff section outside the omission allowlist is never omitted; the run fails closed instead, so an approval can never clear the gate around unreviewed code. ● — review-policy.yml § diff_omit_globs

**R-128.** Invalid timeout, effort, or diff-budget config values are rejected fail-closed. ● — REVIEW_POLICY.md § Phase 4b

**R-129.** Invalid propagation-audit config fails closed. ● — review-policy.yml § propagation_audit

**R-130.** Enablement evidence is collected in the posting environment before automation is switched on; a blocked result stops the flip. ● — REVIEW_POLICY.md § Phase 4b

**R-131.** Accounting is advisory to safety: it never blocks a merge, never fabricates, never estimates token counts, and marks unprovable rigor rows as unavailable. ● — REVIEW_POLICY.md § Phase 4b accounting

**R-132.** Billed cost is always $0.00 (plan-based) with metered equivalents clearly labeled notional. ● — REVIEW_POLICY.md § Phase 4b accounting

**R-133.** An approval carrying discretionary findings files one post-review observation issue per finding under the author identity and links them from the approval. ● — review-policy.yml § post_review_issues

**R-134.** In manual Phase 4b, the agent posts the PR-side handoff and emits the chat-side block; neither replaces the other. ● — REVIEW_POLICY.md § Handoff Message Format

**R-135.** The batch chat-side variant is used when alerting about two or more eligible PRs at once. ○ — REVIEW_POLICY.md § Chat-side handoff block

**R-136.** Under `always`, the 4b handoff follows every threshold PR after 4a clearance; under `complex-changes`, the classifier runs between clearance and merge with its exit codes load-bearing. ● — REVIEW_POLICY.md § Phase 4b Triggers

**R-137.** Repos without the default field fall back to fallback-only; new repos inherit complex-changes; the default lives in the parser because the config file is never synced. ● — REVIEW_POLICY.md § Migration for existing consumers

**R-138.** When classifier heuristics are ambiguous, err toward invoking 4b. ○ — REVIEW_POLICY.md § Phase 4b Triggers

### Feedback disposition and ledgers

**R-139.** Every required-tier finding is dispositioned before merge — fixed or rebutted — and its thread resolved. ● — REVIEW_POLICY.md § Feedback Disposition Policy

**R-140.** Discretionary findings never block clearance (their open threads still bind the conversation gate); ignore tiers are never surfaced. ● — REVIEW_POLICY.md § Feedback Disposition Policy

**R-141.** An absent policy block reproduces P0/P1 required and the rest discretionary, with the gates enforcing P1; the default lives in the parser. ● — REVIEW_POLICY.md § Defaults

**R-142.** Address-all mode makes every tier required and ignores the priorities map. ● — REVIEW_POLICY.md § Feedback Disposition Policy

**R-143.** Both severity gates clear a finding the same way — thread resolution — and share one resolved required-tier set so the blocking sets cannot drift. ● — REVIEW_POLICY.md § Enforcement

**R-144.** CodeRabbit findings never map to p0 (Codex-only); unbadged findings are unclassified and therefore discretionary. ● — REVIEW_POLICY.md § Severity ladder

**R-145.** After adjudicating each Codex finding, the validated reaction (+1 fixed, −1 rebutted) is recorded via the recorder. ● — REVIEW_POLICY.md § Phase 4a

**R-146.** A thumbs-up must be validated, not blanket: the referenced location exists on HEAD and the claim reproduces or is addressed. ○ — REVIEW_POLICY.md § Phase 4a

**R-147.** The Codex recorder reacts only to soliciting findings, posts under the reviewer identity, is idempotent and HEAD-pinned, and writes a durable ledger. ● — REVIEW_POLICY.md § Phase 4a

**R-148.** Each CodeRabbit finding's disposition is recorded as fixed or false-positive in the CodeRabbit ledger. ● — REVIEW_POLICY.md § Phase 2.5

**R-149.** The CodeRabbit recorder is disposition-logging only and never writes to GitHub. ● — REVIEW_POLICY.md § Phase 2.5

**R-150.** Both recorders classify tiers via the shared helpers, are HEAD-pinned on scan, and append superseding rows rather than rewriting. ● — REVIEW_POLICY.md § Phase 2.5, § Phase 4a

**R-151.** Ledger recording is disposition-tracking, not a merge gate. ● — REVIEW_POLICY.md § Phase 2.5

### Post-merge issues, escalation, labels

**R-152.** When an external reviewer flags observations or risks while approving, one issue per item — post-review label plus observation or risk, assigned to the author — is filed before merging (AGENTS.md; REVIEW_POLICY.md § Post-Merge Issue Creation permits immediately after — see the inconsistencies note). ● — AGENTS.md step 9

**R-153.** Post-review issues are not merge blockers. ○ — REVIEW_POLICY.md § Post-Merge Issue Creation

**R-154.** Repeat-after-rebuttal — the reviewer re-flags after a rebuttal — is a disagreement and escalates. ● — REVIEW_POLICY.md § Detection signals

**R-155.** Runaway rounds — the counter exceeding the cap — escalates. ● — REVIEW_POLICY.md § Detection signals

**R-156.** On escalation the loop stops entirely: no more commits, no re-trigger, no merge gate, no merge. ○ — REVIEW_POLICY.md § Escalation procedure

**R-157.** The escalation comment names the signal, both positions with links, and the round counter. ● — REVIEW_POLICY.md § Escalation procedure

**R-158.** The human is alerted and the agent waits for an explicit decision. ○ — REVIEW_POLICY.md § Escalation procedure

**R-159.** An agent never resolves a fired escalation signal on its own. ○ — REVIEW_POLICY.md § Escalation procedure

**R-160.** A timeout is not a disagreement: it routes to Phase 4b, never through the tiebreaker. ● — REVIEW_POLICY.md § Detection signals

**R-161.** When reviewers disagree, the human is the tiebreaker; both positions are surfaced and the agent waits. ○ — REVIEW_POLICY.md § Disagreements and Tiebreaking

**R-162.** Agents never modify `needs-external-review`, `needs-human-review`, or `policy-violation`. ● — REVIEW_POLICY.md § Agent prohibitions

**R-163.** Agents may add `human-hold` but never remove it; it is human-remove-only. ● — REVIEW_POLICY.md § Agent prohibitions

**R-164.** `human-hold` supersedes every merge path — clearance, approvals, auto-merge, and break-glass variables. ● — REVIEW_POLICY.md § Agent prohibitions

**R-165.** Chat authorization does not bypass the label-removal guard; the hook enforces at the mechanism layer. ● — REVIEW_POLICY.md § Agent prohibitions

**R-166.** Label removal is requested via the request helper; the human clears the label. ● — REVIEW_POLICY.md § Agent prohibitions

**R-167.** Exactly two automations may remove `needs-external-review` — the auto-clear workflow and the propagation lane — both posting as the Actions bot. ● — REVIEW_POLICY.md § Sanctioned automation exceptions

**R-168.** Those exceptions cover only those two workflows; an interactive agent removing any protected label remains forbidden. ● — REVIEW_POLICY.md § Agent prohibitions

**R-169.** `needs-human-review`, `policy-violation`, and `human-hold` stay manual-only — no automation removes them. ● — REVIEW_POLICY.md § Agent prohibitions

**R-170.** The auto-clear workflow pins its checkout to the default branch and guards against self-fire loops. ● — REVIEW_POLICY.md § Sanctioned automation exceptions

**R-171.** The four blocking labels are the complete Label Gate set. ● — REVIEW_POLICY.md § Required status checks

**R-172.** `decision-needed` is not a merge blocker and stays out of the Label Gate set. ● — REVIEW_POLICY.md § Required status checks

### Required checks and branch protection

**R-173.** Every fleet repo designates the five canonical checks as required on its default branch. ● — REVIEW_POLICY.md § Required status checks

**R-174.** Without the required bit a red workflow is advisory and the PR merges anyway; required-check listing is what enforces. ● — REVIEW_POLICY.md § Required status checks

**R-175.** Self-Review Required fails when the PR body lacks a `## Self-Review` section (Dependabot-exempt). ● — REVIEW_POLICY.md § Required status checks

**R-176.** The severity-gate check names stay frozen even as the gates generalize, because branch protection matches on the name. ● — REVIEW_POLICY.md § Required status checks

**R-177.** Required checks are paired with admin enforcement, because an admin merge bypasses a required check. ● — REVIEW_POLICY.md § Required status checks

**R-178.** The branch-protection audit is read-only. ● — REVIEW_POLICY.md § Required status checks

**R-179.** The audit uses its own admin-scoped token and fails loudly rather than reporting a false all-clear when it is missing or under-scoped. ● — REVIEW_POLICY.md § Required status checks

**R-180.** The audit workflow deliberately has no manual dispatch trigger; off-schedule runs go through repository dispatch. ● — REVIEW_POLICY.md § Required status checks

**R-181.** With the Dependabot arm enabled, the clearance gate blocks a Dependabot PR without a latest-state non-author reviewer approval whose commit id equals the current HEAD. ● — review-policy.yml § dependabot

**R-182.** The clearance gate re-evaluates on every push plus a scheduled sweep, so stale clearances and dismissed approvals cannot ride a new HEAD. ● — REVIEW_POLICY.md § Required status checks

### Threshold evaluation and config resolution

**R-183.** External review is required when non-generated changed lines meet the threshold or any changed file matches a protected path. ● — REVIEW_POLICY.md § Threshold Evaluation

**R-184.** Renames count on both sides: a protected file moved to an unprotected path still matches. ● — REVIEW_POLICY.md § Threshold Evaluation

**R-185.** The governing policy is always the PR's base-branch policy; no surface reads it from the PR's own checkout. ● — REVIEW_POLICY.md § Threshold Evaluation

**R-186.** Default-branch fallback is permitted only on positive proof or a verified 404; unknown is not proof and fails closed. ● — REVIEW_POLICY.md § Threshold Evaluation

**R-187.** The workflow fallback reads from a trusted default-branch worktree, never a bare path resolving against the merge commit. ● — REVIEW_POLICY.md § Threshold Evaluation

**R-188.** The two base-policy implementations are equivalent by contract; a change to one is mirrored in the other. ○ — REVIEW_POLICY.md § Threshold Evaluation

**R-189.** Request-by-default is orthogonal to enablement: it governs when the trigger posts, never whether Codex participates; with Codex disabled no trigger posts at all. ● — REVIEW_POLICY.md § codex.request_by_default

**R-190.** The request script does not recompute the threshold; the caller signals gating explicitly. ● — REVIEW_POLICY.md § codex.request_by_default

**R-191.** The enabled flags govern agent behavior only, never whether the underlying App runs; full disablement requires both. ○ — REVIEW_POLICY.md § Note on enabled flags

**R-192.** Identity switching is fully automated within a session; internal review needs no human. ○ — REVIEW_POLICY.md § Git Identity Switching

**R-193.** A PR created under the wrong identity is closed and recreated through the author wrapper; there is no in-place fix. ● — REVIEW_POLICY.md § Recovery

**R-194.** The recreate runs from a fresh shell so stale token exports cannot leak in. ○ — REVIEW_POLICY.md § Recovery

**R-195.** A new agent follows the reviewer-identity naming pattern, gets Write access, a classic scoped PAT in 1Password, and registration in `available_reviewers`. ● — REVIEW_POLICY.md § Adding a New Agent

**R-196.** Every new repo under the owner carries the policy files, Dependabot config, CODEOWNERS, and SECURITY.md. ● — REVIEW_POLICY.md § Template Usage

**R-197.** Public repos enable secret scanning and push protection. ● — REVIEW_POLICY.md § Template Usage

**R-198.** The lane branch prefix matches the sync script's constant. ● — review-policy.yml § propagation_prs

**R-199.** The Phase 4b CLI login is a member of `available_reviewers`. ● — review-policy.yml § codex.cli_login

**R-200.** The bot login and author identity change only for their stated reasons. ○ — review-policy.yml § codex.bot_login

**R-201.** Fan-out wave mirrors open with the CodeRabbit-ignore marker and get no Codex trigger. ● — REVIEW_POLICY.md § Phase 3.5

**R-202.** The propagation-audit block and wave-audit tooling are hub-side only and deliberately unmanifested. ● — review-policy.yml § propagation_audit

**R-203.** Nitpick-as-required has teeth only under an assertive CodeRabbit profile; the gate warns non-fatally under chill. ● — REVIEW_POLICY.md § CodeRabbit profile dependency

## Part G — Structure and governance rules

### Binding force and priority

**G-1.** Every entry in `rules/repo_rules.md` is a binding constraint, not a suggestion. ○ — rules/repo_rules.md § preamble

**G-2.** If a proposed change would violate any repo rule, stop and flag the conflict before proceeding. ○ — rules/repo_rules.md § preamble

**G-3.** Everything under `rules/` binds and overrides agent judgment. ○ — Standard § Quick Reference

**G-4.** Canonical root files are the authoritative source of truth and outrank tool-folder content in every conflict. ● — Standard § Quick Reference

**G-5.** Specs define intended behavior; code must not diverge from a spec without an explicit update cycle. ○ — Standard § Quick Reference

### Structure invariants

**G-6.** The six canonical root files always exist at the repo root. ● — rules/repo_rules.md § Structure Invariants

**G-7.** Canonical root files are never duplicated or redefined elsewhere. ● — Standard § Canonical Files

**G-8.** `CLAUDE.md` contains only a reading-order pointer and never duplicates instructions. ● — rules/repo_rules.md § Structure Invariants

**G-9.** `AGENTS.md` is a lightweight index into `docs/agents/`. ● — rules/repo_rules.md § Structure Invariants

**G-10.** Tool folders contain configuration only — no instructions, rules, specs, or plans. ● — Standard § Tool Folder Rules

**G-11.** `.cursor/` references `AGENTS.md` rather than redefining it. ● — Standard § Tool-specific guidance

**G-12.** `.claude/` holds minimal configuration; behavioral instructions come from the canonical docs. ○ — Standard § Tool-specific guidance

**G-13.** `.vscode/` carries only settings and extension lists, no project instructions. ● — Standard § Tool-specific guidance

**G-14.** No new top-level directory without justification in `AGENTS.md` or a `plans/` entry. ● — Standard § Repository Layout

**G-15.** Standard repos converge to the documented layout. ● — Standard § Repository Layout

**G-16.** Every standard repo includes `rules/repo_rules.md` with its three sections. ● — Standard § rules/repo_rules.md

**G-17.** Every `AGENTS.md` carries the six required sections in order. ● — Standard § AGENTS.md Required Structure

**G-18.** Missing required sections are flagged, never silently assumed. ○ — Standard § Handling conflicts

**G-19.** `dist/` is gitignored unless versioning it is explicitly justified in `AGENTS.md`. ● — Standard § dist/

**G-20.** Architecture records are consulted before structural changes. ○ — Standard § docs/architecture/

**G-21.** `scripts/ci/` is not modified without explicit instruction. ○ — Standard § scripts/

### Forbidden patterns

**G-22.** Never push directly to main; every change goes through a PR, break-glass excepted only by explicit human authorization in chat. ○ — rules/repo_rules.md § Forbidden Patterns

**G-23.** Instructions are never duplicated between root files and tool folders. ● — rules/repo_rules.md § Forbidden Patterns

**G-24.** `dist/` is never hand-edited; regenerate only. ● — rules/repo_rules.md § Forbidden Patterns

**G-25.** Tests are never deleted to force a passing build. ○ — rules/repo_rules.md § Forbidden Patterns

**G-26.** Secrets are never committed. ● — rules/repo_rules.md § Forbidden Patterns

**G-27.** Logic and instructions are never duplicated anywhere in the repository. ○ — docs/agents/code-modification-rules.md

**G-28.** Duplicates found anywhere are removed, never kept as backups. ○ — Standard § Drift Prevention

**G-29.** CI checks are not disabled or modified without explicit instruction plus a documented justification in `plans/`. ○ — Standard § CI Enforcement

### Conflict matrix and reading order

**G-30.** Code-versus-spec conflicts flag first, then update the spec or tests before the code — the order binds. ○ — Standard § Handling conflicts

**G-31.** A change violating `rules/` stops and is flagged; no proceeding without resolution. ○ — Standard § Handling conflicts

**G-32.** Tool-folder-versus-root conflicts follow the root file; the duplication is flagged for removal. ○ — Standard § Handling conflicts

**G-33.** Canonical root files are read before acting in an unfamiliar repo. ○ — Standard § Canonical Files

**G-34.** The reading order is README → AGENTS → rules → relevant specs → .ai_context. ○ — Standard § Reading order

**G-35.** The shared operating core is read before the local overlay. ○ — docs/agents/shared-operating-rules.md

**G-36.** Where core and overlay overlap, the core is the baseline; the overlay may add but never contradict. ○ — docs/agents/shared-operating-rules.md

**G-37.** A rule true everywhere is raised at the canonical source, never copied between repos. ○ — docs/agents/shared-operating-rules.md

**G-38.** When uncertain about structure or placement, reference the Mergepath reference implementation. ○ — Standard § Reference Implementation

**G-39.** A present PRD mirror is read as product context and never edited directly. ○ — docs/agents/operating-rules.md

### Editing and file creation

**G-40.** Prefer modifying existing files over creating new ones. ○ — docs/agents/code-modification-rules.md

**G-41.** Use existing directories before introducing new ones. ○ — Standard § Creating files

**G-42.** New canonical instructions go only in root files or the appropriate supporting directory — never a tool folder. ● — docs/agents/code-modification-rules.md

**G-43.** Structure stays consistent throughout the repository. ○ — Standard § Editing

**G-44.** Canonical docs stay authoritative and current; tool folders stay minimal. ○ — Standard § Drift Prevention

### Documentation obligations

**G-45.** Documentation updates accompany changes to behavior, build or deploy steps, dependencies, or directory structure. ○ — docs/agents/documentation-rules.md

**G-46.** Behavior changes update the relevant spec and agent-doc before or alongside the code, never after. ○ — docs/agents/documentation-rules.md

**G-47.** Adding or removing an agent-instruction section updates the `AGENTS.md` index in step. ● — docs/agents/documentation-rules.md

**G-48.** Generated and synced mirrors are never edited in place; the canonical source is edited and the sync re-materializes. ● — docs/agents/documentation-rules.md

**G-49.** A generated mirror always carries a machine-readable marker; a docs file with no marker and in no manifest is repo-owned and directly editable. ● — docs/agents/documentation-rules.md

**G-50.** `specs/**` is edited here, never in its central mirror. ○ — docs/agents/documentation-rules.md

**G-51.** PRD mirrors are edited only at the canonical PRD in the central docs repo. ○ — docs/agents/documentation-rules.md

**G-52.** Propagated surfaces on a consumer are fixed at the Mergepath source, never in the consumer copy. ○ — docs/agents/documentation-rules.md

### Canonical-source discipline

**G-53.** A new cross-repo convention is authored in Mergepath first — a dedicated agent-doc when universal enough to sync, else the right existing sub-file. ○ — docs/agents/documentation-rules.md

**G-54.** A convention is never authored downstream-first; downstream-only content is invisible to every other CLI and machine. ○ — docs/agents/documentation-rules.md

**G-55.** Every vendor or machine-local mirror carries a canonical-source annotation pointing back at the authored source. ● — docs/agents/documentation-rules.md

**G-56.** The annotation uses the documented format with the recommended content-hash prefix pin. ● — docs/agents/documentation-rules.md

**G-57.** The canonical-mirror audit is read-only, on-demand, and deliberately not CI-wired (machine-local files are outside every repo). ● — docs/agents/documentation-rules.md

**G-58.** A propagated canonical file is edited at the source, and every sentence in it must be true in every receiving repo. ○ — docs/agents/shared-operating-rules.md

**G-59.** The shared core carries no repo-specific content. ● — docs/agents/shared-operating-rules.md

**G-60.** Issue references in propagated files use the fully-qualified owner/repo#NN form. ● — docs/agents/shared-operating-rules.md

**G-61.** A shared-core rule is not restated in a local overlay; a hand-mirrored second copy is the drift the split exists to end. ○ — docs/agents/operating-rules.md

**G-62.** Existing overlay/core duplication is transitional debt to remove, not a licence to add more. ○ — docs/agents/operating-rules.md

**G-63.** Review rules go in REVIEW_POLICY.md, never in the code-review-requirements pointer. ○ — docs/agents/code-review-requirements.md

**G-64.** Consumer maintainers link a newly delivered canonical doc from their own index; the sync delivers but does not announce. ○ — canonical doc headers

### Doc ownership

**G-65.** Every agent-doc file appears in the ownership inventory exactly once with exactly one class; zero and two both fail. ● — .mergepath-sync.yml § doc_ownership

**G-66.** A canonical-class doc is true verbatim in every receiving repo and is backed by a manifest path entry. ● — .mergepath-sync.yml § doc_ownership

**G-67.** A per-repo-owned doc is never carried as a verbatim canonical or kit entry (the clobber invariant). ● — .mergepath-sync.yml § doc_ownership

**G-68.** A hub-only doc never travels; a consumer copy of one is bootstrap residue to delete. ● — .mergepath-sync.yml § doc_ownership

**G-69.** Bootstrap-seeded is deliberately not an ownership class: delivery is not ownership. ● — .mergepath-sync.yml § doc_ownership

**G-70.** A mixed document is transitional debt to split — classified by dominant ownership with the split noted — never a fourth class. ○ — .mergepath-sync.yml § doc_ownership

**G-71.** Ownership paths exist on disk, in canonical spelling, inside the agent-docs tree. ● — .mergepath-sync.yml § doc_ownership

**G-72.** An unbacked canonical claim fails unless it carries the pending-manifest marker plus a note naming the follow-up. ● — .mergepath-sync.yml § doc_ownership

**G-73.** A PR adding an agent-doc adds its ownership entry in the same PR. ● — .mergepath-sync.yml § ADDING A DOC

**G-74.** A denylisted doc is never classified canonical, so the two declarations of one fact cannot drift. ● — rules/repo_rules.md § check_doc_ownership

**G-75.** Stale, out-of-scope, unknown-class, and dest-remapped ownership entries all fail. ● — rules/repo_rules.md § check_doc_ownership

### Identity-docs denylist

**G-76.** Per-repo identity docs stay absent from the manifest as verbatim entries. ● — .mergepath-sync.yml § identity docs

**G-77.** Hub-only docs likewise stay absent as verbatim entries. ● — .mergepath-sync.yml § identity docs

**G-78.** If a denylisted doc must genuinely be shared, templated rendering is the only escape — never verbatim. ● — .mergepath-sync.yml § identity docs

**G-79.** A canonical or kit entry for a denylisted path fails the manifest check. ● — .mergepath-sync.yml § identity docs

### Propagation closure and manifest hygiene

**G-80.** Every declared requires-path is itself covered by the manifest — an exact entry or strictly inside a kit. ● — .mergepath-sync.yml § requires

**G-81.** Requires additions are conservative: only grep-verifiable hard dependencies. ○ — .mergepath-sync.yml § requires

**G-82.** Soft references and intentionally-unpropagated config are not requires material. ● — .mergepath-sync.yml § requires

**G-83.** No undeclared on-disk dependency may be referenced out of a propagated check or workflow. ● — rules/repo_rules.md § check_propagation_closure

**G-84.** Exclusions are sparing and every entry carries a reason. ● — .mergepath-sync.yml § exclusions

**G-85.** The manifest schema version is authoritative; unknown versions refuse to run. ● — .mergepath-sync.yml § Schema version

**G-86.** Templated entries declare explicit source and dest; for canonical and kit, source equals dest equals path. ● — .mergepath-sync.yml § Path types

**G-87.** A canonical path is byte-for-byte (undeclared difference is drift); a kit path mirrors every hub file byte-identically while ignoring consumer-only siblings. ● — .mergepath-sync.yml § Path types

### Waves, canary, wave audit

**G-88.** Fix at the source, never the consumer copy: editing a mirror breaks the lane fingerprint, forces full review, and is clobbered on the next sync. ○ — docs/agents/propagation-ordering.md

**G-89.** Exactly one consumer is synced and driven green before any fan-out. ○ — docs/agents/propagation-ordering.md

**G-90.** Canary selection follows the dominant risk of the change. ○ — docs/agents/propagation-ordering.md

**G-91.** Fan-out waits for canary lint green and wave-audit clearance (or a recorded unavailability). ○ — docs/agents/propagation-ordering.md

**G-92.** When reconciling a consumer's own enrolment backlog is the dominant risk of a wave, that consumer is the canary for it; enrolment is one selection reason under G-90 rather than an unconditional appointment, and its tier membership does not hold the fan-out, which is gated on canary lint green plus wave-audit clearance. ○ — docs/agents/propagation-ordering.md

**G-93.** A canary failure stops the fan-out; investigation happens in that one PR. ○ — docs/agents/propagation-ordering.md

**G-94.** The wave-audit helper refuses to dispatch unless the canary head carries the lane marker. ● — docs/agents/propagation-ordering.md

**G-95.** The watermark advances only on a posted approval or a scope-empty range; an unavailable reviewer never advances it. ● — docs/agents/propagation-ordering.md

**G-96.** On changes-requested, the fix lands at the source and the wave is re-cut on a fresh canary. ○ — docs/agents/propagation-ordering.md

**G-97.** On reviewer-unavailable the wave may proceed on CI plus lane, recorded, with the un-audited range chaining forward. ○ — docs/agents/propagation-ordering.md

**G-98.** Infrastructure failure is a hard stop, never a proceedable audit miss. ○ — docs/agents/propagation-ordering.md

**G-99.** Approved-wave fan-out mirrors carry the CodeRabbit-ignore marker and no Codex trigger. ○ — docs/agents/propagation-ordering.md

**G-100.** The canary keeps the full advisory CodeRabbit pass. ○ — docs/agents/propagation-ordering.md

**G-101.** Consumer-specific divergence goes through overrides, facts, or exclusions with a reason — never a hand edit. ● — docs/agents/propagation-ordering.md

**G-102.** A real finding on a sync PR is fixed in Mergepath and re-propagated before resolving; a false positive gets a rebuttal; a real-but-non-blocking finding gets a follow-up issue — never a silent drop. ○ — docs/agents/propagation-ordering.md

**G-103.** A stale-payload sync run is never rerun; it is closed and redone. ○ — docs/agents/propagation-ordering.md

**G-104.** The ordering doc is canonical and the wiki log is a log; material changes update both in lockstep. ○ — docs/agents/propagation-ordering.md

**G-105.** The monthly review appends a dated no-change entry or updates log and table together. ○ — docs/agents/propagation-ordering.md

**G-106.** The wave order shifts only on a defensible signal, never cosmetically. ○ — docs/agents/propagation-ordering.md

**G-107.** The documented order is the default for every wave unless a deviation is documented in the wave's tracking issue. ○ — docs/agents/propagation-ordering.md

### Consumer-safe checks and repo lint

**G-108.** Every CI check file is wired as a run step in the lint workflow or its annex, or carries a documented exemption marker. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-109.** A new check and its wiring land in the same PR and travel in the same sync (atomicity). ● — rules/repo_rules.md § check_ci_scripts_wired

**G-110.** Consumers wire local checks in the annex, never by editing the canonical lint workflow. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-111.** Every lint step is consumer-safe: marker-guarded, propagation-complete, or soft-passing. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-112.** Marker-first: the hub-vs-consumer marker test precedes any test of the check's own hub-only artifacts. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-113.** Every hub-only file a gate reads is named by its literal path. ● — docs/agents/propagation-ordering.md

**G-114.** The consumer skip line uses the canonical spelling; the tooling-skip form is reserved for tests. ● — docs/agents/propagation-ordering.md

**G-115.** Residue invariance: no subset of hub-only paths may change a wrapper's verdict. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-116.** A consumer gate references at least one hub-only path or is recorded in the marker-only ratchet with justification. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-117.** The residue ratchet fails equally on a new violator, a stale entry, and an escalated class. ● — rules/repo_rules.md § check_ci_scripts_wired

**G-118.** A consumer failure tracing to a missing hub-only file is fixed at the source with a marker guard, never in the consumer. ○ — docs/agents/propagation-ordering.md

**G-119.** A consumer with local lint edits migrates them to the annex before the first canonical-overwrite wave arrives. ○ — docs/agents/propagation-ordering.md

**G-120.** A manifest-gated skip is forbidden where the wrapped tests propagate to all consumers — a missing one must surface, never be skipped. ● — docs/agents/templated-propagation.md

### Templated propagation

**G-121.** Template keys match the key grammar; a malformed key is a malformed template, distinct from an unset fact. ● — docs/agents/templated-propagation.md

**G-122.** Conditional marker lines are always stripped; only body lines are conditional. ● — docs/agents/templated-propagation.md

**G-123.** Contains-matching is word-boundary; distinct concepts get distinct fact values. ○ — docs/agents/templated-propagation.md

**G-124.** V1 templates use no nesting, no else, no loops, and no block-comment-only languages. ● — docs/agents/templated-propagation.md

**G-125.** The substitution library never toggles the caller's shell options. ● — docs/agents/templated-propagation.md

**G-126.** Nested-mapping fact values and out-of-grammar fact keys are rejected. ● — docs/agents/templated-propagation.md

**G-127.** A rendered dest preserves the source template's git mode and type. ● — docs/agents/templated-propagation.md

**G-128.** The lane skips external review only for provable verbatim mirrors; the verifier byte-compares every changed file. ● — rules/repo_rules.md § check_verify_propagation_pr

**G-129.** Findings on a templated dest route to Mergepath: the fix belongs in the template or the consumer's facts. ○ — docs/agents/templated-propagation.md

### Sync overrides

**G-130.** Every documented divergence carries a non-empty reason; drift without a paper trail is the failure the schema prevents. ● — docs/sync-overrides.md

**G-131.** A consumer with no divergences carries no override file; absence passes. ● — docs/sync-overrides.md

**G-132.** A non-empty override document declares schema version 1. ● — docs/sync-overrides.md

**G-133.** Top-level override keys are a closed set. ● — docs/sync-overrides.md

**G-134.** Skip paths are manifest-declared and substitution keys match declared templated markers. ● — docs/sync-overrides.md

**G-135.** A substitution override is a value-plus-reason map, both non-empty; bare scalars are rejected. ● — docs/sync-overrides.md

**G-136.** A malformed override file blocks merge downstream. ● — docs/sync-overrides.md

**G-137.** Reviewers flag missing or vague reasons. ○ — docs/sync-overrides.md

**G-138.** An override PR carries the entry and the file change together. ○ — docs/sync-overrides.md

**G-139.** Override helpers stay read-only, treat errors as no-override, and never abort the caller. ● — docs/sync-overrides.md

**G-140.** A non-default ESLint flat-config filename requires a filed override exception with a reason. ● — docs/agents/code-modification-rules.md

### Testing and spec alignment

**G-141.** Tests are updated when behavior changes. ○ — docs/agents/testing-requirements.md

**G-142.** Every spec has a corresponding test or a documented exception. ● — docs/agents/testing-requirements.md

**G-143.** All listed CI checks pass before merge. ● — rules/repo_rules.md § CI Enforcement

**G-144.** The review policy pair (document and config) both exist. ● — rules/repo_rules.md § check_review_policy_exists

**G-145.** The governance files (SECURITY, CODEOWNERS, Dependabot config) all exist. ● — rules/repo_rules.md § check_governance_files

**G-146.** The three Codex helper scripts exist, are executable, and their guard suites pass. ● — rules/repo_rules.md § check_codex_scripts

**G-147.** The Codex P1 gate script, workflow, and test exist and the fixture suite passes. ● — rules/repo_rules.md § check_codex_p1_gate

**G-148.** The author-wrapper and guard test suites exist and pass. ● — rules/repo_rules.md § check_gh_as_author

**G-149.** A present CodeRabbit config parses; the template repo pins the chill profile; and fleet-wide, auto-review must not be explicitly disabled and the request-changes workflow must not be enabled, keeping CodeRabbit advisory. ● — rules/repo_rules.md § check_coderabbit_config

**G-150.** The CodeRabbit wait posts at most one status probe, surfaces its reply without changing timeout semantics, and never counts a status reply as clearance. ● — rules/repo_rules.md § check_coderabbit_wait

**G-151.** Disagreement detection lives in the shared decision module required by the workflow, and the human-review label fires only on allow-listed reviewers conflicting on the current head. ● — rules/repo_rules.md § check_disagreement_detector

**G-152.** The session-finalization check and its test exist and pass. ● — rules/repo_rules.md § check_session_finalization

### ESLint policy

**G-153.** A repo with a root package manifest ships a root flat ESLint config loading at least the recommended ruleset. ● — rules/repo_rules.md § ESLint policy

**G-154.** Repos without one are exempt with a not-applicable log line. ● — rules/repo_rules.md § ESLint policy

**G-155.** Legacy config formats never satisfy the policy. ● — rules/repo_rules.md § ESLint policy

**G-156.** The check's environment-error exit is treated as failure so it cannot silently degrade. ● — docs/agents/code-modification-rules.md

### Git identity hygiene

**G-157.** No repo carries a local- or worktree-scoped identity override; an empty-string override counts. ● — rules/repo_rules.md § check_git_identity_hygiene

**G-158.** The git config file is byte-identical across a lint run. ● — rules/repo_rules.md § check_git_identity_hygiene

**G-159.** No tracked hub script or doc writes an identity key without naming a target repo or an out-of-repo scope. ● — rules/repo_rules.md § check_git_identity_hygiene

**G-160.** The include-graph walk fails closed on an unexpandable include: unreadable is never nothing-there. ● — rules/repo_rules.md § check_git_identity_hygiene

**G-161.** A deliberate exception carries the exemption marker as a true comment and exempts only the command it terminates. ● — rules/repo_rules.md § check_git_identity_hygiene

**G-162.** Documentation examples are rewritten non-runnable rather than exempted. ○ — rules/repo_rules.md § check_git_identity_hygiene

**G-163.** Failure remediation is generated from the offenders actually found, one deduplicated unset per key-scope-file, correctly targeted. ● — rules/repo_rules.md § check_git_identity_hygiene

### Session finalization and worktrees

**G-164.** Before a session goes idle, implementation-ready work ends in exactly one durable state: committed PR, explicit handoff, or explicit discard. ○ — docs/agents/operating-rules.md

**G-165.** Follow-up work starts on a fresh branch or worktree from current main, never the just-merged stale checkout. ○ — docs/agents/operating-rules.md

**G-166.** The tracking PR or issue opens early enough for in-flight work to be visible. ○ — docs/agents/operating-rules.md

**G-167.** The finalization check runs before closeout and stays read-only. ● — docs/agents/operating-rules.md

**G-168.** Agent worktrees live in the hidden per-repo folder. ● — docs/agents/worktree-placement.md

**G-169.** No agent checkouts in system temp directories. ● — docs/agents/worktree-placement.md

**G-170.** No visible sibling checkout directories. ● — docs/agents/worktree-placement.md

**G-171.** Placement covers every agent checkout including review-side ones; the trusted-path rule constrains the ref and placement constrains the disk, both at once. ○ — docs/agents/worktree-placement.md

**G-172.** PR-tied checkouts use the parseable PR-number slug. ● — docs/agents/worktree-placement.md

**G-173.** Strays relocate with the worktree-move command, never a plain move. ○ — docs/agents/worktree-placement.md

**G-174.** No CI gate for placement exists or should: repo CI cannot see outside its checkout. ○ — docs/agents/worktree-placement.md

**G-175.** Tool-managed workspaces are governed by the tool's lifecycle, not the convention. ○ — docs/agents/worktree-placement.md

**G-176.** Task worktrees are removed immediately after their branch merges or is deleted. ● — docs/agents/operating-rules.md

**G-177.** No worktree stays checked out on a branch gone from the remote. ● — docs/agents/operating-rules.md

**G-178.** A PR-slug worktree is removable only on a fully-flagged empty status listing (edits, untracked, ignored, submodules all checked). ● — docs/agents/operating-rules.md

**G-179.** Anything git reports is listed for a human and kept; the dry-run holds a non-zero exit until resolved. ● — docs/agents/operating-rules.md

**G-180.** A vanished registered worktree is prunable only when unlocked; locked-and-missing needs explicit force. ● — docs/agents/operating-rules.md

**G-181.** Locked worktrees and orphan directories need explicit per-class opt-in flags to remove. ● — docs/agents/operating-rules.md

**G-182.** A local branch is deleted only after the merged-PR confirmation; checked-out branches are listed but skipped. ● — docs/agents/operating-rules.md

**G-183.** Worktree state is machine-local and never gates repository CI. ○ — docs/agents/operating-rules.md

### Pagination

**G-184.** Every list read of PR comments, reviews, or check runs paginates (or cursors). ● — docs/agents/shared-operating-rules.md

**G-185.** The mandate covers ad-hoc mid-session queries, not just shipped helpers. ○ — docs/agents/shared-operating-rules.md

**G-186.** The capped JSON view is never used for a connection that can exceed its cap. ● — docs/agents/shared-operating-rules.md

**G-187.** Single-item reads are not lists and need no pagination. ● — docs/agents/shared-operating-rules.md

**G-188.** When in doubt, paginate — a no-op on short lists, the only safe default on long ones. ○ — docs/agents/shared-operating-rules.md

### Background jobs and expected duration

**G-378.** A backgrounded command carries an expected duration stated at launch, and is checked against that expectation. ○ — docs/agents/shared-operating-rules.md

**G-379.** "Still running" is never reported as a status without comparing elapsed time to the expectation. ○ — docs/agents/shared-operating-rules.md

**G-380.** A self-terminating command is preferred — `timeout N` inside it — so a hang dies on its own rather than on the agent noticing. ○ — docs/agents/shared-operating-rules.md

**G-381.** A job with no obvious duration still quotes a bound: the provider-poll helper's own `max_wait_seconds` / `review_timeout_seconds`. ○ — docs/agents/shared-operating-rules.md

**G-382.** Any job exceeding roughly 3× its expected duration is investigated rather than reported as normal. ○ — docs/agents/shared-operating-rules.md

**G-383.** Mutating `scripts/phase-4b/lib.sh` and then running `tests/test_phase_4b_automation.sh` against it is forbidden — the orchestrator stacks 900s adapter timeouts; the pure helpers are sourced and asserted on directly instead. ○ — docs/agents/operating-rules.md

### Secrets and credential failure

**G-189.** Never move a secret through a human: no pasted credentials, no printed resolved values. ○ — docs/agents/shared-operating-rules.md

**G-190.** No long-lived keys by convenience; short-lived manager-resolved credentials are the default. ○ — docs/agents/shared-operating-rules.md

**G-191.** Never unilaterally downgrade a repo's auth model, least of all because a credential lookup failed. ○ — docs/agents/shared-operating-rules.md

**G-192.** On a sign-in error, stop immediately: no retries, no workarounds, no fallback credential paths. ○ — docs/agents/shared-operating-rules.md

### MCP tool call confirmation

**G-384.** A tool call that creates, modifies, or deletes a live resource needs explicit human confirmation; read-only calls do not, and indeterminate effect counts as mutating. ○ — docs/agents/shared-operating-rules.md

**G-193.** With no preflight marker set, suggest preflight rather than individual reads. ○ — docs/agents/operating-rules.md

**G-194.** Wait for confirmed human presence before re-running preflight; never substitute individual reads. ○ — docs/agents/operating-rules.md

**G-195.** A second preflight failure is reported in full and waited out — never looped. ○ — docs/agents/operating-rules.md

**G-196.** The stop-and-prompt rule covers sign-in errors only; other credential errors are diagnosed normally. ○ — docs/agents/operating-rules.md

**G-197.** 1Password references use item-UUID paths, never titles. ● — docs/agents/bootstrap-runbook.md

**G-198.** New-repo runtime secrets use the managed patterns, not secure-note bootstrap entries. ○ — docs/agents/bootstrap-runbook.md

**G-199.** Provider spend caps precede pasting LLM API keys. ○ — docs/agents/bootstrap-runbook.md

**G-200.** The auto-merge token is provisioned wherever Dependabot auto-merge is on, and the workflow verifies it resolves to the author identity before merging. ● — docs/agents/bootstrap-runbook.md

**G-201.** Bootstrap write-path calls run under the author identity through token-verifying helpers, per command. ● — docs/agents/bootstrap-runbook.md

**G-202.** The bootstrap push routes through the wrapper's credential binding with prompting disabled, so a credential miss fails rather than prompts. ● — docs/agents/bootstrap-runbook.md

**G-203.** The token remediation hint runs whole, as one chained command. ○ — docs/agents/bootstrap-runbook.md

### Bug-fix escalation and review conduct

**G-204.** After two failed fix attempts, the next attempt opens with a written audit of all prior attempts before any code. ○ — docs/agents/shared-operating-rules.md

**G-205.** The audit lists every prior PR, what it changed, why it fell short, the shared assumption, and a fix addressing that assumption. ○ — docs/agents/shared-operating-rules.md

**G-206.** The audit appears under the titled section in the PR description. ● — docs/agents/shared-operating-rules.md

**G-207.** No identifiable shared assumption means flagging the human, not another incremental fix. ○ — docs/agents/shared-operating-rules.md

**G-208.** After two attempts, rotation to a different agent is recommended — issue plus prior PRs, no narrative framing; the human decides. ○ — docs/agents/shared-operating-rules.md

**G-209.** A serialization-layer PR is reviewed for losslessness, consumer parity, and necessity. ○ — docs/agents/shared-operating-rules.md

**G-210.** A lossy round-trip is flagged as a design risk requiring justification or elimination of the intermediate format. ○ — docs/agents/shared-operating-rules.md

### Narration ban

**G-211.** Titles and descriptions describe the final state for a cold reader. ○ — docs/agents/shared-operating-rules.md

**G-212.** No session narration: no pivots, abandoned approaches, or plan evolution commentary. ○ — docs/agents/shared-operating-rules.md

**G-213.** A pivot updates the text to the new end state, never to the fact of the pivot. ○ — docs/agents/shared-operating-rules.md

**G-214.** An accurate title or description is read-only thereafter. ○ — docs/agents/shared-operating-rules.md

**G-215.** Rationale, alternatives-considered, and prior-code contrast are welcome; the test is usefulness to someone who never saw the session. ○ — docs/agents/shared-operating-rules.md

**G-216.** Carve-out one: a Path taken record in a PR body, by name, only under its triggers, never the title. ○ — docs/agents/shared-operating-rules.md

**G-217.** Carve-out two: a struck acceptance criterion annotated in place with a dated reason, only when a path record fired. ● — docs/agents/shared-operating-rules.md

**G-218.** The narration rule is judgment guidance, deliberately not a lint gate. ○ — docs/agents/shared-operating-rules.md

### Decision records (governance detail)

**G-219.** Record the disposition truthfully, where a later reader will look, never by deleting the replaced state. ○ — docs/agents/decision-records.md

**G-220.** A finding-level record carries one of the seven resolve classes; any other class is non-conformant. ● — docs/agents/decision-records.md

**G-221.** A Path taken record is required when a PR reverses a recorded position. ● — docs/agents/decision-records.md

**G-222.** The non-triggers bind: finding-fixes, rebases, added tests, wording, and different-shape-from-the-outset earn no record. ○ — docs/agents/decision-records.md

**G-223.** An empty record is worse than none; an untriggered one is narration wearing a heading. ○ — docs/agents/decision-records.md

**G-224.** A path record covers chronology, survivals and discards with reasons, arbitration, and struck criteria. ○ — docs/agents/decision-records.md

**G-225.** Discarded criteria are struck, never deleted. ● — docs/agents/decision-records.md

**G-226.** The heading is exactly the canonical form, in the body, never the title. ● — docs/agents/decision-records.md

**G-227.** A pivot is also recorded on the driving issue with the dated marker comment. ● — docs/agents/decision-records.md

**G-228.** A stale issue is retitled once, at the end, after direction settles. ○ — docs/agents/decision-records.md

**G-229.** A comment-recorded decision gets a structured marker comment and a prepended body callout linking it. ● — docs/agents/decision-records.md

**G-230.** The historical problem statement is never rewritten; the callout prepends. ○ — docs/agents/decision-records.md

**G-231.** Marker formats reproduce byte-for-byte; paraphrase defeats the tooling. ● — docs/agents/decision-records.md

**G-232.** The permalink links the exact comment, never the issue; the callout stays one sentence. ● — docs/agents/decision-records.md

**G-233.** Slugs derive from the decision, never a counter. ○ — docs/agents/decision-records.md

**G-234.** Search precedes writing, on the undated body key and the wildcarded comment key — never on a computed date. ● — docs/agents/decision-records.md

**G-235.** Exactly one active body callout; supersession replaces, never doubles. ● — docs/agents/decision-records.md

**G-236.** The whole slug family is searched first; qualification is an output of the disposition. ○ — docs/agents/decision-records.md

**G-237.** Movement off a decision is checked under both marker families. ○ — docs/agents/decision-records.md

**G-238.** A recommendation record is not an acceptance record; matching one while recording acceptance means superseding. ○ — docs/agents/decision-records.md

**G-239.** Returns and acceptances are new records with derived qualifiers, never counters. ● — docs/agents/decision-records.md

**G-240.** Undecidable authorship takes the branch that cannot duplicate: write nothing and surface the conflict. ○ — docs/agents/decision-records.md

**G-241.** Dates come from the matched marker when finishing under an existing record; the clock is only for first records. ○ — docs/agents/decision-records.md

**G-242.** The body is built from a read taken immediately before the write, sent as the very next call. ○ — docs/agents/decision-records.md

**G-243.** Verification is positive readback of all four facts; a non-erroring write is not verification. ● — docs/agents/decision-records.md

**G-244.** The readback does not detect lost updates; fresh-read-then-write is the race mitigation. ○ — docs/agents/decision-records.md

**G-245.** On supersession the old comment stays as history; only the callout is replaced. ● — docs/agents/decision-records.md

**G-246.** A direction-changing supersession also files a path record; accepting a recommendation does not. ○ — docs/agents/decision-records.md

**G-247.** Decision records stay convention-only: no required gate, at most an advisory check on the deliberate marker. ○ — docs/agents/decision-records.md

### Prose line-wrapping

**G-248.** Prose is soft-wrapped, one physical line per paragraph, never fixed-column hard-wrapped. ● — docs/agents/prose-line-wrapping.md

**G-249.** The rule governs intra-paragraph breaks only; structural Markdown is untouched. ● — docs/agents/prose-line-wrapping.md

**G-250.** It applies to hand-authored GitHub text too: issues, PR bodies, review comments. ○ — docs/agents/prose-line-wrapping.md

**G-251.** Never reflow someone else's file: mirrors, marker-bearing files, propagated or rendered surfaces, fixtures, vendored trees. ● — docs/agents/prose-line-wrapping.md

**G-252.** Propagated-file wrapping is fixed at the canonical source and carried by the next sync. ○ — docs/agents/prose-line-wrapping.md

**G-253.** In-scope paths are an explicit fail-safe allowlist, never an exclusion list. ● — docs/agents/prose-line-wrapping.md

**G-254.** A missing gate is not permission to hard-wrap; the convention is the rule. ○ — docs/agents/prose-line-wrapping.md

**G-255.** Mergepath's out-of-scope surfaces are never reflowed; the gate script is the executable allowlist and is not propagated. ● — docs/agents/documentation-rules.md

### Bootstrap

**G-256.** The wizard refuses existing repos and forks; preflight rejects populated targets and pre-existing remotes. ● — docs/agents/bootstrap-runbook.md

**G-257.** Preflight rejects a hub checkout that is off-main or dirty. ● — docs/agents/bootstrap-runbook.md

**G-258.** Hub-only excludes derive at run time from the ownership inventory, and the mirror aborts if derivation fails. ● — docs/agents/bootstrap-runbook.md

**G-259.** Pure-identity docs are excluded and replaced with honest consumer stubs; hub-only layout sections are scrubbed. ● — docs/agents/bootstrap-runbook.md

**G-260.** Identity scrubs fail closed when a hub marker survives untransformed. ● — docs/agents/bootstrap-runbook.md

**G-261.** Phase 4b automation resets to disabled in the new repo. ● — docs/agents/bootstrap-runbook.md

**G-262.** Bootstrap does not enroll the repo as a consumer; enrollment is a required human next step, and an unenrolled repo silently receives nothing. ○ — docs/agents/bootstrap-runbook.md

**G-263.** Enrollment adds verified facts, runs an audit, and drives the first sync canary-first. ○ — docs/agents/bootstrap-runbook.md

**G-264.** Irreversible sub-steps record a name-bound checkpoint before anything after them can fail, and a checkpoint write that does not land aborts the stage. ● — docs/agents/bootstrap-runbook.md

**G-265.** A checkpoint binds the exact repo created, so resume can never bootstrap over a repo this run did not create. ● — docs/agents/bootstrap-runbook.md

**G-266.** Checkpoints live in their own sidecar and are never written under dry-run. ● — docs/agents/bootstrap-runbook.md

**G-267.** Resume only rewinds: the named stage must be recorded; unknown stages refuse. ● — docs/agents/bootstrap-runbook.md

**G-268.** Resume is not a stage-skip; skipping needs explicit state or the skip variable. ○ — docs/agents/bootstrap-runbook.md

**G-269.** The printed resume command names the last completed stage, not the failed one. ● — docs/agents/bootstrap-runbook.md

**G-270.** The YAML tool must be the required implementation and version; anything else fails closed with a targeted diagnostic. ● — docs/agents/bootstrap-runbook.md

**G-271.** A recorded provisioning failure is never deleted by later success; resolution rewrites the line in place preserving the original. ● — docs/agents/bootstrap-runbook.md

**G-272.** A recorded failure names its specific cause, never a generic message. ● — docs/agents/bootstrap-runbook.md

**G-273.** The secret write refuses to run when its trace temp dir cannot be allocated. ● — docs/agents/bootstrap-runbook.md

**G-274.** Only the pre-execution auth branch may persist captured output, because the marker's absence proves nothing read the piped credential. ● — docs/agents/bootstrap-runbook.md

**G-275.** Resolution records classify only on the full keyed line shape; unkeyed or unrecognized shapes remain outstanding. ● — docs/agents/bootstrap-runbook.md

**G-276.** The operator completes the human-action items the wizard cannot automate. ○ — docs/agents/bootstrap-runbook.md

**G-277.** The canonical PRD lives in the central docs repo, not the consumer. ● — docs/agents/bootstrap-runbook.md

### Migration and drift prevention

**G-278.** Existing repos come into compliance via the ten-step migration, validated against the reference implementation. ○ — Standard § Migration Procedure

**G-279.** CI enforcement runs on every commit. ● — Standard § CI Enforcement

**G-280.** The six baseline checks are implemented in the CI-check directory. ● — Standard § CI Enforcement

### Deployment (this repo's per-repo-owned instance)

**G-281.** Firebase and Google Cloud repos prefer the canonical wrapper deploy flow over ad-hoc CLI use. ○ — docs/agents/deployment-process.md

**G-282.** The default deploy credential is the per-project Firebase-vault service-account key, with the shared 1Password ADC as fallback; the precedence order is canonical in DEPLOYMENT.md. ● — docs/agents/deployment-process.md

**G-283.** The 1Password-first deploy-auth model is the deliberate default; swapping it for browser or CLI login because a lookup failed is exactly the forbidden unilateral downgrade (G-191). ○ — docs/agents/deployment-process.md

**G-284.** On-disk deploy keys are never an accepted substitute for the vaulted service-account key. ● — docs/agents/deployment-process.md

**G-285.** A deploy session loads deploy credentials explicitly (deploy-mode preflight); review-mode preflight deliberately does not. ○ — docs/agents/deployment-process.md

**G-286.** When the next operation is broad non-deploy cloud work, use review preflight or unset the exported credential variable so the wrapper resolves its normal chain. ○ — docs/agents/deployment-process.md

**G-287.** A credential sign-in failure during deploy follows the pause-and-prompt procedure (G-192) — no retry or workaround without the human present. ○ — docs/agents/deployment-process.md

**G-288.** Runtime agent secrets use the portable 1Password Environments model; service-account tokens are CI/headless-only under an approved ticket scoping token, vault access, rotation, and log masking — never an attended-agent convenience. ○ — docs/agents/deployment-process.md

**G-289.** The Codex-specific Environments MCP server is not described as a universal agent adapter. ○ — docs/agents/deployment-process.md

**G-290.** The headless review-auth proof is manual-dispatch only, compares digests without printing secret values, and requires the negative-scope sentinel unless explicitly skipped. ● — docs/agents/deployment-process.md

**G-291.** Existing scripts keep shelling out to the 1Password CLI; no language-SDK migration lands without a separate design decision. ○ — docs/agents/deployment-process.md

**G-292.** Service-account key rotation is human-only, never automated by any agent or workflow. ● — docs/agents/deployment-process.md

### CodeRabbit configuration posture (hub-only audit runbook)

**G-293.** `.coderabbit.yml` is deliberately unpropagated: each consumer ships and owns its own copy, and only the universal safety floor is enforced fleet-wide. ● — docs/agents/coderabbit-audit.md

**G-294.** Config drift against the vendor docs resolves as exactly one of four dispositions: a commented config change, a tooling note, a follow-up issue, or a documented no-action on the audit page. ○ — docs/agents/coderabbit-audit.md

**G-295.** Incremental auto-review stays explicitly pinned on — the fix-up-commit loop and HEAD-anchored clearance depend on it, and an accidental off would silently strand every post-open push unreviewed. ● — docs/agents/coderabbit-audit.md

**G-296.** The auto-pause threshold stays unset here; the key is owned by its own tracked issue and is never pinned blind. ○ — docs/agents/coderabbit-audit.md

**G-297.** A PR against a non-default base is not auto-reviewed; a workflow targeting one must add that base to the base-branches list in that repo's own config. ● — docs/agents/coderabbit-audit.md

**G-298.** Learnings scope stays `auto`, which resolves per repo by visibility — `local` for a public repo, `global` for a private one — so the resolution is read off the repo's current visibility rather than assumed uniform across the fleet. ● — docs/agents/coderabbit-audit.md

**G-299.** Path instructions are targeted supplements added on an observed miss, never speculative additions. ○ — docs/agents/coderabbit-audit.md

**G-300.** The rate-limit allowance is checked with the read-only rate-limit command — an authoring write routed through the author wrapper — rather than by spending a review. ○ — docs/agents/coderabbit-audit.md

**G-301.** The PR author must hold an active CodeRabbit seat covering the repo; a missing seat silently disables review, and coverage is confirmed on the dashboard plus the observational cross-check, there being no API surface for it. ● — docs/agents/coderabbit-audit.md

### Deploy guards and entry point (DEPLOYMENT.md, canonical root)

**G-302.** A deploy runs from the main branch. ● — DEPLOYMENT.md § Deployment Steps

**G-303.** Local main must not be behind origin; the deploy refuses when fetch shows unpulled commits. ● — DEPLOYMENT.md § Deployment Steps

**G-304.** The working tree must be clean — no modified, staged, or untracked paths — or the deploy refuses. ● — DEPLOYMENT.md § Deployment Steps

**G-305.** Force and allow-dirty overrides are break-glass only, never routine. ○ — DEPLOYMENT.md § Deployment Steps

**G-306.** The dirty-tree guard is bypassable only by its dedicated env var, never subsumed by the force flag, so the override stays deliberate and audit-greppable. ● — DEPLOYMENT.md § Deployment Steps

**G-307.** An allow-dirty deploy logs the dirty paths to stderr under a warning banner so the deviation appears in the transcript. ● — DEPLOYMENT.md § Deployment Steps

**G-308.** The deploy script is the only sanctioned routine entry point; invoking the underlying deploy tools directly skips the guards and the cache purge. ○ — DEPLOYMENT.md § Deployment Steps

**G-309.** Direct underlying-tool invocation is reserved for debugging and known one-off flows. ○ — DEPLOYMENT.md § Deployment Steps

**G-310.** Deploys stay manual; CI workflows are limited to linting and review-policy enforcement, never deployment. ● — DEPLOYMENT.md § CI/CD Integration

### Deploy credential mechanics

**G-311.** An exported credential path counts as a genuine human override only when no preflight tempfile marker matches the same path. ● — DEPLOYMENT.md § Deploy credential precedence

**G-312.** The deploy precedence applies to deploy flows only; the general cloud wrapper uses its narrower chain and never consults the project deploy key. ● — DEPLOYMENT.md § Deploy credential precedence

**G-313.** The deploy tool logs its selected source credential so deploy auth is never opaque. ● — DEPLOYMENT.md § Deploy credential precedence

**G-314.** The deploy runs non-interactive with an isolated CLI configstore so stale user login tokens cannot override the selected credential. ● — DEPLOYMENT.md § Deployment Steps

**G-315.** Temporary credential files and the isolated configstore are cleaned up on exit. ● — DEPLOYMENT.md § Deployment Steps

**G-316.** Broad non-deploy cloud work uses review preflight or unsets the exported credential so the deploy-scoped key does not leak into general commands. ○ — DEPLOYMENT.md § Deployment Steps

**G-317.** Cloud quota attribution resolves from explicit billing-project, then explicit project, then the nearest repo config, then the active CLI config — never from the deploy script's pin. ● — DEPLOYMENT.md § Deploy credential precedence

**G-318.** The shared human credential is unsuitable for unattended use; headless environments use the project deploy key as primary. ● — DEPLOYMENT.md § Auth Maintenance

**G-319.** Preflight validates a materialized credential against the token endpoint before exporting it, and skips the export with an actionable warning when it is stale. ● — DEPLOYMENT.md § ADC refresh-token expiry

**G-320.** The permanent fix for recurring deploy-auth failures is provisioning or rotating the project key, not deeper dependence on the shared human credential. ○ — DEPLOYMENT.md § ADC refresh-token expiry

### Cache purge

**G-321.** The CDN purge runs only when both its token and zone are set, and no-ops with a clear log line when either is missing — fail-visible, never fail-silent. ● — DEPLOYMENT.md § Deployment Steps

**G-322.** The zone id is set per consumer repo; the token is sourced by deploy preflight, never by an ad-hoc read in the shell. ● — DEPLOYMENT.md § Deployment Steps

### Secrets management (deployment scope)

**G-323.** Resolved secret output, service-account JSON, and application-default credentials are never committed. ● — DEPLOYMENT.md § Secrets Management

**G-324.** Resolved secret values are never printed in logs, PR bodies, or review comments. ● — DEPLOYMENT.md § Secrets Management

**G-325.** Generated env files are never the source of truth: value changes go to the referenced vault item fields, shape changes to the committed template. ○ — DEPLOYMENT.md § Conflict resolution

**G-326.** Template-plus-inject is used only when a tool genuinely requires a materialized file; runtime variable sets use the managed environments model. ○ — DEPLOYMENT.md § Secrets Management

**G-327.** Whole-file secure-note bootstrap is retired and never used. ● — DEPLOYMENT.md § Runtime secrets guardrails

**G-328.** A scoped service account or pre-materialized CI secret is used only after a ticket explicitly approves the scope. ○ — DEPLOYMENT.md § Runtime secrets

**G-329.** Service-account tokens are headless-only and explicit opt-in for every agent client. ● — DEPLOYMENT.md § Runtime secrets

**G-330.** Beta secret-management surfaces are gated on the audit workstream; only the GA portable-core primitives are the safe baseline. ○ — DEPLOYMENT.md § Runtime secrets

### Headless preflight proof lane

**G-331.** Headless token mode writes only the reviewer PAT, marks the cache as token-mode, and skips SSH warming and keyring repair. ● — DEPLOYMENT.md § Headless proof workflow

**G-332.** The proof service account is scoped to the approved PAT items plus the dedicated canary only, with the token stored as an encrypted Actions secret. ● — DEPLOYMENT.md § Headless proof workflow

**G-333.** Token mode is never pointed at a built-in private vault, which service accounts cannot access. ● — DEPLOYMENT.md § Headless proof workflow

**G-334.** The negative-scope sentinel points at a shared vault outside the approved scope, never a private vault. ● — DEPLOYMENT.md § Headless proof workflow

**G-335.** The proof setup confirms both sides: the local account CAN read the sentinel and the service account CANNOT. ● — DEPLOYMENT.md § Headless proof workflow

**G-336.** The canary is verified by digest comparison only, never by exposing the raw value. ● — DEPLOYMENT.md § Headless proof workflow

**G-337.** The proof workflow stays dispatch-only unless its secrets are intentionally available to a broader event class. ● — DEPLOYMENT.md § Headless proof workflow

**G-338.** The proof runs after provisioning or rotating the service-account token. ○ — DEPLOYMENT.md § Headless proof workflow

### Repo CI secrets and reviewer PATs (deployment doc)

**G-339.** The reviewer-assignment secret is a reviewer-identity PAT, never the author identity; the workflow hard-fails when it resolves to the author or to an unregistered login. ● — DEPLOYMENT.md § Machine User Setup

**G-340.** It is the only reviewer PAT permitted as a repo CI secret; the others are read per-session from the vault. ● — DEPLOYMENT.md § Machine User Setup

**G-341.** Model-provider API keys and per-agent PATs are never repo secrets; the CI-side headless reviewer flow was removed. ● — DEPLOYMENT.md § Machine User Setup

**G-342.** Reviewer PATs live in the designated vault under the exact token field name with the classic-token prefix. ● — DEPLOYMENT.md § Token type

**G-343.** Collaborator invitations are accepted via browser or a classic scoped PAT; fine-grained PATs cannot accept them. ○ — DEPLOYMENT.md § Machine User Setup

**G-344.** PAT rotation follows mint, update vault, revoke old, verify — in that order. ○ — DEPLOYMENT.md § Token rotation

**G-345.** Rotating an item backing a repo secret is followed by a secret-set on every repo carrying it. ○ — DEPLOYMENT.md § Token rotation

### Provisioning posture (deployment doc; see the inconsistencies note)

**G-346.** The documented setup requires one approving review with stale-approval dismissal and the two policy checks required strict. ● — DEPLOYMENT.md § Machine User Setup

**G-347.** The documented setup leaves admin bypass available so a human can force-merge in emergencies. ● — DEPLOYMENT.md § Machine User Setup

**G-348.** The four workflow labels exist in every repo. ● — DEPLOYMENT.md § Machine User Setup

**G-349.** All three machine users are collaborators with Write access. ● — DEPLOYMENT.md § Machine User Setup

**G-350.** Setup is verified by the six listed checks before the repo counts as provisioned. ○ — DEPLOYMENT.md § Machine User Setup

### Firebase project setup

**G-351.** The Firebase config pair is committed after initialization. ● — DEPLOYMENT.md § New Project Setup

**G-352.** Automatic builds and file overwrites are declined during initialization. ○ — DEPLOYMENT.md § New Project Setup

**G-353.** Firestore starts in production mode; functions require the billing plan. ● — DEPLOYMENT.md § New Project Setup

**G-354.** Hosting is always required; other services are conditional on app needs. ● — DEPLOYMENT.md § New Project Setup

**G-355.** The deployer service account uses the canonical name and holds exactly the six listed roles, with the operator granted token-creator on it. ● — DEPLOYMENT.md § op-firebase-setup

**G-356.** Minting a deployer key requires the key-admin role (or owner) on the project. ● — DEPLOYMENT.md § Provisioning

### Deploy-key provisioning and rotation

**G-357.** The key is stored in the Firebase vault under the exact canonical item title the materializer reads literally. ● — DEPLOYMENT.md § Provisioning

**G-358.** The local key file is wiped immediately after upload; the key lives only in the vault plus per-run tempfiles. ● — DEPLOYMENT.md § Provisioning

**G-359.** Provisioning refuses to overwrite an existing canonical item, routing to rotation instead. ● — DEPLOYMENT.md § Provisioning

**G-360.** Provisioning short-circuits with a clear error when the vault CLI is absent. ● — DEPLOYMENT.md § Provisioning

**G-361.** Key provisioning stays opt-in, preserving the impersonation-only contract for callers who do not request it. ● — DEPLOYMENT.md § Provisioning

**G-362.** During rotation the old key id is captured before the item is replaced, so it can be revoked cleanly. ○ — DEPLOYMENT.md § Rotation

**G-363.** Rotation reuses the same canonical item title so lookup keeps working without a script edit. ● — DEPLOYMENT.md § Rotation

**G-364.** The rotation date is recorded in the item's notes field — the primary rotation record. ● — DEPLOYMENT.md § Rotation

**G-365.** Rotation is verified by a low-risk deploy whose source-credential log line still names the project key; falling through to another source forbids rolling forward. ● — DEPLOYMENT.md § Rotation

**G-366.** The old key is revoked only after successful verification, so the project is never left without a valid key. ○ — DEPLOYMENT.md § Rotation

**G-367.** The key rotates on a 90-day cadence, immediately on any compromise indicator with a downstream audit, and on custody or membership changes. ○ — DEPLOYMENT.md § Rotation

**G-368.** Multi-project rotation runs one project at a time; batching or automating it is out of bounds. ○ — DEPLOYMENT.md § Rotation

**G-369.** Recoverable rollback requires retaining the old key material before replacement; without it the only recovery is roll-forward. ○ — DEPLOYMENT.md § Rotation

### Machine bootstrap and script custody

**G-370.** The bootstrap repo list resolves via an explicit path before changing directories; a bare filename argument silently expands to nothing. ● — DEPLOYMENT.md § New Machine Setup

**G-371.** Presence in the bootstrap loop is never sync-consumer enrollment; propagation requires separate manifest enrollment. ● — DEPLOYMENT.md § New Machine Setup

**G-372.** The mergepath copies of the helper scripts are canonical; edits to installed machine copies sync back to the repo. ○ — DEPLOYMENT.md § Script Installation

**G-373.** The helper scripts install to the local bin, marked executable, with that bin on the path. ● — DEPLOYMENT.md § Script Installation

**G-374.** New runtime application secrets prefer the managed environments model; template-inject is retained only where a generated file is genuinely needed. ○ — DEPLOYMENT.md § New Machine Setup

**G-375.** Template-structure divergence between machines is resolved as source code, never by syncing generated local files. ○ — DEPLOYMENT.md § Conflict resolution

### Post-deploy

**G-376.** Every deploy is followed by the verification checklist: live URL in a fresh session, core functionality, console errors. ○ — DEPLOYMENT.md § Post-Deployment Verification

**G-377.** Rollback goes through the hosting release-history mechanism, never a re-deploy of older source. ○ — DEPLOYMENT.md § Rollback Procedure

---

The OWL companion ([`mergepath-rules.ttl`](mergepath-rules.ttl)) formalizes a core subset of the ● rules as axioms a reasoner can violate-check; every violation-catching axiom — the ownership-bridge equivalences included — is annotated with the rule IDs it encodes (declaration and helper axioms are not), and [`README.md`](README.md) documents the encoding, the checker, and the honest limits (what open-world OWL can and cannot catch).
