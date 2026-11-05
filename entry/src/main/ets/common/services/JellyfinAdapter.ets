import { EmbyAdapter } from './EmbyAdapter';

/** Shares the documented Emby-compatible protocol, never the FnOS native session API. */
export class JellyfinAdapter extends EmbyAdapter {
  kind: string = 'jellyfin';
}
