"use strict";
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs"), cp = require("node:child_process");
const CI = require("../mergepath/cockpit/assets/ci.js"), C = require("../mergepath/cockpit/assets/components.js");
const pythonFixture = expression => JSON.parse(cp.execFileSync("python3", ["-c", `import sys,json;sys.path.insert(0,'tests');import test_cockpit_ci as ci;print(json.dumps(${expression}))`], {cwd: require("node:path").resolve(__dirname,".."), timeout: 2000}));
const fixture = () => pythonFixture("ci.model()");
const envelope = data => ({data, observed_at: 1000, stale: false});
for (const field of ["name", "diagnostic", "excerpt"]) test(`Python Unicode ${field} limit round-trips through browser validation`, () => {
  const {data, excerpt} = pythonFixture("ci.unicode_model_and_excerpt()");
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
  const {data} = pythonFixture(`ci.unmatched_checks_fixture(${withActions ? "True" : "False"})`);
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
  for (const app of ["None", "{'id':1,'slug':'github-actions'}"]) {
    const {data} = pythonFixture(`ci.unmatched_checks_fixture(checks=[ci.raw_check(conclusion='success'), {**ci.raw_check(200,suite=999), 'app':${app}}, {**ci.raw_check(201,'success',ci.LATER,app=77), 'app':{'id':77,'slug':'external-app'}}])`);
    const model = CI.project(envelope(data), null, 1001);
    assert.equal(model.state, "bump"); assert.equal(model.hazards.length, 1);
    assert.equal(data.check_rows[0].checks[0].superseded_by, null);
  }
});
test("Check-only pending or unavailable evidence cannot project a clear state", () => {
  for (const [status, expected] of [["queued","running"],["in_progress","running"],["completed","idle"],["unknown","idle"]]) {
    const {data} = pythonFixture(`ci.unmatched_checks_fixture(checks=[ci.raw_check(conclusion='success'), {**ci.raw_check(200), 'status':'${status}', 'conclusion':None}])`);
    assert.equal(CI.project(envelope(data), null, 1001).state, expected);
  }
  const {data} = pythonFixture("ci.unmatched_checks_fixture(head=None)");
  assert.equal(CI.project(envelope(data), null, 1001).state, "idle");
  assert.equal(CI.project(envelope(data), null, 1001).hazards.length, 0);
});
for (const withActions of [true, false]) for (const status of ["queued", "in_progress"]) test(`Superseded external failure retains independent ${status} check tone; Actions=${withActions}`, () => {
  const {data, hot} = pythonFixture(`ci.unmatched_checks_fixture(${withActions ? "True" : "False"}, checks=${withActions ? "[ci.raw_check(conclusion='success')] + " : ""}[{**ci.raw_check(200, app=77, name='external gate'), 'app':{'id':77,'slug':'external-app'}}, {**ci.raw_check(201, 'success', ci.LATER, app=77, name='external gate'), 'app':{'id':77,'slug':'external-app'}}, {**ci.raw_check(202, None, ci.LATER, app=77, name='independent check'), 'status':'${status}', 'completed_at':None, 'app':{'id':77,'slug':'external-app'}}])`);
  const model = CI.project(envelope(data), null, 1001), row = data.check_rows[0];
  assert.equal(hot, true); assert.equal(row.status, status); assert.equal(row.superseded, true);
  assert.equal(row.checks[0].superseded_by, "201"); assert.equal(row.checks[2].status, status);
  assert.equal(model.state, "running"); assert.equal(model.hazards.length, 0);
  assert.deepEqual(CI.runTone(row), {state:"running", label:status === "in_progress" ? "Running" : "Queued"});
});
test("Check rows reject fabricated Actions identities, jobs and commands", () => {
  const {data} = pythonFixture("ci.unmatched_checks_fixture(False)");
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
  remove(){if(this.parentNode){const p=this.parentNode;p.children.splice(p.children.indexOf(this),1);this.parentNode=null;}}
  setAttribute(key,value){this.attrs[key]=value;}
  addEventListener(name,fn){this.listeners[name]=fn;}
  contains(node){return node===this||this.children.some(c=>c.contains(node));}
  focus(){document.activeElement=this;}
}
function dom(){global.document={createElement:tag=>new Node(tag),activeElement:null};return new Node("div");}
test("Unmatched checks render literal names, producer and diagnostic without Actions logs or rerun", () => {
  const {data} = pythonFixture("ci.unmatched_checks_fixture(False)");
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
  assert.equal(parent.children.length,4);
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
