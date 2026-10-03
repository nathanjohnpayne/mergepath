/* Hermetic PR projection/row lifecycle fixtures. Expected <2s; bound 30s. */
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const fixture = spawnSync('python3', ['-B', '-c', `import json,runpy
n=runpy.run_path('tests/test_cockpit_prs.py')
from mergepath.cockpit.prs import build_row,partial_row
r=build_row(n['REPO'],n['raw'](),n['receipts'](),observed_at=1000)
print(json.dumps({'row':r,'partial':partial_row(n['REPO'],'9007199254740993',merge_state='BEHIND',observed_at=1000)}))`], {cwd:root, encoding:'utf8',timeout:5000});
assert.equal(fixture.status, 0, fixture.stderr);
const fixtures = JSON.parse(fixture.stdout);
const clone = x => structuredClone(x);
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
const Rows=require('../mergepath/cockpit/assets/pr_rows.js');
const PRs=require('../mergepath/cockpit/assets/prs.js');
function parent() {const p=new Node('main');document.body.append(p);return p;}
function timers() {let serial=0,now=0;const queue=new Map();return {setTimer:(fn,delay)=>{const id=++serial;queue.set(id,{fn,at:now+delay});return id;},clearTimer:id=>queue.delete(id),advance:ms=>{now+=ms;for(const [id,t] of [...queue])if(t.at<=now){queue.delete(id);t.fn();}},queue};}
function row(number='1',repo='owner/hub') {const r=clone(fixtures.row);r.number=number;r.repo=repo;r.id=repo+'#'+number;return r;}
function terminal(r,lifecycle='MERGED') {const result=clone(r);result.lifecycle=lifecycle;result.state=lifecycle==='MERGED'?'done':'idle';result.label=lifecycle==='MERGED'?'Merged':'Closed';return result;}
function envelope(rows=[row()]) {return {stale:false,data:{schema:'cockpit-prs/v1',repositories:[{repo:'owner/hub',rows,observed_at:1000,stale:false,error:null}]}};}

