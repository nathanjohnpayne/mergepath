"use strict";
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs"), cp = require("node:child_process");
const CI = require("../mergepath/cockpit/assets/ci.js"), C = require("../mergepath/cockpit/assets/components.js");
const fixtures = JSON.parse(cp.execFileSync("python3", ["-B", "-c", "import sys,json;sys.path.insert(0,'tests');import test_cockpit_ci as ci;print(json.dumps(ci.browser_fixtures()))"], {cwd: require("node:path").resolve(__dirname,".."), timeout: 10000}));
const pythonFixture = key => {assert.ok(Object.hasOwn(fixtures, key), `unknown Python fixture: ${key}`); return structuredClone(fixtures[key]);};
const fixture = () => pythonFixture("model");
const envelope = data => ({data, observed_at: 1000, stale: false});
test("Batched Python fixtures return independent nested payloads for every case", () => {
  const original = fixture(), changed = fixture();
  changed.runs[0].name = "mutated"; changed.runs[0].jobs[0].steps.length = 0;
  assert.deepEqual(fixture(), original);
  const external = pythonFixture("external:False"); external.data.check_rows[0].checks[0].producer = null;
  assert.equal(pythonFixture("external:False").data.check_rows[0].checks[0].producer, "app:77");
});
for (const field of ["name", "diagnostic", "excerpt"]) test(`Python Unicode ${field} limit round-trips through browser validation`, () => {
  const {data, excerpt} = pythonFixture("unicode");
  if (field === "name") {
    data.runs[0].diagnostics = [];
    assert.equal(CI.project(envelope(data), null, 1001).rows[0].name, "🚀".repeat(1000));
    data.runs[0].name += "🚀"; assert.throws(() => CI.validate(data));
    data.runs[0].name = "a".repeat(1000); assert.doesNotThrow(() => CI.validate(data));
  } else if (field === "diagnostic") {
    data.runs[0].name = "repo_lint";
    assert.doesNotThrow(() => CI.validate(data));
    assert.equal(data.runs[0].diagnostics[0].text, "🚀".repeat(4000));
    data.runs[0].diagnostics[0].text += "🚀"; assert.throws(() => CI.validate(data));
    data.runs[0].diagnostics[0].text = "a".repeat(4000); assert.doesNotThrow(() => CI.validate(data));
  } else {
    assert.ok(CI.excerptText(excerpt).includes("FAIL:" + "🚀".repeat(995)));
    assert.match(CI.excerptText(excerpt), /Excerpt truncated/);
    excerpt.lines[0] += "🚀"; assert.match(CI.excerptText(excerpt), /invalid response/);
    excerpt.lines = ["FAIL:" + "a".repeat(995)]; assert.ok(CI.excerptText(excerpt).includes(excerpt.lines[0]));
  }
});
for (const withActions of [true, false]) test(`Provider external check failure reaches browser projection; Actions=${withActions}`, () => {
  const {data} = pythonFixture(`external:${withActions ? "True" : "False"}`);
  const model = CI.project(envelope(data), null, 1001);
  assert.equal(model.state, "bump"); assert.equal(model.hazards.length, 1);
  assert.equal(C.normalizeHazards(model.hazards, ["owner/repo"]).diagnostics.length, 0);
  const retained = CI.project({...envelope(data),stale:true}, null, 1010);
  assert.equal(retained.hazards[0].stale, true); assert.equal(retained.hazards[0].observed_at, 1000);
  const row = model.rows.find(row => row.checks.some(check => check.id === "200"));
  assert.equal(row.current_head, true); assert.equal(row.pr, "7"); assert.equal(row.rerun_command, null);
  assert.equal(row.checks[0].producer, "app:77"); assert.equal(row.diagnostics[0].source, "check-run output");
});
test("Unknown check producer or Actions lineage remains actionable beside passing workflow", () => {
  for (const unknownApp of [true, false]) {
    const {data} = pythonFixture(`unknown:${unknownApp ? "True" : "False"}`);
    const model = CI.project(envelope(data), null, 1001);
    assert.equal(model.state, "bump"); assert.equal(model.hazards.length, 1);
    assert.equal(data.check_rows[0].checks[0].superseded_by, null);
  }
});
test("Workflow with empty PR metadata projects current failure from independently observed open HEAD", () => {
  const {data} = pythonFixture("workflow-no-pr");
  const model = CI.project(envelope(data), null, 1001);
  assert.equal(model.state, "bump"); assert.equal(model.hazards.length, 1);
  assert.equal(model.rows[0].pr, "7"); assert.equal(model.rows[0].current_head, true);
  assert.equal(model.rows[0].key, "owner/repo:10:7"); assert.equal(data.check_rows.length, 0);
  assert.ok(model.hazards[0].title.includes("#7"));
});
test("Successful workflow history clears only with independently observed current HEAD", () => {
  for (const [key, current, label] of [["current", true, "Passed"],
    ["old", false, "Passed · old HEAD"], ["closed", null, "Passed · HEAD unknown"],
    ["unattached", null, "Passed · HEAD unknown"]]) {
    const {data} = pythonFixture(`passed:${key}`);
    const model = CI.project(envelope(data), null, 1001);
    assert.equal(model.rows[0].current_head, current);
    assert.deepEqual(CI.runTone(model.rows[0]), {state:current === true ? "clear" : "idle", label});
    assert.equal(model.state, current === true ? "clear" : "idle");
    assert.equal(model.hazards.length, 0); assert.equal(model.stale, false);
    assert.equal(model.rows.filter(row => row.kind !== "checks").length, 1);
    assert.equal(data.check_rows.length, key === "old" ? 1 : 0);
    if (current !== true) {
      const fresh = pythonFixture("passed:current").data.runs[0];
      fresh.id = "11"; fresh.key = `${fresh.repo}:11:${fresh.pr}`;
      fresh.sha = data.check_rows[0]?.sha ?? fresh.sha;
      for (const check of fresh.checks) check.sha = fresh.sha;
      const check_rows = data.check_rows.filter(row => row.pr !== fresh.pr || row.sha !== fresh.sha);
      assert.equal(CI.project(envelope({...data,runs:[...data.runs,fresh],check_rows}), null, 1001).state, "clear");
    }
  }
});
test("Check-only pending or unavailable evidence cannot project a clear state", () => {
  for (const [status, expected] of [["queued","running"],["in_progress","running"],["completed","idle"],["unknown","idle"]]) {
    const {data} = pythonFixture(`pending:${status}`);
    assert.equal(CI.project(envelope(data), null, 1001).state, expected);
  }
  const {data} = pythonFixture("no-head");
  assert.equal(CI.project(envelope(data), null, 1001).state, "idle");
  assert.equal(CI.project(envelope(data), null, 1001).hazards.length, 0);
});
test("Every observed open HEAD retains unknown coverage when no workflows or checks exist", () => {
  for (const kind of ["uncovered", "uncovered-only"]) {
    const {data} = pythonFixture(`coverage:${kind}`), model = CI.project(envelope(data), null, 1001);
    assert.equal(model.state, "idle"); assert.equal(model.hazards.length, 0); assert.equal(model.stale, false);
    const markers = model.rows.filter(row => row.kind === "checks" && row.checks.length === 0);
    assert.equal(markers.length, kind === "uncovered" ? 1 : 2);
    for (const row of markers) {
      assert.equal(row.current_head, true); assert.equal(row.check_evidence_unknown, true);
      assert.deepEqual(CI.runTone(row), {state:"idle", label:"No check observations"});
      assert.equal(row.id, null); assert.equal(row.rerun_command, null); assert.deepEqual(row.jobs, []);
    }
  }
});
test("Current cancellation blocks only otherwise-clear selected coverage", () => {
  for (const [kind, expected] of [["cancelled","idle"],["check-cancelled","idle"],["old-cancelled","clear"],
    ["all-pass","clear"],["neutral","clear"],["skipped","clear"],["stale","idle"],["unknown-completion","idle"],
    ["check-neutral","clear"],["check-skipped","clear"],["check-stale","idle"],["check-unknown-completion","idle"],
    ["unknown-status","idle"],
    ["running-cancelled","running"],["failed-cancelled","bump"]]) {
    const {data} = pythonFixture(`coverage:${kind}`);
    assert.equal(CI.project(envelope(data), null, 1001).state, expected, kind);
  }
  const {data} = pythonFixture("coverage:cancelled"), cancelled = data.runs[1];
  cancelled.repo = "owner/other"; cancelled.key = `owner/other:${cancelled.id}:${cancelled.pr}`;
  for (const check of cancelled.checks) check.repo = cancelled.repo;
  data.repositories.push({...data.repositories[0],repo:cancelled.repo});
  assert.equal(CI.project(envelope(data), "owner/repo", 1001).state, "clear");
  assert.equal(CI.project(envelope(data), "owner/other", 1001).state, "idle");
  assert.equal(CI.project(envelope(data), null, 1001).state, "idle");
});
test("Empty check coverage markers reject invented success or failure evidence", () => {
  const {data} = pythonFixture("coverage:uncovered-only"), marker = data.check_rows[0];
  for (const mutation of [{status:"completed"},{conclusion:"success"},{current_head:false},{pr:null},
    {check_evidence_unknown:false},{actionable:true},{superseded:true},{severity:"bump"},
    {diagnostics:[{text:"invented failure",source:"check-run output",check_id:"99"}]}]) {
    const row = {...marker,...mutation}; row.key = `${row.repo}:checks:${row.sha}:${row.pr ?? "none"}`;
    assert.throws(() => CI.validate({...data,check_rows:[row]}));
  }
});
for (const withActions of [true, false]) for (const status of ["queued", "in_progress"]) test(`Superseded external failure retains independent ${status} check tone; Actions=${withActions}`, () => {
  const {data, hot} = pythonFixture(`mixed:${withActions ? "True" : "False"}:${status}`);
  const model = CI.project(envelope(data), null, 1001), row = data.check_rows[0];
  assert.equal(hot, true); assert.equal(row.status, status); assert.equal(row.superseded, true);
  assert.equal(row.checks[0].superseded_by, "201"); assert.equal(row.checks[2].status, status);
  assert.equal(model.state, "running"); assert.equal(model.hazards.length, 0);
  assert.deepEqual(CI.runTone(row), {state:"running", label:status === "in_progress" ? "Running" : "Queued"});
});
test("Check rows reject fabricated Actions identities, jobs and commands", () => {
  const {data} = pythonFixture("external:False");
  const row = data.check_rows[0];
  for (const mutation of [{id:"200"},{attempt:"1"},{workflow_id:"9"},{jobs_scope:"all-attempts"},
    {rerun_command:"gh run rerun 200 --failed --repo owner/repo"},{jobs:fixture().runs[0].jobs}]) {
    assert.throws(() => CI.validate({...data, check_rows:[{...row,...mutation}]}));
  }
  assert.throws(() => CI.validate({...data,runs:[row],check_rows:[]}));
  assert.throws(() => CI.validate({...data,check_rows:[fixture().runs[0]]}));
});
test("Python contract and exact opaque identities survive browser JSON parsing", () => {
  const data = fixture(), row = data.runs[0]; row.id = "900719925474099312345"; row.pr = "900719925474099312346";
  row.workflow_id = "900719925474099312347"; row.key = `${row.repo}:${row.id}:${row.pr}`;
  row.rerun_command = `gh run rerun ${row.id} --failed --repo ${row.repo}`;
  assert.equal(CI.project(envelope(JSON.parse(JSON.stringify(data))), null, 1001).rows[0].id, row.id);
  row.id = 900719925474099312345; assert.throws(() => CI.validate(data));
});
test("unsuperseded current failure projects owned hazard; superseded/old head retain history", () => {
  const data = fixture(); let model = CI.project(envelope(data), null, 1001);
  assert.equal(model.state, "bump"); assert.equal(model.hazards[0].source, "ci");
  assert.equal(C.normalizeHazards(model.hazards, ["owner/repo"]).diagnostics.length, 0);
  const row = data.runs[0]; row.actionable = false; row.severity = null; row.superseded = true;
  model = CI.project(envelope(data), null, 1001); assert.equal(model.hazards.length, 0); assert.match(CI.runTone(row).label, /superseded/);
  row.superseded = false; row.current_head = false;
  assert.match(CI.runTone(row).label, /old HEAD/); assert.equal(CI.project(envelope(data), null, 1001).hazards.length, 0);
});
test("partial denial keeps useful rows, marks selected coverage stale, preserves age", () => {
  const data = fixture(); data.repositories.push({repo:"owner/denied",observed_at:null,attempted_at:1000,stale:true,error:"permission_denied",retry_at:1020});
  const mixed = CI.project(envelope(data), null, 1010);
  assert.equal(mixed.rows.length, 1); assert.equal(mixed.stale, true); assert.match(mixed.label, /unavailable/);
  assert.equal(mixed.hazards[0].stale, false);
  assert.equal(CI.project(envelope(data), "owner/repo", 1010).stale, false);
  const denied = CI.project(envelope(data), "owner/denied", 1010); assert.equal(denied.rows.length, 0); assert.equal(denied.state,"idle");
  const retained = CI.project({...envelope(data),stale:true}, "owner/repo", 1010);
  assert.equal(retained.stale,true); assert.equal(retained.hazards[0].observed_at,1000); assert.equal(retained.hazards[0].stale,true);
});
test("unknown or rejected identities cannot become clear coverage", () => {
  const data = fixture(), row = data.runs[0]; row.actionable = false; row.severity = null; row.current_head = null;
  assert.equal(CI.project(envelope(data),null,1001).state,"idle");
  row.jobs[0].steps[0].number = 2; assert.throws(()=>CI.validate(data)); row.jobs[0].steps[0].number = "2";
  row.checks[0].producer = "shell-connection"; assert.throws(()=>CI.validate(data));
  row.checks[0].producer = "app:1:workflow:9"; data.runs.push(structuredClone(row)); assert.throws(()=>CI.validate(data));
});
test("queue age adds no blocker; running job concludes without changing run key", () => {
  const data = fixture(), row = data.runs[0]; row.actionable = false; row.severity = null; row.status = "queued"; row.conclusion = null;
  const queued = CI.project(envelope(data),null,500000); assert.equal(queued.state,"running"); assert.equal(queued.hazards.length,0);
  row.status = "in_progress"; assert.equal(CI.runTone(row).label,"Running");
  row.status = "completed"; row.conclusion = "success"; row.check_evidence_unknown = false;
  const final = CI.project(envelope(data),null,1001); assert.equal(final.state,"clear"); assert.equal(final.rows[0].key,queued.rows[0].key);
});
test("log URL stays scoped and FAIL-only output preserves honest attribution and hostile literal text", () => {
  const row = fixture().runs[0]; const path = CI.excerptURL(row,row.jobs[0],row.jobs[0].steps[0]);
  const url = new URL(path,"http://127.0.0.1:7357/s/instance/"); assert.equal(url.pathname,"/s/instance/api/ci/excerpt");
  assert.equal(url.searchParams.get("repo"),"owner/repo"); assert.equal(url.searchParams.get("step"),"2");
  const hostile = "FAIL: <img src=x onerror=evil()>";
  assert.match(CI.excerptText({status:"ok",scope:"job",lines:[hostile]}),/Whole-job/);
  assert.ok(CI.excerptText({status:"ok",scope:"job",lines:[hostile]}).includes(hostile));
  assert.match(CI.excerptText({status:"empty",scope:"step-time-window",lines:[]}),/No FAIL:/);
  assert.match(CI.excerptText({status:"denied",lines:[]}),/denied/);
  assert.match(CI.excerptText({status:"ok",lines:["Error: bad"]}),/invalid/);
});

