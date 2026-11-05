/**
 * 调试信息收集（临时）
 * 把 App 内部实际拼出来的 URL / 错误 暴露到界面上，方便排查
 */
export class Dbg {
  static lastImageUrl: string = '';
  static lastImageErr: string = '';
  static lastApiErr: string = '';
  static lastApiPath: string = '';

  static setImage(url: string): void {
    Dbg.lastImageUrl = url;
  }

  static setImageErr(e: string): void {
    Dbg.lastImageErr = e;
  }

  static setApi(path: string, err: string): void {
    Dbg.lastApiPath = path;
    Dbg.lastApiErr = err;
  }

  static clear(): void {
    Dbg.lastImageErr = '';
    Dbg.lastApiErr = '';
  }
}
