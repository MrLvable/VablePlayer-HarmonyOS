import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AiRuntimeEndpoint, AiSubtitleCue, AiSubtitleError } from '../common/ai/AiSubtitleModels';
import { AiSubtitleConfigStore } from '../common/ai/AiSubtitleConfigStore';
import { OpenAiSubtitleClient } from '../common/ai/OpenAiSubtitleClient';
import { SubtitleFileCodec } from '../common/ai/SubtitleFileCodec';
import { Palette, Theme, pal } from '../common/Theme';
import { window, display } from '@kit.ArkUI';

export interface AiFileTaskProgress {
  state: string;
  completed: number;
  total: number;
  message: string;
  preview: string;
}

/** File-only translation task. Completed batches remain available after pause/cancel/failure. */
export class AiSubtitleFileTask {
  onProgress: (progress: AiFileTaskProgress) => void = () => {};
  private source: AiSubtitleCue[];
  private translated: Map<string, string> = new Map();
  private revision: number = 0;
  private client: OpenAiSubtitleClient | null = null;
  private running: boolean = false;
  private language: string = '';
  private characters: number = 0;

  constructor(cues: AiSubtitleCue[]) {
    this.source = cues.map((cue: AiSubtitleCue): AiSubtitleCue => ({ id: cue.id, startMs: cue.startMs, endMs: cue.endMs, text: cue.text }));
  }

  private progress(state: string, message: string, preview: string = ''): void {
    this.onProgress({ state: state, completed: this.translated.size, total: this.source.length,
      message: message, preview: preview });
  }

  pause(): void {
    this.revision++; this.running = false;
    if (this.client !== null) { this.client.cancel(); this.client = null; }
    this.progress('paused', '已暂停，可继续未完成的字幕');
  }

  cancel(): void {
    this.revision++; this.running = false;
    if (this.client !== null) { this.client.cancel(); this.client = null; }
    this.progress('cancelled', '本次请求已取消，已译条目仍可导出或继续');
  }

  async run(endpoint: AiRuntimeEndpoint, targetLanguage: string, glossary: string = ''): Promise<void> {
    if (this.running) { return; }
    const language = targetLanguage.trim();
    if (this.language.length > 0 && language !== this.language && this.translated.size > 0) {
      this.progress('failed', '目标语言已改变，请重新选择字幕文件后开始'); return;
    }
    this.language = language;
    const gen = ++this.revision;
    this.running = true;
    let previous = '';
    try {
      const client = new OpenAiSubtitleClient(endpoint); this.client = client;
      this.progress('running', '正在翻译字幕…');
      for (let i = 0; i < this.source.length;) {
        if (gen !== this.revision) { return; }
        if (this.translated.has(this.source[i].id)) {
          previous = (previous + '\n' + this.source[i].text + ' → ' + (this.translated.get(this.source[i].id) as string)).slice(-3500);
          i++; continue;
        }
        const batch: AiSubtitleCue[] = [];
        let characters = 0;
        while (i < this.source.length && batch.length < 15) {
          const cue = this.source[i];
          if (this.translated.has(cue.id)) { break; }
          if (batch.length > 0 && characters + cue.text.length > 6000) { break; }
          batch.push(cue); characters += cue.text.length; i++;
        }
        const result = await client.translateBatch(batch, language, { previousText: previous, glossary: glossary });
        if (gen !== this.revision) { return; }
        if (result.length !== batch.length) { throw new AiSubtitleError('response', '翻译结果不完整，已保留之前进度'); }
        let addedCharacters = 0;
        for (let n = 0; n < batch.length; n++) {
          if (result[n].id !== batch[n].id || result[n].startMs !== batch[n].startMs || result[n].endMs !== batch[n].endMs) {
            throw new AiSubtitleError('response', '翻译结果改变了字幕时间轴，未应用该批次');
          }
          addedCharacters += result[n].text.length;
        }
        if (this.characters + addedCharacters > 4 * 1024 * 1024) {
          throw new AiSubtitleError('size', '翻译结果过大，请拆分字幕文件；已完成部分可导出');
        }
        for (let n = 0; n < batch.length; n++) {
          this.translated.set(batch[n].id, result[n].text);
          previous = (previous + '\n' + batch[n].text + ' → ' + result[n].text).slice(-3500);
        }
        this.characters += addedCharacters;
        this.progress(this.translated.size === this.source.length ? 'complete' : 'running',
          this.translated.size === this.source.length ? '全部字幕翻译完成' : '正在翻译字幕…', result[result.length - 1].text.slice(0, 600));
      }
    } catch (e) {
      if (gen === this.revision) {
        this.progress('failed', e instanceof AiSubtitleError ? e.message : '翻译未完成，已保留完成进度，可重试');
      }
    } finally {
      if (gen === this.revision) { this.running = false; this.client = null; }
    }
  }

