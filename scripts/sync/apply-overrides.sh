#!/usr/bin/env bash
# scripts/sync/apply-overrides.sh — override-application library
#
# Sourced by sync-to-downstream.sh's main propagation flow (#168 sub-B).
# Defines two permissive helpers for the per-path decision points where the
# override mechanism feeds into propagation:
#
#   override_should_skip_path  Tests whether a downstream's overrides
#                              file says to skip a given canonical/kit
#                              path. Returns 0 (skip) when matched,
#                              non-zero otherwise. Stores the matched
#                              `reason` in OVERRIDE_SKIP_REASON for
#                              the caller to log.
#
#   override_substitution_for  Looks up an override value for a
#                              templated-path substitution marker.
#                              Returns 0 when an override exists and
#                              writes the value to stdout; non-zero
#                              when the manifest default should win.
#
# These two helpers are read-only against the overrides file. They do NOT
# validate schema (call validate-overrides.sh for that, which is what
# downstream CI does on every PR per #200's design). The contract:
# helpers assume a previously-validated overrides file, treat parse
# errors as "no override" (conservative — safer to over-propagate
# than to silently skip), and never abort the caller.
#
# Sourcing convention:
#
#   # In sync-to-downstream.sh's main script:
#   . "$MERGEPATH_ROOT/scripts/sync/apply-overrides.sh"
#
#   # Then per-consumer, per-path:
#   if override_should_skip_path "$consumer_overrides_file" "$path"; then
#     log "skip $path on $consumer_name: $OVERRIDE_SKIP_REASON"
#     continue
#   fi
#
#   value=$(override_substitution_for "$consumer_overrides_file" "$marker") \
#     && rendered_value="$value" \
#     || rendered_value="$manifest_default"
#
# Separate strict requires-closure helpers below validate effective manifest
# metadata without changing these two permissive reader contracts (#1041).
#
# Globals: OVERRIDE_SKIP_REASON is set to the matched reason when
# override_should_skip_path returns 0.

# --- override_should_skip_path -------------------------------------
#
# Args:
#   $1  Path to the consumer's .sync-overrides.yml. May be empty
#       string or a missing file — both are handled as "no override."
#   $2  The consumer-side target being propagated (`.dest` for templated
#       entries, `.path` for canonical/kit entries).
#
# Returns 0 if the overrides file's skip_paths declares this path,
# non-zero otherwise.

override_should_skip_path() {
  local overrides_file=$1
  local path=$2
  OVERRIDE_SKIP_REASON=""

  if [ -z "$overrides_file" ] || [ ! -f "$overrides_file" ]; then
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    return 1
  fi

  # Use strenv() bracket-lookup rather than string-interpolating $path
  # into a yq filter. CodeRabbit ⚠️ Major on PR #228: a path containing
  # quotes or other yq metacharacters would otherwise break the filter
  # or, worse, alter its semantics. strenv reads the value safely from
  # the environment.
  local reason
  reason=$(YQ_PATH="$path" yq eval '.skip_paths[]? | select(.path == strenv(YQ_PATH)) | .reason' "$overrides_file" 2>/dev/null | head -n 1)
  if [ -n "$reason" ] && [ "$reason" != "null" ]; then
    OVERRIDE_SKIP_REASON="$reason"
    return 0
  fi
  return 1
}

# --- override_substitution_for -------------------------------------
#
# Args:
#   $1  Path to the consumer's .sync-overrides.yml.
#   $2  Substitution marker name (the key under `substitutions:`).
#
# Returns 0 when an override exists; writes the override value to
# stdout. Returns non-zero when no override is present (caller falls
# back to the manifest default).
#
# Multi-line override values are passed through verbatim. The caller
# is responsible for any escaping required by the templating engine.

