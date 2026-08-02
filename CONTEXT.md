# Mergepath

Mergepath is the reference implementation of the AI Agent Tooling Standard and the hub of a fleet of repositories that share one multi-identity AI code-review policy and one canonical-content propagation system. This file is the domain's ubiquitous language — what each term is, which competing names to avoid, and one entry per sense where a word is overloaded. Terms are grouped by cluster; definitions state what a thing IS, and the canonical detail lives in `REVIEW_POLICY.md`, `docs/agents/`, and the manifest, not here.

## Language

### The Standard and the fleet

**AI Agent Tooling Standard**: The methodology- and stack-neutral repository standard governing structure, documentation placement, and agent behavior so multiple AI coding agents behave consistently. _Avoid_: using "Mergepath" for the Standard — Mergepath implements it.

**Mergepath**: This repository — the reference implementation of the Standard and the hub of the fleet. _Avoid_: `ai_agent_repo_template` (legacy name), "the template" as a proper noun.

**Reference implementation**: Mergepath's role as the concrete repo checked against when a Standard rule is in doubt. Bootstrap deliberately strips this claim from new consumers. _Avoid_: "the spec".

**Hub**: Mergepath in its role as the single upstream that authors canonical content and fans it out; hub-only machinery is what only Mergepath runs. _Avoid_: "central repo" (that is the docs vault), "parent repo", "master repo".

**Consumer**: A downstream repository enrolled in the propagation manifest that receives canonical, kit, and templated surfaces. _Avoid_: "fork", "child repo", "client".

**Fleet**: The hub plus all enrolled consumers, as the unit a "fleet-wide" rule must be true in. _Avoid_: "org".

**Enrollment**: Adding a repo to the manifest's `consumers:` list so it receives ongoing propagation. Distinct from — and later than — bootstrap; a bootstrapped-but-unenrolled repo silently receives nothing. _Avoid_: "onboarding" (ambiguous with bootstrap).

**Central docs repo**: The `nathanjohnpayne/docs` vault holding canonical PRDs, a separate source graph from the hub. _Avoid_: conflating with the hub.

**Surface**: A named Mergepath product UI under the umbrella brand: Playground (current), Cockpit, Tiebreaker, and Checks (reserved).

**Reserved name**: A brand name claimed in `BRAND.md` ahead of the surface existing, so a future agent does not pick it for the wrong thing; no files are scaffolded until the surface is designed.

**Playground**: The one current surface — a static review-policy prototyping UI: tune the policy knobs, replay recent PRs against the draft, copy the resulting YAML. _Avoid_: "Rubric" (retired name), "dashboard", "policy editor" (an explicit non-goal, earmarked for Cockpit).

**Replay**: Running a set of real merged PRs through a draft policy to see routing before committing the YAML. _Avoid_: "backtest".

### Identities and credentials

**Author identity**: The single shared account (`nathanjohnpayne`) under which every agent commits, pushes, opens PRs, and merges — the only identity that merges. _Avoid_: "the human identity" as if agents had another authoring path.

**Reviewer identity**: A dedicated per-agent account (`nathanpayne-claude`, `nathanpayne-cursor`, `nathanpayne-codex`) used exclusively to review — never to author or merge. _Avoid_: conflating with the Codex bot, which is a GitHub App, not a reviewer identity.

**Authoring-Agent line**: The required PR-body line naming which agent wrote the code, needed because all PRs share one author login.

**No-self-approve scoping**: The rule that an agent's reviewer identity must not approve a Phase 4 PR its own agent authored; on under-threshold PRs, reviewer-identity self-approval is the intended path. _Avoid_: the unscoped reading "agents never approve their own PRs".

**Wrapper**: The identity-verifying execution path for guarded `gh` writes (`gh-as-author`, `gh-as-reviewer`): it resolves the expected PAT, verifies its effective login, and runs the one command with a process-local token. _Avoid_: bare or inline-token guarded writes — they fail closed.

**Guard**: A PreToolUse hook that hard-blocks a forbidden agent command shape before execution — mechanism enforcement that works whether or not the agent read the policy.

**Preflight**: The Phase 0 once-per-session credential step that front-loads all 1Password reads into one biometric burst and caches PATs in a session file. _Avoid_: per-call `op read` (setup-only fallback).

