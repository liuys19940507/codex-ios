import { resolve } from 'node:path';
import { readConfig } from '../src/runtime/config.js';
import { ensureService, getServiceStatus, stopService } from '../src/runtime/service.js';

try {
  const at=process.argv.indexOf('--config');
  if(at<0||!process.argv[at+1]) throw new Error('Required --config absolute JSON path');
  const config=await readConfig(resolve(process.argv[at+1]!));
  const stopAt=process.argv.indexOf('--stop');
  if(stopAt>=0) {await stopService(config,process.argv[stopAt+1]??'');console.log(JSON.stringify({stopped:true}));}
  else if(process.argv.includes('--status')) {
    console.log(JSON.stringify(await getServiceStatus(config)));
  } else console.log(JSON.stringify(await ensureService(config)));
} catch(error) {
  console.error(error instanceof Error ? error.message : 'Service operation failed');
  process.exitCode=1;
}
