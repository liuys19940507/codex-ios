import { readFile, stat } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { connectRpc, type RpcClient } from '../src/protocol/rpc-client.js';
import type { Json } from '../src/api/contracts.js';

type RecordValue = { [key: string]: Json };
const object = (value: Json): RecordValue => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid protocol object');
  return value;
};
const samePath = (a: string, b: string) => process.platform === 'win32'
  ? resolve(a).toLowerCase() === resolve(b).toLowerCase() : resolve(a) === resolve(b);
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch (e) { if ((e as NodeJS.ErrnoException).code === 'ESRCH') return false; throw e; } };
async function until<T>(get:()=>T|undefined, milliseconds=2000): Promise<T|undefined> {
  const deadline=Date.now()+milliseconds;
  do { const found=get(); if(found!==undefined) return found; await delay(20); } while(Date.now()<deadline);
  return undefined;
}

/** This probe only approves the exact command in a separately captured CLI receipt. */
export async function probeLiveAttach(options: {url:string;tokenFile:string;projectDir:string}): Promise<{passed:boolean;checks:Record<string,boolean>;notes:string[]}> {
  const checks: Record<string, boolean> = {sameLiveTurn:false,lateApproval:false,cliExitPreservesTask:false};
  const notes: string[] = [];
  let rpc: RpcClient | undefined;
  let rival: RpcClient | undefined;
  let recovered: RpcClient | undefined;
  try {
    const evidence = JSON.parse((await readFile(join(options.projectDir, 'probe-cli.json'), 'utf8')).replace(/^\uFEFF/, '')) as {threadId:string;turnId:string;cliPid:number;command:string};
    if (!evidence.threadId || !evidence.turnId || !Number.isSafeInteger(evidence.cliPid) || evidence.cliPid <= 0 || !evidence.command)
      throw new Error('Missing independently captured CLI identity, PID or exact approval command');
    if (alive(evidence.cliPid)) { notes.push('NOT RUN: exit-survival requires the controlled CLI process to have exited. No approval sent.'); return {passed:false,checks,notes}; }
    const token = (await readFile(options.tokenFile, 'utf8')).trim();
    rpc = await connectRpc(options.url, token);
    const approvals: RecordValue[] = [];
    const completions = new Set<string>();
    rpc.onEvent(raw => {
      const msg = object(raw);
      if (msg.method === 'item/commandExecution/requestApproval') approvals.push(msg);
      if (msg.method === 'item/completed') {
        const p = object(msg.params!);
        if (p.threadId === evidence.threadId && p.turnId === evidence.turnId) {
          const item = object(p.item!);
          if (item.type === 'commandExecution' && item.status === 'completed' && item.exitCode === 0 && typeof item.id === 'string') completions.add(item.id);
        }
      }
    });
    const read = object(await rpc.request('thread/read', {threadId:evidence.threadId}));
    const thread = object(read.thread!);
    if (typeof thread.cwd !== 'string' || !samePath(thread.cwd, options.projectDir)) throw new Error('CLI project identity mismatch');
    const turns = object(await rpc.request('thread/turns/list', {threadId:evidence.threadId,limit:50,itemsView:'full'}));
    const active = (turns.data as Json[]).map(object).find(t => t.status === 'inProgress');
    const resumed = object(await rpc.request('thread/resume', {threadId:evidence.threadId,excludeTurns:true}));
    checks.sameLiveTurn = thread.id === evidence.threadId && object(resumed.thread!).id === evidence.threadId && active?.id === evidence.turnId;
    if (!checks.sameLiveTurn) { notes.push('FAIL: the CLI receipt does not identify the same active thread and turn.'); return {passed:false,checks,notes}; }
    const approval = await until(() => approvals.find(a => {
      const p = object(a.params!);
      return p.threadId === evidence.threadId && p.turnId === evidence.turnId;
    }));
    if (!approval) { notes.push('FAIL: thread/resume did not replay the existing approval. Remaining cases NOT RUN.'); return {passed:false,checks,notes}; }
    const params = object(approval.params!);
    if (params.command !== evidence.command || typeof params.cwd !== 'string' || !samePath(params.cwd, options.projectDir) || !(params.availableDecisions as Json[])?.includes('accept'))
      throw new Error('Approval differs from the independently captured controlled command');
    const id = approval.id;
    if (typeof id !== 'string' && typeof id !== 'number') throw new Error('Approval ID missing');

    // A second connection owns its own replayed request. A stale reply must not execute again.
    rival = await connectRpc(options.url, token);
    let rivalApproval: RecordValue | undefined;
    rival.onEvent(raw => { const m=object(raw); if(m.method==='item/commandExecution/requestApproval' && object(m.params!).threadId===evidence.threadId) rivalApproval=m; });
    await rival.request('thread/resume', {threadId:evidence.threadId,excludeTurns:true});
    await until(() => rivalApproval);
    rpc.respond(id, {decision:'accept'});
    const deadline = Date.now() + 90_000;
    let completed = false;
    while (Date.now() < deadline) {
      const page = object(await rpc.request('thread/turns/list', {threadId:evidence.threadId,limit:50,itemsView:'full'}));
      const turn = (page.data as Json[]).map(object).find(t => t.id === evidence.turnId);
      if (turn?.status === 'completed') { completed=true; break; }
      if (turn?.status === 'failed' || turn?.status === 'interrupted') break;
      await delay(250);
    }
    const marker = join(options.projectDir, 'marker.txt');
    const content = (await readFile(marker,'utf8')).replace(/^\uFEFF/,'').trim();
    const before = await stat(marker);
    checks.lateApproval = completed && content === 'probe-ok' && completions.size === 1;
    checks.cliExitPreservesTask = checks.lateApproval && !alive(evidence.cliPid);
    if (rivalApproval && (typeof rivalApproval.id === 'string' || typeof rivalApproval.id === 'number')) {
      rival.respond(rivalApproval.id, {decision:'accept'});
      await delay(500);
      const after = await stat(marker);
      checks.duplicateResponseIgnored = completions.size === 1 && before.mtimeMs === after.mtimeMs;
    } else notes.push('NOT RUN: duplicate response; no second pending request was replayed.');
    await rpc.close(); rpc=undefined;
    recovered = await connectRpc(options.url, token);
    const recovery = object(await recovered.request('thread/turns/list', {threadId:evidence.threadId,limit:50,itemsView:'full'}));
    checks.reconnectRestoresState = (recovery.data as Json[]).map(object).some(t => t.id === evidence.turnId && t.status === 'completed');
    notes.push(`Observed ${completions.size} unique successful command completion(s) after late approval.`, 'User question, steer, interrupt and queue: NOT RUN in this controlled command probe.');
  } catch (error) {
    // The receipt contains no secrets; exception text from an upstream service might.
    notes.push(`FAIL: probe stopped (${error instanceof Error ? error.name : 'UnknownError'}). Unobserved cases remain NOT RUN.`);
  } finally { await recovered?.close(); await rival?.close(); await rpc?.close(); }
  return {passed:checks.sameLiveTurn === true && checks.lateApproval === true && checks.cliExitPreservesTask === true,checks,notes};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const arg = (name:string) => { const at=process.argv.indexOf(name); if(at<0 || !process.argv[at+1]) throw new Error(`Required ${name}`); return process.argv[at+1]!; };
  try {
    const result = await probeLiveAttach({url:arg('--url'),tokenFile:arg('--token-file'),projectDir:arg('--project')});
    console.log(JSON.stringify(result,null,2));
    process.exitCode = result.passed ? 0 : 1;
  } catch { console.error('Probe arguments invalid; require --url --token-file --project'); process.exitCode=1; }
}
