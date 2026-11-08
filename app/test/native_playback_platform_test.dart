import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_test.dart' show FakePortal, FakeSearch, MemoryStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in TargetPlatform.values) {
    test('official handoff opts in only on supported hosts: $platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      final expected = switch (platform) {
        TargetPlatform.iOS when AppStore.iosNativePlaybackEnabled =>
          'ios-avplayer',
        TargetPlatform.android when AppStore.androidNativePlaybackEnabled =>
          'android-exoplayer',
        _ => null,
      };
      final store = await AppStore.create(
        storage: MemoryStorage(),
        animeSearch: FakeSearch(),
      );
      addTearDown(store.dispose);
      final portal = FakePortal();
      await store.attach(portal);
      await store.play(
        const Anime(
          id: '10',
          title: 'Test Anime',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        ),
      );
      await store.preparePlayerSurface(OfficialSite.video('20'));
      expect(AppStore.nativePlaybackBackend, expected);
      expect(
        portal.scripts.any(
          (script) => script.contains(
            'window.__bahaNativeBackend = ${expected == null ? 'null' : '"$expected"'};',
          ),
        ),
        isTrue,
      );
    });
  }
}
