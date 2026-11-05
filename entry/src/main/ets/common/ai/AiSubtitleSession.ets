import { fileIo as fs } from '@kit.CoreFileKit';
import { AiSubtitleConfigStore } from './AiSubtitleConfigStore';
import { AiSubtitleConfig, AiSubtitleCue, AiRuntimeEndpoint, AiSubtitleError } from './AiSubtitleModels';
import { OpenAiSubtitleClient } from './OpenAiSubtitleClient';
import { NativeAudioExtractor } from './NativeAudioExtractor';
import { WaveSpeechSegments } from './WaveSpeechSegments';
import { hilog } from '@kit.PerformanceAnalysisKit';

interface SubtitleReadFailure { code: string; message: string; }

export interface AiPlaybackInput {
  url: string;
  headers: Record<string, string>;
  durationMs: number;
  cacheDir: string;
  /** Subtitle ordinal among demuxed subtitle streams, never a UI track index. -1 selects the first text track. */
  subtitleOrdinal: number;
  /** Real demux stream index read from the player; -1 means unknown. */
  subtitleStreamIndex: number;
  preferredLanguage: string;
  audioStreamIndex: number;
  /** auto prefers existing timed text; speech explicitly recognizes the selected movie audio. */
  mode: string;
  translate: boolean;
  /** Already selected user-authorized external text, with its original absolute movie timeline. */
  timedCues?: AiSubtitleCue[];
}

export interface AiDisplayCue {
  id: string;
  startMs: number;
  endMs: number;
  originalText: string;
  translatedText: string;
}

export interface AiSubtitleSessionEvents {
  onCaption: (original: string, translated: string) => void;
  onStatus: (message: string) => void;
  onError: (message: string) => void;
  /** One-time service setup, distinct from retryable playback/network failures. */
  onConfigurationRequired?: (message: string, purpose: string) => void;
}

/** A bounded on-demand subtitle pipeline. Seeking cancels stale network/decoder work independently of video playback. */
export class AiSubtitleSession {
  private static readonly WINDOW_MS: number = 12000;
  private source: AiPlaybackInput;
  private events: AiSubtitleSessionEvents;
  private config: AiSubtitleConfig = new AiSubtitleConfig();
  private translationEndpoint: AiRuntimeEndpoint | null = null;
  private extractor: NativeAudioExtractor = new NativeAudioExtractor();
  private translationClient: OpenAiSubtitleClient | null = null;
  private asrClient: OpenAiSubtitleClient | null = null;
  private revision: number = 0;
  private active: boolean = false;
  private ready: boolean = false;
  private seekSuspended: boolean = false;
  private blocked: boolean = false;
  private busy: boolean = false;
  private playing: boolean = false;
  private positionMs: number = 0;
  private windows: Map<number, AiDisplayCue[]> = new Map();
  private displayId: string = '';
  private speechFallback: boolean = false;
  private taskSequence: number = 0;
  private fileCues: AiSubtitleCue[] | null = null;

  constructor(source: AiPlaybackInput, events: AiSubtitleSessionEvents) {
    this.source = source; this.events = events;
    this.speechFallback = source.mode === 'speech';
    if (source.timedCues !== undefined) {
      this.fileCues = source.timedCues.map((cue: AiSubtitleCue): AiSubtitleCue => ({ id: cue.id,
        startMs: cue.startMs, endMs: cue.endMs, text: cue.text }));
    }
  }

