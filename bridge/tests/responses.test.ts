import test from 'node:test';
import assert from 'node:assert/strict';
import type { Json, Pending } from '../src/api/contracts.js';
import { validatePendingResponse } from '../src/api/responses.js';
import { ApiError } from '../src/api/validation.js';

const features={approvals:true,fileApprovals:true,permissions:true,questions:true,mcp:true};
const pending=(kind:Pending['kind'],options:Json):Pending=>({id:'request',threadId:'thread',turnId:'turn',kind,prompt:'Review',options,state:'pending'});
const rejects=(p:Pending,response:Json)=>assert.throws(()=>validatePendingResponse(p,response,features),(e:unknown)=>e instanceof ApiError&&[400,409].includes(e.status));

test('file_approval_supports_once_decline_cancel_without_session_grants',()=>{
  const p=pending('file',{});
  for(const decision of ['accept','decline','cancel'])assert.deepEqual(validatePendingResponse(p,{decision},features),{decision});
  rejects(p,{decision:'acceptForSession'});rejects(p,{decision:'accept',grantRoot:'C:/'});
  assert.throws(()=>validatePendingResponse(p,{decision:'accept'},{...features,fileApprovals:false}));
});

test('question_responses_match_server_ids_choices_and_freeform_rules',()=>{
  const p=pending('question',{questions:[
    {id:'choice',header:'Choice',question:'Choose',isOther:false,isSecret:false,options:[{label:'One',description:'First'}]},
    {id:'secret',header:'Secret',question:'Value',isOther:true,isSecret:true,options:null}
  ]});
  const response={answers:{choice:{answers:['One']},secret:{answers:['中文;&$']}}};
  assert.deepEqual(validatePendingResponse(p,response,features),response);
  rejects(p,{answers:{choice:{answers:['Invented']},secret:{answers:['value']}}});
  rejects(p,{answers:{choice:{answers:['One']}}});
  rejects(p,{...response,extra:true});
});

test('permissions_can_only_grant_requested_paths_and_turn_scope',()=>{
  const p=pending('permission',{permissions:{network:{enabled:true},fileSystem:{read:['C:/project'],write:['C:/project/out']}}});
  const response={permissions:{network:{enabled:true},fileSystem:{read:['C:/project'],write:null}},scope:'turn'};
  assert.deepEqual(validatePendingResponse(p,response,features),response);
  assert.deepEqual(validatePendingResponse(p,{permissions:{},scope:'turn'},features),{permissions:{},scope:'turn'});
  rejects(p,{permissions:{fileSystem:{read:null,write:['C:/']}},scope:'turn'});
  rejects(p,{permissions:{},scope:'session'});
  rejects(p,{permissions:{network:{enabled:true}},scope:'turn',strictAutoReview:false});
  rejects(pending('permission',{permissions:{network:null,fileSystem:null}}),{permissions:{network:{enabled:true}},scope:'turn'});
});

test('mcp_forms_validate_required_fields_enums_unicode_and_bounds',()=>{
  const p=pending('mcp',{mode:'form',serverName:'controlled',requestedSchema:{type:'object',properties:{
    title:{type:'string',minLength:2,maxLength:8},count:{type:'integer',minimum:1,maximum:3},
    selected:{type:'string',oneOf:[{const:'one',title:'One'},{const:'two',title:'Two'}]},enabled:{type:'boolean'}
  },required:['title','count','selected']}});
  const response={action:'accept',content:{title:'中文',count:2,selected:'one',enabled:false},_meta:null};
  assert.deepEqual(validatePendingResponse(p,response,features),response);
  const invalidContents:Json[]=[{title:'x',count:2,selected:'one'},{title:'okay',count:4,selected:'one'},
    {title:'okay',count:2.5,selected:'one'},{title:'okay',count:2,selected:'invented'},
    {title:'okay',count:2,selected:'one',unknown:'extra'}];
  for(const content of invalidContents)rejects(p,{action:'accept',content,_meta:null});
  assert.deepEqual(validatePendingResponse(p,{action:'cancel',content:null,_meta:null},features),{action:'cancel',content:null,_meta:null});
});

test('unsupported_mcp_modes_and_schemas_remain_read_only',()=>{
  const cases:Json[]=[{mode:'url',url:'https://example.com'},{mode:'openai/form',requestedSchema:{}},
    {mode:'form',requestedSchema:{type:'object',properties:{nested:{type:'object',properties:{}}}}}];
  for(const options of cases) {
    rejects(pending('mcp',options),{action:'accept',content:{},_meta:null});
  }
});
