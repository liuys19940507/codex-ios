import { win32 } from 'node:path';
import type { Command, Json } from './contracts.js';
import type { RuntimeConfig } from '../runtime/config.js';

export class ApiError extends Error {
  constructor(public readonly status:number,public readonly code:string,message:string) {
    super(message); this.name='ApiError';
  }
}
type RecordValue=Record<string,unknown>;
type Project=RuntimeConfig['projects'][number];
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const fields:Record<Command['method'],string[]>={
  'task/create':['projectId','text','model','reasoning','attachments'],
  'task/input':['threadId','text','mode','expectedTurnId','attachments'],
  'task/interrupt':['threadId','turnId'],
  'request/respond':['requestId','threadId','turnId','response'],
  'thread/rename':['threadId','title'],
  'thread/archive':['threadId'],
  'thread/attach':['threadId','attachmentId'],
  'thread/release':['threadId','attachmentId'],
};
function invalid(message:string):never { throw new ApiError(400,'invalid_request',message); }
function record(value:unknown):RecordValue {
  if (!value || typeof value!=='object' || Array.isArray(value)) invalid('Expected a JSON object');
  return value as RecordValue;
}
function only(value:RecordValue,allowed:string[]):void {
  if(Object.keys(value).some(key=>!allowed.includes(key))) invalid('Unsupported request field');
}
function string(value:unknown,name:string,maxBytes=256):asserts value is string {
  if(typeof value!=='string'||!value.trim()) invalid(`${name} must be a nonempty string`);
  if(Buffer.byteLength(value,'utf8')>maxBytes) throw new ApiError(413,'too_large',`${name} exceeds its byte limit`);
}
function submission(p:RecordValue) {
  if(p.attachments===undefined){string(p.text,'text',65536);return;}
  if(!Array.isArray(p.attachments)||p.attachments.length===0||p.attachments.length>10||p.attachments.some(id=>typeof id!=='string'||!uuid.test(id)))invalid('Use at most10 attachment UUIDs');
  if(new Set((p.attachments as string[]).map(id=>id.toLowerCase())).size!==p.attachments.length)invalid('Duplicate attachment UUID');
  if(typeof p.text!=='string')invalid('text must be a string');
  if(Buffer.byteLength(p.text,'utf8')>65536)throw new ApiError(413,'too_large','text exceeds its byte limit');
}
export function validateCommand(value:unknown):Command {
  const c=record(value); only(c,['id','method','params']);
  if(typeof c.id!=='string'||!uuid.test(c.id)) invalid('Command id must be a UUID');
  if(typeof c.method!=='string'||!Object.hasOwn(fields,c.method)) invalid('Unsupported command');
  const method=c.method as Command['method'],p=record(c.params);only(p,fields[method]);
  if(method==='task/create') {
    string(p.projectId,'projectId');submission(p);
    if(p.model!==undefined) string(p.model,'model');
    if(p.reasoning!==undefined) string(p.reasoning,'reasoning',64);
  } else {
    string(p.threadId,'threadId');
    if(method==='thread/attach'||method==='thread/release') {
      if(typeof p.attachmentId!=='string'||!uuid.test(p.attachmentId))invalid('Attachment id must be a UUID');
    }
    if(method==='task/input') {
      submission(p);
      if(!['start','steer','queue'].includes(String(p.mode))) invalid('Unsupported input mode');
      if(p.mode==='steer'||p.expectedTurnId!==undefined) string(p.expectedTurnId,'expectedTurnId');
    } else if(method==='task/interrupt') string(p.turnId,'turnId');
    else if(method==='thread/rename') string(p.title,'title',512);
    else if(method==='request/respond') {
      string(p.turnId,'turnId');string(p.requestId,'requestId');record(p.response);
      if(Buffer.byteLength(JSON.stringify(p.response),'utf8')>65536) throw new ApiError(413,'too_large','Response exceeds its byte limit');
    }
  }
  return {id:c.id,method,params:p as Record<string,Json>};
}
export function requireProject(projects:Project[],id:string):Project {
  const project=projects.find(p=>p.id===id);
  if(!project) throw new ApiError(404,'not_found','Project is not configured');
  return project;
}
export function projectForCwd(projects:Project[],cwd:string):Project|null {
  return [...projects].sort((a,b)=>b.path.length-a.path.length).find(p=>{
    const relative=win32.relative(win32.resolve(p.path).toLowerCase(),win32.resolve(cwd).toLowerCase());
    return relative===''||(!relative.startsWith('..\\')&&relative!=='..'&&!win32.isAbsolute(relative));
  })??null;
}
