#!/usr/bin/env python3
"""Keep peer-coupled npm families in one Dependabot group (mergepath#2162).

Dependabot assigns each update to the FIRST group in an update entry whose
rules match it. Every npm entry in the fleet groups by dependency type
(``dev-dependencies`` / ``production-dependencies``), and peer-coupled
families routinely straddle that line: ``firebase`` is a production
dependency while ``@firebase/rules-unit-testing`` is a dev dependency. Their
coupled majors then open as two PRs, each bumping one half of the pair, and
both fail ``npm ci`` with ERESOLVE.

This module simulates Dependabot's pull-request targeting for every family
listed in ``scripts/ci/dependabot-coupled-families.json`` and fails when the
members a directory actually declares would be split. For each npm entry in
``.github/dependabot.yml`` and each update type (major, minor, patch), every
member the entry can update must land in the same, non-empty PR target. The
simulation follows what Dependabot does:

* Manifests: the directory's ``package.json`` plus the manifests its
  ``workspaces`` field selects. Only ``dependencies``, ``devDependencies`` and
  ``optionalDependencies`` count. dependabot-core's npm parser reads exactly
  those (``DEPENDENCY_TYPES`` in ``npm_and_yarn/file_parser.rb``), so a
  ``peerDependencies``-only declaration is never updated and cannot be split.
* Eligibility: ``allow`` rules are applied first, then ``ignore`` rules.
* Targets: the first matching ``groups`` entry. A group with
  ``group-by: dependency-name`` opens one PR per dependency. An entry in a
  ``multi-ecosystem-group`` sends otherwise-ungrouped updates that match its
  ``patterns`` to that shared PR, and everything else is its own PR.
* Patterns: ``*`` is the only wildcard, as in Dependabot. Every other
  character, including ``?`` and ``[``, matches itself.

A family with fewer than two eligible members is a no-op, so the check is
safe in every repository whatever it depends on.

Modes:
  --check (default)  report violations; exit 1 if any.
  --fix              insert each missing family group as the first group of
                     the affected entry, then re-check. The edit is textual,
                     so comments and ignore blocks survive. A layout it
                     cannot edit safely (a flow-style ``groups:`` mapping)
                     fails closed and leaves the file untouched.

Exit codes: 0 pass (or not applicable), 1 violation, 2 usage or environment
error (unparseable YAML/JSON, unsupported --fix layout, PyYAML unavailable
under CI).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from typing import Dict, List, Optional, Set, Tuple

NAME = "check_dependabot_coupled_groups"
UPDATE_TYPES = ("major", "minor", "patch")
IGNORE_UPDATE_TYPE = {
    "major": "version-update:semver-major",
    "minor": "version-update:semver-minor",
    "patch": "version-update:semver-patch",
}
# dependabot-core npm_and_yarn FileParser::DEPENDENCY_TYPES. peerDependencies
# is deliberately absent: Dependabot never updates a peer-only declaration.
DEPENDENCY_FIELDS = {
    "dependencies": "production",
    "optionalDependencies": "production",
    "devDependencies": "development",
}


class ConfigError(Exception):
    pass


def load_yaml(path: str):
    try:
        import yaml  # type: ignore
    except ImportError:
        return None, "PyYAML is not importable"
    try:
        with open(path, encoding="utf-8") as fh:
            return yaml.safe_load(fh), None
    except yaml.YAMLError as exc:
        raise ConfigError(f"{path}: YAML parse error: {exc}") from exc


def load_json(path: str):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise ConfigError(f"{path}: {exc}") from exc


_PATTERN_CACHE: Dict[str, "re.Pattern[str]"] = {}


def match(name: str, pattern: str) -> bool:
    """Dependabot pattern match: ``*`` is the only wildcard."""
    rx = _PATTERN_CACHE.get(pattern)
    if rx is None:
        rx = re.compile(".*".join(re.escape(part) for part in pattern.split("*")))
        _PATTERN_CACHE[pattern] = rx
    return rx.fullmatch(name) is not None


def workspace_dirs(root: str, rel: str, pkg: dict) -> List[str]:
    spec = pkg.get("workspaces")
    if isinstance(spec, dict):
        spec = spec.get("packages")
    if not isinstance(spec, list):
        return []
    out: List[str] = []
    base = os.path.join(root, rel)
    for pattern in spec:
        if not isinstance(pattern, str) or pattern.startswith("!"):
            continue
        for hit in sorted(glob.glob(os.path.join(base, pattern))):
            if os.path.isfile(os.path.join(hit, "package.json")):
                out.append(os.path.relpath(hit, root))
    return out


def declared_dependencies(root: str, rel: str) -> Dict[str, Set[str]]:
    """Map package name -> dependency types across the directory's manifests."""
    pkg = load_json(os.path.join(root, rel, "package.json"))
    manifests = [pkg] + [
        load_json(os.path.join(root, ws, "package.json"))
        for ws in workspace_dirs(root, rel, pkg)
    ]
    out: Dict[str, Set[str]] = {}
    for manifest in manifests:
        for field, dep_type in DEPENDENCY_FIELDS.items():
            for name in (manifest.get(field) or {}):
                out.setdefault(name, set()).add(dep_type)
    return out


