import { AiSubtitleConfig, AiRuntimeEndpoint, AiSubtitleError, AiSubtitleModelSelection } from '../common/ai/AiSubtitleModels';
import { AiSubtitleConfigStore } from '../common/ai/AiSubtitleConfigStore';
import { OpenAiSubtitleClient } from '../common/ai/OpenAiSubtitleClient';
import { Palette, Theme, pal } from '../common/Theme';
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

/** Independent settings surface: the owner decides navigation/sheet placement. */
@Component
export struct AiSubtitleSettings {
  onClose: () => void = () => {};
  onSaved: () => void = () => {};
  onOpenTool: () => void = () => {};
  @Prop dark: boolean = Theme.isDark();
  @Prop showHeader: boolean = true;
  /** The playback owner may reveal the one-time ASR setup when original speech is needed. */
  @Prop configurationPurpose: string = 'translation';
  /** Opt in when the host window draws page content beneath its system bars. */
  @Prop fullScreenOverlay: boolean = false;
  @State private safeTop: number = 0;
  @State private safeBottom: number = 0;
  @State private safeLeft: number = 0;
  @State private safeRight: number = 0;
  @State private translationBaseUrl: string = '';
  @State private translationModel: string = '';
  @State private translationKey: string = '';
  @State private asrBaseUrl: string = '';
  @State private asrModel: string = '';
  @State private asrKey: string = '';
  @State private reuseForAsr: boolean = true;
  @State private targetLanguage: string = 'zh-CN';
  @State private sourceLanguage: string = '';
  @State private hasTranslationKey: boolean = false;
  @State private hasAsrKey: boolean = false;
  @State private clearTranslationKey: boolean = false;
  @State private clearAsrKey: boolean = false;
  @State private loading: boolean = true;
  @State private busy: boolean = false;
  @State private validating: boolean = false;
  @State private status: string = '';
  @State private statusOk: boolean = false;
  @State private modelSummary: string = '';
  @State private compatibilityExpanded: boolean = false;
  @State private asrExpanded: boolean = false;
  private translationModelBase: string = '';
  private asrModelBase: string = '';
  private discoveredBase: string = '';
  private discoveredModels: string[] = [];
  private mounted: boolean = false;
  private operation: number = 0;
  private client: OpenAiSubtitleClient | null = null;
  private safeWindow: window.Window | null = null;
  private avoidAreaChanged: (event: window.AvoidAreaOptions) => void = (_event: window.AvoidAreaOptions) => {
    this.readSafeInsets();
  };

  private P(): Palette { return pal(this.dark); }

  aboutToAppear(): void { this.mounted = true; this.connectSafeArea(); this.load(); }

