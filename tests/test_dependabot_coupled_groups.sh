#!/usr/bin/env bash
# tests/test_dependabot_coupled_groups.sh
#
# Fixture suite for scripts/ci/dependabot_coupled_groups.py, the logic
# behind scripts/ci/check_dependabot_coupled_groups (#2162). Each case
# builds a throwaway repository root holding .github/dependabot.yml plus
# the package.json files its npm entries point at, runs the checker with
# --root, and asserts the exit code and the family it names.
#
#   1. firebase (prod) + @firebase/rules-unit-testing (dev), type groups  → FAIL
#   2. firebase-sdk family group listed first                             → PASS
#   3. family group listed AFTER the type groups                          → FAIL
#   4. family group restricted by dependency-type                         → FAIL
#   5. family group restricted to minor/patch (majors fall through)       → FAIL
#   6. only one member present (firebase alone)                           → PASS
#   7. no family members at all                                           → PASS
#   8. both members' majors ignored, minors still split                   → FAIL
#   9. one member ignored outright (no update-types)                      → PASS
#  10. versions-scoped ignore does not count as ignoring the update type  → FAIL
#  11. entry with no groups: members ungrouped (one PR each)              → FAIL
#  12. second npm entry (/functions) splits firebase-server               → FAIL, names /functions
#  13. --fix inserts the group first, keeps comments, then PASS; idempotent
#  14. --fix on an entry with no groups key adds one                      → PASS
#  15. `directories:` glob expands to each package directory              → FAIL for the split one
#  16. no .github/dependabot.yml                                          → PASS (not applicable)
#  17. unparseable YAML                                                   → exit 2
#  18. non-npm ecosystems are ignored                                     → PASS
#  19. both members dev dependencies in one type group (no family group)  → PASS (false-positive guard)
#  20. existing group named after the family but ordered late             → FAIL, no --fix insertion
#  21. peerDependencies-only member (Dependabot never updates peers)      → PASS
#  22. allow: production only drops the dev member                       → PASS
#  23. allow by name keeps both members eligible                         → FAIL
#  24. flow-style groups: --fix fails closed, file untouched             → exit 2
#  25. members declared only inside an npm workspace                     → FAIL
#  26. group-by: dependency-name is one PR per member                    → FAIL
#  27. multi-ecosystem-group with patterns ["*"] is one shared PR        → PASS
#  28. only * is a wildcard (firebas? is literal)                        → FAIL
#  29. pnpm-workspace.yaml packages are evaluated                        → FAIL
#  30. one effective dependency type per package (production wins)      → PASS
#  31. exclude-paths drops an excluded workspace manifest                → PASS
#  32. open-pull-requests-limit: 0 skips the entry                       → PASS
#
# Needs python3 with PyYAML. repo_lint provisions PyYAML for every
# self-test leg; a bare local shell without it SKIPs loudly (and CI fails).
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/ci/dependabot_coupled_groups.py"

[ -f "$CHECKER" ] || { echo "missing $CHECKER" >&2; exit 1; }

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then
    echo "FAIL: PyYAML is not importable under CI; repo_lint's install_python_ci_dependencies step should provide it" >&2
    exit 1
  fi
  echo "SKIP: PyYAML not importable — install it to run tests/test_dependabot_coupled_groups.sh locally" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dependabot-coupled-groups-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
N=0

# new_repo NAME — create an empty fixture root and print its path.
new_repo() {
  local d="$WORKDIR/$1"
  mkdir -p "$d/.github"
  printf '%s\n' "$d"
}

# pkg DIR PROD_DEPS DEV_DEPS — write DIR/package.json; deps are space-separated names.
pkg() {
  local dir="$1" prod="$2" dev="$3"
  mkdir -p "$dir"
  python3 - "$dir/package.json" "$prod" "$dev" <<'PY'
import json, sys
path, prod, dev = sys.argv[1:4]
data = {"name": "fixture", "version": "0.0.0"}
if prod.split():
    data["dependencies"] = {n: "^1.0.0" for n in prod.split()}
if dev.split():
    data["devDependencies"] = {n: "^1.0.0" for n in dev.split()}
json.dump(data, open(path, "w"), indent=2)
PY
}