  async start(positionMs: number): Promise<void> {
    this.cancelPending();
    const gen = ++this.revision;
    this.active = true; this.ready = false; this.seekSuspended = false; this.blocked = false;
    this.positionMs = Number.isFinite(positionMs) ? Math.max(0, positionMs) : 0;
    this.windows.clear(); this.displayId = ''; this.speechFallback = this.source.mode === 'speech';
    this.events.onCaption('', '');
    try {
      if (!Number.isFinite(this.source.durationMs) || this.source.durationMs <= 0) {
        throw new AiSubtitleError('input', '视频时长尚未就绪，请稍后启用 AI 字幕');
      }
      if (this.fileCues !== null && (this.fileCues.length > 25000 || this.fileCues.some((cue: AiSubtitleCue) =>
        cue.id.length === 0 || !Number.isFinite(cue.startMs) || !Number.isFinite(cue.endMs) || cue.startMs < 0
        || cue.endMs <= cue.startMs || typeof cue.text !== 'string')
        || this.fileCues.reduce((size: number, cue: AiSubtitleCue) => size + cue.text.length, 0) > 2097152)) {
        throw new AiSubtitleError('subtitle-file', '外挂字幕时间轴或大小无效，请重新选择字幕文件');
      }
      this.config = await AiSubtitleConfigStore.load();
      if (!this.current(gen)) { return; }
      if (this.source.translate) {
        this.translationEndpoint = await AiSubtitleConfigStore.translationEndpoint();
        if (!this.current(gen)) { return; }
        // Validate configuration before opening any NAS connection.
        this.translationClient = new OpenAiSubtitleClient(this.translationEndpoint);
      }
      const path = this.source.cacheDir + '/ai-subtitle-audio';
      try { if (!fs.accessSync(path)) { fs.mkdirSync(path, true); } }
      catch (e) { throw new AiSubtitleError('cache', '无法创建字幕音频临时目录'); }
      this.ready = true;
      this.events.onStatus(this.speechFallback ? '正在生成语音字幕…' : '正在读取字幕时间轴…');
      this.pump();
    } catch (e) {
      if (!this.current(gen)) { return; }
      this.active = false; this.ready = false; this.cancelPending();
      const error = e instanceof AiSubtitleError ? new AiSubtitleError(e.kind, e.message, e.status)
        : new AiSubtitleError('start', '无法读取 AI 字幕配置');
      this.requestConfiguration(error); throw error;
    }
  }

  tick(positionMs: number, playing: boolean): void {
    if (!this.active) { return; }
    if (!Number.isFinite(positionMs)) { return; }
    this.positionMs = Math.max(0, positionMs); this.playing = playing;
    if (!this.seekSuspended) { this.publish(); }
    this.pump();
  }

  /** Cancel the old timeline immediately; wait for the player's actual seek completion before resuming. */
  suspendForSeek(): void {
    if (!this.active) { return; }
    this.seekSuspended = true;
    if (this.ready) { this.revision++; }
    this.cancelPending(); this.displayId = '';
    this.events.onCaption('', '');
  }

  seek(positionMs: number): void {
    if (!this.active || !Number.isFinite(positionMs)) { return; }
    this.positionMs = Math.max(0, positionMs); this.blocked = false; this.seekSuspended = false;
    // Configuration reads have no timeline-specific result. Keep them alive so an
    // early seek cannot strand initialization with ready=false forever.
    if (this.ready) { this.revision++; this.cancelPending(); }
    this.displayId = '';
    this.events.onCaption('', '');
    this.publish();
    this.pump();
  }

  retry(): void {
    if (!this.active) { return; }
    this.blocked = false; this.events.onStatus('正在重试 AI 字幕…'); this.pump();
  }

  cancel(): void {
    this.active = false; this.ready = false; this.seekSuspended = false; this.revision++; this.cancelPending();
    this.windows.clear(); this.displayId = '';
    this.translationEndpoint = null; this.translationClient = null; this.asrClient = null;
    this.events.onCaption('', '');
  }

  private cancelPending(): void {
    this.extractor.cancelAll(); this.translationClient?.cancel(); this.asrClient?.cancel();
  }

  private current(gen: number): boolean { return this.active && gen === this.revision; }

  private check(gen: number): void {
    if (!this.current(gen)) { throw new AiSubtitleError('cancelled', '字幕任务已取消'); }
  }

  private requestConfiguration(error: AiSubtitleError): void {
    if ((error.kind === 'config' || error.kind === 'config-asr') && this.events.onConfigurationRequired !== undefined) {
      this.events.onConfigurationRequired(error.message, error.kind === 'config-asr' ? 'asr' : 'translation');
    }
  }

  private nextWindow(): number {
    const current = Math.floor(this.positionMs / AiSubtitleSession.WINDOW_MS);
    const ahead = this.playing ? 2 : 0;
    for (let n = current; n <= current + ahead; n++) {
      if (n * AiSubtitleSession.WINDOW_MS >= this.source.durationMs) { break; }
      if (this.source.durationMs - n * AiSubtitleSession.WINDOW_MS < 100) { break; }
      if (!this.windows.has(n)) { return n; }
    }
    return -1;
  }

