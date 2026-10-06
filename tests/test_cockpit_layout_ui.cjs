/* Hermetic panel-layout coverage: order helpers plus the DOM controller on a stub tree. Expected <2s; bound 30s. */
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const Layout = require("../mergepath/cockpit/assets/layout.js");
const root = path.resolve(__dirname, "..");
const PANEL_GAP = 18;

class Node {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase(); this.children = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.handlers = new Map();
    this.hidden = false; this._text = ""; this.className = ""; this.height = 100; this.width = 1000; this.disabled = false; this.focusCalls = 0; this.id = "";
    const names = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {contains: name => names().includes(name), add: (...added) => {this.className = [...new Set([...names(), ...added])].join(" ");},
      remove: (...removed) => {this.className = names().filter(name => !removed.includes(name)).join(" ");},
      toggle: (name, force) => {const on = force ?? !names().includes(name); this.classList[on ? "add" : "remove"](name); return on;}};
  }
  get firstChild() {return this.children[0] ?? null;}
  append(...nodes) {for (const node of nodes) {node.remove(); node.parentNode = this; this.children.push(node);}}
  insertBefore(node, reference) {
    node.remove(); const index = reference === null ? this.children.length : this.children.indexOf(reference);
    assert.ok(index >= 0, "insertBefore reference must be a child"); this.children.splice(index, 0, node); node.parentNode = this;
  }
  // Like a browser, removing (or moving) the subtree that holds focus drops focus to the body.
  remove() {
    if (!this.parentNode) return;
    if (document.activeElement && this.contains(document.activeElement)) document.activeElement = document.body;
    const siblings = this.parentNode.children; siblings.splice(siblings.indexOf(this), 1); this.parentNode = null;
  }
  contains(node) {return node === this || this.children.some(child => child.contains(node));}
  get isConnected() {return this === document.body || !!this.parentNode?.isConnected;}
  set textContent(value) {this.children = []; this._text = String(value);}
  get textContent() {return this._text + this.children.map(child => child.textContent).join("");}
  setAttribute(key, value) {this.attributes[key] = String(value);}
  getAttribute(key) {return this.attributes[key] ?? null;}
  addEventListener(type, fn) {if (!this.handlers.has(type)) this.handlers.set(type, []); this.handlers.get(type).push(fn);}
  removeEventListener(type, fn) {this.handlers.set(type, (this.handlers.get(type) ?? []).filter(item => item !== fn));}
  dispatch(type, init = {}) {const event = {type, defaulted: false, preventDefault() {event.defaulted = true;}, ...init}; for (const fn of [...(this.handlers.get(type) ?? [])]) fn(event); return event;}
  focus() {document.activeElement = this; this.focusCalls++;}
  scrollIntoView() {this.scrolledIntoView = (this.scrolledIntoView ?? 0) + 1;}
  setPointerCapture(id) {this.captured = id;}
  releasePointerCapture() {this.captured = null;}
  descendants() {return this.children.flatMap(child => [child, ...child.descendants()]);}
  querySelector(selector) {
    const direct = selector.startsWith(":scope > "), simple = direct ? selector.slice(9) : selector;
    const matches = node => simple.startsWith(".") ? node.classList.contains(simple.slice(1))
      : simple.startsWith("[data-panel=") ? node.attributes["data-panel"] === simple.slice(13, -2) : node.tagName === simple.toUpperCase();
    return (direct ? this.children : this.descendants()).find(matches) ?? null;
  }
  getBoundingClientRect() {
    layout(document.body); const top = this.top ?? 0, left = this.left ?? 0;
    return {top, left, bottom: top + this.height, right: left + this.width, width: this.width, height: this.height};
  }
}
// A tiny flow model: panels stack with the shared gap; a .row2 seats its children side by side unless the viewport is narrow.
function layout(body) {
  for (const container of body.children) {
    if (container.className !== "panel-grid") continue;
    let y = 0; container.top = 0; container.left = 0;
    for (const child of container.children) {
      if (child.classList.contains("row2")) {
        let tallest = 0, x = 0;
        child.top = y; child.left = 0;
        for (const panel of child.children) {
          panel.top = y; panel.left = x;
          if (document.narrow) {y += panel.height + PANEL_GAP; tallest = 0;} else {x += panel.width; tallest = Math.max(tallest, panel.height);}
        }
        y += document.narrow ? 0 : tallest + PANEL_GAP;
      } else {child.top = y; child.left = 0; y += child.height + PANEL_GAP;}
    }
    container.height = y;
  }
}
class Storage {
  constructor() {this.map = new Map(); this.failGet = false; this.failSet = false;}
  getItem(key) {if (this.failGet) throw new Error("storage denied"); return this.map.has(key) ? this.map.get(key) : null;}
  setItem(key, value) {if (this.failSet) throw new Error("quota"); this.map.set(key, String(value));}
  removeItem(key) {this.map.delete(key);}
}
global.document = {body: new Node("body"), activeElement: null, narrow: false, createElement: tag => new Node(tag)};
function section(id, title, height, className = "panel") {
  const node = new Node("section"); node.className = className; node.attributes["data-panel"] = id; node.height = height;
  const head = new Node("div"); head.className = "sec-head"; const h2 = new Node("h2"); h2.textContent = title; const meta = new Node("span"); meta.className = "sec-meta";
  head.append(h2, meta); const content = new Node("div"); content.className = "panel-content"; content.id = `${id}-content`; content.append(new Node("button"));
  node.append(head, content); return node;
}
function fixture({storage = new Storage(), narrow = false, reduced = false, defaults = Layout.PANELS, extra = [], knownSets = Layout.KNOWN_PANEL_SETS} = {}) {
  document.body = new Node("body"); document.activeElement = document.body; document.narrow = narrow;
  const container = new Node("div"); container.className = "panel-grid"; container.id = "panel-grid"; document.body.append(container);
  const sections = new Map([["prs", section("prs", "Open PRs", 400)], ["ci", section("ci", "CI and test runs", 300, "panel grow")],
    ["agents", section("agents", "Phase 4b agents", 200, "panel side")], ["history", section("history", "Agent history", 300)],
    ["fleet", section("fleet", "Fleet sync", 250)], ["budget", section("budget", "Actions budget", 350)]]);
  for (const id of extra) sections.set(id, section(id, `Extra ${id}`, 100));
  const row = new Node("div"); row.className = "row2";
  container.append(sections.get("prs"), row, sections.get("history"), sections.get("fleet"), sections.get("budget"), ...extra.map(id => sections.get(id)));
  row.append(sections.get("ci"), sections.get("agents"));
  const resetButton = new Node("button"), announcer = new Node("p"); document.body.append(resetButton, announcer);
  const rafs = [], timers = [], scrolls = [];
  const controller = new Layout.LayoutController({container, sections, row, resetButton, announcer, hintId: "layout-hint", store: new Layout.LayoutStore(storage, Layout.STORAGE_KEY, defaults, knownSets), defaults, knownSets,
    raf: fn => rafs.push(fn), caf: () => {}, scrollBy: (_x, y) => scrolls.push(y), viewportHeight: () => 800, reducedMotion: () => reduced, setTimer: fn => timers.push(fn)});
  controller.mount();
  return {controller, container, sections, row, resetButton, announcer, storage, rafs, timers, scrolls, handle: id => controller.handles.get(id)};
}
const domOrder = container => container.children.flatMap(child => child.classList.contains("row2") ? child.children.map(node => node.attributes["data-panel"]) : [child.attributes["data-panel"]]).filter(Boolean);
function drag(f, id, y, {release = true, pointerId = 1} = {}) {
  const handle = f.handle(id);
  handle.dispatch("pointerdown", {pointerId, button: 0, clientX: 10, clientY: 10});
  handle.dispatch("pointermove", {pointerId, clientX: 12, clientY: 30});
  handle.dispatch("pointermove", {pointerId, clientX: 12, clientY: y});
  if (release) handle.dispatch("pointerup", {pointerId});
  return handle;
}

