import AppKit
import AVFoundation

// MARK: - Do Not Disturb

/// Turns Do Not Disturb on and off by running two Shortcuts the person made, named "Kriya Focus On" and "Kriya Focus Off". macOS gives
/// apps no other way to change a Focus. Whether it is on cannot be read without Full Disk Access, so it is reported as unknown.
final class ShortcutsFocusController: FocusControlling {
    static let onName = "Kriya Focus On"
    static let offName = "Kriya Focus Off"

    /// Whether both Shortcuts exist.
    static func isSetUp() -> Bool {
        guard let out = run(["list"]) else { return false }
        let names = Set(out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return names.contains(onName) && names.contains(offName)
    }

    func currentState() -> DNDState { .unknown }

    @discardableResult
    func set(_ state: DNDState) -> Bool {
        guard state != .unknown else { return false }
        return Self.run(["run", state == .on ? Self.onName : Self.offName]) != nil
    }

    private static func run(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Do Not Disturb for the length of one recording. Begun when the recording has started, restored by every way it can end.
final class RecordingFocus {
    private let controller: FocusControlling
    private let store: FocusTransactionStore
    private var transaction: FocusTransaction?

    init(controller: FocusControlling = ShortcutsFocusController(), store: FocusTransactionStore = FocusTransactionStore()) {
        self.controller = controller
        self.store = store
    }

    var isActive: Bool { transaction != nil }

    /// Turns it on. Returns a sentence when it could not be, and the recording goes ahead without it.
    func begin() -> String? {
        guard transaction == nil else { return nil }
        guard ShortcutsFocusController.isSetUp() || !(controller is ShortcutsFocusController) else {
            return "Do Not Disturb was not turned on: make two Shortcuts named “\(ShortcutsFocusController.onName)” and “\(ShortcutsFocusController.offName)” that turn it on and off."
        }
        guard let made = FocusTransaction.begin(using: controller) else { return "Do Not Disturb could not be turned on, so notifications may show in the recording." }
        transaction = made
        // Written down at once, so a quit or crash in the middle is put right at the next start.
        store.pending = made
        return nil
    }

    /// Puts it back. Safe to call more than once; every way a recording ends (stop, cancel, error, permission failure) calls it.
    func restore() {
        guard let transaction else { return }
        self.transaction = nil
        if transaction.restore(using: controller) { store.pending = nil } else { store.pending = transaction }
    }

    /// At launch: puts it back if the last run ended in the middle of a recording.
    @discardableResult
    func recover() -> Bool { store.recover(using: controller) }
}

// MARK: - Showing clicks

/// A transparent window over the screen that draws a ring where the mouse is clicked, one that stays while the button is held, and
/// optionally a halo around the pointer. It ignores the mouse, so it never gets in the way, and it is gone the moment recording ends.
final class ClickHighlightOverlay {
    private static let clickAnimation = "kriya.click"
    private static let releaseAnimation = "kriya.release"
    private var panels: [NSPanel] = []
    private var monitors: [Any] = []
    private var options = ClickHighlightOptions()
    private var holds: [MouseButton: CALayer] = [:]
    private var halo: CALayer?

    var isShowing: Bool { !panels.isEmpty }

    func show(options: ClickHighlightOptions, source: RecordingSource) {
        hide()
        guard options.shows(for: source) else { return }
        self.options = options
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        func watch(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(monitor) }
        }
        watch([.leftMouseDown, .rightMouseDown]) { [weak self] in self?.pressed($0) }
        watch([.leftMouseUp, .rightMouseUp]) { [weak self] in self?.released($0) }
        watch([.leftMouseDragged, .rightMouseDragged, .mouseMoved]) { [weak self] _ in self?.moved() }
        if options.cursorHalo { moved() }
    }

    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels = []
        holds = [:]
        halo = nil
    }

    deinit { hide() }

    private func layerHost(at point: NSPoint) -> (NSView, NSPoint)? {
        guard let panel = panels.first(where: { $0.frame.contains(point) }), let view = panel.contentView else { return nil }
        return (view, NSPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY))
    }

