#!/usr/bin/env bash
# Recompute lane eligibility from trusted code and immutable Git objects.
# Usage: REPO PR FULL_HEAD FULL_BASE GOVERNING_POLICY; live PR JSON on stdin.
set -euo pipefail
repo=${1:-} pr=${2:-} head=${3:-} base=${4:-} policy=${5:-}
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || exit 2
[[ "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ && "$base" =~ ^[0-9a-f]{40}$ ]] || exit 2
[ -f "$policy" ] || exit 2
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
metadata=$(cat)
printf '%s' "$metadata" | jq -e --argjson pr "$pr" --arg head "$head" --arg base "$base" '
  .number == $pr and .head.sha == $head and .base.sha == $base
  and (.head.ref | type == "string") and (.user.login | type == "string")
' >/dev/null || exit 2
config=$(ruby -rjson -ryaml -e 'p=YAML.safe_load(File.read(ARGV[0]), aliases: false); abort "policy must be an object" unless p.is_a?(Hash); puts JSON.generate(p)' "$policy") || exit 2
enabled=$(jq -r 'if .propagation_prs.enabled == null then true else .propagation_prs.enabled end' <<<"$config")
case "$enabled" in false) exit 1 ;; true) ;; *) exit 2 ;; esac
prefix=$(jq -er '.propagation_prs.branch_prefix // "mergepath-sync/" | select(type == "string" and length > 0)' <<<"$config") || exit 2
author=$(jq -er '.author_identity | select(type == "string" and length > 0)' <<<"$config") || exit 2
ref=$(jq -r '.head.ref' <<<"$metadata")
[ "$(jq -r '.user.login' <<<"$metadata")" = "$author" ] || exit 1
[[ "$ref" == "$prefix"* ]] || exit 1
key=${ref#"$prefix"}
if [[ "$key" =~ ^sync-all-([0-9a-f]{7,40})-[0-9a-f]{12}$ ]]; then
  source_key=${BASH_REMATCH[1]}
elif [[ "$key" =~ ^sync-all-([0-9a-fA-F]{7,40})$ ]]; then
  source_key=${BASH_REMATCH[1]}
else
  source_key=$key
fi
[[ "$source_key" =~ ^[0-9a-fA-F]{7,40}$ ]] || exit 1
git_bin=$(command -v git) gh_bin=$(command -v gh)
case "$git_bin:$gh_bin" in /*:/*) ;; *) exit 2 ;; esac
case "$gh_bin" in *"'"*|*'\'*) exit 2 ;; esac
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
chmod 700 "$task_dir"
mkdir "$task_dir/home"
# Fresh repositories, no inherited Git redirects, configuration or hooks.
git_environment=()
for variable in $(compgen -e); do
  case "$variable" in GIT_*) git_environment+=(-u "$variable") ;; esac
done
git_environment+=(HOME="$task_dir/home" XDG_CONFIG_HOME="$task_dir/home/.config"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=)
git_isolated() {
  env -u GITHUB_TOKEN "${git_environment[@]}" "$git_bin" -c core.hooksPath=/dev/null -c http.extraHeader= "$@"
}
# Canonical source is public and data-only. The verifier executes from root,
# never from this runtime clone or from the consumer's proposed tree.
git_isolated -c credential.helper= clone --quiet --filter=blob:none --no-checkout \
  https://github.com/nathanjohnpayne/mergepath.git "$task_dir/canonical" || exit 2
source_sha=$(git_isolated -C "$task_dir/canonical" rev-parse --verify "$source_key^{commit}") || exit 1
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
git_isolated -C "$task_dir/canonical" checkout --quiet --detach "$source_sha" || exit 2
git_isolated init --quiet "$task_dir/consumer" || exit 2
git_isolated -C "$task_dir/consumer" remote add origin "https://github.com/$repo.git" || exit 2
git_isolated -C "$task_dir/consumer" -c credential.helper= \
  -c "credential.helper=!'$gh_bin' auth git-credential" \
  fetch --quiet --no-tags --no-recurse-submodules -- "https://github.com/$repo.git" "$base" "$head" || exit 2
result=0
env -u MERGEPATH_CONSUMER "${git_environment[@]}" bash "$root/verify-propagation-pr.sh" \
  "$task_dir/canonical" "$task_dir/consumer" "$base" "$head" "$source_sha" || result=$?
case "$result" in 0) ;; 1) exit 1 ;; *) exit 2 ;; esac
# The proof applies only to the caller's still-live pair.
current=$("$gh_bin" api "repos/$repo/pulls/$pr") || exit 2
printf '%s' "$current" | jq -e --arg head "$head" --arg base "$base" \
  '.head.sha == $head and .base.sha == $base' >/dev/null || exit 2
