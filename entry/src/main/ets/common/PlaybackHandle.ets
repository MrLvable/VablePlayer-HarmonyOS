import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

export type HandleStateListener = (state: string) => void;
export type HandleFrameListener = () => void;
export type HandleSeekListener = (position: number) => void;
export type HandleBufferListener = (type: media.BufferingInfoType, value: number) => void;
export type HandleErrorListener = (error: BusinessError) => void;
export type HandleListener = HandleStateListener | HandleFrameListener | HandleSeekListener |
  HandleBufferListener | HandleErrorListener;
export type HandleEvent = 'stateChange' | 'startRenderFrame' | 'seekDone' | 'bufferingUpdate' | 'error';

/** Only the members used by PlayerPage; source assignment stays backend-specific. */
export interface PlaybackHandle {
  readonly engineKind: string;
  readonly hasFirstFrameEvent: boolean;
  readonly state: string;
  readonly currentTime: number;
  readonly duration: number;
  readonly width: number;
  readonly height: number;
  surfaceId: string;
  videoScaleType: media.VideoScaleType;
  audioInterruptMode: audio.InterruptMode;
  prepare(): Promise<void>;
  setPlaybackStrategy(strategy: media.PlaybackStrategy): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  seek(position: number, mode?: media.SeekMode): void;
  setSpeed(speed: media.PlaybackSpeed): void;
  setVolume(volume: number): Promise<void>;
  getTrackDescription(): Promise<media.MediaDescription[]>;
  getSelectedTracks(): Promise<number[]>;
  selectTrack(index: number, mode?: media.SwitchMode): Promise<void>;
  deselectTrack(index: number): Promise<void>;
  addSubtitleFromUrl(url: string): Promise<void>;
  release(): Promise<void>;
  on(type: 'stateChange', callback: HandleStateListener): void;
  on(type: 'startRenderFrame', callback: HandleFrameListener): void;
  on(type: 'seekDone', callback: HandleSeekListener): void;
  on(type: 'bufferingUpdate', callback: HandleBufferListener): void;
  on(type: 'error', callback: HandleErrorListener): void;
}
