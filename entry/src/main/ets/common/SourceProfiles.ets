import { SourceEndpoint, SourceEndpointValue } from './SourceEndpoint';

export class SourceProfile {
  kind: string; name: string; family: string; defaultPort: number; defaultScheme: string;
  fields: string[]; authModes: string[]; connectionModes: string[]; capabilities: string[]; notice: string;
  defaultAddress: string = '';
  constructor(kind: string, name: string, family: string, port: number, scheme: string,
    fields: string[], authModes: string[], connectionModes: string[], capabilities: string[], notice: string) {
    this.kind = kind; this.name = name; this.family = family; this.defaultPort = port; this.defaultScheme = scheme;
    this.fields = fields; this.authModes = authModes; this.connectionModes = connectionModes;
    this.capabilities = capabilities; this.notice = notice;
  }
}

/** Form-only secrets stay in memory and are handed to Store's credential vault transaction. */
export class SourceDraft {
  kind: string = 'fnos'; name: string = ''; address: string = ''; portText: string = '';
  scheme: string = 'http'; basePath: string = ''; username: string = ''; password: string = '';
  accessToken: string = ''; rootPath: string = '/'; sourceUrl: string = ''; epgUrl: string = ''; authMode: string = 'password';
  connectionMode: string = 'direct'; domain: string = ''; shareName: string = ''; clientId: string = '';
  authBrokerUrl: string = '';
  clientSecret: string = ''; refreshToken: string = ''; preserveCredentials: boolean = false; userId: string = '';
}

export class SourceValidatedDraft {
  userId: string = '';
  endpoint: SourceEndpointValue = new SourceEndpointValue();
  kind: string = ''; name: string = ''; username: string = ''; rootPath: string = '';
  sourceUrl: string = ''; epgUrl: string = ''; authMode: string = ''; connectionMode: string = '';
  domain: string = ''; shareName: string = ''; clientId: string = '';
  authBrokerUrl: string = '';
}

export class SourceProfiles {
  private static readonly profiles: SourceProfile[] = SourceProfiles.makeProfiles();

