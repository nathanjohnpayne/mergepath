# scripts/lib/reviewers-helpers.sh
#
# Shared reader for the `available_reviewers` allow-list in
# .github/review-policy.yml. Extracted in #453 so every helper that
# consults the allow-list parses it IDENTICALLY. Before this, three
# scripts carried three different readers: coderabbit-wait.sh had the
# strongest normalization (dash + inline comment + BOTH quote styles +
# whitespace, hardened across #438 r8/r10), codex-review-check.sh had a
# weaker double-quote-only reader, and audit-propagation-lane.sh had
# none. A weaker reader silently drops a quoted/commented-but-valid
# reviewer from the allow-list, which would make coderabbit-wait.sh's
# token-login derivation (login_is_available_reviewer at write time)
# fail OPEN — exactly the fail-closed constraint #438 r-series locked in.
# One shared, strongest-form reader keeps all consumers in lockstep.
#
# Sourcing contract: NO top-level side effects, only function defs.
# Bash 3.2 portable (no mapfile, no associative arrays).
#
#   source scripts/lib/reviewers-helpers.sh
#   read_available_reviewers [config_path]            # one login per line
#   login_is_available_reviewer <login> [config_path] # 0 if listed, else 1
#   validate_thread_resolution_ci_app_identity [config_path]
#                                  # the CI app login (#2726): 0 valid, 1 unset, 2 invalid
#
# config_path defaults to $CONFIG (the global the helper scripts set) and
# then to .github/review-policy.yml, so existing call sites that pass no
# argument keep working unchanged.