**Break-glass**: An explicitly human-authorized, per-invocation bypass of a normally-blocking guard. Authorization must be named in chat and never inferred; the label-removal guard deliberately has no break-glass at all.

### The review pipeline

**Phase ladder**: The review workflow's named stages — 0 credential preflight, 1 authoring, 2 internal review, 2.5 CodeRabbit, 3 threshold check, 3.5 propagation lane, 4a Codex loop, 4b cross-agent CLI review. _Avoid_: "external review" without a phase number.

**Internal review**: Phase 2 — the authoring agent reviews its own diff under its reviewer identity and pushes fixes as the author identity until sign-off. Also "self-peer review".

**External review threshold**: The lines-changed trigger (with the protected-path list as its second disjunct) at or above which Phase 4 external review is mandatory; generated files and lockfiles are excluded from the count.

**Protected paths**: The glob list that forces external review regardless of line count — auth, payments, secrets, credentials, and `.github/**`. The `.github/**` entry is exactly why the propagation lane exists.

**CodeRabbit**: The advisory automated reviewer that runs on every ordinary PR in enabled repos — wave fan-out mirrors are deliberately opened with an ignore marker; it informs but never blocks by itself. Its unresolved threads still bind through the conversation gate. _Avoid_: calling it a merge gate.

**Codex**: The ChatGPT Codex Connector GitHub App — the blocking external-review signal for PRs that enter Phase 4; on under-threshold PRs its requested review is advisory. It never emits an `APPROVED` review state and must be explicitly invoked with `@codex review` on every round; a push never re-triggers it. _Avoid_: "Codex approval".

**Review round**: One `@codex review` request-and-response cycle; bounded by the max-review-rounds cap.

**Handoff message**: The structured "External Review Required" PR comment the manual Phase 4b fallback posts — self-contained, so the external reviewer needs no access to the internal thread; the automated Phase 4b leg never posts one.

**Chat-side handoff block**: The copy-paste-friendly companion block emitted into chat at the same moment the human is alerted; additive to the PR-side handoff, never a replacement.

**Disagreement**: The state where internal and external reviewers disagree on merge-readiness; the human is the tiebreaker and the agent stops and waits. Detected in Phase 4a by exactly two signals: repeat-after-rebuttal and runaway rounds.

**Repeat-after-rebuttal**: The escalation signal fired when Codex re-flags a finding after the agent posted a rebuttal — evidence the reviewer is not convinced.

**Runaway rounds**: The escalation signal fired when the round counter exceeds the cap — read as a sign the PR scope is too broad even when each finding is valid.

**Default disposition**: The standing posture of favoring automation — drive every PR author → review → merge without pausing to ask, deferring only for an explicit human signal or a genuine handoff or escalation. _Avoid_: the "how far should I take this PR?" prompt — a deviation, not a courtesy.

**Cycle-time budget**: The doctrine that Phase 4b's added latency is acceptable for high-risk change shapes and corrosive for trivial ones, keeping the proactive-trigger taxonomy narrow.

**Phase 4b substitute**: An `APPROVED` review on the current HEAD from a non-author registered reviewer identity, accepted by the merge gate in place of Codex clearance. The only external-clearance path when Codex is disabled.

**Trusted-path rule**: The requirement that review orchestration executes from a trusted main-ref checkout, never from the PR-under-review's own checkout, so a PR cannot shape its own verdict.

### Clearance and merge gates

**Clearance**: The HEAD-pinned state in which the external reviewer has affirmatively accepted this exact commit; a content-changing push voids it, while a base-only update can carry it forward under the same external-review fingerprint. _Avoid_: treating a label, a stale approval, or reviewer silence as clearance — silence is never implicit approval.

**HEAD-pinned**: The property that a signal or gate counts only when bound to the exact current commit. The antonym failure is a stale clearance riding a new HEAD. Also "HEAD-anchored", "same-head".

**Mutable proxy**: The named anti-pattern of letting a removable label or dismissable review stand in for clearance; replaced by HEAD-pinned required checks.

**Merge gate**: The agent-side pre-merge verification that the three lettered conditions hold — (a) required CI green, (b) a qualifying reviewer approval or, on a same-agent PR where self-approval is forbidden, a fresh Codex affirmative signal, (c) external clearance on HEAD. _Avoid_: conflating with the Merge clearance gate, its CI-enforced counterpart.

