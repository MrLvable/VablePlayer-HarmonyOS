import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class ServerSecretValues {
  token: string = '';
  nativeToken: string = '';
  password: string = '';
  clientSecret: string = '';
  refreshToken: string = '';
  sourceUrl: string = '';
  epgUrl: string = '';
  authBrokerUrl: string = '';
}

interface SecretManifest { version: number; count: number; bytes: number; }

/** Versioned, chunked assets allow long signed URLs without writing secrets into Preferences. */
export class ServerCredentials {
  private static readonly PREFIX: string = 'nasplayer.server.';
  private static readonly CHUNK: number = 512;
  private static readonly MAX_BYTES: number = 65536;

  private static alias(ref: string, suffix: string): string {
    if (!/^v1-[0-9a-f-]{36}$/i.test(ref)) { throw new Error('服务器凭据引用无效'); }
    return ServerCredentials.PREFIX + ref + suffix;
  }

  private static query(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    query.set(asset.Tag.RETURN_LIMIT, 1);
    return query;
  }

  private static async bytes(alias: string): Promise<Uint8Array | null> {
    try {
      const rows = await asset.query(ServerCredentials.query(alias));
      if (rows.length === 0) { return null; }
      const value = rows[0].get(asset.Tag.SECRET) as Uint8Array;
      if (!(value instanceof Uint8Array)) { throw new Error('asset-type'); }
      return value;
    } catch (e) {
      if ((e as BusinessError).code === 24000002) { return null; }
      throw new Error('无法读取服务器安全凭据，请解锁设备后重试');
    }
  }

  private static async add(alias: string, bytes: Uint8Array): Promise<void> {
    const values: asset.AssetMap = new Map();
    values.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    values.set(asset.Tag.SECRET, bytes);
    values.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    values.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    await asset.add(values);
  }

  private static async erase(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    try { await asset.remove(query); }
    catch (e) { if ((e as BusinessError).code !== 24000002) { throw new Error('无法删除服务器安全凭据'); } }
  }

  private static normalize(raw: ServerSecretValues): ServerSecretValues {
    const result = new ServerSecretValues();
    result.token = typeof raw.token === 'string' ? raw.token : '';
    result.nativeToken = typeof raw.nativeToken === 'string' ? raw.nativeToken : '';
    result.password = typeof raw.password === 'string' ? raw.password : '';
    result.clientSecret = typeof raw.clientSecret === 'string' ? raw.clientSecret : '';
    result.refreshToken = typeof raw.refreshToken === 'string' ? raw.refreshToken : '';
    result.sourceUrl = typeof raw.sourceUrl === 'string' ? raw.sourceUrl : '';
    result.epgUrl = typeof raw.epgUrl === 'string' ? raw.epgUrl : '';
    result.authBrokerUrl = typeof raw.authBrokerUrl === 'string' ? raw.authBrokerUrl : '';
    return result;
  }

  static async read(ref: string): Promise<ServerSecretValues | null> {
    const manifestBytes = await ServerCredentials.bytes(ServerCredentials.alias(ref, '.m'));
    if (manifestBytes === null) { return null; }
    try {
      const manifest = JSON.parse(new util.TextDecoder('utf-8').decodeToString(manifestBytes)) as SecretManifest;
      if (manifest.version !== 1 || !Number.isInteger(manifest.count) || manifest.count < 1 || manifest.count > 128
        || !Number.isInteger(manifest.bytes) || manifest.bytes < 1 || manifest.bytes > ServerCredentials.MAX_BYTES
        || Math.ceil(manifest.bytes / ServerCredentials.CHUNK) !== manifest.count) { throw new Error('manifest'); }
      const payload = new Uint8Array(manifest.bytes);
      for (let index = 0; index < manifest.count; index++) {
        const part = await ServerCredentials.bytes(ServerCredentials.alias(ref, '.p' + index.toString()));
        const expected = Math.min(ServerCredentials.CHUNK, payload.length - index * ServerCredentials.CHUNK);
        if (part === null || part.length !== expected) { throw new Error('incomplete'); }
        payload.set(part, index * ServerCredentials.CHUNK);
      }
      const value = JSON.parse(new util.TextDecoder('utf-8').decodeToString(payload)) as ServerSecretValues;
      if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw new Error('payload'); }
      return ServerCredentials.normalize(value);
    } catch (e) { throw new Error('服务器安全凭据不完整，请重新登录'); }
  }

  static async write(values: ServerSecretValues): Promise<string> {
    const payload = new util.TextEncoder().encodeInto(JSON.stringify(ServerCredentials.normalize(values)));
    if (payload.length > ServerCredentials.MAX_BYTES) { throw new Error('服务器凭据或订阅地址过长'); }
    const ref = 'v1-' + util.generateRandomUUID();
    const count = Math.ceil(payload.length / ServerCredentials.CHUNK);
    let added = 0;
    try {
      for (let index = 0; index < count; index++) {
        await ServerCredentials.add(ServerCredentials.alias(ref, '.p' + index.toString()),
          payload.slice(index * ServerCredentials.CHUNK, Math.min(payload.length, (index + 1) * ServerCredentials.CHUNK)));
        added++;
      }
      const manifest: SecretManifest = { version: 1, count: count, bytes: payload.length };
      await ServerCredentials.add(ServerCredentials.alias(ref, '.m'),
        new util.TextEncoder().encodeInto(JSON.stringify(manifest)));
      return ref;
    } catch (e) {
      for (let index = 0; index < added; index++) {
        try { await ServerCredentials.erase(ServerCredentials.alias(ref, '.p' + index.toString())); } catch (cleanupError) {}
      }
      throw new Error('服务器安全凭据保存失败，未改用普通存储');
    }
  }

  static async remove(ref: string): Promise<void> {
    if (ref.length === 0) { return; }
    const bytes = await ServerCredentials.bytes(ServerCredentials.alias(ref, '.m'));
    let count = 128;
    if (bytes !== null) {
      try {
        const manifest = JSON.parse(new util.TextDecoder('utf-8').decodeToString(bytes)) as SecretManifest;
        if (Number.isInteger(manifest.count) && manifest.count > 0 && manifest.count <= 128) { count = manifest.count; }
      } catch (e) {}
    }
    for (let index = 0; index < count; index++) { await ServerCredentials.erase(ServerCredentials.alias(ref, '.p' + index.toString())); }
    await ServerCredentials.erase(ServerCredentials.alias(ref, '.m'));
  }
}
