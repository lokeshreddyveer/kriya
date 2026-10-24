import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import VideoToolbox

/// Records the screen, a window or one app to a movie, with the Mac's sound and the microphone as separate audio tracks.
///
/// One ScreenCaptureKit stream feeds one AVAssetWriter on every supported macOS. Pausing cuts the paused time out of the file
/// (see `PauseClock`), so there is one file and no gap. The keystroke display and the camera are ordinary windows on screen
/// that the stream captures, so nothing is drawn into frames here.
final class ScreenRecorder: NSObject, ObservableObject {
    enum State: Equatable { case idle, starting, recording, paused, stopping }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Stop was pressed before the recording had started: it ends as soon as the start is through, without a file and without an error.
    struct Cancelled: Error {}
    private let cancelLock = NSLock()
    private var cancelStartValue = false
    private var cancelStart: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelStartValue }
        set { cancelLock.lock(); cancelStartValue = newValue; cancelLock.unlock() }
    }

    @Published private(set) var state: State = .idle
    /// Seconds recorded so far, not counting time paused.
    @Published private(set) var elapsed: TimeInterval = 0

    /// Called on the main thread when a recording ends: the file, or why there is none.
    var onFinish: (Result<URL, Error>) -> Void = { _ in }

    // Everything below is touched only on `queue`, except where noted.
    private let queue = DispatchQueue(label: "app.kriya.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micSession: AVCaptureSession?
    private var clock = PauseClock()
    private var options = RecordingOptions()
    private var outputURL: URL?
    /// The capture clock's time of the first frame; written times count from it.
    private var base: Double?
    private var lastWritten: Double = 0
    private var finishing = false
    private var framesWritten = 0
    private let elapsedLock = NSLock()
    private var elapsedValue: TimeInterval = 0
    private var timer: Timer?

    var isActive: Bool { state != .idle }

    // MARK: Starting

    /// Whether this Mac can record in HDR.
    static var hdrAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Starts recording into `folder`. `excluding` are the numbers of Kriya's own windows (the controls) that must stay out of
    /// the video. The result of starting arrives through `completion`.
    func start(options requested: RecordingOptions, into folder: URL, excluding hidden: [Int], fileName: String? = nil, target: NSRunningApplication? = nil, completion: @escaping (Error?) -> Void) {
        guard state == .idle else { return completion(Failure("A recording is already running.")) }
        let options = requested.sanitized(hdrAvailable: Self.hdrAvailable)
        cancelStart = false
        setState(.starting)
        Task {
            do {
                try await Self.askPermissions(for: options)
                if cancelStart { throw Cancelled() }
                let content = try await Self.shareableContent()
                if cancelStart { throw Cancelled() }
                let filter = try Self.filter(for: options.source, in: content, excluding: hidden, target: target)
                let configuration = Self.configuration(for: filter, options: options)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let name = fileName ?? RecordingFileName.make(for: Date()) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
                let url = folder.appendingPathComponent(name)
                try await begin(filter: filter, configuration: configuration, options: options, url: url)
                if cancelStart { throw Cancelled() }   // the stream just started is ended by the clean-up below
                await MainActor.run {
                    self.setState(.recording)
                    self.startTimer()
                    completion(nil)
                }
            } catch {
                await cleanUpAfterFailedStart()
                await MainActor.run {
                    self.setState(.idle)
                    completion(error)
                }
            }
        }
    }

    private func begin(filter: SCContentFilter, configuration: SCStreamConfiguration, options: RecordingOptions, url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.options = options
                self.outputURL = url
                self.clock = PauseClock(frameDuration: 1.0 / Double(options.framesPerSecond))
                self.base = nil
                self.lastWritten = 0
                self.finishing = false
                self.framesWritten = 0
                self.writer = nil
                self.videoInput = nil
                self.systemAudioInput = nil
                self.micInput = nil
                self.setElapsed(0)
                continuation.resume()
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if options.microphone { try startMicrophone() }
        queue.sync { self.stream = stream }
        try await stream.startCapture()
    }

    // MARK: Pause, resume, stop

    func pause() {
        queue.async {
            guard self.state == .recording else { return }
            self.clock.pause()
            DispatchQueue.main.async { self.setState(.paused) }
        }
    }

    func resume() {
        queue.async {
            guard self.state == .paused else { return }
            self.clock.resume()
            DispatchQueue.main.async { self.setState(.recording) }
        }
    }

    func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
    }

    func stop() {
        // Pressed while the recording is still starting (waiting for permission, or for the screen to be found): the start notices
        // and ends cleanly. Before this, the press was ignored and the recording began anyway.
        if state == .starting { cancelStart = true; return }
        guard state == .recording || state == .paused else { return }
        setState(.stopping)
        stopTimer()
        Task {
            if let stream = queue.sync(execute: { self.stream }) { try? await stream.stopCapture() }
            stopMicrophone()
            finish(with: nil)
        }
    }

    // MARK: Finishing

    private func finish(with error: Error?) {
        queue.async {
            guard !self.finishing else { return }
            self.finishing = true
            self.stream = nil
            let url = self.outputURL
            guard let writer = self.writer, self.framesWritten > 0, let url else {
                self.writer?.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                self.reset()
                DispatchQueue.main.async {
                    self.setState(.idle)
                    self.onFinish(.failure(error ?? Failure("Nothing was recorded. Allow Screen Recording for Kriya in System Settings, restart Kriya, and try again.")))
                }
                return
            }
            [self.videoInput, self.systemAudioInput, self.micInput].forEach { $0?.markAsFinished() }
            writer.finishWriting {
                let failed = writer.status == .failed ? writer.error : nil
                self.queue.async {
                    self.reset()
                    DispatchQueue.main.async {
                        self.setState(.idle)
                        self.onFinish(failed.map { .failure($0) } ?? error.map { .failure($0) } ?? .success(url))
                    }
                }
            }
        }
    }

    private func reset() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
        outputURL = nil
        base = nil
    }

    private func cleanUpAfterFailedStart() async {
        if let stream = queue.sync(execute: { self.stream }) { try? await stream.stopCapture() }
        stopMicrophone()
        queue.sync {
            self.writer?.cancelWriting()
            self.stream = nil
            self.reset()
        }
    }

    // MARK: Permissions and what to capture

    private static func askPermissions(for options: RecordingOptions) async throws {
        if options.microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw Failure("Allow the microphone for Kriya in System Settings › Privacy & Security, or turn the microphone off for recordings.") }
        }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // The first time Screen Recording is allowed it only takes effect after the app is opened again.
            throw Failure("Kriya cannot see the screen yet. Allow Screen Recording for Kriya in System Settings › Privacy & Security, then quit and open Kriya again.")
        }
    }

    private static func pointerDisplay(in content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    /// `target` is the app that was in front when the recording was asked for. Finding the screen and the windows takes a moment, and the
    /// person may switch apps meanwhile; the recording is of the app they asked about, not whichever is in front by then.
    static func filter(for source: RecordingSource, in content: SCShareableContent, excluding hidden: [Int], target: NSRunningApplication? = nil) throws -> SCContentFilter {
        guard let display = pointerDisplay(in: content) else { throw Failure("There is no screen to record.") }
        let own = content.windows.filter { hidden.contains(Int($0.windowID)) }
        switch source {
        case .screen:
            return SCContentFilter(display: display, excludingWindows: own)
        case .window:
            guard let window = frontWindow(in: content, app: target) else { throw Failure("There is no window in front to record.") }
            return SCContentFilter(desktopIndependentWindow: window)
        case .app:
            guard let pid = (target ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier,
                  let app = content.applications.first(where: { $0.processID == pid }) else { throw Failure("There is no app in front to record.") }
            return SCContentFilter(display: display, including: [app], exceptingWindows: own)
        }
    }

    /// The front window of the front app: the one Accessibility says is focused if that is allowed, otherwise its largest.
    private static func frontWindow(in content: SCShareableContent, app requested: NSRunningApplication? = nil) -> SCWindow? {
        guard let app = requested ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50 }
        if AXIsProcessTrusted(), let focused = AXWindow.focused()?.frame?.cg {
            if let match = candidates.min(by: { distance($0.frame, focused) < distance($1.frame, focused) }), distance(match.frame, focused) < 40 { return match }
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    static func configuration(for filter: SCContentFilter, options: RecordingOptions) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        // Even sizes: video encoders need them.
        configuration.width = max(2, Int(info.contentRect.width * scale) / 2 * 2)
        configuration.height = max(2, Int(info.contentRect.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        configuration.showsCursor = options.showCursor
        configuration.queueDepth = 6
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if options.hdr, #available(macOS 15.0, *) {
            configuration.captureDynamicRange = .hdrLocalDisplay
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        return configuration
    }

    // MARK: The movie file

    private func makeWriter(width: Int, height: Int) throws {
        guard let url = outputURL else { throw Failure("No place to save the recording.") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let hdr = options.hdr && Self.hdrAvailable
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Self.bitRate(width: width, height: height, fps: options.framesPerSecond, hdr: hdr),
            AVVideoExpectedSourceFrameRateKey: options.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond * 2,
        ]
        var settings: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
        if hdr {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        settings[AVVideoCompressionPropertiesKey] = compression
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw Failure("The recording could not be set up.") }
        writer.add(video)
        videoInput = video

        if options.systemAudio {
            let input = Self.audioInput(channels: 2)
            if writer.canAdd(input) { writer.add(input); systemAudioInput = input }
        }
        if options.microphone {
            let input = Self.audioInput(channels: 1)
            if writer.canAdd(input) { writer.add(input); micInput = input }
        }
        guard writer.startWriting() else { throw writer.error ?? Failure("The recording file could not be started.") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Enough bits for a screen that is mostly still with bursts of motion, without making huge files.
    static func bitRate(width: Int, height: Int, fps: Int, hdr: Bool) -> Int {
        let perPixel = hdr ? 0.10 : 0.07
        let rate = Double(width * height) * Double(fps) * perPixel
        return Int(min(max(rate, 2_000_000), 80_000_000))
    }

    // MARK: Samples

    private func write(video buffer: CMSampleBuffer) {
        guard !finishing else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if base == nil {
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { return }
            do { try makeWriter(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) } catch {
                finish(with: error)
                return
            }
            base = time
        }
        guard let base, let written = clock.video(at: time - base), let input = videoInput, input.isReadyForMoreMediaData,
              let retimed = Self.retimed(buffer, to: written) else { return }
        if input.append(retimed) {
            framesWritten += 1
            lastWritten = written
            setElapsed(written)
        } else if writer?.status == .failed {
            finish(with: writer?.error)
        }
    }

    private func write(audio buffer: CMSampleBuffer, to input: AVAssetWriterInput?, at time: Double) {
        guard !finishing, let base, let input, input.isReadyForMoreMediaData, writer?.status == .writing,
              let written = clock.audio(at: time - base), let retimed = Self.retimed(buffer, to: written) else { return }
        input.append(retimed)
    }

    /// A copy of the buffer that starts at `time` seconds.
    private static func retimed(_ buffer: CMSampleBuffer, to time: Double) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        let first = timing[0].presentationTimeStamp
        let target = CMTime(seconds: time, preferredTimescale: 600_000)
        let shift = CMTimeSubtract(first, target)
        for index in 0..<count {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, shift)
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, shift) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: timing, sampleBufferOut: &out)
        return out
    }

    // MARK: Microphone

    private func startMicrophone() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Failure("There is no microphone to record.") }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure("The microphone could not be used.") }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        micSession = session
        session.startRunning()
    }

    private func stopMicrophone() {
        micSession?.stopRunning()
        micSession = nil
    }

    // MARK: Elapsed time

    private func setElapsed(_ value: TimeInterval) {
        elapsedLock.lock()
        elapsedValue = value
        elapsedLock.unlock()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedLock.lock()
            let value = self.elapsedValue
            self.elapsedLock.unlock()
            if self.state == .recording || self.state == .paused { self.elapsed = value }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func setState(_ value: State) {
        if Thread.isMainThread { state = value } else { DispatchQueue.main.async { self.state = value } }
        if value == .idle { stopTimer() }
    }
}

// MARK: - Receiving samples

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Frames that only say "nothing changed" carry no picture.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            write(video: sampleBuffer)
        case .audio:
            write(audio: sampleBuffer, to: systemAudioInput, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stopped from outside: the screen was locked, the window closed, or permission was taken away. Keep what was recorded.
        DispatchQueue.main.async {
            guard self.state == .recording || self.state == .paused else { return }
            self.setState(.stopping)
            self.stopTimer()
            self.stopMicrophone()
            self.finish(with: nil)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The microphone's times are on the capture session's clock; bring them onto the one the screen uses.
        var time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let session = micSession, let source = session.synchronizationClock {
            time = CMSyncConvertTime(time, from: source, to: CMClockGetHostTimeClock())
        }
        write(audio: sampleBuffer, to: micInput, at: time.seconds)
    }
}
