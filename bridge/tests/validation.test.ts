import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { validateCommand, requireProject, projectForCwd, ApiError } from '../src/api/validation.js';

const command=(method:string,params:unknown)=>({id:randomUUID(),method,params});
const projects=[{id:'app',name:'App',path:'D:\\项目 空格\\app'}];
function rejected(value:unknown,status=400) {
  assert.throws(()=>validateCommand(value),(error:unknown)=>error instanceof ApiError && error.status===status);
}

test('arbitrary_RPC_and_policy_overrides_are_rejected',()=>{
  rejected(command('command/exec',{command:'whoami'}));
  rejected(command('task/create',{projectId:'app',text:'hello',cwd:'C:\\'}));
  rejected(command('task/create',{projectId:'app',text:'hello',approvalPolicy:'never'}));
  rejected(command('task/input',{threadId:'t',text:'hello',mode:'start',sandbox:'danger-full-access'}));
  rejected({...command('thread/archive',{threadId:'t'}),token:'secret'});
  rejected(command('thread/archive',{threadId:'t',extra:true}));
  rejected({id:'not-a-uuid',method:'thread/archive',params:{threadId:'t'}});
});

test('unicode_input_byte_limit_preserves_literal_text',()=>{
  const text='中文;&$\n'+ '😀'.repeat(16380);
  const accepted=validateCommand(command('task/create',{projectId:'app',text}));
  assert.equal(accepted.params.text,text);
  assert.ok(Buffer.byteLength(String(accepted.params.text),'utf8')<=65536);
  rejected(command('task/create',{projectId:'app',text:'😀'.repeat(16385)}),413);
  rejected(command('task/create',{projectId:'app',text:'  '}));
});

test('steer_requires_the_exact_expected_turn',()=>{
  rejected(command('task/input',{threadId:'t',text:'next',mode:'steer'}));
  rejected(command('task/input',{threadId:'t',text:'next',mode:'invalid'}));
  assert.equal(validateCommand(command('task/input',{threadId:'t',text:'next',mode:'steer',expectedTurnId:'turn-1'})).params.expectedTurnId,'turn-1');
});

test('unconfigured_project_is_rejected_without_touching_upstream',()=>{
  assert.equal(requireProject(projects,'app').path,projects[0]!.path);
  assert.throws(()=>requireProject(projects,'elsewhere'),(e:unknown)=>e instanceof ApiError && e.status===404);
});

test('project_boundary_is_windows_case_insensitive_and_not_a_string_prefix',()=>{
  assert.equal(projectForCwd(projects,'d:\\项目 空格\\APP\\src')?.id,'app');
  assert.equal(projectForCwd(projects,'D:\\项目 空格\\app-other'),null);
  assert.equal(projectForCwd(projects,'D:\\项目 空格\\app\\..\\private'),null);
});

test('response_is_bounded_JSON_and_request_identity_is_required',()=>{
  rejected(command('request/respond',{threadId:'t',turnId:'turn',response:{decision:'accept'}}));
  rejected(command('request/respond',{requestId:'r',threadId:'t',turnId:'turn',response:'accept'}));
  assert.deepEqual(validateCommand(command('request/respond',{requestId:'r',threadId:'t',turnId:'turn',response:{decision:'accept'}})).params.response,{decision:'accept'});
});
