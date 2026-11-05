/**
 * ProgressRepository —— 「继续观看」进度仓储 V2
 *
 * ★ 修复的历史缺陷：
 *   写入侧 PlayerPage.upsertProgress() 把每条记录先 JSON.stringify 成字符串，
 *   放进 string[]，再对整个数组 JSON.stringify；
 *   读取侧 Index.loadResume() 却把原始 JSON 当对象数组直接读 arr[i]['id']。
 *   于是保存的是 ["{...}"]，读取期望 [{...}] —— id 永远取不到，
 *   「继续观看」实际从未工作过。
 *
 * V2 设计（方案 9.2）：
 *   · envelope 一次序列化，不再保存"JSON 字符串数组"
 *   · 主键 = serverId + userId + itemId（token 变化不丢历史）
 *   · 所有写入经同一个串行队列，避免 read-modify-write 互相覆盖
 *   · 首次读取自动识别三种历史格式并迁移
 */

import { Store } from './Store';

/** 单条观看进度 */
export interface ProgressRecordV2 {
  serverId: string;
  userId: string;
  itemId: string;
  itemType: string;
  seriesId: string;
  title: string;
  episodeTitle: string;
  seasonNumber: number;
  episodeNumber: number;
  positionMs: number;
  durationMs: number;
  updatedAt: number;
  completed: boolean;
  imageTag: string;
}

/** 存储信封 */
export interface ProgressEnvelopeV2 {
  version: number;   // 固定 2
  records: ProgressRecordV2[];
}

/** 迁移结果统计 */
export interface MigrationReport {
  from: string;        // 'v2' | 'object-array' | 'string-array' | 'empty' | 'corrupt'
  kept: number;
  dropped: number;
  unassigned: number;
}

const KEY_PROGRESS = 'progress_v2';
const KEY_LEGACY = 'play_progress';      // 旧键
const KEY_MIGRATED = 'progress_migrated_v2';

/** 完成判定阈值 */
const COMPLETE_RATIO = 0.95;
/** 太短不记（避免误触污染） */
const MIN_POSITION_MS = 5000;
/** 每账号最多保留条数 */
const MAX_RECORDS = 100;
/** 首页展示条数 */
const HOME_LIMIT = 12;

export class ProgressRepository {
  /** 串行队列：保证 read-modify-write 不交叉 */
  private static chain: Promise<void> = Promise.resolve();

  private static key(serverId: string, userId: string, itemId: string): string {
    return serverId + '|' + userId + '|' + itemId;
  }

  private static newRecord(): ProgressRecordV2 {
    return {
      serverId: '',
      userId: '',
      itemId: '',
      itemType: '',
      seriesId: '',
      title: '',
      episodeTitle: '',
      seasonNumber: 0,
      episodeNumber: 0,
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0,
      completed: false,
      imageTag: ''
    };
  }

  /* ───────── 底层读写 ───────── */

  private static async readEnvelope(): Promise<ProgressEnvelopeV2> {
    const raw = await Store.get(KEY_PROGRESS, '');
    if (raw.length < 2) {
      return { version: 2, records: [] };
    }
    try {
      const env = JSON.parse(raw) as ProgressEnvelopeV2;
      if (env !== null && env.version === 2 && env.records !== undefined) {
        return env;
      }
    } catch (e) {
      // 落下去走空
    }
    return { version: 2, records: [] };
  }

  private static async writeEnvelope(records: ProgressRecordV2[]): Promise<void> {
    const env: ProgressEnvelopeV2 = { version: 2, records: records };
    await Store.set(KEY_PROGRESS, JSON.stringify(env));
  }

  /** 串行执行 mutator */
  private static enqueue(mutator: (records: ProgressRecordV2[]) => ProgressRecordV2[]): Promise<void> {
    const run = async (): Promise<void> => {
      const env = await ProgressRepository.readEnvelope();
      const next = mutator(env.records);
      // 按 updatedAt 降序、去重后截断
      next.sort((a: ProgressRecordV2, b: ProgressRecordV2) => b.updatedAt - a.updatedAt);
      const seen: Set<string> = new Set<string>();
      const kept: ProgressRecordV2[] = [];
      for (let i = 0; i < next.length; i++) {
        const k = ProgressRepository.key(next[i].serverId, next[i].userId, next[i].itemId);
        if (!seen.has(k)) {
          seen.add(k);
          kept.push(next[i]);
          if (kept.length >= MAX_RECORDS) {
            break;
          }
        }
      }
      await ProgressRepository.writeEnvelope(kept);
    };
    ProgressRepository.chain = ProgressRepository.chain.then(run, run);
    return ProgressRepository.chain;
  }

  /* ───────── 公共 API ───────── */

  /**
   * 写入/更新一条进度。
   * position < 5s 不建记录；position/duration >= 95% 视为完成并清除。
   */
  static async upsert(rec: ProgressRecordV2): Promise<void> {
    if (rec.itemId.length === 0) {
      return;
    }
    const tooShort = rec.positionMs < MIN_POSITION_MS;
    const finished = rec.durationMs > 0 && rec.positionMs / rec.durationMs >= COMPLETE_RATIO;

    await ProgressRepository.enqueue((records: ProgressRecordV2[]) => {
      const out: ProgressRecordV2[] = [];
      const k = ProgressRepository.key(rec.serverId, rec.userId, rec.itemId);
      for (let i = 0; i < records.length; i++) {
        const r = records[i];
        if (ProgressRepository.key(r.serverId, r.userId, r.itemId) !== k) {
          out.push(r);
        }
      }
      // ★ 区分「忽略新记录」与「明确清除旧记录」（方案 R05/A7）：
      //   旧实现把 tooShort 和 finished 一起 return out，
      //   而 out 里已经删掉了同 key 的旧记录 —— 于是「播放初始化失败、
      //   playPos 还是 0 时退出」会把之前有效的 10 分钟历史抹掉。
      if (tooShort) {
        return records;   // 位置太短：忽略这次写入，保留旧历史
      }
      if (finished) {
        return out;       // 真正看完：清除记录
      }
      out.push(rec);
      return out;
    });
  }