**Merge clearance gate**: The HEAD-pinned canonical check that fails closed when clearance is not satisfied on the merge HEAD, with an external-review arm and a Dependabot arm; it grows merge-time teeth only where branch protection lists it as required.

**Required status check**: The branch-protection designation that makes a check merge-blocking; without it a red check is advisory. The canonical five (Label Gate, Self-Review Required, the two severity gates, the Merge clearance gate) are the set designated for enforcement; whether a repo actually requires them is live branch-protection state, audited weekly and decided in ADR 0002. _Avoid_: assuming a canonical check is enforced anywhere branch protection does not list it.

**Label Gate**: The canonical check that fails while any of the four blocking labels is present.

**Blocking labels**: The four human-action labels agents may never remove — `needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`. `decision-needed` is deliberately not one (issue triage, not a merge stop).

**human-hold**: The human-remove-only hard freeze that supersedes every merge path, including break-glass. Agents may add it, never remove it.

**Severity gate**: A canonical check that fails on any unresolved bot-review thread whose normalized tier is in the required set on the current HEAD; one Codex instance and one CodeRabbit twin sharing a single tier helper.

**Pre-merge review conversation gate**: The mandatory readback of review-thread state immediately before every merge confirming zero unresolved conversations — run unconditionally, never gated on merge-state status.

**Fingerprint carry-forward**: A hash over the tree objects of externally-reviewed files that lets a prior verdict cover a base-only update (rebase, update-branch) while any real content change invalidates it.

**Freshness window**: The maximum age a time-based clearance signal (a Codex 👍, a wallclock anchor) may have and still count, closing the stale-signal false clear that rewritten committer dates would otherwise allow.

**Auto-clear**: The sanctioned automated removal of `needs-external-review` once the clearance gate passes — one of exactly two automation exceptions to the label prohibition, both running as workflows, not agents.

**Auto-merge arming**: Enabling the auto-merge path, which happens only on a qualifying approval event (with re-arm on push and settle re-arm on unlabel) — never spontaneously.

**Edit-nudge**: A deliberate PR body edit used purely as an event source, because a bot's issue-comment verdict fires no workflow run on its own.

**Dispatch recheck**: A PAT-fired `repository_dispatch` that re-runs a gate after an event GitHub's default token cannot trigger workflows for.

**Failover**: The rate-limit contingency where a stalled CodeRabbit causes a one-shot Codex review request so the PR advances via the real blocking gate; it requests, it never clears.

**Narrow-start**: The rollout convention that a new gate ships disabled everywhere except Mergepath, so it can join required checks fleet-wide as a clean no-op before being switched on per repo.

**Fail closed / fail open**: The disposition vocabulary for uncertainty — an ambiguous or unreadable state resolves to blocking (fail closed) or to proceed-and-record (fail open — e.g. a wave audit whose reviewer is unavailable proceeds, and the watermark simply does not advance; an ordinary Phase 4 PR instead falls back to the manual handoff and waits). _Avoid_: "safe default" without naming the direction.

**Advisory**: A signal that informs but never blocks the merge — CodeRabbit's review, the under-threshold Codex trigger, a status-probe reply, the accounting block.

### Signals, probes, and waits

**Probe**: A read-only, single-pass classification of a live surface answering one narrow question and posting nothing. _Avoid_: conflating with the status probe, which posts.

**Status probe**: A narration request posted to a slow reviewer purely to surface why a review is stalled; its reply is never a review or clearance signal.

**Barrier**: The ordering construct that holds the automated Phase 4b review until every enabled bot provider is terminal on the exact head, so the automated approval never lands ahead of the bots.

**Hold**: A deliberate wait state distinguished from failure — nothing is posted and no human is paged. Most holds self-clear as the awaited signal arrives; some name a cause needing action instead (a draft PR, a wrong base branch), and only patience-shaped holds should be retried. _Avoid_: conflating with `human-hold` (a human-controlled freeze) or with fallback (a reviewer that will not answer).

**Marker**: A stable machine-readable token pinning a fact to a specific SHA or state — the lane's verified-head comment, a resolve-class tag, a pause notice, a pending file. An indeterminate marker read is fail-closed.

**Verdict (reviewer output)**: Codex's clean-outcome shape — a summary issue comment naming the reviewed commit; findings rounds arrive only as a COMMENTED review object. Completion is checked from the union of both endpoints, HEAD-anchored. _Avoid_: watching either endpoint alone.

