#!/usr/bin/env bash
# Retained archival enrollment is independent of current reviewer standing.
# Callers supply a trusted policy: default-branch producer/relay checkouts or
# accounting's materialized governing base policy. Never use event body claims.

# One eligibility predicate is shared by ordinary lookup and inert record
# validation, so a relay cannot broaden the renderer/accounting source kinds.
FEEDBACK_ARCHIVE_ELIGIBILITY_JQ='
  def current_archive_roles:
    def current_login($config; $fallback):
      ($config.bot_login // "") | if . == "" then $fallback else . end;
    [ {login:current_login(.codex; "chatgpt-codex-connector[bot]"), provider:"codex"},
      {login:current_login(.coderabbit; "coderabbitai[bot]"), provider:"coderabbit"},
      {login:current_login(.code_scanning; "github-advanced-security[bot]"), provider:"ghas"},
      ((.available_reviewers // [])[] | {login:., provider:"reviewer"}) ]
    | map(.login |= ascii_downcase);
  def archive_provider($identities; $kind; $login):
    $identities[]
    | select((.login | ascii_downcase) == ($login | ascii_downcase))
    | select($kind == "inline" or
        (($kind == "issue-comment" or $kind == "review-body") and
         (.provider == "codex" or .provider == "coderabbit")) or
        ($kind == "review-body" and .provider == "reviewer"))
    | .provider;
'

feedback_archive_registry_load() {
  local policy="$1" parsed
  parsed=$(policy_yaml_to_json "$policy") || return 2
  feedback_archive_registry_from_json "$parsed"
}

feedback_archive_registry_from_json() {
  local parsed="$1"
  FEEDBACK_ARCHIVE_IDENTITIES=$(printf '%s' "$parsed" | jq -ce "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'
    . as $policy | current_archive_roles as $current_roles
    | $policy.feedback_archive.identities
    | select(type == "array" and length > 0 and length <= 128)
    | select(all(.[];
        (.login | type == "string" and test("^[A-Za-z0-9-]+(_[A-Za-z0-9]+|\\[bot\\])?$")) and
        (.provider == "codex" or .provider == "coderabbit" or
         .provider == "ghas" or .provider == "reviewer") and
        (.status == "active" or .status == "retired")))
    | select((map(.login | ascii_downcase) | unique | length) == length)
    | select(all(.[]; (.login | ascii_downcase) != "github-actions[bot]"))
    # Active roles must agree with current provider/reviewer configuration.
    # Retired entries are verified historical roles, never current allowlists.
    | select(all(.[];
        . as $identity | .status == "retired" or
        ([$current_roles[] | select(.login == ($identity.login | ascii_downcase))
          | .provider] | unique) == [$identity.provider]))
  ') || { echo 'feedback-archive: missing, invalid, or ambiguous retained identity registry' >&2; return 2; }
  FEEDBACK_ARCHIVE_CURRENT_ROLES=$(printf '%s' "$parsed" | jq -ce \
    "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'current_archive_roles') || return 2
}

# rc 0 = enrolled source, rc 1 = never eligible kind/login, rc 2 = unknown registry.
# Restoration is a separate fixed provenance path, not reviewer enrollment.
feedback_archive_source_provider() {
  local kind="$1" login="$2" result rc=0
  [ -n "${FEEDBACK_ARCHIVE_IDENTITIES:-}" ] || return 2
  case "$kind" in issue-comment|inline|review-body) ;; *) return 1 ;; esac
  [[ "$login" =~ ^[A-Za-z0-9-]+(_[A-Za-z0-9]+|\[bot\])?$ ]] || return 1
  result=$(printf '%s' "$FEEDBACK_ARCHIVE_IDENTITIES" | jq -er --arg kind "$kind" --arg login "$login" \
    "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'archive_provider(.; $kind; $login)' 2>/dev/null) || rc=$?
  [ "$rc" -ne 4 ] || return 1
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$result"
}

# Bounded classifier candidates are separate from retained source admission.
# Current roles cannot add enrollment or a kind the retained role never owned.
feedback_archive_source_providers() {
  local kind="$1" login="$2" retained
  retained=$(feedback_archive_source_provider "$kind" "$login") || return $?
  printf '%s' "$FEEDBACK_ARCHIVE_CURRENT_ROLES" | jq -ce \
    --arg retained "$retained" --arg kind "$kind" --arg login "$login" \
    "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'
      ([$retained] + [archive_provider(.; $kind; $login)]) | unique
    ' || return 2
}

# An inert handoff contains at most one source body (32 chunks) or one restored
# record. Decode only as data; a retained enrollment grants no payload authority.
feedback_archive_validate_records() {
  # Optional context comes from the relay source resolver AFTER its trusted
  # repository/default-branch binding and handoff tuple check, never the payload.
  local handoff="$1" verified_source_event="${2:-}"
  jq -e --arg verified_source_event "$verified_source_event" --argjson identities "${FEEDBACK_ARCHIVE_IDENTITIES:-[]}" "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'
    def eligible($kind; $login):
      [archive_provider($identities; $kind; $login)] | length == 1;
    def payload_shape_ok($p):
      ($p | type == "object") and
      ($p.source_comment_id | type == "number" and . > 0 and floor == .) and
      ($p.source_login | type == "string" and
        test("^[A-Za-z0-9-]+(_[A-Za-z0-9]+|\\[bot\\])?$")) and
      (($p.source_kind // "issue-comment") | . == "inline" or
        . == "issue-comment" or . == "review-body");
    def payload_ok($p):
      payload_shape_ok($p) and
      eligible(($p.source_kind // "issue-comment"); $p.source_login);
    # Absolute anchors forbid extra lines; a missing match is an error rather
    # than an empty stream that could silently remove a record from the set.
    def exact($pattern):
      [capture($pattern)] | if length == 1 then .[0] else error("invalid record wrapper") end;
    def v1:
      exact("\\A<!-- mergepath-feedback-archive:v1 (?<data>[A-Za-z0-9+/=]{1,60000}) -->\\z") | .data;
    def v2:
      exact("\\A<!-- mergepath-feedback-archive:v2 id=(?<id>[0-9a-f]{64}) part=(?<part>[0-9]+)/(?<total>[0-9]+) data=(?<data>[A-Za-z0-9+/=]{1,60000}) -->\\z")
      | .part |= tonumber | .total |= tonumber;
    .archive_records as $records | has("archive_source") as $explicit_source
    | ($records | type == "array" and length <= 32) and
      all($records[]; type == "string") and
      (if ($records | length) == 0 then true
       elif (.archive_source.login == "github-actions[bot]" and
             .archive_source.kind == "issue-comment") or
            ((has("archive_source") | not) and ($records | length) == 1 and
             $verified_source_event == "issue_comment") then
         # Immutable old producers lack archive_source. Only independently
         # verified default-branch issue-comment context permits that legacy
         # restoration. Present invalid metadata never takes this fallback.
         # Restore an already trusted record independently of current source
         # enrollment only with explicit Actions source metadata. Legacy
         # complete bodies still need enrollment: issue-comment run context
         # alone cannot distinguish a fresh old-producer source body from a
         # restoration. Accounting refuses missing enrollment after restore.
         .event_name == "issue_comment" and
         (if has("archive_source") then
            (.archive_source.id | type == "number" and . > 0 and floor == .)
          else $verified_source_event == "issue_comment" end) and
         ($records | length == 1) and
         ([$records[] |
           if startswith("<!-- mergepath-feedback-archive:v1 ") then
             v1 | @base64d | fromjson | if $explicit_source then payload_shape_ok(.) else payload_ok(.) end
           elif startswith("<!-- mergepath-feedback-archive:v2 ") then
             v2 | .part >= 1 and .part <= .total and .total <= 32 and
               (if .total == 1 then .data | @base64d | fromjson | if $explicit_source then payload_shape_ok(.) else payload_ok(.) end else true end)
           else test("\\A<!-- mergepath-feedback-archive-relay:v(1 run=[0-9]+ status=(complete|failed)|2 run=[0-9]+ publisher=[0-9]+ status=complete) -->\\z") end]
           | length == 1 and .[0] == true)
       else
         (if ($records[0] | startswith("<!-- mergepath-feedback-archive:v1 ")) then
            if ($records | length) != 1 then error("multiple source bodies") else $records[0] | v1 end
          else
            [$records[] | v2] | sort_by(.part)
            | if (map(.id) | unique | length) != 1 or
                 (map(.total) | unique | length) != 1 or .[0].total != length or
                 map(.part) != [range(1; length + 1)] then error("incomplete source body")
              else map(.data) | join("") end
          end | @base64d | fromjson) as $payload
         | payload_ok($payload) and
           (if has("archive_source") then
             eligible(.archive_source.kind; .archive_source.login) and
             $payload.source_login == .archive_source.login and
             ($payload.source_kind // "issue-comment") == .archive_source.kind and
             $payload.source_comment_id == .archive_source.id
            else true end)
       end)
  ' "$handoff" >/dev/null 2>&1 || {
    echo 'feedback-archive: handoff has ineligible, ambiguous, or excessive source records' >&2
    return 2
  }
}
