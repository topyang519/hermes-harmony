/**
 * Conversation store. Hermes events are ingested as chat, not as a protocol dump.
 */
import { HermesParams, seqOf } from '../model/HermesEvent';

export interface ResumeSnapshot {
  messages?: Object[];
  pending_approval?: Record<string, Object>;
  pending_clarify?: Record<string, Object>;
  inflight?: Object;
  running?: boolean;
  session_id?: string;
}

function asText(value: Object | undefined): string {
  return typeof value === 'string' ? value : '';
}

function isVisibleAssistantPayload(payload: Record<string, Object>): boolean {
  const role = asText(payload['role']).trim().toLowerCase();
  if (role.length > 0 && role !== 'assistant') {
    return false;
  }
  const displayKind = asText(payload['display_kind']).trim().toLowerCase();
  if (displayKind === 'hidden' || displayKind === 'tool' || displayKind === 'internal') {
    return false;
  }
  return true;
}

export function isVoiceNote(text: string): boolean {
  const t = text.trim();
  if (t.indexOf('[The user sent a voice message') >= 0) {
    return true;
  }
  if (t.indexOf('[The user sent an audio file attachment') >= 0) {
    return true;
  }
  if (t.indexOf('harmony-voice-') >= 0 && t.indexOf('@file:') >= 0) {
    return true;
  }
  return false;
}

export function isGenericTitle(title: string): boolean {
  if (title.length === 0) {
    return true;
  }
  if (title === '对话' || title === '新对话' || title === 'Harmony' || title === 'HarmonyOS') {
    return true;
  }
  if (title.indexOf(' ') >= 0 || title.indexOf('/') >= 0) {
    return false;
  }
  return title.length >= 16;
}

@ObservedV2
export class SessionTimeline {
  @Trace sessionId: string = '';
  @Trace events: HermesParams[] = [];
  @Trace lastSeen: number = 0;
  @Trace assistantText: string = '';
  @Trace reasoningText: string = '';
  @Trace statusText: string = '';
  @Trace todos: Object[] = [];
  @Trace pendingApproval: Record<string, Object> | null = null;
  @Trace pendingClarify: Record<string, Object> | null = null;
  @Trace title: string = '';
  @Trace preview: string = '';
  @Trace streaming: boolean = false;
  @Trace fromPhone: boolean = false;
  @Trace archived: boolean = false;
  /** Show in sidebar: just created this visit, or already has chat content. */
  @Trace listed: boolean = false;
  @Trace resumeRevision: number = 0;
  /** Advances for every new Hermes event, including hidden tool/reasoning progress. */
  @Trace activityRevision: number = 0;
  private localSeq: number = -1;

  constructor(sessionId: string) {
    this.sessionId = sessionId;
  }

  displayTitle(): string {
    if (!isGenericTitle(this.title)) {
      return this.title;
    }
    const first = this.firstUserText();
    if (first.length > 0) {
      return first.length > 24 ? first.slice(0, 24) : first;
    }
    if (this.preview.length > 0 && !isGenericTitle(this.preview)) {
      return this.preview.length > 24 ? this.preview.slice(0, 24) : this.preview;
    }
    return '新对话';
  }

  displayPreview(): string {
    if (this.streaming && this.assistantText.length > 0) {
      return this.assistantText.slice(0, 80);
    }
    if (this.preview.length > 0) {
      return this.preview;
    }
    return '暂无消息';
  }

  hasContent(): boolean {
    return this.events.length > 0 || this.preview.length > 0 || this.streaming;
  }

