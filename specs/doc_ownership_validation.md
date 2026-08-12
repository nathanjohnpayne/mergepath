---
spec_id: doc_ownership_validation
---

# Documentation Ownership Validation

`scripts/ci/check_doc_ownership` is a fail-closed integrity check for documentation that Mergepath propagates to consumer repositories. It validates each `docs/agents/*.md` ownership declaration and checks that canonical documents do not contain rendered, repository-relative links to documentation classified `hub-only`.

## Rendered-link extraction

The check considers Markdown links and images that a CommonMark reader renders. It excludes code blocks, inline code, raw HTML blocks, and fenced code blocks, including those opened inside list items or block quotes. Container state ends when the list item or quote holding it ends; state from an inner container must not suppress later top-level Markdown.

Link destinations are compared after the transformations a reader applies that affect the repository-relative path: valid ASCII-punctuation backslash escapes, supported character references, and valid UTF-8 percent-encoded byte sequences. Query strings and fragments are not path components. A malformed encoding, a reference the check cannot resolve, or an extractor failure must not produce a clean ownership verdict.

## Verification

`tests/test_check_doc_ownership.sh` supplies a CommonMark-derived matrix for the ownership check. New parsing behavior must add a discriminating regression case: one that would yield an incorrect rendered-link or ownership result if the behavior regressed.
