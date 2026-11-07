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

Android 日常开发、打包、模拟器验证均在本地完成。GitHub Actions 的 **Manual release** 只支持手动触发：推送代码、创建标签或 Release 均不会启动构建或发版。不要触发该工作流，直到维护者明确决定发布。

### 首次配置 Android 签名

正式 APK 使用专用签名密钥。安全保存 keystore 和密码；以后的版本必须使用相同密钥，用户才能直接更新已安装的正式版本。现有本地体验包使用开发签名，与正式签名不同，通常需要卸载后才能安装正式包，卸载可能清除本地应用数据。

1. 使用 Java 的 `keytool` 创建 Android 上传密钥（或使用已有的正式签名密钥），妥善备份 keystore。
2. 将 keystore 文件编码为单行 Base64。例如在 PowerShell 中运行：

   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\安全位置\baha-plus-release.jks')) | Set-Clipboard
   ```

3. 在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中添加以下 repository secrets：

   | Secret | 内容 |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | keystore 文件的 Base64 内容 |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
   | `ANDROID_KEY_ALIAS` | 签名密钥别名 |
   | `ANDROID_KEY_PASSWORD` | 签名密钥密码 |

不要把 keystore、密码或 Base64 内容提交到仓库。发布工作流缺少任何一项时会失败，不会退回使用开发签名。

### 手动发布

1. 确认计划发布的代码已经合并到 `main`。
2. 在 GitHub **Actions → Manual release → Run workflow** 选择 `main`，点击运行。无需填写版本号或修改项目文件。操作者需有运行工作流和发布 Release 的仓库权限。
3. 工作流以 `app/pubspec.yaml` 的版本作为起点，并根据已有的 `v主版本.次版本.修订号` 标签自动选择下一个版本（例如从 `v0.3.0` 到 `v0.3.1`）。它在构建前为所选提交创建标签，以避免构建期间工作流变更导致 GitHub 拒绝创建标签。APK 和 IPA 使用相同版本，Android 构建号随版本递增；不会修改仓库文件。
4. 工作流分别在 Linux 和 macOS 构建 Android APK 与 iOS IPA；两端都成功后，核对标签是否仍指向所构建的提交，再创建 Release 草稿并上传附件，完成后发布。Release 包含 Android 签名 APK、**未签名**的 iOS IPA 和 SHA-256 校验文件。

发布说明会自动列出自上一个正式 Release 以来的提交，并附上 GitHub 自动生成的合并请求说明。首次发布会列出截至该版本的全部非合并提交；这些内容基于提交标题和合并请求，并非 AI 生成的文字摘要。

iOS IPA 需要使用合适的 Apple 证书和描述文件另行签名后才能安装；它不是可直接安装的已签名包，也不代表已完成 iPhone 真机验收。工作流不会上传 App Store 或 TestFlight。

如果构建或发布失败，可能留下已创建的标签或 Release 草稿；下次手动运行会选择下一个未占用版本。请先在 GitHub 检查并处理这些残留，再决定如何重试。构建本身和最终发布都只发生在手动运行工作流后。如果主分支恰好在创建标签前发生变化，该次运行会停止，应从当前 `main` 手动启动一次新运行。

iOS 共用同一 Flutter 前端和玻璃组件。构建 iOS 仍需 macOS、Xcode 和签名环境；Windows 可以维护工程和运行 Dart 测试，不能在本机生成可安装的 iPhone 包。在 Mac 上：

```sh
cd app
flutter pub get
flutter build ios --no-codesign
```

页面与控件一致性由共用 Dart 实现保证，系统键盘、WebView、媒体解码和系统权限界面仍需在目标设备上验收。

已完成的本地检查及待验收项见 [本地验收记录](verification.md)。已在安卓模拟器验证真实正片、主要播放操作与账号资料读取；账号云端写回及 iOS 设备的完整验收尚未完成。片库当前浏览已读取的首页目录，完整历史片库可通过官方接口搜索，全量目录分页仍待接入。

## 社区功能验证

留言板读取使用动画疯官方每集留言接口，保留建议排序、时间排序、分页、折叠留言、回复和推嘘操作。通知中心读取官方账号顶栏中的通知与订阅更新，只把已验证的动画剧集链接投影到 Flutter；账号切换会清除上一账号的通知和已读状态。

详情页与播放页在故事简介下方显示留言板，包含官网平均分、评分人数和五档星级分布；内嵌留言区保留官方建议顺序，最多显示前十条。滚动到底可通过液态玻璃“查看完整留言板”按钮打开二级页面，后续分页在二级页面加载。每集使用独立的官方留言板 ID，切集时分别保留本机草稿与回复对象。

故事简介预览最多显示 200 个字符（按完整 Unicode 字符计数），超过后通过“查看完整简介”打开可滚动的二级页面。弹幕入口位于视频画面内，竖屏和全屏保持相同的操作语义。

播放期间，完整简介、留言板及留言附图使用 `SecondaryPageRoute`：页面仍绘制自己的不透明背景，但路由不剔除下面的播放页，并关闭路由快照。只设置 `maintainState` 会保留 Dart 对象，却仍允许路由把平台视频视图隐藏；会话测试同时检查 WebView 实例和是否仍在绘制树中。

iOS 继续使用官方 WKWebView 播放，进入后台／息屏时自动暂停，回到前台保持暂停；当前不启用小窗或后台音频。正片阶段新增原生 `PlaybackCache`：用系统后台 `URLSession` 下载当前画质、音轨接下来约 120 秒的 HLS 分片、初始化数据与密钥，通过仅监听回环地址的本机 HTTP 网关供同一个播放器读取。缓存按播放请求隔离，切集或退出时取消旧任务；磁盘缓存上限 96 MiB。官方广告、账号、地区与年龄校验仍先由原页面完成。

网关只接受当前清单中登记的 `bahamut.akamaized.net` HTTPS 资源，使用每次会话独立的随机路径及官方页面来源校验；不读取或导出 WebView Cookie。清单保留原有加密、分片范围、音轨和时间信息。第一次转入缓存源时保留进度、画质、倍速、静音与暂停状态；切换过程中进入后台也不会因异步加载完成而开始播放。网关失败会恢复官方媒体源；未使用缓存时不改变原有播放路径。

背景网络任务由 [Apple 后台 URLSession](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) 调度。这里使用可按时间窗口加载的原始 HLS 分片与本机回放网关，不创建独立的离线整集下载。系统可能延后任务，用户强制退出应用会取消后台传输，不能承诺无限期连续加载。尚需在 macOS/Xcode 构建和 iPhone 上验证原生回环媒体加载、锁屏期间的实际传输和返回后的缓存命中；Windows 离线测试及 Swift 语法解析不能替代这些验收。

弹幕内容继续由官方播放器渲染，播放阶段读取 `m3u8` 插件，弹幕管理器使用 `animePlayer` 插件。Flutter 面板保存官方播放器支持的透明度、字号和滚动／顶部／底部显示设置，并提供官方发送入口。弹幕和留言发送均在 WebView 会话内取得 CSRF，发送前再次确认账号、剧集、文档和正片状态。

发送功能的测试全部使用离线 transport mock：覆盖正确参数、CSRF、服务器拒绝、重复提交、账号切换、切集、广告和过期文档。测试不会向动画疯实际发布弹幕或留言。只读联机检查使用 GET 验证了真实留言与弹幕返回格式。

## 设计与字体

玻璃用于导航与操作层，内容卡片保留清晰、不透明的图像和文字。设计依据见 [设计说明](liquid-glass.md)。

应用内附 Noto Sans TC 与 Noto Sans SC 字体，使两端中文排版共用相同字体并覆盖简繁字形；许可证位于 `app/assets/fonts/OFL.txt` 与 `OFL-SC.txt`。第三方客户端与巴哈姆特官方没有从属关系。
