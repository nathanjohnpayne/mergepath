#!/usr/bin/env bash
# Advisory machine-local invocation observations (#1589). No GitHub reads,
# authority decisions, traps, shell options, or accounting ownership changes.
# Every producer entry point returns 0, including malformed/unwritable storage.

p4b_heartbeat_write() {
  (
    [ -n "${P4B_HB_FILE:-}" ] || exit 0
    local tmp review_posted=false dry_run=false summary_emitted=false
    # Early refusals can precede the orchestrator's initialization. Inherited
    # text must neither break JSON publication nor change a boolean's type.
    [ "${REVIEW_POSTED:-}" != true ] || review_posted=true
    [ "${DRY_RUN:-}" != true ] || dry_run=true
    [ "${P4B_HB_SUMMARY_EMITTED:-}" != true ] || summary_emitted=true
    tmp="$(mktemp "${P4B_HB_DIR}/.heartbeat.XXXXXX")" || exit 0
    # Build from this process's memory, never from a previous on-disk record.
    # A broken/partial old observation cannot shape the next stage or verdict.
    if jq -nc \
      --arg run_id "$P4B_ACCT_RUN_ID" --arg pid "$$" \
      --arg process_started_at "${P4B_HB_PROCESS_STARTED_AT:-}" \
      --arg repo "${REPO:-}" --arg pr "${PR:-}" --arg head "${HEAD:-}" \
      --arg direction "${DIRECTION:-}" --arg reviewer "${REVIEWER:-}" \
      --arg checkout "$P4B_HB_CHECKOUT" --arg started "$P4B_HB_STARTED_EPOCH" \
      --arg started_at "$P4B_HB_STARTED_AT" --arg stage "$P4B_HB_STAGE" \
      --arg stage_at "$P4B_HB_STAGE_AT" --arg stage_epoch "$P4B_HB_STAGE_EPOCH" \
      --argjson stages "$P4B_HB_STAGES" --argjson dry_run "$dry_run" \
      --arg timeout "${ADAPTER_TIMEOUT:-}" \
      --arg adapter_started "${P4B_ACCT_LOOP_STARTED_EPOCH:-}" \
      --arg elapsed "${P4B_ACCT_LOOP_ELAPSED_SECONDS:-}" \
      --arg adapter_rc "${ADAPTER_RC:-}" --arg exit_code "${P4B_HB_EXIT_CODE:-}" \
      --arg adapter_verdict "${VERDICT:-}" \
      --argjson summary_emitted "$summary_emitted" \
      --arg verdict "${VERDICT:-}" --arg token_count "${TOKEN_COUNT:-}" \
      --arg findings_count "${FINDINGS_COUNT:-}" \
      --argjson review_posted "$review_posted" \
      --arg acknowledgment "${REVIEW_ACKNOWLEDGMENT:-}" '
      def number_or_null: if test("^(0|[1-9][0-9]*)$") then tonumber else null end;
      def text_or_null: if . == "" then null else . end;
      {schema:"p4b-heartbeat/v1",run_id:$run_id,pid:($pid|tonumber),
       process_started_at:($process_started_at|text_or_null),repo:$repo,pr:$pr,
       head:$head,direction:$direction,reviewer:$reviewer,checkout:$checkout,
       dry_run:$dry_run,started_at:$started_at,started_at_epoch:($started|number_or_null),
       stage:$stage,stage_at:$stage_at,stage_at_epoch:($stage_epoch|number_or_null),
       stages:$stages,adapter_timeout_seconds:($timeout|number_or_null),
       adapter_started_at_epoch:($adapter_started|number_or_null),
       adapter_elapsed_seconds:($elapsed|number_or_null),adapter_exit_code:($adapter_rc|number_or_null),
       adapter_verdict:($adapter_verdict|text_or_null),exit_code:($exit_code|number_or_null),
       summary_emitted:$summary_emitted,
       verdict:(if $summary_emitted then ($verdict|text_or_null) else null end),
       token_count:(if $summary_emitted then ($token_count|number_or_null) else null end),
       findings_count:(if $summary_emitted then ($findings_count|number_or_null) else null end),
       review_posted:$review_posted,review_acknowledgment:($acknowledgment|text_or_null)}' > "$tmp" \
       && mv -f "$tmp" "$P4B_HB_FILE"; then
      :
    else
      rm -f "$tmp" || true
    fi
  ) >/dev/null 2>&1 || true
  return 0
}

