import Foundation

public struct Anime: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var cover: String
    public var poster: String?
    public var latestVideoId: String?
    public var episodeLabel: String?
    public var updateDay: Int?
    public var updateTime: String?
    public var views: String?
    public var year: String?
    public var sections: [String]

    public init(id: String, title: String, cover: String, poster: String? = nil,
                latestVideoId: String? = nil, episodeLabel: String? = nil,
                updateDay: Int? = nil, updateTime: String? = nil, views: String? = nil,
                year: String? = nil, sections: [String] = []) {
        self.id = id; self.title = title; self.cover = cover; self.poster = poster
        self.latestVideoId = latestVideoId; self.episodeLabel = episodeLabel
        self.updateDay = updateDay; self.updateTime = updateTime; self.views = views
        self.year = year; self.sections = sections
    }

    public var isValid: Bool {
        OfficialSite.validID(id) && !title.isEmpty && title.count < 500 &&
        OfficialSite.validImage(cover) && (poster == nil || OfficialSite.validImage(poster ?? "")) &&
        (latestVideoId == nil || OfficialSite.validID(latestVideoId ?? "")) &&
        sections.allSatisfy { ["season", "hot", "new"].contains($0) }
    }
    public var coverURL: URL? { URL(string: cover) }
    public var posterURL: URL? { URL(string: poster ?? cover) }
}

public struct Catalog: Codable, Sendable {
    public var items: [Anime]
    public var fetchedAt: String
    public init(items: [Anime], fetchedAt: String) {
        self.items = items; self.fetchedAt = fetchedAt
    }
    public var isValid: Bool {
        !items.isEmpty && items.count <= 5000 && items.allSatisfy(\.isValid) &&
            Set(items.map(\.id)).count == items.count && Self.validTimestamp(fetchedAt)
    }
    public static func validTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }
}

public struct Episode: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var label: String
}
public struct Metadata: Hashable, Codable, Sendable {
    public var label: String
    public var value: String
}
public struct AnimeDetail: Codable, Sendable {
    public var title: String
    public var description: String
    public var poster: String?
    public var metadata: [Metadata]
    public var episodes: [Episode]
    public var isValid: Bool {
        !title.isEmpty && title.count < 500 && description.count <= 200000 &&
        (poster == nil || OfficialSite.validImage(poster ?? "")) &&
        metadata.count <= 100 && metadata.allSatisfy { $0.label.count <= 200 && $0.value.count <= 4000 } &&
        episodes.count <= 5000 && episodes.allSatisfy { OfficialSite.validID($0.id) && $0.label.count <= 100 } &&
        Set(episodes.map(\.id)).count == episodes.count
    }
}
public struct WatchEntry: Identifiable, Hashable, Codable, Sendable {
    public var anime: Anime
    public var videoId: String
    public var episodeLabel: String
    public var progress: Double?
    public var progressLabel: String?
    public var id: String { anime.id }
    public var isValid: Bool {
        guard anime.isValid, OfficialSite.validID(videoId),
              episodeLabel.count <= 200, (progressLabel?.count ?? 0) <= 2000 else { return false }
        guard let value = progress else { return true }
        return value >= 0.0 && value <= 1.0
    }
}

public enum OfficialSite {
    public static let origin = "https://ani.gamer.com.tw"
    public static func validID(_ id: String) -> Bool {
        if id.isEmpty || id.count > 10 { return false }
        for character in id {
            if !"0123456789".contains(String(character)) { return false }
        }
        return true
    }
    public static func seriesURL(_ id: String) -> URL? {
        validID(id) ? URL(string: "\(origin)/animeRef.php?sn=\(id)") : nil
    }
    public static func videoURL(_ id: String) -> URL? {
        validID(id) ? URL(string: "\(origin)/animeVideo.php?sn=\(id)") : nil
    }
    public static func searchURL(_ query: String) -> URL? {
        var components = URLComponents(string: "\(origin)/search.php")
        components?.queryItems = [URLQueryItem(name: "keyword", value: String(query.prefix(100)))]
        return components?.url
    }
    public static func allowedNavigation(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return host == "gamer.com.tw" || host.hasSuffix(".gamer.com.tw")
    }
    public static func validImage(_ string: String) -> Bool {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host else { return false }
        return host.hasSuffix(".bahamut.com.tw")
    }
}

/// Device preferences are independent of the public catalog cache.
/// Account collections and progress remain transient official session projections.
public struct DevicePreferences: Codable, Sendable {
    public var language: String
    public var appearance: String
    public init(language: String = "zh-Hant", appearance: String = "system") {
        self.language = language; self.appearance = appearance
    }
    public static func languageForSystem(_ tag: String) -> String {
        let normalized = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.contains("hans") || normalized.contains("-cn") ||
            normalized.contains("-sg") || normalized.contains("-my") ? "zh-Hans" : "zh-Hant"
    }
}
