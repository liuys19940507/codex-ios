import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openStore } from '../src/state/store.js';
import { createSync } from '../src/state/sync.js';
import { createQueries } from '../src/api/queries.js';
import { connectRpc } from '../src/protocol/rpc-client.js';
import { ApiError } from '../src/api/validation.js';
import { fakeServer, handshake } from './support/fake-server.js';

async function fixture(t:TestContext) {
  const dir=await mkdtemp(join(tmpdir(),'codex-query-')),calls:{method:string;params:any}[]=[];
  const projects=[{id:'project',name:'Controlled',path:'C:/controlled/project'}];
  const parent={id:'parent',cwd:projects[0]!.path,name:'Parent',preview:'',status:{type:'notLoaded'},parentThreadId:null,turns:[]};
  const child={...parent,id:'child',name:'Child',parentThreadId:'parent'};
  const foreign={...parent,id:'foreign',cwd:'C:/outside',name:'private foreign title'};
  const server=await fakeServer((socket,m)=>{
    if(handshake(socket,m)||m.method==='initialized')return;
    calls.push({method:m.method!,params:m.params});
    const p=m.params as any;
    const result=m.method==='thread/list'?{data:[parent,child,foreign],nextCursor:p.cursor?null:'next'}:
      m.method==='thread/loaded/list'?{data:[]}:
      m.method==='thread/read'?{thread:{...(p.threadId==='foreign'?foreign:parent),turns:p.includeTurns?[{id:'turn-old',status:'completed',items:Array.from({length:75},(_,i)=>({id:`item-${i}`,type:'agentMessage',text:`history ${i}`}))}]:[]},secretField:'do-not-expose'}:
      m.method==='model/list'?{data:[{id:'catalog-id',model:'available-model',displayName:'Available',hidden:false,supportedReasoningEfforts:[{reasoningEffort:'medium'}]}],nextCursor:null}:{};
    socket.send(JSON.stringify({id:m.id,result}));
  });
  const rpc=await connectRpc(server.url,'test'),store=openStore(join(dir,'state.sqlite')),sync=createSync(store,rpc);
  t.after(async()=>{sync.close();await rpc.close();await server.close();store.close();await rm(dir,{recursive:true,force:true});});
  const queries=createQueries({rpc,store,sync,projects});return {queries,calls,store};
}

test('project_scoped_listing_filters_foreign_threads_and_keeps_child_parent_identity',async t=>{
  const f=await fixture(t),page=await f.queries.queryThreads({projectId:'project',query:'Parent'});
  assert.deepEqual(page.data.map(thread=>thread.id),['parent','child']);
  assert.equal(page.data[1]?.parentId,'parent');
  assert.equal(JSON.stringify(page).includes('private foreign title'),false);
  const params=f.calls.find(c=>c.method==='thread/list')!.params;
  assert.deepEqual(params.cwd,['C:/controlled/project']);assert.equal(params.searchTerm,'Parent');
  assert.ok(params.sourceKinds.includes('subAgentThreadSpawn'));
});

test('unconfigured_project_is_rejected_before_reading_upstream',async t=>{
  const f=await fixture(t);
  await assert.rejects(f.queries.queryThreads({projectId:'not-configured'}),(e:unknown)=>e instanceof ApiError&&e.status===404);
  assert.equal(f.calls.length,0);
});

test('thread_cursor_is_bound_to_project_and_search_filter',async t=>{
  const f=await fixture(t),page=await f.queries.queryThreads({projectId:'project',query:'same'});
  assert.ok(page.nextCursor);
  await f.queries.queryThreads({projectId:'project',query:'same',cursor:page.nextCursor!});
  assert.equal(f.calls.filter(c=>c.method==='thread/list')[1]!.params.cursor,'next');
  await assert.rejects(f.queries.queryThreads({projectId:'project',query:'different',cursor:page.nextCursor!}),(e:unknown)=>e instanceof ApiError&&e.status===400);
});

test('history_is_read_only_and_only_known_policy_fields_are_exposed',async t=>{
  const f=await fixture(t),snapshot=await f.queries.querySnapshot('parent');
  assert.equal(f.calls.some(c=>['thread/resume','thread/start','turn/start'].includes(c.method)),false);
  assert.deepEqual(snapshot.policy,{approvalPolicy:null,sandbox:null});
  assert.equal(JSON.stringify(snapshot).includes('secretField'),false);
});

test('snapshot_and_history_pages_are_bounded_and_have_no_duplicate_anchor',async t=>{
  const f=await fixture(t),snapshot=await f.queries.querySnapshot('parent');
  assert.equal(snapshot.items.length,50);assert.ok(snapshot.itemsCursor);
  const page=await f.queries.queryItems('parent',snapshot.itemsCursor!);
  assert.equal(page.data.length,25);assert.equal(page.nextCursor,null);
  const ids=[...page.data,...snapshot.items].map(item=>item.id);
  assert.equal(new Set(ids).size,75);
});

test('foreign_thread_snapshot_is_rejected_without_resuming_it',async t=>{
  const f=await fixture(t);
  await assert.rejects(f.queries.querySnapshot('foreign'),(e:unknown)=>e instanceof ApiError&&e.status===404);
  assert.equal(f.calls.some(c=>c.method==='thread/resume'),false);
});

test('model_choices_use_real_request_ids_and_server_reasoning_choices',async t=>{
  const f=await fixture(t);
  assert.deepEqual(await f.queries.queryModels(),[{id:'available-model',name:'Available',reasoning:['medium']}]);
});
