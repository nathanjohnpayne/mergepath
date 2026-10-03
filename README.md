# Mergepath Cockpit design exports (epic #1585)

High-resolution PNG exports of the Cockpit design canvas and design spec, for the subtasks #1586 to #1594. Every image is a 2x (phone captures 3x) render of the published design, captured headless from the design source in this branch. `manifest.json` lists every image with its caption. Images are palette-quantized with `pngquant --quality=90-100` to keep this branch small; the largest per-channel difference from the raw capture is 8 of 255, so text and edges are unchanged at full size.

- Original design canvas (private Claude link): https://claude.ai/artifact/LMrtkUuL2tGMSzrsKwSXTS
- Original design spec (private Claude link): https://claude.ai/artifact/6dPeaYr8mxiwRoR7ARvJiD
- Design source: [`source/canvas/project/`](source/canvas/project/) holds the canvas artboards (`Main.dc.html`, `StatusLanguage.dc.html`) and `canvas.json`. They need the Claude Design canvas runtime to run interactively; the runtime is not redistributed here.
- Spec export: [`source/cockpit-design-spec.html`](source/cockpit-design-spec.html) is standalone and opens in any browser (add `data-theme="dark"` on `<html>` for the dark theme).
- Rendered snapshots: [`source/rendered-snapshots/`](source/rendered-snapshots/) holds the rendered prototype DOM for each scenario and theme as static HTML (no script; open in a browser).

Scenarios: Calm, Busy, Speed bumps ahead and Boulder hit are the prototype's mock-data states. Prototype controls (the dashed strip) are not product.

## agents

**Phase 4b agents (live) panel: Boulder hit scenario, dark theme**

![Phase 4b agents (live) panel: Boulder hit scenario, dark theme](images/agents/agents-live-boulder-dark.png)

**Phase 4b agents (live) panel: Boulder hit scenario, light theme**

![Phase 4b agents (live) panel: Boulder hit scenario, light theme](images/agents/agents-live-boulder-light.png)

**Phase 4b agents (live) panel: Speed bumps ahead scenario, dark theme**

![Phase 4b agents (live) panel: Speed bumps ahead scenario, dark theme](images/agents/agents-live-bumps-dark.png)

**Phase 4b agents (live) panel: Speed bumps ahead scenario, light theme**

![Phase 4b agents (live) panel: Speed bumps ahead scenario, light theme](images/agents/agents-live-bumps-light.png)

**Phase 4b agents (live) panel: Busy scenario, dark theme**

![Phase 4b agents (live) panel: Busy scenario, dark theme](images/agents/agents-live-busy-dark.png)

**Phase 4b agents (live) panel: Busy scenario, light theme**

![Phase 4b agents (live) panel: Busy scenario, light theme](images/agents/agents-live-busy-light.png)

**Phase 4b agents (live) panel: Calm scenario, dark theme**

![Phase 4b agents (live) panel: Calm scenario, dark theme](images/agents/agents-live-calm-dark.png)

**Phase 4b agents (live) panel: Calm scenario, light theme**

![Phase 4b agents (live) panel: Calm scenario, light theme](images/agents/agents-live-calm-light.png)

**Phase 4b history: chart, totals and run table: Boulder hit scenario, dark theme**

![Phase 4b history: chart, totals and run table: Boulder hit scenario, dark theme](images/agents/history-boulder-dark.png)

**Phase 4b history: chart, totals and run table: Boulder hit scenario, light theme**

![Phase 4b history: chart, totals and run table: Boulder hit scenario, light theme](images/agents/history-boulder-light.png)

**Phase 4b history: chart, totals and run table: Speed bumps ahead scenario, dark theme**

![Phase 4b history: chart, totals and run table: Speed bumps ahead scenario, dark theme](images/agents/history-bumps-dark.png)

**Phase 4b history: chart, totals and run table: Speed bumps ahead scenario, light theme**

![Phase 4b history: chart, totals and run table: Speed bumps ahead scenario, light theme](images/agents/history-bumps-light.png)

**Phase 4b history: chart, totals and run table: Busy scenario, dark theme**

![Phase 4b history: chart, totals and run table: Busy scenario, dark theme](images/agents/history-busy-dark.png)

**Phase 4b history: chart, totals and run table: Busy scenario, light theme**

![Phase 4b history: chart, totals and run table: Busy scenario, light theme](images/agents/history-busy-light.png)

**Phase 4b history: chart, totals and run table: Calm scenario, dark theme**

![Phase 4b history: chart, totals and run table: Calm scenario, dark theme](images/agents/history-calm-dark.png)

**Phase 4b history: chart, totals and run table: Calm scenario, light theme**

![Phase 4b history: chart, totals and run table: Calm scenario, light theme](images/agents/history-calm-light.png)

## budget

**GitHub Actions budget panel: Boulder hit scenario, dark theme**

![GitHub Actions budget panel: Boulder hit scenario, dark theme](images/budget/actions-budget-boulder-dark.png)

**GitHub Actions budget panel: Boulder hit scenario, light theme**

![GitHub Actions budget panel: Boulder hit scenario, light theme](images/budget/actions-budget-boulder-light.png)

**GitHub Actions budget panel: Speed bumps ahead scenario, dark theme**

![GitHub Actions budget panel: Speed bumps ahead scenario, dark theme](images/budget/actions-budget-bumps-dark.png)

**GitHub Actions budget panel: Speed bumps ahead scenario, light theme**

![GitHub Actions budget panel: Speed bumps ahead scenario, light theme](images/budget/actions-budget-bumps-light.png)

**GitHub Actions budget panel: Busy scenario, dark theme**

![GitHub Actions budget panel: Busy scenario, dark theme](images/budget/actions-budget-busy-dark.png)

**GitHub Actions budget panel: Busy scenario, light theme**

![GitHub Actions budget panel: Busy scenario, light theme](images/budget/actions-budget-busy-light.png)

**GitHub Actions budget panel: Calm scenario, dark theme**

![GitHub Actions budget panel: Calm scenario, dark theme](images/budget/actions-budget-calm-dark.png)

**GitHub Actions budget panel: Calm scenario, light theme**

![GitHub Actions budget panel: Calm scenario, light theme](images/budget/actions-budget-calm-light.png)

## ci

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Boulder hit scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run1-dark.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Boulder hit scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run1-light.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Boulder hit scenario, dark theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run2-dark.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Boulder hit scenario, light theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run2-light.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Boulder hit scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run3-dark.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Boulder hit scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run3-light.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Boulder hit scenario, dark theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run4-dark.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Boulder hit scenario, light theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run4-light.png)

**CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Boulder hit scenario, dark theme**

![CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run5-dark.png)

**CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Boulder hit scenario, light theme**

![CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run5-light.png)

**CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 1h 12m Queued long": Boulder hit scenario, dark theme**

![CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 1h 12m Queued long": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run6-dark.png)

**CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 1h 12m Queued long": Boulder hit scenario, light theme**

![CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 1h 12m Queued long": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run6-light.png)

**CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 11m 20s Not retryable": Boulder hit scenario, dark theme**

![CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 11m 20s Not retryable": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run7-dark.png)

**CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 11m 20s Not retryable": Boulder hit scenario, light theme**

![CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 11m 20s Not retryable": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run7-light.png)

**CI drill-down open on "repo_lint mergepath #1601 · 77a0e13 22s Token exhausted": Boulder hit scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1601 · 77a0e13 22s Token exhausted": Boulder hit scenario, dark theme](images/ci/ci-drilldown-boulder-run8-dark.png)

**CI drill-down open on "repo_lint mergepath #1601 · 77a0e13 22s Token exhausted": Boulder hit scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1601 · 77a0e13 22s Token exhausted": Boulder hit scenario, light theme](images/ci/ci-drilldown-boulder-run8-light.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Speed bumps ahead scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Speed bumps ahead scenario, dark theme](images/ci/ci-drilldown-bumps-run1-dark.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Speed bumps ahead scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Speed bumps ahead scenario, light theme](images/ci/ci-drilldown-bumps-run1-light.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Speed bumps ahead scenario, dark theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Speed bumps ahead scenario, dark theme](images/ci/ci-drilldown-bumps-run2-dark.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Speed bumps ahead scenario, light theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Speed bumps ahead scenario, light theme](images/ci/ci-drilldown-bumps-run2-light.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Speed bumps ahead scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Speed bumps ahead scenario, dark theme](images/ci/ci-drilldown-bumps-run3-dark.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Speed bumps ahead scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Speed bumps ahead scenario, light theme](images/ci/ci-drilldown-bumps-run3-light.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Speed bumps ahead scenario, dark theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Speed bumps ahead scenario, dark theme](images/ci/ci-drilldown-bumps-run4-dark.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Speed bumps ahead scenario, light theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Speed bumps ahead scenario, light theme](images/ci/ci-drilldown-bumps-run4-light.png)

**CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Speed bumps ahead scenario, dark theme**

![CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Speed bumps ahead scenario, dark theme](images/ci/ci-drilldown-bumps-run5-dark.png)

**CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Speed bumps ahead scenario, light theme**

![CI drill-down open on "repo_lint swipewatch #88 · b44d1c7 3m 58s Stale failure": Speed bumps ahead scenario, light theme](images/ci/ci-drilldown-bumps-run5-light.png)

**CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 18m Queued long": Speed bumps ahead scenario, dark theme**

![CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 18m Queued long": Speed bumps ahead scenario, dark theme](images/ci/ci-drilldown-bumps-run6-dark.png)

**CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 18m Queued long": Speed bumps ahead scenario, light theme**

![CI drill-down open on "merge-clearance friends-and-family-billing #19 · c7b1d04 queued 18m Queued long": Speed bumps ahead scenario, light theme](images/ci/ci-drilldown-bumps-run6-light.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Busy scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run1-dark.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Busy scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Busy scenario, light theme](images/ci/ci-drilldown-busy-run1-light.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Busy scenario, dark theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run2-dark.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Busy scenario, light theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Busy scenario, light theme](images/ci/ci-drilldown-busy-run2-light.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Busy scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run3-dark.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Busy scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Busy scenario, light theme](images/ci/ci-drilldown-busy-run3-light.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Busy scenario, dark theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run4-dark.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Busy scenario, light theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Busy scenario, light theme](images/ci/ci-drilldown-busy-run4-light.png)

**CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 6m 40s Running": Busy scenario, dark theme**

![CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 6m 40s Running": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run5-dark.png)

**CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 6m 40s Running": Busy scenario, light theme**

![CI drill-down open on "codeql overridebroadway #41 · 3e7ab02 6m 40s Running": Busy scenario, light theme](images/ci/ci-drilldown-busy-run5-light.png)

**CI drill-down open on "merge-clearance nathanpaynedotcom #137 · 91c3f50 48s Running": Busy scenario, dark theme**

![CI drill-down open on "merge-clearance nathanpaynedotcom #137 · 91c3f50 48s Running": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run6-dark.png)

**CI drill-down open on "merge-clearance nathanpaynedotcom #137 · 91c3f50 48s Running": Busy scenario, light theme**

![CI drill-down open on "merge-clearance nathanpaynedotcom #137 · 91c3f50 48s Running": Busy scenario, light theme](images/ci/ci-drilldown-busy-run6-light.png)

**CI drill-down open on "repo_lint tadlockpsychiatry #7 · 0f4c9d2 3m 02s Passed": Busy scenario, dark theme**

![CI drill-down open on "repo_lint tadlockpsychiatry #7 · 0f4c9d2 3m 02s Passed": Busy scenario, dark theme](images/ci/ci-drilldown-busy-run7-dark.png)

**CI drill-down open on "repo_lint tadlockpsychiatry #7 · 0f4c9d2 3m 02s Passed": Busy scenario, light theme**

![CI drill-down open on "repo_lint tadlockpsychiatry #7 · 0f4c9d2 3m 02s Passed": Busy scenario, light theme](images/ci/ci-drilldown-busy-run7-light.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Calm scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Calm scenario, dark theme](images/ci/ci-drilldown-calm-run1-dark.png)

**CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Calm scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1598 · a3f9c21 3m 12s Running": Calm scenario, light theme](images/ci/ci-drilldown-calm-run1-light.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Calm scenario, dark theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Calm scenario, dark theme](images/ci/ci-drilldown-calm-run2-dark.png)

**CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Calm scenario, light theme**

![CI drill-down open on "codex-review-check mergepath #1598 · a3f9c21 3m 05s Running": Calm scenario, light theme](images/ci/ci-drilldown-calm-run2-light.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Calm scenario, dark theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Calm scenario, dark theme](images/ci/ci-drilldown-calm-run3-dark.png)

**CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Calm scenario, light theme**

![CI drill-down open on "repo_lint mergepath #1599 · e81b7aa 1m 02s Running": Calm scenario, light theme](images/ci/ci-drilldown-calm-run3-light.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Calm scenario, dark theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Calm scenario, dark theme](images/ci/ci-drilldown-calm-run4-dark.png)

**CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Calm scenario, light theme**

![CI drill-down open on "repo_lint matchline #212 · 5d02e8f 4m 41s Passed": Calm scenario, light theme](images/ci/ci-drilldown-calm-run4-light.png)

**CI and test runs panel, all rows collapsed: Boulder hit scenario, dark theme**

![CI and test runs panel, all rows collapsed: Boulder hit scenario, dark theme](images/ci/ci-runs-boulder-dark.png)

**CI and test runs panel, all rows collapsed: Boulder hit scenario, light theme**

![CI and test runs panel, all rows collapsed: Boulder hit scenario, light theme](images/ci/ci-runs-boulder-light.png)

**CI and test runs panel, all rows collapsed: Speed bumps ahead scenario, dark theme**

![CI and test runs panel, all rows collapsed: Speed bumps ahead scenario, dark theme](images/ci/ci-runs-bumps-dark.png)

**CI and test runs panel, all rows collapsed: Speed bumps ahead scenario, light theme**

![CI and test runs panel, all rows collapsed: Speed bumps ahead scenario, light theme](images/ci/ci-runs-bumps-light.png)

**CI and test runs panel, all rows collapsed: Busy scenario, dark theme**

![CI and test runs panel, all rows collapsed: Busy scenario, dark theme](images/ci/ci-runs-busy-dark.png)

**CI and test runs panel, all rows collapsed: Busy scenario, light theme**

![CI and test runs panel, all rows collapsed: Busy scenario, light theme](images/ci/ci-runs-busy-light.png)

**CI and test runs panel, all rows collapsed: Calm scenario, dark theme**

![CI and test runs panel, all rows collapsed: Calm scenario, dark theme](images/ci/ci-runs-calm-dark.png)

**CI and test runs panel, all rows collapsed: Calm scenario, light theme**

![CI and test runs panel, all rows collapsed: Calm scenario, light theme](images/ci/ci-runs-calm-light.png)

## fleet

**Audit finished: banner gone, last-audit column reads "just now" (Speed bumps ahead, dark)**

![Audit finished: banner gone, last-audit column reads "just now" (Speed bumps ahead, dark)](images/fleet/audit-finished-bumps-dark.png)

**Audit finished: banner gone, last-audit column reads "just now" (Speed bumps ahead, light)**

![Audit finished: banner gone, last-audit column reads "just now" (Speed bumps ahead, light)](images/fleet/audit-finished-bumps-light.png)

**Refresh audit in progress: audit banner with progress bar, Sync buttons disabled, last good result kept (Speed bumps ahead, dark)**

![Refresh audit in progress: audit banner with progress bar, Sync buttons disabled, last good result kept (Speed bumps ahead, dark)](images/fleet/audit-running-bumps-dark.png)

**Refresh audit in progress: audit banner with progress bar, Sync buttons disabled, last good result kept (Speed bumps ahead, light)**

![Refresh audit in progress: audit banner with progress bar, Sync buttons disabled, last good result kept (Speed bumps ahead, light)](images/fleet/audit-running-bumps-light.png)

**Fleet sync status panel: Boulder hit scenario, dark theme**

![Fleet sync status panel: Boulder hit scenario, dark theme](images/fleet/fleet-boulder-dark.png)

**Fleet sync status panel: Boulder hit scenario, light theme**

![Fleet sync status panel: Boulder hit scenario, light theme](images/fleet/fleet-boulder-light.png)

**Fleet sync status panel: Speed bumps ahead scenario, dark theme**

![Fleet sync status panel: Speed bumps ahead scenario, dark theme](images/fleet/fleet-bumps-dark.png)

**Fleet sync status panel: Speed bumps ahead scenario, light theme**

![Fleet sync status panel: Speed bumps ahead scenario, light theme](images/fleet/fleet-bumps-light.png)

**Fleet sync status panel: Busy scenario, dark theme**

![Fleet sync status panel: Busy scenario, dark theme](images/fleet/fleet-busy-dark.png)

**Fleet sync status panel: Busy scenario, light theme**

![Fleet sync status panel: Busy scenario, light theme](images/fleet/fleet-busy-light.png)

**Fleet sync status panel: Calm scenario, dark theme**

![Fleet sync status panel: Calm scenario, dark theme](images/fleet/fleet-calm-dark.png)

**Fleet sync status panel: Calm scenario, light theme**

![Fleet sync status panel: Calm scenario, light theme](images/fleet/fleet-calm-light.png)

**Fleet row path list expanded (swipewatch): Boulder hit scenario, dark theme**

![Fleet row path list expanded (swipewatch): Boulder hit scenario, dark theme](images/fleet/fleet-paths-boulder-row1-dark.png)

**Fleet row path list expanded (swipewatch): Boulder hit scenario, light theme**

![Fleet row path list expanded (swipewatch): Boulder hit scenario, light theme](images/fleet/fleet-paths-boulder-row1-light.png)

**Fleet row path list expanded (overridebroadway): Boulder hit scenario, dark theme**

![Fleet row path list expanded (overridebroadway): Boulder hit scenario, dark theme](images/fleet/fleet-paths-boulder-row2-dark.png)

**Fleet row path list expanded (overridebroadway): Boulder hit scenario, light theme**

![Fleet row path list expanded (overridebroadway): Boulder hit scenario, light theme](images/fleet/fleet-paths-boulder-row2-light.png)

**Fleet row path list expanded (nathanpaynedotcom): Boulder hit scenario, dark theme**

![Fleet row path list expanded (nathanpaynedotcom): Boulder hit scenario, dark theme](images/fleet/fleet-paths-boulder-row3-dark.png)

**Fleet row path list expanded (nathanpaynedotcom): Boulder hit scenario, light theme**

![Fleet row path list expanded (nathanpaynedotcom): Boulder hit scenario, light theme](images/fleet/fleet-paths-boulder-row3-light.png)

**Fleet row path list expanded (friends-and-family-billing): Boulder hit scenario, dark theme**

![Fleet row path list expanded (friends-and-family-billing): Boulder hit scenario, dark theme](images/fleet/fleet-paths-boulder-row4-dark.png)

**Fleet row path list expanded (friends-and-family-billing): Boulder hit scenario, light theme**

![Fleet row path list expanded (friends-and-family-billing): Boulder hit scenario, light theme](images/fleet/fleet-paths-boulder-row4-light.png)

**Fleet row path list expanded (swipewatch): Speed bumps ahead scenario, dark theme**

![Fleet row path list expanded (swipewatch): Speed bumps ahead scenario, dark theme](images/fleet/fleet-paths-bumps-row1-dark.png)

**Fleet row path list expanded (swipewatch): Speed bumps ahead scenario, light theme**

![Fleet row path list expanded (swipewatch): Speed bumps ahead scenario, light theme](images/fleet/fleet-paths-bumps-row1-light.png)

**Fleet row path list expanded (overridebroadway): Speed bumps ahead scenario, dark theme**

![Fleet row path list expanded (overridebroadway): Speed bumps ahead scenario, dark theme](images/fleet/fleet-paths-bumps-row2-dark.png)

**Fleet row path list expanded (overridebroadway): Speed bumps ahead scenario, light theme**

![Fleet row path list expanded (overridebroadway): Speed bumps ahead scenario, light theme](images/fleet/fleet-paths-bumps-row2-light.png)

**Fleet row path list expanded (nathanpaynedotcom): Speed bumps ahead scenario, dark theme**

![Fleet row path list expanded (nathanpaynedotcom): Speed bumps ahead scenario, dark theme](images/fleet/fleet-paths-bumps-row3-dark.png)

**Fleet row path list expanded (nathanpaynedotcom): Speed bumps ahead scenario, light theme**

![Fleet row path list expanded (nathanpaynedotcom): Speed bumps ahead scenario, light theme](images/fleet/fleet-paths-bumps-row3-light.png)

**Fleet row path list expanded (friends-and-family-billing): Speed bumps ahead scenario, dark theme**

![Fleet row path list expanded (friends-and-family-billing): Speed bumps ahead scenario, dark theme](images/fleet/fleet-paths-bumps-row4-dark.png)

**Fleet row path list expanded (friends-and-family-billing): Speed bumps ahead scenario, light theme**

![Fleet row path list expanded (friends-and-family-billing): Speed bumps ahead scenario, light theme](images/fleet/fleet-paths-bumps-row4-light.png)

**Fleet row path list expanded (swipewatch): Busy scenario, dark theme**

![Fleet row path list expanded (swipewatch): Busy scenario, dark theme](images/fleet/fleet-paths-busy-row1-dark.png)

**Fleet row path list expanded (swipewatch): Busy scenario, light theme**

![Fleet row path list expanded (swipewatch): Busy scenario, light theme](images/fleet/fleet-paths-busy-row1-light.png)

**Fleet row path list expanded (overridebroadway): Busy scenario, dark theme**

![Fleet row path list expanded (overridebroadway): Busy scenario, dark theme](images/fleet/fleet-paths-busy-row2-dark.png)

**Fleet row path list expanded (overridebroadway): Busy scenario, light theme**

![Fleet row path list expanded (overridebroadway): Busy scenario, light theme](images/fleet/fleet-paths-busy-row2-light.png)

**Fleet row path list expanded (nathanpaynedotcom): Busy scenario, dark theme**

![Fleet row path list expanded (nathanpaynedotcom): Busy scenario, dark theme](images/fleet/fleet-paths-busy-row3-dark.png)

**Fleet row path list expanded (nathanpaynedotcom): Busy scenario, light theme**

![Fleet row path list expanded (nathanpaynedotcom): Busy scenario, light theme](images/fleet/fleet-paths-busy-row3-light.png)

**Fleet row path list expanded (friends-and-family-billing): Busy scenario, dark theme**

![Fleet row path list expanded (friends-and-family-billing): Busy scenario, dark theme](images/fleet/fleet-paths-busy-row4-dark.png)

**Fleet row path list expanded (friends-and-family-billing): Busy scenario, light theme**

![Fleet row path list expanded (friends-and-family-billing): Busy scenario, light theme](images/fleet/fleet-paths-busy-row4-light.png)

**Fleet row path list expanded (swipewatch): Calm scenario, dark theme**

![Fleet row path list expanded (swipewatch): Calm scenario, dark theme](images/fleet/fleet-paths-calm-row1-dark.png)

**Fleet row path list expanded (swipewatch): Calm scenario, light theme**

![Fleet row path list expanded (swipewatch): Calm scenario, light theme](images/fleet/fleet-paths-calm-row1-light.png)

**Fleet row path list expanded (overridebroadway): Calm scenario, dark theme**

![Fleet row path list expanded (overridebroadway): Calm scenario, dark theme](images/fleet/fleet-paths-calm-row2-dark.png)

**Fleet row path list expanded (overridebroadway): Calm scenario, light theme**

![Fleet row path list expanded (overridebroadway): Calm scenario, light theme](images/fleet/fleet-paths-calm-row2-light.png)

**Fleet row path list expanded (nathanpaynedotcom): Calm scenario, dark theme**

![Fleet row path list expanded (nathanpaynedotcom): Calm scenario, dark theme](images/fleet/fleet-paths-calm-row3-dark.png)

**Fleet row path list expanded (nathanpaynedotcom): Calm scenario, light theme**

![Fleet row path list expanded (nathanpaynedotcom): Calm scenario, light theme](images/fleet/fleet-paths-calm-row3-light.png)

**Fleet row path list expanded (friends-and-family-billing): Calm scenario, dark theme**

![Fleet row path list expanded (friends-and-family-billing): Calm scenario, dark theme](images/fleet/fleet-paths-calm-row4-dark.png)

**Fleet row path list expanded (friends-and-family-billing): Calm scenario, light theme**

![Fleet row path list expanded (friends-and-family-billing): Calm scenario, light theme](images/fleet/fleet-paths-calm-row4-light.png)

## overview

**Whole Cockpit page at 1x (layout map): Boulder hit scenario, dark theme**

![Whole Cockpit page at 1x (layout map): Boulder hit scenario, dark theme](images/overview/cockpit-boulder-dark.png)

**Whole Cockpit page at 1x (layout map): Boulder hit scenario, light theme**

![Whole Cockpit page at 1x (layout map): Boulder hit scenario, light theme](images/overview/cockpit-boulder-light.png)

**Whole Cockpit page at 1x (layout map): Speed bumps ahead scenario, dark theme**

![Whole Cockpit page at 1x (layout map): Speed bumps ahead scenario, dark theme](images/overview/cockpit-bumps-dark.png)

**Whole Cockpit page at 1x (layout map): Speed bumps ahead scenario, light theme**

![Whole Cockpit page at 1x (layout map): Speed bumps ahead scenario, light theme](images/overview/cockpit-bumps-light.png)

**Whole Cockpit page at 1x (layout map): Busy scenario, dark theme**

![Whole Cockpit page at 1x (layout map): Busy scenario, dark theme](images/overview/cockpit-busy-dark.png)

**Whole Cockpit page at 1x (layout map): Busy scenario, light theme**

![Whole Cockpit page at 1x (layout map): Busy scenario, light theme](images/overview/cockpit-busy-light.png)

**Whole Cockpit page at 1x (layout map): Calm scenario, dark theme**

![Whole Cockpit page at 1x (layout map): Calm scenario, dark theme](images/overview/cockpit-calm-dark.png)

**Whole Cockpit page at 1x (layout map): Calm scenario, light theme**

![Whole Cockpit page at 1x (layout map): Calm scenario, light theme](images/overview/cockpit-calm-light.png)

## phone

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 1 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 1 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part01of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 2 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 2 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part02of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 3 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 3 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part03of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 4 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 4 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part04of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 5 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 5 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part05of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 6 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 6 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part06of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 7 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 7 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part07of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 8 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 8 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part08of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 9 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, dark theme (part 9 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-dark-part09of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 1 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 1 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part01of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 2 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 2 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part02of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 3 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 3 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part03of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 4 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 4 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part04of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 5 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 5 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part05of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 6 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 6 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part06of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 7 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 7 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part07of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 8 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 8 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part08of9.png)

**Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 9 of 9, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Boulder hit scenario, light theme (part 9 of 9, top to bottom, 40 px overlap)](images/phone/cockpit-390px-boulder-light-part09of9.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 1 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 1 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part01of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 2 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 2 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part02of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 3 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 3 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part03of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 4 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 4 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part04of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 5 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 5 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part05of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 6 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 6 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part06of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 7 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 7 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part07of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 8 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, dark theme (part 8 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-dark-part08of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 1 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 1 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part01of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 2 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 2 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part02of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 3 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 3 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part03of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 4 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 4 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part04of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 5 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 5 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part05of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 6 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 6 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part06of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 7 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 7 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part07of8.png)

**Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 8 of 8, top to bottom, 40 px overlap)**

![Phone width (390 px): whole Cockpit page, Speed bumps ahead scenario, light theme (part 8 of 8, top to bottom, 40 px overlap)](images/phone/cockpit-390px-bumps-light-part08of8.png)

## prs

**Open PRs, "all budgets" expanded on row 1 (Conflicts mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 1 (Conflicts mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row1-dark.png)

**Open PRs, "all budgets" expanded on row 1 (Conflicts mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 1 (Conflicts mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row1-light.png)

**Open PRs, "all budgets" expanded on row 10 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 10 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row10-dark.png)

**Open PRs, "all budgets" expanded on row 10 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 10 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row10-light.png)

**Open PRs, "all budgets" expanded on row 2 (Budget spent mergepath #1584 fix(codex-request): blocking-review budge); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 2 (Budget spent mergepath #1584 fix(codex-request): blocking-review budge); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row2-dark.png)

**Open PRs, "all budgets" expanded on row 2 (Budget spent mergepath #1584 fix(codex-request): blocking-review budge); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 2 (Budget spent mergepath #1584 fix(codex-request): blocking-review budge); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row2-light.png)

**Open PRs, "all budgets" expanded on row 3 (Human stop nathanpaynedotcom #137 feat(blog): reading time and series ); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 3 (Human stop nathanpaynedotcom #137 feat(blog): reading time and series ); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row3-dark.png)

**Open PRs, "all budgets" expanded on row 3 (Human stop nathanpaynedotcom #137 feat(blog): reading time and series ); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 3 (Human stop nathanpaynedotcom #137 feat(blog): reading time and series ); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row3-light.png)

**Open PRs, "all budgets" expanded on row 4 (Unstable overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 4 (Unstable overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row4-dark.png)

**Open PRs, "all budgets" expanded on row 4 (Unstable overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 4 (Unstable overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row4-light.png)

**Open PRs, "all budgets" expanded on row 5 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 5 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row5-dark.png)

**Open PRs, "all budgets" expanded on row 5 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 5 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row5-light.png)

**Open PRs, "all budgets" expanded on row 6 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 6 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row6-dark.png)

**Open PRs, "all budgets" expanded on row 6 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 6 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row6-light.png)

**Open PRs, "all budgets" expanded on row 7 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 7 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row7-dark.png)

**Open PRs, "all budgets" expanded on row 7 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 7 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row7-light.png)

**Open PRs, "all budgets" expanded on row 8 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 8 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row8-dark.png)

**Open PRs, "all budgets" expanded on row 8 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 8 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row8-light.png)

**Open PRs, "all budgets" expanded on row 9 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Boulder hit scenario, dark theme**

![Open PRs, "all budgets" expanded on row 9 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Boulder hit scenario, dark theme](images/prs/budgets-expanded-boulder-row9-dark.png)

**Open PRs, "all budgets" expanded on row 9 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Boulder hit scenario, light theme**

![Open PRs, "all budgets" expanded on row 9 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Boulder hit scenario, light theme](images/prs/budgets-expanded-boulder-row9-light.png)

**Open PRs, "all budgets" expanded on row 1 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Speed bumps ahead scenario, dark theme**

![Open PRs, "all budgets" expanded on row 1 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Speed bumps ahead scenario, dark theme](images/prs/budgets-expanded-bumps-row1-dark.png)

**Open PRs, "all budgets" expanded on row 1 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Speed bumps ahead scenario, light theme**

![Open PRs, "all budgets" expanded on row 1 (Unaccounted mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Speed bumps ahead scenario, light theme](images/prs/budgets-expanded-bumps-row1-light.png)

**Open PRs, "all budgets" expanded on row 2 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Speed bumps ahead scenario, dark theme**

![Open PRs, "all budgets" expanded on row 2 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Speed bumps ahead scenario, dark theme](images/prs/budgets-expanded-bumps-row2-dark.png)

**Open PRs, "all budgets" expanded on row 2 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Speed bumps ahead scenario, light theme**

![Open PRs, "all budgets" expanded on row 2 (Budget near friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Speed bumps ahead scenario, light theme](images/prs/budgets-expanded-bumps-row2-light.png)

**Open PRs, "all budgets" expanded on row 3 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Speed bumps ahead scenario, dark theme**

![Open PRs, "all budgets" expanded on row 3 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Speed bumps ahead scenario, dark theme](images/prs/budgets-expanded-bumps-row3-dark.png)

**Open PRs, "all budgets" expanded on row 3 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Speed bumps ahead scenario, light theme**

![Open PRs, "all budgets" expanded on row 3 (Rate-limited tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Speed bumps ahead scenario, light theme](images/prs/budgets-expanded-bumps-row3-light.png)

**Open PRs, "all budgets" expanded on row 4 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, dark theme**

![Open PRs, "all budgets" expanded on row 4 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, dark theme](images/prs/budgets-expanded-bumps-row4-dark.png)

**Open PRs, "all budgets" expanded on row 4 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, light theme**

![Open PRs, "all budgets" expanded on row 4 (Behind main swipewatch #88 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, light theme](images/prs/budgets-expanded-bumps-row4-light.png)

**Open PRs, "all budgets" expanded on row 5 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Speed bumps ahead scenario, dark theme**

![Open PRs, "all budgets" expanded on row 5 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Speed bumps ahead scenario, dark theme](images/prs/budgets-expanded-bumps-row5-dark.png)

**Open PRs, "all budgets" expanded on row 5 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Speed bumps ahead scenario, light theme**

![Open PRs, "all budgets" expanded on row 5 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Speed bumps ahead scenario, light theme](images/prs/budgets-expanded-bumps-row5-light.png)

**Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, dark theme**

![Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, dark theme](images/prs/budgets-expanded-bumps-row6-dark.png)

**Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, light theme**

![Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Speed bumps ahead scenario, light theme](images/prs/budgets-expanded-bumps-row6-light.png)

**Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row1-dark.png)

**Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row1-light.png)

**Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row2-dark.png)

**Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row2-light.png)

**Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row3-dark.png)

**Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row3-light.png)

**Open PRs, "all budgets" expanded on row 4 (In progress overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 4 (In progress overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row4-dark.png)

**Open PRs, "all budgets" expanded on row 4 (In progress overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 4 (In progress overridebroadway #41 fix(auth): session cookie SameSite); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row4-light.png)

**Open PRs, "all budgets" expanded on row 5 (In progress nathanpaynedotcom #137 feat(blog): reading time and series); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 5 (In progress nathanpaynedotcom #137 feat(blog): reading time and series); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row5-dark.png)

**Open PRs, "all budgets" expanded on row 5 (In progress nathanpaynedotcom #137 feat(blog): reading time and series); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 5 (In progress nathanpaynedotcom #137 feat(blog): reading time and series); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row5-light.png)

**Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row6-dark.png)

**Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 6 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row6-light.png)

**Open PRs, "all budgets" expanded on row 7 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 7 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row7-dark.png)

**Open PRs, "all budgets" expanded on row 7 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 7 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row7-light.png)

**Open PRs, "all budgets" expanded on row 8 (Draft mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Busy scenario, dark theme**

![Open PRs, "all budgets" expanded on row 8 (Draft mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Busy scenario, dark theme](images/prs/budgets-expanded-busy-row8-dark.png)

**Open PRs, "all budgets" expanded on row 8 (Draft mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Busy scenario, light theme**

![Open PRs, "all budgets" expanded on row 8 (Draft mergepath #1601 docs(agents): cockpit operating notes); other rows hidden for the crop: Busy scenario, light theme](images/prs/budgets-expanded-busy-row8-light.png)

**Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Calm scenario, dark theme**

![Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Calm scenario, dark theme](images/prs/budgets-expanded-calm-row1-dark.png)

**Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Calm scenario, light theme**

![Open PRs, "all budgets" expanded on row 1 (In progress mergepath #1598 feat(cockpit): server shell, SSE stream an); other rows hidden for the crop: Calm scenario, light theme](images/prs/budgets-expanded-calm-row1-light.png)

**Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Calm scenario, dark theme**

![Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Calm scenario, dark theme](images/prs/budgets-expanded-calm-row2-dark.png)

**Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Calm scenario, light theme**

![Open PRs, "all budgets" expanded on row 2 (In progress mergepath #1599 test(cockpit): hermetic server suite and c); other rows hidden for the crop: Calm scenario, light theme](images/prs/budgets-expanded-calm-row2-light.png)

**Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Calm scenario, dark theme**

![Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Calm scenario, dark theme](images/prs/budgets-expanded-calm-row3-dark.png)

**Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Calm scenario, light theme**

![Open PRs, "all budgets" expanded on row 3 (In progress friends-and-family-billing #19 fix(invoice): proration rou); other rows hidden for the crop: Calm scenario, light theme](images/prs/budgets-expanded-calm-row3-light.png)

**Open PRs, "all budgets" expanded on row 4 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Calm scenario, dark theme**

![Open PRs, "all budgets" expanded on row 4 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Calm scenario, dark theme](images/prs/budgets-expanded-calm-row4-dark.png)

**Open PRs, "all budgets" expanded on row 4 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Calm scenario, light theme**

![Open PRs, "all budgets" expanded on row 4 (Clean matchline #212 sync: review policy and ci kit 2026-10-01); other rows hidden for the crop: Calm scenario, light theme](images/prs/budgets-expanded-calm-row4-light.png)

**Open PRs, "all budgets" expanded on row 5 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Calm scenario, dark theme**

![Open PRs, "all budgets" expanded on row 5 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Calm scenario, dark theme](images/prs/budgets-expanded-calm-row5-dark.png)

**Open PRs, "all budgets" expanded on row 5 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Calm scenario, light theme**

![Open PRs, "all budgets" expanded on row 5 (Clean tadlockpsychiatry #7 chore: bump ci kit to hub 9a8fcdf); other rows hidden for the crop: Calm scenario, light theme](images/prs/budgets-expanded-calm-row5-light.png)

**Open PRs filtered to the hub (filter chip "mergepath (hub)" on): Busy scenario, dark theme**

![Open PRs filtered to the hub (filter chip "mergepath (hub)" on): Busy scenario, dark theme](images/prs/filter-hub-busy-dark.png)

**Open PRs filtered to the hub (filter chip "mergepath (hub)" on): Busy scenario, light theme**

![Open PRs filtered to the hub (filter chip "mergepath (hub)" on): Busy scenario, light theme](images/prs/filter-hub-busy-light.png)

**Simulate a merge, 450 ms in: Merged ribbon popping, row glow and confetti drift (Calm, dark)**

![Simulate a merge, 450 ms in: Merged ribbon popping, row glow and confetti drift (Calm, dark)](images/prs/merge-reward-450ms-calm-dark.png)

**Simulate a merge, 450 ms in: Merged ribbon popping, row glow and confetti drift (Calm, light)**

![Simulate a merge, 450 ms in: Merged ribbon popping, row glow and confetti drift (Calm, light)](images/prs/merge-reward-450ms-calm-light.png)

**Simulate a merge, 1.6 s in: ribbon settled, glow fading; the row leaves after 7 s (Calm, dark)**

![Simulate a merge, 1.6 s in: ribbon settled, glow fading; the row leaves after 7 s (Calm, dark)](images/prs/merge-reward-settled-calm-dark.png)

**Simulate a merge, 1.6 s in: ribbon settled, glow fading; the row leaves after 7 s (Calm, light)**

![Simulate a merge, 1.6 s in: ribbon settled, glow fading; the row leaves after 7 s (Calm, light)](images/prs/merge-reward-settled-calm-light.png)

**Simulate a merge, after 8 s: merged row removed and summary recounted (Calm, dark)**

![Simulate a merge, after 8 s: merged row removed and summary recounted (Calm, dark)](images/prs/merge-row-removed-calm-dark.png)

**Simulate a merge, after 8 s: merged row removed and summary recounted (Calm, light)**

![Simulate a merge, after 8 s: merged row removed and summary recounted (Calm, light)](images/prs/merge-row-removed-calm-light.png)

**Open PRs panel: Boulder hit scenario, dark theme**

![Open PRs panel: Boulder hit scenario, dark theme](images/prs/open-prs-boulder-dark.png)

**Open PRs panel: Boulder hit scenario, light theme**

![Open PRs panel: Boulder hit scenario, light theme](images/prs/open-prs-boulder-light.png)

**Open PRs panel: Speed bumps ahead scenario, dark theme**

![Open PRs panel: Speed bumps ahead scenario, dark theme](images/prs/open-prs-bumps-dark.png)

**Open PRs panel: Speed bumps ahead scenario, light theme**

![Open PRs panel: Speed bumps ahead scenario, light theme](images/prs/open-prs-bumps-light.png)

**Open PRs panel: Busy scenario, dark theme**

![Open PRs panel: Busy scenario, dark theme](images/prs/open-prs-busy-dark.png)

**Open PRs panel: Busy scenario, light theme**

![Open PRs panel: Busy scenario, light theme](images/prs/open-prs-busy-light.png)

**Open PRs panel: Calm scenario, dark theme**

![Open PRs panel: Calm scenario, dark theme](images/prs/open-prs-calm-dark.png)

**Open PRs panel: Calm scenario, light theme**

![Open PRs panel: Calm scenario, light theme](images/prs/open-prs-calm-light.png)

## shell

**Shell header (connection, GitHub API meter, Updated chips): Boulder hit scenario, dark theme**

![Shell header (connection, GitHub API meter, Updated chips): Boulder hit scenario, dark theme](images/shell/header-boulder-dark.png)

**Shell header (connection, GitHub API meter, Updated chips): Boulder hit scenario, light theme**

![Shell header (connection, GitHub API meter, Updated chips): Boulder hit scenario, light theme](images/shell/header-boulder-light.png)

**Shell header (connection, GitHub API meter, Updated chips): Speed bumps ahead scenario, dark theme**

![Shell header (connection, GitHub API meter, Updated chips): Speed bumps ahead scenario, dark theme](images/shell/header-bumps-dark.png)

**Shell header (connection, GitHub API meter, Updated chips): Speed bumps ahead scenario, light theme**

![Shell header (connection, GitHub API meter, Updated chips): Speed bumps ahead scenario, light theme](images/shell/header-bumps-light.png)

**Shell header (connection, GitHub API meter, Updated chips): Busy scenario, dark theme**

![Shell header (connection, GitHub API meter, Updated chips): Busy scenario, dark theme](images/shell/header-busy-dark.png)

**Shell header (connection, GitHub API meter, Updated chips): Busy scenario, light theme**

![Shell header (connection, GitHub API meter, Updated chips): Busy scenario, light theme](images/shell/header-busy-light.png)

**Shell header (connection, GitHub API meter, Updated chips): Calm scenario, dark theme**

![Shell header (connection, GitHub API meter, Updated chips): Calm scenario, dark theme](images/shell/header-calm-dark.png)

**Shell header (connection, GitHub API meter, Updated chips): Calm scenario, light theme**

![Shell header (connection, GitHub API meter, Updated chips): Calm scenario, light theme](images/shell/header-calm-light.png)

**Prototype controls strip (not product): Calm scenario, dark theme**

![Prototype controls strip (not product): Calm scenario, dark theme](images/shell/prototype-controls-calm-dark.png)

**Prototype controls strip (not product): Calm scenario, light theme**

![Prototype controls strip (not product): Calm scenario, light theme](images/shell/prototype-controls-calm-light.png)

**Road ahead strip and list: Boulder hit scenario, dark theme**

![Road ahead strip and list: Boulder hit scenario, dark theme](images/shell/road-ahead-boulder-dark.png)

**Road ahead strip and list: Boulder hit scenario, light theme**

![Road ahead strip and list: Boulder hit scenario, light theme](images/shell/road-ahead-boulder-light.png)

**Road ahead strip and list: Speed bumps ahead scenario, dark theme**

![Road ahead strip and list: Speed bumps ahead scenario, dark theme](images/shell/road-ahead-bumps-dark.png)

**Road ahead strip and list: Speed bumps ahead scenario, light theme**

![Road ahead strip and list: Speed bumps ahead scenario, light theme](images/shell/road-ahead-bumps-light.png)

**Road ahead strip and list: Busy scenario, dark theme**

![Road ahead strip and list: Busy scenario, dark theme](images/shell/road-ahead-busy-dark.png)

**Road ahead strip and list: Busy scenario, light theme**

![Road ahead strip and list: Busy scenario, light theme](images/shell/road-ahead-busy-light.png)

**Road ahead strip and list: Calm scenario, dark theme**

![Road ahead strip and list: Calm scenario, dark theme](images/shell/road-ahead-calm-dark.png)

**Road ahead strip and list: Calm scenario, light theme**

![Road ahead strip and list: Calm scenario, light theme](images/shell/road-ahead-calm-light.png)

## spec

**Design spec section "a11y", dark theme**

![Design spec section "a11y", dark theme](images/spec/spec-a11y-dark.png)

**Design spec section "a11y", light theme**

![Design spec section "a11y", light theme](images/spec/spec-a11y-light.png)

**Design spec section "color", dark theme (part 1 of 2, 40 px overlap)**

![Design spec section "color", dark theme (part 1 of 2, 40 px overlap)](images/spec/spec-color-dark-part1of2.png)

**Design spec section "color", dark theme (part 2 of 2, 40 px overlap)**

![Design spec section "color", dark theme (part 2 of 2, 40 px overlap)](images/spec/spec-color-dark-part2of2.png)

**Design spec section "color", light theme (part 1 of 2, 40 px overlap)**

![Design spec section "color", light theme (part 1 of 2, 40 px overlap)](images/spec/spec-color-light-part1of2.png)

**Design spec section "color", light theme (part 2 of 2, 40 px overlap)**

![Design spec section "color", light theme (part 2 of 2, 40 px overlap)](images/spec/spec-color-light-part2of2.png)

**Design spec section "components", dark theme (part 1 of 2, 40 px overlap)**

![Design spec section "components", dark theme (part 1 of 2, 40 px overlap)](images/spec/spec-components-dark-part1of2.png)

**Design spec section "components", dark theme (part 2 of 2, 40 px overlap)**

![Design spec section "components", dark theme (part 2 of 2, 40 px overlap)](images/spec/spec-components-dark-part2of2.png)

**Design spec section "components", light theme (part 1 of 2, 40 px overlap)**

![Design spec section "components", light theme (part 1 of 2, 40 px overlap)](images/spec/spec-components-light-part1of2.png)

**Design spec section "components", light theme (part 2 of 2, 40 px overlap)**

![Design spec section "components", light theme (part 2 of 2, 40 px overlap)](images/spec/spec-components-light-part2of2.png)

**Design spec section "decisions", dark theme**

![Design spec section "decisions", dark theme](images/spec/spec-decisions-dark.png)

**Design spec section "decisions", light theme**

![Design spec section "decisions", light theme](images/spec/spec-decisions-light.png)

**Design spec section "i1586", dark theme**

![Design spec section "i1586", dark theme](images/spec/spec-i1586-dark.png)

**Design spec section "i1586", light theme**

![Design spec section "i1586", light theme](images/spec/spec-i1586-light.png)

**Design spec section "i1587", dark theme**

![Design spec section "i1587", dark theme](images/spec/spec-i1587-dark.png)

**Design spec section "i1587", light theme**

![Design spec section "i1587", light theme](images/spec/spec-i1587-light.png)

**Design spec section "i1588", dark theme**

![Design spec section "i1588", dark theme](images/spec/spec-i1588-dark.png)

**Design spec section "i1588", light theme**

![Design spec section "i1588", light theme](images/spec/spec-i1588-light.png)

**Design spec section "i1589", dark theme**

![Design spec section "i1589", dark theme](images/spec/spec-i1589-dark.png)

**Design spec section "i1589", light theme**

![Design spec section "i1589", light theme](images/spec/spec-i1589-light.png)

**Design spec section "i1590", dark theme**

![Design spec section "i1590", dark theme](images/spec/spec-i1590-dark.png)

**Design spec section "i1590", light theme**

![Design spec section "i1590", light theme](images/spec/spec-i1590-light.png)

**Design spec section "i1591", dark theme**

![Design spec section "i1591", dark theme](images/spec/spec-i1591-dark.png)

**Design spec section "i1591", light theme**

![Design spec section "i1591", light theme](images/spec/spec-i1591-light.png)

**Design spec section "i1592", dark theme**

![Design spec section "i1592", dark theme](images/spec/spec-i1592-dark.png)

**Design spec section "i1592", light theme**

![Design spec section "i1592", light theme](images/spec/spec-i1592-light.png)

**Design spec section "i1593", dark theme**

![Design spec section "i1593", dark theme](images/spec/spec-i1593-dark.png)

**Design spec section "i1593", light theme**

![Design spec section "i1593", light theme](images/spec/spec-i1593-light.png)

**Design spec section "i1594", dark theme**

![Design spec section "i1594", dark theme](images/spec/spec-i1594-dark.png)

**Design spec section "i1594", light theme**

![Design spec section "i1594", light theme](images/spec/spec-i1594-light.png)

**Design spec section "language", dark theme (part 1 of 2, 40 px overlap)**

![Design spec section "language", dark theme (part 1 of 2, 40 px overlap)](images/spec/spec-language-dark-part1of2.png)

**Design spec section "language", dark theme (part 2 of 2, 40 px overlap)**

![Design spec section "language", dark theme (part 2 of 2, 40 px overlap)](images/spec/spec-language-dark-part2of2.png)

**Design spec section "language", light theme (part 1 of 2, 40 px overlap)**

![Design spec section "language", light theme (part 1 of 2, 40 px overlap)](images/spec/spec-language-light-part1of2.png)

**Design spec section "language", light theme (part 2 of 2, 40 px overlap)**

![Design spec section "language", light theme (part 2 of 2, 40 px overlap)](images/spec/spec-language-light-part2of2.png)

**Design spec section "motion", dark theme**

![Design spec section "motion", dark theme](images/spec/spec-motion-dark.png)

**Design spec section "motion", light theme**

![Design spec section "motion", light theme](images/spec/spec-motion-light.png)

**Design spec section "overview", dark theme**

![Design spec section "overview", dark theme](images/spec/spec-overview-dark.png)

**Design spec section "overview", light theme**

![Design spec section "overview", light theme](images/spec/spec-overview-light.png)

**Design spec section "precedence", dark theme**

![Design spec section "precedence", dark theme](images/spec/spec-precedence-dark.png)

**Design spec section "precedence", light theme**

![Design spec section "precedence", light theme](images/spec/spec-precedence-light.png)

## status-language

**Status language sheet artboard, light half on the left and dark half on the right (part 1 of 2, 40 px overlap)**

![Status language sheet artboard, light half on the left and dark half on the right (part 1 of 2, 40 px overlap)](images/status-language/status-language-sheet-part1of2.png)

**Status language sheet artboard, light half on the left and dark half on the right (part 2 of 2, 40 px overlap)**

![Status language sheet artboard, light half on the left and dark half on the right (part 2 of 2, 40 px overlap)](images/status-language/status-language-sheet-part2of2.png)

## sync

**Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, dark theme)**

![Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, dark theme)](images/sync/all-boulder-1-preview-dark.png)

**Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, light theme)**

![Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, light theme)](images/sync/all-boulder-1-preview-light.png)

**Sync all: step 1 Preview, shown over the dimmed page (Boulder hit scenario, dark theme)**

![Sync all: step 1 Preview, shown over the dimmed page (Boulder hit scenario, dark theme)](images/sync/all-boulder-1-preview-viewport-dark.png)

**Sync all: step 1 Preview, shown over the dimmed page (Boulder hit scenario, light theme)**

![Sync all: step 1 Preview, shown over the dimmed page (Boulder hit scenario, light theme)](images/sync/all-boulder-1-preview-viewport-light.png)

**Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Boulder hit scenario, dark theme)**

![Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Boulder hit scenario, dark theme)](images/sync/all-boulder-2-confirm-dark.png)

**Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Boulder hit scenario, light theme)**

![Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Boulder hit scenario, light theme)](images/sync/all-boulder-2-confirm-light.png)

**Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Boulder hit scenario, dark theme)**

![Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Boulder hit scenario, dark theme)](images/sync/all-boulder-2b-confirm-acked-dark.png)

**Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Boulder hit scenario, light theme)**

![Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Boulder hit scenario, light theme)](images/sync/all-boulder-2b-confirm-acked-light.png)

**Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, dark theme)**

![Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, dark theme)](images/sync/all-boulder-3-running-early-dark.png)

**Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, light theme)**

![Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, light theme)](images/sync/all-boulder-3-running-early-light.png)

**Sync all: step 3 Run, later stages (Boulder hit scenario, dark theme)**

![Sync all: step 3 Run, later stages (Boulder hit scenario, dark theme)](images/sync/all-boulder-3-running-late-dark.png)

**Sync all: step 3 Run, later stages (Boulder hit scenario, light theme)**

![Sync all: step 3 Run, later stages (Boulder hit scenario, light theme)](images/sync/all-boulder-3-running-late-light.png)

**Sync all: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, dark theme)**

![Sync all: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, dark theme)](images/sync/all-boulder-4-done-dark.png)

