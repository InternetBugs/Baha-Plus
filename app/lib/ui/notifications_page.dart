import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_widgets.dart';
import 'layout.dart';

class NotificationBell extends StatelessWidget {
  const NotificationBell({required this.store, required this.onTap, super.key});
  final AppStore store;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = GlassIconButton(
      key: const ValueKey('notifications-button'),
      semanticLabel: store.t('notifications'),
      icon: const Icon(CupertinoIcons.bell),
      onPressed: onTap,
    );
    if (store.unreadNotifications <= 0) return button;
    return GlassBadge(
      count: store.unreadNotifications,
      backgroundColor: CupertinoColors.systemRed,
      child: button,
    );
  }
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({required this.store, super.key});
  final AppStore store;
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage>
    with WidgetsBindingObserver {
  final _title = GlassLargeTitleController();
  AppStore get store => widget.store;
  bool _unreadOnly = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(store.refreshNotifications());
    _refresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true) {
        unawaited(store.refreshNotifications());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(store.refreshNotifications());
    }
  }

  @override
  Widget build(BuildContext context) {
    final hPad = AppLayout.of(context).pageHorizontalPadding(maxWidth: 780);
    final safe = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = store.notifications
            .where((item) => !_unreadOnly || !store.notificationRead(item))
            .toList();
        final hasError = store.notificationsError != null;
        final isEmpty = items.isEmpty && store.notificationsError == null;
        final prefix = (hasError ? 1 : 0) + (isEmpty ? 1 : 0);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final controlHeight =
            (MediaQuery.textScalerOf(context).scale(13) + 22).clamp(38.0, 56.0);
        return GlassScaffold(
          key: const ValueKey('notifications-page'),
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          statusBarStyle: GlassStatusBarStyle.auto,
          appBar: GlassAppBar(
            title: Text(store.t('notifications')),
            largeTitleController: _title,
            leading: GlassIconButton(
              semanticLabel: store.t('close'),
              icon: const Icon(CupertinoIcons.xmark),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              GlassButtonGroup.icons(
                key: const ValueKey('notifications-actions-capsule'),
                iconSize: 20,
                itemPadding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                items: [
                  GlassButtonGroupItem(
                    icon: const Icon(CupertinoIcons.checkmark_alt_circle),
                    label: store.t('markAllRead'),
                    enabled: store.unreadNotifications > 0,
                    onTap: store.markNotificationsRead,
                  ),
                  GlassButtonGroupItem(
                    icon: const Icon(CupertinoIcons.arrow_clockwise),
                    label: store.t('refresh'),
                    enabled: !store.notificationsLoading,
                    onTap: store.refreshNotifications,
                  ),
                ],
              ),
            ],
          ),
          body: CustomScrollView(
            controller: _title.scrollController,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              CupertinoSliverRefreshControl(
                onRefresh: store.refreshNotifications,
              ),
              SliverToBoxAdapter(child: SizedBox(height: safe.top + 44)),
              GlassLargeTitle(
                text: store.t('notifications'),
                controller: _title,
                padding: EdgeInsets.fromLTRB(hPad.left, 4, hPad.right, 14),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hPad.left, 0, hPad.right, 16),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: GlassSegmentedControl(
                        key: const ValueKey('notifications-filter-control'),
                        height: controlHeight,
                        borderRadius: controlHeight / 2,
                        backgroundColor: dark
                            ? const Color(0x1affffff)
                            : const Color(0x14000000),
                        indicatorColor: dark
                            ? const Color(0x30ffffff)
                            : Colors.white,
                        selectedTextStyle: TextStyle(
                          fontFamily: 'BahaSans',
                          fontFamilyFallback: const ['BahaSansSC'],
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: dark ? Colors.white : brandBlue,
                        ),
                        unselectedTextStyle: TextStyle(
                          fontFamily: 'BahaSans',
                          fontFamilyFallback: const ['BahaSansSC'],
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: secondary(context),
                        ),
                        selectedIndex: _unreadOnly ? 1 : 0,
                        segments: [
                          GlassSegment(label: store.t('all')),
                          GlassSegment(
                            label:
                                '${store.t('unread')} ${store.unreadNotifications}',
                          ),
                        ],
                        onSegmentSelected: (index) =>
                            setState(() => _unreadOnly = index == 1),
                      ),
                    ),
                  ),
                ),
              ),
              if (store.notificationsLoading && store.notifications.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    hPad.left,
                    0,
                    hPad.right,
                    safe.bottom + 24,
                  ),
                  sliver: SliverList.builder(
                    itemCount: prefix + items.length,
                    itemBuilder: (context, index) {
                      var cursor = index;
                      if (hasError) {
                        if (cursor == 0) {
                          return CommunityEmpty(
                            icon: store.notificationsError == 'login'
                                ? CupertinoIcons.person_crop_circle
                                : CupertinoIcons.wifi_exclamationmark,
                            title: communityError(
                              store,
                              store.notificationsError,
                            ),
                            action: GlassActionPill(
                              label: store.t(
                                store.notificationsError == 'login'
                                    ? 'connectAccount'
                                    : 'retry',
                              ),
                              onTap: store.notificationsError == 'login'
                                  ? () {
                                      Navigator.pop(context);
                                      store.connectAccount();
                                    }
                                  : store.refreshNotifications,
                            ),
                          );
                        }
                        cursor--;
                      }
                      if (isEmpty) {
                        if (cursor == 0) {
                          return CommunityEmpty(
                            icon: CupertinoIcons.bell,
                            title: store.t(
                              _unreadOnly
                                  ? 'noUnreadNotifications'
                                  : 'noNotifications',
                            ),
                            message: store.t('noNotificationsHint'),
                          );
                        }
                        cursor--;
                      }
                      final item = items[cursor];
                      final read = store.notificationRead(item);
                      return Semantics(
                        button: true,
                        label: '${item.title}, ${item.time}',
                        child: GestureDetector(
                          key: ValueKey('notification-${item.videoId}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(store.openNotification(item));
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRSuperellipse(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Artwork(
                                    item.cover,
                                    width: 60,
                                    height: 60,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.5,
                                          fontWeight: read
                                              ? FontWeight.w400
                                              : FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 7),
                                      Text(
                                        item.time,
                                        style: TextStyle(
                                          color: secondary(context),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Icon(
                                    read
                                        ? CupertinoIcons.chevron_right
                                        : CupertinoIcons.circle_fill,
                                    size: read ? 13 : 7,
                                    color: read
                                        ? secondary(context)
                                        : brandBlue,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
    WidgetsBinding.instance.removeObserver(this);
    _refresh?.cancel();
    _title.dispose();
    super.dispose();
  }
}
