import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';

BoxDecoration communityCardDecoration(
  BuildContext context, {
  double borderRadius = 22,
  double tintAlpha = .05,
  Color? color,
}) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return BoxDecoration(
    // Keep the surface opaque so its own shadow cannot darken the card body.
    color:
        color ??
        Color.alphaBlend(
          secondary(context).withValues(alpha: tintAlpha),
          theme.scaffoldBackgroundColor,
        ),
    borderRadius: BorderRadius.circular(borderRadius),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? .32 : .10),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? .20 : .06),
        blurRadius: 4,
        offset: const Offset(0, 2),
      ),
    ],
  );
}

String communityError(AppStore store, Object? error) {
  final code = error is CommunityException ? error.code : error;
  return store.t(switch (code) {
    'login' => 'communityLogin',
    'input' => 'communityInputError',
    'busy' => 'communityBusy',
    'stale' => 'communityStale',
    'rejected' => 'communityRejected',
    _ => 'communityUnavailable',
  });
}

String boardEpisodeLabel(
  AppStore store,
  String videoId,
  List<Episode> episodes, {
  String label = '',
}) {
  for (final episode in episodes) {
    if (episode.id == videoId) {
      label = episode.label;
      break;
    }
  }
  if (label.isEmpty) return store.t('currentEpisode');
  return RegExp(r'^\d+(?:\.\d+)?$').hasMatch(label)
      ? store.t('episodeNumber').replaceAll('{n}', label)
      : label;
}

class BoardEpisodePicker extends StatelessWidget {
  const BoardEpisodePicker({
    required this.store,
    required this.videoId,
    required this.episodes,
    required this.onSelected,
    this.label = '',
    this.enabled = true,
    super.key,
  });
  final AppStore store;
  final String videoId, label;
  final List<Episode> episodes;
  final ValueChanged<Episode> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final title = boardEpisodeLabel(store, videoId, episodes, label: label);
    if (episodes.length < 2) {
      return Text(
        title,
        style: const TextStyle(color: brandBlue, fontSize: 13),
      );
    }
    return Semantics(
      label: store.t('selectBoardEpisode'),
      button: true,
      child: GlassButton.custom(
        key: const ValueKey('board-episode-selector'),
        width: 150,
        height: 38,
        shape: const LiquidRoundedRectangle(borderRadius: 20),
        onTap: () {
          if (!enabled) return;
          showCupertinoModalPopup<void>(
            context: context,
            builder: (sheet) => CupertinoActionSheet(
              title: Text(store.t('selectBoardEpisode')),
              actions: [
                for (final episode in episodes)
                  CupertinoActionSheetAction(
                    key: ValueKey('board-select-${episode.id}'),
                    isDefaultAction: episode.id == videoId,
                    onPressed: () {
                      Navigator.pop(sheet);
                      onSelected(episode);
                    },
                    child: Text(boardEpisodeLabel(store, episode.id, episodes)),
                  ),
              ],
              cancelButton: CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(sheet),
                child: Text(store.t('close')),
              ),
            ),
          );
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: brandBlue, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(CupertinoIcons.chevron_down, size: 12, color: brandBlue),
          ],
        ),
      ),
    );
  }
}

class CommunityEmpty extends StatelessWidget {
  const CommunityEmpty({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    super.key,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 42, color: secondary(context)),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        if (message != null) ...[
          const SizedBox(height: 10),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: secondary(context),
              height: 1.6,
              fontSize: 13,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 18), action!],
      ],
    ),
  );
}

class RatingSummaryCard extends StatelessWidget {
  const RatingSummaryCard({required this.rating, super.key});
  final RatingSummary rating;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: communityCardDecoration(
      context,
      borderRadius: 20,
      tintAlpha: .06,
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 88,
            child: Column(
              children: [
                Text(
                  rating.value.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 38,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: brandBlue,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '${_formatCount(rating.count)}${Localizations.localeOf(context).scriptCode == 'Hans' ? '人评分' : '人評分'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondary(context), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              children: [
                for (var star = 5; star >= 1; star--)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: _bar(context, star),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _bar(BuildContext context, int star) {
    final count = rating.distribution[star - 1];
    final fraction = rating.count == 0 ? 0.0 : count / rating.count;
    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            '$star',
            style: TextStyle(color: secondary(context), fontSize: 11),
          ),
        ),
        const Icon(
          CupertinoIcons.star_fill,
          color: Color(0xffffb21a),
          size: 12,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: LayoutBuilder(
            builder: (context, bounds) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 7,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: secondary(context).withValues(alpha: .12),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: bounds.maxWidth * fraction.clamp(0.0, 1.0),
                        height: 7,
                        child: const ColoredBox(color: brandBlue),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatCount(int value) => value.toString().replaceAllMapped(
    RegExp(r'(?<!^)(?=(\d{3})+$)'),
    (_) => ',',
  );
}

class CommunityComposer extends StatelessWidget {
  const CommunityComposer({
    required this.store,
    required this.controller,
    required this.hint,
    required this.sending,
    required this.onSend,
    required this.maximum,
    this.error,
    this.replyName,
    this.cancelReply,
    this.focusNode,
    super.key,
  });
  final AppStore store;
  final TextEditingController controller;
  final String hint;
  final bool sending;
  final VoidCallback? onSend;
  final int maximum;
  final String? error, replyName;
  final VoidCallback? cancelReply;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 26),
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (replyName != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        store.t('replyingTo').replaceAll('{name}', replyName!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: brandBlue, fontSize: 12),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.all(4),
                      minimumSize: const Size(32, 32),
                      onPressed: cancelReply,
                      child: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: ValueKey('community-input-$maximum'),
                      controller: controller,
                      focusNode: focusNode,
                      enabled: !sending,
                      minLines: 1,
                      maxLines: 3,
                      maxLength: maximum,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                      decoration: InputDecoration(
                        hintText: hint,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder(
                    valueListenable: controller,
                    builder: (context, value, child) => Semantics(
                      label: store.t('send'),
                      button: true,
                      child: CupertinoButton(
                        minimumSize: const Size(44, 44),
                        padding: EdgeInsets.zero,
                        onPressed: sending || value.text.trim().isEmpty
                            ? null
                            : onSend,
                        child: sending
                            ? const CupertinoActivityIndicator()
                            : Icon(
                                CupertinoIcons.arrow_up_circle_fill,
                                size: 34,
                                color:
                                    onSend == null || value.text.trim().isEmpty
                                    ? secondary(context)
                                    : brandBlue,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