**Clearance reaction**: The Codex 👍 on the PR signaling no-findings clearance, valid only within the freshness window; the 👀 reaction is acknowledgment only, never clearance.

**Measured, not folklore**: The convention that wait windows and timeouts are derived from committed latency studies, not belief.

### Feedback disposition and records of record

**Severity ladder**: The single normalized tier scale — p0, p1, p2, p3, nitpick — onto which both bot reviewers' native markers map, so one policy covers them. _Avoid_: "priority" alone.

**Required tier / discretionary tier**: A tier whose findings must be dispositioned before merge (blocking) versus one addressed at the agent's judgment — non-blocking as a tier, though an open thread still binds the pre-merge conversation gate until resolved by fix, rebuttal, or explicit deferral with rationale; a third setting, ignore, surfaces nothing.

**Disposition**: What actually happened to a piece of review feedback — a fix, or a rebuttal — followed by resolving the thread. A code commit alone is not a disposition. _Avoid_: "addressed" without the thread resolution.

**Rebuttal**: A reasoned reply on the finding thread explaining why the finding does not apply — the legitimate alternative to a fix, and the precondition for the repeat-after-rebuttal signal.

**Verdict (per-finding)**: The ledger-recorded judgment on a single finding — fixed, or false-positive with a reason. _Avoid_: confusing with Codex's verdict comment (previous cluster).

**Resolve class**: The disposition of record stamped on a review thread at resolve time and read by the rollup and sweep — `addressed-elsewhere`, `rebuttal-recorded`, `deferred-to-followup`, `verified-propagation`, `nitpick-noted`, plus the routing-only `canonical-coverage` and `templated-render`. The tag must state the truth: deferring a finding you actually fixed mis-records it.

**Routing class**: A resolve class that says where a durable fix belongs (the canonical source, or the template) rather than that one happened; never counted as actioned on its own.

**Ledger**: A durable append-only record of adjudicated findings or completed review loops, kept so reviewer precision and automation cost are trackable over time.

**Daily rollup**: The end-of-day pass that re-surfaces bot threads resolved on yesterday's merged PRs without a fix or substantive reply — the deferred-and-forgotten class — while context is hot.

**Weekly sweep**: The longer-horizon backstop enumerating threads still unresolved on recently closed PRs. _Avoid_: conflating with a gate workflow's scheduled sweep, the cron that re-posts required-check runs for events GitHub does not fire.

**Post-merge issue**: The issue filed per item an external reviewer flags while approving, labeled as an observation (a noted characteristic) or a risk (a hazard needing attention); acknowledged debt rather than a merge gate, though filing them is a required step before the merge.

### Propagation

**Canonical source**: The one authoritative copy from which every other copy is derived — the hub for propagated surfaces, the central docs repo for PRDs (a separate source graph). The golden rule: fix at the source, never in a mirror. _Avoid_: calling any consumer copy "the source".

**Mirror**: A derived, tooling-maintained copy of canonical content. Three flavors with three verifiers: verbatim (byte-for-byte), rendered (templated per consumer), and generated (project-doc materialization). Hand-editing one breaks its verification and is clobbered on the next sync.

**Drift**: Undeclared divergence between a consumer's live state and what the hub declares — of files, branch protection, or mirrored doc sections. Drift audits are read-only by design: visibility, not remediation. _Avoid_: "drift" for documented divergence.

**Intentional divergence**: A deliberate, per-consumer difference recorded where it can be audited: a sync override or a manifest exclusion, each carrying a mandatory reason, or a per-consumer facts entry, an observed repo property that carries none. Drift without a paper trail is the failure mode the schema exists to prevent.

**Propagation manifest**: `.mergepath-sync.yml` — the hub-only single source of truth for what propagates, to whom, and how; deliberately never itself propagated. _Avoid_: bare "manifest" when the project-docs manifest is in play.

**Canonical (entry type)**: The manifest path type for a byte-for-byte single-file mirror; any difference is drift. _Avoid_: conflating with the doc-ownership class of the same name.

**Kit**: The manifest path type for a whole-directory mirror with allow-extras semantics — every hub file must match byte-identically, while consumer-only additions alongside are legitimate and preserved.

**Templated (entry type)**: The manifest path type rendered per consumer through the substitution engine; byte-equal to the re-render, not to the source. The only sanctioned way to share an identity-doc destination.

