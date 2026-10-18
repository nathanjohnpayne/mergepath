# Script and test propagation closure

A script delivery must not leave its individually declared tests stale or missing (#2256). The existing `tests/` manifest entry declares its tested `scripts/` artifact with `requires:`. The metadata checker adds the reverse script-to-test obligation whenever the script is delivered, including through a containing selected kit or a rendered script destination. Applicable consumer scopes and existing skip ownership still govern the carriers.

The materializer does not expand a selection. A coupled test must be selected or already match the canonical bytes, tree-entry type and executable mode on the consumer. Otherwise the existing requires-closure artifact gate refuses before opening or pushing the PR and names the affected paths. Include the paired tests or bring them current first. A skip withholding all applicable test carriers also withholds the associated script.

A test-only selection retains its forward runtime dependencies. Unrelated slices have no reverse obligation. Whole test kits do not imply a test-to-script relation, and undeclared relationships are not inferred from file contents. Existing template logical identities and rendered artifact proof remain authoritative.

Coverage: `tests/test_sync_overrides.sh` exercises consumer scopes, selected kits, rendered script identities, unrelated slices and skipped tests. `tests/test_sync_to_downstream.sh` runs the production materializer against disposable Git repositories: stale and missing tests refuse, paired/current tests pass, and disabling the reverse obligation in the fake hub makes the stale-test case reach PR creation.
