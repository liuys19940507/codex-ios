import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { openStore, type Store } from '../src/state/store.js';
import { createSync, type SyncService } from '../src/state/sync.js';
import { connectRpc, type RpcClient } from '../src/protocol/rpc-client.js';
import { fakeServer, handshake } from './support/fake-server.js';
import type { Json } from '../src/api/contracts.js';

const delta=(text:string):Json=>({method:'item/agentMessage/delta',params:{threadId:'thread',turnId:'turn',itemId:'message',delta:text}});
const completion=(text:string):Json=>({method:'item/completed',params:{threadId:'thread',turnId:'turn',item:{type:'agentMessage',id:'message',text,completedAtMs:100}}});

test('pending_forms_keep_schema_and_mark_unknown_requests_read_only',async t=>{
  const f=await fixture(t);
  const schema={type:'object',properties:{name:{type:'string'}},required:['name']};
  f.apply(1,{id:90,method:'mcpServer/elicitation/request',params:{threadId:'thread',turnId:'turn',mode:'form',serverName:'controlled',message:'Name',requestedSchema:schema,privateCredential:'do-not-copy'}});
  f.apply(2,{id:91,method:'item/tool/call',params:{threadId:'thread',turnId:'turn',tool:'unknown',arguments:{secret:'do-not-copy'}}});
  const pending=f.store.snapshot('thread').pending;
  assert.deepEqual((pending[0]!.options as Record<string,Json>).requestedSchema,schema);
  assert.equal((pending[1]!.options as Record<string,Json>).readOnly,true);
  assert.equal(JSON.stringify(pending).includes('do-not-copy'),false);
});
const resume={thread:{id:'thread',cwd:'C:/controlled/project',name:'Controlled',preview:'Test',parentThreadId:null,status:{type:'active'},turns:[]},
  approvalPolicy:'on-request',sandbox:{type:'readOnly'},itemsBackwardsCursor:null,
  initialTurnsPage:{data:[{id:'turn',status:'inProgress',items:[],itemsView:'full'}],nextCursor:null}};

async function fixture(t:TestContext,options:{race?:boolean;unloaded?:boolean;memory?:boolean;announce?:boolean}={}) {
  const dir=await mkdtemp(join(tmpdir(),'codex-sync-'));
  const stores:Store[]=[];
  let server:Awaited<ReturnType<typeof fakeServer>>|undefined,rpc:RpcClient|undefined,sync:SyncService|undefined;
  t.after(async()=>{sync?.close();await rpc?.close();await server?.close();for(const store of stores)store.close();await rm(dir,{recursive:true,force:true});});
  const file=options.memory?':memory:':join(dir,'state.sqlite');
  const calls:string[]=[];
  const resumeParams:unknown[]=[];
  server=await fakeServer((socket,m)=>{
    if(handshake(socket,m))return;
    if(m.method==='initialized') {
      if(options.announce)socket.send(JSON.stringify({method:'thread/started',params:{thread:resume.thread}}));
      return;
    }
    calls.push(m.method!);
    if(m.method==='thread/loaded/list')socket.send(JSON.stringify({id:m.id,result:{data:options.unloaded?[]:['thread']}}));
    else if(m.method==='thread/read')socket.send(JSON.stringify({id:m.id,result:{thread:{...resume.thread,status:{type:'notLoaded'},turns:[{id:'old',status:'completed',items:[{id:'history',type:'agentMessage',text:'history'}]}]}}}));
    else if(m.method==='thread/resume') {
      resumeParams.push(m.params);
      if(options.race)socket.send(JSON.stringify(delta('pre')));
      socket.send(JSON.stringify({id:m.id,result:resume}));
      if(options.race)socket.send(JSON.stringify(delta('ha')));
    } else socket.send(JSON.stringify({id:m.id,error:{code:-32601,message:'Unexpected method'}}));
  });
  rpc=await connectRpc(server.url,'test');
  const store=openStore(file);stores.push(store);
  store.setProjects([{id:'project',name:'Controlled',path:'C:/controlled/project'}]);
  const activeSync=createSync(store,rpc);sync=activeSync;
  if(options.announce){const end=Date.now()+1000;while(!store.has('thread')&&Date.now()<end)await delay(5);assert.equal(store.has('thread'),true);}
  await sync.snapshot('thread');
  const apply=(ordinal:number,message:Json)=>activeSync.applyEvent({connectionId:'fixture',ordinal,message});
  const item=()=>store.snapshot('thread').items.find(i=>i.id==='message')!;
  return {file,store,sync:activeSync,apply,item,calls,stores,resumeParams};
}

