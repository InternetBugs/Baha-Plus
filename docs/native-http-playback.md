# 原生 HTTP 播放

原实现从 `c6db10f` 建立 `experiment/native-http-playback`，移植 Android TV 项目验证过的
HTTP 播放协议，后合入本地 `main` 并删除实验分支。2026-11-14 按用户要求改为默认播放路径：
普通构建直接通过 HTTP 完成授权、广告事件、影片源和进度回报，使用原生视频后端解码。
播放期间不创建隐藏 WebView，也不依赖 JavaScript 时钟桥接。

## 启用与运行

使用现有 Flutter 工程及原生视频后端：

```sh
cd app
flutter run
```

iOS 和 Android 使用现有 AVPlayer／ExoPlayer。Windows 派生调试工程还需同时传入
`--dart-define=BAHA_WINDOWS_NATIVE=true`，并使用已注册 mpv 的 `desktop_main.dart`。
播放统一使用原生 HTTP。`BAHA_NATIVE_HTTP`、`BAHA_ANDROID_NATIVE` 与
`BAHA_IOS_NATIVE` 旧开关已移除；HTTP 失败显示错误和重试，不再提供网页播放路径。

每集播放建立独立内存 Cookie 容器，通过原生 CookieManager 导入应用已有的官方登录会话。
未登录时按访客协议播放；已登录时向官方授权与进度端点携带账号 Cookie，供官方核验会员
权益、断点和云端进度。Cookie 不写入资料缓存或日志，也不发送给广告或媒体 CDN。
账号切换或登出导致设备 Cookie 变化时，旧播放会话在下一次官方请求前停止并提示重试。
无影片 ID、无原生后端、官方拒绝、广告异常和网络失败均显示明确错误，不回退网页播放。
家长密码、额外网页挑战及未实现的后续广告安排仍会停止播放；不跳过官方校验。

确认框按官方播放器 `r18` 编号显示完整分级名称和适用群体：普遍级、保护级（含
6 至未满 12 岁的陪同要求）、辅12级、辅15级、限制级，以及须年龄验证的限制级。
未知、缺失或格式异常的编号显示“分级待确认”，不默认视为全年龄。简繁文字均能
自动换行，较窄的播放器允许滚动查看说明和确认按钮。确认提示只保留观看年龄及
陪同要求，已按用户要求删除“同意观看官方广告”文案。

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
   复用本集内存会话，把十分之一秒转换成秒，并按官方规则转换滚动／顶部／底部、
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
发送使用独立的短期内存 Cookie 容器，不复用播放、广告、设备锁或观看进度的可变会话。
发送前重新检查账号 Cookie、剧集、正片、前台状态和 60 字节 UTF-8 限制；不自动重发。
失败保留草稿，收到官方有效 `sn` 后才把自己的弹幕加入原生画布；迟到确认不会写入新集。
这条路径不通过 JavaScript 获取 Cookie 或执行发送，也不为发送创建隐藏 WebView。

默认播放期间不挂载 `OfficialBrowser` 或隐藏的 `InAppWebView`，不会发送播放器桥接命令。
自动留言预览、收藏和通知使用原生 HTTP。公开目录和有影片 ID 的详情使用现有原生读取。
退出时先回报进度并释放解码器，再原生刷新账号收藏与历史。

## iOS 会话分片缓存

2026-11-14 酥鱼反馈 iOS 切后台后返回前台会失去已缓冲内容，Android 没有同样现象。
此前的原生路径只读取 `AVPlayerItem.loadedTimeRanges`，未为 AVPlayer 保存独立分片。
现在仅 iOS 在 `NativePlayback` 内启用 `NativeHlsCache`：解码器请求本机回环地址，
由 Dart 从当前官方会话已经授权的 CDN 清单按需读取资源。Android 仍直接请求原媒体源。

完整分片保存在当前播放会话的私人临时目录，磁盘上限为 256 MiB，超限淘汰最久未使用的
分片。签名 URL、清单索引和加密密钥只在内存中保留。缓存不新增后台任务或主动预取；
切后台只暂停播放，不销毁缓存。返回前台保持暂停，用户点击播放后，AVPlayer 再次请求
已完成分片时可直接命中本机缓存。切画质隔离对应的缓存区间，切回原画质可复用旧分片；
切集、重新授权和退出会先释放解码器再关闭服务并删除该会话目录。进程被系统终止后的
残留目录在下一次初始化缓存时清理，不恢复旧授权。
临时目录或本机服务无法初始化时，记录不含地址的诊断并继续使用原生直连播放。

