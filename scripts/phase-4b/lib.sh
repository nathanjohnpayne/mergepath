#!/usr/bin/env bash
# scripts/phase-4b/lib.sh — shared helpers for the Phase 4b automated
# review handoff (orchestrator + reviewer adapters).
#
# REFERENCE IMPLEMENTATION (#<this-feature>). Sourced, not executed; it
# does NOT set -euo pipefail on the caller. Bash 3.2 portable (macOS).
#
# Provides: config readers for the phase_4b_automation block and the
# top-level reviewer fields in .github/review-policy.yml, reviewer/
# direction selection, JSON-verdict validation (a jq mirror of
# verdict.schema.json), and small logging helpers. See
# plans/automated-phase-4b-handoff.md for the design.

# --- logging ---------------------------------------------------------------

p4b_log()  { echo "[phase-4b] $*" >&2; }
p4b_warn() { echo "[phase-4b] WARN: $*" >&2; }
# p4b_die <exit-code> <message...>
p4b_die()  { local c="$1"; shift; echo "[phase-4b] ERROR: $*" >&2; exit "$c"; }

# --- config location -------------------------------------------------------

# This library's own directory, captured at SOURCE time (when BASH_SOURCE is
# reliable — unlike call-time inside a function). Files that ship alongside
# lib.sh (e.g. verdict.schema.json) are resolved relative to this, so they
# are found regardless of $PWD or how the caller was invoked.
P4B_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the repo root from this library's own location (follow symlinks),
# NOT $PWD — the same posture scripts/phase-4b-classifier.sh uses so a
# PATH-symlinked or subdir invocation still finds the policy file.
p4b_repo_root() {
  local src="${BASH_SOURCE[0]}" link
  while [ -L "$src" ]; do
    link="$(readlink "$src")"
    case "$link" in
      /*) src="$link" ;;
      *)  src="$(cd -P "$(dirname "$src")" && pwd)/$link" ;;
    esac
  done
  # lib.sh lives at <root>/scripts/phase-4b/lib.sh → root is two dirs up.
  ( cd -P "$(dirname "$src")/../.." && pwd )
}

# The policy file. Overridable via MERGEPATH_REVIEW_POLICY_PATH (tests).
p4b_config() {
  if [ -n "${MERGEPATH_REVIEW_POLICY_PATH:-}" ]; then
    printf '%s' "$MERGEPATH_REVIEW_POLICY_PATH"
    return 0
  fi
  printf '%s/.github/review-policy.yml' "$(p4b_repo_root)"
}

# --- YAML readers (awk; mirrors the codex_field/policy_top_field style) ----

# p4b_automation_field <field> — scalar under the top-level
# `phase_4b_automation:` block. Empty string if absent; caller defaults.
# Nesting-aware (#615 Codex round 3): only DIRECT children of the block
# match. The block carries nested sub-blocks (e.g. `accounting.enabled`),
# and the previous flat scan matched a nested key as the parent-level
# field — a downstream policy that omitted or reordered the parent
# `enabled` would read the accounting sub-toggle as the master switch and
# wrongly run the orchestrator. The direct-child indent is captured from
# the first key line inside the block (so 2- and 4-space styles both
# work); deeper-indented lines belong to sub-blocks and never match —
# sub-block readers (p4b_acct_config_field, mirroring codex_p1_gate_field)
# own those.
p4b_automation_field() {
  p4b_policy_block_field phase_4b_automation "$1"
}

# p4b_policy_block_field <block> <field> — the same reader, generalized over
# the top-level block name (#814). Needed because the same-head barrier reads
# `codex.enabled` and `coderabbit.enabled`, and neither has a sourceable
# reader: the existing per-script `codex_field` / `coderabbit_field` copies
# live inside scripts whose top level runs work on source, and both are
# hardcoded to one block.
#
# The direct-child scoping is load-bearing for exactly the keys the barrier
# needs. `coderabbit.severity_gate.enabled`, `codex.p1_gate.enabled` and
# `codex.external_review_gate.enabled` all exist as NESTED `enabled:` keys, so
# a flat block scan returns whichever comes first in document order — a
# consumer that omits the optional top-level `enabled` would read a sub-gate
# toggle as the master switch and the barrier would guard on the wrong thing.
p4b_policy_block_field() {
  local block="$1" field="$2" cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk -v block="$block" -v field="$field" '
    /^[^[:space:]#]/ {
      if ($0 ~ "^" block ":") { inblk=1; child_indent=-1; next }
      inblk=0
    }
    inblk {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      indent = match($0, /[^[:space:]]/) - 1
      if (child_indent < 0) child_indent = indent
      if (indent > child_indent) next
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^["\047]/, "", $0)
        gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print; exit
      }
    }
  ' "$cfg"
}

# p4b_top_field <field> — a column-0 top-level scalar (author_identity,
# default_external_reviewer, phase_4b_default, ...).
p4b_top_field() {
  local field="$1" cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk -v field="$field" '
    /^[^[:space:]#]/ && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print; exit
    }
  ' "$cfg"
}

# --- same-head provider barrier: terminality (#814) -------------------------
#
# Each enabled provider arm resolves to exactly one class per probe:
#
#   reported          a terminal signal exists on THIS head
#   will-not-report   the provider will never post on this head
#   waived            it will not report in any useful window, and policy
#                     explicitly permits proceeding without it
#   not-yet           it has not posted on this head YET
#   rate-limited      it has REFUSED to report and no wait this run can make
#                     lasts long enough to lift the refusal (#1178)
#   escalate          a stuck condition only a human can clear
#
# `reported`, `will-not-report` and `waived` let the barrier open. `not-yet`
# is a bounded, self-clearing wait; `escalate` goes to the human immediately.
# `rate-limited` is the one class the CLASSIFIER cannot resolve on its own —
# it names the provider's state and the composer decides, because the answer
# depends on whether the OTHER provider reported. See p4b_same_head_barrier.
#
# `waived` is deliberately a separate class rather than reuse of `reported`,
# which would claim a report that never happened, or of `will-not-report`,
# which would claim permanence a rate limit does not have. It names the actual
# situation: a policy decision to proceed without this provider on this head.
#
# The split exists because treating "any terminal-looking rc" as satisfied
# makes the barrier a universal pass: rc 4 means "has not reported", and rc 6
# with skip_reason=paused means "is refusing to report until resumed" — the
# #593 false-clear precedent. Both must read as not-yet.

# p4b_barrier_class_coderabbit <head> <rc> <json>
# Maps one scripts/coderabbit-wait.sh result — polling or --probe — to a
# class. Pure: jq over the passed string only, no I/O, always returns 0.
p4b_barrier_class_coderabbit() {
  local head="$1" rc="$2" json="$3" probe_head probe_observed
  case "$rc" in
    0)
      # Terminal, but only for the head about to be approved. An rc 0
      # anchored on an older head is a stale clearance, and the #794 ordering
      # failure begins exactly there.
      probe_head="$(printf '%s' "$json" | jq -r '.head_sha // empty' 2>/dev/null || true)"
      if [ -n "$probe_head" ] && [ "$probe_head" = "$head" ]; then
        printf 'reported'
      else
        printf 'not-yet'
      fi
      ;;
    2)
      # NOT reported (Codex P1 on #842). In --probe mode rc 2 is the one
      # verdict the probe makes, and it means something specific: CodeRabbit
      # published a blocking `Potential issue`/⚠️ marker carried SOLELY by the
      # PR-level summary. #823 emits it precisely because no required gate
      # dispositions that class — coderabbit-severity-gate.sh reads only
      # pulls/{pr}/comments, the conversation gate covers threads, and the
      # Phase 4b adapter sees only the diff.
      #
      # So the barrier is the only thing that ever sees this signal. Folding it
      # in with rc 0 opened the barrier, ran the adapter, and let an approval
      # post over a finding nothing else would catch — and on the wave-audit
      # path that approval advances the watermark and authorises fan-out.
      # Escalate to a human, who is the only remaining reader.
      printf 'escalate' ;;
    6)
      # EVERY exit-6 skip is not-yet, including draft and non-base-branch.
      #
      # #814 originally specified those two as will-not-report, on the reading
      # that nothing will ever land on this head. That is wrong (Codex P1 on
      # #835): both are PR-level states that can change WITHOUT the head
      # changing. Marking a draft ready, or retargeting the base, makes
      # CodeRabbit review that same head — potentially after the Phase 4b
      # approval has posted, which is exactly the ordering race this barrier
      # exists to prevent. `paused` is the same shape and was already not-yet.
      #
      # AGENTS.md step 5 says the same thing about exit 6 generally: resolve
      # the skip cause rather than treating it as a clean clearance.
      #
      # So no rc yields will-not-report. That class is reachable only through
      # the provider being disabled in policy — coderabbit.enabled: false —
      # which the barrier checks before it ever calls this classifier, and
      # which cannot flip mid-flight on a live PR. Deviation from this issue's
      # change detail recorded on #814.
      printf 'not-yet'
      ;;
    4)
      # The poll budget elapsed with no review.
      printf 'not-yet' ;;
    7)
      # --probe found no terminal signal — but its rc-7 JSON can still CARRY
      # head-anchored terminal evidence (#869): the probe embeds the newest
      # HEAD-pinned review OBJECT (endpoint "reviews", selected by
      # .commit_id == head from the bot's own login) whenever one exists
      # while the summary publication is masked. On #866 the fair-use limit
      # note appended to the finished-review reply read the whole
      # publication as rate_limited while coderabbitai[bot] had two
      # COMMENTED review objects on the exact head (and a per-SHA
      # StatusContext success) — and the barrier held not-yet until its
      # budget escalated.
      #
      # The object alone is NOT enough (P1 on #875): CodeRabbit publishes
      # the review object and the PR-level summary as separate events, the
      # summary can carry the ONLY blocking marker (the #535 summary-only
      # class — e.g. the auto-pause note), and the probe deliberately
      # returns rc 7 observed=awaiting-summary for exactly that
      # mid-publication state. What discriminates the wedged-but-complete
      # #866 state from a just-posted object is the per-SHA CodeRabbit
      # StatusContext reading success on this head, which the probe samples
      # into probe.context_state on this one path (null when unsampled, or
      # when trust_status_context_for_clearance is false — both fail closed
      # here to not-yet).
      #
      # And the success must be TEMPORALLY CORRELATED with the object it
      # corroborates (#875 round 2): on a repeated CodeRabbit run against
      # the SAME sha the statuses endpoint still exposes the PREVIOUS
      # run's success while the new object's summary and status refresh
      # are pending — co-present, but from different runs. So the third
      # conjunct requires probe.context_updated_at (the status' refresh
      # time, sampled alongside the state) at-or-after review.submitted_at
      # (the evidence object's own timestamp, emitted for exactly this
      # comparison). Either field missing, or either timestamp
      # unparseable, fails closed to not-yet — old probe JSON simply keeps
      # the barrier on its pre-#869 bounded wait.
      #
      # Which object review.submitted_at names is settled upstream, and it
      # has to be a review RUN (#900): CodeRabbit also creates a review
      # object for a CONVERSATIONAL REPLY on a thread — its answer to a
      # rebuttal or to a resolve tag reply — and a reply starts no run, so
      # no further StatusContext is ever published for that head. Anchoring
      # on one made this comparison unsatisfiable rather than merely
      # pending, and the barrier burned its whole budget on a provider that
      # had finished. crw_select_head_pinned_review_run in
      # scripts/coderabbit-wait.sh excludes replies by their empty body, so
      # what arrives here is the newest run; with no run on the head the
      # probe emits no `review` at all and the first conjunct fails closed.
      #
      # And an ACTIVE adverse state named by the probe takes precedence
      # over the evidence pair (P1 round 3 on #875): probe.observed on
      # this branch is the class of the newest pending notice beneath the
      # review object, and rate_limit / paused / in_progress each assert
      # that CodeRabbit is NOT done here — a durable pause or a fresh
      # limit notice can be exactly what is holding the summary that
      # carries the only blocking marker, and a postdating spurious
      # success (#595) must not outrank the notice that names the real
      # state. Only the completion family opens: awaiting-summary (the
      # value this branch emits when nothing adverse is pending) or
      # terminal. A missing or unmodelled observed fails closed to
      # not-yet.
      #
      # With all conjuncts the claim matches what the Codex arm accepts
      # (#684): CodeRabbit has reviewed AND completed the head about to be
      # approved. Inline findings stay owned by
      # coderabbit-severity-gate.sh, so counting the set as reported skips
      # no disposition; the disclosed residual is a spurious success
      # (#595) landing on this exact head AND postdating the head's own
      # review object while its summary is still in flight WITH no adverse
      # notice pending, which would skip the #535 summary-only escalation.
      # endpoint must be "reviews": the probe's "issues" evidence on rc 7
      # is a pending notice or a prior-head summary, never head-anchored
      # terminality. The head equality is belt-and-braces on top of the
      # barrier's own drift check.
      probe_head="$(printf '%s' "$json" | jq -r '.head_sha // empty' 2>/dev/null || true)"
      probe_observed="$(printf '%s' "$json" | jq -r '.probe.observed // empty' 2>/dev/null || true)"
      # A REFUSAL is not a delay (#1178). `rate_limit` is the one observed
      # value on this branch that CodeRabbit will not leave on its own for
      # anything the barrier is allowed to do:
      #
      #   - p4b_barrier_should_trigger declines on rate_limit by design, so
      #     no request is ever sent for this head;
      #   - coderabbit-wait.sh's header records that CodeRabbit "does NOT
      #     auto-retry when the window elapses";
      #   - the one path that DOES re-ask is the polling mode's backoff
      #     retry, which --probe cannot reach — it "posts NOTHING".
      #
      # So `not-yet` bought a bounded wait nothing could satisfy: the run
      # spent the whole coderabbit.max_wait_seconds and then escalated
      # naming a timeout rather than the refusal (#826 measured the budget
      # at roughly half the observed window, so it stalls on arrival). And
      # the observation need not age out — on the review-object branch the
      # limit stanza is written into the summarize comment IN PLACE, whose
      # fresh_at stays at-or-after the review object, so the anchored
      # expiry the triage relies on never arrives.
      #
      # Deliberately NOT head-anchored, unlike the `reported` conjunction
      # below. A rate limit is provider-level state, the same shape as a
      # pause — "a paused CodeRabbit cannot report on ANY head" — and the
      # composer's own drift check already owns the head question, so
      # requiring head equality here would only re-answer it while letting
      # an old-probe payload with no head_sha fall back to a wait that
      # cannot end.
      #
      # This arm names the state and stops. Whether it opens the barrier or
      # pages a human depends on the CODEX arm, which a pure function over
      # one CodeRabbit probe cannot see — the same split the #842 drift fix
      # drew, for the same reason.
      if [ "$probe_observed" = "rate_limit" ]; then
        printf 'rate-limited'
      elif [ -n "$probe_head" ] && [ "$probe_head" = "$head" ] \
         && { [ "$probe_observed" = "awaiting-summary" ] || [ "$probe_observed" = "terminal" ]; } \
         && [ "$(printf '%s' "$json" | jq -r '.review.endpoint // empty' 2>/dev/null || true)" = "reviews" ] \
         && [ "$(printf '%s' "$json" | jq -r '.probe.context_state // empty' 2>/dev/null || true)" = "success" ] \
         && [ "$(printf '%s' "$json" | jq -r '
                  (.review.submitted_at // "") as $r
                  | (.probe.context_updated_at // "") as $c
                  | if $r == "" or $c == "" then false
                    else (try (($c | fromdateiso8601) >= ($r | fromdateiso8601)) catch false)
                    end' 2>/dev/null || true)" = "true" ]; then
        printf 'reported'
      else
        printf 'not-yet'
      fi
      ;;
    5)
      # rate_limit_stalled. AGENTS.md step 5 routes this to a human UNLESS the
      # #489 Codex failover engaged, in which case the stall is a non-blocking
      # note: the failover has already requested @codex review and the Codex
      # arm now owns reaching terminality. Escalating regardless would demand a
      # manual fallback on every rate-limited run where the failover worked —
      # not rare, since CodeRabbit rate-limited on five consecutive heads
      # during #823. (Codex P2 on #835, raised twice.)
      if [ "$(printf '%s' "$json" | jq -r '.codex_failover_requested // false' 2>/dev/null || true)" = "true" ]; then
        # WAIVED, not not-yet (Codex P2 on #835 round 4 — my round-3 fix chose
        # the wrong class). not-yet still blocks until the retry budget expires
        # and then escalates, which is the manual fallback the failover exists
        # to avoid; the arm has to actually open. The Codex arm carries the
        # ordering from here, which is what AGENTS.md means by non-blocking.
        printf 'waived'
      else
        printf 'escalate'
      fi
      ;;
    *)
      # 3 (infra) and anything unmodelled. Fail closed to the human rather
      # than guessing.
      printf 'escalate' ;;
  esac
}

# p4b_barrier_class_codex <rc>
# Maps one scripts/codex-review-check.sh result to a class.
#
# The caller MUST invoke the delegate with all five overrides:
#
#   CODEX_REVIEW_CHECK_SKIP_CI=1                      (env)
#   CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1     (env)
#   CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE=false (env)
#   --diagnostic-signal-only                          (FLAG, not env)
#
# so that rc 0 means "Codex itself has spoken on THIS head" rather than "the
# merge gate passes". The flag skips gate (b) and disables the #705
# same-content carry-forward, which is consulted precisely when the current
# head has NO Codex signal — correct for a merge gate, since the reviewed
# content is identical, and wrong here, where the contract is head identity.
# Without it the barrier can open before Codex has spoken on the head about to
# be approved (Codex P1 on #835).
#
# It is a flag rather than an env var because it WEAKENS a required gate and
# environment variables are inherited: as an env var the merge-gate callers
# would pick it up by accident (CodeRabbit Major on #835).
#
# Codex has no will-not-report state: it is either asked or not.
# rc 2 is diagnostic-mode-only and means Codex CANNOT report on this head: it
# answered a trigger with an account-/connection-level block (quota exhausted,
# App not connected). That is not review latency and waiting cannot fix it, so
# it must NOT hold the run — Phase 4b is the documented fallback for exactly
# that state, and codex-review-check.sh's own failure message says to route
# there. Treating it as not-yet made the barrier wait out its whole budget and
# then page a human, so the automated leg could never serve its fallback role
# (Codex P1 on #842). Waived, not reported: Codex has cleared nothing, it is
# simply no longer something this head can be ordered against.
p4b_barrier_class_codex() {
  case "$1" in
    0) printf 'reported' ;;
    1) printf 'not-yet' ;;
    2) printf 'waived' ;;
    *) printf 'escalate' ;;
  esac
}

# --- same-head provider barrier: bounded not-yet retry (#814) ---------------
#
# phase-4b-review.sh is one-shot, so "retry until a bound" cannot be an
# in-process sleep without holding the process open for up to the full
# coderabbit.max_wait_seconds at each of two evaluation points. The bound
# instead rides a marker keyed to (repo, PR, head), written on the first
# not-yet for that head and removed on every other outcome.
#
# Whose clock: the LOCAL clock of the trusted checkout running the
# orchestrator — the same one the accounting hooks already use. Deliberately
# NOT a GitHub timestamp, and deliberately not the head committer date, which
# the pusher controls.
#
# The marker asserts no provider event. It records only "this checkout began
# waiting at T"; terminality comes solely from the probe rc and its head_sha,
# so no value of the clock can turn a not-yet provider into a reported one.
# Both tamper directions fail safe: an artificially OLD marker exhausts the
# budget early and hands the PR to a human, posting no review; a missing, new,
# or future-dated marker restarts the budget and the barrier keeps returning
# pending — also posting no review. The clock decides only WHEN to stop
# retrying and involve a human, which is conservative either way.

# Wall-clock bound for the pending wait, from coderabbit.max_wait_seconds.
# A malformed value falls back to the default rather than failing closed: this
# governs only when a human is called, so a bad parse must not deadlock.
p4b_barrier_budget_seconds() {
  local raw
  raw="$(p4b_policy_block_field coderabbit max_wait_seconds)"
  case "$raw" in
    ''|*[!0-9]*) printf '1245' ;;
    *) printf '%s' "$raw" ;;
  esac
}

p4b_barrier_marker_path() {  # <repo> <pr> <head>
  local repo_slug state
  repo_slug="$(printf '%s' "${1:-unknown}" | tr '/' '-')"
  # Honour P4B_ACCT_STATE_DIR directly rather than calling
  # p4b_acct_state_dir, which lives in accounting.sh. lib.sh must not depend
  # on that module being loaded: the orchestrator sources it, but a caller
  # sourcing lib.sh alone would silently fall back to the real repo state dir
  # and write markers into the working tree. Same env var, same default, so
  # the two agree wherever both are present.
  state="${P4B_ACCT_STATE_DIR:-$(p4b_repo_root)/.mergepath}"
  printf '%s/phase-4b-barrier/%s-pr%s-%s.pending' \
    "$state" "$repo_slug" "${2:-0}" "${3:-nohead}"
}

# p4b_barrier_canon_epoch <raw>
# Print <raw> as a plain base-10 integer usable in BOTH `[ -gt ]` and `$(( ))`,
# or print nothing and return 1 when it is not (#840).
#
# "Digit-only" is not enough, because the two readers disagree on a digit run
# that is not canonical decimal. `[ -gt ]` parses base 10 always; `$(( ))`
# reads a leading zero as OCTAL. So a marker of `0755` compares as 755 and
# subtracts as 493 — measured on origin/main as an elapsed of ~1.79e9 seconds,
# which exhausts any budget on the first read and hands every retry to a human.
# `0899` is not a legal octal literal at all: the arithmetic expansion fails
# outright ("value too great for base") and note_pending returns non-zero with
# no elapsed. And a digit run wider than int64 makes `[ -gt ]` error with
# "integer expression expected" while `$(( ))` wraps to a NEGATIVE elapsed,
# which reads as "barely started" and leaves the wait unbounded.
#
# Stripping the leading zeros makes both readers agree on base 10; the width
# cap keeps every later comparison total. 18 digits is the widest run that
# cannot overflow a signed 64-bit integer, and anything that wide is still
# accepted as a value — it simply lands in the future-dated repair branch,
# which is the conservative direction.
p4b_barrier_canon_epoch() {
  local raw="${1:-}" stripped
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  stripped="${raw#"${raw%%[!0]*}"}"
  [ -n "$stripped" ] || stripped=0
  [ "${#stripped}" -le 18 ] || return 1
  printf '%s' "$stripped"
}

# Plausibility floor for a marker epoch. Canonicalising `0755` to 755 makes the
# two readers AGREE, but they agree on a 1970 timestamp: elapsed comes out near
# 1.79e9 seconds, every budget is exhausted on the first read, and the barrier
# pages a human on a corrupt file — forever, because nothing repairs it. So the
# range check is the other half of #840, not a nicety. Any marker this code
# wrote came from `date +%s`, so a value below 2001-09-09 cannot be one; the
# floor is far under every real timestamp and far over every artefact of the
# short-digit corruption class. The too-NEW side needs no constant: a
# future-dated value is already repaired by the clock-skew branch below.
P4B_BARRIER_MIN_EPOCH=1000000000

# p4b_barrier_note_pending <repo> <pr> <head>
# Record the first not-yet for this head and print the seconds elapsed since
# it. Prints 0 on the first observation. Advisory: if the state dir cannot be
# written the wait simply never accumulates, so the barrier keeps returning
# pending rather than escalating early — the safe direction.
p4b_barrier_note_pending() {
  local marker started now canon
  marker="$(p4b_barrier_marker_path "$1" "$2" "$3")"
  now="$(date +%s)"
  if [ -f "$marker" ]; then
    started="$(cat "$marker" 2>/dev/null || true)"
  else
    mkdir -p "$(dirname "$marker")" 2>/dev/null || true
    printf '%s\n' "$now" >"$marker" 2>/dev/null || true
    started="$now"
  fi
  canon="$(p4b_barrier_canon_epoch "$started" 2>/dev/null || true)"
  if [ -z "$canon" ] || [ "$canon" -lt "$P4B_BARRIER_MIN_EPOCH" ]; then
    # A crash or partial write can leave the marker empty, non-numeric, a digit
    # run the two readers disagree on, or a value no clock could have produced
    # (#840). Returning 0 without repairing it means every later one-shot
    # invocation reads the same invalid value, reports the same nonsense
    # elapsed, and the bound never behaves — either the manual fallback is
    # never reached (wait unbounded) or it is reached immediately on every
    # retry (a human paged for a corrupt file). Reinitialize instead.
    printf '%s\n' "$now" >"$marker" 2>/dev/null || true
    printf '0'
    return 0
  fi
  started="$canon"
  if [ "$started" -gt "$now" ]; then
    # Future-dated marker (clock skew or tampering): treat as fresh rather
    # than producing a negative elapsed, so the budget restarts. Rewrite it,
    # or every later invocation restarts the budget again and the wait never
    # exhausts — the same unbounded-retry defect as the invalid-value case.
    printf '%s\n' "$now" >"$marker" 2>/dev/null || true
    printf '0'
    return 0
  fi
  printf '%s' "$(( now - started ))"
}

# p4b_barrier_claim_root
# Where claims live. Deliberately NOT the checkout's state dir (#858): the
# pending marker measures how long THIS checkout has waited and is rightly
# per-checkout, but a claim is a reservation over a shared external resource —
# the PR timeline — so scoping it to the checkout serialized nothing between
# two Phase 4b invocations run from two trusted checkouts, and both posted.
#
# Per-user, per-HOST, checkout-independent. The host component is load-bearing
# rather than cosmetic: ownership is a PID (below), and PIDs are comparable
# only within one machine. On a networked or synced home directory a bare
# shared root would let machine B read machine A's live PID, find some
# unrelated local process alive at that number, and decline forever — or find
# it dead and steal a live claim. Keying the root by host keeps the PID test
# meaning what it says, at the cost of not coordinating across machines, where
# no filesystem lock could have coordinated anyway.
#
# Falls back to the old per-checkout location only when there is no home to
# anchor on, which preserves today's behaviour rather than failing closed in a
# configuration that has always worked.
#
# Residue: a process killed inside the region strands one directory holding one
# pid file. It is reaped by the next claimant on the same key, so an active key
# self-heals; a key never revisited (an old PR head) just leaves the empty pair
# behind. The whole root is safe to delete when no Phase 4b run is in flight —
# the durable record of what was posted is the timeline marker, never a claim.
#
# EVERY branch is ABSOLUTE BY CONSTRUCTION: each `printf` is either guarded by
# a `/*` case or derived from `p4b_repo_root`, which resolves through `cd -P`.
#
# A RELATIVE operator-supplied root is IGNORED rather than used, and the next
# branch decides. This is the one treatment that keeps the guarantee #858 is
# about. Anchoring a relative root at `$PWD` — the intermediate shape this
# function briefly carried — makes it absolute without making it
# checkout-independent: two invocations started from two directories still
# expand the same relative override to two different roots, which is the split
# reintroduced through an operator-supplied directory instead of through the
# default (CodeRabbit round 1 asked for reject-or-absolutise; Codex P2 round 2
# showed that absolutise-at-cwd is not enough, and both are satisfied by
# ignoring). It also matches what the XDG base-directory spec already requires
# of a reader for a relative `XDG_STATE_HOME`, so all three variables now obey
# one rule instead of three.
#
# Falling through is safe in every direction: an ignored `P4B_CLAIM_DIR` lands
# on the shared per-user root, which is *more* serialized than what the
# operator asked for, never less.
#
# An override chooses the BASE, never the host scoping — see the comment on the
# host component below.
p4b_barrier_claim_root() {
  local base host
  # Pick the BASE. Each branch is absolute or it does not win.
  base=""
  case "${P4B_CLAIM_DIR:-}" in /*) base="$P4B_CLAIM_DIR" ;; esac
  if [ -z "$base" ]; then
    case "${XDG_STATE_HOME:-}" in /*) base="$XDG_STATE_HOME/mergepath/write-claims" ;; esac
  fi
  if [ -z "$base" ]; then
    case "${HOME:-}" in /*) base="$HOME/.local/state/mergepath/write-claims" ;; esac
  fi
  if [ -z "$base" ]; then
    # No home to anchor on: today's per-checkout location.
    case "${P4B_ACCT_STATE_DIR:-}" in
      /*) base="$P4B_ACCT_STATE_DIR" ;;
      *)  base="$(p4b_repo_root)/.mergepath" ;;
    esac
  fi
  # The host component belongs to the CLAIM NAMESPACE, not to the base, so it
  # is appended on every branch including an explicit override (Codex P2, round
  # 3). Ownership is a machine-local PID; point the override at NFS or a synced
  # directory and, without this, host B reads host A's live PID, finds some
  # unrelated local process at that number and either reaps a live claim or
  # holds the barrier against a dead one. Host-scoping declines to coordinate
  # across machines — which no filesystem lock over PIDs could have done
  # anyway — instead of coordinating them wrongly.
  host="$(uname -n 2>/dev/null || true)"
  host="$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '_' 2>/dev/null || true)"
  printf '%s/%s' "$base" "${host:-localhost}"
}

# p4b_barrier_claim_path <repo> <pr> <key> <kind>
# One path per (repo, PR, key, write class) so a resume claim and a trigger
# claim can never be read for one another (#846, #847), under the shared root
# above so every checkout on this machine contends for the same one (#858).
#
# The repo slug is INJECTIVE (Codex P2, round 2). `tr '/' '-'` mapped
# `foo-bar/baz` and `foo/bar-baz` onto one slug — harmless while claims lived
# under the checkout's own state dir, and newly reachable now that #858 puts
# every repo on this machine under one root, where a collision lets one run
# decline or reap another repository's live claim. `%` is not a legal character
# in a GitHub owner or repository name, so `/` → `%2F` cannot be forged by any
# real slug and the encoding is reversible. Claims carry no durable meaning —
# the record of what was posted is the timeline marker — so re-spelling the
# path costs nothing beyond one stranded empty directory per in-flight run.
#
# Case is CANONICALISED first (Codex P2, round 3). GitHub repository identity
# is case-insensitive, so `--repo Owner/Repo` and `--repo owner/repo` name one
# repository and must reserve one claim; on a case-sensitive filesystem they
# otherwise took two directories and both entered the region. Folding case is
# not a loss of injectivity for the same reason it is needed — the spellings it
# merges are the same repository.
p4b_barrier_claim_path() {
  local repo_slug
  repo_slug="$(printf '%s' "${1:-unknown}" | tr 'A-Z' 'a-z' | sed 's|/|%2F|g')"
  printf '%s/phase-4b-barrier/%s-pr%s-%s.%s.claim' \
    "$(p4b_barrier_claim_root)" "$repo_slug" "${2:-0}" "${3:-nohead}" "${4:-trigger}"
}

# p4b_barrier_self_pid — sets P4B_SELF_PID to the PID of the process executing
# THIS shell, which inside a subshell is not `$$`.
#
# Sets a variable rather than printing, deliberately: reading it back through
# `$(p4b_barrier_self_pid)` would fork one more subshell and measure THAT one,
# reintroducing the very misattribution this closes.
#
# Bash 3.2 — the macOS system shell and this library's stated portability floor
# — has no BASHPID, so `${BASHPID:-$$}` alone would leave every macOS run with
# the defect. A command substitution forks exactly one child and execs the
# simple command inside it, so that child's PPID is this shell: the value
# BASHPID would have printed. Measured on 3.2.57 against a background
# subshell's own `$!`. `$$` stays the last resort, which is today's behaviour.
p4b_barrier_self_pid() {
  if [ -n "${BASHPID:-}" ]; then
    P4B_SELF_PID="$BASHPID"
    return 0
  fi
  P4B_SELF_PID="$(exec sh -c 'echo $PPID' 2>/dev/null)" || P4B_SELF_PID=''
  case "$P4B_SELF_PID" in
    ''|*[!0-9]*) P4B_SELF_PID="$$" ;;
  esac
}

# p4b_barrier_claim <path>
# mkdir(2) is create-or-fail with no window between test and set: exactly one
# caller creates the directory, every concurrent other gets EEXIST. Returns 0
# only to the winner; an unusable state dir also returns non-zero, and the
# caller DECLINES to write (#846) — pending is already set before any write
# runs, so the bound and the human escalation stand either way.
#
# Deliberately no timestamp and no clock-based stale-breaking: every such
# rule either steals a live claim (two writes — the failure this exists to
# prevent) or strands a second one. Ownership is the winner's PID instead:
# claims are per-HOST by construction (see p4b_barrier_claim_root), so a
# recorded owner that is no longer alive on this machine proves abandonment,
# and only the NEXT claimant breaks it — never any concurrent evaluation. A
# clear_pending that removed claims was the round-1 defect here: an open or
# drift outcome in one invocation deleted another invocation's LIVE claim
# mid-region, and a third retry could then re-claim and double-post.
#
# The owner recorded is BASHPID, not `$$` (#859). `$$` is the PID of the
# shell that STARTED bash and does not change inside a subshell, and every
# caller reaches this through `out="$(p4b_barrier_maybe_write …)"` — a command
# substitution, hence a subshell. Recording `$$` therefore named a process
# that is not the one executing the claimed region, and got the liveness test
# backwards in both directions: when the subshell died the parent stayed
# alive, so the claim read as held and NO later claimant could ever reap it;
# and when the parent died first the claim read as abandoned, so another
# caller could reap it while the original subshell was still mid-post — then
# the original's release deleted the successor's live claim. BASHPID names the
# process actually inside the region — see p4b_barrier_self_pid above, which
# obtains it on bash 3.2 too.
p4b_barrier_claim() {
  # Resolve the owner BEFORE the mkdir gate. A claim directory whose pid file
  # is not yet written reads as ownerless, and ownerless is unreclaimable by
  # construction (below: an unparseable owner declines, and release refuses a
  # claim it does not own) — a permanently stuck key, which is fail-closed but
  # still a stuck key. On bash 3.2 the lookup forks a subshell and costs ~34x a
  # BASHPID read, so doing it after mkdir would widen that window by the same
  # factor for exactly no benefit: the value is a property of THIS shell and
  # does not depend on winning. Ordered this way the window is one printf.
  p4b_barrier_self_pid
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  if ! mkdir "$1" 2>/dev/null; then
    local owner
    owner="$(cat "$1/pid" 2>/dev/null || true)"
    case "$owner" in
      ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$owner" 2>/dev/null && return 1
    # Takeover is SERIALIZED and REVALIDATED. A bare rename is not enough:
    # the winner recreates the path, so a second reaper that read the same
    # dead owner earlier can rename the winner's LIVE claim away (Codex P2,
    # rounds 2 and 5). The reap lock is held for microseconds; a reaper that
    # crashes inside it strands the lock and every later claim declines —
    # the bounded-escalation direction, never a double post. Re-reading the
    # owner under the lock is what closes the both-read-dead window: the
    # second reaper sees the winner's live PID and declines.
    mkdir "$1.reaplock" 2>/dev/null || return 1
    owner="$(cat "$1/pid" 2>/dev/null || true)"
    if [ -z "$owner" ] || kill -0 "$owner" 2>/dev/null; then
      rmdir "$1.reaplock" 2>/dev/null || true
      return 1
    fi
    rm -rf "$1" 2>/dev/null || true
    if ! mkdir "$1" 2>/dev/null; then
      rmdir "$1.reaplock" 2>/dev/null || true
      return 1
    fi
    rmdir "$1.reaplock" 2>/dev/null || true
  fi
  printf '%s\n' "$P4B_SELF_PID" >"$1/pid" 2>/dev/null || { rm -rf "$1" 2>/dev/null; return 1; }
}

# p4b_barrier_release [path]
# Release a claim THIS process holds. Ownership-aware (#859): a claim whose
# recorded owner is not us belongs to a successor that reaped our abandoned
# claim, and removing it would drop a live reservation mid-write — the exact
# double-post the claim exists to prevent. A foreign or missing owner is left
# alone; the next claimant's dead-owner check is what reclaims it. An EMPTY
# path is a no-op, not an error: a dry run takes no claim and still runs the
# same release path. The ownership test is also what makes `rm -rf` safe here
# — it can only match a directory this process created.
p4b_barrier_release() {
  local path="${1:-}"
  [ -n "$path" ] || return 0
  p4b_barrier_self_pid
  [ "$(cat "$path/pid" 2>/dev/null || true)" = "$P4B_SELF_PID" ] || return 0
  rm -rf "$path" 2>/dev/null || true
}

# p4b_barrier_clear_pending <repo> <pr> <head>
# Drop the marker only. Called on every non-not-yet outcome so a later
# not-yet on the same head starts a fresh budget instead of inheriting a
# stale one. Claims are deliberately NOT touched here: only their winner
# releases them, and abandonment is broken by the next claimant's dead-owner
# check above.
p4b_barrier_clear_pending() {
  rm -f "$(p4b_barrier_marker_path "$1" "$2" "$3")" 2>/dev/null || true
}

# --- #814 CodeRabbit arm: trigger, do not only wait -------------------------
#
# The barrier point is also the right trigger point: it fires only once Codex
# is terminal on the head, which is exactly the settled head worth spending
# CodeRabbit's allowance on. A pure waiter is sound ONLY while
# reviews.auto_review.auto_incremental_review is true. Turn that off (#826
# step 2) and nothing asks CodeRabbit to look at a Phase 4b head: the probe
# returns observed=none forever, the bound exhausts, and every Phase 4b
# escalates to a human — a cost problem converted into a throughput problem.
# Design change recorded on #814.

# The idempotency anchor is a SHA-bearing marker, deliberately NOT "a trigger
# comment newer than the head". That would reintroduce the defect fixed on
# #823 in 0955ac8: the head committer date is set by whoever pushed, so a
# future-dated head makes every prior trigger look stale and the arm re-posts
# on every bounded retry — multiplying straight into the allowance this exists
# to conserve. The probe cannot close it either: between posting and
# CodeRabbit reacting, observed is still `none`, which is the same sub-minute
# race that produced two @codex review triggers on #820.
# p4b_barrier_marker_prefix <kind> <key>
# The marker without its closing delimiter, so a family of keys sharing a
# prefix can be matched with one `contains`. Sole definition of the marker
# spelling — p4b_barrier_marker closes it — because a second copy of the
# format string is a second thing to keep in sync with live PR bodies.
p4b_barrier_marker_prefix() {
  printf '<!-- mergepath-coderabbit-%s:%s' "${1:-trigger}" "${2:-nohead}"
}

# p4b_barrier_marker <kind> <head>   kind ∈ trigger | resume
# Two write classes, two markers (#847). A resume satisfying the trigger's
# "already spent" test would suppress the review request for this head
# forever; a trigger satisfying the resume's would leave a paused bot paused.
# The trigger spelling is kept byte-identical to the pre-#847 literal — live
# PRs already carry it.
p4b_barrier_marker() {
  printf '%s -->' "$(p4b_barrier_marker_prefix "${1:-trigger}" "${2:-nohead}")"
}

p4b_barrier_trigger_marker() {
  p4b_barrier_marker trigger "${1:-nohead}"
}

# p4b_barrier_trigger_posted <head> <reviewer_login> <issue_comments_json>
# True when this automation already spent the head's one request. The marker
# must sit on a comment authored by the reviewer identity: an unscoped body
# search is forgeable and cannot establish that automation posted it.
p4b_barrier_trigger_posted() {
  p4b_barrier_write_posted trigger "$1" "$2" "$3"
}

# p4b_barrier_write_count <kind> <key> <reviewer_login> <issue_comments_json> [since] [family_key]
# Prints how many spent-marks of this kind the reviewer identity has on the
# timeline for this key. Author-scoped for the same reason the boolean was;
# the count costs nothing extra (same read) and makes a cross-checkout
# duplicate — the #846 race observed after the fact — visible to the caller
# as `already-…-duplicate` instead of silently indistinguishable from the
# normal already-spent case.
#
# THE MARKER ARM HAS TWO HALVES when a <family_key> is given (the resume kind
# — see p4b_barrier_maybe_resume for how the two keys are formed):
#
#   exact <key>   — counted regardless of age. <key> pins the pause note AND
#                   the head, and re-pausing costs the bot new reviewed
#                   commits, which costs a new head, so within one head our
#                   own marked resume is unconditionally the answer to this
#                   note. This half is what makes the dedup idempotent across
#                   an IN-PLACE EDIT of the note: CodeRabbit edits one pause
#                   comment (a Finishing-Touches checkbox tick bumps it) and
#                   every freshness-derived identity — a fresh_at in the key,
#                   or a fresh_at conjunct on its own — mints a new episode on
#                   each edit and posts again. The head does not move when the
#                   note is edited, so this half cannot be bumped that way.
#   <family_key>  — any marked resume for the SAME pause note under a
#                   different head, counted only when it was created at or
#                   after <since> (the note's CodeRabbit-owned fresh_at). This
#                   is #862's second remedy and it carries the cross-head
#                   dedup round 1 asked for: a standing pause note that has
#                   not changed since we answered it is still answered, so a
#                   Codex-forced push does not buy a second resume, while a
#                   note REWRITTEN after our resume (the new pause episode
#                   #862 is about) is not, and the recovery fires again. `>=`,
#                   not `>`: second-precision timestamps let our own resume
#                   tie the note it answers, and a tie is an answer.
#                   With <since> empty — a note whose freshness we could not
#                   read — the family counts unconditionally, i.e. the
#                   historical at-most-once per note id, which spends nothing.
#
# <family_key> MUST end with the key separator (`pause-771-`, never
# `pause-771`): the family is matched as a marker PREFIX, and the separator is
# what stops note 771's family from also matching note 7710's keys. The family
# match additionally accepts the pre-#862 id-only marker spelling — the family
# key minus that trailing separator — so a PR already carrying one from an
# earlier run is not resumed a second time on the first run after this ships.
#
# Residual, deliberately: a new head PLUS an in-place edit of a standing note
# satisfies neither half and buys one extra resume — bounded at one per head,
# where the pre-fix shape was one per edit.
#
# For the resume kind, a BARE `@<bot> resume` first line also counts when it
# was created after <since>: coderabbit-wait.sh's own pause recovery posts
# exactly that body with no marker, and two dedup vocabularies that cannot
# read each other's writes double-post against one pause note (Codex P2,
# round 2). Neither timestamp is pusher-controlled. STRICTLY later here, not
# >=: GitHub timestamps carry second precision, so a prior episode's resume
# can tie the new note's fresh_at — counting it would leave the new pause
# unrecovered until escalation, while not counting it risks at worst one
# duplicate resume inside a one-second window (Codex P2, round 5). The bare
# form deliberately gets NO head-scoped half: it carries no pause-note id, so
# a head-scoped bare resume would suppress every later pause note on that
# same head.
#
# Author scope: the marker arm stays pinned to the SELECTED reviewer — the
# marker proves this automation spent the key. The bare arm accepts every
# identity in available_reviewers (plus the selected one), matching
# coderabbit-wait.sh's own allowlist: its resume may have been posted under
# a different trusted identity (the authoring session's PAT vs this Phase 4b
# session's), and a single-identity filter posts a second resume over it
# (Codex P2, round 3).
p4b_barrier_write_count() {
  local m fam legacy trusted bot
  m="$(p4b_barrier_marker "$1" "$2")"
  fam=""
  legacy=""
  if [ -n "${6:-}" ]; then
    fam="$(p4b_barrier_marker_prefix "$1" "$6")"
    legacy="$(p4b_barrier_marker "$1" "${6%-}")"
  fi
  trusted="$(p4b_available_reviewers 2>/dev/null | jq -R . 2>/dev/null | jq -sc . 2>/dev/null || printf '[]')"
  case "$trusted" in '['*) ;; *) trusted='[]' ;; esac
  # The bare form is the CONFIGURED bot's exact command, compared as a string
  # — a wildcard mention pattern counted any trusted reviewer's `@renovate
  # resume` as the CodeRabbit recovery and suppressed the real one (Codex P2,
  # round 4). Same login source and [bot]-strip as the poster.
  bot="$(p4b_policy_block_field coderabbit bot_login)"
  bot="${bot:-coderabbitai}"
  bot="${bot%\[bot\]}"
  printf '%s' "${4:-[]}" | jq --arg m "$m" --arg fam "$fam" --arg legacy "$legacy" \
    --arg who "${3:-}" --arg since "${5:-}" \
    --arg cmd "@${bot} resume" --argjson revs "$trusted" '
    [.[]? | select(
        (((.user.login // "") == $who)
         and (((.body // "") | contains($m))
              or ($fam != ""
                  and (((.body // "") | contains($fam))
                       or ((.body // "") | contains($legacy)))
                  and ($since == "" or ((.created_at // "") >= $since)))))
        or ($since != ""
            and ((.user.login // "") as $l | (($l == $who) or ($revs | index($l) != null)))
            and ((.created_at // "") > $since)
            and ((((.body // "") | split("\n")[0]) | rtrimstr(" ") | rtrimstr("\r")) == $cmd)))]
    | length' 2>/dev/null || printf '0'
}

p4b_barrier_write_posted() {
  [ "$(p4b_barrier_write_count "$1" "$2" "$3" "$4")" -gt 0 ]
}

# p4b_barrier_should_trigger <observed>
# Which probe `observed` values mean "nobody has asked about THIS head, and
# asking would help".
#
# Everything else declines. in_progress / rate_limit / paused are #814's three
# named cases: someone already asked, or asking again cannot help — re-asking
# on rate_limit spends allowance the provider has already refused, and on
# in_progress spends a second review on a head already being read. Both burn
# the same five-per-hour pool this exists to conserve. `awaiting-summary` is
# the same shape (a review object IS pinned to this head), and any unmodelled
# value declines too: a wrong trigger spends allowance, while a missing one
# only ends in the bounded escalation to a human.
#
# `summary-without-head-review` is a deviation from #814's change detail,
# which named only `none` — recorded on #814. It means the bot spoke about an
# EARLIER head with nothing pinned to this one, so for this head nobody has
# asked, which is `none` as far as the barrier is concerned.
p4b_barrier_should_trigger() {
  case "${1:-}" in
    none|summary-without-head-review) return 0 ;;
    *) return 1 ;;
  esac
}

# p4b_barrier_post_trigger <repo> <pr> <head> <reviewer> [kind]
# Post the one permitted write of this kind for this head, carrying its
# marker. Routed through gh-as-reviewer.sh because `gh pr comment` is a
# guarded write and the marker's whole value is that an identity-verified
# account authored it. This is deliberately the ONLY gh-write call site the
# barrier has — both kinds share it, so the lint surface and the identity
# discipline stay in one place.
p4b_barrier_post_trigger() {
  local repo="$1" pr="$2" head="$3" reviewer="$4" kind="${5:-trigger}" verb
  case "$kind" in
    # `resume`, never `review`, for the paused recovery (#847): the auto-pause
    # note is durable and only the resume command lifts it — a review request
    # to a paused bot is refused outright.
    resume) verb=resume ;;
    *)      verb=review; kind=trigger ;;
  esac
  # Uppercase *_AS_REVIEWER deliberately: check_no_bare_gh_writes exempts a
  # wrapped write only when the wrapper is a literal gh-as-*.sh path or a
  # variable matching [A-Z_]*AS_(AUTHOR|REVIEWER). A lowercase holder reads as
  # a bare `gh pr comment` and fails the gate — correctly, since the gate
  # cannot tell what a lowercase variable points at.
  local WRAPPER_AS_REVIEWER body bot rc=0
  WRAPPER_AS_REVIEWER="${P4B_GH_AS_REVIEWER:-$(p4b_repo_root)/scripts/gh-as-reviewer.sh}"
  [ -x "$WRAPPER_AS_REVIEWER" ] || return 1
  # Mention the CONFIGURED bot, not a hardcoded @coderabbitai (Codex P2 on
  # #842). coderabbit-wait.sh probes activity from coderabbit.bot_login, so a
  # consumer that overrides it would have the request addressed to an account
  # that never answers while the probe keeps observing `none` — the barrier
  # then burns its whole budget and escalates on every PR in that repo. Strip
  # the REST-only `[bot]` suffix, as the existing retry and resume paths do.
  bot="$(p4b_policy_block_field coderabbit bot_login)"
  bot="${bot:-coderabbitai}"
  bot="${bot%\[bot\]}"
  body="$(printf '@%s %s\n\n%s\n' "$bot" "$verb" "$(p4b_barrier_marker "$kind" "$head")")"
  env -u OP_PREFLIGHT_REVIEWER_PAT GH_AS_REVIEWER_IDENTITY="$reviewer" \
    "$WRAPPER_AS_REVIEWER" -- gh pr comment "$pr" --repo "$repo" --body "$body" \
    >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# p4b_barrier_maybe_write <kind> <repo> <pr> <key> <reviewer> <dry_run> [since] [family_key] [claim_key]
# claim -> read -> dedup -> post at most once, for either write class. Prints
# the action taken; never fails the caller, because a write that could not be
# posted still leaves the bounded retry and the human escalation behind it.
#
# <claim_key> defaults to <key> and exists because the MARKER key and the
# MUTUAL-EXCLUSION key answer different questions (Codex P1, round 1). The
# marker records which episode was answered; the claim reserves the right to
# post at all. Scoping the claim by anything finer than the resource being
# reserved silently unserializes concurrent writers: an old-head run that
# already probed a pause and a new-head run started after a push hold two
# different claims, both read the timeline before either comment is visible,
# and both post — the marker scan only dedups writes that have LANDED. The
# resume class therefore claims at pause-note level while marking per head; the
# trigger class reserves one request per head, which is what its key already
# names, so it passes nothing and the default keeps today's behaviour.
#
# The claim wraps the WHOLE read-and-post region (#846): the read and the post
# were not atomic, so two overlapping invocations for the same head could both
# read no-marker and both post — double-spending the five-per-hour allowance
# the marker conserves. mkdir gives one winner with no window; the loser (and
# any invocation that cannot take a claim at all, including on an unusable
# state dir) declines without posting. The claim records nothing and is read
# by nothing — the timeline marker stays the only durable account of what was
# posted, so over-spend is never traded for starvation: a failed post releases
# the claim and the next bounded retry re-attempts.
#
# A DRY RUN takes no claim. The claim reserves the right to POST, and a dry run
# never posts; now that the root is shared across checkouts (#858) rather than
# private to one, a rehearsal that claimed would make a concurrent REAL run
# decline. phase-4b-review.sh already goes to explicit lengths to keep dry-run
# state out of real state (Codex P2 on #842) and this is the same rule for the
# same reason.
p4b_barrier_maybe_write() {
  local kind="$1" repo="$2" pr="$3" key="$4" reviewer="$5" dry="${6:-false}" since="${7:-}" family="${8:-}"
  local claim_key="${9:-$4}"
  local claim="" comments raw n out
  if [ "$dry" != true ]; then
    claim="$(p4b_barrier_claim_path "$repo" "$pr" "$claim_key" "$kind")"
    p4b_barrier_claim "$claim" || { printf '%s-claim-declined' "$kind"; return 0; }
  fi
  # Re-read the timeline rather than trusting process state: the bounded retry
  # runs as a fresh one-shot process each time, so "already spent" has to be
  # durable in the PR itself.
  #
  # A read FAILURE is not an empty timeline. `jq -sc 'add // []'` prints `[]`
  # and exits 0 on empty stdin, so folding the read and the parse into one
  # pipeline turns any gh failure — 403, secondary rate limit, a truncated
  # --paginate — into "no marker found", and the arm re-posts on every bounded
  # retry. That is a self-amplifying write loop against the same five-per-hour
  # allowance the marker exists to conserve, on the PAT that is also the CI
  # token. Declining costs nothing, because `pending` is set before this runs,
  # so the bound and the human escalation stand either way.
  raw="$(gh api "repos/$repo/issues/$pr/comments" --paginate 2>/dev/null)" \
    || { p4b_barrier_release "$claim"; printf '%s-read-failed' "$kind"; return 0; }
  comments="$(printf '%s' "$raw" | jq -sc 'add // []' 2>/dev/null)" \
    || { p4b_barrier_release "$claim"; printf '%s-read-failed' "$kind"; return 0; }
  case "$comments" in
    '['*) ;;
    *) p4b_barrier_release "$claim"; printf '%s-read-failed' "$kind"; return 0 ;;
  esac
  n="$(p4b_barrier_write_count "$kind" "$key" "$reviewer" "$comments" "$since" "$family")"
  if [ "$n" -gt 1 ]; then
    # Two markers can only mean two checkouts raced before this change, or a
    # write reported failed actually landed and was retried. Surfaced, not
    # hidden: the caller's ledger shows the duplicate was at least observed.
    out="already-${kind}-duplicate"
  elif [ "$n" -gt 0 ]; then
    out="already-${kind}"
  elif [ "$dry" = true ]; then
    out="would-${kind}"
  elif p4b_barrier_post_trigger "$repo" "$pr" "$key" "$reviewer" "$kind"; then
    case "$kind" in resume) out='resumed' ;; *) out='triggered' ;; esac
  else
    out="${kind}-failed"
  fi
  p4b_barrier_release "$claim"
  printf '%s' "$out"
  return 0
}

# p4b_barrier_maybe_trigger <repo> <pr> <head> <reviewer> <probe_json> <dry_run>
# The review-request write: observed-gate, then the claimed write core. The
# claim is taken only after the decline check, so a state that will never
# post takes no claim. Existing signature and action vocabulary preserved,
# with `already-triggered` spelled `already-trigger` only in the core's
# generic arms — mapped back here so callers and tests keep the historical
# strings.
p4b_barrier_maybe_trigger() {
  local repo="$1" pr="$2" head="$3" reviewer="$4" json="$5" dry="${6:-false}"
  local observed out
  observed="$(printf '%s' "$json" | jq -r '.probe.observed // empty' 2>/dev/null || true)"
  p4b_barrier_should_trigger "$observed" || { printf 'declined'; return 0; }
  out="$(p4b_barrier_maybe_write trigger "$repo" "$pr" "$head" "$reviewer" "$dry")"
  case "$out" in
    already-trigger)           printf 'already-triggered' ;;
    already-trigger-duplicate) printf 'already-triggered-duplicate' ;;
    *)                         printf '%s' "$out" ;;
  esac
  return 0
}

# p4b_barrier_maybe_resume <repo> <pr> <head> <reviewer> <probe_json> <dry_run>
# The pause recovery (#847): on observed=paused, post `@<bot> resume` at most
# once per PAUSE EVENT, deduplicated by its own timeline marker so a resume
# and the review trigger can never be confused for one another. The pause
# notice's comment id is the anchor of both keys below, never the head alone
# (Codex P2, round 1): a pause is PR-level and durable across pushes, so a
# per-head key would post one resume per Codex-forced push while the same
# pause note stands. The comment id is CodeRabbit-owned and carried in the
# probe's evidence; a paused observation without one declines rather than
# guessing a key.
#
# The barrier posts the resume itself rather than delegating to
# coderabbit-wait.sh's polling mode: delegation would need new
# per-invocation overrides for that script's other writers (its switches are
# policy fields, not envs) and its retry latch is local to one checkout —
# weaker than the timeline marker's at-most-once. --probe stays read-only
# structurally: nothing in the probe path can reach this.
#
# Exhaustion still escalates: a resume does not clear pending, so if the bot
# stays paused the bound expires and a human is paged exactly as before —
# after, rather than instead of, the one recovery attempt the polling mode
# would have made.
p4b_barrier_maybe_resume() {
  local repo="$1" pr="$2" head="$3" reviewer="$4" json="$5" dry="${6:-false}"
  local observed pause_id pause_fresh pause_key pause_family out
  observed="$(printf '%s' "$json" | jq -r '.probe.observed // empty' 2>/dev/null || true)"
  [ "$observed" = paused ] || { printf 'skipped'; return 0; }
  pause_id="$(printf '%s' "$json" | jq -r '.review.id // empty' 2>/dev/null || true)"
  case "$pause_id" in
    ''|null|*[!0-9]*) printf 'resume-unidentified'; return 0 ;;
  esac
  # The pause key rides the same argument slot the trigger uses for the head:
  # it keys the claim, the marker, and nothing else, so one write core serves
  # both classes unchanged. The note's fresh_at scopes the family and the
  # bare-form interop dedup — see p4b_barrier_write_count.
  pause_fresh="$(printf '%s' "$json" | jq -r '.review.fresh_at // .review.updated_at // .review.created_at // empty' 2>/dev/null || true)"
  # TWO keys, not one (#862 and its regression). The EXACT key is the note id
  # plus the head; the FAMILY is every key for that note id under any head.
  #
  # The exact key is what makes the recovery idempotent inside one pause
  # episode. Anything derived from the note's freshness is not: CodeRabbit
  # edits ONE pause comment in place — coderabbit-wait.sh documents the same
  # behaviour for its summary — so a Finishing-Touches checkbox tick bumps
  # fresh_at with no new pause, and a fresh_at-derived key (or a bare
  # fresh_at conjunct) reads every such edit as a new episode and resumes
  # again, once per edit, against the five-per-hour allowance the marker
  # exists to conserve. The head cannot be bumped that way, and re-pausing
  # costs the bot new reviewed commits, which costs a new head — so "same
  # note, same head" is exactly "no new episode since we answered".
  #
  # The family carries the cross-head half round 1 asked for: a standing note
  # unchanged since our resume is still answered by it, so a Codex-forced
  # push buys no second resume, while a note rewritten AFTER our resume is a
  # new episode and the recovery fires. That freshness test lives on the
  # family arm, where a `>=` comparison is safe, rather than in the key.
  #
  # A note with no usable timestamp collapses to the historical at-most-once
  # per note id: the family then counts unconditionally.
  #
  # The CLAIM is keyed on the pause note ALONE, deliberately not on the exact
  # key (Codex P1, round 1). The marker is per episode, but the thing being
  # reserved is "the right to post a resume for this note", which is not
  # per-head: an old-head bounded retry and a new-head run started after a push
  # overlap routinely, and two head-scoped claims let both read the timeline
  # before either comment lands and both post. Claiming at note level restores
  # the pre-#862 mutual exclusion — the loser declines and, on its next retry,
  # counts the winner's marker through the family arm.
  pause_key="pause-$pause_id-${head:-nohead}"
  pause_family="pause-$pause_id-"
  out="$(p4b_barrier_maybe_write resume "$repo" "$pr" "$pause_key" "$reviewer" "$dry" "$pause_fresh" "$pause_family" "pause-$pause_id")"
  case "$out" in
    already-resume)           printf 'already-resumed' ;;
    already-resume-duplicate) printf 'already-resumed-duplicate' ;;
    *)                        printf '%s' "$out" ;;
  esac
  return 0
}

# --- the barrier itself (#814) ----------------------------------------------
#
# p4b_same_head_barrier <repo> <pr> <head> <reviewer> [dry_run]
#
# Emits one JSON object on stdout and returns:
#   0  open      — every ENABLED provider is terminal on this exact head
#   1  pending   — at least one is not yet, still inside the bound
#   2  escalate  — a provider needs a human, or the bound is exhausted
#
# Guarded only on the existing codex.enabled / coderabbit.enabled switches;
# #814 ships with no new review-policy keys. A provider disabled in policy is
# simply not consulted — that, and not any rc, is the only route to
# will-not-report, and it cannot flip mid-flight on a live PR.
p4b_same_head_barrier() {
  local repo="$1" pr="$2" head="$3" reviewer="$4" dry="${5:-false}"
  local root cr_bin cx_bin rc json probe_head
  local pending=false why="" trigger="skipped" resume="skipped" cls_cr="disabled" cls_cx="disabled"
  local elapsed budget remaining=0
  root="$(p4b_repo_root)"
  cr_bin="${P4B_CODERABBIT_WAIT:-$root/scripts/coderabbit-wait.sh}"
  cx_bin="${P4B_CODEX_REVIEW_CHECK:-$root/scripts/codex-review-check.sh}"

  # Codex arm. The five overrides turn a merge-gate verdict into "has Codex
  # itself spoken on THIS head" — see p4b_barrier_class_codex for why each is
  # required, and why the diagnostic switch is a flag rather than an env var.
  if [ "$(p4b_policy_block_field codex enabled)" != "false" ]; then
    rc=0
    CODEX_REVIEW_CHECK_SKIP_CI=1 \
    CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
    CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE=false \
      "$cx_bin" --diagnostic-signal-only "$pr" "$repo" >/dev/null 2>&1 || rc=$?
    cls_cx="$(p4b_barrier_class_codex "$rc")"
    # Waiving an account-blocked Codex only helps where a Phase 4b APPROVED can
    # actually clear gate (c). With codex.allow_phase_4b_substitute: false the
    # merge gate rejects that review by design, so opening the barrier would
    # let the automated leg post an approval, report success, and leave the PR
    # still unmergeable with needs-external-review uncleared — a green run that
    # accomplished nothing (Codex P2 on #842). In that configuration a block is
    # exactly what it looks like: something a human has to fix.
    if [ "$cls_cx" = waived ] \
       && [ "$(p4b_policy_block_field codex allow_phase_4b_substitute)" = "false" ]; then
      cls_cx="escalate"
      why="Codex is account-blocked and codex.allow_phase_4b_substitute=false, so no Phase 4b review could clear gate (c) — a human must resolve the block"
    fi
    case "$cls_cx" in
      reported|will-not-report|waived) ;;
      not-yet)  pending=true ;;
      escalate) [ -n "$why" ] || why="codex signal check exited $rc" ;;
      *)        why="codex signal check exited $rc" ;;
    esac
  fi

  # CodeRabbit arm: probe (read-only, zero allowance) -> conditional trigger
  # -> bounded retry. The probe resolves the live head itself, so classifying
  # against "$head" is also what catches a push landing mid-run.
  if [ -z "$why" ] && [ "$(p4b_policy_block_field coderabbit enabled)" != "false" ]; then
    rc=0
    json="$("$cr_bin" --probe "$pr" "$repo" 2>/dev/null)" || rc=$?
    # Head drift, detected BEFORE any trigger (Codex P2 on #842). The probe
    # resolves the LIVE head; when that differs from the head under review a
    # push landed after "$HEAD" was captured. Classifying that as not-yet and
    # then triggering asks CodeRabbit to review an unrelated new head, spends
    # the one permitted request on it, and can never satisfy the old-head
    # comparison — so the run would hold until the whole budget expired. This
    # run is void either way: the orchestrator's own live-head recheck refuses
    # to post on a drifted head, so escalate now for the same reason rather
    # than burning the budget first.
    probe_head="$(printf '%s' "$json" | jq -r '.head_sha // empty' 2>/dev/null || true)"
    if [ -n "$probe_head" ] && [ "$probe_head" != "$head" ]; then
      why="PR head moved during evaluation (reviewing $head, live $probe_head) — rerun on the new head"
      cls_cr="drift"
    else
      cls_cr="$(p4b_barrier_class_coderabbit "$head" "$rc" "$json")"
      case "$cls_cr" in
        reported|will-not-report|waived) ;;
        rate-limited)
          # #1178. The classifier has established that CodeRabbit REFUSED
          # this head and that no wait available to this run lifts the
          # refusal. That is exactly the question the rc-5 arm already
          # answers for the polling mode — waived when the #489 Codex
          # failover engaged, escalate otherwise — and the reason it was
          # unreachable here is only that --probe never returns rc 5 and
          # never sets codex_failover_requested.
          #
          # Resolve it against the Codex arm THIS run already classified,
          # which is the same claim the failover flag makes and is better
          # evidence: the flag says a request was sent, cls_cx == reported
          # says Codex actually spoke on the exact head about to be
          # approved. That, and not CodeRabbit's participation, is what the
          # barrier's ordering guarantee requires — see the rc-5 note on
          # why waived is the right class for a stall the other provider
          # has already covered.
          #
          # A Codex arm still `not-yet` is the one case that keeps waiting,
          # and the wait is honest because it is a wait on CODEX: that arm
          # is self-clearing, and the next probe can find it reported and
          # open the barrier on it. Escalating here instead would page a
          # human on a PR whose Codex round was about to land — the #835
          # objection to escalating a rate limit unconditionally, which
          # holds just as well when the failover's role is played by the
          # barrier's own Codex arm. What the head-anchored budget already
          # bounds, it keeps bounding; only the reason it escalates with
          # changes, below.
          #
          # WHAT MAKES THE OPEN ARM SAFE, and where that safety lives:
          # `observed: rate_limit` has to mean "refused, with nothing unread
          # behind the refusal". It does not say that for free. CodeRabbit
          # writes its rate-limit stanza INTO the summarize comment it edits
          # in place — the same comment that carries the #535 summary-only
          # finding — and classify_comment is marker-first, so one body can
          # say both and the refusal wins the classification. Opening on that
          # would post an approval over a finding no required gate reads
          # (Codex P1 on #1179). crw_rate_limit_masks_blocking_marker in
          # scripts/coderabbit-wait.sh closes it upstream: such a body emits
          # rc 2, which this classifier already escalates, so a rate_limit
          # that reaches HERE is a bare refusal. That invariant is the
          # precondition for this arm — a probe without the guard must not be
          # paired with it.
          #
          # Every OTHER cls_cx escalates now, `waived` and `disabled`
          # included: in those states nothing will read this head at all, so
          # opening would post an approval with no external corroboration
          # and waiting would spend a budget with nothing to wait on. That
          # is the routing #839 gave the account-blocked Codex, for the same
          # reason — no marker is written, so no budget starts.
          #
          # (`escalate` is unreachable: the Codex arm sets `why`, and this
          # whole block is guarded on `why` being empty.)
          #
          # No trigger and no resume on any of these paths: should_trigger
          # declines on rate_limit anyway, and a resume answers a pause, not
          # a limit. The class spends no CodeRabbit allowance in either
          # direction.
          case "$cls_cx" in
            reported) ;;
            not-yet)  pending=true ;;
            *)
              why="CodeRabbit refused to review $head (rate limited) and no wait this run can make lifts that, while Codex is '$cls_cx' rather than reported — nothing has read this head, so a human must review it or clear the limit"
              ;;
          esac
          ;;
        not-yet)
          pending=true
          # The pause recovery is NOT gated on Codex terminality, unlike the
          # trigger below: a pause is PR-level, a paused CodeRabbit cannot
          # report on ANY head, and the resume is not discarded by a
          # Codex-forced push — waiting would only burn the bound (#847).
          resume="$(p4b_barrier_maybe_resume "$repo" "$pr" "$head" "$reviewer" "$json" "$dry")"
          # Only spend the request once Codex is terminal. The trigger point is
          # meant to be the settled head — "after the Codex rounds have
          # converged" — and if Codex is still not-yet it may yet produce
          # feedback that forces a push, discarding this head and the request
          # with it (Codex P2 on #842). Already-present CodeRabbit evidence is
          # still observed above; only the WRITE waits.
          case "$cls_cx" in
            not-yet) trigger="awaiting-codex" ;;
            *) trigger="$(p4b_barrier_maybe_trigger "$repo" "$pr" "$head" "$reviewer" "$json" "$dry")" ;;
          esac
          ;;
        *)
          if [ "$rc" = 2 ]; then
            why="CodeRabbit published a blocking finding carried only by the PR-level summary on $head — no required gate dispositions that class, so a human must read it"
          else
            why="coderabbit probe exited $rc"
          fi
          ;;
      esac
    fi
  fi

  if [ -z "$why" ] && [ "$pending" = true ]; then
    # Bounded: the marker records when THIS checkout began waiting on this
    # head. It asserts no provider event, so no clock value can turn a not-yet
    # provider into a reported one — it decides only when to involve a human.
    elapsed="$(p4b_barrier_note_pending "$repo" "$pr" "$head")"
    budget="$(p4b_barrier_budget_seconds)"
    if [ "$elapsed" -ge "$budget" ]; then
      why="external review did not reach the current head within ${budget}s"
      # Name the REFUSAL, not just the clock (#1178). This exhaustion is
      # reachable with cls_cr=rate-limited whenever Codex stayed not-yet for
      # the whole budget, and "did not reach the current head" reads as
      # latency to whoever opens the handoff — sending them to wait longer
      # or re-nudge, when what actually happened is that one provider
      # refused outright and the other never finished. The manual fallback's
      # renderer carries only this string, which is why the pause recovery
      # below is appended to it for the same reason.
      case "$cls_cr" in
        rate-limited) why="$why (CodeRabbit refused this head as rate limited and cannot be re-asked; the wait was on Codex, which stayed '$cls_cx')" ;;
      esac
      # The recovery this same run just sent must survive into the manual
      # fallback, whose renderer carries only the reason — an operator who
      # cannot see it may post a second resume on top (Codex P2, round 2).
      case "$resume" in
        skipped) ;;
        *) why="$why (pause recovery this run: $resume)" ;;
      esac
    else
      remaining=$(( budget - elapsed ))
    fi
  fi

  # Any outcome other than pending ends this head's wait, so the next not-yet
  # on the same head starts a fresh budget rather than inheriting a stale one.
  if [ -n "$why" ] || [ "$pending" != true ]; then
    p4b_barrier_clear_pending "$repo" "$pr" "$head"
  fi

  if [ -n "$why" ]; then
    jq -nc --arg r "$why" --arg cr "$cls_cr" --arg cx "$cls_cx" --arg t "$trigger" --arg rs "$resume" \
      '{decision:"escalate", reason:$r, coderabbit:$cr, codex:$cx, trigger:$t, resume:$rs}'
    return 2
  fi
  if [ "$pending" = true ]; then
    jq -nc --argjson ra "$remaining" --arg cr "$cls_cr" --arg cx "$cls_cx" --arg t "$trigger" --arg rs "$resume" \
      '{decision:"pending", retry_after:$ra, coderabbit:$cr, codex:$cx, trigger:$t, resume:$rs}'
    return 1
  fi
  jq -nc --arg cr "$cls_cr" --arg cx "$cls_cx" \
    '{decision:"open", coderabbit:$cr, codex:$cx}'
  return 0
}

# --- reviewer CLI runtime bounds: timeout + effort (#589) -------------------

# Conservative defaults preserve the historical hard-coded behavior (a 900s
# timeout, Claude effort medium, Codex effort unset/no-op).
P4B_DEFAULT_ADAPTER_TIMEOUT_SECONDS=900
# Safety bounds for a POLICY-configured timeout. A value outside this range, or
# a non-integer, is rejected fail-closed so a typo (e.g. 90000000) cannot
# effectively unbound the reviewer CLI. The P4B_*_TIMEOUT_SECONDS env overrides
# the orchestrator/adapters honor are a deliberate escape hatch for tests and
# manual runs and are NOT bounded here.
P4B_MIN_ADAPTER_TIMEOUT_SECONDS=1
P4B_MAX_ADAPTER_TIMEOUT_SECONDS=3600

# p4b_resolve_adapter_timeout <adapter>
# Resolve the reviewer CLI timeout (seconds) for <adapter> from policy:
#   phase_4b_automation.<adapter>_timeout_seconds  (per-adapter override)
#   phase_4b_automation.adapter_timeout_seconds    (shared default)
#   P4B_DEFAULT_ADAPTER_TIMEOUT_SECONDS            (900)
# Prints the resolved integer on success. Returns non-zero (no output) when a
# configured value is non-integer or outside [MIN, MAX] so the caller fails
# closed instead of running the CLI mis-bounded. Env overrides are layered on
# by the orchestrator, not here.
p4b_resolve_adapter_timeout() {
  local adapter="$1" val
  val="$(p4b_automation_field "${adapter}_timeout_seconds")"
  [ -n "$val" ] || val="$(p4b_automation_field adapter_timeout_seconds)"
  [ -n "$val" ] || { printf '%s' "$P4B_DEFAULT_ADAPTER_TIMEOUT_SECONDS"; return 0; }
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$val" -lt "$P4B_MIN_ADAPTER_TIMEOUT_SECONDS" ] \
     || [ "$val" -gt "$P4B_MAX_ADAPTER_TIMEOUT_SECONDS" ]; then
    return 1
  fi
  printf '%s' "$val"
}

# p4b_resolve_adapter_effort <adapter>
# Resolve the reviewer CLI effort level for <adapter> from
# phase_4b_automation.<adapter>_effort, validated against that adapter's
# accepted set:
#   claude → low|medium|high|xhigh|max        (maps to `claude --effort`; default medium)
#   codex  → minimal|low|medium|high|xhigh    (maps to `codex -c model_reasoning_effort`;
#                                              default empty = CLI default / no-op)
# Prints the value (possibly empty for codex) on success; returns non-zero on an
# invalid configured value so the caller fails closed.
p4b_resolve_adapter_effort() {
  local adapter="$1" val
  val="$(p4b_automation_field "${adapter}_effort")"
  case "$adapter" in
    claude)
      [ -n "$val" ] || { printf 'medium'; return 0; }
      case "$val" in
        low|medium|high|xhigh|max) printf '%s' "$val" ;;
        *) return 1 ;;
      esac
      ;;
    codex)
      [ -n "$val" ] || return 0   # empty = no -c flag (CLI default)
      case "$val" in
        minimal|low|medium|high|xhigh) printf '%s' "$val" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      # Unknown adapter has no effort knob; any configured value is invalid.
      [ -n "$val" ] && return 1 || return 0
      ;;
  esac
}

# --- feedback-disposition policy (#574-compatible approval gate) -----------

# p4b_feedback_policy_mode — mode under `feedback_policy:`. The absent-block
# default mirrors today's review policy: by-priority with P0/P1 required.
p4b_feedback_policy_mode() {
  local cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || { printf '%s' "by-priority"; return 0; }
  awk '
    /^feedback_policy:/ { inblk=1; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk && $1 == "mode:" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print; exit
    }
  ' "$cfg"
}

# p4b_feedback_priority_value <p0|p1|p2|p3|nitpick>
# Returns the configured disposition value under feedback_policy.priorities,
# or the parser default if absent: P0/P1 required, lower tiers discretionary.
p4b_feedback_priority_value() {
  local tier="$1" cfg value
  cfg="$(p4b_config)"
  if [ -f "$cfg" ]; then
    value="$(
      awk -v tier="$tier" '
        /^feedback_policy:/ { inblk=1; inprio=0; next }
        inblk && /^[^[:space:]#]/ { inblk=0; inprio=0 }
        inblk && /^[[:space:]]+priorities:/ { inprio=1; next }
        inprio {
          line=$0
          gsub(/[[:space:]]*#.*$/, "", line)
          if (line ~ /^[[:space:]]*$/) next
          indent = match(line, /[^[:space:]]/) - 1
          if (indent <= 2) { inprio=0; next }
          key=line
          sub(/^[[:space:]]*/, "", key)
          sub(/:.*/, "", key)
          if (key == tier) {
            sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
            gsub(/^["\047]/, "", line)
            gsub(/["\047][[:space:]]*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line; exit
          }
        }
      ' "$cfg"
    )"
  fi
  if [ -n "${value:-}" ]; then
    printf '%s' "$value"
    return 0
  fi
  case "$tier" in
    p0|p1) printf '%s' "required" ;;
    p2|p3|nitpick) printf '%s' "discretionary" ;;
    *) return 1 ;;
  esac
}

