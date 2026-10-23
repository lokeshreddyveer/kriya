import Foundation

/// One way of triggering something in Kriya: a shortcut, a remapped key, a mouse button, a gesture, a corner and so on.
struct InteractionEntry: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case hotkey, remap, mouseButton, gesture, doubleClick, dragTool, trafficLight, hotCorner, screenEdge, automation, pointerMenu, midi
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hotkey: return "Keyboard shortcuts"
            case .remap: return "Key remapping"
            case .mouseButton: return "Mouse buttons"
            case .gesture: return "Gestures"
            case .doubleClick: return "Double-clicks"
            case .dragTool: return "Drag tools"
            case .trafficLight: return "Window buttons"
            case .hotCorner: return "Hot corners"
            case .screenEdge: return "Screen edges"
            case .automation: return "Automation triggers"
            case .pointerMenu: return "Pointer menu"
            case .midi: return "MIDI controls"
            }
        }

        var symbol: String {
            switch self {
            case .hotkey: return "command"
            case .remap: return "arrow.left.arrow.right"
            case .mouseButton: return "computermouse"
            case .gesture: return "hand.draw"
            case .doubleClick: return "cursorarrow.click.2"
            case .dragTool: return "hand.point.up.left"
            case .trafficLight: return "macwindow"
            case .hotCorner: return "rectangle.inset.topleft.filled"
            case .screenEdge: return "rectangle.lefthalf.inset.filled"
            case .automation: return "gearshape.2"
            case .pointerMenu: return "contextualmenu.and.cursorarrow"
            case .midi: return "pianokeys"
            }
        }
    }

    let kind: Kind
    /// The part of Kriya that owns it.
    let owner: String
    /// What it does.
    let title: String
    /// How you trigger it, as written for a person.
    let trigger: String
    /// The same trigger written one way for every part of Kriya, so two that want the same thing can be found. Nil for
    /// something that cannot clash with anything.
    let key: String?
    var apps: [String] = []
    let pane: SettingsPane

    var id: String { "\(kind.rawValue)|\(owner)|\(title)|\(trigger)" }

    /// The part of Kriya it belongs to. Several mouse presets are one part, and decide among themselves.
    var family: String { owner.hasPrefix("Mouse (") ? "Mouse" : owner }
}

/// Everything that can start something, from every part of Kriya, and which of them want the same thing.
enum InteractionMap {
    struct Inputs {
        var hotkeys: [ShortcutEntry] = []
        var remapEnabled = false
        var remaps: [RemapRule] = []
        var presets: [MousePreset] = []
        var assignments: [MouseAssignment] = []
        var defaultPresetID = "default"
        var drag: DragToolsConfig?
        var traffic: TrafficConfig?
        var screen: ScreenToolsConfig?
        var workflows: [Workflow] = []
        var pointerMenu: PointerMenuConfig?
        var midi: [MIDITrigger] = []
        /// The name of a saved action or command, by its id.
        var name: (String) -> String = { $0 }
    }

    // MARK: Keys that mean the same thing

    static func keyboard(_ code: UInt16, _ modifiers: UInt64) -> String { "k:\(code):\(modifiers)" }
    static func mouse(_ button: UInt32, _ modifiers: UInt64) -> String { "m:\(button):\(modifiers)" }

    // MARK: Gathering

