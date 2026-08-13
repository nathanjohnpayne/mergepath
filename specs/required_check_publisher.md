---
spec_id: required_check_publisher
---

# Required Check Publisher

`.github/workflows/required-check-publisher.yml` is the single writer of the **synthetic** (Checks-API) lineage for the three script-backed required contexts — `Merge clearance gate`, `Codex P1 unresolved threads`, and `CodeRabbit unresolved blocking findings`. It exists because those contexts previously had two producers per workflow file, both reporting as `github-actions` and neither able to retire the other's entries, which stranded fully-cleared PRs behind stale verdicts (#835, #828, #842) and forced empty commits as the only universal escape. This spec states the publisher's behavioral contract; `scripts/ci/check_required_check_publisher` pins exactly what is stated here, and Test 25 in `tests/test_merge_clearance_gate.sh` proves each pin rejects the shape that loses it. One source of truth: a change to the publisher's behavior belongs in this file, in the fence, and in the fixtures, in the same diff.

Nothing here describes the **native** lineage — the check run Actions materialises for each job. That lineage is retained deliberately and is out of the publisher's reach; see *Two lineages*.

## Two lineages, and why the native one is retained

Each required context has two independent producers, and under the resolution rule this repo has measured four times, the newest run of **each** must be green. The job-native lineage puts one suite per workflow run, with runs superseding each other across suites; the Checks-API lineage puts one shared suite per head, where the newest POST wins.

