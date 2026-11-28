import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'catalog_pages.dart' show ShowAnime, CatalogStatus;
import 'chrome.dart';
import 'layout.dart';

class SeasonalPage extends StatefulWidget {
  const SeasonalPage({
    required this.store,
    required this.openDetail,
    super.key,
  });
  final AppStore store;
  final ShowAnime openDetail;

  @override
  State<SeasonalPage> createState() => _SeasonalPageState();
}

class _SeasonalPageState extends State<SeasonalPage> {
  final _title = GlassLargeTitleController();
  AppStore get store => widget.store;
  List<Anime>? _cachedSeasonal;
  Map<String, List<Anime>> _cachedGroups = const {};
  bool? _cachedSimplified;
  final Map<String, String> _dateLabelCache = {};

  Map<String, List<Anime>> _groups() {
    final current = store.seasonal;
    if (identical(_cachedSeasonal, current)) return _cachedGroups;
    _cachedSeasonal = current;
    final items = [...current];
    final positions = {
      for (var index = 0; index < items.length; index++) items[index].id: index,
    };
    items.sort((a, b) {
      if (a.updateDate == null && b.updateDate == null) {
        return positions[a.id]!.compareTo(positions[b.id]!);
      }
      final day = (b.updateDate ?? '').compareTo(a.updateDate ?? '');
      return day != 0
          ? day
          : (b.updateTime ?? '').compareTo(a.updateTime ?? '');
    });
    final result = <String, List<Anime>>{};
    for (final anime in items) {
      result.putIfAbsent(anime.updateDate ?? '', () => []).add(anime);
    }
    _cachedGroups = result;
    return result;
  }

  String _dateLabel(String key) {
    if (key.isEmpty) return store.t('recentUpdates');
    if (_cachedSimplified != store.simplified) {
      _cachedSimplified = store.simplified;
      _dateLabelCache.clear();
    }
    return _dateLabelCache.putIfAbsent(key, () {
      final day = DateTime.parse(key);
      final weekdays = store.simplified
          ? const ['周一', '周二', '周三', '周四', '周五', '周六', '周日']
          : const ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];
      return '${key.substring(5).replaceAll('-', '/')} ${weekdays[day.weekday - 1]}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 1280);
    final safe = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, child) => GlassScaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        statusBarStyle: GlassStatusBarStyle.auto,
        appBar: GlassAppBar(
          title: Text(store.t('seasonal')),
          largeTitleController: _title,
          padding: layout.appBarPadding(hPad),
          leading: GlassIconButton(
            semanticLabel: store.t('back'),
            icon: const Icon(CupertinoIcons.chevron_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: CustomScrollView(
          key: const PageStorageKey('seasonal-timeline'),
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
              text: store.t('seasonal'),
              controller: _title,
              padding: EdgeInsets.fromLTRB(hPad.left, 4, hPad.right, 16),
            ),
            CatalogStatus(
              store: store,
              padding: EdgeInsets.fromLTRB(hPad.left, 0, hPad.right, 20),
            ),
            for (final group in _groups().entries) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hPad.left, 20, hPad.right, 14),
                  child: Text(
                    _dateLabel(group.key),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.only(left: hPad.left, right: hPad.right),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = AppLayout.timelineColumns(
                      constraints.crossAxisExtent,
                    );
                    return SliverMasonryGrid.count(
                      crossAxisCount: columns,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 18,
                      childCount: group.value.length,
                      itemBuilder: (context, index) {
                        final anime = group.value[index];
                        return AnimeTile(
                          key: ValueKey('timeline-${anime.id}'),
                          store: store,
                          anime: anime,
                          showUpdateTime: true,
                          onTap: () => widget.openDetail(anime),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
            SliverToBoxAdapter(child: SizedBox(height: safe.bottom + 40)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }
}
