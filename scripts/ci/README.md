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
- `check_codex_p1_gate` — verifies `scripts/codex-p1-gate.sh` + `.github/workflows/codex-p1-gate.yml` + `tests/test_codex_p1_gate.sh` exist, then runs the fixture-driven test suite (Codex P1 unresolved-thread merge gate, #235)
- `check_sync_manifest` — validates `.mergepath-sync.yml` (manifest read by `scripts/sync-to-downstream.sh`): schema version, consumer shape, every referenced path exists, every path type is recognized. Requires `yq` (mikefarah/yq v4+) on the runner. See #168.
- `check_coderabbit_config` — validates `.coderabbit.yml` parses as YAML and (in the Mergepath template repo only) stays on `reviews.profile: chill` (the nit-suppressing profile per CodeRabbit's docs). Consumer repos inheriting this workflow via the template-mirror bootstrap get the parse + existence checks but may override `profile: assertive` locally without failing CI. Template detection prefers `GITHUB_REPOSITORY` (CI) and falls back to the `origin` remote URL for local runs; override via `MERGEPATH_TEMPLATE_CHECK=force|skip`. Requires `yq` (mikefarah/yq v4+) on the runner. See #237 and #256 P2.
- `check_coderabbit_config_tests` — unit tests for `check_coderabbit_config` itself. Drives the template-vs-consumer detection via fixture repos under `tests/test_check_coderabbit_config.sh`. See #256 P2.
- `check_coderabbit_wait` — runs `tests/test_coderabbit_wait_status_probe.sh`, covering `scripts/coderabbit-wait.sh` timeout status probing, unchanged exit-4 semantics, and the guard that prevents status replies from counting as review clearance. See #417.
- `check_eslint_config_present` — enforces the ESLint flat-config policy (`rules/repo_rules.md` § ESLint policy). If a root `package.json` exists, `eslint.config.js` must exist at the repo root and parse under `node --check`. Repos without a root `package.json` (mergepath itself) pass via an early-out. See #250.
- `check_eslint_config_policy` — runs `tests/test_eslint_policy_check.sh` (unit tests for the policy check).
- `check_sweep_unresolved_feedback` — runs unit tests for the #236 weekly feedback sweep pipeline (`scripts/sweep-unresolved-feedback/enumerate.sh`, `render.sh`). PATH-shims `gh` against synthetic fixtures; hermetic.
- `check_disagreement_detector` — runs `tests/test_disagreement_detector.sh` against fixtures under `scripts/ci/fixtures/disagreement-detector/`. Exercises `scripts/disagreement-detector.cjs`, the decision function extracted from `.github/workflows/agent-review.yml`'s `detect-disagreement` job so the workflow and the test share one implementation. Asserts the workflow still `require()`s the module. See #259.

Inline in `repo_lint.yml` (no local script):

- `check_review_policy_exists` — verifies `.github/review-policy.yml` and `REVIEW_POLICY.md` both exist

See `rules/repo_rules.md` for the full list of enforced checks.
