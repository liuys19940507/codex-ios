import type { Command, Json, Operation, Snapshot } from './contracts.js';
import { ApiError, requireProject, validateCommand } from './validation.js';
import type { RuntimeConfig } from '../runtime/config.js';
import type { RpcClient } from '../protocol/rpc-client.js';
import type { Store } from '../state/store.js';
import type { SyncService } from '../state/sync.js';
import type { Queries } from './queries.js';
import { type Operations, UncertainOperationError } from '../state/operations.js';
import { object } from '../state/reducer.js';
import { validatePendingResponse } from './responses.js';

type Context={rpc:RpcClient;store:Store;sync:SyncService;operations:Operations;queries:Queries;projects:RuntimeConfig['projects'];features:Record<string,boolean>};
export function createCommands(context:Context) {
  const {rpc,store,sync,operations,queries,projects,features}=context;
  const conflict=(message:string):never=>{throw new ApiError(409,'state_conflict',message);};
  const capability=(name:string):void=>{if(!features[name])throw new ApiError(409,'capability_unavailable',`${name} is not enabled by this server`);};
  const input=(text:Json|undefined)=>[{type:'text',text:String(text),text_elements:[]}];
  function responseFor(command:Command,snapshot:Snapshot) {
    const p=command.params,stored=store.pending(String(p.requestId));
    if(!stored)throw new ApiError(409,'request_expired','This request is no longer valid');
    if(stored.connectionId!==sync.connectionId||stored.record.state!=='pending'||stored.record.threadId!==p.threadId||stored.record.turnId!==p.turnId||snapshot.thread.activeTurnId!==p.turnId)conflict('This request is no longer valid for the current turn');
    return validatePendingResponse(stored.record,p.response!,features);
  }
  async function dispatch(raw:Command):Promise<Operation> {
    const command=validateCommand(raw),p=command.params;
    const existing=operations.lookup(command);if(existing)return existing;
    if(command.method==='thread/attach'||command.method==='thread/release') {
      const threadId=String(p.threadId),attachmentId=String(p.attachmentId);
      await queries.authorizeThread(threadId);
      return operations.executeOnce(command,async()=>command.method==='thread/attach'
        ?{readOnlyReason:(await sync.attach(threadId,attachmentId)).readOnlyReason??null}
        :sync.release(threadId,attachmentId));
    }
    let snapshot:Snapshot|undefined;
    if(command.method==='task/create') {
      requireProject(await queries.queryProjects(),String(p.projectId));
      if(p.reasoning&&!p.model)throw new ApiError(400,'invalid_model','Select a model before its reasoning effort');
      if(p.model) {
        const model=(await queries.queryModels()).find(model=>model.id===p.model);
        if(!model||p.reasoning&&!model.reasoning.includes(String(p.reasoning)))throw new ApiError(400,'invalid_model','Model or reasoning effort is not in the server catalog');
      }
    } else {
      snapshot=await queries.querySnapshot(String(p.threadId));
      if(snapshot.readOnlyReason)throw new ApiError(409,'thread_busy',snapshot.readOnlyReason);
      if(command.method==='task/input') {
        if(p.mode==='queue')capability('queue');
        if(p.mode==='steer'){capability('steer');if(snapshot.thread.activeTurnId!==p.expectedTurnId)conflict('The active turn changed; refresh before steering');}
        if(p.mode==='start'&&snapshot.thread.activeTurnId)conflict('A turn is already running; steer it or keep this input as a draft');
      } else if(command.method==='task/interrupt') {
        capability('interrupt');if(snapshot.thread.activeTurnId!==p.turnId)conflict('The requested turn is no longer active');
      } else if(command.method==='request/respond')responseFor(command,snapshot);
      else if(command.method==='thread/archive'&&snapshot.thread.activeTurnId)conflict('Interrupt the active turn before archiving');
    }
    return operations.executeOnce(command,async()=>{
      if(command.method==='task/create') {
        const project=requireProject(await queries.queryProjects(),String(p.projectId));
        const started=object(await rpc.request('thread/start',{cwd:project.path,...(p.model?{model:p.model}:{})}));
        const threadId=object(started.thread).id;
        if(typeof threadId!=='string')throw new Error('Thread creation response has no identity');
        try {
          const response=object(await rpc.request('turn/start',{threadId,input:input(p.text),...(p.model?{model:p.model}:{}),...(p.reasoning?{effort:p.reasoning}:{})}));
          return {threadId,turnId:String(object(response.turn).id)};
        } catch {throw new UncertainOperationError('Thread exists, but its first turn was not confirmed',{threadId});}
      }
      const threadId=String(p.threadId);
      if(command.method==='task/input') {
        if(p.mode==='steer')return rpc.request('turn/steer',{threadId,expectedTurnId:p.expectedTurnId!,input:input(p.text)});
        if(p.mode==='queue')throw new ApiError(409,'capability_unavailable','Queue adapter is not validated');
        const resumed=await sync.resumeForWrite(threadId);
        if(resumed.thread.activeTurnId||resumed.thread.status==='active')conflict('Another client has started a turn; refresh before sending');
        const response=object(await rpc.request('turn/start',{threadId,input:input(p.text)}));
        return {threadId,turnId:String(object(response.turn).id)};
      }
      if(command.method==='task/interrupt')return rpc.request('turn/interrupt',{threadId,turnId:p.turnId!});
      if(command.method==='thread/rename')return rpc.request('thread/name/set',{threadId,name:p.title!});
      if(command.method==='thread/archive')return rpc.request('thread/archive',{threadId});
      const response=responseFor(command,store.snapshot(threadId));
      const pending=sync.claimPending(String(p.requestId));
      return new Promise<Json>((resolve,reject)=>{
        const timeout=setTimeout(()=>{unsubscribe();reject(new UncertainOperationError('Approval response was sent without confirmation',{requestId:pending.record.id}));},3000);
        const unsubscribe=sync.onEvent(event=>{
          if(event.type==='pending/resolved'&&object(event.data).id===pending.record.id) {
            clearTimeout(timeout);unsubscribe();resolve({requestId:pending.record.id,resolved:true});
          }
        });
        try{rpc.respond(pending.rpcId,response as Json);}catch(error){clearTimeout(timeout);unsubscribe();reject(error);}
      });
    });
  }
  return {dispatch};
}
export type Commands=ReturnType<typeof createCommands>;
