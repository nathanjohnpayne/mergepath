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
#  33. one target across SemVer levels (major/non-major family groups)  → FAIL
#  34. allow update-types limit a member's eligible levels               → PASS
#  35. exclude-paths * is single-segment                                 → FAIL
#  36. exclude-paths ** is recursive                                     → PASS
#  37. recursive workspace patterns reach nested manifests               → FAIL
#  38. lerna.json packages are evaluated                                 → FAIL
#  39. target-branch reads that branch's ref; unavailable fails closed; base-ref reads the checkout
#  40. negations as dependabot-core applies them: !(x) ignores the literal x;
#      !(a|b) and !-prefixed patterns exclude nothing
#  41. pnpm catalog / catalogs entries are production dependencies, read
#      from the nearest pnpm-workspace.yaml (entry dir, then its parents)
#  42. directories **/* reaches nested projects
#  43. --fix integrity check fails closed on a malformed re-parse
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
expect "dev/prod split is reported" 1 "$r" "firebase -> production-dependencies [major, minor, patch]"

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
expect "minor/patch-only family group fails on majors" 1 "$r" "firebase -> production-dependencies [major] + firebase-sdk [minor, patch]"

r="$(new_repo one-member)"; pkg "$r" "firebase react" "vitest"; write_config "$r" "$TYPE_GROUPS"
expect "single present member is a no-op" 0 "$r" "PASS"

r="$(new_repo no-members)"; pkg "$r" "react" "vitest"; write_config "$r" "$TYPE_GROUPS"
expect "absent family is a no-op" 0 "$r" "PASS"

r="$(new_repo majors-ignored)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    ignore:
      - dependency-name: "firebase"
        update-types: ["version-update:semver-major"]
      - dependency-name: "@firebase/rules-unit-testing"
        update-types: ["version-update:semver-major"]'
expect "majors ignored, minors still split" 1 "$r" "firebase -> production-dependencies [minor, patch]"

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

# Review round 3 on #2170.

r="$(new_repo cross-level)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" '      firebase-majors:
        update-types: ["major"]
        patterns:
          - "firebase"
          - "@firebase/*"
      firebase-rest:
        update-types: ["minor", "patch"]
        patterns:
          - "firebase"
          - "@firebase/*"'"
$TYPE_GROUPS"
expect "separate family-wide major and non-major groups still split across levels" 1 "$r" "firebase-majors [major] + firebase-rest [minor, patch]"

r="$(new_repo allow-update-types)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    allow:
      - dependency-name: "firebase"
      - dependency-name: "@firebase/rules-unit-testing"
        update-types: ["version-update:semver-patch"]
    ignore:
      - dependency-name: "@firebase/rules-unit-testing"
        update-types: ["version-update:semver-patch"]'
expect "allow update-types limits a member's levels (none left here)" 0 "$r" "PASS"

r="$(new_repo exclude-single-segment)"
printf '{"name":"root","private":true,"workspaces":["packages/**"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/team/nested" "" "@firebase/rules-unit-testing"
write_config "$r" "$TYPE_GROUPS" '    exclude-paths:
      - "packages/*/package.json"'
expect "exclude-paths * is one segment: a nested manifest stays in" 1 "$r" "firebase-sdk"

r="$(new_repo exclude-recursive)"
printf '{"name":"root","private":true,"workspaces":["packages/**"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/team/nested" "" "@firebase/rules-unit-testing"
write_config "$r" "$TYPE_GROUPS" '    exclude-paths:
      - "packages/**"'
expect "exclude-paths ** spans any depth" 0 "$r" "PASS"

r="$(new_repo recursive-workspace)"
printf '{"name":"root","private":true,"workspaces":["packages/**"]}\n' > "$r/package.json"
pkg "$r/packages/team/app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "recursive workspace patterns reach nested manifests" 1 "$r" "firebase-sdk"

r="$(new_repo lerna)"
printf '{"name":"root","private":true,"devDependencies":{"lerna":"^9.0.0"}}\n' > "$r/package.json"
printf '{"packages":["packages/*"]}\n' > "$r/lerna.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "lerna.json packages are evaluated (root declares none)" 1 "$r" "firebase-sdk"

# #2177: remaining Dependabot npm features.

gitc() { git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "${@:2}"; }

# CI exports these; the target-branch cases below control them explicitly.
saved_base_ref="${GITHUB_BASE_REF-}"; saved_ref_name="${GITHUB_REF_NAME-}"
unset GITHUB_BASE_REF GITHUB_REF_NAME

