import { asset } from '@kit.AssetStoreKit';
import { util, url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Store } from '../Store';
import { AiEndpointConfig, AiSubtitleConfig, AiRuntimeEndpoint, AiKeyPresence, AiSubtitleError,
  AiSubtitleModelSelection } from './AiSubtitleModels';

interface SavedAiConfig {
  version?: number;
  translation?: AiEndpointConfig;
  asr?: AiEndpointConfig;
  reuseTranslationForAsr?: boolean;
  targetLanguage?: string;
  sourceLanguage?: string;
}

interface SerializedAiConfig {
  version: number;
  translation: AiEndpointConfig;
  asr: AiEndpointConfig;
  reuseTranslationForAsr: boolean;
  targetLanguage: string;
  sourceLanguage: string;
}

/** No Preferences fallback for secrets: a locked/unavailable vault is an explicit error. */
export class AiSubtitleConfigStore {
  private static readonly KEY: string = 'ai_subtitle_config_v1';
  private static readonly TRANSLATION_ALIAS: string = 'nasplayer.ai.translation.v1';
  private static readonly ASR_ALIAS: string = 'nasplayer.ai.asr.v1';
  private static chain: Promise<void> = Promise.resolve();

  static normalizeBaseUrl(value: string): string {
    const raw = value.trim().replace(/\/+$/, '');
    if (raw.length === 0 || raw.length > 2048) {
      throw new AiSubtitleError('config', '请填写完整的服务 base_url');
    }
    try {
      const parsed = new url.URL(raw);
      if ((parsed.protocol !== 'https:' && parsed.protocol !== 'http:') || parsed.hostname.length === 0
        || parsed.username.length > 0 || parsed.password.length > 0 || parsed.search.length > 0 || parsed.hash.length > 0) {
        throw new Error('base-url');
      }
    } catch (e) {
      throw new AiSubtitleError('config', 'base_url 需为 HTTP(S) 服务地址，不含密钥、查询参数或片段');
    }
    if (/\/(chat\/completions|audio\/transcriptions|models)$/i.test(raw)) {
      throw new AiSubtitleError('config', '请填写 base_url，不要包含具体接口路径');
    }
    // The official API root is commonly pasted without its required version prefix.
    return /^https:\/\/api\.openai\.com$/i.test(raw) ? raw + '/v1' : raw;
  }

  static normalizeApiKey(value: string): string {
    const key = value.trim().replace(/^Bearer\s+/i, '');
    if (key.length > 8192 || /[\r\n\u0000]/.test(key)) {
      throw new AiSubtitleError('config', 'API Key 格式不正确');
    }
    return key;
  }

  private static endpoint(value: AiEndpointConfig | undefined): AiEndpointConfig {
    const result = new AiEndpointConfig();
    if (value !== undefined && value !== null) {
      result.baseUrl = typeof value.baseUrl === 'string' ? value.baseUrl : '';
      result.model = typeof value.model === 'string' ? value.model : '';
    }
    return result;
  }

  static async load(): Promise<AiSubtitleConfig> {
    const result = new AiSubtitleConfig();
    const raw = await Store.get(AiSubtitleConfigStore.KEY, '');
    if (raw.length === 0) { return result; }
    try {
      const saved = JSON.parse(raw) as SavedAiConfig;
      if (saved === null || saved.version !== 1) { return result; }
      result.translation = AiSubtitleConfigStore.endpoint(saved.translation);
      result.asr = AiSubtitleConfigStore.endpoint(saved.asr);
      result.reuseTranslationForAsr = saved.reuseTranslationForAsr !== false;
      result.targetLanguage = typeof saved.targetLanguage === 'string' ? saved.targetLanguage : 'zh-CN';
      result.sourceLanguage = typeof saved.sourceLanguage === 'string' ? saved.sourceLanguage : '';
    } catch (e) {
      throw new AiSubtitleError('config', 'AI 字幕配置无法读取，请重新保存配置');
    }
    return result;
  }

