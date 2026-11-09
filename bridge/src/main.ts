import { randomBytes, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readConfig, validateConfig, type RuntimeConfig } from './runtime/config.js';
import { ensureService, type ServiceInfo } from './runtime/service.js';
import { connectRpc, type RpcClient } from './protocol/rpc-client.js';
import { openStore, type Store } from './state/store.js';
import { createSync, type SyncService } from './state/sync.js';
import { createOperations, type Operations } from './state/operations.js';
import { createQueries, type Queries } from './api/queries.js';
import { createCommands, type Commands } from './api/commands.js';
import { createApiServer } from './api/server.js';
import { ApiError } from './api/validation.js';
import type { Envelope } from './api/contracts.js';

interface Dependencies {
  addresses(): string[];
  secure(path: string): Promise<void>;
  ensureService(config: RuntimeConfig): Promise<ServiceInfo>;
}
const defaults: Dependencies = {
  addresses: () => Object.values(networkInterfaces()).flatMap(entries => (entries ?? []).map(entry => entry.address)),
  secure: async path => {
    const script = fileURLToPath(new URL('../../scripts/windows/Protect-CodexRemotePath.ps1', import.meta.url));
    await promisify(execFile)('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script, '-Path', path], { windowsHide: true, timeout: 15000 });
  },
  ensureService,
};

async function persistent(file: string, generate: () => string, pattern: RegExp): Promise<string> {
  try { await writeFile(file, generate(), { flag: 'wx', mode: 0o600 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
  const value = (await readFile(file, 'utf8')).trim();
  if (!pattern.test(value)) throw new Error('Invalid saved bridge identity; existing files were preserved');
  return value;
}

export async function startBridge(config: RuntimeConfig, dependencies: Dependencies = defaults) {
  validateConfig(config);
  if (!dependencies.addresses().includes(config.bridgeHost)) throw new Error('Configured EasyTier address is not present on this Windows host');
  await mkdir(config.stateDir, { recursive: true });
  await dependencies.secure(config.stateDir);
  const service = await dependencies.ensureService(config);
  const codexToken = (await readFile(join(config.stateDir, 'codex-token'), 'utf8')).trim();
  const token = await persistent(join(config.stateDir, 'bridge-token'), () => randomBytes(32).toString('base64url'), /^[\w-]{43}$/);
  const serverId = await persistent(join(config.stateDir, 'bridge-id'), randomUUID, /^[0-9a-f-]{36}$/);
  let store: Store | undefined, sync: SyncService | undefined, operations: Operations | undefined, queries: Queries | undefined, commands: Commands | undefined;
  let rpc: RpcClient | undefined, available = false, closed = false, retries = 0;
  let timer: NodeJS.Timeout | undefined, connecting: Promise<void> | undefined;
  const controller = new AbortController(), listeners = new Set<(event: Envelope) => void>();
  const requireValue = <T>(value: T | undefined): T => { if (!value) throw new ApiError(503, 'upstream_unavailable', 'Codex is reconnecting'); return value; };
  // Real control probe passed on 0.167.0. Other request-generation paths stay
  // disabled until independently exercised against the native server.
  const features = { steer: true, queue: false, approvals: true, interrupt: true, childThreads: false, fileApprovals: true, permissions: false, questions: true, mcp: false };
  const api = createApiServer({ token, info: { apiVersion: 1, serverId, codexVersion: '0.167.0', features }, available: () => available,
    queries: {
      queryProjects: () => requireValue(queries).queryProjects(), queryModels: () => requireValue(queries).queryModels(),
      queryThreads: input => requireValue(queries).queryThreads(input), querySnapshot: id => requireValue(queries).querySnapshot(id), queryItems: (id, cursor) => requireValue(queries).queryItems(id, cursor),
    }, commands: { dispatch: command => requireValue(commands).dispatch(command) }, operations: { getOperation: id => requireValue(operations).getOperation(id) },
    sync: { replay: cursor => sync?.replay(cursor) ?? 'resync_required', onEvent: handler => { listeners.add(handler); return () => { listeners.delete(handler); }; } },
  });
  try {
    // Bind before opening SQLite: a concurrent losing worker cannot reset the
    // running worker's epoch or projection before EADDRINUSE rejects it.
    await new Promise<void>((resolveListen, reject) => {
      api.server.once('error', reject);
      api.server.listen(config.bridgePort, config.bridgeHost, () => { api.server.off('error', reject); resolveListen(); });
    });
    store = openStore(join(config.stateDir, 'bridge.sqlite'));
    store.setProjects(config.projects); operations = createOperations(store);
    connecting = establish(); await connecting;
  } catch (error) { closed = true; controller.abort(); await rpc?.close(); await api.close(); store?.close(); throw error; }

  async function establish(): Promise<void> {
    try {
      const client = await connectRpc(service.codexUrl, codexToken, { signal: controller.signal });
      if (closed) { await client.close(); return; }
      rpc = client;
      sync = createSync(requireValue(store), client);
      sync.onEvent(event => { for (const listener of listeners) listener(event); });
      queries = createQueries({ rpc: client, store: requireValue(store), sync, projects: config.projects });
      commands = createCommands({ rpc: client, store: requireValue(store), sync, operations: requireValue(operations), queries, projects: config.projects, features });
      client.onClose(() => {
        if (closed || rpc !== client) return;
        available = false; api.invalidate(); sync?.close(); sync = undefined; queries = undefined; commands = undefined;
        requireValue(store).resetEpoch(); schedule();
      });
      retries = 0; available = true;
    } catch { if (!closed) schedule(); }
  }
  function schedule() {
    if (closed || timer) return;
    const wait = Math.min(250 * 2 ** Math.min(retries++, 5), 5000);
    timer = setTimeout(() => { timer = undefined; connecting = establish(); }, wait);
  }
  async function close() {
    if (closed) return;
    closed = true; available = false; controller.abort(); if (timer) clearTimeout(timer);
    api.invalidate(); sync?.close(); await rpc?.close(); await connecting;
    await api.close(); store?.close(); listeners.clear();
    // The shared app-server owns tasks independently; never stop it here.
  }
  return { close };
}

if (process.argv[1] && resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  try {
    const at = process.argv.indexOf('--config');
    if (at < 0 || !process.argv[at + 1]) throw new Error('Required --config path');
    const config = await readConfig(resolve(process.argv[at + 1]!));
    const runtime = await startBridge(config);
    console.log(`Bridge ready at http://${config.bridgeHost}:${config.bridgePort}`);
    for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => { void runtime.close().catch(() => { process.exitCode = 1; }); });
  } catch { console.error('Bridge failed to start; check the configured network address, paths and ports.'); process.exitCode = 1; }
}
