#!/usr/bin/env bash
# NDJSON audit rendering. Sourced only by sync-to-downstream.sh --audit --json.
# Comparisons, consumer selection, and baseline refresh remain in the engine.
# Contract and evidence limits: specs/sync_audit_json.md.
# Audit flags are read by the sourcing engine.
# shellcheck disable=SC2034

# Keep fleet records private until every selected consumer has completed.
# The engine calls run_audit unconditionally so strict errexit still reaches
# failures inside its functions. The EXIT trap normalizes aborted JSON runs
# to script-error status 2, without changing completed 0/1/3 dispositions.
audit_json_buffer_begin() {
  AJ_BUFFER='' AJ_COMPLETE=0
  trap 'audit_json_buffer_cleanup' EXIT
  AJ_BUFFER=$(mktemp "${TMPDIR:-/tmp}/audit-json-output.XXXXXX") || {
    err "could not allocate audit JSON output buffer"
    return 2
  }
}

audit_json_buffer_cleanup() {
  local status=$?
  [ -z "${AJ_BUFFER:-}" ] || rm -f -- "$AJ_BUFFER" || true
  if [ "${AJ_COMPLETE:-0}" != 1 ]; then exit 2; fi
  return "$status"
}

audit_json_buffer_flush() {
  local records
  # Read and remove the private buffer before publishing. Read/cleanup errors
  # must not expose a syntactically valid but incomplete fleet prefix either.
  records=$(cat -- "$AJ_BUFFER") || {
    err "could not read audit JSON output buffer"
    return 2
  }
  rm -f -- "$AJ_BUFFER" || {
    err "could not remove audit JSON output buffer"
    return 2
  }
  AJ_BUFFER=''
  if [ -n "$records" ]; then
    printf '%s\n' "$records" || { err "could not publish audit JSON output"; return 2; }
  fi
}

audit_json_begin() {
  AJ_NAME=$1 AJ_REPO=$2
  AJ_VISIBILITY=$(AUDIT_CONSUMER="$1" yq -r '.consumers[] | select(.name == strenv(AUDIT_CONSUMER)) | .visibility // "unknown"' "$3") || {
    err "could not read manifest visibility for $1"
    return 2
  }
  AJ_BASELINE=null AJ_BASELINE_INFO=null AJ_PATHS='[]' AJ_PRS=null
  AJ_STATUS=in-sync AJ_ERROR=null
  AJ_HUB_SHA=$(git -C "$MERGEPATH_ROOT" rev-parse --verify HEAD 2>/dev/null || true)
  AJ_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
}

audit_json_emit() {
  jq -cn --arg name "$AJ_NAME" --arg repo "$AJ_REPO" --arg visibility "$AJ_VISIBILITY" \
    --arg status "$AJ_STATUS" --arg hub_sha "$AJ_HUB_SHA" --arg audited_at "$AJ_AT" \
    --argjson baseline "$AJ_BASELINE" --argjson baseline_info "$AJ_BASELINE_INFO" \
    --argjson paths "$AJ_PATHS" --argjson open_sync_prs "$AJ_PRS" --argjson error "$AJ_ERROR" \
    '{schema_version:1,name:$name,repo:$repo,visibility:(if $visibility == "unknown" then null else $visibility end),
      baseline:$baseline,baseline_info:$baseline_info,hub_sha:(if $hub_sha == "" then null else $hub_sha end),
      status:$status,paths:$paths,open_sync_prs:$open_sync_prs,error:$error,audited_at:$audited_at}'
}

audit_json_failure() {
  AJ_STATUS=fetch-error
  AJ_ERROR=$(jq -cn --arg reason "$1" '{source:"consumer",reason:$reason}')
  AUDIT_FETCH_ERROR=1
  audit_json_emit
}

