#!/usr/bin/env bash
# op-preflight.sh — Front-load all 1Password credential reads for a session.
#
# Triggers biometric prompts once at the start, then writes resolved secrets
# to a chmod-600 session file under $XDG_CACHE_HOME/mergepath/ (default
# $HOME/.cache/mergepath/). Subsequent invocations within the TTL window
# read the session file and emit the same export statements WITHOUT
# triggering biometric.
#
# This is what makes the script usable from agent drivers (Claude Code,
# Cursor, Codex CLI) where each tool call spawns a fresh subshell and
# cannot see env vars exported by a prior call. The first tool call in a
# session warms the cache (one biometric prompt); every subsequent tool
# call reuses the session file until it rotates. See
# nathanjohnpayne/mergepath#139 for the observed failure mode that
# motivated this design.
#
# Usage:
#   eval "$(scripts/op-preflight.sh --agent claude --mode all)"
#
#   # Force a fresh fetch even if the session file is still warm:
#   eval "$(scripts/op-preflight.sh --agent claude --mode all --refresh)"
#
#   # Delete the session file + ADC tempfile (end-of-session cleanup):
#   scripts/op-preflight.sh --agent claude --purge
#
# Modes:
#   review  — reviewer PAT + author PAT + SSH key warming
#   deploy  — GCP ADC credential
#   all     — everything (default)
#
# Flags:
#   --agent <name>   Agent name: claude, cursor, or codex (required except --purge-all)
#   --mode <mode>    review, deploy, or all (default: all)
#   --dry-run        Show what would be fetched without prompting
#   --skip-ssh       Skip SSH key warming (useful in CI or non-interactive)
#   --refresh        Force biometric fetch even if session file is fresh
#   --purge          Delete session file + ADC tempfile for the given --agent
#   --purge-all      Delete ALL session files + ADC tempfiles under the cache dir
#
# Environment:
#   OP_PREFLIGHT_TTL_SECONDS  Override default TTL (14400s = 4h). Age is
#                             measured against the session file's embedded
#                             timestamp, not file mtime, so `touch`-ing the
#                             file does NOT extend its effective lifetime.
#   OP_PREFLIGHT_CACHE_DIR    Override cache dir (default
#                             $XDG_CACHE_HOME/mergepath or $HOME/.cache/mergepath).
#
# Session file:
#   Path:        $cache_dir/op-preflight-<agent>.env
#   Permissions: 600 (owner read/write only)
#   Format:      bash-sourceable KEY='value' lines (printf %q-escaped)
#   TTL anchor:  OP_PREFLIGHT_CREATED_AT_EPOCH (embedded in file, not mtime)
#
# After eval, downstream scripts and agent commands use the exported env
# vars instead of calling op directly:
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh pr review ...
#   GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"   gh pr merge ...
#   # gcloud/firebase use GOOGLE_APPLICATION_CREDENTIALS automatically

set -eo pipefail
umask 077  # Restrict file permissions before any mktemp/cache writes

# ── PAT lookup table ──────────────────────────────────────────────────
# Must match REVIEW_POLICY.md § PAT lookup table.
AUTHOR_PAT_ITEM="sm5kopwk6t6p3xmu2igesndzhe"

reviewer_pat_item_for() {
  case "$1" in
    claude) echo "pvbq24vl2h6gl7yjclxy2hbote" ;;
    cursor) echo "bslrih4spwxgookzfy6zedz5g4" ;;
    codex)  echo "o6ekjxjjl5gq6rmcneomrjahpu" ;;
    *)      return 1 ;;
  esac
}

ssh_host_for() {
  case "$1" in
    claude) echo "github-claude" ;;
    cursor) echo "github-cursor" ;;
    codex)  echo "github-codex" ;;
    *)      return 1 ;;
  esac
}

# ── Cache layout ──────────────────────────────────────────────────────
DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mergepath"
CACHE_DIR="${OP_PREFLIGHT_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
DEFAULT_TTL_SECONDS=14400  # 4 hours
TTL_SECONDS="${OP_PREFLIGHT_TTL_SECONDS:-$DEFAULT_TTL_SECONDS}"

# ── GCP ADC ───────────────────────────────────────────────────────────
DEFAULT_ADC_OP_URI="${GCP_ADC_OP_URI:-op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential}"
SSH_AUTHOR_HOST="github.com"

