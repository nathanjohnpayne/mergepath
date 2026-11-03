# Shared Agent Operating Rules

> Canonical source: `mergepath/docs/agents/shared-operating-rules.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy. A change here reaches every repo through a propagation wave, so every sentence must be true in all of them.

This file is the **shared core** of the agent operating rules: the rules that hold, unchanged, in every repository that receives it. It carries no repo-specific content — no tech stack, no architecture, no build or deploy specifics, no references to tooling a receiving repo does not have.

Each repository keeps its own `docs/agents/operating-rules.md` as the **local overlay**: reading order, conflict resolution, architecture and coding conventions, log access, and anything else that is true only there. Read this file first, then the local overlay. Where the two overlap, this file is the baseline; the overlay may add repo-specific detail on top of it but should not contradict it. If a rule in the overlay turns out to be true everywhere, it belongs here instead — raise it at the canonical source rather than copying it between repos.

Issue references below use the fully-qualified `nathanjohnpayne/mergepath#NN` form on purpose. These rules were decided in the mergepath hub, and a bare `#NN` in a propagated file silently resolves against whichever repository you are reading it in.

## Always paginate PR comment / review / check-run list reads

Any `gh api` list read against a PR's comments, reviews, or check-runs MUST use `--paginate` (or, for a GraphQL connection, a cursor loop). This is not optional past round 1 of a Phase 4a review loop. `gh api` without `--paginate` fetches exactly one page --- 30 items by default, at most 100 with `per_page=100` --- and returns cleanly with no error or warning that more data exists. On a long-lived PR that has been through many review rounds, the current data routinely sits past that boundary, so an unpaginated read silently returns a stale or empty result that reads as "no new activity" or "no findings" when the opposite is true. This has repeatedly produced false all-clear conclusions and can silently defeat a merge gate (nathanjohnpayne/mergepath#691).

This applies to every hand-rolled, mid-session investigative query, not just the shipped helper scripts. An agent manually inspecting a PR's live state is the common case, and it is exactly the query that skips the paginated helpers. The endpoints that truncate, and the correct form:

