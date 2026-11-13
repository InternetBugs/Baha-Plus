# 原生 HTTP 播放实验

本轮在 `experiment/native-http-playback` 分支整合 Android TV 项目已验证的
`nativeApi` 访客播放协议。基线为 `c6db10f`。本分支没有替换 `main` 的正式播放流程，
也没有发布安装包。

## 启用与运行

使用现有 Flutter 工程及原生视频后端：

```sh
cd app
flutter run --dart-define=BAHA_NATIVE_HTTP=true
```

iOS 和 Android 使用现有 AVPlayer／ExoPlayer。Windows 派生调试工程还需同时传入
`--dart-define=BAHA_WINDOWS_NATIVE=true`，并使用已注册 mpv 的 `desktop_main.dart`。
`BAHA_NATIVE_HTTP` 默认关闭，因此既有构建入口保持原来的会话路径。

播放页会明确显示“访客播放实验，不同步账号观看记录”。播放实验建立新的内存访客 Cookie
容器，不读取 WebView Cookie，也不读取或覆盖登录账号的观看数据。影片编号有效且平台提供
原生后端时进入 HTTP 路径。官方拒绝、广告异常和网络失败显示重试，不回退网页播放。

## 会话与界面

`NativeHttpApi` 移植了以下官方网页 HTTP 协议：

1. 读取影片页静态 HTML，初始化设备会话并读取影片资料、官方播放策略。
2. 遇到家长密码、地区／设备拒绝或网页验证立即停止；原生界面要求用户确认观看资格。
3. 需要广告时，只将当前官方配置里的公开视频广告数组作为 JSON 解析，不执行 JavaScript。
   使用同一个原生视频后端实际播放广告；开始事件成功回报且实际媒体推进累计满 30 秒，
   才启用跳过。广告禁止定位、倍速和切画质，使用原生媒体位置累计；暂停、缓冲的
   墙钟时间不计入。原生结束事件会补齐最后一帧尚未采样的实际媒体时长。
4. 广告结束事件成功后，才请求该会话获准的正片源。保留服务端设备标识轮换，读取官方
   HLS 清单和实际可用画质，交给现有 `NativePlayback`。
5. 正片使用设备检查、开始通知、状态回报和进度接口。按实际媒体推进累计每 60 秒回传，
   并在定位、后台和关闭时尝试回报；接近片尾时保留官方 `time=-1` 语义。
6. 正片开始后异步调用 `/anime/v1/danmu.php?videoSn=…&geo=TW,HK` 读取弹幕。
   复用本集内存访客会话，把十分之一秒转换成秒，并按官方规则转换滚动／顶部／底部、
   小／标准／大字号。HTML 只解析为纯文本，不执行脚本；去重排序后交给现有 Flutter
   弹幕画布，不读取或轮询 WebView 弹幕管理器。

恢复位置的边界取自 HLS 分片时长，后续使用解码器的真实媒体时长，不能把资料接口的
`duration` 字段直接当作秒数。每次新 HTTP 会话都重新执行确认与广告流程；重试不复用
旧会话的广告完成状态。

`NativeHttpPlayback` 持有 HTTP 客户端和唯一原生解码器。`AppStore` 直接转交控制命令，
`NativeHttpPlayer` 复用现有 `PlayerPage`。后台期间和加载后迟到的结果均不能自动播放，
返回前台保留暂停，用户点击播放后继续。切集、重试和退出使旧会话失效并释放资源。
弹幕请求不阻塞解码器或进度回报；失败后视频继续播放，可在弹幕设置面板单独重试。
关闭、透明度、字号和显示类型直接作用于原生画布并保存到本机，不发送网页配置命令。
广告期间不读取或显示正片弹幕；切集和退出会清空数据并忽略旧请求的迟到响应。

弹幕发送保留画面内的纸飞机入口，支持正文、颜色、位置和字号。未登录时提示先在账号
页面登录；`NativeDanmakuSender` 仅在用户提交时，通过平台原生 CookieManager 读取应用内
已有登录 Cookie，独立调用账号页确认身份、获取 CSRF，再原生 POST `/ajax/danmuSet.php`。
发送使用短期内存 Cookie 容器，不混入访客播放、广告、设备锁或观看进度会话。
发送前重新检查账号 Cookie、剧集、正片、前台状态和 60 字节 UTF-8 限制；不自动重发。
失败保留草稿，收到官方有效 `sn` 后才把自己的弹幕加入原生画布；迟到确认不会写入新集。
这条路径不通过 JavaScript 获取 Cookie 或执行发送，也不为发送创建隐藏 WebView。

