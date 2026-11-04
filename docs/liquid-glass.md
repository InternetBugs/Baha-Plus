# Liquid Glass 实现依据

产品前端是 `Sources/BahaPlus` 中的 SwiftUI 视图。早期 React Native 页面仅为历史预览，不代表当前原生实现。

## Apple 官方参考

- [Materials — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

指南读取日期：2026-11-04。

## 在应用中的使用

| 位置 | 实现 |
| --- | --- |
| 底部标签栏 | 系统 `TabView`；没有覆写背景，iOS 26 自动提供原生玻璃与滚动边缘效果 |
| 顶部工具栏 | `NavigationStack` 与标准 `ToolbarItem`，不添加固定白色底板 |
| 详情页 | 系统 `.sheet` 与原生导航栏 |
| 封面上的播放、追番按钮 | `GlassEffectContainer`、`.glassEffect(.clear.interactive(), in: …)` 与 `glassEffectID` |
| 封面控件的可读性 | 图片上的 35% 黑色遮罩与底部渐变；明亮封面下仍保留白色控件的对比 |
| 内容卡片与作品文字 | 普通内容层，避免把所有卡片都变成玻璃 |
| 滚动行为 | iOS 26 `.tabBarMinimizeBehavior(.onScrollDown)` |
| 辅助功能 | 原生材质跟随系统减少透明度、减少动态效果及外观设置 |
| iOS 17–25 | 标准 `.ultraThinMaterial` 降级 |
| Android | SkipUI 提供原生 Compose 控件与材质；Apple 专有 API 由 `#if !SKIP` 隔离 |

Apple 的指南说明的是材质的用途、层级、可读性和系统行为，没有为第三方界面给出一套固定的 CSS 模糊、透明度或折射参数。本项目 iOS 26 的效果由系统绘制。

Windows 无法渲染 SwiftUI 或执行 Xcode 构建。原生实际观感、Dynamic Type、VoiceOver、系统减少透明度与滚动行为需要在 Mac / iPhone 上验收。
