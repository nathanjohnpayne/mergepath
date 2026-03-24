# scripts/ci/

CI enforcement scripts for this repository.

The checks defined here mirror the steps in `.github/workflows/repo_lint.yml`
and can also be run locally before pushing.

Included scripts:

- `check_required_root_files`
- `check_no_tool_folder_instructions`
- `check_no_forbidden_top_level_dirs`
- `check_dist_not_modified`
- `check_spec_test_alignment`
- `check_duplicate_docs`

See `rules/repo_rules.md` for the full list of enforced checks.
