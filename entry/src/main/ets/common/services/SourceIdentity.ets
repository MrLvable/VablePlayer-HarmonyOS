import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ServerConfig } from '../Models';

export class SourceIdentity {
  static key(value: string): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: new util.TextEncoder().encodeInto(value) });
    const bytes = digest.digestSync().data;
    let output = '';
    for (let index = 0; index < bytes.length; index++) { output += bytes[index].toString(16).padStart(2, '0'); }
    return output;
  }

  static account(server: ServerConfig): string {
    // A local token namespace is not a verified remote UID. Explicit token replacement
    // must be isolated, while OAuth's local namespace deliberately survives refresh.
    if (server.userId.length > 0 && !(server.authMode === 'token' && server.userId.startsWith('local:'))) { return server.userId; }
    return server.authMode === 'token' || server.authMode === 'oauth'
      ? (server.token.length > 0 ? SourceIdentity.key(server.token) : 'unauthorized')
      : server.username.length > 0 ? server.domain + ':' + server.username : 'anonymous';
  }

  static ensureLocalAccount(server: ServerConfig): void {
    // An app-local progress namespace, never a claimed remote user ID. OAuth refresh preserves it.
    if (server.userId.length === 0 || (server.authMode === 'token' && server.userId.startsWith('local:'))) {
      server.userId = 'local:' + SourceIdentity.key(server.kind + '\u0000' + SourceIdentity.account(server));
    }
  }

  static scope(server: ServerConfig): string {
    const account = SourceIdentity.account(server);
    return SourceIdentity.key([server.id, server.kind, server.connectionMode, server.scheme, server.host,
      server.port.toString(), server.basePath, server.rootPath, server.shareName,
      server.sourceUrl.length > 0 ? SourceIdentity.key(server.sourceUrl) : '', account].join('\u0000'));
  }
}
