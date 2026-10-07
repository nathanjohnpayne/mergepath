/* Operator-arranged panel order: pure order helpers plus one DOM controller. */
"use strict";
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else {root.CockpitLayout = api; api.install();}
})(globalThis, function () {
  const PANELS = Object.freeze(["prs", "ci", "agents", "history", "fleet", "budget"]);
  // Every panel set a saved order may legitimately hold. When a panel is added, the previous
  // set is appended here so orders saved before it still load and the new panel appends.
  const KNOWN_PANEL_SETS = Object.freeze([PANELS]);
  // The shipped design seats CI and the Phase 4b agents side by side; they keep sharing
  // a row whenever they are adjacent, in either order. Every other row is one panel.
  const PAIR = Object.freeze(["ci", "agents"]);
  const STORAGE_KEY = "cockpit-layout";
  const THRESHOLD = 4, EDGE = 64, STEP = 18, GAP = 18;
  // A stored order is trusted only whole: every id known, none repeated, and the set exactly
  // one of the panel sets this page has ever saved. Anything else is corrupt and falls back to
  // the default. A recognized older set lacks only panels added since, which append in default order.
  const sameSet = (a, b) => a.length === b.length && a.every(id => b.includes(id));
  function validOrder(value, defaults = PANELS, knownSets = KNOWN_PANEL_SETS) {
    return Array.isArray(value) && value.every(id => typeof id === "string" && defaults.includes(id)) && new Set(value).size === value.length
      && (sameSet(value, defaults) || knownSets.some(set => sameSet(value, set)));
  }
  function normalizeOrder(value, defaults = PANELS, knownSets = KNOWN_PANEL_SETS) {
    if (!validOrder(value, defaults, knownSets)) return [...defaults];
    return [...value, ...defaults.filter(id => !value.includes(id))];
  }
  const sameOrder = (a, b) => a.length === b.length && a.every((id, index) => id === b[index]);
  // The result places `id` at `index`; indexes outside the list clamp to its ends.
  function moveTo(order, id, index) {
    const remaining = order.filter(item => item !== id);
    if (remaining.length === order.length || !Number.isFinite(index)) return [...order];
    const slot = Math.max(0, Math.min(remaining.length, Math.trunc(index)));
    return [...remaining.slice(0, slot), id, ...remaining.slice(slot)];
  }
  function rowsFor(order, pair = PAIR) {
    const rows = [];
    for (let i = 0; i < order.length; i++) {
      const a = order[i], b = order[i + 1];
      if (b !== undefined && a !== b && pair.includes(a) && pair.includes(b)) {rows.push([a, b]); i++;}
      else rows.push([a]);
    }
    return rows;
  }
  // items: the panels that are not being dragged, in order, with their current viewport
  // top/bottom. A shared row is one unit: drop above its middle to go before it, below
  // to go after it. The returned index is the dragged panel's final position.
  function dropSlot(items, y, pair = PAIR) {
    if (!items.length) return {index: 0, before: null, after: null, edge: null};
    const byId = new Map(items.map(item => [item.id, item]));
    const rows = rowsFor(items.map(item => item.id), pair).map(ids => ({ids,
      top: Math.min(...ids.map(id => byId.get(id).top)), bottom: Math.max(...ids.map(id => byId.get(id).bottom))}));
    const row = rows.find(candidate => y < candidate.bottom);
    if (!row) {
      const last = rows[rows.length - 1], id = last.ids[last.ids.length - 1];
      return {index: items.length, before: null, after: id, edge: last.bottom};
    }
    if (y < (row.top + row.bottom) / 2) {
      const id = row.ids[0];
      return {index: items.findIndex(item => item.id === id), before: id, after: null, edge: row.top};
    }
    const id = row.ids[row.ids.length - 1];
    return {index: items.findIndex(item => item.id === id) + 1, before: null, after: id, edge: row.bottom};
  }
  class LayoutStore {
    constructor(storage, key = STORAGE_KEY, defaults = PANELS, knownSets = KNOWN_PANEL_SETS) {Object.assign(this, {storage, key, defaults: [...defaults], knownSets});}
    load() {
      try {
        const raw = this.storage?.getItem(this.key);
        if (typeof raw !== "string") return [...this.defaults];
        const value = JSON.parse(raw);
        // Only the version-1 object this store writes is read; any other shape is corrupt.
        if (!value || typeof value !== "object" || Array.isArray(value) || value.v !== 1) return [...this.defaults];
        return normalizeOrder(value.order, this.defaults, this.knownSets);
      } catch {return [...this.defaults];}
    }
    save(order) {try {this.storage?.setItem(this.key, JSON.stringify({v: 1, order: [...order]}));} catch { /* The session order still applies. */ }}
    clear() {try {this.storage?.removeItem(this.key);} catch { /* Nothing durable to clear. */ }}
  }
  class LayoutController {
    constructor({container, sections, row = null, resetButton = null, announcer = null, hintId = null, store, defaults = PANELS, pair = PAIR, knownSets = KNOWN_PANEL_SETS,
      raf = fn => globalThis.requestAnimationFrame?.(fn), caf = id => globalThis.cancelAnimationFrame?.(id),
      scrollBy = (x, y) => globalThis.scrollBy?.(x, y), viewportHeight = () => globalThis.innerHeight ?? Infinity,
      reducedMotion = () => document.body?.classList?.contains("rm") === true || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true,
      setTimer = (fn, delay) => globalThis.setTimeout(fn, delay)}) {
      Object.assign(this, {container, sections, resetButton, announcer, hintId, store, defaults: [...defaults], pair: [...pair], knownSets,
        raf, caf, scrollBy, viewportHeight, reducedMotion, setTimer});
      this.handles = new Map(); this.order = [...this.defaults]; this.grab = null; this.drag = null;
      this.row = row || document.createElement("div"); if (!row) this.row.className = "row2";
      this.indicator = document.createElement("div"); this.indicator.className = "drop-indicator";
      this.indicator.setAttribute("aria-hidden", "true"); this.indicator.hidden = true;
    }
    title(id) {return this.sections.get(id).querySelector?.("h2")?.textContent?.trim() || id;}
    position(id, order = this.order) {return `position ${order.indexOf(id) + 1} of ${order.length}`;}
    announce(text) {if (this.announcer) this.announcer.textContent = text;}
    mount() {
      for (const id of this.defaults) {
        const section = this.sections.get(id), head = section.querySelector?.(".sec-head") || section;
        const handle = document.createElement("button"); handle.type = "button"; handle.className = "panel-handle";
        handle.setAttribute("aria-label", `Move ${this.title(id)} panel`); handle.setAttribute("aria-pressed", "false");
        if (this.hintId) handle.setAttribute("aria-describedby", this.hintId);
        head.insertBefore(handle, head.firstChild || null);
        handle.addEventListener("keydown", event => this.onKey(id, event));
        handle.addEventListener("pointerdown", event => this.onPointerDown(id, event));
        handle.addEventListener("pointermove", event => this.onPointerMove(event));
        handle.addEventListener("pointerup", event => this.onPointerUp(event));
        // A browser-cancelled drag (touch scroll takeover, pen leaving range) is a cancellation the live region must report.
        handle.addEventListener("pointercancel", () => this.cancelDrag(true));
        this.handles.set(id, handle);
      }
      document.body.append(this.indicator);
      this.resetButton?.addEventListener("click", () => this.reset());
      this.apply(this.store.load(), {animate: false});
      return this;
    }
    apply(value, {animate = true} = {}) {
      const order = normalizeOrder(value, this.defaults, this.knownSets);
      const before = animate && !this.reducedMotion() ? this.measure() : null;
      const focus = document.activeElement, expected = [];
      for (const ids of rowsFor(order, this.pair)) {
        if (ids.length === 2) {
          ids.forEach((id, index) => {const node = this.sections.get(id); if (this.row.children[index] !== node) this.row.insertBefore(node, this.row.children[index] || null);});
          expected.push(this.row);
        } else expected.push(this.sections.get(ids[0]));
      }
      expected.forEach((node, index) => {if (this.container.children[index] !== node) this.container.insertBefore(node, this.container.children[index] || null);});
      if (!expected.includes(this.row) && this.row.parentNode) this.row.remove();
      // Moving a subtree drops focus; a focused control inside a moved panel keeps it.
      if (focus && focus !== document.body && focus.isConnected && document.activeElement !== focus) focus.focus({preventScroll: true});
      this.order = order;
      if (this.resetButton) this.resetButton.disabled = sameOrder(order, this.defaults);
      if (before) this.flip(before);
      return this.order;
    }
    measure() {
      const rects = new Map();
      for (const [id, section] of this.sections) {const rect = section.getBoundingClientRect(); rects.set(id, {top: rect.top, left: rect.left});}
      return rects;
    }
    flip(before) {
      const moves = [];
      for (const [id, section] of this.sections) {
        const rect = section.getBoundingClientRect(), prior = before.get(id), dx = prior.left - rect.left, dy = prior.top - rect.top;
        if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) moves.push({section, dx, dy});
      }
      if (!moves.length) return;
      for (const {section, dx, dy} of moves) {section.style.transition = "none"; section.style.transform = `translate(${dx}px, ${dy}px)`;}
      void this.container.getBoundingClientRect?.();
      this.raf(() => {
        for (const {section} of moves) {
          section.classList.add("panel-flip"); section.style.transition = ""; section.style.transform = "";
          this.setTimer(() => section.classList.remove("panel-flip"), 500);
        }
      });
    }
    setGrabbed(id, on) {this.handles.get(id).setAttribute("aria-pressed", String(on)); this.sections.get(id).classList.toggle("panel-grabbed", on);}
    commit(order, id, verb, baseline = this.order) {
      const changed = !sameOrder(order, baseline);
      this.apply(order, {animate: true});
      this.store.save(this.order);
      this.announce(`${this.title(id)} ${verb} at ${this.position(id)}${changed ? "" : ", unchanged"}.`);
      this.handles.get(id).focus?.({preventScroll: true});
    }
    onKey(id, event) {
      const key = event.key;
      if (key === " " || key === "Spacebar" || key === "Enter") {
        event.preventDefault?.();
        if (this.drag) return;
        if (this.grab?.id === id) {const origin = this.grab.origin; this.grab = null; this.setGrabbed(id, false); this.commit(this.order, id, "dropped", origin); return;}
        if (this.grab) this.cancelGrab(false);
        this.grab = {id, origin: [...this.order]}; this.setGrabbed(id, true);
        this.announce(`${this.title(id)} grabbed at ${this.position(id)}. Use the arrow keys to move it, Space or Enter to drop, Escape to cancel.`);
        return;
      }
      if (key === "Escape") {
        if (this.drag) {event.preventDefault?.(); this.cancelDrag(true);}
        else if (this.grab?.id === id) {event.preventDefault?.(); this.cancelGrab(true);}
        return;
      }
      if (this.grab?.id !== id) return;
      const index = this.order.indexOf(id);
      const target = key === "ArrowUp" || key === "ArrowLeft" ? index - 1 : key === "ArrowDown" || key === "ArrowRight" ? index + 1
        : key === "Home" ? 0 : key === "End" ? this.order.length - 1 : null;
      if (target === null) return;
      event.preventDefault?.();
      const order = moveTo(this.order, id, target), changed = !sameOrder(order, this.order);
      if (changed) {this.apply(order, {animate: true}); this.handles.get(id).focus?.({preventScroll: true}); this.sections.get(id).scrollIntoView?.({block: "nearest"});}
      this.announce(`${this.title(id)} ${changed ? "moved to" : "stays at"} ${this.position(id)}.`);
    }
    cancelGrab(announce) {
      const grab = this.grab; if (!grab) return;
      this.grab = null; this.setGrabbed(grab.id, false); this.apply(grab.origin, {animate: true});
      this.handles.get(grab.id).focus?.({preventScroll: true});
      if (announce) this.announce(`Move cancelled. ${this.title(grab.id)} returned to ${this.position(grab.id)}.`);
    }
    onPointerDown(id, event) {
      if ((event.button !== undefined && event.button !== 0) || this.drag) return;
      if (this.grab) this.cancelGrab(false);
      this.drag = {id, pointerId: event.pointerId, startX: event.clientX, startY: event.clientY, x: event.clientX, y: event.clientY,
        active: false, origin: [...this.order], slot: null, frame: null, handle: this.handles.get(id)};
      try {this.drag.handle.setPointerCapture?.(event.pointerId);} catch { /* Capture is an enhancement. */ }
      event.preventDefault?.();
      this.drag.handle.focus?.({preventScroll: true});
    }
    onPointerMove(event) {
      const drag = this.drag;
      if (!drag || event.pointerId !== drag.pointerId) return;
      drag.x = event.clientX; drag.y = event.clientY;
      if (!drag.active) {
        if (Math.hypot(drag.x - drag.startX, drag.y - drag.startY) < THRESHOLD) return;
        drag.active = true;
        this.sections.get(drag.id).classList.add("panel-lifting"); document.body.classList.add("layout-dragging");
        drag.handle.setAttribute("aria-pressed", "true");
        this.announce(`${this.title(drag.id)} picked up. Release to place it, or press Escape to cancel.`);
        const loop = () => {if (this.drag !== drag) return; this.autoScroll(drag); drag.frame = this.raf(loop);};
        drag.frame = this.raf(loop);
      }
      this.track(drag);
    }
    autoScroll(drag) {
      const height = this.viewportHeight();
      const delta = drag.y < EDGE ? -STEP * (1 - Math.max(0, drag.y) / EDGE) : drag.y > height - EDGE ? STEP * (1 - Math.max(0, height - drag.y) / EDGE) : 0;
      if (delta) {this.scrollBy(0, delta); this.track(drag);}
    }
    track(drag) {
      // Rects are read on every move, so a panel that grew from a live snapshot is measured as it is now.
      const items = this.order.filter(id => id !== drag.id).map(id => {
        const rect = this.sections.get(id).getBoundingClientRect(); return {id, top: rect.top, bottom: rect.bottom};
      });
      drag.slot = dropSlot(items, drag.y, this.pair);
      const rect = this.container.getBoundingClientRect();
      this.indicator.hidden = false;
      this.indicator.style.left = `${rect.left}px`; this.indicator.style.width = `${rect.width}px`;
      this.indicator.style.top = `${(drag.slot.edge ?? rect.top) + (drag.slot.before ? -GAP / 2 : GAP / 2) - 1.5}px`;
    }
    onPointerUp(event) {
      const drag = this.drag;
      if (!drag || event.pointerId !== drag.pointerId) return;
      // A live snapshot can resize panels after the last move; measure once more at release.
      if (drag.active) this.track(drag);
      this.endDrag(drag);
      if (!drag.active) return;
      const items = this.order.filter(id => id !== drag.id);
      const order = drag.slot ? [...items.slice(0, drag.slot.index), drag.id, ...items.slice(drag.slot.index)] : [...this.order];
      this.commit(order, drag.id, "dropped");
    }
    cancelDrag(announce) {
      const drag = this.drag; if (!drag) return;
      this.endDrag(drag);
      if (!drag.active) return;
      this.apply(drag.origin, {animate: false}); drag.handle.focus?.({preventScroll: true});
      if (announce) this.announce(`Move cancelled. ${this.title(drag.id)} stays at ${this.position(drag.id)}.`);
    }
    endDrag(drag) {
      this.drag = null;
      if (drag.frame !== null && drag.frame !== undefined) this.caf?.(drag.frame);
      this.indicator.hidden = true; document.body.classList.remove("layout-dragging");
      this.sections.get(drag.id).classList.remove("panel-lifting"); drag.handle.setAttribute("aria-pressed", "false");
      try {drag.handle.releasePointerCapture?.(drag.pointerId);} catch { /* Already released. */ }
    }
    reset() {
      if (this.drag) this.cancelDrag(false);
      if (this.grab) this.cancelGrab(false);
      this.apply(this.defaults, {animate: true}); this.store.clear();
      this.announce("Layout reset to the default order.");
    }
  }
  function install(doc = globalThis.document) {
    const container = doc?.getElementById?.("panel-grid");
    if (!container) return null;
    const sections = new Map(PANELS.map(id => [id, container.querySelector(`[data-panel="${id}"]`)]));
    if ([...sections.values()].some(section => !section)) return null;
    let storage = null;
    try {storage = globalThis.localStorage;} catch {storage = null;}
    const controller = new LayoutController({container, sections, row: container.querySelector(":scope > .row2"),
      resetButton: doc.getElementById("layout-reset"), announcer: doc.getElementById("layout-announcement"), hintId: "layout-hint",
      store: new LayoutStore(storage)});
    return controller.mount();
  }
  return {PANELS, PAIR, KNOWN_PANEL_SETS, STORAGE_KEY, validOrder, normalizeOrder, sameOrder, moveTo, rowsFor, dropSlot, LayoutStore, LayoutController, install};
});
