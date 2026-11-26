import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';

const brandBlue = Color(0xff007aff);
const mediaGlass = LiquidGlassSettings(
  bodyMode: GlassBodyMode.clear,
  glassColor: Color(0x35ffffff),
  backerColor: Color(0x25ffffff),
  thickness: 12,
  blur: 5,
);

Color secondary(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: .55);

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
          minimumSize: const Size(40, 40),
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
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
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
              borderRadius: BorderRadius.circular(18),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13),
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Row(
              children: [
                ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(14),
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
        GlassButton.custom(
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          label: store.t('watch'),
          onTap: () => store.play(anime),
          width: 70,
          height: 36,
          child: Text(
            store.t('watch'),
            style: const TextStyle(
              color: brandBlue,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Standard iOS 26 Liquid Glass capsule pill button for retries, sign-in
/// prompts, and inline actions.
class GlassActionPill extends StatelessWidget {
  const GlassActionPill({
    required this.label,
    required this.onTap,
    this.width,
    this.height = 42,
    this.useOwnLayer = false,
    this.platformViewBackdrop = false,
    this.settings,
    this.foregroundColor,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final double? width;
  final double height;
  final bool useOwnLayer;
  final bool platformViewBackdrop;
  final LiquidGlassSettings? settings;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) => GlassButton.custom(
    shape: LiquidRoundedSuperellipse(borderRadius: height / 2),
    useOwnLayer: useOwnLayer,
    platformViewBackdrop: platformViewBackdrop,
    settings: settings,
    label: label,
    onTap: onTap,
    width: width,
    height: height,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: width == null ? 20 : 12),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: foregroundColor ?? brandBlue,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
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
      borderRadius: BorderRadius.circular(15),
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
