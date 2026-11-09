# Windows 桌面 Debug

Windows 调试入口复用 `app/lib`、资源和官方会话页面，显式启用 `windows-mpv` 原生视频后端及 `BAHA_DIAGNOSTICS`。桌面专用依赖放在生成工程中，移动端继续使用 `app/pubspec.yaml` 与现有锁文件。

## 工具与构建

需要 Flutter Windows 工具链、Visual Studio C++ Build Tools（MSVC、CMake、Windows SDK）和 WebView2 Runtime。WebView 插件还需要 NuGet CLI；脚本优先把 `artifacts/windows-debug/toolchain/` 加入本次进程的 PATH，也可使用 PATH 中已有的 `nuget.exe`。

在工作树根目录执行：

```powershell
.\tools\windows-debug.ps1 -Action Prepare
.\tools\windows-debug.ps1 -Action Build
.\tools\windows-debug.ps1 -Action Run
```

Flutter SDK 默认位于 `D:\BahaPlusTools\flutter`，可通过 `-FlutterSdk` 指定其他目录。脚本使用当前 `PUB_CACHE`，未指定时使用 Flutter SDK 同级的 `pub-cache`。

本机 Visual Studio Build Tools 安装在 `D:\vs-buildtools`，可供其他项目复用。2026-11-09 已使用微软官方安装器卸载旧目录实例，再按导出的 17 项组件重装；新实例完整、可运行，卸载和安装退出码均为 `0`，无需重启。迁移后 `flutter doctor -v` 确认 Windows 工具链使用该目录。组件、编译器、CMake 和 Windows SDK 的核验记录位于 `artifacts/windows-debug/toolchain/build-tools-verification.json`。

生成工程为 `artifacts/windows-debug/source/`。Build 操作成功后，普通软件入口的可执行文件为：

```text
artifacts/windows-debug/source/build/windows/x64/runner/Debug/baha_plus.exe
```

同目录的 DLL 和 `data/` 也是运行所需文件。`artifacts/windows-debug/build-info.json` 记录构建模式、后端、普通软件入口、来源分支与提交、工作区改动标记、可执行文件、Dart kernel 及 WebView 插件 DLL 的 SHA-256、桌面插件补丁和构建时间；只有可执行文件散列不足以区分普通入口与集成测试入口。

## 调试与验证

```powershell
.\tools\windows-debug.ps1 -Action Test
```

集成测试使用真实 Windows 插件，检查本机 HTTP HLS 的解码纹理、原生进度、暂停、定位、模拟 Flutter 生命周期通知后的暂停保持，以及当前 App 启动和五个标签。脚本在 `artifacts/windows-debug/fixtures/` 中准备 8 秒的原创测试画面；首次生成需要 PATH 中的 FFmpeg，视频为 256×144、10 FPS 的 H.264。测试服务器只监听本机回环地址，并在测试结束时关闭。

页面回归先等待真实 WebView 纹理创建完成，以及当前 App 界面的新栅格化回执；按原始帧时间过滤此前 HLS 的延迟回执。可见时使用正常平台帧，仅在隐藏状态补 warm-up frame，并覆盖有效的 `inactive → hidden → inactive → resumed` 模拟序列，核对各标签内容与过渡动画结束。卸载后确认 WebView 和纹理已从组件树移除，再两次等待真实原生释放，保留每次 10 秒的释放限制。迁移后的冷启动记录中，原生 WebView 与界面就绪等待约 35 秒；固定等待三秒不足以代表原生视图已创建。

测试完成后，应再次执行 `-Action Build`，恢复普通软件入口并更新构建记录；Flutter 集成测试会用测试入口覆盖相同输出目录中的可执行文件。模拟 Flutter 生命周期通知可以检查暂停意图及控制器保持，操作系统真实最小化和锁屏仍需另外检查。

普通软件入口的窗口退出回归为：

```powershell
.\tools\windows\desktop_exit_test.ps1
```

该回归先核对构建入口及散列，分别启动普通窗口和实际最小化的窗口，重复发送关闭请求，核对界面卸载、原生回执和进程退出码。它只操作本工作树生成的 Baha Plus 程序，不会接管已经运行的实例。结果与各次标准输出保留在 `artifacts/windows-debug/exit-test-results.json`、`exit-*.log`。

本机普通 Debug 入口首次绘制曾超过一分钟，退出脚本最多等待 120 秒让主窗口出现；这不是 Release 启动性能的测量结果。等待超时会保留原进程以便检查，不会自动重复启动。

Windows 的 `flutter_inappwebview_windows 0.6.0` 没有实现 `WebMessageListener` 工厂，因此桌面入口使用 WebView2 插件已有的 `callHandler` 消息通道。消息脚本仅暴露给官方 HTTPS 主框架，宿主再次检查原生 URL、参数数量和大小，共用的 nonce、消息类型及来源校验继续保留；iOS／Android 使用原有的原生监听器。

## 桌面关闭与原生资源