audit_json_baseline() {
  local root=$1 sha ref kind=local-tree refreshed=false dirty=false warnings='[]' default_ref default_sha
  sha=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || true)
  ref=$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || printf 'HEAD')
  if path_is_in_cache "$root"; then
    kind=cache-clone
    default_ref=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [ -z "$default_ref" ] || ref=${default_ref#origin/}
    [ "${AUDIT_NO_REFRESH:-0}" = "1" ] || refreshed=true
  else
    default_ref=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default_sha=$(git -C "$root" rev-parse --verify "${default_ref:-refs/remotes/origin/HEAD}" 2>/dev/null || true)
    if [ -n "$default_ref" ] && [ "$ref" != "${default_ref#origin/}" ]; then
      warnings='["local tree is not on the last-known default branch"]'
    fi
    if [ -n "$default_sha" ] && [ "$sha" != "$default_sha" ]; then
      warnings=$(jq -c '. + ["local HEAD differs from last-fetched default branch"]' <<< "$warnings")
    fi
  fi
  if [ -n "$(git -C "$root" status --porcelain --untracked-files=normal 2>/dev/null || printf 'unreadable')" ]; then dirty=true; fi
  if [ -n "$sha" ]; then AJ_BASELINE=$(jq -cn --arg value "$ref@$sha" '$value'); fi
  AJ_BASELINE_INFO=$(jq -cn --arg ref "$ref" --arg sha "$sha" --arg kind "$kind" \
    --argjson refreshed "$refreshed" --argjson dirty "$dirty" --argjson warnings "$warnings" \
    '{ref:$ref,sha:(if $sha == "" then null else $sha end),kind:$kind,refreshed:$refreshed,dirty:$dirty,warnings:$warnings}')
  # No history-fetch solely to classify direction. Depth-1 caches usually have
  # insufficient provenance; that remains an explicit unverified divergence.
  AJ_SYNC_COMMITS=$(git -C "$root" log -200 --format=%H --grep='^Source: https://github.com/nathanjohnpayne/mergepath/commit/' HEAD 2>/dev/null || true)
}

# A source claim alone is insufficient: verify exact blobs AND modes at its
# consumer sync ancestor, the audited hub HEAD, and consumer HEAD. No clocks.
audit_json_worktree_matches_entry() {
  local file=$1 entry=$2 mode type blob rest actual_mode=100644
  read -r mode type blob rest <<< "$entry"
  [ "$type" = blob ] || return 1
  case "$mode" in 100644|100755) ;; *) return 1 ;; esac
  [ ! -x "$file" ] || actual_mode=100755
  [ "$actual_mode" = "$mode" ] || return 1
  [ "$(git hash-object -- "$file" 2>/dev/null)" = "$blob" ]
}

