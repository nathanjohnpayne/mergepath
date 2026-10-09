---
spec_id: bootstrap_git_execution
---

# Bootstrap Git Execution

Bootstrap's initial push resolves `git` in `scripts/lib/gh-token-resolver.sh` before any repository-validation probe. Preflight may already have exported the author credential, so validation and transport both use that single captured path. The transport also resolves its `gh` credential helper with `command -v` before creating the child environment. Each result must be an absolute path without quotes or backslashes; missing commands, shell functions and relative PATH results refuse with exit 5. The runner invokes those captured paths without another PATH lookup.

The existing isolated HOME, disabled hooks, cleared credential helpers and inherited `GIT_*` removal remain part of the transport contract. This binary-path check does not authenticate an operator-selected absolute executable or extend bootstrap's accepted command shape.

`tests/test_gh_as_author.sh`, run by `scripts/ci/check_gh_as_author`, covers successful absolute-path transport, rejection of a repository-controlled relative `git` through the real wrapper with an exported preflight fixture credential, and a guard-removed positive control proving that the same fixture receives the fake author token without the check. No real credential or network push is used.
