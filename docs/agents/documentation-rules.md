# Documentation Rules

Update documentation when any of the following change:

- System behavior
- Build or deployment steps
- Dependencies
- Directory structure

When behavior changes: update the relevant `specs/` file and the
appropriate `docs/agents/` sub-file before or alongside the code
change---not after.

When adding or removing an agent instruction section, update the
`AGENTS.md` index at the repository root.

## Direct writes to documentation

Repo-owned documentation is directly editable; generated and synced
mirrors are not. The boundary is explicit below so a routine docs-only
change never depends on tribal knowledge, and so an over-cautious agent
does not avoid a legitimate repo-owned edit under `docs/**`.

**Rule of thumb:** a generated mirror always carries a machine-readable
marker --- a `do_not_edit: true` / `sync_direction:` front-matter header,
or an entry in a sync manifest (`.mergepath-project-docs.yml`,
`.mergepath-sync.yml`). A `docs/**` file with no such marker, listed in
no manifest, is repo-owned --- edit it directly.

### Directly editable (repo-owned --- edit in place)

- `docs/agents/**` --- agent instruction sub-files. Keep the `AGENTS.md`
  index in sync when adding or removing a section.
- `docs/architecture/**` --- architecture decision records.
- `docs/audits/**`, `docs/retrospectives/**` --- analyses and post-mortems.
- `docs/sync-overrides.md` and the repo-root docs (`README.md`,
  `AGENTS.md`, `REVIEW_POLICY.md`, `CLAUDE.md`).
- `specs/**` --- this repo's canonical spec source. It is mirrored OUT to
  the central docs repo (`repo -> central`); edit it here, never in the
  central mirror.

### Do not edit in place (generated / synced mirrors --- route to canonical)

A direct edit here is overwritten on the next sync and breaks the mirror.
Edit the canonical source and let the sync re-materialize it.

- `docs/projects/<project>/prds/**` --- generated PRD mirrors
  (`sync_direction: central-to-repo`, header `do_not_edit: true`). Edit
  the canonical PRD in the `nathanjohnpayne/docs` repo at its `source:`
  path --- `projects/<project>/prds/<project>.md` (note: no `docs/`
  prefix on the central side), declared alongside the `mirror:` in
  `.mergepath-project-docs.yml`. `scripts/project-doc-sync.sh`
  materializes and `--audit`s these mirrors.
- Template-propagated / canonical surfaces declared in
  `.mergepath-sync.yml` (scripts, workflows, and any propagated docs). On
  a consumer these are verbatim mirrors of Mergepath --- fix at the
  Mergepath source, never the consumer copy. See
  `docs/agents/templated-propagation.md`.

No CI check rejects a direct edit to a repo-owned `docs/**` file, and
CodeRabbit's `docs/**` path review is advisory --- so a normal docs-only
change to a repo-owned path is allowed and unblocked. The
generated-mirror markers above are the guard:
`tests/test_project_doc_sync.sh` asserts every materialized mirror
carries them, and the mirror's own `do_not_edit:` header routes an editor
to the canonical source.
