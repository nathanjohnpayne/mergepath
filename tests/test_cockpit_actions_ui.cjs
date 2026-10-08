"use strict";
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {project,BudgetView,render,install,tokenSummary,tokenBoundaries} = require('../mergepath/cockpit/assets/actions.js');
const C = require('../mergepath/cockpit/assets/components.js');
const {PanelRegistry,renderPanelContent,headerBudget,boundaryCrossed}=require('../mergepath/cockpit/assets/app.js');
const now=Date.UTC(2026,9,16,12)/1000, repo='owner/mergepath';
const cycle=()=>({budget:25,cycle_start:Date.UTC(2026,9,1)/1000,cycle_end:Date.UTC(2026,10,1)/1000});
const row=(overrides={})=>({repo,available:true,stale:false,observed_at:now,installation_scan:{observed_at:now,error:null,runs:[]},queued:0,running:0,runs_last_hour:2,jammed:false,jam_since:null,estimated_requests:null,measurement:null,installation_runs:[],...overrides});
const data=(overrides={})=>({schema:'actions-budget/v1',billing:{available:false,stale:true,observed_at:null},robot:{available:false,stale:true,observed_at:null},configuration:{budget:null,cycle_start:null,cycle_end:null},repositories:[row()],...overrides});
const model=(d=data(),stale=false,selected=null,t=now)=>project({data:d,stale,observed_at:now},selected,t);
const measured=()=>({requests_per_run:400,observed_at:now,provenance:'measured local counter'});

