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
tools/windows-debug.ps1
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

Windows 桌面 Debug 的工具要求、构建入口及本机验证方法见 [Windows 调试说明](windows-debug.md)。

连接 Android 模拟器后，可单独运行真实网络集成测试：

```sh
cd app
flutter test integration_test/catalog_smoke_test.dart -d emulator-5554 --no-uninstall
```

该测试使用真实搜索接口及公开番剧资料，并等待主视图与剧集缩略图实际解码，不会主动播放影片或修改追番。保留 `--no-uninstall`，避免 Flutter 测试工具默认卸载应用并清理设备数据；也可使用本地脚本的 `-Action Integration`。测试包使用测试入口，日常体验应重新构建并安装普通 `lib/main.dart` 入口的 APK。

## iOS 与发布

Android 日常开发、打包、模拟器验证均在本地完成。GitHub Actions 的 **Manual release** 只支持手动触发：推送代码、创建标签或 Release 均不会启动构建或发版。不要触发该工作流，直到维护者明确决定发布。

### 云端测试包

GitHub Actions 的 **Manual test build** 默认只构建 iOS 测试包并运行 iPhone 模拟器原生 XCTest；`platform` 可选择 `ios`、`android` 或 `both`。先在所选提交运行 JavaScript、Python 和 Flutter 回归及静态检查，再构建所选平台：Android 为正式 Android 密钥签名的 Release APK，iOS 为未签名 IPA。全部所选检查成功后，`BahaPlus-test-build-版本号` 附件提供对应安装包、SHA-256 校验文件和记录平台、源码提交及运行地址的 `build-info.json`，保留 14 天。未选的平台跳过，不会阻塞最终附件汇总。

测试版本复用现有版本选择规则，默认选择高于现有标签的下一个版本，也可手动指定更高版本。测试构建不创建版本标签或 GitHub Release，不修改 `pubspec.yaml`。Android 使用与正式包相同的签名便于覆盖安装；iOS IPA 仍须另行签名后安装。iOS 的 `ios_build_mode` 可选择 `release`（默认）、`profile` 或真正的 `debug`，文件名和 `build-info.json` 均记录模式；Android 保持 Release。Profile 适合签名后独立启动及真机性能测试；Debug 需要调试器启动和签名的 `get-task-allow` 权限。测试构建开启 `BAHA_DIAGNOSTICS`：允许检查 WebView，并每十秒输出不含媒体 URL 的播放健康信息，包括后端类型、缓冲范围、DOM／弹幕节点和画布像素数；正式发布默认关闭。云端编译和模拟器测试完成后，播放、系统控制中心及后台缓存仍需真机验收。

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
2. 在 GitHub **Actions → Manual release → Run workflow** 选择 `main`。可在 **版本号** 中填写 `0.4.0` 或 `v0.4.0`；留空则自动选择版本。点击运行，操作者需有运行工作流和发布 Release 的仓库权限。
3. 指定版本必须是数字形式的 `主版本.次版本.修订号`，且大于所有已有的同格式版本标签；次版本和修订号须小于 1000，生成的 Android 构建号也须在允许范围内。留空时，工作流以 `app/pubspec.yaml` 的版本作为起点，并根据已有的版本标签自动选择下一个版本（例如从 `v0.3.0` 到 `v0.3.1`）。它在构建前为所选提交创建标签，以避免构建期间工作流变更导致 GitHub 拒绝创建标签。APK 和 IPA 使用相同版本，Android 构建号随版本递增；不会修改仓库文件。
4. 工作流分别在 Linux 和 macOS 构建 Android APK 与 iOS IPA；两端都成功后，核对标签是否仍指向所构建的提交，再创建 Release 草稿并上传附件，完成后发布。Release 包含 Android 签名 APK、**未签名**的 iOS IPA 和 SHA-256 校验文件。

发布说明会自动列出自上一个正式 Release 以来的非合并提交，并将提交标题机器翻译成简体中文；首次发布会列出截至该版本的全部非合并提交。翻译可能不准确，发布后可在 GitHub 上修改说明。工作流使用 MyMemory 的公开翻译 API，无需另设密钥，会将提交标题发送给该第三方服务。翻译服务不可用、超出配额或单条标题超过 500 字节时，工作流会在创建标签和构建前失败；稍后可重试，或先处理过长的标题。

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

Android 原生播放实验分支在官方完成广告和授权后，以 ExoPlayer 接管正片，并使用 Flutter 绘制弹幕；精简官方 WebView 继续承担账号校验和进度回传。迁移边界、测试与回退参数见 [Android 原生播放迁移](android-native-player.md)。

当前 `codex/ios-native-player` 分支在同一接管边界使用 `video_player` 的 AVPlayer 后端。iOS 原生模式不启动下述 WebView 专用 HLS 缓存；使用 `BAHA_IOS_NATIVE=false` 可回退原路径。原生生命周期、控制中心、编译命令及真机待验收项见 [iOS 原生播放迁移](ios-native-player.md)。以下 WKWebView 媒体解码、缓存与网页弹幕说明适用于 iOS 回退模式。