  private static query(alias: string, withSecret: boolean): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    query.set(asset.Tag.RETURN_TYPE, withSecret ? asset.ReturnType.ALL : asset.ReturnType.ATTRIBUTES);
    query.set(asset.Tag.RETURN_LIMIT, 1);
    return query;
  }

  private static async hasSecret(alias: string): Promise<boolean> {
    try { return (await asset.query(AiSubtitleConfigStore.query(alias, false))).length > 0; }
    catch (e) {
      if ((e as BusinessError).code === 24000002) { return false; }
      throw new AiSubtitleError('secure-store', '无法访问安全密钥仓库，请解锁设备后重试');
    }
  }

  static async keyPresence(): Promise<AiKeyPresence> {
    return { translation: await AiSubtitleConfigStore.hasSecret(AiSubtitleConfigStore.TRANSLATION_ALIAS),
      asr: await AiSubtitleConfigStore.hasSecret(AiSubtitleConfigStore.ASR_ALIAS) };
  }

  private static async readSecret(alias: string): Promise<string> {
    try {
      const values = await asset.query(AiSubtitleConfigStore.query(alias, true));
      if (values.length === 0) { return ''; }
      const bytes = values[0].get(asset.Tag.SECRET) as Uint8Array;
      return new util.TextDecoder('utf-8').decodeToString(bytes);
    } catch (e) {
      if ((e as BusinessError).code === 24000002) { return ''; }
      throw new AiSubtitleError('secure-store', '无法读取安全密钥，请解锁设备后重试');
    }
  }

  private static async writeSecret(alias: string, key: string): Promise<void> {
    try {
      if (key.length === 0) {
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
        try { await asset.remove(query); }
        catch (e) { if ((e as BusinessError).code !== 24000002) { throw new Error('asset-remove'); } }
        return;
      }
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
      attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(key));
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      await asset.add(attributes);
    } catch (e) {
      throw new AiSubtitleError('secure-store', '安全密钥保存失败，未改用普通存储');
    }
  }

  private static cleanEndpoint(input: AiEndpointConfig): AiEndpointConfig {
    const result = new AiEndpointConfig();
    result.baseUrl = AiSubtitleConfigStore.normalizeBaseUrl(input.baseUrl);
    result.model = input.model.trim();
    if (result.model.length === 0 || result.model.length > 256 || /[\r\n\u0000]/.test(result.model)) {
      throw new AiSubtitleError('config', '请填写该服务的模型名称');
    }
    return result;
  }

  private static optionalAsr(input: AiEndpointConfig): AiEndpointConfig {
    const endpoint = AiSubtitleConfigStore.endpoint(input);
    endpoint.baseUrl = endpoint.baseUrl.trim(); endpoint.model = endpoint.model.trim();
    if (endpoint.baseUrl.length === 0) {
      if (endpoint.model.length > 256 || /[\r\n\u0000]/.test(endpoint.model)) {
        throw new AiSubtitleError('config', '语音识别模型名称格式不正确');
      }
      return endpoint; // Keep an older pending model without inventing an endpoint or deleting its key.
    }
    return AiSubtitleConfigStore.cleanEndpoint(endpoint);
  }

  /** Empty key input preserves the saved key. Clear flags explicitly remove it. */
  static save(config: AiSubtitleConfig, translationKey: string = '', asrKey: string = '',
    clearTranslationKey: boolean = false, clearAsrKey: boolean = false): Promise<void> {
    const saved: SerializedAiConfig = { version: 1,
      translation: AiSubtitleConfigStore.cleanEndpoint(config.translation),
      asr: config.reuseTranslationForAsr ? AiSubtitleConfigStore.endpoint(config.asr)
        : AiSubtitleConfigStore.optionalAsr(config.asr),
      reuseTranslationForAsr: config.reuseTranslationForAsr
        && !AiSubtitleModelSelection.textOnlyService(config.translation.baseUrl),
      targetLanguage: config.targetLanguage.trim(), sourceLanguage: config.sourceLanguage.trim() };
    saved.asr.model = saved.asr.model.trim();
    if (saved.asr.model.length > 256 || /[\r\n\u0000]/.test(saved.asr.model)) {
      return Promise.reject(new AiSubtitleError('config', '语音识别模型名称格式不正确'));
    }
    if (saved.targetLanguage.length === 0 || saved.targetLanguage.length > 64 || saved.sourceLanguage.length > 64) {
      return Promise.reject(new AiSubtitleError('config', '请填写有效的目标语言，语言名称不超过 64 字符'));
    }
    const newTranslation = AiSubtitleConfigStore.normalizeApiKey(translationKey);
    const newAsr = AiSubtitleConfigStore.normalizeApiKey(asrKey);
    const run = async (): Promise<void> => {
      const previous = await AiSubtitleConfigStore.load();
      const oldRaw = await Store.get(AiSubtitleConfigStore.KEY, '');
      const oldTranslation = await AiSubtitleConfigStore.readSecret(AiSubtitleConfigStore.TRANSLATION_ALIAS);
      const oldAsr = await AiSubtitleConfigStore.readSecret(AiSubtitleConfigStore.ASR_ALIAS);
      if (!clearTranslationKey && newTranslation.length === 0 && oldTranslation.length > 0
        && previous.translation.baseUrl.length > 0
        && AiSubtitleConfigStore.normalizeBaseUrl(previous.translation.baseUrl) !== saved.translation.baseUrl) {
        throw new AiSubtitleError('config', '修改翻译服务地址后，请重新输入对应 API Key');
      }
      if (!saved.reuseTranslationForAsr && !clearAsrKey && newAsr.length === 0 && oldAsr.length > 0
        && previous.asr.baseUrl.length > 0
        && AiSubtitleConfigStore.normalizeBaseUrl(previous.asr.baseUrl) !== saved.asr.baseUrl) {
        throw new AiSubtitleError('config', '修改语音识别服务地址后，请重新输入对应 API Key');
      }
      const updateTranslation = clearTranslationKey || newTranslation.length > 0;
      const updateAsr = clearAsrKey || newAsr.length > 0;
      try {
        if (updateTranslation) { await AiSubtitleConfigStore.writeSecret(AiSubtitleConfigStore.TRANSLATION_ALIAS, clearTranslationKey ? '' : newTranslation); }
        if (updateAsr) { await AiSubtitleConfigStore.writeSecret(AiSubtitleConfigStore.ASR_ALIAS, clearAsrKey ? '' : newAsr); }
        const raw = JSON.stringify(saved);
        await Store.set(AiSubtitleConfigStore.KEY, raw);
        if (await Store.get(AiSubtitleConfigStore.KEY, '') !== raw) { throw new Error('preferences-not-ready'); }
      } catch (e) {
        // Best-effort rollback keeps old endpoint/key associations after a partial write.
        try {
          if (updateTranslation) { await AiSubtitleConfigStore.writeSecret(AiSubtitleConfigStore.TRANSLATION_ALIAS, oldTranslation); }
          if (updateAsr) { await AiSubtitleConfigStore.writeSecret(AiSubtitleConfigStore.ASR_ALIAS, oldAsr); }
          await Store.set(AiSubtitleConfigStore.KEY, oldRaw);
        } catch (rollbackError) {}
        throw new AiSubtitleError('save', 'AI 字幕配置未能完整保存，请检查安全存储后重试');
      }
    };
    const writing = AiSubtitleConfigStore.chain.then(run, run);
    AiSubtitleConfigStore.chain = writing.then(() => {}, () => {});
    return writing;
  }

  static async translationEndpoint(requireModel: boolean = true): Promise<AiRuntimeEndpoint> {
    await AiSubtitleConfigStore.chain;
    const config = await AiSubtitleConfigStore.load();
    const model = config.translation.model.trim();
    const apiKey = await AiSubtitleConfigStore.readSecret(AiSubtitleConfigStore.TRANSLATION_ALIAS);
    if (apiKey.length === 0) { throw new AiSubtitleError('config', '请先填写 AI 字幕服务 API Key'); }
    if (requireModel && model.length === 0) { throw new AiSubtitleError('config', '请先保存服务配置以自动选择翻译模型'); }
    return { baseUrl: AiSubtitleConfigStore.normalizeBaseUrl(config.translation.baseUrl), model: model, apiKey: apiKey };
  }

  static async asrEndpoint(requireModel: boolean = true): Promise<AiRuntimeEndpoint> {
    await AiSubtitleConfigStore.chain;
    const config = await AiSubtitleConfigStore.load();
    const model = config.asr.model.trim();
    if (requireModel && model.length === 0) { throw new AiSubtitleError('config-asr', '识别原声需先配置支持音频转写的语音识别模型'); }
    if (requireModel && model === 'gpt-live-transcribe') {
      throw new AiSubtitleError('config-asr', '请选择文件语音转写模型，实时语音模型不能用于影片片段识别');
    }
    if (config.reuseTranslationForAsr) {
      if (AiSubtitleModelSelection.textOnlyService(config.translation.baseUrl)) {
        throw new AiSubtitleError('config-asr', 'DeepSeek 只处理字幕翻译；识别原声请另加语音识别服务');
      }
      const translation = await AiSubtitleConfigStore.translationEndpoint(false);
      return { baseUrl: translation.baseUrl, model: model, apiKey: translation.apiKey };
    }
    if (config.asr.baseUrl.trim().length === 0) {
      throw new AiSubtitleError('config-asr', '识别原声需先填写语音识别服务的 base_url 与 API Key');
    }
    if (AiSubtitleModelSelection.textOnlyService(config.asr.baseUrl)) {
      throw new AiSubtitleError('config-asr', 'DeepSeek 不提供音频转写接口，请使用语音识别服务');
    }
    const apiKey = await AiSubtitleConfigStore.readSecret(AiSubtitleConfigStore.ASR_ALIAS);
    if (apiKey.length === 0) { throw new AiSubtitleError('config-asr', '请填写语音识别服务的 API Key，不会使用其他服务密钥'); }
    return { baseUrl: AiSubtitleConfigStore.normalizeBaseUrl(config.asr.baseUrl),
      model: model, apiKey: apiKey };
  }
}