    static func entries(_ input: Inputs) -> [InteractionEntry] {
        var list: [InteractionEntry] = []

        for hotkey in input.hotkeys {
            list.append(InteractionEntry(
                kind: .hotkey, owner: hotkey.owner, title: hotkey.title, trigger: KeyNames.describe(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers),
                key: keyboard(hotkey.keyCode, hotkey.modifiers), apps: hotkey.apps, pane: pane(forHotkeyOwner: hotkey.owner)
            ))
        }

        if input.remapEnabled {
            for rule in input.remaps where rule.enabled {
                var what: [String] = []
                if rule.tap != nil { what.append("tap") }
                if rule.hold != nil { what.append("hold") }
                if rule.doubleTap != nil { what.append("double tap") }
                list.append(InteractionEntry(
                    kind: .remap, owner: "Key remapping", title: rule.name,
                    trigger: KeyNames.describe(keyCode: rule.keyCode, modifiers: rule.modifiers) + (what.isEmpty ? "" : " (\(what.joined(separator: ", ")))"),
                    key: keyboard(rule.keyCode, rule.modifiers), apps: rule.appIds, pane: .keyboard
                ))
            }
        }

        // The mouse settings that apply: the default preset everywhere, and any preset given to an app.
        var scopes: [(preset: MousePreset, apps: [String])] = []
        if let preset = input.presets.first(where: { $0.id == input.defaultPresetID }) { scopes.append((preset, [])) }
        for assignment in input.assignments {
            guard let appID = assignment.appId, let preset = input.presets.first(where: { $0.id == assignment.presetId }) else { continue }
            if let index = scopes.firstIndex(where: { $0.preset.id == preset.id && !$0.apps.isEmpty }) {
                scopes[index].apps.append(appID)
            } else {
                scopes.append((preset, [appID]))
            }
        }
        for scope in scopes {
            let settings = scope.preset.settings
            for rule in settings.buttons {
                list.append(InteractionEntry(
                    kind: .mouseButton, owner: "Mouse (\(scope.preset.name))", title: input.name(rule.actionId),
                    trigger: modifiers(rule.modifiers) + MouseButtons.name(rule.button), key: mouse(rule.button, rule.modifiers), apps: scope.apps, pane: .mouse
                ))
            }
            if settings.gestures.enabled {
                list.append(InteractionEntry(
                    kind: .gesture, owner: "Mouse (\(scope.preset.name))", title: "Swipe gestures",
                    trigger: "Hold \(MouseButtons.name(settings.gestures.activationButton)) and move", key: mouse(settings.gestures.activationButton, 0), apps: scope.apps, pane: .mouse
                ))
            }
        }

        if let drag = input.drag {
            if drag.scrollEnabled {
                list.append(InteractionEntry(
                    kind: .dragTool, owner: "Drag tools", title: "Drag to scroll",
                    trigger: modifiers(drag.scrollModifier) + "Hold \(MouseButtons.name(drag.scrollButton)) and drag", key: mouse(drag.scrollButton, drag.scrollModifier), pane: .mouse
                ))
            }
            for binding in drag.doubleClicks {
                list.append(InteractionEntry(
                    kind: .doubleClick, owner: "Drag tools", title: input.name(binding.actionId),
                    trigger: modifiers(binding.modifiers) + "Double-click \(MouseButtons.name(binding.button))", key: "d:\(binding.button):\(binding.modifiers)", pane: .mouse
                ))
            }
            for binding in drag.buttonScrolls {
                list.append(InteractionEntry(
                    kind: .dragTool, owner: "Drag tools", title: "Scroll while holding \(MouseButtons.name(binding.button))",
                    trigger: "Hold \(MouseButtons.name(binding.button)) and scroll", key: "ms:\(binding.button)", pane: .mouse
                ))
            }
        }

        if let traffic = input.traffic {
            for binding in traffic.bindings {
                list.append(InteractionEntry(
                    kind: .trafficLight, owner: "Window buttons", title: "\(binding.button) button",
                    trigger: modifiers(binding.modifiers) + "Click the \(binding.button) button", key: "t:\(binding.button):\(binding.modifiers)", pane: .buttons
                ))
            }
        }

        if let screen = input.screen, screen.hotCornersEnabled {
            for corner in screen.corners {
                list.append(InteractionEntry(
                    kind: .hotCorner, owner: "Hot corners", title: input.name(corner.actionId),
                    trigger: modifiers(corner.modifiers) + "Pointer in the \(words("\(corner.corner)")) corner", key: "c:\(corner.corner):\(corner.modifiers)", pane: .displays
                ))
            }
        }

        for workflow in input.workflows where workflow.enabled {
            switch workflow.trigger {
            case .mouseButton(let button, let mods):
                list.append(InteractionEntry(kind: .automation, owner: "Automation", title: workflow.name, trigger: modifiers(mods) + MouseButtons.name(button), key: mouse(button, mods), pane: .automation))
            case .hotCorner(let corner, _):
                list.append(InteractionEntry(kind: .automation, owner: "Automation", title: workflow.name, trigger: "Pointer in the \(words("\(corner)")) corner", key: "c:\(corner):0", pane: .automation))
            case .screenEdge(let edge, _):
                list.append(InteractionEntry(kind: .screenEdge, owner: "Automation", title: workflow.name, trigger: "Pointer at the \(edge) edge", key: "e:\(edge)", pane: .automation))
            case .trackpad(let gesture):
                list.append(InteractionEntry(kind: .gesture, owner: "Automation", title: workflow.name, trigger: "Trackpad \(words("\(gesture)"))", key: "p:\(gesture)", pane: .automation))
            default:
                break
            }
        }

        for trigger in input.midi where trigger.enabled {
            let where_ = (trigger.device ?? "").isEmpty ? "" : " on \(trigger.device ?? "")"
            list.append(InteractionEntry(
                kind: .midi, owner: "MIDI triggers", title: trigger.name.isEmpty ? trigger.targetID : trigger.name,
                trigger: trigger.summary + where_, key: "midi:\(trigger.kind.rawValue):\(trigger.number)", pane: .automation
            ))
        }

        if let menu = input.pointerMenu, menu.optionRightClick {
            list.append(InteractionEntry(
                kind: .pointerMenu, owner: "Pointer menu", title: "Open the pointer menu",
                trigger: modifiers(KeyModifiers.option) + MouseButtons.name(1), key: mouse(1, KeyModifiers.option), pane: .finder
            ))
        }
        return list
    }

    // MARK: Clashes