test("order helpers normalize storage, clamp moves, pair only adjacent CI/agents and drop around whole rows", () => {
  assert.deepEqual(Layout.normalizeOrder(null), [...Layout.PANELS]);
  // An order is trusted whole or not at all: an unknown or repeated id, or a set this page never
  // saved, discards the stored order.
  for (const corrupt of [["budget", "bogus"], ["budget", "budget", "prs"], ["budget", "bogus", "prs", "prs", 7], ["budget", 7], "budget", ["budget", "prs"], ["fleet"]]) assert.deepEqual(Layout.normalizeOrder(corrupt), [...Layout.PANELS]);
  assert.equal(Layout.validOrder(["budget", "bogus"]), false); assert.equal(Layout.validOrder(["budget", "prs"]), false);
  assert.equal(Layout.validOrder(["budget", "prs", "ci", "agents", "history", "fleet"]), true);
  // A recognized older panel set appends the panels added since, in default order; an unrecognized subset does not.
  const grownDefaults = [...Layout.PANELS, "extra"], olderSets = [Layout.PANELS];
  assert.deepEqual(Layout.normalizeOrder(["fleet", "prs", "ci", "agents", "history", "budget"], grownDefaults, olderSets), ["fleet", "prs", "ci", "agents", "history", "budget", "extra"]);
  assert.deepEqual(Layout.normalizeOrder(["fleet", "prs"], grownDefaults, olderSets), grownDefaults);
  assert.deepEqual(Layout.normalizeOrder(["fleet", "prs", "ci", "agents", "history", "budget"], grownDefaults, []), grownDefaults);
  assert.deepEqual(Layout.moveTo(["a", "b", "c"], "c", 0), ["c", "a", "b"]);
  assert.deepEqual(Layout.moveTo(["a", "b", "c"], "a", 99), ["b", "c", "a"]);
  assert.deepEqual(Layout.moveTo(["a", "b", "c"], "a", -5), ["a", "b", "c"]);
  assert.deepEqual(Layout.moveTo(["a", "b", "c"], "zz", 1), ["a", "b", "c"]);
  assert.deepEqual(Layout.moveTo(["a", "b", "c"], "b", NaN), ["a", "b", "c"]);
  assert.deepEqual(Layout.rowsFor([...Layout.PANELS]), [["prs"], ["ci", "agents"], ["history"], ["fleet"], ["budget"]]);
  assert.deepEqual(Layout.rowsFor(["agents", "ci", "prs"]), [["agents", "ci"], ["prs"]]);
  assert.deepEqual(Layout.rowsFor(["ci", "prs", "agents"]), [["ci"], ["prs"], ["agents"]]);
  assert.equal(Layout.sameOrder(["a", "b"], ["a", "b"]), true); assert.equal(Layout.sameOrder(["a", "b"], ["b", "a"]), false);
  const items = [{id: "prs", top: 0, bottom: 400}, {id: "ci", top: 418, bottom: 718}, {id: "agents", top: 418, bottom: 618}, {id: "history", top: 736, bottom: 1036}];
  assert.deepEqual(Layout.dropSlot(items, 50), {index: 0, before: "prs", after: null, edge: 0});
  assert.deepEqual(Layout.dropSlot(items, 390), {index: 1, before: null, after: "prs", edge: 400});
  assert.deepEqual(Layout.dropSlot(items, 430), {index: 1, before: "ci", after: null, edge: 418});
  assert.deepEqual(Layout.dropSlot(items, 700), {index: 3, before: null, after: "agents", edge: 718});
  assert.deepEqual(Layout.dropSlot(items, 2000), {index: 4, before: null, after: "history", edge: 1036});
  assert.deepEqual(Layout.dropSlot([], 10), {index: 0, before: null, after: null, edge: null});
});

