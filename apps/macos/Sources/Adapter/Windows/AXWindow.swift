import AppKit
import ApplicationServices

extension Rect {
    init(_ cg: CGRect) {
        self.init(x: cg.origin.x, y: cg.origin.y, width: cg.size.width, height: cg.size.height)
    }

    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One window of another app, reached through the Accessibility API. Frames use the screen's top-left origin, the same
/// as the core. Every call can fail (the app may be busy or may refuse), so each one reports failure instead of crashing.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    init(_ element: AXUIElement) {
        self.element = element
        var identifier: pid_t = 0
        AXUIElementGetPid(element, &identifier)
        pid = identifier
        // A stuck app must not freeze Kriya: give up on a call after a moment.
        AXUIElementSetMessagingTimeout(element, 0.4)
    }

    // MARK: Finding windows

    private static let outsideLock = NSLock()
    private static var outsideApp: NSRunningApplication?

    /// Remembers the last app other than Kriya that was in front. Clicking Kriya's menu-bar window makes Kriya the front
    /// app, and its window buttons must still act on the window the person was just using.
    static func startTrackingOutsideApp() {
        let own = Bundle.main.bundleIdentifier
        func note(_ app: NSRunningApplication?) {
            guard let app, app.bundleIdentifier != own, app.activationPolicy == .regular else { return }
            outsideLock.lock()
            outsideApp = app
            outsideLock.unlock()
        }
        note(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
            note(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    /// The app whose window should be acted on: the one in front, or the last other app when Kriya itself is in front.
    private static func targetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == Bundle.main.bundleIdentifier else { return front }
        outsideLock.lock()
        defer { outsideLock.unlock() }
        if let outsideApp, !outsideApp.isTerminated { return outsideApp }
        return front
    }

    /// The focused window of the app in front.
    static func focused() -> AXWindow? {
        guard let app = targetApp() else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.4)
        return element(of: application, kAXFocusedWindowAttribute).map(AXWindow.init)
    }

    /// The window under a point (top-left origin), found by asking what is there and climbing to its window.
    static func at(_ point: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let start = hit else { return nil }
        if role(of: start) == kAXWindowRole { return AXWindow(start) }
        if let window = element(of: start, kAXWindowAttribute) { return AXWindow(window) }
        var current = start
        for _ in 0..<10 {
            guard let parent = element(of: current, kAXParentAttribute) else { return nil }
            if role(of: parent) == kAXWindowRole { return AXWindow(parent) }
            current = parent
        }
        return nil
    }

    static func windows(ofApp pid: pid_t) -> [AXWindow] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.4)
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &out) == .success,
              let list = out as? [AXUIElement] else { return [] }
        return list.map(AXWindow.init)
    }

    // MARK: Reading

    var title: String { string(kAXTitleAttribute) ?? "" }
    var subrole: String? { string(kAXSubroleAttribute) }
    var isStandard: Bool { subrole == kAXStandardWindowSubrole }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { bool("AXFullScreen") ?? false }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var appID: String? { app?.bundleIdentifier }
    var appName: String { app?.localizedName ?? "App" }

    /// Tells windows apart for as long as they exist. Not stable across launches of the app.
    var key: String { "\(pid):\(CFHash(element))" }

    var frame: Rect? {
        guard let position: CGPoint = axValue(kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(kAXSizeAttribute, .cgSize) else { return nil }
        let rect = Rect(x: position.x, y: position.y, width: size.width, height: size.height)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    var canResize: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    // MARK: Changing

    /// Sets size, then position, then size again: moving to another display can clamp the first size to the old display.
    @discardableResult
    func setFrame(_ rect: Rect) -> Bool {
        var size = CGSize(width: rect.width, height: rect.height)
        var position = CGPoint(x: rect.x, y: rect.y)
        guard let sizeValue = AXValueCreate(.cgSize, &size), let positionValue = AXValueCreate(.cgPoint, &position) else { return false }
        let first = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        let second = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        return moved == .success && (first == .success || second == .success)
    }

    @discardableResult
    func setPosition(_ x: Double, _ y: Double) -> Bool {
        var position = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ width: Double, _ height: Double) -> Bool {
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    func unminimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Brings the window to the front and gives its app focus.
    func raise() {
        if isMinimized { unminimize() }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app?.activate()
    }

    // MARK: Helpers

    /// Apps that animate window changes for assistive tools make every move crawl. This turns that off for the moment of
    /// the change and back on after.
    static func withoutEnhancedInterface<T>(pid: pid_t, _ body: () -> T) -> T {
        let application = AXUIElementCreateApplication(pid)
        var out: CFTypeRef?
        let was = AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString, &out) == .success
            && (out as? NSNumber)?.boolValue == true
        if was { AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if was { AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        return body()
    }

    private func string(_ attribute: String) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out as? String
    }

    private func bool(_ attribute: String) -> Bool? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return (out as? NSNumber)?.boolValue
    }

    private func axValue<T>(_ attribute: String, _ type: AXValueType) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
              let raw = out, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        guard AXValueGetValue(value, type, storage) else { return nil }
        return storage.pointee
    }

    private static func element(of source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &out) == .success,
              let raw = out, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func role(of source: AXUIElement) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, kAXRoleAttribute as CFString, &out) == .success else { return nil }
        return out as? String
    }
}

// MARK: - The window buttons

/// A red, yellow or green button found under a point, with the window it belongs to and where it is.
struct TrafficHit {
    let button: TrafficButton
    let window: AXWindow
    let frame: Rect
}

extension AXWindow {
    /// The window button under a point (top-left origin), or `nil` if there is none or the app does not answer in time.
    /// A `nil` always means "leave the click alone", so an app that cannot be read simply keeps its normal buttons.
    static func trafficButton(at point: CGPoint) -> TrafficHit? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var candidate = hit else { return nil }
        for _ in 0..<2 {
            if let sub = trafficSubrole(of: candidate) {
                guard let parent = element(of: candidate, kAXParentAttribute), role(of: parent) == kAXWindowRole,
                      let frame = AXWindow(candidate).frame else { return nil }
                return TrafficHit(button: sub, window: AXWindow(parent), frame: frame)
            }
            guard let parent = element(of: candidate, kAXParentAttribute) else { return nil }
            candidate = parent
        }
        return nil
    }

    private static func trafficSubrole(of source: AXUIElement) -> TrafficButton? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, kAXSubroleAttribute as CFString, &out) == .success,
              let subrole = out as? String else { return nil }
        switch subrole {
        case kAXCloseButtonSubrole: return .close
        case kAXMinimizeButtonSubrole: return .minimize
        case kAXZoomButtonSubrole: return .zoom
        default: return nil
        }
    }

    /// Presses the window's own button, so the app's usual checks (unsaved changes, for one) still run.
    @discardableResult
    func press(_ button: TrafficButton) -> Bool {
        let attribute: String
        switch button {
        case .close: attribute = kAXCloseButtonAttribute
        case .minimize: attribute = kAXMinimizeButtonAttribute
        case .zoom: attribute = kAXZoomButtonAttribute
        }
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
              let raw = out, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXPressAction as CFString) == .success
    }

    @discardableResult
    func setMinimized(_ minimized: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    @discardableResult
    func setFullScreen(_ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
}