FB_PROD="firebase react"
FB_DEV="@firebase/rules-unit-testing vitest"

TYPE_GROUPS='      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"'

FAMILY_GROUP='      firebase-sdk:
        patterns:
          - "firebase"
          - "@firebase/*"'

# write_config REPO GROUPS_BLOCK [EXTRA_ENTRY_KEYS]
write_config() {
  local repo="$1" groups="$2" extra="${3:-}"
  {
    printf 'version: 2\nupdates:\n'
    printf '  - package-ecosystem: "github-actions"\n    directory: "/"\n    schedule:\n      interval: "weekly"\n\n'
    printf '  - package-ecosystem: "npm"\n    directory: "/"\n    schedule:\n      interval: "weekly"\n'
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    if [ -n "$groups" ]; then printf '    groups:\n%s\n' "$groups"; fi
    printf '    commit-message:\n      prefix: "deps"\n'
  } > "$repo/.github/dependabot.yml"
}

# expect NAME WANT_RC REPO [GREP] [extra checker args...]
expect() {
  local name="$1" want="$2" repo="$3" needle="${4:-}"
  shift 4 || shift $#
  local out rc=0
  N=$((N + 1))
  out="$(python3 "$CHECKER" --root "$repo" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL [$N] $name: exit $rc, want $want" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    return 0
  fi
  if [ -n "$needle" ] && ! grep -Fq -- "$needle" <<<"$out"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL [$N] $name: output lacks '$needle'" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    return 0
  fi
  PASS=$((PASS + 1))
  echo "  PASS [$N] $name"
}

echo "dependabot coupled-family group tests"

r="$(new_repo split)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS"
expect "dev/prod split is reported" 1 "$r" "family 'firebase-sdk' is split for major updates"

r="$(new_repo family-first)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$FAMILY_GROUP
$TYPE_GROUPS"
expect "family group first passes" 0 "$r" "PASS"

r="$(new_repo family-last)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS
$FAMILY_GROUP"
expect "family group after type groups fails" 1 "$r" "exists but does not capture every member first"

r="$(new_repo family-dep-type)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" '      firebase-sdk:
        dependency-type: "production"
        patterns:
          - "firebase"
          - "@firebase/*"'"
$TYPE_GROUPS"
expect "dependency-type-restricted family group fails" 1 "$r" "firebase-sdk"

r="$(new_repo family-minor-only)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" '      firebase-sdk:
        update-types: ["minor", "patch"]
        patterns:
          - "firebase"
          - "@firebase/*"'"
$TYPE_GROUPS"
expect "minor/patch-only family group fails on majors" 1 "$r" "split for major updates"

r="$(new_repo one-member)"; pkg "$r" "firebase react" "vitest"; write_config "$r" "$TYPE_GROUPS"
expect "single present member is a no-op" 0 "$r" "PASS"

r="$(new_repo no-members)"; pkg "$r" "react" "vitest"; write_config "$r" "$TYPE_GROUPS"
expect "absent family is a no-op" 0 "$r" "PASS"

r="$(new_repo majors-ignored)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    ignore:
      - dependency-name: "firebase"
        update-types: ["version-update:semver-major"]
      - dependency-name: "@firebase/rules-unit-testing"
        update-types: ["version-update:semver-major"]'
expect "majors ignored, minors still split" 1 "$r" "split for minor updates"

r="$(new_repo member-ignored)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    ignore:
      - dependency-name: "@firebase/rules-unit-testing"'
expect "fully ignored member leaves one active member" 0 "$r" "PASS"

r="$(new_repo versions-ignore)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    ignore:
      - dependency-name: "@firebase/rules-unit-testing"
        versions: [">=7"]'
expect "versions-scoped ignore keeps the member active" 1 "$r" "firebase-sdk"

r="$(new_repo no-groups)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" ""
expect "ungrouped members open one PR each" 1 "$r" "(ungrouped: its own PR)"

r="$(new_repo functions-dir)"; pkg "$r" "react" "vitest"
pkg "$r/functions" "firebase-admin firebase-functions" "firebase-functions-test"
write_config "$r" "$TYPE_GROUPS"
cat >> "$r/.github/dependabot.yml" <<'YAML'

  - package-ecosystem: "npm"
    directory: "/functions"
    schedule:
      interval: "weekly"
    groups:
      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"
