# scripts/ci/

CI enforcement scripts for this repository.

The checks defined here mirror the steps in `.github/workflows/repo_lint.yml`
and can also be run locally before pushing.

Local scripts:

- `check_required_root_files`
- `check_no_tool_folder_instructions`
- `check_no_forbidden_top_level_dirs`
- `check_dist_not_modified`
- `check_spec_test_alignment`
- `check_duplicate_docs`
- `check_codex_scripts` — verifies `scripts/codex-review-request.sh`, `scripts/codex-review-check.sh`, and `scripts/codex-record-feedback.sh` exist and are executable, then runs the Phase 4a helper test suites including `tests/test_codex_record_feedback.sh` (the #487 validated-👍/👎 feedback loop)
- `check_codex_p1_gate` — verifies `scripts/codex-p1-gate.sh` + `.github/workflows/codex-p1-gate.yml` + `tests/test_codex_p1_gate.sh` exist, then runs the fixture-driven test suite (Codex blocking-tier unresolved-thread merge gate — P1-only when `feedback_policy` is absent, generalized to the resolved `required` tiers in #577; #235)
- `check_coderabbit_severity_gate` — the CodeRabbit twin of `check_codex_p1_gate`: verifies `scripts/coderabbit-severity-gate.sh` + `.github/workflows/coderabbit-severity-gate.yml` + `tests/test_coderabbit_severity_gate.sh` exist, checks the workflow trigger shape, then runs the fixture-driven suite (CodeRabbit blocking-tier unresolved-thread merge gate, gated by `coderabbit.severity_gate.enabled`; #574/#577)
- `check_sync_manifest` — validates `.mergepath-sync.yml` (manifest read by `scripts/sync-to-downstream.sh`): schema version, consumer shape, every referenced path exists, every path type is recognized. Requires `yq` (mikefarah/yq v4+) on the runner. See #168.
- `check_propagation_closure` — the INVERSE of `check_sync_manifest` (#519/#521). Scans references *out of* every propagated `scripts/ci/check_*` + canonical `.github/workflows/*` file and fails if any on-disk `tests/`+`scripts/` reference is undeclared (not an exact manifest path, not inside a kit, not in any `requires:`) — i.e. a propagation dependency that would silently *not travel* to consumers and make the referencing tool fail closed there. Skips refs that do not resolve to a real file (fixture strings, doc examples) plus an allow-list of orchestrator/mergepath-internal paths. Requires `yq` (mikefarah/yq v4+); SKIPs on a consumer checkout. See #521.
- `check_coderabbit_config` — validates `.coderabbit.yml` parses as YAML and (in the Mergepath template repo only) stays on `reviews.profile: chill` (the nit-suppressing profile per CodeRabbit's docs). Consumer repos inheriting this workflow via the template-mirror bootstrap get the parse + existence checks but may override `profile: assertive` locally without failing CI. Template detection prefers `GITHUB_REPOSITORY` (CI) and falls back to the `origin` remote URL for local runs; override via `MERGEPATH_TEMPLATE_CHECK=force|skip`. Requires `yq` (mikefarah/yq v4+) on the runner. See #237 and #256 P2.
- `check_coderabbit_config_tests` — unit tests for `check_coderabbit_config` itself. Drives the template-vs-consumer detection via fixture repos under `tests/test_check_coderabbit_config.sh`. See #256 P2.
- `check_coderabbit_wait` — runs `tests/test_coderabbit_wait_status_probe.sh`, covering `scripts/coderabbit-wait.sh` timeout status probing, unchanged exit-4 semantics, and the guard that prevents status replies from counting as review clearance. See #417.
- `check_lint_tooling` — runs `tests/test_lint_tooling.sh`, unit tests for `scripts/lib/lint-tooling.sh`, the shared visibility helper for OPTIONAL lint tooling. Makes a missing local `shellcheck` loud (a WARN locally, a hard FAIL under CI or `MERGEPATH_REQUIRE_SHELLCHECK=1`) instead of a silent skip, closing the gap where a local run without shellcheck passes before CI catches warning-level issues. The helper also runs directly (`bash scripts/lib/lint-tooling.sh`) as a one-shot lint-tool availability report; `check_phase_4b_automation` consumes it for its shellcheck step. See #588.
- `check_eslint_config_present` — enforces the ESLint flat-config policy (`rules/repo_rules.md` § ESLint policy). If a root `package.json` exists, `eslint.config.js` must exist at the repo root and parse under `node --check`. Repos without a root `package.json` (mergepath itself) pass via an early-out. See #250.
- `check_eslint_config_policy` — runs `tests/test_eslint_policy_check.sh` (unit tests for the policy check).
- `check_sweep_unresolved_feedback` — runs unit tests for the #236 weekly feedback sweep pipeline (`scripts/sweep-unresolved-feedback/enumerate.sh`, `render.sh`). PATH-shims `gh` against synthetic fixtures; hermetic.
- `check_disagreement_detector` — runs `tests/test_disagreement_detector.sh` against fixtures under `scripts/ci/fixtures/disagreement-detector/`. Exercises `scripts/disagreement-detector.cjs`, the decision function extracted from `.github/workflows/agent-review.yml`'s `detect-disagreement` job so the workflow and the test share one implementation. Asserts the workflow still `require()`s the module. See #259.

Inline in `repo_lint.yml` (no local script):

- `check_review_policy_exists` — verifies `.github/review-policy.yml` and `REVIEW_POLICY.md` both exist
- `check_governance_files` — verifies `SECURITY.md`, `.github/CODEOWNERS`, and `.github/dependabot.yml` all exist

See `rules/repo_rules.md` for the full list of enforced checks.
