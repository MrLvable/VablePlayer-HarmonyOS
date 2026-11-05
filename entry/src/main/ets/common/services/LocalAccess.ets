import { picker, fileIo, fileShare, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import localNative, { LocalOpenFile } from 'libnas_local.so';
import { PlaybackInfo } from '../Models';

/** Picker URI is the authority. Never strip file://docs or synthesize storage paths. */
export class LocalAccess {
  private static temporary: Map<string, boolean> = new Map();
  static validate(uri: string): string {
    if (!/^file:\/\//.test(uri) || uri.length > 8192 || /[\r\n\x00]/.test(uri)) { throw new Error('请选择系统返回的本地文件或文件夹 URI'); }
    return uri;
  }
  static fileName(uri: string): string {
    LocalAccess.validate(uri);
    try { return new fileUri.FileUri(uri).name; } catch (e) { throw new Error('无法读取所选文件名称'); }
  }
  private static policy(uri: string): fileShare.PolicyInfo[] {
    return [{ uri: LocalAccess.validate(uri), operationMode: fileShare.OperationMode.READ_MODE }];
  }
  static async select(context: common.UIAbilityContext, folder: boolean): Promise<string> {
    const options = new picker.DocumentSelectOptions();
    options.selectMode = folder ? picker.DocumentSelectMode.FOLDER : picker.DocumentSelectMode.FILE;
    options.maxSelectNumber = 1;
    let uris: string[];
    try { uris = await new picker.DocumentViewPicker(context).select(options); }
    catch (e) {
      if (/cancel|取消/i.test((e as Error).message)) { return ''; }
      throw new Error(folder ? '系统未能选择文件夹，请检查设备目录授权能力或改选单文件' : '系统文件选择失败，请重试');
    }
    if (uris.length === 0) { return ''; }
    const uri = LocalAccess.validate(uris[0]);
    LocalAccess.temporary.set(uri, false);
    try {
      if (canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
        await fileShare.persistPermission(LocalAccess.policy(uri));
        LocalAccess.temporary.set(uri, true);
      }
    } catch (e) { /* Current Picker grant is usable; persistence is explicitly reported below. */ }
    if (LocalAccess.temporary.size > 64) {
      let oldest = ''; LocalAccess.temporary.forEach((_value: boolean, key: string) => { if (oldest.length === 0) { oldest = key; } });
      LocalAccess.temporary.delete(oldest);
    }
    return uri;
  }
  static permissionNotice(uri: string): string {
    return LocalAccess.temporary.get(uri) === false ? '当前仅有本次读取授权；重启后可能需要重新选择文件或文件夹。' : '';
  }
  static async ensureRead(uri: string): Promise<void> {
    const policies = LocalAccess.policy(uri);
    if (canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
      try {
        const granted = await fileShare.checkPersistentPermission(policies);
        if (granted.length === 1 && granted[0]) { await fileShare.activatePermission(policies); return; }
      } catch (e) {
        if (!LocalAccess.temporary.has(uri)) { throw new Error('本地读取授权无法恢复，请重新使用系统选择器授权'); }
      }
    }
    if (LocalAccess.temporary.has(uri)) { return; }
    throw new Error('本地文件或目录尚无有效持久授权，请重新选择；保存 URI 不代表已取得读取权限');
  }
  static async withRoot<T>(uri: string, action: (fd: number) => Promise<T>): Promise<T> {
    await LocalAccess.ensureRead(uri);
    let root: fileIo.File | null = null;
    try { root = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY); return await action(root.fd); }
    catch (e) {
      const raw = (e as Error).message; const message = typeof raw === 'string' ? raw : '';
      if (message.startsWith('本地') || message.startsWith('JSON')) { throw (e as Error); }
      if (message.indexOf('DOCUMENT_TOO_LARGE') >= 0) { throw new Error('JSON 文档超过读取上限（最多 2MiB）'); }
      if (message.indexOf('DIRECTORY_TOO_LARGE') >= 0) { throw new Error('本地目录条目过多，请选择更小的子目录'); }
      throw new Error('无法读取已选择的本地文件或目录，请检查授权后重新选择');
    } finally { if (root !== null) { await fileIo.close(root).catch(() => {}); } }
  }
  static relative(path: string): string {
    if (path.length > 4096 || path.startsWith('/') || /[\\\x00]/.test(path)) { throw new Error('本地目录相对路径无效'); }
    if (path.length === 0) { return ''; }
    const parts = path.split('/');
    if (parts.length > 32 || parts.some((part: string) => part.length === 0 || part === '.' || part === '..')) { throw new Error('本地目录不能越过选择的根范围'); }
    return path;
  }
  static async readDocument(uri: string, maximum: number = 2097152): Promise<string> {
    const data: ArrayBuffer = await LocalAccess.withRoot<ArrayBuffer>(uri, (fd: number): Promise<ArrayBuffer> => localNative.readSmall(fd, '', maximum));
    try { return new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(new Uint8Array(data)); }
    catch (e) { throw new Error('JSON 文件必须为有效 UTF-8 文本'); }
  }
  static async openPlayable(uri: string, path: string = ''): Promise<PlaybackInfo> {
    const relative = LocalAccess.relative(path);
    const opened: LocalOpenFile = await LocalAccess.withRoot<LocalOpenFile>(uri, (fd: number): Promise<LocalOpenFile> => localNative.openChild(fd, relative));
    let released = false;
    const result = new PlaybackInfo(); result.url = 'fd://' + opened.fd.toString(); result.headers = {};
    // mpv fd:// borrows the fd; fdclose:// would transfer ownership and must not be used here.
    result.release = async (): Promise<void> => {
      if (released) { return; } released = true;
      await localNative.closeFile(opened.fd);
    };
    return result;
  }
}
