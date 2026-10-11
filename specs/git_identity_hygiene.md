# Git identity hygiene

`scripts/ci/check_git_identity_hygiene` protects commit attribution and signing through three independent checks: local/worktree identity overrides, a repository-config snapshot comparison, and the static instruction scan. The static scan runs in every hub and consumer checkout (#1195); the presence of `scripts/sync-to-downstream.sh` controls only execution of the paired hub regression suite.

## Static scan scope

The production scan enumerates tracked regular shell scripts and Markdown documents with `git ls-files -z`; NUL-delimited paths preserve Unicode, quoted and newline-containing filenames. Symlink files and paths beneath symlinked directories are excluded: a tracked link names a link object, not machine-local target source. Fixture-root runs enumerate their supplied regular files without repository internals or symlink traversal. Repo-owned consumer surfaces, including `REVIEW_POLICY.md`, remain in scope even when a consumer retains a bootstrap-frozen copy. The same scanner, key classifier, command parsing and exemption rules apply in both environments. Its ASCII command grammar reads source under the C locale so unrelated non-UTF8 document bytes cannot abort enumeration of findings.

The scanner and `tests/test_git_identity_hygiene.sh` exclude themselves because they carry forbidden commands as examples and test input. Generated `docs/projects/*/prds/*` mirrors remain excluded because their source belongs to the central documentation repository. These exclusions do not exempt other test suites or repository-owned docs. Explicit repository targets, unambiguous global/system option prefixes (including `--gl` and `--sy`), ephemeral identity overrides, reads/removals and deliberate `GIT_IDENTITY_SCOPE_EXEMPT: <reason>` comments keep their existing meaning. Shell markers must be unquoted, unescaped comments; Markdown HTML markers must be complete comments outside fenced or indented code, including fences in blockquote and nested list containers in their source order. Ending an inner container ends its fence without discarding surviving outer containers. Container indentation uses four-column tab stops. Shell-comment exemptions remain valid inside fenced and indented examples. Indentation is measured after container prefixes; empty first children or list-marker spacing over four blanks use the marker-width-plus-one fallback. Indented code cannot interrupt an open paragraph. Blank lines, container changes, fences, headings and thematic/setext boundaries reset the bounded paragraph state. Shell comment boundaries accept space/tab and control operators, not vertical tab or form feed. Fence closers accept only spaces/tabs with an optional CRLF carriage return.

HTML exemption detection skips escaped markup, inline link destinations/titles (including angle-delimited destinations) and HTML tags with quoted attributes before testing complete comment bodies. This is bounded lexical recognition on a physical line or continued command, combined with per-file fence/container/paragraph state and the existing single/double-backtick code-span handling; it does not render Markdown or validate every Markdown construct. Literal marker text in those data contexts cannot exempt a write; a real comment after a closed construct retains its meaning.

Command separation preserves single/double quotes and ordinary escapes around literal option words, so separators inside a Git `-c` value cannot disconnect the executable from `config`. Complete executable words are dequoted before matching `git` or a path ending in `/git`; variable expansion and runtime executable lookup are not evaluated. Scope/read exemptions classify complete dequoted option words in the invocation prefix, skip the fixed set of separate option operands and stop classifying flags at `--`. Quoted option-value data cannot supply an exemption or move the prefix to a literal `git` mentioned inside that value; a repository target directory named `git` remains an operand. The modern `rename-section` verb, like its legacy flag form, is a section operation rather than a protected-key assignment.

The paired regression suite retains its marker-first consumer skip: it checks hub-maintained policy prose that is not propagated. Presence of a stale suite or policy copy never makes a consumer execute those hub assertions. Explicit suite overrides retain the existing post-suite identity, config and metadata tests.

## Consumer migration snapshot, 2026-10-11

The live main refs were refreshed at 2026-10-11 21:38:51 UTC. The current `.mergepath-sync.yml` names seven consumers; `device-source-of-truth` is no longer in that corpus. The following counts come from immutable GitHub main archives at the recorded commits, scanned by the updated shared check with the fixture-root override, no invented hub marker and no substituted suite. Counts measure reported offending physical/logical lines, not individual writes; one line can carry more than one command. They are source-shape findings, not evidence that a command executed or that a developer checkout currently carries an override.

| Consumer | Main commit | Policy lines | Fixture-test lines |
| --- | --- | ---: | ---: |
| `matchline` | `798df55c3caee2cf32745f1cee003647591fb4a8` | 4 | 0 |
| `nathanpaynedotcom` | `c241241c44a0eb2ea74c89e272f8710bd1225023` | 0 | 0 |
| `overridebroadway` | `7f993eee898c562e51647491d9295b6b129056d3` | 4 | 0 |
| `friends-and-family-billing` | `3691ab5b9f2580f3ffa324bba46674aef47184fc` | 4 | 0 |
| `swipewatch` | `bee3ce917a9ee801cc2e2c4e8b0188e5b777f2c5` | 4 | 0 |
| `tadlockpsychiatry` | `43f26d96c430c561ec08895f02d4ff60f557f6e8` | 4 | 0 |
| `fiveacross` | `7e34ba896bd3e53334cbfc9f74ffc4accd87de36` | 4 | 29 |

`nathanpaynedotcom` remains the clean control. The other six consumers need the four runnable identity assignments in their repo-owned `REVIEW_POLICY.md` rewritten before or alongside propagation of this guard. Those files are not manifest-delivered, so ordinary canonical propagation cannot perform that migration. Replace the stale identity-switching snippet with verification of the machine's real global author identity and reviewer-token switching; do not convert fixture addresses into executable global writes.

`fiveacross` additionally needs its fixture setup in `tests/test_deploy.sh` and `tests/test_worktree_cleanup.sh` scoped explicitly. Preserve the fixture names, email addresses, signing settings and execution behavior: target the existing fixture directory with `git -C`, or use an ephemeral per-command override when that fits the fixture. If cwd-dependent setup is deliberately retained, review and document the specific exception with the existing exemption marker. A preceding `cd` alone does not satisfy the static contract. Do not remove fixture identity setup, add broad path exemptions or introduce a consumer-local duplicate check to make migration pass.

Refresh these observations before opening migration PRs. A consumer with unresolved source hits is expected to fail the newly active guard until its local migration lands; the downstream tracker nathanjohnpayne/nathanpaynedotcom#782 closes only after reviewed propagation and live consumer acceptance.

## Regression coverage

`tests/test_git_identity_hygiene.sh` exercises the shared parsing cases with markerless fixtures and uses a real consumer index to verify policy/script findings, untracked-file exclusion, generated/self-fixture exclusions, scoped fixture writes, explicit exemptions, source encoding and the separate hub-suite gate. Existing identity/config/metadata tests remain intact. The hub consumer-safety and residue suites verify the wrapper in their canonical consumer models.
