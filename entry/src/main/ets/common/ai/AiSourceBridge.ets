import { http, socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { url } from '@kit.ArkTS';

class AiBridgeClient {
  connection: socket.TCPSocketConnection;
  header: string = '';
  alive: boolean = true;
  busy: boolean = false;
  timer: number = -1;
  request: http.HttpRequest | null = null;
  cancel: ((message: string) => void) | null = null;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}
interface AiRangeResponse { responseCode: number; header: Record<string, string>; result: ArrayBuffer; }
class AiRangeChunk {
  start: number = 0;
  end: number = 0;
  total: number = 0;
  data: ArrayBuffer = new ArrayBuffer(0);
}

/** One extraction's TLS/DNS transport. Bounded byte ranges, never a whole-file fallback. */
export class AiSourceBridge {
  private server: socket.TCPSocketServer | null = null;
  private clients: AiBridgeClient[] = [];
  private requests: http.HttpRequest[] = [];
  private generation: number = 0;
  private closed: boolean = true;
  private source: string = '';
  private headers: Record<string, string> = {};
  private path: string = '';
  private total: number = 0;
  private bytes: number = 0;
  private requestsMade: number = 0;
  private deadline: number = 0;
  private timer: number = -1;
  private failure: string = '';
  static readonly CHUNK: number = 512 * 1024;
  static readonly BUDGET: number = 32 * 1024 * 1024;

  static validSource(source: string): boolean {
    if (source.length === 0 || source.length > 8192 || /[\u0000-\u0020\\]/.test(source)) { return false; }
    try {
      const parsed = new url.URL(source);
      return (parsed.protocol === 'http:' || parsed.protocol === 'https:') && parsed.hostname.length > 0
        && parsed.username.length === 0 && parsed.password.length === 0 && parsed.hash.length === 0
        && !/\.m3u8(?:$|[/?])/i.test(parsed.pathname);
    } catch (error) { return false; }
  }
  static numericHttp(source: string): boolean {
    return /^http:\/\/(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:.%]+\])(?::\d+)?(?:[/?]|$)/.test(source);
  }
  static requestHeaders(values: Record<string, string>, start: number, end: number): Record<string, string> {
    const result: Record<string, string> = {};
    const keys = Object.keys(values); let size = 0;
    if (keys.length > 64) { throw new Error('AI_SOURCE_HEADERS_INVALID'); }
    for (const key of keys) {
      const value = values[key];
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key) || typeof value !== 'string' || /[\r\n\u0000]/.test(value)) {
        throw new Error('AI_SOURCE_HEADERS_INVALID');
      }
      size += key.length + value.length;
      if (size > 16384) { throw new Error('AI_SOURCE_HEADERS_INVALID'); }
      if (['range', 'accept-encoding', 'host', 'connection', 'content-length', 'transfer-encoding'].indexOf(key.toLowerCase()) < 0) {
        result[key] = value;
      }
    }
    result['Range'] = 'bytes=' + start.toString() + '-' + end.toString();
    result['Accept-Encoding'] = 'identity'; return result;
  }
  static parseChunk(response: AiRangeResponse, start: number, end: number, total: number): AiRangeChunk {
    const fields = response.header as Record<string, string>; const lower: Record<string, string> = {};
    for (const key of Object.keys(fields)) { lower[key.toLowerCase()] = String(fields[key]); }
    const contentRange = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec((lower['content-range'] || '').trim());
    if (response.responseCode !== 206 || contentRange === null || !(response.result instanceof ArrayBuffer)
      || /json|html|mpegurl/i.test(lower['content-type'] || '')
      || ((lower['content-encoding'] || '').length > 0 && lower['content-encoding'].toLowerCase() !== 'identity')) {
      throw new Error(response.responseCode === 401 || response.responseCode === 403 ? 'AI_SOURCE_AUTHENTICATION_FAILED' : 'AI_SOURCE_RANGE_REQUIRED');
    }
    const chunk = new AiRangeChunk(); chunk.start = Number(contentRange[1]); chunk.end = Number(contentRange[2]);
    chunk.total = Number(contentRange[3]); chunk.data = response.result as ArrayBuffer;
    if (!Number.isSafeInteger(chunk.start) || !Number.isSafeInteger(chunk.end) || !Number.isSafeInteger(chunk.total)
      || chunk.total <= 0 || chunk.start !== start || chunk.end < start || chunk.end > end || chunk.end >= chunk.total
      || chunk.data.byteLength !== chunk.end - chunk.start + 1 || chunk.data.byteLength > AiSourceBridge.CHUNK
      || (total > 0 && chunk.total !== total)) { throw new Error('AI_SOURCE_RANGE_MISMATCH'); }
    return chunk;
  }
  private alive(generation: number): boolean { return !this.closed && generation === this.generation && Date.now() < this.deadline; }
  private check(generation: number): void { if (!this.alive(generation)) { throw new Error('EXTRACTION_CANCELLED'); } }
  errorCode(): string { return this.failure; }
  async start(source: string, headers: Record<string, string>): Promise<string> {
    if (!AiSourceBridge.validSource(source)) { throw new Error('AI_SOURCE_UNSUPPORTED'); }
    const closing = this.generation + 1; await this.close();
    if (closing !== this.generation) { throw new Error('EXTRACTION_CANCELLED'); }
    const generation = ++this.generation; this.closed = false; this.source = source;
    this.headers = AiSourceBridge.requestHeaders(headers, 0, 0); this.total = 0; this.bytes = 0; this.requestsMade = 0;
    this.failure = ''; this.deadline = Date.now() + 25000;
    const random = cryptoFramework.createRandom().generateRandomSync(24).data; let token = '';
    for (const byte of random) { token += byte.toString(16).padStart(2, '0'); }
    this.path = '/ai/' + token + '/source';
    const server = socket.constructTCPSocketServerInstance(); this.server = server;
    this.timer = setTimeout(() => { if (generation === this.generation) { this.failure = 'EXTRACTION_TIMEOUT'; this.close(); } }, 25000);
    try {
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        if (!this.alive(generation) || this.clients.length >= 2) { connection.close().catch(() => {}); return; }
        this.accept(connection, generation);
      });
      await server.listen({ address: '127.0.0.1', port: 0, family: 1 }); this.check(generation);
      const local = await server.getLocalAddress(); this.check(generation);
      if (local.port === undefined || local.port < 1) { throw new Error('AI_SOURCE_BRIDGE_UNAVAILABLE'); }
      return 'http://127.0.0.1:' + local.port.toString() + this.path;
    } catch (error) {
      if (generation === this.generation) { await this.close(); } else { await server.close().catch(() => {}); }
      throw new Error('AI_SOURCE_BRIDGE_UNAVAILABLE');
    }
  }
  async close(): Promise<void> {
    this.closed = true; this.generation++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    for (const request of this.requests) { try { request.destroy(); } catch (error) {} }
    this.requests = [];
    for (const client of this.clients.slice()) { this.remove(client); }
    const server = this.server; this.server = null; this.source = ''; this.headers = {}; this.path = '';
    if (server !== null) { await server.close().catch(() => {}); }
  }
  private remove(client: AiBridgeClient): void {
    if (!client.alive) { return; } client.alive = false;
    if (client.timer >= 0) { clearTimeout(client.timer); client.timer = -1; }
    if (client.cancel !== null) { const cancel = client.cancel; client.cancel = null; cancel('EXTRACTION_CANCELLED'); }
    if (client.request !== null) { try { client.request.destroy(); } catch (error) {} client.request = null; }
    const index = this.clients.indexOf(client); if (index >= 0) { this.clients.splice(index, 1); }
    client.connection.close().catch(() => {});
  }
  private accept(connection: socket.TCPSocketConnection, generation: number): void {
    const client = new AiBridgeClient(connection); this.clients.push(client);
    client.timer = setTimeout(() => { this.remove(client); }, 5000);
    connection.on('close', () => { this.remove(client); }); connection.on('error', () => { this.remove(client); });
    connection.on('message', (info: socket.SocketMessageInfo) => {
      if (!this.alive(generation) || !client.alive || client.busy) { return; }
      for (const byte of new Uint8Array(info.message)) {
        client.header += String.fromCharCode(byte); if (client.header.length > 8192) { this.remove(client); return; }
      }
      if (client.header.indexOf('\r\n\r\n') < 0) { return; }
      clearTimeout(client.timer); client.timer = -1; client.busy = true;
      this.serve(client, generation).catch((error: Error) => {
        if (this.alive(generation) && client.alive) {
          this.failure = /^AI_SOURCE_|^SOURCE_READ_BUDGET|^EXTRACTION_/.test(error.message) ? error.message : 'AI_SOURCE_NETWORK_FAILED';
          client.connection.send({ data: 'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' })
            .then(() => { this.remove(client); }, () => { this.remove(client); });
        } else { this.remove(client); }
      });
    });
  }
  private async serve(client: AiBridgeClient, generation: number): Promise<void> {
    this.check(generation); const lines = client.header.split('\r\n'); const first = lines[0].split(' ');
    if (first.length !== 3 || first[0] !== 'GET' || first[1] !== this.path) { this.remove(client); return; }
    const ranges: string[] = [];
    for (const line of lines.slice(1)) { const colon = line.indexOf(':'); if (colon > 0 && line.substring(0, colon).trim().toLowerCase() === 'range') { ranges.push(line.substring(colon + 1).trim()); } }
    const match = ranges.length === 1 ? /^bytes=(\d+)-(\d+)$/.exec(ranges[0]) : null;
    if (match === null) { throw new Error('AI_SOURCE_RANGE_REQUIRED'); }
    const start = Number(match[1]), end = Number(match[2]);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end - start + 1 > AiSourceBridge.CHUNK) {
      throw new Error('AI_SOURCE_RANGE_MISMATCH');
    }
    const chunk = await this.fetch(start, end, client, generation); this.check(generation); if (!client.alive) { return; }
    await client.connection.send({ data: 'HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Length: '
      + chunk.data.byteLength.toString() + '\r\nContent-Range: bytes ' + chunk.start.toString() + '-' + chunk.end.toString() + '/'
      + chunk.total.toString() + '\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' });
    this.check(generation); if (!client.alive) { return; }
    await client.connection.send({ data: chunk.data }); this.remove(client);
  }
  private async fetch(start: number, end: number, client: AiBridgeClient, generation: number): Promise<AiRangeChunk> {
    this.check(generation);
    if (++this.requestsMade > 256 || this.bytes + end - start + 1 > AiSourceBridge.BUDGET) { throw new Error('SOURCE_READ_BUDGET_EXCEEDED'); }
    const request = http.createHttp(); client.request = request; this.requests.push(request);
    try {
      const response = await new Promise<AiRangeResponse>((resolve, reject) => {
        let fields: Record<string, string> = {}; const parts: Uint8Array[] = [];
        let received = 0; let code = -1; let ended = false; let settled = false; let validHeaders = false;
        const fail = (message: string): void => {
          if (settled) { return; } settled = true; try { request.destroy(); } catch (error) {}
          reject(new Error(message));
        };
        client.cancel = fail;
        const finish = (): void => {
          if (settled || code < 0 || !ended) { return; }
          if (code !== 206 || !validHeaders) { fail(code === 401 || code === 403 ? 'AI_SOURCE_AUTHENTICATION_FAILED' : 'AI_SOURCE_RANGE_REQUIRED'); return; }
          const data = new Uint8Array(received); let offset = 0;
          for (const part of parts) { data.set(part, offset); offset += part.length; }
          settled = true;
          resolve({ responseCode: code, header: fields, result: data.buffer as ArrayBuffer });
        };
        request.on('headersReceive', (value: Object) => {
          if (settled) { return; } fields = value as Record<string, string>;
          const lower: Record<string, string> = {};
          let size = 0; for (const key of Object.keys(fields)) { lower[key.toLowerCase()] = String(fields[key]); size += key.length + String(fields[key]).length; }
          if (size > 32768) { fail('AI_SOURCE_HEADERS_INVALID'); return; }
          const status = /^HTTP\/\S+\s+(\d+)/i.exec(lower['status-line'] || '');
          if (status !== null && Number(status[1]) >= 100 && Number(status[1]) < 200) { return; }
          if (!/^bytes\s+\d+-\d+\/\d+$/i.test((lower['content-range'] || '').trim())
            || /json|html|mpegurl/i.test(lower['content-type'] || '')
            || ((lower['content-encoding'] || '').length > 0 && lower['content-encoding'].toLowerCase() !== 'identity')) {
            fail(status !== null && [401, 403].indexOf(Number(status[1])) >= 0 ? 'AI_SOURCE_AUTHENTICATION_FAILED' : 'AI_SOURCE_RANGE_REQUIRED'); return;
          }
          validHeaders = true;
        });
        request.on('dataReceive', (data: ArrayBuffer) => {
          if (settled) { return; }
          if (!this.alive(generation) || !client.alive) { fail('EXTRACTION_CANCELLED'); return; }
          if (!validHeaders) { fail('AI_SOURCE_RANGE_REQUIRED'); return; }
          received += data.byteLength;
          if (received > end - start + 1 || received > AiSourceBridge.CHUNK || this.bytes + data.byteLength > AiSourceBridge.BUDGET) {
            fail('SOURCE_READ_BUDGET_EXCEEDED'); return;
          }
          this.bytes += data.byteLength;
          // Account each accepted stream event synchronously across all clients.
          // Copy only the bounded current range; no accumulated movie buffer.
          parts.push(new Uint8Array(data.slice(0)));
        });
        request.on('dataEnd', () => { ended = true; finish(); });
        request.requestInStream(this.source, { method: http.RequestMethod.GET,
          header: AiSourceBridge.requestHeaders(this.headers, start, end), usingCache: false, maxRedirects: 0,
          connectTimeout: Math.max(1, Math.min(8000, this.deadline - Date.now())),
          readTimeout: Math.max(1, Math.min(10000, this.deadline - Date.now())) }).then((status: number) => {
            code = status;
            if (status !== 206) { fail(status === 401 || status === 403 ? 'AI_SOURCE_AUTHENTICATION_FAILED' : 'AI_SOURCE_RANGE_REQUIRED'); }
            else { finish(); }
          }, () => { fail(this.alive(generation) ? 'AI_SOURCE_NETWORK_FAILED' : 'EXTRACTION_CANCELLED'); });
      });
      this.check(generation); if (!client.alive) { throw new Error('EXTRACTION_CANCELLED'); }
      const chunk = AiSourceBridge.parseChunk(response, start, end, this.total);
      this.total = chunk.total; return chunk;
    } catch (error) {
      if (this.failure.length > 0) { throw new Error(this.failure); }
      if (!this.alive(generation)) { throw new Error('EXTRACTION_CANCELLED'); }
      const message = (error as Error).message;
      throw new Error(/^AI_SOURCE_|^SOURCE_READ_BUDGET/.test(message) ? message : 'AI_SOURCE_NETWORK_FAILED');
    } finally {
      const index = this.requests.indexOf(request); if (index >= 0) { this.requests.splice(index, 1); }
      if (client.request === request) { client.request = null; }
      client.cancel = null;
      try { request.destroy(); } catch (error) {}
    }
  }
}
