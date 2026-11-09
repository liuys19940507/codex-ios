import { resolve } from 'node:path';
import { readConfig } from '../src/runtime/config.js';
import { ensureBridgeWorker } from '../src/runtime/bridge-worker.js';
try {
  const at=process.argv.indexOf('--config');
  if(at<0||!process.argv[at+1])throw new Error('Required --config path');
  const file=resolve(process.argv[at+1]!);
  console.log(JSON.stringify(await ensureBridgeWorker(await readConfig(file),file)));
}catch{console.error('Bridge startup failed; check the network address, paths and ports.');process.exitCode=1;}
