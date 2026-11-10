# iOS 原生播放迁移

本迁移在 `codex/ios-native-player` 分支进行，基于 Android 原生播放分支的 `42531bb`。本轮先完成代码迁移和 Windows 离线验证，iPhone 实播由维护者后续验收。

2026-11-09 的 Profile 包自由观看反馈、采样范围和待处理项见[实机问题记录](ios-native-player-device-test-2026-11-09.md)。该记录保留了未验证的候选原因，不能视为完整验收通过。

## 播放路径

iOS 默认启用原生正片播放。官方 WKWebView 先完成年龄确认、广告、账号、会员、地区和设备校验；当前剧集进入正片并具有有效时间线后，才准备 Flutter 官方 `video_player` 的 AVFoundation 后端，由 AVPlayer 解码并将视频纹理交给 Flutter。广告和官方确认界面仍显示在原 WebView。

Android 和 iOS 共用 `native-playback.js`、`NativePlayback` 和 `NativeVideoSurface`。宿主明确注入 `android-exoplayer` 或 `ios-avplayer`；不支持的平台不启用接管。媒体源只接受本次官方会话提供的 `bahamut.akamaized.net` HTTPS HLS，原生请求携带官方来源、引用页和设备 WebView 的 User-Agent，不导出 Cookie、CSRF 或账号令牌。

保存的画质用于第一个原生媒体源。手动切换只使用当前清单实际提供且无需独立外置音轨的档位；自动模式继续使用原主清单。切换保留进度、倍速、静音和暂停意图。网页画质切换尚未完成时延后原生接管，避免继承中间状态。

官网进入正片后先暂停 HTML 视频，并保存接管前的播放意图。原生初始化成功后，再从网页读取一次最新时间线并卸载 HTML 视频源、VHS、网页弹幕动画和 Media Session，随后启动原生播放。启用原生后端时，初始化或接管失败提供“重试”，不会静默回退为网页正片；准备期间的网页播放、定位及画质命令同样被拒绝。切集、刷新和退出释放旧原生播放器；退出时等待活动原生控制器释放，再停用 iOS 音频会话。

原生接管后，精简 WKWebView 保持挂载并退出画面合成。账号、剧集标记、官方错误容器及官方回调保留；正片解码、时间线及控制命令由原生播放器处理，官方观看进度和设备策略回调通过独立定时任务接收原生时间线，不再随每次原生状态变化同步。网页播放器的轮询停止，播放健康诊断直接读取原生状态。

明确的官方拒绝会停止原生播放并保留重试入口。网页暂时不可用时暂停并保留同一个原生播放器及其缓冲；校验恢复后恢复控制，继续保持暂停。跨后台往返的迟到校验结果被丢弃。网页进程退出、可恢复的媒体错误或正片时钟持续 30 秒没有推进时，前台原本正在播放的会话可自动重新经过官方流程，恢复剧集、进度、倍速、静音及已保存画质；30 分钟内最多自动恢复两次。暂停、后台、广告和明确的官方拒绝不自动恢复；恢复加载逾时后显示手动重试，后续原生接管成功会清除恢复期限。原生接管后的网页命令、画质恢复和缓存切源不能重新启动 HTML 视频。这仍保留官网授权、进度回写和弹幕数据的会话通道，不表示移除了这些官方流程。

## 缓存与生命周期

原生模式直接使用授权的 HTTPS HLS，不同时启用旧的 WKWebView `PlaybackCache` 回环切源和后台预取，以免两条路径抢占媒体源。旧缓存实现保留在 WebView 回退模式中。本迁移没有为 AVPlayer 接入后台预取或离线播放。

应用统一管理播放生命周期：进入 hidden／paused 时暂停，返回前台仍暂停；临时 inactive（例如拉下控制中心）不单独暂停。接管或画质切换期间经过后台往返，会锁定暂停意图，异步完成不能自动播放。`video_player` 的自动前台恢复关闭，屏幕常亮只由 `PlaybackEnvironment` 根据实际播放状态管理。

iOS Now Playing 使用原生时间线，系统播放、暂停、切换和进度定位绑定当前文档；过期文档和真正后台的控制请求被拒绝。来电／Siri 音频中断开始、旧音频设备断开时向当前原生播放器发送暂停；中断结束不主动恢复。未增加 `UIBackgroundModes`，不启用后台音频或小窗。

