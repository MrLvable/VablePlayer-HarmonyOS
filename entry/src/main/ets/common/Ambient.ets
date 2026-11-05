import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { mix, withAlpha } from './Theme';
import { DominantColor } from './DominantColor';
import { ImageRequest } from './ImageRequest';
import { SourceIdentity } from './services/SourceIdentity';
import { PaletteMath } from './PaletteMath';

/**
 * Ambient —— 首页「连续空间氛围」取色（方案 R10 / §5.2 §5.3）
 *
 * ★ 为什么要新写一个模块，而不是继续用 DominantColor：
 *   DominantColor 只给「一个主色」，整页染一层纯色 —— 参考录屏里
 *   紫灰 / 棕灰 / 青绿是**同屏不同位置**的差别，单一颜色场做不到。
 *   而且旧实现用 surfaceColor() 当 Hero 底部渐隐的 RGB，
 *   等于把海报下半部「涂成一块底色」，不是真正的 alpha 渐隐。
 *
 * ★ 本模块做什么：
 *   1. 只下载一次图片字节（不要 NetImage 下完再单下一个）
 *   2. 同一份 ImageSource 上按 上/中/下 三条带各解码一个 24px 小图
 *   3. 每条带以真实 RGBA 面积选色，官方 ColorPicker 仅在像素读取不可用时兜底
 *   4. 给出 4 个可以分别使用的颜色场：base / top / mid / bottom
 *   5. 保留源图色相与相对明度；文字对比由页面局部遮罩承担
 *
 * ★ 缓存按 server + item + tag + 算法版本分键（方案 5.3 第 3 条），
 *   切服务器后旧结果不会染到新页面；同时做 in-flight 合并，
 *   同一张图不会因为拖动/重绘被重复下载。
 */
export class AmbientPalette {
  /** 上部代表色 0xRRGGBB，-1 表示没取到 */
  topRgb: number = -1;
  midRgb: number = -1;
  botRgb: number = -1;
  /** 是否取到了真实颜色（false = 中性占位） */
  has: boolean = false;

  constructor(top: number, mid: number, bot: number, has: boolean) {
    this.topRgb = top;
    this.midRgb = mid;
    this.botRgb = bot;
    this.has = has;
  }

  static empty(): AmbientPalette {
    return new AmbientPalette(-1, -1, -1, false);
  }

  static fromRgb(top: number, mid: number, bot: number): AmbientPalette {
    return new AmbientPalette(top, mid, bot, top >= 0 || mid >= 0 || bot >= 0);
  }

  /** 权重混合两套取色（连续拖动时用，权重和归一到 1） */
  static blendOf(a: AmbientPalette, b: AmbientPalette, t: number): AmbientPalette {
    const k = Math.max(0, Math.min(1, t));
    if (k <= 0.001) {
      return a;
    }
    if (k >= 0.999) {
      return b;
    }
    // 缺色的通道用另一侧顶替，避免混出偏黑的脏色
    const at = a.topRgb >= 0 ? a.topRgb : b.topRgb;
    const bt = b.topRgb >= 0 ? b.topRgb : a.topRgb;
    const am = a.midRgb >= 0 ? a.midRgb : b.midRgb;
    const bm = b.midRgb >= 0 ? b.midRgb : a.midRgb;
    const ab = a.botRgb >= 0 ? a.botRgb : b.botRgb;
    const bb = b.botRgb >= 0 ? b.botRgb : a.botRgb;
    return AmbientPalette.fromRgb(
      mixRgb(at, bt, k), mixRgb(am, bm, k), mixRgb(ab, bb, k));
  }

  /** Preserve each sampled band's hue and relative brightness; text uses local contrast masks. */
  static field(rgb: number, dark: boolean, band: number): string {
    if (rgb < 0) {
      return dark ? AmbientPalette.NEUTRAL_DARK_FIELD[band]
        : AmbientPalette.NEUTRAL_LIGHT_FIELD[band];
    }
    return PaletteMath.field(rgb, dark, band);
  }

  /** Image-derived base retains pastel brightness instead of imposing a nearly black floor. */
  static baseOf(rgb: number, dark: boolean): string {
    if (rgb < 0) {
      return dark ? '#0B0C0E' : '#F6F7F9';
    }
    return PaletteMath.base(rgb, dark);
  }

