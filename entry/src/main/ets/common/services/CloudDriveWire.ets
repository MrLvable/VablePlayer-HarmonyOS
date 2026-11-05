import { util } from '@kit.ArkTS';

export class ProtoField {
  number: number = 0;
  wire: number = 0;
  value: number = 0;
  data: Uint8Array = new Uint8Array(0);
}
class ProtoVarint { value: number = 0; next: number = 0; }

/** Small, read-only subset of the public CloudDrive proto; no generated third-party SDK code. */
export class CloudDriveWire {
  static join(parts: Uint8Array[]): Uint8Array {
    let size = 0; parts.forEach((part: Uint8Array) => { size += part.length; });
    if (size > 8388608) { throw new Error('CloudDrive 消息超过读取上限'); }
    const output = new Uint8Array(size); let at = 0; parts.forEach((part: Uint8Array) => { output.set(part, at); at += part.length; }); return output;
  }
  private static varint(bytes: Uint8Array, at: number): ProtoVarint {
    const result = new ProtoVarint(); let multiple = 1; let unsafe = false;
    for (let count = 0; count < 10; count++) {
      if (at >= bytes.length) { throw new Error('CloudDrive protobuf 整数不完整'); }
      const byte = bytes[at++]; if (count === 9 && byte > 1) { throw new Error('CloudDrive protobuf 整数溢出'); }
      if (!unsafe) { result.value += (byte & 127) * multiple; if (!Number.isSafeInteger(result.value)) { unsafe = true; } }
      if ((byte & 128) === 0) { result.next = at; if (unsafe) { result.value = Number.NaN; } return result; }
      multiple *= 128;
    }
    throw new Error('CloudDrive protobuf 整数过长');
  }
  static fields(bytes: Uint8Array): ProtoField[] {
    const fields: ProtoField[] = []; let at = 0;
    while (at < bytes.length) {
      const tag = CloudDriveWire.varint(bytes, at); at = tag.next;
      if (!Number.isSafeInteger(tag.value) || tag.value < 8 || tag.value > 4294967295) { throw new Error('CloudDrive protobuf 字段标记无效'); }
      const field = new ProtoField(); field.number = Math.floor(tag.value / 8); field.wire = tag.value % 8;
      if (field.wire === 0) { const integer = CloudDriveWire.varint(bytes, at); at = integer.next; field.value = integer.value; }
      else if (field.wire === 2) {
        const length = CloudDriveWire.varint(bytes, at); at = length.next;
        if (!Number.isSafeInteger(length.value) || length.value < 0 || length.value > bytes.length - at) { throw new Error('CloudDrive protobuf 字段长度无效'); }
        field.data = bytes.slice(at, at + length.value); at += length.value;
      } else if (field.wire === 1 || field.wire === 5) { const size = field.wire === 1 ? 8 : 4; if (size > bytes.length - at) { throw new Error('CloudDrive protobuf 固定字段不完整'); } at += size; }
      else { throw new Error('CloudDrive protobuf 使用了不支持的字段编码'); }
      fields.push(field); if (fields.length > 20000) { throw new Error('CloudDrive protobuf 字段过多'); }
    }
    return fields;
  }
  static text(fields: ProtoField[], number: number): string {
    const field = fields.find((entry: ProtoField) => entry.number === number && entry.wire === 2);
    if (field === undefined) { return ''; }
    try { return new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(field.data); }
    catch (e) { throw new Error('CloudDrive protobuf 文本编码无效'); }
  }
  static integer(fields: ProtoField[], number: number, fallback: number = 0): number {
    const field = fields.find((entry: ProtoField) => entry.number === number && entry.wire === 0); return field === undefined ? fallback : field.value;
  }
  static nested(fields: ProtoField[], number: number): ProtoField[][] { return fields.filter((entry: ProtoField) => entry.number === number && entry.wire === 2).map((entry: ProtoField) => CloudDriveWire.fields(entry.data)); }
  private static encodeInteger(value: number): Uint8Array {
    if (!Number.isSafeInteger(value) || value < 0) { throw new Error('CloudDrive 请求整数无效'); }
    const bytes: number[] = []; do { const part = value % 128; value = Math.floor(value / 128); bytes.push(part + (value > 0 ? 128 : 0)); } while (value > 0); return new Uint8Array(bytes);
  }
  static string(number: number, value: string): Uint8Array {
    const bytes = new util.TextEncoder().encodeInto(value);
    return CloudDriveWire.join([CloudDriveWire.encodeInteger(number * 8 + 2), CloudDriveWire.encodeInteger(bytes.length), bytes]);
  }
  static bool(number: number, value: boolean): Uint8Array { return CloudDriveWire.join([CloudDriveWire.encodeInteger(number * 8), new Uint8Array([value ? 1 : 0])]); }
  static frame(bytes: Uint8Array): Uint8Array {
    const header = new Uint8Array(5); const size = bytes.length;
    header[1] = Math.floor(size / 16777216) & 255; header[2] = Math.floor(size / 65536) & 255; header[3] = Math.floor(size / 256) & 255; header[4] = size & 255;
    return CloudDriveWire.join([header, bytes]);
  }
  private static decodeText(bytes: Uint8Array): Uint8Array {
    const raw = new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(bytes).replace(/\s/g, '');
    if (!/^[A-Za-z0-9+/=]*$/.test(raw)) { throw new Error('CloudDrive gRPC-Web 文本编码无效'); }
    const parts: Uint8Array[] = []; let start = 0;
    while (start < raw.length) {
      const padding = raw.indexOf('=', start); let end = padding < 0 ? raw.length : padding + 1;
      if (padding >= 0 && raw.charAt(end) === '=') { end++; }
      const piece = raw.substring(start, end);
      if (piece.length % 4 !== 0) { throw new Error('CloudDrive gRPC-Web Base64 帧不完整'); }
      parts.push(new util.Base64Helper().decodeSync(piece)); start = end;
    }
    return CloudDriveWire.join(parts);
  }
  static replies(data: Uint8Array, headers: Record<string, string>): Uint8Array[] {
    const contentType = headers['content-type'] !== undefined ? headers['content-type'].toLowerCase() : '';
    if (contentType.indexOf('application/grpc-web') < 0) { throw new Error('此 CloudDrive 端口未提供 gRPC-Web，请使用其官方 HTTP 服务或明确选择聚合 WebDAV'); }
    if (contentType.indexOf('grpc-web-text') >= 0) { data = CloudDriveWire.decodeText(data); }
    const replies: Uint8Array[] = []; let at = 0; let status = headers['grpc-status'] !== undefined ? headers['grpc-status'] : ''; let final = false;
    while (at < data.length) {
      if (data.length - at < 5 || final) { throw new Error('CloudDrive gRPC-Web 帧结构不完整'); }
      const flag = data[at]; const length = data[at + 1] * 16777216 + data[at + 2] * 65536 + data[at + 3] * 256 + data[at + 4]; at += 5;
      if (length > data.length - at) { throw new Error('CloudDrive gRPC-Web 消息被截断'); }
      const message = data.slice(at, at + length); at += length;
      if (flag === 128) {
        const trailers = new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(message).split(/\r?\n/);
        trailers.forEach((line: string) => { const colon = line.indexOf(':'); if (colon > 0 && line.substring(0, colon).trim().toLowerCase() === 'grpc-status') {
          const returned = line.substring(colon + 1).trim(); if (status.length > 0 && status !== returned) { throw new Error('CloudDrive grpc-status 前后不一致'); } status = returned;
        } }); final = true;
      } else if (flag === 0) { replies.push(message); if (replies.length > 512) { throw new Error('CloudDrive 流式回复超过上限'); } }
      else { throw new Error('CloudDrive 返回了不支持的压缩 gRPC-Web 帧'); }
    }
    if (!/^\d+$/.test(status)) { throw new Error('CloudDrive 流式回复缺少最终 grpc-status，不能确认目录完整'); }
    if (status !== '0') { throw new Error(status === '16' ? 'CloudDrive 访问令牌无效或权限不足' : status === '12' ? '此 CloudDrive 版本不支持所需方法，请升级服务或明确选择聚合 WebDAV' : 'CloudDrive RPC 失败（状态 ' + status + '）'); }
    return replies;
  }
}
