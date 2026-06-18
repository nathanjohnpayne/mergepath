// eslint.config.js
//
// Auto-generated from nathanjohnpayne/mergepath's templated source
// at examples/eslint.config.js (per the Mergepath ESLint standard,
// mergepath#250). Edit upstream, not this rendered copy — local
// edits will be overwritten on the next propagation run.
//
// >>> if _template_only_notes
// Template-author notes (this block is stripped from every
// rendered consumer copy because no consumer sets
// `facts._template_only_notes`):
//
// Rendered per consumer by scripts/lib/template-substitution.sh
// (#313) using the consumer's `facts.*` from
// `.mergepath-sync.yml`, then propagated to the consumer repo's
// root as `eslint.config.js` via the templated path-type in
// scripts/sync-to-downstream.sh (Phase B2, #316).
//
// Per-consumer facts.frameworks vocabulary (closed set):
//   typescript  → enables typescript-eslint baseline + TS parsing
//                 (also tightens TS no-unused-vars to ^_-prefix and
//                 demotes no-explicit-any to warn — see #322)
//   astro       → enables eslint-plugin-astro
//   react       → enables eslint-plugin-react + react-hooks. The
//                 React file glob is `**/*.{jsx,tsx}` by default;
//                 set `facts.jsx_in_js: true` to add a SECOND React
//                 rule entry whose glob extends to `.js` (for repos
//                 that babel-/vite-transpile JSX inside `.js`, e.g.,
//                 device-platform-reporting, friends-and-family-
//                 billing). Both entries render together; eslint
//                 flat-config merges rules across overlapping globs.
//
// Per-consumer facts.testing vocabulary (default unset / "none"):
//   vitest      → enables a vitest globals block on common test
//                 file patterns (describe/it/test/expect/vi/...)
//   jest        → same shape but with `jest` global instead of `vi`
//   (anything else, including "mocha" / "node" / unset) renders
//                 no testing globals block. Future expansion: add
//                 mocha / node-test forms as consumers adopt them.
//
// Per-consumer facts.jsx_in_js (default unset / false):
//   When true, an ADDITIONAL React rule entry is rendered whose
//   files glob includes `.js`. Only meaningful for consumers that
//   also declare `frameworks: [react]`; setting it on a non-React
//   consumer renders the React rule block without the React imports
//   (broken eslint config), so don't do that. v1 templating doesn't
//   support compound expressions (e.g., `frameworks contains react
//   && jsx_in_js`), which is why the gate is jsx_in_js alone — the
//   constraint lives in the manifest review, not the template.
//
// Per-consumer facts.react_compiler vocabulary — RESERVED for v2.
//   Currently has NO effect on rendering. The disable block for the
//   React Compiler advisories (react-hooks/set-state-in-effect,
//   preserve-manual-memoization, refs, immutability) renders for
//   ALL React consumers, because the v1 template lib can't combine
//   `frameworks contains react` with `react_compiler != true` into
//   a compound gate (no nested conditionals, no `&&` operator).
//   Codex P1 on PR #327 round 2 caught the prior `react_compiler
//   != true` standalone gate emitting react-hooks/* rule IDs into
//   non-React configs, breaking ESLint load with "Definition for
//   rule X was not found".
//   React Compiler adopters MUST re-enable these rules in their
//   local config override (set each to "error" after the rendered
//   config). When the template lib gains compound expressions, the
//   gate will become `frameworks contains react && react_compiler
//   != true` and this knob will work as documented.
//
// A consumer with no frameworks (e.g., swipewatch — pure Node +
// vitest) gets the JS baseline only. Multiple frameworks stack in
// declaration order.
//
// Why these defaults shipped together (mergepath#322): the Phase D
// fanout for #250 found 5 of 6 React/TS consumers hand-adding the
// same ^_-prefix unused-vars rule, allowEmptyCatch, no-explicit-any
// demotion, and (for vitest/jest consumers) the same globals block.
// Folding them into the template as fact-gated defaults removes the
// per-consumer override churn while keeping the rendered output
// byte-stable for consumers that don't opt in.
// <<<

import js from "@eslint/js";
import globals from "globals";

// >>> if frameworks contains typescript
import tseslint from "typescript-eslint";
// <<<
// >>> if frameworks contains astro
import astro from "eslint-plugin-astro";
// <<<
// >>> if frameworks contains react
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
// <<<

