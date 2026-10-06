import { ThemePalette } from './Theme';

export interface MarkdownRun {
  text: string;
  color: string;
  fontSize: number;
  bold: boolean;
  italic: boolean;
  mono: boolean;
  strike: boolean;
  link: boolean;
}

interface InlineStyle {
  color: string;
  fontSize: number;
  bold: boolean;
  italic: boolean;
  mono: boolean;
  strike: boolean;
  link: boolean;
}

function pushRun(runs: MarkdownRun[], text: string, style: InlineStyle): void {
  if (text.length === 0) {
    return;
  }
  const previous = runs.length > 0 ? runs[runs.length - 1] : undefined;
  if (previous && previous.color === style.color && previous.fontSize === style.fontSize &&
    previous.bold === style.bold && previous.italic === style.italic && previous.mono === style.mono &&
    previous.strike === style.strike && previous.link === style.link) {
    previous.text += text;
    return;
  }
  runs.push({
    text: text,
    color: style.color,
    fontSize: style.fontSize,
    bold: style.bold,
    italic: style.italic,
    mono: style.mono,
    strike: style.strike,
    link: style.link
  });
}

function changedStyle(base: InlineStyle, bold: boolean, italic: boolean, mono: boolean,
  strike: boolean, link: boolean): InlineStyle {
  return {
    color: base.color,
    fontSize: base.fontSize,
    bold: base.bold || bold,
    italic: base.italic || italic,
    mono: base.mono || mono,
    strike: base.strike || strike,
    link: base.link || link
  };
}

function firstClosing(source: string, token: string, from: number): number {
  return source.indexOf(token, from);
}

function parseInline(source: string, style: InlineStyle, runs: MarkdownRun[]): void {
  let cursor = 0;
  while (cursor < source.length) {
    const rest = source.slice(cursor);
    if (rest.startsWith('![')) {
      const labelEnd = source.indexOf(']', cursor + 2);
      if (labelEnd >= 0 && source.slice(labelEnd, labelEnd + 2) === '](') {
        const urlEnd = source.indexOf(')', labelEnd + 2);
        if (urlEnd >= 0) {
          const alt = source.slice(cursor + 2, labelEnd);
          pushRun(runs, alt.length > 0 ? `图片：${alt}` : '图片', style);
          cursor = urlEnd + 1;
          continue;
        }
      }
    }
    if (rest.startsWith('[')) {
      const labelEnd = source.indexOf(']', cursor + 1);
      if (labelEnd >= 0 && source.slice(labelEnd, labelEnd + 2) === '](') {
        const urlEnd = source.indexOf(')', labelEnd + 2);
        if (urlEnd >= 0) {
          const label = source.slice(cursor + 1, labelEnd);
          pushRun(runs, label, changedStyle(style, false, false, false, false, true));
          cursor = urlEnd + 1;
          continue;
        }
      }
    }

    let marker = '';
    let markerKind = '';
    if (rest.startsWith('**') || rest.startsWith('__')) {
      marker = rest.slice(0, 2);
      markerKind = 'bold';
    } else if (rest.startsWith('~~')) {
      marker = '~~';
      markerKind = 'strike';
    } else if (rest.startsWith('`')) {
      marker = '`';
      markerKind = 'mono';
    } else if (rest.startsWith('*') || rest.startsWith('_')) {
      marker = rest.slice(0, 1);
      markerKind = 'italic';
    }

    if (marker.length > 0) {
      const closeAt = firstClosing(source, marker, cursor + marker.length);
      if (closeAt > cursor + marker.length) {
        const content = source.slice(cursor + marker.length, closeAt);
        if (markerKind === 'mono') {
          pushRun(runs, content, changedStyle(style, false, false, true, false, false));
        } else {
          const nested = changedStyle(style, markerKind === 'bold', markerKind === 'italic', false,
            markerKind === 'strike', false);
          parseInline(content, nested, runs);
        }
        cursor = closeAt + marker.length;
        continue;
      }
    }

    let next = source.length;
    const markers = ['![', '[', '**', '__', '~~', '`', '*', '_'];
    for (let i = 0; i < markers.length; i++) {
      const at = source.indexOf(markers[i], cursor + 1);
      if (at >= 0 && at < next) {
        next = at;
      }
    }
    if (next <= cursor) {
      next = cursor + 1;
    }
    pushRun(runs, source.slice(cursor, next), style);
    cursor = next;
  }
}

