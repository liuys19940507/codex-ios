import { createHash } from 'node:crypto';
import type { Command, Json, Operation } from '../api/contracts.js';
import { ApiError, validateCommand } from '../api/validation.js';
import { RpcError } from '../protocol/rpc-client.js';
import type { Store } from './store.js';

export class UncertainOperationError extends Error {
  readonly unknownOutcome=true;
  constructor(message:string,public readonly result:Json) {super(message);this.name='UncertainOperationError';}
}
function canonical(value:unknown):unknown {
  if(Array.isArray(value))return value.map(canonical);
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).sort(([a],[b])=>a.localeCompare(b)).map(([key,v])=>[key,canonical(v)]));
  return value;
}
export function createOperations(store:Store) {
  const inflight=new Map<string,Promise<Operation>>();
  async function executeOnce(raw:Command,send:()=>Promise<Json>):Promise<Operation> {
    const command=validateCommand(raw);
    const digest=createHash('sha256').update(JSON.stringify(canonical(command))).digest('hex');
    const existing=store.atomic(()=>{
      const value=store.operation(command.id);
      if(value)return value;
      store.putOperation({digest,receipt:{id:command.id,state:'pending',result:null,message:null}});
      return null;
    });
    if(existing) {
      if(existing.digest!==digest)throw new ApiError(409,'operation_conflict','This command id belongs to different input');
      return inflight.get(command.id)??existing.receipt;
    }
    const work=(async()=>{
      let receipt:Operation;
      try {receipt={id:command.id,state:'accepted',result:await send(),message:null};}
      catch(error) {
        const explicit=error instanceof RpcError||error instanceof ApiError;
        receipt={id:command.id,state:explicit?'failed':'unknown',
          result:error instanceof UncertainOperationError?error.result:null,
          message:explicit?error.message:'The upstream result is not confirmed. Check this operation; do not submit it again automatically.'};
      }
      store.atomic(()=>store.putOperation({digest,receipt}));return receipt;
    })();
    inflight.set(command.id,work);
    try{return await work;}finally{inflight.delete(command.id);}
  }
  return {executeOnce,getOperation:(id:string):Operation|null=>store.operation(id)?.receipt??null};
}
export type Operations=ReturnType<typeof createOperations>;
