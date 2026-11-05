import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { url } from '@kit.ArkTS';
import { ServerConfig } from './Models';
import { Store } from './Store';
import { SourceIdentity } from './services/SourceIdentity';

export class ServerBackupNode {
  id: string = '';
  name: string = '';
  url: string = '';
}

/** Public UI values. Salt/digest and failed-PIN counters never leave this module. */
export class ServerOption {
  id: string = '';
  note: string = '';
  hidden: boolean = false;
  aggregateEnabled: boolean = true;
  reminderEnabled: boolean = false;
  reminderHour: number = 9;
  reminderMinute: number = 0;
  backups: ServerBackupNode[] = [];
  hasPin: boolean = false;
  locked: boolean = false;
  error: string = '';
}

class SavedServerOption {
  version: number = 1;
  id: string = '';
  note: string = '';
  hidden: boolean = false;
  aggregateEnabled: boolean = true;
  reminderEnabled: boolean = false;
  reminderHour: number = 9;
  reminderMinute: number = 0;
  reminderDay: string = '';
  backups: ServerBackupNode[] = [];
  pinSalt: string = '';
  pinDigest: string = '';
  pinFailures: number = 0;
  pinBlockedUntil: number = 0;
}

interface PublicServerShare {
  version: number;
  kind: string;
  connectionMode: string;
  origin: string;
  notice: string;
}

/**
 * Per-station UI privacy/options, not encryption or remote NAS access control.
 * Call fresh isLocked/get before boot selection, opening content, sharing or deleting.
 * cached is display-only. No timers/background reminders and no credentials in this JSON.
 */
export class ServerOptions {
  private static chain: Promise<void> = Promise.resolve();
  private static readonly views: Map<string, ServerOption> = new Map();
  private static readonly unlocked: Map<string, number> = new Map();
  private static readonly SESSION_MS: number = 10 * 60 * 1000;
  private static readonly MAX_BACKUPS: number = 8;

  private static serial<T>(task: () => Promise<T>): Promise<T> {
    const result = ServerOptions.chain.then(task);
    ServerOptions.chain = result.then(() => {}, () => {});
    return result;
  }

  private static validId(id: string): void {
    if (typeof id !== 'string' || id.length === 0 || id.length > 256 || /[\u0000-\u0020/\\]/.test(id)
      || id === '__proto__' || id === 'prototype' || id === 'constructor') { throw new Error('站点标识无效'); }
  }

  private static key(id: string): string {
    ServerOptions.validId(id);
    return 'station_options_v1.' + SourceIdentity.key(id);
  }

  private static text(value: string, maximum: number, label: string): string {
    if (typeof value !== 'string' || value.length > maximum || value.indexOf('\u0000') >= 0) {
      throw new Error(label + '格式或长度无效');
    }
    return value.trim();
  }

  private static bool(value: boolean): void {
    if (typeof value !== 'boolean') { throw new Error('站点开关值无效'); }
  }

  private static randomHex(bytes: number): string {
    const data = cryptoFramework.createRandom().generateRandomSync(bytes).data;
    if (data.length !== bytes) { throw new Error('安全随机数生成失败'); }
    let result = '';
    for (let index = 0; index < data.length; index++) { result += data[index].toString(16).padStart(2, '0'); }
    return result;
  }

