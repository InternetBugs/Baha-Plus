import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({required this.store, required this.anime, super.key});
  final AppStore store;
  final Anime anime;

  void _play(BuildContext context, {Episode? episode}) {
    Navigator.of(context).pop();
    store.play(anime, episode: episode);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, child) => GlassScaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(store.t('details'), style: const TextStyle(fontSize: 17)),
        actions: [
          GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQuery.paddingOf(context).top + 56,
          20,
          40,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: SizedBox(
                height: 350,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Artwork(anime.cover),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x11000000), Color(0xdd000000)],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            anime.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            [
                              anime.year,
                              anime.episodeLabel,
                            ].whereType<String>().join(' · '),
                            style: const TextStyle(
                              color: Color(0xbbffffff),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Flexible(
                                child: GlassButton.custom(
                                  shape: const LiquidRoundedRectangle(
                                    borderRadius: 24,
                                  ),
                                  useOwnLayer: true,
                                  settings: mediaGlass,
                                  onTap: () => _play(context),
                                  height: 48,
                                  width: 185,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        CupertinoIcons.play_fill,
                                        color: Colors.white,
                                        size: 17,
                                      ),
                                      const SizedBox(width: 9),
                                      Text(
                                        store.t(
                                          anime.latestVideoId == null
                                              ? 'play'
                                              : 'playLatest',
                                        ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              GlassIconButton(
                                useOwnLayer: true,
                                settings: mediaGlass,
                                size: 48,
                                semanticLabel: store.t(
                                  store.isFavorite(anime) ? 'unsave' : 'save',
                                ),
                                icon: Icon(
                                  store.isFavorite(anime)
                                      ? CupertinoIcons.bookmark_fill
                                      : CupertinoIcons.bookmark,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  store.toggleFavorite(anime);
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (store.detailLoading)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (store.detailFailed) ...[
              const SizedBox(height: 24),
              Text(
                store.t('detailUnavailable'),
                style: TextStyle(color: secondary(context), height: 1.6),
              ),
              const SizedBox(height: 12),
              GlassButton.custom(
                shape: const LiquidRoundedRectangle(borderRadius: 20),
                width: 100,
                height: 40,
                onTap: () => store.openDetail(anime),
                child: Text(store.t('retry')),
              ),
            ],
            if (store.detail case final detail?) ...[
              if (detail.episodes.isNotEmpty) ...[
                const SizedBox(height: 28),
                SectionHeading(store.t('episodes')),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, bounds) => Wrap(
                    spacing: 10,
                    runSpacing: 12,
                    children: [
                      for (final episode in detail.episodes)
                        SizedBox(
                          width: (bounds.maxWidth - 40) / 5,
                          child: CupertinoButton(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            color: secondary(context).withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(13),
                            onPressed: () => _play(context, episode: episode),
                            child: Text(
                              episode.label,
                              style: const TextStyle(
                                fontSize: 13,
                                color: brandBlue,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (detail.description.isNotEmpty) ...[
                const SizedBox(height: 28),
                SectionHeading(store.t('synopsis')),
                const SizedBox(height: 14),
                Text(
                  detail.description,
                  style: TextStyle(
                    fontSize: 14,
                    color: secondary(context),
                    height: 1.75,
                  ),
                ),
              ],
              if (detail.metadata.isNotEmpty) ...[
                const SizedBox(height: 28),
                SectionHeading(store.t('metadata')),
                const SizedBox(height: 12),
                for (final metadata in detail.metadata)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            metadata.label,
                            style: TextStyle(
                              color: secondary(context),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            metadata.value,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 28),
            GlassButton.custom(
              shape: const LiquidRoundedRectangle(borderRadius: 22),
              width: 225,
              height: 44,
              onTap: () => _play(context),
              child: Text(store.t('officialDetails')),
            ),
          ],
        ),
      ),
    ),
  );
}
