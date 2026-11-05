/**
 * 数据模型 —— 飞牛影视 / Jellyfin / Emby 共用一套 Emby 协议
 */

export class ServerConfig {
  id: string = '';
  kind: string = 'fnos';
  name: string = '';
  host: string = '';
  port: number = 8005;
  username: string = '';
  token: string = '';
  /** 飞牛原生播放会话的访问令牌，与 Emby 兼容令牌分别保存。 */
  nativeToken: string = '';
  userId: string = '';
  serverName: string = '';
  version: string = '';
  scheme: string = 'http';
  basePath: string = '';
  rootPath: string = '/';
  sourceUrl: string = '';
  epgUrl: string = '';
  authBrokerUrl: string = '';
  authMode: string = 'password';
  connectionMode: string = 'direct';
  domain: string = '';
  shareName: string = '';
  clientId: string = '';
  credentialRef: string = '';
  credentialError: string = '';
  /** Runtime-only credentials. Store persists these through AssetStore, never public JSON. */
  password: string = '';
  clientSecret: string = '';
  refreshToken: string = '';
  clearCredentials: boolean = false;

  constructor(id: string, kind: string, name: string, host: string, port: number,
              username: string, token: string, userId: string,
              serverName: string = '', version: string = '', nativeToken: string = '') {
    this.id = typeof id === 'string' ? id : '';
    this.kind = typeof kind === 'string' ? kind : '';
    this.name = typeof name === 'string' ? name : '';
    this.host = typeof host === 'string' ? host : '';
    this.port = port;
    this.username = typeof username === 'string' ? username : '';
    this.token = typeof token === 'string' ? token : '';
    this.userId = typeof userId === 'string' ? userId : '';
    this.serverName = typeof serverName === 'string' ? serverName : '';
    this.version = typeof version === 'string' ? version : '';
    this.nativeToken = typeof nativeToken === 'string' ? nativeToken : '';
  }

  baseUrl(): string {
    if (this.host.length === 0 && (this.kind === 'local' || this.kind === 'iptv' || this.kind === 'custom'
      || ((this.kind === 'baidu' || this.kind === 'guangya') && this.connectionMode === 'direct'))) { return ''; }
    const scheme = this.scheme.length > 0 ? this.scheme.toLowerCase() : 'http';
    if (scheme !== 'http' && scheme !== 'https' && scheme !== 'smb') { throw new Error('不支持的服务器协议'); }
    let host = this.host.trim();
    if (host.startsWith('[') && host.endsWith(']')) { host = host.substring(1, host.length - 1); }
    if (host.indexOf(':') >= 0) { host = '[' + host.replace(/%(?!25)/g, '%25') + ']'; }
    let path = this.basePath;
    if (path === '/') { path = ''; }
    if ((path.length > 0 && !path.startsWith('/')) || /[?#\\\u0000-\u0020]/.test(path)) {
      throw new Error('服务器子路径格式无效');
    }
    return scheme + '://' + host + ':' + this.port.toString() + path;
  }

  /** Emby 客户端标识头，必须带 */
  authHeader(): string {
    return 'MediaBrowser Client="NAS影库", Device="HarmonyOS", DeviceId="nasplayer-' +
      this.id + '", Version="1.0.0"';
  }
}

export class Library {
  id: string = '';
  name: string = '';
  type: string = '';

  constructor(id: string, name: string, type: string) {
    this.id = id;
    this.name = name;
    this.type = type;
  }
}

export class MediaItem {
  id: string = '';
  name: string = '';
  type: string = '';
  year: number = 0;
  overview: string = '';
  rating: number = 0;
  runtimeTicks: number = 0;
  hasPrimaryImage: boolean = false;
  imageTag: string = '';        // ★ 飞牛影视要求图片 URL 带 tag，否则 404
  backdropTag: string = '';
  /** 服务器报告的容器格式（MP4 / MKV / TS …）；可播放性由实际引擎与编码决定。 */
  container: string = '';
  genres: string[] = [];
  /** Original server dates; empty means unavailable, never inferred from list order. */
  createdAt: string = '';
  modifiedAt: string = '';
  premiereDate: string = '';
  isFavorite: boolean = false;
  favoriteKnown: boolean = false;
  path: string = '';
  indexNumber: number = 0;
  parentIndexNumber: number = 0;
  /** Distinguish server-supplied zero (specials) from an absent index defaulting to zero. */
  indexNumberKnown: boolean = false;
  parentIndexNumberKnown: boolean = false;
  seriesId: string = '';
  seriesName: string = '';
  played: boolean = false;
  progressTicks: number = 0;

  isPlayable(): boolean {
    return this.type === 'Movie' || this.type === 'Episode' ||
      this.type === 'Video' || this.type === 'MusicVideo' || this.type === 'Channel';
  }

  isFolder(): boolean {
    return this.type === 'Series' || this.type === 'Season' || this.type === 'BoxSet' || this.type === 'Folder';
  }

  runtimeMinutes(): number {
    if (this.runtimeTicks <= 0) {
      return 0;
    }
    return Math.floor(this.runtimeTicks / 600000000);
  }

