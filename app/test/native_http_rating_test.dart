import 'dart:convert';

import 'package:baha_plus/ui/native_http_player.dart';
import 'package:baha_plus/ui/native_http_rating.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dictionaries = <String, Map<String, String>>{};

  setUpAll(() async {
    for (final language in ['zh-Hans', 'zh-Hant']) {
      dictionaries[language] =
          (jsonDecode(await rootBundle.loadString('assets/i18n/$language.json'))
                  as Map<String, dynamic>)
              .cast<String, String>();
    }
  });

  for (final language in ['zh-Hans', 'zh-Hant']) {
    final traditional = language == 'zh-Hant';
    String translate(String key) => dictionaries[language]![key]!;
    String message(int code) => translate(nativeHttpRatingMessageKey(code));

    // Expected codes come from the official player's #T age-gate text and its
    // TW-ALL, TW-6TO12, TW-12TO15, TW-15TO18 and TW-18UP icons, not enum order.
    test('$language code 1 is suitable for general audiences', () {
      expect(message(1), contains(traditional ? '普遍級' : '普遍级'));
      expect(message(1), contains(traditional ? '全年齡' : '全年龄'));
      expect(message(1), contains(traditional ? '一般觀眾皆可觀賞' : '一般观众皆可观赏'));
    });

    test('$language code 2 includes the complete accompaniment rule', () {
      expect(message(2), contains(traditional ? '保護級' : '保护级'));
      expect(
        message(2),
        contains(traditional ? '未滿 6 歲之兒童不宜觀賞' : '未满 6 岁之儿童不宜观赏'),
      );
      expect(
        message(2),
        contains(
          traditional
              ? '6 歲以上未滿 12 歲之兒童需父母、師長或成年親友陪伴觀賞'
              : '6 岁以上未满 12 岁之儿童需父母、师长或成年亲友陪伴观赏',
        ),
      );
    });

    test('$language codes 3 and 4 distinguish the 12 and 15 age limits', () {
      expect(message(3), contains(traditional ? '輔12級' : '辅12级'));
      expect(
        message(3),
        contains(traditional ? '未滿 12 歲之兒童不宜觀賞' : '未满 12 岁之儿童不宜观赏'),
      );
      expect(message(3), isNot(contains('15')));
      expect(message(4), contains(traditional ? '輔15級' : '辅15级'));
      expect(
        message(4),
        contains(traditional ? '未滿 15 歲之人不宜觀賞' : '未满 15 岁之人不宜观赏'),
      );
    });

    test('$language codes 5 and 6 both restrict under-18 audiences', () {
      for (final code in [5, 6]) {
        expect(message(code), contains(traditional ? '限制級' : '限制级'));
        expect(message(code), contains(traditional ? '18 歲以上' : '18 岁以上'));
        expect(message(code), contains(traditional ? '未滿 18 歲' : '未满 18 岁'));
      }
      expect(message(5), isNot(contains(traditional ? '年齡驗證' : '年龄验证')));
      expect(message(6), contains(traditional ? '必須通過年齡驗證' : '必须通过年龄验证'));
      expect(
        message(6),
        contains(traditional ? '強烈裸露、性聯想、恐怖、血腥' : '强烈裸露、性联想、恐怖、血腥'),
      );
    });

    test('$language unknown codes do not claim all-age suitability', () {
      for (final code in [-1, 0, 7, 18, 99]) {
        expect(message(code), contains(traditional ? '分級待確認' : '分级待确认'));
        expect(message(code), contains(traditional ? '核對官網' : '核对官网'));
        expect(message(code), isNot(contains(traditional ? '全年齡' : '全年龄')));
        expect(message(code), isNot(contains(traditional ? '普遍級' : '普遍级')));
      }
    });

    for (final code in [2, 6, 99]) {
      testWidgets(
        '$language rating $code wraps and confirms on a narrow player',
        (tester) async {
          tester.view.physicalSize = const Size(280, 200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var confirmations = 0;
          await tester.pumpWidget(
            CupertinoApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: ColoredBox(
                color: CupertinoColors.black,
                child: NativeHttpPlaybackConsent(
                  rating: code,
                  translate: translate,
                  onConfirm: () => confirmations++,
                ),
              ),
            ),
          );
          expect(find.text(message(code)), findsOneWidget);
          expect(find.text(translate('httpAgeConsent')), findsOneWidget);
          expect(
            translate('httpAgeConsent'),
            traditional ? '請確認你符合上述觀看年齡及陪同要求。' : '请确认你符合上述观看年龄及陪同要求。',
          );
          expect(confirmations, 0);
          expect(tester.takeException(), isNull);
          final button = find.byKey(const ValueKey('http-playback-consent'));
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          expect(button.hitTestable(), findsOneWidget);
          await tester.tap(button);
          await tester.pump();
          expect(confirmations, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('confirmation stays disabled while the application is inactive', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: NativeHttpPlaybackConsent(
          rating: 3,
          translate: (key) => dictionaries['zh-Hans']![key]!,
          onConfirm: null,
        ),
      ),
    );
    final button = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('http-playback-consent')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
