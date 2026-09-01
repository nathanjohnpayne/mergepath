# scripts/lib/branch-requirements.sh
#
# Resolve the required status checks that actually gate merges on a branch,
# from a token that has NO `Administration:read` (nathanjohnpayne/mergepath#1064,
# subsuming #1063).
#
# ─────────────────────────────────────────────────────────────────────
# The defect this closes
# ─────────────────────────────────────────────────────────────────────
#
# `scripts/codex-review-check.sh` gate (a) read the required-check list from
# the REST branch-protection endpoint:
#
#     gh api repos/$REPO/branches/$BRANCH/protection/required_status_checks
#
# That endpoint needs `Administration:read`, and GitHub HIDES the resource
# rather than admitting a permission denial — an unprivileged token gets
# **404, not 403**. Gate (a) read that 404 as "no required checks are
# configured", imposed no filter, and passed unconditionally. Measured live on
# nathanjohnpayne/nathanpaynedotcom, same endpoint, same moment:
#
#     reviewer PAT (write scope) → {"message":"Not Found","status":"404"}
#     author  PAT (admin scope)  → 7 contexts, strict: true
#
# Every caller in the fleet runs unprivileged. Agents invoke this script under
# a reviewer PAT, and `.github/workflows/auto-clear-blocking-labels.yml` runs
# it with `GH_TOKEN: ${{ secrets.REVIEWER_ASSIGNMENT_TOKEN }}` — a reviewer PAT
# too — while NOT skipping gate (a) the way merge-clearance-gate.yml does. So
# gate (a) evaluated an empty required set on every path it is actually used
# on, and a genuinely red required check went unnoticed. That is the fail-open
# #465 set out to close, reopened through the one door #465's 403 arm does not
# cover.
#
# ─────────────────────────────────────────────────────────────────────
# Why the fix is a different READ, not a different DECISION
# ─────────────────────────────────────────────────────────────────────
#
# #1064 framed this as needing "a privileged read CI can reach", and the #1061
# attempt that was reverted in 2e5da40 tried exactly that: retry the same REST
# endpoint under `OP_PREFLIGHT_AUTHOR_PAT`. It cannot work — auto-clear CI has
# no author PAT, and `preflight_require_token` returns early when `GH_TOKEN` is
# already set, so the retry is unreachable dead code there. What was left was a
# choice between two bad options: fail closed on an unreadable list (which
# treats every optional and stale-red rollup entry as required, blocking PRs
# fleet-wide) or keep failing open.
#
# That dilemma was false. The REST endpoint is not the only surface carrying
# this data, and the other two are readable by a PLAIN WRITE-SCOPED TOKEN:
#
#   1. GraphQL `repository.ref.refUpdateRule.requiredStatusCheckContexts`
#      — CLASSIC branch protection, which is what the whole fleet uses today.
#   2. REST `repos/{owner}/{repo}/rules/branches/{branch}`
#      — repository RULESETS, the modern model.
#
# `scripts/merge-clearance-gate.sh` already reads both, from CI, under the same
# reviewer token, for its own enforcement probe — this lib generalises that
# proven pair rather than inventing a surface. Measured live while writing
# this, with the reviewer PAT that 404s on REST above:
#
#     nathanpaynedotcom@main → 7 contexts (exactly the admin-visible list)
#     mergepath@main         → 6 contexts
#
# So gate (a) does not need an admin token, a new secret, or a privilege
# grant. It needed a different query.
#
# ─────────────────────────────────────────────────────────────────────
# Why both surfaces, and why the union
# ─────────────────────────────────────────────────────────────────────
#
# They are not alternatives. GitHub enforces classic protection and every
# applicable ruleset SIMULTANEOUSLY, so the effective requirement is the UNION
# of the two lists. Classic protection does not surface on the rulesets
# endpoint and vice versa: verified live on mergepath@main, whose classic
# contexts are non-empty while `rules/branches/main` returns `[]`. Reading
# either alone and stopping there under-reports on a repo that uses the other.
#
# Both surfaces are scoped to rules enforced on the VIEWER, and that is a
# hazard rather than a comfort. An earlier revision of this comment argued it
# was safe because a bypass actor can only HIDE a rule, making the resolved
# list a subset, which can only make gate (a) scrutinise fewer checks and never
# newly block a merge GitHub would allow. That is sound for over-restriction
# and wrong for what this gate is for: a hidden requirement is a context gate
# (a) never checks, which is the same fail-open the lib exists to close,
# arriving through the reader instead of the endpoint. It matters concretely
# here because the fleet reviews under one identity and merges under another,
# so a ruleset bypassing the reviewer can still bind the merger.
#
# The rulesets response is therefore used only when it can be PROVEN complete —
# see the completeness probe in br_required_checks, which reads `/rulesets` (a
# configuration listing, not an actor-scoped evaluation) and accepts the
# response only when no active ruleset has any bypass actor. The classic
# surface carries the same caveat in principle; in practice
# `refUpdateRule.requiredStatusCheckContexts` reports the branch rule rather
# than a per-actor evaluation, and no reader-independent cross-check for it
# exists below `Administration:read`.
#
# ─────────────────────────────────────────────────────────────────────
# The tri-state, and why "unknown" is not "empty"
# ─────────────────────────────────────────────────────────────────────
#
# The whole bug was one conflation: "I read the config and it requires
# nothing" and "I could not read the config" produced the same empty list and
# therefore the same decision. This helper never merges them. `state` is:
#
#   known    BOTH surfaces answered. `contexts` is their union, and MAY
#            legitimately be empty (an approvals-only branch really does
#            require no status checks).
#   unknown  at least one surface did not answer, so the union could not be
#            established. `contexts` is empty because nothing usable was
#            learned, and a caller must NOT read that as "nothing required".
#
# Both surfaces are required for `known` because the requirement IS the union.
# One surface answering `[]` says nothing about what the other would have
# said, so acting on a half-read reintroduces the fail-open one level up: a
# transient GraphQL failure alongside an empty `rules/branches` would read as
# known-and-empty and clear a red classic required check. Each read is retried
# once before being given up on, so a single blip does not reach this.
#
# `partial` marks the half-read case as a DIAGNOSTIC only — it tells an
# operator a half-outage from a total one — and never licenses acting on the
# list. `surfaces` and `errors` record who answered and why the others did not.
#
# ─────────────────────────────────────────────────────────────────────
# Contract
# ─────────────────────────────────────────────────────────────────────
#
#   br_urlencode_branch_path <branch>
#     Percent-encode a branch name for interpolation into an API path.
#
#   br_required_checks <owner/repo> <branch>
#     Print ONE JSON object and return 0:
#       { "state": "known"|"unknown",
#         "partial": true|false,
#         "contexts": [ "<check name>", ... ],   # sorted, deduped
#         "requirements": [ { "context": "<name>",
#                             "app_id": "<id>"|null }, ... ],
#         "surfaces": [ "classic", "rulesets" ], # the ones that ANSWERED
#         "errors":   [ "<surface>: <message>", ... ] }
#
#     `contexts` is the deduped name list, useful for reporting. Anything
#     DECIDING whether a branch is satisfied should read `requirements`, which
#     keeps one entry per rule: GitHub evaluates rules independently, so one
#     context can be pinned to app A by one ruleset and accepted from any
#     producer by another, and only the uncollapsed list preserves that.
#     `app_id: null` means any producer satisfies the rule.
#     Never returns non-zero for an unreadable config — an unreadable config
#     is a RESULT (`unknown`), not a failure of the helper. Callers branch on
#     `.state`, so a helper that exited would force every caller to duplicate
#     the tri-state in exit codes.
#
# Note on a nonexistent branch: `rules/branches/{branch}` answers 200 `[]` for
# ANY branch name (verified live) and cannot distinguish "no rules apply here"
# from "here is nowhere". On its own that would be a fabricated empty list. It
# is not one, because the classic surface refuses to make the claim — it
# reports the ref as not found and contributes nothing — and a result needs
# BOTH surfaces to be `known`. So a nonexistent branch resolves to `unknown`,
# which is the honest answer.
#
# Requires: gh, jq. Bash 3.2 portable (no associative arrays, no mapfile).