缓存服务只监听 `127.0.0.1` 的随机端口，以随机会话路径和预先登记的资源编号寻址。
仅允许官方媒体 CDN 的 HTTPS 源，不跟随重定向，不把账号 Cookie 发送给 CDN。
HLS 清单重写包含变体、密钥、初始化片段及字节范围；不改变媒体序列和加密参数。
iOS ATS 的 HTTP 例外只开放 `127.0.0.1`。下载速率统计上游实际传输字节，本机缓存命中
不计为网络下载。

缓冲条合并原生解码器缓冲与完整缓存分片的真实时间区间，保留定位造成的空缺。
分片的密钥或初始化数据尚未取得时，不将其显示为可用缓存；网络失败和未完成下载
也不显示。AVPlayer 返回空缓冲事件不会抹去独立缓存的区间。

Windows 离线回归通过实际回环 HTTP 服务及模拟 CDN 验证断网命中、缓冲清空事件、
后台往返、画质切换、密钥、字节范围和退出清理。此结果不代替 iOS 编译或 iPhone
解码验收。真机需先播放并缓冲，再分别短时切后台、锁屏及长时后台；回前台核对缓存条、
保持暂停及手动续播，并在已缓存区间内断网播放，确认缓存命中。另需检查自动画质、
切集、退出重开、内存／存储压力和网络中断。

## 账号与社区原生接入

`NativeAccountApi` 与 `OfficialHttpClient` 将下列操作移出 WebView：

- 账号资料、分页收藏与观看记录刷新。观看记录读取 `/anime/v3/history.php`，保留
  断点、已看完状态、下一集和观看时间；接口的影片时长以分钟换算。
- 添加／移除收藏。先确认当前账号与作品对应的两种官方编号，判断实际收藏状态，
  再取得 CSRF 并提交所需变更。重复点击合并处理；成功后更新本机缓存，不导航
  详情或播放器。登录失效时保留目标操作，官方登录成功后继续，返回键可取消。
- 每集留言、排序分页、回复、发布留言、推嘘及取消推嘘，调用官方 wall 接口。
- 通知与订阅更新读取、去重，以及通知对应作品与影片的解析。失败显示原生错误，
  不打开网页作为回退。

账号与收藏页面、通知顶栏及部分作品编号仍由官方返回 HTML；这里使用 Dart DOM
解析器读取数据，不执行页面脚本。登录继续使用官方 WebView，登录适配器只
报告身份变化，收藏和观看记录由原生客户端独立刷新。没有影片 ID 的作品详情仍保留
原有 HTML／WebView 入口。

登出使用原生 HTTP：先 GET `https://user.gamer.com.tw/logout.php`，从官方确认
页面读取一次性令牌，再 POST 同一端点的 `token` 字段；单纯 GET 不会结束会话。
请求使用设备当前 Cookie，令牌只在内存中使用，不执行确认页脚本，不跟随跳转。
发起登出时立即清空账号显示资料、收藏、历史、通知与头像版本，并使在途账号请求失效；
所有已排队的账号缓存写入完成后，移除账号快照与各账号通知已读缓存。官方请求结束、
失败或超时后均删除设备 Cookie；清理期间不允许重新登录，失败不会恢复旧账号资料。

身份解析兼容官方 HTTP 响应没有 JavaScript 用户菜单的情况：从同源
`/viewList.php?u=…` 链接及账号页标题确认账号，核对重复或冲突身份，不执行页面脚本。
身份先于收藏和历史同步完成；后续数据失败保留已确认身份及可重试状态。刚收到官方登录
回调时核对预期账号，短暂 Cookie 读取失败不能把确认的登录清空。普通重定向不作为登出
信号；仅明确的官方登录跳转、401 或访客响应按未登录处理。弹幕发送共用该身份解析。
历史与追番页区分登录身份和数据同步状态；已确认身份但同步失败时提供原生重试，
不会再次要求登录，成功后清除旧同步错误。

原生账号请求仅在当前操作的内存中使用 Cookie，通过平台原生 CookieManager 取得
应用已有的登录状态。它不创建 WebView，也不执行 JavaScript。请求前核对账号，
写入前重新检查 Cookie 与当前页面／剧集，登录登出使在途操作失效；收到明确的成功
回执后不因页面切换将成功误报为失败。wall 写入的 CSRF Cookie 与请求头遵循官网
协议。凭据不会写入资料缓存或诊断日志。

