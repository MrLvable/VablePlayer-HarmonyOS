import { rcp } from '@kit.RemoteCommunicationKit';
import { util, url } from '@kit.ArkTS';

export class SourceResponse {
  status: number = 0;
  text: string = '';
  headers: Record<string, string> = {};
  address: string = '';
}
export class SourceBinaryResponse {
  status: number = 0;
  data: Uint8Array = new Uint8Array(0);
  headers: Record<string, string> = {};
  address: string = '';
}

/** Small metadata documents only. Media bytes go directly to the player. */
export class DirectSourceHttp {
  private generation: number = 0;
  private next: number = 0;
  private sessions: Map<number, rcp.Session> = new Map();

  static resolve(base: string, href: string): string {
    try {
      const parsed = new url.URL(href, base);
      if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.hostname.length === 0
        || parsed.username.length > 0 || parsed.password.length > 0) { throw new Error('url'); }
      parsed.hash = '';
      return parsed.toString();
    } catch (e) { throw new Error('来源地址必须是有效的 HTTP(S) 地址，且不含内嵌账号密码'); }
  }

  static origin(address: string): string { return new url.URL(DirectSourceHttp.resolve(address, address)).origin; }
  static sameOrigin(a: string, b: string): boolean { return DirectSourceHttp.origin(a) === DirectSourceHttp.origin(b); }
  static extension(address: string): string {
    const path = new url.URL(DirectSourceHttp.resolve(address, address)).pathname;
    const match = /\.([a-z0-9]+)$/i.exec(path);
    return match === null ? '' : match[1].toLowerCase();
  }
  static basic(username: string, password: string): string {
    if (username.indexOf(':') >= 0 || /[\r\n]/.test(username + password)) { throw new Error('认证信息格式无效'); }
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(username + ':' + password));
  }

  cancel(): void {
    this.generation++;
    this.sessions.forEach((session: rcp.Session) => { try { session.cancel(); } catch (e) {} });
  }

  async request(address: string, method: string, headers: Record<string, string>, body: string = '',
                maximum: number = 2097152, redirect: number = 0): Promise<SourceResponse> {
    const raw = await this.requestRaw(address, method, headers, body, maximum, redirect);
    const result = new SourceResponse(); result.status = raw.status; result.headers = raw.headers; result.address = raw.address;
    try { result.text = new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(raw.data); }
    catch (e) { throw new Error('来源文档不是有效 UTF-8 文本'); }
    return result;
  }
  requestBinary(address: string, method: string, headers: Record<string, string>, body: ArrayBuffer,
                maximum: number = 8388608): Promise<SourceBinaryResponse> {
    return this.requestRaw(address, method, headers, body, maximum, 0);
  }
  private async requestRaw(address: string, method: string, headers: Record<string, string>, body: string | ArrayBuffer,
                maximum: number, redirect: number): Promise<SourceBinaryResponse> {
    address = DirectSourceHttp.resolve(address, address);
    if (!Number.isInteger(maximum) || maximum <= 0 || maximum > 8388608) { throw new Error('文档读取上限无效'); }
    const gen = this.generation;
    const safeHeaders: Record<string, string> = {};
    Object.keys(headers).forEach((key: string) => {
      if (!/^[A-Za-z0-9!#$%&'*+.^_|~-]+$/.test(key) || /[\r\n]/.test(headers[key])) { throw new Error('请求头格式无效'); }
      safeHeaders[key] = headers[key];
    });
    const session = rcp.createSession();
    const id = ++this.next;
    this.sessions.set(id, session);
    const content = typeof body === 'string' && body.length === 0 ? undefined : body;
    const request = new rcp.Request(address, method, safeHeaders, content);
    request.configuration = { transfer: { autoRedirect: false, timeout: { connectMs: 7000, transferMs: 15000 } } };
    const chunks: Uint8Array[] = [];
    let size = 0;
    let oversized = false;
    request.destination = (incoming: ArrayBuffer): void => {
      if (gen !== this.generation || oversized) { return; }
      if (incoming.byteLength > maximum - size) {
        oversized = true;
        try { session.cancel(request); } catch (e) {}
        return;
      }
      const copy = new Uint8Array(incoming.byteLength);
      copy.set(new Uint8Array(incoming));
      chunks.push(copy);
      size += copy.byteLength;
    };
    try {
      const response = await session.fetch(request);
      if (oversized) { throw new Error('来源文档超过读取上限'); }
      if (gen !== this.generation) { throw new Error('来源请求已取消'); }
      const result = new SourceBinaryResponse();
      result.status = response.statusCode;
      result.address = address;
      Object.keys(response.headers).forEach((key: string) => {
        const value = response.headers[key];
        result.headers[key.toLowerCase()] = typeof value === 'string' ? value : Array.isArray(value) ? value.join(',') : '';
      });
      if (result.status >= 300 && result.status < 400) {
        const location = result.headers['location'];
        if (redirect >= 3 || typeof location !== 'string' || location.length === 0) { throw new Error('来源重定向无效或次数过多'); }
        const next = DirectSourceHttp.resolve(address, location);
        if (!DirectSourceHttp.sameOrigin(address, next)) { throw new Error('来源重定向到了不同主机，请使用最终来源地址'); }
        return await this.requestRaw(next, method, headers, body, maximum, redirect + 1);
      }
      // A callback destination normally leaves body empty; handle a bounded body too.
      if (size === 0 && response.body !== undefined) {
        if (response.body.byteLength > maximum) { throw new Error('来源文档超过读取上限'); }
        chunks.push(new Uint8Array(response.body)); size = response.body.byteLength;
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      chunks.forEach((chunk: Uint8Array) => { bytes.set(chunk, offset); offset += chunk.byteLength; });
      result.data = bytes;
      return result;
    } catch (e) {
      if (oversized) { throw new Error('来源文档超过读取上限'); }
      if (gen !== this.generation) { throw new Error('来源请求已取消'); }
      const error = e as Error;
      if (/^(来源|请求头)/.test(error.message)) { throw new Error(error.message); }
      throw new Error('无法连接来源，请检查地址、认证和网络');
    } finally {
      this.sessions.delete(id);
      try { session.close(); } catch (e) {}
    }
  }
}
