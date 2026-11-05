import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Store } from './Store';

/** 一条下载记录 */
export class DownloadRecord {
  itemId: string = '';
  title: string = '';
  subtitle: string = '';
  url: string = '';
  /** 取流需要的认证 token（飞牛用 Authorization 头） */
  authToken: string = '';
  /** Runtime-only negotiated headers; {} deliberately means no authentication. */
  headers: Record<string, string> | null = null;
  filePath: string = '';
  totalBytes: number = 0;
  receivedBytes: number = 0;
  state: number = 0;      // 0 等待 1 下载中 2 完成 3 失败
  error: string = '';

  progressRatio(): number {
    if (this.totalBytes <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, this.receivedBytes / this.totalBytes));
  }
}

class OfflineDownloadRecord {
  itemId: string = ''; title: string = ''; subtitle: string = ''; filePath: string = '';
  totalBytes: number = 0; receivedBytes: number = 0; state: number = DownloadState.DONE;
}

export class DownloadState {
  static readonly WAIT: number = 0;
  static readonly RUNNING: number = 1;
  static readonly DONE: number = 2;
  static readonly FAILED: number = 3;
}

/**
 * 下载管理器 —— 把影片存到本地，离线也能看
 *
 * 用 @ohos.request 的 downloadFile，支持断点续传
 */
export class DownloadManager {
  private static tasks: Map<string, request.DownloadTask> = new Map<string, request.DownloadTask>();
  private static starting: Set<string> = new Set<string>();
  private static records: DownloadRecord[] = [];
  private static readonly RECORDS_KEY: string = 'download_records';

