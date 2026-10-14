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
``.github/dependabot.yml``, every update a family member can receive, at any
SemVer level, must land in one and the same non-empty PR target. Members can
receive different levels at once (a firebase major alongside a rules-harness
minor), so a target is compared across levels, not per level. The
simulation follows what Dependabot does:

* Entries: an entry with ``open-pull-requests-limit: 0`` has version updates
  disabled and is skipped.
* Source: the checkout, unless the entry's ``target-branch`` names another
  branch. Then manifests are read from that branch's git ref, and the check
  fails closed (exit 2) when the ref isn't available locally.
* Directories: ``directory`` / ``directories``, with ``*`` one path segment and
  ``**`` any depth, so ``**/*`` is the entry directory and everything below.
* Manifests: the directory's ``package.json`` plus the workspace manifests
  selected by its ``workspaces`` field, the nearest ``pnpm-workspace.yaml``
  (the entry directory, then each parent, as dependabot-core's
  ``fetch_file_from_parent_directories``) or ``lerna.json``, minus any that
  the entry's ``exclude-paths`` drops. Negations follow dependabot-core
  exactly: a ``!``-prefixed pattern adds nothing and subtracts nothing (it is
  fetched as a literal path that has no manifest), and Yarn's ``!(x)`` ignores
  the single literal glob ``x`` (``yarn_ignored_glob``), so ``!(docs)`` drops
  ``docs`` while ``!(docs|site)`` drops nothing.
* pnpm catalogs: ``catalog`` / ``catalogs`` entries in that same nearest
  workspace file are production dependencies, and a manifest's ``catalog:``
  requirement defers to them. Only ``dependencies``,
  ``devDependencies`` and ``optionalDependencies`` count. dependabot-core's npm
  parser reads exactly those (``DEPENDENCY_TYPES`` in
  ``npm_and_yarn/file_parser.rb``), so a ``peerDependencies``-only
  declaration is never updated and cannot be split.
* Dependency type: one per package, as Dependabot merges requirements. It is
  production when any manifest declares the package in ``dependencies`` or
  ``optionalDependencies``, and development otherwise.
* Eligibility: ``allow`` rules (name, dependency type and update types) are
  applied first, then ``ignore`` rules.
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
import json
import os
import posixpath
import re
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

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


class Tree:
    """Read-only view of the files Dependabot would read for one entry.

    Paths are POSIX and relative to the repository root; "" is the root.
    """

    def isfile(self, rel: str) -> bool:
        raise NotImplementedError

    def read(self, rel: str) -> str:
        raise NotImplementedError

    def dirs(self) -> List[str]:
        raise NotImplementedError

    def label(self, rel: str) -> str:
        return rel or "."

    def json(self, rel: str):
        try:
            return json.loads(self.read(rel))
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            raise ConfigError(f"{self.label(rel)}: {exc}") from exc

    def yaml(self, rel: str):
        import yaml  # type: ignore  # main() proved PyYAML importable
        try:
            return yaml.safe_load(self.read(rel))
        except yaml.YAMLError as exc:
            raise ConfigError(f"{self.label(rel)}: YAML parse error: {exc}") from exc


SKIP_DIRS = {".git", "node_modules"}


class FsTree(Tree):
    def __init__(self, root: str):
        self.root = root
        self._dirs: Optional[List[str]] = None

    def isfile(self, rel: str) -> bool:
        return os.path.isfile(os.path.join(self.root, rel))

    def read(self, rel: str) -> str:
        with open(os.path.join(self.root, rel), encoding="utf-8") as fh:
            return fh.read()

    def dirs(self) -> List[str]:
        if self._dirs is None:
            out = []
            for cur, subdirs, _files in os.walk(self.root):
                subdirs[:] = sorted(d for d in subdirs if d not in SKIP_DIRS)
                rel = os.path.relpath(cur, self.root)
                out.append("" if rel == "." else rel.replace(os.sep, "/"))
            self._dirs = out
        return self._dirs


class GitTree(Tree):
    def __init__(self, root: str, ref: str):
        self.root, self.ref = root, ref
        listing = subprocess.run(
            ["git", "-C", root, "ls-tree", "-r", "--name-only", ref],
            check=True, capture_output=True, text=True,
        ).stdout.split("\n")
        self._files = {f for f in listing if f}
        dirs = {""}
        for f in self._files:
            d = posixpath.dirname(f)
            while d and d not in dirs:
                dirs.add(d)
                d = posixpath.dirname(d)
        self._dirs = sorted(d for d in dirs if not (set(d.split("/")) & SKIP_DIRS))

    def label(self, rel: str) -> str:
        return f"{self.ref}:{rel or '.'}"

    def isfile(self, rel: str) -> bool:
        return rel in self._files

    def read(self, rel: str) -> str:
        return subprocess.run(
            ["git", "-C", self.root, "show", f"{self.ref}:{rel}"],
            check=True, capture_output=True, text=True,
        ).stdout

    def dirs(self) -> List[str]:
        return self._dirs


def git_out(root: str, *args: str) -> Optional[str]:
    try:
        return subprocess.run(["git", "-C", root, *args], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def entry_tree(root: str, entry: dict, checkout: Tree) -> Tree:
    """Where Dependabot reads this entry's manifests from."""
    branch = entry.get("target-branch")
    if not isinstance(branch, str) or not branch:
        return checkout
    # The branch this checkout is (or is merging into) becomes the target
    # branch's content, so the checkout is the right view of it.
    current = {os.environ.get("GITHUB_BASE_REF"), os.environ.get("GITHUB_REF_NAME"),
               git_out(root, "rev-parse", "--abbrev-ref", "HEAD")}
    if branch in current:
        return checkout
    for ref in (f"refs/remotes/origin/{branch}", f"refs/heads/{branch}"):
        if git_out(root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"):
            return GitTree(root, ref)
    raise ConfigError(
        f"target-branch '{branch}' is not available in this checkout, so its manifests "
        f"can't be read; fetch it first (git fetch --depth=1 origin {branch}:refs/remotes/origin/{branch})"
    )


def path_glob(pattern: str) -> "re.Pattern[str]":
    """Path glob: ``*``/``?`` stay within one segment, ``**`` spans any depth."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3
        elif pattern.startswith("**", i):
            out.append(".*"); i += 2
        elif pattern[i] == "*":
            out.append("[^/]*"); i += 1
        elif pattern[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pattern[i])); i += 1
    return re.compile("".join(out))


EXTGLOB = re.compile(r"!\(([^()]*)\)")


def expand_pattern(pattern: str) -> Tuple[str, List[str]]:
    """Split a workspace pattern into (positive glob, ignored globs).

    Mirrors dependabot-core: every ``!(x)`` becomes ``*`` in the positive
    glob (``matching_paths``), and the ignored glob is the pattern with each
    ``!(x)`` replaced by ``x`` verbatim (``yarn_ignored_glob``), matched as a
    plain path glob. ``|`` has no meaning there, so ``!(docs|site)`` ignores
    the literal path ``docs|site``, which matches nothing.
    """
    if not EXTGLOB.search(pattern):
        return pattern, []
    positive = EXTGLOB.sub("*", pattern)
    ignored = EXTGLOB.sub(lambda m: m.group(1), pattern)
    return positive, [ignored]


def join(rel: str, sub: str) -> str:
    sub = sub.strip("/")
    if sub in ("", "."):
        return rel
    return posixpath.normpath(posixpath.join(rel, sub)) if rel else posixpath.normpath(sub)


def glob_dirs(tree: Tree, base: str, pattern: str) -> List[str]:
    """Directories under ``base`` matching ``pattern`` (relative to ``base``)."""
    pat = pattern.strip("/")
    if not any(ch in pat for ch in "*?"):
        target = join(base, pat)
        return [target] if target in tree.dirs() else []
    rx = path_glob(join(base, pat) if base else pat)
    # The globstar forms (`**`, `**/*`) also select the base directory itself;
    # a lone `*` is only the layer below it (GitHub reserves `/` for the root).
    hits = [d for d in tree.dirs() if d != base and rx.fullmatch(d)]
    if re.fullmatch(r"\*\*(/\*{1,2})*", pat):
        hits.insert(0, base)
    return hits


def class_body(body: str) -> str:
    """Translate an fnmatch ``[...]`` body into a Python regex class body.

    Ruby treats ``\\x`` inside a class as the literal ``x`` (so ``[a\\-c]`` is
    ``a``, ``-`` or ``c``), ``a-z`` as a range, and a reversed range such as
    ``z-a`` as matching only its two endpoints. Every other character is
    literal, including regex-only metacharacters such as ``^`` and ``[``.
    """
    def take(k: int) -> Tuple[str, int]:
        if body[k] == "\\" and k + 1 < len(body):
            return body[k + 1], k + 2
        return body[k], k + 1

    out: List[str] = []
    i = 0
    while i < len(body):
        lo, j = take(i)
        # A range needs a character on both sides of an unescaped "-".
        if j < len(body) - 1 and body[j] == "-":
            hi, k = take(j + 1)
            if ord(lo) <= ord(hi):
                out.append(re.escape(lo) + "-" + re.escape(hi))
            else:
                out.append(re.escape(lo) + re.escape(hi))
            i = k
            continue
        out.append(re.escape(lo))
        i = j
    return "".join(out)


def fnmatch_glob(pattern: str) -> "re.Pattern[str]":
    """Ruby ``File.fnmatch(pattern, path, File::FNM_PATHNAME)``, as
    dependabot-core matches workspace paths: ``*``, ``?`` and ``[set]`` stay
    within one segment and never match a leading ``.`` (no FNM_DOTMATCH), and
    ``**/`` spans zero or more non-hidden directories.
    """
    out: List[str] = []
    i, seg_start = 0, True
    while i < len(pattern):
        c = pattern[i]
        if seg_start and pattern.startswith("**/", i):
            out.append(r"(?:[^/.][^/]*/)*"); i += 3; continue
        if c == "*":
            while i < len(pattern) and pattern[i] == "*":
                i += 1
            out.append(r"(?!\.)[^/]*" if seg_start else r"[^/]*"); seg_start = False; continue
        if c == "?":
            out.append(r"[^/.]" if seg_start else r"[^/]"); i += 1; seg_start = False; continue
        if c == "[":
            start = i + 2 if pattern[i + 1:i + 2] in ("!", "^") else i + 1
            # First unescaped "]" after at least one class character.
            j, k = -1, start + 1 if pattern[start:start + 1] == "]" else start
            while k < len(pattern):
                if pattern[k] == "\\":
                    k += 2; continue
                if pattern[k] == "]":
                    j = k; break
                k += 1
            if j != -1:
                body = pattern[i + 1:j]
                negate = body[:1] in ("!", "^")
                body = class_body(body[1:] if negate else body)
                lead = r"(?!\.)" if seg_start else ""
                out.append(lead + ("[^/" + body + "]" if negate else "(?!/)[" + body + "]"))
                i, seg_start = j + 1, False
                continue
        if c == "\\" and i + 1 < len(pattern):
            out.append(re.escape(pattern[i + 1])); i += 2; seg_start = False; continue
        out.append(re.escape(c)); seg_start = c == "/"; i += 1
    try:
        return re.compile("".join(out))
    except re.error as exc:
        # Fail closed through the documented exit 2, never a traceback.
        raise ConfigError(f"unsupported workspace glob {pattern!r}: {exc}") from exc


def workspace_pattern(pattern: str) -> str:
    """dependabot-core's normalisation before matching: drop a leading ``./``,
    and a trailing ``**`` means ``**/*`` (``matching_paths``)."""
    pat = re.sub(r"^\./", "", pattern).strip("/")
    return pat + "/*" if pat.endswith("**") else pat


def workspace_glob_dirs(tree: Tree, base: str, pattern: str) -> List[str]:
    """Workspace directories under ``base`` matching ``pattern`` with fnmatch semantics."""
    pat = workspace_pattern(pattern)
    # dependabot-core's find_directories fast path: a pattern (and, through
    # recursive_find_directories, each path segment) without "*" is a literal
    # path even if it contains "?" or "[". Only "*" segments are globbed.
    if "*" not in pat:
        target = join(base, pat)
        return [target] if target in tree.dirs() else []
    def literal(seg: str) -> str:
        return re.sub(r"([?\[\]\\])", r"\\\1", seg)
    segs = [seg if "*" in seg else literal(seg) for seg in pat.split("/")]
    head = [literal(seg) for seg in base.split("/")] if base else []
    rx = fnmatch_glob("/".join(head + segs))
    return [d for d in tree.dirs() if d != base and rx.fullmatch(d)]


def excluded(entry: dict, rel_to_entry: str) -> bool:
    """Dependabot ``exclude-paths`` (globs relative to the entry directory)."""
    for pattern in entry.get("exclude-paths") or []:
        if not isinstance(pattern, str):
            continue
        rx = path_glob(pattern.strip("/"))
        parts = rel_to_entry.split("/")
        # A pattern naming the manifest, its directory, or any ancestor
        # directory excludes it.
        candidates = ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]
        candidates.append(f"{rel_to_entry}/package.json")
        if any(rx.fullmatch(c) for c in candidates):
            return True
    return False


def nearest(tree: Tree, rel: str, filename: str) -> Optional[str]:
    """The entry directory's own file, else the closest parent's."""
    cur = rel
    while True:
        candidate = join(cur, filename)
        if tree.isfile(candidate):
            return candidate
        if not cur:
            return None
        cur = posixpath.dirname(cur)


def workspace_config(tree: Tree, rel: str, pkg: dict) -> Tuple[List[str], Dict[str, str]]:
    """Workspace patterns and pnpm catalog dependencies for a directory."""
    patterns: List[str] = []
    catalog: Dict[str, str] = {}
    spec = pkg.get("workspaces")
    if isinstance(spec, dict):
        # dependabot-core reads both keys: values_at("packages", "nohoist").
        spec = [p for key in ("packages", "nohoist") if isinstance(spec.get(key), list) for p in spec[key]]
    if isinstance(spec, list):
        patterns += [p for p in spec if isinstance(p, str)]
    pnpm = nearest(tree, rel, "pnpm-workspace.yaml")
    if pnpm is not None:
        data = tree.yaml(pnpm) or {}
        if isinstance(data, dict):
            if isinstance(data.get("packages"), list):
                patterns += [p for p in data["packages"] if isinstance(p, str)]
            # dependabot-core parses every catalog entry as a production dependency.
            sources = [data.get("catalog")]
            if isinstance(data.get("catalogs"), dict):
                sources += list(data["catalogs"].values())
            for source in sources:
                if isinstance(source, dict):
                    for name in source:
                        catalog[str(name)] = "production"
    lerna = join(rel, "lerna.json")
    if tree.isfile(lerna):
        packages = tree.json(lerna).get("packages")
        if isinstance(packages, list):
            patterns += [p for p in packages if isinstance(p, str)]
    return patterns, catalog


def workspace_dirs(tree: Tree, rel: str, patterns: List[str], entry: dict) -> List[str]:
    include: List[str] = []
    for pattern in patterns:
        if pattern.startswith("!") and not EXTGLOB.match(pattern):
            # dependabot-core fetches "!x" as a literal path with no manifest:
            # it contributes nothing and, unlike pnpm itself, excludes nothing.
            # A leading Yarn extglob such as "!(docs)" is NOT that: it falls
            # through and expands like any other !(x) pattern.
            continue
        positive, negated = expand_pattern(pattern)
        # Each pattern's own !(x) ignore filters only that pattern's matches,
        # as dependabot-core's flat_map does; a later pattern can re-include.
        ignore = [fnmatch_glob(f"{rel}/{workspace_pattern(n)}" if rel else workspace_pattern(n)) for n in negated]
        for hit in workspace_glob_dirs(tree, rel, positive):
            if hit != rel and hit not in include and not any(rx.fullmatch(hit) for rx in ignore):
                include.append(hit)
    out = []
    for ws in include:
        if not tree.isfile(join(ws, "package.json")):
            continue
        rel_to_entry = posixpath.relpath(ws, rel) if rel else ws
        if excluded(entry, rel_to_entry):
            continue
        out.append(ws)
    return out


def declared_dependencies(tree: Tree, rel: str, entry: dict) -> Dict[str, str]:
    """Map package name -> its one effective Dependabot dependency type."""
    pkg = tree.json(join(rel, "package.json"))
    patterns, out = workspace_config(tree, rel, pkg)
    manifests = [pkg] + [tree.json(join(ws, "package.json"))
                         for ws in workspace_dirs(tree, rel, patterns, entry)]
    for manifest in manifests:
        for field, dep_type in DEPENDENCY_FIELDS.items():
            for name, req in (manifest.get(field) or {}).items():
                # A `catalog:` requirement is updated through the catalog entry.
                if isinstance(req, str) and req.startswith("catalog:"):
                    continue
                if dep_type == "production" or name not in out:
                    out[name] = dep_type
    return out


def allowed(entry: dict, name: str, dep_type: str, update_type: str) -> bool:
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
        if kind not in (None, "all", "direct") and kind != dep_type:
            continue
        types = rule.get("update-types")
        if types and IGNORE_UPDATE_TYPE[update_type] not in types and update_type not in types:
            continue
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


def entry_directories(tree: Tree, entry: dict) -> List[str]:
    dirs: List[str] = []
    raw = []
    if isinstance(entry.get("directory"), str):
        raw.append(entry["directory"])
    raw.extend(d for d in entry.get("directories") or [] if isinstance(d, str))
    for d in raw:
        pat = d.strip("/")
        if any(ch in pat for ch in "*?"):
            hits = glob_dirs(tree, "", pat)
        else:
            hits = [join("", pat)]
        dirs += [h for h in hits if h not in dirs]
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
    checkout = FsTree(root)
    """Return (violations, notes). A violation is a dict keyed by entry index."""
    violations = []
    notes = []
    for idx, entry in enumerate(config.get("updates") or []):
        if not isinstance(entry, dict) or entry.get("package-ecosystem") != "npm":
            continue
        if entry.get("open-pull-requests-limit") == 0:
            notes.append(f"entry {idx}: open-pull-requests-limit is 0 (version updates disabled), skipped")
            continue
        groups = [(k, v) for k, v in (entry.get("groups") or {}).items()]
        tree = entry_tree(root, entry, checkout)
        if tree is not checkout:
            notes.append(f"entry {idx}: reading manifests from target-branch ref {tree.ref}")
        for rel in entry_directories(tree, entry):
            if not tree.isfile(join(rel, "package.json")):
                notes.append(f"entry {idx} directory '/{rel}': no package.json, skipped")
                continue
            deps = declared_dependencies(tree, rel, entry)
            for family in families:
                members = sorted(
                    n for n in deps if any(match(n, p) for p in family["patterns"])
                )
                # member -> {update type -> PR target}, over the levels it can receive.
                assigned: Dict[str, Dict[str, Optional[str]]] = {}
                for m in members:
                    levels = {
                        u: pr_target(entry, groups, m, deps[m], u)
                        for u in UPDATE_TYPES
                        if allowed(entry, m, deps[m], u) and not ignored(entry, m, u)
                    }
                    if levels:
                        assigned[m] = levels
                if len(assigned) < 2:
                    continue
                targets = {t for levels in assigned.values() for t in levels.values()}
                if len(targets) == 1 and None not in targets:
                    continue
                violations.append({
                    "entry": idx,
                    "directory": "/" + rel,
                    "family": family,
                    "assigned": assigned,
                    "has_named_group": family["group"] in dict(groups),
                })
    return violations, notes


def describe(v: dict) -> List[str]:
    def label(levels: Dict[str, Optional[str]]) -> str:
        by_target: Dict[str, List[str]] = {}
        for u in UPDATE_TYPES:
            if u in levels:
                by_target.setdefault(levels[u] or "(ungrouped: its own PR)", []).append(u)
        return " + ".join(f"{t} [{', '.join(us)}]" for t, us in by_target.items())

    split = ", ".join(f"{m} -> {label(levels)}" for m, levels in sorted(v["assigned"].items()))
    out = [
        f"FAIL: .github/dependabot.yml npm entry for directory \"{v['directory']}\": "
        f"family '{v['family']['group']}' is split across PRs: {split}.",
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
    new_updates = after.get("updates") if isinstance(after, dict) else None
    if not isinstance(new_updates, list) or len(new_updates) != len(entries):
        raise ConfigError("--fix: edit changed the 'updates' list shape; file left unchanged")
    for idx, entry in enumerate(entries):
        new_entry = new_updates[idx]
        if not isinstance(new_entry, dict):
            raise ConfigError(f"--fix: edit corrupted entry {idx}; file left unchanged")
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
