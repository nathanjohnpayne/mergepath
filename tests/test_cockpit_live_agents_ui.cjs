"use strict";
const assert = require("node:assert/strict");
const {test} = require("node:test");
const fs = require("node:fs");
const L = require("../mergepath/cockpit/assets/live_agents.js");
const now = 1800000000;
function row(changes = {}) {return {id: "owner/hub:p4b-one", run_id: "p4b-one", repo: "owner/hub", pr: "1", pid: 123, head: "a".repeat(40), provider: "codex", reviewer: "nathanpayne-codex", stage: "adapter", reached: ["barrier", "adapter"], process_status: "running", observed_at: now,
  started_at_epoch: now - 1000, stage_at_epoch: now - 900, adapter_started_at_epoch: now - 900, adapter_elapsed_seconds: null, adapter_elapsed_observed_seconds: 900, adapter_elapsed_observed_at: now, adapter_timeout_seconds: 1000, adapter_exit_code: null, exit_code: null, token_count: null, findings_count: null, dry_run: false, summary_emitted: false, review_posted: false, verdict: null, adapter_verdict: null, posted_outcome: null, review_acknowledgment: null, ...changes};}
function envelope(rows = [row()], changes = {}) {return {stale: false, observed_at: now, data: {schema: "cockpit-live-agents/v1", hasObservations: true, coverage_complete: true, observed_at: now, live: rows, terminal: [], diagnostics: [], ...changes}};}
test("observed effective adapter budget drives exact 80% threshold", () => {
  const below = L.projectLive(envelope([row({adapter_started_at_epoch: now - 799, adapter_elapsed_observed_seconds: 799})]), null, now);
  assert.equal(below.rows[0].label, "Running"); assert.equal(below.hazards.length, 0);
  const threshold = L.projectLive(envelope([row({adapter_started_at_epoch: now - 800, adapter_elapsed_observed_seconds: 800})]), null, now);
  assert.equal(threshold.rows[0].label, "Near timeout"); assert.equal(threshold.hazards[0].timing.at, now + 200);
  assert.equal(threshold.rows[0].budget, 1000); assert.equal(threshold.rows[0].remaining, 200);
});
test("barrier elapsed cannot consume adapter budget; posting holds measured elapsed", () => {
  const barrier = row({stage: "barrier", reached: ["barrier"], adapter_started_at_epoch: null, adapter_elapsed_seconds: 9999});
  const projected = L.projectLive(envelope([barrier]), null, now).rows[0];
  assert.equal(projected.elapsed, null); assert.equal(projected.ratio, null); assert.equal(projected.invocation_elapsed, 1000);
  const posting = row({stage: "posting", reached: ["barrier", "adapter", "posting"], adapter_elapsed_seconds: 650});
  assert.equal(L.liveRow(posting, envelope(), now + 5).elapsed, 650);
});
test("budget exceeded cannot invent a timeout; exit124 and recorded crash remain distinct", () => {
  const exceeded = L.projectLive(envelope([row({adapter_started_at_epoch: now - 1200})]), null, now).rows[0];
  assert.match(exceeded.label, /Budget exceeded.*no terminal/); assert.equal(exceeded.state, "bump");
  assert.match(L.liveRow(row({adapter_exit_code: 124}), envelope(), now).label, /Timed out/);
  const crashed = L.projectLive(envelope([row({process_status: "crashed"})]), null, now);
  assert.match(crashed.rows[0].label, /Crashed/); assert.equal(crashed.hazards[0].state, "boulder");
});
test("unknown, stale, future and late samples stop ticking and withdraw coverage", () => {
  const unknown = row({process_status: "unknown"});
  assert.equal(L.liveRow(unknown, envelope(), now + 8).elapsed, 900);
  const stale = {...envelope(), stale: true};
  assert.equal(L.projectLive(stale, null, now + 8).rows[0].elapsed, 900);
  assert.equal(L.projectLive(stale, null, now + 8).coverageValid, false);
  assert.equal(L.projectLive(envelope(), null, now + 11).stale, true);
  assert.equal(L.projectLive(envelope(), null, now + 11).rows[0].elapsed, 900);
  assert.equal(L.liveRow(row({adapter_started_at_epoch: now + 1, adapter_elapsed_observed_seconds: null}), envelope(), now).ratio, null);
  assert.equal(L.projectLive(envelope([row({observed_at: now + 1})]), null, now).coverageValid, false);
  assert.equal(L.liveRow(row({process_status: "unknown", adapter_elapsed_observed_seconds: null}), envelope(), now).elapsed, null);
  assert.equal(L.liveRow(row({process_status: "crashed", adapter_elapsed_observed_seconds: null}), envelope(), now).elapsed, null);
});
test("missing denominator is unavailable and repository filtering applies to hazards", () => {
  const data = envelope([row({adapter_timeout_seconds: null}), row({id: "owner/other:p4b-two", run_id: "p4b-two", repo: "owner/other", process_status: "crashed"})]);
  const model = L.projectLive(data, "owner/hub", now);
  assert.equal(model.rows.length, 1); assert.equal(model.rows[0].ratio, null); assert.equal(model.hazards.length, 0);
});
test("malformed source, duplicate identity and unsupported stage are refused", () => {
  assert.equal(L.validateData(envelope().data), true);
  assert.equal(L.validateData(envelope([row(), row()]).data), false);
  assert.equal(L.validateData(envelope([row({stage: "unknown"})]).data), false);
  assert.equal(L.validateData(envelope([row({adapter_timeout_seconds: NaN})]).data), false);
  assert.equal(L.validateData(envelope([row({reached: ["adapter", "barrier"]})]).data), false);
  assert.equal(L.validateData(envelope([row({id: "other"})]).data), false);
  assert.throws(() => L.projectLive({data: {}}, null, now));
});

