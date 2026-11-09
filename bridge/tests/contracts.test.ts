import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateCommand } from '../src/api/validation.js';

test('shared_mobile_fixtures_cover_cursor_order_partial_output_and_uncertain_operations',async()=>{
  const fixture=async(name:string)=>JSON.parse(await readFile(new URL(`../../contracts/fixtures/${name}.json`,import.meta.url),'utf8'));
  const [info,projects,models,threads,snapshot,events,operations,errors]=await Promise.all(['info','projects','models','threads','snapshot','events','operations','errors'].map(fixture));
  assert.equal(info.apiVersion,1);assert.equal(info.codexVersion,'0.167.0');
  assert.equal(snapshot.thread.projectId,projects[0].id);assert.ok(models[0].reasoning.includes('medium'));
  assert.equal(threads.data[1].parentId,threads.data[0].id);
  assert.equal(snapshot.items[0].data.prefixComplete,false);assert.ok(snapshot.items[0].text.includes('\r\n'));
  assert.deepEqual(events.map((e:any)=>e.cursor.seq),[3,4]);assert.notEqual(events[0].threadId,snapshot.thread.id);
  assert.equal(operations[0].state,'unknown');assert.equal(operations[1].state,'accepted');assert.equal(errors[0].code,'request_expired');
  const p=snapshot.pending[0];
  validateCommand({id:operations[0].id,method:'request/respond',params:{threadId:p.threadId,turnId:p.turnId,requestId:p.id,response:{decision:p.options.availableDecisions[0]}}});
});