test("mount adds a handle to every panel head, applies the stored order and survives corrupt or unavailable storage", () => {
  const f = fixture();
  assert.deepEqual(domOrder(f.container), [...Layout.PANELS]); assert.deepEqual(f.row.children, [f.sections.get("ci"), f.sections.get("agents")]);
  assert.equal(f.resetButton.disabled, true);
  for (const id of Layout.PANELS) {
    const head = f.sections.get(id).querySelector(".sec-head"), handle = f.handle(id);
    assert.equal(head.children[0], handle); assert.equal(handle.tagName, "BUTTON"); assert.equal(handle.type, "button");
    assert.equal(handle.attributes["aria-label"], `Move ${f.sections.get(id).querySelector("h2").textContent} panel`);
    assert.equal(handle.attributes["aria-pressed"], "false"); assert.equal(handle.attributes["aria-describedby"], "layout-hint");
  }
  const seeded = new Storage(); seeded.setItem(Layout.STORAGE_KEY, JSON.stringify({v: 1, order: ["budget", "agents", "ci", "prs", "history", "fleet"]}));
  const stored = fixture({storage: seeded});
  assert.deepEqual(stored.controller.order, ["budget", "agents", "ci", "prs", "history", "fleet"]);
  assert.deepEqual(domOrder(stored.container), ["budget", "agents", "ci", "prs", "history", "fleet"]);
  assert.deepEqual(stored.row.children.map(node => node.attributes["data-panel"]), ["agents", "ci"]); assert.equal(stored.resetButton.disabled, false);
  for (const raw of ["not json", "[]", '{"order":"x"}', '["bogus","prs","prs"]', "null", '{"v":1}', '{"v":1,"order":["budget","bogus"]}', '{"v":1,"order":["budget","budget","prs"]}',
    '{"v":1,"order":["budget","agents","ci","prs"]}', '{"v":2,"order":["budget","prs","ci","agents","history","fleet"]}', '{"order":["budget","prs","ci","agents","history","fleet"]}', '["budget","prs","ci","agents","history","fleet"]']) {
    const storage = new Storage(); storage.setItem(Layout.STORAGE_KEY, raw);
    const stored = fixture({storage});
    assert.deepEqual(stored.controller.order, [...Layout.PANELS], raw); assert.equal(stored.resetButton.disabled, true, raw);
  }
  const denied = new Storage(); denied.failGet = true;
  assert.deepEqual(fixture({storage: denied}).controller.order, [...Layout.PANELS]);
  // An order saved before a panel existed loads when its set is a recognized older set, and the new panel appends.
  const stale = new Storage(); stale.setItem(Layout.STORAGE_KEY, JSON.stringify({v: 1, order: ["fleet", "prs", "ci", "agents", "history", "budget"]}));
  const grown = fixture({storage: stale, defaults: [...Layout.PANELS, "extra"], extra: ["extra"], knownSets: [Layout.PANELS]});
  assert.deepEqual(grown.controller.order, ["fleet", "prs", "ci", "agents", "history", "budget", "extra"]);
  const unrecognized = fixture({storage: stale, defaults: [...Layout.PANELS, "extra"], extra: ["extra"], knownSets: []});
  assert.deepEqual(unrecognized.controller.order, [...Layout.PANELS, "extra"]);
});

