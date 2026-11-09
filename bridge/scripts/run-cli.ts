import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { isAbsolute, basename } from 'node:path';

try {
  const requestAt=process.argv.indexOf('--request');
  const file=process.argv[requestAt+1];
  if(requestAt<0||!file) throw new Error('Required local launch request');
  const request=JSON.parse((await readFile(file,'utf8')).replace(/^\uFEFF/,'')) as {codexExe:string;tokenFile:string;args:string[]};
  if(!isAbsolute(request.codexExe)||basename(request.codexExe).toLowerCase()!=='codex.exe'||!isAbsolute(request.tokenFile)||!Array.isArray(request.args)||!request.args.every(a=>typeof a==='string')) throw new Error('Invalid local launch request');
  const token=(await readFile(request.tokenFile,'utf8')).trim();
  const child=spawn(request.codexExe,request.args,{shell:false,stdio:'inherit',env:{...process.env,CODEX_REMOTE_LOCAL_TOKEN:token}});
  const code=await new Promise<number>((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>resolve(code??1));});
  process.exitCode=code;
} catch {
  console.error('Unable to launch remote Codex client; check local executable and private launch files');
  process.exitCode=1;
}
