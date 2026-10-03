#!/usr/bin/env bash
# Advisory machine-local invocation observations (#1589). No GitHub reads,
# authority decisions, traps, shell options, or accounting ownership changes.
# Every producer entry point returns 0, including malformed/unwritable storage.

p4b_heartbeat_write() {
  (
    [ -n "${P4B_HB_FILE:-}" ] || exit 0
    local tmp review_posted=false
    # Early refusals can precede the orchestrator's initialization. Inherited
    # text must neither break JSON publication nor change this boolean's type.
    [ "${REVIEW_POSTED:-}" != true ] || review_posted=true
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
      --argjson stages "$P4B_HB_STAGES" --argjson dry_run "${DRY_RUN:-false}" \
      --arg timeout "${ADAPTER_TIMEOUT:-}" \
      --arg adapter_started "${P4B_ACCT_LOOP_STARTED_EPOCH:-}" \
      --arg elapsed "${P4B_ACCT_LOOP_ELAPSED_SECONDS:-}" \
      --arg adapter_rc "${ADAPTER_RC:-}" --arg exit_code "${P4B_HB_EXIT_CODE:-}" \
      --arg adapter_verdict "${VERDICT:-}" \
      --argjson summary_emitted "${P4B_HB_SUMMARY_EMITTED:-false}" \
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
  local record="$1" stage pid expected observed rc=0
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
  observed="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" || rc=$?
  if [ "$rc" = 1 ] && [ -z "$observed" ]; then
    printf 'crashed\n'
  elif [ "$rc" != 0 ] || [ -z "$observed" ] || [ -z "$expected" ]; then
    printf 'unknown\n'
  elif [ "$expected" = "$observed" ]; then
    printf 'running\n'
  else
    printf 'crashed\n'
  fi
  return 0
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
