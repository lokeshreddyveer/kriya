import XCTest
@testable import Kriya

final class AppInsightTests: XCTestCase {
    private func facts(_ mutate: (inout AppSourceFacts) -> Void = { _ in }) -> AppSourceFacts {
        var f = AppSourceFacts(path: "/Applications/Foo.app", bundleID: "com.foo.app")
        mutate(&f)
        return f
    }

    // MARK: Source detection

    func testStoreReceiptIsVerifiedAppStore() {
        let r = AppSourceDetector.detect(facts { $0.hasStoreReceipt = true })
        XCTAssertEqual(r.source, .appStore); XCTAssertEqual(r.confidence, .verified)
    }

    func testSparkleFeedIsVerifiedAndGitHubFeedIsLabelledGitHub() {
        let s = AppSourceDetector.detect(facts { $0.sparkleFeed = URL(string: "https://foo.com/appcast.xml") })
        XCTAssertEqual(s.source, .sparkle); XCTAssertEqual(s.confidence, .verified)
        let g = AppSourceDetector.detect(facts { $0.sparkleFeed = URL(string: "https://raw.githubusercontent.com/foo/foo/appcast.xml") })
        XCTAssertEqual(g.source, .github)
    }

    func testHomebrewIsDetectedAndBeatsAFeedBecauseBrewOwnsTheInstall() {
        let r = AppSourceDetector.detect(facts { $0.inHomebrewCaskroom = true; $0.sparkleFeed = URL(string: "https://foo.com/x.xml") })
        XCTAssertEqual(r.source, .homebrew); XCTAssertEqual(r.confidence, .detected)
    }

    func testElectronNeedsAConfigToBeVerified() {
        XCTAssertEqual(AppSourceDetector.detect(facts { $0.hasElectron = true }).confidence, .inferred)
        let github = AppSourceDetector.detect(facts { $0.hasElectron = true; $0.electronProvider = "github" })
        XCTAssertEqual(github.source, .github); XCTAssertEqual(github.confidence, .verified)
        let generic = AppSourceDetector.detect(facts { $0.hasElectron = true; $0.electronProvider = "generic" })
        XCTAssertEqual(generic.source, .electron); XCTAssertEqual(generic.confidence, .verified)
    }

    func testFrameworkAloneIsOnlyInferredAndNothingIsUnknown() {
        let s = AppSourceDetector.detect(facts { $0.hasSparkleFramework = true })
        XCTAssertEqual(s.source, .sparkle); XCTAssertEqual(s.confidence, .inferred)
        let none = AppSourceDetector.detect(facts())
        XCTAssertEqual(none.source, .direct); XCTAssertEqual(none.confidence, .unknown)
    }

    func testSystemIosAndWebApps() {
        XCTAssertEqual(AppSourceDetector.detect(facts { $0.path = "/System/Applications/Notes.app"; $0.bundleID = "com.apple.Notes" }).source, .system)
        XCTAssertEqual(AppSourceDetector.detect(facts { $0.isIOSWrapper = true; $0.bundleID = "com.example.phone" }).source, .iosApp)
        XCTAssertEqual(AppSourceDetector.detect(facts { $0.isWebApp = true }).source, .webApp)
        XCTAssertEqual(AppSourceDetector.detect(facts { $0.bundleID = "com.apple.dt.Xcode"; $0.hasStoreReceipt = true }).source, .appStore, "an Apple app from the store is a store app")
    }

    // MARK: Architecture

