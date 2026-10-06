/** Native home, searchable conversations and adaptive master-detail navigation. */
import { router } from '@kit.ArkUI';
import { GatewayClient } from '../service/GatewayClient';
import { SessionTimeline } from '../service/EventStore';
import { screenWidthVp, sidebarWidthVp } from '../util/DisplayAdapt';
import { SessionView } from '../view/SessionView';
import { Theme, ThemePalette } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';

@Entry
@Component
struct Index {
  private gw: GatewayClient = GatewayClient.instance;
  @StorageLink('hermes_connected') connected: boolean = false;
  @StorageLink('hermes_hermes') hermesOnline: boolean = false;
  @StorageLink('hermes_error') lastError: string = '';
  @StorageLink('hermes_recovering') recovering: boolean = false;
  @StorageLink('hermes_rev') @Watch('onUiRev') uiRev: number = 0;
  @StorageLink('hermes_session_action_notice') sessionActionNotice: string = '';
  @StorageLink('hermes_pending_session') @Watch('onPendingSession') pendingSession: string = '';
  @StorageLink('hermes_sidebar_collapsed') sidebarCollapsed: boolean = false;
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

  @StorageLink('hermes_theme') @Watch('onThemeChanged') themeMode: string = 'light';
  @State colors: ThemePalette = Theme.palette(Theme.mode);

  onThemeChanged(): void {
    this.getUIContext().animateTo(AppMotion.settle(this.reduceMotion), () => {
      this.colors = Theme.palette(this.themeMode);
    });
  }

  onPendingSession(): void { this.consumePendingSession(); }

  @StorageLink('hermes_safe_top') safeTop: number = 0;
  @State wide: boolean = false;
  @State sidebarVp: number = 280;
  @State selectedSessionId: string = '';
  @State openingNewSession: boolean = false;
  @State searchText: string = '';
  @State showArchivedSessions: boolean = false;
  @State actionSessionId: string = '';
  @State deleteConfirmSessionId: string = '';
  @State showSetupReminder: boolean = false;
  @State activeSessionCount: number = 0;
  @State archivedSessionCount: number = 0;

  aboutToAppear(): void {
    this.onThemeChanged();
    this.wide = screenWidthVp() >= 720;
    this.sidebarVp = sidebarWidthVp();
    this.gw.publishUi();
    this.consumePendingSession();
    void this.checkInitialSetupReminder();
  }

  private async checkInitialSetupReminder(): Promise<void> {
    this.showSetupReminder = await this.gw.claimInitialSetupReminder();
  }

  private openSetupGuide(): void {
    this.showSetupReminder = false;
    router.pushUrl({ url: 'pages/SetupPage' });
  }

  onPageShow(): void {
    this.openingNewSession = false;
    this.gw.publishUi();
    this.consumePendingSession();
  }

  onUiRev(): void {
    this.activeSessionCount = this.gw.visibleSessions().length;
    this.archivedSessionCount = this.gw.visibleSessions(true).length;
    if (this.selectedSessionId.length > 0 && this.gw.store.find(this.selectedSessionId) === null) {
      this.selectedSessionId = '';
    }
    this.consumePendingSession();
  }

  private consumePendingSession(): void {
    const pending = this.pendingSession;
    if (pending.length === 0) {
      return;
    }
    this.pendingSession = '';
    if (this.wide) {
      this.selectedSessionId = pending;
      this.gw.setActiveSession(pending);
    } else {
      router.pushUrl({ url: 'pages/SessionPage', params: { sessionId: pending } });
    }
  }

  private connectionColor(): string {
    if (this.recovering) { return this.colors.textSecondary; }
    return this.connected ? (this.hermesOnline ? this.colors.online : this.colors.warn) : this.colors.textSecondary;
  }

  private connectionLabel(): string {
    if (this.recovering) { return '正在同步'; }
    return this.connected ? (this.hermesOnline ? '已连接 · 可以开始' : '服务连接中') : '尚未连接';
  }

  private openSession(item: SessionTimeline): void {
    this.gw.setActiveSession(item.sessionId);
    if (this.wide) {
      this.selectedSessionId = item.sessionId;
    } else {
      router.pushUrl({ url: 'pages/SessionPage', params: { sessionId: item.sessionId } });
    }
  }

