# Code Modification Rules

- Prefer modifying existing files over creating new ones.
- Never duplicate logic or instructions.
- Do not introduce new top-level directories without documented justification in `AGENTS.md` or a `plans/` entry.
- Place canonical instructions only in root files or the appropriate supporting directory---never in `.cursor/`, `.claude/`, or `.vscode/`.

Replace this section with project-specific language, pattern, and boundary constraints.

## ESLint flat-config policy

(Binding rule: `rules/repo_rules.md` § ESLint policy. CI check: `scripts/ci/check_eslint_config_present`. Sample config: `examples/eslint.config.js`. Tracking issue: #250.)

### What the policy requires

Any repo with a root `package.json` ships an `eslint.config.js` flat config at the repo root. The config must, at minimum, load `@eslint/js`'s `recommended` ruleset. Additional framework plugins are required when the matching framework is in the repo's dependencies (the contributor decides which apply; the CI check does not introspect package contents).

Repos with no root `package.json` are exempt — Mergepath itself falls in this category (shell-only), so the check early-outs with a not-applicable log line in this repo's own CI run.

### Why the flat config

ESLint's flat config (`eslint.config.js`) replaces the legacy `.eslintrc.*` cascade. Two practical reasons we standardize on it:

1. It's the format ESLint 9+ requires by default. Legacy configs need an `ESLINT_USE_FLAT_CONFIG=false` workaround that's slated for removal.
2. The flat config is a single file with explicit imports — easier for an automated check (and for a human reviewer at handoff time) to reason about than a multi-file cascade.

`.eslintrc.*` is NOT acceptable under this policy. If a repo has already migrated to a non-`.js` flat config (`.mjs`, `.cjs`, `.ts`), file an exception in `.sync-overrides.yml` with a `reason:` per the sync-overrides docs.

### Recommended config per framework

The starter at `examples/eslint.config.js` is layered for copy-and- trim use. Open the file, keep the framework blocks that apply, and delete the rest. The packages each block needs:

| Stack | Plugins to install (devDependencies) |
|---|---|
| Plain JS | `eslint`, `@eslint/js`, `globals` |
| TypeScript | + `typescript`, `typescript-eslint` |
| Astro | + `eslint-plugin-astro` |
| React | + `eslint-plugin-react`, `eslint-plugin-react-hooks` |

The starter uses `import` syntax (ESM). If your `package.json` does not yet set `"type": "module"`, either add it (preferred for new projects) or rename the file to `eslint.config.mjs` AND file the sync-overrides exception described above.

### CI contract

`scripts/ci/check_eslint_config_present` is the load-bearing check. Exit codes (from the script header):

- `0` — pass: no root `package.json`, OR both files present and the config parses under `node --check`.
- `1` — fail: `package.json` present but `eslint.config.js` missing, or present but failed `node --check`.
- `2` — environment error (Node not available). The workflow treats this as fail so the check can't silently degrade.

The check ONLY validates the policy for the current repo. It does NOT run ESLint itself, install dependencies, or scan the dependency tree. The intent is to gate-keep the existence and parseability of the config file; the actual lint pass runs per-repo via that repo's own CI (or CodeRabbit's auto-lint once an `eslint.config.js` is present).

### Adopting in an existing repo

Per-repo adoption is tracked by the child issues listed in #250. The mechanical steps are:

1. `cp examples/eslint.config.js eslint.config.js` (after the `scripts/sync-to-downstream.sh` apply, the sample is available at the consumer's own `examples/eslint.config.js` path).
2. Trim to the framework blocks that apply; install the listed devDependencies.
3. Run `npx eslint .` locally and address findings or scope the `files` patterns down.
4. Commit alongside the policy bump.
