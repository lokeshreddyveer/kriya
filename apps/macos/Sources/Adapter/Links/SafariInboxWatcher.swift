import AppKit

/// Picks up what the Safari extension left in the inbox folder and handles it as any other browser request. It only looks while
/// Safari support is switched on, and removes every file it looks at.
final class SafariInboxWatcher: ObservableObject {
    private static let enabledKey = "safariExtension.enabled"

    /// The one running copy, which the Overview reaches.
    static weak var current: SafariInboxWatcher?
    let folder: URL
    var openLink: (URL) -> Void = { _ in }
    var showSelection: (String) -> Void = { _ in }
    var savePage: (PageClip, PageAction) -> Void = { _, _ in }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); FeatureActivity.shared.changed("safariExtension", enabled ? "Turned on" : "Turned off"); enabled ? start() : stop() }
    }
    @Published private(set) var handled = 0
    @Published private(set) var refused = 0
    private var timer: Timer?

    init(support: URL) {
        folder = support.appendingPathComponent(SafariInbox.folderName, isDirectory: true)
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        Self.current = self
    }

    func start() {
        guard enabled, timer == nil else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("safari-") {
            let url = folder.appendingPathComponent(name)
            defer { try? manager.removeItem(at: url) }
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { continue }
            let size = (attributes[.size] as? Int) ?? Int.max
            let age = Date().timeIntervalSince((attributes[.modificationDate] as? Date) ?? .distantPast)
            let owner = (attributes[.ownerAccountID] as? Int) == Int(getuid())
            let regular = (attributes[.type] as? FileAttributeType) == .typeRegular
            guard SafariInbox.isAcceptable(name: name, size: size, age: age, isRegular: regular, ownedByUser: owner),
                  let data = try? Data(contentsOf: url) else { refused += 1; continue }
            switch SafariInbox.interpret(data) {
            case .failure:
                refused += 1
            case .success(let request):
                handled += 1
                FeatureActivity.shared.used("safariExtension")
                switch request {
                case .open(let url, _): openLink(url)
                case .selection(let text, _): showSelection(text)
                case .page(let clip, let action): savePage(clip, action)
                }
            }
        }
    }
}