  cues(bilingual: boolean = false): AiSubtitleCue[] {
    const result: AiSubtitleCue[] = [];
    for (let i = 0; i < this.source.length; i++) {
      const cue = this.source[i];
      if (!this.translated.has(cue.id)) { continue; }
      const text = this.translated.get(cue.id) as string;
      result.push({ id: cue.id, startMs: cue.startMs, endMs: cue.endMs,
        text: bilingual ? text + '\n' + cue.text : text });
    }
    return result;
  }
}

/** Imports user-authorized text subtitle files only; this page does not perform audio recognition. */
@Component
export struct AiSubtitleWorkbench {
  onClose: () => void = () => {};
  onConfigure: () => void = () => {};
  onApply: ((cues: AiSubtitleCue[]) => void) | null = null;
  @Prop dark: boolean = Theme.isDark();
  @Prop fullScreenOverlay: boolean = false;
  @State private safeTop: number = 0;
  @State private safeBottom: number = 0;
  @State private safeLeft: number = 0;
  @State private safeRight: number = 0;
  @State private fileName: string = '未选择字幕文件';
  @State private targetLanguage: string = '';
  @State private glossary: string = '';
  @State private total: number = 0;
  @State private completed: number = 0;
  @State private state: string = 'idle';
  @State private message: string = '选择带时间轴的 SRT、VTT 或 ASS 文件';
  @State private preview: string = '';
  @State private busy: boolean = false;
  @State private bilingual: boolean = true;
  private mounted: boolean = false;
  private revision: number = 0;
  private task: AiSubtitleFileTask | null = null;
  private safeWindow: window.Window | null = null;
  private avoidAreaChanged: (event: window.AvoidAreaOptions) => void = (_event: window.AvoidAreaOptions) => {
    this.readSafeInsets();
  };

  private P(): Palette { return pal(this.dark); }

  aboutToAppear(): void { this.mounted = true; this.connectSafeArea(); this.loadLanguage(); }

  aboutToDisappear(): void {
    this.mounted = false; this.revision++;
    const win = this.safeWindow; this.safeWindow = null;
    if (win !== null) { try { win.off('avoidAreaChange', this.avoidAreaChanged); } catch (e) {} }
    if (this.task !== null) { this.task.onProgress = () => {}; this.task.cancel(); this.task = null; }
  }

