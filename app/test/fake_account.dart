import 'dart:async';

import 'package:baha_plus/core/community.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/native_account_api.dart';

class FakeAccountApi extends NativeAccountApi {
  final communityRequests = <Json>[];
  Json communityResponse = {'ok': false, 'code': 'unavailable'};
  Completer<Json>? communityPending;
  Future<Json> Function(String, Json)? communityHandler;
  Future<Json?> Function()? accountLoader;
  Future<Json?> Function()? profileLoader;
  Future<void> Function(Anime, bool)? favoriteHandler;
  int accountReads = 0;
  int profileReads = 0;
  final favoriteRequests = <(String, bool)>[];

  @override
  Future<Json?> fetchProfile({void Function()? checkCurrent}) async {
    profileReads++;
    checkCurrent?.call();
    if (profileLoader == null) throw const CommunityException('unavailable');
    final result = await profileLoader!();
    checkCurrent?.call();
    return result;
  }

  @override
  Future<Json?> fetchAccount({
    void Function()? checkCurrent,
    String? expectedOwner,
    void Function(Json profile)? onAuthenticated,
  }) async {
    accountReads++;
    checkCurrent?.call();
    if (accountLoader == null) throw const CommunityException('unavailable');
    final result = await accountLoader!();
    checkCurrent?.call();
    if (result?['profile'] case final Json profile) {
      if (expectedOwner != null &&
          (profile['id'] as String).toLowerCase() !=
              expectedOwner.toLowerCase()) {
        throw const CommunityException('stale');
      }
      onAuthenticated?.call(profile);
    }
    return result;
  }

  @override
  Future<Json> community(
    String action,
    Json args, {
    required void Function() checkCurrent,
  }) async {
    checkCurrent();
    communityRequests.add({'action': action, ...args});
    final result = communityHandler != null
        ? await communityHandler!(action, args)
        : await (communityPending?.future ?? Future.value(communityResponse));
    if (communityReadActions.contains(action)) checkCurrent();
    return result;
  }

  @override
  Future<void> setFavorite(
    Anime anime,
    bool desired, {
    required String? owner,
    required void Function() checkCurrent,
  }) async {
    checkCurrent();
    favoriteRequests.add((anime.id, desired));
    if (favoriteHandler == null) throw const CommunityException('unavailable');
    await favoriteHandler!(anime, desired);
  }
}