test("pointer drags move panels behind a drop indicator, save the order and keep focus; a plain click is inert", () => {
  const f = fixture(), budget = f.handle("budget");
  budget.dispatch("pointerdown", {pointerId: 1, button: 0, clientX: 10, clientY: 10}); budget.dispatch("pointerup", {pointerId: 1});
  assert.deepEqual(f.controller.order, [...Layout.PANELS]); assert.equal(f.announcer.textContent, ""); assert.equal(f.storage.map.size, 0);
  assert.equal(document.activeElement, budget);
  const secondary = budget.dispatch("pointerdown", {pointerId: 2, button: 2, clientX: 10, clientY: 10});
  assert.equal(f.controller.drag, null); assert.equal(secondary.defaulted, false);
  drag(f, "budget", 50, {release: false});
  assert.equal(f.sections.get("budget").classList.contains("panel-lifting"), true); assert.equal(document.body.classList.contains("layout-dragging"), true);
  assert.equal(f.controller.indicator.hidden, false); assert.equal(f.controller.indicator.style.top, `${-PANEL_GAP / 2 - 1.5}px`); assert.equal(f.controller.indicator.style.width, "1000px");
  assert.equal(budget.attributes["aria-pressed"], "true"); assert.match(f.announcer.textContent, /Actions budget picked up/);
  assert.deepEqual(domOrder(f.container), [...Layout.PANELS], "the live order does not change until the drop");
  budget.dispatch("pointerup", {pointerId: 1});
  assert.deepEqual(f.controller.order, ["budget", "prs", "ci", "agents", "history", "fleet"]); assert.deepEqual(domOrder(f.container), f.controller.order);
  assert.deepEqual(JSON.parse(f.storage.map.get(Layout.STORAGE_KEY)), {v: 1, order: f.controller.order});
  assert.equal(f.announcer.textContent, "Actions budget dropped at position 1 of 6."); assert.equal(document.activeElement, budget);
  assert.equal(f.sections.get("budget").classList.contains("panel-lifting"), false); assert.equal(document.body.classList.contains("layout-dragging"), false);
  assert.equal(f.controller.indicator.hidden, true); assert.equal(budget.attributes["aria-pressed"], "false"); assert.equal(f.resetButton.disabled, false);
  // Pulling the side panel below Fleet leaves CI alone on a full row and retires the pair wrapper.
  drag(f, "agents", 1600);
  assert.deepEqual(f.controller.order, ["budget", "prs", "ci", "history", "fleet", "agents"]); assert.equal(f.row.parentNode, null);
  assert.equal(f.sections.get("ci").parentNode, f.container); assert.equal(f.sections.get("agents").parentNode, f.container);
  // Dropping it just above CI seats it on CI's left.
  drag(f, "agents", 800);
  assert.deepEqual(f.controller.order, ["budget", "prs", "agents", "ci", "history", "fleet"]); assert.equal(f.row.parentNode, f.container);
  assert.deepEqual(f.row.children.map(node => node.attributes["data-panel"]), ["agents", "ci"]);
  // A shared row is one unit for every other panel: below its middle means after both, above means before both.
  drag(f, "history", 1000);
  assert.deepEqual(f.controller.order, ["budget", "prs", "agents", "ci", "history", "fleet"]); assert.equal(f.announcer.textContent, "Agent history dropped at position 5 of 6, unchanged.");
  drag(f, "history", 800);
  assert.deepEqual(f.controller.order, ["budget", "prs", "history", "agents", "ci", "fleet"]);
  assert.deepEqual(f.row.children.map(node => node.attributes["data-panel"]), ["agents", "ci"]);
  // Content and controls inside every panel are the same nodes they were before the moves.
  for (const id of Layout.PANELS) assert.equal(f.sections.get(id).querySelector(".panel-content").children.length, 1);
});

