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

class Artwork extends StatelessWidget {
  const Artwork(this.url, {this.width, this.height, super.key});
  final String url;
  final double? width, height;
  @override
  Widget build(BuildContext context) => CachedNetworkImage(
    imageUrl: url,
    width: width,
    height: height,
    fit: BoxFit.cover,
    fadeInDuration: const Duration(milliseconds: 180),
    placeholder: (context, url) => _placeholder(context),
    errorWidget: (context, url, error) => _placeholder(context),
  );

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
  Widget build(BuildContext context) => Semantics(
    identifier: 'account-button',
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        GlassIconButton(
          semanticLabel: store.t('me'),
          onPressed: onTap,
          size: 44,
          icon: Icon(
            CupertinoIcons.person_crop_circle_fill,
            color: secondary(context),
            size: 32,
          ),
        ),
        if (store.verificationRequired)
          const Positioned(
            top: 2,
            right: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: brandBlue,
                shape: BoxShape.circle,
              ),
              child: SizedBox(width: 8, height: 8),
            ),
          ),
      ],
    ),
  );
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

class CatalogFooter extends StatelessWidget {
  const CatalogFooter(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    if (store.catalog.items.isEmpty) return const SizedBox.shrink();
    final date = DateTime.tryParse(
      store.catalog.fetchedAt,
    )?.toUtc().add(const Duration(hours: 8));
    final label = date == null
        ? ''
        : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${store.t(store.catalogSource == 'live' ? 'dataLive' : 'dataCached')}  $label',
              style: TextStyle(fontSize: 11, color: secondary(context)),
            ),
          ),
          if (store.busy)
            const CupertinoActivityIndicator(radius: 8)
          else
            GlassIconButton(
              size: 36,
              semanticLabel: store.t('refresh'),
              icon: const Icon(CupertinoIcons.arrow_clockwise, size: 17),
              onPressed: store.refreshCatalog,
            ),
        ],
      ),
    );
  }
}

class AnimeTile extends StatelessWidget {
  const AnimeTile({
    required this.store,
    required this.anime,
    required this.onTap,
    this.poster = false,
    super.key,
  });
  final AppStore store;
  final Anime anime;
  final VoidCallback onTap;
  final bool poster;
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
            aspectRatio: poster ? .72 : 1.65,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Artwork(poster ? anime.artwork : anime.cover),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            anime.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  anime.episodeLabel ?? anime.year ?? '',
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
                ClipRRect(
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
          shape: const LiquidRoundedRectangle(borderRadius: 18),
          useOwnLayer: true,
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