  /** Canonical HTTP(S) endpoint only: no credentials, query, fragment, traversal or hidden controls. */
  static normalizeBackupUrl(value: string): string {
    const input = ServerOptions.text(value, 2048, '备用地址');
    if (!/^https?:\/\//i.test(input) || /[\u0000-\u0020\\?#]/.test(input)) {
      throw new Error('备用地址须为HTTP(S)，不能包含凭据、查询或片段');
    }
    let parsed: url.URL;
    try { parsed = new url.URL(input); } catch (e) { throw new Error('备用地址无效'); }
    const authority = input.match(/^https?:\/\/([^/]+)(\/.*)?$/i);
    if (authority === null || authority[1].indexOf('@') >= 0 || parsed.username.length > 0
      || parsed.password.length > 0 || parsed.search.length > 0 || parsed.hash.length > 0
      || parsed.hostname.length === 0 || (parsed.protocol !== 'http:' && parsed.protocol !== 'https:')) {
      throw new Error('备用地址不能包含凭据或私密查询参数');
    }
    const rawPath = authority[2] === undefined ? '' : authority[2];
    for (const part of rawPath.split('/')) {
      let decoded = '';
      try { decoded = decodeURIComponent(part); } catch (e) { throw new Error('备用地址路径编码无效'); }
      if (decoded === '.' || decoded === '..' || /[\u0000-\u0020/\\?#]/.test(decoded)) {
        throw new Error('备用地址路径不安全');
      }
    }
    const port = parsed.port.length > 0 ? Number(parsed.port) : parsed.protocol === 'https:' ? 443 : 80;
    if (!Number.isInteger(port) || port < 1 || port > 65535) { throw new Error('备用端口无效'); }
    return parsed.origin + parsed.pathname.replace(/\/+$/, '');
  }

  private static copyNode(source: ServerBackupNode): ServerBackupNode {
    const node = new ServerBackupNode();
    node.id = source.id; node.name = source.name; node.url = source.url;
    return node;
  }

  private static view(saved: SavedServerOption): ServerOption {
    const value = new ServerOption();
    value.id = saved.id; value.note = saved.note; value.hidden = saved.hidden;
    value.aggregateEnabled = saved.aggregateEnabled; value.reminderEnabled = saved.reminderEnabled;
    value.reminderHour = saved.reminderHour; value.reminderMinute = saved.reminderMinute;
    value.backups = saved.backups.map((node: ServerBackupNode) => ServerOptions.copyNode(node));
    value.hasPin = saved.pinDigest.length > 0;
    value.locked = value.hasPin && (ServerOptions.unlocked.get(saved.id) ?? 0) <= Date.now();
    ServerOptions.views.set(saved.id, value);
    return ServerOptions.copyView(value);
  }

  private static copyView(source: ServerOption): ServerOption {
    const value = new ServerOption();
    value.id = source.id; value.note = source.note; value.hidden = source.hidden;
    value.aggregateEnabled = source.aggregateEnabled; value.reminderEnabled = source.reminderEnabled;
    value.reminderHour = source.reminderHour; value.reminderMinute = source.reminderMinute;
    value.backups = source.backups.map((node: ServerBackupNode) => ServerOptions.copyNode(node));
    value.hasPin = source.hasPin; value.error = source.error;
    value.locked = source.error.length > 0 || (value.hasPin && (ServerOptions.unlocked.get(source.id) ?? 0) <= Date.now());
    if (value.locked) { value.note = ''; value.backups = []; }
    return value;
  }

  private static async load(id: string): Promise<SavedServerOption> {
    const raw = await Store.get(ServerOptions.key(id), '');
    const value = new SavedServerOption(); value.id = id;
    if (raw === '') { return value; }
    if (typeof raw !== 'string' || raw.length > 32768) { throw new Error('站点选项损坏，原记录已保留'); }
    let row: SavedServerOption;
    try { row = JSON.parse(raw) as SavedServerOption; } catch (e) { throw new Error('站点选项损坏，原记录已保留'); }
    if (row === null || typeof row !== 'object' || Array.isArray(row) || row.version !== 1 || row.id !== id
      || typeof row.note !== 'string' || row.note.length > 2000 || row.note.indexOf('\u0000') >= 0
      || typeof row.hidden !== 'boolean' || typeof row.aggregateEnabled !== 'boolean'
      || typeof row.reminderEnabled !== 'boolean' || !Number.isInteger(row.reminderHour) || row.reminderHour < 0 || row.reminderHour > 23
      || !Number.isInteger(row.reminderMinute) || row.reminderMinute < 0 || row.reminderMinute > 59
      || typeof row.reminderDay !== 'string' || !/^(?:|\d{4}-\d{2}-\d{2})$/.test(row.reminderDay)
      || !Array.isArray(row.backups) || row.backups.length > ServerOptions.MAX_BACKUPS
      || typeof row.pinSalt !== 'string' || typeof row.pinDigest !== 'string'
      || !Number.isInteger(row.pinFailures) || row.pinFailures < 0 || row.pinFailures > 4
      || !Number.isSafeInteger(row.pinBlockedUntil) || row.pinBlockedUntil < 0
      || !((row.pinSalt === '' && row.pinDigest === '') || (/^[a-f0-9]{64}$/.test(row.pinSalt) && /^[a-f0-9]{64}$/.test(row.pinDigest)))) {
      throw new Error('站点选项损坏，原记录已保留');
    }
    value.note = row.note; value.hidden = row.hidden; value.aggregateEnabled = row.aggregateEnabled;
    value.reminderEnabled = row.reminderEnabled; value.reminderHour = row.reminderHour; value.reminderMinute = row.reminderMinute;
    value.reminderDay = row.reminderDay; value.pinSalt = row.pinSalt; value.pinDigest = row.pinDigest;
    value.pinFailures = row.pinFailures; value.pinBlockedUntil = row.pinBlockedUntil;
    const ids: Set<string> = new Set(); const urls: Set<string> = new Set();
    for (const item of row.backups) {
      if (item === null || typeof item !== 'object') { throw new Error('备用节点记录损坏'); }
      ServerOptions.validId(item.id);
      const name = ServerOptions.text(item.name, 80, '备用节点名称');
      const address = ServerOptions.normalizeBackupUrl(item.url);
      if (name.length === 0 || ids.has(item.id) || urls.has(address)) { throw new Error('备用节点记录损坏或重复'); }
      const node = new ServerBackupNode(); node.id = item.id; node.name = name; node.url = address;
      ids.add(node.id); urls.add(node.url); value.backups.push(node);
    }
    return value;
  }

  private static async write(saved: SavedServerOption): Promise<void> {
    const raw = JSON.stringify(saved);
    await Store.set(ServerOptions.key(saved.id), raw);
    if (await Store.get(ServerOptions.key(saved.id), '') !== raw) { throw new Error('站点选项未保存，请初始化存储后重试'); }
    ServerOptions.view(saved);
  }

  private static requireUnlocked(saved: SavedServerOption): void {
    if (saved.pinDigest.length > 0 && (ServerOptions.unlocked.get(saved.id) ?? 0) <= Date.now()) {
      throw new Error('站点已锁定，请先验证PIN');
    }
  }

  static get(id: string): Promise<ServerOption> {
    return ServerOptions.serial(async () => ServerOptions.view(await ServerOptions.load(id)));
  }

  /** Batch known saved stations. A corrupt row fails closed and remains visibly diagnosable. */
  static all(): Promise<ServerOption[]> {
    return ServerOptions.serial(async () => {
      const servers = await Store.loadServers(); const result: ServerOption[] = [];
      for (const server of servers) {
        try { result.push(ServerOptions.view(await ServerOptions.load(server.id))); }
        catch (e) {
          const failed = new ServerOption(); failed.id = server.id; failed.hasPin = true; failed.locked = true;
          failed.aggregateEnabled = false; failed.error = '站点选项读取失败，已阻止访问；请检查存储';
          ServerOptions.views.set(server.id, failed); result.push(ServerOptions.copyView(failed));
        }
      }
      return result;
    });
  }

  static cached(id: string): ServerOption | null {
    const value = ServerOptions.views.get(id);
    return value === undefined ? null : ServerOptions.copyView(value);
  }

  static async isLocked(id: string): Promise<boolean> { return (await ServerOptions.get(id)).locked; }

  private static change(id: string, mutate: (saved: SavedServerOption) => void): Promise<void> {
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id); ServerOptions.requireUnlocked(saved);
      mutate(saved); await ServerOptions.write(saved);
    });
  }

  static setNote(id: string, note: string): Promise<void> {
    const value = ServerOptions.text(note, 2000, '备注');
    return ServerOptions.change(id, (saved: SavedServerOption) => { saved.note = value; });
  }
  static setHidden(id: string, enabled: boolean): Promise<void> {
    ServerOptions.bool(enabled); return ServerOptions.change(id, (saved: SavedServerOption) => { saved.hidden = enabled; });
  }
  static setAggregate(id: string, enabled: boolean): Promise<void> {
    ServerOptions.bool(enabled); return ServerOptions.change(id, (saved: SavedServerOption) => { saved.aggregateEnabled = enabled; });
  }
  static setReminder(id: string, enabled: boolean, hour: number = 9, minute: number = 0): Promise<void> {
    ServerOptions.bool(enabled);
    if (!Number.isInteger(hour) || hour < 0 || hour > 23 || !Number.isInteger(minute) || minute < 0 || minute > 59) {
      throw new Error('提醒时间无效');
    }
    return ServerOptions.change(id, (saved: SavedServerOption) => {
      saved.reminderEnabled = enabled; saved.reminderHour = hour; saved.reminderMinute = minute;
    });
  }

  /** Foreground-only claim, at most once per local calendar day. No notification/background promise. */
  static takeDueReminder(id: string, now: number = Date.now()): Promise<boolean> {
    if (!Number.isSafeInteger(now) || now < 0 || now > 8640000000000000) { throw new Error('提醒日期无效'); }
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id);
      if (!saved.reminderEnabled || saved.hidden || (saved.pinDigest.length > 0 && (ServerOptions.unlocked.get(id) ?? 0) <= Date.now())) { return false; }
      const date = new Date(now);
      const day = date.getFullYear().toString().padStart(4, '0') + '-' + (date.getMonth() + 1).toString().padStart(2, '0') + '-' + date.getDate().toString().padStart(2, '0');
      if (saved.reminderDay === day || date.getHours() * 60 + date.getMinutes() < saved.reminderHour * 60 + saved.reminderMinute) { return false; }
      saved.reminderDay = day; await ServerOptions.write(saved); return true;
    });
  }

  static putBackup(id: string, name: string, address: string, nodeId: string = ''): Promise<ServerBackupNode> {
    const label = ServerOptions.text(name, 80, '备用节点名称');
    if (label.length === 0) { throw new Error('请输入备用节点名称'); }
    const endpoint = ServerOptions.normalizeBackupUrl(address);
    if (nodeId.length > 0) { ServerOptions.validId(nodeId); }
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id); ServerOptions.requireUnlocked(saved);
      const at = saved.backups.findIndex((node: ServerBackupNode) => node.id === nodeId);
      if (nodeId.length > 0 && at < 0) { throw new Error('备用节点不存在'); }
      if (saved.backups.some((node: ServerBackupNode) => node.id !== nodeId && node.url === endpoint)) { throw new Error('备用地址已存在'); }
      if (at < 0 && saved.backups.length >= ServerOptions.MAX_BACKUPS) { throw new Error('备用节点最多8个'); }
      const node = new ServerBackupNode(); node.id = at < 0 ? 'node-' + ServerOptions.randomHex(12) : nodeId;
      node.name = label; node.url = endpoint;
      if (at < 0) { saved.backups.push(node); } else { saved.backups[at] = node; }
      await ServerOptions.write(saved); return ServerOptions.copyNode(node);
    });
  }

  static removeBackup(id: string, nodeId: string): Promise<void> {
    ServerOptions.validId(nodeId);
    return ServerOptions.change(id, (saved: SavedServerOption) => {
      if (!saved.backups.some((node: ServerBackupNode) => node.id === nodeId)) { throw new Error('备用节点不存在'); }
      saved.backups = saved.backups.filter((node: ServerBackupNode) => node.id !== nodeId);
    });
  }

  private static copyServer(source: ServerConfig): ServerConfig {
    const next = new ServerConfig(source.id, source.kind, source.name, source.host, source.port, source.username,
      source.token, source.userId, source.serverName, source.version, source.nativeToken);
    next.scheme = source.scheme; next.basePath = source.basePath; next.rootPath = source.rootPath;
    next.sourceUrl = source.sourceUrl; next.epgUrl = source.epgUrl; next.authBrokerUrl = source.authBrokerUrl;
    next.authMode = source.authMode; next.connectionMode = source.connectionMode; next.domain = source.domain;
    next.shareName = source.shareName; next.clientId = source.clientId; next.credentialRef = source.credentialRef;
    next.credentialError = source.credentialError; next.password = source.password; next.clientSecret = source.clientSecret;
    next.refreshToken = source.refreshToken; next.clearCredentials = false;
    return next;
  }

  /** Explicit same-station endpoint switch. Never sends a credential to a node during validation. */
  static activateBackup(id: string, nodeId: string): Promise<ServerConfig> {
    ServerOptions.validId(nodeId);
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id); ServerOptions.requireUnlocked(saved);
      const node = saved.backups.find((value: ServerBackupNode) => value.id === nodeId);
      if (node === undefined) { throw new Error('备用节点不存在'); }
      const source = (await Store.loadServers()).find((value: ServerConfig) => value.id === id);
      if (source === undefined) { throw new Error('站点不存在'); }
      if (source.credentialError.length > 0) { throw new Error('站点安全凭据暂不可读，不能切换节点'); }
      if (source.connectionMode !== 'aggregate' && ['fnos','fnos-native','emby','jellyfin','plex','webdav','clouddrive'].indexOf(source.kind) < 0) {
        throw new Error('此直连来源不使用HTTP站点备用地址');
      }
      const endpoint = new url.URL(ServerOptions.normalizeBackupUrl(node.url));
      const next = ServerOptions.copyServer(source);
      next.scheme = endpoint.protocol === 'https:' ? 'https' : 'http';
      next.host = endpoint.hostname.replace(/^\[|\]$/g, '');
      next.port = endpoint.port.length > 0 ? Number(endpoint.port) : next.scheme === 'https' ? 443 : 80;
      next.basePath = endpoint.pathname.replace(/\/+$/, '');
      await Store.upsert(next);
      return next;
    });
  }

  /** Public connection summary, deliberately omitting username, all secret/resource URLs and all paths. */
  static shareText(id: string): Promise<string> {
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id); ServerOptions.requireUnlocked(saved);
      const server = (await Store.loadServers()).find((value: ServerConfig) => value.id === id);
      if (server === undefined) { throw new Error('站点不存在'); }
      const kinds = ['emby','jellyfin','plex','fnos','fnos-native','webdav','clouddrive','guangya','baidu','smb','iptv','custom','local'];
      if (kinds.indexOf(server.kind) < 0 || ['direct','aggregate'].indexOf(server.connectionMode) < 0) { throw new Error('来源类型或模式无效'); }
      let origin = '';
      if (server.host.length > 0 && (server.scheme === 'http' || server.scheme === 'https')) {
        origin = new url.URL(ServerOptions.normalizeBackupUrl(server.baseUrl())).origin;
      }
      const summary: PublicServerShare = { version: 1, kind: server.kind, connectionMode: server.connectionMode, origin: origin,
        notice: '公开摘要不含账号、凭据、私有路径或媒体地址；接收方需自行配置并授权。' };
      return JSON.stringify(summary, null, 2);
    });
  }

  static publicShare(server: ServerConfig): Promise<string> { return ServerOptions.shareText(server.id); }

  private static pin(value: string): void {
    if (typeof value !== 'string' || !/^\d{4,12}$/.test(value)) { throw new Error('PIN须为4至12位数字'); }
  }
  private static digest(saved: SavedServerOption, pin: string): string {
    return SourceIdentity.key('nasplayer.station.pin.v1\u0000' + saved.id + '\u0000' + saved.pinSalt + '\u0000' + pin);
  }
  private static equal(left: string, right: string): boolean {
    if (left.length !== right.length) { return false; }
    let different = 0;
    for (let index = 0; index < left.length; index++) { different |= left.charCodeAt(index) ^ right.charCodeAt(index); }
    return different === 0;
  }
  private static async checkPin(saved: SavedServerOption, pin: string): Promise<boolean> {
    ServerOptions.pin(pin);
    ServerOptions.unlocked.delete(saved.id);
    if (saved.pinDigest.length === 0) { throw new Error('站点尚未设置PIN'); }
    if (saved.pinBlockedUntil > Date.now()) { throw new Error('PIN尝试过多，请稍后再试'); }
    if (!ServerOptions.equal(ServerOptions.digest(saved, pin), saved.pinDigest)) {
      saved.pinFailures++;
      if (saved.pinFailures >= 5) { saved.pinFailures = 0; saved.pinBlockedUntil = Date.now() + 60000; }
      await ServerOptions.write(saved); return false;
    }
    saved.pinFailures = 0; saved.pinBlockedUntil = 0;
    await ServerOptions.write(saved);
    ServerOptions.unlocked.set(saved.id, Date.now() + ServerOptions.SESSION_MS);
    ServerOptions.view(saved); return true;
  }

  static setPin(id: string, pin: string, oldPin: string = ''): Promise<void> {
    ServerOptions.pin(pin);
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id);
      if (saved.pinDigest.length > 0 && (ServerOptions.unlocked.get(id) ?? 0) <= Date.now()) {
        if (!await ServerOptions.checkPin(saved, oldPin)) { throw new Error('当前PIN不正确'); }
      }
      ServerOptions.unlocked.delete(id);
      saved.pinSalt = ServerOptions.randomHex(32); saved.pinDigest = ServerOptions.digest(saved, pin);
      saved.pinFailures = 0; saved.pinBlockedUntil = 0;
      await ServerOptions.write(saved);
    });
  }
  static verifyPin(id: string, pin: string): Promise<boolean> {
    return ServerOptions.serial(async () => ServerOptions.checkPin(await ServerOptions.load(id), pin));
  }
  static lock(id: string): Promise<void> {
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id);
      if (saved.pinDigest.length === 0) { throw new Error('请先为站点设置PIN'); }
      ServerOptions.unlocked.delete(id); ServerOptions.view(saved);
    });
  }
  static clearPin(id: string, pin: string = ''): Promise<void> {
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id);
      if (saved.pinDigest.length > 0 && (ServerOptions.unlocked.get(id) ?? 0) <= Date.now()) {
        if (!await ServerOptions.checkPin(saved, pin)) { throw new Error('当前PIN不正确'); }
      }
      saved.pinSalt = ''; saved.pinDigest = ''; saved.pinFailures = 0; saved.pinBlockedUntil = 0;
      await ServerOptions.write(saved); ServerOptions.unlocked.delete(id);
    });
  }
  static clear(id: string): Promise<void> {
    return ServerOptions.serial(async () => {
      const saved = await ServerOptions.load(id); ServerOptions.requireUnlocked(saved);
      await Store.set(ServerOptions.key(id), '');
      if (await Store.get(ServerOptions.key(id), '') !== '') { throw new Error('站点选项清理失败'); }
      ServerOptions.views.delete(id); ServerOptions.unlocked.delete(id);
    });
  }
}
