import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,copyFile,rm,readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join,resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

test('native_utility_launch_keeps_literal_arguments_without_loading_bridge_token',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'codex-native-cli-'));
 try {
  const exe=join(dir,'codex.exe');await copyFile(process.execPath,exe);
  const capture=join(dir,'capture.cjs'),output=join(dir,'output.json'),request=join(dir,'request.json');
  await writeFile(capture,'require("node:fs").writeFileSync(process.argv[2],JSON.stringify({args:process.argv.slice(3),token:process.env.CODEX_REMOTE_LOCAL_TOKEN??null}));');
  const args=[capture,output,'中文 😀','x="a\\b"','','literal ; & $x'];
  await writeFile(request,JSON.stringify({codexExe:exe,args}));
  const env={...process.env};delete env.CODEX_REMOTE_LOCAL_TOKEN;
  const result=spawnSync(process.execPath,[resolve('node_modules/tsx/dist/cli.mjs'),'scripts/run-cli.ts','--request',request],{encoding:'utf8',env,windowsHide:true});
  assert.equal(result.status,0,result.stderr);
  const actual=JSON.parse(await readFile(output,'utf8'));assert.deepEqual(actual.args,args.slice(2));assert.equal(actual.token,null);
 }finally{await rm(dir,{recursive:true,force:true});}
});
