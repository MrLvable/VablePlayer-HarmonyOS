import { PlaybackPreferences } from '../common/PlaybackPreferences';
import { router, PiPWindow, window, promptAction } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { audio } from '@kit.AudioKit';
import { PlayParams, SubtitleTrack, TrackInfo, MediaItem, MediaSource, ServerConfig } from '../common/Models';
import { Store } from '../common/Store';
import { MediaServices } from '../common/services/MediaServices';
import { NetImage } from '../components/NetImage';
import { ProgressRepository, ProgressRecordV2 } from '../common/ProgressRepository';
import { withAlpha } from '../common/Theme';
import { Metrics } from '../common/Metrics';
import { Materials } from '../common/Materials';
import { MotionSpec, MotionCurve, MotionPref } from '../common/MotionSpec';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RangeDataSource } from '../common/RangeDataSource';
import { NativePlaybackSession } from '../common/services/MediaService';
import { PlaybackHandle } from '../common/PlaybackHandle';
import { AvPlayerHandle } from '../common/AvPlayerHandle';
import { MpvAdapter } from '../common/MpvAdapter';
import { RangeStreamProxy } from '../common/RangeStreamProxy';
import { image } from '@kit.ImageKit';
import { picker } from '@kit.CoreFileKit';
import { PlaybackNavigation, PlaybackTarget } from '../common/PlaybackNavigation';
import { PlaybackQueueResolver } from '../common/PlaybackQueueResolver';
import { SourcePlaybackLeases } from '../common/SourcePlaybackLeases';
import { SourcePlaybackPolicy } from '../common/SourcePlaybackPolicy';
import { AiSubtitleSettings } from '../components/AiSubtitleSettings';
import { AiSubtitleWorkbench } from '../components/AiSubtitleWorkbench';
import { AiSubtitleCue, AiSubtitleError } from '../common/ai/AiSubtitleModels';
import { SubtitleFileCodec } from '../common/ai/SubtitleFileCodec';
import { util } from '@kit.ArkTS';
import { AiSubtitleSession, AiPlaybackInput } from '../common/ai/AiSubtitleSession';
import { NativeAudioExtractor } from '../common/ai/NativeAudioExtractor';

/**
 * 播放页 —— 网络及持久授权文件使用 mpv，已有本地下载保留 AVPlayer。
 *
 * 功能对齐 HosPlayer：
 *  · 硬解渲染（XComponent surface）
 *  · 后台播放（AVSession：锁屏/控制中心可控制）
 *  · 画中画（PiPWindow）
 *  · 字幕切换（外挂 + 内封）
 *  · 续播回跳
 *  · ±15s、进度条
 */
@Entry
@Component
struct PlayerPage {
  @State videoUrl: string = '';
  /** 播放目标是下载管理保存的本地文件（兼容旧下载文件名）。 */
  private localFileMode: boolean = false;
  /** 期望的续播位置（R05/A7）：fallback 后必须原样带到新实例 */
  private desiredResumeMs: number = 0;
  /**
   * 播放会话代次（方案 R03/A3）。
   * 每次释放/切源都 +1；createAVPlayer 等 await 之后校验，
   * 过期就立刻 release 那个新实例，不赋给 this.player —— 否则退出后还会复活发声。
   */
  private playbackGen: number = 0;
  /** 上次写盘的时间戳，10 秒节流用（R05/A7） */
  private lastSaveAt: number = 0;
  private lastProviderReportAt: number = 0;
  /** 串行化创建，防止两个同时 await 中的 createAVPlayer */
  private creatingPromise: Promise<void> | null = null;
  /** 片源实际编码（用于卡死提示展示） */
  @State private sourceCodecs: string = '';
  /** 进入播放器时缓存主窗口：退出时要恢复竖屏，此时再 getContext 往往已失效 */
  private winRef: window.Window | null = null;
  private systemBarRevision: number = 0;
  private systemBarTask: Promise<void> = Promise.resolve();
  /** R26：PiP 是否收到 STARTED 状态回调 */
  private pipStarted: boolean = false;
  /** R25：横向手势的起点 x，用来做边缘避让（判起点而不是终点） */
  private panStartX: number = -1;
  private fdReadOnly: fs.File | null = null;
  private localFileSize: number = 0;
  /** 创建下一会话前等待旧播放器和流连接全部关闭。 */
  private pendingRelease: Promise<void> | null = null;
  private rangeDataSource: RangeDataSource | null = null;
  private fallbackPlayback: NativePlaybackSession | null = null;
  @State private activeIsHls: boolean = false;
  @State private activeNativeStream: boolean = false;
  /** 保持同步回读描述符存活，直到 AVPlayer 完成 release。 */
  private activeDataDescriptor: media.AVDataSrcDescriptor | null = null;
  private streamRetryCount: number = 0;
  private retryingStream: boolean = false;
  @State private streamHint: string = '';
  @State private hasRenderedFrame: boolean = false;
  @State private isBuffering: boolean = false;
  @State authToken: string = '';
  private nativeAuthToken: string = '';
  private activeAuthToken: string = '';
  private serviceKind: string = 'fnos';
  private initialStreamHeaders: Record<string, string> = {};
  private initialHeadersProvided: boolean = false;
  private playbackLeaseId: string = '';
  private sourceRouteError: boolean = false;
  @State private isLiveStream: boolean = false;
  @State title: string = '';
  @State subtitle: string = '';
  @State isPlaying: boolean = false;
  @State playPos: number = 0;
  @State duration: number = 0;
  @State showBar: boolean = true;
  @State errMsg: string = '';
  @State private loadingFirstFrame: boolean = true;
  @State info: string = '';
  @State startTicks: number = 0;
  /** 恢复观看进度只 seek 一次 */
  private resumeSeeked: boolean = false;
  /** 已发起续播 seek，等待 seekDone 后才起播 */
  private resumeSeekPending: boolean = false;
  /** 诊断：setupPlayer 被调用次数 */
  private setupCount: number = 0;
  /** 卡死看门狗定时器 */
  private watchdogId: number = -1;
  private lastSamplePos: number = -1;
  private lastSeekTarget: number = -1;
  private lastSeekAt: number = 0;
  private seekPending: boolean = false;
  private queuedSeekTarget: number = -1;
  private sourceStartedAt: number = 0;
  private lastProgressAt: number = 0;
  private lastPositionLogAt: number = 0;
  @State isHls: boolean = false;
  @State itemId: string = '';
  // 进度 V2 的来源身份
  @State private reqServerId: string = '';
  @State private reqUserId: string = '';
  @State private reqItemType: string = '';
  @State private reqSeriesId: string = '';
  @State private reqSeason: number = 0;
  @State private reqEpisode: number = 0;
  @State private reqImageTag: string = '';

  // 方向与画面比例（★ 播放器强制横屏，不做竖屏播放）
  @State private isLandscape: boolean = true;
  @State private fitCrop: boolean = false;
  @State private videoW: number = 0;
  @State private videoH: number = 0;

  // 控制层按真实播放窗口布局，避免手机横屏被全局大屏倍率再次放大。
  @State private hudWidth: number = 0;
  @State private hudHeight: number = 0;
  @State private hudSafeLeft: number = 0;
  @State private hudSafeRight: number = 0;
  @State private hudSafeBottom: number = 0;
  @State private hudSafeTop: number = 0;

  // 控制栏自动隐藏
  @State private barOpacity: number = 1;
  // 进度条拖拽（方案 8.4）
  @State private isScrubbing: boolean = false;
  @State private scrubPos: number = 0;
  private hideTimer: number = -1;

  // 手势
  @State private speed: number = 1.0;
  @State @Watch('onNativeOverlayChange') private showSpeedPanel: boolean = false;
  @State @Watch('onNativeOverlayChange') private showRatioPanel: boolean = false;
  @State @Watch('onNativeOverlayChange') private showCastPanel: boolean = false;
  @State private screenRatioMode: string = '默认';
  @State private subtitleMenuPage: number = 0;
  @State @Watch('onNativeOverlayChange') private showSubtitleStyle: boolean = false;
  @State private subtitleScale: number = 1;
  @State private loadingBeat: boolean = false;
  private loadingPulseMounted: boolean = false;
  private loadingPulsePageVisible: boolean = true;
  private loadingPulseStarted: boolean = false;
  private loadingPulseTask: number = -1;
  private loadingPulseGeneration: number = 0;
  @State private technicalFields: string[] = ['', '', '', '', '', ''];
  @State @Watch('onNativeOverlayChange') private showAiPanel: boolean = false;
  @State private showAiSettings: boolean = false;
  @State private showAiWorkbench: boolean = false;
  @State private aiEnabled: boolean = false;
  @State private aiBusy: boolean = false;
  @State private aiBilingual: boolean = false;
  @State private aiStatus: string = '自动翻译字幕，无内封文本时识别原声';
  @State private aiOriginal: string = '';
  @State private aiTranslated: string = '';
  @State private aiConfigurationPurpose: string = 'translation';
  private aiSession: AiSubtitleSession | null = null;
  private aiRevision: number = 0;
  private aiNativeSubtitleBefore: number = -1;
  private aiFileCues: AiSubtitleCue[] = [];
  private externalSubtitleCues: AiSubtitleCue[] = [];
  @State private externalSubtitleName: string = '';
  private externalSubtitleImportGen: number = 0;
  private aiSeekSuspended: boolean = false;
  private aiRequested: boolean = false;
  private aiSettingsResumeGen: number = -1;
  private aiConfigurationPrompted: boolean = false;
  @State private locked: boolean = false;
  @State private gestureHint: string = '';
  @State private hintVisible: boolean = false;
  @State private seekGestureVisible: boolean = false;
  @State private seekGestureTarget: number = 0;
  @State private seekGestureDelta: number = 0;
  private seekGestureStart: number = 0;
  private hintTimer: number = -1;
  private lastTapTime: number = 0;

  // 亮度/音量（手势用）
  @State private brightnessVal: number = -1;
  @State private volumeVal: number = -1;
  // 手势基准值（方案 8.3：所有计算基于本次手势开始值）
  private gLastY: number = 0;
  private gBaseBrightness: number = 128;
  private gBaseVolume: number = 60;
  private boostPrev: number = 1.0;
    private brightnessMax: number = 255;

  @State subtitles: SubtitleTrack[] = [];
  @State curSubtitle: number = -1;
  private subtitleSelectionGen: number = 0;
  private nativeSubtitleIndices: number[] = [];
  /* ══════════ R21 大侧栏（播放列表 / 视频源）══════════
   * 方案 §9.4：播放列表与视频源共用一个容器，只有内容不同；
   * 宽 = 横屏宽 * 0.40，translateX = panelW*(1-progress)，外部 scrim 跟 progress。
   */
  @State @Watch('onNativeOverlayChange') private showSidePanel: boolean = false;
  @State private sideMode: number = 0;        // 0=播放列表 1=视频源
  @State private sideProgress: number = 0;    // 0..1
  private sideAnimationGen: number = 0;
  /** Invalidates native dismissal callbacks whenever an overlay changes or another one opens. */
  private nativeOverlayRevision: number = 0;
  private nativeOverlaySyncing: boolean = false;
  @State private episodes: MediaItem[] = [];
  @State private panelServer: ServerConfig | null = null;
  @State private failedEpisodeImages: string[] = [];
  private panelMounted: boolean = false;
  @State private sources: MediaSource[] = [];
  @State private sideQualityFilter: string = '';
  @State private selectedSourceId: string = '';  @State @Watch('onNativeOverlayChange') showSubPanel: boolean = false;
  @State private switchingPlayback: boolean = false;
  private resolvingNavigation: boolean = false;
  private navigationGen: number = 0;
  private completionHandledGen: number = -1;
  private playbackQueueRequest: Promise<MediaItem[]> | null = null;
  private playbackQueueKey: string = '';
  private playbackQueueReadyKey: string = '';
  @State private autoAdvancing: boolean = false;
  @State private autoNextPending: boolean = false;
  private pendingSelectedSourceId: string = '';

  @State audioTracks: TrackInfo[] = [];
  @State curAudio: number = -1;
  @State @Watch('onNativeOverlayChange') showAudioPanel: boolean = false;

  private player: PlaybackHandle | null = null;
  private session: avSession.AVSession | null = null;
  private pipCtl: PiPWindow.PiPController | null = null;
  private surfaceId: string = '';
  private xc: XComponentController = new XComponentController();
  private timerId: number = -1;
  private useMpvEngine: boolean = false;
  private mpvSurfaceAdapter: MpvAdapter | null = null;
  private streamProxy: RangeStreamProxy | null = null;
  @State private surfaceMounted: boolean = true;
  @State private playbackProgressReady: boolean = false;

  private loadingPulseAllowed(): boolean {
    return this.panelMounted && this.loadingPulseMounted && this.loadingPulsePageVisible
      && (this.loadingFirstFrame || this.isBuffering) && this.errMsg.length === 0;
  }

  private queueLoadingPulse(): void {
    if (!this.loadingPulseAllowed() || this.loadingPulseStarted || this.loadingPulseTask >= 0) { return; }
    const generation = this.loadingPulseGeneration;
    this.loadingPulseTask = setTimeout(() => {
      if (generation !== this.loadingPulseGeneration) { return; }
      this.loadingPulseTask = -1;
      if (!this.loadingPulseAllowed()) { return; }
      this.loadingPulseStarted = true;
      // Only the deferred turn writes State; onAppear/onDisAppear can run in render.
      // The native implicit animation owns repetition and ends with its removed node.
      this.loadingBeat = !this.loadingBeat;
    }, MotionSpec.imageReadyFrame);
  }

  private cancelLoadingPulse(): void {
    this.loadingPulseGeneration++;
    if (this.loadingPulseTask >= 0) { clearTimeout(this.loadingPulseTask); this.loadingPulseTask = -1; }
    this.loadingPulseStarted = false;
  }

  private onLoadingPulseAppear(): void {
    if (this.loadingPulseMounted) { return; }
    this.loadingPulseMounted = true;
    this.queueLoadingPulse();
  }

  private onLoadingPulseDisappear(): void {
    this.loadingPulseMounted = false;
    this.cancelLoadingPulse();
  }

  onPageShow(): void {
    this.loadingPulsePageVisible = true;
    this.queueLoadingPulse();
  }

  onPageHide(): void {
    this.loadingPulsePageVisible = false;
    this.cancelLoadingPulse();
  }

  aboutToAppear(): void {
    this.panelMounted = true;
    const defaults = PlaybackPreferences.current();
    this.screenRatioMode = defaults.ratio; this.subtitleScale = defaults.subtitleScale;
    this.fitCrop = defaults.ratio === '平铺' || defaults.ratio === '裁切';
    this.loadingPulsePageVisible = true;
    // ★ 播放器一律横屏（竖屏下 16:9 的视频只能显示一条，体验差）
    this.isLandscape = true;
    this.loadingFirstFrame = true;
    this.setOrientation(true);
    // ★ 进入播放器隐藏状态栏与导航条（全屏观看）
    this.setPlayerStatusBarVisible(true);
    this.scheduleHideBar();
    const p = router.getParams() as PlayParams;
    if (p !== undefined && p !== null) {
      this.videoUrl = p.url !== undefined ? p.url : '';
    this.authToken = p.token !== undefined ? p.token : '';
    this.serviceKind = p.serviceKind !== undefined ? p.serviceKind : 'fnos';
    this.initialHeadersProvided = p.streamHeaders !== undefined;
    this.initialStreamHeaders = p.streamHeaders !== undefined ? p.streamHeaders : {};
    this.nativeAuthToken = p.nativeToken !== undefined && p.nativeToken.length > 0
      ? p.nativeToken : this.authToken;
    hilog.info(0x0001, 'NasPlay', 'playback credentials native=%{public}s distinct=%{public}s',
      p.nativeToken !== undefined && p.nativeToken.length > 0 ? 'Y' : 'N',
      this.nativeAuthToken !== this.authToken ? 'Y' : 'N');
    this.reqServerId = p.serverId !== undefined ? p.serverId : '';
    this.reqUserId = p.userId !== undefined ? p.userId : '';
    this.reqItemType = p.itemType !== undefined ? p.itemType : 'Episode';
    this.reqSeriesId = p.seriesId !== undefined ? p.seriesId : '';
    this.reqSeason = p.seasonNumber !== undefined ? p.seasonNumber : 0;
    this.reqEpisode = p.episodeNumber !== undefined ? p.episodeNumber : 0;
    this.reqImageTag = p.imageTag !== undefined ? p.imageTag : '';
      this.title = p.title !== undefined ? p.title : '';
      this.subtitle = p.subtitle !== undefined ? p.subtitle : '';
      this.startTicks = p.startTicks !== undefined ? p.startTicks : 0;
    this.desiredResumeMs = Math.floor(this.startTicks / 10000);
      this.isHls = p.isHls !== undefined ? p.isHls : false;
      this.itemId = p.itemId !== undefined ? p.itemId : '';
      this.subtitles = p.subtitles !== undefined ? p.subtitles : [];
      // R21/R22：侧栏数据（没有就是空，不做假数据）
      this.episodes = p.episodes !== undefined ? p.episodes : [];
      this.sources = p.sources !== undefined ? p.sources : [];
      this.selectedSourceId = p.selectedSourceId !== undefined ? p.selectedSourceId : '';
      this.isLiveStream = p.isLive === true || (p.isLive === undefined && this.reqItemType === 'Channel');
    }
    try {
      const leaseId = p !== undefined && p !== null && p.playbackLeaseId !== undefined ? p.playbackLeaseId : '';
      if (leaseId.length > 0) {
        if (!SourcePlaybackLeases.claim(leaseId)) { throw new Error('播放会话已失效，请返回重新打开影片'); }
        this.playbackLeaseId = leaseId;
      }
      this.useMpvEngine = SourcePlaybackPolicy.useMpv(this.serviceKind, this.videoUrl);
      if (this.isLiveStream) { this.startTicks = 0; this.desiredResumeMs = 0; this.duration = 0; }
    } catch (error) {
      this.sourceRouteError = true;
      this.errMsg = (error as Error).message;
      this.loadingFirstFrame = false;
      this.releaseAll('invalid-route');
      return;
    }
    if (this.useMpvEngine) {
      this.surfaceMounted = false;
      const gen = this.playbackGen;
      this.createMpvSurface().catch(() => {
        if (!this.panelMounted || gen !== this.playbackGen) { return; }
        this.errMsg = '播放器初始化失败，请返回后重试';
        this.loadingFirstFrame = false;
      });
    }
    this.loadPanelServer();
  }

  aboutToDisappear(): void {
    this.panelMounted = false;
    this.loadingPulsePageVisible = false;
    this.onLoadingPulseDisappear();
    this.navigationGen++;
    // R05/A7：退出立即保存（saveNow 内部有 playPos>5s 的有效性判断）
    this.saveNow();
    this.releaseAll('aboutToDisappear');
    // 退出播放器恢复竖屏，否则列表页横着显示
    // ★ 先同步用缓存的窗口发一次（不等 Promise），setOrientation 内部再兜底
    if (this.winRef !== null) {
      this.winRef.setPreferredOrientation(window.Orientation.PORTRAIT).catch(() => {
      });
    }
        this.setOrientation(false);
    // ★ 恢复系统栏，否则首页也会变成没有状态栏
    this.setSystemBarVisible(true);
  }

  /**
   * 写本地播放进度
   * ★ 飞牛服务器不保存播放位置（实测 Resume/IsResumable 全返回空），
   *   所以要自己在本地记，首页「继续播放」读这个
   */
  /**
   * 写观看进度 —— 走 V2 仓储（方案 9.2）。
   * ★ 旧实现把每条记录先 stringify 塞进 string[]，读取侧却当对象数组，
   *   导致 id 永远取不到、「继续观看」从未生效。
   */
  private saveLocalProgress(): Promise<void> {
    if (this.isLiveStream || this.itemId.length === 0) {
      return Promise.resolve();
    }
    const rec: ProgressRecordV2 = {
      serverId: this.reqServerId.length > 0 ? this.reqServerId : 'local',
      userId: this.reqUserId.length > 0 ? this.reqUserId : 'local',
      itemId: this.itemId,
      itemType: this.reqItemType,
      seriesId: this.reqSeriesId,
      title: this.title,
      episodeTitle: this.subtitle.length > 0 ? this.subtitle : this.title,
      seasonNumber: this.reqSeason,
      episodeNumber: this.reqEpisode,
      positionMs: this.playPos,
      durationMs: this.duration,
      updatedAt: Date.now(),
      completed: this.duration > 0 && this.playPos / this.duration >= 0.95,
      imageTag: this.reqImageTag
    };
    // 仓储内部会处理 <5s 不建记录、>=95% 清除
    return ProgressRepository.upsert(rec).catch(() => {
    });
  }

  /** 播放中每 10 秒落一次盘 */
  /**
   * 周期保存进度（方案 R05/A7）。
   * ★ 旧实现只有定义、**全工程零调用** —— 进程被杀就丢本次进度。
   *   现在由 timer 每 500ms 调一次，内部按 10 秒节流；
   *   暂停 / seekDone / 退出一律立即保存（见 saveNow）。
   */
  private saveProgressTick(): void {
    if (this.isLiveStream || this.playPos <= 5000 || this.duration <= 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastSaveAt < 10000) {
      return;
    }
    this.lastSaveAt = now;
    this.saveLocalProgress();
  }

