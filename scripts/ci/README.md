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

Inline in `repo_lint.yml` (no local script):

- `check_review_policy_exists` — verifies `.github/review-policy.yml` and `REVIEW_POLICY.md` both exist

See `rules/repo_rules.md` for the full list of enforced checks.
