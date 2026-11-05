import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ImageRequest } from '../common/ImageRequest';

/**
 * 网络图片加载器
 *
 * ★ 为什么需要它：
 *   飞牛影视的 /Items/{id}/Images/Primary 只认请求头里的 X-Emby-Token，
 *   把 token 放 URL 参数会返回 400。
 *   而 ArkUI 的 Image() 组件不能加请求头，
 *   所以只能用 http 自己下载字节流 → 解码成 PixelMap → 交给 Image()。
 */

/**
 * LRU 缓存 + 字节预算（方案 10.3）
 *
 * 预算按 PixelMap 实际字节数统计（width × height × 4，RGBA8888），
 * 而不是"张数"。同一台设备上 1080 宽的大图和 420 宽的缩略图差 6 倍，
 * 只按条数淘汰会让大图悄悄吃光内存。
 *
 *   soft 64 MiB：超过就主动淘汰最久未用的
 *   hard 96 MiB：超过就清到 soft 以下
 */
class ImageCache {
  private static keys: string[] = [];
  private static map: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private static bytes: Map<string, number> = new Map<string, number>();
  private static total: number = 0;

  /** 软上限：超过即开始淘汰 */
  private static readonly SOFT: number = 64 * 1024 * 1024;
  /** 硬上限：超过即清到软上限以下 */
  private static readonly HARD: number = 96 * 1024 * 1024;
  /** 条数兜底（极小图也避免无限增长） */
  private static readonly MAX_COUNT: number = 80;
  /** ★ R07：活跃引用计数（组件正在渲染这张图） */
  private static leases: Map<string, number> = new Map<string, number>();

  /** 组件开始使用某个 key */
  static acquire(k: string): void {
    const n = ImageCache.leases.get(k);
    ImageCache.leases.set(k, n === undefined ? 1 : n + 1);
  }

  /** 组件不再使用某个 key */
  static releaseKey(k: string): void {
    const n = ImageCache.leases.get(k);
    if (n === undefined) {
      return;
    }
    if (n <= 1) {
      ImageCache.leases.delete(k);
    } else {
      ImageCache.leases.set(k, n - 1);
    }
  }

  /** 估算 PixelMap 占用字节 */
  private static sizeOf(pm: image.PixelMap): number {
    try {
      const info = pm.getImageInfoSync();
      const w = info.size.width;
      const h = info.size.height;
      if (w > 0 && h > 0) {
        return w * h * 4;
      }
    } catch (e) {
      // 取不到就按中等图估算
    }
    return 1 * 1024 * 1024;
  }

  static get(k: string): image.PixelMap | undefined {
    const v = ImageCache.map.get(k);
    if (v !== undefined) {
      const i = ImageCache.keys.indexOf(k);
      if (i > 0) {
        ImageCache.keys.splice(i, 1);
        ImageCache.keys.unshift(k);
      }
    }
    return v;
  }

  /** 当前占用（字节），供调试/性能报告使用 */
  static used(): number {
    return ImageCache.total;
  }

  static put(k: string, v: image.PixelMap): void {
    if (ImageCache.map.has(k)) {
      return;
    }
    // 单张超过软上限一半的图不进缓存，避免一张图挤掉全部
    const sz = ImageCache.sizeOf(v);
    if (sz > ImageCache.SOFT / 2) {
      return;
    }
    ImageCache.map.set(k, v);
    ImageCache.bytes.set(k, sz);
    ImageCache.total += sz;
    ImageCache.keys.unshift(k);

    // 超软上限：按 LRU 淘汰到软上限以下
    if (ImageCache.total > ImageCache.SOFT) {
      ImageCache.evictTo(ImageCache.SOFT);
    }
    // 超硬上限：更激进
    if (ImageCache.total > ImageCache.HARD) {
      ImageCache.evictTo(ImageCache.SOFT / 2);
    }
    // 条数兜底
    while (ImageCache.keys.length > ImageCache.MAX_COUNT) {
      if (!ImageCache.evictTail()) { break; }
    }
  }

