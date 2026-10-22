#!/usr/bin/env bash
# scripts/sync-labels.sh — reconcile the canonical issue labels across the
# fleet: the mergepath hub plus every consumer in .mergepath-sync.yml.
#
# Source of truth: BOOTSTRAP_LABELS in scripts/bootstrap/github-infra.sh, the
# same `name|color|description` list a bootstrapped repo is seeded with. That
# seeding creates labels once; nothing kept existing repos in step afterwards,
# so names, colours and descriptions drifted (measured 2026-10-21: every repo,
# the hub included). This keeps the canonical subset identical everywhere.
#
# For each repository and each canonical label:
#   missing            -> create it with the canonical colour and description,
#                         unless it is in BOOTSTRAP_DEPRECATED_LABELS
#                         (deprecated labels are corrected, never created)
#   colour or desc off -> update the label in place (colour compared without
#                         regard to case)
# Names match without regard to case, as GitHub matches them; an update keeps
# the live spelling.
#   identical          -> nothing
# Labels outside the canonical list are never touched. Nothing is deleted or
# renamed, and a label is never recreated, so its issue history stays intact.
#
# Usage:
#   scripts/sync-labels.sh [--apply] [--repos r1,r2]
#
#   (default)   dry run: print the plan, write nothing. Exit 0 when every
#               repository already matches, 1 when the plan has changes.
#   --apply     carry the plan out through scripts/gh-as-author.sh. Exit 0
#               when every write succeeded, 3 when any read or write failed.
#   --repos     limit to these short names or owner/name repositories.
#
# Reads use the caller's GH_TOKEN (any identity that can read labels). Writes
# go through the author wrapper, which verifies the author token. Every read
# is a paginated REST call, so this spends no GraphQL budget.
#
# Run it as a sync-wave step after the fan-out PRs merge (see
# docs/agents/propagation-ordering.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="nathanjohnpayne"
HUB="$OWNER/mergepath"
MANIFEST="${SYNC_LABELS_MANIFEST:-$ROOT/.mergepath-sync.yml}"
INFRA="${SYNC_LABELS_INFRA:-$ROOT/scripts/bootstrap/github-infra.sh}"
AS_AUTHOR="${SYNC_LABELS_AS_AUTHOR:-$ROOT/scripts/gh-as-author.sh}"

APPLY=false
REPO_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --repos) REPO_FILTER="${2:?--repos needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync-labels: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "sync-labels: $*" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v gh >/dev/null 2>&1 || die "gh is required"
[ -f "$INFRA" ] || die "canonical label source not found: $INFRA"

# The canonical list, taken from the bootstrap source itself (never a copy):
# only the BOOTSTRAP_LABELS array is evaluated, in a subshell.
CANON=$(bash -c 'eval "$(sed -n "/^BOOTSTRAP_LABELS=(/,/^)/p" "$1")"; printf "%s\n" "${BOOTSTRAP_LABELS[@]}"' _ "$INFRA") \
  || die "could not read BOOTSTRAP_LABELS from $INFRA"
# Deprecated canonical labels are kept in step where present, never created.
# The declaration must exist and evaluate: a missing or broken list would
# otherwise read as "nothing deprecated", and --apply would create every
# deprecated label across the fleet.
grep -qE '^BOOTSTRAP_DEPRECATED_LABELS=\(' "$INFRA" || die "BOOTSTRAP_DEPRECATED_LABELS is not declared in $INFRA"
DEPRECATED=$(bash -c 'set -e; eval "$(grep -E "^BOOTSTRAP_DEPRECATED_LABELS=\(" "$1")"; declare -p BOOTSTRAP_DEPRECATED_LABELS >/dev/null; printf "%s\n" "${BOOTSTRAP_DEPRECATED_LABELS[@]}"' _ "$INFRA") \
  || die "BOOTSTRAP_DEPRECATED_LABELS in $INFRA does not evaluate"
