import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import WebSocket, { WebSocketServer } from 'ws';
import type { Command, Cursor, Envelope, Json, Operation } from './contracts.js';
import { ApiError, validateCommand } from './validation.js';
import type { Queries } from './queries.js';

export interface ApiContext {
  token: string;
  info: { apiVersion: number; serverId: string; codexVersion: string; features: Record<string, boolean> };
  available(): boolean;
  queries: Pick<Queries, 'queryProjects' | 'queryModels' | 'queryThreads' | 'querySnapshot' | 'queryItems'>;
  commands: { dispatch(command: Command): Promise<Operation> };
  operations: { getOperation(id: string): Operation | null };
  sync: { replay(cursor: Cursor): Envelope[] | 'resync_required'; onEvent(handler: (event: Envelope) => void): () => void };
  log?(message: string): void;
}

interface EventPeer { readyState: number; bufferedAmount: number; send(data: string): unknown; close(code: number): unknown }
export function sendEventFrame(peer: EventPeer, value: unknown): boolean {
  if (peer.readyState !== WebSocket.OPEN) return false;
  const frame = JSON.stringify(value);
  if (peer.bufferedAmount > 1048576 || Buffer.byteLength(frame, 'utf8') > 1048576) {
    peer.send(JSON.stringify({ type: 'resync_required' })); peer.close(1013); return false;
  }
  peer.send(frame); return true;
}

