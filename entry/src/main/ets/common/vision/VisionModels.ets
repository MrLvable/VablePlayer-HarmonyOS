import { ServerConfig, MediaItem } from '../Models';

export class VisionReference {
  key: string = '';
  serverId: string = '';
  accountScope: string = '';
  item: MediaItem = new MediaItem();
  addedAt: number = 0;
}
export class VisionPlaylist {
  id: string = '';
  accountScope: string = '';
  name: string = '';
  entries: VisionReference[] = [];
  createdAt: number = 0;
}
export class VisionRow {
  key: string = '';
  server: ServerConfig;
  item: MediaItem;
  title: string = '';
  positionMs: number = 0;
  durationMs: number = 0;
  updatedAt: number = 0;
  constructor(server: ServerConfig, item: MediaItem) { this.server = server; this.item = item; this.title = item.seriesName.length > 0 ? item.seriesName : item.name; }
}
export class VisionSnapshot {
  watchLater: VisionReference[] = [];
  playlists: VisionPlaylist[] = [];
}
export class VisionState {
  scope: string = '';
  section: number = 0;
  watchLater: VisionRow[] = [];
  watching: VisionRow[] = [];
  calendar: VisionRow[] = [];
  playlists: VisionPlaylist[] = [];
  selectedPlaylistId: string = '';
  filterServerId: string = '';
  errors: string[] = [];
  busy: boolean = false;
  calendarBusy: boolean = false;
  calendarUnknown: boolean = false;
  calendarError: string = '';
}
