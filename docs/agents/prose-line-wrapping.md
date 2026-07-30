# Prose Line-Wrapping

> Canonical source: `mergepath/docs/agents/prose-line-wrapping.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy. Machine-local vendor files (e.g. a `~/GitHub/CLAUDE.md`, `~/.codex/AGENTS.md`) that mirror this convention must carry a `> Canonical source:` annotation pointing back here.
>
> Consumer maintainers: the sync delivers this file. If your repo's own agent-docs index does not already link it (from the `AGENTS.md` reading order or the documentation-rules sub-file), add that link so agents actually discover it.

This convention is deliberately tech-stack-independent: it governs how Markdown prose is written, not what a repository builds, ships, or tests. It applies identically in every repo that receives it.

## The convention

Soft-wrap Markdown prose: write one physical line per paragraph and let the renderer wrap it. Do not hard-wrap prose at a fixed column (roughly 72 to 80 characters).

GitHub-flavored Markdown collapses single newlines inside a paragraph to spaces, so fixed-column wrapping is invisible in the rendered output. It is therefore enforced by nothing, applied inconsistently by different authors and tools, and it manufactures diff noise: inserting one word re-flows every following line of the paragraph, so a one-word change shows up as a block of changed lines and buries the real edit in review.

This governs intra-paragraph line breaks only. Leave tables, fenced or indented code, YAML front matter, link reference definitions, and list or block-quote structure exactly as written, so the rendered output is unchanged.

It applies to hand-authored GitHub-rendered text as well as committed files: issue bodies, PR bodies, and review comments render through the same paragraph collapsing and get the same treatment.

## Never reflow someone else's file

These are out of scope everywhere, and reflowing them is a defect rather than a cleanup:

- Generated mirrors, and any file carrying a `do_not_edit:` or `sync_direction:` header.
- Files propagated or rendered from another repository's canonical source. Fix the wrapping at that source and let the next sync carry it; a local reflow is overwritten and shows up as drift in the meantime.
- Test fixtures, where the exact bytes are the thing under test.
- Vendored or dependency-managed trees.

## Scope and enforcement are per-repo

Which of a repository's own paths are in scope is a per-repo decision, recorded in that repo's `docs/agents/documentation-rules.md`. Keep that list an explicit allowlist rather than an exclusion list, so a future generated tree or vendored dependency is out of scope until someone opts it in deliberately.

Enforcement differs by repository and that is expected: mergepath, the hub where this convention is authored, runs a local lint gate over its allowlisted tree, while a repo with no gate applies the convention by hand and in review. The absence of a gate is not permission to hard-wrap — the convention is the rule, and the gate is only one repository's way of noticing a violation.
