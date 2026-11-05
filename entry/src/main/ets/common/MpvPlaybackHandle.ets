import { Player, PlayerConfig, Media, MpvLogLevel, MpvEvent, MpvFormat,
  EventObserver } from '@mpv-ohos/mpv-arkts';

export type PlaybackState = 'idle' | 'opening' | 'ready' | 'playing' | 'paused' |
  'buffering' | 'completed' | 'error' | 'released';
export type PlaybackTrackKind = 'video' | 'audio' | 'subtitle';

export interface PlaybackSource {
  url: string;
  headers?: Map<string, string>;
  startMs?: number;
}

export interface PlaybackTrack {
  kind: PlaybackTrackKind;
  id: string;
  codec: string;
  language: string;
  title: string;
  selected: boolean;
}

interface RawMpvTrack {
  id?: number | string;
  type?: string;
  codec?: string;
  lang?: string;
  title?: string;
  selected?: boolean;
}

export interface PlaybackSnapshot {
  state: PlaybackState;
  positionMs: number;
  durationMs: number;
  width: number;
  height: number;
  buffering: boolean;
  bufferingPercent: number;
  bufferedUntilMs: number;
  rate: number;
  volume: number;
}

export interface PlaybackCapabilities {
  selectedTracks: boolean;
  seekCompletion: boolean;
  firstRenderedFrame: boolean;
  externalSubtitles: boolean;
  fitMode: boolean;
  systemPiPValidated: boolean;
}

export class PlaybackError extends Error {
  code: number;
  constructor(operation: string, code: number) {
    super('Playback ' + operation + ' failed [' + code.toString() + ']');
    this.code = code;
  }
}

/** Deliberately engine-neutral; this is not media.AVPlayer. Times are milliseconds. */
export interface PlaybackHandle {
  readonly surfaceController: XComponentController;
  readonly capabilities: PlaybackCapabilities;
  open(source: PlaybackSource): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  seek(positionMs: number): Promise<void>;
  setRate(rate: number): Promise<void>;
  setVolume(volume: number): Promise<void>;
  getSnapshot(): PlaybackSnapshot;
  getTracks(): PlaybackTrack[];
  selectTrack(kind: PlaybackTrackKind, id: string | null): Promise<void>;
  addExternalSubtitle(url: string, language?: string, title?: string): void;
  release(): Promise<void>;
}

/**
 * Prototype against the downloaded package's real declarations and source.
 * Bind surfaceController to exactly one XComponent/PlayerSurface. onReady means
 * surface attachment only. There is deliberately no fake startRenderFrame event.
 */
export class MpvPlaybackHandle implements PlaybackHandle, EventObserver {
  readonly surfaceController: Player;
  readonly capabilities: PlaybackCapabilities = {
    selectedTracks: true, seekCompletion: true, firstRenderedFrame: false,
    externalSubtitles: true, fitMode: false, systemPiPValidated: false
  };
  onState: ((state: PlaybackState) => void) | null = null;
  onPosition: ((positionMs: number) => void) | null = null;
  onTracks: ((tracks: PlaybackTrack[]) => void) | null = null;
  onBuffer: ((active: boolean, percent: number) => void) | null = null;
  onSeekDone: ((positionMs: number) => void) | null = null;
  onPlaybackRestart: (() => void) | null = null;
  onError: ((error: PlaybackError) => void) | null = null;

  private closed: boolean = false;
  private surfaceReady: boolean = false;
  private opened: boolean = false;
  private loaded: boolean = false;
  private paused: boolean = true;
  private buffering: boolean = false;
  private playerState: PlaybackState = 'idle';
  private tracks: PlaybackTrack[] = [];
  private headers: Map<string, string> = new Map();
  private surfaceResolve: (() => void) | null = null;
  private surfaceReject: ((error: PlaybackError) => void) | null = null;
  private surfaceTimer: number = -1;
  private loadResolve: (() => void) | null = null;
  private loadReject: ((error: PlaybackError) => void) | null = null;
  private loadTimer: number = -1;
  private seekResolve: (() => void) | null = null;
  private seekReject: ((error: PlaybackError) => void) | null = null;
  private seekTimer: number = -1;
  private seekObserved: boolean = false;
  private completionReady: boolean = false;
  private releasePromise: Promise<void> | null = null;