  private async pump(): Promise<void> {
    if (!this.active || !this.ready || this.seekSuspended || this.blocked || this.busy) { return; }
    const index = this.nextWindow();
    if (index < 0) { return; }
    this.busy = true;
    const gen = this.revision;
    try {
      const start = index * AiSubtitleSession.WINDOW_MS;
      const length = Math.min(AiSubtitleSession.WINDOW_MS, this.source.durationMs - start);
      const original = await this.readWindow(start, length, gen);
      this.check(gen);
      if (original.length > 400 || original.reduce((size: number, cue: AiSubtitleCue) => size + cue.text.length, 0) > 131072) {
        throw new AiSubtitleError('subtitle-size', '当前字幕片段过大，已暂停 AI 请求');
      }
      let translated: AiSubtitleCue[] = [];
      if (this.source.translate && original.length > 0) {
        this.events.onStatus('正在翻译字幕…');
        for (let offset = 0; offset < original.length; offset += 10) {
          this.check(gen);
          const client = new OpenAiSubtitleClient(this.translationEndpoint as AiRuntimeEndpoint);
          this.translationClient = client;
          const batch = await client.translateBatch(original.slice(offset, offset + 10), this.config.targetLanguage,
            { previousText: this.previousContext(start), glossary: '' });
          this.check(gen); translated = translated.concat(batch);
          if (original.reduce((size: number, cue: AiSubtitleCue) => size + cue.text.length, 0)
            + translated.reduce((size: number, cue: AiSubtitleCue) => size + cue.text.length, 0) > 131072) {
            throw new AiSubtitleError('subtitle-size', '当前字幕结果过大，已暂停 AI 请求');
          }
        }
      }
      const completed: AiDisplayCue[] = [];
      for (let n = 0; n < original.length; n++) {
        const cue = original[n];
        const target = translated.find((value: AiSubtitleCue) => value.id === cue.id);
        completed.push({ id: index.toString() + ':' + cue.id, startMs: cue.startMs, endMs: cue.endMs,
          originalText: cue.text, translatedText: target !== undefined ? target.text : '' });
      }
      this.windows.set(index, completed);
      this.prune(index); this.publish();
      this.events.onStatus(completed.length === 0
        ? (this.playing ? '本段暂无字幕，继续等待对白…' : '本段暂无字幕，播放后继续读取')
        : (this.source.translate ? 'AI 字幕已就绪' : 'AI 原声字幕已就绪'));
    } catch (e) {
      if (this.current(gen)) {
        this.blocked = true;
        this.events.onStatus('AI 字幕已暂停，可重试');
        this.events.onError(e instanceof AiSubtitleError ? e.message : '字幕生成失败，请检查配置或连接');
        if (e instanceof AiSubtitleError) { this.requestConfiguration(e); }
      }
    } finally {
      this.busy = false;
      if (this.active && !this.blocked) { this.pump(); }
    }
  }

