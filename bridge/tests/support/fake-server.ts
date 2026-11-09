import { once } from 'node:events';
import { WebSocketServer, WebSocket } from 'ws';
import type { AddressInfo } from 'node:net';

export type Message = { id?: string | number; method?: string; params?: unknown; result?: unknown; error?: unknown };

export async function fakeServer(handler: (socket: WebSocket, message: Message) => void) {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  await once(server, 'listening');
  const headers: string[] = [];
  server.on('connection', (socket, request) => {
    headers.push(request.headers.authorization ?? '');
    socket.on('message', data => handler(socket, JSON.parse(data.toString()) as Message));
  });
  return {
    url: `ws://127.0.0.1:${(server.address() as AddressInfo).port}`,
    headers,
    async close() {
      for (const socket of server.clients) socket.terminate();
      await new Promise<void>(resolve => server.close(() => resolve()));
    },
  };
}

export function handshake(socket: WebSocket, message: Message): boolean {
  if (message.method !== 'initialize') return false;
  socket.send(JSON.stringify({ id: message.id, result: { userAgent: 'test' } }));
  return true;
}
