"use strict";
(function(root, factory) {
  const C = typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents;
  const api = factory(C);
  if (typeof module === "object" && module.exports) module.exports = api;
  else {root.CockpitAgents = api; api.mount(root.CockpitApp);}
})(globalThis, function(C) {
  const providers = ["claude", "codex", "other"];
  const validNumber = n => typeof n === "number" && Number.isFinite(n) && n >= 0 && n <= Number.MAX_SAFE_INTEGER;
  const fmt = n => validNumber(n) ? n.toLocaleString("en-US", {maximumFractionDigits: 2}) : "unavailable";
  const money = n => validNumber(n) ? `$${n.toFixed(2)}` : "unavailable";
  const elapsed = n => validNumber(n) ? `${Math.floor(n / 60)}:${String(Math.floor(n % 60)).padStart(2, "0")}` : "unavailable";
  function validateData(data) {
    return data?.schema === "cockpit-agents/v1" && Array.isArray(data.history) && data.history.length <= 10000
      && typeof data.hasObservations === "boolean" && typeof data.history_complete === "boolean" && data.history.every(row => typeof row.id === "string" && row.id.length <= 1000
        && (row.repo === null || typeof row.repo === "string") && typeof row.pr === "string" && /^[1-9][0-9]*$/.test(row.pr)
        && providers.includes(row.provider) && row.tokens && row.findings && row.cost && typeof row.conflict === "boolean"
        && ["APPROVED", "APPROVED_WITH_ADVISORIES", "CHANGES_REQUESTED", "UNAVAILABLE"].includes(row.verdict)
        && ["reported", "estimated", "bounded_estimate", "unavailable"].includes(row.cost.kind)
        && ["total", "input", "output", "cache_creation", "cache_read", "reasoning", "cost_usd"].every(key => row.tokens[key] === null || validNumber(row.tokens[key]))
        && ["usd", "low_usd", "high_usd"].every(key => row.cost[key] === null || validNumber(row.cost[key]))
        && (row.started_at_epoch === null || validNumber(row.started_at_epoch))
        && (row.elapsed_seconds === null || validNumber(row.elapsed_seconds)))
      && new Set(data.history.map(row => row.id)).size === data.history.length;
  }
  function projectHistory(envelope, repo, now) {
    if (!validateData(envelope?.data)) throw new Error("invalid_agents_history");
    const data = envelope.data;
    const rows = data.history.filter(row => repo === null || row.repo === repo);
    return {state: "idle", label: !data.hasObservations ? "History unavailable" : rows.length ? `${rows.length} recorded runs` : !data.history_complete ? "History coverage incomplete" : "No recorded runs",
      hazards: [], count: null, hasObservations: data.hasObservations, coverageValid: data.hasObservations && data.history_complete, rows, data, now, selectedRepo: repo};
  }
  function costLabel(cost) {
    return cost.kind === "bounded_estimate" ? `${money(cost.low_usd)}–${money(cost.high_usd)} est · bound`
      : cost.kind === "estimated" ? `${money(cost.usd)} est` : cost.kind === "reported" ? `${money(cost.usd)} reported` : "Cost unavailable";
  }
  function tokenLabel(row) {
    if (row.provider === "codex") return `${fmt(row.tokens.total)} total`;
    if (row.tokens.input !== null && row.tokens.output !== null) return `in ${fmt(row.tokens.input)} · out ${fmt(row.tokens.output)} · cache read ${fmt(row.tokens.cache_read)}`;
    return `${fmt(row.tokens.total)} total`;
  }
  function aggregateCosts(rows) {
    const measured = rows.filter(row => row.cost.kind !== "unavailable");
    const sum = key => measured.reduce((total, row) => total + (row.cost[key] ?? row.cost.usd ?? 0), 0);
    const low = sum("low_usd"), high = sum("high_usd");
    return {low, high, measured: measured.length, runs: rows.length, complete: measured.length === rows.length,
      estimated: measured.some(row => row.cost.kind !== "reported")};
  }
  function aggregateLabel(rows) {
    const value = aggregateCosts(rows);
    if (!value.measured) return "Cost unavailable";
    const amount = value.low === value.high ? money(value.low) : `${money(value.low)}–${money(value.high)}`;
    return `${amount}${value.estimated ? " est" : " reported"}${value.complete ? "" : ` · measured ${value.measured}/${value.runs} runs`}`;
  }
  function historyView(rows, now, {provider = null, pr = null, allDates = false} = {}) {
    const today = new Date(now * 1000).toISOString().slice(0, 10), todayEpoch = Date.parse(today) / 1000;
    const days = Array.from({length: 7}, (_, i) => new Date((todayEpoch - (6 - i) * 86400) * 1000).toISOString().slice(0, 10));
    const filtered = rows.filter(row => (provider === null || row.provider === provider) && (pr === null || `${row.repo}#${row.pr}` === pr)
      && (allDates || pr !== null || row.day === null || days.includes(row.day)));
    const chart = days.map(day => ({day, series: ["claude", "codex"].filter(name => provider === null || provider === name)
      .map(name => ({provider: name, rows: filtered.filter(row => row.day === day && row.provider === name)}))}));
    const peak = Math.max(0, ...chart.flatMap(day => day.series.map(series => aggregateCosts(series.rows).high)));
    return {rows: filtered, chart, peak, undated: filtered.filter(row => row.day === null).length,
      totals: providers.filter(name => provider === null || provider === name).map(name => ({provider: name, rows: filtered.filter(row => row.provider === name)}))};
  }
  class HistoryView {
    constructor(parent) {
      this.provider = null; this.pr = null; this.allDates = false; this.rows = new Map(); this.days = new Map(); this.tiles = new Map();
      this.root = C.element("div", "agent-history");
      this.summary = C.element("h3", "history-summary"); this.note = C.element("p", "sub");
      this.filters = C.element("div", "filters"); this.filters.setAttribute("role", "group"); this.filters.setAttribute("aria-label", "History provider");
      this.buttons = new Map();
      for (const name of [null, ...providers]) {
        const button = C.element("button", "chipb", name === null ? "All providers" : name === "codex" ? "Codex" : name === "claude" ? "Claude" : "Other");
        button.type = "button"; button.addEventListener("click", () => {this.provider = name; this.update(this.model);});
        this.buttons.set(name, button); this.filters.append(button);
      }
      this.dateButton = C.element("button", "btn sm", "All recorded dates"); this.dateButton.type = "button";
      this.dateButton.addEventListener("click", () => {this.allDates = !this.allDates; this.update(this.model);}); this.filters.append(this.dateButton);
      this.clear = C.element("button", "btn sm", "Clear PR filter"); this.clear.type = "button"; this.clear.hidden = true;
      this.clear.addEventListener("click", () => {this.pr = null; this.update(this.model);}); this.filters.append(this.clear);
      this.legend = C.element("p", "chart-h", "Per provider, per day · UTC · Claude teal · Codex striped blue · estimates carry est; range bars show the upper bound; missing costs are unavailable");
      this.bars = C.element("div", "bars"); this.totals = C.element("div", "totals");
      this.wrap = C.element("div", "tbl-wrap"); this.table = C.element("div", "tbl history-table"); this.table.setAttribute("role", "table"); this.table.setAttribute("aria-label", "Phase 4b run history");
      const header = C.element("div", "trow th"); header.setAttribute("role", "row");
      for (const title of ["Run", "PR", "Reviewer", "Verdict", "Tokens", "Cost", "Findings", "Elapsed"]) {const cell = C.element("span", "", title); cell.setAttribute("role", "columnheader"); header.append(cell);}
      this.table.append(header); this.wrap.append(this.table);
      this.empty = C.element("p", "empty", "No Phase 4b runs recorded.");
      this.diagnostics = C.element("p", "adapter-diagnostic");
      this.root.append(this.summary, this.note, this.filters, this.legend, this.bars, this.totals, this.wrap, this.empty, this.diagnostics); parent.replaceChildren(this.root);
    }
    update(model) {
      this.model = model;
      if (this.pr !== null && !model.rows.some(row => `${row.repo}#${row.pr}` === this.pr)) this.pr = null;
      const view = historyView(model.rows, model.now, this);
      for (const [name, button] of this.buttons) {button.setAttribute("aria-pressed", String(name === this.provider)); button.classList.toggle("on", name === this.provider);}
      this.dateButton.setAttribute("aria-pressed", String(this.allDates)); this.dateButton.textContent = this.allDates ? "Show 7 days" : "All recorded dates";
      this.clear.hidden = this.pr === null;
      this.summary.textContent = `${this.pr !== null ? this.pr : this.allDates ? "All recorded dates" : "7 days"} · ${view.rows.length} runs · ${aggregateLabel(view.rows)}`;
      this.note.textContent = `Local loop logs + approval accounting · ${model.data.observed_checkouts}/${model.data.coverage.checkouts} checkouts observed · genuine run_id deduplication · ${model.data.coverage.legacy_runs} legacy runs have source identities${model.stale ? " · Stale last-known data" : ""}${view.undated ? ` · ${view.undated} undated runs included in table, excluded from dated chart` : ""}`;
      const crosscheck = model.data.review_crosscheck;
      const total = this.pr !== null && this.provider === null ? model.data.per_pr?.find(item => `${item.repo}#${item.pr}` === this.pr)?.totals : null;
      if (total) this.note.textContent += ` · per PR: ${fmt(total.adapter_invocations)} loops · ${fmt(total.tokens_total)} measured tokens · ${elapsed(total.elapsed_seconds_total)} measured elapsed (missing measurements are unavailable)`;
      if (model.data.coverage.unattributed_runs) this.note.textContent += ` · ${model.data.coverage.unattributed_runs} runs have unavailable target repository attribution (whole-history only)`;
      const diagnostics = [...model.data.diagnostics, ...(crosscheck?.diagnostics || [])];
      if (crosscheck?.truncated) diagnostics.push("Approved-review cross-check is truncated to 8 recent PRs.");
      this.diagnostics.textContent = diagnostics.join(" "); this.diagnostics.hidden = !diagnostics.length;
      const keepDays = new Set(view.chart.map(day => day.day));
      for (const [day, item] of this.days) if (!keepDays.has(day)) {item.root.remove(); this.days.delete(day);}
      for (const [index, day] of view.chart.entries()) {
        let item = this.days.get(day.day);
        if (!item) {const root = C.element("div", "day"), pair = C.element("div", "bar-pair"), label = C.element("span", "day-l", day.day.slice(5)); item = {root, pair, label, series: new Map()}; root.append(pair, label); this.days.set(day.day, item);}
        item.root.hidden = false;
        for (const name of ["claude", "codex"]) {
          let series = item.series.get(name);
          if (!series) {series = {bar: C.element("div", `bar bar-${name}`), value: C.element("span", `day-v v-${name}`)}; item.pair.append(series.bar); item.root.append(series.value); item.series.set(name, series);}
          const data = day.series.find(row => row.provider === name), cost = aggregateCosts(data?.rows || []);
          series.bar.hidden = !data; series.value.hidden = !data;
          series.bar.style.height = `${cost.measured && view.peak ? cost.high / view.peak * 100 : 0}%`;
          const label = data ? data.rows.length ? aggregateLabel(data.rows) : "No recorded runs" : "";
          series.value.textContent = !data?.rows.length ? "—" : !cost.measured ? "n/a" : `${cost.low === cost.high ? money(cost.low) : money(cost.low) + "–\n" + money(cost.high)}${cost.estimated ? " est" : ""}${cost.complete ? "" : `\n${cost.measured}/${cost.runs}`}`;
          series.bar.title = `${name} ${day.day}: ${label}`;
          series.bar.setAttribute("role", "img"); series.bar.setAttribute("aria-label", series.bar.title);
          series.bar.classList.toggle("bounded", cost.low !== cost.high);
        }
        if (this.bars.children[index] !== item.root) this.bars.insertBefore(item.root, this.bars.children[index] || null);
      }
      const keepTiles = new Set(view.totals.map(item => item.provider));
      for (const [name, tile] of this.tiles) tile.root.hidden = !keepTiles.has(name);
      for (const total of view.totals) {
        let tile = this.tiles.get(total.provider);
        if (!tile) {tile = {root: C.element("div", "tot"), label: C.element("span", "tot-k"), value: C.element("span", "tot-v mono"), note: C.element("span", "sub")}; tile.root.append(tile.label, tile.value, tile.note); this.tiles.set(total.provider, tile); this.totals.append(tile.root);}
        tile.root.hidden = false; tile.label.textContent = `${total.provider} · ${total.rows.length} runs`;
        const knownTokens = total.rows.filter(row => row.tokens.total !== null), tokens = knownTokens.reduce((sum, row) => sum + row.tokens.total, 0);
        tile.value.textContent = `${knownTokens.length ? fmt(tokens) : "Unavailable"} tokens`;
        tile.note.textContent = `${aggregateLabel(total.rows)} · tokens measured ${knownTokens.length}/${total.rows.length}${total.provider === "codex" ? " · input/output split unavailable, never imputed" : " · cost_usd where reported; estimates from versioned prices.json"}`;
      }
      const keep = new Set(view.rows.map(row => row.id));
      for (const [id, row] of this.rows) if (!keep.has(id)) {row.remove(); this.rows.delete(id);}
      view.rows.forEach((value, index) => {
        let row = this.rows.get(value.id);
        if (!row) {
          row = C.element("div", "trow"); row.setAttribute("role", "row"); row.parts = {};
          for (const key of ["id", "pr", "reviewer", "verdict", "tokens", "cost", "findings", "elapsed"]) {const cell = C.element("div", "cell"); cell.setAttribute("role", "cell"); row.parts[key] = cell; row.append(cell);}
          row.parts.run = C.element("span", "mono"); row.parts.time = C.element("span", "sub"); row.parts.id.append(row.parts.run, row.parts.time);
          row.parts.button = C.element("button", "linkb mono"); row.parts.button.type = "button";
          row.parts.button.addEventListener("click", () => {if (row.pr !== null) {this.pr = row.pr; this.update(this.model);}}); row.parts.pr.append(row.parts.button);
          this.rows.set(value.id, row);
        }
        row.pr = value.repo === null ? null : `${value.repo}#${value.pr}`;
        row.parts.run.textContent = value.run_id || "Legacy run · source identity";
        row.parts.time.textContent = value.started_at_epoch === null ? "Start time unavailable" : new Date(value.started_at_epoch * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
        row.parts.button.textContent = value.repo === null ? `Target unavailable · PR #${value.pr}` : `${value.repo.split("/")[1]} #${value.pr}`; row.parts.button.setAttribute("aria-pressed", String(this.pr !== null && this.pr === row.pr)); row.parts.button.disabled = value.repo === null;
        row.parts.reviewer.replaceChildren(C.element("span", `rev rev-${value.provider}`, value.provider === "codex" ? "Codex" : value.provider === "claude" ? "Claude" : "Other"));
        const state = value.conflict ? "idle" : value.verdict === "CHANGES_REQUESTED" ? "bump" : value.verdict.startsWith("APPROVED") ? "clear" : "idle";
        const verdict = value.conflict ? "Conflicting observations" : value.verdict === "UNAVAILABLE" ? "Unavailable verdict" : value.verdict;
        row.parts.verdict.replaceChildren(C.badge(state, verdict));
        row.parts.tokens.replaceChildren(C.element("span", "mono", tokenLabel(value)));
        if (value.provider === "codex") row.parts.tokens.append(C.element("span", "sub na", "input/output split unavailable"));
        row.parts.cost.replaceChildren(C.element("span", "mono", costLabel(value.cost)), C.element("span", "sub", value.cost.source));
        if (value.cost.price_key) row.parts.cost.append(C.element("span", "sub", `${value.cost.price_key} · table ${value.cost.price_version || "unavailable"}`));
        row.parts.findings.replaceChildren(...["P0", "P1", "P2", "P3"].map(name => C.element("span", `sev sev-${name.slice(1)}`, `${name} ${fmt(value.findings[name])}`)));
        row.parts.elapsed.textContent = elapsed(value.elapsed_seconds);
        if (this.table.children[index + 1] !== row) this.table.insertBefore(row, this.table.children[index + 1] || null);
      });
      this.empty.hidden = view.rows.length > 0; this.wrap.hidden = !view.rows.length;
      this.empty.textContent = !model.hasObservations ? "History observations unavailable." : !model.data.history_complete ? "History coverage incomplete; no readable runs for this selection." : "No Phase 4b runs recorded for this selection.";
    }
  }
  const historyViews = new WeakMap();
  function renderHistory(parent, model) {let view = historyViews.get(parent); if (!view || view.root.parentNode !== parent) {view = new HistoryView(parent); historyViews.set(parent, view);} view.update(model);}
  function mount(app) {if (app) app.registerPanel("history", "agents", projectHistory, renderHistory);}
  return {validateData, projectHistory, costLabel, tokenLabel, aggregateCosts, aggregateLabel, historyView, HistoryView, renderHistory, mount};
});
