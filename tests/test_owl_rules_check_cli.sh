#!/usr/bin/env bash
# test_owl_rules_check_cli.sh — CLI-contract lock for scripts/owl-rules-check.py:
# the usage, missing-fixture, parse-error, and soft-pass exit codes.
#
# Run by .github/workflows/owl-rules-check.yml (where rdflib/owlrl are
# installed and OWL_CHECK_PYTHON names the venv python). It is NOT wired into
# repo_lint.yml. The argv/mode/missing-fixture assertions are
# dependency-independent (those branches run before the import guard); the
# parse-error assertion needs rdflib and self-skips without it, mirroring the
# checker's own self-bootstrap posture.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${OWL_CHECK_PYTHON:-python3}"
CHECKER="$REPO_ROOT/scripts/owl-rules-check.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
pass=0

check() { # check <label> <condition-rc>
  if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else
    echo "FAIL: $1" >&2
    fail=$((fail + 1))
  fi
}

expect_rc() { # expect_rc <label> <expected> <actual>
  if [ "$3" -eq "$2" ]; then pass=$((pass + 1)); else
    echo "FAIL: $1 (expected rc $2, got $3)" >&2
    fail=$((fail + 1))
  fi
}

run_checker() { # run_checker <python> <script> <args...> — echoes rc
  local py="$1" script="$2"; shift 2
  local rc=0
  "$py" "$script" "$@" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# ── Dependency-independent branches (run before the rdflib import) ──────────

expect_rc "unknown mode exits 2" 2 "$(run_checker python3 "$CHECKER" --bogus)"
expect_rc "surplus argument exits 2" 2 "$(run_checker python3 "$CHECKER" --check unexpected)"
expect_rc "surplus flag pair exits 2" 2 "$(run_checker python3 "$CHECKER" --check --report)"

# The usage diagnostic is part of the contract, not just the exit code.
usage_out="$(python3 "$CHECKER" --check unexpected 2>&1 || true)"
echo "$usage_out" | grep -q "owl-rules-check"; check "surplus argument prints the usage docstring" $?
echo "$usage_out" | grep -q "Exit codes:"; check "usage output names the exit-code contract" $?

# Missing fixture: a scratch tree mirroring the script-relative layout, with
# the violations fixture removed. These branches also precede the import.
SCRATCH="$WORK/tree"
mkdir -p "$SCRATCH/scripts" "$SCRATCH/docs/ontology/fixtures"
cp "$CHECKER" "$SCRATCH/scripts/"
cp "$REPO_ROOT/docs/ontology/mergepath-rules.ttl" "$SCRATCH/docs/ontology/"
cp "$REPO_ROOT/docs/ontology/fixtures/consistent.ttl" "$SCRATCH/docs/ontology/fixtures/"
expect_rc "missing violations fixture exits 2" 2 \
  "$(run_checker python3 "$SCRATCH/scripts/owl-rules-check.py" --check)"

# ── Dependency-bearing branches ─────────────────────────────────────────────

if "$PYTHON" -c 'import rdflib, owlrl' >/dev/null 2>&1; then
  cp "$REPO_ROOT/docs/ontology/fixtures/violations.ttl" "$SCRATCH/docs/ontology/fixtures/"
  printf '\nthis is not turtle @@@\n' >> "$SCRATCH/docs/ontology/mergepath-rules.ttl"
  rc="$(run_checker "$PYTHON" "$SCRATCH/scripts/owl-rules-check.py" --check)"
  expect_rc "corrupted TBox exits 2 (load error, not traceback)" 2 "$rc"
  out="$("$PYTHON" "$SCRATCH/scripts/owl-rules-check.py" --check 2>&1 || true)"
  echo "$out" | grep -q "failed to parse"; check "parse failure names the file" $?
  ! echo "$out" | grep -q "Traceback"; check "parse failure emits no traceback" $?
else
  echo "SKIP: rdflib/owlrl not available; skipping parse-error assertions (self-bootstrap)"
fi

# Soft-pass: only assertable when the invoking python genuinely lacks the
# reasoner stack; skip otherwise rather than manufacture a fake environment.
if ! python3 -c 'import rdflib' >/dev/null 2>&1; then
  expect_rc "dependency-free --check soft-passes 0" 0 "$(run_checker python3 "$CHECKER" --check)"
else
  echo "SKIP: system python3 has rdflib; soft-pass branch covered by the checker itself"
fi

echo "test_owl_rules_check_cli: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
