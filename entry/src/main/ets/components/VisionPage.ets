import { promptAction } from '@kit.ArkUI';
import { Materials } from '../common/Materials';
import { ServerConfig, MediaItem } from '../common/Models';
import { Palette } from '../common/Theme';
import { Metrics } from '../common/Metrics';
import { VisionController } from '../common/vision/VisionController';
import { VisionState, VisionRow, VisionPlaylist } from '../common/vision/VisionModels';
import { NetImage } from './NetImage';

/** The four observed HosVision sections; the parent keeps ownership of the dock and navigation. */
@Component
export struct VisionPage {
  @Prop @Watch('inputsChanged') servers: ServerConfig[] = [];
  @Prop @Watch('inputsChanged') active: boolean = true;
  @Prop @Watch('inputsChanged') revision: number = 0;
  @Prop initialSection: number = 0;
  @Prop darkMode: boolean = true;
  @Prop safeTopVp: number = 0;
  @Prop bottomInsetVp: number = 100;
  onPlay: (server: ServerConfig, item: MediaItem) => Promise<void> = async () => {};
  onOpenDetail: (server: ServerConfig, item: MediaItem) => Promise<void> = async () => {};
  onBrowse: () => void = () => {};
  @StorageProp('screenWidthVp') private widthVp: number = 440;
  @State private frame: VisionState = new VisionState();
  @State private dialog: string = '';
  @State private nameInput: string = '';
  @State private dialogBusy: boolean = false;
  @State private dialogError: string = '';
  @State private activeRow: VisionRow | null = null;
  @State private activeList: VisionPlaylist | null = null;
  private mounted: boolean = false;
  private actionGeneration: number = 0;
  private resetDialogOnNextFrame: boolean = false;
  private inputScope: string = '';
  private controller: VisionController | null = null;

