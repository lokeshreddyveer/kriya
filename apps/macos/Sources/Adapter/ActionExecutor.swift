import AppKit

enum ActionOutcome: Equatable {
    case success
    case failure(String)

    var isSuccess: Bool { self == .success }
}

/// Carries out the plain steps the core's action engine produces. The core checks and flattens an action; this class
/// does the macOS part: pressing keys, opening apps and addresses, running scripts and shortcuts.
final class ActionExecutor {
    private let permissions: PermissionManager
    private let lock = NSLock()
    private var commands: [String: () -> Void] = [:]

    private static let processTimeout: TimeInterval = 30

    init(permissions: PermissionManager) {
        self.permissions = permissions
    }

    // MARK: Built-in commands that features register (for example "window.left_half")

    func registerCommand(_ id: String, handler: @escaping () -> Void) {
        lock.lock()
        commands[id] = handler
        lock.unlock()
    }

    func unregisterCommand(_ id: String) {
        lock.lock()
        commands[id] = nil
        lock.unlock()
    }

    var registeredCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands.keys.sorted()
    }

    // MARK: Running

    func perform(_ action: Action) async -> ActionOutcome {
        let steps: [ActionStep]
        do {
            steps = try planAction(action: action)
        } catch {
            return .failure(error.userMessage)
        }
        for step in steps {
            switch step {
            case .delay(let ms):
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            case .run(let single):
                let outcome = await run(single)
                if case .failure(let message) = outcome {
                    Log.warning("Actions", "An action step failed: \(message)")
                    return outcome
                }
            }
        }
        return .success
    }

    private func run(_ action: Action) async -> ActionOutcome {
        switch action {
        case .noop:
            return .success
        case .keyPress(let keyCode, let modifiers):
            return pressKey(keyCode: keyCode, modifiers: modifiers)
        case .click(let x, let y, let button, let count, let inWindow):
            return click(x: x, y: y, right: button == 1, count: count, inWindow: inWindow)
        case .openApplication(let target):
            return await openApplication(target)
        case .openUrl(let url):
            return await openURL(url)
        case .runShell(let script):
            return await runProcess("/bin/zsh", ["-c", script])
        case .runScript(let language, let source):
            switch language {
            case .appleScript: return await runProcess("/usr/bin/osascript", ["-e", source])
            case .powerShell: return .failure("PowerShell scripts run only on Windows.")
            }
        case .runShortcut(let name):
            return await runProcess("/usr/bin/shortcuts", ["run", name])
        case .builtin(let command):
            return await runBuiltin(command)
        case .sequence:
            return .success   // already flattened by the core
        }
    }

    private func pressKey(keyCode: UInt16, modifiers: UInt64) -> ActionOutcome {
        guard permissions.isGranted(.accessibility) else {
            return .failure("Accessibility permission is needed to press keys.")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return .failure("Could not create the key press.")
        }
        let flags = KeyModifiers.flags(from: modifiers)
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
        return .success
    }

    /// Moves to a point, clicks, and puts the pointer back where it was.
    private func click(x: Int32, y: Int32, right: Bool, count: UInt8, inWindow: Bool) -> ActionOutcome {
        guard permissions.isGranted(.accessibility) else { return .failure("Accessibility permission is needed to click.") }
        var point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        if inWindow {
            guard let frame = AXWindow.focused()?.frame?.cg else { return .failure("There is no window in front to click in.") }
            point = CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let button: CGMouseButton = right ? .right : .left
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let before = CGEvent(source: nil)?.location
        for n in 1...Int(max(count, 1)) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else { return .failure("Could not create the click.") }
            for event in [down, up] {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
        if let before { CGWarpMouseCursorPosition(before) }
        return .success
    }

    private func openApplication(_ target: String) async -> ActionOutcome {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let url: URL? = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return .failure("Could not find that app.")
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return .success
        } catch {
            return .failure("Could not open the app: \(error.localizedDescription)")
        }
    }

    private func openURL(_ text: String) async -> ActionOutcome {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure("The web address is not valid.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return opened ? .success : .failure("Nothing on this Mac can open that address.")
    }

    private func runBuiltin(_ command: String) async -> ActionOutcome {
        lock.lock()
        let handler = commands[command]
        lock.unlock()
        guard let handler else {
            InteractionTrace.shared.note("Command", "\(command): not available")
            return .failure("The command \(command) is not available.")
        }
        InteractionTrace.shared.note("Command", command)
        await MainActor.run { handler() }
        return .success
    }

    // MARK: Processes

    private func runProcess(_ executable: String, _ arguments: [String]) async -> ActionOutcome {
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        var environment = ProcessInfo.processInfo.environment
        environment["KRIYA_FRONT_APP_ID"] = front?.bundleIdentifier ?? ""
        environment["KRIYA_FRONT_APP_NAME"] = front?.localizedName ?? ""

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure("Could not start \(executable): \(error.localizedDescription)"))
                    return
                }
                let timedOut = SyncFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.value = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.processTimeout, execute: watchdog)
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if timedOut.value {
                    continuation.resume(returning: .failure("It took longer than \(Int(Self.processTimeout)) seconds and was stopped."))
                } else if process.terminationStatus != 0 {
                    let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = text.isEmpty ? "exit code \(process.terminationStatus)" : String(text.prefix(300))
                    continuation.resume(returning: .failure("It did not finish: \(detail)"))
                } else {
                    continuation.resume(returning: .success)
                }
            }
        }
    }
}