override_substitution_for() {
  local overrides_file=$1
  local marker=$2

  if [ -z "$overrides_file" ] || [ ! -f "$overrides_file" ]; then
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    return 1
  fi

  # Bracket-lookup with strenv() rather than dot-string-interpolation —
  # marker names can legitimately contain `-`, `.`, or other characters
  # that break yq's dot-path syntax (e.g., `phase-4b.default`). CodeRabbit
  # ⚠️ Major on PR #228 caught this. strenv() reads the marker name from
  # the environment and treats it as a literal map key.
  local has_key
  has_key=$(YQ_MARKER="$marker" yq eval '.substitutions | has(strenv(YQ_MARKER))' "$overrides_file" 2>/dev/null || echo "false")
  if [ "$has_key" != "true" ]; then
    return 1
  fi

  # Substitution entries are structured `{value, reason}` maps per the
  # round 2 schema change (#228; nathanpayne-codex CHANGES_REQUESTED
  # caught that bare-scalar overrides bypassed the audit-trail reason
  # contract). Return only the `.value` field — the `.reason` is for
  # audit / human-readers and is enforced by validate-overrides.sh, not
  # consumed at propagation time.
  #
  # Treat null / empty / missing `.value` as "no override" (return
  # non-zero so the caller falls back to the manifest default).
  # Without this guard, a malformed entry would propagate a literal
  # `null` or empty string into rendered output. The validator
  # rejects such entries on every PR (Rule 7), but this is defensive
  # belt-and-suspenders for already-merged or pre-validated cases.
  # CodeRabbit ⚠️ Major on PR #228 round 4.
  local value
  value=$(YQ_MARKER="$marker" yq eval '.substitutions[strenv(YQ_MARKER)].value' "$overrides_file" 2>/dev/null || true)
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$value"
  return 0
}