**Fact**: A per-consumer key/value declared in the manifest that drives templated rendering — the correct home for a genuinely consumer-specific difference in a templated file. _Avoid_: "variable" (the substitution surface), "config", and attaching a reason field — facts are observed properties, not exceptions.

**Propagation closure**: The invariant that every path a propagated file hard-requires travels with it — declared via `requires:` and checked in both directions (declared→covered, and referenced→declared).

**Sync override**: A consumer-side declared exception — skip a path or override a substitution — each entry carrying a mandatory reason; the audit trail that separates intent from drift.

**Wave**: One end-to-end propagation event: canary first, then a risk-ranked fan-out of mirror PRs across the remaining consumers. _Avoid_: "release", "rollout".

**Canary**: The single consumer synced and driven green before any fan-out, chosen by the dominant risk of the change; a canary failure stops the wave.

**Fan-out**: The multi-consumer phase after the canary is green — a verification step, because the remaining consumers reuse the cleared invariant.

**Wave audit**: The once-per-wave scoped external review, run against the canary over the canonical range not yet audited, replacing per-consumer review of N verbatim mirrors.

**Watermark**: The tag marking the newest canonical range that has passed a wave audit; it advances only on a posted approval, so an un-audited range chains automatically into the next wave.

**Re-cut**: The remediation for a failed wave audit — land the fix at the source, recreate the wave PRs, re-audit the fresh canary. _Avoid_: patching the mirror.

**Propagation lane**: The Phase 3.5 exemption by which a provably byte-verbatim sync PR skips cross-agent external review, its content having been reviewed upstream. Only that requirement is removed — CI, advisory review, and an internal approval still apply. _Avoid_: "review bypass", "auto-approve".

**Faithful-mirror verification**: The lane's load-bearing teeth — every changed file byte-compared (mode and type included) against immutable public Mergepath content at the declared commit, from a trusted checkout. Path confinement alone is deliberately insufficient.

**Lane marker**: The HEAD-pinned verified-head comment recording that verification passed, which downstream gates read to tell exemption apart from clearance.

**Propagation-drift**: The label on the single fleet-wide tracking issue the weekly drift audit maintains; also shorthand for that visibility sweep. _Avoid_: tagging follow-up issues with it — the sweep auto-closes them.

### Bootstrap and doc ownership