    private func ring(at local: NSPoint, colour: CodableColor, filled: Bool) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let radius: CGFloat = 22
        layer.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        layer.position = local
        layer.fillColor = filled ? colour.cgColor.copy(alpha: 0.25) : nil
        layer.strokeColor = colour.cgColor
        layer.lineWidth = 3
        return layer
    }

    private func button(of event: NSEvent) -> MouseButton { event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left }

    private func pressed(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard let (view, local) = layerHost(at: point) else { return }
        let which = button(of: event)
        let colour = options.colour(for: which)
        // The click: a ring that grows and fades.
        let click = ring(at: local, colour: colour, filled: false)
        view.layer?.addSublayer(click)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.4; grow.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [grow, fade]; group.duration = 0.45; group.isRemovedOnCompletion = false; group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak click] in click?.removeFromSuperlayer() }
        click.add(group, forKey: Self.clickAnimation)
        CATransaction.commit()
        // The hold: a steadier ring that stays while the button is down.
        if options.showHold {
            holds[which]?.removeFromSuperlayer()
            let hold = ring(at: local, colour: colour, filled: true)
            view.layer?.addSublayer(hold)
            holds[which] = hold
        }
    }

    private func moved() {
        let point = NSEvent.mouseLocation
        guard let (view, local) = layerHost(at: point) else { return }
        for hold in holds.values { hold.position = local }
        guard options.cursorHalo else { return }
        if halo == nil || halo?.superlayer !== view.layer {
            halo?.removeFromSuperlayer()
            let made = ring(at: local, colour: CodableColor(red: 1, green: 1, blue: 1, alpha: 0.5), filled: true)
            made.lineWidth = 1.5
            view.layer?.addSublayer(made)
            halo = made
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo?.position = local
        CATransaction.commit()
    }

    private func released(_ event: NSEvent) {
        let which = button(of: event)
        guard let hold = holds.removeValue(forKey: which) else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak hold] in hold?.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.25; fade.isRemovedOnCompletion = false; fade.fillMode = .forwards
        hold.add(fade, forKey: Self.releaseAnimation)
        CATransaction.commit()
    }
}

// MARK: - One mixed audio track

/// Writes a copy of a movie whose Mac sound and microphone are mixed into one track, using AVAssetReader and AVAssetWriter. The video is
/// copied as it is, not re-encoded. The original is not touched until the copy is complete, and then replaced by it.
enum RecordingAudioMixer {
    enum Failure: Error { case nothingToMix, readFailed(String), writeFailed(String) }

    /// Mixes every audio track of the movie into one. A movie with fewer than two audio tracks is left as it is.
    static func mix(_ url: URL, channels: Int = 2) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mixing.mov")
        try? FileManager.default.removeItem(at: temporary)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        var copies: [(AVAssetReaderOutput, AVAssetWriterInput)] = []

        if let video = videoTracks.first {
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await video.load(.formatDescriptions).first)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw Failure.readFailed("The video could not be copied.") }
            reader.add(output); writer.add(input)
            copies.append((output, input))
        }
        // All the audio tracks come out as one mixed stream, which is written as one AAC track.
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(mixOutput), writer.canAdd(audioInput) else { throw Failure.readFailed("The sound could not be mixed.") }
        reader.add(mixOutput); writer.add(audioInput)
        copies.append((mixOutput, audioInput))

        guard reader.startReading() else { throw Failure.readFailed(reader.error?.localizedDescription ?? "The recording could not be read.") }
        guard writer.startWriting() else { throw Failure.writeFailed(writer.error?.localizedDescription ?? "The new file could not be started.") }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (output, input) in copies {
                group.addTask {
                    let queue = DispatchQueue(label: "app.kriya.mix.\(UUID().uuidString)")
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if let buffer = output.copyNextSampleBuffer() { input.append(buffer) } else { input.markAsFinished(); done.resume(); return }
                            }
                        }
                    }
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.writeFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "The mixed file could not be finished.")
        }
        // The copy is complete: it replaces the original.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
