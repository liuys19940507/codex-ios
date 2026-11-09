import { isDeepStrictEqual } from 'node:util';
import type { Json, Pending } from './contracts.js';
import { ApiError } from './validation.js';
import { object } from '../state/reducer.js';

function invalid(message = 'Response does not match the pending request'): never { throw new ApiError(400, 'invalid_response', message); }
const unsupported = (): never => { throw new ApiError(409, 'capability_unavailable', 'Handle this request in the Windows CLI'); };
const record = (value: unknown): value is Record<string, any> => value !== null && typeof value === 'object' && !Array.isArray(value);
const only = (value: Record<string, unknown>, keys: string[]) => Object.keys(value).every(key => keys.includes(key));
const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(v => typeof v === 'string');
const subset = (values: unknown, requested: unknown) => values === null || Array.isArray(values) && Array.isArray(requested) && values.every(v => requested.some(r => isDeepStrictEqual(v, r)));

function permissionResponse(response: Record<string, any>, options: Record<string, any>) {
  if (!only(response, ['permissions', 'scope']) || response.scope !== 'turn' || !record(response.permissions)) invalid();
  const granted = response.permissions, requested = object(options.permissions);
  if (!only(granted, ['network', 'fileSystem'])) invalid();
  if (Object.hasOwn(granted, 'network')) {
    const network = granted.network;
    if (!record(network) || !only(network, ['enabled']) || ![true, false, null].includes(network.enabled)) invalid();
    if (network.enabled === true && object(requested.network).enabled !== true) invalid('Network access was not requested');
  }
  if (Object.hasOwn(granted, 'fileSystem')) {
    const fs = granted.fileSystem, original = object(requested.fileSystem);
    if (!record(fs) || !only(fs, ['read', 'write', 'entries', 'globScanMaxDepth']) || !Object.hasOwn(fs, 'read') || !Object.hasOwn(fs, 'write')) invalid();
    if (!subset(fs.read, original.read) || !subset(fs.write, original.write)) invalid('File access exceeds the request');
    if ('entries' in fs && (!Array.isArray(fs.entries) || !subset(fs.entries, original.entries))) invalid();
    if ('globScanMaxDepth' in fs && fs.globScanMaxDepth !== original.globScanMaxDepth) invalid();
  }
}

function questionResponse(response: Record<string, any>, options: Record<string, any>) {
  if (!only(response, ['answers']) || !record(response.answers) || !Array.isArray(options.questions) || !options.questions.length) invalid();
  const questions = options.questions;
  if (new Set(questions.map((q: any) => q.id)).size !== questions.length || Object.keys(response.answers).length !== questions.length) invalid();
  for (const question of questions) {
    if (typeof question.id !== 'string' || !Object.hasOwn(response.answers, question.id)) invalid();
    const answer = response.answers[question.id];
    if (!record(answer) || !only(answer, ['answers']) || !strings(answer.answers) || !answer.answers.length || answer.answers.some((s: string) => !s.trim())) invalid();
    if (Array.isArray(question.options) && !question.isOther && !answer.answers.every((s: string) => question.options.some((o: any) => o.label === s))) invalid('Choose an offered answer');
  }
}

