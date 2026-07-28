# #739 decision record — propagating universal doc conventions (Options A/B/C)

Issue [#739](https://github.com/nathanjohnpayne/mergepath/issues/739) required an explicit, recorded decision on how universal, agent-agnostic doc conventions (starting with the worktree-placement convention) propagate to the 8+ sync consumers, choosing among three evaluated options. This file is that record.

## Decision

**Option B is adopted as the propagation mechanism, with Option C's audit script shipped alongside as a complementary, non-enforcing safety net. Option A is rejected as infeasible.**

- **Option A — sync whole `docs/agents/*.md` files as `canonical`/`kit` entries: rejected.** `canonical` requires a byte-identical mirror and `kit` only tolerates extra *files*, not extra *sections* inside one file. Most `docs/agents/*.md` content is legitimately repo-specific (deployment specifics, testing frameworks, repo layout), so a verbatim sync would either clobber real per-repo customization or register as permanent drift on every consumer. The #743 identity/hub-only denylist (`scripts/ci/check_sync_manifest` check 8) already hard-codes this conclusion for the worst offenders.
- **Option B — extract genuinely universal, tech-stack-independent policies into small dedicated single-purpose files and sync those as ordinary `canonical` entries: adopted.** First instance: `docs/agents/worktree-placement.md`, added to `.mergepath-sync.yml` as `type: canonical, consumers: all`. This reuses the proven mechanism already used for `scripts/*.sh`, needs no new sync-engine work, and sidesteps Option A's mixed-content problem by never mixing universal and repo-specific prose in one file. Each repo's own `operating-rules.md` (or equivalent) references the dedicated file rather than embedding the policy inline.
- **Option C — a registry-plus-audit that flags drift without fixing it: shipped in its tool form, not as the propagation mechanism.** `scripts/audit-canonical-mirrors.sh` is the generalized audit: it scans machine-local vendor files (default `~/GitHub/CLAUDE.md`, `~/.codex/AGENTS.md`; list overridable) for top-level sections lacking a `Canonical source:` annotation or whose pinned canonical source has drifted. It is read-only, exits 0 as a triage aid, and is deliberately not wired into CI — machine-local files are unreachable from repository CI, and the docs are honest about that scope limit.

The authoring-side rule that keeps future conventions from repeating the #739 gap (mergepath-first authoring, `> Canonical source:` annotations on every mirror) lives in `docs/agents/documentation-rules.md` § Canonical-source discipline. It was placed in documentation-rules rather than operating-rules because it governs where documentation is authored and how mirrors are annotated, not session behavior.

## Deferred

The acceptance criterion "at least one canary consumer sync is exercised per the manifest's own canary-first procedure" is explicitly deferred pending human approval: no sync, canary, or propagation command was run as part of the #739 implementation PR. When approved, drive it per the `.mergepath-sync.yml` header (one canary consumer first, fan out only after its `lint` is green).

The gaycruisebingo-missing-from-consumers gap that surfaced this thread is tracked separately (#741, which has since enrolled it in the `consumers:` list) and is intentionally not folded into this decision.
