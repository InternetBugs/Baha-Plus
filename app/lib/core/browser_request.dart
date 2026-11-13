import 'dart:convert';
import 'dart:math';
import 'models.dart';

enum BrowserIntent { idle, detail, account, logout, play, browse }

class BrowserRequest {
  BrowserRequest({required this.intent, this.animeId, this.videoId, String? id})
    : id =
          id ??
          List.generate(
            24,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();

  final BrowserIntent intent;
  final String id;
  final String? animeId, videoId;

  Json? accept(
    String raw, {
    required Uri origin,
    required Uri source,
    required bool isMainFrame,
  }) {
    if (!isMainFrame ||
        !OfficialSite.trustedOrigin(origin) ||
        !OfficialSite.trustedOrigin(source) ||
        utf8.encode(raw).length >= 5000000) {
      return null;
    }
    try {
      final body = jsonDecode(raw) as Json;
      if (body['requestId'] != id) return null;
      final type = body['type'];
      if (type == 'verification-required') {
        return const [
              BrowserIntent.detail,
              BrowserIntent.account,
              BrowserIntent.logout,
            ].contains(intent)
            ? body
            : null;
      }
      switch (intent) {
        case BrowserIntent.detail:
          if (body['id'] != animeId ||
              animeId == null ||
              !OfficialSite.validId(animeId!)) {
            return null;
          }
          if (type == 'detail') {
            AnimeDetail.fromJson(body['detail'] as Json);
          } else if (type != 'detail-error') {
            return null;
          }
        case BrowserIntent.account:
        case BrowserIntent.logout:
          if (intent == BrowserIntent.logout &&
              source.path != '/mygather.php') {
            return null;
          }
          if (type == 'account-authenticated') {
            AccountProfile.fromJson(body['profile'] as Json);
          } else if (type != 'account-guest' && type != 'account-error') {
            return null;
          }
        case BrowserIntent.play:
        case BrowserIntent.idle:
        case BrowserIntent.browse:
          return null;
      }
      return body;
    } catch (_) {
      return null;
    }
  }
}
