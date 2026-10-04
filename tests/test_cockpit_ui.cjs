"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const C = require("../mergepath/cockpit/assets/components.js");
const {authorAccount, renderAuthorBudget, Connection, PanelRegistry, validSnapshot, liveClockNeedsRender, accountHazards, renderPanelContent, createFleetRefresh} = require("../mergepath/cockpit/assets/app.js");
const repositories = [{name: "mergepath", repo: "owner/mergepath", hub: true}, {name: "consumer", repo: "owner/consumer", hub: false}];
const snapshot = (overrides = {}) => ({schema: "cockpit/v1", revision: 1, generated_at: 1000, repositories, api_budget: {}, sources: {}, ...overrides});
const hazard = (id = "one", overrides = {}) => ({id, source: "prs", section: "prs", repo: "owner/mergepath", state: "bump", title: "Review delayed", detail: "Waiting for an observed review.", timing: {kind: "now"}, observed_at: 950, stale: false, ...overrides});
test("Fleet cold progress is opt-in, never coverage, and invalid later data withdraws rendered rows", () => {
  const registry = new PanelRegistry();
  const pending = {state: "running", label: "Auditing", hazards: [], count: null, hasObservations: false, coverageValid: false};
  let override = null;
  registry.register("fleet", "fleet", envelope => {
    if (override) return override;
    if (envelope.data === null) return pending;
    if (envelope.data.ok !== true) throw new Error("invalid_data");
    return {state: "clear", label: "Audited", hazards: [], count: 0};
  }, () => {}, {renderPending: true});
  const cold = {data: null, observed_at: null, attempted_at: 995, retry_at: null, in_flight: true, stale: true, error: "unavailable"};
  const project = envelope => registry.project(snapshot({sources: {fleet: envelope}}), null, 1000);
  const initial = project(cold);
  assert.equal(initial.models.fleet.renderable, true);
  for (const key of ["observedPanels", "freshPanels", "stalePanels", "partialPanels", "invalidPanels"]) assert.equal(initial[key], 0);
  assert.equal(initial.models.fleet.observed, false); assert.deepEqual(initial.hazards, []);
  const parent = {children: [], contains(node) {return this.children.includes(node);}, replaceChildren(...nodes) {for (const node of this.children) node.parentNode = null; this.children = nodes; for (const node of nodes) node.parentNode = this;}};
  const placeholder = {remove() {this.parentNode.replaceChildren();}}, row = {}, adapter = {render: target => target.replaceChildren(row)};
  parent.replaceChildren(placeholder);
  renderPanelContent(parent, initial.models.fleet, adapter, placeholder);
  assert.deepEqual(parent.children, [row]);
  const observed = project({...cold, data: {ok: true}, observed_at: 999, stale: false, in_flight: false});
  assert.equal(observed.freshPanels, 1);
  renderPanelContent(parent, observed.models.fleet, adapter, placeholder);
  const invalid = project({...cold, data: {ok: false}, observed_at: 999});
  assert.equal(invalid.models.fleet.renderable, false);
  renderPanelContent(parent, invalid.models.fleet, adapter, placeholder);
  assert.deepEqual(parent.children, [placeholder]);
  for (const envelope of [{...cold, data: undefined}, {...cold, data: {}}, {...cold, observed_at: "bad"}, {...cold, attempted_at: undefined}, {...cold, retry_at: -1}]) {
    assert.equal(project(envelope).models.fleet.renderable, false);
  }
  for (const bad of [{state: "clear"}, {hazards: [hazard()]}, {count: 0}, {hasObservations: true}, {coverageValid: true}]) {
    override = {...pending, ...bad, renderable: true};
    assert.equal(project(cold).models.fleet.renderable, false);
  }
  assert.throws(() => new PanelRegistry().register("ci", "ci", () => pending, null, {renderPending: true}));
  const noOptIn = new PanelRegistry(); noOptIn.register("fleet", "fleet", () => pending);
  assert.equal(noOptIn.project(snapshot({sources: {fleet: cold}}), null, 1000).models.fleet.renderable, false);
});
test("Fleet gets a current immutable PR envelope without mutating the shared snapshot", () => {
  const registry = new PanelRegistry(), seen = [];
  registry.register("prs", "shared_prs", () => ({state: "idle", label: "PRs", hazards: []}));
  registry.register("fleet", "fleet", (_envelope, _repo, _now, context) => {
    seen.push(context.prs.data.rows[0].state);
    assert.throws(() => {context.prs.data.rows[0].state = "forged";}, TypeError);
    return {state: "idle", label: "Fleet", hazards: []};
  });
  const value = snapshot({sources: {shared_prs: {data: {rows: [{state: "pending"}]}, observed_at: 900}, fleet: {data: {}, observed_at: 900}}});
  registry.project(value, null, 1000);
  assert.equal(value.sources.shared_prs.data.rows[0].state, "pending");
  value.sources.shared_prs.data.rows[0].state = "approved";
  registry.project(value, null, 1001);
  assert.deepEqual(seen, ["pending", "approved"]);
});
test("manual Fleet refresh coalesces requests, uses scoped CSRF, and never sends executable input", async () => {
  const calls = [], timers = []; let release;
  const refresh = createFleetRefresh(async (url, options) => {
    calls.push({url, options});
    if (url === "api/session") return {ok: true, json: async () => ({csrf: "a".repeat(43)})};
    await new Promise(resolve => {release = resolve;});
    return {status: 202};
  }, callback => {timers.push(callback); return 1;}, () => {});
  const first = refresh(), repeated = refresh(); assert.equal(first, repeated);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls.map(call => call.url), ["api/session", "api/fleet/refresh"]);
  assert.equal(calls[1].options.method, "POST"); assert.equal(calls[1].options.credentials, "same-origin");
  assert.equal(calls[1].options.headers["X-Cockpit-CSRF"], "a".repeat(43));
  assert.equal(calls[1].options.body, undefined);
  release(); await first;
  const next = refresh(); assert.notEqual(next, first);
  await new Promise(resolve => setImmediate(resolve)); release(); await next;
  for (const value of [null, {csrf: "bad"}]) {
    let invoked = 0;
    const refused = createFleetRefresh(async () => {invoked++; return {ok: value !== null, json: async () => value};}, () => 1, () => {});
    await assert.rejects(refused(), /refresh_unavailable/); assert.equal(invoked, 1);
  }
  let signal;
  const slow = createFleetRefresh((_url, options) => new Promise((_resolve, reject) => {
    signal = options.signal; signal.addEventListener("abort", () => reject(new Error("aborted")));
  }), callback => {timers.push(callback); return 1;}, () => {});
  const timed = slow(); timers.at(-1)(); await assert.rejects(timed, /aborted/); assert.equal(signal.aborted, true);
});
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
test("passed primary reset makes current usage unknown but preserves denominator and independent secondary evidence", () => {
  const evidence = {limit: 5000, remaining: 0, used: 5000, reset: 1010, observed_at: 950, primary_exhausted: true};
  const before = C.meterModel(evidence, 1000);
  assert.equal(before.state, "boulder"); assert.equal(before.percent, 100);
  const after = C.meterModel(evidence, 1010);
  assert.equal(after.state, "idle"); assert.equal(after.limit, 5000);
  assert.equal(after.remaining, null); assert.equal(after.used, null); assert.equal(after.percent, null);
  assert.equal(after.lastKnownRemaining, 0); assert.equal(after.lastKnownUsed, 5000);
  assert.match(after.reason, /reset/i);
  assert.equal(accountHazards(snapshot({api_budget: {core: evidence}}), 1010, false).length, 0);
  const secondary = {...evidence, secondary_limited: true};
  const retained = C.meterModel(secondary, 1010);
  assert.equal(retained.state, "boulder"); assert.equal(retained.percent, null); assert.equal(retained.limit, 5000);
  assert.match(retained.reason, /Secondary/);
  assert.match(accountHazards(snapshot({api_budget: {core: secondary}}), 1010, false)[0].detail, /last known/i);
  assert.equal(evidence.remaining, 0); assert.equal(evidence.used, 5000);
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
test("partial repository coverage can withdraw freshness but never override a stale envelope", () => {
  const registry = new PanelRegistry();
  registry.register("prs", "fixture", (envelope, repo) => ({state: "clear", label: "Observed repositories", hazards: [],
    count: 0, stale: repo !== "owner/mergepath"}));
  const value = stale => snapshot({sources: {fixture: {data: {}, observed_at: 950, stale}}});
  const partial = registry.project(value(false), null, 1000);
  assert.equal(partial.models.prs.stale, true);
  assert.equal(partial.models.prs.coverageValid, true);
  assert.equal(partial.freshPanels, 0); assert.equal(partial.invalidPanels, 0);
  const readable = registry.project(value(false), "owner/mergepath", 1000);
  assert.equal(readable.models.prs.stale, false); assert.equal(readable.freshPanels, 1);
  const failedEnvelope = registry.project(value(true), "owner/mergepath", 1000);
  assert.equal(failedEnvelope.models.prs.stale, true); assert.equal(failedEnvelope.freshPanels, 0);
  assert.equal(failedEnvelope.models.prs.observed_at, 950);
});
test("provider attempts without observations render diagnostics without inventing last-known coverage", () => {
  const registry = new PanelRegistry();
  registry.register("prs", "fixture", envelope => ({state: "clear", label: "Coverage", count: 0,
    hazards: envelope.data.hazards, hasObservations: envelope.data.observed, stale: envelope.data.stale}));
  const value = (observed, stale, hazards = []) => snapshot({sources: {fixture: {data: {observed, stale, hazards}, observed_at: 950, stale: false}}});
  const never = registry.project(value(false, true), null, 1000);
  assert.equal(never.models.prs.observed, true); // The adapter still owns its error/unknown display.
  assert.equal(never.observedPanels, 0); assert.equal(never.stalePanels, 0); assert.equal(never.freshPanels, 0);
  assert.equal(C.roadModel([], {now: 1000, observed: never.freshPanels > 0, staleCoverage: never.stalePanels > 0}).emptyText, "No observations yet");
  assert.equal(registry.project(value(true, false), null, 1000).freshPanels, 1); // Successful empty observation.
  assert.equal(registry.project(value(true, true), null, 1000).stalePanels, 1); // Retained partial coverage.
  const invalid = registry.project(value(false, true, [hazard("kept"), {invalid: true}]), null, 1000);
  assert.equal(invalid.invalidPanels, 1); assert.equal(invalid.hazards.length, 1); assert.ok(invalid.diagnostics.length);
  const badFlag = registry.project(value("false", false), null, 1000);
  assert.equal(badFlag.freshPanels, 0); assert.ok(badFlag.diagnostics.length);
});
test("stale-only clear coverage stays idle; fresh restoration and stale boulders remain truthful", () => {
  const registry = new PanelRegistry();
  const project = envelope => ({state: envelope.data.hazards.length ? "boulder" : "clear", label: "Fixture", hazards: envelope.data.hazards, count: 0});
  registry.register("prs", "fixture_prs", project);
  registry.register("ci", "fixture_ci", project);
  const envelope = (stale, hazards = []) => ({data: {hazards}, observed_at: 950, stale});
  const value = (prs, ci) => snapshot({sources: {fixture_prs: prs, fixture_ci: ci}});
  const unavailable = registry.project(snapshot(), null, 1000);
  assert.equal(unavailable.observedPanels, 0); assert.equal(unavailable.freshPanels, 0); assert.equal(unavailable.stalePanels, 0);
  const stale = registry.project(value(envelope(true)), null, 1000);
  assert.equal(stale.models.prs.observed, true); assert.equal(stale.models.prs.state, "clear");
  assert.equal(stale.observedPanels, 1); assert.equal(stale.freshPanels, 0); assert.equal(stale.stalePanels, 1);
  const road = C.roadModel(stale.hazards, {now: 1000, observed: stale.freshPanels > 0, staleCoverage: stale.stalePanels > 0});
  assert.equal(road.emptyState, "idle"); assert.match(road.emptyText, /stale/i);
  const mixed = registry.project(value(envelope(true), envelope(false)), null, 1000);
  assert.equal(mixed.freshPanels, 1); assert.equal(mixed.stalePanels, 1); assert.equal(mixed.observedPanels, 2);
  assert.equal(C.roadModel(mixed.hazards, {now: 1000, observed: true, staleCoverage: true}).emptyState, "clear");
  const blocked = registry.project(value(envelope(true, [hazard("retained", {state: "boulder"})])), null, 1000);
  assert.equal(blocked.hazards[0].state, "boulder"); assert.equal(blocked.hazards[0].stale, true);
  assert.equal(C.roadModel(blocked.hazards, {now: 1000, observed: false, staleCoverage: true}).emptyState, "idle");
  const restored = registry.project(value(envelope(false)), null, 1000);
  assert.equal(restored.freshPanels, 1); assert.equal(restored.stalePanels, 0);
  assert.equal(C.roadModel(restored.hazards, {now: 1000, observed: true}).emptyState, "clear");
});
test("registry diagnostics refuse wrong-source and malformed output without domain guessing", () => {
  const registry = new PanelRegistry(); registry.register("ci", "fixture", () => ({state: "clear", label: "Clear", hazards: [hazard()], count: 8}));
  const value = snapshot({sources: {fixture: {data: {}, observed_at: 900, stale: false}}});
  assert.equal(registry.project(value, null, 1000).diagnostics.length, 1);
  assert.equal(registry.counts(value, 1000).get(null), null); // CI counts never become PR badges.
  assert.equal(registry.project(value, null, 1000).hazards.length, 0);
});
test("refused projection hazards never become fresh clear coverage or fake staleness", () => {
  const cases = [[{bad: "fields"}], [hazard("wrong", {source: "ci", section: "ci"})], [hazard(), {bad: "fields"}]];
  for (const hazards of cases) {
    const registry = new PanelRegistry();
    registry.register("prs", "fixture", () => ({state: "clear", label: "Fixture", hazards, count: 0}));
    const value = snapshot({sources: {fixture: {data: {}, observed_at: 950, stale: false}}});
    const projection = registry.project(value, null, 1000);
    assert.equal(projection.models.prs.observed, true); assert.equal(projection.models.prs.observed_at, 950);
    assert.equal(projection.models.prs.stale, false); assert.equal(projection.models.prs.coverageValid, false);
    assert.equal(projection.freshPanels, 0); assert.equal(projection.stalePanels, 0); assert.equal(projection.invalidPanels, 1);
    assert.ok(projection.diagnostics.length > 0);
    assert.equal(projection.hazards.length, hazards.length === 2 ? 1 : 0);
    const road = C.roadModel(projection.hazards, {now: 1000, observed: projection.freshPanels > 0, invalidCoverage: projection.invalidPanels > 0});
    assert.equal(road.emptyState, "idle");
    if (!projection.hazards.length) assert.equal(road.emptyText, "Observations unavailable");
  }
});
test("repository filtering is valid coverage; mixed invalid data and global identities stay explicit", () => {
  const registry = new PanelRegistry();
  registry.register("prs", "fixture_prs", envelope => ({state: "clear", label: "Fixture", hazards: envelope.data.hazards, count: 0}));
  registry.register("ci", "fixture_ci", envelope => ({state: "clear", label: "Fixture", hazards: envelope.data.hazards, count: 0}));
  const envelope = hazards => ({data: {hazards}, observed_at: 950, stale: false});
  const value = snapshot({sources: {fixture_prs: envelope([hazard()]), fixture_ci: envelope([{bad: "fields"}])}});
  const filtered = registry.project(value, "owner/consumer", 1000);
  assert.equal(filtered.hazards.length, 0); assert.equal(filtered.models.prs.coverageValid, true);
  assert.equal(filtered.freshPanels, 1); assert.equal(filtered.invalidPanels, 1);
  assert.equal(C.roadModel([], {now: 1000, observed: true, invalidCoverage: true}).emptyState, "clear");
  const staleInvalid = registry.project(snapshot({sources: {fixture_ci: {...envelope([{bad: "fields"}]), stale: true}}}), null, 1000);
  assert.equal(staleInvalid.freshPanels, 0); assert.equal(staleInvalid.stalePanels, 1); assert.equal(staleInvalid.invalidPanels, 1);
  assert.equal(staleInvalid.models.ci.observed_at, 950); assert.equal(staleInvalid.models.ci.stale, true);
  assert.equal(C.roadModel([], {now: 1000, observed: false, staleCoverage: true, invalidCoverage: true}).emptyText, "Observations unavailable");
  const duplicate = registry.project(snapshot({sources: {fixture_prs: envelope([hazard("same")]), fixture_ci: envelope([hazard("same", {source: "ci", section: "ci"})])}}), null, 1000);
  assert.equal(duplicate.hazards.length, 1); assert.equal(duplicate.freshPanels, 0); assert.equal(duplicate.invalidPanels, 2);
  assert.equal(duplicate.models.prs.coverageValid, false); assert.equal(duplicate.models.ci.coverageValid, false);
  assert.ok(duplicate.diagnostics.length > 0);
});
test("system hazard identities are reserved before adapter merge even while shared hazards are absent", () => {
  const registry = new PanelRegistry();
  registry.register("prs", "fixture", envelope => ({state: "bump", label: "Fixture", hazards: envelope.data.hazards}));
  const value = snapshot({sources: {fixture: {data: {hazards: [hazard("account-api-core"), hazard("shell-connection"), hazard("usable")]}, observed_at: 950, stale: false}},
    api_budget: {core: {limit: 5000, remaining: 0, used: 5000, reset: 2000, primary_exhausted: true}}});
  const projection = registry.project(value, null, 1000);
  assert.deepEqual(projection.hazards.map(item => item.id), ["usable"]);
  assert.equal(projection.models.prs.coverageValid, false); assert.equal(projection.models.prs.stale, false);
  assert.equal(projection.invalidPanels, 1); assert.equal(projection.freshPanels, 0);
  assert.ok(projection.diagnostics.some(text => /reserved/i.test(text)));
  const connectionHazard = hazard("shell-connection", {source: "road", section: "road", repo: null, state: "boulder"});
  const merged = C.normalizeHazards([...projection.hazards, ...accountHazards(value, 1000, false), connectionHazard], repositories.map(item => item.repo));
  assert.equal(merged.diagnostics.length, 0);
  assert.deepEqual(merged.hazards.filter(item => item.source === "road").map(item => item.id), ["account-api-core", "shell-connection"]);
  assert.ok(merged.hazards.filter(item => item.source === "road").every(item => item.state === "boulder"));
});
test("bump and boulder projections need usable owned hazards before repository filtering", () => {
  for (const state of ["bump", "boulder"]) {
    const registry = new PanelRegistry();
    registry.register("prs", "fixture", envelope => ({state, label: "Fixture", hazards: envelope.data.hazards}));
    const value = hazards => snapshot({sources: {fixture: {data: {hazards}, observed_at: 950, stale: false}}});
    const absent = registry.project(value([]), null, 1000);
    assert.equal(absent.models.prs.state, state); assert.equal(absent.models.prs.coverageValid, false);
    assert.equal(absent.models.prs.observed_at, 950); assert.equal(absent.models.prs.stale, false);
    assert.equal(absent.freshPanels, 0); assert.equal(absent.invalidPanels, 1);
    const road = C.roadModel(absent.hazards, {now: 1000, observed: absent.freshPanels > 0, invalidCoverage: absent.invalidPanels > 0});
    assert.equal(road.emptyState, "idle"); assert.equal(road.emptyText, "Observations unavailable");
    assert.ok(absent.diagnostics.some(text => /hazard/i.test(text)));
    const filtered = registry.project(value([hazard("other", {state})]), "owner/consumer", 1000);
    assert.equal(filtered.hazards.length, 0); assert.equal(filtered.models.prs.coverageValid, true);
    assert.equal(filtered.freshPanels, 1); assert.equal(filtered.invalidPanels, 0);
  }
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

test("provider partial coverage cannot invent fresh clear or hide invalid hazards", () => {
  const registry = new PanelRegistry();
  registry.register("budget", "actions", e => e.data);
  const value = data => snapshot({sources:{actions:{data:{state:"idle",label:"Partly unavailable",hazards:[],hasObservations:true,...data},observed_at:950,stale:false}}});
  const partial = registry.project(value({coverageValid:false}),null,1000);
  assert.equal(partial.models.budget.observed,true); assert.equal(partial.observedPanels,1);
  assert.equal(partial.freshPanels,0); assert.equal(partial.stalePanels,0);
  assert.equal(partial.partialPanels,1); assert.equal(partial.invalidPanels,0);
  assert.equal(partial.diagnostics.length,0);
  assert.equal(C.roadModel([], {now:1000,partialCoverage:true}).emptyText,"Observations incomplete");
  assert.equal(C.roadModel([], {now:1000,partialCoverage:true,observed:true}).emptyText,"Road is clear for fresh observed sources");
  const usable=hazard("budget-observed",{source:"budget",section:"budget",repo:null});
  const hazardPartial=registry.project(value({state:"bump",coverageValid:false,hazards:[usable]}),"owner/consumer",1000);
  assert.equal(hazardPartial.hazards.length,1); assert.equal(hazardPartial.partialPanels,1);
  for(const flag of [false,true]) {
    const invalid=registry.project(value({coverageValid:flag,hazards:[usable,{bad:true}]}),null,1000);
    assert.equal(invalid.hazards.length,1); assert.equal(invalid.freshPanels,0);
    assert.equal(invalid.invalidPanels,1); assert.equal(invalid.partialPanels,0);
  }
  assert.equal(registry.project(value({coverageValid:true}),null,1000).freshPanels,1);
  assert.equal(registry.project(value({coverageValid:false,hasObservations:false}),null,1000).observedPanels,0);
  for(const flag of [null,"false",0,{}]) {
    const invalid=registry.project(value({coverageValid:flag}),null,1000);
    assert.equal(invalid.models.budget.observed,false); assert.ok(invalid.diagnostics.length);
  }
});

test("live clocks advance between source events and empty coverage expires without polling", () => {
  const observed = {sources: {live_agents: {observed_at: 1000, data: {observed_at: 1000, live: [{id: "run"}]}}}};
  assert.equal(liveClockNeedsRender(observed, 1000, 1001), true);
  observed.sources.live_agents.data.live = [];
  assert.equal(liveClockNeedsRender(observed, 1000, 1001), false);
  assert.equal(liveClockNeedsRender(observed, 1010, 1011), true);
  assert.equal(liveClockNeedsRender(observed, 1011, 1012), false);
  observed.sources.live_agents.observed_at = null;
  assert.equal(liveClockNeedsRender(observed, 1010, 1011), false);
  assert.equal(liveClockNeedsRender(null, null, 1011), false);
});

const authorSnapshot = (data = {}, envelope = {}) => snapshot({
  api_budget: {core: {configured_identity: "nathanpayne-codex", limit: 5000, remaining: 4726, used: 274, reset: 2000, observed_at: 950}},
  sources: {api_author: {observed_at: 950, stale: false, data: {schema: "author-api-budget/v1", configured_identity: "nathanjohnpayne", verified_identity: "nathanjohnpayne", identity_evidence: "viewer_verified", budgets: {graphql: {limit: 5000, remaining: 281, used: 4719, reset: 2000, observed_at: 950}}, error: null, stale: false, retry_at: 1060, ...data}, ...envelope}}
});
test("author allowance is separate from reviewer evidence and both produce independently owned hazards", () => {
  const value = authorSnapshot(), original = structuredClone(value);
  assert.equal(authorAccount(value).evidence.remaining, 281);
  const hazards = accountHazards(value, 1000, false);
  assert.equal(hazards.length, 1); assert.equal(hazards[0].id, "account-api-author-graphql");
  assert.match(hazards[0].title, /nathanjohnpayne.*author PAT/);
  assert.match(hazards[0].detail, /281 points left of 5000/);
  value.api_budget.core = {...value.api_budget.core, remaining: 0, used: 5000, primary_exhausted: true};
  const both = accountHazards(value, 1000, false);
  assert.deepEqual(both.map(x => x.id), ["account-api-core", "account-api-author-graphql"]);
  assert.equal(both[1].state, "bump"); assert.equal(both[0].state, "boulder");
  assert.deepEqual(authorAccount(value), authorAccount(original));
});
test("author display labels failed refresh as last-known, preserves genuine exhaustion and invalidates expired use", () => {
  const updates = [], meter = {update: (evidence, options) => updates.push({evidence, options})}, note = {};
  let value = authorSnapshot(); renderAuthorBudget(meter, note, value, 1000);
  assert.equal(updates.at(-1).evidence.remaining, 281); assert.equal(updates.at(-1).options.unit, "points");
  assert.match(note.textContent, /Viewer verified.*Author allowance/);
  value = authorSnapshot({error: "cached_author_required", stale: true, identity_evidence: "last_viewer_verified"});
  renderAuthorBudget(meter, note, value, 1000);
  assert.equal(updates.at(-1).evidence.remaining, null); assert.equal(updates.at(-1).evidence.used, null);
  assert.match(note.textContent, /Author budget unavailable.*last known 281 left.*retry/);
  assert.doesNotMatch(note.textContent, /cached_author_required/);
  assert.equal(value.api_budget.core.remaining, 4726);
  const exhausted = {limit: 5000, remaining: 0, used: 5000, reset: 2000, observed_at: 999, primary_exhausted: true};
  value = authorSnapshot({budgets: {graphql: exhausted}, error: "primary_exhausted", stale: true});
  renderAuthorBudget(meter, note, value, 1000);
  assert.equal(updates.at(-1).evidence.remaining, 0);
  assert.equal(C.meterModel(updates.at(-1).evidence, 1000).state, "boulder");
  renderAuthorBudget(meter, note, value, 2001);
  assert.equal(C.meterModel(updates.at(-1).evidence, 2001).remaining, null);
  assert.equal(C.meterModel(updates.at(-1).evidence, 2001).lastKnownRemaining, 0);
  assert.equal(C.meterModel(updates.at(-1).evidence, 2001).lastKnownUsed, 5000);
  assert.deepEqual(accountHazards(value, 2001, false), []);
  assert.match(note.textContent, /reset passed; awaiting observation/);
});
test("missing or mismatched author source stays unknown, independent stale envelope is visible", () => {
  const meter = {update: (evidence, options) => {meter.model = C.meterModel(evidence, options.now);}}, note = {};
  for (const value of [snapshot(), authorSnapshot({configured_identity: "other"}), authorSnapshot({budgets: {}, error: "author_identity_mismatch", verified_identity: null})]) {
    renderAuthorBudget(meter, note, value, 1000); assert.equal(meter.model.remaining, null);
    assert.match(note.textContent, /Author budget unavailable/);
  }
  renderAuthorBudget(meter, note, authorSnapshot({}, {stale: true}), 1000);
  assert.equal(meter.model.remaining, null); assert.match(note.textContent, /last known/);
});

test("scheduler retry supersedes cached author retry without borrowing reviewer state", () => {
  const value = authorSnapshot({retry_at: 1010}, {stale: true, error: "deadline_exceeded", retry_at: 1120});
  assert.equal(authorAccount(value).retry, 1120);
  const note = {}; renderAuthorBudget({update() {}}, note, value, 1000);
  assert.match(note.textContent, /retry in 2 min/);
  assert.equal(value.api_budget.core.remaining, 4726);
});
test("two real meter DOMs show author first and remain independent across exhaustion and reset", () => {
  const saved = global.document;
  class Node {
    constructor() {this.children = []; this.style = {}; this.attrs = {}; this.classList = {contains: () => true, add() {}, remove() {}};}
    append(...nodes) {this.children.push(...nodes); for (const node of nodes) node.parent = this;}
    setAttribute(key, value) {this.attrs[key] = value;}
    removeAttribute(key) {delete this.attrs[key];}
    addEventListener() {}
    replaceWith(node) {const index = this.parent.children.indexOf(this); this.parent.children[index] = node; node.parent = this.parent;}
  }
  global.document = {createElement: () => new Node(), body: new Node()};
  try {
    const parent = new Node(), authorParent = new Node(), reviewerParent = new Node(); parent.append(authorParent, reviewerParent);
    const authorMeter = new C.MeterView(authorParent), reviewerMeter = new C.MeterView(reviewerParent), note = {};
    const value = authorSnapshot(); renderAuthorBudget(authorMeter, note, value, 1000); reviewerMeter.update(value.api_budget.core, {now: 1000});
    assert.deepEqual(parent.children, [authorParent, reviewerParent]);
    assert.equal(authorMeter.value.textContent, "281 left"); assert.equal(reviewerMeter.value.textContent, "4,726 left");
    value.sources.api_author.data.budgets.graphql = {limit: 5000, remaining: 0, used: 5000, reset: 1010, observed_at: 1000, primary_exhausted: true};
    value.sources.api_author.data.error = "primary_exhausted"; value.sources.api_author.data.stale = true;
    renderAuthorBudget(authorMeter, note, value, 1001);
    assert.equal(authorMeter.value.textContent, "0 left"); assert.equal(authorMeter.track.attrs["aria-valuenow"], "100");
    assert.equal(reviewerMeter.value.textContent, "4,726 left");
    renderAuthorBudget(authorMeter, note, value, 1011);
    assert.equal(authorMeter.value.textContent, "Remaining unknown");
    assert.match(authorMeter.reason.textContent, /last known 0 left \/ 5,000 used/);
    assert.equal(authorMeter.track.attrs["aria-valuenow"], undefined);
  } finally {global.document = saved;}
});
