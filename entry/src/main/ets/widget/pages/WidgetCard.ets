/**
 * 桌面小组件卡片 UI
 *
 * 注意：卡片只能使用受限的组件集
 * 不能用 @State / @Link / 复杂动画
 */
@Entry
@Component
struct WidgetCard {
  // 由 EntryFormAbility 注入
  @LocalStorageProp('title') title: string = 'VablePlayer';
  @LocalStorageProp('subtitle') subtitle: string = '打开应用继续观看';
  @LocalStorageProp('image') image: string = '';
  @LocalStorageProp('progress') progress: string = '0';

  build() {
    Column() {
      Row() {
        Text('VablePlayer')
          .fontSize(11)
          .fontColor('#8E8E93')
        Blank()
        Text('▶')
          .fontSize(11)
          .fontColor('#317AF7')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })

      Row() {
        // 海报
        Stack() {
          if (this.image.length > 0) {
            Image(this.image)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
          } else {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#2C2C2E')
              .borderRadius(6)
          }
        }
        .width(44)
        .height(62)
        .margin({ right: 10 })

        Column() {
          Text(this.title)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.subtitle)
            .fontSize(10)
            .fontColor('#8E8E93')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 })
      .alignItems(VerticalAlign.Top)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#171719')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}
