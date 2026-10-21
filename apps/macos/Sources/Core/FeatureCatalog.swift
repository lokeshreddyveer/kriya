import Foundation

/// What the interface shows for each feature, and which system permissions it needs. The core only knows the ids.
extension FeatureId: Identifiable {
    public var id: String { key }

    /// Every feature, in display order. The core owns the list.
    static var all: [FeatureId] { allFeatures() }

    var key: String {
        switch self {
        case .mouse: return "mouse"
        case .windowManagement: return "windowManagement"
        case .trafficLights: return "trafficLights"
        case .contextMenu: return "contextMenu"
        case .selectionBar: return "selectionBar"
        case .clipboard: return "clipboard"
        case .keyboard: return "keyboard"
        case .automation: return "automation"
        }
    }

    var title: String {
        switch self {
        case .mouse: return "Mouse & Trackpad"
        case .windowManagement: return "Window Management"
        case .trafficLights: return "Window Buttons"
        case .contextMenu: return "Right-Click Menu"
        case .selectionBar: return "Selection Bar"
        case .clipboard: return "Clipboard"
        case .keyboard: return "Keyboard & Text Expansion"
        case .automation: return "Automation"
        }
    }

    var summary: String {
        switch self {
        case .mouse: return "Scrolling, speed, buttons and gestures, set separately for each mouse and trackpad."
        case .windowManagement: return "Snap, resize and move windows with shortcuts and screen edges."
        case .trafficLights: return "Choose what the red, yellow and green window buttons do."
        case .contextMenu: return "Extra items in Finder's right-click menu."
        case .selectionBar: return "Quick actions that appear when you select text."
        case .clipboard: return "History of what you copy, snippets, and a quick-access window."
        case .keyboard: return "Keyboard shortcuts for any action, text expansion and a command launcher."
        case .automation: return "Workflows that run on a trigger: a shortcut, a gesture, an app, a display."
        }
    }

    var symbol: String {
        switch self {
        case .mouse: return "computermouse"
        case .windowManagement: return "rectangle.split.2x1"
        case .trafficLights: return "macwindow"
        case .contextMenu: return "contextualmenu.and.cursorarrow"
        case .selectionBar: return "text.cursor"
        case .clipboard: return "doc.on.clipboard"
        case .keyboard: return "keyboard"
        case .automation: return "gearshape.2"
        }
    }

    /// Asked for only when the person turns the feature on.
    var requiredPermissions: [Permission] {
        switch self {
        case .mouse: return [.accessibility, .inputMonitoring]
        case .trafficLights, .keyboard: return [.accessibility, .inputMonitoring]
        case .windowManagement, .selectionBar: return [.accessibility]
        case .contextMenu, .clipboard, .automation: return []
        }
    }

    /// False while the feature is still a placeholder.
    var isAvailable: Bool { true }

    /// The planned release for the feature. Phase 1 builds the foundation they all sit on.
    var arrivesIn: String {
        switch self {
        case .mouse: return "Phase 2"
        case .windowManagement: return "Phase 3"
        case .trafficLights: return "Phase 4"
        case .contextMenu: return "Phase 5"
        case .selectionBar: return "Phase 7"
        case .clipboard: return "Phase 6"
        case .keyboard: return "Phase 8"
        case .automation: return "Phase 9"
        }
    }
}

extension ConnectionKind {
    var title: String {
        switch self {
        case .wired: return "Wired"
        case .wireless: return "Wireless"
        case .builtIn: return "Built-in"
        }
    }

    var symbol: String {
        switch self {
        case .wired: return "cable.connector"
        case .wireless: return "wifi"
        case .builtIn: return "laptopcomputer"
        }
    }
}

extension DeviceKind {
    var title: String {
        switch self {
        case .mouse: return "Mouse"
        case .trackpad: return "Trackpad"
        }
    }

    var symbol: String {
        switch self {
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        }
    }
}

extension AppearanceMode {
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
