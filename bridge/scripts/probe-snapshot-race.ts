import {readFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {connectRpc,type RpcClient} from '../src/protocol/rpc-client.js';
import type {Json} from '../src/api/contracts.js';

type Item={id:string;type:string;text?:string};
type Turn={id:string;items:Item[]};
type Resume={thread:{turns:Turn[]};initialTurnsPage?:{data:Turn[]}};
type Event={method:string;params?:{threadId?:string;turnId?:string;turn?:{id:string};itemId?:string;delta?:string;item?:Item}};
type Options={url:string;tokenFile:string;projectDir:string;threadId:string;mode:'paged'|'full'};
const samePath=(a:string,b:string)=>process.platform==='win32'?resolve(a).toLowerCase()===resolve(b).toLowerCase():resolve(a)===resolve(b);

/** Explicitly opt-in: starts one controlled text-generation turn in a test thread. */
export async function probeSnapshotRace(options:Options) {
  const endpoint=new URL(options.url);
  if(endpoint.protocol!=='ws:'||endpoint.hostname!=='127.0.0.1')throw new Error('Probe requires an owned loopback app-server');
  const receipt=JSON.parse((await readFile(join(options.projectDir,'probe-stream.json'),'utf8')).replace(/^\uFEFF/,'')) as {threadId:string;allowTestTurn:boolean};
  if(receipt.threadId!==options.threadId||receipt.allowTestTurn!==true)throw new Error('Controlled-project receipt missing or mismatched');
  const token=(await readFile(options.tokenFile,'utf8')).trim();
  const primary=await connectRpc(options.url,token);
  let late:RpcClient|undefined;
  let joining:Promise<void>|undefined;
  let joinError:unknown;
  let activeTurnId='';
  let streamCount=0,postCount=0,baselineChars=0;
  let ready=false,completed=false;
  const text=new Map<string,string>(),canonical=new Map<string,string>(),lateFinal=new Map<string,string>();

  async function joinMidStream() {
    late=await connectRpc(options.url,token);
    late.onEvent(raw=>{
      const m=raw as unknown as Event,p=m.params;
      if(!ready||p?.threadId!==options.threadId||p.turnId!==activeTurnId)return;
      if(m.method==='item/agentMessage/delta'&&p.itemId&&typeof p.delta==='string') {
        text.set(p.itemId,(text.get(p.itemId)??'')+p.delta);postCount++;
      }
      if(m.method==='item/completed'&&p.item?.type==='agentMessage'&&typeof p.item.text==='string')lateFinal.set(p.item.id,p.item.text);
    });
    const params=options.mode==='full'?{threadId:options.threadId}:{threadId:options.threadId,excludeTurns:true,initialTurnsPage:{limit:1,itemsView:'full',sortDirection:'desc'}};
    await late.requestAtBarrier('thread/resume',params as Json,raw=>{
      const r=raw as unknown as Resume;
      const turn=(options.mode==='full'?r.thread.turns:r.initialTurnsPage?.data)?.find(t=>t.id===activeTurnId);
      if(!turn)throw new Error('Active turn absent at resume boundary');
      for(const item of turn.items)if(item.type==='agentMessage'&&typeof item.text==='string'){text.set(item.id,item.text);baselineChars+=item.text.length;}
      ready=true;
    });
  }

  primary.onEvent(raw=>{
    const m=raw as unknown as Event,p=m.params;
    if(p?.threadId!==options.threadId)return;
    if(m.method==='turn/started'&&p.turn)activeTurnId=p.turn.id;
    if(p.turnId===activeTurnId&&m.method==='item/agentMessage/delta') {
      streamCount++;
      if(streamCount===3)joining=joinMidStream().catch(error=>{joinError=error;});
    }
    if(p.turnId===activeTurnId&&m.method==='item/completed'&&p.item?.type==='agentMessage'&&typeof p.item.text==='string')canonical.set(p.item.id,p.item.text);
    if(m.method==='turn/completed'&&p.turn?.id===activeTurnId)completed=true;
  });
  try {
    const read=await primary.request('thread/read',{threadId:options.threadId}) as unknown as {thread:{cwd:string;status:{type:string}}};
    if(!samePath(read.thread.cwd,options.projectDir)||!['idle','notLoaded'].includes(read.thread.status.type))throw new Error('Controlled thread must match the project and be idle');
    const resumed=await primary.request('thread/resume',{threadId:options.threadId,excludeTurns:true}) as unknown as {thread:{status:{type:string}}};
    if(resumed.thread.status.type!=='idle')throw new Error('Controlled thread is not idle after resume');
    const started=await primary.request('turn/start',{threadId:options.threadId,input:[{type:'text',text:'For this isolated streaming-consistency test, output exactly 400 numbered lines. Each line must have its three-digit number followed by the words snapshot boundary validation. Do not call tools or agents and do not add an introduction or explanation.',text_elements:[]}]}) as unknown as {turn:{id:string}};
    activeTurnId=started.turn.id;
    const deadline=Date.now()+120000;
    while(!completed&&Date.now()<deadline)await delay(100);
    await joining;
    if(joinError)throw joinError;
    await delay(100);
    const observed=ready&&completed&&postCount>0&&canonical.size>0;
    const immediatePrefixPassed=observed&&[...canonical].every(([id,full])=>text.get(id)===full);
    const completedRecoveryPassed=observed&&[...canonical].every(([id,full])=>lateFinal.get(id)===full);
    return {mode:options.mode,observed,streamCount,postCount,baselineChars,messageCount:canonical.size,
      totalChars:[...canonical.values()].reduce((n,s)=>n+s.length,0),
      messages:[...canonical].map(([id,full])=>({expectedChars:full.length,assembledChars:text.get(id)?.length??0,sameItemId:text.has(id)})),
      immediatePrefixPassed,completedRecoveryPassed};
  } finally {await late?.close();await primary.close();}
}

if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  const arg=(name:string)=>{const at=process.argv.indexOf(name);if(at<0||!process.argv[at+1])throw new Error('Missing argument');return process.argv[at+1]!;};
  try {
    const mode=arg('--mode');if(mode!=='paged'&&mode!=='full')throw new Error('Invalid mode');
    const report=await probeSnapshotRace({url:arg('--url'),tokenFile:arg('--token-file'),projectDir:arg('--project'),threadId:arg('--thread'),mode});
    console.log(JSON.stringify(report,null,2));process.exitCode=report.immediatePrefixPassed?0:1;
  } catch {console.error('Snapshot probe stopped; require an owned test thread, receipt, and --url --token-file --project --thread --mode paged|full.');process.exitCode=1;}
}
