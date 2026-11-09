import assert from 'node:assert/strict';
import test,{type TestContext} from 'node:test';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {probeSnapshotRace} from '../scripts/probe-snapshot-race.js';
import {fakeServer,handshake} from './support/fake-server.js';

async function fixture(t:TestContext,status:'notLoaded'|'active') {
  const projectDir=await mkdtemp(join(tmpdir(),'codex-stream-probe-'));
  t.after(()=>rm(projectDir,{recursive:true,force:true}));
  const tokenFile=join(projectDir,'token');await writeFile(tokenFile,'test');
  await writeFile(join(projectDir,'probe-stream.json'),JSON.stringify({threadId:'controlled',allowTestTurn:true}));
  let starts=0;
  const server=await fakeServer((socket,msg)=>{
    if(handshake(socket,msg)||msg.method==='initialized')return;
    let result:unknown;
    if(msg.method==='thread/read')result={thread:{cwd:projectDir,status:{type:status}}};
    else if(msg.method==='thread/resume')result={thread:{status:{type:'idle'}}};
    else if(msg.method==='turn/start'){
      starts++;result={turn:{id:'test-turn'}};
      socket.send(JSON.stringify({method:'turn/started',params:{threadId:'controlled',turn:{id:'test-turn'}}}));
      socket.send(JSON.stringify({method:'turn/completed',params:{threadId:'controlled',turn:{id:'test-turn'}}}));
    }else throw new Error('Unexpected method');
    socket.send(JSON.stringify({id:msg.id,result}));
  });
  t.after(()=>server.close());
  return {options:{url:server.url,projectDir,tokenFile,threadId:'controlled',mode:'paged' as const},starts:()=>starts};
}

test('snapshot_probe_can_resume_its_controlled_unloaded_thread_without_claiming_unobserved_cases',async t=>{
  const f=await fixture(t,'notLoaded');
  const report=await probeSnapshotRace(f.options);
  assert.equal(f.starts(),1);assert.equal(report.observed,false);assert.equal(report.immediatePrefixPassed,false);
});

test('snapshot_probe_rejects_an_already_active_thread_without_starting_another_turn',async t=>{
  const f=await fixture(t,'active');
  await assert.rejects(probeSnapshotRace(f.options),/idle/);
  assert.equal(f.starts(),0);
});