test("Escape and pointercancel restore the original order mid-drag with focus back on the handle", () => {
  const f = fixture(), prs = drag(f, "prs", 1600, {release: false});
  assert.equal(f.controller.drag?.active, true);
  prs.dispatch("keydown", {key: "Escape"});
  assert.equal(f.controller.drag, null); assert.deepEqual(f.controller.order, [...Layout.PANELS]); assert.deepEqual(domOrder(f.container), [...Layout.PANELS]);
  assert.match(f.announcer.textContent, /Move cancelled\. Open PRs stays at position 1 of 6\./); assert.equal(document.activeElement, prs);
  assert.equal(f.controller.indicator.hidden, true); assert.equal(f.storage.map.size, 0);
  prs.dispatch("pointerup", {pointerId: 1});
  assert.deepEqual(f.controller.order, [...Layout.PANELS], "a late pointerup after cancel is ignored");
  drag(f, "fleet", 50, {release: false}); f.handle("fleet").dispatch("pointercancel", {pointerId: 1});
  assert.equal(f.controller.drag, null); assert.deepEqual(f.controller.order, [...Layout.PANELS]); assert.equal(f.sections.get("fleet").classList.contains("panel-lifting"), false);
});

test("keyboard reordering grabs, moves with arrows, Home and End, drops or cancels, and keeps focus on the handle", () => {
  const f = fixture(), fleet = f.handle("fleet"); fleet.focus();
  assert.equal(fleet.dispatch("keydown", {key: "ArrowUp"}).defaulted, false, "arrows scroll the page until the panel is grabbed");
  assert.equal(fleet.dispatch("keydown", {key: " "}).defaulted, true);
  assert.equal(fleet.attributes["aria-pressed"], "true"); assert.equal(f.sections.get("fleet").classList.contains("panel-grabbed"), true);
  assert.match(f.announcer.textContent, /Fleet sync grabbed at position 5 of 6\. Use the arrow keys/);
  fleet.dispatch("keydown", {key: "ArrowUp"});
  assert.deepEqual(f.controller.order, ["prs", "ci", "agents", "fleet", "history", "budget"]); assert.deepEqual(domOrder(f.container), f.controller.order);
  assert.equal(f.announcer.textContent, "Fleet sync moved to position 4 of 6."); assert.equal(document.activeElement, fleet); assert.equal(f.storage.map.size, 0);
  assert.equal(f.sections.get("fleet").scrolledIntoView, 1);
  for (const key of ["ArrowLeft", "ArrowUp", "ArrowUp"]) fleet.dispatch("keydown", {key});
  assert.deepEqual(f.controller.order, ["fleet", "prs", "ci", "agents", "history", "budget"]);
  fleet.dispatch("keydown", {key: "ArrowUp"}); assert.equal(f.announcer.textContent, "Fleet sync stays at position 1 of 6.");
  fleet.dispatch("keydown", {key: "End"}); assert.equal(f.controller.order.at(-1), "fleet"); assert.equal(f.announcer.textContent, "Fleet sync moved to position 6 of 6.");
  fleet.dispatch("keydown", {key: "Home"}); assert.equal(f.controller.order[0], "fleet");
  fleet.dispatch("keydown", {key: "ArrowDown"}); fleet.dispatch("keydown", {key: "ArrowRight"});
  assert.deepEqual(f.controller.order, ["prs", "ci", "fleet", "agents", "history", "budget"]);
  assert.equal(f.row.parentNode, null, "moving between CI and agents splits the shared row");
  fleet.dispatch("keydown", {key: "ArrowDown"});
  assert.deepEqual(f.row.children.map(node => node.attributes["data-panel"]), ["ci", "agents"], "the pair reunites once adjacent again");
  fleet.dispatch("keydown", {key: "Enter"});
  assert.equal(fleet.attributes["aria-pressed"], "false"); assert.equal(f.sections.get("fleet").classList.contains("panel-grabbed"), false);
  assert.deepEqual(JSON.parse(f.storage.map.get(Layout.STORAGE_KEY)).order, ["prs", "ci", "agents", "fleet", "history", "budget"]);
  assert.equal(f.announcer.textContent, "Fleet sync dropped at position 4 of 6."); assert.equal(document.activeElement, fleet);
  const history = f.handle("history"); history.focus(); history.dispatch("keydown", {key: "Enter"}); history.dispatch("keydown", {key: "ArrowDown"});
  assert.deepEqual(f.controller.order, ["prs", "ci", "agents", "fleet", "budget", "history"]);
  history.dispatch("keydown", {key: "Escape"});
  assert.deepEqual(f.controller.order, ["prs", "ci", "agents", "fleet", "history", "budget"]); assert.deepEqual(domOrder(f.container), f.controller.order);
  assert.match(f.announcer.textContent, /Move cancelled\. Agent history returned to position 5 of 6\./); assert.equal(document.activeElement, history);
  assert.equal(f.controller.grab, null); assert.equal(history.attributes["aria-pressed"], "false");
  // Grabbing another panel releases the first without moving anything.
  history.dispatch("keydown", {key: " "}); f.handle("prs").dispatch("keydown", {key: " "});
  assert.equal(history.attributes["aria-pressed"], "false"); assert.equal(f.handle("prs").attributes["aria-pressed"], "true"); assert.equal(f.controller.grab.id, "prs");
});

