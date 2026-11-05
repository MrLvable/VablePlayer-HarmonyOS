import { router, window, promptAction, display, uiMaterial, SymbolGlyphModifier, curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ServerConfig, Library, MediaItem, ItemDetail, PlayParams, SubtitleTrack, Person, MediaStream, PlaybackInfo } from '../common/Models';
import { LibraryBackdrop } from '../components/LibraryBackdrop';
import { MediaServices } from '../common/services/MediaServices';
import { Store } from '../common/Store';
import { ProgressRepository, ProgressRecordV2 } from '../common/ProgressRepository';
import {
  HdsVisualComponent,
  HdsSceneController,
  HdsSceneType,
  DualEdgeFlowLightWithMaskParam,
  hdsEffect
} from '@kit.UIDesignKit';
import { MediaCache, ClearResult } from '../common/MediaCache';
import { Dbg } from '../common/Dbg';
import {
  HdsNavigation,
  HdsNavigationMenuContentOptions,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { DominantColor } from '../common/DominantColor';
import { Ambient, AmbientPalette, HeroMask } from '../common/Ambient';
import { DownloadManager, DownloadRecord, DownloadState } from '../common/DownloadManager';
import { Push } from '../common/Push';
import { C, Motion, Layout, Theme, ThemeMode, Palette, Size, Radius, withAlpha, mix, hexToRgb, rgbToHex } from '../common/Theme';
import { PosterCard } from '../components/PosterCard';
import { NetImage } from '../components/NetImage';
import { HeroArtwork, HeroPullTracker } from '../common/HeroArtwork';
import { SourceProfiles, SourceProfile, SourceDraft, SourceValidatedDraft } from '../common/SourceProfiles';
import { LocalAccess } from '../common/services/LocalAccess';
import { SourceBrowser } from '../components/SourceBrowser';
import { SourceIdentity } from '../common/services/SourceIdentity';
import { SourceAuthorization } from '../common/services/SourceAuthorization';
import { SourcePlaybackLeases } from '../common/SourcePlaybackLeases';
import { SourcePlaybackPolicy } from '../common/SourcePlaybackPolicy';
import { BottomBar } from '../components/BottomBar';
import { Metrics } from '../common/Metrics';
import { MotionSpec, MotionCurve, MotionPref } from '../common/MotionSpec';
import { MotionFx } from '../common/MotionFx';
import { Materials } from '../common/Materials';
import { PlaybackSettings } from '../components/PlaybackSettings';
import { PlaybackPreferences } from '../common/PlaybackPreferences';
import { ServerOptions, ServerOption, ServerBackupNode } from '../common/ServerOptions';
import { VisionPage } from '../components/VisionPage';
import { VisionStore } from '../common/vision/VisionStore';

/**
 * Hero 边缘流光 Debug 开关（方案 §5.5）。
 * ★ 默认关闭：录屏并不能证明参考在播持续边缘扫光；官方 HdsVisualComponent
 *   的双边流光在旧实现里被不透明海报盖住，也从未做过同图 A/B。
 *   需要对比时改成 true，并固定一张静图、禁用轮播再录。
 */
const HERO_FLOW_LIGHT: boolean = false;

/**
 * Hero 项数调试上限（正常为 0）。
 * 只用来在真机上复现数据边界：1 项（不循环/不自动切/无指示器）、
 * 2 项（首尾衔接）、-1（强制空态，等价于全部海报加载失败）。
 * 生产值必须是 0。
 */
const HERO_DEBUG_LIMIT: number = 0;

class LibRow {
  lib: Library = new Library('', '', '');
  items: MediaItem[] = [];

  constructor(lib: Library, items: MediaItem[]) {
    this.lib = lib;
    this.items = items;
  }
}

@Entry
@Component
struct Index {
  /* ── 全局状态 ── */
  @State servers: ServerConfig[] = [];
  @State private visionRevision: number = 0;
  @State private detailWatchLater: boolean = false;
  @State private tmdbPreferred: string = '';
  @State private tmdbAutoInclude: boolean = true;
  @State private tmdbExcluded: string[] = [];
  @State @Watch('onCurrentServerChanged') current: ServerConfig | null = null;
  @State @Watch('onShellChange') currentTab: number = 0;
  @State @Watch('onShellChange') showSearch: boolean = false;
  @State searchQuery: string = '';
  @State searchResults: MediaItem[] = [];
  @State searching: boolean = false;
  @State favorites: MediaItem[] = [];
  @State private favoritesLoading: boolean = false;
  @State private favoritesError: string = '';
  private favoritesScope: string = '';
  private favoritesGeneration: number = 0;
  private favoriteMutationPending: boolean = false;
  @State libItems: MediaItem[] = [];
  @State @Watch('onShellChange') browsingLib: Library | null = null;
  /* Library-only reference layout; no state is shared with the home Hero. */
  @State private libMode: number = 0;
  @State private libWideCards: boolean = false;
  @State private libSort: number = 0;
  @State private libDescending: boolean = false;
  @State private libSortOpen: boolean = false;
  @State private libGenre: string = '';
  @State private libHeroIndex: number = 0;
  @State private libVisibleItems: MediaItem[] = [];
  @State private libHeroItems: MediaItem[] = [];
  @State private libLoading: boolean = false;
  @State private libError: string = '';
  @State private libFavoriteError: string = '';
  @State private libFavoriteIds: string[] = [];
  @State private libFavoritesLoading: boolean = false;
  @State private libFavoritesLoaded: boolean = false;
  @State private libAmbient: string = '';
  private libServer: ServerConfig | null = null;
  private libGeneration: number = 0;
  private libFavoriteGeneration: number = 0;
  private libAmbientKey: string = '';
  private libAmbientCache: Map<string, string> = new Map<string, string>();
  private librarySwiper: SwiperController = new SwiperController();
  private libraryScroller: Scroller = new Scroller();
  private librarySortLabels: string[] = ['名称', '添加时间', '上映时间', '影片评分', '随机'];
  @State people: Person[] = [];
  @State @Watch('onShellChange') locked: boolean = false;
  @State tmdbKey: string = '';
  @State showTmdbInput: boolean = false;
  @State tmdbInput: string = '';
  @State @Watch('onShellChange') showDownloads: boolean = false;
  @State downloads: DownloadRecord[] = [];
  @State pushEnabled: boolean = false;
  @StorageLink('themeMode') @Watch('onLookChange') themeMode: string = 'system';
  /** 清理缓存后自增，触发占用文案重绘 */
  @State private cacheRev: number = 0;
  /**
   * 系统深色状态响应式订阅（方案 R06）。
   * ★ 旧实现只在某一处 AppStorage.get 读一次，系统切深浅色时
   *   页面不重绘、系统栏样式也不重新应用。
   */
  @StorageProp('sysDark') @Watch('onLookChange') sysDark: boolean = false;
  /** R11：应用是否在前台（EntryAbility 写入；后台必须停 Hero 轮播） */
  @StorageProp('appActive') @Watch('onLookChange') appActive: boolean = true;
  /** 当前窗口尺寸（R08：旋转/分屏时更新，驱动布局重算） */
  @State private winW: number = 0;
  @State private winH: number = 0;
  private winRef: window.Window | null = null;
  private appliedNativeColorMode: ConfigurationConstant.ColorMode | undefined = undefined;
  private diagLookAt: number = 0;

  /**
   * 官方「双边流光」场景控制器（HDS HdsVisualComponent）。
   * 放在 Hero 大图上：面积大、流光扫过海报时效果明显，
   * 比放在 dock 那种小区域合适得多（dock 已恢复手写玻璃保证可读性）。
   */
  private heroSceneCtl: HdsSceneController = new HdsSceneController();
  @StorageLink('accentColor') accentColor: string = '#317AF7';
  @State loading: boolean = false;
  @State errMsg: string = '';
  @State ready: boolean = false;
  @State private launchVisible: boolean = AppStorage.get<boolean>('nasplayer.launchIntroPlayed') !== true;
  @State private launchScale: number = 1;
  @State private launchOpacity: number = 1;
  private launchStarted: boolean = false;
  private launchGeneration: number = 0;
  private launchFrameTask: number = -1;
  private launchFinishTask: number = -1;

  /* ── 首页 ── */
  @State libs: Library[] = [];
  @State heroItems: MediaItem[] = [];
  @State heroIndex: number = 0;
  @State ambientRgb: number = -1;
  @State ambientFrom: string = '';

  /* ══════ R10：连续空间氛围（三带取色 + 可见权重混合）══════ */
  /** A 槽 = 已提交项，B 槽 = 正在进入视口的相邻项，ambW = 向 B 的权重 */
  @State private ambA: AmbientPalette = AmbientPalette.empty();
  @State private ambB: AmbientPalette = AmbientPalette.empty();
  @State private ambW: number = 0;
  /** 四个最终显示颜色：底色 + 上/中/下三个色场（每帧只算一次混合） */
  @State private ambBaseC: string = '';
  @State private ambTopC: string = '';
  @State private ambMidC: string = '';
  @State private ambBotC: string = '';
  private ambAKey: string = '';
  private ambBKey: string = '';
  private ambTicker: number = -1;
  private lastScrollCbAt: number = 0;
  private ambLogAt: number = 0;
  /** dock 的 5 个页签名 */
  private dockLabels: string[] = ['首页', '发现', '收藏', '服务器', '设置'];
  /** DIAG：切换期间的颜色序列打点（定位「闪一下」用，定位完删） */
  private ambSeqAt: number = 0;

  /* ══════ R11：Hero 交互 / 可见生命周期 ══════ */
  @State private heroOnScreen: boolean = true;
  @State private heroAllFailed: boolean = false;
  /** 首页滚动可见进度，只用于暂停已滚出视口的轮播。 */
  @State private heroScrollP: number = 0;
  private homeScrollMounted: boolean = false;
  private homeScrollPageVisible: boolean = false;
  private homeScrollTask: number = -1;
  private homeScrollGeneration: number = 0;
  private pendingHomeScrollY: number = Number.NaN;
  @State private homeArtworkPull: number = 0;
  @State private detailArtworkPull: number = 0;
  @State private detailArtworkRatio: number = 16 / 9;
  private homePull: HeroPullTracker = new HeroPullTracker();
  private detailPull: HeroPullTracker = new HeroPullTracker();
  private detailScroller: Scroller = new Scroller();
  private detailPullTask: number = -1;
  private detailPullGeneration: number = 0;
  private detailArtworkSizeTask: number = -1;
  private pendingDetailArtworkRatio: number = 16 / 9;
  private pendingDetailArtworkUrl: string = '';
  private pendingDetailArtworkScope: string = '';
  private heroTouching: boolean = false;
  @State resumeItems: MediaItem[] = [];
  @State rows: LibRow[] = [];

  /* ── 详情 ── */
  @State @Watch('onShellChange') detailItem: MediaItem | null = null;
  @State detail: ItemDetail | null = null;
  @State seasons: MediaItem[] = [];
  @State episodes: MediaItem[] = [];
  @State curSeasonId: string = '';

  /* ── 添加服务器表单 ── */
  @State @Watch('onShellChange') showAdd: boolean = false;
  /** 空 = 新增；非空 = 编辑该服务器 */
  @State private editingId: string = '';
  @State private sourceDraft: SourceDraft = new SourceDraft();
  @State private sourceFormPhase: string = 'idle';
  @State private sourceFormError: string = '';
  @State private sourceFormStatus: string = '';
  @State private sourceClearCredentials: boolean = false;
  @State private sourceAuthFlow: SourceAuthorization | null = null;
  private sourceAuthServer: ServerConfig | null = null;
  private sourceRequestGeneration: number = 0;

  private swiperCtl: SwiperController = new SwiperController();
  private tabCtl: HdsTabsController = new HdsTabsController();

  /* ══════════ R16：子页 Navigation 栈 ══════════
   * 详情 / 搜索 / 媒体库 / 下载 四个子页从「Index 内部 if/else 覆盖层」
   * 迁到真正的 Navigation 栈：
   *   · Root 永远是一级 Tabs（Dock 只在 Root 可见，push 后被覆盖）
   *   · 系统返回手势由 Navigation 自己 pop，不用手工逐层判断
   *   · 每个子页是独立 NavDestination，状态互不干扰
   */
  // Navigation attaches its native bridge while building. Keep this stable
  // controller outside @State: its own native callback drives destination updates.
  private readonly navStack: NavPathStack = new NavPathStack();
  /** 自己维护栈内页面名，用来在 pop 时精确清理对应业务状态 */
  private navNames: string[] = [];

  private pushSubpage(name: string): void {
    this.navNames = this.stackNames();
    this.navNames.push(name);
    this.navStack.pushPathByName(name, '');
    hilog.info(0x0001, 'NasPlay', 'NAV push %{public}s depth=%{public}d',
      name, this.navNames.length);
  }

  /**
   * 栈内页面名，以 NavPathStack 为准。
   * ★ 真机发现：系统返回/手势是 Navigation 自己 pop 的，onBackPress 根本不会被调用，
   *   所以自己维护的 navNames 会和真实栈不同步（表现为「返回后再进同一个库没反应」）。
   */
  private stackNames(): string[] {
    const out: string[] = [];
    try {
      const names = this.navStack.getAllPathName();
      for (let i = 0; i < names.length; i++) {
        out.push(names[i]);
      }
    } catch (e) {
      return this.navNames;
    }
    return out;
  }

  /** 打开子页（幂等：已经在栈里就不再压栈） */
  private ensureSubpage(name: string): void {
    if (this.stackNames().indexOf(name) >= 0) {
      return;
    }
    this.pushSubpage(name);
  }

  /** 页面被播放器路由覆盖时仍在栈中；仅在真正出栈后清理业务状态。 */
  private onSubpageGone(name: string): void {
    const actual = this.stackNames();
    this.navNames = actual;
    if (actual.indexOf(name) >= 0) {
      hilog.info(0x0001, 'NasPlay', 'NAV covered %{public}s depth=%{public}d',
        name, actual.length);
      return;
    }
    this.clearSubState(name);
    hilog.info(0x0001, 'NasPlay', 'NAV gone %{public}s depth=%{public}d',
      name, this.navNames.length);
  }

  private clearSubState(name: string): void {
    if (name === 'detail') {
      this.detailItem = null;
      this.detail = null;
      this.people = [];
    } else if (name === 'search') {
      this.showSearch = false;
      this.searchQuery = '';
      this.searchResults = [];
    } else if (name === 'library') {
      this.closeLibrary();
    } else if (name === 'server-options') {
      this.serverOptionGeneration++; this.serverOptionBusy = false;
      this.serverOptionPin = ''; this.serverOptionOldPin = ''; this.serverOptionConfirmPin = ''; this.serverOptionError = '';
    } else if (name === 'settings:servers') {
      this.showHiddenSources = false;
    } else if (name === 'source') {
      this.invalidateSourceRequest(); this.showAdd = false; this.editingId = '';
      this.clearSourceAuthorization();
    } else if (name === 'downloads') {
      this.showDownloads = false;
    }
  }

  /** pop 栈顶并清理它的状态 */
  private popSubpage(): boolean {
    this.navNames = this.stackNames();
    const name = this.navNames.pop();
    if (name === undefined) {
      return false;
    }
    this.navStack.pop();
    // Shell watchers must see the real post-pop stack when resuming the home.
    this.clearSubState(name);
    hilog.info(0x0001, 'NasPlay', 'NAV pop %{public}s depth=%{public}d',
      name, this.navNames.length);
    return true;
  }

  /** 关掉指定子页（页内「返回/关闭」按钮用），必要时连续 pop */
  private popNamed(name: string): void {
    this.navNames = this.stackNames();
    const at = this.navNames.lastIndexOf(name);
    if (at < 0) {
      this.clearSubState(name);
      return;
    }
    while (this.navNames.length > at) {
      if (!this.popSubpage()) {
        break;
      }
    }
  }

  /**
   * 系统返回 / 手势返回
   * ★ R16：子页栈优先（Navigation 负责转场），其次回首页 Tab，最后才退出
   */
  onBackPress(): boolean {
    if (this.showAdd && (this.sourceFormPhase === 'saving' || this.sourceFormPhase === 'deleting')) { return true; }
    if (this.locked) {
      return true;              // 锁屏状态不响应返回
    }
    if (this.popSubpage()) {
      return true;
    }
    if (this.currentTab !== 0) {
      this.currentTab = 0;
      return true;
    }
    return false;               // 首页再按就退出
  }

  /**
   * 页面重新可见时刷新「继续观看」（方案 9.4）。
   * 从播放器返回、切 tab 回来都会触发；只在需要时重读，不重载整个首页。
   */
  onPageShow(): void {
    this.homeScrollPageVisible = true;
    const previous = this.current;
    if (previous !== null) {
      // cached() recomputes the in-memory PIN expiry synchronously. The fresh
      // storage check below still gates all resumed content requests.
      const option = ServerOptions.cached(previous.id);
      if (option === null || option.locked) { this.clearProtectedSource(previous.id); }
    }
    this.syncHomeScroll(); this.heroTouching = false;
    this.refreshSourceProtection().then(() => {
      if (!this.homeScrollMounted || !this.homeScrollPageVisible || this.current === null) { return; }
      this.loadResume(this.current); this.restartHeroTimer();
    }).catch(() => {});
  }

  onPageHide(): void {
    this.cancelLaunchIntro();
    this.visionActionGeneration++;
    this.playRequestGeneration++;
    this.invalidateSourceRequest();
    this.homeScrollPageVisible = false;
    this.cancelHomeScrollSync();
    this.heroTouching = false;
    this.stopHeroTimer();
  }

  aboutToDisappear(): void {
    this.cancelLaunchIntro();
    this.visionActionGeneration++;
    this.playRequestGeneration++;
    this.invalidateSourceRequest();
    this.homeScrollMounted = false;
    this.homeScrollPageVisible = false;
    this.cancelHomeScrollSync();
    this.stopHeroTimer();
    this.clearAmbTicker();
    // R08：解绑窗口监听
    if (this.winRef !== null) {
      try {
        this.winRef.off('windowSizeChange');
      } catch (e) {
      }
      this.winRef = null;
    }
  }

  aboutToAppear(): void {
    this.homeScrollMounted = true;
    this.homeScrollPageVisible = true;
    this.startLaunchIntro();
    this.measureInsets();
    Theme.init();
    this.applyNativeColorMode();
    // ★ 屏幕尺寸检测：设备类型用官方 deviceInfo，视口档位用窗口尺寸
    try {
      const d = display.getDefaultDisplaySync();
      Metrics.init(px2vp(d.width), px2vp(d.height));
    } catch (e) {
      Metrics.init(440, 0);
    }
    // ★★ 方案 R08：旋转 / 分屏 / 折叠屏展开都要重新测量。
    //   旧实现只在 aboutToAppear 调一次 display.getDefaultDisplaySync()，
    //   那是物理屏尺寸，窗口变化（横竖屏、分屏）根本不响应。
    this.watchWindowSize();
    this.boot();
  }

  /**
   * 监听窗口尺寸变化（方案 R08）。
   * 旋转、分屏、折叠屏展开都会触发；重新计算 sizeClass 并触发重绘。
   */
  private watchWindowSize(): void {
    try {
      window.getLastWindow(getContext(this)).then((win) => {
        this.winRef = win;
        win.on('windowSizeChange', (size: window.Size) => {
          const w: number = px2vp(size.width);
          const h: number = px2vp(size.height);
          const oldW: number = Metrics.width();
          if (Math.abs(w - oldW) < 1) {
            return;
          }
          Metrics.init(w, h);
          this.winW = w;
          this.winH = h;
        });
      }).catch(() => {
      });
    } catch (e) {
    }
  }

  /** 海报网格的列模板（电视 7 列 / 平板 5 列 / 手机 4 列） */
  private gridTemplate(): string {
    const n = Metrics.gridColumns();
    let t = '1fr';
    for (let i = 1; i < n; i++) {
      t = t + ' 1fr';
    }
    return t;
  }

  /** 当前是否深色 */
  private dark(): boolean {

    if (this.themeMode === 'dark') {
      return true;
    }
    if (this.themeMode === 'light') {
      return false;
    }
    // ★ 跟随系统：用 @StorageProp('sysDark') 响应式订阅
    //   （旧实现是 AppStorage.get 一次性读取 —— 系统切深浅色不重绘）
    return this.sysDark;
  }

  /** 当前色板 */
  private P(): Palette {
    const p = this.dark() ? Palette.dark() : Palette.light();
    const a = this.accentColor;
    if (a !== undefined && a.length > 0) {
      p.accent = a;
    }
    return p;
  }

  async boot(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    let list: ServerConfig[] = [];
    try {
      await Store.init(ctx);
      MediaServices.configureCredentials();
      list = await Store.loadServers();
      this.downloads = await DownloadManager.restore(ctx);
    } catch (e) {
      // ★ 清过应用数据 / Preferences 损坏时不能整页崩掉：
      //   真机上 bm clean -d 后 Store.init 抛未捕获异常，进程直接被杀。
      hilog.info(0x0001, 'NasPlay', 'BOOT store init failed, fallback to demo');
      this.servers = [];
      this.ready = true;
      this.loadDemo();
      return;
    }
    this.servers = list;
    await this.reloadServerOptions();
    await PlaybackPreferences.load();
    this.serverViewMode = await Store.get('server_view_mode', '1') === '0' ? 0 : 1;
    try { this.serverOrder = JSON.parse(await Store.get('server_order', '[]')) as string[]; } catch (error) { this.serverOrder = []; }
    this.tmdbPreferred = await Store.get('tmdb_preferred_source', '');
    this.tmdbAutoInclude = await Store.get('tmdb_auto_include', '1') !== '0';
    try { this.tmdbExcluded = JSON.parse(await Store.get('tmdb_excluded_sources', '[]')) as string[]; } catch (error) { this.tmdbExcluded = []; }
    this.ready = true;

    // 读 TMDB key
    this.tmdbKey = await Store.getTmdbKey();

    // r29: passwords protect individual stations. Retire only the obsolete
    // application-wide flags; ServerOptions PINs and credentials stay intact.
    try { await Store.retireLegacyApplicationLock(); }
    catch (error) { hilog.warn(0x0001, 'NasPlay', 'Legacy lock flags could not be cleared; app-wide locking remains retired'); }
    const lastId = await Store.getLastId();
    if (lastId.length > 0) {
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === lastId && !(await ServerOptions.isLocked(list[i].id)) && !this.serverOption(list[i].id).hidden) {
          this.current = list[i];
          this.loadLibraries();
          break;
        }
      }
    }
    // Demo content is only for a new installation. A saved but locked source
    // returns to its real server card so no sample library is mistaken for data loss.
    if (this.current === null) {
      if (list.length === 0) { this.loadDemo(); }
      else { this.selectTab(3); }
    }
  }

  /* ══════════ 数据加载 ══════════ */

  async loadLibraries(): Promise<void> {
    const s = this.current;
    if (s === null) {
      return;
    }
    const scope = SourceIdentity.scope(s);
    try {
      if (await ServerOptions.isLocked(s.id)) { this.clearProtectedSource(s.id); return; }
    } catch (error) { this.clearProtectedSource(s.id); return; }
    if (!this.homeScrollMounted || !this.homeScrollPageVisible || this.current === null || SourceIdentity.scope(this.current) !== scope) { return; }
    if (this.sourceFamily() !== 'catalog') {
      this.stopHeroTimer(); this.heroItems = []; this.rows = []; this.libs = []; this.resumeItems = [];
      this.loading = false; this.errMsg = ''; return;
    }
    // ★ 切服务器后：坏图记录与取色缓存都必须按新账号重来（方案 T04）
    if (this.badHeroScope !== s.id) {
      this.badHeroScope = s.id;
      this.badHeroIds = [];
      this.heroAllFailed = false;
      Ambient.reset();
    }
    this.loading = true;
    this.errMsg = '';
    try {
      const ls = await MediaServices.getViews(s);
      if (this.current === null || SourceIdentity.scope(this.current) !== SourceIdentity.scope(s)) {
        hilog.info(0x0001, 'NasPlay', 'SERVER stale views, drop');
        return;
      }
      this.libs = ls;

      // 并行拉：继续播放 + 每个库最新
      this.loadResume(s);
      this.loadRows(s, ls);

      // Hero：用各库最新里评分最高的
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errMsg = (e as Error).message;
    }
  }

  /**
   * 继续播放
   * ★ 飞牛服务器不存播放进度（Resume/IsResumable 实测全空），
   *   所以先读本地记录，再按 id 回服务器补详情
   */
  /**
   * 继续观看 —— 读 V2 仓储
   *
   * ★ 旧实现把 JSON 当对象数组直接读 arr[i]['id']，而写入侧存的是
   *   string[]（每条先 stringify），所以 id 永远取不到，此功能从未生效。
   *   现在统一走 ProgressRepository，并在首次调用时迁移旧数据。
   */
  async loadResume(s: ServerConfig): Promise<void> {
    const out: MediaItem[] = [];
    try {
      // 首次运行：迁移旧格式（幂等）
      await ProgressRepository.migrateLegacy(s.id, s.userId);

      // 先多取一些，再按“部剧”归并。否则一部近期反复观看的剧会占满
      // 继续播放的 12 个槽位，把其它剧全挤掉。
      const recs: ProgressRecordV2[] = await ProgressRepository.loadForAccount(s.id, s.userId, 40);
      if (this.current === null || SourceIdentity.scope(this.current) !== SourceIdentity.scope(s)) {
        return;
      }
      recs.sort((a: ProgressRecordV2, b: ProgressRecordV2): number => {
        return b.updatedAt - a.updatedAt;
      });
      const seenGroups: Set<string> = new Set<string>();
      for (let i = 0; i < recs.length; i++) {
        const r = recs[i];
        // 同一部剧只显示最近播放的一集，只保留一张继续播放卡。
        // 剧集记录缺 seriesId 时按标题归并；电影仍按 itemId 独立。
        let group = 'item:' + r.itemId;
        if (r.seriesId.length > 0) {
          group = 'series:' + r.seriesId;
        } else if (r.itemType === 'Episode' && r.title.length > 0) {
          group = 'series-title:' + r.title;
        }
        if (seenGroups.has(group)) {
          continue;
        }
        seenGroups.add(group);
        const item = new MediaItem();
        item.id = r.itemId;
        item.name = r.episodeTitle.length > 0 ? r.episodeTitle : r.title;
        item.seriesName = r.title;
        item.seriesId = r.seriesId;
        item.type = r.itemType;
        item.indexNumber = r.episodeNumber;
        item.parentIndexNumber = r.seasonNumber;
        item.imageTag = r.imageTag;
        item.hasPrimaryImage = r.imageTag.length > 0 || r.seriesId.length > 0;
        item.progressTicks = Math.round(r.positionMs * 10000);
        item.runtimeTicks = Math.round(r.durationMs * 10000);
        out.push(item);
        if (out.length >= 12) {
          break;
        }
      }
    } catch (e) {
      // 读失败就空列表，不阻塞首页
    }

    // 本地快照立即显示（方案 9.4：不等网络详情）
    this.resumeItems = out;

    // 后台并发补详情（上限 3，失败保留旧卡片）
    this.enrichResume(out);
  }

  /**
   * 并发补全继续观看条目的海报 tag / 真实 type。
   * 失败静默保留本地快照，不阻塞渲染。
   */
  private async enrichResume(list: MediaItem[]): Promise<void> {
    const sv = this.current;
    if (sv === null) {
      return;
    }
    const limit = Math.min(6, list.length);
    for (let i = 0; i < limit; i++) {
      const it = list[i];
      try {
        const d = await MediaServices.getItemDetail(sv, it.id);
        it.name = d.item.name.length > 0 ? d.item.name : it.name;
        it.seriesName = d.item.seriesName.length > 0 ? d.item.seriesName : it.seriesName;
        it.type = d.item.type;
        it.imageTag = d.item.imageTag;
        it.hasPrimaryImage = d.item.hasPrimaryImage;
        it.parentIndexNumber = d.item.parentIndexNumber;
        it.indexNumber = d.item.indexNumber;
        if (d.item.runtimeTicks > 0) {
          it.runtimeTicks = d.item.runtimeTicks;
        }
      } catch (e) {
        // 补详情失败不该影响卡片渲染，但要看得到失败，不要静默
        hilog.info(0x0001, 'Resume', 'enrich failed idx=%{public}d id=%{public}s',
          i, it.id);
      }
    }
    // 触发重绘
    const copy: MediaItem[] = [];
    for (let i = 0; i < list.length; i++) {
      copy.push(list[i]);
    }
    this.resumeItems = copy;
  }

  /**
   * 无服务器时的示例数据 —— **只为展示界面形态，不是真实内容**。
   * 图片 URL 会因 current === null 返回空，卡片/Hero 走各自的占位样式，
   * 这样用户在没有服务器时也能看到产品长什么样，而不是一个孤零零的按钮。
   */
  /** 示例模式：用内置示例图（不请求网络、不是真实数据） */
  private isDemo(item: MediaItem): boolean {
    return item.id.startsWith('demo_');
  }

  private demoIndexOf(item: MediaItem): number {
    const s: string = item.id.substring(5);
    const v: number = Number.parseInt(s);
    return isNaN(v) ? 0 : v % 6;
  }

  private demoImage(item: MediaItem): Resource {
    const n: number = this.demoIndexOf(item);
    if (n === 0) {
      return $r('app.media.demo_poster_1');
    }
    if (n === 1) {
      return $r('app.media.demo_poster_2');
    }
    if (n === 2) {
      return $r('app.media.demo_poster_3');
    }
    if (n === 3) {
      return $r('app.media.demo_poster_4');
    }
    if (n === 4) {
      return $r('app.media.demo_poster_5');
    }
    return $r('app.media.demo_poster_6');
  }

  private demoItems(): MediaItem[] {
    const names: string[] = ['星际穿越者', '山海纪年', '深海回响', '夜行记',
      '光影之城', '长夜将至', '风起长林', '雾中列车'];
    const out: MediaItem[] = [];
    for (let i = 0; i < names.length; i++) {
      const m = new MediaItem();
      m.id = 'demo_' + i.toString();
      m.name = names[i];
      m.seriesName = names[i];
      m.type = i % 2 === 0 ? 'Movie' : 'Series';
      m.year = 2018 + (i % 6);
      m.rating = Math.round((7.2 + (i % 4) * 0.5) * 10) / 10;
      m.overview = '这是示例简介，用于展示排版与间距。添加服务器后会显示你的真实影库内容。';
      m.runtimeTicks = 6000 * 10000;
      m.progressTicks = (600 + i * 300) * 10000;
      m.indexNumber = i + 1;
      m.parentIndexNumber = 1;
      out.push(m);
    }
    return out;
  }

  private loadDemo(): void {
    try {
      this.applyDemo();
    } catch (e) {
      hilog.info(0x0001, 'NasPlay', 'DEMO build failed');
    }
  }

  private applyDemo(): void {
    const items = this.demoItems();
    this.heroItems = items.slice(0, 5);
    this.resumeItems = items.slice(0, 3);
    const lib1 = new Library('demo_lib_1', '我的媒体', 'CollectionFolder');
    const lib2 = new Library('demo_lib_2', '电影', 'CollectionFolder');
    const lib3 = new Library('demo_lib_3', '电视剧', 'CollectionFolder');
    this.libs = [lib1, lib2, lib3];
    this.rows = [
      new LibRow(lib2, items.slice(0, 4)),
      new LibRow(lib3, items.slice(4, 8))
    ];
    this.heroIndex = 0;
    // 示例模式默认停在首页，否则会停在「发现」页（那里只有 TMDB 配置提示）
    this.currentTab = 0;
    this.primeAmbient();

    hilog.info(0x0001, 'NasPlay', 'DEMO mode: %{public}d hero, %{public}d rows',
      this.heroItems.length, this.rows.length);
  }

  async loadRows(s: ServerConfig, ls: Library[]): Promise<void> {
    const out: LibRow[] = [];
    for (let i = 0; i < ls.length; i++) {
      try {
        const items = await MediaServices.getLatest(s, ls[i].id, 16);
      if (this.current === null || SourceIdentity.scope(this.current) !== SourceIdentity.scope(s)) {
        return;
      }
        if (items.length > 0) {
          out.push(new LibRow(ls[i], items));
        }
      } catch (e) {
        // 单个库失败不影响其他
      }
    }
    if (this.current === null || SourceIdentity.scope(this.current) !== SourceIdentity.scope(s)) {
      return;
    }
    this.rows = out;
    this.buildHeroFromRows();
  }

  /**
   * 从已加载的行数据重建 Hero（不重新发请求）。
   * 抽出来是为了「坏图重试」可以只重建 Hero，不用重拉整个首页。
   */
  private buildHeroFromRows(): void {
    const pool: MediaItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const items = this.rows[i].items;
      for (let j = 0; j < items.length && j < 4; j++) {
        pool.push(items[j]);
      }
    }

    // ★ 去重：同一个条目可能同时出现在多个媒体库里（例如某 Series 既在「国漫」
    //   又在「电视剧」），重复 id 会让 Swiper 的 ForEach key 冲突，
    //   表现为「海报是 A、标题却是 B」。
    const uniq: MediaItem[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < pool.length; i++) {
      if (!seen.has(pool[i].id)) {
        seen.add(pool[i].id);
        uniq.push(pool[i]);
      }
    }

    // Hero 排序：评分高的前 6 个；坏图条目留在外面，不进入 Hero
    uniq.sort((a: MediaItem, b: MediaItem) => b.rating - a.rating);
    let cap = 6;
    if (HERO_DEBUG_LIMIT > 0) {
      cap = HERO_DEBUG_LIMIT;
    } else if (HERO_DEBUG_LIMIT < 0) {
      cap = 0;
    }
    const keep: MediaItem[] = [];
    for (let i = 0; i < uniq.length && keep.length < cap; i++) {
      if (this.badHeroIds.indexOf(uniq[i].id) < 0) {
        keep.push(uniq[i]);
      }
    }
    this.heroItems = keep;
    this.heroAllFailed = keep.length === 0;
    // ★ 数据替换时重置索引，避免旧索引大于新数组长度
    this.heroIndex = 0;
    this.ambientFrom = '';
    this.primeAmbient();
    this.syncHeroTimer();

    // 诊断日志：确认 hero 顺序与 id 一一对应
    for (let k = 0; k < this.heroItems.length; k++) {
      hilog.info(0x0001, 'NasPlay',
        'HERO idx[%{public}d] id=%{public}s name=%{public}s tag=%{public}s',
        k, this.heroItems[k].id, this.heroItems[k].name, this.heroItems[k].imageTag);
    }
  }

  /**
   * R10 连续空间氛围：同源取色 + 权重混合（方案 §5.3 §5.4）
   *
   * ★ 和旧实现的三点差别：
   *   1. 不再只取「一个主色染一层」—— Ambient 按 上/中/下 三带各取一色，
   *      背景由「低饱和底色 + 上部色场 + 下部色场 + 一处低频光斑」组成，
   *      同屏不同位置才有色相/亮度差别。
   *   2. 拖动时由 Swiper 的 onContentDidScroll 帧级驱动权重，
   *      颜色直接跟着手指走，不给每次权重变化再叠独立缓动。
   *   3. 取色结果按 server+item+tag+算法版本 缓存，拖动过程中**只读缓存**，
   *      绝不在每帧发网络请求（方案 §5.4）。
   */
  private ambientVersion: number = 0;

  /** server + item + tag + 算法版本 */
  private ambKeyOf(item: MediaItem): string {
    const sv = this.current;
    if (sv === null) {
      return '';
    }
    return Ambient.key(SourceIdentity.scope(sv), item.id, item.imageTag + ':' + item.backdropTag, MediaServices.imageHeaders(sv));
  }

  /** 把 A/B/权重压成四个显示颜色（一次混合，builder 只读字符串） */
  private applyAmbient(): void {
    const a = this.ambA.has ? this.ambA : AmbientPalette.empty();
    const b = this.ambB.has ? this.ambB : AmbientPalette.empty();
    const w = this.ambB.has ? this.ambW : 0;
    const merged = AmbientPalette.blendOf(a, b, w);
    const dark = this.dark();
    this.ambTopC = AmbientPalette.field(merged.topRgb, dark, 0);
    this.ambMidC = AmbientPalette.field(merged.midRgb, dark, 1);
    this.ambBotC = AmbientPalette.field(merged.botRgb, dark, 2);
    this.ambBaseC = AmbientPalette.baseOf(merged.midRgb, dark);
    // surfaceColor() 继续用中间色（图片占位、卡片兜底底色）
    this.ambientRgb = merged.midRgb;
    // DIAG：切换期间按 60ms 节流记录颜色序列，用来分清「跳灰 / 亮度突变 / 图片重载」
    const seqNow = Date.now();
    if (seqNow - this.ambSeqAt > 60) {
      this.ambSeqAt = seqNow;
      hilog.info(0x0001, 'NasPlay', 'AMBQ w=%{public}s base=%{public}s top=%{public}s bot=%{public}s hasA=%{public}s hasB=%{public}s',
        this.ambW.toFixed(2), this.ambBaseC, this.ambTopC, this.ambBotC,
        this.ambA.has.toString(), this.ambB.has.toString());
    }
  }

  /** 主题切换 / 前后台切换时重算（主题换了要按新亮度上限压一遍） */
  onLookChange(): void {
    if (!this.appActive) { this.visionActionGeneration++; this.cancelLaunchIntro(); }
    this.applyNativeColorMode();
    this.applySystemBarStyle();
    this.applyAmbient();
    this.syncHeroTimer();
    if (this.appActive) { this.syncHomeScroll(); }
    else { this.cancelHomeScrollSync(); }
  }

  /** 同步应用上下文，使 HDS 系统材质和原生控件跟随应用内主题。 */
  private applyNativeColorMode(): void {
    const mode = this.themeMode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : (this.themeMode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    if (this.appliedNativeColorMode === mode) {
      return;
    }
    const previous = this.appliedNativeColorMode;
    // 设置前先记录，防止配置回调再次触发主题 Watch 时循环应用。
    this.appliedNativeColorMode = mode;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      context.setColorMode(mode);
    } catch (e) {
      this.appliedNativeColorMode = previous;
      hilog.warn(0x0001, 'NasPlay', 'THEME native color mode apply failed');
    }
  }

  /**
   * 一级外壳状态变化（切 Tab / 开搜索 / 进详情 / 进媒体库 / 下载页）时
   * 重新判断 Hero 轮播是否该跑 —— 不需要在每个赋值点手工调。
   */
  onShellChange(): void {
    this.visionActionGeneration++;
    this.cancelHomeScrollSync();
    this.syncHeroTimer();
    this.syncHomeScroll();
  }

  /** 当前项落到 A 槽，并清掉 B 槽（提交态） */
  private primeAmbient(): void {
    const sv = this.current;
    if (sv === null || this.heroItems.length === 0) {
      this.ambA = AmbientPalette.empty();
      this.ambB = AmbientPalette.empty();
      this.ambW = 0;
      this.applyAmbient();
      return;
    }
    const it = this.heroItem();
    const key = this.ambKeyOf(it);
    this.ambA = Ambient.cached(key);
    this.ambAKey = key;
    this.ambB = AmbientPalette.empty();
    this.ambBKey = '';
    this.ambW = 0;
    this.applyAmbient();
    this.prefetchAmbient();
  }

  /**
   * 后台把 Hero 各条的取色补齐（最多 6 张，逐张串行，避免同时解码抢占）。
   * 拖动时才能「只读缓存」就有颜色。
   */
  private async prefetchAmbient(): Promise<void> {
    const sv = this.current;
    if (sv === null) {
      return;
    }
    const ver = ++this.ambientVersion;
    const svId = sv.id;
    const order: MediaItem[] = [];
    const cur = this.heroItem();
    if (cur.id.length > 0) {
      order.push(cur);
    }
    for (let i = 0; i < this.heroItems.length; i++) {
      if (this.heroItems[i].id !== cur.id) {
        order.push(this.heroItems[i]);
      }
    }
    for (let i = 0; i < order.length; i++) {
      if (ver !== this.ambientVersion) {
        return;
      }
      const it = order[i];
      const key = this.ambKeyOf(it);
      if (Ambient.has(key)) {
        continue;
      }
      const url = this.heroImageUrl(it, 320);
      if (url.length === 0) {
        continue;
      }
      const pal = await Ambient.forUrl(key, url, '', '', MediaServices.imageHeaders(sv));
      if (ver !== this.ambientVersion) {
        return;
      }
      if (this.current === null || this.current.id !== svId) {
        return;
      }
      hilog.info(0x0001, 'NasPlay',
        'AMBIENT id=%{public}s has=%{public}s top=#%{public}s mid=#%{public}s bot=#%{public}s',
        it.id, pal.has.toString(),
        AmbientPalette.field(pal.topRgb, this.dark(), 0).substring(1),
        AmbientPalette.field(pal.midRgb, this.dark(), 1).substring(1),
        AmbientPalette.field(pal.botRgb, this.dark(), 2).substring(1));
      if (pal.has && key === this.ambAKey) {
        this.ambA = pal;
        this.applyAmbient();
      }
      if (pal.has && key === this.ambBKey) {
        this.ambB = pal;
        this.applyAmbient();
      }
    }
  }

  /** 单条补色（拖动时缓存未命中用，异步回来后再合并） */
  private async fetchAmbientOne(it: MediaItem): Promise<void> {
    const sv = this.current;
    if (sv === null) {
      return;
    }
    const key = this.ambKeyOf(it);
    if (key.length === 0 || Ambient.has(key)) {
      return;
    }
    const url = this.heroImageUrl(it, 320);
    if (url.length === 0) {
      return;
    }
    const pal = await Ambient.forUrl(key, url, '', '', MediaServices.imageHeaders(sv));
    if (!pal.has) {
      return;
    }
    if (key === this.ambAKey) {
        this.ambientToCurrent(pal, key);
      } else if (key === this.ambBKey) {
      this.ambB = pal;
      this.applyAmbient();
    }
  }

  /**
   * Swiper 帧级滚动回调（方案 §5.4 的连续颜色状态）。
   *
   * ★ 真机实测（本机 API 26 / SGT-AL10）纠正了两个假设：
   *   1. `index` 是**虚拟索引**（loop 下前面插了复制页），不能当业务索引；
   *   2. `position` 不是 vp，而是**归一化到 ±1 的位移比例**：
   *      拖动中回调只报当前页，pos 单调 0 → -1.0，翻页完成后新页 pos=0。
   *   所以进度直接用 |position|，方向用正负号：
   *      pos < 0（当前页左移）→ 拖向下一页；pos > 0 → 拖向上一页。
   *   再留一条自适应：如果某版本给的是 vp（远大于 2.5），就除以 mainAxisLength。
   */
  private onHeroContentScroll(selected: number, idx: number, position: number,
                              axisLen: number): void {
    this.lastScrollCbAt = Date.now();
    // ★ 真机定位：统一过渡（glideAmbientTo）在跑的时候，Swiper 的回调仍会来，
    //   它会把 B 槽换成「另一侧邻项」的颜色 —— 日志实测颜色从 #b55353 直接
    //   跳回 #ff2b00（旧项色），这就是「闪一下」。过渡期间一律不接受回调。
    if (this.ambTicker >= 0) {
      return;
    }
    const n = this.heroItems.length;
    if (n <= 1) {
      return;
    }
    const raw = Math.abs(position);
    const span = raw <= 2.5 ? 1 : (axisLen > 0.001 ? axisLen : 1);
    const t = Math.min(1, raw / span);
    const sv = this.current;
    if (sv === null) {
      return;
    }
    // ★ 真机定位（关键）：这里以前在位移归零时把跟手权重也归零，
    //   而 Swiper 动画结束那一帧正好会给出 t≈0 —— 于是颜色先掉回旧色，
    //   紧随其后的 onChange/commit 再从 0 慢慢过渡过去，就是你看到的「闪一下」。
    //   所以这里什么都不做：切换完成由 commitAmbient 接管；
    //   真正回弹（不会来 commit）由 onHeroAnimEnd 兜底归零。
    if (t <= 0.004) {
      return;
    }
    // 非当前页的回调：切页瞬间给的是 pos≈0，没有中间量，交给 onChange
    if (idx !== selected) {
      return;
    }
    const targetIdx = position < 0 ? (this.heroIndex + 1) % n
      : (this.heroIndex + n - 1) % n;
    const it = this.heroItems[targetIdx];
    const key = this.ambKeyOf(it);
    // ★ 缓慢切换：拖动中最多混到 45%，剩下的 55% 松手后用长过渡走完
    const w = t * 0.45;
    if (key !== this.ambBKey) {
      this.ambBKey = key;
      this.ambB = Ambient.cached(key);   // ★ 只读缓存，拖动中不发请求
      if (!this.ambB.has) {
        this.fetchAmbientOne(it);
      }
    }
    if (Math.abs(w - this.ambW) > 0.004) {
      this.ambW = w;
      this.applyAmbient();
      // 拖动过程的证据：节流打点，确认颜色权重真的来自 Swiper 连续进度
      const now = Date.now();
      if (now - this.ambLogAt > 120) {
        this.ambLogAt = now;
        hilog.info(0x0001, 'NasPlay',
          'AMBIENT drag sel=%{public}d tgt=%{public}d t=%{public}s w=%{public}s',
          selected, targetIdx, t.toFixed(2), w.toFixed(2));
      }
    }
  }

  /**
   * 换页动画结束：把权重归零。
   * ★ 两种场景都要处理：正常切页（onChange 已提交，这里无事）与
   *   **拖动后回弹**（索引没变、onChange 不触发）—— 后者若不归零，
   *   背景会一直停留在邻项的颜色上。
   */
  private onHeroAnimEnd(): void {
    // 兜底：只有「真正回弹」（不会来 onChange/commit，也就没有 glide）才需要归零。
    // 正常切页时 commitAmbient 会先启动 glideAmbientTo，这里的 ticker 判定会跳过。
    setTimeout(() => {
      if (this.ambTicker >= 0) {
        return;
      }
      if (this.ambW > 0.004) {
        this.ambW = 0;
        this.ambB = AmbientPalette.empty();
        this.ambBKey = '';
        this.applyAmbient();
      }
    }, 80);
  }

  /**
   * 单条统一颜色过渡（方案 §5.4：定时换色只做一条 300–450ms 过渡）。
   * 做法是把目标色放进 B 槽，权重 0→1 走一次 smoothstep，
   * 结束再把 B 提交成 A —— 和拖动共用同一条混合路径，不会两套算法打架。
   */
  private glideAmbientTo(pal: AmbientPalette, key: string, ms: number): void {
    this.clearAmbTicker();
    const startW = this.ambW;
    const start = Date.now();
    this.ambB = pal;
    this.ambBKey = key;
    this.ambTicker = setInterval(() => {
      const t = Math.min(1, (Date.now() - start) / ms);
      const k = t * t * (3 - 2 * t);
      this.ambW = startW + (1 - startW) * k;
      this.applyAmbient();
      if (t >= 1) {
        this.clearAmbTicker();
        this.ambA = pal;
        this.ambAKey = key;
        this.ambB = AmbientPalette.empty();
        this.ambBKey = '';
        this.ambW = 0;
        this.applyAmbient();
      }
    }, 16);
  }

  /**
   * 把「当前项」的颜色切到 pal：已显示过颜色时走统一过渡，首次显示才直接赋值。
   * ★ 直接赋值会在取色迟到时造成一次瞬跳（真机上的「闪一下」）。
   */
  private ambientToCurrent(pal: AmbientPalette, key: string): void {
    if (this.ambA.has) {
      this.glideAmbientTo(pal, key, 1000);
    } else {
      this.ambA = pal;
      this.ambAKey = key;
      this.applyAmbient();
    }
  }
  private clearAmbTicker(): void {
    if (this.ambTicker >= 0) {
      clearInterval(this.ambTicker);
      this.ambTicker = -1;
    }
  }

  /**
   * Hero 停稳到第 idx 项：提交颜色。
   * 如果刚才有帧级滚动回调（拖动/滑动收敛），颜色已经在路上，直接提交；
   * 否则（程序化换页、回调没来）补一条统一 360ms 过渡，避免跳色。
   */
  private commitAmbient(idx: number): void {
    this.clearAmbTicker();
    const sv = this.current;
    if (sv === null || this.heroItems.length === 0) {
      return;
    }
    const ni = idx < 0 ? 0 : (idx >= this.heroItems.length ? this.heroItems.length - 1 : idx);
    const it = this.heroItems[ni];
    const key = this.ambKeyOf(it);
    const pal = Ambient.cached(key);
    const continuous = Date.now() - this.lastScrollCbAt < 160;
    if (!pal.has) {
      // ★ 真机缺陷修复（Hero 切换时背景「闪一下」）：
      //   目标项还没取到色时，绝不能把 ambA 设成 empty —— 那会让背景从
      //   当前彩色瞬跳到中性灰，取色回来再跳一次（连闪两次）。
      //   正确做法：记住身份 + 去取色，显示颜色保持不动，
      //   取色回来后再用统一过渡过去。
      this.ambAKey = key;
      this.fetchAmbientOne(it);
      hilog.info(0x0001, 'NasPlay',
        'HERO commit idx=%{public}d id=%{public}s cached=false keep-color',
        ni, it.id);
      return;
    }
    // ★ 需求：缓慢切换、一点一点来。
    //   拖动中只混到 45%，这里用一条 1000ms 的长过渡把剩余部分慢慢走完；
    //   不再区分「跟手/非跟手」——两种情况下起点都是当前显示色，不会跳。
    this.glideAmbientTo(pal, key, 1000);
    hilog.info(0x0001, 'NasPlay',
      'HERO commit idx=%{public}d id=%{public}s cached=true continuous=%{public}s',
      ni, it.id, continuous.toString());
  }

  private detailRequestGeneration: number = 0;
  private seasonRequestGeneration: number = 0;

  private detailRequestCurrent(generation: number, scope: string, itemId: string): boolean {
    return this.homeScrollMounted && this.homeScrollPageVisible && generation === this.detailRequestGeneration
      && this.current !== null && SourceIdentity.scope(this.current) === scope
      && this.detailItem !== null && this.detailItem.id === itemId;
  }

  async openDetail(item: MediaItem): Promise<void> {
    const s = this.current;
    if (s === null) {
      return;
    }
    const generation = ++this.detailRequestGeneration, scope = SourceIdentity.scope(s);
    if (!(await this.serverGate(s)) || generation !== this.detailRequestGeneration || this.current === null || SourceIdentity.scope(this.current) !== scope) { return; }
    this.detailWatchLater = false;
    this.seasonRequestGeneration++;
    this.detailArtworkRatio = 16 / 9;
    this.detailItem = item;
    this.ensureSubpage('detail');
    VisionStore.isWatchLater(s, item.id).then((enabled: boolean) => {
      if (this.detailRequestCurrent(generation, scope, item.id)) { this.detailWatchLater = enabled; }
    }).catch(() => {});
    this.detail = null;
    this.seasons = [];
    this.episodes = [];
    this.people = [];
    try {
      const d = await MediaServices.getItemDetail(s, item.id);
      if (!this.detailRequestCurrent(generation, scope, item.id)) { return; }
      if (d.item.id !== item.id) { throw new Error('详情条目身份不匹配'); }
      this.detail = d;
      if (this.sourceFamily() === 'catalog') { this.loadPeople(item.id); }
      if (item.type === 'Series') {
        const ss = await MediaServices.getSeasons(s, item.id);
        if (!this.detailRequestCurrent(generation, scope, item.id)) { return; }
        this.seasons = ss;
        if (ss.length > 0) {
          this.curSeasonId = ss[0].id;
          const seasonGeneration = ++this.seasonRequestGeneration;
          const eps = await MediaServices.getEpisodes(s, item.id, ss[0].id);
          if (this.detailRequestCurrent(generation, scope, item.id) && seasonGeneration === this.seasonRequestGeneration) { this.episodes = eps; }
        }
      }
    } catch (e) {
      if (this.detailRequestCurrent(generation, scope, item.id)) { promptAction.showToast({ message: '详情加载失败，请重试' }); }
    }
  }

  async selectSeason(seasonId: string): Promise<void> {
    const s = this.current;
    const it = this.detailItem;
    if (s === null || it === null) {
      return;
    }
    const generation = this.detailRequestGeneration, scope = SourceIdentity.scope(s);
    const seasonGeneration = ++this.seasonRequestGeneration;
    this.curSeasonId = seasonId;
    try {
      const eps = await MediaServices.getEpisodes(s, it.id, seasonId);
      if (this.detailRequestCurrent(generation, scope, it.id) && seasonGeneration === this.seasonRequestGeneration) { this.episodes = eps; }
    } catch (e) {
      if (this.detailRequestCurrent(generation, scope, it.id) && seasonGeneration === this.seasonRequestGeneration) { promptAction.showToast({ message: '分集加载失败，请重试' }); }
    }
  }

  /**
   * 播放：先问服务器能不能直连，不能就转 HLS
   * ★ 这是 Jellyfin/Emby 客户端的标准流程
   */
  private playRequestGeneration: number = 0;

  async playItem(item: MediaItem, forceStart: boolean = false, siblings: MediaItem[] = []): Promise<void> {
    const s = this.current;
    if (s === null || !this.homeScrollMounted || !this.homeScrollPageVisible || !item.isPlayable()) {
      return;
    }
    const generation = ++this.playRequestGeneration, accountScope = SourceIdentity.scope(s);
    if (!(await this.serverGate(s)) || generation !== this.playRequestGeneration || this.current === null || SourceIdentity.scope(this.current) !== accountScope) { return; }
    const originDetailId = this.detailItem !== null ? this.detailItem.id : '';
    const requestCurrent = (): boolean => this.homeScrollMounted && this.homeScrollPageVisible
      && generation === this.playRequestGeneration && this.current !== null
      && SourceIdentity.scope(this.current) === accountScope
      && (originDetailId.length === 0 || (this.detailItem !== null && this.detailItem.id === originDetailId));
    let lease = '';
    try {
    const title = item.seriesName.length > 0 ? item.seriesName : item.name;
    let startTicks = !forceStart && Number.isFinite(item.progressTicks)
      ? Math.max(0, Math.floor(item.progressTicks)) : 0;
    if (!forceStart && (item.played || (item.runtimeTicks > 0 && startTicks / item.runtimeTicks >= 0.95))) {
      startTicks = 0;
    }
    if (!forceStart && item.type !== 'Channel') {
      try {
        const records = await ProgressRepository.loadForAccount(s.id, s.userId, 100);
        let latest: ProgressRecordV2 | null = null;
        for (let i = 0; i < records.length; i++) {
          const record = records[i];
          if (record.serverId !== s.id || record.userId !== s.userId || record.itemId !== item.id) { continue; }
          if (latest === null || record.updatedAt > latest.updatedAt) { latest = record; }
        }
        if (latest !== null) {
          const completed = latest.completed || (latest.durationMs > 0 && latest.positionMs / latest.durationMs >= 0.95);
          if (completed) { startTicks = 0; }
          else if (Number.isFinite(latest.positionMs) && latest.positionMs >= 5000) {
            startTicks = Math.floor(latest.positionMs * 10000);
          }
        }
      } catch (e) {
        hilog.warn(0x0001, 'NasPlay', 'local resume unavailable; using item progress');
      }
      if (!requestCurrent()) { return; }
    }

    hilog.info(0x0001, 'NasPlay', 'route resumeMs=%{public}d fromStart=%{public}s',
      Math.floor(startTicks / 10000), forceStart ? 'Y' : 'N');
    // A loaded detail belongs to one item; never reuse its sources or subtitles for another item.
    const d0 = this.detail;
    let sourceDetail = d0 !== null && d0.item.id === item.id ? d0 : null;
    if (sourceDetail === null && s.kind !== 'fnos') {
      // File/cloud providers expose real sources and external subtitles through their own detail endpoint.
      sourceDetail = await MediaServices.getItemDetail(s, item.id);
      if (!requestCurrent()) { return; }
    }
    const sourceId = sourceDetail !== null && sourceDetail.sources.length > 0 ? sourceDetail.sources[0].id : '';
    const playback = await MediaServices.getPlaybackInfo(s, item.id, sourceId, startTicks);
    lease = SourcePlaybackLeases.register(playback.release);
    if (!requestCurrent()) { return; }
    const url = playback.url, isHls = playback.isHls;
    const headers = playback.headers !== null ? playback.headers : MediaServices.streamHeaders(s);
    if (playback.isLive) { startTicks = 0; }

    // 字幕轨：把已经加载过的 detail 拿来用，不再额外请求
    const subs: SubtitleTrack[] = [];
    if (sourceDetail !== null && sourceDetail.sources.length > 0) {
      const src = sourceDetail.sources[0];
      for (let i = 0; i < src.streams.length; i++) {
        const st = src.streams[i];
        if (st.type === 'Subtitle') {
          const track: SubtitleTrack = {
            index: st.index,
            language: st.language,
            title: st.title,
            url: st.isExternal ? MediaServices.subtitleUrl(s, item.id, src.id, st.index, st.codec) : '',
            isExternal: st.isExternal
          };
          subs.push(track);
        }
      }
    }

    // 记下最近播放（桌面小组件会读）
    const poster = item.hasPrimaryImage ? MediaServices.imageUrl(s, item.id, 240, item.imageTag) : '';
    Store.setLastPlayed(title, item.name,
      /[?@]/.test(poster.substring(poster.indexOf('://') + 3)) ? '' : poster,
      (item.runtimeTicks > 0 ? Math.min(100, startTicks / item.runtimeTicks * 100) : 0).toFixed(0));

    const p: PlayParams = {
      url: url,
      title: title,
      subtitle: item.name,
      isHls: isHls,
      startTicks: startTicks,
      itemId: item.id,
      subtitles: subs,
      token: s.token,
      nativeToken: s.nativeToken,
      serviceKind: s.kind,
      streamHeaders: headers,
      playbackLeaseId: lease,
      useMpv: SourcePlaybackPolicy.useMpv(s.kind, url),
      isLive: playback.isLive,
      // 进度 V2 的来源身份
      serverId: s.id,
      userId: s.userId,
      itemType: item.type,
      seriesId: item.seriesId,
      seasonNumber: item.parentIndexNumber,
      episodeNumber: item.indexNumber,
      imageTag: item.imageTag,
      // The series detail may supply its episode list; sources must belong to the exact playable item.
      episodes: siblings.length > 0 ? siblings : (d0 !== null && d0.item.id === item.seriesId)
        ? this.episodes : [],
      sources: sourceDetail !== null ? sourceDetail.sources : [],
      selectedSourceId: playback.mediaSourceId.length > 0 ? playback.mediaSourceId : sourceId
    };
    if (!requestCurrent()) { return; }
    await router.pushUrl({ url: 'pages/PlayerPage', params: p });
    lease = ''; // The destination claims the opaque lease; its timer handles a missing destination.
    } catch (error) {
      if (requestCurrent()) {
        promptAction.showToast({ message: this.sourceRequestError(error as Error, this.sourceDraft) });
      }
    } finally { if (lease.length > 0) { await SourcePlaybackLeases.release(lease); } }
  }

  async doLogin(): Promise<void> { await this.runSourceRequest(true); }

  private sourceProfile(): SourceProfile { return SourceProfiles.forKind(this.sourceDraft.kind); }

  private editingSource(): ServerConfig | null {
    for (let i = 0; i < this.servers.length; i++) { if (this.servers[i].id === this.editingId) { return this.servers[i]; } }
    return null;
  }

  private sourceCredentialsCompatible(server: ServerConfig, draft: SourceDraft): boolean {
    const profile = SourceProfiles.forKind(server.kind);
    const mode = server.connectionMode.length > 0 ? server.connectionMode : 'direct';
    const auth = server.authMode.length > 0 ? server.authMode : profile.authModes[0];
    return server.kind === draft.kind && mode === draft.connectionMode && auth === draft.authMode
      && server.username === draft.username.trim() && server.domain === draft.domain.trim()
      && server.clientId === draft.clientId.trim()
      && (draft.userId.trim().length === 0 || draft.userId.trim() === server.userId) && !this.sourceClearCredentials;
  }

  private sourceFormSnapshot(): SourceDraft {
    const draft = SourceProfiles.copyDraft(this.sourceDraft), existing = this.editingSource();
    draft.preserveCredentials = existing !== null && this.sourceCredentialsCompatible(existing, draft);
    if (draft.preserveCredentials && existing !== null) {
      if (draft.password.length === 0) { draft.password = existing.password; }
      if (draft.accessToken.length === 0) { draft.accessToken = existing.token; }
      if (draft.clientSecret.length === 0) { draft.clientSecret = existing.clientSecret; }
      const changedToken = draft.accessToken.trim().length > 0 && draft.accessToken.trim() !== existing.token;
      if (draft.refreshToken.length === 0 && !changedToken) { draft.refreshToken = existing.refreshToken; }
    }
    return draft;
  }

  private applySourceFields(server: ServerConfig, value: SourceValidatedDraft): void {
    server.kind = value.kind; server.name = value.name; server.host = value.endpoint.host;
    server.port = value.endpoint.port; server.scheme = value.endpoint.scheme; server.basePath = value.endpoint.basePath;
    server.authBrokerUrl = value.authBrokerUrl;
    server.username = value.username; server.rootPath = value.rootPath; server.sourceUrl = value.sourceUrl; server.epgUrl = value.epgUrl;
    server.authMode = value.authMode; server.connectionMode = value.connectionMode; server.domain = value.domain;
    server.shareName = value.shareName; server.clientId = value.clientId;
    if (value.userId.length > 0) { server.userId = value.userId; }
  }

  private sourceServerDraft(draft: SourceDraft, value: SourceValidatedDraft): ServerConfig {
    const existing = this.editingSource();
    const compatible = existing !== null && this.sourceCredentialsCompatible(existing, draft);
    const id = existing !== null ? existing.id : Date.now().toString() + '-' + Math.floor(Math.random() * 16777216).toString(36);
    const token = draft.authMode === 'token' || draft.authMode === 'oauth' || compatible ? draft.accessToken.trim() : '';
    const server = new ServerConfig(id, value.kind, value.name, value.endpoint.host, value.endpoint.port,
      value.username, token, compatible && existing !== null ? existing.userId : '');
    this.applySourceFields(server, value);
    server.password = draft.authMode === 'password' || compatible ? draft.password : '';
    server.clientSecret = draft.authMode === 'oauth' || compatible ? draft.clientSecret : '';
    server.refreshToken = draft.authMode === 'oauth' || compatible ? draft.refreshToken : '';
    server.nativeToken = compatible && existing !== null ? existing.nativeToken : '';
    server.credentialRef = compatible && existing !== null ? existing.credentialRef : '';
    server.clearCredentials = this.sourceClearCredentials || value.authMode === 'anonymous';
    if (draft.authMode === 'password' && this.sourceDraft.password.length > 0) {
      // A newly typed password must be tested rather than silently accepting a previous access token.
      server.token = ''; server.nativeToken = '';
    }
    if (this.sourceDraft.accessToken.trim().length > 0 && existing !== null
      && this.sourceDraft.accessToken.trim() !== existing.token) {
      server.userId = value.userId; server.nativeToken = ''; server.credentialRef = ''; server.clearCredentials = true;
    }
    if (value.authMode === 'anonymous') {
      server.token = ''; server.nativeToken = ''; server.password = ''; server.clientSecret = ''; server.refreshToken = '';
    }
    return server;
  }

  private sourceRequestCurrent(generation: number): boolean {
    return this.homeScrollMounted && this.homeScrollPageVisible && this.showAdd && generation === this.sourceRequestGeneration;
  }

  private sourceRequestError(error: Error, draft: SourceDraft): string {
    let message = typeof error.message === 'string' && error.message.length > 0 ? error.message : '连接失败，请检查来源配置和网络';
    const sensitive = [draft.password, draft.accessToken, draft.clientSecret, draft.refreshToken, draft.sourceUrl, draft.epgUrl, draft.authBrokerUrl];
    for (let i = 0; i < sensitive.length; i++) {
      if (sensitive[i].length > 0) { message = message.split(sensitive[i]).join('••••'); }
    }
    return message.replace(/([?&](?:token|access_token|api_key|apikey|password)=)[^&\s]+/gi, '$1••••');
  }

  private async runSourceRequest(save: boolean): Promise<void> {
    if (!this.showAdd || this.sourceFormPhase !== 'idle') { return; }
    this.sourceFormError = ''; this.sourceFormStatus = '';
    let draft: SourceDraft;
    let value: SourceValidatedDraft;
    try { draft = this.sourceFormSnapshot(); value = SourceProfiles.validate(draft); }
    catch (error) { this.sourceFormError = this.sourceRequestError(error as Error, this.sourceDraft); return; }
    const generation = ++this.sourceRequestGeneration;
    this.sourceFormPhase = save ? 'logging' : 'checking';
    let stored = false;
    try {
      const server = this.sourceServerDraft(draft, value);
      if (this.editingId.length > 0 && await ServerOptions.isLocked(this.editingId)) { throw new Error('服务器已锁定，请先返回解锁'); }
      if (!this.sourceRequestCurrent(generation)) { return; }
      const logged = await MediaServices.login(server, server.password);
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.applySourceFields(logged, value);
      logged.id = server.id;
      logged.name = draft.name.trim().length > 0 ? draft.name.trim()
        : (logged.serverName.length > 0 ? logged.serverName : value.name);
      logged.password = server.password;
      logged.clientSecret = server.clientSecret;
      if (logged.refreshToken.length === 0) { logged.refreshToken = server.refreshToken; }
      logged.clearCredentials = server.clearCredentials;
      if (draft.authMode === 'anonymous') { logged.token = ''; logged.nativeToken = ''; }
      if (!save) { this.sourceFormPhase = 'idle'; this.sourceFormStatus = '连接检测成功，尚未保存'; return; }
      // Network work can be canceled; the short local credential/preferences transaction is committed atomically.
      if (this.editingId.length > 0 && await ServerOptions.isLocked(this.editingId)) { throw new Error('服务器保护已到期，请先返回解锁'); }
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceFormPhase = 'saving';
      await Store.upsert(logged); stored = true;
      if (this.editingId.length === 0 && !this.tmdbAutoInclude) { await ServerOptions.setAggregate(logged.id, false); }
      this.reloadServerOptions();
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.editingId = logged.id;
      await Store.setLastId(logged.id);
      const list = await Store.loadServers();
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.servers = list;
      let selected = logged;
      for (let i = 0; i < list.length; i++) { if (list[i].id === logged.id) { selected = list[i]; break; } }
      this.activateSavedSource(selected);
      this.sourceFormPhase = 'idle'; this.closeSourceForm();
      promptAction.showToast({ message: '来源已保存并连接' });
    } catch (error) {
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceFormPhase = 'idle';
      this.sourceFormError = (stored ? '配置已保存，重新载入失败：' : '') + this.sourceRequestError(error as Error, draft);
    }
  }

  private activateSavedSource(server: ServerConfig): void {
    this.current = server;
    this.loadLibraries();
  }

  private sourceFamily(): string {
    return this.current !== null && SourceProfiles.indexOf(this.current.kind) >= 0
      ? SourceProfiles.forKind(this.current.kind).family : 'catalog';
  }

  private invalidateSourceRequest(): void { this.sourceRequestGeneration++; this.sourceFormPhase = 'idle'; }

  private clearSourceAuthorization(): void { this.sourceAuthFlow = null; this.sourceAuthServer = null; }

  private async beginSourceAuthorization(): Promise<void> {
    if (!this.showAdd || this.sourceFormPhase !== 'idle') { return; }
    this.clearSourceAuthorization(); this.sourceFormError = ''; this.sourceFormStatus = '';
    const generation = ++this.sourceRequestGeneration;
    try {
      const draft = this.sourceFormSnapshot();
      // Device-code initiation precedes having a user token; validate all other real fields.
      draft.accessToken = 'pending-device-authorization';
      const value = SourceProfiles.validate(draft), server = this.sourceServerDraft(draft, value);
      server.token = ''; server.refreshToken = ''; server.userId = ''; server.credentialRef = '';
      if (server.clientId.length === 0) { throw new Error('请先填写自己的应用 Client ID'); }
      if (server.kind === 'baidu' && server.clientSecret.length === 0) { throw new Error('百度设备码换取令牌需要应用 Client Secret'); }
      this.sourceFormPhase = 'authorizing';
      const flow = await MediaServices.beginAuthorization(server);
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceAuthServer = server; this.sourceAuthFlow = flow; this.sourceFormPhase = 'idle';
      this.sourceFormStatus = '请打开授权页面并输入设备码，完成后点“检查授权结果”。';
    } catch (error) {
      if (this.sourceRequestCurrent(generation)) { this.sourceFormPhase = 'idle'; this.sourceFormError = this.sourceRequestError(error as Error, this.sourceDraft); }
    }
  }

  private async openSourceAuthorization(): Promise<void> {
    const flow = this.sourceAuthFlow;
    if (flow === null || !/^https:\/\//i.test(flow.verificationUrl)) { this.sourceFormError = '授权地址无效，请重新发起授权'; return; }
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: flow.verificationUrl
      });
    } catch (e) { this.sourceFormError = '无法打开浏览器，请使用下方授权地址完成认证'; }
  }

  private async pollSourceAuthorization(): Promise<void> {
    const server = this.sourceAuthServer, flow = this.sourceAuthFlow;
    if (server === null || flow === null || this.sourceFormPhase !== 'idle') { return; }
    const generation = ++this.sourceRequestGeneration; this.sourceFormPhase = 'authorizing'; this.sourceFormError = '';
    try {
      const result = await MediaServices.pollAuthorization(server, flow);
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceFormPhase = 'idle';
      if (result.state === 'authorized' && result.server !== null) {
        const draft = SourceProfiles.copyDraft(this.sourceDraft);
        draft.accessToken = result.server.token; draft.refreshToken = result.server.refreshToken;
        this.sourceDraft = draft; this.sourceClearCredentials = true; this.clearSourceAuthorization();
        this.sourceFormStatus = '已取得用户授权，请点击“连接并保存”验证目录并安全保存。';
      } else {
        this.sourceFormStatus = result.message.length > 0 ? result.message : '等待授权确认，请稍后再次检查';
        if (result.state === 'denied' || result.state === 'expired') { this.clearSourceAuthorization(); }
      }
    } catch (error) {
      if (this.sourceRequestCurrent(generation)) { this.sourceFormPhase = 'idle'; this.sourceFormError = this.sourceRequestError(error as Error, this.sourceDraft); }
    }
  }

  private closeSourceForm(): void {
    if (this.sourceFormPhase === 'saving' || this.sourceFormPhase === 'deleting') { return; }
    this.invalidateSourceRequest(); this.showAdd = false; this.editingId = '';
    this.clearSourceAuthorization();
    this.sourceDraft = new SourceDraft(); this.sourceClearCredentials = false;
    this.popNamed('source');
    this.sourceFormError = ''; this.sourceFormStatus = '';
  }

  private openAddServer(kind: string = 'fnos'): void {
    if (this.sourceFormPhase === 'saving' || this.sourceFormPhase === 'deleting') { return; }
    this.invalidateSourceRequest();
    this.clearSourceAuthorization();
    const profile = SourceProfiles.forKind(kind), draft = new SourceDraft();
    draft.kind = profile.kind; draft.scheme = profile.defaultScheme; draft.address = profile.defaultAddress;
    draft.authMode = profile.authModes[0]; draft.connectionMode = profile.connectionModes[0];
    this.editingId = ''; this.sourceDraft = draft; this.sourceClearCredentials = false;
    this.sourceFormError = ''; this.sourceFormStatus = ''; this.showAdd = true;
    this.ensureSubpage('source');
  }

  private openEditServer(server: ServerConfig): void {
    if (this.sourceFormPhase === 'saving' || this.sourceFormPhase === 'deleting') { return; }
    if (SourceProfiles.indexOf(server.kind) < 0) {
      promptAction.showToast({ message: '此来源类型暂不支持编辑，原配置已保留' }); return;
    }
    this.invalidateSourceRequest();
    this.clearSourceAuthorization();
    const profile = SourceProfiles.forKind(server.kind), draft = new SourceDraft();
    draft.kind = server.kind; draft.name = server.name; draft.address = server.host;
    draft.portText = server.port > 0 ? server.port.toString() : ''; draft.scheme = server.scheme || profile.defaultScheme;
    draft.basePath = server.basePath; draft.username = server.username; draft.rootPath = server.rootPath;
    draft.userId = server.userId;
    draft.authBrokerUrl = server.authBrokerUrl;
    draft.sourceUrl = server.sourceUrl; draft.epgUrl = server.epgUrl; draft.domain = server.domain; draft.shareName = server.shareName;
    draft.clientId = server.clientId; draft.connectionMode = server.connectionMode || 'direct';
    const modes = SourceProfiles.authModesFor(draft.kind, draft.connectionMode);
    draft.authMode = modes.indexOf(server.authMode) >= 0 ? server.authMode : modes[0];
    this.editingId = server.id; this.sourceDraft = draft; this.sourceClearCredentials = false;
    this.sourceFormError = ''; this.sourceFormStatus = ''; this.showAdd = true;
    this.ensureSubpage('source');
  }

  private changeSourceKind(kind: string): void {
    if (this.sourceFormPhase !== 'idle' || kind === this.sourceDraft.kind) { return; }
    this.clearSourceAuthorization();
    const profile = SourceProfiles.forKind(kind), draft = SourceProfiles.copyDraft(this.sourceDraft);
    draft.kind = kind;
    if (profile.defaultScheme === 'smb') { draft.scheme = 'smb'; }
    else if (draft.scheme === 'smb' || draft.scheme === 'file') { draft.scheme = profile.defaultScheme; }
    if (profile.connectionModes.indexOf(draft.connectionMode) < 0) { draft.connectionMode = profile.connectionModes[0]; }
    draft.authMode = SourceProfiles.authModesFor(kind, draft.connectionMode)[0];
    if (draft.address.length === 0) { draft.scheme = profile.defaultScheme; draft.address = profile.defaultAddress; draft.portText = ''; }
    this.sourceDraft = draft; this.sourceFormStatus = ''; this.sourceFormError = '';
  }

  private changeSourceMode(mode: string): void {
    if (this.sourceFormPhase !== 'idle' || mode === this.sourceDraft.connectionMode) { return; }
    this.clearSourceAuthorization();
    const draft = SourceProfiles.copyDraft(this.sourceDraft); draft.connectionMode = mode;
    draft.authMode = SourceProfiles.authModesFor(draft.kind, mode)[0];
    if (mode === 'aggregate' && draft.scheme !== 'https') { draft.scheme = 'http'; }
    if (mode === 'direct' && this.sourceProfile().defaultScheme === 'smb') { draft.scheme = 'smb'; }
    this.sourceDraft = draft; this.sourceFormStatus = ''; this.sourceFormError = '';
  }

  private sourceFields(): string[] {
    return SourceProfiles.fieldsFor(this.sourceDraft.kind, this.sourceDraft.connectionMode).filter((field: string): boolean => {
      if (field === 'password') { return this.sourceDraft.authMode === 'password'; }
      if (field === 'userId') { return this.sourceDraft.authMode === 'token'; }
      if (field === 'accessToken') { return this.sourceDraft.authMode === 'token' || this.sourceDraft.authMode === 'oauth'; }
      if (field === 'clientId' && this.sourceDraft.kind === 'guangya') { return true; }
      if (field === 'clientSecret' || field === 'clientId' || field === 'refreshToken') { return this.sourceDraft.authMode === 'oauth'; }
      if (field === 'username' && this.sourceDraft.authMode === 'anonymous') { return false; }
      return true;
    });
  }

  private sourceFieldValue(field: string): string {
    const d = this.sourceDraft;
    if (field === 'name') { return d.name; } if (field === 'address') { return d.address; }
    if (field === 'port') { return d.portText; } if (field === 'basePath') { return d.basePath; }
    if (field === 'username') { return d.username; } if (field === 'password') { return d.password; }
    if (field === 'userId') { return d.userId; }
    if (field === 'accessToken') { return d.accessToken; } if (field === 'rootPath') { return d.rootPath; }
    if (field === 'sourceUrl') { return d.sourceUrl; } if (field === 'epgUrl') { return d.epgUrl; }
    if (field === 'authBrokerUrl') { return d.authBrokerUrl; } if (field === 'domain') { return d.domain; }
    if (field === 'shareName') { return d.shareName; } if (field === 'clientId') { return d.clientId; }
    if (field === 'clientSecret') { return d.clientSecret; } if (field === 'refreshToken') { return d.refreshToken; }
    return '';
  }

  private sourceFieldChanged(field: string, value: string): void {
    if (this.sourceFormPhase !== 'idle') { return; }
    this.clearSourceAuthorization();
    const d = SourceProfiles.copyDraft(this.sourceDraft);
    if (field === 'name') { d.name = value; } else if (field === 'address') { d.address = value; }
    else if (field === 'port') { d.portText = value; } else if (field === 'basePath') { d.basePath = value; }
    else if (field === 'username') { d.username = value; } else if (field === 'password') { d.password = value; }
    else if (field === 'userId') { d.userId = value; }
    else if (field === 'accessToken') { d.accessToken = value; } else if (field === 'rootPath') { d.rootPath = value; }
    else if (field === 'sourceUrl') { d.sourceUrl = value; } else if (field === 'epgUrl') { d.epgUrl = value; }
    else if (field === 'authBrokerUrl') { d.authBrokerUrl = value; }
    else if (field === 'domain') { d.domain = value; } else if (field === 'shareName') { d.shareName = value; }
    else if (field === 'clientId') { d.clientId = value; } else if (field === 'clientSecret') { d.clientSecret = value; }
    else if (field === 'refreshToken') { d.refreshToken = value; } else if (field === 'scheme') { d.scheme = value; }
    else if (field === 'authMode') { d.authMode = value; }
    this.sourceDraft = d; this.sourceFormStatus = ''; this.sourceFormError = '';
  }

  private sourceFieldPlaceholder(field: string): string {
    const existing = this.editingSource();
    if (SourceProfiles.secretField(field) && field !== 'sourceUrl' && field !== 'epgUrl' && field !== 'authBrokerUrl' && existing !== null
      && this.sourceCredentialsCompatible(existing, this.sourceDraft)) { return '留空保留已保存的值'; }
    if (field === 'port') { return '默认 ' + (this.sourceDraft.connectionMode === 'aggregate' ? '80 / HTTPS 443' : this.sourceProfile().defaultPort.toString()); }
    if (field === 'address') { return '主机名、IP 或完整 HTTPS URL'; }
    if (field === 'basePath') { return '/emby 或 /dav'; }
    if (field === 'sourceUrl') {
      if (this.sourceDraft.kind === 'local') { return '点击下方选择文件夹'; }
      return this.sourceDraft.kind === 'custom' ? 'https://example.com/library.json' : 'https://example.com/list.m3u';
    }
    return '';
  }

  private async pickSourceFolder(): Promise<void> {
    if (this.sourceFormPhase !== 'idle' || (this.sourceDraft.kind !== 'local' &&
      !(this.sourceDraft.kind === 'custom' && this.sourceDraft.connectionMode === 'direct'))) { return; }
    const generation = ++this.sourceRequestGeneration;
    this.sourceFormPhase = 'picking'; this.sourceFormError = '';
    try {
      const selected = await LocalAccess.select(getContext(this) as common.UIAbilityContext, this.sourceDraft.kind === 'local');
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceFormPhase = 'idle';
      if (selected.length > 0) {
        if (this.sourceDraft.kind === 'custom' && !decodeURIComponent(selected.split('?')[0]).toLowerCase().endsWith('.json')) {
          this.sourceFormError = '请选择扩展名为 .json 的媒体清单'; return;
        }
        this.sourceFieldChanged('sourceUrl', selected);
      }
    } catch (error) {
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceFormPhase = 'idle'; this.sourceFormError = this.sourceDraft.kind === 'local'
        ? '未能取得文件夹读取授权，请重新选择' : '未能读取 JSON 清单，请重新选择';
    }
  }

  private async clearSourceCredentials(): Promise<void> {
    if (this.sourceFormPhase !== 'idle' || this.editingId.length === 0) { return; }
    const generation = ++this.sourceRequestGeneration;
    let choice = -1;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({ systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent), title: '清除已保存凭据', message: '保存后生效。请填写新的凭据，或选择该来源支持的匿名模式。',
        buttons: [{ text: '取消', color: this.P().textDim }, { text: '清除', color: '#D64C4C' }] });
      choice = result.index;
    } catch (error) { return; }
    if (!this.sourceRequestCurrent(generation) || choice !== 1) { return; }
    const d = SourceProfiles.copyDraft(this.sourceDraft);
    d.password = ''; d.accessToken = ''; d.clientSecret = ''; d.refreshToken = '';
    this.sourceDraft = d; this.sourceClearCredentials = true;
    this.sourceFormStatus = '旧凭据将在成功保存后清除'; this.sourceFormError = '';
  }

  private async deleteEditedSource(): Promise<void> {
    if (this.sourceFormPhase !== 'idle') { return; }
    const existing = this.editingSource(); if (existing === null) { return; }
    const generation = ++this.sourceRequestGeneration;
    let choice = -1;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({ systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent), title: '删除来源', message: '删除此连接及其保存的凭据？服务器上的文件不会被删除。',
        buttons: [{ text: '取消', color: this.P().textDim }, { text: '删除', color: '#D64C4C' }] });
      choice = result.index;
    } catch (error) { return; }
    if (!this.sourceRequestCurrent(generation) || choice !== 1) { return; }
    this.sourceFormPhase = 'deleting';
    try {
      if (await ServerOptions.isLocked(existing.id)) { throw new Error('服务器已锁定'); }
      await Store.remove(existing.id);
      await ServerOptions.clear(existing.id);
      const list = await Store.loadServers();
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.servers = list;
      if (this.current !== null && this.current.id === existing.id) {
        this.current = null;
        this.libs = []; this.rows = []; this.heroItems = []; this.resumeItems = [];
        for (const candidate of list) {
          try {
            const option = await ServerOptions.get(candidate.id);
            if (!option.hidden && !(await ServerOptions.isLocked(candidate.id))) { this.current = candidate; break; }
          } catch (error) { /* Inaccessible profiles are never auto-selected. */ }
        }
        if (!this.sourceRequestCurrent(generation)) { return; }
        await Store.setLastId(this.current !== null ? this.current.id : '');
        if (!this.sourceRequestCurrent(generation)) { return; }
        if (this.current !== null) { this.activateSavedSource(this.current); }
        else { this.libs = []; this.rows = []; this.heroItems = []; this.resumeItems = []; }
      }
      this.sourceFormPhase = 'idle'; this.closeSourceForm();
      promptAction.showToast({ message: '来源已删除' });
    } catch (error) {
      if (!this.sourceRequestCurrent(generation)) { return; }
      this.sourceFormPhase = 'idle'; this.sourceFormError = '删除失败，请重试';
    }
  }



  /* ══════════ 构建 ══════════ */

  private sourceDisplayName(server: ServerConfig): string {
    if (server.name.trim().length > 0) { return server.name.trim(); }
    if (server.serverName.trim().length > 0) { return server.serverName.trim(); }
    if (server.host.trim().length > 0) { return server.host.trim(); }
    return SourceProfiles.indexOf(server.kind) >= 0 ? SourceProfiles.forKind(server.kind).name : '媒体来源';
  }

  private rootTitle(): string {
    if (this.currentTab === 1) {
      return 'HosVision';
    }
    if (this.currentTab === 2) {
      return '收藏';
    }
    if (this.currentTab === 3) {
      return this.serverOrdering ? '站点排序' : '服务器';
    }
    if (this.currentTab === 4) {
      return '设置';
    }
    if (this.current !== null) {
      return this.sourceDisplayName(this.current);
    }
    return 'VablePlayer';
  }

  /**
   * 一级页标题栏菜单。HDS 标题栏按钮由系统渲染，才能获得官方沉浸光感
   * 与边缘流光；服务器页的排序/布局/添加入口也从内容区迁到这里。
   */
  private rootTitleMenus(): HdsNavigationMenuContentOptions {
    if (this.currentTab === 3) {
      return {
        value: [
          {
            content: {
              label: this.serverOrdering ? '完成排序' : '站点排序',
              icon: $r('sys.symbol.chevron_up'),
              action: () => {
                this.flipServerSort();
              }
            }
          },
          {
            content: {
              label: '布局',
              icon: $r('sys.symbol.circle_grid_2x2'),
              action: () => {
                this.serverViewMode = this.serverViewMode === 0 ? 1 : 0;
                Store.set('server_view_mode', this.serverViewMode.toString());
              }
            }
          },
          {
            content: {
              label: '添加',
              icon: $r('sys.symbol.plus'),
              action: () => {
                this.openAddServer();
              }
            }
          }
        ]
      };
    }
    if (this.currentTab === 0) {
      return {
        value: [
          {
            content: {
              label: '搜索',
              icon: $r('sys.symbol.magnifyingglass'),
              action: () => {
                this.showSearch = true;
                this.ensureSubpage('search');
              }
            }
          }
        ]
      };
    }
    return { value: [] };
  }

  @Builder
  homeServerTitle() {
    Row() {
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.TV_tv'))
            .fontSize(15)
            .fontColor([this.P().text])
          Text(this.rootTitle())
            .fontSize(12)
            .fontColor(this.P().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(8)
            .fontColor([this.P().textDim])
        }
        .width('100%')
      }
      .width(Math.max(120, Math.min(160, Metrics.width() * 0.26)))
      .height(34)
      .padding({ left: 12, right: 10 })
      .backgroundColor(Color.Transparent)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        interactive: true
      }))
      .accessibilityText(this.rootTitle() + '，切换服务器')
      .bindMenu(this.serverMenu(), {
        systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent)
      })
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Start)
    .padding({ left: 12 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  private rootTitleBar(): HdsNavigationTitleBarOptions {
    const titleColor = this.dark() ? '#F5F6F8' : '#17181C';
    return {
      content: {
        title: {
          mainTitle: this.currentTab === 0 ? '' : this.rootTitle()
        },
        menu: this.rootTitleMenus(),
        stackBuilder: this.currentTab === 0 ? () => this.homeServerTitle() : undefined
      },
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: titleColor,
              mainTitleShadowColor: this.dark() ? withAlpha('#000000', 0.55) : withAlpha('#FFFFFF', 0.55)
            }
          }
        },
        scrollEffectStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: titleColor
            }
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    };
  }

  private subTitleBar(name: string): HdsNavigationTitleBarOptions {
    let title = '';
    if (name === 'detail') {
      title = this.detailItem !== null ? this.detailItem.name : '详情';
    } else if (name === 'search') {
      title = '搜索';
    } else if (name === 'library') {
      title = this.browsingLib !== null ? this.browsingLib.name : '媒体库';
    } else if (name === 'server-options') {
      title = this.serverOptionMode === 'unlock' ? '解锁服务器' : this.serverOptionMode === 'pin' ? '服务器保护密码' : this.serverOptionMode === 'clearPin' ? '移除服务器密码'
        : this.serverOptionMode === 'note' ? '备注' : this.serverOptionMode === 'backups' ? '备用节点'
        : this.serverOptionMode === 'share' ? '分享连接' : '签到提醒';
    } else if (name === 'source') {
      title = (this.editingId.length > 0 ? '编辑' : '添加') + this.sourceProfile().name;
    } else if (name.startsWith('settings:')) {
      title = this.settingsPageTitle(name.substring(9));
    } else {
      title = '下载管理';
    }
    const titleColor = this.dark() ? '#F5F6F8' : '#17181C';
    return {
      content: {
        title: {
          mainTitle: title
        },
        menu: name === 'library' ? this.libraryTitleMenus() : name === 'source' ? { value: [{ content: { label: '保存', icon: $r('sys.symbol.checkmark'), action: () => { this.doLogin(); } } }] } : { value: [] }
      },
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: titleColor
            }
          }
        },
        scrollEffectStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: titleColor
            }
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    };
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // The launch animation never gates data/navigation; slow servers remain manageable.
        HdsNavigation(this.navStack) {
            this.pageTabs()
          }
          .navDestination(this.navDest)
          .mode(NavigationMode.Stack)
          .titleMode(HdsNavigationTitleMode.MINI)
          .titleBar(this.rootTitleBar())
          .hideBackButton(true)
          .hideTitleBar(this.currentTab === 1)
          .hideToolBar(true)
          .bindToScrollable([this.homeScroller])
          .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
            [LayoutSafeAreaEdge.BOTTOM])
          .width('100%')
          .height('100%')
      }
      .width('100%')
      .height('100%')

      // 底部 Dock 已并入 pageTabs 的悬浮 bar（R14），不再单独渲染
      if (this.currentTab === 0 && this.heroScrollP > 0) {
        Column()
          .width('100%')
          .height(this.statusBarHeight() + 1)
          .backgroundColor(withAlpha(this.surfaceColor(), 0.98))
          .backdropBlur(24)
          .opacity(this.clamp01(this.heroScrollP * 4))
          .position({ x: 0, y: -this.statusBarHeight() })
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.launchVisible) { this.splashView() }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.P().bg)
  }

  /** R16：四个子页的 NavDestination 分发 */
  @Builder
  navDest(name: string, param: object) {
    if (name === 'detail') {
      HdsNavDestination() {
        this.detailView()
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(this.subTitleBar('detail'))
      .backgroundColor(this.P().bg)
      .onDisAppear(() => {
        this.onSubpageGone('detail');
      })
    } else if (name === 'search') {
      HdsNavDestination() {
        this.searchView()
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(this.subTitleBar('search'))
      .backgroundColor(this.P().bg)
      .onDisAppear(() => {
        this.onSubpageGone('search');
      })
    } else if (name === 'library') {
      HdsNavDestination() {
        this.libraryView()
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(this.subTitleBar('library'))
      .backgroundColor(this.P().bg)
      .onDisAppear(() => {
        this.onSubpageGone('library');
      })
    } else if (name === 'server-options') {
      HdsNavDestination() { this.serverOptionsPage() }
        .titleMode(HdsNavDestinationTitleMode.MINI).titleBar(this.subTitleBar(name))
        .backgroundColor(this.P().bg).onDisAppear(() => { this.onSubpageGone(name); })
    } else if (name === 'source') {
      HdsNavDestination() { this.addServerSheet() }
        .onBackPressed((): boolean => this.sourceFormPhase === 'saving' || this.sourceFormPhase === 'deleting')
        .titleMode(HdsNavDestinationTitleMode.MINI).titleBar(this.subTitleBar(name))
        .backgroundColor(this.P().bg).onDisAppear(() => { this.onSubpageGone(name); })
    } else if (name.startsWith('settings:')) {
      HdsNavDestination() { this.settingsPage(name.substring(9)) }
        .titleMode(HdsNavDestinationTitleMode.MINI).titleBar(this.subTitleBar(name))
        .backgroundColor(this.P().bg).onDisAppear(() => { this.onSubpageGone(name); })
    } else if (name === 'downloads') {
      HdsNavDestination() {
        this.downloadView()
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(this.subTitleBar('downloads'))
      .backgroundColor(this.P().bg)
      .onDisAppear(() => {
        this.onSubpageGone('downloads');
      })
    }
  }

  /* ── 启动页 ── */
  /* ══════════ 视图转场 ══════════ */

  /** 详情/搜索/库浏览：淡入 + 从右滑入 */
  private slideTransition: TransitionEffect = TransitionEffect
    .OPACITY.animation({ duration: MotionPref.dur(MotionSpec.normal), curve: Curve.EaseOut })
    .combine(TransitionEffect.translate({ x: 44 }))

  /** 底部 Tab 切换：淡入 + 轻微上移 */
  private tabTransition: TransitionEffect = TransitionEffect
    .OPACITY.animation({ duration: MotionPref.dur(MotionSpec.normal), curve: Curve.EaseOut })
    .combine(TransitionEffect.translate({ y: 16 }))

  /** One launch per process; initial State writes wait for a frame, outside the render pass. */
  private startLaunchIntro(): void {
    if (this.launchStarted) { return; }
    this.launchStarted = true;
    const played = AppStorage.get<boolean>('nasplayer.launchIntroPlayed') === true;
    AppStorage.setOrCreate<boolean>('nasplayer.launchIntroPlayed', true);
    const generation = ++this.launchGeneration;
    this.launchFrameTask = setTimeout(() => {
      this.launchFrameTask = -1;
      if (generation !== this.launchGeneration) { return; }
      if (!this.homeScrollMounted || !this.homeScrollPageVisible || !this.appActive) { this.cancelLaunchIntro(); return; }
      if (played) { this.finishLaunchIntro(generation); return; }
      const reduced = MotionPref.reduce();
      const duration = MotionPref.dur(600);
      this.getUIContext().animateTo({ duration: duration, curve: Curve.EaseInOut }, () => {
        this.launchScale = reduced ? 1 : 1.8; this.launchOpacity = 0;
      });
      this.launchFinishTask = setTimeout(() => { this.finishLaunchIntro(generation); }, duration + 32);
    }, 16);
  }

  private finishLaunchIntro(generation: number): void {
    if (generation !== this.launchGeneration || !this.homeScrollMounted || !this.homeScrollPageVisible) { return; }
    if (this.launchFinishTask >= 0) { clearTimeout(this.launchFinishTask); this.launchFinishTask = -1; }
    this.launchVisible = false;
  }

  private cancelLaunchIntro(): void {
    this.launchGeneration++;
    if (this.launchFrameTask >= 0) { clearTimeout(this.launchFrameTask); this.launchFrameTask = -1; }
    if (this.launchFinishTask >= 0) { clearTimeout(this.launchFinishTask); this.launchFinishTask = -1; }
    this.launchVisible = false; this.launchOpacity = 0;
  }

  @Builder
  splashView() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.launch_v'))
        .width(116).height(116).objectFit(ImageFit.Contain)
        .scale({ x: this.launchScale, y: this.launchScale })
    }.width('100%').height('100%').backgroundColor('#0B1428')
      .opacity(this.launchOpacity).hitTestBehavior(HitTestMode.None)
  }

  /* ── 服务器页（首次进入）── */
  @Builder
  serverView() {
    Column() {
      Row() {
        Text('VablePlayer')
          .fontSize(28)
          .fontColor(C.text)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 24, bottom: 4 })

      Text('连接你的服务器')
        .fontSize(12)
        .fontColor(C.dim)
        .width('100%')
        .padding({ left: 20, bottom: 16 })

      List({ space: 10 }) {
        ForEach(this.servers, (s: ServerConfig) => {
          ListItem() {
            this.serverCard(s)
          }
        }, (s: ServerConfig) => s.id)

        ListItem() {
          this.addForm()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 20, right: 20 })
      .edgeEffect(EdgeEffect.Spring)


      if (this.errMsg.length > 0) {
        Text('⚠ ' + this.errMsg)
          .fontSize(12)
          .fontColor('#FF6B6B')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 10 })
      }
      if (this.loading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(C.accent)
          .margin({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  serverCard(s: ServerConfig) {
    Row() {
      Column() {
        Text(this.sourceDisplayName(s))
          .fontSize(16)
          .fontColor(C.text)
          .fontWeight(FontWeight.Medium)
        Text(this.sourceAddressLabel(s))
          .fontSize(11)
          .fontColor(C.dim)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('连接')
        .fontSize(13)
        .fontColor(C.accent)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(C.bg2)
    .borderRadius(Layout.cardRadius)
    .focusable(true)
    .clickEffect(MotionFx.press())
    .onClick(() => {
      this.selectServer(s);
    })
  }

  /* ── 添加服务器表单 ── */
  /* ── 来源表单：13种类型的真实配置、检测与保存 ── */
  @Builder
  sourceFormInput(field: string) {
    Column({ space: 5 }) {
      Text(field === 'name' ? '显示名称（可留空）' : field === 'rootPath' && this.sourceDraft.kind === 'guangya'
        && this.sourceDraft.connectionMode === 'direct' ? '起始文件夹 ID（根目录填 /）' : SourceProfiles.fieldLabel(field))
        .fontSize(12).fontColor(this.P().textDim).width('100%')
      TextInput({ text: this.sourceFieldValue(field), placeholder: this.sourceFieldPlaceholder(field) })
        .type(SourceProfiles.secretField(field) ? InputType.Password : (field === 'port' ? InputType.Number : InputType.Normal))
        .fontSize(14).fontColor(this.P().text).placeholderColor(this.P().textFaint)
        .backgroundColor(this.P().chip).borderRadius(10).height(44).width('100%')
        .enabled(this.sourceFormPhase === 'idle' && !(field === 'sourceUrl' && this.sourceDraft.kind === 'local'))
        .onChange((value: string) => { this.sourceFieldChanged(field, value); })
      if (field === 'address') {
        Text('支持 HTTPS、IPv6 和反向代理子路径；完整 URL 可直接粘贴。')
          .fontSize(11).fontColor(this.P().textFaint).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 12 })
  }

  @Builder
  addForm() {
    if (!this.showAdd) {
      Button('+ 添加来源').fontSize(14).fontColor(this.P().accent).backgroundColor(this.P().card)
        .width('100%').height(48).borderRadius(Layout.cardRadius)
        .onClick(() => { this.openAddServer(); })
    } else {
      Column({ space: 12 }) {
        Row() {
          Text(this.editingId.length > 0 ? '编辑来源' : '添加来源')
            .fontSize(21).fontColor(this.P().text).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('取消').fontSize(13).fontColor(this.P().textDim).backgroundColor(Color.Transparent)
            .enabled(this.sourceFormPhase !== 'saving' && this.sourceFormPhase !== 'deleting')
            .onClick(() => { this.closeSourceForm(); })
        }.width('100%')

        Scroll() {
          Row({ space: 8 }) {
            ForEach(SourceProfiles.all(), (profile: SourceProfile) => {
              Text(profile.name).fontSize(12)
                .fontColor(this.sourceDraft.kind === profile.kind ? '#FFFFFF' : this.P().textDim)
                .padding({ left: 13, right: 13, top: 8, bottom: 8 })
                .backgroundColor(this.sourceDraft.kind === profile.kind ? this.P().accent : this.P().chip)
                .borderRadius(18).enabled(this.sourceFormPhase === 'idle')
                .onClick(() => { this.changeSourceKind(profile.kind); })
            }, (profile: SourceProfile) => profile.kind)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.TopStart).width('100%').height(40)

        if (this.sourceProfile().connectionModes.length > 1) {
          Row({ space: 8 }) {
            ForEach(this.sourceProfile().connectionModes, (mode: string) => {
              Text(mode === 'direct' ? '直连服务' : 'WebDAV 聚合').fontSize(13)
                .fontColor(this.sourceDraft.connectionMode === mode ? '#FFFFFF' : this.P().textDim)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor(this.sourceDraft.connectionMode === mode ? this.P().accent : this.P().chip)
                .borderRadius(16).enabled(this.sourceFormPhase === 'idle')
                .onClick(() => { this.changeSourceMode(mode); })
            }, (mode: string) => mode)
          }.width('100%')
        }
        Text(this.sourceDraft.connectionMode === 'aggregate'
          ? '填写已部署并授权的聚合服务 WebDAV 根地址、账号及起始目录。' : this.sourceProfile().notice)
          .fontSize(12).lineHeight(19).fontColor(this.P().textDim).width('100%')

        this.sourceFormInput('name')

        if (this.sourceFields().indexOf('address') >= 0) {
          if (!(this.sourceDraft.kind === 'smb' && this.sourceDraft.connectionMode === 'direct')
            && this.sourceDraft.address.indexOf('://') < 0) {
            Row({ space: 8 }) {
              Text('HTTP').fontSize(12).fontColor(this.sourceDraft.scheme === 'http' ? '#FFFFFF' : this.P().textDim)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor(this.sourceDraft.scheme === 'http' ? this.P().accent : this.P().chip)
                .borderRadius(15).enabled(this.sourceFormPhase === 'idle')
                .onClick(() => { this.sourceFieldChanged('scheme', 'http'); })
              Text('HTTPS').fontSize(12).fontColor(this.sourceDraft.scheme === 'https' ? '#FFFFFF' : this.P().textDim)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor(this.sourceDraft.scheme === 'https' ? this.P().accent : this.P().chip)
                .borderRadius(15).enabled(this.sourceFormPhase === 'idle')
                .onClick(() => { this.sourceFieldChanged('scheme', 'https'); })
            }.width('100%')
          }
        }

        Row({ space: 8 }) {
          ForEach(SourceProfiles.authModesFor(this.sourceDraft.kind, this.sourceDraft.connectionMode), (mode: string) => {
            Text(SourceProfiles.authLabel(mode)).fontSize(12)
              .fontColor(this.sourceDraft.authMode === mode ? '#FFFFFF' : this.P().textDim)
              .padding({ left: 13, right: 13, top: 7, bottom: 7 })
              .backgroundColor(this.sourceDraft.authMode === mode ? this.P().accent : this.P().chip)
              .borderRadius(15).enabled(this.sourceFormPhase === 'idle')
              .onClick(() => { this.sourceFieldChanged('authMode', mode); })
          }, (mode: string) => mode)
        }.width('100%')

        ForEach(this.sourceFields(), (field: string) => { this.sourceFormInput(field) }, (field: string) => field)

        if (this.sourceDraft.connectionMode === 'direct' && this.sourceDraft.authMode === 'oauth'
          && (this.sourceDraft.kind === 'baidu' || this.sourceDraft.kind === 'guangya')) {
          Button('获取设备授权码').fontSize(14).fontColor(this.P().accent).backgroundColor(this.P().chip)
            .width('100%').height(44).enabled(this.sourceFormPhase === 'idle')
            .onClick(() => { this.beginSourceAuthorization(); })
          if (this.sourceAuthFlow !== null) {
            Text('设备码：' + (this.sourceAuthFlow as SourceAuthorization).userCode)
              .fontSize(19).fontWeight(FontWeight.Medium).fontColor(this.P().text).copyOption(CopyOptions.LocalDevice).width('100%')
            Text((this.sourceAuthFlow as SourceAuthorization).verificationUrl)
              .fontSize(11).fontColor(this.P().textDim).copyOption(CopyOptions.LocalDevice).width('100%')
            Row({ space: 10 }) {
              Button('打开授权页面').layoutWeight(1).fontSize(12).height(40).backgroundColor(this.P().chip).fontColor(this.P().accent)
                .onClick(() => { this.openSourceAuthorization(); })
              Button('检查授权结果').layoutWeight(1).fontSize(12).height(40).backgroundColor(this.P().accent).fontColor('#FFFFFF')
                .enabled(this.sourceFormPhase === 'idle').onClick(() => { this.pollSourceAuthorization(); })
            }.width('100%')
          }
        }

        if (this.sourceDraft.kind === 'local' || (this.sourceDraft.kind === 'custom' && this.sourceDraft.connectionMode === 'direct')) {
          Button(this.sourceFormPhase === 'picking' ? '正在选择…' :
            (this.sourceDraft.kind === 'local' ? '选择本地文件夹' : '选择本地 JSON 清单'))
            .fontSize(14).fontColor(this.P().accent).backgroundColor(this.P().chip).width('100%').height(44)
            .enabled(this.sourceFormPhase === 'idle').onClick(() => { this.pickSourceFolder(); })
        }

        if (this.editingId.length > 0) {
          Text(this.sourceClearCredentials ? '旧凭据将在成功保存后清除。' : '敏感字段留空保留已保存值；更换账号或连接方式后请提供对应凭据。')
            .fontSize(11).lineHeight(18).fontColor(this.P().textFaint).width('100%')
          Button('清除已保存凭据').fontSize(12).fontColor(this.P().textDim).backgroundColor(this.P().chip)
            .enabled(this.sourceFormPhase === 'idle').onClick(() => { this.clearSourceCredentials(); })
        }

        if (this.sourceFormPhase !== 'idle') {
          Row({ space: 9 }) {
            LoadingProgress().width(20).height(20).color(this.P().accent)
            Text(this.sourceFormPhase === 'saving' ? '正在安全保存配置…' :
              (this.sourceFormPhase === 'deleting' ? '正在删除来源…' :
                (this.sourceFormPhase === 'picking' ? '请在系统选择器授权读取' : '正在验证连接与授权…')))
              .fontSize(12).fontColor(this.P().textDim)
          }.width('100%')
        }
        if (this.sourceFormStatus.length > 0) {
          Text(this.sourceFormStatus).fontSize(12).fontColor(this.dark() ? '#7CDAA2' : '#237A45').width('100%')
        }
        if (this.sourceFormError.length > 0) {
          Text(this.sourceFormError).fontSize(12).fontColor(this.dark() ? '#FFB4AB' : '#B3261E').width('100%')
        }

        Row({ space: 10 }) {
          Button('检测连接').fontSize(14).fontColor(this.P().accent).backgroundColor(this.P().chip)
            .layoutWeight(1).height(46).enabled(this.sourceFormPhase === 'idle')
            .onClick(() => { this.runSourceRequest(false); })
          Button(this.editingId.length > 0 ? '保存并连接' : '连接并保存').fontSize(14)
            .fontColor('#FFFFFF').backgroundColor(this.P().accent).layoutWeight(1).height(46)
            .enabled(this.sourceFormPhase === 'idle').onClick(() => { this.doLogin(); })
        }.width('100%').margin({ top: 6 })
        if (this.editingId.length > 0) {
          Button('删除此来源').fontSize(13).fontColor(this.dark() ? '#FFB4AB' : '#B3261E')
            .backgroundColor(Color.Transparent).enabled(this.sourceFormPhase === 'idle')
            .onClick(() => { this.deleteEditedSource(); })
        }
      }.width('100%').padding(18).alignItems(HorizontalAlign.Start)
        .backgroundColor(this.P().card).borderRadius(22)
    }
  }


  /* ── 首页 ── */

  /* ══════════ R14 最终 Dock ══════════
   * R13 四组真机对照的结论：标准 Tabs 的 barFloatingStyle.systemMaterial
   * 是唯一「真的采到后方内容」的一组（HDS 条件齐全仍近不透明、自绘浑浊）。
   * 所以生产 Dock 换成标准 Tabs 的悬浮栏：宽 65%W、高 60、底部安全区 + 12。
   */
  /* ══════════ R17 顶部滚动保护 ══════════
   * 方案 §6.3 的备用路线：不做 HdsNavigation 改造（Root 已经是 Navigation，
   * 再套一层会与 R16 的栈冲突），改成「固定 Toolbar + 单一保护层」：
   * 只用 Scroll 偏移算一个归一化标量 q（0–24vp 保持透明，24–80vp 渐入），
   * 只更新 q，不每帧重建列表。
   */
  private homeScroller: Scroller = new Scroller();
  @State private topGuardQ: number = 0;

  private onHomeScroll(y: number): void {
    if (!Number.isFinite(y) || !this.homeScrollAllowed()) { return; }
    this.pendingHomeScrollY = y;
    this.queueHomeScrollSync();
  }

  private homeScrollAllowed(): boolean {
    return this.homeScrollMounted && this.homeScrollPageVisible && this.appActive && this.currentTab === 0
      && !this.showAdd && !this.showSearch && !this.showDownloads && !this.locked
      && this.detailItem === null && this.browsingLib === null && this.stackNames().length === 0;
  }

  private commitHomeScroll(y: number): void {
    if (!Number.isFinite(y) || !this.homeScrollAllowed()) { return; }
    this.commitArtworkPull(false);
    // currentOffset 是内容累计偏移；只控制轮播生命周期，不改变滚动内容高度。
    // Progress uses the resting height, never the gesture-controlled reveal height.
    // A height-induced onDidScroll only queues a settling read and cannot accumulate extension.
    const p = this.clamp01(y / this.heroArtworkHeight());
    if (Math.abs(p - this.heroScrollP) > 0.004) {
      this.heroScrollP = p;
      this.syncHeroTimer();
    }
  }

  private syncHomeScroll(): void {
    if (!this.homeScrollAllowed()) { return; }
    // onDidScroll may run during layout/re-render. Queue only plain fields here, never @State.
    this.pendingHomeScrollY = Number.NaN;
    this.queueHomeScrollSync();
  }

  private queueHomeScrollSync(): void {
    if (this.homeScrollTask >= 0 || !this.homeScrollAllowed()) { return; }
    const generation = this.homeScrollGeneration;
    this.homeScrollTask = setTimeout(() => {
      // A canceled callback must not clear a newer task's cancellation handle.
      if (generation !== this.homeScrollGeneration || !this.homeScrollMounted) { return; }
      this.homeScrollTask = -1;
      if (!this.homeScrollAllowed()) { this.pendingHomeScrollY = Number.NaN; return; }
      let y = this.pendingHomeScrollY;
      this.pendingHomeScrollY = Number.NaN;
      if (!Number.isFinite(y)) {
        try {
          // Read the newest offset after layout, not the offset from a covered/old Scroll.
          const offset = this.homeScroller.currentOffset();
          if (offset === undefined || offset === null) { return; }
          y = offset.yOffset;
        } catch (e) { return; }
      }
      this.commitHomeScroll(y);
    }, MotionSpec.imageReadyFrame);
  }

  private cancelHomeScrollSync(): void {
    this.homeScrollGeneration++;
    if (this.homeScrollTask >= 0) { clearTimeout(this.homeScrollTask); this.homeScrollTask = -1; }
    this.pendingHomeScrollY = Number.NaN;
    this.cancelArtworkPull();
  }

  private detailPullAllowed(): boolean {
    return this.homeScrollMounted && this.homeScrollPageVisible && this.appActive
      && this.detailItem !== null && !this.showAdd && !this.locked;
  }

  private onArtworkPullTouch(event: TouchEvent, detail: boolean): void {
    if (detail ? !this.detailPullAllowed() : !this.homeScrollAllowed()) { return; }
    const tracker = detail ? this.detailPull : this.homePull;
    if (event.type === TouchType.Down && event.touches.length === 1) {
      try {
        const offset = (detail ? this.detailScroller : this.homeScroller).currentOffset();
        tracker.begin(event.touches[0].windowX, event.touches[0].windowY, offset.yOffset);
      } catch (e) { tracker.reset(); }
    } else if (event.type === TouchType.Move && event.touches.length === 1) {
      tracker.move(event.touches[0].windowX, event.touches[0].windowY);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel || event.touches.length > 1) {
      tracker.finish();
    }
    if (detail) { this.syncDetailPull(); } else { this.syncHomeScroll(); }
  }

  private commitArtworkPull(detail: boolean): void {
    const tracker = detail ? this.detailPull : this.homePull;
    const target = HeroArtwork.pullExtension(tracker.offset, Metrics.width(), MotionPref.reduce());
    const current = detail ? this.detailArtworkPull : this.homeArtworkPull;
    const releasing = tracker.releasing;
    tracker.releasing = false;
    if (current === target) { return; }
    if (releasing) {
      animateTo({ duration: MotionPref.dur(MotionSpec.hero),
        curve: curves.springMotion(HeroArtwork.returnResponse, HeroArtwork.returnDamping) }, () => {
        if (detail) { this.detailArtworkPull = target; } else { this.homeArtworkPull = target; }
      });
    } else if (detail) { this.detailArtworkPull = target; }
    else { this.homeArtworkPull = target; }
  }

  private syncDetailPull(): void {
    if (this.detailPullTask >= 0 || !this.detailPullAllowed()) { return; }
    const generation = this.detailPullGeneration;
    const itemId = (this.detailItem as MediaItem).id;
    this.detailPullTask = setTimeout(() => {
      if (generation !== this.detailPullGeneration) { return; }
      this.detailPullTask = -1;
      if (!this.detailPullAllowed() || (this.detailItem as MediaItem).id !== itemId) { return; }
      this.commitArtworkPull(true);
    }, MotionSpec.imageReadyFrame);
  }

  private cancelArtworkPull(): void {
    this.detailPullGeneration++;
    if (this.detailPullTask >= 0) { clearTimeout(this.detailPullTask); this.detailPullTask = -1; }
    if (this.detailArtworkSizeTask >= 0) { clearTimeout(this.detailArtworkSizeTask); this.detailArtworkSizeTask = -1; }
    this.homePull.reset(); this.detailPull.reset();
    this.homeArtworkPull = 0; this.detailArtworkPull = 0;
  }

  /** 保护层高度：安全区 + 工具栏 48 + 下沿 20（方案：作用到工具栏下方 16–24vp） */
  private topGuardHeight(): number {
    return this.safeTopVp + 48 + 20;
  }

  private statusBarHeight(): number {
    const topPx = AppStorage.get<number>('topAvoidHeight') ?? 0;
    return topPx > 0 ? px2vp(topPx) : this.safeTopVp;
  }
  /* ══════════ R18 服务器切换 ══════════
   * 方案 §8.1：切服务器必须让首页所有请求的旧响应失效，
   * 并把上一个账号的画面状态清干净 —— 不能把旧封面贴到新账号上。
   * 这里的「代次」以 current.id 为准：每个 await 回来都核对一次。
   */
  private async openServerHome(server: ServerConfig): Promise<void> {
    await this.selectServer(server, 'home');
    if (!this.homeScrollMounted || !this.homeScrollPageVisible || this.current === null
      || SourceIdentity.scope(this.current) !== SourceIdentity.scope(server)) { return; }
    this.popNamed('settings:servers');
    this.selectTab(0);
  }

  private serverSelectionGeneration: number = 0;
  private async selectServer(s: ServerConfig, afterUnlock: string = 'select'): Promise<void> {
    const request = ++this.serverSelectionGeneration;
    if (!(await this.serverGate(s, afterUnlock)) || request !== this.serverSelectionGeneration) { return; }
    if (this.current !== null && this.favoriteAccountScope(this.current) === this.favoriteAccountScope(s)) {
      return;
    }
    hilog.info(0x0001, 'NasPlay', 'SERVER switch -> %{public}s', s.id);
    this.current = s;
    Store.setLastId(s.id);
    // 清上一个账号的画面状态
    this.heroItems = [];
    this.heroIndex = 0;
    this.rows = [];
    this.libs = [];
    this.resumeItems = [];
    this.badHeroIds = [];
    this.heroAllFailed = false;
    Ambient.reset();
    this.applyAmbient();
    this.stopHeroTimer();
    await this.loadLibraries();
  }
  private dockWidth(): number {
    const w = Metrics.width() > 0 ? Metrics.width() : 440;
    return Math.round(Math.max(232, Math.min(360, w * 0.65)));
  }

  private dockBottomGap(): number {
    return this.safeBottomVp > 0 ? this.safeBottomVp : 16;
  }

  /** dock 那种玻璃观感：统一背景 / 模糊 / 边缘高光 / 前景色 */
  private glassBg(): string {
    return withAlpha(this.dark() ? '#FFFFFF' : '#FFFFFF', this.dark() ? 0.20 : 0.34);
  }

  private glassBgStrong(): string {
    return withAlpha('#FFFFFF', this.dark() ? 0.28 : 0.46);
  }

  private glassBorder(): string {
    return withAlpha('#FFFFFF', this.dark() ? 0.22 : 0.60);
  }

  private glassBlurStyle(): BlurStyle {
    return this.dark() ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_REGULAR;
  }

  /** 浅色玻璃上必须用深色前景，否则看不见 */
  private glassFg(): string {
    return this.dark() ? '#2A2A30' : '#3A3A40';
  }

  private dockTabW(): number {
    return this.dockWidth() / 5;
  }

  private dockLeft(): number {
    const w = Metrics.width() > 0 ? Metrics.width() : 440;
    return (w - this.dockWidth()) / 2;
  }

  /** 选中指示胶囊的顶部 y（相对全屏） */
  private dockIndicatorTop(): number {
    const h = Metrics.height() > 0 ? Metrics.height() : 994.9;
    return h - this.dockBottomGap() - this.dockHeight() + 8;
  }
  private dockHeight(): number {
    return 60;
  }

  /**
   * R14/R15：一级页 Tabs —— 悬浮 Dock + 每页独立状态
   *
   * ★ 为什么把正文搬进 TabContent 而不是只借 bar：
   *   参考是「点 dock 直接换页，正文不做整页横向位移，各页保留自己的滚动位置」。
   *   只借 bar、正文仍用 if/else 会让每次切页重建整棵子树（滚动位置、图片状态全丢）。
   *   Tabs 的 TabContent 天然保活，正好满足 R15。
   */
  /**
   * HDS 底部页签（官方沉浸光感接入方式）。
   * 文档要点：沉浸光感对普通组件只在「Navigation 标题栏」或
   * 「横向 Tabs 且 barPosition = End 的底部 TabBar」中生效 ——
   * 所以 dock 必须由 HdsTabs 承载，自绘的 View 加材质不会有效果。
   * 材质用 IMMERSIVE + ADAPTIVE，由系统按算力调档。
   */
  private selectTab(index: number): void {
    const next = index < 0 ? 0 : (index > 4 ? 4 : index);
    if (next === this.currentTab) { return; }
    this.currentTab = next;
    if (next === 2) {
      this.loadFavorites();
    } else if (next === 1) {
      this.visionRevision++;
    }
    try {
      this.tabCtl.changeIndex(next);
    } catch (e) {
    }
  }

  @Builder
  hdsDock() {
    HdsTabs({
      barPosition: BarPosition.End,
      index: this.currentTab,
      controller: this.tabCtl
    }) {
      TabContent() {
        this.homeView()
      }
      .tabBar(this.dockStyle(0))

      TabContent() {
        this.visionView()
      }
      .tabBar(this.dockStyle(1))

      TabContent() {
        this.gridView()
      }
      .tabBar(this.dockStyle(2))

      TabContent() {
        this.serverListView()
      }
      .tabBar(this.dockStyle(3))

      TabContent() {
        this.settingsView()
      }
      .tabBar(this.dockStyle(4))
    }
    // 官方要求：barOverlap 让内容延伸到页签下方，vertical false + End 才是横向底部页签
    .barOverlap(true)
    .vertical(false)
    .barPosition(BarPosition.End)
    // 页签条高度：88 会把胶囊拉长变形（用户反馈），
    // 参考应用的 dock 高度约 60vp，这里取 64。
    .barHeight(54)
    .scrollable(false)
    .animationDuration(MotionPref.dur(MotionSpec.page))
    .barFloatingStyle({
      barWidth: {
        smallWidth: this.dockWidth(),
        mediumWidth: this.dockWidth(),
        largeWidth: this.dockWidth()
      },
      barBottomMargin: this.dockBottomGap(),
      // 官方推荐组合：材质类型与材质等级均跟随系统算力策略。
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number) => {
      if (index === this.currentTab) {
        return;
      }
      this.currentTab = index;
      if (index === 2) {
        this.loadFavorites();
      }
      if (index === 1) {
        this.visionRevision++;
      }
      hilog.info(0x0001, 'NasPlay', 'HDSDOCK tab=%{public}d', index);
    })
    .width('100%')
    .height('100%')

  }

  /** 官方 BottomTabBarStyle：页签本身由系统渲染（胶囊玻璃、多色 symbol、按压反馈） */
  /** dock 图标：深色玻璃配浅灰，浅色玻璃配深灰（系统色对比度不够） */
  private dockIconOff(): string {
    return this.dark() ? '#B4B4BC' : '#4A4A52';
  }

  private dockIconOn(): string {
    return this.dark() ? '#5AA0FF' : '#0A59F7';
  }

  private dockStyle(i: number): BottomTabBarStyle {
    if (i === 0) {
      return new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.house'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOff(), this.dockIconOff()]),
        selected: new SymbolGlyphModifier($r('sys.symbol.house_fill'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOn(), this.dockIconOn()])
      }, '首页').labelStyle({ font: { size: 9 }, selectedColor: this.dockIconOn(),
        unselectedColor: this.dockIconOff() });
    }
    if (i === 1) {
      return new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.circle_grid_2x2'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOff(), this.dockIconOff()]),
        selected: new SymbolGlyphModifier($r('sys.symbol.circle_grid_2x2'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOn(), this.dockIconOn()])
      }, 'Vision').labelStyle({ font: { size: 9 }, selectedColor: this.dockIconOn(),
        unselectedColor: this.dockIconOff() });
    }
    if (i === 2) {
      return new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.heart'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOff(), this.dockIconOff()]),
        selected: new SymbolGlyphModifier($r('sys.symbol.heart_fill'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOn(), this.dockIconOn()])
      }, '收藏').labelStyle({ font: { size: 9 }, selectedColor: this.dockIconOn(),
        unselectedColor: this.dockIconOff() });
    }
    if (i === 3) {
      return new BottomTabBarStyle({
        normal: new SymbolGlyphModifier($r('sys.symbol.folder'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOff(), this.dockIconOff()]),
        selected: new SymbolGlyphModifier($r('sys.symbol.folder_fill'))
          .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOn(), this.dockIconOn()])
      }, '服务器').labelStyle({ font: { size: 9 }, selectedColor: this.dockIconOn(),
        unselectedColor: this.dockIconOff() });
    }
    return new BottomTabBarStyle({
      normal: new SymbolGlyphModifier($r('sys.symbol.gearshape'))
        .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOff(), this.dockIconOff()]),
      selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill'))
        .fontSize('20vp')
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([this.dockIconOn(), this.dockIconOn()])
    }, '设置').labelStyle({ font: { size: 9 }, selectedColor: this.dockIconOn(),
        unselectedColor: this.dockIconOff() });
  }

  private dockGlyph(i: number): string {
    if (i === 0) {
      return this.currentTab === 0 ? '⌂' : '⌂';
    }
    if (i === 1) {
      return '⬚';
    }
    if (i === 2) {
      return this.currentTab === 2 ? '♥' : '♡';
    }
    if (i === 3) {
      return '▣';
    }
    return '⚙';
  }

  /** 自绘 dock：玻璃底 + 滑动胶囊 + 5 个页签 */
  @Builder
  dockBar() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 滑动胶囊（先画，位于图标之下）
        Row()
          .width(this.dockTabW() - 10)
          .height(this.dockHeight() - 18)
          .borderRadius((this.dockHeight() - 18) / 2)
          .backgroundColor(withAlpha(this.P().accent, 0.18))
          .position({
            x: this.currentTab * this.dockTabW() + 5,
            y: 9
          })
          .animation({ duration: MotionSpec.normal, curve: Curve.EaseOut })
          .hitTestBehavior(HitTestMode.None)

        Row() {
          ForEach(this.dockLabels, (label: string, idx: number) => {
            this.dockTabW2(idx, label)
          }, (label: string, idx: number) => idx.toString())
        }
        .width(this.dockWidth())
        .height(this.dockHeight())
      }
      .width(this.dockWidth())
      .height(this.dockHeight())
      .backgroundBlurStyle(
        this.dark() ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_REGULAR,
        { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .backgroundColor(withAlpha('#000000', this.dark() ? 0.30 : 0.18))
      .borderRadius(30)
      .border({
        width: 0.5,
        color: withAlpha('#FFFFFF', 0.14)
      })
    }
    .width('100%')
    .padding({ bottom: this.dockBottomGap() })
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  dockTabW2(index: number, label: string) {
    Column() {
      if (index === 0) {
        SymbolGlyph(this.currentTab === 0 ? $r('sys.symbol.house_fill') : $r('sys.symbol.house'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else if (index === 1) {
        SymbolGlyph($r('sys.symbol.circle_grid_2x2'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else if (index === 2) {
        SymbolGlyph(this.currentTab === 2 ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else if (index === 3) {
        SymbolGlyph(this.currentTab === 3 ? $r('sys.symbol.TV_tv_fill') : $r('sys.symbol.TV_tv'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else {
        SymbolGlyph(this.currentTab === 4 ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      }

      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? this.P().accent : this.P().textDim)
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Medium)
        .maxLines(1)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .height(this.dockHeight())
    .justifyContent(FlexAlign.Center)
    .focusable(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      if (index === this.currentTab) {
        return;
      }
      this.currentTab = index;
      if (index === 2) {
        this.loadFavorites();
      }
      if (index === 1) {
        this.visionRevision++;
      }
      hilog.info(0x0001, 'NasPlay', 'DOCK tab=%{public}d', index);
    })
  }

  @Builder
  pageTabs() {
    this.hdsDock()
  }

  @Builder
  addServerSheet() {
    Column() {
      Scroll() {
        this.addForm()
      }
      .padding({ top: 82 })
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  pageTabsInner() {
    Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      TabContent() {
        this.homeView()
      }

      TabContent() {
        this.visionView()
      }

      TabContent() {
        this.gridView()
      }

      TabContent() {
        this.serverListView()
      }

      TabContent() {
        this.settingsView()
      }
    }
    .barHeight(0)
    .vertical(false)
        // 一级页只用 dock 切换，不响应横向滑动（参考无横滑切页）
    .scrollable(false)
    // 统一页面切换时长，并尊重系统减少动态效果设置。
    .animationDuration(MotionPref.dur(MotionSpec.page))
        .width('100%')
    .height('100%')
    .onChange((i: number) => {
      if (i === this.currentTab) {
        return;
      }
      this.currentTab = i;
      if (i === 2) {
        this.loadFavorites();
      }
      if (i === 1) {
        this.visionRevision++;
      }
      hilog.info(0x0001, 'NasPlay', 'DOCK tab=%{public}d', i);
    })
  }

  /* ══════════ R18 服务器锚定菜单 ══════════
   * 方案 §8.1：首页服务器胶囊弹「头像/服务器名 + 当前勾选 + 分隔线」的锚定菜单。
   * 用系统 bindMenu 承担锚定与开合，内容自绘（Menu/MenuItem 是系统浅色面板，
   * 深色应用里会闪白底 —— R12 已经踩过）。
   */
  @Builder
  serverMenu() {
    // Official bindMenu owns the material; content supplies text and actions only.
    Column() {
      if (this.servers.length === 0) {
        Row() {
          Text('还没有服务器')
            .fontSize(13)
            .fontColor(this.P().textDim)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 14 })
      } else {
        ForEach(this.servers.filter((source: ServerConfig): boolean => !this.serverOption(source.id).hidden), (s: ServerConfig) => {
          Row() {
            Text(this.sourceDisplayName(s))
              .fontSize(14)
              .fontColor(this.P().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.current !== null && this.current.id === s.id) {
              Text('✓')
                .fontSize(14)
                .fontColor(this.P().accent)
            }
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 13, bottom: 13 })
          .onClick(() => {
            this.selectServer(s);
          })
        }, (s: ServerConfig) => s.id)
      }
    }
    .width(230)
    .borderRadius(18)
  }

  @Builder
  dockTab(index: number, label: string) {
    Column() {
      if (index === 0) {
        SymbolGlyph(this.currentTab === 0 ? $r('sys.symbol.house_fill') : $r('sys.symbol.house'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else if (index === 1) {
        SymbolGlyph($r('sys.symbol.circle_grid_2x2'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else if (index === 2) {
        SymbolGlyph(this.currentTab === 2 ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else if (index === 3) {
        SymbolGlyph(this.currentTab === 3 ? $r('sys.symbol.TV_tv_fill') : $r('sys.symbol.TV_tv'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      } else {
        SymbolGlyph(this.currentTab === 4 ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor([this.currentTab === index ? this.P().accent : this.P().textDim])
      }

      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? this.P().accent : this.P().textDim)
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Medium)
        .maxLines(1)
        .margin({ top: 2 })
    }
    .width('100%')
    .height(this.dockHeight() - 8)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * R10 氛围背景：低饱和底色 + 上/下两个大范围低频色场 + 一处低频光斑。
   * 全部颜色来自 `Ambient` 的三带取色，随 Hero 拖动权重实时混合。
   * ★ 只做「同屏不同位置有差别」，不做艳丽光斑（方案 §5.3）。
   */
  @Builder
  ambientBackground() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 低饱和底色
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.ambBaseC)

      // ② 上部色场（角度略偏，避免出现水平色带）
      Column()
        .width('100%')
        .height('84%')
        .linearGradient({
          angle: 168,
          colors: [
            [withAlpha(this.ambTopC, 0.70), 0.00],
            [withAlpha(this.ambTopC, 0.34), 0.48],
            [withAlpha(this.ambTopC, 0.0), 1.00]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // ③ 下部色场
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 12,
          colors: [
            [withAlpha(this.ambBotC, 0.0), 0.30],
            [withAlpha(this.ambBotC, 0.52), 0.80],
            [withAlpha(this.ambBotC, 0.46), 1.00]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // ④ 一处低频光斑：让「上部偏左」和「右下」不是同一个色相
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: [Math.round(Metrics.width() * 0.34), Math.round(Metrics.height() * 0.18)],
          radius: Math.round(Metrics.width() * 0.94),
          colors: [
            [withAlpha(this.ambMidC, 0.40), 0.00],
            [withAlpha(this.ambMidC, 0.10), 0.56],
            [withAlpha(this.ambMidC, 0.0), 1.00]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Hero 的 DST_IN 蒙版色标（方案 §5.2 建议起点 1@0 / 1@55 / .85@68 / .40@84 / 0@100）。
   * ★ RGB 固定黑色：这个节点用 BlendMode.DST_IN 参与合成，只有 alpha 起作用，
   *   所以不会把海报「涂成一块页面底色」。
   */
  /** ★ 缓存的蒙版色标：内容恒定，避免每次 build 重新分配导致离屏组重建（真机闪一下） */
  private heroMaskCached: Array<[string, number]> = [];

  private heroMaskStops(): Array<[string, number]> {
    if (this.heroMaskCached.length === 0) {
      for (let i = 0; i < HeroMask.KEYS.length; i++) {
        this.heroMaskCached.push([withAlpha('#000000', HeroMask.ALPHAS[i]), HeroMask.KEYS[i]]);
      }
    }
    return this.heroMaskCached;
  }

  @Builder
  heroDeck() {
    Swiper(this.swiperCtl) {
      ForEach(this.heroItems, (item: MediaItem) => {
        this.heroSlide(item)
      }, (item: MediaItem) => item.id)
    }
    .width('100%')
    .height('100%')
    .indicator(false)
    // R11：首尾循环交给原生 loop（R09 已保证图文同项，不会再出现 A 图 B 标题）
    .loop(this.heroItems.length > 1)
    // ★ 只缓存相邻 1 项：6 张 1080 大图 + 各自的 DST_IN 离屏组同时挂着会掉帧/闪
    .cachedCount(1)
    // ★ 内置 autoplay 关掉：数据重载时视觉页与 onChange 索引会错位
    .autoPlay(false)
    .index(this.heroIndex)
    .duration(MotionSpec.hero)
    // ★ 帧级连续进度：拖动中直接驱动氛围色权重（方案 §5.4）
    .onContentDidScroll((selected: number, idx: number, position: number, axisLen: number) => {
      this.onHeroContentScroll(selected, idx, position, axisLen);
    })
    // 动画结束（含拖动回弹）时把颜色权重归位
    .onAnimationEnd((index: number, extra: SwiperAnimationEvent) => {
      this.onHeroAnimEnd();
    })
    .onChange((i: number) => {
      // clamp 防御：数据刚替换时 i 可能超出新数组长度
      const n = this.heroItems.length;
      if (n <= 0) {
        return;
      }
      const idx = i < 0 ? 0 : (i >= n ? n - 1 : i);
      this.heroIndex = idx;
      this.commitAmbient(idx);
      // 只在条件不再满足时停（不重启，避免每次换页都把 6 秒窗口推后）
      this.syncHeroTimer();
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.heroTouching = true;
        this.stopHeroTimer();
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.heroTouching = false;
        this.restartHeroTimer();
      }
    })
  }

  /** 图文属于同一轮播项，横向拖动时始终保持对应。 */
  @Builder
  heroSlide(item: MediaItem) {
    Stack({ alignContent: Alignment.TopStart }) {
      // ── MaskedArtwork：海报 + 全尺寸 alpha 蒙版 ──
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.isDemo(item)) {
          // 示例模式：内置示例海报
          Image(this.demoImage(item))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .interpolation(ImageInterpolation.High)
        } else if (this.heroImageUrl(item, 1080).length > 0) {
          NetImage({
            url: this.heroImageUrl(item, 1080),
            headers: this.imageHeadersOrEmpty(),
            targetWidth: 1080,
            placeholderColor: this.dark() ? '#101114' : '#F2F4F7',
            onFail: (u: string) => {
              this.onHeroImageFail(item.id);
            }
          })
            .width('100%')
            .height('100%')
        } else {
          // 无图/示例模式：用主色渐变占位，比纯色更像一张海报
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 160,
              colors: [
                [withAlpha(this.P().accent, this.dark() ? 0.42 : 0.30), 0.00],
                [this.P().card, 0.55],
                [this.P().bg, 1.00]
              ]
            })
        }

        // 全尺寸 alpha 蒙版：DST_IN 用后绘制层的 alpha 保留前一层
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: this.heroMaskStops()
          })
          .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .clip(true)
      // 父离屏组不加不透明背景，否则蒙版组会把底色一起遮掉
      .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)

      // 图片底部只做很轻的局部压暗，保持叠加文字的可读性。
      Column()
        .width('100%')
        .height('42%')
        .linearGradient({
          angle: 180,
          colors: [
            [withAlpha('#000000', 0.0), 0.00],
            [withAlpha('#000000', this.dark() ? 0.08 : 0.02), 0.58],
            [withAlpha('#000000', 0.0), 1.00]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        this.heroCopy(item)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .padding({ bottom: 31 })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      this.openDetail(item);
    })
  }

  /** 参考录屏：居中标题、年份、两行简介、评分；没有简介也保留排版位置。 */
  @Builder
  heroCopy(item: MediaItem) {
    Column() {
      Text(item.name)
        .fontSize(30)
        .lineHeight(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.dark() ? '#F5F6F8' : '#17181C')
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(item.year > 0 ? item.year.toString() : '')
        .fontSize(11)
        .lineHeight(14)
        .fontColor(this.dark() ? '#D3D4D6' : '#4B515C')
        .height(14)
        .margin({ top: 24 })

      Text(item.overview)
        .fontSize(10)
        .lineHeight(17)
        .fontColor(this.dark() ? '#D3D4D6' : '#4B515C')
        .height(34)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })
        .width('100%')

      Row({ space: 3 }) {
        if (item.rating > 0) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(9)
            .fontColor([this.dark() ? '#FFD34E' : '#805500'])
          Text(item.rating.toFixed(1))
            .fontSize(9)
            .fontColor(this.dark() ? '#D3D4D6' : '#4B515C')
        }
      }
      .height(14)
      .margin({ top: 5 })
    }
    .width('100%')
    .padding({ left: 52, right: 52 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 0 项 / 全部图片失败时的稳定空态：高度不变、可重试（R11 fallback） */
  @Builder
  heroEmpty() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [withAlpha(this.ambTopC, 0.55), 0.0],
            [withAlpha(this.ambBotC, 0.70), 1.0]
          ]
        })

      Column() {
        Text(this.loading ? '正在连接服务器…' : (this.errMsg.length > 0
          ? '无法连接服务器' : (this.badHeroIds.length > 0 ? '海报加载失败' : '暂无推荐内容')))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.dark() ? '#F5F6F8' : '#17181C')
        if (this.errMsg.length > 0) {
          Text(this.errMsg)
            .fontSize(12)
            .fontColor(this.P().textDim)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 8 })
        }
        if (this.badHeroIds.length > 0 || this.errMsg.length > 0) {
          Row() {
            Text('重试')
              .fontSize(13)
              .fontColor(this.dark() ? '#F5F6F8' : '#17181C')
          }
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .margin({ top: 12 })
          .borderRadius(16)
          .backgroundColor(withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.16))
          .focusable(true)
          .onClick(() => {
              if (this.errMsg.length > 0) {
                this.loadLibraries();
              } else {
                this.retryHero();
              }
          })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 24 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  homeView() {
    if (this.current !== null && this.sourceFamily() !== 'catalog') {
      SourceBrowser({ server: this.current, darkMode: this.dark(),
        active: this.currentTab === 0 && this.homeScrollPageVisible,
        onPlay: (item: MediaItem, siblings: MediaItem[]) => { this.playItem(item, false, siblings); },
        onManage: () => { this.currentTab = 3; this.tabCtl.changeIndex(3); } })
        .padding({ top: this.safeTopVp })
    } else {
      this.catalogHomeView()
    }
  }

  @Builder
  catalogHomeView() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ══════ R10：连续空间氛围背景（全页固定，Scroll 保持透明）══════
      this.ambientBackground()

      Column() {
        Scroll(this.homeScroller) {
        Column() {
          // ══════ Hero：受控伸展的图片、居中文案与底部分页指示器══════
          Column() {
            // ── Hero：整个 Hero 只有一个高度；图 / alpha 蒙版 / 文字都在 SwiperItem 内 ──
            Stack({ alignContent: Alignment.Bottom }) {
              if (this.heroItems.length > 0) {
                this.heroDeck()
              } else {
                this.heroEmpty()
              }
              // 边缘流光：默认关闭，只作为可比对实验（见 HERO_FLOW_LIGHT）
              if (HERO_FLOW_LIGHT) {
                HdsVisualComponent()
                  .width('100%')
                  .height('100%')
                  .hitTestBehavior(HitTestMode.None)
                  .scene(HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK,
                    this.heroSceneCtl)
              }
            }
            .width('100%')
            .height(this.heroDisplayHeight())
            .clip(true)
            // R11：滚出视口就停轮播（不是「页面在就一直在」）
            .onVisibleAreaChange([0.02], (isVisible: boolean, ratio: number) => {
              this.onHeroVisible(isVisible, ratio);
            })

            // ── 分页指示器 ──
            Row() {
              if (this.heroItems.length > 1) {
                ForEach(this.heroItems, (item: MediaItem, i: number) => {
                  Row()
                    .width(i === this.heroIndex ? 14 : 6)
                    .height(6)
                    .borderRadius(3)
                    .backgroundColor(i === this.heroIndex
                      ? (this.dark() ? '#F5F6F8' : '#17181C')
                      : withAlpha(this.dark() ? '#F5F6F8' : '#17181C', 0.24))
                    .margin({ left: 3.2, right: 3.2 })
                    .animation(MotionFx.fadeIn())
                }, (item: MediaItem, i: number) => i.toString())
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ bottom: 10 })
            .margin({ top: -26 })
            .translate({ y: 8.5 })
          }
          .width('100%')


          // 继续播放
          if (this.resumeItems.length > 0) {
            this.sectionHeader('继续播放', '', '')
            Scroll() {
              Row() {
                ForEach(this.resumeItems, (item: MediaItem) => {
                  this.resumeCard(item)
                }, (item: MediaItem) => item.id)
              }
              .constraintSize({ minWidth: '100%' })
              .justifyContent(FlexAlign.Start)
              .padding({ left: 12, right: 12 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .align(Alignment.Start)
            .width('100%')
            .margin({ top: 8 })
          }

          // ══════ 我的媒体（2×2 拼贴，对齐 HosPlayer）══════
          if (this.rows.length > 0) {
            Row() {
              Text('我的媒体')
                .fontSize(Metrics.f(16))
                .lineHeight(21)
                .fontColor(this.P().text)
                .fontWeight(FontWeight.Medium)
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(Metrics.f(16))
                .fontColor([this.P().textDim])
                .margin({ left: 8 })
              Blank()
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(Metrics.f(16))
                .fontColor([this.P().textDim])
                .margin({ right: 14 })
              SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                .fontSize(Metrics.f(16))
                .fontColor([this.P().textDim])
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 18, bottom: 10 })

            Scroll() {
              Row() {
                ForEach(this.rows, (row: LibRow) => {
                  this.mediaCollage(row)
                }, (row: LibRow) => 'collage_' + row.lib.id)
              }
              .padding({ left: 12, right: 12 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }

          // 各库最新
          ForEach(this.rows, (row: LibRow) => {
            this.sectionHeader(row.lib.name, row.items.length.toString() + ' 部', row.lib.id)
            Scroll() {
              Row() {
                ForEach(row.items, (item: MediaItem) => {
                  PosterCard({
                    title: item.name,
                    demoRes: this.isDemo(item) ? this.demoImage(item) : undefined,
                    subtitle: item.year > 0 ? item.year.toString() : '',
                    imageUrl: item.hasPrimaryImage ?
                      MediaServices.imageUrl(this.current as ServerConfig, item.id, 360, item.imageTag) : '',
                    rating: item.rating,
                    progress: item.progressRatio(),
                    watched: item.played,
                    cardWidth: this.posterWidth(),
              headers: this.imageHeadersOrEmpty(),
              darkMode: this.dark(),
                    onTap: () => {
                      if (item.isPlayable()) {
                        this.playItem(item);
                      } else {
                        this.openDetail(item);
                      }
                    }
                  })
                    .margin({ right: 13 })
                }, (item: MediaItem) => item.id)
              }
              .padding({ left: 12, right: 12 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .align(Alignment.TopStart)
            .scrollBar(BarState.Off)
            .width('100%')
            .margin({ top: 8 })
          }, (row: LibRow) => row.lib.id)

          Column().height(this.safeBottomVp + 60 + 12 + 16)
        }
        .width('100%')
      }
        .scrollBar(BarState.Off)
        // Hero height is explicitly extended while native edge displacement stays disabled, keeping artwork at the top edge.
        .edgeEffect(EdgeEffect.None)
        .align(Alignment.TopStart)
        .onDidScroll(() => {
          this.syncHomeScroll();
        })
        .onTouch((event: TouchEvent) => { this.onArtworkPullTouch(event, false); })
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.surfaceColor())
    }

  /* ══════════ 搜索 ══════════ */

  /* ══════════ 下载 ══════════ */

  async togglePush(v: boolean): Promise<void> {
    if (!v) {
      this.pushEnabled = false;
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const ok = await Push.requestPermission(ctx);
      this.pushEnabled = ok;
      if (ok) {
        Push.send('推送已开启', '下载完成、订阅更新会通知你');
      }
    } catch (e) {
      this.pushEnabled = false;
    }
  }

  refreshDownloads(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    DownloadManager.restore(ctx).then((list: DownloadRecord[]) => {
      this.downloads = list;
    }).catch(() => {
    });
  }

  /** 详情页「重播」：从 0 开始播当前条目 */
  private replayFromStart(): void {
    const it = this.detailItem;
    if (it === null) {
      return;
    }
    this.playItem(it, true);
  }

  /** 详情页「标记已看」：清掉该条目的继续观看记录 */
  private markCurrentWatched(): void {
    const it = this.detailItem;
    const sv = this.current;
    if (it === null || sv === null) {
      return;
    }
    ProgressRepository.markComplete(sv.id, sv.userId, it.id).then(() => {
      promptAction.showToast({ message: '已标记为看完' });
      this.loadResume(sv);
    }).catch(() => {
      promptAction.showToast({ message: '标记失败' });
    });
  }

  /** 详情页「收藏」：加入/移出收藏 */
  private async toggleCurrentFavorite(): Promise<void> {
    const it = this.detailItem;
    const sv = this.current;
    if (it === null || sv === null || this.favoriteMutationPending) { return; }
    const scope = this.favoriteAccountScope(sv);
    this.favoriteMutationPending = true;
    try {
      let exists = it.isFavorite;
      if (!it.favoriteKnown) {
        const detail = await MediaServices.getItemDetail(sv, it.id);
        if (!detail.item.favoriteKnown) { throw new Error('favorite state unavailable'); }
        exists = detail.item.isFavorite;
      }
      if (scope !== this.favoriteAccountScope(this.current)) { return; }
      if (exists) { await MediaServices.removeFavorite(sv, it.id); }
      else { await MediaServices.addFavorite(sv, it.id); }
      if (scope !== this.favoriteAccountScope(this.current)) { return; }
      it.isFavorite = !exists;
      it.favoriteKnown = true;
      promptAction.showToast({ message: exists ? '已取消收藏' : '已加入收藏' });
      this.loadFavorites(true);
    } catch (e) {
      if (scope === this.favoriteAccountScope(this.current)) { promptAction.showToast({ message: '收藏操作未完成，请重试' }); }
    } finally { this.favoriteMutationPending = false; }
  }

  /** 详情页「下载」：把当前条目加入下载队列 */
  private downloadCurrent(): void {
    const it = this.detailItem;
    if (it === null) {
      return;
    }
    this.startDownload(it);
  }

  async startDownload(item: MediaItem): Promise<void> {
    const sv = this.current;
    if (sv === null) {
      return;
    }
    let lease = '';
    try {
      if (!item.isPlayable() || item.type === 'Channel') { throw new Error('当前条目不支持整文件下载'); }
      const accountScope = SourceIdentity.scope(sv);
      const ctx = getContext(this) as common.UIAbilityContext;
      const rec = new DownloadRecord();
      rec.itemId = 'source-' + SourceIdentity.key(accountScope + '\u0000' + item.id);
      rec.title = item.name;
      rec.subtitle = item.seriesName;
      if (this.downloads.some((existing: DownloadRecord) => existing.itemId === rec.itemId
        && (existing.state === DownloadState.WAIT || existing.state === DownloadState.RUNNING))) {
        throw new Error('该影片已有下载任务');
      }
      let sourceDetail = this.detail !== null && this.detail.item.id === item.id ? this.detail : null;
      if (sourceDetail === null && sv.kind !== 'fnos') { sourceDetail = await MediaServices.getItemDetail(sv, item.id); }
      const sourceId = sourceDetail !== null && sourceDetail.sources.length > 0 ? sourceDetail.sources[0].id : '';
      const playback = await MediaServices.getPlaybackInfo(sv, item.id, sourceId, 0);
      lease = SourcePlaybackLeases.register(playback.release);
      if (this.current === null || SourceIdentity.scope(this.current) !== accountScope || !this.homeScrollMounted) { return; }
      if (playback.isLive || playback.isHls || /\.m3u8(?:[?#]|$)/i.test(playback.url)) {
        throw new Error('直播和 HLS 分段流暂不支持整文件下载');
      }
      if (lease.length > 0 || !/^https?:\/\//i.test(playback.url)) {
        throw new Error('此来源需要专用播放会话，暂不支持整文件下载');
      }
      SourcePlaybackPolicy.useMpv(sv.kind, playback.url); // Reject malformed/unknown routes before the system task.
      if (sourceId.length > 0 && playback.mediaSourceId.length > 0 && sourceId !== playback.mediaSourceId) {
        throw new Error('服务器未返回所选视频源，未开始下载');
      }
      rec.url = playback.url;
      rec.headers = SourcePlaybackPolicy.headers(sv.kind,
        playback.headers !== null ? playback.headers : MediaServices.streamHeaders(sv), '');
      rec.state = DownloadState.WAIT;

      await DownloadManager.start(ctx, rec, (r: DownloadRecord) => {
        if (!this.homeScrollMounted) { return; }
        const arr = this.downloads.slice();
        let at = -1;
        for (let i = 0; i < arr.length; i++) {
          if (arr[i].itemId === r.itemId) {
            at = i;
            break;
          }
        }
        if (at < 0) {
          arr.push(r);
        } else {
          arr[at] = r;
        }
        this.downloads = arr;
        if (r.state === DownloadState.DONE && this.pushEnabled) {
          Push.notifyDownloadDone(r.title);
        }
      });
      if (rec.state === DownloadState.FAILED) { throw new Error(rec.error); }
      if (rec.state === DownloadState.RUNNING || rec.state === DownloadState.DONE) {
        promptAction.showToast({ message: rec.state === DownloadState.DONE ? '影片已下载' : '已加入下载' });
      }
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message });
    } finally { if (lease.length > 0) { await SourcePlaybackLeases.release(lease).catch(() => {}); } }
  }

  async playDownloaded(rec: DownloadRecord): Promise<void> {
    const p2: PlayParams = {
      url: rec.filePath,
      title: rec.title,
      subtitle: rec.subtitle,
      isHls: false,
      startTicks: 0,
      itemId: rec.itemId,
      subtitles: [],
      token: '',
      // 本地文件没有服务器账号，用独立 local scope，避免污染服务器历史
      serviceKind: 'local',
      serverId: 'local',
      userId: 'local',
      itemType: 'Episode',
      seriesId: '',
      seasonNumber: 0,
      episodeNumber: 0,
      imageTag: ''
    };
    router.pushUrl({ url: 'pages/PlayerPage', params: p2 });
  }

  removeDownload(rec: DownloadRecord): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    DownloadManager.remove(ctx, rec.itemId);
    this.downloads = this.downloads.filter((d: DownloadRecord) => d.itemId !== rec.itemId);
  }

  /** 播放缓存占用文案 */
  private playCacheText(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return MediaCache.describe(ctx);
  }

  /** 清空播放缓存（MKV 播放会在 cacheDir 落 2GB 级副本） */
  private confirmClearPlayCache(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const before: string = MediaCache.describe(ctx);
    if (before === '无缓存') {
      promptAction.showToast({ message: '当前没有播放缓存' });
      return;
    }
    AlertDialog.show({
      systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent),
      title: '清理播放缓存',
      message: '当前占用 ' + before + '。清理后再次播放 MKV 需要重新缓冲。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        fontColor: '#E5484D',
        action: () => {
          const res: ClearResult = MediaCache.clearAll(ctx);
          let msg: string = '已释放 ' + Math.round(res.freed / 1048576).toString() + ' MB';
          if (res.kept > 0) {
            msg = msg + '，' + res.kept.toString() + ' 个使用中已保留';
          }
          promptAction.showToast({ message: msg });
          this.cacheRev++;
        }
      }
    });
  }

  private downloadedBytes(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return DownloadManager.fmtSize(DownloadManager.totalSize(ctx));
  }

  async saveTmdbKey(): Promise<void> {
    const k = this.tmdbInput.trim();
    this.tmdbKey = k;
    await Store.setTmdbKey(k);
    this.showTmdbInput = false;
    this.tmdbInput = '';
    promptAction.showToast({ message: 'TMDB 配置已保存' });
  }

  private favoriteAccountScope(server: ServerConfig | null): string {
    return server === null ? '' : SourceIdentity.scope(server);
  }

  private syncFavoritesScope(): void {
    const scope = this.favoriteAccountScope(this.current);
    if (scope === this.favoritesScope) { return; }
    this.favoritesGeneration++;
    this.favoritesScope = scope;
    this.favorites = [];
    this.favoritesLoading = false;
    this.favoritesError = '';
  }

  private onCurrentServerChanged(): void {
    this.visionActionGeneration++;
    this.syncFavoritesScope();
    if (this.currentTab === 2 && this.current !== null) { this.loadFavorites(); }
  }

  private visibleFavorites(): MediaItem[] {
    return this.current !== null && this.favoriteAccountScope(this.current) === this.favoritesScope ? this.favorites : [];
  }

  private favoritesRequestCurrent(generation: number, scope: string): boolean {
    return generation === this.favoritesGeneration && scope === this.favoritesScope
      && scope === this.favoriteAccountScope(this.current);
  }

  async loadFavorites(force: boolean = false): Promise<void> {
    this.syncFavoritesScope();
    const s = this.current;
    if (s === null || this.favoritesLoading && !force) { return; }
    const scope = this.favoriteAccountScope(s);
    const generation = ++this.favoritesGeneration;
    this.favoritesLoading = true;
    this.favoritesError = '';
    try {
      const r = await MediaServices.getFavorites(s, 100);
      if (!this.favoritesRequestCurrent(generation, scope)) { return; }
      this.favorites = r;
    } catch (e) {
      if (this.favoritesRequestCurrent(generation, scope)) {
        this.favoritesError = '收藏暂时无法读取，请检查服务器连接后重试';
      }
    } finally {
      if (this.favoritesRequestCurrent(generation, scope)) { this.favoritesLoading = false; }
    }
  }

  async loadPeople(itemId: string): Promise<void> {
    const s = this.current;
    if (s === null) {
      return;
    }
    const generation = this.detailRequestGeneration, scope = SourceIdentity.scope(s);
    try {
      const people = await MediaServices.getPeople(s, itemId);
      if (this.detailRequestCurrent(generation, scope, itemId)) { this.people = people; }
    } catch (e) {
      if (this.detailRequestCurrent(generation, scope, itemId)) { this.people = []; }
    }
  }

  /** 打开某个媒体库（浏览全部内容） */
  async openLibrary(server: ServerConfig, lib: Library): Promise<void> {
    const generation = ++this.libGeneration;
    if (!(await this.serverGate(server)) || generation !== this.libGeneration || !this.homeScrollMounted || !this.homeScrollPageVisible) { return; }
    this.libFavoriteGeneration++;
    this.libServer = server;
    this.browsingLib = lib;
    this.libItems = [];
    this.libVisibleItems = [];
    this.libHeroItems = [];
    this.libMode = 0;
    this.libGenre = '';
    this.libHeroIndex = 0;
    this.libSort = 0;
    this.libDescending = false;
    this.libSortOpen = false;
    this.libFavoriteIds = [];
    this.libFavoritesLoaded = false;
    this.libFavoritesLoading = false;
    this.libFavoriteError = '';
    this.libAmbient = '';
    this.libAmbientKey = '';
    this.libError = '';
    this.libLoading = true;
    this.ensureSubpage('library');
    try {
      const items = await MediaServices.getItems(server, lib.id, 0, 600, false);
      if (generation !== this.libGeneration || this.browsingLib === null || this.browsingLib.id !== lib.id) {
        return;
      }
      this.libItems = items;
      this.libFavoriteIds = items.filter((item: MediaItem) => item.favoriteKnown && item.isFavorite)
        .map((item: MediaItem) => item.id);
      this.refreshLibraryItems();
    } catch (e) {
      if (generation === this.libGeneration) {
        this.libError = '媒体库加载失败，请重试';
      }
    } finally {
      if (generation === this.libGeneration) { this.libLoading = false; }
    }
  }

  closeLibrary(): void {
    this.libGeneration++;
    this.libFavoriteGeneration++;
    this.browsingLib = null;
    this.libServer = null;
    this.libItems = [];
    this.libVisibleItems = [];
    this.libHeroItems = [];
    this.libFavoriteIds = [];
    this.libSortOpen = false;
    this.libLoading = false;
    this.libFavoritesLoading = false;
    this.libAmbientKey = '';
  }

  private libraryTitleMenus(): HdsNavigationMenuContentOptions {
    return { value: [
      { content: { label: this.libWideCards ? '竖版海报' : '横版海报',
        icon: this.libWideCards ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.rectangle_split_2x1'),
        action: () => { this.libWideCards = !this.libWideCards; this.libSortOpen = false; } } },
      { content: { label: '排序', icon: $r('sys.symbol.arrow_left_arrow_right'),
        action: () => { this.libSortOpen = !this.libSortOpen; } } }
    ] };
  }

  private libraryWidth(): number {
    return this.winW > 0 ? this.winW : Metrics.width();
  }

  private libraryUnit(value: number): number {
    return value * Math.min(this.libraryWidth(), 600) / 890;
  }

  private libraryColumns(): number {
    return this.libraryWidth() >= 700 ? (this.libWideCards ? 5 : 6) : (this.libWideCards ? 3 : 4);
  }

  private libraryCardWidth(): number {
    const pad = this.libraryUnit(this.libWideCards ? 42 : 35);
    const gap = this.libraryUnit(this.libWideCards ? 49 : 37);
    return (this.libraryWidth() - pad * 2 - gap * (this.libraryColumns() - 1)) / this.libraryColumns();
  }

  private libraryTabSymbol(mode: number): Resource {
    if (mode === 1) { return $r('sys.symbol.folder'); }
    if (mode === 2) { return $r('sys.symbol.funnel'); }
    if (mode === 3) { return $r('sys.symbol.bookmark'); }
    return $r('sys.symbol.square_grid_2x2');
  }

  private libraryTabLabel(mode: number): string {
    return ['海报', '目录', '类型', '收藏'][mode];
  }

  private libraryGenres(): string[] {
    const values: string[] = [];
    for (let i = 0; i < this.libItems.length; i++) {
      for (let j = 0; j < this.libItems[i].genres.length; j++) {
        const genre = this.libItems[i].genres[j].trim();
        if (genre.length > 0 && values.indexOf(genre) < 0) { values.push(genre); }
      }
    }
    return values.sort((a: string, b: string) => a.localeCompare(b));
  }

  private libraryGenreCount(genre: string): number {
    return this.libItems.filter((item: MediaItem) => item.genres.indexOf(genre) >= 0).length;
  }

  private libraryDate(item: MediaItem, field: number): number {
    const value = field === 1 ? item.createdAt : item.premiereDate;
    const time = typeof value === 'string' && /^\d{4}-\d{2}-\d{2}/.test(value) ? Date.parse(value) : NaN;
    return Number.isFinite(time) ? time : 0;
  }

  private librarySortAvailable(field: number): boolean {
    if (field !== 1 && field !== 2) { return true; }
    return this.libItems.some((item: MediaItem) => this.libraryDate(item, field) > 0);
  }

  private chooseLibrarySort(field: number): void {
    if (!this.librarySortAvailable(field)) {
      promptAction.showToast({ message: '服务器未提供' + this.librarySortLabels[field] + '，无法排序' });
      return;
    }
    this.libDescending = this.libSort === field ? !this.libDescending : field !== 0;
    this.libSort = field;
    this.libSortOpen = false;
    this.refreshLibraryItems();
  }

  private refreshLibraryItems(): void {
    let items = this.libItems.slice();
    if (this.libMode === 1) {
      items = items.filter((item: MediaItem) => item.isFolder());
    } else if (this.libMode === 2 && this.libGenre.length > 0) {
      items = items.filter((item: MediaItem) => item.genres.indexOf(this.libGenre) >= 0);
    } else if (this.libMode === 3) {
      items = items.filter((item: MediaItem) => this.libFavoriteIds.indexOf(item.id) >= 0);
    }
    const direction = this.libDescending ? -1 : 1;
    if (this.libSort === 4) {
      // Shuffle once on a user/data change, never as a side effect of a builder.
      for (let i = items.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const item = items[i]; items[i] = items[j]; items[j] = item;
      }
    } else {
      items.sort((a: MediaItem, b: MediaItem) => {
        if (this.libSort === 1 || this.libSort === 2) {
          const ad = this.libraryDate(a, this.libSort);
          const bd = this.libraryDate(b, this.libSort);
          if (ad === 0 && bd > 0) { return 1; }
          if (bd === 0 && ad > 0) { return -1; }
          if (ad !== bd) { return (ad - bd) * direction; }
        } else if (this.libSort === 3 && a.rating !== b.rating) {
          return (a.rating - b.rating) * direction;
        }
        return a.name.localeCompare(b.name) * (this.libSort === 0 ? direction : 1);
      });
    }
    this.libVisibleItems = items;
    this.libHeroItems = this.libMode === 1 ? [] : items.filter((item: MediaItem) =>
      item.hasPrimaryImage || item.backdropTag.length > 0).slice(0, 8);
    this.libHeroIndex = 0;
    this.updateLibraryAmbient();
    try { this.libraryScroller.scrollEdge(Edge.Top); } catch (e) { /* Not bound before first render. */ }
  }

  private selectLibraryMode(mode: number): void {
    this.libMode = mode;
    this.libGenre = '';
    this.libSortOpen = false;
    this.refreshLibraryItems();
    if (mode === 3) { this.loadLibraryFavorites(); }
  }

  private async loadLibraryFavorites(): Promise<void> {
    const server = this.libServer;
    if (server === null || this.libFavoritesLoading) { return; }
    const generation = this.libGeneration;
    const request = ++this.libFavoriteGeneration;
    this.libFavoritesLoading = true;
    this.libFavoriteError = '';
    try {
      const items = await MediaServices.getFavorites(server, 5000);
      if (generation !== this.libGeneration || request !== this.libFavoriteGeneration) { return; }
      this.libFavoriteIds = items.map((item: MediaItem) => item.id);
      this.libFavoritesLoaded = true;
      if (this.libMode === 3) { this.refreshLibraryItems(); }
    } catch (e) {
      if (generation === this.libGeneration && request === this.libFavoriteGeneration) {
        // Keep confirmed item flags/previous successful ids. An HTTP error is not an empty collection.
        this.libFavoriteError = '服务器未能读取收藏，点击重试';
      }
    } finally {
      if (generation === this.libGeneration && request === this.libFavoriteGeneration) {
        this.libFavoritesLoading = false;
      }
    }
  }

  private libraryImageUrl(item: MediaItem, wide: boolean): string {
    const server = this.libServer;
    if (server === null) { return ''; }
    if (wide && (item.backdropTag.length > 0 || item.imageTag.length > 0)) {
      return MediaServices.backdropUrl(server, item.id, 1080, item.backdropTag, item.imageTag);
    }
    return item.hasPrimaryImage ? MediaServices.imageUrl(server, item.id, 420, item.imageTag) : '';
  }

  private updateLibraryAmbient(): void {
    const item = this.libHeroItems[this.libHeroIndex];
    const server = this.libServer;
    if (item === undefined || server === null) { this.libAmbient = ''; return; }
    const key = server.id + ':' + item.id + ':' + item.imageTag + ':' + (this.dark() ? 'dark' : 'light');
    if (key === this.libAmbientKey) { return; }
    this.libAmbientKey = key;
    const cached = this.libAmbientCache.get(key);
    if (cached !== undefined) { this.libAmbient = cached; return; }
    const generation = this.libGeneration;
    DominantColor.vibrantFromUrl(this.libraryImageUrl(item, true), '', '', MediaServices.imageHeaders(server)).then((rgb: number) => {
      if (generation !== this.libGeneration || key !== this.libAmbientKey || rgb < 0) { return; }
      const color = AmbientPalette.field(rgb, this.dark(), 1);
      if (this.libAmbientCache.size > 20) { this.libAmbientCache.clear(); }
      this.libAmbientCache.set(key, color);
      this.libAmbient = color;
    });
  }

  private libraryEmptyText(): string {
    if (this.libMode === 1) { return '这个库没有返回可浏览的系列或合集'; }
    if (this.libMode === 2 && this.libGenre.length === 0) { return '服务器没有提供类型信息'; }
    if (this.libMode === 3) {
      if (this.libFavoriteError.length > 0) { return '收藏读取失败，请重试'; }
      return this.libFavoritesLoaded ? '这个库里还没有收藏' : '正在读取真实收藏';
    }
    return '这个库里还没有内容';
  }

  private librarySortNote(): string {
    if (this.libSort === 1 || this.libSort === 2) {
      const missing = this.libVisibleItems.filter((item: MediaItem) => this.libraryDate(item, this.libSort) === 0).length;
      if (missing > 0) { return missing.toString() + '项缺少' + this.librarySortLabels[this.libSort] + '，已置于末尾'; }
    }
    return this.libItems.length >= 600 ? '已载入600项，筛选与排序基于已载入内容' : '';
  }

  private openLibraryItem(item: MediaItem): void {
    this.libSortOpen = false;
    if (item.isPlayable()) { this.playItem(item); }
    else { this.openDetail(item); }
  }

  private libraryRowStarts(count: number): number[] {
    const rows: number[] = [];
    for (let i = 0; i < count; i += this.libraryColumns()) { rows.push(i); }
    return rows;
  }

  private retryLibrary(): void {
    if (this.libServer !== null && this.browsingLib !== null) {
      this.openLibrary(this.libServer, this.browsingLib);
    }
  }

  private libraryHeroActive(): boolean {
    const names = this.stackNames();
    return this.appActive && names.length > 0 && names[names.length - 1] === 'library' && !this.libSortOpen;
  }

  private libraryBackdropUrl(): string {
    const item = this.libHeroItems[this.libHeroIndex];
    return item !== undefined ? this.libraryImageUrl(item, true) : '';
  }

  private libraryHeroIsCurrent(item: MediaItem): boolean {
    const current = this.libHeroItems[this.libHeroIndex];
    return current !== undefined && current.id === item.id;
  }

  async doSearch(): Promise<void> {
    const s = this.current;
    const q = this.searchQuery.trim();
    if (s === null || q.length === 0) {
      return;
    }
    this.searching = true;
    try {
      const r = await MediaServices.search(s, q, 60);
      this.searchResults = r;
    } catch (e) {
      this.searchResults = [];
    }
    this.searching = false;
  }

  /** 媒体库浏览页 */
  @Builder
  libraryView() {
    Stack({ alignContent: Alignment.TopStart }) {
      LibraryBackdrop({ url: this.libraryBackdropUrl(),
        headers: this.libServer !== null ? MediaServices.imageHeaders(this.libServer) : {},
        scopeId: this.libServer !== null ? this.libServer.id + ':' + this.libServer.userId : '',
        fallbackColor: this.libAmbient.length > 0 ? this.libAmbient : this.P().bg,
        baseColor: this.P().bg, darkMode: this.dark(), blurRadius: this.libraryUnit(100) })
      Column() {
        this.libraryFilterBar()
        if (this.libLoading) {
          Column() { LoadingProgress().width(36).height(36).color(this.P().accent) }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.libError.length > 0) {
          Column({ space: 18 }) {
            Text(this.libError).fontSize(this.libraryUnit(24)).fontColor(this.P().textDim)
            Button('重新加载').onClick(() => { this.retryLibrary(); })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          if (this.libMode === 3 && this.libFavoriteError.length > 0) {
            Text(this.libFavoriteError).fontSize(this.libraryUnit(22)).fontColor(this.P().accent)
              .width('100%').padding(this.libraryUnit(18)).onClick(() => { this.loadLibraryFavorites(); })
          }
          if (this.libMode === 3 && this.libFavoritesLoading) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color(this.P().accent)
              Text('正在读取收藏').fontSize(this.libraryUnit(21)).fontColor(this.P().textDim)
            }.height(this.libraryUnit(60))
          }
          if (this.libMode === 2 && this.libGenre.length > 0) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(this.libraryUnit(22)).fontColor([this.P().text])
              Text(this.libGenre + ' · ' + this.libVisibleItems.length.toString())
                .fontSize(this.libraryUnit(23)).fontColor(this.P().text)
            }.width('100%').padding(this.libraryUnit(24))
              .onClick(() => { this.libGenre = ''; this.refreshLibraryItems(); })
          }
          if (this.librarySortNote().length > 0) {
            Text(this.librarySortNote()).fontSize(this.libraryUnit(18)).fontColor(this.P().textDim)
              .padding({ top: 6, bottom: 6, left: this.libraryUnit(35), right: this.libraryUnit(35) })
          }
          this.libraryContentList()
        }
      }
      .width('100%').height('100%').padding({ top: this.libraryUnit(212) })
      if (this.libSortOpen) { this.librarySortPopover() }
    }
    .width('100%').height('100%').backgroundColor(this.P().bg).clip(true)
  }

  @Builder
  libraryFilterBar() {
    Row() {
      ForEach([0, 1, 2, 3], (mode: number) => {
        Row() {
          SymbolGlyph(this.libraryTabSymbol(mode)).fontSize(this.libraryUnit(34))
            .fontColor([this.libMode === mode ? this.P().text : this.P().textDim])
        }.height(this.libraryUnit(72)).layoutWeight(1).justifyContent(FlexAlign.Center)
          .borderRadius(this.libraryUnit(36))
          .backgroundColor(this.libMode === mode ? withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.10) : Color.Transparent)
          .accessibilityText(this.libraryTabLabel(mode) + (this.libMode === mode ? '，已选择' : ''))
          .onClick(() => { this.selectLibraryMode(mode); })
      }, (mode: number) => mode.toString())
    }.height(this.libraryUnit(76)).width(this.libraryWidth() - this.libraryUnit(60))
      .margin({ left: this.libraryUnit(30), right: this.libraryUnit(30) })
      .padding(this.libraryUnit(2)).borderRadius(this.libraryUnit(38))
      .border({ width: 0.5, color: withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.24) })
      .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN, interactive: true }))
  }

  @Builder
  libraryHero() {
    Swiper(this.librarySwiper) {
      ForEach(this.libHeroItems, (item: MediaItem) => {
        Column() {
          NetImage({ url: this.libraryImageUrl(item, true),
            headers: this.libServer !== null ? MediaServices.imageHeaders(this.libServer) : {},
            targetWidth: 1080, placeholderColor: this.P().card })
            .width('100%').height(this.libraryUnit(472)).borderRadius(this.libraryUnit(28)).clip(true)
          Column().height(this.libraryUnit(112))
          Column() {
            Row({ space: this.libraryUnit(10) }) {
              if (item.rating > 0) {
                SymbolGlyph($r('sys.symbol.star_fill')).fontSize(this.libraryUnit(22)).fontColor(['#FFD500'])
                Text(item.rating.toFixed(1)).fontSize(this.libraryUnit(20)).fontColor(this.P().text)
              }
            }.height(this.libraryUnit(32)).justifyContent(FlexAlign.Center)
            Text(item.year > 0 ? item.year.toString() : '').fontSize(this.libraryUnit(22))
              .fontColor(this.P().text).height(this.libraryUnit(32)).margin({ top: this.libraryUnit(4) })
            Text(item.overview).fontSize(this.libraryUnit(23)).fontColor(this.P().text)
              .height(this.libraryUnit(32)).margin({ top: this.libraryUnit(10) })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
          }.width('100%').clip(true).opacity(this.libraryHeroIsCurrent(item) ? 1 : 0)
        }.width('100%').clip(true).onClick(() => { this.openLibraryItem(item); })
      }, (item: MediaItem) => item.id)
    }.width('100%').height(this.libraryUnit(694))
      .prevMargin(this.libraryUnit(10)).nextMargin(this.libraryUnit(65)).itemSpace(this.libraryUnit(30))
      .indicator(false).cachedCount(1).index(this.libHeroIndex).loop(this.libHeroItems.length > 1)
      .autoPlay(this.libHeroItems.length > 1 && this.libraryHeroActive()).interval(6000).duration(420)
      .onChange((index: number) => {
        if (index >= 0 && index < this.libHeroItems.length) {
          this.libHeroIndex = index; this.updateLibraryAmbient();
        }
      })
  }

  @Builder
  libraryMediaCard(item: MediaItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.libraryImageUrl(item, this.libWideCards).length > 0) {
          NetImage({ url: this.libraryImageUrl(item, this.libWideCards),
            headers: this.libServer !== null ? MediaServices.imageHeaders(this.libServer) : {},
            targetWidth: this.libWideCards ? 540 : 420, placeholderColor: this.P().card })
            .width('100%').height('100%')
        } else {
          Column() {
            SymbolGlyph(item.isFolder() ? $r('sys.symbol.folder') : $r('sys.symbol.film'))
              .fontSize(this.libraryUnit(46)).fontColor([this.P().textDim])
          }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(this.P().card)
        }
        if (item.rating > 0) {
          Text(item.rating.toFixed(1)).fontSize(this.libraryUnit(20)).fontColor('#F4F4F4')
            .padding({ left: this.libraryUnit(10), right: this.libraryUnit(10), top: this.libraryUnit(6), bottom: this.libraryUnit(6) })
            .backgroundColor(withAlpha('#000000', 0.65)).borderRadius(this.libraryUnit(10))
        }
      }.width('100%').height(this.libraryCardWidth() * (this.libWideCards ? 0.5625 : 1.5))
        .borderRadius(this.libraryUnit(20)).clip(true)
      Text(item.name).fontSize(this.libraryUnit(25)).fontWeight(FontWeight.Medium).fontColor(this.P().text)
        .width('100%').height(this.libraryUnit(32)).lineHeight(this.libraryUnit(32))
        .margin({ top: this.libraryUnit(12) }).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
      Text(item.year > 0 ? item.year.toString() : '').fontSize(this.libraryUnit(20)).fontColor(this.P().text)
        .height(this.libraryUnit(26)).margin({ top: this.libraryUnit(4) })
    }.width(this.libraryCardWidth()).onClick(() => { this.openLibraryItem(item); })
      .accessibilityText(item.name + (item.year > 0 ? '，' + item.year.toString() : ''))
  }

  @Builder
  libraryGenreCard(genre: string) {
    Column() {
      Column() {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(this.libraryUnit(72)).fontColor(['#F4E97A'])
      }.width('100%').height(this.libraryCardWidth() * 1.15)
        .justifyContent(FlexAlign.Center).backgroundColor(this.P().card).borderRadius(this.libraryUnit(14))
      Text(genre).fontSize(this.libraryUnit(23)).fontColor(this.P().text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').textAlign(TextAlign.Center).margin({ top: this.libraryUnit(12) })
      Text(this.libraryGenreCount(genre).toString() + '项').fontSize(this.libraryUnit(18))
        .fontColor(this.P().textDim).margin({ top: this.libraryUnit(5) })
    }.width(this.libraryCardWidth())
      .onClick(() => { this.libGenre = genre; this.refreshLibraryItems(); })
      .accessibilityText(genre + '，' + this.libraryGenreCount(genre).toString() + '项')
  }

  @Builder
  libraryContentList() {
    List({ space: 0, scroller: this.libraryScroller }) {
      if (this.libMode === 2 && this.libGenre.length === 0) {
        if (this.libraryGenres().length === 0) {
          ListItem() { this.libraryEmptyState() }
        } else {
          ForEach(this.libraryRowStarts(this.libraryGenres().length), (start: number) => {
            ListItem() {
              Row({ space: this.libraryUnit(this.libWideCards ? 49 : 37) }) {
                ForEach(this.libraryGenres().slice(start, start + this.libraryColumns()), (genre: string) => {
                  this.libraryGenreCard(genre)
                }, (genre: string) => genre)
              }.width('100%').alignItems(VerticalAlign.Top)
                .padding({ left: this.libraryUnit(this.libWideCards ? 42 : 35), right: this.libraryUnit(this.libWideCards ? 42 : 35),
                  top: start === 0 ? this.libraryUnit(46) : 0, bottom: this.libraryUnit(35) })
            }
          }, (start: number) => 'genres-' + start.toString() + '-' + this.libraryColumns().toString())
        }
      } else if (this.libVisibleItems.length === 0) {
        ListItem() { this.libraryEmptyState() }
      } else {
        if (this.libHeroItems.length > 0) {
          ListItem() { this.libraryHero() }
            .padding({ top: this.libraryUnit(46), bottom: this.libraryUnit(58) })
        }
        ForEach(this.libraryRowStarts(this.libVisibleItems.length), (start: number) => {
          ListItem() {
            Row({ space: this.libraryUnit(this.libWideCards ? 49 : 37) }) {
              ForEach(this.libVisibleItems.slice(start, start + this.libraryColumns()), (item: MediaItem) => {
                this.libraryMediaCard(item)
              }, (item: MediaItem) => item.id)
            }.width('100%').alignItems(VerticalAlign.Top)
              .padding({ left: this.libraryUnit(this.libWideCards ? 42 : 35), right: this.libraryUnit(this.libWideCards ? 42 : 35),
                top: start === 0 && this.libHeroItems.length === 0 ? this.libraryUnit(46) : 0,
                bottom: this.libraryUnit(35) })
          }
        }, (start: number) => this.libMode.toString() + '-' + start.toString() + '-' + this.libraryColumns().toString())
      }
      ListItem() { Column().height(this.libraryUnit(70)) }
    }.width('100%').layoutWeight(1).cachedCount(2).scrollBar(BarState.Off)
  }

  @Builder
  libraryEmptyState() {
    Column({ space: this.libraryUnit(22) }) {
      SymbolGlyph(this.libraryTabSymbol(this.libMode)).fontSize(this.libraryUnit(52)).fontColor([this.P().textDim])
      Text(this.libraryEmptyText()).fontSize(this.libraryUnit(23)).fontColor(this.P().textDim)
        .textAlign(TextAlign.Center).maxLines(2)
    }.width('100%').height(this.libraryUnit(700)).justifyContent(FlexAlign.Center)
  }

  @Builder
  librarySortPopover() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column().width('100%').height('100%').onClick(() => { this.libSortOpen = false; })
      Column() {
        ForEach([0, 1, 2, 3, 4], (field: number) => {
          Row() {
            Text(this.librarySortLabels[field] + (this.libSort === field && field !== 4 ? (this.libDescending ? '  ↓' : '  ↑') : ''))
              .fontSize(this.libraryUnit(24)).fontColor(this.librarySortAvailable(field) ? this.P().text : this.P().textDim)
            Blank()
            if (!this.librarySortAvailable(field)) {
              Text('暂无日期').fontSize(this.libraryUnit(16)).fontColor(this.P().textDim)
            }
          }.width('100%').height(this.libraryUnit(94))
            .padding({ left: this.libraryUnit(29), right: this.libraryUnit(29) })
            .opacity(this.librarySortAvailable(field) ? 1 : 0.45)
            .onClick(() => { this.chooseLibrarySort(field); })
          if (field < 4) {
            Divider().color(withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.12))
              .width(this.libraryUnit(314))
          }
        }, (field: number) => field.toString())
      }.width(this.libraryUnit(374)).padding({ top: this.libraryUnit(6), bottom: this.libraryUnit(6) })
        .borderRadius(this.libraryUnit(45))
        .border({ width: 0.8, color: withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.30) })
        .systemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK, interactive: true }))
        .position({ x: this.libraryWidth() - this.libraryUnit(404), y: this.libraryUnit(197) })
    }.width('100%').height('100%').zIndex(30)
  }

  @Builder
  searchView() {
    Column() {
      // 搜索输入（返回按钮由 HdsNavDestination 标题栏提供）
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(16)
            .fontColor([this.P().textDim])
            .margin({ right: 8 })
          TextInput({ text: $$this.searchQuery, placeholder: '搜索影片、剧集、演员' })
            .fontSize(15)
            .fontColor(this.P().text)
            .placeholderColor(this.P().textDim)
            .backgroundColor('#00000000')
            .layoutWeight(1)
            .height(40)
            .enterKeyType(EnterKeyType.Search)
            .onSubmit(() => {
              this.doSearch();
            })
        }
        .layoutWeight(1)
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.P().chip)
        .borderRadius(20)
        .margin({ left: 10 })

        Text('搜索')
          .fontSize(14)
          .fontColor(this.P().accent)
          .margin({ left: 12 })
          .onClick(() => {
            this.doSearch();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 110, bottom: 10 })

      // 结果
      if (this.searching) {
        Column() {
          LoadingProgress().width(36).height(36).color(this.P().accent)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.searchResults.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(48)
            .fontColor([this.P().textFaint])
            .opacity(0.5)
          Text(this.searchQuery.length > 0 ? '没找到相关影片' : '输入关键字开始搜索')
            .fontSize(14)
            .fontColor(this.P().textDim)
            .margin({ top: 14 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Text('找到 ' + this.searchResults.length.toString() + ' 个结果')
          .fontSize(12)
          .fontColor(this.P().textDim)
          .width('100%')
          .padding({ left: 20, bottom: 8 })

        Grid() {
          ForEach(this.searchResults, (item: MediaItem) => {
            GridItem() {
              Column() {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  if (item.hasPrimaryImage) {
                    NetImage({ url: MediaServices.imageUrl(this.current as ServerConfig, item.id, 360, item.imageTag), headers: this.imageHeadersOrEmpty() })
                      .width('100%')
                      .height('100%')
                  } else {
                    Column()
                      .width('100%')
                      .height('100%')
                      .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.06) : withAlpha('#000000', 0.05))
                  }
                  if (item.rating > 0) {
                    Text(item.rating.toFixed(1))
                      .fontSize(10)
                      .fontColor(this.P().star)
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .backgroundColor(withAlpha('#000000', 0.62))
                      .borderRadius(4)
                      .margin({ right: 5, bottom: 5 })
                  }
                }
                .width('100%')
                .aspectRatio(0.667)
                .borderRadius(12)
                .clip(true)

                Text(item.name)
                  .fontSize(12)
                  .fontColor(this.P().text)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 6 })
                  .width('100%')
                if (item.year > 0) {
                  Text(item.year.toString())
                    .fontSize(10)
                    .fontColor(this.P().textDim)
                    .margin({ top: 2 })
                    .width('100%')
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .focusable(true)
              .clickEffect(MotionFx.press())
              .onClick(() => {
                if (item.isPlayable()) {
                  this.playItem(item);
                } else {
                  this.popNamed('search');
                  this.openDetail(item);
                }
              })
            }
          }, (item: MediaItem) => item.id)
        }
        .columnsTemplate(this.gridTemplate())
        .columnsGap(9)
        .rowsGap(16)
        .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
        .layoutWeight(1)
      }

      Column().height(30)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.P().bg)
  }

  /** 媒体库 2×2 拼贴卡片 */
  @Builder
  mediaCollage(row: LibRow) {
    Column() {
      // 2×2 拼贴
      Column() {
        Row() {
          this.collageCell(row, 0)
          this.collageCell(row, 1)
        }
        Row() {
          this.collageCell(row, 2)
          this.collageCell(row, 3)
        }
      }
      .width(this.resumeCardWidth())
      .height(this.resumeCardHeight())
      .borderRadius(Radius.card)
      .clip(true)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .border({
        width: 0.6,
        color: withAlpha('#FFFFFF', 0.24),
        radius: Radius.card
      })
      .backgroundColor(this.darkMode() ? withAlpha('#FFFFFF', 0.06) : withAlpha('#000000', 0.05))

      Text(row.lib.name)
        .fontSize(Metrics.f(10))
        .lineHeight(15)
        .fontColor(this.P().text)
        .maxLines(1)
        .margin({ top: 6 })
        .width(this.resumeCardWidth())
    }
    .margin({ right: 13 })
    .focusable(true)
    .onHover((isHover: boolean) => {})
    .onClick(() => {
      const s = this.current;
      if (s !== null) {
        this.openLibrary(s, row.lib);
      }
    })
  }

  @Builder
  collageCell(row: LibRow, idx: number) {
    Stack() {
      if (idx < row.items.length && this.isDemo(row.items[idx])) {
        Image(this.demoImage(row.items[idx]))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else if (idx < row.items.length && row.items[idx].hasPrimaryImage) {
        NetImage({ url: MediaServices.imageUrl(this.current as ServerConfig, row.items[idx].id, 200, row.items[idx].imageTag), headers: this.imageHeadersOrEmpty() })
          .width('100%')
          .height('100%')
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.darkMode() ? withAlpha('#FFFFFF', 0.04) : withAlpha('#000000', 0.03))
      }
    }
    .width(this.resumeCardWidth() / 2)
    .height(this.resumeCardHeight() / 2)
  }

  @Builder
  sectionHeader(title: string, count: string, libId: string) {
    Row() {
      Text(title)
        .fontSize(Metrics.f(16))
        .lineHeight(21)
        .fontColor(this.P().text)
        .fontWeight(FontWeight.Medium)
      Blank()
      if (count.length > 0) {
        Text(count)
          .fontSize(Metrics.f(9))
          .lineHeight(14)
          .fontColor(this.P().textDim)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.darkMode() ? withAlpha('#FFFFFF', 0.08) : withAlpha('#000000', 0.05))
          .borderRadius(12)
          .focusable(libId.length > 0)
          .onClick(() => {
            if (libId.length > 0) {
              const sv = this.current;
              if (sv !== null) {
                for (let i = 0; i < this.libs.length; i++) {
                  if (this.libs[i].id === libId) {
                    this.openLibrary(sv, this.libs[i]);
                    break;
                  }
                }
              }
            }
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Metrics.s(16), bottom: 2 })
  }

  /** 继续观看卡宽：16:9 横版小卡，clamp(W*0.44, 156, 200) */
  private resumeCardWidth(): number {
    const w = Metrics.width();
    const base = w > 0 ? w : 440;
    return Math.max(156, Math.min(200, base * 0.44));
  }

  /**
   * 海报卡宽（R12，方案 §4/§6.2）：约 .227W，一屏约 4 张。
   * 461.1vp 窗口 → 105vp（旧实现固定 118，把「约 4 张」挤成 3 张多）。
   */
  private posterWidth(): number {
    const w = Metrics.width() > 0 ? Metrics.width() : 440;
    return Math.round(Math.max(86, Math.min(132, w * 0.227)));
  }

  /**
   * 继续播放卡的配图来源。
   *
   * ★ 关键：飞牛只有「tag == itemId」的条目才能取到图。
   *   剧集（Episode）返回的 ImageTags.Primary 是个独立哈希值，
   *   拿它拼 URL 一律 400；而所属剧（Series）的 tag 恰好等于它自己的 id，
   *   所以用 seriesId 同时当 itemId 和 tag 一定取得到。
   *
   * 实测：
   *   /Items/{seriesId}/Images/Primary?tag={seriesId} → 200 image/webp
   *   /Items/{episodeId}/Images/Primary?tag={剧集tag} → 400
   *
   * 顺带这也更符合「继续观看」的惯例：显示剧的海报而不是某一集的缩略图。
   */
  private resumeImageUrl(item: MediaItem): string {
    const sv = this.current;
    if (sv === null) {
      return '';
    }
    if (item.seriesId.length > 0) {
      return MediaServices.imageUrl(sv, item.seriesId, 480, item.seriesId);
    }
    if (item.imageTag.length > 0) {
      return MediaServices.imageUrl(sv, item.id, 480, item.imageTag);
    }
    return '';
  }

  /** 16:9 高度 */
  private resumeCardHeight(): number {
    return Math.round(this.resumeCardWidth() * 9 / 16);
  }

  /** 剩余时长文案 */
  private remainingText(item: MediaItem): string {
    const total = item.runtimeTicks / 10000;
    const pos = item.progressTicks / 10000;
    if (total <= 0) {
      return '继续播放';
    }
    const left = Math.max(0, total - pos);
    const m = Math.round(left / 60000);
    if (m < 1) {
      return '不足 1 分钟';
    }
    if (m >= 60) {
      return '剩余 ' + Math.floor(m / 60).toString() + ' 小时 ' + (m % 60).toString() + ' 分';
    }
    return '剩余 ' + m.toString() + ' 分钟';
  }

  /**
   * 继续观看卡：16:9 横版小卡（R12，方案 §6.1）
   *
   * ★ 与旧实现的差别（都是用户可见的）：
   *   1. 图上不再有压图标题、也不再是「整幅贴底 3vp 进度条」；
   *      改为图内左下：播放三角 + 短进度线 + 已播时间。
   *   2. 标题移到图下第一行，右侧省略号菜单（标记已看 / 移除续播 / 详情）。
   *   3. 第二行显示集数或剧集名。
   *
   * ★ 交互：点卡片 = 播放；点省略号 = 只开菜单（菜单命令走 ProgressRepository，
   *   成功后从续播列表移除，不是只改外观）。
   */
  @Builder
  resumeCard(item: MediaItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.isDemo(item)) {
          Image(this.demoImage(item))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else if (this.resumeImageUrl(item).length > 0) {
          NetImage({
            url: this.resumeImageUrl(item),
            headers: this.imageHeadersOrEmpty(),
            targetWidth: 480,
            darkMode: this.dark(),
            placeholderColor: withAlpha(this.P().accent, this.dark() ? 0.14 : 0.10)
          })
            .width('100%')
            .height('100%')
            // ★ 渐变模糊（官方 linearGradientBlur）：按「位置」给模糊比例，
            //   位置 0–68% 清晰、68%→84% 渐糊、底部 100% 最糊。
            //   之前用 backdropBlur 是矩形硬边，叠几层都有一条分界；
            //   这个是渐变过渡，才是参考图那种「自然从清晰糊下去」。
            .linearGradientBlur(22, {
              fractionStops: [[0.0, 0.0], [0.02, 0.68], [0.55, 0.84], [1.0, 1.0]],
              direction: GradientDirection.Bottom
            })
        } else {
          // 无图：中性底色即可 —— 左下角已经有播放三角，
          // 这里再画一个 play_circle 会看成「两个播放按钮」。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.06)
              : withAlpha('#000000', 0.05))
        }

        // ★ 参考应用的续播卡底部是「一条磨砂带」，不是纯黑渐变：
        //   进度条/时间所在的那条区域是模糊的（能看到图被糊开），
        //   上方再接一段很轻的渐变过渡，避免出现硬边。
        // ★ 渐变模糊：ArkUI 的 backdropBlur 边界天生是硬的，一层做不出过渡。
        //   这里叠三层不同高度的模糊条（越高越糊、越淡），肉眼上形成「从下往上
        //   模糊逐渐消失」的过渡，避免在模糊带顶部留一条水平硬线。
        // ★ 取舍说明：backdropBlur 的边界永远是矩形硬边，叠几层都不会更柔和
        //   （实测 3 层、5 层都仍能看到一条分界）。要「自然过渡」只能二选一：
        //     A. 平滑渐变（无模糊）—— 天然没有硬边，当前采用
        //     B. 图片模糊副本 + 渐变遮罩（DST_IN）—— 能同时有模糊和过渡，
        //        但要为这张卡再画一次模糊副本，成本明显更高
        //   这里先用 A，参数按参考图的比例（约卡片高度的 40%）。
        Column()
          .width('100%')
          .height('30%')
          .linearGradient({
            angle: 180,
            colors: [
              [withAlpha('#000000', 0.00), 0.00],
              [withAlpha('#000000', 0.03), 0.40],
              [withAlpha('#000000', 0.09), 1.00]
            ]
          })
          .hitTestBehavior(HitTestMode.None)

        // ── 图内左下：播放三角 + 短进度线 + 已播时间 ──
        Row() {
          Stack() {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(9)
              .fontColor(['#FFFFFF'])
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(withAlpha('#000000', 0.46))
          .hitTestBehavior(HitTestMode.None)

          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width(this.resumeBarWidth())
              .height(2.5)
              .borderRadius(2)
              .backgroundColor(withAlpha('#FFFFFF', 0.34))
            Row()
              .width(this.resumeBarWidth() * this.clamp01(item.progressRatio()))
              .height(2.5)
              .borderRadius(2)
              .backgroundColor('#FFFFFF')
          }
          .width(this.resumeBarWidth())
          .height(2.5)
          .margin({ left: 8 })
          .hitTestBehavior(HitTestMode.None)

          Text(this.clockText(item.progressTicks / 10000))
            .fontSize(9)
            .fontColor(withAlpha('#FFFFFF', 0.92))
            .margin({ left: 7 })
            .hitTestBehavior(HitTestMode.None)
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 9, right: 9, bottom: 8 })
        .hitTestBehavior(HitTestMode.None)
      }
      .width(this.resumeCardWidth())
      .height(this.resumeCardHeight())
      .borderRadius(10)
      .clip(true)
      .backgroundColor(this.P().card)

      // ── 图下第一行：标题 + 省略号菜单 ──
      Row() {
        Text(item.seriesName.length > 0 ? item.seriesName : item.name)
          .fontSize(10)
          .lineHeight(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.P().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text('⋯')
          .fontSize(16)
          .fontColor(this.P().textDim)
          .padding({ left: 8, right: 2, top: 0, bottom: 4 })
          .focusable(true)
          .onClick(() => {
            // 只开菜单：这里不绑点击播放，避免误触进播放器
          })
          .bindMenu(this.resumeMenu(item), {
            systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent)
          })
      }
      .width(this.resumeCardWidth())
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      // ── 图下第二行：集数 / 剧集名 ──
      Text(this.resumeSubLine(item))
        .fontSize(8)
        .lineHeight(12)
        .fontColor(this.P().textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.resumeCardWidth())
        .margin({ top: 3 })
        .textAlign(TextAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ right: 13 })
    .focusable(true)
    .clickEffect(MotionFx.pressSoft())
    .onClick(() => {
      this.playItem(item);
    })
  }

  /**
   * 续播卡省略号菜单（业务命令，不是只改外观）。
   * ★ 不用 Menu/MenuItem：那套是系统主题的浅色面板，深色应用里会闪一块白底。
   *   自绘三行，颜色跟着当前主题走。
   */
  @Builder
  resumeMenu(item: MediaItem) {
    Column() {
      Row() {
        Text('标记已看')
          .fontSize(14)
          .fontColor(this.P().text)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .focusable(true)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        this.markResumeWatched(item);
      })

      Row() {
        Text('移除续播')
          .fontSize(14)
          .fontColor(this.P().text)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .focusable(true)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        this.removeResume(item);
      })

      Row() {
        Text('详情')
          .fontSize(14)
          .fontColor(this.P().text)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .focusable(true)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        this.openDetail(item);
      })
    }
    .width(178)
    .padding({ top: 5, bottom: 5 })
    .borderRadius(14)
    .backgroundColor(this.dark() ? '#22232A' : '#FFFFFF')
    .border({
      width: 0.5,
      color: this.dark() ? withAlpha('#FFFFFF', 0.14) : withAlpha('#000000', 0.08)
    })
  }

  /** 标记已看：写业务层（本地 V2 进度）→ 从续播列表移除 */
  private async markResumeWatched(item: MediaItem): Promise<void> {
    const sv = this.current;
    if (sv === null) {
      return;
    }
    try {
      await ProgressRepository.markComplete(sv.id, sv.userId, item.id);
      this.dropResume(item.id);
      hilog.info(0x0001, 'NasPlay', 'RESUME mark-watched id=%{public}s ok', item.id);
    } catch (e) {
      hilog.info(0x0001, 'NasPlay', 'RESUME mark-watched id=%{public}s failed', item.id);
      promptAction.showToast({ message: '操作失败' });
    }
  }

  /** 移除续播：删业务层记录 → 从续播列表移除 */
  private async removeResume(item: MediaItem): Promise<void> {
    const sv = this.current;
    if (sv === null) {
      return;
    }
    try {
      await ProgressRepository.remove(sv.id, sv.userId, item.id);
      this.dropResume(item.id);
      hilog.info(0x0001, 'NasPlay', 'RESUME removed id=%{public}s ok', item.id);
    } catch (e) {
      hilog.info(0x0001, 'NasPlay', 'RESUME removed id=%{public}s failed', item.id);
      promptAction.showToast({ message: '操作失败' });
    }
  }

  private dropResume(id: string): void {
    const keep: MediaItem[] = [];
    for (let i = 0; i < this.resumeItems.length; i++) {
      if (this.resumeItems[i].id !== id) {
        keep.push(this.resumeItems[i]);
      }
    }
    this.resumeItems = keep;
  }

  private clamp01(v: number): number {
    if (isNaN(v) || v <= 0) {
      return 0;
    }
    return v >= 1 ? 1 : v;
  }

  /** 图上短进度线宽度：约卡片宽的 28%，clamp 40–58vp */
  private resumeBarWidth(): number {
    const w = this.resumeCardWidth() * 0.28;
    return Math.round(Math.max(40, Math.min(58, w)));
  }

  /** 毫秒 → mm:ss / h:mm:ss；时长未知就不伪造数字 */
  private clockText(ms: number): string {
    if (ms <= 0 || isNaN(ms)) {
      return '--:--';
    }
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (v: number): string => v < 10 ? '0' + v.toString() : v.toString();
    if (h > 0) {
      return h.toString() + ':' + pad(m) + ':' + pad(s);
    }
    return pad(m) + ':' + pad(s);
  }

  /** 卡片第二行：集数 + 剧集名（有哪个显示哪个，都空就显示剩余时长） */
  private resumeSubLine(item: MediaItem): string {
    const ep = this.episodeLabel(item);
    const parts: string[] = [];
    if (ep.length > 0) {
      parts.push(ep);
    }
    if (item.seriesName.length > 0 && item.name.length > 0
      && item.name !== item.seriesName) {
      parts.push(item.name);
    }
    if (parts.length === 0) {
      return this.remainingText(item);
    }
    return parts.join('  ·  ');
  }

  episodeLabel(item: MediaItem): string {
    let s = '';
    if (item.parentIndexNumber > 0) {
      s = 'S' + item.parentIndexNumber.toString().padStart(2, '0');
    }
    if (item.indexNumber > 0) {
      s = s + 'E' + item.indexNumber.toString().padStart(2, '0');
    }
    if (s.length === 0 && item.year > 0) {
      s = item.year.toString();
    }
    return s;
  }

  /* ── 详情页 ── */
  private detailArtworkUrl(): string {
    if (this.current === null || this.detailItem === null) { return ''; }
    const item = this.detail !== null && this.detail.item.id === this.detailItem.id
      ? this.detail.item : this.detailItem;
    return MediaServices.backdropUrl(this.current, item.id, 1080, item.backdropTag, item.imageTag);
  }

  private detailArtworkHeight(): number {
    return HeroArtwork.imageHeight(Metrics.width(), this.detailArtworkRatio);
  }

  private detailDisplayHeight(): number {
    return this.detailArtworkHeight() + this.detailArtworkPull;
  }

  private detailArtworkWidth(): number {
    return HeroArtwork.imageWidth(Metrics.width(), this.detailArtworkRatio, this.detailArtworkPull);
  }

  private detailArtworkScope(): string {
    return this.current === null || this.detailItem === null ? ''
      : this.current.id + ':' + this.current.userId + ':' + this.detailItem.id;
  }

  private onDetailArtworkSize(url: string, scope: string, width: number, height: number): void {
    if (!this.detailPullAllowed() || url !== this.detailArtworkUrl() || scope !== this.detailArtworkScope()
      || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) { return; }
    // Cache hits may report synchronously from a component visibility/layout callback.
    // Queue only ordinary fields here; the decoded aspect is committed after that render turn.
    this.pendingDetailArtworkRatio = width / height;
    this.pendingDetailArtworkUrl = url;
    this.pendingDetailArtworkScope = scope;
    if (this.detailArtworkSizeTask >= 0) { return; }
    const generation = this.detailPullGeneration;
    this.detailArtworkSizeTask = setTimeout(() => {
      if (generation !== this.detailPullGeneration) { return; }
      this.detailArtworkSizeTask = -1;
      // The same frame can decode a newer URL; validate the latest pending identity, not the timer's first URL.
      if (!this.detailPullAllowed() || this.pendingDetailArtworkUrl !== this.detailArtworkUrl()
        || this.pendingDetailArtworkScope !== this.detailArtworkScope()) { return; }
      const ratio = this.pendingDetailArtworkRatio;
      if (Math.abs(ratio - this.detailArtworkRatio) > 0.002) { this.detailArtworkRatio = ratio; }
    }, MotionSpec.imageReadyFrame);
  }

  @Builder
  detailHeroArtwork(url: string, scope: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (url.length > 0) {
        NetImage({ url: url, headers: this.imageHeadersOrEmpty(),
          targetWidth: 1080, fit: ImageFit.Contain,
          onImageSize: (width: number, height: number) => {
            this.onDetailArtworkSize(url, scope, width, height);
          } })
          .width(this.detailArtworkWidth()).height(this.detailDisplayHeight())
          .position({ x: (Metrics.width() - this.detailArtworkWidth()) / 2, y: 0 })
      }
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: this.detailArtworkFeatherStops() })
        .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
        .hitTestBehavior(HitTestMode.None)
    }.width('100%').height(this.detailDisplayHeight()).clip(true)
      .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None)
  }

  private detailBackdropScope(): string {
    return this.current === null ? '' : this.current.id + ':' + this.current.userId;
  }

  private detailArtworkFeatherStops(): Array<[string, number]> {
    return [[withAlpha('#000000', 1), 0], [withAlpha('#000000', 1), 0.72],
      [withAlpha('#000000', 0.90), 0.82], [withAlpha('#000000', 0.46), 0.94],
      [withAlpha('#000000', 0), 1]];
  }

  private detailBackdropVeilStops(): Array<[string, number]> {
    const color = this.dark() ? '#000000' : '#FFFFFF';
    const alpha = this.dark() ? [0.04, 0.10, 0.20, 0.28] : [0.06, 0.12, 0.20, 0.28];
    return [[withAlpha(color, alpha[0]), 0], [withAlpha(color, alpha[1]), 0.28],
      [withAlpha(color, alpha[2]), 0.65], [withAlpha(color, alpha[3]), 1]];
  }

  @Builder
  detailBackdrop() {
    LibraryBackdrop({ url: this.detailArtworkUrl(), headers: this.imageHeadersOrEmpty(),
      scopeId: this.detailBackdropScope(), fallbackColor: this.P().bg, baseColor: this.P().bg,
      darkMode: this.dark(), blurRadius: 42,
      imageStrength: this.dark() ? 0.94 : 0.82, baseVeilStrength: this.dark() ? 0.12 : 0.18 })
      .width('100%').height('100%')
    Column().width('100%').height('100%')
      .linearGradient({ angle: 180, colors: this.detailBackdropVeilStops() })
      .hitTestBehavior(HitTestMode.None)
  }

  private async toggleDetailWatchLater(): Promise<void> {
    const server = this.current, item = this.detailItem;
    if (server === null || item === null || !(await this.serverGate(server))) { return; }
    const generation = this.detailRequestGeneration, scope = SourceIdentity.scope(server);
    try {
      const enabled = await VisionStore.toggleWatchLater(server, item);
      if (this.detailRequestCurrent(generation, scope, item.id)) { this.detailWatchLater = enabled; }
      this.visionRevision++;
      promptAction.showToast({ message: enabled ? '已加入待看' : '已移出待看' });
    } catch (error) { promptAction.showToast({ message: '待看保存失败，请重试' }); }
  }

  @Builder
  detailView() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Decoded, gently changing atmospheric image remains visible beneath the full page.
      this.detailBackdrop()

      Scroll(this.detailScroller) {
        Column() {
          // Complete foreground artwork is independent of the tall atmospheric background.
          Stack({ alignContent: Alignment.TopStart }) {
            this.detailHeroArtwork(this.detailArtworkUrl(), this.detailArtworkScope())
          // ══════ 顶部按钮行 ══════
          Row() {
            Blank()

            // 收藏
            Row() {
              SymbolGlyph($r('sys.symbol.bookmark'))
                .fontSize(18)
                .fontColor([this.detailWatchLater ? this.P().accent : this.P().text])
            }
            .width(40)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .backdropBlur(20)
            .backgroundColor(this.dark() ? withAlpha('#000000', 0.35) : withAlpha('#FFFFFF', 0.55))
            .borderRadius(20)
            .margin({ left: 8 })
            .onClick(() => { this.toggleDetailWatchLater(); })

            // 更多
            Row() {
              SymbolGlyph($r('sys.symbol.ellipsis_circle'))
                .fontSize(18)
                .fontColor([this.P().text])
            }
            .width(40)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .backdropBlur(20)
            .backgroundColor(this.dark() ? withAlpha('#000000', 0.35) : withAlpha('#FFFFFF', 0.55))
            .borderRadius(20)
            .margin({ left: 8 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.safeTopVp + 62 })
          }.width('100%').height(this.detailDisplayHeight())

          // ══════ 标题（居中）══════
          Text(this.detailItem !== null ? this.detailItem.name : '')
            .fontSize(24)
            .fontColor(this.dark() ? C.white : '#1A1A1A')
            .fontWeight(FontWeight.Bold)
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: 32, right: 32 })
            .margin({ top: 14 })

          // 元信息
          Text(this.detailMeta())
            .fontSize(12)
            .fontColor(this.dark() ? '#D0D0D7' : '#55555D')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 8 })

          // ══════ 按钮行（居中）══════
          Row() {
            // 大胶囊：继续播放 + 进度
            Row() {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(16)
                .fontColor([this.dark() ? C.white : '#FFFFFF'])
                .margin({ right: 8 })
              Text(this.detailPlayLabel())
                .fontSize(15)
                .fontColor(this.dark() ? C.white : '#FFFFFF')
                .fontWeight(FontWeight.Medium)
              if (this.detailProgressLabel().length > 0) {
                Text(this.detailProgressLabel())
                  .fontSize(12)
                  .fontColor(withAlpha('#FFFFFF', 0.7))
                  .margin({ left: 8 })
              }
            }
            .height(48)
            .padding({ left: 26, right: 26 })
            .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .backgroundColor(withAlpha(this.P().accent, 0.72))
            .border({
              width: 0.8,
              color: withAlpha('#FFFFFF', 0.32),
              radius: 24
            })
            .shadow({
              radius: 18,
              color: withAlpha(this.P().accent, 0.35),
              offsetX: 0,
              offsetY: 6
            })
            .borderRadius(24)
            .focusable(true)
            .clickEffect(MotionFx.press())
            .onClick(() => {
              if (this.detailItem !== null) {
                if (this.detailItem.isPlayable()) {
                  this.playItem(this.detailItem);
                } else if (this.episodes.length > 0) {
                  this.playItem(this.episodes[0]);
                }
              }
            })

            // 三个圆钮：重播 / 标记已看 / 收藏
            Row() {
              SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
                .fontSize(18)
                .fontColor([this.P().text])
            }
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .backgroundColor(withAlpha('#FFFFFF', 0.10))
            .border({
              width: 0.7,
              color: this.dark() ? withAlpha('#FFFFFF', 0.16) : withAlpha('#FFFFFF', 0.85),
              radius: 24
            })
            .borderRadius(24)
            .margin({ left: 10 })
            .focusable(true)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.replayFromStart();
            })

            Row() {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([this.P().text])
            }
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .backgroundColor(withAlpha('#FFFFFF', 0.10))
            .border({
              width: 0.7,
              color: this.dark() ? withAlpha('#FFFFFF', 0.16) : withAlpha('#FFFFFF', 0.85),
              radius: 24
            })
            .borderRadius(24)
            .margin({ left: 10 })
            .focusable(true)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.markCurrentWatched();
            })

            Row() {
              SymbolGlyph($r('sys.symbol.heart'))
                .fontSize(18)
                .fontColor([this.P().text])
            }
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .backgroundColor(withAlpha('#FFFFFF', 0.10))
            .border({
              width: 0.7,
              color: this.dark() ? withAlpha('#FFFFFF', 0.16) : withAlpha('#FFFFFF', 0.85),
              radius: 24
            })
            .borderRadius(24)
            .margin({ left: 10 })
            .focusable(true)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.toggleCurrentFavorite();
            })

            // ★ 下载按钮：startDownload 此前定义了却没有任何 UI 入口，
            //   下载功能对用户完全不可达（T20）
            Row() {
              SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                .fontSize(18)
                .fontColor([this.P().text])
            }
            .width(48)
            .height(48)
            .justifyContent(FlexAlign.Center)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: this.dark() ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .backgroundColor(withAlpha('#FFFFFF', 0.10))
            .border({
              width: 0.7,
              color: this.dark() ? withAlpha('#FFFFFF', 0.16) : withAlpha('#FFFFFF', 0.85),
              radius: 24
            })
            .borderRadius(24)
            .margin({ left: 10 })
            .focusable(true)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.downloadCurrent();
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 18 })

          // ══════ 技术信息行 ══════
          if (this.detailTechInfo().length > 0) {
            Text(this.detailTechInfo())
              .fontSize(12)
              .fontColor(this.dark() ? C.dim : '#6B6B70')
              .textAlign(TextAlign.Center)
              .width('100%')
              .margin({ top: 16 })
          }

          // ══════ 简介（居中 3 行）══════
          if (this.detailItem !== null && this.detailItem.overview.length > 0) {
            Text(this.detailItem.overview)
              .fontSize(13)
              .fontColor(this.dark() ? '#D4D4DA' : '#414149')
              .lineHeight(20)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ left: 24, right: 24 })
              .margin({ top: 14 })
          }

          // ══════ 评分行 ══════
          if (this.detailItem !== null && this.detailItem.rating > 0) {
            Row() {
              SymbolGlyph($r('sys.symbol.star_fill'))
                .fontSize(12)
                .fontColor([this.P().star])
                .margin({ right: 4 })
              Text(this.detailItem.rating.toFixed(1))
                .fontSize(13)
                .fontColor(this.P().star)
                .fontWeight(FontWeight.Medium)
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .margin({ top: 12 })
          }

          // ══════ 季选择 ══════
          if (this.seasons.length > 0) {
            Row() {
              Text('第 1 季')
                .fontSize(17)
                .fontColor(this.P().text)
                .fontWeight(FontWeight.Bold)
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(14)
                .fontColor([this.P().text])
                .margin({ left: 6 })

              Blank()

              // 视图切换图标
              SymbolGlyph($r('sys.symbol.calendar'))
                .fontSize(18)
                .fontColor([this.P().textDim])
                .margin({ right: 14 })
              SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                .fontSize(18)
                .fontColor([this.P().textDim])
                .margin({ right: 14 })
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(18)
                .fontColor([this.P().textDim])
            }
            .width('100%')
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            .margin({ top: 26 })
          }

          // ══════ 剧集分组胶囊 ══════
          if (this.episodes.length > 0) {
            Row() {
              ForEach(this.episodeGroups(), (g: string, gi: number) => {
                Text(g)
                  .fontSize(12)
                  .fontColor(gi === this.epGroupIndex ? C.white : this.P().textDim)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .backgroundColor(gi === this.epGroupIndex ? this.P().accent : (this.dark() ? withAlpha('#FFFFFF', 0.08) : withAlpha('#000000', 0.05)))
                  .borderRadius(16)
                  .margin({ right: 8 })
                  .onClick(() => {
                    this.epGroupIndex = gi;
                  })
              }, (g: string) => g)
            }
            .width('100%')
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            .margin({ top: 12 })
          }

          // ══════ 剧集卡片（3 列横排）══════
          Scroll() {
            Row() {
              ForEach(this.visibleEpisodes(), (ep: MediaItem) => {
                Column() {
                  // 16:9 缩略图
                  Stack({ alignContent: Alignment.BottomStart }) {
                    if (ep.hasPrimaryImage) {
                      NetImage({ url: MediaServices.imageUrl(this.current as ServerConfig, ep.id, 480, ep.imageTag), headers: this.imageHeadersOrEmpty() })
                        .width('100%')
                        .height('100%')
                    } else {
                      Column()
                        .width('100%')
                        .height('100%')
                        .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.08) : withAlpha('#000000', 0.06))
                    }
                    // 播放图标
                    Row() {
                      SymbolGlyph($r('sys.symbol.play_fill'))
                        .fontSize(16)
                        .fontColor([withAlpha('#FFFFFF', 0.95)])
                    }
                    .margin({ left: 10, bottom: 10 })

                    // 进度条
                    if (ep.progressRatio() > 0.005) {
                      Stack({ alignContent: Alignment.Start }) {
                        Row()
                          .width('100%')
                          .height(3)
                          .backgroundColor(withAlpha('#FFFFFF', 0.25))
                        Row()
                          .width((ep.progressRatio() * 100).toFixed(1) + '%')
                          .height(3)
                          .backgroundColor(C.white)
                      }
                      .width('100%')
                      .height(3)
                    }
                  }
                  .width('100%')
                  .aspectRatio(16 / 9)
                  .borderRadius(12)
                  .clip(true)
                  .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.06) : withAlpha('#000000', 0.05))

                  // 年份
                  if (ep.year > 0) {
                    Text(ep.year.toString())
                      .fontSize(11)
                      .fontColor(this.P().textDim)
                      .margin({ top: 8 })
                  }
                  // S01E01
                  Text(this.episodeCode(ep))
                    .fontSize(11)
                    .fontColor(this.P().textDim)
                    .margin({ top: 2 })
                  // 标题
                  Text(ep.name)
                    .fontSize(14)
                    .fontColor(this.P().text)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                  // 简介
                  if (ep.overview.length > 0) {
                    Text(ep.overview)
                      .fontSize(11)
                      .fontColor(this.P().textDim)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 4 })
                  }
                }
                .width(300)
                .justifyContent(FlexAlign.Start)
                .alignItems(HorizontalAlign.Start)
                .margin({ right: 12 })
                .focusable(true)
                .clickEffect(MotionFx.press())
                .onClick(() => {
                  this.playItem(ep);
                })
              }, (ep: MediaItem) => ep.id)
            }
            // Metadata height varies by episode; align card tops instead of centering the shorter card.
            .alignItems(VerticalAlign.Top)
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .margin({ top: 12 })

          // ══════ 相册 ══════
          if (this.detailItem !== null && this.detailItem.hasPrimaryImage) {
            Row() {
              Text('相册')
                .fontSize(Metrics.f(17))
                .fontColor(this.P().text)
                .fontWeight(FontWeight.Bold)
              Text(' 2')
                .fontSize(Metrics.f(12))
                .fontColor(this.P().textDim)
            }
            .width('100%')
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            .margin({ top: 24, bottom: 10 })

            Scroll() {
              Row() {
                // 背景图
                Stack({ alignContent: Alignment.TopStart }) {
                  NetImage({
                    url: MediaServices.backdropUrl(this.current as ServerConfig,
                      this.detailItem.id, 720,
                      this.detailItem.backdropTag, this.detailItem.imageTag),
                    headers: this.imageHeadersOrEmpty(),
                    darkMode: this.dark()
                  })
                    .width('100%')
                    .height('100%')
                  Text('背景')
                    .fontSize(Metrics.f(10))
                    .fontColor(withAlpha('#FFFFFF', 0.95))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(withAlpha('#000000', 0.45))
                    .borderRadius(4)
                    .margin({ left: 8, top: 8 })
                }
                .width(Metrics.s(240))
                .height(Metrics.s(135))
                .borderRadius(10)
                .clip(true)
                .margin({ right: 10 })

                // 封面
                Stack({ alignContent: Alignment.TopStart }) {
                  NetImage({
                    url: MediaServices.imageUrl(this.current as ServerConfig,
                      this.detailItem.id, 360, this.detailItem.imageTag),
                    headers: this.imageHeadersOrEmpty(),
                    darkMode: this.dark()
                  })
                    .width('100%')
                    .height('100%')
                  Text('封面')
                    .fontSize(Metrics.f(10))
                    .fontColor(withAlpha('#FFFFFF', 0.95))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(withAlpha('#000000', 0.45))
                    .borderRadius(4)
                    .margin({ left: 8, top: 8 })
                }
                .width(Metrics.s(90))
                .height(Metrics.s(135))
                .borderRadius(10)
                .clip(true)
              }
              .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            }
            .scrollable(ScrollDirection.Horizontal)
            .align(Alignment.TopStart)
            .scrollBar(BarState.Off)
            .width('100%')
          }

          // ══════ 类型 ══════
          if (this.detailItem !== null && this.detailItem.genres.length > 0) {
            Text('类型')
              .fontSize(Metrics.f(17))
              .fontColor(this.P().text)
              .fontWeight(FontWeight.Bold)
              .width('100%')
              .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
              .margin({ top: 24, bottom: 10 })

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.detailItem.genres, (g: string) => {
                Text(g)
                  .fontSize(Metrics.f(12))
                  .fontColor(this.P().text)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .backdropBlur(20)
                  .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.10) : withAlpha('#000000', 0.05))
                  .borderRadius(16)
                  .margin({ right: 8, bottom: 8 })
                  .focusable(true)
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              }, (g: string) => g)
            }
            .width('100%')
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
          }

          // ══════ 媒体信息 ══════
          if (this.detail !== null && this.detail.sources.length > 0) {
            Text('媒体信息')
              .fontSize(Metrics.f(17))
              .fontColor(this.P().text)
              .fontWeight(FontWeight.Bold)
              .width('100%')
              .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
              .margin({ top: 24, bottom: 10 })

            Row() {
              // 视频
              if (this.detail.sources[0].videoStream() !== undefined) {
                this.mediaInfoCard(true, this.detail.sources[0].videoStream()!)
              }
              // 音频
              if (this.detail.sources[0].audioStreams().length > 0) {
                Row().width(10)
                this.mediaInfoCard(false, this.detail.sources[0].audioStreams()[0])
              }
            }
            .width('100%')
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            .alignItems(VerticalAlign.Top)
          }

          // ══════ 文件路径 ══════
          if (this.detailItem !== null && this.detailItem.path.length > 0) {
            Text(this.detailItem.path)
              .fontSize(Metrics.f(9))
              .fontColor(this.P().textFaint)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
              .margin({ top: 16 })
          }
          // ══════ 演职员 ══════
          if (this.people.length > 0) {
            Row() {
              Text('团队')
                .fontSize(Metrics.f(17))
                .fontColor(this.P().text)
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')
            .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            .margin({ top: 22, bottom: 10 })

            Scroll() {
              Row() {
                ForEach(this.people, (ps: Person) => {
                  Column() {
                    if (ps.hasImage) {
                      NetImage({ url: MediaServices.personImageUrl(this.current as ServerConfig, ps.id, 200), headers: this.imageHeadersOrEmpty() })
                        .width(Metrics.s(72))
                        .height(Metrics.s(72))
                        .borderRadius(Metrics.s(72) / 2)
                    } else {
                      Row() {
                        Text(ps.name.length > 0 ? ps.name.substring(0, 1) : '?')
                          .fontSize(Metrics.f(22))
                          .fontColor(this.P().textDim)
                      }
                      .width(Metrics.s(72))
                      .height(Metrics.s(72))
                      .justifyContent(FlexAlign.Center)
                      .backgroundColor(this.darkMode() ? withAlpha('#FFFFFF', 0.08) : withAlpha('#000000', 0.06))
                      .borderRadius(Metrics.s(72) / 2)
                    }
                    Text(ps.name)
                      .fontSize(Metrics.f(12))
                      .fontColor(this.P().text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 6 })
                      .width(Metrics.s(84))
                      .textAlign(TextAlign.Center)
                    if (ps.role.length > 0) {
                      Text(ps.role)
                        .fontSize(Metrics.f(10))
                        .fontColor(this.P().textDim)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 2 })
                        .width(Metrics.s(84))
                        .textAlign(TextAlign.Center)
                    } else if (ps.type === 'Director') {
                      Text('导演')
                        .fontSize(Metrics.f(10))
                        .fontColor(this.P().textDim)
                        .margin({ top: 2 })
                    }
                  }
                  .alignItems(HorizontalAlign.Center)
                  .margin({ right: Metrics.s(12) })
                  .focusable(true)
                  .onHover((isHover: boolean) => {})
                }, (ps: Person) => ps.id + ps.name)
              }
              .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }

          Column().height(60)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .onDidScroll(() => { this.syncDetailPull(); })
      .onTouch((event: TouchEvent) => { this.onArtworkPullTouch(event, true); })

      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.P().bg)
  }

  /* ══════════ 详情页辅助 Builder ══════════ */

  /** 媒体信息卡片（视频 / 音频） */
  @Builder
  mediaInfoCard(isVideo: boolean, st: MediaStream) {
    Column() {
      // 标题行：图标 + 主标签
      Row() {
        SymbolGlyph(isVideo ? $r('sys.symbol.rectangle_on_rectangle') : $r('sys.symbol.music_note_circle'))
          .fontSize(Metrics.f(15))
          .fontColor([this.P().text])
          .margin({ right: 8 })
        Text(isVideo ? (st.qualityLabel().length > 0 ? st.qualityLabel() : '视频')
                     : (st.channelLabel().length > 0 ? st.channelLabel() : '音频'))
          .fontSize(Metrics.f(18))
          .fontColor(this.P().text)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .margin({ bottom: 12 })

      // 明细
      this.infoRow('编码', st.codecLabel())
      if (isVideo) {
        this.infoRow('分辨率', st.resolution())
        this.infoRow('帧率', st.frameRate > 0 ? Math.round(st.frameRate).toString() : '')
        this.infoRow('比特率', st.bitrateText())
        this.infoRow('动态范围', st.isHdr ? 'HDR' : (st.videoRange.length > 0 ? st.videoRange : 'SDR'))
        this.infoRow('配置', st.profile)
        this.infoRow('等级', st.level > 0 ? st.level.toString() : '')
        this.infoRow('长宽比', st.aspectRatio)
      } else {
        this.infoRow('布局', st.channelLayout)
        this.infoRow('声道', st.channels > 0 ? st.channels.toString() : '')
        this.infoRow('比特率', st.bitrateText())
        this.infoRow('采样率', st.sampleRate > 0 ? st.sampleRate.toString() + ' Hz' : '')
        this.infoRow('语言', st.language)
        this.infoRow('外部', st.isExternal ? '是' : '否')
        this.infoRow('默认', st.isDefault ? '是' : '否')
      }
    }
    .layoutWeight(1)
    .padding(16)
    .backdropBlur(30)
    .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.08) : withAlpha('#000000', 0.04))
    .borderRadius(16)
    .border({
      width: 0.5,
      color: this.dark() ? withAlpha('#FFFFFF', 0.12) : withAlpha('#000000', 0.08),
      radius: 16
    })
    .alignItems(HorizontalAlign.Start)
  }

  /** 媒体信息的一行：标签在左，值在右 */
  @Builder
  infoRow(label: string, value: string) {
    if (value.length > 0) {
      Row() {
        Text(label)
          .fontSize(Metrics.f(11))
          .fontColor(this.P().textDim)
        Blank()
        Text(value)
          .fontSize(Metrics.f(11))
          .fontColor(this.P().text)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
    }
  }
  /* ── 详情页辅助方法 ── */

  /** 页面底色 —— Hero 渐变和整页背景必须用同一个色，才不会出接缝 */
  /* ═════════ 单一页面底色 displaySurfaceColor ═════════
   * 方案 5.1 / 5.4：整页只有一个底色来源。
   * 页面背景、Hero 渐隐终点、信息区背景必须读取同一份状态，
   * 不允许分别给它们运行三个时间不同的颜色动画，也不叠加第二套渐隐。
   */

  /** 基础底色（无染色时） */
  /** current 为 null（示例模式）时给空串，避免强转后访问成员崩溃 */
  private tokenOrEmpty(): string {
    return this.current !== null ? this.current.token : '';
  }

  private authOrEmpty(): string {
    return this.current !== null ? this.current.authHeader() : '';
  }

  private imageHeadersOrEmpty(): Record<string, string> {
    return this.current !== null ? MediaServices.imageHeaders(this.current) : {};
  }

  private baseSurface(): string {
    return this.dark() ? '#0A0A0B' : '#F7F8FA';
  }

  /** 提取色 → '#rrggbb' */
  private dominantHex(): string {
    const v = this.ambientRgb;
    let h = (v & 0xFFFFFF).toString(16);
    while (h.length < 6) {
      h = '0' + h;
    }
    return '#' + h;
  }

  /**
   * mutedDominant：把提取色和它的灰度色按 0.35 混合，抑制过饱和。
   * 避免一张红海报把整页染成红色。
   */
  private mutedDominant(): string {
    const dom = this.dominantHex();
    const rgb = hexToRgb(dom);
    // BT.601 luma
    const g = Math.round(0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]);
    const gray = rgbToHex(g, g, g);
    return mix(dom, gray, 0.35);
  }

  /**
   * ★ 唯一页面底色。
   * 深色：mix('#0A0A0B', mutedDominant, 0.18)
   * 浅色：mix('#F7F8FA', mutedDominant, 0.035)
   * 取色失败：直接返回基础色，不制造第二套背景。
   */
  private surfaceColor(): string {
    const base = this.baseSurface();
    if (this.ambientRgb < 0) {
      return base;
    }
    return AmbientPalette.baseOf(this.ambientRgb, this.dark());
  }

  /** Hero 图片视口高度：clamp(窗口宽 vp, 340, 460) */
  /* ═════════ 窗口安全区 ═════════
   * 当前 EntryAbility 用 setWindowLayoutFullScreen(true) + setWindowSystemBarEnable([])
   * 关掉了系统栏，TYPE_SYSTEM 避让区恒为 0。
   * 所以同时读 TYPE_CUTOUT / TYPE_NAVIGATION_INDICATOR，取最大值；全为 0 时兜底。
   */
  @State private safeTopVp: number = 0;
  /** 服务器页：0 = 2 列网格，1 = 列表 */
  @State private serverViewMode: number = 0;
  @State private showAddMenu: boolean = false;
  @State private addTypeName: string = 'Emby';
  @State private serverSortAsc: boolean = true;
  @State private serverOrdering: boolean = false;
  @State private serverOrder: string[] = [];
  /** 当前被按下的工具按钮（-1 表示无）：驱动弹簧按压反馈 */
  @State private pressedBtn: number = -1;
  /** 添加菜单的弹出动画属性（用 animateTo + springMotion 驱动） */
  @State private menuA: number = 0;
  @State private menuS: number = 0.86;
  @State private menuX: number = 36;

  private addTypes: string[] = SourceProfiles.all().map((profile: SourceProfile): string => profile.name);
  @State private safeBottomVp: number = 0;

  /**
   * 状态栏图标明暗跟随主题。
   * 深色主题 → 白色图标；浅色主题 → 黑色图标。
   */
  /** 配置并启动 Hero 的官方双边流光（默认关闭，见 HERO_FLOW_LIGHT） */
  private setupHeroFlowLight(): void {
    if (!HERO_FLOW_LIGHT) {
      return;
    }
    try {
      const accent: string = this.P().accent;
      const first: hdsEffect.EdgeFlowLightParam = {
        startPos: 0.0,
        endPos: 0.5,
        color: withAlpha(accent, 0.30)
      };
      const second: hdsEffect.EdgeFlowLightParam = {
        startPos: 0.5,
        endPos: 1.0,
        color: withAlpha('#FFFFFF', 0.22)
      };
      const params: DualEdgeFlowLightWithMaskParam = {
        // 不加背景遮罩，只在图上扫一层光
        backgroundMaskColors: ['#00000000', '#00000000'],
        firstEdgeFlowLight: first,
        secondEdgeFlowLight: second
      };
      this.heroSceneCtl.setSceneParams(params);
      this.heroSceneCtl.start();
    } catch (e) {
      // 低版本没有这个能力就静默降级
    }
  }

  private applySystemBarStyle(): void {
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      w.setWindowSystemBarProperties({
        statusBarContentColor: this.dark() ? '#FFFFFF' : '#17181C',
        navigationBarContentColor: this.dark() ? '#FFFFFF' : '#17181C'
      }).catch(() => {
      });
    }).catch(() => {
    });
  }

  private measureInsets(): void {
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      const dens = display.getDefaultDisplaySync().densityPixels;
      let top = 0;
      let bottom = 0;
      const types: number[] = [
        window.AvoidAreaType.TYPE_SYSTEM,
        window.AvoidAreaType.TYPE_CUTOUT,
        window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
      ];
      for (let i = 0; i < types.length; i++) {
        const a = w.getWindowAvoidArea(types[i] as window.AvoidAreaType);
        top = Math.max(top, a.topRect.height / dens);
        bottom = Math.max(bottom, a.bottomRect.height / dens);
      }
      this.safeTopVp = top > 1 ? top : 28;
      this.safeBottomVp = bottom > 1 ? bottom : 16;
      this.applySystemBarStyle();
      this.setupHeroFlowLight();
    }).catch(() => {
      this.safeTopVp = 28;
      this.safeBottomVp = 16;
    });
  }

  private heroArtworkHeight(): number {
    const w = Metrics.width();
    return Math.round(Math.max(320, Math.min(520, (w > 0 ? w : 440) * 1.005)));
  }

  private heroDisplayHeight(): number {
    return this.heroArtworkHeight() + this.homeArtworkPull;
  }

  /**
   * 安全取当前 Hero 条目。
   * 数据替换瞬间 heroIndex 可能仍然大于新数组长度，直接下标会越界。
   */
  /** 取不到图的 Hero 条目 id（本地会话内，避免反复请求 404 图） */
  @State private badHeroIds: string[] = [];
  /** 坏图记录所属服务器：切服后必须重来 */
  private badHeroScope: string = '';
  private heroTimer: number = -1;

  /** Hero 是否在视口内（onVisibleAreaChange 驱动；不可见就不跑轮播） */
  private onHeroVisible(visible: boolean, ratio: number): void {
    this.heroOnScreen = visible;
    this.syncHeroTimer();
  }

  /**
   * 图片失败 → 记录并把它从 Hero 里剔除（R11：失败 fallback）
   *
   * ★ 旧实现最后一张坏图会卡住：keep.length === 0 时直接 return，
   *   于是列表里留着一个永远加载不出来的条目，Swiper 停在一张空白图上。
   *   现在：全部失败 → heroAllFailed，显示可重试的空态面板（布局高度不变）。
   */
  private onHeroImageFail(itemId: string): void {
    if (this.badHeroIds.indexOf(itemId) >= 0) {
      return;
    }
    this.badHeroIds.push(itemId);
    hilog.info(0x0001, 'NasPlay', 'HERO image fail id=%{public}s bad=%{public}d',
      itemId, this.badHeroIds.length);
    const keep: MediaItem[] = [];
    for (let i = 0; i < this.heroItems.length; i++) {
      if (this.heroItems[i].id !== itemId) {
        keep.push(this.heroItems[i]);
      }
    }
    this.heroItems = keep;
    this.heroAllFailed = keep.length === 0;
    if (keep.length === 0) {
      this.stopHeroTimer();
      this.primeAmbient();
      return;
    }
    const n = this.heroItems.length;
    this.heroIndex = this.heroIndex >= n ? (n > 0 ? n - 1 : 0) : this.heroIndex;
    this.primeAmbient();
    this.syncHeroTimer();
  }

  /** 重试：清掉坏图记录，用已加载的行数据重建 Hero（不重新拉列表） */
  private retryHero(): void {
    this.badHeroIds = [];
    this.heroAllFailed = false;
    Ambient.reset();
    this.buildHeroFromRows();
    hilog.info(0x0001, 'NasPlay', 'HERO retry rows=%{public}d hero=%{public}d',
      this.rows.length, this.heroItems.length);
  }

  /* ───────── R11：轮播的可见生命周期 ─────────
   * 只在「首页 + 前台 + Hero 在视口内 + 没有浮层」时跑 6 秒定时器。
   * 旧实现 startHeroTimer 只有 onPageShow 一个入口，切到其它 Tab、
   * 打开搜索/详情、退后台都不会停 —— 定时器空转，且回来时立刻跳一格。
   */
  private heroCanAutoPlay(): boolean {
    if (this.heroItems.length <= 1) {
      return false;
    }
    if (!this.appActive || this.heroTouching || this.heroScrollP >= 0.75) {
      return false;
    }
    if (!this.heroOnScreen) {
      return false;
    }
    if (this.currentTab !== 0) {
      return false;
    }
    if (this.showSearch || this.showDownloads || this.locked) {
      return false;
    }
    if (this.detailItem !== null || this.browsingLib !== null) {
      return false;
    }
    return true;
  }

  /** 条件满足就启动，不满足就停 —— 幂等，可以到处调 */
  private syncHeroTimer(): void {
    if (this.heroCanAutoPlay()) {
      if (this.heroTimer < 0) {
        this.startHeroTimer();
      }
    } else {
      this.stopHeroTimer();
    }
  }

  /** 自管轮播：每 6 秒前进一格，循环（Swiper.loop 负责首尾衔接） */
  private startHeroTimer(): void {
    this.stopHeroTimer();
    if (!this.heroCanAutoPlay()) {
      return;
    }
    hilog.info(0x0001, 'NasPlay', 'HERO timer start n=%{public}d idx=%{public}d',
      this.heroItems.length, this.heroIndex);
    this.heroTimer = setInterval(() => {
      if (!this.heroCanAutoPlay()) {
        this.stopHeroTimer();
        return;
      }
      // ★ 用 SwiperController 换页，页面才有 420ms 横移动画；
      //   直接改 @State heroIndex 会「瞬切」，录屏里就是一帧跳过去。
      hilog.info(0x0001, 'NasPlay', 'HERO tick from %{public}d', this.heroIndex);
      this.swiperCtl.showNext();
    }, 6000);
  }

  private stopHeroTimer(): void {
    if (this.heroTimer >= 0) {
      clearInterval(this.heroTimer);
      this.heroTimer = -1;
      hilog.info(0x0001, 'NasPlay', 'HERO timer stop');
    }
  }

  /** 手动触摸 / 手动切片后重新计时，避免刚松手就自动跳一格 */
  private restartHeroTimer(): void {
    this.stopHeroTimer();
    this.syncHeroTimer();
  }

  private heroItem(): MediaItem {
    if (this.heroItems.length === 0) {
      return new MediaItem();
    }
    const i = this.heroIndex < 0 ? 0
      : (this.heroIndex >= this.heroItems.length ? this.heroItems.length - 1 : this.heroIndex);
    return this.heroItems[i];
  }

  /**
   * Hero 图片：优先条目的 Primary（竖版），没有可用 tag 才退 Backdrop。
   *
   * ★ 关键：飞牛的 /Images/Primary 必须带 tag，不带会返回 4303 字节 HTML，
   *   解码失败后 NetImage 什么都不画 —— 就是之前那块纯黑。
   *   所以这里必须检查 tag 非空才构造 URL。
   */
  private heroImageUrl(item: MediaItem, w: number): string {
    const sv = this.current;
    if (sv === null) {
      return '';
    }
    if (item.hasPrimaryImage && item.imageTag.length > 0) {
      return MediaServices.imageUrl(sv, item.id, w, item.imageTag);
    }
    // backdropUrl 内部已经做了 tag 检查，两个 tag 都空时返回 ''
    return MediaServices.backdropUrl(sv, item.id, w, item.backdropTag, item.imageTag);
  }

  private darkMode(): boolean {
    return this.dark();
  }
  @State epGroupIndex: number = 0;

  private detailMeta(): string {
    const it = this.detailItem;
    if (it === null) {
      return '';
    }
    let s = '';
    if (it.year > 0) {
      s = it.year.toString();
    }
    if (it.type === 'Series') {
      s = s.length > 0 ? s + ' • 剧集' : '剧集';
      if (it.year === 0 && this.seasons.length > 0) {
        s = s;
      }
    } else if (it.type === 'Movie') {
      s = s.length > 0 ? s + ' • 电影' : '电影';
    }
    return s;
  }

  private detailPlayLabel(): string {
    const it = this.detailItem;
    if (it === null) {
      return '播放';
    }
    if (it.progressTicks > 0) {
      return '继续播放';
    }
    if (it.type === 'Series') {
      return '播放第一集';
    }
    return '播放';
  }

  private detailProgressLabel(): string {
    const it = this.detailItem;
    if (it === null || it.progressTicks <= 0) {
      return '';
    }
    const sec = Math.floor(it.progressTicks / 10000000);
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return (m < 10 ? '0' + m : m.toString()) + ':' + (s < 10 ? '0' + s : s.toString());
  }

  private detailTechInfo(): string {
    const it = this.detailItem;
    if (it === null) {
      return '';
    }
    const parts: string[] = [];
    if (it.runtimeMinutes() > 0) {
      parts.push(it.runtimeMinutes().toString() + ' 分钟');
    }
    const d = this.detail;
    if (d !== null && d.sources.length > 0) {
      const src = d.sources[0];
      if (src.sizeBytes > 0) {
        parts.push((src.sizeBytes / 1073741824).toFixed(2) + ' GB');
      }
      const v = src.videoStream();
      if (v !== undefined && v.width > 0 && v.height > 0) {
        parts.push(v.width.toString() + 'x' + v.height.toString());
      }
      if (v !== undefined && v.codec.length > 0) {
        parts.push(v.codec.toUpperCase());
      }
      const aud = src.audioCount();
      if (aud > 0) {
        parts.push(aud.toString() + ' 音轨');
      }
      const sub = src.subtitleCount();
      if (sub > 0) {
        parts.push(sub.toString() + ' 字幕');
      }
    }
    return parts.join(' • ');
  }

  private episodeCode(ep: MediaItem): string {
    let s = '';
    if (ep.parentIndexNumber > 0) {
      s = 'S' + ep.parentIndexNumber.toString().padStart(2, '0');
    }
    if (ep.indexNumber > 0) {
      s = s + 'E' + ep.indexNumber.toString().padStart(2, '0');
    }
    return s;
  }

  private episodeGroups(): string[] {
    const n = this.episodes.length;
    if (n <= 10) {
      return n > 0 ? ['1-' + n.toString()] : [];
    }
    const out: string[] = [];
    let start = 1;
    while (start <= n) {
      const end = Math.min(start + 9, n);
      out.push(start.toString() + '-' + end.toString());
      start = end + 1;
    }
    return out;
  }

  private visibleEpisodes(): MediaItem[] {
    const size = 10;
    const start = this.epGroupIndex * size;
    const end = Math.min(start + size, this.episodes.length);
    const out: MediaItem[] = [];
    for (let i = start; i < end; i++) {
      out.push(this.episodes[i]);
    }
    return out;
  }

  /** 打开添加菜单：弹簧曲线驱动缩放/位移/透明度（animateTo 才能让弹簧生效） */
  private openAddMenu(): void {
    this.showAddMenu = true;
    animateTo({ curve: curves.springMotion(0.45, 0.6) }, () => {
      this.menuA = 1;
      this.menuS = 1;
      this.menuX = 0;
    });
  }

  private closeAddMenu(): void {
    animateTo({ curve: curves.springMotion(0.32, 1) }, () => {
      this.menuA = 0;
      this.menuS = 0.9;
      this.menuX = 24;
    });
    setTimeout(() => {
      this.showAddMenu = false;
    }, 220);
  }

  private flipServerSort(): void {
    this.serverOrdering = !this.serverOrdering;
    if (this.serverOrdering) { this.serverViewMode = 1; }
  }

  private moveServer(id: string, offset: number): void {
    const order = this.sortedServers().map((server: ServerConfig): string => server.id);
    const index = order.indexOf(id), next = index + offset;
    if (index < 0 || next < 0 || next >= order.length) { return; }
    const replaced = order[next]; order[next] = id; order[index] = replaced; this.serverOrder = order;
    Store.set('server_order', JSON.stringify(order)).catch(() => { promptAction.showToast({ message: '排序保存失败' }); });
  }

  private sortedServers(): ServerConfig[] {
    const out: ServerConfig[] = [];
    for (let i = 0; i < this.servers.length; i++) {
      if (this.serverOption(this.servers[i].id).hidden === this.showHiddenSources) { out.push(this.servers[i]); }
    }
    out.sort((a: ServerConfig, b: ServerConfig): number => {
      const ai = this.serverOrder.indexOf(a.id), bi = this.serverOrder.indexOf(b.id);
      if (ai !== bi && (ai >= 0 || bi >= 0)) { return (ai < 0 ? 100000 : ai) - (bi < 0 ? 100000 : bi); }
      const an: string = a.name;
      const bn: string = b.name;
      const c: number = an < bn ? -1 : (an > bn ? 1 : 0);
      return this.serverSortAsc ? c : -c;
    });
    return out;
  }

  private isCurServer(s: ServerConfig): boolean {
    return this.current !== null && this.current.id === s.id;
  }

  private serverSubTime(s: ServerConfig): string {
    return this.isCurServer(s) ? '当前' : '已保存';
  }

  private serverSubStat(s: ServerConfig): string {
    if (s.kind === 'local') { return '本地文件夹'; }
    if (s.kind === 'iptv') { return 'IPTV 播放列表'; }
    if (SourceProfiles.indexOf(s.kind) >= 0 && SourceProfiles.forKind(s.kind).family === 'files') {
      return SourceProfiles.forKind(s.kind).name + (s.host.length > 0 ? '  ·  ' + s.host : '');
    }
    const n: number = this.isCurServer(s) ? this.libs.length : 0;
    return '媒体库 ' + n.toString() + '  ·  ' + s.host;
  }

  private sourceAddressLabel(server: ServerConfig): string {
    if (server.kind === 'local') { return '本地文件夹'; }
    if (server.kind === 'iptv') { return 'IPTV 播放列表'; }
    if (server.host.length === 0) { return '已保存的来源'; }
    const host = server.host.indexOf(':') >= 0 ? '[' + server.host + ']' : server.host;
    return (server.scheme === 'https' ? 'https://' : '') + host + ':' + server.port.toString() + server.basePath;
  }

  private serverCardHeight(): number {
    const width = Metrics.width() > 0 ? Metrics.width() : 440;
    const cardWidth = Math.max(0, (width - 44) / 2);
    return Math.max(110, Math.min(160, Math.round(cardWidth / 1.9)));
  }

  private serverGridHeight(): number {
    const rows = Math.max(1, Math.ceil(this.sortedServers().length / 2));
    return rows * this.serverCardHeight() + (rows - 1) * 12;
  }

  private refreshAllServers(): void {
    Store.loadServers().then((list: ServerConfig[]) => {
      this.servers = list;
      if (this.current !== null) {
        for (let i = 0; i < list.length; i++) {
          if (list[i].id === this.current.id) {
            this.current = list[i];
            this.loadLibraries();
            break;
          }
        }
      }
      hilog.info(0x0001, 'NasPlay', 'SERVERS refresh n=%{public}d', list.length);
    }).catch(() => {
      hilog.info(0x0001, 'NasPlay', 'SERVERS refresh failed');
    });
  }

  @State private serverOptions: ServerOption[] = [];
  @State private serverOptionId: string = '';
  @State private serverOptionMode: string = '';
  @State private serverOptionText: string = '';
  @State private serverOptionPin: string = '';
  @State private serverOptionOldPin: string = '';
  @State private serverOptionConfirmPin: string = '';
  @State private serverOptionError: string = '';
  @State private serverOptionBusy: boolean = false;
  @State private showHiddenSources: boolean = false;
  private serverPendingAction: string = '';
  private serverOptionGeneration: number = 0;

  private serverOption(id: string): ServerOption {
    const found = this.serverOptions.find((option: ServerOption) => option.id === id);
    return found === undefined ? new ServerOption() : found;
  }

  private async refreshSourceProtection(): Promise<void> {
    await this.reloadServerOptions();
    if (!this.homeScrollMounted || !this.homeScrollPageVisible) { return; }
    if (this.current !== null && this.serverOption(this.current.id).locked) { this.clearProtectedSource(this.current.id); }
    for (const server of this.servers) {
      try {
        if (await ServerOptions.takeDueReminder(server.id)) {
          promptAction.showToast({ message: this.sourceDisplayName(server) + '：今日签到提醒' });
        }
      } catch (error) { /* A corrupt station does not suppress the other sources. */ }
    }
  }

  private async reloadServerOptions(): Promise<void> {
    try { const options = await ServerOptions.all(); if (this.homeScrollMounted) { this.serverOptions = options; this.visionRevision++; } }
    catch (error) { promptAction.showToast({ message: '站点设置读取失败，请重试' }); }
  }

  private async serverGate(server: ServerConfig, action: string = ''): Promise<boolean> {
    try {
      if (!(await ServerOptions.isLocked(server.id))) { return true; }
      this.clearProtectedSource(server.id);
      this.serverPendingAction = action;
      this.openServerOption(server, 'unlock');
    } catch (error) { this.clearProtectedSource(server.id); promptAction.showToast({ message: '无法验证服务器保护状态，请重试' }); }
    return false;
  }

  private openServerOption(server: ServerConfig, mode: string): void {
    const generation = ++this.serverOptionGeneration;
    this.serverOptionId = server.id; this.serverOptionMode = mode;
    this.serverOptionText = mode === 'note' ? this.serverOption(server.id).note : '';
    if (mode === 'share') {
      ServerOptions.publicShare(server).then((text: string) => {
        if (generation === this.serverOptionGeneration && this.serverOptionId === server.id && this.serverOptionMode === 'share') { this.serverOptionText = text; }
      }).catch(() => { if (generation === this.serverOptionGeneration) { this.serverOptionError = '连接信息无法读取，请先解锁服务器'; } });
    }
    this.serverOptionPin = ''; this.serverOptionOldPin = ''; this.serverOptionConfirmPin = ''; this.serverOptionError = '';
    this.ensureSubpage('server-options');
  }

  private clearProtectedSource(id: string): void {
    if (this.current === null || this.current.id !== id) { return; }
    this.serverSelectionGeneration++; this.playRequestGeneration++; this.detailRequestGeneration++; this.seasonRequestGeneration++;
    this.stopHeroTimer(); this.current = null; this.heroItems = []; this.rows = []; this.libs = [];
    this.resumeItems = []; this.favorites = []; this.detailItem = null; this.detail = null; this.people = [];
    this.closeLibrary(); this.searchQuery = ''; this.searchResults = []; this.showSearch = false;
    const names = this.stackNames();
    if (names.length === 0 || names.some((name: string): boolean => name === 'detail' || name === 'library' || name === 'search' || name === 'source')) {
      this.navStack.clear(); this.navNames = []; this.currentTab = 3; this.tabCtl.changeIndex(3);
    }
    Ambient.reset(); this.applyAmbient();
  }

  private async serverMenuAction(server: ServerConfig, action: string): Promise<void> {
    try { this.getUIContext().getContextMenuController().close(); } catch (error) {}
    this.serverPendingAction = '';
    if (action === 'unlock') { this.serverPendingAction = ''; this.openServerOption(server, 'unlock'); return; }
    if (action === 'pin' || action === 'clearPin') { this.openServerOption(server, action); return; }
    if (!(await this.serverGate(server, action))) { return; }
    try {
      if (action === 'home') { await this.openServerHome(server); }
      else if (action === 'select') { await this.selectServer(server); }
      else if (action === 'edit') { this.openEditServer(server); }
      else if (action === 'share' || action === 'note' || action === 'backups' || action === 'reminder' || action === 'pin') {
        this.openServerOption(server, action);
      } else if (action === 'lock') {
        if (!this.serverOption(server.id).hasPin) { this.openServerOption(server, 'pin'); return; }
        await ServerOptions.lock(server.id); this.clearProtectedSource(server.id);
      } else if (action === 'aggregate') {
        await ServerOptions.setAggregate(server.id, !this.serverOption(server.id).aggregateEnabled);
      } else if (action === 'hidden') {
        const option = this.serverOption(server.id);
        if (!option.hidden && !option.hasPin) {
          this.serverPendingAction = 'hidden'; this.openServerOption(server, 'pin'); return;
        }
        await ServerOptions.setHidden(server.id, !option.hidden);
        if (!option.hidden) { await ServerOptions.lock(server.id); this.clearProtectedSource(server.id); }
      } else if (action === 'delete') {
        const answer = await this.getUIContext().getPromptAction().showDialog({ systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent), title: '删除来源', message: '删除连接及其已保存凭据？服务器上的文件不会被删除。',
          buttons: [{ text: '取消', color: this.P().textDim }, { text: '删除', color: '#E5484D' }] });
        if (answer.index !== 1 || !(await this.serverGate(server, 'delete'))) { return; }
        await Store.remove(server.id); await ServerOptions.clear(server.id); this.clearProtectedSource(server.id); this.servers = await Store.loadServers();
      }
      await this.reloadServerOptions();
    } catch (error) { promptAction.showToast({ message: '操作未完成，请重试' }); }
  }

  @Builder
  serverMenuItem(title: string, symbol: Resource, server: ServerConfig, action: string) {
    Row({ space: 10 }) {
      if (action === 'share') {
        Image($r('app.media.ic_share')).width(15).height(15).fillColor(this.P().text)
      } else {
        SymbolGlyph(symbol).fontSize(15).fontColor([action === 'delete' ? '#FFB4AB' : this.P().text])
      }
      Text(title).fontSize(14).fontColor(action === 'delete' ? '#FFB4AB' : this.P().text)
    }.width('100%').height(43).padding({ left: 16, right: 18 })
      .onClick(() => { this.serverMenuAction(server, action); })
    Divider().strokeWidth(0.5).color(this.P().divider).margin({ left: 15, right: 15 })
  }

  @Builder
  serverContextMenu(server: ServerConfig) {
    Column() {
      this.serverMenuItem('编辑', $r('sys.symbol.square_and_pencil'), server, 'edit')
      this.serverMenuItem('分享', $r('sys.symbol.square_and_arrow_down'), server, 'share')
      this.serverMenuItem('备注', $r('sys.symbol.square_and_pencil'), server, 'note')
      this.serverMenuItem(this.serverOption(server.id).locked ? '解锁' : '上锁', $r('sys.symbol.lock'), server,
        this.serverOption(server.id).locked ? 'unlock' : 'lock')
      this.serverMenuItem('签到提醒', $r('sys.symbol.clock'), server, 'reminder')
      if (this.serverOption(server.id).hasPin) {
        this.serverMenuItem('修改密码', $r('sys.symbol.lock'), server, 'pin')
        this.serverMenuItem('移除密码', $r('sys.symbol.lock_open'), server, 'clearPin')
      }
      this.serverMenuItem('备用节点', $r('sys.symbol.TV_tv'), server, 'backups')
      this.serverMenuItem(this.serverOption(server.id).aggregateEnabled ? '禁用聚合' : '启用聚合', $r('sys.symbol.magnifyingglass'), server, 'aggregate')
      this.serverMenuItem(this.serverOption(server.id).hidden ? '移出隐藏空间' : '加入隐藏空间', $r('sys.symbol.folder'), server, 'hidden')
      this.serverMenuItem('删除', $r('sys.symbol.trash'), server, 'delete')
    }.width(208)
  }

  private async saveServerOption(): Promise<void> {
    if (this.serverOptionBusy) { return; }
    const server = this.servers.find((source: ServerConfig) => source.id === this.serverOptionId);
    if (server === undefined) { this.serverOptionError = '来源已不存在'; return; }
    const generation = this.serverOptionGeneration, mode = this.serverOptionMode, pending = this.serverPendingAction;
    const current = (): boolean => this.homeScrollMounted && generation === this.serverOptionGeneration
      && this.serverOptionId === server.id && this.serverOptionMode === mode;
    this.serverOptionBusy = true; this.serverOptionError = '';
    try {
      if (mode === 'unlock') {
        if (!(await ServerOptions.verifyPin(server.id, this.serverOptionPin))) { throw new Error('密码不正确或尝试过于频繁'); }
      } else {
        if (mode !== 'pin' && mode !== 'clearPin' && await ServerOptions.isLocked(server.id)) { throw new Error('请先解锁服务器'); }
        if (mode === 'note') { await ServerOptions.setNote(server.id, this.serverOptionText); }
        else if (mode === 'pin') {
          if (this.serverOptionPin !== this.serverOptionConfirmPin) { throw new Error('两次输入的新密码不一致'); }
          await ServerOptions.setPin(server.id, this.serverOptionPin, this.serverOptionOldPin);
          if (pending === 'hidden' && current()) {
            if (!(await ServerOptions.verifyPin(server.id, this.serverOptionPin))) { throw new Error('密码已保存，请重新解锁后加入隐藏空间'); }
            await ServerOptions.setHidden(server.id, true); await ServerOptions.lock(server.id);
          }
          this.clearProtectedSource(server.id);
          await this.reloadServerOptions();
          if (current()) { this.serverPendingAction = ''; this.popNamed('server-options'); }
          return;
        }
        else if (mode === 'clearPin') { await ServerOptions.clearPin(server.id, this.serverOptionPin); }
        else if (mode === 'backups') { await ServerOptions.putBackup(server.id, '备用节点', this.serverOptionText); }
      }
      await this.reloadServerOptions();
      if (!current()) { return; }
      this.serverOptionPin = ''; this.serverOptionOldPin = ''; this.serverOptionConfirmPin = '';
      if (mode !== 'backups') {
        this.serverPendingAction = '';
        this.popNamed('server-options');
        if (pending.length > 0) { await this.serverMenuAction(server, pending); }
      } else { this.serverOptionText = ''; }
    } catch (error) { if (current()) { this.serverOptionError = (error as Error).message; } }
    finally { if (current()) { this.serverOptionBusy = false; } }
  }

  @Builder
  serverOptionsPage() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.selectedServerOptionName()).fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.P().text).width('100%')
        if (this.serverOptionMode === 'share') {
          Text(this.serverOptionText).fontSize(14).lineHeight(23).fontColor(this.P().text)
            .copyOption(CopyOptions.LocalDevice).width('100%')
          Text('长按复制连接信息。分享内容不含账号、密码、令牌或私有资源地址；接收方需自行登录。')
            .fontSize(12).lineHeight(21).fontColor(this.P().textDim)
        } else if (this.serverOptionMode === 'unlock' || this.serverOptionMode === 'pin' || this.serverOptionMode === 'clearPin') {
          Text(this.serverOptionMode === 'unlock' ? '输入密码即可访问此服务器' : this.serverOptionMode === 'clearPin' ? '验证后移除这个服务器的密码保护' : '设置 4–12 位数字密码，仅保护这个服务器')
            .fontSize(15).fontColor(this.P().text).width('100%')
          if (this.serverOptionMode === 'pin' && this.serverOption(this.serverOptionId).hasPin) {
            TextInput({ text: this.serverOptionOldPin, placeholder: '当前密码（已解锁时可留空）' }).type(InputType.NUMBER_PASSWORD)
              .maxLength(12).height(48).fontColor(this.P().text).backgroundColor(this.P().card)
              .onChange((value: string) => { this.serverOptionOldPin = value; })
          }
          TextInput({ text: this.serverOptionPin, placeholder: this.serverOptionMode === 'pin' ? '新的数字密码' : '当前服务器密码' })
            .type(InputType.NUMBER_PASSWORD).maxLength(12).height(48).fontColor(this.P().text).backgroundColor(this.P().card)
            .onChange((value: string) => { this.serverOptionPin = value; })
          if (this.serverOptionMode === 'pin') {
            TextInput({ text: this.serverOptionConfirmPin, placeholder: '再次输入新的密码' })
              .type(InputType.NUMBER_PASSWORD).maxLength(12).height(48).fontColor(this.P().text).backgroundColor(this.P().card)
              .onChange((value: string) => { this.serverOptionConfirmPin = value; })
          }
          Text('密码只保护上面选定的服务器，应用和其他服务器可以正常使用。')
            .fontSize(12).lineHeight(21).fontColor(this.P().textDim)
        } else if (this.serverOptionMode === 'note') {
          TextArea({ text: this.serverOptionText, placeholder: '为这个服务器添加备注' }).height(150).maxLength(500)
            .fontSize(15).fontColor(this.P().text).backgroundColor(this.P().card)
            .onChange((value: string) => { this.serverOptionText = value; })
        } else if (this.serverOptionMode === 'backups') {
          Text('备用节点属于同一个服务器。切换时保留账号凭据，请只添加你信任的地址。')
            .fontSize(13).lineHeight(21).fontColor(this.P().textDim).width('100%')
          ForEach(this.serverOption(this.serverOptionId).backups, (node: ServerBackupNode) => {
            Column({ space: 9 }) {
              Text(node.url).fontSize(14).fontColor(this.P().text).width('100%')
              Row({ space: 12 }) {
                Button('切换到此节点').fontSize(12).onClick(() => { this.activateServerBackup(node); })
                Button('删除').fontSize(12).onClick(() => {
                  this.removeServerBackup(node);
                })
              }
            }.width('100%').padding(14).backgroundColor(this.P().card).borderRadius(12)
          }, (node: ServerBackupNode) => node.id)
          TextInput({ text: this.serverOptionText, placeholder: 'https://nas.example.com:443' }).height(48)
            .fontSize(14).fontColor(this.P().text).backgroundColor(this.P().card)
            .onChange((value: string) => { this.serverOptionText = value; })
        } else if (this.serverOptionMode === 'reminder') {
          Row() {
            Text('启用签到提醒').fontSize(15).fontColor(this.P().text).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.serverOption(this.serverOptionId).reminderEnabled })
              .selectedColor(this.P().accent).onChange((value: boolean) => {
                ServerOptions.setReminder(this.serverOptionId, value).then(() => { this.reloadServerOptions(); })
                  .catch(() => { this.serverOptionError = '提醒设置保存失败'; });
              })
          }.width('100%').padding(16).backgroundColor(this.P().card).borderRadius(14)
          Text('每日 09:00 后打开应用时提醒一次。应用不会代替你向服务器执行签到，也不承诺后台定时提醒。')
            .fontSize(13).lineHeight(22).fontColor(this.P().textDim)
        }
        if (this.serverOptionError.length > 0) { Text(this.serverOptionError).fontSize(13).fontColor('#E46C6C').width('100%') }
        if (this.serverOptionMode !== 'share' && this.serverOptionMode !== 'reminder') {
          Button(this.serverOptionMode === 'unlock' ? '解锁' : this.serverOptionMode === 'clearPin' ? '移除这个服务器的密码' : this.serverOptionMode === 'pin' ? '保存并上锁' : this.serverOptionMode === 'backups' ? '添加节点' : '保存')
            .width('100%').height(48).enabled(!this.serverOptionBusy).backgroundColor(this.P().accent).fontColor('#FFFFFF')
            .onClick(() => { this.saveServerOption(); })
        }
      }.width('100%').padding({ top: 94, left: 20, right: 20, bottom: 36 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
  }

  private async removeServerBackup(node: ServerBackupNode): Promise<void> {
    const id = this.serverOptionId, generation = this.serverOptionGeneration;
    try { await ServerOptions.removeBackup(id, node.id); await this.reloadServerOptions(); }
    catch (error) { if (generation === this.serverOptionGeneration && id === this.serverOptionId) { this.serverOptionError = (error as Error).message; } }
  }

  private async activateServerBackup(node: ServerBackupNode): Promise<void> {
    const id = this.serverOptionId, generation = this.serverOptionGeneration;
    try {
      if (await ServerOptions.isLocked(this.serverOptionId)) { throw new Error('请先解锁服务器'); }
      await ServerOptions.activateBackup(id, node.id);
      if (generation !== this.serverOptionGeneration || id !== this.serverOptionId) { return; }
      this.servers = await Store.loadServers();
      const server = this.servers.find((source: ServerConfig) => source.id === this.serverOptionId);
      if (server !== undefined) { await this.selectServer(server); }
      await this.reloadServerOptions(); promptAction.showToast({ message: '已切换备用节点' });
    } catch (error) { this.serverOptionError = (error as Error).message; }
  }


  @Builder
  serverListView() {
    Scroll() {
      Column() {
        if (this.servers.length === 0) {
          Column() {
            SymbolGlyph($r('sys.symbol.TV_tv'))
              .fontSize(46)
              .fontColor([withAlpha(this.P().textDim, 0.5)])
            Text('还没有添加服务器')
              .fontSize(15)
              .fontColor(this.P().textDim)
              .margin({ top: 14 })
            Text('点右上角 + 选择服务类型')
              .fontSize(12)
              .fontColor(this.P().textFaint)
              .margin({ top: 6 })
          }
          .width('100%')
          .padding({ top: 90 })
        } else if (this.serverViewMode === 0) {
          Grid() {
            ForEach(this.sortedServers(), (s: ServerConfig) => {
              GridItem() {
                this.serverCardGrid(s)
              }
            }, (s: ServerConfig) => s.id)
          }
          .width('100%')
          .columnsTemplate('1fr 1fr')
          .columnsGap(12)
          .rowsGap(12)
          .height(this.serverGridHeight())
          .padding({ left: 16, right: 16 })
          .scrollBar(BarState.Off)
        } else {
          Column({ space: 12 }) {
            ForEach(this.sortedServers(), (s: ServerConfig) => {
              this.serverCardRow(s)
            }, (s: ServerConfig) => s.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }

        if (this.servers.length > 0) {
          Row() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(16)
              .fontColor([this.P().text])
            Text('刷新服务器数据')
              .fontSize(15)
              .fontColor(this.P().text)
              .margin({ left: 8 })
          }
          .padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .borderRadius(26)
          .backgroundColor(this.glassBg())
          .border({ width: 0.5, color: this.glassBorder() })
          // 内容区按钮拿不到沉浸材质（官方：只在标题栏/TabBar 生效），
          // 按压反馈用弹簧曲线自行实现（官方推荐做法）。
          .scale({ x: this.pressedBtn === 2 ? 0.90 : 1, y: this.pressedBtn === 2 ? 0.90 : 1 })
          .animation({ curve: curves.springMotion(0.32, 0.55) })
          .onTouch((e: TouchEvent) => {
            this.pressedBtn = e.type === TouchType.Down ? 2 : -1;
          })
          .margin({ top: 20 })
          .onClick(() => { this.refreshAllServers(); })

          Text('已到列表底部')
            .fontSize(12)
            .fontColor(this.P().textFaint)
            .margin({ top: 12 })
        }

      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 102, bottom: this.dockBottomGap() + 64 + 16 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.TopStart)
  }

  /** 2 列网格卡片 */
  @Builder
  serverCardGrid(s: ServerConfig) {
    Column() {
      Row() {
        Stack() {
          SymbolGlyph($r('sys.symbol.TV_tv'))
            .fontSize(16)
            .fontColor([withAlpha(this.P().text, 0.85)])
        }
        .width(28).height(28).borderRadius(8)
        .backgroundColor(withAlpha(this.P().accent, 0.20))

        Blank()

        Circle()
          .width(6).height(6)
          .fill(this.isCurServer(s) ? '#4ADE80' : withAlpha(this.P().textFaint, 0.8))
        Text(this.serverSubTime(s))
          .fontSize(11)
          .fontColor(this.P().textFaint)
          .margin({ left: 5 })
      }
      .width('100%')

      Text(this.sourceDisplayName(s))
        .fontSize(15)
        .fontColor(this.P().text)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8 })
        .width('100%')
        .textAlign(TextAlign.Start)

      Blank()

      Row() {
        Text(this.serverSubStat(s))
          .fontSize(11)
          .fontColor(this.P().textDim)
          .maxLines(1)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Row() {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(14)
            .fontColor([this.P().accent])
          Text('编辑')
            .fontSize(11)
            .fontColor(this.P().accent)
            .margin({ left: 4 })
        }
        .padding({ left: 6, top: 4, bottom: 4 })
        .onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .onClick(() => {
          this.serverMenuAction(s, 'edit');
        })
      }
      .width('100%')
    }
    .width('100%')
    .height(this.serverCardHeight())
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(18)
    .backgroundColor(this.dark() ? '#28272A' : '#FFFFFF')
    .border({
      width: this.isCurServer(s) ? 2 : 0.5,
      color: this.isCurServer(s) ? this.P().accent
        : withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.10)
    })
    .onClick(() => { this.openServerHome(s); })
    .bindContextMenu(this.serverContextMenu(s), ResponseType.LongPress, { systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent), borderRadius: 18 })
  }

  /** 列表行卡片 */
  @Builder
  serverCardRow(s: ServerConfig) {
    Row() {
      Stack() {
        SymbolGlyph($r('sys.symbol.TV_tv'))
          .fontSize(20)
          .fontColor([withAlpha(this.P().text, 0.85)])
      }
      .width(44).height(44).borderRadius(12)
      .backgroundColor(withAlpha(this.P().accent, 0.20))

      Column() {
        Text((this.serverOption(s.id).locked ? '🔒  ' : '') + this.sourceDisplayName(s))
          .fontSize(16)
          .fontColor(this.P().text)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.serverOption(s.id).note.length > 0 ? this.serverOption(s.id).note : this.serverSubStat(s))
          .fontSize(11)
          .fontColor(this.P().textDim)
          .margin({ top: 4 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      Column() {
        Circle()
          .width(6).height(6)
          .fill(this.isCurServer(s) ? '#4ADE80' : withAlpha(this.P().textFaint, 0.8))
        Text(this.serverSubTime(s))
          .fontSize(11)
          .fontColor(this.P().textFaint)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.End)

      if (this.serverOrdering) {
        Column({ space: 4 }) {
          Button('↑').width(32).height(28).fontSize(15).onClick(() => { this.moveServer(s.id, -1); })
          Button('↓').width(32).height(28).fontSize(15).onClick(() => { this.moveServer(s.id, 1); })
        }.margin({ left: 8 }).onTouch((event: TouchEvent) => { event.stopPropagation(); })
      } else {
      Row() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(15)
          .fontColor([this.P().accent])
        Text('编辑')
          .fontSize(12)
          .fontColor(this.P().accent)
          .margin({ left: 3 })
      }
      .padding(8)
      .margin({ left: 4 })
      .onTouch((event: TouchEvent) => { event.stopPropagation(); })
      .onClick(() => {
        this.serverMenuAction(s, 'edit');
      })
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(18)
    .backgroundColor(this.dark() ? '#28272A' : '#FFFFFF')
    .border({
      width: this.isCurServer(s) ? 2 : 0.5,
      color: this.isCurServer(s) ? this.P().accent
        : withAlpha(this.dark() ? '#FFFFFF' : '#000000', 0.10)
    })
    .onClick(() => { this.openServerHome(s); })
    .bindContextMenu(this.serverContextMenu(s), ResponseType.LongPress, { systemMaterial: Materials.popupMaterial(this.dark(), this.P().accent), borderRadius: 18 })
  }

  /** 添加服务器菜单（参考应用：点 + 弹出服务类型列表） */
  @Builder
  addServerMenu() {
    // ★ 自绘菜单内容 + 系统材质容器：
    //   系统 MenuItem 的文字颜色不受材质参数控制（跟随系统文字色），
    //   深色材质上仍然是黑字，怎么调 materialColor 都没用。
    //   所以内容自己画（白字可控），材质仍由 bindMenu 的 systemMaterial 提供。
    Column() {
      ForEach(this.addTypes, (name: string, idx: number) => {
        Row() {
          Text(name)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => {
          this.openAddServer(SourceProfiles.forName(name).kind);
        })

        if (idx < this.addTypes.length - 1) {
          Divider()
            .color(withAlpha('#FFFFFF', 0.12))
            .strokeWidth(0.5)
            .margin({ left: 20, right: 20 })
        }
      }, (name: string, idx: number) => name)
    }
    .width(200)
  }

  private selectedServerOptionName(): string {
    const server = this.servers.find((entry: ServerConfig): boolean => entry.id === this.serverOptionId);
    return server === undefined ? '服务器' : this.sourceDisplayName(server);
  }

  private protectedServerCount(): string {
    const count = this.serverOptions.filter((option: ServerOption): boolean => option.hasPin).length;
    return count > 0 ? count.toString() + ' 个服务器已保护' : '按服务器设置';
  }

  @Builder
  serverPasswordSettings() {
    Scroll() {
      Column({ space: 14 }) {
        Text('选择要保护的服务器').fontSize(17).fontColor(this.P().text).width('100%')
        Text('每个服务器单独设置密码。打开应用和访问其他服务器都不受影响。')
          .fontSize(13).lineHeight(21).fontColor(this.P().textDim).width('100%')
        ForEach(this.servers, (server: ServerConfig) => {
          Column({ space: 12 }) {
            Row() {
              Text(this.sourceDisplayName(server)).fontSize(16).fontColor(this.P().text).layoutWeight(1)
              Text(this.serverOption(server.id).hasPin ? this.serverOption(server.id).locked ? '已锁定' : '已解锁' : '未设置密码')
                .fontSize(12).fontColor(this.P().textDim)
            }.width('100%')
            Row({ space: 8 }) {
              if (this.serverOption(server.id).hasPin) {
                Button(this.serverOption(server.id).locked ? '解锁' : '立即上锁').fontSize(13).height(40).layoutWeight(1)
                  .backgroundColor(this.P().chip).fontColor(this.P().accent)
                  .onClick(() => { this.serverMenuAction(server, this.serverOption(server.id).locked ? 'unlock' : 'lock'); })
                Button('修改密码').fontSize(13).height(40).layoutWeight(1).backgroundColor(this.P().chip).fontColor(this.P().text)
                  .onClick(() => { this.serverMenuAction(server, 'pin'); })
                Button('移除密码').fontSize(13).height(40).layoutWeight(1).backgroundColor(this.P().chip).fontColor(this.P().textDim)
                  .onClick(() => { this.serverMenuAction(server, 'clearPin'); })
              } else {
                Button('设置密码').fontSize(14).height(42).width('100%').backgroundColor(this.P().accent).fontColor('#FFFFFF')
                  .onClick(() => { this.serverMenuAction(server, 'pin'); })
              }
            }.width('100%')
          }.width('100%').padding(16).backgroundColor(this.P().card).borderRadius(16)
        }, (server: ServerConfig) => server.id)
        if (this.servers.length === 0) {
          Button('添加服务器').height(44).onClick(() => { this.openAddServer(); })
        }
      }.width('100%').padding({ top: 90, left: 20, right: 20, bottom: 32 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
      .onAppear(() => { this.reloadServerOptions(); })
  }

  private settingsPageTitle(section: string): string {
    if (section === 'appearance') { return '外观与个性化'; }
    if (section === 'servers') { return '服务器管理'; }
    if (section === 'subscriptions') { return '待看与追更'; }
    if (section === 'tmdb') { return 'TMDB 设置'; }
    if (section === 'lock') { return '服务器密码'; }
    if (section === 'interaction') { return '界面交互'; }
    if (section === 'layout') { return '界面布局'; }
    if (section === 'playback') { return '播放偏好'; }
    if (section === 'subtitles') { return '字幕设置'; }
    if (section === 'cache') { return '播放缓存'; }
    if (section === 'notifications') { return '推送设置'; }
    return '设置';
  }

  @Builder
  settingsPage(section: string) {
    if (section === 'appearance') {
      Column() { this.appearanceSheet() }.width('100%').height('100%').padding({ top: 88 })
    } else if (section === 'servers') {
      Column() {
        Row({ space: 12 }) {
          Button('添加服务器').onClick(() => { this.openAddServer(); })
          Button(this.showHiddenSources ? '返回普通空间' : '隐藏空间').onClick(() => { this.showHiddenSources = !this.showHiddenSources; })
        }.padding({ top: 84, left: 20, right: 20 }).width('100%')
        this.serverListView()
      }.width('100%').height('100%')
    } else if (section === 'subscriptions') {
      VisionPage({ servers: this.visionSources(), active: this.visionContextVisible('settings:subscriptions'), revision: this.visionRevision,
        initialSection: 0, darkMode: this.dark(), safeTopVp: 82, bottomInsetVp: 24,
        onPlay: (server: ServerConfig, item: MediaItem) => this.openVisionItem(server, item, true),
        onOpenDetail: (server: ServerConfig, item: MediaItem) => this.openVisionItem(server, item, false),
        onBrowse: () => { this.openVisionBrowse(); } })
    } else if (section === 'tmdb') {
      this.tmdbSettingsPage()
    } else if (section === 'interaction' || section === 'layout' || section === 'playback' || section === 'subtitles') {
      PlaybackSettings({ section: section, darkMode: this.dark() })
    } else if (section === 'lock') {
      this.serverPasswordSettings()
    } else if (section === 'notifications') {
      Column({ space: 16 }) {
        Row() {
          Text('允许应用通知').fontSize(15).fontColor(this.P().text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.pushEnabled }).selectedColor(this.P().accent)
            .onChange((value: boolean) => { this.togglePush(value); })
        }.width('100%').padding(16).backgroundColor(this.P().card).borderRadius(14)
        Text('下载完成等通知由系统授权决定。签到提醒只在应用打开时检查，不是后台定时任务。')
          .fontSize(13).lineHeight(22).fontColor(this.P().textDim).width('100%')
      }.width('100%').height('100%').padding({ top: 94, left: 20, right: 20 })
    } else if (section === 'cache') {
      Column({ space: 18 }) {
        Text(this.playCacheText()).fontSize(24).fontColor(this.P().text)
        Text('清理闲置的播放缓存；正在使用的缓存会保留。网络影片按需缓冲播放。')
          .fontSize(13).lineHeight(21).fontColor(this.P().textDim)
        Button('清理播放缓存').height(48).width('100%').backgroundColor(this.P().card).fontColor(this.P().accent)
          .onClick(() => { this.confirmClearPlayCache(); })
      }.width('100%').height('100%').padding({ top: 110, left: 20, right: 20 }).alignItems(HorizontalAlign.Start)
    }
  }

  private async persistTmdbOptions(): Promise<void> {
    try {
      await Store.set('tmdb_preferred_source', this.tmdbPreferred);
      await Store.set('tmdb_auto_include', this.tmdbAutoInclude ? '1' : '0');
      await Store.set('tmdb_excluded_sources', JSON.stringify(this.tmdbExcluded));
      this.visionRevision++;
    } catch (error) { promptAction.showToast({ message: '设置保存失败，请重试' }); }
  }

  @Builder
  tmdbSettingsPage() {
    Scroll() {
      Column({ space: 16 }) {
        Text('首选站点').fontSize(13).fontColor(this.P().textDim).width('100%')
        Column() {
          ForEach(this.servers, (server: ServerConfig) => {
            Row() {
              Text(this.sourceDisplayName(server)).fontSize(15).fontColor(this.P().text).layoutWeight(1)
              if (this.tmdbPreferred === server.id) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.P().accent])
              }
            }.width('100%').padding(15).onClick(() => { this.tmdbPreferred = server.id; this.persistTmdbOptions(); })
          }, (server: ServerConfig) => server.id)
          if (this.servers.length === 0) { Text('请先添加服务器').fontSize(14).fontColor(this.P().textDim).padding(16) }
        }.width('100%').backgroundColor(this.P().card).borderRadius(16)
        Row() {
          Text('自动聚合新增站点').fontSize(14).fontColor(this.P().text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.tmdbAutoInclude }).selectedColor(this.P().accent)
            .onChange((value: boolean) => { this.tmdbAutoInclude = value; this.persistTmdbOptions(); })
        }.width('100%').padding(16).backgroundColor(this.P().card).borderRadius(16)
        Text('聚合站点').fontSize(13).fontColor(this.P().textDim).width('100%')
        Column() {
          ForEach(this.servers, (server: ServerConfig) => {
            Row() {
              Text(this.sourceDisplayName(server)).fontSize(14).fontColor(this.P().text).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.serverOption(server.id).aggregateEnabled }).selectedColor(this.P().accent)
                .onChange((value: boolean) => { this.setTmdbSource(server, value); })
            }.width('100%').padding(15)
          }, (server: ServerConfig) => server.id)
        }.width('100%').backgroundColor(this.P().card).borderRadius(16)
        Text('TMDB API Key（可选）').fontSize(13).fontColor(this.P().textDim).width('100%')
        TextInput({ text: this.tmdbInput, placeholder: '用于后续元数据扩展，Vision 无需此密钥' })
          .type(InputType.Password).fontSize(14).fontColor(this.P().text).backgroundColor(this.P().card)
          .height(48).onChange((value: string) => { this.tmdbInput = value; })
        Button('保存 API Key').width('100%').height(46).fontColor(this.P().accent).backgroundColor(this.P().card)
          .onClick(() => { this.saveTmdbKey(); })
        Text('站点参与设置用于多来源内容聚合。文件型来源的元数据能力由服务本身提供。')
          .fontSize(12).lineHeight(20).fontColor(this.P().textFaint).width('100%')
      }.width('100%').padding({ top: 90, left: 20, right: 20, bottom: 32 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.TopStart)
  }

  private async setTmdbSource(server: ServerConfig, enabled: boolean): Promise<void> {
    if (!(await this.serverGate(server))) { return; }
    try {
      await ServerOptions.setAggregate(server.id, enabled);
      await this.reloadServerOptions();
      this.tmdbExcluded = enabled ? this.tmdbExcluded.filter((id: string): boolean => id !== server.id)
        : this.tmdbExcluded.indexOf(server.id) >= 0 ? this.tmdbExcluded : this.tmdbExcluded.concat([server.id]);
      await this.persistTmdbOptions();
    } catch (error) { promptAction.showToast({ message: '站点聚合设置未保存，请重试' }); }
  }


  @Builder
  settingsView() {
    Column() {
      Scroll() {
        Column() {
          Row({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.TV_tv_fill')).fontSize(24).fontColor([this.P().text])
            Column({ space: 3 }) {
              Text('VablePlayer').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.P().text)
              Text(this.current !== null ? this.rootServerSummary() : '连接你的媒体服务器')
                .fontSize(9).fontColor(this.P().textDim).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(11).fontColor([this.P().textFaint])
          }
          .width('100%').height(54).padding({ left: 16, right: 14 })
          .backgroundColor(this.P().card).borderRadius(16)
          .focusable(true).clickEffect(MotionFx.pressSoft())
          .onClick(() => { this.ensureSubpage('settings:servers'); })

          Row({ space: 12 }) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.square_and_arrow_down')).fontSize(19).fontColor([this.P().textDim])
              Column({ space: 3 }) {
                Text('下载管理').fontSize(11).fontColor(this.P().text)
                Text(this.downloadedBytes()).fontSize(9).fontColor(this.P().textFaint)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(10).fontColor([this.P().textFaint])
            }
            .layoutWeight(1).height(54).padding({ left: 16, right: 12 })
            .backgroundColor(this.P().card).borderRadius(16)
            .focusable(true).clickEffect(MotionFx.pressSoft())
            .onClick(() => { this.showDownloads = true; this.ensureSubpage('downloads'); })

            Row({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.arrow_down_circle')).fontSize(19).fontColor([this.P().textDim])
              Column({ space: 3 }) {
                Text('推送通知').fontSize(11).fontColor(this.P().text)
                Text(this.pushEnabled ? '已开启' : '已关闭').fontSize(9).fontColor(this.P().textFaint)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(10).fontColor([this.P().textFaint])
            }
            .layoutWeight(1).height(54).padding({ left: 14, right: 10 })
            .backgroundColor(this.P().card).borderRadius(16)
            .onClick(() => { this.ensureSubpage('settings:notifications'); })
          }.width('100%').margin({ top: 16 })

          this.settingsGroupTitle('通用')
          Column() {
            this.settingsActionRow($r('sys.symbol.rectangle_on_rectangle'), '外观与个性化', '', () => { this.ensureSubpage('settings:appearance'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.square_and_arrow_down'), '下载管理', '', () => { this.showDownloads = true; this.ensureSubpage('downloads'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.star_fill'), '订阅', '', () => { this.ensureSubpage('settings:subscriptions'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.TV_tv'), 'TMDB 设置', this.tmdbKey.length > 0 ? '已配置' : '', () => { this.tmdbInput = this.tmdbKey; this.ensureSubpage('settings:tmdb'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.gearshape'), '服务器管理', '', () => { this.ensureSubpage('settings:servers'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.lock'), '服务器密码', this.protectedServerCount(), () => { this.ensureSubpage('settings:lock'); })
          }.width('100%').backgroundColor(this.P().card).borderRadius(16).clip(true)

          this.settingsGroupTitle('播放器')
          Column() {
            this.settingsActionRow($r('sys.symbol.list_bullet'), '界面交互', '', () => { this.ensureSubpage('settings:interaction'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.square_grid_2x2'), '界面布局', '', () => { this.ensureSubpage('settings:layout'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.play_fill'), '播放偏好', '', () => { this.ensureSubpage('settings:playback'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.music_note_circle'), '字幕设置', '', () => { this.ensureSubpage('settings:subtitles'); })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.text_character_square'), 'AI 字幕翻译', '模型与接口', () => {
              router.pushUrl({ url: 'pages/AiSubtitlePage' }).catch(() => {});
            })
            this.settingsDivider()
            this.settingsActionRow($r('sys.symbol.arrow_clockwise'), '播放缓存', this.playCacheText(), () => { this.ensureSubpage('settings:cache'); })
          }.width('100%').backgroundColor(this.P().card).borderRadius(16).clip(true)

          this.settingsGroupTitle('服务器')
          Column() {
            this.settingsInfoRow($r('sys.symbol.TV_tv'), '当前服务器', this.current !== null ? this.rootServerSummary() : '未连接')
            this.settingsDivider()
            this.settingsInfoRow($r('sys.symbol.folder'), '地址', this.current !== null ? this.current.host + ':' + this.current.port.toString() : '—')
            this.settingsDivider()
            this.settingsInfoRow($r('sys.symbol.gearshape'), '服务器版本', this.current !== null ? this.current.version : '—')
          }.width('100%').backgroundColor(this.P().card).borderRadius(16).clip(true)

          this.settingsGroupTitle('开发者')
          Column() {
            this.settingsActionRow($r('sys.symbol.gearshape'), '材质探针（Debug）', '', () => {
              router.pushUrl({ url: 'pages/CapabilityProbe' }).catch(() => {});
            })
          }.width('100%').backgroundColor(this.P().card).borderRadius(16)
          Column().height(110)
        }.width('100%').padding({ left: 16, right: 16 })
      }.scrollBar(BarState.Off).layoutWeight(1).width('100%').align(Alignment.TopStart)
    }
    .width('100%').height('100%').backgroundColor(this.P().bg)
    .padding({ top: 198 })

  }

  private rootServerSummary(): string {
    if (this.current === null) { return '未连接'; }
    return this.sourceDisplayName(this.current);
  }

  @Builder
  appearanceSheet() {
    Column() {
      Scroll() {
          Column() {
            // 外观模式（三选一胶囊）
            Row() {
              Column() {
                Text('外观模式').fontSize(15).fontColor(this.P().text)
                Text('深色 / 浅色 / 跟随系统')
                  .fontSize(11).fontColor(this.P().textDim).margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              ForEach(this.themeOptions, (opt: string) => {
                Text(opt)
                  .fontSize(11)
                  .fontColor(this.themeMode === this.themeKey(opt) ? '#FFFFFF' : this.P().textDim)
                  .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                  .backgroundColor(this.themeMode === this.themeKey(opt) ? this.P().accent : this.P().chip)
                  .borderRadius(Radius.chip)
                  .margin({ left: 6 })
                  .focusable(true)
                  .clickEffect(MotionFx.press())
                  .onClick(() => {
                    const k = this.themeKey(opt);
                    this.themeMode = k;
                    // ★ 必须存盘，否则重启就丢（之前只改内存）
                    Theme.setMode(k);
                    Store.set('themeMode', k);
                  })
              }, (opt: string) => opt)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })

            Divider().color(this.P().divider).strokeWidth(0.5)

            // ★ 应用主题色
            Column() {
              Row() {
                Column() {
                  Text('应用主题色').fontSize(15).fontColor(this.P().text)
                  Text('设置主题色与悬浮导航光效')
                    .fontSize(11).fontColor(this.P().textDim).margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .margin({ bottom: 10 })

              Row() {
                ForEach(Theme.ACCENTS, (c: string) => {
                  Stack() {
                    if (Theme.accent() === c) {
                      SymbolGlyph($r('sys.symbol.checkmark'))
                        .fontSize(14)
                        .fontColor(['#FFFFFF'])
                    }
                  }
                  .width(34)
                  .height(34)
                  .borderRadius(17)
                  .backgroundColor(c)
                  .border({
                    width: Theme.accent() === c ? 2.5 : 0,
                    color: withAlpha('#FFFFFF', 0.9),
                    radius: 17
                  })
                  .margin({ right: 10 })
                  .focusable(true)
                  .onHover((isHover: boolean) => {})
                  .onClick(() => {
                    Theme.setAccent(c);
                  })
                }, (c: string) => c)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .alignItems(HorizontalAlign.Start)

            Divider().color(this.P().divider).strokeWidth(0.5)

            this.settingsActionRow($r('sys.symbol.lock'), '服务器密码', this.protectedServerCount(), () => {
              this.ensureSubpage('settings:lock');
            })
            Divider().color(this.P().divider).strokeWidth(0.5)

            this.settingsInfoRow($r('sys.symbol.rectangle_on_rectangle'), '导航栏样式', '悬浮页签')
          }
          .width('100%')
          .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
          .backgroundColor(this.P().card)
          .borderRadius(Radius.card)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 14, bottom: 24 })
  }

  @Builder
  settingsGroupTitle(title: string) {
    Text(title).fontSize(9).lineHeight(14).fontColor(this.P().section)
      .width('100%').padding({ left: 16, top: 32, bottom: 8 })
  }

  @Builder
  settingsDivider() {
    Divider().color(this.P().divider).strokeWidth(0.5).margin({ left: 54, right: 4 })
  }

  @Builder
  settingsActionRow(icon: Resource, label: string, value: string, action: () => void) {
    Row() {
      SymbolGlyph(icon).fontSize(18).fontColor([this.P().textDim]).width(18)
      Text(label).fontSize(11).fontColor(this.P().text).margin({ left: 18 }).layoutWeight(1)
      if (value.length > 0) {
        Text(value).fontSize(9).fontColor(this.P().textFaint).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '42%' }).margin({ right: 8 })
      }
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(9).fontColor([this.P().textFaint])
    }.width('100%').height(48).padding({ left: 18, right: 12 })
    .focusable(true).clickEffect(MotionFx.pressSoft()).onClick(action)
  }

  @Builder
  settingsInfoRow(icon: Resource, label: string, value: string) {
    Row() {
      SymbolGlyph(icon).fontSize(18).fontColor([this.P().textDim]).width(18)
      Text(label).fontSize(11).fontColor(this.P().text).margin({ left: 18 }).layoutWeight(1)
      Text(value).fontSize(9).fontColor(this.P().textFaint).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '52%' })
    }.width('100%').height(48).padding({ left: 18, right: 16 })
  }

  @State private showAppearanceSheet: boolean = false;

  @State colorWeak: boolean = false;
  @State settingsTab: number = 0;

  private themeOptions: string[] = ['深色', '浅色', '跟随系统'];

  private themeKey(opt: string): string {
    if (opt === '深色') {
      return ThemeMode.DARK;
    }
    if (opt === '浅色') {
      return ThemeMode.LIGHT;
    }
    return ThemeMode.SYSTEM;
  }

  @Builder
  groupTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor(this.P().section)
      .width('100%')
      .padding({ left: 4, top: 22, bottom: 8 })
  }

  @Builder
  navRowClick(label: string, desc: string, action: () => void) {
    Row() {
      Text(label).fontSize(15).fontColor(this.P().text)
      Blank()
      Text(desc).fontSize(11).fontColor(this.P().textDim).margin({ right: 6 }).maxLines(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13).fontColor([this.P().textDim])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .borderRadius(8)
    .focusable(true)
    .onHover((h: boolean) => {})
    .onClick(() => {
      action();
    })
  }

  @Builder
  navRow(label: string, desc: string) {
    Row() {
      Text(label).fontSize(15).fontColor(this.P().text)
      Blank()
      Text(desc).fontSize(11).fontColor(this.P().textDim).margin({ right: 6 }).maxLines(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13).fontColor([this.P().textDim])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .focusable(true)
  }

  @Builder
  settingRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(15).fontColor(this.P().text)
      Blank()
      Text(value).fontSize(12).fontColor(this.P().textDim).maxLines(1)
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
  }

  /* ── 海报网格（Vision / 收藏）── */
  /* ══════════ 下载管理页 ══════════ */

  @Builder
  downloadView() {
    Column() {
      if (this.downloads.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.square_and_arrow_down'))
            .fontSize(Metrics.f(46))
            .fontColor([this.P().textFaint])
            .opacity(0.5)
          Text('还没有下载')
            .fontSize(Metrics.f(14))
            .fontColor(this.P().textDim)
            .margin({ top: 14 })
          Text('在详情页点「下载」把影片存到本地')
            .fontSize(Metrics.f(11))
            .fontColor(this.P().textFaint)
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.downloads, (rec: DownloadRecord) => {
            ListItem() {
              Row() {
                Column() {
                  Text(rec.title)
                    .fontSize(Metrics.f(14))
                    .fontColor(this.P().text)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (rec.subtitle.length > 0) {
                    Text(rec.subtitle)
                      .fontSize(Metrics.f(11))
                      .fontColor(this.P().textDim)
                      .maxLines(1)
                      .margin({ top: 2 })
                  }
                  // 进度
                  if (rec.state === DownloadState.RUNNING) {
                    Stack({ alignContent: Alignment.Start }) {
                      Row()
                        .width('100%')
                        .height(3)
                        .backgroundColor(this.P().chip)
                        .borderRadius(2)
                      Row()
                        .width((rec.progressRatio() * 100).toFixed(1) + '%')
                        .height(3)
                        .backgroundColor(this.P().accent)
                        .borderRadius(2)
                    }
                    .width('100%')
                    .height(3)
                    .margin({ top: 8 })
                    Text(DownloadManager.fmtSize(rec.receivedBytes) + ' / ' +
                      DownloadManager.fmtSize(rec.totalBytes) + '  ' +
                      (rec.progressRatio() * 100).toFixed(0) + '%')
                      .fontSize(Metrics.f(10))
                      .fontColor(this.P().textDim)
                      .margin({ top: 4 })
                  } else if (rec.state === DownloadState.DONE) {
                    Text('已完成 · ' + DownloadManager.fmtSize(rec.totalBytes))
                      .fontSize(Metrics.f(10))
                      .fontColor('#3CC46A')
                      .margin({ top: 6 })
                  } else if (rec.state === DownloadState.FAILED) {
                    Text(rec.error.length > 0 ? rec.error : '下载失败')
                      .fontSize(Metrics.f(10))
                      .fontColor('#FF6B6B')
                      .margin({ top: 6 })
                  } else {
                    Text('等待中...')
                      .fontSize(Metrics.f(10))
                      .fontColor(this.P().textDim)
                      .margin({ top: 6 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (rec.state === DownloadState.DONE) {
                  Text('播放')
                    .fontSize(Metrics.f(12))
                    .fontColor('#FFFFFF')
                    .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                    .backgroundColor(this.P().accent)
                    .borderRadius(14)
                    .focusable(true)
                    .clickEffect(MotionFx.press())
                    .onClick(() => {
                      this.playDownloaded(rec);
                    })
                    .margin({ left: 10 })
                }

                Text('删除')
                  .fontSize(Metrics.f(12))
                  .fontColor(this.P().textDim)
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .focusable(true)
                  .clickEffect(MotionFx.press())
                  .onClick(() => {
                    this.removeDownload(rec);
                  })
                  .margin({ left: 6 })
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
            }
          }, (rec: DownloadRecord) => rec.itemId)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
        .divider({ strokeWidth: 0.5, color: this.P().divider })
      }

      Column().height(Metrics.s(40))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.P().bg)
    .padding({ top: 110 })
  }

  /* ══════════ Vision 页面 ══════════ */

  @Builder
  visionView() {
    VisionPage({ servers: this.visionSources(), active: this.visionContextVisible('vision'),
      revision: this.visionRevision, darkMode: this.dark(), safeTopVp: this.safeTopVp,
      bottomInsetVp: this.dockBottomGap() + 88,
      onPlay: (server: ServerConfig, item: MediaItem) => this.openVisionItem(server, item, true),
      onOpenDetail: (server: ServerConfig, item: MediaItem) => this.openVisionItem(server, item, false),
      onBrowse: () => { this.openVisionBrowse(); } })
  }

  private visionActionGeneration: number = 0;

  private visionSources(): ServerConfig[] {
    const source = this.current;
    if (source === null) { return []; }
    const option = this.serverOption(source.id);
    return option.hidden || option.locked || option.error.length > 0 ? [] : [source];
  }

  private visionContext(): string {
    const names = this.stackNames();
    if (names.length === 0 && this.currentTab === 1) { return 'vision'; }
    return names.length > 0 && names[names.length - 1] === 'settings:subscriptions' ? 'settings:subscriptions' : '';
  }

  private visionContextVisible(context: string): boolean {
    return this.homeScrollMounted && this.homeScrollPageVisible && this.appActive && !this.showAdd && this.visionContext() === context;
  }

  private openVisionBrowse(): void {
    const context = this.visionContext();
    if (context.length === 0 || !this.visionContextVisible(context)) { return; }
    if (context === 'settings:subscriptions') { this.popNamed('settings:subscriptions'); }
    this.selectTab(this.visionSources().length > 0 ? 0 : 3);
  }

  private async openVisionItem(server: ServerConfig, item: MediaItem, play: boolean): Promise<void> {
    const context = this.visionContext(); const current = this.current;
    if (current === null || context.length === 0 || !this.visionContextVisible(context)) { return; }
    const scope = SourceIdentity.scope(current);
    if (SourceIdentity.scope(server) !== scope) { return; }
    const generation = ++this.visionActionGeneration;
    const stillCurrent = (): boolean => generation === this.visionActionGeneration && this.visionContextVisible(context)
      && this.current !== null && SourceIdentity.scope(this.current) === scope;
    const options = await ServerOptions.get(current.id);
    if (!stillCurrent() || options.hidden || options.error.length > 0) { return; }
    if (!(await this.serverGate(current)) || !stillCurrent()) { return; }
    if (play && item.isPlayable()) { await this.playItem(item); } else { await this.openDetail(item); }
  }


  @Builder
  gridView() {
    Column() {
      if (this.favoritesError.length > 0) {
        Row({ space: 12 }) {
          Text(this.favoritesError).fontSize(13).fontColor(this.P().textDim).layoutWeight(1)
          Button('重试').fontSize(13).enabled(!this.favoritesLoading).onClick(() => { this.loadFavorites(true); })
        }.width('100%').padding({ left: Metrics.pagePad(), right: Metrics.pagePad(), top: 8, bottom: 8 })
      } else if (this.favoritesLoading && this.visibleFavorites().length > 0) {
        Text('正在刷新收藏…').fontSize(12).fontColor(this.P().textDim).padding({ top: 8, bottom: 8 })
      }
      if (this.visibleFavorites().length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(46)
            .fontColor([this.P().textFaint])
            .opacity(0.5)
          Text(this.current === null ? '请先选择服务器' : this.favoritesLoading ? '正在读取收藏…'
            : this.favoritesError.length > 0 ? '暂时无法读取收藏' : '还没有收藏的影片')
            .fontSize(15)
            .fontColor(this.P().textDim)
            .margin({ top: 14 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // This TabContent always belongs to favorites, even while another tab is visible.
        Grid() {
          ForEach(this.visibleFavorites(), (item: MediaItem) => {
            GridItem() {
              Column() {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  if (item.hasPrimaryImage && this.current !== null) {
                    NetImage({ url: MediaServices.imageUrl(this.current as ServerConfig, item.id, 360, item.imageTag), headers: this.imageHeadersOrEmpty() })
                      .width('100%')
                      .height('100%')
                  } else {
                    Column()
                      .width('100%')
                      .height('100%')
                      .backgroundColor(this.dark() ? withAlpha('#FFFFFF', 0.06) : withAlpha('#000000', 0.05))
                  }
                  // 评分角标
                  if (item.rating > 0) {
                    Text(item.rating.toFixed(1))
                      .fontSize(10)
                      .fontColor(this.P().star)
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .backgroundColor(withAlpha('#000000', 0.62))
                      .borderRadius(4)
                      .margin({ right: 5, bottom: 5 })
                  }
                  // 进度条
                  if (item.progressRatio() > 0.005) {
                    Stack({ alignContent: Alignment.Start }) {
                      Row().width('100%').height(3).backgroundColor(withAlpha('#000000', 0.5))
                      Row()
                        .width((item.progressRatio() * 100).toFixed(1) + '%')
                        .height(3)
                        .backgroundColor(this.P().accent)
                    }
                    .width('100%')
                    .height(3)
                  }
                }
                .width('100%')
                .aspectRatio(0.667)
                .borderRadius(Radius.poster)
                .clip(true)

                Text(item.name)
                  .fontSize(12)
                  .fontColor(this.P().text)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 6 })
                  .width('100%')

                if (item.year > 0) {
                  Text(item.year.toString())
                    .fontSize(10)
                    .fontColor(this.P().textDim)
                    .margin({ top: 2 })
                    .width('100%')
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .focusable(true)
              .clickEffect(MotionFx.press())
              .onClick(() => {
                if (item.isPlayable()) {
                  this.playItem(item);
                } else {
                  this.openDetail(item);
                }
              })
            }
          }, (item: MediaItem) => item.id)
        }
        .columnsTemplate(this.gridTemplate())
        .columnsGap(9)
        .rowsGap(16)
        .padding({ left: Metrics.pagePad(), right: Metrics.pagePad() })
        .layoutWeight(1)
      }

      Column().height(100)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.P().bg)
    .padding({ top: 110 })
  }
  allItems(): MediaItem[] {
    const out: MediaItem[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const items = this.rows[i].items;
      for (let j = 0; j < items.length; j++) {
        out.push(items[j]);
      }
    }
    return out;
  }
}
