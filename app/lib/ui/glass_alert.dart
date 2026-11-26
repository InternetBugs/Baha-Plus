import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'chrome.dart';

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
    final media = MediaQuery.of(context);
    final safe = media.padding;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF1C1C1E);
    final muted = ink.withValues(alpha: dark ? .62 : .56);
    final availableWidth = math.max(
      240.0,
      media.size.width -
          safe.left -
          safe.right -
          (widget.compactWidth ? 48.0 : 40.0),
    );
    final availableHeight = math.max(
      200.0,
      media.size.height - safe.top - safe.bottom - 24.0,
    );
    final isWide = media.size.width >= 600;
    final targetMaxWidth = widget.compactWidth
        ? (isWide ? 336.0 : 312.0)
        : (isWide ? 392.0 : 340.0);
    final dialogMaxWidth = math.min(targetMaxWidth, availableWidth);
    final compactHeight = availableHeight < 380;
    final dialogMaxHeight = media.size.height > 700
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
    final largeText = media.textScaler.scale(16) > 22;
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
      final wellShape = LiquidRoundedSuperellipse(
        borderRadius: notesRadius,
        side: BorderSide(
          color: dark ? const Color(0x1AFFFFFF) : const Color(0x0D000000),
          width: 0.5,
        ),
      );
      final notesContent = _GlassAlertNotesContent(
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
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: wellShape),
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

sealed class _NotesBlock {
  const _NotesBlock();
}

class _NotesHeadingBlock extends _NotesBlock {
  const _NotesHeadingBlock(this.level, this.text);

  final int level;
  final String text;
}

class _NotesBulletBlock extends _NotesBlock {
  const _NotesBulletBlock({
    required this.text,
    this.indent = 0,
    this.marker,
  });

  final String text;
  final int indent;
  final String? marker;
}

class _NotesParagraphBlock extends _NotesBlock {
  const _NotesParagraphBlock(this.text);

  final String text;
}

class _NotesQuoteBlock extends _NotesBlock {
  const _NotesQuoteBlock(this.text);

  final String text;
}

class _NotesCodeBlock extends _NotesBlock {
  const _NotesCodeBlock(this.code);

  final String code;
}

class _NotesRuleBlock extends _NotesBlock {
  const _NotesRuleBlock();
}

/// Renders Markdown release notes cleanly inside an alert well: headings without
/// raw `#` tokens, hanging-indent bullet/numbered lists, inline bold/code/links,
/// and plain-text passthrough for non-Markdown notes.
class _GlassAlertNotesContent extends StatelessWidget {
  const _GlassAlertNotesContent({
    required this.body,
    required this.hasNotes,
    required this.ink,
    required this.muted,
    required this.dark,
  });

  final String body;
  final bool hasNotes;
  final Color ink;
  final Color muted;
  final bool dark;

  static final _headingRe = RegExp(r'^\s*(#{1,6})\s+(.+?)\s*#*\s*$');
  static final _unorderedRe = RegExp(r'^(\s*)[-*+•]\s+(.+)$');
  static final _orderedRe = RegExp(r'^(\s*)(\d+)[.)]\s+(.+)$');
  static final _quoteRe = RegExp(r'^\s*>\s?(.*)$');
  static final _ruleRe = RegExp(r'^\s*([-*_])(?:\s*\1){2,}\s*$');
  static final _fenceRe = RegExp(r'^\s*(`{3,}|~{3,})');

  static List<_NotesBlock> _parseBlocks(String raw) {
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final blocks = <_NotesBlock>[];
    final paragraph = <String>[];
    final quote = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(_NotesParagraphBlock(paragraph.join('\n')));
      paragraph.clear();
    }

