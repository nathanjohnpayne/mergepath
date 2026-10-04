/* Audit-only Fleet observations. The shell owns requests, credentials and cadence. */
(function (root, factory) {
  const common = typeof module === "object" && module.exports;
  const api = factory(common ? require("./components.js") : root.CockpitComponents,
    common ? require("./pr_rows.js") : root.CockpitPRRows);
  if (common) module.exports = api;
  else {root.CockpitFleet = api; api.install(root.CockpitApp, {refresh: root.CockpitApp.refreshFleet});}
})(typeof globalThis !== "undefined" ? globalThis : this, function (C, PRRows) {
  "use strict";
  const STATUSES = ["in-sync", "drift", "ahead", "override-only", "fetch-error"];
  const DIRECTIONS = ["hub ahead", "consumer ahead of hub", "re-render differs", "covered by .sync-overrides.yml", "unverified divergence"];
  const repo = value => typeof value === "string" && /^[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+$/.test(value);
  const sha = value => typeof value === "string" && /^[0-9a-f]{40}$/.test(value);
  const text = (value, limit = 4096) => typeof value === "string" && value.length > 0 && value.length <= limit && !/[\x00-\x1f]/.test(value);
  const keys = (object, names) => !!object && typeof object === "object" && !Array.isArray(object) && Object.keys(object).length === names.length && names.every(name => Object.hasOwn(object, name));
  const auditTime = value => typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value.replace("Z", ".000Z");
  function validRecord(record, entry) {
    if (!keys(record, ["schema_version", "name", "repo", "visibility", "baseline", "baseline_info", "hub_sha", "status", "paths", "open_sync_prs", "error", "audited_at"]) || record.schema_version !== 1 || record.repo !== entry.repo || record.name !== entry.name
      || !STATUSES.includes(record.status) || ![null, "public", "private", "internal"].includes(record.visibility)
      || !Array.isArray(record.paths) || record.paths.length > 10000 || !text(record.audited_at, 32)
      || !auditTime(record.audited_at) || (record.hub_sha !== null && !sha(record.hub_sha))) return false;
    const baseline = record.baseline_info;
    if (baseline !== null && (!keys(baseline, ["ref", "sha", "kind", "refreshed", "dirty", "warnings"]) || !text(baseline.ref, 1024) || !sha(baseline.sha) || baseline.kind !== "cache-clone"
      || baseline.refreshed !== true || typeof baseline.dirty !== "boolean" || !Array.isArray(baseline.warnings)
      || baseline.warnings.length > 32 || !baseline.warnings.every(w => text(w, 1024)) || record.baseline !== `${baseline.ref}@${baseline.sha}`)) return false;
    if (baseline === null && (record.baseline !== null || record.status !== "fetch-error")) return false;
    const paths = new Set();
    for (const path of record.paths) {
      if (!keys(path, ["path", "class", "direction", "comparison", "override_reason", "provenance"]) || !text(path.path) || path.path.startsWith("/") || path.path.split("/").includes("..") || paths.has(path.path)
        || !["canonical", "kit", "templated"].includes(path.class) || !DIRECTIONS.includes(path.direction)
        || !text(path.comparison, 1024) || !(path.override_reason === null || text(path.override_reason))) return false;
      paths.add(path.path);
      const p = path.provenance;
      if (p !== null && (!keys(p, ["source_sha", "sync_sha", "hub_sha", "consumer_sha", "source_entry", "hub_entry", "consumer_entry"])
        || !["source_sha", "sync_sha", "hub_sha", "consumer_sha"].every(key => sha(p[key]))
        || !["source_entry", "hub_entry", "consumer_entry"].every(key => typeof p[key] === "string" && p[key].length <= 8192 && /^100(?:644|755) blob [0-9a-f]{40}\t[^\x00-\x1f]+$/.test(p[key])))) return false;
    }
    const prs = record.open_sync_prs;
    if (prs !== null && (!Array.isArray(prs) || prs.length > 1000 || new Set(prs.map(pr => pr?.number)).size !== prs.length
      || !prs.every(pr => keys(pr, ["number", "branch", "state", "lifecycle_state", "draft"]) && C.count(pr?.number) !== null && pr.number > 0 && text(pr.branch, 1024)
        && pr.branch.startsWith("mergepath-sync/") && text(pr.state, 128) && pr.lifecycle_state === "OPEN" && typeof pr.draft === "boolean"))) return false;
    if (record.status === "fetch-error") return keys(record.error, ["source", "reason"]) && ["consumer", "open_sync_prs"].includes(record.error.source) && text(record.error.reason, 512);
    const directions = new Set(record.paths.map(path => path.direction));
    const derived = directions.has("consumer ahead of hub") ? "ahead" : [...directions].some(value => value !== "covered by .sync-overrides.yml") ? "drift" : directions.size ? "override-only" : "in-sync";
    return record.error === null && prs !== null && baseline !== null && record.hub_sha !== null && record.status === derived;
  }
  function currentPRRows(envelope) {
    const result = new Map();
    if (!envelope || C.epoch(envelope.observed_at) === null || envelope.data?.schema !== "cockpit-prs/v1" || !Array.isArray(envelope.data.repositories)) return result;
    const repos = new Set();
    for (const entry of envelope.data.repositories) {
      if (!repo(entry?.repo) || repos.has(entry.repo) || typeof entry.stale !== "boolean" || !Array.isArray(entry.rows)) return new Map();
      repos.add(entry.repo);
      for (const row of entry.rows) {
        if (!PRRows.validRow(row) || row.repo !== entry.repo || result.has(row.id)) return new Map();
        result.set(row.id, {...row, stale: envelope.stale === true || entry.stale || row.stale});
      }
    }
    return result;
  }
  function progress(envelope, now) {
    const running = envelope.in_flight === true, start = C.epoch(envelope.attempted_at), retry = C.epoch(envelope.retry_at);
    return {running, attemptedAt: start, elapsed: running && start !== null ? Math.max(0, Math.floor(now - start)) : null,
      retryAt: retry, error: start === null ? null : envelope.error ?? null};
  }
  function project(envelope, selectedRepo = null, now = Date.now() / 1000, context = {}) {
    const audit = progress(envelope, now);
    if (envelope.data === null && envelope.observed_at === null) return {state: audit.running ? "running" : "idle",
      label: audit.running ? "Audit running · no observations yet" : audit.error ? "Audit unavailable · no observations yet" : "Awaiting first audit",
      hazards: [], count: null, rows: [], selectedRepo, now, audit, stale: true, hasObservations: false, coverageValid: false};
    const data = envelope.data;
    if (!data || data.schema !== "cockpit-fleet/v1" || !repo(data.hub_repo) || !Array.isArray(data.repositories) || !data.repositories.length || data.repositories.length > 256
      || typeof data.complete !== "boolean" || ![0, 1, 3].includes(data.audit_exit)) throw new Error("invalid_fleet_source");
    const seen = new Set(), names = new Set(), current = currentPRRows(context.prs), rows = [], hazards = [];
    for (const entry of data.repositories) {
      if (!repo(entry?.repo) || !text(entry.name, 128) || seen.has(entry.repo) || names.has(entry.name) || entry.repo === data.hub_repo
        || !STATUSES.includes(entry.status) || typeof entry.stale !== "boolean" || !validRecord(entry.attempt, entry)
        || entry.status !== entry.attempt.status || C.epoch(entry.attempted_at) === null || entry.attempted_at !== Date.parse(entry.attempt.audited_at) / 1000
        || !Array.isArray(entry.sync_pr_rows) || !entry.sync_pr_rows.every(row => PRRows.validRow(row) && row.repo === entry.repo)
        || !(entry.record === null || validRecord(entry.record, entry) && entry.record.status !== "fetch-error")
        || !(entry.observed_at === null || C.epoch(entry.observed_at) !== null)
        || (entry.record === null) !== (entry.observed_at === null)
        || entry.record !== null && (entry.observed_at !== Date.parse(entry.record.audited_at) / 1000 || entry.observed_at > entry.attempted_at)
        || (entry.status === "fetch-error") !== entry.stale) throw new Error("invalid_fleet_row");
      seen.add(entry.repo); names.add(entry.name);
      const stale = envelope.stale === true || entry.stale, record = entry.record;
      if (entry.status !== "fetch-error" && (!record || record.status !== entry.status || entry.observed_at !== entry.attempted_at)) throw new Error("invalid_fleet_row");
      const ids = new Set(), syncPRs = entry.sync_pr_rows.map(fallback => {
        if (ids.has(fallback.id) || !(record?.open_sync_prs ?? []).some(pr => String(pr.number) === fallback.number)) throw new Error("invalid_fleet_pr");
        ids.add(fallback.id);
        const observed = current.get(fallback.id);
        return observed ?? {...fallback, stale: stale || fallback.stale};
      });
      if (syncPRs.length !== (record?.open_sync_prs ?? []).length) throw new Error("incomplete_fleet_prs");
      const failed = entry.status === "fetch-error", tone = failed || ["drift", "ahead"].includes(entry.status) ? "bump" : "clear";
      const label = failed ? "Fetch error" : entry.status === "drift" ? `Drift · ${record.paths.length} paths` : entry.status === "ahead" ? "Ahead of hub" : entry.status === "override-only" ? "Override-only" : "In sync";
      const row = {...entry, record, syncPRs, stale, tone, label, membershipStale: stale,
        prLookupKnown: entry.attempt.open_sync_prs !== null, hasObservations: C.epoch(entry.attempted_at) !== null};
      rows.push(row);
      if (failed) hazards.push({id: `fleet-fetch-${entry.repo}`, source: "fleet", section: "fleet", repo: entry.repo,
        state: "bump", title: `${entry.name} · audit fetch error`, detail: entry.attempt.error.reason,
        timing: {kind: "now"}, observed_at: entry.attempted_at, stale: envelope.stale === true});
    }
    const expectedExit = rows.some(row => row.status === "fetch-error") ? 3 : rows.some(row => ["drift", "ahead"].includes(row.status)) ? 1 : 0;
    if (data.audit_exit !== expectedExit || data.complete !== rows.every(row => row.status !== "fetch-error") || (data.audit_exit === 3) !== !data.complete) throw new Error("invalid_fleet_coverage");
    if (selectedRepo !== null && !seen.has(selectedRepo) && selectedRepo !== data.hub_repo) throw new Error("invalid_fleet_filter");
    const visible = rows.filter(row => selectedRepo === null || row.repo === selectedRepo), failures = visible.filter(row => row.status === "fetch-error").length;
    const counts = Object.fromEntries(STATUSES.map(status => [status, visible.filter(row => row.status === status).length]));
    const hasObservations = visible.some(row => row.hasObservations), stale = envelope.stale === true || visible.some(row => row.stale);
    return {state: failures ? "bump" : audit.running ? "running" : hasObservations ? "clear" : "idle",
      label: visible.length ? `${counts["in-sync"]} in sync · ${counts.drift} drifting · ${counts.ahead} ahead · ${counts["override-only"]} override-only · ${failures} fetch errors` : "No consumers in this scope",
      count: visible.length, rows, selectedRepo, now, audit, hazards, hasObservations, stale,
      coverageValid: hasObservations && visible.every(row => row.status !== "fetch-error" && row.observed_at !== null),
      note: "sync-to-downstream.sh --audit --json · every30min or on demand · refreshed remote default branches"};
  }
  class FleetRow {
    constructor(model) {
      this.node = C.element("div", "fleet-entry"); this.node.dataset.repo = model.repo;
      this.row = C.element("div", "fleet-row"); this.row.setAttribute("role", "row");
      this.cells = Array.from({length: 7}, () => {const cell = C.element("div", "fleet-cell"); cell.setAttribute("role", "cell"); this.row.append(cell); return cell;});
      this.name = C.element("span", "mono"); this.visibility = C.element("span", "sub"); this.cells[0].append(this.name, this.visibility);
      this.badge = C.badge("idle", "Unknown"); this.reason = C.element("span", "sub"); this.cells[1].append(this.badge, this.reason);
      this.identity = C.element("span", "mono soft"); this.baseline = C.element("span", "sub"); this.cells[2].append(this.identity, this.baseline);
      this.pathButton = C.element("button", "fleet-link"); this.pathButton.type = "button"; this.pathButton.setAttribute("aria-expanded", "false");
      this.pathButton.addEventListener("click", () => {this.pathsOpen = !this.pathsOpen; this.expand();}); this.cells[3].append(this.pathButton);
      this.prButton = C.element("button", "fleet-link"); this.prButton.type = "button"; this.prButton.setAttribute("aria-expanded", "false");
      this.prButton.addEventListener("click", () => {this.prsOpen = !this.prsOpen; this.expand();});
      this.prNote = C.element("span", "sub"); this.cells[4].append(this.prButton, this.prNote);
      this.time = C.element("span", "mono soft"); this.timeNote = C.element("span", "sub"); this.cells[5].append(this.time, this.timeNote);
      this.sync = C.element("button", "btn sm", "Sync"); this.sync.type = "button"; this.sync.disabled = true; this.sync.title = "Confirmed sync is unavailable pending its executor"; this.cells[6].append(this.sync);
      const identity = encodeURIComponent(model.repo);
      this.paths = C.element("div", "fleet-paths"); this.paths.id = `fleet-paths-${identity}`; this.pathButton.setAttribute("aria-controls", this.paths.id);
      this.pathList = C.element("ul", "fleet-path-list"); this.paths.append(this.pathList); this.pathNodes = new Map();
      this.prs = C.element("div", "fleet-prs"); this.prs.id = `fleet-prs-${identity}`; this.prButton.setAttribute("aria-controls", this.prs.id);
      this.prs.append(C.element("p", "sub", "PR observations are independent of audit membership. Directive meters are advisory; unknown amounts are never guessed."));
      this.prList = new PRRows.RowList(this.prs); this.node.append(this.row, this.paths, this.prs); this.pathsOpen = this.prsOpen = false;
    }
    expand() {
      this.paths.hidden = !this.pathsOpen; this.prs.hidden = !this.prsOpen;
      this.pathButton.setAttribute("aria-expanded", String(this.pathsOpen)); this.prButton.setAttribute("aria-expanded", String(this.prsOpen));
      this.pathButton.textContent = this.pathCount ? `${this.pathCount} path${this.pathCount === 1 ? "" : "s"} · ${this.pathsOpen ? "hide" : "show"}` : "none";
    }
    update(model, now) {
      this.model = model; const record = model.record;
      this.row.className = `fleet-row tone-${model.tone}`; this.name.textContent = model.name; this.visibility.textContent = (record ?? model.attempt).visibility ?? "visibility unknown";
      this.badge.className = `b b-${model.tone}`; this.badge.replaceChildren(C.glyph(model.tone), document.createTextNode(model.label));
      this.reason.textContent = model.status === "fetch-error" ? `${model.attempt.error.reason}${record ? " · last good audit kept" : " · no successful audit observed"}` : "";
      this.identity.textContent = record ? `${record.hub_sha?.slice(0, 8) ?? "unknown"} → ${record.baseline_info?.sha.slice(0, 8) ?? "unknown"}` : "baseline unknown";
      this.baseline.textContent = record?.baseline ?? "Exact baseline unavailable"; this.identity.title = record ? `hub ${record.hub_sha ?? "unknown"} · ${record.baseline ?? "unknown"}` : "No successful baseline";
      const paths = record?.paths ?? [], keys = new Set(paths.map(path => path.path)); this.pathCount = paths.length;
      for (const [key, node] of this.pathNodes) if (!keys.has(key)) {node.li.remove(); this.pathNodes.delete(key);}
      for (const path of paths) {
        let node = this.pathNodes.get(path.path);
        if (!node) {node = {li: C.element("li"), path: C.element("span", "mono"), chip: C.element("span"), detail: C.element("span", "soft")}; node.li.append(node.path, node.chip, node.detail); this.pathNodes.set(path.path, node); this.pathList.append(node.li);}
        node.path.textContent = path.path; node.chip.className = `fleet-class cls-${path.class}`; node.chip.textContent = path.class;
        node.detail.textContent = path.direction + (path.override_reason ? ` · ${path.override_reason}` : ""); node.li.title = `${path.comparison}${path.provenance ? ` · source ${path.provenance.source_sha}` : ""}`;
      }
      this.pathButton.disabled = paths.length === 0; if (!paths.length) this.pathsOpen = false;
      this.prButton.disabled = model.syncPRs.length === 0; this.prButton.textContent = model.syncPRs.length ? model.syncPRs.map(pr => `#${pr.number} ${pr.merge_state ?? "UNKNOWN"}`).join(" · ") : model.prLookupKnown ? "none" : "unknown";
      this.prNote.textContent = `${model.membershipStale ? "Last-known membership · stale" : "Audit membership"}${!model.prLookupKnown ? " · current lookup unavailable" : ""}${model.syncPRs.some(pr => pr.partial) ? " · enrichment unavailable" : ""}`;
      this.prList.update(model.syncPRs, {now, stale: false});
      // The same PR can also be mounted in the PR panel: disclosure IDs are mount-local.
      for (const view of this.prList.views.values()) {
        const id = `fleet-budget-${encodeURIComponent(view.id)}`;
        view.full.id = id; view.button.setAttribute("aria-controls", id);
      }
      if (!model.syncPRs.length) this.prsOpen = false;
      this.time.textContent = model.observed_at === null ? "not observed" : C.ageLabel(now - model.observed_at);
      this.timeNote.className = model.stale ? "sub fleet-stale" : "sub";
      this.timeNote.textContent = `${model.stale ? "stale · " : ""}attempt ${C.ageLabel(now - model.attempted_at)}`;
      this.expand();
    }
    destroy() {this.prList.destroy(); this.node.remove();}
  }
  class FleetView {
    constructor(parent, {refresh = null} = {}) {
      this.parent = parent; this.refresh = typeof refresh === "function" ? refresh : null; this.views = new Map();
      this.summary = C.element("p", "fleet-summary"); this.controls = C.element("div", "fleet-controls"); this.note = C.element("p", "sub");
      this.refreshButton = C.element("button", "btn sm", "Refresh audit"); this.refreshButton.type = "button";
      this.refreshButton.addEventListener("click", () => this.requestRefresh());
      this.syncAll = C.element("button", "btn sm primary", "Sync all"); this.syncAll.type = "button"; this.syncAll.disabled = true; this.syncAll.title = "Confirmed sync is unavailable pending its executor";
      this.controls.append(this.refreshButton, this.syncAll); this.banner = C.element("div", "fleet-audit"); this.banner.setAttribute("role", "status");
      this.spinner = C.glyph("running"); this.progressText = C.element("span"); this.banner.append(this.spinner, this.progressText);
      this.feedback = C.element("p", "sub"); this.feedback.setAttribute("role", "status"); this.empty = C.element("p", "empty");
      this.wrap = C.element("div", "fleet-table-wrap"); this.table = C.element("div", "fleet-table"); this.table.setAttribute("role", "table"); this.table.setAttribute("aria-label", "Fleet audit observations");
      this.header = C.element("div", "fleet-row fleet-header"); this.header.setAttribute("role", "row");
      for (const label of ["Consumer", "Status", "Hub → consumer", "Paths", "Open sync PR", "Last audit", ""]) {const node = C.element("span", "", label); node.setAttribute("role", "columnheader"); this.header.append(node);}
      this.table.append(this.header); this.wrap.append(this.table); this.attach();
    }
    attach() {this.parent.replaceChildren(this.summary, this.controls, this.note, this.banner, this.feedback, this.wrap, this.empty);}
    async requestRefresh() {
      if (!this.refresh || this.requesting || this.model?.audit.running || this.model?.audit.retryAt > this.model.now && this.model.audit.error) return;
      this.requesting = true; this.refreshButton.disabled = true; this.feedback.textContent = "Requesting audit refresh…"; this.feedback.hidden = false;
      try {await this.refresh(); this.feedback.textContent = "Refresh requested · repeated requests are coalesced by the source";}
      catch {this.feedback.textContent = "Refresh unavailable · no audit result changed";}
      finally {this.requesting = false; if (this.model) this.updateControls();}
    }
    updateControls() {
      const audit = this.model.audit;
      this.refreshButton.disabled = Boolean(!this.refresh || this.requesting || audit.running || audit.error && audit.retryAt > this.model.now);
      this.refreshButton.title = !this.refresh ? "Audit refresh is unavailable" : audit.error && audit.retryAt > this.model.now ? "Source failure backoff is active" : "Refresh the shared audit source";
    }
    update(model) {
      this.model = model; if (!this.parent.contains(this.summary)) this.attach();
      this.summary.textContent = model.label; this.note.textContent = `${model.note ?? "Audit-only source · no observations yet"} · Sync unavailable pending confirmed executor${model.stale && model.hasObservations ? " · last-known rows stale" : ""}`;
      this.banner.hidden = !model.audit.running; this.progressText.textContent = `Auditing${model.audit.elapsed === null ? "" : ` · ${model.audit.elapsed}s elapsed`}: last good rows stay until completion. Progress is indeterminate.`;
      this.feedback.hidden = !this.feedback.textContent;
      if (model.audit.error && !model.audit.running && !this.requesting) {this.feedback.textContent = "Audit unavailable · last good rows retained when present"; this.feedback.hidden = false;}
      else if (this.previousError && !model.audit.error && !this.requesting) {this.feedback.textContent = ""; this.feedback.hidden = true;}
      this.previousError = model.audit.error;
      const present = new Set(), focus = document.activeElement;
      for (const row of model.rows) {
        present.add(row.repo); let view = this.views.get(row.repo);
        if (!view) {view = new FleetRow(row); this.views.set(row.repo, view); this.table.append(view.node);}
        view.update(row, model.now); view.node.hidden = model.selectedRepo !== null && model.selectedRepo !== row.repo;
      }
      for (const [id, view] of this.views) if (!present.has(id)) {view.destroy(); this.views.delete(id);}
      this.empty.hidden = model.rows.some(row => model.selectedRepo === null || model.selectedRepo === row.repo);
      this.empty.textContent = model.hasObservations ? "No consumers in this scope." : "No audit observations yet.";
      if (focus?.isConnected && document.activeElement !== focus) focus.focus({preventScroll: true});
      this.updateControls();
    }
  }
  const mounted = new WeakMap();
  function render(parent, model, options = {}) {
    let view = mounted.get(parent);
    if (!view) {view = new FleetView(parent, options); mounted.set(parent, view);}
    view.update(model); return view;
  }
  function install(app, options = {}) {app.registerPanel("fleet", "fleet", project, (parent, model) => render(parent, model, options), {renderPending: true});}
  return {STATUSES, validRecord, currentPRRows, project, FleetRow, FleetView, render, install};
});
