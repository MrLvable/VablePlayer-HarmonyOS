import { http } from '@kit.NetworkKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RANGE_BLOCK: number = 1048576;
const RANGE_CACHE_BLOCKS: number = 32;

class MemoryRange {
  start: number = 0;
  data: Uint8Array = new Uint8Array(0);
  used: number = 0;
  pinned: boolean = false;
}

class DataRange {
  start: number = 0;
  end: number = 0;
  total: number = 0;
  data: ArrayBuffer = new ArrayBuffer(0);
}

export class RangeDataSourceStats {
  fetchedBytes: number = 0;
  totalBytes: number = 0;
  requests: number = 0;
  misses: number = 0;
  readCalls: number = 0;
  cachedBytes: number = 0;
  failed: boolean = false;
}

/** Plain state retained by the synchronous media callback, never an ArkUI component. */
class RangeReaderState {
  closed: boolean = false;
  failed: boolean = false;
  total: number = 0;
  blocks: MemoryRange[] = [];
  pending: number[] = [];
  inflight: number[] = [];
  currentBlock: number = -1;
  clock: number = 0;
  stats: RangeDataSourceStats = new RangeDataSourceStats();
}

/** Official AVDataSrcDescriptor path with bounded, demand-driven memory reads. */
export class RangeDataSource {
  private generation: number = 0;
  private state: RangeReaderState | null = null;
  private url: string = '';
  private token: string = '';
  private requests: http.HttpRequest[] = [];
  private scheduler: number = -1;

  async start(url: string, token: string): Promise<media.AVDataSrcDescriptor> {
    const closeGeneration = this.generation + 1;
    await this.close();
    if (this.generation !== closeGeneration) {
      throw new Error('媒体数据源已取消');
    }
    const gen = ++this.generation;
    const state = new RangeReaderState();
    this.state = state;
    this.url = url;
    this.token = token;
    try {
      const head = await this.fetchRange(0, 2 * RANGE_BLOCK - 1, gen, state);
      this.assertAlive(gen, state);
      state.total = head.total;
      state.stats.totalBytes = head.total;
      this.commit(state, head, true);
      // MKV cues can be at the end. Fetch only this small tail, never the body.
      const tailStart = Math.max(0, Math.floor((state.total - 2 * RANGE_BLOCK) / RANGE_BLOCK) * RANGE_BLOCK);
      if (tailStart > head.end) {
        const tail = await this.fetchRange(tailStart, state.total - 1, gen, state);
        this.assertAlive(gen, state);
        this.commit(state, tail, true);
      } else if (head.end < state.total - 1) {
        const tail = await this.fetchRange(head.end + 1, state.total - 1, gen, state);
        this.assertAlive(gen, state);
        this.commit(state, tail, true);
      }
      this.scheduler = setInterval(() => { this.pump(gen, state); }, 20);
      const descriptor: media.AVDataSrcDescriptor = {
        fileSize: state.total,
        callback: (buffer: ArrayBuffer, length: number, pos?: number): number => {
          return RangeDataSource.read(state, buffer, length, pos);
        }
      };
      hilog.info(0x0001, 'NasData', 'ready total=%{public}d fetched=%{public}d blocks=%{public}d',
        state.total, state.stats.fetchedBytes, state.blocks.length);
      return descriptor;
    } catch (e) {
      if (gen === this.generation) { await this.close(); }
      throw new Error('无法建立边播边取媒体数据源');
    }
  }

  async close(): Promise<void> {
    this.generation++;
    const state = this.state;
    if (state !== null) {
      state.closed = true;
      state.pending = [];
      state.blocks = [];
    }
    if (this.scheduler >= 0) {
      clearInterval(this.scheduler);
      this.scheduler = -1;
    }
    const requests = this.requests.slice();
    this.requests = [];
    for (let i = 0; i < requests.length; i++) {
      try { requests[i].destroy(); } catch (e) {}
    }
    this.url = '';
    this.token = '';
  }

