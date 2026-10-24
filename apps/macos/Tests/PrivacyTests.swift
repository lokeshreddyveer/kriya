import XCTest
@testable import Kriya

final class BackupCryptoTests: XCTestCase {
    func testASealedBackupOpensOnlyWithItsPassphrase() throws {
        let json = #"{"format_version":1,"app":"kriya","secret":"deploy-token-123"}"#
        let sealed = try BackupCrypto.seal(json, passphrase: "correct horse", iterations: 20_000)
        XCTAssertTrue(BackupCrypto.isEncrypted(sealed))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("deploy-token-123"))
        XCTAssertEqual(try BackupCrypto.open(sealed, passphrase: "correct horse"), json)
        XCTAssertThrowsError(try BackupCrypto.open(sealed, passphrase: "wrong horse!")) { XCTAssertEqual($0 as? BackupCryptoError, .wrongPassphrase) }
    }

    func testChangingTheSettingsInTheFileIsCaught() throws {
        let sealed = try BackupCrypto.seal("hello", passphrase: "passphrase one", iterations: 20_000)
        var envelope = try JSONDecoder().decode(BackupCrypto.Envelope.self, from: sealed)
        envelope.iterations = 30_000
        let changed = try JSONEncoder().encode(envelope)
        XCTAssertThrowsError(try BackupCrypto.open(changed, passphrase: "passphrase one"))
        envelope.iterations = 1
        XCTAssertThrowsError(try BackupCrypto.open(try JSONEncoder().encode(envelope), passphrase: "passphrase one")) { XCTAssertEqual($0 as? BackupCryptoError, .damaged) }
    }

    func testAPlainBackupIsNotMistakenForASealedOne() {
        XCTAssertFalse(BackupCrypto.isEncrypted(Data(#"{"format_version":1}"#.utf8)))
        XCTAssertFalse(BackupCrypto.isEncrypted(Data("not json".utf8)))
    }

    func testAShortPassphraseIsRefused() {
        XCTAssertThrowsError(try BackupCrypto.seal("x", passphrase: "short", iterations: 20_000)) { XCTAssertEqual($0 as? BackupCryptoError, .tooShort) }
    }
}

final class ProtectedBackupTests: XCTestCase {
    private var world: TestWorld!
    private var store: MemoryPassphraseStore!
    private var backup: BackupManager!

    override func setUpWithError() throws {
        world = try TestWorld()
        store = MemoryPassphraseStore()
        try FileManager.default.createDirectory(at: world.folder.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        backup = BackupManager(core: world.core, folder: world.folder.appendingPathComponent("Backups", isDirectory: true), passphrases: store, defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
    }

    override func tearDown() { world.cleanUp() }

    func testProtectedBackupsAreSealedAndStillRestore() throws {
        let plain = world.folder.appendingPathComponent("plain.kriyabackup")
        try backup.export(to: plain)
        XCTAssertFalse(BackupCrypto.isEncrypted(try Data(contentsOf: plain)), "unprotected backups stay as they were")

        try backup.protect(with: "a long passphrase")
        XCTAssertTrue(backup.isProtected)
        let sealed = world.folder.appendingPathComponent("sealed.kriyabackup")
        try backup.export(to: sealed)
        XCTAssertTrue(BackupCrypto.isEncrypted(try Data(contentsOf: sealed)))
        XCTAssertNoThrow(try backup.inspect(sealed), "this Mac holds the passphrase")
        XCTAssertNoThrow(try backup.restore(from: sealed))
        XCTAssertTrue(backup.automaticBackups.allSatisfy { BackupCrypto.isEncrypted((try? Data(contentsOf: $0.url)) ?? Data()) }, "the copy made before a restore is sealed too")
    }

    func testAnotherMacNeedsTheTypedPassphrase() throws {
        try backup.protect(with: "shared secret phrase")
        let file = world.folder.appendingPathComponent("carried.kriyabackup")
        try backup.export(to: file)
        store.delete()
        let other = BackupManager(core: world.core, folder: world.folder.appendingPathComponent("Backups", isDirectory: true), passphrases: MemoryPassphraseStore(), defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        XCTAssertThrowsError(try other.inspect(file)) { XCTAssertEqual($0 as? BackupCryptoError, .needsPassphrase) }
        XCTAssertThrowsError(try other.inspect(file, passphrase: "not the phrase")) { XCTAssertEqual($0 as? BackupCryptoError, .wrongPassphrase) }
        XCTAssertNoThrow(try other.inspect(file, passphrase: "shared secret phrase"))
    }

    func testTurningProtectionOnSealsBackupsAlreadySaved() throws {
        try backup.writeAutomaticBackup(reason: "test")
        let first = try XCTUnwrap(backup.automaticBackups.first)
        XCTAssertFalse(BackupCrypto.isEncrypted(try Data(contentsOf: first.url)))
        try backup.protect(with: "now it is sealed")
        XCTAssertTrue(BackupCrypto.isEncrypted(try Data(contentsOf: first.url)))
        XCTAssertNoThrow(try backup.inspect(first.url))
    }

    func testAShortPassphraseChangesNothing() {
        XCTAssertThrowsError(try backup.protect(with: "short"))
        XCTAssertFalse(backup.isProtected)
        XCTAssertNil(store.phrase)
    }
}

final class ClipboardVaultTests: XCTestCase {
    private var world: TestWorld!
    private var keys: MemoryVaultKeyStore!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        world = try TestWorld()
        keys = MemoryVaultKeyStore()
        store = ClipboardStore(core: world.core, keyStore: keys)
    }

    override func tearDown() { world.cleanUp() }

    private func copy(_ text: String) -> NewClip {
        NewClip(text: text, rich: nil, richFormat: nil, image: nil, imageFormat: nil, imageWidth: nil, imageHeight: nil, files: [], sourceApp: "app.test", concealed: false)
    }

    private func turnOn() throws {
        let done = expectation(description: "encrypted")
        var failure: String?
        store.vault.turnOn { failure = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertNil(failure)
    }

    func testAFreshInstallNeverAsksTheKeyStore() {
        XCTAssertFalse(store.vault.isEncrypted)
        XCTAssertEqual(keys.saves, 0)
        XCTAssertNil(keys.key)
    }

    func testTurningItOnKeepsTheKeyAwayFromTheCoreFileAndEverythingStillWorks() throws {
        _ = store.record(copy("quarterly numbers"))
        try turnOn()
        XCTAssertTrue(store.vault.isEncrypted)
        XCTAssertEqual(keys.key?.count, VaultKey.byteCount)
        XCTAssertEqual(store.vault.status?.sealedItems, 1)
        XCTAssertEqual(store.search("quarterly").first?.preview, "quarterly numbers")
        _ = store.record(copy("another note"))
        XCTAssertEqual(store.search("").count, 2)
    }

    func testALostKeyLocksTheHistoryUntilItIsDeleted() throws {
        try turnOn()
        _ = store.record(copy("hidden away"))
        keys.key = nil
        let restarted = ClipboardStore(core: world.core, keyStore: keys)
        // The same running core still holds the key it was given, so simulate a restart by taking it away.
        _ = try world.core.clipVaultSetKey(key: nil)
        restarted.vault.refresh()
        XCTAssertTrue(restarted.vault.isLocked)
        XCTAssertEqual(restarted.record(copy("not saved"))?.skipped, .vaultLocked)
        let done = expectation(description: "reset")
        restarted.vault.startAgain { XCTAssertNil($0); done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(restarted.vault.isLocked)
        XCTAssertEqual(restarted.record(copy("fresh start"))?.status, .stored)
    }

    func testTurningItOffRestoresPlainHistoryAndRemovesTheKey() throws {
        _ = store.record(copy("plain again"))
        try turnOn()
        let done = expectation(description: "off")
        store.vault.turnOff { XCTAssertNil($0); done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertFalse(store.vault.isEncrypted)
        XCTAssertNil(keys.key)
        XCTAssertEqual(store.search("plain").first?.preview, "plain again")
    }
}

final class ClipboardLockTests: XCTestCase {
    private func makeLock(clock: @escaping () -> Date, answers: [Bool]) -> (ClipboardLock, () -> Int) {
        var remaining = answers
        var asked = 0
        let suite = UserDefaults(suiteName: "kriya-lock-tests-\(UUID().uuidString)")!
        let lock = ClipboardLock(defaults: suite, authenticate: { _, done in asked += 1; done(remaining.isEmpty ? false : remaining.removeFirst()) }, now: clock, watchSystem: false)
        return (lock, { asked })
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    func testItIsOffUntilTheMacConfirmsWhoYouAre() {
        var now = Date()
        let (lock, asked) = makeLock(clock: { now }, answers: [false, true])
        XCTAssertTrue(lock.isOpen)
        lock.enable(reason: "test") { XCTAssertFalse($0) }
        settle()
        XCTAssertFalse(lock.isEnabled, "a failed check leaves it off, so nobody is locked out")
        lock.enable(reason: "test") { XCTAssertTrue($0) }
        settle()
        XCTAssertTrue(lock.isEnabled)
        XCTAssertEqual(asked(), 2)
        now = now.addingTimeInterval(1)
        XCTAssertTrue(lock.isOpen)
    }

    func testItClosesAfterTheTimeAndAsksAgain() {
        var now = Date()
        let (lock, asked) = makeLock(clock: { now }, answers: [true, true])
        lock.enable(reason: "test") { _ in }
        settle()
        lock.timeoutMinutes = 5
        var opened = false
        lock.ensureUnlocked(reason: "open") { opened = $0 }
        XCTAssertTrue(opened)
        XCTAssertEqual(asked(), 1, "still open, so it does not ask")
        now = now.addingTimeInterval(6 * 60)
        XCTAssertTrue(lock.needsUnlock)
        lock.ensureUnlocked(reason: "open") { opened = $0 }
        settle()
        XCTAssertEqual(asked(), 2)
        XCTAssertTrue(opened)
    }

    func testLockingNowClosesItAndAFailedCheckKeepsItClosed() {
        let now = Date()
        let (lock, _) = makeLock(clock: { now }, answers: [true, false])
        lock.enable(reason: "test") { _ in }
        settle()
        lock.lockNow()
        XCTAssertTrue(lock.needsUnlock)
        var opened = true
        lock.ensureUnlocked(reason: "open") { opened = $0 }
        settle()
        XCTAssertFalse(opened)
        XCTAssertTrue(lock.needsUnlock)
    }
}