# p4b_required_verdict_severities_json
# Returns a JSON array of verdict severities that cannot appear in an
# APPROVED response. Phase 4b adapter verdicts use P0-P3; CodeRabbit-only
# nitpick policy applies to the CodeRabbit gate, not this schema.
p4b_required_verdict_severities_json() {
  local mode tier value first=true
  mode="$(p4b_feedback_policy_mode)"
  mode="${mode:-by-priority}"
  case "$mode" in
    address-all)
      printf '%s' '["P0","P1","P2","P3"]'
      return 0
      ;;
    by-priority) ;;
    *) return 1 ;;
  esac

  printf '['
  for tier in p0 p1 p2 p3; do
    value="$(p4b_feedback_priority_value "$tier")" || return 1
    case "$value" in
      required)
        if [ "$first" = true ]; then first=false; else printf ','; fi
        printf '"%s"' "$(printf '%s' "$tier" | tr '[:lower:]' '[:upper:]')"
        ;;
      discretionary|ignore) ;;
      *) return 1 ;;
    esac
  done
  printf ']'
}

# p4b_available_reviewers — newline-separated list items under
# `available_reviewers:`.
p4b_available_reviewers() {
  local cfg
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk '
    /^available_reviewers:/ { inlist=1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["\047]/, "", line); gsub(/["\047][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
      next
    }
    inlist && /^[^[:space:]#-]/ { inlist=0 }
  ' "$cfg"
}

# --- identity / direction helpers ------------------------------------------

# Strip the reviewer-login prefix to get the agent short name.
#   nathanpayne-codex -> codex ; claude -> claude
p4b_agent_of_login() {
  local login
  login="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$login" in
    nathanpayne-*) printf '%s' "${login#nathanpayne-}" ;;
    *)             printf '%s' "$login" ;;
  esac
}