test("the saved order survives a reload and Reset layout restores the default and clears storage", () => {
  const storage = new Storage(), first = fixture({storage});
  drag(first, "budget", 50); first.handle("fleet").dispatch("keydown", {key: " "}); first.handle("fleet").dispatch("keydown", {key: "Home"}); first.handle("fleet").dispatch("keydown", {key: " "});
  assert.deepEqual(first.controller.order, ["fleet", "budget", "prs", "ci", "agents", "history"]);
  const reloaded = fixture({storage});
  assert.deepEqual(reloaded.controller.order, ["fleet", "budget", "prs", "ci", "agents", "history"]); assert.deepEqual(domOrder(reloaded.container), reloaded.controller.order);
  assert.equal(reloaded.resetButton.disabled, false);
  reloaded.resetButton.dispatch("click");
  assert.deepEqual(reloaded.controller.order, [...Layout.PANELS]); assert.deepEqual(domOrder(reloaded.container), [...Layout.PANELS]);
  assert.equal(storage.map.has(Layout.STORAGE_KEY), false); assert.equal(reloaded.resetButton.disabled, true);
  assert.equal(reloaded.announcer.textContent, "Layout reset to the default order.");
  assert.deepEqual(fixture({storage}).controller.order, [...Layout.PANELS]);
  const quota = new Storage(); quota.failSet = true; const unsaved = fixture({storage: quota});
  drag(unsaved, "budget", 50); assert.deepEqual(unsaved.controller.order, ["budget", "prs", "ci", "agents", "history", "fleet"]);
});

