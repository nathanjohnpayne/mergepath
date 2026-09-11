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

# Read shell/workflow source from stdin and return success when its visible,
# direct GitHub CLI syntax contains a prohibited PR merge, REST write, or
# GraphQL mutation. This is a static regression guard, not a Bash sandbox: it
# grades literal/path-qualified `gh` invocations and rejects several ambiguous
# direct-command forms, but runtime credential separation and trusted-checkout
# execution remain the security boundary against generated command dispatch.
# The one optional exception is the exact label DELETE used by the trusted
# auto-clear workflow; any spelling or command suffix drift fails closed and
# must be reviewed explicitly.
gh_source_has_direct_literal_pr_mutation() {
  local mode source allowed_delete prefix suffix normalized api_count
  local protected_source dynamic_scan content_scan graphql_segment gh_command_start_re
  local api_command_start_re method_flag_re api_segment method_count get_count
  local literal_marker_prefix literal_space literal_newline literal_semi
  local literal_amp literal_pipe literal_lparen literal_rparen literal_lbrace
  local literal_rbrace literal_newline_boundary
  mode="${1:-}"
  case "$mode" in
    ""|--allow-needs-external-review-delete) ;;
    *) return 2 ;;
  esac

  source=$(cat) || return 2
  # Bash removes an unquoted backslash-newline pair before tokenization; it
  # does not insert whitespace. Preserve token-internal joins such as `g\
  # h` -> `gh` so a direct literal command cannot be split around the scan.
  source=${source//$'\\\n'/}
  # Heredoc payload is not shell syntax: quotes and mutation-looking text in
  # it must not affect lexical state, while a later command still executes.
  # Reject a real unquoted heredoc opener before reading its payload. Quoted
  # `name<<EOF` data, inline comments, arithmetic shifts, and here-strings are
  # not heredoc operators and remain available to guarded source.
  if printf '%s\n' "$source" | awk '
    function array_assignment_shift(line, position, open, close_pos, j, char, name_end, name, prefix, after, subscript) {
      open = 0
      for (j = position - 1; j >= 1; j--) {
        char = substr(line, j, 1)
        if (char == "]") return 0
        if (char == "[") { open = j; break }
        if (char ~ /[;&|()[:space:]]/) return 0
      }
      if (open == 0) return 0
      name_end = open - 1
      j = name_end
      while (j >= 1 && substr(line, j, 1) ~ /[[:alnum:]_]/) j--
      if (j == name_end) return 0
      name = substr(line, j + 1, name_end - j)
      if (name !~ /^[[:alpha:]_][[:alnum:]_]*$/) return 0
      # A subscript-looking word after a command name is still an argument,
      # where `<<` is a real heredoc operator (for example
      # `echo a[1<<EOF]=x`). Only exempt a line-leading assignment command;
      # broader shell-keyword/control-flow forms fail closed.
      prefix = j >= 1 ? substr(line, 1, j) : ""
      if (prefix !~ /^[[:space:]]*$/) return 0
      close_pos = index(substr(line, position + 2), "]")
      if (close_pos == 0) return 0
      close_pos += position + 1
      # Keep the exemption deliberately smaller than Bash arithmetic. A
      # numeric literal shift is unambiguously part of this assignment word;
      # names, whitespace, or shell punctuation after `<<` can instead form a
      # real heredoc opener and must fail closed.
      subscript = substr(line, open + 1, close_pos - open - 1)
      if (subscript !~ /^[[:digit:]]+<<[[:digit:]]+$/) return 0
      after = substr(line, close_pos + 1, 2)
      return substr(after, 1, 1) == "=" || after == "+="
    }
    BEGIN {
      single = 0
      double = 0
      escaped = 0
      command_depth = 0
      arithmetic_depth = 0
      legacy_arithmetic_depth = 0
      parameter_depth = 0
      parameter_frame_counter = 0
      found = 0
    }
    {
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (escaped) { escaped = 0; continue }
        if (char == "\\" && !single) { escaped = 1; continue }
        if (arithmetic_depth > 0) {
          if (char == "\"" && !single) { double = !double; continue }
          if (char == "\047" && !double) { single = !single; continue }
          if (!single && char == "`") {
            found = 1
            exit
          }
          # Nested substitution inside arithmetic is outside this small lexer;
          # reject it rather than letting nested quote state hide a heredoc.
          if (!single && char == "$" \
              && substr($0, i + 1, 1) ~ /[({\[]/) {
            found = 1
            exit
          }
          if (single || double) continue
          if (char == "(") arithmetic_parens[arithmetic_depth]++
          if (char == ")") {
            arithmetic_parens[arithmetic_depth]--
            if (arithmetic_parens[arithmetic_depth] == 0) {
              single = arithmetic_single[arithmetic_depth]
              double = arithmetic_double[arithmetic_depth]
              delete arithmetic_single[arithmetic_depth]
              delete arithmetic_double[arithmetic_depth]
              delete arithmetic_parens[arithmetic_depth]
              parameter_depth = arithmetic_parameter[arithmetic_depth]
              delete arithmetic_parameter[arithmetic_depth]
              arithmetic_depth--
            }
          }
          continue
        }
        if (legacy_arithmetic_depth > 0) {
          if (char == "\"" && !single) { double = !double; continue }
          if (char == "\047" && !double) { single = !single; continue }
          if (!single && char == "`") {
            found = 1
            exit
          }
          if (!single && char == "$" \
              && substr($0, i + 1, 1) ~ /[({\[]/) {
            found = 1
            exit
          }
          if (single || double) continue
          if (char == "[") legacy_arithmetic_brackets[legacy_arithmetic_depth]++
          if (char == "]") {
            legacy_arithmetic_brackets[legacy_arithmetic_depth]--
            if (legacy_arithmetic_brackets[legacy_arithmetic_depth] == 0) {
              single = legacy_arithmetic_single[legacy_arithmetic_depth]
              double = legacy_arithmetic_double[legacy_arithmetic_depth]
              parameter_depth = legacy_arithmetic_parameter[legacy_arithmetic_depth]
              delete legacy_arithmetic_single[legacy_arithmetic_depth]
              delete legacy_arithmetic_double[legacy_arithmetic_depth]
              delete legacy_arithmetic_parameter[legacy_arithmetic_depth]
              delete legacy_arithmetic_brackets[legacy_arithmetic_depth]
              legacy_arithmetic_depth--
            }
          }
          continue
        }
        if (parameter_depth > 0) {
          if (!single && char == "$" && substr($0, i + 1, 2) == "((") {
            found = 1
            exit
          }
          if (!single && char == "$" && substr($0, i + 1, 1) == "[") {
            found = 1
            exit
          }
          if (!single && char == "$" && substr($0, i + 1, 1) == "(") {
            command_depth++
            saved_single[command_depth] = single
            saved_double[command_depth] = double
            saved_parameter[command_depth] = parameter_depth
            command_parens[command_depth] = 1
            parameter_depth = 0
            single = 0
            double = 0
            i++
            continue
          }
          if (!single && char == "$" && substr($0, i + 1, 1) == "{") {
            parameter_frame_counter++
            new_parameter_frame = parameter_frame_counter
            parameter_parent[new_parameter_frame] = parameter_depth
            parameter_depth = new_parameter_frame
            parameter_single[parameter_depth] = single
            parameter_double[parameter_depth] = double
            parameter_braces[parameter_depth] = 1
            single = 0
            double = 0
            i++
            continue
          }
          if (char == "\"" && !single) { double = !double; continue }
          if (char == "\047" && !double) { single = !single; continue }
          if (!single && char == "`") {
            found = 1
            exit
          }
          if (single || double) continue
          if (char == "{") parameter_braces[parameter_depth]++
          if (char == "}") {
            parameter_braces[parameter_depth]--
            if (parameter_braces[parameter_depth] == 0) {
              closing_parameter_frame = parameter_depth
              single = parameter_single[closing_parameter_frame]
              double = parameter_double[closing_parameter_frame]
              parameter_depth = parameter_parent[closing_parameter_frame]
              delete parameter_single[closing_parameter_frame]
              delete parameter_double[closing_parameter_frame]
              delete parameter_braces[closing_parameter_frame]
              delete parameter_parent[closing_parameter_frame]
            }
          }
          continue
        }
        if (!single && char == "$" \
            && substr($0, i + 1, 2) == "((") {
          arithmetic_depth++
          arithmetic_single[arithmetic_depth] = single
          arithmetic_double[arithmetic_depth] = double
          arithmetic_parameter[arithmetic_depth] = parameter_depth
          arithmetic_parens[arithmetic_depth] = 2
          single = 0
          double = 0
          i += 2
          continue
        }
        if (!single && !double && char == "(" \
            && substr($0, i + 1, 1) == "(") {
          arithmetic_depth++
          arithmetic_single[arithmetic_depth] = single
          arithmetic_double[arithmetic_depth] = double
          arithmetic_parameter[arithmetic_depth] = parameter_depth
          arithmetic_parens[arithmetic_depth] = 2
          i++
          continue
        }
        if (!single && char == "$" && substr($0, i + 1, 1) == "[") {
          legacy_arithmetic_depth++
          legacy_arithmetic_single[legacy_arithmetic_depth] = single
          legacy_arithmetic_double[legacy_arithmetic_depth] = double
          legacy_arithmetic_parameter[legacy_arithmetic_depth] = parameter_depth
          legacy_arithmetic_brackets[legacy_arithmetic_depth] = 1
          single = 0
          double = 0
          i++
          continue
        }
        if (!single && char == "$" && substr($0, i + 1, 1) == "{") {
          parameter_frame_counter++
          new_parameter_frame = parameter_frame_counter
          parameter_parent[new_parameter_frame] = parameter_depth
          parameter_depth = new_parameter_frame
          parameter_single[parameter_depth] = single
          parameter_double[parameter_depth] = double
          parameter_braces[parameter_depth] = 1
          single = 0
          double = 0
          i++
          continue
        }
        if (!single && char == "$" && substr($0, i + 1, 1) == "(") {
          command_depth++
          saved_single[command_depth] = single
          saved_double[command_depth] = double
          saved_parameter[command_depth] = parameter_depth
          command_parens[command_depth] = 1
          single = 0
          double = 0
          i++
          continue
        }
        previous = i > 1 ? substr($0, i - 1, 1) : " "
        if (!single && !double && char == "#" \
            && previous ~ /[[:space:];|&()]/) break
        # Legacy backtick substitutions are executable even in double quotes,
        # and their escaping/nesting rules are intentionally outside this
        # small static classifier. Reject the active construct up front; an
        # escaped or single-quoted literal backtick remains ordinary data.
        if (!single && char == "`") {
          found = 1
          exit
        }
        if (char == "\"" && !single) { double = !double; continue }
        if (char == "\047" && !double) { single = !single; continue }
        if (command_depth > 0 && !single && !double && char == "(") {
          command_parens[command_depth]++
          continue
        }
        if (command_depth > 0 && !single && !double && char == ")") {
          command_parens[command_depth]--
          if (command_parens[command_depth] == 0) {
            single = saved_single[command_depth]
            double = saved_double[command_depth]
            parameter_depth = saved_parameter[command_depth]
            delete saved_single[command_depth]
            delete saved_double[command_depth]
            delete saved_parameter[command_depth]
            delete command_parens[command_depth]
            command_depth--
          }
          continue
        }
        if (!single && !double && char == "<" \
            && previous != "<" \
            && substr($0, i + 1, 1) == "<" \
            && substr($0, i + 2, 1) != "<" \
            && !array_assignment_shift($0, i)) {
          found = 1
          exit
        }
      }
    }
    END { exit(found ? 0 : 1) }
  '; then
    return 0
  fi
  if [ "$mode" = "--allow-needs-external-review-delete" ]; then
    allowed_delete='gh api "repos/$REPO/issues/$PR/labels/needs-external-review" -X DELETE -i --silent 2>/dev/null || true' # NO_BARE_GH_WRITE_EXEMPT: inert exact-match classifier data, never executed
    if [[ "$source" == *"$allowed_delete"* ]]; then
      prefix=${source%%"$allowed_delete"*}
      suffix=${source#*"$allowed_delete"}
      # Each clear block owns exactly one label deletion.  Two copies are not
      # the intentional exception, even when both spellings are individually
      # exact.
      [[ "$suffix" != *"$allowed_delete"* ]] || return 0
      source="${prefix}MERGEPATH_ALLOWED_NEEDS_EXTERNAL_REVIEW_DELETE${suffix}"
    fi
  fi

  # Lexer markers must be impossible to forge from the source being graded.
  # Extend one deterministic prefix until it is absent, then derive every
  # marker from it. This keeps later restoration local to bytes the lexer
  # itself introduced instead of rewriting user-authored sentinel text.
  literal_marker_prefix="MERGEPATH_CLASSIFIER_LITERAL_"
  while [[ "$source" == *"$literal_marker_prefix"* ]]; do
    literal_marker_prefix="${literal_marker_prefix}X"
  done
  literal_space="${literal_marker_prefix}SPACE"
  literal_newline="${literal_marker_prefix}NEWLINE"
  literal_semi="${literal_marker_prefix}SEMI"
  literal_amp="${literal_marker_prefix}AMP"
  literal_pipe="${literal_marker_prefix}PIPE"
  literal_lparen="${literal_marker_prefix}LPAREN"
  literal_rparen="${literal_marker_prefix}RPAREN"
  literal_lbrace="${literal_marker_prefix}LBRACE"
  literal_rbrace="${literal_marker_prefix}RBRACE"

  # Backslash continuations were removed above. Preserve every remaining
  # physical newline as a command boundary before erasing shell quotes around
  # tokens; otherwise a later `rm -f` can be misattributed to an earlier
  # read-only `gh api` call. Protect dollars/backticks inside single-quoted
  # literals first: GraphQL variable syntax such as `$owner` is inert shell
  # text there, while the same characters outside single quotes stay dynamic
  # and make direct `gh` argument classification fail closed.
  protected_source=$(printf '%s\n' "$source" \
    | awk -v literal_prefix="$literal_marker_prefix" '
    BEGIN {
      single = 0
      double = 0
      escaped = 0
      command_depth = 0
      backtick_depth = 0
      backtick_saved_double = 0
    }
    {
      output = ""
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (escaped) {
          if (char == "$") char = literal_prefix "DOLLAR"
          if (char == "`") char = literal_prefix "BACKTICK"
          if (char == " " || char == "\t") {
            char = literal_prefix "SPACE"
          }
          output = output char
          escaped = 0
          continue
        }
        if (char == "\\" && !single) {
          next_char = substr($0, i + 1, 1)
          if (!double || next_char == "$" || next_char == "`" \
              || next_char == "\"" || next_char == "\\") {
            escaped = 1
          } else {
            output = output char
          }
          continue
        }
        # Backticks execute even inside double quotes. Their command body must
        # be lexed in command context instead of inheriting the outer quoted
        # word, or its spaces become protected and hide a literal mutation.
        if (!single && char == "`") {
          output = output char
          if (backtick_depth == 0) {
            backtick_depth = 1
            backtick_saved_double = double
            double = 0
          } else {
            backtick_depth = 0
            double = backtick_saved_double
          }
          continue
        }
        if (!single && char == "$" && substr($0, i + 1, 1) == "(") {
          output = output "$("
          command_depth++
          saved_single[command_depth] = single
          saved_double[command_depth] = double
          command_parens[command_depth] = 1
          single = 0
          double = 0
          escaped = 0
          i++
          continue
        }
        previous = i > 1 ? substr($0, i - 1, 1) : " "
        if (!single && !double && char == "#" \
            && previous ~ /[[:space:];|&()]/) {
          break
        }
        if (char == "\"" && !single) {
          double = !double
          output = output char
          continue
        }
        if (char == "\047" && !double) {
          single = !single
          output = output char
          continue
        }
        if (command_depth > 0 && !single && !double && char == "(") {
          command_parens[command_depth]++
          output = output char
          continue
        }
        if (command_depth > 0 && !single && !double && char == ")") {
          command_parens[command_depth]--
          output = output char
          if (command_parens[command_depth] == 0) {
            single = saved_single[command_depth]
            double = saved_double[command_depth]
            delete saved_single[command_depth]
            delete saved_double[command_depth]
            delete command_parens[command_depth]
            command_depth--
          }
          continue
        }
        if ((single || double) && (char == " " || char == "\t")) {
          char = literal_prefix "SPACE"
        }
        if ((single || double) && char == ";") char = literal_prefix "SEMI"
        if ((single || double) && char == "&") char = literal_prefix "AMP"
        if ((single || double) && char == "|") char = literal_prefix "PIPE"
        if ((single || double) && char == "(") char = literal_prefix "LPAREN"
        if ((single || double) && char == ")") char = literal_prefix "RPAREN"
        if ((single || double) && char == "{") char = literal_prefix "LBRACE"
        if ((single || double) && char == "}") char = literal_prefix "RBRACE"
        if (single && char == "$") char = literal_prefix "DOLLAR"
        if (single && char == "`") char = literal_prefix "BACKTICK"
        output = output char
      }
      # A physical newline inside an open quoted word is data, not a command
      # separator. Mark it before the record newline is normalized below.
      if (single || double) output = output literal_prefix "NEWLINE"
      print output
    }
  ') || return 2
  # Bash ANSI-C and locale quote prefixes can synthesize any portion of an
  # executable, command group, verb, or option after lexical concatenation.
  # Treat either construct as opaque instead of attempting to interpret its
  # locale- or escape-dependent payload.
  if [[ "$protected_source" == *"\$'"* || "$protected_source" == *'$"'* ]]; then
    return 0
  fi
  # Preserve quoted-token interiors for the conservative textual scan. Quoted
  # or escaped separators belong to their surrounding argument; restoring them
  # after erasing quotes would turn `echo "gh pr merge 7"` into an executable
  # command or let quoted punctuation manufacture a shell boundary. This is
  # deliberately not a full command-position parser: an unquoted literal `gh`
  # in another command's argument position and standalone empty quoted words
  # may still fail closed. A content-only view restores markers only after one
  # real direct `gh api graphql` segment has been selected below.
  dynamic_scan=$(printf '%s\n' "$protected_source" \
    | tr '\n' ';' | tr -d "\"'") || return 2
  # Active legacy backticks were rejected by the pre-lexer. Keep this
  # defensive normalization so an unexpected raw delimiter cannot join words.
  normalized=${dynamic_scan//\`/;}
  literal_newline_boundary="${literal_newline};"
  normalized=${normalized//"$literal_newline_boundary"/"$literal_newline"}
  gh_command_start_re='(^|[;&|()[:space:]])([^;&|()[:space:]]*/)?gh([[:space:]]+(-R([^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)|--repo(=[^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)|--hostname(=[^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)))*'
  api_command_start_re="$gh_command_start_re"'[[:space:]]+api'
  method_flag_re='(-X([^;&|()[:space:]]*)|--method(=[^;&|()[:space:]]*)?)([;&|()[:space:]]|$)'
  # An opaque command group, PR verb, or standalone API argument can expand
  # into mutation syntax that no literal source scan can grade. Embedded
  # values such as repos/$REPO/... remain inspectable, as do dollars protected
  # above inside a single-quoted GraphQL document.
  if printf '%s\n' "$dynamic_scan" | grep -Eiq \
      "$gh_command_start_re"'[[:space:]]+[^;&|()[:space:]]*[\$`][^;&|()[:space:]]*' \
    || printf '%s\n' "$dynamic_scan" | grep -Eiq \
      "$gh_command_start_re"'[[:space:]]+pr([[:space:]]+(-R([^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)|--repo(=[^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)))*[[:space:]]+[^;&|()[:space:]]*[\$`][^;&|()[:space:]]*' \
    || printf '%s\n' "$dynamic_scan" | grep -Eiq \
      "$api_command_start_re"'[[:space:]]+([^;&|]*[[:space:]])?[^;&|()[:space:]/=<>]*[\$`]'; then
    return 0
  fi

  # Any `gh alias` action can turn a later opaque command name into `pr merge`
  # (including a dynamic action token) without leaving a literal native merge
  # at the call site. Guarded source has no legitimate alias operation.
  if printf '%s\n' "$normalized" | grep -Eiq \
    "$gh_command_start_re"'[[:space:]]+alias([;&|()[:space:]]|$)'; then
    return 0
  fi

  # Native command, including a path-qualified/prefixed gh and the common gh
  # repository/hostname options before either `pr` or `merge`.
  if printf '%s\n' "$normalized" | grep -Eiq \
    '(^|[;&|()[:space:]])([^;&|()[:space:]]*/)?gh([[:space:]]+(-R([^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)|--repo(=[^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)|--hostname(=[^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)))*[[:space:]]+pr([[:space:]]+(-R([^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)|--repo(=[^;&|()[:space:]]+|[[:space:]]+[^;&|()[:space:]]+)))*[[:space:]]+merge([;&|()[:space:]]|$)'; then
    return 0
  fi

  # No API command means the remaining method/operation words are inert text.
  if ! printf '%s\n' "$normalized" | grep -Eiq \
    "$api_command_start_re"'([;&|()[:space:]]|$)'; then
    return 1
  fi

  # gh/pflag accepts clustered short options. A mutation-relevant X/f/F
  # hidden behind another short flag (for example `-iXPUT` or `-iFkey=value`)
  # is ambiguous to the token-oriented checks below, so reject the cluster.
  if printf '%s\n' "$normalized" | grep -Eiq \
    "$api_command_start_re"'[^;&|]*[[:space:]]+-[^-;&|()[:space:]][^;&|()[:space:]]*[XfF][^;&|()[:space:]]*([;&|()[:space:]]|$)'; then
    return 0
  fi

  api_count=$(printf '%s\n' "$normalized" | grep -Eio \
    "$api_command_start_re"'([;&|()[:space:]]|$)' \
    | wc -l | tr -d '[:space:]') || return 2
  case "$api_count" in *[!0-9]*|'') return 2 ;; esac

  # Explicit REST write methods, in compact/spaced/equal and either argument
  # order, are prohibited.  The exact permitted label DELETE was removed
  # above before this test, so a different endpoint or a second write remains.
  if printf '%s\n' "$normalized" | grep -Eiq \
    "$api_command_start_re"'[[:space:]]+([^;&|]*[[:space:]])?(-X[[:space:]]*|--method[[:space:]]*(=[[:space:]]*)?)(POST|PATCH|PUT|DELETE)([;&|()[:space:]]|$)'; then
    return 0
  fi

  # A method flag whose operand is not one visible GET literal is not proof of
  # a read.  Grade each shell command segment separately: a later read-only
  # API call must not launder an opaque or unknown method in an earlier one.
  # Multiple method flags in one command are ambiguous and fail closed too.
  while IFS= read -r api_segment; do
    printf '%s\n' "$api_segment" | grep -Eiq \
      "$api_command_start_re"'([()[:space:]]|$)' || continue
    method_count=$(printf '%s\n' "$api_segment" \
      | { grep -Eio "$method_flag_re" || true; } \
      | wc -l | tr -d '[:space:]') || return 2
    case "$method_count" in *[!0-9]*|'') return 2 ;; esac
    [ "$method_count" -gt 0 ] || continue
    get_count=$(printf '%s\n' "$api_segment" \
      | { grep -Eio \
        '(-X[[:space:]]*|--method[[:space:]]*(=[[:space:]]*)?)GET([()[:space:]]|$)' \
          || true; } \
      | wc -l | tr -d '[:space:]') || return 2
    case "$get_count" in *[!0-9]*|'') return 2 ;; esac
    if [ "$method_count" -ne 1 ] || [ "$get_count" -ne 1 ]; then
      return 0
    fi
  done < <(printf '%s\n' "$normalized" | tr ';&|' '\n')

  # GraphQL reads remain valid only when their literal `query` operation is
  # visible in this single direct API command. An opaque variable/file/input
  # is outside that literal contract, while a mutation keyword or known PR
  # merge/queue operation is affirmatively prohibited.
  if printf '%s\n' "$normalized" | grep -Eiq \
      "$api_command_start_re"'[[:space:]]+graphql([;&|()[:space:]]|$)'; then
    [ "$api_count" -eq 1 ] || return 0
    graphql_segment=""
    while IFS= read -r api_segment; do
      printf '%s\n' "$api_segment" | grep -Eiq \
        "$api_command_start_re"'[[:space:]]+graphql([[:space:]]|$)' \
        || continue
      [ -z "$graphql_segment" ] || return 0
      graphql_segment=$api_segment
    done < <(printf '%s\n' "$normalized" | tr ';&|()' '\n')
    [ -n "$graphql_segment" ] || return 0
    content_scan=${graphql_segment//"$literal_space"/ }
    content_scan=${content_scan//"$literal_newline"/ }
    content_scan=${content_scan//"$literal_semi"/;}
    content_scan=${content_scan//"$literal_amp"/&}
    content_scan=${content_scan//"$literal_pipe"/|}
    content_scan=${content_scan//"$literal_lparen"/(}
    content_scan=${content_scan//"$literal_rparen"/)}
    content_scan=${content_scan//"$literal_lbrace"/\{}
    content_scan=${content_scan//"$literal_rbrace"/\}}
    if printf '%s\n' "$content_scan" | grep -Eiq \
        '(^|[^[:alnum:]_])(mutation|addPullRequestToMergeQueue|enqueuePullRequest|dequeuePullRequest|enablePullRequestAutoMerge|disablePullRequestAutoMerge|mergePullRequest)([^[:alnum:]_]|$)' \
      || printf '%s\n' "$content_scan" | grep -Eiq \
        'query[[:space:]]*=[[:space:]]*([$@-]|\$\{|\$\()|(^|[;&|()[:space:]])--input([=;&|()[:space:]]|$)' \
      || printf '%s\n' "$graphql_segment" | grep -Eq \
        "$api_command_start_re"'[[:space:]][^;&|]*[\$`]' \
      ; then
      return 0
    fi
    if printf '%s\n' "$content_scan" | grep -Eiq \
      'query[[:space:]]*=[[:space:]]*query([[:space:]]+[[:alpha:]_][[:alnum:]_]*)?[[:space:]]*(\([^)]*\)[[:space:]]*)?\{'; then
      return 1
    fi
    return 0
  fi

  # gh api changes its default method from GET to POST as soon as a field or
  # input flag is supplied.  Permit that syntax only when this sole API call
  # explicitly pins GET; otherwise it is an implicit write even without -X.
  if printf '%s\n' "$normalized" | grep -Eiq \
      "$api_command_start_re"'[[:space:]]+([^;&|]*[[:space:]])?((-f|-F)([^;&|()[:space:]]*|[[:space:]]+[^;&|()[:space:]]+)|--field([=;&|()[:space:]]|$)|--raw-field([=;&|()[:space:]]|$)|--input([=;&|()[:space:]]|$))'; then
    if [ "$api_count" -eq 1 ] \
      && printf '%s\n' "$normalized" | grep -Eiq \
        "$api_command_start_re"'[[:space:]]+([^;&|]*[[:space:]])?(-X[[:space:]]*|--method[[:space:]]*(=[[:space:]]*)?)GET([;&|()[:space:]]|$)'; then
      return 1
    fi
    return 0
  fi

  return 1
}

# Return success only when the direct-literal scan is clean. Prohibited syntax
# (rc 0) and classifier/usage failure (rc 2) both fail the regression check;
# this adapter prevents a negated tri-state predicate from failing open.
gh_source_lacks_direct_literal_pr_mutation() {
  local rc
  rc=0
  gh_source_has_direct_literal_pr_mutation "$@" || rc=$?
  [ "$rc" -eq 1 ]
}
