/**
 * MotionSpec —— 全应用统一动效参数
 *
 * 方案 7.2：不能在不同页面散落 150/180/200/250/300 等随机数。
 * 所有时长从这里取；曲线语义见下方注释。
 */
export class MotionSpec {
  /** 很小的控件状态变化（按下反馈） */
  static readonly fast: number = 120;
  /** 常规入场/离场 */
  static readonly normal: number = 220;
  /** 面板滑入 */
  static readonly panelIn: number = 260;
  /** 面板滑出（比滑入快，符合离场体感） */
  static readonly panelOut: number = 180;
  /** Player popovers use a shorter fade/scale than the full-height side panel. */
  static readonly menuIn: number = 200;
  static readonly menuOut: number = 160;
  /** 页面转场 */
  static readonly page: number = 320;
  /** Hero 切片/换色 */
  static readonly hero: number = 420;
  /** 已解码的媒体背景交叉淡化；与前景Hero滑动分开，避免整页换色闪烁。 */
  static readonly ambient: number = 820;
  /** Let a decoded image's hidden slot mount before animating opacity; not a display-vsync promise. */
  static readonly imageReadyFrame: number = 16;
  /** 图片淡入 */
  static readonly image: number = 160;
  /** 数字滚动 */
  static readonly digit: number = 100;
  /** HUD 入场 */
  static readonly hud: number = 140;
  /**
   * 播放器控制层显隐（方案 §9.3）：录屏量到约 70–120ms，
   * 入 110ms EaseOut、出 100ms EaseIn。不能用 220ms 的常规面板时长 ——
   * 参考里控制条是「快速移出/移入并淡化」，不是面板式缓动。
   */
  static readonly controlsIn: number = 110;
  static readonly controlsOut: number = 100;
  /** 控制层自动隐藏（方案 §9.3 建议 3 秒；录屏触点不可见，属于产品规则） */
  static readonly controlsAutoHide: number = 3000;
  /** 手势结束 HUD 驻留时间（毫秒，用于 setTimeout，不是动画时长） */
  static readonly hudHold: number = 500;
}

/** 曲线语义（方案 7.2） */
export class MotionCurve {
  /** 普通入场 */
  static readonly inCurve: Curve = Curve.EaseOut;
  /** 普通离场 */
  static readonly outCurve: Curve = Curve.EaseIn;
  /** 颜色和图像淡化 */
  static readonly fadeCurve: Curve = Curve.EaseInOut;
}

/**
 * 弹簧参数（方案 7.2）。
 * 注意：参数是响应/阻尼等物理语义，不是毫秒，不能承诺严格在 220ms 结束。
 * 只用于按钮松手、选中背景、可中断的微形变；面板和视频控制层不弹跳。
 */
export const SPRING_RESPONSE: number = 0.32;
export const SPRING_DAMPING: number = 0.88;

/** 系统「减少动态效果」开关的读取结果（由 Ability 写入 AppStorage） */
export class MotionPref {
  static readonly KEY_REDUCE: string = 'reduceMotion';

  static reduce(): boolean {
    const v = AppStorage.get<boolean>(MotionPref.KEY_REDUCE);
    return v !== undefined ? v : false;
  }

  /** 减少动效时把时长压到几乎瞬时，但保留极短淡化以维持可感知性 */
  static dur(normalMs: number): number {
    return MotionPref.reduce() ? 80 : normalMs;
  }
}