# Map an agent short name to a reviewer login. A value already in login
# form (contains a dash) is passed through unchanged.
p4b_login_of_agent() {
  case "$1" in
    *-*) printf '%s' "$1" ;;
    *)   printf 'nathanpayne-%s' "$1" ;;
  esac
}

# Map a reviewer login (or agent) to an adapter name.
#   nathanpayne-codex -> codex ; nathanpayne-claude -> claude
# Unknown agents echo their agent name; the orchestrator treats anything
# without a review-via-<name>.sh adapter as unsupported (manual fallback).
p4b_adapter_of_login() { p4b_agent_of_login "$1"; }

p4b_adapter_dir() {
  if [ -n "${P4B_ADAPTER_DIR:-}" ]; then
    printf '%s' "$P4B_ADAPTER_DIR"
    return 0
  fi
  printf '%s/scripts/phase-4b/adapters' "$(p4b_repo_root)"
}

p4b_adapter_supported_for_login() {
  local adapter
  adapter="$(p4b_adapter_of_login "$1")"
  [ -x "$(p4b_adapter_dir)/review-via-${adapter}.sh" ]
}

p4b_available_reviewer_contains() {
  local needle="$1" r
  while IFS= read -r r; do
    [ "$r" = "$needle" ] && return 0
  done <<EOF
$(p4b_available_reviewers)
EOF
  return 1
}