# Percent-encode a branch name for interpolation into an API path.
#
# `gh api` passes the path through verbatim, so a branch name carrying a
# character that is legal in a git ref but structural in a URL corrupts the
# request rather than 404ing honestly: `#` truncates everything after it as a
# fragment, `%` is read as the start of an escape, and `?` starts a query
# string. Each silently addresses a DIFFERENT branch, or none — and an empty
# result is indistinguishable from "nothing required", which is precisely the
# conflation this lib exists to remove.
#
# Slashes are the one thing that must NOT be encoded: GitHub addresses a
# hierarchical branch name (`release/1.0`) with literal separators in these
# routes, so encoding `/` as %2F would break the common case to guard the rare
# one. Each segment is encoded on its own and the segments rejoined. jq's
# `@uri` does the per-segment work — correct for UTF-8, which a hand-rolled
# byte loop is not — and jq is already a hard dependency of every caller.
#
# This is the promoted copy of the definition that lived only in
# scripts/audit-branch-protection.sh, which is hub-only and so could not be
# reused by the propagated scripts that need it (#1063).
br_urlencode_branch_path() {
  jq -rn --arg s "${1-}" '$s | split("/") | map(@uri) | join("/")'
}

# Run a read once, and once more after a pause if it fails.
#
# Both surfaces must answer for the result to be usable (see the tri-state
# note above), so a single transient blip on either one would otherwise
# degrade the whole resolution to `unknown` and put gate (a) on the
# fail-closed path. One retry absorbs the common case — a rate-limit tick or
# a 5xx on one of two independent endpoints — without pretending to be a
# general retry framework; a persistent failure still resolves to `unknown`,
# which is the honest answer.
#
# BR_RETRY_SLEEP exists so the offline suites do not pay the pause for the
# failure cases they deliberately provoke.
# Each attempt stdout is captured SEPARATELY and only the successful attempt is
# emitted. `gh api` writes its JSON HTTP-error body to STDOUT (documented at
# length in scripts/lib/gh-api-scalar.sh), so a naive `cmd || cmd` streams the
# error object and then the good document into one pipe. The classic parser
# would see an error object followed by a GraphQL response and resolve the ref
# as not-found; the rulesets parser would reject the mixed object/array stream.
# The retry would then be unable to recover from the ordinary transient HTTP
# failure it exists for, and gate (a) would take its fail-closed path anyway.
#
# stderr is deliberately NOT captured — callers redirect it themselves to
# collect the diagnostic for the `errors` array.
_br_retry() {
  local attempt_out
  if attempt_out="$("$@")"; then
    printf '%s' "$attempt_out"
    return 0
  fi
  sleep "${BR_RETRY_SLEEP:-2}"
  if attempt_out="$("$@")"; then
    printf '%s' "$attempt_out"
    return 0
  fi
  return 1
}