def allowed(entry: dict, name: str, dep_type: str) -> bool:
    """Dependabot ``allow``: absent means everything; otherwise any rule must match."""
    rules = entry.get("allow")
    if not rules:
        return True
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        dep = rule.get("dependency-name")
        if isinstance(dep, str) and not match(name, dep):
            continue
        kind = rule.get("dependency-type")
        if kind in (None, "all", "direct") or kind == dep_type:
            return True
    return False


def ignored(entry: dict, name: str, update_type: str) -> bool:
    """True when an ignore rule drops every update of this type for name.

    A rule scoped by ``versions`` only drops some releases, so it is not
    treated as ignoring the update type (conservative: the member stays
    active and must still be grouped).
    """
    for rule in entry.get("ignore") or []:
        if not isinstance(rule, dict):
            continue
        dep = rule.get("dependency-name")
        if not isinstance(dep, str) or not match(name, dep):
            continue
        if rule.get("versions"):
            continue
        types = rule.get("update-types")
        if not types or IGNORE_UPDATE_TYPE[update_type] in types:
            return True
    return False


def group_matches(group: dict, name: str, dep_type: str, update_type: str) -> bool:
    if not isinstance(group, dict):
        return False
    if group.get("applies-to", "version-updates") != "version-updates":
        return False
    wanted = group.get("dependency-type")
    if wanted and wanted != dep_type:
        return False
    types = group.get("update-types")
    if types and update_type not in types:
        return False
    patterns = group.get("patterns")
    if patterns and not any(match(name, p) for p in patterns):
        return False
    if any(match(name, p) for p in group.get("exclude-patterns") or []):
        return False
    return True


def pr_target(entry: dict, groups: List[Tuple[str, dict]], name: str,
              dep_type: str, update_type: str) -> Optional[str]:
    """The PR an update lands in; None means its own single-dependency PR."""
    for gname, group in groups:
        if group_matches(group, name, dep_type, update_type):
            if group.get("group-by") == "dependency-name":
                return f"{gname}[{name}]"
            return gname
    meg = entry.get("multi-ecosystem-group")
    if isinstance(meg, str) and any(match(name, p) for p in entry.get("patterns") or []):
        return f"multi-ecosystem-group:{meg}"
    return None


def entry_directories(root: str, entry: dict) -> List[str]:
    dirs: List[str] = []
    raw = []
    if isinstance(entry.get("directory"), str):
        raw.append(entry["directory"])
    raw.extend(d for d in entry.get("directories") or [] if isinstance(d, str))
    for d in raw:
        rel = d.strip("/")
        if any(ch in rel for ch in "*?["):
            for hit in sorted(glob.glob(os.path.join(root, rel))):
                if os.path.isdir(hit):
                    dirs.append(os.path.relpath(hit, root))
        else:
            dirs.append(rel or ".")
    return dirs


def family_snippet(family: dict, indent: str) -> List[str]:
    lines = [
        f"{indent}# Peer-coupled family (scripts/ci/dependabot-coupled-families.json,",
        f"{indent}# mergepath#2162). Keep it first so its members move together.",
        f"{indent}{family['group']}:",
        f"{indent}  patterns:",
    ]
    lines += [f'{indent}    - "{p}"' for p in family["patterns"]]
    return lines