class Node {
  constructor(tag) {this.tagName=tag;this.children=[];this.parentNode=null;this.attrs={};this.listeners={};this.hidden=false;this.className="";this.style={};this._text="";}
  set textContent(value) {this._text=String(value); this.children.forEach(c=>c.parentNode=null); this.children=[];}
  get textContent(){return this._text+this.children.map(c=>c.textContent).join("");}
  get lastChild(){return this.children.at(-1);}
  append(...nodes){for(const node of nodes){node.remove();node.parentNode=this;this.children.push(node);}}
  insertBefore(node,reference){node.remove();node.parentNode=this;const index=reference===null?this.children.length:this.children.indexOf(reference);this.children.splice(index<0?this.children.length:index,0,node);}
  // Like a browser, detaching a node that holds focus drops it, and a hidden subtree cannot take focus.
  remove(){if(this.parentNode){if(this.contains(document.activeElement))document.activeElement=null;const p=this.parentNode;p.children.splice(p.children.indexOf(this),1);this.parentNode=null;}}
  setAttribute(key,value){this.attrs[key]=value;}
  addEventListener(name,fn){this.listeners[name]=fn;}
  contains(node){return node===this||this.children.some(c=>c.contains(node));}
  focus(){for(let n=this;n;n=n.parentNode)if(n.hidden)return;document.activeElement=this;}
}
function dom(){global.document={createElement:tag=>new Node(tag),activeElement:null};return new Node("div");}
test("Unknown open-HEAD marker uses honest copy and preserves disclosure when checks arrive", () => {
  const parent = dom(), {data} = pythonFixture("coverage:uncovered-only");
  const view = new CI.CIView(parent, () => assert.fail("unknown coverage cannot request logs"));
  view.update(CI.project(envelope(data), null, 1001));
  const key = data.check_rows[0].key, row = view.rows.get(key), button = row.button;
  view.toggle(key); button.focus();
  assert.ok(parent.textContent.includes("No check observations"));
  assert.ok(parent.textContent.includes("No workflow or check runs observed for this open HEAD."));
  assert.ok(!parent.textContent.includes("Failed run")); assert.ok(!parent.textContent.includes("gh run rerun"));
  assert.equal(row.jobs.size, 0); assert.equal(row.command.hidden, true);
  view.update(CI.project(envelope(pythonFixture("external:False").data), null, 1002));
  assert.equal(view.rows.get(key).button, button); assert.equal(document.activeElement, button);
  assert.equal(row.body.hidden, false); assert.ok(parent.textContent.includes("External gate failed"));
});
test("Unmatched checks render literal names, producer and diagnostic without Actions logs or rerun", () => {
  const {data} = pythonFixture("external:False");
  const parent = dom(), view = new CI.CIView(parent, () => assert.fail("unexpected fetch"));
  const check = data.check_rows[0].checks[0]; check.name = "<img onerror=evil()>";
  const model = CI.project(envelope(data), null, 1001); view.update(model); view.toggle(model.rows[0].key);
  const rendered = view.rows.get(model.rows[0].key);
  assert.ok(parent.textContent.includes("<img onerror=evil()>")); assert.ok(parent.textContent.includes("app:77"));
  assert.ok(parent.textContent.includes("External gate failed; check-run diagnostic"));
  assert.ok(parent.textContent.includes("check-run output · check 200"));
  assert.equal(rendered.command.hidden, true); assert.equal(rendered.jobs.size, 0);
  assert.ok(!parent.textContent.includes("gh run rerun")); assert.ok(!parent.textContent.includes("Show FAIL excerpt"));
  assert.ok(!model.hazards[0].detail.includes("Run null"));
});
test("renderer restores stable disclosed content after the shell replaces it with an invalid-data placeholder", () => {
  const parent=dom(), data=fixture(), render=CI.renderer(()=>assert.fail("unexpected fetch"));
  render(parent,CI.project(envelope(data),null,1001));
  const list=parent.children[2], row=list.children[0], button=row.children[0];
  button.listeners.click(); assert.equal(button.attrs["aria-expanded"],"true");
  parent.textContent="Invalid source observation";
  assert.equal(list.parentNode,null);
  render(parent,CI.project(envelope(data),null,1002));
  assert.equal(parent.children[2],list); assert.equal(list.children[0],row);
  assert.equal(button.attrs["aria-expanded"],"true");
  assert.ok(parent.textContent.includes("check_shell"));
  assert.ok(!parent.textContent.includes("Invalid source observation"));
  render(parent,CI.project(envelope(data),null,1003));
  assert.equal(parent.children.length,5); // summary, notes, list, history disclosure, empty
});
test("stable row, one disclosure and keyboard focus survive repeated live conclusions", () => {
  const parent=dom(), data=fixture(), view=new CI.CIView(parent,()=>assert.fail("unexpected fetch"));
  let model=CI.project(envelope(data),null,1001); view.update(model);
  const key=data.runs[0].key, row=view.rows.get(key), button=row.button;
  view.toggle(key); button.focus(); assert.equal(button.attrs["aria-expanded"],"true");
  data.runs[0].actionable=false;data.runs[0].severity=null;data.runs[0].status="completed";data.runs[0].conclusion="success";
  view.update(CI.project(envelope(data),null,1002)); assert.equal(view.rows.get(key).button,button);assert.equal(document.activeElement,button);assert.equal(row.body.hidden,false);
  const second=structuredClone(data.runs[0]);second.id="11";second.key="owner/repo:11:7";second.rerun_command=null;data.runs.push(second);
  view.update(CI.project(envelope(data),null,1003)); view.toggle(second.key);assert.equal(row.body.hidden,true);assert.equal(view.rows.get(second.key).body.hidden,false);
  view.toggle(second.key);assert.equal(view.rows.get(second.key).body.hidden,true);
});
test("obsolete log request is aborted and late response cannot overwrite new disclosure", async () => {
  const parent=dom(),data=fixture();let resolve;const calls=[];
  const view=new CI.CIView(parent,(url,options)=>{calls.push({url,options});return new Promise(r=>resolve=r);});
  view.update(CI.project(envelope(data),null,1001));const key=data.runs[0].key;view.toggle(key);
  const row=view.rows.get(key),step=row.jobs.get("20").steps.get("2");
  const task=row.load(step,"20","2");await row.load(step,"20","2");assert.equal(calls.length,1);
  view.toggle(key);assert.equal(calls[0].options.signal.aborted,true);assert.match(step.log.textContent,/interrupted/);
  resolve({ok:true,status:200,json:async()=>({status:"ok",scope:"job",lines:["FAIL: late"]})});await task;
  assert.match(step.log.textContent,/interrupted/);assert.ok(!step.log.textContent.includes("late"));
});
test("changed step conclusion clears obsolete excerpt and returns disappearing control focus to run", () => {
  const parent=dom(),data=fixture(),view=new CI.CIView(parent);
  view.update(CI.project(envelope(data),null,1001));const key=data.runs[0].key;view.toggle(key);
  const row=view.rows.get(key),step=row.jobs.get("20").steps.get("2");
  step.log.hidden=false;step.log.textContent="FAIL: previous observation";step.button.focus();
  data.runs[0].jobs[0].steps[0].status="in_progress";data.runs[0].jobs[0].steps[0].conclusion=null;
  view.update(CI.project(envelope(data),null,1002));
  assert.equal(step.log.hidden,true);assert.equal(step.log.textContent,"");assert.equal(document.activeElement,row.button);
  assert.equal(row.body.hidden,false);
});
test("dynamic names and diagnostics use literal text; CSS includes measured motion and settled reduction", () => {
  const parent=dom(), data=fixture();data.runs[0].name="<img onerror=evil()>";
  const view=new CI.CIView(parent);view.update(CI.project(envelope(data),null,1001));assert.ok(parent.textContent.includes("<img onerror=evil()>"));
  const source=fs.readFileSync(require.resolve("../mergepath/cockpit/assets/ci.js"),"utf8");assert.ok(!source.includes("innerHTML"));assert.ok(!source.includes("new EventSource"));assert.ok(!source.includes("setInterval"));
  const css=fs.readFileSync(require.resolve("../mergepath/cockpit/assets/ci.css"),"utf8");assert.match(css,/1\.2s ease-in-out infinite/);assert.match(css,/animation:enter var\(--t-med\) var\(--ease\)/);assert.match(css,/animation:none!important;transform:none!important/);assert.match(css,/prefers-reduced-motion:reduce/);
});

