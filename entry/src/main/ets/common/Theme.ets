import { Store } from './Store';
import { hilog } from '@kit.PerformanceAnalysisKit';
/**
 * 主题系统 —— 对齐 HosPlayer
 *
 * ★ 核心：深浅两套色板 + 海报主色染色
 *   深色  背景 #000000  卡片 #171719  次级 #8E8E93
 *   浅色  背景 #FFFFFF  卡片 #ECEBF1  次级 #8E8E93
 */

export enum ThemeMode {
  DARK = 'dark',
  LIGHT = 'light',
  SYSTEM = 'system',
}

/** 一套色板 */
export class Palette {
  bg: string = '#000000';            // 页面底色
  card: string = '#171719';          // 卡片
  cardHover: string = '#1F1F22';
  divider: string = '#2C2C2E';       // 分割线
  text: string = '#FFFFFF';          // 主文字
  textDim: string = '#8E8E93';       // 次文字
  textFaint: string = '#5A5A5E';     // 更淡
  section: string = '#757575';       // 分组标题
  chip: string = '#18181A';          // 下拉胶囊
  accent: string = '#317AF7';        // 强调色（由 Theme.accent() 覆盖）
  star: string = '#FFD166';          // 星标
  scrim: string = '#000000';         // 遮罩基色
  navBg: string = '#1C1C1F';         // 悬浮底栏

  constructor(init?: (p: Palette) => void) {
    if (init) {
      init(this);
    }
  }

  static dark(): Palette {
    return new Palette((p: Palette) => {
      // 方案 5.1 深色 token
      p.bg = '#161518'; // 参考录屏服务器、设置空白区域采样
      p.card = '#2B2A2D'; // 参考录屏设置分组卡片采样
      p.cardHover = '#343337';
      p.divider = withAlpha('#FFFFFF', 0.10);   // 白 10%（必须是 #AARRGGBB，不能用 RRGGBBAA）
      p.text = '#F5F6F8';
      p.textDim = '#B6BAC3';
      p.textFaint = '#8A8E97';
      p.section = '#A3A8B2';         // 年份/区块辅助文字
      p.chip = '#28272A';
      p.accent = '#317AF7';
      p.star = '#FFD166';
      p.scrim = '#000000';
      p.navBg = '#141417';
    });
  }

  static light(): Palette {
    return new Palette((p: Palette) => {
      // 方案 5.1 浅色 token
      p.bg = '#F7F8FA';
      p.card = '#FFFFFF';
      p.cardHover = '#F0F2F5';
      p.divider = withAlpha('#000000', 0.08);   // 黑 8%（同上）
      p.text = '#17181C';
      p.textDim = '#555B65';
      p.textFaint = '#7C828C';
      p.section = '#606670';         // 年份/区块辅助文字
      p.chip = '#EFF1F4';
      p.accent = '#317AF7';
      p.star = '#805500';            // 浅色下星标用深琥珀，保证对比度
      p.scrim = '#FFFFFF';
      p.navBg = '#FFFFFF';
    });
  }
}

/** 全局主题单例（用 AppStorage 驱动重绘） */
export class Theme {
  static readonly KEY_MODE: string = 'themeMode';
  static readonly KEY_ACCENT: string = 'accentColor';

  /** 可选主题色 */
  static readonly ACCENTS: string[] = [
    '#317AF7',   // 蓝（默认）
    '#8B5CF6',   // 紫
    '#EC4899',   // 粉
    '#EF4444',   // 红
    '#F59E0B',   // 橙
    '#10B981',   // 绿
    '#06B6D4',   // 青
    '#64748B'    // 灰
  ];

  static accent(): string {
    const a = AppStorage.get<string>(Theme.KEY_ACCENT);
    return a !== undefined ? a : '#317AF7';
  }