# ── Parse arguments ───────────────────────────────────────────────────
AGENT=""
MODE="all"
DRY_RUN=false
SKIP_SSH=false
REFRESH=false
PURGE=false
PURGE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENT="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-ssh) SKIP_SSH=true; shift ;;
    --refresh) REFRESH=true; shift ;;
    --purge) PURGE=true; shift ;;
    --purge-all) PURGE_ALL=true; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode all)\"" >&2
      exit 1
      ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────
if $PURGE_ALL; then
  if [[ -d "$CACHE_DIR" ]]; then
    echo "# Purging all session files under $CACHE_DIR" >&2
    find "$CACHE_DIR" -maxdepth 1 -type f \( -name 'op-preflight-*.env' -o -name 'op-preflight-*-adc.json' \) -print -delete >&2
  fi
  exit 0
fi

if [[ "$MODE" == "review" || "$MODE" == "all" || "$PURGE" == "true" ]] && [[ -z "$AGENT" ]]; then
  echo "Error: --agent is required for review, all, or --purge mode." >&2
  echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode all)\"" >&2
  exit 1
fi

if [[ -n "$AGENT" ]] && [[ -z "$(reviewer_pat_item_for "$AGENT" 2>/dev/null || true)" ]]; then
  echo "Error: unknown agent '$AGENT'. Valid: claude, cursor, codex" >&2
  exit 1
fi

