# 从源码构建

## 环境

- DevEco Studio 及支持工程 `26.0.0` 产品配置的 HarmonyOS API 26 SDK、原生 CMake/Ninja/Clang 工具链。
- Python 3.10+：恢复固定第三方依赖与执行公开检查。
- Node.js 22 或更新的兼容版本：运行离线契约测试；完整 ArkTS 构建使用 DevEco 附带的 Node/Hvigor。
- 本工程使用 Stage 模型，入口为 `entry`，当前原生依赖仅为 `arm64-v8a`。不要用 Android SDK、APK 或其他架构原生库替代。

## 初始化

```sh
git clone https://github.com/MrLvable/VablePlayer-HarmonyOS.git
cd VablePlayer-HarmonyOS
python3 scripts/bootstrap_deps.py
ohpm install
```

Windows 可以使用 `python`。`bootstrap_deps.py` 会在文件不存在时，将无签名模板复制为本机 `build-profile.json5`，然后从固定公共上游下载并校验 MPV HAR 与 SMB 动态库。已有依赖哈希不符会报错，不覆盖未知版本。脚本不请求服务器账号、API Key 或签名密码；请勿将真实值写入模板。

在 DevEco Studio 打开项目并同步 OHPM/Hvigor。若命令行未配置 `ohpm`，使用 DevEco 的包管理工具；完整安装目录中的 `tools/ohpm/bin/ohpm` 提供同一入口。同步后确认 `entry/oh_modules/@mpv-ohos/mpv-arkts` 与三个本地 NAPI 声明依赖均已恢复。

## 构建与签名

在 IDE 中选择 `default` 产品，构建 `entry` HAP。真机安装请使用自己的华为账号和 Signing Configs；SDK、本机路径、实际 `build-profile.json5`、证书及口令全部由 `.gitignore` 排除。仓库只跟踪 `build-profile.example.json5`，这也避免 IDE 自动签名修改被顺带提交。

Windows 可通过项目辅助脚本调用 DevEco 配套工具：

```powershell
./build-helper.ps1 -DevEcoHome '你的 DevEco Studio 安装目录'
```

脚本设置当前进程的 SDK/JDK/Node 环境，调用 `assembleHap --no-daemon`，不安装或操作手机。输出位于 `entry/build/default/outputs/default/`，文件名由实际构建及签名方式决定。本仓库无预签名稳定发行版。

SMB、AI 音频提取、本地授权 fd 均由 `entry/src/main/cpp/CMakeLists.txt` 构建。最终产物需要桥接模块与其动态依赖，只有 `.d.ts` 不代表模块已打包。MPV 恢复包包含原生运行时，勿再混入第二份不匹配的 `libc++_shared.so`。

## 不安装 Harmony SDK 的离线检查

```sh
npm ci --ignore-scripts
python3 scripts/bootstrap_deps.py
python3 scripts/prepare_test_types.py
MPV_LIB_TYPES=.cache/mpv/MpvLib.d.ets npm test
python3 scripts/check_publication.py --git-history
```

PowerShell 最后几步对应：

```powershell
python scripts/prepare_test_types.py
$env:MPV_LIB_TYPES = '.cache/mpv/MpvLib.d.ets'
npm test
python scripts/check_publication.py --git-history
```

提取脚本只读取固定 HAR 的真实 MPV 声明到 Git 忽略的 `.cache/`；不生成可运行播放器，也不替代 `ohpm install`。完整安装 OHPM 后可不提取声明、清除 `MPV_LIB_TYPES`，由测试自动读取包内类型。

仓库附带 [GitHub Actions 模板](ci/source-checks.yml)，用于源码/历史检查和离线契约测试。当前发布授权没有写入工作流的权限，因此模板放在文档目录，**尚未启用自动 CI**。维护者可将它复制到 `.github/workflows/source-checks.yml` 后通过具备工作流写入权限的方式提交。模板不执行华为账号登录、应用签名或真机测试。`npm test` 通过不等于 ArkTS、原生编译或真实网络播放通过。最近实际结果见 [VALIDATION](VALIDATION.md)。

## 常见问题

- **下载失败**：确认可访问 OHPM 与 GitHub 上游，重试恢复脚本；不要关闭 TLS 校验或去掉哈希检查。
- **缺少 MPV 类型**：先同步 OHPM，或按离线方式准备声明并设置 `MPV_LIB_TYPES`。
- **SDK 配置不匹配**：使用支持 API 26 的完整 DevEco SDK；更低版本需要单独适配材料和系统 API，不能只修改版本号。
- **签名/本机路径变化**：修改本机忽略的文件；提交前运行公开检查，并检查暂存列表。
- **x86 模拟器缺原生库**：当前上游原生依赖只保留 arm64，不能据此推断 x86 可运行。

依赖许可与二进制发布范围见 [第三方说明](../THIRD_PARTY_NOTICES.md)。