  /**
   * 唯一主题色入口：更新响应式状态 + 持久化。
   * ★ 原实现 setAccent 只改内存、setAccent2 才存盘，而设置页调用的是前者，
   *   导致"颜色改了但重启丢失"。
   */
  static setAccent(c: string): void {
    if (c.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(Theme.KEY_ACCENT, c);
    Store.set('accentColor', c);
  }

  /** 系统当前是否为深色（由 UIAbility 的 onConfigurationUpdate 写入）*/
  static readonly KEY_SYS_DARK: string = 'sysDark';

  static init(): void {
    if (AppStorage.get<string>(Theme.KEY_MODE) === undefined) {
      AppStorage.setOrCreate<string>(Theme.KEY_MODE, ThemeMode.SYSTEM);
    }
    if (AppStorage.get<boolean>(Theme.KEY_SYS_DARK) === undefined) {
      AppStorage.setOrCreate<boolean>(Theme.KEY_SYS_DARK, true);
    }
  }

  /** 从持久化存储恢复主题（启动时调一次）*/
  static async restore(): Promise<void> {
    try {
      // ★ mode 和 accent 各自独立恢复，任一个缺失不影响另一个
      const saved = await Store.get('themeMode', '');
      if (saved.length > 0) {
        AppStorage.setOrCreate<string>(Theme.KEY_MODE, saved);
      }
      const ac = await Store.get('accentColor', '');
      if (ac.length > 0) {
        AppStorage.setOrCreate<string>(Theme.KEY_ACCENT, ac);
      }
    } catch (e) {
      // 首次启动没有存过，忽略
    }
  }

  /** 系统深浅色变化时由 Ability 调用 */
  static setSystemDark(dark: boolean): void {
    AppStorage.setOrCreate<boolean>(Theme.KEY_SYS_DARK, dark);
  }

  static mode(): string {
    const m = AppStorage.get<string>(Theme.KEY_MODE);
    return m !== undefined ? m : ThemeMode.SYSTEM;
  }

  /** ★ 改主题要存盘，否则重启就丢（之前就是这个 Bug）*/
  static setMode(m: string): void {
    hilog.info(0x0001, 'NasPlay', 'THEME setMode=%{public}s', m);
    AppStorage.setOrCreate<string>(Theme.KEY_MODE, m);
    Store.set('themeMode', m);
  }

  /** 当前是否为深色 */
  static isDark(): boolean {
    const m = Theme.mode();
    if (m === ThemeMode.DARK) {
      return true;
    }
    if (m === ThemeMode.LIGHT) {
      return false;
    }
    // ★ 跟随系统：读系统实际模式（之前硬编码 true，导致永远深色）
    const d = AppStorage.get<boolean>(Theme.KEY_SYS_DARK);
    return d !== undefined ? d : true;
  }

  static palette(): Palette {
    const p = Theme.isDark() ? Palette.dark() : Palette.light();
    p.accent = Theme.accent();
    return p;
  }
}

/** 按模式取色（供 @Builder 里直接调） */
export function pal(dark: boolean): Palette {
  const p = dark ? Palette.dark() : Palette.light();
  p.accent = Theme.accent();
  return p;
}

/* ───────── 颜色工具 ───────── */

export function hexToRgb(hex: string): number[] {
  const h = hex.replace('#', '');
  const s = h.length === 8 ? h.substring(2) : h;
  const r = parseInt(s.substring(0, 2), 16);
  const g = parseInt(s.substring(2, 4), 16);
  const b = parseInt(s.substring(4, 6), 16);
  return [r, g, b];
}

export function rgbToHex(r: number, g: number, b: number): string {
  const f = (v: number): string => {
    const x = Math.max(0, Math.min(255, Math.round(v)));
    const t = x.toString(16);
    return t.length === 1 ? '0' + t : t;
  };
  return '#' + f(r) + f(g) + f(b);
}

export function withAlpha(hex: string, a: number): string {
  const c = hexToRgb(hex);
  const al = Math.round(Math.max(0, Math.min(1, a)) * 255);
  const t = al.toString(16);
  return '#' + (t.length === 1 ? '0' + t : t) + rgbToHex(c[0], c[1], c[2]).substring(1);
}

export function mix(a: string, b: string, t: number): string {
  const ca = hexToRgb(a);
  const cb = hexToRgb(b);
  const k = Math.max(0, Math.min(1, t));
  return rgbToHex(
    ca[0] + (cb[0] - ca[0]) * k,
    ca[1] + (cb[1] - ca[1]) * k,
    ca[2] + (cb[2] - ca[2]) * k
  );
}

/**
 * ★ 海报染色：把图片主色压成页面底色
 * 深色 lerp(color, black, 0.78)
 * 浅色 lerp(color, white, 0.82)
 */
export function tint(bgColor: string, dark: boolean): string {
  return dark ? mix(bgColor, '#000000', 0.78) : mix(bgColor, '#FFFFFF', 0.82);
}

/** 基础动效时长 */
export class Motion {
  static readonly focus: number = 230;
  static readonly short: number = 180;
  static readonly page: number = 300;
  static readonly indicator: number = 260;
  // 兼容旧名
  static readonly focusDuration: number = 230;
  static readonly shortDuration: number = 180;
  static readonly pageDuration: number = 300;
  static readonly indicatorDuration: number = 260;
}

/** 圆角 */
export class Radius {
  /** 海报封面圆角：参考约 10 源像素量级（≈1.32x 参考密度 → 约 8vp） */
  static readonly poster: number = 8;
  static readonly card: number = 20;
  static readonly nav: number = 30;
  static readonly chip: number = 16;
}

/** 尺寸（按 HosPlayer 实测，单位 dp） */
export class Size {
  static readonly heroHeight: number = 414;
  static readonly serverChipW: number = 114;
  static readonly serverChipH: number = 36;
  static readonly searchBtn: number = 38;
  static readonly resumeCardW: number = 191;
  static readonly resumeCardH: number = 107;
  static readonly navW: number = 287;
  static readonly navH: number = 53;
  static readonly navItemW: number = 53;
  static readonly posterW: number = 107;
  static readonly posterH: number = 160;
  static readonly pagePad: number = 11;
}

/* ───────── 兼容旧代码（固定深色） ─────────
 * 新代码请用 pal(dark) 拿当前模式的色板
 */
export class C {
  static readonly bg: string = '#000000';
  static readonly bg1: string = '#0A0A0C';
  static readonly bg2: string = '#141416';
  static readonly card: string = '#171719';
  static readonly accent: string = '#317AF7';
  static readonly accent2: string = '#5B9BF8';
  static readonly text: string = '#F5F5F7';
  static readonly dim: string = '#8E8E93';
  static readonly faint: string = '#5A5A5E';
  static readonly section: string = '#757575';
  static readonly star: string = '#FFD166';
  static readonly white: string = '#FFFFFF';
  static readonly transparent: string = '#00000000';

  static whiteA(a: number): string {
    return withAlpha('#FFFFFF', a);
  }

  static blackA(a: number): string {
    return withAlpha('#000000', a);
  }
}

export class Layout {
  static readonly pagePadding: number = 11;
  static readonly posterRadius: number = 12;
  static readonly cardRadius: number = 20;
  static readonly navRadius: number = 30;
  static readonly navHeight: number = 53;
}