test("never-observed selected repository withdraws coverage but successful empty observation counts", () => {
  const data=fixture(); data.runs=[]; data.groups=[];
  data.repositories.forEach(row=>{row.observed_at=null;row.stale=true;});
  assert.equal(CI.project(envelope(data),null,1001).hasObservations,false);
  data.repositories[0].observed_at=1000; data.repositories[0].stale=false;
  assert.equal(CI.project(envelope(data),data.repositories[0].repo,1001).hasObservations,true);
});

test("a completed success off every open HEAD carries not-fetched job scope, validates only with empty jobs and says so when disclosed", () => {
  const data = fixture(), base = data.runs[0];
  const row = {...structuredClone(base), id: "11", key: `${base.repo}:11:${base.pr ?? "none"}`, status: "completed", conclusion: "success", current_head: false,
    jobs: [], jobs_scope: "not-fetched", checks: [], diagnostics: [], actionable: false, superseded: false, severity: null, reason: null, check_evidence_unknown: false, rerun_command: null};
  data.runs.push(row);
  assert.doesNotThrow(() => CI.validate(data));
  assert.throws(() => CI.validate({...data, runs: [base, {...row, jobs: structuredClone(base.jobs)}]}), /invalid_ci_observation/);
  assert.throws(() => CI.validate({...data, runs: [base, {...row, jobs_scope: "none"}]}), /invalid_ci_observation/);
  assert.throws(() => CI.validate({...data, runs: [base, {...base, jobs_scope: "not-fetched"}]}), /invalid_ci_observation/);
  const parent = dom(), view = new CI.CIView(parent, () => assert.fail("unexpected fetch"));
  view.update(CI.project(envelope(data), null, 1001));
  const run = view.rows.get(row.key);
  assert.equal(run.empty.textContent, "Job detail is read for live runs, failed runs and open-PR heads; this completed success keeps its workflow result only.");
  const cancelled = {...row, id: "12", key: `${base.repo}:12:${base.pr ?? "none"}`, conclusion: "cancelled"}; data.runs.push(cancelled); view.update(CI.project(envelope(data), null, 1002));
  assert.equal(view.rows.get(cancelled.key).empty.textContent, "Job detail is read for live runs, failed runs and open-PR heads; this completed run keeps its workflow result only.");
  assert.equal(run.duration.textContent, "1m 0s");
  assert.equal(run.badge.textContent, "Passed · old HEAD");
  assert.match(view.notes.textContent, /Job detail for live, failed and open-HEAD runs/);
});

