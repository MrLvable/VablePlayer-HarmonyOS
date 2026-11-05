import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface NativeResponse<T> {
  code?: number;
  data?: T;
  msg?: string;
  message?: string;
}

interface NativeFile {
  guid: string;
  path?: string;
}

interface NativeTrack {
  guid: string;
  media_guid?: string;
  codec_name?: string;
  bps?: number;
  channels?: number;
  height?: number;
}

interface NativeQuality {
  resolution: string;
  bitrate: number;
  progressive?: boolean;
  is_m3u8?: boolean;
}

interface NativeStreams {
  files?: NativeFile[];
  file_stream?: NativeFile;
  video_streams?: NativeTrack[];
  audio_streams?: NativeTrack[];
  qualities?: NativeQuality[];
}

interface NativeInfoBody {
  item_guid: string;
}

interface NativeCanonicalItem {
  guid?: string;
}

interface NativePlayInfo {
  item?: NativeCanonicalItem;
  type?: string;
}

interface QualityBody {
  media_guid: string;
}

interface PlayBody {
  media_guid: string;
  video_guid: string;
  video_encoder: string;
  resolution: string;
  bitrate: number;
  startTimestamp: number;
  audio_encoder: string;
  audio_guid: string;
  subtitle_guid: string;
  channels: number;
}

interface FilePlayBody {
  media_guid: string;
  resolution: string;
  bitrate: number;
  startTimestamp: number;
  forced_sdr: number;
  without_stream: boolean;
}

interface NativePlay {
  play_link?: string;
  is_m3u8?: boolean;
}

interface QuitBody {
  req: string;
  reqid: string;
  playLink: string;
}

interface NativeLoginBody {
  app_name: string;
  username: string;
  password: string;
  nonce: string;
}

interface NativeLogin {
  token?: string;
}

export class FnosPlaybackResult {
  url: string = '';
  isHls: boolean = false;
}

/** Native FnOS playback negotiation, separate from its Emby compatibility API. */
export class FnosPlayback {
  private generation: number = 0;
  private closed: boolean = true;
  private base: string = '';
  private token: string = '';
  private authStyle: number = 1;
  private playLink: string = '';
  private requests: http.HttpRequest[] = [];
  private readAttempts: number = 0;

  /** Credentials are used for this request only and are never retained or logged. */
  static async login(base: string, username: string, password: string): Promise<string> {
    let origin = base.replace(/\/+$/, '');
    if (origin.endsWith('/v')) { origin = origin.substring(0, origin.length - 2); }
    if (!/^https?:\/\//i.test(origin) || username.trim().length === 0 || password.length === 0) {
      throw new Error('缺少飞牛原生登录信息');
    }
    const body: NativeLoginBody = {
      app_name: 'trimemedia-web', username: username.trim(), password: password,
      nonce: Math.floor(100000 + Math.random() * 900000).toString()
    };
    const raw = JSON.stringify(body);
    const helper = new FnosPlayback();
    const signature = await helper.signature('/v/api/v1/login', raw, '', 3, '');
    const request = http.createHttp();
    try {
      const response = await request.request(origin + '/v/api/v1/login', {
        method: http.RequestMethod.POST,
        header: {
          'authx': signature, 'Cookie': 'mode=relay',
          'Accept': 'application/json', 'Content-Type': 'application/json'
        },
        extraData: raw, usingCache: false, connectTimeout: 8000, readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING, maxLimit: 524288
      });
      const status = response.responseCode as number;
      const text = (response.result as string).trim();
      if (status < 200 || status >= 300 || !text.startsWith('{')) {
        hilog.warn(0x0001, 'NasFnos', 'native login status=%{public}d json=%{public}s',
          status, text.startsWith('{') ? 'Y' : 'N');
        throw new Error('飞牛原生登录接口不可用');
      }
      const envelope = JSON.parse(text) as NativeResponse<NativeLogin>;
      const code = envelope.code !== undefined ? envelope.code : -1;
      const login = envelope.data;
      const hasToken = login !== undefined && login !== null && typeof login.token === 'string'
        && login.token.trim().length > 0;
      hilog.info(0x0001, 'NasFnos', 'native login status=%{public}d code=%{public}d credential=%{public}s',
        status, code, hasToken ? 'Y' : 'N');
      if (code !== 0 || !hasToken || login === undefined || login === null || login.token === undefined) {
        const detail = typeof envelope.msg === 'string' ? envelope.msg
          : (typeof envelope.message === 'string' ? envelope.message : '');
        hilog.warn(0x0001, 'NasFnos', 'native login rejected code=%{public}d reason=%{public}s',
          code, helper.safeMessage(detail));
        throw new Error('飞牛原生登录失败（' + code.toString() + '）');
      }
      return login.token;
    } finally {
      request.destroy();
    }
  }

