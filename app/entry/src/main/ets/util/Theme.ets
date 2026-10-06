/** Semantic colors for native day and night surfaces. */
export interface ThemePalette {
  bg: string;
  bgChat: string;
  bgElevated: string;
  bgInput: string;
  bgComposer: string;
  border: string;
  borderFocus: string;
  text: string;
  textSecondary: string;
  textMuted: string;
  placeholder: string;
  accent: string;
  accentPressed: string;
  accentSoft: string;
  danger: string;
  dangerSoft: string;
  success: string;
  online: string;
  offline: string;
  warn: string;
  chipBg: string;
  card: string;
  bubbleUser: string;
  bubbleAssistant: string;
  divider: string;
  hairline: string;
  overlay: string;
  onAccent: string;
}

const DAY: ThemePalette = {
  bg: '#F2F3F7',
  bgChat: '#FAFAFC',
  bgElevated: '#FFFFFF',
  bgInput: '#EDEEF3',
  bgComposer: '#FFFFFF',
  border: '#D0D4DD',
  borderFocus: '#005FCC',
  text: '#171A21',
  textSecondary: '#555E6C',
  textMuted: '#626D7D',
  placeholder: '#626D7D',
  accent: '#005FCC',
  accentPressed: '#004DA6',
  accentSoft: '#E4EDFF',
  danger: '#B42318',
  dangerSoft: '#FCEBE9',
  success: '#23784E',
  online: '#23784E',
  offline: '#B42318',
  warn: '#8A5200',
  chipBg: '#EDEEF3',
  card: '#FFFFFF',
  bubbleUser: '#E4EDFF',
  bubbleAssistant: '#FFFFFF',
  divider: '#DEE1E8',
  hairline: '#D0D4DD',
  overlay: '#F5FFFFFF',
  onAccent: '#FFFFFF',
};

const NIGHT: ThemePalette = {
  bg: '#101114',
  bgChat: '#16171B',
  bgElevated: '#1C1E23',
  bgInput: '#282B32',
  bgComposer: '#1C1E23',
  border: '#434853',
  borderFocus: '#82B1FF',
  text: '#F4F5F7',
  textSecondary: '#BAC0CB',
  textMuted: '#A0A9B8',
  placeholder: '#A0A9B8',
  accent: '#82B1FF',
  accentPressed: '#AACBFF',
  accentSoft: '#21324C',
  danger: '#FFAAA1',
  dangerSoft: '#432A2C',
  success: '#88D6AD',
  online: '#88D6AD',
  offline: '#FFAAA1',
  warn: '#E8BE78',
  chipBg: '#282B32',
  card: '#1C1E23',
  bubbleUser: '#21324C',
  bubbleAssistant: '#24262C',
  divider: '#33363E',
  hairline: '#434853',
  overlay: '#F51C1E23',
  onAccent: '#10203A',
};

export class Theme {
  static mode: string = 'light';
  static systemMode: string = 'light';
  static onChange: (() => void) | null = null;
  static update(mode: string): void {
    if (Theme.mode !== mode) {
      Theme.mode = mode;
      if (Theme.onChange) { Theme.onChange(); }
    }
  }
  static palette(mode: string): ThemePalette { return mode === 'dark' ? NIGHT : DAY; }
  static get bg(): string { return Theme.palette(Theme.mode).bg; }
  static get bgChat(): string { return Theme.palette(Theme.mode).bgChat; }
  static get bgElevated(): string { return Theme.palette(Theme.mode).bgElevated; }
  static get bgInput(): string { return Theme.palette(Theme.mode).bgInput; }
  static get bgComposer(): string { return Theme.palette(Theme.mode).bgComposer; }
  static get border(): string { return Theme.palette(Theme.mode).border; }
  static get borderFocus(): string { return Theme.palette(Theme.mode).borderFocus; }
  static get text(): string { return Theme.palette(Theme.mode).text; }
  static get textSecondary(): string { return Theme.palette(Theme.mode).textSecondary; }
  static get textMuted(): string { return Theme.palette(Theme.mode).textMuted; }
  static get placeholder(): string { return Theme.palette(Theme.mode).placeholder; }
  static get accent(): string { return Theme.palette(Theme.mode).accent; }
  static get accentPressed(): string { return Theme.palette(Theme.mode).accentPressed; }
  static get accentSoft(): string { return Theme.palette(Theme.mode).accentSoft; }
  static get danger(): string { return Theme.palette(Theme.mode).danger; }
  static get dangerSoft(): string { return Theme.palette(Theme.mode).dangerSoft; }
  static get success(): string { return Theme.palette(Theme.mode).success; }
  static get online(): string { return Theme.palette(Theme.mode).online; }
  static get offline(): string { return Theme.palette(Theme.mode).offline; }
  static get warn(): string { return Theme.palette(Theme.mode).warn; }
  static get chipBg(): string { return Theme.palette(Theme.mode).chipBg; }
  static get card(): string { return Theme.palette(Theme.mode).card; }
  static get bubbleUser(): string { return Theme.palette(Theme.mode).bubbleUser; }
  static get bubbleAssistant(): string { return Theme.palette(Theme.mode).bubbleAssistant; }
  static get divider(): string { return Theme.palette(Theme.mode).divider; }
  static get hairline(): string { return Theme.palette(Theme.mode).hairline; }
  static get overlay(): string { return Theme.palette(Theme.mode).overlay; }
  static get onAccent(): string { return Theme.palette(Theme.mode).onAccent; }
}
