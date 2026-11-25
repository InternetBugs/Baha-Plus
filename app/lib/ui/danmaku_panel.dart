import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_widgets.dart';
import 'glass_settings_menu.dart';
import 'layout.dart';

const _playerSheetAnimation = AnimationStyle(
  duration: Duration(milliseconds: 140),
  reverseDuration: Duration(milliseconds: 80),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

const _composerTransitionDuration = Duration(milliseconds: 120);

const _danmakuColors = [
  '#FFFFFF',
  '#FFD166',
  '#FF9F43',
  '#FF595E',
  '#FF9FBA',
  '#C3A6FF',
  '#74D9FF',
  '#9DE0AD',
];

const _danmakuMaxBytes = 60;

Color _parseHexColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', 'ff'), radix: 16));

Color _sheetBackdropColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff111113)
    : const Color(0xfff2f2f7);

Color _cardSurfaceColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff1c1c1e)
    : Colors.white;

void showDanmakuPanel(BuildContext context, AppStore store) {
  showAdaptiveGlassSheet<void>(
    context: context,
    fullSize: .88,
    topBorderRadius: 32,
    expandedColor: const Color(0xfff2f2f7),
    expandedDarkColor: const Color(0xff111113),
    tabletMaxWidth: 780,
    tabletMaxHeightFraction: .78,
    tabletMaxHeight: 560,
    sheetAnimationStyle: _playerSheetAnimation,
    builder: (_) => DanmakuPanel(store: store),
  );
}

