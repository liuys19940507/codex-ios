import { randomUUID } from 'node:crypto';
import type { Cursor, Envelope, Item, Json, Pending, Snapshot } from '../api/contracts.js';
import { ApiError } from '../api/validation.js';
import type { RpcClient } from '../protocol/rpc-client.js';
import type { Store } from './store.js';
import { object, projectItem, summary } from './reducer.js';

export type SourceEvent={connectionId:string;ordinal:number;message:Json};
export class SyncService {
  readonly connectionId=randomUUID();
  private ordinal=0;
  private readonly ready=new Set<string>();
  private readonly inflight=new Map<string,Promise<Snapshot>>();
  private readonly buffers=new Map<string,SourceEvent[]>();
  private readonly listeners=new Set<(event:Envelope)=>void>();
  private readonly unsubscribe:()=>void;
  constructor(private readonly store:Store,private readonly rpc:RpcClient) {
    this.unsubscribe=rpc.onEvent(message=>{
      const p=object(object(message).params),threadId=String(p.threadId??object(p.thread).id??'');
      if(!threadId)return;
      const frame={connectionId:this.connectionId,ordinal:++this.ordinal,message};
      const buffer=this.buffers.get(threadId);
      if(buffer) {
        if(buffer.length>=2000)throw new Error('Snapshot event buffer exceeded');
        buffer.push(frame);
      } else if(this.ready.has(threadId))this.applyEvent(frame);
      else if(object(message).method==='thread/started'&&this.store.project(String(object(p.thread).cwd??''))) {
        this.install({thread:p.thread});this.ready.add(threadId);this.applyEvent(frame);
      } else this.store.atomic(()=>this.store.markSource(frame.connectionId,frame.ordinal));
    });
  }
  onEvent(handler:(event:Envelope)=>void):()=>void {this.listeners.add(handler);return ()=>this.listeners.delete(handler);}
  replay(cursor:Cursor):Envelope[]|'resync_required' {return this.store.replay(cursor);}
  close():void {this.unsubscribe();this.listeners.clear();}
  snapshot(threadId:string):Promise<Snapshot> {
    if(this.ready.has(threadId))return Promise.resolve(this.store.snapshot(threadId));
    const active=this.inflight.get(threadId);if(active)return active;
    this.buffers.set(threadId,[]);
    const work=this.bootstrap(threadId).finally(()=>{this.inflight.delete(threadId);this.buffers.delete(threadId);});
    this.inflight.set(threadId,work);return work;
  }
  private async bootstrap(threadId:string):Promise<Snapshot> {
    const loaded=object(await this.rpc.request('thread/loaded/list',{}));
    const isLoaded=Array.isArray(loaded.data)&&loaded.data.includes(threadId);
    const apply=(value:Json)=>{
      const snap=this.install(value);
      if(snap.thread.id!==threadId)throw new ApiError(503,'upstream_invalid','Snapshot identity mismatch');
      const ids=new Set(snap.items.map(item=>item.id));
      const buffered=this.buffers.get(threadId)??[];
      this.buffers.delete(threadId);this.ready.add(threadId);
      for(const frame of buffered) {
        const msg=object(frame.message),p=object(msg.params),id=String(p.itemId??object(p.item).id??'');
        // Canonical snapshot items already include pre-barrier changes. In the
        // actual active-agent case the item is absent, so retain observed frames.
        if((String(msg.method).startsWith('item/')&&!ids.has(id))||'id' in msg||msg.method==='serverRequest/resolved')this.applyEvent(frame);
        else this.store.atomic(()=>this.store.markSource(frame.connectionId,frame.ordinal));
      }
    };
    if(isLoaded)await this.rpc.requestAtBarrier('thread/resume',{threadId,excludeTurns:true,initialTurnsPage:{limit:20,sortDirection:'desc',itemsView:'full'}},apply);
    else apply(await this.rpc.request('thread/read',{threadId,includeTurns:true}));
    return this.store.snapshot(threadId);
  }
  private install(value:unknown):Snapshot {
    const response=object(value),thread=object(response.thread),page=object(response.initialTurnsPage);
    const turns:Array<Record<string,any>>=Array.isArray(page.data)?[...page.data].reverse():Array.isArray(thread.turns)?thread.turns:[];
    const threadSummary=summary({...thread,turns},this.store);
    const items:Item[]=[];
    for(const turn of turns)for(const raw of Array.isArray(turn.items)?turn.items:[]) {
      const item=object(raw);
      const completed=turn.status==='completed'||item.completedAtMs!=null||['completed','failed','declined'].includes(String(item.status));
      items.push(projectItem(raw,String(turn.id),completed));
    }
    const snapshot:Snapshot={cursor:this.store.cursor(),thread:threadSummary,items,itemsCursor:response.itemsBackwardsCursor??null,pending:[],
      policy:{approvalPolicy:typeof response.approvalPolicy==='string'?response.approvalPolicy:null,
        sandbox:typeof object(response.sandbox).type==='string'?response.sandbox.type:null}};
    this.store.atomic(()=>this.store.putSnapshot(snapshot));return snapshot;
  }
  applyEvent(frame:SourceEvent):Envelope|null {
    if(this.store.seen(frame.connectionId,frame.ordinal))return null;
    const msg=object(frame.message),p=object(msg.params),method=String(msg.method??''),threadId=String(p.threadId??object(p.thread).id??'');
    if(!this.store.has(threadId))return null;
    const emitted:Envelope[]=[];
    this.store.atomic(()=>{
      this.store.markSource(frame.connectionId,frame.ordinal);
      const snapshot=this.store.snapshot(threadId);
      const publish=(type:string,data:unknown)=>emitted.push(this.store.append(threadId,type,data as Json));
      const upsert=(item:Item)=>{
        const i=snapshot.items.findIndex(current=>current.id===item.id);
        if(i<0)snapshot.items.push(item);else snapshot.items[i]=item;
        publish(item.kind==='unknown'?'activity/unknown':'item/upsert',item);
      };
      if(method==='item/started'||method==='item/completed') {
        const raw=object(p.item),existing=snapshot.items.find(item=>item.id===raw.id);
        if(method==='item/completed'||!existing)upsert(projectItem(raw,String(p.turnId),method==='item/completed',true));
      } else if(['item/agentMessage/delta','item/plan/delta','item/commandExecution/outputDelta','item/reasoning/summaryTextDelta'].includes(method)) {
        const id=String(p.itemId),text=typeof p.delta==='string'?p.delta:'';
        const kind=method.includes('commandExecution')?'commandExecution':method.includes('reasoning')?'reasoning':method.includes('/plan/')?'plan':'agentMessage';
        let item=snapshot.items.find(item=>item.id===id);
        if(!item) {
          item=projectItem({id,type:kind},String(p.turnId),false,false);
          item.text=text;snapshot.items.push(item);publish('item/upsert',item);
        } else if(!object(item.data).completed) {
          item.text+=text;publish('item/delta',{id,turnId:item.turnId,text});
        }
      } else if(method==='turn/started'||method==='turn/completed') {
        const turn=object(p.turn),turnId=String(turn.id);
        if(method==='turn/started') {snapshot.thread.activeTurnId=turnId;snapshot.thread.status='active';}
        else if(snapshot.thread.activeTurnId===turnId) {
          snapshot.thread.activeTurnId=null;snapshot.thread.status=String(turn.status??'unknown');
          for(const pending of snapshot.pending.filter(item=>item.turnId===turnId)) {
            const stored=this.store.pending(pending.id);
            if(stored) {stored.record.state='resolved';this.store.putPending(stored.record,stored.connectionId,stored.rpcId);}
            publish('pending/resolved',{id:pending.id});
          }
          snapshot.pending=snapshot.pending.filter(item=>item.turnId!==turnId);
        }
        publish('thread/upsert',snapshot.thread);
      } else if(method==='thread/status/changed') {
        snapshot.thread.status=String(object(p.status).type??'unknown');publish('thread/upsert',snapshot.thread);
      } else if(method==='thread/name/updated') {
        snapshot.thread.title=String(p.threadName??p.name??snapshot.thread.title);publish('thread/upsert',snapshot.thread);
      } else if(method==='thread/started')publish('thread/upsert',snapshot.thread);
      else if(method==='turn/diff/updated')upsert({id:`diff:${p.turnId}`,turnId:String(p.turnId),kind:'diff',text:String(p.diff??''),data:{prefixComplete:true,completed:false}});
      else if(method==='turn/plan/updated')upsert({id:`plan:${p.turnId}`,turnId:String(p.turnId),kind:'plan',text:(Array.isArray(p.plan)?p.plan:[]).map((step:unknown)=>String(object(step).step??'')).join('\n'),data:{steps:p.plan??[],prefixComplete:true,completed:false}});
      else if(method==='serverRequest/resolved'&&(typeof p.requestId==='string'||typeof p.requestId==='number')) {
        const stored=this.store.pendingByRpc(frame.connectionId,p.requestId);
        if(stored&&stored.record.state==='pending') {
          stored.record.state='resolved';this.store.putPending(stored.record,frame.connectionId,stored.rpcId);
          snapshot.pending=snapshot.pending.filter(item=>item.id!==stored.record.id);publish('pending/resolved',{id:stored.record.id});
        }
      } else if((typeof msg.id==='string'||typeof msg.id==='number')&&method) {
        const existing=this.store.pendingByRpc(frame.connectionId,msg.id);
        if(!existing&&typeof p.turnId==='string') {
          const kind:Pending['kind']=method.includes('commandExecution')?'command':method.includes('fileChange')?'file':method.includes('requestUserInput')?'question':method.includes('permissions')?'permission':'mcp';
          const pending:Pending={id:randomUUID(),threadId,turnId:p.turnId,kind,prompt:String(p.reason??p.command??p.message??'Review the pending request'),
            options:{availableDecisions:Array.isArray(p.availableDecisions)?p.availableDecisions:[],questions:Array.isArray(p.questions)?p.questions:[],permissions:p.permissions??null},state:'pending'};
          this.store.putPending(pending,frame.connectionId,msg.id);snapshot.pending.push(pending);publish('pending/upsert',pending);
        }
      } else if(method.startsWith('item/'))upsert({id:`unknown:${frame.connectionId}:${frame.ordinal}`,turnId:String(p.turnId??''),kind:'unknown',text:`Unsupported activity: ${method}`,data:{method,prefixComplete:false,completed:false}});
      this.store.putSnapshot(snapshot);
    });
    for(const envelope of emitted)for(const listener of this.listeners)listener(envelope);
    return emitted.at(-1)??null;
  }
}
export function createSync(store:Store,rpc:RpcClient):SyncService {return new SyncService(store,rpc);}
