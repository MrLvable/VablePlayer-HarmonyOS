import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackHandle, HandleStateListener, HandleFrameListener, HandleSeekListener,
  HandleBufferListener, HandleErrorListener, HandleListener, HandleEvent } from './PlaybackHandle';
import { MpvPlaybackHandle, PlaybackTrack, PlaybackTrackKind, PlaybackError } from './MpvPlaybackHandle';

export interface MpvTechnicalInfo {
  fps: number | null;
  /** Current encoded video bitrate in bits per second, when available. */
  bitrate: number | null;
  hardware: 'hardware' | 'software' | 'unknown';
  /** Describes the reported source transfer, not the display's output mode. */
  dynamicRange: 'SDR' | 'HDR' | '';
  gamma: string;
}

/** Explicit small UI adapter. Numeric UI indexes map to (kind, mpv-id), never array positions. */
export class MpvAdapter implements PlaybackHandle {
  private static active: MpvAdapter | null = null;
  private static creationTail: Promise<void> = Promise.resolve();
  readonly engineKind: string = 'mpv';
  readonly hasFirstFrameEvent: boolean = false;
  readonly core: MpvPlaybackHandle = new MpvPlaybackHandle();
  private closed: boolean = false;
  private scale: media.VideoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
  private keys: string[] = [];
  private stateListener: HandleStateListener | null = null;
  private seekListener: HandleSeekListener | null = null;
  private bufferListener: HandleBufferListener | null = null;
  private errorListener: HandleErrorListener | null = null;
  static create(): Promise<MpvAdapter> {
    const creating = MpvAdapter.creationTail.then(async (): Promise<MpvAdapter> => {
      const active = MpvAdapter.active;
      if (active !== null) { await active.release(); }
      // Native events already posted by the old, now joined thread resolve the
      // package's global callback names when they run. Drain that main-loop turn
      // before binding the next instance, including after an external release.
      await new Promise<void>((resolve) => { setTimeout(resolve, 0); });
      const next = new MpvAdapter();
      MpvAdapter.active = next;
      return next;
    });
    MpvAdapter.creationTail = creating.then(() => {}, () => {});
    return creating;
  }
  private constructor() {
    this.core.onState = () => { if (this.stateListener !== null) { this.stateListener(this.state); } };
    this.core.onSeekDone = (position: number) => { if (this.seekListener !== null) { this.seekListener(position); } };
    this.core.onBuffer = (active: boolean, percent: number) => {
      if (this.bufferListener !== null) {
        this.bufferListener(active ? media.BufferingInfoType.BUFFERING_START : media.BufferingInfoType.BUFFERING_END, 0);
        this.bufferListener(media.BufferingInfoType.BUFFERING_PERCENT, percent);
      }
    };
    this.core.onError = (error: PlaybackError) => { if (this.errorListener !== null) { this.errorListener(error); } };
  }
  get surfaceController(): XComponentController { return this.core.surfaceController; }
  get isReleased(): boolean { return this.closed; }
  get state(): string { const value = this.core.getSnapshot().state; return value === 'ready' ? 'prepared' : value; }
  get currentTime(): number { return this.core.getSnapshot().positionMs; }
  get duration(): number { return this.core.getSnapshot().durationMs; }
  get width(): number { return this.core.getSnapshot().width; }
  get height(): number { return this.core.getSnapshot().height; }
  /** A best-effort demux mapping. Unavailable mappings are never replaced by mpv's UI track ID. */
  getSelectedDemuxStreamIndex(kind: 'audio' | 'subtitle'): number {
    if (this.closed) { return -1; }
    const id = this.core.getSelectedTrackId(kind);
    if (id === null) { return -1; }
    const native = this.core.surfaceController.native;
    const countText = native.getPropertyString('track-list/count').trim();
    if (!/^\d+$/.test(countText)) { return -1; }
    const count = Math.min(128, Number(countText));
    for (let i = 0; i < count; i++) {
      const prefix = 'track-list/' + i.toString() + '/';
      const type = native.getPropertyString(prefix + 'type');
      if (type !== (kind === 'subtitle' ? 'sub' : 'audio') || native.getPropertyString(prefix + 'id').trim() !== id) { continue; }
      const index = native.getPropertyString(prefix + 'ff-index').trim();
      return /^\d+$/.test(index) ? Number(index) : -1;
    }
    return -1;
  }
  getTechnicalInfo(): MpvTechnicalInfo {
    if (this.closed) { return { fps: null, bitrate: null, hardware: 'unknown', dynamicRange: '', gamma: '' }; }
    const native = this.core.surfaceController.native;
    const fps = native.getProperty('container-fps');
    const bitrate = native.getProperty('video-bitrate');
    const decoder = native.getPropertyString('hwdec-current').trim();
    const gamma = native.getPropertyString('video-params/gamma').trim().toLowerCase();
    let hardware: 'hardware' | 'software' | 'unknown' = 'unknown';
    if (decoder === 'no') { hardware = 'software'; }
    else if (decoder.length > 0) { hardware = 'hardware'; }
    let dynamicRange: 'SDR' | 'HDR' | '' = '';
    if (gamma === 'pq' || gamma === 'hlg') { dynamicRange = 'HDR'; }
    else if (gamma === 'bt.1886' || gamma === 'srgb' || gamma === 'gamma1.8' || gamma === 'gamma2.0'
      || gamma === 'gamma2.2' || gamma === 'gamma2.4' || gamma === 'gamma2.6' || gamma === 'gamma2.8') {
      dynamicRange = 'SDR';
    }
    return { fps: Number.isFinite(fps) && fps > 0 ? fps : null,
      bitrate: Number.isFinite(bitrate) && bitrate > 0 ? bitrate : null,
      hardware: hardware, dynamicRange: dynamicRange, gamma: gamma };
  }