实验播放期间不挂载 `OfficialBrowser` 或隐藏的 `InAppWebView`，不会发送播放器桥接命令。
自动留言预览、收藏和通知也不会为此创建账号 WebView。公开目录和详情仍使用现有原生读取。

## 账号与社区原生接入

`NativeAccountApi` 与 `OfficialHttpClient` 将下列操作移出 WebView，既有播放路径和
HTTP 实验路径共用这一实现，不依赖 `BAHA_NATIVE_HTTP` 开关：

- 账号资料、分页收藏与观看记录刷新。观看记录读取 `/anime/v3/history.php`，保留
  断点、已看完状态、下一集和观看时间；接口的影片时长以分钟换算。
- 添加／移除收藏。先确认当前账号与作品对应的两种官方编号，判断实际收藏状态，
  再取得 CSRF 并提交所需变更。重复点击合并处理；成功后更新本机缓存，不导航
  详情或播放器。登录失效时保留目标操作，官方登录成功后继续，返回键可取消。
- 每集留言、排序分页、回复、发布留言、推嘘及取消推嘘，调用官方 wall 接口。
- 通知与订阅更新读取、去重，以及通知对应作品与影片的解析。失败显示原生错误，
  不打开网页作为回退。

账号与收藏页面、通知顶栏及部分作品编号仍由官方返回 HTML；这里使用 Dart DOM
解析器读取数据，不执行页面脚本。登录／登出继续使用官方 WebView，登录适配器只
报告身份变化，收藏和观看记录由原生客户端独立刷新。没有影片 ID 的作品详情仍保留
原有 HTML／WebView 入口。

原生账号请求仅在当前操作的内存中使用 Cookie，通过平台原生 CookieManager 取得
应用已有的登录状态。它不创建 WebView，也不执行 JavaScript。请求前核对账号，
写入前重新检查 Cookie 与当前页面／剧集，登录登出使在途操作失效；收到明确的成功
回执后不因页面切换将成功误报为失败。wall 写入的 CSRF Cookie 与请求头遵循官网
协议。凭据不会写入资料缓存或诊断日志。

这条账号数据路径与访客播放隔离。读取账号观看记录已迁移；HTTP 实验播放本身仍以
访客身份回报进度，因此不会生成登录账号的云端观看记录。传统播放的广告、播放授权、
进度回传和时钟桥接仍按原有流程运行。两条播放路径的弹幕发送都使用
`NativeDanmakuSender`，原生画布收到成功回执后显示自己的弹幕。

Cookie 仅接受 `ani.gamer.com.tw` 和 `api.gamer.com.tw` 的 HTTPS 会话，支持 parent-domain、
host-only、路径、替换和过期。Cookie 不发送给广告配置或媒体 CDN。请求不跟随重定向，
限制响应大小并支持超时取消。诊断只记录阶段、状态码和数值，不记录 Cookie、设备标识、
媒体地址或响应正文。

## 验证入口

```sh
cd app
flutter test test/native_http_api_test.dart test/native_http_playback_test.dart \
  test/native_danmaku_sender_test.dart test/native_account_api_test.dart \
  test/favorite_navigation_test.dart test/community_test.dart
flutter test integration_test/native_danmaku_sender_smoke_test.dart \
  -d <device> --no-uninstall
flutter test integration_test/native_http_playback_smoke_test.dart \
  -d <device> --no-uninstall \
  --dart-define=BAHA_NATIVE_HTTP=true \
  --dart-define=BAHA_DIAGNOSTICS=true
```

真实网络测试固定使用独立访客会话，默认影片为 `40190`；可以通过
`BAHA_HTTP_TEST_VIDEO` 指定其他影片。它验证实际广告、跳过门槛、正片视频尺寸和原生
时钟推进、暂停、暂停中定位、画质、倍速、应用生命周期通知、至少 60 秒真实媒体推进、
官方进度回报，以及包括 offstage 在内的 WebView 组件数量为零。
另验证真实弹幕加载、暂停定位后的画布绘制、关闭后隐藏和重新开启后恢复。
弹幕发送使用离线 HTTP mock，不向官方发布任何内容。独立设备测试只通过原生插件读写
专用临时测试 Cookie，HTTP 全部由 mock 接管，结束后删除该 Cookie；无需真实账号。

