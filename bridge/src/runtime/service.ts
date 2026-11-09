import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, open, readFile, writeFile, rename, unlink, lstat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createConnection } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { connectRpc } from '../protocol/rpc-client.js';
import type { Json } from '../api/contracts.js';
import { validateConfig, type RuntimeConfig } from './config.js';

export interface ServiceInfo {instanceId:string;pid:number;codexUrl:string;bridgeUrl:string}
export interface ProcessIdentity {pid:number;exe:string;createdAt:string;commandLine:string}
export interface ServiceHost {
  version(exe:string):Promise<string>;
  secure(path:string):Promise<void>;
  portOpen(port:number):Promise<boolean>;
  spawn(exe:string,args:string[],stateDir:string):Promise<ProcessIdentity>;
  identify(pid:number):Promise<ProcessIdentity|null>;
  healthy(url:string,token:string):Promise<boolean>;
  listThreads(url:string,token:string):Promise<Json>;
  stop(pid:number):Promise<void>;
}
interface OwnedService {info:ServiceInfo;process:ProcessIdentity;codexExe:string;codexPort:number}
const psDir=fileURLToPath(new URL('../../../scripts/windows/',import.meta.url));
const run=promisify(execFile);
const ps=(script:string,args:string[])=>run('powershell.exe',['-NoProfile','-NonInteractive','-File',join(psDir,script),...args],{windowsHide:true,encoding:'utf8',timeout:15000,maxBuffer:1024*1024});
const paths=(c:RuntimeConfig)=>({record:join(c.stateDir,'service.json'),token:join(c.stateDir,'codex-token'),lock:join(c.stateDir,'start.lock')});
const samePath=(a:string,b:string)=>resolve(a).toLowerCase()===resolve(b).toLowerCase();
const isMissing=(e:unknown)=>(e as NodeJS.ErrnoException).code==='ENOENT';

async function identify(pid:number):Promise<ProcessIdentity|null> {
  const result=await ps('Get-CodexRemoteProcess.ps1',['-ProcessId',String(pid)]);
  return JSON.parse(result.stdout.replace(/^\uFEFF/,'')) as ProcessIdentity|null;
}

const nativeHost:ServiceHost={
  version:async exe=>(await run(exe,['--version'],{windowsHide:true,timeout:10000,encoding:'utf8'})).stdout.trim(),
  secure:async path=>{if(process.platform!=='win32') throw new Error('Shared launcher requires native Windows');await ps('Protect-CodexRemotePath.ps1',['-Path',path]);},
  portOpen:async port=>await new Promise<boolean>(resolveResult=>{
    const socket=createConnection({host:'127.0.0.1',port});
    const done=(value:boolean)=>{socket.destroy();resolveResult(value);};
    socket.once('connect',()=>done(true));socket.once('error',()=>done(false));socket.setTimeout(500,()=>done(false));
  }),
  spawn:async(exe,args,stateDir)=>{
    const child=spawn(exe,args,{cwd:stateDir,detached:true,windowsHide:true,stdio:'ignore',shell:false});
    await new Promise<void>((ok,fail)=>{child.once('spawn',ok);child.once('error',fail);});
    const pid=child.pid!;child.unref();
    const value=await identify(pid);
    if(!value) throw new Error('Owned Codex process exited during startup');
    return value;
  },
  identify,
  healthy:async(url,token)=>{try{const rpc=await connectRpc(url,token);await rpc.close();return true;}catch{return false;}},
  listThreads:async(url,token)=>{
    const rpc=await connectRpc(url,token,{signal:AbortSignal.timeout(2000)});
    try{return await rpc.request('thread/loaded/list',{});}finally{await rpc.close();}
  },
  stop:async pid=>{process.kill(pid);},
};

