# Baha Plus 液态玻璃设计语言

这份文档记录当前 Flutter 界面采用的 iOS 26 Liquid Glass 视觉语言与强制组件规范，供新增页面、调整现有界面及后续 Agent 开发时遵循。Android 和 iOS 共用同一套页面、主题和玻璃组件；平台渲染能力可能影响实际效果。

## 设计原则

- **内容优先**：封面、海报、简介、片单和设置分组保持清晰、实在的内容表面，让图片和文字承担主要视觉层级。
- **玻璃承载操作**：把折射、透明和高光集中用于导航、浮动操作、弹窗、分段选择与播放控制，避免把每张内容卡片都做成玻璃。
- **保持层次**：大标题与主封面建立页面焦点；玻璃覆盖在内容上方，不依靠大量副标题或装饰区分层级。
- **保证可读性**：根据背景选择背衬、渐变和文字颜色。避免玻璃叠玻璃；封面与视频上的操作单独采样，确保文字和边缘高光清楚。
- **尊重系统与用户设置**：适配浅色、深色、系统外观、简繁中文、大字体与减少动画设置。

## 基础样式

| 项目 | 当前实现 |
| --- | --- |
| 玻璃组件 | `liquid_glass_widgets: 1.16.1`；启动时初始化并包装应用，使用 `GlassThemeData.ios27()` |
| 渲染质量 | 用户在设置中选择「玻璃效果」三档：性能（`GlassQuality.minimal`，仅 `BackdropFilter` 磨砂且通过 `GlassAdaptiveScope` 固定上限自动关闭 `GlassPage` 背景纹理采样）、标准（轻量 fragment shader）、质量（`GlassQuality.premium` 完整折射），默认标准。`main.dart` 用嵌套 `GlassAdaptiveScope` + `GlassTheme` 按选择固定全档质量，偏好持久化在 `baha.device.glass` |
| 品牌及操作色 | `brandBlue`：`#007AFF`，用于选中导航、主要操作和强调；破坏性操作使用 `CupertinoColors.systemRed` 胶囊强调 |
| 页面背景 | 浅色 `#FFFFFF`，深色 `#08080A` |
| 内容表面 | 浅色 `#FFFFFF`，深色 `#1C1C1E`；最低层容器分别为 `#F2F2F7`、`#000000` |
| 字体 | 复用 iOS / Android 系统原生中文字体（`bahaFontFallback`，按简繁界面动态优先 PingFang TC/SC、Noto Sans CJK TC/SC 与思源黑体回退），不再内置 28 MB 静态字体文件 |
| 图标 | 统一使用 `CupertinoIcons`；缺失的 Apple SF Symbols 形态（如画中画 `PipIcon`）在 `chrome.dart` 以统一线宽与圆角绘制，不使用 Material `Icons.*` |
| iOS 26 应用图标 | 原生多层液态玻璃图标位于 `app/ios/Runner/AppIcon.icon`（`tile.svg`、`play.svg`、`badge.svg` 三层玻璃 + 浅色／深色背景渐变），已接入 `Runner.xcodeproj`（`folder.iconcomposer.icon`）；Xcode 26 `actool` 编译后向 `Assets.car` 写入 `AppIcon.iconstack`（浅色／深色／色调／透明外观与实时镜面高光）并自动产出 iOS 15–18 兼容位图；同时保留 `Assets.xcassets/AppIcon.appiconset` 兼容旧版 Xcode |
| 文字层级 | 默认正文 16；导航标题 17 / 600，大标题 34 / 700，标签文字 11；次要文字使用主题前景色的 55% 透明度 |

颜色及文字入口见 `app/lib/main.dart` 和 `app/lib/ui/chrome.dart`。优先复用主题与共享组件，不要在业务页面另写一套旧式控件。

## 组件与布局

