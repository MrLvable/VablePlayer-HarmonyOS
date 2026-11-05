import { SourceIdentity } from './services/SourceIdentity';

/** Shared image authentication and cache identity for rendering and palette extraction. */
export class ImageRequest {
  static headers(token: string, auth: string, supplied?: Record<string, string>): Record<string, string> {
    const headers: Record<string, string> = {};
    if (supplied !== undefined) { Object.keys(supplied).forEach((key: string) => { headers[key] = supplied[key]; }); return headers; }
    if (token.length > 0) { headers['X-Emby-Token'] = token; headers['X-MediaBrowser-Token'] = token; }
    if (auth.length > 0) { headers['X-Emby-Authorization'] = auth; } return headers;
  }
  static validated(token: string, auth: string, supplied?: Record<string, string>): Record<string, string> {
    const source = ImageRequest.headers(token, auth, supplied); const normalized: Record<string, string> = {};
    Object.keys(source).forEach((key: string) => {
      const name = key.toLowerCase(); const value = source[key];
      if (!/^[A-Za-z0-9!#$%&'*+.^_|~-]+$/.test(key) || typeof value !== 'string' || /[\r\n]/.test(value)
        || (normalized[name] !== undefined && normalized[name] !== value)) { throw new Error('图片请求头无效'); }
      normalized[name] = value;
    }); return normalized;
  }
  static key(url: string, width: number, token: string = '', auth: string = '', supplied?: Record<string, string>): string {
    const source = ImageRequest.headers(token, auth, supplied); let canonical: Record<string, string>;
    try { canonical = ImageRequest.validated('', '', source); }
    catch (e) {
      const invalid = Object.keys(source).sort().map((key: string) => [key, String(source[key])]);
      return SourceIdentity.key(JSON.stringify(['invalid-image-headers', url, width, invalid]));
    }
    const values: string[][] = Object.keys(canonical).sort().map((key: string) => [key, canonical[key]]);
    return SourceIdentity.key(JSON.stringify([url, width, values]));
  }
  static redirectLimit(headers: Record<string, string>): number {
    // NetworkKit redirects may retain custom headers. Authenticated images stay on the requested endpoint.
    return Object.keys(headers).some((key: string) => !/^(accept|accept-language|user-agent|cache-control|pragma)$/i.test(key)) ? 0 : 3;
  }
}