  private async readWindow(start: number, length: number, gen: number): Promise<AiSubtitleCue[]> {
    if (this.fileCues !== null) {
      this.check(gen);
      return this.fileCues.filter((cue: AiSubtitleCue) => cue.endMs > start && cue.startMs < start + length && cue.text.trim().length > 0)
        .map((cue: AiSubtitleCue): AiSubtitleCue => ({ id: cue.id, startMs: cue.startMs, endMs: cue.endMs, text: cue.text }));
    }
    if (!this.speechFallback) {
      this.events.onStatus('正在读取内封字幕…');
      try {
        const result = await this.extractor.extractTextSubtitles({ url: this.source.url, headers: this.source.headers,
          startMs: start, durationMs: length, jobId: this.jobId(), subtitleOrdinal: this.source.subtitleOrdinal,
          subtitleStreamIndex: this.source.subtitleStreamIndex >= 0 ? this.source.subtitleStreamIndex : undefined,
          preferredLanguage: this.source.preferredLanguage });
        this.check(gen);
        const cues: AiSubtitleCue[] = [];
        for (let index = 0; index < result.cues.length; index++) {
          const cue = result.cues[index];
          if (!Number.isFinite(cue.startMs) || !Number.isFinite(cue.endMs) || cue.startMs < 0
            || cue.endMs <= cue.startMs || typeof cue.text !== 'string' || cue.text.length > 4096) {
            throw new AiSubtitleError('subtitle-time', '内封字幕时间轴无效，未生成字幕');
          }
          if (cue.endMs <= start || cue.startMs >= start + length || cue.text.trim().length === 0) { continue; }
          cues.push({ id: 'text-' + Math.round(cue.startMs).toString() + '-' + index.toString(),
            startMs: cue.startMs, endMs: cue.endMs, text: cue.text });
        }
        return cues;
      } catch (e) {
        this.check(gen);
        const error = e as Error;
        // Only an explicit absence/unsupported text track triggers the separately configured ASR path.
        if (!/NO_(TEXT_)?SUBTITLE|SUBTITLE_(TEXT_NOT_FOUND|BITMAP_OR_CODEC_UNSUPPORTED|CODEC_UNSUPPORTED|NOT_FOUND|UNSUPPORTED)|UNSUPPORTED_SUBTITLE/.test(error.message)) {
          const failure = this.subtitleReadFailure(error);
          hilog.warn(0x0001, 'NasAi',
            'text-read failure start=%{public}d length=%{public}d stream=%{public}d ordinal=%{public}d code=%{public}s',
            start, length, this.source.subtitleStreamIndex, this.source.subtitleOrdinal, failure.code);
          throw new AiSubtitleError('extract-text', e instanceof AiSubtitleError ? e.message : failure.message);
        }
        this.speechFallback = true;
      }
    }
    this.events.onStatus('正在识别影片原声…');
    let endpoint: AiRuntimeEndpoint; let validated: OpenAiSubtitleClient;
    try {
      endpoint = await AiSubtitleConfigStore.asrEndpoint();
      validated = new OpenAiSubtitleClient(endpoint);
    } catch (e) {
      if (e instanceof AiSubtitleError && (e.kind === 'config' || e.kind === 'config-asr')) {
        throw new AiSubtitleError('config-asr', e.message, e.status);
      }
      throw new AiSubtitleError(e instanceof AiSubtitleError ? e.kind : 'config-asr',
        e instanceof AiSubtitleError ? e.message : '请先配置支持音频转写的语音识别服务');
    }
    this.check(gen);
    this.asrClient = validated;
    const job = this.jobId();
    const path = this.source.cacheDir + '/ai-subtitle-audio/' + job + '.wav';
    try {
      const audio = await this.extractor.extractAudio({ url: this.source.url, headers: this.source.headers,
        outputPath: path, startMs: start, durationMs: length, sampleRate: 16000, jobId: job,
        audioStreamIndex: this.source.audioStreamIndex >= 0 ? this.source.audioStreamIndex : undefined });
      this.check(gen);
      if (audio.path !== path || !Number.isFinite(audio.startMs) || !Number.isFinite(audio.endMs)
        || audio.startMs < 0 || audio.endMs <= audio.startMs || audio.sampleRate !== 16000 || audio.channels !== 1) {
        throw new AiSubtitleError('audio-format', '音频提取结果无效');
      }
      const stat = fs.statSync(audio.path);
      if (stat.size <= 44 || stat.size > 4000000) { throw new AiSubtitleError('audio-size', '音频片段长度异常'); }
      const input = fs.openSync(audio.path, fs.OpenMode.READ_ONLY);
      let wav = new ArrayBuffer(stat.size);
      try {
        if (fs.readSync(input.fd, wav) !== stat.size) { throw new AiSubtitleError('audio-read', '音频片段读取不完整'); }
      } finally { fs.closeSync(input); }
      const pieces = WaveSpeechSegments.split(wav);
      const cues: AiSubtitleCue[] = [];
      for (let n = 0; n < pieces.length; n++) {
        this.check(gen);
        const piece = pieces[n];
        const client = new OpenAiSubtitleClient(endpoint); this.asrClient = client;
        const result = await client.transcribeWav(piece.wav, this.config.sourceLanguage);
        this.check(gen);
        if (result.timestampsAvailable) {
          for (let i = 0; i < result.cues.length; i++) {
            const local = result.cues[i];
            const from = audio.startMs + piece.startMs + local.startMs;
            const to = Math.min(audio.endMs, audio.startMs + piece.endMs, audio.startMs + piece.startMs + local.endMs);
            if (to > from) { cues.push({ id: 'asr-' + n.toString() + '-' + i.toString(),
              startMs: from, endMs: to, text: local.text }); }
          }
        } else if (result.text.trim().length > 0) {
          // The bounds are measured PCM segment bounds, not invented word timestamps.
          cues.push({ id: 'asr-' + n.toString(), startMs: audio.startMs + piece.startMs,
            endMs: Math.min(audio.endMs, audio.startMs + piece.endMs), text: result.text.trim() });
        }
      }
      wav = new ArrayBuffer(0);
      return cues;
    } finally {
      try { if (fs.accessSync(path)) { fs.unlinkSync(path); } } catch (e) {}
    }
  }

