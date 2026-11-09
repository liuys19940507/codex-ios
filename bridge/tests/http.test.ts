import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { apiFixture } from './support/api-fixture.js';

test('http_requires_header_authentication_and_never_uses_url_tokens',async t=>{
  const f=await apiFixture(t);
  assert.equal((await fetch(`${f.url}/v1/info?token=${f.token}`)).status,401);
  assert.equal((await fetch(`${f.url}/v1/info`,{headers:{Authorization:'Bearer wrong'}})).status,401);
  const response=await fetch(`${f.url}/v1/info`,{headers:f.headers});
  assert.equal(response.status,200);assert.equal((await response.json() as any).serverId,'fixture');
  assert.equal(response.headers.get('cache-control'),'no-store');
});

test('invalid_json_and_oversized_body_are_rejected_without_dispatch_or_body_logs',async t=>{
  const f=await apiFixture(t),headers={...f.headers,'Content-Type':'application/json'};
  assert.equal((await fetch(`${f.url}/v1/commands`,{method:'POST',headers,body:'{private-input'})).status,400);
  assert.equal((await fetch(`${f.url}/v1/commands`,{method:'POST',headers,body:'x'.repeat(1048577)})).status,413);
  assert.equal(f.commands.length,0);
  const logs=JSON.stringify(f.logs);assert.equal(logs.includes(f.token),false);assert.equal(logs.includes('private-input'),false);
});

test('http_rejects_arbitrary_rpc_extra_fields_and_excess_text',async t=>{
  const f=await apiFixture(t),headers={...f.headers,'Content-Type':'application/json'};
  const cases=[{id:randomUUID(),method:'account/login/start',params:{}},
    {id:randomUUID(),method:'task/create',params:{projectId:'project',text:'text',cwd:'C:/outside'}},
    {id:randomUUID(),method:'task/create',params:{projectId:'project',text:'界'.repeat(22000)}}];
  for(const [index,command] of cases.entries()) {
    assert.equal((await fetch(`${f.url}/v1/commands`,{method:'POST',headers,body:JSON.stringify(command)})).status,index===2?413:400);
  }
  assert.equal((await fetch(`${f.url}/v1/rpc`,{headers:f.headers})).status,404);
  assert.equal(f.commands.length,0);
});

test('upstream_unavailable_returns_503_and_receipt_lookup_is_read_only',async t=>{
  const f=await apiFixture(t),id=randomUUID();
  assert.equal((await fetch(`${f.url}/v1/operations/${id}`,{headers:f.headers})).status,200);
  assert.equal(f.commands.length,0);f.offline();
  const response=await fetch(`${f.url}/v1/info`,{headers:f.headers});
  assert.equal(response.status,503);assert.equal((await response.json() as any).code,'upstream_unavailable');
});
