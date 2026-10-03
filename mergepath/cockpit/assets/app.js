"use strict";
(function (root, factory) {
  const components = typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents;
  const api = factory(components);
  if (typeof module === "object" && module.exports) module.exports = api;
  else {root.CockpitApp = api; api.mount();}
})(globalThis, function (C) {
  const unavailable = () => ({state: "idle", label: "Unavailable", hazards: [], count: null, observed: false, stale: true, observed_at: null, coverageValid: false});
  function validSnapshot(value) {
    return value?.schema === "cockpit/v1" && C.count(value.revision) !== null && C.epoch(value.generated_at) !== null
      && Array.isArray(value.repositories) && value.repositories.length > 0
      && value.repositories.every(item => typeof item.name === "string" && /^[A-Za-z0-9_.-]+$/.test(item.name)
        && typeof item.repo === "string" && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(item.repo) && typeof item.hub === "boolean")
      && new Set(value.repositories.map(item => item.repo)).size === value.repositories.length
      && value.sources !== null && typeof value.sources === "object" && !Array.isArray(value.sources)
      && value.api_budget !== null && typeof value.api_budget === "object" && !Array.isArray(value.api_budget);
  }
  class PanelRegistry {
    constructor() {this.adapters = new Map();}
    register(id, source, project, render = null) {
      if (!C.SECTIONS.includes(id) || id === "road" || this.adapters.has(id) || typeof source !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(source)
          || typeof project !== "function" || (render !== null && typeof render !== "function")) throw new Error("invalid_panel_registration");
      this.adapters.set(id, {source, project, render});
    }
    project(snapshot, selectedRepo, now) {
      const models = {}, hazards = [], diagnostics = [], repositories = snapshot.repositories.map(item => item.repo);
      for (const id of C.SECTIONS.filter(section => section !== "road")) {
        const adapter = this.adapters.get(id), envelope = adapter ? snapshot.sources[adapter.source] : null;
        models[id] = unavailable();
        if (!adapter) continue;
        if (!envelope || C.epoch(envelope.observed_at) === null || envelope.data === null || envelope.data === undefined) continue;
        try {
          const projected = adapter.project(envelope, selectedRepo, now);
          if (!projected || !C.STATES.includes(projected.state) || typeof projected.label !== "string"
              || (projected.coverageValid !== undefined && typeof projected.coverageValid !== "boolean")
              || (projected.hasObservations !== undefined && typeof projected.hasObservations !== "boolean")) throw new Error("invalid_projection");
          const normalized = C.normalizeHazards(projected.hazards, repositories);
          diagnostics.push(...normalized.diagnostics.map(text => `${id}: ${text}`));
          const ownedSource = normalized.hazards.filter(hazard => hazard.source === id);
          if (ownedSource.length !== normalized.hazards.length) diagnostics.push(`${id}: A hazard used another panel's source identity.`);
          const owned = ownedSource.filter(hazard => hazard.id !== "shell-connection" && !hazard.id.startsWith("account-api-"));
          if (owned.length !== ownedSource.length) diagnostics.push(`${id}: A hazard used a reserved system identity.`);
          const missingHazard = ["bump", "boulder"].includes(projected.state) && owned.length === 0;
          if (missingHazard) diagnostics.push(`${id}: A blocking projection has no usable owned hazard.`);
          const visible = C.filterHazards(owned, selectedRepo).map(hazard => ({...hazard, stale: hazard.stale || envelope.stale === true}));
          const validationValid = normalized.diagnostics.length === 0 && owned.length === normalized.hazards.length && !missingHazard;
          models[id] = {...projected, hazards: visible, count: C.count(projected.count), observed: true,
            hasObservations: projected.hasObservations !== false,
            stale: envelope.stale === true || projected.stale === true, observed_at: envelope.observed_at,
            validationValid, coverageValid: validationValid && projected.coverageValid !== false};
          if (id === "budget") {
            models[id].horizon = null;
            if (projected.horizon !== undefined && projected.horizon !== null) {
              if (C.epoch(projected.horizon.cycleEnd) !== null && projected.horizon.cycleEnd > now
                  && typeof projected.horizon.label === "string" && projected.horizon.label.trim()) models[id].horizon = {cycleEnd: projected.horizon.cycleEnd, label: projected.horizon.label};
              else diagnostics.push("budget: Cycle horizon unavailable: invalid projection.");
            }
          }
          hazards.push(...visible);
        } catch {diagnostics.push(`${id}: Adapter output unavailable.`);}
      }
      // Duplicate identity across adapters is also refused.
      const normalized = C.normalizeHazards(hazards, repositories);
      const identities = new Map();
      for (const hazard of hazards) {
        if (identities.has(hazard.id)) {
          models[identities.get(hazard.id)].coverageValid = false;
          models[identities.get(hazard.id)].validationValid = false;
          models[hazard.source].coverageValid = false;
          models[hazard.source].validationValid = false;
        } else identities.set(hazard.id, hazard.source);
      }
      const observedModels = Object.values(models).filter(model => model.observed);
      const coverageModels = observedModels.filter(model => model.hasObservations);
      return {models, hazards: normalized.hazards, diagnostics: [...diagnostics, ...normalized.diagnostics],
        observed: coverageModels.length > 0, observedPanels: coverageModels.length,
        freshPanels: coverageModels.filter(model => !model.stale && model.coverageValid).length,
        stalePanels: coverageModels.filter(model => model.stale).length,
        partialPanels: coverageModels.filter(model => model.validationValid && !model.coverageValid).length,
        invalidPanels: observedModels.filter(model => !model.validationValid).length};
    }
    counts(snapshot, now) {
      const adapter = this.adapters.get("prs"), envelope = adapter ? snapshot.sources[adapter.source] : null;
      const counts = new Map();
      for (const repo of [null, ...snapshot.repositories.map(item => item.repo)]) {
        let value = null;
        if (adapter && envelope && C.epoch(envelope.observed_at) !== null && envelope.data !== null) {
          try {value = C.count(adapter.project(envelope, repo, now)?.count);} catch { /* Unknown stays unknown. */ }
        }
        counts.set(repo, value);
      }
      return counts;
    }
  }
  class Connection {
    constructor({fetchSnapshot, openStream, onSnapshot, onState, setTimer = (fn, delay) => setTimeout(fn, delay), clearTimer = timer => clearTimeout(timer), now = () => Date.now() / 1000}) {
      Object.assign(this, {fetchSnapshot, openStream, onSnapshot, onState, setTimer, clearTimer, now});
      this.generation = 0; this.failures = 0; this.active = false; this.inventory = null;
    }
    _clear() {
      for (const timer of [this.retry, this.deadline, this.watchdog]) if (timer !== undefined) this.clearTimer(timer);
      this.retry = this.deadline = this.watchdog = undefined;
      this.abort?.abort(); this.abort = null;
      this.stream?.close(); this.stream = null;
    }
    stop() {this.active = false; this.generation++; this._clear();}
    start() {if (this.active) return; this.active = true; void this._begin();}
    _accept(value) {
      if (!validSnapshot(value)) return false;
      const inventory = JSON.stringify(value.repositories);
      if (this.inventory !== null && this.inventory !== inventory) return false;
      this.inventory = inventory;
      this.onSnapshot(value);
      return true;
    }
    _healthy(generation) {
      if (!this.active || generation !== this.generation) return;
      this.failures = 0; this.onState({kind: "live", retry_at: null});
      if (this.watchdog !== undefined) this.clearTimer(this.watchdog);
      this.watchdog = this.setTimer(() => this._fail(generation), 45000);
    }
    _fail(generation) {
      if (!this.active || generation !== this.generation) return;
      this.generation++; this._clear(); this.failures++;
      const delay = Math.min(30, 2 ** Math.min(this.failures, 5));
      this.onState({kind: this.failures >= 3 ? "offline" : "reconnecting", retry_at: this.now() + delay});
      this.retry = this.setTimer(() => {this.retry = undefined; void this._begin();}, delay * 1000);
    }
    async _begin() {
      if (!this.active) return;
      const generation = ++this.generation;
      this.onState({kind: this.failures >= 3 ? "offline" : this.failures ? "reconnecting" : "connecting", retry_at: null});
      this.abort = new AbortController();
      this.deadline = this.setTimer(() => this._fail(generation), 5000);
      try {
        const response = await this.fetchSnapshot(this.abort.signal);
        if (!this.active || generation !== this.generation) return;
        if (response.status === 401 || response.status === 404) {
          this.stop(); this.onState({kind: "session", retry_at: null}); return;
        }
        if (!response.ok) throw new Error("snapshot_unavailable");
        const value = await response.json();
        if (!this.active || generation !== this.generation) return;
        if (!this._accept(value)) throw new Error("snapshot_invalid");
        this.clearTimer(this.deadline); this.deadline = undefined; this.abort = null;
        const stream = this.openStream(); this.stream = stream;
        this.watchdog = this.setTimer(() => this._fail(generation), 45000);
        stream.addEventListener("snapshot", event => {
          if (!this.active || generation !== this.generation) return;
          try {if (!this._accept(JSON.parse(event.data))) throw new Error("snapshot_invalid"); this._healthy(generation);}
          catch {this._fail(generation);}
        });
        stream.addEventListener("heartbeat", event => {
          if (!this.active || generation !== this.generation) return;
          try {
            const value = JSON.parse(event.data);
            if (!value || Array.isArray(value) || typeof value !== "object" || Object.keys(value).length) throw new Error("heartbeat_invalid");
            this._healthy(generation);
          } catch {this._fail(generation);}
        });
        stream.addEventListener("error", () => this._fail(generation));
      } catch {this._fail(generation);}
    }
  }
  function accountHazards(snapshot, now, stale) {
    return Object.entries(snapshot.api_budget).flatMap(([pool, evidence]) => {
      if (!evidence || typeof evidence !== "object") return [];
      const meter = C.meterModel(evidence, now);
      if (!["bump", "boulder"].includes(meter.state)) return [];
      return [{id: `account-api-${pool}`, source: "road", section: "road", repo: null, state: meter.state,
        title: `Reviewer PAT · ${pool}: ${meter.reason}`, detail: `${meter.remaining ?? "Unknown"} ${pool === "graphql" ? "points" : "requests"} left of ${meter.limit ?? "unknown"}.${meter.expired ? ` Last known: ${meter.lastKnownRemaining ?? "unknown"} left / ${meter.lastKnownUsed ?? "unknown"} used.` : ""} Shared by all enrolled repositories.`,
        timing: {kind: "now"}, observed_at: C.epoch(evidence.observed_at), stale, now}];
    });
  }
  function renderPanelContent(parent, model, adapter, placeholder) {
    if (adapter?.render && model.observed) {
      if (placeholder?.parentNode === parent) placeholder.remove();
      adapter.render(parent, model);
      return placeholder;
    }
    if (!placeholder) {
      placeholder = C.element("div", "empty");
      const text = C.element("div"); text.append(C.element("p", "", "Observations unavailable"), C.element("span", "sub", "This section's data source is not connected yet."));
      placeholder.append(C.badge("idle", "Unavailable"), text);
    }
    if (!parent.contains(placeholder)) parent.replaceChildren(placeholder);
    return placeholder;
  }
  const registry = new PanelRegistry();
  function mount() {
    const $ = id => document.getElementById(id), body = document.body;
    const meter = new C.MeterView($("api-meter")), road = new C.RoadView($("road-view"));
    const media = window.matchMedia("(prefers-reduced-motion: reduce)"), darkMedia = window.matchMedia("(prefers-color-scheme: dark)");
    const readPreference = key => {try {return localStorage.getItem(key);} catch {return null;}};
    const savePreference = (key, value) => {try {localStorage.setItem(key, value);} catch { /* Session preference still applies. */ }};
    let dark = readPreference("cockpit-theme") ? readPreference("cockpit-theme") === "dark" : darkMedia.matches;
    let reduced = readPreference("cockpit-motion") === "reduce";
    function preferences() {
      body.classList.toggle("dark", dark); body.classList.toggle("rm", reduced || media.matches);
      if (reduced || media.matches) for (const node of document.querySelectorAll(".fresh")) node.classList.remove("fresh");
      $("theme").setAttribute("aria-pressed", String(dark));
      $("motion").setAttribute("aria-pressed", String(reduced || media.matches));
      $("motion").textContent = media.matches ? "Reduced motion · system" : "Reduce motion";
    }
    $("theme").addEventListener("click", () => {dark = !dark; savePreference("cockpit-theme", dark ? "dark" : "light"); preferences();});
    $("motion").addEventListener("click", () => {reduced = !reduced; savePreference("cockpit-motion", reduced ? "reduce" : "normal"); preferences();});
    media.addEventListener("change", preferences); preferences();
    const filterButtons = new Map(), poolOptions = new Map();
    let snapshot = null, selectedRepo = null, pool = "core", receivedAt = null, renderedAt = null, connection = {kind: "connecting", retry_at: null};
    const epochNow = () => Date.now() / 1000;
    const poolSelect = $("api-pool"); poolOptions.set("core", poolSelect.options[0]);
    function renderFilters() {
      const counts = registry.counts(snapshot, epochNow());
      for (const item of [{repo: null, name: "All repositories", hub: false}, ...snapshot.repositories]) {
        let button = filterButtons.get(item.repo);
        if (!button) {
          button = C.element("button", "chipb"); button.type = "button";
          button.parts = {name: C.element("span", "", item.name + (item.hub ? " · hub" : "")), count: C.element("span", "cnt")};
          button.append(button.parts.name, button.parts.count);
          button.addEventListener("click", () => {selectedRepo = item.repo; render();});
          $("repository-filters").append(button); filterButtons.set(item.repo, button);
        }
        button.setAttribute("aria-pressed", String(item.repo === selectedRepo)); button.classList.toggle("on", item.repo === selectedRepo);
        button.parts.count.textContent = counts.get(item.repo) === null ? "—" : String(counts.get(item.repo));
        button.title = counts.get(item.repo) === null ? "PR count unavailable" : `${counts.get(item.repo)} open PRs`;
      }
      $("repository-note").textContent = `${snapshot.repositories.length} enrolled repositories · PR counts ${counts.get(null) !== null ? "from observations" : "unavailable"}`;
    }
    const placeholders = new Map();
    function renderPanels(projection) {
      for (const [id, model] of Object.entries(projection.models)) {
        const parent = $(`${id}-content`), adapter = registry.adapters.get(id);
        placeholders.set(id, renderPanelContent(parent, model, adapter, placeholders.get(id)));
      }
    }
    function renderConnection() {
      const labels = {connecting: "Connecting", live: "Live", reconnecting: "Reconnecting", offline: "Offline", session: "Session expired"};
      const state = connection.kind === "live" ? "clear" : connection.kind === "reconnecting" ? "bump" : ["offline", "session"].includes(connection.kind) ? "boulder" : "idle";
      $("connection").className = `chip conn c-${state}`;
      $("connection-label").textContent = labels[connection.kind];
      $("connection-note").textContent = connection.kind === "session" ? "Relaunch scripts/cockpit.sh" : connection.kind === "live" ? "Local SSE · authenticated session"
        : connection.retry_at ? `Retry in ${Math.max(0, Math.ceil(connection.retry_at - epochNow()))}s · data may be stale` : "Awaiting stream · data may be stale";
      $("updated-age").textContent = receivedAt === null ? "Not yet" : C.ageLabel((performance.now() - receivedAt) / 1000);
    }
    function render() {
      renderConnection();
      const current = snapshot || {repositories: [], api_budget: {}, sources: {}};
      if (snapshot) renderFilters();
      for (const key of Object.keys(current.api_budget).sort()) {
        if (!/^[a-z_]+$/.test(key) || poolOptions.has(key)) continue;
        const option = C.element("option", "", key); option.value = key; poolSelect.append(option); poolOptions.set(key, option);
      }
      const evidence = current.api_budget[pool] || {}, now = epochNow();
      renderedAt = now;
      meter.update(evidence, {unit: pool === "graphql" ? "points" : "requests", now});
      const identity = typeof evidence.configured_identity === "string" ? `${evidence.configured_identity} · preflight configured` : "Identity unknown";
      const observed = C.epoch(evidence.observed_at), reset = C.epoch(evidence.reset);
      $("api-note").textContent = `${identity} · ${observed === null ? "no header evidence" : `observed ${C.ageLabel(now - observed)}`} · ${reset === null ? "reset unknown" : `reset ${reset > now ? C.timeLabel({kind: "at", at: reset}, now) : "time passed; awaiting headers"}`}`;
      const projection = registry.project(current, selectedRepo, now); renderPanels(projection);
      const stale = connection.kind !== "live";
      let hazards = [...projection.hazards.map(hazard => ({...hazard, stale: hazard.stale || stale})), ...accountHazards(current, now, stale)];
      if (["reconnecting", "offline", "session"].includes(connection.kind)) hazards.push({id: "shell-connection", source: "road", section: "road", repo: null,
        state: connection.kind === "reconnecting" ? "bump" : "boulder", title: connection.kind === "session" ? "Local session expired" : connection.kind === "offline" ? "Local stream offline" : "Local stream reconnecting",
        detail: connection.kind === "session" ? "Relaunch scripts/cockpit.sh to establish a new session." : "Last-known observations remain visible. Every section may be stale until the stream returns.", timing: {kind: "now"}, observed_at: null, stale: true});
      const valid = C.normalizeHazards(hazards, current.repositories.map(item => item.repo)); hazards = valid.hazards;
      const horizon = projection.models.budget.horizon;
      const freshPanels = stale ? 0 : projection.freshPanels, stalePanels = stale ? projection.observedPanels : projection.stalePanels;
      const model = road.update(hazards, {now, horizonMinutes: horizon ? (horizon.cycleEnd - now) / 60 : null, horizonLabel: horizon?.label,
        observed: freshPanels > 0, staleCoverage: stalePanels > 0, invalidCoverage: projection.invalidPanels > 0, partialCoverage: projection.partialPanels > 0});
      const boulders = hazards.filter(hazard => hazard.state === "boulder").length, bumps = hazards.length - boulders;
      $("road-summary").textContent = hazards.length ? `${boulders} boulders · ${bumps} speed bumps` : model.observed ? "Clear for fresh observed sources" : model.invalidCoverage ? "Observations unavailable" : model.staleCoverage ? "Observations stale" : model.partialCoverage ? "Observations incomplete" : "No observations yet";
      const invalidText = projection.invalidPanels ? ` · ${projection.invalidPanels} ${projection.invalidPanels === 1 ? "source" : "sources"} reporting invalid data` : "";
      const partialText = projection.partialPanels ? ` · ${projection.partialPanels} incomplete` : "";
      $("coverage").textContent = `${freshPanels} of 6 panel sources fresh · ${stalePanels} stale${partialText}${invalidText}${stale && snapshot ? " · stream stale" : ""}. ${model.horizonLabel}. Account and connection evidence is shared.`;
      let diagnostic = $("adapter-diagnostics");
      if (!diagnostic) {diagnostic = C.element("p", "adapter-diagnostic"); diagnostic.id = "adapter-diagnostics"; $("road-view").append(diagnostic);}
      diagnostic.textContent = [...projection.diagnostics, ...valid.diagnostics].join(" "); diagnostic.hidden = !diagnostic.textContent;
    }
    poolSelect.addEventListener("change", () => {pool = poolSelect.value; render();});
    const controller = new Connection({fetchSnapshot: signal => fetch("api/snapshot", {credentials: "same-origin", cache: "no-store", signal}),
      openStream: () => new EventSource("events"), onSnapshot: value => {snapshot = value; receivedAt = performance.now(); render();},
      onState: value => {const changed = connection.kind !== value.kind; connection = value; render(); if (changed) $("connection-announcement").textContent = $("connection-label").textContent + ". " + $("connection-note").textContent;}});
    const timer = setInterval(() => {
      const now = epochNow();
      if (snapshot && Object.values(snapshot.api_budget).some(evidence => {
        const reset = C.epoch(evidence?.reset);
        return reset !== null && renderedAt !== null && reset > renderedAt && reset <= now;
      })) render();
      else renderConnection();
    }, 1000);
    const resize = new ResizeObserver(() => {if (snapshot) render();}); resize.observe(road.strip);
    document.fonts.ready.then(() => {if (snapshot) render();});
    window.addEventListener("pagehide", () => {controller.stop(); clearInterval(timer); resize.disconnect();});
    window.addEventListener("pageshow", event => {if (event.persisted) window.location.reload();});
    // Later scripts register a pure projection once; the shell remains the sole connection owner.
    registerPanel = (id, source, project, renderer) => {registry.register(id, source, project, renderer); render();};
    render(); controller.start();
  }
  let registerPanel = (id, source, project, renderer) => registry.register(id, source, project, renderer);
  return {validSnapshot, PanelRegistry, Connection, accountHazards, renderPanelContent, mount, registerPanel: (...args) => registerPanel(...args)};
});
