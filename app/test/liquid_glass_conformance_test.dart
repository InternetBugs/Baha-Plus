import 'dart:io';

import 'package:baha_plus/ui/chrome.dart';
import 'package:baha_plus/ui/glass_alert.dart';
import 'package:baha_plus/ui/layout.dart';
import 'package:baha_plus/ui/native_http_player.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  test(
    'UI source files do not regress to banned legacy Cupertino or Material widgets',
    () {
      final uiDir = Directory('lib/ui');
      expect(uiDir.existsSync(), isTrue);

      final banned = <String, RegExp>{
        'CupertinoAlertDialog': RegExp(r'\bCupertinoAlertDialog\b'),
        'showCupertinoDialog': RegExp(r'\bshowCupertinoDialog\b'),
        'AlertDialog': RegExp(r'\bAlertDialog\b'),
        'CupertinoActionSheet': RegExp(r'\bCupertinoActionSheet\b'),
        'CupertinoSwitch': RegExp(r'\bCupertinoSwitch\b'),
        'CupertinoSlidingSegmentedControl': RegExp(
          r'\bCupertinoSlidingSegmentedControl\b',
        ),
        'CupertinoSegmentedControl': RegExp(r'\bCupertinoSegmentedControl\b'),
        'RefreshIndicator': RegExp(r'\bRefreshIndicator\b'),
        'LinearProgressIndicator': RegExp(r'\bLinearProgressIndicator\b'),
        'CircularProgressIndicator': RegExp(r'\bCircularProgressIndicator\b'),
        'CupertinoButton.filled': RegExp(r'\bCupertinoButton\.filled\b'),
        'LiquidRoundedRectangle': RegExp(r'\bLiquidRoundedRectangle\b'),
        'Material Icons.*': RegExp(r'(?<!Cupertino)\bIcons\.'),
      };

      final violations = <String>[];
      for (final entity in uiDir.listSync().whereType<File>()) {
        if (!entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final entry in banned.entries) {
            if (entry.value.hasMatch(line)) {
              violations.add('${entity.path}:${i + 1}: uses ${entry.key}');
            }
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'UI regressions against docs/liquid-glass.md:\n${violations.join('\n')}',
      );
    },
  );

  testWidgets(
    'showGlassConfirmDialog supports destructive Liquid Glass capsule actions',
    (tester) async {
      bool? result;
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.standard),
          child: MaterialApp(
            home: Builder(
              builder: (context) => Center(
                child: CupertinoButton(
                  onPressed: () async {
                    result = await showGlassConfirmDialog(
                      context: context,
                      title: '清除日志',
                      message: '确定要删除全部诊断记录吗？',
                      cancelLabel: '取消',
                      confirmLabel: '清除',
                      destructive: true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.byType(GlassAlert), findsOneWidget);
      final surface = tester.widget<GlassContainer>(
        find.byKey(const ValueKey('glass-alert-surface')),
      );
      expect(surface.useOwnLayer, isTrue);
      expect(surface.shape, isA<LiquidRoundedSuperellipse>());

      final confirmButton = tester.widget<GlassAlertActionButton>(
        find.ancestor(
          of: find.text('清除'),
          matching: find.byType(GlassAlertActionButton),
        ),
      );
      expect(confirmButton.action.isDestructive, isTrue);
      expect(confirmButton.action.isPrimary, isFalse);

      await tester.tap(find.text('清除'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(result, isTrue);
      expect(find.byType(GlassAlert), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('PipIcon paints without Material Icons dependency', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: PipIcon(size: 18, color: Colors.white)),
      ),
    );
    expect(find.byType(PipIcon), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AdSkipCapsule renders Liquid Glass capsule for countdown & skip', (
    tester,
  ) async {
    var skipped = 0;
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: AdSkipCapsule(
                key: const ValueKey('http-skip-ad'),
                canSkip: false,
                label: '广告 15 秒',
                onSkip: () => skipped++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final capsule = find.byKey(const ValueKey('http-skip-ad'));
    final glass = tester.widget<GlassContainer>(
      find.descendant(of: capsule, matching: find.byType(GlassContainer)),
    );
    expect(glass.useOwnLayer, isTrue);
    expect(glass.platformViewBackdrop, isTrue);
    expect(glass.shape, isA<LiquidRoundedSuperellipse>());
    expect(find.byIcon(CupertinoIcons.forward_end_fill), findsNothing);
    await tester.tap(capsule);
    expect(skipped, 0);

    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: GlassThemeData.simple(quality: GlassQuality.standard),
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: AdSkipCapsule(
                key: const ValueKey('http-skip-ad'),
                canSkip: true,
                label: '跳过广告',
                onSkip: () => skipped++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(CupertinoIcons.forward_end_fill), findsOneWidget);
    await tester.tap(capsule);
    expect(skipped, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'EpisodeChipButton, GlassActionPill, and GlassNavigationRail use superellipse glass styling',
    (tester) async {
      var selectedEpisode = 1;
      var retried = 0;
      var railTab = 0;
      await tester.pumpWidget(
        LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          theme: GlassThemeData.simple(quality: GlassQuality.minimal),
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 84,
                    child: EpisodeChipButton(
                      label: '2',
                      selected: false,
                      onTap: () => selectedEpisode = 2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  GlassActionPill(label: '重试', onTap: () => retried++),
                  const SizedBox(height: 12),
                  GlassNavigationRail(
                    width: 84,
                    settings: LiquidGlassSettings.ios27Light,
                    selectedIndex: railTab,
                    onSelected: (index) => railTab = index,
                    selectedColor: brandBlue,
                    indicatorColor: const Color(0x268e8e93),
                    destinations: const [
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.square_stack_fill,
                        label: '探索',
                      ),
                      GlassNavigationRailDestination(
                        icon: CupertinoIcons.calendar,
                        label: '排期',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('2'));
      await tester.tap(find.text('重试'));
      await tester.tap(find.byKey(const ValueKey('rail-tab-1')));
      await tester.pump();

      expect(selectedEpisode, 2);
      expect(retried, 1);
      expect(railTab, 1);
      expect(
        find.byKey(const ValueKey('rail-sliding-indicator')),
        findsOneWidget,
      );
      final railContainer = tester.widget<GlassContainer>(
        find.descendant(
          of: find.byType(GlassNavigationRail),
          matching: find.byType(GlassContainer),
        ),
      );
      expect(railContainer.quality, GlassQuality.minimal);
      expect(tester.takeException(), isNull);
    },
  );
}
