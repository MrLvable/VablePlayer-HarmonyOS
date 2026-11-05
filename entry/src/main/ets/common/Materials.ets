import { uiMaterial } from '@kit.ArkUI';
import { withAlpha } from './Theme';

/**
 * Materials —— **全局材质唯一入口**
 *
 * 目的（工程约束）：
 *   · 系统材质（沉浸/玻璃）的参数只在这里定义，避免「dock 一套、工具栏一套、
 *     菜单又一套」，导致同屏几种玻璃透明度不一样；
 *   · 交互光效（interactive / lightEffect）在这里统一打开，凡是套材质的
 *     可点区域都自动有按压光效，不用每处补；
 *   · 换配色/换档位只改这里。
 *
 * 官方材质须由 Dialog / Menu / Popup / Sheet 等支持的容器承载。
 * 普通 Column 任意屏幕位置仅加 systemMaterial 不等于有效的光感弹层。
 * module.metadata 启用 ENABLE 时官方材质优先视觉属性；内容仍避免不透明整底。
 * 材质实例缓存复用，系统负责交互光效和设备分级。
 */
export class Materials {
  /**
   * 全局沉浸材质。
   * @param dark      当前是否深色
   * @param accent    主题强调色（用作交互光源色）
   * @param tintAlpha 材质内部染色 alpha（默认深色更实、浅色更透）
   */
  static immersive(dark: boolean, accent: string, tintAlpha: number): uiMaterial.ImmersiveMaterial {
    const opts: uiMaterial.ImmersiveOptions = {
      // 深色下用纯黑染色：系统材质底色偏浅，用 #0D0E12 时量少会发白，
      // 纯黑能在较低 alpha 下就压出「暗玻璃」的观感（参考应用就是暗玻璃）。
      materialColor: withAlpha(dark ? '#000000' : '#FFFFFF', tintAlpha),
      interactive: true,
      lightEffect: {
        color: withAlpha(accent, 0.55)
      }
    };
    return new uiMaterial.ImmersiveMaterial(opts);
  }

  /**
   * dock / 悬浮 bar 用的标准参数。
   * ★ 必须缓存：这个 getter 在 build 里调用，每次 new ImmersiveMaterial
   *   会导致材质节点重建，真机上直接把主线程拖死（ThreadBlock6S, signal:9）。
   */
  private static dockDark: uiMaterial.ImmersiveMaterial | null = null;
  private static dockLight: uiMaterial.ImmersiveMaterial | null = null;
  private static dockDarkAccent: string = '';
  private static dockLightAccent: string = '';

  static dockMaterial(dark: boolean, accent: string): uiMaterial.ImmersiveMaterial {
    if (dark) {
      if (Materials.dockDark === null || Materials.dockDarkAccent !== accent) {
        Materials.dockDark = Materials.immersive(true, accent, 0.30);
        Materials.dockDarkAccent = accent;
      }
      return Materials.dockDark;
    }
    if (Materials.dockLight === null || Materials.dockLightAccent !== accent) {
      Materials.dockLight = Materials.immersive(false, accent, 0.22);
      Materials.dockLightAccent = accent;
    }
    return Materials.dockLight;
  }

  private static popupDark: uiMaterial.ImmersiveMaterial | null = null;
  private static popupLight: uiMaterial.ImmersiveMaterial | null = null;
  private static popupDarkAccent: string = '';
  private static popupLightAccent: string = '';

  /** Native Dialog/Menu/Popup/Sheet surface; do not layer a painted card over it. */
  static popupMaterial(dark: boolean, accent: string): uiMaterial.ImmersiveMaterial {
    if (dark) {
      if (Materials.popupDark === null || Materials.popupDarkAccent !== accent) {
        Materials.popupDark = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK,
          materialColor: withAlpha('#000000', 0.48), interactive: true,
          lightEffect: { color: withAlpha(accent, 0.55) } });
        Materials.popupDarkAccent = accent;
      }
      return Materials.popupDark;
    }
    if (Materials.popupLight === null || Materials.popupLightAccent !== accent) {
      Materials.popupLight = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK,
        materialColor: withAlpha('#FFFFFF', 0.24), interactive: true,
        lightEffect: { color: withAlpha(accent, 0.55) } });
      Materials.popupLightAccent = accent;
    }
    return Materials.popupLight;
  }

  /* ───────── 自绘玻璃（不能用系统材质的地方：工具栏胶囊、菜单）───────── */

  static glassBlur(dark: boolean): BlurStyle {
    // 参考应用是「薄玻璃」：模糊强、染色淡。模糊等级比染色更重要。
    return dark ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_REGULAR;
  }

  static glassMode(dark: boolean): ThemeColorMode {
    return dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT;
  }

  /** 玻璃底色的统一 alpha —— 调低，让后方内容透出来（参考图观感） */
  static glassTintAlpha(dark: boolean): number {
    return dark ? 0.10 : 0.30;
  }

  static glassTint(dark: boolean): string {
    return withAlpha(dark ? '#000000' : '#FFFFFF', Materials.glassTintAlpha(dark));
  }

  /** 菜单/面板底色（比玻璃更实，保证文字可读） */
  static panelBg(dark: boolean): string {
    return dark ? '#22232A' : '#FFFFFF';
  }

  static panelBorder(dark: boolean): string {
    return dark ? withAlpha('#FFFFFF', 0.14) : withAlpha('#000000', 0.08);
  }
}
