/**
 * NEVER COMPILED. NEVER RUN ON A DEVICE.
 * Hermes event params forwarded by the bridge. Harmony metadata correlates
 * phone-dispatched turns and server→client approval/clarification requests.
 */
export interface HermesParams {
  type?: string;
  session_id?: string;
  payload?: Record<string, Object>;
  seq?: number;
  harmony_request_id?: string;
}

export function eventType(p: HermesParams): string {
  return `${p.type ?? ''}`;
}

export function seqOf(p: HermesParams): number {
  return typeof p.seq === 'number' ? p.seq : 0;
}

export function payloadText(p: HermesParams): string {
  const payload = p.payload;
  if (!payload) {
    return '';
  }
  const text = payload['text'];
  return typeof text === 'string' ? text : '';
}

export function isDelta(p: HermesParams): boolean {
  const t = eventType(p);
  return t === 'message.delta' || t === 'reasoning.delta' || t === 'thinking.delta';
}

export function isApproval(p: HermesParams): boolean {
  return eventType(p) === 'approval.request';
}

export function isClarify(p: HermesParams): boolean {
  return eventType(p) === 'clarify.request';
}

export function isToolStart(p: HermesParams): boolean {
  return eventType(p) === 'tool.start';
}

export function isToolComplete(p: HermesParams): boolean {
  return eventType(p) === 'tool.complete';
}

export function isTodo(p: HermesParams): boolean {
  return eventType(p) === 'todo.updated';
}

export function isSubagent(p: HermesParams): boolean {
  return eventType(p).startsWith('subagent.');
}

export function isStatus(p: HermesParams): boolean {
  return eventType(p) === 'status.update';
}

export function isComplete(p: HermesParams): boolean {
  return eventType(p) === 'message.complete';
}

export function isStart(p: HermesParams): boolean {
  return eventType(p) === 'message.start';
}
