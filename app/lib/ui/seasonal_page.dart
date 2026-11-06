import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'catalog_pages.dart' show ShowAnime;
import 'chrome.dart';

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

  Map<String, List<Anime>> _groups() {
    final items = [...store.seasonal];
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
    return result;
  }

  String _dateLabel(String key) {
    if (key.isEmpty) return store.t('recentUpdates');
    final day = DateTime.parse(key);
    final weekdays = store.simplified
        ? ['周一', '周二', '周三', '周四', '周五', '周六', '周日']
        : ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];
    return '${key.substring(5).replaceAll('-', '/')} ${weekdays[day.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, child) => GlassScaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      bottomEdgeFade: false,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(store.t('seasonal')),
        largeTitleController: _title,
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
          CupertinoSliverRefreshControl(onRefresh: store.refreshCatalog),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).top + 56),
          ),
          GlassLargeTitle(
            text: store.t('seasonal'),
            controller: _title,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          ),
          for (final group in _groups().entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
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
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns = (constraints.crossAxisExtent / 190)
                      .floor()
                      .clamp(2, 4);
                  final width =
                      (constraints.crossAxisExtent - 16 * (columns - 1)) /
                      columns;
                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 18,
                      mainAxisExtent: width / (16 / 9) + 86,
                    ),
                    itemCount: group.value.length,
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
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }
}