**Bootstrap wizard**: The staged tool that spins up a brand-new repo from the template — delivery only. Bootstrap is initial delivery, not durable ownership, and not enrollment. _Avoid_: bare "bootstrap" (also a local credential-restore tool's name), "clone the template".

**Identity scrub**: The bootstrap pass that replaces or excludes every surface where a lexical rename would leave Mergepath's hub identity intact and false in the new repo; each scrub is marker-gated and fails closed.

**Bootstrap residue**: A hub-only or stale file left in a consumer by an old bootstrap — a file unexpectedly present, the inverse of the missing-file failure mode.

**Canonicalization**: Bringing an already-shared or residue file under manifest management so it stops being unmanaged: divergence becomes declared, detectable, and overwritten back into conformance on the next sync. _Avoid_: "adopting", "importing".

**Doc ownership class**: The exhaustive classification of every agent-doc file into exactly one of canonical (one hub source, true verbatim everywhere), per-repo-owned (each repo authors its own), or hub-only (never travels; a consumer copy is residue). A mixed document is transitional debt to split, never a fourth class.

**Generated mirror**: A project-doc file materialized with machine-readable do-not-edit and sync-direction markers. PRDs flow central→repo; specs flow repo→central. _Avoid_: editing one in place.

**Repo-owned doc**: A docs file carrying no generated-mirror marker and backed by no propagated path entry — edit it directly, in place; a per-repo-owned ownership class in the manifest declares ownership, not mirroring.

**Canonical-source discipline**: The rule that a cross-repo convention is authored in Mergepath first and only then mirrored outward, every mirror carrying a canonical-source annotation (optionally pinned with a content-hash prefix so drift is detectable). _Avoid_: downstream-first authoring.

**Machine-local mirror**: An agent-configuration file outside every repo (a machine's global agent file) mirroring a hub convention; repo CI structurally cannot see it, and honesty about that scope is part of the rule.

### Governance conventions

**Canonical root files**: The six required root docs every fleet repo carries: `README.md`, `AGENTS.md`, `CLAUDE.md`, `DEPLOYMENT.md`, `CONTRIBUTING.md`, `.ai_context.md`.

**Tool folder**: `.cursor/`, `.claude/`, `.vscode/` — configuration containers only; never instructions, rules, specs, or plans. A tool-folder instruction conflicting with a root file loses.

**Reading order**: The mandated document sequence on entering a repo, with the shared core read before the local overlay.

**Shared core / local overlay**: The ownership split for operating rules — one fleet-wide file identical everywhere, plus each repo's overlay that may add but never contradict.

**Conflict matrix**: The fixed dispositions for contradictions — code vs spec: update the spec or tests first; a rule violation: stop and flag; tool folder vs root file: root file wins; missing sections: flag, assume nothing.

**Decision record**: The record-what-actually-happened discipline at three granularities — a finding (resolve-class tag), a change (a Path taken section), an issue (a decision comment plus body callout). _Avoid_: conflating with ADRs, the architecture records in `docs/architecture/`.

**Path taken**: The change-level record — a PR-body section required when a PR reverses a position it had already recorded; its non-trigger list (fixing findings, rebases, requested tests) is as binding as its triggers.

**Ceremony**: The named failure mode where a required artifact gets pasted in empty on every change until its presence and absence both carry zero signal — the load-bearing argument against reflexive gates.

**Enforcement honesty**: Stating plainly where a rule cannot be CI-enforced and deciding not to pretend — convention-only enforcement as a recorded decision, not an oversight.

**Narration ban**: Describe the work, not the session — PR titles and descriptions state the final state for a cold reader; rationale is welcome, chronology is not (Path taken is the sanctioned exception).

**Session finalization**: The closeout discipline that implementation-ready work ends in exactly one of three durable states — a committed PR, an explicit handoff, or an explicit discard — with nothing orphaned.

**Worktree placement**: The machine-local convention that agent-created worktrees live in hidden per-repo folders, never as visible siblings; deliberately unenforced by CI, which cannot see outside its checkout.

**Soft-wrap**: The fleet-wide prose rule — one physical line per paragraph, the renderer wraps; fixed-column hard wrapping is invisible in rendered output and manufactures diff churn. Enforced here by the md-prose-wrap gate over an explicit fail-safe allowlist. _Avoid_: reflowing generated, propagated, or fixture files.

### Testing and enforcement vocabulary

**CI enforcement check**: An executable under `scripts/ci/` validating one invariant on every commit, wired into the repo-lint workflow. _Avoid_: "test" — many checks wrap tests but are not tests; also distinguish from required status checks and the reserved Checks surface.

**Repo lint**: The propagated workflow that runs the CI-check kit; its never-propagated annex holds a consumer's local steps so the canonical overwrite cannot clobber them.

**Consumer-safe check**: A kit check that behaves correctly in a consumer checkout where hub-only artifacts are absent — skipping with the canonical marker-first idiom rather than failing.

**Ratchet**: A grandfathered-violation list that fails equally on a new violator, a stale entry, and an escalated class — so it can neither grow to buy silence nor outlive its bugs.

**Regression net**: A test suite a CI check wraps specifically to keep the check itself honest.

**Hermetic test**: A test that runs entirely against fixtures — no live network, credentials, or machine-local state — the form that lets a check run in CI even when the thing it audits cannot.

**Spec-test alignment**: The invariant that every spec has a corresponding test or a documented exception.

**Test deletion**: Never done to make a build pass — the most-repeated single prohibition in the corpus.

### Overloaded words — one line per sense

**Canonical** is three entries: canonical source (the principle), canonical entry type (how a file propagates), canonical ownership class (who owns a doc).

**Check** is three entries: CI enforcement check (a script), required status check (a branch-protection designation), Checks (a reserved surface name).

**Mirror** is three flavors under one entry: verbatim, rendered, generated — each with its own verifier.

**Bootstrap** is delivery (the wizard), never ownership (not a doc class) and never enrollment.

**Verdict** is two entries: Codex's reviewer-output comment, and the per-finding ledger judgment.

**Sweep** is two senses: the weekly unresolved-feedback backstop, and a gate workflow's scheduled re-posting cron.

**Hold** is two entries: the self-clearing wait state, and `human-hold`, the human-controlled freeze.

**Gate** is two senses: a required status check with branch-protection teeth, and an agent-side decision helper that is advisory to the agent's own control flow.
