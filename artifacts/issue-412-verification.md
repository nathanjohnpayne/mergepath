# Issue #412 Verification

Recorded: 2026-06-04T01:22:39Z

Branch: `codex/gh-token-secondary-sweep-412`

Pre-commit base HEAD: `01ce5a6fb6ecaa0f3db7416c7143964689428e63`

## Scope

This artifact records the local verification for issue #412, which migrates secondary GitHub helpers and active identity guidance to token-verified `gh` writes.

## Commands

All commands ran from `/Users/nathanpayne/GitHub/mergepath`.

| Command | Result |
| --- | --- |
| `rg -n "gh auth switch\|active keyring\|write paths use the keyring\|GH_TOKEN is irrelevant\|GH_TOKEN is ignored\|switches \\+ runs \\+ restores\|trap EXIT\|active account\|auth-restore" AGENTS.md REVIEW_POLICY.md docs scripts -g '!retrospectives/**' -g '!docs/archive/**'` | PASS, no active docs/scripts matches |
| `scripts/ci/check_no_bare_gh_writes` | PASS |
| `bash -n scripts/bootstrap/_lib.sh scripts/bootstrap/github-infra.sh scripts/bootstrap/board-and-summary.sh scripts/bootstrap/template-mirror.sh scripts/bootstrap-new-repo.sh scripts/sync-to-downstream.sh scripts/coderabbit-wait.sh scripts/request-label-removal.sh scripts/resolve-pr-threads.sh scripts/gh-projects/lib.sh scripts/gh-projects/move-item.sh scripts/lib/gh-token-resolver.sh scripts/gh-as-author.sh scripts/gh-as-reviewer.sh scripts/identity-check.sh scripts/op-preflight.sh scripts/ci/check_no_bare_gh_writes scripts/ci/check_onepassword_headless_proof_workflow` | PASS |
| `bash -n scripts/ci/check_no_bare_gh_writes scripts/sync-to-downstream.sh tests/test_sync_to_downstream.sh scripts/onepassword-headless-proof-setup.sh` | PASS |
| `bash tests/test_identity_check.sh` | PASS, 16/16 |
| `bash tests/test_identity_check_fail_closed.sh` | PASS, 10/10 |
| `bash tests/test_gh_as_reviewer.sh` | PASS, 7/7 |
| `bash tests/test_gh_as_author.sh` | PASS, 6/6 |
| `bash tests/test_gh_wrapper_parallel.sh` | PASS |
| `bash tests/test_sync_to_downstream.sh` | PASS |
| `bash tests/test_bootstrap_github_infra.sh` | PASS, 22/22 |
| `bash tests/test_bootstrap_board_and_summary.sh` | PASS, 46/46 |
| `bash tests/test_bootstrap_template_mirror.sh` | PASS, 39/39 |
| `bash tests/test_helper_autosource.sh` | PASS, 7/7 |
| `scripts/ci/check_ci_scripts_wired` | PASS, 41 check scripts wired or exempt |
| `scripts/ci/check_gh_as_author` | PASS |
| `scripts/ci/check_op_preflight_contract` | PASS |
| `scripts/ci/check_onepassword_headless_proof_workflow` | PASS |
| `scripts/ci/check_bootstrap_github_infra` | PASS |
| `scripts/ci/check_bootstrap_board_and_summary` | PASS |
| `scripts/ci/check_bootstrap_template_mirror` | PASS |
| `scripts/ci/check_bootstrap_firebase_and_codereview` | PASS, 39/39 |
| `scripts/ci/check_resolve_pr_threads` | PASS, 10 tests |
| `bash tests/test_request_label_removal_escape.sh` | PASS, 11/11 |
| `bash tests/test_check_coderabbit_config.sh` | PASS, 17/17 |
| `scripts/ci/check_bootstrap_wizard` | PASS, 44/44 |
| `scripts/ci/check_bootstrap_sh` | PASS, 10/10 |
| `scripts/ci/check_canonical_bugs_263caf3` | PASS, 47/47 |
| `scripts/ci/check_codex_scripts` | PASS |
| `scripts/ci/check_codex_p1_gate` | PASS, 13/13 |
| `scripts/ci/check_phase_4b_classifier` | PASS, 14 tests |
| `scripts/ci/check_workflow_parsers` | PASS, 60 tests |
| `scripts/ci/check_workflow_verify_propagation_templated` | PASS, 5/5 |
| `scripts/ci/check_mktemp_portability` | PASS, 13/13 |
| `scripts/ci/check_template_substitution` | PASS, 55/55 |
| `scripts/ci/check_sync_manifest` | PASS, 25 fixture tests and live manifest check |
| `scripts/ci/check_required_root_files && scripts/ci/check_no_tool_folder_instructions && scripts/ci/check_no_forbidden_top_level_dirs && scripts/ci/check_spec_test_alignment && scripts/ci/check_duplicate_docs` | PASS |
| `scripts/ci/check_verify_propagation_pr && scripts/ci/check_auto_clear_workflow && scripts/ci/check_pr_audit_codex_clearance && scripts/ci/check_pr_audit_sync_exemption` | PASS |
| `scripts/ci/check_sweep_unresolved_feedback && scripts/ci/check_disagreement_detector && scripts/ci/check_sync_overrides && scripts/ci/check_export_consumer_facts` | PASS |
| `scripts/ci/check_eslint_config_present && scripts/ci/check_eslint_config_policy && scripts/ci/check_coderabbit_config && scripts/ci/check_coderabbit_config_tests` | PASS |
| `git diff --check` | PASS |

## Notes

- Test-only stale-term mentions remain in assertions that prove wrappers do not call stored-account selection; the active docs/scripts sweep is clean.
- CodeRabbit follow-up on PR #416: `scripts/sync-to-downstream.sh --no-pr` live mode now skips the author-token guard only when no gh author writes can run; `tests/test_sync_to_downstream.sh` proves it reaches a deterministic fake clone instead of the token gate.
- CodeRabbit follow-up on PR #416: `check_no_bare_gh_writes` now includes `gh variable set`, and the existing `onepassword-headless-proof-setup.sh` variable write is kept on the verified author-wrapper path.
- Codex P2 follow-up on PR #416: `sync_check_existing_pr` now routes through `sync_read_gh`, which reuses an already-warmed author preflight token for gh read probes without making `--no-pr` hard-require author-token verification.
- Codex P2 follow-up on PR #416: `gh_default_reviewer_identity` now honors `OP_PREFLIGHT_AGENT` before falling back to Claude, so reviewer wrappers match the warmed preflight lane even when `MERGEPATH_AGENT` is unset.
- `scripts/gh-projects` does not have a dedicated unit test; coverage is syntax validation plus `check_no_bare_gh_writes`, which now includes `gh project`, `gh issue`, `gh label`, `gh repo`, `gh secret`, and `gh variable` write shapes.