test('partial sync row is standalone and exact opaque integers never become browser numbers',()=>{
  assert.equal(Rows.validRow(fixtures.partial),true);assert.equal(fixtures.partial.number,'9007199254740993');
  const view=new Rows.RowView(fixtures.partial);parent().append(view.node);
  assert.match(view.ref.textContent,/9007199254740993/);assert.match(view.meta.textContent,/HEAD unknown/);
  assert.match(view.strip.textContent,/unknown/);assert.match(Rows.spendText(fixtures.row.spend),/9007199254740993 tokens/);
  const bad=clone(fixtures.partial);bad.number=9007199254740992;assert.equal(Rows.validRow(bad),false);
  view.destroy();
});
test('projection retains partial coverage age, truthful unknown count and conservative stale',()=>{
  const e=envelope();e.data.repositories.push({repo:'owner/denied',rows:[],observed_at:null,stale:true,error:'permission_denied'});
  let model=PRs.project(e,null,1100);assert.equal(model.count,null);assert.equal(model.stale,true);assert.match(model.label,/observations unavailable/);
  model=PRs.project(e,'owner/hub',1100);assert.equal(model.count,1);assert.equal(model.stale,false);
  assert.equal(model.hasObservations,true);
  assert.equal(PRs.project(e,'owner/denied',1100).hasObservations,false);
  const empty=envelope([]);assert.equal(PRs.project(empty,null,1100).hasObservations,true);
  e.stale=true;assert.equal(PRs.project(e,'owner/hub',1100).stale,true);
  const p=parent();PRs.render(p,PRs.project(e,null,1100));assert.match(p.textContent,/owner\/denied: not observed/);assert.match(p.textContent,/observed 1m ago/);
});
test('valid snapshots reattach the stable row tree after a shell unavailable placeholder',()=>{
  const p=parent(),model=PRs.project(envelope(),null,1100);PRs.render(p,model);
  const table=p.children[3].children[0],entry=table.children[1],disclosure=entry.children[0].children[4].children[2];
  disclosure.handlers.click();p.replaceChildren(new Node('placeholder'));assert.equal(entry.isConnected,false);
  PRs.render(p,model);assert.equal(p.children[3].children[0].children[1],entry);assert.equal(entry.isConnected,true);
  assert.equal(disclosure.getAttribute('aria-expanded'),'true');
});
test('duplicate or mismatched identities, hostile links and literal dynamic text are refused safely',()=>{
  const e=envelope([row(),row()]);assert.throws(()=>PRs.project(e,null,1100),/invalid/);
  e.data.repositories[0].rows=[row('1','other/repo')];assert.throws(()=>PRs.project(e,null,1100),/invalid/);
  const link=new Node('a');Rows.safeLink(link,'javascript:alert(1)');assert.equal(link.href,undefined);
  Rows.safeLink(link,'https://user:pass@github.com/a/b');assert.equal(link.href,undefined);
  const view=new Rows.RowView(row());assert.equal(view.title.textContent,'literal <img onerror=bad>');assert.equal(view.title.children.length,0);view.destroy();
});
test('same identity survives HEAD changes, sorting, filters and disclosure updates with keyboard focus',()=>{
  const list=new Rows.RowList(parent());const first=row(),second=row('2');second.state='boulder';
  list.update([first,second],{now:1100});const view=list.views.get(first.id);const button=view.button;
  button.focus();button.handlers.click();assert.equal(list.open,first.id);assert.equal(button.getAttribute('aria-expanded'),'true');
  list.views.get(second.id).button.handlers.click();assert.equal(view.full.hidden,true);assert.equal(list.open,second.id);
  button.handlers.click();first.head='b'.repeat(40);first.state='boulder';
  list.update([second,first],{selectedRepo:'other/repo',now:1200});assert.equal(list.views.get(first.id),view);assert.equal(view.node.hidden,true);assert.equal(list.open,first.id);assert.equal(document.activeElement,button);
  list.update([first,second],{now:1300});assert.equal(view.node.hidden,false);assert.equal(view.full.hidden,false);assert.match(view.meta.textContent,/bbbbbbbb/);assert.match(view.budgets[0].note.textContent,/observed 5m ago/);list.destroy();
});
test('initial rows enter with reference360ms stagger; only later new identities get fresh700ms',()=>{
  const list=new Rows.RowList(parent()),first=row(),second=row('2');list.update([first,second]);
  for(const [index,view] of [...list.views.values()].entries()) {assert.equal(view.row.classList.contains('entering'),true);assert.equal(view.row.classList.contains('fresh'),false);assert.equal(view.row.style.animationDelay,`${index*40}ms`);}
  const third=row('3');list.update([first,second,third]);assert.equal(list.views.get(third.id).row.classList.contains('fresh'),true);assert.equal(list.views.get(third.id).row.classList.contains('entering'),false);assert.equal(list.views.get(third.id).row.style.animationDelay,'80ms');
  list.update([terminal(second),first,third]);assert.equal(list.views.get(second.id).row.style.animationDelay,'0ms');list.destroy();
  const empty=new Rows.RowList(parent());empty.update([]);empty.update([first]);assert.equal(empty.views.get(first.id).row.classList.contains('fresh'),true);empty.destroy();
});
test('fresh OPEN to MERGED has one glow and removal clock; repeated snapshots never restart either',()=>{
  const timer=timers(),list=new Rows.RowList(parent(),timer);const r=row();list.update([r]);const view=list.views.get(r.id);
  list.update([terminal(r)]);assert.equal(view.rewarding,true);assert.equal(view.ribbon.hidden,false);assert.equal(timer.queue.size,2);assert.equal(view.row.classList.contains('entering'),false);assert.equal(view.row.classList.contains('fresh'),false);
  timer.advance(2600);assert.equal(view.row.classList.contains('pr-reward'),false);assert.equal(view.row.classList.contains('entering'),false);assert.equal(view.row.classList.contains('fresh'),false);
  list.update([terminal(r)]);assert.equal(view.row.classList.contains('pr-reward'),false);assert.equal(timer.queue.size,1);
  timer.advance(4400);assert.equal(list.views.size,0);list.update([terminal(r)]);assert.equal(list.views.size,0);
  list.update([r]);assert.equal(list.views.size,1);assert.equal(list.views.get(r.id).rewarding,false);list.destroy();
});
test('later fresh rows do not re-enter when merge glow ends',()=>{
  const timer=timers(),list=new Rows.RowList(parent(),timer),first=row(),fresh=row('2');list.update([first]);list.update([first,fresh]);
  const view=list.views.get(fresh.id);assert.equal(view.row.classList.contains('fresh'),true);
  list.update([first,terminal(fresh)]);assert.equal(view.row.classList.contains('fresh'),false);assert.equal(view.row.classList.contains('entering'),false);
  timer.advance(2600);assert.equal(view.row.classList.contains('pr-reward'),false);assert.equal(view.row.classList.contains('fresh'),false);assert.equal(view.row.classList.contains('entering'),false);
  list.update([first,terminal(fresh)]);assert.equal(view.row.classList.contains('fresh'),false);timer.advance(4400);assert.equal(list.views.has(fresh.id),false);list.destroy();
});
test('default timers are invoked without a RowView native receiver',()=>{
  const oldSet=global.setTimeout,oldClear=global.clearTimeout;let id=0;
  global.setTimeout=function(){assert.equal(this instanceof Rows.RowView,false);return ++id;};
  global.clearTimeout=function(){assert.equal(this instanceof Rows.RowView,false);};
  try{const r=row(),view=new Rows.RowView(r);view.update(terminal(r));assert.equal(id,2);view.destroy();}
  finally{global.setTimeout=oldSet;global.clearTimeout=oldClear;}
});
test('CLOSED, first-seen MERGED, stale merges, reopening and destruction do not leave reward timers',()=>{
  for(const mode of ['closed','initial','stale','reopen','absent','destroy']){
    const timer=timers(),list=new Rows.RowList(parent(),timer),r=row();
    if(mode==='initial')list.update([terminal(r)]);
    else{list.update([r]);list.update([terminal(r,mode==='closed'?'CLOSED':'MERGED')],{stale:mode==='stale'});if(mode==='reopen')list.update([r]);if(mode==='absent')list.update([]);if(mode==='destroy')list.destroy();}
    assert.equal(timer.queue.size,0,mode);if(!['destroy','absent'].includes(mode)){assert.equal(list.views.get(r.id).rewarding,false,mode);list.destroy();}
  }
});
test('five disclosure meters use remaining headlines, exact used fill, near ticks and unknown source ages',()=>{
  const r=row(),list=new Rows.RowList(parent());list.update([r],{now:1100});const view=list.views.get(r.id);list.toggle(r.id);
  assert.equal(view.budgets.length,5);assert.equal(view.full.children.length,6);
  for(const [i,v] of view.budgets.entries()){assert.equal(v.fill.style.width,`${r.budgets[i].ratio*100}%`);assert.match(v.headline.textContent,/left of/);assert.match(v.note.textContent,/observed 1m ago/);}
  r.budgets[0]={...r.budgets[0],used:10,remaining:0,ratio:1,state:'boulder'};list.update([r]);assert.equal(view.budgets[0].cap.hidden,false);assert.equal(view.budgets[0].card.classList.contains('landing'),true);
  const unknown=clone(fixtures.partial);const partial=new Rows.RowView(unknown);assert.equal(partial.budgets[0].fill.hidden,true);assert.equal(partial.budgets[0].tick.hidden,true);assert.match(partial.budgets[0].note.textContent,/not observed/);partial.destroy();list.destroy();
});
test('CodeRabbit findings and skipped probes render terminal badges with stale context',()=>{
  const r=row(),view=new Rows.RowView(r);
  const cases=[
    ['reported',null,'Reviewed on HEAD','clear'],
    ['findings',null,'Findings on HEAD','bump'],
    ['skipped','draft','Skipped','idle'],
    ['skipped','non-base-branch','Skipped','idle'],
    ['skipped','paused','Paused','bump'],
    ['paused',null,'Paused','bump'],
    ['rate_limit_stalled',null,'Rate-limited','bump'],
    ['no_review_yet',null,'No review on HEAD','run'],
    ['unknown',null,'Unknown','idle'],
  ];
  for(const [status,skipReason,label,tone] of cases){
    r.coderabbit={...r.coderabbit,status,skip_reason:skipReason,stale:true};view.update(r,{now:1100});
    assert.match(view.cr.textContent,new RegExp(label),status+':'+skipReason);
    assert.equal(view.cr.className,'b b-'+tone,status+':'+skipReason);
    assert.match(view.crNote.textContent,/Last-known · stale · observed 1m ago/);
    if(status==='skipped'&&skipReason!=='paused')assert.match(view.crNote.textContent,new RegExp(skipReason));
  }
  view.destroy();
});
test('assets remain fetch-free and scoped; shared motion tokens include normal and reduced-motion resting states',()=>{
  for(const file of ['prs.js','pr_rows.js'])assert.doesNotMatch(fs.readFileSync(path.join(root,'mergepath/cockpit/assets',file),'utf8'),/\bfetch\s*\(|new EventSource|setInterval/);
  const css=fs.readFileSync(path.join(root,'mergepath/cockpit/assets/prs.css'),'utf8');assert.match(css,/var\(--t-pop\)/);assert.match(css,/var\(--t-glow\)/);assert.match(css,/prefers-reduced-motion:reduce/);assert.match(css,/\.ck\.rm/);assert.match(css,/max-width:720px/);
  const html=fs.readFileSync(path.join(root,'mergepath/cockpit/index.html'),'utf8');for(const asset of ['prs.css','pr_rows.js','prs.js'])assert.ok(html.includes('assets/'+asset));
});