  static readonly NEUTRAL_DARK_FIELD: string[] = ['#16181D', '#121419', '#0F1115'];
  static readonly NEUTRAL_LIGHT_FIELD: string[] = ['#EDEFF3', '#F0F2F6', '#F4F5F8'];
}

/** 缓存条目上限：Hero 最多 6 条，跨 Tab/切服再留一些余量 */
const CACHE_MAX: number = 48;
/** 取色算法版本：改了取色逻辑必须 +1，否则旧缓存会一直生效 */
const ALGO_VERSION: number = 5;

export class Ambient {
  private static cache: Map<string, AmbientPalette> = new Map<string, AmbientPalette>();
  private static inFlight: Map<string, Promise<AmbientPalette>> = new Map<string, Promise<AmbientPalette>>();
  private static aliases: Map<string, string> = new Map();
  private static generation: number = 0;

  /** 缓存键：server + item + tag + 算法版本 */
  static key(serverId: string, itemId: string, tag: string, headers?: Record<string, string>): string {
    return ImageRequest.key(JSON.stringify([serverId, itemId, tag, ALGO_VERSION]), 24, '', '', headers !== undefined ? headers : {});
  }

  /** 同步拿缓存（拖动中只允许用缓存，禁止每帧发请求） */
  static cached(key: string): AmbientPalette {
    const alias = Ambient.aliases.get(key); const p = Ambient.cache.get(alias !== undefined ? alias : key);
    return p !== undefined ? p : AmbientPalette.empty();
  }

  static has(key: string): boolean {
    const alias = Ambient.aliases.get(key); return Ambient.cache.has(alias !== undefined ? alias : key);
  }

  /** 异步取色；同一 key 并发调用只会有一次真实下载 */
  static async forUrl(key: string, url: string, token: string, authHeader: string, supplied?: Record<string, string>): Promise<AmbientPalette> {
    if (url.length === 0) {
      return AmbientPalette.empty();
    }
    const headers = ImageRequest.headers(token, authHeader, supplied);
    const identity = SourceIdentity.key(JSON.stringify([key, ImageRequest.key(url, 24, '', '', headers)]));
    Ambient.aliases.delete(key); Ambient.aliases.set(key, identity);
    if (Ambient.aliases.size > CACHE_MAX * 2) { let first = ''; Ambient.aliases.forEach((_identity: string, id: string) => { if (first.length === 0) { first = id; } }); Ambient.aliases.delete(first); }
    const hit = Ambient.cache.get(identity);
    if (hit !== undefined) {
      return hit;
    }
    const busy = Ambient.inFlight.get(identity);
    if (busy !== undefined) {
      return await busy;
    }
    const generation = Ambient.generation;
    const task = Ambient.fetchAndPick(url, '', '', headers);
    Ambient.inFlight.set(identity, task);
    try {
      const p = await task;
      if (generation === Ambient.generation) { Ambient.put(identity, p); }
      return p;
    } finally {
      if (Ambient.inFlight.get(identity) === task) { Ambient.inFlight.delete(identity); }
    }
  }

  private static put(key: string, p: AmbientPalette): void {
    if (!p.has) {
      // 失败结果也缓存，避免反复重试打满网络；但用短命的中性占位表示
      // （切服务器/重进首页会按新 key 重新取）
      if (Ambient.cache.size >= CACHE_MAX) {
        Ambient.cache.clear();
      }
      Ambient.cache.set(key, p);
      return;
    }
    if (Ambient.cache.size >= CACHE_MAX) {
      Ambient.cache.clear();
    }
    Ambient.cache.set(key, p);
  }

  /** 清空（切服务器 / 重试时调用） */
  static reset(): void {
    Ambient.cache.clear();
    Ambient.inFlight.clear();
    Ambient.aliases.clear();
    Ambient.generation++;
  }

