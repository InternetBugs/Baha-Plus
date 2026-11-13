# 原生目录与影片资料

2026-11-13 起，`main` 的公开目录、搜索、海报补全和带影片 ID 的作品详情使用 Dart HTTP 读取官方公开资料。播放授权、广告和进度回报现统一由独立的原生 HTTP 会话处理，详见[原生 HTTP 播放](native-http-playback.md)。

## 数据路径

- 目录读取 `/mobile_app/anime/v4/index.php`，映射本季更新、人气与新上架作品，合并重复作品并分别保留剧集缩略图和主视图。
- 有影片 ID 的详情读取 `/mobile_app/anime/v4/video.php?sn=…`，核对作品与影片 ID 后生成简介、剧集列表和作品资料。
- 搜索与主视图补全读取原有 `/anime/v1/search.php` 和 `/anime/v1/anime_list.php`，传输层由 WebView JavaScript 改为同一个原生 HTTP 客户端。
- 这些请求始终匿名，不读取或携带官方账号 Cookie，也不使用响应中的收藏、断点或账号状态。官方只返回评分而没有人数和分布时，作品资料显示评分，不生成缺失的统计值。
- 无影片 ID 的详情仍保留既有 HTML 资料读取路径；这是该入口原有的实现，不是原生读取失败后的回退。

`OfficialAppApi` 只允许指定的官方 HTTPS 接口，禁止重定向。请求有 12 秒超时、2 MB 响应上限和释放时取消机制。原生目录与详情的异步结果使用请求代次隔离，过期响应不会覆盖较新的页面状态。

目录成功后更新本地缓存；刷新失败保留已有缓存，同时显示错误与重试按钮。没有缓存时显示加载或错误状态。有影片 ID 的详情失败也直接报错并提供重试。两条路径均不会导航到官网、执行网页资料脚本或回退到 WebView。

## WebView 生命周期

`AppRoot` 首帧后启动原生目录刷新。仅浏览公开目录、搜索或带影片 ID 的详情时，不创建 `OfficialBrowser`，也不创建隐藏在 `Offstage` 中的 `InAppWebView`。

当前原生账号迁移同时覆盖账号资料、收藏、观看记录、留言和通知。这些操作使用
`NativeAccountApi`，只通过平台 CookieManager 读取应用已有的官方登录状态，不创建
WebView，也不执行网页脚本。部分官方响应是 HTML，由 Dart 作为静态资料解析。
收藏成功不替换当前详情路由或播放文档，原生账号刷新也不占用浏览器操作票据。

登录／登出、手动官网浏览以及无影片 ID 的 HTML 详情读取仍会按需创建 WebView。
播放使用独立原生 HTTP 会话，不挂载播放 WebView；旧的网页接管和时钟桥接已删除。
关闭播放后先释放原生媒体，必要的账号同步直接通过原生 HTTP 执行。
接入范围和账号／访客会话边界见[原生 HTTP 播放与账号接入](native-http-playback.md)。

## 验证

离线测试覆盖接口限制、异常响应、取消与超时、目录映射、作品与影片绑定、显式错误及原生重试、缓存保留、过期响应隔离，以及 WebView 按需创建和清理后的卸载。现有账号、收藏、留言与播放界面测试使用离线资料客户端，避免测试过程访问公网。

本轮完整 Flutter 回归 411 项通过，JavaScript 适配器回归 124 项通过，239 条双语资源及 TypeScript 检查通过。Flutter 最终全量回归使用 `--concurrency=1`；此前并发运行中诊断日志压力测试超出其 30 秒时限，单独复测和串行全量回归均通过。

Android 真实网络测试：

```sh
cd app
flutter test integration_test/native_metadata_smoke_test.dart -d <device-id> --no-uninstall
```

测试使用普通应用启动入口，等待真实目录，搜索“進擊”，再从片库点击作品详情；遇到启动更新弹窗时先关闭弹窗。全程不开始播放、不使用账号，并断言包括 `Offstage` 在内的 `OfficialBrowser` 与 `InAppWebView` 组件数量均为零。

2026-11-13 在本机 Android 11 / API 30 / x86_64 专用模拟器中通过：当次返回 78 部目录作品、19 条搜索结果，样本作品 `114197`、影片 `52553` 的详情包含 6 集。测试结果输出后，在详情页停留期间执行 `adb shell dumpsys meminfo app.bahaplus.mobile`，Android 报告 **`WebViews: 0`**，并已核对该详情页的实际截图。

采样可通过测试参数 `--dart-define=BAHA_METADATA_INSPECTION=true` 保留 20 秒检查窗口。该次为 Debug 模拟器功能验证，没有同条件旧版基线，不以进程总内存推算节省量；也不代表 iOS 实机、登录后操作或播放流程已完成本轮联机验收。

原始日志、内存采样与截图保存在忽略的 `artifacts/app-metadata/`，不提交到仓库。
