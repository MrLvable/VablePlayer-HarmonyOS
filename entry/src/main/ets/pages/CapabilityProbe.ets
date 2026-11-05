/**
 * CapabilityProbe —— 能力探针页（仅开发调试构建使用）
 *
 * 目的：在真实设备 + 真实 SDK 上逐项验证实施方案所依赖的官方能力，
 *       把结果渲染成文本，便于通过 uitest dumpLayout 读取，不依赖人工看截图。
 *
 * 验证项目：
 *   A. 运行时 syscap 与沉浸光感支持度
 *   B. Navigation + NavDestination + NavPathStack
 *   C. Tabs + TabContent
 *   D. ${'$'}HDS：HdsNavigation 标题栏 + 系统材质
 *   E. HDS：HdsTabs + barFloatingStyle 悬浮态（含 systemMaterialEffect）
 *   F. backgroundBlurStyle × ThemeColorMode
 *   G. bindSheet 半模态
 *   H. animateTo / TransitionEffect / geometryTransition / springMotion
 *   I. Swiper.onContentDidScroll 归一化位移
 *   J. 窗口安全区与 vp 尺寸
 *
 * 准入判定：公开声明 + 编译通过 + 真机行为正确。仅 import 成功不算通过。
 */

import { withAlpha } from '../common/Theme';
import { window, display, curves, uiMaterial, promptAction } from '@kit.ArkUI';
import { PiPWindow } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  HdsBarStyle,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';

interface ProbeRow {
  id: string;
  label: string;
  status: string;   // PASS / FAIL / INFO
  note: string;
}

interface SafeAreaInfo {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

@Entry
@Component
struct CapabilityProbe {
  @State rows: ProbeRow[] = [];
  @State winW: number = 0;
  @State winH: number = 0;
  @State density: number = 0;
  @State safeTop: number = 0;
  @State safeBottom: number = 0;

  // D. HdsNavigation 演示
  private navStack: NavPathStack = new NavPathStack();
  // C/E. Tabs 演示
  private tabsCtl: HdsTabsController = new HdsTabsController();
  @State curTab: number = 0;

  // G. bindSheet
  @State showSheet: boolean = false;

  // H. 动画演示
  @State boxScale: number = 1;
  @State boxShown: boolean = true;
  @State geoOn: boolean = false;

  // I. Swiper 归一化位移
  private swiperCtl: SwiperController = new SwiperController();
  @State swiperPos: number = 0;
  @State swiperIdx: number = 0;
  @State swiperPosText: string = 'n/a';

  aboutToAppear(): void {
    this.collectRuntimeFacts();
    this.runProgrammaticChecks();
  }

  /* ───────── A/J. 运行时事实与 syscap ───────── */

