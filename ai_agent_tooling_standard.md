# AI Agent Tooling Standard

## Purpose

This document defines a **deterministic repository standard** for AI
coding agents and human developers. It governs structure, documentation
placement, and agent behavior to prevent configuration drift and
cross-tool inconsistency.

The reference implementation is **Mergepath** (`mergepath`).
When in doubt about structure or file placement, that repository is
canonical.

Supported environments: Cursor, Claude Code, VS Code, Codex-style
agents, and other editor or automation systems.

---

## Quick Reference

Before reading further, internalize this priority order:

1. **Canonical root files** are the authoritative source of truth.
2. **Tool folders** (`.cursor/`, `.claude/`, `.vscode/`) contain
   configuration only—never instructions.
3. **Supporting directories** (`rules/`, `plans/`, `specs/`) extend
   canonical docs with structured detail.
4. **`rules/`** entries are binding constraints. They override agent
   judgment.
5. **`specs/`** entries define intended behavior. Code must not diverge
   from specs without an explicit update cycle.

If any instruction in a tool folder conflicts with a canonical root
file, the root file wins.

---

## Canonical Files

These files must exist at the repository root and must not be
duplicated or redefined anywhere else:

| File | Purpose |
|---|---|
| `README.md` | Project overview and entry point |
| `AGENTS.md` | AI agent instructions and behavioral rules |
| `CLAUDE.md` | Claude Code entry point — points to `AGENTS.md`, no duplicated instructions |
| `DEPLOYMENT.md` | Build, deploy, and environment steps |
| `CONTRIBUTING.md` | Contribution guidelines |
| `.ai_context.md` | Supplemental context for AI agents |

`CLAUDE.md` must contain only a reading-order pointer to `AGENTS.md` and other
canonical files. It must never duplicate instructions from `AGENTS.md`.

AI agents must read these files before taking any action in an
unfamiliar repository.

---

## AGENTS.md Required Structure

Every `AGENTS.md` in a repository following this standard must contain
these sections in this order. Omitting sections causes inconsistent
agent behavior across repos.

```
# AGENTS.md

## 1. Repository Overview
Brief description of the project. What it does, what stack it uses,
what the agent's primary job is in this repo.

## 2. Agent Operating Rules
Behavioral rules specific to this repository. Reading order, conflict
resolution, escalation behavior.

## 3. Code Modification Rules
What the agent may and may not change. Languages, patterns, boundaries.

## 4. Documentation Rules
Which files must be updated when behavior changes. When to update
README vs. specs vs. plans.

## 5. Testing Requirements
Test coverage expectations. What must be tested. What must never be
deleted to force a passing build.

## 6. Deployment Process
Reference to DEPLOYMENT.md. Any environment-specific notes relevant
to agent behavior.
```

Agents encountering an `AGENTS.md` that is missing sections must flag
the gap rather than silently proceeding with assumed behavior.

---

## Repository Layout

Repositories following this standard must converge to this structure:

```
repo/
│
├── README.md
├── AGENTS.md
├── CLAUDE.md
├── DEPLOYMENT.md
├── CONTRIBUTING.md
├── .ai_context.md
│
├── rules/
│   └── repo_rules.md       ← repository-level invariants (see below)
├── plans/
├── specs/
├── tests/
├── functions/
├── dist/                   ← gitignored unless intentionally versioned
│
├── .cursor/
├── .claude/
├── .vscode/
│
├── src/
├── scripts/                ← automation and tooling scripts (see below)
└── docs/
    └── architecture/       ← for larger repos; optional but recommended
```

Do not introduce new top-level directories without explicit
justification documented in `AGENTS.md` or a `plans/` entry.

---

## Directory Responsibilities

### `rules/`

Hard repository constraints. Agents must treat every file here as a
**binding rule**, not a suggestion.

Typical contents:
- Architecture constraints
- Coding standards
- Security restrictions
- AI behavioral guardrails
- `repo_rules.md`—repository-level structural invariants (see below)

**Agent rule:** If a proposed change would violate a rule in `rules/`,
stop. Flag the conflict before proceeding.

#### `rules/repo_rules.md`

This file defines the structural invariants for the repository itself.
It is the machine-readable enforcement companion to this standard. Every
repository following this standard should include it.

Required contents:

```markdown
# Repository Rules

## Structure Invariants
- Canonical root files (README.md, AGENTS.md, CLAUDE.md,
  DEPLOYMENT.md, CONTRIBUTING.md, .ai_context.md) must always exist.
- Tool folders (.cursor/, .claude/, .vscode/) must contain
  configuration only—no instructions.
- No new top-level directories without documented justification.

## Forbidden Patterns
- Instructions must not be duplicated between root files and
  tool folders.
- dist/ must not be edited manually.
- Tests must not be deleted to force a build to pass.

## CI Enforcement
The following checks must pass on every commit (see scripts/ci/):
  - check_required_root_files
  - check_no_tool_folder_instructions
  - check_no_forbidden_top_level_dirs
  - check_dist_not_modified
  - check_spec_test_alignment
```

---

### `plans/`

Execution and migration plans. These guide sequencing and rollout but
do not define runtime behavior.

Typical contents:
- Feature rollout plans
- Architecture migrations
- Project sequencing

---

### `specs/`

Defines intended system behavior. These are the ground truth for what
the system is supposed to do.

Typical contents:
- Feature specifications
- API contracts
- Acceptance criteria

**Agent rule:** If code conflicts with a spec, do not silently update
the code. Flag the conflict, then update either the spec or the tests
before modifying behavior. The order of operations matters.