test("completed runs off open heads sit behind a counted history disclosure while attention rows stay in the main list", () => {
  const data = fixture(), base = data.runs[0];
  const history = {...structuredClone(base), id: "11", key: `${base.repo}:11:${base.pr ?? "none"}`, status: "completed", conclusion: "success", current_head: false,
    jobs: [], jobs_scope: "not-fetched", checks: [], diagnostics: [], actionable: false, superseded: false, severity: null, reason: null, check_evidence_unknown: false, rerun_command: null};
  data.runs.push(history);
  const parent = dom(), view = new CI.CIView(parent, () => assert.fail("unexpected fetch"));
  view.update(CI.project(envelope(data), null, 1001));
  assert.deepEqual(view.list.children, [view.rows.get(base.key).root]);
  assert.deepEqual(view.historyList.children, [view.rows.get(history.key).root]);
  assert.equal(view.history.hidden, false); assert.equal(view.historyList.hidden, true);
  assert.equal(view.historyToggle.textContent, "1 completed run off open heads · show"); assert.equal(view.historyToggle.attrs["aria-expanded"], "false");
  view.historyOpen = true; view.discloseHistory();
  assert.equal(view.historyList.hidden, false); assert.equal(view.historyToggle.attrs["aria-expanded"], "true");
  // A run that turns live moves back to the main list and keeps its node; an empty history hides its disclosure.
  const node = view.rows.get(history.key).root; history.status = "in_progress"; history.conclusion = null; history.jobs_scope = "all-attempts";
  view.update(CI.project(envelope(data), null, 1002));
  assert.equal(view.rows.get(history.key).root, node); assert.equal(node.parentNode, view.list); assert.equal(view.list.children.length, 2);
  assert.equal(view.historyList.children.length, 0); assert.equal(view.history.hidden, true);
  assert.equal(CI.attention({status: "completed", conclusion: "failure", current_head: null, actionable: false}), true);
  assert.equal(CI.attention({status: "completed", conclusion: "cancelled", current_head: false, actionable: false}), false);
});