const common = ['type', 'title', 'description', 'default'];
function enumValues(schema: Record<string, any>): string[] | undefined {
  if (strings(schema.enum)) return schema.enum;
  const alternatives = schema.oneOf ?? schema.anyOf;
  if (Array.isArray(alternatives) && alternatives.every(v => record(v) && typeof v.const === 'string' && only(v, ['const', 'title']))) return alternatives.map(v => v.const);
  return undefined;
}
function supportedField(field: unknown): boolean {
  if (!record(field)) return false;
  if (field.type === 'boolean') return only(field, common);
  if (field.type === 'number' || field.type === 'integer') return only(field, [...common, 'minimum', 'maximum']) && [field.minimum, field.maximum].every(v => v === undefined || typeof v === 'number' && Number.isFinite(v));
  if (field.type === 'string') {
    if (!only(field, [...common, 'enum', 'enumNames', 'oneOf', 'minLength', 'maxLength', 'format'])) return false;
    if (('enum' in field || 'oneOf' in field) && !enumValues(field)?.length) return false;
    return [field.minLength, field.maxLength].every(v => v === undefined || Number.isSafeInteger(v) && v >= 0) && (field.format === undefined || ['email', 'uri', 'date', 'date-time'].includes(field.format));
  }
  if (field.type === 'array') return only(field, [...common, 'items', 'minItems', 'maxItems']) && record(field.items) && only(field.items, ['type', 'enum', 'anyOf']) && !!enumValues(field.items)?.length && [field.minItems, field.maxItems].every(v => v === undefined || Number.isSafeInteger(v) && v >= 0);
  return false;
}
function validateField(field: Record<string, any>, value: unknown): boolean {
  if (field.type === 'boolean') return typeof value === 'boolean';
  if (field.type === 'integer' || field.type === 'number') return typeof value === 'number' && Number.isFinite(value) && (field.type !== 'integer' || Number.isSafeInteger(value)) && (field.minimum === undefined || value >= field.minimum) && (field.maximum === undefined || value <= field.maximum);
  if (field.type === 'array') return strings(value) && new Set(value).size === value.length && (field.minItems === undefined || value.length >= field.minItems) && (field.maxItems === undefined || value.length <= field.maxItems) && value.every(v => enumValues(field.items)!.includes(v));
  if (typeof value !== 'string') return false;
  const length = [...value].length;
  if (field.minLength !== undefined && length < field.minLength || field.maxLength !== undefined && length > field.maxLength || enumValues(field) && !enumValues(field)!.includes(value)) return false;
  if (field.format === 'email') return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  if (field.format === 'uri') { try { return !!new URL(value).protocol; } catch { return false; } }
  if (field.format === 'date') return /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value));
  if (field.format === 'date-time') return /^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$/.test(value) && !Number.isNaN(Date.parse(value));
  return true;
}

export function supportsMcpForm(options: unknown): boolean {
  const o = object(options), schema = o.requestedSchema;
  return o.mode === 'form' && record(schema) && schema.type === 'object' && only(schema, ['$schema', 'type', 'properties', 'required']) && record(schema.properties) && Object.values(schema.properties).every(supportedField) && (schema.required === undefined || strings(schema.required) && schema.required.every(k => Object.hasOwn(schema.properties, k)));
}

export function validatePendingResponse(pending: Pending, raw: Json, features: Record<string, boolean>): Json {
  const feature = { command: 'approvals', file: 'fileApprovals', permission: 'permissions', question: 'questions', mcp: 'mcp' }[pending.kind];
  if (!features[feature]) unsupported();
  if (!record(raw)) invalid();
  const value = object(raw);
  const options = object(pending.options);
  if (options.readOnly === true) unsupported();
  if (pending.kind === 'command') {
    if (!only(value, ['decision']) || !Array.isArray(options.availableDecisions) || !options.availableDecisions.some((d: unknown) => isDeepStrictEqual(d, value.decision))) invalid('Choose a decision offered by this request');
  } else if (pending.kind === 'file') {
    // 0.167.0 has no per-file decisions field. Use its versioned response enum,
    // narrowed to single-use decisions; do not offer session grants.
    if (!only(value, ['decision']) || !['accept', 'decline', 'cancel'].includes(value.decision)) invalid();
  } else if (pending.kind === 'question') questionResponse(value, options);
  else if (pending.kind === 'permission') permissionResponse(value, options);
  else {
    if (!supportsMcpForm(options)) unsupported();
    if (!only(value, ['action', 'content', '_meta']) || value._meta !== null || !['accept', 'decline', 'cancel'].includes(value.action)) invalid();
    if (value.action !== 'accept') { if (value.content !== null) invalid(); }
    else {
      const schema = options.requestedSchema, content = value.content;
      if (!record(content) || !Object.keys(content).every(k => Object.hasOwn(schema.properties, k)) || !(schema.required ?? []).every((k: string) => Object.hasOwn(content, k))) invalid();
      for (const [key, field] of Object.entries(schema.properties)) if (Object.hasOwn(content, key) && !validateField(field as Record<string, any>, content[key])) invalid(`Invalid form field: ${key}`);
    }
  }
  return raw;
}
