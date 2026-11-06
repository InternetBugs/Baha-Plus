import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'account_page.dart';
import 'catalog_pages.dart';
import 'chrome.dart';
import 'detail_page.dart';
import 'official_browser.dart';

class AppRoot extends StatefulWidget {
  const AppRoot({required this.store, this.mountPortal = true, super.key});
  final AppStore store;
  final bool mountPortal;
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  final _titles = List.generate(4, (_) => GlassLargeTitleController());
  final _search = TextEditingController();
  AppStore get store => widget.store;

  void _account() => GlassModalSheet.show<void>(
    context: context,
    initialState: GlassSheetState.full,
    fullSize: .94,
    detents: const {GlassSheetDetent.large},
    fullTopBorderRadius: 36,
    topBorderRadius: 36,
    horizontalMargin: 0,
    bottomMargin: 0,
    showDragIndicator: false,
    expandedColor: const Color(0xfff2f2f7),
    expandedDarkColor: const Color(0xff111113),
    builder: (_) => AccountPage(store: store),
  );

  void _history() => Navigator.push(
    context,
    CupertinoPageRoute<void>(builder: (_) => HistoryPage(store: store)),
  );

  void _detail(Anime anime) {
    store.openDetail(anime);
    Navigator.push(
      context,
      CupertinoPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => DetailPage(store: store, anime: anime),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, child) {
      if (_search.text != store.query) {
        _search.value = TextEditingValue(
          text: store.query,
          selection: TextSelection.collapsed(offset: store.query.length),
        );
      }
      final nativeLayer = Positioned.fill(
        key: const ValueKey('native-layer'),
        child: ExcludeSemantics(
          excluding: store.browserVisible,
          child: IgnorePointer(
            ignoring: store.browserVisible,
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: _native(context),
            ),
          ),
        ),
      );
      final portalLayer = Positioned.fill(
        key: const ValueKey('portal-layer'),
        child: Offstage(
          offstage: !store.browserVisible,
          child: OfficialBrowser(
            key: const ValueKey('official-session'),
            store: store,
          ),
        ),
      );
      return PopScope(
        canPop: !store.browserVisible,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && store.browserVisible) store.dismissBrowser();
        },
        child: Stack(
          // Offstage retains the full layout and official session but submits
          // no platform-view layer for the glass to sample on native pages.
          children: !widget.mountPortal
              ? [nativeLayer]
              : [nativeLayer, portalLayer],
        ),
      );
    },
  );

  Widget _native(BuildContext context) {
    final keys = ['explore', 'schedule', 'library', 'search'];
    final title = store.t(keys[store.tab]);
    final controller = _titles[store.tab];
    final bottomSpace = MediaQuery.paddingOf(context).bottom + 110;
    final body = CustomScrollView(
      key: PageStorageKey('catalog-tab-${store.tab}'),
      controller: controller.scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).top + 44),
        ),
        CupertinoSliverRefreshControl(onRefresh: store.refreshCatalog),
        GlassLargeTitle(
          text: title,
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          trailing: AccountAvatar(store: store, onTap: _account),
        ),
        if (store.tab == 3 || store.tab == 2)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Semantics(
                identifier: 'search-query',
                child: GlassSearchBar(
                  surfaceStyle: GlassSurfaceStyle.solid,
                  controller: _search,
                  placeholder: store.t('searchPlaceholder'),
                  clearButtonSemanticLabel: store.t('clearSearch'),
                  height: 48,
                  onChanged: (value) => store.query = value,
                  onSubmitted: (_) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    store.search();
                  },
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, bottomSpace),
          sliver: SliverToBoxAdapter(
            child: switch (store.tab) {
              1 => ScheduleContent(store: store, openDetail: _detail),
              2 => LibraryContent(
                store: store,
                openDetail: _detail,
                connectAccount: store.connectAccount,
              ),
              3 => SearchContent(store: store, openDetail: _detail),
              _ => HomeContent(
                store: store,
                openDetail: _detail,
                openHistory: _history,
              ),
            },
          ),
        ),
      ],
    );
    return GlassScaffold(
      bottomEdgeFade: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        title: Text(title),
        largeTitleController: controller,
        actions: [
          AnimatedBuilder(
            animation: controller,
            builder: (context, child) => IgnorePointer(
              ignoring: controller.collapseProgress < .5,
              child: Opacity(
                opacity: controller.collapseProgress,
                child: AccountAvatar(store: store, onTap: _account),
              ),
            ),
          ),
        ],
      ),
      bottomBar: GlassTabBar.bottom(
        settings:
            (Theme.of(context).brightness == Brightness.dark
                    ? LiquidGlassSettings.ios27Dark
                    : LiquidGlassSettings.ios27Light)
                .copyWith(
                  backerColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0x40000000)
                      : const Color(0x45ffffff),
                ),
        selectedIndex: store.tab,
        onTabSelected: (index) {
          FocusManager.instance.primaryFocus?.unfocus();
          store.selectTab(index);
        },
        horizontalPadding: 16,
        verticalPadding: 12,
        selectedIconColor: brandBlue,
        selectedLabelColor: brandBlue,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        indicatorColor: Theme.of(context).brightness == Brightness.dark
            ? const Color(0x30ffffff)
            : const Color(0x268e8e93),
        tabs: [
          GlassTab(
            icon: const Icon(CupertinoIcons.square_stack_fill),
            label: store.t('explore'),
          ),
          GlassTab(
            icon: const Icon(CupertinoIcons.calendar),
            label: store.t('schedule'),
          ),
          GlassTab(
            icon: const Icon(CupertinoIcons.rectangle_stack_fill),
            label: store.t('library'),
          ),
          GlassTab(
            icon: const Icon(CupertinoIcons.search),
            label: store.t('search'),
          ),
        ],
      ),
      body: body,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    for (final title in _titles) {
      title.dispose();
    }
    super.dispose();
  }
}
