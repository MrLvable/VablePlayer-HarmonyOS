# 第三方组件声明：鸿蒙 mpv 试验接入

本项目接入的 `@mpv-ohos/mpv-arkts` 1.0.0 来自 [OHPM](https://ohpm.openharmony.cn/ohpm/@mpv-ohos%2Fmpv-arkts)。其 ArkTS/C++ 封装由 ErBW_s 提供，Copyright (c) 2026 ErBW_s，采用 MIT 许可；完整原文见 `licenses/mpv-arkts-1.0.0-MIT.txt`。封装层的许可不覆盖全部原生依赖。

| 组件 | 来源、版本与许可材料 |
|---|---|
| mpv ArkTS/NAPI封装 | [mpv-ohos/mpv-arkts](https://github.com/mpv-ohos/mpv-arkts)，OHPM1.0.0；MIT原文随包保留。另包含AKI与simdjson封装依赖，相关Apache-2.0/LICENSE/NOTICE原文见 `licenses/`。 |
| libmpv原生构建 | [libmpv-ohos-build / 20260715](https://github.com/mpv-ohos/libmpv-ohos-build/tree/20260715)，构建仓库commit `1bab837e662ffa47ce51efd0720d3ed7c4988944`。脚本与补丁原样保存在 `libmpv-ohos-build-20260715/`；构建脚本自身MIT。 |
| mpv原生源码 | [ErBWs/mpv](https://github.com/ErBWs/mpv/tree/6edeee00a07b9b76f197aa71eee3d029fb090de4)，ref `feat-ohos-0.41.0`，commit `6edeee00a07b9b76f197aa71eee3d029fb090de4`。二进制内含版本 `v0.41.0-dev-g6edeee00a`。构建脚本设置 `-Dgpl=false`；mpv Copyright和LGPL-2.1全文保留，具体文件许可仍以对应源码为准。 |
| FFmpeg | 上游 [FFmpeg n8.0](https://github.com/FFmpeg/FFmpeg/tree/140fd653aed8cad774f991ba083e2d01e86420c7)，commit `140fd653aed8cad774f991ba083e2d01e86420c7`（GitHub上游镜像）。构建另应用两个OHOS补丁，见下方；启用 `--enable-version3`，实际库内标识 LGPL version3 or later。LGPL-3.0、其引用的GPL-3.0全文及FFmpeg LICENSE已保留。 |
| 其他媒体依赖 | libass0.17.4、libplacebo7.360.1、mbedTLS3.6.4、dav1d1.5.1、FriBidi1.0.16、FreeType2.13.3、HarfBuzz11.4.5、fontconfig2.17.1、libxml2 2.15.1、LittleCMS2.17、dovi_tool2.3.1、shaderc2025.4、Lua5.2.4。版本来自固定构建脚本；已保存可取得的上游许可原文，来源清单见 `SOURCE_INVENTORY.md`。 |
| C++运行时 | HAR另含 `libc++_shared.so`。保存了LLVM/libc++许可参考；该预编译运行时未在HAR中提供精确源码版本，尚不能把参考文件冒认为完整匹配的SDK声明。 |

本接入使用上游已编译HAR，未改动其中的原生库。FFmpeg补丁为：

- `patches/ffmpeg/support-av3a-audio-vivid.patch`
- `patches/ffmpeg/support-zero-copy-hardware-decode.patch`

libplacebo另应用 `remove-unnecessary-atomic-test.patch` 和 `support-external-yuv-zero-copy.patch`。四个补丁及其SHA-256均已记录。

原始HAR：16,801,367 bytes，SHA-256 `facaf095b77045d91cc0787f0544b4681b1c5fe6c7c635823c56f9eb16d6dbff`。其SHA-512与OHPM registry发布值完全一致，完整校验值见 `PROVENANCE.json`、`CHECKSUMS.sha256`、`CHECKSUMS.sha512`。

本文件记录开发集成所用组件、许可文本和源码出处，不表示完整发布合规审计或播放验收已经完成。正式分发前需按适用许可证补齐相应源码/构建与重链接等材料，核对原生传递依赖及C++运行时声明。保留这些原文及来源记录；不要把整个HAR标为MIT。
