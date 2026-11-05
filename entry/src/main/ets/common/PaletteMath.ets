class PaletteGroup {
  weight: number = 0;
  red: number = 0;
  green: number = 0;
  blue: number = 0;
  add(red: number, green: number, blue: number, weight: number): void {
    this.weight += weight; this.red += red * weight; this.green += green * weight; this.blue += blue * weight;
  }
}

/** Small, deterministic palette math. Colors retain the source image's hue and relative brightness. */
export class PaletteMath {
  static hex(rgb: number): string { return '#' + (rgb & 0xFFFFFF).toString(16).padStart(6, '0'); }
  static brightness(rgb: number): number {
    return (0.299 * ((rgb >> 16) & 255) + 0.587 * ((rgb >> 8) & 255) + 0.114 * (rgb & 255)) / 255;
  }
  static chromatic(rgb: number): boolean {
    const red = (rgb >> 16) & 255, green = (rgb >> 8) & 255, blue = rgb & 255;
    // Pastel pink/lavender are real colors too; do not discard them as "gray".
    return Math.max(red, green, blue) - Math.min(red, green, blue) >= 9;
  }
  private static pack(red: number, green: number, blue: number): number {
    return (Math.max(0, Math.min(255, Math.round(red))) << 16)
      | (Math.max(0, Math.min(255, Math.round(green))) << 8) | Math.max(0, Math.min(255, Math.round(blue)));
  }
  private static tint(rgb: number, retain: number, white: number): string {
    const red = (rgb >> 16) & 255, green = (rgb >> 8) & 255, blue = rgb & 255;
    return PaletteMath.hex(PaletteMath.pack(red * retain + 255 * white,
      green * retain + 255 * white, blue * retain + 255 * white));
  }
  static field(rgb: number, dark: boolean, band: number): string {
    const index = Math.max(0, Math.min(2, Math.floor(band)));
    if (dark) { return PaletteMath.tint(rgb, [0.76, 0.68, 0.60][index], 0); }
    const white = [0.18, 0.22, 0.26][index];
    return PaletteMath.tint(rgb, 1 - white, white);
  }
  static base(rgb: number, dark: boolean): string {
    return dark ? PaletteMath.tint(rgb, 0.56, 0) : PaletteMath.tint(rgb, 0.72, 0.28);
  }

  /** Area-weighted hue families avoid averaging opposite colors or selecting a tiny saturated logo. */
  static fromRgba(bytes: Uint8Array, width: number, height: number, stride: number,
    preferChromatic: boolean, premultiplied: boolean = false): number {
    if (!Number.isInteger(width) || !Number.isInteger(height) || !Number.isInteger(stride)
      || width <= 0 || height <= 0 || width > 256 || height > 256 || stride < width * 4
      || bytes.byteLength < stride * height) { return -1; }
    const hues: PaletteGroup[] = [], neutrals: PaletteGroup[] = [];
    for (let index = 0; index < 24; index++) { hues.push(new PaletteGroup()); }
    for (let index = 0; index < 8; index++) { neutrals.push(new PaletteGroup()); }
    let total = 0, colored = 0;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const offset = y * stride + x * 4, alpha = bytes[offset + 3];
        if (alpha < 16) { continue; }
        const restore = premultiplied ? 255 / alpha : 1;
        const red = Math.min(255, bytes[offset] * restore), green = Math.min(255, bytes[offset + 1] * restore), blue = Math.min(255, bytes[offset + 2] * restore);
        const weight = alpha / 255, high = Math.max(red, green, blue), low = Math.min(red, green, blue), delta = high - low;
        total += weight;
        if (delta < 9) {
          const value = Math.min(7, Math.floor((red + green + blue) / 3 / 32));
          neutrals[value].add(red, green, blue, weight); continue;
        }
        let hue = high === red ? (green - blue) / delta : high === green ? (blue - red) / delta + 2 : (red - green) / delta + 4;
        hue = (hue * 60 + 360) % 360;
        hues[Math.min(23, Math.floor(hue / 15))].add(red, green, blue, weight); colored += weight;
      }
    }
    if (total <= 0) { return -1; }
    let bestHue = 0, hueScore = 0, bestNeutral = 0;
    for (let index = 0; index < 24; index++) {
      const score = hues[index].weight + 0.5 * (hues[(index + 23) % 24].weight + hues[(index + 1) % 24].weight);
      if (score > hueScore) { hueScore = score; bestHue = index; }
    }
    for (let index = 1; index < 8; index++) { if (neutrals[index].weight > neutrals[bestNeutral].weight) { bestNeutral = index; } }
    const selectColor = hueScore > 0 && (preferChromatic
      ? hueScore >= total * 0.12 || colored >= total * 0.35 : hueScore >= neutrals[bestNeutral].weight);
    const result = new PaletteGroup();
    if (selectColor) {
      for (let step = -1; step <= 1; step++) {
        const group = hues[(bestHue + step + 24) % 24], weight = step === 0 ? 1 : 0.5;
        result.weight += group.weight * weight; result.red += group.red * weight;
        result.green += group.green * weight; result.blue += group.blue * weight;
      }
    } else {
      const group = neutrals[bestNeutral]; result.weight = group.weight;
      result.red = group.red; result.green = group.green; result.blue = group.blue;
    }
    return result.weight > 0 ? PaletteMath.pack(result.red / result.weight, result.green / result.weight, result.blue / result.weight) : -1;
  }
}