audit_json_direction() {
  local path=$1 root=$2 sync_sha source_sha source_entry sync_entry hub_entry consumer_entry body
  AJ_DIRECTION='unverified divergence' AJ_PROVENANCE=null
  [ -n "$AJ_HUB_SHA" ] && [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || return 0
  [ -f "$MERGEPATH_ROOT/$path" ] && [ ! -L "$MERGEPATH_ROOT/$path" ] || return 0
  # Evidence describes committed bytes only. Any relevant working-tree edit,
  # including mode changes, makes its direction unverifiable from history.
  git -C "$root" diff --quiet HEAD -- "$path" 2>/dev/null || return 0
  git -C "$MERGEPATH_ROOT" diff --quiet HEAD -- "$path" 2>/dev/null || return 0
  hub_entry=$(git -C "$MERGEPATH_ROOT" ls-tree "$AJ_HUB_SHA" -- "$path" 2>/dev/null || true)
  consumer_entry=$(git -C "$root" ls-tree HEAD -- "$path" 2>/dev/null || true)
  [ -n "$hub_entry" ] && [ -n "$consumer_entry" ] || return 0
  audit_json_worktree_matches_entry "$MERGEPATH_ROOT/$path" "$hub_entry" || return 0
  audit_json_worktree_matches_entry "$root/$path" "$consumer_entry" || return 0
  while IFS= read -r sync_sha; do
    [ -n "$sync_sha" ] || continue
    body=$(git -C "$root" show -s --format=%B "$sync_sha" 2>/dev/null || true)
    source_sha=$(printf '%s\n' "$body" | sed -n 's#^Source: https://github.com/nathanjohnpayne/mergepath/commit/\([0-9a-f]\{40\}\)$#\1#p')
    [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || continue
    git -C "$MERGEPATH_ROOT" merge-base --is-ancestor "$source_sha" "$AJ_HUB_SHA" 2>/dev/null || continue
    source_entry=$(git -C "$MERGEPATH_ROOT" ls-tree "$source_sha" -- "$path" 2>/dev/null || true)
    sync_entry=$(git -C "$root" ls-tree "$sync_sha" -- "$path" 2>/dev/null || true)
    [ -n "$source_entry" ] && [ "$source_entry" = "$sync_entry" ] || continue
    if [ "$hub_entry" = "$source_entry" ] && [ "$consumer_entry" != "$source_entry" ]; then
      AJ_DIRECTION='consumer ahead of hub'
    elif [ "$consumer_entry" = "$source_entry" ] && [ "$hub_entry" != "$source_entry" ]; then
      AJ_DIRECTION='hub ahead'
    else
      # Use the newest verified anchor; an older convenient ancestor cannot
      # override a newer shared baseline where both sides changed.
      return 0
    fi
    AJ_PROVENANCE=$(jq -cn --arg source_sha "$source_sha" --arg sync_sha "$sync_sha" \
      --arg hub_sha "$AJ_HUB_SHA" --arg consumer_sha "$(git -C "$root" rev-parse HEAD)" \
      --arg source_entry "$source_entry" --arg hub_entry "$hub_entry" --arg consumer_entry "$consumer_entry" \
      '{source_sha:$source_sha,sync_sha:$sync_sha,hub_sha:$hub_sha,consumer_sha:$consumer_sha,
        source_entry:$source_entry,hub_entry:$hub_entry,consumer_entry:$consumer_entry}')
    return 0
  done <<< "$AJ_SYNC_COMMITS"
}

audit_json_add_path() {
  local path=$1 class=$2 root=$3 skip_reason=$4 comparison=$5
  [ "$comparison" != ok ] || return 0
  AJ_PROVENANCE=null
  if [ -n "$skip_reason" ]; then
    AJ_DIRECTION='covered by .sync-overrides.yml'
    [ "$AJ_STATUS" != in-sync ] || AJ_STATUS=override-only
  else
    AUDIT_DRIFT_FOUND=1
    if [ "$class" = templated ]; then
      AJ_DIRECTION='re-render differs'
    elif [ "$comparison" = missing ]; then
      AJ_DIRECTION='hub ahead'
    else
      audit_json_direction "$path" "$root"
    fi
    if [ "$AJ_DIRECTION" = 'consumer ahead of hub' ]; then
      AJ_STATUS=ahead
    elif [ "$AJ_STATUS" != ahead ]; then
      AJ_STATUS=drift
    fi
  fi
  AJ_PATHS=$(jq -c --arg path "$path" --arg class "$class" --arg direction "$AJ_DIRECTION" \
    --arg comparison "$comparison" --arg reason "$skip_reason" --argjson provenance "$AJ_PROVENANCE" \
    '. + [{path:$path,class:$class,direction:$direction,comparison:$comparison,
      override_reason:(if $reason == "" then null else $reason end),provenance:$provenance}]' <<< "$AJ_PATHS")
}

audit_json_compare_entry() {
  local path=$1 class=$2 source=$3 dest=$4 name=$5 root=$6 overrides=$7 reason='' target=$1 file leaf listing
  [ "$class" != templated ] || target=$dest
  if override_should_skip_path "$overrides" "$target"; then reason=$OVERRIDE_SKIP_REASON; fi
  case "$class" in
    canonical)
      compare_canonical "$path" "$root"
      audit_json_add_path "$path" "$class" "$root" "$reason" "$REPLY"
      ;;
    kit)
      # Allow consumer-only extras, exactly as compare_kit does. Emit each
      # differing managed file, retaining mixed directions within a kit.
      listing=$(mktemp "${TMPDIR:-/tmp}/audit-json-kit.XXXXXX") || {
        err "could not allocate kit listing for $path"
        return 2
      }
      if ! find "$MERGEPATH_ROOT/${path%/}" -type f -print0 > "$listing"; then
        rm -f "$listing"
        err "could not enumerate hub kit $path"
        return 2
      fi
      if [ ! -s "$listing" ] && [ ! -d "$root/${path%/}" ]; then
        audit_json_add_path "$path" "$class" "$root" "$reason" missing
      fi
      while IFS= read -r -d '' file; do
        leaf="${path%/}/${file#"$MERGEPATH_ROOT/${path%/}/"}"
        compare_canonical "$leaf" "$root"
        audit_json_add_path "$leaf" "$class" "$root" "$reason" "$REPLY"
      done < "$listing"
      rm -f "$listing"
      ;;
    templated)
      compare_templated "$path" "$source" "$dest" "$name" "$root"
      audit_json_add_path "$dest" "$class" "$root" "$reason" "$REPLY"
      ;;
    *) err "unknown path type '$class' for $path"; AUDIT_DRIFT_FOUND=1; AJ_STATUS=drift ;;
  esac
}