**Sync all: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, light theme)**

![Sync all: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, light theme)](images/sync/all-boulder-4-done-light.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, dark theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, dark theme)](images/sync/all-boulder-5-fleet-after-dark.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, light theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, light theme)](images/sync/all-boulder-5-fleet-after-light.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 1 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 1 of 2, 40 px overlap)](images/sync/all-boulder-6-prs-after-dark-part1of2.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 2 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 2 of 2, 40 px overlap)](images/sync/all-boulder-6-prs-after-dark-part2of2.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 1 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 1 of 2, 40 px overlap)](images/sync/all-boulder-6-prs-after-light-part1of2.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 2 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 2 of 2, 40 px overlap)](images/sync/all-boulder-6-prs-after-light-part2of2.png)

**Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, dark theme)**

![Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-1-preview-dark.png)

**Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, light theme)**

![Sync all: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-1-preview-light.png)

**Sync all: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, dark theme)**

![Sync all: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-1-preview-viewport-dark.png)

**Sync all: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, light theme)**

![Sync all: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-1-preview-viewport-light.png)

**Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Speed bumps ahead scenario, dark theme)**

![Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-2-confirm-dark.png)

**Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Speed bumps ahead scenario, light theme)**

![Sync all: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged; the ahead-of-hub acknowledgement is unchecked, so Start sync is disabled (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-2-confirm-light.png)

**Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Speed bumps ahead scenario, dark theme)**

![Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-2b-confirm-acked-dark.png)

**Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Speed bumps ahead scenario, light theme)**

![Sync all: step 2 Confirm with the ahead-of-hub acknowledgement checked, Start sync enabled (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-2b-confirm-acked-light.png)

**Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, dark theme)**

![Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-3-running-early-dark.png)

**Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, light theme)**

![Sync all: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-3-running-early-light.png)

**Sync all: step 3 Run, later stages (Speed bumps ahead scenario, dark theme)**

![Sync all: step 3 Run, later stages (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-3-running-late-dark.png)

**Sync all: step 3 Run, later stages (Speed bumps ahead scenario, light theme)**

![Sync all: step 3 Run, later stages (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-3-running-late-light.png)

**Sync all: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, dark theme)**

![Sync all: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-4-done-dark.png)

**Sync all: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, light theme)**

![Sync all: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-4-done-light.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, dark theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-5-fleet-after-dark.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, light theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-5-fleet-after-light.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, dark theme)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, dark theme)](images/sync/all-bumps-6-prs-after-dark.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, light theme)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, light theme)](images/sync/all-bumps-6-prs-after-light.png)

**Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, dark theme)](images/sync/single-boulder-1-preview-dark.png)

**Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Boulder hit scenario, light theme)](images/sync/single-boulder-1-preview-light.png)

**Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Boulder hit scenario, dark theme)](images/sync/single-boulder-1-preview-viewport-dark.png)

**Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Boulder hit scenario, light theme)](images/sync/single-boulder-1-preview-viewport-light.png)

**Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Boulder hit scenario, dark theme)](images/sync/single-boulder-1b-preview-recreate-dark.png)

**Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Boulder hit scenario, light theme)](images/sync/single-boulder-1b-preview-recreate-light.png)

**Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Boulder hit scenario, dark theme)](images/sync/single-boulder-2-confirm-dark.png)

**Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Boulder hit scenario, light theme)](images/sync/single-boulder-2-confirm-light.png)

**Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Boulder hit scenario, dark theme)](images/sync/single-boulder-2a-confirm-all-skipped-dark.png)

**Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Boulder hit scenario, light theme)](images/sync/single-boulder-2a-confirm-all-skipped-light.png)

**Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, dark theme)](images/sync/single-boulder-3-running-early-dark.png)

**Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Boulder hit scenario, light theme)](images/sync/single-boulder-3-running-early-light.png)

**Per-repo Sync on swipewatch: step 3 Run, later stages (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: step 3 Run, later stages (Boulder hit scenario, dark theme)](images/sync/single-boulder-3-running-late-dark.png)

**Per-repo Sync on swipewatch: step 3 Run, later stages (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: step 3 Run, later stages (Boulder hit scenario, light theme)](images/sync/single-boulder-3-running-late-light.png)

**Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, dark theme)**

![Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, dark theme)](images/sync/single-boulder-4-done-dark.png)

**Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, light theme)**

![Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Boulder hit scenario, light theme)](images/sync/single-boulder-4-done-light.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, dark theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, dark theme)](images/sync/single-boulder-5-fleet-after-dark.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, light theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Boulder hit scenario, light theme)](images/sync/single-boulder-5-fleet-after-light.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 1 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 1 of 2, 40 px overlap)](images/sync/single-boulder-6-prs-after-dark-part1of2.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 2 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, dark theme) (part 2 of 2, 40 px overlap)](images/sync/single-boulder-6-prs-after-dark-part2of2.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 1 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 1 of 2, 40 px overlap)](images/sync/single-boulder-6-prs-after-light-part1of2.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 2 of 2, 40 px overlap)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Boulder hit scenario, light theme) (part 2 of 2, 40 px overlap)](images/sync/single-boulder-6-prs-after-light-part2of2.png)

**Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-1-preview-dark.png)

**Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: step 1 Preview. Dry-run command, pre-checks, per-repo plan with path classes; a repo with an open sync PR defaults to Skip; an ahead-of-hub repo gets a warning (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-1-preview-light.png)

**Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-1-preview-viewport-dark.png)

**Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: step 1 Preview, shown over the dimmed page (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-1-preview-viewport-light.png)

**Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-1b-preview-recreate-dark.png)

**Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: back on step 1 with Recreate chosen for the repo that already has an open sync PR (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-1b-preview-recreate-light.png)

**Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-2-confirm-dark.png)

**Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: step 2 Confirm. Runs as the author through gh-as-author.sh, one sync at a time, logged (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-2-confirm-light.png)

**Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-2a-confirm-all-skipped-dark.png)

**Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: step 2 Confirm with every target on Skip, so Start sync stays disabled (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-2a-confirm-all-skipped-light.png)

**Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-3-running-early-dark.png)

**Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: step 3 Run, early. Per-repo stage rails (fetch, diff, branch, commit, PR) and the streamed log (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-3-running-early-light.png)

**Per-repo Sync on swipewatch: step 3 Run, later stages (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: step 3 Run, later stages (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-3-running-late-dark.png)

**Per-repo Sync on swipewatch: step 3 Run, later stages (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: step 3 Run, later stages (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-3-running-late-light.png)

**Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, dark theme)**

![Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-4-done-dark.png)

**Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, light theme)**

![Per-repo Sync on swipewatch: Done. Check burst and one PR chip per new sync PR (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-4-done-light.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, dark theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-5-fleet-after-dark.png)

**Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, light theme)**

![Fleet panel right after the sync: just-synced row glow, Sync PR open (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-5-fleet-after-light.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, dark theme)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, dark theme)](images/sync/single-bumps-6-prs-after-dark.png)

**Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, light theme)**

![Open PRs right after the sync: each new sync PR enters as a fresh row (Speed bumps ahead scenario, light theme)](images/sync/single-bumps-6-prs-after-light.png)
