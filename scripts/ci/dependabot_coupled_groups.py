#!/usr/bin/env python3
"""Keep peer-coupled npm families in one Dependabot group (mergepath#2162).

Dependabot assigns each update to the FIRST group in an update entry whose
rules match it. Every npm entry in the fleet groups by dependency type
(``dev-dependencies`` / ``production-dependencies``), and peer-coupled
families routinely straddle that line: ``firebase`` is a production
dependency while ``@firebase/rules-unit-testing`` is a dev dependency. Their
coupled majors then open as two PRs, each bumping one half of the pair, and
both fail ``npm ci`` with ERESOLVE.

This module simulates Dependabot's first-match group assignment for every
family listed in ``scripts/ci/dependabot-coupled-families.json`` and fails
when the members a directory actually declares would be split. For each npm
entry in ``.github/dependabot.yml`` and each update type (major, minor,
patch), the members present in that directory's ``package.json`` and not
ignored for that update type must all resolve to the same, non-empty group.
A family with fewer than two active members is a no-op, so the check is
safe in every repository whatever it depends on.

Modes:
  --check (default)  report violations; exit 1 if any.
  --fix              insert each missing family group as the first group of
                     the affected entry, then re-check. The edit is textual,
                     so comments and ignore blocks survive.

Exit codes: 0 pass (or not applicable), 1 violation, 2 usage or environment
error (unparseable YAML/JSON, PyYAML unavailable under CI).
"""

from __future__ import annotations

import argparse
import fnmatch
import glob
import json
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

NAME = "check_dependabot_coupled_groups"
UPDATE_TYPES = ("major", "minor", "patch")
IGNORE_UPDATE_TYPE = {
    "major": "version-update:semver-major",
    "minor": "version-update:semver-minor",
    "patch": "version-update:semver-patch",
}
PROD_FIELDS = ("dependencies", "optionalDependencies")
DEV_FIELDS = ("devDependencies",)


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


def match(name: str, pattern: str) -> bool:
    return fnmatch.fnmatchcase(name, pattern)


def declared_dependencies(pkg: dict) -> Dict[str, str]:
    """Map package name -> 'production' | 'development'."""
    out: Dict[str, str] = {}
    for field in PROD_FIELDS:
        for name in (pkg.get(field) or {}):
            out[name] = "production"
    for field in DEV_FIELDS:
        for name in (pkg.get(field) or {}):
            out.setdefault(name, "development")
    return out


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


def first_group(groups: List[Tuple[str, dict]], name: str, dep_type: str,
                update_type: str) -> Optional[str]:
    for gname, group in groups:
        if group_matches(group, name, dep_type, update_type):
            return gname
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
            pkg_path = os.path.join(root, rel, "package.json")
            if not os.path.isfile(pkg_path):
                notes.append(f"entry {idx} directory '/{rel.lstrip('.')}': no package.json, skipped")
                continue
            deps = declared_dependencies(load_json(pkg_path))
            for family in families:
                members = sorted(
                    n for n in deps if any(match(n, p) for p in family["patterns"])
                )
                if len(members) < 2:
                    continue
                for update_type in UPDATE_TYPES:
                    active = [m for m in members if not ignored(entry, m, update_type)]
                    if len(active) < 2:
                        continue
                    assigned = {
                        m: first_group(groups, m, deps[m], update_type) for m in active
                    }
                    targets = set(assigned.values())
                    if len(targets) == 1 and None not in targets:
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
    split = ", ".join(
        f"{m} -> {g if g else '(ungrouped: its own PR)'}"
        for m, g in sorted(v["assigned"].items())
    )
    out = [
        f"FAIL: .github/dependabot.yml npm entry for directory \"{v['directory']}\": "
        f"family '{v['family']['group']}' is split for {v['update_type']} updates: {split}.",
        f"      Why: {v['family']['rationale']}",
    ]
    if v["has_named_group"]:
        out.append(
            f"      A group named '{v['family']['group']}' exists but does not capture every "
            "member first. Move it to the top of the entry's groups and drop any "
            "dependency-type or update-types restriction on it."
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
        raise ConfigError("cannot locate top-level 'updates:' for --fix")
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


def apply_fix(path: str, violations: List[dict]) -> int:
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    spans = entry_spans(lines)
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
        if idx >= len(spans):
            raise ConfigError(f"--fix: entry {idx} not found in the text layout")
        start, end, key_indent = spans[idx]
        pad = " " * key_indent
        groups_line = next(
            (i for i in range(start, end) if re.match(rf"^{pad}groups:\s*(#.*)?$", lines[i])
             or (i == start and re.match(r"^\s*-\s+groups:\s*(#.*)?$", lines[i]))),
            None,
        )
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
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
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
            n = apply_fix(config_path, violations)
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
