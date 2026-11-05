import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { PlaybackHandle, HandleStateListener, HandleFrameListener, HandleSeekListener,
  HandleBufferListener, HandleErrorListener, HandleListener, HandleEvent } from './PlaybackHandle';

export class AvPlayerHandle implements PlaybackHandle {
  readonly engineKind: string = 'avplayer';
  readonly hasFirstFrameEvent: boolean = true;
  readonly nativePlayer: media.AVPlayer;
  constructor(player: media.AVPlayer) { this.nativePlayer = player; }
  get state(): string { return this.nativePlayer.state; }
  get currentTime(): number { return this.nativePlayer.currentTime; }
  get duration(): number { return this.nativePlayer.duration; }
  get width(): number { return this.nativePlayer.width; }
  get height(): number { return this.nativePlayer.height; }
  get surfaceId(): string { return this.nativePlayer.surfaceId ?? ''; }
  set surfaceId(value: string) { this.nativePlayer.surfaceId = value; }
  get videoScaleType(): media.VideoScaleType { return this.nativePlayer.videoScaleType ?? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT; }
  set videoScaleType(value: media.VideoScaleType) { this.nativePlayer.videoScaleType = value; }
  get audioInterruptMode(): audio.InterruptMode { return this.nativePlayer.audioInterruptMode ?? audio.InterruptMode.SHARE_MODE; }
  set audioInterruptMode(value: audio.InterruptMode) { this.nativePlayer.audioInterruptMode = value; }
  prepare(): Promise<void> { return this.nativePlayer.prepare(); }
  setPlaybackStrategy(value: media.PlaybackStrategy): Promise<void> { return this.nativePlayer.setPlaybackStrategy(value); }
  play(): Promise<void> { return this.nativePlayer.play(); }
  pause(): Promise<void> { return this.nativePlayer.pause(); }
  seek(value: number, mode: media.SeekMode = media.SeekMode.SEEK_PREV_SYNC): void { this.nativePlayer.seek(value, mode); }
  setSpeed(value: media.PlaybackSpeed): void { this.nativePlayer.setSpeed(value); }
  async setVolume(value: number): Promise<void> { this.nativePlayer.setVolume(value); }
  getTrackDescription(): Promise<media.MediaDescription[]> { return this.nativePlayer.getTrackDescription(); }
  getSelectedTracks(): Promise<number[]> { return this.nativePlayer.getSelectedTracks(); }
  selectTrack(index: number, mode?: media.SwitchMode): Promise<void> { return this.nativePlayer.selectTrack(index, mode); }
  deselectTrack(index: number): Promise<void> { return this.nativePlayer.deselectTrack(index); }
  addSubtitleFromUrl(url: string): Promise<void> { return this.nativePlayer.addSubtitleFromUrl(url); }
  release(): Promise<void> { return this.nativePlayer.release(); }
  on(type: 'stateChange', callback: HandleStateListener): void;
  on(type: 'startRenderFrame', callback: HandleFrameListener): void;
  on(type: 'seekDone', callback: HandleSeekListener): void;
  on(type: 'bufferingUpdate', callback: HandleBufferListener): void;
  on(type: 'error', callback: HandleErrorListener): void;
  on(type: HandleEvent, callback: HandleListener): void {
    if (type === 'stateChange') { this.nativePlayer.on('stateChange', callback as HandleStateListener); }
    else if (type === 'startRenderFrame') { this.nativePlayer.on('startRenderFrame', callback as HandleFrameListener); }
    else if (type === 'seekDone') { this.nativePlayer.on('seekDone', callback as HandleSeekListener); }
    else if (type === 'bufferingUpdate') { this.nativePlayer.on('bufferingUpdate', callback as HandleBufferListener); }
    else { this.nativePlayer.on('error', callback as HandleErrorListener); }
  }
}
