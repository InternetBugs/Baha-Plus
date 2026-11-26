import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'diagnostics_page.dart';
import 'glass_alert.dart';
import 'glass_settings_menu.dart';

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

  Future<void> _refreshProfile(BuildContext context) async {
    final success = await store.refreshAccountProfile(force: true);
    if (success || !context.mounted || !store.hasAccount) return;
    await showGlassMessageDialog(
      context: context,
      title: store.t('refreshProfile'),
      message: store.t('accountSyncError'),
      closeLabel: store.t('close'),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final success = await store.logoutAccount();
    if (success || !context.mounted) return;
    await showGlassMessageDialog(
      context: context,
      title: store.t('logout'),
      message: store.t('logoutFailed'),
      closeLabel: store.t('close'),
    );
  }

  Future<void> _setSkipAgeConfirmation(BuildContext context, bool value) async {
    if (value) {
      final confirmed = await showGlassConfirmDialog(
        context: context,
        title: store.t('skipAgeConfirmationTitle'),
        message: store.t('skipAgeConfirmationWarning'),
        cancelLabel: store.t('cancel'),
        confirmLabel: store.t('skipAgeConfirmationEnable'),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await store.setSkipAgeConfirmation(value);
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
          store.t('me'),
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final safe = MediaQuery.paddingOf(context);
          final side = 20.0 + math.max(0.0, (constraints.maxWidth - 640.0) / 2);
          return ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: EdgeInsets.fromLTRB(
              side,
              12,
              side,
              safe.bottom + 40,
            ),
            children: [
          GlassSettingsGroup(
            children: [
              GlassSettingsHighlight(
                onTap: store.hasAccount || store.loggingOut
                    ? null
                    : () => _connect(context),
                semanticButton: !store.hasAccount,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 26,
                  ),
                  child: Row(
                    children: [
                      AccountPortrait(
                        profile: store.accountProfile,
                        cacheVersion: store.accountPortraitVersion,
                      ),
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
              if (store.hasAccount) ...[
                GlassSettingsRow(
                  title: store.t('refreshProfile'),
                  icon: CupertinoIcons.arrow_clockwise,
                  onTap: store.profileRefreshing || store.loggingOut
                      ? null
                      : () => _refreshProfile(context),
                  busy: store.profileRefreshing,
                ),
                GlassSettingsRow(
                  title: store.t('logout'),
                  icon: CupertinoIcons.square_arrow_right,
                  onTap: store.loggingOut ? null : () => _logout(context),
                  busy: store.loggingOut,
                ),
              ],
            ],
          ),
          const SizedBox(height: 22),
          GlassSettingsGroup(
            children: [
              if (onNotifications != null)
                GlassSettingsRow(
                  title: store.t('notifications'),
                  icon: CupertinoIcons.bell,
                  onTap: () {
                    Navigator.pop(context);
                    onNotifications!();
                  },
                  value: store.unreadNotifications > 0
                      ? '${store.unreadNotifications}'
                      : null,
                ),
              GlassSettingsRow(
                title: store.t('favorites'),
                icon: CupertinoIcons.bookmark,
                onTap: () {
                  Navigator.pop(context);
                  store.selectTab(2, filter: 'favorites');
                },
                value: store.accountSynced ? '${store.favorites.length}' : null,
              ),
              if (store.verificationRequired)
                GlassSettingsRow(
                  title: store.t('officialVerification'),
                  icon: CupertinoIcons.checkmark_shield,
                  onTap: () {
                    Navigator.pop(context);
                    store.openOfficial();
                  },
                ),
            ],
          ),
          const SizedBox(height: 28),
          _sectionLabel(context, store.t('preferences')),
          const SizedBox(height: 8),
          GlassSettingsGroup(
            children: [
              GlassSettingsPickerRow<String>(
                key: const ValueKey('account-language-picker'),
                title: store.t('language'),
                icon: CupertinoIcons.textformat,
                valueLabel: store.simplified ? '简体中文' : '繁體中文',
                selectedValue: store.language,
                options: const [
                  GlassSettingsOption(
                    key: ValueKey('language-option-zh-Hans'),
                    value: 'zh-Hans',
                    label: '简体中文',
                  ),
                  GlassSettingsOption(
                    key: ValueKey('language-option-zh-Hant'),
                    value: 'zh-Hant',
                    label: '繁體中文',
                  ),
                ],
                onSelected: store.setLanguage,
              ),
              GlassSettingsPickerRow<String>(
                key: const ValueKey('account-appearance-picker'),
                title: store.t('appearance'),
                icon: CupertinoIcons.circle_lefthalf_fill,
                valueLabel: store.t(store.appearance),
                selectedValue: store.appearance,
                options: [
                  for (final value in ['system', 'light', 'dark'])
                    GlassSettingsOption(
                      key: ValueKey('appearance-option-$value'),
                      value: value,
                      label: store.t(value),
                    ),
                ],
                onSelected: store.setAppearance,
              ),
              GlassSettingsPickerRow<String>(
                key: const ValueKey('account-glass-style-picker'),
                title: store.t('glassStyle'),
                icon: CupertinoIcons.drop,
                valueLabel: switch (store.glassStyle) {
                  'performance' => store.t('glassStylePerformance'),
                  'premium' => store.t('glassStylePremium'),
                  _ => store.t('glassStyleStandard'),
                },
                selectedValue: store.glassStyle,
                options: [
                  for (final MapEntry(key: value, value: labelKey) in {
                    'performance': 'glassStylePerformance',
                    'standard': 'glassStyleStandard',
                    'premium': 'glassStylePremium',
                  }.entries)
                    GlassSettingsOption(
                      key: ValueKey('glass-style-option-$value'),
                      value: value,
                      label: store.t(labelKey),
                    ),
                ],
                onSelected: store.setGlassStyle,
              ),
            ],
          ),
          const SizedBox(height: 28),
          _sectionLabel(context, store.t('playback')),
          const SizedBox(height: 8),
          GlassSettingsGroup(
            children: [
              GlassSettingsSwitchRow(
                key: const ValueKey('account-skip-age-confirmation-switch'),
                title: store.t('skipAgeConfirmation'),
                icon: CupertinoIcons.exclamationmark_shield,
                value: store.skipAgeConfirmation,
                onChanged: (value) => _setSkipAgeConfirmation(context, value),
              ),
              GlassSettingsSwitchRow(
                key: const ValueKey('account-skip-op-switch'),
                title: store.t('skipOpLongPress'),
                icon: CupertinoIcons.forward_end,
                value: store.skipOpLongPress,
                onChanged: store.setSkipOpLongPress,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _sectionFooter(context, store.t('skipOpLongPressHint')),
          const SizedBox(height: 28),
          _sectionLabel(context, store.t('about')),
          const SizedBox(height: 8),
          GlassSettingsGroup(
            children: [
              GlassSettingsRow(
                title: 'Baha Plus',
                icon: CupertinoIcons.info_circle,
                onTap: store.updates.checking ? null : onCheckUpdates,
                value: store.updates.currentVersion ?? '—',
              ),
              GlassSettingsRow(
                title: store.t(
                  store.updates.checking ? 'checkingUpdates' : 'checkUpdates',
                ),
                icon: CupertinoIcons.arrow_clockwise,
                onTap: store.updates.checking ? null : onCheckUpdates,
                busy: store.updates.checking,
              ),
              GlassSettingsRow(
                title: store.t('diagnosticsTitle'),
                icon: CupertinoIcons.doc_text,
                onTap: () => Navigator.of(context).push<void>(
                  CupertinoPageRoute(
                    builder: (_) => DiagnosticsPage(store: store),
                  ),
                ),
              ),
            ],
          ),
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
      );
        },
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

  Widget _sectionFooter(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(
      text,
      style: TextStyle(color: secondary(context), fontSize: 12, height: 1.6),
    ),
  );
}