def find_violations(root: str, config: dict, families: List[dict]):
    """Return (violations, notes). A violation is a dict keyed by entry index."""
    violations = []
    notes = []
    for idx, entry in enumerate(config.get("updates") or []):
        if not isinstance(entry, dict) or entry.get("package-ecosystem") != "npm":
            continue
        groups = [(k, v) for k, v in (entry.get("groups") or {}).items()]
        for rel in entry_directories(root, entry):
            if not os.path.isfile(os.path.join(root, rel, "package.json")):
                notes.append(f"entry {idx} directory '/{rel.lstrip('.')}': no package.json, skipped")
                continue
            deps = declared_dependencies(root, rel)
            for family in families:
                members = sorted(
                    n for n in deps if any(match(n, p) for p in family["patterns"])
                )
                for update_type in UPDATE_TYPES:
                    assigned: Dict[str, Set[Optional[str]]] = {}
                    for m in members:
                        if ignored(entry, m, update_type):
                            continue
                        targets = {
                            pr_target(entry, groups, m, t, update_type)
                            for t in sorted(deps[m]) if allowed(entry, m, t)
                        }
                        if targets:
                            assigned[m] = targets
                    if len(assigned) < 2:
                        continue
                    union = set().union(*assigned.values())
                    if len(union) == 1 and None not in union:
                        continue
                    violations.append({
                        "entry": idx,
                        "directory": "/" + ("" if rel == "." else rel),
                        "family": family,
                        "update_type": update_type,
                        "assigned": assigned,
                        "has_named_group": family["group"] in dict(groups),
                    })
                    break  # one report per family per directory is enough
    return violations, notes


def describe(v: dict) -> List[str]:
    def label(targets: Set[Optional[str]]) -> str:
        names = sorted(t if t else "(ungrouped: its own PR)" for t in targets)
        return " + ".join(names)

    split = ", ".join(f"{m} -> {label(t)}" for m, t in sorted(v["assigned"].items()))
    out = [
        f"FAIL: .github/dependabot.yml npm entry for directory \"{v['directory']}\": "
        f"family '{v['family']['group']}' is split for {v['update_type']} updates: {split}.",
        f"      Why: {v['family']['rationale']}",
    ]
    if v["has_named_group"]:
        out.append(
            f"      A group named '{v['family']['group']}' exists but does not capture every "
            "member first. Move it to the top of the entry's groups and drop any "
            "dependency-type, update-types or group-by restriction on it."
        )
    else:
        out.append("      Add as the FIRST group of this entry (or run with --fix):")
        out += family_snippet(v["family"], "        ")
    return out


# ── --fix: textual insertion that preserves comments ─────────────────────

ITEM_RE = re.compile(r"^(\s*)-\s+\S")


def entry_spans(lines: List[str]) -> List[Tuple[int, int, int]]:
    """Return (start, end, key_indent) per item of the top-level updates list."""
    upd = next((i for i, l in enumerate(lines) if re.match(r"^updates:\s*(#.*)?$", l)), None)
    if upd is None:
        raise ConfigError("--fix: cannot locate a block-style top-level 'updates:'")
    item_indent = None
    starts: List[int] = []
    end_of_list = len(lines)
    for i in range(upd + 1, len(lines)):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        m = ITEM_RE.match(line)
        if item_indent is None and m:
            item_indent = len(m.group(1))
        if item_indent is not None and indent < item_indent:
            end_of_list = i
            break
        if m and len(m.group(1)) == item_indent:
            starts.append(i)
    spans = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else end_of_list
        spans.append((s, e, item_indent + 2))
    return spans


