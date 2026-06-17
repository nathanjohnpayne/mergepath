#!/usr/bin/env bash
set -euo pipefail

# Print stdin lines (file paths) that match any of the glob patterns
# passed as positional arguments, using REPO-RELATIVE path glob semantics
# (#471):
#   *   matches within a single path segment — does NOT cross `/`
#   ?   matches a single character within a segment — does NOT cross `/`
#   **  matches across directories (any depth, including `/`)
#
# This replaces the prior `[[ $file == $pattern ]]` matcher, whose bash
# pattern semantics let `*` cross `/`, so `src/*.js` WRONGLY matched
# `src/nested/file.js` — too broad for a policy knob.
#
# The matcher is the slash-aware twin of the Mergepath Playground's
# compileGlob (mergepath/playground/index.html). Both compile a glob to the
# same anchored ERE — `**` -> `.*`, `*` -> `[^/]*`, `?` -> `[^/]` — with
# regex metacharacters escaped. KEEP THE TWO IN LOCKSTEP.
#
# The glob is converted char-by-char (NOT a multi-pass sed pipeline): the
# earlier sed approach in `.github/workflows/pr-review-policy.yml`
# double-transformed `*` — `.github/**` became `.github/.*` (correct), then
# a second pass turned the remaining `*` into `[^/]*`, yielding
# `.github/.[^/]*` which silently failed to match nested paths
# (mergepath#54). A single left-to-right pass that consumes `**` before `*`
# cannot double-transform.
#
# Usage:
#   printf '%s\n' file1 file2 ... | scripts/workflow/match_protected_paths.sh <pattern>...
#
# Example:
#   $ printf '%s\n' .github/workflows/foo.yml src/main.ts README.md \
#       | scripts/workflow/match_protected_paths.sh '.github/**' 'src/auth/**'
#   .github/workflows/foo.yml

if [ "$#" -eq 0 ]; then
  echo "match_protected_paths.sh: at least one pattern required" >&2
  echo "usage: printf '%s\\n' <files...> | match_protected_paths.sh <pattern>..." >&2
  exit 1
fi

patterns=("$@")

# Compile a repo-relative glob to an anchored ERE with segment-local
# `*`/`?` and cross-directory `**`. Mirrors the Playground's compileGlob
# (see header). Single left-to-right pass; `**` is consumed before `*`.
glob_to_regex() {
  local glob="$1" out="" n i c
  n=${#glob}
  i=0
  while [ "$i" -lt "$n" ]; do
    c="${glob:i:1}"
    case "$c" in
      '*')
        if [ "${glob:i+1:1}" = '*' ]; then
          out+='.*'; i=$((i + 2))          # ** -> any chars, including /
        else
          out+='[^/]*'; i=$((i + 1))       # *  -> segment-local
        fi
        ;;
      '?') out+='[^/]'; i=$((i + 1)) ;;    # ?  -> single non-/ char
      '.'|'+'|'^'|'$'|'('|')'|'{'|'}'|'|'|'['|']'|'\\')
        out+="\\$c"; i=$((i + 1)) ;;        # escape ERE metacharacters
      *) out+="$c"; i=$((i + 1)) ;;
    esac
  done
  printf '^%s$' "$out"
}

# `|| [ -n "$file" ]` so a non-newline-terminated final stdin line
# is still processed in this iteration. Without it, `read` returns
# non-zero on EOF-without-newline and the loop body is skipped — the
# last changed file is silently dropped from protected-path matching,
# which can false-pass the guard on EXACTLY the path you're trying
# to protect. (CodeRabbit Major, #272.)
while IFS= read -r file || [ -n "$file" ]; do
  [ -z "$file" ] && continue
  for pattern in "${patterns[@]}"; do
    regex=$(glob_to_regex "$pattern")
    if [[ "$file" =~ $regex ]]; then
      echo "$file"
      break
    fi
  done
done
