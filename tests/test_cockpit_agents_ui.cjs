"use strict";
const assert = require("node:assert/strict");
const {test} = require("node:test");
const A = require("../mergepath/cockpit/assets/agents.js");
const now = Date.parse("2026-10-03T12:00:00Z") / 1000;
function row(overrides = {}) {return {id: "owner/hub:p4b-one", run_id: "p4b-one", repo: "owner/hub", pr: "1", provider: "codex", conflict: false,
  verdict: "CHANGES_REQUESTED", elapsed_seconds: 30, started_at_epoch: now, day: "2026-10-03", tokens: {total: 100, input: null, output: null, cache_creation: null, cache_read: null, reasoning: null, cost_usd: null},
  findings: {P0: 0, P1: 1, P2: 0, P3: 0}, cost: {kind: "bounded_estimate", usd: null, low_usd: .01, high_usd: .3, source: "prices.json"}, ...overrides};}
function envelope(rows = [row()], overrides = {}) {return {observed_at: now, stale: false, data: {schema: "cockpit-agents/v1", hasObservations: true, history_complete: true, history: rows, ...overrides}};}
test("history projection preserves repository scope, missing data and stale evidence", () => {
  const data = envelope([row(), row({id: "two", repo: "owner/other"})]);
  assert.equal(A.projectHistory(data, "owner/hub", now).rows.length, 1);
  assert.equal(A.projectHistory(envelope([], {hasObservations: true}), null, now).label, "No recorded runs");
  assert.equal(A.projectHistory(envelope([], {hasObservations: false}), null, now).hasObservations, false);
  assert.throws(() => A.projectHistory({data: {history: []}}, null, now));
  assert.equal(A.projectHistory({...data, stale: true}, null, now).rows.length, 2);
});
test("incomplete observations withdraw coverage without rejecting readable history", () => {
  const partial = A.projectHistory(envelope([row()], {history_complete: false}), null, now);
  assert.equal(partial.coverageValid, false); assert.equal(partial.hasObservations, true); assert.equal(partial.rows.length, 1);
  assert.equal(A.projectHistory(envelope([], {history_complete: false}), null, now).label, "History coverage incomplete");
  const unavailable = A.projectHistory(envelope([], {hasObservations: false, history_complete: false}), null, now);
  assert.equal(unavailable.coverageValid, false); assert.equal(unavailable.label, "History unavailable");
  assert.equal(A.projectHistory(envelope([]), null, now).coverageValid, true);
  assert.equal(A.validateData(envelope([], {history_complete: "yes"}).data), false);
});
test("shared registry preserves history completeness and unavailable observations", {skip: !process.env.COCKPIT_SHARED_APP}, () => {
  const {PanelRegistry} = require(process.env.COCKPIT_SHARED_APP);
  const registry = new PanelRegistry(); registry.register("history", "agents", A.projectHistory);
  const snapshot = data => ({repositories: [{repo: "owner/hub"}], sources: {agents: data}});
  const partial = registry.project(snapshot(envelope([row()], {history_complete: false})), null, now);
  assert.equal(partial.freshPanels, 0); assert.equal(partial.partialPanels, 1); assert.equal(partial.invalidPanels, 0);
  assert.equal(partial.models.history.rows.length, 1); assert.equal(partial.models.history.observed, true);
  const unavailable = registry.project(snapshot(envelope([], {hasObservations: false, history_complete: false})), null, now);
  assert.equal(unavailable.observedPanels, 0); assert.equal(unavailable.models.history.observed, true);
  const empty = registry.project(snapshot(envelope([])), null, now);
  assert.equal(empty.observedPanels, 1); assert.equal(empty.freshPanels, 1);
});
test("never invents Codex split or exact total-only cost", () => {
  const value = row(); assert.match(A.tokenLabel(value), /100 total/);
  assert.match(A.costLabel(value.cost), /0.01.*0.30 est.*bound/);
  assert.equal(A.aggregateCosts([value]).low, .01); assert.equal(A.aggregateCosts([value]).high, .3);
  assert.match(A.aggregateLabel([value]), /est/);
});
test("reported, mixed, partial and unavailable sums remain explicitly distinguished", () => {
  const reported = row({cost: {kind: "reported", usd: 1, low_usd: null, high_usd: null}});
  const missing = row({cost: {kind: "unavailable", usd: null, low_usd: null, high_usd: null}});
  assert.equal(A.aggregateLabel([reported]), "$1.00 reported");
  assert.match(A.aggregateLabel([reported, missing]), /measured 1\/2/);
  assert.match(A.aggregateLabel([reported, row()]), /est/);
  assert.equal(A.aggregateLabel([missing]), "Cost unavailable");
});
test("seven-day UTC chart, undated legacy rows, PR and provider filters", () => {
  const values = [row(), row({id: "old", day: "2026-08-01"}), row({id: "unknown", day: null}), row({id: "claude", provider: "claude", pr: "2"})];
  const view = A.historyView(values, now);
  assert.equal(view.chart.length, 7); assert.equal(view.chart[0].day, "2026-09-27"); assert.equal(view.rows.length, 3); assert.equal(view.undated, 1);
  assert.equal(A.historyView(values, now, {allDates: true}).rows.length, 4);
  assert.equal(A.historyView(values, now, {pr: "owner/hub#1"}).rows.length, 3);
  const claude = A.historyView(values, now, {provider: "claude"}); assert.equal(claude.rows.length, 1); assert.equal(claude.chart[6].series.length, 1);
});
test("invalid numeric, run, cost and duplicate identity output is refused", () => {
  assert.equal(A.validateData(envelope([row()]).data), true);
  assert.equal(A.validateData(envelope([row(), row()]).data), false);
  assert.equal(A.validateData(envelope([row({pr: 1})]).data), false);
  assert.equal(A.validateData(envelope([row({tokens: {total: NaN}})]).data), false);
  assert.equal(A.validateData(envelope([row({cost: {kind: "exact-ish"}})]).data), false);
});

