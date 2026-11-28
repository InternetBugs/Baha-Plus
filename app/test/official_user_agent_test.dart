import 'dart:io';

import 'package:baha_plus/data/official_user_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolution keeps one stable browser identity', () async {
    final before = OfficialUserAgent.value;
    final first = OfficialUserAgent.ensureResolved();
    expect(OfficialUserAgent.ensureResolved(), same(first));
    await first;
    await OfficialUserAgent.resolve();
    expect(OfficialUserAgent.device, startsWith('Mozilla/5.0 '));
    expect(OfficialUserAgent.value, startsWith('Mozilla/5.0 '));
    if (!Platform.isAndroid && !Platform.isIOS) {
      // A host without a WebView falls back once, and stays on it.
      expect(OfficialUserAgent.device, OfficialUserAgent.fallback);
      expect(OfficialUserAgent.value, before);
    }
  });
}
