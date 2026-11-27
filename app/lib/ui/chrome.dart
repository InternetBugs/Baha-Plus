import 'dart:async';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'glass_alert.dart';

const brandBlue = Color(0xff007aff);
const mediaGlass = LiquidGlassSettings(
  bodyMode: GlassBodyMode.clear,
  glassColor: Color(0x35ffffff),
  backerColor: Color(0x25ffffff),
  thickness: 12,
  blur: 5,
);

/// Shared continuous-superellipse corner radius tokens across the app.
abstract final class BahaRadius {
  static const double hero = 26;
  static const double card = 22;
  static const double tile = 18;
  static const double thumb = 14;
  static const double chip = 15;
}

Color secondary(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: .55);

/// Unified opaque content-card surface decoration using continuous superellipse
/// corners, a hairline edge border, and gentle elevation.
ShapeDecoration bahaCardDecoration(
  BuildContext context, {
  double borderRadius = BahaRadius.card,
  double tintAlpha = .055,
  bool elevated = true,
  Color? color,
}) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  final surfaceColor =
      color ??
      Color.alphaBlend(
        secondary(context).withValues(alpha: tintAlpha),
        theme.scaffoldBackgroundColor,
      );
  return ShapeDecoration(
    color: surfaceColor,
    shape: RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide(
        color: dark ? const Color(0x18ffffff) : const Color(0x0d000000),
        width: 0.5,
      ),
    ),
    shadows: elevated
        ? [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .28 : .06),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .16 : .03),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ]
        : null,
  );
}

/// Tactile press-scale and pointer-hover feedback for interactive cards & rows.
class PressableSurface extends StatefulWidget {
  const PressableSurface({
    required this.onTap,
    required this.child,
    this.pressedScale = 0.975,
    super.key,
  });

  final VoidCallback? onTap;
  final Widget child;
  final double pressedScale;

  @override
  State<PressableSurface> createState() => _PressableSurfaceState();
}

class _PressableSurfaceState extends State<PressableSurface> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: !reduceMotion && _pressed ? widget.pressedScale : 1.0,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Top-inset-aware pull-to-refresh sliver for `GlassScaffold(extendBody: true)`
/// pages so the spinner appears cleanly below the status bar and `GlassAppBar`.
class BahaSliverRefreshControl extends StatelessWidget {
  const BahaSliverRefreshControl({
    required this.topInset,
    required this.onRefresh,
    super.key,
  });

  final double topInset;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: EdgeInsets.only(top: topInset),
    sliver: CupertinoSliverRefreshControl(onRefresh: onRefresh),
  );
}

/// Unified iOS 26 Liquid Glass segmented control with consistent typography,
/// dynamic text-scale sizing, and light/dark highlight tokens.
class BahaSegmentedControl extends StatelessWidget {
  const BahaSegmentedControl({
    required this.segments,
    required this.selectedIndex,
    required this.onSegmentSelected,
    this.fontSize = 13,
    this.minHeight = 38,
    this.insideGlassContainer = false,
    super.key,
  }) : isScrollable = false,
       labelPadding = null;

  const BahaSegmentedControl.scrollable({
    required this.segments,
    required this.selectedIndex,
    required this.onSegmentSelected,
    this.fontSize = 12.5,
    this.minHeight = 38,
    this.labelPadding = const EdgeInsets.symmetric(horizontal: 14),
    super.key,
  }) : isScrollable = true,
       insideGlassContainer = false;