  async resolve(url: string, token: string, itemId: string): Promise<FnosPlaybackResult> {
    const closeGeneration = this.generation + 1;
    await this.close();
    if (this.generation !== closeGeneration) {
      throw new Error('原生播放连接已取消');
    }
    const marker = '/v/api/v1/media/range/';
    const index = url.indexOf(marker);
    if (index < 0 || itemId.length === 0 || token.length === 0) {
      throw new Error('缺少飞牛原生播放连接信息');
    }
    const gen = ++this.generation;
    this.closed = false;
    this.base = url.substring(0, index);
    this.token = token;
    this.playLink = '';
    this.readAttempts = 0;

    // The native client resolves its item first; an Emby item ID is not assumed
    // to be the native episode/media GUID accepted by the stream-list endpoint.
    const infoBody: NativeInfoBody = { item_guid: itemId };
    this.readAttempts++;
    let info: NativePlayInfo;
    try {
      info = await this.call<NativePlayInfo>('info', '/v/api/v1/play/info',
        http.RequestMethod.POST, JSON.stringify(infoBody), '', 3, gen);
    } catch (e) {
      this.assertAlive(gen);
      if ((e as Error).message !== 'info: 服务状态 -6') { throw new Error((e as Error).message); }
      // Native range URLs identify a media file, while play/info takes an item.
      // The verified file-play API can negotiate that file without track GUIDs.
      const encodedRangeId = url.substring(index + marker.length).split('?')[0].split('#')[0].split('/')[0];
      let rangeId = '';
      try { rangeId = decodeURIComponent(encodedRangeId); } catch (decodeError) {}
      if (!/^[A-Za-z0-9_-]{16,128}$/.test(rangeId)) {
        throw new Error('飞牛媒体文件标识无效');
      }
      hilog.info(0x0001, 'NasFnos', 'native item not found; use verified media-file negotiation');
      return await this.resolveFile(rangeId, gen);
    }
    this.assertAlive(gen);
    const hasItem = info.item !== undefined && info.item !== null;
    const nativeItem = info.item;
    const hasGuid = nativeItem !== undefined && nativeItem !== null
      && typeof nativeItem.guid === 'string' && nativeItem.guid.trim().length > 0;
    let canonicalId = itemId;
    if (hasGuid && nativeItem !== undefined && nativeItem !== null && nativeItem.guid !== undefined) {
      canonicalId = nativeItem.guid;
    }
    hilog.info(0x0001, 'NasFnos', 'info shape item=%{public}s guid=%{public}s type=%{public}s canonicalChanged=%{public}s',
      hasItem ? 'Y' : 'N', hasGuid ? 'Y' : 'N', typeof info.type, canonicalId !== itemId ? 'Y' : 'N');
    const streamPath = '/v/api/v1/stream/list/' + encodeURIComponent(canonicalId) + '?before_play=1';
    let streams: NativeStreams | null = null;
    let lastFailure = '';
    // The current server accepted the query-hash signature. Keep its two known
    // alternatives bounded: one info read, three stream probes, one quality read.
    const styles: number[] = [1, 3, 2];
    for (let attempt = 0; attempt < styles.length; attempt++) {
      const style = styles[attempt];
      try {
        this.readAttempts++;
        streams = await this.call<NativeStreams>('streams', streamPath,
          http.RequestMethod.GET, '', 'before_play=1', style, gen);
        this.assertAlive(gen);
        this.authStyle = style;
        break;
      } catch (e) {
        this.assertAlive(gen);
        lastFailure = (e as Error).message;
      }
    }
    if (streams === null) {
      throw new Error('飞牛原生播放接口不可用，或当前登录令牌不兼容（' + lastFailure + '）');
    }
    const files = streams.files !== undefined ? streams.files : [];
    let file: NativeFile | null = streams.file_stream !== undefined ? streams.file_stream : null;
    if (files.length > 0) {
      file = files[0];
      for (let i = 0; i < files.length; i++) {
        const path = files[i].path !== undefined ? files[i].path as string : '';
        if (!/\d+-\d+-\S+/.test(path)) {
          file = files[i];
          break;
        }
      }
    }
    const videos = streams.video_streams !== undefined ? streams.video_streams : [];
    const audios = streams.audio_streams !== undefined ? streams.audio_streams : [];
    hilog.info(0x0001, 'NasFnos', 'streams files=%{public}d video=%{public}d audio=%{public}d',
      files.length, videos.length, audios.length);
    if (file === null || !file.guid || videos.length === 0 || !videos[0].guid || audios.length === 0) {
      throw new Error('飞牛原生接口未提供可用的音视频轨道');
    }
    let audio = audios[0];
    for (let i = 0; i < audios.length; i++) {
      if (audios[i].codec_name === 'aac') {
        audio = audios[i];
        break;
      }
    }
    if (!audio.guid) {
      throw new Error('飞牛原生接口未提供音频轨道标识');
    }
    const qualityBody: QualityBody = { media_guid: file.guid };
    let qualities: NativeQuality[] | null = null;
    if (this.readAttempts < 5) {
      const style = this.authStyle;
      try {
        this.readAttempts++;
        qualities = await this.call<NativeQuality[]>('quality', '/v/api/v1/play/quality',
          http.RequestMethod.POST, JSON.stringify(qualityBody), '', style, gen);
        this.assertAlive(gen);
        if (!Array.isArray(qualities) || qualities.length === 0) {
          throw new Error('quality 结构不兼容');
        }
        this.authStyle = style;
      } catch (e) {
        this.assertAlive(gen);
        qualities = null;
        lastFailure = (e as Error).message;
      }
    }
    if (qualities === null && streams.qualities !== undefined) {
      qualities = streams.qualities;
    }
    if (qualities === null || qualities.length === 0) {
      throw new Error('飞牛未提供播放画质（' + lastFailure + '）');
    }
    const quality = this.chooseQuality(qualities);
    if (quality === null) {
      throw new Error('飞牛未提供 1080p 以内的兼容播放画质');
    }
    const body: PlayBody = {
      media_guid: file.guid,
      video_guid: videos[0].guid,
      video_encoder: 'h264',
      resolution: quality.resolution,
      bitrate: quality.bitrate,
      startTimestamp: 0,
      audio_encoder: 'aac',
      audio_guid: audio.guid,
      subtitle_guid: '',
      channels: 2
    };
    hilog.info(0x0001, 'NasFnos', 'play profile resolution=%{public}s bitrate=%{public}d auth=%{public}d reads=%{public}d',
      quality.resolution, quality.bitrate, this.authStyle, this.readAttempts);
    const play = await this.call<NativePlay>('play', '/v/api/v1/play/play',
      http.RequestMethod.POST, JSON.stringify(body), '', this.authStyle, gen);
    this.assertAlive(gen);
    return this.finishPlay(play);
  }