  /** 立即保存（暂停 / seekDone / 后台 / 退出） */
  private saveNow(): void {
    if (this.isLiveStream || this.playPos <= 5000 || this.duration <= 0) {
      return;
    }
    // ★ 同步更新期望续播点（方案 R05/A7）：
    //   用户中途 seek 过，fallback 重开时应该从「当前真实播放点」恢复，
    //   而不是还回到最初进页面时的那个点。
    this.desiredResumeMs = this.playPos;
    this.lastSaveAt = Date.now();
    this.saveLocalProgress();
  }

  private reportProviderState(state: string): void {
    const serverId = this.reqServerId;
    const itemId = this.itemId;
    if (serverId.length === 0 || itemId.length === 0 || this.videoUrl.startsWith('/')) { return; }
    const position = this.isLiveStream ? 0 : Math.max(0, Math.floor(this.playPos * 10000));
    const duration = this.isLiveStream ? 0 : Math.max(0, Math.floor(this.duration * 10000));
    this.lastProviderReportAt = Date.now();
    const resolveServer = this.panelServer !== null && this.panelServer.id === serverId
      ? Promise.resolve(this.panelServer) : this.navigationServer();
    resolveServer.then((server: ServerConfig) => {
      if (server.id !== serverId) { return; }
      return MediaServices.reportPlaybackState(server, itemId, position, duration, state);
    }).catch(() => {});
  }



  /* ══════════ 播放器 ══════════ */

  async setupPlayer(): Promise<void> {
    if (this.creatingPromise !== null) {
      try { await this.creatingPromise; } catch (e) {}
    }
    if (!this.panelMounted || this.sourceRouteError || this.videoUrl.length === 0 || this.player !== null) {
      return;
    }
    const creating = this.doSetupPlayer();
    this.creatingPromise = creating;
    try {
      await creating;
    } finally {
      if (this.creatingPromise === creating) {
        this.creatingPromise = null;
      }
    }
  }

  private currentPlayer(gen: number, p: PlaybackHandle): boolean {
    return this.panelMounted && gen === this.playbackGen && this.player === p;
  }

  /** 官方媒体数据源接口读取远端 Range；HLS 使用带鉴权的 URL，本地文件使用 fdSrc。 */
  private async doSetupPlayer(): Promise<void> {
    if (this.pendingRelease !== null) {
      await this.pendingRelease;
    }
    if (!this.panelMounted || this.sourceRouteError || this.player !== null || this.videoUrl.length === 0) {
      return;
    }
    const gen = this.playbackGen;
    this.setupCount++;
    this.loadingFirstFrame = true;
    this.hasRenderedFrame = false;
    this.playbackProgressReady = false;
    this.isBuffering = false;
    this.lastSamplePos = -1;
    this.lastPositionLogAt = 0;
    this.localFileMode = this.videoUrl.startsWith('/');
    this.nativeSubtitleIndices = [];
    this.activeIsHls = this.isHls;
    this.activeNativeStream = false;
    this.activeAuthToken = this.authToken;
    this.startWatchdog(gen);
    hilog.info(0x0001, 'NasPlay', 'setup #%{public}d local=%{public}s hls=%{public}s retry=%{public}d',
      this.setupCount, this.localFileMode ? 'Y' : 'N', this.isHls ? 'Y' : 'N', this.streamRetryCount);
    let failureReason = '无法连接媒体流';
    try {
      if (this.useMpvEngine) { await this.doSetupMpv(gen); return; }
      let descriptor: media.AVDataSrcDescriptor | null = null;
      let playbackUrl = this.videoUrl;
      if (!this.localFileMode) { MediaServices.requireKind(this.serviceKind); }
      if (!this.localFileMode && this.serviceKind === 'fnos' && this.streamRetryCount === 1
        && !this.isHls) {
        failureReason = 'NAS 无法建立兼容播放会话';
        this.streamHint = '正在请求 NAS 兼容播放流…';
        const fallback = MediaServices.createNativePlayback(this.serviceKind);
        if (fallback === null) { throw new Error('当前服务器不支持原生播放会话'); }
        this.fallbackPlayback = fallback;
        const resolved = await fallback.resolve(this.videoUrl, this.nativeAuthToken, this.itemId);
        if (!this.panelMounted || gen !== this.playbackGen) {
          await fallback.close();
          return;
        }
        playbackUrl = resolved.url;
        this.activeIsHls = resolved.isHls;
        this.activeNativeStream = true;
        this.activeAuthToken = this.nativeAuthToken;
        failureReason = 'NAS 兼容播放流无法加载';
        this.streamHint = '正在加载 NAS 兼容播放流…';
        hilog.info(0x0001, 'NasPlay', 'fallback native source ready hls=%{public}s',
          this.activeIsHls ? 'Y' : 'N');
      }
      if (this.localFileMode) {
        failureReason = '本地下载文件不可用';
        const st = fs.statSync(this.videoUrl);
        if (st.size <= 0) {
          throw new Error('empty local file');
        }
        this.fdReadOnly = fs.openSync(this.videoUrl, fs.OpenMode.READ_ONLY);
        this.localFileSize = st.size;
      } else if (this.serviceKind === 'fnos' && !this.activeIsHls && !this.activeNativeStream) {
        failureReason = '无法读取远端媒体数据';
        this.streamHint = '正在读取媒体头部与索引…';
        const dataSource = new RangeDataSource();
        this.rangeDataSource = dataSource;
        descriptor = await dataSource.start(playbackUrl, this.activeAuthToken);
        if (!this.panelMounted || gen !== this.playbackGen) {
          await dataSource.close();
          return;
        }
        this.streamHint = '正在准备流式播放…';
        hilog.info(0x0001, 'NasPlay', 'official dataSource ready');
      }
      const p = new AvPlayerHandle(await media.createAVPlayer());
      if (!this.panelMounted || gen !== this.playbackGen || this.player !== null) {
        await p.release().catch(() => {});
        return;
      }
      this.player = p;
      this.wirePlayerEvents(gen, p);
      if (this.localFileMode && this.fdReadOnly !== null) {
        p.nativePlayer.fdSrc = { fd: this.fdReadOnly.fd, offset: 0, length: this.localFileSize };
      } else if (descriptor !== null) {
        // dataSrc 由 AVPlayer 持有 native 回调引用，避免临时 MediaSource 的引用生命周期。
        this.activeDataDescriptor = descriptor;
        p.nativePlayer.dataSrc = descriptor;
      } else {
        const headers = this.activeNativeStream
          ? SourcePlaybackPolicy.headers('fnos', undefined, this.activeAuthToken) : this.playbackHeaders();
        const source = media.createMediaSourceWithUrl(playbackUrl, headers);
        if (this.activeIsHls) { source.setMimeType(media.AVMimeTypes.APPLICATION_M3U8); }
        await p.nativePlayer.setMediaSource(source);
      }
      if (this.currentPlayer(gen, p)) { this.setupSession(); }
    } catch (e) {
      if (this.panelMounted && gen === this.playbackGen) {
        const err = e as BusinessError;
        this.handlePlaybackFailure(gen, failureReason,
          err.code !== undefined ? err.code : 0);
      }
    }
  }

  private activeSurfaceController(): XComponentController {
    return this.useMpvEngine && this.mpvSurfaceAdapter !== null ? this.mpvSurfaceAdapter.surfaceController : this.xc;
  }

  private playbackHeaders(): Record<string, string> {
    return SourcePlaybackPolicy.headers(this.serviceKind,
      this.initialHeadersProvided ? this.initialStreamHeaders : undefined, this.authToken);
  }

  private async createMpvSurface(): Promise<void> {
    const gen = this.playbackGen;
    if (!this.panelMounted) { return; }
    this.surfaceMounted = false;
    if (this.pendingRelease !== null) { await this.pendingRelease; }
    if (!this.panelMounted || gen !== this.playbackGen) { return; }
    // Let ArkUI remove the old XComponent before constructing another native
    // controller. A zero-delay task can still be coalesced into the same frame.
    await new Promise<void>((resolve) => { setTimeout(resolve, 32); });
    if (!this.panelMounted || gen !== this.playbackGen) { return; }
    const adapter = await MpvAdapter.create();
    if (!this.panelMounted || gen !== this.playbackGen) { await adapter.release(); return; }
    this.mpvSurfaceAdapter = adapter;
    this.surfaceMounted = true;
  }

  private async doSetupMpv(gen: number): Promise<void> {
    const p = this.mpvSurfaceAdapter;
    if (p === null || p.isReleased) { throw new Error('mpv surface unavailable'); }
    this.player = p;
    this.wirePlayerEvents(gen, p);
    let url = this.videoUrl;
    let headers: Record<string, string> = this.playbackHeaders();
    if (this.streamRetryCount > 0 && this.serviceKind === 'fnos'
      && this.videoUrl.indexOf('/v/api/v1/media/range/') >= 0) {
      this.streamHint = '正在重新连接媒体流（1/1）…';
      const proxy = new RangeStreamProxy();
      this.streamProxy = proxy;
      url = await proxy.start(this.videoUrl, this.authToken);
      if (!this.currentPlayer(gen, p)) { await proxy.close(); return; }
      headers = {};
      hilog.info(0x0001, 'NasPlay', 'mpv opening bounded loopback source');
    } else {
      hilog.info(0x0001, 'NasPlay', 'mpv opening direct source cache=32+8MiB disk=N');
    }
    await p.open(url, headers);
    if (this.currentPlayer(gen, p)) { this.setupSession(); }
  }

