import { PlaybackPreferences, PlaybackPreferenceValues } from '../common/PlaybackPreferences';
import { Theme, Palette } from '../common/Theme';
import { promptAction } from '@kit.ArkUI';

@Component
export struct PlaybackSettings {
  section: string = 'playback';
  darkMode: boolean = true;
  @State private value: PlaybackPreferenceValues = new PlaybackPreferenceValues();
  @State private busy: boolean = false;
  private mounted: boolean = false;
  aboutToAppear(): void {
    this.mounted = true;
    PlaybackPreferences.load().then((value: PlaybackPreferenceValues) => {
      if (this.mounted) { this.value = value; }
    });
  }
  aboutToDisappear(): void { this.mounted = false; }
  private P(): Palette { return this.darkMode ? Palette.dark() : Palette.light(); }
  private async update(field: string, text: string, enabled: boolean): Promise<void> {
    if (this.busy) { return; }
    const next = PlaybackPreferences.current();
    if (field === 'autoNext') { next.autoNext = enabled; }
    if (field === 'doubleTapPause') { next.doubleTapPause = enabled; }
    if (field === 'ratio') { next.ratio = text; }
    if (field === 'subtitleScale') { next.subtitleScale = Number(text); }
    this.busy = true;
    try { await PlaybackPreferences.save(next); if (this.mounted) { this.value = next; } }
    catch (error) { promptAction.showToast({ message: '保存失败，请重试' }); }
    finally { if (this.mounted) { this.busy = false; } }
  }
  @Builder
  toggleRow(title: string, enabled: boolean, field: string) {
    Row() {
      Text(title).fontSize(15).fontColor(this.P().text).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled }).selectedColor(Theme.accent())
        .enabled(!this.busy).onChange((next: boolean) => { this.update(field, '', next); })
    }.width('100%').padding(16).backgroundColor(this.P().card).borderRadius(14)
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.section === 'interaction' || this.section === 'playback') {
          this.toggleRow('双击画面播放 / 暂停', this.value.doubleTapPause, 'doubleTapPause')
          this.toggleRow('播完自动播放下一集', this.value.autoNext, 'autoNext')
          Text('单击显示控制栏；左右拖动调整进度，画面左侧上下滑动调整亮度，右侧调整音量。')
            .fontSize(13).lineHeight(21).fontColor(this.P().textDim).width('100%')
        }
        if (this.section === 'layout' || this.section === 'playback') {
          Text('默认画面比例').fontSize(13).fontColor(this.P().textDim).width('100%')
          ForEach(['默认', '平铺', '拉伸', '裁切', '16:9', '4:3', '原始像素比例'], (ratio: string) => {
            Button(this.value.ratio === ratio ? '✓  ' + ratio : ratio)
              .fontSize(15).fontColor(this.value.ratio === ratio ? Theme.accent() : this.P().text)
              .backgroundColor(this.P().card).height(46).width('100%').borderRadius(12).enabled(!this.busy)
              .onClick(() => { this.update('ratio', ratio, false); })
          }, (ratio: string) => ratio)
          Text('默认保留完整画面；平铺等比放大并裁去边缘；拉伸铺满时会改变人物比例。')
            .fontSize(13).lineHeight(21).fontColor(this.P().textDim).width('100%')
        }
        if (this.section === 'subtitles') {
          Text('默认字幕大小').fontSize(13).fontColor(this.P().textDim).width('100%')
          ForEach([0.8, 1, 1.25, 1.5], (scale: number) => {
            Button((this.value.subtitleScale === scale ? '✓  ' : '') +
              (scale === 0.8 ? '较小' : scale === 1 ? '默认' : scale === 1.25 ? '较大' : '特大'))
              .fontSize(15).fontColor(this.value.subtitleScale === scale ? Theme.accent() : this.P().text)
              .backgroundColor(this.P().card).height(48).width('100%').enabled(!this.busy)
              .onClick(() => { this.update('subtitleScale', scale.toString(), false); })
          }, (scale: number) => scale.toString())
          Text('播放时可选择内封 / 外挂字幕、调整偏移和大小。AI 翻译服务在 AI 字幕翻译中配置。')
            .fontSize(13).lineHeight(21).fontColor(this.P().textDim).width('100%')
        }
        Text('设置从下一次打开影片开始生效，播放页内的临时调整优先。')
          .fontSize(12).fontColor(this.P().textFaint).width('100%')
      }.width('100%').padding({ left: 20, right: 20, top: 90, bottom: 36 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.TopStart).backgroundColor(this.P().bg)
  }
}
