import { Store } from './Store';

export class PlaybackPreferenceValues {
  autoNext: boolean = true;
  doubleTapPause: boolean = true;
  ratio: string = '默认';
  subtitleScale: number = 1;
}

/** Shared defaults; a playback session can still override ratio/subtitle size. */
export class PlaybackPreferences {
  private static value: PlaybackPreferenceValues = new PlaybackPreferenceValues();
  private static writes: Promise<void> = Promise.resolve();
  private static revision: number = 0;

  static current(): PlaybackPreferenceValues {
    const out = new PlaybackPreferenceValues();
    out.autoNext = PlaybackPreferences.value.autoNext;
    out.doubleTapPause = PlaybackPreferences.value.doubleTapPause;
    out.ratio = PlaybackPreferences.value.ratio;
    out.subtitleScale = PlaybackPreferences.value.subtitleScale;
    return out;
  }

  static async load(): Promise<PlaybackPreferenceValues> {
    const revision = PlaybackPreferences.revision;
    await PlaybackPreferences.writes.catch(() => {});
    if (revision !== PlaybackPreferences.revision) { return PlaybackPreferences.current(); }
    const out = new PlaybackPreferenceValues();
    try {
      const raw = JSON.parse(await Store.get('playback_preferences_v1', '{}')) as PlaybackPreferenceValues;
      if (typeof raw.autoNext === 'boolean') { out.autoNext = raw.autoNext; }
      if (typeof raw.doubleTapPause === 'boolean') { out.doubleTapPause = raw.doubleTapPause; }
      if (['默认', '平铺', '拉伸', '裁切', '16:9', '4:3', '原始像素比例'].indexOf(raw.ratio) >= 0) { out.ratio = raw.ratio; }
      if ([0.8, 1, 1.25, 1.5].indexOf(raw.subtitleScale) >= 0) { out.subtitleScale = raw.subtitleScale; }
    } catch (error) { /* Invalid legacy data uses documented defaults. */ }
    if (revision === PlaybackPreferences.revision) { PlaybackPreferences.value = out; }
    return PlaybackPreferences.current();
  }

  static save(next: PlaybackPreferenceValues): Promise<void> {
    if (next === null || typeof next !== 'object' || typeof next.autoNext !== 'boolean'
      || typeof next.doubleTapPause !== 'boolean'
      || ['默认', '平铺', '拉伸', '裁切', '16:9', '4:3', '原始像素比例'].indexOf(next.ratio) < 0
      || [0.8, 1, 1.25, 1.5].indexOf(next.subtitleScale) < 0) {
      return Promise.reject(new Error('播放设置无效，请重新选择'));
    }
    // Only known fields enter Preferences. Neither caller mutation nor a custom
    // toJSON/extra field can change an already accepted queued write.
    const snapshot = new PlaybackPreferenceValues();
    snapshot.autoNext = next.autoNext; snapshot.doubleTapPause = next.doubleTapPause;
    snapshot.ratio = next.ratio; snapshot.subtitleScale = next.subtitleScale;
    const raw = JSON.stringify(snapshot);
    PlaybackPreferences.revision++;
    const write = PlaybackPreferences.writes.catch(() => {}).then(async (): Promise<void> => {
      await Store.set('playback_preferences_v1', raw);
      PlaybackPreferences.value = snapshot;
    });
    PlaybackPreferences.writes = write;
    return write;
  }
}
