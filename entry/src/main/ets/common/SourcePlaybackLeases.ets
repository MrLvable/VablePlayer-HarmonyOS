class SourcePlaybackLease {
  releaseResource: () => Promise<void>;
  claimed: boolean = false;
  timer: number = -1;
  closing: Promise<void> | null = null;
  constructor(releaseResource: () => Promise<void>) { this.releaseResource = releaseResource; }
}

/** A route carries only an opaque ID. The exact provider session owns its cleanup. */
export class SourcePlaybackLeases {
  private static entries: Map<string, SourcePlaybackLease> = new Map<string, SourcePlaybackLease>();
  private static sequence: number = 0;

  static register(release: (() => Promise<void>) | null): string {
    if (release === null) { return ''; }
    const id = 'playback-' + Date.now().toString(36) + '-' + (++SourcePlaybackLeases.sequence).toString(36);
    const entry = new SourcePlaybackLease(release);
    SourcePlaybackLeases.entries.set(id, entry);
    entry.timer = setTimeout(() => { SourcePlaybackLeases.release(id).catch(() => {}); }, 60000);
    return id;
  }

  static claim(id: string): boolean {
    const entry = SourcePlaybackLeases.entries.get(id);
    if (entry === undefined || entry.claimed || entry.closing !== null) { return false; }
    entry.claimed = true;
    if (entry.timer >= 0) { clearTimeout(entry.timer); entry.timer = -1; }
    return true;
  }

  static release(id: string): Promise<void> {
    const entry = SourcePlaybackLeases.entries.get(id);
    if (entry === undefined) { return Promise.resolve(); }
    if (entry.closing !== null) { return entry.closing; }
    if (entry.timer >= 0) { clearTimeout(entry.timer); entry.timer = -1; }
    const closing = Promise.resolve().then(() => entry.releaseResource());
    entry.closing = closing;
    closing.then(() => { SourcePlaybackLeases.entries.delete(id); }, () => { SourcePlaybackLeases.entries.delete(id); });
    return closing;
  }
}
