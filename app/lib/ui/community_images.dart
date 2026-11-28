import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'secondary_page_route.dart';

class CommentAvatar extends StatelessWidget {
  const CommentAvatar({this.url, this.size = 36, super.key});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(
      CupertinoIcons.person_crop_circle_fill,
      color: secondary(context),
      size: size,
    );
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(32, 512);
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? fallback
            : Image(
                image: CachedNetworkImageProvider(
                  url!,
                  maxWidth: cacheSize,
                  maxHeight: cacheSize,
                ),
                key: ValueKey('comment-avatar-$url'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : fallback,
                errorBuilder: (_, error, stack) => fallback,
              ),
      ),
    );
  }
}

class CommentAttachment extends StatelessWidget {
  const CommentAttachment({
    required this.store,
    required this.url,
    this.compact = false,
    super.key,
  });
  final AppStore store;
  final String url;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget buildImage({int? maxWidth, int? maxHeight}) => Image(
      image: CachedNetworkImageProvider(
        url,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      fit: compact ? BoxFit.cover : BoxFit.contain,
      gaplessPlayback: true,
      alignment: Alignment.centerLeft,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : SizedBox(
              height: compact ? 56 : 160,
              child: const Center(child: CupertinoActivityIndicator()),
            ),
      errorBuilder: (_, error, stack) => compact
          ? Icon(
              CupertinoIcons.photo,
              semanticLabel: store.t('imageUnavailable'),
            )
          : _ImageUnavailable(store: store),
    );
    final compactCache = (56 * dpr).ceil().clamp(56, 512);
    return Semantics(
      label: store.t('viewAttachment'),
      button: true,
      child: GestureDetector(
        key: ValueKey('comment-attachment-$url'),
        onTap: () => Navigator.push<void>(
          context,
          SecondaryPageRoute(
            keepsPlaybackVisible: store.showsPlayer,
            builder: (_) => _AttachmentViewer(store: store, url: url),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: compact
                ? const BoxConstraints.tightFor(width: 56, height: 56)
                : const BoxConstraints(maxHeight: 260),
            child: compact
                ? buildImage(maxWidth: compactCache, maxHeight: compactCache)
                : LayoutBuilder(
                    builder: (context, constraints) => buildImage(
                      maxWidth: constraints.hasBoundedWidth
                          ? (constraints.maxWidth * dpr).ceil().clamp(1, 2048)
                          : null,
                      maxHeight: (260 * dpr).ceil().clamp(1, 2048),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentViewer extends StatelessWidget {
  const _AttachmentViewer({required this.store, required this.url});
  final AppStore store;
  final String url;

  @override
  Widget build(BuildContext context) => GlassScaffold(
    key: const ValueKey('comment-image-viewer'),
    edgeFade: false,
    enableBackgroundSampling: false,
    backgroundColor: Colors.black,
    appBar: GlassAppBar(
      title: Text(
        store.t('attachedImage'),
        style: const TextStyle(color: Colors.white, fontSize: 17),
      ),
      actions: [
        GlassIconButton(
          semanticLabel: store.t('close'),
          icon: const Icon(CupertinoIcons.xmark, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    ),
    body: InteractiveViewer(
      minScale: .5,
      maxScale: 5,
      child: Center(
        child: Image(
          image: CachedNetworkImageProvider(url),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          loadingBuilder: (_, child, progress) => progress == null
              ? child
              : const CupertinoActivityIndicator(color: Colors.white),
          errorBuilder: (_, error, stack) => _ImageUnavailable(store: store),
        ),
      ),
    ),
  );
}

class _ImageUnavailable extends StatelessWidget {
  const _ImageUnavailable({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.photo, size: 22, color: secondary(context)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            store.t('imageUnavailable'),
            style: TextStyle(color: secondary(context), fontSize: 12),
          ),
        ),
      ],
    ),
  );
}
