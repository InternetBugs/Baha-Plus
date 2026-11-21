import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'chrome.dart';

const _lightMenuShadow = [
  BoxShadow(color: Color(0x16000000), blurRadius: 1, spreadRadius: 0.5),
  BoxShadow(color: Color(0x16000000), blurRadius: 28, offset: Offset(0, 10)),
  BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
];

const _settingsTextStyle = TextStyle(
  fontFamily: 'BahaSans',
  fontFamilyFallback: ['BahaSansSC'],
);

/// A selectable option displayed inside a floating Liquid Glass settings card.
class GlassSettingsOption<T> {
  const GlassSettingsOption({
    required this.value,
    required this.label,
    this.key,
  });

  final T value;
  final String label;
  final Key? key;
}

/// Imperative controller for a [GlassSettingsMenu].
class GlassSettingsMenuController {
  _GlassSettingsMenuState? _state;

  bool get isOpen => _state?._isOpen ?? false;

  void open() => _state?._open();

  void close() => _state?._close();

  void toggle() => _state?._toggle();

  void _attach(_GlassSettingsMenuState state) => _state = state;

  void _detach(_GlassSettingsMenuState state) {
    if (identical(_state, state)) _state = null;
  }
}

bool _isDarkMenu(BuildContext context, {bool forceDark = false}) =>
    forceDark || Theme.of(context).brightness == Brightness.dark;

/// Primary label and checkmark ink inside a Liquid Glass secondary card.
Color glassSettingsMenuInkColor(
  BuildContext context, {
  bool forceDark = false,
}) => _isDarkMenu(context, forceDark: forceDark)
    ? Colors.white
    : const Color(0xff1c1c1e);

/// Muted value and chevron ink inside a Liquid Glass secondary card.
Color glassSettingsMenuMutedColor(
  BuildContext context, {
  bool forceDark = false,
}) => glassSettingsMenuInkColor(
  context,
  forceDark: forceDark,
).withValues(alpha: .55);

/// Highlight pill fill for hover and slide-to-select inside a glass menu card.
Color glassSettingsMenuSelectionColor(
  BuildContext context, {
  bool forceDark = false,
}) => _isDarkMenu(context, forceDark: forceDark)
    ? const Color(0x24ffffff)
    : const Color(0x14000000);

/// Optical settings calibrated for an iOS 26 floating Liquid Glass menu card.
LiquidGlassSettings glassSettingsMenuSettings(
  BuildContext context, {
  bool platformViewBackdrop = false,
  bool forceDark = false,
}) {
  final dark = _isDarkMenu(context, forceDark: forceDark);
  if (platformViewBackdrop) {
    return dark
        ? const LiquidGlassSettings(
            glassColor: Color(0xb81e1e24),
            backerColor: Color(0x2e000000),
            blur: 20,
            thickness: 22,
            saturation: 1.4,
            lightIntensity: .65,
            ambientStrength: .18,
            refractiveIndex: 1.18,
            chromaticAberration: 0,
            shadowElevation: 0,
          )
        : const LiquidGlassSettings(
            glassColor: Color(0xccf7f7fa),
            blur: 20,
            thickness: 22,
            saturation: 1.55,
            lightIntensity: .85,
            ambientStrength: .32,
            refractiveIndex: 1.18,
            chromaticAberration: 0,
            shadow: _lightMenuShadow,
          );
  }

  final adaptiveQuality = GlassAdaptiveScopeData.maybeOf(
    context,
  )?.effectiveQuality;
  final themeQuality = GlassThemeData.of(context).qualityFor(context);
  final effectiveQuality =
      adaptiveQuality ?? themeQuality ?? GlassQuality.standard;
  final useNativeFrost =
      ui.ImageFilter.isShaderFilterSupported &&
      effectiveQuality == GlassQuality.premium;

  if (useNativeFrost) {
    return dark
        ? LiquidGlassSettings.ios27Dark.copyWith(
            glassColor: const Color(0x28ffffff),
            frost: 16,
            frostOpacity: .84,
            bodyShade: .32,
          )
        : LiquidGlassSettings.ios27Light.copyWith(
            glassColor: const Color(0x88f8f8fa),
            frost: 16,
            frostOpacity: .72,
            shadow: _lightMenuShadow,
          );
  }

  return dark
      ? const LiquidGlassSettings(
          glassColor: Color(0x9e222228),
          backerColor: Color(0x22101014),
          blur: 14,
          thickness: 18,
          saturation: 1.4,
          lightIntensity: .65,
          ambientStrength: .22,
          refractiveIndex: 1.2,
          chromaticAberration: 0,
          shadowElevation: 0,
        )
      : const LiquidGlassSettings(
          glassColor: Color(0x8cfafafd),
          blur: 14,
          thickness: 20,
          saturation: 1.85,
          lightIntensity: .9,
          ambientStrength: .35,
          refractiveIndex: 1.22,
          chromaticAberration: 0,
          shadow: _lightMenuShadow,
        );
}