test("drops follow the panels' current rectangles when the layout narrows or a panel grows mid-drag", () => {
  const narrow = fixture({narrow: true});
  const ci = narrow.sections.get("ci").getBoundingClientRect(), agents = narrow.sections.get("agents").getBoundingClientRect();
  assert.ok(agents.top > ci.bottom, "the pair stacks in a narrow viewport");
  drag(narrow, "budget", 800);
  assert.deepEqual(narrow.controller.order, ["prs", "ci", "agents", "budget", "history", "fleet"], "the stacked pair still counts as one row");
  const f = fixture(), handle = drag(f, "history", 850, {release: false});
  assert.equal(f.controller.drag.slot.before, "fleet");
  document.narrow = true; f.sections.get("prs").height = 900;
  handle.dispatch("pointermove", {pointerId: 1, clientX: 12, clientY: 850});
  assert.deepEqual(f.controller.drag.slot, {index: 1, before: null, after: "prs", edge: 900}, "the enlarged first panel is measured as it is now");
  handle.dispatch("pointerup", {pointerId: 1});
  assert.deepEqual(f.controller.order, ["prs", "history", "ci", "agents", "fleet", "budget"]);
  // A panel that grows after the last pointermove is re-measured at release, so the drop lands where the pointer is.
  const late = fixture(), lateHandle = drag(late, "budget", 390, {release: false});
  assert.equal(late.controller.drag.slot.index, 1, "after prs at the last move");
  late.sections.get("prs").height = 900;
  lateHandle.dispatch("pointerup", {pointerId: 1});
  assert.deepEqual(late.controller.order, ["budget", "prs", "ci", "agents", "history", "fleet"]);
});

test("live snapshot renders during a drag or grab never reset the order, end the interaction or recreate the handle", () => {
  const f = fixture(), handles = new Map(Layout.PANELS.map(id => [id, f.handle(id)]));
  const rerender = () => {
    // The shell only ever rewrites each panel's content container; the sections and handles stay.
    for (const id of Layout.PANELS) {const content = f.sections.get(id).querySelector(".panel-content"); content.textContent = ""; content.append(new Node("div"), new Node("button"));}
    f.sections.get("prs").height = 700; f.sections.get("agents").height = 900;
  };
  const handle = drag(f, "fleet", 50, {release: false}); rerender();
  assert.equal(f.controller.drag?.active, true); assert.deepEqual(f.controller.order, [...Layout.PANELS]); assert.equal(document.activeElement, handle);
  handle.dispatch("pointermove", {pointerId: 1, clientX: 12, clientY: 300});
  assert.deepEqual(f.controller.drag.slot, {index: 0, before: "prs", after: null, edge: 0}, "the grown first panel now spans the pointer");
  handle.dispatch("pointerup", {pointerId: 1});
  assert.deepEqual(f.controller.order, ["fleet", "prs", "ci", "agents", "history", "budget"]);
  for (const id of Layout.PANELS) assert.equal(f.handle(id), handles.get(id));
  const prs = f.handle("prs"); prs.focus(); prs.dispatch("keydown", {key: " "}); rerender(); prs.dispatch("keydown", {key: "ArrowDown"});
  assert.equal(f.controller.grab?.id, "prs"); assert.equal(document.activeElement, prs);
  assert.deepEqual(f.controller.order, ["fleet", "ci", "prs", "agents", "history", "budget"]);
  rerender(); prs.dispatch("keydown", {key: " "});
  assert.deepEqual(JSON.parse(f.storage.map.get(Layout.STORAGE_KEY)).order, ["fleet", "ci", "prs", "agents", "history", "budget"]);
  assert.equal(f.announcer.textContent, "Open PRs dropped at position 3 of 6.");
  assert.equal(f.sections.get("prs").querySelector(".panel-content").children.length, 2); assert.equal(document.activeElement, prs);
  // A focused control inside a moved panel keeps focus too.
  const inner = f.sections.get("budget").querySelector(".panel-content").children[1]; inner.focus();
  f.handle("budget").dispatch("keydown", {key: " "});
  assert.equal(document.activeElement, inner);
  f.controller.apply(["budget", ...f.controller.order.filter(id => id !== "budget")]);
  assert.equal(document.activeElement, inner); assert.equal(inner.isConnected, true);
});