# p4b_select_reviewer <author-agent-or-login>
# Echo the external reviewer login: a member of available_reviewers whose
# agent differs from the author and has a local adapter, preferring
# default_external_reviewer.
# Exit 1 (no echo) if none can be found.
p4b_select_reviewer() {
  local author_in="$1" author_agent default def_agent r r_agent
  author_agent="$(p4b_agent_of_login "$author_in")"

  default="$(p4b_top_field default_external_reviewer)"
  if [ -n "$default" ] && p4b_available_reviewer_contains "$default"; then
    def_agent="$(p4b_agent_of_login "$default")"
    if [ "$def_agent" != "$author_agent" ] && p4b_adapter_supported_for_login "$default"; then
      printf '%s' "$default"; return 0
    fi
  fi

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    r_agent="$(p4b_agent_of_login "$r")"
    if [ "$r_agent" != "$author_agent" ] && p4b_adapter_supported_for_login "$r"; then
      printf '%s' "$r"; return 0
    fi
  done <<EOF
$(p4b_available_reviewers)
EOF
  return 1
}

# --- verdict validation (structural contract derived from the schema) ------

# p4b_verdict_schema_path — location of verdict.schema.json, the single
# source of truth for the verdict's structural contract. It ships alongside
# this library, so it is resolved relative to P4B_LIB_DIR (captured at source
# time). Overridable via P4B_VERDICT_SCHEMA_PATH (tests / non-standard layouts).
p4b_verdict_schema_path() {
  if [ -n "${P4B_VERDICT_SCHEMA_PATH:-}" ]; then
    printf '%s' "$P4B_VERDICT_SCHEMA_PATH"
    return 0
  fi
  printf '%s/verdict.schema.json' "$P4B_LIB_DIR"
}

