import { resolve } from 'node:path';
import { readFile } from 'node:fs/promises';
import { readConfig } from '../src/runtime/config.js';
import { ensureService, inspectService, stopService } from '../src/runtime/service.js';
import { connectRpc } from '../src/protocol/rpc-client.js';
import { join } from 'node:path';

try {
  const at=process.argv.indexOf('--config');
  if(at<0||!process.argv[at+1]) throw new Error('Required --config absolute JSON path');
  const config=await readConfig(resolve(process.argv[at+1]!));
  const stopAt=process.argv.indexOf('--stop');
  if(stopAt>=0) {await stopService(config,process.argv[stopAt+1]??'');console.log(JSON.stringify({stopped:true}));}
  else if(process.argv.includes('--status')) {
    const owned=await inspectService(config);
    if(!owned) console.log(JSON.stringify({service:null,threads:[]}));
    else {
      const rpc=await connectRpc(owned.info.codexUrl,(await readFile(join(config.stateDir,'codex-token'),'utf8')).trim());
      try { const threads=await rpc.request('thread/loaded/list',{}); console.log(JSON.stringify({service:owned.info,threads})); }
      finally {await rpc.close();}
    }
  } else console.log(JSON.stringify(await ensureService(config)));
} catch(error) {
  console.error(error instanceof Error ? error.message : 'Service operation failed');
  process.exitCode=1;
}
