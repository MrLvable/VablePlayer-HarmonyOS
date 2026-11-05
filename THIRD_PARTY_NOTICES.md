# 第三方组件与源码范围

自有 ArkTS、原生桥接与工程辅助代码按根目录 [Apache-2.0](LICENSE) 发布；仓库中保留原始许可的第三方代码、头文件、源码归档和构建配方按各自条款使用。本说明不将第三方代码重新授权为 Apache-2.0。

| 组件 | 仓库保留内容 | 构建时恢复 |
| --- | --- | --- |
| mpv-arkts 1.0.0 / MPV / FFmpeg | MIT 封装声明、MPV/FFmpeg 及传递依赖许可、来源、版本哈希、原生构建脚本和补丁 | `scripts/bootstrap_deps.py` 从 OHPM 取得固定 HAR，核对 SHA-256 |
| libsmb2 6.2 | LGPL-2.1-or-later、上游源码归档、头文件、构建与 SONAME 配方 | 从上游发布 HAR 中只读取匹配 SHA-256 的 arm64 动态库，不整体解压 |
| TypeScript 4.9.5 | 锁文件与测试工具依赖说明 | `npm ci`，Apache-2.0 |
| Hypium 1.0.19 | OHPM 依赖及完整性锁定 | `ohpm install`，上游许可随依赖恢复 |

原始组件材料见 [vendor 声明](vendor/THIRD_PARTY_NOTICES.md)、[MPV 源码与许可清单](vendor/mpv-arkts-1.0.0-notices/SOURCE_INVENTORY.md) 和 [SMB 来源](vendor/libsmb2-6.2/README.md)。这些材料记录上游固定版本，不构成对全部预编译传递依赖的重新审核。

本仓库不上传 HAR、`.so`、HAP 或签名材料。MPV 的 MIT 封装许可不能替代原生库条款；已知 FFmpeg 依赖涉及 LGPL-3.0-or-later，MPV 构建材料也有逐文件许可限制。发布自行构建的二进制前，应取得匹配的完整对应源码与构建材料，履行适用的声明、修改说明、替换/重新链接等要求。不能仅凭存在许可证文件就认定二进制发布义务完成。

应用内演示海报为本项目抽象图形资源；README 中的图片为本应用空来源表单与通用设置的历史真实界面，仅作隐私裁剪。未包含第三方参考应用、影视海报或用户媒体。
