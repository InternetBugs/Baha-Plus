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
  }) async {
    detailRequests.add((animeId: animeId, videoId: videoId));
    if (detailLoader case final load?) return load(animeId, videoId);
    throw const OfficialAppApiException('offline-test');
  }

  @override
  Future<Json> fetchPublicCatalog(Uri uri) async {
    publicRequests.add(uri);
    return publicResponse;
  }
}