"Single producer" therefore means **single owner of the synthetic lineage**, never the deletion of a natively-named job. Deleting the job named for a context does not merge the lineages — it deletes one, leaving a required context whose only producer is a workflow. If that workflow is absent from the default branch, renamed, disabled, or its `workflow_run` delivery drops, the context has no producer at all and every PR in the repo blocks forever with no partial degradation to warn anyone. The natively-named jobs in the three gate workflows keep their names and keep computing their own verdicts; what they lose (in #845 PR 4) is the ability to write the Checks API.

## Trust model

The publisher's definition always comes from the **default branch**: `workflow_run`, `schedule`, and `repository_dispatch` all execute the default-branch copy. A pull request therefore cannot edit the workflow that evaluates it, which is the closure for the P1a exposure — inline `gh api` calls and a `checks: write` grant sitting in PR-authored YAML.

`workflow_dispatch` is **absent by design**, not merely unused. A manual dispatch executes the *selected ref's* copy of the file, so a PR branch could be run with `checks: write` — P1a through the manual path. The operator break-glass is the `required-check-republish` `repository_dispatch`, which is PAT-gated and always runs the default-branch definition.

`checks: write` is granted at **job** scope, never at workflow scope. A workflow-level grant hands the scope to every future job added to the file, which is how the fleet's four-workflow exposure set grew in the first place.

## Trigger model

One parent, not three: `workflow_run` observes only `Merge Clearance Gate`, whose trigger set is a measured strict superset of both siblings' (it adds `labeled`/`unlabeled` and `repository_dispatch`). A single delivery per PR event therefore carries every refresh signal, and the per-event fan-in stays at one pass instead of three. `workflow_run` matches on the parent's exact top-level `name:`, so a rename on either side silently orphans every event-driven publish — the failure mode is a workflow that never fires, which is indistinguishable from one that fires and finds nothing to do. The fence reads the expected name out of the parent file rather than carrying a copy of the string. Reading it there means a *missing* name must be as loud as a mismatched one: a parent that declares no top-level `name:` is named by Actions after its path, so the publisher's `workflows:` entry matches nothing and every event-driven publish is orphaned. The fence therefore tracks whether the parent file loaded separately from the name that load yielded, because both an unreadable parent and a nameless one produce no name, and treating them alike lets a one-line deletion disarm the assertion instead of tripping it.

The three activity types have distinct roles. `requested` fires at parent-run creation, before its jobs execute, so holds land within seconds of the PR event. `in_progress` is the **rerun** cue: a rerun re-uses the run, so `requested` never re-fires and the re-evaluation window would otherwise carry no pending cover. `completed` is the publish cue. The publisher never reads `workflow_run.conclusion` — deliveries drop and that field can be null upstream, and the verdict must not depend on how the parent finished; every pass re-evaluates from scratch.

The publisher carries **no schedule of its own** until #845 PR 4. The parent's `*/15` cron already reaches it through the `workflow_run` chain (a schedule-parent delivery whose head matches no open PR degrades to a full-coverage pass), so an own cron would run a second full-fleet pass every interval for nothing. PR 4 re-adds it in the same diff that deletes the three gate workflows' schedules, so every stage keeps exactly one cron path.

Chain depth is capped at three levels by GitHub and the publisher sits at level 2. A third workflow observing the publisher would be silently truncated rather than rejected, so nothing may name it in a `workflow_run.workflows:` array. That scan matches siblings against the publisher's own top-level `name:`, which makes an unnamed publisher the same hazard in mirror image — Actions substitutes the path, which a sibling can still observe, while the scan has nothing to match and reports nothing. The publisher is therefore required to declare a usable name, which keeps the assertion armed at no cost.

## Head binding

Every published `head_sha` binds to `github.event.workflow_run.head_sha` or to a shell variable derived from the open-PR list read. **Never `github.sha`**: on a `workflow_run` run that is the default branch's last commit, so one such binding puts all three contexts on a commit branch protection never consults — absent on every PR head, fleet-wide, permanently, with no partial degradation. The fence expresses this as an allowlist over every binding **site** — every argument that binds the Checks-API `head_sha` field, under any gh-CLI field-flag spelling (`-f`, `-F`, `--field`, `--raw-field`, quoted whole-argument or quoted value) — rather than as a denylist of wrong spellings, because `github.sha` → `base.sha` → literal-prefixed strings cannot be enumerated. The number of binding sites is pinned alongside the allowlist, so a new POST cannot arrive without its head binding being read. What the fence does **not** assert is the value an allowlisted variable holds when the POST runs: reassigning one immediately before the POST rebinds it without touching any binding site. That residual is a dataflow property, not a spelling, and closing it would require interpreting the shell rather than reading it.

Head-to-PR resolution comes from the open-PR list, exhaustively paginated, and never from `workflow_run.pull_requests`, which is empty for fork PRs. A capped list would silently exempt every head beyond the cap from both phases.

## Phase ordering

**Phase 1 (`open`)** POSTs an `in_progress` entry per context on the event head, as the **first, unconditional** step of the job. That ordering is the whole fail-closed argument: everything after that line — checkout failure, head resolution failure, a gate script crash, runner death, a dropped `completed` delivery — leaves the context *pending* rather than leaving a stale verdict standing. A pending required entry blocks (measured: `isRequired: true`, `mergeStateStatus: BLOCKED`). A step-level `if:` on the publisher skips exactly when the run it guards is the one that needed to retire a stale verdict.

`open` is deliberately **groupless**. Queued behind `publish`, its hold would wait behind a mid-flight stale pass — reversing the write order but leaving a post-green window open until the queued job reaches a runner. It also skips when the parent run has already completed, because a hold opened after the completed pass has no future event to retire it.

**Phase 2 (`publish`)** POSTs a fresh `completed` run per context rather than PATCHing phase 1's. The phases are separate workflow runs, and every Checks-API POST for one head coalesces into one shared suite where the newest run wins, so no identifier has to cross the run boundary.

## Ordering and the stale-write defense

`publish` carries **one fixed concurrency queue** (`rcp-publish`, `cancel-in-progress: false`), not a per-head group. A per-head group leaves the sweep and dispatch paths outside the serialization entirely, so an older evaluation on one of those paths could read state before a transition and POST after a newer evaluation, restoring a stale verdict. The queue is safe on this file and was not safe on the gate workflows, and the difference is measured rather than argued: when a third member queues, GitHub cancels the *pending* member and materialises that run's native check. On a gate workflow that check is named for a required context and concludes `cancelled`, which is neither SUCCESS nor SKIPPED nor NEUTRAL and cannot be retired through the API slot. Here it is named `publish`, which nothing requires. **No job whose name is a required context may ever carry a `concurrency:` block.**

Cancellation is **coalescing, not loss**: every pass evaluates every open PR (event head, or dispatch-named PR, first), so whichever member survives subsumes the work of every cancelled one.

The queue orders arrivals but cannot order the read-to-write gap inside a pass, and `POST /check-runs` has no conditional write, no If-Match and no CAS. So immediately before each POST the pass performs a per-(head, context) **freshness read** and withholds any verdict whose slot carries a pending entry started at or after the pass began. Both sides of that comparison come from the **server** clock — the pass's own `run_started_at`, and the entry's server-assigned `started_at` — because runner skew could otherwise hide a newer hold. Ties withhold: a genuinely newer hold in the boundary second must win, and the tie cannot be this pass's own phase-1 hold, which predates the pass by the parent's runtime. The pass subtracts holds it opened itself by id, since identity distinguishes self from newer where a timestamp cannot. A **failed** freshness lookup withholds too — unknown freshness is possibly-stale. The residual is the single read-to-POST gap, which is the floor without conditional writes.

Immediately before the POST the pass also **revalidates the PR's live head**. The gate scripts evaluate live PR state, so a force-push mid-pass would attach a fresh-state verdict to the captured SHA — reusable if the branch ever returns to it. On drift it publishes red pinned to the bound head; the new head gets its own evaluation from its own events.

Both reads are worthless after the POST, so their **position** is part of the contract and not an implementation detail.

## Verdict mapping and failure directions

Each context's gate script maps rc 0 to `success`, rc 1 to `failure`, and every other rc to `failure` with an infra/config title — config, usage and infra exits publish a red rather than skipping, because skipping would leave the previous verdict standing on the very refresh path the publisher owns. An rc 0 that lacks the script's own verdict sentinel (where it has one) publishes red: a success that did not come from the verdict path is a stubbed or truncated script, not a green.

Exactly **one** place in the file may assign `conclusion="success"`. Every other failure direction here is an availability cost with a known remedy; an unearned green is the only one that merges something, so the number of code paths able to produce one is pinned at one and any new green-producing path is a conspicuous diff.

Two postures are red-by-construction. A head carried by **more than one open PR** publishes red on all three contexts, once: one commit slot cannot honestly carry two PRs' differing policy state, so red-until-disambiguated is the only verdict wrong for neither. A **superseded head** — an event head matching no open PR — has any pending entry phase 1 opened on it *closed* red rather than abandoned: a red pinned to a superseded head is invisible to branch protection, while an abandoned `in_progress` reads as a hang.

Everything else fails toward *pending*. A stuck pending is an availability cost with a known remedy (the dispatch in seconds, the cron within one interval); a stale green is a correctness hole.

## Staging

Stage A ships the publisher under **shadow** context names, which are not in branch protection, so nothing it publishes can affect a merge while the trigger shape, head binding, PR resolution and rc mapping are rehearsed against production traffic. The three `env:` values are the single flip point for the live names. The fence is name-agnostic by construction: it pins the *shape*, so it does not have to change at the flip.

The publisher's introducing PR cannot exercise it — a `workflow_run` workflow runs the default branch's definition — which is why the fence, the fixtures and this specification substitute for in-vivo validation on the introducing diff, and why the shadow stage exists to answer the remaining live questions afterwards.

## Propagation posture

The publisher travels as a manifest `canonical` entry requiring the parent workflow and the three gate scripts; the fence travels in the `scripts/ci/` kit and additionally requires the publisher, so a wave cannot ship the fence without its subject. A consumer that has the fence and not yet the workflow is mid-rollout, not broken: the fence SKIPs when its subject and the hub marker are both absent, and fails loudly only when the subject is absent on the hub itself, where that means the single writer was deleted.
