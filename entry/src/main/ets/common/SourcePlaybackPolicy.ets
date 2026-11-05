/** Every negotiated network/file-descriptor source uses the same streaming engine. */
export class SourcePlaybackPolicy {
  static useMpv(_kind: string, url: string): boolean {
    // Existing app download records may predate the .ready filename convention.
    if (url.startsWith('/')) { return false; }
    if (/^https?:\/\/[^/?#\s]+(?:[/?#]|$)/i.test(url) || /^fd:\/\/\d+$/.test(url)) { return true; }
    throw new Error('当前播放协议不受支持，请重新选择媒体来源');
  }

  static headers(kind: string, explicit: Record<string, string> | null | undefined,
    legacyToken: string): Record<string, string> {
    const headers: Record<string, string> = {};
    if (explicit !== null && explicit !== undefined) {
      const keys = Object.keys(explicit);
      for (let i = 0; i < keys.length; i++) { headers[keys[i]] = explicit[keys[i]]; }
    } else if (explicit === undefined && kind === 'fnos' && legacyToken.length > 0) {
      // Only pre-negotiation legacy FnOS routes omitted streamHeaders.
      headers['Authorization'] = legacyToken;
      headers['X-Emby-Token'] = legacyToken;
    }
    return headers;
  }
}
