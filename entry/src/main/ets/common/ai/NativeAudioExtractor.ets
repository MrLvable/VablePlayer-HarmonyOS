import * as nativeExtractor from 'libai_audio_extractor.so';
import { AiSourceBridge } from './AiSourceBridge';

export interface AudioExtractionOptions {
  url: string;
  headers: Record<string, string>;
  outputPath: string;
  startMs: number;
  durationMs: number;
  sampleRate: number;
  jobId: string;
  /** FFmpeg stream index, not the mpv UI track ID. */
  audioStreamIndex?: number;
}

export interface ExtractedAudioWindow {
  path: string;
  startMs: number;
  endMs: number;
  sampleRate: number;
  channels: number;
  sourceBytes: number;
  sourceOpenBytes: number;
  sourceProbeBytes: number;
  sourceSeekBytes: number;
  sourceDecodeBytes: number;
}

export interface SubtitleExtractionOptions {
  url: string;
  headers: Record<string, string>;
  startMs: number;
  durationMs: number;
  /** Bounded look-back for overlapping cues; defaults to 5000, maximum 30000. */
  preRollMs?: number;
  jobId: string;
  subtitleStreamIndex?: number;
  subtitleOrdinal?: number;
  preferredLanguage?: string;
}

export interface ExtractedSubtitleCue { startMs: number; endMs: number; text: string; }
export interface ExtractedSubtitleWindow {
  cues: ExtractedSubtitleCue[];
  language: string;
  streamIndex: number;
  sourceBytes: number;
  sourceOpenBytes: number;
  sourceProbeBytes: number;
  sourceSeekBytes: number;
  sourceDecodeBytes: number;
}

interface PendingExtraction {
  cancelled: boolean;
  running: boolean;
  reject: ((error: Error) => void) | null;
  bridge: AiSourceBridge | null;
}

/** One short, independent extraction at a time; the native bridge enforces its own bounds. */
export class NativeAudioExtractor {
  private static queueTail: Promise<void> = Promise.resolve();
  private activeJobs: Map<string, PendingExtraction> = new Map();

