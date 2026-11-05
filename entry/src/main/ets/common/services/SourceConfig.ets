import { ServerConfig } from '../Models';

/** Preserve endpoint and vault metadata when a legacy login returns a new account object. */
export class SourceConfig {
  static preserve(source: ServerConfig, target: ServerConfig): ServerConfig {
    target.scheme = source.scheme; target.basePath = source.basePath; target.rootPath = source.rootPath;
    target.sourceUrl = source.sourceUrl; target.epgUrl = source.epgUrl; target.authBrokerUrl = source.authBrokerUrl;
    target.authMode = source.authMode; target.connectionMode = source.connectionMode; target.domain = source.domain;
    target.shareName = source.shareName; target.clientId = source.clientId; target.credentialRef = source.credentialRef;
    target.password = source.password; target.clientSecret = source.clientSecret; target.refreshToken = source.refreshToken;
    target.clearCredentials = source.clearCredentials; return target;
  }
}