  /** Admission check, not a reservation: at most two decodes may already be in flight. */
  static prepareDecode(): boolean {
    if (ImageCache.total >= ImageCache.HARD) {
      ImageCache.evictTo(ImageCache.SOFT);
    }
    return ImageCache.total < ImageCache.HARD;
  }

  private static evictTo(target: number): void {
    while (ImageCache.total > target && ImageCache.keys.length > 0) {
      if (!ImageCache.evictTail()) { break; }
    }
  }

  private static evictTail(): boolean {
    // ★ R07：从尾部往前找一个「没有活跃引用」的条目。
    //   有 lease 的说明正被组件渲染，淘汰掉会立刻黑屏；
    //   没有 lease 的才是真正可以安全释放的。
    for (let i = ImageCache.keys.length - 1; i >= 0; i--) {
      const k = ImageCache.keys[i];
      const lease = ImageCache.leases.get(k);
      if (lease !== undefined && lease > 0) {
        continue;
      }
      ImageCache.keys.splice(i, 1);
      ImageCache.map.delete(k);
      const b = ImageCache.bytes.get(k);
      if (b !== undefined) {
        ImageCache.total -= b;
        if (ImageCache.total < 0) {
          ImageCache.total = 0;
        }
        ImageCache.bytes.delete(k);
      }
      // ★ 真机教训：这里**不能** pm.release()。
      //   PixelMap 交给 Image 组件后，组件可能仍在渲染它；
      //   即使 lease 记账为 0（例如某些组件直接走 NetImageLoader.load 拿图，
      //   没经过 NetImage 的 acquire），release 掉就会让渲染线程卡死 ——
      //   实测出现 THREAD_BLOCK_6S、卡在 CreatePixelMap、界面完全不渲染。
      //   所以这里只从缓存表里摘掉，native 内存交给 GC / 系统回收。
      //   真正的硬上限靠「不再新增解码」而不是「释放正在用的图」。
      return true;
    }
    // 全都有 lease：宁可暂时超预算，也不能让屏幕上的图被释放
    return false;
  }

  static clear(): void {
    ImageCache.map.clear();
    ImageCache.bytes.clear();
    ImageCache.keys = [];
    ImageCache.total = 0;
  }
}

export class NetImageLoader {
  /** Optional generic headers replace the deprecated Emby-only arguments, including an explicit empty map. */
  static effectiveHeaders(token: string, authHeader: string, supplied?: Record<string, string>): Record<string, string> {
    return ImageRequest.headers(token, authHeader, supplied);
  }

  private static canonicalHeaders(headers: Record<string, string>): Record<string, string> {
    return ImageRequest.validated('', '', headers);
  }

  static cacheKey(url: string, maxW: number, token: string = '', authHeader: string = '', supplied?: Record<string, string>): string {
    return ImageRequest.key(url, maxW, token, authHeader, supplied);
  }

  static headerKey(headers: Record<string, string>): string { return NetImageLoader.cacheKey('', 0, '', '', headers); }
  /**
   * 正在下载的 key -> Promise。
   * ★ 原来用 Set<string>，同 URL 的第二个请求直接拿到 undefined（被当成失败），
   *   多个组件请求同一张图时后来的那个会显示空白。改成共享 Promise 后，
   *   后来者 await 同一个结果。
   */
  private static inFlight: Map<string, Promise<image.PixelMap | undefined>> =
    new Map<string, Promise<image.PixelMap | undefined>>();
  /** 同时进行的下载+解码任务上限。真机上一次创建数百张 PixelMap 会打满主线程。 */
  private static readonly MAX_ACTIVE: number = 2;
  private static activeLoads: number = 0;
  private static waitQueue: Array<() => void> = [];

  private static startNext(): void {
    while (NetImageLoader.activeLoads < NetImageLoader.MAX_ACTIVE &&
      NetImageLoader.waitQueue.length > 0) {
      const next = NetImageLoader.waitQueue.shift();
      if (next !== undefined) {
        next();
      }
    }
  }