    private func be(_ values: [UInt32]) -> Data { Data(values.flatMap { v in [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }) }

    func testFatHeaderWithBothProcessorsIsUniversal() {
        // magic, count, then per entry: cputype, subtype, offset, size, align
        let fat = be([0xCAFEBABE, 2, 0x01000007, 3, 4096, 100, 12, 0x0100000C, 0, 8192, 100, 14])
        let set = AppArchitecture.parse(header: fat)
        XCTAssertEqual(set, [.arm64, .x86_64])
        XCTAssertEqual(AppArchitecture.badge(set), "Universal")
    }

    func testThinHeadersAreReadLittleEndian() {
        let arm = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0, 0, 0, 0])
        XCTAssertEqual(AppArchitecture.parse(header: arm), [.arm64])
        XCTAssertEqual(AppArchitecture.badge([.arm64]), "Apple silicon")
        let intel = Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01, 0, 0, 0, 0])
        XCTAssertEqual(AppArchitecture.badge(AppArchitecture.parse(header: intel)), "Intel only")
    }

    func testJunkAndHugeCountsGiveNothing() {
        XCTAssertTrue(AppArchitecture.parse(header: Data("#!/bin/sh\necho".utf8)).isEmpty)
        XCTAssertTrue(AppArchitecture.parse(header: Data()).isEmpty)
        XCTAssertTrue(AppArchitecture.parse(header: be([0xCAFEBABE, 9999, 0, 0])).isEmpty, "a Java class file also starts CAFEBABE; a count that high is not a processor list")
        XCTAssertNil(AppArchitecture.badge([]))
    }

    // MARK: Leftover evidence

    func testOnlyExactBundleIdentifiersAreStrongAndOnlyThoseAreTicked() {
        func ev(_ file: String, folder: String = "Application Support", team: String? = nil) -> LeftoverEvidence? {
            LeftoverClassifier.evidence(fileName: file, folder: folder, bundleID: "com.foo.Editor", appName: "Editor Pro", teamID: team)
        }
        XCTAssertEqual(ev("com.foo.Editor"), .bundleID)
        XCTAssertEqual(ev("com.foo.Editor.plist", folder: "Preferences"), .bundleID)
        XCTAssertEqual(ev("com.foo.Editor.savedState", folder: "Saved Application State"), .bundleID)
        XCTAssertEqual(ev("Editor Pro"), .nameOnly)
        XCTAssertNil(ev("Editor Pro", folder: "Preferences"), "a name is never matched in Preferences")
        XCTAssertNil(ev("Editor Pro Backup files"), "a partial name is never a match")
        XCTAssertNil(ev("com.foo.EditorExtras"), "a longer identifier is a different app")
        XCTAssertEqual(ev("ABCDE12345.shared", folder: "Group Containers", team: "ABCDE12345"), .developer)
        XCTAssertNil(ev("ABCDE12345.shared", folder: "Application Support", team: "ABCDE12345"))
        XCTAssertTrue(LeftoverEvidence.bundleID.preselected)
        XCTAssertFalse(LeftoverEvidence.nameOnly.preselected)
        XCTAssertFalse(LeftoverEvidence.developer.preselected)
    }

    func testShortNamesAreNeverMatched() {
        XCTAssertNil(LeftoverClassifier.evidence(fileName: "Pad", folder: "Application Support", bundleID: "com.x.y", appName: "Pad"))
    }

    // MARK: Policy and inventory tools

    func testOnlyHomebrewAutomaticMayBeInstalled() {
        for source in AppUpdateSource.allCases {
            for policy in UpdatePolicy.allCases {
                XCTAssertEqual(UpdatePolicy.mayInstall(source: source, policy: policy), source == .homebrew && policy == .automatic)
            }
        }
    }

    func testUnusualLocationsAndDuplicates() {
        XCTAssertFalse(AppInventoryTools.isUnusualLocation("/Applications/A.app", home: "/Users/me"))
        XCTAssertFalse(AppInventoryTools.isUnusualLocation("/Applications/Utilities/T.app", home: "/Users/me"))
        XCTAssertFalse(AppInventoryTools.isUnusualLocation("/Users/me/Applications/A.app", home: "/Users/me"))
        XCTAssertTrue(AppInventoryTools.isUnusualLocation("/Users/me/Downloads/A.app", home: "/Users/me"))
        XCTAssertTrue(AppInventoryTools.isUnusualLocation("/Applications2/A.app", home: "/Users/me"), "whole path pieces only")
        let dup = AppInventoryTools.duplicates([("a.b", "/Applications/A.app"), ("a.b", "/Users/me/Downloads/A.app"), ("c.d", "/Applications/C.app"), ("", "/x.app"), ("", "/y.app")])
        XCTAssertEqual(dup.keys.sorted(), ["a.b"])
        XCTAssertEqual(dup["a.b"]?.count, 2)
    }

    func testUnusedByMonths() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let apps: [(name: String, lastUsed: Date?)] = [("Fresh", now.addingTimeInterval(-86_400)), ("Old", now.addingTimeInterval(-400 * 86_400)), ("Never", nil)]
        XCTAssertEqual(AppInventoryTools.unused(apps, months: 12, now: now).sorted(), ["Never", "Old"])
        XCTAssertEqual(AppInventoryTools.unused(apps, months: 24, now: now), ["Never"])
    }

    func testExports() throws {
        let rows = [AppInventoryTools.Row(name: "A \"x\" | y", bundleID: "a.b", version: "1.0", source: "Sparkle", confidence: "Verified", architecture: "Universal", path: "/Applications/A.app", bytes: 42, lastOpened: nil)]
        let csv = AppInventoryTools.csv(rows)
        XCTAssertTrue(csv.hasPrefix("name,bundle_id,version,source,confidence,architecture,path,bytes,last_opened\n"))
        XCTAssertTrue(csv.contains("\"A \"\"x\"\" | y\""))
        XCTAssertTrue(AppInventoryTools.markdown(rows).contains("A \"x\" \\| y"), "a pipe is escaped so the table holds")
        let decoded = try JSONDecoder().decode([AppInventoryTools.Row].self, from: try XCTUnwrap(AppInventoryTools.json(rows)))
        XCTAssertEqual(decoded, rows)
    }

    func testBackupNamesAndPruning() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        let name = AppBackupNaming.folderName(app: "My/App", version: "1.2.3", at: d)
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasPrefix("My App 1.2.3 "))
        let items: [(id: String, app: String, date: Date)] = [("f1", "Foo", d), ("f2", "Foo", d.addingTimeInterval(100)), ("f3", "Foo", d.addingTimeInterval(200)), ("b1", "Bar", d)]
        XCTAssertEqual(AppBackupNaming.expired(items, keep: 2), ["f1"], "the oldest of three Foo copies goes; a lone Bar stays, whatever the versions")
        XCTAssertTrue(AppBackupNaming.expired([], keep: 2).isEmpty)
    }
}
