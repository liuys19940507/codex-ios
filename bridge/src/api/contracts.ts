export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type Cursor = { epoch: string; seq: number };
export type Item = { id: string; turnId: string; kind: string; text: string; data: Json };
export type Pending = {
  id: string; threadId: string; turnId: string;
  kind: 'command' | 'file' | 'permission' | 'question' | 'mcp';
  prompt: string; options: Json; state: 'pending' | 'resolved' | 'unknown';
};
export type ThreadSummary = {
  id: string; projectId: string; title: string; status: string;
  activeTurnId: string | null; parentId: string | null;
};
export type Snapshot = {
  cursor: Cursor; thread: ThreadSummary; items: Item[]; itemsCursor: string | null;
  pending: Pending[]; policy: { approvalPolicy: string | null; sandbox: string | null };
};
export type Envelope = { cursor: Cursor; threadId: string; type: string; data: Json };
export type Operation = {
  id: string; state: 'pending' | 'accepted' | 'failed' | 'unknown';
  result: Json; message: string | null;
};
export type Command = {
  id: string;
  method: 'task/create' | 'task/input' | 'task/interrupt' | 'request/respond' | 'thread/rename' | 'thread/archive';
  params: { [key: string]: Json };
};
