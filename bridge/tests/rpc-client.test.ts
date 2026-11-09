import assert from 'node:assert/strict';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { connectRpc } from '../src/protocol/rpc-client.js';
import { fakeServer, handshake, type Message } from './support/fake-server.js';

test('snapshot_barrier: applies a response synchronously before a following delta frame', async t => {
  const server=await fakeServer((socket,msg)=>{
    if(handshake(socket,msg)||!msg.method||msg.method==='initialized')return;
    socket.send(JSON.stringify({method:'delta',params:{text:'already-in-snapshot'}}));
    socket.send(JSON.stringify({id:msg.id,result:{text:'seed'}}));
    socket.send(JSON.stringify({method:'delta',params:{text:'-tail'}}));
  });
  t.after(()=>server.close());
  const client=await connectRpc(server.url,'test');
  t.after(()=>client.close());
  let text='';
  client.onEvent(raw=>{const msg=raw as {params:{text:string}};text+=msg.params.text;});
  await client.requestAtBarrier('thread/resume',{threadId:'t'},raw=>{text=(raw as {text:string}).text;});
  await delay(20);
  assert.equal(text,'seed-tail');
});

test('handshake_once: authenticates before any application request', async t => {
  const methods: string[] = [];
  const server = await fakeServer((socket, msg) => {
    if (msg.method) methods.push(msg.method);
    if (!handshake(socket, msg) && msg.id !== undefined)
      socket.send(JSON.stringify({ id: msg.id, result: { ok: true } }));
  });
  t.after(() => server.close());
  const client = await connectRpc(server.url, 'local-test-token');
  t.after(() => client.close());
  assert.deepEqual(await client.request('thread/list', {}), { ok: true });
  assert.deepEqual(methods, ['initialize', 'initialized', 'thread/list']);
  assert.deepEqual(server.headers, ['Bearer local-test-token']);
});

test('out_of_order_responses: matches request ids rather than arrival order', async t => {
  const requests: Message[] = [];
  const server = await fakeServer((socket, msg) => {
    if (handshake(socket, msg) || !msg.id) return;
    requests.push(msg);
    if (requests.length === 2) {
      for (const request of [...requests].reverse())
        socket.send(JSON.stringify({ id: request.id, result: request.params }));
    }
  });
  t.after(() => server.close());
  const client = await connectRpc(server.url, 'test');
  t.after(() => client.close());
  const [a, b] = await Promise.all([
    client.request('thread/read', { threadId: 'a' }),
    client.request('thread/read', { threadId: 'b' }),
  ]);
  assert.deepEqual(a, { threadId: 'a' });
  assert.deepEqual(b, { threadId: 'b' });
});

test('server_request_with_id_is_not_response: retains early approvals and original ids', async t => {
  const replies: Message[] = [];
  const server = await fakeServer((socket, msg) => {
    if (handshake(socket, msg)) {
      socket.send(JSON.stringify({ id: 'approval-7', method: 'item/commandExecution/requestApproval', params: { threadId: 't', turnId: 'v' } }));
    } else if (!msg.method) {
      replies.push(msg);
    }
  });
  t.after(() => server.close());
  const client = await connectRpc(server.url, 'test');
  t.after(() => client.close());
  await delay(20);
  const seen: Message[] = [];
  client.onEvent(msg => seen.push(msg as Message));
  assert.equal(seen.length, 1);
  assert.equal(seen[0]?.id, 'approval-7');
  client.respond('approval-7', { decision: 'accept' });
  await delay(20);
  assert.deepEqual(replies, [{ id: 'approval-7', result: { decision: 'accept' } }]);
});

test('overload_retry_reads_only: retries a read but never replays a write', async t => {
  let reads = 0, writes = 0;
  const server = await fakeServer((socket, msg) => {
    if (handshake(socket, msg) || !msg.id) return;
    if (msg.method === 'thread/list' && ++reads === 3) {
      socket.send(JSON.stringify({ id: msg.id, result: { data: [] } }));
    } else {
      if (msg.method === 'turn/start') writes++;
      socket.send(JSON.stringify({ id: msg.id, error: { code: -32001, message: 'Server overloaded; retry later.' } }));
    }
  });
  t.after(() => server.close());
  const client = await connectRpc(server.url, 'test');
  t.after(() => client.close());
  assert.deepEqual(await client.request('thread/list', {}), { data: [] });
  await assert.rejects(client.request('turn/start', {}), { code: -32001 });
  assert.equal(reads, 3);
  assert.equal(writes, 1);
});

test('connection_loss: outstanding writes reject without exposing credentials or replaying', async t => {
  let writes = 0;
  const server = await fakeServer((socket, msg) => {
    if (handshake(socket, msg)) return;
    if (msg.method === 'turn/start') { writes++; socket.terminate(); }
  });
  t.after(() => server.close());
  const client = await connectRpc(server.url, 'sensitive-test-token');
  t.after(() => client.close());
  await assert.rejects(client.request('turn/start', {}), error =>
    error instanceof Error && !error.message.includes('sensitive-test-token'));
  assert.equal(writes, 1);
});
