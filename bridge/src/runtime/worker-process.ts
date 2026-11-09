import { spawn } from 'node:child_process';
import { openSync, closeSync } from 'node:fs';

export async function spawnWorkerProcess(script: string, args: string[], logPath: string): Promise<number> {
  const loader = new URL('../../node_modules/tsx/dist/loader.mjs', import.meta.url).href;
  const log = openSync(logPath, 'a', 0o600);
  try {
    // Import the pinned loader in this Node process. The tsx CLI creates an
    // extra child with its own signal relay and process lifetime.
    const child = spawn(process.execPath, ['--import', loader, script, ...args], { windowsHide: true, detached: true, stdio: ['ignore', log, log] });
    await new Promise<void>((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    child.unref();return child.pid!;
  } finally { closeSync(log); }
}