| 场景 | 规范实现 |
| --- | --- |
| 页面容器与标题 | `GlassScaffold`（默认 `extendBody: true` 以在顶栏与底栏下方产生真实折射与滚动边缘淡出）、`GlassAppBar`；主目录页及通知／留言板二级列表使用随滚动折叠的 `GlassLargeTitle`。推入式子页（新番时间线、合集、通知中心、诊断日志）左侧统一使用 `chevron_back` 返回；模态浮层与详情／简介／留言板／竖屏播放页关闭按钮 `xmark` 统一置于右上角 `actions`，宽屏顶栏与居中内容列对齐 |
| 底部与侧边导航 | 手机与窄分屏使用 `GlassTabBar.searchable`（4 个浏览标签 + 独立搜索变形球）浮于内容上方，并开启底部边缘淡出；平板竖屏／中等分屏（600–899pt）居中限宽展示；宽平板（≥900pt 且高度 ≥560pt）切换为带平滑滑动超椭圆指示胶囊的左侧浮动液态玻璃导航栏 `GlassNavigationRail` |
| 搜索 | 移动端与中等分屏全局搜索直接由 `GlassTabBar.searchable` 变形承载，绑定 `store.query`；片库内局部筛选使用独立 `store.libraryQuery` 与 `GlassSearchBar`（高度 48，实色表面，宽屏限宽并与大标题左对齐），无本地匹配时提供一键跳转全站搜索入口 |
| 圆形与分组操作 | 单按钮使用 `GlassIconButton`（头像入口尺寸 44）；同侧多个顶栏动作使用 `GlassButtonGroup.icons` 合并胶囊（如通知页全部已读／刷新、内置浏览器返回／刷新）；未读数与校验状态角标使用 `GlassBadge` / `GlassBadge.dot` |
| 主要与辅助操作 | 主要操作使用 `GlassButton.custom` + `LiquidRoundedSuperellipse`（胶囊半径取 `height / 2`）；重试、登录、跳转与行内行动按钮统一复用支持大字体自撑高的 `GlassActionPill`；详情页与播放页选集统一复用超椭圆按压反馈组件 `EpisodeChipButton`；可点击卡片与行统一复用 `PressableSurface` 提供微缩按压与桌面悬停反馈 |
| 分段筛选与切换 | 全应用统一复用 `chrome.dart` 的 `BahaSegmentedControl`（2–5 项，封装 `GlassSegmentedControl`）与 `BahaSegmentedControl.scrollable`（6 项及以上，如排期页周一至周日），内置浅／深色高对比样式、大字体自适应高度，以及玻璃容器内嵌防裁切模式（`insideGlassContainer: true`） |
| 开关控件 | 设置项布尔开关统一使用 `GlassSwitch`（封装于 `GlassSettingsSwitchRow`），提供 iOS 26 修长胶囊滑块与拖拽液态拉伸反馈 |
| 下拉刷新、通知与进度 | `extendBody: true` 列表下拉刷新统一复用 `BahaSliverRefreshControl`（内置 `SliverPadding(top: safe.top + 44)` + `CupertinoSliverRefreshControl`），确保刷新指示器位于 `GlassAppBar` 下方而非被遮挡；全局瞬态反馈（如收藏成功／失败）通过 `main.dart` 顶层挂载的 `GlassNoticeToast` 呈现；网页加载与线性进度条使用 `GlassProgressIndicator.linear` |
| 账号、诊断与弹幕面板 | 手机与窄分屏使用带拖拽指示条的 `GlassModalSheet`；平板（≥640×540）以居中圆角浮层卡片呈现；诊断页采用 iOS 26 分组设置卡片（`GlassSettingsGroup` + `GlassSettingsRow`）；视频上的弹幕发送浮层使用半透明 `GlassContainer` 承载内嵌输入区，避免玻璃叠玻璃；留言板底部输入框以 `GlassScaffold.bodyOverlays` 浮于列表上方并开启底部边缘淡出 |
| 弹窗与确认提示 | 全应用所有提示、报错与二次确认弹窗统一使用 `GlassAlert`（`showGlassAlertDialog` / `showGlassMessageDialog` / `showGlassConfirmDialog`、`GlassUpdateAlert`）：同心超椭圆圆角、左对齐排版、胶囊操作按钮（支持 `isPrimary` 蓝胶囊与 `isDestructive` 红胶囊），跟随三档玻璃效果设置 |
| 内容图片与超椭圆 | 统一复用 `BahaRadius`（`hero: 26`、`card: 22`、`tile: 18`、`thumb: 14`、`chip: 15`）与 `bahaCardDecoration`；封面、海报、视频画布与附件图使用 `ClipRSuperellipse`，不透明内容卡片使用 `RoundedSuperellipseBorder`；首页横向滑动轨道与 Hero 轮播贴屏幕边缘滑动不裁切 |
| 播放控制与浮层 HUD | 竖屏在紧凑手机采用 12pt 窄边距圆角视频与同宽液态玻璃控制条（进度条两侧分列当前／总时长、下方 44pt 级播放／±10s／静音／全屏操作，遵循用户三档玻璃质量设置）；横屏全屏顶部关闭、左侧锁屏与右上共享胶囊采用 44pt 手机标准尺寸，中央主控采用 64/52pt（平板 68/54pt）圆形玻璃按钮，底部采用左右分体双翼胶囊（左翼当前时间、右翼总时长＋静音／选集，避开中间硬字幕区）夹紧贴底通透细轨进度条（上方保留隐形触控延展区，窄分屏自动回退为紧凑单胶囊），并支持标题集数／非 1× 倍速标识、全屏玻璃选集浮层与片尾下一集快捷胶囊；长按倍速提示、滑动快进预览、广告倒计时／跳过胶囊均使用 `GlassContainer`（`useOwnLayer: true`、`platformViewBackdrop: true`、`LiquidRoundedSuperellipse`）并适配全屏安全区；宽平板非全屏采用左播放、右选集／简介／留言双栏布局，全屏不强锁方向 |
| 作品资料 | 详情页与播放页均使用无背景的标签、数值分栏，不添加独立卡片；宽屏详情页采用海报横幅与双栏排版 |
| 评分与留言 | 使用不透明内容表面，并以柔和外部投影和较短的接触阴影加强层次；横向留言预览在平板限制单卡宽度并列展示，二级阅读页居中限宽 |