YAML
expect "second npm entry is checked on its own directory" 1 "$r" 'directory "/functions": family '"'"'firebase-server'"'"

r="$(new_repo fix)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "      # keep this comment
$TYPE_GROUPS" '    # ignore comment survives too
    ignore:
      - dependency-name: "eslint"
        update-types: ["version-update:semver-major"]'
expect "--fix inserts the group and passes" 0 "$r" "inserted 1 family group" --fix
N=$((N + 1))
if grep -q "# keep this comment" "$r/.github/dependabot.yml" \
   && grep -q "# ignore comment survives too" "$r/.github/dependabot.yml" \
   && python3 - "$r/.github/dependabot.yml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
npm = [u for u in cfg["updates"] if u["package-ecosystem"] == "npm"][0]
assert list(npm["groups"])[0] == "firebase-sdk", list(npm["groups"])
assert npm["groups"]["firebase-sdk"] == {"patterns": ["firebase", "@firebase/*"]}
assert npm["ignore"][0]["dependency-name"] == "eslint"
PY
then PASS=$((PASS + 1)); echo "  PASS [$N] --fix keeps comments and puts the family first"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] --fix layout" >&2; sed 's/^/      /' "$r/.github/dependabot.yml" >&2; fi
cp "$r/.github/dependabot.yml" "$WORKDIR/fix-after-first.yml"
expect "--fix is idempotent" 0 "$r" "PASS" --fix
N=$((N + 1))
if cmp -s "$r/.github/dependabot.yml" "$WORKDIR/fix-after-first.yml"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] second --fix leaves the file byte-identical"
else
  FAIL=$((FAIL + 1)); echo "  FAIL [$N] second --fix changed the file" >&2
fi

r="$(new_repo fix-no-groups)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" ""
expect "--fix adds a groups key when the entry has none" 0 "$r" "PASS" --fix

r="$(new_repo directories-glob)"
pkg "$r/apps/web" "$FB_PROD" "$FB_DEV"
pkg "$r/apps/admin" "react" "vitest"
cat > "$r/.github/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directories:
      - "/apps/*"
    schedule:
      interval: "weekly"
    groups:
      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"
YAML
expect "directories glob checks each package" 1 "$r" 'directory "/apps/web"'

r="$WORKDIR/no-config"; mkdir -p "$r"
expect "no dependabot.yml is not applicable" 0 "$r" "not applicable"

r="$(new_repo bad-yaml)"; printf 'updates: [\n' > "$r/.github/dependabot.yml"
expect "unparseable YAML is an environment error" 2 "$r" "YAML parse error"

r="$(new_repo actions-only)"; pkg "$r" "$FB_PROD" "$FB_DEV"
printf 'version: 2\nupdates:\n  - package-ecosystem: "github-actions"\n    directory: "/"\n    schedule:\n      interval: "weekly"\n' > "$r/.github/dependabot.yml"
expect "non-npm ecosystems are ignored" 0 "$r" "PASS"

r="$(new_repo same-type-group)"; pkg "$r" "react" "eslint @eslint/js vitest"; write_config "$r" "$TYPE_GROUPS"
expect "members already sharing one type group pass with no family group" 0 "$r" "PASS"

# Review round 1 on #2170 — one case per finding.

r="$(new_repo peer-only)"
printf '{"name":"lib","peerDependencies":{"vite":"^8.0.0"},"devDependencies":{"vitest":"^5.0.0"},"dependencies":{"react":"^19.0.0"}}\n' > "$r/package.json"
write_config "$r" '      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"'
expect "peerDependencies-only member is not updatable (dependabot-core DEPENDENCY_TYPES)" 0 "$r" "PASS"

r="$(new_repo allow-production)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    allow:
      - dependency-type: "production"'
expect "allow filters drop the dev member before grouping" 0 "$r" "PASS"

r="$(new_repo allow-by-name)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    allow:
      - dependency-name: "firebase"
      - dependency-name: "@firebase/*"'
