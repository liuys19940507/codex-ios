import WebSocket from 'ws';
import { setTimeout as delay } from 'node:timers/promises';
import type { Json } from '../api/contracts.js';

const READ_METHODS = new Set([
  'thread/list', 'thread/read', 'thread/turns/list', 'thread/items/list',
  'thread/loaded/list', 'model/list',
]);
type Waiter = { resolve: (value: Json) => void; reject: (error: Error) => void; timer: NodeJS.Timeout; apply?: (value:Json)=>void };
export interface RpcClient {
  request(method: string, params: Json): Promise<Json>;
  requestAtBarrier(method:string,params:Json,apply:(value:Json)=>void):Promise<Json>;
  respond(id: string | number, result: Json): void;
  onEvent(handler: (message: Json) => void): () => void;
  close(): Promise<void>;
}

export class RpcError extends Error {
  constructor(public readonly code: number, message: string) {
    super(message);
    this.name = 'RpcError';
  }
}
export class RpcTransportError extends Error {
  readonly unknownOutcome = true;
  constructor(message: string) { super(message); this.name = 'RpcTransportError'; }
}

class WebSocketRpcClient implements RpcClient {
  private nextId = 1;
  private readonly pending = new Map<number, Waiter>();
  private readonly handlers = new Set<(message: Json) => void>();
  private backlog: Json[] = [];
  private failed = false;

  constructor(private readonly socket: WebSocket) {
    socket.on('message', (data, binary) => {
      if (this.failed) return;
      if (binary) { this.fail('Unexpected binary RPC message'); return; }
      try {
        const message: unknown = JSON.parse(data.toString());
        if (message === null || typeof message !== 'object' || Array.isArray(message)) {
          this.fail('Invalid RPC message'); return;
        }
        const record = message as Record<string, unknown>;
        // Server-initiated requests also have ids: classify by method first.
        if (typeof record.method === 'string') {
          if (!this.handlers.size) {
            if (this.backlog.length >= 1000) { this.fail('RPC event backlog exceeded'); return; }
            this.backlog.push(message as Json);
          } else {
            for (const handler of this.handlers) handler(message as Json);
          }
          return;
        }
        if (typeof record.id !== 'number') return;
        const waiter = this.pending.get(record.id);
        if (!waiter) return;
        clearTimeout(waiter.timer);
        this.pending.delete(record.id);
        if (record.error && typeof record.error === 'object') {
          const error = record.error as Record<string, unknown>;
          waiter.reject(new RpcError(
            typeof error.code === 'number' ? error.code : -32603,
            typeof error.message === 'string' ? error.message : 'RPC request failed',
          ));
        } else if ('result' in record) {
          try {
            waiter.apply?.(record.result as Json);
            waiter.resolve(record.result as Json);
          } catch(error) {
            waiter.reject(error instanceof Error ? error : new Error('RPC snapshot application failed'));
            this.fail('RPC snapshot application failed');
          }
        } else {
          waiter.reject(new RpcTransportError('RPC response has no result'));
        }
      } catch {
        this.fail('Invalid RPC message or event consumer failure');
      }
    });
    socket.on('close', () => this.fail('RPC connection closed'));
    socket.on('error', () => this.fail('RPC connection failed'));
  }

  async initialize(): Promise<void> {
    await this.sendRequest('initialize', {
      clientInfo: { name: 'codex_ios_remote', title: 'Codex iOS Remote', version: '0.1.0' },
      capabilities: { experimentalApi: true },
    });
    this.send({ method: 'initialized' });
  }

  async request(method: string, params: Json): Promise<Json> {
    const attempts = READ_METHODS.has(method) ? 3 : 1;
    for (let attempt = 0; ; attempt++) {
      try { return await this.sendRequest(method, params); }
      catch (error) {
        if (!(error instanceof RpcError) || error.code !== -32001 || attempt + 1 >= attempts)
          throw error;
        await delay(50 * 2 ** attempt + Math.floor(Math.random() * 20));
      }
    }
  }

  respond(id: string | number, result: Json): void { this.send({ id, result }); }

  requestAtBarrier(method:string,params:Json,apply:(value:Json)=>void):Promise<Json> {
    return this.sendRequest(method,params,apply);
  }

  onEvent(handler: (message: Json) => void): () => void {
    this.handlers.add(handler);
    const queued = this.backlog;
    this.backlog = [];
    for (const message of queued) handler(message);
    return () => { this.handlers.delete(handler); };
  }

  async close(): Promise<void> {
    this.fail('RPC connection closed');
    if (this.socket.readyState === WebSocket.CLOSED) return;
    await new Promise<void>(resolve => {
      const timer = setTimeout(() => { this.socket.terminate(); resolve(); }, 200);
      this.socket.once('close', () => { clearTimeout(timer); resolve(); });
      this.socket.close();
    });
  }

  private sendRequest(method: string, params: Json, apply?: (value:Json)=>void): Promise<Json> {
    return new Promise((resolve, reject) => {
      if (this.failed || this.socket.readyState !== WebSocket.OPEN) {
        reject(new RpcTransportError('RPC connection is unavailable')); return;
      }
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new RpcTransportError('RPC response timed out; outcome requires reconciliation'));
      }, 30_000);
      this.pending.set(id, { resolve, reject, timer, apply });
      try { this.send({ id, method, params }); }
      catch {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new RpcTransportError('RPC send failed; outcome requires reconciliation'));
      }
    });
  }

  private send(message: Json): void {
    if (this.failed || this.socket.readyState !== WebSocket.OPEN)
      throw new RpcTransportError('RPC connection is unavailable');
    this.socket.send(JSON.stringify(message));
  }

  private fail(message: string): void {
    if (this.failed) return;
    this.failed = true;
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(new RpcTransportError(message));
    }
    this.pending.clear();
    this.backlog = [];
    if (this.socket.readyState !== WebSocket.CLOSED) this.socket.close();
  }
}

export async function connectRpc(url: string, token: string, options:{signal?:AbortSignal}={}): Promise<RpcClient> {
  if(options.signal?.aborted)throw new RpcTransportError('RPC connection aborted');
  const endpoint = new URL(url);
  if (!['ws:', 'wss:'].includes(endpoint.protocol) || endpoint.username || endpoint.password)
    throw new Error('RPC endpoint must be a WebSocket URL without user credentials');
  const socket = new WebSocket(endpoint, {
    headers: { Authorization: 'Bearer ' + token }, handshakeTimeout: 10_000,
  });
  const client = new WebSocketRpcClient(socket);
  const abort=()=>{void client.close();};
  options.signal?.addEventListener('abort',abort,{once:true});
  socket.once('close',()=>options.signal?.removeEventListener('abort',abort));
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once('open', () => resolve());
      socket.once('error', () => reject(new RpcTransportError('RPC connection failed')));
      socket.once('close', () => reject(new RpcTransportError('RPC connection closed before ready')));
    });
    await client.initialize();
    return client;
  } catch (error) { await client.close(); throw error; }
}
