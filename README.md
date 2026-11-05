# Baha Plus

面向 Android 和 iOS 的巴哈姆特动画疯第三方客户端。**当前产品前端使用 SwiftUI**，通过 Skip Lite 把共享界面转换为 Android 原生 Kotlin / Jetpack Compose。

## 当前实现

- 探索、本季新番、每周时间表、片库、搜索、作品详情与选集。
- 简体中文、繁体中文；按系统语言初始化，可在右上角账户面板切换。
- 参考 App Store 的大标题、封面主卡、胶囊操作与分组账户 Sheet；搜索有独立入口。
- 浅色、深色、跟随系统。
- iOS 26 使用 Apple 原生 Liquid Glass：系统标签栏、工具栏、Sheet，以及封面上的 clear glass 控件。
- Android 使用带背景模糊、边缘高光和明暗适配的悬浮胶囊导航，页面与 iOS 共用 SwiftUI。
- 官方 WebView 会话用于登录、收藏、观看记录、会员管理和播放；App 不读取密码。
- 收藏和观看记录从官方账号读取，播放进度由官方播放器回写。App 不另建本地收藏或本地观看记录。
- 本机保存语言、外观偏好和上次成功加载的公开目录。首页没有缓存时留白，有缓存时立即显示并在后台刷新；刷新失败保留缓存。内置快照仅用于开发预览，不作为正式页面的兜底数据。

## 工程入口

```text
Project.xcworkspace            Xcode 入口
Package.swift                 Swift Package / Skip 模块
Darwin/                       iOS App 壳、图标和签名配置
Android/                      Android 原生入口与 Gradle 配置
Sources/BahaPlus/              SwiftUI 页面、状态与官方会话适配
Sources/BahaCore/              数据模型、目录缓存、简繁搜索、双语与预览资源
tests/BahaCoreTests/           Swift 核心测试
tests/native-adapters.test.ts  官方 DOM 适配器的离线测试
```

公开仓库仅包含 SwiftUI 主工程及必要的资源、构建与验证工具。早期 Expo 预览、本机开发缓存和工具链不包含在仓库中。

## 日常本地检查

日常修改先在本机运行轻量检查，Windows 也可以执行：

```sh
npm ci
npm run resources:check
npm test
npm run typecheck
```

原生编译与安装包使用下方的手动 Actions。Windows/WSL 也可以运行纯 Swift 核心测试，不能运行 Xcode。

## GitHub Actions（按需构建）

提交代码、推送到 `main`、创建 Pull Request 都不会自动运行云端构建。日常修改先在本机完成资源、适配器和纯 Swift 核心检查，一批修改完成后再按需手动运行 **Native build**。

工作流不设置固定的每日次数或冷却时间。两个工作流共用一个并发组，一次运行一轮云端验证，保留正在进行的构建。需要新安装包时正常构建，验证已有 APK 时直接指定已有的构建编号，不重新编译。

构建步骤：

1. 在 Linux runner 检查双语资源、官方页面适配器和 TypeScript。
2. 在 macOS 26 runner 安装 Skip / Gradle，运行 Swift XCTest，构建 iOS 和 Android。
3. 使用 iPhoneOS SDK 另外构建 arm64 真机应用，并打包未签名的 IPA。
4. 成功后从 `BahaPlus-native` 下载 Android debug APK、iOS 模拟器 App 压缩包和 `BahaPlus-unsigned.ipa`。

iOS 原生预览仅在手动勾选 `include_previews` 时生成，完成打包后串行运行，在 iOS 26 模拟器上导出首页、搜索、账户面板和繁体深色模式截图，可从 `ios-ui-previews` 下载。预览使用公开目录和占位账号，不代表真实账号登录或播放验收。安装包和截图保留 7 天，构建日志保留 3 天。

**Android runtime smoke** 也仅手动运行。指定已有的成功构建编号 `build_run_id` 后，它会下载实际 APK，在 Android 模拟器中安装并检查启动、搜索输入与清空、账户面板和简繁切换。截图、界面树和运行日志保存在 `android-runtime-evidence`，这项检查使用访客界面。

iOS 模拟器产物用于模拟器验收，不能直接安装到 iPhone。`BahaPlus-unsigned.ipa` 使用真机 SDK 与 arm64 架构，安装前仍需使用自己的 Apple 账号完成签名；它不是已经签名、可直接安装的 iPhone 应用。CI 不需要保存 Apple 账号凭据，工作流不自动发布 Release 或上传应用商店。

## 在 Mac 上运行

需要 Xcode 26 或更新版本，以编译 Liquid Glass API；iOS 最低部署版本为 17。