  private createSession(): void {
    if (this.openingNewSession) { return; }
    if (this.gw.isReady()) {
      const sessionId = this.gw.newSession('新对话');
      if (!sessionId) { return; }
      this.gw.setActiveSession(sessionId);
      if (this.wide) {
        this.selectedSessionId = sessionId;
      } else {
        this.openingNewSession = true;
        void router.pushUrl({ url: 'pages/SessionPage', params: { sessionId: sessionId } })
          .then(() => { this.openingNewSession = false; }, () => { this.openingNewSession = false; });
      }
    } else {
      router.pushUrl({ url: 'pages/SettingsPage' });
    }
  }

  private listItems(): SessionTimeline[] {
    const revision = this.uiRev;
    const query = this.searchText.trim().toLowerCase();
    return this.gw.visibleSessions(this.showArchivedSessions).filter((item: SessionTimeline) =>
      query.length === 0 || this.sessionTitle(item.sessionId).toLowerCase().includes(query) ||
      this.sessionPreview(item.sessionId).toLowerCase().includes(query));
  }

  private sessionTitle(sessionId: string): string {
    // Keep each row stable while its text follows gateway revisions.
    const revision = this.uiRev;
    return this.gw.store.timeline(sessionId).displayTitle();
  }

  private sessionPreview(sessionId: string): string {
    const revision = this.uiRev;
    return this.gw.store.timeline(sessionId).displayPreview();
  }

  private toggleSessionArchive(item: SessionTimeline): void {
    this.actionSessionId = '';
    this.deleteConfirmSessionId = '';
    this.gw.archiveSession(item.sessionId, !this.showArchivedSessions);
  }

  private requestSessionDelete(item: SessionTimeline): void {
    this.actionSessionId = '';
    this.deleteConfirmSessionId = item.sessionId;
  }

  private confirmSessionDelete(item: SessionTimeline): void {
    this.deleteConfirmSessionId = '';
    this.gw.deleteSession(item.sessionId);
  }

  @Builder
  SmallButton(label: string, hint: string, onTap: () => void) {
    Button(label, { type: ButtonType.Normal })
      .height(44)
      .fontSize(14)
      .fontColor(this.colors.textSecondary)
      .backgroundColor(this.colors.chipBg)
      .borderRadius(14)
      .padding({ left: 12, right: 12 })
      .accessibilityText(hint)
      .controlFeedback()
      .onClick(onTap)
  }

