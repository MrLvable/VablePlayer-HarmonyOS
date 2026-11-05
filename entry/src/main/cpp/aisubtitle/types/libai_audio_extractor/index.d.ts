export interface AudioExtractionOptions {
  url: string;
  headers: Record<string, string>;
  outputPath: string;
  startMs: number;
  durationMs: number;
  sampleRate: number;
  jobId: string;
  /** Optional absolute FFmpeg stream index; omitted selects the best audio stream. */
  audioStreamIndex?: number;
}
export interface ExtractedAudioWindow {
  path: string;
  startMs: number;
  endMs: number;
  sampleRate: number;
  channels: number;
  /** Includes HTTP response headers and bounded range bodies, or local bytes read. */
  sourceBytes: number;
  sourceOpenBytes: number;
  sourceProbeBytes: number;
  sourceSeekBytes: number;
  sourceDecodeBytes: number;
}
export interface SubtitleExtractionOptions {
  url: string;
  headers: Record<string, string>;
  startMs: number;
  durationMs: number;
  /** Bounded look-back for overlapping cues; defaults to 5000, maximum 30000. */
  preRollMs?: number;
  jobId: string;
  subtitleStreamIndex?: number;
  /** Zero-based ordinal among all subtitle streams, including bitmap streams. */
  subtitleOrdinal?: number;
  /** Exact case-insensitive match to actual stream language metadata. */
  preferredLanguage?: string;
}
export interface ExtractedSubtitleCue { startMs: number; endMs: number; text: string; }
export interface ExtractedSubtitleWindow {
  cues: ExtractedSubtitleCue[];
  language: string;
  streamIndex: number;
  sourceBytes: number;
  sourceOpenBytes: number;
  sourceProbeBytes: number;
  sourceSeekBytes: number;
  sourceDecodeBytes: number;
}
export const extractAudio: (options: AudioExtractionOptions) => Promise<ExtractedAudioWindow>;
export const extractTextSubtitles: (options: SubtitleExtractionOptions) => Promise<ExtractedSubtitleWindow>;
export const cancelExtraction: (jobId: string) => void;
