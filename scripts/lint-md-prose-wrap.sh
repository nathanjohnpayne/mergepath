#!/usr/bin/env bash
# lint-md-prose-wrap.sh — enforce soft-wrapped Markdown *prose* in repo-owned
# docs (one physical line per paragraph; the renderer wraps).
#
# This is the mergepath-LOCAL Markdown prose gate. It is intentionally NOT a
# scripts/ci/check_* (those propagate to every consumer via the scripts/ci/
# kit) and NOT wired into the propagated repo_lint.yml. It runs only here, via
# the standalone .github/workflows/md-prose-wrap.yml workflow, so no consumer
# CI is touched. See docs/agents/documentation-rules.md § Prose line-wrapping.
#
# The actual render-preserving transform lives in scripts/lib/md_reflow.py
# (Markdown-AST-aware, fail-closed render check). This wrapper owns the
# *policy*: which .md files are in scope.
#
# Modes:
#   --check   (default) exit 1 if any in-scope file is not soft-wrapped
#   --write   rewrite in-scope files in place
#   --diff    print a unified diff of what --write would do
#   --list    print the resolved in-scope file list and exit
#
# Self-bootstrap: if python3 or markdown-it-py is unavailable, the gate
# soft-passes (exit 0) with a note rather than hard-failing — mirrors the
# repo's "soft-pass if the tool isn't present yet" idiom (repo_lint.yml). CI
# installs the pinned dependency, so enforcement is real there.

set -euo pipefail

MODE="--check"
if [ "$#" -gt 0 ]; then
  case "$1" in
    --check | --write | --diff | --list) MODE="$1"; shift ;;
    -h | --help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "lint-md-prose-wrap.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Scope is an ALLOWLIST (fail-safe): only the repo-owned prose roots below are
# in scope, and any path NOT matched is out of scope by default. A future
# directory — a generated/build tree, a vendored dependency, a new code area —
# is therefore NEVER swept in until it is added here on purpose. This is the
# opposite of a denylist, which would reflow everything except a hand-kept
# blocklist and silently pull in an unrelated tree the day it appears.
#
# The allowlist mirrors docs/agents/documentation-rules.md § Prose
# line-wrapping. Within an in-scope root a few paths are still carved out
# (they are matched FIRST, before the broad includes):
#   docs/projects/*/prds/*   generated PRD mirror (do_not_edit; central->repo)
#   docs/audits/data/*       generated stat tables / raw-data descriptors
#   .github/pull_request_template.md, .github/ISSUE_TEMPLATE/*
#                            propagated to ~8 consumers via .mergepath-sync.yml
#                            (reflowing the source changes byte-identical
#                            downstream output; deferred to a sync wave)
# Kit READMEs under scripts/{ci,phase-4b,gh-projects,workflow}/ are propagated
# too, but scripts/ is simply not an in-scope root, so they fall out by
# omission (the fail-safe default) with no explicit carve-out.
# ---------------------------------------------------------------------------
is_in_scope() {
  case "$1" in
    # Carve-outs inside an in-scope root (generated mirror / propagated) win.
    docs/projects/*/prds/*) return 1 ;;
    docs/audits/data/*) return 1 ;;
    .github/pull_request_template.md | .github/ISSUE_TEMPLATE/*) return 1 ;;
    # Allowlisted repo-owned prose roots.
    docs/* | rules/* | plans/* | specs/* | packaging/*) return 0 ;;
    .github/copilot-instructions.md | .github/templates/* | .github/screenshots/*) return 0 ;;
    functions/README.md | mergepath/README.md | tests/README.md) return 0 ;;
    scripts/build/README.md | bugs/screenshots/README.md | artifacts/*) return 0 ;;
    # A repo-root doc (a top-level *.md with no directory component) is in
    # scope; any OTHER nested path is out of scope by default (fail-safe).
    */*) return 1 ;;
    *) return 0 ;;
  esac
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lint-md-prose-wrap.sh: not inside a git work tree" >&2
  exit 2
fi

FILES=()
while IFS= read -r f; do
  is_in_scope "$f" || continue
  FILES+=("$f")
done < <(git ls-files '*.md')

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "lint-md-prose-wrap.sh: no in-scope Markdown files found" >&2
  exit 0
fi

if [ "$MODE" = "--list" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

# Self-bootstrap: soft-pass if the runtime is not present yet.
PYTHON="${MD_REFLOW_PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "lint-md-prose-wrap.sh: python3 not found — soft pass (self-bootstrap)" >&2
  exit 0
fi
if ! "$PYTHON" -c 'import markdown_it' >/dev/null 2>&1; then
  echo "lint-md-prose-wrap.sh: markdown-it-py not installed — soft pass (self-bootstrap)" >&2
  echo "  install: $PYTHON -m pip install 'markdown-it-py==4.2.0'" >&2
  exit 0
fi

exec "$PYTHON" "$REPO_ROOT/scripts/lib/md_reflow.py" "$MODE" "${FILES[@]}"
