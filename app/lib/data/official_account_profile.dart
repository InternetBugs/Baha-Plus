import 'package:html/dom.dart';

import '../core/community.dart';
import '../core/models.dart';

/// Reads server-rendered identity without running the site's user-menu script.
/// An absent menu alone is not evidence that the session is a guest.
Json? officialAccountProfile(Document page) {
  final user = page.querySelector('a.user-info');
  final menuId = user?.querySelector('.user-id')?.text.trim();
  final guest =
      page.querySelector('a[href*="user.gamer.com.tw/login.php"]') != null;
  final owners = <String>[];
  for (final link in page.querySelectorAll('a[href]')) {
    final uri = Uri.tryParse(link.attributes['href']!);
    if (uri == null) continue;
    final target = OfficialSite.home.resolveUri(uri);
    if (!OfficialSite.trustedOrigin(target) ||
        target.userInfo.isNotEmpty ||
        target.fragment.isNotEmpty ||
        target.path != '/viewList.php') {
      continue;
    }
    final values = target.queryParametersAll['u'];
    if (values == null || values.length != 1 || !_validOwner(values.single)) {
      throw const CommunityException('format');
    }
    owners.add(values.single);
  }
  if (owners.map((id) => id.toLowerCase()).toSet().length > 1) {
    throw const CommunityException('stale');
  }
  final hasMenuId =
      menuId != null && menuId.isNotEmpty && menuId.toLowerCase() != 'guest';
  if (hasMenuId) {
    if (!_validOwner(menuId) || guest) {
      throw const CommunityException('format');
    }
    if (owners.any((id) => id.toLowerCase() != menuId.toLowerCase())) {
      throw const CommunityException('stale');
    }
  } else {
    if (guest && owners.isEmpty) return null;
    if (guest ||
        owners.isEmpty ||
        page.querySelector('.theme-title')?.text.contains('我的動畫') != true) {
      throw const CommunityException('format');
    }
  }
  final id = hasMenuId ? menuId : owners.first;
  final name = user?.querySelector('.user-name')?.text.trim();
  final img = user?.querySelector('.avatar img');
  final image = img?.attributes['data-src'] ?? img?.attributes['src'];
  final avatar = image == null ? null : OfficialSite.home.resolve(image);
  final profile = <String, dynamic>{
    'id': id,
    'displayName': name == null || name.isEmpty ? id : name,
    if (avatar != null &&
        OfficialSite.validImage(avatar.toString()) &&
        avatar.userInfo.isEmpty &&
        avatar.port == 443)
      'avatar': avatar.toString(),
  };
  AccountProfile.fromJson(profile);
  return profile;
}

bool _validOwner(String id) =>
    RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) &&
    id.toLowerCase() != 'guest';

/// The public profile contains current display data even when the Anime menu
/// is rendered by JavaScript or the login's nickname cookie is out of date.
Json officialPublicAccountProfile(Document page, {required String owner}) {
  final header = page.querySelector('.main-container_header_info');
  final identity = header
      ?.querySelector('.header_info-small small')
      ?.text
      .trim();
  final id = RegExp(
    r'^ID[：:]\s*([A-Za-z0-9_-]{1,64})$',
  ).firstMatch(identity ?? '')?[1];
  if (id == null || !_validOwner(id)) {
    throw const CommunityException('format');
  }
  if (id.toLowerCase() != owner.toLowerCase()) {
    throw const CommunityException('stale');
  }
  final name = header?.querySelector('h1')?.text.trim();
  final image = page.querySelector('#avatar_img');
  final raw = image?.attributes['data-src'] ?? image?.attributes['src'];
  if (name == null || name.isEmpty || raw == null || raw.trim().isEmpty) {
    throw const CommunityException('format');
  }
  final profile = <String, dynamic>{
    'id': owner,
    'displayName': name,
    'avatar': Uri.https('home.gamer.com.tw', '/').resolve(raw).toString(),
  };
  AccountProfile.fromJson(profile);
  return profile;
}
