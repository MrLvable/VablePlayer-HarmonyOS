import { ServerConfig, Library, MediaItem, ItemDetail, MediaSource, PlaybackInfo } from '../Models';
import { MediaCatalog } from './MediaCatalog';
import { DirectCatalogBase } from './DirectCatalogBase';
import { DirectSourceHttp } from './DirectSourceHttp';
import { SourceXml, SourceXmlNode } from './SourceXml';
import { SourceIdentity } from './SourceIdentity';

export class IptvProgramme {
  channelId: string = '';
  title: string = '';
  description: string = '';
  startMs: number = 0;
  endMs: number = 0;
}
class IptvEntry {
  item: MediaItem = new MediaItem();
  address: string = '';
  group: string = '';
  tvgId: string = '';
  headers: Record<string, string> = {};
  isHls: boolean = false;
  live: boolean = true;
  blocked: string = '';
}
class IptvSnapshot { entries: IptvEntry[] = []; loaded: number = 0; address: string = ''; }
class IptvGuide { programmes: IptvProgramme[] = []; loaded: number = 0; }

/** Extended M3U channel catalog. HLS media/master playlists remain a single playable source. */
export class IptvCatalog extends DirectCatalogBase implements MediaCatalog {
  private transport: DirectSourceHttp = new DirectSourceHttp();
  private static playlists: Map<string, IptvSnapshot> = new Map();
  private static loading: Map<string, Promise<IptvSnapshot>> = new Map();
  private static guides: Map<string, IptvGuide> = new Map();
  cancel(): void { this.transport.cancel(); }
  private scope(server: ServerConfig): string { return SourceIdentity.scope(server) + '|' + SourceIdentity.key(server.sourceUrl + '\u0000' + server.epgUrl + '\u0000' + server.token + '\u0000' + server.authMode); }
  private source(server: ServerConfig): string {
    if (server.sourceUrl.trim().length === 0) { throw new Error('请填写 IPTV M3U 或 HLS 来源地址'); }
    return DirectSourceHttp.resolve(server.sourceUrl, server.sourceUrl);
  }
  headers(server: ServerConfig): Record<string, string> {
    const headers: Record<string, string> = {};
    if (server.authMode !== 'anonymous' && server.token.length > 0) { headers['Authorization'] = server.token; }
    return headers;
  }
  private headersFor(server: ServerConfig, address: string): Record<string, string> {
    // Playlist credentials never cross to an unrelated channel/logo/EPG host.
    return DirectSourceHttp.sameOrigin(this.source(server), address) ? this.headers(server) : {};
  }
  private splitInfo(text: string): number {
    let quoted = false;
    for (let i = 0; i < text.length; i++) { if (text[i] === '"') { quoted = !quoted; } else if (text[i] === ',' && !quoted) { return i; } }
    return -1;
  }
  private attributes(text: string): Record<string, string> {
    const values: Record<string, string> = {}; const expression = /([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|([^\s,]+))/g;
    let match: RegExpExecArray | null = expression.exec(text);
    while (match !== null) { values[match[1].toLowerCase()] = match[2] !== undefined ? match[2] : match[3]; match = expression.exec(text); }
    return values;
  }
  private parse(server: ServerConfig, text: string, address: string): IptvSnapshot {
    const lines = text.replace(/^\ufeff/, '').split(/\r?\n/).map((line: string) => line.trim());
    if (lines.length === 0 || !/^#EXTM3U(?:\s|$)/.test(lines[0])) { throw new Error('来源不是有效的 Extended M3U/HLS 播放列表'); }
    const snapshot = new IptvSnapshot(); snapshot.loaded = Date.now(); snapshot.address = address;
    if (lines.some((line: string) => /^#EXT-X-(TARGETDURATION|MEDIA-SEQUENCE|STREAM-INF|I-FRAME-STREAM-INF|MEDIA):/.test(line))) {
      const entry = new IptvEntry(); entry.item.id = 'iptv:hls:' + SourceIdentity.key(address); entry.item.name = server.name.length > 0 ? server.name : 'HLS 直播';
      entry.item.container = 'm3u8'; entry.item.path = address; entry.address = address; entry.isHls = true;
      entry.live = !lines.some((line: string) => line === '#EXT-X-ENDLIST' || /^#EXT-X-PLAYLIST-TYPE:VOD$/i.test(line));
      entry.item.type = entry.live ? 'Channel' : 'Video';
      entry.headers = this.headersFor(server, address); snapshot.entries = [entry]; return snapshot;
    }
    let attributes: Record<string, string> = {}; let name = ''; let group = ''; let pending = false;
    let extra: Record<string, string> = {}; let blocked = ''; const ids: string[] = [];
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i]; if (line.length === 0) { continue; }
      if (line.startsWith('#EXTINF:')) {
        if (pending) { throw new Error('IPTV 频道缺少播放地址'); }
        const comma = this.splitInfo(line); if (comma < 0) { throw new Error('IPTV EXTINF 缺少频道标题'); }
        attributes = this.attributes(line.substring(8, comma)); name = line.substring(comma + 1).trim(); group = attributes['group-title'] !== undefined ? attributes['group-title'] : '';
        extra = {}; blocked = ''; pending = true; continue;
      }
      if (line.startsWith('#EXTGRP:') && pending && group.length === 0) { group = line.substring(8).trim(); continue; }
      if (line.startsWith('#EXTVLCOPT:') && pending) {
        const value = line.substring(11); const equals = value.indexOf('='); const key = equals >= 0 ? value.substring(0, equals).toLowerCase() : '';
        if (key === 'http-user-agent' || key === 'http-referrer') { extra[key === 'http-user-agent' ? 'User-Agent' : 'Referer'] = value.substring(equals + 1); }
        else { blocked = '此频道包含暂不支持的播放选项'; } continue;
      }
      if (/^#KODIPROP:.*(?:license|drm|inputstream)/i.test(line) && pending) { blocked = '此频道需要 DRM 或额外播放插件，当前不支持'; continue; }
      if (line.startsWith('#')) { continue; }
      if (!pending) { throw new Error('IPTV 频道地址缺少对应 EXTINF'); }
      const entry = new IptvEntry(); entry.address = DirectSourceHttp.resolve(address, line); entry.isHls = DirectSourceHttp.extension(entry.address) === 'm3u8';
      entry.tvgId = attributes['tvg-id'] !== undefined ? attributes['tvg-id'] : ''; entry.group = group; entry.blocked = blocked;
      entry.item.name = name.length > 0 ? name : attributes['tvg-name'] !== undefined ? attributes['tvg-name'] : '';
      if (entry.item.name.length === 0) { throw new Error('IPTV 频道缺少标题'); }
      entry.item.id = 'iptv:channel:' + SourceIdentity.key([entry.address, entry.tvgId, entry.group, entry.item.name].join('\u0000'));
      if (ids.indexOf(entry.item.id) >= 0) { throw new Error('IPTV 列表包含完全重复的频道'); } ids.push(entry.item.id);
      entry.item.type = 'Channel'; entry.item.path = entry.address; entry.item.container = entry.isHls ? 'm3u8' : DirectSourceHttp.extension(entry.address);
      entry.item.indexNumber = snapshot.entries.length + 1; entry.item.indexNumberKnown = true;
      const logo = attributes['tvg-logo'];
      if (logo !== undefined && logo.length > 0) {
        entry.item.imageTag = DirectSourceHttp.resolve(address, logo); entry.item.hasPrimaryImage = true;
      }
      entry.headers = this.headersFor(server, entry.address); Object.keys(extra).forEach((key: string) => { entry.headers[key] = extra[key]; });
      snapshot.entries.push(entry); pending = false;
      if (snapshot.entries.length > 5000) { throw new Error('IPTV 频道超过 5000 项，请缩小列表'); }
    }
    if (pending) { throw new Error('IPTV 最后一个频道缺少播放地址'); }
    if (snapshot.entries.length === 0) { throw new Error('IPTV 列表中没有可读取的频道'); }
    return snapshot;
  }
  private async fetchList(server: ServerConfig): Promise<IptvSnapshot> {
    const response = await this.transport.request(this.source(server), 'GET', this.headers(server), '', 2097152);
    if (response.status !== 200) { throw new Error('IPTV 列表读取失败（HTTP ' + response.status.toString() + '）'); }
    const snapshot = this.parse(server, response.text, response.address); this.remember(server, snapshot.entries.map((entry: IptvEntry) => entry.item)); return snapshot;
  }
  private async list(server: ServerConfig, refresh: boolean = false): Promise<IptvSnapshot> {
    const key = this.scope(server); const cached = IptvCatalog.playlists.get(key);
    if (!refresh && cached !== undefined && Date.now() - cached.loaded < 60000) { return cached; }
    const previous = IptvCatalog.loading.get(key); if (previous !== undefined) { return previous; }
    const work = this.fetchList(server); IptvCatalog.loading.set(key, work);
    try {
      const snapshot = await work; IptvCatalog.playlists.set(key, snapshot);
      if (IptvCatalog.playlists.size > 8) {
        let first = ''; IptvCatalog.playlists.forEach((_entry: IptvSnapshot, id: string) => { if (first.length === 0) { first = id; } }); IptvCatalog.playlists.delete(first);
      }
      return snapshot;
    } finally { if (IptvCatalog.loading.get(key) === work) { IptvCatalog.loading.delete(key); } }
  }
  async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    if (server.authMode === 'anonymous') { server.token = ''; }
    else if (password.length > 0 || (server.token.length === 0 && server.username.length > 0)) { server.token = DirectSourceHttp.basic(server.username, password); }
    await this.list(server, true); server.serverName = server.name.length > 0 ? server.name : 'IPTV'; return server;
  }
  async getViews(server: ServerConfig): Promise<Library[]> {
    const snapshot = await this.list(server); const groups: string[] = [];
    snapshot.entries.forEach((entry: IptvEntry) => { if (entry.group.length > 0 && groups.indexOf(entry.group) < 0) { groups.push(entry.group); } });
    return [new Library('iptv:all', '全部频道', 'channels')].concat(groups.map((group: string) => new Library('iptv:group:' + encodeURIComponent(group), group, 'channels')));
  }
  async getItems(server: ServerConfig, parent: string, start: number, limit: number, _recursive: boolean): Promise<MediaItem[]> {
    if (!Number.isInteger(start) || start < 0 || !Number.isInteger(limit) || limit < 1 || limit > 5000) { throw new Error('IPTV 分页范围无效'); }
    const entries = (await this.list(server)).entries;
    if (parent !== 'iptv:all' && !parent.startsWith('iptv:group:')) { throw new Error('IPTV 频道分组无效'); }
    const group = parent.startsWith('iptv:group:') ? decodeURIComponent(parent.substring(11)) : '';
    return entries.filter((entry: IptvEntry) => parent === 'iptv:all' || entry.group === group).slice(start, start + limit).map((entry: IptvEntry) => entry.item);
  }
  getLatest(server: ServerConfig, parent: string, limit: number): Promise<MediaItem[]> { return this.getItems(server, parent, 0, limit, false); }
  async search(server: ServerConfig, query: string, limit: number): Promise<MediaItem[]> {
    const needle = query.trim().toLowerCase(); if (needle.length === 0) { return []; }
    return (await this.list(server)).entries.filter((entry: IptvEntry) => entry.item.name.toLowerCase().indexOf(needle) >= 0).slice(0, limit).map((entry: IptvEntry) => entry.item);
  }
  private async entry(server: ServerConfig, id: string): Promise<IptvEntry> {
    const entry = (await this.list(server)).entries.find((value: IptvEntry) => value.item.id === id);
    if (entry === undefined) { throw new Error('此频道已不在当前 IPTV 列表中'); } return entry;
  }
  async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const entry = await this.entry(server, id); const detail = new ItemDetail(); detail.item = entry.item;
    const source = new MediaSource(); source.id = entry.item.id; source.container = entry.item.container; detail.sources = [source]; return detail;
  }
  async playback(server: ServerConfig, id: string, selected: string): Promise<PlaybackInfo> {
    const entry = await this.entry(server, id);
    if (selected.length > 0 && selected !== id) { throw new Error('IPTV 视频源标识不匹配'); }
    if (entry.blocked.length > 0) { throw new Error(entry.blocked); }
    const info = new PlaybackInfo(); info.url = entry.address; info.mediaSourceId = id; info.isHls = entry.isHls; info.isLive = entry.live; info.headers = entry.headers; return info;
  }
  stream(server: ServerConfig, id: string): string {
    const snapshot = IptvCatalog.playlists.get(this.scope(server)); const entry = snapshot !== undefined ? snapshot.entries.find((value: IptvEntry) => value.item.id === id) : undefined;
    if (entry === undefined) { throw new Error('请先读取 IPTV 播放信息'); } return entry.address;
  }
  async adjacentChannel(server: ServerConfig, id: string, direction: number): Promise<MediaItem | null> {
    if (direction !== 1 && direction !== -1) { throw new Error('频道切换方向无效'); }
    const entries = (await this.list(server)).entries; const index = entries.findIndex((entry: IptvEntry) => entry.item.id === id);
    if (index < 0) { throw new Error('当前频道已不在列表中'); } const next = index + direction; return next >= 0 && next < entries.length ? entries[next].item : null;
  }
  imageUrl(_server: ServerConfig, _id: string, _width: number, tag: string): string { return tag.length > 0 ? DirectSourceHttp.resolve(tag, tag) : ''; }
  // Public logos may live on other hosts; no playlist Authorization is supplied to images.
  imageHeaders(_server: ServerConfig): Record<string, string> { return {}; }
  static xmltvTime(value: string): number {
    const match = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?$/.exec(value.trim());
    if (match === null) { throw new Error('XMLTV 节目时间格式无效'); }
    const year = Number(match[1]); const month = Number(match[2]); const day = Number(match[3]); const hour = Number(match[4]); const minute = Number(match[5]); const second = Number(match[6]);
    const local = Date.UTC(year, month - 1, day, hour, minute, second); const checked = new Date(local);
    if (year < 1900 || checked.getUTCFullYear() !== year || checked.getUTCMonth() !== month - 1 || checked.getUTCDate() !== day || hour > 23 || minute > 59 || second > 59) { throw new Error('XMLTV 节目日期无效'); }
    const hours = match[8] !== undefined ? Number(match[8]) : 0; const minutes = match[9] !== undefined ? Number(match[9]) : 0;
    if (hours > 23 || minutes > 59) { throw new Error('XMLTV 时区无效'); }
    return local - (match[7] === '-' ? -1 : 1) * (hours * 60 + minutes) * 60000;
  }
  async getEpg(server: ServerConfig, channelId: string, startMs: number, endMs: number): Promise<IptvProgramme[]> {
    if (server.epgUrl.length === 0) { throw new Error('尚未配置 XMLTV 节目单地址'); }
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs || endMs - startMs > 604800000) { throw new Error('节目单查询范围无效'); }
    const entry = await this.entry(server, channelId);
    if (entry.tvgId.length === 0) { throw new Error('此频道未提供 tvg-id，无法准确匹配节目单'); }
    const key = this.scope(server); let guide = IptvCatalog.guides.get(key);
    if (guide === undefined || Date.now() - guide.loaded > 300000) {
      const address = DirectSourceHttp.resolve(this.source(server), server.epgUrl);
      const response = await this.transport.request(address, 'GET', this.headersFor(server, address), '', 6291456);
      if (response.status !== 200) { throw new Error('XMLTV 节目单读取失败（HTTP ' + response.status.toString() + '）'); }
      const xml = SourceXml.parse(response.text); if (xml.local !== 'tv' || xml.namespace.length > 0) { throw new Error('不是有效的 XMLTV 节目单'); }
      const incomingGuide = new IptvGuide(); incomingGuide.loaded = Date.now();
      xml.all('programme').forEach((node: SourceXmlNode) => {
        const channel = node.attributes['channel']; const start = node.attributes['start']; const stop = node.attributes['stop'];
        if (typeof channel !== 'string' || typeof start !== 'string' || typeof stop !== 'string') { throw new Error('XMLTV 节目缺少频道或明确起止时间'); }
        const programme = new IptvProgramme(); programme.channelId = channel; programme.startMs = IptvCatalog.xmltvTime(start); programme.endMs = IptvCatalog.xmltvTime(stop);
        if (programme.endMs <= programme.startMs) { throw new Error('XMLTV 节目结束时间无效'); }
        programme.title = node.field('title'); programme.description = node.field('desc'); incomingGuide.programmes.push(programme);
      });
      guide = incomingGuide; IptvCatalog.guides.set(key, guide);
      if (IptvCatalog.guides.size > 8) {
        let first = ''; IptvCatalog.guides.forEach((_entry: IptvGuide, id: string) => { if (first.length === 0) { first = id; } }); IptvCatalog.guides.delete(first);
      }
    }
    return guide.programmes.filter((programme: IptvProgramme) => programme.channelId === entry.tvgId && programme.startMs < endMs && programme.endMs > startMs)
      .sort((a: IptvProgramme, b: IptvProgramme) => a.startMs - b.startMs);
  }
}