# p4b_validate_verdict <json-string>
# Returns 0 iff the string is a verdict object conforming to
# verdict.schema.json's required shape plus the semantic invariants that
# keep a posted APPROVED review from clearing a PR while still carrying
# blocking findings. Fail-closed: any deviation, empty input, missing or
# malformed schema, or jq error returns non-zero. No stdout.
#
# Drift resistance (#585): the structural constants most likely to drift —
# the top-level key set, the verdict enum, the per-finding key set, the
# severity enum, and the usage key set — are read FROM the schema at
# validation time rather than hand-mirrored in this jq program. Changing a
# key or enum value in verdict.schema.json therefore reconfigures the
# validator automatically, and tests/test_phase_4b_automation.sh adds
# schema-vs-validator parity fixtures as defense in depth. The remaining
# checks encode semantics the JSON Schema cannot express on its own: the
# config-dependent feedback_policy approval gate, the all-or-nothing usage
# object, and the 1-based line bound.
p4b_validate_verdict() {
  local json="$1" required_severities schema
  [ -n "$json" ] || return 1
  required_severities="$(p4b_required_verdict_severities_json)" || return 1
  schema="$(p4b_verdict_schema_path)"
  [ -r "$schema" ] || return 1
  printf '%s' "$json" | jq -e \
      --argjson required_severities "$required_severities" \
      --slurpfile schema_doc "$schema" '
    # Structural constants, derived from verdict.schema.json (single source
    # of truth). A missing/empty schema slurp makes these error → jq exits
    # non-zero → validation fails closed.
    ($schema_doc[0]) as $s
    | ($s.required | sort) as $top_keys
    | ($s.properties.verdict.enum) as $verdict_enum
    | ($s.properties.findings.items.required | sort) as $finding_keys
    | ($s.properties.findings.items.properties.severity.enum) as $severity_enum
    | ($s.properties.usage.required | sort) as $usage_keys
    | ($s.properties.usage.properties | keys | sort) as $usage_all_keys
    | def okstr: (type == "string") and (length > 0);
      def okintnull: (. == null) or (type == "number" and floor == . and . >= 0);
      # Guard the derived constants are the right SHAPE first. `sort` already
      # errors (→ fail closed) if a required-key field is not an array, but the
      # enums are consumed with `index`, which on a STRING does a substring
      # search instead of array membership — a malformed schema (or a hostile
      # P4B_VERDICT_SCHEMA_PATH) with an enum as a scalar would then wrongly
      # accept "APPROVED"/"P1". Assert array shape so a bad schema fails closed.
      (($verdict_enum | type) == "array")
      and (($severity_enum | type) == "array")
      and (($top_keys | type) == "array")
      and (($finding_keys | type) == "array")
      and (($usage_keys | type) == "array")
      and ((keys_unsorted | sort) == $top_keys)
      and ((.verdict) as $v | ($verdict_enum | index($v)) != null)
      and (.summary | okstr)
      and (.findings | type == "array")
      and all(.findings[]?;
            ((keys_unsorted | sort) == $finding_keys)
            and ((.severity) as $sv | ($severity_enum | index($sv)) != null)
            and ((.path == null) or (.path | type == "string"))
            and ((.line == null) or (.line | type == "number" and floor == . and . >= 1))
            and (.body | okstr))
      and ((.verdict != "APPROVED")
           or all(.findings[]?; (.severity as $s2 | ($required_severities | index($s2) | not))))
      # cli_version (#622): required-but-nullable, same contract as usage —
      # a string when the adapter captured `--version` output, null when it
      # did not (never a guessed value).
      and ((.cli_version == null) or (.cli_version | type == "string"))
      # usage: the schema-required keys must all be present, any other key
      # must be one the schema DECLARES, and every field must type-check.
      # This mirrors the JSON Schema exactly: required ⊆ keys ⊆ properties,
      # additionalProperties: false. Since #632 the schema is
      # required-COMPLETE (OpenAI strict mode demands required == all
      # properties), so the #602 additive fields are required-but-nullable
      # and this derived check tightens with it automatically.
      and ((.usage == null)
           or ((.usage | type == "object")
               and ((.usage | keys_unsorted | sort) as $uk
                    | (($usage_keys - $uk) == []) and (($uk - $usage_all_keys) == []))
               and (.usage.token_count | okintnull)
               and (.usage.input_tokens | okintnull)
               and (.usage.output_tokens | okintnull)
               # #602 additive fields (required-but-nullable since #632; the
               # key-set equality above already rejects an absent key). Plain
               # `.usage.X`, never `// null` — the jq alternative operator
               # treats `false` as absent, so a boolean field
               # (cache_read_input_tokens:false) would silently pass (#615
               # Codex; the known repo `//`-vs-false footgun).
               and (.usage.cache_creation_input_tokens | okintnull)
               and (.usage.cache_read_input_tokens | okintnull)
               and (.usage.reasoning_tokens | okintnull)
               and (.usage.total_cost_usd as $c
                    | ($c == null) or (($c | type) == "number" and $c >= 0))
               and (.usage.source | okstr)))
  ' >/dev/null 2>&1
}

