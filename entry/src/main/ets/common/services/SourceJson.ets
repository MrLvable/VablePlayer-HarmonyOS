/** Preserve uint64 IDs before JSON.parse can round them. Never rewrites inside quoted strings. */
export class SourceJson {
  static preserveIntegers(text: string): string {
    let output = ''; let quoted = false; let escaped = false;
    for (let at = 0; at < text.length; at++) {
      const char = text.charAt(at);
      if (quoted) {
        output += char;
        if (escaped) { escaped = false; } else if (char === '\\') { escaped = true; } else if (char === '"') { quoted = false; }
        continue;
      }
      if (char === '"') { quoted = true; output += char; continue; }
      if (char === '-' || /[0-9]/.test(char)) {
        const match = /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(text.substring(at));
        if (match !== null) {
          const number = match[0];
          if (/^-?0\d/.test(number)) { throw new Error('云端 JSON 数字格式无效'); }
          output += /^-?\d+$/.test(number) && !Number.isSafeInteger(Number(number)) ? '"' + number + '"' : number;
          at += number.length - 1; continue;
        }
      }
      output += char;
    }
    return output;
  }
  static id(value: string | number | undefined): string {
    if (typeof value === 'string' && /^\d+$/.test(value)) { return value; }
    if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) { return value.toString(); }
    throw new Error('云端文件标识无效，已停止以免访问错误条目');
  }
}
