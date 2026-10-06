/**
 * Entry ability: attach gateway + match system bars to app chrome.
 */
import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GatewayClient } from '../service/GatewayClient';
import { Player } from '../service/Player';
import { Theme } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';
import { AppPrefs } from '../service/AppPrefs';
import { densityScale } from '../util/DisplayAdapt';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppMotion.start();
    GatewayClient.instance.attachUIAbilityContext(this.context);
    this.forwardNotificationSession(want);
    this.applySystemTheme(this.context.config.colorMode);
    Player.instance.attach();
    AppStorage.setOrCreate('hermes_foreground', true);
  }

  onConfigurationUpdate(config: Configuration): void {
    this.applySystemTheme(config.colorMode);
  }

  private applySystemTheme(mode: ConfigurationConstant.ColorMode | undefined): void {
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      AppPrefs.updateSystemTheme('dark');
    } else if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      AppPrefs.updateSystemTheme('light');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err && err.code) {
        return;
      }
      void this.applySystemBars(windowStage);
    });
  }

  onForeground(): void {
    AppMotion.refreshSystemPreference();
    AppStorage.setOrCreate('hermes_foreground', true);
    void GatewayClient.instance.onForeground();
  }

  onNewWant(want: Want): void {
    this.forwardNotificationSession(want);
  }

  private forwardNotificationSession(want: Want): void {
    const sessionId = want.parameters?.['notification_session_id'];
    if (typeof sessionId === 'string' && sessionId.length > 0) {
      AppStorage.setOrCreate('hermes_pending_session', sessionId);
    }
  }

  onBackground(): void {
    AppStorage.setOrCreate('hermes_foreground', false);
    void Player.instance.stop();
    GatewayClient.instance.onBackground();
  }

  private async applySystemBars(windowStage: window.WindowStage): Promise<void> {
    try {
      const win = await windowStage.getMainWindow();
      this.mainWindow = win;
      Theme.onChange = () => { void this.refreshSystemBars(); };
      // The phone's short screen timeout otherwise backgrounds the ability and
      // suspends its WebSocket in the middle of a Hermes turn. Keep the screen
      // awake while this window is visible; HarmonyOS releases the hold when
      // the app leaves the foreground.
      await win.setWindowKeepScreenOn(true);
      // Resize the page around the keyboard so the header and composer remain
      // anchored while the message list uses the reduced space between them.
      win.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      // Let the root page paint behind status and gesture areas. ArkUI page
      // roots paint the background there; top padding keeps content below status.
      await win.setWindowLayoutFullScreen(true);
      const systemArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const safeTopVp = Math.ceil(systemArea.topRect.height / densityScale());
      AppStorage.setOrCreate('hermes_safe_top', safeTopVp);
      const props: window.SystemBarProperties = {
        statusBarColor: Theme.bg,
        navigationBarColor: Theme.bg,
        statusBarContentColor: Theme.text,
        navigationBarContentColor: Theme.text
      };
      await win.setWindowSystemBarProperties(props);
    } catch (_e) {
      // Older devices / preview: ignore
    }
  }

  private async refreshSystemBars(): Promise<void> {
    try {
      if (this.mainWindow) {
        await this.mainWindow.setWindowSystemBarProperties({
          statusBarColor: Theme.bg, navigationBarColor: Theme.bg,
          statusBarContentColor: Theme.text, navigationBarContentColor: Theme.text
        });
      }
    } catch (_) { /* Preview windows may not support system bars. */ }
  }

  onDestroy(): void {
    AppMotion.stop();
  }

  onWindowStageDestroy(): void {
    Theme.onChange = null;
    this.mainWindow = null;
  }
}