  progressRatio(): number {
    if (this.runtimeTicks <= 0 || this.progressTicks <= 0) {
      return 0;
    }
    return Math.min(1, this.progressTicks / this.runtimeTicks);
  }
}

export class MediaStream {
  index: number = 0;
  type: string = '';
  codec: string = '';
  language: string = '';
  title: string = '';
  isDefault: boolean = false;
  isExternal: boolean = false;
  width: number = 0;
  height: number = 0;
  // ★ 媒体信息面板要用的技术参数
  bitrate: number = 0;          // bps
  frameRate: number = 0;
  profile: string = '';
  level: number = 0;
  aspectRatio: string = '';
  pixelFormat: string = '';
  colorSpace: string = '';
  colorTransfer: string = '';
  bitDepth: number = 0;
  channels: number = 0;
  channelLayout: string = '';
  sampleRate: number = 0;
  isHdr: boolean = false;
  videoRange: string = '';

  isVideo(): boolean { return this.type === 'Video'; }
  isAudio(): boolean { return this.type === 'Audio'; }
  isSubtitle(): boolean { return this.type === 'Subtitle'; }

  /** "3840 x 1600" */
  resolution(): string {
    if (this.width <= 0 || this.height <= 0) return '';
    return this.width.toString() + ' x ' + this.height.toString();
  }

  /** "5.0 Mbps" */
  bitrateText(): string {
    if (this.bitrate <= 0) return '';
    if (this.bitrate >= 1000000) return (this.bitrate / 1000000).toFixed(1) + ' Mbps';
    return Math.round(this.bitrate / 1000).toString() + ' Kbps';
  }

  /** "8k/4k/1080p/720p" */
  qualityLabel(): string {
    const h = this.height;
    if (h >= 4000) return '8k';
    if (h >= 2000) return '4k';
    if (h >= 1000) return '1080p';
    if (h >= 700) return '720p';
    if (h >= 400) return '480p';
    return '';
  }

  /** "Stereo / 5.1 / 7.1" */
  channelLabel(): string {
    if (this.channels <= 0) return '';
    if (this.channels === 1) return 'Mono';
    if (this.channels === 2) return 'Stereo';
    if (this.channels === 6) return '5.1';
    if (this.channels === 8) return '7.1';
    return this.channels.toString() + 'ch';
  }

  /** "H264" */
  codecLabel(): string {
    if (this.codec.length === 0) return '';
    return this.codec.toUpperCase();
  }
}

export class MediaSource {
  id: string = '';
  container: string = '';
  sizeBytes: number = 0;
  streams: MediaStream[] = [];

  videoStream(): MediaStream | undefined {
    for (let i = 0; i < this.streams.length; i++) {
      if (this.streams[i].type === 'Video') {
        return this.streams[i];
      }
    }
    return undefined;
  }

  audioStreams(): MediaStream[] {
    const out: MediaStream[] = [];
    for (let i = 0; i < this.streams.length; i++) {
      if (this.streams[i].type === 'Audio') {
        out.push(this.streams[i]);
      }
    }
    return out;
  }

  subtitleStreams(): MediaStream[] {
    const out: MediaStream[] = [];
    for (let i = 0; i < this.streams.length; i++) {
      if (this.streams[i].type === 'Subtitle') {
        out.push(this.streams[i]);
      }
    }
    return out;
  }

  audioCount(): number {
    let n = 0;
    for (let i = 0; i < this.streams.length; i++) {
      if (this.streams[i].type === 'Audio') {
        n++;
      }
    }
    return n;
  }

