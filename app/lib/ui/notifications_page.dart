import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_widgets.dart';

class NotificationBell extends StatelessWidget {
  const NotificationBell({required this.store, required this.onTap, super.key});
  final AppStore store;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      GlassIconButton(
        key: const ValueKey('notifications-button'),
        semanticLabel: store.t('notifications'),
        icon: const Icon(CupertinoIcons.bell),
        onPressed: onTap,
      ),
      if (store.unreadNotifications > 0)
        Positioned(
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: brandBlue,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Text(
                  store.unreadNotifications > 99
                      ? '99+'
                      : '${store.unreadNotifications}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({required this.store, super.key});
  final AppStore store;
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage>
    with WidgetsBindingObserver {
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final items = store.notifications
          .where((item) => !_unreadOnly || !store.notificationRead(item))
          .toList();
      return GlassScaffold(
        key: const ValueKey('notifications-page'),
        extendBody: false,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: GlassAppBar(
          leading: GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            GlassIconButton(
              semanticLabel: store.t('markAllRead'),
              icon: const Icon(CupertinoIcons.checkmark_alt_circle),
              onPressed: store.unreadNotifications == 0
                  ? null
                  : store.markNotificationsRead,
            ),
            GlassIconButton(
              semanticLabel: store.t('refresh'),
              icon: const Icon(CupertinoIcons.arrow_clockwise),
              onPressed: store.notificationsLoading
                  ? null
                  : store.refreshNotifications,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    store.t('notifications'),
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      for (final unread in [false, true])
                        GlassButton.custom(
                          shape: const LiquidRoundedRectangle(borderRadius: 20),
                          height: 38,
                          width: 110,
                          onTap: () => setState(() => _unreadOnly = unread),
                          child: Text(
                            unread
                                ? '${store.t('unread')} ${store.unreadNotifications}'
                                : store.t('all'),
                            style: TextStyle(
                              fontSize: 12,
                              color: _unreadOnly == unread
                                  ? brandBlue
                                  : secondary(context),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: store.notificationsLoading && store.notifications.isEmpty
                  ? const Center(child: CupertinoActivityIndicator())
                  : RefreshIndicator(
                      onRefresh: store.refreshNotifications,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          20,
                          0,
                          20,
                          MediaQuery.paddingOf(context).bottom + 24,
                        ),
                        children: [
                          if (store.notificationsError != null)
                            CommunityEmpty(
                              icon: store.notificationsError == 'login'
                                  ? CupertinoIcons.person_crop_circle
                                  : CupertinoIcons.wifi_exclamationmark,
                              title: communityError(
                                store,
                                store.notificationsError,
                              ),
                              action: CupertinoButton(
                                onPressed: store.notificationsError == 'login'
                                    ? () {
                                        Navigator.pop(context);
                                        store.connectAccount();
                                      }
                                    : store.refreshNotifications,
                                child: Text(
                                  store.t(
                                    store.notificationsError == 'login'
                                        ? 'connectAccount'
                                        : 'retry',
                                  ),
                                ),
                              ),
                            ),
                          if (items.isEmpty && store.notificationsError == null)
                            CommunityEmpty(
                              icon: CupertinoIcons.bell,
                              title: store.t(
                                _unreadOnly
                                    ? 'noUnreadNotifications'
                                    : 'noNotifications',
                              ),
                              message: store.t('noNotificationsHint'),
                            ),
                          for (final item in items)
                            Semantics(
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
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(18),
                                        child: SizedBox(
                                          width: 60,
                                          height: 60,
                                          child: Artwork(item.cover),
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
                                                fontWeight:
                                                    store.notificationRead(item)
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
                                          store.notificationRead(item)
                                              ? CupertinoIcons.chevron_right
                                              : CupertinoIcons.circle_fill,
                                          size: store.notificationRead(item)
                                              ? 13
                                              : 7,
                                          color: store.notificationRead(item)
                                              ? secondary(context)
                                              : brandBlue,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refresh?.cancel();
    super.dispose();
  }
}