# Emit one normalized reviewer login per line. Normalization order:
# strip the list dash + leading space, then a trailing inline comment,
# then trailing whitespace, then a leading and trailing quote (single OR
# double), then any remaining trailing whitespace. Trimming trailing
# whitespace BEFORE the closing-quote strip is load-bearing: a quoted item
# with padding but no comment (e.g. `- "name"   `) would otherwise keep its
# closing quote because `["']$` can't match before the trailing spaces, and
# the stray quote would drop a valid reviewer from the fail-closed allow-list
# (Codex P2 on #463). The second trailing-whitespace strip covers a space
# inside the quotes (`- "name "`).
read_policy_list() {  # <key> [config_path]
  local key=$1
  local cfg="${2:-${CONFIG:-.github/review-policy.yml}}"
  [ -n "$key" ] || return 0
  [ -f "$cfg" ] || return 0
  # `index($0, key ":") == 1` is a LITERAL anchored-prefix test, deliberately
  # not the `/^key:/` regex the single-key version used: generalizing over a
  # caller-supplied key would otherwise let a regex metacharacter in that key
  # change what the block matcher means.
  awk -v key="$key" '
    index($0, key ":") == 1 {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && /^ *-/ {print}
  ' "$cfg" | sed -E "s/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*\$//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//; s/[[:space:]]+\$//"
}

read_available_reviewers() {
  read_policy_list available_reviewers "$@"
}

# True when <key> is present and carries an INLINE value that
# read_policy_list cannot consume -- a YAML flow list
# (`key: [a, b]`) or a bare scalar (`key: name`). The block reader only
# collects following dash-prefixed lines, so both forms parse to NOTHING and
# are indistinguishable from an absent key. For a deny-list that difference is
# a silent fail-OPEN: the repo looks like it declared its service account and
# receives no protection at all. Callers use this to fail closed instead.
policy_list_has_unconsumed_inline_value() {  # <key> [config_path]
  local key=$1
  local cfg="${2:-${CONFIG:-.github/review-policy.yml}}"
  [ -n "$key" ] || return 1
  [ -f "$cfg" ] || return 1
  awk -v key="$key" '
    index($0, key ":") == 1 {
      rest = substr($0, length(key) + 2)
      sub(/[[:space:]]*#.*$/, "", rest)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
      # An EMPTY flow list is the documented inert configuration, not an
      # unsupported value: `key: []` says "no such identity here" as clearly
      # as omitting the key. Treating it as unparseable would exit 2 on every
      # PR in a repo that wrote the legitimate empty form (Codex #1080).
      if (rest != "" && rest !~ /^\[[[:space:]]*\]$/) { found = 1 }
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$cfg"
}

# Identities that must NEVER carry reviewer standing — CI service accounts.
# Absent or empty is a legitimate configuration and means "no such identity
# on this repo"; callers treat that as an inert check, not as an error, so a
# repo that has not adopted the key is unaffected rather than broken.
read_non_reviewer_identities() {
  read_policy_list non_reviewer_identities "$@"
}

# Identities that may approve a Dependabot PR and nothing else (#2874): the
# account behind DEPENDABOT_REVIEWER_TOKEN. They are deliberately NOT in
# available_reviewers, so every other approval check ignores them, and a
# leaked copy of that token cannot clear an agent or human PR. Absent or
# empty is inert: the Dependabot lane then accepts available_reviewers only.
read_dependabot_reviewer_identities() {
  read_policy_list dependabot_reviewer_identities "$@"
}

# The approver set for the Dependabot lane only: available_reviewers plus
# dependabot_reviewer_identities, one login per line, de-duplicated.
read_dependabot_approvers() {
  { read_available_reviewers "$@"; read_dependabot_reviewer_identities "$@"; } \
    | sed '/^$/d' | awk '!seen[$0]++'
}

# Return 0 iff <login> is a non-empty, exact member of the allow-list.
# Fail-closed: an empty login or an unreadable config returns 1.
login_is_available_reviewer() {
  local login=$1 cfg="${2:-${CONFIG:-.github/review-policy.yml}}" reviewer
  [ -n "$login" ] || return 1
  while IFS= read -r reviewer; do
    [ "$reviewer" = "$login" ] && return 0
  done <<< "$(read_available_reviewers "$cfg")"
  return 1
}

# Return 0 iff <login> is a non-empty, exact member of the
# `non_reviewer_identities` deny-list. Fail-OPEN on an empty login, unlike
# login_is_available_reviewer: this answers "is this identity forbidden?", so
# an unknown login must not read as forbidden.
login_is_non_reviewer_identity() {
  local login=$1 cfg="${2:-${CONFIG:-.github/review-policy.yml}}" denied
  [ -n "$login" ] || return 1
  while IFS= read -r denied; do
    [ "$denied" = "$login" ] && return 0
  done <<< "$(read_non_reviewer_identities "$cfg")"
  return 1
}

# --- The CI app thread-resolution identity (#2726) --------------------------
#
# `thread_resolution_ci_app_identity` names the ONE GitHub App bot login that
# may resolve demonstrably-actioned review threads from CI
# (scripts/identity-check.sh --expect-thread-resolution-app, reached only from
# scripts/resolve-pr-threads.sh --resolve-actioned --ci-app-identity). It is a
# top-level scalar, absent by default; absent, empty, `~` and `null` all mean
# "no CI app", and the mode is then inert.

# Print the key's raw scalar value, or nothing when it is absent or one of the
# empty forms. No validation: a reader that only needs "which login could this
# be?" (the clearance gate's deny-list) takes it as written.
read_thread_resolution_ci_app_identity() {  # [config_path]
  local cfg="${1:-${CONFIG:-.github/review-policy.yml}}" value
  [ -f "$cfg" ] || return 0
  value=$(awk 'index($0, "thread_resolution_ci_app_identity:") == 1 {
      sub(/^thread_resolution_ci_app_identity:[[:space:]]*/, ""); print; exit
    }' "$cfg" | sed -E "s/[[:space:]]+#.*\$//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//")
  case "$value" in
    ''|'~'|null) return 0 ;;
  esac
  printf '%s\n' "$value"
}

# Print the configured CI app login when it is configured AND valid.
#   0  configured and valid; the login is on stdout
#   1  not configured; the mode is inert (nothing printed)
#   2  configured but invalid; the reason is on stderr (nothing on stdout)
# Valid means all of:
#   - the exact form of a GitHub App bot login, `<app-slug>[bot]`
#   - not a bot that is shared or that reviews: github-actions[bot] is every
#     workflow run's GITHUB_TOKEN, so it would not name one app, and a review
#     bot must never resolve review threads, its own included
#   - declared in non_reviewer_identities (so the #1080 assertion in
#     scripts/merge-clearance-gate.sh refuses any approval it posts), with that
#     list in a form this reader can parse
#   - never in available_reviewers: it holds no reviewer standing, with that
#     list in a form this reader can parse
validate_thread_resolution_ci_app_identity() {  # [config_path]
  local cfg="${1:-${CONFIG:-.github/review-policy.yml}}" login re
  login=$(read_thread_resolution_ci_app_identity "$cfg")
  [ -n "$login" ] || return 1
  re='^[a-z0-9][a-z0-9-]{0,38}\[bot\]$'
  if ! [[ "$login" =~ $re ]]; then
    echo "thread_resolution_ci_app_identity in $cfg is not a GitHub App bot login of the form <app-slug>[bot]." >&2
    return 2
  fi
  case "$login" in
    'github-actions[bot]'|'dependabot[bot]'|'coderabbitai[bot]'|'chatgpt-codex-connector[bot]'|'github-advanced-security[bot]')
      echo "thread_resolution_ci_app_identity in $cfg is '$login', a shared or reviewing bot; it must name the repository's own CI app." >&2
      return 2
      ;;
  esac
  if [ -z "$(read_non_reviewer_identities "$cfg")" ] \
     && policy_list_has_unconsumed_inline_value non_reviewer_identities "$cfg"; then
    echo "non_reviewer_identities in $cfg carries an inline value this reader cannot parse, so '$login' cannot be shown to be declared a non-reviewer." >&2
    return 2
  fi
  if ! login_is_non_reviewer_identity "$login" "$cfg"; then
    echo "thread_resolution_ci_app_identity '$login' is not declared in non_reviewer_identities in $cfg; declare it there so it can never count as an approval." >&2
    return 2
  fi
  # The same guard for available_reviewers: a flow list (`[a, b]`) reads as
  # EMPTY here, so the membership test below would pass the app while the
  # workflows' YAML readers (pr-audit.yml, agent-review.yml) parse the list in
  # full and give the app reviewer standing. Unparseable here means refused.
  if [ -z "$(read_available_reviewers "$cfg")" ] \
     && policy_list_has_unconsumed_inline_value available_reviewers "$cfg"; then
    echo "available_reviewers in $cfg carries an inline value this reader cannot parse, so '$login' cannot be shown to be absent from it." >&2
    return 2
  fi
  if login_is_available_reviewer "$login" "$cfg"; then
    echo "thread_resolution_ci_app_identity '$login' is listed in available_reviewers in $cfg; a CI app holds no reviewer standing." >&2
    return 2
  fi
  printf '%s\n' "$login"
}
