# scripts/lib/daily-feedback-rollup-helpers.sh
#
# Pure helper functions for daily-feedback-rollup.sh, split out so the
# unit tests in tests/test_daily_feedback_rollup.sh can source them
# directly without running the script's main body (which assumes
# GH_TOKEN + a live gh shim). Each function takes simple string args
# and produces stdout — no GitHub I/O, no temp files.
#
# To use:
#   source scripts/lib/daily-feedback-rollup-helpers.sh
#
# AGENT_AUTHORS is the only piece of state the helpers need at module
# load. Set it before sourcing or accept the canonical default.

: "${AGENT_AUTHORS:=nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}"

# classify_severity <comment-body> → P0|P1|P2|P3|Major|Minor|Nitpick|Trivial|Unknown
#
# Anchored on the first ~600 chars of body — enough to catch the
# CodeRabbit/Codex severity badge near the top, not enough to false-
# match severity words deeper in quoted context. Order matters: pick
# the highest-confidence match first.
#
# CodeRabbit canonical badges: `🟠 Major` / `Potential issue` / `⚠️` /
#                              `🧹 Nitpick` / `🔵 Trivial`
# Codex canonical badges:      `![P0 Badge]` … `![P3 Badge]`
classify_severity() {
  local body_head
  body_head=$(printf '%s' "$1" | head -c 600)
  case "$body_head" in
    *"![P0 Badge]"*|*"P0 Badge"*) echo "P0"; return ;;
    *"![P1 Badge]"*|*"P1 Badge"*) echo "P1"; return ;;
    *"![P2 Badge]"*|*"P2 Badge"*) echo "P2"; return ;;
    *"![P3 Badge]"*|*"P3 Badge"*) echo "P3"; return ;;
    *"🟠 Major"*|*"Potential issue"*|*"⚠️"*) echo "Major"; return ;;
    *"🧹 Nitpick"*|*Nitpick*) echo "Nitpick"; return ;;
    *"🔵 Trivial"*|*Trivial*) echo "Trivial"; return ;;
    *"Outside diff range"*) echo "Trivial"; return ;;
    *Minor*) echo "Minor"; return ;;
  esac
  echo "Unknown"
}

# severity_to_track <severity> → substantive|polish
#
# Spec routing: P0/P1/P2/Major → substantive; P3/Nitpick/Trivial →
# polish; Minor → substantive (closer to Major in CodeRabbit's badge
# semantics); Unknown → substantive (err on surface).
severity_to_track() {
  case "$1" in
    P0|P1|P2|Major|Minor) echo "substantive" ;;
    P3|Nitpick|Trivial)   echo "polish" ;;
    *)                    echo "substantive" ;;
  esac
}

# item_id_for <stable-key> → 12-char SHA1 prefix
#
# Used to build the `<!-- mp-id:... -->` marker on each rollup line
# item. The key should be the canonical `<repo>#<pr>:<thread_id>`
# per spec so the same thread always gets the same ID across days.
item_id_for() {
  printf '%s' "$1" | shasum -a 1 | cut -c1-12
}

# extract_tag_class <reply-body> → class string or empty
#
# Greps for the canonical `[mergepath-resolve: <class>]` tag that
# agent-side resolve-pr-threads.sh emits (mergepath#299 follow-up).
# Returns the class string (lowercase, hyphenated) or empty if no
# tag present. The regex is intentionally tolerant of surrounding
# whitespace.
extract_tag_class() {
  # grep -oE exits 1 on no-match, which under `set -e` + `pipefail`
  # would kill the caller. We squash to empty stdout on no-match so
  # callers can rely on `[ -z "$class" ]` semantics regardless of the
  # caller's shell options. Also: the regex requires a `]` immediately
  # after the class name; we strip surrounding whitespace via the sed
  # capture group so `[mergepath-resolve:  foo ]` and `[mergepath-resolve:foo]`
  # both parse to `foo`.
  printf '%s' "$1" \
    | grep -oE '\[mergepath-resolve:[[:space:]]*[a-z-]+[[:space:]]*\]' 2>/dev/null \
    | head -n1 \
    | sed -E 's/\[mergepath-resolve:[[:space:]]*([a-z-]+)[[:space:]]*\]/\1/' \
    || true
}

# tag_class_action <class> → skip|surface
#
# Maps a parsed tag class to whether the rollup should surface or
# skip the thread. Unknown classes route to "surface" per the spec
# (err on surface — future class additions are additive).
tag_class_action() {
  case "$1" in
    # templated-render — verify-propagation-pr.sh re-rendered the
    # source against mergepath@<sha> with the consumer's facts and
    # confirmed byte-equality with the PR dest (mergepath#323). Same
    # "mergepath concern" class as canonical-coverage: a finding on a
    # templated dest is structurally a mergepath concern (the template
    # lives in mergepath), so route it to mergepath rather than
    # surfacing on each consumer's daily rollup.
    #
    # verified-propagation — resolve-pr-threads.sh
    # --resolve-verified-propagation byte-compared the consumer's
    # CURRENT content at the anchored path against mergepath's
    # canonical source (or the re-rendered template with the
    # consumer's facts) and confirmed equality (mergepath#572). The
    # thread is evidence-verified handled — skip, don't re-surface.
    addressed-elsewhere|canonical-coverage|rebuttal-recorded|templated-render|verified-propagation) echo "skip" ;;
    nitpick-noted|deferred-to-followup) echo "surface" ;;
    "") echo "" ;;  # no tag → caller falls through to heuristics
    *)  echo "surface" ;;  # unknown → surface
  esac
}

