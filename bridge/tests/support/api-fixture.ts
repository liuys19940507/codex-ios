import type { TestContext } from 'node:test';
import { createApiServer } from '../../src/api/server.js';
import type { Cursor, Envelope } from '../../src/api/contracts.js';
import { ApiError } from '../../src/api/validation.js';

export async function apiFixture(t:TestContext) {
  const token='test-bridge-token',logs:string[]=[],commands:unknown[]=[],events:Envelope[]=[],handlers=new Set<(event:Envelope)=>void>();
  let available=true;
  const api=createApiServer({token,info:{apiVersion:1,serverId:'fixture',codexVersion:'0.167.0',features:{queue:false}},
    available:()=>available,log:message=>logs.push(message),
    queries:{queryProjects:()=>[{id:'project',name:'Controlled',path:'C:/controlled'}],queryModels:async()=>[],
      queryThreads:async()=>({data:[],nextCursor:null}),queryMetadata:async()=>{throw new ApiError(404,'not_found','Not observed');},querySnapshot:async()=>{throw new ApiError(404,'not_found','Not observed');},queryItems:async()=>({data:[],nextCursor:null})},
    commands:{dispatch:async command=>{commands.push(command);return {id:command.id,state:'accepted',result:null,message:null};}},
    operations:{getOperation:id=>({id,state:'unknown',result:null,message:null})},
    sync:{replay:(cursor:Cursor)=>cursor.epoch==='epoch'&&cursor.seq<=events.length?events.filter(e=>e.cursor.seq>cursor.seq):'resync_required',onEvent:handler=>{handlers.add(handler);return()=>{handlers.delete(handler);};}}
  });
  await new Promise<void>((resolve,reject)=>{api.server.once('error',reject);api.server.listen(0,'127.0.0.1',()=>resolve());});
  const address=api.server.address();if(!address||typeof address==='string')throw new Error('Missing port');
  t.after(()=>api.close());
  return {api,token,logs,commands,events,headers:{Authorization:`Bearer ${token}`},url:`http://127.0.0.1:${address.port}`,
    offline:()=>{available=false;},emit:(threadId:string)=>{const event:Envelope={cursor:{epoch:'epoch',seq:events.length+1},threadId,type:'item/delta',data:{id:'item',turnId:'turn',text:'sample'}};events.push(event);for(const handler of handlers)handler(event);return event;}};
}
