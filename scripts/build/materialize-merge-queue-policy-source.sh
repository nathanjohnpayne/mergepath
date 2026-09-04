#!/usr/bin/env bash
# Materialize the SHA-pinned workflows and source-owned handshake for the
# protected policy repository.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: materialize-merge-queue-policy-source.sh --write DIRECTORY
       materialize-merge-queue-policy-source.sh --check DIRECTORY
EOF
  exit 2
}

MODE=""
DESTINATION=""
case "${1:-}" in
  --write|--check)
    [ "$#" -eq 2 ] || usage
    MODE=${1#--}
    DESTINATION=$2
    ;;
  *) usage ;;
esac
case "$DESTINATION" in ''|/|.) usage ;; esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AUTH_TEMPLATE="$ROOT/.github/templates/required-workflows/mergepath-merge-queue-authorization.yml"
REPO_LINT="$ROOT/.github/workflows/repo_lint.yml"
FINAL_HANDSHAKE="$ROOT/.github/templates/required-workflows/scripts/merge-queue-final-handshake.sh"
[ -r "$AUTH_TEMPLATE" ] || {
  echo "missing required-workflow template: $AUTH_TEMPLATE" >&2
  exit 1
}
[ -r "$REPO_LINT" ] || {
  echo "missing canonical repo-lint workflow: $REPO_LINT" >&2
  exit 1
}
[ -x "$FINAL_HANDSHAKE" ] || {
  echo "missing executable final-handshake source: $FINAL_HANDSHAKE" >&2
  exit 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/.github/workflows" "$TMP_DIR/scripts/workflow"
cp "$AUTH_TEMPLATE" \
  "$TMP_DIR/.github/workflows/mergepath-merge-queue-authorization.yml"
install -m 0755 "$FINAL_HANDSHAKE" \
  "$TMP_DIR/scripts/workflow/merge-queue-final-handshake.sh"

# Keep repo_lint.yml canonical. The policy-repo variant differs only in the
# trigger surface and concurrency block: organization required workflows
# support pull_request and merge_group, GitHub ignores their event filters,
# and ruleset workflows must not use cancel-in-progress. Rollout separately
# disables these generated workflows in their source repository.
awk '
  BEGIN {
    in_triggers = 0
    in_concurrency = 0
    replaced = 0
    removed_concurrency = 0
    closed = 0
  }
  !replaced && $0 == "on:" {
    print "on:"
    print "  pull_request:"
    print "  merge_group:"
    in_triggers = 1
    replaced = 1
    next
  }
  in_triggers && $0 == "concurrency:" {
    in_triggers = 0
    in_concurrency = 1
    removed_concurrency = 1
    next
  }
  in_concurrency && $0 == "permissions:" {
    in_concurrency = 0
    closed = 1
    print ""
    print
    next
  }
  !in_triggers && !in_concurrency { print }
  END {
    if (!replaced || !removed_concurrency || !closed ||
        in_triggers || in_concurrency) exit 4
  }
' "$REPO_LINT" > \
  "$TMP_DIR/.github/workflows/mergepath-repo-lint.yml" || {
    echo "could not materialize the required repo-lint trigger surface" >&2
    exit 1
  }

if [ "$MODE" = "write" ]; then
  mkdir -p "$DESTINATION/.github/workflows" "$DESTINATION/scripts/workflow"
  install -m 0644 \
    "$TMP_DIR/.github/workflows/mergepath-merge-queue-authorization.yml" \
    "$DESTINATION/.github/workflows/mergepath-merge-queue-authorization.yml"
  install -m 0644 \
    "$TMP_DIR/.github/workflows/mergepath-repo-lint.yml" \
    "$DESTINATION/.github/workflows/mergepath-repo-lint.yml"
  install -m 0755 \
    "$TMP_DIR/scripts/workflow/merge-queue-final-handshake.sh" \
    "$DESTINATION/scripts/workflow/merge-queue-final-handshake.sh"
else
  cmp -s \
    "$TMP_DIR/.github/workflows/mergepath-merge-queue-authorization.yml" \
    "$DESTINATION/.github/workflows/mergepath-merge-queue-authorization.yml" \
    || {
      echo "policy source authorization workflow is missing or drifted" >&2
      exit 1
    }
  cmp -s "$TMP_DIR/.github/workflows/mergepath-repo-lint.yml" \
    "$DESTINATION/.github/workflows/mergepath-repo-lint.yml" || {
      echo "policy source repo-lint workflow is missing or drifted" >&2
      exit 1
    }
  cmp -s "$TMP_DIR/scripts/workflow/merge-queue-final-handshake.sh" \
    "$DESTINATION/scripts/workflow/merge-queue-final-handshake.sh" || {
      echo "policy source final-handshake script is missing or drifted" >&2
      exit 1
    }
  [ -x "$DESTINATION/scripts/workflow/merge-queue-final-handshake.sh" ] || {
    echo "policy source final-handshake script is not executable" >&2
    exit 1
  }
fi

for file in \
  "$TMP_DIR/.github/workflows/mergepath-merge-queue-authorization.yml" \
  "$TMP_DIR/.github/workflows/mergepath-repo-lint.yml" \
  "$TMP_DIR/scripts/workflow/merge-queue-final-handshake.sh"; do
  shasum -a 256 "$file"
done