---

### `tests/`

Automated validation. Agents must update tests when behavior changes.
Tests must not be deleted to make a build pass.

---

### `functions/`

Serverless functions and backend handlers (API endpoints, event
handlers, cloud functions).

---

### `scripts/`

Automation and developer tooling. This directory contains scripts
that support development, CI, and maintenance workflows. It is not
application code.

Typical contents:
- `scripts/ci/` — CI enforcement checks (see below)
- `scripts/build/` — build and compile helpers
- `scripts/migrate/` — data or structure migration utilities
- `scripts/gh-projects/` — multi-phase GitHub Projects v2 driver kit
  (parent + native sub-issue tree, body-file placeholders, swimlane
  helpers). Standard tooling for tracking phased initiatives.

Agents should not modify files in `scripts/ci/` without explicit
instruction, as those scripts enforce this standard.

---

### `dist/`

Generated build artifacts. Never edit manually. Regenerate through the
build system only.

`dist/` must be listed in `.gitignore` unless the repository has an
explicit, documented reason to version build artifacts. If versioned,
that decision must be noted in `AGENTS.md`.

---

### `docs/architecture/`

Optional but recommended for larger repositories. Contains architecture
decision records (ADRs), system diagrams, and high-level design
documents.

Agents should consult this directory before making structural or
architectural changes.

---

## Tool Folder Rules

The following directories are configuration containers—nothing more:

```
.cursor/
.claude/
.vscode/
```

### What they may contain
- Editor or agent configuration
- References (by path or link) to canonical docs
- Editor preferences and extension lists

### What they must never contain
- Instructions that duplicate content in canonical root files
- Behavioral rules (those belong in `rules/` or `AGENTS.md`)
- Specs or plans

### Tool-specific guidance

**`.cursor/`**
- May contain Cursor-specific configuration.
- Must reference `AGENTS.md` rather than redefining its contents.

**`.claude/`**
- Minimal configuration only.
- Claude agents must read `AGENTS.md`, `rules/`, and `specs/` for all
  behavioral instructions.

**`.vscode/`**
- `settings.json` and `extensions.json` only.
- No project instructions.

---

## Agent Behavior Rules

### Reading order

When starting work in a repository, agents must read in this order:

1. `README.md` — understand the project
2. `AGENTS.md` — load behavioral instructions
3. `rules/` — load binding constraints, starting with `repo_rules.md`
4. Relevant `specs/` files — understand intended behavior
5. `.ai_context.md` — load supplemental context if present

### Editing

- Prefer modifying existing files over creating new ones.
- Never duplicate logic or instructions.
- Update documentation when behavior changes.
- Maintain consistent structure throughout.

### Creating files

- Use existing directories before introducing new ones.
- Do not create new top-level directories without justification.
- Place new canonical instructions only in root files or the
  appropriate supporting directory—never in tool folders.

### Handling conflicts

| Conflict type | Required action |
|---|---|
| Code vs. `specs/` | Flag conflict → update spec or tests → then update code |
| Proposed change vs. `rules/` | Stop → flag the violation → do not proceed without resolution |
| Tool folder instruction vs. root file | Follow root file; flag the duplication for removal |
| `AGENTS.md` missing required sections | Flag the gap → do not assume behavior for missing sections |

### Documentation updates

Agents must update documentation when any of the following change:
- System behavior
- Build or deployment steps
- Dependencies
- Directory structure

---

## CI Enforcement

Vague enforcement is no enforcement. The following checks must be
implemented in `scripts/ci/` and run on every commit.

| Check | What it validates |
|---|---|
| `check_required_root_files` | README.md, AGENTS.md, CLAUDE.md, DEPLOYMENT.md, CONTRIBUTING.md, and .ai_context.md all exist |
| `check_no_tool_folder_instructions` | `.cursor/`, `.claude/`, `.vscode/` contain no instruction content |
| `check_no_forbidden_top_level_dirs` | No undocumented top-level directories exist |
| `check_dist_not_modified` | `dist/` was not directly edited (compare against build output) |
| `check_spec_test_alignment` | Every spec file has a corresponding test file or documented exception |
| `check_duplicate_docs` | No instruction content is duplicated between root files and tool folders |

Agents must not disable or modify CI checks without explicit
instruction and a documented justification in `plans/`.

---

## Drift Prevention

Repository drift occurs when instructions fragment across multiple
locations. To prevent it:

- Keep canonical docs authoritative and up to date.
- Remove duplicated instructions when found—do not leave them as
  "backup" copies.
- Keep tool folders minimal.
- Run CI enforcement checks on every commit.

---

## Migration Procedure

To bring an existing repository into compliance:

1. Audit the full repository structure.
2. Identify all duplicated or fragmented instructions.
3. Consolidate instructions into the appropriate canonical root file or
   supporting directory.
4. Simplify tool folders—remove anything that is not configuration.
5. Add any missing directories from the standard layout.
6. Create `rules/repo_rules.md` with structural invariants.
7. Verify `AGENTS.md` contains all required sections; add any missing.
8. Add or update `.ai_context.md` if supplemental AI context is useful.
9. Implement CI checks in `scripts/ci/`.
10. Validate the result against **Mergepath** (`mergepath`).

---

## Reference Implementation

**`mergepath`** (Mergepath) provides:
- Example canonical documentation
- Example directory structure
- Example tool folder configuration
- Example `rules/repo_rules.md`
- Example `AGENTS.md` with all required sections
- Example CI scripts in `scripts/ci/`

Agents must reference this template when uncertain how to structure
changes or where to place new files.
