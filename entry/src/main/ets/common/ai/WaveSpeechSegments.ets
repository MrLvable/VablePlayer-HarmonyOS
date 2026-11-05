import { AiSubtitleError } from './AiSubtitleModels';

export interface WaveSpeechSegment {
  startMs: number;
  endMs: number;
  wav: ArrayBuffer;
}

interface PcmWaveInfo {
  sampleRate: number;
  offset: number;
  size: number;
}

/** Bounded PCM energy segmentation, used only when an ASR provider has no timestamp output. */
export class WaveSpeechSegments {
  private static fourcc(view: DataView, offset: number): string {
    return String.fromCharCode(view.getUint8(offset), view.getUint8(offset + 1),
      view.getUint8(offset + 2), view.getUint8(offset + 3));
  }

  private static inspect(wav: ArrayBuffer): PcmWaveInfo {
    const view = new DataView(wav);
    if (view.byteLength < 44 || view.byteLength > 4000000 || WaveSpeechSegments.fourcc(view, 0) !== 'RIFF'
      || WaveSpeechSegments.fourcc(view, 8) !== 'WAVE') {
      throw new AiSubtitleError('audio-format', '识别需要短片段 PCM WAV 音频');
    }
    let rate = 0;
    let dataOffset = -1;
    let dataSize = 0;
    let pcm = false;
    for (let offset = 12; offset + 8 <= view.byteLength;) {
      const type = WaveSpeechSegments.fourcc(view, offset);
      const length = view.getUint32(offset + 4, true);
      if (length > view.byteLength - offset - 8) { throw new AiSubtitleError('audio-format', '音频片段不完整'); }
      if (type === 'fmt ' && length >= 16) {
        pcm = view.getUint16(offset + 8, true) === 1 && view.getUint16(offset + 10, true) === 1
          && view.getUint16(offset + 22, true) === 16;
        rate = view.getUint32(offset + 12, true);
      } else if (type === 'data') { dataOffset = offset + 8; dataSize = length; }
      offset += 8 + length + (length % 2);
    }
    if (!pcm || rate < 8000 || rate > 48000 || dataOffset < 0 || dataSize % 2 !== 0) {
      throw new AiSubtitleError('audio-format', '仅支持单声道 16 位 PCM WAV');
    }
    return { sampleRate: rate, offset: dataOffset, size: dataSize };
  }

  static split(wav: ArrayBuffer): WaveSpeechSegment[] {
    const info = WaveSpeechSegments.inspect(wav);
    const view = new DataView(wav);
    const samples = info.size / 2;
    const frameSamples = Math.max(1, Math.floor(info.sampleRate / 50));
    const levels: number[] = [];
    for (let from = 0; from < samples; from += frameSamples) {
      const to = Math.min(samples, from + frameSamples);
      let energy = 0;
      for (let n = from; n < to; n++) {
        const sample = view.getInt16(info.offset + n * 2, true);
        energy += sample * sample;
      }
      levels.push(Math.sqrt(energy / Math.max(1, to - from)));
    }
    if (levels.length === 0) { return []; }
    const sorted = levels.slice().sort((a: number, b: number) => a - b);
    const floor = sorted[Math.floor(sorted.length * 0.2)];
    const threshold = Math.min(850, Math.max(180, floor * 2));
    const ranges: number[][] = [];
    let begin = -1;
    let lastVoiced = -1;
    for (let i = 0; i < levels.length; i++) {
      if (levels[i] > threshold) { if (begin < 0) { begin = i; } lastVoiced = i; }
      if (begin >= 0 && (i - lastVoiced >= 20 || i - begin >= 290 || i === levels.length - 1)) {
        if (lastVoiced - begin >= 5) {
          ranges.push([Math.max(0, begin - 8), Math.min(levels.length, lastVoiced + 9)]);
        }
        begin = -1; lastVoiced = -1;
      }
    }
    const result: WaveSpeechSegment[] = [];
    let previousTo = 0;
    for (let i = 0; i < ranges.length; i++) {
      // Padding around a forced cut must not submit the same PCM twice.
      const from = Math.max(previousTo, ranges[i][0] * frameSamples);
      const to = Math.min(samples, ranges[i][1] * frameSamples);
      if (to <= from) { continue; }
      result.push({ startMs: Math.round(from / info.sampleRate * 1000),
        endMs: Math.round(to / info.sampleRate * 1000),
        wav: WaveSpeechSegments.slice(wav, info, from, to) });
      previousTo = to;
    }
    return result;
  }

  private static slice(source: ArrayBuffer, info: PcmWaveInfo, from: number, to: number): ArrayBuffer {
    const count = Math.max(0, to - from) * 2;
    const target = new ArrayBuffer(44 + count);
    const bytes = new Uint8Array(target);
    const view = new DataView(target);
    const names: string[] = ['RIFF', 'WAVE', 'fmt ', 'data'];
    const offsets: number[] = [0, 8, 12, 36];
    for (let i = 0; i < names.length; i++) {
      for (let n = 0; n < 4; n++) { bytes[offsets[i] + n] = names[i].charCodeAt(n); }
    }
    view.setUint32(4, count + 36, true); view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, info.sampleRate, true); view.setUint32(28, info.sampleRate * 2, true);
    view.setUint16(32, 2, true); view.setUint16(34, 16, true); view.setUint32(40, count, true);
    bytes.set(new Uint8Array(source, info.offset + from * 2, count), 44);
    return target;
  }
}