  private async resolveFile(mediaId: string, gen: number): Promise<FnosPlaybackResult> {
    this.assertAlive(gen);
    this.authStyle = 3;
    const qualityBody: QualityBody = { media_guid: mediaId };
    this.readAttempts++;
    const qualities = await this.call<NativeQuality[]>('quality-file', '/v/api/v1/play/quality',
      http.RequestMethod.POST, JSON.stringify(qualityBody), '', this.authStyle, gen);
    this.assertAlive(gen);
    if (!Array.isArray(qualities) || qualities.length === 0) {
      throw new Error('飞牛媒体文件未提供兼容播放画质');
    }
    for (let i = 0; i < qualities.length; i++) {
      const q = qualities[i];
      hilog.info(0x0001, 'NasFnos', 'file quality index=%{public}d resolution=%{public}s bitrate=%{public}d progressive=%{public}s hls=%{public}s',
        i, q.resolution, q.bitrate, q.progressive === true ? 'Y' : 'N', q.is_m3u8 === true ? 'Y' : 'N');
    }
    const quality = this.chooseQuality(qualities);
    if (quality === null) { throw new Error('飞牛媒体文件未提供兼容播放画质'); }
    const body: FilePlayBody = {
      media_guid: mediaId, resolution: quality.resolution, bitrate: quality.bitrate,
      startTimestamp: 0, forced_sdr: 0, without_stream: false
    };
    hilog.info(0x0001, 'NasFnos', 'file profile qualities=%{public}d resolution=%{public}s bitrate=%{public}d requestedHls=%{public}s',
      qualities.length, quality.resolution, quality.bitrate, quality.is_m3u8 === true ? 'Y' : 'N');
    const play = await this.call<NativePlay>('play-file', '/v/api/v1/play/play',
      http.RequestMethod.POST, JSON.stringify(body), '', this.authStyle, gen);
    this.assertAlive(gen);
    return this.finishPlay(play);
  }

