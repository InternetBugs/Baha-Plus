#if SKIP || os(iOS)
import Foundation
import Observation
import SwiftUI
import BahaCore
import SkipWeb

@MainActor @Observable
final class AppStore: WebViewScriptMessageDelegate {
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "baha.device.language") }
    }
    var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: "baha.device.appearance") }
    }
    var tab = 0
    var catalog = AppResources.snapshot
    var catalogSource = "snapshot"
    var favorites: [Anime] = []
    var history: [WatchEntry] = []
    var accountSynced = false
    var accountNeedsRefresh = false
    var selectedAnime: Anime?
    var detail: AnimeDetail?
    var detailLoading = false
    var detailFailed = false
    var query = "" {
        didSet { if query != oldValue { searchResults = []; searchedQuery = "" } }
    }
    var searchResults: [Anime] = []
    var searchedQuery = ""
    var libraryFilter = "all"
    var browserVisible = false
    var browserTitle = ""
    var browserError = false
    var busy = false
    var notice: String?
    var browserState = WebViewState()
    let navigator = WebViewNavigator(initialURL: URL(string: OfficialSite.origin))
    let configuration: WebEngineConfiguration

    private var operation = BrowserRequest(intent: .catalog)
    private var intent: BrowserIntent { operation.intent }
    private var nonce: String { operation.id }
    @ObservationIgnored private var pendingAnime: Anime?
    @ObservationIgnored private var desiredFavorite = false
    @ObservationIgnored private var deadline: Task<Void, Never>?
    private let traditional = AppResources.dictionary("zh-Hant")
    private let simplified = AppResources.dictionary("zh-Hans")

    init() {
        language = UserDefaults.standard.string(forKey: "baha.device.language") ??
            DevicePreferences.languageForSystem(Locale.preferredLanguages.first ?? "zh-Hant")
        appearance = UserDefaults.standard.string(forKey: "baha.device.appearance") ?? "system"
        configuration = WebEngineConfiguration(
            javaScriptCanOpenWindowsAutomatically: false,
            allowsInlineMediaPlayback: true,
            scriptMessageHandlerNames: ["baha"],
            capturesConsoleOutput: false
        )
        configuration.scriptMessageDelegate = self
    }

    func text(_ key: String) -> String {
        (language == "zh-Hans" ? simplified[key] : traditional[key]) ?? key
    }
    var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
    var seasonal: [Anime] { catalog.items.filter { $0.sections.contains("season") } }
    var popular: [Anime] { catalog.items.filter { $0.sections.contains("hot") } }
    var filteredLibrary: [Anime] {
        let source = libraryFilter == "favorites" ? favorites : catalog.items
        var result = source.filter {
            (libraryFilter == "all" || libraryFilter == "favorites" || $0.sections.contains(libraryFilter)) &&
            SearchFolding.matches($0.title, query: query)
        }
        if libraryFilter != "favorites" && !query.isEmpty && searchedQuery == query {
            for anime in searchResults where !result.contains(where: { $0.id == anime.id }) &&
                (libraryFilter == "all" || anime.sections.contains(libraryFilter)) {
                result.append(anime)
            }
        }
        return result
    }
    var canRetryFavorite: Bool { intent == .favorite }
    func isFavorite(_ anime: Anime) -> Bool { favorites.contains { $0.id == anime.id } }

    func refreshCatalog() {
        guard !browserVisible else { return }
        load(URL(string: OfficialSite.origin)!, purpose: .catalog, visible: false)
    }
    func openDetail(_ anime: Anime) {
        selectedAnime = anime; detail = nil; detailFailed = false; detailLoading = true
        pendingAnime = anime
        guard OfficialSite.validID(anime.id) else { navigationFailed(); return }
        if browserState.url?.host == "ani.gamer.com.tw" {
            begin(.detail)
            runScript("detail", replacements: ["%ANIME_ID%": anime.id])
            armDeadline()
        } else {
            load(URL(string: OfficialSite.origin)!, purpose: .detail, visible: false)
        }
    }
    func search() {
        guard libraryFilter != "favorites", !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = OfficialSite.searchURL(query) else { return }
        searchedQuery = query
        load(url, purpose: .search, visible: false)
    }
    func openOfficialSearch() {
        guard let url = OfficialSite.searchURL(query) else { return }
        load(url, purpose: .browse, visible: true)
    }
    func connectAccount() {
        selectedAnime = nil
        // A login or account switch makes the old projection unverified.
        // Never display a previous account's collection after leaving the portal.
        favorites = []; history = []; accountSynced = false
        browserTitle = text("officialAccount")
        load(URL(string: "\(OfficialSite.origin)/mygather.php")!, purpose: .account, visible: true)
    }
    func toggleFavorite(_ anime: Anime) {
        pendingAnime = anime; desiredFavorite = !isFavorite(anime); selectedAnime = nil
        browserTitle = text("favorites")
        guard OfficialSite.validID(anime.id), let url = OfficialSite.searchURL(anime.title) else { return }
        // The official search card has the same subscription control, without
        // instantiating a video player merely to change a collection.
        load(url, purpose: .favorite, visible: true)
    }
    func play(_ anime: Anime, episode: Episode? = nil) {
        selectedAnime = nil; pendingAnime = anime
        let url = episode.flatMap { OfficialSite.videoURL($0.id) } ??
            anime.latestVideoId.flatMap { OfficialSite.videoURL($0) } ?? OfficialSite.seriesURL(anime.id)
        guard let url else { return }
        browserTitle = anime.title
        accountNeedsRefresh = true
        load(url, purpose: .play, visible: true)
    }
    func continueWatching(_ entry: WatchEntry) {
        selectedAnime = nil; pendingAnime = entry.anime
        guard let url = OfficialSite.videoURL(entry.videoId) else { return }
        browserTitle = entry.anime.title; accountNeedsRefresh = true
        load(url, purpose: .play, visible: true)
    }
    func closeBrowser() {
        let closedDocument = nonce
        let refresh = accountNeedsRefresh
        browserVisible = false
        begin(.idle)
        busy = false
        let closingRequest = nonce
        Task {
            guard nonce == closingRequest else { return }
            if let tokenData = try? JSONEncoder().encode(closedDocument),
               let token = String(data: tokenData, encoding: .utf8) {
                _ = try? await navigator.evaluateJavaScript("""
                if (window.__bahaDocumentNonce === \(token)) {
                  document.querySelectorAll('video,audio').forEach(function(m){m.pause()});
                } true;
                """)
            }
            if refresh {
                // Let the official player's pause handler submit its progress.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard nonce == closingRequest && !browserVisible else { return }
                syncAccount()
            }
        }
    }
    func syncAccount() {
        guard browserState.url?.host == "ani.gamer.com.tw" else {
            notice = text("accountHint"); busy = false; return
        }
        begin(.accountRefresh)
        notice = nil; busy = true
        runScript("account-sync")
        armDeadline()
    }
    func retryFavorite() {
        guard intent == .favorite, let anime = pendingAnime, OfficialSite.validID(anime.id) else { return }
        runScript("favorite-action", replacements: [
            "%ANIME_ID%": anime.id, "__BAHA_DESIRED__": desiredFavorite ? "true" : "false"
        ])
    }

    private func begin(_ purpose: BrowserIntent) {
        deadline?.cancel()
        operation = BrowserRequest(
            intent: purpose,
            animeID: [.detail, .favorite].contains(purpose) ? pendingAnime?.id : nil,
            favoriteTarget: purpose == .favorite ? desiredFavorite : nil,
            query: purpose == .search ? query : nil
        )
    }
    private func load(_ url: URL, purpose: BrowserIntent, visible: Bool) {
        guard OfficialSite.allowedNavigation(url) else { return }
        begin(purpose)
        browserError = false; notice = nil; busy = true; browserVisible = visible
        navigator.initialURL = url
        navigator.load(url: url)
        if !visible { armDeadline() }
    }
    func navigationFinished() {
        guard browserState.url?.host == "ani.gamer.com.tw" else { busy = false; return }
        switch intent {
        case .catalog: runScript("catalog", replacements: ["%KIND%": "catalog"])
        case .search: runScript("catalog", replacements: ["%KIND%": "search"])
        case .detail:
            if let anime = pendingAnime { runScript("detail", replacements: ["%ANIME_ID%": anime.id]) }
        case .account, .accountRefresh: syncAccount()
        case .favorite: retryFavorite(); busy = false
        default:
            stampDocument()
            busy = false
        }
    }
    func navigationFailed() {
        // Revoke callbacks from a failed or expired operation. A reload can retry
        // the same intent, but an old asynchronous reply no longer owns it.
        let failed = operation
        deadline?.cancel()
        operation = BrowserRequest(intent: failed.intent, animeID: failed.animeID,
                                   favoriteTarget: failed.favoriteTarget, query: failed.query)
        busy = false; browserError = browserVisible
        if intent == .detail { detailLoading = false; detailFailed = true }
    }
    private func armDeadline() {
        deadline?.cancel()
        let expected = nonce
        deadline = Task {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard nonce == expected else { return }
            let account = [.account, .accountRefresh].contains(intent)
            navigationFailed()
            if account { notice = text("accountSyncError") }
        }
    }
    private func runScript(_ name: String, replacements: [String: String] = [:]) {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
              var script = try? String(contentsOf: url, encoding: .utf8),
              let tokenData = try? JSONEncoder().encode(nonce),
              let token = String(data: tokenData, encoding: .utf8) else { navigationFailed(); return }
        for (key, value) in replacements { script = script.replacingOccurrences(of: key, with: value) }
        let prefix = """
        (function() {
        window.__bahaDocumentNonce = \(token);
        function bahaPostJSON(raw) {
          var body = JSON.parse(raw); body.requestId = \(token);
          window.webkit.messageHandlers.baha.postMessage(body);
        }
        """
        let expected = nonce
        let fullScript = prefix + "\n" + script + "\n})(); true;"
        Task {
            guard nonce == expected else { return }
            do { _ = try await navigator.evaluateJavaScript(fullScript) }
            catch { if nonce == expected { navigationFailed() } }
        }
    }
    private func stampDocument() {
        guard let data = try? JSONEncoder().encode(nonce),
              let token = String(data: data, encoding: .utf8) else { return }
        let expected = nonce
        Task {
            guard nonce == expected else { return }
            _ = try? await navigator.evaluateJavaScript("window.__bahaDocumentNonce = \(token); true;")
        }
    }

    func webEngine(_ webEngine: WebEngine, didReceiveScriptMessage message: WebViewScriptMessage) {
        guard message.bodyJSON.utf8.count < 5_000_000,
              let data = message.bodyJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrowserMessage.self, from: data),
              operation.accepts(channel: message.name, sourceURL: message.sourceURL,
                                isMainFrame: message.isMainFrame, message: payload) else { return }
        guard payload.isValid(for: operation) else { navigationFailed(); return }
        let completed = operation
        switch payload.type {
        case "catalog", "search":
            guard let items = payload.items, let fetchedAt = payload.fetchedAt else { return }
            deadline?.cancel(); busy = false
            if payload.type == "catalog" {
                catalog = Catalog(items: items, fetchedAt: fetchedAt); catalogSource = "live"
                syncAccount()
            } else {
                searchResults = items
                searchedQuery = completed.query ?? ""
                begin(.idle)
            }
        case "detail":
            guard let value = payload.detail else { return }
            detail = value; detailLoading = false; busy = false; begin(.idle)
        case "detail-error":
            navigationFailed()
        case "account-synced":
            guard let items = payload.favorites, let entries = payload.history else { return }
            favorites = items; history = entries; accountSynced = true; accountNeedsRefresh = false
            busy = false; begin(.idle); browserVisible = false
        case "account-guest":
            favorites = []; history = []; accountSynced = false; accountNeedsRefresh = false
            busy = false; deadline?.cancel()
            if browserVisible { notice = text("accountHint") } else { begin(.idle) }
        case "account-error":
            busy = false; deadline?.cancel(); notice = text("accountSyncError")
        case "favorite-complete":
            // Never change native collection optimistically. Re-read the account.
            notice = text(desiredFavorite ? "added" : "removed")
            syncAccount()
        case "favorite-error":
            busy = false; notice = text("accountSyncError")
        default: break
        }
    }
}
#endif
