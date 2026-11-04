import Foundation
import XCTest
@testable import BahaCore

final class BrowserRequestTests: XCTestCase {
    private let item: [String: Any] = [
        "id": "10", "title": "測試動畫",
        "cover": "https://p2.bahamut.com.tw/test.jpg", "sections": ["season"]
    ]
    private let date = "2026-11-04T13:45:00.000Z"

    private func message(_ type: String, request: BrowserRequest,
                         values: [String: Any] = [:]) throws -> BrowserMessage {
        var body = values
        body["type"] = type
        body["requestId"] = request.id
        return try JSONDecoder().decode(BrowserMessage.self,
            from: JSONSerialization.data(withJSONObject: body))
    }

    func testOnlyMainFrameOfOfficialAnimeOriginCanReply() throws {
        let request = BrowserRequest(intent: .catalog)
        let reply = try message("catalog", request: request, values: ["items": [item], "fetchedAt": date])
        XCTAssertTrue(request.accepts(channel: "baha", sourceURL: OfficialSite.origin + "/",
                                      isMainFrame: true, message: reply))
        for source in ["https://ani.gamer.com.tw.attacker.test/", "http://ani.gamer.com.tw/",
                       "https://user.gamer.com.tw/", "https://ani.gamer.com.tw@attacker.test/"] {
            XCTAssertFalse(request.accepts(channel: "baha", sourceURL: source,
                                           isMainFrame: true, message: reply))
        }
        XCTAssertFalse(request.accepts(channel: "other", sourceURL: OfficialSite.origin,
                                       isMainFrame: true, message: reply))
        XCTAssertFalse(request.accepts(channel: "baha", sourceURL: OfficialSite.origin,
                                       isMainFrame: false, message: reply))
        XCTAssertFalse(request.accepts(channel: "baha", sourceURL: OfficialSite.origin,
                                       isMainFrame: nil, message: reply))
    }

    func testLateReplyCannotCompleteAnotherRequestToTheSamePage() throws {
        let old = BrowserRequest(intent: .catalog)
        let current = BrowserRequest(intent: .catalog)
        let reply = try message("catalog", request: old, values: ["items": [item], "fetchedAt": date])
        XCTAssertFalse(current.accepts(channel: "baha", sourceURL: OfficialSite.origin + "/",
                                        isMainFrame: true, message: reply))
        XCTAssertFalse(reply.isValid(for: current))
    }

    func testIdleAndPlaybackRejectAllProjectionMessages() throws {
        for purpose in [BrowserIntent.idle, .play, .browse, .favorite] {
            let request = BrowserRequest(intent: purpose)
            let reply = try message("account-synced", request: request,
                                    values: ["favorites": [], "history": []])
            XCTAssertFalse(request.accepts(channel: "baha", sourceURL: OfficialSite.origin + "/",
                                            isMainFrame: true, message: reply))
            XCTAssertFalse(reply.isValid(for: request))
        }
    }

    func testEmptySearchIsAValidResultAndBelongsToItsSubmittedQuery() throws {
        let request = BrowserRequest(intent: .search, query: "魔法")
        let reply = try message("search", request: request, values: ["items": [], "fetchedAt": date])
        XCTAssertTrue(reply.isValid(for: request))
        XCTAssertTrue(request.accepts(channel: "baha", sourceURL: OfficialSite.searchURL("魔法")?.absoluteString,
                                      isMainFrame: true, message: reply))
        XCTAssertFalse(request.accepts(channel: "baha", sourceURL: OfficialSite.searchURL("別的作品")?.absoluteString,
                                       isMainFrame: true, message: reply))
        XCTAssertFalse(request.accepts(channel: "baha", sourceURL: OfficialSite.origin + "/",
                                       isMainFrame: true, message: reply))
    }

    func testEmptyCatalogDuplicateIdentityAndInvalidDateAreRejected() throws {
        let request = BrowserRequest(intent: .catalog)
        XCTAssertFalse(try message("catalog", request: request,
                                   values: ["items": [], "fetchedAt": date]).isValid(for: request))
        XCTAssertFalse(try message("catalog", request: request,
                                   values: ["items": [item, item], "fetchedAt": date]).isValid(for: request))
        XCTAssertFalse(try message("catalog", request: request,
                                   values: ["items": [item], "fetchedAt": "yesterday"]).isValid(for: request))
        XCTAssertTrue(try message("catalog", request: request,
                                  values: ["items": [item], "fetchedAt": date]).isValid(for: request))
    }

    func testDetailMatchesSeriesAndDoesNotAcceptForeignArtworkOrDuplicateEpisodes() throws {
        let request = BrowserRequest(intent: .detail, animeID: "10")
        var detail: [String: Any] = [
            "title": "測試動畫", "description": "簡介", "metadata": [],
            "episodes": [["id": "20", "label": "1"]]
        ]
        XCTAssertTrue(try message("detail", request: request,
                                  values: ["id": "10", "detail": detail]).isValid(for: request))
        XCTAssertFalse(try message("detail", request: request,
                                   values: ["id": "11", "detail": detail]).isValid(for: request))
        detail["poster"] = "https://attacker.test/picture.jpg"
        XCTAssertFalse(try message("detail", request: request,
                                   values: ["id": "10", "detail": detail]).isValid(for: request))
        detail.removeValue(forKey: "poster")
        detail["episodes"] = [["id": "20", "label": "1"], ["id": "20", "label": "2"]]
        XCTAssertFalse(try message("detail", request: request,
                                   values: ["id": "10", "detail": detail]).isValid(for: request))
    }

    func testCloudAccountProgressIsValidatedAndAnEmptyAccountIsAllowed() throws {
        let request = BrowserRequest(intent: .accountRefresh)
        let entry: [String: Any] = [
            "anime": item, "videoId": "20", "episodeLabel": "5",
            "progress": 0.64, "progressLabel": "觀看至 14 分 41 秒"
        ]
        XCTAssertTrue(try message("account-synced", request: request,
                                  values: ["favorites": [item], "history": [entry]]).isValid(for: request))
        XCTAssertTrue(try message("account-synced", request: request,
                                  values: ["favorites": [], "history": []]).isValid(for: request))
        var bad = entry
        bad["progress"] = 1.2
        XCTAssertFalse(try message("account-synced", request: request,
                                   values: ["favorites": [item], "history": [bad]]).isValid(for: request))
        XCTAssertFalse(try message("account-synced", request: request,
                                   values: ["favorites": [item, item], "history": []]).isValid(for: request))
    }

    func testFavoriteCompletionMustConfirmTheExactRequestedStateAndSeries() throws {
        let request = BrowserRequest(intent: .favorite, animeID: "10", favoriteTarget: true)
        XCTAssertTrue(try message("favorite-complete", request: request,
                                  values: ["id": "10", "saved": true]).isValid(for: request))
        XCTAssertFalse(try message("favorite-complete", request: request,
                                   values: ["id": "10", "saved": false]).isValid(for: request))
        XCTAssertFalse(try message("favorite-complete", request: request,
                                   values: ["id": "11", "saved": true]).isValid(for: request))
        XCTAssertFalse(try message("favorite-complete", request: request,
                                   values: ["id": "10"]).isValid(for: request))
    }
}