test('four cards keep denied billing and absent robot separate from queue observations',()=>{
 const m=model();assert.equal(m.cards.length,4);assert.equal(m.cards[3].state,'clear');assert.equal(m.cards[0].available,false);
 assert.equal(m.cards[2].available,false);assert.equal(m.state,'idle');assert.equal(m.coverageValid,false);assert.equal(m.hasObservations,true);
 assert.match(m.label,/unavailable/);assert.match(m.cards[1].rows[0].value,/unavailable/);assert.match(m.cards[1].denominator,/1,000.*per repository/);
});
test('estimates label provenance and use 70%/100% thresholds',()=>{
 for(const [amount,state] of [[699,'clear'],[700,'bump'],[1000,'boulder']]) {
  const m=model(data({repositories:[row({estimated_requests:amount,measurement:{...measured(),requests_per_run:amount/2}})]}));
  assert.equal(m.cards[1].state,state);assert.match(m.cards[1].rows[0].value,/^est\./);
  assert.equal(m.hazards.filter(h=>h.source==='budget').length,state==='clear'?0:1);
  if(state!=='clear')assert.equal(m.hazards[0].timing.kind,'unknown');
 }
 assert.match(model(data({repositories:[row({estimated_requests:800,measurement:measured()})]}),false,null,now+3601).cards[1].rows[0].value,/unavailable/);
});
test('measurement provenance uses the backend Unicode codepoint boundary',()=>{
 for(const length of [121,240,241]) {
  const provenance='\u{1f600}'.repeat(length);
  const m=model(data({repositories:[row({estimated_requests:800,measurement:{...measured(),provenance}})]}));
  const token=m.cards[1];
  if(length<=240) {
   assert.equal(token.available,true);assert.equal(token.state,'bump');
   assert.match(token.rows[0].value,/^est\./);assert.ok(token.rows[0].detail.includes(provenance));
   assert.equal(m.hazards.filter(h=>h.id.startsWith('actions-token-')).length,1);
  } else {
   assert.equal(token.available,false);assert.equal(token.state,'idle');
   assert.match(token.rows[0].value,/unavailable/);
   assert.equal(m.hazards.filter(h=>h.id.startsWith('actions-token-')).length,0);
  }
 }
});
test('explicit installation run overrides estimate and retains last-known hard signal stale',()=>{
 const d=data({repositories:[row({installation_runs:['41'],estimated_requests:20,measurement:{...measured(),requests_per_run:10}})]});
 for(const stale of [false,true]) {
 const m=model(d,stale);assert.equal(m.state,'boulder');assert.equal(m.cards[1].rows[0].value,'exhausted');
 assert.equal(m.hazards[0].timing.kind,'now');assert.match(m.hazards[0].detail,/run 41/);assert.equal(m.hazards[0].stale,stale);assert.equal(m.hasObservations,true);assert.equal(m.stale,stale);
 }
});
test('queue warning count is independent of generic meter percentage; jam needs proven interval',()=>{
 for(const [queued,running,jammed,since,state] of [[9,1,false,null,'running'],[10,1,false,null,'bump'],[40,1,true,now-1800,'bump'],[40,1,true,now-1801,'boulder'],[39,1,true,now-1801,'bump'],[40,2,true,now-1801,'bump']]) {
 const m=model(data({repositories:[row({queued,running,jammed,jam_since:since})]}));assert.equal(m.cards[3].state,state);
 assert.match(m.cards[3].note,/runner capacity.*unavailable/i);
 }
});
test('robot primary headroom never clears observed secondary throttle even after reset',()=>{
 const robot={available:true,stale:false,configured_identity:'nathanpayne-robot',observed_at:now,reset:now+60,limit:5000,remaining:4900,secondary_limited:true};
 const m=model(data({robot}));assert.equal(m.cards[2].state,'boulder');assert.equal(m.cards[2].percent,2);assert.match(m.cards[2].note,/Secondary/);
 const expired=model(data({robot}),false,null,now+61);assert.equal(expired.cards[2].state,'boulder');assert.equal(expired.cards[2].percent,null);
 assert.match(expired.cards[2].value,/unknown/);
});
test('spend sums reported net, projection gets explicit cycle-end timing and right anchor',()=>{
 const billing={available:true,stale:false,observed_at:now,net_amount:15,year:2026,month:10,repositories:[{repo,net_amount:15}]};
 const m=model(data({billing,configuration:cycle()}));
 assert.equal(m.cards[0].value,'$15.00 reported');assert.equal(m.cards[0].percent,60);assert.equal(m.cards[0].projection.value,30);
 assert.equal(m.cards[0].state,'boulder');assert.equal(m.hazards[0].timing.at,cycle().cycle_end);
 const filtered=model(data({billing,configuration:cycle()}),false,repo);
 assert.equal(filtered.cards[0].projection,null);assert.match(filtered.cards[0].denominator,/budget unavailable/);
 assert.equal(model(data({billing}),false,'owner/other').cards[0].value,'Repository spend unavailable');
 assert.equal(model(data({billing,configuration:{budget:25}})).cards[0].available,false);
 assert.equal(model(data({billing,configuration:{budget:25}})).cards[0].percent,null);
});
test('stale last-good billing stays visible without current projection',()=>{
 const billing={available:false,stale:true,observed_at:now-10,net_amount:15,year:2026,month:10,repositories:[{repo,net_amount:15}]};
 const m=model(data({billing,configuration:cycle()}));
 assert.match(m.cards[0].value,/last known/);assert.equal(m.cards[0].projection,null);assert.equal(m.cards[0].available,false);
});
test('repository filter keeps account robot hazards and valid shared contract',()=>{
 const m=model(data({repositories:[row({queued:10}),row({repo:'owner/other',queued:41,running:1,jammed:true,jam_since:now-2000})]}),false,repo);
 assert.equal(m.cards[3].rows.length,1);assert.equal(m.hazards.length,1);
 assert.equal(C.normalizeHazards(m.hazards,[repo,'owner/other']).diagnostics.length,0);
 assert.throws(()=>model(data({repositories:[row(),row()]})));
});
class Node {
 constructor(tag){this.tagName=tag;this.children=[];this.attributes={};this.style={};this.className='';this.textContent='';this.classList={contains:n=>this.className.split(' ').includes(n),add:n=>{this.className+=' '+n;},remove:n=>{this.className=this.className.split(' ').filter(x=>x!==n).join(' ');},toggle:(n,on)=>on?this.classList.add(n):this.classList.remove(n)};}
 append(...nodes){for(const n of nodes){if(n.parentNode)n.remove();this.children.push(n);n.parentNode=this;}}
 replaceChildren(...nodes){for(const node of this.children)node.parentNode=null;this.children=[];this.append(...nodes);}
 contains(node){return node===this||this.children.some(child=>child.contains(node));}
 replaceWith(n){const p=this.parentNode;if(p){p.children[p.children.indexOf(this)]=n;n.parentNode=p;}}
 setAttribute(k,v){this.attributes[k]=v;} removeAttribute(k){delete this.attributes[k];}
 addEventListener(){} remove(){if(this.parentNode)this.parentNode.children=this.parentNode.children.filter(n=>n!==this);this.parentNode=null;}
}
test('DOM retains meter identity across updates, literal dynamic text, caps only on threshold entry',()=>{
 const old=global.document;global.document={createElement:tag=>new Node(tag),body:new Node('body')};
 try {
 const parent=new Node('div'),view=new BudgetView(parent);
 const d=data({repositories:[row({estimated_requests:800,measurement:{...measured(),provenance:'<img onerror=bad>'}})]});
 view.update(model(d));const fill=view.cards.get('robot').meter.fill,tokenNode=view.cards.get('token').rows.get(repo).node;
 view.update(model(d));assert.equal(view.cards.get('robot').meter.fill,fill);assert.equal(view.cards.get('token').rows.get(repo).node,tokenNode);
 assert.match(view.cards.get('token').rows.get(repo).detail.textContent,/<img onerror=bad>/);
 assert.equal(parent.children.length,2);assert.equal(view.summary.textContent,model(d).label);
 const billing={available:true,stale:false,observed_at:now,net_amount:25,year:2026,month:10,repositories:[{repo,net_amount:25}]};
 view.update(model(data({billing,configuration:cycle()})));
 const cap=view.cards.get('spend').meter.cap;view.update(model(data({billing,configuration:cycle()})));assert.equal(view.cards.get('spend').meter.cap,cap);
 } finally {global.document=old;}
});
test('motion/security source reuses shared timings and adds no network loop or unsafe HTML',()=>{
 const js=fs.readFileSync(require.resolve('../mergepath/cockpit/assets/actions.js'),'utf8');
 const css=fs.readFileSync(require.resolve('../mergepath/cockpit/assets/actions.css'),'utf8');
 assert.doesNotMatch(js,/innerHTML|\bfetch\(|EventSource|setInterval/);
 assert.match(css,/width var\(--t-slow\) var\(--ease\)/);assert.match(css,/background-color var\(--t-med\)/);
 assert.match(css,/prefers-reduced-motion:reduce/);assert.match(css,/\.rm.*animation:none/);
 const calls=[];install({registerPanel:(...a)=>calls.push(a)});assert.equal(calls[0][0],'budget');assert.equal(calls[0][1],'actions');
});

test('actual renderer restores the same view after invalid projection detaches it through the shared placeholder',()=>{
 const old=global.document;global.document={createElement:tag=>new Node(tag),body:new Node('body')};
 try {
  const parent=new Node('div'), registry=new PanelRegistry();registry.register('budget','actions',project,render);
  const billing={available:true,stale:false,observed_at:now,net_amount:25,year:2026,month:10,repositories:[{repo,net_amount:25}]};
  const d=data({billing,configuration:cycle()});
  const snapshot={repositories:[{repo}],sources:{actions:{data:d,stale:false,observed_at:now}}};
  const adapter=registry.adapters.get('budget');let placeholder=null;
  let projection=registry.project(snapshot,null,now).models.budget;
  placeholder=renderPanelContent(parent,projection,adapter,placeholder);
  const summary=parent.children[0],grid=parent.children[1];
  const find=(node,predicate)=>predicate(node)?node:node.children.map(child=>find(child,predicate)).find(Boolean);
  const cap=find(grid,node=>node.className.split(' ').includes('m-cap'));
  const tokenRow=find(grid,node=>node.className.split(' ').includes('actions-row'));
  const fill=find(grid,node=>node.className.split(' ').includes('m-fill'));
  snapshot.sources.actions.data={...d,schema:'malformed'};
  projection=registry.project(snapshot,null,now).models.budget;
  assert.equal(projection.observed,false);
  placeholder=renderPanelContent(parent,projection,adapter,placeholder);
  assert.equal(parent.contains(placeholder),true);assert.equal(parent.contains(grid),false);
  assert.equal(grid.parentNode,null);assert.equal(summary.parentNode,null);
  snapshot.sources.actions.data=d;
  projection=registry.project(snapshot,null,now).models.budget;
  placeholder=renderPanelContent(parent,projection,adapter,placeholder);
  assert.equal(parent.contains(summary),true);assert.equal(parent.contains(grid),true);
  assert.equal(parent.contains(placeholder),false);assert.equal(parent.children.length,2);
  assert.equal(find(grid,node=>node.className.split(' ').includes('m-cap')),cap);assert.equal(cap.classList.contains('fresh'),false);
  assert.equal(find(grid,node=>node.className.split(' ').includes('actions-row')),tokenRow);
  assert.equal(find(grid,node=>node.className.split(' ').includes('m-fill')),fill);
  renderPanelContent(parent,projection,adapter,placeholder);
  assert.equal(parent.children[0],summary);assert.equal(parent.children[1],grid);assert.equal(parent.children.length,2);
 } finally {global.document=old;}
});
test('queue rows use the card scale from the busiest repository and keep both segment widths finite',()=>{
 const old=global.document;global.document={createElement:tag=>new Node(tag),body:new Node('body')};
 try {
  const m=model(data({repositories:[row({queued:10,running:2}),row({repo:'owner/second',queued:3,running:1})]}));
  assert.equal(m.cards[3].scale,12);
  const parent=new Node('div'),view=new BudgetView(parent);view.update(m);
  const rows=view.cards.get('queue').rows;
  for(const [name,queued,running] of [[repo,10,2],['owner/second',3,1]]) {
   const actual=rows.get(name),q=Number.parseFloat(actual.fill.style.width),r=Number.parseFloat(actual.run.style.width);
   assert.ok(Number.isFinite(q)&&Number.isFinite(r));assert.ok(Math.abs(q-queued/12*100)<1e-9);assert.ok(Math.abs(r-running/12*100)<1e-9);assert.ok(q+r<=100);
  }
 } finally {global.document=old;}
});

test('billing report identity must match the current configured UTC period before percentage or projection',()=>{
 const november=Date.UTC(2026,10,1)/1000, t=november+60;
 const billing={available:true,stale:false,observed_at:november-60,net_amount:25,year:2026,month:10,repositories:[{repo,net_amount:25}]};
 const config={budget:25,cycle_start:november,cycle_end:Date.UTC(2026,11,1)/1000};
 for(const selected of [null,repo]) {
  const m=model(data({billing,configuration:config}),false,selected,t);
  assert.equal(m.cards[0].available,false);assert.equal(m.cards[0].stale,true);
  assert.equal(m.cards[0].percent,null);assert.equal(m.cards[0].projection,null);
  assert.match(m.cards[0].value,/last known/);assert.match(m.cards[0].note,/2026-10/);
  assert.equal(m.hazards.filter(h=>h.id.startsWith('actions-spend-')).length,0);
  assert.equal(m.horizon,null);
 }
 for(const period of [{year:undefined,month:undefined},{year:2026,month:11},{year:2026,month:10.5}]) {
  const m=model(data({billing:{...billing,...period,observed_at:now},configuration:cycle()}));
  assert.equal(m.cards[0].percent,null);assert.equal(m.cards[0].projection,null);
 }
});
test('repository filtering preserves current and projected account spend hazards without giving the share a denominator',()=>{
 for(const amount of [15,25]) {
  const billing={available:true,stale:false,observed_at:now,net_amount:amount,year:2026,month:10,repositories:[{repo,net_amount:1}]};
  const d=data({billing,configuration:cycle()});
  const account=model(d),filtered=model(d,false,repo);
  const spendHazards=m=>m.hazards.filter(h=>h.id.startsWith('actions-spend-'));
  assert.deepEqual(spendHazards(filtered),spendHazards(account));
  assert.deepEqual(filtered.horizon,account.horizon);
  assert.equal(filtered.state,'boulder');assert.match(filtered.label,/at the limit/);
  assert.equal(filtered.cards[0].value,'$1.00 reported');assert.equal(filtered.cards[0].percent,null);
  assert.equal(filtered.cards[0].projection,null);assert.equal(filtered.cards[0].state,'idle');
  assert.match(filtered.cards[0].denominator,/repository share.*budget unavailable/);
  assert.ok(spendHazards(filtered).every(h=>h.repo===null));
  const stale=model(data({billing:{...billing,available:false,stale:true},configuration:cycle()}),false,repo);
  assert.equal(stale.hazards.some(h=>h.id==='actions-spend-account-at'),false);
  if(amount===25){assert.equal(stale.hazards.find(h=>h.id==='actions-spend-account-now').stale,true);assert.equal(stale.state,'boulder');}
 }
});

test('header token summary names exhausted repositories and never invents exhaustion',()=>{
 const other='owner/fiveacross';
 const exhausted=tokenSummary(model(data({repositories:[row({installation_runs:['41','42']}),row({repo:other})]})));
 assert.equal(exhausted.state,'boulder');assert.equal(exhausted.value,'Exhausted · mergepath');
 assert.match(exhausted.note,/run 41, 42 · reset unknown/);assert.deepEqual(exhausted.repos,[repo]);
 const calm=tokenSummary(model(data({repositories:[row(),row({repo:other})]})));
 assert.equal(calm.state,'clear');assert.equal(calm.value,'No exhaustion seen');assert.deepEqual(calm.repos,[]);
 const near=tokenSummary(model(data({repositories:[row({estimated_requests:800,measurement:measured()})]})));
 assert.equal(near.state,'bump');assert.equal(near.value,'Near the limit · mergepath');assert.match(near.note,/exhaustion not observed/);
 // The log scan does not depend on the CI-derived row: a stale row with a fresh scan is still covered.
 assert.equal(tokenSummary(model(data({repositories:[row({stale:true,available:false})]}))).value,'No exhaustion seen');
 assert.deepEqual(tokenSummary(undefined),{state:'idle',value:'Not observed yet',note:'Actions budget awaiting its first observation'});
});

test('repository rows stay fresh for the CI observation gap, not the old 120 seconds',()=>{
 const card=age=>model(data({repositories:[row({observed_at:now-age})]}),false,null,now).cards[1].rows[0].detail;
 assert.match(card(200),/· fresh/);assert.match(card(271),/stale/);
});
test('the header needs a fresh complete log scan of every repository before it says no exhaustion',()=>{
 const at=scan=>tokenSummary(model(data({repositories:[row(),row({repo:'owner/fiveacross',installation_scan:scan})]})));
 assert.equal(at({observed_at:now-200,error:null,runs:[]}).value,'No exhaustion seen');
 for(const scan of [{observed_at:now-200,error:null},{observed_at:now-301,error:null,runs:[]},{observed_at:now,error:'incomplete'},{observed_at:null,error:'secondary_limit'},undefined]) {
  const s=at(scan);assert.equal(s.value,'Not fully observed');assert.match(s.note,/1 of 2 repositories scanned/);
 }
 // Exhaustion is shown even when the CI-derived row is stale.
 const hot=tokenSummary(model(data({repositories:[row({stale:true,available:false,installation_runs:['9']})]})));
 assert.equal(hot.state,'boulder');assert.equal(hot.value,'Exhausted · mergepath');
});

test('an estimate at the limit stays a warning in the header and does not wait for the log scan',()=>{
 const est=(amount,scan)=>tokenSummary(model(data({repositories:[row({estimated_requests:amount,measurement:{...measured(),requests_per_run:amount/2},installation_scan:scan}),row({repo:'owner/fiveacross'})]})));
 const at=est(1000,{observed_at:now,error:null,runs:[]});
 assert.equal(at.state,'boulder');assert.equal(at.value,'At the limit by estimate · mergepath');
 assert.match(at.note,/^Estimated from measured requests per run · exhaustion not observed · 2 of 2 repositories scanned$/);
 const partial=est(800,{observed_at:now,error:'incomplete'});
 assert.equal(partial.state,'bump');assert.equal(partial.value,'Near the limit · mergepath');assert.match(partial.note,/1 of 2 repositories scanned/);
 // Observed exhaustion still outranks any estimate.
 const both=tokenSummary(model(data({repositories:[row({estimated_requests:1000,measurement:{...measured(),requests_per_run:500}}),row({repo:'owner/fiveacross',installation_runs:['7']})]})));
 assert.equal(both.value,'Exhausted · fiveacross');
});
test('the header token chip stays fleet-wide while the panels follow the repository filter',()=>{
 const registry=new PanelRegistry();registry.register('budget','actions',project,render);
 const other='owner/nathanpaynedotcom';
 const snapshot={repositories:[{repo},{repo:other}],sources:{actions:{data:data({repositories:[row(),row({repo:other,installation_runs:['9']})]}),stale:false,observed_at:now}}};
 const filtered=registry.project(snapshot,repo,now);
 assert.deepEqual(filtered.models.budget.cards.find(card=>card.id==='token').rows.map(r=>r.repo),[repo]);
 assert.equal(tokenSummary(filtered.models.budget).value,'No exhaustion seen');
 const header=tokenSummary(headerBudget(registry,snapshot,repo,filtered,now));
 assert.equal(header.state,'boulder');assert.equal(header.value,'Exhausted · nathanpaynedotcom');
 const all=registry.project(snapshot,null,now);
 assert.equal(headerBudget(registry,snapshot,null,all,now),all.models.budget);
});

test('scan-proven runs age with their own settled scan, apart from the CI row',()=>{
 const at=(scan,t=now)=>model(data({repositories:[row({installation_scan:scan})]}),false,null,t);
 const fresh=at({observed_at:now,error:null,runs:['9']});
 assert.equal(fresh.cards[1].rows[0].value,'exhausted');assert.equal(fresh.hazards[0].stale,false);assert.match(fresh.hazards[0].detail,/run 9/);
 assert.match(tokenSummary(fresh).note,/^Installation rate limit in run 9/);
 // A later failed scan retains the runs, but they are last known, never fresh.
 for(const scan of [{observed_at:now,error:'secondary_limit',runs:['9']},{observed_at:now-301,error:null,runs:['9']},{observed_at:now,error:'incomplete',runs:['9']}]) {
  const m=at(scan);assert.equal(m.state,'boulder');assert.equal(m.hazards[0].stale,true,JSON.stringify(scan));
  assert.match(m.cards[1].rows[0].detail,/run 9; reset unknown · last known/);
  const header=tokenSummary(m);assert.equal(header.value,'Exhausted · mergepath');assert.match(header.note,/^Last known: installation rate limit in run 9/);
 }
 // A fresh CI-derived run keeps the row fresh whatever the scan says; the runs are combined.
 const both=model(data({repositories:[row({installation_runs:['4'],installation_scan:{observed_at:now,error:'secondary_limit',runs:['9']}})]}));
 assert.equal(both.hazards[0].stale,false);assert.deepEqual(both.cards[1].rows[0].runs,['4','9']);
 // A malformed scan run list is neither evidence nor a settled scan.
 const bad=at({observed_at:now,error:null,runs:['x']});assert.equal(bad.cards[1].rows[0].exhausted,false);assert.equal(tokenSummary(bad).value,'Not fully observed');
});
test('the display clock re-renders when a scan or a CI row ages across its boundary',()=>{
 const d=data({repositories:[row({observed_at:now-10,installation_scan:{observed_at:now-20,error:null,runs:[]}})]});
 assert.deepEqual(tokenBoundaries(d),[now-20+300,now-10+270]);
 assert.deepEqual(tokenBoundaries(undefined),[]);
 const b=tokenBoundaries(d);
 assert.equal(boundaryCrossed(b,now,now+259),false);assert.equal(boundaryCrossed(b,now,now+261),true);
 assert.equal(boundaryCrossed(b,now+261,now+262),false);assert.equal(boundaryCrossed(b,now+279,now+281),true);
 assert.equal(boundaryCrossed(b,null,now+400),false);
 // The header flips exactly at the boundary.
 assert.equal(tokenSummary(model(d,false,null,now+280)).value,'No exhaustion seen');
 assert.equal(tokenSummary(model(d,false,null,now+281)).value,'Not fully observed');
});
test('a stale scheduler envelope is never fresh scan coverage',()=>{
 const d=data({repositories:[row(),row({repo:'owner/fiveacross'})]});
 assert.equal(tokenSummary(model(d,false)).value,'No exhaustion seen');
 const stale=tokenSummary(model(d,true));assert.equal(stale.value,'Not fully observed');assert.match(stale.note,/0 of 2 repositories scanned/);
 // Retained scan proofs in a stale envelope read last known.
 const proof=model(data({repositories:[row({installation_scan:{observed_at:now,error:null,runs:['9']}})]}),true);
 assert.equal(proof.hazards[0].stale,true);assert.match(tokenSummary(proof).note,/^Last known: installation/);
});
test('an installation scan alone is a budget observation',()=>{
 const scanOnly=row({observed_at:null,queued:null,running:null,runs_last_hour:null});
 assert.equal(model(data({repositories:[scanOnly]})).hasObservations,true);
 assert.equal(model(data({repositories:[{...scanOnly,installation_scan:{observed_at:null,error:'secondary_limit',runs:[]}}]})).hasObservations,false);
});
test('without a live stream the header never reads current',()=>{
 const calm=model(data({repositories:[row(),row({repo:'owner/fiveacross'})]}));
 assert.equal(tokenSummary(calm).value,'No exhaustion seen');
 const off=tokenSummary(calm,true);assert.equal(off.state,'idle');assert.equal(off.value,'Not fully observed');
 assert.match(off.note,/^Local stream not live · last known: Failed-job logs of the last hour · 2 of 2 repositories scanned$/);
 const hot=tokenSummary(model(data({repositories:[row({installation_runs:['9']})]})),true);
 assert.equal(hot.value,'Exhausted · mergepath');assert.match(hot.note,/^Last known: installation/);
 const near=tokenSummary(model(data({repositories:[row({estimated_requests:800,measurement:measured()})]})),true);
 assert.equal(near.value,'Near the limit · mergepath');assert.match(near.note,/^Last known: estimated/);
});
test('last-known scan proofs age the token card but not the queue card',()=>{
 const m=model(data({repositories:[row({installation_scan:{observed_at:now,error:'secondary_limit',runs:['9']}})]}));
 const token=m.cards.find(card=>card.id==='token'),queue=m.cards.find(card=>card.id==='queue');
 assert.equal(token.stale,true);assert.equal(queue.stale,false);assert.equal(m.stale,true);
 const live=model(data({repositories:[row({installation_scan:{observed_at:now,error:null,runs:['9']}})]}));
 assert.equal(live.cards.find(card=>card.id==='token').stale,false);
});
test('a fresh scan proof keeps the token card fresh beside a stale CI row',()=>{
 const m=model(data({repositories:[row({observed_at:now-400,installation_scan:{observed_at:now,error:null,runs:['9']}})]}));
 assert.equal(m.cards.find(card=>card.id==='token').stale,false);assert.equal(m.cards.find(card=>card.id==='queue').stale,true);
 assert.equal(m.hazards.find(h=>h.id.startsWith('actions-token-')).stale,false);
 assert.equal(model(data(),true).cards.find(card=>card.id==='token').stale,true);
});
test('a measured estimate expiring is a display-clock boundary',()=>{
 const d=data({repositories:[row({observed_at:now-10,installation_scan:{observed_at:now-20,error:null,runs:[]},estimated_requests:800,measurement:{...measured(),observed_at:now-3000}})]});
 assert.deepEqual(tokenBoundaries(d),[now-20+300,now-10+270,now-3000+3600]);
 assert.equal(boundaryCrossed(tokenBoundaries(d),now+599,now+601),true);
});