  private static runLimited(
    work: () => Promise<image.PixelMap | undefined>
  ): Promise<image.PixelMap | undefined> {
    return new Promise<image.PixelMap | undefined>((resolve) => {
      const run = (): void => {
        NetImageLoader.activeLoads++;
        work().then((pm: image.PixelMap | undefined) => {
          resolve(pm);
        }).catch(() => {
          resolve(undefined);
        }).finally(() => {
          NetImageLoader.activeLoads--;
          NetImageLoader.startNext();
        });
      };
      if (NetImageLoader.activeLoads < NetImageLoader.MAX_ACTIVE) {
        run();
      } else {
        NetImageLoader.waitQueue.push(run);
      }
    });
  }

  static cached(url: string): image.PixelMap | undefined {
    return ImageCache.get(url);
  }

  static isDownloading(url: string): boolean {
    return NetImageLoader.inFlight.has(url);
  }

  /** 下载并解码；带 emby 认证头
   *  ★ 必须限制解码尺寸，否则 1080p 原图解码成 PixelMap 每张 30MB+，几十张就 OOM
   */
  /**
   * 下载并解码。
   * @param cacheKey 请求身份键（URL + 解码尺寸 + 认证范围）；缓存与 inFlight 用它
   * @param url      真实请求地址
   * ★ 方案 R07：缓存/inFlight 的键不能只用 URL ——
   *   同一 URL 在不同解码尺寸/不同账号下需要区分，否则会串图或串权限。
   */
  static async load(_legacyKey: string, url: string, token: string, authHeader: string,
                   maxW: number, supplied?: Record<string, string>): Promise<image.PixelMap | undefined> {
    if (url.length === 0) {
      return undefined;
    }
    let headers: Record<string, string>;
    try { headers = NetImageLoader.canonicalHeaders(NetImageLoader.effectiveHeaders(token, authHeader, supplied)); }
    catch (e) { return undefined; }
    // Recompute from actual headers even for old callers that supplied a weak/custom key.
    const cacheKey = NetImageLoader.cacheKey(url, maxW, '', '', headers);
    const hit = ImageCache.get(cacheKey);
    if (hit !== undefined) {
      return hit;
    }
    // 已有同键请求在飞：直接等同一个 Promise，不再返回 undefined
    const pending = NetImageLoader.inFlight.get(cacheKey);
    if (pending !== undefined) {
      return pending;
    }
    const task = NetImageLoader.runLimited((): Promise<image.PixelMap | undefined> => {
      return NetImageLoader.doLoad(cacheKey, url, '', '', maxW, headers);
    });
    NetImageLoader.inFlight.set(cacheKey, task);
    try {
      return await task;
    } finally {
      NetImageLoader.inFlight.delete(cacheKey);
    }
  }

  /** 真正的下载+解码（只在 load() 内部调用一次） */
  private static async doLoad(cacheKey: string, url: string, token: string,
                             authHeader: string,
                             maxW: number, supplied?: Record<string, string>): Promise<image.PixelMap | undefined> {
    const req = http.createHttp();
    let src: image.ImageSource | undefined = undefined;
    try {
      const headers = NetImageLoader.canonicalHeaders(NetImageLoader.effectiveHeaders(token, authHeader, supplied));

      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        usingCache: false,
        maxRedirects: ImageRequest.redirectLimit(headers),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 12000,
        readTimeout: 25000
      });

      const code = resp.responseCode as number;
      if (code < 200 || code >= 300) {
        return undefined;
      }
      const buf = resp.result as ArrayBuffer;
      if (buf === undefined || buf.byteLength < 100) {
        return undefined;
      }

      src = image.createImageSource(buf);
      // 按目标宽度等比缩放解码；大图失败自动降级重试
      const info = await src.getImageInfo();
      const iw = info.size.width > 0 ? info.size.width : maxW;
      const ih = info.size.height > 0 ? info.size.height : maxW;
      const ratio = ih / iw;

      // ★ 多级回退：有些海报是「渐进式 JPEG」，硬件解码器直接拒绝
      //   （日志: JPEGDEC unsupported progressiveMode, error -2）
      //   所以 desiredSize 失败后换 sampleSize，再失败就无参数交给软解
      let pm: image.PixelMap | undefined = undefined;

