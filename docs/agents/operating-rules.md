# Agent Operating Rules

Read in this order before taking any action:

1. `README.md` — understand the project
2. `AGENTS.md` — load behavioral instructions (index pointing to this directory)
3. `rules/repo_rules.md` — load binding constraints
4. Relevant `specs/` files — understand intended behavior
5. `.ai_context.md` — load supplemental context

Conflict resolution:

- If code conflicts with `specs/`: flag the conflict, update spec or
  tests first, then update code. Do not silently modify behavior.
- If a proposed change violates `rules/repo_rules.md`: stop and flag
  the violation. Do not proceed without resolution.
- If a tool folder contains instructions that conflict with `AGENTS.md`
  or these sub-files: follow the canonical docs and flag the duplication
  for removal.
- If `AGENTS.md` or its sub-files are missing required sections: flag
  the gap and do not assume behavior for missing sections.
