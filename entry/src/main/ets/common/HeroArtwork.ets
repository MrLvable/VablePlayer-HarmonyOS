/** Shared, explicitly controlled Hero reveal geometry. Native Scroll never supplies the overscroll displacement. */
export class HeroArtwork {
  /** Reference clip: about 0.3–0.4s main return with a small overshoot and a decaying tail. */
  static readonly returnResponse: number = 0.38;
  static readonly returnDamping: number = 0.78;

  static pullExtension(offset: number, width: number, reduceMotion: boolean): number {
    if (reduceMotion || !Number.isFinite(offset) || offset >= 0) { return 0; }
    const w = Number.isFinite(width) && width > 0 ? width : 440;
    const limit = w * 0.85;
    // A constant finger-to-artwork slope throughout the usable drag range.
    // Only the final safety bound stops growth; resistance must not slow the
    // image progressively while the finger continues moving at a steady speed.
    return Math.min(-offset, limit);
  }

  static imageHeight(width: number, ratio: number): number {
    const w = Number.isFinite(width) && width > 0 ? width : 440;
    const aspect = Number.isFinite(ratio) && ratio > 0 ? ratio : 16 / 9;
    // Fit a complete landscape or portrait source without making a tall poster consume the page.
    return Math.min(w / aspect, Math.min(520, w * 1.15));
  }

  static imageWidth(width: number, ratio: number, extension: number): number {
    const aspect = Number.isFinite(ratio) && ratio > 0 ? ratio : 16 / 9;
    return (HeroArtwork.imageHeight(width, aspect) + Math.max(0, extension)) * aspect;
  }
}

/** Passive touch observation: no gesture recognizer, so Swiper and buttons keep their input. */
export class HeroPullTracker {
  private startX: number = 0;
  private startY: number = 0;
  private atTop: boolean = false;
  private axis: number = 0;
  active: boolean = false;
  offset: number = 0;
  releasing: boolean = false;

  begin(x: number, y: number, scrollOffset: number): void {
    this.reset();
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(scrollOffset)) { return; }
    this.startX = x; this.startY = y; this.atTop = scrollOffset <= 0.5; this.active = true;
  }

  move(x: number, y: number): void {
    if (!this.active || !this.atTop || !Number.isFinite(x) || !Number.isFinite(y)) { return; }
    const dx = Math.abs(x - this.startX), dy = y - this.startY;
    if (this.axis === 0 && Math.max(dx, Math.abs(dy)) >= 8) {
      if (dx > Math.abs(dy)) { this.axis = 2; }
      else if (dy > dx * 1.15) { this.axis = 1; }
    }
    this.offset = this.axis === 1 && dy > 0 ? -dy * 0.55 : 0;
  }

  finish(): void { this.active = false; this.offset = 0; this.releasing = true; }
  reset(): void { this.active = false; this.offset = 0; this.releasing = false; this.axis = 0; this.atTop = false; }
}
