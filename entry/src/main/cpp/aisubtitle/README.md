# Bounded audio-window extraction

This NAPI module links the FFmpeg n8.0 symbols already exported by the installed `@mpv-ohos/mpv-arkts` 1.0.0 arm64 `libmpv.so`. It does not construct a second mpv player, alter global player options, request microphone permission, play captured audio, or download a complete remote movie as a fallback.

## Interface

```ts
extractAudio({
  url, headers, outputPath, startMs, durationMs: 12000,
  sampleRate: 16000, jobId
}): Promise<{
  path, startMs, endMs, sampleRate, channels, sourceBytes
}>
cancelExtraction(jobId): void
```

The same module also exports:

```ts
extractTextSubtitles({
  url, headers, startMs, durationMs: 12000, jobId,
  subtitleStreamIndex?, subtitleOrdinal?, preferredLanguage?, preRollMs?
}): Promise<{ cues: { startMs, endMs, text }[], language, streamIndex, sourceBytes }>
```

The explicit FFmpeg stream index takes precedence over the zero-based ordinal among **all** subtitle tracks (including bitmap tracks). With neither selector, the first text subtitle is chosen. A supplied language matches actual stream metadata case-insensitively and exactly; the bridge does not guess an ISO-639 alias or silently substitute another language. Bitmap subtitles are explicitly unsupported, not passed through OCR or ASR as if they were decoded text.

Text extraction seeks 5 seconds before the requested window by default. Optional integer `preRollMs` accepts 0–30000 ms; a longer look-back can recover long overlapping cues but increases reads and latency. Only cues overlapping the requested window are returned, preserving their actual boundaries. A cue that started before this bounded pre-roll can be missed. Scanning stops after the window with a small mux-order allowance, or at the same read/deadline limits; it never scans a complete movie as a fallback. Empty cues can legitimately mean no subtitle text in that window. Unknown cue duration is skipped, and an all-unknown result rejects `SUBTITLE_TIMING_UNAVAILABLE`; no fixed placeholder duration is manufactured.

Non-selected streams are discarded after seeking, except one timed video/audio stream retained to stop at the window boundary even when subtitle cues are sparse. They are never decoded. In FFmpeg n8.0 Matroska, the demuxer checks discard only after reading a Block; this does **not** eliminate interleaved video payload reads. A 12-second window, 5-second look-back and 2-second mux allowance at 6.4 Mbit/s can still read roughly 15 MB plus seek/probe overhead. The 32 MiB/25-second limits remain hard limits, not promises of extraction speed on a slow connection.

FFmpeg decodes ASS/SSA, SubRip, WebVTT, mov_text and other supported text subtitle codecs. ASS event fields, override tags, line breaks and drawing mode are handled by `subtitle_text.h`. Font/style instructions are removed from translated plain text; drawing instructions are not turned into dialogue. Packet PTS is rescaled using the stream time base; FFmpeg display offsets are milliseconds, while `AVSubtitle.pts` is in microseconds.

The ArkTS wrapper is `common/ai/NativeAudioExtractor.ets`. Create a wrapper instance, call `extractAudio`, and call `cancelAll` when its owning playback generation ends. Results arriving after navigation must still be discarded by the caller. Upload/read the returned private cache file only after successful completion, and delete it after use. Never log URLs, headers or credentials.

`outputPath` must be an absolute, unique private-cache filename. Native creation uses `O_EXCL`, `O_NOFOLLOW` and mode 0600: existing files are not overwritten. Failure/cancellation removes only an output created by this job. The result is a mono 16 kHz signed-16-bit little-endian WAV, including its 44-byte header. `startMs` and `endMs` describe the audio actually written using source PTS, not fabricated request timestamps. Shorter results near EOF are possible. Silence genuinely decoded from the source is retained; missing audio is never replaced with synthetic silence.

Optional `audioStreamIndex` is an absolute **FFmpeg stream index**, not the mpv UI track ID. If omitted, FFmpeg selects its best audio stream. Do not pass an unrelated mpv track number as this field.

Audio extraction seeks through the container's default indexed stream before discarding other tracks, then decodes only the selected audio. This matters for MKV Cues that index video without indexing every audio track: an audio-index seek can fall back to a linear scan from the beginning. Successful results expose numeric `sourceOpenBytes`, `sourceProbeBytes`, `sourceSeekBytes` and `sourceDecodeBytes`; their sum is `sourceBytes`. These counters include the same bounded input/HTTP response bytes and reveal which stage consumed the budget without logging source addresses or credentials.

## Limits and errors