常用共享组件及媒体玻璃设置位于 `app/lib/ui/chrome.dart`，通用液态玻璃弹窗位于 `app/lib/ui/glass_alert.dart`（更新弹窗位于 `app/lib/ui/update_dialog.dart`），设置分组与菜单位于 `app/lib/ui/glass_settings_menu.dart`，响应式断点、平板导航栏与浮层卡片位于 `app/lib/ui/layout.dart`；导航、搜索与面板见 `app/lib/ui/app_root.dart`，封面与详情见 `catalog_pages.dart`、`detail_page.dart`，播放控制见 `player_page.dart`、`native_http_player.dart`。修改共享样式时，应同时检查这些场景。

## 强制规范与禁止回退项

后续开发和重构界面时，**禁止**引入或回退到以下旧版 iOS / Material 控件，必须使用对应的 iOS 26 Liquid Glass 实现：

| 禁止使用（旧版 / Material） | 必须替代为 |
| --- | --- |
| `CupertinoAlertDialog` / `AlertDialog` / `showCupertinoDialog` / `showDialog` | `GlassAlert`（`showGlassMessageDialog` / `showGlassConfirmDialog` / `showGlassAlertDialog` / `GlassUpdateAlert`，位于 `app/lib/ui/glass_alert.dart`） |
| `CupertinoActionSheet` / `showCupertinoModalPopup` 选项菜单 | `GlassSettingsMenu` + `glassSettingsOptionItem` / `glassSettingsActionItem` / `glassSettingsSubmenuItem`（位于 `app/lib/ui/glass_settings_menu.dart`） |
| `CupertinoSwitch` / Material `Switch` | `GlassSwitch`（设置页中统一复用 `GlassSettingsSwitchRow`） |
| `CupertinoSlidingSegmentedControl` / `CupertinoSegmentedControl` / 多个独立按钮拼互斥筛选 | `GlassSegmentedControl`（2–5 项）或 `GlassSegmentedControl.scrollable`（6 项及以上） |
| Material `RefreshIndicator` | `CustomScrollView` + `CupertinoSliverRefreshControl` + `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())` |
| Material `LinearProgressIndicator` / `CircularProgressIndicator` | `GlassProgressIndicator.linear` / `CupertinoActivityIndicator` |
| Material `Icons.*` | `CupertinoIcons.*`，或无法覆盖的 SF Symbols 形态复用 `chrome.dart` 的统一矢量图标（如 `PipIcon`） |
| 视频画面上的实心 `CupertinoButton.filled`、纯半透明黑底 `Container` HUD（如倍速、快进、广告跳过） | `GlassContainer`（`useOwnLayer: true`、`platformViewBackdrop: true`、`LiquidRoundedSuperellipse`）搭配 `_fullscreenControlGlass` / `mediaGlass` |
| `LiquidRoundedRectangle` 用于自定义玻璃按钮／容器 | `LiquidRoundedSuperellipse`（胶囊半径取 `height / 2`） |
| 在业务玻璃组件中硬编码 `quality: GlassQuality.*` | 省略 `quality` 或读取 `GlassThemeData.of(context).qualityFor(context)`，尊重用户三档设置 |
| 错误页／提示页使用裸文字 `CupertinoButton` 重试或登录 | 复用 `GlassActionPill` 胶囊行动按钮 |
| 强调色直接使用 Material `Colors.blue` / `Colors.orange` 等色板 | 使用 `brandBlue` 或 `CupertinoColors.system*` |

