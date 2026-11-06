# Liquid Glass

Android 与 iOS 共用 Flutter / Dart 界面及 `liquid_glass_widgets 1.16.1`。使用相同的布局、字体、颜色和玻璃组件，让页面有一致的设计语言。

## 组件

| 页面元素 | 实现 |
| --- | --- |
| 页面与玻璃背景采样 | `GlassScaffold` |
| 可折叠大标题 | `GlassLargeTitle`、`GlassAppBar` |
| 悬浮标签导航与选中胶囊 | `GlassTabBar.bottom` |
| 头像、关闭、刷新等操作 | `GlassIconButton` |
| 封面上的播放按钮 | `GlassButton.custom` |
| 搜索 | `GlassSearchBar` |
| 完整播放页面 | Flutter `PlayerPage`，包含视频、播放控制、选集、简介与作品资料 |
| 播放进度和控制 | `GlassContainer`、`GlassSlider` 与 Cupertino 图标 |
| 海报、简介、片单、设置分组 | 普通不透明内容 |

在启动时预载组件的 shader，两端使用同一套 `GlassThemeData.ios27` premium 配置、中文字体与 Cupertino 图标。悬浮标签栏保留形状一致的薄背衬；封面上的按钮单独取样，确保按钮文字与边缘高光清楚可见。系统渲染能力仍可能影响折射质量和性能。

玻璃只用于导航与控制层，避免将每张内容卡片都做成透明面板，也避免嵌套玻璃表面削弱折射。大标题和主封面承担视觉层级，页面减少副标题。

官方 WebView 在原生页面中使用 `Offstage` 保持同一会话，但不提交到画面合成。这样玻璃只采样当前 Flutter 内容，不会出现后台官网文字穿透导航栏的问题。打开登录时显示完整网页，播放时由视频区域承载官方引擎。

播放页面将同一会话中的视频表面嵌入圆角区域，导航、控制、选集、简介及资料均由 Flutter 实现。竖屏与横屏均将玻璃控制条叠放在视频内；正片播放时自动隐藏，触碰视频重新显示。切换布局保留同一个 WebView。原有控制栏隐藏，广告进度、提示、合法跳过按钮和年龄界面继续保留；广告期间只提供播放、暂停和静音。控制桥接读取官方核心的正片/广告状态，不将流地址或会话令牌传入 Dart。

## 本地验收

- 实际 Android APK 在本地模拟器运行。
- 检查玻璃导航的背景采样、选中指示器、按钮按压与滚动。
- 检查浅色、深色、简体、繁体以及大字体下的溢出。
- 检查账号页、搜索、空白首页与已有缓存首页。
- iOS 渲染、键盘、WebView 和播放必须在 Mac 模拟器或真机另外验收。

## 依据

- [组件官方文档](https://pub.dev/packages/liquid_glass_widgets)
- [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Flutter iOS setup](https://docs.flutter.dev/platform-integration/ios/setup)
