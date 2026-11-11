import { createHash } from 'node:crypto';
import type { Item, Snapshot, ThreadSummary } from './contracts.js';
import { ApiError, requireProject } from './validation.js';
import type { RuntimeConfig } from '../runtime/config.js';
import type { RpcClient } from '../protocol/rpc-client.js';
import type { Store } from '../state/store.js';
import type { SyncService } from '../state/sync.js';
import { object, projectItem, summary } from '../state/reducer.js';
import { createProjectCatalog, sourceKinds } from './project-catalog.js';
import { encodeTurnsBoundary, decodeTurnsBoundary } from '../state/history-boundary.js';

export type QueryContext={rpc:RpcClient;store:Store;sync:SyncService;projects:RuntimeConfig['projects'];discoverProjects?:boolean};
export {sourceKinds};
const encode=(value:unknown)=>Buffer.from(JSON.stringify(value)).toString('base64url');
function decode(cursor:string):Record<string,any> {
  try {
    if(cursor.length>16384)throw new Error();
    const result=JSON.parse(Buffer.from(cursor,'base64url').toString('utf8'));
    if(!result||typeof result!=='object'||Array.isArray(result))throw new Error();
    return result;
  } catch {throw new ApiError(400,'invalid_cursor','Invalid history or list cursor');}
}
export function createQueries(context:QueryContext) {
  const {rpc,store,sync,projects}=context;store.setProjects(projects);
  const catalog=createProjectCatalog(rpc,projects,context.discoverProjects);
  async function refreshProjects() {const result=await catalog.refresh();store.setProjects(result);return result;}
  async function authorizeThread(threadId:string):Promise<Record<string,any>> {
    if(!threadId||threadId.length>256)throw new ApiError(400,'invalid_request','Invalid thread id');
    const response=object(await rpc.requestAtBarrier('thread/read',{threadId,includeTurns:false},value=>{
      const thread=object(object(value).thread);
      // Apply metadata at the read response boundary, before a following live
      // rename event. Scope failures are rejected below without failing RPC.
      if(thread.id===threadId&&store.project(String(thread.cwd??'')))sync.refreshMetadata(thread);
    })),thread=object(response.thread);
    if(thread.id!==threadId)throw new ApiError(503,'upstream_invalid','Thread identity mismatch');
    if(context.discoverProjects) {catalog.includeDirectory(thread.cwd);store.setProjects(catalog.all());}
    summary(thread,store);return thread;
  }
  async function queryThreads(input:{projectId?:string;query?:string;cursor?:string}={}) {
    const available=context.discoverProjects?await refreshProjects():catalog.all();
    const selected=input.projectId?[requireProject(available,input.projectId)]:available;
    const query=input.query??'';
    if(Buffer.byteLength(query,'utf8')>1024)throw new ApiError(400,'invalid_request','Search text is too long');
    const filter=createHash('sha256').update(JSON.stringify([input.projectId??null,query])).digest('hex');
    let cursor:string|null=null;
    if(input.cursor) {
      const value=decode(input.cursor);
      if(value.kind!=='threads'||value.filter!==filter||typeof value.cursor!=='string')throw new ApiError(400,'invalid_cursor','Cursor belongs to another search');
      cursor=value.cursor;
    }
    const result=object(await rpc.request('thread/list',{...(!context.discoverProjects||input.projectId?{cwd:selected.map(project=>project.path)}:{}),searchTerm:query||null,cursor,limit:50,
      sortKey:'updated_at',sortDirection:'desc',sourceKinds,modelProviders:[],useStateDbOnly:true}));
    const data:ThreadSummary[]=[];
    for(const raw of Array.isArray(result.data)?result.data:[]) {
      const thread=object(raw);
      if(context.discoverProjects){catalog.includeDirectory(thread.cwd);store.setProjects(catalog.all());}
      const project=store.project(String(thread.cwd??''));
      if(!project||(!context.discoverProjects||input.projectId)&&!selected.some(p=>p.id===project.id))continue;
      data.push(summary(thread,store));
    }
    return {data,nextCursor:typeof result.nextCursor==='string'?encode({kind:'threads',filter,cursor:result.nextCursor}):null};
  }
  function historyCursor(snapshot:Snapshot,items:Item[],upstream:string|null):string|null {
    return items.length>50?encode({kind:'local',threadId:snapshot.thread.id,epoch:snapshot.cursor.epoch,anchor:items[items.length-50]!.id,upstream}):
      upstream?encode({kind:'upstream',threadId:snapshot.thread.id,epoch:snapshot.cursor.epoch,cursor:upstream,
        ...(decodeTurnsBoundary(upstream)!==null?{anchor:items[0]?.id??snapshot.items[0]?.id??null}:{})}):null;
  }
  async function querySnapshot(threadId:string):Promise<Snapshot> {
    await authorizeThread(threadId);
    const snapshot=await sync.snapshot(threadId);
    return {...snapshot,items:snapshot.items.slice(-50),itemsCursor:historyCursor(snapshot,snapshot.items,snapshot.itemsCursor)};
  }
  async function queryItems(threadId:string,cursor?:string):Promise<{data:Item[];nextCursor:string|null}> {
    await authorizeThread(threadId);
    const snapshot=await sync.snapshot(threadId);
    if(!cursor)return {data:snapshot.items.slice(-50),nextCursor:historyCursor(snapshot,snapshot.items,snapshot.itemsCursor)};
    const value=decode(cursor);
    if(value.threadId!==threadId||value.epoch!==snapshot.cursor.epoch)throw new ApiError(409,'resync_required','History changed; reload the snapshot');
    if(value.kind==='local'&&typeof value.anchor==='string') {
      const before=snapshot.items.findIndex(item=>item.id===value.anchor);
      if(before<0)throw new ApiError(409,'resync_required','History anchor is no longer available');
      const items=snapshot.items.slice(0,before);
      const old=typeof value.upstream==='string'?value.upstream:null;
      const boundary=old&&decodeTurnsBoundary(old)!==null?snapshot.itemsCursor:old;
      return {data:items.slice(-50),nextCursor:historyCursor(snapshot,items,boundary)};
    }
    if(value.kind!=='upstream'||typeof value.cursor!=='string')throw new ApiError(400,'invalid_cursor','Invalid item cursor');
    if(decodeTurnsBoundary(value.cursor)!==null)return olderTurns(threadId,value);
    const response=object(await rpc.request('thread/items/list',{threadId,cursor:value.cursor,limit:50,sortDirection:'desc'}));
    if(store.cursor().epoch!==value.epoch)throw new ApiError(409,'resync_required','History changed; reload the snapshot');
    const data=(Array.isArray(response.data)?response.data:[]).map(raw=>{
      const entry=object(raw),item=object(entry.item);
      return projectItem(item,String(entry.turnId),entry.completedAtMs!=null||item.completedAtMs!=null||['completed','failed','declined'].includes(String(item.status)));
    }).reverse();
    return {data,nextCursor:typeof response.nextCursor==='string'?encode({...value,cursor:response.nextCursor}):null};
  }
  async function olderTurns(threadId:string,value:Record<string,any>):Promise<{data:Item[];nextCursor:string|null}> {
    if(value.anchor!==null&&typeof value.anchor!=='string')throw new ApiError(400,'invalid_cursor','Missing history anchor');
    for(let attempt=0;attempt<20;attempt++) {
      const current=store.snapshot(threadId);
      if(current.cursor.epoch!==value.epoch)throw new ApiError(409,'resync_required','History changed; reload the snapshot');
      const index=value.anchor===null?current.items.length:current.items.findIndex(item=>item.id===value.anchor);
      if(index<0)throw new ApiError(409,'resync_required','History anchor is no longer available');
      if(index>0) {
        const items=current.items.slice(0,index);
        return {data:items.slice(-50),nextCursor:historyCursor(current,items,current.itemsCursor)};
      }
      if(current.itemsCursor===null)return {data:[],nextCursor:null};
      const boundary=current.itemsCursor,nativeCursor=decodeTurnsBoundary(boundary);
      if(nativeCursor===null)throw new ApiError(409,'resync_required','History source changed; reload the snapshot');
      const response=object(await rpc.request('thread/turns/list',{threadId,cursor:nativeCursor,limit:1,sortDirection:'desc',itemsView:'full'}));
      if(!Array.isArray(response.data)||!(response.nextCursor===null||typeof response.nextCursor==='string')||response.nextCursor===nativeCursor)
        throw new ApiError(503,'upstream_invalid','History pagination did not advance');
      const fetched:Item[]=[];
      for(const raw of [...response.data].reverse()) {
        const turn=object(raw);
        if(typeof turn.id!=='string'||!Array.isArray(turn.items))throw new ApiError(503,'upstream_invalid','Invalid history turn');
        for(const rawItem of turn.items) {
          const item=object(rawItem);
          if(typeof item.id!=='string'||!item.id)throw new ApiError(503,'upstream_invalid','Invalid history item');
          fetched.push(projectItem(item,turn.id,turn.status==='completed'||item.completedAtMs!=null||['completed','failed','declined'].includes(String(item.status))));
        }
      }
      // Read again after RPC: live deltas/metadata may have changed the cache.
      const fresh=store.snapshot(threadId),known=new Set(fresh.items.map(item=>item.id));
      if(fresh.cursor.epoch!==value.epoch)throw new ApiError(409,'resync_required','History changed; reload the snapshot');
      const added=new Map(fetched.filter(item=>!known.has(item.id)).map(item=>[item.id,item]));
      const merged:Snapshot={...fresh,items:[...added.values(),...fresh.items],
        itemsCursor:fresh.itemsCursor===boundary?encodeTurnsBoundary(response.nextCursor):fresh.itemsCursor};
      store.atomic(()=>store.putSnapshot(merged));
    }
    const current=store.snapshot(threadId);
    const index=value.anchor===null?current.items.length:current.items.findIndex(item=>item.id===value.anchor);
    if(index<0)throw new ApiError(409,'resync_required','History anchor is no longer available');
    const items=current.items.slice(0,index);
    return {data:items.slice(-50),nextCursor:historyCursor(current,items,current.itemsCursor)};
  }
  async function queryModels():Promise<{id:string;name:string;reasoning:string[]}[]> {
    const models:{id:string;name:string;reasoning:string[]}[]=[];let cursor:string|null=null;
    for(let page=0;page<10;page++) {
      const response=object(await rpc.request('model/list',{cursor,limit:100}));
      for(const raw of Array.isArray(response.data)?response.data:[]) {
        const m=object(raw);
        if(m.hidden||typeof m.model!=='string')continue;
        models.push({id:m.model,name:String(m.displayName??m.model),reasoning:(Array.isArray(m.supportedReasoningEfforts)?m.supportedReasoningEfforts:[])
          .map((effort:unknown)=>object(effort).reasoningEffort).filter((effort:unknown):effort is string=>typeof effort==='string')});
      }
      if(typeof response.nextCursor!=='string')return models;
      if(response.nextCursor===cursor)throw new ApiError(503,'upstream_invalid','Model pagination did not advance');
      cursor=response.nextCursor;
    }
    throw new ApiError(503,'upstream_invalid','Model catalog exceeded its page limit');
  }
  async function queryMetadata(threadId:string):Promise<ThreadSummary> {
    // Pin refresh must never call Sync.snapshot: that can subscribe to a
    // loaded thread and retain its writer independently of the selected view.
    return summary(await authorizeThread(threadId),store);
  }
  return {queryThreads,queryMetadata,querySnapshot,queryItems,queryModels,authorizeThread,queryProjects:()=>context.discoverProjects?refreshProjects():catalog.all()};
}
export type Queries=ReturnType<typeof createQueries>;