class Node {
  constructor(tag) {this.tagName = tag; this.children = []; this.parentNode = null; this.detachments = 0; this.style = {}; this.attributes = {}; this.classList = {remove() {}};}
  setAttribute(key, value) {this.attributes[key] = value;}
  addEventListener() {}
  remove() {if (this.parentNode) {this.detachments++; const siblings = this.parentNode.children; siblings.splice(siblings.indexOf(this), 1); this.parentNode = null;}}
  append(...nodes) {for (const node of nodes) {node.remove(); this.children.push(node); node.parentNode = this;}}
  replaceChildren(...nodes) {for (const node of [...this.children]) node.remove(); this.append(...nodes);}
  insertBefore(node, reference) {node.remove(); const index = reference === null ? this.children.length : this.children.indexOf(reference); assert.ok(index >= 0); this.children.splice(index, 0, node); node.parentNode = this;}
}
function withDOM(fn) {const old = global.document; global.document = {createElement: tag => new Node(tag)}; try {fn();} finally {global.document = old;}}
test("actual renderer preserves keyed cards/stages/fill through repeats and source interruptions", () => withDOM(() => {
  const view = new L.LiveView(new Node("section")), model = L.projectLive(envelope(), null, now);
  view.update(model); const card = view.cards.get(row().id), stages = [...card.stageNodes], fill = card.fill;
  view.update(model); view.update(L.projectLive({...envelope(), stale: true}, null, now));
  assert.match(card.footer.textContent, /stale/); assert.match(card.badge.children[1].textContent, /Stale/);
  view.update(L.projectLive(envelope([row({adapter_started_at_epoch: now - 400, adapter_elapsed_observed_seconds: 400})]), null, now));
  assert.equal(view.cards.get(row().id), card); assert.deepEqual(card.stageNodes, stages); assert.equal(card.fill, fill);
  assert.equal(card.root.detachments, 0); assert.ok(stages.every(node => node.detachments === 0)); assert.equal(fill.style.width, "40%");
}));
test("shell withdrawal reattaches cached nodes on valid recovery without replaying entry", () => withDOM(() => {
  const parent = new Node("section"), model = L.projectLive(envelope(), null, now);
  const first = L.renderLive(parent, model), card = first.cards.get(row().id);
  parent.replaceChildren(new Node("placeholder"));
  const recovered = L.renderLive(parent, model);
  assert.equal(recovered, first); assert.equal(recovered.cards.get(row().id), card);
  assert.equal(recovered.root.parentNode, parent); assert.equal(card.root.detachments, 0);
  assert.equal(card.entering, false); assert.doesNotMatch(card.root.className, /fresh/);
}));
test("crash caption distinguishes wall-clock invocation age from stopped adapter runtime", () => withDOM(() => {
  const view = new L.LiveView(new Node("section"));
  for (const offset of [100, 200]) {
    const sample = row({process_status: "crashed", observed_at: now + offset});
    view.update(L.projectLive(envelope([sample], {observed_at: now + offset}), null, now + offset));
    const card = view.cards.get(row().id);
    assert.equal(card.value.textContent, "15:00");
    assert.match(card.timing.textContent, /Since invocation start \(wall time\)/);
    assert.match(card.timing.textContent, /adapter clock stopped at last observed elapsed/);
    assert.ok(card.timing.textContent.includes(L.elapsed(1000 + offset)));
  }
}));
test("done transition leaves active list and requires summary plus post for posted readout", () => withDOM(() => {
  const view = new L.LiveView(new Node("section")); view.update(L.projectLive(envelope(), null, now));
  const terminal = row({stage: "done", reached: ["barrier", "adapter", "posting", "done"], process_status: "done", adapter_verdict: "APPROVED", exit_code: 7});
  view.update(L.projectLive(envelope([], {terminal: [terminal]}), null, now));
  assert.equal(view.cards.size, 0); assert.match(view.empty.textContent, /No Phase 4b run in flight/);
  assert.match(view.terminal.textContent, /final summary unavailable/); assert.doesNotMatch(view.terminal.textContent, /APPROVED review posted/);
  terminal.summary_emitted = true; terminal.review_posted = true; terminal.verdict = "APPROVED"; terminal.posted_outcome = "APPROVED"; terminal.review_acknowledgment = "failed";
  view.update(L.projectLive(envelope([], {terminal: [terminal]}), null, now));
  assert.match(view.terminal.textContent, /APPROVED review posted.*exit 7.*acknowledgment failed/);
}));
test("both reduced-motion paths stop loops at rest and preserve information", () => {
  const css = fs.readFileSync(require.resolve("../mergepath/cockpit/assets/live_agents.css"), "utf8");
  assert.match(css, /live-agent-pulse 1\.4s ease-in-out infinite/);
  assert.match(css, /width 700ms var\(--ease\)/);
  assert.match(css, /body\.rm .*animation:none!important;transition:none!important;transform:none!important/);
  assert.match(css, /prefers-reduced-motion:reduce/);
  assert.doesNotMatch(css, /animation-play-state:paused/);
});
test("cards created while reduced do not replay entry when normal motion returns", () => withDOM(() => {
  global.document.body = {classList: {contains: () => true}};
  const view = new L.LiveView(new Node("section")); view.update(L.projectLive(envelope(), null, now));
  const card = view.cards.get(row().id); assert.equal(card.entering, false); assert.doesNotMatch(card.root.className, /fresh/);
  global.document.body.classList.contains = () => false;
  view.update(L.projectLive(envelope(), null, now)); assert.equal(card.entering, false);
}));
