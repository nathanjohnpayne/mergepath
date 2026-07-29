# Documentation Rules

Update documentation when any of the following change:

- System behavior
- Build or deployment steps
- Dependencies
- Directory structure

When behavior changes: update the relevant `specs/` file and the appropriate `docs/agents/` sub-file before or alongside the code change---not after.

When adding or removing an agent instruction section, update the `AGENTS.md` index at the repository root.

## Direct writes to documentation

Repo-owned documentation is directly editable; generated and synced mirrors are not. The boundary is explicit below so a routine docs-only change never depends on tribal knowledge, and so an over-cautious agent does not avoid a legitimate repo-owned edit under `docs/**`.

**Rule of thumb:** a generated mirror always carries a machine-readable marker --- a `do_not_edit: true` / `sync_direction:` front-matter header, or an entry in a sync manifest (`.mergepath-project-docs.yml`, `.mergepath-sync.yml`). A `docs/**` file with no such marker, listed in no manifest, is repo-owned --- edit it directly.

### Directly editable (repo-owned --- edit in place)

- `docs/agents/**` --- agent instruction sub-files. Keep the `AGENTS.md` index in sync when adding or removing a section.
- `docs/architecture/**` --- architecture decision records.
- `docs/audits/**`, `docs/retrospectives/**` --- analyses and post-mortems.
- `docs/sync-overrides.md` and the repo-root docs (`README.md`, `AGENTS.md`, `REVIEW_POLICY.md`, `CLAUDE.md`).
- `specs/**` --- this repo's canonical spec source. It is mirrored OUT to the central docs repo (`repo -> central`); edit it here, never in the central mirror.

### Do not edit in place (generated / synced mirrors --- route to canonical)

A direct edit here is overwritten on the next sync and breaks the mirror. Edit the canonical source and let the sync re-materialize it.

- `docs/projects/<project>/prds/**` --- generated PRD mirrors (`sync_direction: central-to-repo`, header `do_not_edit: true`). Edit the canonical PRD in the `nathanjohnpayne/docs` repo at its `source:` path --- `projects/<project>/prds/<project>.md` (note: no `docs/` prefix on the central side), declared alongside the `mirror:` in `.mergepath-project-docs.yml`. `scripts/project-doc-sync.sh` materializes and `--audit`s these mirrors.
- Template-propagated / canonical surfaces declared in Mergepath's propagation manifest (scripts, workflows, and any propagated docs). On a consumer these are verbatim mirrors of Mergepath --- fix at the Mergepath source, never the consumer copy. (The manifest `.mergepath-sync.yml` and the rendering engine `docs/agents/templated-propagation.md` live on Mergepath, not the consumer.)

No CI check rejects a direct edit to a repo-owned `docs/**` file, and CodeRabbit's `docs/**` path review is advisory --- so a normal docs-only change to a repo-owned path is allowed and unblocked. The generated-mirror markers above are the guard: `tests/test_project_doc_sync.sh` asserts every materialized mirror carries them, and the mirror's own `do_not_edit:` header routes an editor to the canonical source.

## Canonical-source discipline

A new cross-repo or agent-agnostic convention is authored in mergepath **first** — in a small dedicated `docs/agents/*.md` file when it is universal enough to sync as a `canonical` manifest entry (the pattern `docs/agents/worktree-placement.md` establishes; see #739), otherwise in the appropriate existing `docs/agents/` sub-file. Only then is it mirrored into vendor-specific or machine-local files — a machine's `~/GitHub/CLAUDE.md`, a global `~/.codex/AGENTS.md`, a consumer repo's own docs — and every such mirror carries a `> Canonical source: mergepath/<path>` annotation pointing back at the authored source. Never author a convention downstream-first: content added directly to one vendor file is invisible to every other agent CLI and to every other machine, and nothing catches the omission (the worktree-placement convention lived only in one machine's `~/GitHub/CLAUDE.md` for months — the #739 gap).

Annotation format for mirrored sections:

```markdown
> Canonical source: `mergepath/docs/agents/<file>.md` (canonical-sha256: <hex-prefix>)
```

The `canonical-sha256:` pin is optional but recommended: it records a prefix (12+ hex chars) of the SHA-256 of the canonical file at the time the mirror was taken, which lets `scripts/audit-canonical-mirrors.sh` detect that the canonical source has moved on since the mirror was written. The audit script is a read-only, on-demand triage aid (run it locally, e.g. at session finalization) — it reports top-level sections lacking an annotation and pinned sections whose canonical source has drifted, and it never edits or migrates anything. Its audit run is deliberately not wired into any GitHub Actions workflow: machine-local files are outside every repo, so CI cannot see them — honesty about that scope is part of the rule. (The script's hermetic parser regression suite does run in CI, via `scripts/ci/check_audit_canonical_mirrors`; what stays out of CI is the audit of machine-local files itself.)

## Prose line-wrapping

The rule itself — soft-wrap prose, one physical line per paragraph, never a fixed 72-to-80-column hard wrap — is fleet-wide and lives in [`docs/agents/prose-line-wrapping.md`](prose-line-wrapping.md), the canonical file propagated to every repo. Read it there; it also carries the "never reflow someone else's file" list that applies everywhere. This section carries only what is specific to *this* repository: which paths are in scope, and how the rule is enforced here.

Scope is an explicit allowlist of repo-owned prose, and it is fail-safe: any path not on the list is out of scope, so a future generated tree, vendored dependency, or new code area is never swept in until it is added on purpose. In scope: the repo-root docs, `docs/**`, `rules/**`, `plans/**`, `specs/**`, `packaging/**`, the `.github/` agent docs (`copilot-instructions.md`, `templates/`, `screenshots/`), and a few repo-owned component READMEs (`functions/`, `mergepath/`, `tests/`, `scripts/build/`, `bugs/screenshots/`), plus the entire `artifacts/` directory. Out of scope: generated mirrors (`docs/projects/*/prds/`, `docs/audits/data/`), propagated surfaces (`.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/`, and the `scripts/` kit READMEs), and fixtures. Do not reflow those; fix wrapping at their canonical source instead. The gate script `scripts/lint-md-prose-wrap.sh` is the executable form of this allowlist.

The `md-prose-wrap` gate enforces this. `.github/workflows/md-prose-wrap.yml` runs `scripts/lint-md-prose-wrap.sh --check`, and the render-preserving transform lives in `scripts/lib/md_reflow.py`. Run `scripts/lint-md-prose-wrap.sh --write` to reflow the in-scope tree and `--list` to see it. The gate is mergepath-local and is intentionally not propagated to consumers.
