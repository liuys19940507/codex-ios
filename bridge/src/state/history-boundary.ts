import {ApiError} from '../api/validation.js';

const prefix='turns.v1:';
export function encodeTurnsBoundary(cursor:unknown):string|null {
  return typeof cursor==='string'&&cursor.length>0?prefix+Buffer.from(cursor).toString('base64url'):null;
}
export function decodeTurnsBoundary(value:string):string|null {
  if(!value.startsWith(prefix))return null;
  const encoded=value.slice(prefix.length),data=Buffer.from(encoded,'base64url');
  if(!encoded||data.toString('base64url')!==encoded)throw new ApiError(400,'invalid_cursor','Invalid turns history boundary');
  return data.toString('utf8');
}