test('announced_thread_still_attaches_before_treating_cached_state_as_live',async t=>{
  const f=await fixture(t,{announce:true});
  assert.equal(f.calls.filter(method=>method==='thread/resume').length,1);
  assert.equal(f.store.snapshot('thread').thread.activeTurnId,'turn');
});

test('paged_resume_uses_the_real_full_item_history_contract',async t=>{
  const f=await fixture(t);
  const p=f.resumeParams[0] as {excludeTurns:boolean;initialTurnsPage:{itemsView:string}};
  assert.equal(p.excludeTurns,true);
  assert.equal(p.initialTurnsPage.itemsView,'full');
});

test('snapshot_race_keeps_observed_deltas_when_actual_active_snapshot_has_no_prefix',async t=>{
  const f=await fixture(t,{race:true});await delay(20);
  assert.equal(f.item().text,'preha');
  assert.equal((f.item().data as Record<string,Json>).prefixComplete,false);
  f.apply(1,completion('canonical preha'));
  assert.equal(f.item().text,'canonical preha');
  assert.equal((f.item().data as Record<string,Json>).prefixComplete,true);
  assert.equal((await f.sync.snapshot('thread')).policy.sandbox,'readOnly');
});

test('identical_text_distinct_frames_is_preserved_but_same_source_id_is_not_reapplied',async t=>{
  const f=await fixture(t);
  f.apply(1,delta('ha'));f.apply(2,delta('ha'));f.apply(1,delta('ha'));
  assert.equal(f.item().text,'haha');
  assert.equal((f.sync.replay({epoch:f.store.cursor().epoch,seq:0}) as unknown[]).length,2);
});

test('a_buffered_source_frame_is_not_lost_after_a_later_frame_was_committed',async t=>{
  const f=await fixture(t);
  // Other observed threads can commit a later ordinal while this thread's
  // earlier frame is waiting behind its snapshot barrier.
  f.apply(2,{method:'thread/status/changed',params:{threadId:'thread',status:{type:'active'}}});
  f.apply(1,delta('retained'));
  assert.equal(f.item()?.text,'retained');
  f.apply(1,delta('retained'));
  assert.equal(f.item()?.text,'retained');
});

test('late_started_and_delta_cannot_overwrite_a_completed_item',async t=>{
  const f=await fixture(t);f.apply(1,completion('canonical'));
  f.apply(2,{method:'item/started',params:{threadId:'thread',turnId:'turn',item:{id:'message',type:'agentMessage',text:''}}});
  f.apply(3,delta('stale'));
  assert.equal(f.item().text,'canonical');
  assert.equal(f.store.snapshot('thread').items.length,1);
});

test('interruption_without_canonical_item_retains_partial_output_marker',async t=>{
  const f=await fixture(t);f.apply(1,delta('partial'));
  f.apply(2,{method:'turn/completed',params:{threadId:'thread',turn:{id:'turn',status:'interrupted',items:[]}}});
  assert.equal(f.item().text,'partial');
  assert.equal((f.item().data as Record<string,Json>).prefixComplete,false);
  assert.equal(f.store.snapshot('thread').thread.activeTurnId,null);
});

