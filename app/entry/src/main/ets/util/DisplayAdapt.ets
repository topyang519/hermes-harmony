/**
 * Pura X View: 2232×1320 physical. Portrait widthVp is often ~400–460 —
 * below a usable master-detail split. Only use split when width ≥ 480vp.
 */
import { display } from '@kit.ArkUI';

const WIDE_WIDTH_VP = 720;
const CONTENT_MAX_WIDTH_VP = 560;
const FORM_MAX_WIDTH_VP = 520;
const APPROVAL_CARD_MAX_VP = 480;

function defaultDisplay(): display.Display {
  return display.getDefaultDisplaySync();
}

export function densityScale(): number {
  const scale = defaultDisplay().densityPixels;
  return scale > 0 ? scale : 1;
}

export function screenWidthVp(): number {
  return defaultDisplay().width / densityScale();
}

export function screenHeightVp(): number {
  return defaultDisplay().height / densityScale();
}

/** Master-detail only when the pane is wide enough to not look broken. */
export function isWidePhone(): boolean {
  return screenWidthVp() >= WIDE_WIDTH_VP;
}

export function contentMaxWidthVp(): number {
  return Math.min(CONTENT_MAX_WIDTH_VP, screenWidthVp());
}

export function formMaxWidthVp(): number {
  return Math.min(FORM_MAX_WIDTH_VP, screenWidthVp() - 32);
}

export function approvalCardMaxWidthVp(): number {
  return Math.min(APPROVAL_CARD_MAX_VP, Math.max(280, screenWidthVp() - 48));
}

export function sidebarWidthVp(): number {
  return Math.round(Math.min(300, Math.max(220, screenWidthVp() * 0.32)));
}

export function bubbleMaxWidthPercent(): string {
  return '88%';
}
