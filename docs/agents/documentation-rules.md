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
- Template-propagated / canonical surfaces declared in `.mergepath-sync.yml` (scripts, workflows, and any propagated docs). On a consumer these are verbatim mirrors of Mergepath --- fix at the Mergepath source, never the consumer copy. See `docs/agents/templated-propagation.md`.

No CI check rejects a direct edit to a repo-owned `docs/**` file, and CodeRabbit's `docs/**` path review is advisory --- so a normal docs-only change to a repo-owned path is allowed and unblocked. The generated-mirror markers above are the guard: `tests/test_project_doc_sync.sh` asserts every materialized mirror carries them, and the mirror's own `do_not_edit:` header routes an editor to the canonical source.

## Prose line-wrapping

Soft-wrap Markdown prose: write one physical line per paragraph and let the renderer wrap it. Do not hard-wrap prose at a fixed column (roughly 72 to 80 characters). GitHub-flavored Markdown collapses single newlines inside a paragraph to spaces, so fixed-column wrapping is invisible in the rendered output, is enforced by nothing, is applied inconsistently, and creates reflow churn on every edit.

This governs intra-paragraph line breaks only. Leave tables, fenced or indented code, YAML front matter, link reference definitions, and list or block-quote structure exactly as written, so the rendered output is unchanged.

Scope is an explicit allowlist of repo-owned prose, and it is fail-safe: any path not on the list is out of scope, so a future generated tree, vendored dependency, or new code area is never swept in until it is added on purpose. In scope: the repo-root docs, `docs/**`, `rules/**`, `plans/**`, `specs/**`, `packaging/**`, the `.github/` agent docs (`copilot-instructions.md`, `templates/`, `screenshots/`), and a few repo-owned component READMEs (`functions/`, `mergepath/`, `tests/`, `scripts/build/`, `bugs/screenshots/`), plus the entire `artifacts/` directory. Out of scope: generated mirrors (`docs/projects/*/prds/`, `docs/audits/data/`), propagated surfaces (`.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/`, and the `scripts/` kit READMEs), and fixtures. Do not reflow those; fix wrapping at their canonical source instead. The gate script `scripts/lint-md-prose-wrap.sh` is the executable form of this allowlist.

The `md-prose-wrap` gate enforces this. `.github/workflows/md-prose-wrap.yml` runs `scripts/lint-md-prose-wrap.sh --check`, and the render-preserving transform lives in `scripts/lib/md_reflow.py`. Run `scripts/lint-md-prose-wrap.sh --write` to reflow the in-scope tree and `--list` to see it. The gate is mergepath-local and is intentionally not propagated to consumers.