  final List<GlassSegment> segments;
  final int selectedIndex;
  final ValueChanged<int> onSegmentSelected;
  final double fontSize;
  final double minHeight;
  final bool isScrollable;
  final bool insideGlassContainer;
  final EdgeInsetsGeometry? labelPadding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textScaler = MediaQuery.textScalerOf(context);
    final controlHeight = (textScaler.scale(fontSize) + 22).clamp(
      minHeight,
      58.0,
    );
    final bgColor = insideGlassContainer
        ? (dark ? const Color(0x22ffffff) : const Color(0x14000000))
        : (dark ? const Color(0x1affffff) : const Color(0x14000000));
    final indicatorColor = insideGlassContainer
        ? (dark ? const Color(0x3affffff) : Colors.white)
        : (dark ? const Color(0x30ffffff) : Colors.white);
    final selectedStyle = TextStyle(
      fontFamily: 'BahaSans',
      fontFamilyFallback: const ['BahaSansSC'],
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      color: dark ? Colors.white : brandBlue,
    );
    final unselectedStyle = TextStyle(
      fontFamily: 'BahaSans',
      fontFamilyFallback: const ['BahaSansSC'],
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      color: secondary(context),
    );
    if (isScrollable) {
      return GlassSegmentedControl.scrollable(
        height: controlHeight,
        borderRadius: controlHeight / 2,
        maskingQuality: MaskingQuality.off,
        labelPadding:
            labelPadding ?? const EdgeInsets.symmetric(horizontal: 14),
        backgroundColor: bgColor,
        indicatorColor: indicatorColor,
        selectedTextStyle: selectedStyle,
        unselectedTextStyle: unselectedStyle,
        selectedIndex: selectedIndex,
        segments: segments,
        onSegmentSelected: onSegmentSelected,
      );
    }
    return GlassSegmentedControl(
      height: controlHeight,
      borderRadius: controlHeight / 2,
      backgroundColor: bgColor,
      indicatorColor: indicatorColor,
      indicatorExpansion: insideGlassContainer
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      indicatorPinchStrength: insideGlassContainer ? 0.0 : 0.4,
      selectedTextStyle: selectedStyle,
      unselectedTextStyle: unselectedStyle,
      selectedIndex: selectedIndex,
      segments: segments,
      onSegmentSelected: onSegmentSelected,
    );
  }
}

/// Floating iOS 26 Liquid Glass HUD toast that surfaces [AppStore.notice]
/// updates across all native routes.
class GlassNoticeToast extends StatefulWidget {
  const GlassNoticeToast({required this.store, super.key});

  final AppStore store;

  @override
  State<GlassNoticeToast> createState() => _GlassNoticeToastState();
}

class _GlassNoticeToastState extends State<GlassNoticeToast> {
  late int _seenRevision;
  String? _message;
  bool _visible = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.store.noticeRevision;
    widget.store.noticeEvents.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(covariant GlassNoticeToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.noticeEvents.removeListener(_onStoreChanged);
      _seenRevision = widget.store.noticeRevision;
      _hideTimer?.cancel();
      _hideTimer = null;
      _visible = false;
      widget.store.noticeEvents.addListener(_onStoreChanged);
    }
  }

  void _onStoreChanged() {
    final store = widget.store;
    if (store.noticeRevision == _seenRevision) return;
    _seenRevision = store.noticeRevision;
    final text = store.notice;
    // OfficialBrowser already displays store.notice inline while open.
    if (text == null ||
        text.isEmpty ||
        (store.browserVisible && !store.usesNativeHttpPlayback)) {
      return;
    }
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _message = text;
      _visible = true;
    });
    _hideTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _dismiss() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_visible && mounted) setState(() => _visible = false);
  }

  @override
  void dispose() {
    widget.store.noticeEvents.removeListener(_onStoreChanged);
    _hideTimer?.cancel();
    super.dispose();
  }

  bool _isPositive(String text) {
    final store = widget.store;
    return text == store.t('added') ||
        text == store.t('removed') ||
        text == store.t('historyCleared');
  }

  @override
  Widget build(BuildContext context) {
    final text = _message;
    if (text == null) return const SizedBox.shrink();
    final safe = MediaQuery.paddingOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final positive = _isPositive(text);
    final accent = positive ? brandBlue : CupertinoColors.systemOrange;
    final ink = dark ? Colors.white : const Color(0xff1c1c1e);
    return IgnorePointer(
      ignoring: !_visible,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, safe.top + 54, 20, 0),
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedSlide(
            offset: _visible ? Offset.zero : const Offset(0, -0.35),
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: Semantics(
                liveRegion: true,
                label: text,
                child: GestureDetector(
                  key: const ValueKey('global-notice-toast'),
                  onTap: _dismiss,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: GlassContainer(
                      useOwnLayer: true,
                      settings: glassAlertSettings(context),
                      shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 11,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            positive
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.exclamationmark_circle_fill,
                            size: 18,
                            color: accent,
                          ),
                          const SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ink,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                height: 1.35,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ],
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
  }
}

/// Apple SF Symbols-style Picture-in-Picture glyph matching CupertinoIcons
/// stroke weight and rounded corners without relying on Material Icons.
class PipIcon extends StatelessWidget {
  const PipIcon({this.size, this.color, super.key});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final effectiveSize = size ?? theme.size ?? 18.0;
    final effectiveColor = color ?? theme.color ?? CupertinoColors.white;
    return SizedBox.square(
      dimension: effectiveSize,
      child: CustomPaint(painter: _PipIconPainter(effectiveColor)),
    );
  }
}