  subtitleCount(): number {
    let n = 0;
    for (let i = 0; i < this.streams.length; i++) {
      if (this.streams[i].type === 'Subtitle') {
        n++;
      }
    }
    return n;
  }
}

export class ItemDetail {
  item: MediaItem = new MediaItem();
  sources: MediaSource[] = [];
}

/* ───────── 接口返回结构的解析中间态 ───────── */

export interface RawUserData {
  Played?: boolean;
  PlaybackPositionTicks?: number;
  IsFavorite?: boolean;
}

export interface RawImageTags {
  Primary?: string;
  Banner?: string;
  Logo?: string;
  Thumb?: string;
  Disc?: string;
  Art?: string;
  Backdrop?: string;
}

export interface RawItem {
  Id?: string;
  Name?: string;
  Type?: string;
  ProductionYear?: number;
  Overview?: string;
  CommunityRating?: number;
  RunTimeTicks?: number;
  IndexNumber?: number;
  ParentIndexNumber?: number;
  SeriesId?: string;
  SeriesName?: string;
  ImageTags?: RawImageTags;
  BackdropImageTags?: string[];
  DateCreated?: string;
  Genres?: string[];
  Path?: string;
  PremiereDate?: string;
  EndDate?: string;
  UserData?: RawUserData;
  MediaSources?: RawMediaSource[];
}

export interface RawMediaStream {
  Index?: number;
  Type?: string;
  Codec?: string;
  Language?: string;
  DisplayTitle?: string;
  Title?: string;
  IsDefault?: boolean;
  IsExternal?: boolean;
  Width?: number;
  Height?: number;
  BitRate?: number;
  FrameRate?: number;
  Profile?: string;
  Level?: number;
  AspectRatio?: string;
  PixelFormat?: string;
  ColorSpace?: string;
  ColorTransfer?: string;
  BitDepth?: number;
  Channels?: number;
  ChannelLayout?: string;
  SampleRate?: number;
  VideoRange?: string;
}

export interface RawMediaSource {
  Id?: string;
  Container?: string;
  Size?: number;
  MediaStreams?: RawMediaStream[];
}

export interface RawItemsResp {
  Items?: RawItem[];
  TotalRecordCount?: number;
}

export interface RawUser {
  Id?: string;
  Name?: string;
}

export interface RawAuthResp {
  AccessToken?: string;
  ServerName?: string;
  User?: RawUser;
}

export interface RawServerInfo {
  ServerName?: string;
  Version?: string;
  ProductName?: string;
}

/** 跳转播放页的参数 */
/** 一条字幕轨 */
export interface SubtitleTrack {
  index: number;
  language: string;
  title: string;
  url: string;
  isExternal: boolean;
}

export interface PlayParams {
  url: string;
  title: string;
  subtitle: string;
  isHls: boolean;
  startTicks: number;
  itemId: string;
  subtitles: SubtitleTrack[];
  /** 播放地址需要的认证 token（飞牛用 Authorization 头）*/
  token: string;
  nativeToken?: string;
  serviceKind?: string;
  streamHeaders?: Record<string, string>;
  playbackLeaseId?: string;
  useMpv?: boolean;
  isLive?: boolean;

  /* ── 进度 V2 需要的来源身份（方案 9.2）── */
  serverId: string;
  userId: string;
  itemType: string;
  seriesId: string;
  seasonNumber: number;
  episodeNumber: number;
  imageTag: string;
  /* ── R21/R22：大侧栏需要的数据（播放列表 + 视频源）── */
  /** 同剧集列表（播放列表侧栏），没有就是空数组 */
  episodes?: MediaItem[];
  /** 服务器给出的可选视频源 */
  sources?: MediaSource[];
  /** 当前选中的视频源 id（R22：不再写死 sources[0]） */
  selectedSourceId?: string;
}
/* ───────── 播放决策 ───────── */

/** 服务器给出的播放方案 */
export class PlaybackInfo {
  url: string = '';           // 最终播放地址
  isTranscode: boolean = false;  // 是否服务器转码
  isHls: boolean = false;        // 是否是 HLS（m3u8）
  mediaSourceId: string = '';
  /** null uses the provider default; an explicit empty object deliberately sends no credentials. */
  headers: Record<string, string> | null = null;
  isLive: boolean = false;
  /** Process-local resource ownership; routing passes a lease ID rather than this function. */
  release: (() => Promise<void>) | null = null;
}

/** PlaybackInfo 返回的 MediaSources 元素 */
export interface RawPlaybackSource {
  Id?: string;
  SupportsDirectPlay?: boolean;
  SupportsDirectStream?: boolean;
  SupportsTranscoding?: boolean;
  DirectStreamUrl?: string;
  TranscodingUrl?: string;
  TranscodingSubProtocol?: string;
}

/* ───────── DeviceProfile（上报给服务器的能力声明）───────── */

export interface PlayProfile {
  Container: string;
  Type: string;
  VideoCodec?: string;
  AudioCodec?: string;
  Protocol?: string;
  Context?: string;
  MaxAudioChannels?: string;
}

export interface SubtitleProfile {
  Format: string;
  Method: string;
}

export interface DeviceProfileBody {
  MaxStreamingBitrate: number;
  MaxStaticBitrate: number;
  DirectPlayProfiles: PlayProfile[];
  TranscodingProfiles: PlayProfile[];
  SubtitleProfiles: SubtitleProfile[];
}

export interface DeviceProfileWrapper {
  DeviceProfile: DeviceProfileBody;
}


/** PlaybackInfo 接口的完整返回 */
export interface RawPlaybackResp {
  MediaSources?: RawPlaybackSource[];
  PlaySessionId?: string;
  ErrorCode?: string;
}


/** 播放器里的轨道条目（音轨 / 字幕轨） */
export class TrackInfo {
  index: number = 0;
  label: string = '';

  constructor(index: number, label: string) {
    this.index = index;
    this.label = label;
  }
}


/** 演职员 */
export class Person {
  id: string = '';
  name: string = '';
  role: string = '';
  type: string = '';      // Actor / Director / Writer
  hasImage: boolean = false;
}

/** 条目里的 People 字段（接口返回） */
export interface RawPerson {
  Id?: string;
  Name?: string;
  Role?: string;
  Type?: string;
  PrimaryImageTag?: string;
}

/** 带 People 的条目 */
export interface RawItemWithPeople extends RawItem {
  People?: RawPerson[];
}
