/**
 * MediaCache —— 播放缓存管理（R04/A5）
 *
 * 背景：MKV 在本机 AVPlayer 上只能用 fdSrc（本地文件）播放，
 * 所以每播一部 MKV 都会在 cacheDir 落一个完整副本（2GB 级）。
 *
 * 本版按 04-当前源码播放器审计 A5 修的问题：
 *   1. 之前每次点播都无条件 unlink 同 itemId 缓存再重下 —— 第二次播放仍等 18 秒
 *   2. 预算只看下载前占用，不预留本片大小，下载后也不淘汰
 *   3. clearAll 不接受 keepPath、不检查是否在用
 *   4. 缓存命名只有 itemId —— 相同 ID 不同服务器/源会复用同路径
 *   5. 注释说「启动清理」，实际没有启动调用
 *
 * 现在的模型：
 *   · cacheKey = hash(serverId|userId|itemId|sourceId|version)，不含明文 token
 *   · 下载中写 <key>.part，验证通过后原子 rename 成 <key>.ready
 *   · 只有 .ready 才允许命中；.part 永远当未完成
 *   · lease：正在被播放器/下载器使用的 key 不参与淘汰，clearAll 也跳过
 *   · 预算 4 GiB，淘汰前先算「本片预留」，不够就淘汰到够
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 缓存文件信息 */
class CacheEntry {
  path: string = '';
  key: string = '';
  size: number = 0;
  atime: number = 0;
  ready: boolean = false;
}

export class MediaCache {
  /** 总预算 4 GiB */
  static readonly BUDGET: number = 4 * 1024 * 1024 * 1024;
  private static readonly PART: string = '.part';
  private static readonly READY: string = '.ready';
  private static readonly PREFIX: string = 'stream_';

  /** 正在使用的 key（播放器 / 下载器持有），淘汰时跳过 */
  private static leases: Set<string> = new Set<string>();

  /* ───────── key ───────── */

  /**
   * 稳定的 cacheKey：server + user + item + source + version。
   * ★ 不含明文 token；也不只用 itemId（不同服务器可能有相同 ID）。
   */
  static keyOf(serverId: string, userId: string, itemId: string,
              sourceId: string, version: string): string {
    const raw: string = serverId + '|' + userId + '|' + itemId + '|'
      + sourceId + '|' + version;
    // 简单 FNV-1a，避免把整段明文（含服务器地址）写进文件名
    let h: number = 0x811c9dc5;
    for (let i = 0; i < raw.length; i++) {
      h = h ^ raw.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, '0') + '_' + itemId.substring(0, 8);
  }

  /* ───────── 路径 ───────── */

  static partPath(ctx: common.UIAbilityContext, key: string): string {
    return ctx.cacheDir + '/' + MediaCache.PREFIX + key + MediaCache.PART;
  }

  static readyPath(ctx: common.UIAbilityContext, key: string): string {
    return ctx.cacheDir + '/' + MediaCache.PREFIX + key + MediaCache.READY;
  }

  /* ───────── lease ───────── */

  static acquire(key: string): void {
    MediaCache.leases.add(key);
  }

  static release(key: string): void {
    MediaCache.leases.delete(key);
  }

  static isLeased(key: string): boolean {
    return MediaCache.leases.has(key);
  }

  /* ───────── 命中判定 ───────── */