expect "allow rules naming both members keep the split visible" 1 "$r" "firebase-sdk"

r="$(new_repo flow-groups)"; pkg "$r" "$FB_PROD" "$FB_DEV"
cat > "$r/.github/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    groups: { dev-dependencies: { dependency-type: development }, production-dependencies: { dependency-type: production } }
YAML
cp "$r/.github/dependabot.yml" "$WORKDIR/flow-groups.yml"
expect "--fix fails closed on a flow-style groups mapping" 2 "$r" "flow-style 'groups:' mapping" --fix
N=$((N + 1))
if cmp -s "$r/.github/dependabot.yml" "$WORKDIR/flow-groups.yml"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] flow-style config left byte-identical"
else
  FAIL=$((FAIL + 1)); echo "  FAIL [$N] --fix edited a flow-style config" >&2
fi

r="$(new_repo workspaces)"
printf '{"name":"root","private":true,"workspaces":["packages/*"],"devDependencies":{"vitest":"^5.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "members declared only in a workspace manifest are evaluated" 1 "$r" "firebase-sdk"

r="$(new_repo group-by-name)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" '      per-dependency:
        group-by: dependency-name
        patterns:
          - "*"'
expect "group-by: dependency-name opens one PR per member" 1 "$r" "per-dependency[firebase]"

r="$(new_repo multi-ecosystem)"; pkg "$r" "$FB_PROD" "$FB_DEV"
cat > "$r/.github/dependabot.yml" <<'YAML'
version: 2
multi-ecosystem-groups:
  infrastructure:
    schedule:
      interval: "weekly"
updates:
  - package-ecosystem: "npm"
    directory: "/"
    patterns: ["*"]
    multi-ecosystem-group: "infrastructure"
YAML
expect "a multi-ecosystem group is one shared PR target" 0 "$r" "PASS"

r="$(new_repo literal-question-mark)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" '      firebase-sdk:
        patterns:
          - "firebas?"
          - "@firebase/*"'"
$TYPE_GROUPS"
expect "only * is a wildcard: firebas? does not match firebase" 1 "$r" "family 'firebase-sdk' is split"

# Review round 2 on #2170.

r="$(new_repo pnpm-workspace)"
printf '{"name":"root","private":true,"devDependencies":{"vitest":"^5.0.0"}}\n' > "$r/package.json"
printf 'packages:\n  - "apps/*"\n' > "$r/pnpm-workspace.yaml"
pkg "$r/apps/web" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "pnpm-workspace.yaml members are evaluated (root declares none)" 1 "$r" "firebase-sdk"

r="$(new_repo mixed-type)"
printf '{"name":"root","private":true,"workspaces":["packages/*"]}\n' > "$r/package.json"
pkg "$r/packages/app" "firebase @firebase/rules-unit-testing" ""
pkg "$r/packages/tests" "" "@firebase/rules-unit-testing vitest"
write_config "$r" "$TYPE_GROUPS"
expect "a package declared as production anywhere is production (one type per package)" 0 "$r" "PASS"

r="$(new_repo exclude-paths)"
printf '{"name":"root","private":true,"workspaces":["packages/*"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/fixture" "" "@firebase/rules-unit-testing"
write_config "$r" "$TYPE_GROUPS" '    exclude-paths:
      - "packages/fixture"'
expect "exclude-paths drops an excluded workspace manifest" 0 "$r" "PASS"

r="$(new_repo prs-disabled)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    open-pull-requests-limit: 0'
expect "open-pull-requests-limit: 0 disables the entry" 0 "$r" "version updates disabled"

r="$(new_repo named-late)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS
$FAMILY_GROUP"
cp "$r/.github/dependabot.yml" "$WORKDIR/named-late.yml"
expect "--fix refuses to duplicate a misplaced family group" 1 "$r" "exists but does not capture every member first" --fix
N=$((N + 1))
if cmp -s "$r/.github/dependabot.yml" "$WORKDIR/named-late.yml"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] misplaced named group left for a human"
else
  FAIL=$((FAIL + 1)); echo "  FAIL [$N] --fix edited a config it should leave alone" >&2
fi

echo "dependabot coupled-family group tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
