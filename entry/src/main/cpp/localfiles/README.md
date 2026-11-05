# 已授权本地 fd 访问

`LocalAccess.select(context,folder)`只保存系统Picker原样返回的单个URI，取消返回空串。它尝试持久化只读权限；若只能临时读取，浏览页明确提示重启可能须重新选择。`ensureRead(uri)`在每次使用前检查/激活真正持久权限，或确认本进程实际Picker授权；只把URI写进偏好不算持久授权。需要`ohos.permission.FILE_ACCESS_PERSIST`和设备系统能力，失败/不支持/撤销权限须重新选择。参见官方 [持久授权指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/file-management/file-persistPermission.md) 和 [Picker接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-core-file-kit/js-apis-file-picker.md)。目录授权与重启恢复需要在目标设备验证，不能把SDK声明当成设备支持证明。

本模块不去掉`file://docs`前缀、不拼`/storage`绝对路径。应用先`fileIo.open(原样URI,READ_ONLY)`，再把获得的根fd交给NAPI：

- `list/stat`只接受根内相对路径；逐级`openat`，拒绝空路径段、`.`、`..`、反斜杠和超32层，使用`O_NOFOLLOW`不跟符号链接。
- `list`通过目录fd的`fdopendir/readdir/fstatat`获取真实信息，不读取影片内容；超过10000条明确失败。
- `openChild`返回本次独立只读fd和真实文件信息；不读整片、不缓存整片。根File对象可独立关闭，播放fd仍由本次lease保留。
- `readSmall`仅供小型JSON文档，最多2MiB；先检查fstat并有界pread，多1字节检测文件变化/超限，拒绝目录。
- `closeFile`只释放本模块实际创建的fd；ArkTS release回调另有一次性守卫。

播放器使用 **`fd://N`**。官方 [mpv手册](https://mpv.io/manual/master/)区分借用的fd协议和会关闭fd的`fdclose://`；本项目固定原生fork [6edeee00a / stream_file.c](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/stream/stream_file.c#L298)也仅在fdclose分支设置close标志。应用因此在停止/释放原生播放器后调用自己的release，禁止再改成fdclose以免重复关闭或误关重用的fd。该语义已按官方/固定源码核对，实际设备fd播放、seek和生命周期需要单独验收。

`SourceBrowser`由父页面提供`server`、`active`、`onPlay(item,siblings)`及可选`onManage`。文件夹进入真实目录，视频回调播放，非视频文件解释不可播放；IPTV通过真实分组和getEpg展示当前/下一节目，不编造EPG。状态只经controller的16ms合并发布；隐藏、卸载、换账号失效旧代际。名称/文件时间排序明确作用于已加载条目；时间缺失不以名称冒充日期，收藏成功后才提交图标。

验证：Local/Custom/controller等实际ArkTS方法由受控平台、Native IO和HTTP mock检查。源方法通过不等于目标设备上的授权、openat读取、fd视频或视觉体验通过。原生模块需经过实际Harmony SDK的CMake与HAP构建，目录权限撤销、临时授权恢复、seek和退出释放需要在设备验证。运行方式见[测试说明](../../../../../tests/README.md)，本次公开快照的执行结果见[VALIDATION](../../../../../docs/VALIDATION.md)。
