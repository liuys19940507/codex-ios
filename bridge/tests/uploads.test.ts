import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAttachmentStore, validateUpload, attachmentInput } from '../src/api/uploads.js';

const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZfoAAAAASUVORK5CYII=','base64');
async function fixture(t:TestContext) {
  const root=await mkdtemp(join(tmpdir(),'codex-uploads-'));
  const project={id:'project',name:'Controlled',path:root};
  t.after(()=>rm(root,{recursive:true,force:true}));
  return {root,project,store:createAttachmentStore(join(root,'uploads'))};
}
const upload=(extra:Record<string,unknown>={})=>({id:randomUUID(),projectId:'project',name:'中文 😀.txt',kind:'file',base64:Buffer.from('UPLOAD_CONTENT_中文').toString('base64'),...extra});

test('uploads_preserve_bytes_and_names_and_resolve_after_restart',async t=>{
  const f=await fixture(t),request=upload();
  const receipt=await f.store.save(request,f.project);
  assert.equal(receipt.name,request.name);assert.equal(receipt.size,Buffer.byteLength('UPLOAD_CONTENT_中文'));
  assert.equal('location' in receipt,false,'Do not expose a server path in upload receipts');
  const reopened=createAttachmentStore(join(f.root,'uploads'));
  const [resource]=await reopened.resolve([request.id],'project');
  assert.equal(await readFile(resource!.location,'utf8'),'UPLOAD_CONTENT_中文');
  assert.equal(resource!.name,request.name);
});

test('same_upload_uuid_is_idempotent_but_cannot_replace_other_content',async t=>{
  const f=await fixture(t),request=upload();
  const receipts=await Promise.all([f.store.save(request,f.project),f.store.save(request,f.project)]);
  assert.deepEqual(receipts[0],receipts[1]);
  await assert.rejects(f.store.save({...request,base64:Buffer.from('changed').toString('base64')},f.project),/conflict|different|reuse/i);
  const [saved]=await f.store.resolve([request.id],'project');
  assert.equal(await readFile(saved!.location,'utf8'),'UPLOAD_CONTENT_中文');
});

test('attachment_resolution_rejects_other_projects_missing_and_deleted_files',async t=>{
  const f=await fixture(t),request=upload();await f.store.save(request,f.project);
  await assert.rejects(f.store.resolve([request.id],'other-project'),/project|scope/i);
  await assert.rejects(f.store.resolve([randomUUID()],'project'),/found|missing/i);
  const [saved]=await f.store.resolve([request.id],'project');await rm(saved!.location);
  await assert.rejects(f.store.resolve([request.id],'project'),/found|missing/i);
});

test('changed_stored_bytes_are_rejected_before_they_reach_a_turn',async t=>{
  const f=await fixture(t),request=upload();await f.store.save(request,f.project);
  const [saved]=await f.store.resolve([request.id],'project');
  await writeFile(saved!.location,'unexpected changed content');
  await assert.rejects(f.store.resolve([request.id],'project'),/changed|corrupt|content/i);
});

test('malformed_empty_oversized_and_path_like_uploads_are_rejected',async t=>{
  const f=await fixture(t);
  for(const request of [upload({id:'../outside'}),upload({name:'../outside.txt'}),upload({name:'bad\nname.txt'}),upload({base64:'%%%'}),upload({base64:''}),upload({base64:'YQ'}),upload({extra:true}),upload({kind:'script'})]) {
    await assert.rejects(f.store.save(request,f.project));
  }
  await assert.rejects(f.store.save(upload({base64:Buffer.alloc(20*1024*1024+1).toString('base64')}),f.project),/20|limit|large/i);
  assert.throws(()=>validateUpload(upload({projectId:'',name:'valid.txt'})));
  await assert.rejects(f.store.save(upload({projectId:'outside'}),f.project),/project|scope/i);
});

test('image_uploads_are_verified_and_resolve_to_native_local_images',async t=>{
  const f=await fixture(t),request=upload({name:'picture.png',kind:'image',base64:png.toString('base64')});
  await f.store.save(request,f.project);
  const resources=await f.store.resolve([request.id],'project');
  assert.deepEqual(await readFile(resources[0]!.location),png);
  assert.deepEqual(attachmentInput('',resources),[{type:'localImage',path:resources[0]!.location}]);
  await assert.rejects(f.store.save(upload({kind:'image',name:'fake.png'}),f.project),/image|PNG|JPEG/i);
});

test('remote_image_urls_are_registered_without_download_and_reject_other_schemes',async t=>{
  const f=await fixture(t),request={id:randomUUID(),projectId:'project',name:'图片地址',kind:'imageURL',location:'https://example.invalid/image.png'};
  await f.store.save(request,f.project);
  const resources=await f.store.resolve([request.id],'project');
  assert.deepEqual(attachmentInput('look',resources),[{type:'text',text:'look',text_elements:[]},{type:'image',url:request.location}]);
  for(const location of ['file:///C:/secret.png','ftp://host/a.png','https://name:password@example.invalid/a.png']) {
    await assert.rejects(f.store.save({...request,id:randomUUID(),location},f.project));
  }
});

test('server_image_paths_stay_inside_the_authorized_project',async t=>{
  const f=await fixture(t),image=join(f.root,'existing.png');await writeFile(image,png);
  const request={id:randomUUID(),projectId:'project',name:'已有图片',kind:'serverImage',location:image};
  await f.store.save(request,f.project);
  assert.equal((await f.store.resolve([request.id],'project'))[0]!.location,image);
  await assert.rejects(f.store.save({...request,id:randomUUID(),location:join(f.root,'..','outside.png')},f.project),/project|scope|outside/i);
});

test('file_references_keep_original_text_and_do_not_evaluate_the_file',async t=>{
  const f=await fixture(t),request=upload({name:'报价 单.pdf'});await f.store.save(request,f.project);
  const resources=await f.store.resolve([request.id],'project'),parts=attachmentInput('请检查这份文件',resources);
  assert.equal(parts.length,1);assert.equal(parts[0]!.type,'text');
  const text=(parts[0] as {text:string}).text;
  assert.ok(text.startsWith('请检查这份文件'));
  assert.ok(text.includes(request.name));assert.ok(text.includes(resources[0]!.location));
  assert.equal(await readFile(resources[0]!.location,'utf8'),'UPLOAD_CONTENT_中文');
});
