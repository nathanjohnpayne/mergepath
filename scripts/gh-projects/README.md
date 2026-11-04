# scripts/gh-projects — multi-phase GitHub Project driver kit

Reusable helpers for tracking larger, multi-phase initiatives in [GitHub Projects v2](https://docs.github.com/en/issues/planning-and-tracking-with-projects). Each phase gets a parent issue with native [sub-issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-sub-issues) links to the child tasks that make it up, and every issue is added to a Project board whose swimlanes are advanced as work moves.

The MUX Video Integration initiative ([Project #5](https://github.com/users/nathanjohnpayne/projects/5)) is the reference implementation — see [`examples/mux-video-integration/`](./examples/mux-video-integration/).

## What this gives you

- **`lib.sh`** — a sourceable library of functions: `create_parent`, `create_child`, `link_sub_issue`, `add_to_project`, `set_project_readme`, `ensure_label`, `prep_body` (placeholder substitution). Source it from a short per-initiative driver script.
- **`move-item.sh`** — a standalone CLI that moves one issue to a named Status swimlane by discovering the project's field/option IDs at runtime. Works against any Project v2 with a `Status` single-select field. One GraphQL query per move, whatever the board's size.
- **`read-route.sh`** — a read-only CLI that prints an issue's model/effort route from its `mergepath-route` marker, over one REST call, so it works where GraphQL and the boards are unreachable (a Claude cloud session). See [Read an issue's route](#read-an-issues-route).
- **`backfill-route-markers.sh`** — a one-time, local-session CLI that copies each per-repo board's four routing fields into the issues' `mergepath-route` markers, with a dry run, a per-repository report, and conflicts and partial routes reported instead of written. See [Backfill route markers from the boards](#backfill-route-markers-from-the-boards).
- **`examples/mux-video-integration/`** — a complete worked example: the driver script, body-file templates, and the output that produced issues #210–#230.

## Prerequisites

- `gh` installed (via Homebrew on this machine).
- An author classic PAT with `project` for user-owned Projects v2, plus `public_repo` for public repository operations; use `repo` only when private repository access is needed. See GitHub’s [Projects API authentication](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects) and [scope definitions](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps). These helpers verify that `GH_TOKEN` resolves to `nathanjohnpayne` before mutating issues or Project v2 items.
- Local sessions run [scripts/op-preflight.sh](../op-preflight.sh) in review mode once to cache credentials. Cloud sessions use provisioned credentials and the capability probe in [Cloud Agent Environments](../../docs/agents/cloud-environments.md), without invoking local 1Password preflight. If the session cannot perform the GraphQL-backed Project operations, hand them to a capable local session under that guide.
- The target Project v2 board must have a `Status` single-select field with the canonical options `Backlog`, `Ready`, `In progress`, `In review`, `Done`. `move-item.sh` discovers the field by that exact name. GitHub's default board template does not provide these options, so edit the board's `Status` field by hand to have exactly these five. The set is the one mergepath's new-repo bootstrap gives the board it provisions with a new repo ([`scripts/bootstrap/board-and-summary.sh`](https://github.com/nathanjohnpayne/mergepath/blob/main/scripts/bootstrap/board-and-summary.sh); hub-only, so the link is absolute). That bootstrap scaffolds a whole repo, so it is not a way to create a board for an initiative.

```bash
# Local session setup — preflight populates OP_PREFLIGHT_AUTHOR_PAT.
# Select the running agent; claude is this example's local agent.
eval "$(scripts/op-preflight.sh --agent claude --mode review)"
```

For a local session, select the cached `OP_PREFLIGHT_AUTHOR_PAT` from [REVIEW_POLICY.md § PAT lookup table](../../REVIEW_POLICY.md#pat-lookup-table) after preflight. For a cloud session, provision `OP_PREFLIGHT_AUTHOR_PAT` with the minimum classic PAT scopes above and follow [Cloud Agent Environments](../../docs/agents/cloud-environments.md); do not run local 1Password preflight there. The capability probe tests GraphQL transport, not Project permissions or mutations. Exporting a token does not remove a transport ceiling, so Claude cloud still hands these operations to a capable session.

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
- **Order within `Ready` is set by hand.** Moving an item to `Ready` says it can be started, not that it should be next, and no workflow orders the column. Whoever moves an item to `Ready` also places it by priority tier, then dependency order, so the top item that is not a parent is the next to take: see [Shared Agent Operating Rules § Ordering the Ready column](../../docs/agents/shared-operating-rules.md#ordering-the-ready-column).
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

# Parent
P_URL=$(create_parent "Phase 1: …" "$SCRIPT_DIR/phase-1/parent.md" "myproj,agent-action")
P_NUM="${P_URL##*/}"

# Child — substitute __PARENT_NUM__ in the body file first.
F=$(prep_body "$SCRIPT_DIR/phase-1/c1.md" "$P_NUM")
read C1_URL C1_NUM _ <<<"$(create_child "Do the first thing" "$F" "myproj,agent-action" "$P_NUM")"
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

### Read an issue's route

```bash
scripts/gh-projects/read-route.sh 2848 --repo nathanjohnpayne/mergepath
# anthropic=opus-5.5/high openai=gpt-6.1-sol/high
```

Reads `GET repos/OWNER/REPO/issues/N` only (no GraphQL, no Projects v2), so it works from a Claude cloud session whose GitHub proxy serves only `repos/<owner>/<repo>/...`. It needs no project PAT and does not source `lib.sh`; it uses the read auth `gh` already has. The repository is `--repo`, else `$REPO`, else the `origin` remote. The marker contract is [Shared Agent Operating Rules § The route marker](../../docs/agents/shared-operating-rules.md#the-route-marker); a session honors the route as that file's *Starting an issue* section says.

Success prints one line, `anthropic=<model>/<effort> openai=<model>/<effort>`, on stdout. Every failure prints one line on stderr naming its case, nothing on stdout, and exits with the case's own code:

| Exit | Case | Meaning |
|---|---|---|
| 0 | found | A valid marker; the route is on stdout. |
| 1 | `read-failed` | The issue could not be read. |
| 2 | usage | Bad arguments or no resolvable repository. |
| 3 | `no-marker` | No marker; the caller keeps the session's model and effort, unless the issue carries `decision-needed`, in which case it is not ready to start. |
| 4 | `malformed` / `out-of-vocabulary` | A marker line breaks the format, or a model or effort is not in the vocabulary. |
| 5 | `duplicated` | More than one marker line. |

The parse is strict about candidates and ignores everything else. A candidate is a line outside a fenced code block that begins with `<!--` and contains `mergepath-route`. A prose mention, an inline-code example or a fenced example is not a candidate, so quoting the marker in documentation neither breaks nor duplicates a real one. A candidate must be exactly the canonical marker, with single spaces and `anthropic` first, or it fails closed as `malformed`; a half-typed comment such as `<!--mergepath-route ...` or one missing its `-->` is still a candidate. One trailing CR is tolerated. Two or more candidates are `duplicated`. `read-route.sh --vocabulary` prints the accepted values; `check_gh_projects_read_route` compares them with the rules table so the two cannot drift. `--body-file PATH` parses a body the caller already holds instead of reading the issue, with the same verdicts and exit codes and no `gh` call; the backfill below uses it so there is one marker parser.

### Backfill route markers from the boards

`backfill-route-markers.sh` moves routing data off the boards and onto the issues: for every per-repo board of the owner (default `nathanjohnpayne`, all of its Projects v2 boards unless `--board N` names some), it reads every item over REST with an explicit `fields[]=<id>` for each of the four routing fields (`Anthropic model`, `Anthropic effort`, `OpenAI model`, `OpenAI effort`), maps each item to its repository by the item's own `content.repository`, and appends the [route marker](../../docs/agents/shared-operating-rules.md#the-route-marker) to each issue, open or closed, whose four fields are set. It needs a local session: a Claude cloud session cannot read the boards.

```bash
eval "$(scripts/op-preflight.sh --agent claude --mode review)"
# Plan first: GET calls only, the full plan and the per-repository report.
GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" \
  scripts/gh-projects/backfill-route-markers.sh --dry-run --json backfill-plan.json
# Then write, one issue at a time, through scripts/gh-as-author.sh.
GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" \
  scripts/gh-projects/backfill-route-markers.sh --live --json backfill-run.json
```

One of `--dry-run` or `--live` is required, so a bare invocation never writes. Option names map to marker values as the contract says (lowercased, spaces to `-`), checked against `read-route.sh --vocabulary`. Each issue item with any routing field set lands in one category:

| Category | Meaning |
|---|---|
| `would-write` / `written` | All four fields are set and in the vocabulary and the body has no marker; the marker is appended on its own line after a blank line. |
| `already-present` | The body's marker equals the board's route. A second run finds every written issue here and writes nothing. |
| `conflict` | The body's marker differs (`different-marker`), is malformed or out of the vocabulary (`malformed-marker`), or is duplicated (`duplicated-marker`); or two boards hold different values for the same issue (`board-disagreement`). Never overwritten. |
| `partial` | A model without its effort, the reverse, or only one provider set. The contract requires both halves, so nothing is guessed or written. |
| `out-of-vocabulary` | A board option that maps outside the vocabulary. Never written. |
| `unwritable` | The appended marker would not parse as the route (for example, the body ends inside an unclosed code fence). |
| `skipped` | Pull requests, draft items, `size:L` parents (by label), routed issues in an archived repository (`archived-repository`: read-only, and out of scope for fleet work; each repository's `archived` flag is read once with `GET repos/OWNER/REPO` and cached), and items whose issue content is unavailable. |

Issues with no routing field set are counted as `no-route` and not listed. The report gives, per repository, the items read and the count in each category, with skips broken down by reason; `--json FILE` writes the same report and every item's result as JSON. Board-level notes name a board that lacks a routing field (it is skipped) and any board option outside the vocabulary.

In `--live`, each write reads the issue again immediately before it and re-judges that fresh body (a marker added since the listing is reported, not overwritten), writes through `scripts/gh-as-author.sh -- gh issue edit N --repo OWNER/REPO --body-file F`, and reads the issue back, requiring the stored body to equal the written file byte for byte. A failed write or a mismatched readback stops the run. Writes are paced by `--pace` seconds (default 10, about 360 an hour, inside GitHub's limit of 500 content-creating requests an hour), and the run stops before a write when the REST core or GraphQL remaining budget is under `--budget-floor` (default 1000; `gh issue edit` spends GraphQL points). `--max-writes N` caps a run, for a first small batch. GitHub's issue update has no compare-and-swap, so an edit made to an issue body between the fresh read and the write would be overwritten. The window is one round trip, but do not edit fleet issue bodies while a `--live` run is going; a suspected lost edit can be recovered from the issue's edit history.

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
