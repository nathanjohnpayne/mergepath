"use strict";
(function(root, factory) {
  const C = typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents;
  const api = factory(C);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.CockpitActions = api;
})(globalThis, function(C) {
  const num = v => C.finite(v) && v >= 0 && v <= Number.MAX_SAFE_INTEGER;
  const repoOK = v => typeof v === "string" && /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/.test(v) && v.length <= 256;
  const fresh = (v, now, ttl) => v?.available === true && v.stale === false && num(v.observed_at) && now >= v.observed_at && now - v.observed_at <= ttl;
  const CI_OBSERVATION_GAP = 270;
  // The provider scans each repository's failed-job logs at most every 120 seconds; a scan
  // older than this missed at least one cycle.
  const SCAN_FRESH = 300;
  const fmt = n => n.toLocaleString("en-US", {maximumFractionDigits: 1});
  const dollars = n => `$${n.toFixed(2)}`;
  const stateOf = ratio => ratio === null ? "idle" : ratio >= 1 ? "boulder" : ratio >= .7 ? "bump" : "clear";
  const base = (id, title, denominator) => ({id, title, denominator, state: "idle", available: false, stale: false, value: "Unavailable", note: "Observations unavailable", rows: [], percent: null, projection: null});
  function project(envelope, selectedRepo, now) {
    const data = envelope?.data;
    if (data?.schema !== "actions-budget/v1" || !Array.isArray(data.repositories) || data.repositories.length > 100
        || !data.billing || !data.robot || !data.configuration) throw new Error("invalid_actions_payload");
    const cards = [base("spend", "Spend this cycle", "net_amount · per billing cycle"),
      base("token", "GITHUB_TOKEN per repo", "1,000 per hour · per repository · reference limit"),
      base("robot", "Shared CI PAT pool", "per hour · per account · nathanpayne-robot"),
      base("queue", "Queue pressure", "queued vs running · per repo")];
    const hazards = [], seen = new Set();
    function hazard(card, state, repo, detail, timing = {kind:"unknown"}, observed = null, stale = false) {
      hazards.push({id: `actions-${card.id}-${repo || "account"}-${timing.kind}`, source: "budget", section: "budget", state,
        repo, title: `${card.title}${repo ? ` · ${repo.split("/")[1]}` : ""}`, detail, timing, observed_at: observed, stale});
    }
    const [spend, token, robot, queue] = cards, billing = data.billing, config = data.configuration;
    const periodKnown = Number.isInteger(billing.year) && billing.year >= 1970 && billing.year <= 9999
      && Number.isInteger(billing.month) && billing.month >= 1 && billing.month <= 12;
    const periodStart = periodKnown ? Date.UTC(billing.year,billing.month-1,1)/1000 : null;
    const periodEnd = periodKnown ? Date.UTC(billing.year,billing.month,1)/1000 : null;
    const periodCurrent = periodKnown && periodStart <= now && now < periodEnd;
    const billingFresh = fresh(billing, now, 3600) && envelope.stale !== true && periodCurrent;
    const cycleValid = periodCurrent && config.cycle_start === periodStart && config.cycle_end === periodEnd;
    const accountBudget = cycleValid && num(config.budget) && config.budget > 0 ? config.budget : null;
    let accountProjection = null;
    const billRows = billing.repositories;
    if (num(billing.net_amount) && Array.isArray(billRows) && billRows.length <= 20000
        && billRows.every(r => repoOK(r.repo) && num(r.net_amount))) {
      const shares = selectedRepo ? billRows.filter(r => r.repo === selectedRepo) : billRows;
      const net = selectedRepo ? shares.reduce((s,r)=>s+r.net_amount,0) : billing.net_amount;
      // Shared account hazards use account evidence; the share has no denominator.
      const budget = selectedRepo ? null : accountBudget;
      spend.available = billingFresh && budget !== null; spend.stale = !billingFresh;
      spend.value = selectedRepo && shares.length === 0 ? "Repository spend unavailable" : `${dollars(net)} reported${billingFresh ? "" : " · last known"}`;
      spend.denominator = budget === null ? `${selectedRepo ? "repository share · " : ""}budget unavailable · per billing cycle` : `of ${dollars(budget)} budget · per billing cycle`;
      spend.percent = budget ? Math.min(100, net / budget * 100) : null;
      spend.state = billingFresh ? stateOf(budget ? net / budget : null) : "idle";
      spend.rows = shares.slice().sort((a,b)=>b.net_amount-a.net_amount).slice(0,4);
      spend.note = `Reported REST netAmount only. Workflow attribution unavailable.${billingFresh ? "" : billing.available === false ? " Billing currently unavailable through configured client; last-good observation stale." : " Billing observation stale."}`;
      if (!periodCurrent) spend.note += ` Reported period ${periodKnown ? `${billing.year}-${String(billing.month).padStart(2,"0")}` : "unknown"}; current-cycle percentage and projection unavailable.`;
      const start = config.cycle_start, end = config.cycle_end;
      if (billingFresh && accountBudget && start < now) {
        const projected = billing.net_amount / (now - start) * (end - start);
        if (num(projected)) {
          accountProjection = {value: projected, percent: Math.min(100, projected / accountBudget * 100)};
          if (!selectedRepo) {
            spend.projection = accountProjection;
            spend.note += " Projection: cycle-to-date net spend / elapsed cycle time × cycle duration.";
          }
          const ps = projected >= accountBudget ? "boulder" : projected >= accountBudget * .9 ? "bump" : null;
          if (ps) {
            if (!selectedRepo) spend.state = C.worstState([spend.state,ps]);
            hazard(spend, ps, null, `Projected ${dollars(projected)} against ${dollars(accountBudget)} at cycle end; estimated from current average burn.`, {kind:"at",at:end}, billing.observed_at);
          }
        }
      }
      const accountState = stateOf(accountBudget ? billing.net_amount / accountBudget : null);
      if (["bump","boulder"].includes(accountState)) hazard(spend,accountState,null,`${dollars(billing.net_amount)} reported against ${dollars(accountBudget)} budget.`,{kind:"now"},billing.observed_at,!billingFresh);
      if (selectedRepo && hazards.some(h=>h.id.startsWith("actions-spend-"))) spend.note += " Account spend hazards remain shared.";
    } else spend.note = "Billing unavailable through configured client. Budget and cycle must be explicitly configured; other observations are independent.";
    let q = 0, r = 0, queueKnown = 0, tokenKnown = 0, anyStale = envelope.stale === true;
    const repositories = data.repositories.filter(row => !selectedRepo || row.repo === selectedRepo);
    for (const row of repositories) {
      if (!repoOK(row?.repo) || seen.has(row.repo)) throw new Error("invalid_repository");
      seen.add(row.repo);
      // Repository rows come from the shared CI snapshot, renewed within its observation gap (ci.OBSERVATION_GAP).
      const good = fresh(row, now, CI_OBSERVATION_GAP) && envelope.stale !== true;
      const countsValid = C.count(row.queued) !== null && C.count(row.running) !== null && C.count(row.runs_last_hour) !== null;
      const hard = Array.isArray(row.installation_runs) && row.installation_runs.length <= 10000
        && row.installation_runs.every(id => typeof id === "string" && /^[1-9][0-9]{0,15}$/.test(id)) && row.installation_runs.length > 0;
      const measurement = row.measurement;
      const measured = measurement && num(measurement.requests_per_run) && num(measurement.observed_at)
        && now >= measurement.observed_at && now - measurement.observed_at <= 3600
        && typeof measurement.provenance === "string" && [...measurement.provenance].length <= 240;
      const estimate = countsValid && measured && num(row.estimated_requests) && Math.abs(row.estimated_requests-row.runs_last_hour*measurement.requests_per_run)<.001 ? row.estimated_requests : null;
      let ts = hard ? "boulder" : good && estimate !== null ? stateOf(estimate/1000) : "idle";
      const scan = row.installation_scan, scanned = num(scan?.observed_at) && scan.error === null && now >= scan.observed_at && now - scan.observed_at <= SCAN_FRESH;
      const tr = {repo:row.repo, state:ts, exhausted:hard, scanned, runs:hard ? row.installation_runs.slice(0,3) : [], percent:hard ? 100 : estimate === null ? null : Math.min(100,estimate/10),
        value:hard ? "exhausted" : estimate === null ? "Estimate unavailable" : `est. ${fmt(estimate)}${good ? "" : " · last known"}`,
        detail: `${countsValid ? fmt(row.runs_last_hour) : "Unknown"} runs in last hour · ${good ? "fresh" : "stale / unavailable"}${hard ? ` · installation limit in run ${row.installation_runs.slice(0,3).join(", ")}; reset unknown` : ""}${measured ? ` · ${measurement.provenance}` : " · measured requests per run unavailable"}`};
      token.rows.push(tr);
      if (good && (estimate !== null || hard)) tokenKnown++;
      if (!good) anyStale = true;
      if (["bump","boulder"].includes(ts)) hazard(token,ts,row.repo,hard ? `Observed installation rate-limit failure in run ${row.installation_runs.slice(0,3).join(", ")}; reset unknown.` : `${fmt(estimate)} estimated requests of 1,000 per hour; exhaustion timing unknown.`,hard ? {kind:"now"} : {kind:"unknown"},C.epoch(row.observed_at),!good);
      const jam = row.jammed === true && countsValid && row.queued >= 40 && row.running <= 1
        && num(row.jam_since) && num(row.observed_at) && row.observed_at - row.jam_since > 1800;
      const qs = jam ? "boulder" : countsValid && row.queued >= 10 ? "bump" : good && countsValid ? row.running > 0 ? "running" : "clear" : "idle";
      queue.rows.push({repo:row.repo,state:qs,queued:countsValid?row.queued:null,running:countsValid?row.running:null,
        value:countsValid?`${row.queued} / ${row.running}`:"Unknown / unknown",detail:`${good ? "fresh" : "stale / unavailable"}${jam ? " · jammed: continuous successful samples >30 min" : ""}`});
      if (good && countsValid) {q += row.queued; r += row.running; queueKnown++;}
      if (["bump","boulder"].includes(qs)) hazard(queue,qs,row.repo,jam?`${row.queued} queued, ${row.running} running continuously >30 minutes. Cockpit jam heuristic.`:`${row.queued} queued; warning reference 10, runner capacity unknown.`,jam?{kind:"now"}:{kind:"unknown"},C.epoch(row.observed_at),!good);
    }
    token.state = C.worstState(token.rows.map(row=>row.state)); token.available = repositories.length > 0 && tokenKnown === repositories.length;
    token.stale = anyStale; token.note = "Estimates: runs in the last hour × explicitly measured requests per run. Installation failure overrides estimates. Reset and exhaustion ETA unavailable without evidence.";
    queue.state = C.worstState(queue.rows.map(row=>row.state)); queue.available = repositories.length > 0 && queueKnown === repositories.length; queue.stale = anyStale;
    queue.value = `${q} queued · ${r} running${queue.available ? "" : " · partial / unavailable coverage"}`;
    queue.note = "Warning reference: ≥10 queued; jam heuristic: ≥40 queued and ≤1 running continuously >30 min. Runner capacity and drain ETA unavailable.";
    queue.scale = Math.max(1,...queue.rows.filter(row=>row.queued!==null).map(row=>row.queued+row.running));
    const robotData = data.robot, robotFresh = fresh(robotData, now, 120) && envelope.stale !== true;
    if (robotData.configured_identity === "nathanpayne-robot" && num(robotData.observed_at)) {
      const m = C.meterModel(robotData,now);
      robot.available = robotFresh && m.percent !== null; robot.stale = !robotFresh;
      robot.state = robotData.secondary_limited === true ? "boulder" : robotFresh ? m.state : "idle";
      robot.value = m.remaining === null ? "Remaining unknown" : `${fmt(m.remaining)} left${robotFresh ? "" : " · last known"}`;
      robot.denominator = m.limit === null ? "Limit unknown · per hour · per account" : `of ${fmt(m.limit)} per hour · per account · nathanpayne-robot`;
      robot.percent = m.percent; robot.note = `${m.reason}. Per-repository pool attribution unavailable.`;
      if (["bump","boulder"].includes(robot.state)) hazard(robot,robot.state,null,robot.note,robot.state==="boulder"||m.ratio>=.9?{kind:"now"}:{kind:"unknown"},robotData.observed_at,!robotFresh);
    } else robot.note = "Robot pool unavailable: configured reviewer headers belong to a separate account. Per-repository attribution unavailable.";
    const states = cards.map(card=>card.state);
    states[0] = C.worstState([states[0],...hazards.filter(h=>h.id.startsWith("actions-spend-")).map(h=>h.state)]);
    const state = C.worstState(states);
    const coverage = cards.every(card=>card.available);
    const hasObservations = (num(billing.observed_at) && num(billing.net_amount))
      || repositories.some(row=>num(row.observed_at) && C.count(row.queued)!==null && C.count(row.running)!==null)
      || (num(robotData.observed_at) && robotData.configured_identity==="nathanpayne-robot");
    const bumps = states.filter(state=>state==="bump").length, boulders = states.filter(state=>state==="boulder").length;
    return {state:state==="clear"&&!coverage?"idle":state,label:boulders||bumps?`${boulders} at the limit · ${bumps} approaching${coverage?"":" · incomplete coverage"}`:coverage?"Headroom on every meter":"Headroom partly unavailable",
      count:repositories.length, hazards,cards,coverageValid:coverage,hasObservations,stale:envelope.stale===true||cards.some(card=>card.stale),sourceStale:envelope.stale===true,horizon:accountProjection?{cycleEnd:config.cycle_end,label:"cycle end"}:null};
  }
  const views = new WeakMap();
  class BudgetView {
    constructor(parent) {
      this.summary = C.element("h3","actions-summary"); this.root = C.element("div","actions-meters"); this.cards = new Map();
      for (const id of ["spend","token","robot","queue"]) {
        const card = C.element("article","actions-card"), head = C.element("h3"), title=C.element("span"), den=C.element("span","den"); head.append(title,den);
        const body=C.element("div","actions-body"), note=C.element("p","note"), age=C.element("span","sub"); card.append(head,body,note,age); this.root.append(card);
        this.cards.set(id,{card,title,den,body,note,age,rows:new Map()});
      }
      parent.append(this.summary,this.root);
    }
    update(model) {
      this.summary.textContent=model.label;
      for (const card of model.cards) {
        const v=this.cards.get(card.id); v.card.className=`actions-card t-${C.tone(card.state)}`; v.title.textContent=card.title;
        v.den.textContent=card.id==="spend"?"net_amount · per billing cycle":card.denominator; v.note.textContent=card.note; v.age.textContent=card.available?"Fresh observations":card.stale?"Stale / unavailable observations":"Unavailable";
        if (["spend","robot"].includes(card.id)) {
          if (!v.meter) {
            v.meter=new C.MeterView(v.body); v.proj=C.element("span","m-tick-l"); v.projTick=C.element("i","m-tick proj"); v.meter.track.append(v.projTick,v.proj); v.spenders=C.element("ul","actions-spenders"); v.body.append(v.spenders);
          }
          const percent=card.percent, m=v.meter;
          // Shared MeterView owns threshold entry/cap motion; exact display values remain card-owned.
          const evidence={limit:100000,used:percent===null?null:Math.round(percent*1000),remaining:percent===null?null:100000-Math.round(percent*1000),secondary_limited:card.id==="robot" && card.state==="boulder"};
          m.update(evidence); m.value.textContent=card.value; m.denominator.textContent=card.denominator; m.reason.textContent="";
          m.root.className=`m t-${C.tone(card.state)}${percent===null?" unknown":""}${card.projection?" has-l":""}`; m.fill.className=`m-fill t-${C.tone(card.id==="spend"?stateOf(percent===null?null:percent/100):card.state)}`; m.fill.style.width=`${percent??0}%`;
          m.track.setAttribute("aria-label",`${card.title}: ${card.value}; ${card.denominator}; ${card.note}`);
          v.proj.hidden=v.projTick.hidden=!card.projection;
          if(!card.projection) v.proj.textContent="";
          if(card.projection) {v.proj.textContent=`proj ${dollars(card.projection.value)} est.`; v.proj.style.left=v.projTick.style.left=`${card.projection.percent}%`; v.proj.className=`m-tick-l${card.projection.percent>85?" end":""}`;}
          v.spenders.replaceChildren(...card.rows.map(row=>{const li=C.element("li"); li.append(C.element("span","mono",row.repo),C.element("span","mono",dollars(row.net_amount)));return li;}));
        } else {
          if(!v.headline) {v.headline=C.element("strong","actions-headline mono"); v.list=C.element("div","actions-rows");v.body.append(v.headline,v.list);}
          v.headline.textContent=card.id==="queue"?card.value:"";
          const keep=new Set(card.rows.map(row=>row.repo));
          for(const [key,row] of v.rows) if(!keep.has(key)){row.node.remove();v.rows.delete(key);}
          for(const row of card.rows) {
            let view=v.rows.get(row.repo);
            if(!view) {view={node:C.element("div","actions-row"),name:C.element("span","mono"),bar:C.element("div",card.id==="queue"?"actions-qbar":"mini"),value:C.element("span","mono"),detail:C.element("span","sub")};
              view.fill=C.element("span",card.id==="queue"?"actions-queued":"mini-fill");view.run=C.element("span","actions-running");view.bar.append(view.fill,view.run);view.node.append(view.name,view.bar,view.value,view.detail);v.rows.set(row.repo,view);v.list.append(view.node);}
            view.name.textContent=row.repo.split("/")[1];view.value.textContent=row.value;view.detail.textContent=row.detail;
            view.node.className=`actions-row t-${C.tone(row.state)}`;
            if(card.id==="queue") {view.bar.className=`actions-qbar${row.state==="boulder"?" jam":""}`;view.fill.style.width=`${row.queued===null?0:row.queued/card.scale*100}%`;view.run.style.width=`${row.running===null?0:row.running/card.scale*100}%`;}
            else {view.fill.className=`mini-fill t-${C.tone(row.state)}`;view.fill.style.width=`${row.percent??0}%`;view.bar.classList.toggle("unknown",row.percent===null);}
            view.bar.setAttribute("role","img");view.bar.setAttribute("aria-label",`${row.repo}: ${row.value}; ${row.detail}`);
          }
          if(card.id==="queue"&&!v.legend){v.legend=C.element("div","actions-qleg","■ queued (amber) · ■ running (blue)");v.body.append(v.legend);}
        }
      }
    }
  }
  function render(parent,model) {
    let view=views.get(parent);
    if(!view){view=new BudgetView(parent);views.set(parent,view);}
    else if(view.summary.parentNode!==parent || view.root.parentNode!==parent) {
      // The shared unavailable placeholder can detach the retained view. Restore
      // its nodes and classifier history; an interrupted entry must not replay.
      for(const card of view.cards.values()) card.meter?.cap.classList.remove("fresh");
      parent.replaceChildren(view.summary,view.root);
    }
    view.update(model);
  }
  // The header chip: which repositories' Actions GITHUB_TOKEN budgets are exhausted now.
  // Exhaustion is the observed installation rate-limit failure the token card carries;
  // nothing else establishes it, and reset is never observable.
  function tokenSummary(model) {
    const token = Array.isArray(model?.cards) ? model.cards.find(card => card?.id === "token") : null;
    const rows = Array.isArray(token?.rows) ? token.rows : [];
    if (!rows.length) return {state:"idle", value:"Not observed yet", note:"Actions budget awaiting its first observation"};
    const exhausted = rows.filter(row => row.exhausted === true);
    if (exhausted.length) {
      const names = exhausted.map(row => row.repo.split("/")[1]), runs = exhausted.flatMap(row => row.runs || []).slice(0,3);
      return {state:"boulder", value:`Exhausted · ${names.join(", ")}`,
        note:`Installation rate limit in run ${runs.join(", ")} · reset unknown · GITHUB_TOKEN, 1,000 requests per hour per repository`, repos:exhausted.map(row => row.repo)};
    }
    // "No exhaustion seen" needs a fresh, complete failed-job log scan of every repository.
    const scanned = rows.filter(row => row.scanned === true).length, all = scanned === rows.length;
    const state = !all ? "idle" : token.state === "bump" ? "bump" : "clear";
    return {state, value: !all ? "Not fully observed" : state === "bump" ? "Near the limit" : "No exhaustion seen",
      note:`Failed-job logs of the last hour · ${scanned} of ${rows.length} ${rows.length === 1 ? "repository" : "repositories"} scanned`, repos:[]};
  }
  function install(app) {app.registerPanel("budget","actions",project,render);}
  return {project,BudgetView,render,install,tokenSummary};
});