  aboutToAppear(): void {
    this.mounted = true; this.inputScope = VisionController.scope(this.servers);
    this.controller = new VisionController((frame: VisionState) => { if (this.mounted && this.active) {
      if (this.resetDialogOnNextFrame) { this.resetDialogOnNextFrame = false; this.dialog = ''; this.dialogBusy = false; this.dialogError = ''; }
      this.frame = frame;
    } });
    this.controller.configure(this.servers, this.active, this.revision, this.initialSection);
  }
  aboutToDisappear(): void { this.mounted = false; this.actionGeneration++; this.resetDialogOnNextFrame = true; if (this.controller !== null) { this.controller.destroy(); this.controller = null; } }
  private inputsChanged(): void {
    const scope = VisionController.scope(this.servers);
    if (!this.active || scope !== this.inputScope) { this.actionGeneration++; this.resetDialogOnNextFrame = true; }
    this.inputScope = scope;
    if (this.mounted && this.controller !== null) { this.controller.configure(this.servers, this.active, this.revision, this.initialSection); }
  }
  private current(): boolean { return this.active && this.frame.scope === VisionController.scope(this.servers); }
  private P(): Palette { return this.darkMode ? Palette.dark() : Palette.light(); }
  private u(value: number): number { return value * Math.min(560, Math.max(320, this.widthVp)) / 720; }
  private pageBackground(): string { return this.darkMode ? (this.frame.section === 0 ? '#000000' : '#161518') : this.P().bg; }
  private rows(): VisionRow[] {
    if (!this.current()) { return []; }
    if (this.frame.section === 0) { return this.frame.watchLater; }
    if (this.frame.section === 2) { return this.frame.watching; }
    return this.controller !== null ? this.controller.playlistRows() : [];
  }
  private time(value: number): string {
    const seconds = Math.max(0, Math.floor(value / 1000)); const minutes = Math.floor(seconds / 60);
    return minutes >= 60 ? Math.floor(minutes / 60).toString() + ':' + (minutes % 60).toString().padStart(2, '0') + ':' + (seconds % 60).toString().padStart(2, '0')
      : minutes.toString().padStart(2, '0') + ':' + (seconds % 60).toString().padStart(2, '0');
  }
  private episode(row: VisionRow): string {
    if (row.item.type !== 'Episode') { return ''; }
    const season = row.item.parentIndexNumberKnown ? 'S' + row.item.parentIndexNumber.toString().padStart(2, '0') : '';
    const episode = row.item.indexNumberKnown ? 'E' + row.item.indexNumber.toString().padStart(2, '0') : '';
    return season + episode + (row.item.name !== row.title ? '  ' + row.item.name : '');
  }
  private async open(row: VisionRow, detail: boolean): Promise<void> {
    if (!this.current() || this.controller === null) { return; }
    const controller = this.controller; const scope = this.frame.scope; const section = this.frame.section;
    try {
      if (!await controller.canOpen(row)) { throw new Error('来源已锁定或不可用，请到服务器页检查'); }
      if (!this.current() || this.controller !== controller || this.frame.scope !== scope || this.frame.section !== section) { return; }
      if (detail || !row.item.isPlayable()) { await this.onOpenDetail(row.server, row.item); } else { await this.onPlay(row.server, row.item); }
    } catch (e) { promptAction.showToast({ message: (e as Error).message }); }
  }
  private selectSection(index: number): void {
    if (!this.mounted || !this.active || this.controller === null || index < 0 || index > 3) { return; }
    this.closeDialog(); this.controller.selectSection(index);
  }
  private closeDialog(force: boolean = false): void {
    if (this.dialogBusy && !force) { return; }
    this.actionGeneration++; this.dialog = ''; this.dialogBusy = false; this.dialogError = '';
    this.activeRow = null; this.activeList = null;
  }
  private browse(): void { if (this.active && this.mounted) { this.closeDialog(); this.onBrowse(); } }
  private sheetVisible(): boolean { return this.current() && !this.resetDialogOnNextFrame && this.dialog.length > 0; }
  private sheetTitle(): string {
    if (this.dialog === 'create') { return '创建播放列表'; } if (this.dialog === 'rename') { return '重命名播放列表'; }
    if (this.dialog === 'filter') { return '来源筛选'; } if (this.dialog === 'add') { return '添加到播放列表'; }
    if (this.dialog === 'delete-playlist') { return '删除播放列表'; }
    if (this.dialog === 'playlist') { return this.activeList !== null ? this.activeList.name : '播放列表'; }
    return this.activeRow !== null ? this.activeRow.title : '影片操作';
  }
  private sheetHeight(): number {
    const available = Metrics.height() > 0 ? Metrics.height() : 900;
    let rows = 5;
    if (this.dialog === 'create' || this.dialog === 'rename') { return Math.min(340, available * 0.72); }
    if (this.dialog === 'filter') { rows = this.controller !== null ? this.controller.sources().length + 1 : 1; }
    if (this.dialog === 'add') { rows = this.frame.playlists.length + 1; }
    if (this.dialog === 'playlist' || this.dialog === 'delete-playlist') { rows = 2; }
    return Math.max(220, Math.min(available * 0.72, 94 + rows * 48));
  }
  private openDialog(mode: string, row: VisionRow | null = null, list: VisionPlaylist | null = null): void {
    if (!this.current() || this.dialogBusy) { return; } this.activeRow = row; this.activeList = list; this.dialog = mode;
    this.nameInput = mode === 'rename' && list !== null ? list.name : ''; this.dialogError = '';
  }
  private async saveName(): Promise<void> {
    if (this.controller === null || this.dialogBusy) { return; } this.dialogBusy = true; this.dialogError = '';
    const controller = this.controller; const generation = ++this.actionGeneration; const row = this.activeRow;
    try {
      if (this.dialog === 'rename' && this.activeList !== null) { await controller.renamePlaylist(this.activeList.id, this.nameInput); }
      else {
        const id = await controller.createPlaylist(this.nameInput);
        if (!this.mounted || !this.active || generation !== this.actionGeneration) { return; }
        if (row !== null) { await controller.addToPlaylist(id, row); }
        if (!this.mounted || !this.active || generation !== this.actionGeneration) { return; }
        controller.selectSection(3); controller.openPlaylist(id);
      }
      if (this.mounted && generation === this.actionGeneration) { this.dialog = ''; }
    } catch (e) { if (this.mounted && generation === this.actionGeneration) { this.dialogError = (e as Error).message; } }
    finally { if (this.mounted && generation === this.actionGeneration) { this.dialogBusy = false; } }
  }
  private async action(work: () => Promise<void>): Promise<void> {
    if (this.dialogBusy) { return; } this.dialogBusy = true;
    const generation = ++this.actionGeneration;
    try { await work(); if (this.mounted && generation === this.actionGeneration) { this.dialog = ''; } }
    catch (e) { if (this.mounted && generation === this.actionGeneration) { this.dialogError = (e as Error).message; } }
    finally { if (this.mounted && generation === this.actionGeneration) { this.dialogBusy = false; } }
  }
  private weekday(): string { return ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][new Date().getDay()]; }
  private date(): string { const now = new Date(); return (now.getMonth() + 1).toString().padStart(2, '0') + '/' + now.getDate().toString().padStart(2, '0'); }
  private filterPath(): string { return 'M ' + this.u(2) + ' ' + this.u(2) + ' L ' + this.u(30) + ' ' + this.u(2) + ' L ' + this.u(19) + ' ' + this.u(15) + ' L ' + this.u(19) + ' ' + this.u(29) + ' L ' + this.u(12) + ' ' + this.u(25) + ' L ' + this.u(12) + ' ' + this.u(15) + ' Z'; }
  @Builder private iconButton(icon: Resource, click: () => void) {
    Button({ type: ButtonType.Circle }) { SymbolGlyph(icon).fontSize(this.u(37)).fontColor([this.P().text]).fontWeight(FontWeight.Lighter) }
      .width(this.u(64)).height(this.u(64)).backgroundColor(this.darkMode ? '#202023' : this.P().chip)
      .border({ width: this.u(1), color: this.darkMode ? '#47474B' : this.P().divider }).onClick(click)
  }
  @Builder private filterButton() {
    Button({ type: ButtonType.Circle }) {
      Path().commands(this.filterPath()).width(this.u(34)).height(this.u(34))
        .fill('#00000000').stroke(this.P().text).strokeWidth(this.u(1.6))
    }.width(this.u(64)).height(this.u(64)).backgroundColor(this.darkMode ? '#202023' : this.P().chip)
      .border({ width: this.u(1), color: this.darkMode ? '#47474B' : this.P().divider }).onClick(() => { this.openDialog('filter'); })
  }
  @Builder private header() {
    Row({ space: this.u(12) }) {
      Column({ space: 2 }) {
        Text('HosVision').fontSize(this.u(32)).fontWeight(FontWeight.Bold).fontColor(this.P().text)
        Text(this.servers.length === 1 ? this.servers[0].name : '选择服务器后查看')
          .fontSize(12).fontColor(this.P().textDim).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Blank()
      if (this.frame.section === 2 && this.servers.length > 1) { this.filterButton() }
      if (this.frame.section === 3) { this.iconButton($r('sys.symbol.plus'), () => { this.openDialog('create'); }) }
      else { this.iconButton($r('sys.symbol.arrow_clockwise'), () => { if (this.controller !== null) { this.controller.refresh(); } }) }
    }.height(this.u(64)).width('100%').padding({ left: this.u(24), right: this.u(24) }).margin({ top: this.safeTopVp + this.u(14) })
    Row() {
      ForEach(['待看', '日历', '在看', '播放列表'], (label: string, index: number) => {
        Button({ type: ButtonType.Capsule }) {
          Text(label).fontSize(Math.max(12, this.u(18))).fontColor(this.frame.section === index ? this.P().text : this.P().textDim)
            .maxLines(1).textAlign(TextAlign.Center)
        }.layoutWeight(1).height(44).borderRadius(22)
          .backgroundColor(this.frame.section === index ? (this.darkMode ? '#353538' : '#FFFFFF') : Color.Transparent)
          .accessibilityText(label).enabled(this.active)
          .onClick(() => { this.selectSection(index); })
      })
    }.padding(3).height(50).width('calc(100% - ' + this.u(48).toString() + 'vp)').borderRadius(this.u(32))
      .backgroundColor(this.darkMode ? '#212124' : '#E8E8ED').border({ width: this.u(1), color: this.darkMode ? '#47474B' : this.P().divider })
      .margin({ top: this.u(24), left: this.u(24), right: this.u(24) })
  }
  @Builder private empty() {
    Column() {
      SymbolGlyph(this.frame.section === 3 ? $r('sys.symbol.folder') : $r('sys.symbol.bookmark')).fontSize(this.u(60)).fontColor([this.P().textFaint]).fontWeight(FontWeight.Lighter)
      Text(this.frame.section === 3 ? (this.frame.selectedPlaylistId.length > 0 ? '播放列表里还没有内容' : '还没有播放列表') : this.frame.section === 2 ? '还没有在看的内容' : '待看里还没有内容')
        .fontSize(this.u(20)).fontColor(this.P().text).margin({ top: this.u(24) })
      if (this.frame.section === 0) {
        Text('在电影或剧集详情页点击右上角待看按钮即可加入。').fontSize(Math.max(12, this.u(14))).fontColor(this.P().textDim).margin({ top: this.u(24) })
        Button(this.servers.length > 0 ? '浏览影片并加入待看' : '添加服务器').height(44).fontSize(14).fontColor('#FFFFFF').backgroundColor(this.P().accent)
          .margin({ top: 20 }).onClick(() => { this.browse(); })
      } else if (this.frame.section === 3 && this.frame.selectedPlaylistId.length === 0) {
        Button('创建第一个播放列表').fontSize(this.u(20)).height(this.u(64)).padding({ left: this.u(24), right: this.u(24) })
          .fontColor('#FFFFFF').backgroundColor('#0087FF').borderRadius(this.u(32)).margin({ top: this.u(24) }).onClick(() => { this.openDialog('create'); })
      } else if (this.frame.section === 2) {
        Button(this.servers.length > 0 ? '浏览影片开始观看' : '添加服务器').height(44).fontSize(14).fontColor('#FFFFFF').backgroundColor(this.P().accent)
          .margin({ top: 20 }).onClick(() => { this.browse(); })
      } else if (this.frame.section === 3) {
        Text('从待看或在看条目的菜单添加内容。').fontSize(this.u(14)).fontColor(this.P().textDim).margin({ top: this.u(20) })
      }
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding({ bottom: this.u(96) })
  }
  @Builder private card(row: VisionRow) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.controller !== null && this.controller.imageUrl(row).length > 0) {
          NetImage({ url: this.controller.imageUrl(row), headers: this.controller.imageHeaders(row), targetWidth: 640, darkMode: this.darkMode }).width('100%').height('100%')
        } else { Column().width('100%').height('100%').backgroundColor(this.P().chip) }
        if (this.frame.section === 2 || row.positionMs > 0) {
          Row({ space: this.u(10) }) {
            Text(row.server.name.substring(0, 1)).fontSize(this.u(13)).fontColor('#FFFFFF').textAlign(TextAlign.Center).width(this.u(28)).height(this.u(22)).backgroundColor('#5D463D').borderRadius(this.u(2))
            Stack({ alignContent: Alignment.Start }) {
              Row().width('100%').height(this.u(6)).backgroundColor('#A7A7AB').borderRadius(this.u(3))
              Row().width((row.durationMs > 0 ? Math.min(1, row.positionMs / row.durationMs) * 100 : 0).toString() + '%').height(this.u(6)).backgroundColor('#FFFFFF').borderRadius(this.u(3))
            }.width(this.u(76)).height(this.u(6))
            Text(this.time(row.positionMs)).fontSize(this.u(13)).fontColor('#FFFFFF')
          }.padding({ left: this.u(20), bottom: this.u(14) })
        }
      }.width('100%').aspectRatio(16 / 9).borderRadius(this.u(14)).clip(true)
        .onClick(() => { this.open(row, this.frame.section === 0); })
      Row({ space: this.u(7) }) {
        Row({ space: this.u(6) }) {
          Text(row.title).fontSize(this.u(14)).fontColor(this.P().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          if (this.episode(row).length > 0) { Text(this.episode(row)).fontSize(this.u(11)).fontColor(this.P().textDim).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(2) }
        }.layoutWeight(1).constraintSize({ minHeight: 40 }).onClick(() => { this.open(row, this.frame.section === 0); })
        Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(19).fontColor([this.P().textDim]) }
          .width(40).height(40).backgroundColor(Color.Transparent).accessibilityText('影片操作')
          .onClick(() => { this.openDialog('item', row); })
      }.width('100%').margin({ top: this.u(3) })
      Text(row.server.name).fontSize(this.u(13)).fontColor(this.P().textFaint).width('100%').margin({ top: this.u(2) })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private grid() {
    Grid() { ForEach(this.rows(), (row: VisionRow) => { GridItem() { this.card(row) } }, (row: VisionRow) => row.key) }
      .columnsTemplate(this.widthVp >= 700 ? '1fr 1fr 1fr' : '1fr 1fr').columnsGap(this.u(18)).rowsGap(this.u(20))
      .padding({ left: this.u(24), right: this.u(24), top: this.u(16), bottom: this.u(20) }).layoutWeight(1).width('100%')
  }
  @Builder private calendar() {
    Row({ space: this.u(16) }) {
      Column({ space: this.u(10) }) {
        Text(this.weekday()).fontSize(this.u(21)).fontWeight(FontWeight.Bold).fontColor(this.P().text)
        Text(this.date()).fontSize(this.u(14)).fontColor(this.P().textDim)
        Text('今天').fontSize(this.u(14)).fontColor(this.P().textDim)
      }.width('46%').alignItems(HorizontalAlign.Start)
      Column({ space: this.u(14) }) {
        if (this.frame.calendarBusy) { LoadingProgress().width(this.u(30)).height(this.u(30)) }
        else if (this.frame.calendarError.length > 0) { Text(this.frame.calendarError).fontSize(this.u(16)).fontColor(this.P().textDim) }
        else if (this.frame.calendar.length === 0) { Text(this.frame.calendarUnknown ? '更新日期暂不可用' : '今日无剧集更新').fontSize(this.u(17)).fontColor(this.P().textDim) }
        else { ForEach(this.frame.calendar, (row: VisionRow) => { Text(row.title + ' ' + this.episode(row)).fontSize(this.u(17)).fontColor(this.P().text).onClick(() => { this.open(row, true); }) }, (row: VisionRow) => row.key) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top).padding({ left: this.u(24), right: this.u(24), top: this.u(18) })
    Blank()
  }
  @Builder private playlists() {
    List({ space: this.u(12) }) {
      ForEach(this.frame.playlists, (list: VisionPlaylist) => {
        ListItem() {
          Row({ space: this.u(18) }) {
            SymbolGlyph($r('sys.symbol.folder_fill')).fontSize(this.u(40)).fontColor([this.P().textDim])
            Column({ space: this.u(6) }) { Text(list.name).fontSize(this.u(20)).fontColor(this.P().text); Text(list.entries.length.toString() + ' 项').fontSize(this.u(14)).fontColor(this.P().textDim) }.alignItems(HorizontalAlign.Start).layoutWeight(1).constraintSize({ minHeight: 44 })
              .onClick(() => { if (this.controller !== null) { this.controller.openPlaylist(list.id); } })
            Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([this.P().textDim]) }.width(44).height(44).backgroundColor(Color.Transparent)
              .accessibilityText('管理播放列表').onClick(() => { this.openDialog('playlist', null, list); })
          }.width('100%').padding(this.u(20)).backgroundColor(this.P().chip).borderRadius(this.u(16))
        }
      }, (list: VisionPlaylist) => list.id)
    }.padding({ left: this.u(24), right: this.u(24), top: this.u(20) }).width('100%').layoutWeight(1)
  }
  @Builder private dialogAction(label: string, click: () => void) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(15).fontColor(this.P().text).width('100%').textAlign(TextAlign.Start)
    }.width('100%').height(48).padding({ left: 12, right: 12 }).backgroundColor(Color.Transparent)
      .borderRadius(12).enabled(!this.dialogBusy).onClick(click)
  }
  @Builder private sheetContent() {
    Column() {
      Row({ space: 12 }) {
        Text(this.sheetTitle()).fontSize(19).fontWeight(FontWeight.Medium).fontColor(this.P().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.P().textDim]) }
          .width(44).height(44).backgroundColor(Color.Transparent).enabled(!this.dialogBusy)
          .accessibilityText('关闭').onClick(() => { this.closeDialog(); })
      }.width('100%').padding({ left: 20, right: 12, top: 8, bottom: 8 })
      Scroll() {
        Column({ space: 6 }) {
          if (this.dialog === 'create' || this.dialog === 'rename') {
            TextInput({ text: $$this.nameInput, placeholder: '播放列表名称' }).height(48).fontSize(16)
              .fontColor(this.P().text).maxLength(80).enabled(!this.dialogBusy)
            Row({ space: 12 }) {
              Button('取消').height(44).layoutWeight(1).fontColor(this.P().textDim).backgroundColor(Color.Transparent)
                .enabled(!this.dialogBusy).onClick(() => { this.closeDialog(); })
              Button('保存').height(44).layoutWeight(1).fontColor('#FFFFFF').backgroundColor(this.P().accent)
                .enabled(!this.dialogBusy && this.nameInput.trim().length > 0).onClick(() => { this.saveName(); })
            }.width('100%').margin({ top: 16 })
          } else if (this.dialog === 'filter') {
            this.dialogAction('全部来源', () => { if (this.controller !== null) { this.controller.filter(''); } this.closeDialog(); })
            if (this.controller !== null) { ForEach(this.controller.sources(), (server: ServerConfig) => {
              this.dialogAction(server.name, () => { if (this.controller !== null) { this.controller.filter(server.id); } this.closeDialog(); })
            }, (server: ServerConfig) => server.id) }
          } else if (this.dialog === 'add') {
            ForEach(this.frame.playlists, (list: VisionPlaylist) => {
              this.dialogAction(list.name, () => { const row = this.activeRow; if (this.controller !== null && row !== null) {
                this.action(() => (this.controller as VisionController).addToPlaylist(list.id, row));
              } })
            }, (list: VisionPlaylist) => list.id)
            this.dialogAction('创建播放列表', () => { this.dialog = 'create'; this.nameInput = ''; })
          } else if (this.dialog === 'playlist' && this.activeList !== null) {
            this.dialogAction('重命名', () => { this.openDialog('rename', null, this.activeList); })
            this.dialogAction('删除播放列表', () => { this.dialog = 'delete-playlist'; })
          } else if (this.dialog === 'delete-playlist' && this.activeList !== null) {
            Text('删除此播放列表？影片和服务器文件会保留。').fontSize(15).fontColor(this.P().textDim).width('100%').padding(12)
            this.dialogAction('确认删除', () => { const list = this.activeList; if (this.controller !== null && list !== null) {
              this.action(() => (this.controller as VisionController).deletePlaylist(list.id));
            } })
          } else if (this.activeRow !== null) {
            this.dialogAction(this.activeRow.positionMs > 0 ? '继续播放' : '播放', () => {
              const row = this.activeRow; this.closeDialog(); if (row !== null) { this.open(row, false); }
            })
            this.dialogAction('查看详情', () => { const row = this.activeRow; this.closeDialog(); if (row !== null) { this.open(row, true); } })
            this.dialogAction(this.frame.section === 0 ? '移出待看' : '加入或移出待看', () => { const row = this.activeRow;
              if (this.controller !== null && row !== null) { this.action(() => (this.controller as VisionController).toggleWatch(row)); }
            })
            this.dialogAction('添加到播放列表', () => { this.dialog = 'add'; })
            if (this.frame.section === 3 && this.frame.selectedPlaylistId.length > 0) {
              this.dialogAction('从播放列表移除', () => { const row = this.activeRow; if (this.controller !== null && row !== null) {
                this.action(() => (this.controller as VisionController).removeFromPlaylist(this.frame.selectedPlaylistId, row));
              } })
            }
          }
          if (this.dialogBusy) { LoadingProgress().width(28).height(28) }
          if (this.dialogError.length > 0) { Text(this.dialogError).fontSize(14).fontColor('#F48F8F').padding(12).width('100%') }
        }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%')
  }

  build() {
    Stack() {
      Column() {
        this.header()
        if (this.current() && this.frame.errors.length > 0) {
          Row({ space: this.u(12) }) { Text(this.frame.errors.join('\n')).fontSize(this.u(14)).fontColor('#D99A84').maxLines(3).layoutWeight(1); Text('重试').fontSize(this.u(17)).fontColor('#0087FF').onClick(() => { if (this.controller !== null) { this.controller.refresh(); } }) }.padding({ left: this.u(24), right: this.u(24), top: this.u(12) })
        }
        if (!this.current()) { Column() { LoadingProgress().width(this.u(36)).height(this.u(36)) }.layoutWeight(1).justifyContent(FlexAlign.Center) }
        else if (this.frame.section === 1) { this.calendar() }
        else if (this.frame.section === 3 && this.frame.selectedPlaylistId.length === 0 && this.frame.playlists.length > 0) { this.playlists() }
        else {
          if (this.frame.section === 3 && this.frame.selectedPlaylistId.length > 0) { Row() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(this.u(22)).fontColor([this.P().text]); Text('播放列表').fontSize(this.u(18)).fontColor(this.P().text) }.padding(this.u(18)).onClick(() => { if (this.controller !== null) { this.controller.openPlaylist(''); } }) }
          if (this.rows().length > 0) { this.grid() }
          else if (this.frame.busy && this.current()) { Column() { LoadingProgress().width(this.u(36)).height(this.u(36)) }.layoutWeight(1).justifyContent(FlexAlign.Center) }
          else { this.empty() }
        }
        Column().height(this.bottomInsetVp).width('100%')
      }.width('100%').height('100%')
    }.width('100%').height('100%').backgroundColor(this.pageBackground())
      .bindSheet(this.sheetVisible(), this.sheetContent(), {
        height: this.sheetHeight(), preferType: SheetType.CENTER, dragBar: false, showClose: false,
        backgroundColor: Color.Transparent, systemMaterial: Materials.popupMaterial(this.darkMode, this.P().accent),
        onWillDismiss: (action: DismissSheetAction) => { if (!this.dialogBusy) { this.closeDialog(); action.dismiss(); } },
        onDisappear: () => { if (!this.sheetVisible()) { this.closeDialog(true); } }
      })
  }
}
