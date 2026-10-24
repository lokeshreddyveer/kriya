import XCTest
@testable import Kriya

final class UpdateLinksTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    func testTheFeedItselfIsNeverTheAnswer() {
        let feed = u("https://example.com/updates/appcast.xml")
        let page = UpdateLinks.page(for: .init(), feed: feed)
        XCTAssertEqual(page, u("https://example.com/"), "no page in the feed: the developer's site, not the XML")
        XCTAssertFalse(page.map(UpdateLinks.looksLikeFeed) ?? true)
    }

    func testTheVersionsOwnPageWinsThenItsNotes() {
        let feed = u("https://example.com/appcast.xml")
        XCTAssertEqual(UpdateLinks.page(for: .init(link: u("https://example.com/v2"), releaseNotes: u("https://example.com/notes")), feed: feed), u("https://example.com/v2"))
        XCTAssertEqual(UpdateLinks.page(for: .init(link: nil, releaseNotes: u("https://example.com/notes.html")), feed: feed), u("https://example.com/notes.html"))
        XCTAssertEqual(UpdateLinks.page(for: .init(link: u("https://example.com/changelog.xml"), releaseNotes: nil), feed: feed), u("https://example.com/"), "a link that is another feed is skipped")
    }

    func testGitHubFeedsGoToTheReleasesPage() {
        XCTAssertEqual(UpdateLinks.githubReleases(from: u("https://raw.githubusercontent.com/owner/app/main/appcast.xml")), u("https://github.com/owner/app/releases/latest"))
        XCTAssertEqual(UpdateLinks.githubReleases(from: u("https://github.com/owner/app/releases.atom")), u("https://github.com/owner/app/releases/latest"))
        XCTAssertEqual(UpdateLinks.githubReleases(from: u("https://owner.github.io/app/appcast.xml")), u("https://github.com/owner/app/releases/latest"))
        XCTAssertNil(UpdateLinks.githubReleases(from: u("https://example.com/appcast.xml")))
        XCTAssertEqual(UpdateLinks.page(for: .init(), feed: u("https://raw.githubusercontent.com/o/r/main/a.xml")), u("https://github.com/o/r/releases/latest"))
    }

    func testOnlyWebAddressesAreOpenedAndHostingServicesAreNotSiteRoots() {
        XCTAssertNil(UpdateLinks.web(u("file:///Applications/Evil.app")))
        XCTAssertNil(UpdateLinks.web(u("javascript:alert(1)")))
        XCTAssertNil(UpdateLinks.web(u("evil://run")))
        XCTAssertNotNil(UpdateLinks.web(u("http://example.com")))
        XCTAssertNil(UpdateLinks.siteRoot(of: u("https://bucket.s3.amazonaws.com/appcast.xml")))
        XCTAssertNil(UpdateLinks.page(for: .init(link: u("file:///tmp/x")), feed: u("https://d111.cloudfront.net/appcast.xml")), "nothing safe to open")
        XCTAssertEqual(UpdateLinks.page(for: .init(), feed: u("https://d111.cloudfront.net/appcast.xml"), appHomepage: u("https://app.example.org/")), u("https://app.example.org/"))
    }

    func testFeedLikeAddressesAreRecognised() {
        for s in ["https://a.com/appcast.xml", "https://a.com/releases.atom", "https://a.com/latest-mac.yml", "https://a.com/update.json", "https://a.com/feed"] { XCTAssertTrue(UpdateLinks.looksLikeFeed(u(s)), s) }
        XCTAssertFalse(UpdateLinks.looksLikeFeed(u("https://a.com/download/app")))
    }

    func testAppStorePagesOpenInTheAppStoreAndLookupAnswersAreRead() throws {
        XCTAssertEqual(UpdateLinks.appStoreURL(fromStorePage: "https://apps.apple.com/us/app/things/id904280696?mt=12&uo=4"), u("macappstore://apps.apple.com/us/app/things/id904280696"))
        XCTAssertNil(UpdateLinks.appStoreURL(fromStorePage: "https://example.com/id1"))
        XCTAssertNil(UpdateLinks.appStoreURL(fromStorePage: "https://evil.apple.com.example.org/app/id1"))
        XCTAssertNil(UpdateLinks.appStoreURL(fromStorePage: "https://support.apple.com/app/id1"), "only the App Store's own hosts")
        XCTAssertNil(UpdateLinks.appStoreURL(fromStorePage: "http://apps.apple.com/us/app/x/id1"), "https only")
        let answer = #"{"resultCount":1,"results":[{"version":"3.21","trackViewUrl":"https://apps.apple.com/us/app/things/id904280696?mt=12"}]}"#
        let entry = try XCTUnwrap(UpdateLinks.storeEntry(fromLookup: Data(answer.utf8)))
        XCTAssertEqual(entry.version, "3.21")
        XCTAssertNil(UpdateLinks.storeEntry(fromLookup: Data(#"{"resultCount":0,"results":[]}"#.utf8)))
        XCTAssertNil(UpdateLinks.storeEntry(fromLookup: Data("junk".utf8)))
    }
}
