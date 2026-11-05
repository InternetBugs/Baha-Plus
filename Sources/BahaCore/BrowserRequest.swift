import Foundation

public enum BrowserIntent: String, Sendable {
    case idle, catalog, search, detail, account, favorite, play, browse
    case accountRefresh = "account-refresh"
}

/// One request owns the document adapter and its asynchronous replies. Starting
/// or cancelling an operation creates a new identity, including repeated reads
/// of the same URL, so an old page can never complete a newer operation.
public struct BrowserRequest: Equatable, Sendable {
    public let id: String
    public let intent: BrowserIntent
    public let animeID: String?
    public let favoriteTarget: Bool?
    public let query: String?

    public init(intent: BrowserIntent, animeID: String? = nil, favoriteTarget: Bool? = nil,
                query: String? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.intent = intent
        self.animeID = animeID
        self.favoriteTarget = favoriteTarget
        self.query = query
    }

    public func accepts(channel: String, sourceURL: String?, isMainFrame: Bool?,
                        message: BrowserMessage) -> Bool {
        guard channel == "baha", isMainFrame == true, message.requestId == id,
              let sourceURL, let url = URL(string: sourceURL),
              url.scheme == "https", url.host == "ani.gamer.com.tw" else { return false }
        switch intent {
        case .catalog:
            return message.type == "catalog" && ["/", "/index.php"].contains(url.path)
        case .search:
            guard let query else { return false }
            let keyword = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "keyword" })?.value
            return message.type == "search" && url.path == "/search.php" &&
                keyword == String(query.prefix(100))
        case .detail: return ["detail", "detail-error"].contains(message.type)
        case .account, .accountRefresh:
            return ["account-synced", "account-guest", "account-error"].contains(message.type)
        case .favorite:
            return ["favorite-complete", "favorite-error", "account-guest", "account-error"].contains(message.type)
        case .idle, .play, .browse: return false
        }
    }
}

/// Only data crosses the page bridge. All navigation and mutation targets
/// remain the native request's validated IDs.
public struct BrowserMessage: Decodable, Sendable {
    public var type: String
    public var requestId: String?
    public var items: [Anime]?
    public var fetchedAt: String?
    public var id: String?
    public var saved: Bool?
    public var detail: AnimeDetail?
    public var favorites: [Anime]?
    public var history: [WatchEntry]?

    public func isValid(for request: BrowserRequest) -> Bool {
        guard requestId == request.id else { return false }
        switch type {
        case "catalog", "search":
            guard let items, let fetchedAt,
                  request.intent == (type == "catalog" ? .catalog : .search),
                  items.count <= 5000, items.allSatisfy(\.isValid),
                  Set(items.map(\.id)).count == items.count,
                  Catalog.validTimestamp(fetchedAt) else { return false }
            return type == "search" || !items.isEmpty
        case "detail":
            guard request.intent == .detail, let expected = request.animeID,
                  OfficialSite.validID(expected), id == expected, let detail else { return false }
            return detail.isValid
        case "detail-error":
            return request.intent == .detail && id == request.animeID && request.animeID != nil
        case "account-synced":
            guard [BrowserIntent.account, BrowserIntent.accountRefresh].contains(request.intent),
                  let favorites, let history, favorites.count <= 10000, history.count <= 1000,
                  favorites.allSatisfy(\.isValid), history.allSatisfy(\.isValid) else { return false }
            return Set(favorites.map(\.id)).count == favorites.count &&
                Set(history.map(\.id)).count == history.count
        case "favorite-complete":
            guard request.intent == .favorite, let expected = request.animeID,
                  OfficialSite.validID(expected), let target = request.favoriteTarget else { return false }
            return id == expected && saved == target
        case "favorite-error":
            return request.intent == .favorite && id == request.animeID && request.animeID != nil
        case "account-guest", "account-error":
            return [BrowserIntent.account, BrowserIntent.accountRefresh, BrowserIntent.favorite].contains(request.intent)
        default: return false
        }
    }
}
