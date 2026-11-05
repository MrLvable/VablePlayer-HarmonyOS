import { NetImage, NetImageLoader } from './NetImage';
import { MotionSpec, MotionPref, MotionCurve } from '../common/MotionSpec';

/** Two decoded image slots; only the hidden slot may change its request. */
@Component
export struct LibraryBackdrop {
  @Prop @Watch('onSourceChanged') url: string = '';
  @Prop @Watch('onSourceChanged') token: string = '';
  @Prop @Watch('onSourceChanged') authHeader: string = '';
  @Prop @Watch('onSourceChanged') headers: Record<string, string> = {};
  @Prop @Watch('onSourceChanged') scopeId: string = '';
  @Prop @Watch('onAppearanceChanged') fallbackColor: string = '';
  @Prop @Watch('onAppearanceChanged') baseColor: string = '#000000';
  @Prop darkMode: boolean = true;
  @Prop blurRadius: number = 40;
  /** Optional appearance overrides; negative preserves the existing library treatment. */
  @Prop imageStrength: number = -1;
  @Prop baseVeilStrength: number = -1;

  @State private aUrl: string = '';
  @State private aHeaders: Record<string, string> = {};
  @State private bUrl: string = '';
  @State private bHeaders: Record<string, string> = {};
  @State private aOpacity: number = 0;
  @State private bOpacity: number = 0;
  @State private currentFallback: string = '#000000';

  private mounted: boolean = false;
  private activeSlot: number = -1;
  private loadingSlot: number = -1;
  private fading: boolean = false;
  private requestGeneration: number = 0;
  private loadingGeneration: number = 0;
  private transitionGeneration: number = 0;
  private fadeStartTimer: number = -1;
  private scopeKey: string = '';
  private wantedUrl: string = '';
  private wantedHeaders: Record<string, string> = {};
  private wantedHeaderKey: string = '';
  private aHeaderKey: string = '';
  private bHeaderKey: string = '';

  aboutToAppear(): void {
    this.mounted = true;
    this.currentFallback = this.fallbackColor.length > 0 ? this.fallbackColor : this.baseColor;
    this.onSourceChanged();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.requestGeneration++;
    this.transitionGeneration++;
    this.resetSlots();
    this.scopeKey = '';
    this.wantedUrl = '';
    this.wantedHeaders = {};
    this.wantedHeaderKey = '';
  }

  private resetSlots(): void {
    this.cancelFadeStart();
    this.aOpacity = 0;
    this.bOpacity = 0;
    this.aUrl = '';
    this.bUrl = '';
    this.aHeaders = {};
    this.bHeaders = {};
    this.aHeaderKey = '';
    this.bHeaderKey = '';
    this.activeSlot = -1;
    this.loadingSlot = -1;
    this.fading = false;
  }

  onSourceChanged(): void {
    if (!this.mounted) { return; }
    const generic = Object.keys(this.headers).length > 0 || (this.token.length === 0 && this.authHeader.length === 0);
    const headers = NetImageLoader.effectiveHeaders(this.token, this.authHeader, generic ? this.headers : undefined);
    const headerKey = NetImageLoader.headerKey(headers);
    const scope = this.scopeId + '\n' + headerKey;
    const sameScope = scope === this.scopeKey;
    if (sameScope && this.url === this.wantedUrl && headerKey === this.wantedHeaderKey) { return; }
    this.cancelFadeStart();
    this.requestGeneration++;
    this.wantedUrl = this.url;
    this.wantedHeaders = headers;
    this.wantedHeaderKey = headerKey;
    if (!sameScope) {
      // A different account/server must not retain the previous account's image.
      this.transitionGeneration++;
      this.resetSlots();
      this.scopeKey = scope;
    }
    if (this.wantedUrl.length === 0) {
      this.transitionGeneration++;
      this.resetSlots();
      this.onAppearanceChanged();
    } else if (!this.fading) {
      this.loadLatest();
    }
    // While fading, keep both decoded layers untouched and coalesce to the latest request.
  }

  onAppearanceChanged(): void {
    if (!this.mounted) { return; }
    const next = this.fallbackColor.length > 0 ? this.fallbackColor : this.baseColor;
    if (next === this.currentFallback) { return; }
    this.getUIContext().animateTo({ duration: MotionPref.dur(MotionSpec.ambient), curve: MotionCurve.fadeCurve }, () => {
      this.currentFallback = next;
    });
  }

  private slotMatchesWanted(slot: number): boolean {
    if (slot === 0) {
      return this.aUrl === this.wantedUrl && this.aHeaderKey === this.wantedHeaderKey;
    }
    if (slot === 1) {
      return this.bUrl === this.wantedUrl && this.bHeaderKey === this.wantedHeaderKey;
    }
    return false;
  }

  private loadLatest(): void {
    if (!this.mounted || this.fading || this.wantedUrl.length === 0) { return; }
    if (this.slotMatchesWanted(this.activeSlot)) {
      this.loadingSlot = -1;
      this.clearInactiveSlot();
      return;
    }
    const slot = this.activeSlot === 0 ? 1 : 0;
    this.loadingSlot = slot;
    this.loadingGeneration = this.requestGeneration;
    if (slot === 0) {
      this.aOpacity = 0;
      this.aHeaders = NetImageLoader.effectiveHeaders('', '', this.wantedHeaders);
      this.aHeaderKey = this.wantedHeaderKey;
      this.aUrl = this.wantedUrl;
    } else {
      this.bOpacity = 0;
      this.bHeaders = NetImageLoader.effectiveHeaders('', '', this.wantedHeaders);
      this.bHeaderKey = this.wantedHeaderKey;
      this.bUrl = this.wantedUrl;
    }
  }

