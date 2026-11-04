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
        var result = ""
        for character in string.lowercased() {
            let part = String(character)
            let folded = mapping[part] ?? part
            if folded.rangeOfCharacter(from: .letters) != nil ||
                folded.rangeOfCharacter(from: .decimalDigits) != nil {
                result += folded
            }
        }
        return result.replacingOccurrences(of: "计画", with: "计划")
    }
    public static func matches(_ title: String, query: String) -> Bool {
        normalize(title).contains(normalize(query))
    }
}