# p4b_extract_json_block <text>
# Emit the SOLE complete, balanced, top-level JSON object embedded in the text.
# Used by the Claude adapter, whose model output may wrap the JSON in prose.
# Leaves already-pure JSON unchanged.
#
# Implementation (#587): a string-aware brace-depth scanner, not a naive
# first-"{"-to-last-"}" slice. It tracks JSON string literals (honoring \" and
# \\ escapes) so braces inside string VALUES do not change nesting depth, and
# it isolates the first balanced top-level object — so balanced-brace prose
# after the JSON object can no longer extend the slice and poison extraction.
#
# It then requires that to be the ONLY top-level object: if a second `{` opens
# outside a string in the remainder, the output is ambiguous (e.g. a draft
# APPROVED followed by a corrected CHANGES_REQUESTED) and this emits nothing so
# downstream schema validation fails closed rather than silently posting the
# first verdict (#594 Codex). Markdown code fences alone on a line are stripped
# first. Unbalanced, object-free, or multi-object input all emit nothing.
p4b_extract_json_block() {
  printf '%s\n' "$1" \
    | sed -e 's/^```[A-Za-z0-9]*[[:space:]]*$//' -e 's/^```[[:space:]]*$//' \
    | awk '
        { buf = buf $0 "\n" }
        END {
          n = length(buf)
          start = index(buf, "{")
          if (start == 0) exit 0
          depth = 0; instr = 0; esc = 0; endpos = 0
          for (i = start; i <= n; i++) {
            c = substr(buf, i, 1)
            if (instr) {
              if (esc)       { esc = 0;   continue }   # this char is escaped
              if (c == "\\") { esc = 1;   continue }   # begin escape sequence
              if (c == "\"") { instr = 0; continue }   # end of string literal
              continue                                  # any other in-string char
            }
            if (c == "\"") { instr = 1; continue }     # begin string literal
            if (c == "{")  { depth++ }
            else if (c == "}") {
              depth--
              if (depth == 0) { endpos = i; break }    # first object closed
            }
          }
          if (endpos == 0) exit 0                       # unbalanced → fail closed
          # Reject a SECOND top-level object in the remainder (string-aware):
          # ambiguous multi-verdict output must fail closed, not take the first.
          instr = 0; esc = 0
          for (i = endpos + 1; i <= n; i++) {
            c = substr(buf, i, 1)
            if (instr) {
              if (esc)       { esc = 0;   continue }
              if (c == "\\") { esc = 1;   continue }
              if (c == "\"") { instr = 0; continue }
              continue
            }
            if (c == "\"") { instr = 1; continue }
            if (c == "{")  { exit 0 }                   # second object → fail closed
          }
          printf "%s", substr(buf, start, endpos - start + 1)
        }'
}