class _PipIconPainter extends CustomPainter {
  const _PipIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = (s * 0.095).clamp(1.2, 2.2);
    final frameWidth = s * 0.90;
    final frameHeight = s * 0.72;
    final frameRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: frameWidth,
      height: frameHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(frameRect, Radius.circular(s * 0.16)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    final inset = stroke * 1.35;
    final pipWidth = frameWidth * 0.44;
    final pipHeight = frameHeight * 0.42;
    final pipRect = Rect.fromLTWH(
      frameRect.right - inset - pipWidth,
      frameRect.bottom - inset - pipHeight,
      pipWidth,
      pipHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pipRect, Radius.circular(s * 0.09)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _PipIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class Artwork extends StatelessWidget {
  const Artwork(this.url, {this.width, this.height, super.key});
  final String? url;
  final double? width, height;
  @override
  Widget build(BuildContext context) {
    if (url == null) {
      return SizedBox(width: width, height: height, child: _placeholder(context));
    }
    Widget image(double? displayWidth) => CachedNetworkImage(
      imageUrl: url!,
      width: width,
      height: height,
      memCacheWidth: displayWidth == null
          ? null
          : (displayWidth * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, 2048),
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (context, url) => _placeholder(context),
      errorWidget: (context, url, error) => _placeholder(context),
    );
    if (width != null) return image(width);
    return LayoutBuilder(
      builder: (context, constraints) =>
          image(constraints.hasBoundedWidth ? constraints.maxWidth : null),
    );
  }

  Widget _placeholder(BuildContext context) => ColoredBox(
    color: secondary(context).withValues(alpha: .08),
    child: Center(
      child: Icon(CupertinoIcons.film, color: secondary(context), size: 32),
    ),
  );
}

class AccountAvatar extends StatelessWidget {
  const AccountAvatar({required this.store, required this.onTap, super.key});
  final AppStore store;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final button = GlassIconButton(
      semanticLabel: store.t('me'),
      onPressed: onTap,
      size: 44,
      icon: AccountPortrait(
        profile: store.accountProfile,
        cacheVersion: store.accountPortraitVersion,
        size: 32,
      ),
    );
    return Semantics(
      identifier: 'account-button',
      child: store.verificationRequired
          ? GlassBadge.dot(
              dotColor: brandBlue,
              semanticLabel: store.t('officialVerification'),
              child: button,
            )
          : button,
    );
  }
}

class AccountPortrait extends StatelessWidget {
  const AccountPortrait({
    required this.profile,
    this.cacheVersion,
    this.size = 52,
    super.key,
  });
  final AccountProfile? profile;
  final int? cacheVersion;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(
      CupertinoIcons.person_crop_circle_fill,
      size: size,
      color: secondary(context),
    );
    final avatar = profile?.avatar;
    if (avatar == null) return fallback;
    return ClipOval(
      child: Image(
        image: CachedNetworkImageProvider(avatar),
        key: ValueKey((profile!.id, cacheVersion)),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
        errorBuilder: (context, error, stack) => fallback,
      ),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {this.onTap, super.key});
  final String title;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
      ),
      if (onTap != null)
        CupertinoButton(
          padding: const EdgeInsets.only(left: 12),
          minimumSize: const Size(44, 44),
          onPressed: onTap,
          child: const Icon(CupertinoIcons.chevron_right, size: 17),
        ),
    ],
  );
}

