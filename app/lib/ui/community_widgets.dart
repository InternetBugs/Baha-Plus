import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/community.dart';
import '../core/models.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'glass_settings_menu.dart';

const collapsedCommentLines = 3;
final _numericEpisodeRe = RegExp(r'^\d+(?:\.\d+)?$');
final _thousandsRe = RegExp(r'(?<!^)(?=(\d{3})+$)');

/// Shared numeric episode label formatter used across watch history and
/// community boards.
String formatEpisodeNumberLabel(AppStore store, String rawLabel) =>
    _numericEpisodeRe.hasMatch(rawLabel)
    ? store.t('episodeNumber').replaceAll('{n}', rawLabel)
    : rawLabel;

ShapeDecoration communityCardDecoration(
  BuildContext context, {
  double borderRadius = BahaRadius.card,
  double tintAlpha = .05,
  Color? color,
}) => bahaCardDecoration(
  context,
  borderRadius: borderRadius,
  tintAlpha: tintAlpha,
  community: true,
  color: color,
);

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
  return formatEpisodeNumberLabel(store, label);
}

/// Anchored Liquid Glass episode selector for switching episode comment boards.
class BoardEpisodePicker extends StatelessWidget {
  const BoardEpisodePicker({
    required this.store,
    required this.videoId,
    required this.episodes,
    required this.onSelected,
    this.fallbackLabel = '',
    super.key,
  });

  final AppStore store;
  final String videoId;
  final List<Episode> episodes;
  final ValueChanged<Episode> onSelected;
  final String fallbackLabel;

  @override
  Widget build(BuildContext context) {
    final currentLabel = boardEpisodeLabel(
      store,
      videoId,
      episodes,
      label: fallbackLabel,
    );
    if (episodes.length <= 1) {
      return Text(
        currentLabel,
        style: TextStyle(color: secondary(context), fontSize: 13),
      );
    }
    return GlassSettingsMenu(
      key: const ValueKey('board-episode-picker'),
      menuAlignment: GlassMenuAlignment.topLeft,
      items: [
        for (final episode in episodes)
          glassSettingsOptionItem(
            context,
            key: ValueKey('board-episode-${episode.id}'),
            title: formatEpisodeNumberLabel(store, episode.label),
            selected: episode.id == videoId,
            onTap: () => onSelected(episode),
          ),
      ],
      triggerBuilder: (context, toggle) => GlassActionPill(
        label: currentLabel,
        trailingIcon: CupertinoIcons.chevron_up_chevron_down,
        height: 36,
        fontSize: 13,
        horizontalPadding: 14,
        onTap: toggle,
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
  const RatingSummaryCard({required this.rating, this.store, super.key});
  final RatingSummary rating;
  final AppStore? store;

  @override
  Widget build(BuildContext context) {
    final formattedCount = _formatCount(rating.count);
    final countSuffix =
        store?.t(rating.count == 1 ? 'ratingSingular' : 'ratingPlural') ??
        (Localizations.maybeLocaleOf(context)?.scriptCode == 'Hans'
            ? '人评分'
            : '人評分');
    final countLabel = '$formattedCount$countSuffix';
    return Semantics(
      container: true,
      label: '${rating.value.toStringAsFixed(1)} / 5.0, $countLabel',
      excludeSemantics: true,
      child: DecoratedBox(
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
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 88, maxWidth: 132),
                child: Column(
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        rating.value.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 38,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: brandBlue,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      countLabel,
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
      ),
    );
  }

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
            builder: (context, bounds) => ClipRSuperellipse(
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

  String _formatCount(int value) =>
      value.toString().replaceAllMapped(_thousandsRe, (_) => ',');
}

class CommunityComposer extends StatelessWidget {
  const CommunityComposer({
    required this.store,
    required this.controller,
    required this.hint,
    required this.sending,
    required this.onSend,
    required this.maximum,
    this.countRunes = false,
    this.error,
    this.errorAction,
    this.replyName,
    this.cancelReply,
    this.focusNode,
    this.embedded = false,
    super.key,
  });
  final AppStore store;
  final TextEditingController controller;
  final String hint;
  final bool sending;
  final VoidCallback? onSend;
  final int maximum;
  final bool countRunes;
  final String? error, replyName;
  final Widget? errorAction;
  final VoidCallback? cancelReply;
  final FocusNode? focusNode;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = Column(
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
              Semantics(
                button: true,
                label: store.t('cancelReply'),
                excludeSemantics: true,
                onTap: cancelReply,
                child: CupertinoButton(
                  padding: const EdgeInsets.all(4),
                  minimumSize: const Size(32, 32),
                  onPressed: cancelReply,
                  child: const Icon(
                    CupertinoIcons.xmark_circle_fill,
                    size: 18,
                  ),
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
                maxLength: countRunes ? null : maximum,
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
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, child) {
                final trimmed = value.text.trim();
                final overLimit =
                    countRunes && trimmed.runes.length > maximum;
                final canSubmit =
                    !sending &&
                    onSend != null &&
                    trimmed.isNotEmpty &&
                    !overLimit;
                return Semantics(
                  label: store.t('send'),
                  button: true,
                  child: CupertinoButton(
                    minimumSize: const Size(44, 44),
                    padding: EdgeInsets.zero,
                    onPressed: canSubmit ? onSend : null,
                    child: sending
                        ? const CupertinoActivityIndicator()
                        : Icon(
                            CupertinoIcons.arrow_up_circle_fill,
                            size: 34,
                            color: canSubmit ? brandBlue : secondary(context),
                          ),
                  ),
                );
              },
            ),
          ],
        ),
        if (countRunes)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final count = value.text.trim().runes.length;
              final threshold = (maximum * 0.8).floor();
              if (count < threshold) return const SizedBox.shrink();
              final exceeded = count > maximum;
              return Padding(
                key: const ValueKey('community-rune-counter'),
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: Text(
                  exceeded
                      ? '${store.t('commentLengthExceeded').replaceAll('{max}', '$maximum')} ($count / $maximum)'
                      : '$count / $maximum',
                  style: TextStyle(
                    color: exceeded
                        ? Theme.of(context).colorScheme.error
                        : secondary(context),
                    fontSize: 11.5,
                    height: 1.4,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 4, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
                if (errorAction != null) ...[
                  const SizedBox(width: 8),
                  errorAction!,
                ],
              ],
            ),
          ),
      ],
    );
    return SafeArea(
      top: false,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: embedded
              ? DecoratedBox(
                  decoration: ShapeDecoration(
                    color: dark
                        ? const Color(0x24ffffff)
                        : const Color(0xb8ffffff),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(24),
                      side: BorderSide(
                        color: dark
                            ? const Color(0x1effffff)
                            : const Color(0x14000000),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: content,
                  ),
                )
              : GlassContainer(
                  useOwnLayer: true,
                  shape: const LiquidRoundedSuperellipse(borderRadius: 26),
                  padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                  child: content,
                ),
        ),
      ),
    );
  }
}
