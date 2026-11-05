import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ServerConfig } from './Models';
import { ServerRepository } from './ServerRepository';

/** 服务器列表持久化 */
export class Store {
  private static pref: preferences.Preferences | null = null;
  private static readonly KEY: string = 'servers_json';
  private static readonly KEY_LAST: string = 'last_server_id';

  static async init(context: common.Context): Promise<void> {
    if (Store.pref === null) {
      Store.pref = await preferences.getPreferences(context, 'nas_player');
    }
  }

  static async loadServers(): Promise<ServerConfig[]> {
    return Store.pref === null ? [] : await ServerRepository.load(Store.pref);
  }

  static async saveServers(list: ServerConfig[]): Promise<void> {
    if (Store.pref === null) { throw new Error('服务器存储尚未初始化'); }
    await ServerRepository.save(Store.pref, list);
  }

  static async upsert(server: ServerConfig): Promise<void> {
    if (Store.pref === null) { throw new Error('服务器存储尚未初始化'); }
    await ServerRepository.upsert(Store.pref, server);
  }

  static async remove(id: string): Promise<void> {
    if (Store.pref === null) { throw new Error('服务器存储尚未初始化'); }
    await ServerRepository.remove(Store.pref, id);
  }

  static async refreshServerCredentials(server: ServerConfig, expectedRef: string): Promise<boolean> {
    if (Store.pref === null) { throw new Error('服务器存储尚未初始化'); }
    return ServerRepository.refresh(Store.pref, server, expectedRef);
  }

  static async setLastId(id: string): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put(Store.KEY_LAST, id);
    await Store.pref.flush();
  }

  /* ───────── 最近播放（给桌面小组件用）───────── */

  static async setLastPlayed(title: string, subtitle: string,
                             image: string, progress: string): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put('last_title', title);
    await Store.pref.put('last_subtitle', subtitle);
    await Store.pref.put('last_image', image);
    await Store.pref.put('last_progress', progress);
    await Store.pref.flush();
  }

  /* ───────── TMDB ───────── */

  static async setTmdbKey(k: string): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put('tmdb_key', k);
    await Store.pref.flush();
  }

  static async getTmdbKey(): Promise<string> {
    if (Store.pref === null) {
      return '';
    }
    return await Store.pref.get('tmdb_key', '') as string;
  }

  /* ───────── 通用键值 ───────── */

  static async get(k: string, def: string): Promise<string> {
    if (Store.pref === null) {
      return def;
    }
    return await Store.pref.get(k, def) as string;
  }

  static async set(k: string, v: string): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put(k, v);
    await Store.pref.flush();
  }

  /* ───────── 本地播放进度（飞牛服务器不存，只能自己记）───────── */

  /** 一条播放进度 */
  static async saveProgress(rec: string): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put('play_progress', rec);
    await Store.pref.flush();
  }

  static async getProgressRaw(): Promise<string> {
    if (Store.pref === null) {
      return '[]';
    }
    return await Store.pref.get('play_progress', '[]') as string;
  }

  /** Only the obsolete app-wide lock is retired. Per-station ServerOptions is untouched. */
  static async retireLegacyApplicationLock(): Promise<void> {
    if (Store.pref === null) { return; }
    if (await Store.pref.get('lock_enabled', '0') === '0'
      && await Store.pref.get('lock_pin', '') === '' && await Store.pref.get('lock_bio', '0') === '0') { return; }
    await Store.pref.put('lock_enabled', '0');
    await Store.pref.put('lock_pin', '');
    await Store.pref.put('lock_bio', '0');
    await Store.pref.flush();
  }

  /* ───────── 应用锁 ───────── */

  static async setPin(hash: string): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put('lock_pin', hash);
    await Store.pref.flush();
  }

  static async getPin(): Promise<string> {
    if (Store.pref === null) {
      return '';
    }
    return await Store.pref.get('lock_pin', '') as string;
  }

  static async setLockEnabled(v: boolean): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put('lock_enabled', v ? '1' : '0');
    await Store.pref.flush();
  }

  static async isLockEnabled(): Promise<boolean> {
    if (Store.pref === null) {
      return false;
    }
    const v = await Store.pref.get('lock_enabled', '0') as string;
    return v === '1';
  }

  static async setBiometricEnabled(v: boolean): Promise<void> {
    if (Store.pref === null) {
      return;
    }
    await Store.pref.put('lock_bio', v ? '1' : '0');
    await Store.pref.flush();
  }

  static async isBiometricEnabled(): Promise<boolean> {
    if (Store.pref === null) {
      return false;
    }
    const v = await Store.pref.get('lock_bio', '0') as string;
    return v === '1';
  }

  static async getLastId(): Promise<string> {
    if (Store.pref === null) {
      return '';
    }
    return await Store.pref.get(Store.KEY_LAST, '') as string;
  }
}
