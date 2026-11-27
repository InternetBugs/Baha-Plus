import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'native_http_rating.dart';

class NativeHttpPlaybackConsent extends StatelessWidget {
  const NativeHttpPlaybackConsent({
    required this.rating,
    required this.translate,
    required this.onConfirm,
    super.key,
  });

  final int rating;
  final String Function(String) translate;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final badge = nativeHttpRatingBadge(rating);
    final rawRating = translate(nativeHttpRatingMessageKey(rating));
    final newline = rawRating.indexOf('\n');
    final ratingHeadline = newline == -1
        ? rawRating.trim()
        : rawRating.substring(0, newline).trim();
    final ratingDetail = newline == -1
        ? ''
        : rawRating.substring(newline + 1).trim();

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -1.1),
          radius: 1.45,
          colors: [Color(0xFF1A1E28), Color(0xFF09090C), Color(0xFF050507)],
          stops: [0.0, 0.62, 1.0],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.hasBoundedHeight && constraints.maxHeight < 220;
          return Center(
            child: SingleChildScrollView(
              padding: compact
                  ? const EdgeInsets.fromLTRB(16, 46, 16, 10)
                  : const EdgeInsets.fromLTRB(20, 44, 20, 18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KeyedSubtree(
                      key: const ValueKey('http-playback-age-rating'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: ShapeDecoration(
                              color: const Color(0x14FFFFFF),
                              shape: RoundedSuperellipseBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: const BorderSide(
                                  color: Color(0x22FFFFFF),
                                  width: 0.75,
                                ),
                              ),
                            ),
                            child: Padding(
                              padding: compact
                                  ? const EdgeInsets.fromLTRB(3.5, 2.5, 10, 2.5)
                                  : const EdgeInsets.fromLTRB(4, 3, 11, 3),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  DecoratedBox(
                                    key: const ValueKey(
                                      'http-playback-age-badge',
                                    ),
                                    decoration: ShapeDecoration(
                                      color: badge.backgroundColor,
                                      shape: const StadiumBorder(),
                                    ),
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: compact ? 6.5 : 7,
                                        vertical: compact ? 1.5 : 2,
                                      ),
                                      child: Text(
                                        badge.codeLabel,
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                          color: badge.foregroundColor,
                                          fontSize: compact ? 10 : 10.5,
                                          fontWeight: FontWeight.w700,
                                          height: 1.15,
                                          letterSpacing: 0.1,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: compact ? 6 : 7),
                                  Flexible(
                                    child: Text(
                                      ratingHeadline,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: const Color(0xF5FFFFFF),
                                        fontSize: compact ? 12 : 12.5,
                                        fontWeight: FontWeight.w600,
                                        height: 1.25,
                                        letterSpacing: -0.1,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (ratingDetail.isNotEmpty) ...[
                            SizedBox(height: compact ? 6 : 8),
                            Text(
                              ratingDetail,
                              style: TextStyle(
                                color: const Color(0xD9FFFFFF),
                                fontSize: compact ? 11.5 : 12.5,
                                fontWeight: FontWeight.w400,
                                height: compact ? 1.38 : 1.48,
                                decoration: TextDecoration.none,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(height: compact ? 2 : 4),
                    Text(
                      translate('httpAgeConsent'),
                      style: TextStyle(
                        color: const Color(0x8CFFFFFF),
                        fontSize: compact ? 10.5 : 11.5,
                        fontWeight: FontWeight.w400,
                        height: compact ? 1.32 : 1.42,
                        decoration: TextDecoration.none,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: compact ? 9 : 12),
                    _ConsentPrimaryButton(
                      key: const ValueKey('http-playback-consent'),
                      label: translate('httpConfirmPlayback'),
                      compact: compact,
                      onPressed: onConfirm,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// High-contrast iOS 26 specular gradient capsule matching the primary action
/// treatment in [GlassUpdateAlert].
class _ConsentPrimaryButton extends StatefulWidget {
  const _ConsentPrimaryButton({
    required this.label,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  State<_ConsentPrimaryButton> createState() => _ConsentPrimaryButtonState();
}

class _ConsentPrimaryButtonState extends State<_ConsentPrimaryButton> {
  static const _shadowBlue = Color(0x5C007AFF);

  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;
  FocusHighlightMode _highlightMode = FocusManager.instance.highlightMode;

  bool get _enabled => widget.onPressed != null;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_handleHighlightModeChange);
  }

  @override
  void didUpdateWidget(covariant _ConsentPrimaryButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && (_pressed || _hovered)) {
      _pressed = false;
      _hovered = false;
    }
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
    final enabled = _enabled;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final showFocusRing =
        enabled && _focused && _highlightMode == FocusHighlightMode.traditional;
    final top = _pressed
        ? const Color(0xFF2893FF)
        : _hovered
        ? const Color(0xFF2491FF)
        : const Color(0xFF1B8BFF);
    final bottom = _pressed
        ? const Color(0xFF0A7AFF)
        : _hovered
        ? const Color(0xFF0578FA)
        : const Color(0xFF0072F2);
    final capsule = StadiumBorder(
      side: BorderSide(
        color: showFocusRing ? Colors.white : const Color(0x47FFFFFF),
        width: showFocusRing ? 1.5 : 0.75,
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? widget.onPressed : null,
      child: Focus(
        canRequestFocus: enabled,
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
                  widget.onPressed?.call();
                  return null;
                },
              ),
            },
            child: MouseRegion(
              cursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
              onExit: enabled ? (_) => setState(() => _hovered = false) : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTapDown: enabled ? (_) => _setPressed(true) : null,
                onTapUp: enabled ? (_) => _setPressed(false) : null,
                onTapCancel: enabled ? () => _setPressed(false) : null,
                onTap: widget.onPressed,
                child: AnimatedOpacity(
                  opacity: enabled ? 1.0 : 0.42,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 140),
                  child: AnimatedScale(
                    scale: !reduceMotion && _pressed ? 0.96 : 1.0,
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    child: AnimatedContainer(
                      duration: reduceMotion || _pressed
                          ? Duration.zero
                          : const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      constraints: BoxConstraints(
                        minHeight: widget.compact ? 34 : 38,
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.compact ? 18 : 20,
                        vertical: widget.compact ? 6 : 8,
                      ),
                      decoration: ShapeDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [top, bottom],
                        ),
                        shape: capsule,
                        shadows: enabled
                            ? const [
                                BoxShadow(
                                  color: _shadowBlue,
                                  blurRadius: 16,
                                  offset: Offset(0, 5),
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.play_fill,
                            color: Colors.white,
                            size: widget.compact ? 11.5 : 12,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: widget.compact ? 13 : 13.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.15,
                                height: 1.2,
                                decoration: TextDecoration.none,
                              ),
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
        ),
      ),
    );
  }
}