  getStats(): RangeDataSourceStats {
    const result = new RangeDataSourceStats();
    const state = this.state;
    if (state === null) { return result; }
    result.fetchedBytes = state.stats.fetchedBytes;
    result.totalBytes = state.total;
    result.requests = state.stats.requests;
    result.misses = state.stats.misses;
    result.readCalls = state.stats.readCalls;
    result.failed = state.failed;
    for (let i = 0; i < state.blocks.length; i++) {
      result.cachedBytes += state.blocks[i].data.byteLength;
    }
    return result;
  }

  private alive(gen: number, state: RangeReaderState): boolean {
    return gen === this.generation && this.state === state && !state.closed;
  }

  private assertAlive(gen: number, state: RangeReaderState): void {
    if (!this.alive(gen, state)) { throw new Error('data source closed'); }
  }

  private static find(state: RangeReaderState, position: number): MemoryRange | null {
    for (let i = 0; i < state.blocks.length; i++) {
      const block = state.blocks[i];
      if (position >= block.start && position < block.start + block.data.length) { return block; }
    }
    return null;
  }

  private static enqueue(state: RangeReaderState, position: number): void {
    const start = Math.floor(position / RANGE_BLOCK) * RANGE_BLOCK;
    if (start < 0 || start >= state.total || state.pending.indexOf(start) >= 0
      || state.inflight.indexOf(start) >= 0) { return; }
    state.pending.unshift(start);
    if (state.pending.length > 32) { state.pending.length = 32; }
  }

  private static read(state: RangeReaderState, buffer: ArrayBuffer,
    length: number, position?: number): number {
    state.stats.readCalls++;
    if (state.closed || state.failed) { return -2; }
    if (position === undefined || !Number.isSafeInteger(position) || position < 0 || length <= 0) { return -2; }
    if (position >= state.total) { return -1; }
    state.currentBlock = Math.floor(position / RANGE_BLOCK) * RANGE_BLOCK;
    const target = new Uint8Array(buffer);
    const wanted = Math.min(length, target.length, state.total - position);
    let copied = 0;
    while (copied < wanted) {
      const offset = position + copied;
      const block = RangeDataSource.find(state, offset);
      if (block === null) {
        state.stats.misses++;
        RangeDataSource.enqueue(state, offset);
        break;
      }
      const within = offset - block.start;
      const count = Math.min(wanted - copied, block.data.length - within);
      target.set(block.data.subarray(within, within + count), copied);
      block.used = ++state.clock;
      copied += count;
    }
    // 0 means no bytes available yet. -1 is reserved for the actual file end.
    // The scheduler handles network I/O; this callback never waits or allocates requests.
    return copied;
  }

  private pump(gen: number, state: RangeReaderState): void {
    if (!this.alive(gen, state) || state.failed) { return; }
    while (state.inflight.length < 2) {
      let next = -1;
      while (state.pending.length > 0) {
        const candidate = state.pending.shift();
        if (candidate !== undefined && RangeDataSource.find(state, candidate) === null
          && state.inflight.indexOf(candidate) < 0) {
          next = candidate;
          break;
        }
      }
      // Readahead follows the last position requested by AVPlayer, at most 8 MiB.
      if (next < 0 && state.currentBlock >= 0) {
        for (let i = 0; i <= 8; i++) {
          const candidate = state.currentBlock + i * RANGE_BLOCK;
          if (candidate < state.total && RangeDataSource.find(state, candidate) === null
            && state.inflight.indexOf(candidate) < 0) {
            next = candidate;
            break;
          }
        }
      }
      if (next < 0) { return; }
      state.inflight.push(next);
      this.loadBlock(next, gen, state).catch(() => {});
    }
  }

