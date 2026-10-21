import Combine
import Foundation

/// Settings for hot corners, saved display profiles, dimming and the file shelf.
final class ScreenToolsStore: ObservableObject {
    @Published private(set) var config = ScreenToolsConfig(
        hotCornersEnabled: false, corners: [], cornerDwellMs: 350, cornerSize: 6, displayProfiles: [], restoreProfileOnChange: false,
        dimLevels: [], shelfEnabled: false, shelfOnShake: true, shelfOnDrag: false, shelfEdge: .pointer, shelfAutoHideSeconds: 0,
        shelfExcludedAppIds: []
    )
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: ScreenToolsConfig?      // guarded by lock

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.screenToolsConfig()
        } catch {
            Log.error("Screen", "Could not load screen tools: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    /// Safe to read from any thread.
    var current: ScreenToolsConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? config
    }

    func update(_ change: (inout ScreenToolsConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.saveScreenToolsConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }
}

extension DisplayProfile: Identifiable {}
extension ScreenCorner: CaseIterable, Identifiable {
    public static var allCases: [ScreenCorner] { [.topLeft, .topRight, .bottomLeft, .bottomRight] }
    public var id: Self { self }
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}
