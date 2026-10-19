# Project documentation synchronization

`scripts/project-doc-sync.sh` materializes and audits the documentation mirrors declared by `.mergepath-project-docs.yml`. PRDs flow from the central documentation repository to their owning repositories; specifications flow from their owning repositories to the central repository. Generated ownership markers and front-matter placement retain their existing contracts.

Generated `source_ref` metadata records the full Git commit object ID for the source path's latest commit. A source path without history falls back to the full HEAD object ID. Existing scoped dirty detection appends `-dirty`; an unavailable Git reference remains `unknown`.

Identical source content and repository state render identical reference metadata across abbreviation settings, object-store sizes and fetches. `--audit` remains read-only. The next materialization rewrites abbreviated references once into the full format.

`tests/test_project_doc_sync.sh` exercises complete materialization and audit against local Git fixtures, including cloned sources with different object stores and `core.abbrev` settings, a fetch without content changes, and the full-HEAD dirty fallback. Existing ownership, front-matter, filtering, symlink and orphan controls remain in that suite.

This specification and its mapped test accompany hub-only tooling. Bootstrap excludes the specification and removes its `spec_test_map` entry. The consumer replay retains the portable spec-to-test alignment check against that consumer shape.
