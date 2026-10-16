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
  # Buffered cross-file output read by requires_closure_gate.
  # shellcheck disable=SC2034
  OVERRIDE_REQUIRES_ACTIVE_EDGES=""
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
    (.paths[] | select(.type == "templated" and has("dest")) | .dest | select(tag != "!!str"))
  ] | length == 0' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '[
    (.paths[].consumers | select(tag == "!!seq") | .[] | select(tag != "!!str")),
    (.paths[] | (.requires // [])[] | select(tag != "!!str"))
  ] | length == 0' "$manifest" >/dev/null 2>&1 || return 2
  yq -e '[
    ((.consumers[].name, .paths[].path,
      (.paths[] | select(.type == "templated") | (.dest // .path)),
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
  local path _type scopes _dest scope known name
  while IFS=$'\t' read -r path _type scopes _dest; do
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
    # Delegate first-row/first-serialized-line semantics to the unchanged
    # materializer reader, including empty/null reasons and duplicate paths.
    # Query distinct validated targets only; the child shell contains the
    # reader's OVERRIDE_SKIP_REASON output, and publication stays buffered.
    local skip_targets effective_skips skip_path
    skip_targets=$(yq -r '(.skip_paths // [])[] | .path' "$overrides" 2>/dev/null) || return 2
    skip_targets=$(printf '%s\n' "$skip_targets" | LC_ALL=C awk '!seen[$0]++') || return 2
    effective_skips=$(
      while IFS= read -r skip_path; do
        [ -n "$skip_path" ] || continue
        if override_should_skip_path "$overrides" "$skip_path"; then
          printf '%s\n' "$skip_path" || exit 2
        fi
      done <<< "$skip_targets"
    ) || return 2
    OVERRIDE_REQUIRES_SKIPS="$effective_skips"
  fi
  OVERRIDE_REQUIRES_DETAIL=""
  return 0
}

# On success ACTIVE_EDGES is the ordered, selected direct-edge list used by
# the artifact gate too. Never publish a partial list on contradiction/error.
override_requires_check() {
  local consumer=$1 selected=${2-} filtered=0
  [ "$#" -lt 2 ] || filtered=1
  # Buffered cross-file output read by requires_closure_gate.
  # shellcheck disable=SC2034
  OVERRIDE_REQUIRES_ACTIVE_EDGES=""
  OVERRIDE_REQUIRES_DETAIL="unknown consumer: $consumer"
  local name known=0
  while IFS= read -r name; do
    if [ "$name" = "$consumer" ]; then known=1; break; fi
  done <<< "$OVERRIDE_REQUIRES_CONSUMERS"
  [ "$known" -eq 1 ] || return 2
  OVERRIDE_REQUIRES_DETAIL="could not process requires metadata"
  command -v awk >/dev/null 2>&1 || return 2
  local row result rc
  # Typed stdin preserves literal backslashes (awk -v would reinterpret them).
  # Validated metadata has no tabs/newlines; selected targets are opaque whole
  # records, so an arbitrary tab-containing selector cannot select its prefix.
  if result=$({
    printf 'C\t%s\nF\t%s\n' "$consumer" "$filtered"
    while IFS= read -r row; do
      if [ -n "$row" ]; then printf 'P\t%s\n' "$row"; fi
    done <<< "$OVERRIDE_REQUIRES_ENTRIES"
    while IFS= read -r row; do
      if [ -n "$row" ]; then printf 'E\t%s\n' "$row"; fi
    done <<< "$OVERRIDE_REQUIRES_EDGES"
    while IFS= read -r row; do
      if [ -n "$row" ]; then printf 'S\t%s\n' "$row"; fi
    done <<< "$OVERRIDE_REQUIRES_SKIPS"
    while IFS= read -r row; do
      if [ -n "$row" ]; then printf 'T\t%s\n' "$row"; fi
    done <<< "$selected"
  } | LC_ALL=C awk '
    # Length framing, not SUBSEP: validated literal paths can contain SUBSEP.
    function key(a) { return length(a) ":" a }
    function pair(a, b) { return key(a) key(b) }
    function applies(scope) {
      return index("," scope ",", ",all,") || index("," scope ",", "," consumer ",")
    }
    function covered(path, delivery,    i, prefix) {
      # An applicable exact template names a rendered artifact, not its raw
      # source. Keep plain/kit union only for non-templated requirements.
      if (!delivery && template_key[key(path)]) return rendered[key(path)]
      if (delivery ? delivered[key(path)] : logical[key(path)]) return 1
      # Literal component prefixes implement ${carrier%/}/ without regex or
      # path normalization, including already-terminated kit spellings.
      for (i = 1; i <= length(path); i++) {
        if (substr(path, i, 1) != "/") continue
        prefix = substr(path, 1, i)
        if (delivery ? selected_kits[key(prefix)] : kits[key(prefix)]) return 1
      }
      return 0
    }
    {
      kind = substr($0, 1, 1)
      value = substr($0, 3)
      if (substr($0, 2, 1) != "\t") { invalid = 1; next }
      if (kind == "C") consumer = value
      else if (kind == "F") filtered = value + 0
      else if (kind == "P") {
        if (split(value, cell, "\t") != 4) { invalid = 1; next }
        n++; paths[n] = cell[1]; types[n] = cell[2]
        scopes[n] = cell[3]; targets[n] = cell[4]
      } else if (kind == "E") {
        if (split(value, cell, "\t") != 2) { invalid = 1; next }
        count[key(cell[1])]++
        edges[pair(cell[1], count[key(cell[1])])] = cell[2]
      } else if (kind == "S") skipped[key(value)] = 1
      else if (kind == "T") selected[key(value)] = 1
      else invalid = 1
    }
    END {
      if (invalid) exit 2
      for (i = 1; i <= n; i++) {
        if (!applies(scopes[i])) continue
        if (types[i] == "templated") template_key[key(paths[i])] = 1
        if (skipped[key(targets[i])]) continue
        if (types[i] == "templated") rendered[key(paths[i])] = 1
        logical[key(paths[i])] = 1
        if (types[i] == "kit") {
          prefix = paths[i]
          if (substr(prefix, length(prefix), 1) != "/") prefix = prefix "/"
          kits[key(prefix)] = 1
        }
        if (!filtered || selected[key(paths[i])]) {
          delivered[key(targets[i])] = 1
          if (types[i] == "kit") selected_kits[key(prefix)] = 1
        }
      }
      for (i = 1; i <= n; i++) {
        if (!applies(scopes[i]) || !covered(targets[i], 1)) continue
        for (j = 1; j <= count[key(paths[i])]; j++) {
          required = edges[pair(paths[i], j)]
          if (!covered(required, 0)) {
            print "D\t" consumer ": " required " (required by " paths[i] ") has no applicable unskipped manifest carrier; remove the required-path skip or also skip the requiring entry"
            exit 1
          }
          output[++out_count] = paths[i] "\t" required
        }
      }
      print "OK"
      for (i = 1; i <= out_count; i++) print output[i]
    }
  '); then
    # Successful buffered cross-file output; the artifact gate reads it.
    # shellcheck disable=SC2034
    case "$result" in
      OK) OVERRIDE_REQUIRES_ACTIVE_EDGES="" ;;
      OK$'\n'*) OVERRIDE_REQUIRES_ACTIVE_EDGES=${result#*$'\n'} ;;
      *) return 2 ;;
    esac
    OVERRIDE_REQUIRES_DETAIL=""
    return 0
  else
    rc=$?
    if [ "$rc" -eq 1 ] && [[ "$result" == D$'\t'* ]]; then
      OVERRIDE_REQUIRES_DETAIL=${result#*$'\t'}
      return 1
    fi
    return 2
  fi
}