test("moves animate with a FLIP transform under normal motion and jump under reduced motion", () => {
  const animated = fixture(); animated.handle("budget").dispatch("keydown", {key: " "}); animated.handle("budget").dispatch("keydown", {key: "Home"});
  const moved = [...animated.sections.values()].filter(node => node.style.transform);
  assert.ok(moved.length >= 2); assert.match(moved[0].style.transform, /translate\(/); assert.equal(moved[0].style.transition, "none");
  assert.equal(animated.rafs.length, 1); animated.rafs[0]();
  for (const node of moved) {assert.equal(node.style.transform, ""); assert.equal(node.classList.contains("panel-flip"), true);}
  for (const fn of animated.timers) fn();
  for (const node of moved) assert.equal(node.classList.contains("panel-flip"), false);
  const reduced = fixture({reduced: true}); reduced.handle("budget").dispatch("keydown", {key: " "}); reduced.handle("budget").dispatch("keydown", {key: "Home"});
  assert.ok([...reduced.sections.values()].every(node => !node.style.transform)); assert.equal(reduced.rafs.length, 0);
  assert.deepEqual(reduced.controller.order, ["budget", "prs", "ci", "agents", "history", "fleet"]);
});

test("the shipped shell wires the module: grid container, six data-panel sections, hint, reset button, live region and assets", () => {
  const html = fs.readFileSync(path.join(root, "mergepath/cockpit/index.html"), "utf8");
  assert.match(html, /<div id="panel-grid" class="panel-grid">/);
  for (const id of Layout.PANELS) assert.match(html, new RegExp(`<section class="panel[^"]*" data-panel="${id}" aria-labelledby="${id}">`));
  assert.ok(html.indexOf('data-panel="ci"') < html.indexOf('data-panel="agents"') && html.includes('<div class="row2">'));
  assert.match(html, /<button class="btn" id="layout-reset" type="button" disabled>Reset layout<\/button>/);
  assert.match(html, /<span class="sub" id="layout-hint">/); assert.match(html, /<p class="sr-only" id="layout-announcement" role="status" aria-live="polite"><\/p>/);
  assert.ok(html.indexOf('href="assets/layout.css"') > html.indexOf('href="assets/cockpit.css"'));
  assert.ok(html.indexOf('src="assets/layout.js"') > html.indexOf('src="assets/app.js"'));
  const css = fs.readFileSync(path.join(root, "mergepath/cockpit/assets/layout.css"), "utf8");
  assert.match(css, /\.panel-handle\{[^}]*touch-action:none/); assert.match(css, /\.panel-flip\{transition:transform var\(--t-med\) var\(--ease\)\}/);
  assert.match(css, /\.drop-indicator\{position:fixed/); assert.match(css, /\.panel-handle\{[^}]*cursor:grab/);
  // install() finds the shell by its ids and tolerates a page without the grid.
  document.body = new Node("body"); document.activeElement = document.body;
  const container = new Node("div"); container.className = "panel-grid"; const row = new Node("div"); row.className = "row2";
  const sections = Object.fromEntries(Layout.PANELS.map(id => [id, section(id, id, 100)]));
  container.append(sections.prs, row, sections.history, sections.fleet, sections.budget); row.append(sections.ci, sections.agents);
  const reset = new Node("button"), live = new Node("p"); document.body.append(container, reset, live);
  const ids = {"panel-grid": container, "layout-reset": reset, "layout-announcement": live};
  const doc = {body: document.body, createElement: tag => new Node(tag), getElementById: id => ids[id] ?? null};
  const saved = globalThis.localStorage; const storage = new Storage(); storage.setItem(Layout.STORAGE_KEY, JSON.stringify({v: 1, order: ["budget", "prs", "ci", "agents", "history", "fleet"]}));
  globalThis.localStorage = storage;
  try {
    const controller = Layout.install(doc);
    assert.deepEqual(controller.order, ["budget", "prs", "ci", "agents", "history", "fleet"]); assert.equal(controller.row, row); assert.equal(controller.handles.size, 6);
    assert.equal(Layout.install({getElementById: () => null}), null);
  } finally {if (saved === undefined) delete globalThis.localStorage; else globalThis.localStorage = saved;}
});
