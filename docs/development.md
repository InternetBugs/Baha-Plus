# 开发与构建

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

## iOS 与发布

Android 日常开发、打包、模拟器验证均在本地完成。当前不自动运行任何 GitHub Actions。功能验收完成后再配置并执行正式发布流程，调试包不代表正式签名版本。

iOS 共用同一 Flutter 前端和玻璃组件。构建 iOS 仍需 macOS、Xcode 和签名环境；Windows 可以维护工程和运行 Dart 测试，不能在本机生成可安装的 iPhone 包。在 Mac 上：

```sh
cd app
flutter pub get
flutter build ios --no-codesign
```

页面与控件一致性由共用 Dart 实现保证，系统键盘、WebView、媒体解码和系统权限界面仍需在目标设备上验收。

已完成的本地检查及待验收项见 [本地验收记录](verification.md)。已在安卓模拟器验证真实正片、主要播放操作与账号资料读取；账号云端写回及 iOS 设备的完整验收尚未完成。片库当前浏览已读取的首页目录，完整历史片库可通过官方接口搜索，全量目录分页仍待接入。

## 设计与字体

玻璃用于导航与操作层，内容卡片保留清晰、不透明的图像和文字。设计依据见 [设计说明](liquid-glass.md)。

应用内附 Noto Sans TC 与 Noto Sans SC 字体，使两端中文排版共用相同字体并覆盖简繁字形；许可证位于 `app/assets/fonts/OFL.txt` 与 `OFL-SC.txt`。第三方客户端与巴哈姆特官方没有从属关系。