  private collectRuntimeFacts(): void {
    try {
      const d = display.getDefaultDisplaySync();
      this.density = d.densityPixels;
      this.winW = d.width / d.densityPixels;
      this.winH = d.height / d.densityPixels;
    } catch (e) {
      // 忽略
    }
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      const avoid = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const d = display.getDefaultDisplaySync();
      this.safeTop = avoid.topRect.height / d.densityPixels;
      this.safeBottom = avoid.bottomRect.height / d.densityPixels;
      const rect = w.getWindowProperties().windowRect;
      this.winW = rect.width / d.densityPixels;
      this.winH = rect.height / d.densityPixels;
    }).catch(() => {
    });
  }

  private push(id: string, label: string, ok: boolean, note: string): void {
    this.rows.push({
      id: id,
      label: label,
      status: ok ? 'PASS' : 'FAIL',
      note: note
    });
  }

  private info(id: string, label: string, note: string): void {
    this.rows.push({
      id: id,
      label: label,
      status: 'INFO',
      note: note
    });
  }

  private runProgrammaticChecks(): void {
    // R26：画中画能力探针（先确认本机支持再实现，不硬写）
    try {
      const on = PiPWindow.isPiPEnabled();
      this.info('A8', 'PiPWindow.isPiPEnabled', on ? '支持' : '不支持');
      hilog.info(0x0001, 'NasPlay', 'CAP PiP enabled=%{public}s', on.toString());
    } catch (e) {
      this.info('A8', 'PiPWindow.isPiPEnabled', '异常/不可用');
      hilog.info(0x0001, 'NasPlay', 'CAP PiP throw');
    }
    // A1 syscap
    this.push('A1', 'syscap HDSComponent.Core',
      canIUse('SystemCapability.UIDesign.HDSComponent.Core'),
      canIUse('SystemCapability.UIDesign.HDSComponent.Core') ? '可用' : '不可用');

    // A2 syscap Full
    this.push('A2', 'syscap HDSComponent.Full',
      canIUse('SystemCapability.UIDesign.HDSComponent.Full'),
      canIUse('SystemCapability.UIDesign.HDSComponent.Full') ? '可用' : '不可用');

    // A3 沉浸光感
    let immOk = false;
    let immNote = '';
    try {
      immOk = uiMaterial.isImmersiveMaterialSupported();
      immNote = immOk ? '支持' : '不支持';
    } catch (e) {
      immNote = '调用异常 ' + (e as BusinessError).message;
    }
    this.push('A3', 'uiMaterial 沉浸光感', immOk, immNote);

    // A4 材质配置状态
    try {
      const info = uiMaterial.getMaterialInfo();
      this.info('A4', 'uiMaterial.getMaterialInfo',
        'type=' + info.type.toString() + ' state=' + info.state.toString());
    } catch (e) {
      this.info('A4', 'uiMaterial.getMaterialInfo', '异常 ' + (e as BusinessError).message);
    }

    // A5 全局材质等级
    try {
      const lv = uiMaterial.getGlobalMaterialLevel();
      this.info('A5', 'uiMaterial.getGlobalMaterialLevel', 'level=' + lv.toString());
    } catch (e) {
      this.info('A5', 'uiMaterial.getGlobalMaterialLevel', '异常');
    }

    // A6 hdsMaterial 枚举可用性（编译期已证明存在，这里记录值）
    this.info('A6', 'hdsMaterial 枚举',
      'IMMERSIVE=' + hdsMaterial.MaterialType.IMMERSIVE.toString() +
      ' SMOOTH=' + hdsMaterial.MaterialLevel.SMOOTH.toString());

    // A7 springMotion 可调用
    try {
      const c = curves.springMotion(0.32, 0.88);
      this.push('A7', 'curves.springMotion', c !== undefined, '返回曲线对象');
    } catch (e) {
      this.push('A7', 'curves.springMotion', false, '异常');
    }

    // J 窗口事实
    this.info('J1', '窗口 vp 尺寸', this.winW.toFixed(1) + ' × ' + this.winH.toFixed(1) + ' vp');
    this.info('J2', '显示密度', this.density.toString() + 'x');
    this.info('J3', '安全区', 'top=' + this.safeTop.toFixed(1) + ' bottom=' + this.safeBottom.toFixed(1) + ' vp');
  }

  /* ───────── H. 动画 ───────── */

  private runAnimateTo(): void {
    this.getUIContext().animateTo({
      duration: 220,
      curve: Curve.EaseOut
    }, () => {
      this.boxScale = this.boxScale === 1 ? 1.25 : 1;
    });
  }

  private toggleTransition(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.boxShown = !this.boxShown;
    });
  }

  /* ───────── 界面 ───────── */

  /**
   * R13 材质实验台：四组 Dock 对照，统一 300×55vp。
   * which: 0=HDS 默认  1=HDS 条件齐全  2=标准 Tabs 悬浮材质  3=自绘玻璃
   */
  @Builder
  materialLab(which: number) {
    Stack() {
      // 明暗条纹：一列里同时有亮底、暗底、彩色底，才能看出玻璃是否真的采样
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [
            ['#F2F3F7', 0.00],
            ['#1E2129', 0.20],
            ['#E8B23A', 0.40],
            ['#123A6B', 0.58],
            ['#F5F6FA', 0.78],
            ['#262A33', 1.00]
          ]
        })

      if (which === 1) {
        HdsTabs({ barPosition: BarPosition.End, controller: this.tabsCtl }) {
          TabContent() {
            Column()
          }.tabBar('首页')

          TabContent() {
            Column()
          }.tabBar('发现')

          TabContent() {
            Column()
          }.tabBar('收藏')
        }
        .barHeight(55)
        .vertical(false)
        .barOverlap(true)
        .barFloatingStyle({
          barWidth: {
            smallWidth: 300,
            mediumWidth: 300,
            largeWidth: 300
          },
          barSideMargin: 0,
          barBottomMargin: 0,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .width(300)
        .height(55)
      } else if (which === 2) {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() {
            Column()
          }.tabBar('首页')

          TabContent() {
            Column()
          }.tabBar('发现')

          TabContent() {
            Column()
          }.tabBar('收藏')
        }
        .barHeight(55)
        .vertical(false)
        .barOverlap(true)
        .barFloatingStyle({
          barWidth: {
            smallBarWidth: 300,
            mediumBarWidth: 300,
            largeBarWidth: 300
          },
          barSideMargin: 0,
          barBottomMargin: 0,
          systemMaterial: new uiMaterial.ImmersiveMaterial()
        })
        .width(300)
        .height(55)
      } else if (which === 3) {
        Row() {
          Text('首页')
            .fontSize(11)
            .fontColor('#317AF7')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('发现')
            .fontSize(11)
            .fontColor('#B6BAC3')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('收藏')
            .fontSize(11)
            .fontColor('#B6BAC3')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }
        .width(300)
        .height(55)
        .padding({ left: 6, right: 6 })
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
        .backgroundColor(withAlpha('#000000', 0.42))
        .borderRadius(28)
        .border({ width: 0.5, color: withAlpha('#FFFFFF', 0.14) })
      } else {
        HdsTabs({ barPosition: BarPosition.End, controller: this.tabsCtl }) {
          TabContent() {
            Column()
          }.tabBar('首页')

          TabContent() {
            Column()
          }.tabBar('发现')

          TabContent() {
            Column()
          }.tabBar('收藏')
        }
        .barHeight(55)
        .width(300)
        .height(55)
      }
    }
    .width('100%')
    .height(80)
    .borderRadius(8)
    .clip(true)
  }

  build() {
    Column() {
      // 顶部标题
      Row() {
        Text('能力探针 CapabilityProbe')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        Text(this.rows.length.toString() + ' 项')
          .fontSize(12)
          .fontColor('#8A8A92')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 6 }) {

          // ═══ 结果文本（供 dumpLayout 读取）═══
          ForEach(this.rows, (r: ProbeRow) => {
            Row() {
              Text(r.status)
                .fontSize(11)
                .fontColor(r.status === 'PASS' ? '#3DD68C' : (r.status === 'FAIL' ? '#FF6B6B' : '#8A8A92'))
                .width(46)
              Text(r.id + ' ' + r.label)
                .fontSize(12)
                .fontColor('#F5F6F8')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(r.note)
                .fontSize(11)
                .fontColor('#B6BAC3')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor('#141417')
            .borderRadius(6)
          }, (r: ProbeRow) => r.id)

          // ═══ B. Navigation + NavDestination ═══
          this.sectionTitle('B · Navigation + NavDestination + NavPathStack')
          Stack() {
            Navigation(this.navStack) {
              Column() {
                Text('NavBar 内容（点击进入目的页）')
                  .fontSize(12)
                  .fontColor('#B6BAC3')
                Button('pushPath 进目的页')
                  .fontSize(11)
                  .height(28)
                  .margin({ top: 6 })
                  .onClick(() => {
                    this.navStack.pushPathByName('probeDest', 'hello');
                  })
              }
              .justifyContent(FlexAlign.Center)
            }
            .title('Navigation 标题')
            .titleMode(NavigationTitleMode.Mini)
            .mode(NavigationMode.Stack)
            .navDestination(this.probeDestBuilder)
            .width('100%')
            .height('100%')
          }
          .width('100%')
          .height(150)
          .borderRadius(10)
          .clip(true)
          .backgroundColor('#141417')

          // ═══ C. Tabs + TabContent ═══
          this.sectionTitle('C · Tabs + TabContent（标准 ArkUI）')
          Stack() {
            Tabs({ barPosition: BarPosition.End, index: this.curTab }) {
              TabContent() {
                Text('页签 A 内容').fontSize(12).fontColor('#B6BAC3')
              }.tabBar('A')

              TabContent() {
                Text('页签 B 内容').fontSize(12).fontColor('#B6BAC3')
              }.tabBar('B')
            }
            .barHeight(40)
            .onChange((i: number) => {
              this.curTab = i;
            })
            .width('100%')
            .height('100%')
          }
          .width('100%')
          .height(140)
          .borderRadius(10)
          .clip(true)
          .backgroundColor('#141417')

          // ═══ D. HdsNavigation（含系统材质）═══
          this.sectionTitle('D · HdsNavigation 标题栏 + systemMaterialEffect')
          Stack() {
            HdsNavigation(this.navStack) {
              Column() {
                Text('HDS 导航栏内容')
                  .fontSize(12)
                  .fontColor('#B6BAC3')
                Text('titleBar.style.systemMaterialEffect')
                  .fontSize(10)
                  .fontColor('#8A8A92')
                  .margin({ top: 4 })
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .height('100%')
            }
            .titleMode(HdsNavigationTitleMode.MINI)
            .mode(NavigationMode.Stack)
            .titleBar({
              content: {
                title: {
                  mainTitle: 'HDS 标题'
                }
              },
              style: {
                scrollEffectOpts: {
                  enableScrollEffect: true,
                  scrollEffectType: ScrollEffectType.COMMON_BLUR
                },
                systemMaterialEffect: {
                  materialType: hdsMaterial.MaterialType.IMMERSIVE,
                  materialLevel: hdsMaterial.MaterialLevel.SMOOTH
                }
              }
            })
            .width('100%')
            .height('100%')
          }
          .width('100%')
          .height(160)
          .borderRadius(10)
          .clip(true)
          .backgroundColor('#141417')

          // ═══ E. Dock 材质四组对照（R13，方案 §7.1 §7.2）═══
          // 统一几何 300×55vp，背景是明暗条纹（模拟海报），
          // 不叠自己的背景色/边框 —— 否则会屏蔽系统材质，测不出来。
          this.sectionTitle('E1 · HDS 默认（无条件）')
          this.materialLab(0)
          this.sectionTitle('E2 · HDS + End/vertical(false)/barOverlap/ADAPTIVE')
          this.materialLab(1)
          this.sectionTitle('E3 · 标准 Tabs + barFloatingStyle.systemMaterial')
          this.materialLab(2)
          this.sectionTitle('E4 · 自绘玻璃（生产 BottomBar 现方案）')
          this.materialLab(3)

          // ═══ F. backgroundBlurStyle × colorMode ═══
          this.sectionTitle('F · backgroundBlurStyle × ThemeColorMode')
          Row({ space: 8 }) {
            Column() {
              Text('DARK').fontSize(10).fontColor('#FFFFFF')
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
            .backgroundColor(withAlpha('#000000', 0.33))
            .borderRadius(10)

            Column() {
              Text('LIGHT').fontSize(10).fontColor('#000000')
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.LIGHT })
            .backgroundColor(withAlpha('#FFFFFF', 0.53))
            .borderRadius(10)

            Column() {
              Text('NONE').fontSize(10).fontColor('#FFFFFF')
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(withAlpha('#000000', 0.33))
            .borderRadius(10)
          }
          .width('100%')

          // ═══ G. bindSheet ═══
          this.sectionTitle('G · bindSheet 半模态')
          Row({ space: 8 }) {
            Button('打开 bindSheet')
              .fontSize(12)
              .height(36)
              .layoutWeight(1)
              .onClick(() => {
                this.showSheet = true;
              })
          }
          .width('100%')
          .bindSheet(this.showSheet, this.sheetBuilder(), {
            height: 220,
            dragBar: true,
            onDisappear: () => {
              this.showSheet = false;
            }
          })

          // ═══ H. 动画 ═══
          this.sectionTitle('H · animateTo / TransitionEffect / geometryTransition')
          Row({ space: 8 }) {
            Column() {
              Text('scale').fontSize(10).fontColor('#FFFFFF')
            }
            .width(70)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#317AF7')
            .borderRadius(10)
            .scale({ x: this.boxScale, y: this.boxScale })
            .onClick(() => {
              this.runAnimateTo();
            })

            Column() {
              if (this.boxShown) {
                Text('transition').fontSize(10).fontColor('#FFFFFF')
              }
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#2E7D5B')
            .borderRadius(10)
            .transition(TransitionEffect.OPACITY.combine(
              TransitionEffect.translate({ y: 8 })
            ))
            .onClick(() => {
              this.toggleTransition();
            })

            Column() {
              Text('geometry').fontSize(10).fontColor('#FFFFFF')
            }
            .width(80)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#8B5CF6')
            .borderRadius(this.geoOn ? 28 : 10)
            .geometryTransition('probe-geo-box')
            .onClick(() => {
              this.getUIContext().animateTo({
                duration: 320,
                curve: Curve.EaseInOut
              }, () => {
                this.geoOn = !this.geoOn;
              });
            })
          }
          .width('100%')

          // ═══ I. Swiper.onContentDidScroll ═══
          this.sectionTitle('I · Swiper.onContentDidScroll 归一化位移')
          Column() {
            Swiper(this.swiperCtl) {
              ForEach([0, 1, 2], (n: number) => {
                Column() {
                  Text('页 ' + n.toString()).fontSize(14).fontColor('#FFFFFF')
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .backgroundColor(n === 0 ? '#317AF7' : (n === 1 ? '#2E7D5B' : '#8B5CF6'))
              }, (n: number) => n.toString())
            }
            .loop(false)
            .indicator(false)
            .onChange((i: number) => {
              this.swiperIdx = i;
            })
            .onContentDidScroll((selectedIndex: number, index: number, position: number, mainAxisLength: number) => {
              this.swiperPos = position;
              this.swiperPosText = 'sel=' + selectedIndex.toString() +
                ' idx=' + index.toString() +
                ' pos=' + position.toFixed(3) +
                ' len=' + mainAxisLength.toFixed(0);
            })
            .width('100%')
            .height(80)

            Text('sel=' + this.swiperIdx.toString() + '  ' + this.swiperPosText)
              .fontSize(11)
              .fontColor('#B6BAC3')
              .margin({ top: 4 })
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#141417')
          .borderRadius(10)

          Blank().height(40)
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0A0A0B')
  }

  @Builder
  sectionTitle(t: string) {
    Text(t)
      .fontSize(12)
      .fontColor('#8A8A92')
      .width('100%')
      .margin({ top: 10, bottom: 2 })
  }

  @Builder
  probeDestBuilder(name: string, param: Object) {
    NavDestination() {
      Column() {
        Text('目的页：' + name)
          .fontSize(13)
          .fontColor('#FFFFFF')
        Text('参数：' + (param !== undefined ? param.toString() : '-'))
          .fontSize(11)
          .fontColor('#B6BAC3')
          .margin({ top: 4 })
        Button('返回')
          .fontSize(11)
          .height(28)
          .margin({ top: 8 })
          .onClick(() => {
            this.navStack.pop();
          })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height('100%')
    }
    .title('NavDestination')
    .backgroundColor('#141417')
  }

  @Builder
  sheetBuilder() {
    Column() {
      Text('bindSheet 半模态')
        .fontSize(15)
        .fontColor('#FFFFFF')
      Text('若此面板可拖动收起，则 bindSheet 可用')
        .fontSize(11)
        .fontColor('#B6BAC3')
        .margin({ top: 6 })
      Button('关闭')
        .fontSize(12)
        .height(32)
        .margin({ top: 12 })
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Center)
  }
}