弹幕沿用 Flutter 绘制层，保留透明度、字号、滚动／顶部／底部设置、64 个活动文字对象及 16 MiB 图像缓存上限。滚动弹幕最多约 60 次每秒请求绘制；没有可见弹幕时停止动画，固定弹幕只在显示边界刷新。普通暂停冻结呈现位置和轨道，显式定位通过独立修订号重建。数据仍来自当前官方会话，发送仍走官网账号与 CSRF 校验，时间取实际原生进度。本轮没有实际发布留言或弹幕。

## 编译与对照

在 macOS／Xcode 环境构建启用诊断的测试包：

```sh
cd app
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --dart-define=BAHA_DIAGNOSTICS=true
```

默认启用 iOS 原生正片。回到原有 WKWebView 播放及可用的旧缓存流程：

```sh
flutter build ios --release --no-codesign \
  --dart-define=BAHA_DIAGNOSTICS=true \
  --dart-define=BAHA_IOS_NATIVE=false
```

Android 的 `BAHA_ANDROID_NATIVE` 独立保留。两端开关互不影响。测试 IPA 仍需签名后才能安装。**Manual test build** 选择本分支和 `ios`，并通过 `ios_build_mode` 选择 `release`（默认）、`profile` 或 `debug`；三种模式均启用诊断。IPA 文件名和 `build-info.json` 记录实际构建模式，Profile 和 Debug 附件名称分别另带 `ios-profile`、`ios-debug`。测试构建不创建版本标签或正式发布。

Windows 配合 Feather 签名安装并做真机性能测试时，可选择 Profile 包；其 Dart 代码使用 AOT 编译，签名安装后可从桌面启动，保留本项目诊断和性能分析能力。对应的 macOS 构建命令为：

```sh
flutter build ios --profile --no-codesign --dart-define=BAHA_DIAGNOSTICS=true
```

需要真正的 Debug 包时，本地命令改用 `flutter build ios --debug --no-codesign --dart-define=BAHA_DIAGNOSTICS=true`。iOS Debug 包需要调试器启动及签名的 `get-task-allow` 权限；仅开启系统开发者模式不能补齐签名权限。Profile 与 Release 不提供 Debug 的热重载。

接管成功日志为 `[BAHA_NATIVE] ios-avplayer handoff complete`；诊断包的 `[BAHA_HEALTH]` 应出现 `backend: "ios-avplayer"`，原生前的网页 HLS 后端可能显示 `native-hls`，两者含义不同。日志不应包含签名媒体 URL、Cookie 或账号令牌。

## iPhone 验收

使用开启诊断的 Profile 或 Release 包，对照以下操作：

1. 正常完成官网年龄确认和广告，确认原生正片有画面和声音、弹幕跟随进度；广告和确认界面不提前被原生层遮住。
2. 暂停、继续、拖动、快进／后退、倍速、静音，切换官方实际提供的画质和自动模式；全屏及留言／简介二级页面往返保持同一播放会话。
3. 切后台和锁屏后暂停，返回前台保持暂停；切画质过程中也做同样往返。拉下控制中心后测试播放／暂停／进度定位。
4. 测试来电／Siri 和耳机断开后的暂停，确认中断结束不自动播放。
5. 连续观看至少一集，关注黑屏、声音与进度不一致、弹幕、内存增长和观看记录写回；另测切集、刷新、网络中断、退出后立即重开和媒体卡片清理。
6. 需要定位差异时，用 `BAHA_IOS_NATIVE=false` 构建回退包做同设备、同剧集、同画质对照。

现有真实网络集成测试已支持 iOS 后端识别，可在有 Flutter／Xcode 的设备环境中执行：

```sh
flutter test integration_test/native_player_smoke_test.dart \
  -d <iPhone设备ID> --no-uninstall --dart-define=BAHA_DIAGNOSTICS=true
```

该集成测试会点击真实官方年龄“同意”按钮并连续播放十分钟，只在操作者明确同意该操作时运行。保留 `--no-uninstall`，避免清理现有账号与偏好。控制中心、来电、耳机断开及真实锁屏应另外用普通主入口包测试。

Windows 离线验证不能替代 iOS 编译、AVPlayer 实际解码、控制中心／耳机事件、真机性能及官方进度写回验收。既有 Android 实播和较早的 iOS WebView 构建结果不作为本迁移的 iPhone 验收证据。
