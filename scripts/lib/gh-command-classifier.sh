#!/usr/bin/env bash
# Shared command-prefix vocabulary for the gh pre-write guard and wrappers.
# Sourcing contract: no top-level side effects; Bash 3.2 portable.

# Value-consuming options must stay single-sourced: both the hook's tokenizer
# and the wrapper classifier use this exact table.
GH_PREFIX_VALUE_OPTS_SPEC="sudo=-u,--user,-g,--group,-p,--prompt,-h,--host,-t,--type,-r,--role,-C,--close-from,-D,--chdir,-R,--chroot,-U,--other-user,-T,--command-timeout;nice=-n,--adjustment;ionice=-c,--class,-n,--classdata,-p,--pid;env=-u,--unset,-C,--chdir;exec=-a;time=-f,--format,-o,--output"

gh_prefix_flag_takes_value() {
  local pfx="$1" opt="$2" spec opts candidate
  spec=";$GH_PREFIX_VALUE_OPTS_SPEC"
  case "$spec" in
    *";$pfx="*) ;;
    *) return 1 ;;
  esac
  opts="${spec##*;$pfx=}"
  opts="${opts%%;*}"
  local IFS=,
  for candidate in $opts; do
    [ "$candidate" = "$opt" ] && return 0
  done
  return 1
}

gh_prefix_flag_has_attached_value() {
  local pfx="$1" token="$2" spec opts candidate
  spec=";$GH_PREFIX_VALUE_OPTS_SPEC"
  case "$spec" in
    *";$pfx="*) ;;
    *) return 1 ;;
  esac
  opts="${spec##*;$pfx=}"
  opts="${opts%%;*}"
  local IFS=,
  for candidate in $opts; do
    case "$candidate" in
      --*) [ "${token#"$candidate"=}" != "$token" ] && return 0 ;;
      -?) [ "$token" != "$candidate" ] && [ "${token#"$candidate"}" != "$token" ] && return 0 ;;
    esac
  done
  return 1
}

# Return success only when argv resolves, through the literal prefix forms the
# guard understands, to `gh ... pr create|new`. This is classification only;
# the caller preserves and executes the original argv.
gh_is_pr_create_command() {
  local executable prefix saw_pr argument skip_value consumed argument_index

  # Successful classification exposes the original argv index of create|new.
  # Callers that must inspect only PR-create flags can preserve every prefix
  # token verbatim and start parsing after this boundary.
  GH_PR_CREATE_VERB_INDEX=-1
  consumed=0

  while [ "$#" -gt 0 ]; do
    executable="${1##*/}"
    case "$executable" in
      gh) break ;;
      env)
        prefix=$executable
        shift
        consumed=$((consumed + 1))
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --) shift; consumed=$((consumed + 1)); break ;;
            *=*) shift; consumed=$((consumed + 1)) ;;
            -S|--split-string|--split-string=*) return 1 ;;
            *)
              if gh_prefix_flag_takes_value "$prefix" "$1"; then
                [ "$#" -ge 2 ] || return 1
                shift 2
                consumed=$((consumed + 2))
              elif gh_prefix_flag_has_attached_value "$prefix" "$1"; then
                shift
                consumed=$((consumed + 1))
              elif [ "${1#-}" != "$1" ]; then
                shift
                consumed=$((consumed + 1))
              else
                break
              fi
              ;;
          esac
        done
        ;;
      command)
        shift
        consumed=$((consumed + 1))
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --) shift; consumed=$((consumed + 1)); break ;;
            -p) shift; consumed=$((consumed + 1)) ;;
            -v|-V) return 1 ;;
            *) break ;;
          esac
        done
        ;;
      sudo|time|nohup|exec|nice|ionice)
        prefix=$executable
        shift
        consumed=$((consumed + 1))
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --) shift; consumed=$((consumed + 1)); break ;;
            *)
              if gh_prefix_flag_takes_value "$prefix" "$1"; then
                [ "$#" -ge 2 ] || return 1
                shift 2
                consumed=$((consumed + 2))
              elif gh_prefix_flag_has_attached_value "$prefix" "$1"; then
                shift
                consumed=$((consumed + 1))
              elif [ "${1#-}" != "$1" ]; then
                shift
                consumed=$((consumed + 1))
              else
                break
              fi
              ;;
          esac
        done
        ;;
      *) return 1 ;;
    esac
  done

  [ "$#" -gt 0 ] || return 1
  case "${1##*/}" in gh) ;; *) return 1 ;; esac
  shift
  consumed=$((consumed + 1))

  saw_pr=0
  skip_value=0
  argument_index=$consumed
  for argument in "$@"; do
    if [ "$skip_value" -eq 1 ]; then
      skip_value=0
    else
      case "$argument" in
        -R|--repo|--hostname) skip_value=1 ;;
        -R?*|--repo=*|--hostname=*) ;;
        pr)
          [ "$saw_pr" -eq 0 ] || return 1
          saw_pr=1
          ;;
        create|new)
          if [ "$saw_pr" -eq 1 ]; then
            GH_PR_CREATE_VERB_INDEX=$argument_index
            return 0
          fi
          return 1
          ;;
        -*) ;;
        *) return 1 ;;
      esac
    fi
    argument_index=$((argument_index + 1))
  done
  return 1
}
