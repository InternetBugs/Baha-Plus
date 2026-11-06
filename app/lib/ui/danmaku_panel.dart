import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'community_widgets.dart';

void showDanmakuPanel(BuildContext context, AppStore store) {
  GlassModalSheet.show<void>(
    context: context,
    initialState: GlassSheetState.full,
    fullSize: .88,
    detents: const {GlassSheetDetent.large},
    fullTopBorderRadius: 32,
    showDragIndicator: false,
    expandedColor: const Color(0xfff2f2f7),
    expandedDarkColor: const Color(0xff111113),
    builder: (_) => DanmakuPanel(store: store),
  );
}

class DanmakuPanel extends StatefulWidget {
  const DanmakuPanel({required this.store, super.key});
  final AppStore store;
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
  AppStore get store => widget.store;

  Future<void> _send() async {
    if (_sending) return;
    if (_videoId != store.playingVideoId) {
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
      if (mounted) _draft.clear();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, store.playback]),
    builder: (context, _) {
      final settings = store.danmakuSettings;
      final canSend =
          store.playback.value.canControl && store.playingVideoId == _videoId;
      return GlassScaffold(
        key: const ValueKey('danmaku-panel'),
        extendBody: false,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: GlassAppBar(
          title: Text(store.t('danmaku')),
          actions: [
            GlassIconButton(
              semanticLabel: store.t('close'),
              icon: const Icon(CupertinoIcons.xmark),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                children: [
                  // The preview is also the content behind the floating glass tools.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: SizedBox(
                      height: 118,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0xff183d5a), Color(0xff394c74)],
                              ),
                            ),
                          ),
                          if (settings.enabled)
                            Center(
                              child: Opacity(
                                opacity: settings.opacity,
                                child: Text(
                                  store.t('danmakuPreview'),
                                  style: TextStyle(
                                    fontSize: 22 * settings.scale,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    shadows: const [Shadow(blurRadius: 3)],
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: GlassButton.custom(
                              useOwnLayer: true,
                              settings: mediaGlass,
                              shape: const LiquidRoundedRectangle(
                                borderRadius: 20,
                              ),
                              width: 130,
                              height: 38,
                              onTap: () => store.setDanmakuSettings(
                                settings.copyWith(enabled: !settings.enabled),
                              ),
                              child: Text(
                                store.t(
                                  settings.enabled
                                      ? 'hideDanmaku'
                                      : 'showDanmaku',
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _slider(
                    'danmakuOpacity',
                    settings.opacity,
                    .1,
                    1,
                    (value) => store.setDanmakuSettings(
                      settings.copyWith(opacity: value),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _slider(
                    'danmakuSize',
                    settings.scale,
                    .5,
                    1.5,
                    (value) => store.setDanmakuSettings(
                      settings.copyWith(scale: value),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    store.t('danmakuModes'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _choice(
                        'danmakuRolling',
                        settings.rolling,
                        () => store.setDanmakuSettings(
                          settings.copyWith(rolling: !settings.rolling),
                        ),
                      ),
                      _choice(
                        'danmakuTop',
                        settings.top,
                        () => store.setDanmakuSettings(
                          settings.copyWith(top: !settings.top),
                        ),
                      ),
                      _choice(
                        'danmakuBottom',
                        settings.bottom,
                        () => store.setDanmakuSettings(
                          settings.copyWith(bottom: !settings.bottom),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text(
                    store.t('sendDanmaku'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    store.t('danmakuLimit'),
                    style: TextStyle(
                      color: secondary(context),
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var position = 0; position < 3; position++)
                        _choice(
                          [
                            'danmakuRolling',
                            'danmakuTop',
                            'danmakuBottom',
                          ][position],
                          _position == position,
                          () => setState(() => _position = position),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var size = 0; size < 3; size++)
                        _choice(
                          ['smallText', 'standardText', 'largeText'][size],
                          _size == size,
                          () => setState(() => _size = size),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 14,
                    runSpacing: 10,
                    children: [
                      for (final color in [
                        '#FFFFFF',
                        '#FFD166',
                        '#74D9FF',
                        '#FF9FBA',
                        '#9DE0AD',
                      ])
                        Semantics(
                          label: store
                              .t('danmakuColor')
                              .replaceAll('{color}', color),
                          selected: _color == color,
                          button: true,
                          child: GestureDetector(
                            onTap: () => setState(() => _color = color),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Color(
                                  int.parse(
                                    color.replaceFirst('#', 'ff'),
                                    radix: 16,
                                  ),
                                ),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _color == color
                                      ? brandBlue
                                      : Colors.black12,
                                  width: _color == color ? 3 : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (!canSend) ...[
                    const SizedBox(height: 16),
                    Text(
                      store.t('danmakuWaitForContent'),
                      style: TextStyle(
                        color: secondary(context),
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            CommunityComposer(
              store: store,
              controller: _draft,
              hint: store.t('danmakuPlaceholder'),
              sending: _sending,
              onSend: canSend ? _send : null,
              maximum: 60,
              error: _error == null ? null : communityError(store, _error),
            ),
          ],
        ),
      );
    },
  );

  Widget _choice(String label, bool selected, VoidCallback action) => Semantics(
    selected: selected,
    child: GlassButton.custom(
      shape: const LiquidRoundedRectangle(borderRadius: 20),
      width: 90,
      height: 40,
      onTap: action,
      child: Text(
        store.t(label),
        style: TextStyle(
          fontSize: 12,
          color: selected ? brandBlue : secondary(context),
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    ),
  );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> change,
  ) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(store.t(label), style: const TextStyle(fontSize: 13)),
          ),
          Text(
            '${(value * 100).round()}%',
            style: TextStyle(color: secondary(context), fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Semantics(
        label: store.t(label),
        child: GlassSlider(
          value: value,
          min: min,
          max: max,
          activeColor: brandBlue,
          onChanged: change,
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }
}
