import XCTest
@testable import BahaCore

final class CatalogCacheTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "baha.catalog.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testFreshInstallHasNoCatalog() {
        withDefaults { defaults in
            XCTAssertNil(CatalogCache.load(from: defaults))
        }
    }

    func testSuccessfulCatalogCanBeRestoredAndReplaced() throws {
        try withDefaults { defaults in
            let first = Catalog(items: [AppResources.snapshot.items[0]],
                                fetchedAt: "2026-11-04T13:45:00.000Z")
            CatalogCache.save(first, to: defaults)
            let restored = try XCTUnwrap(CatalogCache.load(from: defaults))
            XCTAssertEqual(restored.items, first.items)
            XCTAssertEqual(restored.fetchedAt, first.fetchedAt)

            let next = Catalog(items: [AppResources.snapshot.items[1]],
                               fetchedAt: "2026-11-05T03:00:00.000Z")
            CatalogCache.save(next, to: defaults)
            XCTAssertEqual(CatalogCache.load(from: defaults)?.items, next.items)
            XCTAssertEqual(CatalogCache.load(from: defaults)?.fetchedAt, next.fetchedAt)
        }
    }

    func testEmptyOrInvalidRefreshPreservesLastSuccessfulCatalog() {
        withDefaults { defaults in
            let previous = AppResources.snapshot
            CatalogCache.save(previous, to: defaults)
            var invalid = previous
            invalid.items[0].cover = "https://attacker.test/image.jpg"
            let duplicate = Catalog(items: [previous.items[0], previous.items[0]],
                                    fetchedAt: previous.fetchedAt)
            for rejected in [Catalog(items: [], fetchedAt: previous.fetchedAt),
                             Catalog(items: previous.items, fetchedAt: "invalid"), invalid, duplicate] {
                CatalogCache.save(rejected, to: defaults)
                XCTAssertEqual(CatalogCache.load(from: defaults)?.items, previous.items)
                XCTAssertEqual(CatalogCache.load(from: defaults)?.fetchedAt, previous.fetchedAt)
            }
        }
    }

    func testCorruptAndUntrustedCacheAreTreatedAsMissing() throws {
        try withDefaults { defaults in
            for value in ["", "{broken", "{\"items\":[],\"fetchedAt\":\"invalid\"}"] {
                defaults.set(value, forKey: CatalogCache.key)
                XCTAssertNil(CatalogCache.load(from: defaults))
            }
            var invalid = AppResources.snapshot
            invalid.items[0].cover = "https://attacker.test/image.jpg"
            let data = try JSONEncoder().encode(invalid)
            defaults.set(String(data: data, encoding: .utf8), forKey: CatalogCache.key)
            XCTAssertNil(CatalogCache.load(from: defaults))
        }
    }
}