广告和回退播放会话启用 WebView 的媒体保留设置，减少二级页面遮挡、应用后台及锁屏时的媒体管线挂起；普通浏览会话关闭该设置。即使桌面／移动页面模式没有变化，进入或离开播放会话也会更新原生设置。应用真正进入 hidden／paused 时暂停视频和音频，返回前台恢复切后台前的媒体位置并保持暂停；临时 inactive（例如拉下 iOS 控制中心）继续接受播放／暂停命令。该设置不代表已实现可靠的 Android 系统后台下载。

iOS 回退模式使用官方 WKWebView 播放，进入后台／息屏时自动暂停，回到前台保持暂停；当前不启用小窗或后台音频。正片阶段的原生 `PlaybackCache` 用系统后台 `URLSession` 下载当前画质、音轨接下来约 120 秒的 HLS 分片、初始化数据与密钥，通过仅监听回环地址的本机 HTTP 网关供同一个播放器读取。缓存按播放请求隔离，切集或退出时取消旧任务；磁盘缓存上限 96 MiB。官方广告、账号、地区与年龄校验仍先由原页面完成。

网关只接受当前清单中登记的 `bahamut.akamaized.net` HTTPS 资源，使用每次会话独立的随机路径及官方页面来源校验；不读取或导出 WebView Cookie。清单保留原有加密、分片范围、音轨和时间信息。预加载使用后台 URLSession；播放器正在等待的分片改用有明确超时的前台会话，避免被后台调度长期阻塞。第一次转入缓存源时保留进度、画质、倍速、静音与暂停状态；切源等待时间定位和可播放数据，期间进入后台会锁定暂停，即使加载在返回前台后才完成也不会自动播放。媒体传输／解码错误或持续 20 秒没有播放进展时，会限次重载当前已授权媒体源；缓存通道故障则回退到官方源。暂停、后台、广告和官方权限错误不会触发该恢复。

画质偏好在文档开始时注入。在官方完成授权和广告流程、返回正片媒体地址后，先读取其主清单并选择已保存的官方档位，再将对应变体地址交给播放器。因此仍会读取主清单，但首批媒体分片直接使用保存的画质；自动模式和档位缺失时保留官方自动源。原始主清单和全部可用档位继续保存在当前文档内，供后续手动切换、自动模式和缓存登记使用。只有官方 `video_src.php` 对应当前剧集的成功响应会参与此处理。

画质命令通过异步 WebView 调用等待执行结果；原生 HLS 按当前媒体后端识别，不使用旧广告遗留的 VHS 档位。连续选择依次执行，失败时保留本机偏好并延后重试；VHS 路径同步官方画质选择器与本机网页偏好。iOS 在元数据就绪并设置进度后恢复原有播放意图，再等待 `canplay`，防止先等 `canplay`、再播放造成循环等待；原来暂停的媒体可在元数据和定位就绪后完成切换，继续保持暂停。只提供官方清单中实际存在的档位。

网页进程退出由 WebView 原生回调处理，恢复当前集的最后有效进度、倍速与静音状态。前台正在播放的正片在 30 分钟内最多自动恢复两次；后台、暂停或广告阶段保留显式重试入口，不自动开始播放。进程退出恢复是兜底，不代表解决内存持续增长；测试版通过 Web Inspector 的 Memory 分类追踪与播放健康信息定位增长来源。

`PlaybackEnvironment` 在前台实际播放时请求 iOS／Android 屏幕常亮，暂停、进入后台或退出时释放。iOS 原生 Now Playing 信息使用实际媒体位置和播放速率，系统播放／暂停／切换事件绑定当前文档后转交播放器；过期文档和真正后台的播放命令会被拒绝。网页 Media Session 同样安装播放／暂停处理器。该控制中心支持不启用后台音频或小窗。

背景网络任务由 [Apple 后台 URLSession](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) 调度。这里使用可按时间窗口加载的原始 HLS 分片与本机回放网关，不创建独立的离线整集下载。系统可能延后任务，用户强制退出应用会取消后台传输，不能承诺无限期连续加载。尚需在 macOS/Xcode 构建和 iPhone 上验证原生回环媒体加载、锁屏期间的实际传输和返回后的缓存命中；Windows 离线测试及 Swift 语法解析不能替代这些验收。

弹幕内容继续由官方播放器渲染，播放阶段读取 `m3u8` 插件，弹幕管理器使用 `animePlayer` 插件。Flutter 面板保存官方播放器支持的透明度、字号和滚动／顶部／底部显示设置，并提供官方发送入口。弹幕和留言发送均在 WebView 会话内取得 CSRF，发送前再次确认账号、剧集、文档和正片状态。

发送功能的测试全部使用离线 transport mock：覆盖正确参数、CSRF、服务器拒绝、重复提交、账号切换、切集、广告和过期文档。测试不会向动画疯实际发布弹幕或留言。只读联机检查使用 GET 验证了真实留言与弹幕返回格式。

## 设计与字体

玻璃用于导航与操作层，内容卡片保留清晰、不透明的图像和文字。设计依据见 [设计说明](liquid-glass.md)。

应用内附 Noto Sans TC 与 Noto Sans SC 字体，使两端中文排版共用相同字体并覆盖简繁字形；许可证位于 `app/assets/fonts/OFL.txt` 与 `OFL-SC.txt`。第三方客户端与巴哈姆特官方没有从属关系。
