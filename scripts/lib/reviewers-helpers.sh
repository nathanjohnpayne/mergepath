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
read_available_reviewers() {
  local cfg="${1:-${CONFIG:-.github/review-policy.yml}}"
  [ -f "$cfg" ] || return 0
  awk '
    /^available_reviewers:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && /^ *-/ {print}
  ' "$cfg" | sed -E "s/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*\$//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//; s/[[:space:]]+\$//"
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