      const dw0 = Math.min(maxW, iw);
      const dh0 = Math.max(1, Math.round(dw0 * ratio));
      const attempts: image.DecodingOptions[] = [
        { desiredSize: { width: dw0, height: dh0 } },
        { desiredSize: { width: dw0, height: dh0 }, editable: false },
        { sampleSize: 2 },
        { sampleSize: 4 },
        {}
      ];

      for (let a = 0; a < attempts.length; a++) {
        // No waiting/spin and no release of visible PixelMaps under memory pressure.
        // This uses current cache bytes, not a strict reservation for concurrent/native allocations.
        if (!ImageCache.prepareDecode()) { return undefined; }
        try {
          pm = await src.createPixelMap(attempts[a]);
          if (pm !== undefined) {
            break;
          }
        } catch (e2) {
          pm = undefined;
        }
      }
      if (pm === undefined) {
        return undefined;
      }
      ImageCache.put(cacheKey, pm);
      return pm;
    } catch (e) {
      return undefined;
    } finally {
      // ★ R07：ImageSource 必须在 finally 释放，异常路径以前会漏
      if (src !== undefined) {
        try {
          src.release();
        } catch (e3) {
        }
      }
      req.destroy();
    }
  }
}

/**
 * 网络图片组件 —— 替代 Image('http://...')
 *
 * 用法：
 *   NetImage({ url: xxx, token: this.token, authHeader: this.auth })
 */
@Component
export struct NetImage {
  /**
   * ★ 加 @Watch（方案 R07）：
   *   旧实现 @Prop 上没有 @Watch，只有 aboutToAppear 和 aboutToReuse 会发起加载。
   *   @Prop 值变化（换对象、切服务器、变尺寸）时不会重新请求，
   *   列表复用/局部刷新场景会一直显示上一张图。
   */
  @Prop @Watch('onRequestKeyChange') url: string = '';
  @Prop @Watch('onRequestKeyChange') token: string = '';
  @Prop @Watch('onRequestKeyChange') authHeader: string = '';
  @Prop @Watch('onRequestKeyChange') headers: Record<string, string> = {};
  @Prop darkMode: boolean = true;
  @Prop corner: number = 0;
  @Prop fit: ImageFit = ImageFit.Cover;
  /** 解码目标宽度（大图用 1440，缩略图 420）*/
  @Prop @Watch('onRequestKeyChange') targetWidth: number = 420;
  /** 占位色：图片未加载/失败时铺这个色，避免出现纯黑块 */
  @Prop placeholderColor: string = '';
  /** 加载失败回调（用于把坏图条目从 Hero 候选里剔除） */
  onFail: (url: string) => void = () => {};
  /** Only a valid decoded PixelMap/cache hit is ready; placeholders and stale requests never notify. */
  onImageReady: (url: string) => void = () => {};
  onImageSize: (width: number, height: number) => void = () => {};

  @State private pix: image.PixelMap | undefined = undefined;
  @State private failed: boolean = false;

  /**
   * 请求身份键（方案 R07）：URL + 解码尺寸 + 认证范围。
   * ★ 旧实现只用 URL 当缓存/inFlight 的键 ——
   *   换了服务器、换了账号、或同一 URL 要不同尺寸时会串图/串权限。
   *   完整 URL、尺寸和所有头经过 SHA256，缓存键不包含明文凭据或短 token 前缀。
   */
  private requestKey(): string {
    return NetImageLoader.cacheKey(this.url, this.targetWidth, '', '', this.requestHeaders());
  }

  private requestHeaders(): Record<string, string> {
    // Legacy components still pass token/authHeader. New provider calls pass headers only.
    const generic = Object.keys(this.headers).length > 0 || (this.token.length === 0 && this.authHeader.length === 0);
    return NetImageLoader.effectiveHeaders(this.token, this.authHeader, generic ? this.headers : undefined);
  }

