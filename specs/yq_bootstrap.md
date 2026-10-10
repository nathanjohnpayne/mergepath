# Pinned yq bootstrap

`scripts/lib/ensure-yq.sh` supplies the CI parser when mikefarah/yq is absent. An already-present mikefarah/yq retains the existing no-op behavior. With `--ci-only`, a local run also skips installation unless `GITHUB_ACTIONS=true`.

The default release is v4.53.6, with the official `yq_linux_amd64` SHA-256 pinned in the script. Download to an unprivileged temporary directory, verify the complete binary with SHA-256, and only then install it with `sudo install` and run its version check. A failed download, invalid expected digest or checksum mismatch must fail before installation or execution, preserving any existing destination. Temporary downloads are removed on exit.

`ENSURE_YQ_DEST` redirects the install destination for offline tests. `ENSURE_YQ_SHA256` supplies the expected fixture digest; overriding `ENSURE_YQ_VERSION` requires an explicit digest. Neither override permits an unchecked download.

The weekly drift audit uses the same release version and retains its existing checksum verification. Cloud setup retains its minimum-version checks; tests of older versions must continue to exercise rejection of releases below v4.53.6.

`tests/test_resolve_pr_threads_verified_propagation.sh` exercises present-parser and local no-ops, missing and wrong-implementation installs, verified fixture installation, checksum mismatch, invalid digest, missing override digest and download failure. The installed v4.53.6 parser must pass `check_sync_manifest`, `check_resolve_pr_threads` and `check_doc_ownership`.
