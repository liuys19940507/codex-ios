import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, open, readFile, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import { extname, isAbsolute, join, relative, resolve } from 'node:path';
import { ApiError } from './validation.js';
import type { RuntimeConfig } from '../runtime/config.js';
// The pinned generated schema uses extensionless internal imports; keep this
// narrow projection module-compatible without modifying generated sources.
type UserInput={type:'text';text:string;text_elements:[]}|{type:'image';url:string}|{type:'localImage';path:string};

export const MAX_ATTACHMENT_BYTES=20*1024*1024;
export const MAX_ATTACHMENTS=10;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const kinds=['image','file','imageURL','serverImage'] as const;
type Kind=typeof kinds[number];
type Project=RuntimeConfig['projects'][number];
export type UploadRequest={id:string;projectId:string;name:string;kind:Kind;base64?:string;location?:string};
export type AttachmentReceipt={id:string;name:string;kind:Kind;size:number};
export type AttachmentResource=AttachmentReceipt&{projectId:string;location:string;digest:string;projectRoot?:string};
type Saved=AttachmentResource&{payloadName?:string};
function fail(message:string,status=400):never {throw new ApiError(status,'invalid_attachment',message);}
const bytes=(value:string)=>Buffer.byteLength(value,'utf8');
function inside(root:string,file:string) {const part=relative(root,file);return part===''||(!part.startsWith('..'+(process.platform==='win32'?'\\':'/'))&&part!=='..'&&!isAbsolute(part));}
function name(value:unknown):asserts value is string {
  if(typeof value!=='string'||!value.trim()||bytes(value)>512||/[\x00-\x1f\x7f/\\]/.test(value)||value==='.'||value==='..')fail('Invalid attachment filename');
}
export function validateAttachmentIds(value:unknown):string[] {
  if(!Array.isArray(value)||value.length===0||value.length>MAX_ATTACHMENTS||value.some(id=>typeof id!=='string'||!uuid.test(id)))fail('Use at most10 attachment UUIDs');
  const ids=(value as string[]).map(id=>id.toLowerCase());
  if(new Set(ids).size!==ids.length)fail('Duplicate attachment UUID');
  return ids;
}
export function validateUpload(raw:unknown):UploadRequest {
  if(!raw||typeof raw!=='object'||Array.isArray(raw))fail('Expected an attachment object');
  const value=raw as Record<string,unknown>;
  if(Object.keys(value).some(key=>!['id','projectId','name','kind','base64','location'].includes(key)))fail('Unsupported attachment field');
  if(typeof value.id!=='string'||!uuid.test(value.id))fail('Attachment id must be a UUID');
  if(typeof value.projectId!=='string'||!value.projectId.trim()||bytes(value.projectId)>256)fail('Invalid project scope');
  name(value.name);
  if(!kinds.includes(value.kind as Kind))fail('Invalid attachment kind');
  if(value.kind==='image'||value.kind==='file') {
    if(value.location!==undefined||typeof value.base64!=='string'||!value.base64)fail('Attachment data is required');
    if(value.base64.length>Math.ceil(MAX_ATTACHMENT_BYTES/3)*4)fail('Attachment exceeds20MiB limit',413);
    if(!/^[A-Za-z0-9+/]*={0,2}$/.test(value.base64))fail('Invalid base64 attachment');
  } else if(value.base64!==undefined||typeof value.location!=='string'||!value.location.trim()||bytes(value.location)>32768||/[\x00-\x1f]/.test(value.location))fail('Invalid image location');
  return {...value,id:value.id.toLowerCase()} as UploadRequest;
}
function image(data:Buffer) {
  const png=data.length>=24&&data.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))&&data.subarray(12,16).toString()==='IHDR';
  const jpeg=data.length>4&&data[0]===255&&data[1]===216&&data[2]===255&&data[data.length-2]===255&&data[data.length-1]===217;
  if(!png&&!jpeg)fail('Use a PNG or JPEG image');
}
async function boundedRead(file:string):Promise<Buffer> {
  const handle=await open(file,'r');
  try {
    if(!(await handle.stat()).isFile())fail('Attachment is not a regular file');
    const chunks:Buffer[]=[];let total=0;
    while(true) {
      const buffer=Buffer.alloc(Math.min(65536,MAX_ATTACHMENT_BYTES+1-total));
      const {bytesRead}=await handle.read(buffer,0,buffer.length,null);
      if(!bytesRead)break;
      total+=bytesRead;if(total>MAX_ATTACHMENT_BYTES)fail('Attachment exceeds20MiB limit',413);
      chunks.push(buffer.subarray(0,bytesRead));
    }
    if(!total)fail('Empty attachment');return Buffer.concat(chunks);
  } finally {await handle.close();}
}
const receipt=(resource:AttachmentResource):AttachmentReceipt=>({id:resource.id,name:resource.name,kind:resource.kind,size:resource.size});
export function createAttachmentStore(directory:string) {
  const root=resolve(directory),work=new Map<string,Promise<unknown>>();
  async function load(id:string):Promise<Saved> {
    try {
      const folder=join(root,id),value=JSON.parse(await readFile(join(folder,'metadata.json'),'utf8')) as Saved;
      if(value.id!==id||typeof value.projectId!=='string'||!kinds.includes(value.kind)||!/^[a-f0-9]{64}$/.test(value.digest)||!Number.isInteger(value.size)||value.size<0||value.size>MAX_ATTACHMENT_BYTES)fail('Saved attachment metadata is invalid',409);
      name(value.name);
      if(value.kind==='image'||value.kind==='file') {
        if(typeof value.payloadName!=='string'||!/^payload(?:\.[a-z0-9]{1,10})?$/.test(value.payloadName))fail('Saved attachment path is invalid',409);
        value.location=join(folder,value.payloadName);
        const actual=await realpath(value.location);
        if(!inside(await realpath(folder),actual)||(await stat(actual)).isDirectory())fail('Saved attachment path is outside its storage scope',409);
        value.location=actual;
      } else if(value.kind==='serverImage') {
        if(typeof value.projectRoot!=='string'||!inside(value.projectRoot,await realpath(value.location)))fail('Image is outside the project scope',409);
        const data=await boundedRead(value.location);image(data);
        if(createHash('sha256').update(data).digest('hex')!==value.digest)fail('The server image changed; add it again',409);
      }
      return value;
    } catch(error) {
      if((error as NodeJS.ErrnoException).code==='ENOENT')throw new ApiError(404,'attachment_missing','Attachment was not found');
      throw error;
    }
  }
  async function saveNow(value:UploadRequest,project:Project):Promise<AttachmentReceipt> {
    if(value.projectId!==project.id)fail('Attachment project scope mismatch',403);
    let data:Buffer|undefined,location=value.location??'',projectRoot:string|undefined;
    if(value.kind==='image'||value.kind==='file') {
      data=Buffer.from(value.base64!,'base64');
      if(data.length===0||data.length>MAX_ATTACHMENT_BYTES)fail('Attachment exceeds20MiB limit or is empty',413);
      if(data.toString('base64')!==value.base64)fail('Invalid base64 attachment');
      if(value.kind==='image')image(data);
    } else if(value.kind==='imageURL') {
      let url:URL;try{url=new URL(location);}catch{fail('Invalid image URL');}
      if(!['http:','https:'].includes(url.protocol)||url.username||url.password)fail('Use an HTTP(S) image URL without credentials');
    } else {
      const lexical=resolve(project.path);
      if(!isAbsolute(location)||!inside(lexical,resolve(location)))fail('Image path is outside the project scope',403);
      projectRoot=await realpath(project.path);location=await realpath(location);
      if(!inside(projectRoot,location))fail('Image path is outside the project scope',403);
      data=await boundedRead(location);image(data);
    }
    const digest=createHash('sha256').update(data??Buffer.from(location)).digest('hex');
    const record:Saved={id:value.id,projectId:value.projectId,name:value.name,kind:value.kind,size:data?.length??0,location,digest,...(projectRoot?{projectRoot}:{})};
    const folder=join(root,value.id);
    try {
      await stat(folder);
      const old=await load(value.id);
      if(old.projectId!==record.projectId||old.name!==record.name||old.kind!==record.kind||old.digest!==record.digest)fail('Attachment UUID reuse conflicts with different content',409);
      return receipt(old);
    } catch(error) {if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error;}
    await mkdir(root,{recursive:true});
    const stage=await mkdtemp(join(root,'.stage-'));
    try {
      if(value.kind==='image'||value.kind==='file') {
        const extension=extname(value.name).toLowerCase();
        record.payloadName='payload'+(/^\.[a-z0-9]{1,10}$/.test(extension)?extension:'.bin');
        record.location=join(folder,record.payloadName);
        await writeFile(join(stage,record.payloadName),data!,{flag:'wx',mode:0o600});
      }
      await writeFile(join(stage,'metadata.json'),JSON.stringify(record),{flag:'wx',mode:0o600});
      await rename(stage,folder);return receipt(record);
    } finally {
      // Only the owned staging child may be recursively removed.
      if(inside(root,stage)&&relative(root,stage).startsWith('.stage-'))await rm(stage,{recursive:true,force:true});
    }
  }
  async function save(raw:unknown,project:Project) {
    const value=validateUpload(raw),previous=work.get(value.id)??Promise.resolve();
    const task=previous.catch(()=>{}).then(()=>saveNow(value,project));work.set(value.id,task);
    try{return await task;}finally{if(work.get(value.id)===task)work.delete(value.id);}
  }
  async function resources(ids:string[],projectId:string) {
    const result:AttachmentResource[]=[];
    for(const id of validateAttachmentIds(ids)) {
      const resource=await load(id);
      if(resource.projectId!==projectId)fail('Attachment belongs to another project scope',403);
      result.push(resource);
    }
    return result;
  }
  return {save,resolve:resources};
}
export type AttachmentStore=ReturnType<typeof createAttachmentStore>;
export function attachmentInput(text:string,resources:AttachmentResource[]):UserInput[] {
  const files=resources.filter(item=>item.kind==='file');
  const references=files.length?'附件文件已保存在 Windows，可用现有工具读取：\n'+files.map(item=>`- ${JSON.stringify(item.name)}: ${item.location}`).join('\n'):'';
  const content=[text,references].filter(Boolean).join('\n\n'),parts:UserInput[]=content?[{type:'text',text:content,text_elements:[]}]:[];
  for(const resource of resources) {
    if(resource.kind==='imageURL')parts.push({type:'image',url:resource.location});
    else if(resource.kind==='image'||resource.kind==='serverImage')parts.push({type:'localImage',path:resource.location});
  }
  return parts;
}
