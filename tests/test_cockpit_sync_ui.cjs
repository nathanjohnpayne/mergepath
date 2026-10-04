/* Offline DOM/state/request boundaries. Expected <1s; bound30s. */
'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
class Node {
  constructor(tag='text'){this.tagName=tag.toUpperCase();this.children=[];this.parentNode=null;this.dataset={};this.attributes={};this.handlers={};this.className='';this.hidden=false;this._text='';this.disabled=false;
    this.classList={contains:n=>this.className.split(/\s+/).includes(n),add:(...ns)=>{this.className=[...new Set([...this.className.split(/\s+/).filter(Boolean),...ns])].join(' ');},remove:(...ns)=>{this.className=this.className.split(/\s+/).filter(n=>!ns.includes(n)).join(' ');},toggle:(n,on)=>{on=on??!this.classList.contains(n);this.classList[on?'add':'remove'](n);}};}
  append(...nodes){for(const n of nodes){n.remove();n.parentNode=this;this.children.push(n);}}
  replaceChildren(...nodes){for(const n of [...this.children])n.remove();this._text='';this.append(...nodes);}
  contains(node){return node===this||this.children.some(child=>child.contains(node));}
  remove(){if(this.parentNode){if(this.isConnected&&this.contains(document.activeElement))document.activeElement=document.body;const a=this.parentNode.children;a.splice(a.indexOf(this),1);this.parentNode=null;}}
  insertBefore(n,next){n.remove();n.parentNode=this;const i=this.children.indexOf(next);this.children.splice(i<0?this.children.length:i,0,n);}
  get isConnected(){return this===document.body||!!this.parentNode?.isConnected;}
  set textContent(v){this.replaceChildren();this._text=String(v);}
  get textContent(){return this._text+this.children.map(n=>n.textContent).join('');}
  setAttribute(k,v){this.attributes[k]=String(v);}
  getAttribute(k){return this.attributes[k]??null;}
  addEventListener(k,fn){this.handlers[k]=fn;}
  focus(){document.activeElement=this;}
  closest(selector){if(selector==='[hidden]')return this.hidden?this:this.parentNode?.closest(selector)??null;return null;}
  querySelectorAll(selector){return this.children.flatMap(n=>[...((n.tagName==='BUTTON'||n.tagName==='INPUT')&&!n.disabled||n.tagName==='A'&&n.href?[n]:[]),...n.querySelectorAll(selector)]);}
}
global.document={createElement:t=>new Node(t),activeElement:null,querySelector:()=>null};document.body=new Node('body');
const Sync=require('../mergepath/cockpit/assets/sync.js');
const clone=x=>structuredClone(x),sha='a'.repeat(40),pid='p'.repeat(43),rid='c'.repeat(32),now=1791054000;
function target({ahead=false,old=false}={}){return {name:'one',repo:'owner/one',status:ahead?'ahead':'drift',eligible:true,reason:null,
  baseline:'origin/main@'+'b'.repeat(40),paths:[{path:'REVIEW_POLICY.md',class:'canonical',direction:ahead?'consumer ahead of hub':'hub ahead'}],
  open_sync_prs:old?[{number:88,branch:'mergepath-sync/old'}]:[],ahead,choices:old?['skip','recreate']:['sync','skip'],default_choice:old?'skip':'sync'};}
function preview(options){return {schema:'cockpit-sync-preview/v1',preview_id:pid,hub_sha:sha,expires_at:now+300,targets:[target(options)],checks:['Hub clean at origin/main'],dry_run:'proposed scope',scope_note:'Audit proves actual differences',can_confirm:true};}
function state(p=preview()){return {schema:'cockpit-sync/v1',phase:'preview',preview:p,run:null,error:null};}
function runState(events=[],outcome='running',results=[]){return {schema:'cockpit-sync/v1',phase:outcome==='success'?'done':outcome==='running'?'running':'error',preview:preview(),error:null,
  run:{schema:'cockpit-sync-run/v1',run_id:rid,operator:'nathanjohnpayne',started_at:now,hub_sha:sha,repos:['owner/one'],choices:{'owner/one':'sync'},events,results,outcome}};}