  private static async fetchAndPick(url: string, token: string,
                                    authHeader: string, supplied?: Record<string, string>): Promise<AmbientPalette> {
    const req = http.createHttp();
    let src: image.ImageSource | undefined = undefined;
    try {
      const headers = ImageRequest.validated(token, authHeader, supplied);
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        usingCache: false,
        maxRedirects: ImageRequest.redirectLimit(headers),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 12000,
        readTimeout: 25000
      });
      if ((resp.responseCode as number) >= 300) {
        return AmbientPalette.empty();
      }
      const buf = resp.result as ArrayBuffer;
      // Small solid/pastel PNGs are valid images too. The decoder validates the
      // content; a byte-count heuristic must not discard a real light poster.
      if (buf === undefined || buf.byteLength < 16) {
        return AmbientPalette.empty();
      }
      src = image.createImageSource(buf);
      if (src === undefined) {
        return AmbientPalette.empty();
      }
      const info = src.getImageInfoSync();
      const iw = info.size.width;
      const ih = info.size.height;
      if (iw <= 0 || ih <= 0) {
        return AmbientPalette.empty();
      }
      const bandH = Math.max(1, Math.floor(ih / 3));
      const top = await Ambient.pickBand(src, 0, bandH, iw);
      const mid = await Ambient.pickBand(src, bandH, bandH, iw);
      const bot = await Ambient.pickBand(src, bandH * 2, ih - bandH * 2, iw);

      if (top < 0 && mid < 0 && bot < 0) {
        // 分区解码不可用时的兜底：整图一个小色
        const whole = await Ambient.pickBand(src, 0, ih, iw);
        if (whole < 0) {
          return AmbientPalette.empty();
        }
        return AmbientPalette.fromRgb(whole, whole, whole);
      }
      // 某条带没取到就借用相邻条带，保证三个色场都有值、不会突然变黑
      const ft = top >= 0 ? top : (mid >= 0 ? mid : bot);
      const fb = bot >= 0 ? bot : (mid >= 0 ? mid : top);
      const fm = mid >= 0 ? mid : ft;
      return AmbientPalette.fromRgb(ft, fm, fb);
    } catch (e) {
      return AmbientPalette.empty();
    } finally {
      if (src !== undefined) {
        try {
          src.release();
        } catch (e2) {
        }
      }
      req.destroy();
    }
  }

  /**
   * 解码一条带并取「有彩色」。
   * ★ desiredRegion 是源图裁剪，desiredSize 是输出尺寸 ——
   *   24×24 足够表达一块大范围低频颜色，解码成本可忽略。
   */
  private static async pickBand(src: image.ImageSource, y: number, h: number,
                               iw: number): Promise<number> {
    let pm: image.PixelMap | undefined = undefined;
    try {
      const opt: image.DecodingOptions = {
        desiredSize: { width: 24, height: 24 },
        desiredRegion: { x: 0, y: y, size: { width: iw, height: h } },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pm = await src.createPixelMap(opt);
      if (pm === undefined) {
        return -1;
      }
      return await DominantColor.fromPixelMap(pm, true);
    } catch (e) {
      return -1;
    } finally {
      if (pm !== undefined) {
        try {
          pm.release();
        } catch (e2) {
        }
      }
    }
  }
}

/* ───────── 颜色小工具 ───────── */

function toHex(rgb: number): string {
  let h = (rgb & 0xFFFFFF).toString(16);
  while (h.length < 6) {
    h = '0' + h;
  }
  return '#' + h;
}

function mixRgb(a: number, b: number, t: number): number {
  if (a < 0) {
    return b;
  }
  if (b < 0) {
    return a;
  }
  const ar = (a >> 16) & 0xFF;
  const ag = (a >> 8) & 0xFF;
  const ab = a & 0xFF;
  const br = (b >> 16) & 0xFF;
  const bg = (b >> 8) & 0xFF;
  const bb = b & 0xFF;
  const r = Math.round(ar + (br - ar) * t);
  const g = Math.round(ag + (bg - ag) * t);
  const bl = Math.round(ab + (bb - ab) * t);
  return (r << 16) | (g << 8) | bl;
}

function luma(hex: string): number {
  const h = hex.replace('#', '');
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
}

/** 深色主题：亮度超过上限就按比例压到上限（保持色相） */
function clampLuma(hex: string, maxLuma: number): string {
  const y = luma(hex);
  if (y <= maxLuma || y <= 0.0001) {
    return hex;
  }
  return mix(hex, '#000000', 1 - maxLuma / y);
}

