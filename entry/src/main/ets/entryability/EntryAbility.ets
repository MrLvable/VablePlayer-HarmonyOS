import { AbilityConstant, UIAbility, Want, ConfigurationConstant, Configuration } from '@kit.AbilityKit';
import { Store } from '../common/Store';
import { Theme } from '../common/Theme';
import { window, PiPWindow } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { uiMaterial } from '@kit.ArkUI';

const DOMAIN: number = 0x0001;
const TAG: string = 'NasPlayer';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    // R26：画中画能力探针（启动即打一条，不依赖 UI 导航）
    try {
      const pipOn = PiPWindow.isPiPEnabled();
      hilog.info(DOMAIN, 'NasPlay', 'CAP PiP enabled=%{public}s', pipOn.toString());
      const mi = uiMaterial.getMaterialInfo();
      hilog.info(DOMAIN, 'NasPlay', 'CAP material type=%{public}d state=%{public}d level=%{public}d',
        mi.type, mi.state, uiMaterial.getGlobalMaterialLevel());
    } catch (e) {
      hilog.info(DOMAIN, 'NasPlay', 'CAP PiP unavailable');
    }
  }

  /**
   * 系统深浅色切换时回调
   * ★ 之前 Theme.isDark() 里"跟随系统"直接 return true，永远深色。
   *   现在由这里把真实的系统模式写进 AppStorage。
   */
  onConfigurationUpdate(config: Configuration): void {
    // 应用主动指定深浅色时也会触发回调，不把应用覆盖值当成系统偏好。
    if (Theme.mode() !== 'system') {
      return;
    }
    const dark = this.readSystemDark();
    Theme.setSystemDark(dark);
    hilog.info(DOMAIN, TAG, 'colorMode changed, dark=%{public}s', dark.toString());
  }

  /** 读系统真实深浅色（config.colorMode 在本机不可靠） */
  private readSystemDark(): boolean {
    try {
      const cfg = this.context.resourceManager.getConfigurationSync();
      hilog.info(DOMAIN, 'NasPlay', 'SYS colorMode=%{public}d', cfg.colorMode);
      return cfg.colorMode === resourceManager.ColorMode.DARK;
    } catch (e) {
      hilog.info(DOMAIN, 'NasPlay', 'SYS colorMode read failed');
      return false;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');

    // 主题初始化：Store 就绪 → 读系统模式 → 恢复用户选择
    Store.init(this.context).then(() => {
      Theme.init();
      // config.colorMode 在本机恒为 DARK，改用 resourceManager
      Theme.setSystemDark(this.readSystemDark());
      return Theme.restore();
    }).then(() => {
      hilog.info(DOMAIN, TAG, 'theme restored');
    }).catch(() => {
      hilog.error(DOMAIN, TAG, 'theme restore failed');
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      // 全屏布局：内容延伸到状态栏/手势条下方（保持沉浸感）
      const win = windowStage.getMainWindowSync();
      // ★ 避让区必须同步取：真机上窗口已全屏时
      //   setWindowLayoutFullScreen(true) 的 promise 不走 then，
      //   放在 then 里会导致 syncAvoidArea 与监听都没执行（实测无日志）。
      this.syncAvoidArea(win);
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          const h: number = Math.max(data.area.topRect.height,
            AppStorage.get<number>('topAvoidHeight') ?? 0);
          AppStorage.setOrCreate<number>('topAvoidHeight', h);
          hilog.info(DOMAIN, TAG, 'avoid top=%{public}d', h);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const h: number = Math.max(data.area.bottomRect.height,
            AppStorage.get<number>('bottomAvoidHeight') ?? 0);
          AppStorage.setOrCreate<number>('bottomAvoidHeight', h);
          hilog.info(DOMAIN, TAG, 'avoid bottom=%{public}d', h);
        }
      });
      win.setWindowLayoutFullScreen(true).catch(() => {});
      win.setWindowSystemBarEnable(['status', 'navigation']).catch(() => {});
    });
  }

  /** 读一次避让区（状态栏 / 底部导航条）并写入 AppStorage */

  private syncAvoidArea(win: window.Window): void {

    try {

      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);

      AppStorage.setOrCreate<number>('topAvoidHeight', sys.topRect.height);

      const nav: window.AvoidArea =

        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);

      AppStorage.setOrCreate<number>('bottomAvoidHeight', nav.bottomRect.height);

      hilog.info(DOMAIN, TAG, 'avoid init top=%{public}d bottom=%{public}d',

        sys.topRect.height, nav.bottomRect.height);

    } catch (e) {

      hilog.error(DOMAIN, TAG, 'avoid init failed');

    }

  }


  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
    // ★ R11：Hero 轮播只在「首页可见 + 前台 + Hero 在视口内」时跑。
    //   旧实现只有页面 onPageShow 一个入口，退后台后定时器仍在空转。
    AppStorage.setOrCreate<boolean>('appActive', true);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
    AppStorage.setOrCreate<boolean>('appActive', false);
  }
}