# --- Effective manifest requires closure (#1041) -------------------
# These NEW helpers are separate from the two permissive override readers
# above. Load proves the finite metadata shape before flattening it; errors
# are fatal to closure proof, never an empty successful graph. No stdout.
# load MANIFEST OVERRIDES; check CONSUMER [SELECTED_LOGICAL_TARGETS]
# Omitting targets checks every effective entry. Supplying even an empty
# list checks only that selected slice. Return 0 valid, 1 contradiction,
# 2 unreadable/unsupported metadata or unknown consumer. Detail is diagnostic.
override_requires_load() {
  local manifest=$1 overrides=$2
  OVERRIDE_REQUIRES_DETAIL="could not read requires metadata"
  OVERRIDE_REQUIRES_CONSUMERS="" OVERRIDE_REQUIRES_ENTRIES=""
  OVERRIDE_REQUIRES_EDGES="" OVERRIDE_REQUIRES_SKIPS=""
  command -v yq >/dev/null 2>&1 || return 2
  # Validate containers before traversing members, then scalar types before
  # string operations. TSV has no escaping ambiguity: reject control bytes
  # (including NUL, which shell variables discard) and comma-separated
  # consumer names before serializing literal fields.
  yq -e '(tag == "!!map") and ((.consumers | tag) == "!!seq") and ((.paths | tag) == "!!seq")' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '[
    (.consumers[] | select(tag != "!!map")),
    (.paths[] | select(tag != "!!map"))
  ] | length == 0' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '[
    (.consumers[].name | select(tag != "!!str")),
    (.paths[].path | select(tag != "!!str")),
    (.paths[].type | select(. != "canonical" and . != "kit" and . != "templated")),
    (.paths[].consumers | select(tag != "!!seq" and . != "all")),
    (.paths[] | select(has("requires")) | .requires | select(tag != "!!seq")),
    (.paths[] | select(.type == "templated") | .dest | select(tag != "!!str"))
  ] | length == 0' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '[
    (.paths[].consumers | select(tag == "!!seq") | .[] | select(tag != "!!str")),
    (.paths[] | (.requires // [])[] | select(tag != "!!str"))
  ] | length == 0' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '[
    ((.consumers[].name, .paths[].path,
      (.paths[] | select(.type == "templated") | .dest),
      (.paths[] | (.requires // [])[])) | select(test("^[^\x00\t\r\n]+$") == false)),
    ((.consumers[].name, (.paths[].consumers | select(tag == "!!seq") | .[]))
      | select(test("^[^,\x00\t\r\n]+$") == false))
  ] | length == 0' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '(.consumers | map(.name) | unique | length) == (.consumers | length)' "$manifest" >/dev/null 2>&1 || return 2
  OVERRIDE_REQUIRES_CONSUMERS=$(yq -r '.consumers[].name' "$manifest" 2>/dev/null) || return 2
  # Only templated entries own a destination. Ignore arbitrary .dest metadata
  # on canonical/kit entries instead of serializing an unvalidated field.
  OVERRIDE_REQUIRES_ENTRIES=$(yq -r '.paths[] | . as $entry | .path + "\t" + .type + "\t" +
    (.consumers | (select(tag == "!!str") // ("," + join(",") + ","))) + "\t" +
    (($entry.dest | select($entry.type == "templated")) // $entry.path)' "$manifest" 2>/dev/null) || return 2
  OVERRIDE_REQUIRES_EDGES=$(yq -r '.paths[] | .path as $p | (.requires // [])[] | $p + "\t" + .' "$manifest" 2>/dev/null) || return 2
  # Unknown consumer scopes cannot stand in for declared applicability.
  local path type scopes dest scope known name
  while IFS=$'\t' read -r path type scopes dest; do
    [ -n "$path" ] || continue
    [ "$scopes" != all ] || continue
    local -a scope_names=()
    IFS=',' read -r -a scope_names <<< "$scopes"
    for scope in "${scope_names[@]}"; do
      [ -n "$scope" ] || continue
      known=0
      while IFS= read -r name; do
        if [ "$name" = "$scope" ]; then known=1; break; fi
      done <<< "$OVERRIDE_REQUIRES_CONSUMERS"
      [ "$known" -eq 1 ] || return 2
    done
  done <<< "$OVERRIDE_REQUIRES_ENTRIES"
  if [ -n "$overrides" ] && [ -e "$overrides" ]; then
    yq -e '(tag == "!!null") or ((tag == "!!map") and
      ((.skip_paths | tag) == "!!null" or (.skip_paths | tag) == "!!seq"))' "$overrides" >/dev/null 2>&1 || return 2
    yq -e '[(.skip_paths // [])[] | select(tag != "!!map")] | length == 0' "$overrides" >/dev/null 2>&1 || return 2
    yq -e '[(.skip_paths // [])[] | (.path, .reason) | select(tag != "!!str")] | length == 0' "$overrides" >/dev/null 2>&1 || return 2
    yq -e '[(.skip_paths // [])[] | .path | select(test("^[^\x00\t\r\n]+$") == false)] | length == 0' "$overrides" >/dev/null 2>&1 || return 2
    # Same finite skip predicate as override_should_skip_path: a literal
    # target and a nonempty reason. Schema validation remains the validator's job.
    OVERRIDE_REQUIRES_SKIPS=$(yq -r '(.skip_paths // [])[] | select(.reason != "") | .path' "$overrides" 2>/dev/null) || return 2
  fi
  OVERRIDE_REQUIRES_DETAIL=""
  return 0
}

override_requires_check() {
  local consumer=$1 selected=${2-} filtered=0
  [ "$#" -lt 2 ] || filtered=1
  OVERRIDE_REQUIRES_DETAIL="unknown consumer: $consumer"
  local name known=0
  while IFS= read -r name; do
    if [ "$name" = "$consumer" ]; then known=1; break; fi
  done <<< "$OVERRIDE_REQUIRES_CONSUMERS"
  [ "$known" -eq 1 ] || return 2
  local path type scopes dest target skip edge required
  local carrier carrier_type carrier_scopes carrier_dest covered
  while IFS=$'\t' read -r path type scopes dest; do
    [ -n "$path" ] || continue
    case ",$scopes," in *,all,*|*",$consumer,"*) ;; *) continue ;; esac
    if [ "$filtered" -eq 1 ]; then
      known=0
      while IFS= read -r target; do
        if [ "$target" = "$path" ]; then known=1; break; fi
      done <<< "$selected"
      [ "$known" -eq 1 ] || continue
    fi
    target=$path
    [ "$type" != templated ] || target=$dest
    case $'\n'"$OVERRIDE_REQUIRES_SKIPS"$'\n' in *$'\n'"$target"$'\n'*) continue ;; esac
    while IFS=$'\t' read -r edge required; do
      [ "$edge" = "$path" ] || continue
      covered=0
      while IFS=$'\t' read -r carrier carrier_type carrier_scopes carrier_dest; do
        [ -n "$carrier" ] || continue
        if [ "$carrier" != "$required" ]; then
          [ "$carrier_type" = kit ] && [[ "$required" == "${carrier%/}/"* ]] || continue
        fi
        case ",$carrier_scopes," in *,all,*|*",$consumer,"*) ;; *) continue ;; esac
        skip=$carrier
        [ "$carrier_type" != templated ] || skip=$carrier_dest
        case $'\n'"$OVERRIDE_REQUIRES_SKIPS"$'\n' in *$'\n'"$skip"$'\n'*) continue ;; esac
        covered=1
        break
      done <<< "$OVERRIDE_REQUIRES_ENTRIES"
      if [ "$covered" -eq 0 ]; then
        OVERRIDE_REQUIRES_DETAIL="$consumer: $required (required by $path) has no applicable unskipped manifest carrier; remove the required-path skip or also skip the requiring entry"
        return 1
      fi
    done <<< "$OVERRIDE_REQUIRES_EDGES"
  done <<< "$OVERRIDE_REQUIRES_ENTRIES"
  OVERRIDE_REQUIRES_DETAIL=""
  return 0
}