test("focus on the history toggle moves to the summary when the last history row leaves", () => {
  const data = fixture(), base = data.runs[0];
  const done = {...structuredClone(base), id: "13", key: `${base.repo}:13:${base.pr ?? "none"}`, status: "completed", conclusion: "success", current_head: false,
    jobs: [], jobs_scope: "not-fetched", checks: [], diagnostics: [], actionable: false, superseded: false, severity: null, reason: null, check_evidence_unknown: false, rerun_command: null};
  data.runs.push(done);
  const parent = dom(), view = new CI.CIView(parent, () => assert.fail("unexpected fetch"));
  view.update(CI.project(envelope(data), null, 1001));
  view.historyToggle.focus(); assert.equal(document.activeElement, view.historyToggle);
  done.current_head = true; view.update(CI.project(envelope(data), null, 1002));
  assert.equal(view.history.hidden, true); assert.equal(document.activeElement, view.summary);
  data.runs.pop(); done.current_head = false; data.runs.push(done); view.update(CI.project(envelope(data), null, 1003));
  view.historyToggle.focus(); data.runs.pop(); view.update(CI.project(envelope(data), null, 1004));
  assert.equal(view.history.hidden, true); assert.equal(document.activeElement, view.summary, "a removed last row also releases the toggle");
});

