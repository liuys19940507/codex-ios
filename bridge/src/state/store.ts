import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import type { Cursor, Envelope, Json, Operation, Pending, Snapshot, ThreadSummary } from '../api/contracts.js';
import { ApiError, projectForCwd } from '../api/validation.js';
import type { RuntimeConfig } from '../runtime/config.js';

export type StoredPending={record:Pending;rpcId:string|number;connectionId:string};
export type StoredOperation={digest:string;receipt:Operation};
export class Store {
  private readonly db:DatabaseSync;
  private epoch=randomUUID();
  private seq=0;
  private closed=false;
  private projects:RuntimeConfig['projects']=[];
  constructor(file:string) {
    this.db=new DatabaseSync(file);
    try {
      const version=this.db.prepare('PRAGMA user_version').get()?.user_version;
      if(version!==0&&version!==1) throw new Error('Unsupported SQLite state version');
      this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS snapshots(thread_id TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY,thread_id TEXT NOT NULL,type TEXT NOT NULL,data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sources(connection_id TEXT NOT NULL,lo INTEGER NOT NULL,hi INTEGER NOT NULL,PRIMARY KEY(connection_id,lo));
        CREATE TABLE IF NOT EXISTS pending(id TEXT PRIMARY KEY,connection_id TEXT NOT NULL,rpc_key TEXT NOT NULL,value TEXT NOT NULL,UNIQUE(connection_id,rpc_key));
        CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,value TEXT NOT NULL);
        PRAGMA user_version=1;`);
      this.resetEpoch();
    } catch(error) {this.db.close();throw error;}
  }
  atomic<T>(work:()=>T):T {
    const oldSeq=this.seq;
    this.db.exec('BEGIN IMMEDIATE');
    try {const result=work();this.db.exec('COMMIT');return result;}
    catch(error){this.db.exec('ROLLBACK');this.seq=oldSeq;throw error;}
  }
  resetEpoch():void {
    this.atomic(()=>{
      this.db.exec('DELETE FROM events; DELETE FROM sources;');
      for(const row of this.db.prepare('SELECT thread_id,value FROM snapshots').all()) {
        const snapshot=JSON.parse(String(row.value)) as Snapshot;
        for(const pending of snapshot.pending) if(pending.state==='pending')pending.state='unknown';
        this.putSnapshot(snapshot);
      }
      for(const row of this.db.prepare('SELECT id,value FROM pending').all()) {
        const value=JSON.parse(String(row.value)) as StoredPending;
        if(value.record.state==='pending')value.record.state='unknown';
        this.db.prepare('UPDATE pending SET value=? WHERE id=?').run(JSON.stringify(value),String(row.id));
      }
      for(const row of this.db.prepare('SELECT id,value FROM operations').all()) {
        const value=JSON.parse(String(row.value)) as StoredOperation;
        if(value.receipt.state==='pending') {
          value.receipt.state='unknown';value.receipt.message='The previous connection ended before confirmation; do not resend automatically.';
          this.putOperation(value);
        }
      }
    });
    this.epoch=randomUUID();this.seq=0;
  }
  cursor():Cursor {return {epoch:this.epoch,seq:this.seq};}
  setProjects(projects:RuntimeConfig['projects']):void {this.projects=projects;}
  project(cwd:string) {return projectForCwd(this.projects,cwd);}
  has(threadId:string):boolean {return !!this.db.prepare('SELECT 1 FROM snapshots WHERE thread_id=?').get(threadId);}
  snapshot(threadId:string):Snapshot {
    const row=this.db.prepare('SELECT value FROM snapshots WHERE thread_id=?').get(threadId);
    if(!row)throw new ApiError(404,'not_found','Thread has not been observed');
    return {...JSON.parse(String(row.value)) as Snapshot,cursor:this.cursor()};
  }
  putSnapshot(snapshot:Snapshot):void {
    this.db.prepare('INSERT INTO snapshots(thread_id,value) VALUES(?,?) ON CONFLICT(thread_id) DO UPDATE SET value=excluded.value')
      .run(snapshot.thread.id,JSON.stringify(snapshot));
  }
  threads():ThreadSummary[] {
    return this.db.prepare('SELECT value FROM snapshots').all().map(row=>(JSON.parse(String(row.value)) as Snapshot).thread);
  }
  seen(connectionId:string,ordinal:number):boolean {
    if(!connectionId||!Number.isSafeInteger(ordinal)||ordinal<1)throw new Error('Invalid source event identity');
    return !!this.db.prepare('SELECT 1 FROM sources WHERE connection_id=? AND lo<=? AND hi>=?').get(connectionId,ordinal,ordinal);
  }
  markSource(connectionId:string,ordinal:number):void {
    // Compress processed identities into ranges. A snapshot can delay earlier
    // ordinals while another thread commits later ones, so a high-water mark
    // alone would silently discard valid buffered frames.
    const adjacent=this.db.prepare('SELECT lo,hi FROM sources WHERE connection_id=? AND hi>=? AND lo<=?').all(connectionId,ordinal-1,ordinal+1);
    const lo=Math.min(ordinal,...adjacent.map(row=>Number(row.lo))),hi=Math.max(ordinal,...adjacent.map(row=>Number(row.hi)));
    this.db.prepare('DELETE FROM sources WHERE connection_id=? AND hi>=? AND lo<=?').run(connectionId,ordinal-1,ordinal+1);
    this.db.prepare('INSERT INTO sources VALUES(?,?,?)').run(connectionId,lo,hi);
  }
  append(threadId:string,type:string,data:Json):Envelope {
    const envelope={cursor:{epoch:this.epoch,seq:++this.seq},threadId,type,data};
    this.db.prepare('INSERT INTO events VALUES(?,?,?,?)').run(this.seq,threadId,type,JSON.stringify(data));
    this.db.prepare('DELETE FROM events WHERE seq<=?').run(this.seq-10000);
    return envelope;
  }
  replay(cursor:Cursor):Envelope[]|'resync_required' {
    if(cursor.epoch!==this.epoch||!Number.isSafeInteger(cursor.seq)||cursor.seq<0||cursor.seq>this.seq)return 'resync_required';
    const min=this.db.prepare('SELECT MIN(seq) AS n FROM events').get()?.n;
    if(min!==null&&min!==undefined&&cursor.seq<Number(min)-1)return 'resync_required';
    return this.db.prepare('SELECT seq,thread_id,type,data FROM events WHERE seq>? ORDER BY seq').all(cursor.seq)
      .map(row=>({cursor:{epoch:this.epoch,seq:Number(row.seq)},threadId:String(row.thread_id),type:String(row.type),data:JSON.parse(String(row.data)) as Json}));
  }
  putPending(record:Pending,connectionId:string,rpcId:string|number):void {
    const value:StoredPending={record,rpcId,connectionId};
    this.db.prepare('INSERT INTO pending VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value')
      .run(record.id,connectionId,JSON.stringify(rpcId),JSON.stringify(value));
  }
  pending(id:string):StoredPending|null {
    const row=this.db.prepare('SELECT value FROM pending WHERE id=?').get(id);
    return row?JSON.parse(String(row.value)) as StoredPending:null;
  }
  pendingByRpc(connectionId:string,rpcId:string|number):StoredPending|null {
    const row=this.db.prepare('SELECT value FROM pending WHERE connection_id=? AND rpc_key=?').get(connectionId,JSON.stringify(rpcId));
    return row?JSON.parse(String(row.value)) as StoredPending:null;
  }
  operation(id:string):StoredOperation|null {
    const row=this.db.prepare('SELECT value FROM operations WHERE id=?').get(id);
    return row?JSON.parse(String(row.value)) as StoredOperation:null;
  }
  putOperation(value:StoredOperation):void {
    this.db.prepare('INSERT INTO operations VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value')
      .run(value.receipt.id,JSON.stringify(value));
  }
  close():void {if(!this.closed){this.closed=true;this.db.close();}}
}
export function openStore(file:string):Store {return new Store(file);}
