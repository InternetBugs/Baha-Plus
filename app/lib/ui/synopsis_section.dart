import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../data/app_store.dart';
import 'chrome.dart';
import 'layout.dart';
import 'secondary_page_route.dart';

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
          GlassActionPill(
            key: const ValueKey('open-full-synopsis'),
            label: store.t('fullSynopsis'),
            trailingIcon: CupertinoIcons.chevron_right,
            height: 42,
            fontSize: 13.5,
            minWidth: 156,
            onTap: () => Navigator.push<void>(
              context,
              SecondaryPageRoute(
                keepsPlaybackVisible: store.showsPlayer,
                builder: (_) => SynopsisPage(
                  store: store,
                  title: title,
                  description: description,
                ),
              ),
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
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final hPad = layout.pageHorizontalPadding(maxWidth: 720);
    final safe = MediaQuery.paddingOf(context);
    return GlassScaffold(
      key: const ValueKey('full-synopsis-page'),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      statusBarStyle: GlassStatusBarStyle.auto,
      topEdgeFadeExtent: 44,
      appBar: GlassAppBar(
        title: Text(store.t('synopsis'), style: const TextStyle(fontSize: 17)),
        padding: layout.appBarPadding(hPad),
        actions: [
          GlassIconButton(
            semanticLabel: store.t('close'),
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          hPad.left,
          safe.top + 56,
          hPad.right,
          safe.bottom + 32,
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
}
