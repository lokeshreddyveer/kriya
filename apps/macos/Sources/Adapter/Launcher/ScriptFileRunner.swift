import AppKit
import SwiftUI

/// Runs a script file from a script folder, away from the main thread, and shows what it printed as its mode says.
enum ScriptFileRunner {
    static func run(_ script: ScriptFile, argument: String, toast: Toast) {
        let args = ScriptFileParser.split(argument, into: script.arguments.count)
        let missing = zip(script.arguments, args + Array(repeating: "", count: max(0, script.arguments.count - args.count))).contains { !$0.optional && $1.isEmpty }
        if missing {
            toast.show("“\(script.title)” needs: " + script.arguments.map(\.placeholder).filter { !$0.isEmpty }.joined(separator: ", "), isError: true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let first = (try? String(contentsOfFile: script.path, encoding: .utf8))?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let launch = ScriptFileParser.launch(for: script.path, isExecutable: fm.isExecutableFile(atPath: script.path), firstLine: first) else {
                DispatchQueue.main.async { toast.show("“\(script.title)” cannot run: make it executable (chmod +x) or start it with #!/bin/zsh.", isError: true) }
                return
            }
            let directory = script.directory.map { ($0 as NSString).expandingTildeInPath }.flatMap { fm.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
                ?? URL(fileURLWithPath: (script.path as NSString).deletingLastPathComponent)
            let environment = ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "KRIYA_ARGUMENT": argument]
            do {
                let output = try ToolRunner.run(launch.executable, launch.arguments + args, in: directory, environment: environment, timeout: 120)
                DispatchQueue.main.async { show(output, for: script, toast: toast) }
            } catch {
                DispatchQueue.main.async { toast.show("“\(script.title)” failed: \(error.localizedDescription)", isError: true) }
            }
        }
    }

    private static func show(_ output: String, for script: ScriptFile, toast: Toast) {
        switch script.mode {
        case .silent:
            break
        case .compact, .inline:
            let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            toast.show(line.isEmpty ? "\(script.title) finished" : String(line.prefix(160)))
        case .fullOutput:
            ScriptOutputWindow.show(title: script.title, text: output.isEmpty ? "(it printed nothing)" : output)
        }
    }
}

/// A small window with what a script printed, to read and copy.
final class ScriptOutputWindow {
    private static var windows: [NSWindow] = []

    static func show(title: String, text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
            Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        })
        window.center()
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
