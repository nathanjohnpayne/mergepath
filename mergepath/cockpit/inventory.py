"""Load the same manifest inventory that the hub's sync tooling consumes."""

import json
import re
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path


HUB = "nathanjohnpayne/mergepath"
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+\Z")


@dataclass(frozen=True)
class Repository:
    name: str
    repo: str
    hub: bool = False


def load_inventory(root: Path, run=subprocess.run) -> tuple[Repository, ...]:
    """Use installed hub yq once; never install it or source the sync script."""
    try:
        result = run(
            ["yq", "-o=json", ".consumers", str(root / ".mergepath-sync.yml")],
            check=True, capture_output=True, text=True, timeout=10,
        )
        consumers = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise ValueError("manifest_inventory_unavailable") from None
    if not isinstance(consumers, list) or not consumers:
        raise ValueError("invalid_manifest_inventory")
    inventory = [Repository("mergepath", HUB, True)]
    names, repos = {"mergepath"}, {HUB.casefold()}
    for entry in consumers:
        if not isinstance(entry, dict):
            raise ValueError("invalid_manifest_inventory")
        name, repo = entry.get("name"), entry.get("repo")
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", name)
                or not isinstance(repo, str) or not REPO.fullmatch(repo)
                or name in names or repo.casefold() in repos):
            raise ValueError("invalid_manifest_inventory")
        names.add(name)
        repos.add(repo.casefold())
        inventory.append(Repository(name, repo))
    return tuple(inventory)


def public_inventory(inventory: tuple[Repository, ...], repo: str | None = None):
    if repo is not None and repo not in {item.repo for item in inventory}:
        raise ValueError("unknown_repository")
    return [asdict(item) for item in inventory if repo is None or item.repo == repo]
