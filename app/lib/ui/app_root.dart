import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import '../data/playback_environment.dart';
import 'account_page.dart';
import 'catalog_pages.dart';
import 'chrome.dart';
import 'detail_page.dart';
import 'official_browser.dart';
import 'seasonal_page.dart';
import 'notifications_page.dart';

class AppRoot extends StatefulWidget {
  const AppRoot({
    required this.store,
    this.mountPortal = true,
    this.portalBuilder,
    super.key,
  });
  final AppStore store;
  final bool mountPortal;
  final WidgetBuilder? portalBuilder;
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _titles = List.generate(5, (_) => GlassLargeTitleController());
  final _search = TextEditingController();
  late final AnimationController _tabAnimation;
  late int _lastTab;
  late PlaybackEnvironment _playbackEnvironment;
  final _officialSessionKey = GlobalKey(debugLabel: 'official-session');
  OverlayEntry? _favoritePortalEntry;
  Route<void>? _favoritePortalRoute;
  Map<ScrollController, double>? _favoriteScrollOffsets;
  bool _favoritePresentationScheduled = false;
  double _tabDirection = 1;
  AppStore get store => widget.store;
  bool get _favoritePortalVisible =>
      widget.mountPortal && store.browserVisible && store.canRetryFavorite;

  @override
  void initState() {
    super.initState();
    _lastTab = store.tab;
    _tabAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
    store.addListener(_tabChanged);
    store.addListener(_favoritePresentationChanged);
    _favoritePresentationChanged();
    _playbackEnvironment = PlaybackEnvironment(store);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) {
      _playbackEnvironment.setForeground(_mediaActive(state));
      unawaited(store.setApplicationActive(_mediaActive(state)));
    }
  }

  void _tabChanged() {
    if (_lastTab == store.tab) return;
    _tabDirection = store.tab > _lastTab ? 1 : -1;
    _lastTab = store.tab;
    if (MediaQuery.disableAnimationsOf(context)) {
      _tabAnimation.value = 1;
    } else {
      _tabAnimation.forward(from: 0);
    }
  }

  Widget _officialPortal(BuildContext context) => KeyedSubtree(
    key: _officialSessionKey,
    child: widget.portalBuilder?.call(context) ?? OfficialBrowser(store: store),
  );

  void _favoritePresentationChanged() {
    if (store.canRetryFavorite) {
      _favoriteScrollOffsets ??= {
        for (final title in _titles)
          if (title.scrollController.hasClients)
            title.scrollController: title.scrollController.offset,
      };
    }
    if (_favoritePresentationScheduled) return;
    _favoritePresentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _favoritePresentationScheduled = false;
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final overlay = navigator.overlay!;
      if (widget.mountPortal && _favoritePortalEntry == null) {
        // Reparent the existing official session in the same frame as the
        // root rebuild. A second WebView would lose the authenticated session.
        _favoritePortalEntry = OverlayEntry(
          maintainState: true,
          builder: (context) => ListenableBuilder(
            listenable: store,
            builder: (context, child) => _favoritePortalVisible
                ? Positioned.fill(child: _officialPortal(context))
                : const SizedBox.shrink(),
          ),
        );
        overlay.insert(_favoritePortalEntry!);
      }
      if (_favoritePortalVisible && _favoritePortalRoute == null) {
        final route = RawDialogRoute<void>(
          settings: const RouteSettings(name: 'favorite-official'),
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          transitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) unawaited(store.closeBrowser());
            },
            child: const SizedBox.shrink(),
          ),
        );
        _favoritePortalRoute = route;
        unawaited(
          navigator.push(route).then((_) {
            if (!mounted || _favoritePortalRoute != route) return;
            _favoritePortalRoute = null;
            if (_favoritePortalVisible) unawaited(store.closeBrowser());
          }),
        );
        // The popup owns Back handling; the persistent portal paints above
        // it and the still-mounted detail and source routes.
        overlay.rearrange([_favoritePortalEntry!], below: _favoritePortalEntry);
      } else if (!_favoritePortalVisible && _favoritePortalRoute != null) {
        final route = _favoritePortalRoute!;
        _favoritePortalRoute = null;
        if (route.isActive) navigator.removeRoute(route);
      }
      // A guest response can temporarily empty the favorites tab. Restore its
      // position after the account snapshot is available and laid out again.
      if (!store.canRetryFavorite && !store.busy) {
        final offsets = _favoriteScrollOffsets;
        _favoriteScrollOffsets = null;
        for (final entry
            in offsets?.entries ?? <MapEntry<ScrollController, double>>[]) {
          if (!entry.key.hasClients) continue;
          final position = entry.key.position;
          entry.key.jumpTo(
            entry.value.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant AppRoot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      _playbackEnvironment.dispose();
      _playbackEnvironment = PlaybackEnvironment(store);
      oldWidget.store.removeListener(_tabChanged);
      oldWidget.store.removeListener(_favoritePresentationChanged);
      store.addListener(_tabChanged);
      store.addListener(_favoritePresentationChanged);
      _lastTab = store.tab;
      _tabAnimation.value = 1;
    }
    _favoritePortalEntry?.markNeedsBuild();
    _favoritePresentationChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _playbackEnvironment.setForeground(_mediaActive(state));
    unawaited(store.setApplicationActive(_mediaActive(state)));
  }

  // Pulling down iOS Control Center temporarily removes focus. Only a hidden
  // or paused application has actually entered the background.
  bool _mediaActive(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

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
    // The full-height account page already paints an opaque background.
    maintainContentGlass: false,
    expandedColor: const Color(0xfff2f2f7),
    expandedDarkColor: const Color(0xff111113),
    builder: (_) => AccountPage(store: store, onNotifications: _notifications),
  );

  void _notifications() => Navigator.push(
    context,
    CupertinoPageRoute<void>(builder: (_) => NotificationsPage(store: store)),
  );

  Widget _accountActions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      NotificationBell(store: store, onTap: _notifications),
      const SizedBox(width: 8),
      AccountAvatar(store: store, onTap: _account),
    ],
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

  void _season() => Navigator.push(
    context,
    CupertinoPageRoute<void>(
      builder: (_) => SeasonalPage(store: store, openDetail: _detail),
    ),
  );

  void _selectTab(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (index == store.tab) {
      final scroll = _titles[index].scrollController;
      if (!scroll.hasClients) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        scroll.jumpTo(0);
      } else {
        unawaited(
          scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      return;
    }
    store.selectTab(index);
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
        // Keep tab state, but stop painting and animating its glass while the
        // full-screen browser or player covers it.
        child: Visibility(
          visible: !widget.mountPortal || !store.browserVisible,
          maintainState: true,
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
        ),
      );
      final portalLayer = Positioned.fill(
        key: const ValueKey('portal-layer'),
        child: Offstage(
          offstage: !store.browserVisible,
          child: _favoritePortalVisible
              ? const SizedBox.shrink()
              : _officialPortal(context),
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
    final keys = ['explore', 'schedule', 'library', 'watchHistory', 'search'];
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
        CupertinoSliverRefreshControl(
          onRefresh: switch (store.tab) {
            3 => store.syncAccount,
            4 when store.query.isNotEmpty => store.search,
            2 when store.query.isNotEmpty && store.libraryFilter == 'all' =>
              store.search,
            _ => store.refreshCatalog,
          },
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).top + 44),
        ),
        GlassLargeTitle(
          text: title,
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          trailing: _accountActions(),
        ),
        if (store.tab == 4 || store.tab == 2)
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
          sliver: store.tab == 0
              ? HomeContent(
                  store: store,
                  openDetail: _detail,
                  openHistory: () => store.selectTab(3),
                  openSeason: _season,
                )
              : store.tab == 3
              ? HistoryContent(store: store)
              : store.tab == 2
              ? LibraryContent(
                  store: store,
                  openDetail: _detail,
                  connectAccount: store.connectAccount,
                )
              : store.tab == 4
              ? SearchContent(store: store, openDetail: _detail)
              : SliverToBoxAdapter(
                  child: switch (store.tab) {
                    1 => ScheduleContent(store: store, openDetail: _detail),
                    _ => const SizedBox.shrink(),
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
                child: _accountActions(),
              ),
            ),
          ),
        ],
      ),
      bottomBar: GlassTabBar.bottom(
        key: const ValueKey('main-tab-bar'),
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
        onTabSelected: _selectTab,
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
            icon: const Icon(CupertinoIcons.clock),
            label: store.t('watchHistory'),
          ),
          GlassTab(
            icon: const Icon(CupertinoIcons.search),
            label: store.t('search'),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _tabAnimation,
        child: body,
        builder: (context, child) {
          final progress = Curves.easeOutCubic.transform(_tabAnimation.value);
          return Transform.translate(
            key: const ValueKey('tab-page-transition'),
            offset: Offset(_tabDirection * 24 * (1 - progress), 0),
            child: Opacity(opacity: .65 + .35 * progress, child: child),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _playbackEnvironment.dispose();
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_tabChanged);
    store.removeListener(_favoritePresentationChanged);
    final route = _favoritePortalRoute;
    _favoritePortalRoute = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.navigator?.mounted == true && route.isActive) {
          route.navigator!.removeRoute(route);
        }
      });
    }
    _favoritePortalEntry?.remove();
    _favoritePortalEntry?.dispose();
    _tabAnimation.dispose();
    _search.dispose();
    for (final title in _titles) {
      title.dispose();
    }
    super.dispose();
  }
}
