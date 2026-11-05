# 第三方组件声明

当前vendor中的 `mpv-arkts-1.0.0.har` 对应的 [完整声明与许可材料](mpv-arkts-1.0.0-notices/THIRD_PARTY_NOTICES.md) 已保留，包括封装MIT、mpv/FFmpeg相关LGPL文本、原生构建来源、补丁和SHA-256/512校验值。

封装MIT不代表整个原生二进制都是MIT。此材料记录开发集成来源，完整发布审计及全部传递依赖/SDK运行时声明仍需核对，见同目录 [源码材料清单](mpv-arkts-1.0.0-notices/SOURCE_INVENTORY.md)。

SMB直连另动态链接 [libsmb2 6.2](libsmb2-6.2/README.md)（LGPL-2.1-or-later）。仅引入固定arm64原生库，完整LGPL、上游源码归档、头文件、构建/SONAME材料及SHA-256清单已保留；不导入旧HAR的整文件readFile封装或额外libc++。本工程另写有界偏移读取NAPI与本机Range桥接，设备与真实SMB服务验收仍待用户重新授权。
