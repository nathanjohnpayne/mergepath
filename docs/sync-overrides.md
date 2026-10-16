# Per-repo sync overrides

Each downstream consumer of the Mergepath template can carry a `.sync-overrides.yml` at its repo root declaring **intentional divergences** from the canonical mirror. The propagation script (`scripts/sync-to-downstream.sh`) reads this file when computing what to write to a consumer, so legitimate per-repo divergence stays put while everything else syncs cleanly.

This is the third leg of the propagation system. The other two:

- **The manifest** — `.mergepath-sync.yml` in mergepath's repo root. Declares which paths are canonical / kit / templated, and which consumers opt in to each. Single source of truth for **what** propagates.
- **The propagation script** — `scripts/sync-to-downstream.sh`. Reads the manifest + a target commit, computes per-consumer file diffs, opens a PR per consumer.

Without the override mechanism the script would either silently overwrite legitimate per-repo divergence (data loss) or have to abort whenever it detected a difference (which makes the script useless on any non-trivial consumer). The override file resolves that by giving each repo a documented escape hatch — every divergence carries a `reason`, so drift without a paper trail is the failure mode the schema exists to prevent.

## File location and lifecycle

- **Location.** `.sync-overrides.yml` at the consumer repo's root, alongside `.mergepath-sync.yml`-managed canonical paths.
- **Absence is allowed.** A consumer with no documented divergences should not have the file at all. The validator treats an absent file as "no overrides" (pass).
- **Schema validation.** `scripts/sync/validate-overrides.sh` runs on every PR in the downstream repo via the `repo_lint.yml` workflow. A malformed override blocks merge.
- **Application.** `scripts/sync/apply-overrides.sh` exposes two helpers (`override_should_skip_path`, `override_substitution_for`) that the propagation script calls per-path. The library is read-only and has no side effects beyond setting one global (`OVERRIDE_SKIP_REASON`) for caller logging.

## Schema

```yaml
# Schema version. Required on any non-empty document; must equal 1
# (bumped on incompatible schema changes).
version: 1

# Paths the propagation script must NOT overwrite for this repo.
# Each entry references the consumer-side target declared by the
# manifest at .mergepath-sync.yml: `.dest` for a templated entry,
# `.path` for a canonical or kit entry.
skip_paths:
  - path: <consumer-target-from-manifest>
    reason: <non-empty rationale; multi-line allowed>

# Override values for templated-path substitution markers. Manifest
# defaults apply where this map is silent. Keys must match a
# substitution marker declared by a `type: templated` path in the
# manifest. Each entry is a structured `{value, reason}` map — both
# fields required and non-empty (whitespace counts as empty). Bare-
# scalar overrides are explicitly rejected so substitutions carry
# the same audit-trail discipline as `skip_paths`.
substitutions:
  <marker-name>:
    value: <non-empty override-value>
    reason: <non-empty rationale; multi-line allowed>
```

### Validation rules

`scripts/sync/validate-overrides.sh` enforces:

| Rule | Behavior on violation |
|---|---|
| File parses as YAML | Exit 1 |
| Top-level keys ⊆ {`version`, `skip_paths`, `substitutions`} | Exit 1 |
| `version` is required on non-empty documents and must equal 1 | Exit 1 |
| Every `skip_paths[].path` exactly matches a manifest consumer target (`.dest` for templated, `.path` otherwise) | Exit 1 |
| Every `skip_paths[].reason` is non-empty (whitespace counts as empty) | Exit 1 |
| Effective consumer skips preserve declared `requires:` coverage for every active entry | Exit 1; ambiguous consumer identity exits 2 |
| Every `substitutions.<key>` matches a marker declared by a `type: templated` manifest path | Exit 1 |
| Every `substitutions.<key>` is a map with non-empty `value` and non-empty `reason` fields (whitespace counts as empty for both) | Exit 1 |

Absence of the file → exit 0. Empty file → exit 0 (no entries means no constraints to validate).

The "every marker is declared" rule is the strictest of these and is intentional. A templated path may declare no substitution markers; any non-empty `substitutions:` content must still match a marker that a templated manifest entry actually declares.

## Effective dependency closure

