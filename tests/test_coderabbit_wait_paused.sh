#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's auto-pause `paused` state and
# the static auto-review skip checks (#490 / the real #485 case).
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep so the
# paused-resume loop, the resume-retry cap, and the non-base-branch / draft
# skips are deterministic and make no GitHub writes.
#
# The paused fixture is pinned to the #485 "Reviews paused" comment shape —
# the stable `<!-- ... review paused by coderabbit.ai -->` marker wrapping a
# "## Reviews paused" NOTE — so a CodeRabbit marker drift fails this test.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-paused.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The verbatim #485 "Reviews paused" comment body, single-line-escaped for the
# stubbed gh JSON. Regression-pins the comment SHAPE: the auto-generated marker
# plus the "## Reviews paused" NOTE and the resume/review bullets.
PAUSED_BODY_485='<!-- This is an auto-generated comment: review paused by coderabbit.ai -->\n\n> [!NOTE]\n> ## Reviews paused\n>\n> It looks like this branch is under active development. To avoid overwhelming you with review comments due to an influx of new commits, CodeRabbit has automatically paused this review. You can configure this behavior by changing the `reviews.auto_review.auto_pause_after_reviewed_commits` setting.\n>\n> - `@coderabbitai resume` to resume automatic reviews.\n> - `@coderabbitai review` to trigger a single review.\n\n<!-- end of auto-generated comment: review paused by coderabbit.ai -->'

# make_case <name> <max_wait> <max_resume_retries> [base_ref] [is_draft] [write_coderabbit_yml]
#   base_ref / is_draft default to main / false (the normal not-skipped PR).
#   write_coderabbit_yml=yes drops a .coderabbit.yml with base_branches:[main]
#   and drafts:false so the static-skip checks have something to read.
make_case() {
  local name=$1
  local max_wait=$2
  local max_resume=$3
  local base_ref=${4:-main}
  local is_draft=${5:-false}
  local write_coderabbit_yml=${6:-no}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: $max_wait
  status_probe_enabled: false
  max_rate_limit_retries: 2
  max_resume_retries: $max_resume
  wallclock_freshness_window_seconds: 999999999
  trust_status_context_for_clearance: false
EOF

  if [ "$write_coderabbit_yml" = "yes" ]; then
    cat >"$dir/.coderabbit.yml" <<'EOF'
reviews:
  auto_review:
    enabled: true
    drafts: false
    base_branches:
      - main
EOF
  fi

  cat >"$dir/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  cat "$clock_file"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$dir/bin/date"

  cat >"$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi
duration=${1:-0}
case "$duration" in
  *.*) duration=${duration%%.*} ;;
esac
current=$(cat "$clock_file")
printf '%s\n' $((current + duration)) >"$clock_file"
EOF
  chmod +x "$dir/bin/sleep"

  # The gh stub exports the case knobs to the subshell.
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export CODERABBIT_TEST_BASE_REF='$base_ref'
export CODERABBIT_TEST_IS_DRAFT='$is_draft'
export CODERABBIT_TEST_PAUSED_BODY='$PAUSED_BODY_485'
exec "$dir/bin/gh-impl" "\$@"
EOF
  chmod +x "$dir/bin/gh"

  cat >"$dir/bin/gh-impl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODERABBIT_TEST_STATE_DIR:?}
scenario=${CODERABBIT_TEST_SCENARIO:?}
bot='coderabbitai[bot]'
head_time='2026-06-04T00:00:00Z'
post_time='2026-06-04T00:00:01Z'
review_time='2026-06-04T00:00:30Z'

json_string() {
  jq -Rn --arg s "$1" '$s'
}

resume_count() {
  if [ -f "$state_dir/resume-count" ]; then cat "$state_dir/resume-count"; else printf '0\n'; fi
}

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 99
fi
shift

method="GET"
if [ "${1:-}" = "--method" ]; then
  method=${2:-}
  shift 2
fi
if [ "${1:-}" = "--paginate" ]; then
  shift
fi

endpoint=${1:-}
shift || true

if [ "$method" = "POST" ]; then
  body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f)
        case "${2:-}" in
          body=*) body=${2#body=} ;;
        esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  case "$endpoint" in
    repos/owner/repo/issues/999/comments)
      printf '%s\n' "$body" >>"$state_dir/post-bodies"
      case "$body" in
        *resume*)
          count=$(resume_count)
          count=$((count + 1))
          printf '%s\n' "$count" >"$state_dir/resume-count"
          ;;
      esac
      printf '{"id":9001,"created_at":"%s","body":%s}\n' "$post_time" "$(json_string "$body")"
      ;;
    *)
      echo "unexpected gh api POST endpoint: $endpoint" >&2
      exit 99
      ;;
  esac
  exit 0
fi