class AnimeTile extends StatelessWidget {
  const AnimeTile({
    required this.store,
    required this.anime,
    required this.onTap,
    this.poster = false,
    this.titleLines = 2,
    this.showUpdateTime = false,
    super.key,
  });
  final AppStore store;
  final Anime anime;
  final VoidCallback onTap;
  final bool poster;
  final int titleLines;
  final bool showUpdateTime;
  @override
  Widget build(BuildContext context) => PressableSurface(
    onTap: onTap,
    child: Semantics(
      button: true,
      label: anime.title,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: poster ? .72 : 16 / 9,
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(BahaRadius.tile),
              child: Artwork(poster ? anime.poster : anime.cover),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            anime.title,
            maxLines: titleLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    if (showUpdateTime) anime.updateTime,
                    anime.episodeLabel ?? anime.year,
                  ].whereType<String>().where((e) => e.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: secondary(context)),
                ),
              ),
              if (store.isFavorite(anime))
                const Icon(
                  CupertinoIcons.bookmark_fill,
                  color: brandBlue,
                  size: 12,
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class AnimeRow extends StatelessWidget {
  const AnimeRow({
    required this.store,
    required this.anime,
    required this.onTap,
    super.key,
  });
  final AppStore store;
  final Anime anime;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final buttonHeight = (textScaler.scale(13) + 23).clamp(36.0, 50.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: PressableSurface(
              pressedScale: 0.985,
              onTap: onTap,
              child: Row(
                children: [
                  ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(BahaRadius.thumb),
                    child: Artwork(anime.artwork, width: 62, height: 62),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          anime.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          anime.episodeLabel ?? anime.year ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: secondary(context),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          GlassActionPill(
            label: store.t('watch'),
            onTap: () => store.play(anime),
            height: buttonHeight,
            minWidth: 70,
            fontSize: 13,
            horizontalPadding: 14,
          ),
        ],
      ),
    );
  }
}

/// Standard iOS 26 Liquid Glass capsule pill button for retries, sign-in
/// prompts, and inline actions. Adapts its height and width cleanly to
/// accessibility text scales.
class GlassActionPill extends StatelessWidget {
  const GlassActionPill({
    required this.label,
    required this.onTap,
    this.width,
    this.minWidth,
    this.height = 42,
    this.fontSize = 14,
    this.horizontalPadding,
    this.icon,
    this.trailingIcon,
    this.useOwnLayer = false,
    this.platformViewBackdrop = false,
    this.settings,
    this.foregroundColor,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final double? width;
  final double? minWidth;
  final double height;
  final double fontSize;
  final double? horizontalPadding;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool useOwnLayer;
  final bool platformViewBackdrop;
  final LiquidGlassSettings? settings;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final effectiveHeight = math.max(
      height,
      (textScaler.scale(fontSize) + 22).clamp(height, 64.0),
    );
    final fg = foregroundColor ?? brandBlue;
    final hPad = horizontalPadding ?? (width == null ? 18.0 : 12.0);
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1, color: fg),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 6),
            Icon(trailingIcon, size: fontSize - 1, color: fg),
          ],
        ],
      ),
    );
    final button = GlassButton.custom(
      shape: LiquidRoundedSuperellipse(borderRadius: effectiveHeight / 2),
      useOwnLayer: useOwnLayer,
      platformViewBackdrop: platformViewBackdrop,
      settings: settings,
      label: label,
      onTap: onTap,
      width: width,
      height: effectiveHeight,
      child: content,
    );
    if (minWidth != null && width == null) {
      return ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth!),
        child: button,
      );
    }
    return button;
  }
}

/// Shared continuous-superellipse episode chip used across Detail and Player.
class EpisodeChipButton extends StatefulWidget {
  const EpisodeChipButton({
    required this.label,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  State<EpisodeChipButton> createState() => _EpisodeChipButtonState();
}

class _EpisodeChipButtonState extends State<EpisodeChipButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final enabled = !widget.selected && widget.onTap != null;
    final fill = widget.selected
        ? brandBlue
        : _pressed
        ? (dark ? const Color(0x28ffffff) : const Color(0x1a000000))
        : secondary(context).withValues(alpha: .08);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(BahaRadius.chip),
      side: widget.selected
          ? const BorderSide(color: Color(0x33ffffff), width: 0.5)
          : BorderSide.none,
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? widget.onTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: !reduceMotion && _pressed ? 0.96 : 1.0,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: reduceMotion || _pressed
                ? Duration.zero
                : const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            decoration: ShapeDecoration(
              color: fill,
              shape: shape,
              shadows: widget.selected
                  ? [
                      BoxShadow(
                        color: brandBlue.withValues(alpha: dark ? .32 : .22),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                color: widget.selected ? Colors.white : brandBlue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
