import { createHash } from 'node:crypto';
import { win32 } from 'node:path';
import type { RpcClient } from '../protocol/rpc-client.js';
import type { RuntimeConfig } from '../runtime/config.js';
import { ApiError } from './validation.js';
import { object } from '../state/reducer.js';

export const sourceKinds=['cli','vscode','exec','appServer','subAgent','subAgentReview','subAgentCompact','subAgentThreadSpawn','subAgentOther','unknown'];
type Project=RuntimeConfig['projects'][number];
function directory(value:unknown):string|null {
  if(typeof value!=='string'||value.includes('\0')||!/^\w:[\\/]/.test(value))return null;
  return win32.normalize(value).replace(/(?<!:)\\$/,'');
}
const key=(value:string)=>directory(value)?.toLowerCase()??null;

export function createProjectCatalog(rpc:RpcClient,configured:Project[],enabled=false) {
  let projects=[...configured],refreshed=0,pending:Promise<Project[]>|undefined;
  const all=()=>projects.map(project=>({...project}));
  function add(list:Project[],cwd:unknown):Project|null {
    const path=directory(cwd);if(!path)return null;
    const existing=list.find(p=>key(p.path)===key(path));if(existing)return existing;
    if(!enabled)return null;
    const project={id:`history_${createHash('sha256').update(key(path)!).digest('hex').slice(0,20)}`,name:win32.basename(path)||path,path};
    list.push(project);return project;
  }
  async function refresh():Promise<Project[]> {
    if(!enabled||Date.now()-refreshed<10000)return all();
    if(pending)return pending;
    pending=(async()=>{
      const next=[...projects];let cursor:string|null=null;
      const cursors=new Set<string>();
      for(let page=0;page<1000;page++) {
        const response=object(await rpc.request('thread/list',{cursor,limit:100,sourceKinds,modelProviders:[],sortKey:'updated_at',sortDirection:'desc',useStateDbOnly:true}));
        for(const raw of Array.isArray(response.data)?response.data:[])add(next,object(raw).cwd);
        if(typeof response.nextCursor!=='string') {projects=next;refreshed=Date.now();return all();}
        if(cursors.has(response.nextCursor))throw new ApiError(503,'upstream_invalid','Project discovery pagination did not advance');
        cursors.add(response.nextCursor);cursor=response.nextCursor;
      }
      throw new ApiError(503,'upstream_invalid','Project discovery pagination exceeded its limit');
    })();
    try{return await pending;}finally{pending=undefined;}
  }
  return {all,refresh,includeDirectory:(cwd:unknown)=>add(projects,cwd),projectForDirectory:(cwd:string)=>projects.find(p=>key(p.path)===key(cwd))??null};
}