  private jobId(): string {
    return 'subtitle-' + Date.now().toString() + '-' + (++this.taskSequence).toString();
  }

  /** Only fixed codes and the native allowlisted numeric HTTP suffix reach diagnostics. */
  private subtitleReadFailure(error: Error): SubtitleReadFailure {
    const raw = typeof error.message === 'string' ? error.message : '';
    const known = ['AI_SOURCE_AUTHENTICATION_FAILED', 'AI_SOURCE_BRIDGE_UNAVAILABLE',
      'AI_SOURCE_HEADERS_INVALID', 'AI_SOURCE_NETWORK_FAILED', 'AI_SOURCE_RANGE_MISMATCH',
      'AI_SOURCE_RANGE_REQUIRED', 'AI_SOURCE_UNSUPPORTED', 'AUDIO_CODEC_UNSUPPORTED',
      'AUDIO_DECODER_OPEN_FAILED', 'AUDIO_DECODE_FAILED', 'AUDIO_DRAIN_FAILED', 'AUDIO_FORMAT_CHANGED',
      'AUDIO_FRAME_INVALID', 'AUDIO_FRAME_TOO_LARGE', 'AUDIO_LAYOUT_INVALID', 'AUDIO_PACKET_FAILED',
      'AUDIO_PARAMETERS_INVALID', 'AUDIO_RESAMPLE_FAILED', 'AUDIO_TIMELINE_DISCONTINUITY',
      'AUDIO_TIMESTAMPS_UNAVAILABLE', 'CODEC_ALLOCATION_FAILED', 'DECODE_ALLOCATION_FAILED', 'EXTRACTION_BUSY',
      'EXTRACTION_CANCELLED', 'EXTRACTION_FAILED', 'EXTRACTION_JOB_ID_IN_USE', 'EXTRACTION_SCHEDULING_FAILED',
      'EXTRACTION_TIMEOUT', 'FFMPEG_ABI_VERSION_MISMATCH', 'FORMAT_ALLOCATION_FAILED',
      'HTTP_AUTHENTICATION_FAILED', 'HTTP_CHUNKED_RANGE_UNSUPPORTED', 'HTTP_CONNECTION_CLOSED',
      'HTTP_CONNECT_FAILED', 'HTTP_EMPTY_RANGE', 'HTTP_ENCODED_RANGE_UNSUPPORTED', 'HTTP_HEADERS_TOO_LARGE',
      'HTTP_HOSTNAME_UNSUPPORTED_USE_NUMERIC_IP', 'HTTP_INVALID_CONTENT_RANGE', 'HTTP_INVALID_HEADER',
      'HTTP_INVALID_RESPONSE', 'HTTP_POLL_FAILED', 'HTTP_RANGE_LENGTH_MISMATCH', 'HTTP_RANGE_REQUIRED',
      'HTTP_RANGE_START_OUTSIDE_SOURCE', 'HTTP_READ_FAILED', 'HTTP_REDIRECT_REJECTED', 'HTTP_SEND_FAILED',
      'HTTP_SOCKET_FAILED', 'HTTP_TRUNCATED_RANGE', 'INVALID_AUDIO_STREAM_INDEX', 'INVALID_AUDIO_WINDOW',
      'INVALID_HEADERS', 'INVALID_HTTP_HEADER', 'INVALID_NUMBER_OPTION', 'INVALID_OPTIONS',
      'INVALID_PATH_OR_JOB_ID', 'INVALID_SOURCE_AUTHORITY', 'INVALID_SOURCE_FD', 'INVALID_SOURCE_OR_OUTPUT',
      'INVALID_SOURCE_PORT', 'INVALID_SOURCE_URL', 'INVALID_STRING_OPTION', 'INVALID_SUBTITLE_ORDINAL',
      'INVALID_SUBTITLE_PREROLL', 'INVALID_SUBTITLE_STREAM_INDEX', 'INVALID_SUBTITLE_WINDOW',
      'IO_ALLOCATION_FAILED', 'LOCAL_SOURCE_READ_FAILED', 'LOCAL_SOURCE_UNAVAILABLE', 'MEDIA_FORMAT_UNSUPPORTED',
      'MEDIA_READ_FAILED', 'MEDIA_SEEK_FAILED', 'MEDIA_STREAM_INFO_FAILED', 'NO_AUDIO_IN_REQUESTED_WINDOW',
      'NO_AUDIO_TRACK', 'NO_SUBTITLE_TRACK', 'ONLY_MONO_16000_SUPPORTED', 'OPTIONS_REQUIRED',
      'OUTPUT_CREATE_FAILED', 'OUTPUT_SEEK_FAILED', 'OUTPUT_WRITE_FAILED',
      'PREFERRED_SUBTITLE_LANGUAGE_NOT_FOUND', 'RESAMPLER_ALLOCATION_FAILED', 'RESAMPLER_INIT_FAILED',
      'RESERVED_HTTP_HEADER', 'SELECTED_TRACK_IS_NOT_AUDIO', 'SELECTED_TRACK_IS_NOT_SUBTITLE',
      'SOURCE_READ_BUDGET_EXCEEDED', 'SOURCE_REQUIRES_LOCAL_PATH_OR_NUMERIC_HTTP', 'SOURCE_SIZE_CHANGED',
      'STRING_OPTION_TOO_LONG', 'SUBTITLE_BITMAP_OR_CODEC_UNSUPPORTED', 'SUBTITLE_CODEC_UNSUPPORTED',
      'SUBTITLE_DECODER_OPEN_FAILED', 'SUBTITLE_DECODE_FAILED', 'SUBTITLE_ORDINAL_NOT_FOUND',
      'SUBTITLE_PARAMETERS_INVALID', 'SUBTITLE_STREAM_NOT_FOUND', 'SUBTITLE_TEXT_MALFORMED',
      'SUBTITLE_TEXT_TOO_LARGE', 'SUBTITLE_TIMING_UNAVAILABLE', 'SUBTITLE_WINDOW_TOO_LARGE', 'TOO_MANY_HEADERS',
      'TOO_MANY_SUBTITLE_RECTS'];
    const safeHttp = /^HTTP_(AUTHENTICATION_FAILED|RANGE_REQUIRED)_STATUS_\d{3}_(JSON|HTML|MEDIA|OTHER)_CR_[NY]_CL_[NY](?:_API_-?\d{1,10})?(?:_START_\d{1,19}_END_\d{1,19}_TOTAL_\d{1,19})?$/;
    const code = known.indexOf(raw) >= 0 || safeHttp.test(raw) ? raw : 'UNKNOWN';
    let message = '无法读取影片内封字幕，可重试或选择外挂字幕';
    if (code === 'SOURCE_READ_BUDGET_EXCEEDED') { message = '当前字幕片段读取量较大，请暂停后重试或选择外挂字幕'; }
    else if (code === 'EXTRACTION_TIMEOUT') { message = '读取内封字幕超时，请检查服务器连接后重试'; }
    else if (code === 'MEDIA_SEEK_FAILED') { message = '当前影片的字幕定位失败，可重试或选择外挂字幕'; }
    else if (code.indexOf('AUTHENTICATION_FAILED') >= 0) { message = '字幕读取授权已失效，请重新连接服务器'; }
    else if (code === 'HTTP_REDIRECT_REJECTED') { message = '字幕地址已重定向，请重新连接服务器后重试'; }
    else if (['HTTP_CONNECTION_CLOSED', 'HTTP_POLL_FAILED', 'HTTP_SOCKET_FAILED', 'HTTP_TRUNCATED_RANGE'].indexOf(code) >= 0) { message = '内封字幕连接中断，请重试或选择外挂字幕'; }
    else if (['HTTP_HEADERS_TOO_LARGE', 'HTTP_INVALID_HEADER', 'HTTP_INVALID_RESPONSE'].indexOf(code) >= 0) { message = '服务器字幕响应异常，请重连或选择外挂字幕'; }
    else if (code.indexOf('RANGE') >= 0 || code === 'SOURCE_SIZE_CHANGED') { message = '服务器未提供可定位的字幕流，请重连或选择外挂字幕'; }
    else if (code === 'SUBTITLE_TIMING_UNAVAILABLE') { message = '该段内封字幕缺少可用时间轴，可重试或选择外挂字幕'; }
    else if (code === 'SUBTITLE_DECODE_FAILED') { message = '该段内封字幕解码失败，可重试或选择外挂字幕'; }
    else if (['SUBTITLE_ORDINAL_NOT_FOUND', 'SUBTITLE_STREAM_NOT_FOUND', 'PREFERRED_SUBTITLE_LANGUAGE_NOT_FOUND',
      'SELECTED_TRACK_IS_NOT_SUBTITLE'].indexOf(code) >= 0) { message = '所选内封字幕轨暂不可用，请重新选择字幕'; }
    else if (['AI_SOURCE_NETWORK_FAILED', 'HTTP_CONNECT_FAILED', 'HTTP_READ_FAILED', 'HTTP_SEND_FAILED',
      'MEDIA_READ_FAILED', 'MEDIA_STREAM_INFO_FAILED'].indexOf(code) >= 0) { message = '内封字幕读取连接失败，请检查服务器连接后重试'; }
    return { code: code, message: message };
  }

