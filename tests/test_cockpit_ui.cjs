"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const C = require("../mergepath/cockpit/assets/components.js");
const {Connection, PanelRegistry, validSnapshot, accountHazards, renderPanelContent} = require("../mergepath/cockpit/assets/app.js");
const repositories = [{name: "mergepath", repo: "owner/mergepath", hub: true}, {name: "consumer", repo: "owner/consumer", hub: false}];
const snapshot = (overrides = {}) => ({schema: "cockpit/v1", revision: 1, generated_at: 1000, repositories, api_budget: {}, sources: {}, ...overrides});
const hazard = (id = "one", overrides = {}) => ({id, source: "prs", section: "prs", repo: "owner/mergepath", state: "bump", title: "Review delayed", detail: "Waiting for an observed review.", timing: {kind: "now"}, observed_at: 950, stale: false, ...overrides});
test("bootstrap scrubs full fragment before I/O and accepts only a fixed scope grammar", async () => {
  const source = fs.readFileSync(require.resolve("../mergepath/cockpit/bootstrap.js"), "utf8");
  for (const scope of ["a".repeat(43), "", "../escape", "a".repeat(42), "a".repeat(44), "/".repeat(43)]) {
    const calls = [], status = {textContent: ""};
    const context = {URLSearchParams, document: {getElementById: () => status},
      window: {location: {hash: `#launch=fixture-only&scope=${encodeURIComponent(scope)}&secret=extra`, replace: path => calls.push(["navigate", path])},
        history: {replaceState: (_state, _title, path) => calls.push(["scrub", path])}},
      fetch: async (path, options) => {assert.deepEqual(calls, [["scrub", "/bootstrap"]]); calls.push(["fetch", path, options]); return {ok: true};}};
    vm.runInNewContext(source, context); await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls[0][0], "scrub");
    if (scope === "a".repeat(43)) {
      assert.equal(calls[1][1], "/api/bootstrap"); assert.equal(calls[1][2].method, "POST");
      assert.equal(calls[1][2].headers["X-Cockpit-Bootstrap"], "fixture-only");
      assert.deepEqual(calls[2], ["navigate", `/s/${scope}/`]);
    } else {assert.equal(calls.length, 1); assert.match(status.textContent, /Relaunch/);}
  }
});
test("six states preserve common ordering; unavailable is not clear", () => {
  assert.equal(C.STATES.length, 6);
  assert.equal(C.worstState(["done", "running", "clear", "bump", "boulder"]), "boulder");
  assert.equal(C.worstState(["unknown", "idle"]), "idle");
  assert.equal(C.worstState(["clear", "done"]), "clear");
});
test("meters keep observed denominator, unknown usage and distinct throttle signals", () => {
  assert.deepEqual(C.meterModel().percent, null);
  assert.equal(C.meterModel({limit: 5000}).state, "idle");
  assert.equal(C.meterModel({limit: 5000, remaining: 1500}).state, "bump");
  assert.equal(C.meterModel({limit: 5000, used: 4999}).state, "bump");
  assert.equal(C.meterModel({limit: 5000, used: 5000}).state, "boulder");
  assert.equal(C.meterModel({limit: 5000, remaining: 4000, secondary_limited: true}).limit, 5000);
  assert.equal(C.meterModel({limit: 5000, remaining: 4000, secondary_limited: true}).reason, "Secondary throttle");
  assert.equal(C.meterModel({limit: 30, remaining: 29}).state, "clear");
  assert.equal(C.meterModel({limit: "5000", used: 0}).ratio, null);
  assert.equal(C.meterModel({limit: 0, used: 0}).ratio, null);
  assert.equal(C.meterModel({limit: 10, remaining: 11}).ratio, null);
});
test("hazards reject malformed adapters, keep literal text and restrict navigation", () => {
  const result = C.normalizeHazards([hazard(), hazard("two", {state: "clear"}), hazard("three", {repo: "outsider/repo"}),
    hazard("four", {timing: {kind: "at", at: NaN}}), hazard("five", {href: "javascript:bad"}), hazard("one"),
    hazard("literal", {title: "<img onerror=bad>", timing: {kind: "unknown"}})], repositories.map(item => item.repo));
  assert.equal(result.hazards.length, 2);
  assert.equal(result.diagnostics.length, 5);
  assert.equal(result.hazards[1].title, "<img onerror=bad>");
});
test("filter retains shared hazards and does not change account evidence", () => {
  const hazards = [hazard(), hazard("other", {repo: "owner/consumer"}), hazard("account", {repo: null})];
  assert.deepEqual(C.filterHazards(hazards, "owner/consumer").map(item => item.id), ["other", "account"]);
  const value = snapshot({api_budget: {core: {limit: 5000, remaining: 100, observed_at: 990}}});
  assert.equal(accountHazards(value, 1000, false)[0].repo, null);
  assert.equal(value.api_budget.core.limit, 5000);
});
test("Road uses explicit log1p horizon; unknown does not invent future positions", () => {
  assert.equal(C.logPosition(0, 16000), 4);
  assert.equal(C.logPosition(16000, 16000), 94);
  assert.equal(C.logPosition(32000, 16000), 94);
  assert.ok(C.logPosition(60, 16000) > C.logPosition(30, 16000));
  assert.equal(C.logPosition(30, null), null);
  const hazards = [hazard(), hazard("future", {timing: {kind: "at", at: 4600}}), hazard("unknown", {timing: {kind: "unknown"}})];
  const unknown = C.roadModel(hazards, {now: 1000});
  assert.equal(unknown.horizonLabel, "Horizon unavailable");
  assert.deepEqual(unknown.strip.map(item => item.id), ["one"]);
  assert.equal(unknown.items.length, 3); assert.equal(unknown.deferred, 2);
  const explicit = C.roadModel(hazards, {now: 1000, horizonMinutes: 30, horizonLabel: "Cycle ends in 30 min"});
  assert.equal(explicit.items.find(item => item.id === "future").beyond, true);
  assert.equal(explicit.strip.length, 2);
  assert.equal(C.roadModel([], {now: 1000}).observed, false);
});
test("nine Road slots prioritize boulders; full list and narrow layout remain complete", () => {
  const hazards = Array.from({length: 13}, (_, index) => hazard(`hazard-${index}`, {state: index < 10 ? "boulder" : "bump", timing: {kind: "at", at: 1000 + index * 60}}));
  const model = C.roadModel(hazards, {now: 1000, horizonMinutes: 16000, horizonLabel: "Observed cycle end", width: 1000});
  assert.equal(model.strip.length, 9); assert.ok(model.strip.every(item => item.state === "boulder"));
  assert.equal(model.items.length, 13); assert.equal(model.overflow, 4);
  for (const width of [180, 300, 1000]) {
    const narrow = C.roadModel(hazards, {now: 1000, horizonMinutes: 16000, width});
    const packed = C.packRoad(narrow.strip.map((item, index) => ({...item, number: index + 1})), width);
    assert.ok(packed.every(item => item.x >= 10 && item.x <= width - 10));
    for (let index = 1; index < packed.length; index++) assert.ok(packed[index].x - packed[index - 1].x >= 28 - 1e-6);
    for (let left = 0; left < packed.length; left++) for (let right = left + 1; right < packed.length; right++) {
      if (packed[left].lane === packed[right].lane) assert.ok(packed[left].left + packed[left].labelWidth <= packed[right].left || packed[right].left + packed[right].labelWidth <= packed[left].left);
    }
  }
});
test("one provider-owned projection seam retains stale boulder and missing observations", () => {
  const registry = new PanelRegistry();
  registry.register("prs", "fixture_prs", (envelope, repo) => ({state: "boulder", label: "Stopped", hazards: envelope.data.hazards, count: repo === null ? 2 : 1}));
  assert.throws(() => registry.register("prs", "second", () => {}));
  assert.equal(registry.project(snapshot(), null, 1000).models.prs.state, "idle");
  assert.equal(registry.counts(snapshot(), 1000).get(null), null);
  const envelope = {data: {hazards: [hazard("blocked", {state: "boulder"}), hazard("account", {repo: null})]}, observed_at: 950, attempted_at: 990, stale: true, error: "permission_denied", retry_at: 1100, in_flight: false};
  const value = snapshot({sources: {fixture_prs: envelope}});
  const projected = registry.project(value, "owner/consumer", 1000);
  assert.equal(projected.models.prs.state, "boulder"); assert.equal(projected.models.prs.stale, true);
  assert.deepEqual(projected.hazards.map(item => item.id), ["account"]);
  assert.equal(projected.hazards[0].stale, true);
  assert.equal(registry.counts(value, 1000).get(null), 2);
  assert.equal(envelope.data.hazards[0].stale, false);
});
test("registry diagnostics refuse wrong-source and malformed output without domain guessing", () => {
  const registry = new PanelRegistry(); registry.register("ci", "fixture", () => ({state: "clear", label: "Clear", hazards: [hazard()], count: 8}));
  const value = snapshot({sources: {fixture: {data: {}, observed_at: 900, stale: false}}});
  assert.equal(registry.project(value, null, 1000).diagnostics.length, 1);
  assert.equal(registry.counts(value, 1000).get(null), null); // CI counts never become PR badges.
  assert.equal(registry.project(value, null, 1000).hazards.length, 0);
});
test("observed/unavailable ownership transitions reattach detached placeholder", () => {
  const parent = {children: [], contains(node) {return this.children.includes(node);}, replaceChildren(...nodes) {for (const node of this.children) node.parentNode = null; this.children = nodes; for (const node of nodes) node.parentNode = this;}};
  const placeholder = {remove() {this.parentNode.replaceChildren();}};
  parent.replaceChildren(placeholder);
  const observed = {}, adapter = {render: target => target.replaceChildren(observed)};
  assert.equal(renderPanelContent(parent, {observed: true}, adapter, placeholder), placeholder);
  assert.deepEqual(parent.children, [observed]);
  renderPanelContent(parent, {observed: false}, adapter, placeholder);
  assert.deepEqual(parent.children, [placeholder]);
  renderPanelContent(parent, {observed: true}, adapter, placeholder);
  assert.deepEqual(parent.children, [observed]);
});
test("cycle horizon is optional observed budget evidence, never inferred or recursive", () => {
  const registry = new PanelRegistry();
  registry.register("budget", "fixture", envelope => ({state: "idle", label: "Fixture", hazards: [], count: null, horizon: envelope.data.horizon}));
  assert.equal(registry.project(snapshot(), null, 1000).models.budget.horizon, undefined);
  const value = horizon => snapshot({sources: {fixture: {data: {horizon}, observed_at: 900, stale: false}}});
  assert.deepEqual(registry.project(value({cycleEnd: 2000, label: "Cycle end"}), null, 1000).models.budget.horizon, {cycleEnd: 2000, label: "Cycle end"});
  assert.equal(registry.project(value({cycleEnd: 999, label: "Past"}), null, 1000).models.budget.horizon, null);
  assert.equal(registry.project(value(null), null, 1000).models.budget.horizon, null);
});
test("Road reference ticks use log scale and full labels pack in upper lanes without global cap", () => {
  const model = C.roadModel([], {now: 1000, horizonMinutes: 16000, width: 1000});
  assert.deepEqual(model.ticks.map(tick => tick.label), ["15 min", "1 h", "today"]);
  assert.equal(C.roadModel([], {now: 1000}).ticks.length, 0);
  const packed = C.packRoad([4, 24, 44, 64, 84].map((position, i) => ({id: String(i), number: i + 1, title: "Short", position})), 1000);
  assert.equal(packed.filter(item => !item.short).length, 5);
  assert.ok(packed.every(item => item.lane >= 1 && item.lane <= 3));
  assert.match(accountHazards(snapshot({api_budget: {graphql: {limit: 5000, used: 3500, remaining: 1500}}}), 1000, false)[0].detail, /1500 points left of 5000/);
});
class Timers {
  constructor() {this.now = 1000; this.id = 0; this.tasks = new Map();}
  set = (fn, delay) => {const id = ++this.id; this.tasks.set(id, {fn, at: this.now + delay / 1000}); return id;};
  clear = id => this.tasks.delete(id);
  advance(seconds) {
    this.now += seconds;
    for (const [id, task] of [...this.tasks]) if (task.at <= this.now) {this.tasks.delete(id); task.fn();}
  }
}
class Stream {
  constructor() {this.listeners = new Map(); this.closed = false;}
  addEventListener(name, fn) {this.listeners.set(name, fn);}
  close() {this.closed = true;}
  emit(name, value) {this.listeners.get(name)?.({data: JSON.stringify(value)});}
}
const flush = () => new Promise(resolve => setImmediate(resolve));
function fixture(fetcher = async () => ({status: 200, ok: true, json: async () => snapshot()})) {
  const timers = new Timers(), streams = [], states = [], received = [], calls = [];
  const connection = new Connection({fetchSnapshot: signal => {calls.push(signal); return fetcher(signal);}, openStream: () => {const stream = new Stream(); streams.push(stream); return stream;},
    onSnapshot: value => received.push(value), onState: state => states.push(state), setTimer: timers.set, clearTimer: timers.clear, now: () => timers.now});
  return {connection, timers, streams, states, received, calls};
}
test("snapshot shape/inventory is checked, one stream starts, heartbeat is liveness only", async () => {
  assert.equal(validSnapshot(snapshot()), true); assert.equal(validSnapshot(snapshot({schema: "bad"})), false);
  const f = fixture(); f.connection.start(); f.connection.start(); await flush();
  assert.equal(f.calls.length, 1); assert.equal(f.streams.length, 1);
  assert.equal(f.states.at(-1).kind, "connecting");
  f.streams[0].emit("snapshot", snapshot()); assert.equal(f.states.at(-1).kind, "live");
  const received = f.received.length; f.streams[0].emit("heartbeat", {}); assert.equal(f.received.length, received);
  f.streams[0].emit("snapshot", snapshot({repositories: [repositories[0]]}));
  assert.equal(f.states.at(-1).kind, "reconnecting"); assert.equal(f.streams[0].closed, true);
  f.connection.stop(); assert.equal(f.timers.tasks.size, 0);
});
test("reconnect closes stream, bounded backoff becomes offline; stale events cannot reset it", async () => {
  const f = fixture(); f.connection.start(); await flush();
  for (const delay of [2, 4, 8, 16, 30]) {
    const stream = f.streams.at(-1); stream.emit("error", {});
    assert.equal(stream.closed, true); assert.equal(f.timers.tasks.size, 1);
    assert.equal(f.states.at(-1).retry_at - f.timers.now, delay);
    stream.emit("snapshot", snapshot()); assert.notEqual(f.states.at(-1).kind, "live");
    f.timers.advance(delay); await flush();
  }
  assert.equal(f.states.at(-1).kind, "offline");
  f.streams.at(-1).emit("heartbeat", {}); assert.equal(f.states.at(-1).kind, "live");
  f.connection.stop();
});
test("initial and reconnect HTTP401 or namespace HTTP404 stop with relaunch and no retry", async () => {
  for (const status of [401, 404]) {
    let attempts = 0;
    const f = fixture(async () => ++attempts === 1 ? {status: 200, ok: true, json: async () => snapshot()} : {status, ok: false});
    f.connection.start(); await flush(); f.streams[0].emit("error", {}); f.timers.advance(2); await flush();
    assert.equal(f.states.at(-1).kind, "session"); assert.equal(f.timers.tasks.size, 0); assert.equal(f.connection.active, false);
    const initial = fixture(async () => ({status, ok: false})); initial.connection.start(); await flush();
    assert.equal(initial.streams.length, 0); assert.equal(initial.states.at(-1).kind, "session");
    assert.equal(initial.timers.tasks.size, 0); assert.equal(initial.connection.active, false);
  }
});
test("abortable probe deadline and stream watchdog reject late results; invalid heartbeat fails", async () => {
  let deliver;
  const f = fixture(() => new Promise(resolve => {deliver = resolve;}));
  f.connection.start(); f.timers.advance(5);
  assert.equal(f.calls[0].aborted, true); assert.equal(f.states.at(-1).kind, "reconnecting");
  deliver({status: 200, ok: true, json: async () => snapshot()}); await flush(); assert.equal(f.streams.length, 0);
  f.connection.stop();
  const watched = fixture(); watched.connection.start(); await flush(); watched.timers.advance(45);
  assert.equal(watched.streams[0].closed, true); assert.equal(watched.states.at(-1).kind, "reconnecting"); watched.connection.stop();
  const bad = fixture(); bad.connection.start(); await flush(); bad.streams[0].emit("heartbeat", {not: "heartbeat"});
  assert.equal(bad.states.at(-1).kind, "reconnecting"); bad.connection.stop();
});