# Resolve the required status checks enforced on <branch> of <owner/repo>.
# See the contract block above for the emitted shape.
br_required_checks() {
  local repo="${1-}"
  local branch="${2-}"
  local owner name branch_enc
  local classic_out rulesets_out errfile
  local classic_ctx='[]' rulesets_ctx='[]'
  local surfaces='[]' errors='[]'
  local classic_ok=0 rulesets_ok=0
  local ref_seen

  # Emit a well-formed `unknown` for a malformed call rather than a bare
  # failure: a caller that mis-invokes this must land on the conservative
  # branch, not on an empty string it might then treat as "nothing required".
  if [ -z "$repo" ] || [ -z "$branch" ] || [ "${repo#*/}" = "$repo" ]; then
    jq -nc --arg r "$repo" --arg b "$branch" \
      '{state:"unknown", partial:false, contexts:[], surfaces:[],
        errors:["args: expected <owner/repo> <branch>, got repo=\($r) branch=\($b)"]}'
    return 0
  fi

  owner="${repo%%/*}"
  name="${repo##*/}"
  branch_enc="$(br_urlencode_branch_path "$branch")"
  errfile="$(mktemp)"

  # ── Surface 1: classic branch protection, via GraphQL.
  #
  # `refUpdateRule` is the viewer-scoped projection of classic protection and,
  # unlike the REST protection endpoint, needs no Administration:read.
  #
  # The ref is selected by its FULLY QUALIFIED name. `qualifiedName` also
  # accepts a short name, but a branch and a tag can share one, and the tag
  # would win for some inputs — `refs/heads/` is unambiguous. The branch is
  # interpolated RAW here (not percent-encoded): this is a GraphQL variable
  # carried in the request BODY, not a URL path segment, so encoding it would
  # look for a branch whose name literally contains `%23`.
  # `-f`, NOT `-F`. `gh api -F` applies magic type conversion, so a repository
  # or owner whose name is numeric — or a ref segment that is literally `true`,
  # `false` or `null` — is sent as a JSON number/boolean/null against a
  # `String!` variable and the query hard-fails on EVERY invocation for that
  # repo. Measured: `-F name=12345` → "Could not coerce value 12345 to String";
  # `-f name=12345` resolves normally. `-f` sends every value as a raw string,
  # which is what all three variables are declared as.
  if classic_out="$(_br_retry gh api graphql \
      -f query='query($owner:String!,$name:String!,$qualifiedName:String!){
        repository(owner:$owner,name:$name){
          ref(qualifiedName:$qualifiedName){
            refUpdateRule{ requiredStatusCheckContexts }
          }
        }
      }' \
      -f owner="$owner" -f name="$name" -f qualifiedName="refs/heads/$branch" \
      2>"$errfile")"; then
    # A 200 can still carry a GraphQL `errors` array with a null data field,
    # and `gh` does not always exit non-zero for it. Treat any errors array as
    # a failed read: a partial response would under-report the list, and this
    # surface's whole value is that its list is trustworthy.
    if [ -n "$(printf '%s' "$classic_out" | jq -r '(.errors // []) | if length > 0 then .[0].message else "" end' 2>/dev/null)" ]; then
      errors="$(printf '%s' "$errors" | jq -c --arg m "$(printf '%s' "$classic_out" | jq -r '.errors[0].message' 2>/dev/null)" '. + ["classic: graphql error: \($m)"]')"
    else
      # Distinguish "the ref was observed and carries no protection rule"
      # (a real, usable answer: nothing is required by the classic surface)
      # from "the ref itself came back null" (the branch was not seen at all,
      # so NOTHING was learned and claiming an empty list would be the same
      # fabrication this lib exists to prevent).
      ref_seen="$(printf '%s' "$classic_out" | jq -r 'if .data.repository.ref == null then "no" else "yes" end' 2>/dev/null || echo "no")"
      if [ "$ref_seen" = "yes" ]; then
        # Validate the WHOLE array rather than filtering it. Dropping a
        # non-string entry and marking the surface readable would return an
        # incomplete union: if that entry named a required context, gate (a)
        # would stop scrutinising it and clear. An unexpected shape means the
        # surface was not understood, which is the same as not having read it —
        # the fail-closed treatment the ruleset payloads already get.
        if classic_ctx="$(printf '%s' "$classic_out" | jq -c '
            (.data.repository.ref.refUpdateRule.requiredStatusCheckContexts // []) as $ctx
            | if ($ctx | type) != "array"
              then error("requiredStatusCheckContexts is not an array (\($ctx | type))")
              elif ($ctx | map(select(type != "string")) | length) > 0
              then error("requiredStatusCheckContexts carries \($ctx | map(select(type != "string")) | length) non-string entry/entries")
              else $ctx
              end' 2>"$errfile")"; then
          classic_ok=1
        else
          classic_ctx='[]'
          errors="$(printf '%s' "$errors" | jq -c --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["classic: \($m)"]')"
        fi
      else
        errors="$(printf '%s' "$errors" | jq -c '. + ["classic: ref not found in the GraphQL response; nothing learned about classic protection"]')"
      fi
    fi
  else
    errors="$(printf '%s' "$errors" | jq -c --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["classic: \($m)"]')"
  fi

  # ── Surface 2: repository rulesets, via REST.
  #
  # `--paginate` is load-bearing: this endpoint pages at 30 applicable rules,
  # and stacked rulesets can push a `required_status_checks` rule onto page 2.
  # A truncated first page is INDISTINGUISHABLE from an absent rule, so the
  # omission would silently drop contexts instead of announcing itself.
  #
  # `--paginate` emits one JSON array per page, so the filter slurps (`-s`)
  # and concatenates with `add`; `objects` keeps a non-object page element (an
  # error envelope on a partial-failure page) from hard-erroring mid-stream.
  #
  # A branch with no rulesets answers `[]` with HTTP 200 — verified live —
  # which is a successful read of "no ruleset requirements", not a failure.
  if rulesets_out="$(_br_retry gh api --paginate "repos/$repo/rules/branches/$branch_enc" 2>"$errfile")"; then
    if rulesets_ctx="$(printf '%s' "$rulesets_out" | jq -c -s '
        # Every page must be the documented ARRAY. A 2xx carrying a JSON
        # OBJECT instead — an error envelope — would otherwise pass silently:
        # `add` yields that object, `.[]?` then iterates its VALUES, `objects`
        # discards the scalar ones, and the filter returns `[]` with exit 0.
        # The surface would be marked readable-and-empty on the strength of an
        # error body, which is the conflation this lib exists to remove. jq
        # `error` exits non-zero, so the caller records it as an unread surface.
        # At least one page must have arrived. `gh api --paginate` can exit 0
        # having emitted nothing — an anomalous empty 2xx — and `jq -s` then
        # slurps `[]`, which the page-type check accepts vacuously and
        # `add // []` turns into a readable-and-empty surface. Nothing was
        # read, so nothing may be concluded: this is the same absence-versus-
        # inability-to-look conflation as the 404, one layer down.
        if length == 0
        then error("rules/branches returned no pages at all")
        else .
        end
        | if (map(type != "array") | any)
        then error("rules/branches returned a non-array page (\(map(type) | unique | join(",")))")
        else .
        end
        | (add // [])
        # A rule that DECLARES itself a required-status-checks rule must carry
        # the documented payload. Checking only the page type is not enough:
        # for `{"type":"required_status_checks","parameters":{}}` the
        # `.parameters.required_status_checks[]?` traversal yields nothing and
        # the surface is recorded as readable with an INCOMPLETE list, so a
        # genuinely required context silently stops being scrutinised. Same
        # conflation as a non-array page, one level down — an unparseable rule
        # is an unread surface, not an empty one.
        | (map(select(objects | .type == "required_status_checks"))
           | map(select(
               ((.parameters | type) != "object")
               or ((.parameters.required_status_checks | type) != "array")
               or ((.parameters.required_status_checks
                    | map(select((.context | type) != "string")) | length) > 0)
             ))) as $malformed
        | if ($malformed | length) > 0
          then error("rules/branches returned \($malformed | length) malformed required_status_checks rule(s)")
          else .
          end
        # Emitted as {context, app_id} pairs, not bare names. Rulesets expose
        # the producing app as `integration_id`, and a caller checking whether
        # every requirement has REPORTED needs that: when one context is
        # required from two apps and only one has reported, the name is present
        # while a requirement is still outstanding. `app_id` is null when the
        # rule accepts the context from any producer.
        | [ .[]? | objects
            | select(.type == "required_status_checks")
            | .parameters.required_status_checks[]?
            | { context: .context,
                app_id: (if .integration_id == null then null else (.integration_id | tostring) end) } ]' 2>"$errfile")"; then
      rulesets_ok=1
    else
      rulesets_ctx='[]'
      errors="$(printf '%s' "$errors" | jq -c --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["rulesets: unparseable response: \($m)"]')"
    fi
  else
    errors="$(printf '%s' "$errors" | jq -c --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["rulesets: \($m)"]')"
  fi

  # ── Completeness probe for surface 2.
  #
  # `rules/branches` returns the rules enforced on the REQUESTING identity. This
  # fleet reviews under one identity and merges under another by design, so a
  # ruleset that lists the reviewer among its `bypass_actors` while still
  # binding the merging author is simply absent from the response above. The
  # resolver would then report `known` with that requirement missing, and gate
  # (a) would never scrutinise the context — the same fail-open this lib exists
  # to close, arriving through the reader instead of the endpoint.
  #
  # An earlier revision argued viewer-scoping was safe because it can only ever
  # HIDE a rule, making the list a subset. That is sound for over-restriction
  # and wrong here: a hidden requirement is one gate (a) never checks.
  #
  # So the response is used only when it can be PROVEN complete. `/rulesets` is
  # a configuration listing rather than an actor-scoped evaluation, and a
  # ruleset with no bypass actors cannot be hidden from anybody — so if every
  # active ruleset has an empty `bypass_actors`, nothing was withheld from this
  # reader and the union stands. Anything else, including a ruleset whose
  # detail cannot be read, leaves completeness unproven and the surface unread.
  #
  # This deliberately avoids ref-pattern matching. Whether a ruleset targets
  # THIS branch does not matter to the question being asked: if no ruleset
  # anywhere can be bypassed, no rule can have been hidden from this response.
  # Ref matching would need the Ruby glob translation
  # scripts/audit-branch-protection.sh carries, and getting it subtly wrong
  # fails open in exactly the direction this probe exists to prevent.
  if [ "$rulesets_ok" -eq 1 ]; then
    if rulesets_meta="$(_br_retry gh api --paginate "repos/$repo/rulesets" 2>"$errfile")"; then
      # BRANCH-targeted and ACTIVE only.
      #
      # A tag ruleset cannot contribute to `rules/branches/<branch>` and cannot
      # hide a branch status-check requirement, so counting one would mark the
      # surface unknown — and, because that state is itself blocking, would
      # permanently stop gate (a) clearing on a repo whose only bypassable
      # ruleset governs tags. `target` is a field on the listing, so this costs
      # no ref-pattern matching: it distinguishes what a ruleset governs, not
      # which refs it names.
      # The inventory gets the same shape validation as the rule read above,
      # and for the same reason: an inventory that exits 0 having emitted
      # nothing, or a 2xx carrying an object, both slurp to something whose
      # `objects` traversal yields no active rulesets. That would read as
      # "nothing can be bypassed" and certify the viewer-scoped response as
      # complete on the strength of a response nobody parsed — the completeness
      # proof would be exactly as empty as the evidence for it.
      if active_rulesets="$(printf '%s' "$rulesets_meta" | jq -r -s '
        if length == 0
        then error("the ruleset listing returned no pages at all")
        elif (map(type != "array") | any)
        then error("the ruleset listing returned a non-array page (\(map(type) | unique | join(",")))")
        else .
        end
        | add // []
        | [ .[]? | objects
            | select((.enforcement // "") == "active")
            | select((.target // "branch") == "branch") ]
        | .[] | "\(.id)|\(.source_type // "")|\(.source // "")"' 2>"$errfile")"; then
        : # inventory parsed; the per-ruleset bypass check below decides
      else
        active_rulesets=""
        rulesets_ok=0
        errors="$(printf '%s' "$errors" | jq -c --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["rulesets: \($m), so the viewer-scoped rule response cannot be shown complete"]')"
      fi
      if [ "$rulesets_ok" -eq 1 ] && [ -n "$active_rulesets" ]; then
        while IFS= read -r rs_line; do
          [ -n "$rs_line" ] || continue
          rs_id="${rs_line%%|*}"
          rs_rest="${rs_line#*|}"
          rs_src_type="${rs_rest%%|*}"
          rs_src="${rs_rest#*|}"
          case "$rs_src_type" in
            Organization) rs_endpoint="orgs/$rs_src/rulesets/$rs_id" ;;
            Repository|"") rs_endpoint="repos/$repo/rulesets/$rs_id" ;;
            *) rs_endpoint="" ;;
          esac
          if [ -z "$rs_endpoint" ]; then
            rulesets_ok=0
            errors="$(printf '%s' "$errors" | jq -c --arg t "$rs_src_type" '. + ["rulesets: ruleset scope \($t) cannot be read, so the viewer-scoped rule response cannot be shown complete"]')"
            break
          fi
          if rs_detail="$(_br_retry gh api "$rs_endpoint" 2>"$errfile")"; then
            # `bypass_actors` must be an ACTUAL ARRAY. GitHub OMITS the field
            # when the token lacks write access to the ruleset rather than
            # returning it empty, so `// []` would turn "I was not shown the
            # bypass list" into "there is no bypass list" — the absence-versus-
            # inability-to-look conflation this whole change exists to remove,
            # reappearing inside the probe written to catch it. An absent field
            # leaves completeness unproven, exactly like an unreadable detail.
            rs_bypass="$(printf '%s' "$rs_detail" \
              | jq -r 'if (.bypass_actors | type) == "array" then (.bypass_actors | length | tostring) else "unknown" end' 2>/dev/null || echo "unknown")"
            if [ "$rs_bypass" = "unknown" ]; then
              rulesets_ok=0
              errors="$(printf '%s' "$errors" | jq -c --arg i "$rs_id" '. + ["rulesets: ruleset \($i) did not report a bypass_actors array (the field is omitted when the token lacks write access to the ruleset), so completeness cannot be shown"]')"
              break
            elif [ "$rs_bypass" -ne 0 ]; then
              rulesets_ok=0
              errors="$(printf '%s' "$errors" | jq -c --arg i "$rs_id" '. + ["rulesets: ruleset \($i) has bypass actors, so a rule binding the merging identity may be hidden from this reader"]')"
              break
            fi
          else
            rulesets_ok=0
            errors="$(printf '%s' "$errors" | jq -c --arg i "$rs_id" --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["rulesets: ruleset \($i) detail unreadable (\($m)), so the viewer-scoped rule response cannot be shown complete"]')"
            break
          fi
        done <<EOF
$active_rulesets
EOF
      fi
    else
      rulesets_ok=0
      errors="$(printf '%s' "$errors" | jq -c --arg m "$(tr '\n' ' ' <"$errfile")" '. + ["rulesets: ruleset listing unreadable (\($m)), so the viewer-scoped rule response cannot be shown complete"]')"
    fi
    [ "$rulesets_ok" -eq 1 ] || rulesets_ctx='[]'
  fi

  rm -f "$errfile"

  [ "$classic_ok" -eq 1 ] && surfaces="$(printf '%s' "$surfaces" | jq -c '. + ["classic"]')"
  [ "$rulesets_ok" -eq 1 ] && surfaces="$(printf '%s' "$surfaces" | jq -c '. + ["rulesets"]')"

  # BOTH surfaces must answer for the result to be `known`.
  #
  # An earlier revision returned `known` when either one did, reasoning that
  # filtering on a partial list beats imposing no filter. That is wrong, and
  # both reviewers caught it independently on PR #1176: the requirement is the
  # UNION, so one surface answering `[]` says nothing about what the other
  # would have said. Concretely — the GraphQL read fails transiently while
  # `rules/branches` returns `[]`, the result reads as known-and-empty, gate
  # (a) wipes the rollup, and a red classic required check clears. That is the
  # original fail-open reintroduced one level up, which is exactly the shape of
  # bug this lib exists to remove.
  #
  # `partial` is retained as a diagnostic — it marks the case where one surface
  # DID answer, which is what an operator needs to know to tell a half-outage
  # from a total one — but it is never a licence to act on the list.
  jq -nc \
    --argjson classic "$classic_ctx" \
    --argjson rulesets "$rulesets_ctx" \
    --argjson surfaces "$surfaces" \
    --argjson errors "$errors" \
    --argjson classic_ok "$classic_ok" \
    --argjson rulesets_ok "$rulesets_ok" '
    (($classic_ok + $rulesets_ok) == 2) as $known
    | ($rulesets | map(.context)) as $ruleset_names
    | { state: (if $known then "known" else "unknown" end),
        partial: (($classic_ok + $rulesets_ok) == 1),
        contexts: (if $known then (($classic + $ruleset_names) | unique) else [] end),
        # The REQUIREMENT LIST, one entry per rule rather than one per name.
        #
        # This is the shape a caller needs to decide whether a branch is
        # satisfied, and it is deliberately not collapsed by context: GitHub
        # evaluates each rule independently, so one context can carry several
        # requirements at once — pinned to app A by one ruleset, accepted from
        # any producer by another, and required by classic protection as well.
        # Collapsing them loses exactly the distinction that decides whether a
        # given run satisfies the branch.
        #
        # `app_id` is null for "any producer satisfies this". Classic
        # requirements are always null, by necessity rather than by
        # observation: `RefUpdateRule` exposes `requiredStatusCheckContexts` as
        # bare strings, and `BranchProtectionRule`, which does carry app
        # identity, needs `Administration:read` — the scope this lib exists to
        # avoid depending on. Modelling an unreadable pinning as any-producer
        # is the choice that cannot block a merge GitHub would allow.
        requirements: (if $known
                       then ([ $classic[] | { context: ., app_id: null } ]
                             + $rulesets) | unique
                       else [] end),
        surfaces: $surfaces,
        errors: $errors }
  '
}