  private previousContext(before: number): string {
    let text = '';
    this.windows.forEach((cues: AiDisplayCue[]) => {
      for (let i = 0; i < cues.length; i++) {
        if (cues[i].endMs <= before && cues[i].endMs >= before - 24000) {
          text += cues[i].originalText + '\n';
        }
      }
    });
    return text.slice(-1600);
  }

  private publish(): void {
    const index = Math.floor(this.positionMs / AiSubtitleSession.WINDOW_MS);
    let selected: AiDisplayCue | undefined = undefined;
    for (let n = index - 1; n <= index + 1; n++) {
      const cues = this.windows.get(n);
      if (cues === undefined) { continue; }
      selected = cues.find((cue: AiDisplayCue) => cue.startMs <= this.positionMs && cue.endMs > this.positionMs);
      if (selected !== undefined) { break; }
    }
    const id = selected !== undefined ? selected.id : '';
    if (id === this.displayId) { return; }
    this.displayId = id;
    this.events.onCaption(selected !== undefined ? selected.originalText : '', selected !== undefined ? selected.translatedText : '');
  }

  private prune(current: number): void {
    let characters = 0;
    this.windows.forEach((cues: AiDisplayCue[]) => {
      cues.forEach((cue: AiDisplayCue) => { characters += cue.originalText.length + cue.translatedText.length; });
    });
    if (this.windows.size <= 64 && characters <= 1048576) { return; }
    const discard: number[] = [];
    this.windows.forEach((_cues: AiDisplayCue[], index: number) => {
      if (Math.abs(index - current) > 24) { discard.push(index); }
    });
    for (let i = 0; i < discard.length; i++) {
      const cues = this.windows.get(discard[i]);
      if (cues !== undefined) { cues.forEach((cue: AiDisplayCue) => { characters -= cue.originalText.length + cue.translatedText.length; }); }
      this.windows.delete(discard[i]);
    }
    if (characters > 1048576) {
      const far: number[] = [];
      this.windows.forEach((_cues: AiDisplayCue[], index: number) => { if (Math.abs(index - current) > 2) { far.push(index); } });
      far.sort((a: number, b: number) => Math.abs(b - current) - Math.abs(a - current));
      for (let i = 0; i < far.length && characters > 1048576; i++) {
        const cues = this.windows.get(far[i]);
        if (cues !== undefined) { cues.forEach((cue: AiDisplayCue) => { characters -= cue.originalText.length + cue.translatedText.length; }); }
        this.windows.delete(far[i]);
      }
    }
  }
}
