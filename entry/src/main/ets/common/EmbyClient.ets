import { http } from '@kit.NetworkKit';
import {
  ServerConfig, Library, MediaItem, MediaSource, MediaStream, ItemDetail,
  RawAuthResp, RawItemsResp, RawItem, RawMediaSource, RawMediaStream,
  RawServerInfo, RawUser, PlaybackInfo, RawPlaybackSource,
  PlayProfile, SubtitleProfile, DeviceProfileBody, DeviceProfileWrapper, RawPlaybackResp,
  Person, RawPerson, RawItemWithPeople
} from './Models';
import { Dbg } from './Dbg';

/**
 * 通用 Emby / Jellyfin 协议客户端
 * 只提供 Emby-compatible 协议；飞牛原生登录、播放和差异由 services/FnosAdapter 管理。
 *
 * Jellyfin 使用官方 Authorization: MediaBrowser ... Token="..."。
 * FnOS / Emby 兼容接口保留其已有的 X-Emby-* 请求头。
 */
export class EmbyClient {

  private static authorizationHeaders(server: ServerConfig, includeToken: boolean = true): Record<string, string> {
    if (server.kind === 'jellyfin') {
      // Legacy X-Emby-* channels can be disabled server-side. Values are URL encoded
      // inside quoted parameters as required by Jellyfin's authorization scheme.
      let authorization = 'MediaBrowser Client="VablePlayer", Device="HarmonyOS", DeviceId="' +
        encodeURIComponent('nasplayer-' + server.id) + '", Version="1.0.0"';
      if (includeToken && server.token.length > 0) {
        authorization += ', Token="' + encodeURIComponent(server.token) + '"';
      }
      return { 'Authorization': authorization };
    }
    return { 'X-Emby-Authorization': server.authHeader(), 'X-Emby-Token': server.token };
  }

  private static requireSuccess(code: number, path: string, login: boolean = false): void {
    if (code >= 200 && code < 300) { return; }
    Dbg.setApi(path, 'HTTP ' + code.toString());
    const status = '（HTTP ' + code.toString() + '）';
    if (code === 401) {
      throw new Error((login ? '登录失败：账号或密码不正确' : '登录会话已失效，请重新登录服务器') + status);
    }
    if (code === 403) { throw new Error('服务器拒绝访问，请检查账号权限和远程访问设置' + status); }
    if (code === 404) { throw new Error('服务接口不存在，请检查来源类型、端口和服务器子路径' + status); }
    if (code === 429) { throw new Error('服务器请求过于频繁，请稍后重试' + status); }
    if (code >= 500) { throw new Error('服务器或反向代理发生错误，请检查服务状态' + status); }
    // Server error bodies can contain credentials or HTML. Never put them in UI/logs.
    throw new Error('服务器请求失败' + status);
  }

