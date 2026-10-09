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
  if jq -e 'has("wave_audit")' "$3/input.json" >/dev/null; then
    [ "$(p4b_input_digest "$3/pr.diff")" = "$(jq -er '.pr_diff_sha256' "$3/input.json")" ] || return 1
  fi
  p4b_input_transitions "$1" "$2" "$3/current-transitions.json" || return 1
  transition_digest="$(p4b_input_digest "$3/current-transitions.json")" || return 1
  [ "$transition_digest" = "$(jq -er '.head_transitions_sha256' "$3/input.json")" ]
}

# Curated propagation input is regenerated by trusted wave code, never accepted
# as arbitrary caller bytes. Its canary must first pass the live byte verifier
# shipped by #1546; an unavailable verifier refuses this specialized path.
p4b_capture_wave_input() { # repo pr base head request-json input-dir governing-policy
  local repo="$1" pr="$2" base="$3" head="$4" request="$5" dest="$6" policy="$7"
  local scripts_root gh_bin metadata proof source_base source_head historical final digest pr_digest variable
  scripts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  [ -f "$request" ] && [ ! -L "$request" ] && [ -f "$policy" ] || return 1
  jq -e '
    (keys | sort) == ["canonical_base_sha","canonical_head_sha","finalize_historical","historical_end_sha","version"]
    and .version == 1
    and ([.canonical_base_sha,.canonical_head_sha] | all(type == "string" and test("^[0-9a-f]{40}$")))
    and (.historical_end_sha | type == "string" and (. == "" or test("^[0-9a-f]{40}$")))
    and (.finalize_historical | type == "boolean")
    and (.finalize_historical == false or .historical_end_sha == "")
  ' "$request" >/dev/null || return 1
  [ -f "$scripts_root/workflow/verify-live-propagation.sh" ] || return 1
  source_head="$(jq -er .canonical_head_sha "$request")" || return 1
  gh_bin="$(p4b_input_command gh)" || return 1
  metadata="$("$gh_bin" api "repos/$repo/pulls/$pr")" || return 1
  proof="$(printf '%s' "$metadata" | bash "$scripts_root/workflow/verify-live-propagation.sh" \
    "$repo" "$pr" "$head" "$base" "$policy")" || return 1
  printf '%s' "$proof" | jq -e --arg source "$source_head" --arg head "$head" --arg base "$base" \
    '.source_sha == $source and .head_sha == $head and .base_sha == $base' >/dev/null || return 1
  source_base="$(jq -er .canonical_base_sha "$request")" || return 1
  historical="$(jq -r .historical_end_sha "$request")" || return 1
  final="$(jq -r .finalize_historical "$request")" || return 1
  local -a args=("$pr" --repo "$repo" --base "$source_base" --head-sha "$source_head"
    --capture-input-dir "$dest/wave") clean_env=()
  [ -z "$historical" ] || args+=(--historical-end "$historical")
  [ "$final" != true ] || args+=(--finalize-historical)
  for variable in $(compgen -e); do
    case "$variable" in GIT_*|WAVE_AUDIT_*) clean_env+=(-u "$variable") ;; esac
  done
  mkdir "$dest/wave" || return 1
  # Only this verified child may bypass the redundant marker precondition in
  # older trusted wave code. Capture mode itself has no publishing authority.
  env ${clean_env[@]+"${clean_env[@]}"} HOME="$dest/home" XDG_CONFIG_HOME="$dest/home/.config" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    WAVE_AUDIT_REPO_DIR="$(dirname "$scripts_root")" WAVE_AUDIT_MANIFEST_RELPATH=.mergepath-sync.yml \
    WAVE_AUDIT_ORCHESTRATOR="$scripts_root/phase-4b-review.sh" WAVE_AUDIT_LANE_VERIFIED_OK=1 \
    MERGEPATH_REVIEW_POLICY_PATH="$scripts_root/../.github/review-policy.yml" \
    bash "$scripts_root/wave-audit.sh" "${args[@]}" || return 1
  jq -e --slurpfile requested "$request" \
    'del(.manifest_blob,.scope_fingerprint) == $requested[0]' "$dest/wave/scope.json" >/dev/null || return 1
  digest="$(p4b_input_digest "$dest/wave/review.diff")" || return 1
  pr_digest="$(jq -er '.diff_sha256' "$dest/input.json")" || return 1
  mv "$dest/review.diff" "$dest/pr.diff" || return 1
  cp "$dest/wave/review.diff" "$dest/review.diff" || return 1
  jq --slurpfile scope "$dest/wave/scope.json" --arg digest "$digest" --arg pr_digest "$pr_digest" \
    '. + {wave_audit:$scope[0],pr_diff_sha256:$pr_digest,diff_sha256:$digest}' \
    "$dest/input.json" >"$dest/wave-input.json" || return 1
  mv "$dest/wave-input.json" "$dest/input.json" || return 1
  chmod 400 "$dest/review.diff" "$dest/input.json" "$dest/pr.diff" || return 1
  p4b_revalidate_input "$repo" "$pr" "$dest"
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
    ((keys - ["wave_audit","pr_diff_sha256"] | sort) == ["base_sha","diff_sha256","head_sha","head_transitions_sha256","merge_base_sha"])
    and (if has("wave_audit") then
      (.wave_audit | type == "object") and (.pr_diff_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      else (has("pr_diff_sha256") | not) end)
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
  case "${1:-}:$#" in
    capture:6) shift; p4b_capture_input "$@" ;;
    wave-capture:8) shift; p4b_capture_wave_input "$@" ;;
    *) exit 2 ;;
  esac
fi