/// Builds a checkmark-aligned option item matching iOS 26 picker menus.
GlassMenuItem glassSettingsOptionItem(
  BuildContext context, {
  Key? key,
  required String title,
  required bool selected,
  required VoidCallback onTap,
  bool forceDark = false,
}) {
  final ink = glassSettingsMenuInkColor(context, forceDark: forceDark);
  return GlassMenuItem(
    key: key,
    title: title,
    height: 44,
    iconSize: 16,
    iconColor: ink,
    icon: SizedBox(
      width: 16,
      child: selected
          ? const Center(child: Icon(CupertinoIcons.checkmark, size: 15))
          : null,
    ),
    titleStyle: _settingsTextStyle.copyWith(
      color: ink,
      fontSize: 16,
      fontWeight: FontWeight.w400,
    ),
    onTap: onTap,
  );
}

/// Builds a standard action item for a Liquid Glass settings menu card.
GlassMenuItem glassSettingsActionItem(
  BuildContext context, {
  Key? key,
  required String title,
  required VoidCallback onTap,
  IconData? icon,
  bool forceDark = false,
}) {
  final ink = glassSettingsMenuInkColor(context, forceDark: forceDark);
  return GlassMenuItem(
    key: key,
    title: title,
    height: 46,
    iconSize: 18,
    iconColor: ink,
    icon: icon == null ? null : Icon(icon, size: 18),
    titleStyle: _settingsTextStyle.copyWith(
      color: ink,
      fontSize: 16,
      fontWeight: FontWeight.w400,
    ),
    onTap: onTap,
  );
}

/// Builds a layered submenu item with a trailing value and disclosure chevron.
GlassMenuItem glassSettingsSubmenuItem(
  BuildContext context, {
  Key? key,
  required String title,
  required List<Widget> submenu,
  IconData? icon,
  String? value,
  bool forceDark = false,
}) {
  final ink = glassSettingsMenuInkColor(context, forceDark: forceDark);
  final muted = glassSettingsMenuMutedColor(context, forceDark: forceDark);
  return GlassMenuItem(
    key: key,
    title: title,
    height: 46,
    iconSize: 18,
    iconColor: ink,
    icon: icon == null ? null : Icon(icon, size: 18),
    titleStyle: _settingsTextStyle.copyWith(
      color: ink,
      fontSize: 16,
      fontWeight: FontWeight.w400,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null && value.isNotEmpty) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 84),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _settingsTextStyle.copyWith(color: muted, fontSize: 14),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Icon(CupertinoIcons.chevron_right, size: 14, color: muted),
      ],
    ),
    submenu: submenu,
    onTap: _noop,
  );
}

void _noop() {}

/// Floating iOS 26 Liquid Glass secondary menu card with instant barrier
/// release and system Back handling.
class GlassSettingsMenu extends StatefulWidget {
  const GlassSettingsMenu({
    required this.items,
    required this.triggerBuilder,
    this.controller,
    this.menuWidth,
    this.menuAlignment = GlassMenuAlignment.topRight,
    this.menuPadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.platformViewBackdrop = false,
    this.forceDark = false,
    this.morphSpeed = MorphSpeed.fast,
    this.onOpen,
    this.onClose,
    super.key,
  });

  final List<Widget> items;
  final Widget Function(BuildContext context, VoidCallback toggleMenu)
  triggerBuilder;
  final GlassSettingsMenuController? controller;
  final double? menuWidth;
  final GlassMenuAlignment menuAlignment;
  final EdgeInsets menuPadding;
  final bool platformViewBackdrop;
  final bool forceDark;
  final MorphSpeed morphSpeed;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  State<GlassSettingsMenu> createState() => _GlassSettingsMenuState();
}

