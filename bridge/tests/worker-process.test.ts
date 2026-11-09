import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { spawnWorkerProcess } from '../src/runtime/worker-process.js';

test('detached_worker_pid_is_the_actual_node_server_without_a_cli_wrapper',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'codex-worker-')),script=join(dir,'worker.ts'),pidFile=join(dir,'pid');
  let pid:number|undefined;
  try {
    await writeFile(script,"import {writeFileSync} from 'node:fs';writeFileSync(process.argv[2],String(process.pid));setInterval(()=>{},1000);");
    pid=await spawnWorkerProcess(script,[pidFile],join(dir,'worker.log'));
    let actual=0,deadline=Date.now()+3000;
    while(!actual&&Date.now()<deadline){try{actual=Number(await readFile(pidFile,'utf8'));}catch{}if(!actual)await delay(20);}
    assert.equal(actual,pid);
  }finally{
    if(pid)try{process.kill(pid);}catch{}
    await delay(100);await rm(dir,{recursive:true,force:true});
  }
});
