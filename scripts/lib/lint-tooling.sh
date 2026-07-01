#!/usr/bin/env bash
# scripts/lib/lint-tooling.sh — visibility for OPTIONAL lint tooling.
#
# Sourced helper (Bash 3.2 / macOS portable; defines functions only, no side
# effects on source). Its job is to make a MISSING optional lint tool
# (shellcheck above all) impossible to miss, closing the #588 gap where a
# local run without ShellCheck passes SILENTLY while CI (which has it) later
# fails on warning-level issues. Before this helper, callers wrapped the lint
# in a bare `if command -v shellcheck; then … fi` and skipped with no message
# at all when it was absent.
#
# It can ALSO be run directly (`bash scripts/lib/lint-tooling.sh`) to print a
# one-shot availability report of optional lint tools — a lightweight repo
# setup check a developer can run before pushing.
#
# Strictness: when shellcheck is absent, the default is a loud WARN locally and
# a hard FAIL under CI (GitHub Actions sets CI=true), so CI actually catches a
# runner that has lost shellcheck instead of silently skipping the lint.
# Override either direction with MERGEPATH_REQUIRE_SHELLCHECK=1 (always require)
# or MERGEPATH_REQUIRE_SHELLCHECK=0 (never require, warn only).

# lint_tooling_strict — print "true" when a missing optional lint tool should
# be a hard failure in the current context, "false" when it should only warn.
# Precedence: explicit MERGEPATH_REQUIRE_SHELLCHECK override, else CI detection.
lint_tooling_strict() {
  case "${MERGEPATH_REQUIRE_SHELLCHECK:-}" in
    1|true|yes|on)   printf 'true';  return 0 ;;
    0|false|no|off)  printf 'false'; return 0 ;;
  esac
  if [ -n "${CI:-}" ] && [ "${CI}" != "false" ] && [ "${CI}" != "0" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# lint_tooling_require_shellcheck — the visibility gate. Returns 0 and prints
# nothing when shellcheck is present. When it is ABSENT it prints a loud,
# actionable message on stderr and returns 1 in strict mode (so the caller can
# fail its check) or 0 in warn-only mode (so a local run still succeeds).
lint_tooling_require_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    return 0
  fi
  if [ "$(lint_tooling_strict)" = "true" ]; then
    {
      echo "FAIL: shellcheck is not installed, but it is REQUIRED here (CI, or"
      echo "      MERGEPATH_REQUIRE_SHELLCHECK=1). Shell static analysis cannot"
      echo "      run, so warning-level issues would slip through unchecked."
      echo "      Install it: brew install shellcheck (macOS) /"
      echo "      apt-get install shellcheck (Debian) / dnf install ShellCheck."
    } >&2
    return 1
  fi
  {
    echo "WARN: shellcheck is not installed on this machine, so shell static"
    echo "      analysis was SKIPPED locally. CI runs shellcheck, so a clean"
    echo "      local run here can still FAIL CI on warning-level issues."
    echo "      Install it to catch them locally: brew install shellcheck"
    echo "      (macOS) / apt-get install shellcheck (Debian). Set"
    echo "      MERGEPATH_REQUIRE_SHELLCHECK=1 to make a missing shellcheck a"
    echo "      hard failure locally too."
  } >&2
  return 0
}

# lint_tooling_report — human-readable availability report for optional lint
# tools. Prints one line per tool on stdout and returns non-zero when a tool
# that is required in the current context (see lint_tooling_strict) is missing.
lint_tooling_report() {
  local rc=0 strict ver
  strict="$(lint_tooling_strict)"
  echo "Optional lint tooling ($([ "$strict" = true ] && echo 'strict: missing = FAIL' || echo 'lenient: missing = WARN')):"
  if command -v shellcheck >/dev/null 2>&1; then
    ver="$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2; exit}')"
    echo "  [ok]      shellcheck ${ver:-(unknown version)}"
  elif [ "$strict" = "true" ]; then
    echo "  [MISSING] shellcheck — REQUIRED here; install: brew install shellcheck"
    rc=1
  else
    echo "  [warn]    shellcheck — not installed; CI still lints. brew install shellcheck"
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "  [ok]      jq $(jq --version 2>/dev/null)"
  else
    echo "  [warn]    jq — not installed"
  fi
  return "$rc"
}

# Direct execution → print the availability report and exit with its status.
# When sourced, BASH_SOURCE[0] != $0 so this is skipped.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  lint_tooling_report
  exit $?
fi
