# Baha Plus

面向 Android 和 iOS 的巴哈姆特动画疯第三方客户端，使用 **Flutter / Dart**。两端共用页面、中文字体和 [`liquid_glass_widgets`](https://pub.dev/packages/liquid_glass_widgets) 玻璃控件。

## 功能

- 探索、每周时间表、片库、观看记录、搜索、作品详情与选集。
- 简体中文、繁体中文；浅色、深色、跟随系统。
- App Store 风格的大标题、封面卡片、悬浮玻璃标签栏、玻璃操作按钮。
- 首页人气片单采用竖向瀑布流，随页面连续滚动；目录缓存状态不占用页面。
- 片库共用封面瀑布流，优先展示番剧主视图；首页本季注目采用可左右滑动的主视图轮播，合并原先单独的推荐卡片。
- 首页「本季新番」打开按更新日期分组的横屏剧集时间线；片库「本季」保留竖版番剧封面。
- 搜索框自动调用动画疯搜索接口，支持简繁关键词转换和结果去重，在应用内直接展示结果。
- 完整 Flutter 播放页面：视频区域、进度与玻璃控制、选集、简介和作品资料；支持横屏、十秒快进/后退、静音与倍速。
- 无目录缓存时首页留白，有缓存时立即显示并后台刷新；失败保留已有缓存。
- 收藏、观看记录和播放进度来自官方账号，应用不另建本地收藏或本地历史。
- 账号卡片显示官方昵称、账号 ID 与头像，首页账号入口同步显示头像。
- 账号资料自动更新；观看记录直接读取官网的分页接口，支持继续播放对应集数。账号面板保留一处追番入口，移除重复快捷区与手动同步按钮。
- 底栏选中项使用玻璃弹簧滑动，页面按切换方向轻移渐入，并遵循系统减少动画设置。
- 再次点击当前底栏标签会平滑返回该页顶部。继续观看使用圆角高光进度轨道与圆形玻璃播放按钮。
- 官方持久 WebView 会话负责登录、会员、广告、视频解码、年龄验证与地区限制。播放页面的导航、布局和交互由 Flutter 绘制，视频区域保留官方引擎及其必要确认界面。
- 详情仅读取静态 HTML，不为了获取选集在后台运行播放器。官方播放页使用桌面展示模式。
- 官方验证需要用户在完整可见的官方页面手动完成。

视频内使用一套自定义玻璃控制条，支持自动隐藏。广告阶段显示实际广告进度并提供播放、暂停与静音；拖动、快进、画质及倍速仅在官方核心明确报告正片状态后启用。广告提示、合法跳过按钮和年龄确认保留在视频内。应用不导出流地址、密码或 Cookie，也不另建播放进度数据库。

源码只保留 Flutter 工程。Android 平台壳使用 Kotlin，iOS 平台壳使用 Objective-C，业务界面均为 Dart。旧实现可以从 Git 历史查看。

## 目录

```text
app/lib/core/         数据模型、官网 URL 与桥接校验、简繁搜索
app/lib/data/         状态、公开目录缓存、官方会话适配
app/lib/ui/           共用 Flutter 页面和 Liquid Glass 控件
app/assets/           双语、官网 DOM 适配器、中文字体
app/android/          Android 平台工程
app/ios/              iOS 平台工程
app/test/             Dart 核心与界面测试
tests/                官网 JavaScript 适配器离线测试
tools/android-local.ps1
```

## 本地开发

要求 Flutter **3.47.9**、Java 21、Android SDK 和模拟器。玻璃组件锁定 **1.16.1**，要求 Flutter 3.41 以上。工具链、缓存、构建产物与账号会话不提交到仓库。

```powershell
$env:FLUTTER_ROOT = 'D:\BahaPlusTools\flutter'
.\tools\android-local.ps1 -Action Check
.\tools\android-local.ps1 -Action Build
.\tools\android-local.ps1 -Action Run -Device emulator-5554
```

本地脚本会优先读取 `FLUTTER_ROOT`、`ANDROID_HOME`，当前开发机也可以使用项目内的 `.tools/android-sdk`。只有这台电脑的网络需要代理时，才传入 `-ProxyUrl http://127.0.0.1:7890`。该选项不修改系统代理。

默认构建用于当前 x86_64 模拟器的 debug APK，输出到 `artifacts/flutter-local/BahaPlus-debug.apk`。连接 Android 真机时可用：

```powershell
.\tools\android-local.ps1 -Action Build -TargetPlatform android-arm64
```

手机体验使用 release 模式；也可同时包含 ARM64 手机与 x86_64 模拟器架构：

```powershell
.\tools\android-local.ps1 -Action Build -Mode release -TargetPlatform 'android-arm64,android-x64'
```

输出为 `artifacts/flutter-local/BahaPlus-release.apk`，附带 SHA-256 构建记录。当前体验包使用开发签名。

也可以直接使用 Flutter：

```sh
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter run -d emulator-5554
```

双语资源、官网适配器另外检查：

```sh
npm ci
npm run resources:check
npm test
npm run typecheck
```

连接 Android 模拟器后，可单独运行真实网络集成测试：

```sh
cd app
flutter test integration_test/catalog_smoke_test.dart -d emulator-5554 --no-uninstall
```

该测试使用真实搜索接口及公开番剧资料，并等待主视图与剧集缩略图实际解码，不会主动播放影片或修改追番。保留 `--no-uninstall`，避免 Flutter 测试工具默认卸载应用并清理设备数据；也可使用本地脚本的 `-Action Integration`。测试包使用测试入口，日常体验应重新构建并安装普通 `lib/main.dart` 入口的 APK。

## 账号与播放

右上角账号入口打开账号面板，已登录时显示官方昵称、账号 ID 与头像。点击账号卡片进入官方账号页面，用户自行登录并完成验证，账号资料随官方页面返回自动读取；关闭登录页面也会在后台重新检查官方会话。密码和 Cookie 留在平台 WebView，应用只接受官方主文档、当前请求标识匹配且内容通过校验的投影数据。

本机保存公开目录缓存、字体、图片缓存与语言/外观偏好；账号资料、收藏和观看历史是当前官方会话的内存投影。更换账号或检测到游客状态时清空旧投影，重新读取。冷启动、返回前台和进入观看记录时自动更新资料，重复请求在执行中合并。观看记录通过官网实际使用的账号接口读取，保留分页与云端断点，接口失败会报告错误。播放关闭时暂停媒体，再刷新云端记录。退到后台会暂停媒体，回到前台保持暂停，由用户继续播放。

玻璃效果根据绘制负载在标准与完整质量间调整，保留玻璃外观；图片按显示宽度与像素密度限制解码大小。语言和外观变化才重建应用主题，普通账号与目录状态变化由对应页面更新。

搜索与主视图元数据通过官网会话的网络通道直接请求官方 JSON 接口，页面仍由 Flutter 绘制。用户搜索使用当前账号上下文，后台补全公开海报使用匿名请求；只接收必要的番剧资料字段，搜索历史与收藏标记不会混入目录缓存。主视图和每集缩略图分开保存，后续刷新保留已取得的主视图。

封面与头像的 Dart 网络请求读取设备系统代理配置，未设置代理时直连；不内置开发机代理地址，保留正常 TLS 证书校验。该行为与构建脚本的 `-ProxyUrl` 选项分别作用于应用运行和本地编译。

## iOS 与发布

Android 日常开发、打包、模拟器验证均在本地完成。当前不自动运行任何 GitHub Actions。功能验收完成后再配置并执行正式发布流程，调试包不代表正式签名版本。

iOS 共用同一 Flutter 前端和玻璃组件。构建 iOS 仍需 macOS、Xcode 和签名环境；Windows 可以维护工程和运行 Dart 测试，不能在本机生成可安装的 iPhone 包。在 Mac 上：

```sh
cd app
flutter pub get
flutter build ios --no-codesign
```

页面与控件一致性由共用 Dart 实现保证，系统键盘、WebView、媒体解码和系统权限界面仍需在目标设备上验收。

已完成的本地检查及待验收项见 [本地验收记录](docs/verification.md)。已在安卓模拟器验证真实正片、主要播放操作与账号资料读取；账号云端写回及 iOS 设备的完整验收尚未完成。片库当前浏览已读取的首页目录，完整历史片库可通过官方接口搜索，全量目录分页仍待接入。

## 设计与字体

玻璃用于导航与操作层，内容卡片保留清晰、不透明的图像和文字。设计依据见 [设计说明](docs/liquid-glass.md)。

应用内附 Noto Sans TC 与 Noto Sans SC 字体，使两端中文排版共用相同字体并覆盖简繁字形；许可证位于 `app/assets/fonts/OFL.txt` 与 `OFL-SC.txt`。第三方客户端与巴哈姆特官方没有从属关系。
