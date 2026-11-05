import { MotionSpec, MotionPref } from './MotionSpec';

/**
 * MotionFx —— **全局动效唯一入口**
 *
 * 目的（工程约束）：
 *   · 任何页面/组件都不允许再手写 `.animation({ duration: 300, curve: ... })`
 *     这类字面量，全部从这里取；
 *   · 参数变化（调快/调慢/减少动效）只改这里和 MotionSpec，不用全工程搜；
 *   · 返回值就是 ArkUI 的 `AnimateParam`，可以直接传给
 *     `.animation()` / `.transition()` / `animateTo()`。
 *
 * 语义分组（不要混用）：
 *   · press*      按下反馈，最短
 *   · fadeIn/Out  通用淡入淡出
 *   · panel*      面板（侧栏、菜单）进退
 *   · page        页面级转场
 *   · hero        Hero 切片
 *   · image       图片淡入
 *   · controls*   播放器控制层
 */
export class MotionFx {
  /**
   * ★ 必须缓存：这些 getter 在 build 里被调用几十次/帧，
   *   每次 new 一个 AnimateParam 会把主线程拖死
   *   （真机实测：AppKilledReporter reason: ThreadBlock6S, signal:9）。
   */
  private static cache: Map<string, AnimateParam> = new Map<string, AnimateParam>();
  private static cachedReduce: boolean = false;

  private static param(duration: number, curve: Curve): AnimateParam {
    const reduce = MotionPref.reduce();
    if (reduce !== MotionFx.cachedReduce) {
      MotionFx.cache.clear();
      MotionFx.cachedReduce = reduce;
    }
    const key = duration.toString() + '_' + curve.toString();
    const hit = MotionFx.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const out: AnimateParam = {
      duration: MotionPref.dur(duration),
      curve: curve
    };
    MotionFx.cache.set(key, out);
    return out;
  }

  /** 按下/抬起这类微反馈 */
  static pressIn(): AnimateParam {
    return MotionFx.param(MotionSpec.fast, Curve.EaseOut);
  }

  /** 通用淡入 */
  static fadeIn(): AnimateParam {
    return MotionFx.param(MotionSpec.normal, Curve.EaseOut);
  }

  /** 通用淡出（比淡入略快，符合离场体感） */
  static fadeOut(): AnimateParam {
    return MotionFx.param(MotionSpec.panelOut, Curve.EaseIn);
  }

  /** 双向通用 */
  static fade(): AnimateParam {
    return MotionFx.param(MotionSpec.normal, Curve.EaseInOut);
  }

  /** 面板入场（侧栏、底部面板、菜单） */
  static panelIn(): AnimateParam {
    return MotionFx.param(MotionSpec.panelIn, Curve.EaseOut);
  }

  /** 面板离场 */
  static panelOut(): AnimateParam {
    return MotionFx.param(MotionSpec.panelOut, Curve.EaseIn);
  }

  /** 页面级转场 */
  static page(): AnimateParam {
    return MotionFx.param(MotionSpec.page, Curve.EaseInOut);
  }

  /** Hero 切片横移 */
  static hero(): AnimateParam {
    return MotionFx.param(MotionSpec.hero, Curve.EaseOut);
  }

  /** 图片淡入 */
  static image(): AnimateParam {
    return MotionFx.param(MotionSpec.image, Curve.EaseInOut);
  }

  /** 播放器控制层显 */
  static controlsIn(): AnimateParam {
    return MotionFx.param(MotionSpec.controlsIn, Curve.EaseOut);
  }

  /** 播放器控制层隐 */
  static controlsOut(): AnimateParam {
    return MotionFx.param(MotionSpec.controlsOut, Curve.EaseIn);
  }

  /** HUD 入场 */
  static hud(): AnimateParam {
    return MotionFx.param(MotionSpec.hud, Curve.EaseOut);
  }

  /* ───────── 按压反馈（clickEffect）───────── */

  private static readonly pressFx: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.94 };
  private static readonly pressSoftFx: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.97 };

  /** 标准按压：卡片、按钮、tab（复用同一个对象） */
  static press(): ClickEffect {
    return MotionFx.pressFx;
  }

  /** 轻微按压：大块容器、整卡（复用同一个对象） */
  static pressSoft(): ClickEffect {
    return MotionFx.pressSoftFx;
  }
}