test("a focused run that moves into collapsed history reveals it and keeps keyboard focus", () => {
  const data = fixture(), base = data.runs[0];
  const done = {...structuredClone(base), id: "12", key: `${base.repo}:12:${base.pr ?? "none"}`, status: "completed", conclusion: "success", current_head: true,
    jobs: [], jobs_scope: "all-attempts", checks: [], diagnostics: [], actionable: false, superseded: false, severity: null, reason: null, check_evidence_unknown: false, rerun_command: null};
  data.runs.push(done);
  const parent = dom(), view = new CI.CIView(parent, () => assert.fail("unexpected fetch"));
  view.update(CI.project(envelope(data), null, 1001));
  const button = view.rows.get(done.key).button;
  assert.equal(button.parentNode && view.list.contains(button), true); button.focus(); assert.equal(document.activeElement, button);
  assert.equal(view.historyOpen, false);
  // A new PR HEAD makes the completed success history while its control holds focus.
  done.current_head = false;
  view.update(CI.project(envelope(data), null, 1002));
  assert.equal(view.historyList.contains(button), true);
  assert.equal(view.historyOpen, true); assert.equal(view.historyList.hidden, false); assert.equal(view.historyToggle.attrs["aria-expanded"], "true");
  assert.equal(document.activeElement, button);
  // Without focus inside it, a run moving into history leaves the disclosure as the operator set it.
  view.historyOpen = false; view.discloseHistory(); done.current_head = true; view.update(CI.project(envelope(data), null, 1003));
  view.summary.focus(); done.current_head = false; view.update(CI.project(envelope(data), null, 1004));
  assert.equal(view.historyOpen, false); assert.equal(view.historyList.hidden, true); assert.equal(document.activeElement, view.summary);
});