账号数据与播放各持有独立内存 Cookie 快照；默认 HTTP 播放现在也导入设备登录会话。
真实 Android 访客播放和进度回报已经验证，已登录账号的云端进度写回及会员播放仍待
真实账号验收。弹幕发送使用 `NativeDanmakuSender`，原生画布收到成功回执后
显示自己的弹幕。

播放 Cookie 仅接受 `ani.gamer.com.tw` 和 `api.gamer.com.tw` 的 HTTPS 会话，支持 parent-domain、
host-only、路径、替换和过期。Cookie 不发送给广告配置或媒体 CDN。请求不跟随重定向，
限制响应大小并支持超时取消。诊断只记录阶段、状态码和数值，不记录 Cookie、设备标识、
媒体地址或响应正文。

## 旧桥接清理

2026-11-14 按酥鱼要求，在其他窗口已完成原生功能验证的基础上删除旧桥接。
本次清理不重新运行测试或设备验收。

- 删除旧播放脚本、网页授权后交接解码器、JavaScript 时钟同步、网页弹幕轮询，
  以及已经由原生接口替代的目录、收藏和社区脚本。
- 删除旧播放回退开关和仅用于上述桥接的测试入口；保留原生 HTTP、原生解码器与原生界面用例。
- 删除 iOS 网页 HLS 缓存通道、回环网关和相关构建资源，只保留取消旧版遗留后台下载的迁移处理。
- 官方 WebView 只保留登录、手动官网浏览和无影片 ID 的详情读取；其消息仅接受
  当前请求对应的身份与详情事件，拒绝旧播放、收藏及账号集合事件。

## 验证入口

```sh
cd app
flutter test test/native_http_api_test.dart test/native_http_playback_test.dart \
  test/native_danmaku_sender_test.dart test/native_account_api_test.dart \
  test/favorite_navigation_test.dart test/community_test.dart
flutter test integration_test/native_danmaku_sender_smoke_test.dart \
  -d <device> --no-uninstall
flutter test integration_test/native_account_smoke_test.dart \
  integration_test/community_smoke_test.dart -d <device> --no-uninstall
flutter test integration_test/native_http_playback_smoke_test.dart \
  -d <device> --no-uninstall \
  --dart-define=BAHA_DIAGNOSTICS=true
```

真实网络测试使用专用未登录设备，读取真实原生 Cookie 存储并验证默认 HTTP 路径，
默认影片为 `40190`；可以通过
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

以下为迁移历史验证记录；当时默认构建尚使用旧桥接路径。

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

2026-11-14 默认 HTTP 切换验证：

- 普通 `AppStore.create` 默认启用 HTTP；影片 ID 缺失、原生后端不可用及会话变更均不会
  打开播放网页。默认播放器的留言预览、控制和弹幕发送入口通过组件测试。
- 移除旧网页播放桥接及其专用测试、迁移导航断言，并整合分级适用群体、账号同步界面、
  取消追番回执修复后，当前完整 Flutter 回归 **494 项通过**，JavaScript **14 项通过**。
  取消追番专项 41 项及分级界面专项 17 项均包含在完整回归内；Dart 静态分析、
  TypeScript 与 257 条双语资源检查通过。诊断模式的 HTTP 播放、原生解码和系统音频
  回执另有 50 项测试通过；不记录原始异常、媒体地址或账号内容。
- 手机端原先也只接受取消追番回执中的整数 `error: 0`。现与 TV 修复对齐，兼容字符串
  `"0"`、空值及缺失回执，并从服务器重新读取收藏状态、确认账号与 Cookie 会话后再
  更新界面。明确错误、服务器未生效和账号变化仍失败；不重复提交请求。验证使用
  HTTP mock，未真实修改账号收藏。
- 播放页拖动定位遇到命令异常时会清除预览并恢复实际播放位置；后台暂停与长按倍速
  恢复在原生 HTTP 路径下通过回归。
- 可见 Android API 35 模拟器未传入 `BAHA_NATIVE_HTTP=true`，真实影片 `40190` 的广告
  实际推进 30.030 秒，正片累计推进 65.625 秒，3 次进度回报成功，包含 1 次周期回报。
  360p、1.5 倍速、暂停、定位和 707 条弹幕读取通过；暂停定位后画布绘制 8 条弹幕。