A documented skip cannot withhold every applicable carrier of a manifest `requires:` path while leaving its requiring entry active (#1041). Sync fails closed before opening or pushing a propagation PR, naming the consumer, requiring entry and required path. Remove the dependency skip or skip the requiring entry as well. Independent skips remain valid. Exact entries and containing kits form a coverage union: a surviving applicable carrier is sufficient, including a kit without a trailing slash. Templated entries use their logical `.path` for dependency coverage and consumer `.dest` for skip ownership; an omitted destination defaults to `.path`, while a present null, empty, nonstring or control-byte destination is invalid. For a logical requirement with an exact templated mapping applicable to this consumer, only an unskipped templated carrier counts: a raw source-side kit is not delivery of its rendered destination. Non-templated requirements retain their exact/kit union, and another consumer’s inapplicable template does not shadow plain coverage. Only declared direct edges are checked; this does not discover dependencies from file contents or infer runtime behavior.

Sync checks the selected outgoing carriers and retains its existing current-artifact content, executable-mode and template-render checks. A selected kit also activates the already-declared requirements of consumer-applicable entries it delivers. Skipping an exact requiring entry removes its obligation only when no selected unskipped carrier still delivers that consumer artifact; a kit carrying a template source does not reactivate a skipped rendered destination elsewhere. Local `--sync-all --dry-run` uses the same selected metadata check before reporting a planned PR; it does not clone, contact GitHub or prove current artifact bytes. Remote override state remains unknown without a local worktree. Audit checks the effective manifest for each selected consumer before classifying differences; a contradiction is a configuration error, not `override-only` success. JSON audit exits 2 with empty buffered stdout on this fatal error, while completed fetch-error and drift audits retain their existing status/exit precedence.

The validator accepts `scripts/sync/validate-overrides.sh [overrides-file] [manifest-file] [consumer-name]`. Supply an explicit manifest consumer name when validating a scoped skip. Without it, the validator checks every declared consumer scope: uniform success passes, uniform contradiction exits 1, and differing outcomes exit 2 requesting the selector. An unknown selector exits 2 when a nonempty skip set needs closure validation. No identity is guessed from a directory, remote or environment. Absent, empty and no-skip documents keep their existing behavior.

Closure enumerates distinct validated skip targets once and delegates each decision to the unchanged application reader in a buffered child shell. Its first serialized reason line, including duplicate-path order and empty or literal `null` first lines, remains authoritative; closure does not normalize reasons or change the validator schema. The child shell preserves the application reader’s caller-visible reason output.

The two existing application readers still treat absent files and read errors as no override. The separate `override_requires_load` / `override_requires_check` metadata helpers fail closed on unavailable or malformed closure inputs and expose a diagnostic through `OVERRIDE_REQUIRES_DETAIL`. Their indexed literal-metadata check buffers the effective direct-edge list in `OVERRIDE_REQUIRES_ACTIVE_EDGES` only after successful validation; failures clear it. Sync consumes that same selected list for its separate current-artifact proof. The processor is portable `awk`, already part of the sync toolchain; unavailable or failed processing is a metadata error, not an empty successful graph. Applicable template dependencies retain the existing expected-render, fact-export, byte and executable-mode proof; a byte-current raw source kit cannot mask a missing, stale or mode-wrong rendered artifact. The engine and validator are hub/bootstrap machinery, so merging this change does not claim a canonical wave has upgraded every installed consumer validator. The previously cleared gaycruisebingo skip incident remains completed; this change supplies the structural guarantee.

## Worked examples

### A consumer that never diverges

The recommended starting state for new repos created from the Mergepath template. Either omit the file entirely, or commit an explicit empty version copied from `examples/.sync-overrides.yml`:

```yaml
version: 1
skip_paths: []
substitutions: {}
```

### A consumer that legitimately uses Cloud Run instead of Firebase Hosting

```yaml
version: 1
skip_paths:
  - path: .github/workflows/deploy.yml
    reason: |
      This repo's deploy workflow targets Cloud Run, not Firebase
      Hosting (which the canonical workflow assumes). Tracked in
      <repo>#42 for eventual canonical convergence once Mergepath
      ships a Cloud Run variant.
```

The propagation script logs the skip + reason on every run for that repo. The reason is the audit trail: a future maintainer reading this can decide whether the divergence still applies, file the convergence work, or remove the override when canonical catches up.

### A high-deploy-frequency repo overriding a Phase-4b knob

```yaml
version: 1
substitutions:
  phase_4b_default:
    value: fallback-only
    reason: |
      Deploy frequency is high (~5 PRs/day), and the latency cost of
      always-on phase-4b proactive routing outweighs the safety
      benefit. Re-evaluate after 90 days (target review: 2026-08-01).
```

(This example assumes a future templated path in the manifest declares `phase_4b_default` as a substitution marker. v1 manifest doesn't yet.)

The `reason` field is part of the substitution map, not a YAML comment — the validator's Rule 7 enforces it the same way `skip_paths[].reason` is enforced. A bare-scalar override (`phase_4b_default: fallback-only`) fails validation explicitly.

## Workflow: adding an override

1. Open a PR in the downstream repo that includes:
   - The new `.sync-overrides.yml` entry (skip_paths / substitutions, with `reason`).
   - The corresponding file change (the actual divergence in the repo content).
2. The reviewer flags any `reason` field that's missing or vague. "Required for this repo" is not a reason; "uses Cloud Run instead of Firebase Hosting (issue #42)" is.
3. Merge.

## Workflow: removing an override (re-converge with canonical)

1. Remove the entry from `.sync-overrides.yml`.
2. From a Mergepath checkout, run a dry-run sync to confirm the next propagation will write the canonical version:

   ```bash
   scripts/sync-to-downstream.sh HEAD --repos <consumer-name> --dry-run
   ```

3. Merge in the consumer repo.
4. The next live propagation run picks up the removed override and writes the canonical content.

## Helper API (for `sync-to-downstream.sh` integration)

```bash
. "$MERGEPATH_ROOT/scripts/sync/apply-overrides.sh"

# Per-consumer, per-path:
if override_should_skip_path "$consumer_overrides_file" "$path"; then
  log "skip $path on $consumer_name: $OVERRIDE_SKIP_REASON"
  continue
fi

# For templated paths' substitution markers:
if override_value=$(override_substitution_for "$consumer_overrides_file" "$marker"); then
  rendered_value="$override_value"
else
  rendered_value="$manifest_default"
fi
```

The helpers are read-only, treat any error or absent file as "no override" (conservative — over-propagation is safer than silent skips), and never abort the caller. They assume a previously-validated overrides file (downstream CI runs `validate-overrides.sh` on every PR).

## References

- [#168](https://github.com/nathanjohnpayne/mergepath/issues/168) — parent: `sync-to-downstream.sh` propagation tool design.
- [#198](https://github.com/nathanjohnpayne/mergepath/issues/198) — sub-A: manifest spec (closed; landed via PR #215).
- [#199](https://github.com/nathanjohnpayne/mergepath/issues/199) — sub-B: main propagation script (in progress).
- [#200](https://github.com/nathanjohnpayne/mergepath/issues/200) — sub-C: this override mechanism.
- [#201](https://github.com/nathanjohnpayne/mergepath/issues/201) — sub-D: `--audit` drift detection (closed; landed via PR #215).
