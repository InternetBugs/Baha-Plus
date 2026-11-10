import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'diagnostics_page.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({
    required this.store,
    required this.onCheckUpdates,
    this.onNotifications,
    super.key,
  });
  final AppStore store;
  final VoidCallback onCheckUpdates;
  final VoidCallback? onNotifications;

  void _connect(BuildContext context) {
    Navigator.pop(context);
    store.connectAccount();
  }

  Future<void> _logout(BuildContext context) async {
    final success = await store.logoutAccount();
    if (success || !context.mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(store.t('logout')),
        content: Text(store.t('logoutFailed')),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog),
            child: Text(store.t('close')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, store.updates]),
    builder: (context, child) => GlassScaffold(
      extendBody: false,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      statusBarStyle: GlassStatusBarStyle.auto,
      appBar: GlassAppBar(
        centerTitle: false,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        title: Text(
          store.t('officialAccount'),
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
        ),
        actions: [
          GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        children: [
          _group(context, [
            GestureDetector(
              onTap: store.hasAccount || store.loggingOut
                  ? null
                  : () => _connect(context),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 26,
                ),
                child: Row(
                  children: [
                    AccountPortrait(profile: store.accountProfile),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            store.accountProfile?.displayName ??
                                store.t('localProfile'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            store.accountProfile != null
                                ? '@${store.accountProfile!.id}'
                                : store.t(
                                    store.accountSynced
                                        ? 'accountConnected'
                                        : 'connectAccount',
                                  ),
                            style: TextStyle(
                              color: secondary(context),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!store.hasAccount)
                      Icon(
                        CupertinoIcons.chevron_right,
                        color: secondary(context),
                        size: 14,
                      ),
                  ],
                ),
              ),
            ),
            if (store.hasAccount)
              _row(
                context,
                store.t('logout'),
                CupertinoIcons.square_arrow_right,
                store.loggingOut ? null : () => _logout(context),
                busy: store.loggingOut,
              ),
          ]),
          const SizedBox(height: 22),
          _group(context, [
            if (onNotifications != null)
              _row(
                context,
                store.t('notifications'),
                CupertinoIcons.bell,
                () {
                  Navigator.pop(context);
                  onNotifications!();
                },
                value: store.unreadNotifications > 0
                    ? '${store.unreadNotifications}'
                    : null,
              ),
            _row(context, store.t('favorites'), CupertinoIcons.bookmark, () {
              Navigator.pop(context);
              store.selectTab(2, filter: 'favorites');
            }, value: store.accountSynced ? '${store.favorites.length}' : null),
            if (store.verificationRequired)
              _row(
                context,
                store.t('officialVerification'),
                CupertinoIcons.checkmark_shield,
                () {
                  Navigator.pop(context);
                  store.openOfficial();
                },
              ),
          ]),
          const SizedBox(height: 28),
          _sectionLabel(context, store.t('preferences')),
          const SizedBox(height: 8),
          _group(context, [
            _row(
              context,
              store.t('language'),
              CupertinoIcons.textformat,
              () => _language(context),
              value: store.simplified ? '简体中文' : '繁體中文',
              picker: true,
            ),
            _row(
              context,
              store.t('appearance'),
              CupertinoIcons.circle_lefthalf_fill,
              () => _appearance(context),
              value: store.t(store.appearance),
              picker: true,
            ),
          ]),
          const SizedBox(height: 28),
          _sectionLabel(context, store.t('about')),
          const SizedBox(height: 8),
          _group(context, [
            _row(
              context,
              'Baha Plus',
              CupertinoIcons.info_circle,
              store.updates.checking ? null : onCheckUpdates,
              value: store.updates.currentVersion ?? '—',
            ),
            _row(
              context,
              store.t(
                store.updates.checking ? 'checkingUpdates' : 'checkUpdates',
              ),
              CupertinoIcons.arrow_clockwise,
              store.updates.checking ? null : onCheckUpdates,
              busy: store.updates.checking,
            ),
            _row(
              context,
              store.t('diagnosticsTitle'),
              CupertinoIcons.doc_text,
              () => Navigator.of(context).push<void>(
                CupertinoPageRoute(
                  builder: (_) => DiagnosticsPage(store: store),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              store.t('aboutText'),
              style: TextStyle(
                color: secondary(context),
                fontSize: 11,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sectionLabel(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(left: 16),
    child: Text(
      title,
      style: TextStyle(color: secondary(context), fontSize: 12),
    ),
  );

  Widget _group(BuildContext context, List<Widget> children) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(26),
    ),
    child: Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0)
            Padding(
              padding: const EdgeInsets.only(left: 52),
              child: Divider(
                height: 1,
                color: secondary(context).withValues(alpha: .12),
              ),
            ),
          children[index],
        ],
      ],
    ),
  );

  Widget _row(
    BuildContext context,
    String title,
    IconData icon,
    VoidCallback? action, {
    String? value,
    bool picker = false,
    bool busy = false,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: action,
    child: Semantics(
      button: true,
      enabled: action != null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 19),
        child: Row(
          children: [
            Icon(icon, color: brandBlue, size: 22),
            const SizedBox(width: 14),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 14))),
            if (value != null) ...[
              Text(
                value,
                style: TextStyle(
                  color: picker ? brandBlue : secondary(context),
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (busy)
              const CupertinoActivityIndicator(radius: 7)
            else
              Icon(
                picker
                    ? CupertinoIcons.chevron_up_chevron_down
                    : CupertinoIcons.chevron_right,
                color: picker ? brandBlue : secondary(context),
                size: 13,
              ),
          ],
        ),
      ),
    ),
  );

  void _language(BuildContext context) => showCupertinoModalPopup<void>(
    context: context,
    builder: (sheet) => CupertinoActionSheet(
      title: Text(store.t('language')),
      actions: [
        for (final entry in {'zh-Hans': '简体中文', 'zh-Hant': '繁體中文'}.entries)
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              store.setLanguage(entry.key);
            },
            child: Text(entry.value),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(sheet),
        child: Text(store.t('close')),
      ),
    ),
  );

  void _appearance(BuildContext context) => showCupertinoModalPopup<void>(
    context: context,
    builder: (sheet) => CupertinoActionSheet(
      title: Text(store.t('appearance')),
      actions: [
        for (final value in ['system', 'light', 'dark'])
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              store.setAppearance(value);
            },
            child: Text(store.t(value)),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(sheet),
        child: Text(store.t('close')),
      ),
    ),
  );
}