  static all(): SourceProfile[] { return SourceProfiles.profiles.slice(); }
  static copyDraft(value: SourceDraft): SourceDraft {
    const copy = new SourceDraft();
    copy.kind = value.kind; copy.name = value.name; copy.address = value.address; copy.portText = value.portText;
    copy.scheme = value.scheme; copy.basePath = value.basePath; copy.username = value.username; copy.password = value.password;
    copy.accessToken = value.accessToken; copy.rootPath = value.rootPath; copy.sourceUrl = value.sourceUrl; copy.epgUrl = value.epgUrl;
    copy.authMode = value.authMode; copy.connectionMode = value.connectionMode; copy.domain = value.domain;
    copy.shareName = value.shareName; copy.clientId = value.clientId; copy.clientSecret = value.clientSecret;
    copy.authBrokerUrl = value.authBrokerUrl;
    copy.refreshToken = value.refreshToken; copy.preserveCredentials = value.preserveCredentials;
    copy.userId = value.userId;
    return copy;
  }
  static forKind(kind: string): SourceProfile {
    for (let i = 0; i < SourceProfiles.profiles.length; i++) {
      if (SourceProfiles.profiles[i].kind === kind) { return SourceProfiles.profiles[i]; }
    }
    throw new Error('此来源类型尚未定义');
  }
  static forName(name: string): SourceProfile {
    for (let i = 0; i < SourceProfiles.profiles.length; i++) {
      if (SourceProfiles.profiles[i].name === name) { return SourceProfiles.profiles[i]; }
    }
    throw new Error('此来源类型尚未定义');
  }
  static indexOf(kind: string): number {
    for (let i = 0; i < SourceProfiles.profiles.length; i++) { if (SourceProfiles.profiles[i].kind === kind) { return i; } }
    return -1;
  }
  static fieldsFor(kind: string, mode: string): string[] {
    if (mode === 'aggregate') { return ['address', 'port', 'basePath', 'username', 'password', 'rootPath']; }
    return SourceProfiles.forKind(kind).fields.slice();
  }
  static authModesFor(kind: string, mode: string): string[] {
    return mode === 'aggregate' ? ['password', 'anonymous'] : SourceProfiles.forKind(kind).authModes.slice();
  }
  static capabilitiesFor(kind: string, mode: string = 'direct'): string[] {
    const profile = SourceProfiles.forKind(kind);
    return mode === 'aggregate' ? ['files', 'play'] : profile.capabilities.slice();
  }
  static supports(kind: string, capability: string, mode: string = 'direct'): boolean {
    return SourceProfiles.capabilitiesFor(kind, mode).indexOf(capability) >= 0;
  }
  static authLabel(mode: string): string {
    if (mode === 'anonymous') { return '匿名'; }
    if (mode === 'token') { return '访问令牌'; }
    if (mode === 'oauth') { return '应用授权'; }
    return '账号密码';
  }
  static fieldLabel(field: string): string {
    if (field === 'address') { return '服务器地址'; }
    if (field === 'port') { return '端口（可留空）'; }
    if (field === 'basePath') { return '反向代理子路径（可留空）'; }
    if (field === 'username') { return '用户名'; }
    if (field === 'userId') { return '媒体库用户 ID'; }
    if (field === 'password') { return '密码'; }
    if (field === 'accessToken') { return '访问令牌'; }
    if (field === 'rootPath') { return '起始目录'; }
    if (field === 'sourceUrl') { return '来源地址或文件 URI'; }
    if (field === 'authBrokerUrl') { return '自有授权服务地址（可留空）'; }
    if (field === 'epgUrl') { return '电子节目单 EPG（可留空）'; }
    if (field === 'domain') { return '域 / 工作组（可留空）'; }
    if (field === 'shareName') { return '共享名称'; }
    if (field === 'clientId') { return '应用标识 Client ID'; }
    if (field === 'clientSecret') { return '应用密钥 Client Secret'; }
    if (field === 'refreshToken') { return '刷新令牌 Refresh Token'; }
    return field;
  }
  static secretField(field: string): boolean {
    return field === 'password' || field === 'accessToken' || field === 'clientSecret'
      || field === 'refreshToken' || field === 'sourceUrl' || field === 'epgUrl' || field === 'authBrokerUrl';
  }