# p4b_run_with_timeout <seconds> <command> [args...]
# Portable bounded execution for reviewer CLIs/adapters. GNU coreutils
# `timeout` is common on Linux; macOS has perl, and the inherited alarm
# timer survives exec so the target process is still bounded.
p4b_run_with_timeout() {
  local seconds="$1"
  shift
  case "$seconds" in
    ''|0) "$@"; return $? ;;
    *[!0-9]*) p4b_die 3 "timeout seconds must be a non-negative integer; got '$seconds'" ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
    return $?
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$seconds" "$@"
    return $?
  fi
  p4b_die 3 "bounded review execution requires GNU timeout or perl"
}

p4b_is_timeout_rc() {
  case "$1" in
    124|142) return 0 ;;
    *)       return 1 ;;
  esac
}

# --- review-diff byte budget (#635) -----------------------------------------

# A PR whose diff carries bulk artifacts (mined JSONL extracts, generated
# datasets) can exceed the reviewer CLI's model context; the CLI then fails
# with an opaque nonzero exit and the whole automated leg falls back to the
# manual handoff even though the reviewable code is small (#629: a 6.4 MB
# diff, 6.2 MB of it two committed data files). The adapters therefore bound
# what they pipe to the reviewer CLI: when the diff exceeds the budget, the
# LARGEST per-file sections (bulk artifacts by construction) are omitted
# until it fits, each replaced with an explicit placeholder line, and every
# omission is reported so the adapter can disclose it in the review prompt.
# The reviewer must never be led to believe an omitted file is absent from
# the PR — an undisclosed manual trim on #629 produced exactly that
# false-positive P1.

P4B_DEFAULT_DIFF_MAX_BYTES=600000   # ~150k tokens: fits every current
                                    # reviewer CLI context with headroom
P4B_MIN_DIFF_MAX_BYTES=4096
P4B_MAX_DIFF_MAX_BYTES=10485760

# The repo-relative path of the review policy file as it appears in PR
# diffs. This is deliberately NOT derived from p4b_config():
# MERGEPATH_REVIEW_POLICY_PATH points the CONFIG READERS at an absolute
# (often temp) file for tests and manual runs, but the omission-provenance
# guard below keys on the path a PR's diff sections carry, which is always
# the canonical in-repo location.
P4B_REVIEW_POLICY_REPO_PATH=".github/review-policy.yml"

# p4b_resolve_diff_max_bytes
# Resolve the review-diff byte budget: P4B_DIFF_MAX_BYTES env override
# (tests/manual escape hatch — integer-validated but not range-bounded,
# mirroring the P4B_*_TIMEOUT_SECONDS envs) → the
# phase_4b_automation.diff_max_bytes policy knob (bounded fail-closed, like
# adapter_timeout_seconds) → P4B_DEFAULT_DIFF_MAX_BYTES. Prints the budget
# on success; returns non-zero (no output) on an invalid configured value
# so the caller fails closed instead of running the CLI mis-bounded.
p4b_resolve_diff_max_bytes() {
  local val
  if [ -n "${P4B_DIFF_MAX_BYTES:-}" ]; then
    case "$P4B_DIFF_MAX_BYTES" in
      *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$P4B_DIFF_MAX_BYTES"
    return 0
  fi
  val="$(p4b_automation_field diff_max_bytes)"
  [ -n "$val" ] || { printf '%s' "$P4B_DEFAULT_DIFF_MAX_BYTES"; return 0; }
  case "$val" in
    *[!0-9]*) return 1 ;;
  esac
  if [ "$val" -lt "$P4B_MIN_DIFF_MAX_BYTES" ] \
     || [ "$val" -gt "$P4B_MAX_DIFF_MAX_BYTES" ]; then
    return 1
  fi
  printf '%s' "$val"
}

# p4b_diff_omit_globs
# Newline-separated shell-glob allowlist of paths whose diff sections MAY be
# omitted from an over-budget review diff. Resolution: P4B_DIFF_OMIT_GLOBS
# env override (comma-separated; tests/manual runs) → the
# phase_4b_automation.diff_omit_globs policy list → EMPTY. Empty means no
# section is omission-eligible, so an over-budget diff fails closed to the
# manual handoff. This is the structural guard the Phase 4b substitute gate
# needs (#636 Codex P1): trimming by size alone could silently drop a large
# APPLICATION-CODE section and let the posted APPROVED clear a merge on code
# no reviewer saw — only operator-declared bulk-artifact paths are ever
# omitted. Patterns are bash `case` globs (`*` crosses `/`); a section is
# eligible only when EVERY repo path it touches — b/-side, a/-side, and any
# rename/copy source or destination — matches (see p4b_trim_review_diff).
#
# PROVENANCE: this reads the CURRENT CHECKOUT's policy file. The #628
# trusted-path rule (run the orchestrator from a trusted main-ref checkout)
# is what makes that read trustworthy operationally; the mechanical
# backstop lives in p4b_trim_review_diff, which refuses ALL omission when
# the diff under review itself touches the policy file (#668).
p4b_diff_omit_globs() {
  local cfg
  if [ -n "${P4B_DIFF_OMIT_GLOBS:-}" ]; then
    printf '%s\n' "$P4B_DIFF_OMIT_GLOBS" | tr ',' '\n' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
    return 0
  fi
  cfg="$(p4b_config)"
  [ -f "$cfg" ] || return 0
  awk '
    /^phase_4b_automation:/ { inblk=1; inlist=0; next }
    inblk && /^[^[:space:]#]/ { inblk=0; inlist=0 }
    inblk {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      if ($0 ~ /^[[:space:]]*diff_omit_globs:[[:space:]]*$/) { inlist=1; next }
      if (inlist) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
          line = $0
          sub(/^[[:space:]]*-[[:space:]]*/, "", line)
          gsub(/[[:space:]]*#.*$/, "", line)
          gsub(/^["\047]/, "", line); gsub(/["\047][[:space:]]*$/, "", line)
          sub(/[[:space:]]+$/, "", line)
          if (line != "") print line
          next
        }
        inlist = 0
      }
    }
  ' "$cfg"
}

# p4b_path_matches_any_glob <path> <globs-newline-separated>
p4b_path_matches_any_glob() {
  local path="$1" g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # $g is intentionally unquoted: it is the glob pattern itself.
    # shellcheck disable=SC2254
    case "$path" in
      $g) return 0 ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# p4b_trim_review_diff <in_file> <out_file> <max_bytes> [<omit_globs>]