void showDanmakuComposer(BuildContext context, AppStore store) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: CupertinoLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: const Color(0x8a000000),
    transitionDuration: _composerTransitionDuration,
    pageBuilder: (dialogContext, _, _) {
      final media = MediaQuery.of(dialogContext);
      final viewInsets = media.viewInsets;
      final safe = media.padding;
      final availableHeight = math.max(
        160.0,
        media.size.height - viewInsets.bottom - safe.top,
      );
      final compact = availableHeight < 460;
      final radius = compact ? 26.0 : 30.0;
      final bottomMargin = viewInsets.bottom > 0
          ? 8.0
          : math.max(12.0, safe.bottom);
      final horizontalMargin = math.max(
        12.0,
        math.max(safe.left, safe.right) + 8.0,
      );
      final needsNotice =
          store.accountProfile == null ||
          !store.danmakuSettings.enabled ||
          !store.playback.value.canControl;
      final portraitCap = needsNotice ? 464.0 : 418.0;
      final maxHeight = math.min(
        compact ? 352.0 : portraitCap,
        math.max(160.0, availableHeight - bottomMargin - 12.0),
      );
      final dark = Theme.of(dialogContext).brightness == Brightness.dark;
      final shape = LiquidRoundedSuperellipse(borderRadius: radius);
      return AnimatedPadding(
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        duration: media.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalMargin,
              safe.top + 12,
              horizontalMargin,
              bottomMargin,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: compact ? 580 : 520,
                maxHeight: maxHeight,
              ),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: shape,
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? .52 : .22),
                      blurRadius: 34,
                      offset: const Offset(0, 14),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? .28 : .08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipPath(
                  clipper: ShapeBorderClipper(shape: shape),
                  child: MediaQuery.removePadding(
                    context: dialogContext,
                    removeTop: true,
                    removeBottom: true,
                    child: Material(
                      type: MaterialType.transparency,
                      child: DanmakuPanel(store: store, composerOnly: true),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (dialogContext, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(dialogContext)) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, .06),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class DanmakuPanel extends StatefulWidget {
  const DanmakuPanel({
    required this.store,
    this.composerOnly = false,
    super.key,
  });
  final AppStore store;
  final bool composerOnly;
  @override
  State<DanmakuPanel> createState() => _DanmakuPanelState();
}

class _DanmakuPanelState extends State<DanmakuPanel> {
  final _draft = TextEditingController();
  bool _sending = false;
  int _position = 0, _size = 1;
  String _color = '#FFFFFF';
  Object? _error;
  late final String? _videoId = widget.store.playingVideoId;
  late final String _document = widget.store.operation.id;
  AppStore get store => widget.store;

  bool _isDefaultSettings(DanmakuSettings settings) =>
      (settings.opacity - .8).abs() < .005 &&
      (settings.scale - 1.0).abs() < .005 &&
      settings.rolling &&
      settings.top &&
      settings.bottom;

  Future<void> _send() async {
    if (_sending) return;
    if (_videoId != store.playingVideoId || _document != store.operation.id) {
      setState(() => _error = const CommunityException('stale'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await store.sendDanmaku(
        _draft.text,
        color: _color,
        position: _position,
        size: _size,
      );
      if (mounted &&
          _videoId == store.playingVideoId &&
          _document == store.operation.id) {
        _draft.clear();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      store,
      store.playback,
      ?store.nativeHttpPlayback,
    ]),
    builder: (context, _) {
      final settings = store.danmakuSettings;
      final canSend =
          store.accountProfile != null &&
          settings.enabled &&
          store.playback.value.canControl &&
          store.playingVideoId == _videoId &&
          store.operation.id == _document;
      final backdrop = _sheetBackdropColor(context);
      return GlassScaffold(
        key: ValueKey(
          widget.composerOnly ? 'danmaku-composer' : 'danmaku-panel',
        ),
        extendBody: false,
        backgroundColor: backdrop,
        statusBarStyle: GlassStatusBarStyle.auto,
        appBar: widget.composerOnly
            ? _composerAppBar(context)
            : _settingsAppBar(context, settings),
        body: widget.composerOnly
            ? _composerBody(context, canSend)
            : _settingsBody(context, settings),
      );
    },
  );

  GlassAppBar _settingsAppBar(BuildContext context, DanmakuSettings settings) {
    final modified = !_isDefaultSettings(settings);
    return GlassAppBar(
      centerTitle: false,
      toolbarHeight: 56,
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
      title: Text(
        store.t('danmakuSettings'),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
      ),
      actions: [
        if (modified)
          GlassIconButton(
            key: const ValueKey('danmaku-reset'),
            size: 40,
            semanticLabel: store.t('danmakuReset'),
            icon: const Icon(CupertinoIcons.arrow_counterclockwise, size: 18),
            onPressed: () => store.setDanmakuSettings(
              settings.copyWith(
                opacity: .8,
                scale: 1.0,
                rolling: true,
                top: true,
                bottom: true,
              ),
            ),
          ),
        GlassIconButton(
          size: 40,
          semanticLabel: store.t('close'),
          icon: const Icon(CupertinoIcons.xmark, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  GlassAppBar _composerAppBar(BuildContext context) => GlassAppBar(
    centerTitle: false,
    toolbarHeight: 56,
    padding: const EdgeInsets.fromLTRB(18, 8, 14, 4),
    title: Row(
      children: [
        Flexible(
          child: Text(
            store.t('sendDanmaku'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
          ),
        ),
        const SizedBox(width: 10),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _draft,
          builder: (context, value, _) => _ByteCounterBadge(
            bytes: utf8.encode(value.text.trim()).length,
          ),
        ),
      ],
    ),
    actions: [
      GlassIconButton(
        size: 40,
        semanticLabel: store.t('close'),
        icon: const Icon(CupertinoIcons.xmark, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
    ],
  );

  Widget _settingsBody(BuildContext context, DanmakuSettings settings) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final hasLoadError = store.nativeHttpPlayback?.danmakuFailureStage != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 640;
        final stage = _DanmakuCinemaStage(
          store: store,
          settings: settings,
          height: wide ? 196 : 156,
        );
        final errorBanner = hasLoadError ? _loadErrorBanner(context) : null;
        final controls = _settingsControlGroups(
          context,
          settings,
          compact: wide,
        );
        if (wide) {
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 44,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            stage,
                            if (errorBanner != null) ...[
                              const SizedBox(height: 14),
                              errorBanner,
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 56,
                      child: SingleChildScrollView(child: controls),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 32),
          children: [
            stage,
            if (errorBanner != null) ...[
              const SizedBox(height: 14),
              errorBanner,
            ],
            const SizedBox(height: 22),
            controls,
          ],
        );
      },
    );
  }

  Widget _loadErrorBanner(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: dark ? const Color(0x28ff453a) : const Color(0x16ff3b30),
        shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle_fill,
              color: CupertinoColors.systemRed,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                store.t('danmakuLoadError'),
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: const Size(44, 36),
              onPressed: () => store.nativeHttpPlayback?.loadDanmaku(),
              child: Text(
                store.t('retry'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsControlGroups(
    BuildContext context,
    DanmakuSettings settings, {
    bool compact = false,
  }) {
    final card = _cardSurfaceColor(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(context, store.t('danmakuStyle')),
        const SizedBox(height: 8),
        GlassSettingsGroup(
          color: card,
          dividerIndent: 54,
          children: [
            _sliderRow(
              context,
              key: const ValueKey('danmaku-opacity-slider'),
              icon: CupertinoIcons.circle_lefthalf_fill,
              label: 'danmakuOpacity',
              value: settings.opacity,
              min: .1,
              max: 1.0,
              compact: compact,
              onChanged: (value) =>
                  store.setDanmakuSettings(settings.copyWith(opacity: value)),
            ),
            _sliderRow(
              context,
              key: const ValueKey('danmaku-size-slider'),
              icon: CupertinoIcons.textformat_size,
              label: 'danmakuSize',
              value: settings.scale,
              min: .5,
              max: 1.5,
              compact: compact,
              onChanged: (value) =>
                  store.setDanmakuSettings(settings.copyWith(scale: value)),
            ),
          ],
        ),
        SizedBox(height: compact ? 16 : 22),
        _sectionLabel(context, store.t('danmakuModes')),
        const SizedBox(height: 8),
        GlassSettingsGroup(
          color: card,
          children: [
            GlassSettingsSwitchRow(
              key: const ValueKey('danmaku-mode-rolling'),
              title: store.t('danmakuRolling'),
              icon: CupertinoIcons.arrow_left_right,
              value: settings.rolling,
              onChanged: (value) =>
                  store.setDanmakuSettings(settings.copyWith(rolling: value)),
            ),
            GlassSettingsSwitchRow(
              key: const ValueKey('danmaku-mode-top'),
              title: store.t('danmakuTop'),
              icon: CupertinoIcons.arrow_up_to_line,
              value: settings.top,
              onChanged: (value) =>
                  store.setDanmakuSettings(settings.copyWith(top: value)),
            ),
            GlassSettingsSwitchRow(
              key: const ValueKey('danmaku-mode-bottom'),
              title: store.t('danmakuBottom'),
              icon: CupertinoIcons.arrow_down_to_line,
              value: settings.bottom,
              onChanged: (value) =>
                  store.setDanmakuSettings(settings.copyWith(bottom: value)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    bool compact = false,
    required ValueChanged<double> onChanged,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inactiveTrack = dark
        ? const Color(0x2effffff)
        : const Color(0x1f000000);
    return Padding(
      padding: EdgeInsets.fromLTRB(18, compact ? 12 : 16, 18, compact ? 10 : 14),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, color: brandBlue, size: 20),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  store.t(label),
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              const SizedBox(width: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: brandBlue.withValues(alpha: dark ? .22 : .11),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Text(
                    '${(value * 100).round()}%',
                    style: TextStyle(
                      color: dark ? const Color(0xff5eb0ff) : brandBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 10),
          Semantics(
            label: store.t(label),
            child: GlassSlider(
              key: key,
              value: value,
              min: min,
              max: max,
              trackHeight: 5,
              thumbRadius: 13,
              activeColor: brandBlue,
              inactiveColor: inactiveTrack,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _composerBody(BuildContext context, bool canSend) => LayoutBuilder(
    builder: (context, constraints) {
      final compactPadding = constraints.maxHeight < 220;
      final textScaler = MediaQuery.textScalerOf(context);
      final stackedControls =
          constraints.maxWidth < 340 || textScaler.scale(14) > 17.5;
      final segmentHeight = (textScaler.scale(13) + 22).clamp(38.0, 58.0);
      return Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                18,
                compactPadding ? 6 : 10,
                18,
                compactPadding ? 6 : 12,
              ),
              children: [
                if (!canSend) ...[
                  _composerNoticeBanner(context),
                  const SizedBox(height: 12),
                ],
                GlassSettingsGroup(
                  color: _cardSurfaceColor(context),
                  dividerIndent: 18,
                  children: [
                    _segmentedStyleRow(
                      context,
                      key: const ValueKey('danmaku-position-control'),
                      label: store.t('danmakuPosition'),
                      labels: [
                        store.t('danmakuRolling'),
                        store.t('danmakuTop'),
                        store.t('danmakuBottom'),
                      ],
                      selectedIndex: _position,
                      stacked: stackedControls,
                      controlHeight: segmentHeight,
                      onSelected: (index) => setState(() => _position = index),
                    ),
                    _segmentedStyleRow(
                      context,
                      key: const ValueKey('danmaku-size-control'),
                      label: store.t('danmakuFontSize'),
                      labels: [
                        store.t('smallText'),
                        store.t('standardText'),
                        store.t('largeText'),
                      ],
                      selectedIndex: _size,
                      stacked: stackedControls,
                      controlHeight: segmentHeight,
                      onSelected: (index) => setState(() => _size = index),
                    ),
                    _colorPaletteRow(context, stacked: stackedControls),
                  ],
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _draft,
                  builder: (context, value, _) {
                    final overLimit =
                        utf8.encode(value.text.trim()).length >
                        _danmakuMaxBytes;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        store.t(
                          overLimit
                              ? 'danmakuBytesLimitExceeded'
                              : 'danmakuLimit',
                        ),
                        style: TextStyle(
                          color: overLimit
                              ? Theme.of(context).colorScheme.error
                              : secondary(context),
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          CommunityComposer(
            store: store,
            controller: _draft,
            hint: store.t('danmakuPlaceholder'),
            sending: _sending,
            onSend: canSend ? _send : null,
            maximum: _danmakuMaxBytes,
            error: _error == null ? null : communityError(store, _error),
          ),
        ],
      );
    },
  );

  Widget _composerNoticeBanner(BuildContext context) {
    final loginRequired = store.accountProfile == null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = loginRequired ? CupertinoColors.systemOrange : brandBlue;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: accent.withValues(alpha: dark ? .20 : .12),
        shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              loginRequired
                  ? CupertinoIcons.person_crop_circle
                  : CupertinoIcons.play_circle,
              color: accent,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                store.t(
                  loginRequired
                      ? 'danmakuLoginRequired'
                      : 'danmakuWaitForContent',
                ),
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .85),
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segmentedStyleRow(
    BuildContext context, {
    required Key key,
    required String label,
    required List<String> labels,
    required int selectedIndex,
    required bool stacked,
    required double controlHeight,
    required ValueChanged<int> onSelected,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final control = GlassSegmentedControl(
      key: key,
      height: controlHeight,
      borderRadius: controlHeight / 2,
      backgroundColor: dark ? const Color(0x1fffffff) : const Color(0x14000000),
      indicatorColor: dark ? const Color(0x36ffffff) : Colors.white,
      selectedTextStyle: TextStyle(
        fontFamily: 'BahaSans',
        fontFamilyFallback: const ['BahaSansSC'],
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: dark ? Colors.white : brandBlue,
      ),
      unselectedTextStyle: TextStyle(
        fontFamily: 'BahaSans',
        fontFamilyFallback: const ['BahaSansSC'],
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: secondary(context),
      ),
      segments: [for (final text in labels) GlassSegment(label: text)],
      selectedIndex: selectedIndex,
      onSegmentSelected: onSelected,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: secondary(context),
                  ),
                ),
                const SizedBox(height: 8),
                control,
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: secondary(context),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: control),
              ],
            ),
    );
  }

  Widget _colorPaletteRow(BuildContext context, {required bool stacked}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget swatch(String hex) => _ColorSwatch(
      hex: hex,
      label: store.t('danmakuColor').replaceAll('{color}', hex),
      selected: _color == hex,
      onTap: () => setState(() => _color = hex),
    );
    final tray = DecoratedBox(
      decoration: ShapeDecoration(
        color: dark ? const Color(0xff121620) : const Color(0xff1b2434),
        shape: LiquidRoundedSuperellipse(
          borderRadius: 16,
          side: BorderSide(
            color: Colors.white.withValues(alpha: dark ? .08 : .10),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: LayoutBuilder(
          builder: (context, bounds) {
            if (bounds.maxWidth >= 292) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [for (final hex in _danmakuColors) swatch(hex)],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final hex in _danmakuColors.take(4)) swatch(hex),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final hex in _danmakuColors.skip(4)) swatch(hex),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  store.t('danmakuColorLabel'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: secondary(context),
                  ),
                ),
                const SizedBox(height: 8),
                tray,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    store.t('danmakuColorLabel'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: secondary(context),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: tray),
              ],
            ),
    );
  }

  Widget _sectionLabel(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(left: 16),
    child: Text(
      title,
      style: TextStyle(
        color: secondary(context),
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }
}

class _ByteCounterBadge extends StatelessWidget {
  const _ByteCounterBadge({required this.bytes});
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final over = bytes > _danmakuMaxBytes;
    final near = !over && bytes >= 48;
    final Color foreground;
    final Color background;
    if (over) {
      foreground = CupertinoColors.systemRed;
      background = CupertinoColors.systemRed.withValues(alpha: dark ? .24 : .14);
    } else if (near) {
      foreground = CupertinoColors.systemOrange;
      background = CupertinoColors.systemOrange.withValues(
        alpha: dark ? .22 : .14,
      );
    } else {
      foreground = secondary(context);
      background = dark ? const Color(0x1cffffff) : const Color(0x10000000);
    }
    return DecoratedBox(
      key: const ValueKey('danmaku-byte-counter'),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          '$bytes/$_danmakuMaxBytes',
          style: TextStyle(
            color: foreground,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.hex,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String hex;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fill = _parseHexColor(hex);
    final bright = fill.computeLuminance() > .55;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      child: GestureDetector(
        key: ValueKey('danmaku-color-$hex'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: 32,
          height: 32,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white.withValues(alpha: .16),
              width: selected ? 2.2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: fill.withValues(alpha: .55),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            child: selected
                ? Center(
                    child: Icon(
                      CupertinoIcons.checkmark,
                      size: 13,
                      color: bright ? const Color(0xff111319) : Colors.white,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _DanmakuCinemaStage extends StatelessWidget {
  const _DanmakuCinemaStage({
    required this.store,
    required this.settings,
    required this.height,
  });

  final AppStore store;
  final DanmakuSettings settings;
  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    const shape = LiquidRoundedSuperellipse(borderRadius: 22);
    return Semantics(
      label: store.t('danmakuPreviewLabel'),
      child: ClipPath(
        key: const ValueKey('danmaku-settings-stage'),
        clipper: const ShapeBorderClipper(shape: shape),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _DanmakuStagePainter(
              settings: settings,
              heroText: store.t('danmakuPreview'),
              topText: store.t('danmakuPreviewTop'),
              rollingText: store.t('danmakuPreviewRolling'),
              bottomText: store.t('danmakuPreviewBottom'),
              disabledHint: store.t('danmakuDisabledHint'),
              borderAlpha: dark ? .12 : .16,
            ),
          ),
        ),
      ),
    );
  }
}

class _DanmakuStagePainter extends CustomPainter {
  const _DanmakuStagePainter({
    required this.settings,
    required this.heroText,
    required this.topText,
    required this.rollingText,
    required this.bottomText,
    required this.disabledHint,
    required this.borderAlpha,
  });

  final DanmakuSettings settings;
  final String heroText;
  final String topText;
  final String rollingText;
  final String bottomText;
  final String disabledHint;
  final double borderAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Deep cinematic anime twilight backdrop for accurate danmaku legibility.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xff0b1220),
            Color(0xff14233b),
            Color(0xff1f2f4c),
          ],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
    );
    // Subtle atmospheric cinema horizon glow.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(.35, -.15),
          radius: .95,
          colors: const [Color(0x305894d6), Color(0x0014233b)],
        ).createShader(rect),
    );
    // Gentle cinema edge vignette so top and bottom pinned lines sit cleanly.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x52000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0x5c000000),
          ],
          stops: [0.0, 0.28, 0.72, 1.0],
        ).createShader(rect),
    );

    _paintSettingsPreview(canvas, size);

    // Crisp inner glass rim along the stage frame.
    final rim = RRect.fromRectAndRadius(
      rect.deflate(.5),
      const Radius.circular(21.5),
    );
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: borderAlpha),
    );
  }

  void _paintSettingsPreview(Canvas canvas, Size size) {
    final opacity = settings.opacity;
    final scale = settings.scale;
    if (settings.top) {
      _paintDanmakuLine(
        canvas,
        size,
        text: topText,
        color: const Color(0xffffd166).withValues(alpha: opacity),
        fontSize: 13.5 * scale,
        centerX: size.width * .5,
        centerY: size.height * .16,
      );
    }
    if (settings.rolling) {
      _paintDanmakuLine(
        canvas,
        size,
        text: heroText,
        color: Colors.white.withValues(alpha: opacity),
        fontSize: 16.5 * scale,
        leftX: size.width * .11,
        centerY: size.height * .43,
        trailingCue: true,
        cueOpacity: opacity * .32,
      );
      _paintDanmakuLine(
        canvas,
        size,
        text: rollingText,
        color: const Color(0xff74d9ff).withValues(alpha: opacity),
        fontSize: 13.5 * scale,
        rightX: size.width * .83,
        centerY: size.height * .64,
        trailingCue: true,
        cueOpacity: opacity * .26,
      );
    }
    if (settings.bottom) {
      _paintDanmakuLine(
        canvas,
        size,
        text: bottomText,
        color: const Color(0xff9de0ad).withValues(alpha: opacity),
        fontSize: 13.5 * scale,
        centerX: size.width * .5,
        centerY: size.height * .85,
      );
    }
    if (!settings.rolling && !settings.top && !settings.bottom) {
      _paintCenteredBadge(canvas, size, disabledHint);
    }
  }

  void _paintDanmakuLine(
    Canvas canvas,
    Size size, {
    required String text,
    required Color color,
    required double fontSize,
    required double centerY,
    double? centerX,
    double? leftX,
    double? rightX,
    bool trailingCue = false,
    double cueOpacity = 0,
  }) {
    final maxWidth = math.max(40.0, size.width - 28.0);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'BahaSans',
          fontFamilyFallback: const ['BahaSansSC'],
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          shadows: const [
            Shadow(color: Color(0xd9000000), blurRadius: 3, offset: Offset(0, 1)),
            Shadow(color: Color(0x99000000), blurRadius: 8),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);

    final maxX = math.max(14.0, size.width - painter.width - 14.0);
    double x;
    if (centerX != null) {
      x = (centerX - painter.width / 2).clamp(14.0, maxX).toDouble();
    } else if (rightX != null) {
      x = (rightX - painter.width).clamp(14.0, maxX).toDouble();
    } else {
      x = (leftX ?? 14.0).clamp(14.0, maxX).toDouble();
    }
    final maxY = math.max(6.0, size.height - painter.height - 6.0);
    final y = (centerY - painter.height / 2).clamp(6.0, maxY).toDouble();

    if (trailingCue && cueOpacity > 0) {
      final trailStart = x + painter.width + 8;
      final trailEnd = math.min(size.width - 12.0, trailStart + 28.0);
      if (trailEnd - trailStart >= 8) {
        final lineY = y + painter.height * .52;
        final trailRect = Rect.fromLTRB(trailStart, lineY - 1, trailEnd, lineY + 1);
        canvas.drawRRect(
          RRect.fromRectAndRadius(trailRect, const Radius.circular(1)),
          Paint()
            ..shader = LinearGradient(
              colors: [
                color.withValues(alpha: cueOpacity),
                color.withValues(alpha: 0),
              ],
            ).createShader(trailRect),
        );
      }
    }

    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }

  void _paintCenteredBadge(Canvas canvas, Size size, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'BahaSans',
          fontFamilyFallback: ['BahaSansSC'],
          color: Color(0xb8ffffff),
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(40.0, size.width - 48.0));

    final pillWidth = painter.width + 26;
    final pillHeight = painter.height + 14;
    final pillRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: pillWidth,
        height: pillHeight,
      ),
      Radius.circular(pillHeight / 2),
    );
    canvas.drawRRect(pillRect, Paint()..color = const Color(0x38000000));
    canvas.drawRRect(
      pillRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x28ffffff),
    );
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _DanmakuStagePainter oldDelegate) =>
      oldDelegate.settings != settings ||
      oldDelegate.heroText != heroText ||
      oldDelegate.topText != topText ||
      oldDelegate.rollingText != rollingText ||
      oldDelegate.bottomText != bottomText ||
      oldDelegate.disabledHint != disabledHint ||
      oldDelegate.borderAlpha != borderAlpha;
}
