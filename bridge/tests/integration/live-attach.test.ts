import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { probeLiveAttach } from '../../scripts/probe-live-attach.js';
import { fakeServer, handshake } from '../support/fake-server.js';

// Synthetic protocol contract tests. These never establish real CLI feasibility.
async function fixture(t: TestContext, options: { wrongTurn?: boolean; liveCli?: boolean } = {}) {
  const projectDir = await mkdtemp(join(tmpdir(), 'codex-attach-'));
  t.after(() => rm(projectDir, { recursive: true, force: true }));
  const tokenFile = join(projectDir, 'token');
  await writeFile(tokenFile, 'test-only');
  await writeFile(join(projectDir, 'probe-cli.json'), JSON.stringify({
    threadId: 'cli-thread', turnId: 'cli-turn', cliPid: options.liveCli ? process.pid : 2147483647,
    command:'Set-Content marker.txt probe-ok; Start-Sleep -Seconds 25',
  }));
  let executionCount = 0;
  let completed = false;
  const turn = () => ({ id: options.wrongTurn ? 'another-turn' : 'cli-turn', status: completed ? 'completed' : 'inProgress', items: [] });
  const server = await fakeServer((socket, message) => {
    if (handshake(socket, message) || message.method === 'initialized') return;
    if (!message.method) {
      if (message.id === 'approval' && executionCount === 0) {
        executionCount++;
        void writeFile(join(projectDir, 'marker.txt'), 'probe-ok').then(() => {
          completed = true;
          socket.send(JSON.stringify({method:'item/completed',params:{threadId:'cli-thread',turnId:'cli-turn',item:{id:'command',type:'commandExecution',status:'completed',exitCode:0}}}));
          socket.send(JSON.stringify({method:'serverRequest/resolved',params:{threadId:'cli-thread',requestId:'approval'}}));
        });
      }
      return;
    }
    let result: unknown;
    if (message.method === 'thread/read') result = {thread:{id:'cli-thread',cwd:projectDir,turns:[turn()]}};
    else if (message.method === 'thread/turns/list') result = {data:[turn()],nextCursor:null};
    else if (message.method === 'thread/resume') {
      result = {thread:{id:'cli-thread',cwd:projectDir,turns:[turn()]}};
      // Real 0.167.0 replays pending requests asynchronously after the resume reply.
      if (!completed && !process.env.PROBE_FAKE_NO_REPLAY) setTimeout(() => socket.send(JSON.stringify({
        method:'item/commandExecution/requestApproval',id:'approval',params:{threadId:'cli-thread',turnId:'cli-turn',itemId:'command',cwd:projectDir,command:'Set-Content marker.txt probe-ok; Start-Sleep -Seconds 25',availableDecisions:['accept','cancel']},
      })), 10);
    } else throw new Error('Unexpected method ' + message.method);
    socket.send(JSON.stringify({id:message.id,result}));
  });
  t.after(() => server.close());
  return {options:{url:server.url,tokenFile,projectDir}, executionCount:()=>executionCount};
}

test('late_attach_same_live_turn', async t => {
  const f = await fixture(t);
  const result = await probeLiveAttach(f.options);
  assert.equal(result.checks.sameLiveTurn, true);
  assert.equal(result.passed, true, JSON.stringify(result));
  const wrong = await fixture(t, {wrongTurn:true});
  assert.equal((await probeLiveAttach(wrong.options)).checks.sameLiveTurn, false);
});

test('late_approval_can_be_resolved: missing replay cannot pass', async t => {
  const f = await fixture(t);
  const result = await probeLiveAttach(f.options);
  assert.equal(result.checks.lateApproval, true);
  assert.equal(result.checks.duplicateResponseIgnored, true);
  assert.equal(f.executionCount(), 1);
});

test('cli_exit_preserves_task: a still-running CLI cannot prove survival', async t => {
  const f = await fixture(t);
  assert.equal((await probeLiveAttach(f.options)).checks.cliExitPreservesTask, true);
  const live = await fixture(t, {liveCli:true});
  const result = await probeLiveAttach(live.options);
  assert.equal(result.checks.cliExitPreservesTask, false);
  assert.equal(result.passed, false);
  assert.equal(live.executionCount(), 0);
});