test("an orphaned queued run off open heads is history, not a running run, and says why", () => {
  const data = pythonFixture("orphan:False"), row = data.runs[0];
  assert.equal(row.orphaned, true); assert.equal(row.status, "queued");
  const model = CI.project(envelope(data), null, 1791300000);
  assert.match(model.label, /^0 running/); assert.equal(model.state, "idle"); assert.equal(model.hazards.length, 0);
  assert.deepEqual(CI.runTone(row), {state: "idle", label: "Orphaned"}); assert.equal(CI.attention(row), false);
  const parent = dom(), view = new CI.CIView(parent, () => assert.fail("unexpected fetch"));
  view.update(model);
  const run = view.rows.get(row.key);
  assert.equal(run.root.parentNode, view.historyList);
  assert.equal(view.historyToggle.textContent, "1 orphaned queued run · show");
  assert.equal(run.flag.hidden, false); assert.match(run.reason.textContent, /never started/);
  assert.equal(run.duration.textContent, "queued 7h 0m");
  // A rerun's queue age is its current attempt's: run_started_at resets, created_at does not.
  const rerun = structuredClone(data); rerun.runs[0].created_at -= 30 * 86400;
  view.update(CI.project(envelope(rerun), null, 1791300000)); assert.equal(run.duration.textContent, "queued 7h 0m");
  rerun.runs[0].started_at = null; view.update(CI.project(envelope(rerun), null, 1791300000)); assert.equal(run.duration.textContent, "queued 727h 0m");
  // Beside completed history both counts are named.
  const done = {...structuredClone(row), id: "11", key: `${row.repo}:11:none`, status: "completed", conclusion: "success", orphaned: false, reason: null};
  data.runs.push(done); view.update(CI.project(envelope(data), null, 1791300000));
  assert.equal(view.historyToggle.textContent, "1 completed run off open heads · 1 orphaned queued run · show");
});

