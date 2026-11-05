import XCTest
@testable import BahaCore

final class BahaCoreTests: XCTestCase {
    func testOfficialNavigationDoesNotAcceptLookalikeHosts() {
        XCTAssertNotNil(OfficialSite.seriesURL("114190"))
        XCTAssertNil(OfficialSite.seriesURL("1&url=evil"))
        XCTAssertFalse(OfficialSite.allowedNavigation(URL(string: "https://gamer.com.tw.attacker.test")!))
        XCTAssertFalse(OfficialSite.allowedNavigation(URL(string: "http://ani.gamer.com.tw")!))
        XCTAssertTrue(OfficialSite.allowedNavigation(URL(string: "https://user.gamer.com.tw/login.php")!))
    }
    func testSearchUsesOfficialKeywordParameter() {
        let url = OfficialSite.searchURL("魔法 少女")!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "keyword")
    }
    func testSnapshotAndLanguagesAreComplete() {
        XCTAssertTrue(AppResources.snapshot.items.allSatisfy(\.isValid))
        XCTAssertFalse(AppResources.snapshot.items.isEmpty)
        XCTAssertEqual(Set(AppResources.dictionary("zh-Hans").keys), Set(AppResources.dictionary("zh-Hant").keys))
    }
    func testSearchAcceptsBothScripts() {
        XCTAssertTrue(SearchFolding.matches("世界最強的魔女，就此開始", query: "世界最强的魔女"))
        XCTAssertTrue(SearchFolding.matches("魔法少女育成計畫 restart", query: "育成计划"))
    }
    func testSearchHandlesUnicodeWidthAndSupplementaryCharacters() {
        XCTAssertTrue(SearchFolding.matches("Fate/strange Fake", query: "Ｆａｔｅ　ｓｔｒａｎｇｅ"))
        XCTAssertEqual(SearchFolding.normalize("𠮷-野"), "𠮷野")
        XCTAssertEqual(SearchFolding.normalize("e\u{301}"), SearchFolding.normalize("é"))
    }
    func testIdentifiersRemainStrictlyASCIIDigits() {
        XCTAssertTrue(OfficialSite.validID("12345"))
        XCTAssertFalse(OfficialSite.validID("１２３"))
        XCTAssertFalse(OfficialSite.validID("1 2"))
        XCTAssertFalse(OfficialSite.validID(""))
    }
    func testWatchProgressRejectsNonFiniteAndOutOfRangeValues() {
        let anime = AppResources.snapshot.items[0]
        for value in [Double.nan, Double.infinity, -Double.infinity, -0.01, 1.01] {
            let entry = WatchEntry(anime: anime, videoId: "20", episodeLabel: "1",
                                   progress: value, progressLabel: nil)
            XCTAssertFalse(entry.isValid)
        }
        for value in [0.0, 0.64, 1.0] {
            let entry = WatchEntry(anime: anime, videoId: "20", episodeLabel: "1",
                                   progress: value, progressLabel: nil)
            XCTAssertTrue(entry.isValid)
        }
    }
    func testPreferencesHaveNoLocalAccountData() throws {
        let data = try JSONEncoder().encode(DevicePreferences(language: "zh-Hans", appearance: "dark"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(Set(object.keys), Set(["language", "appearance"]))
        XCTAssertEqual(DevicePreferences.languageForSystem("zh-TW"), "zh-Hant")
        XCTAssertEqual(DevicePreferences.languageForSystem("zh-Hans-US"), "zh-Hans")
    }
}
