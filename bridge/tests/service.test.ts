import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { mkdtemp, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServiceManager, type ServiceHost, type ProcessIdentity } from '../src/runtime/service.js';
import type { RuntimeConfig } from '../src/runtime/config.js';

async function fixture(t:TestContext) {
  const stateDir=await mkdtemp(join(tmpdir(),'codex-service-'));
  t.after(()=>rm(stateDir,{recursive:true,force:true}));
  const codexExe=join(stateDir,'codex.exe');
  await writeFile(codexExe,'test boundary only');
  const config:RuntimeConfig={codexExe,stateDir,codexPort:18391,bridgeHost:'127.0.0.1',bridgePort:18392,projects:[{id:'p',name:'Test',path:stateDir}]};
  let processInfo:ProcessIdentity|null=null;
  let occupied=false;
  const captured:{exe:string;args:string[];stateDir:string}[]=[];
  let stopCount=0;
  const host:ServiceHost={
    version:async()=> 'codex-cli 0.167.0',
    secure:async()=>{},
    portOpen:async()=>occupied,
    spawn:async(exe,args,dir)=>{
      captured.push({exe,args:[...args],stateDir:dir});
      occupied=true;
      processInfo={pid:901,exe,createdAt:'2026-11-08T00:00:00.000Z',commandLine:'owned test boundary'};
      return processInfo;
    },
    identify:async(pid)=>pid===901 ? processInfo:null,
    healthy:async()=>processInfo!==null,
    stop:async()=>{stopCount++;processInfo=null;occupied=false;},
  };
  return {config,manager:createServiceManager(host),host,captured,stopCount:()=>stopCount,occupy:()=>{occupied=true;},replaceProcess:()=>{processInfo={pid:901,exe:codexExe,createdAt:'different incarnation',commandLine:'other'};}};
}

test('reuse_owned_service: returns the same authenticated process',async t=>{
  const f=await fixture(t);
  const first=await f.manager.ensureService(f.config);
  const second=await f.manager.ensureService(f.config);
  assert.deepEqual(second,first);
  assert.equal(f.captured.length,1);
  assert.equal((await readFile(join(f.config.stateDir,'codex-token'),'utf8')).trim().length,64);
});

test('occupied_port_is_not_our_service: never stops another process',async t=>{
  const f=await fixture(t);f.occupy();
  await assert.rejects(f.manager.ensureService(f.config),/occupied/i);
  assert.equal(f.stopCount(),0);
  assert.equal(f.captured.length,0);
});

test('concurrent_launch_once: independent managers share a filesystem lock',async t=>{
  const f=await fixture(t);
  const values=await Promise.all(Array.from({length:5},()=>createServiceManager(f.host).ensureService(f.config)));
  assert.equal(new Set(values.map(v=>v.instanceId)).size,1);
  assert.equal(f.captured.length,1);
});

test('preserve_unicode_argument_boundaries: arguments remain a literal array',async t=>{
  const f=await fixture(t);
  await f.manager.ensureService(f.config);
  const captured=f.captured[0]!;
  assert.equal(captured.exe,f.config.codexExe);
  assert.deepEqual(captured.args,['app-server','--listen','ws://127.0.0.1:18391','--ws-auth','capability-token','--ws-token-file',join(f.config.stateDir,'codex-token')]);
  assert.equal(captured.stateDir,f.config.stateDir);
});

test('closing_cli_does_not_stop_server: only explicit matching instance can stop',async t=>{
  const f=await fixture(t);
  const service=await f.manager.ensureService(f.config);
  assert.equal(f.stopCount(),0);
  await assert.rejects(f.manager.stopService(f.config,'wrong-instance'),/instance/i);
  assert.equal(f.stopCount(),0);
  await f.manager.stopService(f.config,service.instanceId);
  assert.equal(f.stopCount(),1);
});

test('recycled_pid_cannot_be_reused_or_stopped',async t=>{
  const f=await fixture(t);
  const service=await f.manager.ensureService(f.config);f.replaceProcess();
  await assert.rejects(f.manager.ensureService(f.config),/identity/i);
  await assert.rejects(f.manager.stopService(f.config,service.instanceId),/identity/i);
  assert.equal(f.stopCount(),0);
});
