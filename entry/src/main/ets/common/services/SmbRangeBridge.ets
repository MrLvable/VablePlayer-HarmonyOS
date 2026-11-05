import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ServerConfig } from '../Models';
import { SmbNative } from './SmbNative';

class SmbHttpClient {
  connection: socket.TCPSocketConnection;
  header: string = '';
  alive: boolean = true;
  busy: boolean = false;
  requestId: number = 0;
  timeout: number = -1;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}
export class SmbBridgeStats {
  totalBytes: number = 0;
  readBytes: number = 0;
  servedBytes: number = 0;
  readRequests: number = 0;
  clientRequests: number = 0;
}
/** Per-playback loopback service, 2 clients × 256KiB chunks; no whole-file cache. */
export class SmbRangeBridge {
  private server: socket.TCPSocketServer | null = null;
  private clients: SmbHttpClient[] = [];
  private generation: number = 0;
  private closed: boolean = true;
  private session: number = 0;
  private path: string = '';
  private total: number = 0;
  private mime: string = 'application/octet-stream';
  private stats: SmbBridgeStats = new SmbBridgeStats();

  private alive(gen: number): boolean { return !this.closed && this.generation === gen; }
  private assertAlive(gen: number): void { if (!this.alive(gen)) { throw new Error('SMB 播放连接已关闭'); } }
  getStats(): SmbBridgeStats {
    return { totalBytes: this.total, readBytes: this.stats.readBytes, servedBytes: this.stats.servedBytes,
      readRequests: this.stats.readRequests, clientRequests: this.stats.clientRequests };
  }
  async start(config: ServerConfig, filePath: string): Promise<string> {
    const closingGeneration = this.generation + 1;
    await this.close();
    if (this.generation !== closingGeneration) { throw new Error('SMB 播放请求已取消'); }
    const gen = ++this.generation;
    this.closed = false;
    let openedSession = 0;
    let ownServer: socket.TCPSocketServer | null = null;
    try {
      const opened = await SmbNative.open(config, filePath);
      openedSession = opened.sessionId;
      this.assertAlive(gen);
      if (!Number.isSafeInteger(opened.size) || opened.size <= 0) { throw new Error('SMB 文件为空或大小无效'); }
      this.session = openedSession; this.total = opened.size;
      this.stats = new SmbBridgeStats(); this.stats.totalBytes = opened.size;
      const bytes = cryptoFramework.createRandom().generateRandomSync(24).data;
      let token = '';
      for (let i = 0; i < bytes.length; i++) { token += bytes[i].toString(16).padStart(2, '0'); }
      const name = filePath.substring(filePath.lastIndexOf('/') + 1);
      this.path = '/smb/' + token + '/' + encodeURIComponent(name);
      const ext = name.substring(name.lastIndexOf('.') + 1).toLowerCase();
      this.mime = ext === 'mkv' ? 'video/x-matroska' : ext === 'mp4' || ext === 'm4v' ? 'video/mp4'
        : ext === 'webm' ? 'video/webm' : ext === 'ts' || ext === 'm2ts' ? 'video/mp2t' : 'application/octet-stream';
      const server = socket.constructTCPSocketServerInstance(); ownServer = server; this.server = server;
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        if (!this.alive(gen) || this.clients.length >= 2) { connection.close().catch(() => {}); return; }
        this.accept(connection, gen);
      });
      await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
      this.assertAlive(gen);
      const address = await server.getLocalAddress(); this.assertAlive(gen);
      if (address.port === undefined || address.port < 1) { throw new Error('SMB 本机流端口不可用'); }
      return 'http://127.0.0.1:' + address.port.toString() + this.path;
    } catch (e) {
      if (this.generation === gen) { await this.close(); }
      else if (ownServer !== null) { await ownServer.close().catch(() => {}); }
      // A close during open must dispose that open's own handle, not a newer generation.
      if (openedSession > 0 && openedSession !== this.session) { await SmbNative.close(openedSession).catch(() => {}); }
      throw (e as Error);
    }
  }
  async close(): Promise<void> {
    this.closed = true; this.generation++;
    const clients = this.clients.slice(); this.clients = [];
    const pending: Promise<void>[] = [];
    for (let i = 0; i < clients.length; i++) { this.remove(clients[i]); }
    const server = this.server; this.server = null;
    const session = this.session; this.session = 0; this.path = '';
    if (server !== null) { pending.push(server.close().catch(() => {})); }
    if (session > 0) { pending.push(SmbNative.close(session).catch(() => {})); }
    await Promise.all(pending);
  }
  private remove(client: SmbHttpClient): void {
    if (!client.alive) { return; }
    client.alive = false;
    if (client.timeout >= 0) { clearTimeout(client.timeout); client.timeout = -1; }
    if (client.requestId > 0) { SmbNative.cancel(client.requestId); client.requestId = 0; }
    const index = this.clients.indexOf(client); if (index >= 0) { this.clients.splice(index, 1); }
    client.connection.close().catch(() => {});
  }
  private accept(connection: socket.TCPSocketConnection, gen: number): void {
    const client = new SmbHttpClient(connection); this.clients.push(client);
    client.timeout = setTimeout(() => { this.remove(client); }, 5000);
    connection.on('close', () => { this.remove(client); });
    connection.on('error', () => { this.remove(client); });
    connection.on('message', (info: socket.SocketMessageInfo) => {
      if (!this.alive(gen) || !client.alive || client.busy) { return; }
      const bytes = new Uint8Array(info.message);
      for (let i = 0; i < bytes.length; i++) {
        client.header += String.fromCharCode(bytes[i]);
        if (client.header.length > 8192) { this.remove(client); return; }
      }
      if (client.header.indexOf('\r\n\r\n') < 0) { return; }
      clearTimeout(client.timeout); client.timeout = -1; client.busy = true;
      this.serve(client, gen).catch(() => { this.remove(client); });
    });
  }
  private async error(client: SmbHttpClient, status: string, extra: string = ''): Promise<void> {
    await client.connection.send({ data: 'HTTP/1.1 ' + status + '\r\n' + extra
      + 'Content-Length: 0\r\nConnection: close\r\n\r\n' });
    this.remove(client);
  }
  private async serve(client: SmbHttpClient, gen: number): Promise<void> {
    this.assertAlive(gen);
    const lines = client.header.split('\r\n'); const first = lines[0].split(' ');
    if (first.length !== 3 || first[1] !== this.path) { await this.error(client, '404 Not Found'); return; }
    const method = first[0];
    if (method !== 'GET' && method !== 'HEAD') { await this.error(client, '405 Method Not Allowed', 'Allow: GET, HEAD\r\n'); return; }
    let range = ''; let rangeCount = 0;
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(':');
      if (colon > 0 && lines[i].substring(0, colon).trim().toLowerCase() === 'range') {
        range = lines[i].substring(colon + 1).trim(); rangeCount++;
      }
    }
    let start = 0; let end = this.total - 1;
    const partial = rangeCount > 0;
    if (partial) {
      const match = /^bytes=(\d*)-(\d*)$/i.exec(range);
      if (rangeCount !== 1 || match === null || (match[1] === '' && match[2] === '')) {
        await this.error(client, '416 Range Not Satisfiable', 'Content-Range: bytes */' + this.total.toString() + '\r\n'); return;
      }
      if (match[1] === '') {
        const suffix = Number(match[2]);
        start = Number.isSafeInteger(suffix) && suffix > 0 ? Math.max(0, this.total - suffix) : this.total;
      } else {
        start = Number(match[1]);
        if (match[2] !== '') {
          const requestedEnd = Number(match[2]);
          end = Number.isSafeInteger(requestedEnd) ? Math.min(end, requestedEnd) : -1;
        }
      }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= this.total || end < start) {
        await this.error(client, '416 Range Not Satisfiable', 'Content-Range: bytes */' + this.total.toString() + '\r\n'); return;
      }
    }
    this.stats.clientRequests++;
    let headers = 'HTTP/1.1 ' + (partial ? '206 Partial Content' : '200 OK') + '\r\nContent-Type: ' + this.mime
      + '\r\nAccept-Ranges: bytes\r\nContent-Length: ' + (end - start + 1).toString()
      + '\r\nCache-Control: no-store\r\nConnection: close\r\n';
    if (partial) { headers += 'Content-Range: bytes ' + start.toString() + '-' + end.toString() + '/' + this.total.toString() + '\r\n'; }
    await client.connection.send({ data: headers + '\r\n' });
    if (method === 'HEAD') { this.remove(client); return; }
    let position = start;
    while (position <= end && this.alive(gen) && client.alive) {
      const count = Math.min(256 * 1024, end - position + 1);
      const requestId = SmbNative.requestId(); client.requestId = requestId;
      this.stats.readRequests++;
      const data = await SmbNative.read(this.session, position, count, requestId);
      if (client.requestId === requestId) { client.requestId = 0; }
      this.assertAlive(gen); if (!client.alive) { return; }
      if (data.byteLength < 1 || data.byteLength > count) { throw new Error('SMB 文件提前结束或读取范围无效'); }
      this.stats.readBytes += data.byteLength;
      await client.connection.send({ data: data });
      if (!this.alive(gen) || !client.alive) { return; }
      this.stats.servedBytes += data.byteLength; position += data.byteLength;
    }
    this.remove(client);
  }
}
