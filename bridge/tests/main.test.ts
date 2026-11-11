import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import type WebSocket from 'ws';
import { startBridge } from '../src/main.js';
import { fakeServer, handshake } from './support/fake-server.js';
import { createAttachmentStore } from '../src/api/uploads.js';

async function fixture(t:TestContext) {
  const stateDir=await mkdtemp(join(tmpdir(),'codex-main-'));
  let socket:WebSocket|undefined;const calls:string[]=[];
  const server=await fakeServer((peer,m)=>{
    socket=peer;if(handshake(peer,m)||m.method==='initialized')return;
    calls.push(m.method!);
    const thread={id:'own',cwd:'C:/controlled',name:'Test',status:{type:'notLoaded'},turns:[]};
    peer.send(JSON.stringify({id:m.id,result:m.method==='thread/loaded/list'?{data:[]}:{thread}}));
  });
  const reserve=createServer();await new Promise<void>(resolve=>reserve.listen(0,'127.0.0.1',resolve));
  const address=reserve.address();if(!address||typeof address==='string')throw new Error('No port');
  const bridgePort=address.port;await new Promise<void>(resolve=>reserve.close(()=>resolve()));
  await writeFile(join(stateDir,'codex-token'),'test-native-token');
  const config={codexExe:'C:/native/codex.exe',stateDir,codexPort:8390,bridgeHost:'127.0.0.1',bridgePort,projects:[{id:'controlled',name:'Controlled',path:'C:/controlled'}]};
  const dependencies={addresses:()=>['127.0.0.1'],secure:async(_path:string)=>{},ensureService:async()=>({instanceId:'test',pid:0,codexUrl:server.url,bridgeUrl:`http://127.0.0.1:${bridgePort}`})};
  let runtime:Awaited<ReturnType<typeof startBridge>>|undefined;
  t.after(async()=>{await runtime?.close();await server.close();await rm(stateDir,{recursive:true,force:true});});
  return {config,dependencies,calls,start:async()=>runtime=await startBridge(config,dependencies),cut:()=>socket!.terminate()};
}

test('upload_endpoint_is_authenticated_project_scoped_and_does_not_take_control',async t=>{
  const f=await fixture(t);await f.start();
  const token=(await readFile(join(f.config.stateDir,'bridge-token'),'utf8')).trim();
  const base=`http://${f.config.bridgeHost}:${f.config.bridgePort}`,headers={Authorization:`Bearer ${token}`,'Content-Type':'application/json'};
  const request={id:randomUUID(),projectId:'controlled',name:'手机 文档.txt',kind:'file',base64:Buffer.alloc(2*1024*1024,65).toString('base64')};
  assert.equal((await fetch(`${base}/v1/attachments`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(request)})).status,401);
  assert.deepEqual(f.calls,[]);
  const info=await fetch(`${base}/v1/info`,{headers}).then(r=>r.json()) as any;
  assert.equal(info.features.attachments,true);
  const response=await fetch(`${base}/v1/attachments`,{method:'POST',headers,body:JSON.stringify(request)});
  assert.equal(response.status,200);
  const receipt=await response.json() as any;assert.equal(receipt.id,request.id);assert.equal(receipt.size,2*1024*1024);
  const retry=await fetch(`${base}/v1/attachments`,{method:'POST',headers,body:JSON.stringify(request)});
  assert.deepEqual(await retry.json(),receipt);
  const [saved]=await createAttachmentStore(join(f.config.stateDir,'uploads')).resolve([request.id],'controlled');
  assert.equal((await readFile(saved!.location)).length,2*1024*1024);
  assert.equal((await fetch(`${base}/v1/attachments`,{method:'POST',headers,body:JSON.stringify({...request,id:randomUUID(),projectId:'outside'})})).status,404);
  assert.equal((await fetch(`${base}/v1/attachments?unexpected=true`,{method:'POST',headers,body:JSON.stringify(request)})).status,400);
  assert.deepEqual(f.calls,[],'Upload must never resume/attach/start a task');
});

test('metadata_feature_and_authenticated_endpoint_only_read_thread_metadata',async t=>{
  const f=await fixture(t),runtime=await f.start();
  const token=(await readFile(join(f.config.stateDir,'bridge-token'),'utf8')).trim();
  const url=`http://${f.config.bridgeHost}:${f.config.bridgePort}`,headers={Authorization:`Bearer ${token}`};
  assert.equal((await fetch(`${url}/v1/threads/own/metadata`)).status,401);
  assert.equal(f.calls.length,0);
  const info=await fetch(`${url}/v1/info`,{headers}).then(r=>r.json()) as any;
  assert.equal(info.features.threadMetadata,true);
  const response=await fetch(`${url}/v1/threads/own/metadata`,{headers});
  assert.equal(response.status,200);
  const body=await response.json() as any;assert.equal(body.id,'own');assert.equal(body.title,'Test');
  assert.equal('items' in body,false);
  assert.deepEqual(f.calls,['thread/read']);
  assert.equal((await fetch(`${url}/v1/threads/own/metadata?cursor=unexpected`,{headers})).status,400);
  assert.deepEqual(f.calls,['thread/read']);
});

test('missing_configured_network_address_fails_before_starting_any_service',async t=>{
  const f=await fixture(t);let starts=0;
  await assert.rejects(startBridge({...f.config,bridgeHost:'10.147.21.222'},{...f.dependencies,ensureService:async()=>{starts++;throw new Error('Must not start');}}),/address/i);
  assert.equal(starts,0);
});

test('bridge_persists_separate_credentials_and_reconnects_with_new_epoch',async t=>{
  const f=await fixture(t);await f.start();
  const token=(await readFile(join(f.config.stateDir,'bridge-token'),'utf8')).trim();
  assert.notEqual(token,'test-native-token');assert.equal(token.length,43);
  const headers={Authorization:`Bearer ${token}`},url=`http://127.0.0.1:${f.config.bridgePort}`;
  const info=await fetch(`${url}/v1/info`,{headers});assert.equal(info.status,200);
  assert.equal((await fetch(`${url}/v1/operations/${randomUUID()}`,{headers})).status,404);
  const first=await fetch(`${url}/v1/threads/own/snapshot`,{headers}).then(r=>r.json()) as any;
  await assert.rejects(startBridge(f.config,f.dependencies),(e:unknown)=>(e as NodeJS.ErrnoException).code==='EADDRINUSE');
  const afterConflict=await fetch(`${url}/v1/threads/own/snapshot`,{headers}).then(r=>r.json()) as any;
  assert.equal(afterConflict.cursor.epoch,first.cursor.epoch);
  f.cut();
  let epoch=first.cursor.epoch,deadline=Date.now()+5000;
  while(epoch===first.cursor.epoch&&Date.now()<deadline) {
    await delay(30);const response=await fetch(`${url}/v1/threads/own/snapshot`,{headers});
    if(response.ok)epoch=(await response.json() as any).cursor.epoch;
  }
  assert.notEqual(epoch,first.cursor.epoch);
  const id=(await info.json() as any).serverId;assert.equal((await readFile(join(f.config.stateDir,'bridge-id'),'utf8')).trim(),id);
});
