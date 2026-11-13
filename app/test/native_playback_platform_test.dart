import 'package:baha_plus/data/app_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in TargetPlatform.values) {
    test('native decoding is available only on supported hosts: $platform', () {
      debugDefaultTargetPlatformOverride = platform;
      final expected = switch (platform) {
        TargetPlatform.iOS => 'ios-avplayer',
        TargetPlatform.android => 'android-exoplayer',
        TargetPlatform.windows when AppStore.windowsNativePlaybackEnabled =>
          'windows-mpv',
        _ => null,
      };
      expect(AppStore.nativePlaybackBackend, expected);
    });
  }
}
