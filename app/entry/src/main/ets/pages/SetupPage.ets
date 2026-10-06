/** A standalone, copyable computer setup guide. Readiness comes from the bridge. */
import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { GatewayClient } from '../service/GatewayClient';
import { Theme, ThemePalette } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';

@Entry
@Component
struct SetupPage {
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
  @StorageLink('hermes_safe_top') safeTop: number = 0;
  @StorageLink('hermes_connected') connected: boolean = false;
  @StorageLink('hermes_hermes') hermesOnline: boolean = false;
  @StorageLink('hermes_voice_ready') voiceReady: boolean = false;
  @StorageLink('hermes_voice_checked') voiceChecked: boolean = false;
  @StorageLink('hermes_voice_stt') sttReady: boolean = false;
  @StorageLink('hermes_voice_tts') ttsReady: boolean = false;
  @StorageLink('hermes_voice_ffmpeg') ffmpegReady: boolean = false;
  @StorageLink('hermes_voice_reason') voiceReason: string = '连接电脑后，自动检查语音配置。';
  @State platform: string = 'macOS';
  @State feedback: string = '';
  @State checking: boolean = false;

  onThemeChanged(): void {
    this.getUIContext().animateTo(AppMotion.settle(this.reduceMotion), () => {
      this.colors = Theme.palette(this.themeMode);
    });
  }
  aboutToAppear(): void {
    this.onThemeChanged();
    void this.recheckVoiceConfiguration();
  }

  private async recheckVoiceConfiguration(): Promise<void> {
    if (this.checking) { return; }
    this.checking = true;
    this.feedback = '正在向电脑请求语音配置状态…';
    const result = await GatewayClient.instance.checkVoiceConfiguration();
    this.checking = false;
    if (result === 'ready') {
      this.feedback = '检查完成：语音识别、语音合成和 FFmpeg 均已就绪。';
    } else if (result === 'not_ready') {
      this.feedback = `检查完成：${this.voiceReason}`;
    } else if (result === 'unsupported') {
      this.feedback = '当前电脑连接器不支持此检查，请更新连接器后重新连接。';
    } else if (result === 'hermes_unavailable') {
      this.feedback = '电脑连接器已连接，但 Hermes 服务未就绪。启动电脑端 Hermes 后再试。';
    } else if (result === 'timeout') {
      this.feedback = '电脑未及时返回检查结果。请确认 Hermes 和连接器正在运行，再试一次。';
    } else if (result === 'checking') {
      this.feedback = '已有一次检查正在进行，请稍候查看状态。';
    } else {
      this.feedback = '尚未连接电脑。请先在设置中连接电脑，再重新检查。';
    }
  }

  private installCommand(): string {
    return this.platform === 'Windows' ?
      "& ([scriptblock]::Create((irm https://github.com/topyang519/hermes-harmony/releases/latest/download/install.ps1))) -Relay 'wss://relay.example.com'" :
      'curl -fsSL https://github.com/topyang519/hermes-harmony/releases/latest/download/install.sh | sh -s -- --relay wss://relay.example.com';
  }

  private audioCommand(): string {
    if (this.platform === 'macOS') { return 'brew install ffmpeg\nffmpeg -version'; }
    if (this.platform === 'Windows') { return 'winget install --id Gyan.FFmpeg -e\nffmpeg -version'; }
    return 'sudo apt update\nsudo apt install ffmpeg\nffmpeg -version';
  }

