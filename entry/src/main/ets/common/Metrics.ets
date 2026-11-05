import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 屏幕适配 —— 手机 / 平板 / 电视
 *
 * ★★ 方案 R08 的核心修正：
 *   旧实现把「设备类型」和「视口尺寸」混成一个 ScreenKind，且只看视口宽度。
 *   后果：手机横屏后宽度约 995 vp（>=900），被判定为电视 ——
 *        于是字号 ×1.75、海报 7 列、Hero 560vp，横屏或分屏直接错乱。
 *
 *   现在拆成两个互相独立的概念：
 *     · deviceType  设备本身是什么   ← 来自官方 deviceInfo.deviceType
 *     · sizeClass   当前视口多大      ← 来自视口宽度，随旋转/分屏变化
 *
 *   缩放、列数这类「给多大的屏用多大尺寸」看 sizeClass；
 *   「要不要启用电视遥控器焦点/安全边距」看 deviceType。
 */

/** 设备类型（不会因为旋转而变） */
export enum DeviceType {
  PHONE = 'phone',
  TABLET = 'tablet',
  TV = 'tv',
  UNKNOWN = 'unknown',
}

/** 视口尺寸档位（随旋转 / 分屏变化） */
export enum SizeClass {
  COMPACT = 'compact',    // < 600 vp  手机竖屏
  MEDIUM = 'medium',      // 600~900   平板 / 折叠屏
  EXPANDED = 'expanded',  // >= 900    电视 / 手机横屏 / 大屏
}

export class Metrics {
  static readonly KEY_DEVICE: string = 'deviceTypeName';
  static readonly KEY_SIZE_CLASS: string = 'sizeClassName';
  static readonly KEY_WIDTH: string = 'screenWidthVp';
  static readonly KEY_HEIGHT: string = 'screenHeightVp';
  static readonly KEY_LANDSCAPE: string = 'isLandscape';
  /** 兼容旧键（其他地方还在读） */
  static readonly KEY_KIND: string = 'screenKind';

  /**
   * 初始化 / 更新。
   * 可以重复调用 —— 旋转、分屏、折叠屏展开都会重新进来。
   */
  static init(widthVp: number, heightVp: number = 0): void {
    // ① 设备类型：来自官方 API，不随窗口变化
    let dev: DeviceType = DeviceType.UNKNOWN;
    try {
      const t: string = deviceInfo.deviceType;
      if (t === 'phone') {
        dev = DeviceType.PHONE;
      } else if (t === 'tablet') {
        dev = DeviceType.TABLET;
      } else if (t === 'tv' || t === 'smartVision') {
        dev = DeviceType.TV;
      }
    } catch (e) {
      dev = DeviceType.UNKNOWN;
    }
    // 拿不到设备类型时，只在「非常宽」的情况下保守判为 TV
    if (dev === DeviceType.UNKNOWN) {
      dev = widthVp >= 1200 ? DeviceType.TV
        : (widthVp >= 700 ? DeviceType.TABLET : DeviceType.PHONE);
    }

    // ② 视口档位：只看当前宽度（横竖屏会变，这是对的）
    let sc: SizeClass = SizeClass.COMPACT;
    if (widthVp >= 900) {
      sc = SizeClass.EXPANDED;
    } else if (widthVp >= 600) {
      sc = SizeClass.MEDIUM;
    }

    const landscape: boolean = heightVp > 0 ? widthVp > heightVp : widthVp >= 600;

    AppStorage.setOrCreate<string>(Metrics.KEY_DEVICE, dev);
    AppStorage.setOrCreate<string>(Metrics.KEY_SIZE_CLASS, sc);
    AppStorage.setOrCreate<number>(Metrics.KEY_WIDTH, widthVp);
    AppStorage.setOrCreate<number>(Metrics.KEY_HEIGHT, heightVp);
    AppStorage.setOrCreate<boolean>(Metrics.KEY_LANDSCAPE, landscape);
    // 兼容旧键：TV 才写 tv，其余按视口写
    AppStorage.setOrCreate<string>(Metrics.KEY_KIND,
      dev === DeviceType.TV ? 'tv' : (sc === SizeClass.MEDIUM ? 'tablet' : 'phone'));
  }

