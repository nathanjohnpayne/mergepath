#!/usr/bin/env bash

# Shared mode selection for CI wrappers that combine a live structural
# assertion with an implementation regression suite.

ci_check_select_mode() {
  CI_CHECK_RUN_SELF_TEST=1

  if [ "${MERGEPATH_CONSUMER_SAFETY:-0}" = "1" ] && [ "$#" -eq 0 ]; then
    CI_CHECK_RUN_SELF_TEST=0
    return 0
  fi

  case "${1:-}" in
    "") ;;
    --check)
      [ "$#" -eq 1 ] || return 2
      CI_CHECK_RUN_SELF_TEST=0
      ;;
    --self-test)
      [ "$#" -eq 1 ] || return 2
      ;;
    *) return 2 ;;
  esac
}