  private async loadBlock(start: number, gen: number, state: RangeReaderState): Promise<void> {
    try {
      let completed = false;
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const range = await this.fetchRange(start, Math.min(start + RANGE_BLOCK - 1, state.total - 1), gen, state);
          this.assertAlive(gen, state);
          this.commit(state, range, false);
          completed = true;
          break;
        } catch (e) {
          if (!this.alive(gen, state)) { return; }
        }
      }
      if (!completed && this.alive(gen, state)) {
        state.failed = true;
        hilog.warn(0x0001, 'NasData', 'range failed at=%{public}d', start);
      }
    } finally {
      const index = state.inflight.indexOf(start);
      if (index >= 0) { state.inflight.splice(index, 1); }
    }
  }

  private commit(state: RangeReaderState, range: DataRange, pinned: boolean): void {
    const bytes = new Uint8Array(range.data);
    let offset = 0;
    while (offset < bytes.length) {
      const start = range.start + offset;
      const count = Math.min(RANGE_BLOCK - start % RANGE_BLOCK, bytes.length - offset);
      const existing = RangeDataSource.find(state, start);
      if (existing === null) {
        const block = new MemoryRange();
        block.start = start;
        block.data = bytes.slice(offset, offset + count);
        block.pinned = pinned;
        block.used = ++state.clock;
        state.blocks.push(block);
      } else if (pinned) {
        existing.pinned = true;
      }
      offset += count;
    }
    while (state.blocks.length > RANGE_CACHE_BLOCKS) {
      let oldest = -1;
      for (let i = 0; i < state.blocks.length; i++) {
        if (!state.blocks[i].pinned && (oldest < 0 || state.blocks[i].used < state.blocks[oldest].used)) { oldest = i; }
      }
      if (oldest < 0) { break; }
      state.blocks.splice(oldest, 1);
    }
  }

  private async fetchRange(start: number, end: number, gen: number,
    state: RangeReaderState): Promise<DataRange> {
    this.assertAlive(gen, state);
    const request = http.createHttp();
    this.requests.push(request);
    state.stats.requests++;
    try {
      const headers: Record<string, string> = {
        'Range': 'bytes=' + start.toString() + '-' + end.toString(), 'Accept-Encoding': 'identity'
      };
      if (this.token.length > 0) {
        headers['Authorization'] = this.token;
        headers['X-Emby-Token'] = this.token;
      }
      const response = await request.request(this.url, {
        method: http.RequestMethod.GET, header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, usingCache: false,
        connectTimeout: 12000, readTimeout: 15000, maxLimit: 4 * RANGE_BLOCK
      });
      this.assertAlive(gen, state);
      const responseHeaders = response.header as Record<string, string>;
      const keys = Object.keys(responseHeaders);
      let contentRange = '';
      let contentType = '';
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i].toLowerCase();
        if (key === 'content-range') { contentRange = responseHeaders[keys[i]]; }
        if (key === 'content-type') { contentType = responseHeaders[keys[i]].toLowerCase(); }
      }
      const match = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec(contentRange.trim());
      if (response.responseCode !== 206 || match === null || contentType.indexOf('json') >= 0
        || contentType.indexOf('html') >= 0) { throw new Error('invalid range response'); }
      const range = new DataRange();
      range.start = Number(match[1]);
      range.end = Number(match[2]);
      range.total = Number(match[3]);
      range.data = response.result as ArrayBuffer;
      if (!Number.isSafeInteger(range.total) || range.total <= 0 || range.start !== start
        || range.end !== Math.min(end, range.total - 1) || range.end < range.start
        || range.data.byteLength !== range.end - range.start + 1
        || (state.total > 0 && range.total !== state.total)) { throw new Error('range mismatch'); }
      state.stats.fetchedBytes += range.data.byteLength;
      return range;
    } finally {
      const index = this.requests.indexOf(request);
      if (index >= 0) { this.requests.splice(index, 1); }
      try { request.destroy(); } catch (e) {}
    }
  }
}
