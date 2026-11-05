# 原生源码、补丁与许可材料清单

本目录只保存相关文字、许可、构建脚本和补丁，没有下载完整原生源码树。可供主项目vendor旁保留的最小材料为：

- `THIRD_PARTY_NOTICES.md`
- `PROVENANCE.json`、`CHECKSUMS.sha256`、`CHECKSUMS.sha512`
- `licenses/` 全目录
- `libmpv-ohos-build-20260715/` 全目录（文字构建脚本、4个补丁和MIT许可）

原始在线核查证据 `*-ref.json`、`build-release-*.json` 等保留在开发工作区 `work/mpv-evaluation/notices/`，未复制到此vendor目录。独立 `probe/` 工程包含工具junction、缓存和构建产物，没有作为vendor材料递归复制。

## 原生构建与二进制身份

| 项目 | 记录 |
|---|---|
| OHPM包 | `@mpv-ohos/mpv-arkts`1.0.0；原始完整registry发布元数据保存在 `ohpm-package-metadata.json`。 |
| wrapper源码检查快照 | GitHub `mpv-ohos/mpv-arkts` 当前head `b709a5950181376a9947860e637b38270d3cc913`；不把它冒认为包内明确记录的编译commit。已用SDK `ark_disasm` 检查HAR中实际Player.open/header路径。 |
| wrapper原生依赖配置 | `mpv/src/main/cpp/CMakeLists.txt` 固定引用20260715的 `libmpv_aarch64.zip`，预期SHA-256 `ac8b176dc4c86f4772d62ff530762ec187c3c46383bf2d476870d17dad806e5b`；GitHub release API所报asset digest一致。此次不重复下载该zip做二进制逐字节比较。 |
| build来源 | [mpv-ohos/libmpv-ohos-build](https://github.com/mpv-ohos/libmpv-ohos-build/tree/1bab837e662ffa47ce51efd0720d3ed7c4988944)，tag20260715→commit `1bab837e662ffa47ce51efd0720d3ed7c4988944`。 |
| mpv源码 | [ErBWs/mpv](https://github.com/ErBWs/mpv/tree/6edeee00a07b9b76f197aa71eee3d029fb090de4)，branch/ref `feat-ohos-0.41.0`→commit `6edeee00a07b9b76f197aa71eee3d029fb090de4`；真实HAR库内版本字串匹配 `g6edeee00a`。 |
| FFmpeg源码 | 构建脚本clone `https://code.ffmpeg.org/FFmpeg/FFmpeg.git` 的n8.0；上游GitHub镜像tag对应commit `140fd653aed8cad774f991ba083e2d01e86420c7`。真实库内版本n8.0、Lavf62.3.100、LGPL3或以后。 |
| 原生so | HAR内 `libmpv.so` 35,491,168 bytes；SHA-256 `672e98d497199a89e20893979ecec686dee1113bbe1b609c9a9266aa1679bd32`。 |

固定build快照的 `download/deps-version.sh`、`download/download-deps.sh` 记录各依赖repo/ref；`patch.sh`按目录应用补丁；`scripts/*.sh`与crossfiles记录配置。其workflow为Linux/Ubuntu，不要求用户在Windows重新编译原生库才能引入已发布HAR。

## 四个补丁

| 文件 | SHA-256 |
|---|---|
| FFmpeg support-av3a-audio-vivid.patch | `79e970caeaf121c0c866265f70aae92f3a4328724fe061c0a8c4e76e2935f23b` |
| FFmpeg support-zero-copy-hardware-decode.patch | `c15790cf227aaaa4727fe28f85f4d1e403a1d8f9485aea78e328efe552ef6720` |
| libplacebo remove-unnecessary-atomic-test.patch | `8081754fc65641696871f0b7f7cf887380919b54e443e639ac88f2ec10d4a8be` |
| libplacebo support-external-yuv-zero-copy.patch | `6aab3a5cd3253f992876eb11c20b05125e28e0b80e81603d2401ba8bc6e6ad30` |

## 许可材料

`licenses/`内保存：包内MIT原文、mpv LGPL2.1与Copyright、FFmpeg LGPL3/GPL3/LGPL2.1和LICENSE、AKI bundled Apache2与NOTICE、simdjson4.6.1 Apache2、libass0.17.4 ISC、libplacebo7.360.1 LGPL2.1、mbedTLS3.6.4许可、dav1d1.5.1 BSD、FriBidi1.0.16 LGPL、HarfBuzz11.4.5 COPYING、FreeType2.13.3 FTL、fontconfig2.17.1 COPYING、libxml2 2.15.1 Copyright、LittleCMS2.17 MIT、dovi_tool2.3.1 MIT、shaderc2025.4 Apache2和Lua5.2官方readme的MIT许可段及原HTML。

Lua许可来自官方5.2 readme，版权年份1994–2015，与5.2.4发行时期一致。simdjson版本4.6.1由wrapper中合并源文件的生成头识别；当前上游LICENSE亦另存作来源核查。`llvm-libcxx-upstream-LICENSE.txt`是上游18.1.8参考文本，**不声明已核实HAR中libc++精确来自这个版本**。

编译选项 `-Dgpl=false` 只表明mpv构建模式，mpv自己的Copyright明确提示构建开关本身不创建许可授权；FFmpeg此次实际启用version3。所有逐文件条款仍需按对应源码遵守。

此清单不声称已覆盖shaderc、Rust、SDK运行时等所有传递依赖的完整发布义务，也不声称重建了与二进制逐字节一致的整个原生依赖树。待正式发行时，应取得/保存与该二进制对应的完整源码与构建材料并完成许可证核对；此处没有执行发布。
