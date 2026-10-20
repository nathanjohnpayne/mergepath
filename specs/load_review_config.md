# Governing review configuration loader

`scripts/workflow/load_review_config.sh` exports the four `load-config` outputs consumed by `agent-review.yml`: `threshold`, `paths`, `reviewers` and `author_identity`. It resolves the governing base policy once through `resolve_base_policy.sh`, using event-provided base fields. Default-branch resolution retains the caller's default configuration and makes no GitHub API calls; non-default resolution uses the resolver's materialized temporary policy.

Each list extraction is a complete `parse_policy_list.sh | jq` pipeline. If either stage fails while extracting `external_review_paths` or `available_reviewers`, the loader discards all selected values, emits a warning and exactly these four single-line outputs, then exits 0 (#1374):

```text
threshold=0
paths=[]
reviewers=[]
author_identity=
```

The zero exit keeps dependent triage runnable instead of skipping its fail-closed guards. The loader does not grant merge clearance. Before emitting those defaults after a list failure, it removes only the resolved temporary policy whose path differs from `--default-config`; the caller-owned default configuration survives unchanged. Successful parsing uses the same cleanup ownership rule and preserves the existing compact list and shared scalar semantics. Missing scalar keys retain their empty values, including an unproven author identity.

Resolver failure and an absent shared scalar helper already produce the same defaults. This contract does not redesign YAML parsing, generalize which malformed policies the list reader rejects (#978/#1090), or change output-device errors and the missing-jq usage preflight.

`tests/test_load_review_config.sh` exercises actual loader bytes with isolated resolver/list/jq shims. Its fault matrix covers both list keys, both failing stages (including partial stdout), and both temporary and caller-owned policies; assertions require exit 0, exactly four defaults, retained diagnostics, resolver-owned cleanup and unchanged default bytes. Normal controls, real resolver cases, scalar cases and the default-base zero-network assertion preserve the existing behavior. `scripts/ci/check_external_review_helpers` runs this native suite in CI.
