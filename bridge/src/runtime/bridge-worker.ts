import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import type { RuntimeConfig } from './config.js';
import { spawnWorkerProcess } from './worker-process.js';

type Status = 'ready' | 'offline' | 'missing';
interface WorkerDependencies {
  probe(config: RuntimeConfig): Promise<Status>;
  spawn(configPath: string, config: RuntimeConfig): Promise<void>;
  wait(): Promise<void>;
}
const defaults: WorkerDependencies = {
  probe: async config => {
    let token: string, serverId: string;
    try {
      token = (await readFile(join(config.stateDir, 'bridge-token'), 'utf8')).trim();
      serverId = (await readFile(join(config.stateDir, 'bridge-id'), 'utf8')).trim();
    } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return 'missing'; throw error; }
    let response: Response;
    try {
      response = await fetch(`http://${config.bridgeHost}:${config.bridgePort}/v1/info`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(1500) });
    } catch { return 'missing'; }
    const body = await response.json() as { serverId?: string; apiVersion?: number; code?: string };
    if (response.status === 200 && body.serverId === serverId && body.apiVersion === 1) return 'ready';
    if (response.status === 503 && body.code === 'upstream_unavailable') return 'offline';
    throw new Error('Unrecognized listener at the configured bridge address; no process was stopped');
  },
  spawn: async (configPath, config) => {
    const main = fileURLToPath(new URL('../main.ts', import.meta.url));
    await spawnWorkerProcess(main,['--config',resolve(configPath)],join(config.stateDir,'bridge-worker.log'));
  },
  wait: async () => { await delay(250); },
};

export async function ensureBridgeWorker(config: RuntimeConfig, configPath: string, dependencies: WorkerDependencies = defaults) {
  const result = { bridgeUrl: `http://${config.bridgeHost}:${config.bridgePort}` };
  if (await dependencies.probe(config) !== 'missing') return result;
  await dependencies.spawn(configPath,config);
  for (let attempt = 0; attempt < 80; attempt++) {
    await dependencies.wait();
    if (await dependencies.probe(config) !== 'missing') return result;
  }
  throw new Error('Bridge did not become ready; check EasyTier, configured paths and ports');
}
