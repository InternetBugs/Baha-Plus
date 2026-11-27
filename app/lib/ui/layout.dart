import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Window width classes shared across phones, foldables, iPads and Android
/// tablets. Driven by live viewport metrics so Split View, Slide Over,
/// Stage Manager and Android multi-window resize smoothly.
enum LayoutSizeClass { compact, medium, expanded }

/// Responsive geometry helpers derived from the current window size and safe
/// area insets.
class AppLayout {
  const AppLayout._(this.size, this.padding);

  factory AppLayout.of(BuildContext context) =>
      AppLayout._(MediaQuery.sizeOf(context), MediaQuery.paddingOf(context));

  factory AppLayout.fromSize(Size size, [EdgeInsets padding = EdgeInsets.zero]) =>
      AppLayout._(size, padding);

  final Size size;
  final EdgeInsets padding;

  double get width => size.width;
  double get height => size.height;

  LayoutSizeClass get sizeClass {
    if (width >= 900) return LayoutSizeClass.expanded;
    if (width >= 600) return LayoutSizeClass.medium;
    return LayoutSizeClass.compact;
  }

  bool get isCompact => sizeClass == LayoutSizeClass.compact;
  bool get isMedium => sizeClass == LayoutSizeClass.medium;
  bool get isExpanded => sizeClass == LayoutSizeClass.expanded;
  bool get isWide => width >= 600;

  /// True for tablet-class screens (iPad mini / Air / Pro, Android 8"–14"
  /// tablets and unfolded large foldables) rather than phones in landscape.
  bool get isTablet => size.shortestSide >= 600;

  /// Use a leading Liquid Glass navigation rail on wide, tall tablet viewports.
  bool get useNavigationRail => width >= 900 && height >= 560;

  /// Use a two-column theater layout (video on the left, companion sidebar on
  /// the right) when watching on a wide tablet viewport.
  bool get useSplitPlayer => width >= 900 && height >= 560;

  /// Use a two-column detail body (episodes + synopsis left, rating + metadata
  /// right) on wide screens.
  bool get useSplitDetail => width >= 840;

  /// Present modal settings sheets as centered floating cards on tablets while
  /// keeping edge-to-edge sheets on phones and narrow Split View windows.
  bool get useCenteredSheet => width >= 640 && height >= 540;

  double get horizontalPadding => switch (sizeClass) {
    LayoutSizeClass.compact => 20.0,
    LayoutSizeClass.medium => 28.0,
    LayoutSizeClass.expanded => 32.0,
  };

  /// Width of the floating Liquid Glass navigation rail capsule. Scales gently
  /// with accessibility text size so 4-character CJK labels stay on one line.
  double railCapsuleWidth(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(11) * 4.6 + 34).clamp(84.0, 120.0);

  /// Horizontal space reserved on the leading edge when the navigation rail is
  /// visible.
  double railReservedWidth(BuildContext context) => useNavigationRail
      ? padding.left + 16.0 + railCapsuleWidth(context) + 12.0
      : 0.0;

  /// Horizontal outer padding for [GlassTabBar.bottom]. On compact screens the
  /// pill fills the width with 16pt margins; on medium tablets it stays centered
  /// at a comfortable dock width.
  double bottomTabBarHorizontalPadding() =>
      isCompact ? 16.0 : math.max(16.0, (width - 500.0) / 2);

  /// Symmetric horizontal padding that centers content within [maxWidth] while
  /// respecting display cutouts and minimum responsive gutters.
  EdgeInsets pageHorizontalPadding({
    required double maxWidth,
    double leadingReserved = 0,
  }) {
    final available = math.max(0.0, width - leadingReserved);
    final centered = math.max(horizontalPadding, (available - maxWidth) / 2);
    final safeLeft = padding.left > 0 ? padding.left + 12.0 : 0.0;
    final safeRight = padding.right > 0 ? padding.right + 12.0 : 0.0;
    return EdgeInsets.only(
      left: leadingReserved > 0 ? centered : math.max(centered, safeLeft),
      right: math.max(centered, safeRight),
    );
  }

  static int posterColumns(double contentWidth) =>
      (contentWidth / 190).floor().clamp(2, 6);

  static int landscapeTileColumns(double contentWidth) =>
      (contentWidth / 240).floor().clamp(2, 4);

  static int timelineColumns(double contentWidth) =>
      (contentWidth / 220).floor().clamp(2, 5);

  static int episodeColumns(double contentWidth, {int min = 5, int max = 10}) =>
      (contentWidth / 68).floor().clamp(min, max);
}

class GlassNavigationRailDestination {
  const GlassNavigationRailDestination({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}

/// Floating vertical Liquid Glass navigation rail for expanded tablet screens.
class GlassNavigationRail extends StatelessWidget {
  const GlassNavigationRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.settings,
    required this.selectedColor,
    required this.indicatorColor,
    required this.width,
    super.key,
  });

  final List<GlassNavigationRailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final LiquidGlassSettings settings;
  final Color selectedColor;
  final Color indicatorColor;
  final double width;

