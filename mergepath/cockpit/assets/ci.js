"use strict";
(function (root, factory) {
  const C = typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents;
  const api = factory(C);
  if (typeof module === "object" && module.exports) module.exports = api;
  else {root.CockpitCI = api; root.CockpitApp.registerPanel("ci", "ci", api.project, api.renderer());}
})(globalThis, function (C) {
  const decimal = value => typeof value === "string" && /^[1-9][0-9]{0,79}$/.test(value);
  const repoName = value => typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/.test(value);
  const epoch = value => value === null || C.epoch(value) !== null;
  const failures = ["failure", "timed_out", "action_required", "startup_failure"];
  const live = ["queued", "in_progress", "waiting", "pending", "requested"];
  const status = value => [...live, "completed", "unknown"].includes(value);
  const conclusion = value => value === null || [...failures, "success", "neutral", "cancelled", "skipped", "stale"].includes(value);
  const codePointLength = value => Array.from(value).length;
  function requireValid(value) {if (!value) throw new Error("invalid_ci_observation");}
  function validate(data) {
    requireValid(data?.schema === "ci/v1" && Array.isArray(data.runs) && Array.isArray(data.repositories) && Array.isArray(data.groups) && data.repositories.length > 0 && Number.isSafeInteger(data.recent_seconds) && data.recent_seconds > 0);
    const repositories = new Map(), keys = new Set();
    for (const item of data.repositories) {
      requireValid(repoName(item?.repo) && !repositories.has(item.repo) && epoch(item.observed_at) && epoch(item.attempted_at)
        && epoch(item.retry_at) && typeof item.stale === "boolean" && (item.error === null || typeof item.error === "string")
        && (item.history_complete === undefined || typeof item.history_complete === "boolean"));
      repositories.set(item.repo, item);
    }
    requireValid(data.check_rows === undefined || Array.isArray(data.check_rows));
    requireValid(data.runs.every(row => row?.kind !== "checks") && (data.check_rows ?? []).every(row => row?.kind === "checks"));
    for (const row of [...data.runs, ...(data.check_rows ?? [])]) {
      const checksOnly = row?.kind === "checks";
      requireValid(checksOnly || row?.kind === undefined || row.kind === "workflow");
      requireValid(typeof row?.key === "string" && row.key === (checksOnly ? `${row.repo}:checks:${row.sha}:${row.pr ?? "none"}` : `${row.repo}:${row.id}:${row.pr ?? "none"}`) && !keys.has(row.key)
        && repositories.has(row.repo) && (checksOnly ? row.id === null && row.attempt === null && row.workflow_id === null : decimal(row.id) && decimal(row.attempt) && decimal(row.workflow_id))
        && (row.pr === null || decimal(row.pr)) && typeof row.sha === "string" && /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(row.sha)
        && typeof row.name === "string" && codePointLength(row.name) <= 1000 && status(row.status) && conclusion(row.conclusion)
        && [null, true, false].includes(row.current_head) && typeof row.actionable === "boolean" && typeof row.superseded === "boolean"
        && typeof row.check_evidence_unknown === "boolean" && [null, "bump", "boulder"].includes(row.severity)
        && (row.reason === null || typeof row.reason === "string") && [row.created_at, row.started_at, row.updated_at].every(epoch)
        && (checksOnly ? row.jobs_scope === "none" : row.jobs_scope === "all-attempts" || row.jobs_scope === "not-fetched" && Array.isArray(row.jobs) && row.jobs.length === 0)
        && Array.isArray(row.jobs) && Array.isArray(row.checks) && Array.isArray(row.diagnostics)
        && (!checksOnly || row.jobs.length === 0 && (row.checks.length > 0 || row.current_head === true && row.pr !== null
          && row.status === "unknown" && row.conclusion === null && row.check_evidence_unknown && !row.actionable
          && !row.superseded && row.severity === null && row.diagnostics.length === 0))
        && (checksOnly ? row.rerun_command === null : row.rerun_command === null || row.rerun_command === `gh run rerun ${row.id} --failed --repo ${row.repo}`)
        && (!row.actionable || row.current_head === true && row.severity !== null));
      keys.add(row.key);
      const jobIds = new Set();
      for (const job of row.jobs) {
        requireValid(decimal(job?.id) && !jobIds.has(job.id) && typeof job.name === "string" && status(job.status)
          && conclusion(job.conclusion) && epoch(job.started_at) && epoch(job.completed_at) && Array.isArray(job.steps));
        requireValid((job.check_id === null || decimal(job.check_id)) && (job.attempt === null || decimal(job.attempt)));
        jobIds.add(job.id);
        const steps = new Set();
        for (const step of job.steps) {
          requireValid(decimal(step?.number) && !steps.has(step.number) && typeof step.name === "string" && status(step.status)
            && conclusion(step.conclusion) && epoch(step.started_at) && epoch(step.completed_at));
          steps.add(step.number);
        }
      }
      const checkIds = new Set();
      for (const check of row.checks) {
        requireValid(decimal(check?.id) && !checkIds.has(check.id) && check.repo === row.repo && check.sha === row.sha
          && typeof check.name === "string" && (check.producer === null || typeof check.producer === "string" && /^app:[1-9][0-9]*(?::workflow:[1-9][0-9]*)?$/.test(check.producer))
          && status(check.status) && conclusion(check.conclusion) && epoch(check.started_at) && epoch(check.completed_at)
          && (check.superseded_by === null || decimal(check.superseded_by)));
        checkIds.add(check.id);
      }
      for (const diagnostic of row.diagnostics) requireValid(typeof diagnostic?.text === "string" && codePointLength(diagnostic.text) <= 4000
        && diagnostic.source === "check-run output" && decimal(diagnostic.check_id));
    }
    return repositories;
  }
  function runTone(row) {
    if (row.kind === "checks" && row.checks.length === 0) return {state: "idle", label: "No check observations"};
    if (row.actionable) return {state: row.severity, label: row.severity === "boulder" ? row.reason === "Observed installation rate-limit failure" ? "Token exhausted" : "Not retryable" : "Stale failure"};
    if (row.superseded && !(row.kind === "checks" && live.includes(row.status))) return {state: "idle", label: "Failed · superseded"};
    if (live.includes(row.status)) return {state: "running", label: row.status === "in_progress" ? "Running" : "Queued"};
    if (failures.includes(row.conclusion)) return {state: "idle", label: row.current_head === false ? "Failed · old HEAD" : row.current_head === null ? "Failed · HEAD unknown" : "Failed"};
    if (row.kind === "checks" && row.current_head !== true) return {state: "idle", label: row.current_head === false ? "Checks · old HEAD" : "Checks · HEAD unknown"};
    if (row.conclusion === "success") return row.current_head === true ? {state: "clear", label: "Passed"}
      : {state: "idle", label: row.current_head === false ? "Passed · old HEAD" : "Passed · HEAD unknown"};
    return {state: "idle", label: row.conclusion ? row.conclusion[0].toUpperCase() + row.conclusion.slice(1) : "Unknown"};
  }
  function project(envelope, selectedRepo, now) {
    if (!envelope?.data) return {state: "idle", label: "CI unavailable", hazards: [], count: null, rows: [], repositories: [], stale: true, now};
    const byRepo = validate(envelope.data), repositories = [...byRepo.values()].filter(item => selectedRepo === null || item.repo === selectedRepo);
    const stale = envelope.stale === true || repositories.some(item => item.stale || item.observed_at === null);
    const allRows = [...envelope.data.runs, ...(envelope.data.check_rows ?? [])];
    const rows = allRows.filter(row => selectedRepo === null || row.repo === selectedRepo);
    const hazards = allRows.filter(row => row.actionable).map(row => {
      const observation = byRepo.get(row.repo);
      return {id: `ci:${row.key}`, source: "ci", section: "ci", repo: row.repo, state: row.severity,
        title: `${row.repo.split("/")[1]}${row.pr ? ` #${row.pr}` : ""}: ${row.reason}`.slice(0, 240),
        detail: row.kind === "checks" ? `Check runs · ${row.sha}. No Actions rerun for these checks.` : `Run ${row.id} · ${row.sha}. ${row.rerun_command ?? "Rerun command unavailable"}`,
        timing: {kind: "now"}, observed_at: observation.observed_at, stale: envelope.stale === true || observation.stale};
    });
    const running = rows.filter(row => live.includes(row.status)).length, attention = rows.filter(row => row.actionable).length;
    const unknown = rows.some(row => row.check_evidence_unknown || failures.includes(row.conclusion) && row.current_head === null || row.kind === "checks" && row.current_head === null)
      || repositories.some(item => item.observed_at === null);
    const terminalPass = ["success", "neutral", "skipped"];
    const uncleared = rows.some(row => row.current_head === true && !live.includes(row.status)
      && (row.checks.some(check => check.conclusion === "cancelled") || !row.superseded && (row.kind === "checks"
        ? !row.checks.length || row.checks.some(check => check.status !== "completed" || !terminalPass.includes(check.conclusion))
        : row.status !== "completed" || !terminalPass.includes(row.conclusion))));
    const state = C.worstState(rows.map(row => runTone(row).state));
    return {state: state === "clear" && (unknown || uncleared) ? "idle" : state,
      label: `${running} running · ${attention} need attention · ${rows.length} recent${stale ? " · coverage stale or unavailable" : ""}${unknown ? " · current-check evidence unavailable" : ""}${uncleared ? " · current CI success not established" : ""}`,
      hazards, count: null, rows, repositories, stale, hasObservations: repositories.some(item => item.observed_at !== null), sourceStale: envelope.stale === true, recentSeconds: envelope.data.recent_seconds, now};
  }
  function elapsed(start, end, now) {
    if (C.epoch(start) === null || (end !== null && C.epoch(end) === null)) return "Duration unknown";
    const seconds = Math.floor(Math.max(0, (end ?? now) - start));
    return seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ${seconds % 60}s` : `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  }
  function stepTone(step) {
    return failures.includes(step.conclusion) ? "fail" : step.conclusion === "success" ? "clear" : live.includes(step.status) ? step.status === "in_progress" ? "run" : "idle" : "idle";
  }
  function element(tag, cls, text) {return C.element(tag, cls, text);}
  function excerptURL(row, job, step) {
    const query = new URLSearchParams({repo: row.repo, run: row.id, attempt: row.attempt, job: job.id, step: step.number});
    return `api/ci/excerpt?${query}`;
  }
  function excerptText(value) {
    if (!value || !["ok", "empty", "denied", "unavailable", "stale"].includes(value.status) || !Array.isArray(value.lines)
        || value.lines.length > 80 || value.lines.some(line => typeof line !== "string" || codePointLength(line) > 1000 || !line.startsWith("FAIL:"))) return "Log excerpt unavailable: invalid response.";
    const provenance = value.scope === "step-time-window" ? "Job log · observed step time window; not exact step attribution."
      : value.scope === "job" ? "Whole-job FAIL excerpt · selected-step attribution unavailable." : "Actions job log";
    if (value.status === "unavailable" && value.error === "response_too_large") return "Log excerpt unavailable: complete job log exceeds the 2 MiB read limit; no tail was observed.";
    if (value.status === "ok") return `${provenance}\n${value.lines.join("\n")}${value.truncated ? "\nExcerpt truncated." : ""}`;
    return value.status === "empty" ? `${provenance}\nNo FAIL: lines in the bounded excerpt.`
      : value.status === "denied" ? "Log access denied; no excerpt observed."
      : value.status === "stale" ? "Observation stale; refresh evidence before requesting logs." : "Log excerpt unavailable.";
  }
  class RunView {
    constructor(owner, row) {
      this.owner = owner; this.row = row; this.jobs = new Map(); this.requests = new Map();
      this.root = element("article", "ci-run"); this.button = element("button", "ci-run-head"); this.button.type = "button";
      this.shape = C.glyph("idle"); this.name = element("strong", "mono"); this.ref = element("span", "ci-ref");
      this.pips = element("span", "ci-pips"); this.duration = element("span", "mono ci-duration");
      this.badge = element("span", "b"); this.toggle = element("span", "ci-toggle", "+");
      this.toggle.setAttribute("aria-hidden", "true");
      this.button.append(this.shape, this.name, this.ref, this.pips, this.duration, this.badge, this.toggle);
      this.flag = element("div", "ci-flag"); this.reason = element("strong"); this.command = element("code", "ci-command");
      this.command.tabIndex = 0; this.command.setAttribute("aria-label", "Rerun command, copyable text only");
      this.flag.append(this.reason, this.command); this.body = element("div", "ci-jobs");
      this.root.append(this.button, this.flag, this.body);
      this.button.addEventListener("click", () => owner.toggle(this.row.key));
    }
    update(row, observation, model) {
      if (this.row.attempt !== row.attempt) this.abort();
      this.row = row; this.stale = model.sourceStale || observation.stale || observation.observed_at === null;
      const tone = runTone(row); this.root.className = `ci-run ci-tone-${C.tone(tone.state)}`;
      this.shape.className = `g g-${C.tone(tone.state)}`;
      this.name.textContent = row.name || "Workflow unknown";
      this.ref.textContent = `${row.repo.split("/")[1]}${row.pr ? ` #${row.pr}` : " · PR unknown"} · ${row.sha.slice(0, 7)}${this.stale ? " · stale" : ""}`;
      this.badge.className = `b b-${C.tone(tone.state)}`; this.badge.textContent = tone.label;
      // A run without fetched job detail ends at its workflow update time.
      const completed = row.status !== "completed" ? null : row.jobs.length ? Math.max(...row.jobs.map(job => job.completed_at ?? -1)) : row.jobs_scope === "not-fetched" ? row.updated_at ?? -1 : -1;
      this.duration.textContent = row.kind === "checks" ? `${row.checks.length} checks` : completed === -1 ? "Duration unknown" : elapsed(row.started_at ?? row.created_at, completed, model.now);
      if (row.kind !== "checks" && row.status !== "in_progress" && row.status !== "completed") this.duration.textContent = `queued ${elapsed(row.created_at, null, model.now)}`;
      while (this.pips.children.length > row.jobs.length) this.pips.lastChild.remove();
      row.jobs.forEach((job, index) => {
        let pip = this.pips.children[index]; if (!pip) {pip = element("span", "ci-pip"); this.pips.append(pip);}
        pip.className = `ci-pip ci-pip-${stepTone(job)}`; pip.setAttribute("aria-label", `${job.name}: ${job.conclusion ?? job.status}`);
      });
      this.flag.hidden = !row.actionable && !row.check_evidence_unknown && !row.superseded && !row.diagnostics.length;
      this.reason.textContent = row.reason ?? (row.superseded ? "Failed history superseded by a later run of the same checks." : row.check_evidence_unknown ? "Failed run; current-check evidence unavailable." : "Check-run diagnostics observed · expand the run to read them.");
      this.command.hidden = row.rerun_command === null; this.command.textContent = row.rerun_command ?? "";
      const wanted = new Set(row.jobs.map(job => job.id));
      for (const [id, view] of this.jobs) if (!wanted.has(id)) {view.root.remove(); this.jobs.delete(id);}
      for (const job of row.jobs) {
        let view = this.jobs.get(job.id);
        if (!view) {
          view = {root: element("div", "ci-job"), heading: element("strong", "mono"), steps: new Map(), list: element("ul", "ci-steps")};
          view.root.append(view.heading, view.list); this.jobs.set(job.id, view); this.body.append(view.root);
        }
        view.heading.textContent = `${job.name} · attempt ${job.attempt ?? "unknown"} · ${job.conclusion ?? job.status} · ${elapsed(job.started_at, job.completed_at, model.now)}`;
        const wantedSteps = new Set(job.steps.map(step => step.number));
        for (const [number, old] of view.steps) if (!wantedSteps.has(number)) {old.root.remove(); view.steps.delete(number);}
        for (const step of job.steps) {
          let stepView = view.steps.get(step.number);
          if (!stepView) {
            stepView = {root: element("li", "ci-step"), glyph: C.glyph("idle"), name: element("span", "mono"), duration: element("span", "mono ci-step-duration"), button: element("button", "btn ci-log-button", "Show FAIL excerpt"), log: element("pre", "ci-log")};
            stepView.button.type = "button"; stepView.log.hidden = true; stepView.log.tabIndex = 0;
            stepView.root.append(stepView.glyph, stepView.name, stepView.duration, stepView.button, stepView.log);
            stepView.button.addEventListener("click", () => this.load(stepView, job.id, step.number));
            view.steps.set(step.number, stepView); view.list.append(stepView.root);
          }
          const evidence = `${row.attempt}:${step.status}:${step.conclusion}`;
          if (stepView.evidence !== undefined && stepView.evidence !== evidence) {
            this.abort();
            if (document.activeElement === stepView.button || document.activeElement === stepView.log) this.button.focus();
            stepView.log.hidden = true; stepView.log.textContent = "";
          }
          stepView.evidence = evidence;
          stepView.glyph.className = stepTone(step) === "fail" ? "ci-fail" : `g g-${stepTone(step)}`;
          stepView.name.textContent = `${step.name} · ${step.conclusion ?? step.status}`;
          stepView.duration.textContent = elapsed(step.started_at, step.completed_at, model.now);
          stepView.button.hidden = !failures.includes(step.conclusion); stepView.button.setAttribute("aria-disabled", String(this.stale));
          stepView.button.textContent = this.stale ? "Refresh evidence to read logs" : "Show FAIL excerpt";
        }
      }
      if (!this.empty) {this.empty = element("p", "ci-empty"); this.body.append(this.empty);}
      this.empty.textContent = row.kind === "checks" ? row.checks.length === 0 ? "No workflow or check runs observed for this open HEAD." : "No observed Actions job for these checks."
        : row.jobs_scope === "not-fetched" ? `Job detail is read for live runs, failed runs and open-PR heads; this completed ${row.conclusion === "success" ? "success" : "run"} keeps its workflow result only.` : "No jobs observed for this run.";
      this.empty.hidden = row.jobs.length > 0;
      if (!this.checks) {this.checks = element("div", "ci-job ci-diagnostics mono"); this.body.append(this.checks);}
      this.checks.hidden = row.kind !== "checks";
      this.checks.textContent = row.kind === "checks" ? row.checks.map(check => `check ${check.id} · ${check.name} · ${check.conclusion ?? check.status} · ${check.producer ?? "producer unknown"} · ${elapsed(check.started_at, check.completed_at, model.now)}${check.superseded_by ? ` · superseded by check ${check.superseded_by}` : ""}`).join("\n") : "";
      if (!this.diagnostics) {this.diagnostics = element("div", "ci-diagnostics"); this.body.append(this.diagnostics);}
      this.diagnostics.textContent = row.diagnostics.map(d => `${d.source} · check ${d.check_id}: ${d.text}`).join("\n");
      this.disclose(this.owner.open === row.key);
    }
    disclose(open) {
      this.button.setAttribute("aria-expanded", String(open)); this.toggle.textContent = open ? "−" : "+";
      if (this.body.hidden !== !open) this.body.hidden = !open;
      if (!open) this.abort();
    }
    abort() {
      for (const request of this.requests.values()) {request.controller.abort(); request.view.button.setAttribute("aria-busy", "false"); request.view.log.textContent = "Log request interrupted. Select Show FAIL excerpt to retry.";}
      this.requests.clear();
    }
    async load(view, jobId, stepNumber) {
      const job = this.row.jobs.find(j => j.id === jobId), step = job?.steps.find(s => s.number === stepNumber);
      if (!step || this.stale || this.owner.open !== this.row.key) return;
      const key = `${this.row.attempt}:${jobId}:${stepNumber}`;
      if (this.requests.has(key)) return;
      const request = {controller: new AbortController(), view}; this.requests.set(key, request);
      view.button.setAttribute("aria-busy", "true"); view.log.hidden = false; view.log.textContent = "Reading bounded Actions job log…";
      try {
        const reply = await this.owner.fetch(excerptURL(this.row, job, step), {credentials: "same-origin", signal: request.controller.signal});
        const value = reply.ok ? await reply.json() : null;
        if (this.requests.get(key) === request) view.log.textContent = reply.status === 401 || reply.status === 404
          ? "Log session unavailable. Relaunch Cockpit if the session expired." : excerptText(value);
      } catch {if (this.requests.get(key) === request) view.log.textContent = "Log excerpt unavailable.";}
      finally {if (this.requests.get(key) === request) {this.requests.delete(key); view.button.setAttribute("aria-busy", "false");}}
    }
  }
  // Runs the operator is waiting on stay in the main list; every other completed run is history.
  function attention(row) {
    return live.includes(row.status) || row.actionable === true || row.current_head === true || failures.includes(row.conclusion) || row.kind === "checks";
  }
  class CIView {
    constructor(parent, fetcher = (...args) => fetch(...args)) {
      this.parent = parent; this.fetch = fetcher; this.rows = new Map(); this.open = null; this.historyOpen = false;
      this.summary = element("p", "ci-summary"); this.notes = element("p", "sub ci-notes"); this.list = element("div", "ci-list"); this.empty = element("p", "ci-empty");
      // Completed runs off every open head sit behind a counted disclosure, so sweep-heavy
      // repositories do not turn the panel into hundreds of passed runs.
      this.history = element("div", "ci-history"); this.history.hidden = true;
      this.historyToggle = element("button", "ci-history-toggle"); this.historyToggle.type = "button";
      this.historyList = element("div", "ci-list ci-history-list"); this.historyList.id = "ci-history-runs"; this.historyList.hidden = true;
      this.historyToggle.setAttribute("aria-controls", this.historyList.id); this.historyToggle.setAttribute("aria-expanded", "false");
      this.historyToggle.addEventListener("click", () => {this.historyOpen = !this.historyOpen; this.discloseHistory();});
      this.history.append(this.historyToggle, this.historyList);
      this.mount(parent);
    }
    mount(parent) {
      this.parent = parent; parent.textContent = "";
      parent.append(this.summary, this.notes, this.list, this.history, this.empty);
    }
    discloseHistory() {
      const count = this.historyList.children.length;
      // Hiding an emptied history must not strand focus on its toggle: move it to the summary first.
      if (count === 0 && this.history.contains(document.activeElement)) {this.summary.tabIndex = -1; this.summary.focus();}
      this.history.hidden = count === 0; this.historyList.hidden = !this.historyOpen;
      this.historyToggle.setAttribute("aria-expanded", String(this.historyOpen));
      this.historyToggle.textContent = `${count} completed ${count === 1 ? "run" : "runs"} off open heads · ${this.historyOpen ? "hide" : "show"}`;
    }
    toggle(key) {this.open = this.open === key ? null : key; for (const [id, view] of this.rows) view.disclose(id === this.open);}
    update(model) {
      this.summary.textContent = model.label;
      this.notes.textContent = `Last ${elapsed(0, model.recentSeconds, 0)} + all active runs · Job detail for live, failed and open-HEAD runs · ` + model.repositories.map(o => `${o.repo.split("/")[1]}: ${o.observed_at === null ? "unavailable, never observed" : `${C.ageLabel(model.now - o.observed_at)}${o.stale || model.sourceStale ? " · stale" : ""}${o.history_complete === false ? " · window over the page bound, completed history off open heads not listed" : ""}`}${o.error ? ` · ${o.error}` : ""}`).join(" · ");
      const wanted = new Set(model.rows.map(row => row.key));
      for (const [key, view] of this.rows) if (!wanted.has(key)) {
        const focused = view.root.contains(document.activeElement); view.abort(); view.root.remove(); this.rows.delete(key);
        if (this.open === key) this.open = null;
        if (focused) this.summary.focus();
      }
      this.summary.tabIndex = -1;
      const focus = document.activeElement;
      let primary = 0, history = 0;
      for (const row of model.rows) {
        let view = this.rows.get(row.key);
        if (!view) {view = new RunView(this, row); this.rows.set(row.key, view);}
        view.update(row, model.repositories.find(o => o.repo === row.repo), model);
        // Keyed nodes keep their disclosure state while they move between the two lists.
        const target = attention(row) ? this.list : this.historyList, index = target === this.list ? primary++ : history++;
        if (target.children[index] !== view.root) target.insertBefore(view.root, target.children[index] || null);
      }
      // A focused run that moves into collapsed history reveals it: focus cannot return into a hidden list.
      if (focus && !this.historyOpen && this.historyList.contains(focus)) this.historyOpen = true;
      this.discloseHistory();
      // A browser drops focus when a focused node moves; restore it only then, never over an explicit focus change.
      if (focus && focus !== document.body && focus.isConnected !== false && this.parent.contains(focus) && (document.activeElement === null || document.activeElement === document.body)) focus.focus({preventScroll: true});
      this.empty.hidden = model.rows.length > 0;
      this.empty.textContent = model.stale ? "No usable run rows · observations stale or unavailable." : "No recent workflow runs observed.";
    }
  }
  function renderer(fetcher) {
    let view;
    return (parent, model) => {
      if (!view) view = new CIView(parent, fetcher);
      else if (view.list.parentNode !== parent) view.mount(parent);
      view.update(model);
    };
  }
  return {validate, project, runTone, attention, elapsed, excerptURL, excerptText, CIView, renderer};
});