  aboutToDisappear(): void {
    this.mounted = false; this.operation++;
    const win = this.safeWindow; this.safeWindow = null;
    if (win !== null) { try { win.off('avoidAreaChange', this.avoidAreaChanged); } catch (e) {} }
    if (this.client !== null) { this.client.cancel(); this.client = null; }
    this.translationKey = ''; this.asrKey = '';
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

  private async load(): Promise<void> {
    const revision = ++this.operation;
    try {
      const config = await AiSubtitleConfigStore.load();
      const keys = await AiSubtitleConfigStore.keyPresence();
      if (!this.mounted || revision !== this.operation) { return; }
      this.translationBaseUrl = config.translation.baseUrl; this.translationModel = config.translation.model;
      this.asrBaseUrl = config.asr.baseUrl; this.asrModel = config.asr.model;
      this.reuseForAsr = config.reuseTranslationForAsr;
      this.targetLanguage = config.targetLanguage; this.sourceLanguage = '';
      this.hasTranslationKey = keys.translation; this.hasAsrKey = keys.asr;
      this.translationModelBase = config.translation.baseUrl; this.asrModelBase = config.asr.baseUrl;
      if (AiSubtitleModelSelection.textOnlyService(config.translation.baseUrl)) { this.reuseForAsr = false; }
      this.asrExpanded = this.configurationPurpose === 'asr';
    } catch (e) {
      if (this.mounted && revision === this.operation) { this.status = this.message(e as Error); }
    } finally { if (this.mounted && revision === this.operation) { this.loading = false; } }
  }

  private message(error: Error): string {
    return error instanceof AiSubtitleError ? error.message : '操作未完成，请检查服务配置后重试';
  }

  private changed(): void { this.status = ''; this.modelSummary = ''; this.statusOk = false; }

  private draft(): AiSubtitleConfig {
    const config = new AiSubtitleConfig();
    config.translation.baseUrl = this.translationBaseUrl; config.translation.model = this.translationModel;
    config.asr.baseUrl = this.asrBaseUrl; config.asr.model = this.asrModel;
    config.reuseTranslationForAsr = this.reuseForAsr;
    config.targetLanguage = this.targetLanguage; config.sourceLanguage = ''; // Detect the original language automatically.
    return config;
  }

  private async endpoint(kind: string): Promise<AiRuntimeEndpoint> {
    const translationCredentials = kind === 'translation' || this.reuseForAsr;
    const base = AiSubtitleConfigStore.normalizeBaseUrl(translationCredentials ? this.translationBaseUrl : this.asrBaseUrl);
    const model = (kind === 'translation' ? this.translationModel : this.asrModel).trim();
    const input = AiSubtitleConfigStore.normalizeApiKey(translationCredentials ? this.translationKey : this.asrKey);
    const clearing = translationCredentials ? this.clearTranslationKey : this.clearAsrKey;
    if (input.length > 0) { return { baseUrl: base, model: model, apiKey: input }; }
    if (clearing) { throw new AiSubtitleError('config', '该密钥已标记清除，请重新输入 API Key'); }
    const config = await AiSubtitleConfigStore.load();
    if (!translationCredentials && config.reuseTranslationForAsr) {
      throw new AiSubtitleError('config', '请先保存独立识别服务配置，或输入该服务的 API Key');
    }
    const saved = translationCredentials ? await AiSubtitleConfigStore.translationEndpoint(false) : await AiSubtitleConfigStore.asrEndpoint(false);
    if (saved.baseUrl !== base) { throw new AiSubtitleError('config', '修改服务地址后，请重新输入对应 API Key'); }
    return { baseUrl: base, model: model, apiKey: saved.apiKey };
  }

  private async validate(kind: string, shortTranslation: boolean): Promise<void> {
    if (this.busy || this.loading) { return; }
    this.busy = true; this.validating = true; this.statusOk = false; this.modelSummary = '';
    this.status = shortTranslation ? '正在测试字幕翻译…' : '正在验证模型列表…';
    const revision = ++this.operation;
    try {
      const endpoint = await this.endpoint(kind);
      if (!this.mounted || revision !== this.operation) { return; }
      const client = new OpenAiSubtitleClient(endpoint, !shortTranslation); this.client = client;
      const result = shortTranslation ? await client.validateTranslation() : await client.validateModel();
      if (!this.mounted || revision !== this.operation) { return; }
      this.status = result.message; this.statusOk = result.ok;
      if (result.models.length > 0) {
        this.modelSummary = '可用模型：' + result.models.slice(0, 6).join('、')
          + (result.models.length > 6 ? ' 等 ' + result.models.length.toString() + ' 个' : '');
      }
    } catch (e) {
      if (this.mounted && revision === this.operation) { this.status = this.message(e as Error); }
    } finally {
      if (this.mounted && revision === this.operation) { this.busy = false; this.validating = false; this.client = null; }
    }
  }

  private cancelValidation(): void {
    this.operation++;
    if (this.client !== null) { this.client.cancel(); this.client = null; }
    this.busy = false; this.validating = false; this.statusOk = false; this.status = '已取消验证';
  }

  private async discover(kind: string, revision: number): Promise<string[]> {
    const endpoint = await this.endpoint(kind);
    if (!this.mounted || revision !== this.operation) { throw new AiSubtitleError('cancelled', '已取消'); }
    const client = new OpenAiSubtitleClient(endpoint, true); this.client = client;
    const result = await client.validateModel();
    if (!this.mounted || revision !== this.operation) { throw new AiSubtitleError('cancelled', '已取消'); }
    this.client = null;
    if (kind === 'translation') { this.discoveredBase = endpoint.baseUrl; this.discoveredModels = result.models.slice(); }
    return result.models;
  }

  private async prepareModels(revision: number): Promise<void> {
    const base = AiSubtitleConfigStore.normalizeBaseUrl(this.translationBaseUrl);
    const changedService = base !== this.translationModelBase;
    let models: string[] = base === this.discoveredBase ? this.discoveredModels.slice() : [];
    if (this.translationModel.trim().length === 0 || base !== this.translationModelBase) {
      models = await this.discover('translation', revision);
      const selected = AiSubtitleModelSelection.translation(models, this.translationModel.trim());
      if (selected.length === 0) {
        this.compatibilityExpanded = true;
        throw new AiSubtitleError('config', '服务未提供可自动匹配的翻译模型，请在兼容设置中选择服务商支持的模型');
      }
      this.translationModel = selected; this.translationModelBase = base;
    }
    if (AiSubtitleModelSelection.textOnlyService(base)) { this.reuseForAsr = false; }
    if (this.reuseForAsr && (this.asrModel.trim().length === 0 || changedService)) {
      if (base !== this.discoveredBase) { models = await this.discover('translation', revision); }
      this.asrModel = AiSubtitleModelSelection.asr(models, this.asrModel.trim());
      if (this.asrModel.length === 0) { this.reuseForAsr = false; }
    }
    if (!this.reuseForAsr && this.asrBaseUrl.trim().length > 0) {
      const asrBase = AiSubtitleConfigStore.normalizeBaseUrl(this.asrBaseUrl);
      if (AiSubtitleModelSelection.textOnlyService(asrBase)) {
        this.asrExpanded = true;
        throw new AiSubtitleError('config-asr', '此服务只提供文本翻译，请填写支持音频转写的识别服务');
      }
      if (this.asrModel.trim().length === 0 || asrBase !== this.asrModelBase) {
        const asrModels = await this.discover('asr', revision);
        const selected = AiSubtitleModelSelection.asr(asrModels, this.asrModel.trim());
        if (selected.length === 0) {
          this.asrExpanded = true; this.compatibilityExpanded = true;
          throw new AiSubtitleError('config-asr', '未发现已知的文件转写模型，请在兼容设置中填写识别服务支持的模型');
        }
        this.asrModel = selected; this.asrModelBase = asrBase;
      }
    }
  }

  private async save(): Promise<void> {
    if (this.busy || this.loading) { return; }
    this.busy = true; this.validating = true; this.statusOk = false;
    this.status = '正在自动匹配服务模型…'; this.modelSummary = '';
    const revision = ++this.operation;
    try {
      await this.prepareModels(revision);
      if (!this.mounted || revision !== this.operation) { return; }
      this.validating = false; this.status = '正在安全保存…';
      await AiSubtitleConfigStore.save(this.draft(), this.translationKey, this.asrKey,
        this.clearTranslationKey, this.clearAsrKey);
      if (!this.mounted || revision !== this.operation) { return; }
      this.translationKey = ''; this.asrKey = '';
      this.clearTranslationKey = false; this.clearAsrKey = false;
      const keys = await AiSubtitleConfigStore.keyPresence();
      if (!this.mounted || revision !== this.operation) { return; }
      this.hasTranslationKey = keys.translation; this.hasAsrKey = keys.asr;
      await AiSubtitleConfigStore.translationEndpoint();
      if (this.configurationPurpose === 'asr') {
        try { await AiSubtitleConfigStore.asrEndpoint(); }
        catch (error) {
          if (this.mounted && revision === this.operation) {
            this.asrExpanded = true; this.status = '翻译配置已保存；识别原声还需添加下方语音识别服务'; this.statusOk = false;
          }
          return;
        }
      }
      if (!this.mounted || revision !== this.operation) { return; }
      this.status = '已保存，下次点开即可使用'; this.statusOk = true;
      this.onSaved();
    } catch (e) {
      if (this.mounted && revision === this.operation) { this.status = this.message(e as Error); }
    } finally {
      if (this.mounted && revision === this.operation) { this.busy = false; this.validating = false; this.client = null; }
    }
  }

  private async openTool(): Promise<void> {
    if (this.busy || this.loading) { return; }
    this.busy = true; this.validating = false;
    const revision = ++this.operation;
    try {
      const saved = await AiSubtitleConfigStore.load();
      const keys = await AiSubtitleConfigStore.keyPresence();
      if (!this.mounted || revision !== this.operation) { return; }
      if (this.translationKey.length > 0 || this.asrKey.length > 0 || this.clearTranslationKey || this.clearAsrKey
        || saved.translation.baseUrl !== this.translationBaseUrl.trim().replace(/\/+$/, '')
        || saved.translation.model !== this.translationModel.trim() || saved.targetLanguage !== this.targetLanguage.trim()
        || saved.sourceLanguage !== this.sourceLanguage.trim() || saved.reuseTranslationForAsr !== this.reuseForAsr
        || saved.asr.model !== this.asrModel.trim()
        || (!this.reuseForAsr && saved.asr.baseUrl !== this.asrBaseUrl.trim().replace(/\/+$/, ''))) {
        this.statusOk = false; this.status = '请先保存当前配置，再翻译字幕文件'; return;
      }
      if (!keys.translation || saved.translation.baseUrl.length === 0 || saved.translation.model.length === 0) {
        this.statusOk = false; this.status = '请先填写并保存翻译服务与 API Key'; return;
      }
      this.onOpenTool();
    } catch (e) {
      if (this.mounted && revision === this.operation) { this.statusOk = false; this.status = this.message(e as Error); }
    } finally { if (this.mounted && revision === this.operation) { this.busy = false; } }
  }

  @Builder
  private translationCard() {
    Column({ space: 10 }) {
      Text('AI 服务').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.P().text).width('100%')
      TextInput({ text: this.translationBaseUrl, placeholder: 'base_url，例如 https://api.example.com/v1' })
        .height(46).fontSize(14).backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
        .enabled(!this.busy && !this.loading).onChange((value: string) => { this.translationBaseUrl = value; this.changed(); })
      TextInput({ text: this.translationKey, placeholder: this.hasTranslationKey && !this.clearTranslationKey ? 'API Key 已安全保存，留空保留' : 'API Key' })
        .type(InputType.Password).showPasswordIcon(true).height(46).fontSize(15)
        .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
        .enabled(!this.busy && !this.loading).onChange((value: string) => { this.translationKey = value; this.clearTranslationKey = false; this.changed(); })
      Text(this.translationModel.length > 0 ? '模型 · ' + this.translationModel : '保存时自动选择合适的模型')
        .fontSize(12).fontColor(this.P().textDim).width('100%')
    }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private asrCard() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 5 }) {
          Text('识别影片原声').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.P().text).width('100%')
          Text(AiSubtitleModelSelection.textOnlyService(this.translationBaseUrl)
            ? 'DeepSeek 可翻译字幕；无字幕影片需另加识别服务。'
            : (this.asrModel.length > 0 ? '模型 · ' + this.asrModel : '已有字幕可直接翻译，识别原声只需配置一次。'))
            .fontSize(12).fontColor(this.P().textDim).width('100%').lineHeight(19)
        }.layoutWeight(1)
        Button(this.asrExpanded ? '收起' : '配置').fontSize(13).height(34).fontColor(this.P().accent).backgroundColor(this.P().cardHover)
          .enabled(!this.busy && !this.loading).onClick(() => { this.asrExpanded = !this.asrExpanded; })
      }.width('100%')
      if (this.asrExpanded) {
        if (!AiSubtitleModelSelection.textOnlyService(this.translationBaseUrl)) {
          Row() {
            Text('使用同一服务识别原声').fontSize(14).fontColor(this.P().text).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.reuseForAsr }).enabled(!this.busy && !this.loading)
              .onChange((value: boolean) => { this.reuseForAsr = value; this.changed(); })
          }.width('100%').height(36)
        }
        if (!this.reuseForAsr || AiSubtitleModelSelection.textOnlyService(this.translationBaseUrl)) {
          TextInput({ text: this.asrBaseUrl, placeholder: '识别服务 base_url' }).height(46).fontSize(14)
            .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
            .enabled(!this.busy && !this.loading).onChange((value: string) => { this.asrBaseUrl = value; this.changed(); })
          TextInput({ text: this.asrKey, placeholder: this.hasAsrKey && !this.clearAsrKey ? '识别密钥已安全保存，留空保留' : '识别服务 API Key' })
            .type(InputType.Password).showPasswordIcon(true).height(46).fontSize(15)
            .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
            .enabled(!this.busy && !this.loading).onChange((value: string) => { this.asrKey = value; this.clearAsrKey = false; this.changed(); })
          Text('使用此服务自己的密钥，模型会自动匹配。').fontSize(12).fontColor(this.P().textDim).width('100%')
        }
      }
    }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private compatibilityCard() {
    Column({ space: 10 }) {
      Row() {
        Text('兼容设置').fontSize(15).fontColor(this.P().textDim).layoutWeight(1)
        Button(this.compatibilityExpanded ? '收起' : '展开').fontSize(13).height(32).fontColor(this.P().textDim).backgroundColor(this.P().cardHover)
          .enabled(!this.busy && !this.loading).onClick(() => { this.compatibilityExpanded = !this.compatibilityExpanded; })
      }.width('100%')
      if (this.compatibilityExpanded) {
        Text('服务不提供模型列表时，可填写服务商给出的模型名称。').fontSize(12).fontColor(this.P().textDim).width('100%')
        TextInput({ text: this.translationModel, placeholder: '翻译模型（通常无需填写）' }).height(44).fontSize(14)
          .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
          .enabled(!this.busy && !this.loading).onChange((value: string) => {
            this.translationModel = value;
            try { this.translationModelBase = AiSubtitleConfigStore.normalizeBaseUrl(this.translationBaseUrl); } catch (e) {}
            this.changed();
          })
        TextInput({ text: this.asrModel, placeholder: '文件语音转写模型（通常无需填写）' }).height(44).fontSize(14)
          .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
          .enabled(!this.busy && !this.loading).onChange((value: string) => {
            this.asrModel = value;
            try { this.asrModelBase = AiSubtitleConfigStore.normalizeBaseUrl(this.asrBaseUrl); } catch (e) {}
            this.changed();
          })
        Row({ space: 10 }) {
          Button('验证模型').layoutWeight(1).height(38).fontSize(13).fontColor(this.P().text).backgroundColor(this.P().cardHover)
            .enabled(!this.busy && !this.loading).onClick(() => { this.validate('translation', false); })
          Button('测试翻译').layoutWeight(1).height(38).fontSize(13).fontColor(this.P().text).backgroundColor(this.P().cardHover)
            .enabled(!this.busy && !this.loading).onClick(() => { this.validate('translation', true); })
        }.width('100%')
        if (this.hasTranslationKey) {
          Text(this.clearTranslationKey ? '保存后清除翻译密钥' : '清除已保存的翻译密钥').fontSize(12).fontColor(this.P().textDim).width('100%')
            .enabled(!this.busy).onClick(() => { this.clearTranslationKey = !this.clearTranslationKey; this.translationKey = ''; this.changed(); })
        }
        if (this.hasAsrKey) {
          Text(this.clearAsrKey ? '保存后清除识别密钥' : '清除已保存的识别密钥').fontSize(12).fontColor(this.P().textDim).width('100%')
            .enabled(!this.busy).onClick(() => { this.clearAsrKey = !this.clearAsrKey; this.asrKey = ''; this.changed(); })
        }
        Button('翻译字幕文件').height(40).fontSize(14).fontColor(this.P().text).backgroundColor(this.P().cardHover).width('100%')
          .enabled(!this.busy && !this.loading).onClick(() => { this.openTool(); })
      }
    }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18).alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.showHeader) {
        Row({ space: 10 }) {
          Button('‹').width(44).height(44).flexShrink(0).fontSize(30).fontColor(this.P().text).backgroundColor(this.P().card)
            .onClick(() => { if (this.client !== null) { this.client.cancel(); } this.onClose(); })
          Text('AI 字幕').fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.P().text).layoutWeight(1).maxLines(1)
        }.width('100%').height(64).flexShrink(0).padding({ left: '3.4%', right: '3.4%', top: 10, bottom: 10 })
      }
      Scroll() {
        Column({ space: 14 }) {
          Text('配置一次，播放时直接开启').fontSize(13).fontColor(this.P().textDim).width('100%').padding({ left: 14 })
          this.translationCard()
          Column({ space: 10 }) {
            Text('目标语言').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.P().text).width('100%')
            TextInput({ text: this.targetLanguage, placeholder: '简体中文 / zh-CN' }).height(44).fontSize(14)
              .backgroundColor(this.P().cardHover).fontColor(this.P().text).placeholderColor(this.P().textFaint).borderRadius(10)
              .enabled(!this.busy && !this.loading).onChange((value: string) => { this.targetLanguage = value; this.changed(); })
            Text('原语言自动识别').fontSize(12).fontColor(this.P().textDim).width('100%')
          }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(18)
          this.asrCard()
          if (this.loading) { Text('正在读取配置…').fontSize(14).fontColor(this.P().textDim) }
          if (this.status.length > 0) {
            Text(this.status).fontSize(14).fontColor(this.statusOk ? this.P().accent : this.P().textDim).width('100%')
          }
          if (this.modelSummary.length > 0) { Text(this.modelSummary).fontSize(12).fontColor(this.P().textDim).width('100%') }
          Row({ space: 10 }) {
            Button('保存并使用').layoutWeight(1).height(46).fontSize(15).fontColor('#FFFFFF').backgroundColor(this.P().accent)
              .enabled(!this.busy && !this.loading).onClick(() => { this.save(); })
            if (this.busy && this.validating) {
              Button('取消').height(46).fontSize(14).fontColor(this.P().text).backgroundColor(this.P().card)
                .onClick(() => { this.cancelValidation(); })
            }
          }.width('100%')
          this.compatibilityCard()
        }.width('100%').padding({ left: '3.4%', right: '3.4%', bottom: 36 })
      }.layoutWeight(1).constraintSize({ minHeight: 0 }).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(this.P().bg)
      .padding({ top: this.safeTop, bottom: this.safeBottom, left: this.safeLeft, right: this.safeRight })
      .onAreaChange(() => { this.readSafeInsets(); })
  }
}
