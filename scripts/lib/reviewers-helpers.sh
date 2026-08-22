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
