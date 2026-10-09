#!/usr/bin/env bash
# Immutable reasoning input and its context-bound adapter verdict (#1753).
# Sourced by the trusted orchestrator/adapters; capture also has a CLI entry.

p4b_input_command() {
  local resolved
  resolved="$(command -v "$1" 2>/dev/null)" || return 1
  case "$resolved" in /*) ;; *) return 1 ;; esac
  case "$resolved" in *"'"*|*'\'*) return 1 ;; esac
  printf '%s\n' "$resolved"
}

p4b_input_digest() {
  local node_bin
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  node_bin="$(p4b_input_command node)" || return 1
  "$node_bin" -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$1"
}

# API-owned head-transition events detect an observed A-B-A swap while the
# model runs. The immutable object diff remains authoritative regardless.
p4b_input_transitions() { # repo pr output-file
  local gh_bin pages
  gh_bin="$(p4b_input_command gh)" || return 1
  pages="$("$gh_bin" api --paginate --slurp "repos/$1/issues/$2/timeline")" || return 1
  printf '%s' "$pages" | jq -e '
    type == "array" and all(.[]; type == "array" and all(.[]; type == "object"))
  ' >/dev/null || return 1
  printf '%s' "$pages" | jq -c '
    [.[][] | select(.event | IN("head_ref_force_pushed", "head_ref_deleted", "head_ref_restored"))
      | {id, event, created_at, commit_id}]
  ' >"$3" || return 1
  jq -e 'all(.[]; (.id | type == "number" and floor == . and . > 0)
    and (.created_at | type == "string" and length > 0))' "$3" >/dev/null
}

p4b_capture_input() { # repo pr full-base full-head private-output-dir
  local repo="$1" pr="$2" base="$3" head="$4" dest="$5"
  local git_bin gh_bin merge_base actual_base actual_head digest transitions
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$pr" =~ ^[0-9]+$ && "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -d "$dest" ] && [ ! -L "$dest" ] || return 1
  chmod 700 "$dest" || return 1
  git_bin="$(p4b_input_command git)" || return 1
  gh_bin="$(p4b_input_command gh)" || return 1
  p4b_input_transitions "$repo" "$pr" "$dest/head-transitions.json" || return 1
  mkdir "$dest/home" || return 1
  # Never reuse a PR checkout, its config, or inherited repository redirects.
  local -a git_env=()
  local variable
  for variable in $(compgen -e); do
    case "$variable" in GIT_*) git_env+=(-u "$variable") ;; esac
  done
  git_env+=(HOME="$dest/home" XDG_CONFIG_HOME="$dest/home/.config"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    GIT_ASKPASS= SSH_ASKPASS=)
  env -u GITHUB_TOKEN ${git_env[@]+"${git_env[@]}"} "$git_bin" init --bare -q "$dest/objects.git" || return 1
  env -u GITHUB_TOKEN ${git_env[@]+"${git_env[@]}"} "$git_bin" -C "$dest/objects.git" \
    -c credential.helper= -c "credential.helper=!'$gh_bin' auth git-credential" \
    -c core.hooksPath=/dev/null -c http.extraHeader= \
    fetch --quiet --no-tags --no-recurse-submodules --no-write-fetch-head -- \
    "https://github.com/$repo.git" "$base" "$head" || return 1
  actual_base="$(env ${git_env[@]+"${git_env[@]}"} "$git_bin" -C "$dest/objects.git" rev-parse --verify "$base^{commit}")" || return 1
  actual_head="$(env ${git_env[@]+"${git_env[@]}"} "$git_bin" -C "$dest/objects.git" rev-parse --verify "$head^{commit}")" || return 1
  [ "$actual_base" = "$base" ] && [ "$actual_head" = "$head" ] || return 1
  merge_base="$(env ${git_env[@]+"${git_env[@]}"} "$git_bin" -C "$dest/objects.git" merge-base "$base" "$head")" || return 1
  [[ "$merge_base" =~ ^[0-9a-f]{40}$ ]] || return 1
  env ${git_env[@]+"${git_env[@]}"} "$git_bin" -C "$dest/objects.git" \
    diff --binary --full-index --no-ext-diff --no-textconv "$merge_base" "$head" -- >"$dest/review.diff" || return 1
  [ -s "$dest/review.diff" ] || return 1
  digest="$(p4b_input_digest "$dest/review.diff")" || return 1
  transitions="$(p4b_input_digest "$dest/head-transitions.json")" || return 1
  jq -n --arg base "$base" --arg head "$head" --arg merge_base "$merge_base" \
    --arg digest "$digest" --arg transitions "$transitions" \
    '{base_sha:$base,head_sha:$head,merge_base_sha:$merge_base,diff_sha256:$digest,head_transitions_sha256:$transitions}' >"$dest/input.json" || return 1
  chmod 400 "$dest/review.diff" "$dest/input.json" "$dest/head-transitions.json"
}

p4b_revalidate_input() { # repo pr private-dir
  local expected actual transition_digest
  expected="$(jq -er '.diff_sha256' "$3/input.json")" || return 1
  actual="$(p4b_input_digest "$3/review.diff")" || return 1
  [ "$actual" = "$expected" ] || return 1
  p4b_input_transitions "$1" "$2" "$3/current-transitions.json" || return 1
  transition_digest="$(p4b_input_digest "$3/current-transitions.json")" || return 1
  [ "$transition_digest" = "$(jq -er '.head_transitions_sha256' "$3/input.json")" ]
}

# The reasoning model emits only the established verdict schema. The trusted
# adapter adds input metadata after validating the model result; model text
# cannot choose a head or digest. Standalone reasoning without metadata has
# no postable binding and is rejected by the orchestrator.
p4b_bind_input() { # metadata-file raw-diff fitted-diff verdict-json
  local digest fitted
  if [ -z "$1" ]; then
    printf '%s' "$4" | jq -c '. + {review_input:null}'
    return
  fi
  digest="$(p4b_input_digest "$2")" || return 1
  fitted="$(p4b_input_digest "$3")" || return 1
  jq -e --arg digest "$digest" '
    (keys | sort) == ["base_sha","diff_sha256","head_sha","head_transitions_sha256","merge_base_sha"]
    and ([.base_sha,.head_sha,.merge_base_sha] | all(type == "string" and test("^[0-9a-f]{40}$")))
    and (.head_transitions_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and .diff_sha256 == $digest
  ' "$1" >/dev/null || return 1
  printf '%s' "$4" | jq -c --slurpfile metadata "$1" --arg fitted "$fitted" \
    '. + {review_input:($metadata[0] + {reviewed_diff_sha256:$fitted})}'
}

p4b_validate_bound_input() { # bound-verdict metadata-file raw-diff
  local digest
  digest="$(p4b_input_digest "$3")" || return 1
  printf '%s' "$1" | jq -e --slurpfile metadata "$2" --arg digest "$digest" '
    (.review_input | type == "object")
    and ((.review_input | del(.reviewed_diff_sha256)) == $metadata[0])
    and .review_input.diff_sha256 == $digest
    and (.review_input.reviewed_diff_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' >/dev/null
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  [ "$#" -eq 6 ] && [ "$1" = capture ] || exit 2
  shift
  p4b_capture_input "$@"
fi
