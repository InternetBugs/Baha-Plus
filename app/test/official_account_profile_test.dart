import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/data/official_account_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';

void main() {
  const heading = '<h2 class="theme-title">我的動畫</h2>';
  const owner = '<a href="/viewList.php?u=reader">觀看紀錄</a>';
  const menu =
      '<a class="user-info"><span class="user-id">reader</span>'
      '<span class="user-name">讀者</span></a>';
  const login = '<a href="https://user.gamer.com.tw/login.php">登入</a>';

  test('server-rendered identity does not require the JavaScript menu', () {
    expect(officialAccountProfile(parse('$heading$owner')), {
      'id': 'reader',
      'displayName': 'reader',
    });
    expect(officialAccountProfile(parse('$heading$owner$menu')), {
      'id': 'reader',
      'displayName': '讀者',
    });
  });

  test('only an explicit guest page returns guest', () {
    expect(officialAccountProfile(parse(login)), isNull);
    expect(
      () => officialAccountProfile(parse('<html>loading</html>')),
      throwsA(isA<CommunityException>()),
    );
  });

  const publicProfile = '''
<div class="main-container_header_guildimg">
  <img id="avatar_img" src="https://avatar2.bahamut.com.tw/reader.png?v=3">
</div>
<div class="main-container_header_info">
  <div><h1>新的 &amp; 暱稱</h1></div>
  <div class="header_info-small"><small>ID：reader</small></div>
</div>
''';

  test('public profile reads the current nickname and avatar', () {
    expect(
      officialPublicAccountProfile(parse(publicProfile), owner: 'Reader'),
      {
        'id': 'Reader',
        'displayName': '新的 & 暱稱',
        'avatar': 'https://avatar2.bahamut.com.tw/reader.png?v=3',
      },
    );
  });

  test('public profile rejects a different owner or incomplete data', () {
    expect(
      () => officialPublicAccountProfile(parse(publicProfile), owner: 'other'),
      throwsA(isA<CommunityException>().having((e) => e.code, 'code', 'stale')),
    );
    for (final html in [
      '<html>loading</html>',
      publicProfile.replaceFirst('<h1>新的 &amp; 暱稱</h1>', ''),
      publicProfile.replaceFirst('id="avatar_img"', ''),
      publicProfile.replaceFirst(
        'https://avatar2.bahamut.com.tw/reader.png?v=3',
        'https://attacker.test/reader.png',
      ),
    ]) {
      expect(
        () => officialPublicAccountProfile(parse(html), owner: 'reader'),
        throwsException,
      );
    }
  });

  for (final html in [
    '$heading<a href="https://attacker.test/viewList.php?u=reader">x</a>',
    '$heading<a href="https://ani.gamer.com.tw:444/viewList.php?u=reader">x</a>',
    '$heading<a href="https://x@ani.gamer.com.tw/viewList.php?u=reader">x</a>',
    '$heading<a href="/viewList.php?u=reader#x">x</a>',
    '$heading<a href="/viewList.php?u=reader&u=another">x</a>',
    '$heading<a href="/viewList.php?u=guest">x</a>',
    '$heading<a href="/viewList.php?u=%3Cscript%3E">x</a>',
    '$heading$owner<a href="/viewList.php?u=another">x</a>',
    '$heading$owner$login',
    '$menu<a href="/viewList.php?u=another">x</a>',
    owner,
  ]) {
    test('untrusted or conflicting identity is rejected: $html', () {
      expect(
        () => officialAccountProfile(parse(html)),
        throwsA(isA<CommunityException>()),
      );
    });
  }
}