  private finishPlay(play: NativePlay): FnosPlaybackResult {
    if (play.play_link === undefined || play.play_link.length === 0) {
      throw new Error('飞牛未返回原生播放地址');
    }
    this.playLink = play.play_link;
    const result = new FnosPlaybackResult();
    result.url = this.playLink.startsWith('http://') || this.playLink.startsWith('https://')
      ? this.playLink : this.base + (this.playLink.startsWith('/') ? '' : '/') + this.playLink;
    result.isHls = play.is_m3u8 === true || this.playLink.split('?')[0].toLowerCase().endsWith('.m3u8');
    hilog.info(0x0001, 'NasFnos', 'native session ready hls=%{public}s', result.isHls ? 'Y' : 'N');
    return result;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.generation++;
    const requests = this.requests.slice();
    this.requests = [];
    for (let i = 0; i < requests.length; i++) {
      try { requests[i].destroy(); } catch (e) {}
    }
    const base = this.base;
    const token = this.token;
    const link = this.playLink;
    const style = this.authStyle;
    this.playLink = '';
    this.base = '';
    this.token = '';
    if (link.length > 0 && base.length > 0 && token.length > 0) {
      const body: QuitBody = {
        req: 'media.quit', reqid: 'nasplayer-' + Date.now().toString(), playLink: link
      };
      const request = http.createHttp();
      try {
        const raw = JSON.stringify(body);
        const signature = await this.signature('/v/api/v1/media/p', raw, '', style, token);
        const headers: Record<string, string> = {
          'Authorization': token, 'authx': signature, 'Content-Type': 'application/json'
        };
        if (style === 3) { headers['Cookie'] = 'mode=relay'; }
        await request.request(base + '/v/api/v1/media/p', {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: raw, usingCache: false, connectTimeout: 3000, readTimeout: 3000,
          expectDataType: http.HttpDataType.STRING, maxLimit: 65536
        });
        hilog.info(0x0001, 'NasFnos', 'native session quit');
      } catch (e) {
        hilog.warn(0x0001, 'NasFnos', 'native session quit unavailable');
      } finally {
        request.destroy();
      }
    }
  }

  private assertAlive(gen: number): void {
    if (this.closed || gen !== this.generation) {
      throw new Error('原生播放连接已取消');
    }
  }

  private chooseQuality(qualities: NativeQuality[]): NativeQuality | null {
    let chosen: NativeQuality | null = null;
    let chosenHeight = 0;
    for (let i = 0; i < qualities.length; i++) {
      const q = qualities[i];
      if (typeof q.resolution !== 'string' || typeof q.bitrate !== 'number'
        || q.bitrate <= 0 || q.bitrate > 12000000) { continue; }
      const text = q.resolution.toLowerCase();
      const height = text.indexOf('4k') >= 0 ? 2160 : parseInt(text, 10);
      if (isNaN(height) || height <= 0 || height > 1080) { continue; }
      // Prefer server-provided HLS, then the highest compatible resolution/rate.
      if (chosen === null || (q.is_m3u8 === true && chosen.is_m3u8 !== true)
        || ((q.is_m3u8 === true) === (chosen.is_m3u8 === true)
          && (height > chosenHeight || (height === chosenHeight && q.bitrate > chosen.bitrate)))) {
        chosen = q;
        chosenHeight = height;
      }
    }
    return chosen;
  }

