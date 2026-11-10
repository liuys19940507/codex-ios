import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { openStore } from '../src/state/store.js';
import { createSync } from '../src/state/sync.js';
import { createOperations } from '../src/state/operations.js';
import { createQueries } from '../src/api/queries.js';
import { createCommands } from '../src/api/commands.js';
import { ApiError } from '../src/api/validation.js';
import { connectRpc } from '../src/protocol/rpc-client.js';
import { fakeServer, handshake } from './support/fake-server.js';
import type { Command } from '../src/api/contracts.js';

const command=(method:Command['method'],params:Command['params']):Command=>({id:randomUUID(),method,params});

test('attachment_commands_are_scoped_idempotent_and_do_not_interrupt_work',async t=>{
  const f=await fixture(t);const attachmentId=randomUUID();
  const attach=command('thread/attach',{threadId:'thread',attachmentId});
  assert.equal((await f.commands.dispatch(attach)).state,'accepted');
  const count=f.calls.filter(c=>c.method==='thread/resume').length;
  assert.equal((await f.commands.dispatch(attach)).state,'accepted');
  assert.equal(f.calls.filter(c=>c.method==='thread/resume').length,count);
  assert.equal((await f.commands.dispatch(command('thread/release',{threadId:'thread',attachmentId}))).state,'accepted');
  assert.equal(f.calls.filter(c=>c.method==='thread/unsubscribe').length,1);
  assert.equal(f.calls.some(c=>['turn/interrupt','thread/archive'].includes(c.method)),false);
  await assert.rejects(f.commands.dispatch(command('thread/attach',{threadId:'thread',attachmentId:'invalid'})),/UUID/);
});
async function fixture(t:TestContext,options:{active?:boolean;dropCreate?:boolean;streamStart?:boolean}={}) {
  const dir=await mkdtemp(join(tmpdir(),'codex-command-')),projects=[{id:'project',name:'Controlled',path:'C:/controlled/project'}];
  const active=options.active??true;
  let loaded=active;
  const thread={id:'thread',cwd:projects[0]!.path,name:'Controlled',status:{type:active?'active':'idle'},turns:active?[{id:'turn',status:'inProgress',items:[]}]:[]};
  const calls:{method:string;params:any}[]=[],responses:{id:unknown;result:unknown}[]=[];
  let emit:(message:unknown)=>void=()=>{throw new Error('No socket');};
  const server=await fakeServer((socket,m)=>{
    emit=message=>socket.send(JSON.stringify(message));
    if(handshake(socket,m)||m.method==='initialized')return;
    if(m.method===undefined&&'result' in m) {
      responses.push({id:m.id,result:m.result});
      socket.send(JSON.stringify({method:'serverRequest/resolved',params:{threadId:'thread',requestId:m.id}}));return;
    }
    calls.push({method:m.method!,params:m.params});
    const p=m.params as any;
    if(options.dropCreate&&m.method==='turn/start'){socket.terminate();return;}
    if(m.method==='thread/resume')loaded=true;
    const result=m.method==='thread/loaded/list'?{data:loaded?['thread']:[]}:
      m.method==='thread/read'?{thread}:
      m.method==='thread/resume'?{thread,initialTurnsPage:{data:thread.turns},approvalPolicy:'on-request',sandbox:{type:'readOnly'}}:
      m.method==='thread/start'?{thread:{...thread,id:'created'}}:
      m.method==='turn/start'?{turn:{id:'new-turn'}}:
      m.method==='turn/steer'?{turnId:p.expectedTurnId}:
      m.method==='model/list'?{data:[{model:'supported',displayName:'Supported',supportedReasoningEfforts:[{reasoningEffort:'medium'}]}]}:{};
    socket.send(JSON.stringify({id:m.id,result}));
    if(options.streamStart&&m.method==='turn/start') {
      socket.send(JSON.stringify({method:'turn/started',params:{threadId:'thread',turn:{id:'new-turn',status:'inProgress',items:[]}}}));
      socket.send(JSON.stringify({method:'item/agentMessage/delta',params:{threadId:'thread',turnId:'new-turn',itemId:'live-first',delta:'live first output'}}));
    }
  });
  const rpc=await connectRpc(server.url,'test'),store=openStore(join(dir,'state.sqlite')),sync=createSync(store,rpc);
  const operations=createOperations(store),queries=createQueries({rpc,store,sync,projects});
  const features={steer:true,queue:false,approvals:true,interrupt:true,fileApprovals:false,permissions:false,questions:false,mcp:false};
  const commands=createCommands({rpc,store,sync,operations,queries,projects,features});
  t.after(async()=>{sync.close();await rpc.close();await server.close();store.close();await rm(dir,{recursive:true,force:true});});
  await queries.querySnapshot('thread');
  async function pending() {
    emit({id:77,method:'item/commandExecution/requestApproval',params:{threadId:'thread',turnId:'turn',itemId:'shell',command:'controlled',availableDecisions:['accept','cancel']}});
    const deadline=Date.now()+1000;
    while(!store.snapshot('thread').pending.length&&Date.now()<deadline)await delay(5);
    return store.snapshot('thread').pending[0]!;
  }
  return {commands,calls,responses,store,features,pending,emit};
}

test('unconfigured_project_and_policy_override_are_rejected_before_task_creation',async t=>{
  const f=await fixture(t);
  await assert.rejects(f.commands.dispatch(command('task/create',{projectId:'outside',text:'test'})),(e:unknown)=>e instanceof ApiError&&e.status===404);
  await assert.rejects(f.commands.dispatch(command('task/create',{projectId:'project',text:'test',approvalPolicy:'never'})),(e:unknown)=>e instanceof ApiError&&e.status===400);
  assert.equal(f.calls.filter(c=>c.method==='thread/start').length,0);
});

