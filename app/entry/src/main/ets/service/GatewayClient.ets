/**
 * WS client: reconnect backoff, epoch invalidation, cursor sub.
 *
 * Keep an active turn connected with a visible HarmonyOS continuous-task
 * notification. Retain idle sockets across background transitions and validate
 * them on resume; replace only sockets that fail the readiness probe.
 * AppStorage mirrors state for pages that don't observe @Trace.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { EventStore, ResumeSnapshot, SessionTimeline, isGenericTitle } from './EventStore';
import { SecretBag, Secrets, DEFAULT_GATEWAY_URL } from './Secrets';
import { AppPrefs } from './AppPrefs';
import { BackgroundConnectionTask } from './BackgroundConnectionTask';
import { TaskReplyNotifications } from './TaskReplyNotifications';
import { HermesParams, eventType } from '../model/HermesEvent';

function localPortValid(port: string): boolean {
  if (!port) { return true; }
  if (!/^[0-9]{1,5}$/.test(port)) { return false; }
  const number = Number(port);
  return number > 0 && number <= 65535;
}

function localIpv4Octets(host: string): number[] | null {
  const parts = host.split('.');
  if (parts.length !== 4) { return null; }
  const octets: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (!/^(?:0|[1-9][0-9]{0,2})$/.test(parts[i])) { return null; }
    const value = Number(parts[i]);
    if (value > 255) { return null; }
    octets.push(value);
  }
  return octets;
}

function validLocalIpv6(host: string): boolean {
  if (!host || host.indexOf(':::') >= 0 || !/^[0-9a-fA-F:]+$/.test(host) || host.indexOf(':') < 0) { return false; }
  const compressedAt = host.indexOf('::');
  if (compressedAt >= 0 && host.indexOf('::', compressedAt + 2) >= 0) { return false; }
  const pieces = host.split(':');
  let units = 0;
  for (let i = 0; i < pieces.length; i++) {
    if (pieces[i].length === 0) { continue; }
    if (pieces[i].length > 4 || !/^[0-9a-fA-F]{1,4}$/.test(pieces[i])) { return false; }
    units++;
  }
  return compressedAt >= 0 ? units < 8 : units === 8;
}

function isLocalAuthority(authority: string): boolean {
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']');
    if (close < 0) { return false; }
    const host = authority.slice(1, close).toLowerCase();
    const suffix = authority.slice(close + 1);
    const port = suffix.length === 0 ? '' : (suffix.startsWith(':') ? suffix.slice(1) : 'invalid');
    if ((suffix.length > 0 && !port) || !localPortValid(port) || !validLocalIpv6(host)) { return false; }
    return host === '::1' || host.startsWith('fc') || host.startsWith('fd') ||
      host.startsWith('fe8') || host.startsWith('fe9') || host.startsWith('fea') || host.startsWith('feb');
  }

  const colon = authority.lastIndexOf(':');
  const host = (colon < 0 ? authority : authority.slice(0, colon)).toLowerCase();
  const port = colon < 0 ? '' : authority.slice(colon + 1);
  if ((colon >= 0 && (authority.indexOf(':') !== colon || !port)) || !localPortValid(port)) { return false; }
  if (/^(?:localhost|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:localhost|local))$/.test(host)) {
    return true;
  }
  const octets = localIpv4Octets(host);
  if (!octets) { return false; }
  return octets[0] === 10 || octets[0] === 127 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168) ||
    (octets[0] === 169 && octets[1] === 254);
}

// Keep endpoint validation local so lightweight GatewayClient test doubles need
// not mirror utility exports from the credential store.
function isSupportedGatewayEndpoint(url: string): boolean {
  const match = /^(wss?):\/\/([^\s/?#@]+)\/(?:v2\/app|relay\/phone\/[a-f0-9]{32})$/.exec(url);
  if (!match) { return false; }
  return match[1] === 'wss' || isLocalAuthority(match[2]);
}

export interface VoiceCapabilities {
  ready?: boolean;
  stt?: boolean;
  tts?: boolean;
  ffmpeg?: boolean;
  reason?: string;
}

export interface WireMsg {
  voice?: VoiceCapabilities;
  voice_reply?: boolean;
  t?: string;
  epoch?: string;
  hermes?: boolean;
  p?: HermesParams;
  session?: string;
  truncated?: boolean;
  latest_seq?: number;
  resume?: ResumeSnapshot;
  list?: Object[];
  archived_list?: Object[];
  created?: string;
  stored?: string;
  action?: string;
  archived?: boolean;
  ok?: boolean;
  body?: string;
  msg?: string;
  code?: string;
  request_id?: string;
  harmony_server_request_id?: string;
  task_request_id?: string;
  requested?: string;
  features?: string[];
  harmony_request_id?: string;
  status?: string;
  interrupted?: boolean;
  sr?: number;
  fmt?: string;
  bytes?: number;
  aborted?: boolean;
}

export interface WireOut extends WireMsg {
  app?: string;
  proto?: number;
  dev?: string;
  last_seen?: number;
  choice?: string;
  answer?: string;
  title?: string;
  text?: string;
  agent_session?: boolean;
}

export interface AgentCommandResult {
  text: string;
}

export interface AgentActionNotice {
  kind: 'approval' | 'clarification';
  text: string;
}

interface PendingAgentSession {
  taskId: string;
  requestId: string;
  resolve: (sessionId: string) => void;
  reject: (reason: Error) => void;
  timer: number;
}

interface PendingPhoneSession {
  draftId: string;
  requestId: string;
  title: string;
  creating: boolean;
  error: string;
  timer: number;
}

interface PendingAgentReply {
  taskId: string;
  requestId: string;
  sessionId: string;
  userText: string;
  onAction: ((notice: AgentActionNotice) => void) | undefined;
  seenActionIds: Set<string>;
  resolve: (result: AgentCommandResult) => void;
  reject: (reason: Error) => void;
  timer: number;
}

interface PendingAgentInterrupt {
  taskId: string;
  requestId: string;
  taskRequestId: string;
  resolve: (confirmed: boolean) => void;
  timer: number;
}

interface PendingSessionAction {
  requestId: string;
  action: 'archive' | 'restore' | 'delete';
  sessionId: string;
  timer: number;
}

interface PendingVoiceCheck {
  requestId: string;
  resolve: (result: string) => void;
  timer: number;
}

interface AgentDispatchInfo {
  requestId: string;
  sessionId: string;
}

@ObservedV2
export class GatewayClient {
  static readonly instance: GatewayClient = new GatewayClient();

  store: EventStore = new EventStore();
  @Trace connected: boolean = false;
  @Trace hermes: boolean = false;
  @Trace lastError: string = '';
  @Trace transcript: string = '';
  @Trace sessionsList: Object[] = [];
  @Trace sessionActionNotice: string = '';
  @Trace uiRev: number = 0;
  onPcm: ((chunk: ArrayBuffer) => void) | null = null;
  onTtsStart: ((sr: number) => void) | null = null;
  onTtsEnd: ((aborted: boolean, bytes: number) => void) | null = null;

  private ws: webSocket.WebSocket | null = null;
  private context: common.Context | null = null;
  private uiAbilityContext: common.Context | null = null;
  private closingOnPurpose: boolean = false;
  private reconnectAttempt: number = 0;
  private deviceId: string = 'harmony-phone';
  private pcmBytes: number = 0;
  private bridgeReady: boolean = false;
  private voiceProtocol: boolean = false;
  private voiceConfigured: boolean = false;
  private voiceCheckAt: number = 0;
  private voiceTimer: number = -1;
  private agentProtocolReady: boolean = false;
  private connecting: boolean = false;
  private generation: number = 0;
  private reconnectTimer: number = -1;
  private handshakeTimer: number = -1;
  private livenessTimer: number = -1;
  private resumeProbeTimer: number = -1;
  private foregroundRecoveryTimer: number = -1;
  private foregroundRecovery: boolean = false;
  private resumeAfterBackground: boolean = false;
  private lastMessageAt: number = 0;
  private prefsReady: Promise<void> | null = null;
  private acceptingPcm: boolean = false;
  private activeSessionId: string = '';
  private awaitingReply: boolean = false;
  private replayOpen: number = 0;
  private uiForeground: boolean = false;
  private agentLeases: number = 0;
  private agentQueue: Promise<void> = Promise.resolve();
  private agentRequestSequence: number = 0;
  private sessionActionSequence: number = 0;
  private voiceCheckSequence: number = 0;
  private pendingSessionAction: PendingSessionAction | null = null;
  private pendingVoiceCheck: PendingVoiceCheck | null = null;
  private pendingAgentSession: PendingAgentSession | null = null;
  private pendingPhoneSession: PendingPhoneSession | null = null;
  private phoneSessionSequence: number = 0;
  private agentReplyWaiters: Map<string, PendingAgentReply> = new Map<string, PendingAgentReply>();
  private agentInterruptWaiters: Map<string, PendingAgentInterrupt> = new Map<string, PendingAgentInterrupt>();
  private agentSessionByContext: Map<string, string> = new Map<string, string>();
  private agentSessionByTask: Map<string, string> = new Map<string, string>();
  private agentDispatchByTask: Map<string, AgentDispatchInfo> = new Map<string, AgentDispatchInfo>();
  private cancelledAgentTasks: Set<string> = new Set<string>();

  attachContext(ctx: common.Context): void {
    this.context = ctx;
    this.setStorage('hermes_connected', false);
    this.setStorage('hermes_hermes', false);
    this.setStorage('hermes_error', '');
    this.setStorage('hermes_recovering', false);
    this.setStorage('hermes_rev', 0);
    this.setStorage('hermes_session_count', 0);
    this.setStorage('hermes_pending_session', '');
    this.setStorage('hermes_speaking', false);
    this.setStorage('hermes_recording', false);
    this.resetVoice();
    this.prefsReady = AppPrefs.load(ctx).then(() => {
      this.store.pruneForeign(AppPrefs.syncAllSessions);
      const agentContextIds = Object.keys(AppPrefs.agentSessions);
      for (let i = 0; i < agentContextIds.length; i++) {
        if (!this.agentSessionByContext.has(agentContextIds[i])) {
          this.agentSessionByContext.set(agentContextIds[i], AppPrefs.agentSessions[agentContextIds[i]]);
        }
      }
      // Remember owned ids for filtering, but do not dump empty stubs into the sidebar.
      for (let i = 0; i < AppPrefs.phoneSessionIds.length; i++) {
        this.store.markPhoneOwned(AppPrefs.phoneSessionIds[i], false);
      }
      this.publishUi();
      if (this.isReady()) {
        this.listSessions();
      }
    });
    this.publishUi();
  }

  attachUIAbilityContext(ctx: common.Context): void {
    this.uiAbilityContext = ctx;
    this.attachContext(ctx);
  }

  async claimInitialSetupReminder(): Promise<boolean> {
    if (this.prefsReady) {
      await this.prefsReady;
    }
    if (!this.context) {
      return false;
    }
    return AppPrefs.claimInitialSetupReminder(this.context);
  }

  isVoiceReady(): boolean {
    return this.isReady() && this.voiceConfigured && Date.now() - this.voiceCheckAt < 90000;
  }

  refreshVoice(): void {
    if (this.isReady() && this.voiceProtocol) { this.send({ t: 'voice_check' }); }
  }

  async checkVoiceConfiguration(): Promise<string> {
    if (!this.connected || !this.bridgeReady || this.ws === null) { return 'disconnected'; }
    if (!this.hermes) { return 'hermes_unavailable'; }
    if (!this.voiceProtocol) { return 'unsupported'; }
    if (this.pendingVoiceCheck) { return 'checking'; }
    const requestId = `voice-check-${Date.now()}-${++this.voiceCheckSequence}`;
    return new Promise<string>((resolve: (result: string) => void): void => {
      const timer = setTimeout((): void => {
        this.finishVoiceCheck(requestId, 'timeout');
      }, 15000);
      this.pendingVoiceCheck = { requestId: requestId, resolve: resolve, timer: timer };
      this.sendNow({ t: 'voice_check', request_id: requestId });
    });
  }

  private finishVoiceCheck(requestId: string, result: string): void {
    const pending = this.pendingVoiceCheck;
    if (!pending || pending.requestId !== requestId) { return; }
    clearTimeout(pending.timer);
    this.pendingVoiceCheck = null;
    pending.resolve(result);
  }

  private resetVoice(): void {
    if (this.pendingVoiceCheck) { this.finishVoiceCheck(this.pendingVoiceCheck.requestId, 'disconnected'); }
    if (this.voiceTimer !== -1) { clearTimeout(this.voiceTimer); }
    this.voiceTimer = -1;
    this.voiceConfigured = false;
    this.voiceCheckAt = 0;
    this.setStorage('hermes_voice_ready', false);
    this.setStorage('hermes_voice_checked', false);
    this.setStorage('hermes_voice_stt', false);
    this.setStorage('hermes_voice_tts', false);
    this.setStorage('hermes_voice_ffmpeg', false);
    this.setStorage('hermes_voice_reason', '连接电脑后，自动检查语音配置。');
    this.setStorage('hermes_voice_mode', false);
    this.setStorage('hermes_auto_voice', false);
  }

  private applyVoiceCapabilities(voice: VoiceCapabilities | undefined): void {
    if (!this.voiceProtocol || !this.isReady()) { return; }
    this.voiceConfigured = voice?.ready === true && voice.stt === true && voice.tts === true && voice.ffmpeg === true;
    this.voiceCheckAt = Date.now();
    this.setStorage('hermes_voice_ready', this.voiceConfigured);
    this.setStorage('hermes_voice_checked', true);
    this.setStorage('hermes_voice_stt', voice?.stt === true);
    this.setStorage('hermes_voice_tts', voice?.tts === true);
    this.setStorage('hermes_voice_ffmpeg', voice?.ffmpeg === true);
    this.setStorage('hermes_voice_reason', voice?.reason ?? '电脑语音配置未就绪。');
    AppPrefs.publish();
    this.send({ t: 'voice_preferences', voice_reply: this.voiceConfigured && AppPrefs.autoVoiceReply });
    if (!this.voiceConfigured) { this.stopIncomingAudio(); }
    if (this.voiceTimer !== -1) { clearTimeout(this.voiceTimer); }
    this.voiceTimer = setTimeout(() => {
      // Renew before expiry without interrupting a healthy recording.
      this.voiceTimer = setTimeout(() => {
        this.resetVoice();
        this.refreshVoice();
      }, 30000);
      this.refreshVoice();
    }, 60000);
    this.publishUi();
  }

  setActiveSession(sessionId: string): void {
    this.activeSessionId = this.store.resolveId(sessionId);
  }

  visibleSessions(archived: boolean = false): SessionTimeline[] {
    return this.store.visibleSessions(AppPrefs.syncAllSessions, archived);
  }

  async setSyncAllSessions(enabled: boolean): Promise<void> {
    AppPrefs.syncAllSessions = enabled;
    if (this.context) {
      await AppPrefs.save(this.context);
    } else {
      AppPrefs.publish();
    }
    if (!enabled) {
      this.store.pruneForeign(false);
    } else {
      this.listSessions();
    }
    this.publishUi();
  }

  async setSidebarCollapsed(collapsed: boolean): Promise<void> {
    AppPrefs.sidebarCollapsed = collapsed;
    if (this.context) {
      await AppPrefs.save(this.context);
    } else {
      AppPrefs.publish();
    }
  }

  async setVoiceInputMode(voice: boolean): Promise<void> {
    if (voice && !this.isVoiceReady()) { this.refreshVoice(); return; }
    AppPrefs.voiceInputMode = voice;
    if (this.context) {
      await AppPrefs.save(this.context);
    } else {
      AppPrefs.publish();
    }
  }

  async setAutoVoiceReply(enabled: boolean): Promise<void> {
    if (enabled && !this.isVoiceReady()) { this.refreshVoice(); return; }
    AppPrefs.autoVoiceReply = enabled;
    if (this.isReady()) { this.send({ t: 'voice_preferences', voice_reply: enabled }); }
    if (!enabled) {
      this.stopIncomingAudio();
    }
    if (this.context) {
      await AppPrefs.save(this.context);
    } else {
      AppPrefs.publish();
    }
  }

  /** Mirror connection state for @StorageLink pages (Index does not observe @Trace alone). */
  publishUi(): void {
    this.uiRev = this.uiRev + 1;
    this.setStorage('hermes_connected', this.connected);
    this.setStorage('hermes_hermes', this.hermes);
    this.setStorage('hermes_error', this.lastError);
    this.setStorage('hermes_recovering', this.foregroundRecovery);
    this.setStorage('hermes_rev', this.uiRev);
    this.setStorage('hermes_session_count', this.visibleSessions().length);
    this.setStorage('hermes_session_action_notice', this.sessionActionNotice);
  }

  private setStorage<T>(key: string, value: T): void {
    try {
      AppStorage.setOrCreate<T>(key, value);
    } catch (_e) {
      // The agent extension may run without an initialized ArkUI storage host.
    }
  }

  async onForeground(): Promise<void> {
    const returning = this.resumeAfterBackground;
    this.resumeAfterBackground = false;
    this.uiForeground = true;
    this.reconnectAttempt = 0;
    this.clearReconnect();
    this.clearLiveness();
    // Stopping a continuous background task can be delayed by HarmonyOS. The
    // background-task manager must never gate restoring the foreground socket.
    void BackgroundConnectionTask.stop(this.uiAbilityContext);
    if (this.closingOnPurpose) { return; }
    if (returning) { this.beginForegroundRecovery(); }
    if (this.ws !== null && this.bridgeReady) {
      this.probeResumedConnection();
      return;
    }
    // An unfinished handshake from before suspension may never complete.
    if (this.connecting) { this.invalidateConnectionForResume(); }
    await this.connect();
  }

  private beginForegroundRecovery(): void {
    this.finishForegroundRecovery();
    this.foregroundRecovery = true;
    this.foregroundRecoveryTimer = setTimeout(() => {
      this.foregroundRecoveryTimer = -1;
      this.foregroundRecovery = false;
      this.publishUi();
    }, 4000);
    this.publishUi();
  }

  private finishForegroundRecovery(): void {
    if (this.foregroundRecoveryTimer !== -1) { clearTimeout(this.foregroundRecoveryTimer); }
    this.foregroundRecoveryTimer = -1;
    this.foregroundRecovery = false;
  }

  private clearResumeProbe(): void {
    if (this.resumeProbeTimer !== -1) { clearTimeout(this.resumeProbeTimer); }
    this.resumeProbeTimer = -1;
  }

  private probeResumedConnection(): void {
    const socket = this.ws;
    const generation = this.generation;
    const voiceReply = this.isVoiceReady() && AppPrefs.autoVoiceReply;
    this.clearResumeProbe();
    this.resumeProbeTimer = setTimeout(() => {
      this.resumeProbeTimer = -1;
      if (this.ws !== socket || this.generation !== generation || !this.uiForeground) { return; }
      this.invalidateConnectionForResume();
      void this.connect();
    }, 1500);
    // Existing bridges accept hello again on the same authenticated socket and
    // reply immediately with ready. No prompt or user decision is replayed.
    this.sendHello(voiceReply);
    this.publishUi();
  }

  private sendHello(voiceReply: boolean): void {
    const hello: WireOut = {
      t: 'hello', app: '0.6.8', proto: 2, dev: this.deviceId, voice_reply: voiceReply
    };
    this.sendNow(hello);
  }

  private invalidateConnectionForResume(): void {
    this.failPhoneSession('连接已中断，请重试创建对话');
    this.generation += 1;
    this.connecting = false;
    this.bridgeReady = false;
    this.connected = false;
    this.hermes = false;
    this.resetVoice();
    this.agentProtocolReady = false;
    this.replayOpen = 0;
    this.clearHandshake();
    this.clearReconnect();
    this.clearLiveness();
    this.stopIncomingAudio();
    this.closeSocketOnly();
    this.publishUi();
  }

  onBackground(): void {
    this.uiForeground = false;
    this.resumeAfterBackground = true;
    this.clearResumeProbe();
    this.finishForegroundRecovery();
    this.reconcileBackgroundTask();
    this.publishUi();
  }

  private hasPendingTurn(): boolean {
    return this.awaitingReply || this.agentLeases > 0;
  }

  private reconcileBackgroundTask(): void {
    if (this.uiForeground) {
      void BackgroundConnectionTask.stop(this.uiAbilityContext);
    } else if (this.hasPendingTurn()) {
      void BackgroundConnectionTask.start(this.uiAbilityContext);
      if (this.bridgeReady) { this.startLiveness(); }
    } else {
      // Leave a healthy idle socket intact for a quick foreground return. The
      // OS may suspend it; the resume probe detects that without a forced close.
      this.clearLiveness();
      this.clearReconnect();
      void BackgroundConnectionTask.stop(this.uiAbilityContext);
    }
  }

  isReady(): boolean {
    return this.connected && this.bridgeReady && this.hermes && this.ws !== null &&
      this.resumeProbeTimer === -1;
  }

  async connect(): Promise<void> {
    if (this.connecting || this.bridgeReady) {
      return;
    }
    this.clearReconnect();
    this.closingOnPurpose = false;
    this.connecting = true;
    this.agentProtocolReady = false;
    const generation = ++this.generation;
    let creds: SecretBag;
    try {
      if (this.prefsReady) {
        await this.prefsReady;
      }
      creds = await Secrets.load();
    } catch (_err) {
      if (generation !== this.generation) { return; }
      this.connecting = false;
      this.lastError = '无法读取连接设置，请重新保存设置';
      this.publishUi();
      return;
    }
    if (generation !== this.generation || this.closingOnPurpose) { return; }
    const url = (creds.gatewayUrl || DEFAULT_GATEWAY_URL).trim();
    if (!isSupportedGatewayEndpoint(url)) {
      this.connecting = false;
      this.lastError = '请在设置中填写有效的 WebSocket 网关地址';
      this.publishUi();
      return;
    }
    if (!creds.password || creds.password.trim().length === 0) {
      this.connecting = false;
      this.lastError = '请先填写连接密码';
      this.publishUi();
      return;
    }
    this.closeSocketOnly();
    this.bridgeReady = false;
    this.resetVoice();
    this.agentProtocolReady = false;
    this.connected = false;
    this.hermes = false;
    this.lastError = '';
    let socket: webSocket.WebSocket;
    try {
      socket = webSocket.createWebSocket();
    } catch (err) {
      this.connectionFailed(`无法建立连接${this.errorCodeSuffix(err as Object)}，请检查网络和网关地址`);
      return;
    }
    this.ws = socket;
    this.publishUi();
    const sep = url.indexOf('?') >= 0 ? '&' : '?';
    const connectUrl = `${url}${sep}password=${encodeURIComponent(creds.password.trim())}`;
    const isLan = url.indexOf('ws://') === 0;
    const options: webSocket.WebSocketRequestOptions = {};
    if (isLan) {
      options.header = { 'X-Hermes-App-Password': creds.password.trim() };
    }
    socket.on('open', (_err: Object, _value: Object) => {
      if (this.ws !== socket || generation !== this.generation) { return; }
      this.sendHello(false);
    });
    socket.on('message', (_err: Object, value: string | ArrayBuffer) => {
      if (this.ws !== socket || generation !== this.generation) { return; }
      if (typeof value !== 'string') {
        if (this.acceptingPcm && this.isVoiceReady() && AppPrefs.autoVoiceReply && this.uiForeground) {
          this.pcmBytes += value.byteLength;
          if (this.onPcm) { this.onPcm(value); }
        }
        return;
      }
      this.onText(value);
    });
    socket.on('close', (_err: Object, _value: Object) => {
      if (this.ws !== socket || generation !== this.generation) { return; }
      this.connectionFailed('连接已断开，正在重新连接');
    });
    socket.on('error', (err: Object) => {
      if (this.ws !== socket || generation !== this.generation) { return; }
      this.connectionFailed(`连接失败${this.errorCodeSuffix(err)}，请检查网络和连接设置`);
    });
    this.handshakeTimer = setTimeout(() => {
      this.handshakeTimer = -1;
      if (this.ws === socket && generation === this.generation && !this.bridgeReady) {
        this.connectionFailed('连接超时，请检查网络和网关状态');
      }
    }, 15000);
    const connectCb = (err: Object, ok: boolean): void => {
      if (this.ws !== socket || generation !== this.generation) { return; }
      if (err || !ok) {
        this.connectionFailed(`连接被拒绝${err ? this.errorCodeSuffix(err) : ''}，请检查连接密码`);
      }
    };
    try {
      if (isLan) { socket.connect(connectUrl, options, connectCb); }
      else { socket.connect(connectUrl, connectCb); }
    } catch (err) {
      this.connectionFailed(`无法建立连接${this.errorCodeSuffix(err as Object)}，请检查网关地址`);
    }
  }

  /** Keep platform diagnostics useful without logging URLs, passwords, or raw errors. */
  private errorCodeSuffix(error: Object): string {
    const code = (error as BusinessError).code;
    return typeof code === 'number' ? `（系统错误码 ${code}）` : '';
  }

  private connectionFailed(message: string): void {
    this.failPhoneSession('连接已中断，请重试创建对话');
    if (this.pendingSessionAction) {
      this.finishSessionAction('连接中断，电脑端未确认操作结果，请重新连接后检查会话状态');
    }
    this.clearHandshake();
    this.clearLiveness();
    this.closeSocketOnly();
    this.connecting = false;
    this.connected = false;
    this.hermes = false;
    this.bridgeReady = false;
    this.resetVoice();
    this.replayOpen = 0;
    this.stopIncomingAudio();
    this.lastError = message;
    this.publishUi();
    this.scheduleReconnect();
  }

  private stopIncomingAudio(): void {
    this.acceptingPcm = false;
    this.setStorage('hermes_speaking', false);
    if (this.onTtsEnd) { this.onTtsEnd(true, this.pcmBytes); }
  }

  private clearHandshake(): void {
    if (this.handshakeTimer !== -1) { clearTimeout(this.handshakeTimer); }
    this.handshakeTimer = -1;
  }

  private clearReconnect(): void {
    if (this.reconnectTimer !== -1) { clearTimeout(this.reconnectTimer); }
    this.reconnectTimer = -1;
  }

  private clearLiveness(): void {
    if (this.livenessTimer !== -1) { clearInterval(this.livenessTimer); }
    this.livenessTimer = -1;
  }

  private startLiveness(): void {
    this.clearLiveness();
    if (!this.uiForeground && !this.hasPendingTurn()) { return; }
    this.lastMessageAt = Date.now();
    this.livenessTimer = setInterval(() => {
      if (this.bridgeReady && Date.now() - this.lastMessageAt > 55000) {
        this.connectionFailed('连接超时，正在自动恢复');
      }
    }, 10000);
  }

  /** User-initiated disconnect (settings). */
  disconnect(): void {
    this.failPhoneSession('连接已断开，连接电脑后可重新创建对话');
    this.rejectAgentOperations('连接已由用户断开');
    this.closingOnPurpose = true;
    this.bridgeReady = false;
    this.resetVoice();
    this.agentProtocolReady = false;
    this.generation += 1;
    this.connecting = false;
    this.clearReconnect();
    this.clearHandshake();
    this.clearLiveness();
    this.finishForegroundRecovery();
    void BackgroundConnectionTask.stop(this.uiAbilityContext);
    this.stopIncomingAudio();
    this.closeSocketOnly();
    this.connected = false;
    this.hermes = false;
    this.publishUi();
  }

  private closeSocketOnly(): void {
    this.clearResumeProbe();
    if (this.ws) {
      const closeOpts: webSocket.WebSocketCloseOptions = { code: 1000, reason: 'client' };
      const socket = this.ws;
      this.ws = null;
      try { socket.close(closeOpts, (_err: Object, _ok: boolean) => {}); } catch (_err) {}
    }
  }

  close(): void {
    this.disconnect();
  }

  private sendNow(obj: WireOut): void {
    if (obj.session && this.isDraftSession(obj.session)) { return; }
    const socket = this.ws;
    if (!socket) { return; }
    try {
      socket.send(JSON.stringify(obj), (err: Object, ok: boolean) => {
        if (this.ws !== socket) { return; }
        if (err || !ok) {
          this.connectionFailed('发送未确认，请连接恢复后检查对话再重试');
        }
      });
    } catch (_err) {
      this.connectionFailed('发送失败，请连接恢复后检查对话再重试');
    }
  }

  send(obj: WireOut): void {
    const kind = obj.t ?? '';
    if (kind === 'hello' || kind === 'pong') {
      this.sendNow(obj);
      return;
    }
    if ((kind === 'asr_start' || kind === 'asr_end' || kind === 'tts') && !this.isVoiceReady()) {
      this.refreshVoice(); return;
    }
    if (!this.isReady()) {
      this.lastError = '尚未就绪，请连接成功后重试';
      this.publishUi();
      if (!this.connecting && !this.bridgeReady) { this.scheduleReconnect(); }
      return;
    }
    // Never queue user actions: reconnecting must not replay a prompt or approval.
    this.sendNow(obj);
  }

  sendBin(buf: ArrayBuffer): void {
    const socket = this.ws;
    if (!this.isVoiceReady() || !socket) { return; }
    try {
      socket.send(buf, (err: Object, ok: boolean) => {
        if (this.ws === socket && (err || !ok)) {
          this.connectionFailed('语音传输中断，请重新录音');
        }
      });
    } catch (_err) { this.connectionFailed('语音传输中断，请重新录音'); }
  }

  sub(sessionId: string, lastSeen: number): void {
    if (!this.isSessionReady(sessionId)) { return; }
    this.replayOpen += 1;
    const msg: WireOut = { t: 'sub', session: this.store.resolveId(sessionId), last_seen: lastSeen };
    this.send(msg);
  }

  subAll(): void {
    const cursors = this.store.lastSeenMap();
    cursors.forEach((lastSeen: number, sid: string) => {
      this.sub(sid, lastSeen);
    });
  }

  dispatch(sessionId: string, text: string): void {
    if (this.isDraftSession(sessionId)) { return; }
    if (!this.isReady()) {
      this.lastError = '尚未就绪，请连接成功后重新发送';
      this.publishUi();
      return;
    }
    const sid = this.store.resolveId(sessionId);
    this.setActiveSession(sid);
    this.store.timeline(sid).appendLocalUser(text);
    this.awaitingReply = true;
    if (this.context) {
      void TaskReplyNotifications.requestPermission(this.context);
    }
    this.publishUi();
    const msg: WireOut = { t: 'dispatch', session: sid, text: text, request_id: this.nextAgentRequestId() };
    this.send(msg);
  }

  interrupt(sessionId: string): void {
    const msg: WireOut = { t: 'interrupt', session: this.store.resolveId(sessionId) };
    this.send(msg);
  }

  approve(sessionId: string, requestId: string, choice: string, serverRequestId: string = ''): void {
    const msg: WireOut = {
      t: 'approve',
      session: this.store.resolveId(sessionId),
      request_id: requestId,
      harmony_server_request_id: serverRequestId,
      choice: choice
    };
    this.send(msg);
  }

  clarify(sessionId: string, requestId: string, answer: string, serverRequestId: string = ''): void {
    const msg: WireOut = {
      t: 'clarify',
      session: this.store.resolveId(sessionId),
      request_id: requestId,
      harmony_server_request_id: serverRequestId,
      answer: answer
    };
    this.send(msg);
  }

  /** Return a local screen identity immediately; adopt the server identity in place. */
  newSession(title: string): string {
    if (this.pendingPhoneSession) { return this.pendingPhoneSession.draftId; }
    if (!this.isReady()) { return ''; }
    this.phoneSessionSequence += 1;
    const draftId = `harmony-draft-${Date.now()}-${this.phoneSessionSequence}`;
    const pending: PendingPhoneSession = {
      draftId: draftId, requestId: '', title: title,
      creating: false, error: '', timer: -1
    };
    this.pendingPhoneSession = pending;
    const timeline = this.store.markPhoneOwned(draftId, true);
    timeline.title = title;
    this.beginPhoneSession(pending);
    return draftId;
  }

  isDraftSession(sessionId: string): boolean {
    return sessionId.startsWith('harmony-draft-') && this.store.resolveId(sessionId) === sessionId;
  }

  isSessionReady(sessionId: string): boolean {
    return this.isReady() && !this.isDraftSession(sessionId);
  }

  isCreatingSession(sessionId: string): boolean {
    return this.pendingPhoneSession?.draftId === sessionId && this.pendingPhoneSession.creating;
  }

  sessionCreationMessage(sessionId: string): string {
    const pending = this.pendingPhoneSession;
    if (!pending || pending.draftId !== sessionId) { return ''; }
    return pending.creating ? '正在准备对话，可以先输入内容…' : pending.error;
  }

  retryNewSession(sessionId: string): void {
    const pending = this.pendingPhoneSession;
    if (!pending || pending.draftId !== sessionId || pending.creating) { return; }
    if (!this.isReady()) {
      pending.error = '连接电脑后可重新创建对话';
      this.publishUi();
      return;
    }
    this.beginPhoneSession(pending);
  }

  private beginPhoneSession(pending: PendingPhoneSession): void {
    this.phoneSessionSequence += 1;
    pending.requestId = `harmony-ui-session-${Date.now()}-${this.phoneSessionSequence}`;
    pending.creating = true;
    pending.error = '';
    this.store.timeline(pending.draftId).preview = '正在准备对话…';
    const requestId = pending.requestId;
    pending.timer = setTimeout(() => {
      if (this.pendingPhoneSession?.requestId !== requestId) { return; }
      this.failPhoneSession('电脑暂未确认新对话，请重试');
      this.publishUi();
    }, 20000);
    this.publishUi();
    this.send({ t: 'new_session', title: pending.title, request_id: requestId });
  }

  private failPhoneSession(message: string): void {
    const pending = this.pendingPhoneSession;
    if (!pending || !pending.creating) { return; }
    clearTimeout(pending.timer);
    pending.timer = -1;
    pending.creating = false;
    pending.error = message;
    this.store.timeline(pending.draftId).preview = '创建未完成，点击重试';
  }

  /** Execute a Xiaoyi request over the existing paired gateway. */
  runAgentCommand(taskId: string, contextId: string, text: string,
    onAction?: (notice: AgentActionNotice) => void): Promise<AgentCommandResult> {
    const command = text.trim();
    if (!taskId || !command) {
      return Promise.reject(new Error('小艺没有提供有效的任务内容'));
    }
    const run = this.agentQueue.then(async (): Promise<AgentCommandResult> => {
      if (this.cancelledAgentTasks.has(taskId)) {
        this.cancelledAgentTasks.delete(taskId);
        throw new Error('任务已取消');
      }
      this.agentLeases += 1;
      if (!this.uiForeground) { this.reconcileBackgroundTask(); }
      try {
        return await this.executeAgentCommand(taskId, contextId, command, onAction);
      } finally {
        this.agentLeases = Math.max(0, this.agentLeases - 1);
        this.reconcileBackgroundTask();
      }
    });
    this.agentQueue = run.then((): void => {}, (): void => {});
    return run;
  }

  async cancelAgentTask(taskId: string): Promise<boolean> {
    this.cancelledAgentTasks.add(taskId);
    const active = this.agentDispatchByTask.get(taskId);
    if (!active) {
      if (this.agentReplyWaiters.has(taskId)) {
        this.finishAgentReply(taskId, new Error('任务已取消'));
      }
      if (this.pendingAgentSession?.taskId === taskId) {
        this.finishAgentSession(null, new Error('任务已取消'));
      }
      return true;
    }
    try {
      await this.waitForAgentBridge(taskId, false);
    } catch (_error) {
      this.finishAgentReply(taskId, new Error('未能连接电脑确认中断状态'));
      return false;
    }
    const interruptId = this.nextAgentRequestId();
    return await new Promise<boolean>((resolve: (confirmed: boolean) => void): void => {
      const timer = setTimeout((): void => {
        this.agentInterruptWaiters.delete(interruptId);
        resolve(false);
        this.finishAgentReply(taskId, new Error('电脑端未确认中断，任务状态需要在 App 中检查'));
      }, 10000);
      this.agentInterruptWaiters.set(interruptId, {
        taskId: taskId, requestId: interruptId, taskRequestId: active.requestId,
        resolve: resolve, timer: timer
      });
      this.sendNow({
        t: 'interrupt', session: active.sessionId, request_id: interruptId,
        task_request_id: active.requestId
      });
    });
  }

  isAgentTaskCancelled(taskId: string): boolean {
    return this.cancelledAgentTasks.has(taskId);
  }

  finishAgentTask(taskId: string): void {
    this.cancelledAgentTasks.delete(taskId);
    this.agentSessionByTask.delete(taskId);
    this.agentDispatchByTask.delete(taskId);
  }

  clearAgentContext(contextId: string): void {
    if (!contextId) { return; }
    const sid = this.agentSessionByContext.get(contextId) ?? '';
    this.agentSessionByContext.delete(contextId);
    void AppPrefs.forgetAgentSession(this.context, contextId);
    if (sid) {
      const resolved = this.store.resolveId(sid);
      this.store.removeSession(resolved);
      AppPrefs.phoneSessionIds = AppPrefs.phoneSessionIds.filter((id: string): boolean =>
        this.store.resolveId(id) !== resolved);
      if (this.context) { void AppPrefs.save(this.context); }
      else { AppPrefs.publish(); }
      this.publishUi();
    }
  }

  private async executeAgentCommand(taskId: string, contextId: string, text: string,
    onAction?: (notice: AgentActionNotice) => void): Promise<AgentCommandResult> {
    await this.ensureAgentBridgeReady(taskId);
    if (!this.agentProtocolReady) {
      throw new Error('电脑端桥接程序版本过旧，请升级到 0.3.5 或更新版本');
    }
    if (this.cancelledAgentTasks.has(taskId)) {
      throw new Error('任务已取消');
    }
    const key = contextId || `task:${taskId}`;
    let sid = this.agentSessionByContext.get(key) ?? '';
    if (!sid) {
      sid = await this.createAgentSession(taskId);
      this.agentSessionByContext.set(key, sid);
      await AppPrefs.rememberAgentSession(this.context, key, sid);
    }
    if (this.cancelledAgentTasks.has(taskId)) {
      throw new Error('任务已取消');
    }
    if (!this.isReady()) {
      throw new Error('创建 Hermes 对话后连接中断，请重新发送任务');
    }
    this.agentSessionByTask.set(taskId, sid);
    const requestId = this.nextAgentRequestId();
    const reply = this.waitForAgentReply(taskId, requestId, sid, text, onAction);
    this.agentDispatchByTask.set(taskId, { requestId: requestId, sessionId: sid });
    const dispatch: WireOut = {
      t: 'dispatch', session: sid, text: text, request_id: requestId, agent_session: true
    };
    this.sendNow(dispatch);
    this.publishUi();
    try {
      return await reply;
    } finally {
      this.agentSessionByTask.delete(taskId);
    }
  }

  private async ensureAgentBridgeReady(taskId: string): Promise<void> {
    if (this.isReady()) { return; }
    await this.waitForAgentBridge(taskId, true);
  }

  private async waitForAgentBridge(taskId: string, honorCancellation: boolean): Promise<void> {
    if (this.isReady()) { return; }
    if (!this.context) {
      throw new Error('请先打开赫默狮并完成电脑配对');
    }
    if (this.closingOnPurpose) {
      throw new Error('连接已断开，请打开 App 重新连接电脑');
    }
    void this.connect();
    await new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      const started = Date.now();
      const poll = setInterval((): void => {
        if (this.isReady()) {
          clearInterval(poll);
          resolve();
          return;
        }
        if (this.closingOnPurpose) {
          clearInterval(poll);
          reject(new Error('连接已断开，请打开 App 重新连接电脑'));
          return;
        }
        if (honorCancellation && this.cancelledAgentTasks.has(taskId)) {
          clearInterval(poll);
          reject(new Error('任务已取消'));
          return;
        }
        if (Date.now() - started >= 30000) {
          clearInterval(poll);
          reject(new Error(this.lastError || '连接电脑超时，请检查配对和网络'));
        } else if (!this.connecting && !this.bridgeReady) {
          void this.connect();
        }
      }, 250);
    });
  }

  private createAgentSession(taskId: string): Promise<string> {
    if (!this.isReady()) {
      return Promise.reject(new Error('当前没有连接到电脑上的 Hermes Agent'));
    }
    const requestId = this.nextAgentRequestId();
    return new Promise<string>((resolve: (sessionId: string) => void, reject: (reason: Error) => void): void => {
      const timer = setTimeout((): void => {
        if (this.pendingAgentSession?.requestId === requestId) {
          this.finishAgentSession(null, new Error('创建 Hermes 对话超时，请重试'));
        }
      }, 20000);
      this.pendingAgentSession = { taskId: taskId, requestId: requestId, resolve: resolve, reject: reject, timer: timer };
      this.sendNow({
        t: 'new_session', title: '小艺 · Hermes', request_id: requestId, agent_session: true
      });
    });
  }

  private waitForAgentReply(taskId: string, requestId: string, sessionId: string,
    userText: string, onAction?: (notice: AgentActionNotice) => void): Promise<AgentCommandResult> {
    return new Promise<AgentCommandResult>((resolve: (result: AgentCommandResult) => void,
      reject: (reason: Error) => void): void => {
      const timer = setTimeout((): void => {
        this.finishAgentReply(taskId, new Error('Hermes 回复超时，请在 App 中检查任务状态'));
      }, 65 * 60 * 1000);
      this.agentReplyWaiters.set(taskId, {
        taskId: taskId, requestId: requestId, sessionId: sessionId, userText: userText,
        onAction: onAction, seenActionIds: new Set<string>(),
        resolve: resolve, reject: reject, timer: timer
      });
    });
  }

  private finishAgentSession(sessionId: string | null, error: Error | null): void {
    const pending = this.pendingAgentSession;
    if (!pending) { return; }
    this.pendingAgentSession = null;
    clearTimeout(pending.timer);
    if (error) { pending.reject(error); }
    else if (sessionId) { pending.resolve(sessionId); }
    else { pending.reject(new Error('没有创建 Hermes 对话')); }
  }

  private finishAgentReply(taskId: string, error: Error | null, result?: AgentCommandResult): void {
    const pending = this.agentReplyWaiters.get(taskId);
    if (!pending) { return; }
    this.agentReplyWaiters.delete(taskId);
    this.agentDispatchByTask.delete(taskId);
    clearTimeout(pending.timer);
    if (error) { pending.reject(error); }
    else if (result) { pending.resolve(result); }
    else { pending.reject(new Error('Hermes 没有返回结果')); }
  }

  private rejectAgentOperations(message: string): void {
    this.finishAgentSession(null, new Error(message));
    const taskIds = Array.from(this.agentReplyWaiters.keys());
    for (let i = 0; i < taskIds.length; i++) {
      const active = this.agentDispatchByTask.get(taskIds[i]);
      if (active) {
        this.sendNow({ t: 'interrupt', session: active.sessionId, request_id: this.nextAgentRequestId(),
          task_request_id: active.requestId });
      }
      this.finishAgentReply(taskIds[i], new Error(message));
    }
    for (const interrupt of this.agentInterruptWaiters.values()) {
      clearTimeout(interrupt.timer);
      interrupt.resolve(false);
    }
    this.agentInterruptWaiters.clear();
  }

  private nextAgentRequestId(): string {
    this.agentRequestSequence += 1;
    return `harmony-agent-${Date.now()}-${this.agentRequestSequence}`;
  }

  private beginSessionAction(action: 'archive' | 'restore' | 'delete', sessionId: string): void {
    this.sessionActionNotice = '';
    if (!this.isReady()) {
      this.sessionActionNotice = '连接电脑后才能管理会话';
      this.publishUi();
      return;
    }
    if (this.pendingSessionAction) {
      this.sessionActionNotice = '上一个会话操作仍在等待电脑端确认';
      this.publishUi();
      return;
    }
    const resolved = this.store.resolveId(sessionId);
    this.sessionActionSequence += 1;
    const requestId = `harmony-session-${Date.now()}-${this.sessionActionSequence}`;
    const pending: PendingSessionAction = {
      requestId: requestId,
      action: action,
      sessionId: resolved,
      timer: -1,
    };
    pending.timer = setTimeout(() => {
      if (!this.pendingSessionAction || this.pendingSessionAction.requestId !== requestId) {
        return;
      }
      this.pendingSessionAction = null;
      this.sessionActionNotice = '电脑端暂未确认操作结果，请检查会话状态后再重试';
      if (this.isReady()) {
        this.listSessions();
      }
      this.publishUi();
    }, 12000);
    this.pendingSessionAction = pending;
    this.sessionActionNotice = action === 'archive' ? '正在归档…' :
      action === 'restore' ? '正在恢复会话…' : '正在删除会话…';
    this.publishUi();
    if (action === 'delete') {
      this.send({ t: 'session_delete', session: resolved, request_id: requestId });
    } else {
      this.send({ t: 'session_archive', session: resolved, archived: action === 'archive', request_id: requestId });
    }
  }

  private finishSessionAction(
    notice: string, requestId: string = '', action: string = '', sessionId: string = ''
  ): boolean {
    const pending = this.pendingSessionAction;
    if (pending) {
      if (requestId.length > 0 && requestId !== pending.requestId) {
        return false;
      }
      if (requestId.length === 0 &&
        ((action.length > 0 && action !== pending.action) ||
          (sessionId.length > 0 && this.store.resolveId(sessionId) !== pending.sessionId))) {
        return false;
      }
    }
    if (pending) {
      clearTimeout(pending.timer);
      this.pendingSessionAction = null;
    }
    this.sessionActionNotice = notice;
    this.publishUi();
    return true;
  }

  archiveSession(sessionId: string, archived: boolean): void {
    this.beginSessionAction(archived ? 'archive' : 'restore', sessionId);
  }

  deleteSession(sessionId: string): void {
    this.beginSessionAction('delete', sessionId);
  }

  listSessions(): void {
    const msg: WireOut = { t: 'sessions' };
    this.send(msg);
  }

  asrStart(sr: number, sessionId: string): void {
    const sid = this.store.resolveId(sessionId);
    this.setActiveSession(sid);
    const msg: WireOut = { t: 'asr_start', sr: sr, session: sid };
    this.send(msg);
  }

  asrEnd(): void {
    const msg: WireOut = { t: 'asr_end' };
    this.send(msg);
  }

  asrCancel(): void {
    if (this.isReady()) { this.send({ t: 'asr_cancel' }); }
  }

  noteOutgoingVoice(sessionId: string, seconds: number): void {
    const sid = this.store.resolveId(sessionId);
    this.setActiveSession(sid);
    this.store.timeline(sid).appendLocalVoice(seconds);
    this.awaitingReply = true;
    this.publishUi();
  }

  tts(text: string): void {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.pcmBytes = 0;
    this.setStorage('hermes_speaking', true);
    const msg: WireOut = { t: 'tts', text: trimmed };
    this.send(msg);
  }

  private maybeAutoSpeak(params: HermesParams, sid: string): void {
    if (eventType(params) !== 'message.complete') {
      return;
    }
    if (this.awaitingReply) {
      this.awaitingReply = false;
    }
    // Bridge auto-sends tts_start/pcm after this complete. Do not request tts
    // again — that doubled playback and raced the player.
  }

  private updateHermesStatus(available: boolean, epoch: string): void {
    const wasAvailable = this.hermes;
    const oldEpoch = this.store.epoch;
    this.store.applyEpoch(epoch);
    this.hermes = available;
    if (!available) {
      this.resetVoice();
      this.lastError = '网关已连接，Hermes 暂不可用';
    } else if (this.lastError === '网关已连接，Hermes 暂不可用' ||
      this.lastError === 'Hermes 暂不可用，正在等待恢复') {
      this.lastError = '';
    }
    if (wasAvailable !== available || oldEpoch !== this.store.epoch) {
      this.publishUi();
    }
    if (available && (!wasAvailable || (epoch.length > 0 && oldEpoch !== epoch))) {
      this.refreshVoice();
      if (this.activeSessionId.length > 0) {
        const active = this.store.timeline(this.activeSessionId);
        this.sub(this.activeSessionId, active.lastSeen);
      }
      this.listSessions();
    }
  }

  private onText(raw: string): void {
    this.lastMessageAt = Date.now();
    let msg: WireMsg;
    try {
      msg = JSON.parse(raw) as WireMsg;
    } catch (_err) {
      return;
    }
    const kind = msg.t ?? '';
    if (kind === 'ready') {
      const resumedSocket = this.resumeProbeTimer !== -1;
      const wasAvailable = this.hermes;
      const oldEpoch = this.store.epoch;
      this.clearResumeProbe();
      this.finishForegroundRecovery();
      this.clearHandshake();
      this.connecting = false;
      this.reconnectAttempt = 0;
      this.connected = true;
      this.bridgeReady = true;
      this.lastError = '';
      const features = msg.features ?? [];
      this.voiceProtocol = features.indexOf('voice_readiness_v1') >= 0;
      this.setStorage('hermes_voice_reason', this.voiceProtocol ? '正在检查电脑语音配置…' : '电脑连接器需要更新，才能检查语音配置。');
      this.agentProtocolReady = features.indexOf('a2a_task_correlation_v1') >= 0 &&
        features.indexOf('a2a_control_handoff_v1') >= 0;
      this.startLiveness();
      this.publishUi();
      this.updateHermesStatus(msg.hermes === true, msg.epoch ?? '');
      // A retained socket keeps its subscription, but frames can have been
      // missed during suspension. Fill the selected conversation from its cursor.
      if (resumedSocket && wasAvailable && this.hermes && oldEpoch === this.store.epoch) {
        if (this.activeSessionId.length > 0) {
          const active = this.store.timeline(this.activeSessionId);
          this.sub(this.activeSessionId, active.lastSeen);
        }
        this.listSessions();
      }
      for (const waiter of this.agentReplyWaiters.values()) {
        const liveSession = this.store.resolveId(waiter.sessionId);
        const timeline = this.store.timeline(liveSession);
        this.sub(liveSession, timeline.lastSeen);
      }
    } else if (kind === 'voice_capabilities') {
      this.applyVoiceCapabilities(msg.voice);
      if (msg.request_id) {
        this.finishVoiceCheck(msg.request_id, this.connected && this.hermes ?
          (this.voiceConfigured ? 'ready' : 'not_ready') : 'disconnected');
      }
    } else if (kind === 'session_resolved') {
      const waiter = this.findAgentReplyByRequest(msg.request_id ?? '');
      const liveSession = msg.session ?? '';
      const requestedSession = msg.requested ?? '';
      if (waiter && liveSession) {
        if (requestedSession) { this.store.rememberAlias(requestedSession, liveSession); }
        waiter.sessionId = liveSession;
        this.store.timeline(liveSession).appendLocalUser(waiter.userText);
        this.agentSessionByTask.set(waiter.taskId, liveSession);
        const dispatch = this.agentDispatchByTask.get(waiter.taskId);
        if (dispatch) { dispatch.sessionId = liveSession; }
      }
    } else if (kind === 'interrupt_result') {
      const interrupt = this.agentInterruptWaiters.get(msg.request_id ?? '');
      if (interrupt) {
        this.agentInterruptWaiters.delete(interrupt.requestId);
        clearTimeout(interrupt.timer);
        const confirmed = msg.status === 'interrupted' &&
          (msg.task_request_id ?? '') === interrupt.taskRequestId;
        interrupt.resolve(confirmed);
        if (confirmed) {
          this.finishAgentReply(interrupt.taskId, new Error('任务已取消'));
        } else {
          this.finishAgentReply(interrupt.taskId, new Error('电脑端未确认中断，任务状态需要在 App 中检查'));
        }
      } else if (msg.status === 'interrupted' && msg.task_request_id) {
        const waiter = this.findAgentReplyByRequest(msg.task_request_id);
        if (waiter) {
          this.finishAgentReply(waiter.taskId, new Error('Hermes 任务已从 App 中中断'));
        }
      }
    } else if (kind === 'ev' && msg.p) {
      const sid = `${msg.p.session_id ?? ''}`;
      if (sid) {
        const existing = this.store.find(sid);
        const allowCreate = AppPrefs.syncAllSessions ||
          AppPrefs.isPhoneOwned(sid) ||
          (existing !== null && existing.fromPhone);
        if (existing !== null || allowCreate) {
          const tl = this.store.timeline(sid);
          if (AppPrefs.isPhoneOwned(sid)) {
            tl.fromPhone = true;
          }
          const changed = tl.ingest(msg.p);
          const waiter = this.findAgentReplyByRequest(`${msg.p.harmony_request_id ?? ''}`);
          const eventKind = eventType(msg.p);
          if (waiter && (eventKind === 'approval.request' || eventKind === 'clarify.request')) {
            const payload = msg.p.payload ?? {};
            const actionId = `${payload['request_id'] ?? `${eventKind}:${msg.p.seq ?? ''}`}`;
            if (!waiter.seenActionIds.has(actionId) && waiter.seenActionIds.size < 64) {
              waiter.seenActionIds.add(actionId);
              const prompt = eventKind === 'clarify.request' ?
                `${payload['question'] ?? payload['description'] ?? payload['prompt'] ?? ''}`.trim() : '';
              const notice: AgentActionNotice = {
                kind: eventKind === 'approval.request' ? 'approval' : 'clarification', text: prompt
              };
              try { waiter.onAction?.(notice); } catch (_error) {
                // Progress delivery must never prevent the Hermes turn from finishing.
              }
            }
          } else if (waiter && eventKind === 'message.complete') {
            const payload = msg.p.payload ?? {};
            const role = `${payload['role'] ?? ''}`.trim().toLowerCase();
            const displayKind = `${payload['display_kind'] ?? ''}`.trim().toLowerCase();
            const status = `${payload['status'] ?? ''}`.trim().toLowerCase();
            if (status === 'interrupted' || status === 'cancelled' || status === 'aborted' || status === 'error') {
              this.finishAgentReply(waiter.taskId, new Error('Hermes 未能完成此任务，请在 App 中检查对话状态'));
            } else if ((!role || role === 'assistant') && displayKind !== 'hidden' &&
              displayKind !== 'tool' && displayKind !== 'internal') {
              let reply = `${payload['text'] ?? payload['content'] ?? payload['message'] ?? ''}`.trim();
              if (!reply) { reply = tl.assistantText.trim(); }
              if (reply) {
                this.finishAgentReply(waiter.taskId, null, { text: reply });
              }
            }
          }
          if (changed && eventType(msg.p) === 'message.complete') {
            const isReplyToActivePhoneTask = this.awaitingReply && this.activeSessionId === sid;
            const isReplyToAgentTask = waiter !== undefined;
            if (!this.uiForeground && this.context && (isReplyToActivePhoneTask || isReplyToAgentTask)) {
              const payload = msg.p.payload ?? {};
              const role = `${payload['role'] ?? ''}`.trim().toLowerCase();
              const displayKind = `${payload['display_kind'] ?? ''}`.trim().toLowerCase();
              if ((!role || role === 'assistant') && displayKind !== 'hidden' &&
                displayKind !== 'tool' && displayKind !== 'internal') {
                let reply = `${payload['text'] ?? payload['content'] ?? ''}`.trim();
                if (!reply) { reply = tl.assistantText.trim(); }
                void TaskReplyNotifications.publishReply(sid, tl.displayTitle(), reply, msg.p.seq ?? 0);
              }
            }
            this.maybeAutoSpeak(msg.p, sid);
          }
          if (eventType(msg.p) === 'message.complete') {
            this.reconcileBackgroundTask();
          }
        }
      }
      this.publishUi();
    } else if (kind === 'replay') {
      if (this.replayOpen > 0) {
        this.replayOpen -= 1;
      }
      const sid = msg.session ?? '';
      if (!sid) {
        return;
      }
      const existing = this.store.find(sid);
      if (!existing && !AppPrefs.syncAllSessions && !AppPrefs.isPhoneOwned(sid)) {
        return;
      }
      const tl: SessionTimeline = this.store.timeline(sid);
      if (msg.truncated === true) {
        const emptyResume: ResumeSnapshot = {};
        tl.replaceFromResume(msg.resume !== undefined ? msg.resume : emptyResume, msg.latest_seq ?? 0);
        const approval = msg.resume?.pending_approval;
        if (approval) {
          tl.pendingApproval = approval;
        }
      } else if (typeof msg.latest_seq === 'number' && msg.latest_seq > tl.lastSeen) {
        tl.lastSeen = msg.latest_seq;
      }
      this.publishUi();
    } else if (kind === 'sessions') {
      this.sessionsList = msg.list ?? [];
      const phone = this.pendingPhoneSession;
      const isPhoneCreate = phone !== null &&
        (msg.request_id === phone.requestId || (!msg.request_id && this.pendingAgentSession === null && !!msg.created));
      if (isPhoneCreate && !msg.created) {
        this.failPhoneSession('电脑未能创建新对话，请重试');
      }
      if (msg.created && msg.created.length > 0) {
        const live = msg.created;
        const pending = this.pendingAgentSession;
        const isAgentCreate = pending !== null && msg.request_id === pending.requestId;
        // A late response to an abandoned retry must not open another page.
        const obsoletePhoneCreate = !isPhoneCreate && (msg.request_id ?? '').startsWith('harmony-ui-session-');
        const stored = (msg.stored && msg.stored.length > 0) ? msg.stored : live;
        if (!obsoletePhoneCreate) {
          if (isPhoneCreate && phone) {
            clearTimeout(phone.timer);
            // Only the UI owns typed draft text. No task is sent to this id.
            this.store.removeSession(phone.draftId);
            this.store.rememberAlias(phone.draftId, live);
            this.pendingPhoneSession = null;
          }
          this.store.rememberAlias(stored, live);
          const tl = this.store.markPhoneOwned(live, true);
          if (tl.title.length === 0) { tl.title = phone && isPhoneCreate ? phone.title : '新对话'; }
          void AppPrefs.rememberPhoneSession(this.context, live);
          if (stored !== live) { void AppPrefs.rememberPhoneSession(this.context, stored); }
          if (isPhoneCreate && phone) {
            if (this.activeSessionId === phone.draftId) {
              this.lastError = '';
              this.setActiveSession(live);
              this.sub(live, tl.lastSeen);
            }
          } else if (isAgentCreate && pending) {
            this.agentSessionByTask.set(pending.taskId, stored);
            this.finishAgentSession(stored, null);
          } else {
            this.setActiveSession(live);
            this.setStorage('hermes_pending_session', live);
          }
        }
      }
      const list = msg.list ?? [];
      for (let i = 0; i < list.length; i++) {
        const row = list[i] as Record<string, Object>;
        const stored = `${row['stored_session_id'] ?? ''}`;
        const live = `${row['session_id'] ?? row['id'] ?? stored}`;
        if (live.length === 0) {
          continue;
        }
        if (stored.length > 0) {
          this.store.rememberAlias(stored, live);
        }
        const owned = AppPrefs.isPhoneOwned(live) || AppPrefs.isPhoneOwned(stored);
        if (!AppPrefs.syncAllSessions && !owned) {
          continue;
        }
        const tl = owned ? this.store.markPhoneOwned(live, false) : this.store.timeline(live);
        if (AppPrefs.syncAllSessions) {
          tl.fromPhone = owned || tl.fromPhone;
        }
        const rawTitle = row['title'];
        const title = typeof rawTitle === 'string' ? rawTitle : '';
        if (title.length > 0 && !isGenericTitle(title)) {
          tl.title = title;
          tl.listed = true;
        }
        tl.archived = false;
        // session.list preview is an untyped backend summary and may contain
        // tool output or broken fragments. Replay/resume supplies chat-only text.
      }
      if (msg.archived_list !== undefined) {
        const archivedList = msg.archived_list;
        for (let i = 0; i < archivedList.length; i++) {
          const row = archivedList[i] as Record<string, Object>;
          const sid = `${row['id'] ?? row['stored_session_id'] ?? row['session_id'] ?? ''}`;
          if (sid.length === 0) {
            continue;
          }
          const owned = AppPrefs.isPhoneOwned(sid);
          if (!AppPrefs.syncAllSessions && !owned) {
            continue;
          }
          const tl = owned ? this.store.markPhoneOwned(sid, false) : this.store.timeline(sid);
          if (AppPrefs.syncAllSessions) {
            tl.fromPhone = owned || tl.fromPhone;
          }
          const rawTitle = row['title'];
          const title = typeof rawTitle === 'string' ? rawTitle : '';
          if (title.length > 0 && !isGenericTitle(title)) {
            tl.title = title;
          }
          tl.archived = true;
          tl.listed = true;
        }
      }
      if (!AppPrefs.syncAllSessions) {
        this.store.pruneForeign(false);
      }
      if (msg.created && msg.created.length > 0) {
        this.sub(msg.created, 0);
      }
      this.publishUi();
    } else if (kind === 'session_action') {
      if (!this.finishSessionAction('', msg.request_id ?? '', msg.action ?? '', msg.session ?? '')) {
        return;
      }
      const sid = msg.session ?? '';
      const resolved = this.store.resolveId(sid);
      const stored = msg.stored ?? '';
      const action = msg.action ?? '';
      if (action === 'delete') {
        this.store.removeSession(sid);
        void AppPrefs.forgetPhoneSessions(this.context, [sid, resolved, stored]);
        const agentContexts = Array.from(this.agentSessionByContext.keys());
        for (let i = 0; i < agentContexts.length; i++) {
          const contextId = agentContexts[i];
          const agentSessionId = this.agentSessionByContext.get(contextId) ?? '';
          if (agentSessionId === sid || agentSessionId === resolved || agentSessionId === stored ||
            this.store.resolveId(agentSessionId) === resolved) {
            this.agentSessionByContext.delete(contextId);
          }
        }
        void AppPrefs.forgetAgentSessionsForSessions(this.context, [sid, resolved, stored]);
        if (this.activeSessionId === sid || this.activeSessionId === resolved) {
          this.activeSessionId = '';
          this.awaitingReply = false;
        }
        this.sessionActionNotice = '会话已删除';
      } else {
        const tl = this.store.find(sid);
        if (tl) {
          tl.archived = msg.archived === true;
          tl.listed = true;
        }
        this.sessionActionNotice = msg.archived === true ? '会话已归档' : '会话已恢复';
      }
      this.publishUi();
    } else if (kind === 'transcript') {
      this.transcript = msg.body ?? '';
      this.publishUi();
    } else if (kind === 'tts_start') {
      this.pcmBytes = 0;
      this.acceptingPcm = this.isVoiceReady() && AppPrefs.autoVoiceReply && this.uiForeground;
      if (!this.acceptingPcm) { return; }
      this.setStorage('hermes_speaking', true);
      if (this.onTtsStart) {
        this.onTtsStart(msg.sr ?? 16000);
      }
      this.publishUi();
    } else if (kind === 'tts_end') {
      if (!this.acceptingPcm) { return; }
      this.acceptingPcm = false;
      if (this.onTtsEnd) {
        this.onTtsEnd(msg.aborted === true, msg.bytes ?? this.pcmBytes);
      }
      this.publishUi();
    } else if (kind === 'error') {
      const code = msg.code ?? '';
      if (code === 'voice_unavailable') {
        this.applyVoiceCapabilities({ ready: false, reason: msg.msg ?? '电脑语音配置未就绪。' });
        return;
      }
      if (code === 'session_action') {
        this.finishSessionAction(
          msg.msg ?? '会话操作失败，请重试', msg.request_id ?? '', msg.action ?? '', msg.session ?? ''
        );
        return;
      }
      if (code === 'new_session' && this.pendingPhoneSession &&
        (msg.request_id === this.pendingPhoneSession.requestId || (!msg.request_id && !this.pendingAgentSession))) {
        this.failPhoneSession('电脑未能创建新对话，请重试');
        this.publishUi();
        return;
      }
      if (code === 'new_session' && (msg.request_id ?? '').startsWith('harmony-ui-session-')) { return; }
      if (this.pendingSessionAction &&
        (!msg.request_id || msg.request_id === this.pendingSessionAction.requestId)) {
        const notice = code === 'unknown'
          ? '电脑端桥接版本不支持此会话操作，请更新电脑端桥接程序'
          : msg.msg ?? '电脑端未能处理会话操作';
        this.finishSessionAction(notice, msg.request_id ?? '');
        return;
      }
      const pendingSession = this.pendingAgentSession;
      if (code === 'new_session' && pendingSession && msg.request_id === pendingSession.requestId) {
        this.finishAgentSession(null, new Error('Hermes 无法创建新对话，请检查电脑端 Agent 状态'));
      }
      if (msg.request_id) {
        const waiting = this.findAgentReplyByRequest(msg.request_id);
        if (waiting) {
          if (code === 'session_gone') {
            const keys = Array.from(this.agentSessionByContext.keys());
            for (let i = 0; i < keys.length; i++) {
              const mapped = this.agentSessionByContext.get(keys[i]) ?? '';
              if (mapped === (msg.session ?? '') ||
                this.store.resolveId(mapped) === this.store.resolveId(msg.session ?? '')) {
                this.agentSessionByContext.delete(keys[i]);
                void AppPrefs.forgetAgentSession(this.context, keys[i]);
              }
            }
          }
          const message = code === 'turn_timeout' && msg.interrupted !== true ?
            'Hermes 长时间无进展，未能确认任务已停止；请在 App 中检查状态' :
            this.agentDispatchError(code);
          this.finishAgentReply(waiting.taskId, new Error(message));
        }
      }
      if (code === 'replay') {
        if (this.replayOpen > 0) { this.replayOpen -= 1; }
        // Historical refresh is best-effort and must not overwrite the state
        // of the active turn with a global request-failed banner.
        this.publishUi();
        return;
      }
      if (code === 'session_gone') {
        if (this.replayOpen > 0) { this.replayOpen -= 1; }
        const stale = msg.session ?? '';
        if (stale.length > 0) {
          this.store.removeSession(stale);
          void AppPrefs.forgetPhoneSession(this.context, stale);
        }
        if (stale.length > 0 && stale === this.activeSessionId) {
          this.activeSessionId = '';
          this.awaitingReply = false;
          this.lastError = '当前对话已失效，正在创建新对话';
          const draft = this.newSession('新对话');
          if (draft) { this.setStorage('hermes_pending_session', draft); }
        }
        this.publishUi();
        return;
      }
      this.lastError = code === 'busy' ? '此对话正在执行其他任务，请稍后重试' :
        code === 'asr_short' ? '录音太短，请按住说完后再松开' :
        code === 'asr' ? '语音发送失败，请重新录音' :
        code === 'tts' ? '语音播放失败，文字回复仍可查看' :
        code === 'rate' ? '操作太快，请稍后重试' :
        code === 'turn_timeout' ? (msg.interrupted === true ?
          'Hermes 长时间无进展，任务已停止，请重试' :
          'Hermes 长时间无进展，未能确认任务已停止；请在电脑端检查状态') :
        code === 'hermes_down' ? 'Hermes 暂不可用，正在等待恢复' :
        '请求未完成，请检查连接状态后重试';
      if (this.awaitingReply &&
        (!msg.session || this.store.resolveId(msg.session) === this.activeSessionId)) {
        this.awaitingReply = false;
        this.reconcileBackgroundTask();
      }
      if (code === 'tts') { this.stopIncomingAudio(); }
      this.publishUi();
    } else if (kind === 'ping') {
      if (typeof msg.hermes === 'boolean') {
        this.updateHermesStatus(msg.hermes, msg.epoch ?? '');
      }
      const pong: WireOut = { t: 'pong' };
      this.send(pong);
    }
  }

  private scheduleReconnect(): void {
    if (this.closingOnPurpose || this.reconnectTimer !== -1 || this.connecting) { return; }
    if (!this.uiForeground && !this.hasPendingTurn()) { return; }
    this.reconnectAttempt += 1;
    const delay = this.foregroundRecovery && this.reconnectAttempt === 1 ? 0 :
      Math.min(8000, 500 * Math.pow(2, Math.min(this.reconnectAttempt, 4)));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (!this.closingOnPurpose) { void this.connect(); }
    }, delay);
  }

  private findAgentReplyByRequest(requestId: string): PendingAgentReply | undefined {
    for (const waiter of this.agentReplyWaiters.values()) {
      if (waiter.requestId === requestId) { return waiter; }
    }
    return undefined;
  }

  private agentDispatchError(code: string): string {
    if (code === 'rate') { return '请求过于频繁，请稍后再试'; }
    if (code === 'busy') { return '该 Hermes 对话正在执行其他任务，请稍后再试'; }
    if (code === 'bad_dispatch') { return 'Hermes 任务内容无效，请重新描述'; }
    if (code === 'turn_timeout') { return 'Hermes 长时间无进展，任务已停止'; }
    if (code === 'session_gone') { return 'Hermes 对话已失效，请重新发送任务'; }
    if (code === 'hermes_down') { return '电脑上的 Hermes Agent 当前不可用'; }
    return '任务发送失败，请检查手机与电脑的连接';
  }
}
