import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureBridgeWorker } from '../src/runtime/bridge-worker.js';
const config={codexExe:'C:/native/codex.exe',stateDir:'C:/private',codexPort:8390,bridgeHost:'10.147.21.2',bridgePort:8391,projects:[{id:'project',name:'Project',path:'C:/controlled'}]};

test('healthy_or_reconnecting_worker_is_reused_without_spawning_another',async()=>{
  for(const status of ['ready','offline'] as const) {
    let starts=0;
    const result=await ensureBridgeWorker(config,'C:/controlled/config.json',{probe:async()=>status,spawn:async()=>{starts++;},wait:async()=>{}});
    assert.equal(starts,0);assert.equal(result.bridgeUrl,'http://10.147.21.2:8391');
  }
});

test('worker_start_preserves_config_argument_and_waits_for_authenticated_readiness',async()=>{
  let probes=0;const paths:string[]=[];
  const result=await ensureBridgeWorker(config,'D:/项目 空格/a;&$b.json',{probe:async()=>++probes<3?'missing':'ready',spawn:async path=>{paths.push(path);},wait:async()=>{}});
  assert.deepEqual(paths,['D:/项目 空格/a;&$b.json']);assert.equal(result.bridgeUrl,'http://10.147.21.2:8391');assert.equal(probes,3);
});

test('unrecognized_listener_does_not_trigger_worker_start_or_stop',async()=>{
  let starts=0;
  await assert.rejects(ensureBridgeWorker(config,'C:/controlled/config.json',{probe:async()=>{throw new Error('Unrecognized listener');},spawn:async()=>{starts++;},wait:async()=>{}}),/Unrecognized/);
  assert.equal(starts,0);
});
