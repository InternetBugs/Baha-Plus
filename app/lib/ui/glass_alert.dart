import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'chrome.dart';
import 'release_notes_view.dart';

const _lightAlertShadow = [
  BoxShadow(color: Color(0x14000000), blurRadius: 1, spreadRadius: 0.5),
  BoxShadow(color: Color(0x1E000000), blurRadius: 36, offset: Offset(0, 14)),
  BoxShadow(color: Color(0x0C000000), blurRadius: 10, offset: Offset(0, 3)),
];

const _alertOpenCurve = Cubic(0.22, 1.08, 0.36, 1.0);

/// Optical settings calibrated for an iOS 26 floating Liquid Glass alert.
LiquidGlassSettings glassAlertSettings(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final effectiveQuality = resolveGlassAlertQuality(context);
  final useNativeFrost =
      ui.ImageFilter.isShaderFilterSupported &&
      effectiveQuality == GlassQuality.premium;

  if (useNativeFrost) {
    return dark
        ? LiquidGlassSettings.ios27Dark.copyWith(
            glassColor: const Color(0x2CFFFFFF),
            frost: 18,
            frostOpacity: .86,
            bodyShade: .34,
          )
        : LiquidGlassSettings.ios27Light.copyWith(
            glassColor: const Color(0x98F8F8FA),
            frost: 18,
            frostOpacity: .78,
            shadow: _lightAlertShadow,
          );
  }

  return dark
      ? const LiquidGlassSettings(
          glassColor: Color(0xAD222228),
          backerColor: Color(0x22101014),
          blur: 18,
          thickness: 22,
          saturation: 1.45,
          lightIntensity: .7,
          ambientStrength: .22,
          refractiveIndex: 1.2,
          chromaticAberration: 0,
          shadowElevation: 0,
        )
      : const LiquidGlassSettings(
          glassColor: Color(0xB8FAFAFD),
          blur: 18,
          thickness: 22,
          saturation: 1.75,
          lightIntensity: .9,
          ambientStrength: .35,
          refractiveIndex: 1.22,
          chromaticAberration: 0,
          shadow: _lightAlertShadow,
        );
}

/// Resolves the active glass quality tier from the app's glass theme or
/// adaptive scope so alerts follow the user's three-tier glass setting.
GlassQuality resolveGlassAlertQuality(BuildContext context) {
  final adaptiveQuality = GlassAdaptiveScopeData.maybeOf(
    context,
  )?.effectiveQuality;
  final themeQuality = GlassThemeData.of(context).qualityFor(context);
  return adaptiveQuality ?? themeQuality ?? GlassQuality.standard;
}

/// Action descriptor for a capsule pill button in an iOS 26 Liquid Glass alert.
class GlassAlertAction {
  const GlassAlertAction({
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
    this.isDestructive = false,
    this.autofocus = false,
    this.key,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isPrimary;
  final bool isDestructive;
  final bool autofocus;
  final Key? key;

  bool get isProminent => isPrimary || isDestructive;
}

/// Presents a custom iOS 26 Liquid Glass alert route.
Future<T?> showGlassAlertRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: false,
    barrierLabel: CupertinoLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: dark ? const Color(0x78000000) : const Color(0x3D000000),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (dialogContext, _, _) => builder(dialogContext),
    transitionBuilder: (dialogContext, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(dialogContext)) return child;
      final isReversing = animation.status == AnimationStatus.reverse;
      final scaleCurve = CurvedAnimation(
        parent: animation,
        curve: _alertOpenCurve,
        reverseCurve: Curves.easeInCubic,
      );
      final opacityCurve = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.72, curve: Curves.easeOut),
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: opacityCurve,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: isReversing ? 0.94 : 0.92,
            end: 1.0,
          ).animate(scaleCurve),
          child: child,
        ),
      );
    },
  );
}

/// Presents a general iOS 26 Liquid Glass alert dialog.
Future<T?> showGlassAlertDialog<T>({
  required BuildContext context,
  required String title,
  required List<GlassAlertAction> Function(BuildContext dialogContext)
  actionsBuilder,
  String? message,
  bool compactWidth = true,
  Key? dialogKey,
  Key surfaceKey = const ValueKey('glass-alert-surface'),
}) => showGlassAlertRoute<T>(
  context: context,
  builder: (dialogContext) => GlassAlert(
    key: dialogKey,
    surfaceKey: surfaceKey,
    title: title,
    message: message,
    compactWidth: compactWidth,
    actions: actionsBuilder(dialogContext),
  ),
);