  static supportsSource(source: string, isHls: boolean = false): boolean {
    if (isHls || /\.m3u8(?:$|[?#])/i.test(source) || source.length === 0 || source.length > 8192 || /[\u0000\r\n]/.test(source)) { return false; }
    return source.startsWith('/') || (/^fd:\/\/(?:0|[1-9]\d{0,9})$/.test(source) && Number(source.substring(5)) <= 2147483647) || AiSourceBridge.validSource(source);
  }

  static sourceError(source: string, isHls: boolean = false): string {
    if (isHls || /\.m3u8(?:$|[?#])/i.test(source)) { return '当前流暂不支持原声识别，可选择外挂字幕'; }
    return NativeAudioExtractor.supportsSource(source) ? '' : '当前来源暂不支持原声识别，可选择外挂字幕';
  }

  private async source<T>(task: PendingExtraction, address: string, headers: Record<string, string>,
    operation: (address: string, headers: Record<string, string>) => Promise<T>): Promise<T> {
    if (!NativeAudioExtractor.supportsSource(address)) { throw new Error('AI_SOURCE_UNSUPPORTED'); }
    if (!/^https?:\/\//i.test(address) || AiSourceBridge.numericHttp(address)) { return operation(address, headers); }
    const bridge = new AiSourceBridge(); task.bridge = bridge;
    try {
      const local = await bridge.start(address, headers);
      if (task.cancelled) { throw new Error('EXTRACTION_CANCELLED'); }
      return await operation(local, {});
    } catch (error) { throw new Error(bridge.errorCode().length > 0 ? bridge.errorCode() : (error as Error).message); }
    finally { await bridge.close(); if (task.bridge === bridge) { task.bridge = null; } }
  }

  private enqueue<T>(jobId: string, operation: (task: PendingExtraction) => Promise<T>): Promise<T> {
    if (jobId.length === 0 || this.activeJobs.has(jobId)) { return Promise.reject(new Error('EXTRACTION_JOB_ID_IN_USE')); }
    const task: PendingExtraction = { cancelled: false, running: false, reject: null, bridge: null };
    this.activeJobs.set(jobId, task);
    return new Promise<T>((resolve, reject) => {
      task.reject = reject;
      const queued = NativeAudioExtractor.queueTail.then(async (): Promise<void> => {
        try {
          if (task.cancelled) { throw new Error('EXTRACTION_CANCELLED'); }
          task.running = true;
          const value = await operation(task);
          if (task.cancelled) { throw new Error('EXTRACTION_CANCELLED'); }
          resolve(value);
        } catch (e) { reject(e as Error); }
        finally {
          task.running = false;
          task.reject = null;
          if (this.activeJobs.get(jobId) === task) { this.activeJobs.delete(jobId); }
        }
      });
      // Cancel rejects the caller promptly, but this queue waits for the real
      // native Promise to settle before another instance can enter the bridge.
      NativeAudioExtractor.queueTail = queued.then(() => {}, () => {});
    });
  }

  async extractAudio(options: AudioExtractionOptions): Promise<ExtractedAudioWindow> {
    if (options.jobId.length === 0 || this.activeJobs.has(options.jobId)) { throw new Error('EXTRACTION_JOB_ID_IN_USE'); }
    if (!Number.isFinite(options.startMs) || options.startMs < 0 || !Number.isFinite(options.durationMs)
      || options.durationMs < 100 || options.durationMs > 30000 || options.sampleRate !== 16000) {
      throw new Error('INVALID_AUDIO_WINDOW');
    }
    return this.enqueue<ExtractedAudioWindow>(options.jobId, (task: PendingExtraction) => this.source<ExtractedAudioWindow>(task,
      options.url, options.headers, (address: string, headers: Record<string, string>) => {
        const forwarded: AudioExtractionOptions = { url: address, headers: headers, outputPath: options.outputPath,
          startMs: options.startMs, durationMs: options.durationMs, sampleRate: options.sampleRate, jobId: options.jobId };
        if (options.audioStreamIndex !== undefined) { forwarded.audioStreamIndex = options.audioStreamIndex; }
        return nativeExtractor.extractAudio(forwarded);
      }));
  }

  async extractTextSubtitles(options: SubtitleExtractionOptions): Promise<ExtractedSubtitleWindow> {
    if (options.jobId.length === 0 || this.activeJobs.has(options.jobId)) { throw new Error('EXTRACTION_JOB_ID_IN_USE'); }
    if (!Number.isFinite(options.startMs) || options.startMs < 0 || !Number.isFinite(options.durationMs)
      || options.durationMs < 100 || options.durationMs > 30000) { throw new Error('INVALID_SUBTITLE_WINDOW'); }
    if (options.preRollMs !== undefined && (!Number.isInteger(options.preRollMs)
      || options.preRollMs < 0 || options.preRollMs > 30000)) { throw new Error('INVALID_SUBTITLE_PREROLL'); }
    return this.enqueue<ExtractedSubtitleWindow>(options.jobId, (task: PendingExtraction) => this.source<ExtractedSubtitleWindow>(task,
      options.url, options.headers, (address: string, headers: Record<string, string>) => {
        const forwarded: SubtitleExtractionOptions = { url: address, headers: headers, startMs: options.startMs,
          durationMs: options.durationMs, jobId: options.jobId };
        if (options.preRollMs !== undefined) { forwarded.preRollMs = options.preRollMs; }
        if (options.subtitleStreamIndex !== undefined) { forwarded.subtitleStreamIndex = options.subtitleStreamIndex; }
        if (options.subtitleOrdinal !== undefined) { forwarded.subtitleOrdinal = options.subtitleOrdinal; }
        if (options.preferredLanguage !== undefined) { forwarded.preferredLanguage = options.preferredLanguage; }
        return nativeExtractor.extractTextSubtitles(forwarded);
      }));
  }

  cancelExtraction(jobId: string): void {
    const task = this.activeJobs.get(jobId);
    if (task === undefined || task.cancelled) { return; }
    task.cancelled = true;
    if (task.bridge !== null) { task.bridge.close().catch(() => {}); }
    if (task.reject !== null) { task.reject(new Error('EXTRACTION_CANCELLED')); }
    if (task.running) { nativeExtractor.cancelExtraction(jobId); }
    else { this.activeJobs.delete(jobId); }
  }

  cancelAll(): void {
    this.activeJobs.forEach((_task: PendingExtraction, jobId: string) => { this.cancelExtraction(jobId); });
  }
}
