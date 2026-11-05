import { AiSubtitleCue, AiSubtitleError } from './AiSubtitleModels';

/** Text subtitle import/export. Timing always comes from the file, never from model-generated guesses. */
export class SubtitleFileCodec {
  static readonly MAX_TEXT_LENGTH: number = 2097152;
  static readonly MAX_CUES: number = 25000;

  static parse(input: string, formatHint: string = ''): AiSubtitleCue[] {
    if (input.length > SubtitleFileCodec.MAX_TEXT_LENGTH) {
      throw new AiSubtitleError('subtitle-size', '字幕文件过大，请选择不超过 2MB 的文本字幕');
    }
    const text = input.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
    const isAss = /\[Events\]/i.test(text) || /\.(ass|ssa)$/i.test(formatHint);
    const cues = isAss ? SubtitleFileCodec.parseAss(text) : SubtitleFileCodec.parseTimedBlocks(text);
    if (cues.length === 0) {
      throw new AiSubtitleError('subtitle-format', '未找到有效时间轴，请选择 SRT、VTT 或 ASS 文本字幕');
    }
    if (cues.length > SubtitleFileCodec.MAX_CUES) {
      throw new AiSubtitleError('subtitle-size', '字幕条数过多，请拆分后导入');
    }
    return cues.sort((a: AiSubtitleCue, b: AiSubtitleCue) => a.startMs - b.startMs || a.endMs - b.endMs);
  }

  private static parseTimedBlocks(text: string): AiSubtitleCue[] {
    const cues: AiSubtitleCue[] = [];
    const blocks = text.split(/\n[\t ]*\n/);
    for (let i = 0; i < blocks.length; i++) {
      const lines = blocks[i].trim().split('\n');
      if (lines.length < 2 || /^(NOTE|STYLE|REGION)(\s|$)/.test(lines[0])) { continue; }
      let timingIndex = -1;
      for (let n = 0; n < Math.min(3, lines.length); n++) {
        if (lines[n].indexOf('-->') >= 0) { timingIndex = n; break; }
      }
      if (timingIndex < 0) { continue; }
      const timing = lines[timingIndex].split('-->');
      if (timing.length !== 2) { continue; }
      const start = SubtitleFileCodec.timestamp(timing[0].trim());
      const end = SubtitleFileCodec.timestamp(timing[1].trim().split(/\s+/)[0]);
      const body = SubtitleFileCodec.cleanText(lines.slice(timingIndex + 1).join('\n'));
      if (SubtitleFileCodec.valid(start, end, body)) {
        cues.push({ id: 'file-' + i.toString(), startMs: start, endMs: end, text: body });
      }
    }
    return cues;
  }

  private static parseAss(text: string): AiSubtitleCue[] {
    const cues: AiSubtitleCue[] = [];
    const lines = text.split('\n');
    let inEvents = false;
    let fields: string[] = ['layer', 'start', 'end', 'style', 'name', 'marginl', 'marginr', 'marginv', 'effect', 'text'];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (/^\[/.test(line)) { inEvents = /^\[Events\]$/i.test(line); continue; }
      if (!inEvents) { continue; }
      if (/^Format:/i.test(line)) {
        fields = line.substring(line.indexOf(':') + 1).split(',').map((value: string) => value.trim().toLowerCase());
        continue;
      }
      if (!/^Dialogue:/i.test(line)) { continue; }
      const textIndex = fields.indexOf('text');
      const startIndex = fields.indexOf('start');
      const endIndex = fields.indexOf('end');
      if (textIndex !== fields.length - 1 || startIndex < 0 || endIndex < 0) { continue; }
      const values = line.substring(line.indexOf(':') + 1).split(',');
      if (values.length < fields.length) { continue; }
      const raw = values.slice(textIndex).join(',');
      // ASS vector drawings are not speech. Never send drawing commands as subtitle text.
      if (/\{[^}]*\\p[1-9]/.test(raw)) { continue; }
      const body = SubtitleFileCodec.cleanText(raw.replace(/\{[^}]*\}/g, '')
        .replace(/\\[Nn]/g, '\n').replace(/\\h/g, ' '));
      const start = SubtitleFileCodec.timestamp(values[startIndex].trim());
      const end = SubtitleFileCodec.timestamp(values[endIndex].trim());
      if (SubtitleFileCodec.valid(start, end, body)) {
        cues.push({ id: 'ass-' + i.toString(), startMs: start, endMs: end, text: body });
      }
    }
    return cues;
  }

  private static cleanText(text: string): string {
    const result = text.replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      .replace(/\u0000/g, '').trim();
    if (result.length > 4096) { throw new AiSubtitleError('subtitle-size', '单条字幕过长，请拆分后导入，原文未截断'); }
    return result;
  }

  private static timestamp(text: string): number {
    if (!/^(\d{1,3}:)?\d{1,2}:\d{2}[,.]\d{1,3}$/.test(text)) { return -1; }
    const parts = text.replace(',', '.').split(':');
    const hours = parts.length === 3 ? Number(parts[0]) : 0;
    const minutes = Number(parts[parts.length - 2]);
    const seconds = Number(parts[parts.length - 1]);
    if (minutes >= 60 || seconds >= 60 || !Number.isFinite(seconds)) { return -1; }
    return Math.round((hours * 3600 + minutes * 60 + seconds) * 1000);
  }

  private static valid(start: number, end: number, body: string): boolean {
    return Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start && body.length > 0;
  }

  static formatTime(ms: number): string {
    const value = Math.max(0, Math.floor(ms));
    return Math.floor(value / 3600000).toString().padStart(2, '0') + ':'
      + Math.floor(value % 3600000 / 60000).toString().padStart(2, '0') + ':'
      + Math.floor(value % 60000 / 1000).toString().padStart(2, '0') + ','
      + (value % 1000).toString().padStart(3, '0');
  }

  static toSrt(cues: AiSubtitleCue[]): string {
    const blocks: string[] = [];
    for (let i = 0; i < cues.length; i++) {
      const cue = cues[i];
      if (!SubtitleFileCodec.valid(cue.startMs, cue.endMs, cue.text)) { continue; }
      blocks.push((blocks.length + 1).toString() + '\n' + SubtitleFileCodec.formatTime(cue.startMs)
        + ' --> ' + SubtitleFileCodec.formatTime(cue.endMs) + '\n' + cue.text.trim());
    }
    return blocks.join('\n\n') + (blocks.length > 0 ? '\n' : '');
  }
}