# Cursor-loop GraphQL read includes merge state and cannot truncate at 100 PRs.
# Errors, missing fields, malformed pages, or non-advancing cursors are unknown,
# never the empty list that would incorrectly make a sync preview look clear.
audit_json_open_prs() {
  local cursor='' seen='[]' page nodes more page_count=0
  AJ_PRS='[]'
  local query='query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){pullRequests(first:100,after:$cursor,states:OPEN){nodes{number headRefName state mergeStateStatus isDraft} pageInfo{hasNextPage endCursor}}}}'
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 1000 ] || return 1
    local -a args=(api graphql -f "query=$query" -f "owner=${AJ_REPO%%/*}" -f "name=${AJ_REPO#*/}")
    [ -z "$cursor" ] || args+=(-f "cursor=$cursor")
    page=$(sync_read_gh "${args[@]}" 2>/dev/null) || return 1
    jq -e '(.errors // [] | length) == 0 and
      (.data.repository.pullRequests | type == "object") and
      (.data.repository.pullRequests.nodes | type == "array" and all(.[];
        (.number | type == "number" and . > 0 and floor == .) and
        (.headRefName | type == "string") and .state == "OPEN" and
        (.mergeStateStatus | type == "string" and length > 0) and (.isDraft | type == "boolean"))) and
      (.data.repository.pullRequests.pageInfo.hasNextPage | type == "boolean")' >/dev/null <<< "$page" || return 1
    nodes=$(jq -c '[.data.repository.pullRequests.nodes[] | select(.headRefName | startswith("mergepath-sync/")) |
      {number,branch:.headRefName,state:.mergeStateStatus,lifecycle_state:.state,draft:.isDraft}]' <<< "$page")
    AJ_PRS=$(jq -cn --argjson old "$AJ_PRS" --argjson new "$nodes" '$old + $new | unique_by(.number)')
    more=$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<< "$page")
    [ "$more" = true ] || return 0
    cursor=$(jq -er '.data.repository.pullRequests.pageInfo.endCursor | select(type == "string" and length > 0)' <<< "$page") || return 1
    jq -e --arg cursor "$cursor" 'index($cursor) == null' >/dev/null <<< "$seen" || return 1
    seen=$(jq -c --arg cursor "$cursor" '. + [$cursor]' <<< "$seen")
  done
}

audit_json_finish() {
  if ! audit_json_open_prs; then
    AJ_PRS=null AJ_STATUS=fetch-error AUDIT_FETCH_ERROR=1
    AJ_ERROR='{"source":"open_sync_prs","reason":"open sync PR lookup unavailable or incomplete"}'
  fi
  audit_json_emit
}