test('restart_changes_epoch_and_preserves_projection_without_trusting_old_pending_requests',async t=>{
  const f=await fixture(t);f.apply(1,delta('saved'));
  const old=f.store.cursor();f.sync.close();f.store.close();
  const restored=openStore(f.file);f.stores.push(restored);
  assert.notEqual(restored.cursor().epoch,old.epoch);
  assert.equal(restored.replay(old),'resync_required');
  assert.equal(restored.snapshot('thread').items[0]?.text,'saved');
});

test('pruned_and_future_cursors_require_resync',async t=>{
  const f=await fixture(t,{memory:true}),old=f.store.cursor();
  for(let i=1;i<=10002;i++)f.apply(i,{method:'thread/status/changed',params:{threadId:'thread',status:{type:i%2?'active':'idle',activeFlags:[]}}});
  assert.equal(f.sync.replay(old),'resync_required');
  const replay=f.sync.replay({epoch:old.epoch,seq:2});
  assert.notEqual(replay,'resync_required');assert.equal(replay.length,10000);
  assert.equal(f.sync.replay({epoch:old.epoch,seq:10003}),'resync_required');
});

test('corrupt_store_reports_error_and_does_not_replace_the_file',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'codex-corrupt-'));t.after(()=>rm(dir,{recursive:true,force:true}));
  const file=join(dir,'state.sqlite');await writeFile(file,'not SQLite');
  assert.throws(()=>openStore(file),/database|sqlite/i);
  assert.equal(await readFile(file,'utf8'),'not SQLite');
});

test('unloaded_history_reads_do_not_resume_or_start_a_task',async t=>{
  const f=await fixture(t,{unloaded:true});
  assert.deepEqual(f.calls,['thread/loaded/list','thread/read']);
  assert.equal(f.store.snapshot('thread').items[0]?.text,'history');
});

test('pending_preserves_original_rpc_id_and_resolution_is_idempotent',async t=>{
  const f=await fixture(t);
  const request:Json={method:'item/commandExecution/requestApproval',id:0,params:{threadId:'thread',turnId:'turn',itemId:'command',command:'controlled',reason:'Controlled request',availableDecisions:['accept','cancel']}};
  f.apply(1,request);f.apply(2,request);
  const pending=f.store.snapshot('thread').pending;
  assert.equal(pending.length,1);assert.equal(f.store.pending(pending[0]!.id)?.rpcId,0);
  f.apply(3,{method:'serverRequest/resolved',params:{threadId:'thread',requestId:0}});
  f.apply(4,request);
  assert.equal(f.store.snapshot('thread').pending.length,0);
});

test('claimed_pending_is_disabled_once_and_authoritative_resolution_clears_it',async t=>{
  const f=await fixture(t),connectionId=f.sync.connectionId;
  f.sync.applyEvent({connectionId,ordinal:1,message:{method:'item/commandExecution/requestApproval',id:77,params:{threadId:'thread',turnId:'turn',availableDecisions:['accept']}}});
  const id=f.store.snapshot('thread').pending[0]!.id;
  assert.equal(f.sync.claimPending(id).record.state,'unknown');
  assert.throws(()=>f.sync.claimPending(id));
  f.sync.applyEvent({connectionId,ordinal:2,message:{method:'serverRequest/resolved',params:{threadId:'thread',requestId:77}}});
  assert.equal(f.store.snapshot('thread').pending.length,0);
});

test('unknown_activity_is_readable_without_copying_arbitrary_unknown_fields',async t=>{
  const f=await fixture(t);
  f.apply(1,{method:'item/futureTool/changed',params:{threadId:'thread',turnId:'turn',secretField:'do-not-copy'}});
  const item=f.store.snapshot('thread').items[0]!;
  assert.equal(item.kind,'unknown');assert.ok(item.text.length>0);
  assert.equal(JSON.stringify(item).includes('do-not-copy'),false);
});