# is_agent_author <login> → exit 0 if agent, 1 otherwise
#
# Used to recognize "addressed via reply" (must be from an agent
# author) and to filter who's allowed to emit a `[mergepath-resolve:]`
# tag. Reads AGENT_AUTHORS (colon-separated). Bash 3.2 compatible —
# avoids associative arrays.
is_agent_author() {
  local login="$1"
  local oldIFS="$IFS"
  IFS=':'
  set -- $AGENT_AUTHORS
  IFS="$oldIFS"
  for a; do
    [ "$login" = "$a" ] && return 0
  done
  return 1
}

# body_excerpt <body> [max_chars]
#
# Single-line, trimmed excerpt suitable for the rollup checklist
# item. Default max is 200 chars. Replaces newlines/tabs with spaces
# so the markdown rendering doesn't break.
body_excerpt() {
  local max="${2:-200}"
  printf '%s' "$1" | tr '\n\r\t' '   ' | head -c "$max"
}

# parse_triaged_ids_from_body <rollup-body> → newline-separated mp-ids
#
# Scans a prior rollup issue body line-by-line and emits, on stdout,
# the `mp-id` of every line item considered "already triaged" — i.e.
# excluded from future rollups (issue #304 dedupe pass).
#
# Triage signals recognised on a single rollup line:
#   - Checkbox `[x]` or `[X]`              → fix landed / won't-fix / followup-filed
#   - Checkbox `[~]` or `[-]`              → N/A / not-relevant
#   - Strikethrough wrapping the bullet    → `~~- [ ] ... ~~`
#   - A `#N` issue reference on the line   → follow-up filed
#
# Caller is responsible for the **closed host issue** signal: if the
# rollup issue itself is closed, the caller should treat every mp-id
# from its body as triaged (regardless of per-line state). We don't
# do it here because this helper has no view of issue state — it gets
# only the body text. The caller can use this helper's output for the
# "closed-host implies all triaged" branch by re-running it with a
# fall-through: parse_all_ids_from_body for closed hosts (skip the
# per-line signal check). For simplicity, this helper exposes a
# second mode via `parse_all_ids_from_body`.
#
# Per-item follow-up-link granularity trade-off: a reply ON a specific
# checklist line is not addressable in plain Markdown — replies live
# in the issue-comment stream, not on a specific bullet. The spec
# permits the simpler interpretation: "any `#N` reference on the
# line itself counts as a follow-up signal for THAT line." Reply-
# comments on the host issue that mention `#N` without anchoring to
# a specific mp-id are intentionally NOT consumed here; the
# follow-up-filed user signal is to drop the `#N` into the bullet
# text itself, which the agent or human triaging the rollup can do
# in one edit. This keeps the helper a pure body-string parser with
# no API I/O.
#
# Bash 3.2 + POSIX awk compatible. Output is mp-id per line, no
# duplicates (dedupe within the helper so the caller's set-membership
# check is O(1) per candidate).
parse_triaged_ids_from_body() {
  # awk processes the body line-by-line, extracts the mp-id from
  # `<!-- mp-id:XXXXXXXXXXXX -->`, and prints it only if the same line
  # carries a triage signal. We use awk (not bash + grep loop) so a
  # 200-line rollup body parses in a single subprocess. POSIX-portable
  # awk patterns only (no gawk-specific regex shortcuts).
  printf '%s\n' "$1" | awk '
    {
      line = $0
      # 1) extract the mp-id, if any
      if (match(line, /<!-- *mp-id:[a-f0-9]+ *-->/)) {
        marker = substr(line, RSTART, RLENGTH)
        # strip prefix/suffix and any surrounding whitespace
        sub(/^<!-- *mp-id:/, "", marker)
        sub(/ *-->$/, "", marker)
        id = marker
      } else {
        next
      }

      triaged = 0

      # 2) checkbox [x] / [X]  → fix-landed / won-fix / followup-filed
      if (line ~ /\[[ \t]*[xX][ \t]*\]/) triaged = 1
      # 3) checkbox [~] / [-]  → N/A
      else if (line ~ /\[[ \t]*[~\-][ \t]*\]/) triaged = 1
      # 4) strikethrough wrapping a bullet  → ~~- [ ] ... ~~
      else if (line ~ /~~.*\[[ \t]*\][ \t]*.*~~/) triaged = 1
      # 5) follow-up issue ref on the same line  → #N
      #    The hash must be preceded by a word boundary (start of
      #    line, whitespace, or common punctuation like `(`, `[`,
      #    `,`, `;`). POSIX awk does NOT support `\b`, so we make
      #    the leading-boundary explicit. The digit-only requirement
      #    on `[0-9]+` already excludes URL anchors like
      #    `pull/999#discussion_r1` (which have a letter after `#`),
      #    so no trailing boundary is needed.
      else if (line ~ /(^|[ \t(\[,;])#[0-9]+/) triaged = 1

      if (triaged) {
        print id
      }
    }
  ' | awk '!seen[$0]++'
}

# parse_all_ids_from_body <rollup-body> → newline-separated mp-ids
#
# Like parse_triaged_ids_from_body but does NOT check triage signals
# — emits every mp-id present in the body. Used by the caller for the
# "closed host issue → all items triaged" branch (issue #304 spec's
# implicit won't-fix rule for closed rollup hosts).
parse_all_ids_from_body() {
  printf '%s\n' "$1" | awk '
    {
      if (match($0, /<!-- *mp-id:[a-f0-9]+ *-->/)) {
        marker = substr($0, RSTART, RLENGTH)
        sub(/^<!-- *mp-id:/, "", marker)
        sub(/ *-->$/, "", marker)
        print marker
      }
    }
  ' | awk '!seen[$0]++'
}