    void flushQuote() {
      if (quote.isEmpty) return;
      blocks.add(_NotesQuoteBlock(quote.join('\n')));
      quote.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      final fence = _fenceRe.firstMatch(line);
      if (fence != null) {
        flushParagraph();
        flushQuote();
        final marker = fence.group(1)!;
        final fenceChar = marker[0];
        final fenceLen = marker.length;
        final codeLines = <String>[];
        while (++i < lines.length) {
          final close = _fenceRe.firstMatch(lines[i]);
          if (close != null) {
            final closeMarker = close.group(1)!;
            if (closeMarker[0] == fenceChar && closeMarker.length >= fenceLen) {
              break;
            }
          }
          codeLines.add(lines[i]);
        }
        blocks.add(_NotesCodeBlock(codeLines.join('\n')));
        continue;
      }

      if (line.trim().isEmpty) {
        flushParagraph();
        flushQuote();
        continue;
      }

      if (_ruleRe.hasMatch(line)) {
        flushParagraph();
        flushQuote();
        blocks.add(const _NotesRuleBlock());
        continue;
      }

      final heading = _headingRe.firstMatch(line);
      if (heading != null) {
        flushParagraph();
        flushQuote();
        blocks.add(
          _NotesHeadingBlock(heading.group(1)!.length, heading.group(2)!.trim()),
        );
        continue;
      }

      final unordered = _unorderedRe.firstMatch(line);
      if (unordered != null) {
        flushParagraph();
        flushQuote();
        final indent = (unordered.group(1)!.length ~/ 2).clamp(0, 2);
        blocks.add(
          _NotesBulletBlock(text: unordered.group(2)!.trim(), indent: indent),
        );
        continue;
      }

      final ordered = _orderedRe.firstMatch(line);
      if (ordered != null) {
        flushParagraph();
        flushQuote();
        final indent = (ordered.group(1)!.length ~/ 2).clamp(0, 2);
        blocks.add(
          _NotesBulletBlock(
            text: ordered.group(3)!.trim(),
            indent: indent,
            marker: '${ordered.group(2)!}.',
          ),
        );
        continue;
      }

      final quoteMatch = _quoteRe.firstMatch(line);
      if (quoteMatch != null) {
        flushParagraph();
        quote.add(quoteMatch.group(1)!);
        continue;
      }

      flushQuote();
      paragraph.add(line);
    }

