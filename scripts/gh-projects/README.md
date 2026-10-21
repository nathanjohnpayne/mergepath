# scripts/gh-projects — multi-phase GitHub Project driver kit

Reusable helpers for tracking larger, multi-phase initiatives in [GitHub Projects v2](https://docs.github.com/en/issues/planning-and-tracking-with-projects). Each phase gets a parent issue with native [sub-issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-sub-issues) links to the child tasks that make it up, and every issue is added to a Project board whose swimlanes are advanced as work moves.

The MUX Video Integration initiative ([Project #5](https://github.com/users/nathanjohnpayne/projects/5)) is the reference implementation — see [`examples/mux-video-integration/`](./examples/mux-video-integration/).

## What this gives you

- **`lib.sh`** — a sourceable library of functions: `create_parent`, `create_child`, `link_sub_issue`, `add_to_project`, `set_project_readme`, `ensure_label`, `prep_body` (placeholder substitution). Source it from a short per-initiative driver script.
- **`move-item.sh`** — a standalone CLI that moves one issue to a named Status swimlane by discovering the project's field/option IDs at runtime. Works against any Project v2 with a `Status` single-select field. One GraphQL query per move, whatever the board's size.
- **`examples/mux-video-integration/`** — a complete worked example: the driver script, body-file templates, and the output that produced issues #210–#230.

## Prerequisites

- `gh` installed (via Homebrew on this machine).
- An author PAT with `repo` + `project` scopes. Use the cached `OP_PREFLIGHT_AUTHOR_PAT` from [REVIEW_POLICY.md § PAT lookup table](../../REVIEW_POLICY.md#pat-lookup-table); these helpers verify that `GH_TOKEN` resolves to `nathanjohnpayne` before mutating issues or Project v2 items.
- Local sessions run [scripts/op-preflight.sh](../op-preflight.sh) in review mode once to cache credentials. Cloud sessions use provisioned credentials and the capability probe in [Cloud Agent Environments](../../docs/agents/cloud-environments.md), without invoking local 1Password preflight. If the session cannot perform the GraphQL-backed Project operations, hand them to a capable local session under that guide.
- The target Project v2 board must have a `Status` single-select field with the canonical options `Backlog`, `Ready`, `In progress`, `In review`, `Done`. `move-item.sh` discovers the field by that exact name. GitHub's default board template does not provide these options, so edit the board's `Status` field by hand to have exactly these five. The set is the one mergepath's new-repo bootstrap gives the board it provisions with a new repo ([`scripts/bootstrap/board-and-summary.sh`](https://github.com/nathanjohnpayne/mergepath/blob/main/scripts/bootstrap/board-and-summary.sh); hub-only, so the link is absolute). That bootstrap scaffolds a whole repo, so it is not a way to create a board for an initiative.

```bash
# Local session setup — preflight populates OP_PREFLIGHT_AUTHOR_PAT.
# Select the running agent; claude is this example's local agent.
eval "$(scripts/op-preflight.sh --agent claude --mode review)"
```

Select the author PAT before calling these helpers in a prepared local session or a cloud session with GraphQL transport and the required `repo` + `project` PAT scopes. The capability probe tests GraphQL transport; it does not verify Project scopes or mutations. In cloud this selects the provisioned credential; do not run local preflight there. Exporting a token does not remove a transport ceiling, so Claude cloud still hands these operations to a capable session.

```bash
export GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"
```

## Status lanes

Every repository's board uses the same five `Status` options, and each one has a single entry rule. The board's built-in workflows make most moves; the rest are the job of whoever is doing the work.

| Status | An item belongs here when | Moved here by |
|---|---|---|
| `Backlog` | It is captured but not yet specified well enough to start, or it has an open blocker. | The built-in *Item added to project* workflow. Whoever records or notices an open blocker, with `move-item.sh`. |
| `Ready` | It is specified well enough that an agent can start without asking questions: the issue states the problem, the expected outcome, and how to verify it; and every blocker is closed. | Whoever triages it, with `move-item.sh`. The built-in *Item reopened* workflow also lands here. |
| `In progress` | Work has started: a branch exists, but no pull request that resolves it is open. | The agent or human starting the work, with `move-item.sh`. |
| `In review` | A pull request that resolves it is open and waiting on review or merge gates. | The built-in *Pull request linked to issue* workflow, which fires when a pull request is linked to the issue: by a closing keyword in the PR body (the normal route; see [Shared Agent Operating Rules § Link the issue a pull request resolves](../../docs/agents/shared-operating-rules.md#link-the-issue-a-pull-request-resolves)) or by a manual link from the PR's *Development* sidebar. |
| `Done` | It is closed. | The built-in *Item closed* workflow. |

- **A parent issue follows its active sub-issues.** It is `In progress` only while at least one of its sub-issues is `In progress` or `In review`; it never gets a branch of its own. Between bursts of work it sits in `Ready` or `Backlog` by the same rules as any other issue, however many of its sub-issues are already done. No workflow rolls a sub-issue's lane up to its parent, so whoever moves a sub-issue into or out of `In progress` or `In review` also moves the parent with `move-item.sh`; the built-in *Item closed* workflow still moves the parent to `Done` when it closes.
- **An open blocker puts an issue in `Backlog`.** A blocker is a native *blocked by* relationship to an open issue, recorded from the issue's *Relationships* sidebar or the issue dependencies API. While any blocker is open the issue is never `Ready` or `In progress`: it sits in `Backlog`, except that an open linked pull request may hold it in `In review` (see below). When its last blocker closes, whoever notices re-checks the `Ready` entry rule and moves it to `Ready` with `move-item.sh` only if that rule is met; an issue that is still under-specified stays in `Backlog`. No built-in workflow reads blocked-by relationships, so both moves are by hand, and two built-in workflows can move a blocked issue out of `Backlog` on their own: *Item reopened* lands a reopened issue in `Ready`, so whoever reopens an issue with an open blocker moves it back to `Backlog`; *Pull request linked to issue* lands it in `In review`, which is the right lane while that pull request is open, and when the pull request closes without merging the issue goes back to `Backlog` if a blocker is still open. The relationship records the blocker, so an issue blocked by another issue carries no label for it. `status:blocked` remains only for a blocker that no issue can point at, such as a vendor or an outside event: name it in the issue body, and apply the same lane rule, `Backlog` until it clears. An issue waiting on a human decision carries `decision-needed` instead.
- **Order within a lane comes from the `priority:*` labels.** Moving an item to `Ready` says it can be started, not that it should be next.
- **These moves have no workflow.** Starting work (`Ready` to `In progress`); a resolving pull request closed without merging (the issue stays in `In review`; move it back to `In progress`, to `Ready`, or to `Backlog` if a blocker is open); parking an issue in `Backlog` when a blocker is recorded, or after *Item reopened* lands a blocked issue in `Ready`; and returning it to `Ready` when its last blocker closes and the `Ready` entry rule is met. All are done by hand.
- **The workflow targets are set by hand.** The Projects API can neither read nor set which `Status` a built-in workflow assigns, so a new board needs them configured under the board's **⋯ → Workflows**: *Item added to project* → `Backlog`, *Item reopened* → `Ready`, *Pull request linked to issue* → `In review`, *Item closed* → `Done`.

## Anatomy of a phased initiative

For every initiative you want to track:

1. **Create the Project v2 board** in the GitHub UI. Note its owner + number (e.g. `nathanjohnpayne / 5`). Ensure its `Status` single-select field has the canonical options (see [Prerequisites](#prerequisites)); the default template's options don't match.
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
  scripts/gh-projects/move-item.sh 211 "In progress"
```

The issue must already be on the board; otherwise the script fails and says so. Pass `--add-if-missing` to add it first (`gh project item-add`, idempotent) and then move it:

```bash
PROJECT=5 OWNER=nathanjohnpayne REPO=nathanjohnpayne/nathanpaynedotcom \
  scripts/gh-projects/move-item.sh --add-if-missing 211 "In progress"
```

Valid status names are the options on the Project's `Status` field. The canonical set is `Backlog`, `Ready`, `In progress`, `In review`, `Done` (see [Prerequisites](#prerequisites)). `move-item.sh` matches the name exactly, including case, so `"In Progress"` does not select `In progress`.

### Set the Project README

```bash
gh project edit <N> --owner <owner> --readme "$(cat "path/to/plan.md")"
```

Or from a driver that has sourced `lib.sh`:

```bash
set_project_readme "$HOME/.claude/plans/my-initiative.md"
```

(Use `"$HOME/..."` or `"~/path/..."` with double quotes around any path argument
so a directory name with spaces — e.g. `~/My Plans/...` — survives word-splitting.)

## Placeholder conventions in body files

`prep_body` does a simple `sed` substitution on up to five tokens:

| Token | Meaning |
|---|---|
| `__PARENT_NUM__` | The parent issue number (always available once the parent is created). |
| `__C1_NUM__` … `__C4_NUM__` | A sibling child's issue number — useful when one child needs to reference another (e.g. "Verify the PR from sub-issue #\_\_C3\_NUM\_\_"). |

Create children in dependency order: if child C2's body references C1, create C1 first, capture its number, then `prep_body C2.md $PARENT_NUM $C1_NUM`.

## Why native sub-issues (not task lists)

[Sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-sub-issues) render as a real parent-child tree in the GitHub UI and in Projects, and the parent's progress bar tracks children automatically. Task-list checkboxes in the body work but don't roll up. `lib.sh` uses the REST API:

```http
POST /repos/{owner}/{repo}/issues/{parent_num}/sub_issues
Content-Type: application/json

{"sub_issue_id": <child_db_id>}
```

Note the `sub_issue_id` is the **integer database ID** of the child (from `gh api repos/.../issues/<num> --jq .id`), not the issue number. `gh api` must send it as a number with `-F`, not a string with `-f`.

## Gotchas

- **Hook blocks heredoc in inline `gh issue create`.** The repo's `scripts/hooks/gh-pr-guard.sh` tokenizes the command with shlex and rejects heredocs. Always write body content to a file and use `--body-file`.
- **`gh api` integer fields need `-F`.** `-f` coerces to string → 422 Invalid request.
- **Env vars don't persist across `Bash` tool calls.** In local sessions, consume the cached exports with `eval "$(scripts/op-preflight.sh --agent <agent> --check --print-exports)"` at the start of each shell invocation; this never prompts. Cloud sessions use their provisioned credentials and capability probe, without local preflight. An authentication failure requires fresh human readiness before one canonical refresh, not an inline PAT reread.
- **Project-item ID ≠ issue number.** The `Status` edit endpoint takes the project-level item ID (`PVTI_...`). Resolve it through the issue (`repository { issue(number:) { projectItems { nodes { id project { id } } } } }`) and pick the node whose project is the board you want. `move-item.sh` does this for you. Don't page the board with `gh project item-list` to find one item: on a board of several hundred items each lookup costs a large share of the account's hourly GraphQL quota, and a batch of moves exhausts it.
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

Same `lib.sh` helpers — no library changes. The driver fetches existing parent numbers (or accepts them as args), prep_body's sibling references, calls `create_child` + `link_sub_issue` for each new child, then adds to the Project. The reference implementation lives in nathanpaynedotcom on `main`: [`scripts/gh-projects/examples/matchline/additions/add-plan-refinements.sh`](https://github.com/nathanjohnpayne/nathanpaynedotcom/blob/main/scripts/gh-projects/examples/matchline/additions/add-plan-refinements.sh), promoted in [nathanpaynedotcom#263](https://github.com/nathanjohnpayne/nathanpaynedotcom/pull/263).

### Picking which to write

| Situation | Driver |
|---|---|
| New initiative, no issues yet | Fresh-create |
| Existing initiative, expanding scope | Additions |
| Existing initiative, refining a single existing issue | Just edit the issue directly via `gh issue edit` — no driver needed |

## Idempotency caveat

Neither driver shape is currently idempotent. Re-running a fresh-create driver against a project that already has the issues will create duplicates. The scope-creep solution would be a `create_child_once` helper that skips when a child with the same title already exists under the same parent — file as a follow-up if you find yourself wanting to safely re-run an additions driver.
