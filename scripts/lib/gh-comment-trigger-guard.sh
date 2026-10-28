# shellcheck shell=bash
# Shared runtime comment guard for the token-verifying wrappers (#2158).
# Sourcing defines functions only; every payload file is private and ephemeral.
gh_comment_guard_prepare() {
  local argument
  GH_COMMENT_GUARD_ARGS=("$@")
  GH_COMMENT_GUARD_STATE=$(mktemp -d "${TMPDIR:-/tmp}/gh-comment-guard.XXXXXX") || return 1
  chmod 700 "$GH_COMMENT_GUARD_STATE" || return 1
  python3 "$ROOT/scripts/workflow/gh-comment-trigger-guard.py" \
    --role "$GH_COMMENT_GUARD_ROLE" --state-dir "$GH_COMMENT_GUARD_STATE" -- "$@" || return 1
  GH_COMMENT_GUARD_ARGS=()
  while IFS= read -r -d '' argument; do
    GH_COMMENT_GUARD_ARGS+=("$argument")
  done < "$GH_COMMENT_GUARD_STATE/argv"
}

# Preserve the REST transport's existing materialized-file-only CLI grammar.
# Raw API stdin remains a separate documented transport form.
gh_comment_guard_check_transport() {
  local cli_stdin
  if [ "$1" != rest ]; then return 0; fi
  cli_stdin=$(jq -er '(.cli_stdin // false) | if type == "boolean" then tostring else error("invalid stdin metadata") end' \
    "$GH_COMMENT_GUARD_STATE/metadata.json") || return 1
  if [ "$cli_stdin" = true ]; then
    echo "comment-trigger-guard: the REST transport accepts exactly a materialized body file; write stdin to a file first." >&2
    return 1
  fi
}