`BAHA_HTTP_INSPECTION=true` 会在最终报告后恢复正片播放并保留 30 秒，供宿主使用
`dumpsys meminfo` 核对运行时 WebView 数量，再实际按 Home、返回应用，检查媒体会话
自动暂停且位置不再推进。此开关需要同时运行宿主检查脚本；测试结束前会断言保持暂停、
仍为同一个原生播放器。测试只在最终报告打印公共影片编号、画质、时钟和计数。
本机证据保存在被忽略的 `artifacts/native-http/`。

2026-11-13 当前窗口整合验证：

- 完整 Flutter 测试 461 项通过，其中原生 HTTP 专项 28 项；静态分析和格式检查通过。
- JavaScript 测试 127 项、Python 测试 12 项、TypeScript 检查与 247 项双语资源校验通过。
- 专用 Android API 35 模拟器 `BahaPlus_NativeHttp_API35` 的联机测试通过：影片 `40190`
  实际广告 30.219 秒，正片累计媒体推进 64.208 秒，4 次进度回报成功，其中 1 次为
  达到 60 秒门槛后的周期回报。暂停、暂停中定位、360p 和 1.5 倍速均验证通过。
- 原生读取 707 条弹幕，暂停定位后画布绘制 8 条，关闭／开启验证通过。包括 offstage
  在内的 WebView 组件数量为零；运行时 `dumpsys meminfo` 同样报告 `WebViews: 0`。
- 实际播放中按 Home，系统媒体会话由 `PLAYING(3)` 转为 `PAUSED(2)`；后台再次取样
  及返回应用后均保持在 75000 毫秒。同一原生播放器实例保留，测试结束后释放。

本轮证据见本机 `artifacts/native-http/report.json`、`integration.log`、
`runtime-inspection.log` 与 `flutter-tests-final.log`。弹幕移植的独立记录仍保留在
`danmaku-report.json` 与 `danmaku-integration.log`。这些产物均不提交到仓库。

弹幕发送补充验证：实现完成时完整 Flutter 回归 478 项通过；工作区出现并行账号迁移
改动后，重新运行发送／播放专项 25 项及相关文件静态检查，均通过。Android 原生插件
测试验证了无需 WebView 即可读取临时 HttpOnly Cookie，并完成 HTTP mock 下的身份
确认、CSRF 和表单发送。真实账号发布次数为零，真实发布仍待使用者自行验收。
记录见本机 `danmaku-send-tests.log`、`danmaku-send-focused-final.log`、
`danmaku-send-device.log` 和 `danmaku-send-report.json`。

账号、社区与弹幕发送合并验证（2026-11-13）：完整 Flutter 回归 **492 项通过**，
JavaScript **119 项通过**，Python **12 项通过**；Dart 静态分析（含集成测试源码）、
TypeScript、248 条双语资源与差异格式检查均通过。覆盖原生账号分页、CSRF 与 Cookie
变化、成功写入回执、旧刷新不覆盖新收藏、登录后继续收藏、详情及来源滚动位置、
播放票据保留，以及媒体清理后 WebView 卸载不等待原生账号请求。
本轮验证未向官方实际发布弹幕或留言，也未使用真实账号修改收藏或推嘘。
记录见本机 `artifacts/native-account-regression-final.log`、
`native-account-js-tests-final.log` 与 `native-account-teardown-tests.log`。

## 尚未覆盖

此次移植的播放流程保留 TV 实验的访客范围，没有接入登录账号历史和跨设备续播。
账号观看记录读取和留言已接入独立原生请求；留言、收藏、推嘘及弹幕的真实账号写入
尚未实测。也不覆盖完整广告
调度、IMA／互动广告、短广告的后续调度、家长密码和验证码。短于 30 秒且需要后续广告
的情况明确报错。

Android 模拟器通过不能代表 iOS 真机、Windows、低端 ARM 电视或完整一集验收。
HTTP 接口来自官方网页播放器，并无本项目可依赖的公开稳定性承诺。

协议来源与先前实测：相邻 `Baha-Plus-AndroidTV` 仓库的
`docs/native-api-experiment.md`、`NativeApiClient.kt`、`NativeApiPolicy.kt`、
`GuestCookieJar.kt`，以及 2026-11-13 的官方播放器代码和当前官方响应。本轮不修改 TV
仓库，也不移入其 APK、账号数据或原始网络响应。
