import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/official_app_api.dart';
import 'package:http/testing.dart';

/// Offline dependency for store/UI tests. Reads fail unless a test supplies data.
class FakeMetadata extends OfficialAppApi {
  FakeMetadata()
    : super(
        client: MockClient(
          (_) async => throw const OfficialAppApiException('offline-test'),
        ),
      );

  int catalogRequests = 0;
  final publicRequests = <Uri>[];
  Json publicResponse = {
    'data': {'animeList': []},
  };
  final detailRequests = <({String animeId, String videoId})>[];
  Future<Catalog> Function()? catalogLoader;
  Future<AnimeDetail> Function(String animeId, String videoId)? detailLoader;
  Future<RatingSummary?> Function(String fanId)? ratingLoader;
  Future<({List<Anime> items, bool hasMore})> Function(int page)? libraryLoader;

  @override
  Future<Catalog> fetchCatalog() async {
    catalogRequests++;
    if (catalogLoader case final load?) return load();
    throw const OfficialAppApiException('offline-test');
  }

  @override
  Future<AnimeDetail> fetchDetail({
    required String animeId,
    required String videoId,
    bool includeRating = true,
    Future<void>? cancel,
  }) async {
    detailRequests.add((animeId: animeId, videoId: videoId));
    if (detailLoader case final load?) return load(animeId, videoId);
    throw const OfficialAppApiException('offline-test');
  }

  @override
  Future<Json> fetchPublicCatalog(Uri uri, {Future<void>? cancel}) async {
    publicRequests.add(uri);
    return publicResponse;
  }

  @override
  Future<RatingSummary?> fetchRating(
    String fanId, {
    Future<void>? cancel,
  }) async {
    if (ratingLoader case final load?) return load(fanId);
    throw const OfficialAppApiException('offline-test');
  }

  @override
  Future<({List<Anime> items, bool hasMore})> fetchLibraryPage(
    int page, {
    Future<void>? cancel,
  }) async {
    if (libraryLoader case final load?) return load(page);
    return (items: const <Anime>[], hasMore: false);
  }
}