case "$endpoint" in
  repos/owner/repo/pulls/999)
    printf '{"head":{"sha":"head-sha"},"base":{"ref":"%s"},"draft":%s}\n' \
      "${CODERABBIT_TEST_BASE_REF:?}" "${CODERABBIT_TEST_IS_DRAFT:?}"
    ;;
  repos/owner/repo/commits/head-sha)
    if [ "${1:-}" = "--jq" ]; then
      printf '%s\n' "$head_time"
    else
      printf '{"commit":{"committer":{"date":"%s"}}}\n' "$head_time"
    fi
    ;;
  repos/owner/repo/commits/head-sha/statuses)
    printf '[]\n'
    ;;
  repos/owner/repo/issues/999/timeline)
    printf '[]\n'
    ;;
  repos/owner/repo/pulls/999/reviews)
    # Used by count_potential_issues on the clearance path.
    case "$scenario" in
      paused_then_review)
        if [ "$(resume_count)" -ge 1 ]; then
          printf '[{"id":9501,"user":{"login":"%s"},"submitted_at":"%s"}]\n' "$bot" "$review_time"
        else
          printf '[]\n'
        fi
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  repos/owner/repo/pulls/999/comments)
    printf '[]\n'
    ;;
  repos/owner/repo/issues/999/comments)
    case "$scenario" in
      paused_then_review)
        # First poll: paused NOTE. After we post resume, a clean review lands.
        if [ "$(resume_count)" -ge 1 ]; then
          printf '[{"id":9601,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 0**\\n\\nLGTM. No actionable comments."}]\n' \
            "$bot" "$review_time" "$review_time"
        else
          printf '[{"id":9301,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":%s}]\n' \
            "$bot" "$head_time" "$head_time" "$(json_string "${CODERABBIT_TEST_PAUSED_BODY:?}")"
        fi
        ;;
      paused_persists)
        # Every poll returns a NEW paused NOTE (fresh id) so the resume cap is
        # the thing that ends the loop, not a deduped same-id NOTE.
        n=$(resume_count)
        printf '[{"id":93%02d,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":%s}]\n' \
          "$n" "$bot" "$head_time" "$head_time" "$(json_string "${CODERABBIT_TEST_PAUSED_BODY:?}")"
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$dir/bin/gh-impl"

  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1
  local scenario=$2
  local rc=0

  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_SCENARIO="$scenario" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?

  printf '%s\n' "$rc"
}

resume_count() {
  local dir=$1
  if [ -f "$dir/state/resume-count" ]; then cat "$dir/state/resume-count"; else printf '0\n'; fi
}

post_bodies() {
  local dir=$1
  if [ -f "$dir/state/post-bodies" ]; then cat "$dir/state/post-bodies"; else printf ''; fi
}

# 1. The #485 case: paused NOTE detected → @coderabbitai resume posted →
#    polling resumes → a clean review clears (exit 0). NOT a timeout, NOT
#    rate_limit, and the resume verb (not `try again`) is used.
test_paused_resume_then_review_clears() {
  local dir rc status skip resumes bodies retries
  dir=$(make_case "paused-resume-review" 120 2)
  rc=$(run_case "$dir" paused_then_review)
  status=$(jq -r '.status' "$dir/out.json")
  skip=$(jq -r '.skip_reason' "$dir/out.json")
  resumes=$(resume_count "$dir")
  retries=$(jq -r '.resume_retries' "$dir/out.json")
  bodies=$(post_bodies "$dir")

  if [ "$rc" != "0" ]; then
    fail "paused resume->review: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "cleared" ]; then
    fail "paused resume->review: status=$status, expected cleared"
  elif [ "$skip" != "null" ]; then
    fail "paused resume->review: skip_reason=$skip, expected null (recovered, not skipped)"
  elif [ "$resumes" != "1" ]; then
    fail "paused resume->review: resume posts=$resumes, expected exactly 1"
  elif [ "$retries" != "1" ]; then
    fail "paused resume->review: resume_retries=$retries, expected 1"
  elif ! printf '%s' "$bodies" | grep -Fq "@coderabbitai resume"; then
    fail "paused resume->review: did not post '@coderabbitai resume'; posts=[$bodies]"
  elif printf '%s' "$bodies" | grep -Fq "try again"; then
    fail "paused resume->review: posted a rate-limit 'try again' instead of resume; posts=[$bodies]"
  else
    pass "auto-pause detected → @coderabbitai resume → review clears (exit 0, resume_retries=1)"
  fi
}