class _GlassSettingsMenuState extends State<GlassSettingsMenu> {
  final GlassMenuController _menuController = GlassMenuController();
  final OverlayPortalController _barrierController = OverlayPortalController();
  LocalHistoryEntry? _historyEntry;
  bool _removingHistoryProgrammatically = false;
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant GlassSettingsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _detachHistoryEntry(checkRoute: false);
    super.dispose();
  }

  void _toggle() {
    if (_isOpen) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    if (!mounted || _isOpen) return;
    _isOpen = true;
    _showBarrier();
    _attachHistoryEntry();
    widget.onOpen?.call();
    _menuController.open();
  }

  void _close({bool fromHistory = false}) {
    final wasOpen = _isOpen;
    if (!wasOpen && !_menuController.isOpen) return;
    _isOpen = false;
    _hideBarrier();
    if (!fromHistory) _detachHistoryEntry();
    _menuController.close();
    if (wasOpen) widget.onClose?.call();
  }

  void _handleGlassMenuClose() {
    final wasOpen = _isOpen;
    _isOpen = false;
    _hideBarrier();
    _detachHistoryEntry();
    if (wasOpen) widget.onClose?.call();
  }

  void _showBarrier() {
    if (_barrierController.isShowing) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isOpen && !_barrierController.isShowing) {
          _barrierController.show();
        }
      });
    } else {
      _barrierController.show();
    }
  }

  void _hideBarrier() {
    if (!_barrierController.isShowing) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isOpen && _barrierController.isShowing) {
          _barrierController.hide();
        }
      });
    } else {
      _barrierController.hide();
    }
  }

  void _attachHistoryEntry() {
    if (_historyEntry != null || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        if (identical(_historyEntry, entry)) {
          _historyEntry = null;
        }
        if (_removingHistoryProgrammatically) return;
        _close(fromHistory: true);
      },
    );
    _historyEntry = entry;
    route.addLocalHistoryEntry(entry);
  }

  void _detachHistoryEntry({bool checkRoute = true}) {
    final entry = _historyEntry;
    if (entry == null) return;
    _historyEntry = null;
    if (checkRoute && (!mounted || ModalRoute.of(context)?.isActive != true)) {
      return;
    }
    _removingHistoryProgrammatically = true;
    try {
      entry.remove();
    } finally {
      _removingHistoryProgrammatically = false;
    }
  }

  Widget _buildBarrier(BuildContext context) => Positioned.fill(
    child: Semantics(
      container: true,
      label: CupertinoLocalizations.of(context).modalBarrierDismissLabel,
      onDismiss: _close,
      onTap: _close,
      child: GestureDetector(
        key: const ValueKey('glass-settings-menu-barrier'),
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        onTap: _close,
        child: const ColoredBox(color: Colors.transparent),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final targetWidth = widget.menuWidth ?? (screenWidth * .56).clamp(196, 232);
    final effectiveWidth = math.min(
      targetWidth,
      math.max(180.0, screenWidth - 32.0),
    );
    final settings = glassSettingsMenuSettings(
      context,
      platformViewBackdrop: widget.platformViewBackdrop,
      forceDark: widget.forceDark,
    );
    final selectionColor = glassSettingsMenuSelectionColor(
      context,
      forceDark: widget.forceDark,
    );

    Widget menu = GlassMenu(
      controller: _menuController,
      items: widget.items,
      menuWidth: effectiveWidth,
      menuBorderRadius: 28,
      itemBorderRadius: 20,
      menuAlignment: widget.menuAlignment,
      autoAdjustToScreen: true,
      menuPadding: widget.menuPadding,
      settings: settings,
      selectionColor: selectionColor,
      platformViewBackdrop: widget.platformViewBackdrop,
      showDismissBarrier: false,
      morphSpeed: widget.morphSpeed,
      onClose: _handleGlassMenuClose,
      triggerBuilder: (context, _) => widget.triggerBuilder(context, _toggle),
    );

    if (widget.forceDark && Theme.of(context).brightness != Brightness.dark) {
      final baseTheme = GlassThemeData.of(context);
      final cupertino = CupertinoTheme.of(context);
      menu = GlassTheme(
        data: baseTheme.copyWith(brightness: Brightness.dark),
        child: CupertinoTheme(
          data: cupertino.copyWith(
            brightness: Brightness.dark,
            textTheme: cupertino.textTheme.copyWith(
              textStyle: cupertino.textTheme.textStyle.copyWith(
                color: Colors.white,
              ),
              tabLabelTextStyle: cupertino.textTheme.tabLabelTextStyle.copyWith(
                color: Colors.white70,
              ),
            ),
          ),
          child: menu,
        ),
      );
    }

    return OverlayPortal(
      controller: _barrierController,
      overlayLocation: OverlayChildLocation.nearestOverlay,
      overlayChildBuilder: _buildBarrier,
      child: menu,
    );
  }
}

/// iOS 26 inset-grouped settings card with continuous squircle corners and
/// hairline inset dividers.
class GlassSettingsGroup extends StatelessWidget {
  const GlassSettingsGroup({
    required this.children,
    this.dividerIndent = 54,
    super.key,
  });

  final List<Widget> children;
  final double dividerIndent;

  static const _shape = LiquidRoundedSuperellipse(borderRadius: 26);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = secondary(context).withValues(alpha: dark ? .18 : .12);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: _shape,
      ),
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: _shape),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Padding(
                  padding: EdgeInsets.only(left: dividerIndent),
                  child: Divider(
                    height: 0.5,
                    thickness: 0.5,
                    color: dividerColor,
                  ),
                ),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