    flushParagraph();
    flushQuote();
    return blocks;
  }

  static bool _isEscapable(String ch) =>
      r'\`*_{}[]()#+-.!~<>'.contains(ch);

  static TextSpan _parseInline(
    String text, {
    required TextStyle baseStyle,
    required TextStyle boldStyle,
    required TextStyle codeStyle,
    required TextStyle strikeStyle,
  }) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
    }

    var i = 0;
    while (i < text.length) {
      final ch = text[i];

      // Backslash escapes emitted by tools/release_notes.py or Markdown authors.
      if (ch == r'\' && i + 1 < text.length && _isEscapable(text[i + 1])) {
        buffer.write(text[i + 1]);
        i += 2;
        continue;
      }

      // Inline code: `code`
      if (ch == '`') {
        final end = text.indexOf('`', i + 1);
        if (end > i + 1) {
          flushText();
          spans.add(TextSpan(text: text.substring(i + 1, end), style: codeStyle));
          i = end + 1;
          continue;
        }
      }

      // Bold: **text** or __text__
      if ((ch == '*' || ch == '_') &&
          i + 1 < text.length &&
          text[i + 1] == ch) {
        final delim = '$ch$ch';
        final end = text.indexOf(delim, i + 2);
        if (end > i + 2) {
          flushText();
          spans.add(
            _parseInline(
              text.substring(i + 2, end),
              baseStyle: boldStyle,
              boldStyle: boldStyle,
              codeStyle: codeStyle.copyWith(fontWeight: FontWeight.w600),
              strikeStyle: strikeStyle,
            ),
          );
          i = end + 2;
          continue;
        }
      }

      // Strikethrough: ~~text~~
      if (ch == '~' && i + 1 < text.length && text[i + 1] == '~') {
        final end = text.indexOf('~~', i + 2);
        if (end > i + 2) {
          flushText();
          spans.add(
            TextSpan(text: text.substring(i + 2, end), style: strikeStyle),
          );
          i = end + 2;
          continue;
        }
      }

      // Italic: *text* (avoid matching standalone asterisks with surrounding space)
      if (ch == '*' && i + 1 < text.length && text[i + 1] != ' ') {
        final end = text.indexOf('*', i + 1);
        if (end > i + 1 && text[end - 1] != ' ') {
          flushText();
          spans.add(
            TextSpan(
              text: text.substring(i + 1, end),
              style: baseStyle.copyWith(fontStyle: FontStyle.italic),
            ),
          );
          i = end + 1;
          continue;
        }
      }

      // Markdown link: [label](url) -> keep readable label only.
      if (ch == '[') {
        final closeBracket = text.indexOf(']', i + 1);
        if (closeBracket > i + 1 &&
            closeBracket + 1 < text.length &&
            text[closeBracket + 1] == '(') {
          final closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen > closeBracket + 2) {
            flushText();
            spans.add(
              _parseInline(
                text.substring(i + 1, closeBracket),
                baseStyle: baseStyle,
                boldStyle: boldStyle,
                codeStyle: codeStyle,
                strikeStyle: strikeStyle,
              ),
            );
            i = closeParen + 1;
            continue;
          }
        }
      }

      buffer.write(ch);
      i++;
    }

    flushText();
    if (spans.isEmpty) return TextSpan(text: '', style: baseStyle);
    if (spans.length == 1 && spans.single is TextSpan) {
      final only = spans.single as TextSpan;
      if (only.style == null && only.children == null) {
        return TextSpan(text: only.text, style: baseStyle);
      }
    }
    return TextSpan(style: baseStyle, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final bodyColor = hasNotes ? ink.withValues(alpha: dark ? .88 : .86) : muted;
    final bodyStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: bodyColor,
    );
    if (!hasNotes) {
      return Text(body, textAlign: TextAlign.start, style: bodyStyle);
    }

    final blocks = _parseBlocks(body);
    if (blocks.isEmpty) {
      return Text(body, textAlign: TextAlign.start, style: bodyStyle);
    }

    final codeStyle = bodyStyle.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: ink.withValues(alpha: dark ? .96 : .94),
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    final strikeStyle = bodyStyle.copyWith(
      decoration: TextDecoration.lineThrough,
      color: muted,
    );
    final bulletColor = ink.withValues(alpha: dark ? .52 : .44);

    TextSpan spanFor(String text, {TextStyle? style}) => _parseInline(
      text,
      baseStyle: style ?? bodyStyle,
      boldStyle: (style ?? bodyStyle).copyWith(
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      codeStyle: codeStyle,
      strikeStyle: strikeStyle,
    );

    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final previous = i > 0 ? blocks[i - 1] : null;
      if (previous != null) {
        final double gap;
        if (block is _NotesHeadingBlock) {
          gap = 14;
        } else if (previous is _NotesHeadingBlock) {
          gap = 6;
        } else if (block is _NotesBulletBlock &&
            previous is _NotesBulletBlock) {
          gap = 5;
        } else {
          gap = 8;
        }
        children.add(SizedBox(height: gap));
      }

      switch (block) {
        case _NotesHeadingBlock(:final level, :final text):
          final headingStyle = TextStyle(
            fontSize: level <= 2 ? 14.5 : 14,
            fontWeight: FontWeight.w600,
            height: 1.35,
            letterSpacing: -0.15,
            color: ink.withValues(alpha: dark ? .96 : .94),
          );
          children.add(
            Text.rich(
              spanFor(text, style: headingStyle),
              textAlign: TextAlign.start,
            ),
          );
        case _NotesBulletBlock(:final text, :final indent, :final marker):
          final markerText = marker ?? (indent == 0 ? '•' : '◦');
          final markerStyle = bodyStyle.copyWith(
            color: bulletColor,
            fontWeight: marker == null ? FontWeight.w700 : FontWeight.w500,
            fontFeatures: marker == null
                ? null
                : const [ui.FontFeature.tabularFigures()],
          );
          children.add(
            Padding(
              padding: EdgeInsets.only(left: indent * 14.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: marker == null ? 7 : 6),
                    child: Text(markerText, style: markerStyle),
                  ),
                  Expanded(
                    child: Text.rich(
                      spanFor(text),
                      textAlign: TextAlign.start,
                    ),
                  ),
                ],
              ),
            ),
          );
        case _NotesParagraphBlock(:final text):
          children.add(
            Text.rich(spanFor(text), textAlign: TextAlign.start),
          );
        case _NotesQuoteBlock(:final text):
          children.add(
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: ink.withValues(alpha: dark ? .24 : .18),
                    width: 2,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text.rich(
                  spanFor(text, style: bodyStyle.copyWith(color: muted)),
                  textAlign: TextAlign.start,
                ),
              ),
            ),
          );
        case _NotesCodeBlock(:final code):
          children.add(
            DecoratedBox(
              decoration: ShapeDecoration(
                color: dark ? const Color(0x16FFFFFF) : const Color(0x0D000000),
                shape: const RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  code,
                  style: bodyStyle.copyWith(
                    fontSize: 12.5,
                    height: 1.45,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          );
        case _NotesRuleBlock():
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Divider(
                height: 0.5,
                thickness: 0.5,
                color: ink.withValues(alpha: dark ? .16 : .10),
              ),
            ),
          );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