  /** 标记完成（从继续观看移除） */
  static async markComplete(serverId: string, userId: string, itemId: string): Promise<void> {
    await ProgressRepository.enqueue((records: ProgressRecordV2[]) => {
      const out: ProgressRecordV2[] = [];
      for (let i = 0; i < records.length; i++) {
        const r = records[i];
        const same = r.serverId === serverId && r.userId === userId && r.itemId === itemId;
        if (!same) {
          out.push(r);
        }
      }
      return out;
    });
  }

  /** 移除一条 */
  static async remove(serverId: string, userId: string, itemId: string): Promise<void> {
    await ProgressRepository.markComplete(serverId, userId, itemId);
  }

  /**
   * 读取某账号的继续观看列表（未完成、按更新时间降序）。
   * @param limit 默认首页 12 条
   */
  static async loadForAccount(serverId: string, userId: string,
                              limit: number = HOME_LIMIT): Promise<ProgressRecordV2[]> {
    const env = await ProgressRepository.readEnvelope();
    const out: ProgressRecordV2[] = [];
    for (let i = 0; i < env.records.length; i++) {
      const r = env.records[i];
      if (r.serverId !== serverId || r.userId !== userId) {
        continue;
      }
      if (r.completed) {
        continue;
      }
      if (r.positionMs < MIN_POSITION_MS) {
        continue;
      }
      out.push(r);
      if (out.length >= limit) {
        break;
      }
    }
    return out;
  }

  /** 全部记录（调试/统计用） */
  static async loadAll(): Promise<ProgressRecordV2[]> {
    const env = await ProgressRepository.readEnvelope();
    return env.records;
  }

  /** 清空（切换默认账号等场景） */
  static async clear(): Promise<void> {
    await ProgressRepository.enqueue((records: ProgressRecordV2[]) => {
      return [];
    });
  }

  /* ───────── 旧数据迁移（方案 9.3）───────── */

  /**
   * 首次读取时识别并迁移历史格式。
   * 三种历史格式：
   *   1. V2 envelope  —— 已迁移，直接返回
   *   2. 对象数组 [{id,name,...}]
   *   3. 字符串数组 ["{...}"]  ← 旧实现实际写的格式
   *
   * 旧数据没有 serverId/userId 维度，**不得复制到所有服务器**：
   * 只有调用方明确给出当前唯一可确认账号时才归属它，否则进 legacy-unassigned。
   */
  static async migrateLegacy(serverId: string, userId: string): Promise<MigrationReport> {
    const done = await Store.get(KEY_MIGRATED, '');
    if (done === '1') {
      return { from: 'v2', kept: 0, dropped: 0, unassigned: 0 };
    }

    const legacyRaw = await Store.get(KEY_LEGACY, '');
    const report: MigrationReport = { from: 'empty', kept: 0, dropped: 0, unassigned: 0 };

    if (legacyRaw.length < 3) {
      await Store.set(KEY_MIGRATED, '1');
      report.from = 'empty';
      return report;
    }

    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(legacyRaw) as Object;
    } catch (e) {
      report.from = 'corrupt';
      await Store.set(KEY_MIGRATED, '1');
      return report;
    }

    const rawList: Object[] = [];
    if (parsed instanceof Array) {
      const arr = parsed as Object[];
      // 判断是字符串数组还是对象数组
      let isStringArray = false;
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          isStringArray = true;
          break;
        }
      }
      report.from = isStringArray ? 'string-array' : 'object-array';
      for (let i = 0; i < arr.length; i++) {
        if (isStringArray) {
          try {
            rawList.push(JSON.parse(arr[i] as string) as Object);
          } catch (e) {
            report.dropped++;
          }
        } else {
          rawList.push(arr[i]);
        }
      }
    }

    // 转换
    const converted: ProgressRecordV2[] = [];
    for (let i = 0; i < rawList.length; i++) {
      const o = rawList[i] as Record<string, Object>;
      const id = o['id'] !== undefined ? (o['id'] as string) : '';
      if (id === undefined || id.length === 0) {
        report.dropped++;
        continue;
      }
      const r = ProgressRepository.newRecord();
      r.itemId = id;
      r.serverId = serverId;
      r.userId = userId;
      r.itemType = 'Episode';
      r.title = o['series'] !== undefined ? (o['series'] as string) : '';
      r.episodeTitle = o['name'] !== undefined ? (o['name'] as string) : '';
      r.positionMs = o['pos'] !== undefined ? (o['pos'] as number) : 0;
      r.durationMs = o['dur'] !== undefined ? (o['dur'] as number) : 0;
      r.updatedAt = o['at'] !== undefined ? (o['at'] as number) : Date.now();
      r.completed = r.durationMs > 0 && r.positionMs / r.durationMs >= COMPLETE_RATIO;
      if (r.positionMs < MIN_POSITION_MS) {
        report.dropped++;
        continue;
      }
      converted.push(r);
      report.kept++;
    }

    if (converted.length > 0) {
      await ProgressRepository.enqueue((records: ProgressRecordV2[]) => {
        const out: ProgressRecordV2[] = [];
        for (let i = 0; i < records.length; i++) {
          out.push(records[i]);
        }
        for (let i = 0; i < converted.length; i++) {
          out.push(converted[i]);
        }
        return out;
      });
    }

    await Store.set(KEY_MIGRATED, '1');
    return report;
  }
}
