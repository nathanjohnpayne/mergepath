"use strict";
(function(root, factory) {
  const C = typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents;
  const api = factory(C);
  if (typeof module === "object" && module.exports) module.exports = api;
  else {root.CockpitLiveAgents = api; api.mount(root.CockpitApp);}
})(globalThis, function(C) {
  const stages = ["barrier", "adapter", "posting", "done"];
  let terminalLists = 0;
  const number = value => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER;
  const elapsed = value => number(value) ? `${Math.floor(value / 60)}:${String(Math.floor(value % 60)).padStart(2, "0")}` : "unavailable";
  const safeText = value => typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\x00-\x1f]/.test(value);
  function validRow(row) {
    return row && safeText(row.id) && safeText(row.repo) && /^p4b-[A-Za-z0-9._-]{1,200}$/.test(row.run_id)
      && row.id === `${row.repo}:${row.run_id}` && typeof row.pr === "string" && /^[1-9][0-9]*$/.test(row.pr)
      && ["claude", "codex", "other"].includes(row.provider) && safeText(row.reviewer)
      && Number.isInteger(row.pid) && row.pid > 0 && row.pid <= 2147483647 && stages.includes(row.stage)
      && ["running", "crashed", "unknown", "done"].includes(row.process_status) && number(row.observed_at)
      && Array.isArray(row.reached) && row.reached.length > 0 && row.reached.length <= 4
      && row.reached.every((stage, i) => stages.includes(stage) && (!i || stages.indexOf(stage) > stages.indexOf(row.reached[i - 1])))
      && row.reached.at(-1) === row.stage
      && ["started_at_epoch", "stage_at_epoch", "adapter_started_at_epoch", "adapter_elapsed_seconds", "adapter_elapsed_observed_seconds", "adapter_elapsed_observed_at", "adapter_timeout_seconds", "adapter_exit_code", "exit_code", "token_count", "findings_count"].every(key => row[key] === null || number(row[key]))
      && ["summary_emitted", "review_posted", "dry_run"].every(key => typeof row[key] === "boolean")
      && ["verdict", "adapter_verdict", "posted_outcome", "review_acknowledgment"].every(key => row[key] === null || safeText(row[key]))
      && (row.summary_emitted || (row.verdict === null && row.token_count === null && row.findings_count === null))
      && row.posted_outcome === (row.summary_emitted && row.review_posted && !row.dry_run ? row.verdict : null);
  }
  function validateData(data) {
    return data?.schema === "cockpit-live-agents/v1" && typeof data.hasObservations === "boolean"
      && typeof data.coverage_complete === "boolean" && number(data.observed_at)
      && Array.isArray(data.live) && Array.isArray(data.terminal) && data.live.length + data.terminal.length <= 64
      && data.live.every(row => validRow(row) && row.stage !== "done" && row.process_status !== "done")
      && data.terminal.every(row => validRow(row) && row.stage === "done" && row.process_status === "done")
      && new Set([...data.live, ...data.terminal].map(row => row.id)).size === data.live.length + data.terminal.length
      && Array.isArray(data.diagnostics) && data.diagnostics.length <= 9 && data.diagnostics.every(safeText);
  }
  function liveRow(row, envelope, now) {
    // Only a recent successful probe authorizes extrapolation between fetches.
    const stale = envelope.stale === true || row.observed_at > now || now - row.observed_at > 10;
    const running = !stale && row.process_status === "running";
    const observation = Math.min(now, row.observed_at);
    const clock = running ? now : observation;
    const comparable = number(row.adapter_started_at_epoch) && row.adapter_started_at_epoch <= observation;
    let seconds = row.reached.includes("adapter") ? row.adapter_elapsed_seconds ?? row.adapter_elapsed_observed_seconds : null;
    if (row.stage === "adapter" && comparable && running) seconds = Math.max(seconds ?? 0, clock - row.adapter_started_at_epoch);
    const budget = number(row.adapter_timeout_seconds) && row.adapter_timeout_seconds > 0 ? row.adapter_timeout_seconds : null;
    const ratio = number(seconds) && budget !== null ? seconds / budget : null;
    let state = running ? "running" : "idle", label = stale ? "Stale · last observed" : row.process_status === "unknown" ? "Process unknown" : "Running";
    if (row.process_status === "crashed") {state = "boulder"; label = stale ? "Crashed · last observed" : "Crashed · recorded process gone";}
    else if (row.adapter_exit_code === 124) {state = "boulder"; label = "Timed out · adapter exit 124";}
    else if (running && row.stage === "adapter" && ratio !== null && ratio >= 1) {state = "bump"; label = "Budget exceeded · no terminal outcome observed";}
    else if (running && row.stage === "adapter" && ratio !== null && ratio >= .8) {state = "bump"; label = "Near timeout";}
    const invocation = number(row.started_at_epoch) && row.started_at_epoch <= observation ? clock - row.started_at_epoch : null;
    return {...row, stale, running, state, label, elapsed: seconds, budget, ratio,
      remaining: ratio === null ? null : Math.max(0, budget - seconds), invocation_elapsed: invocation,
      stages: stages.map(stage => ({name: stage, kind: stage === row.stage ? row.process_status === "crashed" ? "crash" : running ? "cur" : "unknown" : row.reached.includes(stage) ? "done" : "todo"}))};
  }
  function projectLive(envelope, repo, now) {
    if (!validateData(envelope?.data) || !number(now)) throw new Error("invalid_live_agents");
    const data = envelope.data, rows = data.live.filter(row => repo === null || row.repo === repo).map(row => liveRow(row, envelope, now));
    const terminal = data.terminal.filter(row => repo === null || row.repo === repo);
    const hazards = rows.filter(row => ["bump", "boulder"].includes(row.state)).map(row => ({
      id: `agent-${row.id}`, source: "agents", section: "agents", repo: row.repo, state: row.state,
      title: `${row.repo} #${row.pr} · ${row.label}`, detail: row.process_status === "crashed" ? `Run ${row.run_id}: recorded process identity is gone; no posted verdict follows from this observation.`
        : `${row.label}. Observed adapter elapsed ${elapsed(row.elapsed)} / ${elapsed(row.budget)}. This is advisory runtime evidence.`,
      observed_at: row.observed_at, stale: row.stale, timing: row.stale ? {kind: "unknown"} : row.state === "bump" && row.remaining > 0 ? {kind: "at", at: now + row.remaining} : {kind: "now"}}));
    const running = rows.filter(row => row.running).length, crashed = rows.filter(row => row.process_status === "crashed").length;
    const unknown = rows.filter(row => !row.running && row.process_status !== "crashed").length;
    const expired = data.observed_at > now || now - data.observed_at > 10;
    return {state: C.worstState(rows.map(row => row.state)), label: `${running} running · ${crashed} crashed${unknown ? ` · ${unknown} unknown or stale` : ""}`,
      hazards, count: rows.length, rows, terminal, data, now, stale: envelope.stale === true || expired,
      hasObservations: data.hasObservations, coverageValid: data.hasObservations && data.coverage_complete && !expired && !unknown};
  }
  class LiveView {
    constructor(parent) {
      this.cards = new Map(); this.root = C.element("div", "live-agents");
      this.summary = C.element("h3", "live-summary"); this.note = C.element("p", "sub");
      this.list = C.element("div", "live-agent-list"); this.empty = C.element("p", "empty");
      // Finished runs stay available as text, behind a disclosure with a count, so two dozen
      // observations do not become a wall of prose beside the CI panel.
      this.terminal = C.element("div", "live-terminal"); this.terminal.hidden = true; this.terminalOpen = false; this.terminalNodes = new Map();
      this.terminalToggle = C.element("button", "live-terminal-toggle"); this.terminalToggle.type = "button";
      this.terminalList = C.element("ul", "live-terminal-list"); this.terminalList.id = `live-terminal-observations-${++terminalLists}`; this.terminalList.hidden = true;
      this.terminalToggle.setAttribute("aria-controls", this.terminalList.id); this.terminalToggle.setAttribute("aria-expanded", "false");
      this.terminalToggle.addEventListener("click", () => {this.terminalOpen = !this.terminalOpen; this.discloseTerminal();});
      this.terminalNote = C.element("span", "sub", "Accounting history updates independently; these observations add no spend.");
      this.terminal.append(this.terminalToggle, this.terminalList, this.terminalNote);
      this.diagnostics = C.element("p", "adapter-diagnostic");
      this.root.append(this.summary, this.note, this.list, this.empty, this.terminal, this.diagnostics); parent.replaceChildren(this.root);
    }
    discloseTerminal() {
      const count = this.terminalNodes.size;
      this.terminalList.hidden = !this.terminalOpen;
      this.terminalToggle.setAttribute("aria-expanded", String(this.terminalOpen));
      this.terminalToggle.textContent = `${count} finished ${count === 1 ? "run" : "runs"} observed · ${this.terminalOpen ? "hide" : "show"}`;
    }
    create(row) {
      const root = C.element("article", "live-agent"), header = C.element("div", "live-agent-head"), badge = C.badge(row.state, row.label);
      const reviewer = C.element("span", "rev"), target = C.element("span", "mono soft"); header.append(badge, reviewer, target);
      const pipeline = C.element("div", "live-stages"), stageNodes = stages.map(stage => {
        const node = C.element("div", "live-stage"), dot = C.element("span", "live-stage-dot"), label = C.element("span", "", stage);
        dot.setAttribute("aria-hidden", "true"); node.append(dot, label); pipeline.append(node); return node;
      });
      const meter = C.element("div", "m"), top = C.element("div", "m-top"), value = C.element("span", "m-val"), denominator = C.element("span", "m-den");
      top.append(value, denominator); const track = C.element("div", "m-track"), fill = C.element("span", "m-fill"), tick = C.element("span", "m-tick");
      tick.style.left = "80%"; track.append(fill, tick); meter.append(top, track);
      const timing = C.element("p", "sub"), footer = C.element("div", "live-agent-footer mono soft");
      root.append(header, pipeline, meter, timing, footer);
      const reduced = document.body?.classList?.contains?.("rm") || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
      const card = {root, badge, reviewer, target, stageNodes, value, denominator, track, fill, timing, footer, entering: !reduced};
      const retireEntry = event => {if (event.target === root && event.animationName === "live-agent-enter") {card.entering = false; root.classList.remove("fresh");}};
      root.addEventListener("animationend", retireEntry); root.addEventListener("animationcancel", retireEntry);
      return card;
    }
    update(model) {
      if (!Array.isArray(model.rows)) throw new Error("invalid_live_model");
      this.model = model; this.summary.textContent = model.label;
      this.note.textContent = `Machine-local heartbeat · polling target 5 s · ${model.stale ? "Stale last-known observations; clocks stopped" : `observed ${C.ageLabel(model.now - model.data.observed_at)}`}${!model.data.coverage_complete ? " · coverage incomplete" : ""}`;
      const keep = new Set(model.rows.map(row => row.id));
      for (const [id, card] of this.cards) if (!keep.has(id)) {card.root.remove(); this.cards.delete(id);}
      for (const [index, row] of model.rows.entries()) {
        let card = this.cards.get(row.id);
        if (!card) {card = this.create(row); this.cards.set(row.id, card);}
        card.root.className = `live-agent tone-${row.state}${row.stale ? " stale" : ""}${card.entering ? " fresh" : ""}`;
        card.badge.className = `b b-${row.state === "running" ? "run" : row.state}`;
        // Keep badge label/glyph nodes attached across repeated samples.
        card.badge.children[0].className = `g g-${row.state === "running" ? "run" : row.state}`;
        card.badge.children[1].textContent = row.label;
        card.reviewer.className = `rev rev-${row.provider}`; card.reviewer.textContent = row.provider === "claude" ? "Claude" : row.provider === "codex" ? "Codex" : row.reviewer;
        card.target.textContent = `${row.repo} #${row.pr}`;
        row.stages.forEach((stage, i) => {card.stageNodes[i].className = `live-stage stg-${stage.kind}`; card.stageNodes[i].setAttribute("aria-label", `${stage.name}: ${stage.kind}`);});
        card.value.textContent = elapsed(row.elapsed); card.denominator.textContent = `of ${elapsed(row.budget)} adapter timeout · tick at 80%`;
        card.fill.className = `m-fill t-${row.state === "running" ? "run" : row.state}`; card.fill.style.width = `${row.ratio === null ? 0 : Math.min(100, row.ratio * 100)}%`;
        card.track.setAttribute("role", "img"); card.track.setAttribute("aria-label", `Adapter elapsed ${elapsed(row.elapsed)} of ${elapsed(row.budget)}; ${row.remaining === null ? "remaining unavailable" : elapsed(row.remaining) + " remaining"}`);
        card.timing.textContent = `Since invocation start (wall time) ${elapsed(row.invocation_elapsed)} · ${row.stage === "barrier" ? "barrier; adapter not started" : row.stage === "posting" ? "adapter elapsed held during posting" : row.stale || !row.running ? "adapter clock stopped at last observed elapsed" : "fresh process identity verified"}`;
        card.footer.textContent = `${row.run_id} · pid ${row.pid} · ${row.stage} · ${row.process_status}${row.stale ? " · stale" : ""}`;
        if (this.list.children[index] !== card.root) this.list.insertBefore(card.root, this.list.children[index] || null);
      }
      this.empty.hidden = model.rows.length > 0;
      this.empty.textContent = model.data.hasObservations && model.data.coverage_complete ? "No Phase 4b run in flight." : "Live coverage incomplete; no runs established.";
      const keepTerminal = new Set(model.terminal.map(row => row.id));
      for (const [id, node] of this.terminalNodes) if (!keepTerminal.has(id)) {node.remove(); this.terminalNodes.delete(id);}
      model.terminal.forEach((row, index) => {
        let node = this.terminalNodes.get(row.id);
        if (!node) {node = C.element("li"); this.terminalNodes.set(row.id, node);}
        node.textContent = `${row.repo} #${row.pr}: ${row.posted_outcome !== null ? `${row.posted_outcome} review posted` : row.summary_emitted ? `${row.verdict ?? "verdict unavailable"} summary; no posted outcome established` : row.review_posted ? "review POST confirmed; final summary and outcome unavailable" : "finished; final summary unavailable"}${row.dry_run ? " · dry run" : ""} · exit ${row.exit_code ?? "unavailable"} · acknowledgment ${row.review_acknowledgment ?? "unavailable"}`;
        if (this.terminalList.children[index] !== node) this.terminalList.insertBefore(node, this.terminalList.children[index] || null);
      });
      // Hiding the emptied disclosure must not strand focus on its toggle: move it to the summary first.
      if (!model.terminal.length && this.terminal.contains(document.activeElement)) {this.summary.tabIndex = -1; this.summary.focus();}
      this.terminal.hidden = !model.terminal.length;
      this.discloseTerminal();
      this.diagnostics.textContent = model.data.diagnostics.join(" "); this.diagnostics.hidden = !model.data.diagnostics.length;
    }
  }
  const views = new WeakMap();
  function renderLive(parent, model) {
    let view = views.get(parent);
    if (!view) {view = new LiveView(parent); views.set(parent, view);}
    else if (view.root.parentNode !== parent) {
      // Invalid data is withdrawn by the shell. A valid recovery reattaches
      // cached nodes without replaying entry or bypassing source validation.
      for (const card of view.cards.values()) {card.entering = false; card.root.classList.remove("fresh");}
      parent.replaceChildren(view.root);
    }
    view.update(model);
    return view;
  }
  function mount(app) {if (app) app.registerPanel("agents", "live_agents", projectLive, renderLive);}
  return {validateData, liveRow, projectLive, LiveView, renderLive, mount, elapsed};
});