  /* ───────── 设备类型（稳定） ───────── */

  static device(): DeviceType {
    const d = AppStorage.get<string>(Metrics.KEY_DEVICE);
    if (d === DeviceType.TV) {
      return DeviceType.TV;
    }
    if (d === DeviceType.TABLET) {
      return DeviceType.TABLET;
    }
    if (d === DeviceType.PHONE) {
      return DeviceType.PHONE;
    }
    return DeviceType.UNKNOWN;
  }

  /** 真正的电视（智慧屏）—— 只有它才启用遥控器焦点与防过扫描边距 */
  static isTv(): boolean {
    return Metrics.device() === DeviceType.TV;
  }

  /* ───────── 视口档位（随旋转变化） ───────── */

  static sizeClass(): SizeClass {
    const s = AppStorage.get<string>(Metrics.KEY_SIZE_CLASS);
    if (s === SizeClass.EXPANDED) {
      return SizeClass.EXPANDED;
    }
    if (s === SizeClass.MEDIUM) {
      return SizeClass.MEDIUM;
    }
    return SizeClass.COMPACT;
  }

  /** 兼容旧代码：视口是否像平板/电视那么宽 */
  static isTablet(): boolean {
    return Metrics.sizeClass() !== SizeClass.COMPACT;
  }

  static isLandscape(): boolean {
    const l = AppStorage.get<boolean>(Metrics.KEY_LANDSCAPE);
    return l !== undefined ? l : false;
  }

  static width(): number {
    const w = AppStorage.get<number>(Metrics.KEY_WIDTH);
    return w !== undefined ? w : 440;
  }

  static height(): number {
    const h = AppStorage.get<number>(Metrics.KEY_HEIGHT);
    return h !== undefined ? h : 0;
  }

  /* ───────── 尺寸派生 ───────── */

  /**
   * 缩放系数：按视口档位，不看设备类型。
   * ★ 这样手机横屏只是「宽一点」，不会突然按电视 ×1.75 放大。
   */
  static scale(): number {
    const sc: SizeClass = Metrics.sizeClass();
    if (Metrics.isTv() && sc === SizeClass.EXPANDED) {
      return 1.75;          // 真电视且确实很宽
    }
    if (sc === SizeClass.EXPANDED) {
      return 1.25;          // 手机横屏 / 分屏宽窗口：温和放大
    }
    if (sc === SizeClass.MEDIUM) {
      return 1.15;
    }
    return 1.0;
  }

  static s(v: number): number {
    return Math.round(v * Metrics.scale());
  }

  static f(v: number): number {
    const sc: SizeClass = Metrics.sizeClass();
    if (Metrics.isTv() && sc === SizeClass.EXPANDED) {
      return Math.round(v * 1.55);
    }
    if (sc === SizeClass.EXPANDED) {
      return Math.round(v * 1.12);
    }
    if (sc === SizeClass.MEDIUM) {
      return Math.round(v * 1.08);
    }
    return v;
  }

  /** 海报列数 */
  static gridColumns(): number {
    const sc: SizeClass = Metrics.sizeClass();
    if (Metrics.isTv() && sc === SizeClass.EXPANDED) {
      return 7;
    }
    if (sc === SizeClass.EXPANDED) {
      return 5;
    }
    if (sc === SizeClass.MEDIUM) {
      return 5;
    }
    return 4;
  }

  static heroHeight(): number {
    if (Metrics.isTv() && Metrics.sizeClass() === SizeClass.EXPANDED) {
      return 560;
    }
    return 414;
  }

  static pagePad(): number {
    if (Metrics.isTv() && Metrics.sizeClass() === SizeClass.EXPANDED) {
      return 56;
    }
    return 16;
  }

  /** 电视防过扫描安全边距；手机/平板为 0 */
  static safeTop(): number {
    return Metrics.isTv() ? 36 : 0;
  }
}