r="$(new_repo target-branch)"; pkg "$r" "react" "vitest"; write_config "$r" "$TYPE_GROUPS" '    target-branch: "develop"'
gitc "$r" init -q -b main && gitc "$r" add -A && gitc "$r" commit -q -m main
gitc "$r" checkout -q -b develop && pkg "$r" "$FB_PROD" "$FB_DEV" && gitc "$r" commit -qam develop && gitc "$r" checkout -q main
expect "target-branch manifests are read from that branch's ref" 1 "$r" "reading manifests from target-branch ref refs/heads/develop"
N=$((N + 1))
tb_out="$(python3 "$CHECKER" --root "$r" 2>&1 || true)"
if grep -q "family 'firebase-sdk'" <<<"$tb_out"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] the split exists only on the target branch and is reported"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] target-branch split not reported" >&2; fi

r="$(new_repo target-branch-missing)"; pkg "$r" "$FB_PROD" "$FB_DEV"; write_config "$r" "$TYPE_GROUPS" '    target-branch: "release"'
gitc "$r" init -q -b main && gitc "$r" add -A && gitc "$r" commit -q -m main
expect "an unavailable target-branch fails closed" 2 "$r" "target-branch 'release' is not available"

r="$(new_repo target-branch-is-base)"; pkg "$r" "react" "vitest"; write_config "$r" "$TYPE_GROUPS" '    target-branch: "release"'
gitc "$r" init -q -b main && gitc "$r" add -A && gitc "$r" commit -q -m main
N=$((N + 1))
tb_out="$(GITHUB_BASE_REF=release python3 "$CHECKER" --root "$r" 2>&1 || true)"
if grep -q "PASS" <<<"$tb_out"; then
  PASS=$((PASS + 1)); echo "  PASS [$N] target-branch equal to the PR base reads the checkout"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] target-branch == GITHUB_BASE_REF should read the checkout" >&2; fi

[ -n "$saved_base_ref" ] && export GITHUB_BASE_REF="$saved_base_ref"
[ -n "$saved_ref_name" ] && export GITHUB_REF_NAME="$saved_ref_name"

r="$(new_repo yarn-extglob)"
printf '{"name":"root","private":true,"workspaces":["packages/!(docs)"]}\n' > "$r/package.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"; pkg "$r/packages/docs" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "Yarn !(docs) still selects packages/app" 1 "$r" 'directory "/": family '"'"'firebase-sdk'"'"

r="$(new_repo yarn-extglob-negated)"
printf '{"name":"root","private":true,"workspaces":["packages/!(docs|site)"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/docs" "" "@firebase/rules-unit-testing"; pkg "$r/packages/site" "" "@firebase/rules-unit-testing"; pkg "$r/packages/app" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "Yarn !(docs|site) is one literal ignored glob, so neither workspace is dropped" 1 "$r" "firebase-sdk"

r="$(new_repo pnpm-negation)"
printf '{"name":"root","private":true,"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
printf 'packages:\n  - "packages/*"\n  - "!packages/fixture"\n' > "$r/pnpm-workspace.yaml"
pkg "$r/packages/fixture" "" "@firebase/rules-unit-testing"; pkg "$r/packages/app" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "a !-prefixed workspace pattern excludes nothing (dependabot-core fetches it literally)" 1 "$r" "firebase-sdk"

r="$(new_repo yarn-extglob-single)"
printf '{"name":"root","private":true,"workspaces":["packages/!(docs)"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/docs" "" "@firebase/rules-unit-testing"; pkg "$r/packages/app" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "Yarn !(docs) drops packages/docs" 0 "$r" "PASS"

r="$(new_repo yarn-extglob-reincluded)"
printf '{"name":"root","private":true,"workspaces":["packages/!(docs)","packages/docs"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/docs" "" "@firebase/rules-unit-testing"; pkg "$r/packages/app" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "a later pattern re-includes what an earlier !(docs) ignored (per-pattern scope)" 1 "$r" "firebase-sdk"

# Workspace globs use Ruby File.fnmatch(FNM_PATHNAME), as dependabot-core does.
r="$(new_repo ws-dot-slash)"
printf '{"name":"root","private":true,"workspaces":["./packages/*"]}\n' > "$r/package.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "a leading ./ in a workspace glob is normalised away" 1 "$r" "firebase-sdk"