function fixture(p=preview()){
  const parent=new Node('main'),background=new Node('section'),trigger=new Node('button');parent.append(background,trigger);document.body.append(parent);trigger.focus();
  const calls=[],timers=new Map();let seq=0;
  const actions={preview:async payload=>{calls.push(['preview',payload]);return state(p);},confirm:async payload=>{calls.push(['confirm',payload]);return runState();},cancel:async payload=>{calls.push(['cancel',payload]);return {schema:'cockpit-sync/v1',phase:'canceled',preview:null,run:null,error:null};}};
  const view=new Sync.SyncDialog(parent,actions,{now:()=>now,setTimer:(fn,ms)=>{timers.set(++seq,{fn,ms});return seq;},clearTimer:id=>timers.delete(id)});
  return {view,calls,timers,parent,background,trigger};
}
test('preview, explicit recreate, separate ahead acknowledgment and one confirmation',async()=>{
  const {view,calls,background,trigger}=fixture(preview({ahead:true,old:true}));await view.open(['owner/one']);
  assert.equal(background.inert,true);assert.equal(view.next.disabled,true);assert.match(view.body.textContent,/Recreate leaves old PRs open/);
  view.choiceNodes.get('owner/one:recreate').handlers.click();assert.equal(view.next.disabled,false);view.showConfirm();
  assert.equal(view.start.disabled,true);assert.match(view.body.textContent,new RegExp(sha));
  await view.begin();assert.equal(calls.filter(c=>c[0]==='confirm').length,0);
  view.ack.checked=true;view.ack.handlers.change();assert.equal(view.start.disabled,false);
  await Promise.all([view.begin(),view.begin()]);assert.equal(calls.filter(c=>c[0]==='confirm').length,1);
  assert.deepEqual(calls.find(c=>c[0]==='confirm')[1],{preview_id:pid,hub_sha:sha,choices:{'owner/one':'recreate'},ack_ahead:true});
  await view.dismiss();assert.equal(view.visible,false);assert.equal(document.activeElement,trigger);assert.equal(background.inert,undefined);
  view.update(runState());assert.equal(view.visible,false);
  assert.equal(calls.filter(c=>c[0]==='cancel').length,0);view.close();
});
test('back invalidates ahead acknowledgment; canceled and expired previews do not execute',async()=>{
  const {view,calls,timers}=fixture(preview({ahead:true}));await view.open(['owner/one']);view.showConfirm();view.ack.checked=true;view.controls();
  view.footer.children[0].handlers.click();view.showConfirm();assert.equal(view.ack.checked,false);assert.equal(view.start.disabled,true);
  await view.dismiss();assert.equal(calls.at(-1)[0],'cancel');view.close();
  const f=fixture({...preview(),expires_at:now});await f.view.open(['owner/one']);assert.equal(f.view.next.disabled,true);assert.match(f.view.error.textContent,/expired/);f.view.close();
  assert.equal(timers.size,0);
});
test('run updates preserve modal and log nodes, focus, results; missing/out-of-order stages stay honest',()=>{
  const {view}=fixture();view.update(runState([{id:1,kind:'stage',repo:'owner/one',value:'commit'},{id:2,kind:'log',text:'actual log'}]));
  const modal=view.modal,line=view.log.children[0];line.focus();
  const events=[{id:1,kind:'stage',repo:'owner/one',value:'commit'},{id:2,kind:'log',text:'actual log'},{id:3,kind:'stage',repo:'owner/one',value:'fetch'}];
  view.update(runState(events));view.update(runState(events));assert.equal(view.modal,modal);assert.equal(view.log.children[0],line);assert.equal(document.activeElement,line);
  assert.equal(view.eventNodes.size,3);assert.equal(view.log.children.length,2);assert.equal(view.railNodes.get('owner/one:diff').classList.contains('observed'),false);
  assert.equal(view.railNodes.get('owner/one:commit').classList.contains('active'),true);
  const result={kind:'result',repo:'owner/one',value:'https://github.com/owner/one/pull/99'};
  const done=runState([...events,{id:4,...result}], 'success',[result]);view.update(done);const chip=view.chips.children[0];view.update(done);
  assert.equal(view.chips.children[0],chip);assert.equal(view.chips.children.length,1);assert.equal(view.cursor.hidden,true);assert.equal(view.done.children.length,2);
  assert.equal(view.railNodes.get('owner/one:PR').classList.contains('observed'),false);assert.equal(chip.href,result.value);view.close();
});
test('partial failure retains actual PR results and cannot claim all-target success',()=>{
  const {view}=fixture();view.reveal();const result={kind:'result',repo:'owner/one',value:'https://github.com/owner/one/pull/99'};
  view.update(runState([{id:1,...result}],'partial',[result]));assert.match(view.done.textContent,/partial/);assert.equal(view.chips.children.length,1);
  const bad=runState([],'success',[]);assert.equal(Sync.validState(bad),false);assert.equal(view.update(bad),false);view.close();
});
test('cached-author refusal explains terminal recovery without dispatching authentication or retry',()=>{
  const {view,calls}=fixture();view.reveal();
  const refused=runState([{id:1,kind:'log',text:'cached_author_required'},{id:2,kind:'outcome',value:'refused'}],'refused');
  view.update(refused);assert.equal(view.error.hidden,false);assert.match(view.error.textContent,/cached author credential.*unavailable/i);
  assert.match(view.error.textContent,/Refresh credentials in the terminal/);assert.match(view.error.textContent,/new preview/);
  assert.match(view.log.textContent,/Refresh credentials in the terminal/);assert.doesNotMatch(view.error.textContent,/cached_author_required/);
  view.update(refused);assert.equal(calls.length,0);assert.equal(view.eventNodes.size,2);assert.equal(view.footer.children.length,1);view.close();
});
test('schema refuses unknown choices, unsafe links, forged author, duplicate event identities',()=>{
  for(const edit of [s=>s.preview.targets[0].choices.push('shell'),s=>s.preview.hub_sha='short',s=>s.preview.targets[0].repo='../../repo']){const s=state();edit(s);assert.equal(Sync.validState(s),false);}
  const unsafe=runState([{id:1,kind:'result',repo:'owner/one',value:'javascript:alert(1)'}]);assert.equal(Sync.validState(unsafe),false);
  const forged=runState();forged.run.operator='browser-author';assert.equal(Sync.validState(forged),false);
  const dup=runState([{id:1,kind:'log',text:'a'},{id:1,kind:'log',text:'b'}]);assert.equal(Sync.validState(dup),false);
});
test('focus containment and return are usable without relying on animation',async()=>{
  const {view,trigger}=fixture();await view.open(['owner/one']);const nodes=view.modal.querySelectorAll('button');const first=nodes[0],last=nodes.at(-1);
  last.focus();let prevented=false;view.overlay.handlers.keydown({key:'Tab',shiftKey:false,preventDefault:()=>prevented=true});assert.equal(prevented,true);assert.equal(document.activeElement,first);
  first.focus();view.overlay.handlers.keydown({key:'Tab',shiftKey:true,preventDefault:()=>{}});assert.equal(document.activeElement,last);
  await view.dismiss();assert.equal(document.activeElement,trigger);view.close();
});
test('step changes move removed-control focus into the dialog; same-step snapshots preserve it',async()=>{
  const {view}=fixture();await view.open(['owner/one']);
  const heading=view.title,modal=view.modal;
  view.next.focus();view.next.handlers.click();assert.equal(document.activeElement,heading);assert.equal(heading.isConnected,true);
  view.start.focus();view.update(state());assert.equal(document.activeElement,view.start);
  view.footer.children[0].focus();view.footer.children[0].handlers.click();assert.equal(document.activeElement,heading);
  view.next.focus();view.next.handlers.click();view.start.focus();await view.begin();assert.equal(document.activeElement,heading);
  const hide=view.footer.children[0],log=view.log;hide.focus();view.update(runState());assert.equal(document.activeElement,hide);assert.equal(view.log,log);
  const result={kind:'result',repo:'owner/one',value:'https://github.com/owner/one/pull/99'};
  const done=runState([{id:1,...result}],'success',[result]);view.update(done);assert.equal(document.activeElement,heading);
  const close=view.footer.children[0],chip=view.chips.children[0];close.focus();view.update(done);
  assert.equal(document.activeElement,close);assert.equal(view.modal,modal);assert.equal(view.log,log);assert.equal(view.chips.children[0],chip);view.close();
  const f=fixture();await f.view.open(['owner/one']);f.view.next.focus();
  const error={schema:'cockpit-sync/v1',phase:'error',preview:null,run:null,error:'hub_dirty'};
  f.view.update(error);assert.equal(document.activeElement,f.view.title);
  const errorClose=f.view.footer.children[0];errorClose.focus();f.view.update(error);assert.equal(document.activeElement,errorClose);f.view.close();
});
test('default browser timers keep their global receiver through initial preview and Back',async()=>{
  const f=fixture(),actions=f.view.actions;f.view.close();
  const nativeSet=globalThis.setTimeout,nativeClear=globalThis.clearTimeout,timers=new Map();let seq=0,view;
  try{
    globalThis.setTimeout=function(fn,ms){assert.equal(this===globalThis,true,'native setTimeout receiver');timers.set(++seq,{fn,ms});return seq;};
    globalThis.clearTimeout=function(id){assert.equal(this===globalThis,true,'native clearTimeout receiver');timers.delete(id);};
    view=new Sync.SyncDialog(f.parent,actions,{now:()=>now});await view.open(['owner/one']);
    assert.equal(view.error.hidden,true);assert.equal(timers.size,1);
    view.next.focus();view.next.handlers.click();view.footer.children[0].focus();view.footer.children[0].handlers.click();
    assert.equal(document.activeElement,view.title);assert.equal(timers.size,1);
    view.next.focus();view.next.handlers.click();assert.equal(document.activeElement,view.title);
    const fixed=Sync.createActions(async url=>({ok:true,json:async()=>url==='api/session'?{csrf:'s'.repeat(43)}:state()}));
    await fixed.preview({repos:['owner/one']});assert.equal(timers.size,1);
    view.close();view=null;assert.equal(timers.size,0);
  }finally{try{view?.close();}finally{globalThis.setTimeout=nativeSet;globalThis.clearTimeout=nativeClear;}}
});
test('fixed authenticated JSON actions send only payload; no separate poll or user command',async()=>{
  const calls=[];let cleared=false;
  const actions=Sync.createActions(async(url,options)=>{calls.push([url,options]);return url==='api/session'?{ok:true,json:async()=>({csrf:'s'.repeat(43)})}:{ok:true,json:async()=>state()};},()=>1,()=>cleared=true);
  const payload={repos:['owner/one']};await actions.preview(payload);assert.equal(cleared,true);assert.equal(calls.length,2);assert.equal(calls[1][0],'api/sync/preview');
  assert.equal(calls[1][1].headers['X-Cockpit-CSRF'],'s'.repeat(43));assert.equal(calls[1][1].credentials,'same-origin');assert.deepEqual(JSON.parse(calls[1][1].body),payload);
});
test('both reduction paths and responsive dialog preserve pinned motion tokens',()=>{
  const css=fs.readFileSync(path.join(__dirname,'../mergepath/cockpit/assets/sync.css'),'utf8');
  assert.match(css,/width:660px/);assert.match(css,/var\(--t-pop\) var\(--ease\)/);assert.match(css,/var\(--t-med\) ease/);assert.match(css,/var\(--t-fast\) ease/);
  assert.match(css,/var\(--t-glow\) ease-out/);assert.match(css,/blink 1s steps\(2\)/);assert.match(css,/\.ck\.rm/);assert.match(css,/prefers-reduced-motion:reduce/);assert.match(css,/max-width:520px/);
  const definitions=new Set([...css.matchAll(/@keyframes\s+([\w-]+)\s*\{/g)].map(match=>match[1]));
  for(const name of ['sync-fade','sync-pop','sync-blink','sync-burst'])assert.equal(definitions.has(name),true,`${name} must have executable keyframes`);
  for(const match of css.matchAll(/(?:animation:|,)\s*(sync-[\w-]+)\s+var\(/g))assert.equal(definitions.has(match[1]),true);
  assert.match(css,/@keyframes sync-pop\{0%\{transform:scale\(\.6\);opacity:0\}60%\{transform:scale\(1\.08\);opacity:1\}100%\{transform:scale\(1\);opacity:1\}\}/);
  assert.match(css,/@keyframes sync-fade\{from\{opacity:0\}to\{opacity:1\}\}/);
  assert.match(css,/@keyframes sync-blink\{0%,100%\{opacity:1\}50%\{opacity:\.35\}\}/);
  assert.match(css,/@keyframes sync-burst.*34px/);
});

async function expiryFixture(){
  const f=fixture();f.clock=now;f.view.now=()=>f.clock;await f.view.open(['owner/one']);
  f.expiryCallback=[...f.timers.values()][0].fn;f.view.showConfirm();return f;
}
function successfulRun(){
  const result={kind:'result',repo:'owner/one',value:'https://github.com/owner/one/pull/99'};
  return runState([{id:1,...result}],'success',[result]);
}
test('accepted running and done runs retire preview authority, including queued expiry callbacks',async()=>{
  for(const outcome of ['running','done']){
    const f=await expiryFixture();
    try{
      await f.view.begin();if(outcome==='done')f.view.update(successfulRun());
      assert.equal(f.timers.size,0);f.clock=now+301;f.expiryCallback();f.view.controls();
      assert.equal(f.view.state.phase,outcome);assert.equal(f.view.error.hidden,true);
      assert.equal(f.calls.filter(c=>c[0]==='confirm').length,1);
      if(outcome==='done'){assert.equal(f.view.title.textContent,'Sync complete');assert.match(f.view.chips.textContent,/owner\/one #99/);}
    }finally{f.view.close();}
  }
});
test('a delayed accepted confirmation clears only the consumed preview warning through finally',async()=>{
  const f=await expiryFixture();let release;
  try{
    f.view.actions.confirm=async payload=>{f.calls.push(['confirm',payload]);return await new Promise(resolve=>release=resolve);};
    const pending=f.view.begin();f.clock=now+301;f.expiryCallback();
    assert.equal(f.view.error.hidden,false);assert.match(f.view.error.textContent,/preview expired/i);
    release(successfulRun());await pending;f.expiryCallback();
    assert.equal(f.view.busy,false);assert.equal(f.timers.size,0);assert.equal(f.view.error.hidden,true);
    assert.equal(f.view.title.textContent,'Sync complete');assert.match(f.view.chips.textContent,/owner\/one #99/);
    assert.equal(f.calls.filter(c=>c[0]==='confirm').length,1);
  }finally{f.view.close();}
});
test('hidden accepted run transitions retire expiry before returning without rendering',async()=>{
  for(const outcome of ['running','done']){
    const f=await expiryFixture();
    try{
      await f.view.begin();f.view.hide();f.view.update(outcome==='done'?successfulRun():runState());
      assert.equal(f.view.visible,false);assert.equal(f.timers.size,0);f.clock=now+301;f.expiryCallback();
      assert.equal(f.view.error.hidden,true);assert.equal(f.calls.filter(c=>c[0]==='confirm').length,1);
      f.view.reveal();f.view.update(f.view.state);
      if(outcome==='done')assert.match(f.view.chips.textContent,/owner\/one #99/);
    }finally{f.view.close();}
  }
});
test('queued expiry preserves invalid evidence, state errors, runtime refusal and unconsumed server expiry',async()=>{
  for(const fault of ['invalid','state','cleanup','server-expiry']){
    const f=await expiryFixture();
    try{
      if(fault==='invalid')assert.equal(f.view.update({schema:'invalid'}),false);
      else if(fault==='state')f.view.update({schema:'cockpit-sync/v1',phase:'error',preview:preview(),run:null,error:'hub_dirty'});
      else if(fault==='cleanup'){
        await f.view.begin();const result={kind:'result',repo:'owner/one',value:'https://github.com/owner/one/pull/99'};
        f.view.update(runState([{id:1,...result},{id:2,kind:'log',text:'cleanup_incomplete'}],'failed',[result]));
      }else{
        f.view.actions.confirm=async payload=>{f.calls.push(['confirm',payload]);return {schema:'cockpit-sync/v1',phase:'error',preview:preview(),run:null,error:'preview_expired'};};
        await f.view.begin();assert.equal(f.view.state.run,null);
      }
      const warning=f.view.error.textContent;assert.equal(f.view.error.hidden,false);
      f.clock=now+301;f.expiryCallback();f.view.controls();
      assert.equal(f.view.error.textContent,warning);assert.equal(f.view.error.hidden,false);
      if(fault==='invalid')assert.equal(f.view.start.disabled,true);
      if(fault==='cleanup'){assert.match(warning,/cleanup could not be verified/i);assert.match(f.view.chips.textContent,/owner\/one #99/);}
      if(fault==='server-expiry')assert.match(warning,/preview expired/i);
    }finally{f.view.close();}
  }
});
test('unconsumed expiry refuses before dispatch, and a later preview owns its own timer',async()=>{
  const expired=await expiryFixture();
  try{
    expired.clock=now+301;await expired.view.begin();
    assert.equal(expired.calls.filter(c=>c[0]==='confirm').length,0);assert.equal(expired.view.start.disabled,true);
    assert.match(expired.view.error.textContent,/preview expired/i);
  }finally{expired.view.close();}
  const f=await expiryFixture();
  try{
    await f.view.begin();f.view.update(successfulRun());
    const fresh={...preview(),preview_id:'q'.repeat(43),expires_at:now+600};
    f.view.actions.preview=async payload=>{f.calls.push(['preview',payload]);return state(fresh);};
    await f.view.open(['owner/one']);f.view.showConfirm();assert.equal(f.timers.size,1);
    const freshCallback=[...f.timers.values()][0].fn;f.clock=fresh.expires_at+1;f.expiryCallback();
    assert.equal(f.view.error.hidden,true);freshCallback();assert.equal(f.view.start.disabled,true);
    await f.view.begin();assert.equal(f.calls.filter(c=>c[0]==='confirm').length,1);assert.match(f.view.error.textContent,/preview expired/i);
  }finally{f.view.close();}
});
