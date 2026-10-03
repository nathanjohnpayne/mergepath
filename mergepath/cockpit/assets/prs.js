(function (root, factory) {
  const common = typeof module === "object" && module.exports;
  const api = factory(common ? require("./components.js") : root.CockpitComponents, common ? require("./pr_rows.js") : root.CockpitPRRows);
  if (common) module.exports = api;
  else {root.CockpitPRs = api; api.register(root.CockpitApp);}
})(typeof globalThis !== "undefined" ? globalThis : this, function (C, Rows) {
  "use strict";
  function project(envelope, selectedRepo, now) {
    const data = envelope.data;
    if (!data || data.schema !== "cockpit-prs/v1" || !Array.isArray(data.repositories)) throw new Error("invalid_pr_source");
    const repos = new Set(), identities = new Set(), allRows = [], entries = [];
    for (const entry of data.repositories) {
      if (repos.has(entry.repo) || typeof entry.repo !== "string" || !Array.isArray(entry.rows) || typeof entry.stale !== "boolean") throw new Error("invalid_pr_source");
      repos.add(entry.repo);
      for (const row of entry.rows) {
        if (!Rows.validRow(row) || row.repo !== entry.repo || identities.has(row.id)) throw new Error("invalid_pr_source");
        identities.add(row.id); allRows.push(row);
      }
      if (selectedRepo === null || selectedRepo === entry.repo) entries.push(entry);
    }
    if (selectedRepo !== null && !repos.has(selectedRepo)) throw new Error("invalid_pr_filter");
    const rows = allRows.filter(row => selectedRepo === null || row.repo === selectedRepo);
    const open = rows.filter(row => row.lifecycle === "OPEN"), known = entries.every(entry => C.epoch(entry.observed_at) !== null);
    const stale = envelope.stale === true || entries.some(entry => entry.stale || entry.rows.some(row => row.stale));
    const unavailable = entries.filter(entry => entry.error !== null || C.epoch(entry.observed_at) === null).length;
    const state = known ? C.worstState(open.map(row => row.state)) : "idle";
    const boulders = open.filter(row => row.state === "boulder").length, bumps = open.filter(row => row.state === "bump").length, running = open.filter(row => row.state === "running").length;
    return {state, label: `${known ? open.length : "?"} open · ${boulders} boulders · ${bumps} speed bumps · ${running} in progress${stale ? " · last-known stale" : ""}${unavailable ? ` · ${unavailable} repository observations unavailable` : ""}`,
      count: known ? open.length : null, hazards: allRows.flatMap(row => row.hazards), rows: allRows,
      repositories: entries, selectedRepo, stale, now, hasObservations: entries.some(entry => C.epoch(entry.observed_at) !== null),
      note: "GraphQL · shared hot 15s / idle 120s · slower evidence 120s and on HEAD/activity changes · Cockpit directive meters are advisory"};
  }
  const mounted = new WeakMap();
  function render(parent, model) {
    let view = mounted.get(parent);
    if (!view) {
      const summary = C.element("p", "pr-summary"), note = C.element("p", "sub"), coverage = C.element("p", "sub"), container = C.element("div", "pr-table-wrap");
      parent.replaceChildren(summary, note, coverage, container);
      view = {summary, note, coverage, rows: new Rows.RowList(container)}; mounted.set(parent, view);
    }
    // The shell may replace panel content with an unavailable placeholder between valid snapshots.
    if (!parent.contains(view.summary)) parent.replaceChildren(view.summary, view.note, view.coverage, view.rows.parent);
    view.summary.textContent = model.label; view.note.textContent = model.note;
    view.coverage.textContent = model.repositories.map(entry => `${entry.repo}: ${C.epoch(entry.observed_at) === null ? "not observed" : `observed ${C.ageLabel(model.now - entry.observed_at)}`}${entry.stale ? " · stale" : ""}${entry.error ? " · refresh unavailable" : ""}`).join("; ");
    view.rows.update(model.rows, {selectedRepo: model.selectedRepo, now: model.now, stale: model.stale});
  }
  function register(app) {app.registerPanel("prs", "prs", project, render);}
  return {project, render, register};
});