  private currentIncoming(slot: number, url: string): boolean {
    return this.mounted && !this.fading && this.loadingSlot === slot &&
      this.loadingGeneration === this.requestGeneration && this.slotMatchesWanted(slot) &&
      url === this.wantedUrl;
  }

  private onSlotReady(slot: number, url: string): void {
    if (!this.currentIncoming(slot, url)) { return; }
    this.cancelFadeStart();
    const generation = ++this.transitionGeneration;
    const request = this.requestGeneration;
    // Cache hits can notify in the mount turn. First commit the decoded hidden layer at opacity 0.
    this.fadeStartTimer = setTimeout(() => {
      if (!this.mounted || generation !== this.transitionGeneration || request !== this.requestGeneration) { return; }
      this.fadeStartTimer = -1;
      this.startFade(generation, slot, url);
    }, MotionSpec.imageReadyFrame);
  }

  private cancelFadeStart(): void {
    if (this.fadeStartTimer < 0) { return; }
    clearTimeout(this.fadeStartTimer);
    this.fadeStartTimer = -1;
    this.transitionGeneration++;
  }

  private startFade(generation: number, slot: number, url: string): void {
    if (!this.currentIncoming(slot, url) || generation !== this.transitionGeneration) { return; }
    this.fading = true;
    if (slot === 0 && this.activeSlot === 1) {
      // A is below B: first install the decoded A under opaque B, then fade B out.
      this.aOpacity = 1;
    } else if (slot === 1) {
      this.bOpacity = 0;
    }
    this.getUIContext().animateTo({ duration: MotionPref.dur(MotionSpec.ambient), curve: MotionCurve.fadeCurve,
      onFinish: () => { this.finishFade(generation, slot); } }, () => {
      if (slot === 0) {
        this.aOpacity = 1;
        this.bOpacity = 0;
      } else {
        // A remains opaque below B throughout the fade: no midpoint brightness dip.
        this.bOpacity = 1;
      }
      this.currentFallback = this.fallbackColor.length > 0 ? this.fallbackColor : this.baseColor;
    });
  }

  private finishFade(generation: number, slot: number): void {
    if (!this.mounted || generation !== this.transitionGeneration || !this.fading) { return; }
    this.activeSlot = slot;
    this.loadingSlot = -1;
    this.fading = false;
    this.clearInactiveSlot();
    this.loadLatest();
  }

  private clearInactiveSlot(): void {
    if (this.activeSlot === 0) {
      this.bOpacity = 0;
      this.bUrl = '';
      this.bHeaders = {};
      this.bHeaderKey = '';
    } else if (this.activeSlot === 1) {
      this.aOpacity = 0;
      this.aUrl = '';
      this.aHeaders = {};
      this.aHeaderKey = '';
    }
  }

  private onSlotFailed(slot: number, url: string): void {
    if (!this.currentIncoming(slot, url)) { return; }
    this.cancelFadeStart();
    this.loadingSlot = -1;
    if (this.activeSlot < 0) { this.resetSlots(); }
    else { this.clearInactiveSlot(); }
    this.onAppearanceChanged();
  }

  private imageLayerOpacity(): number {
    return Number.isFinite(this.imageStrength) && this.imageStrength >= 0
      ? Math.min(1, this.imageStrength) : (this.darkMode ? 0.80 : 0.32);
  }

  private baseVeilOpacity(): number {
    return Number.isFinite(this.baseVeilStrength) && this.baseVeilStrength >= 0
      ? Math.min(1, this.baseVeilStrength) : (this.darkMode ? 0.34 : 0.72);
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.currentFallback)
      Stack() {
        if (this.aUrl.length > 0) {
          NetImage({ url: this.aUrl, headers: this.aHeaders,
            targetWidth: 1080, placeholderColor: this.currentFallback,
            onImageReady: (url: string) => { this.onSlotReady(0, url); },
            onFail: (url: string) => { this.onSlotFailed(0, url); } })
            .width('100%').height('100%').blur(this.blurRadius)
            .scale({ x: 1.15, y: 1.15 }).opacity(this.aOpacity)
        }
        if (this.bUrl.length > 0) {
          NetImage({ url: this.bUrl, headers: this.bHeaders,
            targetWidth: 1080, placeholderColor: this.currentFallback,
            onImageReady: (url: string) => { this.onSlotReady(1, url); },
            onFail: (url: string) => { this.onSlotFailed(1, url); } })
            .width('100%').height('100%').blur(this.blurRadius)
            .scale({ x: 1.15, y: 1.15 }).opacity(this.bOpacity)
        }
      }.width('100%').height('100%').opacity(this.imageLayerOpacity())
      Column().width('100%').height('100%')
        .backgroundColor(this.baseColor).opacity(this.baseVeilOpacity())
    }.width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.None)
  }
}
