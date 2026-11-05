import { ServerConfig, MediaItem } from '../Models';
import { ProgressRepository, ProgressRecordV2 } from '../ProgressRepository';
import { ServerOptions } from '../ServerOptions';
import { MediaCatalog } from '../services/MediaCatalog';
import { MediaServiceRegistry } from '../services/MediaServiceRegistry';
import { MediaServices } from '../services/MediaServices';
import { SourceIdentity } from '../services/SourceIdentity';
import { SourceAuthConfig } from '../services/SourceAuthorization';
import { VisionStore } from './VisionStore';
import { VisionState, VisionRow, VisionReference, VisionPlaylist } from './VisionModels';

interface CancellableVisionCatalog extends MediaCatalog { cancel: () => void; }
class VisionSeries { server: ServerConfig; id: string; constructor(server: ServerConfig, id: string) { this.server = server; this.id = id; } }

/** HosVision is a personal watch hub. All dates/progress come from saved state or the actual media provider. */
export class VisionController {
  private servers: ServerConfig[] = [];
  private eligible: ServerConfig[] = [];
  private state: VisionState = new VisionState();
  private catalogs: Map<string, MediaCatalog> = new Map();
  private generation: number = 0;
  private calendarGeneration: number = 0;
  private timer: number = -1;
  private active: boolean = false;
  private mounted: boolean = true;
  private configured: boolean = false;
  private revision: number = -1;
  private publish: (state: VisionState) => void;
  constructor(publish: (state: VisionState) => void) { this.publish = publish; }
  static scope(servers: ServerConfig[]): string {
    return SourceIdentity.key(JSON.stringify(servers.slice(0, 1).map((server: ServerConfig) => [SourceIdentity.scope(server), server.credentialRef, SourceIdentity.key(server.token)])));
  }
  private alive(generation: number): boolean { return this.mounted && this.active && generation === this.generation; }
  private emit(): void {
    if (this.timer >= 0 || !this.active || !this.mounted) { return; } const generation = this.generation;
    this.timer = setTimeout(() => {
      this.timer = -1; if (!this.alive(generation)) { return; }
      const next = new VisionState(); next.scope = this.state.scope; next.section = this.state.section;
      next.watchLater = this.state.watchLater.slice(); next.watching = this.state.watching.slice(); next.calendar = this.state.calendar.slice();
      next.playlists = this.state.playlists.slice(); next.selectedPlaylistId = this.state.selectedPlaylistId; next.filterServerId = this.state.filterServerId;
      next.errors = this.state.errors.slice(); next.busy = this.state.busy; next.calendarBusy = this.state.calendarBusy;
      next.calendarUnknown = this.state.calendarUnknown; next.calendarError = this.state.calendarError; this.publish(next);
    }, 16);
  }
  private invalidate(): number {
    this.generation++; this.calendarGeneration++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    this.catalogs.forEach((catalog: MediaCatalog) => { const source = catalog as CancellableVisionCatalog; if (typeof source.cancel === 'function') { source.cancel(); } });
    this.catalogs.clear(); return this.generation;
  }
  configure(servers: ServerConfig[], active: boolean, revision: number = 0, initialSection: number = 0): void {
    const scope = VisionController.scope(servers); const changed = scope !== this.state.scope; const wasActive = this.active;
    this.active = active;
    this.servers = servers.slice(0, 1).map((server: ServerConfig) => SourceAuthConfig.copy(server));
    if (!this.configured) { this.state.section = Math.max(0, Math.min(3, initialSection)); this.configured = true; }
    if (changed) {
      const section = this.state.section; this.invalidate();
      this.eligible = []; this.state = new VisionState(); this.state.scope = scope; this.state.section = section;
    }
    const refresh = changed || !wasActive || revision !== this.revision; this.revision = revision;
    if (!active) { this.invalidate(); return; } if (refresh) { this.refresh(); }
  }
  destroy(): void { this.mounted = false; this.active = false; this.invalidate(); }
  private catalog(server: ServerConfig): MediaCatalog {
    const scope = SourceIdentity.scope(server); const previous = this.catalogs.get(scope); if (previous !== undefined) { return previous; }
    const catalog = MediaServiceRegistry.forServer(server).catalog; this.catalogs.set(scope, catalog); return catalog;
  }
  private refRows(refs: VisionReference[]): VisionRow[] {
    const rows: VisionRow[] = [];
    refs.forEach((ref: VisionReference) => {
      const server = this.eligible.find((source: ServerConfig) => source.id === ref.serverId && SourceIdentity.scope(source) === ref.accountScope);
      if (server === undefined) { return; } const row = new VisionRow(server, ref.item); row.key = ref.key; row.updatedAt = ref.addedAt; rows.push(row);
    }); return rows;
  }
  private async local(generation: number): Promise<void> {
    const saved = await VisionStore.load(this.eligible); if (!this.alive(generation)) { return; }
    this.state.watchLater = this.refRows(saved.watchLater); this.state.playlists = saved.playlists;
    if (this.state.selectedPlaylistId.length > 0 && !saved.playlists.some((entry: VisionPlaylist) => entry.id === this.state.selectedPlaylistId)) { this.state.selectedPlaylistId = ''; }
  }
  async refresh(): Promise<void> {
    if (!this.mounted || !this.active) { return; } const generation = this.invalidate();
    this.state.busy = true; this.state.errors = []; this.emit();
    try {
      const options = await ServerOptions.all(); if (!this.alive(generation)) { return; }
      options.forEach((option) => { if (option.error.length > 0) { const source = this.servers.find((server: ServerConfig) => server.id === option.id); if (source !== undefined) { this.state.errors.push(source.name + '：' + option.error); } } });
      this.eligible = this.servers.filter((server: ServerConfig) => {
        const option = options.find((entry) => entry.id === server.id);
        // This is the explicitly opened station. Cross-station aggregation preferences
        // must not disable its own watch hub.
        return option === undefined || (!option.hidden && !option.locked && option.error.length === 0);
      });
      const allowed = this.eligible.map((server: ServerConfig) => SourceIdentity.scope(server));
      this.state.watching = this.state.watching.filter((row: VisionRow) => allowed.indexOf(SourceIdentity.scope(row.server)) >= 0);
      this.state.watchLater = this.state.watchLater.filter((row: VisionRow) => allowed.indexOf(SourceIdentity.scope(row.server)) >= 0);
      await this.local(generation); if (!this.alive(generation)) { return; }
      // loadForAccount hides completion tombstones; read the repository's bounded envelope once
      // so an old server-side resume row cannot revive a locally completed item.
      let progress: ProgressRecordV2[] = []; let progressFailed = false;
      try { progress = await ProgressRepository.loadAll(); } catch (e) { progressFailed = true; }
      if (!this.alive(generation)) { return; }
      const selected = this.eligible.slice(0, 1);
      this.state.filterServerId = selected.length > 0 ? selected[0].id : '';
      const results: VisionRow[][] = new Array(selected.length); let cursor = 0;
      const worker = async (): Promise<void> => {
        while (cursor < selected.length && this.alive(generation)) {
          const index = cursor++; const server = selected[index]; const old = this.state.watching.filter((row: VisionRow) => SourceIdentity.scope(row.server) === SourceIdentity.scope(server));
          try { results[index] = await this.resume(server, generation, progress, progressFailed); }
          catch (e) { if (this.alive(generation)) { this.state.errors.push(server.name + '：继续观看暂时无法读取'); } results[index] = old; }
        }
      };
      await Promise.all([worker(), worker()]); if (!this.alive(generation)) { return; }
      const rows: VisionRow[] = []; results.forEach((entries: VisionRow[]) => { if (entries !== undefined) { entries.forEach((row: VisionRow) => rows.push(row)); } });
      this.state.watching = rows.sort((a: VisionRow, b: VisionRow) => b.updatedAt - a.updatedAt);
    } catch (e) { if (this.alive(generation)) { this.state.errors.push('Vision 数据暂时无法读取，请重试；已有记录已保留'); } }
    finally { if (this.alive(generation)) { this.state.busy = false; this.emit(); if (this.state.section === 1) { this.loadCalendar(); } } }
  }
  private fromRecord(record: ProgressRecordV2): MediaItem {
    const item = new MediaItem(); item.id = record.itemId; item.name = record.episodeTitle.length > 0 ? record.episodeTitle : record.title;
    item.type = record.itemType.length > 0 ? record.itemType : 'Video'; item.seriesId = record.seriesId;
    item.seriesName = record.seriesId.length > 0 ? record.title : ''; item.imageTag = record.imageTag; item.hasPrimaryImage = record.imageTag.length > 0;
    item.indexNumber = record.episodeNumber; item.indexNumberKnown = record.episodeNumber > 0;
    item.parentIndexNumber = record.seasonNumber; item.parentIndexNumberKnown = record.seasonNumber > 0;
    item.progressTicks = Math.round(record.positionMs * 10000); item.runtimeTicks = Math.round(record.durationMs * 10000); return item;
  }
  private async resume(server: ServerConfig, generation: number, records: ProgressRecordV2[], localFailed: boolean): Promise<VisionRow[]> {
    let remote: MediaItem[] = []; let remoteFailed = false;
    const localById: Map<string, ProgressRecordV2> = new Map();
    records.forEach((record: ProgressRecordV2) => {
      if (record.serverId !== server.id || record.userId !== server.userId || record.itemId.length === 0) { return; }
      const previous = localById.get(record.itemId);
      if (previous === undefined || record.updatedAt > previous.updatedAt
        || (record.updatedAt === previous.updatedAt && record.completed)) { localById.set(record.itemId, record); }
    });
    try { remote = await this.catalog(server).getResume(server, 100); } catch (e) { remoteFailed = true; }
    if (!this.alive(generation)) { return []; }
    if (remoteFailed) { this.state.errors.push(server.name + '：服务器继续观看读取失败，已显示可用本机记录'); }
    if (localFailed) { this.state.errors.push(server.name + '：本机播放记录读取失败'); }
    if (remoteFailed && localFailed) { throw new Error('resume'); }
    const rows: Map<string, VisionRow> = new Map();
    remote.forEach((item: MediaItem) => {
      if (!item.isPlayable() || item.played || item.progressTicks <= 0 || item.progressRatio() >= 0.95 || rows.has(item.id)) { return; }
      const row = new VisionRow(server, item); row.key = VisionStore.key(server, item.id); row.positionMs = item.progressTicks / 10000; row.durationMs = item.runtimeTicks / 10000; rows.set(item.id, row);
    });
    localById.forEach((record: ProgressRecordV2) => {
      if (record.completed || (record.durationMs > 0 && record.positionMs / record.durationMs >= 0.95)) { rows.delete(record.itemId); return; }
      if (record.positionMs <= 0) { return; }
      const previous = rows.get(record.itemId); const item = previous !== undefined ? previous.item : this.fromRecord(record);
      if (!item.isPlayable()) { return; } item.progressTicks = Math.round(record.positionMs * 10000); if (record.durationMs > 0) { item.runtimeTicks = Math.round(record.durationMs * 10000); }
      const row = new VisionRow(server, item); row.key = VisionStore.key(server, item.id); row.positionMs = record.positionMs; row.durationMs = item.runtimeTicks / 10000; row.updatedAt = record.updatedAt; rows.set(item.id, row);
    });
    const result: VisionRow[] = []; rows.forEach((row: VisionRow) => result.push(row)); return result;
  }
  selectSection(section: number): void {
    if (!this.active || section < 0 || section > 3) { return; } this.state.section = section; this.state.selectedPlaylistId = ''; this.calendarGeneration++;
    this.emit(); if (section === 1 && !this.state.busy) { this.loadCalendar(); }
  }
  filter(serverId: string): void { if (!this.active || (serverId.length > 0 && !this.eligible.some((server: ServerConfig) => server.id === serverId))) { return; } this.refresh(); }
  sources(): ServerConfig[] { return this.eligible.slice(); }
  playlistRows(): VisionRow[] { const list = this.state.playlists.find((entry: VisionPlaylist) => entry.id === this.state.selectedPlaylistId); return list !== undefined ? this.refRows(list.entries) : []; }
  openPlaylist(id: string): void { this.state.selectedPlaylistId = id; this.emit(); }
  private static today(): string { const now = new Date(); return now.getFullYear().toString() + '-' + (now.getMonth() + 1).toString().padStart(2, '0') + '-' + now.getDate().toString().padStart(2, '0'); }
  private async loadCalendar(): Promise<void> {
    if (!this.active || this.state.section !== 1) { return; } const generation = this.generation; const calendar = ++this.calendarGeneration;
    this.state.calendarBusy = true; this.state.calendarError = ''; this.state.calendarUnknown = false; this.emit();
    const series: VisionSeries[] = []; const keys: Set<string> = new Set();
    this.state.watchLater.concat(this.state.watching).forEach((row: VisionRow) => {
      const id = row.item.type === 'Series' ? row.item.id : row.item.seriesId; const key = SourceIdentity.scope(row.server) + '|' + id;
      if (id.length > 0 && !keys.has(key)) { keys.add(key); series.push(new VisionSeries(row.server, id)); }
    });
    const output: VisionRow[] = []; const date = VisionController.today(); let cursor = 0; let unknown = false; let failed = false;
    const worker = async (): Promise<void> => {
      while (cursor < Math.min(series.length, 20) && this.alive(generation) && calendar === this.calendarGeneration && this.state.section === 1) {
        const source = series[cursor++];
        try {
          const episodes = await this.catalog(source.server).getEpisodes(source.server, source.id, '');
          let dated = 0; episodes.forEach((item: MediaItem) => {
            if (!/^\d{4}-\d{2}-\d{2}/.test(item.premiereDate)) { return; } dated++;
            if (item.premiereDate.substring(0, 10) === date) { const row = new VisionRow(source.server, item); row.key = VisionStore.key(source.server, item.id); output.push(row); }
          }); if (episodes.length > 0 && dated === 0) { unknown = true; }
        } catch (e) { failed = true; }
      }
    };
    await Promise.all([worker(), worker()]);
    if (!this.alive(generation) || calendar !== this.calendarGeneration || this.state.section !== 1) { return; }
    this.state.calendar = output; this.state.calendarBusy = false; this.state.calendarUnknown = unknown;
    this.state.calendarError = failed ? '部分来源的剧集更新日期暂时无法读取，请刷新重试' : series.length > 20 ? '当前跟踪前 20 部剧集的更新日期' : ''; this.emit();
  }
  async canOpen(row: VisionRow): Promise<boolean> {
    const generation = this.generation; const scope = this.state.scope; const section = this.state.section;
    const rowScope = SourceIdentity.scope(row.server);
    const source = this.eligible.find((server: ServerConfig) => SourceIdentity.scope(server) === rowScope);
    if (source === undefined || !this.alive(generation)) { return false; } const options = await ServerOptions.get(source.id);
    if (!this.alive(generation) || this.state.scope !== scope || this.state.section !== section || options.hidden || options.error.length > 0) { return false; }
    const locked = await ServerOptions.isLocked(source.id);
    return this.alive(generation) && this.state.scope === scope && this.state.section === section && !locked
      && this.eligible.some((server: ServerConfig) => SourceIdentity.scope(server) === rowScope);
  }
  imageUrl(row: VisionRow): string { try { return MediaServices.imageUrl(row.server, row.item.id, 640, row.item.imageTag); } catch (e) { return ''; } }
  imageHeaders(row: VisionRow): Record<string, string> { try { return MediaServices.imageHeaders(row.server); } catch (e) { return {}; } }
  private async writableSource(): Promise<ServerConfig> {
    const source = this.eligible[0];
    if (source === undefined || !await this.canOpen(new VisionRow(source, new MediaItem()))) { throw new Error('当前服务器不可用或已锁定，请重新打开服务器'); }
    return source;
  }
  async toggleWatch(row: VisionRow): Promise<void> { const generation = this.generation; if (!await this.canOpen(row)) { throw new Error('来源不可用或已锁定，请先到服务器页解锁'); } await VisionStore.toggleWatchLater(row.server, row.item); await this.local(generation); if (this.alive(generation)) { this.emit(); } }
  async createPlaylist(name: string): Promise<string> { const generation = this.generation; const source = await this.writableSource(); const id = await VisionStore.createPlaylist(name, source); await this.local(generation); if (this.alive(generation)) { this.emit(); } return id; }
  async renamePlaylist(id: string, name: string): Promise<void> { const generation = this.generation; const source = await this.writableSource(); await VisionStore.renamePlaylist(id, name, source); await this.local(generation); if (this.alive(generation)) { this.emit(); } }
  async deletePlaylist(id: string): Promise<void> { const generation = this.generation; const source = await this.writableSource(); await VisionStore.deletePlaylist(id, source); await this.local(generation); if (this.alive(generation)) { this.emit(); } }
  async addToPlaylist(id: string, row: VisionRow): Promise<void> { const generation = this.generation; if (!await this.canOpen(row)) { throw new Error('来源不可用或已锁定'); } await VisionStore.addToPlaylist(id, row.server, row.item); await this.local(generation); if (this.alive(generation)) { this.emit(); } }
  async removeFromPlaylist(id: string, row: VisionRow): Promise<void> { const generation = this.generation; if (!await this.canOpen(row)) { throw new Error('来源不可用或已锁定'); } await VisionStore.removeFromPlaylist(id, row.key, row.server); await this.local(generation); if (this.alive(generation)) { this.emit(); } }
}