- Inline diff comments --- `gh api --paginate "repos/OWNER/REPO/pulls/PR/comments"`. By round 4+ a PR easily exceeds 30 of these (findings, plus replies, plus resolve-tool tag-replies), so the newest findings land on page 2 and an unpaginated read returns nothing for them.
- PR-level (issue) comments --- `gh api --paginate "repos/OWNER/REPO/issues/PR/comments"`. This is where a Codex clean verdict lands.
- Review objects --- `gh api --paginate "repos/OWNER/REPO/pulls/PR/reviews"`. This is where a Codex findings round lands.
- Check-runs / commit statuses --- `gh api --paginate "repos/OWNER/REPO/commits/SHA/check-runs"` and `.../statuses`. A single head commit can accumulate 100+ check-runs from repeated scheduled-sweep re-evaluations (194 observed on nathanjohnpayne/mergepath#687), so even `per_page=100` without `--paginate` silently drops a live failure onto page 2.

`gh pr view --json comments|reviews|statusCheckRollup` has the same trap and CANNOT be fixed with `--paginate`: the `--json` GraphQL shape caps each connection at the first 100 entries and strips the `pageInfo` you would need even to detect the truncation. For any connection that can exceed 100 (check-runs above all), read the REST endpoint with `gh api --paginate`, or walk the GraphQL connection with a Relay cursor loop --- see the `statusCheckRollup` cursor loops in `scripts/codex-review-check.sh`. A single-item read (`repos/.../issues/comments/ID`, `repos/.../pulls/PR`) is not a list and does not need `--paginate`.

The shipped gate scripts already bake this in --- `fetch_api_array` wraps `gh api --paginate` for the REST arrays, and the GraphQL reads use cursor loops --- so this rule is aimed at the ad-hoc queries those helpers do not cover. When in doubt, add `--paginate`: it is a no-op on a short list and the only safe default on a long one.

## GitHub REST and GraphQL rate limits are separate budgets

GitHub meters REST and GraphQL separately. A user token gets 5,000 REST requests per hour and, independently, 5,000 GraphQL points per hour; exhausting one leaves the other intact. When a GraphQL call fails on the primary rate limit, switch that work to the equivalent REST endpoints and keep going, rather than waiting for the GraphQL window to reset.

Several `gh` commands are GraphQL under the hood and spend that budget: `gh pr view --json`, `gh pr list`, `gh issue view --json`, `gh issue list`, `gh project ...` and `gh api graphql`. Their REST equivalents are plain `gh api` paths, for example `repos/OWNER/REPO/pulls/N`, `.../pulls/N/reviews`, `.../pulls/N/comments`, `.../issues/N`, `.../issues/N/comments` and `.../commits/SHA/check-runs`, each with `--paginate` under the rule above.

Board moves are the exception: defer them until `resources.graphql.reset` rather than switching. GitHub does publish Projects (v2) REST endpoints, but the board helpers under `scripts/gh-projects/` are GraphQL-only and verify the author identity before every write, which a raw `gh api` call skips. The user-owned board endpoint also rejects fine-grained PATs. Never report a board move as done if it has not happened.

Classify the failure by its message, not by its HTTP status. A GraphQL error can arrive as HTTP 200 with an `errors` entry as well as a 403 or 429. Check for a secondary limit first, because it can arrive with the primary budget also at zero:

1. **Secondary (abuse) limit:** the message mentions a secondary rate limit, or the response carries `Retry-After`. It applies across both APIs, so switching to REST just hits it again. Back off instead: wait for `Retry-After` when present; otherwise, if `x-ratelimit-remaining` is 0, wait until `x-ratelimit-reset`; otherwise wait at least one minute. Lengthen the wait on each repeat. Most `gh` commands hide the response headers (`gh api --include` shows them); when you cannot see them, use the one-minute floor and lengthen it. Do not call `gh api rate_limit` until the wait is over: the probe itself counts against the secondary limit, and it can read healthy during one.
2. **Primary limit:** otherwise, when the message says `API rate limit exceeded`, or `gh api rate_limit --jq '.resources | {core, graphql}'` shows that API's `remaining` at 0. Switching APIs works.

GitHub App installation tokens (CI workflows) have their own separate budget.

## Background jobs and expected duration

A backgrounded command must have an expected duration stated when it is launched, and must be checked against that expectation. Never report "still running" as a status without comparing elapsed time to the expectation. A completion notification fires only on completion; a hung job produces no notification and no error — it is indistinguishable from a job legitimately working. Passive waiting has no failure detection by default.

Corollaries:

- Prefer a self-terminating command — put `timeout N` inside it — so a hang dies on its own rather than depending on the agent noticing.
- A job with no obvious duration still has a bound: provider-poll helpers carry their own `max_wait_seconds` / `review_timeout_seconds`, so quote that as the expectation.
- Investigate any job that exceeds roughly 3× its expected duration; do not report "still running" as though that were a normal status.
- "It is still going" is not a status. "It is at 4 minutes against an expected 2" is.

## 1Password CLI authentication failures

If any `op` command (`op read`, `op inject`, `op run`, `op document get`, or any script that wraps them) fails with a sign-in or authentication error — including but not limited to:

- `[ERROR] ... not currently signed in`
- `session expired`
- `biometric unlock ... timed out`
- `authorization prompt dismissed`
- `error initializing client: authorization`

Then follow this procedure:

1. **Stop immediately.** Do not retry the command, do not attempt workarounds (manual token entry, environment variable overrides, fallback credential paths, or skipping the credential step).
2. **Check if preflight was run.** If `OP_PREFLIGHT_DONE` is not set, suggest running the preflight script:
   > "1Password auth failed. Would you like to run credential preflight to cache all credentials at once? `eval \"$(scripts/op-preflight.sh --agent {your-agent} --mode review)\"`"
   >
   > (`--mode deploy` is not an approved deployment setup: a cache hit can export review PATs, and evaluating its output exposes credentials to the caller's whole shell. Do not use `--mode all` for builds or deployment. Wait for separately reviewed post-build tooling that selects only deploy credentials and scopes them to one consuming subprocess after artifact verification. See [Build and deploy isolation](#build-and-deploy-isolation). The default is `review` per nathanjohnpayne/mergepath#282.)
3. **If preflight was already run** but credentials expired (rare — only after 1Password locks or the 12-hour hard limit), prompt the human and suggest re-running preflight:
   > "Preflight credentials appear to have expired. Could you re-run preflight when you're back? I need to resume the review."
4. **Wait for the human to confirm** they are present and ready before re-running preflight (not individual `op read` commands).
5. After confirmation, re-run preflight. If it fails again, report the full error output and wait — do not loop.

This rule applies only to 1Password CLI sign-in and authentication errors. Other `op` failures (wrong item ID, missing field, network errors, vault permission errors) should be diagnosed and resolved normally.

## Cloud agent sessions

A Claude Code cloud session or a Codex cloud task has no 1Password and no gh keyring, and the Claude cloud GitHub proxy's ambient token writes as `claude[bot]`, not as you. Before writing to GitHub from one, follow [Cloud Agent Environments](cloud-environments.md): provision the dedicated author and reviewer PATs it names, run `scripts/agent-capability-probe.sh` to learn what the session can do, and hand anything it cannot do (GraphQL-only helpers, multi-branch or cross-repo work) to a local session or CI. On a cloud surface the write wrappers run the guarded `gh pr` / `gh issue` verbs as REST calls and read each byline back, because those subcommands are GraphQL and the Claude cloud proxy refuses them; `gh pr merge` stays refused there, because the merge gates read GraphQL, so a merge is parked with a handback for a local session.

## Secret handling

These three rules hold in every repository, whatever it deploys and however it deploys it. The repo-specific half — which credential a deploy resolves, which vault item holds it, which command runs the deploy — belongs in that repo's own `docs/agents/deployment-process.md`, not here.

1. **Never move a secret through a human.** Do not ask anyone to paste a raw credential, token, or key into chat, an issue, or a PR comment, and never print a resolved secret value in logs or command output. A credential manager hands the value to the tool that needs it; it does not pass through a transcript.
2. **No long-lived keys by convenience.** Do not introduce long-lived service-account keys or on-disk deploy keys into repo docs, scripts, or secret stores unless the project explicitly requires them and a human has approved that requirement. Short-lived, manager-resolved credentials are the default form.
3. **Do not downgrade a repo's auth model unilaterally.** Where a repository's deploy or CI auth is 1Password-backed — the fleet default — switching it back to routine browser login, an interactive CLI login, or an unmanaged on-disk key needs explicit human approval. Reaching for the downgrade because a credential lookup failed is the specific move this rule forbids; see the pause-and-prompt procedure above.

### Build and deploy isolation

Production artifact builds run on a separate CI runner or account before deployment credentials are acquired. Repository build code and dependencies must have no deployment credentials, author/reviewer PATs, or filesystem access to the operator's credential-manager files and preflight caches, including through host mounts. Unsetting variables in a same-user shell or restricting cache-file permissions does not establish this isolation.

Publish an immutable artifact with a digest and attestation bound to the intended repository and full source revision. Trusted post-build tooling verifies that binding and artifact integrity before acquiring deployment credentials, then deploys the verified artifact without rebuilding or executing the candidate checkout. Each repository owns its artifact format, verification implementation and platform-specific deploy adapter.

Acquire each deployment credential only after successful build and artifact verification, and inject it only into the subprocess that consumes it. Author/reviewer PATs are not deployment credentials and must not be injected into build or deploy subprocesses. Credential preflight belongs in trusted post-build tooling; review/all-mode credential loading is not a build or deployment step. Retain the repository's approved authentication model and fail closed on failed build, verification or credential acquisition.

Before marking a consumer migrated, exercise its real build and use fake credentials to prove both environment absence and denied filesystem/cache reachability. Verify credential acquisition occurs after build completion and each credential reaches only its intended subprocess. Shared guidance alone is not evidence that a consumer's adapter satisfies this boundary.

## Mutating MCP tool calls need explicit confirmation

A connected MCP server routinely exposes write and delete operations against live infrastructure — DNS zones, object storage, databases, deployed services — under the same account that serves production. These calls are unlike every other change an agent makes: they land in no diff, no branch protection gates them, and no reviewer sees them before they take effect. There is no PR to decline and frequently no undo.

An agent MUST therefore obtain explicit human confirmation before issuing any MCP tool call that creates, modifies, or deletes a live resource. Read-only calls need no confirmation and should be used freely — investigating thoroughly before proposing a change is the behavior this rule is meant to encourage, not restrain.

The boundary is the **effect of the call**, not the name of the tool:

- **No confirmation needed** — listing, getting, searching, querying, and reading logs, metrics, or audit history.
- **Confirm first** — anything that creates, updates, or deletes, plus anything whose effect cannot be established as read-only. Transport method alone does not settle this: a read-only query issued over `POST` — a GraphQL or search endpoint — needs no confirmation, while a `POST` that provisions a resource does. Where the effect is genuinely indeterminate, treat it as mutating and ask.

Two failure modes this rule closes:

1. **A generic executor hides its blast radius behind one schema.** Where a single tool accepts an arbitrary method and path, one innocuous-looking call shape serves both a harmless read and an account-wide delete, and neither the tool name nor its schema distinguishes them. Confirmation must therefore key on the request the agent is about to issue, never on the tool's name or its usual use.
2. **Plausible intent is not authorization.** A task that implies infrastructure change — "set up the new domain" — authorizes proposing that change, not performing it. Intent inferred from surrounding work is the weakest possible warrant for an irreversible action.

When asking, state the exact operation, the target resource, and **the account or scope being acted on**. A single credential commonly covers an entire production account, so the scope is the part a human most needs to check, and it is the part an agent is least likely to have chosen deliberately.

Nothing here narrows the stricter rules already in force above: a mutating call that would also move a secret through a human, or that would downgrade a repository's auth model, stays forbidden regardless of confirmation. See nathanjohnpayne/mergepath#908 for the capability review that produced this rule.

## Bug fix escalation policy

These rules prevent agents from repeatedly patching symptoms of a structural defect. They are derived from a real failure where one agent made six unsuccessful fix attempts on the same issue because every attempt preserved the same broken architectural assumption.

### Two-strike audit rule

If an agent has made **two or more failed fix attempts** on the same issue (i.e., two merged PRs that were each intended to resolve the issue but did not), the next attempt **must** begin with a written audit of all prior attempts before any code changes. The audit must:

1. List every prior PR that targeted this issue.
2. For each, state what it changed and why it was insufficient.
3. Identify the **shared assumption** across all prior attempts.
4. Propose a fix that addresses that assumption directly, not another symptom within it.

The audit should appear in the PR description under a section titled "Audit Of Prior Failed Fixes."

If the agent cannot identify a shared assumption, it must flag the issue to the human rather than filing another incremental fix.

### Agent rotation for retries

When an agent's fixes are not resolving an issue after two attempts, **hand the problem to a different agent**. A fresh agent without the prior context is less likely to inherit implicit assumptions about the system's architecture. The new agent should be given:

- The issue description
- Links to all prior fix PRs
- No additional narrative framing (let it form its own model)

This is a recommendation, not a hard rule. The human decides when to rotate.

### Serialization layer review requirement

When reviewing a PR that introduces or modifies a **serialization or deserialization layer**—any code that converts structured data to a flat format (strings, JSON, markdown, plain text) and back—the reviewer must verify:

1. **Losslessness:** Does the round-trip preserve all semantically meaningful information? If not, what is discarded?
2. **Consumer parity:** Do all consumers of the serialized format produce identical output from identical input? If there are multiple parsers/renderers, are they tested for equivalence?
3. **Necessity:** Is the intermediate format required, or can consumers read the structured format directly?

If the round-trip is lossy, the reviewer must flag the information loss as a design risk and require either:
- An explicit justification for why the loss is acceptable, or
- A plan to eliminate the intermediate format

## Daily feedback rollup — the deferred-and-forgotten class

Every repository that receives these rules runs a daily rollup that catches review feedback which was closed out but never actually addressed. Agents should know when it fires and which issue to triage, so the same items are not chased twice.

**`.github/workflows/daily-feedback-rollup.yml`** runs daily at `55 23 * * *` UTC. It scans yesterday's MERGED PRs and surfaces bot review threads that were RESOLVED **without** an associated fix commit or substantive reply. The output splits into two clearly-labeled tracks (substantive / polish) so the high-severity stream stays high-signal even on days with a lot of nit volume.

This catches the class that motivated nathanjohnpayne/mergepath#234 / nathanjohnpayne/mergepath#286 / nathanjohnpayne/mergepath#287: a CodeRabbit Major or Codex P2 the agent resolved as "non-blocking, will fix in a follow-up" — and then nobody wrote down. Captured while the resolving agent's context is still hot.

See `scripts/daily-feedback-rollup.sh` (workhorse) + `scripts/lib/daily-feedback-rollup-helpers.sh` (classifier helpers) + `scripts/resolve-pr-threads.sh --auto-resolve-bots` (the upstream emit-side that tags each resolve with `[mergepath-resolve:<class>]` so the classifier prefers agent-recorded rationale over heuristics).

Which issue to act on:

- Routine end-of-day triage → the substantive `deferred-feedback-rollup YYYY-MM-DD` issue from the daily cron. Items aged 0-7 days, context fresh.
- Polish/nit batch triage → the `polish-feedback-rollup YYYY-MM-DD` issue from the same daily cron. Lower urgency; can batch across multiple days.

The rollup is per-repo: the workflow runs in the repository it is installed in and opens its issues there. Cross-repo aggregation is an explicit non-goal; the per-repo design preserves operator focus on the repo whose context they are currently in.

## End of session: no pull request left on an unanswered verdict

Measured in the hub (nathanjohnpayne/mergepath#2165): across the fourteen most recently merged multi-commit pull requests, 57% of created-to-merged wall-clock was idle gaps of ninety minutes or more, and every gap between nine and thirteen and a half hours began with a reviewer verdict — a Codex or CodeRabbit review, or a reviewer-identity comment — that no session was alive to act on. The verdict was ready within minutes; the pull request then waited for someone to open a session. The review loop itself is fast when a session is driving it; the cost is the session ending with the ball in the agent's court.

A session therefore does not end with a pull request in either of these states unless it has posted a handoff:

- the pull request's newest event is a verdict — a bot review, a bot verdict comment, a reviewer-identity review or comment, or a human reply — with no push, reply or review request after it; or
- the pull request's head is CI-green, approved and unmerged.

Finish the round instead: fix or rebut the findings and push, request the next review, or run the pre-merge gates and merge, in the order `REVIEW_POLICY.md` § Workflow prescribes. When the round genuinely cannot be finished in the session — the fix needs a human decision, the external reviewer has not answered, or the session has hit a capability ceiling — post a pull-request comment that names the next action and the identity expected to take it, and carries the tag `[mergepath-handoff]` on its own line so tooling can recognize it. The Phase 4b handoff (the `## External Review Required` comment) and the local-agent handback (`<!-- mergepath-handback: … -->`) already count as handoffs; the `human-hold`, `needs-human-review` and `policy-violation` labels already count as a human stop.

A pull request with no handoff is fair game for any later session, including a scheduled resume routine, to pick up and continue from its newest event; a pull request with a handoff is left to the identity the handoff names. A handoff stays in force for as long as its marker is on the pull request, whatever happens after it; no later push, review or comment clears it. The identity it names clears it when the round is taken back, by editing or deleting the handoff comment so it no longer carries the marker. This rule is about the state a session leaves behind, not about who caused the wait: a session that is waiting on CI or on a requested review may end, because a machine acts next; a session that is holding an answered-for verdict may not.

## Filing an issue: fill out every triage field at creation

The agent that files an issue holds the context a later board-triage pass would have to reconstruct from a cold read, so it fills out every triage field when it creates the issue, using only evidence it can name. Where a field cannot be decided from that evidence, the issue gets `decision-needed` and the open question in its body; a field is never filled by guessing. Issue writes go through `scripts/gh-as-author.sh` as `nathanjohnpayne`, with the body passed by `--body-file`.

1. **Labels.** Exactly one `size:` label, exactly one `priority:` label, and exactly one of `agent-action` / `human-action`, plus `decision-needed` when the issue cannot proceed until a human decides something. Choose each by its canonical description. The canonical label set has one source, the `BOOTSTRAP_LABELS` list in the hub's new-repo bootstrap, specified in [`specs/bootstrap_label_seeding.md`](https://github.com/nathanjohnpayne/mergepath/blob/main/specs/bootstrap_label_seeding.md) (hub-only, so the link is absolute), which names the file that holds it; the fleet label sync keeps every repository's labels in step with it. `priority:normal` is the default; `priority:high` and `priority:critical` need the evidence their descriptions require, cited in the body, and `priority:low` applies only when the issue itself says the work is optional. Add the repository's own type or area labels where it defines them, and never create a label outside the canonical set and the repository's own. Do not add or remove the merge-gate labels (`needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`) or `needs-local-agent` when filing.
2. **Dependencies.** Record every blocked-by / blocking relationship with GitHub's native issue relationships (the issue's *Relationships* sidebar, or `POST repos/OWNER/REPO/issues/N/dependencies/blocked_by` with the blocker's numeric database `id`, not its number), not as body text. A dependency exists only when one issue cannot be completed until the other lands. A shared topic is not a dependency, and neither is a sub-issue link.
3. **Lane.** Leave the issue in `Backlog`, where the board's *Item added to project* workflow puts it, unless the `Ready` entry rule in [`scripts/gh-projects/README.md` § Status lanes](../../scripts/gh-projects/README.md#status-lanes) is met (the issue states the problem, the expected outcome, and how to verify it, and every blocker is closed) and, for a `size:L` issue, its sub-issues are filed. Move it with `scripts/gh-projects/move-item.sh` (`--add-if-missing` when it is not on the board yet), then place it as [Ordering the Ready column](#ordering-the-ready-column) says.
4. **Routing.** Unless the issue is a `size:L` parent, pick its tier from [Model Routing § Routing tiers](model-routing.md#routing-tiers) and write both of that tier's routes into the body as the [route marker](#the-route-marker). When the repository's board has the four routing fields, set them to the same values in the same step. When the evidence does not settle the tier, leave the marker and the fields unset and add `decision-needed` with the question; the issue stays in `Backlog` and is not started until its route is decided.
5. **`size:L` decomposition.** File a `size:L` issue together with its `size:S` / `size:M` sub-issues. Create each sub-issue through the author wrapper like any other issue, then link it to the parent as a native sub-issue: `POST repos/OWNER/REPO/issues/<parent>/sub_issues` with the child's numeric database `id` as `sub_issue_id`, which `link_sub_issue` in `scripts/gh-projects/lib.sh` wraps. Each sub-issue has **Inputs**, **Outputs**, **Acceptance criteria**, and **Validation** sections and its own labels, dependencies, and route. If the scope cannot be split without inventing it, file the parent alone with `decision-needed`, leave it in `Backlog`, and list the questions that would unblock the split.
6. **Body.** Acceptance criteria an agent can verify, and a validation step (a test, command, or check) or a note on why none applies.

### The route marker

An issue's model and effort route lives on the issue, as one hidden line in its body. The board's routing fields mirror it but are not its source: a Claude cloud session can read an issue body with one REST call (`GET repos/OWNER/REPO/issues/N`), but it cannot read the boards, which belong to the `nathanjohnpayne` user account, outside the `repos/<owner>/<repo>/...` paths its GitHub proxy allows. The format is:

```markdown
<!-- mergepath-route: anthropic=<model>/<effort> openai=<model>/<effort> -->
```

Each value is the board option's name, lowercased, with spaces replaced by `-`. These are the only valid values:

| Half | Model: board option → value (fields `Anthropic model`, `OpenAI model`) | Effort (fields `Anthropic effort`, `OpenAI effort`) |
|---|---|---|
| `anthropic` | Haiku 4.5 → `haiku-4.5`, Sonnet 5.5 → `sonnet-5.5`, Opus 5.5 → `opus-5.5`, Fable 5.1 → `fable-5.1` | `low`, `medium`, `high` |
| `openai` | GPT-6 Luna → `gpt-6-luna`, GPT-6.1 Sol → `gpt-6.1-sol`, GPT-6 Astra → `gpt-6-astra` | `low`, `medium`, `high`, `xhigh` |

- An issue carries exactly one marker, on its own line, with both halves.
- A `size:L` parent carries no marker; each of its sub-issues does.
- Changing a route means replacing the marker line in place, never adding a second one, and updating the board fields in the same step when the board has them. Replacing the marker is the only routing edit a triage pass makes to an existing issue body.
- When the marker and the board fields disagree, the marker wins. Whoever notices reports the drift to the owner instead of silently rewriting either side.

### Ordering the Ready column

The `Ready` entry rule says an issue can be started, not that it should be next, and no workflow orders the column. So an agent that moves an issue to `Ready`, whether at filing, in triage, or when its last blocker closes, also places it in the column: by priority tier first (`priority:critical`, then `high`, `normal`, `low`), then in dependency order within a tier, blockers above what they block, so an issue that other open issues are waiting on sits above one that nothing waits on. The top `Ready` item is then the next one to take, skipping any `size:L` parent: a parent never gets a branch of its own, so its work is taken through its sub-issues. Whoever changes the priority of an issue already in `Ready` places it again the same way.

No helper in `scripts/gh-projects/` positions items. Place one by dragging its card on the board, or with the Projects GraphQL mutation `updateProjectV2ItemPosition` (`projectId`, `itemId`, and `afterId`, the item it should follow; omit `afterId` to move it to the top), run as `nathanjohnpayne`, the identity the board helpers verify. This is the board's manual order, which a view sorted by a field does not show. A session that cannot reach GraphQL hands the placement to one that can, like any other board move.

## Starting an issue: read and honor its route

Before starting work on an issue, and after the claim check in [Link the issue a pull request resolves](#link-the-issue-a-pull-request-resolves), read the issue's [route marker](#the-route-marker) and honor the half for the provider your session runs on: `anthropic` for a Claude model, `openai` for an OpenAI model. Read it with `scripts/gh-projects/read-route.sh` when your checkout has that helper (nathanjohnpayne/mergepath#2848 adds it to the board kit); without it, read the issue body over REST (`gh api repos/OWNER/REPO/issues/N --jq .body`) and apply the marker rules yourself.

- **No marker:** keep the session's model and effort, unless the issue carries `decision-needed` for its route, in which case it is not ready to start.
- **A different model or effort:** a session cannot change its own model, so delegate the implementation to a subagent configured with the route's model and effort.
- **An unavailable model:** if neither the session nor any subagent it can start runs the route's model, do not substitute another. Report the mismatch to the owner once, leave the issue unstarted, and continue with other work.
- **A malformed or duplicated marker:** do not guess which route was meant. Report it to the owner once, leave the issue unstarted, and continue with other work.

A single comment on the issue is enough for either report; check for an earlier one before posting.

## Link the issue a pull request resolves

When a pull request resolves an issue, its body names that issue with a closing keyword: `Closes #N` on its own line, one line per issue, or `Closes OWNER/REPO#N` for an issue in another repository (the same qualification applies to `Refs`). An issue number in the title, a `(#N)` suffix, or `Refs #N` mentions the issue without linking it. GitHub honors a closing keyword only when the pull request targets the repository's default branch; for a pull request into any other branch the keyword links nothing, so move the issue between lanes by hand.

The link is what moves the issue on the repository's Project board. The board's *Pull request linked to issue* workflow moves the issue to `In review` when the pull request opens, and the merge closes it, which moves it to `Done`. Without the link the issue sits in `Ready` or `In progress` through the whole review and has to be closed by hand.

Use `Refs #N` instead when the pull request is only part of the work, so the merge does not close an issue that still has work left; move that issue between lanes by hand. What each lane means, and which moves are manual: `scripts/gh-projects/README.md` § Status lanes.

One issue, one open pull request. `scripts/gh-as-author.sh -- gh pr create` refuses to open a pull request whose body links an issue that another open pull request in the same repository already links with any of those keywords, and names that pull request (exit `7`). Two sessions implementing one issue, discovered only by a merge conflict, is the failure it catches (nathanjohnpayne/mergepath#2562). When the second pull request is a deliberate split or a stacked tranche, name the first in `GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK=<number>` and say so in the body; an open-PR list the wrapper cannot read refuses rather than passes. The check sees only open pull requests, so before starting on an issue read its newest comments and any open linked pull request, and leave a one-line claim through the reviewer wrapper, `<!-- mergepath-claim: <agent> <YYYY-MM-DD> -->` on its own line, so a session arriving in the window before your pull request exists sees who holds it; do not start on an issue whose newest claim is another identity's while that identity's pull request is still open or its claim is less than a day old.

## Visual evidence for reader-visible UI changes

A pull request that makes a meaningful reader-visible UI change carries screenshots of the changed state, in its body or in a comment on it. By default that means a desktop capture and a phone capture; a ticket may require more widths or states, and a reviewer may ask for more. When screenshots would add no useful evidence, or cannot be produced, the pull request says so, in the same places, with a concrete explanation (what was tried, or why the change has no visible state to capture). Silence does not satisfy the requirement, and neither does a bare "N/A".

Upload with `scripts/pr-assets-upload.sh`, then paste the Markdown lines it prints into the PR body or a comment. They are pinned to the full commit SHA of the upload, so they keep rendering after later uploads:

```
eval "$(scripts/op-preflight.sh --agent <agent> --mode pr-assets)"
scripts/pr-assets-upload.sh --repo nathanjohnpayne/<name> --pr <N> desktop.png phone.png
```

`--mode pr-assets` caches the identity-checked author credential scoped to the assets repository; the script uses no other credential. `scripts/pr-assets-upload.sh --help` lists the accepted file types, the naming rules and the exit codes.

- **Never in the code repository.** Do not commit screenshots to the repository the pull request targets, and do not push them as a branch of it. The script writes only to `nathanjohnpayne/pr-assets` and never touches the source repository's refs.
- **Public-only.** Everything in `nathanjohnpayne/pr-assets` is public, so a screenshot must meet the bar of a public PR body: nothing from signed-in analytics or vendor dashboards, no personal data, nothing from a private repository. The script refuses a private or internal source repository. For a private repository, use an approved private method for visual evidence, or report the blocker on the pull request; do not substitute the public store and do not silently omit the evidence.
- **Keep everything.** Never delete or rewrite history in `nathanjohnpayne/pr-assets`: older pull requests embed SHA-pinned URLs into it, and removing a commit breaks them. Upload under a new name rather than replacing a file.

## PR and issue titles/descriptions: describe the work, not the session

Titles and descriptions — for both pull requests and issues — must describe the final state of the change (what it does and why) for a reader who arrives with no knowledge of the session that produced it.

- Do not narrate the session's path: no pivots, abandoned approaches, "originally did X, then switched to Y," or commentary on how the plan evolved.
- When a pivot changes what the work is, update the title/description to reflect the new end state — not the fact that a pivot happened.
- Once a title or description already describes the work accurately, treat it as read-only. Do not reword or "refresh" it to fold in later session context.
- This bans narrating the session, not documenting the work. Design rationale, an "Alternatives considered" section, or contrasting the change with the prior committed code (e.g. "replaces the hard-coded `null` with a threaded value") all describe the end state for a cold reader and are fine. The test: would the text help someone who never saw the session? Rationale and prior-code contrast pass; "I first tried X, then switched" does not.
- One narration-shaped section is carved out by name: a `## Path taken` record in a **pull-request body**, written under the change-level half of `docs/agents/decision-records.md`. It is "Alternatives considered" one step further along — it names an alternative that was not merely weighed but tried and abandoned, which is the only thing that tells a later reader a rejected approach from an unexamined one. The carve-out is narrow in three ways, and outside them the ban above is unchanged: it covers the content under that heading only, never the title; it applies only when that document's triggers actually fired, and its non-trigger list is as binding as its trigger list; and the rest of the body — summary, rationale, the acceptance criteria that still stand — is still written for a reader who never saw the session.
- Exactly one annotation is exempt *outside* that heading, because the same document requires it to stay where the criterion is rather than move under the record: an acceptance criterion the change discarded is struck in place, keeping its checkbox, with the dated reason appended — `- [ ] ~~<criterion>~~ — Discarded YYYY-MM-DD: <reason>`. It qualifies on the same terms and for the same reason as the heading does: a cold reader needs it to tell a criterion dropped for cause from one that was never asked for, and deleting the criterion instead would make it look as though nobody ever asked. It is exempt only when a path record was triggered in the first place, and it does not license any other dated session note in the criteria list.

This is advisory guidance for judgment, not a `repo_lint`/CI gate — the narration-vs-rationale distinction is not reliably lintable, and a reviewer (human or bot) should apply it as judgment rather than minting false-positive findings from words like "originally" or "instead." See nathanjohnpayne/mergepath#654, and nathanjohnpayne/mergepath#788 for the carve-out above.

## CodeRabbit rate-limit substitution

When CodeRabbit is rate-limited, request Codex immediately through the canonical requester rather than waiting out the provider window. A request grants no clearance: under-threshold approval requires a completed exact-head Codex review or affirmative verdict with required findings handled, and records the provider substitution and full SHA. Phase 4 keeps its usual independent-review and escalation gates; [mergepath#2120](https://github.com/nathanjohnpayne/mergepath/issues/2120) permits its adapter review after a bare CodeRabbit refusal. If Codex is unavailable too, alert the human. See `REVIEW_POLICY.md` § Rate-limit → Codex failover and [mergepath#2139](https://github.com/nathanjohnpayne/mergepath/issues/2139) for the full workflow.
