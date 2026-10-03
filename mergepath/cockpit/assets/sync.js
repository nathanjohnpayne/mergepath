"use strict";
(function (root, factory) {
  const C = typeof module === "object" && module.exports ? require("./components.js") : root.CockpitComponents;
  const api = factory(C);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.CockpitSync = api;
})(globalThis, function (C) {
  const PHASES = ["idle", "previewing", "preview", "running", "done", "error", "canceled"];
  const STAGES = ["fetch", "diff", "branch", "commit", "PR"];
  const REFUSALS = {
    __proto__:null,
    cached_author_required:"The cached author credential is unavailable. Refresh credentials in the terminal, then close this dialog and create a new preview.",
    cleanup_incomplete:"Worker cleanup could not be verified. Check the Cockpit terminal; sync remains blocked until cleanup is confirmed.",
    hub_dirty:"The hub checkout has local changes. Clean it in the terminal, then create a new preview.",
    hub_not_main:"The hub checkout must be on main. Switch branches in the terminal, then create a new preview.",
    hub_not_origin_main:"The hub checkout must exactly match origin/main. Update it in the terminal, then create a new preview.",
    hub_origin_mismatch:"The hub origin does not match the trusted repository. Check the launch checkout in the terminal.",
    consumer_changed:"Consumer evidence changed after the preview. Close this dialog and create a new preview.",
    preview_changed:"Hub or manifest evidence changed after the preview. Close this dialog and create a new preview.",
    preview_expired:"The preview expired. Close this dialog and create a new preview.",
    preview_consumed:"This preview has already been used. Review its results before creating a new preview.",
    preview_mismatch:"The confirmation no longer matches the preview. Close this dialog and create a new preview.",
    audit_stale:"Fresh consumer evidence is unavailable. Refresh Fleet, then create a new preview.",
    audit_incomplete:"Consumer evidence is incomplete. Refresh Fleet, then create a new preview.",
    audit_unavailable:"The consumer audit is unavailable. Check the Cockpit terminal and refresh Fleet before previewing again.",
    audit_log_unavailable:"The action log is unavailable. Check the Cockpit terminal before starting another sync.",
    sync_busy:"Another sync or preview is still active. Wait for it to finish before previewing again.",
    unsupported_git_signing:"Configured commit signing is unavailable in this version of Cockpit. Use the supported terminal workflow.",
    git_identity_unavailable:"Git name or email is unavailable. Configure them in the terminal, then restart Cockpit and preview again.",
    deadline_exceeded:"The operation reached its time limit. Review retained results before creating a new preview.",
    output_limit:"The operation produced too much output. Check the Cockpit terminal and review retained results before previewing again.",
    worker_protocol_error:"Worker progress could not be verified. Check the Cockpit terminal and review retained results before previewing again.",
    sync_failed:"Sync could not complete. Check the Cockpit terminal and review retained results before creating a new preview.",
    all_skipped:"Choose at least one consumer to sync.",
    ahead_ack_required:"Acknowledge that the selected consumers are ahead of the hub before starting sync.",
    session_unavailable:"The Cockpit session is unavailable. Reopen Cockpit from the terminal before previewing again."
  };
  const repo = value => typeof value === "string" && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value);
  const sha = value => typeof value === "string" && /^[0-9a-f]{40}$/.test(value);
  const text = (value, limit=4096) => typeof value === "string" && value.length <= limit && !/[\x00-\x08\x0b-\x1f]/.test(value);
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const prURL = (value, repository) => typeof value === "string" && value.startsWith(`https://github.com/${repository}/pull/`) && /^[1-9][0-9]*$/.test(value.slice(`https://github.com/${repository}/pull/`.length));
  function validPreview(p) {
    return object(p) && p.schema === "cockpit-sync-preview/v1" && /^[A-Za-z0-9_-]{43}$/.test(p.preview_id) && sha(p.hub_sha)
      && C.epoch(p.expires_at) !== null && typeof p.can_confirm === "boolean" && Array.isArray(p.checks) && p.checks.every(v=>text(v))
      && text(p.dry_run,262144) && text(p.scope_note) && Array.isArray(p.targets) && p.targets.length>0 && p.targets.length<=256
      && new Set(p.targets.map(t=>t.repo)).size===p.targets.length && p.targets.every(t=>object(t) && repo(t.repo) && text(t.name,128)
        && ["in-sync","drift","ahead","override-only","fetch-error"].includes(t.status) && typeof t.eligible==="boolean" && typeof t.ahead==="boolean"
        && (t.baseline===null || text(t.baseline)) && Array.isArray(t.paths) && t.paths.length<=10000 && t.paths.every(path=>object(path)
          && text(path.path) && ["canonical","kit","templated"].includes(path.class) && text(path.direction))
        && (t.open_sync_prs===null || Array.isArray(t.open_sync_prs) && t.open_sync_prs.every(p=>object(p) && Number.isSafeInteger(p.number) && p.number>0 && text(p.branch)))
        && Array.isArray(t.choices) && t.choices.length>0 && t.choices.every(c=>["skip","sync","recreate"].includes(c)) && t.choices.includes(t.default_choice)
        && (!t.eligible ? t.choices.length===1 && t.choices[0]==="skip" : t.open_sync_prs!==null
          && (t.open_sync_prs.length ? t.choices.length===2 && t.choices.includes("skip") && t.choices.includes("recreate") && t.default_choice==="skip"
            : t.choices.length===2 && t.choices.includes("skip") && t.choices.includes("sync"))));
  }
  function validState(state) {
    if (!object(state) || state.schema!=="cockpit-sync/v1" || !PHASES.includes(state.phase) || (state.error!==null && !text(state.error,128))
      || (state.preview!==null && !validPreview(state.preview))) return false;
    if (["preview"].includes(state.phase) && state.preview===null) return false;
    const run=state.run;
    if (run===null) return !["running","done"].includes(state.phase);
    if (!object(run) || run.schema!=="cockpit-sync-run/v1" || !/^[0-9a-f]{32}$/.test(run.run_id) || !sha(run.hub_sha)
      || run.operator!=="nathanjohnpayne" || C.epoch(run.started_at)===null || !Array.isArray(run.repos) || !run.repos.length
      || !run.repos.every(repo) || new Set(run.repos).size!==run.repos.length || !object(run.choices)
      || !["running","success","partial","refused","failed"].includes(run.outcome) || !Array.isArray(run.events) || run.events.length>1500 || !Array.isArray(run.results)) return false;
    const events=new Set();
    for (const e of run.events) {
      if (!object(e) || !Number.isSafeInteger(e.id) || e.id<1 || events.has(e.id)) return false;
      events.add(e.id);
      if (e.kind==="log") {if (!text(e.text)) return false;}
      else if (e.kind==="stage") {if (!run.repos.includes(e.repo) || !STAGES.includes(e.value)) return false;}
      else if (e.kind==="result") {if (!run.repos.includes(e.repo) || !["no-change","existing"].includes(e.value) && !prURL(e.value,e.repo)) return false;}
      else if (e.kind==="outcome") {if (!["success","partial","refused","failed"].includes(e.value)) return false;}
      else return false;
    }
    return new Set(run.results.map(r=>r.repo)).size===run.results.length && run.results.every(r=>object(r) && r.kind==="result" && run.repos.includes(r.repo)
      && (["no-change","existing"].includes(r.value) || prURL(r.value,r.repo))) && (run.outcome!=="success" || run.results.length===run.repos.length);
  }
  function createActions(fetcher, setTimer=(fn,ms)=>globalThis.setTimeout(fn,ms), clearTimer=id=>globalThis.clearTimeout(id)) {
    return Object.fromEntries(["preview","confirm","cancel"].map(action=>[action, async payload=>{
      const abort=new AbortController(), timer=setTimer(()=>abort.abort(),10000);
      try {
        const session=await fetcher("api/session",{credentials:"same-origin",cache:"no-store",signal:abort.signal});
        if (!session.ok) throw new Error("session_unavailable");
        const value=await session.json();
        if (!/^[A-Za-z0-9_-]{43}$/.test(value?.csrf)) throw new Error("session_unavailable");
        const response=await fetcher(`api/sync/${action}`,{method:"POST",credentials:"same-origin",cache:"no-store",signal:abort.signal,
          headers:{"X-Cockpit-CSRF":value.csrf,"Content-Type":"application/json"},body:JSON.stringify(payload)});
        const state=await response.json();
        if (!response.ok || !validState(state)) throw new Error(typeof state?.error==="string" ? state.error : "sync_unavailable");
        return state;
      } finally {clearTimer(timer);}
    }]));
  }
  function button(label, fn, primary=false) {
    const node=C.element("button",`btn${primary?" primary":""}`,label);node.type="button";node.addEventListener("click",fn);return node;
  }
  class SyncDialog {
    constructor(parent, actions, {now=()=>Date.now()/1000,setTimer=(fn,ms)=>globalThis.setTimeout(fn,ms),clearTimer=id=>globalThis.clearTimeout(id)}={}) {
      Object.assign(this,{parent,actions,now,setTimer,clearTimer});this.state=null;this.step="preview";this.visible=false;this.busy=false;this.choiceNodes=new Map();this.eventNodes=new Map();this.railNodes=new Map();this.resultNodes=new Map();
      this.overlay=C.element("div","sync-overlay");this.overlay.hidden=true;
      this.modal=C.element("section","sync-modal");this.modal.setAttribute("role","dialog");this.modal.setAttribute("aria-modal","true");
      this.title=C.element("h3","","Preview the sync");this.title.id="cockpit-sync-title";this.title.setAttribute("tabindex","-1");this.modal.setAttribute("aria-labelledby",this.title.id);
      this.steps=C.element("div","sync-steps","1 · Preview    2 · Confirm    3 · Run");this.body=C.element("div","sync-body");this.footer=C.element("div","sync-footer");
      this.error=C.element("div","sync-error");this.error.setAttribute("role","status");this.error.hidden=true;
      this.modal.append(this.steps,this.title,this.error,this.body,this.footer);this.overlay.append(this.modal);parent.append(this.overlay);
      this.overlay.addEventListener("keydown",e=>{
        if(e.key==="Escape"){e.preventDefault();this.dismiss();}
        if(e.key==="Tab"){
          const nodes=[...this.modal.querySelectorAll('button:not([disabled]),input:not([disabled]),a[href]')].filter(n=>!n.hidden && !n.closest('[hidden]'));
          if(!nodes.length){e.preventDefault();this.title.focus();return;}
          const first=nodes[0],last=nodes[nodes.length-1];
          if(e.shiftKey && (document.activeElement===first || document.activeElement===this.title)){e.preventDefault();last.focus();}
          else if(!e.shiftKey && (document.activeElement===last || document.activeElement===this.title)){e.preventDefault();first.focus();}
        }
      });
    }
    reveal() {
      if(this.visible)return;
      this.returnFocus=document.activeElement;this.inert=[];
      for(const n of this.parent.children)if(n!==this.overlay && !["SCRIPT","STYLE","LINK"].includes(n.tagName)){this.inert.push([n,n.inert]);n.inert=true;}
      this.visible=true;this.overlay.hidden=false;this.title.focus();
    }
    hide() {
      this.dismissedRunId=this.state?.run?.run_id??null;
      this.visible=false;this.overlay.hidden=true;for(const [n,inert] of this.inert??[])n.inert=inert;
      this.inert=[];if(this.returnFocus?.isConnected)this.returnFocus.focus();
    }
    focusStep(key) {if(this.visible && this.focusKey!==key){this.focusKey=key;this.title.focus();}}
    fail(error) {const value=String(error?.message??error??"Sync unavailable");this.error.hidden=false;this.error.textContent=REFUSALS[value]??(/^[a-z][a-z_]+$/.test(value)?"The operation could not complete. Check the Cockpit terminal, then close this dialog and create a new preview.":value.replaceAll("_"," "));}
    async open(repos) {
      if(this.busy)return;
      if(this.state?.phase==="running"){this.reveal();return;}
      this.reveal();this.step="preview";this.focusKey=null;this.busy=true;this.body.replaceChildren(C.element("p","","Checking the clean hub and refreshing consumer evidence…"));this.footer.replaceChildren(button("Cancel",()=>this.dismiss()));
      this.title.textContent="Preview the sync";this.error.hidden=true;
      try{this.update(await this.actions.preview({repos}));}catch(e){this.fail(e);}finally{this.busy=false;this.controls();}
    }
    async dismiss() {
      if(this.state?.phase==="preview" || this.state?.phase==="previewing"){
        try{this.update(await this.actions.cancel({preview_id:this.state.preview?.preview_id??null}));}catch(e){this.fail(e);return;}
      }
      this.hide();
    }
    update(state) {
      if(!validState(state)){if(this.visible)this.fail("Sync evidence unavailable");this.start && (this.start.disabled=true);return false;}
      if(this.state?.run?.run_id===state.run?.run_id && state.run && this.state.run.events.some((event,index)=>JSON.stringify(event)!==JSON.stringify(state.run.events[index]))){if(this.visible)this.fail("Sync event history changed");return false;}
      this.state=JSON.parse(JSON.stringify(state));
      if(state.phase==="running" && !this.visible && state.run.run_id!==this.dismissedRunId)this.reveal();
      if(!this.visible)return true;
      if(state.phase==="preview" && state.preview){
        if(this.previewId!==state.preview.preview_id){this.previewId=state.preview.preview_id;this.step="preview";this.choices=Object.fromEntries(state.preview.targets.map(t=>[t.repo,t.default_choice]));this.showPreview();}
        this.controls();
      }else if(state.run){this.showRun();}
      else if(state.phase==="error"){this.fail(state.error);const key=`error:${state.error}`;if(this.focusKey!==key)this.footer.replaceChildren(button("Close",()=>this.hide()));this.focusStep(key);}
      else if(state.phase==="canceled"){this.hide();}
      if(state.error){this.fail(state.error);if(this.start)this.start.disabled=true;if(this.next)this.next.disabled=true;}
      return true;
    }
    showPreview() {
      const p=this.state.preview;this.error.hidden=true;this.title.textContent="Preview the sync";this.body.replaceChildren();this.choiceNodes.clear();
      this.body.append(C.element("div","sync-callout mono",`Dry run: sync-to-downstream.sh --sync-all --repos ${p.targets.map(t=>t.repo).join(",")} --dry-run`));
      const checks=C.element("ul","sync-checks");for(const check of p.checks)checks.append(C.element("li","",`✓ ${check}`));this.body.append(checks);
      for(const t of p.targets){
        const plan=C.element("div","sync-plan");plan.append(C.element("strong","",`${t.name} · ${t.status} · ${t.paths.length} paths`));
        const list=C.element("ul","sync-paths");
        for(const path of t.paths){const row=C.element("li");row.append(C.element("span","mono",path.path),C.element("span",`fleet-class cls-${path.class}`,path.class),C.element("span","soft",path.direction));list.append(row);}
        plan.append(list);
        if(!t.eligible)plan.append(C.element("p","soft",`Skipped: ${t.reason??t.status}`));
        else {
          const choices=C.element("div","sync-choices");
          if(t.open_sync_prs.length)plan.append(C.element("p","",`Open sync PR ${t.open_sync_prs.map(p=>`#${p.number}`).join(", ")} exists. Recreate leaves old PRs open; close them yourself.`));
          for(const choice of t.choices){const b=button(choice[0].toUpperCase()+choice.slice(1),()=>{this.choices[t.repo]=choice;this.controls();});b.setAttribute("aria-pressed",String(choice===this.choices[t.repo]));choices.append(b);this.choiceNodes.set(`${t.repo}:${choice}`,b);}
          plan.append(choices);
        }
        if(t.ahead)plan.append(C.element("div","sync-warning","Consumer is ahead of the hub. Sync overwrites consumer-ahead paths; a separate acknowledgment is required."));
        this.body.append(plan);
      }
      const details=C.element("details","sync-dry");details.append(C.element("summary","","Proposed dry-run scope"),C.element("p","soft",p.scope_note),C.element("pre","sync-log",p.dry_run));this.body.append(details);
      this.next=button("Continue to confirm",()=>this.showConfirm(),true);this.footer.replaceChildren(button("Cancel",()=>this.dismiss()),this.next);
      this.clearTimer(this.expiryTimer);this.expiryTimer=this.setTimer(()=>this.controls(),Math.max(0,(p.expires_at-this.now())*1000));this.controls();
      this.focusStep(`preview:${p.preview_id}`);
    }
    controls() {
      const p=this.state?.preview;if(!p)return;
      const selected=p.targets.filter(t=>this.choices[t.repo]!=="skip");const enabled=p.can_confirm && this.now()<p.expires_at && selected.length>0 && !this.busy;
      for(const t of p.targets)for(const c of t.choices){const b=this.choiceNodes.get(`${t.repo}:${c}`);if(b){b.setAttribute("aria-pressed",String(this.choices[t.repo]===c));b.classList.toggle("on",this.choices[t.repo]===c);}}
      if(this.next)this.next.disabled=!enabled;
      if(this.start)this.start.disabled=!enabled || selected.some(t=>t.ahead) && !this.ack?.checked;
      if(this.now()>=p.expires_at)this.fail("Preview expired. Close and preview again.");
    }
    showConfirm() {
      this.step="confirm";const p=this.state.preview, selected=p.targets.filter(t=>this.choices[t.repo]!=="skip");
      if(!selected.length)return;this.error.hidden=true;this.title.textContent="Confirm the sync";this.body.replaceChildren();
      this.body.append(C.element("div","sync-callout",`Cut a sync from hub origin/main ${p.hub_sha} to ${selected.map(t=>t.repo).join(", ")}. It uses the cached author identity through scripts/gh-as-author.sh, one consumer at a time, and logs operator, time, SHA and targets.`));
      this.ack=null;
      const ahead=selected.filter(t=>t.ahead);
      if(ahead.length){const label=C.element("label","sync-warning sync-ack");this.ack=C.element("input");this.ack.type="checkbox";this.ack.checked=false;this.ack.addEventListener("change",()=>this.controls());label.append(this.ack,C.element("span","",`I understand ${ahead.map(t=>t.repo).join(", ")} is ahead of the hub and this sync overwrites those paths.`));this.body.append(label);}
      this.start=button("Start sync",()=>this.begin(),true);this.footer.replaceChildren(button("Back",()=>{this.step="preview";this.start=null;this.ack=null;this.showPreview();}),this.start);this.controls();
      this.focusStep(`confirm:${p.preview_id}`);
    }
    async begin() {
      if(this.busy || this.start?.disabled)return;this.busy=true;this.controls();
      const p=this.state.preview;
      try{this.update(await this.actions.confirm({preview_id:p.preview_id,hub_sha:p.hub_sha,choices:{...this.choices},ack_ahead:!!this.ack?.checked}));}
      catch(e){this.fail(e);}finally{this.busy=false;this.controls();}
    }
    showRun() {
      const run=this.state.run;
      if(this.runId!==run.run_id){
        this.runId=run.run_id;this.eventNodes.clear();this.resultNodes.clear();this.railNodes.clear();this.body.replaceChildren();
        this.rails=C.element("div","sync-rails");
        for(const repository of run.repos){const row=C.element("div","sync-rail-row");row.append(C.element("span","mono",repository));const rail=C.element("div","sync-rail");
          for(const stage of STAGES){const n=C.element("span","sync-stage",stage);rail.append(n);this.railNodes.set(`${repository}:${stage}`,n);}row.append(rail);this.rails.append(row);}
        this.log=C.element("div","sync-log");this.log.setAttribute("role","log");this.log.setAttribute("aria-live","polite");this.log.setAttribute("aria-relevant","additions");
        this.cursor=C.element("span","sync-cursor");this.log.append(this.cursor);this.done=C.element("div","sync-done");this.done.hidden=true;this.chips=C.element("div","sync-prchips");this.body.append(this.rails,this.log,this.done,this.chips);
      }
      this.title.textContent=run.outcome==="running"?`Syncing ${run.repos.join(", ")}`:run.outcome==="success"?"Sync complete":"Sync needs attention";
      for(const e of run.events){
        if(this.eventNodes.has(e.id))continue;
        this.eventNodes.set(e.id,e);
        if(e.kind==="log"){const n=C.element("div","sync-line",REFUSALS[e.text]??e.text);this.log.insertBefore(n,this.cursor);}
        if(e.kind==="stage"){
          const index=STAGES.indexOf(e.value),n=this.railNodes.get(`${e.repo}:${e.value}`);
          const later=STAGES.slice(index+1).some(s=>{const a=this.railNodes.get(`${e.repo}:${s}`);return a.classList.contains("active")||a.classList.contains("observed");});
          if(later)n.classList.add("observed");
          else{for(const s of STAGES.slice(0,index)){const a=this.railNodes.get(`${e.repo}:${s}`);if(a.classList.contains("active")){a.classList.remove("active");a.classList.add("observed");}}n.classList.add("active");}
        }
      }
      for(const r of run.results){if(this.resultNodes.has(r.repo))continue;const n=prURL(r.value,r.repo)?C.element("a","sync-prchip",`${r.repo} #${r.value.split("/").at(-1)}`):C.element("span","sync-prchip",`${r.repo} · ${r.value}`);
        if(prURL(r.value,r.repo)){n.href=r.value;n.target="_blank";n.rel="noopener noreferrer";}this.resultNodes.set(r.repo,n);this.chips.append(n);
        for(const stage of STAGES){const s=this.railNodes.get(`${r.repo}:${stage}`);if(s.classList.contains("active")){s.classList.remove("active");s.classList.add("observed");}}
      }
      this.cursor.hidden=run.outcome!=="running";
      if(run.outcome!=="running"){const reason=run.events.findLast(e=>e.kind==="log" && Object.hasOwn(REFUSALS,e.text));if(reason)this.fail(reason.text);}
      if(run.outcome!=="running" && this.done.hidden){this.done.hidden=false;this.done.append(C.element("span",`sync-done-glyph ${run.outcome==="success"?"success":"attention"}`,run.outcome==="success"?"✓":"!"),C.element("span","",run.outcome==="success"?"Sync finished. Resulting PRs will refresh in Fleet and Open PRs.":`${run.outcome}. Completed results are retained; this run cannot be replayed.`));}
      if(this.footer.dataset.run!==`${run.run_id}:${run.outcome}`){this.footer.dataset.run=`${run.run_id}:${run.outcome}`;this.footer.replaceChildren(button(run.outcome==="running"?"Hide · continues in background":"Close",()=>this.hide()));}
      this.focusStep(`run:${run.run_id}:${run.outcome}`);
    }
    close() {this.clearTimer(this.expiryTimer);this.hide();this.overlay.remove();}
  }
  function install(app, actions, options={}) {
    const parent=options.parent??document.querySelector(".ck")??document.body;
    return new SyncDialog(parent,actions,options);
  }
  return {STAGES,validPreview,validState,prURL,createActions,SyncDialog,install};
});