1. 按 [Skip 官方入门文档](https://skip.dev/docs/gettingstarted/)安装 Skip、Android Studio 和 Android SDK。
2. 在项目目录执行 `skip checkup` 检查工具链。
3. 打开 `Project.xcworkspace`。
4. 选择 **BahaPlus App** Scheme 和 iPhone 模拟器，运行。

如果以后需要 Mac 本机构建，准备 Node.js 24+、Java 21、Skip、Android SDK 后可执行 `bash tools/build-local-macos.sh`。它会检查资源并生成与云端相同类别的三个原生产物，输出到 `artifacts/native-macos`。本地 iOS 截图可单独运行 `bash tools/build-ios-previews.sh`，Android 安装检查则在模拟器启动后运行 `python3 tools/android-smoke.py --apk artifacts/native-macos/BahaPlus-debug.apk --output artifacts/android-smoke`。

`Darwin/BahaPlus.xcconfig` 默认设置 `SKIP_ACTION = none`，先让 iOS 独立运行。要同时构建、启动 Android，在 Android Studio 启动模拟器后，把它改为 `launch`。也可打开 `Android` 项目进行构建。

在 iPhone 真机上运行时，需要在 Xcode 中设置自己的开发团队和签名。这里没有配置开发者账号，也没有上传或发布应用。

## 账号流程

在右上角账户面板进入巴哈姆特官方登录页，完成登录后点工具栏的同步按钮。账号收藏、观看至哪一集、播放进度和官方进度文字会显示到 SwiftUI 页面。启动时会复用应用内的官方持久会话，尝试自动同步；播放结束返回时会暂停媒体，并重新读取云端记录。

追番按钮使用官方搜索卡片自己的订阅控件，复用其登录检查、CSRF 和成功响应。查看详情只读取并解析 HTML，不把详情页的视频播放器加载到后台；收藏操作也不需要打开视频页。不会仅凭本地点击把 UI 标为收藏成功。接口或 DOM 变化、登录失效、网络失败会保留错误提示，不制造本地记录。

公开目录与详情也从官方页面的 DOM 提取为数据；实际列表与卡片由 SwiftUI 绘制。详情读取重定向后的静态 HTML，并按最终页面地址解析选集。官方播放页使用桌面版展示，账号与登录页面保留移动版；播放器、广告、年龄验证、地区限制和会员权限继续使用官方服务。

## 验证

在具有 Swift 工具链的电脑上运行核心测试：

```sh
BAHA_CORE_ONLY=1 swift test
```

在 Mac 上验证两端：

```sh
skip checkup
swift test
skip test
```

完整构建可使用：

```sh
bash tools/verify-native-macos.sh
```

它会检查工具链与工程布局、运行 Swift 核心测试，并使用 Xcode 的 Android 构建阶段同时构建 iOS 模拟器 App 和 Android debug APK。只有两个实际产物都存在且 APK 包含 Manifest 与 DEX 文件时才报告构建成功。日志和产物放在 `artifacts/native-macos`。这仍不替代真机上的登录、播放、云端同步、简繁切换和玻璃视觉验收。

JavaScript 只用于官方页面的数据适配，不承担 App 前端：

```sh
npm install
npm run resources:check
npm test
npm run typecheck
```

原生资源直接维护在 `Sources/BahaCore/Resources` 和 `Sources/BahaPlus/Resources`。需要重建简繁搜索字典时运行 `npm run resources:search`，重建图标时运行 `npm run icons`。

Windows 上可以检查适配器和资源，并使用 `tools/check-swift-syntax.py` 检查 Swift 语法。在 WSL 中也可以使用官方 Swift Linux 工具链，真实编译并运行 `BAHA_CORE_ONLY=1 swift test`。这些检查**不等于** SwiftUI 类型检查、Xcode 编译、Skip 转译或真机验收。

本机检查结果：官方 Swift 6.2.4 编译并运行的 21 项 XCTest 通过，覆盖目录缓存、双语资源、Unicode 搜索、官方 URL、播放页展示策略、账号请求隔离和桥接消息校验。公开仓库保留的 10 项原生页面适配 / 详情 HTML 读取 / 资源测试通过。SwiftUI 和两端原生构建以 Actions 的实际结果为准，真实账号播放仍需目标设备验收。

项目提供 `tools/setup-swift-wsl.sh` 与 `tools/run-swift-wsl.sh` 供当前 Windows 开发环境复用临时 Swift 工具链；它们不会改系统 Swift 安装或 shell 配置。WSL 只能完成这里的纯 Swift 核心验证；完整 Skip App 的原生构建仍需要 [macOS 与 Xcode](https://skip.dev/docs/faq/#can-i-use-skip-on-windows-or-linux)。

## 实现依据

详见 [Liquid Glass 设计依据](docs/liquid-glass.md)。

双平台工程配置基于 [Skip 官方 HelloSkip 模板](https://github.com/skiptools/skipapp-hello)。WebView 锁定 [SkipWeb 官方修复提交 `4ae9b16`](https://github.com/skiptools/skip-web/commit/4ae9b16f5835d37ab63dc4cb4064df4fef3574a4)，修复 Android WebView 124 在导航时返回空请求头导致的启动崩溃；该补丁晚于 0.12.0 标签。SwiftUI 的 iOS 26 专有 API 用条件编译隔离。