  constructor() {
    this.surfaceController = new Player(new PlayerConfig({
      hwdec: true, osc: false, osd: false, logLevel: MpvLogLevel.None,
      onReady: () => {
        if (this.closed) { return; }
        this.surfaceReady = true;
        this.clearSurfaceTimer();
        const resolve = this.surfaceResolve;
        this.surfaceResolve = null; this.surfaceReject = null;
        if (resolve !== null) { resolve(); }
      }
    }));
    const native = this.surfaceController.native;
    // PlayerConfig.None currently falls through the package's level switch.
    native.requestLogMessages('no');
    native.addEventObserver(this);
    // The package defaults to 1024/512MiB. Set bounds before any media is loaded.
    native.setProperty('demuxer-max-bytes', '32MiB');
    native.setProperty('demuxer-max-back-bytes', '8MiB');
    native.setProperty('cache-secs', 20);
    native.setProperty('cache-on-disk', false);
    if (native.getProperty('demuxer-max-bytes') !== 33554432 ||
      native.getProperty('demuxer-max-back-bytes') !== 8388608) {
      native.removeEventObserver(this);
      this.surfaceController.destroy();
      this.closed = true;
      throw new PlaybackError('cache-limit-not-applied', 801);
    }
    // Observe actual native selections, not optimistic Player.set*Track state.
    native.observeProperty('aid', MpvFormat.MPV_FORMAT_STRING);
    native.observeProperty('sid', MpvFormat.MPV_FORMAT_STRING);
    native.observeProperty('vid', MpvFormat.MPV_FORMAT_STRING);
  }

  private live(): void {
    if (this.closed) { throw new PlaybackError('released', 5400102); }
  }

  private setState(state: PlaybackState): void {
    if (this.playerState === state) { return; }
    this.playerState = state;
    if (this.onState !== null) { this.onState(state); }
  }

  private refreshPlaybackState(): void {
    if (this.closed || !this.loaded || this.playerState === 'completed' || this.playerState === 'error') { return; }
    if (this.confirmNativeEof()) { return; }
    this.setState(this.buffering ? 'buffering' : this.paused ? 'paused' : 'playing');
  }

  /** keep-open can pause at EOF without delivering an EOF property callback. */
  private confirmNativeEof(): boolean {
    if (this.closed || !this.loaded || !this.completionReady || this.seekResolve !== null
      || this.playerState === 'completed' || this.playerState === 'error' || this.playerState === 'released') {
      return false;
    }
    try {
      if (this.surfaceController.native.getPropertyBool('eof-reached')) {
        this.setState('completed');
        return true;
      }
    } catch (e) {
      // An unavailable query is not evidence of EOF or a playback failure.
    }
    return false;
  }

  private waitForSurface(): Promise<void> {
    if (this.surfaceReady) { return Promise.resolve(); }
    return new Promise<void>((resolve, reject) => {
      this.surfaceResolve = resolve; this.surfaceReject = reject;
      this.surfaceTimer = setTimeout(() => {
        this.surfaceResolve = null; this.surfaceReject = null; this.surfaceTimer = -1;
        reject(new PlaybackError('surface-timeout', 5400104));
      }, 10000);
    });
  }