    /// Groups of two or more that want the same trigger in the same place. Keyboard shortcuts against each other are the
    /// shortcut list's own business, so a group made only of those is left out.
    static func clashes(_ entries: [InteractionEntry]) -> [[InteractionEntry]] {
        let byKey = Dictionary(grouping: entries.filter { $0.key != nil }) { $0.key ?? "" }
        var result: [[InteractionEntry]] = []
        for group in byKey.values where group.count > 1 {
            // Two from the same part and of the same kind are that part's own business (a preset for one app replaces the
            // default one, for instance), so they are not set against each other.
            let clashing = group.filter { entry in
                group.contains { $0.id != entry.id && overlaps($0, entry) && !($0.kind == entry.kind && $0.family == entry.family) }
            }
            guard clashing.count > 1, clashing.contains(where: { $0.kind != .hotkey }) else { continue }
            result.append(clashing.sorted { ($0.kind.rawValue, $0.owner, $0.title) < ($1.kind.rawValue, $1.owner, $1.title) })
        }
        return result.sorted { ($0.first?.trigger ?? "") < ($1.first?.trigger ?? "") }
    }

    /// Two share a place when either works everywhere, or they have an app in common.
    static func overlaps(_ a: InteractionEntry, _ b: InteractionEntry) -> Bool {
        if a.apps.isEmpty || b.apps.isEmpty { return true }
        return !Set(a.apps).isDisjoint(with: b.apps)
    }

    enum Severity: Int, CaseIterable, Identifiable, Comparable {
        case blocks = 0, both, order
        var id: Int { rawValue }
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .blocks: return "One may never run"
            case .both: return "Both may run"
            case .order: return "Depends on order"
            }
        }
    }

    /// How bad a clash is: some mean one of the two cannot work, some mean both fire, and the rest depend on who looks first.
    static func severity(of group: [InteractionEntry]) -> Severity {
        let kinds = Set(group.map(\.kind))
        if kinds.contains(.remap) && kinds.contains(.hotkey) { return .blocks }
        if kinds.contains(.gesture) && kinds.contains(.mouseButton) { return .blocks }
        if kinds == [.midi] || kinds.contains(.hotCorner) || kinds.contains(.screenEdge) { return .both }
        return .order
    }

    /// The clashes as a plain-text report for sharing, with personal details taken out.
    static func report(_ groups: [[InteractionEntry]]) -> String {
        guard !groups.isEmpty else { return "No two things in Kriya want the same trigger." }
        let body = groups.sorted { severity(of: $0) != severity(of: $1) ? severity(of: $0) < severity(of: $1) : ($0.first?.trigger ?? "") < ($1.first?.trigger ?? "") }.map { group -> String in
            let lines = group.map { "  - \($0.owner) › \($0.title)" + ($0.apps.isEmpty ? "" : " (in \($0.apps.count) app\($0.apps.count == 1 ? "" : "s"))") }.joined(separator: "\n")
            return "\(group[0].trigger)  [\(severity(of: group).title)]\n\(lines)\n  \(explanation(for: group))"
        }.joined(separator: "\n\n")
        return SupportScrubber.scrub("Kriya conflict report\n\n" + body)
    }

    /// What happens when two clash, in words.
    static func explanation(for group: [InteractionEntry]) -> String {
        let kinds = Set(group.map(\.kind))
        if kinds.contains(.remap), kinds.contains(.hotkey) {
            return "Key remapping reads keys first and may change them before a shortcut sees them, so the shortcut may never run."
        }
        if kinds.contains(.gesture), kinds.contains(.mouseButton) {
            return "Holding this button starts a gesture, which can take the press away from the button rule."
        }
        if kinds == [.midi] {
            return "The same note or knob starts both. They run together when the channel and device they listen to overlap."
        }
        if kinds.contains(.hotCorner) || kinds.contains(.screenEdge) {
            return "Both react to the pointer in the same place. One of them may run, or both."
        }
        return "Both start from the same thing. Which one runs depends on which part of Kriya looks at it first (see Order)."
    }

    // MARK: Words

    static func modifiers(_ bits: UInt64) -> String {
        bits == 0 ? "" : KeyModifiers.glyphs(for: bits) + " "
    }

    /// "topLeft" as "top left".
    static func words(_ camel: String) -> String {
        var out = ""
        for character in camel {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character.lowercased())
        }
        return out
    }

    private static func pane(forHotkeyOwner owner: String) -> SettingsPane {
        switch owner {
        case "Windows": return .windows
        case "Clipboard": return .clipboard
        case "Selection bar": return .selection
        case "Right-click menu": return .finder
        case "Automation": return .automation
        default: return .keyboard
        }
    }

    // MARK: The order events are offered in

    /// A name a person would use for each part that listens to the event tap.
    static func friendlyName(forSubscriber owner: String) -> String {
        switch owner {
        case "keyboard.remap": return "Key remapping"
        case "keyboard.shortcuts": return "Keyboard shortcuts"
        case "keyboard.expansion", "keyboard.expansion.mouse": return "Text expansion (watching only)"
        case "mouse": return "Mouse and trackpad"
        case "drag.tools": return "Drag tools"
        case "buttons": return "Window buttons"
        case "pointer.menu.option": return "Pointer menu"
        case "clipboard.stack": return "Paste stack"
        case "window.drag", "window.modifier.drag": return "Window dragging"
        default: return owner
        }
    }
}
