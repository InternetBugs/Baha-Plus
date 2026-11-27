import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'catalog_pages.dart' show AnimeWaterfall, ShowAnime;
import 'chrome.dart';
import 'layout.dart';

class CollectionPage extends StatefulWidget {
  const CollectionPage({
    required this.store,
    required this.collection,
    required this.openDetail,
    super.key,
  });

  final AppStore store;
  final AnimeCollection collection;
  final ShowAnime openDetail;

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  final _title = GlassLargeTitleController();
  AppStore get store => widget.store;

  AnimeCollection _resolvedCollection() {
    final target = widget.collection;
    if (target.id == 'new-added') {
      final items = store.newAdded;
      return AnimeCollection(
        id: 'new-added',
        title: store.t('newlyAdded'),
        items: items.isEmpty ? target.items : items,
      );
    }
    if (target.id == 'expiring-all') {
      final live = store.expiringCollection;
      return AnimeCollection(
        id: 'expiring-all',
        title: store.t('expiringSoonTitle'),
        items: live?.items ?? target.items,
        expiring: true,
      );
    }
    for (final candidate in store.catalog.collections) {
      if (candidate.id == target.id || candidate.title == target.title) {
        return candidate;
      }
    }
    return target;
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 1280);
    final safe = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) {
        final collection = _resolvedCollection();
        final subtitleParts = <String>[
          if (collection.expiring) store.t('heroExpiring'),
          store
              .t('collectionCount')
              .replaceAll('{n}', '${collection.items.length}'),
        ];
        return GlassScaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          statusBarStyle: GlassStatusBarStyle.auto,
          appBar: GlassAppBar(
            title: Text(
              collection.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            largeTitleController: _title,
            padding: layout.isCompact
                ? const EdgeInsets.symmetric(horizontal: 8)
                : EdgeInsets.only(
                    left: math.max(8.0, hPad.left - 8),
                    right: math.max(8.0, hPad.right - 8),
                  ),
            leading: GlassIconButton(
              semanticLabel: store.t('back'),
              icon: const Icon(CupertinoIcons.chevron_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: CustomScrollView(
            key: PageStorageKey('collection-${collection.id}'),
            controller: _title.scrollController,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              BahaSliverRefreshControl(
                topInset: safe.top + 44,
                onRefresh: store.refreshCatalog,
              ),
              GlassLargeTitle(
                text: collection.title,
                controller: _title,
                padding: EdgeInsets.fromLTRB(hPad.left, 4, hPad.right, 8),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hPad.left, 0, hPad.right, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        subtitleParts.join(' · '),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: collection.expiring
                              ? CupertinoColors.systemOrange
                              : secondary(context),
                        ),
                      ),
                      if (collection.intro.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          collection.intro,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: secondary(context),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (collection.items.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    hPad.left,
                    0,
                    hPad.right,
                    safe.bottom + 40,
                  ),
                  sliver: AnimeWaterfall(
                    store: store,
                    items: collection.items,
                    openDetail: widget.openDetail,
                    itemKeyPrefix: 'collection-${collection.id}',
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      hPad.left,
                      40,
                      hPad.right,
                      safe.bottom + 40,
                    ),
                    child: Center(
                      child: Text(
                        store.t('noResults'),
                        style: TextStyle(color: secondary(context)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }
}
