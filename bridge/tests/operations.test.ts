import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openStore, type Store } from '../src/state/store.js';
import { createOperations, UncertainOperationError } from '../src/state/operations.js';
import { ApiError } from '../src/api/validation.js';
import { RpcError, RpcTransportError, connectRpc } from '../src/protocol/rpc-client.js';
import { fakeServer, handshake } from './support/fake-server.js';
import type { Command } from '../src/api/contracts.js';

const command=():Command=>({id:randomUUID(),method:'task/create',params:{projectId:'project',text:'hello'}});
async function fixture(t:TestContext) {
  const dir=await mkdtemp(join(tmpdir(),'codex-operations-')),file=join(dir,'state.sqlite');
  const store=openStore(file),stores:Store[]=[store];
  t.after(async()=>{for(const value of stores)value.close();await rm(dir,{recursive:true,force:true});});
  return {store,file,stores,operations:createOperations(store)};
}

test('duplicate_id_calls_send_once_even_when_requests_overlap',async t=>{
  const f=await fixture(t),c=command();let sends=0;
  const send=async()=>{sends++;await new Promise(resolve=>setTimeout(resolve,10));return {threadId:'created'};};
  const [a,b]=await Promise.all([f.operations.executeOnce(c,send),f.operations.executeOnce(c,send)]);
  assert.equal(sends,1);assert.equal(a.state,'accepted');assert.deepEqual(b,a);
  assert.deepEqual(f.operations.getOperation(c.id),a);
});

test('same_id_different_payload_conflicts_and_key_order_does_not',async t=>{
  const f=await fixture(t),c=command();let sends=0;
  await f.operations.executeOnce(c,async()=>{sends++;return null;});
  await f.operations.executeOnce({...c,params:{text:'hello',projectId:'project'}},async()=>{sends++;return null;});
  await assert.rejects(f.operations.executeOnce({...c,params:{...c.params,text:'different'}},async()=>null),(e:unknown)=>e instanceof ApiError&&e.status===409);
  assert.equal(sends,1);
});

test('sent_without_response_is_unknown_and_is_not_automatically_reposted',async t=>{
  const f=await fixture(t),c=command();let sends=0;
  const send=async()=>{sends++;throw new RpcTransportError('Disconnected after delivery');};
  assert.equal((await f.operations.executeOnce(c,send)).state,'unknown');
  assert.equal((await f.operations.executeOnce(c,send)).state,'unknown');
  assert.equal(sends,1);
});

test('socket_cut_after_upstream_received_write_does_not_cause_another_send',async t=>{
  const f=await fixture(t);let received=0;
  const server=await fakeServer((socket,message)=>{
    if(handshake(socket,message)||message.method==='initialized')return;
    if(message.method==='turn/start'){received++;socket.terminate();}
  });t.after(()=>server.close());
  const rpc=await connectRpc(server.url,'test');t.after(()=>rpc.close());
  const c=command(),send=()=>rpc.request('turn/start',{threadId:'controlled',input:[]});
  assert.equal((await f.operations.executeOnce(c,send)).state,'unknown');
  assert.equal((await f.operations.executeOnce(c,send)).state,'unknown');
  assert.equal(received,1);
});

test('restart_preserves_unknown_without_sending',async t=>{
  const f=await fixture(t),c=command();
  await f.operations.executeOnce(c,async()=>{throw new RpcTransportError('lost');});
  f.store.close();const restored=openStore(f.file);f.stores.push(restored);
  let sends=0;const operation=await createOperations(restored).executeOnce(c,async()=>{sends++;return null;});
  assert.equal(operation.state,'unknown');assert.equal(sends,0);
});

test('crash_after_persisting_pending_recovers_as_unknown',async t=>{
  const f=await fixture(t),c=command();
  void f.operations.executeOnce(c,()=>new Promise(()=>{}));
  assert.equal(f.operations.getOperation(c.id)?.state,'pending');
  f.store.close();const restored=openStore(f.file);f.stores.push(restored);
  assert.equal(createOperations(restored).getOperation(c.id)?.state,'unknown');
});

test('explicit_upstream_rejection_is_failed_while_unclassified_errors_are_unknown',async t=>{
  const f=await fixture(t);
  assert.equal((await f.operations.executeOnce(command(),async()=>{throw new RpcError(-32602,'Invalid input');})).state,'failed');
  assert.equal((await f.operations.executeOnce(command(),async()=>{throw new Error('Ambiguous failure');})).state,'unknown');
});

test('partial_create_keeps_confirmed_thread_identity_for_reconciliation',async t=>{
  const f=await fixture(t),c=command();
  const result=await f.operations.executeOnce(c,async()=>{throw new UncertainOperationError('Turn start outcome is unknown',{threadId:'already-created'});});
  assert.equal(result.state,'unknown');assert.deepEqual(result.result,{threadId:'already-created'});
});