  appendLocalUser(text: string): void {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return;
    }
    const last = this.events.length > 0 ? this.events[this.events.length - 1] : null;
    if (last && `${last.type ?? ''}` === 'local.user') {
      const payload = last.payload ?? {};
      if (asText(payload['text']) === trimmed) {
        return;
      }
    }
    this.pushUser('local.user', trimmed, 0);
  }

  appendLocalVoice(seconds: number): void {
    const dur = seconds > 0 ? seconds : 1;
    this.pushUser('local.voice', '', dur);
    this.preview = '[语音]';
  }

  attachTranscriptToLastVoice(text: string): void {
    const trimmed = text.trim();
    if (trimmed.length === 0 || this.events.length === 0) {
      return;
    }
    const last = this.events[this.events.length - 1];
    if (`${last.type ?? ''}` !== 'local.voice') {
      return;
    }
    const payload = last.payload ?? {};
    const next: HermesParams = {
      type: 'local.voice',
      session_id: this.sessionId,
      payload: {
        'text': trimmed,
        'seconds': payload['seconds'] ?? 1
      } as Record<string, Object>,
      seq: last.seq
    };
    const copy = this.events.slice();
    copy[copy.length - 1] = next;
    this.events = copy;
    this.adoptTitle(trimmed);
  }

  private pushUser(kind: string, text: string, seconds: number): void {
    const next = this.events.slice();
    const payload: Record<string, Object> = {};
    if (text.length > 0) {
      payload['text'] = text;
    }
    if (seconds > 0) {
      payload['seconds'] = seconds;
    }
    const row: HermesParams = {
      type: kind,
      session_id: this.sessionId,
      payload: payload,
      seq: this.localSeq
    };
    this.localSeq -= 1;
    next.push(row);
    this.events = next;
    if (text.length > 0) {
      this.preview = text.slice(0, 80);
      this.adoptTitle(text);
    }
    this.assistantText = '';
    this.streaming = false;
    this.listed = true;
  }

  ingest(params: HermesParams): boolean {
    const seq = seqOf(params);
    if (seq > 0 && seq <= this.lastSeen) {
      return false;
    }
    if (seq > 0) {
      this.lastSeen = seq;
    }
    this.activityRevision += 1;
    const t = `${params.type ?? ''}`;
    const payload = params.payload ?? {};

    if (t === 'message.start') {
      this.assistantText = '';
      this.streaming = true;
      this.statusText = '正在回复';
      this.listed = true;
      return true;
    }
    if (t === 'message.delta') {
      const piece = payload['text'];
      if (typeof piece === 'string') {
        this.assistantText += piece;
      }
      this.streaming = true;
      this.listed = true;
      return true;
    }
    if (t === 'reasoning.delta' || t === 'thinking.delta' || t === 'thinking.start' ||
      t === 'thinking.complete' || t === 'reasoning.complete') {
      const piece = payload['text'];
      if (typeof piece === 'string') {
        this.reasoningText += piece;
      }
      return false;
    }
    if (t === 'session.title' || t === 'session.info') {
      const title = asText(payload['title']) || asText(payload['text']);
      this.adoptTitle(title);
      return false;
    }
    if (t === 'status.update') {
      const text = payload['text'];
      this.statusText = typeof text === 'string' ? text : this.statusText;
      return false;
    }
    if (t === 'todo.updated') {
      const todos = payload['todos'];
      if (Array.isArray(todos)) {
        this.todos = todos as Object[];
      }
      return false;
    }
    if (t === 'approval.request') {
      this.pendingApproval = payload;
      this.streaming = false;
      return false;
    }
    if (t === 'clarify.request') {
      this.pendingClarify = payload;
      this.streaming = false;
      return false;
    }
    if (t === 'request.cancel') {
      const requestId = asText(payload['id']);
      if (requestId.length > 0 && this.pendingApproval &&
        asText(this.pendingApproval['harmony_server_request_id']) === requestId) {
        this.pendingApproval = null;
      }
      if (requestId.length > 0 && this.pendingClarify &&
        asText(this.pendingClarify['harmony_server_request_id']) === requestId) {
        this.pendingClarify = null;
      }
      return false;
    }
    if (t === 'message.complete') {
      if (!isVisibleAssistantPayload(payload)) {
        return false;
      }
      let text = asText(payload['text']);
      if (text.length === 0) {
        text = asText(payload['content']);
      }
      if (text.length === 0) {
        text = this.assistantText;
      }
      if (text.length === 0) {
        this.streaming = false;
        this.statusText = '';
        return false;
      }
      const last = this.events.length > 0 ? this.events[this.events.length - 1] : null;
      if (last && `${last.type ?? ''}` === 'message.complete') {
        const prev = last.payload ?? {};
        if (asText(prev['text']) === text) {
          this.streaming = false;
          this.statusText = '';
          return false;
        }
      }
      const row: HermesParams = {
        type: 'message.complete',
        session_id: this.sessionId,
        payload: { 'text': text } as Record<string, Object>,
        seq: seq
      };
      const next = this.events.slice();
      next.push(row);
      this.events = next;
      this.assistantText = text;
      this.streaming = false;
      this.statusText = '';
      this.preview = text.slice(0, 80);
      this.listed = true;
      return true;
    }
    // Protocol internals (tools, subagents, session.*): keep out of the chat.
    return false;
  }

  replaceFromResume(resume: ResumeSnapshot, latestSeq: number): void {
    this.events = [];
    this.assistantText = '';
    this.reasoningText = '';
    this.statusText = '';
    this.preview = '';
    this.streaming = resume.running === true;
    this.statusText = this.streaming ? '正在回复' : '';
    this.resumeRevision += 1;
    this.pendingApproval = null;
    this.pendingClarify = null;
    this.lastSeen = latestSeq;
    const messages = resume.messages ?? [];
    for (let i = 0; i < messages.length; i++) {
      const m = messages[i] as Record<string, Object>;
      const role = `${m['role'] ?? ''}`;
      const content = asText(m['content']) || asText(m['text']);
      if (content.length === 0) {
        continue;
      }
      if (role === 'user' || role === 'human') {
        const kind = `${m['display_kind'] ?? ''}`;
        if (kind === 'hidden' && !isVoiceNote(content)) {
          continue;
        }
        if (isVoiceNote(content)) {
          this.appendLocalVoice(1);
        } else {
          this.appendLocalUser(content);
        }
      } else if (role === 'assistant') {
        const row: HermesParams = {
          type: 'message.complete',
          session_id: this.sessionId,
          payload: { 'text': content } as Record<string, Object>,
          seq: 0
        };
        const copy = this.events.slice();
        copy.push(row);
        this.events = copy;
        this.assistantText = content;
        this.preview = content.slice(0, 80);
        this.listed = true;
      }
      // Tool/system/developer records are protocol internals, not chat replies.
    }
    if (resume.pending_approval) {
      this.pendingApproval = resume.pending_approval;
    }
    if (resume.pending_clarify) {
      this.pendingClarify = resume.pending_clarify;
    }
  }

  resetCursor(): void {
    this.lastSeen = 0;
  }

  private firstUserText(): string {
    for (let i = 0; i < this.events.length; i++) {
      const ev = this.events[i];
      const kind = `${ev.type ?? ''}`;
      const payload = ev.payload ?? {};
      if (kind === 'local.voice') {
        const text = asText(payload['text']);
        if (text.length > 0 && !isVoiceNote(text)) {
          return text;
        }
        return '[语音]';
      }
      if (kind === 'local.user') {
        const text = asText(payload['text']);
        if (text.length > 0 && !isVoiceNote(text)) {
          return text;
        }
      }
    }
    return '';
  }

  private adoptTitle(candidate: string): void {
    const trimmed = candidate.trim();
    if (trimmed.length === 0 || (!isGenericTitle(this.title) && this.title.length > 0)) {
      return;
    }
    if (isGenericTitle(trimmed)) {
      return;
    }
    this.title = trimmed.length > 24 ? trimmed.slice(0, 24) : trimmed;
  }
}