function tableCells(line: string): string[] {
  let content = line.trim();
  if (content.startsWith('|')) {
    content = content.slice(1);
  }
  if (content.endsWith('|')) {
    content = content.slice(0, content.length - 1);
  }
  return content.split('|').map((cell: string) => cell.trim());
}

function isTableDivider(line: string): boolean {
  const cells = tableCells(line);
  if (cells.length < 2) {
    return false;
  }
  for (let i = 0; i < cells.length; i++) {
    if (!/^:?-{3,}:?$/.test(cells[i])) {
      return false;
    }
  }
  return true;
}

function baseStyle(colors: ThemePalette): InlineStyle {
  return {
    color: colors.text,
    fontSize: 16,
    bold: false,
    italic: false,
    mono: false,
    strike: false,
    link: false
  };
}

function copyStyle(base: InlineStyle, color: string, fontSize: number, bold: boolean): InlineStyle {
  return {
    color: color,
    fontSize: fontSize,
    bold: base.bold || bold,
    italic: base.italic,
    mono: base.mono,
    strike: base.strike,
    link: base.link
  };
}

/** Convert common Markdown blocks and inline styles to native text runs. */
export function markdownToRuns(source: string, colors: ThemePalette): MarkdownRun[] {
  const sourceLines = source.replace(/\r\n?/g, '\n').split('\n');
  const lines: string[] = [];
  const codeLines: boolean[] = [];
  let inCode = false;
  for (let i = 0; i < sourceLines.length; i++) {
    if (/^ {0,3}(```+|~~~+).*$/.test(sourceLines[i])) {
      inCode = !inCode;
      continue;
    }
    lines.push(sourceLines[i]);
    codeLines.push(inCode);
  }
  const runs: MarkdownRun[] = [];
  const normal = baseStyle(colors);

  for (let i = 0; i < lines.length; i++) {
    if (i > 0) {
      pushRun(runs, '\n', normal);
    }
    const line = lines[i];
    if (line.trim().length === 0) {
      continue;
    }
    if (codeLines[i]) {
      const codeStyle: InlineStyle = {
        color: colors.textSecondary,
        fontSize: 14,
        bold: false,
        italic: false,
        mono: true,
        strike: false,
        link: false
      };
      pushRun(runs, line, codeStyle);
      continue;
    }
    if (/^ {0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
      pushRun(runs, '────────────', copyStyle(normal, colors.border, normal.fontSize, false));
      continue;
    }
    if (i + 1 < lines.length && line.indexOf('|') >= 0 && isTableDivider(lines[i + 1])) {
      const headerStyle: InlineStyle = copyStyle(normal, normal.color, normal.fontSize, true);
      parseInline(tableCells(line).join('  │  '), headerStyle, runs);
      continue;
    }
    if (isTableDivider(line)) {
      continue;
    }
    if (line.indexOf('|') >= 0 && line.trim().startsWith('|')) {
      parseInline(tableCells(line).join('  │  '), normal, runs);
      continue;
    }

    const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
    if (heading) {
      const level = heading[1].length;
      const headingStyle: InlineStyle = copyStyle(normal, normal.color, Math.max(17, 24 - level), true);
      parseInline(heading[2], headingStyle, runs);
      continue;
    }
    const quote = line.match(/^ {0,3}>\s?(.*)$/);
    if (quote) {
      const quoteStyle: InlineStyle = copyStyle(normal, colors.textSecondary, normal.fontSize, false);
      pushRun(runs, '│ ', quoteStyle);
      parseInline(quote[1], quoteStyle, runs);
      continue;
    }
    const unordered = line.match(/^\s*[-*+]\s+(.+)$/);
    if (unordered) {
      pushRun(runs, '• ', normal);
      parseInline(unordered[1], normal, runs);
      continue;
    }
    const ordered = line.match(/^\s*(\d+)[.)]\s+(.+)$/);
    if (ordered) {
      pushRun(runs, `${ordered[1]}. `, normal);
      parseInline(ordered[2], normal, runs);
      continue;
    }
    parseInline(line, normal, runs);
  }
  return runs;
}