  /** 下载目录 */
  static dir(context: common.UIAbilityContext): string {
    const d = context.filesDir + '/downloads';
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d);
      }
    } catch (e) {
      // 忽略
    }
    return d;
  }

  /** 本地文件路径 */
  static localPath(context: common.UIAbilityContext, itemId: string): string {
    if (!DownloadManager.safeItemId(itemId)) { throw new Error('下载文件标识无效'); }
    return DownloadManager.dir(context) + '/' + itemId + '.mp4';
  }

  private static safeItemId(itemId: string): boolean {
    // Keep old opaque IDs at the same paths; new URL/path IDs are hashed by the caller.
    return typeof itemId === 'string' && /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,191}$/.test(itemId)
      && itemId !== '.' && itemId !== '..';
  }

  /** 是否已下载 */
  /**
   * 是否已下载完成（方案 R05/A8）。
   * ★ 旧实现只看「最终路径的 exists」—— 失败/中断留下的残片会被当 DONE，
   *   下次点播放直接命中这个残片。
   *   现在只有经过校验并 rename 成 .ready 的文件才算完成。
   */
  static isDownloaded(context: common.UIAbilityContext, itemId: string): boolean {
    if (!DownloadManager.safeItemId(itemId)) { return false; }
    return DownloadManager.isReadyFile(DownloadManager.readyPath(context, itemId));
  }

  /**
   * 恢复已完成下载。应用重启后系统下载任务不再存在，因此只恢复
   * 已发布为 .ready 的文件；.part 一律视为未完成。
   */
  static async restore(context: common.UIAbilityContext): Promise<DownloadRecord[]> {
    const out: DownloadRecord[] = [];
    try {
      const raw = await Store.get(DownloadManager.RECORDS_KEY, '[]');
      const saved = JSON.parse(raw) as DownloadRecord[];
      if (!Array.isArray(saved)) { return []; }
      for (let i = 0; i < saved.length; i++) {
        const savedRecord = saved[i];
        if (savedRecord === null || !DownloadManager.safeItemId(savedRecord.itemId)) { continue; }
        const rec = DownloadManager.offlineCopy(savedRecord);
        if (!DownloadManager.isDownloaded(context, rec.itemId)) {
          continue;
        }
        const ready = DownloadManager.readyPath(context, rec.itemId);
        rec.filePath = ready;
        rec.state = DownloadState.DONE;
        rec.error = '';
        try {
          rec.totalBytes = fs.statSync(ready).size;
          rec.receivedBytes = rec.totalBytes;
        } catch (e0) {
        }
        out.push(rec);
      }
    } catch (e) {
      return [];
    }
    DownloadManager.records = out;
    // Rewrite legacy snapshots too, removing old signed URLs/tokens on restore.
    DownloadManager.persistOffline();
    return out;
  }

  private static offlineCopy(rec: DownloadRecord): DownloadRecord {
    const clean = new DownloadRecord(); clean.itemId = rec.itemId;
    clean.title = typeof rec.title === 'string' ? rec.title : '';
    clean.subtitle = typeof rec.subtitle === 'string' ? rec.subtitle : '';
    clean.filePath = rec.filePath; clean.totalBytes = rec.totalBytes; clean.receivedBytes = rec.receivedBytes;
    clean.state = DownloadState.DONE; return clean;
  }

  private static persistOffline(): void {
    const snapshots: OfflineDownloadRecord[] = [];
    for (let i = 0; i < DownloadManager.records.length; i++) {
      const rec = DownloadManager.records[i];
      if (!DownloadManager.safeItemId(rec.itemId) || rec.state !== DownloadState.DONE) { continue; }
      const clean = new OfflineDownloadRecord(); clean.itemId = rec.itemId; clean.title = rec.title;
      clean.subtitle = rec.subtitle; clean.filePath = rec.filePath;
      clean.totalBytes = rec.totalBytes; clean.receivedBytes = rec.receivedBytes;
      snapshots.push(clean);
    }
    Store.set(DownloadManager.RECORDS_KEY, JSON.stringify(snapshots)).catch(() => {});
  }

  private static rememberDone(rec: DownloadRecord): void {
    let found = false;
    for (let i = 0; i < DownloadManager.records.length; i++) {
      if (DownloadManager.records[i].itemId === rec.itemId) {
        DownloadManager.records[i] = DownloadManager.offlineCopy(rec);
        found = true;
        break;
      }
    }
    if (!found) {
      DownloadManager.records.push(DownloadManager.offlineCopy(rec));
    }
    DownloadManager.persistOffline();
  }

  private static forget(itemId: string): void {
    const keep: DownloadRecord[] = [];
    for (let i = 0; i < DownloadManager.records.length; i++) {
      if (DownloadManager.records[i].itemId !== itemId) {
        keep.push(DownloadManager.records[i]);
      }
    }
    DownloadManager.records = keep;
    DownloadManager.persistOffline();
  }

  /** 校验 .ready 文件：存在且大小 > 0 */
  private static isReadyFile(p: string): boolean {
    try {
      if (!fs.accessSync(p)) {
        return false;
      }
      const st = fs.statSync(p);
      return st.size > 0;
    } catch (e) {
      return false;
    }
  }

  /** 完整文件的路径（只有 .ready） */
  static readyPath(context: common.UIAbilityContext, itemId: string): string {
    return DownloadManager.localPath(context, itemId) + '.ready';
  }

  /** 下载中的临时路径 */
  static partPath(context: common.UIAbilityContext, itemId: string): string {
    return DownloadManager.localPath(context, itemId) + '.part';
  }

  /** 删除下载 */
  static remove(context: common.UIAbilityContext, itemId: string): boolean {
    if (!DownloadManager.safeItemId(itemId)) { return false; }
    try {
      // ★ 先取消任务再删文件（旧实现先 unlink 再 task.delete，有竞态）
      const t = DownloadManager.tasks.get(itemId);
      if (t !== undefined) {
        try {
          t.delete();
        } catch (e0) {
        }
        DownloadManager.tasks.delete(itemId);
      }
      DownloadManager.forget(itemId);
      for (const path of [DownloadManager.readyPath(context, itemId),
                          DownloadManager.partPath(context, itemId),
                          DownloadManager.localPath(context, itemId)]) {
        try {
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (e1) {
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 开始下载 */
  static async start(context: common.UIAbilityContext, rec: DownloadRecord,
                     onProgress: (r: DownloadRecord) => void): Promise<void> {
    if (!DownloadManager.safeItemId(rec.itemId)) { throw new Error('下载文件标识无效'); }
    if (DownloadManager.tasks.has(rec.itemId) || DownloadManager.starting.has(rec.itemId)) {
      throw new Error('该影片已有下载任务');
    }
    if (!/^https?:\/\/[^/?#\s]+(?:[/?#]|$)/i.test(rec.url)) { throw new Error('当前来源不支持整文件下载'); }
    // 已存在：★ 必须先把 filePath 写回 rec（旧实现在赋值之前就 return，
    // 命中分支的 rec 是空路径，点播放会路由空 url）
    if (DownloadManager.isDownloaded(context, rec.itemId)) {
      const ready = DownloadManager.readyPath(context, rec.itemId);
      rec.filePath = ready;
      rec.state = DownloadState.DONE;
      try {
        rec.receivedBytes = fs.statSync(ready).size;
        rec.totalBytes = rec.receivedBytes;
      } catch (e0) {
      }
      onProgress(rec);
      return;
    }

    // ★ 下载写 .part，校验通过后 rename 成 .ready
    const filePath = DownloadManager.partPath(context, rec.itemId);
    rec.filePath = filePath;
    rec.state = DownloadState.WAIT;
    onProgress(rec);

    DownloadManager.starting.add(rec.itemId);
    try {
      // ★ 飞牛的取流接口必须带 Authorization 头，不带会返回 43 字节的
      //   {"msg":"Auth Failed"} JSON 并存成"视频文件" —— 下载从来没成功过。
      const dlHeaders: Record<string, string> = {};
      if (rec.headers !== undefined && rec.headers !== null) {
        const keys = Object.keys(rec.headers);
        for (let i = 0; i < keys.length; i++) {
          if (!/^[A-Za-z0-9!#$%&'*+.^_|~-]+$/.test(keys[i]) || /[\r\n]/.test(rec.headers[keys[i]])) {
            throw new Error('下载请求头格式无效');
          }
          dlHeaders[keys[i]] = rec.headers[keys[i]];
        }
      } else if (rec.authToken !== undefined && rec.authToken.length > 0) {
        dlHeaders['Authorization'] = rec.authToken;
        dlHeaders['X-Emby-Token'] = rec.authToken;
      }
      const task = await request.downloadFile(context, {
        url: rec.url,
        header: dlHeaders,
        filePath: filePath,
        enableMetered: true,
        enableRoaming: true,
        background: true
      } as request.DownloadConfig);

      DownloadManager.tasks.set(rec.itemId, task);
      rec.state = DownloadState.RUNNING;
      onProgress(rec);

      task.on('progress', (received: number, total: number) => {
        rec.receivedBytes = received;
        rec.totalBytes = total;
        rec.state = DownloadState.RUNNING;
        onProgress(rec);
      });

      task.on('complete', () => {
        // ★ 校验（方案 R05/A8）：不能只看事件给的 totalBytes。
        //   旧实现：total=0 直接标 DONE；只看事件字节数，没验证磁盘上到底写了什么。
        //   现在必须 stat 实际文件、校验大小与媒体头，通过后才 rename 成 .ready。
        let actualSize: number = -1;
        try {
          actualSize = fs.statSync(filePath).size;
        } catch (e0) {
          actualSize = -1;
        }
        if (actualSize <= 0) {
          rec.state = DownloadState.FAILED;
          rec.error = '下载文件不存在或为空';
          DownloadManager.tasks.delete(rec.itemId);
          DownloadManager.dropPart(filePath);
          onProgress(rec);
          return;
        }
        if (actualSize < 65536) {
          rec.state = DownloadState.FAILED;
          rec.error = '服务器返回的内容不是视频（' + actualSize.toString()
            + ' 字节），请检查登录状态';
          DownloadManager.tasks.delete(rec.itemId);
          DownloadManager.dropPart(filePath);
          onProgress(rec);
          return;
        }
        if (!DownloadManager.looksLikeMedia(filePath)) {
          rec.state = DownloadState.FAILED;
          rec.error = '下载内容的文件头不是已知视频格式';
          DownloadManager.tasks.delete(rec.itemId);
          DownloadManager.dropPart(filePath);
          onProgress(rec);
          return;
        }
        // 校验通过：.part -> .ready
        const ready: string = DownloadManager.readyPath(context, rec.itemId);
        try {
          try {
            fs.unlinkSync(ready);
          } catch (e1) {
          }
          fs.renameSync(filePath, ready);
        } catch (e2) {
          rec.state = DownloadState.FAILED;
          rec.error = '保存文件失败';
          DownloadManager.tasks.delete(rec.itemId);
          onProgress(rec);
          return;
        }
        rec.state = DownloadState.DONE;
        rec.filePath = ready;
        rec.receivedBytes = actualSize;
        rec.totalBytes = actualSize;
        DownloadManager.tasks.delete(rec.itemId);
        DownloadManager.rememberDone(rec);
        onProgress(rec);
      });

      task.on('fail', (err: number) => {
        rec.state = DownloadState.FAILED;
        rec.error = '下载失败 (' + err.toString() + ')';
        DownloadManager.tasks.delete(rec.itemId);
        // ★ 失败必须隔离残片，否则下次会被 isDownloaded 当成已完成
        DownloadManager.dropPart(filePath);
        onProgress(rec);
      });

      // downloadFile 创建时已自动开始
    } catch (e) {
      const err = e as BusinessError;
      rec.state = DownloadState.FAILED;
      rec.error = '下载任务创建失败' + (err.code !== undefined ? ' [' + err.code.toString() + ']' : '');
      const task = DownloadManager.tasks.get(rec.itemId);
      if (task !== undefined) { try { task.delete(); } catch (e0) {} }
      DownloadManager.tasks.delete(rec.itemId); DownloadManager.dropPart(filePath);
      onProgress(rec);
    } finally {
      DownloadManager.starting.delete(rec.itemId);
    }
  }

  /** 删除 .part 残片 */
  private static dropPart(p: string): void {
    try {
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
    }
  }

  /**
   * 检查文件头是否是已知媒体格式（方案 R05/A8）。
   * 飞牛鉴权失败会返回 43 字节 JSON、未知路径返回 4303 字节 HTML，
   * 单体量判断不够，这里再看 magic。
   */
  private static looksLikeMedia(p: string): boolean {
    try {
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(12);
        const n = fs.readSync(f.fd, buf, { offset: 0, length: 12 });
        if (n < 8) {
          return false;
        }
        const b = new Uint8Array(buf);
        // MKV: 1A 45 DF A3
        if (b[0] === 0x1A && b[1] === 0x45 && b[2] === 0xDF && b[3] === 0xA3) {
          return true;
        }
        // MP4 / MOV: 4 字节 box size + 'ftyp'
        if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
          return true;
        }
        // MPEG-TS: 0x47 每隔 188 字节
        if (b[0] === 0x47) {
          return true;
        }
        // MPEG-PS: 00 00 01 BA
        if (b[0] === 0x00 && b[1] === 0x00 && b[2] === 0x01 && b[3] === 0xBA) {
          return true;
        }
        // AVI: 'RIFF'
        if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46) {
          return true;
        }
        // FLV: 'FLV'
        if (b[0] === 0x46 && b[1] === 0x4C && b[2] === 0x56) {
          return true;
        }
        return false;
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      return false;
    }
  }

  /** 暂停 */
  static pause(itemId: string): void {
    const t = DownloadManager.tasks.get(itemId);
    if (t !== undefined) {
      try {
        t.pause();
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 恢复 */
  static resume(itemId: string): void {
    const t = DownloadManager.tasks.get(itemId);
    if (t !== undefined) {
      try {
        t.resume();
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 已下载的文件列表 */
  static listDownloaded(context: common.UIAbilityContext): string[] {
    const out: string[] = [];
    try {
      const d = DownloadManager.dir(context);
      const files = fs.listFileSync(d);
      for (let i = 0; i < files.length; i++) {
        const f = files[i];
        if (f.endsWith('.ready')) {
          out.push(f);
        }
      }
    } catch (e) {
      // 忽略
    }
    return out;
  }

  /** 下载占用空间 */
  static totalSize(context: common.UIAbilityContext): number {
    let total = 0;
    try {
      const d = DownloadManager.dir(context);
      const files = fs.listFileSync(d);
      for (let i = 0; i < files.length; i++) {
        const st = fs.statSync(d + '/' + files[i]);
        total += st.size;
      }
    } catch (e) {
      // 忽略
    }
    return total;
  }

  static fmtSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return bytes.toString() + ' B';
    }
    if (bytes < 1048576) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    if (bytes < 1073741824) {
      return (bytes / 1048576).toFixed(1) + ' MB';
    }
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }
}