r="$(new_repo ws-hidden)"
printf '{"name":"root","private":true,"workspaces":["packages/*"],"dependencies":{"firebase":"^13.0.0"}}\n' > "$r/package.json"
pkg "$r/packages/.fixture" "" "@firebase/rules-unit-testing"; pkg "$r/packages/app" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "packages/* does not match a hidden packages/.fixture (no FNM_DOTMATCH)" 0 "$r" "PASS"

r="$(new_repo ws-char-class)"
printf '{"name":"root","private":true,"workspaces":["packages/[af]*"]}\n' > "$r/package.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "a [set] character class in a workspace glob is honoured" 1 "$r" "firebase-sdk"

r="$(new_repo ws-class-escape)"
cat > "$r/package.json" <<'JSON'
{"name":"root","private":true,"workspaces":["packages/[a\\-c]*"]}
JSON
pkg "$r/packages/-app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "an escaped \\- inside a class is a literal hyphen, as Ruby fnmatch reads it" 1 "$r" "firebase-sdk"

r="$(new_repo ws-class-reversed)"
printf '{"name":"root","private":true,"workspaces":["packages/[z-a]*"]}\n' > "$r/package.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"; pkg "$r/packages/moo" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "a reversed range [z-a] matches only its endpoints (Ruby) and never crashes" 1 "$r" "firebase-sdk"

r="$(new_repo ws-root-extglob)"
printf '{"name":"root","private":true,"workspaces":["!(docs)"]}\n' > "$r/package.json"
pkg "$r/app" "$FB_PROD" "$FB_DEV"; pkg "$r/docs" "react" ""
write_config "$r" "$TYPE_GROUPS"
expect "a root-level !(docs) is a Yarn extglob, not a skipped !-pattern" 1 "$r" "firebase-sdk"

r="$(new_repo ws-nohoist)"
printf '{"name":"root","private":true,"workspaces":{"packages":["packages/*"],"nohoist":["tools/*"]}}\n' > "$r/package.json"
pkg "$r/packages/app" "react" ""; pkg "$r/tools/rules" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "object-form workspaces also read nohoist (dependabot-core values_at)" 1 "$r" "firebase-sdk"

r="$(new_repo ws-no-star-literal)"
printf '{"name":"root","private":true,"workspaces":["packages/ap?"]}\n' > "$r/package.json"
pkg "$r/packages/app" "$FB_PROD" "$FB_DEV"
write_config "$r" "$TYPE_GROUPS"
expect "a workspace pattern without * is a literal path (dependabot-core fast path)" 0 "$r" "PASS"

r="$(new_repo dirs-single-star)"
pkg "$r" "$FB_PROD" "$FB_DEV"; pkg "$r/web" "react" ""
cat > "$r/.github/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directories:
      - "*"
    schedule:
      interval: "weekly"
    groups:
      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"
YAML
expect "directories: [\"*\"] is the layer below the root, not the root itself" 0 "$r" "PASS"

r="$(new_repo pnpm-ancestor-catalog)"
printf '{"name":"root","private":true}\n' > "$r/package.json"
printf 'catalog:\n  firebase: ^13.0.0\n' > "$r/pnpm-workspace.yaml"
printf '{"name":"app","dependencies":{"firebase":"catalog:"},"devDependencies":{"@firebase/rules-unit-testing":"^6.0.0"}}\n' > "$r/packages/app/package.json" 2>/dev/null || { mkdir -p "$r/packages/app"; printf '{"name":"app","dependencies":{"firebase":"catalog:"},"devDependencies":{"@firebase/rules-unit-testing":"^6.0.0"}}\n' > "$r/packages/app/package.json"; }
cat > "$r/.github/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/packages/app"
    schedule:
      interval: "weekly"
    groups:
      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"
YAML
expect "an entry below the root reads its ancestor's pnpm catalog" 1 "$r" 'directory "/packages/app": family '"'"'firebase-sdk'"'"

r="$(new_repo pnpm-catalog)"
printf '{"name":"root","private":true,"dependencies":{"firebase":"catalog:"},"devDependencies":{"@firebase/rules-unit-testing":"catalog:"}}\n' > "$r/package.json"
printf 'catalog:\n  firebase: ^13.0.0\n  "@firebase/rules-unit-testing": ^6.0.0\n' > "$r/pnpm-workspace.yaml"
write_config "$r" "$TYPE_GROUPS"
expect "pnpm catalog entries are production, so both share the production group" 0 "$r" "PASS"