test('steer_pins_current_turn_and_does_not_override_existing_policy',async t=>{
  const f=await fixture(t);
  await assert.rejects(f.commands.dispatch(command('task/input',{threadId:'thread',text:'next',mode:'steer',expectedTurnId:'old-turn'})),(e:unknown)=>e instanceof ApiError&&e.status===409);
  const result=await f.commands.dispatch(command('task/input',{threadId:'thread',text:'中文;&$',mode:'steer',expectedTurnId:'turn'}));
  assert.equal(result.state,'accepted');
  const request=f.calls.find(c=>c.method==='turn/steer')!.params;
  assert.equal(request.expectedTurnId,'turn');assert.equal(request.input[0].text,'中文;&$');
  assert.equal('approvalPolicy' in request,false);assert.equal('sandboxPolicy' in request,false);
});

test('unsupported_queue_and_active_turn_start_fail_without_sending_input',async t=>{
  const f=await fixture(t);
  for(const mode of ['queue','start'])await assert.rejects(f.commands.dispatch(command('task/input',{threadId:'thread',text:'keep as draft',mode})),(e:unknown)=>e instanceof ApiError&&e.status===409);
  assert.equal(f.calls.filter(c=>c.method==='turn/start').length,0);
});

test('approval_uses_original_rpc_id_and_only_offered_decisions',async t=>{
  const f=await fixture(t),pending=await f.pending();
  await assert.rejects(f.commands.dispatch(command('request/respond',{requestId:pending.id,threadId:'thread',turnId:'turn',response:{decision:'acceptForSession'}})),(e:unknown)=>e instanceof ApiError&&e.status===400);
  const c=command('request/respond',{requestId:pending.id,threadId:'thread',turnId:'turn',response:{decision:'accept'}});
  const first=await f.commands.dispatch(c),again=await f.commands.dispatch(c);
  assert.equal(first.state,'accepted');assert.deepEqual(again,first);
  assert.deepEqual(f.responses,[{id:77,result:{decision:'accept'}}]);
  assert.equal(f.store.snapshot('thread').pending.length,0);
  await assert.rejects(f.commands.dispatch({...c,id:randomUUID()}),(e:unknown)=>e instanceof ApiError&&e.status===409);
});

test('expired_or_wrong_turn_approval_conflicts_without_responding',async t=>{
  const f=await fixture(t),pending=await f.pending();
  await assert.rejects(f.commands.dispatch(command('request/respond',{requestId:pending.id,threadId:'thread',turnId:'wrong',response:{decision:'accept'}})),(e:unknown)=>e instanceof ApiError&&e.status===409);
  f.emit({method:'serverRequest/resolved',params:{threadId:'thread',requestId:77}});
  await delay(20);
  await assert.rejects(f.commands.dispatch(command('request/respond',{requestId:pending.id,threadId:'thread',turnId:'turn',response:{decision:'accept'}})),(e:unknown)=>e instanceof ApiError&&e.status===409);
  assert.equal(f.responses.length,0);
});

test('history_is_resumed_only_when_user_explicitly_sends_input',async t=>{
  const f=await fixture(t,{active:false});assert.equal(f.calls.some(c=>c.method==='thread/resume'),false);
  const result=await f.commands.dispatch(command('task/input',{threadId:'thread',text:'continue',mode:'start'}));
  assert.equal(result.state,'accepted');assert.equal(f.calls.filter(c=>c.method==='thread/resume').length,1);
  const resumed=f.calls.find(c=>c.method==='thread/resume')!.params;
  assert.equal('approvalPolicy' in resumed,false);assert.equal('sandbox' in resumed,false);
});

test('explicit_history_input_activates_subscription_before_start_without_a_client_refresh',async t=>{
  const f=await fixture(t,{active:false,streamStart:true});
  const result=await f.commands.dispatch(command('task/input',{threadId:'thread',text:'continue',mode:'start'}));
  assert.equal(result.state,'accepted');
  for(const end=Date.now()+500;Date.now()<end&&f.store.snapshot('thread').thread.activeTurnId!=='new-turn';)await delay(5);
  assert.equal(f.store.snapshot('thread').thread.activeTurnId,'new-turn');
  assert.equal(f.store.snapshot('thread').items.find(item=>item.id==='live-first')?.text,'live first output');
  assert.equal(f.calls.filter(c=>c.method==='thread/resume').length,1);
});

test('create_partial_failure_keeps_created_thread_without_creating_another',async t=>{
  const f=await fixture(t,{dropCreate:true});
  const c=command('task/create',{projectId:'project',text:'controlled'}),result=await f.commands.dispatch(c);
  assert.equal(result.state,'unknown');assert.deepEqual(result.result,{threadId:'created'});
  assert.deepEqual(await f.commands.dispatch(c),result);
  assert.equal(f.calls.filter(c=>c.method==='thread/start').length,1);
});

test('unsupported_model_and_reasoning_are_rejected_before_creation',async t=>{
  const f=await fixture(t);
  const cases:Command['params'][]=[{model:'not-supported'},{model:'supported',reasoning:'not-supported'}];
  for(const params of cases) {
    await assert.rejects(f.commands.dispatch(command('task/create',{projectId:'project',text:'controlled',...params})),(e:unknown)=>e instanceof ApiError&&e.status===400);
  }
  assert.equal(f.calls.filter(c=>c.method==='thread/start').length,0);
});
