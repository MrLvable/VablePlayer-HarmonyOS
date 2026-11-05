import { MediaItem, MediaSource, MediaStream } from '../Models';
import { DirectSourceHttp } from './DirectSourceHttp';
import { LocalAccess } from './LocalAccess';

interface ManifestFolder { id: string; name: string; parentId?: string; }
interface ManifestSubtitle { id: string; url: string; language?: string; label?: string; format?: string; }
interface ManifestItem {
  id: string; name: string; parentId?: string; streamURL: string; type?: string; posterURL?: string; backdropURL?: string;
  overview?: string; year?: number; durationSeconds?: number; createdAt?: string; modifiedAt?: string; premiereDate?: string;
  sizeBytes?: number; width?: number; height?: number; headers?: Record<string, string>; subtitles?: ManifestSubtitle[];
}
interface ManifestDocument { version: number; name?: string; folders?: ManifestFolder[]; items: ManifestItem[]; }
export class CustomEntry {
  item: MediaItem = new MediaItem(); parentId: string = ''; address: string = ''; headers: Record<string, string> = {};
  subtitles: ManifestSubtitle[] = []; source: MediaSource = new MediaSource(); live: boolean = false;
}
export class CustomSnapshot {
  name: string = '自定义媒体库'; address: string = ''; local: boolean = false; loaded: number = 0;
  folders: Map<string, MediaItem> = new Map(); parents: Map<string, string> = new Map(); entries: Map<string, CustomEntry> = new Map();
}
/** App-defined v1 format, not an invented external media-server standard. */
export class CustomManifest {
  static folderId(id: string): string { return id.length === 0 ? 'custom:root' : 'custom:folder:' + encodeURIComponent(id); }
  static itemId(id: string): string { return 'custom:item:' + encodeURIComponent(id); }
  private static text(value: string | undefined, field: string, maximum: number, required: boolean = false): string {
    if (value === undefined && !required) { return ''; }
    if (typeof value !== 'string' || value.length > maximum || /\x00/.test(value) || (required && value.trim().length === 0)) {
      throw new Error('JSON 媒体库字段无效：' + field);
    }
    return value;
  }
  private static id(value: string): string { return CustomManifest.text(value, 'id', 128, true); }
  private static date(value: string | undefined, field: string): string {
    if (value === undefined) { return ''; }
    if (typeof value !== 'string' || value.length > 40 || !Number.isFinite(Date.parse(value))) { throw new Error('JSON 日期无效：' + field); }
    return value;
  }
  private static nonnegative(value: number | undefined, field: string, maximum: number, integer: boolean = false): number {
    if (value === undefined) { return 0; }
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > maximum || (integer && !Number.isSafeInteger(value))) {
      throw new Error('JSON 数值无效：' + field);
    }
    return value;
  }
  private static address(base: string, href: string, local: boolean): string {
    CustomManifest.text(href, 'URL', 8192, true);
    if (local && href.startsWith('file://')) { return LocalAccess.validate(href); }
    if (local && !/^https?:\/\//i.test(href)) { throw new Error('本地 JSON 的资源请填写完整 HTTP(S) 地址；本地文件 URI 仍须独立授权'); }
    return DirectSourceHttp.resolve(base, href);
  }
  private static headers(raw?: Record<string, string>): Record<string, string> {
    const output: Record<string, string> = {};
    if (raw === undefined) { return output; }
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).length > 16) { throw new Error('JSON 播放请求头无效'); }
    Object.keys(raw).forEach((name: string) => {
      if (!/^(authorization|user-agent|referer|accept|origin|x-[a-z0-9-]+)$/i.test(name) || typeof raw[name] !== 'string'
        || raw[name].length > 4096 || /[\r\n\x00]/.test(raw[name])) { throw new Error('JSON 播放请求头不受支持或格式无效'); }
      output[name.toLowerCase()] = raw[name];
    }); return output;
  }
  static parse(text: string, base: string, local: boolean, inheritedHeaders: Record<string, string>): CustomSnapshot {
    let doc: ManifestDocument;
    try { doc = JSON.parse(text.replace(/^\ufeff/, '')) as ManifestDocument; } catch (e) { throw new Error('JSON 媒体库解析失败'); }
    if (doc === null || typeof doc !== 'object' || Array.isArray(doc) || doc.version !== 1 || !Array.isArray(doc.items)
      || (doc.folders !== undefined && !Array.isArray(doc.folders))) { throw new Error('JSON 媒体库须使用本应用 version:1 格式'); }
    const folders = doc.folders !== undefined ? doc.folders : [];
    if (folders.length + doc.items.length > 5000) { throw new Error('JSON 媒体库超过 5000 项上限'); }
    const snapshot = new CustomSnapshot(); snapshot.address = base; snapshot.local = local; snapshot.loaded = Date.now();
    snapshot.name = CustomManifest.text(doc.name, 'name', 200) || snapshot.name;
    const seen: string[] = [];
    folders.forEach((folder: ManifestFolder) => {
      if (folder === null || typeof folder !== 'object') { throw new Error('JSON 文件夹条目无效'); }
      const id = CustomManifest.id(folder.id);
      if (seen.indexOf(id) >= 0) { throw new Error('JSON 媒体库 ID 重复'); } seen.push(id);
      const item = new MediaItem(); item.id = CustomManifest.folderId(id); item.name = CustomManifest.text(folder.name, 'folder.name', 300, true); item.type = 'Folder';
      snapshot.folders.set(id, item); snapshot.parents.set(id, CustomManifest.text(folder.parentId, 'parentId', 128));
    });
    snapshot.parents.forEach((_parent: string, id: string) => {
      const chain: string[] = [id]; let parent = snapshot.parents.get(id) || '';
      while (parent.length > 0) {
        if (!snapshot.folders.has(parent)) { throw new Error('JSON 文件夹父目录不存在'); }
        if (chain.indexOf(parent) >= 0 || chain.length >= 32) { throw new Error('JSON 目录循环或深度超过 32'); }
        chain.push(parent); parent = snapshot.parents.get(parent) || '';
      }
    });
    doc.items.forEach((raw: ManifestItem) => {
      if (raw === null || typeof raw !== 'object') { throw new Error('JSON 媒体条目无效'); }
      const id = CustomManifest.id(raw.id);
      if (seen.indexOf(id) >= 0) { throw new Error('JSON 媒体库 ID 重复'); } seen.push(id);
      const entry = new CustomEntry(); entry.parentId = CustomManifest.text(raw.parentId, 'parentId', 128);
      if (entry.parentId.length > 0 && !snapshot.folders.has(entry.parentId)) { throw new Error('JSON 媒体父目录不存在'); }
      entry.item.id = CustomManifest.itemId(id); entry.item.name = CustomManifest.text(raw.name, 'item.name', 300, true); entry.item.type = 'Video';
      entry.item.overview = CustomManifest.text(raw.overview, 'overview', 20000);
      entry.item.year = CustomManifest.nonnegative(raw.year, 'year', 9999, true);
      entry.item.runtimeTicks = Math.round(CustomManifest.nonnegative(raw.durationSeconds, 'durationSeconds', Number.MAX_SAFE_INTEGER / 10000000) * 10000000);
      if (!Number.isSafeInteger(entry.item.runtimeTicks)) { throw new Error('JSON 时长超出安全范围'); }
      entry.item.createdAt = CustomManifest.date(raw.createdAt, 'createdAt'); entry.item.modifiedAt = CustomManifest.date(raw.modifiedAt, 'modifiedAt');
      entry.item.premiereDate = CustomManifest.date(raw.premiereDate, 'premiereDate');
      if (raw.type !== undefined && raw.type !== 'video' && raw.type !== 'live') { throw new Error('JSON item.type 仅支持 video/live'); }
      entry.live = raw.type === 'live'; entry.address = CustomManifest.address(base, raw.streamURL, local);
      const explicitHeaders = CustomManifest.headers(raw.headers);
      if (entry.address.startsWith('file://') && Object.keys(explicitHeaders).length > 0) { throw new Error('本地文件不使用 HTTP 请求头'); }
      if (!local && DirectSourceHttp.sameOrigin(base, entry.address)) {
        Object.keys(inheritedHeaders).forEach((key: string) => { entry.headers[key.toLowerCase()] = inheritedHeaders[key]; });
      }
      Object.keys(explicitHeaders).forEach((key: string) => { entry.headers[key] = explicitHeaders[key]; });
      if (raw.posterURL !== undefined) { entry.item.imageTag = CustomManifest.address(base, raw.posterURL, local); entry.item.hasPrimaryImage = true; }
      if (raw.backdropURL !== undefined) { entry.item.backdropTag = CustomManifest.address(base, raw.backdropURL, local); }
      if ((entry.item.imageTag.length > 0 && !/^https?:/.test(entry.item.imageTag)) || (entry.item.backdropTag.length > 0 && !/^https?:/.test(entry.item.backdropTag))) {
        throw new Error('JSON 封面目前需要 HTTP(S) 图片地址');
      }
      const source = entry.source; source.id = entry.item.id; source.sizeBytes = CustomManifest.nonnegative(raw.sizeBytes, 'sizeBytes', Number.MAX_SAFE_INTEGER, true);
      if (/^https?:/.test(entry.address)) { source.container = DirectSourceHttp.extension(entry.address); entry.item.container = source.container; }
      if (raw.width !== undefined || raw.height !== undefined) {
        const stream = new MediaStream(); stream.type = 'Video';
        stream.width = CustomManifest.nonnegative(raw.width, 'width', 32768, true); stream.height = CustomManifest.nonnegative(raw.height, 'height', 32768, true);
        if (stream.width < 1 || stream.height < 1) { throw new Error('JSON 分辨率需要真实 width 和 height'); } source.streams.push(stream);
      }
      if (raw.subtitles !== undefined && (!Array.isArray(raw.subtitles) || raw.subtitles.length > 64)) { throw new Error('JSON 字幕列表无效'); }
      const subIds: string[] = [];
      (raw.subtitles !== undefined ? raw.subtitles : []).forEach((sub: ManifestSubtitle, index: number) => {
        if (sub === null || typeof sub !== 'object') { throw new Error('JSON 字幕条目无效'); }
        const subId = CustomManifest.id(sub.id); if (subIds.indexOf(subId) >= 0) { throw new Error('JSON 字幕 ID 重复'); } subIds.push(subId);
        const address = CustomManifest.address(base, sub.url, local);
        if (!/^https?:/.test(address)) { throw new Error('JSON 外部字幕目前需要 HTTP(S) 地址'); }
        if (entry.address.startsWith('file://') || (Object.keys(entry.headers).length > 0 && !DirectSourceHttp.sameOrigin(entry.address, address))) {
          throw new Error('带认证播放的字幕必须与播放地址同源；本地 fd 外挂字幕请单独导入');
        }
        const format = sub.format !== undefined ? sub.format.toLowerCase() : DirectSourceHttp.extension(address);
        if (['srt', 'vtt', 'ass', 'ssa'].indexOf(format) < 0) { throw new Error('JSON 字幕格式仅支持 SRT/VTT/ASS/SSA'); }
        const saved: ManifestSubtitle = { id: subId, url: address, label: CustomManifest.text(sub.label, 'subtitle.label', 200),
          language: CustomManifest.text(sub.language, 'subtitle.language', 32), format: format };
        entry.subtitles.push(saved);
        const stream = new MediaStream(); stream.type = 'Subtitle'; stream.index = 1000 + index; stream.isExternal = true;
        stream.codec = format; stream.title = saved.label || saved.language || ('字幕 ' + (index + 1).toString()); stream.language = saved.language || '';
        source.streams.push(stream);
      });
      snapshot.entries.set(id, entry);
    }); return snapshot;
  }
}