- Exactly one native extraction job at a time. Concurrent calls fail `EXTRACTION_BUSY`.
- Requested duration 100–30000 ms; normal caller window 12000 ms. Sample rate must be 16000.
- 25-second worker deadline and atomic cancellation, checked during socket waits and decode operations. No detached worker thread is created.
- Input read budget is 32 MiB. HTTP response headers count toward this budget. Local input reads are counted too.
- The native AVIO reader accepts numeric `http://`, absolute local files and borrowed `fd://N`. The ArkTS wrapper transparently bridges file-type HTTP(S) URLs with DNS/TLS through NetworkKit streaming, described below. HLS/playlists still fail explicitly; no complete-file cache is used.
- HTTP discovers total size with `bytes=0-0`, then uses independent bounded 512 KiB Range requests whose end is clamped to `total-1`. Seeking to total returns EOF without a request. The reader validates 206 and Content-Range/length, requests identity encoding and rejects chunked/encoded ranges. All redirects are rejected before issuing another request, so custom authorization headers never follow a redirect.
- A non-206 response reports an allowlisted diagnostic suffix such as `HTTP_RANGE_REQUIRED_STATUS_200_JSON_CR_N_CL_Y`. It contains only the HTTP status, response type class and presence of Content-Range/Content-Length. A numeric JSON `code` is appended only if already present in the initial bounded receive buffer. It never includes the URL, arbitrary response text, credentials or header values. This distinguishes a JSON business/auth failure from a server ignoring Range; it does not accept a 200 whole-file response as a fallback.
- A 416 response also reports only numeric requested start/end and the currently known total, so an unexpected server boundary rejection can be distinguished from the former unclamped tail-request defect.
- The module never gives the URL or headers to FFmpeg. It supplies a bounded custom AVIO reader and rejects nested FFmpeg I/O. Accepted container demuxers are explicitly listed in the implementation. Playlists and arbitrary external references cannot start another unbounded reader.
- No audio track, unsupported codec/container, failed seek, absent timestamps, timeline discontinuity, budget exhaustion and cancellation all reject the Promise with a stable error code. The bridge does not claim a usable audio segment on failure.

## Transparent transport and descriptor ownership

`NativeAudioExtractor.supportsSource(url, isHls?)` and `sourceError` expose the real extraction capability to the player. They are only checks for native media extraction; a separately supplied SRT/VTT track may still be translated even when the original movie is an unsupported HLS source.

Numeric HTTP retains the original bounded C++ reader. `AiSourceBridge.ets` handles file-type HTTP(S)/DNS endpoints using the platform NetworkKit `requestInStream`, retaining standard TLS certificate validation. It gives native only a random 192-bit-token URL bound to 127.0.0.1. Credentials remain in memory and are sent only to the original URL. `maxRedirects: 0` refuses redirects before any next-origin request, including for custom authentication headers. No alternate provider or hostname is guessed.

The bridge accepts one explicit byte range at a time, capped at 512 KiB, and requires 206 plus exact Content-Range/length and stable total size. Missing ranges, HTML/JSON/playlist content and encoded bodies fail. Headers are checked before body accumulation; `dataReceive` independently enforces the requested size and total 32 MiB budget, destroys overflowing requests and retains at most the current range. It never starts `request()` as a whole-file fallback. A 25-second bridge deadline, 256-request ceiling and two local clients bound the extraction lifetime. `close` explicitly rejects pending work and destroys requests/sockets even if a platform `destroy` does not settle its Promise.

Local `fd://N` borrows the existing player's file authority. The NAPI call strictly parses a nonnegative descriptor and duplicates it synchronously before queueing native work, preventing the player closing/reusing its borrowed descriptor while the job waits. The worker uses its own duplicate and `pread`, preserving the player's offset and never closing the player's handle. Both duplicates are RAII-released. Only seekable regular files with a positive size are accepted; `fdclose://`, negative/overflow descriptors and suffixes are refused.

The returned phase counters remain native reader bytes. For a bridged source they include loopback HTTP headers/body, and are **not** a measurement of TLS wire traffic or every upstream response-header byte. The bridge separately enforces its body-read budget. HLS nested references remain excluded by the native demuxer policy; supporting HTTPS does not imply playlist support.

## Build integration

The parent entry CMake file should add this directory with `add_subdirectory(aisubtitle)`. Enable the entry module's external CMake build, and add the native declaration package to the entry `oh-package.json5`:

```json
"libai_audio_extractor.so": "file:./src/main/cpp/aisubtitle/types/libai_audio_extractor"
```

`CMakeLists.txt` locates the existing entry OHPM `libmpv.so`; `AI_MPV_LIBRARY` can override its path for a standalone cross-build. Use the OHOS SDK's `ohos.toolchain.cmake`, `OHOS_ARCH=arm64-v8a`, and the SDK CMake/Ninja executables. No new FFmpeg binary is bundled. The existing mpv HAR still supplies `libmpv.so` and its dependencies.

The retained upstream header provenance and licensing are in `third_party/ffmpeg`. Before accessing public structures, runtime versions must exactly match avformat 62.3.100, avcodec 62.11.100, avutil 60.8.100 and swresample 6.1.100. A mismatched binary is rejected. The retained AVS3DA codec enum matches the installed mpv build patch; those patches do not change the public structure layouts used here.

## Verification

From the project root, `python3 tests/native/validate_native_helpers.py` compiles and runs the actual portable C helpers with a host Clang/GCC compiler. `node tests/native/validate-native-wrapper.cjs` strictly checks the actual ArkTS wrapper and native declarations, then uses mocked NAPI Promises for lifecycle and counter contracts. Prerequisites and commands are in [tests/README.md](../../../../../tests/README.md).

`tests/validate-ai-source-bridge.cjs` checks the real bridge/wrapper methods with controlled HTTP/socket/NAPI mocks, including Range validation, authentication scope, no redirects, byte limits, cancellation and capability reporting. These tests do not execute an on-device decoder or prove real TLS, container seeking, file authority or cloud ASR behavior.

Build the integrated HAP with the compatible Harmony SDK and restored fixed dependencies. Runtime imports, native cancellation, audio/text extraction, actual media timestamps and network behavior require separate target-device verification. Read [the public validation record](../../../../../docs/VALIDATION.md) for what was executed for this source snapshot. This module contains no cloud provider account or API key.
