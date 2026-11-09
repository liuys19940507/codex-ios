import test from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { apiFixture } from './support/api-fixture.js';
import { sendEventFrame } from '../src/api/server.js';

test('unauthorized_upgrade_is_rejected_before_websocket_acceptance',async t=>{
  const f=await apiFixture(t),socket=new WebSocket(f.url.replace('http','ws')+'/v1/events?epoch=epoch&after=0');
  const status=await new Promise<number>((resolve,reject)=>{
    socket.once('unexpected-response',(_request,response)=>{response.resume();socket.terminate();resolve(response.statusCode!);});
    socket.once('open',()=>reject(new Error('Unauthenticated socket accepted')));socket.on('error',()=>{});
  });
  assert.equal(status,401);
});

test('events_replay_global_cursor_then_stream_live_events_in_order',async t=>{
  const f=await apiFixture(t);f.emit('other');f.emit('selected');
  const socket=new WebSocket(f.url.replace('http','ws')+'/v1/events?epoch=epoch&after=0',{headers:f.headers});
  t.after(()=>socket.terminate());
  const received:any[]=[];
  await new Promise<void>((resolve,reject)=>{
    socket.on('error',reject);socket.on('message',bytes=>{received.push(JSON.parse(bytes.toString()));if(received.length===2)f.emit('selected');if(received.length===3)resolve();});
  });
  assert.deepEqual(received.map(e=>e.cursor.seq),[1,2,3]);assert.equal(received[0].threadId,'other');
});

test('invalid_old_or_future_cursors_require_resync_and_close',async t=>{
  const f=await apiFixture(t);
  for(const query of ['epoch=old&after=0','epoch=epoch&after=20','epoch=epoch&after=-1','after=0']) {
    const socket=new WebSocket(f.url.replace('http','ws')+'/v1/events?'+query,{headers:f.headers});
    const frames:any[]=[];
    await new Promise<void>((resolve,reject)=>{socket.on('message',bytes=>frames.push(JSON.parse(bytes.toString())));socket.on('close',()=>resolve());socket.on('error',reject);});
    assert.deepEqual(frames,[{type:'resync_required'}]);
  }
});

test('slow_consumer_resyncs_before_more_event_payloads_are_buffered',()=>{
  const frames:string[]=[],closes:number[]=[];
  const peer={readyState:WebSocket.OPEN,bufferedAmount:1048577,send:(text:string)=>frames.push(text),close:(code:number)=>closes.push(code)};
  assert.equal(sendEventFrame(peer,{cursor:{epoch:'epoch',seq:1}}),false);
  assert.deepEqual(frames.map(s=>JSON.parse(s)),[{type:'resync_required'}]);assert.deepEqual(closes,[1013]);
});
