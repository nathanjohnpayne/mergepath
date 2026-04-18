#!/usr/bin/env bash
set -euo pipefail

# Print stdin lines (file paths) that match any of the glob
# patterns passed as positional arguments. Patterns use bash
# extended pattern matching (`[[ str == pattern ]]`), which — for
# our purposes — handles `**` cleanly: `.github/**` matches
# `.github/workflows/foo.yml` without needing `shopt -s globstar`.
#
# Usage:
#   printf '%s\n' file1 file2 ... | scripts/workflow/match_protected_paths.sh <pattern>...
#
# Example:
#   $ printf '%s\n' .github/workflows/foo.yml src/main.ts README.md \
#       | scripts/workflow/match_protected_paths.sh '.github/**' 'src/auth/**'
#   .github/workflows/foo.yml
#
# Why bash `[[ ]]` instead of an explicit glob-to-regex sed pipeline:
# the earlier sed implementation in `.github/workflows/pr-review-policy.yml`
# double-transformed `*` — `.github/**` became `.github/.*` (correct),
# then a second pass converted the remaining `*` into `[^/]*`, yielding
# `.github/.[^/]*` which silently failed to match nested paths. See
# mergepath#54 for the full post-mortem.

if [ "$#" -eq 0 ]; then
  echo "match_protected_paths.sh: at least one pattern required" >&2
  echo "usage: printf '%s\\n' <files...> | match_protected_paths.sh <pattern>..." >&2
  exit 1
fi

patterns=("$@")

while IFS= read -r file; do
  [ -z "$file" ] && continue
  for pattern in "${patterns[@]}"; do
    # shellcheck disable=SC2053  # $pattern is intended to be a glob
    if [[ "$file" == $pattern ]]; then
      echo "$file"
      break
    fi
  done
done
