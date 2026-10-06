/**
 * Chat: WeChat-like bubbles, Aa / hold-to-talk composer, quiet header.
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { GatewayClient } from '../service/GatewayClient';
import { Recorder } from '../service/Recorder';
import { Player } from '../service/Player';
import { HermesParams, eventType, payloadText } from '../model/HermesEvent';
import { SessionTimeline } from '../service/EventStore';
import { approvalCardMaxWidthVp, bubbleMaxWidthPercent, isWidePhone } from '../util/DisplayAdapt';
import { Theme, ThemePalette } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';
import { MarkdownRun, markdownToRuns } from '../util/Markdown';

const WAIT_PROGRESS_WARNING_MS = 8 * 60 * 1000;
const WAIT_PROGRESS_NOTICE = 'Hermes 已 8 分钟没有进展；10 分钟无进展后会尝试中断。可以继续等待，或手动停止任务';

function recField(rec: Record<string, Object>, key: string, fallback: string): string {
  const v = rec[key];
  if (v === undefined) {
    return fallback;
  }
  return `${v}`;
}

function recChoices(rec: Record<string, Object>, fallback: string[]): string[] {
  const raw = rec['choices'];
  if (raw === undefined) {
    return fallback;
  }
  const arr = raw as string[];
  const out: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    out.push(`${arr[i]}`);
  }
  if (out.length === 0) {
    return fallback;
  }
  return out;
}

function payloadSeconds(ev: HermesParams): number {
  const payload = ev.payload;
  if (payload === undefined) {
    return 1;
  }
  const raw = payload['seconds'];
  if (typeof raw === 'number' && raw > 0) {
    return Math.round(raw);
  }
  return 1;
}

@Builder
function WaveTiny(active: boolean, colors: ThemePalette) {
  Row({ space: 2 }) {
    ForEach([8, 14, 10, 16, 9], (h: number) => {
      Column()
        .width(2)
        .height(active ? h : 6)
        .borderRadius(1)
        .backgroundColor(active ? colors.accent : colors.textMuted)
        .animation(AppMotion.press(AppMotion.reduced))
    }, (h: number) => `h-${h}`)
  }
}

@Builder
function UserVoiceBubble(seconds: number, colors: ThemePalette) {
  Row() {
    Blank()
    Row({ space: 8 }) {
      WaveTiny(true, colors)
      Text(`${seconds}″`)
        .fontSize(15)
        .fontColor(colors.text)
        .fontWeight(FontWeight.Medium)
    }
    .justifyContent(FlexAlign.Start)
    .constraintSize({ minWidth: 72 + Math.min(96, seconds * 10) })
    .padding({ left: 14, right: 16, top: 11, bottom: 11 })
    .backgroundColor(colors.bubbleUser)
    .borderRadius({ topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16 })
  }
  .width('100%')
  .padding({ left: 14, right: 14, top: 5, bottom: 5 })
}

@Builder
function MarkdownRunSpan(run: MarkdownRun, colors: ThemePalette) {
  if (run.strike) {
    Span(run.text)
      .fontSize(run.fontSize)
      .fontColor(run.link ? colors.accent : run.color)
      .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
      .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
      .fontFamily(run.mono ? 'monospace' : 'HarmonyOS Sans')
      .decoration({ type: TextDecorationType.LineThrough, color: run.color })
  } else if (run.link) {
    Span(run.text)
      .fontSize(run.fontSize)
      .fontColor(colors.accent)
      .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
      .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
      .fontFamily(run.mono ? 'monospace' : 'HarmonyOS Sans')
      .decoration({ type: TextDecorationType.Underline, color: colors.accent })
  } else {
    Span(run.text)
      .fontSize(run.fontSize)
      .fontColor(run.color)
      .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
      .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
      .fontFamily(run.mono ? 'monospace' : 'HarmonyOS Sans')
  }
}

@Builder
function UserBubble(text: string, colors: ThemePalette) {
  Row() {
    Blank()
    Text(text)
      .fontSize(16)
      .fontColor(colors.text)
      .lineHeight(23)
      .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      .copyOption(CopyOptions.LocalDevice)
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .constraintSize({ maxWidth: bubbleMaxWidthPercent() })
      .backgroundColor(colors.bubbleUser)
      .borderRadius({ topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16 })
  }
  .width('100%')
  .padding({ left: 14, right: 14, top: 5, bottom: 5 })
}

@Builder
function AssistantBubble(text: string, playing: boolean, renderMarkdown: boolean, colors: ThemePalette, voiceReady: boolean) {
  Row() {
    Column() {
      if (renderMarkdown) {
        Text() {
          ForEach(markdownToRuns(text, colors), (run: MarkdownRun, index: number) => {
            MarkdownRunSpan(run, colors)
          }, (_run: MarkdownRun, index: number) => `markdown-run-${index}`)
        }
          .fontSize(16)
          .fontColor(colors.text)
          .lineHeight(23)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          .copyOption(CopyOptions.LocalDevice)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .constraintSize({ maxWidth: bubbleMaxWidthPercent() })
          .backgroundColor(colors.bubbleAssistant)
          .borderRadius({ topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16 })
      } else {
        Text(text)
          .fontSize(16)
          .fontColor(colors.text)
          .lineHeight(23)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          .copyOption(CopyOptions.LocalDevice)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .constraintSize({ maxWidth: bubbleMaxWidthPercent() })
          .backgroundColor(colors.bubbleAssistant)
          .borderRadius({ topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16 })
      }
      if (voiceReady) {
        Row({ space: 8 }) {
          WaveTiny(playing, colors)
          Text(playing ? '正在播放' : 'Hermes')
            .fontSize(12)
            .fontColor(playing ? colors.accent : colors.textMuted)
        }
        .width('100%')
        .margin({ top: 6, left: 2 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    Blank()
  }
  .width('100%')
  .padding({ left: 14, right: 14, top: 5, bottom: 5 })
}

@Component
export struct SessionView {
  @StorageLink('hermes_reduce_motion') reduceMotion: boolean = false;

  @Styles
  controlFeedback() {
    .stateStyles({
      normal: { .scale({ x: 1, y: 1 }).opacity(1) },
      pressed: { .scale({ x: this.reduceMotion ? 1 : 0.97, y: this.reduceMotion ? 1 : 0.97 }).opacity(0.86) },
      disabled: { .scale({ x: 1, y: 1 }).opacity(0.45) }
    })
    .animation(AppMotion.press(this.reduceMotion))
  }

  @Styles
  inputFeedback() {
    .stateStyles({
      normal: { .border({ width: 1, color: Color.Transparent }) },
      focused: { .border({ width: 1, color: this.colors.accent }) }
    })
    .animation(AppMotion.press(this.reduceMotion))
  }

  @StorageLink('hermes_theme') @Watch('onThemeChanged') themeMode: string = 'light';
  @State colors: ThemePalette = Theme.palette(Theme.mode);

  onThemeChanged(): void {
    this.getUIContext().animateTo(AppMotion.settle(this.reduceMotion), () => {
      this.colors = Theme.palette(this.themeMode);
    });
  }

  @Prop embedded: boolean = false;
  @Prop @Watch('onSessionIdChange') sessionId: string = '';
  @StorageLink('hermes_rev') @Watch('onRev') uiRev: number = 0;
  @StorageLink('hermes_voice_mode') voiceMode: boolean = false;
  @StorageLink('hermes_voice_ready') @Watch('onVoiceReadyChanged') voiceReady: boolean = false;
  @StorageLink('hermes_speaking') speaking: boolean = false;
  @StorageLink('hermes_connected') connected: boolean = false;
  @StorageLink('hermes_hermes') hermesOnline: boolean = false;
  @StorageLink('hermes_error') lastError: string = '';
  @StorageLink('hermes_recovering') recovering: boolean = false;
  @StorageLink('hermes_foreground') @Watch('onForegroundChanged') foreground: boolean = true;
  @State draft: string = '';
  @State clarifyDraft: string = '';
  @State preparing: boolean = false;
  @State cancelGesture: boolean = false;
  @State elapsed: number = 0;
  @State notice: string = '';
  @State waiting: boolean = false;
  @State followBottom: boolean = true;
  private held: boolean = false;
  private ending: boolean = false;
  private recordingSession: string = "";
  private touchY: number = 0;
  private recTimer: number = -1;
  private waitTimer: number = -1;
  private seenResumeRevision: number = 0;
  private seenActivityRevision: number = 0;
  @State recording: boolean = false;
  @State wide: boolean = false;
  private gw: GatewayClient = GatewayClient.instance;
  private recorder: Recorder = new Recorder();
  private player: Player = Player.instance;
  private boundId: string = '';
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.onThemeChanged();
    this.wide = isWidePhone();
    this.player.attach();
    this.bindSession(this.sessionId);
    this.seenResumeRevision = this.timeline().resumeRevision;
    this.seenActivityRevision = this.timeline().activityRevision;
  }

  aboutToDisappear(): void {
    void this.stopRec(true);
    void this.player.stop();
    this.clearWaitTimer();
  }

  onVoiceReadyChanged(): void {
    if (!this.voiceReady) { void this.stopRec(true); }
  }

  onForegroundChanged(): void {
    if (!this.foreground) {
      void this.stopRec(true);
    }
  }

  onSessionIdChange(): void {
    void this.stopRec(true);
    void this.player.stop();
    this.draft = '';
    this.waiting = false;
    this.clearWaitTimer();
    this.notice = '';
    this.bindSession(this.sessionId);
    this.seenResumeRevision = this.timeline().resumeRevision;
    this.seenActivityRevision = this.timeline().activityRevision;
  }

  onRev(): void {
    if (!this.connected && (this.recording || this.preparing)) {
      void this.stopRec(true);
    }
    const tl = this.timeline();
    if (tl.resumeRevision !== this.seenResumeRevision) {
      this.seenResumeRevision = tl.resumeRevision;
      if (!tl.streaming) {
        this.finishWaiting();
      }
    }
    if (tl.activityRevision !== this.seenActivityRevision) {
      this.seenActivityRevision = tl.activityRevision;
      if (this.waiting) {
        if (this.notice === WAIT_PROGRESS_NOTICE) {
          this.notice = '';
        }
        this.armWaitTimer();
      }
    }
    const events = this.chatEvents();
    if (events.length > 0 && eventType(events[events.length - 1]) === 'message.complete') {
      this.finishWaiting();
    }
    if (this.lastError.length > 0) {
      this.finishWaiting();
    }
    if (this.followBottom) {
      this.scrollToLatest();
    }
  }

  private clearWaitTimer(): void {
    if (this.waitTimer !== -1) { clearTimeout(this.waitTimer); }
    this.waitTimer = -1;
  }

  private finishWaiting(): void {
    this.waiting = false;
    this.clearWaitTimer();
    if (this.notice === WAIT_PROGRESS_NOTICE) {
      this.notice = '';
    }
  }

  private scrollToLatest(): void {
    setTimeout(() => {
      if (this.followBottom) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 60);
  }

  private armWaitTimer(): void {
    this.clearWaitTimer();
    this.waitTimer = setTimeout(() => {
      this.waitTimer = -1;
      if (this.waiting) {
        this.notice = WAIT_PROGRESS_NOTICE;
      }
    }, WAIT_PROGRESS_WARNING_MS);
  }

  private bindSession(sid: string): void {
    if (sid.length === 0) {
      return;
    }
    const resolved = this.gw.store.resolveId(sid);
    this.gw.setActiveSession(resolved);
    if (resolved === this.boundId) {
      return;
    }
    this.boundId = resolved;
    this.gw.sub(resolved, this.timeline().lastSeen);
  }

  private timeline(): SessionTimeline {
    return this.gw.store.timeline(this.sessionId);
  }

  private chatEvents(): HermesParams[] {
    const _bump = this.uiRev;
    const all = this.timeline().events;
    const out: HermesParams[] = [];
    for (let i = 0; i < all.length; i++) {
      const t = eventType(all[i]);
      if (t === 'local.user' || t === 'local.voice' || t === 'message.complete') {
        out.push(all[i]);
      }
    }
    return out;
  }

  private lastCompleteIndex(events: HermesParams[]): number {
    for (let i = events.length - 1; i >= 0; i--) {
      if (eventType(events[i]) === 'message.complete') {
        return i;
      }
    }
    return -1;
  }

  private liveAssistant(): string {
    const _bump = this.uiRev;
    const tl = this.timeline();
    if (tl.streaming && tl.assistantText.length > 0) {
      return tl.assistantText;
    }
    return '';
  }

  private headerTitle(): string {
    const _bump = this.uiRev;
    return this.timeline().displayTitle();
  }

  private hasChat(): boolean {
    return this.chatEvents().length > 0 || this.liveAssistant().length > 0;
  }

  private isDraftSession(): boolean {
    const revision = this.uiRev;
    return this.gw.isDraftSession(this.sessionId);
  }

  private isCreatingSession(): boolean {
    const revision = this.uiRev;
    return this.gw.isCreatingSession(this.sessionId);
  }

  private canSend(): boolean {
    const revision = this.uiRev;
    return this.gw.isSessionReady(this.sessionId) && !this.waiting;
  }

  private creationMessage(): string {
    const revision = this.uiRev;
    return this.gw.sessionCreationMessage(this.sessionId);
  }

  private async startRec(): Promise<void> {
    if (this.recording || this.preparing || this.waiting || this.ending) {
      return;
    }
    if (this.isDraftSession()) { return; }
    if (!this.gw.isVoiceReady()) {
      this.notice = '请先在电脑完成语音配置，详情见安装与语音指南';
      this.gw.refreshVoice();
      return;
    }
    if (!this.gw.isReady()) {
      this.notice = '连接尚未就绪，请稍后重试';
      return;
    }
    this.held = true;
    this.recordingSession = this.sessionId;
    this.preparing = true;
    this.cancelGesture = false;
    this.notice = '';
    this.elapsed = 0;
    void this.player.stop();
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.recorder.start(ctx, this.recordingSession);
      if (!this.held) {
        return;
      }
      this.recording = true;
      AppStorage.setOrCreate('hermes_recording', true);
      this.recTimer = setInterval(() => {
        this.elapsed += 1;
        if (this.elapsed >= 60) {
          void this.stopRec();
        }
      }, 1000);
    } catch (err) {
      this.notice = '无法录音，请确认麦克风权限和连接后重试';
      this.held = false;
    } finally {
      this.preparing = false;
    }
  }

  private async stopRec(cancel: boolean = false): Promise<void> {
    if (this.ending) {
      if (cancel) { void this.recorder.stop(true); }
      return;
    }
    if (!this.recording && !this.preparing && !this.held) {
      return;
    }
    this.ending = true;
    const sid = this.recordingSession;
    this.held = false;
    clearInterval(this.recTimer);
    this.recTimer = -1;
    const sent = await this.recorder.stop(cancel || this.cancelGesture);
    this.recording = false;
    this.preparing = false;
    AppStorage.setOrCreate('hermes_recording', false);
    if (sent) {
      this.gw.noteOutgoingVoice(sid, this.recorder.lastDurationSec());
      this.waiting = true;
      this.armWaitTimer();
      this.followBottom = true;
      this.notice = '';
    } else {
      this.notice = cancel || this.cancelGesture ? '已取消录音' : '录音太短或尚未就绪，请重新按住说话';
    }
    this.cancelGesture = false;
    this.ending = false;
  }

  private sendDraft(): void {
    const text = this.draft.trim();
    if (text.length === 0 || this.waiting) {
      return;
    }
    if (this.isDraftSession()) { return; }
    if (!this.gw.isReady()) {
      this.notice = '尚未连接，输入内容已保留';
      return;
    }
    this.notice = '';
    this.followBottom = true;
    this.gw.dispatch(this.sessionId, text);
    this.waiting = true;
    this.armWaitTimer();
    this.draft = '';
  }

  private async switchToVoice(): Promise<void> {
    if (!this.voiceReady) {
      router.pushUrl({ url: 'pages/SetupPage' });
      return;
    }
    await this.gw.setVoiceInputMode(true);
  }

  private async switchToText(): Promise<void> {
    if (this.recording) {
      await this.stopRec(true);
    }
    await this.gw.setVoiceInputMode(false);
  }

  private goBack(): void {
    router.back();
  }

  private clarifyQuestion(): string {
    const clarify = this.timeline().pendingClarify;
    if (!clarify) {
      return '请确认';
    }
    return recField(clarify, 'question', '请确认');
  }

  private clarifyChoices(): string[] {
    const clarify = this.timeline().pendingClarify;
    if (!clarify) {
      return [];
    }
    return recChoices(clarify, []);
  }

  private clarifyRequestId(): string {
    const clarify = this.timeline().pendingClarify;
    if (!clarify) {
      return '';
    }
    return recField(clarify, 'request_id', '');
  }

  private clarifyServerRequestId(): string {
    const clarify = this.timeline().pendingClarify;
    return clarify ? recField(clarify, 'harmony_server_request_id', '') : '';
  }

  private submitClarify(answer: string): void {
    const value = answer.trim();
    if (value.length === 0) {
      return;
    }
    this.gw.clarify(
      this.sessionId, this.clarifyRequestId(), value, this.clarifyServerRequestId()
    );
    this.timeline().pendingClarify = null;
    this.clarifyDraft = '';
    this.gw.publishUi();
  }

  private approvalCommand(): string {
    const approval = this.timeline().pendingApproval;
    if (!approval) {
      return '';
    }
    const command = recField(approval, 'command', '');
    if (command.length > 0) {
      return command;
    }
    return recField(approval, 'description', '');
  }

  private approvalChoices(): string[] {
    const approval = this.timeline().pendingApproval;
    if (!approval) {
      return ['once', 'deny'];
    }
    return recChoices(approval, ['once', 'deny']);
  }

  private approvalRequestId(): string {
    const approval = this.timeline().pendingApproval;
    if (!approval) {
      return '';
    }
    return recField(approval, 'request_id', '');
  }

  private approvalServerRequestId(): string {
    const approval = this.timeline().pendingApproval;
    return approval ? recField(approval, 'harmony_server_request_id', '') : '';
  }

  @Builder
  ModeToggle() {
    if (this.voiceMode) {
      Button('Aa', { type: ButtonType.Normal })
        .width(48)
        .height(48)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.text)
        .backgroundColor(this.colors.chipBg)
        .borderRadius(20)
        .transition(AppMotion.fade(this.reduceMotion))
        .controlFeedback()
        .onClick(() => {
          void this.switchToText();
        })
    } else {
      Button({ type: ButtonType.Normal }) {
        WaveTiny(false, this.colors)
      }
      .width(48)
      .height(48)
      .backgroundColor(this.colors.chipBg)
      .borderRadius(20)
      .accessibilityText('切换到语音输入')
      .transition(AppMotion.fade(this.reduceMotion))
      .controlFeedback()
      .onClick(() => {
        void this.switchToVoice();
      })
    }
  }

  @Builder
  ComposerBar() {
    Row({ space: 8 }) {
      if (this.voiceReady) {
        this.ModeToggle()
      }

      if (this.voiceMode && this.voiceReady) {
        Text(this.preparing ? '正在准备麦克风…' : (this.recording ? (this.cancelGesture ? '松开取消' : `松开发送 · ${this.elapsed}s`) : (this.waiting ? '正在回复…' : '按住说话')))
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.recording ? this.colors.onAccent : this.colors.text)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.cancelGesture ? this.colors.danger : (this.recording ? this.colors.accent : this.colors.bgInput))
          .borderRadius(16)
          .scale({ x: (this.recording || this.preparing) && !this.reduceMotion ? 0.985 : 1,
            y: (this.recording || this.preparing) && !this.reduceMotion ? 0.985 : 1 })
          .animation(AppMotion.press(this.reduceMotion))
          .transition(AppMotion.fade(this.reduceMotion))
          .accessibilityText('按住说话，松开发送，上滑取消')
          .enabled(this.canSend())
          .onTouch((e: TouchEvent) => {
            if (e.type === TouchType.Down) {
              this.touchY = e.touches[0].screenY;
              void this.startRec();
            } else if (e.type === TouchType.Move && e.touches.length > 0) {
              this.cancelGesture = this.touchY - e.touches[0].screenY > 60;
            } else if (e.type === TouchType.Up) {
              void this.stopRec();
            } else if (e.type === TouchType.Cancel) {
              void this.stopRec(true);
            }
          })
      } else {
        TextInput({ text: this.draft, placeholder: '输入你想聊的内容…' })
          .layoutWeight(1)
          .height(48)
          .fontSize(16)
          .fontColor(this.colors.text)
          .placeholderColor(this.colors.placeholder)
          .backgroundColor(this.colors.bgInput)
          .borderRadius(16)
          .padding({ left: 12, right: 12 })
          .transition(AppMotion.fade(this.reduceMotion))
          .inputFeedback()
          .onChange((v: string) => {
            this.draft = v;
          })
          .onSubmit(() => {
            this.sendDraft();
          })

        if (this.draft.trim().length > 0) {
          Button('发送', { type: ButtonType.Normal })
            .height(48)
            .padding({ left: 14, right: 14 })
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors.onAccent)
            .backgroundColor(this.colors.accent)
            .borderRadius(16)
            .transition(AppMotion.reveal(this.reduceMotion))
            .enabled(this.canSend())
            .controlFeedback()
            .onClick(() => {
              this.sendDraft();
            })
        }
      }
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row() {
          if (!this.embedded) {
            Text('‹')
              .width(48)
              .height(48)
              .fontSize(22)
              .fontColor(this.colors.text)
              .textAlign(TextAlign.Center)
              .controlFeedback()
              .onClick(() => {
                this.goBack();
              })
          }
          Text(this.headerTitle())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(this.wide ? TextAlign.Start : TextAlign.Center)
            .margin({ left: this.wide ? 16 : 0 })
          if (this.speaking) {
            Row({ space: 6 }) {
              WaveTiny(true, this.colors)
            }
            .width(48)
            .justifyContent(FlexAlign.Center)
            .accessibilityText('停止语音播放')
            .transition(AppMotion.fade(this.reduceMotion))
            .controlFeedback()
            .onClick(() => { void this.player.stop(); })
          } else {
            Column().width(36)
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 6, right: 10 })
        .backgroundColor(this.colors.bgElevated)

        Divider().color(this.colors.hairline).strokeWidth(0.5)

        if (!this.hasChat()) {
          Column({ space: 16 }) {
            Text('赫')
              .fontSize(36)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors.accent)
              .width(80).height(80).textAlign(TextAlign.Center)
              .backgroundColor(this.colors.accentSoft).borderRadius(28)
            Text('从一个想法开始。')
              .fontSize(24).fontWeight(FontWeight.Bold)
              .fontColor(this.colors.text)
            Text(this.voiceReady ? '输入文字，或切换语音按住说话\n回复会保存在这段对话中' : '在下方输入消息，开始文字对话\n语音需先在电脑完成配置')
              .fontSize(14).lineHeight(23).textAlign(TextAlign.Center)
              .fontColor(this.colors.textSecondary)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.colors.bgChat)
        } else {
          List({ scroller: this.scroller }) {
            ForEach(this.chatEvents(), (ev: HermesParams, idx: number) => {
              ListItem() {
                if (eventType(ev) === 'local.voice') {
                  UserVoiceBubble(payloadSeconds(ev), this.colors)
                } else if (eventType(ev) === 'local.user') {
                  UserBubble(payloadText(ev), this.colors)
                } else {
                  AssistantBubble(
                    payloadText(ev),
                    this.speaking && idx === this.lastCompleteIndex(this.chatEvents()),
                    true, this.colors, this.voiceReady
                  )
                }
              }
              .transition(AppMotion.message(this.reduceMotion))
            }, (ev: HermesParams, idx: number) => `${ev.seq ?? idx}-${eventType(ev)}-${payloadText(ev).length}`)

            if (this.liveAssistant().length > 0) {
              ListItem() {
                AssistantBubble(
                  this.liveAssistant(), false, false, this.colors, this.voiceReady
                )
              }
              .transition(AppMotion.message(this.reduceMotion))
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(this.colors.bgChat)
          .edgeEffect(EdgeEffect.Spring)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            if (state === ScrollState.Scroll && offset < 0) { this.followBottom = false; }
            return { offsetRemain: offset };
          })
          .onReachEnd(() => { this.followBottom = true; })
        }

        if (this.isDraftSession()) {
          Row({ space: 10 }) {
            if (this.isCreatingSession()) {
              LoadingProgress().width(18).height(18).color(this.colors.accent)
            }
            Text(this.creationMessage()).fontSize(13).lineHeight(20)
              .fontColor(this.colors.textSecondary).layoutWeight(1)
            if (!this.isCreatingSession()) {
              Button('重试', { type: ButtonType.Normal }).height(36).fontSize(13)
                .fontColor(this.colors.accent).backgroundColor(this.colors.accentSoft).borderRadius(12)
                .controlFeedback()
                .onClick(() => { this.notice = ''; this.gw.retryNewSession(this.sessionId); })
            }
          }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .transition(AppMotion.reveal(this.reduceMotion))
        }
        if (!this.isDraftSession() && (this.notice.length > 0 || (!this.recovering && (this.lastError.length > 0 || !this.connected)))) {
          Text(this.notice.length > 0 ? this.notice : (this.lastError.length > 0 ? this.lastError : '连接已断开，正在恢复…'))
            .fontSize(13).fontColor(this.colors.warn).lineHeight(19)
            .padding(12).width('100%').backgroundColor(this.colors.bgElevated)
            .transition(AppMotion.reveal(this.reduceMotion))
        }
        if (this.waiting || this.timeline().streaming) {
          Row({ space: 12 }) {
            LoadingProgress().width(18).height(18).color(this.colors.accent)
            Text('Hermes 正在回复').fontSize(13).fontColor(this.colors.textSecondary).layoutWeight(1)
            Button('停止').height(36).fontSize(13).fontColor(this.colors.text)
              .backgroundColor(this.colors.chipBg)
              .controlFeedback()
              .onClick(() => {
                this.gw.interrupt(this.sessionId);
                void this.player.stop();
                this.finishWaiting();
              })
          }.padding({ left: 16, right: 16, top: 8, bottom: 8 }).width('100%')
            .transition(AppMotion.reveal(this.reduceMotion))
        }

        if (this.timeline().pendingClarify) {
          Column() {
            Text(this.clarifyQuestion())
              .fontSize(14)
              .fontColor(this.colors.text)
              .padding({ bottom: 8 })
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.clarifyChoices(), (choice: string) => {
                Text(choice)
                  .fontSize(14)
                  .fontColor(this.colors.onAccent)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .backgroundColor(this.colors.accent)
                  .borderRadius(16)
                  .transition(AppMotion.reveal(this.reduceMotion))
                  .margin({ right: 8, bottom: 6 })
                  .controlFeedback()
                  .onClick(() => {
                    this.submitClarify(choice);
                  })
              })
            }
            Row({ space: 8 }) {
              TextInput({ text: this.clarifyDraft, placeholder: '输入回答' })
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .fontColor(this.colors.text)
                .placeholderColor(this.colors.placeholder)
                .backgroundColor(this.colors.bgInput)
                .borderRadius(16)
                .padding({ left: 10, right: 10 })
                .inputFeedback()
                .onChange((value: string) => { this.clarifyDraft = value; })
                .onSubmit(() => { this.submitClarify(this.clarifyDraft); })
              if (this.clarifyDraft.trim().length > 0) {
                Text('发送')
                  .height(42)
                  .padding({ left: 12, right: 12 })
                  .fontSize(14)
                  .fontColor(this.colors.onAccent)
                  .backgroundColor(this.colors.accent)
                  .borderRadius(16)
                  .controlFeedback()
                  .onClick(() => { this.submitClarify(this.clarifyDraft); })
              }
            }
            .width('100%')
          }
          .padding({ left: 16, right: 16, bottom: 8, top: 8 })
          .width('100%')
          .backgroundColor(this.colors.bgComposer)
          .transition(AppMotion.reveal(this.reduceMotion))
        }

        Column() {
          this.ComposerBar()
        }
        .padding({
          left: 10,
          right: 10,
          top: 8,
          bottom: this.wide ? 16 : 12
        })
        .width('100%')
        .backgroundColor(this.colors.bgComposer)
      }
      .width('100%')
      .height('100%')

      if (this.recording) {
        Column({ space: 14 }) {
          WaveTiny(true, this.colors)
          Text(this.cancelGesture ? '松开取消发送' : `正在聆听 · ${this.elapsed}s`)
            .fontSize(14)
            .fontColor(this.colors.textSecondary)
        }
        .padding({ left: 28, right: 28, top: 22, bottom: 22 })
        .borderRadius(16)
        .backgroundColor(this.colors.overlay)
        .hitTestBehavior(HitTestMode.None)
        .transition(AppMotion.modal(this.reduceMotion))
      }

      if (this.timeline().pendingApproval) {
        Column() {
          Column() {
            Text('需要批准')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors.text)
              .width('100%')
            Text(this.approvalCommand())
              .fontSize(13)
              .fontColor(this.colors.textSecondary)
              .padding({ top: 10, bottom: 12 })
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
              ForEach(this.approvalChoices(), (choice: string) => {
                Text(choice === 'deny' ? '拒绝' : (choice === 'once' ? '允许一次' : choice))
                  .fontSize(14)
                  .fontColor(choice === 'deny' ? this.colors.text : this.colors.onAccent)
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .backgroundColor(choice === 'deny' ? this.colors.chipBg : this.colors.accent)
                  .borderRadius(16)
                  .margin({ left: 8, top: 4 })
                  .controlFeedback()
                  .onClick(() => {
                    this.gw.approve(
                      this.sessionId, this.approvalRequestId(), choice, this.approvalServerRequestId()
                    );
                    this.timeline().pendingApproval = null;
                    this.gw.publishUi();
                  })
              })
            }
            .width('100%')
          }
          .constraintSize({ maxWidth: approvalCardMaxWidthVp() })
          .width('90%')
          .padding(20)
          .borderRadius(16)
          .backgroundColor(this.colors.card)
          .transition(AppMotion.modal(this.reduceMotion))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
        .transition(AppMotion.fade(this.reduceMotion))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors.bgChat)
    .onAreaChange((oldArea: Area, area: Area) => {
      this.wide = isWidePhone();
      if (oldArea.height > area.height) {
        this.followBottom = true;
      }
      if (oldArea.height !== area.height && this.followBottom) {
        this.scrollToLatest();
      }
    })
  }
}
