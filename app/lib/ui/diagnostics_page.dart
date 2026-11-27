import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'glass_alert.dart';
import 'glass_settings_menu.dart';
import 'layout.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({required this.store, super.key});
  final AppStore store;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  AppStore get store => widget.store;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await store.diagnostics.initialize();
    } catch (_) {
      // Actions can retry initialization and present an actionable error.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _message(String key) => showGlassMessageDialog(
    context: context,
    title: store.t('diagnosticsTitle'),
    message: store.t(key),
    closeLabel: store.t('close'),
  );

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) await _message(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File> _report() =>
      store.diagnostics.export(context: store.diagnosticContext);

  Future<void> _toggle() => _run(() async {
    if (store.diagnostics.enabled) {
      await store.diagnostics.stop();
    } else {
      await store.diagnostics.start();
      store.diagnostics.record('app.snapshot', store.diagnosticContext);
    }
  }, 'diagnosticsStorageFailed');

  Future<void> _share(BuildContext buttonContext) async {
    // Capture a valid popover anchor before the export's asynchronous work.
    final box = buttonContext.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    await _run(() async {
      final file = await _report();
      if (!mounted) return;
      await store.diagnostics.share(file, origin);
    }, 'diagnosticsShareFailed');
  }

  Future<void> _copy() => _run(() async {
    final file = await _report();
    await Clipboard.setData(ClipboardData(text: await file.readAsString()));
    if (mounted) await _message('diagnosticsCopied');
  }, 'diagnosticsCopyFailed');

  Future<void> _preview() => _run(() async {
    final report = await (await _report()).readAsString();
    if (!mounted) return;
    final lines = report.split('\n');
    await Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (context) {
          final previewLayout = AppLayout.of(context);
          final previewPad = previewLayout.pageHorizontalPadding(maxWidth: 920);
          return GlassScaffold(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerLowest,
            statusBarStyle: GlassStatusBarStyle.auto,
            appBar: GlassAppBar(
              title: Text(store.t('diagnosticsPreview')),
              padding: previewLayout.isCompact
                  ? const EdgeInsets.symmetric(horizontal: 8)
                  : EdgeInsets.only(
                      left: math.max(8.0, previewPad.left - 8),
                      right: math.max(8.0, previewPad.right - 8),
                    ),
              leading: GlassIconButton(
                semanticLabel: store.t('back'),
                icon: const Icon(CupertinoIcons.chevron_back),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            body: Builder(
              builder: (context) {
                final safe = MediaQuery.paddingOf(context);
                return ListView.builder(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    previewPad.left,
                    safe.top + 64,
                    previewPad.right,
                    safe.bottom + 20,
                  ),
                  itemCount: lines.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText(
                      lines[index],
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }, 'diagnosticsStorageFailed');

  Future<void> _clear() async {
    final confirmed = await showGlassConfirmDialog(
      context: context,
      title: store.t('diagnosticsClear'),
      message: store.t('diagnosticsClearConfirm'),
      cancelLabel: store.t('close'),
      confirmLabel: store.t('diagnosticsClear'),
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await _run(store.diagnostics.clear, 'diagnosticsStorageFailed');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.diagnostics,
    builder: (context, _) {
      final diagnostics = store.diagnostics;
      final safe = MediaQuery.paddingOf(context);
      final layout = AppLayout.of(context);
      final hPad = layout.pageHorizontalPadding(maxWidth: 680);
      final canExport = !_busy && diagnostics.hasLogs;
      return GlassScaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
        statusBarStyle: GlassStatusBarStyle.auto,
        topEdgeFadeExtent: 44,
        appBar: GlassAppBar(
          title: Text(store.t('diagnosticsTitle')),
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
        body: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            hPad.left,
            safe.top + 64,
            hPad.right,
            safe.bottom + 40,
          ),
          children: [
            GlassSettingsGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            diagnostics.enabled
                                ? CupertinoIcons.circle_fill
                                : CupertinoIcons.doc_text,
                            color: brandBlue,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              store.t(
                                diagnostics.enabled
                                    ? 'diagnosticsRecording'
                                    : 'diagnosticsStopped',
                              ),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_busy) const CupertinoActivityIndicator(),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _action(
                        diagnostics.enabled
                            ? 'diagnosticsStop'
                            : 'diagnosticsStart',
                        _toggle,
                        enabled: !_busy,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        store.t('diagnosticsInstructions'),
                        style: TextStyle(
                          color: secondary(context),
                          height: 1.7,
                        ),
                      ),
                      if (diagnostics.writeFailed) ...[
                        const SizedBox(height: 12),
                        Text(
                          store.t('diagnosticsStorageFailed'),
                          style: const TextStyle(
                            color: CupertinoColors.systemRed,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            GlassSettingsGroup(
              children: [
                Opacity(
                  opacity: canExport ? 1 : .45,
                  child: Builder(
                    builder: (button) => GlassSettingsRow(
                      title: store.t('diagnosticsShare'),
                      icon: CupertinoIcons.share,
                      onTap: canExport ? () => _share(button) : null,
                    ),
                  ),
                ),
                Opacity(
                  opacity: canExport ? 1 : .45,
                  child: GlassSettingsRow(
                    title: store.t('diagnosticsPreview'),
                    icon: CupertinoIcons.eye,
                    onTap: canExport ? _preview : null,
                  ),
                ),
                Opacity(
                  opacity: canExport ? 1 : .45,
                  child: GlassSettingsRow(
                    title: store.t('diagnosticsCopy'),
                    icon: CupertinoIcons.doc_on_clipboard,
                    onTap: canExport ? _copy : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                store.t('diagnosticsPrivacy'),
                style: TextStyle(
                  color: secondary(context),
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 22),
            GlassSettingsGroup(
              children: [
                Opacity(
                  opacity: _busy ? .45 : 1,
                  child: GlassSettingsRow(
                    title: store.t('diagnosticsFeedback'),
                    icon: CupertinoIcons.exclamationmark_bubble,
                    onTap: _busy
                        ? null
                        : () => _run(() async {
                            final opened = await launchUrl(
                              Uri.parse(
                                'https://github.com/InternetBugs/Baha-Plus/issues/new',
                              ),
                              mode: LaunchMode.externalApplication,
                            );
                            if (!opened) {
                              throw StateError('Could not open feedback');
                            }
                          }, 'diagnosticsFeedbackFailed'),
                  ),
                ),
                Opacity(
                  opacity: canExport ? 1 : .45,
                  child: GlassSettingsHighlight(
                    onTap: canExport ? _clear : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.trash,
                            color: CupertinoColors.systemRed,
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              store.t('diagnosticsClear'),
                              style: const TextStyle(
                                fontSize: 15,
                                color: CupertinoColors.systemRed,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                store.t('diagnosticsFeedbackHint'),
                style: TextStyle(
                  color: secondary(context),
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _action(String key, VoidCallback action, {required bool enabled}) =>
      Semantics(
        button: true,
        enabled: enabled,
        label: store.t(key),
        onTap: enabled ? action : null,
        child: IgnorePointer(
          ignoring: !enabled,
          child: Opacity(
            opacity: enabled ? 1 : .45,
            child: GlassButton.custom(
              // Keep the glass above the opaque capture-status card.
              useOwnLayer: true,
              shape: const LiquidRoundedSuperellipse(borderRadius: 24),
              height: 48,
              onTap: action,
              canRequestFocus: enabled,
              excludeFromSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  store.t(key),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: brandBlue,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
