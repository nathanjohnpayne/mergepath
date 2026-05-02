# scripts/gh-projects — multi-phase GitHub Project driver kit

Reusable helpers for tracking larger, multi-phase initiatives in [GitHub Projects v2](https://docs.github.com/en/issues/planning-and-tracking-with-projects). Each phase gets a parent issue with native [sub-issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-sub-issues) links to the child tasks that make it up, and every issue is added to a Project board whose swimlanes are advanced as work moves.

The MUX Video Integration initiative ([Project #5](https://github.com/users/nathanjohnpayne/projects/5)) is the reference implementation — see [`examples/mux-video-integration/`](./examples/mux-video-integration/).

## What this gives you

- **`lib.sh`** — a sourceable library of functions: `create_parent`, `create_child`, `link_sub_issue`, `add_to_project`, `set_project_readme`, `ensure_label`, `prep_body` (placeholder substitution). Source it from a short per-initiative driver script.
- **`move-item.sh`** — a standalone CLI that moves one issue to a named Status swimlane by discovering the project's field/option IDs at runtime. Works against any Project v2 with a `Status` single-select field.
- **`examples/mux-video-integration/`** — a complete worked example: the driver script, body-file templates, and the output that produced issues #210–#230.

## Prerequisites

- `gh` installed (via Homebrew on this machine).
- A PAT in 1Password with `repo` + `project` scopes. The `nathanjohnpayne` author PAT (item `sm5kopwk6t6p3xmu2igesndzhe`) works.
- Run [scripts/op-preflight.sh](../op-preflight.sh) once per session to cache credentials.
- The target Project v2 board must have a `Status` single-select field (the default template does). `move-item.sh` discovers the field by that exact name.

```bash
# Session setup
eval "$(scripts/op-preflight.sh --agent claude --mode all)"
export GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"
```

## Anatomy of a phased initiative

For every initiative you want to track:

1. **Create the Project v2 board** in the GitHub UI. Note its owner + number (e.g. `nathanjohnpayne / 5`). Ensure it has a `Status` single-select field — the default template does.
2. **Write the plan** somewhere durable (e.g. `~/.claude/plans/<name>.md`). This becomes the Project README.
3. **Draft parent + child issue bodies** as Markdown files, using placeholders (`__PARENT_NUM__`, `__C1_NUM__`, etc.) for cross-references.
4. **Write a one-shot driver script** that sources `lib.sh` and creates everything. See [`examples/mux-video-integration/create-issues.sh`](./examples/mux-video-integration/create-issues.sh).
5. **Run the driver** once. It creates labels (if needed), parent issues, child issues, links them as sub-issues, and adds everything to the project.
6. **Mirror the plan to the Project README** via `set_project_readme` (or `gh project edit --readme`).
7. **Move items between swimlanes** with `move-item.sh` as work progresses.

## Quick reference

### Create issues from a driver

```bash
#!/usr/bin/env bash
set -euo pipefail

# Required env — declare once at top of driver.
export REPO="nathanjohnpayne/nathanpaynedotcom"
export OWNER="nathanjohnpayne"
export PROJECT=5

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib.sh"

ensure_label "myproj" "FF3366" "My multi-phase initiative"
ensure_label "phase-1" "0E8A16" "Phase 1 of a multi-phase project"

# Parent
P_URL=$(create_parent "Phase 1: …" "$SCRIPT_DIR/phase-1/parent.md" "myproj,phase-1")
P_NUM="${P_URL##*/}"

# Child — substitute __PARENT_NUM__ in the body file first.
F=$(prep_body "$SCRIPT_DIR/phase-1/c1.md" "$P_NUM")
read C1_URL C1_NUM _ <<<"$(create_child "Do the first thing" "$F" "myproj,phase-1" "$P_NUM")"
```

### Move an issue between swimlanes

```bash
PROJECT=5 OWNER=nathanjohnpayne REPO=nathanjohnpayne/nathanpaynedotcom \
  scripts/gh-projects/move-item.sh 211 "In Progress"
```

Valid status names are whatever options the Project's `Status` field has — typically `Todo`, `In Progress`, `In Review`, `Human`, `Done`.

### Set the Project README

```bash
gh project edit <N> --owner <owner> --readme "$(cat path/to/plan.md)"
```

Or from a driver that has sourced `lib.sh`:

```bash
set_project_readme ~/.claude/plans/my-initiative.md
```

## Placeholder conventions in body files

`prep_body` does a simple `sed` substitution on up to five tokens:

| Token | Meaning |
|---|---|
| `__PARENT_NUM__` | The parent issue number (always available once the parent is created). |
| `__C1_NUM__` … `__C4_NUM__` | A sibling child's issue number — useful when one child needs to reference another (e.g. "Verify the PR from sub-issue #\_\_C3\_NUM\_\_"). |

Create children in dependency order: if child C2's body references C1, create C1 first, capture its number, then `prep_body C2.md $PARENT_NUM $C1_NUM`.

## Why native sub-issues (not task lists)

[Sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-sub-issues) render as a real parent-child tree in the GitHub UI and in Projects, and the parent's progress bar tracks children automatically. Task-list checkboxes in the body work but don't roll up. `lib.sh` uses the REST API:

```
POST /repos/{owner}/{repo}/issues/{parent_num}/sub_issues
Body: {"sub_issue_id": <child_db_id>}
```

Note the `sub_issue_id` is the **integer database ID** of the child (from `gh api repos/.../issues/<num> --jq .id`), not the issue number. `gh api` must send it as a number with `-F`, not a string with `-f`.

## Gotchas

- **Hook blocks heredoc in inline `gh issue create`.** The repo's `scripts/hooks/gh-pr-guard.sh` tokenizes the command with shlex and rejects heredocs. Always write body content to a file and use `--body-file`.
- **`gh api` integer fields need `-F`.** `-f` coerces to string → 422 Invalid request.
- **Env vars don't persist across `Bash` tool calls.** Always re-eval preflight or re-read the PAT inline at the start of each shell invocation.
- **Project-item ID ≠ issue number.** The `Status` edit endpoint takes the project-level item ID (`PVTI_...`), which you look up via `gh project item-list --format json` and match by content URL. `move-item.sh` does this for you.
- **Project v2 `readme` field.** `gh project edit <N> --owner <owner> --readme <string>` overwrites the entire README. Pass the full rendered Markdown.

## Worked example

See [`examples/mux-video-integration/`](./examples/mux-video-integration/) for the exact files used to create issues #210–#230. The driver is rerunnable against a fresh project — delete existing issues first or re-point `PROJECT` to a new board.

## Two driver lifecycle patterns

Two driver shapes cover the full per-initiative lifecycle. Both use this same `lib.sh`; the difference is what they're for.

### Fresh-create driver (`examples/<initiative>/create-issues.sh`)

One-shot, non-idempotent script that builds the initial issue tree from scratch. Creates labels, parent issues, child issues in dependency order, links children as native sub-issues, and adds everything to the Project board. Use when a new initiative kicks off.

The MUX example above is a fresh-create driver. After it runs, the issue tree exists and the kit's job is mostly done — subsequent work is moving items between swimlanes via `move-item.sh` and (occasionally) refining the plan.

### Additions driver (`examples/<initiative>/additions/add-*.sh`)

Companion one-shot, non-idempotent driver that adds new children to **existing** parent issues without recreating the tree. Use when:

- A plan-review surfaces follow-on work that needs ticket coverage under existing parents (e.g., "phase 2 also needs a child for X")
- A phase scope expands mid-flight
- A mid-phase discovery needs its own ticket

Same `lib.sh` helpers — no library changes. The driver fetches existing parent numbers (or accepts them as args), prep_body's sibling references, calls `create_child` + `link_sub_issue` for each new child, then adds to the Project. The reference implementation lives in nathanpaynedotcom (`scripts/gh-projects/examples/matchline/additions/add-plan-refinements.sh` on the `matchline/issue-driver` branch — promoted in [nathanpaynedotcom#263](https://github.com/nathanjohnpayne/nathanpaynedotcom/pull/263)).

### Picking which to write

| Situation | Driver |
|---|---|
| New initiative, no issues yet | Fresh-create |
| Existing initiative, expanding scope | Additions |
| Existing initiative, refining a single existing issue | Just edit the issue directly via `gh issue edit` — no driver needed |

## Idempotency caveat

Neither driver shape is currently idempotent. Re-running a fresh-create driver against a project that already has the issues will create duplicates. The scope-creep solution would be a `create_child_once` helper that skips when a child with the same title already exists under the same parent — file as a follow-up if you find yourself wanting to safely re-run an additions driver.
