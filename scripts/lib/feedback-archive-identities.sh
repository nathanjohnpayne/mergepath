#!/usr/bin/env bash
# Retained archival enrollment is independent of current reviewer standing.
# Callers supply a trusted policy: default-branch producer/relay checkouts or
# accounting's materialized governing base policy. Never use event body claims.

# One eligibility predicate is shared by ordinary lookup and inert record
# validation, so a relay cannot broaden the renderer/accounting source kinds.
FEEDBACK_ARCHIVE_ELIGIBILITY_JQ='
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
  FEEDBACK_ARCHIVE_IDENTITIES=$(printf '%s' "$parsed" | jq -ce '
    .feedback_archive.identities
    | select(type == "array" and length > 0 and length <= 128)
    | select(all(.[];
        (.login | type == "string" and test("^[A-Za-z0-9-]+(\\[bot\\])?$")) and
        (.provider == "codex" or .provider == "coderabbit" or
         .provider == "ghas" or .provider == "reviewer") and
        (.status == "active" or .status == "retired")))
    | select((map(.login | ascii_downcase) | unique | length) == length)
    | select(all(.[]; (.login | ascii_downcase) != "github-actions[bot]"))
  ') || { echo 'feedback-archive: missing, invalid, or ambiguous retained identity registry' >&2; return 2; }
}

# rc 0 = enrolled source, rc 1 = never eligible kind/login, rc 2 = unknown registry.
# Restoration is a separate fixed provenance path, not reviewer enrollment.
feedback_archive_source_provider() {
  local kind="$1" login="$2" result rc=0
  [ -n "${FEEDBACK_ARCHIVE_IDENTITIES:-}" ] || return 2
  case "$kind" in issue-comment|inline|review-body) ;; *) return 2 ;; esac
  [[ "$login" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || return 2
  result=$(printf '%s' "$FEEDBACK_ARCHIVE_IDENTITIES" | jq -er --arg kind "$kind" --arg login "$login" \
    "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'archive_provider(.; $kind; $login)' 2>/dev/null) || rc=$?
  [ "$rc" -ne 4 ] || return 1
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$result"
}

# An inert handoff contains at most one source body (32 chunks) or one restored
# record. Decode only as data; a retained enrollment grants no payload authority.
feedback_archive_validate_records() {
  local handoff="$1"
  jq -e --argjson identities "$FEEDBACK_ARCHIVE_IDENTITIES" "$FEEDBACK_ARCHIVE_ELIGIBILITY_JQ"'
    def eligible($kind; $login):
      [archive_provider($identities; $kind; $login)] | length == 1;
    def payload_ok($p):
      ($p | type == "object") and
      ($p.source_comment_id | type == "number" and . > 0 and floor == .) and
      ($p.source_login | type == "string") and
      eligible(($p.source_kind // "issue-comment"); $p.source_login);
    .archive_records as $records
    | ($records | type == "array" and length <= 32) and
      (if ($records | length) == 0 then true
       elif (.archive_source.login == "github-actions[bot]" and
             .archive_source.kind == "issue-comment") or
            ((has("archive_source") | not) and ($records | length) == 1 and
             ($records[0] | startswith("<!-- mergepath-feedback-archive:v1 ") | not)) then
         ($records | length == 1) and
         all($records[]; [
           if startswith("<!-- mergepath-feedback-archive:v1 ") then
             capture("^<!-- mergepath-feedback-archive:v1 (?<data>[A-Za-z0-9+/=]{1,60000}) -->$")
             | .data | @base64d | fromjson | payload_ok(.)
           elif startswith("<!-- mergepath-feedback-archive:v2 ") then
             capture("^<!-- mergepath-feedback-archive:v2 id=[0-9a-f]{64} part=(?<part>[0-9]+)/(?<total>[0-9]+) data=[A-Za-z0-9+/=]{1,60000} -->$")
             | (.part | tonumber) as $part | (.total | tonumber) as $total
             | $part >= 1 and $part <= $total and $total <= 32
           else test("^<!-- mergepath-feedback-archive-relay:v(1 run=[0-9]+ status=(complete|failed)|2 run=[0-9]+ publisher=[0-9]+ status=complete) -->$") end] | length == 1 and .[0] == true)
       else
         (if ($records[0] | startswith("<!-- mergepath-feedback-archive:v1 ")) then
            if ($records | length) != 1 then error("multiple source bodies") else
              $records[0] | capture("^<!-- mergepath-feedback-archive:v1 (?<data>[A-Za-z0-9+/=]{1,60000}) -->$") | .data
            end
          else
            [$records[] | capture("^<!-- mergepath-feedback-archive:v2 id=(?<id>[0-9a-f]{64}) part=(?<part>[0-9]+)/(?<total>[0-9]+) data=(?<data>[A-Za-z0-9+/=]{1,60000}) -->$")
              | .part |= tonumber | .total |= tonumber] | sort_by(.part)
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