DEPRECATED_JSON=$(printf '%s\n' "$DEPRECATED" | jq -Rnc '[inputs | select(length > 0)]') || die "could not read BOOTSTRAP_DEPRECATED_LABELS"
CANON_JSON=$(printf '%s\n' "$CANON" | jq -Rnc '
  [inputs | select(length > 0)
   | (index("|")) as $a | (.[$a+1:] | index("|")) as $b
   | if $a == null or $b == null then error("malformed spec: \(.)") else . end
   | {name: .[:$a], color: (.[$a+1:$a+1+$b] | ascii_downcase), description: .[$a+2+$b:]}]') \
  || die "the canonical label list is malformed"
[ "$(jq length <<<"$CANON_JSON")" -gt 0 ] || die "the canonical label list is empty"
jq -e 'all(.[]; (.name | length) > 0 and (.color | test("^[0-9a-f]{6}$")) and (.description | length) > 0)' \
  <<<"$CANON_JSON" >/dev/null || die "a canonical label has an empty name, a non-hex colour or an empty description"
# GitHub rejects a label description over 100 characters (HTTP 422), so a
# longer one would fail every write for that label and never converge.
jq -e 'all(.[]; (.description | length) <= 100)' <<<"$CANON_JSON" >/dev/null \
  || die "a canonical label description is over GitHub's 100-character limit"
jq -e --argjson c "$CANON_JSON" 'all(.[]; . as $d | ($c | map(.name) | index($d)) != null)' <<<"$DEPRECATED_JSON" >/dev/null \
  || die "BOOTSTRAP_DEPRECATED_LABELS names a label that is not canonical"

# The fleet: the hub plus every manifest consumer.
command -v yq >/dev/null 2>&1 || die "yq is required to read $MANIFEST"
# The manifest shape is checked before any consumer is read: yq succeeds with
# no output on a document without a consumers list (or with entries lacking
# a repo), which would otherwise shrink the run to the hub alone and report
# every repository as matching.
yq -e '.version == 1 and (.consumers | type) == "!!seq" and (.consumers | length) > 0
       and ([.consumers[] | select((.repo | type) != "!!str"
              or ((.repo // "") | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not))] | length) == 0' \
  "$MANIFEST" >/dev/null 2>&1 \
  || die "$MANIFEST is not a version-1 manifest whose every consumer names an owner/name repo"
CONSUMERS=$(yq -r '.consumers[].repo' "$MANIFEST" 2>/dev/null | sort -u) \
  || die "could not read consumers from $MANIFEST"
REPOS=$(printf '%s\n%s\n' "$HUB" "$CONSUMERS" | awk 'NF && !seen[$0]++')
if [ -n "$REPO_FILTER" ]; then
  wanted=$(printf '%s' "$REPO_FILTER" | tr ',' '\n' | awk -v o="$OWNER" 'NF { print (index($0, "/") ? $0 : o "/" $0) }')
  # Every requested name must be a fleet repository: a typo next to a valid
  # name must not silently shrink the run.
  unknown=$(printf '%s\n' "$wanted" | grep -Fxv -f <(printf '%s\n' "$REPOS") || true)
  [ -z "$unknown" ] || die "--repos names repositories outside the fleet: $(printf '%s' "$unknown" | tr '\n' ' ')"
  REPOS=$(printf '%s\n' "$REPOS" | grep -Fx -f <(printf '%s\n' "$wanted") || true)
  [ -n "$REPOS" ] || die "--repos matched no fleet repository"
fi

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

changes=0 failures=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  # Pinned to github.com, where the author wrapper confines the writes (it
  # refuses --hostname itself), so a GH_HOST pointing elsewhere cannot plan
  # github.com writes from another host's labels.
  live=$(gh api --hostname github.com --paginate "repos/$repo/labels?per_page=100" 2>/dev/null | jq -sc 'add // []') \
    || { echo "  ! $repo: labels unreadable"; failures=$((failures + 1)); continue; }
  plan=$(jq -c --argjson canon "$CANON_JSON" --argjson deprecated "$DEPRECATED_JSON" '
    (map({key: (.name | ascii_downcase), value: .}) | from_entries) as $have
    | [ $canon[] as $c
        | ($have[$c.name | ascii_downcase]) as $h
        | if $h == null then
            (if ($deprecated | index($c.name)) != null then empty else {action: "create", label: $c} end)
          elif (($h.color // "") | ascii_downcase) != $c.color or ($h.description // "") != $c.description
            then {action: "update", label: $c, live_name: $h.name, from: {color: $h.color, description: ($h.description // "")}}
          else empty end ]' <<<"$live")
  n=$(jq length <<<"$plan")
  if [ "$n" = 0 ]; then echo "= $repo: in sync"; continue; fi
  changes=$((changes + n))
  echo "~ $repo: $n change(s)"
  while IFS= read -r step; do
    # GitHub matches label names without regard to case, so an update goes
    # to the live spelling, which is kept (a label is never renamed).
    action=$(jq -r .action <<<"$step"); name=$(jq -r '.live_name // .label.name' <<<"$step")
    color=$(jq -r .label.color <<<"$step"); desc=$(jq -r .label.description <<<"$step")
    if [ "$action" = create ]; then
      echo "    create $name ($color)"
    else
      echo "    update $name: $(jq -r --arg c "$color" --arg d "$desc" '[ (if (.from.color | ascii_downcase) != $c then "color \(.from.color) -> \($c)" else empty end),
                                                                (if .from.description != $d then "description" else empty end) ] | join(", ")' <<<"$step")"
    fi
    [ "$APPLY" = true ] || continue
    # A materialized payload file: the wrapper re-execs gh, and a process
    # substitution descriptor is not guaranteed to survive that.
    body_file=$(mktemp "${TMPDIR:-/tmp}/sync-labels.XXXXXX") || { failures=$((failures + 1)); continue; }
    if [ "$action" = create ]; then
      jq -nc --arg n "$name" --arg c "$color" --arg d "$desc" '{name:$n,color:$c,description:$d}' >"$body_file"
      "$AS_AUTHOR" -- gh api "repos/$repo/labels" --method POST --input "$body_file" >/dev/null 2>&1 \
        || { echo "      ! create failed"; failures=$((failures + 1)); }
    else
      jq -nc --arg c "$color" --arg d "$desc" '{color:$c,description:$d}' >"$body_file"
      "$AS_AUTHOR" -- gh api "repos/$repo/labels/$(urlencode "$name")" --method PATCH --input "$body_file" >/dev/null 2>&1 \
        || { echo "      ! update failed"; failures=$((failures + 1)); }
    fi
    rm -f "$body_file"
  done < <(jq -c '.[]' <<<"$plan")
done <<<"$REPOS"

if [ "$APPLY" = true ]; then
  [ "$failures" -eq 0 ] || { echo "sync-labels: $failures read/write failure(s)" >&2; exit 3; }
  echo "sync-labels: applied $changes change(s)"
  exit 0
fi
[ "$failures" -eq 0 ] || exit 3
[ "$changes" -eq 0 ] && { echo "sync-labels: every repository matches the canonical labels"; exit 0; }
echo "sync-labels: $changes change(s) planned (dry run; rerun with --apply)"
exit 1