/**
 * 按目标亮度整体缩放 RGB（不混白/混黑）。
 * ★ 这是「取海报主色」的关键：混色会掉饱和度，缩放只改明暗，
 *   色相与饱和度原样保留 —— 红色海报才会得到红色背景。
 */
function scaleToLuma(hex: string, target: number): string {
  const h = hex.replace('#', '');
  let r = parseInt(h.substring(0, 2), 16);
  let g = parseInt(h.substring(2, 4), 16);
  let b = parseInt(h.substring(4, 6), 16);
  const y = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  if (y <= 0.002) {
    // 近乎纯黑的主色：给一点可见的底，避免整片死黑
    return toHex((Math.round(255 * target * 0.55) << 16)
      | (Math.round(255 * target * 0.42) << 8)
      | Math.round(255 * target * 0.38));
  }
  const factor = target / y;
  r = r * factor;
  g = g * factor;
  b = b * factor;
  // 溢出时整体等比压回 255，保持比例（否则会偏色）
  const maxC = Math.max(r, g, b);
  if (maxC > 255) {
    const k = 255 / maxC;
    r *= k;
    g *= k;
    b *= k;
  }
  const cl = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));
  return toHex((cl(r) << 16) | (cl(g) << 8) | cl(b));
}

/** 向自身灰度混合降低饱和度（k=1 变纯灰），亮度基本不变 */
function desaturate(hex: string, k: number): string {
  const h = hex.replace('#', '');
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  const y = 0.299 * r + 0.587 * g + 0.114 * b;
  const cl = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));
  return toHex((cl(r + (y - r) * k) << 16) | (cl(g + (y - g) * k) << 8) | cl(b + (y - b) * k));
}

/** 把颜色亮度规范化到目标值（保持色相/低饱和），过暗往白提、过亮往黑压 */
function setLuma(hex: string, target: number): string {
  const y = luma(hex);
  if (y <= 0.0001) {
    return hex;
  }
  if (y < target) {
    const k = 1 - y / target;
    // 往白里混会同时降低饱和度，这正是「低饱和颜色场」想要的
    return mix(hex, '#FFFFFF', k * 0.72);
  }
  return mix(hex, '#000000', 1 - target / y);
}

/**
 * 以亮度为中心放大色度（BT.601 线性组合 ⇒ 亮度不变）。
 * 用来把「提亮时被洗成灰」的颜色找回原来的色相。
 */
function chroma(hex: string, k: number): string {
  const h = hex.replace('#', '');
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  const y = 0.299 * r + 0.587 * g + 0.114 * b;
  const cl = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));
  return toHex((cl(y + (r - y) * k) << 16) | (cl(y + (g - y) * k) << 8) | cl(y + (b - y) * k));
}

/** 浅色主题：亮度低于下限就按比例抬到下限 */
function liftLuma(hex: string, minLuma: number): string {
  const y = luma(hex);
  if (y >= minLuma || y >= 0.9999) {
    return hex;
  }
  return mix(hex, '#FFFFFF', 1 - (1 - minLuma) / (1 - y));
}

/**
 * Hero 底部 alpha 渐隐的色标（方案 §5.2 建议起点）。
 * ★ 这里只有 alpha 有意义：节点用 BlendMode.DST_IN 参与合成，
 *   RGB 不会把海报染白/染黑，所以不需要传任何页面底色。
 */
export class HeroMask {
  /** CSS 式 [alpha, stop] 渐隐：1@0% → 1@55% → .85@68% → .40@84% → 0@100% */
  static readonly KEYS: number[] = [0, 0.26, 0.46, 0.64, 0.80, 0.92, 1.0];
  static readonly ALPHAS: number[] = [1.0, 0.95, 0.84, 0.60, 0.30, 0.08, 0.0];

  /** 生成 DST_IN 蒙版用的线性渐变色标（RGB 固定黑，只有 alpha 起作用） */
  static stops(): Array<[string, number]> {
    const out: Array<[string, number]> = [];
    for (let i = 0; i < HeroMask.KEYS.length; i++) {
      out.push([withAlpha('#000000', HeroMask.ALPHAS[i]), HeroMask.KEYS[i]]);
    }
    return out;
  }
}