  async open(source: PlaybackSource): Promise<void> {
    this.live();
    if (this.opened) { throw new PlaybackError('open-once', 5400102); }
    if (source.url.length === 0) { throw new PlaybackError('source', 401); }
    this.opened = true;
    this.setState('opening');
    try {
      await this.waitForSurface();
      this.live();
      this.headers = new Map<string, string>();
      if (source.headers !== undefined) {
        source.headers.forEach((value: string, name: string) => { this.headers.set(name, value); });
      }
      const rawHeaders: string[] = [];
      this.headers.forEach((value: string, name: string) => {
        if (!/^[A-Za-z0-9!#$%&'*+.^_|~-]+$/.test(name) || /[\r\n]/.test(value)) {
          throw new PlaybackError('http-header', 401);
        }
        // mpv's string-list separator is a comma. These are raw header values,
        // not the package's per-file %length% MediaOptions header encoding.
        const field = (name + ': ' + value).replace(/\\/g, '\\\\').replace(/,/g, '\\,');
        rawHeaders.push(field);
      });
      this.surfaceController.native.setProperty('http-header-fields', rawHeaders.join(','));
      // The page starts with subtitles off. Apply that native policy before
      // loading, since FILE_LOADED metadata may precede automatic selection.
      this.surfaceController.native.setProperty('sid', 'no');
      const loading = new Promise<void>((resolve, reject) => {
        this.loadResolve = resolve; this.loadReject = reject;
        this.loadTimer = setTimeout(() => {
          this.loadResolve = null; this.loadReject = null; this.loadTimer = -1;
          reject(new PlaybackError('file-load-timeout', 5400104));
        }, 30000);
      });
      // false loads paused. No AVPlayer initialized/prepare state is fabricated.
      try {
        this.surfaceController.open(new Media(source.url, {
          start: source.startMs !== undefined ? Math.max(0, source.startMs) / 1000 : undefined
        }), false);
      } catch (e) {
        this.fail('load-command', 5400103);
      }
      await loading;
      this.live();
    } catch (e) {
      if (!this.closed) { this.fail('open', 5400103); }
      throw new PlaybackError('open', 5400103);
    }
  }

  onPropertyChanged(property: string, value?: string | number | boolean): void {
    if (this.closed) { return; }
    if (property === 'pause' && typeof value === 'boolean') {
      this.paused = value;
      if (this.loaded && !value && this.seekResolve === null) { this.completionReady = true; }
      this.refreshPlaybackState();
    } else if (property === 'paused-for-cache' && typeof value === 'boolean') {
      this.buffering = value;
      this.refreshPlaybackState();
      if (this.onBuffer !== null) { this.onBuffer(value, this.surfaceController.state.bufferingPercentage); }
    } else if (property === 'cache-buffering-state' && typeof value === 'number') {
      if (this.onBuffer !== null) { this.onBuffer(this.buffering, value); }
    } else if (property === 'time-pos/full' && typeof value === 'number' && Number.isFinite(value) && value >= 0) {
      if (this.loaded && this.onPosition !== null) { this.onPosition(Math.round(value * 1000)); }
    } else if (property === 'track-list' && typeof value === 'string') {
      this.readTracks(value);
    } else if ((property === 'aid' || property === 'sid' || property === 'vid') && typeof value === 'string') {
      const kind: PlaybackTrackKind = property === 'aid' ? 'audio' : property === 'sid' ? 'subtitle' : 'video';
      // 'auto' is a policy, not an observed track ID. Preserve track-list's
      // actual selection until the native property reports an ID or 'no'.
      if (value !== 'no' && !this.tracks.some((track: PlaybackTrack) => track.kind === kind && track.id === value)) {
        return;
      }
      for (let i = 0; i < this.tracks.length; i++) {
        if (this.tracks[i].kind === kind) { this.tracks[i].selected = this.tracks[i].id === value; }
      }
      if (this.onTracks !== null) { this.onTracks(this.getTracks()); }
    } else if (property === 'eof-reached' && value === true && this.loaded) {
      this.confirmNativeEof();
    }
  }

  onEvent(id: number, _name: string): void {
    if (this.closed || !this.opened) { return; }
    if (id === MpvEvent.MPV_EVENT_FILE_LOADED) {
      this.loaded = true;
      this.paused = this.surfaceController.native.getPropertyBool('pause');
      this.buffering = this.surfaceController.native.getPropertyBool('paused-for-cache');
      this.setState('ready');
      this.clearLoadTimer();
      const resolve = this.loadResolve;
      this.loadResolve = null; this.loadReject = null;
      if (resolve !== null) { resolve(); }
    } else if (id === MpvEvent.MPV_EVENT_SEEK && this.seekResolve !== null) {
      this.seekObserved = true;
    } else if (id === MpvEvent.MPV_EVENT_PLAYBACK_RESTART) {
      // This is an actual mpv playback-restart notification, not proof of a displayed frame.
      if (this.onPlaybackRestart !== null) { this.onPlaybackRestart(); }
      if (this.seekResolve !== null && this.seekObserved) {
        const positionMs = Math.round(this.surfaceController.native.getProperty('time-pos/full') * 1000);
        if (!Number.isFinite(positionMs) || positionMs < 0) { return; }
        const resolve = this.seekResolve;
        this.seekResolve = null; this.seekReject = null; this.seekObserved = false;
        this.clearSeekTimer();
        this.completionReady = true;
        if (this.onSeekDone !== null) { this.onSeekDone(positionMs); }
        resolve();
      }
      this.refreshPlaybackState();
    } else if (id === MpvEvent.MPV_EVENT_END_FILE) {
      if (this.playerState === 'error' || this.playerState === 'completed' || this.seekResolve !== null) { return; }
      if (this.surfaceController.native.getPropertyBool('eof-reached')) { this.confirmNativeEof(); }
      else { this.fail('file-ended-without-eof', 5400103); }
    } else if (id === MpvEvent.MPV_EVENT_SHUTDOWN) {
      this.fail('unexpected-shutdown', 5400105);
    }
  }

  private readTracks(json: string): void {
    try {
      const raw = JSON.parse(json) as RawMpvTrack[];
      const list: PlaybackTrack[] = [];
      for (let i = 0; i < raw.length; i++) {
        const t = raw[i];
        if (t.id === undefined || (t.type !== 'video' && t.type !== 'audio' && t.type !== 'sub')) { continue; }
        list.push({ id: t.id.toString(), kind: t.type === 'sub' ? 'subtitle' : t.type,
          codec: t.codec !== undefined ? t.codec : '', language: t.lang !== undefined ? t.lang : '',
          title: t.title !== undefined ? t.title : '', selected: t.selected === true });
      }
      this.tracks = list;
      if (this.onTracks !== null) { this.onTracks(this.getTracks()); }
    } catch (e) {
      // Track metadata can be temporarily unavailable during a reconfiguration.
      // It must not turn otherwise working playback into a fatal error.
    }
  }

  getSnapshot(): PlaybackSnapshot {
    // Existing page sampling also recovers a real EOF whose native callback was lost.
    // Do not refresh ordinary states here: ready's listener reads this snapshot.
    this.confirmNativeEof();
    const state = this.surfaceController.state;
    // w/h are decoded frame dimensions. dw/dh include the user's aspect
    // override and must never be advertised as a different source quality.
    const width = state.videoParams.w;
    const height = state.videoParams.h;
    return { state: this.playerState, positionMs: Math.round(state.position * 1000),
      durationMs: Math.round(state.duration * 1000), width: Number.isFinite(width) && width > 0 ? width : 0,
      height: Number.isFinite(height) && height > 0 ? height : 0, buffering: this.buffering,
      bufferingPercent: state.bufferingPercentage, bufferedUntilMs: Math.round(state.buffer * 1000),
      rate: state.speed, volume: state.volume / 100 };
  }

  getTracks(): PlaybackTrack[] {
    const copy: PlaybackTrack[] = [];
    for (let i = 0; i < this.tracks.length; i++) {
      const t = this.tracks[i];
      copy.push({ id: t.id, kind: t.kind, codec: t.codec, language: t.language,
        title: t.title, selected: t.selected });
    }
    return copy;
  }

  /** Current native ID, empty when explicitly off, null when unavailable. */
  getSelectedTrackId(kind: PlaybackTrackKind): string | null {
    this.live();
    if (!this.loaded) { return null; }
    const native = this.surfaceController.native;
    const type = kind === 'subtitle' ? 'sub' : kind;
    // The numeric wrapper returns 0 on mpv_get_property failure. A string
    // preserves unavailable as empty and never invents a selected track zero.
    const current = native.getPropertyString('current-tracks/' + type + '/id').trim();
    if (this.tracks.some((track: PlaybackTrack) => track.kind === kind && track.id === current)) { return current; }
    const property = kind === 'audio' ? 'aid' : kind === 'video' ? 'vid' : 'sid';
    const selected = native.getPropertyString(property).trim();
    if (selected === 'no') { return ''; }
    if (this.tracks.some((track: PlaybackTrack) => track.kind === kind && track.id === selected)) { return selected; }
    return null;
  }

  async play(): Promise<void> {
    this.live();
    this.surfaceController.play();
    if (this.loaded && this.seekResolve === null && !this.surfaceController.native.getPropertyBool('pause')) {
      this.completionReady = true;
    }
  }
  async pause(): Promise<void> { this.live(); this.surfaceController.pause(); }

  seek(positionMs: number): Promise<void> {
    this.live();
    if (!this.loaded || this.seekResolve !== null || !Number.isFinite(positionMs) || positionMs < 0) {
      return Promise.reject(new PlaybackError('seek-state-or-position', 5400102));
    }
    // A previous position's EOF must not complete this in-flight seek.
    this.completionReady = false;
    const seeking = new Promise<void>((resolve, reject) => {
      this.seekObserved = false; this.seekResolve = resolve; this.seekReject = reject;
      this.seekTimer = setTimeout(() => {
        this.seekResolve = null; this.seekReject = null; this.seekObserved = false; this.seekTimer = -1;
        reject(new PlaybackError('seek-completion-timeout', 5400104));
      }, 15000);
    });
    try {
      this.surfaceController.seek(positionMs / 1000);
    } catch (e) {
      this.clearSeekTimer();
      const reject = this.seekReject;
      this.seekResolve = null; this.seekReject = null;
      if (reject !== null) { reject(new PlaybackError('seek-command', 5400103)); }
    }
    return seeking;
  }

  async setRate(rate: number): Promise<void> {
    this.live();
    if (!Number.isFinite(rate) || rate <= 0 || rate > 4) { throw new PlaybackError('rate', 401); }
    this.surfaceController.setSpeed(rate);
  }

  async setVolume(volume: number): Promise<void> {
    this.live();
    if (!Number.isFinite(volume) || volume < 0 || volume > 1) { throw new PlaybackError('volume', 401); }
    this.surfaceController.setVolume(volume * 100);
  }

  async selectTrack(kind: PlaybackTrackKind, id: string | null): Promise<void> {
    this.live();
    if (id !== null && !this.tracks.some((track: PlaybackTrack) => track.kind === kind && track.id === id)) {
      throw new PlaybackError('unknown-track', 401);
    }
    const property = kind === 'audio' ? 'aid' : kind === 'video' ? 'vid' : 'sid';
    this.surfaceController.native.setProperty(property, id !== null ? id : 'no');
    // Promise means command submitted. Selection UI must follow native onTracks.
  }

  addExternalSubtitle(url: string, language: string = '', title: string = ''): void {
    this.live();
    if (url.length === 0) { throw new PlaybackError('subtitle-url', 401); }
    // Do not use the package's optimistic selected-URI state as confirmation.
    this.surfaceController.native.command(['sub-add', url, 'select', title || 'external', language || 'auto']);
  }

  private fail(operation: string, code: number): void {
    if (this.closed || this.playerState === 'error') { return; }
    const error = new PlaybackError(operation, code);
    this.setState('error');
    this.clearLoadTimer(); this.clearSeekTimer();
    const loadReject = this.loadReject; const seekReject = this.seekReject;
    this.loadResolve = null; this.loadReject = null;
    this.seekResolve = null; this.seekReject = null;
    if (loadReject !== null) { loadReject(error); }
    if (seekReject !== null) { seekReject(error); }
    if (this.onError !== null) { this.onError(error); }
  }

  private clearSurfaceTimer(): void { if (this.surfaceTimer >= 0) { clearTimeout(this.surfaceTimer); this.surfaceTimer = -1; } }
  private clearLoadTimer(): void { if (this.loadTimer >= 0) { clearTimeout(this.loadTimer); this.loadTimer = -1; } }
  private clearSeekTimer(): void { if (this.seekTimer >= 0) { clearTimeout(this.seekTimer); this.seekTimer = -1; } }

  release(): Promise<void> {
    if (this.releasePromise !== null) { return this.releasePromise; }
    this.closed = true;
    this.clearSurfaceTimer(); this.clearLoadTimer(); this.clearSeekTimer();
    const error = new PlaybackError('cancelled', 5400102);
    const surfaceReject = this.surfaceReject; const loadReject = this.loadReject; const seekReject = this.seekReject;
    this.surfaceResolve = null; this.surfaceReject = null;
    this.loadResolve = null; this.loadReject = null; this.seekResolve = null; this.seekReject = null;
    if (surfaceReject !== null) { surfaceReject(error); }
    if (loadReject !== null) { loadReject(error); }
    if (seekReject !== null) { seekReject(error); }
    this.surfaceController.native.removeEventObserver(this);
    this.releasePromise = Promise.resolve().then(() => {
      try { this.surfaceController.native.setProperty('http-header-fields', ''); } catch (e) {}
      try {
        this.surfaceController.destroy();
      } finally {
        this.headers.clear();
        this.tracks = [];
        this.setState('released');
      }
    });
    return this.releasePromise;
  }
}
