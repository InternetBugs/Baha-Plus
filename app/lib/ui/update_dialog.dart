import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'glass_alert.dart';

export 'glass_alert.dart'
    show
        GlassAlert,
        GlassAlertAction,
        GlassAlertActionButton,
        glassAlertSettings,
        resolveGlassAlertQuality,
        showGlassAlertDialog,
        showGlassAlertRoute,
        showGlassConfirmDialog,
        showGlassMessageDialog;

/// Optical settings calibrated for an iOS 26 floating Liquid Glass update alert.
LiquidGlassSettings glassUpdateAlertSettings(BuildContext context) =>
    glassAlertSettings(context);

/// Presents the update-available alert using iOS 26 Liquid Glass geometry,
/// left-aligned typography, an inset scrollable release-notes well, and
/// concentric capsule action pills.
Future<bool?> showUpdateAvailableDialog({
  required BuildContext context,
  required String title,
  required String versionDetails,
  required String notesTitle,
  required String notesBody,
  required bool hasNotes,
  required String laterLabel,
  required String downloadLabel,
}) => showGlassAlertRoute<bool>(
  context: context,
  builder: (dialogContext) => GlassUpdateAlert(
    key: const ValueKey('update-available-dialog'),
    title: title,
    versionDetails: versionDetails,
    notesTitle: notesTitle,
    notesBody: notesBody,
    hasNotes: hasNotes,
    actions: [
      GlassAlertAction(
        key: const ValueKey('update-later-action'),
        label: laterLabel,
        onPressed: () => Navigator.pop(dialogContext, false),
      ),
      GlassAlertAction(
        key: const ValueKey('update-download-action'),
        label: downloadLabel,
        isPrimary: true,
        autofocus: true,
        onPressed: () => Navigator.pop(dialogContext, true),
      ),
    ],
  ),
);

/// Presents a compact iOS 26 Liquid Glass status or error alert for update
/// checks and download launch failures.
Future<void> showUpdateMessageDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String closeLabel,
}) => showGlassAlertRoute<void>(
  context: context,
  builder: (dialogContext) => GlassUpdateAlert(
    key: const ValueKey('update-message-dialog'),
    title: title,
    message: message,
    compactWidth: true,
    actions: [
      GlassAlertAction(
        key: const ValueKey('update-close-action'),
        label: closeLabel,
        autofocus: true,
        onPressed: () => Navigator.pop(dialogContext),
      ),
    ],
  ),
);

/// Floating iOS 26 Liquid Glass alert container tailored for update prompts
/// and update status messages.
class GlassUpdateAlert extends StatelessWidget {
  const GlassUpdateAlert({
    required this.title,
    required this.actions,
    this.versionDetails,
    this.message,
    this.notesTitle,
    this.notesBody,
    this.hasNotes = true,
    this.compactWidth = false,
    super.key,
  });

  final String title;
  final String? versionDetails;
  final String? message;
  final String? notesTitle;
  final String? notesBody;
  final bool hasNotes;
  final bool compactWidth;
  final List<GlassAlertAction> actions;

  @override
  Widget build(BuildContext context) => GlassAlert(
    surfaceKey: const ValueKey('update-dialog-glass-surface'),
    title: title,
    versionDetails: versionDetails,
    message: message,
    notesTitle: notesTitle,
    notesBody: notesBody,
    hasNotes: hasNotes,
    compactWidth: compactWidth,
    actions: actions,
  );
}