// A minimal DOM implements node ownership and moves, so this exercises the real
// renderer's retention rather than mirroring its date-filtering implementation.
class Node {
  constructor(tag) {this.tagName = tag; this.children = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.classList = {toggle() {}};}
  setAttribute(key, value) {this.attributes[key] = value;}
  addEventListener() {}
  remove() {if (this.parentNode) {const siblings = this.parentNode.children; siblings.splice(siblings.indexOf(this), 1); this.parentNode = null;}}
  append(...nodes) {for (const node of nodes) {node.remove(); this.children.push(node); node.parentNode = this;}}
  replaceChildren(...nodes) {for (const node of [...this.children]) node.remove(); this.append(...nodes);}
  insertBefore(node, reference) {node.remove(); const index = reference === null ? this.children.length : this.children.indexOf(reference); assert.ok(index >= 0); this.children.splice(index, 0, node); node.parentNode = this;}
}
test("actual HistoryView evicts expired UTC dates while retaining surviving day nodes", () => {
  const previous = global.document;
  global.document = {createElement: tag => new Node(tag)};
  try {
    const view = new A.HistoryView(new Node("section"));
    const model = epoch => A.projectHistory(envelope([], {observed_checkouts: 1, coverage: {checkouts: 1, legacy_runs: 0}, diagnostics: []}), null, epoch);
    const midnight = Date.parse("2026-10-03T23:59:59Z") / 1000;
    view.update(model(midnight));
    const retained = new Map(view.days), expired = retained.get("2026-09-27");
    view.update(model(midnight + 2));
    assert.equal(view.days.size, 7); assert.equal(view.bars.children.length, 7);
    assert.equal(view.days.has("2026-09-27"), false); assert.equal(expired.root.parentNode, null);
    assert.deepEqual([...view.days.keys()], ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"]);
    for (const [day, item] of retained) if (day !== "2026-09-27") assert.equal(view.days.get(day), item);
    view.update(model(midnight + 10 * 86400));
    assert.equal(view.days.size, 7); assert.equal(view.bars.children.length, 7);
    assert.ok([...view.days.keys()].every(day => day >= "2026-10-07"));
  } finally {global.document = previous;}
});