  private async call<T>(stage: string, path: string, method: http.RequestMethod,
    body: string, query: string, style: number, gen: number): Promise<T> {
    this.assertAlive(gen);
    const base = this.base;
    const token = this.token;
    const sign = await this.signature(path.split('?')[0], body, query, style, token);
    this.assertAlive(gen);
    const request = http.createHttp();
    this.requests.push(request);
    try {
      const headers: Record<string, string> = {
        'Authorization': token, 'X-Emby-Token': token, 'authx': sign,
        'Accept': 'application/json', 'Content-Type': 'application/json'
      };
      if (style === 3) { headers['Cookie'] = 'mode=relay'; }
      const response = await request.request(base + path, {
        method: method,
        header: headers,
        extraData: method === http.RequestMethod.GET ? undefined : body,
        usingCache: false, connectTimeout: 8000, readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING, maxLimit: 2 * 1048576
      });
      this.assertAlive(gen);
      const status = response.responseCode as number;
      const raw = (response.result as string).trim();
      const json = raw.startsWith('{');
      if (status < 200 || status >= 300 || !json) {
        hilog.warn(0x0001, 'NasFnos', '%{public}s auth=%{public}d status=%{public}d json=%{public}s',
          stage, style, status, json ? 'Y' : 'N');
        throw new Error(stage + ': HTTP ' + status.toString() + (json ? '' : ' 非 JSON'));
      }
      const envelope = JSON.parse(raw) as NativeResponse<T>;
      const code = envelope.code !== undefined ? envelope.code : 0;
      const hasData = envelope.data !== undefined && envelope.data !== null;
      hilog.info(0x0001, 'NasFnos', '%{public}s auth=%{public}d status=%{public}d code=%{public}d data=%{public}s',
        stage, style, status, code, hasData ? 'Y' : 'N');
      if (code !== 0 || !hasData) {
        const detail = typeof envelope.msg === 'string' ? envelope.msg
          : (typeof envelope.message === 'string' ? envelope.message : '');
        const safeDetail = this.safeMessage(detail);
        hilog.warn(0x0001, 'NasFnos', '%{public}s rejected code=%{public}d reason=%{public}s',
          stage, code, safeDetail);
        throw new Error(stage + ': 服务状态 ' + code.toString());
      }
      return envelope.data as T;
    } catch (e) {
      this.assertAlive(gen);
      const err = e as BusinessError;
      if (err.code !== undefined) {
        hilog.warn(0x0001, 'NasFnos', '%{public}s network code=%{public}d', stage, err.code);
        throw new Error(stage + ': 网络状态 ' + err.code.toString());
      }
      // Only errors constructed above contain safe, useful protocol diagnostics.
      const message = (e as Error).message;
      if (message.startsWith(stage + ':')) { throw new Error(message); }
      throw new Error(stage + ': JSON 结构不兼容');
    } finally {
      const index = this.requests.indexOf(request);
      if (index >= 0) { this.requests.splice(index, 1); }
      try { request.destroy(); } catch (e) {}
    }
  }

  private safeMessage(value: string): string {
    return value
      .replace(/https?:\/\/[^\s"'<>]+/gi, '[url]')
      .replace(/\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/g, '[ip]')
      .replace(/(authorization|bearer|authx|token|password)\s*[:=]\s*[^\s,;}]+/gi, '$1=[redacted]')
      .replace(/[A-Za-z0-9_+\/=-]{24,}/g, '[redacted]')
      .replace(/[\r\n\t]/g, ' ')
      .substring(0, 160);
  }

  private async signature(path: string, body: string, query: string,
    style: number, token: string): Promise<string> {
    const nonce = Math.floor(100000 + Math.random() * 900000).toString();
    const timestamp = Date.now().toString();
    let input: string;
    if (style === 2) {
      input = nonce + timestamp + token;
    } else {
      const content = body.length > 0 ? body : (style === 3 ? '' : query);
      let decoded = content;
      if (style !== 3) {
        try { decoded = decodeURIComponent(content.replace(/%(?![0-9A-Fa-f]{2})/g, '%25')); } catch (e) {}
      }
      const contentHash = await this.md5(decoded);
      input = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh_' + path + '_' + nonce + '_'
        + timestamp + '_' + contentHash + '_16CCEB3D-AB42-077D-36A1-F355324E4237';
    }
    return 'nonce=' + nonce + '&timestamp=' + timestamp + '&sign=' + await this.md5(input);
  }

  private async md5(value: string): Promise<string> {
    // CryptoFramework update() can reject a zero-length DataBlob. This is the
    // standard MD5 of an empty body, required for native GET request signatures.
    if (value.length === 0) { return 'd41d8cd98f00b204e9800998ecf8427e'; }
    const digest = cryptoFramework.createMd('MD5');
    const bytes = new util.TextEncoder().encodeInto(value);
    await digest.update({ data: bytes });
    const result = await digest.digest();
    let hex = '';
    for (let i = 0; i < result.data.length; i++) {
      hex += result.data[i].toString(16).padStart(2, '0');
    }
    return hex;
  }
}
