/* Reusable, fetch-free PR rows; shared with the audit-reported sync PR seam. */
(function (root, factory) {
  const api = factory(typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.CockpitPRRows = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (C) {
  "use strict";
  const BUDGET_IDS = ["blocking", "requests", "rounds", "reruns", "commits"];
  const decimal = value => typeof value === "string" && /^[1-9][0-9]*$/.test(value);
  const exactCount = value => C.count(value) !== null || typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value);
  function validRow(row) {
    return row && typeof row === "object" && typeof row.repo === "string" && /^[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+$/.test(row.repo)
      && decimal(row.number) && row.id === `${row.repo}#${row.number}` && typeof row.title === "string"
      && (row.head === null || typeof row.head === "string" && /^[0-9a-f]{40}$/.test(row.head))
      && ["OPEN", "MERGED", "CLOSED"].includes(row.lifecycle) && C.STATES.includes(row.state)
      && typeof row.label === "string" && typeof row.reason === "string" && typeof row.stale === "boolean"
      && Array.isArray(row.labels) && row.labels.every(label => ["needs-external-review", "needs-human-review", "human-hold", "policy-violation"].includes(label))
      && Array.isArray(row.checks) && row.checks.every(check => typeof check.id === "string" && typeof check.name === "string" && C.STATES.includes(check.state))
      && Array.isArray(row.budgets) && row.budgets.length === 5 && row.budgets.every((budget, index) => budget.id === BUDGET_IDS[index]
        && typeof budget.name === "string" && typeof budget.source === "string" && typeof budget.abbr === "string"
        && typeof budget.advisory === "boolean" && typeof budget.stale === "boolean"
        && ["used", "limit", "remaining"].every(key => budget[key] === null || C.count(budget[key]) !== null)
        && ["idle", "clear", "bump", "boulder"].includes(budget.state)
        && (budget.ratio === null || C.finite(budget.ratio) && budget.ratio >= 0 && budget.ratio <= 1)
        && C.finite(budget.threshold) && budget.threshold >= 0 && budget.threshold <= 1)
      && row.feedback && row.codex && row.coderabbit && row.spend && row.spend.codex_split === "unavailable"
      && (row.spend.totals === null || typeof row.spend.totals === "object" && (row.spend.totals.tokens_total === null || exactCount(row.spend.totals.tokens_total)))
      && Array.isArray(row.hazards);
  }
  function safeLink(node, value) {
    try {
      const url = new URL(value);
      if (url.protocol !== "https:" || !["github.com", "www.github.com"].includes(url.hostname) || url.username || url.password) throw new Error();
      node.href = url.href;
    } catch {node.removeAttribute("href");}
  }
  function spendText(spend) {
    const totals = spend?.totals;
    if (!totals) return "LLM spend unknown · accounting unavailable · Codex split unavailable";
    const tokens = totals.tokens_total === null ? "tokens unknown" : `${totals.tokens_total} tokens`;
    const reported = C.finite(totals.reported_cost_usd) ? `$${totals.reported_cost_usd.toFixed(2)} reported` : "reported cost unavailable";
    const notional = C.finite(totals.notional_usd) ? ` · $${totals.notional_usd.toFixed(2)} notional est.` : "";
    return `LLM ${tokens} · ${reported}${notional} · Codex split unavailable`;
  }
  class BudgetView {
    constructor(budget) {
      this.compact = C.element("div", "pr-bs"); this.compact.title = budget.name;
      this.abbr = C.element("span", "pr-bs-label", budget.abbr);
      this.mini = C.element("div", "mini"); this.miniFill = C.element("div", "mini-fill"); this.mini.append(this.miniFill);
      this.remaining = C.element("span", "pr-bs-number"); this.compact.append(this.abbr, this.mini, this.remaining);
      this.card = C.element("div", "pr-budget-card"); this.name = C.element("span", "pr-budget-name", budget.name);
      this.headline = C.element("span", "pr-budget-headline"); this.track = C.element("div", "m-track");
      this.fill = C.element("div", "m-fill"); this.tick = C.element("i", "m-tick"); this.cap = C.element("span", "m-cap"); this.cap.append(C.glyph("boulder"));
      this.track.append(this.fill, this.tick, this.cap); this.note = C.element("span", "sub"); this.card.append(this.name, this.headline, this.track, this.note);
    }
    update(budget, now) {
      if (budget.state !== "boulder") this.landing = false;
      else if (this.previousRemaining !== 0) this.landing = true;
      this.previousRemaining = budget.remaining;
      this.compact.className = `pr-bs t-${budget.state}`;
      this.card.className = `pr-budget-card t-${budget.state}${budget.remaining === null ? " unknown" : ""}${this.landing ? " landing" : ""}`;
      this.remaining.textContent = budget.remaining === null ? "unknown" : `${budget.remaining} left`;
      this.headline.textContent = budget.remaining === null ? "unknown" : `${budget.remaining} left of ${budget.limit}`;
      this.miniFill.className = this.fill.className = `m-fill t-${budget.state}`;
      this.miniFill.style.width = this.fill.style.width = `${(budget.ratio ?? 0) * 100}%`;
      this.miniFill.hidden = this.fill.hidden = budget.ratio === null;
      this.mini.classList.toggle("unknown", budget.remaining === null);
      this.tick.style.left = `${budget.threshold * 100}%`; this.tick.hidden = budget.remaining === null;
      this.cap.hidden = budget.state !== "boulder";
      const observed = C.epoch(budget.observed_at);
      this.note.textContent = `${budget.used === null ? "Source unreadable, nothing guessed" : `${budget.used} used`} · ${budget.source}${budget.advisory ? " · advisory display only" : ""}${budget.stale ? " · stale" : ""}${observed === null ? " · not observed" : ` · observed ${C.ageLabel(now - observed)}`}`;
      this.compact.title = `${budget.name}: ${this.headline.textContent} · ${this.note.textContent}`;
    }
  }
  class RowView {
    constructor(row, {toggle = () => {}, remove = () => {}, setTimer = (fn, delay) => setTimeout(fn, delay), clearTimer = timer => clearTimeout(timer)} = {}) {
      if (!validRow(row)) throw new Error("invalid_pr_row");
      Object.assign(this, {toggle, remove, setTimer, clearTimer}); this.id = row.id; this.generation = 0; this.rewarding = false; this.glowing = false;
      this.node = C.element("div", "pr-entry"); this.row = C.element("div", "pr-row"); this.row.setAttribute("role", "row"); this.node.dataset.pr = row.id;
      this.cells = Array.from({length: 8}, () => {const cell = C.element("div", "pr-cell"); cell.setAttribute("role", "cell"); this.row.append(cell); return cell;});
      this.status = C.badge("idle", "Waiting"); this.ribbon = C.element("span", "pr-ribbon", "Merged"); this.ribbon.hidden = true;
      for (let i = 1; i <= 5; i++) this.ribbon.append(C.element("i", `pr-conf pr-c${i}`));
      this.cells[0].append(this.status, this.ribbon);
      this.link = C.element("a", "pr-link"); this.ref = C.element("span", "pr-ref"); this.title = C.element("span", "pr-title"); this.link.append(this.ref, this.title);
      this.meta = C.element("span", "sub"); this.cells[1].append(this.link, this.meta);
      this.merge = C.element("span", "pr-ms"); this.reason = C.element("span", "pr-why"); this.pips = C.element("div", "pr-pips"); this.checkNote = C.element("span", "sub"); this.cells[2].append(this.merge, this.reason, this.pips, this.checkNote);
      this.labels = new Map(); this.checkNodes = new Map();
      this.strip = C.element("div", "pr-budget-strip"); this.full = C.element("div", "pr-budgets-full"); this.full.id = `pr-budgets-${row.repo.replace(/[^A-Za-z0-9]/g, "-")}-${row.number}`;
      this.budgets = row.budgets.map(budget => {const view = new BudgetView(budget); this.strip.append(view.compact); this.full.append(view.card); return view;});
      this.llm = C.element("span", "pr-llm"); this.button = C.element("button", "pr-disclosure", "all budgets"); this.button.type = "button"; this.button.setAttribute("aria-controls", this.full.id);
      this.button.addEventListener("click", () => this.toggle(this.id)); this.flags = C.element("div", "pr-flags"); this.cells[4].append(this.strip, this.llm, this.button, this.flags);
      this.inflight = C.element("a", "pr-flag run"); this.stops = C.element("span", "pr-flag stop"); this.flags.append(this.inflight, this.stops);
      this.feedback = C.element("span", "pr-feedback"); this.feedbackNote = C.element("span", "sub"); this.cells[5].append(this.feedback, this.feedbackNote);
      this.cr = C.badge("idle", "Unknown"); this.crNote = C.element("span", "sub"); this.cells[6].append(this.cr, this.crNote);
      this.age = C.element("span", "pr-age"); this.push = C.element("span", "sub"); this.cells[7].append(this.age, this.push);
      this.llmCard = C.element("div", "pr-budget-card"); this.llmCard.append(C.element("span", "pr-budget-name", "LLM spend on this PR · no cap")); this.llmFull = C.element("span", "pr-budget-headline"); this.llmCoverage = C.element("span", "sub"); this.llmCard.append(this.llmFull, this.llmCoverage); this.full.append(this.llmCard);
      this.node.append(this.row, this.full); this.expand(false); this.update(row, {initial: true});
    }
    expand(open) {this.full.hidden = !open; this.button.setAttribute("aria-expanded", String(open)); this.button.textContent = open ? "hide budgets" : "all budgets";}
    cancelReward() {
      this.generation++;
      if (this.removalTimer !== undefined) this.clearTimer(this.removalTimer);
      if (this.glowTimer !== undefined) this.clearTimer(this.glowTimer);
      this.removalTimer = this.glowTimer = undefined; this.rewarding = this.glowing = false; this.ribbon.hidden = true;
      this.row.classList.remove("pr-reward");
    }
    update(row, {initial = false, stale = row.stale, now = Date.now() / 1000} = {}) {
      if (!validRow(row) || row.id !== this.id) throw new Error("invalid_pr_row");
      const previous = this.model;
      if (row.lifecycle !== "MERGED") this.cancelReward();
      const reward = !initial && !stale && previous?.lifecycle === "OPEN" && row.lifecycle === "MERGED";
      this.model = row; for (const state of C.STATES) this.row.classList.toggle(`tone-${state}`, state === row.state); this.row.classList.toggle("pr-reward", this.glowing || reward);
      this.status.replaceChildren(C.glyph(row.state), document.createTextNode(row.label)); this.status.className = `b b-${C.tone(row.state)}`;
      this.ref.textContent = `${row.repo} #${row.number}`; this.title.textContent = row.title; safeLink(this.link, `https://github.com/${row.repo}/pull/${row.number}`);
      this.meta.textContent = `${row.author ?? "Author unknown"} · ${row.head?.slice(0, 8) ?? "HEAD unknown"}${row.draft ? " · draft" : ""}${stale ? " · stale" : ""}`;
      this.merge.className = `pr-ms ink-${row.state}`; this.merge.textContent = row.lifecycle === "MERGED" ? "MERGED" : row.merge_state ?? "UNKNOWN"; this.reason.textContent = row.reason;
      const keys = new Set(row.checks.map(check => check.id));
      for (const [key, node] of this.checkNodes) if (!keys.has(key)) {node.remove(); this.checkNodes.delete(key);}
      for (const check of row.checks) {
        let pip = this.checkNodes.get(check.id);
        if (!pip) {pip = C.element("a", "pr-pip"); this.checkNodes.set(check.id, pip); this.pips.append(pip);}
        pip.className = `pr-pip pip-${check.state}`; pip.title = `${check.name} · ${check.state}`; pip.setAttribute("aria-label", pip.title); pip.textContent = check.state === "clear" ? "✓" : check.state === "boulder" ? "×" : check.state === "running" ? "↻" : "·"; safeLink(pip, check.url);
      }
      const passed = row.checks.filter(check => check.state === "clear").length, running = row.checks.filter(check => check.state === "running").length, failed = row.checks.filter(check => check.state === "boulder").length;
      this.checkNote.textContent = row.checks_known ? `${passed} of ${row.checks.length} required passed${running ? ` · ${running} running` : ""}${failed ? ` · ${failed} failed` : ""}` : "Required-check evidence unknown";
      this.checkNote.textContent += ` · review decision: ${row.review_decision ?? (row.partial ? "unknown" : "none observed")}`;
      for (const [key, node] of this.labels) if (!row.labels.includes(key)) {node.remove(); this.labels.delete(key);}
      for (const label of row.labels) if (!this.labels.has(label)) {const node = C.element("span", `pr-label${["human-hold", "policy-violation", "needs-human-review"].includes(label) ? " hold" : " external"}`, label); this.labels.set(label, node); this.cells[3].append(node);}
      this.cells[3].classList.toggle("empty-labels", row.labels.length === 0); this.cells[3].setAttribute("aria-label", row.labels.length ? "Gate labels" : "No observed gate labels");
      this.budgets.forEach((view, index) => view.update(row.budgets[index], now));
      this.llm.textContent = this.llmFull.textContent = spendText(row.spend); this.llmCoverage.textContent = `${row.spend.coverage}${row.spend.stale ? " · stale" : ""}`;
      const evidenceAge = receipt => C.epoch(receipt.observed_at) === null ? "not observed" : `observed ${C.ageLabel(now - receipt.observed_at)}`;
      this.llmCoverage.textContent += ` · ${evidenceAge(row.spend)}`;
      this.inflight.textContent = row.codex.in_flight_on_head === true ? "Request in flight on HEAD" : row.codex.outstanding ? `${row.codex.outstanding} outstanding request(s) · HEAD unknown` : row.codex.outstanding === 0 ? "No outstanding requests · HEAD activity unasserted" : "Codex request state unknown";
      this.inflight.title = `${evidenceAge(row.codex)}${row.codex.stale ? " · stale" : ""}`;
      safeLink(this.inflight, row.codex.url);
      this.inflight.className = `pr-flag ${row.codex.in_flight_on_head === true ? "run" : ""}`;
      this.stops.textContent = row.codex.human_stops === null ? "Human-stop evidence unknown" : row.codex.human_stops.length ? `Human stop: ${row.codex.human_stops.join(", ")}` : ""; this.stops.hidden = !this.stops.textContent;
      this.feedback.textContent = `${row.feedback.accounted ?? "?"} / ${row.feedback.posted ?? "?"}`; this.feedback.classList.toggle("short", row.feedback.accounted !== null && row.feedback.posted !== null && row.feedback.accounted < row.feedback.posted);
      this.feedbackNote.textContent = `accounted / posted${row.feedback.stale ? " · stale" : ""} · ${evidenceAge(row.feedback)}`;
      const crLabel = row.coderabbit.status === "reported" && row.coderabbit.head === row.head ? "Reviewed on HEAD" : row.coderabbit.status === "paused" || row.coderabbit.skip_reason === "paused" ? "Paused" : row.coderabbit.status === "rate_limit_stalled" ? "Rate-limited" : row.coderabbit.status === "no_review_yet" ? "No review on HEAD" : row.coderabbit.status === "unknown" ? "Unknown" : "Review pending";
      const crState = crLabel === "Reviewed on HEAD" ? "clear" : ["Paused", "Rate-limited"].includes(crLabel) ? "bump" : crLabel === "Unknown" ? "idle" : "running";
      this.cr.className = `b b-${C.tone(crState)}`; this.cr.replaceChildren(C.glyph(crState), document.createTextNode(crLabel)); this.crNote.textContent = `${row.coderabbit.stale ? "Last-known · stale · " : ""}${evidenceAge(row.coderabbit)}`;
      this.age.textContent = C.epoch(row.created_at) === null ? "Age unknown" : C.ageLabel(now - row.created_at); this.push.textContent = C.epoch(row.last_push) === null ? "Last push unknown" : `push ${C.ageLabel(now - row.last_push)}`;
      if (reward && !this.rewarding) {
        this.rewarding = this.glowing = true; this.row.classList.remove("entering", "fresh"); this.row.style.animationDelay = "0ms"; this.ribbon.hidden = false; const generation = ++this.generation;
        this.glowTimer = this.setTimer(() => {if (generation === this.generation) {this.glowing = false; this.row.classList.remove("pr-reward");}}, 2600);
        this.removalTimer = this.setTimer(() => {if (generation === this.generation && this.model.lifecycle === "MERGED") {this.cancelReward(); this.remove(this.id);}}, 7000);
      }
    }
    destroy() {this.cancelReward(); this.node.remove();}
  }
  class RowList {
    constructor(parent, options = {}) {
      this.parent = parent; this.options = options; this.views = new Map(); this.open = null; this.seen = new Set(); this.removed = new Set(); this.initialized = false;
      this.table = C.element("div", "pr-table"); this.table.setAttribute("role", "table"); this.table.setAttribute("aria-label", "Observed pull requests");
      this.header = C.element("div", "pr-row pr-header"); this.header.setAttribute("role", "row");
      for (const label of ["Status", "Pull request", "Merge state · checks", "Gate labels", "Review budgets · remaining", "Feedback", "CodeRabbit", "Age"]) {const cell = C.element("span", "", label); cell.setAttribute("role", "columnheader"); this.header.append(cell);}
      this.table.append(this.header); this.empty = C.element("p", "sub", "No open PRs observed in this scope."); this.parent.append(this.table, this.empty);
    }
    toggle(id) {this.open = this.open === id ? null : id; for (const [key, view] of this.views) view.expand(key === this.open);}
    remove(id) {const view = this.views.get(id); if (view) {view.destroy(); this.views.delete(id);} this.removed.add(id); if (this.open === id) this.open = null;}
    update(rows, {selectedRepo = null, now = Date.now() / 1000, stale = false} = {}) {
      const focus = document.activeElement, present = new Set(), visible = [], created = new Set(), initialBatch = !this.initialized;
      for (const row of rows) {
        if (!validRow(row) || present.has(row.id)) throw new Error("invalid_pr_rows"); present.add(row.id);
        if (row.lifecycle === "OPEN") this.removed.delete(row.id);
        if (this.removed.has(row.id)) continue;
        let view = this.views.get(row.id);
        if (!view) {view = new RowView(row, {...this.options, toggle: id => this.toggle(id), remove: id => this.remove(id)}); view.update(row, {initial: true, now, stale: stale || row.stale}); this.views.set(row.id, view); this.table.append(view.node);
          created.add(row.id);
          if (initialBatch) view.row.classList.add("entering");
          else if (!this.seen.has(row.id) && row.lifecycle === "OPEN" && !stale && !row.stale) view.row.classList.add("fresh");
        } else view.update(row, {now, stale: stale || row.stale});
        view.expand(row.id === this.open); view.node.hidden = selectedRepo !== null && selectedRepo !== row.repo;
        if (!view.node.hidden) visible.push(view);
        this.seen.add(row.id);
      }
      for (const [id, view] of this.views) if (!present.has(id)) {view.destroy(); this.views.delete(id); if (this.open === id) this.open = null;}
      // Reorder existing nodes, retaining surviving focus and expansion.
      const ordered = [...this.views.values()].sort((a, b) => C.RANK[a.model.state] - C.RANK[b.model.state] || a.id.localeCompare(b.id));
      let previous = this.header;
      for (const [index, view] of ordered.entries()) {if (created.has(view.id)) view.row.style.animationDelay = `${index * 40}ms`; if (previous.nextSibling !== view.node) this.table.insertBefore(view.node, previous.nextSibling); previous = view.node;}
      this.initialized = true; this.empty.hidden = visible.length !== 0;
      if (focus?.isConnected && document.activeElement !== focus) focus.focus({preventScroll: true});
    }
    destroy() {for (const view of this.views.values()) view.destroy(); this.views.clear(); this.table.remove(); this.empty.remove();}
  }
  return {BUDGET_IDS, decimal, exactCount, validRow, safeLink, spendText, BudgetView, RowView, RowList};
});
