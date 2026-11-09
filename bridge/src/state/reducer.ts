import type { Item, Json, ThreadSummary } from '../api/contracts.js';
import type { Store } from './store.js';
import { ApiError } from '../api/validation.js';

export function object(value:unknown):Record<string,any> {
  return value!==null&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,any>:{};
}
export function summary(raw:unknown,store:Store):ThreadSummary {
  const thread=object(raw),project=store.project(String(thread.cwd??''));
  if(!project||typeof thread.id!=='string')throw new ApiError(404,'not_found','Thread is outside configured projects');
  const turns=Array.isArray(thread.turns)?thread.turns:[];
  const active=turns.find((turn:unknown)=>object(turn).status==='inProgress');
  return {id:thread.id,projectId:project.id,title:thread.name||String(thread.preview??'').slice(0,120)||'Untitled task',
    status:String(object(thread.status).type??'unknown'),activeTurnId:active?String(active.id):null,parentId:thread.parentThreadId??null};
}
export function projectItem(raw:unknown,turnId:string,completed:boolean,prefixComplete=completed):Item {
  const item=object(raw),kind=String(item.type??'unknown');
  let text='',data:Record<string,Json>={completed,prefixComplete};
  if(kind==='agentMessage'||kind==='plan')text=String(item.text??'');
  else if(kind==='userMessage') {
    text=(Array.isArray(item.content)?item.content:[]).filter((p:unknown)=>object(p).type==='text').map((p:unknown)=>String(object(p).text??'')).join('\n');
    data.prefixComplete=true;data.completed=true;
  } else if(kind==='commandExecution') {
    text=String(item.aggregatedOutput??'');
    data={...data,command:String(item.command??''),status:String(item.status??'unknown'),exitCode:typeof item.exitCode==='number'?item.exitCode:null};
  } else if(kind==='fileChange')data={...data,changes:Array.isArray(item.changes)?item.changes:[],status:String(item.status??'unknown')};
  else if(kind==='reasoning')text=(Array.isArray(item.summary)?item.summary:[]).join('\n');
  else if(kind==='collabAgentToolCall')data={...data,tool:String(item.tool??''),status:String(item.status??''),childThreadIds:Array.isArray(item.receiverThreadIds)?item.receiverThreadIds:[]};
  else if(kind==='mcpToolCall')data={...data,server:String(item.server??''),tool:String(item.tool??''),status:String(item.status??''),result:item.result??null,error:item.error??null};
  else if(kind==='dynamicToolCall')data={...data,tool:String(item.tool??''),status:String(item.status??'')};
  else text=`Unsupported activity: ${kind}`;
  return {id:String(item.id),turnId,kind,text,data};
}
