import Foundation

/// Stores only a validated public catalog. Account data stays in the official session.
public enum CatalogCache {
    public static let key = ["baha", "catalog", "v1"].joined(separator: ".")

    public static func load(from defaults: UserDefaults = .standard) -> Catalog? {
        guard let value = defaults.string(forKey: key),
              value.utf8.count < 5_000_000,
              let data = value.data(using: .utf8),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.isValid else { return nil }
        return catalog
    }

    public static func save(_ catalog: Catalog, to defaults: UserDefaults = .standard) {
        guard catalog.isValid,
              let data = try? JSONEncoder().encode(catalog),
              data.count < 5_000_000,
              let value = String(data: data, encoding: .utf8) else { return }
        defaults.set(value, forKey: key)
    }
}