r="$(new_repo pnpm-catalogs-named)"
printf '{"name":"root","private":true,"dependencies":{"firebase":"catalog:web"},"devDependencies":{"@firebase/rules-unit-testing":"^6.0.0"}}\n' > "$r/package.json"
printf 'catalogs:\n  web:\n    firebase: ^13.0.0\n' > "$r/pnpm-workspace.yaml"
write_config "$r" "$TYPE_GROUPS"
expect "a named catalog member still splits from a plain dev member" 1 "$r" "@firebase/rules-unit-testing -> dev-dependencies"

r="$(new_repo recursive-directories)"
pkg "$r" "react" "vitest"; pkg "$r/services/team/web" "$FB_PROD" "$FB_DEV"
cat > "$r/.github/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directories:
      - "**/*"
    schedule:
      interval: "weekly"
    groups:
      dev-dependencies:
        dependency-type: "development"
      production-dependencies:
        dependency-type: "production"
YAML
expect "directories **/* reaches nested projects" 1 "$r" 'directory "/services/team/web"'

N=$((N + 1))
if python3 - "$CHECKER" <<'PYT'
import importlib.util, sys, tempfile, os
spec = importlib.util.spec_from_file_location("dcg", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import yaml
d = tempfile.mkdtemp(); path = os.path.join(d, "dependabot.yml")
open(path, "w").write('version: 2\nupdates:\n  - package-ecosystem: "npm"\n    directory: "/"\n    groups:\n      dev-dependencies:\n        dependency-type: "development"\n')
config = yaml.safe_load(open(path))
fam = {"group": "firebase-sdk", "patterns": ["firebase"], "rationale": "x"}
real = yaml.safe_load
yaml.safe_load = lambda text: ["not", "a", "mapping"]
try:
    m.apply_fix(path, config, [{"entry": 0, "family": fam, "has_named_group": False}])
except m.ConfigError as exc:
    assert "file left unchanged" in str(exc), exc
    sys.exit(0)
finally:
    yaml.safe_load = real
sys.exit(1)
PYT
then PASS=$((PASS + 1)); echo "  PASS [$N] --fix integrity check fails closed on a malformed re-parse"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] --fix integrity check did not raise ConfigError" >&2; fi

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

# #2464: execute the actual lint-fast setup body against a depth-one clone.
# The closed transport shim changes only the GitHub fetch URL to a local bare
# remote; configuration loading, ref selection, fetch flags and checker reads
# are production behavior.
N=$((N + 1))
if python3 - "$ROOT" "$WORKDIR" <<'PYT'
import json, os, pathlib, shutil, subprocess, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
workflow = yaml.safe_load((root / '.github/workflows/repo_lint.yml').read_text())
steps = workflow['jobs']['lint_fast']['steps']
setup = next(s for s in steps if s.get('name') == 'fetch_dependabot_target_refs')
assert setup['if'] == 'matrix.shard == 1' and setup['timeout-minutes'] == 3
assert steps.index(setup) < next(i for i, s in enumerate(steps) if s.get('name') == 'check_dependabot_coupled_groups')
checkout = next(s for s in steps if s.get('uses', '').startswith('actions/checkout@'))
assert checkout['with']['persist-credentials'] is False
assert checkout['with'].get('fetch-depth', 1) == 1