  private static async request(server: ServerConfig, path: string): Promise<string> {
    const req = http.createHttp();
    try {
      const headers = EmbyClient.authorizationHeaders(server);
      headers['Accept'] = 'application/json';
      const resp = await req.request(server.baseUrl() + path, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 12000,
        readTimeout: 26000,
        expectDataType: http.HttpDataType.STRING
      });
      const code: number = resp.responseCode as number;
      const body: string = resp.result as string;
      EmbyClient.requireSuccess(code, path);
      return body;
    } finally {
      req.destroy();
    }
  }

  private static async postJson(server: ServerConfig, path: string, body: string, login: boolean = false): Promise<string> {
    const req = http.createHttp();
    try {
      const headers = EmbyClient.authorizationHeaders(server, !login);
      headers['Content-Type'] = 'application/json';
      headers['Accept'] = 'application/json';
      const resp = await req.request(server.baseUrl() + path, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        connectTimeout: 12000,
        readTimeout: 26000,
        expectDataType: http.HttpDataType.STRING
      });
      EmbyClient.requireSuccess(resp.responseCode as number, path, login);
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  /* ───────── 探测 ───────── */

  static async probePublic(host: string, port: number): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request('http://' + host + ':' + port.toString() + '/System/Info/Public', {
        method: http.RequestMethod.GET,
        header: {
          'X-Emby-Authorization': 'MediaBrowser Client="NAS影库", Device="HarmonyOS", DeviceId="probe", Version="1.0.0"',
          'Accept': 'application/json'
        } as Record<string, string>,
        connectTimeout: 8000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      });
      const info = JSON.parse(resp.result as string) as RawServerInfo;
      return info.ServerName !== undefined ? info.ServerName : '';
    } catch (e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  /* ───────── 登录 ───────── */

  static async login(server: ServerConfig, password: string): Promise<ServerConfig> {
    const payload: Record<string, string> = {
      'Username': server.username,
      'Pw': password
    };
    if (server.kind !== 'jellyfin') { payload['Password'] = password; }
    const raw = await EmbyClient.postJson(server, '/Users/AuthenticateByName',
      JSON.stringify(payload), true);
    let d: RawAuthResp;
    try { d = JSON.parse(raw) as RawAuthResp; }
    catch (e) { throw new Error('登录失败：服务器返回了无效的 JSON，请检查来源类型、端口或子路径'); }
    if (d === null || typeof d !== 'object' || Array.isArray(d)) {
      throw new Error('登录失败：服务器返回了无效的登录结果');
    }
    const token: string = typeof d.AccessToken === 'string' ? d.AccessToken : '';
    const user: RawUser = d.User !== undefined && d.User !== null ? d.User : {} as RawUser;
    const uid: string = typeof user.Id === 'string' ? user.Id : '';
    if (token.length === 0 || uid.length === 0) {
      throw new Error('登录失败：服务器未返回 token');
    }
    const sName: string = d.ServerName !== undefined ? d.ServerName : server.serverName;
    return new ServerConfig(server.id, server.kind, snameOr(sName, server.name), server.host,
      server.port, server.username, token, uid, sName, server.version);
  }

  /* ───────── 媒体库 ───────── */

  static async verifyTokenUser(server: ServerConfig): Promise<void> {
    if (server.userId.length === 0) { throw new Error('令牌连接需要真实的媒体库用户 ID'); }
    const raw = await EmbyClient.request(server, '/Users/' + encodeURIComponent(server.userId));
    const user = JSON.parse(raw) as RawUser;
    if (user.Id !== server.userId) { throw new Error('令牌与所选媒体库用户身份不匹配'); }
  }

  static async getViews(server: ServerConfig): Promise<Library[]> {
    const raw = await EmbyClient.request(server, '/Users/' + server.userId + '/Views');
    const d = JSON.parse(raw) as RawItemsResp;
    const out: Library[] = [];
    const items: RawItem[] = d.Items !== undefined ? d.Items : [];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      out.push(new Library(
        it.Id !== undefined ? it.Id : '',
        it.Name !== undefined ? it.Name : '',
        it.Type !== undefined ? it.Type : ''
      ));
    }
    return out;
  }

  /* ───────── 条目 ───────── */

  static async getItems(server: ServerConfig, parentId: string, start: number,
                        limit: number, recursive: boolean): Promise<MediaItem[]> {
    const path = '/Users/' + server.userId + '/Items' +
      '?ParentId=' + parentId +
      '&StartIndex=' + start.toString() +
      '&Limit=' + limit.toString() +
      '&Recursive=' + (recursive ? 'true' : 'false') +
      '&Fields=ProductionYear,RunTimeTicks,Overview,CommunityRating,ImageTags,UserData,Genres,DateCreated,PremiereDate' +
      '&ImageTypeLimit=1&EnableImageTypes=Primary,Backdrop&EnableUserData=true' +
      '&SortBy=SortName&SortOrder=Ascending';
    const raw = await EmbyClient.request(server, path);
    const d = JSON.parse(raw) as RawItemsResp;
    return EmbyClient.filterListItems(EmbyClient.toItems(d));
  }

  static async getLatest(server: ServerConfig, parentId: string, limit: number): Promise<MediaItem[]> {
    const path = '/Users/' + server.userId + '/Items/Latest?ParentId=' + parentId +
      '&Limit=' + limit.toString() +
      '&Fields=ProductionYear,RunTimeTicks,ImageTags,UserData';
    const raw = await EmbyClient.request(server, path);
    const trimmed = raw.trim();
    const out: MediaItem[] = [];
    if (trimmed.startsWith('[')) {
      const arr = JSON.parse(trimmed) as RawItem[];
      for (let i = 0; i < arr.length; i++) {
        out.push(EmbyClient.toItem(arr[i]));
      }
    } else {
      const d = JSON.parse(trimmed) as RawItemsResp;
      return EmbyClient.filterListItems(EmbyClient.toItems(d));
    }
    return EmbyClient.filterListItems(out);
  }

  static async getResume(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    try {
      // ★ 飞牛影视不支持 /Items/Resume（400 + 26秒），改用 Filters=IsResumable
      const path = '/Users/' + server.userId + '/Items?Filters=IsResumable' +
        '&Recursive=true&Limit=' + limit.toString() +
        '&IncludeItemTypes=Movie,Episode' +
        '&Fields=ProductionYear,RunTimeTicks,ImageTags,UserData';
      const raw = await EmbyClient.request(server, path);
      const d = JSON.parse(raw) as RawItemsResp;
      return EmbyClient.toItems(d);
    } catch (e) {
      return [];
    }
  }

  static async getItemDetail(server: ServerConfig, id: string): Promise<ItemDetail> {
    const path = '/Items/' + id +
      '?Fields=MediaSources,Overview,ProductionYear,RunTimeTicks,CommunityRating,ImageTags,UserData,Genres,Path,PremiereDate,People,Studios' +
      (server.kind === 'jellyfin' ? '&UserId=' + encodeURIComponent(server.userId) : '');
    const raw = await EmbyClient.request(server, path);
    const o = JSON.parse(raw) as RawItem;
    const detail = new ItemDetail();
    detail.item = EmbyClient.toItem(o);
    const srcs: RawMediaSource[] = o.MediaSources !== undefined ? o.MediaSources : [];
    for (let i = 0; i < srcs.length; i++) {
      const m = srcs[i];
      const ms = new MediaSource();
      ms.id = m.Id !== undefined ? m.Id : '';
      ms.container = m.Container !== undefined ? m.Container : '';
      ms.sizeBytes = m.Size !== undefined ? m.Size : 0;
      const rawStreams: RawMediaStream[] = m.MediaStreams !== undefined ? m.MediaStreams : [];
      for (let j = 0; j < rawStreams.length; j++) {
        const s = rawStreams[j];
        const st = new MediaStream();
        st.index = s.Index !== undefined ? s.Index : 0;
        st.type = s.Type !== undefined ? s.Type : '';
        st.codec = s.Codec !== undefined ? s.Codec : '';
        st.language = s.Language !== undefined ? s.Language : '';
        st.title = s.DisplayTitle !== undefined ? s.DisplayTitle :
          (s.Title !== undefined ? s.Title : '');
        st.isDefault = s.IsDefault !== undefined ? s.IsDefault : false;
        st.isExternal = s.IsExternal !== undefined ? s.IsExternal : false;
        st.width = s.Width !== undefined ? s.Width : 0;
        st.height = s.Height !== undefined ? s.Height : 0;
        st.bitrate = s.BitRate !== undefined ? s.BitRate : 0;
        st.frameRate = s.FrameRate !== undefined ? s.FrameRate : 0;
        st.profile = s.Profile !== undefined ? s.Profile : '';
        st.level = s.Level !== undefined ? s.Level : 0;
        st.aspectRatio = s.AspectRatio !== undefined ? s.AspectRatio : '';
        st.pixelFormat = s.PixelFormat !== undefined ? s.PixelFormat : '';
        st.colorSpace = s.ColorSpace !== undefined ? s.ColorSpace : '';
        st.colorTransfer = s.ColorTransfer !== undefined ? s.ColorTransfer : '';
        st.bitDepth = s.BitDepth !== undefined ? s.BitDepth : 0;
        st.channels = s.Channels !== undefined ? s.Channels : 0;
        st.channelLayout = s.ChannelLayout !== undefined ? s.ChannelLayout : '';
        st.sampleRate = s.SampleRate !== undefined ? s.SampleRate : 0;
        st.videoRange = s.VideoRange !== undefined ? s.VideoRange : '';
        st.isHdr = st.videoRange.toUpperCase().indexOf('HDR') >= 0;
        ms.streams.push(st);
      }
      detail.sources.push(ms);
    }
    return detail;
  }

  static async getSeasons(server: ServerConfig, seriesId: string): Promise<MediaItem[]> {
    const path = '/Shows/' + seriesId + '/Seasons?UserId=' + server.userId +
      '&Fields=ProductionYear,ImageTags,UserData';
    const raw = await EmbyClient.request(server, path);
    const d = JSON.parse(raw) as RawItemsResp;
    return EmbyClient.toItems(d);
  }

  static async getEpisodes(server: ServerConfig, seriesId: string,
                           seasonId: string): Promise<MediaItem[]> {
    const path = '/Shows/' + seriesId + '/Episodes?UserId=' + server.userId +
      (seasonId.length > 0 ? '&SeasonId=' + seasonId : '') +
      '&Fields=ProductionYear,RunTimeTicks,ImageTags,Overview,UserData';
    const raw = await EmbyClient.request(server, path);
    const d = JSON.parse(raw) as RawItemsResp;
    const items = EmbyClient.toItems(d);
    const reportedTotal = Number(d.TotalRecordCount);
    const total = Number.isFinite(reportedTotal) && reportedTotal >= 0 && Math.floor(reportedTotal) === reportedTotal
      ? reportedTotal : items.length;
    const maximum = 5000;
    if (total > maximum || items.length > maximum) {
      throw new Error('分集列表超过5000项，请手动选择剧集');
    }
    // Standard unbounded responses need no extra request. Compatibility servers may still cap them.
    if (total <= items.length) { return items; }
    if (items.length === 0) { throw new Error('分集列表返回空页，无法读取完整剧集'); }
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < items.length; i++) {
      if (items[i].id.length === 0 || seen.has(items[i].id)) {
        throw new Error('分集列表包含重复或无效条目，请重试');
      }
      seen.add(items[i].id);
    }
    let start = items.length;
    while (start < total) {
      const pageRaw = await EmbyClient.request(server, path + '&StartIndex=' + start.toString() + '&Limit=200');
      const page = JSON.parse(pageRaw) as RawItemsResp;
      const pageTotal = Number(page.TotalRecordCount);
      if (Number.isFinite(pageTotal) && pageTotal > 0 && pageTotal !== total) {
        throw new Error('分集列表在加载时发生变化，请重试');
      }
      const next = EmbyClient.toItems(page);
      if (next.length === 0) { throw new Error('分集列表返回空页，无法读取完整剧集'); }
      if (start + next.length > total) { throw new Error('分集列表数量不一致，请重试'); }
      for (let i = 0; i < next.length; i++) {
        if (next[i].id.length === 0 || seen.has(next[i].id)) {
          throw new Error('服务器返回重复分集页，无法读取完整剧集');
        }
        seen.add(next[i].id);
        items.push(next[i]);
      }
      start += next.length;
    }
    return items;
  }

  static async search(server: ServerConfig, q: string, limit: number): Promise<MediaItem[]> {
    const enc = encodeURIComponent(q);
    const path = '/Users/' + server.userId + '/Items?SearchTerm=' + enc +
      '&Limit=' + limit.toString() +
      '&Recursive=true&IncludeItemTypes=Movie,Series,Episode' +
      '&Fields=ProductionYear,ImageTags,RunTimeTicks';
    const raw = await EmbyClient.request(server, path);
    const d = JSON.parse(raw) as RawItemsResp;
    return EmbyClient.toItems(d);
  }

  /* ═══════════ 收藏 ═══════════ */

  /** 收藏列表 */
  static async getFavorites(server: ServerConfig, limit: number): Promise<MediaItem[]> {
    // Preserve transport failures (including unsupported-provider 404) for the caller's error UI.
    const path = '/Users/' + server.userId + '/Items?Filters=IsFavorite' +
      '&Recursive=true&Limit=' + limit.toString() +
      '&IncludeItemTypes=Movie,Series,Episode' +
      '&Fields=ProductionYear,RunTimeTicks,ImageTags,UserData';
    const raw = await EmbyClient.request(server, path);
    return EmbyClient.toItems(JSON.parse(raw) as RawItemsResp);
  }

  /** 加收藏 */
  static async addFavorite(server: ServerConfig, itemId: string): Promise<void> {
    await EmbyClient.postJson(server,
      '/Users/' + server.userId + '/FavoriteItems/' + itemId, '');
  }

  /** 取消收藏 */
  static async removeFavorite(server: ServerConfig, itemId: string): Promise<void> {
    const req = http.createHttp();
    try {
      const headers = EmbyClient.authorizationHeaders(server);
      const resp = await req.request(server.baseUrl() + '/Users/' + server.userId +
        '/FavoriteItems/' + itemId, {
        method: http.RequestMethod.DELETE,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      EmbyClient.requireSuccess(resp.responseCode as number, '/Users/FavoriteItems');
    } finally {
      req.destroy();
    }
  }

  /** 查是否已收藏 */
  static async isFavorite(server: ServerConfig, itemId: string): Promise<boolean> {
    try {
      const raw = await EmbyClient.request(server, '/Items/' + itemId +
        '?Fields=UserData' + (server.kind === 'jellyfin' ? '&UserId=' + encodeURIComponent(server.userId) : ''));
      const o = JSON.parse(raw) as RawItem;
      if (o.UserData !== undefined) {
        return o.UserData.IsFavorite === true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /* ═══════════ 演职员 ═══════════ */

  static async getPeople(server: ServerConfig, itemId: string): Promise<Person[]> {
    const out: Person[] = [];
    try {
      const raw = await EmbyClient.request(server, '/Items/' + itemId + '?Fields=People' +
        (server.kind === 'jellyfin' ? '&UserId=' + encodeURIComponent(server.userId) : ''));
      const o = JSON.parse(raw) as RawItemWithPeople;
      const ps: RawPerson[] = o.People !== undefined ? o.People : [];
      for (let i = 0; i < ps.length && i < 30; i++) {
        const rp = ps[i];
        const pr = new Person();
        pr.id = rp.Id !== undefined ? rp.Id : '';
        pr.name = rp.Name !== undefined ? rp.Name : '';
        pr.role = rp.Role !== undefined ? rp.Role : '';
        pr.type = rp.Type !== undefined ? rp.Type : '';
        pr.hasImage = rp.PrimaryImageTag !== undefined;
        out.push(pr);
      }
    } catch (e) {
      // 没演员就算了
    }
    return out;
  }

  /** 演员头像 */
  static personImageUrl(server: ServerConfig, personId: string, w: number): string {
    return server.baseUrl() + '/Items/' + personId +
      '/Images/Primary?maxWidth=' + w.toString() + '&quality=85' +
      (server.kind === 'jellyfin' ? '' : '&X-Emby-Token=' + server.token);
  }

  /* ═══════════ 播放决策：直连 or 转码 ═══════════ */

  /**
   * 询问服务器该怎么播。
   *
   * ★ Jellyfin/Emby 客户端的标准做法：
   *   把本机支持的编解码报给服务器（DeviceProfile），
   *   服务器判断能不能直连，不能就给一个 HLS 转码地址。
   *
   * 鸿蒙平台解码能力（SDK CodecMimeType）：
   *   视频 H.264 / H.265 / VP8 / MPEG2 / MPEG4
   *   音频 AAC / MP3 / FLAC / Vorbis
   *   → 没有 DTS / AC3 / EAC3 / TrueHD，遇到就转码
   */
  static async getPlaybackInfo(server: ServerConfig, itemId: string,
                               mediaSourceId: string, startTicks: number): Promise<PlaybackInfo> {
    const path = '/Items/' + itemId + '/PlaybackInfo' +
      '?UserId=' + server.userId +
      '&StartTimeTicks=' + startTicks.toString() +
      '&IsPlayback=true&AutoOpenLiveStream=true' +
      (mediaSourceId.length > 0 ? '&MediaSourceId=' + mediaSourceId : '');

    const result = new PlaybackInfo();
    try {
      const raw = await EmbyClient.postJson(server, path, JSON.stringify(EmbyClient.deviceProfile()));
      // Non-JSON responses cannot be used as playback information.
      if (raw.trim().startsWith('<')) {
        result.url = EmbyClient.directStreamUrl(server, itemId);
        return result;
      }
      const d = JSON.parse(raw) as RawPlaybackResp;
      const srcs: RawPlaybackSource[] = d.MediaSources !== undefined ? d.MediaSources : [];
      if (srcs.length === 0) {
        result.url = EmbyClient.directStreamUrl(server, itemId);
        return result;
      }
      const src = srcs[0];
      const canDirect: boolean = src.SupportsDirectPlay === true || src.SupportsDirectStream === true;
      const transUrl: string = src.TranscodingUrl !== undefined ? src.TranscodingUrl : '';
      const directUrl: string = src.DirectStreamUrl !== undefined ? src.DirectStreamUrl : '';

      if (canDirect && directUrl.length > 0) {
        result.url = directUrl.startsWith('http') ? directUrl : server.baseUrl() + directUrl;
        result.isTranscode = false;
      } else if (transUrl.length > 0) {
        result.url = transUrl.startsWith('http') ? transUrl : server.baseUrl() + transUrl;
        result.isTranscode = true;
        result.isHls = transUrl.indexOf('.m3u8') >= 0;
      } else {
        result.url = EmbyClient.directStreamUrl(server, itemId);
      }
      result.mediaSourceId = src.Id !== undefined ? src.Id : mediaSourceId;
    } catch (e) {
      result.url = EmbyClient.directStreamUrl(server, itemId);
    }
    return result;
  }

  /** 上报给服务器的设备能力 */
  private static deviceProfile(): DeviceProfileWrapper {
    const dp1: PlayProfile = {
      Container: 'mp4,m4v,mkv,webm,ts,m2ts',
      Type: 'Video',
      VideoCodec: 'h264,hevc,vp8,mpeg2video,mpeg4',
      AudioCodec: 'aac,mp3,flac,vorbis,opus',
      MaxAudioChannels: '8'
    };
    const dp2: PlayProfile = {
      Container: 'mp3,aac,flac,wav,m4a',
      Type: 'Audio',
      AudioCodec: 'mp3,aac,flac,vorbis'
    };
    const tp1: PlayProfile = {
      Container: 'ts',
      Type: 'Video',
      VideoCodec: 'h264',
      AudioCodec: 'aac',
      Protocol: 'hls',
      Context: 'Streaming',
      MaxAudioChannels: '2'
    };
    const sp1: SubtitleProfile = { Format: 'srt', Method: 'External' };
    const sp2: SubtitleProfile = { Format: 'ass', Method: 'External' };
    const sp3: SubtitleProfile = { Format: 'vtt', Method: 'External' };

    const body: DeviceProfileBody = {
      MaxStreamingBitrate: 120000000,
      MaxStaticBitrate: 120000000,
      DirectPlayProfiles: [dp1, dp2],
      TranscodingProfiles: [tp1],
      SubtitleProfiles: [sp1, sp2, sp3]
    };
    const wrapper: DeviceProfileWrapper = { DeviceProfile: body };
    return wrapper;
  }

  /** 直连播放地址 */
  /** Emby/Jellyfin standard direct file stream; provider-specific FnOS URLs live in FnosAdapter. */
  static streamUrl(server: ServerConfig, itemId: string): string {
    return server.baseUrl() + '/Videos/' + encodeURIComponent(itemId) + '/stream?Static=true';
  }

  /** 旧接口保留，指向新地址 */
  static directStreamUrl(server: ServerConfig, itemId: string): string {
    return EmbyClient.streamUrl(server, itemId);
  }

  /** 播放时需要的请求头 */
  static streamHeaders(server: ServerConfig): Record<string, string> {
    if (server.kind === 'jellyfin') { return EmbyClient.authorizationHeaders(server); }
    const h: Record<string, string> = {};
    h['Authorization'] = server.token;
    h['X-Emby-Token'] = server.token;
    return h;
  }

  /** 播放器请求头 */
  static playHeaders(server: ServerConfig): Record<string, string> {
    return EmbyClient.authorizationHeaders(server);
  }


  /**
   * 图片地址
   * ★ 飞牛影视必须带 tag（ImageTags.Primary 的值），否则 404
   * ★ Jellyfin/Emby 带不带都行
   */
  static imageUrl(server: ServerConfig, itemId: string, maxWidth: number, tag: string): string {
    let u = server.baseUrl() + '/Items/' + itemId +
      '/Images/Primary?maxWidth=' + maxWidth.toString() + '&quality=90';
    if (tag.length > 0) {
      u = u + '&tag=' + tag;
    }
    const full = server.kind === 'jellyfin' ? u : u + '&X-Emby-Token=' + server.token;
    Dbg.setImage(full);
    return full;
  }

  /**
   * 背景大图
   * ★ 飞牛的 /Images/Backdrop/0 返回 4303 字节 HTML 错误页（不是图）
   *   所以：有 backdropTag 用 Backdrop，没有就用 Primary 图顶替
   */
  static backdropUrl(server: ServerConfig, itemId: string, maxWidth: number,
                     backdropTag: string, primaryTag: string): string {
    if (backdropTag.length > 0) {
      return server.baseUrl() + '/Items/' + itemId +
        '/Images/Backdrop/0?maxWidth=' + maxWidth.toString() + '&quality=85' +
        '&tag=' + backdropTag + (server.kind === 'jellyfin' ? '' : '&X-Emby-Token=' + server.token);
    }
    if (primaryTag.length > 0) {
      return server.baseUrl() + '/Items/' + itemId +
        '/Images/Primary?maxWidth=' + maxWidth.toString() + '&quality=80' +
        '&tag=' + primaryTag + (server.kind === 'jellyfin' ? '' : '&X-Emby-Token=' + server.token);
    }
    return '';
  }

  /** 图片请求头（Image 组件可以通过 httpHeader 带上） */
  static imageHeaders(server: ServerConfig): Record<string, string> {
    return EmbyClient.authorizationHeaders(server);
  }

  /** 字幕下载地址（外挂 / 内封提取） */
  static subtitleUrl(server: ServerConfig, itemId: string, mediaSourceId: string,
                     index: number, codec: string): string {
    let fmt = 'srt';
    const lc = codec.toLowerCase();
    if (lc === 'ass' || lc === 'ssa') {
      fmt = 'ass';
    } else if (lc === 'vtt' || lc === 'webvtt') {
      fmt = 'vtt';
    }
    const ms = mediaSourceId.length > 0 ? mediaSourceId : itemId;
    // AVPlayer.addSubtitleFromUrl cannot accept custom headers. Jellyfin's
    // documented fallback is the case-sensitive ApiKey query (not api_key).
    const auth = server.kind === 'jellyfin' ? '?ApiKey=' + encodeURIComponent(server.token)
      : '?X-Emby-Token=' + server.token + '&api_key=' + server.token;
    return server.baseUrl() + '/Videos/' + itemId + '/' + ms +
      '/Subtitles/' + index.toString() + '/0/Stream.' + fmt +
      auth;
  }

  /* ───────── 进度上报 ───────── */

  static async reportProgress(server: ServerConfig, itemId: string,
                              positionTicks: number, played: boolean): Promise<void> {
    const payload: Record<string, string | number | boolean> = {
      'ItemId': itemId,
      'PositionTicks': positionTicks,
      'CanSeek': true,
      'IsPaused': false
    };
    if (played) {
      payload['Played'] = true;
    }
    try {
      await EmbyClient.postJson(server, '/Sessions/Playing/Progress', JSON.stringify(payload));
    } catch (e) {
      // 忽略上报失败
    }
  }

  /* ───────── 解析辅助 ───────── */

  private static toItems(d: RawItemsResp): MediaItem[] {
    const out: MediaItem[] = [];
    const items: RawItem[] = d.Items !== undefined ? d.Items : [];
    for (let i = 0; i < items.length; i++) {
      out.push(EmbyClient.toItem(items[i]));
    }
    return out;
  }

  /**
   * 过滤掉不该出现在列表里的条目
   * ★ 飞牛影视会把 Series 内部的 Season 暴露成 CollectionFolder，
   *   而且 ExcludeItemTypes / IsFolder=false 都过滤不掉，只能客户端过滤。
   */
  static filterListItems(list: MediaItem[]): MediaItem[] {
    const out: MediaItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const it = list[i];
      // 只要这些类型
      if (it.type === 'Series' || it.type === 'Movie' || it.type === 'Episode' ||
          it.type === 'Video' || it.type === 'MusicVideo' || it.type === 'BoxSet') {
        // 再排除名字像 "Season 1" 的
        const nm = it.name.trim();
        const isSeasonName = nm.startsWith('Season ') || nm.startsWith('第') && nm.endsWith('季');
        if (!isSeasonName) {
          out.push(it);
        }
      }
    }
    return out;
  }

  private static toItem(o: RawItem): MediaItem {
    const m = new MediaItem();
    m.id = o.Id !== undefined ? o.Id : '';
    m.name = o.Name !== undefined ? o.Name : '';
    m.type = o.Type !== undefined ? o.Type : '';
    m.year = o.ProductionYear !== undefined ? o.ProductionYear : 0;
    m.overview = o.Overview !== undefined ? o.Overview : '';
    m.rating = o.CommunityRating !== undefined ? o.CommunityRating : 0;
    m.runtimeTicks = o.RunTimeTicks !== undefined ? o.RunTimeTicks : 0;
    m.indexNumber = o.IndexNumber !== undefined ? o.IndexNumber : 0;
    m.parentIndexNumber = o.ParentIndexNumber !== undefined ? o.ParentIndexNumber : 0;
    m.indexNumberKnown = typeof o.IndexNumber === 'number' && Number.isFinite(o.IndexNumber) &&
      o.IndexNumber >= 0 && Math.floor(o.IndexNumber) === o.IndexNumber;
    m.parentIndexNumberKnown = typeof o.ParentIndexNumber === 'number' && Number.isFinite(o.ParentIndexNumber) &&
      o.ParentIndexNumber >= 0 && Math.floor(o.ParentIndexNumber) === o.ParentIndexNumber;
    m.seriesId = o.SeriesId !== undefined ? o.SeriesId : '';
    m.seriesName = o.SeriesName !== undefined ? o.SeriesName : '';
    m.createdAt = typeof o.DateCreated === 'string' ? o.DateCreated : '';
    m.premiereDate = typeof o.PremiereDate === 'string' ? o.PremiereDate : '';
    if (Array.isArray(o.Genres)) {
      m.genres = o.Genres.filter((genre: string) => typeof genre === 'string' && genre.trim().length > 0);
    }
    if (o.Path !== undefined) {
      m.path = o.Path;
    }
    if (o.ImageTags !== undefined && o.ImageTags.Primary !== undefined &&
        o.ImageTags.Primary.length > 0) {
      m.hasPrimaryImage = true;
      m.imageTag = o.ImageTags.Primary;
    }
    if (o.ImageTags !== undefined && o.ImageTags.Backdrop !== undefined) {
      m.backdropTag = o.ImageTags.Backdrop;
    }
    if (Array.isArray(o.BackdropImageTags) && o.BackdropImageTags.length > 0 &&
        typeof o.BackdropImageTags[0] === 'string') {
      m.backdropTag = o.BackdropImageTags[0];
    }
    // 容器格式：只有详情接口返回 MediaSources，列表接口通常没有
    if (o.MediaSources !== undefined && o.MediaSources.length > 0) {
      const c = o.MediaSources[0].Container;
      if (c !== undefined) {
        m.container = c.toUpperCase();
      }
    }
    if (o.UserData !== undefined && o.UserData !== null) {
      m.favoriteKnown = typeof o.UserData.IsFavorite === 'boolean';
      m.isFavorite = o.UserData.IsFavorite === true;
      m.played = o.UserData.Played !== undefined ? o.UserData.Played : false;
      m.progressTicks = o.UserData.PlaybackPositionTicks !== undefined ?
        o.UserData.PlaybackPositionTicks : 0;
    }
    return m;
  }
}

function snameOr(s: string, fallback: string): string {
  return s.length > 0 ? s : fallback;
}