  static const _itemHeight = 60.0;
  static const _itemGap = 4.0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final themeQuality = GlassThemeData.of(context).qualityFor(context);
    final unselectedColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: dark ? .82 : .76);
    final safeIndex = selectedIndex.clamp(
      0,
      math.max(0, destinations.length - 1),
    );
    return GlassIsolationScope(
      isolated: true,
      defaultQuality: themeQuality,
      child: GlassContainer(
        useOwnLayer: true,
        quality: themeQuality,
        width: width,
        shape: const LiquidRoundedSuperellipse(borderRadius: 30),
        settings: settings,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: SingleChildScrollView(
          primary: false,
          physics: const BouncingScrollPhysics(),
          child: Stack(
            children: [
              if (destinations.isNotEmpty)
                AnimatedPositioned(
                  key: const ValueKey('rail-sliding-indicator'),
                  duration: reducedMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  left: 0,
                  right: 0,
                  top: safeIndex * (_itemHeight + _itemGap),
                  height: _itemHeight,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: indicatorColor,
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < destinations.length; index++) ...[
                    if (index > 0) const SizedBox(height: _itemGap),
                    SizedBox(
                      height: _itemHeight,
                      child: _GlassRailItem(
                        key: ValueKey('rail-tab-$index'),
                        destination: destinations[index],
                        selected: index == safeIndex,
                        selectedColor: selectedColor,
                        unselectedColor: unselectedColor,
                        onTap: () => onSelected(index),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassRailItem extends StatefulWidget {
  const _GlassRailItem({
    required this.destination,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
    super.key,
  });

  final GlassNavigationRailDestination destination;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onTap;

  @override
  State<_GlassRailItem> createState() => _GlassRailItemState();
}

class _GlassRailItemState extends State<_GlassRailItem> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final foreground = widget.selected
        ? widget.selectedColor
        : widget.unselectedColor;
    final fill = widget.selected
        ? Colors.transparent
        : _pressed
        ? (dark ? const Color(0x1effffff) : const Color(0x14000000))
        : _hovered
        ? (dark ? const Color(0x14ffffff) : const Color(0x0b000000))
        : Colors.transparent;
    return Semantics(
      selected: widget.selected,
      button: true,
      label: widget.destination.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: ShapeDecoration(
              color: fill,
              shape: const LiquidRoundedSuperellipse(borderRadius: 22),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.destination.icon, size: 22, color: foreground),
                const SizedBox(height: 4),
                Text(
                  widget.destination.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: foreground,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows a [GlassModalSheet] on phones and narrow Split View windows, or a
/// centered rounded Page Sheet card on tablets.
Future<T?> showAdaptiveGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required double fullSize,
  required double topBorderRadius,
  required Color expandedColor,
  required Color expandedDarkColor,
  double tabletMaxWidth = 600,
  double tabletMaxHeightFraction = .86,
  double tabletMaxHeight = 760,
  AnimationStyle? sheetAnimationStyle,
}) {
  final layout = AppLayout.of(context);
  if (!layout.useCenteredSheet) {
    return GlassModalSheet.show<T>(
      context: context,
      initialState: GlassSheetState.full,
      fullSize: fullSize,
      detents: const {GlassSheetDetent.large},
      fullTopBorderRadius: topBorderRadius,
      topBorderRadius: topBorderRadius,
      horizontalMargin: 0,
      bottomMargin: 0,
      showDragIndicator: true,
      maintainContentGlass: false,
      expandedColor: expandedColor,
      expandedDarkColor: expandedDarkColor,
      sheetAnimationStyle: sheetAnimationStyle,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);
        final sheetHeight = fullSize <= 1.0
            ? media.size.height * fullSize
            : fullSize;
        final sheetTop = math.max(0.0, media.size.height - sheetHeight);
        final topOverlap = math.max(0.0, media.padding.top - sheetTop);
        final sheetTopInset = math.max(12.0, topOverlap);
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(top: sheetTopInset),
            viewPadding: media.viewPadding.copyWith(top: sheetTopInset),
          ),
          child: builder(sheetContext),
        );
      },
    );
  }
  final duration =
      sheetAnimationStyle?.duration ?? const Duration(milliseconds: 220);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: CupertinoLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0x99000000)
        : const Color(0x66000000),
    transitionDuration: duration,
    pageBuilder: (dialogContext, _, _) {
      final media = MediaQuery.of(dialogContext);
      final safe = media.padding;
      final insets = media.viewInsets;
      final dark = Theme.of(dialogContext).brightness == Brightness.dark;
      final availableWidth = math.max(
        320.0,
        media.size.width - safe.left - safe.right - 48.0,
      );
      final availableHeight = math.max(
        240.0,
        media.size.height - safe.top - safe.bottom - insets.bottom - 48.0,
      );
      final targetHeight = math.min(
        math.min(media.size.height * tabletMaxHeightFraction, tabletMaxHeight),
        availableHeight,
      );
      final shape = LiquidRoundedSuperellipse(
        borderRadius: 32,
        side: BorderSide(
          color: dark
              ? const Color(0x22ffffff)
              : const Color(0x14000000),
          width: 0.75,
        ),
      );
      return AnimatedPadding(
        padding: EdgeInsets.only(bottom: insets.bottom),
        duration: media.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                key: const ValueKey('tablet-modal-sheet'),
                constraints: BoxConstraints(
                  maxWidth: math.min(tabletMaxWidth, availableWidth),
                  maxHeight: targetHeight,
                ),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: dark ? expandedDarkColor : expandedColor,
                    shape: shape,
                    shadows: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: dark ? .54 : .22),
                        blurRadius: 42,
                        offset: const Offset(0, 18),
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: dark ? .28 : .08),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipPath(
                    clipper: ShapeBorderClipper(shape: shape),
                    child: CupertinoUserInterfaceLevel(
                      data: CupertinoUserInterfaceLevelData.elevated,
                      child: MediaQuery.removePadding(
                        context: dialogContext,
                        removeTop: true,
                        removeBottom: true,
                        removeLeft: true,
                        removeRight: true,
                        child: Material(
                          type: MaterialType.transparency,
                          child: builder(dialogContext),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (dialogContext, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(dialogContext)) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: .96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
