import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';

Future<void> showFullscreenEpisodesDialog({
  required BuildContext context,
  required AppStore store,
  required Anime anime,
  required List<Episode> episodes,
  required String? currentId,
  required LiquidGlassSettings closeGlass,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: CupertinoLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: const Color(0x8a000000),
  transitionDuration: const Duration(milliseconds: 160),
  pageBuilder: (dialogContext, _, _) => _FullscreenEpisodesDialog(
    store: store,
    anime: anime,
    episodes: episodes,
    currentId: currentId,
    closeGlass: closeGlass,
  ),
  transitionBuilder: (dialogContext, animation, _, child) {
    if (MediaQuery.disableAnimationsOf(dialogContext)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: .96, end: 1.0).animate(curved),
        child: child,
      ),
    );
  },
);

class _FullscreenEpisodesDialog extends StatefulWidget {
  const _FullscreenEpisodesDialog({
    required this.store,
    required this.anime,
    required this.episodes,
    required this.currentId,
    required this.closeGlass,
  });

  final AppStore store;
  final Anime anime;
  final List<Episode> episodes;
  final String? currentId;
  final LiquidGlassSettings closeGlass;

  @override
  State<_FullscreenEpisodesDialog> createState() =>
      _FullscreenEpisodesDialogState();
}

class _FullscreenEpisodesDialogState extends State<_FullscreenEpisodesDialog> {
  final _scrollController = ScrollController();
  bool _scrolledToCurrent = false;
  static const _chipHeight = 40.0;
  static const _spacing = 10.0;

  void _scheduleInitialScroll(int columns) {
    if (_scrolledToCurrent || widget.currentId == null) return;
    _scrolledToCurrent = true;
    final index = widget.episodes.indexWhere((ep) => ep.id == widget.currentId);
    if (index < columns) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final row = index ~/ columns;
      final target = math.max(0.0, (row - 1) * (_chipHeight + _spacing));
      final maxExtent = _scrollController.position.maxScrollExtent;
      if (maxExtent > 0) {
        _scrollController.jumpTo(target.clamp(0.0, maxExtent));
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final availableWidth = math.max(
      260.0,
      size.width - safe.left - safe.right - 32.0,
    );
    final availableHeight = math.max(
      200.0,
      size.height - safe.top - safe.bottom - 32.0,
    );
    const shape = LiquidRoundedSuperellipse(borderRadius: 28);
    final episodes = widget.episodes;
    final currentId = widget.currentId;
    final shrinkWrap = episodes.length <= 24;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            key: const ValueKey('player-fullscreen-episodes-dialog'),
            constraints: BoxConstraints(
              maxWidth: math.min(520.0, availableWidth),
              maxHeight: math.min(420.0, availableHeight),
            ),
            child: GlassContainer(
              useOwnLayer: true,
              platformViewBackdrop: true,
              shape: shape,
              settings: LiquidGlassSettings.ios27Dark.copyWith(
                backerColor: const Color(0xcc141418),
                saturation: 1.0,
              ),
              padding: EdgeInsets.zero,
              child: Theme(
                data: Theme.of(context).copyWith(
                  brightness: Brightness.dark,
                  colorScheme: const ColorScheme.dark(
                    surface: Color(0xff1c1c1e),
                    onSurface: Colors.white,
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.store.t('episodes'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            GlassIconButton(
                              size: 36,
                              iconSize: 17,
                              semanticLabel: widget.store.t('close'),
                              settings: widget.closeGlass,
                              icon: const Icon(
                                CupertinoIcons.xmark,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: LayoutBuilder(
                          builder: (context, bounds) {
                            final gridWidth = math.max(
                              120.0,
                              bounds.maxWidth - 40.0,
                            );
                            final count = (gridWidth / 64).floor().clamp(4, 8);
                            _scheduleInitialScroll(count);
                            return GridView.builder(
                              controller: _scrollController,
                              shrinkWrap: shrinkWrap,
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                4,
                                20,
                                20,
                              ),
                              itemCount: episodes.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: count,
                                    mainAxisSpacing: _spacing,
                                    crossAxisSpacing: _spacing,
                                    mainAxisExtent: _chipHeight,
                                  ),
                              itemBuilder: (context, index) {
                                final episode = episodes[index];
                                final selected = episode.id == currentId;
                                return EpisodeChipButton(
                                  key: ValueKey('fullscreen-ep-${episode.id}'),
                                  label: episode.label,
                                  selected: selected,
                                  onTap: selected
                                      ? null
                                      : () {
                                          Navigator.pop(context);
                                          widget.store.play(
                                            widget.anime,
                                            episode: episode,
                                          );
                                        },
                                );
                              },
                            );
                          },
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
