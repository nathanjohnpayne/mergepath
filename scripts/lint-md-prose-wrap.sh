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
      sed -n '2,26p' "$0"
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
# In-scope = repo-owned, local, prose Markdown. Everything excluded below is
# excluded for a specific, durable reason — keep the reasons with the globs so
# a future reader knows why a path is out of scope (and does not "helpfully"
# re-include a propagated mirror).
#
# EXCLUDED — generated mirror (edit the canonical source, never the mirror):
#   docs/projects/*/prds/*            central-to-repo PRD mirror (do_not_edit)
#
# EXCLUDED — propagated to ~8 consumers via .mergepath-sync.yml (reflowing the
# source changes byte-identical downstream output; needs a coordinated sync
# wave, deliberately deferred):
#   .github/pull_request_template.md  canonical, consumers: all
#   .github/ISSUE_TEMPLATE/*          kit, consumers: all (front-matter bodies)
#   scripts/ci/*                      kit
#   scripts/phase-4b/*                kit
#   scripts/gh-projects/*             kit (README + examples/** fixtures)
#   scripts/workflow/*                kit (no .md today; excluded defensively)
#
# EXCLUDED — fixtures / generated data where bytes are load-bearing:
#   docs/audits/data/*                generated stat tables + raw-data descriptors
#   (scripts/gh-projects/examples/**  already covered by the kit exclusion)
# ---------------------------------------------------------------------------
is_excluded() {
  case "$1" in
    docs/projects/*/prds/*) return 0 ;;
    .github/pull_request_template.md) return 0 ;;
    .github/ISSUE_TEMPLATE/*) return 0 ;;
    scripts/ci/*) return 0 ;;
    scripts/phase-4b/*) return 0 ;;
    scripts/gh-projects/*) return 0 ;;
    scripts/workflow/*) return 0 ;;
    docs/audits/data/*) return 0 ;;
    *) return 1 ;;
  esac
}

FILES=()
while IFS= read -r f; do
  is_excluded "$f" && continue
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