# Reader seam for #1590: process-instance identity reduces PID-reuse errors.
# ps absence/indeterminate evidence is unknown, never a confident live/crashed.
p4b_heartbeat_status() {
  local record="$1" stage pid expected observed started rc=0
  stage="$(jq -ser 'select(length == 1) | .[0] |
    select(type == "object" and .schema == "p4b-heartbeat/v1") |
    select(has("process_started_at")) |
    select(.process_started_at == null or (.process_started_at | type == "string" and length > 0)) | .stage |
    select(. == "barrier" or . == "adapter" or . == "posting" or . == "done")' "$record" 2>/dev/null)" \
    || { printf 'unknown\n'; return 0; }
  # ps accepts positive decimal pid_t values, not jq's scientific notation
  # for oversized numbers. Use the portable signed 32-bit bound before ps.
  pid="$(jq -er '.pid | select(type == "number" and . > 0 and . <= 2147483647 and . == floor)' "$record" 2>/dev/null)" \
    || { printf 'unknown\n'; return 0; }
  case "$pid" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  [ "$stage" != 'done' ] || { printf 'done\n'; return 0; }
  command -v ps >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  expected="$(jq -er '.process_started_at | select(type == "string" and length > 0)' "$record" 2>/dev/null)" \
    || { printf 'unknown\n'; return 0; }
  started="$(jq -er '.started_at_epoch | select(type == "number" and . > 0)' "$record" 2>/dev/null)" || started=""
  # lstart follows the zone of whoever runs ps, and the writer's zone is not
  # recorded. The reader renders the live start in UTC and decides identity
  # without knowing the writer's zone (p4b_heartbeat_same_process).
  observed="$(LC_ALL=C TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null)" || rc=$?
  if [ "$rc" = 1 ] && [ -z "$observed" ]; then
    printf 'crashed\n'
  elif [ "$rc" != 0 ] || [ -z "$observed" ] || [ -z "$expected" ]; then
    printf 'unknown\n'
  else
    case "$(p4b_heartbeat_same_process "$expected" "$observed" "$started")" in
      yes) printf 'running\n' ;;
      no) printf 'crashed\n' ;;
      *) printf 'unknown\n' ;;
    esac
  fi
  return 0
}

# Echoes yes when the live process is the record's writer, no when it is not, and
# nothing when that cannot be decided. <recorded lstart> is in the writer's zone,
# <observed lstart> in UTC. The writer is the process that owned the PID when it
# wrote the record, so it started no later than started_at_epoch; a reused PID
# belongs to a process that started after the writer ended, which is after the
# record was written. Identity therefore needs both: the recorded start equals
# the live start up to a whole zone offset (a multiple of 15 minutes, at most 14
# hours), and the live process started no later than the record (#1830, #1837).
p4b_heartbeat_same_process() { # <recorded lstart> <observed UTC lstart> <started_at_epoch>
  jq -nr --arg a "$1" --arg b "$2" --arg started "$3" '
    def epoch: gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " ") | strptime("%a %b %d %H:%M:%S %Y") | mktime;
    ($b | epoch) as $live | (($a | epoch) - $live) as $d
    | if ($d % 900) != 0 or ($d | fabs) > 50400 then "no"
      elif ($started | test("^[0-9]+([.][0-9]+)?$") | not) then empty
      elif $live <= ($started | tonumber) then "yes"
      else "no" end' 2>/dev/null || true
}

