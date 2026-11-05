import { ServerConfig } from '../Models';

export class SourceAuthorization {
  provider: string = '';
  clientId: string = '';
  deviceCode: string = '';
  userCode: string = '';
  verificationUrl: string = '';
  expiresAt: number = 0;
  intervalSeconds: number = 5;
  nextPollAt: number = 0;
  deviceId: string = '';
  projectId: string = '';
}

export class SourceAuthPoll {
  state: 'pending' | 'slow' | 'denied' | 'expired' | 'authorized' = 'pending';
  server: ServerConfig | null = null;
  message: string = '';
  intervalSeconds: number = 5;
}

export type SourceTokenRotation = (server: ServerConfig, expectedCredentialRef: string) => Promise<void>;

export class SourceAuthConfig {
  static copy(source: ServerConfig): ServerConfig {
    const next = new ServerConfig(source.id, source.kind, source.name, source.host, source.port, source.username,
      source.token, source.userId, source.serverName, source.version, source.nativeToken);
    next.scheme = source.scheme; next.basePath = source.basePath; next.rootPath = source.rootPath;
    next.sourceUrl = source.sourceUrl; next.epgUrl = source.epgUrl; next.authBrokerUrl = source.authBrokerUrl;
    next.authMode = source.authMode; next.connectionMode = source.connectionMode; next.domain = source.domain;
    next.shareName = source.shareName; next.clientId = source.clientId; next.credentialRef = source.credentialRef;
    next.password = source.password; next.clientSecret = source.clientSecret; next.refreshToken = source.refreshToken;
    next.credentialError = source.credentialError; return next;
  }
}
