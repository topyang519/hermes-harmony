/**
 * Narrow-phone session route. Wide Index embeds SessionView directly.
 */
import { SessionView } from '../view/SessionView';
import { Theme, ThemePalette } from '../util/Theme';
import { AppMotion } from '../util/AppMotion';

@Entry
@Component
struct SessionPage {
  @State sessionId: string = '';
  @StorageLink('hermes_reduce_motion') reduceMotion: boolean = false;
  @StorageLink('hermes_theme') @Watch('onThemeChanged') themeMode: string = 'light';
  @State colors: ThemePalette = Theme.palette(Theme.mode);

  onThemeChanged(): void {
    this.getUIContext().animateTo(AppMotion.settle(this.reduceMotion), () => {
      this.colors = Theme.palette(this.themeMode);
    });
  }

  @StorageLink('hermes_safe_top') safeTop: number = 0;

  aboutToAppear(): void {
    this.onThemeChanged();
    const params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params && params['sessionId']) {
      this.sessionId = params['sessionId'];
    }
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
      SessionView({ sessionId: this.sessionId })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop })
    .backgroundColor(this.colors.bgChat)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
