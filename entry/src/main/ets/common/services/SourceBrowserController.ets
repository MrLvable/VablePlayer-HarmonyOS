import { ServerConfig, Library, MediaItem } from '../Models';
import { MediaCatalog } from './MediaCatalog';
import { MediaServiceRegistry } from './MediaServiceRegistry';
import { SourceIdentity } from './SourceIdentity';
import { IptvCatalog, IptvProgramme } from './IptvCatalog';
import { DirectSourceHttp } from './DirectSourceHttp';
import { LocalAccess } from './LocalAccess';

export class SourceCrumb { id: string = ''; name: string = ''; constructor(id: string, name: string) { this.id = id; this.name = name; } }
export class SourceBrowserState {
  scope: string = ''; views: Library[] = []; trail: SourceCrumb[] = []; items: MediaItem[] = [];
  busy: boolean = false; error: string = ''; notice: string = ''; query: string = ''; grid: boolean = false;
  sort: string = 'name'; more: boolean = false; favoriteBusy: string[] = [];
  epgChannel: string = ''; epgName: string = ''; epgBusy: boolean = false; epgError: string = ''; programmes: IptvProgramme[] = [];
}
interface CancellableCatalog extends MediaCatalog { cancel: () => void; }
/** Plain lifecycle controller; its only UI publication is coalesced after a 16ms frame. */
export class SourceBrowserController {
  private state: SourceBrowserState = new SourceBrowserState();
  private server: ServerConfig | null = null; private catalog: MediaCatalog | null = null;
  private mounted: boolean = false; private active: boolean = false; private visible: boolean = true;
  private generation: number = 0; private epgGeneration: number = 0; private timer: number = -1;
  private cursor: number = 0; private retryTrail: SourceCrumb[] = []; private searchMode: boolean = false;
  private retrySearch: string = '';
  private publish: (state: SourceBrowserState) => void;
  constructor(publish: (state: SourceBrowserState) => void) { this.publish = publish; }
  static scope(server: ServerConfig): string {
    return SourceIdentity.scope(server) + SourceIdentity.key([server.sourceUrl, server.epgUrl, server.authMode, server.token, server.password].join('\u0000'));
  }
  private copyServer(s: ServerConfig): ServerConfig {
    const out = new ServerConfig(s.id, s.kind, s.name, s.host, s.port, s.username, s.token, s.userId, s.serverName, s.version, s.nativeToken);
    out.scheme = s.scheme; out.basePath = s.basePath; out.rootPath = s.rootPath; out.sourceUrl = s.sourceUrl; out.epgUrl = s.epgUrl;
    out.authMode = s.authMode; out.connectionMode = s.connectionMode; out.domain = s.domain; out.shareName = s.shareName;
    out.clientId = s.clientId; out.credentialRef = s.credentialRef; out.password = s.password; out.clientSecret = s.clientSecret; out.refreshToken = s.refreshToken;
    return out;
  }
  private snapshot(): SourceBrowserState {
    const s = this.state; const out = new SourceBrowserState();
    out.scope = s.scope; out.views = s.views.slice(); out.trail = s.trail.slice(); out.items = s.items.slice();
    out.busy = s.busy; out.error = s.error; out.notice = s.notice; out.query = s.query; out.grid = s.grid; out.sort = s.sort;
    out.more = s.more; out.favoriteBusy = s.favoriteBusy.slice(); out.epgChannel = s.epgChannel; out.epgName = s.epgName;
    out.epgBusy = s.epgBusy; out.epgError = s.epgError; out.programmes = s.programmes.slice(); return out;
  }
  private alive(gen: number): boolean { return this.mounted && this.active && this.visible && gen === this.generation; }
  private emit(): void {
    if (this.timer >= 0) { return; }
    const gen = this.generation;
    this.timer = setTimeout(() => { this.timer = -1; if (this.alive(gen)) { this.publish(this.snapshot()); } }, 16);
  }
  private invalidate(): number {
    this.generation++; this.epgGeneration++;
    this.state.favoriteBusy = [];
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if (this.catalog !== null) {
      const cancellable = this.catalog as CancellableCatalog;
      if (typeof cancellable.cancel === 'function') { cancellable.cancel(); }
    }
    return this.generation;
  }
  configure(server: ServerConfig, active: boolean): void {
    const scope = SourceBrowserController.scope(server); const changed = scope !== this.state.scope;
    const wasActive = this.active; this.mounted = true; this.active = active;
    if (changed) {
      this.invalidate(); this.server = this.copyServer(server); this.catalog = null;
      const grid = this.state.grid; this.state = new SourceBrowserState(); this.state.scope = scope; this.state.grid = grid;
      this.cursor = 0; this.retryTrail = []; this.searchMode = false;
      try { this.catalog = MediaServiceRegistry.forServer(server).catalog; }
      catch (e) { this.state.error = this.message(e as Object); if (active && this.visible) { this.emit(); } return; }
    }
    if (!active) { this.invalidate(); return; }
    if (this.catalog === null) { if (this.visible) { this.emit(); } return; }
    if (this.visible && (changed || !wasActive)) { this.loadRoots(); }
  }
  setVisible(visible: boolean): void {
    if (visible === this.visible) { return; } this.visible = visible;
    if (!visible) { this.invalidate(); return; }
    if (this.mounted && this.active) { if (this.catalog === null) { this.emit(); } else { this.loadRoots(); } }
  }
  destroy(): void { this.mounted = false; this.active = false; this.invalidate(); this.catalog = null; this.server = null; }
  private message(error: Object): string { const text = (error as Error).message; return typeof text === 'string' && text.length > 0 ? text : '来源读取失败，请重试'; }
  private async loadRoots(): Promise<void> {
    if (!this.mounted || !this.active || !this.visible || this.catalog === null || this.server === null) { return; }
    const gen = this.invalidate(); const catalog = this.catalog; const server = this.server;
    this.state.busy = true; this.state.error = ''; this.emit();
    try {
      const views = await catalog.getViews(server); if (!this.alive(gen)) { return; }
      this.state.views = views;
      if (views.length === 0) { this.state.items = []; this.state.trail = []; this.state.more = false; this.state.busy = false; this.emit(); return; }
      const previous = this.state.trail[0]; const view = previous === undefined ? views[0] : views.find((entry: Library) => entry.id === previous.id) || views[0];
      const trail = previous !== undefined && previous.id === view.id ? this.state.trail.slice() : [new SourceCrumb(view.id, view.name)];
      await this.loadFolder(trail);
    } catch (e) { if (this.alive(gen)) { this.state.busy = false; this.state.error = this.message(e as Object); this.emit(); } }
  }
  selectRoot(view: Library): void { this.loadFolder([new SourceCrumb(view.id, view.name)]); }
  enter(item: MediaItem): void { if (item.isFolder()) { this.loadFolder(this.state.trail.concat([new SourceCrumb(item.id, item.name)])); } }
  back(index: number): void { if (index >= 0 && index < this.state.trail.length) { this.loadFolder(this.state.trail.slice(0, index + 1)); } }
  retry(): void { if (this.retrySearch.length > 0) { this.search(this.retrySearch); } else if (this.retryTrail.length > 0) { this.loadFolder(this.retryTrail); } else { this.loadRoots(); } }
  private async loadFolder(trail: SourceCrumb[]): Promise<void> {
    if (!this.mounted || !this.active || !this.visible || this.catalog === null || this.server === null || trail.length === 0) { return; }
    const gen = this.invalidate(); const catalog = this.catalog; const server = this.server; this.retryTrail = trail.slice(); this.retrySearch = '';
    this.state.busy = true; this.state.error = ''; this.state.epgChannel = ''; this.state.programmes = []; this.emit();
    try {
      const items = await catalog.getItems(server, trail[trail.length - 1].id, 0, 200, false);
      if (!this.alive(gen)) { return; }
      this.cursor = items.length; this.state.items = items; this.state.trail = trail; this.state.more = items.length === 200;
      this.state.busy = false; this.state.query = ''; this.searchMode = false;
      this.state.notice = server.kind === 'local' || (server.kind === 'custom' && server.sourceUrl.startsWith('file://')) ? LocalAccess.permissionNotice(server.sourceUrl) : '';
      this.sortItems(); this.emit();
    } catch (e) { if (this.alive(gen)) { this.state.busy = false; this.state.error = this.message(e as Object); this.emit(); } }
  }
  async loadMore(): Promise<void> {
    if (!this.mounted || !this.active || !this.visible || this.state.busy || !this.state.more || this.searchMode || this.catalog === null || this.server === null) { return; }
    if (this.cursor >= 5000) { this.state.notice = '当前已加载 5000 项，请进入子目录或搜索。'; this.state.more = false; this.emit(); return; }
    const gen = this.generation; const catalog = this.catalog; const server = this.server;
    const parent = this.state.trail[this.state.trail.length - 1]; if (parent === undefined) { return; }
    this.state.busy = true; this.emit();
    try {
      const rows = await catalog.getItems(server, parent.id, this.cursor, 200, false); if (!this.alive(gen)) { return; }
      if (rows.some((item: MediaItem) => this.state.items.some((old: MediaItem) => item.id === old.id))) { throw new Error('目录在分页期间发生变化，请刷新后重试'); }
      this.cursor += rows.length; this.state.items = this.state.items.concat(rows); this.state.more = rows.length === 200;
      this.state.busy = false; this.state.error = ''; this.sortItems(); this.emit();
    } catch (e) { if (this.alive(gen)) { this.state.busy = false; this.state.error = this.message(e as Object); this.emit(); } }
  }
  async search(query: string): Promise<void> {
    if (query.trim().length === 0) { this.retrySearch = ''; if (this.state.trail.length > 0) { this.loadFolder(this.state.trail.slice()); } else { this.loadRoots(); } return; }
    if (!this.mounted || !this.active || !this.visible || this.catalog === null || this.server === null) { return; }
    const gen = this.invalidate(); const catalog = this.catalog; const server = this.server;
    this.retrySearch = query.trim();
    this.state.busy = true; this.state.error = ''; this.state.query = query.trim(); this.emit();
    try {
      const rows = await catalog.search(server, query.trim(), 5000); if (!this.alive(gen)) { return; }
      this.state.items = rows; this.state.more = false; this.state.busy = false; this.searchMode = true;
      this.state.notice = rows.length === 5000 ? '搜索已达到 5000 项上限，请缩小关键字。' : ''; this.sortItems(); this.emit();
    } catch (e) { if (this.alive(gen)) { this.state.busy = false; this.state.error = this.message(e as Object); this.emit(); } }
  }
  setGrid(grid: boolean): void { this.state.grid = grid; this.emit(); }
  explainFile(_item: MediaItem): void { this.state.notice = '此条目不是支持的视频文件；文件目录不会把所有文件伪装成影片。'; this.emit(); }
  static time(item: MediaItem): number { return Date.parse(item.modifiedAt || item.createdAt || item.premiereDate); }
  hasTimes(): boolean {
    const files = this.state.items.filter((item: MediaItem) => !item.isFolder());
    return files.length > 0 && files.every((item: MediaItem) => Number.isFinite(SourceBrowserController.time(item)));
  }
  setSort(sort: string): void {
    if (sort !== 'name' && sort !== 'name-desc' && sort !== 'time') { return; }
    if (sort === 'time' && !this.hasTimes()) { this.state.notice = '部分条目缺少真实日期，时间排序不可用。'; this.emit(); return; }
    this.state.sort = sort; this.sortItems(); this.emit();
  }
  private sortItems(): void {
    if (this.state.sort === 'time' && !this.hasTimes()) { this.state.sort = 'name'; }
    this.state.items = this.state.items.slice().sort((a: MediaItem, b: MediaItem) => {
      if (a.isFolder() !== b.isFolder()) { return a.isFolder() ? -1 : 1; }
      if (a.isFolder() && b.isFolder()) { return a.name.localeCompare(b.name); }
      if (this.state.sort === 'time') { return SourceBrowserController.time(b) - SourceBrowserController.time(a); }
      return a.name.localeCompare(b.name) * (this.state.sort === 'name-desc' ? -1 : 1);
    });
  }
  async toggleFavorite(item: MediaItem): Promise<void> {
    if (this.state.favoriteBusy.indexOf(item.id) >= 0 || this.catalog === null || this.server === null || !this.active || !this.visible) { return; }
    const gen = this.generation; const catalog = this.catalog; const server = this.server;
    this.state.favoriteBusy = this.state.favoriteBusy.concat([item.id]); this.emit();
    try {
      const favorite = item.favoriteKnown ? item.isFavorite : await catalog.isFavorite(server, item.id);
      if (!this.alive(gen)) { return; }
      if (favorite) { await catalog.removeFavorite(server, item.id); } else { await catalog.addFavorite(server, item.id); }
      if (!this.alive(gen)) { return; }
      // Update a new item instance: never mutate an item already published into ArkUI State during rendering.
      const updated = new MediaItem();
      updated.id = item.id; updated.name = item.name; updated.type = item.type; updated.path = item.path; updated.container = item.container;
      updated.imageTag = item.imageTag; updated.backdropTag = item.backdropTag; updated.hasPrimaryImage = item.hasPrimaryImage;
      updated.createdAt = item.createdAt; updated.modifiedAt = item.modifiedAt; updated.premiereDate = item.premiereDate;
      updated.runtimeTicks = item.runtimeTicks; updated.progressTicks = item.progressTicks; updated.played = item.played;
      updated.year = item.year; updated.overview = item.overview; updated.rating = item.rating; updated.isFavorite = !favorite; updated.favoriteKnown = true;
      this.state.items = this.state.items.map((row: MediaItem) => row.id === updated.id ? updated : row); this.state.notice = favorite ? '已从本机收藏移除' : '已加入本机收藏';
    } catch (e) { if (this.alive(gen)) { this.state.notice = '收藏失败：' + this.message(e as Object); } }
    finally { if (this.alive(gen)) { this.state.favoriteBusy = this.state.favoriteBusy.filter((id: string) => id !== item.id); this.emit(); } }
  }
  async loadEpg(item: MediaItem): Promise<void> {
    if (this.server === null || this.catalog === null || this.server.kind !== 'iptv' || !this.active || !this.visible) { return; }
    const gen = this.generation; const epgGen = ++this.epgGeneration; const catalog = this.catalog as IptvCatalog; const server = this.server;
    this.state.epgChannel = item.id; this.state.epgName = item.name; this.state.epgBusy = true; this.state.epgError = ''; this.state.programmes = []; this.emit();
    try {
      const now = Date.now(); const rows = await catalog.getEpg(server, item.id, now - 86400000, now + 86400000);
      if (!this.alive(gen) || epgGen !== this.epgGeneration) { return; }
      this.state.programmes = rows; this.state.epgBusy = false; this.emit();
    } catch (e) { if (this.alive(gen) && epgGen === this.epgGeneration) { this.state.epgError = this.message(e as Object); this.state.epgBusy = false; this.emit(); } }
  }
  closeEpg(): void { this.epgGeneration++; this.state.epgChannel = ''; this.state.programmes = []; this.emit(); }
  imageUrl(item: MediaItem): string {
    if (this.catalog === null || this.server === null || item.imageTag.length === 0) { return ''; }
    try { return this.catalog.imageUrl(this.server, item.id, 480, item.imageTag); } catch (e) { return ''; }
  }
  imageHeaders(item: MediaItem): Record<string, string> {
    if (this.catalog === null || this.server === null) { return {}; }
    const address = this.imageUrl(item); if (address.length === 0) { return {}; }
    try {
      if (this.server.sourceUrl.startsWith('file://')) { return {}; }
      const origin = /^https?:\/\//i.test(this.server.sourceUrl) ? this.server.sourceUrl : this.server.baseUrl();
      return DirectSourceHttp.sameOrigin(origin, address) ? this.catalog.imageHeaders(this.server) : {};
    } catch (e) { return {}; }
  }
}