# #1362: per-PR request claim. Re-running authorization alone is not atomic:
# two wrappers could both recount a below-cap timeline and both post. So the
# wrapper takes an exclusive per-PR lock BEFORE the authorization recount and
# holds it through the comment POST and the readback of its confirmed id
# (gh_comment_guard_confirm_post). The lock is a kernel flock on fd 9 of this
# wrapper process: it ends when the wrapper exits, however it exits, so it can
# never suppress a trigger that was never sent. The authorization pass runs
# inside it and takes no lock of its own. A nested trigger write, a lock that
# cannot be opened or verified, or a holder that outlasts the wait fails
# closed. The lock is host-local: it serializes guarded requesters on this
# machine only, and a direct web-UI request bypasses it entirely (counted
# afterward from the timeline, never blocked).
gh_comment_guard_claim() { # <repo> <pr>
  local repo="$1" pr="$2" dir key path timeout
  if [ -n "${MERGEPATH_CODEX_REQUEST_CLAIM_HELD:-}" ]; then
    echo "comment-trigger-guard: a Codex request write is already inside the request claim for ${MERGEPATH_CODEX_REQUEST_CLAIM_HELD##*/}; refusing a nested trigger write (#1362)." >&2
    return 1
  fi
  # Every checkout on the machine must resolve the same lock file, so the
  # directory is absolute: a relative XDG_STATE_HOME is ignored (as the XDG
  # spec says), and a relative MERGEPATH_CODEX_REQUEST_CLAIM_DIR, or no
  # usable root at all, fails closed.
  local state_root="${XDG_STATE_HOME:-}"
  case "$state_root" in
    /*) ;;
    *) state_root=""; [ -z "${HOME:-}" ] || state_root="$HOME/.local/state" ;;
  esac
  dir="${MERGEPATH_CODEX_REQUEST_CLAIM_DIR:-${state_root:+$state_root/mergepath/codex-request-claims}}"
  timeout="${MERGEPATH_CODEX_REQUEST_CLAIM_TIMEOUT_SECONDS:-900}"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$dir" != /* ]]; then
    echo "comment-trigger-guard: cannot establish the per-PR Codex request claim (invalid timeout, or no absolute claim directory); refusing the trigger write (#1362)." >&2
    return 1
  fi
  key=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | sed 's|/|__|')
  path="$dir/$key#$pr.lock"
  if ! { mkdir -p "$dir" && chmod 700 "$dir" && exec 9>>"$path"; } 2>/dev/null; then
    echo "comment-trigger-guard: cannot open the per-PR Codex request claim $path; refusing the trigger write (#1362). Set MERGEPATH_CODEX_REQUEST_CLAIM_DIR to a writable directory shared by every checkout on this machine." >&2
    return 1
  fi
  if ! python3 -I -S -c '
import errno, fcntl, os, sys, time
path, timeout, label = sys.argv[1], float(sys.argv[2]), sys.argv[3]
def same(a, b):
    return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)
try:
    if not same(os.fstat(9), os.stat(path)):
        sys.exit(3)
    deadline = time.monotonic() + timeout
    waited = False
    while True:
        try:
            fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                raise
        if time.monotonic() >= deadline:
            print(f"comment-trigger-guard: another guarded Codex request for {label} still holds the per-PR claim after {timeout:.0f}s; refusing the trigger write (#1362).", file=sys.stderr)
            sys.exit(4)
        if not waited:
            print(f"comment-trigger-guard: waiting for another guarded Codex request for {label} to finish (#1362).", file=sys.stderr)
            waited = True
        time.sleep(0.2)
    # Confirm the claim: the path still names this inode, and a separate open
    # of it cannot take the lock, so this wrapper holds it.
    probe = os.open(path, os.O_RDONLY)
    try:
        if not same(os.fstat(probe), os.fstat(9)):
            sys.exit(3)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                sys.exit(0)
            raise
        sys.exit(3)
    finally:
        os.close(probe)
except OSError:
    sys.exit(3)
' "$path" "$timeout" "$repo#$pr"; then
    exec 9>&-
    echo "comment-trigger-guard: the per-PR Codex request claim for $repo#$pr could not be acquired and confirmed; refusing the trigger write (#1362)." >&2
    return 1
  fi
  export MERGEPATH_CODEX_REQUEST_CLAIM_HELD="$path"
  GH_COMMENT_GUARD_CLAIM="$repo#$pr"
}

# Run the claimed trigger write and confirm the id it reports, still inside the
# claim, before the next guarded requester may recount. Without a claim the
# command runs unchanged.
gh_comment_guard_run_write() { # <command...>
  local out rc=0 id comment repo pr attempt attempts delay
  if [ -z "${GH_COMMENT_GUARD_CLAIM:-}" ]; then
    "$@"
    return $?
  fi
  out="$GH_COMMENT_GUARD_STATE/claimed-write.out"
  # The POST and the readback below inherit the claim on purpose: a child
  # that can still write keeps every other requester out until it ends, even
  # if this wrapper is killed meanwhile. Only the read-only recount releases
  # it in its own shell (gh_comment_guard_authorize) (#1362).
  "$@" >"$out" || rc=$?
  cat "$out"
  [ "$rc" -eq 0 ] || return "$rc"
  repo="${GH_COMMENT_GUARD_CLAIM%#*}" pr="${GH_COMMENT_GUARD_CLAIM##*#}"
  id=$(grep -oE 'issuecomment-[0-9]+' "$out" | tail -1 | sed 's/issuecomment-//') || id=""
  # #2769: the POST has already landed, so a transient 5xx or a short
  # read-after-write delay on the readback must not report it unposted (a
  # polling rerun would then spend another slot). A failed read is retried a
  # bounded number of times, still inside the claim; a read that returns a
  # comment is final, so a mismatch is refused at once.
  attempts="${MERGEPATH_CODEX_REQUEST_READBACK_ATTEMPTS:-4}"
  delay="${MERGEPATH_CODEX_REQUEST_READBACK_DELAY_SECONDS:-1}"
  [[ "$attempts" =~ ^[1-9][0-9]?$ ]] || attempts=4
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=1
  comment=""
  if [ -n "$id" ]; then
    for ((attempt = 1; attempt <= attempts; attempt++)); do
      comment=$(unset GITHUB_TOKEN; GH_HOST=github.com GH_TOKEN="$TOKEN" \
        GH_ENTERPRISE_TOKEN="${GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL:-}" GITHUB_ENTERPRISE_TOKEN="${GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL:-}" \
        gh api "repos/$repo/issues/comments/$id" 2>/dev/null) || comment=""
      [ -z "$comment" ] || break
      [ "$attempt" -eq "$attempts" ] || sleep $((delay * attempt))
    done
  fi
  if [ -z "$id" ] || ! printf '%s' "$comment" | jq -e --arg author "$AUTHOR" --arg pr "$pr" --arg id "$id" \
       '(.id | tostring) == $id and ((.user.login // "") | ascii_downcase) == ($author | ascii_downcase)
        and .body == "@codex review" and ((.issue_url // "") | endswith("/issues/" + $pr))' >/dev/null 2>&1; then
    echo "comment-trigger-guard: the Codex request write for $repo#$pr returned without a confirmed comment id; refusing to treat it as posted (#1362). It may have landed: check the PR for the author's new Codex request comment and wait for Codex's response before requesting again. A polling rerun of scripts/codex-review-request.sh posts another request, spending a slot, unless Codex already reports that request Running on HEAD." >&2
    return 5
  fi
  exec 9>&-
  unset MERGEPATH_CODEX_REQUEST_CLAIM_HELD GH_COMMENT_GUARD_CLAIM
}

gh_comment_guard_authorize() {
  local metadata="$GH_COMMENT_GUARD_STATE/metadata.json" repo pr head result trigger
  trigger=$(jq -er '.trigger | if type == "boolean" then tostring else error("invalid trigger metadata") end' \
    "$metadata") || return 1
  if [ "$trigger" = false ]; then return 0; fi
  repo=$(jq -er .repo "$metadata") && pr=$(jq -er .pr "$metadata") && head=$(jq -er .head "$metadata") || return 1
  gh_comment_guard_claim "$repo" "$pr" || return 1
  # The recount only reads: its substitution's own shell closes fd 9 before
  # it runs, so a killed wrapper cannot leave a hung recount holding the
  # claim. Nothing that can write runs here.
  result=$(exec 9>&-; MERGEPATH_PHASE_4A_GATED=true MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD="$head" \
    GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-$TOKEN}" \
    "$ROOT/scripts/codex-review-request.sh" --authorize-trigger-write --allow-moving-head "$pr" "$repo") || return 1
  printf '%s' "$result" | jq -e --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg author "$AUTHOR" \
    '.authorized == true and .repo == $repo and .pr_number == $pr and .head_sha == $head and .author_identity == $author' >/dev/null
}

gh_comment_guard_cleanup() {
  [ -z "${GH_COMMENT_GUARD_STATE:-}" ] || python3 - "$GH_COMMENT_GUARD_STATE" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
