import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { ImageRequest } from './ImageRequest';
import { PaletteMath } from './PaletteMath';

/**
 * 主色提取 —— 有界 RGBA 面积采样，官方 effectKit.ColorPicker 兜底
 *
 * ★★ 为什么不再自己算平均色：
 *   原实现把 16×16 的所有像素做简单平均。海报只要有大片黑底/白边，
 *   平均值就是一团浑浊的灰 —— 那不是「主色」，是「平均色」。
 *   这正是背景取不到 Hero 主色的根因。
 *
 * ★★ 官方方案（@ohos.effectKit，@since 9，syscap Multimedia.Image.Core）：
 *   effectKit.createColorPicker(pixelMap) 给出 ColorPicker，可直接取
 *     · getMainColorSync()            —— 智能主色
 *     · getLargestProportionColor()   —— 占比最大的颜色
 *     · getTopProportionColors(n)     —— Top N 候选
 *     · getHighestSaturationColor()   —— 饱和度最高
 *     · getAverageColor()             —— 平均色（就是旧实现自己算的那个）
 *     · isBlackOrWhiteOrGrayColor(c)  —— 判断某个颜色是否黑白灰
 *
 *   先在24px图上按面积聚合同色相候选，保留浅彩色的真实明度。
 *   无法读取RGBA时使用官方Top N候选，但不把浅粉/淡紫误滤成灰，
 *   也不使用没有面积依据的最高饱和度小色块替代整张海报。
 */
export class DominantColor {
  /** 从网络图提取主色，返回 0xRRGGBB；失败返回 -1 */
  static async fromUrl(url: string, token: string, authHeader: string, supplied?: Record<string, string>): Promise<number> {
    const rgb = await DominantColor.pickFromUrl(url, token, authHeader, false, supplied);
    return rgb;
  }

  /**
   * 从网络图提取「有彩色」的主色（跳过黑白灰）。
   * 这是背景染色想要的颜色。
   */
  static async vibrantFromUrl(url: string, token: string, authHeader: string, supplied?: Record<string, string>): Promise<number> {
    return await DominantColor.pickFromUrl(url, token, authHeader, true, supplied);
  }

  private static async pickFromUrl(url: string, token: string, authHeader: string,
                                   skipGray: boolean, supplied?: Record<string, string>): Promise<number> {
    if (url.length === 0) {
      return -1;
    }
    const req = http.createHttp();
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
        return -1;
      }
      const buf = resp.result as ArrayBuffer;
      if (buf === undefined || buf.byteLength < 16) {
        return -1;
      }
      return await DominantColor.fromBuffer(buf, skipGray);
    } catch (e) {
      return -1;
    } finally {
      req.destroy();
    }
  }

  /** 从字节流提取主色 */
  static async fromBuffer(buf: ArrayBuffer, skipGray: boolean = true): Promise<number> {
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    try {
      src = image.createImageSource(buf);
      // 24×24 足够取色，解码成本极低
      pm = await src.createPixelMap({ desiredSize: { width: 24, height: 24 }, desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      return await DominantColor.fromPixelMap(pm, skipGray);
    } catch (e) {
      return -1;
    } finally {
      if (pm !== undefined) {
        pm.release();
      }
      if (src !== undefined) {
        src.release();
      }
    }
  }

  /**
   * 从 PixelMap 提取主色（官方 ColorPicker）。
   * @param skipGray true 时优先返回有彩色，黑白灰只作兜底
   */
  static async fromPixelMap(pm: image.PixelMap, skipGray: boolean = true): Promise<number> {
    // Area and pastel brightness matter more than maximum saturation. Reading
    // the bounded thumbnail also avoids platform gray heuristics dropping pink.
    try {
      const info = pm.getImageInfoSync(), count = pm.getPixelBytesNumber(), stride = pm.getBytesNumberPerRow();
      if (info.pixelFormat === image.PixelMapFormat.RGBA_8888 && info.size.width <= 256 && info.size.height <= 256
        && count > 0 && count <= 1048576) {
        const buffer = new ArrayBuffer(count);
        await pm.readPixelsToBuffer(buffer);
        const picked = PaletteMath.fromRgba(new Uint8Array(buffer), info.size.width, info.size.height, stride,
          skipGray, info.alphaType === image.AlphaType.PREMUL);
        if (picked >= 0) { return picked; }
      }
    } catch (e) {
      // Older/unsupported pixel formats still use the platform picker below.
    }
    let picker: effectKit.ColorPicker | undefined = undefined;
    try {
      picker = await effectKit.createColorPicker(pm);
      if (picker === undefined) {
        return -1;
      }

      if (skipGray) {
        // 1) 先看 Top 候选里有没有「有色」的
        const tops: Array<effectKit.Color | null> = picker.getTopProportionColors(6);
        if (tops !== undefined && tops.length > 0) {
          for (let i = 0; i < tops.length; i++) {
            const c = tops[i];
            if (c === null) {
              continue;
            }
            const packed: number = DominantColor.pack(c);
            if (PaletteMath.chromatic(packed)) {
              return packed;
            }
          }
        }
        // Do not let a tiny saturated logo replace the actual large neutral area.
        // 2) 都不行就退回占比最大的（可能确实是黑白灰海报）
        const largest = picker.getLargestProportionColor();
        if (largest !== undefined) {
          return DominantColor.pack(largest);
        }
      }

      // 4) 兜底：智能主色
      const main = picker.getMainColorSync();
      if (main !== undefined) {
        return DominantColor.pack(main);
      }
      return -1;
    } catch (e) {
      return -1;
    }
  }

  /** effectKit.Color → 0xRRGGBB */
  private static pack(c: effectKit.Color): number {
    const r = Math.max(0, Math.min(255, Math.round(c.red)));
    const g = Math.max(0, Math.min(255, Math.round(c.green)));
    const b = Math.max(0, Math.min(255, Math.round(c.blue)));
    return (r << 16) | (g << 8) | b;
  }

  /** 把颜色调暗（用于深色主题背景） */
  static darken(rgb: number, k: number): string {
    const r = Math.round(((rgb >> 16) & 0xFF) * k);
    const g = Math.round(((rgb >> 8) & 0xFF) * k);
    const b = Math.round((rgb & 0xFF) * k);
    return '#' + DominantColor.h2(r) + DominantColor.h2(g) + DominantColor.h2(b);
  }

  /** 把颜色提亮（用于浅色主题背景） */
  static lighten(rgb: number, k: number): string {
    const r = Math.round(((rgb >> 16) & 0xFF) + (255 - ((rgb >> 16) & 0xFF)) * k);
    const g = Math.round(((rgb >> 8) & 0xFF) + (255 - ((rgb >> 8) & 0xFF)) * k);
    const b = Math.round((rgb & 0xFF) + (255 - (rgb & 0xFF)) * k);
    return '#' + DominantColor.h2(r) + DominantColor.h2(g) + DominantColor.h2(b);
  }

  private static h2(v: number): string {
    const s = Math.max(0, Math.min(255, v)).toString(16);
    return s.length === 1 ? '0' + s : s;
  }
}
