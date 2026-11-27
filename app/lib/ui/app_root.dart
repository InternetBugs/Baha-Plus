import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import '../data/playback_environment.dart';
import 'account_page.dart';
import 'catalog_pages.dart';
import 'chrome.dart';
import 'collection_page.dart';
import 'detail_page.dart';
import 'layout.dart';
import 'official_browser.dart';
import 'native_http_player.dart';
import 'seasonal_page.dart';
import 'notifications_page.dart';
import 'update_dialog.dart';

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
  final _librarySearch = TextEditingController();
  late final AnimationController _tabAnimation;
  late int _lastTab;
  int _lastBrowseTab = 0;
  late PlaybackEnvironment _playbackEnvironment;
  bool _foreground = true;
  final _officialSessionKey = GlobalKey(debugLabel: 'official-session');
  OverlayEntry? _favoritePortalEntry;
  Route<void>? _favoritePortalRoute;
  Map<ScrollController, double>? _favoriteScrollOffsets;
  bool _favoritePresentationScheduled = false;
  bool _updateCheckInProgress = false;
  double _tabDirection = 1;
  static final _tabBarSettingsDark = LiquidGlassSettings.ios27Dark.copyWith(
    backerColor: const Color(0x40000000),
  );
  static final _tabBarSettingsLight = LiquidGlassSettings.ios27Light.copyWith(
    backerColor: const Color(0x45ffffff),
  );
  AppStore get store => widget.store;
  bool get _favoritePortalVisible =>
      widget.mountPortal && store.browserVisible && store.favoriteLoginPending;

  @override
  void initState() {
    super.initState();
    store.setPortalHostActive(widget.mountPortal);
    _lastTab = store.tab;
    _lastBrowseTab = store.tab < 4 ? store.tab : 0;
    _tabAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
    store.addListener(_tabChanged);
    store.addListener(_favoritePresentationChanged);
    _favoritePresentationChanged();
    _playbackEnvironment = PlaybackEnvironment(store);
    _playbackEnvironment.pictureInPicture.addListener(_syncPlaybackActivity);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) didChangeAppLifecycleState(state);
    _scheduleUpdateCheck();
    _scheduleCatalogRefresh();
    _scheduleProfileRefresh();
    _scheduleNotificationsRefresh();
  }

  Future<void>? _profileRefresh;

  void _scheduleProfileRefresh() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final refresh = store.refreshAccountProfile();
        _profileRefresh = refresh;
        unawaited(refresh);
      });

  void _scheduleNotificationsRefresh() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshNotificationsAtStartup());
      });

  Future<void> _refreshNotificationsAtStartup() async {
    // The profile refresh discovers the signed-in account on a cold start, so
    // wait for it before deciding whether the bell can be populated.
    final profileRefresh = _profileRefresh;
    if (profileRefresh != null) await profileRefresh;
    // An inactive app would make community() throw 'unavailable', which would
    // leave a visible error state on a start that never showed the main screen.
    if (!mounted || !store.hasAccount || !store.applicationActive) return;
    if (store.notificationsLoading) return;
    await store.refreshNotifications();
  }

  void _scheduleCatalogRefresh() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !store.catalogLoading) {
          unawaited(store.refreshCatalog());
        }
      });

  void _scheduleUpdateCheck() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_checkUpdates(automatic: true));
      });

  Future<void> _checkUpdates({bool automatic = false}) async {
    if (_updateCheckInProgress) return;
    _updateCheckInProgress = true;
    final updates = store.updates;
    try {
      final release = await updates.check(automatic: automatic);
      if (!mounted || store.updates != updates) return;
      if (release == null) {
        if (!automatic) await _updateMessage('noAvailableUpdates');
        return;
      }
      final notes = release.changelog;
      final download = await showUpdateAvailableDialog(
        context: context,
        title: store.t('updateAvailable'),
        versionDetails: store
            .t('updateVersionDetails')
            .replaceAll('{current}', updates.currentVersion!)
            .replaceAll('{latest}', '${release.version}'),
        notesTitle: store.t('updateNotes'),
        notesBody: notes.isEmpty ? store.t('noUpdateNotes') : notes,
        hasNotes: notes.isNotEmpty,
        laterLabel: store.t('updateLater'),
        downloadLabel: store.t('downloadUpdate'),
      );
      if (download != true || !mounted) return;
      try {
        await updates.openDownloads();
      } catch (_) {
        if (mounted) await _updateMessage('updateDownloadFailed');
      }
    } catch (_) {
      if (!automatic && mounted && store.updates == updates) {
        await _updateMessage('updateCheckFailed');
      }
    } finally {
      _updateCheckInProgress = false;
    }
  }

  Future<void> _updateMessage(String message) => showUpdateMessageDialog(
    context: context,
    title: store.t('checkUpdates'),
    message: store.t(message),
    closeLabel: store.t('close'),
  );

  void _tabChanged() {
    if (store.tab < 4) _lastBrowseTab = store.tab;
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
    if (store.favoriteLoginPending) {
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
      if (!store.favoriteLoginPending && !store.busy) {
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
    store.setPortalHostActive(widget.mountPortal);
    if (oldWidget.store != store) {
      oldWidget.store.setPortalHostActive(false);
      store.setPortalHostActive(widget.mountPortal);
      oldWidget.store.updates.cancelCheck();
      _playbackEnvironment.pictureInPicture.removeListener(
        _syncPlaybackActivity,
      );
      _playbackEnvironment.dispose();
      _playbackEnvironment = PlaybackEnvironment(store);
      _playbackEnvironment.pictureInPicture.addListener(_syncPlaybackActivity);
      _syncPlaybackActivity();
      oldWidget.store.removeListener(_tabChanged);
      oldWidget.store.removeListener(_favoritePresentationChanged);
      store.addListener(_tabChanged);
      store.addListener(_favoritePresentationChanged);
      _lastTab = store.tab;
      _lastBrowseTab = store.tab < 4 ? store.tab : 0;
      _tabAnimation.value = 1;
      _scheduleUpdateCheck();
      _scheduleCatalogRefresh();
      _scheduleProfileRefresh();
      _scheduleNotificationsRefresh();
    }
    // The persistent entry belongs to the Navigator's overlay, which is
    // outside this subtree while a theme or language change rebuilds us.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _favoritePortalEntry?.markNeedsBuild();
    });
    _favoritePresentationChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncPlaybackActivity();
  }

  void _syncPlaybackActivity() {
    _playbackEnvironment.setForeground(_foreground);
    unawaited(
      store.setApplicationActive(
        _foreground,
        pictureInPicture: _playbackEnvironment.keepsPlaybackInBackground,
      ),
    );
  }

  void _account() {
    if (widget.mountPortal && !store.browserVisible && !store.busy) {
      unawaited(store.syncAccount());
    }
    showAdaptiveGlassSheet<void>(
      context: context,
      fullSize: .94,
      topBorderRadius: 36,
      expandedColor: const Color(0xfff2f2f7),
      expandedDarkColor: const Color(0xff111113),
      tabletMaxWidth: 580,
      tabletMaxHeightFraction: .86,
      tabletMaxHeight: 760,
      builder: (_) => AccountPage(
        store: store,
        onNotifications: _notifications,
        onCheckUpdates: () => unawaited(_checkUpdates()),
      ),
    );
  }

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

  void _collection(AnimeCollection collection) => Navigator.push(
    context,
    CupertinoPageRoute<void>(
      builder: (_) => CollectionPage(
        store: store,
        collection: collection,
        openDetail: _detail,
      ),
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
      if (_librarySearch.text != store.libraryQuery) {
        _librarySearch.value = TextEditingValue(
          text: store.libraryQuery,
          selection: TextSelection.collapsed(offset: store.libraryQuery.length),
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
      final httpLayer = !widget.mountPortal || !store.usesNativeHttpPlayback
          ? null
          : Positioned.fill(
              key: const ValueKey('native-http-player-layer'),
              child: NativeHttpPlayer(
                store: store,
                environment: _playbackEnvironment,
              ),
            );
      final portalLayer =
          !widget.mountPortal ||
              !store.needsOfficialPortal ||
              store.usesNativeHttpPlayback
          ? null
          : Positioned.fill(
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
          // Public catalog/detail reads have no platform view, including an
          // offstage one. Retain the official session only while it is in use.
          children: [nativeLayer, ?portalLayer, ?httpLayer],
        ),
      );
    },
  );

  Widget _native(BuildContext context) {
    final layout = AppLayout.of(context);
    final useRail = layout.useNavigationRail;
    final railWidth = layout.railReservedWidth(context);
    final hPad = layout.pageHorizontalPadding(
      maxWidth: 1280,
      leadingReserved: railWidth,
    );
    final keys = ['explore', 'schedule', 'library', 'watchHistory', 'search'];
    final title = store.t(keys[store.tab]);
    final controller = _titles[store.tab];
    final safe = MediaQuery.paddingOf(context);
    final bottomSpace = safe.bottom + (useRail ? 36 : 110);
    final searchField = store.tab == 2
        ? Semantics(
            identifier: 'library-filter-query',
            child: GlassSearchBar(
              key: const ValueKey('library-filter-bar'),
              surfaceStyle: GlassSurfaceStyle.solid,
              controller: _librarySearch,
              placeholder: store.t('libraryFilterPlaceholder'),
              clearButtonSemanticLabel: store.t('clearSearch'),
              height: 48,
              onChanged: (value) => store.libraryQuery = value,
              onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            ),
          )
        : Semantics(
            identifier: 'search-query',
            child: GlassSearchBar(
              key: const ValueKey('global-search-bar'),
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
          );
    final body = CustomScrollView(
      key: PageStorageKey('catalog-tab-${store.tab}'),
      controller: controller.scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        BahaSliverRefreshControl(
          topInset: safe.top + 44,
          onRefresh: switch (store.tab) {
            3 => store.syncAccount,
            2 when store.libraryFilter == 'favorites' => store.syncAccount,
            4 when store.query.isNotEmpty => store.search,
            _ => store.refreshCatalog,
          },
        ),
        GlassLargeTitle(
          text: title,
          controller: controller,
          padding: EdgeInsets.fromLTRB(hPad.left, 4, hPad.right, 16),
          trailing: _accountActions(),
        ),
        if (store.tab == 0 ||
            store.tab == 1 ||
            (store.tab == 2 &&
                store.libraryQuery.isEmpty &&
                store.libraryFilter != 'favorites'))
          CatalogStatus(
            store: store,
            padding: EdgeInsets.fromLTRB(hPad.left, 0, hPad.right, 20),
          ),
        if (store.tab == 2 || (store.tab == 4 && useRail))
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad.left, 0, hPad.right, 20),
              child: layout.isWide
                  ? Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: searchField,
                      ),
                    )
                  : searchField,
            ),
          ),
        if (store.tab == 0)
          SliverPadding(
            padding: EdgeInsets.only(bottom: bottomSpace),
            sliver: HomeContent(
              store: store,
              horizontalPadding: hPad,
              openDetail: _detail,
              openHistory: () => store.selectTab(3),
              openSeason: _season,
              openCollection: _collection,
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad.left, 0, hPad.right, bottomSpace),
            sliver: store.tab == 3
                ? HistoryContent(store: store, openDetail: _detail)
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final barSettings = dark ? _tabBarSettingsDark : _tabBarSettingsLight;
    final barIndicator = dark
        ? const Color(0x30ffffff)
        : const Color(0x268e8e93);
    final appBar = GlassAppBar(
      title: Text(title),
      largeTitleController: controller,
      padding: layout.isCompact
          ? const EdgeInsets.symmetric(horizontal: 8)
          : EdgeInsets.only(
              left: math.max(8.0, hPad.left - 8),
              right: math.max(8.0, hPad.right - 8),
            ),
      actions: [
        AnimatedBuilder(
          animation: controller,
          child: _accountActions(),
          builder: (context, child) {
            final progress = controller.collapseProgress;
            if (progress <= 0) return const SizedBox.shrink();
            return IgnorePointer(
              ignoring: progress < .5,
              child: Opacity(opacity: progress, child: child),
            );
          },
        ),
      ],
    );
    final animatedBody = AnimatedBuilder(
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
    );
    return GlassScaffold(
      bottomEdgeFade: !useRail,
      bottomEdgeFadeExtent: -14.0,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: useRail
          ? Padding(padding: EdgeInsets.only(left: railWidth), child: appBar)
          : appBar,
      bodyOverlays: useRail
          ? [
              Positioned(
                left: safe.left + 16,
                top: safe.top + 16,
                bottom: safe.bottom + 16,
                child: Center(
                  child: GlassNavigationRail(
                    key: const ValueKey('main-navigation-rail'),
                    width: layout.railCapsuleWidth(context),
                    settings: barSettings,
                    selectedIndex: store.tab,
                    onSelected: _selectTab,
                    selectedColor: brandBlue,
                    indicatorColor: barIndicator,
                    destinations: [
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.square_stack_fill,
                        label: store.t('explore'),
                      ),
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.calendar,
                        label: store.t('schedule'),
                      ),
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.rectangle_stack_fill,
                        label: store.t('library'),
                      ),
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.clock,
                        label: store.t('watchHistory'),
                      ),
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.search,
                        label: store.t('search'),
                      ),
                    ],
                  ),
                ),
              ),
            ]
          : null,
      bottomBar: useRail
          ? null
          : GlassTabBar.searchable(
              key: const ValueKey('main-tab-bar'),
              settings: barSettings,
              selectedIndex: _lastBrowseTab.clamp(0, 3),
              isSearchActive: store.tab == 4,
              onTabSelected: _selectTab,
              horizontalPadding: layout.bottomTabBarHorizontalPadding(),
              verticalPadding: 12,
              selectedIconColor: brandBlue,
              selectedLabelColor: brandBlue,
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
              indicatorColor: barIndicator,
              searchConfig: GlassSearchBarConfig(
                controller: _search,
                hintText: store.t('searchPlaceholder'),
                hintStyle: TextStyle(color: secondary(context), fontSize: 16),
                textColor: Theme.of(context).colorScheme.onSurface,
                clearButtonSemanticLabel: store.t('clearSearch'),
                cancelButtonSemanticLabel: store.t('cancel'),
                textInputAction: TextInputAction.search,
                showsCancelButton: true,
                onSearchToggle: (active) {
                  if (active) {
                    store.selectTab(4);
                  } else {
                    FocusManager.instance.primaryFocus?.unfocus();
                    store.selectTab(_lastBrowseTab);
                  }
                },
                onChanged: (value) => store.query = value,
                onSubmitted: (_) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  store.search();
                },
                onCancelTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  store.query = '';
                  store.selectTab(_lastBrowseTab);
                },
              ),
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
              ],
            ),
      body: useRail
          ? Padding(
              padding: EdgeInsets.only(left: railWidth),
              child: ClipRect(child: animatedBody),
            )
          : animatedBody,
    );
  }

  @override
  void dispose() {
    store.setPortalHostActive(false);
    store.updates.cancelCheck();
    _playbackEnvironment.pictureInPicture.removeListener(_syncPlaybackActivity);
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
    _librarySearch.dispose();
    for (final title in _titles) {
      title.dispose();
    }
    super.dispose();
  }
}