test("an orphaned run on an open HEAD stays visible and never establishes current CI success", () => {
  const data = pythonFixture("orphan:True"), row = data.runs[0];
  assert.equal(row.orphaned, true); assert.equal(row.current_head, true);
  const model = CI.project(envelope(data), null, 1791300000);
  assert.equal(CI.attention(row), true); assert.match(model.label, /^0 running/);
  assert.match(model.label, /current CI success not established/);
});

test("an orphaned rerun keeps an earlier attempt's current failure as a hazard; superseded history yields to Orphaned", () => {
  const data = pythonFixture("orphan:actionable"), row = data.runs[0];
  assert.equal(row.orphaned, true); assert.equal(row.actionable, true);
  const model = CI.project(envelope(data), null, 1791300000);
  assert.equal(model.hazards.length, 1); assert.equal(CI.runTone(row).state, row.severity);
  // A superseded orphan on the current HEAD never ran, so it cannot let the panel claim clearance.
  const current = pythonFixture("orphan:True"); current.runs[0].superseded = true;
  assert.match(CI.project(envelope(current), null, 1791300000).label, /current CI success not established/);
  const history = pythonFixture("orphan:False"); history.runs[0].superseded = true;
  assert.doesNotThrow(() => CI.validate(history)); assert.deepEqual(CI.runTone(history.runs[0]), {state: "idle", label: "Orphaned"});
});

test("orphaned is accepted only on a queued workflow run with no jobs in its current attempt", () => {
  const ok = pythonFixture("orphan:False"); assert.doesNotThrow(() => CI.validate(ok));
  const rerun = pythonFixture("orphan:False"); rerun.runs[0].attempt = "2";
  rerun.runs[0].jobs = [{id: "1", name: "x", status: "completed", conclusion: "success", started_at: null, completed_at: null, steps: [], check_id: null, attempt: "1"}];
  assert.doesNotThrow(() => CI.validate(rerun), "earlier attempts' jobs may sit beside an orphaned current attempt");
  rerun.runs[0].jobs[0].attempt = null; assert.throws(() => CI.validate(rerun), "a job of unknown attempt counts as present");
  for (const mutate of [row => {row.status = "in_progress";}, row => {row.orphaned = "yes";},
    row => {row.jobs_scope = "not-fetched";}, row => {row.jobs = [{id: "1", name: "x", status: "queued", conclusion: null, started_at: null, completed_at: null, steps: [], check_id: null, attempt: "1"}];}]) {
    const data = pythonFixture("orphan:False"); mutate(data.runs[0]);
    assert.throws(() => CI.validate(data));
  }
});