# 2. Durable pause: CodeRabbit keeps re-pausing. After max_resume_retries the
#    helper exits 6 (skipped) with status=paused and skip_reason=paused —
#    NOT exit 4 (timeout). Bounded resume posts == the cap.
test_paused_persists_exhausts_cap_exit6() {
  local dir rc status skip resumes retries
  dir=$(make_case "paused-persists" 600 2)
  rc=$(run_case "$dir" paused_persists)
  status=$(jq -r '.status' "$dir/out.json")
  skip=$(jq -r '.skip_reason' "$dir/out.json")
  resumes=$(resume_count "$dir")
  retries=$(jq -r '.resume_retries' "$dir/out.json")

  if [ "$rc" = "4" ]; then
    fail "paused persists: exit 4 (timeout) — the #485 bug; expected 6 (skipped). stderr=$(cat "$dir/err.log")"
  elif [ "$rc" != "6" ]; then
    fail "paused persists: exit $rc, expected 6; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "paused" ]; then
    fail "paused persists: status=$status, expected paused"
  elif [ "$skip" != "paused" ]; then
    fail "paused persists: skip_reason=$skip, expected paused"
  elif [ "$resumes" != "2" ]; then
    fail "paused persists: resume posts=$resumes, expected 2 (== max_resume_retries)"
  elif [ "$retries" != "2" ]; then
    fail "paused persists: resume_retries=$retries, expected 2"
  else
    pass "durable auto-pause exhausts resume cap → exit 6 status=paused skip_reason=paused (never exit 4)"
  fi
}

# 3. Static skip: PR base branch ∉ configured base_branches → exit 6,
#    skip_reason=non-base-branch, BEFORE any polling, no resume posted.
test_non_base_branch_skip_exit6() {
  local dir rc status skip resumes
  dir=$(make_case "non-base-branch" 600 2 "release/legacy" false yes)
  rc=$(run_case "$dir" idle)
  status=$(jq -r '.status' "$dir/out.json")
  skip=$(jq -r '.skip_reason' "$dir/out.json")
  resumes=$(resume_count "$dir")

  if [ "$rc" != "6" ]; then
    fail "non-base-branch: exit $rc, expected 6; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "skipped" ]; then
    fail "non-base-branch: status=$status, expected skipped"
  elif [ "$skip" != "non-base-branch" ]; then
    fail "non-base-branch: skip_reason=$skip, expected non-base-branch"
  elif [ "$resumes" != "0" ]; then
    fail "non-base-branch: resume posts=$resumes, expected 0 (no re-invocation on a non-invocable skip)"
  else
    pass "non-base-branch PR surfaces skip_reason=non-base-branch and exits 6 without polling"
  fi
}

# 4. Static skip: draft PR when drafts:false → exit 6, skip_reason=draft.
test_draft_skip_exit6() {
  local dir rc status skip resumes
  dir=$(make_case "draft-skip" 600 2 main true yes)
  rc=$(run_case "$dir" idle)
  status=$(jq -r '.status' "$dir/out.json")
  skip=$(jq -r '.skip_reason' "$dir/out.json")
  resumes=$(resume_count "$dir")

  if [ "$rc" != "6" ]; then
    fail "draft skip: exit $rc, expected 6; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "skipped" ]; then
    fail "draft skip: status=$status, expected skipped"
  elif [ "$skip" != "draft" ]; then
    fail "draft skip: skip_reason=$skip, expected draft"
  elif [ "$resumes" != "0" ]; then
    fail "draft skip: resume posts=$resumes, expected 0"
  else
    pass "draft PR with drafts:false surfaces skip_reason=draft and exits 6"
  fi
}

# 5. A base branch IN the allow-list and a non-draft must NOT trip the static
#    skip — the readers must not over-fire when .coderabbit.yml is present.
#    (Uses paused_then_review so the run still terminates deterministically.)
test_allowed_base_non_draft_not_skipped() {
  local dir rc status skip
  dir=$(make_case "allowed-base" 120 2 main false yes)
  rc=$(run_case "$dir" paused_then_review)
  status=$(jq -r '.status' "$dir/out.json")
  skip=$(jq -r '.skip_reason' "$dir/out.json")

  if [ "$status" = "skipped" ]; then
    fail "allowed base: status=skipped — static skip over-fired on an allowed base / non-draft PR"
  elif [ "$skip" = "non-base-branch" ] || [ "$skip" = "draft" ]; then
    fail "allowed base: skip_reason=$skip — static skip over-fired"
  elif [ "$rc" != "0" ] || [ "$status" != "cleared" ]; then
    fail "allowed base: exit $rc status=$status, expected cleared/0 (paused→resume→review); stderr=$(cat "$dir/err.log")"
  else
    pass "allowed base + non-draft PR is not statically skipped (paused→resume→review still clears)"
  fi
}

test_paused_resume_then_review_clears
test_paused_persists_exhausts_cap_exit6
test_non_base_branch_skip_exit6
test_draft_skip_exit6
test_allowed_base_non_draft_not_skipped

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