export function createServiceManager(host:ServiceHost=nativeHost) {
  async function reclaimStaleLock(file:string):Promise<boolean> {
    // Serialize stale-owner decisions separately. A waiter must reread ownership
    // while holding this guard; otherwise it can unlink a replacement lock.
    const guard=file+'.recovery';
    let handle;
    try{handle=await open(guard,'wx',0o600);}catch(error){if((error as NodeJS.ErrnoException).code==='EEXIST')return false;throw error;}
    try {
      await handle.writeFile(JSON.stringify({pid:process.pid,nonce:randomUUID()}));
      let owner:{pid:number};
      try{owner=JSON.parse(await readFile(file,'utf8')) as {pid:number};}
      catch(error){if(isMissing(error)||error instanceof SyntaxError)return false;throw error;}
      if(!Number.isSafeInteger(owner.pid)||owner.pid<=0)throw new Error('Invalid startup lock owner');
      try{process.kill(owner.pid,0);return false;}
      catch(error){if((error as NodeJS.ErrnoException).code!=='ESRCH')throw error;}
      await unlink(file);
      return true;
    } finally {
      await handle.close();
      // Only the holder removes this guard. Abandoned guards are deliberately
      // left for inspection instead of recursively attempting unsafe recovery.
      await unlink(guard);
    }
  }

  async function lock(config:RuntimeConfig):Promise<()=>Promise<void>> {
    const file=paths(config).lock;
    const nonce=randomUUID();
    const deadline=Date.now()+15000;
    for(;;) {
      try {
        const handle=await open(file,'wx',0o600);
        try{await handle.writeFile(JSON.stringify({pid:process.pid,nonce}));}finally{await handle.close();}
        return async()=>{
          const owner=JSON.parse(await readFile(file,'utf8')) as {nonce:string};
          if(owner.nonce!==nonce) throw new Error('Service startup lock identity changed');
          await unlink(file);
        };
      } catch(error) {
        if((error as NodeJS.ErrnoException).code!=='EEXIST') throw error;
        if(await reclaimStaleLock(file))continue;
        if(Date.now()>deadline) throw new Error('Service startup lock is busy; inspect start.lock and start.lock.recovery owners');
        await delay(25);
      }
    }
  }

  async function readOwned(config:RuntimeConfig):Promise<OwnedService|null> {
    try {
      const saved=JSON.parse(await readFile(paths(config).record,'utf8')) as OwnedService;
      if(!saved.info?.instanceId||!Number.isSafeInteger(saved.info.pid)||saved.info.pid!==saved.process?.pid) throw new Error('Invalid service identity record');
      if(!samePath(saved.codexExe,config.codexExe)||saved.codexPort!==config.codexPort||saved.info.codexUrl!==`ws://127.0.0.1:${config.codexPort}`||saved.info.bridgeUrl!==`http://${config.bridgeHost}:${config.bridgePort}`) throw new Error('Service configuration changed; explicitly stop the old instance first');
      const current=await host.identify(saved.info.pid);
      if(!current) return null;
      if(!samePath(current.exe,saved.process.exe)||current.createdAt!==saved.process.createdAt||current.commandLine!==saved.process.commandLine) throw new Error('Service process identity mismatch');
      return saved;
    } catch(e) {if(isMissing(e)) return null;throw e;}
  }

  async function ensureService(raw:RuntimeConfig):Promise<ServiceInfo> {
    const config=validateConfig(raw);
    if(!(await lstat(config.codexExe)).isFile()) throw new Error('Native Codex executable missing');
    await mkdir(config.stateDir,{recursive:true,mode:0o700});
    const stateStat=await lstat(config.stateDir);
    if(!stateStat.isDirectory()||stateStat.isSymbolicLink()) throw new Error('stateDir must be a real local directory');
    await host.secure(config.stateDir);
    const release=await lock(config);
    try {
      if((await host.version(config.codexExe)).trim()!=='codex-cli 0.167.0') throw new Error('Codex 0.167.0 native executable is required');
      const previous=await readOwned(config);
      if(previous) {
        const token=(await readFile(paths(config).token,'utf8')).trim();
        if(!/^[0-9a-f]{64}$/.test(token)||!await host.healthy(previous.info.codexUrl,token))throw new Error('Owned service is not healthy; not replacing or killing it');
        return previous.info;
      }
      if(await host.portOpen(config.codexPort)) throw new Error('Codex port occupied by an unowned process; choose another port');
      const token=randomBytes(32).toString('hex');
      await writeFile(paths(config).token,token,{mode:0o600});
      await host.secure(paths(config).token);
      const codexUrl=`ws://127.0.0.1:${config.codexPort}`;
      const processInfo=await host.spawn(config.codexExe,['app-server','--listen',codexUrl,'--ws-auth','capability-token','--ws-token-file',paths(config).token],config.stateDir);
      const info:ServiceInfo={instanceId:randomUUID(),pid:processInfo.pid,codexUrl,bridgeUrl:`http://${config.bridgeHost}:${config.bridgePort}`};
      const saved:OwnedService={info,process:processInfo,codexExe:config.codexExe,codexPort:config.codexPort};
      const temp=paths(config).record+'.'+randomUUID()+'.tmp';
      await writeFile(temp,JSON.stringify(saved),{mode:0o600});
      await rename(temp,paths(config).record);
      const deadline=Date.now()+15000;
      while(!await host.healthy(codexUrl,token)) {
        if(Date.now()>deadline) throw new Error('Owned Codex did not become ready; service identity retained for diagnosis');
        await delay(100);
      }
      return info;
    } finally {await release();}
  }

  async function stopService(config:RuntimeConfig,instanceId:string):Promise<void> {
    validateConfig(config);
    const release=await lock(config);
    try {
      const owned=await readOwned(config);
      if(!owned||owned.info.instanceId!==instanceId) throw new Error('Explicit current instance ID is required to stop a service');
      await host.stop(owned.info.pid);
      await unlink(paths(config).record);
    } finally{await release();}
  }
  async function getStatus(config:RuntimeConfig) {
    validateConfig(config);
    const owned=await readOwned(config);
    if(!owned)return {service:null,threads:null,tasksAvailable:false};
    try {
      const token=(await readFile(paths(config).token,'utf8')).trim();
      if(!/^[0-9a-f]{64}$/.test(token))throw new Error('Capability token unavailable');
      const threads=await host.listThreads(owned.info.codexUrl,token);
      return {service:owned.info,threads,tasksAvailable:true};
    } catch {return {service:owned.info,threads:null,tasksAvailable:false};}
  }
  return {ensureService,stopService,inspectService:readOwned,getStatus};
}

const manager=createServiceManager();
export const ensureService=manager.ensureService;
export const stopService=manager.stopService;
export const inspectService=manager.inspectService;
export const getServiceStatus=manager.getStatus;
