import { readFile } from 'node:fs/promises';
import { isAbsolute, basename } from 'node:path';
import { isIP } from 'node:net';

export interface RuntimeConfig {
  codexExe:string;
  stateDir:string;
  codexPort:number;
  bridgeHost:string;
  bridgePort:number;
  projects:{id:string;name:string;path:string}[];
  discoverProjects?:boolean;
}

export function validateConfig(value:unknown):RuntimeConfig {
  if(!value || typeof value!=='object' || Array.isArray(value)) throw new Error('Runtime configuration must be an object');
  const c=value as RuntimeConfig;
  if(typeof c.codexExe!=='string' || !isAbsolute(c.codexExe) || basename(c.codexExe).toLowerCase()!=='codex.exe') throw new Error('Configure an absolute native codex.exe path');
  if(typeof c.stateDir!=='string' || !isAbsolute(c.stateDir)) throw new Error('stateDir must be absolute');
  for(const port of [c.codexPort,c.bridgePort]) if(!Number.isInteger(port)||port<1||port>65535) throw new Error('Invalid configured port');
  if(c.codexPort===c.bridgePort) throw new Error('Codex and bridge ports must differ');
  if(c.discoverProjects!==undefined&&typeof c.discoverProjects!=='boolean')throw new Error('discoverProjects must be boolean');
  if(typeof c.bridgeHost!=='string'||isIP(c.bridgeHost)!==4||c.bridgeHost==='0.0.0.0') throw new Error('Configure a specific local EasyTier IPv4 address');
  if(!Array.isArray(c.projects)||c.projects.length===0) throw new Error('Configure at least one project');
  const ids=new Set<string>();
  for(const p of c.projects) {
    if(!p||typeof p.id!=='string'||! /^[a-zA-Z0-9_-]{1,64}$/.test(p.id)||ids.has(p.id)||typeof p.name!=='string'||!p.name.trim()||typeof p.path!=='string'||!isAbsolute(p.path)) throw new Error('Invalid or duplicate project configuration');
    ids.add(p.id);
  }
  return c;
}

export async function readConfig(file:string):Promise<RuntimeConfig> {
  return validateConfig(JSON.parse((await readFile(file,'utf8')).replace(/^\uFEFF/,'')));
}
