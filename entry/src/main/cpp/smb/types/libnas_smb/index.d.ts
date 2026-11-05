export interface SmbConnectionOptions {
  server: string;
  share: string;
  username: string;
  password: string;
  domain: string;
  timeoutSeconds: number;
}
export interface SmbFileStat { type: number; isDirectory: boolean; size: number; modifiedTime: number; }
export interface SmbDirectoryEntry extends SmbFileStat { name: string; }
export interface SmbReadSession { sessionId: number; size: number; modifiedTime: number; }
interface NasSmbNative {
  listDirectory(options: SmbConnectionOptions, path: string): Promise<SmbDirectoryEntry[]>;
  stat(options: SmbConnectionOptions, path: string): Promise<SmbFileStat>;
  openRead(options: SmbConnectionOptions, path: string): Promise<SmbReadSession>;
  readAt(sessionId: number, offset: number, length: number, requestId: number): Promise<ArrayBuffer>;
  /** Cancels a pending read between bounded SMB requests; an in-flight network read observes its timeout. */
  cancelRead(requestId: number): void;
  /** Idempotent. Marks the session closing before waiting for its serialized native IO. */
  close(sessionId: number): Promise<void>;
}
declare const nasSmbNative: NasSmbNative;
export default nasSmbNative;
