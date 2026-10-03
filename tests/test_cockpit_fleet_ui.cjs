/* Hermetic Fleet projection and persistent DOM tests. Expected <3s; bound30s. */
'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {spawnSync}=require('node:child_process'),path=require('node:path');
const root=path.resolve(__dirname,'..'),clone=x=>structuredClone(x);
const fixture=spawnSync('python3',['-B','-c',`import json,runpy,time
n=runpy.run_path('tests/test_cockpit_fleet.py')
t=n['SourceTests']();t.setUp()
try:
 p=t.provider();one=n['record'](status='drift');one['open_sync_prs']=[{'number':88,'branch':'mergepath-sync/x','state':'BEHIND','lifecycle_state':'OPEN','draft':False}]
 one['paths'] += [dict(one['paths'][0],path='AGENTS.md',**{'class':'canonical'}),dict(one['paths'][0],path='ci.yml',**{'class':'templated','direction':'re-render differs'})]
 complete=t.fetch(p,[one,n['record'](n['INVENTORY'][2])],1)
 partial=t.fetch(p,[n['record'](status='fetch-error',stamp='2026-10-03T19:01:00Z'),n['record'](n['INVENTORY'][2],stamp='2026-10-03T19:01:00Z')],3)
 print(json.dumps({'complete':complete,'partial':partial}))
finally:t.tearDown()`],{cwd:root,encoding:'utf8',timeout:5000});
assert.equal(fixture.status,0,fixture.stderr);const fixtures=JSON.parse(fixture.stdout);
class Node {
  constructor(tag='text') {this.tagName=tag;this.children=[];this.parentNode=null;this.style={};this.dataset={};this.attributes={};this.hidden=false;this._text='';this.className='';this.handlers={};
    this.classList={contains:n=>this.className.split(/\s+/).includes(n),add:(...names)=>{this.className=[...new Set([...this.className.split(/\s+/).filter(Boolean),...names])].join(' ');},remove:(...names)=>{this.className=this.className.split(/\s+/).filter(n=>!names.includes(n)).join(' ');},toggle:(n,on)=>{on=on??!this.classList.contains(n);this.classList[on?'add':'remove'](n);return on;}};}
  append(...nodes) {for(const n of nodes){n.remove();n.parentNode=this;this.children.push(n);}}
  replaceChildren(...nodes) {for(const n of [...this.children])n.remove();this._text='';this.append(...nodes);}
  insertBefore(n,next) {n.remove();n.parentNode=this;const i=this.children.indexOf(next);this.children.splice(i<0?this.children.length:i,0,n);}
  remove() {if(this.parentNode){const a=this.parentNode.children;a.splice(a.indexOf(this),1);this.parentNode=null;}}
  get nextSibling() {return this.parentNode?.children[this.parentNode.children.indexOf(this)+1]??null;}
  get isConnected() {return this===document.body||!!this.parentNode?.isConnected;}
  contains(n) {return n===this||this.children.some(child=>child.contains(n));}
  set textContent(v) {this.replaceChildren();this._text=String(v);}
  get textContent() {return this._text+this.children.map(n=>n.textContent).join('');}
  setAttribute(k,v) {this.attributes[k]=String(v);}
  getAttribute(k) {return this.attributes[k]??null;}
  removeAttribute(k) {delete this.attributes[k];if(k==='href')delete this.href;}
  addEventListener(k,fn) {this.handlers[k]=fn;}
  focus() {document.activeElement=this;}
}
global.document={createElement:t=>new Node(t),createTextNode:t=>{const n=new Node();n.textContent=t;return n;},activeElement:null};
document.body=new Node('body');
const Fleet=require('../mergepath/cockpit/assets/fleet.js');
const Rows=require('../mergepath/cockpit/assets/pr_rows.js');
const now=1791054060;
function parent(){const p=new Node('main');document.body.append(p);return p;}
function envelope(data=fixtures.complete){return {data:clone(data),observed_at:now,attempted_at:now,in_flight:false,stale:false,error:null,retry_at:null};}
function model(e=envelope(),selected=null,context={}){return Fleet.project(e,selected,now,context);}