if ! [[ "$TTL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Error: OP_PREFLIGHT_TTL_SECONDS must be an integer; got '$TTL_SECONDS'" >&2
  exit 1
fi

# ── Cache paths (deterministic per agent) ─────────────────────────────
SESSION_FILE="$CACHE_DIR/op-preflight-$AGENT.env"
ADC_TMPFILE="$CACHE_DIR/op-preflight-$AGENT-adc.json"

# ── Purge mode ────────────────────────────────────────────────────────
if $PURGE; then
  rm -f "$SESSION_FILE" "$ADC_TMPFILE"
  echo "# Purged session file + ADC tempfile for agent=$AGENT" >&2
  exit 0
fi

# ── Dry run ───────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo "# op-preflight.sh --agent $AGENT --mode $MODE (dry run)" >&2
  echo "#" >&2
  echo "# Session file:   $SESSION_FILE" >&2
  echo "# ADC tempfile:   $ADC_TMPFILE" >&2
  echo "# TTL seconds:    $TTL_SECONDS" >&2
  if [[ -f "$SESSION_FILE" ]]; then
    embedded=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"")
    now=$(date +%s)
    age=$((now - ${embedded:-0}))
    echo "# Session age:    ${age}s (TTL ${TTL_SECONDS}s)" >&2
  else
    echo "# Session age:    n/a (no session file)" >&2
  fi
  echo "#" >&2
  if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
    echo "# Would read: reviewer PAT ($(reviewer_pat_item_for "$AGENT"))" >&2
    echo "# Would read: author PAT ($AUTHOR_PAT_ITEM)" >&2
    if ! $SKIP_SSH; then
      echo "# Would warm SSH: $SSH_AUTHOR_HOST (author key)" >&2
      echo "# Would warm SSH: $(ssh_host_for "$AGENT") (reviewer key)" >&2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    echo "# Would read: GCP ADC ($DEFAULT_ADC_OP_URI)" >&2
  fi
  exit 0
fi

# ── Ensure cache dir exists (mode 0700) ───────────────────────────────
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR" 2>/dev/null || true

# ── Session file freshness check ──────────────────────────────────────
# Prefer an embedded CREATED_AT epoch over file mtime so `touch`-ing the
# file cannot silently extend its effective lifetime.
session_is_fresh() {
  [[ -f "$SESSION_FILE" ]] || return 1
  local created_at now age
  created_at=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
  [[ -z "$created_at" ]] && return 1
  [[ "$created_at" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  age=$((now - created_at))
  [[ "$age" -lt "$TTL_SECONDS" ]]
}

# Emit the session file's export statements to stdout. Caller eval's them.
emit_from_session_file() {
  # Source the session file and re-emit only the vars we own, so a
  # hand-edited file with arbitrary content cannot inject exports.
  # Also drop CREATED_AT from the exported set; it's bookkeeping.
  # shellcheck disable=SC1090
  . "$SESSION_FILE"

  # Validate the session file actually contains the credentials the
  # CURRENT invocation's --mode is asking for. A stale cross-mode cache
  # (e.g. a prior `--mode deploy` run wrote only ADC fields, and this
  # run is `--mode review`) would otherwise hit the fast path and emit
  # no PAT exports — downstream `gh` review commands then run
  # unauthenticated. Return non-zero to trigger the refresh path in
  # each case. See #141 round-1 Codex finding (P1, line 223).
  if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
    if [[ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]] || [[ -z "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]]; then
      return 2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    # Both the cached-path pointer must be set AND the file it names
    # must still be readable (non-empty).
    if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] || [[ ! -s "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
      return 2
    fi
  fi

  [[ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_REVIEWER_PAT=%q\n' "$OP_PREFLIGHT_REVIEWER_PAT"
  [[ -n "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_AUTHOR_PAT=%q\n' "$OP_PREFLIGHT_AUTHOR_PAT"
  [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && \
    printf 'export GOOGLE_APPLICATION_CREDENTIALS=%q\n' "$GOOGLE_APPLICATION_CREDENTIALS"
  [[ -n "${OP_PREFLIGHT_ADC_TMPFILE:-}" ]] && \
    printf 'export OP_PREFLIGHT_ADC_TMPFILE=%q\n' "$OP_PREFLIGHT_ADC_TMPFILE"
  printf 'export OP_PREFLIGHT_DONE=1\n'
  printf 'export OP_PREFLIGHT_AGENT=%q\n' "$AGENT"
  return 0
}

# ── Fast path: reuse session file when fresh ──────────────────────────
if ! $REFRESH && session_is_fresh; then
  if emit_from_session_file; then
    age=$(( $(date +%s) - $(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"") ))
    echo "" >&2
    echo "# ── Preflight cached hit (age ${age}s / TTL ${TTL_SECONDS}s) ──" >&2
    echo "# Session file: $SESSION_FILE" >&2
    echo "# Run with --refresh to force a new biometric fetch." >&2
    echo "# ──────────────────────────────────────────────────────────" >&2
    exit 0
  fi
  # emit_from_session_file returned non-zero (e.g. ADC file vanished).
  # Fall through to full fetch.
  echo "# Session file stale or incomplete — refreshing" >&2
fi

# ── Preflight checks for full fetch ──────────────────────────────────
if ! command -v op &>/dev/null; then
  echo "Error: 1Password CLI (op) not found." >&2
  exit 1
fi

# ── Collect export statements + session-file lines ───────────────────
EXPORTS=()
SESSION_LINES=()
SUMMARY=()

# ── Phase 1: CLI credentials (one biometric prompt + session reuse) ───
if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
  reviewer_item="$(reviewer_pat_item_for "$AGENT")"

  # Build an op inject template for both PATs. op inject resolves all
  # op:// references in a single process — one biometric prompt covers
  # both reads.
  tpl_file="$(mktemp "${TMPDIR:-/tmp}/op-preflight-tpl-XXXXXX")"
  trap 'rm -f "$tpl_file"' EXIT

  cat > "$tpl_file" <<TPL
REVIEWER_PAT={{ op://Private/${reviewer_item}/token }}
AUTHOR_PAT={{ op://Private/${AUTHOR_PAT_ITEM}/token }}
TPL

  echo "# Preflight: reading PATs (one biometric prompt)..." >&2
  resolved="$(op inject -i "$tpl_file")"
  rm -f "$tpl_file"

  reviewer_pat="$(echo "$resolved" | grep '^REVIEWER_PAT=' | cut -d= -f2-)"
  author_pat="$(echo "$resolved" | grep '^AUTHOR_PAT=' | cut -d= -f2-)"

  if [[ -z "$reviewer_pat" ]]; then
    echo "Error: failed to read reviewer PAT for $AGENT." >&2
    exit 1
  fi
  if [[ -z "$author_pat" ]]; then
    echo "Error: failed to read author PAT." >&2
    exit 1
  fi

  EXPORTS+=("export OP_PREFLIGHT_REVIEWER_PAT=$(printf '%q' "$reviewer_pat")")
  EXPORTS+=("export OP_PREFLIGHT_AUTHOR_PAT=$(printf '%q' "$author_pat")")
  SESSION_LINES+=("OP_PREFLIGHT_REVIEWER_PAT=$(printf '%q' "$reviewer_pat")")
  SESSION_LINES+=("OP_PREFLIGHT_AUTHOR_PAT=$(printf '%q' "$author_pat")")
  SUMMARY+=("Reviewer PAT ($AGENT): loaded")
  SUMMARY+=("Author PAT: loaded")
fi

if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
  echo "# Preflight: reading GCP ADC (reuses session)..." >&2

  # Deterministic path so subsequent invocations find the same file.
  # Overwrite in place — chmod 600 before writing secret content.
  touch "$ADC_TMPFILE"
  chmod 600 "$ADC_TMPFILE"

  if op read "$DEFAULT_ADC_OP_URI" > "$ADC_TMPFILE" 2>/dev/null && [[ -s "$ADC_TMPFILE" ]]; then
    EXPORTS+=("export GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$ADC_TMPFILE")")
    EXPORTS+=("export OP_PREFLIGHT_ADC_TMPFILE=$(printf '%q' "$ADC_TMPFILE")")
    SESSION_LINES+=("GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$ADC_TMPFILE")")
    SESSION_LINES+=("OP_PREFLIGHT_ADC_TMPFILE=$(printf '%q' "$ADC_TMPFILE")")
    SUMMARY+=("GCP ADC: loaded -> $ADC_TMPFILE")
  else
    rm -f "$ADC_TMPFILE"
    echo "# Warning: could not read GCP ADC. Deploy credentials not cached." >&2
    SUMMARY+=("GCP ADC: SKIPPED (not available)")
  fi
fi

# ── Phase 2: SSH key warming ──────────────────────────────────────────
if [[ "$MODE" == "review" || "$MODE" == "all" ]] && ! $SKIP_SSH; then
  echo "# Preflight: warming SSH keys..." >&2

  # Author key
  if ssh -T "git@${SSH_AUTHOR_HOST}" 2>&1 | grep -qi "successfully authenticated"; then
    SUMMARY+=("SSH key ($SSH_AUTHOR_HOST): authorized")
  else
    SUMMARY+=("SSH key ($SSH_AUTHOR_HOST): warming attempted")
  fi

  # Reviewer key
  reviewer_host="$(ssh_host_for "$AGENT")"
  if ssh -T "git@${reviewer_host}" 2>&1 | grep -qi "successfully authenticated"; then
    SUMMARY+=("SSH key ($reviewer_host): authorized")
  else
    SUMMARY+=("SSH key ($reviewer_host): warming attempted")
  fi
fi

# ── Persist session file ──────────────────────────────────────────────
CREATED_AT=$(date +%s)
{
  printf '# op-preflight session cache — do NOT edit by hand.\n'
  printf '# Agent:      %s\n' "$AGENT"
  printf '# Mode:       %s\n' "$MODE"
  printf '# Created:    %s (epoch %s)\n' "$(date -u -r "$CREATED_AT" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$CREATED_AT" +%Y-%m-%dT%H:%M:%SZ)" "$CREATED_AT"
  printf '# TTL:        %s seconds\n' "$TTL_SECONDS"
  printf 'OP_PREFLIGHT_CREATED_AT_EPOCH=%s\n' "$CREATED_AT"
  printf 'OP_PREFLIGHT_TTL_SECONDS=%s\n' "$TTL_SECONDS"
  printf 'OP_PREFLIGHT_AGENT=%q\n' "$AGENT"
  printf 'OP_PREFLIGHT_MODE=%q\n' "$MODE"
  printf 'OP_PREFLIGHT_DONE=1\n'
  for line in "${SESSION_LINES[@]}"; do
    printf '%s\n' "$line"
  done
} > "$SESSION_FILE"
chmod 600 "$SESSION_FILE"

# ── Output ────────────────────────────────────────────────────────────
EXPORTS+=("export OP_PREFLIGHT_DONE=1")
EXPORTS+=("export OP_PREFLIGHT_AGENT=$(printf '%q' "$AGENT")")

# Print export statements to stdout (caller evals them)
for exp in "${EXPORTS[@]}"; do
  echo "$exp"
done

# Print summary to stderr (visible to user, not eval'd)
echo "" >&2
echo "# ── Preflight complete ──────────────────────────────" >&2
for line in "${SUMMARY[@]}"; do
  echo "#   $line" >&2
done
echo "# Session file: $SESSION_FILE (TTL ${TTL_SECONDS}s)" >&2
echo "# OP_PREFLIGHT_DONE=1" >&2
echo "# Human can step away." >&2
echo "# ──────────────────────────────────────────────────────" >&2