本次普通入口调试曾复现关闭窗口时进程以 `0xC0000005` 退出。Debug 原生调用栈落在 WebView 插件的 DLL 静态析构、`dcomp.dll` 与 `coremessaging.dll`；仅提前拆除 Flutter 界面不足以解决它。

主窗口现在先通过 `baha_plus/desktop_lifecycle` 请求 Dart 清理，重复关闭共用同一次请求。Dart 在总计 12 秒内卸载界面并等待原生回执，窗口保持存活直到成功；最小化时使用 warm-up frame 卸载界面，不依赖常规帧恢复。超时或错误保留窗口并允许重新请求，不把失败当作释放成功。

`prepare_webview.ps1` 将已锁定和核对散列的 `flutter_inappwebview_windows 0.6.0` 复制到派生工程，再应用桌面补丁。每个 WebView 的 texture、捕获 bridge 与 view 保留到实际纹理注销回执之后，在创建它们的 STA 线程释放；计入在途创建、迟到及重复回调，创建接口同步返回失败也会完成一次错误回执。管理器确认视图和纹理均已释放后，异步等待 `ShutdownQueueAsync` 的完成及 `GetResults`，最后释放队列和 WinRT 资源。移动端依赖和共享 pub 缓存不应用这些补丁。此流程覆盖当前 App 使用的 inline WebView；新增独立 browser／headless 创建路径时需另行审查其创建保护。

独立原生回归 **34 项通过**，覆盖释放顺序、线程、重复回调、同步失败、队列异常与幂等行为。`native-shutdown-tests.log` 中的 HRESULT 是主动注入的失败用例。最终派生源码输入与输出散列包含在构建记录的插件补丁字段中。

Debug runner 同时保留最多 32 帧的原生异常栈日志，只解析本地符号、模块和偏移；`Build` 将 WebView 插件 PDB 放到程序旁供本地解析。Release 不链接这项 DbgHelp 诊断。它不记录局部变量、媒体 URL 或内存转储。

## 生成可运行调试包

普通入口 Build 和窗口退出回归通过后执行：

```powershell
.\tools\windows\package_debug.ps1
```

输出为 `artifacts/windows-debug/BahaPlus-windows-debug.zip`，校验值为同目录 `SHA256SUMS.txt`。解压到同一目录后运行 `baha_plus.exe`，保留配套 DLL、符号文件及 `data/`。脚本按 CMake 安装清单与显式程序／符号文件清单打包，附上构建与退出验证记录；运行时生成的 WebView2 个人资料目录不会进入调试包。压缩完成后逐项回读 ZIP 并核对 SHA-256。

## 播放与验证边界

2026-11-09 最终工作树验证结果：

- Flutter 全量 **224/224**，开启诊断的原生播放／媒体控制／接管专项 **57/57**，静态分析无问题。
- JavaScript **119/119**、Python **12/12**、TypeScript 类型检查及 **205 条**双语资源检查通过。
- Windows 真实视频／页面集成 **2/2**，最终退出回归 **2/2**，原生资源释放专项 **34 项**通过，派生 Dart 工程分析无问题。
- 普通软件入口已实际显示官方首页和片库，打开番剧详情并返回片库，实际最小化／恢复保留页面。最终关闭测试均确认实际 WebView 已释放，最小化场景记录 `lifecycle=hidden framesEnabled=false`，两次进程退出码均为 `0`。

本机使用 Flutter 3.47.9／Dart 3.13.7、Visual Studio Build Tools 2022 17.14.44、MSVC 14.44.35207 和 Windows SDK 10.0.26100.0。构建中的上游 CMake CMP0175 提示没有阻止构建；未为本次任务升级移动端依赖。测试后已重建普通入口，未把集成测试入口当作软件交付。

工具链迁移后已重新通过桌面集成 **2/2**，再于 2026-11-09 23:10（Asia/Taipei）完成普通入口构建；新 CMake 缓存确认使用 `D:/vs-buildtools`。23:12 与 23:13 完成普通／实际最小化退出，两次均确认界面卸载、原生回执及 WebView 释放，进程退出码为 `0`。随后重新生成包含 57 个文件的 Debug ZIP，逐项回读校验；该包及构建／退出记录已同步到主工作区的 `artifacts/windows-debug/`。其最终散列以同目录的 `SHA256SUMS.txt` 为准。此前移动端、JavaScript 和原生释放专项结果沿用对应源码的已完成验证，没有把它们计作迁移后重新执行的测试。

原生正片初始化或接管失败时，软件应显示显式重试；重试按钮须可点击，正片控制不能转回 HTML 播放。成功接管后，网页媒体源、媒体控制回调与播放器轮询被释放。官方广告、年龄确认、账号校验、观看进度回写及弹幕数据仍使用官方 WebView 会话。

Windows 调试可以验证共用页面、桥接路由及桌面原生视频插件。iPhone 的 AVPlayer 解码、AirPods 入耳事件、真实锁屏恢复和温控表现仍需在修复后的 iPhone 包上单独复验。原始设备证据及后续修复状态见 [2026-11-09 设备记录](ios-native-player-device-test-2026-11-09.md)。