  applyScreenRatio(mode: string): void {
    if (this.closed) { throw new PlaybackError('released', 5400102); }
    const modes: string[] = ['默认', '平铺', '拉伸', '裁切', '16:9', '4:3', '原始像素比例'];
    if (modes.indexOf(mode) < 0) { throw new PlaybackError('screen-ratio-mode', 401); }
    const native = this.core.surfaceController.native;
    const names: string[] = ['keepaspect', 'panscan', 'video-aspect-override', 'video-unscaled'];
    const previous: string[] = names.map((name: string) => native.getPropertyString(name));
    const keepAspect = mode !== '拉伸';
    const panscan = mode === '平铺' || mode === '裁切' ? 1 : 0;
    const aspect = mode === '16:9' || mode === '4:3' ? mode : 'no';
    // Original pixels: do not scale; oversized video is cropped by the window.
    const unscaled = mode === '原始像素比例' ? 'yes' : 'no';
    try {
      native.setProperty('keepaspect', keepAspect);
      native.setProperty('panscan', panscan);
      native.setProperty('video-aspect-override', aspect);
      native.setProperty('video-unscaled', unscaled);
      const actual: string[] = names.map((name: string) => native.getPropertyString(name).trim());
      const ratioParts = actual[2].split(':');
      const actualRatio = ratioParts.length === 2 ? Number(ratioParts[0]) / Number(ratioParts[1]) : Number(actual[2]);
      const expectedRatio = mode === '16:9' ? 16 / 9 : 4 / 3;
      // The bundled mpv 0.41 aspect parser stores 'no' as -2.0 and its string
      // getter prints -2.000000. Zero/-1 select different aspect policies.
      const aspectMatches = aspect === 'no' ? actual[2] === 'no'
        || Number.isFinite(actualRatio) && Math.abs(actualRatio + 2) < 0.0001
        : Number.isFinite(actualRatio) && Math.abs(actualRatio - expectedRatio) < 0.0001;
      hilog.info(0x0001, 'NasPlay', 'RATIO mode=%{public}s readback=%{public}s', mode, actual.join('|'));
      if (actual.some((value: string) => value.length === 0)
        || actual[0] !== (keepAspect ? 'yes' : 'no')
        || !Number.isFinite(Number(actual[1])) || Math.abs(Number(actual[1]) - panscan) > 0.0001
        || !aspectMatches || actual[3] !== unscaled) {
        throw new PlaybackError('screen-ratio-readback', 801);
      }
    } catch (e) {
      for (let i = 0; i < names.length; i++) {
        if (previous[i].length > 0) {
          // The numeric -2 readback is a parser sentinel; restore its public
          // spelling rather than passing it through a numeric range check.
          const restore = names[i] === 'video-aspect-override' && Number(previous[i]) === -2 ? 'no' : previous[i];
          try { native.setProperty(names[i], restore); } catch (rollbackError) {}
        }
      }
      throw new PlaybackError('screen-ratio', 801);
    }
  }
  setSubtitleScale(scale: number): void {
    if (this.closed) { throw new PlaybackError('released', 5400102); }
    if (!Number.isFinite(scale) || scale < 0.5 || scale > 2) { throw new PlaybackError('subtitle-scale-range', 401); }
    const native = this.core.surfaceController.native;
    const previous = native.getPropertyString('sub-scale');
    native.setProperty('sub-scale', scale);
    const actual = native.getPropertyString('sub-scale').trim();
    if (actual.length === 0 || !Number.isFinite(Number(actual)) || Math.abs(Number(actual) - scale) > 0.0001) {
      if (previous.length > 0) { try { native.setProperty('sub-scale', previous); } catch (e) {} }
      throw new PlaybackError('subtitle-scale-readback', 801);
    }
  }
  get surfaceId(): string { return this.surfaceController.getXComponentSurfaceId(); }
  set surfaceId(value: string) { if (value !== this.surfaceId) { throw new PlaybackError('surface-owned-by-mpv', 801); } }
  get videoScaleType(): media.VideoScaleType { return this.scale; }
  set videoScaleType(value: media.VideoScaleType) {
    const panscan = value === media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP ? 1 : 0;
    this.core.surfaceController.native.setProperty('panscan', panscan);
    if (this.core.surfaceController.native.getProperty('panscan') !== panscan) { throw new PlaybackError('fit-mode', 801); }
    this.scale = value;
  }
  get audioInterruptMode(): audio.InterruptMode { throw new PlaybackError('audio-focus-not-bound', 801); }
  set audioInterruptMode(_value: audio.InterruptMode) { throw new PlaybackError('audio-focus-not-bound', 801); }
  prepare(): Promise<void> { return Promise.reject(new PlaybackError('use-open-source', 801)); }
  setPlaybackStrategy(_value: media.PlaybackStrategy): Promise<void> { return Promise.reject(new PlaybackError('avplayer-strategy-not-applicable', 801)); }
  open(url: string, headers: Record<string, string>): Promise<void> {
    const values: Map<string, string> = new Map();
    const names = Object.keys(headers);
    for (let i = 0; i < names.length; i++) { values.set(names[i], headers[names[i]]); }
    return this.core.open({ url: url, headers: values });
  }
  play(): Promise<void> { return this.core.play(); }
  pause(): Promise<void> { return this.core.pause(); }
  seek(value: number, _mode?: media.SeekMode): void {
    this.core.seek(value).catch((error: PlaybackError) => { if (!this.closed && this.errorListener !== null) { this.errorListener(error); } });
  }
  setSpeed(value: media.PlaybackSpeed): void {
    let rate = 1;
    if (value === media.PlaybackSpeed.SPEED_FORWARD_0_125_X) { rate = 0.125; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_0_25_X) { rate = 0.25; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_0_50_X) { rate = 0.5; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_0_75_X) { rate = 0.75; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_1_25_X) { rate = 1.25; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_1_50_X) { rate = 1.5; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_1_75_X) { rate = 1.75; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_2_00_X) { rate = 2; }
    else if (value === media.PlaybackSpeed.SPEED_FORWARD_3_00_X) { rate = 3; }
    this.core.surfaceController.setSpeed(rate);
    if (Math.abs(this.core.surfaceController.native.getProperty('speed') - rate) > 0.001) { throw new PlaybackError('rate', 5400102); }
  }
  setVolume(value: number): Promise<void> { return this.core.setVolume(value); }
  private index(track: PlaybackTrack): number {
    const key = track.kind + ':' + track.id;
    let index = this.keys.indexOf(key);
    if (index < 0) { this.keys.push(key); index = this.keys.length - 1; }
    return index;
  }
  private async waitTracks(): Promise<PlaybackTrack[]> {
    for (let i = 0; i < 20 && !this.closed && this.core.getTracks().length === 0; i++) {
      await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
    }
    return this.core.getTracks();
  }
  async getTrackDescription(): Promise<media.MediaDescription[]> {
    const tracks = await this.waitTracks();
    const result: media.MediaDescription[] = [];
    for (let i = 0; i < tracks.length; i++) {
      const t = tracks[i];
      result.push({ track_index: this.index(t), track_type: t.kind === 'audio' ? media.MediaType.MEDIA_TYPE_AUD
        : t.kind === 'video' ? media.MediaType.MEDIA_TYPE_VID : media.MediaType.MEDIA_TYPE_SUBTITLE,
        codec_mime: t.codec, language: t.language, native_id: t.id });
    }
    return result;
  }
  async getSelectedTracks(): Promise<number[]> {
    // track-list metadata can arrive before native track selection completes.
    // Query the active IDs now rather than reusing that early selected=false.
    for (let attempt = 0; attempt < 10 && !this.closed; attempt++) {
      const tracks = this.core.getTracks();
      const kinds: PlaybackTrackKind[] = ['video', 'audio', 'subtitle'];
      const result: number[] = [];
      let pending = false;
      for (let k = 0; k < kinds.length; k++) {
        const kind = kinds[k];
        if (!tracks.some((track: PlaybackTrack) => track.kind === kind)) { continue; }
        const id = this.core.getSelectedTrackId(kind);
        if (id === null) { pending = true; continue; }
        for (let i = 0; i < tracks.length; i++) {
          if (tracks[i].kind === kind && tracks[i].id === id) { result.push(this.index(tracks[i])); }
        }
      }
      if (!pending) { return result; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
    }
    throw new PlaybackError('track-selection-unavailable', 5400104);
  }
  private track(index: number): PlaybackTrack {
    const tracks = this.core.getTracks();
    for (let i = 0; i < tracks.length; i++) { if (this.index(tracks[i]) === index) { return tracks[i]; } }
    throw new PlaybackError('unknown-track', 401);
  }
  private async confirmSelection(kind: PlaybackTrackKind, id: string | null): Promise<void> {
    for (let i = 0; i < 25 && !this.closed; i++) {
      const selected = this.core.getSelectedTrackId(kind);
      if (selected === (id !== null ? id : '')) { return; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
    }
    throw new PlaybackError('track-confirmation', 5400104);
  }
  async selectTrack(index: number, _mode?: media.SwitchMode): Promise<void> {
    const t = this.track(index); await this.core.selectTrack(t.kind, t.id); await this.confirmSelection(t.kind, t.id);
  }
  async deselectTrack(index: number): Promise<void> {
    const t = this.track(index);
    const selected = this.core.getSelectedTrackId(t.kind);
    if (selected === null) { throw new PlaybackError('track-selection-unavailable', 5400104); }
    if (selected !== t.id) { return; }
    await this.core.selectTrack(t.kind, null); await this.confirmSelection(t.kind, null);
  }
  async addSubtitleFromUrl(url: string): Promise<void> {
    const before = this.core.getTracks().filter((t: PlaybackTrack) => t.kind === 'subtitle').map((t: PlaybackTrack) => t.id);
    this.core.addExternalSubtitle(url);
    for (let i = 0; i < 50 && !this.closed; i++) {
      const selected = this.core.getSelectedTrackId('subtitle');
      const added = selected !== null && selected.length > 0 && before.indexOf(selected) < 0
        && this.core.getTracks().some((t: PlaybackTrack) => t.kind === 'subtitle' && t.id === selected);
      if (added) { return; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
    }
    throw new PlaybackError('external-subtitle-confirmation', 5400104);
  }
  release(): Promise<void> {
    this.closed = true;
    return this.core.release().then(() => {
      if (MpvAdapter.active === this) { MpvAdapter.active = null; }
    });
  }
  on(type: 'stateChange', callback: HandleStateListener): void;
  on(type: 'startRenderFrame', callback: HandleFrameListener): void;
  on(type: 'seekDone', callback: HandleSeekListener): void;
  on(type: 'bufferingUpdate', callback: HandleBufferListener): void;
  on(type: 'error', callback: HandleErrorListener): void;
  on(type: HandleEvent, callback: HandleListener): void {
    if (type === 'stateChange') { this.stateListener = callback as HandleStateListener; }
    else if (type === 'seekDone') { this.seekListener = callback as HandleSeekListener; }
    else if (type === 'bufferingUpdate') { this.bufferListener = callback as HandleBufferListener; }
    else if (type === 'error') { this.errorListener = callback as HandleErrorListener; }
    // startRenderFrame is intentionally unsupported and is never emitted.
  }
}
