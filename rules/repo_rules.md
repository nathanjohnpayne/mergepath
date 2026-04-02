# Repository Rules

Agents must treat every entry here as a binding constraint, not a
suggestion. If a proposed change would violate a rule below, stop and
flag the conflict before proceeding.

## Structure Invariants

- Canonical root files must always exist:
  README.md, AGENTS.md, CLAUDE.md, DEPLOYMENT.md, CONTRIBUTING.md, .ai_context.md
- `CLAUDE.md` must contain only a reading-order pointer to `AGENTS.md`.
  It must never duplicate instructions from AGENTS.md or any other file.
- `AGENTS.md` is a lightweight index pointing to `docs/agents/`. Agent
  instructions live in focused sub-files under `docs/agents/`.
- Tool folders (.cursor/, .claude/, .vscode/) must contain
  configuration only—no instructions, no behavioral rules.
- No new top-level directories without justification documented in
  AGENTS.md or a plans/ entry.

## Forbidden Patterns

- Never push directly to `main`. All changes must go through a
  pull request—even single-line fixes and documentation updates.
  The only exception is if the human explicitly authorizes a
  direct push in chat as a break-glass override.
- Instructions must not be duplicated between root files and
  tool folders.
- `dist/` must not be edited manually. Regenerate through the
  build system only.
- Tests must not be deleted to force a build to pass.
- Secrets must never be committed. Use environment variables or
  a secrets manager.

## CI Enforcement

The following checks run from `scripts/ci/` locally and via `.github/workflows/repo_lint.yml` in CI.
All checks must pass before merge.

- check_required_root_files
- check_no_tool_folder_instructions
- check_no_forbidden_top_level_dirs
- check_dist_not_modified
- check_spec_test_alignment
- check_duplicate_docs
- check_review_policy_exists (inline in repo_lint.yml): .github/review-policy.yml and REVIEW_POLICY.md must both exist
