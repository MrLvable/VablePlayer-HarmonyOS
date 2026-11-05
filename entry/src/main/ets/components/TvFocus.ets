import { Palette, Motion, withAlpha } from '../common/Theme';

/**
 * TV 交互组件 —— 同时支持
 *  · 遥控器方向键（focus）
 *  · 华为智慧屏遥控「指向」模式（air mouse → hover + 点击）
 *
 * 关键：hover 和 focus 用同一套视觉，指针用户和遥控用户都能看出可点
 */

/** 可聚焦 + 可悬停的文字按钮 */
@Component
export struct TvButton {
  @Prop label: string = '';
  @Prop darkMode: boolean = true;
  @Prop primary: boolean = false;
  @Prop buttonH: number = 40;
  @Prop fontSize: number = 14;
  @State private active: boolean = false;

  onTap: () => void = () => {};

  private P(): Palette {
    return this.darkMode ? Palette.dark() : Palette.light();
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(this.fontSize)
        .fontColor(this.primary || this.active ? '#FFFFFF' : this.P().text)
        .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
    }
    .height(this.buttonH)
    .padding({ left: 18, right: 18 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.primary ? this.P().accent :
      (this.active ? this.P().cardHover : this.P().chip))
    .borderRadius(this.buttonH / 2)
    .border({
      width: this.active ? 2 : 0,
      color: this.active ? withAlpha('#FFFFFF', 0.85) : '#00000000',
      radius: this.buttonH / 2
    })
    .scale({ x: this.active ? 1.06 : 1.0, y: this.active ? 1.06 : 1.0 })
    .animation({ duration: Motion.short, curve: Curve.Friction })
    .focusable(true)
    .onFocus(() => {
      this.active = true;
    })
    .onBlur(() => {
      this.active = false;
    })
    .onHover((isHover: boolean) => {
      this.active = isHover;
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 可聚焦 + 可悬停的图标按钮（毛玻璃圆钮） */
@Component
export struct TvIconButton {
  @Prop icon: Resource = $r('sys.symbol.ellipsis_circle');
  @Prop darkMode: boolean = true;
  @Prop size: number = 40;
  @Prop translucent: boolean = true;
  @State private active: boolean = false;

  onTap: () => void = () => {};

  private P(): Palette {
    return this.darkMode ? Palette.dark() : Palette.light();
  }

  build() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(Math.round(this.size * 0.45))
        .fontColor([this.P().text])
    }
    .width(this.size)
    .height(this.size)
    .justifyContent(FlexAlign.Center)
    .backdropBlur(20)
    .backgroundColor(this.translucent
      ? (this.darkMode ? withAlpha('#000000', 0.35) : withAlpha('#FFFFFF', 0.55))
      : this.P().chip)
    .borderRadius(this.size / 2)
    .border({
      width: this.active ? 2 : 0,
      color: this.active ? withAlpha('#FFFFFF', 0.9) : '#00000000',
      radius: this.size / 2
    })
    .scale({ x: this.active ? 1.1 : 1.0, y: this.active ? 1.1 : 1.0 })
    .animation({ duration: Motion.short, curve: Curve.Friction })
    .focusable(true)
    .onFocus(() => {
      this.active = true;
    })
    .onBlur(() => {
      this.active = false;
    })
    .onHover((isHover: boolean) => {
      this.active = isHover;
    })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 可聚焦 + 可悬停的图标+文字按钮（设置项） */
@Component
export struct TvListRow {
  @Prop icon: Resource = $r('sys.symbol.chevron_right');
  @Prop label: string = '';
  @Prop desc: string = '';
  @Prop showChevron: boolean = true;
  @Prop darkMode: boolean = true;
  @Prop fontSize: number = 15;
  @State private active: boolean = false;

  onTap: () => void = () => {};

  private P(): Palette {
    return this.darkMode ? Palette.dark() : Palette.light();
  }

  build() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(this.fontSize + 2)
        .fontColor([this.P().textDim])
        .margin({ right: 14 })

      Column() {
        Text(this.label)
          .fontSize(this.fontSize)
          .fontColor(this.P().text)
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(this.fontSize - 4)
            .fontColor(this.P().textDim)
            .margin({ top: 3 })
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(this.fontSize - 2)
          .fontColor([this.P().textDim])
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14, left: 4, right: 4 })
    .borderRadius(8)
    .backgroundColor(this.active ? withAlpha(this.P().accent, 0.10) : '#00000000')
    .focusable(true)
    .onFocus(() => {
      this.active = true;
    })
    .onBlur(() => {
      this.active = false;
    })
    .onHover((isHover: boolean) => {
      this.active = isHover;
    })
    .onClick(() => {
      this.onTap();
    })
  }
}