def apply_fix(path: str, config: dict, violations: List[dict]) -> int:
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    lines = original.split("\n")
    spans = entry_spans(lines)
    entries = config.get("updates") or []
    if len(spans) != len(entries):
        raise ConfigError("--fix: the text layout of 'updates:' does not match the parsed entries")
    pending: Dict[int, List[dict]] = {}
    for v in violations:
        if v["has_named_group"]:
            continue
        fams = pending.setdefault(v["entry"], [])
        if all(f["group"] != v["family"]["group"] for f in fams):
            fams.append(v["family"])
    inserted = 0
    # Edit bottom-up so earlier spans keep their line numbers.
    for idx in sorted(pending, reverse=True):
        start, end, key_indent = spans[idx]
        pad = " " * key_indent
        groups_key = re.compile(rf"^(?:{pad}|\s*-\s+)groups:(.*)$")
        groups_line = None
        for i in range(start, end):
            m = groups_key.match(lines[i])
            if m and (i == start or lines[i].startswith(pad + "groups:")):
                rest = m.group(1).strip()
                if rest and not rest.startswith("#"):
                    raise ConfigError(
                        f"--fix: entry {idx} uses a flow-style 'groups:' mapping; "
                        "add the family group by hand"
                    )
                groups_line = i
                break
        if groups_line is None and entries[idx].get("groups"):
            raise ConfigError(f"--fix: cannot locate entry {idx}'s 'groups:' key in the text")
        block: List[str] = []
        if groups_line is not None:
            child = next(
                (lines[i] for i in range(groups_line + 1, end)
                 if lines[i].strip() and not lines[i].lstrip().startswith("#")),
                None,
            )
            gpad = " " * (len(child) - len(child.lstrip())) if child else pad + "  "
            for fam in pending[idx]:
                block += family_snippet(fam, gpad)
            lines[groups_line + 1:groups_line + 1] = block
        else:
            last = max(i for i in range(start, end) if lines[i].strip())
            block = [f"{pad}groups:"]
            for fam in pending[idx]:
                block += family_snippet(fam, pad + "  ")
            lines[last + 1:last + 1] = block
        inserted += len(pending[idx])
    updated = "\n".join(lines)
    # Integrity: the edit may only ADD family groups. Anything else means the
    # text layout fooled the editor, so restore the original and fail closed.
    import yaml  # type: ignore  # load_yaml already proved it importable
    try:
        after = yaml.safe_load(updated)
    except yaml.YAMLError as exc:
        raise ConfigError(f"--fix: edit produced invalid YAML ({exc}); file left unchanged")
    for idx, entry in enumerate(entries):
        new_entry = (after.get("updates") or [])[idx]
        expect = dict(entry)
        expect_groups = dict(entry.get("groups") or {})
        new_groups = dict(new_entry.get("groups") or {})
        for fam in pending.get(idx, []):
            expect_groups[fam["group"]] = {"patterns": list(fam["patterns"])}
        if new_groups != expect_groups or (
            {k: v for k, v in new_entry.items() if k != "groups"}
            != {k: v for k, v in expect.items() if k != "groups"}
        ):
            raise ConfigError(f"--fix: edit would change entry {idx} beyond adding groups; file left unchanged")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(updated)
    return inserted


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(prog=NAME, description=__doc__.splitlines()[0])
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--root", default=os.environ.get("MERGEPATH_DEPENDABOT_ROOT"))
    ap.add_argument("--families", default=None)
    args = ap.parse_args(argv)

    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(args.root or os.path.join(here, "..", ".."))
    families_path = args.families or os.path.join(here, "dependabot-coupled-families.json")
    config_path = os.path.join(root, ".github", "dependabot.yml")

    if not os.path.isfile(config_path):
        print(f"{NAME}: no .github/dependabot.yml — not applicable.")
        print(f"{NAME}: PASS")
        return 0

    try:
        families = load_json(families_path)["families"]
        config, err = load_yaml(config_path)
        if err:
            if os.environ.get("CI"):
                print(f"{NAME}: ERROR ({err}; repo_lint's install_python_ci_dependencies step provides it)", file=sys.stderr)
                return 2
            print(f"{NAME}: SKIP ({err}; install PyYAML to run this check locally)")
            return 0
        if not isinstance(config, dict):
            raise ConfigError(f"{config_path}: top level is not a mapping")
        violations, notes = find_violations(root, config, families)
        if args.fix and violations:
            n = apply_fix(config_path, config, violations)
            print(f"{NAME}: --fix inserted {n} family group(s) into .github/dependabot.yml")
            config, _ = load_yaml(config_path)
            violations, notes = find_violations(root, config, families)
    except ConfigError as exc:
        print(f"{NAME}: ERROR ({exc})", file=sys.stderr)
        return 2

    for note in notes:
        print(f"{NAME}: note: {note}")
    if violations:
        for v in violations:
            print("\n".join(describe(v)))
        print(f"{NAME}: FAIL")
        return 1
    print(f"{NAME}: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