  private async connectSafeArea(): Promise<void> {
    if (!this.fullScreenOverlay) { return; }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(context);
      if (!this.mounted) { return; }
      this.safeWindow = win;
      this.readSafeInsets();
      win.on('avoidAreaChange', this.avoidAreaChanged);
    } catch (e) {}
  }

  private readSafeInsets(): void {
    const win = this.safeWindow;
    if (!this.mounted || !this.fullScreenOverlay || win === null) { return; }
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      if (!Number.isFinite(density) || density <= 0) { return; }
      let top = 0; let bottom = 0; let left = 0; let right = 0;
      const types: window.AvoidAreaType[] = [window.AvoidAreaType.TYPE_SYSTEM,
        window.AvoidAreaType.TYPE_CUTOUT, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR];
      for (let i = 0; i < types.length; i++) {
        try {
          const area = win.getWindowAvoidArea(types[i]);
          top = Math.max(top, area.topRect.height); bottom = Math.max(bottom, area.bottomRect.height);
          left = Math.max(left, area.leftRect.width); right = Math.max(right, area.rightRect.width);
        } catch (e) {}
      }
      this.safeTop = top / density; this.safeBottom = bottom / density;
      this.safeLeft = left / density; this.safeRight = right / density;
    } catch (e) {}
  }

  private async loadLanguage(): Promise<void> {
    const gen = this.revision;
    try {
      const config = await AiSubtitleConfigStore.load();
      if (this.mounted && gen === this.revision) { this.targetLanguage = config.targetLanguage; }
    } catch (e) { if (this.mounted && gen === this.revision) { this.message = '请先完成 AI 字幕配置'; } }
  }

  private error(error: Error, fallback: string): string {
    return error instanceof AiSubtitleError ? error.message : fallback;
  }

  private name(uri: string): string {
    const piece = uri.substring(uri.lastIndexOf('/') + 1).replace(/[?#].*$/, '');
    try { return decodeURIComponent(piece).slice(0, 160) || '字幕文件'; }
    catch (e) { return '字幕文件'; }
  }

  private async read(uri: string): Promise<string> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = await fileIo.stat(file.fd);
      if (!Number.isFinite(stat.size) || stat.size <= 0 || stat.size > 2 * 1024 * 1024) {
        throw new AiSubtitleError('file-size', '请选择不超过 2MB 的非空字幕文件');
      }
      const data = new Uint8Array(stat.size);
      let offset = 0;
      while (offset < stat.size) {
        const part = new ArrayBuffer(Math.min(65536, stat.size - offset));
        const count = await fileIo.read(file.fd, part, { length: part.byteLength });
        if (count <= 0) { break; }
        data.set(new Uint8Array(part, 0, count), offset); offset += count;
      }
      const extra = new ArrayBuffer(1);
      if (await fileIo.read(file.fd, extra, { length: 1 }) > 0 || offset !== stat.size) {
        throw new AiSubtitleError('file-changed', '字幕文件读取期间发生变化，请重新选择');
      }
      let encoding = 'utf-8';
      if (data.length >= 2 && data[0] === 255 && data[1] === 254) { encoding = 'utf-16le'; }
      else if (data.length >= 2 && data[0] === 254 && data[1] === 255) { encoding = 'utf-16be'; }
      try { return new util.TextDecoder(encoding, { fatal: true }).decodeToString(data); }
      catch (e) { throw new AiSubtitleError('encoding', '字幕编码无法读取，请转换为 UTF-8 后再导入'); }
    } finally { await fileIo.close(file).catch(() => {}); }
  }

  private async chooseFile(): Promise<void> {
    if (this.busy || this.state === 'running') { return; }
    this.busy = true;
    const gen = ++this.revision;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const selected = await documentPicker.select({ maxSelectNumber: 1,
        fileSuffixFilters: ['字幕文件|.srt,.vtt,.ass,.ssa'] });
      if (!this.mounted || gen !== this.revision || selected.length === 0) { return; }
      const input = await this.read(selected[0]);
      if (!this.mounted || gen !== this.revision) { return; }
      const name = this.name(selected[0]);
      const cues = SubtitleFileCodec.parse(input, name);
      if (this.task !== null) { this.task.onProgress = () => {}; this.task.cancel(); }
      const task = new AiSubtitleFileTask(cues); this.task = task;
      task.onProgress = (progress: AiFileTaskProgress) => {
        if (!this.mounted || this.task !== task) { return; }
        this.state = progress.state; this.completed = progress.completed; this.total = progress.total;
        this.message = progress.message;
        if (progress.preview.length > 0) { this.preview = progress.preview; }
      };
      this.fileName = name; this.total = cues.length; this.completed = 0; this.preview = '';
      this.state = 'ready'; this.message = '已读取真实时间轴，可以开始翻译';
    } catch (e) {
      if (this.mounted && gen === this.revision) { this.message = this.error(e as Error, '未能读取字幕文件，请重新选择'); }
    } finally { if (this.mounted && gen === this.revision) { this.busy = false; } }
  }

  private async runFileTranslation(): Promise<void> {
    if (this.busy || this.state === 'running' || this.task === null) { return; }
    this.busy = true;
    const gen = ++this.revision;
    const task = this.task;
    try {
      const config = await AiSubtitleConfigStore.load();
      const endpoint = await AiSubtitleConfigStore.translationEndpoint();
      if (!this.mounted || gen !== this.revision || this.task !== task) { return; }
      this.targetLanguage = config.targetLanguage;
      this.busy = false;
      await task.run(endpoint, config.targetLanguage, this.glossary);
    } catch (e) {
      if (this.mounted && gen === this.revision) {
        this.state = 'failed'; this.message = this.error(e as Error, '无法开始翻译，请检查 AI 字幕配置');
      }
    } finally { if (this.mounted && gen === this.revision) { this.busy = false; } }
  }

  private stop(paused: boolean): void {
    this.revision++; this.busy = false;
    if (this.task !== null) { if (paused) { this.task.pause(); } else { this.task.cancel(); } }
  }

  private async exportFile(): Promise<void> {
    if (this.busy || this.state === 'running' || this.task === null || this.completed === 0) { return; }
    this.busy = true;
    const gen = ++this.revision;
    try {
      const cues = this.task.cues(this.bilingual);
      const output = new util.TextEncoder().encodeInto(SubtitleFileCodec.toSrt(cues));
      if (output.byteLength > 16 * 1024 * 1024) { throw new AiSubtitleError('size', '导出结果过大，请减少字幕条数'); }
      const partial = cues.length !== this.total;
      const stem = this.fileName.replace(/\.[^.]*$/, '').replace(/[\\/:*?"<>|]/g, '-').slice(0, 80) || 'subtitles';
      const language = this.targetLanguage.replace(/[\\/:*?"<>|]/g, '-').slice(0, 32) || 'translated';
      const name = stem + '.' + language + (partial ? '.partial-' + cues.length.toString() : '') + '.srt';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const selected = await documentPicker.save({ newFileNames: [name], fileSuffixChoices: ['SRT 字幕|.srt'] });
      if (!this.mounted || gen !== this.revision || selected.length === 0) { return; }
      const file = await fileIo.open(selected[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        let offset = 0;
        while (offset < output.length) {
          const part = output.slice(offset, Math.min(output.length, offset + 65536));
          const count = await fileIo.write(file.fd, part.buffer, { length: part.length });
          if (count <= 0) { throw new AiSubtitleError('file-write', '文件写入未完成，请重新导出'); }
          offset += count;
        }
        await fileIo.fsync(file.fd);
      } finally { await fileIo.close(file).catch(() => {}); }
      if (this.mounted && gen === this.revision) {
        this.message = partial ? '已导出已译部分（' + cues.length.toString() + '/' + this.total.toString() + ' 条）'
          : '完整译文 SRT 已导出';
      }
    } catch (e) {
      if (this.mounted && gen === this.revision) { this.message = this.error(e as Error, '导出失败，请重新选择保存位置'); }
    } finally { if (this.mounted && gen === this.revision) { this.busy = false; } }
  }

  private apply(): void {
    const callback = this.onApply;
    if (callback === null || this.task === null || this.completed === 0 || this.state === 'running') { return; }
    callback(this.task.cues(this.bilingual));
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Button('‹').width(44).height(44).flexShrink(0).fontSize(30).fontColor(this.P().text).backgroundColor(this.P().card)
          .onClick(() => { this.stop(false); this.onClose(); })
        Text('AI 字幕翻译').fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.P().text).layoutWeight(1).maxLines(1)
      }.width('100%').height(64).flexShrink(0).padding({ left: '3.4%', right: '3.4%', top: 10, bottom: 10 })
      Scroll() {
        Column({ space: 14 }) {
          Text('字幕文件').fontSize(13).fontColor(this.P().textDim).width('100%').padding({ left: 14 })
          Column({ space: 12 }) {
            Text(this.fileName).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.P().text).width('100%')
            Text('SRT / VTT / ASS · 不超过 2MB').fontSize(13).fontColor(this.P().textDim).width('100%')
            Button(this.total > 0 ? '重新选择文件' : '选择字幕文件').height(42).fontSize(15)
              .fontColor(this.P().text).backgroundColor(this.P().cardHover).width('100%')
              .enabled(!this.busy && this.state !== 'running').onClick(() => { this.chooseFile(); })
          }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18)
          Column({ space: 12 }) {
            Row() {
              Text('目标语言').fontSize(15).fontColor(this.P().text).layoutWeight(1)
              Text(this.targetLanguage.length > 0 ? this.targetLanguage : '请先配置').fontSize(14).fontColor(this.P().textDim)
              Button('配置').fontSize(13).height(32).margin({ left: 10 }).fontColor(this.P().accent).backgroundColor(this.P().cardHover)
                .enabled(!this.busy && this.state !== 'running').onClick(() => { this.onConfigure(); })
            }.width('100%')
            TextInput({ text: this.glossary, placeholder: '术语或人名译法（可选）' }).height(44).fontSize(14)
              .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
              .enabled(!this.busy && this.state !== 'running').onChange((value: string) => { this.glossary = value.slice(0, 4000); })
            Text('已译 ' + this.completed.toString() + ' / ' + this.total.toString() + ' 条').fontSize(16)
              .fontColor(this.P().text).width('100%')
            Progress({ value: this.completed, total: this.total > 0 ? this.total : 1, type: ProgressType.Linear })
              .width('100%').color(this.P().accent).backgroundColor(this.P().cardHover)
            Text(this.message).fontSize(14).fontColor(this.P().textDim).width('100%').lineHeight(21)
            if (this.state === 'running') {
              Row({ space: 10 }) {
                Button('暂停').layoutWeight(1).height(42).fontColor(this.P().text).backgroundColor(this.P().cardHover)
                  .onClick(() => { this.stop(true); })
                Button('取消请求').layoutWeight(1).height(42).fontColor(this.P().text).backgroundColor(this.P().cardHover)
                  .onClick(() => { this.stop(false); })
              }.width('100%')
            } else {
              Button(this.state === 'complete' ? '翻译完成' : (this.completed > 0 ? '继续翻译未完成部分' : '开始翻译'))
                .height(44).width('100%').fontSize(15).fontColor('#FFFFFF').backgroundColor(this.P().accent)
                .enabled(!this.busy && this.total > 0 && this.state !== 'complete').onClick(() => { this.runFileTranslation(); })
            }
          }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18)
          if (this.preview.length > 0) {
            Column({ space: 8 }) {
              Text('最近完成的译文').fontSize(13).fontColor(this.P().textDim).width('100%')
              Text(this.preview).fontSize(15).fontColor(this.P().text).width('100%').lineHeight(23)
            }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18)
          }
          if (this.completed > 0) {
            Column({ space: 12 }) {
              Row() {
                Text('双语输出（译文 + 原文）').fontSize(14).fontColor(this.P().text).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.bilingual }).onChange((value: boolean) => { this.bilingual = value; })
              }.width('100%')
              Button(this.completed === this.total ? '导出完整 SRT' : '导出已译部分 SRT').width('100%').height(44)
                .fontColor(this.P().text).backgroundColor(this.P().cardHover)
                .enabled(!this.busy && this.state !== 'running').onClick(() => { this.exportFile(); })
              if (this.onApply !== null) {
                Button(this.completed === this.total ? '应用字幕' : '应用已译部分').width('100%').height(44)
                  .fontColor('#FFFFFF').backgroundColor(this.P().accent)
                  .enabled(!this.busy && this.state !== 'running').onClick(() => { this.apply(); })
              }
            }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18)
          }
          Text('进度只计算已收到并校验通过的字幕。暂停、取消或失败后，可在本页继续；关闭本页会结束任务，请先导出需要保留的结果。')
            .fontSize(13).fontColor(this.P().textDim).width('100%').lineHeight(21)
        }.width('100%').padding({ left: '3.4%', right: '3.4%', bottom: 36 })
      }.width('100%').layoutWeight(1).constraintSize({ minHeight: 0 }).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(this.P().bg)
      .padding({ top: this.safeTop, bottom: this.safeBottom, left: this.safeLeft, right: this.safeRight })
      .onAreaChange(() => { this.readSafeInsets(); })
  }
}