封面操作使用的 `mediaGlass` 为透明主体：`glassColor` 为 `0x35FFFFFF`、`backerColor` 为 `0x25FFFFFF`、厚度 12、模糊 5。视频内的控制条和浮动按钮根据需要增加深色背衬，不应直接假定相同参数在所有图片上都清晰。

竖屏播放控制条复用 `mediaGlass` 的透明主体，使用标准渲染质量、厚度 16 和模糊 6。浅色模式采用低透明度的中性灰染色、不加白色背衬，配合柔和的边缘高光与外部投影呈现厚度；深色模式采用低透明度的白色染色和薄深色背衬，避免边缘发白。控制条位于页面背景上，不采样上方的视频画面。

## 交互与背景采样

- 页面玻璃要有真实折射，页面容器必须存在可采样的背景：设置 `backgroundColor` 或 `background` 时 `GlassScaffold` 默认开启背景采样；显式传 `enableBackgroundSampling: false` 会让玻璃退化为合成磨砂染色。仅在没有背景可采样（例如纯透明覆盖层）时才关闭。
- 目录页横向切换使用 280 毫秒的位移与淡入；重复点按当前标签可回到顶部。系统要求减少动画时直接切换或跳转。
- 页面内容为底部浮动导航与系统安全区域预留空间；交互控件应保留清晰的点击范围和无障碍语义。
- 原生目录、搜索与有影片 ID 的详情不创建 WebView。官方操作期间需要隐藏网页时以 `Offstage` 保留当前会话，不提交平台视图到画面合成；操作及清理结束后卸载 WebView。登录时显示官方页面，详见[原生资料与视图生命周期](native-metadata.md)。
- 播放页在圆角视频区域内显示官方播放表面，Flutter 提供导航、播放控制、选集与作品资料。竖屏控制条固定在视频下方、标题上方；横屏控制条叠放在视频内，正片播放时自动隐藏，触碰视频重新显示。广告和年龄验证等官方界面继续保留。玻璃效果由 Flutter 组件渲染，不能视为调用了 iOS 系统原生的 Liquid Glass 材质。

## 验收清单

设计或组件变更后，根据影响范围检查：

- Android 实机或模拟器中，滚动页面时玻璃背景采样、导航选中状态、按钮按压及图片上的可读性。
- 浅色、深色、简体、繁体、大字体，以及系统减少动画设置；检查文本截断、溢出和安全区域。
- 首页、片库、搜索、账号面板、详情及播放页，包括空状态和已有内容时的表现。
- 确认 `app/lib/ui/` 中没有回退引入 `CupertinoAlertDialog`、`CupertinoSwitch`、`CupertinoSlidingSegmentedControl`、`RefreshIndicator`、`LinearProgressIndicator` 或 Material `Icons.*`。
- WebView 登录和播放期间，检查玻璃层、视频画面和官方提示之间的遮挡关系。
- iOS 的玻璃渲染、键盘、WebView 和播放需在 Mac 模拟器或真机单独验收；共用 Flutter 代码本身不代表已经完成平台验证。

## 参考

- [组件官方文档](https://pub.dev/packages/liquid_glass_widgets)
- [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Flutter iOS setup](https://docs.flutter.dev/platform-integration/ios/setup)
