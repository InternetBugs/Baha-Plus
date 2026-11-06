import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';

class SynopsisSection extends StatelessWidget {
  const SynopsisSection({
    required this.store,
    required this.title,
    required this.description,
    super.key,
  });
  static const previewLimit = 200;
  final AppStore store;
  final String title, description;

  @override
  Widget build(BuildContext context) {
    final text = description.characters;
    final truncated = text.length > previewLimit;
    return Column(
      key: const ValueKey('synopsis-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(store.t('synopsis')),
        const SizedBox(height: 14),
        Text(
          truncated ? '${text.take(previewLimit)}…' : description,
          key: const ValueKey('synopsis-preview'),
          style: TextStyle(
            fontSize: 14,
            color: secondary(context),
            height: 1.75,
          ),
        ),
        if (truncated) ...[
          const SizedBox(height: 12),
          GlassButton.custom(
            key: const ValueKey('open-full-synopsis'),
            shape: const LiquidRoundedRectangle(borderRadius: 22),
            width: 180,
            height: 42,
            onTap: () => Navigator.push<void>(
              context,
              CupertinoPageRoute(
                fullscreenDialog: true,
                builder: (_) => SynopsisPage(
                  store: store,
                  title: title,
                  description: description,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  store.t('fullSynopsis'),
                  style: const TextStyle(fontSize: 13, color: brandBlue),
                ),
                const SizedBox(width: 7),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 12,
                  color: brandBlue,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class SynopsisPage extends StatelessWidget {
  const SynopsisPage({
    required this.store,
    required this.title,
    required this.description,
    super.key,
  });
  final AppStore store;
  final String title, description;

  @override
  Widget build(BuildContext context) => GlassScaffold(
    key: const ValueKey('full-synopsis-page'),
    extendBody: false,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    appBar: GlassAppBar(
      title: Text(store.t('synopsis'), style: const TextStyle(fontSize: 17)),
      leading: GlassIconButton(
        semanticLabel: store.t('close'),
        icon: const Icon(CupertinoIcons.xmark),
        onPressed: () => Navigator.pop(context),
      ),
    ),
    body: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.paddingOf(context).bottom + 32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 24,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 22),
          SelectableText(
            description,
            style: const TextStyle(fontSize: 16, height: 1.8),
          ),
        ],
      ),
    ),
  );
}