  /**
   * 是否已有验证过的 Ready 缓存。
   * @param expectedSize >0 时校验实际大小必须一致
   */
  static hit(ctx: common.UIAbilityContext, key: string, expectedSize: number): boolean {
    const p: string = MediaCache.readyPath(ctx, key);
    try {
      const st = fs.statSync(p);
      if (st.size <= 0) {
        return false;
      }
      if (expectedSize > 0 && st.size !== expectedSize) {
        hilog.info(0x0001, 'MediaCache', 'ready size mismatch %{public}d != %{public}d',
          st.size, expectedSize);
        return false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 已存在的 Ready 缓存大小；没有返回 -1 */
  static readySize(ctx: common.UIAbilityContext, key: string): number {
    try {
      return fs.statSync(MediaCache.readyPath(ctx, key)).size;
    } catch (e) {
      return -1;
    }
  }

  /**
   * 下载成功后发布：.part → .ready。
   * 调用前必须已经 fsync + 长度校验。
   */
  static publish(ctx: common.UIAbilityContext, key: string): boolean {
    const from: string = MediaCache.partPath(ctx, key);
    const to: string = MediaCache.readyPath(ctx, key);
    try {
      try {
        fs.unlinkSync(to);
      } catch (e0) {
        // 旧 ready 不存在
      }
      fs.renameSync(from, to);
      hilog.info(0x0001, 'MediaCache', 'published %{public}s', key);
      return true;
    } catch (e) {
      const er = e as Error;
      hilog.info(0x0001, 'MediaCache', 'publish failed: %{public}s', er.message);
      return false;
    }
  }

  /** 丢弃未完成的 .part */
  static discardPart(ctx: common.UIAbilityContext, key: string): void {
    try {
      fs.unlinkSync(MediaCache.partPath(ctx, key));
    } catch (e) {
    }
  }

  /* ───────── 枚举 ───────── */

  private static list(ctx: common.UIAbilityContext): CacheEntry[] {
    const out: CacheEntry[] = [];
    try {
      const names: string[] = fs.listFileSync(ctx.cacheDir);
      for (let i = 0; i < names.length; i++) {
        const nm = names[i];
        if (!nm.startsWith(MediaCache.PREFIX)) {
          continue;
        }
        const isReady: boolean = nm.endsWith(MediaCache.READY);
        const isPart: boolean = nm.endsWith(MediaCache.PART);
        if (!isReady && !isPart) {
          continue;
        }
        const full: string = ctx.cacheDir + '/' + nm;
        const keyPart: string = nm.substring(MediaCache.PREFIX.length,
          nm.length - (isReady ? MediaCache.READY.length : MediaCache.PART.length));
        try {
          const st = fs.statSync(full);
          const e = new CacheEntry();
          e.path = full;
          e.key = keyPart;
          e.size = st.size;
          e.atime = st.atime * 1000;
          e.ready = isReady;
          out.push(e);
        } catch (e1) {
        }
      }
    } catch (e2) {
    }
    return out;
  }

  static usedBytes(ctx: common.UIAbilityContext): number {
    const list = MediaCache.list(ctx);
    let sum: number = 0;
    for (let i = 0; i < list.length; i++) {
      sum += list[i].size;
    }
    return sum;
  }

  static count(ctx: common.UIAbilityContext): number {
    let n: number = 0;
    const list = MediaCache.list(ctx);
    for (let i = 0; i < list.length; i++) {
      if (list[i].ready) {
        n++;
      }
    }
    return n;
  }

  /* ───────── 淘汰 ───────── */

  /**
   * 按预算淘汰。
   * @param reserveBytes 本次要下载的大小；预留后仍超预算就淘汰到够
   * @param keepKey      当前正在用的 key，不删
   * @returns 释放的字节数
   */
  static evict(ctx: common.UIAbilityContext, keepKey: string, reserveBytes: number): number {
    const list = MediaCache.list(ctx);
    let total: number = 0;
    for (let i = 0; i < list.length; i++) {
      total += list[i].size;
    }
    const budget: number = MediaCache.BUDGET;
    if (total + reserveBytes <= budget) {
      // 预算够，但仍然清理过期 .part（超过 1 天没动的）
      MediaCache.dropStaleParts(list, keepKey);
      return 0;
    }

    // 最旧的排前面；.part 优先于 .ready 被删
    list.sort((a: CacheEntry, b: CacheEntry) => {
      if (a.ready !== b.ready) {
        return a.ready ? 1 : -1;
      }
      return a.atime - b.atime;
    });

    let freed: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (total + reserveBytes <= budget) {
        break;
      }
      const e = list[i];
      if (e.key === keepKey || MediaCache.leases.has(e.key)) {
        continue;
      }
      try {
        fs.unlinkSync(e.path);
        total -= e.size;
        freed += e.size;
        hilog.info(0x0001, 'MediaCache', 'evicted %{public}s (%{public}d MB)',
          e.key, Math.round(e.size / 1048576));
      } catch (e3) {
      }
    }
    return freed;
  }

  /** 清理一天以上没动过的 .part */
  private static dropStaleParts(list: CacheEntry[], keepKey: string): void {
    const now: number = Date.now();
    const DAY: number = 24 * 3600 * 1000;
    for (let i = 0; i < list.length; i++) {
      const e = list[i];
      if (e.ready || e.key === keepKey || MediaCache.leases.has(e.key)) {
        continue;
      }
      if (now - e.atime > DAY) {
        try {
          fs.unlinkSync(e.path);
        } catch (e1) {
        }
      }
    }
  }

  /**
   * 清空全部播放缓存。
   * ★ 跳过 lease 中（正在播放/下载）的文件，并如实报告保留了几个。
   */
  static clearAll(ctx: common.UIAbilityContext): ClearResult {
    const list = MediaCache.list(ctx);
    const res = new ClearResult();
    for (let i = 0; i < list.length; i++) {
      const e = list[i];
      if (MediaCache.leases.has(e.key)) {
        res.kept++;
        continue;
      }
      try {
        fs.unlinkSync(e.path);
        res.freed += e.size;
      } catch (e1) {
      }
    }
    hilog.info(0x0001, 'MediaCache', 'clearAll freed %{public}d MB kept %{public}d',
      Math.round(res.freed / 1048576), res.kept);
    return res;
  }

  /** 启动清理：删掉所有 .part 与超预算的 .ready */
  static startupCleanup(ctx: common.UIAbilityContext): void {
    const list = MediaCache.list(ctx);
    for (let i = 0; i < list.length; i++) {
      if (!list[i].ready && !MediaCache.leases.has(list[i].key)) {
        try {
          fs.unlinkSync(list[i].path);
        } catch (e) {
        }
      }
    }
    MediaCache.evict(ctx, '', 0);
  }

  /** 人类可读的占用描述 */
  static describe(ctx: common.UIAbilityContext): string {
    const used: number = MediaCache.usedBytes(ctx);
    const n: number = MediaCache.count(ctx);
    if (n === 0) {
      return '无缓存';
    }
    return n.toString() + ' 部 · ' + Math.round(used / 1048576).toString() + ' MB';
  }
}

/** clearAll 结果 */
export class ClearResult {
  freed: number = 0;
  kept: number = 0;
}