  private wirePlayerEvents(gen: number, p: PlaybackHandle): void {
      p.on('stateChange', (state: string) => {
        if (!this.currentPlayer(gen, p)) { return; }
        hilog.info(0x0001, 'NasPlay', 'state -> %{public}s', state);
        if (state === 'initialized') {
          this.prepareCurrent(gen, p);
        } else if (state === 'prepared') {
          this.startPreparedPlayback(gen, p);
        } else if (state === 'playing') {
          this.autoAdvancing = false; this.autoNextPending = false;
          this.isPlaying = true;
          this.reportProviderState('playing');
          this.errMsg = '';
          this.startTimer();
          this.scheduleHideBar();
          this.updateSession(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
        } else if (state === 'paused') {
          this.isPlaying = false;
          this.reportProviderState('paused');
          this.saveNow();
          this.updateSession(avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
        } else if (state === 'completed') {
          if (this.resolvingNavigation) { this.stopTimer(); this.isPlaying = false; return; }
          this.handlePlaybackCompleted(gen, p);
        } else if (state === 'error') {
          this.handlePlaybackFailure(gen, '播放器无法继续播放', 0);
        }
      });
      p.on('startRenderFrame', () => {
        if (!this.currentPlayer(gen, p)) { return; }
        this.hasRenderedFrame = true;
        this.loadingFirstFrame = false;
        this.isBuffering = false;
        this.streamHint = '';
        this.lastProgressAt = Date.now();
        this.logStreamStats('first-frame');
      });
      p.on('seekDone', (pos: number) => {
        if (!this.currentPlayer(gen, p)) { return; }
        hilog.info(0x0001, 'NasPlay', 'seekDone pos=%{public}d', pos);
        if (pos >= 0) { this.playPos = this.isLiveStream ? 0 : pos; }
        this.lastProgressAt = Date.now();
        this.lastSamplePos = pos;
        this.seekPending = false;
        this.resumeSeeked = true;
        if (this.resumeSeekPending) {
          this.resumeSeekPending = false;
          this.playCurrent(gen, p);
        } else { this.saveNow(); }
        if (this.queuedSeekTarget >= 0) {
          const target = this.queuedSeekTarget;
          this.queuedSeekTarget = -1;
          if (!this.requestSeek(target) && this.aiSeekSuspended) { this.resumeAiAfterSeek(this.playPos); }
        } else { this.resumeAiAfterSeek(this.playPos); }
      });
      p.on('bufferingUpdate', (type: media.BufferingInfoType, value: number) => {
        if (!this.currentPlayer(gen, p)) { return; }
        if (type === media.BufferingInfoType.BUFFERING_START) { this.isBuffering = true; }
        if (type === media.BufferingInfoType.BUFFERING_END) { this.isBuffering = false; }
        hilog.info(0x0001, 'NasPlay', 'buffering type=%{public}d value=%{public}d', type, value);
      });
      p.on('error', (e: BusinessError) => {
        if (!this.currentPlayer(gen, p)) { return; }
        if (p.state !== 'error') {
          // 官方契约：操作错误或瞬态流错误不等于播放器进入 error 状态。
          hilog.warn(0x0001, 'NasPlay', 'nonfatal player event code=%{public}d state=%{public}s', e.code, p.state);
          if (e.code === 5400102 || e.code === 5400104) {
            this.seekPending = false;
            this.queuedSeekTarget = -1;
            if (this.aiSeekSuspended) { this.resumeAiAfterSeek(p.currentTime); }
          }
          if (this.resumeSeekPending) {
            this.resumeSeekPending = false;
            promptAction.showToast({ message: '恢复进度失败，从当前进度播放' });
            this.playCurrent(gen, p);
          }
          return;
        }
        this.handlePlaybackFailure(gen, '片源播放失败', e.code);
      });
  }

  /** setPlaybackStrategy 仅在 initialized 调用，完成后才能 prepare。 */
  private async prepareCurrent(gen: number, p: PlaybackHandle): Promise<void> {
    if (!this.currentPlayer(gen, p) || p.engineKind !== 'avplayer') { return; }
    try {
      p.surfaceId = this.surfaceId;
      await p.setPlaybackStrategy({
        showFirstFrameOnPrepare: true,
        preferredHdr: false,
        // URL/HLS 使用系统下载缓冲；DataSource 的有界缓存由 RangeDataSource 管理。
        // 对自定义 MKV 数据源设置全轨道时长水位会让稀疏字幕队列阻止音视频消费。
        preferredBufferDuration: this.activeIsHls || this.activeNativeStream ? 20 : undefined,
        preferredBufferDurationForPlaying: this.activeIsHls || this.activeNativeStream ? 0.3 : undefined
      });
      if (!this.currentPlayer(gen, p)) { return; }
      await p.prepare();
    } catch (e) {
      if (this.currentPlayer(gen, p)) {
        const err = e as BusinessError;
        this.handlePlaybackFailure(gen, '无法准备片源', err.code !== undefined ? err.code : 0);
      }
    }
  }

  private async startPreparedPlayback(gen: number, p: PlaybackHandle): Promise<void> {
    if (!this.currentPlayer(gen, p)) { return; }
    if (this.pendingSelectedSourceId.length > 0) {
      this.selectedSourceId = this.pendingSelectedSourceId;
      this.pendingSelectedSourceId = '';
    }
    this.switchingPlayback = false;
    if (!this.isLiveStream && p.duration > 0) { this.duration = p.duration; }
    this.info = this.buildInfo();
    try {
      if (p instanceof MpvAdapter) {
        p.applyScreenRatio(this.screenRatioMode);
        p.setSubtitleScale(this.subtitleScale);
      } else {
        p.videoScaleType = this.fitCrop
          ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
          : media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
      }
    } catch (e) {}
    if (p.width > 0 && p.height > 0) { this.autoOrient(p.width, p.height); }
    await this.initializePreparedTracks(gen, p);
    if (!this.currentPlayer(gen, p)) { return; }
    if (p.engineKind === 'avplayer') {
      try { p.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE; } catch (e) {}
    }
    if (this.isLiveStream) {
      this.duration = 0; this.desiredResumeMs = 0; this.resumeSeeked = true;
      this.playCurrent(gen, p);
      return;
    }
    const resumeMs = Math.floor(this.desiredResumeMs);
    if (!this.resumeSeeked && resumeMs > 3000) {
      // FILE_LOADED can precede the package's duration snapshot. Do not discard a resume request.
      const waitUntil = Date.now() + 3000;
      while (this.currentPlayer(gen, p) && p.duration <= 0 && Date.now() < waitUntil) {
        await new Promise<void>((resolve) => { setTimeout(resolve, 50); });
      }
      if (!this.currentPlayer(gen, p)) { return; }
      if (p.duration <= 0) {
        this.handlePlaybackFailure(gen, '未能读取视频时长，无法恢复进度', 0); return;
      }
    }
    if (p.duration > 0) { this.duration = p.duration; }
    hilog.info(0x0001, 'NasPlay', 'prepared resume=%{public}d duration=%{public}d', resumeMs, this.duration);
    if (!this.resumeSeeked && resumeMs > 3000 && resumeMs < this.duration) {
      this.resumeSeeked = true;
      this.resumeSeekPending = true;
      try {
        if (!this.requestSeek(resumeMs)) {
          this.resumeSeekPending = false;
          this.playCurrent(gen, p);
        }
      } catch (e) {
        this.resumeSeekPending = false;
        this.playCurrent(gen, p);
      }
    } else {
      this.resumeSeeked = true;
      this.playCurrent(gen, p);
    }
  }

  /** prepared 时只读一次轨道描述；不切换或取消音频轨道。 */
  private async initializePreparedTracks(gen: number, p: PlaybackHandle): Promise<void> {
    const selection = this.subtitleSelectionGen;
    try {
      const descs = await p.getTrackDescription();
      if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
      let selected: number[] = [];
      let selectionKnown = true;
      try { selected = await p.getSelectedTracks(); } catch (e) {
        selectionKnown = false;
        hilog.warn(0x0001, 'NasPlay', 'selected tracks unavailable; metadata retained');
      }
      if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
      hilog.info(0x0001, 'NasPlay', 'tracks prepared selected=%{public}s count=%{public}d',
        selected.join(','), descs.length);
      const audioList: TrackInfo[] = [];
      const subtitleIndices: number[] = [];
      const embeddedSubtitles: SubtitleTrack[] = [];
      let selectedAudio = -1;
      let vCodec = '';
      let aCodec = '';
      for (let i = 0; i < descs.length; i++) {
        const d = descs[i];
        const kind = d['track_type'] as number;
        const idx = d['track_index'] as number;
        const mime = d['codec_mime'] as string;
        hilog.info(0x0001, 'NasPlay', 'track index=%{public}d type=%{public}d mime=%{public}s selected=%{public}s',
          idx, kind, mime !== undefined ? mime : '', selected.indexOf(idx) >= 0 ? 'Y' : 'N');
        if (kind === media.MediaType.MEDIA_TYPE_VID) {
          if (selected.indexOf(idx) >= 0 || (vCodec.length === 0 && mime !== 'png' && mime !== 'jpeg' && mime !== 'image/jpeg')) {
            vCodec = mime !== undefined ? mime : '';
          }
        } else if (kind === media.MediaType.MEDIA_TYPE_AUD) {
          const label = '音轨 ' + (audioList.length + 1).toString()
            + (mime !== undefined && mime.length > 0 ? ' · ' + mime : '');
          audioList.push(new TrackInfo(idx, label));
          if (selected.indexOf(idx) >= 0) { selectedAudio = idx; }
          if (selected.indexOf(idx) >= 0 || aCodec.length === 0) { aCodec = mime !== undefined ? mime : ''; }
        } else if (kind === media.MediaType.MEDIA_TYPE_SUBTITLE && idx >= 0) {
          subtitleIndices.push(idx);
          const language = d['language'] as string;
          const nativeTitle = d['title'] as string;
          const languageLabel = language !== undefined && language.length > 0 ? language : '';
          const label = nativeTitle !== undefined && nativeTitle.length > 0 ? nativeTitle
            : (languageLabel.length > 0 ? languageLabel : '内嵌字幕 ' + (embeddedSubtitles.length + 1).toString());
          embeddedSubtitles.push({ index: idx, language: languageLabel,
            title: label + (mime !== undefined && mime.length > 0 ? ' · ' + mime : ''), url: '', isExternal: false });
        }
      }
      this.audioTracks = audioList;
      this.curAudio = selectedAudio;
      this.nativeSubtitleIndices = subtitleIndices;
      const externalSubtitles = this.subtitles.filter((track: SubtitleTrack) => track.isExternal && track.url.length > 0);
      this.subtitles = embeddedSubtitles.concat(externalSubtitles);
      this.sourceCodecs = (vCodec + ' ' + aCodec).trim();
      if (this.curSubtitle < 0 && selectionKnown) {
        const selectedSubtitles: number[] = [];
        for (let i = 0; i < selected.length; i++) {
          if (subtitleIndices.indexOf(selected[i]) >= 0) { selectedSubtitles.push(selected[i]); }
        }
        this.curSubtitle = -2;
        if (await this.disableNativeSubtitles(gen, p, selectedSubtitles, selection)) {
          this.curSubtitle = -1;
        }
      } else if (!selectionKnown) {
        this.curSubtitle = -2;
      }
    } catch (e) {
      if (this.currentSubtitleSelection(gen, p, selection)) {
        const err = e as BusinessError;
        hilog.warn(0x0001, 'NasPlay', 'track initialization failed code=%{public}d',
          err.code !== undefined ? err.code : 0);
        if (this.curSubtitle < 0) { this.curSubtitle = -2; }
        promptAction.showToast({ message: '无法读取当前选中的轨道，字幕状态未更新' });
      }
    }
  }

  private async disableNativeSubtitles(gen: number, p: PlaybackHandle, indices: number[], selection: number = -1): Promise<boolean> {
    let success = true;
    for (let i = 0; i < indices.length; i++) {
      if (!this.currentSubtitleSelection(gen, p, selection)) { return false; }
      const idx = indices[i];
      try {
        await p.deselectTrack(idx);
        if (!this.currentSubtitleSelection(gen, p, selection)) { return false; }
        hilog.info(0x0001, 'NasPlay', 'subtitle deselect index=%{public}d result=ok', idx);
      } catch (e) {
        if (!this.currentSubtitleSelection(gen, p, selection)) { return false; }
        success = false;
        const err = e as BusinessError;
        hilog.warn(0x0001, 'NasPlay', 'subtitle deselect index=%{public}d code=%{public}d',
          idx, err.code !== undefined ? err.code : 0);
      }
    }
    if (this.currentSubtitleSelection(gen, p, selection) && !success) {
      promptAction.showToast({ message: '字幕关闭失败，保留当前字幕状态' });
    }
    return success && this.currentSubtitleSelection(gen, p, selection);
  }

  private currentSubtitleSelection(gen: number, player: PlaybackHandle, selection: number): boolean {
    return this.currentPlayer(gen, player) && (selection < 0 || selection === this.subtitleSelectionGen);
  }

  private playCurrent(gen: number, p: PlaybackHandle): void {
    p.play().then(() => {
      if (this.currentPlayer(gen, p) && this.aiRequested && this.aiSession === null && !this.aiBusy && this.aiSettingsResumeGen < 0) {
        this.startAiSubtitles();
      } else if (this.currentPlayer(gen, p) && !this.aiRequested && !this.aiBusy && this.aiSession === null
        && this.curSubtitle === -1 && this.externalSubtitleCues.length > 0) {
        this.aiFileCues = this.externalSubtitleCues; this.aiEnabled = true; this.updateAiFileCaption();
      }
    }).catch((e: BusinessError) => {
      if (this.currentPlayer(gen, p)) { this.handlePlaybackFailure(gen, '无法开始播放', e.code); }
    });
  }

  private logStreamStats(stage: string): void {
    const p = this.player;
    if (p instanceof MpvAdapter) {
      const native = p.core.surfaceController.native;
      hilog.info(0x0001, 'NasPlay', 'mpv %{public}s cacheBytes=%{public}d total=%{public}d eofCached=%{public}s',
        stage, Math.round(native.getProperty('demuxer-cache-state/total-bytes')),
        Math.round(native.getProperty('file-size')), native.getPropertyBool('demuxer-cache-state/eof-cached') ? 'Y' : 'N');
      if (this.streamProxy !== null) {
        const stats = this.streamProxy.getStats();
        hilog.info(0x0001, 'NasPlay', 'mpv proxy fetched=%{public}d total=%{public}d failures=%{public}d',
          stats.upstreamBytes, stats.totalBytes, stats.failures);
      }
    }
    const dataSource = this.rangeDataSource;
    if (dataSource === null) {
      hilog.info(0x0001, 'NasPlay', 'stream %{public}s hls=%{public}s position=%{public}d',
        stage, this.activeIsHls ? 'Y' : 'N', this.playPos);
      return;
    }
    const stats = dataSource.getStats();
    hilog.info(0x0001, 'NasPlay',
      'dataSource %{public}s fetched=%{public}d total=%{public}d cached=%{public}d requests=%{public}d reads=%{public}d misses=%{public}d failed=%{public}s',
      stage, stats.fetchedBytes, stats.totalBytes, stats.cachedBytes, stats.requests,
      stats.readCalls, stats.misses, stats.failed ? 'Y' : 'N');
  }

  private stopWatchdog(): void {
    if (this.watchdogId >= 0) {
      clearInterval(this.watchdogId);
      this.watchdogId = -1;
    }
  }

  private startWatchdog(gen: number): void {
    this.stopWatchdog();
    this.lastProgressAt = Date.now();
    this.sourceStartedAt = this.lastProgressAt;
    this.watchdogId = setInterval(() => {
      if (!this.panelMounted || gen !== this.playbackGen || this.errMsg.length > 0) { return; }
      if (this.isScrubbing || (this.player !== null && this.player.state === 'paused')) {
        this.lastProgressAt = Date.now();
        this.sourceStartedAt = this.lastProgressAt;
        return;
      }
      const ready = this.hasRenderedFrame || this.playbackProgressReady;
      const limit = ready ? 20000 : 30000;
      const since = ready ? this.lastProgressAt : this.sourceStartedAt;
      if (Date.now() - since >= limit) {
        this.handlePlaybackFailure(gen, ready ? '播放长时间没有推进' : '等待播放开始超时', 0);
      }
    }, 1000);
  }

  /** 每个路由会话至多重新建立一次流连接，失败后显示可操作的错误。 */
  private async handlePlaybackFailure(gen: number, reason: string, code: number): Promise<void> {
    if (!this.panelMounted || gen !== this.playbackGen || this.retryingStream || this.resolvingNavigation || this.errMsg.length > 0) { return; }
    const retry = !this.localFileMode && this.streamRetryCount < 1;
    this.retryingStream = true;
    this.logStreamStats('failure');
    hilog.info(0x0001, 'NasPlay', 'stream failure reason=%{public}s code=%{public}d retry=%{public}s',
      reason, code, retry ? 'Y' : 'N');
    this.desiredResumeMs = this.isLiveStream ? 0 : Math.max(this.desiredResumeMs, this.playPos);
    this.resumeSeeked = false;
    this.resumeSeekPending = false;
    // The retry/error page still owns this negotiated fd/session until it leaves.
    this.releaseAll(retry ? 'stream-retry' : 'stream-failed', true);
    const nextGen = this.playbackGen;
    if (retry) {
      this.streamRetryCount++;
      this.streamHint = '正在重新连接媒体流（1/1）…';
      this.loadingFirstFrame = true;
    } else {
      this.switchingPlayback = false;
      this.loadingFirstFrame = false;
      this.isBuffering = false;
      this.streamHint = '';
      this.errMsg = reason + (code !== 0 ? ' [' + code.toString() + ']' : '')
        + '。请检查来源连接，或返回详情页切换片源后重试。';
      this.showBar = true;
      this.barOpacity = 1;
      this.setPlayerStatusBarVisible(true);
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
    }
    try {
      if (this.pendingRelease !== null) { await this.pendingRelease; }
      if (retry && this.panelMounted && nextGen === this.playbackGen) {
        if (this.useMpvEngine) { await this.createMpvSurface(); }
        if (!this.panelMounted || nextGen !== this.playbackGen) { return; }
        this.retryingStream = false;
        await this.setupPlayer();
      }
    } catch (e) {
      if (this.panelMounted && nextGen === this.playbackGen) {
        this.loadingFirstFrame = false;
        this.isBuffering = false;
        this.errMsg = '重新连接失败，请检查来源连接后返回重试。';
      }
    } finally {
      if (nextGen === this.playbackGen) { this.retryingStream = false; }
    }
  }

  /**
   * 切换横竖屏
   * ★ 参考 SweetVideo：视频比屏幕宽就自动转横屏，用户也能手动切
   */
  /**
   * 播放器全屏时隐藏状态栏与底部导航条。
   *
   * EntryAbility 里全局设了 setWindowSystemBarEnable(['status','navigation'])
   * （首页需要保留状态栏），但播放器从来没关掉过 —— 所以播放时状态栏一直在。
   *
   * ★ 注意：这个 API 是窗口级的，退出播放器必须恢复，
   *   否则首页也会变成没有状态栏（之前就踩过这个坑）。
   */
  private async setSystemBarVisible(visible: boolean): Promise<void> {
    await this.applySystemBars(visible ? 2 : 0);
  }

  private setPlayerStatusBarVisible(visible: boolean): void {
    this.applySystemBars(visible && !this.locked ? 1 : 0).catch(() => {});
  }

  /** Serialize window operations so a late player hide cannot override exit restoration. */
  private applySystemBars(mode: number): Promise<void> {
    const revision = ++this.systemBarRevision;
    const operation = this.systemBarTask.then(async () => {
      if (revision !== this.systemBarRevision || (mode !== 2 && !this.panelMounted)) { return; }
      const win = this.winRef !== null ? this.winRef : await window.getLastWindow(getContext(this));
      if (revision !== this.systemBarRevision || (mode !== 2 && !this.panelMounted)) { return; }
      await win.setWindowSystemBarEnable(mode === 2 ? ['status', 'navigation'] : mode === 1 ? ['status'] : []);
    }).catch(() => {
      hilog.warn(0x0001, 'NasPlay', 'native system bar update unavailable');
    });
    this.systemBarTask = operation;
    return operation;
  }

  hideControls(): void {
    this.isScrubbing = false;
    this.barOpacity = 0;
    this.setPlayerStatusBarVisible(false);
  }

  private handleSurfaceTap(): void {
    if (this.locked) { return; }
    if (this.barOpacity > 0.5) { this.hideControls(); }
    else { this.showBarTemporarily(); }
  }

  private playerPopupTransition(): TransitionEffect {
    // One opacity animation belongs to the layer; content only moves/scales.
    const enter = TransitionEffect.scale({ x: 0.96, y: 0.96, centerX: '50%', centerY: '0%' })
      .combine(TransitionEffect.translate({ y: this.hudUnit(8) }))
      .animation({ duration: MotionPref.dur(MotionSpec.menuIn), curve: Curve.EaseOut });
    const leave = TransitionEffect.scale({ x: 0.96, y: 0.96, centerX: '50%', centerY: '0%' })
      .combine(TransitionEffect.translate({ y: this.hudUnit(8) }))
      .animation({ duration: MotionPref.dur(MotionSpec.menuOut), curve: Curve.EaseIn });
    return TransitionEffect.asymmetric(enter, leave);
  }

  private playerPopupLayerTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: MotionPref.dur(MotionSpec.menuIn), curve: Curve.EaseOut }),
      TransitionEffect.OPACITY.animation({ duration: MotionPref.dur(MotionSpec.menuOut), curve: Curve.EaseIn }));
  }

  private async setOrientation(landscape: boolean): Promise<void> {
    try {
      // ★ R24：窗口引用要在页面还活着时拿到并缓存。退出时（aboutToDisappear）
      //   再 getContext/getLastWindow 经常拿不到，异常被 catch 吞掉，
      //   界面就停在横屏 —— 真机已复现（返回后仍是 2848x1320）。
      if (this.winRef === null) {
        this.winRef = await window.getLastWindow(getContext(this));
      }
      const win = this.winRef;
      if (landscape) {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      } else {
        await win.setPreferredOrientation(window.Orientation.PORTRAIT);
      }
      this.isLandscape = landscape;
    } catch (e) {
      // 某些窗口不支持，忽略
    }
  }

  private toggleOrientation(): void {
    this.setOrientation(!this.isLandscape);
  }

  /** 铺满(裁切) / 适应(留黑边) 切换 */
  private toggleScale(): void {
    const pl = this.player;
    if (pl === null) {
      return;
    }
    const next = !this.fitCrop;
    try {
      pl.videoScaleType = next
        ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
        : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      this.fitCrop = next;
    } catch (e) {
      promptAction.showToast({ message: '当前播放器无法切换画面比例' });
    }
  }

  /** 视频进来时按宽高比自动决定方向 */
  private autoOrient(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    this.videoW = w;
    this.videoH = h;
    // 视频是横向的（宽 > 高）且当前是竖屏 → 自动转横屏
    if (w > h && !this.isLandscape) {
      this.setOrientation(true);
    }
  }

  private buildInfo(): string {
    const p = this.player;
    if (p === null) {
      return '';
    }
    const parts: string[] = [];
    if (p.width > 0 && p.height > 0) {
      parts.push(p.width.toString() + 'x' + p.height.toString());
    }
    return parts.join(' • ');
  }

  /* ══════════ 后台播放（AVSession）══════════ */

  async setupSession(): Promise<void> {
    if (this.session !== null) {
      return;
    }
    try {
      const gen = this.playbackGen;
      const ctx = getContext(this) as common.UIAbilityContext;
      const s = await avSession.createAVSession(ctx, 'nasplayer', 'video');
      if (!this.panelMounted || gen !== this.playbackGen) {
        await s.destroy().catch(() => {});
        return;
      }
      this.session = s;

      const meta: avSession.AVMetadata = {
        assetId: this.itemId,
        title: this.title,
        artist: this.subtitle
      };
      await s.setAVMetadata(meta);

      const st: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PREPARE,
        speed: 1.0,
        position: {
          elapsedTime: 0,
          updateTime: Date.now()
        }
      };
      await s.setAVPlaybackState(st);
      await s.activate();

      s.on('play', () => {
        this.player?.play();
      });
      s.on('pause', () => {
        this.player?.pause();
      });
      s.on('stop', () => {
        this.releaseAll('completed');
        router.back();
      });
      s.on('seek', (time: number) => {
        this.requestSeek(time);
      });
      s.on('fastForward', () => {
        this.seekBy(15000);
      });
      s.on('rewind', () => {
        this.seekBy(-15000);
      });
    } catch (e) {
      // 后台播放失败不影响正常播放
    }
  }

  private updateSession(state: avSession.PlaybackState): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    const st: avSession.AVPlaybackState = {
      state: state,
      speed: 1.0,
      position: {
        elapsedTime: this.playPos,
        updateTime: Date.now()
      }
    };
    s.setAVPlaybackState(st).catch(() => {});
  }

  /* ══════════ 画中画 ══════════ */

  async enterPip(): Promise<void> {
    const gen = this.playbackGen;
    const player = this.player;
    if (player === null || this.switchingPlayback) { return; }
    try {
      const cur = this.pipCtl;
      if (cur !== null) {
        await cur.startPiP();
        if (!this.currentPlayer(gen, player)) { await cur.stopPiP().catch(() => {}); }
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const cfg: PiPWindow.PiPConfiguration = {
        context: ctx,
        componentController: this.activeSurfaceController(),
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY
      };
      // R26 诊断：能力 / 应用级开关 / 状态回调 / 最终是否激活
      hilog.info(0x0001, 'NasPlay', 'PIP enabled=%{public}s',
        PiPWindow.isPiPEnabled().toString());
      const ctl = await PiPWindow.create(cfg);
      if (!this.currentPlayer(gen, player)) { await ctl.stopPiP().catch(() => {}); return; }
      this.pipCtl = ctl;
      ctl.on('stateChange', (st: PiPWindow.PiPState, reason: string) => {
        if (!this.currentPlayer(gen, player)) { return; }
        hilog.info(0x0001, 'NasPlay', 'PIP state=%{public}d reason=%{public}s', st, reason);
      });
      try {
        await ctl.startPiP();
      } catch (e2) {
        const be2 = e2 as BusinessError;
        // 1300013 = create() 之后已处于启动态
        hilog.info(0x0001, 'NasPlay', 'PIP startPiP code=%{public}d', be2.code);
        if (be2.code !== 1300013) { throw new Error('画中画启动失败'); }
      }
      if (!this.currentPlayer(gen, player)) { await ctl.stopPiP().catch(() => {}); return; }
      const active = await ctl.isPiPActive();
      hilog.info(0x0001, 'NasPlay', 'PIP isActive=%{public}s', active.toString());
      if (!active) { promptAction.showToast({ message: '画中画未启动，请检查系统画中画权限' }); }
      hilog.info(0x0001, 'NasPlay', 'PIP settingSwitch=%{public}s',
        (await ctl.getPiPSettingSwitch()).toString());
    } catch (e) {
      if (!this.currentPlayer(gen, player)) { return; }
      promptAction.showToast({ message: '画中画启动失败，请检查系统画中画权限' });
    }
  }

  /* ══════════ 字幕 ══════════ */

  async selectSubtitle(i: number, keepAiRequest: boolean = false): Promise<void> {
    if (!keepAiRequest) {
      this.externalSubtitleImportGen++; this.externalSubtitleCues = []; this.externalSubtitleName = '';
      this.stopAiSubtitles(false);
    }
    const selection = ++this.subtitleSelectionGen;
    this.showSubPanel = false;
    this.showBarTemporarily();
    const p = this.player;
    const gen = this.playbackGen;
    if (p === null) { return; }
    if (i < 0) {
      try {
        // 外挂字幕添加后重新读取描述，仅取消实际选中的字幕轨道。
        const descs = await p.getTrackDescription();
        if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
        const subtitleIndices: number[] = [];
        for (let n = 0; n < descs.length; n++) {
          if ((descs[n]['track_type'] as number) === media.MediaType.MEDIA_TYPE_SUBTITLE) {
            const idx = descs[n]['track_index'] as number;
            if (idx >= 0) { subtitleIndices.push(idx); }
          }
        }
        const selected = await p.getSelectedTracks();
        if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
        const selectedSubtitles: number[] = [];
        for (let n = 0; n < selected.length; n++) {
          if (subtitleIndices.indexOf(selected[n]) >= 0) { selectedSubtitles.push(selected[n]); }
        }
        hilog.info(0x0001, 'NasPlay', 'subtitle close selected=%{public}s targets=%{public}s',
          selected.join(','), selectedSubtitles.join(','));
        this.nativeSubtitleIndices = subtitleIndices;
        if (await this.disableNativeSubtitles(gen, p, selectedSubtitles, selection)) {
          this.curSubtitle = -1;
        }
      } catch (e) {
        if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
        const err = e as BusinessError;
        hilog.warn(0x0001, 'NasPlay', 'subtitle selection query failed code=%{public}d',
          err.code !== undefined ? err.code : 0);
        promptAction.showToast({ message: '无法读取当前字幕轨道，字幕状态未更新' });
      }
      return;
    }
    if (i >= this.subtitles.length) { return; }
    const t = this.subtitles[i];
    try {
      if (!t.isExternal && t.url.length === 0) {
        await p.selectTrack(t.index);
        if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
        const selected = await p.getSelectedTracks();
        if (selected.indexOf(t.index) < 0) { throw new Error('subtitle selection not confirmed'); }
      } else if (t.url.length > 0) {
        await p.addSubtitleFromUrl(t.url);
      } else { throw new Error('subtitle URL missing'); }
      if (this.currentSubtitleSelection(gen, p, selection)) { this.curSubtitle = i; }
    } catch (e) {
      if (!this.currentSubtitleSelection(gen, p, selection)) { return; }
      const err = e as BusinessError;
      hilog.warn(0x0001, 'NasPlay', 'subtitle load failed code=%{public}d',
        err.code !== undefined ? err.code : 0);
      promptAction.showToast({ message: '字幕加载失败，保留当前字幕状态' });
    }
  }

  /* ══════════ 音轨 ══════════ */

  async selectAudio(t: TrackInfo): Promise<void> {
    this.showAudioPanel = false;
    this.showBarTemporarily();
    const p = this.player;
    const gen = this.playbackGen;
    if (p === null) {
      return;
    }
    try {
      await p.selectTrack(t.index, media.SwitchMode.SMOOTH);
      if (!this.currentPlayer(gen, p)) { return; }
      this.curAudio = t.index;
    } catch (e) {
      if (!this.currentPlayer(gen, p)) { return; }
      promptAction.showToast({ message: '切换音轨失败，保留当前音轨' });
    }
  }

  /* ══════════ 控制 ══════════ */

  /** Invalidate callbacks, join the engine, then close the exact negotiated resources. */
  private async closePlayback(from: string, preserveLease: boolean = false): Promise<void> {
    if (!preserveLease) { this.reportProviderState('stopped'); }
    const continueAi = from === 'source-switch' || from === 'episode-switch' || from === 'stream-retry'
      || from === 'stream-failed' || from === 'manual-retry';
    this.externalSubtitleImportGen++;
    if (from === 'episode-switch' || !continueAi) { this.externalSubtitleCues = []; this.externalSubtitleName = ''; }
    this.stopAiSubtitles(false, continueAi);
    this.aiSettingsResumeGen = -1;
    this.showAiPanel = false; this.showAiSettings = false; this.showAiWorkbench = false;
    hilog.info(0x0001, 'NasPlay', 'closePlayback from=%{public}s', from);
    this.logStreamStats('exit-' + from);
    this.playbackGen++;
    this.stopTimer();
    this.stopWatchdog();
    this.isPlaying = false;
    const p = this.player;
    const surfaceAdapter = this.mpvSurfaceAdapter;
    const dataSource = this.rangeDataSource;
    const fallback = this.fallbackPlayback;
    const proxy = this.streamProxy;
    const descriptor = this.activeDataDescriptor;
    const reader = this.fdReadOnly;
    const session = this.session;
    const pip = this.pipCtl;
    this.pipStarted = false;
    this.seekPending = false;
    this.queuedSeekTarget = -1;
    // 保持回读缓存存活，等 native 引擎停止回调后再清理数据源。
    if (pip !== null) { await pip.stopPiP().catch(() => {}); }
    // A failed native join deliberately retains the engine/resource references.
    // Closing an fd/bridge after an unconfirmed join could race native I/O.
    if (p !== null) { await p.release(); }
    if (surfaceAdapter !== null && surfaceAdapter !== p) { await surfaceAdapter.release(); }
    if (this.player === p) { this.player = null; }
    if (this.mpvSurfaceAdapter === surfaceAdapter) { this.mpvSurfaceAdapter = null; }
    this.rangeDataSource = null; this.fallbackPlayback = null; this.streamProxy = null;
    this.fdReadOnly = null; this.session = null; this.pipCtl = null;
    this.localFileMode = false; this.localFileSize = 0;
    if (proxy !== null) { await proxy.close().catch(() => {}); }
    if (this.activeDataDescriptor === descriptor) { this.activeDataDescriptor = null; }
    if (dataSource !== null) { await dataSource.close().catch(() => {}); }
    if (fallback !== null) { await fallback.close().catch(() => {}); }
    if (reader !== null) {
      try { fs.closeSync(reader); } catch (e) {}
    }
    if (session !== null) { await session.destroy().catch(() => {}); }
    if (!preserveLease) {
      const leaseId = this.playbackLeaseId;
      this.playbackLeaseId = '';
      await SourcePlaybackLeases.release(leaseId);
    }
  }

  private releaseAll(from: string = '?', preserveLease: boolean = false): void {
    const previous = this.pendingRelease;
    if (previous !== null && preserveLease) { return; }
    let closing: Promise<void>;
    if (previous !== null) {
      // Leaving during retry-close upgrades it to a terminal close. Invalidate
      // the retry continuation now, but release the lease only after that join.
      this.playbackGen++;
      closing = previous.then(async () => {
        const leaseId = this.playbackLeaseId;
        this.playbackLeaseId = '';
        await SourcePlaybackLeases.release(leaseId);
      });
    } else { closing = this.closePlayback(from, preserveLease); }
    this.pendingRelease = closing;
    closing.catch(() => {}).finally(() => {
      if (this.pendingRelease === closing) { this.pendingRelease = null; }
    });
  }

  private startTimer(): void {
    this.stopTimer();
    this.timerId = setInterval(() => {
      const p = this.player;
      if (p === null) { return; }
      let cur = 0;
      try { cur = p.currentTime; } catch (e) { return; }
      if (cur >= 0) { this.playPos = this.isLiveStream ? 0 : cur; }
      this.aiSession?.tick(this.playPos, this.isPlaying);
      this.updateAiFileCaption();
      const facts = this.hudTechnicalFields();
      if (facts.join('|') !== this.technicalFields.join('|')) { this.technicalFields = facts; }
      if (!p.hasFirstFrameEvent && cur > 0 && !this.playbackProgressReady) {
        this.playbackProgressReady = true;
        this.loadingFirstFrame = false;
        this.streamHint = '';
        hilog.info(0x0001, 'NasPlay', 'playback progress confirmed position=%{public}d firstFrameEvent=unsupported', cur);
        this.logStreamStats('progress');
      }
      if (!this.isLiveStream && this.duration <= 0 && p.duration > 0) {
        this.duration = p.duration; this.resumeRequestedAi();
      }
      if (this.lastSamplePos < 0 || Math.abs(cur - this.lastSamplePos) >= 100) {
        this.lastProgressAt = Date.now();
        this.lastSamplePos = cur;
      }
      this.saveProgressTick();
      if (Date.now() - this.lastProviderReportAt >= 10000) {
        this.reportProviderState(this.isPlaying ? 'playing' : 'paused');
      }
      if (Date.now() - this.lastPositionLogAt >= 5000) {
        this.lastPositionLogAt = Date.now();
        hilog.info(0x0001, 'NasPlay', 'position current=%{public}d duration=%{public}d rendered=%{public}s buffering=%{public}s',
          cur, p.duration, this.hasRenderedFrame ? 'Y' : 'N', this.isBuffering ? 'Y' : 'N');
        this.logStreamStats('tick');
      }
    }, 500);
  }

  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private togglePlay(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    if (this.isPlaying) {
      p.pause().catch(() => {});
    } else {
      p.play().catch(() => {});
    }
  }

  private seekBy(deltaMs: number): void {
    const p = this.player;
    if (this.isLiveStream || p === null || this.duration <= 0) {
      return;
    }
    let target = this.playPos + deltaMs;
    if (target < 0) {
      target = 0;
    }
    if (target > this.duration) {
      target = this.duration;
    }
    this.requestSeek(target);
  }

  /** Deduplicate Slider Click/End and serialize a later requested target. */
  private requestSeek(value: number): boolean {
    const p = this.player;
    if (this.isLiveStream || p === null || this.duration <= 0 || !Number.isFinite(value)) { return false; }
    const target = Math.max(0, Math.min(this.duration, Math.round(value)));
    const now = Date.now();
    if (Math.abs(target - this.lastSeekTarget) < 400
      && (this.seekPending || now - this.lastSeekAt < 1000)) { return false; }
    if (this.seekPending) {
      this.queuedSeekTarget = target;
      this.playPos = target;
      this.suspendAiForSeek();
      return true;
    }
    this.lastSeekTarget = target;
    this.lastSeekAt = now;
    this.seekPending = true;
    this.lastProgressAt = now;
    this.suspendAiForSeek();
    try {
      p.seek(target, media.SeekMode.SEEK_PREV_SYNC);
      this.playPos = target;
      return true;
    } catch (e) {
      this.seekPending = false;
      this.resumeAiAfterSeek(p.currentTime);
      return false;
    }
  }

  canStepEpisode(direction: number): boolean {
    if (direction === 0 || this.switchingPlayback || this.videoUrl.startsWith('/')) { return false; }
    const current = this.episodes.findIndex((item: MediaItem) => item.id === this.itemId);
    const next = current + (direction < 0 ? -1 : 1);
    return current >= 0 && next >= 0 && next < this.episodes.length && this.playableNavigationItem(this.episodes[next]);
  }

  async stepEpisode(direction: number): Promise<void> {
    if (!this.canStepEpisode(direction)) { return; }
    const current = this.episodes.findIndex((item: MediaItem) => item.id === this.itemId);
    await this.switchEpisode(this.episodes[current + (direction < 0 ? -1 : 1)]);
  }

  async switchEpisode(item: MediaItem): Promise<void> {
    if (item.id === this.itemId) { this.closeSidePanel(); return; }
    if (this.switchingPlayback || item.id.length === 0 || !this.playableNavigationItem(item)) { return; }
    await this.navigatePlayback(item, '', -1, false);
  }

  async switchSource(source: MediaSource): Promise<void> {
    if (this.switchingPlayback || source.id.length === 0) { return; }
    if (source.id === this.selectedSourceId && this.errMsg.length === 0 && this.player !== null) {
      this.closeSidePanel(); return;
    }
    const item = this.currentNavigationItem();
    const resumeMs = this.player !== null ? Math.max(0, this.player.currentTime) : this.playPos;
    await this.navigatePlayback(item, source.id, resumeMs, source.id !== this.selectedSourceId);
  }

  private currentNavigationItem(): MediaItem {
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.episodes[i].id === this.itemId) { return this.episodes[i]; }
    }
    const item = new MediaItem();
    item.id = this.itemId; item.name = this.subtitle.length > 0 ? this.subtitle : this.title;
    item.seriesId = this.reqSeriesId; item.seriesName = this.reqSeriesId.length > 0 ? this.title : '';
    item.type = this.reqItemType; item.indexNumber = this.reqEpisode; item.parentIndexNumber = this.reqSeason;
    item.imageTag = this.reqImageTag;
    return item;
  }

  private playableNavigationItem(item: MediaItem): boolean {
    return item.type === 'Episode' || item.type === 'Movie' || item.type === 'Video'
      || item.type === 'MusicVideo' || item.type === 'Channel';
  }

  private ensurePlaybackQueue(): Promise<MediaItem[]> {
    if (this.isLiveStream) { return Promise.resolve(this.episodes.slice()); }
    const item = this.currentNavigationItem();
    const key = this.reqServerId + '|' + this.reqUserId + '|' + (item.seriesId.length > 0 ? item.seriesId : item.id);
    if (this.playbackQueueReadyKey === key && this.episodes.some((episode: MediaItem) => episode.id === item.id)) {
      return Promise.resolve(this.episodes);
    }
    if (this.playbackQueueRequest !== null && this.playbackQueueKey === key) { return this.playbackQueueRequest; }
    const seed = this.episodes.slice();
    const request = this.navigationGen;
    const resolving = async (): Promise<MediaItem[]> => {
      const server = await this.navigationServer();
      const queue = await PlaybackQueueResolver.resolve(server, item, seed);
      if (this.panelMounted && request === this.navigationGen && item.id === this.itemId) {
        this.episodes = queue; this.playbackQueueReadyKey = key;
      }
      return queue;
    };
    const promise = resolving();
    this.playbackQueueKey = key; this.playbackQueueRequest = promise;
    promise.then(() => {}, () => {}).finally(() => {
      if (this.playbackQueueRequest === promise) { this.playbackQueueRequest = null; }
    });
    return promise;
  }

  private async handlePlaybackCompleted(gen: number, player: PlaybackHandle): Promise<void> {
    if (!this.currentPlayer(gen, player) || this.completionHandledGen === gen || this.resolvingNavigation || this.switchingPlayback) { return; }
    if (this.isLiveStream) { await this.handlePlaybackFailure(gen, '直播连接已结束', 0); return; }
    const navigation = this.navigationGen;
    this.completionHandledGen = gen;
    this.isPlaying = false; this.stopTimer(); this.stopWatchdog(); this.stopAiSubtitles(false, true);
    if (this.duration > 0) { this.playPos = this.duration; }
    this.saveNow();
    await this.saveLocalProgress();
    if (!this.currentPlayer(gen, player) || navigation !== this.navigationGen || this.resolvingNavigation || this.switchingPlayback) { return; }
    if (!PlaybackPreferences.current().autoNext || this.reqItemType !== 'Episode' || this.videoUrl.startsWith('/')) {
      this.releaseAll('completed'); router.back(); return;
    }
    this.autoAdvancing = true; this.loadingFirstFrame = true; this.isBuffering = false;
    this.showBarTemporarily();
    try {
      await this.ensurePlaybackQueue();
      if (!this.currentPlayer(gen, player)) { return; }
      if (navigation !== this.navigationGen || this.resolvingNavigation || this.switchingPlayback) {
        this.autoAdvancing = false; this.loadingFirstFrame = false; return;
      }
      const current = this.episodes.findIndex((episode: MediaItem) => episode.id === this.itemId);
      if (current < 0) { throw new Error('分集列表未包含当前集，请手动选集'); }
      if (current + 1 >= this.episodes.length) {
        this.autoAdvancing = false; this.releaseAll('completed-last-episode'); router.back(); return;
      }
      const next = this.episodes[current + 1];
      if (!this.playableNavigationItem(next)) { throw new Error('下一集无法播放，请手动选集'); }
      const oldItem = this.itemId;
      hilog.info(0x0001, 'NasPlay', 'auto-next season=%{public}d episode=%{public}d', next.parentIndexNumber, next.indexNumber);
      // Automatic sequential playback always starts the next episode from its beginning.
      await this.navigatePlayback(next, '', 0, false);
      if (this.panelMounted && this.itemId === oldItem && this.playbackGen === gen) {
        throw new Error('下一集未能开始，请检查服务器后重试');
      }
    } catch (e) {
      if (!this.currentPlayer(gen, player)) { return; }
      if (navigation !== this.navigationGen || this.resolvingNavigation || this.switchingPlayback) {
        this.autoAdvancing = false; this.loadingFirstFrame = false; return;
      }
      this.autoAdvancing = false; this.autoNextPending = true; this.loadingFirstFrame = false;
      this.errMsg = '本集已播完，自动续播失败。' + (e as Error).message;
      this.showBarTemporarily();
    }
  }

  private retryAutomaticNext(): void {
    const player = this.player;
    if (player === null) { this.retryPlayback(); return; }
    this.errMsg = ''; this.autoNextPending = false; this.completionHandledGen = -1;
    this.handlePlaybackCompleted(this.playbackGen, player);
  }

  private async navigationServer(): Promise<ServerConfig> {
    const servers = await Store.loadServers();
    for (let i = 0; i < servers.length; i++) {
      if (servers[i].id === this.reqServerId) { return servers[i]; }
    }
    throw new Error('服务器记录已移除，请返回重新连接');
  }

  private async navigatePlayback(item: MediaItem, sourceId: string, resumeMs: number,
    changingSource: boolean): Promise<void> {
    if (!this.panelMounted || this.videoUrl.startsWith('/')) { return; }
    const request = ++this.navigationGen;
    const oldTitle = this.title;
    const oldSeriesId = this.reqSeriesId;
    this.switchingPlayback = true;
    this.resolvingNavigation = true;
    let committed = false;
    let pendingTarget: PlaybackTarget | null = null;
    try {
      if (this.player !== null && this.completionHandledGen !== this.playbackGen) { this.playPos = Math.max(0, this.player.currentTime); }
      this.saveNow();
      await this.saveLocalProgress();
      this.rememberEpisodeProgress();
      const server = await this.navigationServer();
      const target = await PlaybackNavigation.resolve(server, item, sourceId, resumeMs, changingSource);
      pendingTarget = target;
      if (!this.panelMounted || request !== this.navigationGen) { return; }
      // A failed resolve above leaves the old player, source checkmark and metadata intact.
      this.resolvingNavigation = false;
      if (this.player !== null && this.completionHandledGen !== this.playbackGen) { this.playPos = Math.max(0, this.player.currentTime); }
      this.saveNow();
      await this.saveLocalProgress();
      this.rememberEpisodeProgress();
      this.surfaceMounted = false;
      this.releaseAll(changingSource ? 'source-switch' : 'episode-switch');
      if (this.pendingRelease !== null) { await this.pendingRelease; }
      if (!this.panelMounted || request !== this.navigationGen) { return; }
      if (target.leaseId.length > 0 && !SourcePlaybackLeases.claim(target.leaseId)) {
        throw new Error('播放会话已失效，请重新选择影片');
      }
      this.playbackLeaseId = target.leaseId;
      committed = true;
      this.applyPlaybackTarget(target, oldTitle, oldSeriesId);
      this.closeSidePanel();
      if (this.useMpvEngine) { await this.createMpvSurface(); }
      else {
        await new Promise<void>((resolve) => { setTimeout(resolve, 32); });
        if (!this.panelMounted || request !== this.navigationGen) { return; }
        this.surfaceMounted = true;
      }
      if (this.panelMounted && request === this.navigationGen) { await this.setupPlayer(); }
    } catch (e) {
      if (!this.panelMounted || request !== this.navigationGen) { return; }
      const message = (e as Error).message;
      const friendly = message.startsWith('当前飞牛') || message.startsWith('该视频源')
        || message.startsWith('服务器') ? message : '切换失败，请检查服务器连接后重试';
      if (committed) { this.errMsg = friendly; this.loadingFirstFrame = false; }
      promptAction.showToast({ message: friendly });
      this.switchingPlayback = false;
    } finally {
      if (!committed && pendingTarget !== null) {
        await SourcePlaybackLeases.release(pendingTarget.leaseId).catch(() => {});
      }
      if (request === this.navigationGen) {
        this.resolvingNavigation = false;
        if (!committed) { this.switchingPlayback = false; }
      }
    }
  }

  private applyPlaybackTarget(target: PlaybackTarget, oldTitle: string, oldSeriesId: string): void {
    this.autoNextPending = false;
    const item = target.item;
    this.panelServer = target.server;
    this.reqServerId = target.server.id; this.reqUserId = target.server.userId;
    this.serviceKind = target.server.kind;
    this.authToken = target.server.token;
    this.nativeAuthToken = target.server.nativeToken.length > 0 ? target.server.nativeToken : target.server.token;
    this.initialStreamHeaders = target.headers;
    this.initialHeadersProvided = true;
    this.isLiveStream = target.isLive;
    this.sourceRouteError = false;
    this.videoUrl = target.url; this.isHls = target.isHls;
    this.itemId = item.id; this.reqItemType = item.type; this.reqSeriesId = item.seriesId;
    this.reqSeason = item.parentIndexNumber; this.reqEpisode = item.indexNumber; this.reqImageTag = item.imageTag;
    this.title = item.seriesName.length > 0 ? item.seriesName
      : (item.seriesId.length > 0 && item.seriesId === oldSeriesId ? oldTitle : item.name);
    this.subtitle = item.name;
    this.sources = target.sources;
    this.episodes = this.episodes.map((episode: MediaItem) => episode.id === item.id ? item : episode);
    if (this.selectedSourceId !== target.sourceId) { this.selectedSourceId = ''; }
    this.pendingSelectedSourceId = target.sourceId;
    this.subtitles = target.subtitles; this.nativeSubtitleIndices = []; this.curSubtitle = -1;
    this.audioTracks = []; this.curAudio = -1;
    this.desiredResumeMs = target.isLive ? 0 : target.positionMs;
    this.startTicks = Math.floor(this.desiredResumeMs * 10000);
    this.playPos = 0; this.duration = 0; this.videoW = 0; this.videoH = 0;
    this.resumeSeeked = false; this.resumeSeekPending = false;
    this.streamRetryCount = 0; this.retryingStream = false;
    this.seekPending = false; this.lastSeekTarget = -1; this.queuedSeekTarget = -1; this.lastSeekAt = 0;
    this.lastSaveAt = 0; this.lastSamplePos = -1;
    this.loadingFirstFrame = true; this.hasRenderedFrame = false; this.playbackProgressReady = false;
    this.isBuffering = false; this.isPlaying = false; this.errMsg = ''; this.streamHint = '';
    this.sourceCodecs = ''; this.info = ''; this.speed = 1;
    this.showAudioPanel = false; this.showSubPanel = false; this.showSpeedPanel = false;
    this.barOpacity = 1; this.isScrubbing = false;
    this.useMpvEngine = target.useMpv;
    if (!this.isLiveStream) { Store.setLastPlayed(this.title, this.subtitle,
      item.hasPrimaryImage ? MediaServices.imageUrl(target.server, item.id, 240, item.imageTag) : '',
      item.runtimeTicks > 0 ? (target.positionMs * 10000 / item.runtimeTicks * 100).toFixed(0) : '0').catch(() => {}); }
  }

  private rememberEpisodeProgress(): void {
    if (this.isLiveStream || this.playPos <= 0 || this.duration <= 0) { return; }
    const list = this.episodes.slice();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.itemId) {
        list[i].progressTicks = Math.floor(this.playPos * 10000);
        list[i].runtimeTicks = Math.floor(this.duration * 10000);
      }
    }
    this.episodes = list;
  }

  /* ══════════ 控制栏自动隐藏 ══════════ */

  /* ══════════ R21：侧栏开合 ══════════
   * 单一 progress 值同时驱动 translateX 与 scrim，可中断；
   * 打开前先收起其它浮层（互斥），并暂停控制条自动隐藏。
   */
  private sidePanelWidth(): number {
    const width = this.hudW();
    return Math.round(width * (width > this.hudH() ? 0.40 : 0.88));
  }

  private loadPanelServer(): void {
    Store.loadServers().then((servers: ServerConfig[]) => {
      if (!this.panelMounted) {
        return;
      }
      for (let i = 0; i < servers.length; i++) {
        if (servers[i].id === this.reqServerId) {
          this.panelServer = servers[i];
          this.refreshCurrentSources(servers[i]);
          if (this.reqItemType === 'Episode' && !this.videoUrl.startsWith('/')) {
            this.ensurePlaybackQueue().catch(() => {});
          }
          break;
        }
      }
    }).catch(() => {
      // 本地播放或服务器记录已移除时，仍显示已有剧集文本和进度。
    });
  }

  private refreshCurrentSources(server: ServerConfig): void {
    const itemId = this.itemId;
    const request = this.navigationGen;
    if (itemId.length === 0 || this.videoUrl.startsWith('/')) { return; }
    MediaServices.getItemDetail(server, itemId).then((detail) => {
      if (!this.panelMounted || request !== this.navigationGen || itemId !== this.itemId || this.switchingPlayback) { return; }
      this.sources = detail.sources;
      if (detail.sources.length === 1) { this.selectedSourceId = detail.sources[0].id; }
      else if (!detail.sources.some((source: MediaSource) => source.id === this.selectedSourceId)) {
        this.selectedSourceId = '';
      }
    }).catch(() => {});
  }

  private sideInitialIndex(): number {
    for (let i = 0; i < this.episodes.length; i++) {
      if (this.episodes[i].id === this.itemId) {
        return Math.max(0, i - 3);
      }
    }
    return 0;
  }

  private episodePanelTitle(ep: MediaItem): string {
    const label = ep.indexNumber > 0 ? '第' + ep.indexNumber.toString() + '集 · ' : '';
    return label + ep.name;
  }

  private episodePanelProgress(ep: MediaItem): number {
    if (ep.id === this.itemId && this.duration > 0) {
      return Math.max(0, Math.min(1, this.playPos / this.duration));
    }
    // Router parameters can be plain objects without MediaItem prototype methods.
    if (ep.played) { return 1; }
    return Number.isFinite(ep.runtimeTicks) && ep.runtimeTicks > 0 && Number.isFinite(ep.progressTicks)
      ? Math.max(0, Math.min(1, ep.progressTicks / ep.runtimeTicks)) : 0;
  }

  private episodePanelImage(ep: MediaItem): string {
    const server = this.panelServer;
    if (server === null) {
      return '';
    }
    if (this.failedEpisodeImages.indexOf(ep.id) < 0 &&
      (ep.backdropTag.length > 0 || ep.imageTag.length > 0)) {
      return MediaServices.backdropUrl(server, ep.id, 420, ep.backdropTag, ep.imageTag);
    }
    const seriesId = ep.seriesId.length > 0 ? ep.seriesId : this.reqSeriesId;
    return seriesId.length > 0 ? MediaServices.imageUrl(server, seriesId, 420, '') : '';
  }

  private panelImageHeaders(): Record<string, string> {
    const server = this.panelServer;
    return server !== null ? MediaServices.imageHeaders(server) : {};
  }

  private sideThumbnailWidth(): number {
    return Math.min(this.hudUnit(232), Math.max(72, this.sidePanelWidth() * 0.34));
  }

  private sideSourceQuality(source: MediaSource): string {
    const video = source.streams.find((stream) => stream.type === 'Video');
    return video !== undefined && video.height > 0 ? video.height.toString() + 'P' : '原画';
  }

  private sideSourceQualities(): string[] {
    const values: string[] = [];
    for (let i = 0; i < this.sources.length; i++) {
      const quality = this.sideSourceQuality(this.sources[i]);
      if (values.indexOf(quality) < 0) { values.push(quality); }
    }
    return values;
  }

  private sideActiveQuality(): string {
    return this.sideSourceQualities().indexOf(this.sideQualityFilter) >= 0 ? this.sideQualityFilter : '';
  }

  private sideFilteredSources(): MediaSource[] {
    const quality = this.sideActiveQuality();
    return quality.length === 0 ? this.sources : this.sources.filter((source: MediaSource) =>
      this.sideSourceQuality(source) === quality);
  }

  private sideQualityCount(quality: string): number {
    return this.sources.filter((source: MediaSource) => this.sideSourceQuality(source) === quality).length;
  }

  private sideSourceGroupTitle(): string {
    if (this.serviceKind === 'fnos') { return '飞牛影视'; }
    const server = this.panelServer;
    if (server !== null) {
      if (server.name.length > 0) { return server.name; }
      if (server.serverName.length > 0) { return server.serverName; }
    }
    return this.serviceKind === 'fnos' ? '飞牛影视' :
      (this.serviceKind === 'jellyfin' ? 'Jellyfin' : (this.serviceKind === 'emby' ? 'Emby' : '当前来源'));
  }

  private sideSourceMetadata(source: MediaSource): string {
    const parts: string[] = [];
    const active = source.id === this.selectedSourceId && this.player instanceof MpvAdapter;
    let bytes = source.sizeBytes;
    if (bytes <= 0 && active) {
      bytes = (this.player as MpvAdapter).core.surfaceController.native.getProperty('file-size');
    }
    if (Number.isFinite(bytes) && bytes > 0) {
      parts.push(bytes >= 1073741824 ? (bytes / 1073741824).toFixed(2) + ' GB'
        : (bytes / 1048576).toFixed(1) + ' MB');
    }
    const video = source.streams.find((stream) => stream.type === 'Video');
    if (video !== undefined) {
      if (video.bitrate > 0) { parts.push((video.bitrate / 1000000).toFixed(1) + ' Mbps'); }
      if (video.frameRate > 0) { parts.push((Math.round(video.frameRate * 100) / 100).toString() + 'fps'); }
      else if (active && this.technicalFields[2].length > 0) { parts.push(this.technicalFields[2]); }
      if (video.videoRange.length > 0) { parts.push(video.videoRange); }
      else if (video.isHdr) { parts.push('HDR'); }
      else if (active && this.technicalFields[5].length > 0) { parts.push(this.technicalFields[5]); }
    }
    return parts.join('  ');
  }

  private sideSourceDescription(source: MediaSource): string {
    return this.sideSourceQuality(source).toLowerCase();
  }

  private onEpisodeImageFail(id: string): void {
    if (this.failedEpisodeImages.indexOf(id) < 0) {
      this.failedEpisodeImages = this.failedEpisodeImages.concat([id]);
    }
  }

  private openSidePanel(mode: number): void {
    if (this.showSidePanel && this.sideMode === mode) {
      this.closeSidePanel();
      return;
    }
    this.sideAnimationGen++;
    this.sideProgress = 1;
    this.sideMode = mode;
    this.showSubPanel = false;
    this.showAudioPanel = false;
    this.showSpeedPanel = false;
    this.showSidePanel = true;
    this.barOpacity = 1;
    this.setPlayerStatusBarVisible(true);
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    hilog.info(0x0001, 'NasPlay',
      'SIDEPANEL open mode=%{public}d episodes=%{public}d sources=%{public}d width=%{public}d',
      mode, this.episodes.length, this.sources.length, this.sidePanelWidth());
  }



  private closeSidePanel(): void {
    this.sideAnimationGen++;
    this.sideProgress = 0; this.showSidePanel = false;
    this.scheduleHideBar();
  }
  private scheduleHideBar(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.hideTimer = setTimeout(() => {
      if (this.isPlaying && !this.isScrubbing && !this.showSubPanel && !this.showAudioPanel && !this.showSpeedPanel && !this.showSidePanel && !this.showRatioPanel && !this.showSubtitleStyle && !this.showCastPanel && !this.showAiPanel && !this.showAiSettings && !this.showAiWorkbench && this.errMsg.length === 0) {
        this.hideControls();
      }
    }, MotionSpec.controlsAutoHide);
  }

  private showBarTemporarily(): void {
    this.barOpacity = 1;
    this.setPlayerStatusBarVisible(true);
    this.scheduleHideBar();
  }

  private flashHint(text: string): void {
    this.gestureHint = text;
    this.hintVisible = true;
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
    }
    this.hintTimer = setTimeout(() => {
      this.hintVisible = false;
    }, 900);
  }

  /**
   * UI 浮点倍率 → media.PlaybackSpeed 枚举。
   * ★ 原实现直接把 0.75/1.25 等浮点传给 setSpeed，签名要的是枚举，属于类型错误。
   */
  private speedEnum(v: number): media.PlaybackSpeed {
    if (v <= 0.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (v <= 0.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (v <= 1.0) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (v <= 1.25) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (v <= 1.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (v <= 1.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }

  /** 应用倍率；成功才更新 UI 状态，失败回滚并提示 */
  private applySpeed(v: number, silent: boolean): void {
    const pl = this.player;
    if (pl === null) {
      return;
    }
    const prev = this.speed;
    try {
      pl.setSpeed(this.speedEnum(v));
      this.speed = v;
      if (!silent) {
        this.flashHint(v === 1.0 ? '正常速度' : (v.toFixed(2).replace(/0+$/, '').replace(/[.]$/, '') + 'x'));
      }
    } catch (e) {
      this.speed = prev;
      if (!silent) {
        promptAction.showToast({ message: '当前视频不支持该倍速' });
      }
    }
  }

  private setSpeed(v: number): void {
    this.applySpeed(v, false);
    this.showSpeedPanel = false;
  }

  private boostStart(): void {
    if (this.locked || this.player === null) {
      return;
    }
    this.boostPrev = this.speed;
    this.applySpeed(2.0, true);
    this.flashHint('2x 快进中');
  }

  private boostEnd(): void {
    if (this.player === null) {
      return;
    }
    this.applySpeed(this.boostPrev > 0 ? this.boostPrev : 1.0, true);
  }

  /** 手势开始：记录基准值，之后所有计算都以它为原点（方案 8.3） */
  private gestureBegin(): void {
    this.gLastY = 0;
    this.gBaseBrightness = this.brightnessVal < 0 ? 128 : this.brightnessVal;
    this.gBaseVolume = this.volumeVal < 0 ? 60 : this.volumeVal;
  }

  /** 竖滑应用到亮度：传入累计 offsetY，内部换算增量 */
  private applyBrightnessFromGesture(offsetY: number): void {
    const step = (this.gLastY - offsetY) / 3;
    this.gLastY = offsetY;
    const next = Math.max(10, Math.min(255, this.gBaseBrightness + step));
    this.gBaseBrightness = next;
    this.brightnessVal = next;
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      w.setWindowBrightness(next / 255.0);
    }).catch(() => {
    });
    this.flashHint('亮度 ' + Math.round((next / 255.0) * 100).toString() + '%');
  }

  /** 竖滑应用到音量：同上 */
  private applyVolumeFromGesture(offsetY: number): void {
    const step = (this.gLastY - offsetY) / 3;
    this.gLastY = offsetY;
    const next = Math.max(0, Math.min(100, this.gBaseVolume + step));
    this.gBaseVolume = next;
    this.volumeVal = next;
    const pl = this.player;
    if (pl !== null) {
      try {
        pl.setVolume(next / 100.0);
      } catch (e) {
      }
    }
    this.flashHint('音量 ' + Math.round(next).toString() + '%');
  }

  private toggleLock(): void {
    this.locked = !this.locked;
    if (this.locked) {
      this.hideControls();
      this.setPlayerStatusBarVisible(true);
      this.flashHint('已锁定，点锁图标解锁');
    } else {
      this.showBarTemporarily();
    }
  }

  /** 屏幕宽度（vp）—— 手势分区用 */
  private screenW(): number {
    try {
      const d = display.getDefaultDisplaySync();
      return d.width / d.densityPixels;
    } catch (e) {
      return 400;
    }
  }

  /**
   * 进度条拖拽（方案 8.4）：
   *  · 拖动中只更新预览值，不 seek、不覆盖真实 playPos
   *  · 松手才提交一次 seek
   *  · 拖动期间暂停自动隐藏计时，结束后重置 4 秒
   */
  private handleScrub(v: number, mode: SliderChangeMode): void {
    if (!this.canInteractWithTimeline()) { this.isScrubbing = false; return; }
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      this.isScrubbing = true;
      this.scrubPos = v;
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
      return;
    }
    this.isScrubbing = false;
    const pl = this.player;
    if (pl !== null && this.duration > 0) {
      this.requestSeek(v);
    }
    this.scheduleHideBar();
  }

  private canInteractWithTimeline(): boolean {
    return !this.isLiveStream && this.panelMounted && !this.locked && this.barOpacity > 0.5
      && this.errMsg.length === 0 && !this.switchingPlayback;
  }

  private fmt(ms: number): string {
    if (ms <= 0) {
      return '00:00';
    }
    const total = Math.floor(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const mm = m < 10 ? '0' + m.toString() : m.toString();
    const ss = s < 10 ? '0' + s.toString() : s.toString();
    if (h > 0) {
      const hh = h < 10 ? '0' + h.toString() : h.toString();
      return hh + ':' + mm + ':' + ss;
    }
    return mm + ':' + ss;
  }

  private progressRatio(): number {
    if (this.duration <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, this.playPos / this.duration));
  }

  /* ══════════ 界面 ══════════ */

  /* ══════════ R23：更多菜单（窄锚定，与大侧栏互斥）══════════
   * 方案 §9.1 / E27：宽约横屏宽 13.9%（本机 138vp），在按钮旁锚定展开，
   * 快速收退、视频继续、不销毁播放器。与大侧栏互斥。
   */
  @Builder
  moreMenu() {
    Column() {
      Row() {
        Text('播放信息')
          .fontSize(Metrics.f(12))
          .fontColor(withAlpha('#FFFFFF', 0.55))
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 2 })

      Row() {
        Text(this.sourceCodecs.length > 0 ? this.sourceCodecs : '未知编码')
          .fontSize(Metrics.f(11))
          .fontColor('#F5F6F8')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 6 })

      Row() {
        Text(this.localFileMode ? '本地文件' : (this.activeIsHls ? 'HLS' : (this.activeNativeStream ? 'NAS 兼容流' : '媒体数据源流式播放')))
          .fontSize(Metrics.f(11))
          .fontColor(withAlpha('#FFFFFF', 0.7))
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 10 })

      Divider()
        .strokeWidth(0.5)
        .color(withAlpha('#FFFFFF', 0.12))
        .margin({ left: 10, right: 10 })

      Row() {
        Text('画中画')
          .fontSize(Metrics.f(13))
          .fontColor('#5B9BF8')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .onClick(() => {
        this.enterPip();
      })

      Row() {
        Text('关闭菜单')
          .fontSize(Metrics.f(13))
          .fontColor(withAlpha('#FFFFFF', 0.85))
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    }
    .width(138)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(12)
  }
  /* ══════════ R21：大侧栏渲染 ══════════ */
  @Builder
  sideEpisodeCard(ep: MediaItem) {
    Row({ space: this.hudUnit(22) }) {
      Stack() {
        if (this.episodePanelImage(ep).length > 0) {
          NetImage({
            url: this.episodePanelImage(ep),
            headers: this.panelImageHeaders(),
            targetWidth: 420,
            placeholderColor: '#171717',
            onFail: (_url: string) => { this.onEpisodeImageFail(ep.id); }
          })
            .width('100%')
            .height('100%')
        } else {
          SymbolGlyph($r('sys.symbol.TV_tv'))
            .fontSize(this.hudUnit(36))
            .fontColor([withAlpha('#FFFFFF', 0.35)])
        }
      }
      .width(this.sideThumbnailWidth())
      .height(this.sideThumbnailWidth() / 2)
      .borderRadius(this.hudUnit(12))
      .clip(true)
      .backgroundColor('#171717')

      Column({ space: this.hudUnit(10) }) {
        Text(this.episodePanelTitle(ep))
          .fontSize(this.hudUnit(22))
          .lineHeight(this.hudUnit(26))
          .fontWeight(ep.id === this.itemId ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(ep.id === this.itemId ? '#00D2FC' : '#DEDEDE')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (ep.overview.length > 0) {
          Text(ep.overview)
            .fontSize(this.hudUnit(19))
            .lineHeight(this.hudUnit(24))
            .fontColor('#A8A8A8')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        if (this.episodePanelProgress(ep) > 0) {
          Row({ space: this.hudUnit(12) }) {
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(this.hudUnit(4))
                .backgroundColor(withAlpha('#FFFFFF', 0.12))
              Row()
                .width((this.episodePanelProgress(ep) * 100).toFixed(1) + '%')
                .height(this.hudUnit(4))
                .backgroundColor('#00D2FC')
            }
            .width(this.sidePanelWidth() * 0.18)
            .height(this.hudUnit(4))
            .borderRadius(this.hudUnit(2))
            .clip(true)
            Text(Math.round(this.episodePanelProgress(ep) * 100).toString() + '%')
              .fontSize(this.hudUnit(19))
              .fontColor(withAlpha('#FFFFFF', 0.55))
          }
          .height(this.hudUnit(20))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: this.hudUnit(16), right: this.hudUnit(16),
      top: this.hudUnit(18), bottom: this.hudUnit(18) })
    .borderRadius(this.hudUnit(20))
    .backgroundColor(ep.id === this.itemId ? '#2E2E2E' : '#00000000')
    .enabled(!this.switchingPlayback)
    .onClick(() => { this.switchEpisode(ep); })
    .accessibilityGroup(true)
    .accessibilityText((ep.id === this.itemId ? '正在播放，' : '') + this.episodePanelTitle(ep))
  }

  @Builder
  sideSourceCard(src: MediaSource) {
    Row({ space: this.hudUnit(18) }) {
      Column({ space: this.hudUnit(13) }) {
        Row({ space: this.hudUnit(16) }) {
          Text(this.sideSourceQuality(src))
            .fontSize(this.hudUnit(28)).letterSpacing(this.hudUnit(0.5))
            .lineHeight(this.hudUnit(30))
            .fontWeight(FontWeight.Bold)
            .fontColor('#E6E6E6')
          if (this.sideSourceMetadata(src).length > 0) {
            Text(this.sideSourceMetadata(src))
              .fontSize(this.hudUnit(20))
              .lineHeight(this.hudUnit(24))
              .fontColor('#B6B6B6')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }.width('100%')
        if (this.sideSourceDescription(src).length > 0) {
          Text(this.sideSourceDescription(src))
            .fontSize(this.hudUnit(20))
            .lineHeight(this.hudUnit(24))
            .fontColor('#A9A9A9')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (src.id === this.selectedSourceId) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(this.hudUnit(30))
          .fontColor(['#00D2FC'])
      }
    }
    .width('100%')
    .padding({ left: this.hudUnit(17), right: this.hudUnit(17),
      top: this.hudUnit(18), bottom: this.hudUnit(16) })
    .constraintSize({ minHeight: this.hudUnit(100) })
    .borderRadius(this.hudUnit(18))
    .backgroundColor(src.id === this.selectedSourceId ? '#3D3D3D' : '#00000000')
    .enabled(!this.switchingPlayback)
    .onClick(() => { this.switchSource(src); })
    .accessibilityGroup(true)
    .accessibilityText((src.id === this.selectedSourceId ? '当前视频源，' : '') +
      this.sideSourceQuality(src) + '，' + this.sideSourceMetadata(src))
  }

  @Builder
  sidePanel() {
    Column() {
          if (this.sideMode === 1) {
          Row() {
            Text('选择视频源')
              .fontSize(this.hudUnit(30))
              .lineHeight(this.hudUnit(36))
              .fontWeight(FontWeight.Bold)
              .fontColor('#F5F6F8')
          }
          .width('100%')
          .padding({ left: this.hudUnit(40), right: this.hudUnit(40),
            top: this.hudUnit(31), bottom: this.hudUnit(32) })

          Scroll() {
            Row({ space: this.hudUnit(16) }) {
              Text('全部')
                .fontSize(this.hudUnit(24))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.sideActiveQuality().length === 0 ? '#001318' : '#D0D0D0')
                .padding({ left: this.hudUnit(20), right: this.hudUnit(20) })
                .height(this.hudUnit(54))
                .borderRadius(this.hudUnit(27))
                .backgroundColor(this.sideActiveQuality().length === 0 ? '#00D2FC' : '#303030')
                .onClick(() => { this.sideQualityFilter = ''; })
              ForEach(this.sideSourceQualities(), (quality: string) => {
                Text() {
                  Span(quality).fontSize(this.hudUnit(23.5))
                  Span('  ' + this.sideQualityCount(quality).toString()).fontSize(this.hudUnit(20))
                }
                  .fontColor(this.sideActiveQuality() === quality ? '#001318' : '#D0D0D0')
                  .padding({ left: this.hudUnit(23), right: this.hudUnit(23) })
                  .height(this.hudUnit(54))
                  .borderRadius(this.hudUnit(27))
                  .backgroundColor(this.sideActiveQuality() === quality ? '#00D2FC' : '#303030')
                  .onClick(() => { this.sideQualityFilter = quality; })
              }, (quality: string) => quality)
            }
            .constraintSize({ minWidth: this.sidePanelWidth() })
            .justifyContent(FlexAlign.Center)
            .padding({ left: this.hudUnit(38), right: this.hudUnit(38) })
          }
          .width('100%')
          .height(this.hudUnit(54))
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .margin({ bottom: this.hudUnit(35) })
          }

          List({ space: this.sideMode === 0 ? this.hudUnit(10) : 0,
            initialIndex: this.sideMode === 0 ? this.sideInitialIndex() : 0 }) {
            if (this.sideMode === 0) {
              ForEach(this.episodes, (ep: MediaItem) => {
                ListItem() {
                  this.sideEpisodeCard(ep)
                }
              }, (ep: MediaItem) => ep.id)
            } else {
              if (this.sideFilteredSources().length > 0) {
                ListItem() {
                  Column() {
                    Text(this.sideSourceGroupTitle())
                      .fontSize(this.hudUnit(24))
                      .lineHeight(this.hudUnit(24))
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#00D2FC')
                      .width('100%')
                      .padding({ left: this.hudUnit(22), right: this.hudUnit(22),
                        top: this.hudUnit(18), bottom: this.hudUnit(16) })
                    Column({ space: this.hudUnit(6) }) {
                      ForEach(this.sideFilteredSources(), (src: MediaSource) => {
                        this.sideSourceCard(src)
                      }, (src: MediaSource) => src.id)
                    }.width('100%').padding({ left: this.hudUnit(8), right: this.hudUnit(8), bottom: this.hudUnit(12) })
                  }
                  .width('100%')
                  .borderRadius(this.hudUnit(22))
                }
              }
            }
          }
          .width('100%')
          .padding({
            left: this.hudUnit(38),
            right: this.hudUnit(38),
            top: this.sideMode === 0 ? this.hudUnit(30) : 0,
            bottom: this.hudUnit(22)
          })
          .layoutWeight(1)
          .scrollBar(BarState.Off)

          if ((this.sideMode === 0 && this.episodes.length === 0)
            || (this.sideMode === 1 && this.sources.length === 0)) {
            Text(this.sideMode === 0 ? '没有同剧集列表' : '服务器没有给出可选视频源')
              .fontSize(Metrics.f(12))
              .fontColor(withAlpha('#FFFFFF', 0.45))
              .padding({ left: 16, right: 16, bottom: 20 })
          }
        
    }.width(this.sidePanelWidth()).height(Math.max(160, this.hudH() - this.hudSafeTop - this.hudSafeBottom - 24))
  }

  private hudW(): number {
    return this.hudWidth > 0 ? this.hudWidth : Math.max(Metrics.width(), Metrics.height());
  }

  private hudH(): number {
    return this.hudHeight > 0 ? this.hudHeight : Math.max(320, Math.min(Metrics.width(), Metrics.height()));
  }

  private hudShort(): number {
    return Math.min(this.hudW(), this.hudH());
  }

  private hudIconSize(): number {
    return this.hudUnit(36);
  }

  private hudTap(): number {
    return this.hudUnit(74);
  }

  private hudUtilityWidth(): number {
    return this.hudUnit(100);
  }

  private hudLeftPad(): number {
    return Math.max(this.hudSafeLeft + 4, this.hudUnit(92));
  }

  private hudRightPad(): number {
    return Math.max(this.hudSafeRight + 4, this.hudUnit(32));
  }

  /** Reference recording, normalized to its real 1920 x 890 landscape viewport. */
  private hudUnit(value: number): number { return value * this.hudShort() / 890; }

  private hudEpisodeLabel(): string {
    const prefix = this.reqEpisode > 0 ? 'S' + Math.max(1, this.reqSeason).toString().padStart(2, '0')
      + 'E' + this.reqEpisode.toString().padStart(2, '0') + '· ' : '';
    return prefix + this.subtitle;
  }

  private hudQualityLabel(): string {
    let height = this.player !== null ? this.player.height : 0;
    for (let i = 0; i < this.sources.length; i++) {
      const source = this.sources[i];
      if (source.id !== this.selectedSourceId && this.sources.length !== 1) { continue; }
      for (let n = 0; n < source.streams.length; n++) {
        if (height <= 0 && source.streams[n].type === 'Video' && source.streams[n].height > 0) { height = source.streams[n].height; break; }
      }
    }
    return height > 0 ? (height >= 2160 ? '4K' : height.toString() + 'P') : '原画';
  }

  private hudTime(value: number): string {
    const total = Math.max(0, Math.floor(value / 1000));
    return Math.floor(total / 3600).toString().padStart(2, '0') + ':'
      + Math.floor(total % 3600 / 60).toString().padStart(2, '0') + ':' + (total % 60).toString().padStart(2, '0');
  }

  private hudSpeedSymbol(): Resource {
    if (this.speed === 0.5) { return $r('sys.symbol.speed_50percent'); }
    if (this.speed === 0.75) { return $r('sys.symbol.speed_75percent'); }
    if (this.speed === 1.25) { return $r('sys.symbol.speed_125percent'); }
    if (this.speed === 1.5) { return $r('sys.symbol.speed_150percent'); }
    if (this.speed === 1.75) { return $r('sys.symbol.speed_175percent'); }
    if (this.speed === 2) { return $r('sys.symbol.speed_200percent'); }
    return $r('sys.symbol.speed_100percent');
  }

  private applyScreenRatio(mode: string): void {
    const p = this.player;
    if (p === null) { return; }
    try {
      if (p instanceof MpvAdapter) { p.applyScreenRatio(mode); }
      else if (mode === '默认') { p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT; }
      else if (mode === '平铺' || mode === '裁切') { p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP; }
      else if (mode === '拉伸') { p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT; }
      else { promptAction.showToast({ message: '当前播放方式仅支持适应、拉伸与裁切' }); return; }
      this.screenRatioMode = mode;
      this.fitCrop = mode === '平铺' || mode === '裁切';
      if (mode === '平铺') { promptAction.showToast({ message: '等比铺满，保留原始比例' }); }
      this.showRatioPanel = false;
      this.showBarTemporarily();
    } catch (e) { promptAction.showToast({ message: '画面比例未改变，请重试' }); }
  }

  private applySubtitleScale(value: number): void {
    const p = this.player;
    if (!(p instanceof MpvAdapter)) { promptAction.showToast({ message: '当前播放方式不支持调整字幕字号' }); return; }
    try { p.setSubtitleScale(value); this.subtitleScale = value; }
    catch (e) { promptAction.showToast({ message: '字幕字号未改变，请重试' }); }
  }

  private async openSubtitleSearch(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try { await context.startAbility({ action: 'ohos.want.action.viewData', uri: 'https://subhd.tv/search/' + encodeURIComponent(this.title) }); }
    catch (e) { promptAction.showToast({ message: '暂时无法打开字幕搜索' }); }
  }

  private activeSubtitleLabel(): string {
    if (this.curSubtitle < 0 || this.curSubtitle >= this.subtitles.length) { return '未选择'; }
    const track = this.subtitles[this.curSubtitle];
    return track.language.length > 0 ? this.subtitleLanguageName(track.language) : track.title;
  }

  private subtitleOptionLabel(track: SubtitleTrack, index: number): string {
    if (track.language.length > 0 && (!track.title || track.title.startsWith(track.language + ' · '))) {
      return this.subtitleLanguageName(track.language);
    }
    return track.title.length > 0 ? track.title : (track.language.length > 0 ? this.subtitleLanguageName(track.language) : '字幕 ' + (index + 1).toString());
  }

  private subtitleLanguageName(language: string): string {
    const names: Record<string, string> = { 'en': '英语', 'ar': '阿拉伯语', 'de': '德语', 'es': '西班牙语', 'fr': '法语', 'hi': '印地语',
      'id': '印尼语', 'it': '意大利语', 'ja': '日语', 'ko': '韩语', 'ms': '马来语', 'pt': '葡萄牙语', 'ru': '俄语', 'th': '泰语', 'vi': '越南语', 'tr': '土耳其语', 'zh': '中文' };
    return names[language.toLowerCase().split('-')[0]] ?? language;
  }

  private aiPlaybackInput(mode: string, preferredSubtitle: number = this.curSubtitle): AiPlaybackInput {
    if (this.isLiveStream) { throw new Error('直播请导入字幕文件进行翻译，暂不生成整片时间轴'); }
    if (this.player === null || this.duration <= 0 || this.videoUrl.length === 0) {
      throw new Error('请等待视频准备完成');
    }
    if (this.externalSubtitleCues.length === 0 && !NativeAudioExtractor.supportsSource(this.videoUrl, this.activeIsHls)) {
      throw new Error(NativeAudioExtractor.sourceError(this.videoUrl, this.activeIsHls));
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const headers = this.playbackHeaders();
    const embedded = this.subtitles.filter((track: SubtitleTrack) => !track.isExternal);
    let ordinal = -1;
    if (preferredSubtitle >= 0 && preferredSubtitle < this.subtitles.length) {
      const chosen = this.subtitles[preferredSubtitle];
      ordinal = embedded.findIndex((track: SubtitleTrack) => track.index === chosen.index);
    }
    const mpv = this.player instanceof MpvAdapter ? this.player : null;
    return { url: this.videoUrl, headers: headers, durationMs: this.duration, cacheDir: context.cacheDir,
      subtitleOrdinal: ordinal, subtitleStreamIndex: mpv !== null ? mpv.getSelectedDemuxStreamIndex('subtitle') : -1,
      preferredLanguage: '', audioStreamIndex: mpv !== null ? mpv.getSelectedDemuxStreamIndex('audio') : -1,
      mode: mode, translate: true, timedCues: this.externalSubtitleCues.length > 0 ? this.externalSubtitleCues : undefined };
  }

  private stopAiSubtitles(restoreNative: boolean = true, preserveRequest: boolean = false): void {
    const previous = this.aiNativeSubtitleBefore;
    this.aiRevision++;
    const session = this.aiSession; this.aiSession = null;
    if (session !== null) { session.cancel(); }
    this.aiFileCues = [];
    if (!preserveRequest) { this.aiRequested = false; this.aiSettingsResumeGen = -1; this.aiConfigurationPrompted = false; }
    this.aiEnabled = false; this.aiBusy = false;
    this.aiSeekSuspended = false;
    this.aiOriginal = ''; this.aiTranslated = ''; this.aiNativeSubtitleBefore = -1;
    if (restoreNative && this.externalSubtitleCues.length > 0 && this.panelMounted) {
      this.aiFileCues = this.externalSubtitleCues; this.aiEnabled = true; this.updateAiFileCaption();
    } else if (restoreNative && previous >= -1 && this.player !== null && this.panelMounted) {
      this.selectSubtitle(previous);
    }
  }

  private openAiSubtitles(): void {
    this.showSubPanel = false; this.showAiPanel = true; this.showBarTemporarily();
    if (this.aiSession !== null || this.aiBusy) { return; }
    this.aiRequested = true; this.aiConfigurationPrompted = false;
    this.startAiSubtitles();
  }

  private openAiSettings(): void {
    this.aiSettingsResumeGen = this.aiRequested ? this.playbackGen : -1;
    this.showAiPanel = false; this.showAiSettings = true;
  }

  private closeAiSettings(): void {
    const cancelPending = this.aiConfigurationPrompted && this.aiSettingsResumeGen === this.playbackGen;
    this.aiSettingsResumeGen = -1;
    if (cancelPending) { this.stopAiSubtitles(); this.aiStatus = '已取消 AI 字幕配置'; }
    else if (!this.aiEnabled) { this.aiRequested = false; }
    this.showAiSettings = false; this.showAiPanel = true;
  }

  private resumeRequestedAi(): void {
    if (this.panelMounted && this.aiRequested && this.aiSession === null && !this.aiBusy && this.aiSettingsResumeGen < 0
      && this.player !== null && this.duration > 0 && !this.isLiveStream && !this.seekPending && !this.aiSeekSuspended
      && !this.retryingStream && !this.resolvingNavigation && !this.switchingPlayback && this.errMsg.length === 0) {
      this.startAiSubtitles();
    }
  }

  private resumeAiAfterConfiguration(): void {
    const resume = this.panelMounted && this.aiRequested && this.aiSettingsResumeGen === this.playbackGen;
    this.aiSettingsResumeGen = -1; this.showAiSettings = false;
    if (!resume) { this.aiStatus = '配置已保存'; return; }
    this.stopAiSubtitles(false, true); this.aiConfigurationPrompted = false;
    this.showAiPanel = true; this.startAiSubtitles();
  }

  private requestAiConfiguration(message: string, purpose: string, revision: number, playback: number): void {
    if (!this.panelMounted || revision !== this.aiRevision || playback !== this.playbackGen || !this.aiRequested) { return; }
    this.aiStatus = message;
    if (this.aiConfigurationPrompted) { this.showAiPanel = true; return; }
    this.aiConfigurationPrompted = true; this.aiConfigurationPurpose = purpose;
    this.aiSettingsResumeGen = playback; this.showAiPanel = false; this.showAiSettings = true;
  }

  private async startAiSubtitles(mode: string = 'auto'): Promise<void> {
    if (this.aiBusy) { return; }
    const previous = this.aiEnabled ? this.aiNativeSubtitleBefore : this.curSubtitle;
    let input: AiPlaybackInput;
    try { input = this.aiPlaybackInput(mode, previous); }
    catch (e) { this.aiStatus = (e as Error).message; return; }
    this.stopAiSubtitles(false, true); this.aiRequested = true;
    const revision = ++this.aiRevision;
    const playback = this.playbackGen;
    this.aiBusy = true; this.aiNativeSubtitleBefore = previous;
    this.aiStatus = '正在准备 AI 字幕…';
    try {
      await this.selectSubtitle(-1, true);
      if (!this.panelMounted || revision !== this.aiRevision || playback !== this.playbackGen) { return; }
      if (this.curSubtitle !== -1) { throw new Error('原字幕尚未关闭，请关闭后重试'); }
      const session = new AiSubtitleSession(input, {
        onCaption: (original: string, translated: string) => {
          if (this.panelMounted && revision === this.aiRevision && playback === this.playbackGen) {
            this.aiOriginal = original; this.aiTranslated = translated;
          }
        },
        onStatus: (message: string) => {
          if (this.panelMounted && revision === this.aiRevision && playback === this.playbackGen) {
            this.aiStatus = message;
            if (message === 'AI 字幕已就绪' || message === 'AI 原声字幕已就绪') { this.showAiPanel = false; }
          }
        },
        onError: (message: string) => {
          if (this.panelMounted && revision === this.aiRevision && playback === this.playbackGen) { this.aiStatus = message; this.showAiPanel = true; }
        },
        onConfigurationRequired: (message: string, purpose: string) => { this.requestAiConfiguration(message, purpose, revision, playback); }
      });
      this.aiSession = session; this.aiEnabled = true;
      const starting = session.start(this.playPos);
      if (this.aiSeekSuspended || this.seekPending) { session.suspendForSeek(); }
      await starting;
    } catch (e) {
      if (this.panelMounted && revision === this.aiRevision && playback === this.playbackGen) {
        this.aiSession?.cancel(); this.aiSession = null; this.aiEnabled = false;
        this.aiStatus = (e as Error).message;
        if (previous >= 0) { await this.selectSubtitle(previous, true); }
      }
    } finally { if (revision === this.aiRevision) { this.aiBusy = false; } }
  }

  private async applyAiFileCues(cues: AiSubtitleCue[], name: string = ''): Promise<void> {
    const previous = this.aiEnabled ? this.aiNativeSubtitleBefore : this.curSubtitle;
    this.stopAiSubtitles(false);
    const revision = ++this.aiRevision;
    const playback = this.playbackGen;
    await this.selectSubtitle(-1, true);
    if (!this.panelMounted || revision !== this.aiRevision || playback !== this.playbackGen) { return; }
    if (this.curSubtitle !== -1) { this.aiStatus = '原字幕尚未关闭，未应用文件字幕'; return; }
    this.aiNativeSubtitleBefore = previous;
    this.aiSeekSuspended = this.seekPending;
    this.externalSubtitleCues = cues.map((cue: AiSubtitleCue): AiSubtitleCue => ({ id: cue.id, startMs: cue.startMs, endMs: cue.endMs, text: cue.text }));
    this.externalSubtitleName = name.length > 0 ? name : '字幕文件';
    this.aiFileCues = this.externalSubtitleCues; this.aiEnabled = true;
    this.aiStatus = '已应用 ' + cues.length.toString() + ' 条文件字幕';
    this.showAiWorkbench = false; this.showAiPanel = false;
    this.updateAiFileCaption(); this.showBarTemporarily();
  }

  private async readSubtitleFile(uri: string): Promise<string> {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = await fs.stat(file.fd);
      if (!Number.isFinite(stat.size) || stat.size <= 0 || stat.size > 2097152) { throw new AiSubtitleError('file-size', '请选择不超过 2MB 的非空字幕文件'); }
      const data = new Uint8Array(stat.size); let offset = 0;
      while (offset < stat.size) {
        const part = new ArrayBuffer(Math.min(65536, stat.size - offset));
        const count = await fs.read(file.fd, part, { length: part.byteLength });
        if (count <= 0) { break; } data.set(new Uint8Array(part, 0, count), offset); offset += count;
      }
      if (offset !== stat.size || await fs.read(file.fd, new ArrayBuffer(1), { length: 1 }) > 0) { throw new AiSubtitleError('file-changed', '字幕文件已变化，请重新选择'); }
      const encoding = data.length >= 2 && data[0] === 255 && data[1] === 254 ? 'utf-16le'
        : data.length >= 2 && data[0] === 254 && data[1] === 255 ? 'utf-16be' : 'utf-8';
      try { return new util.TextDecoder(encoding, { fatal: true }).decodeToString(data); }
      catch (e) { throw new AiSubtitleError('encoding', '字幕编码无法读取，请转换为 UTF-8 后导入'); }
    } finally { await fs.close(file).catch(() => {}); }
  }

  private async chooseExternalSubtitle(): Promise<void> {
    const playback = this.playbackGen; const selection = ++this.externalSubtitleImportGen;
    this.showSubPanel = false;
    try {
      if (this.isLiveStream) { throw new AiSubtitleError('live', '当前直播暂不支持按文件时间轴加载字幕'); }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const selected = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 1,
        fileSuffixFilters: ['字幕文件|.srt,.vtt,.ass,.ssa'] });
      if (!this.panelMounted || playback !== this.playbackGen || selection !== this.externalSubtitleImportGen || selected.length === 0) { return; }
      const text = await this.readSubtitleFile(selected[0]);
      if (!this.panelMounted || playback !== this.playbackGen || selection !== this.externalSubtitleImportGen) { return; }
      const name = decodeURIComponent(selected[0].substring(selected[0].lastIndexOf('/') + 1)).substring(0, 160);
      await this.applyAiFileCues(SubtitleFileCodec.parse(text, name), name);
    } catch (e) {
      if (this.panelMounted && playback === this.playbackGen && selection === this.externalSubtitleImportGen) {
        promptAction.showToast({ message: e instanceof AiSubtitleError ? e.message : '无法读取字幕文件，请重新选择' });
      }
    }
  }

  private updateAiFileCaption(): void {
    if (this.aiFileCues.length === 0 || this.aiSeekSuspended) { return; }
    const cue = this.aiFileCues.find((value: AiSubtitleCue) => value.startMs <= this.playPos && value.endMs > this.playPos);
    this.aiOriginal = cue !== undefined ? cue.text : ''; this.aiTranslated = '';
  }

  private suspendAiForSeek(): void {
    if (this.aiSeekSuspended) { return; }
    this.aiSeekSuspended = true;
    this.aiSession?.suspendForSeek();
    this.aiOriginal = ''; this.aiTranslated = '';
  }

  private resumeAiAfterSeek(positionMs: number): void {
    const actual = Number.isFinite(positionMs) && positionMs >= 0 ? positionMs : this.playPos;
    this.aiSeekSuspended = false; this.playPos = actual;
    this.aiSession?.seek(actual);
    this.updateAiFileCaption();
    this.resumeRequestedAi();
  }

  private hudTechnicalWidth(index: number): number {
    const widths: number[] = [70, 116, 73, 94, 63, 78];
    return this.hudUnit(widths[index]);
  }

  private async capturePlaybackFrame(): Promise<void> {
    const p = this.player;
    if (!(p instanceof MpvAdapter)) { promptAction.showToast({ message: '当前播放方式不支持视频截图' }); return; }
    let packer: image.ImagePacker | null = null;
    let pixel: image.PixelMap | null = null;
    try {
      pixel = p.core.surfaceController.screenshot(true);
      packer = image.createImagePacker();
      const data = await packer.packing(pixel, { format: 'image/jpeg', quality: 95 });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const saver = new picker.DocumentViewPicker(context);
      const target = await saver.save({ newFileNames: ['NAS-' + Date.now().toString() + '.jpg'], fileSuffixChoices: ['JPEG图片|.jpg'] });
      if (target.length > 0) {
        const file = fs.openSync(target[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        try { fs.writeSync(file.fd, data); } finally { fs.closeSync(file); }
        promptAction.showToast({ message: '视频截图已保存' });
      }
    } catch (e) { promptAction.showToast({ message: '未保存截图' }); }
    finally {
      if (packer !== null) { await packer.release(); }
      if (pixel !== null) { await pixel.release(); }
    }
  }

  private hudTechnicalText(): string {
    return this.hudTechnicalFields().filter((value: string) => value.length > 0).join('    ');
  }

  private hudTechnicalFields(): string[] {
    const p = this.player;
    const parts: string[] = ['', '', '', '', '', ''];
    const codec = this.sourceCodecs.split(' ')[0];
    if (codec.length > 0) { parts[0] = codec.toUpperCase(); }
    if (p !== null && p.width > 0 && p.height > 0) { parts[1] = p.width.toString() + '×' + p.height.toString(); }
    if (p instanceof MpvAdapter) {
      const facts = p.getTechnicalInfo();
      if (facts.fps !== null) { parts[2] = (Math.round(facts.fps * 10) / 10).toString() + 'fps'; }
      if (facts.bitrate !== null) { parts[3] = (facts.bitrate / 1000000).toFixed(1) + 'Mbps'; }
      if (facts.hardware !== 'unknown') { parts[4] = facts.hardware === 'hardware' ? '硬解' : '软解'; }
      if (facts.dynamicRange.length > 0) { parts[5] = facts.dynamicRange; }
    }
    return parts;
  }

  private async openCastPicker(): Promise<void> {
    this.showCastPanel = false;
    try {
      const picker = new avSession.AVCastPickerHelper(this.getUIContext().getHostContext() as common.UIAbilityContext);
      await picker.select({ sessionType: 'video' });
    } catch (e) {
      promptAction.showToast({ message: '暂时无法打开投播设备列表' });
    }
  }

  private async retryPlayback(): Promise<void> {
    if (this.sourceRouteError || this.retryingStream || this.resolvingNavigation) { return; }
    this.retryingStream = true;
    this.desiredResumeMs = this.isLiveStream ? 0 : Math.max(this.desiredResumeMs, this.playPos);
    this.releaseAll('manual-retry', true);
    const gen = this.playbackGen;
    try {
      if (this.pendingRelease !== null) { await this.pendingRelease; }
      if (!this.panelMounted || gen !== this.playbackGen) { return; }
      this.errMsg = ''; this.streamRetryCount = 0;
      this.loadingFirstFrame = true; this.isBuffering = false;
      this.hasRenderedFrame = false; this.playbackProgressReady = false;
      this.resumeSeeked = false; this.resumeSeekPending = false;
      this.barOpacity = 1;
      if (this.useMpvEngine) {
        await this.createMpvSurface();
        if (!this.panelMounted || gen !== this.playbackGen) { return; }
        this.retryingStream = false;
        await this.setupPlayer();
      } else { this.retryingStream = false; await this.setupPlayer(); }
    } catch (e) {
      if (this.panelMounted && gen === this.playbackGen) {
        this.errMsg = '连接失败，请检查来源连接后重试。';
        this.loadingFirstFrame = false;
      }
    } finally { if (gen === this.playbackGen) { this.retryingStream = false; } }
  }

  private readHudInsets(): void {
    if (this.winRef === null) {
      return;
    }
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      const cutout = this.winRef.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const nav = this.winRef.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.hudSafeLeft = Math.max(cutout.leftRect.width, nav.leftRect.width) / density;
      this.hudSafeRight = Math.max(cutout.rightRect.width, nav.rightRect.width) / density;
      this.hudSafeTop = Math.max(cutout.topRect.height, nav.topRect.height) / density;
      this.hudSafeBottom = Math.max(cutout.bottomRect.height, nav.bottomRect.height) / density;
    } catch (e) {
    }
  }

  @Builder
  hudIcon(symbol: Resource, label: string, selected: boolean, action: () => void, size: number = 36, offsetX: number = 0, enabled: boolean = true) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(this.hudUnit(size))
        .fontColor([enabled ? (selected ? '#FFFFFF' : withAlpha('#FFFFFF', 0.94)) : withAlpha('#FFFFFF', 0.43)])
        .translate({ x: this.hudUnit(offsetX) })
    }
    .width(this.hudUtilityWidth())
    .height(this.hudTap())
    .justifyContent(FlexAlign.Center)
    .accessibilityText(label)
    .enabled(enabled)
    .onClick(action)
  }

  @Builder
  hudHeader() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Text(this.title)
          .fontSize(this.hudUnit(32))
          .letterSpacing(this.hudUnit(-0.8))
          .lineHeight(this.hudUnit(36))
          .height(this.hudUnit(36))
          .fontColor(withAlpha('#FFFFFF', 0.95))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.hudEpisodeLabel())
            .fontSize(this.hudUnit(22.5))
            .letterSpacing(this.hudUnit(-0.15))
            .lineHeight(this.hudUnit(28))
            .height(this.hudUnit(28))
            .fontColor(withAlpha('#FFFFFF', 0.62))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: this.hudUnit(3) })
        }
      }
      .width('50%')
      .alignItems(HorizontalAlign.Center)
      .position({ x: '25%', y: this.hudUnit(34) })

      Row() {
        this.hudIcon($r('sys.symbol.xmark'), '退出播放', false, () => {
          this.releaseAll();
          router.back();
        }, 37.5, -3)
        Blank()
        this.hudIcon($r('sys.symbol.square_grid_2x2'), '画面比例', false, () => {
          this.showRatioPanel = !this.showRatioPanel;
          this.showSubPanel = false;
          this.showAudioPanel = false;
        }, 40, -2)
        this.hudIcon($r('sys.symbol.screen_rotation'), '切换屏幕方向', false, () => {
          this.toggleOrientation();
        }, 39, -3)
        this.hudIcon($r('sys.symbol.statusbar_cast'), '投播设备', false, () => {
          this.showCastPanel = true; this.showBarTemporarily();
        }, 42)
        this.hudIcon($r('sys.symbol.rectangle_on_rectangle'), '画中画', false, () => {
          this.enterPip();
        }, 39, -0.5)
      }
      .width('100%')
      .padding({
        left: Math.max(this.hudSafeLeft + 4, this.hudUnit(60)),
        right: this.hudRightPad()
      })
      .position({ x: 0, y: this.hudUnit(84) })
    }
    .width('100%')
    .height(this.hudH() * 0.23)
    .opacity(this.barOpacity)
    .translate({ y: this.barOpacity > 0.5 ? 0 : -28 })
    .visibility(this.barOpacity > 0.5 ? Visibility.Visible : Visibility.Hidden)
    .hitTestBehavior(this.barOpacity > 0.5 ? HitTestMode.Transparent : HitTestMode.BLOCK_DESCENDANTS)
    .animation({ duration: this.barOpacity > 0.5 ? MotionSpec.controlsIn : MotionSpec.controlsOut, curve: this.barOpacity > 0.5 ? Curve.EaseOut : Curve.EaseIn })
  }

  @Builder
  hudMore() {
    Row() {
      SymbolGlyph($r('sys.symbol.ellipsis_circle'))
        .fontSize(this.hudUnit(39))
        .fontColor([withAlpha('#FFFFFF', 0.88)])
    }
    .width(this.hudUtilityWidth())
    .height(this.hudTap())
    .justifyContent(FlexAlign.Center)
    .accessibilityText('更多播放选项')
    .onClick(() => {
      if (this.showSidePanel) { this.closeSidePanel(); }
      this.showSubPanel = false;
      this.showAudioPanel = false;
      this.showSpeedPanel = false;
      this.showRatioPanel = false;
      this.showSubtitleStyle = false;
    })
    .bindMenu(this.moreMenu(), {
      systemMaterial: Materials.popupMaterial(true, '#00D2FC')
    })
  }

  @Builder
  playerMenuRow(label: string, detail: string, selected: boolean, enabled: boolean, action: () => void) {
    Column() {
      Row() {
        Column() {
          Text(label).fontSize(this.hudUnit(24)).fontColor(enabled ? '#E3E4E6' : '#8E9298').maxLines(1)
          if (detail.length > 0) {
            Text(detail).fontSize(this.hudUnit(18)).fontColor('#A5A7AB').maxLines(1).margin({ top: this.hudUnit(8) })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(this.hudUnit(25)).fontColor(['#00D2FC'])
        }
      }.width('100%').height(this.hudUnit(94)).padding({ left: this.hudUnit(28), right: this.hudUnit(28) })
      Divider().strokeWidth(this.hudUnit(1)).color(withAlpha('#FFFFFF', 0.12)).margin({ left: this.hudUnit(28), right: this.hudUnit(28) })
    }.width('100%').enabled(enabled).accessibilityText(label + (detail.length > 0 ? '，' + detail : ''))
      .onClick(action)
  }

  private nativeOverlayVisible(kind: string): boolean {
    if (kind === 'subtitle') { return this.showSubPanel || this.showSubtitleStyle; }
    if (kind === 'ratio') { return this.showRatioPanel; }
    if (kind === 'speed') { return this.showSpeedPanel; }
    if (kind === 'audio') { return this.showAudioPanel; }
    if (kind === 'side') { return this.showSidePanel; }
    if (kind === 'cast') { return this.showCastPanel; }
    if (kind === 'ai') { return this.showAiPanel; }
    return false;
  }

  private hideNativeOverlay(kind: string): void {
    if (kind === 'subtitle') { this.showSubPanel = false; this.showSubtitleStyle = false; }
    else if (kind === 'ratio') { this.showRatioPanel = false; }
    else if (kind === 'speed') { this.showSpeedPanel = false; }
    else if (kind === 'audio') { this.showAudioPanel = false; }
    else if (kind === 'side') { this.sideAnimationGen++; this.sideProgress = 0; this.showSidePanel = false; }
    else if (kind === 'cast') { this.showCastPanel = false; }
    else if (kind === 'ai') { this.showAiPanel = false; }
  }

  private onNativeOverlayChange(property: string): void {
    this.nativeOverlayRevision++;
    if (this.nativeOverlaySyncing) { return; }
    let kind = '';
    if (property === 'showSubPanel' || property === 'showSubtitleStyle') { kind = 'subtitle'; }
    else if (property === 'showRatioPanel') { kind = 'ratio'; }
    else if (property === 'showSpeedPanel') { kind = 'speed'; }
    else if (property === 'showAudioPanel') { kind = 'audio'; }
    else if (property === 'showSidePanel') { kind = 'side'; }
    else if (property === 'showCastPanel') { kind = 'cast'; }
    else if (property === 'showAiPanel') { kind = 'ai'; }
    if (!this.nativeOverlayVisible(kind)) { return; }
    const kinds: string[] = ['subtitle', 'ratio', 'speed', 'audio', 'side', 'cast', 'ai'];
    this.nativeOverlaySyncing = true;
    try {
      for (const other of kinds) { if (other !== kind && this.nativeOverlayVisible(other)) { this.hideNativeOverlay(other); } }
    } finally { this.nativeOverlaySyncing = false; }
  }

  private nativePopupState(kind: string): (event: PopupStateChangeParam) => void {
    const playback = this.playbackGen, revision = this.nativeOverlayRevision;
    return (event: PopupStateChangeParam): void => {
      if (event.isVisible || !this.panelMounted || playback !== this.playbackGen || revision !== this.nativeOverlayRevision) { return; }
      this.hideNativeOverlay(kind); this.scheduleHideBar();
    };
  }

  private nativeSheetDismiss(kind: string): (action: DismissSheetAction) => void {
    const playback = this.playbackGen, revision = this.nativeOverlayRevision;
    return (action: DismissSheetAction): void => {
      if (this.panelMounted && playback === this.playbackGen && revision === this.nativeOverlayRevision) {
        this.hideNativeOverlay(kind); this.scheduleHideBar();
      }
      action.dismiss();
    };
  }

  private nativeSheetGone(kind: string): () => void {
    const playback = this.playbackGen, revision = this.nativeOverlayRevision;
    return (): void => {
      if (!this.panelMounted || playback !== this.playbackGen || revision !== this.nativeOverlayRevision) { return; }
      this.hideNativeOverlay(kind); this.scheduleHideBar();
    };
  }

  /** Real ArkUI popup/sheet hosts; the transparent 1vp anchors preserve the former HUD locations. */
  @Builder
  nativePlayerOverlays() {
    Row().width(1).height(1).position({ x: this.hudW() / 2 + this.hudUnit(210), y: this.hudUnit(164) })
      .hitTestBehavior(HitTestMode.None)
      .bindPopup(this.showSubPanel || this.showSubtitleStyle, { builder: this.subtitleMenuPanel(),
        placement: Placement.Bottom, enableArrow: false, autoCancel: true,
        width: Math.min(this.hudUnit(425), this.hudW() * 0.88),
        systemMaterial: Materials.popupMaterial(true, '#00D2FC'), onStateChange: this.nativePopupState('subtitle') })
    Row().width(1).height(1).position({ x: this.hudW() - this.hudUnit(200), y: this.hudUnit(71) })
      .hitTestBehavior(HitTestMode.None)
      .bindPopup(this.showRatioPanel, { builder: this.ratioMenuPanel(), placement: Placement.Bottom,
        enableArrow: false, autoCancel: true, width: this.hudUnit(267),
        systemMaterial: Materials.popupMaterial(true, '#00D2FC'), onStateChange: this.nativePopupState('ratio') })
    Row().width(1).height(1).position({ x: this.hudUnit(194), y: this.hudUnit(94) })
      .hitTestBehavior(HitTestMode.None)
      .bindPopup(this.showSpeedPanel, { builder: this.speedMenuPanel(), placement: Placement.Bottom,
        enableArrow: false, autoCancel: true, width: this.hudUnit(267),
        systemMaterial: Materials.popupMaterial(true, '#00D2FC'), onStateChange: this.nativePopupState('speed') })
    Row().width(1).height(1).position({ x: Math.max(this.hudUnit(200), this.hudW() - this.hudUnit(325)), y: this.hudUnit(170) })
      .hitTestBehavior(HitTestMode.None)
      .bindPopup(this.showAudioPanel, { builder: this.audioMenuPanel(), placement: Placement.Bottom,
        enableArrow: false, autoCancel: true, width: Math.min(this.hudUnit(430), this.hudW() * 0.88),
        systemMaterial: Materials.popupMaterial(true, '#00D2FC'), onStateChange: this.nativePopupState('audio') })
    Row().width(1).height(1).position({ x: this.hudW() - this.hudSafeRight - 1, y: this.hudH() / 2 })
      .hitTestBehavior(HitTestMode.None)
      .bindPopup(this.showSidePanel, { builder: this.sidePanel(), placement: Placement.Left,
        enableArrow: false, autoCancel: true, width: this.sidePanelWidth(),
        systemMaterial: Materials.popupMaterial(true, '#00D2FC'), onStateChange: this.nativePopupState('side') })
    Row().width(1).height(1).hitTestBehavior(HitTestMode.None)
      .bindSheet(this.showCastPanel, this.castConfirmation(), { preferType: SheetType.CENTER,
        width: Math.min(this.hudUnit(796), this.hudW() - 32), height: this.hudUnit(449),
        dragBar: false, showClose: false, systemMaterial: Materials.popupMaterial(true, '#00D2FC'),
        onWillDismiss: this.nativeSheetDismiss('cast'), onDisappear: this.nativeSheetGone('cast') })
    Row().width(1).height(1).hitTestBehavior(HitTestMode.None)
      .bindSheet(this.showAiPanel, this.aiSubtitlePanel(), { preferType: SheetType.CENTER,
        width: Math.min(this.hudUnit(600), this.hudW() * 0.85), height: this.hudH() - this.hudUnit(100),
        dragBar: false, showClose: false, systemMaterial: Materials.popupMaterial(true, '#00D2FC'),
        onWillDismiss: this.nativeSheetDismiss('ai'), onDisappear: this.nativeSheetGone('ai') })
  }

  @Builder
  subtitleMenuPanel() {
    Column() {
          if (this.showSubtitleStyle) {
            Text('字幕字号').fontSize(this.hudUnit(22)).fontColor('#E3E4E6').width('100%')
              .padding(this.hudUnit(28))
            this.playerMenuRow('较小', '', this.subtitleScale === 0.8, true, () => { this.applySubtitleScale(0.8); })
            this.playerMenuRow('默认', '', this.subtitleScale === 1, true, () => { this.applySubtitleScale(1); })
            this.playerMenuRow('较大', '', this.subtitleScale === 1.25, true, () => { this.applySubtitleScale(1.25); })
            this.playerMenuRow('特大', '', this.subtitleScale === 1.5, true, () => { this.applySubtitleScale(1.5); })
          } else if (this.subtitleMenuPage === 0) {
            Scroll() {
              Column() {
                this.playerMenuRow('禁用字幕', '', this.curSubtitle === -1, true, () => { this.selectSubtitle(-1); })
                this.playerMenuRow('内封字幕', this.activeSubtitleLabel(), false,
                  this.subtitles.some((t: SubtitleTrack) => !t.isExternal), () => { this.subtitleMenuPage = 1; })
                this.playerMenuRow('外挂字幕', '', false,
                  this.subtitles.some((t: SubtitleTrack) => t.isExternal), () => { this.subtitleMenuPage = 2; })
                this.playerMenuRow('选择字幕文件', this.externalSubtitleName, this.externalSubtitleCues.length > 0, true, () => { this.chooseExternalSubtitle(); })
                this.playerMenuRow('SubHD', '', false, true, () => { this.openSubtitleSearch(); })
                this.playerMenuRow('副字幕', '未启用', false, false, () => {})
                this.playerMenuRow('AI 字幕', this.aiRequested ? '已开启' : '自动识别并翻译', this.aiRequested, true, () => { this.openAiSubtitles(); })
                this.playerMenuRow('字幕样式', '', false, this.player instanceof MpvAdapter, () => {
                  this.showSubPanel = false; this.showSubtitleStyle = true;
                })
              }.width('100%')
            }.width('100%').height('100%').scrollBar(BarState.Auto)
          } else {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(this.hudUnit(22)).fontColor(['#E3E4E6'])
              Text(this.subtitleMenuPage === 1 ? '内封字幕' : '外挂字幕').fontSize(this.hudUnit(22)).fontColor('#E3E4E6')
            }.width('100%').height(this.hudUnit(70)).padding({ left: this.hudUnit(28) })
              .onClick(() => { this.subtitleMenuPage = 0; })
            List() {
              ForEach(this.subtitles, (track: SubtitleTrack, index: number) => {
                if ((this.subtitleMenuPage === 1 && !track.isExternal) || (this.subtitleMenuPage === 2 && track.isExternal)) {
                  ListItem() {
                    this.playerMenuRow(this.subtitleOptionLabel(track, index), track.language,
                      this.curSubtitle === index, true, () => { this.selectSubtitle(index); })
                  }
                }
              }, (track: SubtitleTrack, index: number) => index.toString())
            }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
          }
        
    }.width(Math.min(this.hudUnit(425), this.hudW() * 0.88))
        .height(this.hudH() - this.hudUnit(180))
  }

  @Builder
  ratioMenuPanel() {
    Column() {
          Text('屏幕比例').fontSize(this.hudUnit(20)).fontColor('#9A9B9F').width('100%')
            .padding({ left: this.hudUnit(28) }).height(this.hudUnit(70))
          List() {
            ForEach(['默认', '平铺', '拉伸', '裁切', '16:9', '4:3', '原始像素比例'], (mode: string) => {
              ListItem() {
                Column() {
                  Row() {
                    Stack() {
                      if (this.screenRatioMode === mode) {
                        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(this.hudUnit(25)).fontColor(['#D2D3D5'])
                      }
                    }.width(this.hudUnit(42)).height(this.hudUnit(40))
                    Text(mode).fontSize(this.hudUnit(20)).fontColor('#B3B4B6').maxLines(1)
                  }.width('100%').height(this.hudUnit(94)).padding({ left: this.hudUnit(28), right: this.hudUnit(16) })
                    .onClick(() => { this.applyScreenRatio(mode); })
                  Divider().strokeWidth(this.hudUnit(1)).color(withAlpha('#FFFFFF', 0.12)).margin({ left: this.hudUnit(28), right: this.hudUnit(28) })
                }.width('100%')
              }
            }, (mode: string) => mode)
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        
    }.width(this.hudUnit(267)).height(Math.min(this.hudUnit(711), this.hudH() - this.hudUnit(90)))
          .padding({ top: this.hudUnit(8), bottom: this.hudUnit(10) })
  }

  @Builder
  speedMenuPanel() {
    Column() {
          Text('播放速度').fontSize(this.hudUnit(20)).fontColor('#9A9B9F').width('100%').padding(this.hudUnit(22))
          List() {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], (value: number) => {
              ListItem() { this.playerMenuRow(value.toString() + '×', '', this.speed === value, true, () => { this.setSpeed(value); }) }
            }, (value: number) => value.toString())
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        
    }.width(this.hudUnit(267)).height(Math.min(this.hudUnit(660), this.hudH() - this.hudUnit(150)))
  }

  @Builder
  audioMenuPanel() {
    Column() {
          Text('音轨').fontSize(this.hudUnit(22)).fontColor('#E3E4E6').width('100%').padding(this.hudUnit(28))
          List() {
            ForEach(this.audioTracks, (track: TrackInfo) => {
              ListItem() { this.playerMenuRow(track.label, '', this.curAudio === track.index, true, () => { this.selectAudio(track); }) }
            }, (track: TrackInfo) => track.index.toString())
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
          if (this.audioTracks.length === 0) { Text('暂未读取到音轨').fontSize(this.hudUnit(20)).fontColor('#9A9B9F').padding(this.hudUnit(28)) }
        
    }.width(Math.min(this.hudUnit(430), this.hudW() * 0.88)).height(this.hudUnit(360))
  }

  @Builder
  hudBottom() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Row() {
          ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
            Text(this.technicalFields[index]).fontSize(this.hudUnit(index === 1 ? 23 : 24)).fontColor(withAlpha('#FFFFFF', 0.94))
              .maxLines(1).width(this.hudTechnicalWidth(index)).padding({ left: this.hudUnit(2) })
          }, (index: number) => index.toString())
        }.layoutWeight(1).clip(true).accessibilityGroup(true).accessibilityText(this.hudTechnicalText())
        this.hudIcon($r('sys.symbol.text_character_square'), '字幕', this.showSubPanel, () => {
          this.subtitleMenuPage = 0;
          this.showSubPanel = !this.showSubPanel;
          this.showAudioPanel = false;
        }, 36)
        this.hudIcon($r('sys.symbol.music_fill'), '音轨', this.showAudioPanel, () => {
          this.showAudioPanel = !this.showAudioPanel;
          this.showSubPanel = false;
        }, 40)
        this.hudIcon($r('sys.symbol.barrage_simple'), '暂无弹幕', false, () => {}, 36, 0, false)
        this.hudIcon($r('sys.symbol.rectangle_and_cut_fill'), '视频截图', false, () => { this.capturePlaybackFrame(); }, 38)
        this.hudMore()
      }
      .width('100%').height(this.hudTap())
      .padding({ left: this.hudLeftPad(), right: this.hudRightPad() })
      .position({ x: 0, y: this.hudH() - this.hudUnit(254) })

      Row() {
        Text(this.isLiveStream ? '直播' : this.hudTime(this.isScrubbing ? this.scrubPos : this.playPos))
          .fontSize(this.hudUnit(24)).letterSpacing(this.hudUnit(0.65)).fontColor(withAlpha('#FFFFFF', 0.95)).width(this.hudUnit(98))
        if (this.isLiveStream) {
          Blank().layoutWeight(1)
        } else {
        Slider({ value: this.isScrubbing ? this.scrubPos : this.playPos, min: 0,
          max: this.duration > 0 ? this.duration : 1, step: 1000, style: SliderStyle.OutSet })
          .layoutWeight(1).height(this.hudUnit(74)).margin({ left: this.hudUnit(-12), right: this.hudUnit(-12) })
          .blockSize({ width: this.hudUnit(14), height: this.hudUnit(14) })
          .blockColor('#D0D0D0').trackThickness(this.hudUnit(7))
          .trackColor(withAlpha('#FFFFFF', 0.23)).selectedColor('#F9F9F9')
          .enabled(this.duration > 0 && this.canInteractWithTimeline())
          .onChange((value: number, mode: SliderChangeMode) => { this.handleScrub(value, mode); })
        }
        Text(this.isLiveStream ? '实时' : this.hudTime(this.duration)).fontSize(this.hudUnit(24)).letterSpacing(this.hudUnit(0.65)).fontColor(withAlpha('#FFFFFF', 0.95))
          .width(this.hudUnit(130)).textAlign(TextAlign.End).padding({ right: this.hudUnit(34) })
      }
      .width('100%').height(this.hudTap())
      .padding({ left: this.hudLeftPad(), right: this.hudRightPad() })
      .position({ x: 0, y: this.hudH() - this.hudUnit(190) })

      Row() {
        SymbolGlyph(this.hudSpeedSymbol()).fontSize(this.hudUnit(39)).fontColor(['#F6F6F6'])
      }.width(this.hudUtilityWidth()).height(this.hudTap()).justifyContent(FlexAlign.Center)
      .position({ x: this.hudUnit(63.5), y: this.hudH() - this.hudUnit(123) })
      .accessibilityText('播放速度').onClick(() => { this.showSpeedPanel = !this.showSpeedPanel; })

      Row() {
        Row() { SymbolGlyph($r('sys.symbol.gobackward_15')).fontSize(this.hudUnit(46)).fontColor(['#FAFAFA']).translate({ x: this.hudUnit(2.5) }) }
          .width(this.hudUnit(80)).height(this.hudTap()).justifyContent(FlexAlign.Center)
          .accessibilityText('后退15秒').enabled(!this.isLiveStream).onClick(() => { this.seekBy(-15000); })
        Row() { SymbolGlyph($r('sys.symbol.backward_end_fill')).fontSize(this.hudUnit(58)).fontColor(['#FAFAFA']).scale({ y: 0.96 }).translate({ y: this.hudUnit(1) }) }
          .width(this.hudUtilityWidth()).height(this.hudTap()).justifyContent(FlexAlign.Center)
          .accessibilityText('上一集').enabled(this.canStepEpisode(-1)).onClick(() => { this.stepEpisode(-1); })
        Row() {
          SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(this.hudUnit(54)).fontColor(['#FAFAFA']).scale({ x: this.isPlaying ? 0.94 : 1, y: this.isPlaying ? 1.18 : 1 })
        }.width(this.hudUtilityWidth()).height(this.hudTap()).justifyContent(FlexAlign.Center)
          .accessibilityText(this.isPlaying ? '暂停' : '播放').onClick(() => { this.togglePlay(); })
        Row() { SymbolGlyph($r('sys.symbol.forward_end_fill')).fontSize(this.hudUnit(58)).fontColor(['#FAFAFA']).scale({ y: 0.96 }).translate({ y: this.hudUnit(1.2) }) }
          .width(this.hudUtilityWidth()).height(this.hudTap()).justifyContent(FlexAlign.Center)
          .accessibilityText('下一集').enabled(this.canStepEpisode(1)).onClick(() => { this.stepEpisode(1); })
        Row() { SymbolGlyph($r('sys.symbol.goforward_15')).fontSize(this.hudUnit(46)).fontColor(['#FAFAFA']).translate({ x: this.hudUnit(-3.5) }) }
          .width(this.hudUnit(80)).height(this.hudTap()).justifyContent(FlexAlign.Center)
          .accessibilityText('前进15秒').enabled(!this.isLiveStream).onClick(() => { this.seekBy(15000); })
      }.width(this.hudUnit(460)).height(this.hudTap())
      .position({ x: this.hudW() / 2 + this.hudUnit(13.5 - 230), y: this.hudH() - this.hudUnit(123) })

      Row() { Text(this.hudQualityLabel()).fontSize(this.hudUnit(25)).letterSpacing(this.hudUnit(-0.6)).fontWeight(FontWeight.Medium).fontColor('#F7F7F7') }
        .width(this.hudUnit(140)).height(this.hudTap()).justifyContent(FlexAlign.Center)
        .position({ x: this.hudW() - this.hudUnit(232), y: this.hudH() - this.hudUnit(123) })
        .accessibilityText('视频清晰度与来源').onClick(() => { this.openSidePanel(1); })
      Row() { this.hudIcon($r('sys.symbol.list_bullet'), '播放列表', this.showSidePanel && this.sideMode === 0,
        () => { this.openSidePanel(0); }, 38.5, 1.5) }
        .position({ x: this.hudW() - this.hudUnit(132), y: this.hudH() - this.hudUnit(123) })
    }.width('100%').height('100%').opacity(this.barOpacity)
      .translate({ y: this.barOpacity > 0.5 ? 0 : this.hudUnit(70) })
      .visibility(this.barOpacity > 0.5 ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(this.barOpacity > 0.5 ? HitTestMode.Transparent : HitTestMode.BLOCK_DESCENDANTS)
      .animation({ duration: this.barOpacity > 0.5 ? MotionSpec.controlsIn : MotionSpec.controlsOut, curve: Curve.EaseOut })
  }

  @Builder
  castConfirmation() {
    Column() {
          Text('投播').fontSize(this.hudUnit(40)).fontColor('#F4F4F5').fontWeight(FontWeight.Medium)
            .width('100%').height(this.hudUnit(75)).textAlign(TextAlign.Center)
          Row() {
            Text('直接投原始链接').fontSize(this.hudUnit(28)).fontColor('#E1E2E4').layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: false }).enabled(false)
              .accessibilityText('当前鉴权片源暂不支持直接投原始链接')
          }.width('100%').height(this.hudUnit(75))
          Text('当前片源需要登录授权，暂不支持直接投原始链接。可打开系统设备列表查看可用设备。')
            .fontSize(this.hudUnit(23)).lineHeight(this.hudUnit(33)).fontColor('#ACADB1')
            .width('100%').height(this.hudUnit(110))
          Row({ space: this.hudUnit(22) }) {
            Text('取消').fontSize(this.hudUnit(28)).fontColor('#F4F4F5')
              .width(this.hudUnit(340)).height(this.hudUnit(87)).textAlign(TextAlign.Center)
              .backgroundColor('#45464C').borderRadius(this.hudUnit(44))
              .onClick(() => { this.showCastPanel = false; this.showBarTemporarily(); })
            Text('选择设备').fontSize(this.hudUnit(28)).fontColor('#FFFFFF')
              .width(this.hudUnit(340)).height(this.hudUnit(87)).textAlign(TextAlign.Center)
              .backgroundColor('#0A59F7').borderRadius(this.hudUnit(44))
              .onClick(() => { this.openCastPicker(); })
          }.width('100%').justifyContent(FlexAlign.Center).margin({ top: this.hudUnit(17) })
        
    }.width(this.hudUnit(796)).height(this.hudUnit(449))
          .padding({ left: this.hudUnit(46), right: this.hudUnit(46), top: this.hudUnit(35) })
  }

  @Builder
  aiSubtitlePanel() {
    Column() {
          Row() {
            Text('AI 字幕').fontSize(this.hudUnit(30)).fontColor('#F4F4F5').layoutWeight(1)
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(this.hudUnit(25)).fontColor(['#D5D6DA'])
              .onClick(() => { this.showAiPanel = false; this.showBarTemporarily(); })
          }.width('100%').padding(this.hudUnit(28))
          Text(this.aiStatus).fontSize(this.hudUnit(21)).fontColor('#BFC2C9').maxLines(3)
            .width('100%').padding({ left: this.hudUnit(28), right: this.hudUnit(28), bottom: this.hudUnit(16) })
          Row() {
            Text('显示双语字幕').fontSize(this.hudUnit(23)).fontColor('#DDE0E5').layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.aiBilingual }).onChange((value: boolean) => { this.aiBilingual = value; })
          }.width('100%').padding({ left: this.hudUnit(28), right: this.hudUnit(28) }).height(this.hudUnit(72))
          Scroll() {
            Column() {
              if (!this.aiBusy) {
                this.playerMenuRow(this.aiEnabled ? '重试 AI 字幕' : '重新开启 AI 字幕', '', false, true, () => {
                  if (this.aiSession !== null) { this.aiSession.retry(); }
                  else { this.aiRequested = true; this.startAiSubtitles(); }
                })
              }
              this.playerMenuRow('翻译字幕文件（可选）', 'SRT / VTT / ASS', false, !this.aiBusy, () => {
                this.showAiPanel = false; this.showAiWorkbench = true;
              })
              this.playerMenuRow('AI 字幕设置', '服务与目标语言', false, !this.aiBusy, () => { this.openAiSettings(); })
              if (this.aiEnabled || this.aiRequested) {
                this.playerMenuRow('关闭 AI 字幕', '', false, true, () => {
                  this.stopAiSubtitles(); this.aiStatus = 'AI 字幕已关闭';
                })
              }
            }.width('100%')
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        
    }.width(Math.min(this.hudUnit(600), this.hudW() * 0.85))
          .height(this.hudH() - this.hudUnit(100))
  }

  @Builder
  aiSubtitleCaption() {
    if (this.aiEnabled && (this.aiOriginal.length > 0 || this.aiTranslated.length > 0)) {
      Column({ space: this.hudUnit(5) }) {
        if (this.aiTranslated.length > 0) {
          Text(this.aiTranslated).fontSize(this.hudUnit(28) * this.subtitleScale).fontColor('#FFFFFF')
            .width('100%').textAlign(TextAlign.Center).fontWeight(FontWeight.Medium)
            .textShadow(this.aiCaptionShadows()).hitTestBehavior(HitTestMode.None)
        }
        if (this.aiOriginal.length > 0 && (this.aiBilingual || this.aiTranslated.length === 0)) {
          Text(this.aiOriginal).fontSize(this.hudUnit(this.aiTranslated.length > 0 ? 22 : 28) * this.subtitleScale)
            .width('100%').fontColor('#FFFFFF').textAlign(TextAlign.Center)
            .textShadow(this.aiCaptionShadows()).hitTestBehavior(HitTestMode.None)
        }
      }.width('88%')
        .position({ x: '6%', y: this.hudH() - Math.max(this.hudSafeBottom + this.hudUnit(18),
          this.hudUnit(this.barOpacity > 0.5 ? 205 : 52)) })
        .translate({ y: '-100%' }).hitTestBehavior(HitTestMode.None)
    }
  }

  private aiCaptionShadows(): ShadowOptions[] {
    const edge = this.hudUnit(0.8);
    return [
      { radius: edge, color: '#000000', offsetX: -edge, offsetY: 0 },
      { radius: edge, color: '#000000', offsetX: edge, offsetY: 0 },
      { radius: edge, color: '#000000', offsetX: 0, offsetY: -edge },
      { radius: edge, color: '#000000', offsetX: 0, offsetY: edge },
      { radius: this.hudUnit(1.8), color: '#B3000000', offsetX: 0, offsetY: this.hudUnit(1) }
    ];
  }

  onBackPress(): boolean {
    if (this.showAiSettings) { this.closeAiSettings(); return true; }
    if (this.showAiWorkbench) { this.showAiWorkbench = false; this.showAiPanel = true; return true; }
    if (this.showAiPanel) { this.showAiPanel = false; this.showBarTemporarily(); return true; }
    if (this.showCastPanel) { this.showCastPanel = false; this.showBarTemporarily(); return true; }
    if (this.showSidePanel) { this.closeSidePanel(); return true; }
    if (this.showRatioPanel || this.showSubPanel || this.showSubtitleStyle || this.showAudioPanel || this.showSpeedPanel) {
      this.showRatioPanel = false; this.showSubPanel = false; this.showSubtitleStyle = false;
      this.showAudioPanel = false; this.showSpeedPanel = false; this.showBarTemporarily(); return true;
    }
    return false;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.surfaceMounted) {
      XComponent({
        id: 'nasPlayerSurface',
        type: XComponentType.SURFACE,
        controller: this.activeSurfaceController()
      })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.surfaceId = this.activeSurfaceController().getXComponentSurfaceId();
          this.setupPlayer();
        })
        // ★ 手势：横向滑 = 快进退；左半屏竖滑 = 亮度；右半屏竖滑 = 音量
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            PanGesture({ direction: PanDirection.Horizontal, distance: 30 })
              .onActionStart((e: GestureEvent) => {
                if (this.isLiveStream) { this.panStartX = -1; this.seekGestureVisible = false; return; }
                // R25 边缘避让：记起点，起点落在系统返回手势区就不认这次横向拖动
                this.panStartX = e.fingerList.length > 0 ? e.fingerList[0].localX : -1;
                this.seekGestureStart = this.playPos;
                this.seekGestureTarget = this.playPos;
                this.seekGestureDelta = 0;
              })
              .onActionUpdate((e: GestureEvent) => {
                if (this.isLiveStream || this.locked) {
                  return;
                }
                const edge = 24 * Metrics.scale();
                if (this.panStartX < edge || this.panStartX > this.hudW() - edge) { return; }
                const delta = Math.round(e.offsetX / this.hudW() * Math.min(900000, this.duration));
                this.seekGestureTarget = Math.max(0, Math.min(this.duration, this.seekGestureStart + delta));
                this.seekGestureDelta = this.seekGestureTarget - this.seekGestureStart;
                this.seekGestureVisible = true;
                this.hideControls();
                this.setPlayerStatusBarVisible(true);
              })
              .onActionEnd((e: GestureEvent) => {
                if (this.isLiveStream || this.locked) {
                  return;
                }
                const w = this.screenW();
                const edge = 24 * Metrics.scale();
                let ok = true;
                if (e.fingerList.length > 0) {
                  // ★ 用起点判断：终点在边缘附近不代表手势从边缘起
                const x = this.panStartX >= 0 ? this.panStartX
                  : (e.fingerList.length > 0 ? e.fingerList[0].localX : -1);
                ok = x >= edge && x <= w - edge;
                this.panStartX = -1;
                }
                if (ok && this.seekGestureVisible && Math.abs(this.seekGestureDelta) > 500) {
                  this.requestSeek(this.seekGestureTarget);
                }
                this.seekGestureVisible = false;
                this.showBarTemporarily();
              })
              .onActionCancel(() => { this.seekGestureVisible = false; this.showBarTemporarily(); }),
            PanGesture({ direction: PanDirection.Vertical, distance: 20 })
              .onActionStart(() => {
                this.gestureBegin();
              })
              .onActionUpdate((e: GestureEvent) => {
                if (this.locked || e.fingerList.length === 0) {
                  return;
                }
                const x = e.fingerList[0].localX;
                const w = this.screenW();
                // ★ 边缘避让（方案 8.3）：左右各 24vp 内不接管手势，
                //   避免和系统返回手势/侧滑冲突
                const edge = 24 * Metrics.scale();
                if (x < edge || x > w - edge) {
                  return;
                }
                if (x < w / 2) {
                  this.applyBrightnessFromGesture(e.offsetY);
                } else {
                  this.applyVolumeFromGesture(e.offsetY);
                }
              }),
            // ★ 双击播放/暂停（原来用 LongPress 长按 2 倍速，但鸿蒙系统长按会被
            //   截图菜单抢走，所以改成双击）
            TapGesture({ count: 2 })
              .onAction(() => {
                if (!PlaybackPreferences.current().doubleTapPause || this.locked) {
                  return;
                }
                this.togglePlay();
                this.showBarTemporarily();
              }),
            // A custom gesture group supersedes the XComponent's implicit click recognizer.
            TapGesture({ count: 1 }).onAction(() => { this.handleSurfaceTap(); })
          )
        )

      }

      // playing 事件不等于显示首帧，缓冲状态也与首帧状态分别处理。
      if ((this.loadingFirstFrame || this.isBuffering) && this.errMsg.length === 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: this.hudUnit(17) }) {
            ForEach([0, 1, 2], (index: number) => {
              Circle().width(this.hudUnit(18)).height(this.hudUnit(18)).fill('#F3F7FA')
                .opacity(this.loadingBeat ? 0.9 - index * 0.22 : 0.25 + index * 0.22)
                .animation({ duration: 650, delay: index * 130, iterations: -1, playMode: PlayMode.Alternate })
            }, (index: number) => index.toString())
          }.position({ x: this.hudW() / 2 - this.hudUnit(44), y: this.hudH() / 2 - this.hudUnit(33) })
          Text(this.autoAdvancing ? '正在准备下一集…' : ((this.hasRenderedFrame || this.playbackProgressReady) ? '正在缓冲…' : (this.desiredResumeMs > 3000 ? '正在恢复播放…' : '正在加载…')))
            .fontSize(this.hudUnit(20)).fontColor(withAlpha('#FFFFFF', 0.65))
            .width(this.hudUnit(340)).textAlign(TextAlign.Center)
            .position({ x: this.hudW() / 2 - this.hudUnit(170), y: this.hudH() / 2 + this.hudUnit(20) })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(withAlpha('#000000', 0.03))
        .onAppear(() => { this.onLoadingPulseAppear(); })
        .onDisAppear(() => { this.onLoadingPulseDisappear(); })
        .hitTestBehavior(HitTestMode.None)
        .zIndex(80)
      }

      // ★ 顶部渐隐：只为控制条文字做可读性保护。
      //   之前它是常驻的 —— 控制条自动隐藏后这层 75% 黑渐变还在，
      //   看起来就像画面上盖了一块黑色遮罩。现在跟随 barOpacity 一起淡出。
      Column()
        .width('100%')
        .height(120)
        .linearGradient({
          angle: 180,
          colors: [
            [withAlpha('#000000', 0.75), 0.0],
            [withAlpha('#000000', 0.0), 1.0]
          ]
        })
        .opacity(this.barOpacity)
        .hitTestBehavior(HitTestMode.None)
        .animation({ duration: this.barOpacity > 0.5 ? MotionSpec.controlsIn : MotionSpec.controlsOut, curve: this.barOpacity > 0.5 ? Curve.EaseOut : Curve.EaseIn })

      this.hudHeader()
      this.aiSubtitleCaption()

      this.nativePlayerOverlays()
      // 控制层与参考一致：信息/工具、进度、独立居中的传输按钮。
      this.hudBottom()

      // A terminal playback error is page content, not a dismissible popup; keep its retry/return lifecycle.
      if (this.errMsg.length > 0) {
        Column({ space: this.hudUnit(24) }) {
          Text('播放未能继续').fontSize(this.hudUnit(30)).fontColor('#F4F4F5')
          Text(this.errMsg).fontSize(this.hudUnit(23)).lineHeight(this.hudUnit(32))
            .fontColor('#CBCDD1').textAlign(TextAlign.Center).maxLines(4)
          Row({ space: this.hudUnit(24) }) {
            Button('返回详情').fontSize(this.hudUnit(24)).height(this.hudUnit(62))
              .backgroundColor('#45464C').onClick(() => { this.saveNow(); router.back(); })
            Button(this.autoNextPending ? '重试下一集' : '重新连接').fontSize(this.hudUnit(24)).height(this.hudUnit(62))
              .backgroundColor('#0A59F7').onClick(() => {
                if (this.autoNextPending) { this.retryAutomaticNext(); } else { this.retryPlayback(); }
              })
          }
        }.width(this.hudUnit(760)).padding(this.hudUnit(38)).borderRadius(this.hudUnit(34))
          .backgroundColor(withAlpha('#191B20', 0.92))
          .position({ x: this.hudW() / 2 - this.hudUnit(380), y: this.hudH() / 2 })
          .translate({ y: '-50%' }).zIndex(96)
      }

      if (!this.locked) {
        Row() {
          this.hudIcon($r('sys.symbol.lock_open'), '锁定播放界面', false, () => { this.toggleLock(); }, 39)
        }
        .position({ x: Math.max(this.hudSafeLeft + 4, this.hudW() * 0.07865 - this.hudUtilityWidth() / 2), y: '50%' })
        .translate({ y: '-50%' })
        .opacity(this.barOpacity)
        .visibility(this.barOpacity > 0.5 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(this.barOpacity > 0.5 ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      }

      // ══════ 手势提示气泡 ══════
      if (this.seekGestureVisible) {
        Row({ space: this.hudUnit(8) }) {
          Text(this.hudTime(this.seekGestureTarget)).fontSize(this.hudUnit(24)).fontColor('#FFFFFF')
          Text('(' + (this.seekGestureDelta >= 0 ? '+' : '−') + this.hudTime(Math.abs(this.seekGestureDelta)) + ')')
            .fontSize(this.hudUnit(24))
            .fontColor(this.seekGestureDelta >= 0 ? '#7BD54A' : '#FFFFFF')
          Text('/ ' + this.hudTime(this.duration) + '  '
            + (this.duration > 0 ? Math.floor(this.seekGestureTarget / this.duration * 100).toString() : '0') + '%')
            .fontSize(this.hudUnit(24)).fontColor('#FFFFFF')
        }.width(this.hudUnit(580)).height(this.hudUnit(64))
          .justifyContent(FlexAlign.Center).backdropBlur(this.hudUnit(24))
          .backgroundColor(withAlpha('#1B1E25', 0.86)).borderRadius(this.hudUnit(32))
          .position({ x: this.hudW() / 2 - this.hudUnit(290), y: this.hudH() / 2 - this.hudUnit(31) }).zIndex(90)
      }
      if (this.hintVisible) {
        Text(this.gestureHint)
          .fontSize(Metrics.f(13))
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 9, bottom: 9 })
          .backdropBlur(24)
          .backgroundColor(withAlpha('#000000', 0.62))
          .borderRadius(20)
          .position({ x: '50%', y: '42%' })
          .translate({ x: '-50%' })
          .transition(TransitionEffect.OPACITY.animation({ duration: MotionPref.dur(MotionSpec.hud) }))
      }

      // ══════ 锁屏态：只留一个解锁按钮 ══════
      if (this.locked) {
        Row() {
          SymbolGlyph($r('sys.symbol.lock'))
            .fontSize(this.hudUnit(36))
            .fontColor([withAlpha('#FFFFFF', 0.96)])
        }
        .width(this.hudUtilityWidth())
        .height(this.hudTap())
        .justifyContent(FlexAlign.Center)
        .position({ x: Math.max(this.hudSafeLeft + 4, this.hudW() * 0.07865 - this.hudUtilityWidth() / 2), y: '50%' })
        .translate({ y: '-50%' })
        .onClick(() => {
          this.toggleLock();
        })
      }
      if (this.showAiSettings) {
        AiSubtitleSettings({ dark: true, fullScreenOverlay: true, configurationPurpose: this.aiConfigurationPurpose,
          onClose: () => { this.closeAiSettings(); },
          onSaved: () => { this.resumeAiAfterConfiguration(); },
          onOpenTool: () => { this.showAiSettings = false; this.showAiWorkbench = true; }
        }).width('100%').height('100%').zIndex(200).transition(this.playerPopupTransition())
      }
      if (this.showAiWorkbench) {
        AiSubtitleWorkbench({ dark: true, fullScreenOverlay: true,
          onClose: () => { this.showAiWorkbench = false; this.showAiPanel = true; },
          onConfigure: () => { this.showAiWorkbench = false; this.openAiSettings(); },
          onApply: (cues: AiSubtitleCue[]) => { this.applyAiFileCues(cues); }
        }).width('100%').height('100%').zIndex(200).transition(this.playerPopupTransition())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      const height = Number(area.height);
      if (width > 0 && height > 0) {
        this.hudWidth = width;
        this.hudHeight = height;
        this.readHudInsets();
      }
    })
  }

  @Builder
  audioRow(t: TrackInfo) {
    Row() {
      Text(t.label)
        .fontSize(Metrics.f(13))
        .fontColor(this.curAudio === t.index ? '#5B9BF8' : withAlpha('#FFFFFF', 0.85))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.curAudio === t.index) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(Metrics.f(13))
          .fontColor(['#5B9BF8'])
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.selectAudio(t);
    })
  }

  @Builder
  subRow(label: string, idx: number) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.curSubtitle === idx ? '#5B9BF8' : withAlpha('#FFFFFF', 0.85))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.curSubtitle === idx) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(13)
          .fontColor(['#5B9BF8'])
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.selectSubtitle(idx);
    })
  }
}