# Prune only old terminal/dead observations. Never delete a live long-running
# invocation. Invalid retention disables pruning; malformed records remain for
# diagnosis. File mtime is the last local publication, not authority/freshness.
p4b_heartbeat_prune() {
  (
    local days="${P4B_HEARTBEAT_RETENTION_DAYS:-7}" record status
    case "$days" in ''|*[!0-9]*|0*) exit 0 ;; esac
    [ "${#days}" -le 4 ] && [ "$days" -ge 1 ] && [ "$days" -le 3650 ] || exit 0
    [ -d "${P4B_HB_DIR:-}" ] || exit 0
    while IFS= read -r -d '' record; do
      [ "$record" != "${P4B_HB_FILE:-}" ] || continue
      status="$(p4b_heartbeat_status "$record")"
      case "$status" in done|crashed) rm -f "$record" || true ;; esac
    done < <(find "$P4B_HB_DIR" -type f -name 'p4b-*.json' -mmin +"$((days * 1440))" -print0)
  ) >/dev/null 2>&1 || true
  return 0
}

p4b_heartbeat_stage() {
  local stage="$1" epoch="${2:-}" at stages
  [ -n "${P4B_HB_FILE:-}" ] || return 0
  case "$stage" in barrier|adapter|posting|done) ;; *) return 0 ;; esac
  epoch="${epoch:-$(date +%s 2>/dev/null || true)}"
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  # No duplicate transition when updating elapsed evidence within a stage.
  if [ "${P4B_HB_STAGE:-}" != "$stage" ]; then
    stages="$(jq -nc --argjson prev "${P4B_HB_STAGES:-[]}" --arg stage "$stage" \
      --arg at "$at" --arg epoch "$epoch" '
      $prev + [{stage:$stage,stage_at:$at,stage_at_epoch:
        (if ($epoch|test("^(0|[1-9][0-9]*)$")) then ($epoch|tonumber) else null end)}]' 2>/dev/null)" || return 0
    P4B_HB_STAGES="$stages"
    P4B_HB_STAGE="$stage"; P4B_HB_STAGE_AT="$at"; P4B_HB_STAGE_EPOCH="$epoch"
  fi
  p4b_heartbeat_write
  return 0
}

p4b_heartbeat_start() {
  # Only the genuine orchestrator ID travels globally. pid-$$ is a local
  # pending-record ownership fallback and must never become history identity.
  [[ "${P4B_ACCT_RUN_ID:-}" =~ ^p4b-[a-zA-Z0-9._-]+$ ]] || return 0
  P4B_HB_DIR="${P4B_HEARTBEAT_DIR:-${HOME:-}/.local/state/mergepath/phase-4b-runs}"
  P4B_HB_FILE="$P4B_HB_DIR/$P4B_ACCT_RUN_ID.json"
  P4B_HB_CHECKOUT="$(pwd -P 2>/dev/null || true)"
  P4B_HB_STARTED_EPOCH="$(date +%s 2>/dev/null || true)"
  P4B_HB_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  # Same pinned locale and zone as the p4b_heartbeat_status reader.
  # The writer keeps the v1 rendering (its own zone), so readers of every version
  # still parse it; p4b_heartbeat_status decides identity whatever zone it was in.
  P4B_HB_PROCESS_STARTED_AT="$(LC_ALL=C ps -p "$$" -o lstart= 2>/dev/null || true)"
  P4B_HB_STAGES='[]'; P4B_HB_STAGE=""; P4B_HB_SUMMARY_EMITTED=false
  P4B_HB_EXIT_CODE=""
  # All local telemetry operations run guarded; no failed mkdir/JSON/mv/ps
  # can interrupt a caller under errexit, including calls inside refusal arms.
  mkdir -p "$P4B_HB_DIR" >/dev/null 2>&1 || true
  p4b_heartbeat_stage barrier
  p4b_heartbeat_prune
  return 0
}

p4b_heartbeat_finish() {
  P4B_HB_EXIT_CODE="$1"
  p4b_heartbeat_stage 'done'
  return 0
}