export default [
  // Ignore generated / vendored output. Customize per-consumer via
  // a follow-up commit on the propagation PR if a repo needs extras
  // (e.g., functions/lib for cloud-functions repos).
  //
  // `.claude/worktrees/**` is the per-agent worktree root that
  // Claude Code creates for parallel sub-tasks; linting the working
  // copies inside it is duplicative and noisy on every agent run.
  {
    ignores: [
      "node_modules/**",
      "dist/**",
      "build/**",
      "coverage/**",
      ".astro/**",
      ".next/**",
      ".vercel/**",
      ".claude/worktrees/**",
    ],
  },

  // Baseline JS recommended — required by the Mergepath policy floor.
  js.configs.recommended,

  // Baseline rule policy applied to all JS sources. `^_`-prefix
  // unused-vars is the standard convention for marking intentionally-
  // unused locals (args, vars, caught errors, destructured-array
  // leftovers); the `allowEmptyCatch` setting permits the
  // `catch (_) {}` swallow idiom that appears in legacy code.
  // Both relaxations were added by hand by 5 of 6 consumers during
  // the Phase D fanout (#250) — folding them into the baseline
  // removes the per-consumer churn.
  {
    rules: {
      "no-unused-vars": ["error", {
        argsIgnorePattern: "^_",
        varsIgnorePattern: "^_",
        caughtErrorsIgnorePattern: "^_",
        destructuredArrayIgnorePattern: "^_",
      }],
      "no-empty": ["error", { allowEmptyCatch: true }],
    },
  },

  // Apply browser + node globals to all JS sources by default. Narrow
  // these per-file-pattern in a follow-up commit if the repo has a
  // clean split (e.g., scripts/* node-only, src/* browser-only).
  //
  // `*.cjs` files are split out so ESLint parses them as CommonJS
  // (`sourceType: "commonjs"`) rather than ES modules — otherwise
  // top-level `require`/`module.exports` and CommonJS scope rules
  // produce false-positive parse errors. The defaults ESLint applies
  // by extension are: `module` for `.js`/`.mjs`, `commonjs` for
  // `.cjs`; we make that explicit here so the policy is
  // self-documenting.
  {
    files: ["**/*.{js,mjs,jsx}"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
  },
  {
    files: ["**/*.cjs"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "commonjs",
      globals: {
        ...globals.node,
      },
    },
  },

// >>> if frameworks contains typescript
  // TypeScript recommended ruleset — applied to .ts / .tsx via the
  // typescript-eslint plugin's flat-config preset. Includes the
  // parser, the recommended rule set, and the file-glob targeting.
  ...tseslint.configs.recommended,
// <<<

// >>> if frameworks contains typescript
  // Tighten the TS-specific unused-vars rule to match the JS baseline
  // `^_`-prefix convention, and demote `no-explicit-any` to warn —
  // legitimate `any` usage shows up in Playwright cross-frame DOM
  // bridges, Firestore type-erasure, and WIP design-direction code;
  // an error blocks CI on signals the team has already considered.
  // Both demotions were hand-added by every TS consumer during the
  // Phase D fanout (#250); folding into the template removes the
  // per-consumer churn.
  //
  // `.astro` is in the glob because astro frontmatter (the `---` fence)
  // is TypeScript, linted by @typescript-eslint via the astro parser —
  // without it the `^_` convention silently fails on astro consumers
  // (the rule still fires from the recommended preset, just without
  // these ignore patterns). Kept in this typescript-gated block, NOT a
  // separate astro-gated one, so these `@typescript-eslint/*` rule IDs
  // only render where the plugin is imported — cf. the #327 rule-
  // without-plugin break. A TS consumer with no `.astro` files matches
  // none, so the added extension is inert for them.
  {
    files: ["**/*.{ts,tsx,astro}"],
    rules: {
      "@typescript-eslint/no-unused-vars": ["error", {
        argsIgnorePattern: "^_",
        varsIgnorePattern: "^_",
        caughtErrorsIgnorePattern: "^_",
        destructuredArrayIgnorePattern: "^_",
      }],
      "@typescript-eslint/no-explicit-any": "warn",
    },
  },
// <<<

// >>> if frameworks contains astro
  // Astro flat-config recommended ruleset — applied to .astro files.
  // The plugin exposes its flat-config preset under the bracketed
  // `configs['flat/recommended']` key (NOT the legacy
  // `configs.recommended` which is the eslintrc-shape config).
  // Same key for ESM and CJS — the plugin's export shape is
  // module-system-agnostic.
  ...astro.configs['flat/recommended'],
// <<<

// >>> if frameworks contains react
  // React + React Hooks recommended rulesets — applied to .jsx / .tsx.
  // Detect the React version automatically from package.json. The
  // React 17+ JSX transform makes `react/react-in-jsx-scope` obsolete;
  // turn it off explicitly so the rule doesn't flag every component.
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: {
      react,
      "react-hooks": reactHooks,
    },
    languageOptions: {
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
    },
    rules: {
      ...react.configs.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
      "react/prop-types": "off",
      // React Compiler advisories — disabled by default because they
      // only fire usefully once the React Compiler is adopted; until
      // then they're noisy on idiomatic React (set-state-in-effect
      // for init, ref-during-render in TipTap-style editors). Inlined
      // here (vs a sibling block) so they inherit this entry's
      // `files:` and `plugins:` scope — codex P1 #327 round 3
      // caught the standalone block referencing react-hooks/* rules
      // without a scope, breaking ESLint on .js files of React
      // consumers (where the plugin isn't loaded for that glob).
      // React Compiler adopters override locally back to "error".
      "react-hooks/set-state-in-effect": "off",
      "react-hooks/preserve-manual-memoization": "off",
      "react-hooks/refs": "off",
      "react-hooks/immutability": "off",
    },
    settings: {
      react: { version: "detect" },
    },
  },
// <<<

// >>> if jsx_in_js
  // jsx_in_js variant — an ADDITIONAL React rule entry whose files
  // glob includes `.js` so repos that babel-/vite-transpile JSX in
  // plain `.js` files (e.g., device-platform-reporting, friends-and-
  // family-billing) lint those files under the React rule set.
  // Renders alongside the default `**/*.{jsx,tsx}` block above for
  // React consumers that opt in; eslint flat-config merges rules
  // across overlapping globs so the .js files inherit the React
  // rules via this second entry. Setting jsx_in_js: true on a
  // non-React consumer is a manifest misconfiguration — this block
  // would reference undeclared `react`/`reactHooks` and the
  // rendered config would fail to load.
  {
    files: ["**/*.{js,jsx,tsx}"],
    plugins: {
      react,
      "react-hooks": reactHooks,
    },
    languageOptions: {
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
    },
    rules: {
      ...react.configs.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
      "react/prop-types": "off",
      // React Compiler advisories — disabled by default because they
      // only fire usefully once the React Compiler is adopted; until
      // then they're noisy on idiomatic React (set-state-in-effect
      // for init, ref-during-render in TipTap-style editors). Inlined
      // here (vs a sibling block) so they inherit this entry's
      // `files:` and `plugins:` scope — codex P1 #327 round 3
      // caught the standalone block referencing react-hooks/* rules
      // without a scope, breaking ESLint on .js files of React
      // consumers (where the plugin isn't loaded for that glob).
      // React Compiler adopters override locally back to "error".
      "react-hooks/set-state-in-effect": "off",
      "react-hooks/preserve-manual-memoization": "off",
      "react-hooks/refs": "off",
      "react-hooks/immutability": "off",
    },
    settings: {
      react: { version: "detect" },
    },
  },
// <<<

// React Compiler advisory disables are now INSIDE the React block(s)
// above (so they inherit the same `files:` and `plugins:` scope and
// don't reference react-hooks/* on files where the plugin isn't
// loaded — codex P1 #327 round 3). The standalone block previously
// at this position has been removed.

// >>> if testing contains vitest
  // Vitest globals — applied to common test file patterns. Without
  // this block, `describe`/`it`/`expect`/`vi`/etc. trigger no-undef
  // in every test file. Pattern covers __tests__ dirs and *.test.*
  // files; broaden per-consumer if test helpers live elsewhere.
  {
    files: ["tests/**", "**/__tests__/**", "**/*.test.{js,jsx,mjs,ts,tsx}"],
    languageOptions: {
      globals: {
        describe: "readonly",
        it: "readonly",
        test: "readonly",
        expect: "readonly",
        beforeEach: "readonly",
        afterEach: "readonly",
        beforeAll: "readonly",
        afterAll: "readonly",
        vi: "readonly",
      },
    },
  },
// <<<

// >>> if testing contains jest
  // Jest globals — applied to common test file patterns. Without
  // this block, `describe`/`it`/`expect`/`jest`/etc. trigger
  // no-undef in every test file.
  {
    files: ["tests/**", "**/__tests__/**", "**/*.test.{js,jsx,mjs,ts,tsx}"],
    languageOptions: {
      globals: {
        describe: "readonly",
        it: "readonly",
        test: "readonly",
        expect: "readonly",
        beforeEach: "readonly",
        afterEach: "readonly",
        beforeAll: "readonly",
        afterAll: "readonly",
        jest: "readonly",
      },
    },
  },
// <<<
];