  private async copyCommand(command: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, command));
      this.feedback = '命令已复制。请发送到电脑，在电脑终端中运行。';
      this.getUIContext().getPromptAction().showToast({ message: '已复制命令' });
    } catch (_) { this.feedback = '复制失败，可长按选择命令后复制。'; }
  }

  @Builder
  Command(command: string) {
    Column({ space: 10 }) {
      Row() {
        Text(this.platform === 'Windows' ? '电脑 · PowerShell' : '电脑 · 终端')
          .fontSize(12).fontColor(this.colors.textSecondary).layoutWeight(1)
        Button('复制命令', { type: ButtonType.Normal })
          .height(44).fontSize(13).fontColor(this.colors.accent)
          .backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText('复制命令，在电脑中运行')
          .controlFeedback()
          .onClick(() => { void this.copyCommand(command); })
      }.width('100%')
      ForEach([command], (value: string) => {
        Text(value).fontSize(13).fontFamily('monospace').lineHeight(22)
          .fontColor(this.colors.text).width('100%')
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          .transition(AppMotion.message(this.reduceMotion))
      }, (value: string) => value)
    }.padding(16).width('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor(this.colors.bgInput).borderRadius(16)
  }

  @Builder
  StepHeader(number: string, title: string, subtitle: string) {
    Row({ space: 12 }) {
      Text(number).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.colors.accent)
        .width(34).height(34).textAlign(TextAlign.Center)
        .backgroundColor(this.colors.accentSoft).borderRadius(12)
      Column({ space: 5 }) {
        Text(title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors.text).width('100%')
        Text(subtitle).fontSize(13).fontColor(this.colors.textSecondary).lineHeight(20).width('100%')
      }.layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  Check(label: string, ready: boolean, checked: boolean) {
    Row() {
      Text(label).fontSize(14).fontColor(this.colors.text).layoutWeight(1)
      Text(ready ? '已就绪' : (checked ? '未就绪' : '待检查')).fontSize(12)
        .fontColor(ready ? this.colors.success : this.colors.textSecondary)
    }.width('100%').padding({ top: 12, bottom: 12 })
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
        Button('‹ 返回', { type: ButtonType.Normal }).height(48).fontSize(16)
          .fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .controlFeedback()
          .onClick(() => router.back())
        Blank()
        Text('安装与语音指南').fontSize(14).fontColor(this.colors.textSecondary)
      }.width('100%').padding({ left: 8, right: 20, top: 6, bottom: 6 })
      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 10 }) {
            Text('从电脑开始，\n在手机接着聊。').fontSize(32).fontWeight(FontWeight.Bold)
              .fontColor(this.colors.text).lineHeight(41).width('100%')
            Text('电脑端运行 Hermes Agent 和赫默狮连接器，手机即可发送任务并查看结果。')
              .fontSize(15).lineHeight(24).fontColor(this.colors.textSecondary).width('100%')
            Text('以下命令在电脑终端运行。').fontSize(13)
              .fontColor(this.colors.accent).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 12 })

          Row({ space: 6 }) {
            ForEach(['macOS', 'Linux', 'Windows'], (name: string) => {
              Button(name, { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(14)
                .fontColor(this.platform === name ? this.colors.onAccent : this.colors.textSecondary)
                .backgroundColor(this.platform === name ? this.colors.accent : this.colors.bgInput)
                .borderRadius(12).controlFeedback().onClick(() => { this.platform = name; this.feedback = ''; })
            }, (name: string) => name)
          }.width('100%')

          Column({ space: 16 }) {
            this.StepHeader('1', '准备电脑', '先确认基础环境，再安装连接器')
            Text('需要 Python 3.11+，并在电脑上安装和配置 Hermes Agent。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Text('尚未安装 Hermes Agent 时，可使用官方安装命令：').fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
            this.Command(this.platform === 'Windows' ? 'iex (irm https://hermes-agent.nousresearch.com/install.ps1)' : 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash')
            Text('安装后按提示配置模型，在电脑确认 Hermes 可以正常对话。').fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
            this.Command(this.platform === 'Windows' ? 'py -3 --version\nhermes --version' : 'python3 --version\nhermes --version')
            Text('确认 Python 和 Hermes 均已安装后，继续下一步。')
              .fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
          }.padding(20).width('100%').backgroundColor(this.colors.card).borderRadius(24)

          Column({ space: 16 }) {
            this.StepHeader('2', '安装电脑连接器', '复制命令到电脑终端，按 Enter 运行')
            this.Command(this.installCommand())
            Text('首次安装时，请把命令中的 relay.example.com 替换成你部署的中继服务器地址（wss://）。已有连接器配置的电脑会沿用原来的中继地址。连接器安装脚本和固定版本安装包从 GitHub Releases 下载。')
              .fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
            Text('电脑显示二维码和配对链接后即可配对。macOS / Linux 会安装登录启动服务；Windows 需保持连接器终端运行。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Text('电脑端 Hermes 和连接器已安装的，无需重复安装；继续配对或重新检查即可。')
              .fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
            Text('语音功能需要连接器 0.3.8 或更新版本。')
              .fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
          }.padding(20).width('100%').backgroundColor(this.colors.card).borderRadius(24)

          Column({ space: 16 }) {
            this.StepHeader('3', '在手机完成配对', '电脑和手机可以使用不同网络')
            Text('打开「设置 → 连接电脑」，扫描二维码或粘贴配对链接，点击「配对并连接」。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Button('去连接电脑', { type: ButtonType.Normal }).height(48).width('100%').fontSize(15)
              .fontColor(this.colors.onAccent).backgroundColor(this.colors.accent).borderRadius(14)
              .controlFeedback()
              .onClick(() => router.replaceUrl({ url: 'pages/SettingsPage' }))
          }.padding(20).width('100%').backgroundColor(this.colors.card).borderRadius(24)

          Column({ space: 16 }) {
            this.StepHeader('4', '配置语音（可选）', '文字聊天无需配置这一项')
            Text('配置电脑语音识别（STT）、语音合成（TTS）和 FFmpeg。电脑检查通过后，即可启用语音对话。')
              .fontSize(15).lineHeight(24).fontWeight(FontWeight.Medium).fontColor(this.colors.text).width('100%')
            Text('① 安装 FFmpeg').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors.text).width('100%')
            this.Command(this.audioCommand())
            Text(this.platform === 'macOS' ? '此命令需要已安装 Homebrew。看到 FFmpeg 版本号即完成。' :
              (this.platform === 'Windows' ? '安装后重新打开 PowerShell，让 PATH 生效，再检查版本号。' : '上面适用于 Ubuntu / Debian；其他发行版请用系统包管理器安装 FFmpeg。'))
              .fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
            Text('② 配置识别和朗读').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors.text).width('100%')
            this.Command('hermes tools')
            Text('在电脑的工具配置界面中启用 Speech-to-Text 和 Text-to-Speech。已有配置时，选择「Reconfigure an existing tool’s provider or API key」检查各自的提供方。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Text('内置方式：识别可选 Local Whisper 并安装依赖和模型，或配置云服务；朗读可选 Microsoft Edge TTS，或配置云服务。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Text('已安装自定义命令或插件语音（例如 Qwen 脚本）：保留当前选中的提供方，无需改成内置方式。确认识别和朗读都已启用、脚本对运行 Hermes 的电脑用户可访问，并且脚本所需依赖和凭据已配置。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Text('③ 保存并重启电脑服务').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors.text).width('100%')
            Text('退出配置菜单保存。重启正在运行的 Hermes 服务（桌面版关闭后重新打开；终端版停止后用原来的启动命令重新运行）。若刚安装 FFmpeg，也重启连接器。然后回到本页，点击下方「重新检查」。')
              .fontSize(14).lineHeight(23).fontColor(this.colors.textSecondary).width('100%')
            Text('首次在手机录音时，请允许麦克风权限。')
              .fontSize(13).lineHeight(21).fontColor(this.colors.textSecondary).width('100%')
          }.padding(20).width('100%').backgroundColor(this.colors.card).borderRadius(24)

          Column({ space: 10 }) {
            Text(this.voiceReady ? '语音已就绪' : '电脑语音配置').fontSize(21).fontWeight(FontWeight.Bold)
              .fontColor(this.colors.text).width('100%')
            Text(this.voiceReason).fontSize(14).lineHeight(22).fontColor(this.colors.textSecondary).width('100%')
            Text('检查当前 Hermes 配置中的 STT、TTS 提供方，并确认 FFmpeg 可用；自定义 command 提供方也会识别。检查不会运行脚本或访问语音服务，实际使用前请发起一次语音对话确认。')
              .fontSize(12).lineHeight(19).fontColor(this.colors.textMuted).width('100%')
            this.Check('电脑连接', this.connected && this.hermesOnline, this.connected)
            Divider().color(this.colors.divider)
            this.Check('语音识别 STT', this.sttReady, this.voiceChecked)
            Divider().color(this.colors.divider)
            this.Check('语音合成 TTS', this.ttsReady, this.voiceChecked)
            Divider().color(this.colors.divider)
            this.Check('FFmpeg 音频依赖', this.ffmpegReady, this.voiceChecked)
            Button(this.checking ? '正在检查电脑配置…' : '重新检查电脑配置', { type: ButtonType.Normal }).height(48).width('100%').fontSize(15)
              .fontColor(this.colors.onAccent).backgroundColor(this.colors.accent).borderRadius(14)
              .enabled(!this.checking)
              .controlFeedback()
              .onClick(() => { void this.recheckVoiceConfiguration(); })
            if (this.checking) {
              LoadingProgress().width(20).height(20).color(this.colors.accent)
                .transition(AppMotion.fade(this.reduceMotion))
            }
            if (this.feedback.length > 0) {
              Text(this.feedback).fontSize(13).lineHeight(21)
                .fontColor(this.checking ? this.colors.textSecondary : this.colors.accent).width('100%')
                .transition(AppMotion.reveal(this.reduceMotion))
            }
          }.padding(20).width('100%').backgroundColor(this.colors.accentSoft).borderRadius(24)
          Column({ space: 10 }) {
            Text('遇到问题').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors.text).width('100%')
            Text('没有二维码：检查 Python 版本和安装输出。\n一直连接中：确认电脑 Hermes 和连接器正在运行，且电脑没有休眠。\n语音未通过：按检查结果补齐项目；无法检查时更新 Hermes 与连接器，再重连手机。\n不能录音：在手机系统设置中允许赫默狮使用麦克风。')
              .fontSize(14).lineHeight(25).fontColor(this.colors.textSecondary).width('100%')
          }.width('100%').padding({ bottom: 24 })
        }.constraintSize({ maxWidth: 600 }).width('100%')
          .padding({ left: 20, right: 20, bottom: 24 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
    }.width('100%').height('100%').padding({ top: this.safeTop }).backgroundColor(this.colors.bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
