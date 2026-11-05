# 本地测试

测试主要读取当前工程的实际 ArkTS 方法或 C helper，在受控依赖中检查边界。它们不需要个人 NAS、云 API Key、手机或真实媒体。通过源方法检查，不能推断设备解码、真实服务连接、视觉帧率、小窗或投屏已通过。

## Node.js 契约检查

需要 Node.js 18+ 和 TypeScript。先按 [构建指南](../docs/BUILDING.md) 恢复固定 MPV 依赖并执行 `ohpm install`，其中播放器声明检查会读取已安装 OHPM 包的真实类型。

使用仓库锁定的测试依赖：

```sh
npm ci
npm test
```

`npm test` 自动枚举当前 51 个 `validate-*.cjs` 脚本；不把脚本内部的断言组再混算成同一“测试数”。也可使用已有 TypeScript，通过 `TYPESCRIPT_PATH` 指向包目录或 `lib/typescript.js`，再在项目根逐项运行：

```powershell
Get-ChildItem tests/validate-*.cjs | ForEach-Object {
  node $_.FullName
  if ($LASTEXITCODE -ne 0) { throw "检查失败：$($_.Name)" }
}
```

Linux/macOS：

```sh
for test in tests/validate-*.cjs; do
  node "$test" || exit 1
done
```

| 范围 | 代表脚本与观察内容 |
| --- | --- |
| 来源/认证 | `validate-source-form`、`validate-source-profiles`、`validate-services`、`validate-jellyfin-auth`：实际配置模型、分派、协议与旧结果隔离 |
| 播放/接播 | `validate-playback-business`、`validate-playback-queue`、`validate-auto-next`：状态、seek、分集归属、EOF、失败恢复与退出代际 |
| 图片/材质/动效 | `validate-image-cache`、`validate-library-backdrop`、`validate-screen-ratio`：可见性、预算、取色/回调、比例与原生弹层接入 |
| AI | `validate-ai-client`、`validate-ai-session`、`validate-ai-subtitles`：真实请求结构、忠实翻译约束、cue/时轴、队列、取消与字幕解析 |
| 文件/原生桥 | `validate-smb-direct`、`validate-ai-source-bridge`：有界读取、Range、授权与原生/socket mock 生命周期 |
| 观看/存储 | Vision、服务器 Store、收藏相关脚本：账号隔离、错误保留、秘密引用和迟到回调 |

各脚本能输出更细的组名。部分脚本需要真实 MPV 类型，可用 `MPV_LIB_TYPES` 指向 `MpvLib.d.ets`；特殊工作目录可通过 `NAS_PLAYER_ROOT` 指向工程根。不要将个人路径写进测试源码。

## 主机 C helper

`native/validate_native_helpers.py` 直接包含产品的 `subtitle_text.h`、`http_range.h` 和 `local_source.h`，通过临时共享库运行边界 fixture。需要 Python 3 和主机 Clang/GCC：

```sh
python3 tests/native/validate_native_helpers.py
```

可设置 `CC` 或使用 `--cc` 指定编译器。Windows 的独立 Clang DLL 路径需要 `lld-link`，可用 `LD` 或 `--ld` 指定；使用 64 位 Python。生成物位于系统临时目录，不提交到仓库。

这些用例覆盖 Range、EOF、整数边界、字幕文本与时间单位以及 fd URI；它们没有执行设备侧 FFmpeg 解码、真实 socket 或授权文件读取。

## 原生包装层

```sh
node tests/native/validate-native-wrapper.cjs
```

该检查对实际包装层与原生声明做严格类型检查，并用受控 NAPI Promise 检查任务串行、取消、恢复、代际和相位计数。它不会加载设备 `.so`。

## 记录结果

本次开源快照执行结果见 [VALIDATION](../docs/VALIDATION.md)。新增检查请使用虚构凭据、`example.test` 地址、原创短片与脱敏最小样本。不要把真实日志、抓包、用户媒体或设备备份放到 `tests` 下。原生/页面改动仍需实际 ArkTS、CMake 和 HAP 构建；真实媒体能力另由设备实测证明。
