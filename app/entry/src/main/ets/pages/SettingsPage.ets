/** Connection setup and everyday preferences. Credentials stay in secure storage. */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppPrefs } from '../service/AppPrefs';
import { scanBarcode } from '@kit.ScanKit';
import { Secrets, DEFAULT_GATEWAY_URL, SecretBag, isValidGatewayUrl } from '../service/Secrets';
import { GatewayClient } from '../service/GatewayClient';
import { TaskReplyNotifications } from '../service/TaskReplyNotifications';
import { Theme, ThemePalette } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';

@Entry
@Component
struct SettingsPage {
  @StorageLink('hermes_reduce_motion_preference') reduceMotionPreference: boolean = false;
  @State gatewayUrl: string = DEFAULT_GATEWAY_URL;
  @State pairingLink: string = '';
  @State password: string = '';
  @State cfId: string = '';
  @State cfSecret: string = '';
  @State statusNote: string = '';
  @State busy: boolean = false;
  @State notificationsEnabled: boolean = false;
  @State loaded: boolean = false;
  @State showSecrets: boolean = false;
  @State showAdvanced: boolean = false;
  @StorageLink('hermes_connected') connected: boolean = false;
  @StorageLink('hermes_hermes') hermesOnline: boolean = false;
  @StorageLink('hermes_error') lastError: string = '';
  @StorageLink('hermes_recovering') recovering: boolean = false;
  @StorageLink('hermes_sync_all') syncAll: boolean = false;
  @StorageLink('hermes_auto_voice') autoVoice: boolean = false;
  @StorageLink('hermes_voice_mode') voiceMode: boolean = false;
  @StorageLink('hermes_voice_ready') voiceReady: boolean = false;
  @StorageLink('hermes_voice_reason') voiceReason: string = '连接电脑后，自动检查语音配置。';
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
      normal: { .border({ width: 1, color: this.colors.border }) },
      focused: { .border({ width: 1, color: this.colors.accent }) }
    })
    .animation(AppMotion.press(this.reduceMotion))
  }

  @StorageLink('hermes_theme') @Watch('onThemeChanged') themeMode: string = 'light';
  @StorageLink('hermes_theme_preference') themePreference: string = 'system';
  @State colors: ThemePalette = Theme.palette(Theme.mode);

  onThemeChanged(): void {
    this.getUIContext().animateTo(AppMotion.settle(this.reduceMotion), () => {
      this.colors = Theme.palette(this.themeMode);
    });
  }

  @StorageLink('hermes_safe_top') safeTop: number = 0;

  async aboutToAppear(): Promise<void> {
    this.onThemeChanged();
    GatewayClient.instance.refreshVoice();
    this.notificationsEnabled = await TaskReplyNotifications.isEnabled();
    try {
      const bag = await Secrets.load();
      this.gatewayUrl = bag.gatewayUrl || DEFAULT_GATEWAY_URL;
      this.password = bag.password;
      this.cfId = bag.cfId;
      this.cfSecret = bag.cfSecret;
      this.loaded = true;
    } catch (_) {
      this.statusNote = '无法读取安全存储，请返回后重试。';
    }
  }

  private async enableTaskNotifications(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.notificationsEnabled = await TaskReplyNotifications.requestPermission(context);
    if (!this.notificationsEnabled) {
      this.statusNote = '系统尚未允许通知。可在系统通知设置中为赫默狮开启横幅。';
    }
  }

  private async openTaskNotificationSettings(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.notificationsEnabled = await TaskReplyNotifications.openSystemSettings(context);
  }

  aboutToDisappear(): void {
    this.showSecrets = false;
  }

  private connectionLabel(): string {
    if (this.recovering) { return '正在同步'; }
    return this.connected ? (this.hermesOnline ? 'Hermes 已就绪' : '正在连接 Hermes') : '尚未连接';
  }

  private connectionHint(): string {
    if (this.recovering) { return '正在确认连接并同步对话。'; }
    if (this.connected && this.hermesOnline) {
      return '连接成功。可以新建对话发送文字，语音需要单独完成电脑配置。';
    }
    if (this.connected) {
      return '已连接网关，正在等待助手服务。稍后仍未就绪时，可重新连接。';
    }
    return this.lastError.length > 0 ? this.lastError : '在电脑运行连接器，然后扫码或粘贴配对链接。';
  }

  @Builder
  FieldLabel(title: string, hint: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors.text).width('100%')
      Text(hint).fontSize(12).fontColor(this.colors.textSecondary).lineHeight(18).width('100%')
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 10 })
  }

  @Builder
  StyledInput(value: string, placeholder: string, isSecret: boolean, onUpdate: (v: string) => void) {
    TextInput({ text: value, placeholder: placeholder })
      .height(50)
      .width('100%')
      .fontSize(14)
      .fontColor(this.colors.text)
      .placeholderColor(this.colors.placeholder)
      .backgroundColor(this.colors.bgInput)
      .border({ width: 1, color: this.colors.border })
      .borderRadius(14)
      .padding({ left: 14, right: 14 })
      .type(isSecret && !this.showSecrets ? InputType.Password : InputType.Normal)
      .enabled(this.loaded && !this.busy)
      .accessibilityText(placeholder)
      .inputFeedback()
      .onChange((value: string) => {
        this.statusNote = '';
        onUpdate(value);
      })
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
    Column() {
      Row() {
        Button('‹  返回', { type: ButtonType.Normal })
          .height(48)
          .fontSize(16)
          .fontColor(this.colors.accent)
          .backgroundColor(Color.Transparent)
          .accessibilityText('返回上一页')
          .controlFeedback()
          .onClick(() => router.back())
        Blank()
        Text('设置').fontSize(15).fontColor(this.colors.textSecondary)
      }.width('100%').padding({ left: 8, right: 24, top: 8, bottom: 4 })

      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 8 }) {
            Text('设置')
              .fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.colors.text).width('100%')
            Text('连接电脑，选择适合你的使用方式。')
              .fontSize(14).fontColor(this.colors.textSecondary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 8 })

          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Column().width(8).height(8).borderRadius(4)
                .backgroundColor(this.recovering ? this.colors.textSecondary : (this.connected && this.hermesOnline ? this.colors.online : this.colors.warn))
              Text(this.connectionLabel())
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors.text)
            }.width('100%')
            Text(this.connectionHint())
              .fontSize(13).fontColor(this.colors.textSecondary).lineHeight(21).width('100%')
          }
          .width('100%').padding(18).backgroundColor(this.colors.accentSoft).borderRadius(18)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 20 }) {
            Column({ space: 8 }) {
              Text('连接电脑').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors.text).width('100%')
              Text('先在电脑安装配套连接器，再扫描它显示的二维码，或粘贴完整配对链接。')
                .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
              Button('安装与语音配置说明  ›', { type: ButtonType.Normal })
                .height(48).width('100%').fontSize(14).fontColor(this.colors.accent)
                .backgroundColor(this.colors.accentSoft).borderRadius(14)
                .controlFeedback()
                .onClick(() => router.pushUrl({ url: 'pages/SetupPage' }))
            }.width('100%')

            this.StyledInput(this.pairingLink, '粘贴电脑显示的配对链接', true, (value: string) => {
              this.pairingLink = value;
            })
            Row({ space: 10 }) {
              Button('扫描二维码', { type: ButtonType.Normal })
                .layoutWeight(1).height(46).fontSize(14)
                .fontColor(this.colors.text).backgroundColor(this.colors.bgInput).borderRadius(14)
                .enabled(this.loaded && !this.busy)
                .controlFeedback()
                .onClick(() => { void this.scanPairing(); })
              Button('配对并连接', { type: ButtonType.Normal })
                .layoutWeight(1).height(46).fontSize(14)
                .fontColor(this.colors.onAccent).backgroundColor(this.colors.accent).borderRadius(14)
                .enabled(this.loaded && !this.busy)
                .controlFeedback()
                .onClick(() => { void this.applyPairing(this.pairingLink); })
            }.width('100%')

            Row() {
              Button(this.showSecrets ? '隐藏密码' : '显示密码', { type: ButtonType.Normal })
                .height(44).fontSize(13).fontColor(this.colors.accent)
                .backgroundColor(Color.Transparent).padding({ left: 0, right: 12 })
                .controlFeedback()
                .onClick(() => this.showSecrets = !this.showSecrets)
              Blank()
              Button(this.showAdvanced ? '收起高级设置' : '高级设置', { type: ButtonType.Normal })
                .height(44).fontSize(13).fontColor(this.colors.textSecondary)
                .backgroundColor(Color.Transparent).padding({ left: 12, right: 0 })
                .controlFeedback()
                .onClick(() => {
                  this.getUIContext().animateTo(AppMotion.layout(this.reduceMotion), () => {
                    this.showAdvanced = !this.showAdvanced;
                  });
                })
            }.width('100%')

            if (this.showAdvanced) {
              Column({ space: 16 }) {
                Text('手动连接旧版网关或自建服务时填写。')
                  .fontSize(12).fontColor(this.colors.textSecondary).lineHeight(19).width('100%')
                Column() {
                  this.FieldLabel('网关地址', '填写电脑连接器显示的地址。')
                  this.StyledInput(this.gatewayUrl, 'wss://服务器地址/…', false, (value: string) => this.gatewayUrl = value)
                }
                Column() {
                  this.FieldLabel('连接密码', '配对电脑时使用。')
                  this.StyledInput(this.password, '输入连接密码', true, (value: string) => this.password = value)
                }
                Column() {
                  this.FieldLabel('Access Client ID（可选）', '额外访问认证的客户端标识')
                  this.StyledInput(this.cfId, '输入 Client ID', true, (value: string) => this.cfId = value)
                }
                Column() {
                  this.FieldLabel('Access Client Secret（可选）', '与 Client ID 配套使用')
                  this.StyledInput(this.cfSecret, '输入 Client Secret', true, (value: string) => this.cfSecret = value)
                }
              }.width('100%').transition(AppMotion.reveal(this.reduceMotion))
            }

            if (this.showAdvanced) {
            Button(this.busy ? '正在连接…' : (this.loaded ? '保存手动设置并连接' : '正在读取设置…'), { type: ButtonType.Normal })
              .height(52).width('100%').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(this.colors.onAccent).backgroundColor(this.colors.accent).borderRadius(16)
              .enabled(this.loaded && !this.busy)
              .transition(AppMotion.reveal(this.reduceMotion))
              .controlFeedback()
              .onClick(() => { void this.save(); })

            }

            if (this.statusNote.length > 0) {
              Text(this.statusNote)
                .fontSize(13).fontColor(this.colors.warn).lineHeight(21).width('100%')
                .transition(AppMotion.reveal(this.reduceMotion))
            }
          }
          .width('100%').padding(20).borderRadius(24).backgroundColor(this.colors.card)
          .border({ width: 1, color: this.colors.divider })

          Column({ space: 14 }) {
            Text('外观').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors.text).width('100%')
            Row({ space: 8 }) {
              Button('跟随系统', { type: ButtonType.Normal }).layoutWeight(1).height(52).fontSize(13)
                .fontColor(this.themePreference === 'system' ? this.colors.onAccent : this.colors.text)
                .backgroundColor(this.themePreference === 'system' ? this.colors.accent : this.colors.bgInput)
                .borderRadius(16).accessibilityText('外观跟随系统设置')
                .controlFeedback()
                .onClick(() => { void AppPrefs.setTheme(getContext(this) as common.Context, 'system'); })
              Button('☀ 日间', { type: ButtonType.Normal }).layoutWeight(1).height(52).fontSize(13)
                .fontColor(this.themePreference === 'light' ? this.colors.onAccent : this.colors.text)
                .backgroundColor(this.themePreference === 'light' ? this.colors.accent : this.colors.bgInput)
                .borderRadius(16).accessibilityText('固定使用日间模式')
                .controlFeedback()
                .onClick(() => { void AppPrefs.setTheme(getContext(this) as common.Context, 'light'); })
              Button('☾ 夜间', { type: ButtonType.Normal }).layoutWeight(1).height(52).fontSize(13)
                .fontColor(this.themePreference === 'dark' ? this.colors.onAccent : this.colors.text)
                .backgroundColor(this.themePreference === 'dark' ? this.colors.accent : this.colors.bgInput)
                .borderRadius(16).accessibilityText('固定使用夜间模式')
                .controlFeedback()
                .onClick(() => { void AppPrefs.setTheme(getContext(this) as common.Context, 'dark'); })
            }.width('100%')
            Text(this.themePreference === 'system' ? '外观会随系统的日间／夜间设置即时切换。' : '当前为固定模式；选择「跟随系统」可自动切换。')
              .fontSize(12).fontColor(this.colors.textSecondary).width('100%')
            Divider().color(this.colors.divider).margin({ top: 6, bottom: 6 })
            Row({ space: 14 }) {
              Column({ space: 5 }) {
                Text('减少动态效果').fontSize(15).fontColor(this.colors.text).width('100%')
                Text(this.reduceMotion && !this.reduceMotionPreference ? '已跟随系统开启' : '使用简短淡入淡出，减少位移和缩放')
                  .fontSize(12).lineHeight(19).fontColor(this.colors.textSecondary).width('100%')
              }.layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.reduceMotionPreference })
                .selectedColor(this.colors.accent).accessibilityText('减少动态效果')
                .onChange((on: boolean) => {
                  void AppPrefs.setReduceMotion(getContext(this) as common.Context, on);
                })
            }.width('100%')
          }.width('100%').padding(20).borderRadius(24).backgroundColor(this.colors.card)

          Column({ space: 12 }) {
            Row() {
              Text('任务回复通知').fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor(this.colors.text).layoutWeight(1)
              Text(this.notificationsEnabled ? '已允许' : '未开启').fontSize(12)
                .fontColor(this.notificationsEnabled ? this.colors.success : this.colors.textSecondary)
            }.width('100%')
            Text('手机任务运行期间切到后台会保持连接，回复到达后显示横幅。空闲时或应用进程结束后收到电脑端新任务，仍需接入 Push Kit 才能即时推送。')
              .fontSize(13).fontColor(this.colors.textSecondary).lineHeight(21).width('100%')
            Row({ space: 10 }) {
              Button(this.notificationsEnabled ? '通知已开启' : '开启通知', { type: ButtonType.Normal })
                .layoutWeight(1).height(46).fontSize(14)
                .fontColor(this.notificationsEnabled ? this.colors.text : this.colors.onAccent)
                .backgroundColor(this.notificationsEnabled ? this.colors.bgInput : this.colors.accent)
                .borderRadius(14).enabled(!this.notificationsEnabled)
                .controlFeedback()
                .onClick(() => { void this.enableTaskNotifications(); })
              Button('系统通知设置', { type: ButtonType.Normal })
                .layoutWeight(1).height(46).fontSize(14)
                .fontColor(this.colors.accent).backgroundColor(this.colors.accentSoft)
                .borderRadius(14).controlFeedback().onClick(() => { void this.openTaskNotificationSettings(); })
            }.width('100%')
          }.width('100%').padding(20).borderRadius(24).backgroundColor(this.colors.card)

          Column({ space: 12 }) {
            Row() {
              Text('语音').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors.text).layoutWeight(1)
              Text(this.voiceReady ? '电脑已配置' : '待配置').fontSize(12)
                .fontColor(this.voiceReady ? this.colors.success : this.colors.textSecondary)
            }.width('100%')
            Text(this.voiceReason).fontSize(13).fontColor(this.colors.textSecondary).lineHeight(21).width('100%')
            Row({ space: 14 }) {
              Column({ space: 6 }) {
                Text('使用语音输入').fontSize(15).fontColor(this.colors.text).width('100%')
                Text('电脑通过配置检查后，可在对话中按住说话')
                  .fontSize(12).fontColor(this.colors.textSecondary).lineHeight(19).width('100%')
              }.layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.voiceMode && this.voiceReady })
                .selectedColor(this.colors.accent).enabled(this.voiceReady)
                .accessibilityText(this.voiceReady ? '启用语音输入' : '查看语音配置')
                .onChange((on: boolean) => { void GatewayClient.instance.setVoiceInputMode(on); })
            }.width('100%').padding({ top: 8, bottom: 12 })
            Divider().color(this.colors.divider)
            Button(this.voiceReady ? '查看语音配置与检查  ›' : '如何在电脑配置语音  ›', { type: ButtonType.Normal })
              .height(48).width('100%').fontSize(14).fontColor(this.colors.accent)
              .backgroundColor(this.colors.accentSoft).borderRadius(14)
              .controlFeedback()
              .onClick(() => router.pushUrl({ url: 'pages/SetupPage' }))
          }.width('100%').padding(20).borderRadius(24).backgroundColor(this.colors.card)

          Column({ space: 4 }) {
            Text('对话偏好').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.colors.text)
              .width('100%').margin({ bottom: 8 })
            Row({ space: 14 }) {
              Column({ space: 6 }) {
                Text('自动播放回复').fontSize(15).fontColor(this.colors.text).width('100%')
                Text('回复完成后读出来，文字始终保留')
                  .fontSize(12).fontColor(this.colors.textSecondary).lineHeight(19).width('100%')
              }.layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.autoVoice && this.voiceReady })
                .enabled(this.voiceReady)
                .selectedColor(this.colors.accent).accessibilityText('回复完成后自动播放语音')
                .onChange((on: boolean) => { void GatewayClient.instance.setAutoVoiceReply(on); })
            }.width('100%').padding({ top: 12, bottom: 16 })
            Divider().color(this.colors.divider)
            Row({ space: 14 }) {
              Column({ space: 6 }) {
                Text('显示全部会话').fontSize(15).fontColor(this.colors.text).width('100%')
                Text('关闭时仅显示这台手机创建的对话')
                  .fontSize(12).fontColor(this.colors.textSecondary).lineHeight(19).width('100%')
              }.layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.syncAll })
                .selectedColor(this.colors.accent).accessibilityText('同步并显示全部 Hermes 会话')
                .onChange((on: boolean) => { void GatewayClient.instance.setSyncAllSessions(on); })
            }.width('100%').padding({ top: 16, bottom: 12 })
          }.width('100%').padding(20).borderRadius(24).backgroundColor(this.colors.card)

        }
        .constraintSize({ maxWidth: 560 }).width('100%')
        .padding({ left: 20, right: 20, bottom: 24 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop })
    .backgroundColor(this.colors.bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private async save(): Promise<void> {
    const url = this.gatewayUrl.trim();
    if (!isValidGatewayUrl(url)) {
      this.statusNote = '网关地址格式有误，请填写有效的 WebSocket 地址。';
      return;
    }
    if (this.password.trim().length === 0) {
      this.statusNote = '请先填写连接密码。';
      return;
    }
    if ((this.cfId.trim().length === 0) !== (this.cfSecret.trim().length === 0)) {
      this.statusNote = '额外访问认证需同时填写 Client ID 和 Client Secret，或同时留空。';
      this.showAdvanced = true;
      return;
    }
    this.busy = true;
    this.statusNote = '正在安全保存连接信息…';
    const bag: SecretBag = {
      gatewayUrl: url, password: this.password.trim(),
      cfId: this.cfId.trim(), cfSecret: this.cfSecret.trim()
    };
    try {
      await Secrets.save(bag);
      this.gatewayUrl = url;
      this.showSecrets = false;
      GatewayClient.instance.disconnect();
      await GatewayClient.instance.connect();
      this.statusNote = '设置已保存。连接状态会在上方实时更新。';
    } catch (_) {
      this.statusNote = '保存或连接失败，请检查连接信息后重试。';
    } finally {
      this.busy = false;
    }
  }

  private async scanPairing(): Promise<void> {
    try {
      const result = await scanBarcode.startScanForResult(getContext(this));
      await this.applyPairing(result.originalValue);
    } catch (_) {
      this.statusNote = '扫码未完成，可粘贴配对链接重试。';
    }
  }

  private async applyPairing(raw: string): Promise<void> {
    const link = raw.trim();
    const match = /^(wss?:\/\/[^\s/?#@]+)\/relay\/phone\/([a-f0-9]{32})\?password=([A-Za-z0-9_-]{32,})$/.exec(link);
    if (!match || !isValidGatewayUrl(`${match[1]}/relay/phone/${match[2]}`)) {
      this.statusNote = '配对链接无效；请复制电脑显示的完整链接。';
      return;
    }
    this.gatewayUrl = `${match[1]}/relay/phone/${match[2]}`;
    this.password = match[3];
    this.pairingLink = '';
    await this.save();
  }
}
