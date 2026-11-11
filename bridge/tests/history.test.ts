import test,{type TestContext} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {basename,dirname,join,resolve} from 'node:path';
import {createQueries} from '../src/api/queries.js';
import {ApiError} from '../src/api/validation.js';
import {openStore} from '../src/state/store.js';
import {createSync} from '../src/state/sync.js';
import {connectRpc} from '../src/protocol/rpc-client.js';
import {fakeServer,handshake} from './support/fake-server.js';

async function fixture(t:TestContext,options:{complete?:boolean;empty?:boolean;repeat?:boolean}={}){
 const directory=await mkdtemp(join(tmpdir(),'codex-history-'));
 const project={id:'project',name:'Controlled',path:'C:/controlled/project'};
 const items=(prefix:string,count:number)=>Array.from({length:count},(_,i)=>({id:`${prefix}-${i}`,type:'agentMessage',text:`${prefix} ${i}`}));
 const recent={id:'recent',status:'completed',items:items('recent',75)};
 const older={id:'older',status:'completed',items:items('older',75)};
 const thread={id:'thread',cwd:project.path,name:'Controlled',preview:'',status:{type:'idle'},parentThreadId:null,turns:[]};
 const calls:{method:string;params:any}[]=[];
 let beforeOlder:(()=>void)|undefined;
 const server=await fakeServer((socket,m)=>{
  if(handshake(socket,m)||m.method==='initialized')return;
  const p=m.params as any;calls.push({method:m.method!,params:p});
  let result:any={};
  if(m.method==='thread/read')result={thread};
  if(m.method==='thread/loaded/list')result={data:['thread']};
  if(m.method==='thread/resume')result={thread,initialTurnsPage:{data:[recent],nextCursor:options.complete?null:'turns-before-recent',backwardsCursor:'turns-newest'},itemsBackwardsCursor:'items-hydration-start'};
  if(m.method==='thread/turns/list'){
   beforeOlder?.();beforeOlder=undefined;
   result=options.repeat?{data:[],nextCursor:p.cursor}:
    options.empty&&p.cursor==='turns-before-recent'?{data:[{id:'empty',status:'completed',items:[]}],nextCursor:'turns-before-empty'}:
    {data:[older],nextCursor:null};
  }
  if(m.method==='thread/items/list')result={data:recent.items.slice(-50).reverse().map(item=>({turnId:'recent',item,completedAtMs:1})),nextCursor:'items-replay'};
  socket.send(JSON.stringify({id:m.id,result}));
 });
 const rpc=await connectRpc(server.url,'test'),store=openStore(join(directory,'state.sqlite')),sync=createSync(store,rpc);
 t.after(async()=>{sync.close();await rpc.close();await server.close();store.close();assert.equal(dirname(resolve(directory)),resolve(tmpdir()));assert.ok(basename(directory).startsWith('codex-history-'));await rm(directory,{recursive:true,force:true});});
 const queries=createQueries({rpc,store,sync,projects:[project]});
 return {queries,store,calls,beforeOlder:(action:()=>void)=>{beforeOlder=action;}};
}

test('complete_initial_turns_page_does_not_replay_item_hydration_cursor',async t=>{
 const f=await fixture(t,{complete:true}),snapshot=await f.queries.querySnapshot('thread');
 assert.equal(snapshot.items.length,50);assert.ok(snapshot.itemsCursor);
 const last=await f.queries.queryItems('thread',snapshot.itemsCursor!);
 assert.equal(last.data.length,25);assert.equal(last.nextCursor,null);
 assert.equal(new Set([...last.data,...snapshot.items].map(i=>i.id)).size,75);
 assert.equal(f.calls.some(c=>c.method==='thread/items/list'),false);
});

test('older_turns_are_bounded_without_missing_items_or_duplicate_anchors',async t=>{
 const f=await fixture(t),snapshot=await f.queries.querySnapshot('thread');
 const pages=[snapshot.items];let cursor=snapshot.itemsCursor;
 for(let n=0;cursor&&n<5;n++){
  const page=await f.queries.queryItems('thread',cursor);assert.ok(page.data.length<=50);
  pages.unshift(page.data);cursor=page.nextCursor;
 }
 assert.equal(cursor,null);
 assert.deepEqual(pages.flat().map(i=>i.id),[...Array.from({length:75},(_,i)=>`older-${i}`),...Array.from({length:75},(_,i)=>`recent-${i}`)]);
 const call=f.calls.find(c=>c.method==='thread/turns/list');assert.ok(call);
 assert.deepEqual(call.params,{threadId:'thread',cursor:'turns-before-recent',limit:1,sortDirection:'desc',itemsView:'full'});
 assert.equal(f.calls.some(c=>c.method==='thread/items/list'),false);
});

test('concurrent_history_reader_reuses_cache_and_preserves_live_snapshot_changes',async t=>{
 const f=await fixture(t),snapshot=await f.queries.querySnapshot('thread');
 const local=await f.queries.queryItems('thread',snapshot.itemsCursor!);assert.ok(local.nextCursor);
 f.beforeOlder(()=>{
  const fresh=f.store.snapshot('thread');fresh.items.at(-1)!.text='live output during history';fresh.thread.status='active';fresh.thread.activeTurnId='live-turn';
  f.store.atomic(()=>f.store.putSnapshot(fresh));
 });
 const a=await f.queries.queryItems('thread',local.nextCursor!);
 const b=await f.queries.queryItems('thread',local.nextCursor!);
 assert.deepEqual(a,b);assert.equal(a.data.length,50);
 assert.equal(f.calls.filter(c=>c.method==='thread/turns/list').length,1);
 const fresh=f.store.snapshot('thread');assert.equal(fresh.items.at(-1)!.text,'live output during history');assert.equal(fresh.thread.activeTurnId,'live-turn');
 assert.equal(new Set(fresh.items.map(i=>i.id)).size,150);
});

test('empty_older_turns_are_skipped_until_visible_history_is_available',async t=>{
 const f=await fixture(t,{empty:true}),snapshot=await f.queries.querySnapshot('thread');
 const local=await f.queries.queryItems('thread',snapshot.itemsCursor!);
 const older=await f.queries.queryItems('thread',local.nextCursor!);
 assert.equal(older.data.length,50);assert.ok(older.data.every(i=>i.turnId==='older'));
 assert.equal(f.calls.filter(c=>c.method==='thread/turns/list').length,2);
});

test('repeated_native_history_cursor_is_rejected_instead_of_looping',async t=>{
 const f=await fixture(t,{repeat:true}),snapshot=await f.queries.querySnapshot('thread');
 const local=await f.queries.queryItems('thread',snapshot.itemsCursor!);
 await assert.rejects(f.queries.queryItems('thread',local.nextCursor!),(e:unknown)=>e instanceof ApiError&&e.code==='upstream_invalid');
});