/// Presents a single-action iOS 26 Liquid Glass status or error alert.
Future<void> showGlassMessageDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String closeLabel,
  Key? dialogKey,
  Key? actionKey,
  Key surfaceKey = const ValueKey('glass-alert-surface'),
}) => showGlassAlertDialog<void>(
  context: context,
  dialogKey: dialogKey,
  surfaceKey: surfaceKey,
  title: title,
  message: message,
  actionsBuilder: (dialogContext) => [
    GlassAlertAction(
      key: actionKey,
      label: closeLabel,
      autofocus: true,
      onPressed: () => Navigator.pop(dialogContext),
    ),
  ],
);

/// Presents a two-action iOS 26 Liquid Glass confirmation alert.
Future<bool?> showGlassConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String cancelLabel,
  required String confirmLabel,
  bool destructive = false,
  Key? dialogKey,
  Key? cancelKey,
  Key? confirmKey,
  Key surfaceKey = const ValueKey('glass-alert-surface'),
}) => showGlassAlertDialog<bool>(
  context: context,
  dialogKey: dialogKey,
  surfaceKey: surfaceKey,
  title: title,
  message: message,
  actionsBuilder: (dialogContext) => [
    GlassAlertAction(
      key: cancelKey,
      label: cancelLabel,
      autofocus: destructive,
      onPressed: () => Navigator.pop(dialogContext, false),
    ),
    GlassAlertAction(
      key: confirmKey,
      label: confirmLabel,
      isPrimary: !destructive,
      isDestructive: destructive,
      autofocus: !destructive,
      onPressed: () => Navigator.pop(dialogContext, true),
    ),
  ],
);

/// Floating iOS 26 Liquid Glass alert container with concentric superellipse
/// geometry, left-aligned typography, optional scrollable detail well, and
/// capsule action pills.
class GlassAlert extends StatefulWidget {
  const GlassAlert({
    required this.title,
    required this.actions,
    this.versionDetails,
    this.message,
    this.notesTitle,
    this.notesBody,
    this.hasNotes = true,
    this.compactWidth = false,
    this.surfaceKey = const ValueKey('glass-alert-surface'),
    super.key,
  });

  final String title;
  final String? versionDetails;
  final String? message;
  final String? notesTitle;
  final String? notesBody;
  final bool hasNotes;
  final bool compactWidth;
  final Key surfaceKey;
  final List<GlassAlertAction> actions;

  @override
  State<GlassAlert> createState() => _GlassAlertState();
}

class _GlassAlertState extends State<GlassAlert> {
  final ScrollController _notesScrollController = ScrollController();

  @override
  void dispose() {
    _notesScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF1C1C1E);
    final muted = ink.withValues(alpha: dark ? .62 : .56);
    final availableWidth = math.max(
      240.0,
      size.width -
          safe.left -
          safe.right -
          (widget.compactWidth ? 48.0 : 40.0),
    );
    final availableHeight = math.max(
      200.0,
      size.height - safe.top - safe.bottom - 24.0,
    );
    final isWide = size.width >= 600;
    final targetMaxWidth = widget.compactWidth
        ? (isWide ? 336.0 : 312.0)
        : (isWide ? 392.0 : 340.0);
    final dialogMaxWidth = math.min(targetMaxWidth, availableWidth);
    final compactHeight = availableHeight < 380;
    final dialogMaxHeight = size.height > 700
        ? math.min(availableHeight, 560.0)
        : availableHeight;

    // Concentric iOS 26 geometry: outer superellipse radius equals
    // pill radius (height / 2) + button inset from the platter edge.
    final buttonHeight = compactHeight ? 44.0 : 46.0;
    final buttonInset = compactHeight ? 12.0 : 13.0;
    final outerRadius = buttonHeight / 2 + buttonInset;
    final notesRadius = compactHeight ? 20.0 : 22.0;
    final textInset = compactHeight ? 18.0 : 22.0;
    final topInset = compactHeight ? 18.0 : 22.0;

