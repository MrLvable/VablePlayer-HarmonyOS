import { http, socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class RangeStreamStats {
  totalBytes: number = 0;
  upstreamBytes: number = 0;
  servedBytes: number = 0;
  upstreamRequests: number = 0;
  clientRequests: number = 0;
  activeClients: number = 0;
  failures: number = 0;
}

class ProxyChunk {
  start: number = 0;
  end: number = 0;
  total: number = 0;
  contentType: string = '';
  data: ArrayBuffer = new ArrayBuffer(0);
}

class ProxyClient {
  connection: socket.TCPSocketConnection;
  header: string = '';
  busy: boolean = false;
  alive: boolean = true;
  request: http.HttpRequest | null = null;

  constructor(connection: socket.TCPSocketConnection) {
    this.connection = connection;
  }
}

/**
 * A loopback HTTP bridge for authenticated, seekable media. Each upstream read is
 * bounded to 1 MiB; bytes are sent immediately and no complete-file cache is made.
 * AVPlayer owns HTTP buffering and can open a new Range connection when seeking.
 */
export class RangeStreamProxy {
  private server: socket.TCPSocketServer | null = null;
  private clients: ProxyClient[] = [];
  private requests: http.HttpRequest[] = [];
  private generation: number = 0;
  private closed: boolean = true;
  private sourceUrl: string = '';
  private authToken: string = '';
  private total: number = 0;
  private mime: string = 'application/octet-stream';
  private path: string = '';
  private probe: ProxyChunk | null = null;
  private stats: RangeStreamStats = new RangeStreamStats();

  get fetchedBytes(): number {
    return this.stats.upstreamBytes;
  }

  get sourceSize(): number {
    return this.total;
  }

  getStats(): RangeStreamStats {
    const copy = new RangeStreamStats();
    copy.totalBytes = this.total;
    copy.upstreamBytes = this.stats.upstreamBytes;
    copy.servedBytes = this.stats.servedBytes;
    copy.upstreamRequests = this.stats.upstreamRequests;
    copy.clientRequests = this.stats.clientRequests;
    copy.activeClients = this.clients.length;
    copy.failures = this.stats.failures;
    return copy;
  }

  async start(url: string, token: string): Promise<string> {
    const closeGeneration = this.generation + 1;
    await this.close();
    // close() yields even for a fresh instance. A route exit or newer start in
    // that microtask gap must cancel this start before it can open resources.
    if (this.generation !== closeGeneration) {
      throw new Error('媒体流连接已取消');
    }
    const gen = ++this.generation;
    this.closed = false;
    this.sourceUrl = url;
    this.authToken = token;
    this.total = 0;
    this.stats = new RangeStreamStats();
    let startedServer: socket.TCPSocketServer | null = null;
    try {
      const probe = await this.fetchChunk(0, 65535, gen, null);
      this.assertAlive(gen);
      this.probe = probe;
      this.total = probe.total;
      const suffix = this.detectFormat(probe);
      this.path = '/media-' + Date.now().toString() + '-'
        + Math.floor(Math.random() * 1000000000).toString() + suffix;
      const server = socket.constructTCPSocketServerInstance();
      startedServer = server;
      this.server = server;
      await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
      this.assertAlive(gen);
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        if (!this.isAlive(gen) || this.clients.length >= 8) {
          connection.close().catch(() => {});
          return;
        }
        this.accept(connection, gen);
      });
      const address = await server.getLocalAddress();
      this.assertAlive(gen);
      const port = address.port;
      if (port === undefined || port <= 0) {
        throw new Error('loopback port unavailable');
      }
      hilog.info(0x0001, 'NasStream', 'ready total=%{public}d probe=%{public}d mime=%{public}s',
        this.total, probe.data.byteLength, this.mime);
      return 'http://127.0.0.1:' + port.toString() + this.path;
    } catch (e) {
      // A stale start must never close a newer playback session.
      if (this.generation === gen) {
        await this.close();
      } else if (startedServer !== null) {
        // listen() may finish after close() tried to stop its not-yet-bound
        // socket. Dispose this start's own server without touching a newer one.
        await startedServer.close().catch(() => {});
      }
      throw new Error('无法建立媒体流连接');
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    this.generation++;
    const requests = this.requests.slice();
    this.requests = [];
    for (let i = 0; i < requests.length; i++) {
      try {
        requests[i].destroy();
      } catch (e) {}
    }
    const clients = this.clients.slice();
    this.clients = [];
    const closing: Promise<void>[] = [];
    for (let i = 0; i < clients.length; i++) {
      clients[i].alive = false;
      closing.push(clients[i].connection.close().catch(() => {}));
    }
    const server = this.server;
    this.server = null;
    this.sourceUrl = '';
    this.authToken = '';
    this.probe = null;
    if (server !== null) {
      closing.push(server.close().catch(() => {}));
    }
    await Promise.all(closing);
  }

  private isAlive(gen: number): boolean {
    return !this.closed && gen === this.generation;
  }

  private assertAlive(gen: number): void {
    if (!this.isAlive(gen)) {
      throw new Error('stream closed');
    }
  }

  private accept(connection: socket.TCPSocketConnection, gen: number): void {
    const client = new ProxyClient(connection);
    this.clients.push(client);
    connection.on('close', () => { this.removeClient(client); });
    connection.on('error', () => { this.removeClient(client); });
    connection.on('message', (info: socket.SocketMessageInfo) => {
      if (!client.alive || client.busy || !this.isAlive(gen)) {
        return;
      }
      const bytes = new Uint8Array(info.message);
      for (let i = 0; i < bytes.length; i++) {
        client.header += String.fromCharCode(bytes[i]);
        if (client.header.length > 16384) {
          this.removeClient(client);
          return;
        }
      }
      if (client.header.indexOf('\r\n\r\n') < 0) {
        return;
      }
      client.busy = true;
      this.serve(client, gen).catch(() => {
        if (this.isAlive(gen) && client.alive) {
          this.stats.failures++;
          hilog.warn(0x0001, 'NasStream', 'client transfer stopped');
        }
        this.removeClient(client);
      });
    });
  }

  private removeClient(client: ProxyClient): void {
    if (!client.alive) {
      return;
    }
    client.alive = false;
    if (client.request !== null) {
      try {
        client.request.destroy();
      } catch (e) {}
      client.request = null;
    }
    const index = this.clients.indexOf(client);
    if (index >= 0) {
      this.clients.splice(index, 1);
    }
    client.connection.close().catch(() => {});
  }

  private async replyError(client: ProxyClient, status: string, extra: string = ''): Promise<void> {
    await client.connection.send({ data: 'HTTP/1.1 ' + status + '\r\n'
      + extra + 'Content-Length: 0\r\nConnection: close\r\n\r\n' });
    this.removeClient(client);
  }

  private async serve(client: ProxyClient, gen: number): Promise<void> {
    this.assertAlive(gen);
    const lines = client.header.split('\r\n');
    const first = lines[0].split(' ');
    if (first.length < 3 || first[1] !== this.path) {
      await this.replyError(client, '404 Not Found');
      return;
    }
    const method = first[0];
    if (method !== 'GET' && method !== 'HEAD') {
      await this.replyError(client, '405 Method Not Allowed', 'Allow: GET, HEAD\r\n');
      return;
    }
    let range = '';
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(':');
      if (colon > 0 && lines[i].substring(0, colon).trim().toLowerCase() === 'range') {
        range = lines[i].substring(colon + 1).trim();
      }
    }
    let start = 0;
    let end = this.total - 1;
    const partial = range.length > 0;
    if (partial) {
      const match = /^bytes=(\d*)-(\d*)$/i.exec(range);
      if (match === null || (match[1].length === 0 && match[2].length === 0)) {
        await this.replyError(client, '416 Range Not Satisfiable',
          'Content-Range: bytes */' + this.total.toString() + '\r\n');
        return;
      }
      if (match[1].length === 0) {
        const suffix = Number(match[2]);
        start = Math.max(0, this.total - suffix);
        if (!Number.isSafeInteger(suffix) || suffix <= 0) {
          start = this.total;
        }
      } else {
        start = Number(match[1]);
        if (match[2].length > 0) {
          end = Math.min(end, Number(match[2]));
        }
      }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)
        || start < 0 || start >= this.total || end < start) {
        await this.replyError(client, '416 Range Not Satisfiable',
          'Content-Range: bytes */' + this.total.toString() + '\r\n');
        return;
      }
    }
    this.stats.clientRequests++;
    hilog.info(0x0001, 'NasStream', 'request #%{public}d %{public}s range=%{public}d-%{public}d total=%{public}d',
      this.stats.clientRequests, method, start, end, this.total);
    let headers = 'HTTP/1.1 ' + (partial ? '206 Partial Content' : '200 OK') + '\r\n'
      + 'Content-Type: ' + this.mime + '\r\nAccept-Ranges: bytes\r\n'
      + 'Content-Length: ' + (end - start + 1).toString() + '\r\n'
      + 'Cache-Control: no-store\r\nConnection: close\r\n';
    if (partial) {
      headers += 'Content-Range: bytes ' + start.toString() + '-' + end.toString()
        + '/' + this.total.toString() + '\r\n';
    }
    await client.connection.send({ data: headers + '\r\n' });
    if (method === 'HEAD') {
      this.removeClient(client);
      return;
    }
    let position = start;
    while (position <= end && client.alive && this.isAlive(gen)) {
      let data: ArrayBuffer;
      const probe = this.probe;
      if (probe !== null && position >= probe.start && position <= probe.end) {
        const count = Math.min(probe.end - position + 1, end - position + 1);
        data = probe.data.slice(position - probe.start, position - probe.start + count);
      } else {
        const chunkEnd = Math.min(position + 1048576 - 1, end);
        const chunk = await this.fetchChunk(position, chunkEnd, gen, client);
        data = chunk.data;
      }
      this.assertAlive(gen);
      if (!client.alive) {
        return;
      }
      // Await each write so an open-ended media request cannot queue the whole
      // source in JavaScript memory. Closing the player also destroys its read.
      await client.connection.send({ data: data });
      position += data.byteLength;
      this.stats.servedBytes += data.byteLength;
    }
    hilog.info(0x0001, 'NasStream', 'served=%{public}d fetched=%{public}d total=%{public}d',
      this.stats.servedBytes, this.stats.upstreamBytes, this.total);
    this.removeClient(client);
  }

  private async fetchChunk(start: number, end: number, gen: number,
    client: ProxyClient | null): Promise<ProxyChunk> {
    this.assertAlive(gen);
    if (client !== null && !client.alive) {
      throw new Error('client closed');
    }
    const request = http.createHttp();
    this.requests.push(request);
    if (client !== null) {
      client.request = request;
    }
    try {
      const headers: Record<string, string> = {
        'Range': 'bytes=' + start.toString() + '-' + end.toString(),
        'Accept-Encoding': 'identity'
      };
      if (this.authToken.length > 0) {
        headers['Authorization'] = this.authToken;
        headers['X-Emby-Token'] = this.authToken;
      }
      this.stats.upstreamRequests++;
      const response = await request.request(this.sourceUrl, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: 15000,
        readTimeout: 20000,
        maxLimit: 2 * 1048576
      });
      this.assertAlive(gen);
      if (client !== null && !client.alive) {
        throw new Error('client closed');
      }
      const responseHeaders = response.header as Record<string, string>;
      const keys = Object.keys(responseHeaders);
      let contentRange = '';
      let contentType = '';
      let encoding = '';
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i].toLowerCase();
        if (key === 'content-range') {
          contentRange = responseHeaders[keys[i]];
        } else if (key === 'content-type') {
          contentType = responseHeaders[keys[i]].toLowerCase();
        } else if (key === 'content-encoding') {
          encoding = responseHeaders[keys[i]].toLowerCase();
        }
      }
      const match = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec(contentRange.trim());
      if (response.responseCode !== 206 || match === null || contentType.indexOf('json') >= 0
        || contentType.indexOf('html') >= 0 || (encoding.length > 0 && encoding !== 'identity')) {
        throw new Error('invalid media range response');
      }
      const chunk = new ProxyChunk();
      chunk.start = Number(match[1]);
      chunk.end = Number(match[2]);
      chunk.total = Number(match[3]);
      chunk.contentType = contentType;
      chunk.data = response.result as ArrayBuffer;
      if (!Number.isSafeInteger(chunk.total) || chunk.total <= 0 || chunk.start !== start
        || chunk.end < start || chunk.end > end || chunk.end >= chunk.total
        || chunk.data.byteLength !== chunk.end - chunk.start + 1
        || (this.total > 0 && chunk.total !== this.total)) {
        throw new Error('media range mismatch');
      }
      this.stats.upstreamBytes += chunk.data.byteLength;
      return chunk;
    } finally {
      if (client !== null && client.request === request) {
        client.request = null;
      }
      const index = this.requests.indexOf(request);
      if (index >= 0) {
        this.requests.splice(index, 1);
      }
      try {
        request.destroy();
      } catch (e) {}
    }
  }

  private detectFormat(chunk: ProxyChunk): string {
    const bytes = new Uint8Array(chunk.data);
    if (bytes.length >= 4 && bytes[0] === 0x1A && bytes[1] === 0x45
      && bytes[2] === 0xDF && bytes[3] === 0xA3) {
      this.mime = 'video/x-matroska';
      return '.mkv';
    }
    if (bytes.length >= 8 && bytes[4] === 0x66 && bytes[5] === 0x74
      && bytes[6] === 0x79 && bytes[7] === 0x70) {
      this.mime = 'video/mp4';
      return '.mp4';
    }
    if (bytes.length > 188 && bytes[0] === 0x47 && bytes[188] === 0x47) {
      this.mime = 'video/mp2t';
      return '.ts';
    }
    this.mime = chunk.contentType.startsWith('video/') || chunk.contentType.startsWith('audio/')
      ? chunk.contentType.split(';')[0] : 'application/octet-stream';
    return '.bin';
  }
}
