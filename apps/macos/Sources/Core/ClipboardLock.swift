import AppKit
import LocalAuthentication

/// An optional gate in front of the clipboard history: Touch ID or the Mac's password before it opens, and again after a
/// while, after sleep and after the screen locks. It protects what Kriya shows on screen. What is stored is protected by
/// encryption (see ClipboardVault), not by this.
final class ClipboardLock: ObservableObject {
    static let shared = ClipboardLock()

    typealias Authenticator = (_ reason: String, _ done: @escaping (Bool) -> Void) -> Void

    private enum Key {
        static let enabled = "clipboardHistoryLocked"
        static let minutes = "clipboardHistoryLockMinutes"
    }

    /// The times the person can pick, in minutes.
    static let timeouts = [1, 5, 15, 60]

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            if !isEnabled { unlockedAt = nil }
            publish()
        }
    }

    @Published var timeoutMinutes: Int {
        didSet { defaults.set(timeoutMinutes, forKey: Key.minutes) }
    }

    /// Whether the history may be shown right now. Always true when the lock is off.
    @Published private(set) var isOpen = true

    private let defaults: UserDefaults
    private let authenticate: Authenticator
    private let now: () -> Date
    private var unlockedAt: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, authenticate: @escaping Authenticator = ClipboardLock.askTheSystem, now: @escaping () -> Date = Date.init, watchSystem: Bool = true) {
        self.defaults = defaults
        self.authenticate = authenticate
        self.now = now
        isEnabled = defaults.bool(forKey: Key.enabled)
        let saved = defaults.object(forKey: Key.minutes) as? Int
        timeoutMinutes = saved.flatMap { Self.timeouts.contains($0) ? $0 : nil } ?? 5
        isOpen = !isEnabled
        if watchSystem { observeSystem() }
    }

    deinit {
        timer?.invalidate()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// True when history must not be shown until the person proves who they are.
    var needsUnlock: Bool { isEnabled && !stillValid }

    private var stillValid: Bool {
        guard let unlockedAt else { return false }
        return now().timeIntervalSince(unlockedAt) < Double(timeoutMinutes) * 60
    }

    /// Calls `then(true)` if the history may be shown: the lock is off, it was opened recently, or the person just
    /// proved who they are. Calls `then(false)` if they did not.
    func ensureUnlocked(reason: String, then: @escaping (Bool) -> Void) {
        guard needsUnlock else { then(true); return }
        authenticate(reason) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { then(ok); return }
                if ok { self.unlockedAt = self.now() }
                self.publish()
                then(ok)
            }
        }
    }

    /// Turns the lock on, but only once the Mac has shown it can ask (so nobody is locked out of their own history).
    func enable(reason: String, then: @escaping (Bool) -> Void) {
        authenticate(reason) { [weak self] ok in
            DispatchQueue.main.async {
                if ok, let self {
                    self.isEnabled = true
                    self.unlockedAt = self.now()
                    self.publish()
                }
                then(ok)
            }
        }
    }

    /// Turns the lock off, but only for someone who can open it: a lock that anyone at an unlocked Mac can switch off protects nothing.
    /// Calls `then(true)` once it is off, `then(false)` if the person did not prove who they are and it stays on.
    func disable(reason: String, then: @escaping (Bool) -> Void) {
        ensureUnlocked(reason: reason) { [weak self] ok in
            if ok { self?.isEnabled = false }
            then(ok)
        }
    }

    /// Changes how long the history stays open, with the same proof: a longer time is a weaker lock.
    func changeTimeout(to minutes: Int, reason: String, then: @escaping (Bool) -> Void) {
        guard minutes != timeoutMinutes else { then(true); return }
        ensureUnlocked(reason: reason) { [weak self] ok in
            if ok { self?.timeoutMinutes = minutes }
            then(ok)
        }
    }

    func lockNow() {
        unlockedAt = nil
        publish()
    }

    /// For a time-limited unlock with no new use: the window stays open while it is in use and closes when idle.
    func noteUse() {
        if isEnabled, stillValid { unlockedAt = now() }
    }

    private func publish() {
        let open = !needsUnlock
        if open != isOpen { isOpen = open }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.lockNow() })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.lockNow() })
        // While the history is on screen, close it when the time is up.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.publish() }
    }

    /// Touch ID if there is one, otherwise (or when it fails) the Mac's password.
    static func askTheSystem(reason: String, done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.warning("Clipboard", "The Mac cannot ask for a password here: \(error?.localizedDescription ?? "unknown")")
            done(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in done(ok) }
    }
}
