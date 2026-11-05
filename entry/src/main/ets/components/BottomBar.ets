import { Palette, Radius, Size, Motion, withAlpha } from '../common/Theme';
import { Metrics } from '../common/Metrics';
import { MotionSpec, MotionCurve } from '../common/MotionSpec';

/**
 * AppDock —— 底部悬浮 dock
 *
 * 方案 6.3 落地要点：
 *  · 外壳只保留一次材质；navItem 内部 **不再做任何模糊**
 *    （原实现每个 tab 又加 THIN/ULTRA_THIN，浅色下变成五个白圆饼）
 *  · 选中态只加主题色 12% 实色背景，不加模糊
 *  · 每个 tab 至少 48vp 可点击高度；图标 22vp、标签 11fp
 *  · 手机 dock 宽 min(W−32, 360)、高 60、圆角 30
 *  · 底部间距由父容器传入（安全区 + 12），不在这里写死
 */
@Component
export struct BottomBar {
  @Prop active: number = 0;
  @Prop darkMode: boolean = true;
  /** 由父容器计算好的底部间距 = safeBottomVp + 12 */
  @Prop bottomGap: number = 12;
  onSelect: (index: number) => void = () => {};

  @State private hoverIdx: number = -1;
  /**
   * 订阅用户保存的强调色（方案 R06）。
   * ★ 旧实现 P() 每次都 new 一个默认 Palette，accent 恒为内置蓝，
   *   设置页改了强调色 dock 根本不跟。
   */
  @StorageProp('accentColor') accentColor: string = '#317AF7';


  private labels: string[] = ['首页', '发现', '收藏', '服务器', '设置'];

  private P(): Palette {
    const base: Palette = this.darkMode ? Palette.dark() : Palette.light();
    // 用保存的强调色覆盖（空串时保留主题默认）
    if (this.accentColor.length > 0) {
      base.accent = this.accentColor;
    }
    return base;
  }

  /** dock 宽度：min(W−32, 360) */
  private dockWidth(): number {
    const w = Metrics.width();
    const avail = (w > 0 ? w : 440) - 32;
    return Math.max(240, Math.min(360, avail));
  }

  build() {
    Column() {
      // ★ 取舍说明（方案 C）：
      //   官方 systemMaterial 在深色下即使 ULTRA_THICK 仍然太透，
      //   dock 浮在彩色海报上时 tab 文字读不清；而系统材质不允许再叠
      //   backgroundColor（会直接屏蔽材质），没法补对比度。
      //   所以 dock 回到手写 backgroundBlurStyle 的玻璃胶囊，保证可读性；
      //   官方流光组件 HdsVisualComponent 改到 Hero 大图上用（那里效果更明显）。
      Row() {
        ForEach(this.labels, (label: string, index: number) => {
          this.navItem(label, index)
        }, (label: string, index: number) => index.toString())
      }
      .width(this.dockWidth())
      .height(60)
      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
      // 唯一材质层：整块一次模糊，tab 内部零模糊
      .backgroundBlurStyle(
        this.darkMode ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_REGULAR,
        { colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }
      )
      .backgroundColor(withAlpha(this.darkMode ? '#000000' : '#FFFFFF',
        this.darkMode ? 0.42 : 0.72))
      .borderRadius(30)
      .border({
        width: 0.5,
        color: this.darkMode ? withAlpha('#FFFFFF', 0.14) : withAlpha('#000000', 0.07)
      })
      .shadow({
        radius: this.darkMode ? 18 : 22,
        color: withAlpha('#000000', this.darkMode ? 0.26 : 0.12),
        offsetX: 0,
        offsetY: 4
      })

      // 材质与流光已拆到 Stack 的前两层
    }
    .width('100%')
    .padding({ bottom: this.bottomGap })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  navItem(label: string, index: number) {
    Column() {
      if (index === 0) {
        SymbolGlyph(this.active === 0 ? $r('sys.symbol.house_fill') : $r('sys.symbol.house'))
          .fontSize(22)
          .fontColor([this.active === index ? this.P().accent : this.P().textDim])
      } else if (index === 1) {
        SymbolGlyph($r('sys.symbol.circle_grid_2x2'))
          .fontSize(22)
          .fontColor([this.active === index ? this.P().accent : this.P().textDim])
      } else if (index === 2) {
        SymbolGlyph(this.active === 2 ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(22)
          .fontColor([this.active === index ? this.P().accent : this.P().textDim])
      } else if (index === 3) {
        SymbolGlyph(this.active === 3 ? $r('sys.symbol.TV_tv_fill') : $r('sys.symbol.TV_tv'))
          .fontSize(22)
          .fontColor([this.active === index ? this.P().accent : this.P().textDim])
      } else {
        SymbolGlyph(this.active === 4 ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor([this.active === index ? this.P().accent : this.P().textDim])
      }

      Text(label)
        .fontSize(11)
        .fontColor(this.active === index ? this.P().accent : this.P().textDim)
        .fontWeight(this.active === index ? FontWeight.Bold : FontWeight.Medium)
        .maxLines(1)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(26)
    // ★ 选中态：只用主题色 12% 实色，不加模糊
    .backgroundColor(this.active === index
      ? withAlpha(this.P().accent, 0.12)
      : (this.hoverIdx === index
        ? withAlpha(this.darkMode ? '#FFFFFF' : '#000000', this.darkMode ? 0.06 : 0.04)
        : '#00000000'))
    .focusable(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onHover((isHover: boolean) => {
      this.hoverIdx = isHover ? index : -1;
    })
    .onClick(() => {
      this.onSelect(index);
    })
    .animation({ duration: MotionSpec.fast, curve: MotionCurve.inCurve })
  }
}
