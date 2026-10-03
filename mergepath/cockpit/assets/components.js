/* Shared presentation only. Provider classifiers belong to their own adapters. */
"use strict";
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.CockpitComponents = api;
})(globalThis, function () {
  const STATES = Object.freeze(["idle", "running", "clear", "bump", "boulder", "done"]);
  const SECTIONS = Object.freeze(["road", "prs", "ci", "agents", "history", "fleet", "budget"]);
  const LABELS = Object.freeze({idle: "Idle", running: "Running", clear: "Clear", bump: "Speed bump", boulder: "Boulder", done: "Done"});
  const RANK = Object.freeze({boulder: 0, bump: 1, running: 2, clear: 3, done: 3, idle: 4});
  const finite = value => typeof value === "number" && Number.isFinite(value);
  const count = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
  const epoch = value => finite(value) && value >= 0 ? value : null;
  const tone = state => state === "running" ? "run" : state;
  function worstState(states) {
    return states.reduce((worst, state) => STATES.includes(state) && RANK[state] < RANK[worst] ? state : worst, "idle");
  }
  function ageLabel(seconds) {
    if (!finite(seconds)) return "Unknown age";
    const age = Math.max(0, Math.floor(seconds));
    return age < 60 ? `${age}s ago` : age < 3600 ? `${Math.floor(age / 60)}m ago` : age < 86400 ? `${Math.floor(age / 3600)}h ago` : `${Math.floor(age / 86400)}d ago`;
  }
  function timeLabel(timing, now) {
    if (timing.kind === "unknown") return "Timing unknown";
    if (timing.kind === "now" || timing.at <= now) return "Now";
    const minutes = Math.ceil((timing.at - now) / 60);
    return minutes < 60 ? `in ${minutes} min` : minutes < 1440 ? `in ${Math.ceil(minutes / 60)} hr` : `in ${Math.ceil(minutes / 1440)} days`;
  }
  function meterModel(evidence = {}, now = Date.now() / 1000) {
    const limit = count(evidence.limit), lastKnownRemaining = count(evidence.remaining);
    let used = count(evidence.used);
    if (used === null && limit !== null && lastKnownRemaining !== null && lastKnownRemaining <= limit) used = limit - lastKnownRemaining;
    const lastKnownUsed = used, reset = epoch(evidence.reset), expired = reset !== null && reset <= now;
    const remaining = expired ? null : lastKnownRemaining;
    if (expired) used = null;
    const ratio = limit !== null && limit > 0 && used !== null ? used / limit : null;
    const primary = evidence.primary_exhausted === true && reset !== null && reset > now;
    const state = evidence.secondary_limited === true || primary ? "boulder"
      : ratio === null ? "idle" : ratio >= 1 ? "boulder" : ratio >= .7 ? "bump" : "clear";
    return {limit, remaining, used, lastKnownRemaining, lastKnownUsed, expired, ratio, state, percent: ratio === null ? null : Math.min(100, Math.max(0, ratio * 100)),
      reason: evidence.secondary_limited === true ? `Secondary throttle${expired ? " · last observed" : ""}` : primary ? "Primary pool exhausted" : expired ? "Usage unavailable after reset" : ratio === null ? "Usage unavailable" : `${Math.round(ratio * 100)}% used`};
  }
  function normalizeHazards(values, repositories) {
    const hazards = [], diagnostics = [], ids = new Set();
    if (!Array.isArray(values)) return {hazards, diagnostics: ["Hazard output unavailable: expected a list."]};
    for (const value of values) {
      const text = (key, max) => typeof value?.[key] === "string" && value[key].trim().length > 0 && value[key].length <= max;
      const timing = value?.timing;
      if (!value || !text("id", 256) || !SECTIONS.includes(value.source) || !SECTIONS.includes(value.section)
          || !["bump", "boulder"].includes(value.state) || !text("title", 240) || typeof value.detail !== "string" || value.detail.length > 4000
          || !(value.repo === null || repositories.includes(value.repo)) || typeof value.stale !== "boolean"
          || !(value.observed_at === null || epoch(value.observed_at) !== null)
          || !timing || !["now", "at", "unknown"].includes(timing.kind) || (timing.kind === "at" && epoch(timing.at) === null)
          || Object.hasOwn(value, "href") || Object.hasOwn(value, "html") || ids.has(value.id)) {
        diagnostics.push("An adapter hazard was refused: invalid fields or duplicate identity.");
        continue;
      }
      ids.add(value.id);
      hazards.push({id: value.id, source: value.source, section: value.section, repo: value.repo, state: value.state,
        title: value.title, detail: value.detail, observed_at: value.observed_at, stale: value.stale,
        timing: timing.kind === "at" ? {kind: "at", at: timing.at} : {kind: timing.kind}});
    }
    return {hazards, diagnostics};
  }
  function filterHazards(hazards, repo) {
    return hazards.filter(hazard => repo === null || hazard.repo === null || hazard.repo === repo);
  }
  function hazardMinutes(hazard, now) {
    return hazard.timing.kind === "unknown" ? null : hazard.timing.kind === "now" ? 0 : Math.max(0, (hazard.timing.at - now) / 60);
  }
  function logPosition(minutes, horizonMinutes) {
    if (!finite(minutes) || minutes < 0 || !finite(horizonMinutes) || horizonMinutes <= 0) return null;
    return 4 + 90 * Math.min(1, Math.log1p(minutes) / Math.log1p(horizonMinutes));
  }
  function roadModel(hazards, {now, horizonMinutes = null, horizonLabel = "Horizon unavailable", width = 1000, observed = false, staleCoverage = false, invalidCoverage = false} = {}) {
    const validHorizon = finite(horizonMinutes) && horizonMinutes > 0;
    const items = hazards.map(hazard => {
      const minutes = hazardMinutes(hazard, now);
      return {...hazard, minutes, position: minutes === 0 ? 4 : validHorizon && minutes !== null ? logPosition(minutes, horizonMinutes) : null,
        beyond: validHorizon && minutes !== null && minutes > horizonMinutes};
    }).sort((a, b) => (a.minutes ?? Infinity) - (b.minutes ?? Infinity) || RANK[a.state] - RANK[b.state] || a.id.localeCompare(b.id));
    const capacity = Math.min(9, Math.max(0, Math.floor((width - 20) / 28) + 1));
    const chosen = items.filter(item => item.position !== null).sort((a, b) => RANK[a.state] - RANK[b.state] || a.minutes - b.minutes || a.id.localeCompare(b.id)).slice(0, capacity);
    const selected = new Set(chosen.map(item => item.id));
    // Keep applicable reference ticks, dropping labels that would collide with Now/end or each other.
    let previousTick = 35;
    const ticks = validHorizon ? [{minutes: 15, label: "15 min"}, {minutes: 60, label: "1 h"}, {minutes: 1440, label: "today"}].flatMap(tick => {
      const position = logPosition(tick.minutes, horizonMinutes), x = position * width / 100;
      if (tick.minutes >= horizonMinutes || x < previousTick + 42 || x > width - 125) return [];
      previousTick = x; return [{...tick, position}];
    }) : [];
    return {items, ticks, strip: items.filter(item => selected.has(item.id)), deferred: items.filter(item => item.position === null).length,
      overflow: items.length - selected.size, observed, staleCoverage, invalidCoverage,
      emptyState: observed && !items.length ? "clear" : "idle",
      emptyText: items.length ? "See the full list for timing" : observed ? "Road is clear for fresh observed sources" : invalidCoverage ? "Observations unavailable" : staleCoverage ? "Last-known observations are stale" : "No observations yet",
      horizonLabel: validHorizon ? horizonLabel : "Horizon unavailable", validHorizon};
  }
  function packRoad(markers, width, measure = text => text.length * 6) {
    const bounds = [10, Math.max(10, width - 10)], lanes = [[], [], [], []];
    const packed = markers.map(marker => ({...marker, x: Math.min(bounds[1], Math.max(bounds[0], marker.position * width / 100))}));
    for (let i = 1; i < packed.length; i++) packed[i].x = Math.max(packed[i].x, packed[i - 1].x + 28);
    if (packed.length) packed[packed.length - 1].x = Math.min(bounds[1], packed[packed.length - 1].x);
    for (let i = packed.length - 2; i >= 0; i--) packed[i].x = Math.min(packed[i].x, packed[i + 1].x - 28);
    function place(marker, short, allowed) {
        const number = String(marker.number), size = Math.min(width - 20, Math.ceil(short ? measure(number, true) + 14 : measure(marker.title, false) + measure(number, true) + 22));
        const left = Math.max(0, Math.min(width - size, marker.x - size / 2)), right = left + size;
        const lane = allowed.find(index => lanes[index].every(interval => right + (short ? 3 : 8) <= interval[0] || left >= interval[1] + (short ? 3 : 8)));
        if (lane !== undefined) {
          lanes[lane].push([left, right]);
          Object.assign(marker, {lane, left, labelWidth: size, short});
          return true;
        }
        return false;
    }
    for (const marker of packed) place(marker, false, [1, 2, 3]);
    for (const marker of packed) if (marker.lane === undefined) place(marker, true, [0, 1, 2, 3]);
    return packed;
  }
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function glyph(state, size = "") {
    if (!STATES.includes(state)) state = "idle";
    const node = element("span", `g g-${tone(state)} ${size}`.trim());
    node.setAttribute("aria-hidden", "true");
    return node;
  }
  function badge(state, label = LABELS[state] || LABELS.idle) {
    if (!STATES.includes(state)) state = "idle";
    const node = element("span", `b b-${tone(state)}`);
    node.append(glyph(state), element("span", "", label));
    return node;
  }
  class MeterView {
    constructor(parent) {
      this.root = element("div", "m unknown");
      const top = element("div", "m-top");
      this.value = element("span", "m-val", "Unknown");
      this.denominator = element("span", "m-den", "Limit unknown");
      top.append(this.value, this.denominator);
      this.track = element("div", "m-track");
      this.fill = element("span", "m-fill t-idle");
      this.tick = element("span", "m-tick");
      this.tick.style.left = "70%";
      this.cap = element("span", "m-cap");
      this.track.append(this.fill, this.tick, this.cap);
      this.reason = element("span", "sub");
      this.root.append(top, this.track, this.reason);
      parent.append(this.root);
      this.previous = "idle";
    }
    update(evidence, {unit = "requests", now = Date.now() / 1000} = {}) {
      const model = meterModel(evidence, now), fmt = value => value === null ? "unknown" : value.toLocaleString("en-US");
      this.root.className = `m t-${tone(model.state)}${model.percent === null ? " unknown" : ""}`;
      this.value.textContent = model.remaining === null ? "Remaining unknown" : `${fmt(model.remaining)} left`;
      this.denominator.textContent = model.limit === null ? "Limit unknown" : `of ${fmt(model.limit)} ${unit}`;
      this.fill.className = `m-fill t-${tone(model.state)}`;
      this.fill.style.width = `${model.percent ?? 0}%`;
      this.reason.textContent = model.reason + (model.expired ? ` · last known ${fmt(model.lastKnownRemaining)} left / ${fmt(model.lastKnownUsed)} used` : "");
      this.track.setAttribute("role", model.percent === null ? "img" : "meter");
      this.track.setAttribute("aria-label", `${model.reason}; ${this.value.textContent}; ${this.denominator.textContent}`);
      if (model.percent !== null) {
        this.track.setAttribute("aria-valuemin", "0");
        this.track.setAttribute("aria-valuemax", "100");
        this.track.setAttribute("aria-valuenow", String(model.percent));
      } else for (const key of ["aria-valuemin", "aria-valuemax", "aria-valuenow"]) this.track.removeAttribute(key);
      if (model.state !== this.previous) {
        const cap = element("span", "m-cap");
        this.cap.replaceWith(cap); this.cap = cap;
        if (["bump", "boulder"].includes(model.state)) {
          this.cap.append(glyph(model.state));
          if (!document.body.classList.contains("rm")) this.cap.classList.add("fresh");
          cap.addEventListener("animationend", () => cap.classList.remove("fresh"), {once: true});
        }
        this.previous = model.state;
      }
      return model;
    }
  }
  class RoadView {
    constructor(parent) {
      this.markers = new Map(); this.rows = new Map(); this.seenRows = new Set(); this.seenMarkers = new Set();
      this.strip = element("div", "strip"); this.strip.setAttribute("aria-hidden", "true");
      this.line = element("div", "line");
      this.empty = element("div", "road-empty");
      this.end = element("span", "hz end", "Horizon unavailable");
      this.ticks = new Map();
      this.strip.append(this.line, element("span", "now", "NOW"), this.end, this.empty);
      this.more = element("a", "more"); this.more.href = "#road-hazards";
      this.list = element("ol", "road-list"); this.list.id = "road-hazards"; this.list.tabIndex = -1;
      parent.append(this.strip, this.more, this.list);
      this.canvas = document.createElement("canvas");
    }
    update(hazards, options) {
      const focus = document.activeElement, width = Math.max(40, this.strip.clientWidth);
      const model = roadModel(hazards, {...options, width});
      this.end.textContent = model.horizonLabel;
      for (const [minutes, node] of this.ticks) if (!model.ticks.some(tick => tick.minutes === minutes)) {node.remove(); this.ticks.delete(minutes);}
      for (const tick of model.ticks) {
        let node = this.ticks.get(tick.minutes);
        if (!node) {node = element("span", "hz", tick.label); this.strip.append(node); this.ticks.set(tick.minutes, node);}
        node.style.left = `${tick.position}%`;
      }
      this.more.textContent = model.overflow ? `${model.overflow} more in the full list${model.deferred ? ` · ${model.deferred} await timing or horizon` : ""}` : "";
      this.more.hidden = !model.overflow;
      this.empty.hidden = model.strip.length > 0;
      this.empty.className = `road-empty${model.emptyState === "clear" ? " clear" : ""}`;
      this.empty.replaceChildren(glyph(model.emptyState, "lg"), element("span", "", model.emptyText));
      const keepRows = new Set(model.items.map(item => item.id)), keepMarkers = new Set(model.strip.map(item => item.id));
      for (const [id, node] of this.rows) if (!keepRows.has(id)) {node.remove(); this.rows.delete(id);}
      for (const [id, node] of this.markers) if (!keepMarkers.has(id)) {node.remove(); this.markers.delete(id);}
      model.items.forEach((item, index) => {
        item.number = index + 1;
        let row = this.rows.get(item.id);
        if (!row) {
          row = element("li", "ri");
          row.parts = {number: element("span", "ri-n"), glyph: glyph(item.state), kind: element("span", "ri-kind"), text: element("span", "ri-text"), title: element("strong"), detail: element("span", "sub"), eta: element("span", "ri-eta"), source: element("a", "ri-src")};
          row.parts.text.append(row.parts.title, row.parts.detail);
          row.append(row.parts.number, row.parts.glyph, row.parts.kind, row.parts.text, row.parts.eta, row.parts.source);
          if (!this.seenRows.has(item.id) && !document.body.classList.contains("rm")) {
            row.classList.add("fresh");
            row.addEventListener("animationend", event => {if (event.target === row) row.classList.remove("fresh");});
          }
          this.rows.set(item.id, row);
        }
        row.classList.remove("ri-bump", "ri-boulder"); row.classList.add(`ri-${item.state}`);
        row.parts.number.textContent = item.number;
        row.parts.glyph.className = `g g-${item.state}`;
        row.parts.kind.textContent = LABELS[item.state];
        row.parts.title.textContent = item.title;
        row.parts.detail.textContent = `${item.detail}${item.stale ? ` · Stale · ${item.observed_at === null ? "age unknown" : ageLabel(options.now - item.observed_at)}` : ""}`;
        row.parts.eta.textContent = timeLabel(item.timing, options.now) + (item.beyond ? " · beyond horizon" : "");
        row.parts.source.href = `#${item.section}`; row.parts.source.textContent = item.repo === null ? "Shared account / shell" : item.repo.split("/")[1];
        if (this.list.children[index] !== row) this.list.insertBefore(row, this.list.children[index] || null);
      });
      const context = this.canvas.getContext("2d");
      const numbered = model.strip.map(item => ({...item, number: model.items.findIndex(full => full.id === item.id) + 1}));
      packRoad(numbered, width, (text, mono) => {context.font = mono ? '700 10px "JetBrains Mono"' : '11px "Instrument Sans"'; return context.measureText(text).width;}).forEach(item => {
        let marker = this.markers.get(item.id);
        if (!marker) {
          marker = element("div", "mk"); marker.parts = {glyph: glyph(item.state, "lg"), stem: element("span", "mk-stem"), label: element("span", "mk-lbl")};
          marker.append(marker.parts.stem, marker.parts.label, marker.parts.glyph); this.strip.append(marker); this.markers.set(item.id, marker);
          if (!this.seenMarkers.has(item.id) && !document.body.classList.contains("rm")) {
            marker.classList.add("fresh"); marker.style.setProperty("--entry-delay", `${(item.number - 1) * 70}ms`);
            marker.parts.glyph.addEventListener("animationend", event => {if (event.animationName === "land") marker.classList.remove("fresh");});
          }
        }
        marker.classList.remove("mk-bump", "mk-boulder"); marker.classList.add(`mk-${item.state}`);
        marker.style.left = `${item.x}px`; marker.parts.glyph.className = `g g-${item.state} lg`;
        const top = 84 - item.lane * 26;
        marker.parts.label.hidden = item.lane === undefined;
        marker.parts.label.style.top = `${top}px`; marker.parts.label.style.left = `${item.left - item.x}px`;
        marker.parts.label.style.maxWidth = `${item.labelWidth}px`;
        marker.parts.label.textContent = item.short ? String(item.number) : `${item.number} ${item.title}`;
        marker.parts.stem.style.top = `${top + 20}px`; marker.parts.stem.style.height = `${116 - top - 20}px`;
      });
      for (const item of model.items) this.seenRows.add(item.id);
      for (const item of model.strip) this.seenMarkers.add(item.id);
      // The full list may reorder on new ETA evidence; keep a surviving focused link.
      if (focus?.isConnected && document.activeElement !== focus) focus.focus({preventScroll: true});
      return model;
    }
  }
  return {STATES, SECTIONS, LABELS, RANK, finite, count, epoch, tone, worstState, ageLabel, timeLabel, meterModel,
    normalizeHazards, filterHazards, hazardMinutes, logPosition, roadModel, packRoad, element, glyph, badge, MeterView, RoadView};
});