@ObservedV2
export class EventStore {
  @Trace sessions: SessionTimeline[] = [];
  @Trace epoch: string = '';
  private aliases: Map<string, string> = new Map();

  resolveId(sessionId: string): string {
    if (!sessionId) {
      return sessionId;
    }
    return this.aliases.get(sessionId) ?? sessionId;
  }

  rememberAlias(alternate: string, live: string): void {
    if (!alternate || !live) {
      return;
    }
    this.aliases.set(alternate, live);
    this.aliases.set(live, live);
  }

  find(sessionId: string): SessionTimeline | null {
    const resolved = this.resolveId(sessionId);
    const found = this.sessions.find((s: SessionTimeline) => s.sessionId === resolved);
    return found !== undefined ? found : null;
  }

  timeline(sessionId: string): SessionTimeline {
    const resolved = this.resolveId(sessionId);
    let found = this.sessions.find((s: SessionTimeline) => s.sessionId === resolved);
    if (!found) {
      found = new SessionTimeline(resolved);
      const next = this.sessions.slice();
      next.unshift(found);
      this.sessions = next;
    }
    return found;
  }

  visibleSessions(syncAll: boolean, archived: boolean = false): SessionTimeline[] {
    return this.sessions.filter((s: SessionTimeline) => {
      if (s.archived !== archived) {
        return false;
      }
      if (!syncAll && !s.fromPhone) {
        return false;
      }
      return s.listed || s.hasContent();
    });
  }

  pruneForeign(syncAll: boolean): void {
    if (syncAll) {
      return;
    }
    this.sessions = this.sessions.filter((s: SessionTimeline) => s.fromPhone);
  }

  removeSession(sessionId: string): void {
    const resolved = this.resolveId(sessionId);
    this.sessions = this.sessions.filter((s: SessionTimeline) => s.sessionId !== resolved);
    const aliasesToDelete: string[] = [];
    this.aliases.forEach((live: string, alias: string) => {
      if (alias === sessionId || alias === resolved || live === resolved) {
        aliasesToDelete.push(alias);
      }
    });
    for (let i = 0; i < aliasesToDelete.length; i++) {
      this.aliases.delete(aliasesToDelete[i]);
    }
  }

  markPhoneOwned(sessionId: string, listed: boolean = true): SessionTimeline {
    const tl = this.timeline(sessionId);
    tl.fromPhone = true;
    if (listed) {
      tl.listed = true;
    }
    const rest = this.sessions.filter((s: SessionTimeline) => s.sessionId !== tl.sessionId);
    this.sessions = [tl].concat(rest);
    return tl;
  }

  applyEpoch(epoch: string): void {
    if (epoch && this.epoch && epoch !== this.epoch) {
      for (const s of this.sessions) {
        s.resetCursor();
      }
    }
    if (epoch) {
      this.epoch = epoch;
    }
  }

  lastSeenMap(): Map<string, number> {
    const out = new Map<string, number>();
    for (const s of this.sessions) {
      out.set(s.sessionId, s.lastSeen);
    }
    return out;
  }
}
