import { Palette, Radius, Motion, withAlpha } from '../common/Theme';
import { Metrics } from '../common/Metrics';
import { NetImage } from './NetImage';

/**
 * 海报卡片
 *
 * 对齐参考应用：
 *  · 海报本身 12dp 圆角，标题/年份在卡片外面
 *  · 没有任何外层卡片边框/背景（之前那种会包住文字）
 *  · 默认全亮，聚焦/悬停才放大 + 高光
 */
@Component
export struct PosterCard {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop imageUrl: string = '';
  /** 示例模式的内置海报（不请求网络，不是真实数据） */
  @Prop demoRes: Resource | undefined = undefined;
  @Prop rating: number = 0;
  @Prop progress: number = 0;
  @Prop watched: boolean = false;
  @Prop cardWidth: number = 107;
  @Prop darkMode: boolean = true;
  @Prop token: string = '';
  @Prop authHeader: string = '';
  @Prop headers: Record<string, string> = {};

  @State private focused: boolean = false;
  @State private hovered: boolean = false;

  onTap: () => void = () => {};

  private P(): Palette {
    return this.darkMode ? Palette.dark() : Palette.light();
  }

  private active(): boolean {
    return this.focused || this.hovered;
  }

  private titleSize(): number {
    return Metrics.f(10);
  }

  private subSize(): number {
    return Metrics.f(8);
  }

  build() {
    Column() {
      // ── 海报主体（只有它有圆角）──
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.demoRes !== undefined) {
          Image(this.demoRes)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else if (this.imageUrl.length > 0) {
          NetImage({
            url: this.imageUrl,
            token: this.token,
            authHeader: this.authHeader,
            headers: this.headers,
            darkMode: this.darkMode
          })
            .width('100%')
            .height('100%')
        } else {
          Column() {
            Text('无海报')
              .fontSize(this.subSize())
              .fontColor(this.P().textFaint)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.darkMode ? withAlpha('#FFFFFF', 0.06) : withAlpha('#000000', 0.05))
        }

        // 聚焦/悬停高光
        if (this.active()) {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [
                [withAlpha('#FFFFFF', 0.18), 0.0],
                [withAlpha('#FFFFFF', 0.0), 0.5]
              ]
            })
        }

        // 评分角标
        if (this.rating > 0) {
          Text(this.rating.toFixed(1))
            .fontSize(this.subSize())
            .fontColor(this.P().star)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor(withAlpha('#000000', 0.62))
            .borderRadius(4)
            .margin({ right: 5, bottom: 5 })
        }

        // 观看进度条
        if (this.progress > 0.005 && this.progress < 0.995) {
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .backgroundColor(withAlpha('#000000', 0.55))
            Row()
              .width((this.progress * 100).toFixed(1) + '%')
              .height(3)
              .backgroundColor(this.P().accent)
          }
          .width('100%')
          .height(3)
        }

        // 已看角标
        if (this.watched) {
          Text('已看')
            .fontSize(this.subSize() - 1)
            .fontColor('#FFFFFF')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor(withAlpha('#1B7A3A', 0.85))
            .borderRadius(4)
            .margin({ left: 5, top: 5 })
        }
      }
      .width('100%')
      .aspectRatio(0.667)
      .backgroundColor(this.darkMode ? withAlpha('#FFFFFF', 0.06) : withAlpha('#000000', 0.05))
      .borderRadius(Radius.poster)
      .clip(true)
      .shadow({
        radius: this.active() ? 20 : 0,
        color: withAlpha('#000000', 0.7),
        offsetX: 0,
        offsetY: 6
      })
      .border({
        width: this.active() ? 2 : 0,
        color: this.active() ? withAlpha('#FFFFFF', 0.92) : '#00000000',
        radius: Radius.poster
      })
      .scale({
        x: this.active() ? 1.10 : 1.0,
        y: this.active() ? 1.10 : 1.0
      })
      .animation({ duration: Motion.focus, curve: Curve.Friction })

      // ── 标题（卡片外面，居中一行；R12 方案 §6.2）──
      Text(this.title)
        .fontSize(this.titleSize())
        .fontColor(this.P().text)
        .fontWeight(this.active() ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 7 })
        .width('100%')

      // ── 年份（卡片外面，居中紧随标题下一行）──
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(this.subSize())
          .fontColor(this.P().textDim)
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .margin({ top: 2 })
          .width('100%')
      }
    }
    .width(this.cardWidth)
    .backgroundColor('#00000000')
    .focusable(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.93 })
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
    .onHover((isHover: boolean) => {
      this.hovered = isHover;
    })
    .onClick(() => {
      this.onTap();
    })
  }
}