area = work / 'workflow-target-refs'; area.mkdir()
real_git = shutil.which('git')
def git(cwd, *args):
    return subprocess.run([real_git, '-C', str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()
seed = area / 'seed'; seed.mkdir(); git(seed, 'init', '-q', '-b', 'main')
git(seed, 'config', 'user.name', 'fixture'); git(seed, 'config', 'user.email', 'fixture@example.invalid')
git(seed, 'config', 'commit.gpgsign', 'false')
(seed / 'package.json').write_text('{"dependencies":{"react":"*"}}')
git(seed, 'add', '.'); git(seed, 'commit', '-qm', 'main')
git(seed, 'checkout', '-qb', 'release')
(seed / 'package.json').write_text('{"dependencies":{"firebase":"*"},"devDependencies":{"@firebase/rules-unit-testing":"*"}}')
git(seed, 'commit', '-qam', 'release'); git(seed, 'checkout', '-q', 'main')
remote = area / 'remote.git'; git(area, 'clone', '--bare', str(seed), str(remote))
clone = area / 'checkout'; git(area, 'clone', '--depth=1', '--no-tags', '--branch', 'main', remote.as_uri(), str(clone))
(clone / '.github').mkdir(); (clone / 'scripts/ci').mkdir(parents=True)
shutil.copy2(root / 'scripts/ci/dependabot_coupled_groups.py', clone / 'scripts/ci')
config = clone / '.github/dependabot.yml'
def write_config(branch=None):
    entry = {'package-ecosystem':'npm','directory':'/','schedule':{'interval':'weekly'},
             'groups':{'dev':{'dependency-type':'development'},'prod':{'dependency-type':'production'}}}
    if branch is not None: entry['target-branch'] = branch
    config.write_text(yaml.safe_dump({'version':2,'updates':[entry, dict(entry),
        dict(entry, **{'target-branch':'disabled','open-pull-requests-limit':0})]}))
log = area / 'calls.jsonl'; shim = area / 'bin'; shim.mkdir()
(shim / 'git').write_text('''#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]
with open(os.environ['TARGET_REF_LOG'],'a') as f:
    f.write(json.dumps({'args':args,'auth':os.environ.get('GIT_CONFIG_COUNT')=='3',
        'no_helper':os.environ.get('GIT_CONFIG_VALUE_0')==''})+'\\n')
if args and args[0]=='fetch':
    assert args[1:4]==['--no-tags','--depth=1','--']
    assert args[4]=='https://github.com/example/fixture.git'
    assert os.environ['GIT_CONFIG_VALUE_2'].startswith('AUTHORIZATION: basic ')
    args[4]=os.environ['TARGET_REF_REMOTE']
os.execv(os.environ['TARGET_REF_GIT'],[os.environ['TARGET_REF_GIT'],*args])
'''); (shim / 'git').chmod(0o755)
env = dict(os.environ, PATH=str(shim)+os.pathsep+os.environ['PATH'], GITHUB_BASE_REF='main',
    GITHUB_REF_NAME='123/merge', GITHUB_SERVER_URL='https://github.com', GITHUB_REPOSITORY='example/fixture',
    GITHUB_TOKEN='synthetic-read-token', TARGET_REF_REMOTE=remote.as_uri(), TARGET_REF_LOG=str(log), TARGET_REF_GIT=real_git)
def run_setup(expected):
    before = (clone / '.git/config').read_bytes()
    p = subprocess.run(['bash','-e'], input=setup['run'], cwd=clone, env=env, capture_output=True, text=True, timeout=15)
    assert p.returncode == expected, (p.returncode,p.stdout,p.stderr)
    assert 'synthetic-read-token' not in p.stdout+p.stderr
    assert (clone / '.git/config').read_bytes() == before
    return p
write_config(); run_setup(0); assert not log.exists(), 'default target fetched unnecessarily'
write_config('main'); run_setup(0); assert not log.exists(), 'base target fetched unnecessarily'
write_config('release')
checker = [sys.executable,str(root/'scripts/ci/dependabot_coupled_groups.py'),'--root',str(clone)]
p = subprocess.run(checker, env=env, capture_output=True, text=True)
assert p.returncode == 2 and 'not available' in p.stderr
run_setup(0)
calls = [json.loads(x) for x in log.read_text().splitlines()]
fetches = [x for x in calls if x['args'][0]=='fetch']
assert len(fetches)==1 and fetches[0]['auth'] and fetches[0]['no_helper']
assert fetches[0]['args'][-1] == '+refs/heads/release:refs/remotes/origin/release'
assert git(clone, 'rev-list','--count','refs/remotes/origin/release') == '1'
p = subprocess.run(checker, env=env, capture_output=True, text=True)
assert p.returncode == 1 and 'reading manifests from target-branch ref refs/remotes/origin/release' in p.stdout
write_config('missing'); run_setup(2)
count = len([x for x in log.read_text().splitlines() if json.loads(x)['args'][0]=='fetch'])
write_config('bad branch'); run_setup(2)
assert len([x for x in log.read_text().splitlines() if json.loads(x)['args'][0]=='fetch']) == count
print('default/base no-fetch, alternate depth-one read, dedup/disabled filtering, missing/invalid refusal, unchanged git config')
PYT
then PASS=$((PASS + 1)); echo "  PASS [$N] actual lint-fast target-ref setup supplies bounded alternate inputs"
else FAIL=$((FAIL + 1)); echo "  FAIL [$N] actual lint-fast target-ref setup contract" >&2; fi

echo "dependabot coupled-family group tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
