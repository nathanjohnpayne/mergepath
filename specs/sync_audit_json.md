# Sync audit JSON (#1591)

`scripts/sync-to-downstream.sh --audit --json` emits newline-delimited JSON (NDJSON): one complete object per selected manifest consumer, in manifest order. Stdout contains records only on successful audit execution; diagnostics go to stderr. Usage errors remain exit 2. Without `--json`, the legacy text audit and its exit codes are unchanged. JSON requires `jq` in addition to the existing audit prerequisites.

The mode composes with `--repos`, `--paths`/`--files`, `--use-local-tree`, `--no-clone`, and `--no-refresh`. Existing consumer opt-in and filter validation apply before comparison. An unavailable local helper or failed hub kit enumeration is a script/source error (exit 2), never a clean consumer record. Empty hub kits still report a missing consumer directory as drift, matching text mode. `--json` is rejected for sync modes. Default audits retain #439's refreshed cache clone of the live default branch; they do not read stale sibling checkouts. A cache refresh failure reports `fetch-error` rather than reading stale cached bytes.

## Consumer record

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1`. |
| `name`, `repo` | Manifest consumer name and `owner/repository`. |
| `visibility` | Manifest-declared visibility; `null` when absent. This is configuration, not a live visibility probe. |
| `baseline` | Consumer comparison reference and full commit SHA as `ref@sha`; `null` if unavailable. |
| `baseline_info` | `ref`, full `sha`, `kind` (`cache-clone` or `local-tree`), `refreshed`, `dirty`, and `warnings`. A local tree is compared as-is; `dirty` discloses that its bytes may differ from the named commit. |
| `hub_sha` | Full local hub HEAD SHA, or `null` when unavailable. The engine compares the hub working tree, as in text mode. Direction evidence requires relevant paths to match HEAD. |
| `status` | `in-sync`, `drift`, `ahead`, `override-only`, or `fetch-error`. |
| `paths` | Differing managed consumer paths, each with `path`, `class` (`canonical`, `kit`, `templated`), `direction`, legacy `comparison` tag, nullable `override_reason`, and nullable `provenance`. Matching files are omitted. |
| `open_sync_prs` | Array of open PRs whose head branch starts with `mergepath-sync/`, or `null` if the source was not measured. Each has integer `number`, `branch`, merge `state` (GitHub `mergeStateStatus`, including `UNKNOWN`), `lifecycle_state: OPEN`, and boolean `draft`. |
| `error` | `null`, or `{source, reason}` with a short generic failure reason. Provider stderr is not copied into records. |
| `audited_at` | UTC observation timestamp. Never used to determine direction. |

Open PRs are read with a complete GraphQL cursor loop. A denied read, GraphQL error, missing repository/connection, malformed page, or non-advancing cursor sets `open_sync_prs: null`, `status: fetch-error`, and exit 3. Partial pages are discarded. `[]` means a complete read found no matching open branches. A consumer clone/refresh failure also leaves PR evidence unmeasured (`null`). PR merge state `UNKNOWN` remains unknown; it is not clearance.

Status precedence is `fetch-error` > any uncovered consumer-ahead path > any other uncovered divergence > differing overridden paths only > `in-sync`. Mixed records retain every differing path and its direction; a consumer with ahead and hub-ahead paths is `ahead`, so a sync preview cannot lose its additional-confirmation requirement. `ahead` and `drift` exit 1, while `override-only` and `in-sync` exit 0. Any fetch error takes fleet-wide exit precedence (3) over drift (1), preserving the existing 0/1/2/3 contract.

## Comparison and direction evidence

Comparisons use the existing byte comparators. JSON expands kits into differing managed files, preserving mixed directions; consumer-only kit extras remain allowed and omitted. A `.sync-overrides.yml` skip covers a whole manifest kit entry, or the consumer destination of a templated entry. Matching skipped files do not make an `override-only` record. Only actual differing bytes covered by a documented skip are emitted with `covered by .sync-overrides.yml` and its reason. Invalid/unreadable overrides retain the existing helper's conservative no-skip behavior.

Missing consumer files use `hub ahead` and remain drift. Differing templated output uses `re-render differs`, rendered with the same consumer facts as the text audit. Other differing canonical/kit files use the following conservative three-way proof, never timestamps or cross-repository commit counts:

1. Find a consumer ancestor within the most recent 200 matching sync commits whose body contains exactly one full `Source: https://github.com/nathanjohnpayne/mergepath/commit/<40-character SHA>` anchor.
2. Resolve that source commit locally and establish that it is an ancestor of the audited hub HEAD.
3. Verify the path's blob and tree mode in that consumer sync commit equal the source path's blob and mode. Both current working-tree files must match their respective HEADs; symlinks and missing paths are not eligible.
4. If the hub HEAD path still equals the source entry and the consumer HEAD path differs, emit `consumer ahead of hub`. If the consumer HEAD still equals the source entry and the hub HEAD differs, emit `hub ahead`. If both differ, keep `unverified divergence`; do not select an older convenient baseline.

`provenance` preserves full source, consumer sync, hub, and consumer HEAD SHAs plus exact source/hub/consumer tree-entry strings (mode, type, blob, path). These allow a reviewer to reproduce the proof. This is advisory direction evidence, not an authorization or a guarantee that consumer changes should replace canonical content. Missing history (including depth-1 caches), unavailable objects, dirty relevant paths, unverifiable source claims, and changes on both sides remain `unverified divergence`/`drift`. The audit never fetches additional history solely to manufacture an ahead verdict. Mode-only differences remain outside the existing byte comparator's scope, preserving text-mode semantics.

The stateless CLI has no last-good-result cache, so it cannot invent a last-good age. The fleet panel retains successful records and computes stale age from their `audited_at` when a later audit fails. JSON supplies the short failure reason and observation timestamp.

## Verification

`tests/test_sync_audit_json.sh` uses local git histories, synthetic manifest consumers, and a hermetic `gh` stub. It covers the five states, mixed directions/status precedence, overridden matching and differing files, kit allow-extras, templated destinations, proof rejection, cursor pagination and errors, filter composition, cache/default-branch refresh and rename, exit precedence, and byte-identical legacy output. `tests/test_sync_to_downstream.sh` retains the existing engine regression suite. The `check_sync_to_downstream` integration must run both suites; hub-only paths remain excluded from consumer propagation.
