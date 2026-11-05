import Foundation

public enum AppResources {
    public static func data(_ resource: String) -> Data? {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
    public static func dictionary(_ name: String) -> [String: String] {
        guard let data = data(name) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    public static var snapshot: Catalog {
        guard let data = data("catalog-snapshot"),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(items: [], fetchedAt: "2026-11-04T13:45:00.000Z")
        }
        return catalog
    }
}

public enum SearchFolding {
    private static let mapping = AppResources.dictionary("search-folding")
    public static func normalize(_ string: String) -> String {
        #if SKIP
        let normalized: String = java.text.Normalizer.normalize(string, java.text.Normalizer.Form.NFKC)
        #else
        let normalized: String = string.precomposedStringWithCompatibilityMapping
        #endif
        var result = ""
        for character in normalized.lowercased() {
            let part = String(character)
            let folded = mapping[part] ?? part
            result += folded
        }
        #if SKIP
        let filtered: String = result.replace(kotlin.text.Regex("[^\\p{L}\\p{N}\\p{M}]"), "")
        #else
        let filtered = result.replacingOccurrences(of: "[^\\p{L}\\p{N}\\p{M}]",
                                                   with: "", options: .regularExpression)
        #endif
        return filtered.replacingOccurrences(of: "计画", with: "计划")
    }
    public static func matches(_ title: String, query: String) -> Bool {
        normalize(title).contains(normalize(query))
    }
}