  @Builder
  ConversationRow(item: SessionTimeline) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Text(this.sessionTitle(item.sessionId).slice(0, 1) || '赫')
              .width(42)
              .height(42)
              .fontSize(17)
              .fontColor(this.colors.accent)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.colors.accentSoft)
              .borderRadius(14)
            Column({ space: 6 }) {
              Text(this.sessionTitle(item.sessionId))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.showArchivedSessions ? '已归档会话' : (this.sessionPreview(item.sessionId) || '开始你的第一条消息'))
                .fontSize(13)
                .fontColor(this.colors.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›').fontSize(19).fontColor(this.colors.textMuted)
          }.width('100%')
        }
        .layoutWeight(1)
        .height(70)
        .padding(12)
        .borderRadius(18)
        .backgroundColor(this.gw.store.resolveId(this.selectedSessionId) === item.sessionId ? this.colors.card : Color.Transparent)
        .accessibilityText('打开对话：' + this.sessionTitle(item.sessionId))
        .controlFeedback()
        .onClick(() => this.openSession(item))

        Button(this.actionSessionId === item.sessionId ? '×' : '···', { type: ButtonType.Normal })
          .width(42)
          .height(54)
          .fontSize(17)
          .fontColor(this.colors.textSecondary)
          .backgroundColor(this.colors.chipBg)
          .borderRadius(15)
          .accessibilityText(this.actionSessionId === item.sessionId ? '收起会话操作' : '会话操作')
          .enabled(!this.gw.isDraftSession(item.sessionId))
          .controlFeedback()
          .onClick(() => {
            this.actionSessionId = this.actionSessionId === item.sessionId ? '' : item.sessionId;
            this.deleteConfirmSessionId = '';
          })
      }
      .width('100%')

      if (this.actionSessionId === item.sessionId) {
        Row({ space: 8 }) {
          Button(this.showArchivedSessions ? '恢复归档' : '归档', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .fontColor(this.colors.accent)
            .backgroundColor(this.colors.accentSoft)
            .borderRadius(12)
            .controlFeedback()
            .onClick(() => this.toggleSessionArchive(item))
          Button('删除', { type: ButtonType.Normal })
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .fontColor(this.colors.danger)
            .backgroundColor(this.colors.dangerSoft)
            .borderRadius(12)
            .controlFeedback()
            .onClick(() => this.requestSessionDelete(item))
        }
        .padding({ left: 8, right: 8 })
        .transition(AppMotion.reveal(this.reduceMotion))
      }

      if (this.deleteConfirmSessionId === item.sessionId) {
        Column({ space: 8 }) {
          Text('永久删除“' + this.sessionTitle(item.sessionId) + '”？')
            .fontSize(14)
            .fontColor(this.colors.text)
          Text('删除后无法恢复。')
            .fontSize(12)
            .fontColor(this.colors.textSecondary)
          Row({ space: 8 }) {
            Button('取消', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(38)
              .fontColor(this.colors.textSecondary)
              .backgroundColor(this.colors.chipBg)
              .borderRadius(12)
              .controlFeedback()
              .onClick(() => this.deleteConfirmSessionId = '')
            Button('永久删除', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(38)
              .fontColor(this.colors.onAccent)
              .backgroundColor(this.colors.danger)
              .borderRadius(12)
              .controlFeedback()
              .onClick(() => this.confirmSessionDelete(item))
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.colors.dangerSoft)
        .borderRadius(14)
        .transition(AppMotion.reveal(this.reduceMotion))
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
  }

  @Builder
  NewConversationButton() {
    Button('+  新对话', { type: ButtonType.Normal })
      .height(52)
      .width('100%')
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors.onAccent)
      .backgroundColor(this.colors.accent)
      .borderRadius(16)
      .accessibilityText('新建文字对话')
      .enabled(!this.openingNewSession)
      .controlFeedback()
      .onClick(() => this.createSession())
  }

  @Builder
  CollapsedRail() {
    Column({ space: 12 }) {
      this.SmallButton('›', '展开对话列表', () => {
        void this.gw.setSidebarCollapsed(false);
      })
      this.SmallButton('+', '新建对话', () => this.createSession())
      Blank()
      this.SmallButton('设置', '打开设置', () => {
        router.pushUrl({ url: 'pages/SettingsPage' });
      })
    }
    .width(72)
    .height('100%')
    .padding({ top: 16, bottom: 16 })
    .backgroundColor(this.colors.bgElevated)
    .transition(AppMotion.fade(this.reduceMotion))
  }

  @Builder
  Welcome() {
    Column({ space: 12 }) {
      Text('赫')
        .fontSize(38)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.accent)
        .width(80)
        .height(80)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colors.accentSoft)
        .borderRadius(28)
      Text('让想法继续向前。')
        .fontSize(this.wide ? 24 : 22)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.text)
        .textAlign(TextAlign.Center)
      Text(this.recovering ? '正在同步对话…' : (this.connected && this.hermesOnline ? '新建一段对话，交给你的 Hermes。\n文字回复和任务进展都在这里。' : '先连接电脑上的 Hermes，\n再把想法交给你的随身助手。'))
        .fontSize(14)
        .lineHeight(23)
        .fontColor(this.colors.textSecondary)
        .textAlign(TextAlign.Center)
      if (!this.recovering && (!this.connected || !this.hermesOnline)) {
        Button('连接电脑', { type: ButtonType.Normal })
          .height(48)
          .fontSize(15)
          .fontColor(this.colors.onAccent)
          .backgroundColor(this.colors.accent)
          .borderRadius(16)
          .margin({ top: 8 })
          .controlFeedback()
          .onClick(() => router.pushUrl({ url: 'pages/SettingsPage' }))
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 32, bottom: 32 })
  }

  @Builder
  SessionListPane() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text('赫默狮')
            .fontSize(27)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors.text)
          Text('与电脑上的 Hermes 保持连接')
            .fontSize(12)
            .fontColor(this.colors.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.wide) {
          this.SmallButton('‹', '收起对话列表', () => {
            void this.gw.setSidebarCollapsed(true);
          })
        }
        this.SmallButton('设置', '连接与偏好设置', () => {
          router.pushUrl({ url: 'pages/SettingsPage' });
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 22, bottom: 16 })

      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Column().width(7).height(7).borderRadius(4).backgroundColor(this.connectionColor())
          Text(this.connectionLabel())
            .fontSize(12)
            .fontColor(this.connectionColor())
            .layoutWeight(1)
          Text('›').fontSize(18).fontColor(this.colors.textSecondary)
        }.width('100%')
      }
      .width('100%')
      .height(44)
      .backgroundColor(Color.Transparent)
      .padding({ left: 20, right: 20 })
      .borderRadius(0)
      .accessibilityText(`${this.connectionLabel()}，打开连接设置`)
      .controlFeedback()
      .onClick(() => router.pushUrl({ url: 'pages/SettingsPage' }))

      if (this.gw.visibleSessions().length + this.gw.visibleSessions(true).length > 0) {
        Column() {
          TextInput({ text: this.searchText, placeholder: '搜索对话' })
            .height(46)
            .fontSize(14)
            .fontColor(this.colors.text)
            .placeholderColor(this.colors.placeholder)
            .backgroundColor(this.colors.bgInput)
            .borderRadius(14)
            .accessibilityText('搜索对话标题和最近消息')
            .onChange((value: string) => this.searchText = value)
          Row({ space: 8 }) {
            Button('对话  ' + this.activeSessionCount, { type: ButtonType.Normal })
              .height(38)
              .layoutWeight(1)
              .fontSize(13)
              .fontWeight(!this.showArchivedSessions ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(!this.showArchivedSessions ? this.colors.onAccent : this.colors.textSecondary)
              .backgroundColor(!this.showArchivedSessions ? this.colors.accent : this.colors.chipBg)
              .borderRadius(12)
              .controlFeedback()
              .onClick(() => {
                this.showArchivedSessions = false;
                this.actionSessionId = '';
                this.deleteConfirmSessionId = '';
              })
            Button('归档  ' + this.archivedSessionCount, { type: ButtonType.Normal })
              .height(38)
              .layoutWeight(1)
              .fontSize(13)
              .fontWeight(this.showArchivedSessions ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.showArchivedSessions ? this.colors.onAccent : this.colors.textSecondary)
              .backgroundColor(this.showArchivedSessions ? this.colors.accent : this.colors.chipBg)
              .borderRadius(12)
              .controlFeedback()
              .onClick(() => {
                this.showArchivedSessions = true;
                this.actionSessionId = '';
                this.deleteConfirmSessionId = '';
              })
          }
          .width('100%')
          .margin({ top: 12 })
          if (this.sessionActionNotice.length > 0) {
            Text(this.sessionActionNotice)
              .width('100%')
              .fontSize(12)
              .fontColor(this.colors.textSecondary)
              .margin({ top: 8 })
          }
          Text(this.showArchivedSessions ? '已归档会话' : '最近对话')
            .width('100%')
            .fontSize(12)
            .fontColor(this.colors.textSecondary)
            .margin({ top: 16, bottom: 2 })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 10 })
      }

      if (this.listItems().length === 0) {
        Scroll() {
          Column() {
            if (this.searchText.trim().length > 0) {
              Text('没有匹配的对话')
                .fontSize(17)
                .fontColor(this.colors.text)
              Text('换个关键词，或清空搜索查看全部')
                .fontSize(13)
                .fontColor(this.colors.textSecondary)
                .margin({ top: 10 })
              Button('清空搜索', { type: ButtonType.Normal })
                .height(44)
                .fontColor(this.colors.accent)
                .backgroundColor(this.colors.accentSoft)
                .margin({ top: 16 })
                .controlFeedback()
                .onClick(() => this.searchText = '')
            } else if (this.showArchivedSessions) {
              Text('还没有归档的会话')
                .fontSize(16)
                .fontColor(this.colors.textSecondary)
                .margin({ top: 30 })
            } else {
              this.Welcome()
            }
          }
          .width('100%')
          .padding({ top: 24, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      } else {
        List({ space: 6 }) {
          ForEach(this.listItems(), (item: SessionTimeline) => {
            ListItem() {
              this.ConversationRow(item)
            }
            .transition(AppMotion.message(this.reduceMotion))
          }, (item: SessionTimeline) => item.sessionId + '-' +
            (this.showArchivedSessions ? 'archived' : 'active'))
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 8, right: 8 })
        .edgeEffect(EdgeEffect.Spring)
      }

      Column() {
        this.NewConversationButton()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 20 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DetailPane() {
    Column() {
      if (this.selectedSessionId.length > 0) {
        ForEach([this.selectedSessionId], (sessionId: string) => {
          Column() {
            SessionView({ sessionId: sessionId, embedded: true })
              .width('100%').layoutWeight(1)
          }.width('100%').layoutWeight(1)
            .transition(AppMotion.message(this.reduceMotion))
        }, (sessionId: string) => sessionId)
      } else {
        Blank()
        this.Welcome()
        Column() {
          this.NewConversationButton()
        }.width(240).margin({ top: 12 })
        Blank()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors.bgChat)
  }

  pageTransition() {
    PageTransitionEnter(AppMotion.page(RouteType.Push, this.reduceMotion))
      .translate({ x: this.reduceMotion ? '0%' : '100%' }).opacity(this.reduceMotion ? 0 : 1)
    PageTransitionExit(AppMotion.page(RouteType.Push, this.reduceMotion))
      .translate({ x: this.reduceMotion ? '0%' : '-18%' }).opacity(this.reduceMotion ? 0 : 0.92)
    PageTransitionEnter(AppMotion.page(RouteType.Pop, this.reduceMotion))
      .translate({ x: this.reduceMotion ? '0%' : '-18%' }).opacity(this.reduceMotion ? 0 : 0.92)
    PageTransitionExit(AppMotion.page(RouteType.Pop, this.reduceMotion))
      .translate({ x: this.reduceMotion ? '0%' : '100%' }).opacity(this.reduceMotion ? 0 : 1)
  }

  build() {
    Stack() {
      Column() {
        if (this.wide) {
          Row() {
            Column() {
              if (this.sidebarCollapsed) {
                this.CollapsedRail()
              } else {
                Column() { this.SessionListPane() }
                  .width('100%').height('100%')
                  .transition(AppMotion.fade(this.reduceMotion))
              }
            }.width(this.sidebarCollapsed ? 72 : this.sidebarVp).height('100%')
              .backgroundColor(this.colors.bgElevated)
              .animation(AppMotion.layout(this.reduceMotion))
            Divider().vertical(true).color(this.colors.hairline).strokeWidth(1)
            Column() { this.DetailPane() }.layoutWeight(1).height('100%')
          }.width('100%').height('100%')
        } else {
          this.SessionListPane()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.safeTop })
      .backgroundColor(this.colors.bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_old: Area, area: Area) => {
        const width = Number(area.width);
        this.wide = width >= 720;
        this.sidebarVp = Math.min(320, Math.max(260, width * 0.34));
      })

      if (this.showSetupReminder) {
        Column() {
          Column({ space: 18 }) {
            Column({ space: 10 }) {
              Text('先完成电脑端配置')
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors.text).width('100%')
              Text('安装电脑连接器并完成配对，即可开始使用。语音对话可在电脑配置好语音后启用。')
                .fontSize(15).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start)

            Row({ space: 12 }) {
              Button('稍后', { type: ButtonType.Normal })
                .layoutWeight(1).height(50).fontSize(15)
                .fontColor(this.colors.text).backgroundColor(this.colors.chipBg).borderRadius(15)
                .controlFeedback()
                .onClick(() => { this.showSetupReminder = false; })
              Button('开始配置', { type: ButtonType.Normal })
                .layoutWeight(1).height(50).fontSize(15)
                .fontColor(this.colors.onAccent).backgroundColor(this.colors.accent).borderRadius(15)
                .controlFeedback()
                .onClick(() => this.openSetupGuide())
            }.width('100%')
          }
          .width('100%').padding(24).borderRadius(24).backgroundColor(this.colors.card)
          .transition(AppMotion.modal(this.reduceMotion))
        }
        .width('100%').height('100%').padding({ left: 24, right: 24 })
        .justifyContent(FlexAlign.Center).backgroundColor('#99000000')
        .transition(AppMotion.fade(this.reduceMotion))
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