export function createApiServer(context: ApiContext) {
  if (!context.token) throw new Error('Bridge authentication token is required');
  const token = Buffer.from(`Bearer ${context.token}`);
  const authenticated = (request: IncomingMessage) => {
    const supplied = Buffer.from(request.headers.authorization ?? '');
    return supplied.length === token.length && timingSafeEqual(supplied, token);
  };
  function reply(response: ServerResponse, status: number, data: unknown) {
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    response.end(JSON.stringify(data));
  }
  function parse(request: IncomingMessage) {
    if (!request.url?.startsWith('/v1/')) throw new ApiError(404, 'not_found', 'Unknown endpoint');
    return new URL(request.url, 'http://bridge.local');
  }
  function parameters(url: URL, allowed: string[]) {
    const result: Record<string, string> = {};
    for (const [key, value] of url.searchParams) {
      if (!allowed.includes(key) || Object.hasOwn(result, key)) throw new ApiError(400, 'invalid_request', 'Invalid query parameters');
      result[key] = value;
    }
    return result;
  }
  async function body(request: IncomingMessage): Promise<unknown> {
    if (Number(request.headers['content-length'] ?? 0) > 1048576) { request.resume(); throw new ApiError(413, 'body_too_large', 'Request exceeds 1 MiB'); }
    if (request.headers['content-type']?.split(';')[0]?.trim() !== 'application/json') throw new ApiError(400, 'invalid_json', 'Send application/json');
    const data = await new Promise<Buffer>((resolve, reject) => {
      const chunks: Buffer[] = []; let size = 0;
      const fail = (error: Error) => { cleanup(); request.resume(); reject(error); };
      const receive = (chunk: Buffer) => {
        size += chunk.length;
        if (size > 1048576) fail(new ApiError(413, 'body_too_large', 'Request exceeds 1 MiB'));
        else chunks.push(chunk);
      };
      const end = () => { cleanup(); resolve(Buffer.concat(chunks)); };
      const abort = () => fail(new ApiError(400, 'invalid_json', 'Request was interrupted'));
      const cleanup = () => { request.off('data', receive); request.off('end', end); request.off('error', fail); request.off('aborted', abort); };
      request.on('data', receive); request.once('end', end); request.once('error', fail); request.once('aborted', abort);
    });
    try { return JSON.parse(data.toString('utf8')); }
    catch { throw new ApiError(400, 'invalid_json', 'Request must contain valid JSON'); }
  }
  const server = createServer((request, response) => {
    void route(request, response).catch(error => {
      if (response.destroyed || response.headersSent) return;
      const apiError = error instanceof ApiError ? error : new ApiError(503, 'upstream_unavailable', 'Codex is temporarily unavailable');
      context.log?.(`HTTP request failed: ${apiError.code}`);
      reply(response, apiError.status, { code: apiError.code, message: apiError.message });
    });
  });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  async function route(request: IncomingMessage, response: ServerResponse) {
    if (!authenticated(request)) { request.resume(); reply(response, 401, { code: 'unauthorized', message: 'A valid bearer token is required' }); return; }
    const url = parse(request), method = request.method, path = url.pathname;
    const operation = /^\/v1\/operations\/([^/]+)$/.exec(path);
    if (method === 'GET' && operation) {
      parameters(url, []);
      const receipt = context.operations.getOperation(decodeURIComponent(operation[1]!));
      if (!receipt) throw new ApiError(404, 'not_found', 'Operation was not found');
      reply(response, 200, receipt); return;
    }
    if (!context.available()) throw new ApiError(503, 'upstream_unavailable', 'Codex is temporarily unavailable');
    let result: unknown;
    if (method === 'GET' && path === '/v1/info') { parameters(url, []); result = context.info; }
    else if (method === 'GET' && path === '/v1/projects') { parameters(url, []); result = context.queries.queryProjects(); }
    else if (method === 'GET' && path === '/v1/models') { parameters(url, []); result = await context.queries.queryModels(); }
    else if (method === 'GET' && path === '/v1/threads') result = await context.queries.queryThreads(parameters(url, ['projectId', 'query', 'cursor']));
    else if (method === 'POST' && path === '/v1/commands') { parameters(url, []); result = await context.commands.dispatch(validateCommand(await body(request))); }
    else {
      const thread = /^\/v1\/threads\/([^/]+)\/(snapshot|items)$/.exec(path);
      if (method !== 'GET' || !thread) throw new ApiError(404, 'not_found', 'Unknown endpoint');
      const id = decodeURIComponent(thread[1]!);
      if (thread[2] === 'snapshot') { parameters(url, []); result = await context.queries.querySnapshot(id); }
      else result = await context.queries.queryItems(id, parameters(url, ['cursor']).cursor);
    }
    reply(response, 200, result);
  }

  const sockets = new WebSocketServer({ noServer: true, maxPayload: 4096, perMessageDeflate: false });
  const unsubscribers = new Map<WebSocket, () => void>();
  const resync = (socket: WebSocket) => { if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'resync_required' })); socket.close(1013); };
  server.on('upgrade', (request, socket, head) => {
    socket.on('error', () => {});
    const reject = (status: number, message: string) => { socket.end(`HTTP/1.1 ${status} ${message}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); };
    if (!authenticated(request)) { reject(401, 'Unauthorized'); return; }
    if (!context.available()) { reject(503, 'Unavailable'); return; }
    let cursor: Cursor | undefined;
    try {
      const url = parse(request);
      if (url.pathname !== '/v1/events') { reject(404, 'Not Found'); return; }
      const p = parameters(url, ['epoch', 'after']);
      if (p.epoch && p.after && /^\d+$/.test(p.after) && Number.isSafeInteger(Number(p.after))) cursor = { epoch: p.epoch, seq: Number(p.after) };
    } catch { reject(400, 'Bad Request'); return; }
    sockets.handleUpgrade(request, socket, head, peer => {
      peer.on('error', () => {});
      peer.on('message', () => peer.close(1008));
      peer.once('close', () => { unsubscribers.get(peer)?.(); unsubscribers.delete(peer); });
      // Subscription and replay run synchronously: no live event can slip
      // between the cursor read and registering the stream handler.
      const unsubscribe = context.sync.onEvent(event => { if (!sendEventFrame(peer, event)) { unsubscribe(); unsubscribers.delete(peer); } });
      unsubscribers.set(peer, unsubscribe);
      const replay = cursor ? context.sync.replay(cursor) : 'resync_required';
      if (replay === 'resync_required') { unsubscribe(); unsubscribers.delete(peer); resync(peer); return; }
      for (const event of replay) if (!sendEventFrame(peer, event)) { unsubscribe(); unsubscribers.delete(peer); break; }
    });
  });
  function invalidate() { for (const [socket, unsubscribe] of unsubscribers) { unsubscribe(); resync(socket); } unsubscribers.clear(); }
  async function close() {
    invalidate();
    for (const peer of sockets.clients) peer.terminate();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await new Promise<void>(resolve => sockets.close(() => resolve()));
  }
  return { server, close, invalidate };
}
