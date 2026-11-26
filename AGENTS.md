# Repository Instructions

在修改本仓库代码（尤其是 `app/lib/ui/`）前，请先阅读 [docs/liquid-glass.md](docs/liquid-glass.md) 与 [docs/development.md](docs/development.md)。

## iOS 26 Liquid Glass 界面硬性规范

Baha Plus 的 Android 与 iOS 共用一套基于 `liquid_glass_widgets`（`GlassThemeData.ios27()`）的 iOS 26 Liquid Glass 设计语言。新增或修改 Flutter 界面时必须遵守以下规则，**禁止回退到旧版 Cupertino 或 Material 控件**：

1. **弹窗与确认框**：一律使用 `app/lib/ui/glass_alert.dart` 的 `GlassAlert`（`showGlassMessageDialog` / `showGlassConfirmDialog` / `showGlassAlertDialog`）或 `GlassUpdateAlert`，**禁止**使用 `CupertinoAlertDialog`、`AlertDialog`、`showCupertinoDialog`、`showDialog`。破坏性操作传入 `destructive: true`（或 `isDestructive: true`）。
2. **弹出选择菜单**：一律使用 `app/lib/ui/glass_settings_menu.dart` 的 `GlassSettingsMenu` 及 `glassSettingsOptionItem` / `glassSettingsActionItem` / `glassSettingsSubmenuItem`，**禁止**使用 `CupertinoActionSheet` 或 `showCupertinoModalPopup` 选项表。
3. **布尔开关**：一律使用 `GlassSwitch`（设置分组内复用 `GlassSettingsSwitchRow`），**禁止**使用 `CupertinoSwitch` 或 Material `Switch`。
4. **互斥筛选／分段切换**：2–5 项一律使用 `GlassSegmentedControl`，6 项及以上一律使用 `GlassSegmentedControl.scrollable`，**禁止**使用 `CupertinoSlidingSegmentedControl`、`CupertinoSegmentedControl` 或多个散装按钮拼接互斥切换。
5. **下拉刷新与进度条**：下拉刷新一律使用 `CustomScrollView` + `CupertinoSliverRefreshControl` + `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())`，**禁止**使用 Material `RefreshIndicator`；线性加载进度条使用 `GlassProgressIndicator.linear`，**禁止**使用 Material `LinearProgressIndicator`。
6. **图标体系**：一律使用 `CupertinoIcons.*`；若 `CupertinoIcons` 缺少对应 Apple SF Symbols 图形，在 `app/lib/ui/chrome.dart` 维护统一描边与圆角的矢量图标（如 `PipIcon`），**禁止**在 UI 中引入 Material `Icons.*`。
7. **视频画布上的浮层控件与 HUD**：长按倍速提示、滑动快进预览、广告倒计时／跳过按钮及顶部／底部播放控制条必须使用 `GlassContainer`（`useOwnLayer: true`、`platformViewBackdrop: true`、`LiquidRoundedSuperellipse`），**禁止**使用纯黑半透明 `Container` 或实心矩形 `CupertinoButton.filled`；视频顶部多按钮操作（竖屏与全屏）统一收进共享液态玻璃胶囊。
8. **形状、徽标与共享交互控件**：所有 `GlassContainer` / `GlassButton.custom` 一律使用 `LiquidRoundedSuperellipse`（胶囊按钮半径取 `height / 2`），**禁止**使用 `LiquidRoundedRectangle`；封面／海报／视频容器圆角裁切使用 `ClipRSuperellipse`，不透明卡片使用 `RoundedSuperellipseBorder`；选集按钮统一复用 `EpisodeChipButton`，重试／登录等轻量行动按钮统一复用 `GlassActionPill`，未读／状态角标统一复用 `GlassBadge` / `GlassBadge.dot`；分类及强调色使用 `CupertinoColors.system*`，禁止直接引入 Material `Colors.blue` 等色板；iOS 26 原生多层液态玻璃应用图标维护在 `app/ios/Runner/AppIcon.icon`（不可从 `Runner.xcodeproj` 移除或退回单层静态位图）。
9. **沉浸式导航与滚动折射**：全屏可滚动的 `GlassScaffold` 页面保持默认 `extendBody: true` 并为顶部 `GlassAppBar` 预留内边距，使内容滚过导航栏时呈现真实折射与边缘淡出（固定非折叠标题的半屏弹窗面板如 `AccountPage`、`DanmakuPanel` 保持 `extendBody: false` 以避免滚动行与左对齐标题重叠）；移动端与中等宽度底部导航使用 `GlassTabBar.searchable`（4 个浏览标签 + 独立搜索变形球）并开启底部边缘淡出；多按钮工具栏使用 `GlassButtonGroup.icons` 或共享胶囊；手机端 `GlassModalSheet` 保留顶部拖拽指示条。
10. **层次、可读性与质量设置**：内容卡片（封面、海报、评分、留言、设置分组）保持不透明以保证清晰度，不要把内容卡片全部做成玻璃，也不要玻璃叠玻璃；**禁止**在业务组件上硬编码 `quality: GlassQuality.*` 覆盖用户在设置中选择的「玻璃效果」三档质量，并始终适配浅色／深色、简繁中文、大字体与系统减少动画设置。

## 验证要求

修改 Flutter UI 或逻辑后，需运行静态检查与完整测试套件（`FLUTTER_ROOT` 默认 `D:\BahaPlusTools\flutter`）：

```powershell
cd app
flutter analyze
flutter test
```