  static validate(draft: SourceDraft): SourceValidatedDraft {
    const profile = SourceProfiles.forKind(draft.kind);
    if (profile.connectionModes.indexOf(draft.connectionMode) < 0) { throw new Error('该来源不支持所选连接方式'); }
    const authModes = SourceProfiles.authModesFor(draft.kind, draft.connectionMode);
    if (authModes.indexOf(draft.authMode) < 0) { throw new Error('该来源不支持所选认证方式'); }
    const fields = SourceProfiles.fieldsFor(draft.kind, draft.connectionMode);
    const result = new SourceValidatedDraft();
    result.endpoint.scheme = profile.defaultScheme;
    result.kind = draft.kind; result.name = draft.name.trim(); result.username = draft.username.trim();
    result.userId = fields.indexOf('userId') >= 0 && draft.authMode === 'token' ? draft.userId.trim() : '';
    result.connectionMode = draft.connectionMode; result.authMode = draft.authMode;
    result.domain = fields.indexOf('domain') >= 0 ? draft.domain.trim() : '';
    result.shareName = fields.indexOf('shareName') >= 0 ? draft.shareName.trim() : '';
    result.clientId = fields.indexOf('clientId') >= 0 ? draft.clientId.trim() : '';
    if (draft.kind === 'guangya' && draft.connectionMode === 'direct' && result.clientId.length === 0) { throw new Error('光鸭直连需要应用 Client ID 与用户令牌'); }
    if (fields.indexOf('authBrokerUrl') >= 0 && draft.authBrokerUrl.trim().length > 0) {
      result.authBrokerUrl = SourceProfiles.sourceUrl(draft.authBrokerUrl, false);
    }
    if (draft.kind === 'guangya' && draft.connectionMode === 'direct') {
      const folder = draft.rootPath.trim();
      if (folder.length > 0 && folder !== '/' && !/^[A-Za-z0-9_-]{1,256}$/.test(folder)) { throw new Error('光鸭起始目录请填写真实文件夹 ID，根目录填 /'); }
      result.rootPath = folder.length > 0 ? folder : '/';
    } else { result.rootPath = fields.indexOf('rootPath') >= 0 ? SourceProfiles.rootPath(draft.rootPath) : ''; }
    if (fields.indexOf('address') >= 0) {
      const defaultPort = draft.connectionMode === 'aggregate' ? 80 : profile.defaultPort;
      const scheme = draft.connectionMode === 'aggregate' ? (draft.scheme === 'https' ? 'https' : 'http') : draft.scheme;
      result.endpoint = SourceEndpoint.normalize(draft.address, draft.portText, defaultPort, scheme, draft.basePath);
      if (draft.connectionMode === 'aggregate' && result.endpoint.scheme === 'smb') { throw new Error('聚合服务请填写 HTTP 或 HTTPS WebDAV 地址'); }
      if (draft.kind !== 'smb' && result.endpoint.scheme === 'smb') { throw new Error('所选来源需要 HTTP 或 HTTPS 地址'); }
    }
    if (fields.indexOf('sourceUrl') >= 0) {
      result.sourceUrl = SourceProfiles.sourceUrl(draft.sourceUrl,
        draft.kind === 'local' || (draft.kind === 'custom' && /^file:\/\//i.test(draft.sourceUrl.trim())));
    }
    if (fields.indexOf('epgUrl') >= 0 && draft.epgUrl.trim().length > 0) {
      result.epgUrl = SourceProfiles.sourceUrl(draft.epgUrl, false);
    }
    if (draft.kind === 'smb' && draft.connectionMode === 'direct') {
      if (result.endpoint.scheme !== 'smb') { throw new Error('SMB 直连请填写主机/IP 或 smb:// 地址；HTTP 聚合入口请切换连接方式'); }
      if (result.endpoint.basePath.length > 0) {
        const parts = result.endpoint.basePath.split('/').filter((part: string): boolean => part.length > 0);
        const share = decodeURIComponent(parts[0]);
        if (result.shareName.length > 0 && result.shareName.toLowerCase() !== share.toLowerCase()) {
          throw new Error('SMB 地址中的共享名称与共享栏不一致');
        }
        if (result.shareName.length === 0) { result.shareName = share; }
        const child = parts.slice(1).map((part: string): string => decodeURIComponent(part)).join('/');
        const root = SourceProfiles.rootPath(child);
        if (root !== '/' && result.rootPath !== '/' && result.rootPath !== root) {
          throw new Error('SMB 地址中的目录与起始目录栏不一致');
        }
        if (root !== '/' && result.rootPath === '/') { result.rootPath = root; }
        result.endpoint.basePath = '';
      }
      if (result.shareName.length === 0) { throw new Error('请填写 SMB 共享名称'); }
    }
    if (draft.kind === 'smb' && /[\\/:?#\u0000-\u001F]/.test(result.shareName)) { throw new Error('共享名称不能包含路径分隔符或控制字符'); }
    if (draft.authMode === 'password') {
      if (result.username.length === 0) { throw new Error('请填写用户名，或选择该来源支持的匿名模式'); }
      if (draft.password.length === 0 && !draft.preserveCredentials) { throw new Error('请填写密码'); }
    } else if (draft.authMode === 'token') {
      if (draft.accessToken.trim().length === 0 && !draft.preserveCredentials) { throw new Error('请填写访问令牌'); }
      if (fields.indexOf('userId') >= 0 && result.userId.length === 0) { throw new Error('令牌连接请填写媒体库用户 ID，或改用账号密码登录'); }
      if (result.userId.length > 0 && !/^[A-Za-z0-9_-]{1,128}$/.test(result.userId)) { throw new Error('媒体库用户 ID 格式无效'); }
    } else if (draft.authMode === 'oauth') {
      const token = draft.accessToken.trim().length > 0;
      const refresh = draft.refreshToken.trim().length > 0;
      const clientPair = result.clientId.length > 0 && draft.clientSecret.length > 0;
      if (!token && !refresh && !clientPair && !draft.preserveCredentials) { throw new Error('请填写访问令牌、刷新令牌或平台应用授权凭据'); }
      if (refresh && result.clientId.length === 0) { throw new Error('使用刷新令牌时请同时填写 Client ID'); }
      if (refresh && !token && draft.kind === 'baidu' && draft.clientSecret.length === 0 && !draft.preserveCredentials) { throw new Error('百度刷新授权还需要应用 Client Secret'); }
    }
    if (result.name.length === 0) {
      result.name = result.endpoint.host.length > 0 ? result.endpoint.host : profile.name;
    }
    return result;
  }

  static rootPath(value: string): string {
    let path = value.trim();
    if (path.length === 0) { return '/'; }
    if (/[\u0000-\u001F\\]/.test(path)) { throw new Error('起始目录不能包含控制字符或反斜杠'); }
    const parts = path.split('/');
    for (let i = 0; i < parts.length; i++) { if (parts[i] === '.' || parts[i] === '..') { throw new Error('起始目录不支持相对跳转'); } }
    if (!path.startsWith('/')) { path = '/' + path; }
    while (path.length > 1 && path.endsWith('/')) { path = path.substring(0, path.length - 1); }
    return path;
  }

  static sourceUrl(value: string, local: boolean): string {
    const uri = local ? value : value.trim();
    if (uri.trim().length === 0) { throw new Error(local ? '请选择已授权的本地文件夹' : '请填写播放列表地址'); }
    if (/[\u0000-\u001F]/.test(uri)) { throw new Error('URI 不能包含控制字符'); }
    if (local) {
      if (!/^file:\/\//i.test(uri)) { throw new Error('本地文件夹请通过系统选择器获取 file URI'); }
      if (uri.indexOf('\\') >= 0) { throw new Error('本地 URI 不支持反斜杠'); }
      const segments = uri.substring(7).split('/');
      for (let i = 0; i < segments.length; i++) {
        let segment = '';
        try { segment = decodeURIComponent(segments[i]); } catch (e) { throw new Error('本地 URI 编码无效'); }
        if (segment === '.' || segment === '..' || segment.indexOf('/') >= 0 || segment.indexOf('\\') >= 0) {
          throw new Error('本地 URI 不支持相对跳转');
        }
      }
    } else {
      if (/\s/.test(uri)) { throw new Error('网络 URI 中的空白请使用百分号编码'); }
      if (!/^https?:\/\//i.test(uri)) { throw new Error('播放列表请填写 HTTP 或 HTTPS 地址'); }
      const base = uri.split('?')[0];
      SourceEndpoint.normalize(base, '', 80);
    }
    return uri;
  }

  private static makeProfiles(): SourceProfile[] {
    const endpoint = ['address', 'port', 'basePath'];
    const account = endpoint.concat(['username', 'password', 'accessToken']);
    const media = ['catalog', 'play', 'search', 'episodes', 'favorites', 'progress'];
    const browse = ['files', 'play'];
    const list: SourceProfile[] = [
      new SourceProfile('emby', 'Emby', 'catalog', 8096, 'http', account.concat(['userId']), ['password', 'token'], ['direct'], media, '直连 Emby 服务，支持完整 HTTPS 地址与反向代理子路径。'),
      new SourceProfile('jellyfin', 'Jellyfin', 'catalog', 8096, 'http', account.concat(['userId']), ['password', 'token'], ['direct'], media, '直连 Jellyfin 服务；连接检测会验证实际账号会话。'),
      new SourceProfile('plex', 'Plex', 'catalog', 32400, 'http', endpoint.concat(['accessToken']), ['token'], ['direct'], ['catalog', 'play', 'search', 'episodes', 'progress'], '填写你的 Plex 服务地址和访问令牌；不会使用影视服务器密码代替 Plex 授权。'),
      new SourceProfile('fnos', '飞牛影视', 'catalog', 8005, 'http', account.concat(['userId']), ['password', 'token'], ['direct'], media, '连接飞牛影视兼容媒体库，并验证实际可用的播放会话。'),
      new SourceProfile('fnos-native', '飞牛影视（原生）', 'catalog', 8005, 'http', account.concat(['userId']), ['password', 'token'], ['direct'], media, '目录使用飞牛兼容接口，播放独立协商飞牛原生会话。首次连接请使用账号密码取得原生播放凭据。'),
      new SourceProfile('webdav', 'WebDAV', 'files', 80, 'http', account.concat(['rootPath']), ['password', 'anonymous'], ['direct'], browse, '填写 WebDAV 根地址和起始目录；实际检测目录读取权限。'),
      new SourceProfile('clouddrive', 'CloudDrive2', 'files', 19798, 'http', endpoint.concat(['accessToken', 'rootPath']), ['token'], ['direct', 'aggregate'], browse, '直连 CloudDrive2 的 gRPC-Web 服务，填写有效 API 访问令牌。聚合模式使用已启用的 WebDAV 入口与其账号密码。'),
      new SourceProfile('guangya', '光鸭云盘', 'files', 443, 'https', ['clientId', 'accessToken', 'refreshToken', 'authBrokerUrl', 'rootPath'], ['token', 'oauth'], ['direct', 'aggregate'], browse, '直连官方开放平台，需要应用标识与用户令牌。设备授权需配置你部署的授权代理；服务端签名密钥保留在代理端。'),
      new SourceProfile('baidu', '百度网盘', 'files', 443, 'https', ['clientId', 'clientSecret', 'accessToken', 'refreshToken', 'rootPath'], ['oauth', 'token'], ['direct', 'aggregate'], browse, '直连百度官方开放平台。可导入用户令牌，或配置自己的应用标识与密钥进行设备授权；权限取决于开发者应用。'),
      new SourceProfile('smb', 'SMB', 'files', 445, 'smb', endpoint.concat(['domain', 'shareName', 'username', 'password', 'rootPath']), ['password', 'anonymous'], ['direct', 'aggregate'], browse, '直连填写主机、共享名称和可选域；聚合模式填写 WebDAV 地址，不把 SMB 路径伪装成 HTTP 流。'),
      new SourceProfile('iptv', 'IPTV', 'iptv', 80, 'http', ['sourceUrl', 'epgUrl', 'username', 'password'], ['anonymous', 'password'], ['direct'], ['channels', 'play'], '导入实际 M3U 播放列表及可选 XMLTV 节目单。订阅地址可能包含密钥，会隐藏展示并按敏感配置保存。'),
      new SourceProfile('custom', '自定义媒体库', 'files', 0, 'http', ['sourceUrl', 'username', 'password', 'accessToken'], ['anonymous', 'password', 'token'], ['direct', 'aggregate'], browse, '导入包含影片名称、播放地址和封面的 JSON 媒体清单，支持网络地址或已授权的本地文件。聚合模式独立连接 WebDAV。'),
      new SourceProfile('local', '本地文件夹', 'files', 0, 'file', ['sourceUrl'], ['anonymous'], ['direct'], browse, '通过系统文件夹选择器授权访问；不会假定可以读取手机任意目录。')
    ];
    list[8].defaultAddress = 'https://pan.baidu.com';
    return list;
  }
}
