import { ServerConfig, MediaItem, Library } from '../common/Models';
import { SourceBrowserController, SourceBrowserState, SourceCrumb } from '../common/services/SourceBrowserController';
import { IptvProgramme } from '../common/services/IptvCatalog';
import { Palette } from '../common/Theme';
import { Metrics } from '../common/Metrics';
import { NetImage } from './NetImage';

/** Real file/live catalog browser. Parent owns playback/navigation and active-page state. */
@Component
export struct SourceBrowser {
  @Prop @Watch('inputsChanged') server: ServerConfig = new ServerConfig('', 'local', '', '', 0, '', '', '');
  @Prop @Watch('inputsChanged') active: boolean = true;
  @Prop darkMode: boolean = true;
  onPlay: (item: MediaItem, siblings: MediaItem[]) => void = () => {};
  onManage: (() => void) | undefined = undefined;
  @State private frame: SourceBrowserState = new SourceBrowserState();
  @State private searchText: string = '';
  private controller: SourceBrowserController | null = null;
  private mounted: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.controller = new SourceBrowserController((state: SourceBrowserState) => {
      if (!this.mounted || !this.active) { return; }
      if (state.scope !== this.frame.scope || (state.query.length === 0 && this.frame.query.length > 0)) { this.searchText = ''; }
      this.frame = state; // Controller publishes only after 16ms and generation/scope guards.
    });
    this.controller.configure(this.server, this.active);
  }
  aboutToDisappear(): void { this.mounted = false; if (this.controller !== null) { this.controller.destroy(); this.controller = null; } }
  private inputsChanged(): void { if (this.mounted && this.controller !== null) { this.controller.configure(this.server, this.active); } }
  private P(): Palette { return this.darkMode ? Palette.dark() : Palette.light(); }
  private current(): boolean { return this.active && this.frame.scope === SourceBrowserController.scope(this.server); }
  private live(): boolean { return this.server.kind === 'iptv'; }
  private open(item: MediaItem): void {
    if (!this.current() || this.controller === null) { return; }
    if (item.isFolder()) { this.controller.enter(item); }
    else if (item.isPlayable()) { this.onPlay(item, this.frame.items.filter((entry: MediaItem) => entry.isPlayable())); }
    else { this.controller.explainFile(item); }
  }
  private date(item: MediaItem): string {
    const value = SourceBrowserController.time(item);
    return Number.isFinite(value) ? new Date(value).toLocaleDateString() : '';
  }
  private subtitle(item: MediaItem): string {
    if (item.isFolder()) { return '文件夹'; }
    const date = this.date(item); return (item.container.length > 0 ? item.container.toUpperCase() : this.live() ? '频道' : '文件') + (date.length > 0 ? ' · ' + date : '');
  }
  private nowText(): string {
    const now = Date.now(); const item = this.frame.programmes.find((entry: IptvProgramme) => entry.startMs <= now && entry.endMs > now);
    return item !== undefined ? item.title : '暂无当前节目数据';
  }
  private nextText(): string {
    const now = Date.now(); const item = this.frame.programmes.find((entry: IptvProgramme) => entry.startMs > now);
    return item !== undefined ? new Date(item.startMs).toTimeString().substring(0, 5) + ' ' + item.title : '暂无接下来节目数据';
  }
  @Builder private thumbnail(item: MediaItem, width: number, height: number) {
    Stack() {
      if (this.controller !== null && this.controller.imageUrl(item).length > 0) {
        NetImage({ url: this.controller.imageUrl(item), headers: this.controller.imageHeaders(item), token: '', authHeader: '',
          darkMode: this.darkMode, fit: this.live() ? ImageFit.Contain : ImageFit.Cover, targetWidth: 480 })
          .width('100%').height('100%')
      } else {
        SymbolGlyph(item.isFolder() ? $r('sys.symbol.folder') : $r('sys.symbol.play_fill'))
          .fontSize(item.isFolder() ? 28 : 22).fontColor([this.P().textDim])
      }
    }.width(width).height(height).backgroundColor(this.P().card).borderRadius(10).clip(true)
  }
  @Builder private favorite(item: MediaItem) {
    if (!item.isFolder() && item.isPlayable()) {
      Button() {
        SymbolGlyph(item.favoriteKnown && item.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(19).fontColor([item.favoriteKnown && item.isFavorite ? this.P().accent : this.P().textDim])
      }.width(40).height(40).backgroundColor(Color.Transparent)
        .enabled(this.frame.favoriteBusy.indexOf(item.id) < 0)
        .accessibilityText(item.favoriteKnown && item.isFavorite ? '移除本机收藏' : '加入本机收藏')
        .onClick(() => { if (this.controller !== null) { this.controller.toggleFavorite(item); } })
    }
  }
  @Builder private listRow(item: MediaItem) {
    Row({ space: 12 }) {
      Row({ space: 12 }) {
        this.thumbnail(item, 80, 52)
        Column({ space: 5 }) {
          Text(item.name).fontSize(15).fontColor(this.P().text).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.subtitle(item)).fontSize(11).fontColor(this.P().textDim).maxLines(1).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).onClick(() => { this.open(item); })
      if (this.live()) { Button('节目单').fontSize(11).height(32).backgroundColor(this.P().card).fontColor(this.P().accent)
        .onClick(() => { if (this.controller !== null) { this.controller.loadEpg(item); } }) }
      this.favorite(item)
    }.width('100%').padding({ top: 10, bottom: 10 }).border({ width: { bottom: 0.5 }, color: this.P().divider })
  }
  @Builder private gridCard(item: MediaItem) {
    Column({ space: 8 }) {
      Column({ space: 8 }) {
        this.thumbnail(item, Math.max(100, (Metrics.width() - 56) / (Metrics.width() >= 600 ? 4 : 2)), this.live() ? 82 : 105)
        Text(item.name).fontSize(13).fontColor(this.P().text).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(this.subtitle(item)).fontSize(10).fontColor(this.P().textDim).maxLines(1).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start).onClick(() => { this.open(item); })
      Row() {
        if (this.live()) { Button('节目单').fontSize(10).height(28).backgroundColor(this.P().card).fontColor(this.P().accent)
          .onClick(() => { if (this.controller !== null) { this.controller.loadEpg(item); } }) }
        Blank()
        this.favorite(item)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private header() {
    Row() {
      Column({ space: 4 }) {
        Text(this.server.name || (this.live() ? '直播来源' : '文件来源')).fontSize(24).fontWeight(FontWeight.Medium).fontColor(this.P().text)
        Text(this.live() ? '按真实分组浏览频道' : '浏览已授权来源中的真实文件').fontSize(12).fontColor(this.P().textDim)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.onManage !== undefined) { Button('管理来源').height(36).fontSize(12).backgroundColor(this.P().card).fontColor(this.P().accent)
        .onClick(() => { if (this.onManage !== undefined) { this.onManage(); } }) }
    }.width('100%').padding({ top: 16, bottom: 18 })
    Row({ space: 8 }) {
      TextInput({ text: this.searchText, placeholder: this.live() ? '搜索频道' : '搜索来源中的文件' })
        .fontSize(14).fontColor(this.P().text).backgroundColor(this.P().card).borderRadius(12).height(42).layoutWeight(1)
        .onChange((value: string) => { this.searchText = value; })
        .onSubmit(() => { if (this.controller !== null) { this.controller.search(this.searchText); } })
      Button('搜索').fontSize(13).height(42).backgroundColor(this.P().accent).fontColor(Color.White)
        .onClick(() => { if (this.controller !== null) { this.controller.search(this.searchText); } })
    }.width('100%')
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.frame.views, (view: Library) => {
          Button(view.name).fontSize(12).height(34)
            .backgroundColor(this.frame.trail.length > 0 && this.frame.trail[0].id === view.id ? this.P().accent : this.P().card)
            .fontColor(this.frame.trail.length > 0 && this.frame.trail[0].id === view.id ? Color.White : this.P().text)
            .onClick(() => { if (this.controller !== null) { this.controller.selectRoot(view); } })
        }, (view: Library) => view.id)
      }.padding({ top: 12, bottom: 12 })
    }.width('100%').height(58).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.TopStart)
    Row({ space: 10 }) {
      Text('已加载排序').fontSize(10).fontColor(this.P().textDim)
      Button(this.frame.sort === 'name-desc' ? '名称 ↓' : '名称 ↑').height(30).fontSize(11).backgroundColor(this.P().card).fontColor(this.P().text)
        .onClick(() => { if (this.controller !== null) { this.controller.setSort(this.frame.sort === 'name' ? 'name-desc' : 'name'); } })
      Button('文件时间 ↓').height(30).fontSize(11).backgroundColor(this.P().card).fontColor(this.frame.sort === 'time' ? this.P().accent : this.P().textDim)
        .onClick(() => { if (this.controller !== null) { this.controller.setSort('time'); } })
      Blank()
      Button(this.frame.grid ? '列表' : '网格').height(30).fontSize(11).backgroundColor(this.P().card).fontColor(this.P().accent)
        .onClick(() => { if (this.controller !== null) { this.controller.setGrid(!this.frame.grid); } })
    }.width('100%').padding({ bottom: 12 })
    if (this.frame.query.length > 0) {
      Row() { Text('搜索：' + this.frame.query).fontSize(12).fontColor(this.P().textDim).layoutWeight(1)
        Button('返回目录').height(28).fontSize(11).onClick(() => { if (this.controller !== null) { this.controller.back(this.frame.trail.length - 1); } }) }.width('100%')
    } else {
      Scroll() { Row({ space: 4 }) {
        ForEach(this.frame.trail, (crumb: SourceCrumb, index: number) => {
          Button((index > 0 ? '› ' : '') + crumb.name).fontSize(12).height(32).backgroundColor(Color.Transparent).fontColor(this.P().accent)
            .onClick(() => { if (this.controller !== null) { this.controller.back(index); } })
        }, (crumb: SourceCrumb) => crumb.id)
      } }.width('100%').height(36).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.TopStart)
    }
  }
  build() {
    Column() {
      if (this.active) {
        if (this.current()) { this.header() }
        if (!this.current()) { LoadingProgress().width(32).height(32).margin(24) }
        else {
          if (this.frame.error.length > 0) {
            Column({ space: 8 }) { Text(this.frame.error).fontColor(this.P().text).fontSize(13)
              Button('重试').height(34).fontSize(12).onClick(() => { if (this.controller !== null) { this.controller.retry(); } }) }.padding(14).width('100%').backgroundColor(this.P().card).borderRadius(12)
          }
          if (this.frame.notice.length > 0) { Text(this.frame.notice).fontColor(this.P().textDim).fontSize(11).width('100%').padding({ top: 8, bottom: 8 }) }
          if (this.frame.epgChannel.length > 0) {
            Column({ space: 7 }) {
              Row() { Text(this.frame.epgName + ' · 节目单').fontSize(14).fontColor(this.P().text).layoutWeight(1)
                Button('收起').height(28).fontSize(11).onClick(() => { if (this.controller !== null) { this.controller.closeEpg(); } }) }.width('100%')
              if (this.frame.epgBusy) { Text('读取真实节目单…').fontSize(12).fontColor(this.P().textDim) }
              else if (this.frame.epgError.length > 0) { Text(this.frame.epgError).fontSize(12).fontColor(this.P().textDim) }
              else { Text('当前：' + this.nowText()).fontSize(12).fontColor(this.P().text)
                Text('接下来：' + this.nextText()).fontSize(12).fontColor(this.P().textDim) }
            }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(12).alignItems(HorizontalAlign.Start).margin({ top: 8, bottom: 8 })
          }
          if (!this.frame.busy && this.frame.items.length === 0 && this.frame.error.length === 0) {
            Column({ space: 12 }) { SymbolGlyph($r('sys.symbol.folder')).fontSize(38).fontColor([this.P().textDim])
              Text(this.frame.query.length > 0 ? '没有匹配的真实条目' : '此目录暂无条目').fontSize(14).fontColor(this.P().textDim) }.layoutWeight(1).justifyContent(FlexAlign.Center)
          } else if (this.frame.grid) {
            Grid() { ForEach(this.frame.items, (item: MediaItem) => { GridItem() { this.gridCard(item) } }, (item: MediaItem) => item.id) }
              .columnsTemplate(Metrics.width() >= 600 ? '1fr 1fr 1fr 1fr' : '1fr 1fr').columnsGap(14).rowsGap(18).layoutWeight(1)
              .onReachEnd(() => { if (this.controller !== null) { this.controller.loadMore(); } })
          } else {
            List() { ForEach(this.frame.items, (item: MediaItem) => { ListItem() { this.listRow(item) } }, (item: MediaItem) => item.id) }
              .width('100%').layoutWeight(1).scrollBar(BarState.Off)
              .onReachEnd(() => { if (this.controller !== null) { this.controller.loadMore(); } })
          }
          if (this.frame.busy) { LoadingProgress().width(26).height(26).margin(10) }
          if (this.frame.more && !this.frame.busy) { Button('加载更多').height(34).fontSize(12).onClick(() => { if (this.controller !== null) { this.controller.loadMore(); } }) }
        }
      }
    }.width('100%').height('100%').padding({ left: 20, right: 20, bottom: 96 }).backgroundColor(this.P().bg)
      .onVisibleAreaChange([0.0, 1.0], (visible: boolean) => { if (this.controller !== null) { this.controller.setVisible(visible); } })
  }
}
