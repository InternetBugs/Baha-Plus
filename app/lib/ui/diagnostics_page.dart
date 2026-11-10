import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/app_store.dart';
import 'chrome.dart';

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

  Future<void> _message(String key) => showCupertinoDialog<void>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(store.t('diagnosticsTitle')),
      content: Text(store.t(key)),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialog),
          child: Text(store.t('close')),
        ),
      ],
    ),
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
        builder: (context) => GlassScaffold(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
          appBar: GlassAppBar(
            title: Text(store.t('diagnosticsPreview')),
            leading: GlassIconButton(
              semanticLabel: store.t('close'),
              icon: const Icon(CupertinoIcons.back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: lines.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SelectableText(
                lines[index],
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }, 'diagnosticsStorageFailed');

  Future<void> _clear() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(store.t('diagnosticsClear')),
        content: Text(store.t('diagnosticsClearConfirm')),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(store.t('close')),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(store.t('diagnosticsClear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(store.diagnostics.clear, 'diagnosticsStorageFailed');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.diagnostics,
    builder: (context, _) {
      final diagnostics = store.diagnostics;
      return GlassScaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
        appBar: GlassAppBar(
          title: Text(store.t('diagnosticsTitle')),
          leading: GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (_busy) const CupertinoActivityIndicator(),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      store.t('diagnosticsInstructions'),
                      style: TextStyle(color: secondary(context), height: 1.7),
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
                    const SizedBox(height: 16),
                    _action(
                      diagnostics.enabled
                          ? 'diagnosticsStop'
                          : 'diagnosticsStart',
                      _toggle,
                      enabled: !_busy,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Builder(
              builder: (button) => _action(
                'diagnosticsShare',
                () => _share(button),
                enabled: !_busy && diagnostics.hasLogs,
              ),
            ),
            const SizedBox(height: 12),
            _action(
              'diagnosticsPreview',
              _preview,
              enabled: !_busy && diagnostics.hasLogs,
            ),
            const SizedBox(height: 12),
            _action(
              'diagnosticsCopy',
              _copy,
              enabled: !_busy && diagnostics.hasLogs,
            ),
            const SizedBox(height: 20),
            Text(
              store.t('diagnosticsPrivacy'),
              style: TextStyle(
                color: secondary(context),
                fontSize: 12,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 20),
            _action(
              'diagnosticsFeedback',
              () => _run(() async {
                final opened = await launchUrl(
                  Uri.parse(
                    'https://github.com/InternetBugs/Baha-Plus/issues/new',
                  ),
                  mode: LaunchMode.externalApplication,
                );
                if (!opened) throw StateError('Could not open feedback');
              }, 'diagnosticsFeedbackFailed'),
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            Text(
              store.t('diagnosticsFeedbackHint'),
              style: TextStyle(
                color: secondary(context),
                fontSize: 12,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 20),
            CupertinoButton(
              onPressed: !_busy && diagnostics.hasLogs ? _clear : null,
              child: Text(store.t('diagnosticsClear')),
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
              shape: const LiquidRoundedRectangle(borderRadius: 22),
              height: 48,
              onTap: action,
              canRequestFocus: enabled,
              excludeFromSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(store.t(key), style: const TextStyle(fontSize: 14)),
              ),
            ),
          ),
        ),
      );
}