/// Interactive press-highlighted surface for rows inside a [GlassSettingsGroup].
class GlassSettingsHighlight extends StatefulWidget {
  const GlassSettingsHighlight({
    required this.child,
    this.onTap,
    this.semanticButton = true,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool semanticButton;

  @override
  State<GlassSettingsHighlight> createState() => _GlassSettingsHighlightState();
}

class _GlassSettingsHighlightState extends State<GlassSettingsHighlight> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highlight = _pressed && enabled
        ? (dark ? const Color(0x12ffffff) : const Color(0x0b000000))
        : Colors.transparent;
    Widget content = AnimatedContainer(
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      color: highlight,
      child: widget.child,
    );
    if (widget.semanticButton) {
      content = Semantics(button: true, enabled: enabled, child: content);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      child: content,
    );
  }
}

/// Standard settings row inside a [GlassSettingsGroup].
class GlassSettingsRow extends StatelessWidget {
  const GlassSettingsRow({
    required this.title,
    required this.icon,
    this.onTap,
    this.value,
    this.busy = false,
    super.key,
  });

  final String title;
  final IconData icon;
  final VoidCallback? onTap;
  final String? value;
  final bool busy;

  @override
  Widget build(BuildContext context) => GlassSettingsHighlight(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: Row(
        children: [
          Icon(icon, color: brandBlue, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
          if (value != null) ...[
            const SizedBox(width: 8),
            Text(
              value!,
              style: TextStyle(color: secondary(context), fontSize: 14),
            ),
            const SizedBox(width: 8),
          ],
          if (busy)
            const CupertinoActivityIndicator(radius: 7)
          else
            Icon(
              CupertinoIcons.chevron_right,
              color: secondary(context),
              size: 13,
            ),
        ],
      ),
    ),
  );
}

/// Settings row with a trailing iOS switch. Tapping anywhere on the row
/// toggles the value.
class GlassSettingsSwitchRow extends StatelessWidget {
  const GlassSettingsSwitchRow({
    required this.title,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.description,
    super.key,
  });

  final String title;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? description;

  @override
  Widget build(BuildContext context) => GlassSettingsHighlight(
    onTap: () => onChanged(!value),
    semanticButton: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: brandBlue, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15)),
                if (description != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    description!,
                    style: TextStyle(
                      color: secondary(context),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          CupertinoSwitch(
            value: value,
            activeTrackColor: brandBlue,
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

/// Settings picker row whose trailing control opens an anchored iOS 26 Liquid
/// Glass secondary option card with checkmark alignment.
class GlassSettingsPickerRow<T> extends StatefulWidget {
  const GlassSettingsPickerRow({
    required this.title,
    required this.icon,
    required this.valueLabel,
    required this.selectedValue,
    required this.options,
    required this.onSelected,
    this.menuWidth,
    super.key,
  });

  final String title;
  final IconData icon;
  final String valueLabel;
  final T selectedValue;
  final List<GlassSettingsOption<T>> options;
  final ValueChanged<T> onSelected;
  final double? menuWidth;

  @override
  State<GlassSettingsPickerRow<T>> createState() =>
      _GlassSettingsPickerRowState<T>();
}

class _GlassSettingsPickerRowState<T> extends State<GlassSettingsPickerRow<T>> {
  final GlassSettingsMenuController _menuController =
      GlassSettingsMenuController();

  @override
  Widget build(BuildContext context) {
    final muted = secondary(context);
    return GlassSettingsHighlight(
      onTap: _menuController.toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(widget.icon, color: brandBlue, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(widget.title, style: const TextStyle(fontSize: 15)),
            ),
            const SizedBox(width: 8),
            GlassSettingsMenu(
              controller: _menuController,
              menuWidth: widget.menuWidth,
              menuAlignment: GlassMenuAlignment.topRight,
              items: [
                for (final option in widget.options)
                  glassSettingsOptionItem(
                    context,
                    key: option.key,
                    title: option.label,
                    selected: option.value == widget.selectedValue,
                    onTap: () => widget.onSelected(option.value),
                  ),
              ],
              triggerBuilder: (context, toggleMenu) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: toggleMenu,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.valueLabel,
                        style: TextStyle(color: muted, fontSize: 14),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        CupertinoIcons.chevron_up_chevron_down,
                        color: muted,
                        size: 13,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
