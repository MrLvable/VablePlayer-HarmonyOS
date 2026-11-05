/** Pure endpoint parsing shared by source forms and ServerConfig. No credentials or network access. */
export class SourceEndpointValue {
  host: string = '';
  port: number = 0;
  scheme: string = 'http';
  basePath: string = '';
}

export class SourceEndpoint {
  static normalize(address: string, portText: string, defaultPort: number,
    scheme: string = 'http', basePath: string = ''): SourceEndpointValue {
    let input = address.trim();
    if (input.length === 0) { throw new Error('请输入服务器地址'); }
    if (/\s|\\/.test(input)) { throw new Error('服务器地址不能包含空白或反斜杠'); }
    if (/[?#]/.test(input)) { throw new Error('服务器地址不能包含查询参数或片段，请填写服务根地址'); }
    let transport = scheme.toLowerCase();
    let explicitScheme = false;
    const prefix = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//.exec(input);
    if (prefix !== null) {
      transport = prefix[1].toLowerCase(); explicitScheme = true; input = input.substring(prefix[0].length);
    }
    if (transport !== 'http' && transport !== 'https' && transport !== 'smb') {
      throw new Error('地址协议仅支持 HTTP、HTTPS 或 SMB');
    }
    const slash = input.indexOf('/');
    const authority = slash >= 0 ? input.substring(0, slash) : input;
    const addressPath = slash >= 0 ? input.substring(slash) : '';
    if (authority.indexOf('@') >= 0) { throw new Error('请在用户名和密码栏填写凭据，不要把凭据放进地址'); }
    let host = '', embeddedPort = '';
    if (authority.startsWith('[')) {
      const closing = authority.indexOf(']');
      if (closing < 0) { throw new Error('IPv6 地址缺少右方括号'); }
      host = authority.substring(1, closing);
      const suffix = authority.substring(closing + 1);
      if (suffix.length > 0) {
        if (!suffix.startsWith(':') || suffix.length === 1) { throw new Error('IPv6 端口格式无效'); }
        embeddedPort = suffix.substring(1);
      }
      if (!SourceEndpoint.isIpv6(host)) { throw new Error('IPv6 地址格式无效'); }
    } else {
      const colons = authority.split(':').length - 1;
      if (colons > 1) {
        if (explicitScheme) { throw new Error('完整 URL 中的 IPv6 地址请使用方括号'); }
        host = authority;
        if (!SourceEndpoint.isIpv6(host)) { throw new Error('IPv6 地址格式无效'); }
      } else if (colons === 1) {
        const separator = authority.lastIndexOf(':');
        host = authority.substring(0, separator); embeddedPort = authority.substring(separator + 1);
        if (embeddedPort.length === 0) { throw new Error('冒号后缺少端口'); }
      } else { host = authority; }
      if (colons <= 1 && !SourceEndpoint.isHost(host)) { throw new Error('主机名或 IPv4 地址格式无效'); }
    }
    const typedPort = portText.trim();
    if (embeddedPort.length > 0 && typedPort.length > 0 && Number(embeddedPort) !== Number(typedPort)) {
      throw new Error('地址中的端口与端口栏不一致，请统一或清空端口栏');
    }
    const fallback = explicitScheme ? (transport === 'https' ? 443 : (transport === 'smb' ? 445 : 80)) : defaultPort;
    const selectedPort = embeddedPort.length > 0 ? embeddedPort : typedPort;
    const port = selectedPort.length > 0 ? SourceEndpoint.port(selectedPort) : fallback;
    if (!Number.isInteger(port) || port < 1 || port > 65535) { throw new Error('端口须为 1 到 65535 之间的整数'); }
    const path = SourceEndpoint.path(addressPath);
    const configuredPath = SourceEndpoint.path(basePath);
    if (path.length > 0 && configuredPath.length > 0 && path !== configuredPath) {
      throw new Error('地址中的路径与子路径栏不一致，请统一或清空子路径栏');
    }
    const result = new SourceEndpointValue();
    result.host = SourceEndpoint.normalizeHost(host);
    result.port = port; result.scheme = transport; result.basePath = configuredPath.length > 0 ? configuredPath : path;
    return result;
  }

  static baseUrl(scheme: string, host: string, port: number, basePath: string = ''): string {
    const transport = scheme.length > 0 ? scheme.toLowerCase() : 'http';
    let name = host.trim();
    if (name.startsWith('[') && name.endsWith(']')) { name = name.substring(1, name.length - 1); }
    if (name.indexOf(':') >= 0) {
      name = '[' + name.replace(/%(?!25)/g, '%25') + ']';
    }
    return transport + '://' + name + ':' + port.toString() + SourceEndpoint.path(basePath);
  }

  static path(value: string): string {
    let path = value.trim();
    if (path.length === 0 || path === '/') { return ''; }
    if (/[?#\\]|[\u0000-\u0020]/.test(path)) { throw new Error('子路径不能包含空白、查询参数或片段'); }
    if (/%(?![0-9a-fA-F]{2})/.test(path)) { throw new Error('路径的百分号编码无效'); }
    if (!path.startsWith('/')) { path = '/' + path; }
    const segments = path.split('/');
    for (let i = 0; i < segments.length; i++) {
      let decoded = '';
      try { decoded = decodeURIComponent(segments[i]); } catch (e) { throw new Error('路径编码无效'); }
      if (decoded === '.' || decoded === '..' || decoded.indexOf('\\') >= 0 || decoded.indexOf('/') >= 0) {
        throw new Error('路径不支持相对跳转或编码的目录分隔符');
      }
    }
    while (path.endsWith('/')) { path = path.substring(0, path.length - 1); }
    return encodeURI(path).replace(/%25([0-9a-fA-F]{2})/g, '%$1');
  }

  private static port(value: string): number {
    if (!/^[0-9]+$/.test(value)) { throw new Error('端口须为 1 到 65535 之间的整数'); }
    const port = Number(value);
    if (!Number.isInteger(port) || port < 1 || port > 65535) { throw new Error('端口须为 1 到 65535 之间的整数'); }
    return port;
  }

  private static isIpv4(value: string): boolean {
    const parts = value.split('.');
    if (parts.length !== 4) { return false; }
    for (let i = 0; i < parts.length; i++) {
      if (!/^(0|[1-9][0-9]{0,2})$/.test(parts[i]) || Number(parts[i]) > 255) { return false; }
    }
    return true;
  }

  private static isHost(value: string): boolean {
    if (value.length === 0 || value.length > 253) { return false; }
    if (/^[0-9.]+$/.test(value) && value.indexOf('.') >= 0) { return SourceEndpoint.isIpv4(value); }
    const labels = value.endsWith('.') ? value.substring(0, value.length - 1).split('.') : value.split('.');
    for (let i = 0; i < labels.length; i++) {
      if (labels[i].length === 0 || labels[i].length > 63 || !/^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$/.test(labels[i])) {
        return false;
      }
    }
    return true;
  }

  private static normalizeHost(value: string): string {
    const index = value.indexOf('%');
    if (index < 0) { return value.toLowerCase(); }
    const zone = value.substring(index + 1).replace(/^25/, '');
    return value.substring(0, index).toLowerCase() + '%' + zone;
  }

  private static isIpv6(value: string): boolean {
    let address = value;
    const zone = address.indexOf('%');
    if (zone >= 0) {
      const scope = address.substring(zone + 1).replace(/^25/, '');
      if (!/^[a-zA-Z0-9_.-]+$/.test(scope)) { return false; }
      address = address.substring(0, zone);
    }
    if (address.indexOf('.') >= 0) {
      const last = address.lastIndexOf(':');
      const dotted = address.substring(last + 1);
      if (last < 0 || !SourceEndpoint.isIpv4(dotted)) { return false; }
      address = address.substring(0, last + 1) + '0:0';
    }
    if (!/^[0-9a-fA-F:]+$/.test(address)) { return false; }
    const compressed = address.split('::');
    if (compressed.length > 2) { return false; }
    const left: string[] = compressed[0].length > 0 ? compressed[0].split(':') : [];
    const right: string[] = compressed.length === 2 && compressed[1].length > 0 ? compressed[1].split(':') : [];
    const all = left.concat(right);
    for (let i = 0; i < all.length; i++) { if (!/^[0-9a-fA-F]{1,4}$/.test(all[i])) { return false; } }
    return compressed.length === 2 ? all.length < 8 : all.length === 8;
  }
}
