import test from 'node:test';
import assert from 'node:assert/strict';
import { createProjectCatalog } from '../src/api/project-catalog.js';
import type { RpcClient } from '../src/protocol/rpc-client.js';

function fixture(enabled=true) {
  const calls:any[]=[];
  const rpc={request:async(method:string,params:any)=>{
    calls.push({method,params});
    return params.cursor?{data:[{cwd:'D:/other/B/api'},{cwd:'d:\\OTHER\\a\\API'},{cwd:'D:/other/A/api/child'},{cwd:'relative/unsafe'},{cwd:'https://foreign/path'}],nextCursor:null}
      :{data:[{cwd:'D:/other/A/api'},{cwd:'C:/configured'}],nextCursor:'page2'};
  }} as unknown as RpcClient;
  const catalog=createProjectCatalog(rpc,[{id:'configured',name:'Configured',path:'C:/configured'}],enabled);
  return {catalog,calls};
}
test('discovery_reads_every_page_and_keeps_stable_windows_directory_identity',async()=>{
  const f=fixture();const projects=await f.catalog.refresh();
  assert.equal(projects.length,4);
  assert.equal(f.calls.length,2);
  assert.equal(f.calls[0].params.cwd,undefined);
  assert.deepEqual(projects.filter(p=>p.name==='api').map(p=>p.path),['D:\\other\\A\\api','D:\\other\\B\\api']);
  assert.equal(projects.find(p=>p.path==='C:/configured')?.id,'configured');
  const first=f.catalog.projectForDirectory('d:/OTHER/a/API');
  assert.ok(first);assert.equal(first.id,f.catalog.projectForDirectory('D:\\other\\A\\api')?.id);
  assert.notEqual(first.id,f.catalog.projectForDirectory('D:/other/A/api/child')?.id);
  assert.equal(f.catalog.projectForDirectory('D:/unknown'),null);
});
test('static_mode_never_reads_or_enlarges_configured_scope',async()=>{
  const f=fixture(false);assert.equal((await f.catalog.refresh()).length,1);
  assert.equal(f.calls.length,0);assert.equal(f.catalog.projectForDirectory('D:/other/A/api'),null);
});
test('concurrent_refresh_is_shared_and_failed_pagination_preserves_existing_catalog',async()=>{
  const f=fixture();await Promise.all([f.catalog.refresh(),f.catalog.refresh()]);assert.equal(f.calls.length,2);
  assert.equal(f.catalog.all().length,4);
  const rpc={request:async()=>({data:[{cwd:'D:/new'}],nextCursor:'same'})} as unknown as RpcClient;
  const looping=createProjectCatalog(rpc,[{id:'original',name:'Original',path:'C:/configured'}],true);
  await assert.rejects(looping.refresh(),/pagination/i);
  assert.equal(looping.all().length,1);
});
