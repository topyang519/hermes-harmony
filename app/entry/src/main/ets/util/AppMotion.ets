/** Shared motion policy. Transforms never delay an action or intercept gestures. */
import { curves } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';

function onSystemReduceMotion(reduced: boolean): void {
  AppMotion.systemReduced = reduced;
  AppMotion.publish();
}

export class AppMotion {
  static manualReduced: boolean = false;
  static systemReduced: boolean = false;
  private static listening: boolean = false;

  static get reduced(): boolean { return AppMotion.manualReduced || AppMotion.systemReduced; }

  static publish(): void {
    AppStorage.setOrCreate('hermes_reduce_motion', AppMotion.reduced);
  }

  static refreshSystemPreference(): void {
    // This system preference is available from API 23. Earlier phones use
    // the app's persisted preference and keep normal motion by default.
    try {
      if (typeof accessibility.isAnimationReduceEnabledSync === 'function') {
        AppMotion.systemReduced = accessibility.isAnimationReduceEnabledSync();
      }
    } catch (_) { /* Older OS versions do not expose this preference. */ }
    AppMotion.publish();
  }

  static start(): void {
    AppMotion.refreshSystemPreference();
    if (AppMotion.listening) { return; }
    try {
      if (typeof accessibility.onAnimationReduceStateChange === 'function') {
        accessibility.onAnimationReduceStateChange(onSystemReduceMotion);
        AppMotion.listening = true;
      }
    } catch (_) { /* Refresh again when the app returns to the foreground. */ }
  }

  static stop(): void {
    if (!AppMotion.listening) { return; }
    try { accessibility.offAnimationReduceStateChange(onSystemReduceMotion); }
    catch (_) { /* Ability shutdown must still finish. */ }
    AppMotion.listening = false;
  }

  static press(reduced: boolean): AnimateParam {
    return { duration: reduced ? 80 : 150,
      curve: reduced ? Curve.EaseOut : curves.springMotion(0.22, 1, 0) };
  }

  static settle(reduced: boolean): AnimateParam {
    return { duration: reduced ? 100 : 220, curve: Curve.EaseInOut };
  }

  static layout(reduced: boolean): AnimateParam {
    return { duration: reduced ? 0 : 220, curve: curves.cubicBezierCurve(0.2, 0, 0.2, 1) };
  }

  static page(type: RouteType, reduced: boolean): PageTransitionOptions {
    return { type: type, duration: reduced ? 120 : 280,
      curve: curves.cubicBezierCurve(0.2, 0, 0.2, 1) };
  }

  static fade(reduced: boolean): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: reduced ? 100 : 160, curve: Curve.EaseOut });
  }

  static reveal(reduced: boolean): TransitionEffect {
    return reduced ? AppMotion.fade(true) : TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 8 }))
      .animation({ duration: 200, curve: curves.springMotion(0.3, 1, 0) });
  }

  static modal(reduced: boolean): TransitionEffect {
    return reduced ? AppMotion.fade(true) : TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
      .combine(TransitionEffect.translate({ y: 12 }))
      .animation({ duration: 240, curve: curves.springMotion(0.34, 1, 0) });
  }

  static message(reduced: boolean): TransitionEffect {
    // Animate insertion once, never each streaming token.
    // No exit animation: streaming text can become a completed message at once.
    const enter = reduced ? AppMotion.fade(true) : TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 6 }))
      .animation({ duration: 180, curve: Curve.EaseOut });
    return TransitionEffect.asymmetric(enter, TransitionEffect.IDENTITY);
  }
}
