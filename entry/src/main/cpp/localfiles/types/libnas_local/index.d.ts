export interface LocalFileStat { isDirectory: boolean; size: number; modifiedTime: number; }
export interface LocalDirectoryEntry extends LocalFileStat { name: string; }
export interface LocalOpenFile extends LocalFileStat { fd: number; }
interface LocalFdNative {
  list(rootFd: number, relativePath: string): Promise<LocalDirectoryEntry[]>;
  stat(rootFd: number, relativePath: string): Promise<LocalFileStat>;
  openChild(rootFd: number, relativePath: string): Promise<LocalOpenFile>;
  readSmall(rootFd: number, relativePath: string, maxBytes: number): Promise<ArrayBuffer>;
  closeFile(fd: number): Promise<void>;
}
declare const localFdNative: LocalFdNative;
export default localFdNative;
