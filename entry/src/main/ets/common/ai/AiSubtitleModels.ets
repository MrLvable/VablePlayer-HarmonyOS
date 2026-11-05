/** Configuration contains no credentials. API keys are resolved from AssetStoreKit at runtime. */
export class AiEndpointConfig {
  baseUrl: string = '';
  model: string = '';
}

export class AiSubtitleConfig {
  translation: AiEndpointConfig = new AiEndpointConfig();
  asr: AiEndpointConfig = new AiEndpointConfig();
  reuseTranslationForAsr: boolean = true;
  targetLanguage: string = 'zh-CN';
  /** Empty means automatic source-language detection. */
  sourceLanguage: string = '';
}

export interface AiRuntimeEndpoint {
  baseUrl: string;
  model: string;
  apiKey: string;
}

export interface AiKeyPresence {
  translation: boolean;
  asr: boolean;
}

export interface AiSubtitleCue {
  id: string;
  startMs: number;
  endMs: number;
  text: string;
}

export interface AiTranslationContext {
  previousText: string;
  glossary: string;
}

export interface AiValidationResult {
  ok: boolean;
  models: string[];
  selectedModelAvailable: boolean;
  message: string;
}

/** Matching is limited to known API families. /models alone is not a capability test. */
export class AiSubtitleModelSelection {
  static textOnlyService(baseUrl: string): boolean {
    return /^https?:\/\/api\.deepseek\.com(?:\/v1)?\/?$/i.test(baseUrl.trim());
  }

  static fileAsr(model: string): boolean {
    return /^(?:gpt-transcribe(?:-\d{4}-\d{2}-\d{2})?|whisper-1|gpt-4o(?:-mini)?-transcribe(?:-\d{4}-\d{2}-\d{2})?)$/i.test(model);
  }

  static textModel(model: string): boolean {
    if (/(?:transcrib|whisper|audio|realtime|live|embedding|tts|moderation|image|dall-e|sora|codex)/i.test(model)) { return false; }
    return /^(?:gpt-[\d]|chatgpt-|deepseek-|qwen|glm-|claude-|gemini-|mistral|llama|meta-llama\/)/i.test(model);
  }

  static translation(models: string[], current: string = ''): string {
    if (current.length > 0 && models.indexOf(current) >= 0 && AiSubtitleModelSelection.textModel(current)) { return current; }
    const choices = models.filter((model: string) => AiSubtitleModelSelection.textModel(model));
    const preferred = choices.find((model: string) => /(?:flash|mini|turbo|deepseek-chat)(?:-|$)/i.test(model));
    return preferred !== undefined ? preferred : (choices.length > 0 ? choices[0] : '');
  }

  static asr(models: string[], current: string = ''): string {
    if (models.indexOf('gpt-transcribe') >= 0) { return 'gpt-transcribe'; }
    if (current.length > 0 && models.indexOf(current) >= 0 && AiSubtitleModelSelection.fileAsr(current)) { return current; }
    const selected = models.find((model: string) => AiSubtitleModelSelection.fileAsr(model));
    return selected !== undefined ? selected : '';
  }
}

export interface AiTranscriptionResult {
  /** Relative to the submitted WAV, not the entire movie. Empty when real timestamps are unavailable. */
  cues: AiSubtitleCue[];
  text: string;
  timestampsAvailable: boolean;
}

export class AiSubtitleError extends Error {
  kind: string;
  status: number;
  constructor(kind: string, message: string, status: number = 0) {
    super(message);
    this.kind = kind;
    this.status = status;
  }
}