test('cold initial progress never claims observations, coverage, counts or hazards',()=>{
 const e={data:null,observed_at:null,attempted_at:null,in_flight:false,stale:true,error:'unavailable',retry_at:null};
 let m=model(e);assert.equal(m.state,'idle');assert.equal(m.label,'Awaiting first audit');assert.equal(m.count,null);assert.equal(m.hasObservations,false);assert.equal(m.coverageValid,false);assert.deepEqual(m.hazards,[]);
 e.in_flight=true;e.attempted_at=now-3;m=model(e);assert.equal(m.state,'running');assert.equal(m.audit.elapsed,3);assert.equal(m.hasObservations,false);
 e.in_flight=false;e.error='source_failed';e.retry_at=now+1800;m=model(e);assert.match(m.label,/unavailable/);
 e.data={};assert.throws(()=>model(e),/invalid/);
});
test('healthy drift remains ordinary audit work; exit3 retains separate last good times and current failure',()=>{
 const m=model();assert.equal(m.state,'clear');assert.equal(m.count,2);assert.equal(m.coverageValid,true);assert.deepEqual(m.hazards,[]);assert.equal(m.rows[0].tone,'bump');
 const p=model(envelope(fixtures.partial));assert.equal(p.state,'bump');assert.equal(p.coverageValid,false);assert.equal(p.rows[0].record.status,'drift');assert.equal(p.rows[0].status,'fetch-error');assert.ok(p.rows[0].attempted_at>p.rows[0].observed_at);assert.equal(p.rows[0].syncPRs[0].stale,true);assert.equal(p.hazards.length,1);assert.equal(p.hazards[0].state,'bump');
 assert.equal(model(envelope(fixtures.partial),'fixture/two').coverageValid,true);assert.equal(model(envelope(),'fixture/hub').hasObservations,false);assert.throws(()=>model(envelope(),'foreign/repo'),/filter/);
});
test('malformed partial records, identities, times, baselines, provenance and coherent exits withdraw',()=>{
 for(const mutate of [e=>e.data.repositories.push(clone(e.data.repositories[0])),e=>e.data.repositories[0].attempt.repo='foreign/repo',e=>e.data.audit_exit=0,e=>e.data.complete=false,e=>e.data.repositories[0].attempted_at=now+1,e=>e.data.repositories[0].record.baseline_info.kind='local-tree',e=>e.data.repositories[0].attempt.paths[0].provenance={},e=>e.data.repositories[0].record.paths[0].direction='invented',e=>e.data.repositories[0].sync_pr_rows=[],e=>e.data.repositories[0].attempt.audited_at='2026-02-31T19:00:00Z']){
  const e=envelope();mutate(e);assert.throws(()=>model(e),/invalid|incomplete/);
 }
});
test('current PR context joins by repo and number, keeps independent freshness, and emits no duplicate PR hazard',()=>{
 const e=envelope(fixtures.partial),fallback=e.data.repositories[0].sync_pr_rows[0],current=clone(fallback);
 current.partial=false;current.head='c'.repeat(40);current.title='current';current.state='boulder';current.stale=false;
 const prs={observed_at:now,stale:false,data:{schema:'cockpit-prs/v1',repositories:[{repo:'fixture/one',stale:false,rows:[current]}]}};
 assert.equal(Rows.validRow(current),true);const before=JSON.stringify(prs),m=model(e,null,{prs});
 assert.equal(m.rows[0].membershipStale,true);assert.equal(m.rows[0].syncPRs[0].stale,false);assert.equal(m.rows[0].syncPRs[0].head,current.head);assert.equal(m.hazards.length,1);assert.equal(JSON.stringify(prs),before);
 prs.stale=true;assert.equal(model(e,null,{prs}).rows[0].syncPRs[0].stale,true);
 prs.data.repositories[0].rows[0].repo='foreign/repo';assert.equal(model(e,null,{prs}).rows[0].syncPRs[0].partial,true);
});
test('persistent rows/disclosures/focus survive progress, filtering, stale failure and shell replacement',()=>{
 const p=parent(),v=Fleet.render(p,model(),{refresh:async()=>{}}),row=v.views.get('fixture/one'),button=row.pathButton,pathNode=row.pathNodes.get('scripts/a.sh').li;
 button.handlers.click();row.prButton.handlers.click();button.focus();assert.equal(row.paths.hidden,false);assert.equal(row.prs.hidden,false);
 const e=envelope();e.in_flight=true;e.attempted_at=now-20;Fleet.render(p,model(e));assert.equal(v.banner.hidden,false);assert.match(v.progressText.textContent,/20s elapsed/);assert.match(v.progressText.textContent,/indeterminate/);assert.equal(v.refreshButton.disabled,true);assert.equal(v.views.get('fixture/one'),row);
 Fleet.render(p,model(envelope(fixtures.partial),'fixture/two'));assert.equal(row.node.hidden,true);assert.equal(row.pathNodes.get('scripts/a.sh').li,pathNode);assert.equal(row.paths.hidden,false);assert.match(row.reason.textContent,/last good audit kept/);assert.match(row.prNote.textContent,/current lookup unavailable/);
 p.replaceChildren(new Node('placeholder'));assert.equal(row.node.isConnected,false);Fleet.render(p,model());assert.equal(v.views.get('fixture/one'),row);assert.equal(row.node.isConnected,true);assert.equal(row.pathButton.getAttribute('aria-expanded'),'true');assert.equal(row.prButton.getAttribute('aria-expanded'),'true');assert.equal(document.activeElement,button);assert.equal(v.banner.hidden,true);
 const prView=[...row.prList.views.values()][0];assert.match(prView.full.id,/^fleet-budget-fixture%2Fone%23/);assert.equal(prView.button.getAttribute('aria-controls'),prView.full.id);assert.equal(v.syncAll.disabled,true);assert.equal(row.sync.disabled,true);
});
test('dynamic path text is literal and fallback PR enrichment stays unknown',()=>{
 const e=envelope();e.data.repositories[0].record.paths[0].override_reason='<img onerror=bad>';e.data.repositories[0].attempt.paths[0].override_reason='<img onerror=bad>';
 const v=Fleet.render(parent(),model(e)),r=v.views.get('fixture/one');assert.equal(r.pathNodes.get('scripts/a.sh').detail.children.length,0);assert.match(r.pathList.textContent,/<img onerror=bad>/);
 assert.match(r.prNote.textContent,/enrichment unavailable/);const pr=[...r.prList.views.values()][0];assert.match(pr.meta.textContent,/HEAD unknown/);assert.ok(pr.budgets.every(b=>b.fill.hidden));
});
test('disclosure ID references are whitespace-free and preserve distinct identities',()=>{
 const e=envelope(),names=['one two','one-two'];
 for(let i=0;i<2;i++){
  const row=e.data.repositories[i];row.name=names[i];row.record.name=names[i];row.attempt.name=names[i];
 }
 const v=Fleet.render(parent(),model(e)),ids=[];
 for(const row of v.views.values()){
  for(const [node,button] of [[row.paths,row.pathButton],[row.prs,row.prButton],...[...row.prList.views.values()].map(pr=>[pr.full,pr.button])]){
   assert.doesNotMatch(node.id,/\s/);assert.equal(button.getAttribute('aria-controls'),node.id);ids.push(node.id);
  }
 }
 assert.equal(new Set(ids).size,ids.length);
 const first=v.views.get('fixture/one'),pathId=first.paths.id,prId=first.prs.id;
 first.pathButton.handlers.click();first.pathButton.focus();Fleet.render(v.parent,model(e));
 assert.equal(first.paths.id,pathId);assert.equal(first.prs.id,prId);assert.equal(first.paths.hidden,false);assert.equal(document.activeElement,first.pathButton);
});
test('refresh callback coalesces locally, reports failure, and honors source backoff',async()=>{
 let calls=0,done;const v=Fleet.render(parent(),model(),{refresh:()=>{calls++;return new Promise(resolve=>done=resolve);}});
 const first=v.requestRefresh();await v.requestRefresh();assert.equal(calls,1);assert.equal(v.feedback.hidden,false);assert.equal(v.refreshButton.disabled,true);done();await first;assert.equal(v.refreshButton.disabled,false);
 const e=envelope();e.error='source_failed';e.retry_at=now+1800;Fleet.render(v.parent,model(e));await v.requestRefresh();assert.equal(calls,1);assert.equal(v.refreshButton.disabled,true);
 Fleet.render(v.parent,model());assert.equal(v.feedback.hidden,true);v.refresh=async()=>{throw new Error('fixture');};await v.requestRefresh();assert.match(v.feedback.textContent,/no audit result changed/);
});
test('Fleet installs narrow pending seam and keeps networking/motion in shared contracts',()=>{
 let args;Fleet.install({registerPanel:(...a)=>args=a},{refresh:async()=>{}});assert.equal(args[0],'fleet');assert.deepEqual(args[4],{renderPending:true});
 const js=fs.readFileSync(path.join(root,'mergepath/cockpit/assets/fleet.js'),'utf8'),css=fs.readFileSync(path.join(root,'mergepath/cockpit/assets/fleet.css'),'utf8');assert.doesNotMatch(js,/\bfetch\s*\(|new EventSource|setInterval|innerHTML/);assert.match(css,/prefers-reduced-motion:reduce/);assert.match(css,/\.ck\.rm/);assert.match(css,/var\(--t-med\)/);assert.match(css,/overflow-x:auto/);
});