- Flutter 组件树（含 offstage）与 Android 运行时均为 **0 个 WebView**。宿主实际按 Home、
  返回应用后，系统媒体会话保持暂停，位置稳定在 80000 毫秒。
- 原生 CookieManager 的设备测试确认 HttpOnly Cookie 可直接用于播放授权与进度
  HTTP mock；更换账号 Cookie 后，旧会话不会发出下一条进度请求。
- 原生账号设备测试使用不含 JavaScript 用户菜单的官方响应结构，31 个 HTTP mock
  请求通过；历史失败保留身份，收藏、留言与通知正常，Cookie 变更会阻止旧账号写入。
  弹幕发送的同类身份结构及原生 HttpOnly Cookie 设备测试通过，真实发布次数为零。
- 构建未带播放开关的普通 `lib/main.dart` Debug APK，覆盖安装时保留模拟器应用数据。
  真实已登录账号的会员播放、云端写回和 iPhone 新默认路径仍待对应设备验收。
- 独立可视化验收从普通首页实际点击《我家的弟弟們真是讓您費心了》第 19 集
  （影片 `52306`）进入确认、广告与正片，暂停位置为 01:07／23:55；弹幕设置、
  发送面板、4 则公开留言的完整留言板、时间排序与留言附图通过。18 次运行时采样
  均为 0 个 WebView，退出后原生媒体会话释放。保留截图与 90 秒录屏；未实际发送内容。

本轮日志与运行时报告位于本机 `artifacts/native-migration-device/`：
`native-http-final-current-all-tests.log`、`favorite-consent-final-tests.log`、
`native-http-final-diagnostics-tests.log`、`http-default-device.log`、
`http-default-runtime.json`、`http-default-cookie-device.log`、
`http-default-sender-device-final.log` 及 `http-default-visible-agent/result.json`；APK 为
`artifacts/BahaPlus-native-http-default-debug.apk`。这些本机验收产物不提交。

2026-11-14 合入本地 `main` 后、切换默认 HTTP 之前的模拟器复核：

- Android 15／API 35、x86_64 上原生账号临时 HttpOnly Cookie 与 27 个 mock 请求通过，
  原生弹幕发送设备 mock 通过，未进行真实账号写入或公开发布。
- 真实目录、搜索、详情及原生留言界面通过。联机发现留言回复数可能是字符串，
  无附图的 `image` 可能为空数组，已修复兼容并增加拒绝畸形格式的回归。
  留言头像、附图、放大、回复、深色模式及不同剧集隔离均通过。
- 默认官方流程交接 ExoPlayer 的真实播放、控制、60 秒持续播放及退出释放通过。
  HTTP 实验的真实广告为 30.03 秒，正片媒体累计推进 63.175 秒，3 次进度回报成功，
  其中 1 次为周期回报；原生弹幕读取 707 条、可见 8 条及显隐切换通过。
  运行时 WebView 数量为零，实际按 Home 并返回后保持暂停与同一原生实例，
  后台及返回位置均为 75000 毫秒。

本轮证据保存在忽略的 `artifacts/native-migration-device/`：
`account-community-integration.log`、`native-community-final.log`、
`community-default-playback.log`、`native-http-runtime.json` 及 `community/` 截图。
早期批次因过时的留言测试布局断言失败，最终留言单项复跑通过；不能将早期批次整体
描述为通过。完整离线回归及本轮主题重建修复记录见[本地验收](verification.md)。

## 尚未覆盖

默认 HTTP 播放已接入原生登录 Cookie、断点读取及官方进度端点；真实登录账号的会员
权益、云端记录写回与跨设备续播仍待验收。账号历史读取和社区功能使用独立原生请求；
留言、收藏、推嘘及弹幕的真实账号写入尚未实测。尚未覆盖完整广告调度、
IMA／互动广告、短广告的后续调度、家长密码和验证码。短于 30 秒且需要后续广告
的情况明确报错。

Android 模拟器通过不能代表 iOS 真机、Windows、低端 ARM 电视或完整一集验收。
HTTP 接口来自官方网页播放器，并无本项目可依赖的公开稳定性承诺。

协议来源与先前实测：相邻 `Baha-Plus-AndroidTV` 仓库的
`docs/native-api-experiment.md`、`NativeApiClient.kt`、`NativeApiPolicy.kt`、
`GuestCookieJar.kt`，以及 2026-11-13 的官方播放器代码和当前官方响应。本轮不修改 TV
仓库，也不移入其 APK、账号数据或原始网络响应。