# Byte-bound a unified diff for reviewer-CLI consumption. Under-budget input
# is copied through verbatim (empty stdout). Over-budget input has its
# largest OMISSION-ELIGIBLE per-file sections omitted, each replaced in the
# output with a single
#   [phase-4b diff-budget: <path> omitted - oversized diff section]
# placeholder line, and one "<path><TAB><bytes>" line per omission printed
# on stdout for the caller's disclosure note. Returns non-zero (fail-closed)
# when omitting every eligible section still cannot meet the budget (never
# omits a non-eligible section), or when no reviewable file section survives
# — the caller must fall back rather than review a husk or approve around
# unreviewed code.
#
# Eligible = EVERY repo path the section touches matches <omit_globs>
# (newline-separated shell globs; see p4b_diff_omit_globs). A section touches
# its b/-side path, its a/-side path, AND — for a rename or copy — the
# `rename from` / `copy from` source and `rename to` / `copy to`
# destination. Checking only the b/-side (the #636 round-1 shape) let a
# large rename FROM a non-allowlisted application path (`src/foo.sh`) TO an
# allowlisted artifact path (`docs/audits/data/foo.sh`) be omitted, hiding
# the removal of application code while an APPROVED could still post (#636
# round-2 P1). Requiring the a/-side and rename/copy source to be
# allowlisted too fails such a section closed; the explicit rename/copy
# DESTINATION lines are checked as well (#668) so eligibility never rests
# solely on the header-derived split when the section carries exact paths.
#
# Omission-allowlist provenance (#668, the #636 sibling): <omit_globs> is
# read from the CURRENT CHECKOUT's .github/review-policy.yml. A PR that
# itself edits that file could broaden the allowlist (e.g. to `src/*`),
# pair it with an over-budget diff, and have this function omit
# application-code sections from the reviewer input while an APPROVED still
# posts. The #628 trusted-path rule (orchestrator runs from a trusted
# main-ref checkout) mitigates that only operationally; the mechanical
# guard is here: when omission is needed (the diff is over budget) and ANY
# section touches $P4B_REVIEW_POLICY_REPO_PATH on any side, this function
# refuses omission entirely and returns non-zero, so the run falls back to
# the manual handoff instead of trusting an allowlist the PR under review
# may have rewritten. Under-budget diffs are unaffected — they pass through
# verbatim and the allowlist plays no role. The trust argument mirrors the
# #429 head-pinned exemption: only inputs the PR author cannot influence
# may decide what the reviewer never sees.
# Shared awk function that recovers the b/-side (new) path from a `diff --git`
# header, used by BOTH awk passes in p4b_trim_review_diff so the omit decision
# and the omission-placeholder disclosure key off an identical path (#697).
#
# For a RENAME/COPY the section carries an explicit `rename to`/`copy to` line,
# and THAT is the authoritative new path — the header split is only a heuristic.
# So when the caller knows the destination (rto non-empty) it is returned
# verbatim; the header is never re-parsed for renames/copies (#712). This also
# closes the mis-split where a crafted rename header (a != b) whose concatenated
# "A b/B" text happens to contain an earlier SYMMETRIC " b/" split — e.g.
# `diff --git a/data/a b/data/a b/data/a b/data/a` renaming `data/a b/data/a
# b/data/a` to `data/a` — would otherwise return the synthetic midpoint instead
# of the real b-side.
#
# For a plain EDIT header `diff --git a/P b/P` no rto exists (rto empty): the
# a/- and b/-sides are equal, so the real b-path is the value V for which the
# remainder after stripping the leading "a/" is exactly "V b/V". This is
# recovered even when V itself contains the literal " b/" (e.g. P = `foo b/bar`),
# which a bare greedy `sub(/^diff --git a\/.* b\//, "", p)` mis-splits. If no
# symmetric split exists (a modeless header with a != b and no rto — e.g. a mode
# change with differing sides, which the pre-#712 code also handled greedily) it
# falls back to the greedy last-" b/" tail.
P4B_DIFF_BSIDE_AWK_FN='
function p4b_diff_bside(hdr, rto,   rest, greedy, i, nxt, left, right) {
  if (rto != "") return rto
  rest = hdr; sub(/^diff --git a\//, "", rest)
  greedy = hdr; sub(/^diff --git a\/.* b\//, "", greedy)
  i = index(rest, " b/")
  while (i > 0) {
    left = substr(rest, 1, i - 1)
    right = substr(rest, i + 3)
    if (left == right) return left
    nxt = index(substr(rest, i + 1), " b/")
    if (nxt == 0) break
    i = i + nxt
  }
  return greedy
}
'

p4b_trim_review_diff() {
  local in="$1" out="$2" max="$3" globs="${4:-}" total sizes omit="" projected
  local b i bside aside rfrom rto p plh plen
  [ -r "$in" ] || return 1
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  total="$(wc -c < "$in" | tr -d '[:space:]')"
  if [ "$total" -le "$max" ]; then
    cp "$in" "$out" || return 1
    return 0
  fi
  # Per-section metadata as
  # "bytes<TAB>index<TAB>bside<TAB>aside<TAB>rename_from<TAB>rename_to",
  # largest first. Sections are keyed by INDEX (omission never depends on path
  # parsing); the b/-side is the display path, and a/-side + rename/copy
  # source/destination are carried so the caller can require EVERY touched
  # path to be allowlisted. a/-side is derived by stripping the parsed
  # " b/<bside>" suffix, so it uses the same split point as the b/-side.
  # LC_ALL=C keeps length() byte-exact.
  sizes="$(LC_ALL=C awk '
    '"$P4B_DIFF_BSIDE_AWK_FN"'
    /^diff --git /{ n++; hdr[n] = $0; bytes[n] = 0; rfrom[n] = ""; rto[n] = "" }
    n > 0 { bytes[n] += length($0) + 1 }
    /^rename from /{ if (n > 0 && rfrom[n] == "") rfrom[n] = substr($0, 13) }
    /^copy from /  { if (n > 0 && rfrom[n] == "") rfrom[n] = substr($0, 11) }
    /^rename to /  { if (n > 0 && rto[n]   == "") rto[n]   = substr($0, 11) }
    /^copy to /    { if (n > 0 && rto[n]   == "") rto[n]   = substr($0, 9)  }
    END {
      for (i = 1; i <= n; i++) {
        b = p4b_diff_bside(hdr[i], rto[i])
        a = hdr[i]; sub(/^diff --git a\//, "", a)
        suf = " b/" b
        if (substr(a, length(a) - length(suf) + 1) == suf) a = substr(a, 1, length(a) - length(suf))
        printf "%d\t%d\t%s\t%s\t%s\t%s\n", bytes[i], i, b, a, rfrom[i], rto[i]
      }
    }
  ' "$in" | sort -rn)"
  [ -n "$sizes" ] || return 1
  # Omission-allowlist provenance guard (#668): omission is needed past this
  # point, and the allowlist was read from the current checkout's policy
  # file — the ONE repo path whose in-PR modification could have rewritten
  # the allowlist this run is judged by. If any section touches it on any
  # side (edit, delete, rename/copy in or out), refuse omission entirely so
  # the caller falls back to the manual handoff. See the function comment
  # for the trust argument.
  while IFS=$'\t' read -r b i bside aside rfrom rto; do
    for p in "$bside" "$aside" "$rfrom" "$rto"; do
      if [ "$p" = "$P4B_REVIEW_POLICY_REPO_PATH" ]; then
        return 1
      fi
    done
  done <<EOF
$sizes
EOF
  # Omit largest-first until the PROJECTED output size fits. `projected` models
  # the exact output byte count — each omission removes the section's bytes and
  # adds its placeholder line — so a placeholder can no longer push the final
  # output back over budget after the loop stops (#636 round-2 P2).
  projected="$total"
  while IFS=$'\t' read -r b i bside aside rfrom rto; do
    [ "$projected" -le "$max" ] && break
    p4b_path_matches_any_glob "$bside" "$globs" || continue
    p4b_path_matches_any_glob "$aside" "$globs" || continue
    if [ -n "$rfrom" ]; then
      p4b_path_matches_any_glob "$rfrom" "$globs" || continue
    fi
    if [ -n "$rto" ]; then
      p4b_path_matches_any_glob "$rto" "$globs" || continue
    fi
    plh="[phase-4b diff-budget: ${bside} omitted - oversized diff section; see the prompt note]"
    plen="$(printf '%s\n' "$plh" | LC_ALL=C wc -c | tr -d '[:space:]')"
    projected=$(( projected - b + plen ))
    omit="$omit $i"
    printf '%s\t%s\n' "$bside" "$b"
  done <<EOF
$sizes
EOF
  [ "$projected" -le "$max" ] || return 1
  LC_ALL=C awk -v omit_list="$omit" '
    '"$P4B_DIFF_BSIDE_AWK_FN"'
    BEGIN { split(omit_list, parts, " "); for (k in parts) if (parts[k] != "") omit[parts[k]] = 1 }
    # #697/#712: name the omitted file with the SAME b/-side derivation the
    # sizes pipeline used to key the omit decision (p4b_diff_bside, defined
    # above, with the authoritative rename/copy destination when the section
    # carries one), so the disclosure can never name a different path than the
    # one omission was judged on. A bare greedy `sub(/^diff --git a\/.* b\//,
    # "", p)` mis-splits a header whose path contains the literal " b/", and the
    # header symmetric-split heuristic mis-splits a crafted rename header — both
    # are avoided here. The header is buffered until its `rename to`/`copy to`
    # line (if any) is seen, so the placeholder is emitted with the true rto.
    function p4b_flush_pending(   line) {
      if (!pending) return
      if (pending_skip) {
        line = p4b_diff_bside(pending_hdr, pending_rto)
        printf "[phase-4b diff-budget: %s omitted - oversized diff section; see the prompt note]\n", line
      }
      pending = 0
    }
    /^diff --git /{
      p4b_flush_pending()
      n++
      pending = 1; pending_hdr = $0; pending_rto = ""
      skipping = ((n "") in omit) ? 1 : 0
      pending_skip = skipping
      if (!skipping) print
      next
    }
    pending && /^rename to /{ if (pending_rto == "") pending_rto = substr($0, 11); if (!pending_skip) print; next }
    pending && /^copy to /  { if (pending_rto == "") pending_rto = substr($0, 9);  if (!pending_skip) print; next }
    !skipping { print }
    END { p4b_flush_pending() }
  ' "$in" > "$out" || return 1
  # Placeholders add bytes the loop above does not model; assert the OUTPUT
  # honors the budget and still carries at least one reviewable section.
  [ "$(wc -c < "$out" | tr -d '[:space:]')" -le "$max" ] || return 1
  grep -q '^diff --git ' "$out" || return 1
  return 0
}

# p4b_stderr_tail <file>
# One sanitized line (<= ~400 bytes) from the tail of a captured stderr
# file, for embedding the reviewer CLI's actual complaint in a failure
# message. Non-printable bytes are blanked and whitespace runs collapsed;
# an empty or missing file prints nothing. (#635: the previous rc!=0
# handling guessed "auth" for every failure — a context-overflow rc=1 read
# as a login problem while the CLI's real error was discarded.)
#
# #696: the tail is interpolated straight into p4b_die messages that can
# surface in workflow logs and the Phase 4b manual-fallback comment. A
# reviewer CLI that emits an auth error carrying a token/key in stderr would
# otherwise leak it there, so mask obvious secret patterns BEFORE returning.
# The redaction pass is intentionally over-broad (any word that looks like a
# credential is masked) and portable: `sed -E` (ERE) is honored by both BSD
# sed (macOS bash-3.2) and GNU sed, the same form other scripts in this repo
# already rely on.
p4b_stderr_tail() {
  [ -n "${1:-}" ] && [ -s "$1" ] || return 0
  tail -c 400 "$1" \
    | LC_ALL=C tr -c '[:print:]' ' ' \
    | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ *//' -e 's/ *$//' \
    | sed -E \
        -e 's/(gh[posru]|github_pat)_[A-Za-z0-9_]+/\1_[REDACTED]/g' \
        -e 's/sk-[A-Za-z0-9_-]+/sk-[REDACTED]/g' \
        -e 's/([Bb]earer )[A-Za-z0-9._~+\/-]+=*/\1[REDACTED]/g' \
        -e 's/([Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn])([[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/g'
}

# --- plan-only reviewer CLI auth guards ------------------------------------

p4b_codex_auth_file() {
  if [ -n "${P4B_CODEX_AUTH_FILE:-}" ]; then
    printf '%s' "$P4B_CODEX_AUTH_FILE"
    return 0
  fi
  if [ -n "${CODEX_HOME:-}" ]; then
    printf '%s/auth.json' "$CODEX_HOME"
    return 0
  fi
  printf '%s/.codex/auth.json' "$HOME"
}

p4b_require_codex_plan_auth() {
  local auth_file mode
  auth_file="$(p4b_codex_auth_file)"
  [ -r "$auth_file" ] || p4b_die 4 "codex plan login not found at $auth_file; run codex login (API-key auth is not allowed for Phase 4b)"
  mode="$(jq -r '.auth_mode // empty' "$auth_file" 2>/dev/null || true)"
  [ "$mode" = "chatgpt" ] || p4b_die 4 "codex auth_mode is '${mode:-unknown}', not 'chatgpt'; API-key auth is not allowed for Phase 4b"
}

p4b_claude_auth_status() {
  local claude_bin="$1"
  if [ -n "${P4B_CLAUDE_AUTH_STATUS_FILE:-}" ]; then
    cat "$P4B_CLAUDE_AUTH_STATUS_FILE"
    return 0
  fi
  "$claude_bin" auth status --json 2>/dev/null
}

p4b_require_claude_plan_auth() {
  local claude_bin="$1" status logged_in auth_method api_provider subscription_type
  status="$(p4b_claude_auth_status "$claude_bin")" \
    || p4b_die 4 "claude plan login status could not be read; run claude auth login (API-key auth is not allowed for Phase 4b)"
  logged_in="$(printf '%s' "$status" | jq -r '.loggedIn // false' 2>/dev/null || true)"
  auth_method="$(printf '%s' "$status" | jq -r '.authMethod // empty' 2>/dev/null || true)"
  api_provider="$(printf '%s' "$status" | jq -r '.apiProvider // empty' 2>/dev/null || true)"
  subscription_type="$(printf '%s' "$status" | jq -r '.subscriptionType // empty' 2>/dev/null || true)"
  [ "$logged_in" = "true" ] || p4b_die 4 "claude is not logged in; run claude auth login (API-key auth is not allowed for Phase 4b)"
  case "$auth_method" in
    claude.ai|oauth_token) ;;
    *) p4b_die 4 "claude authMethod is '${auth_method:-unknown}', not a first-party subscription method; API-key auth is not allowed for Phase 4b" ;;
  esac
  [ "$api_provider" = "firstParty" ] || p4b_die 4 "claude apiProvider is '${api_provider:-unknown}', not 'firstParty'; API-key auth is not allowed for Phase 4b"
  if [ "$auth_method" = "claude.ai" ]; then
    [ -n "$subscription_type" ] && [ "$subscription_type" != "null" ] \
      || p4b_die 4 "claude subscriptionType is missing; a Claude Code subscription login is required for Phase 4b"
  fi
}