  /** 当前已成功加载的键（用于判断「换对象」） */
  private loadedKey: string = '';
  /** generation 守卫：每次发起请求递增 */
  private generation: number = 0;
  /** 只有进入视口才请求，避免 Grid 一次创建大量离屏 PosterCard 时并发解码。 */
  private visibleInViewport: boolean = false;
  private loadScheduled: boolean = false;

  aboutToAppear(): void {
    this.loadScheduled = false;
  }

  aboutToDisappear(): void {
    this.generation++;
    this.visibleInViewport = false;
    // ★ R07：组件销毁要放掉租约，否则这张图永远不会被淘汰
    if (this.loadedKey.length > 0) {
      ImageCache.releaseKey(this.loadedKey);
      this.loadedKey = '';
    }
    this.loadScheduled = false;
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.loadScheduled = false;
    if (this.visibleInViewport) {
      this.startLoad();
    }
  }

  /** @Watch 回调：url / token / authHeader / targetWidth 任一变化都重新请求 */
  onRequestKeyChange(): void {
    if (this.visibleInViewport) {
      this.startLoad();
    }
  }

  private startLoad(): void {
    this.loadScheduled = true;
    this.generation++;
    const key: string = this.requestKey();
    if (key === this.loadedKey && this.pix !== undefined) { return; }
    // ① 换对象了：先清掉旧图，避免新图失败时旧图还在冒充成功
    if (key !== this.loadedKey) {
      // ★ R07：换 key 时先放掉旧 key 的租约，否则旧图永远不可淘汰
      if (this.loadedKey.length > 0) {
        ImageCache.releaseKey(this.loadedKey);
        this.loadedKey = '';
      }
      this.pix = undefined;
      this.failed = false;
    }
    // ② 先看缓存（同步，避免闪烁）
    const hit = NetImageLoader.cached(key);
    if (hit !== undefined) {
      ImageCache.acquire(key);
      this.pix = hit;
      this.failed = false;
      this.loadedKey = key;
      this.notifyImageReady(this.url);
      return;
    }
    this.doLoad(key);
  }

  private async doLoad(key: string): Promise<void> {
    this.generation++;
    const gen: number = this.generation;
    if (this.url.length === 0) {
      this.pix = undefined;
      this.failed = true;
      this.loadedKey = '';
      return;
    }
    const wantUrl: string = this.url;
    const pm = await NetImageLoader.load(key, wantUrl, '', '', this.targetWidth, this.requestHeaders());
    // ★ 双重校验：既要是最新一代，也要仍指向同一个键
    //   （旧实现只比 generation，不核对 key —— 快速切服务器时仍可能串图）
    if (gen !== this.generation || key !== this.requestKey()) {
      // 过期结果：如果它自带独占资源，由 loader 的 LRU 接走，这里不提交到 UI
      return;
    }
    if (pm !== undefined) {
      ImageCache.acquire(key);
      this.pix = pm;
      this.failed = false;
      this.loadedKey = key;
      this.notifyImageReady(wantUrl);
    } else {
      // 失败不得冒充旧图：明确清空并暴露失败态
      this.pix = undefined;
      this.failed = true;
      this.loadedKey = '';
      try {
        this.onFail(wantUrl);
      } catch (e) {
      }
    }
  }

  private notifyImageReady(url: string): void {
    try {
      if (this.pix !== undefined) {
        const size = this.pix.getImageInfoSync().size;
        this.onImageSize(size.width, size.height);
      }
    } catch (e) {
      // Optional size observers must not prevent the ready notification.
    }
    try {
      this.onImageReady(url);
    } catch (e) {
      // Consumer animation/teardown must not turn a decoded image into a load error.
    }
  }

  build() {
    Stack() {
      if (this.pix !== undefined) {
        Image(this.pix)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .interpolation(ImageInterpolation.Medium)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.placeholderColor.length > 0
            ? this.placeholderColor
            : (this.darkMode ? '#1A1A1E' : '#E8E8ED'))
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(this.corner)
    .clip(true)
    .onVisibleAreaChange([0.0, 0.01], (isVisible: boolean, ratio: number) => {
      this.visibleInViewport = isVisible;
      if (isVisible && !this.loadScheduled) {
        this.startLoad();
      }
    })
  }
}
