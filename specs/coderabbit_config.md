# CodeRabbit configuration check

`scripts/ci/check_coderabbit_config` validates the local `.coderabbit.yml`. Existing existence, YAML parsing and universal safety-floor checks apply before template-specific checks.

On the Mergepath template, `reviews.profile` must be `chill` and `reviews.auto_review.auto_pause_after_reviewed_commits` must be present and equal `15`. A missing or different pause threshold exits `1` with a diagnostic naming the full key and expected value. A successful template check reports the threshold.

The existing template detector controls both assertions. Non-template repositories retain their existing output and exit behavior when the pause threshold is absent or different. The check does not propagate `.coderabbit.yml` or change the runtime resume policy.

Coverage is in the existing `tests/test_check_coderabbit_config.sh`, invoked by `scripts/ci/check_coderabbit_config_tests`; a separate test file is unnecessary. It covers correct, missing and changed template thresholds and the unchanged consumer path.