    final quality = resolveGlassAlertQuality(context);
    final settings = glassAlertSettings(context);
    final shape = LiquidRoundedSuperellipse(borderRadius: outerRadius);
    final largeText = textScaler.scale(16) > 22;
    final useUnifiedBodyScroll =
        availableHeight < 280 || largeText || widget.notesBody == null;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(textInset, topInset, textInset, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            textAlign: TextAlign.start,
            style: TextStyle(
              fontSize: compactHeight ? 18 : 19,
              fontWeight: FontWeight.w700,
              height: 1.25,
              letterSpacing: -0.35,
              color: ink,
            ),
          ),
          if (widget.versionDetails != null) ...[
            SizedBox(height: compactHeight ? 4 : 6),
            Text(
              widget.versionDetails!,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.5,
                color: muted,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (widget.message != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.message!,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                height: 1.48,
                color: ink.withValues(alpha: dark ? .82 : .76),
              ),
            ),
          ],
        ],
      ),
    );

    final hasNotesBlock = widget.notesTitle != null && widget.notesBody != null;
    Widget? notesWell({required bool innerScrollable}) {
      if (!hasNotesBlock) return null;
      final wellBorderRadius = BorderRadius.circular(notesRadius);
      final wellShape = RoundedSuperellipseBorder(
        borderRadius: wellBorderRadius,
        side: BorderSide(
          color: dark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
          width: 0.5,
        ),
      );
      final notesContent = ReleaseNotesView(
        body: widget.notesBody!,
        hasNotes: widget.hasNotes,
        ink: ink,
        muted: muted,
        dark: dark,
      );
      final wellHorizontalPad = compactHeight ? 12.0 : 14.0;
      final wellTopPad = compactHeight ? 10.0 : 12.0;
      final scrollBody = innerScrollable
          ? Flexible(
              fit: FlexFit.loose,
              child: _ScrollEdgeFade(
                controller: _notesScrollController,
                child: CupertinoScrollbar(
                  controller: _notesScrollController,
                  thickness: 3,
                  radius: const Radius.circular(3),
                  child: SingleChildScrollView(
                    controller: _notesScrollController,
                    primary: false,
                    padding: EdgeInsets.fromLTRB(
                      wellHorizontalPad,
                      2,
                      wellHorizontalPad,
                      wellTopPad + 2,
                    ),
                    physics: const BouncingScrollPhysics(),
                    child: SizedBox(width: double.infinity, child: notesContent),
                  ),
                ),
              ),
            )
          : Padding(
              padding: EdgeInsets.fromLTRB(
                wellHorizontalPad,
                2,
                wellHorizontalPad,
                wellTopPad,
              ),
              child: SizedBox(width: double.infinity, child: notesContent),
            );
      return Padding(
        padding: EdgeInsets.fromLTRB(
          buttonInset,
          compactHeight ? 10 : 14,
          buttonInset,
          0,
        ),
        child: DecoratedBox(
          key: const ValueKey('update-notes-well'),
          decoration: ShapeDecoration(
            color: dark ? const Color(0x14FFFFFF) : const Color(0x0B000000),
            shape: wellShape,
          ),
          child: ClipRSuperellipse(
            borderRadius: wellBorderRadius,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    wellHorizontalPad,
                    wellTopPad,
                    wellHorizontalPad,
                    6,
                  ),
                  child: Text(
                    widget.notesTitle!,
                    textAlign: TextAlign.start,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: ink.withValues(alpha: dark ? .76 : .70),
                    ),
                  ),
                ),
                scrollBody,
              ],
            ),
          ),
        ),
      );
    }

    final contentBody = useUnifiedBodyScroll
        ? Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              primary: false,
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  ?notesWell(innerScrollable: false),
                ],
              ),
            ),
          )
        : Flexible(
            fit: FlexFit.loose,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (notesWell(innerScrollable: true) case final well?)
                  Flexible(fit: FlexFit.loose, child: well),
              ],
            ),
          );

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: widget.title,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogMaxWidth,
                maxHeight: dialogMaxHeight,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: GlassContainer(
                  key: widget.surfaceKey,
                  useOwnLayer: true,
                  quality: quality,
                  settings: settings,
                  shape: shape,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      contentBody,
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          buttonInset,
                          hasNotesBlock
                              ? (compactHeight ? 12 : 16)
                              : (compactHeight ? 14 : 20),
                          buttonInset,
                          buttonInset,
                        ),
                        child: _GlassAlertActions(
                          actions: widget.actions,
                          buttonHeight: buttonHeight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassAlertActions extends StatelessWidget {
  const _GlassAlertActions({
    required this.actions,
    required this.buttonHeight,
  });

  final List<GlassAlertAction> actions;
  final double buttonHeight;

  bool _fitsSideBySide(BuildContext context, double maxWidth) {
    if (actions.length != 2) return actions.length <= 1;
    // Two capsules separated by a 10 pt gap, keeping comfortable horizontal
    // padding inside each rounded end cap.
    final labelBudget = (maxWidth - 10) / 2 - 28;
    if (labelBudget <= 0) return false;
    final baseStyle = DefaultTextStyle.of(context).style;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    for (final action in actions) {
      final painter = TextPainter(
        text: TextSpan(
          text: action.label,
          style: baseStyle.merge(
            const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
        ),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      final fits = painter.width <= labelBudget;
      painter.dispose();
      if (!fits) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (actions.length == 1) {
        return GlassAlertActionButton(
          action: actions.single,
          height: buttonHeight,
        );
      }
      if (_fitsSideBySide(context, constraints.maxWidth)) {
        return Row(
          children: [
            for (var index = 0; index < actions.length; index++) ...[
              if (index > 0) const SizedBox(width: 10),
              Expanded(
                child: GlassAlertActionButton(
                  action: actions[index],
                  height: buttonHeight,
                ),
              ),
            ],
          ],
        );
      }
      // Match iOS stacked alert hierarchy: prominent action above dismiss.
      final ordered = [
        ...actions.where((action) => action.isProminent),
        ...actions.where((action) => !action.isProminent),
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < ordered.length; index++) ...[
            if (index > 0) const SizedBox(height: 10),
            GlassAlertActionButton(
              action: ordered[index],
              height: buttonHeight,
            ),
          ],
        ],
      );
    },
  );
}

/// Concentric capsule pill button rendered directly on top of the Liquid Glass
/// alert surface using vibrancy fills rather than a second nested blur pass.
class GlassAlertActionButton extends StatefulWidget {
  const GlassAlertActionButton({
    required this.action,
    required this.height,
    super.key,
  });

  final GlassAlertAction action;
  final double height;

  @override
  State<GlassAlertActionButton> createState() => _GlassAlertActionButtonState();
}

class _GlassAlertActionButtonState extends State<GlassAlertActionButton> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;
  FocusHighlightMode _highlightMode = FocusManager.instance.highlightMode;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_handleHighlightModeChange);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(
      _handleHighlightModeChange,
    );
    super.dispose();
  }

  void _handleHighlightModeChange(FocusHighlightMode mode) {
    if (_highlightMode == mode || !mounted) return;
    setState(() => _highlightMode = mode);
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final primary = widget.action.isPrimary;
    final destructive = widget.action.isDestructive;
    final prominent = widget.action.isProminent;
    final showFocusRing =
        _focused && _highlightMode == FocusHighlightMode.traditional;
    final capsule = StadiumBorder(
      side: BorderSide(
        color: showFocusRing
            ? (prominent ? Colors.white : brandBlue)
            : prominent
            ? const Color(0x3DFFFFFF)
            : (dark ? const Color(0x26FFFFFF) : const Color(0x66FFFFFF)),
        width: showFocusRing ? 1.5 : 0.75,
      ),
    );

    final Color? solidFill;
    final Gradient? gradientFill;
    final Color? shadowColor;
    if (destructive) {
      solidFill = null;
      final top = _pressed
          ? const Color(0xFFFF6961)
          : _hovered
          ? const Color(0xFFFF5950)
          : const Color(0xFFFF4D43);
      final bottom = _pressed
          ? const Color(0xFFFF3B30)
          : _hovered
          ? const Color(0xFFF0352A)
          : const Color(0xFFE52E24);
      gradientFill = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      );
      shadowColor = CupertinoColors.systemRed.withValues(
        alpha: dark ? .34 : .24,
      );
    } else if (primary) {
      solidFill = null;
      final top = _pressed
          ? const Color(0xFF2893FF)
          : _hovered
          ? const Color(0xFF1E8CFF)
          : const Color(0xFF1486FF);
      final bottom = _pressed
          ? const Color(0xFF0A7AFF)
          : _hovered
          ? const Color(0xFF0578FA)
          : const Color(0xFF0072F2);
      gradientFill = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      );
      shadowColor = brandBlue.withValues(alpha: dark ? .32 : .24);
    } else {
      gradientFill = null;
      shadowColor = null;
      solidFill = dark
          ? (_pressed
                ? const Color(0x3BFFFFFF)
                : _hovered
                ? const Color(0x2EFFFFFF)
                : const Color(0x22FFFFFF))
          : (_pressed
                ? const Color(0x24000000)
                : _hovered
                ? const Color(0x1A000000)
                : const Color(0x12000000));
    }

    final labelColor = prominent
        ? Colors.white
        : (dark ? Colors.white : const Color(0xFF1C1C1E));

    return Semantics(
      button: true,
      label: widget.action.label,
      onTap: widget.action.onPressed,
      child: Focus(
        autofocus: widget.action.autofocus,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          child: Actions(
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.action.onPressed();
                  return null;
                },
              ),
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                key: widget.action.key,
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTapDown: (_) => _setPressed(true),
                onTapUp: (_) => _setPressed(false),
                onTapCancel: () => _setPressed(false),
                onTap: widget.action.onPressed,
                child: AnimatedScale(
                  scale: !reduceMotion && _pressed ? 0.97 : 1.0,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: reduceMotion || _pressed
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    constraints: BoxConstraints(minHeight: widget.height),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: ShapeDecoration(
                      color: solidFill,
                      gradient: gradientFill,
                      shape: capsule,
                      shadows: shadowColor != null
                          ? [
                              BoxShadow(
                                color: shadowColor,
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      widget.action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: labelColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Applies a soft alpha fade to whichever vertical edge of a scrollable notes
/// well currently has overflow content, avoiding hard mid-glyph clipping.
class _ScrollEdgeFade extends StatefulWidget {
  const _ScrollEdgeFade({required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  State<_ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<_ScrollEdgeFade> {
  final ValueNotifier<(bool top, bool bottom)> _edges = ValueNotifier((
    false,
    false,
  ));
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateFromController);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant _ScrollEdgeFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateFromController);
      widget.controller.addListener(_updateFromController);
    }
    _scheduleSync();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateFromController);
    _edges.dispose();
    super.dispose();
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _updateFromController();
    });
  }

  void _updateFromController() {
    if (!widget.controller.hasClients) return;
    _updateFromMetrics(widget.controller.position);
  }

  void _updateFromMetrics(ScrollMetrics metrics) {
    final top = metrics.pixels > 2;
    final bottom = metrics.maxScrollExtent - metrics.pixels > 2;
    final next = (top, bottom);
    if (_edges.value != next) _edges.value = next;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
    onNotification: (notification) {
      _updateFromMetrics(notification.metrics);
      return false;
    },
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _updateFromMetrics(notification.metrics);
        return false;
      },
      child: ValueListenableBuilder<(bool, bool)>(
        valueListenable: _edges,
        child: widget.child,
        builder: (context, edges, child) {
          final (fadeTop, fadeBottom) = edges;
          if (!fadeTop && !fadeBottom) return child!;
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) {
              if (bounds.height <= 0) {
                return const LinearGradient(
                  colors: [Colors.white, Colors.white],
                ).createShader(bounds);
              }
              final topStop = fadeTop
                  ? (14.0 / bounds.height).clamp(0.0, 0.25)
                  : 0.0;
              final bottomStop = fadeBottom
                  ? (1.0 - 20.0 / bounds.height).clamp(0.75, 1.0)
                  : 1.0;
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  fadeTop ? Colors.transparent : Colors.white,
                  Colors.white,
                  Colors.white,
                  fadeBottom ? Colors.transparent : Colors.white,
                ],
                stops: [0.0, topStop, bottomStop, 1.0],
              ).createShader(bounds);
            },
            child: child,
          );
        },
      ),
    ),
  );
}
