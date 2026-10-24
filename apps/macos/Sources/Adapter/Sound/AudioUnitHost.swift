import AVFoundation
import AudioToolbox

/// Audio Unit effects installed on this Mac (version 2 and version 3), found through the system's component list.
enum AudioUnitCatalog {
    static func effects() -> [PluginRef] {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        let components = AVAudioUnitComponentManager.shared().components(matching: description)
        description.componentType = 0
        var seen = Set<String>()
        var out: [PluginRef] = []
        for c in components {
            let d = c.audioComponentDescription
            let id = PluginRef.id(type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer)
            guard seen.insert(id).inserted, !c.name.isEmpty, c.hasMIDIInput == false else { continue }
            out.append(PluginRef(id: id, name: c.name, manufacturer: c.manufacturerName))
        }
        return out.sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }

    static func description(for ref: PluginRef) -> AudioComponentDescription? {
        guard let c = ref.codes else { return nil }
        return AudioComponentDescription(componentType: c.type, componentSubType: c.subtype, componentManufacturer: c.manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}

/// A stack of Audio Unit effects that sound goes through, one after another, on the audio thread. An `AVAudioEngine` in real-time
/// manual-rendering mode hosts the plug-ins (it handles version 2 and version 3 units alike) and is driven from the mixer's own
/// audio callback. Stereo only: with any other channel count the plug-ins are skipped. All memory is made when the chain is built.
final class AudioUnitChain {
    struct Slot {
        let id: String
        let node: AVAudioUnit
        var unit: AUAudioUnit { node.auAudioUnit }
        var bypassed: Bool
    }

    static let maxFrames = 4096
    private(set) var slots: [Slot] = []
    private let sampleRate: Double
    private let format: AVAudioFormat
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var renderBlock: AVAudioEngineManualRenderingBlock?
    private let planar: [UnsafeMutablePointer<Float>]
    private let outRaw: UnsafeMutableRawPointer
    private let outList: UnsafeMutablePointer<AudioBufferList>
    // What the source node should hand to the first plug-in for the render in progress.
    private var inL: UnsafeMutablePointer<Float>
    private var inR: UnsafeMutablePointer<Float>
    private var inFrames = 0
    private var lock = os_unfair_lock_s()
    private(set) var isRunning = false
    /// The result of the last render, for diagnosing a plug-in that does nothing.
    private(set) var lastStatus: AVAudioEngineManualRenderingStatus = .success

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2)!
        planar = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            p.initialize(repeating: 0, count: Self.maxFrames)
            return p
        }
        let size = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        outRaw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        outList = outRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        outList.pointee.mNumberBuffers = 2
        inL = planar[0]
        inR = planar[1]
    }

    deinit {
        stop()
        for p in planar { p.deallocate() }
        outRaw.deallocate()
    }

    var isEmpty: Bool { slots.isEmpty }

    func stop() {
        if engine.isRunning { engine.stop() }
        isRunning = false
    }

    /// Loads the plug-ins (off the audio thread), joins them in order and starts the engine. Reports the ones that failed.
    func load(_ refs: [PluginRef], completion: @escaping ([String]) -> Void) {
        var failed: [String] = []
        var built: [String: AVAudioUnit] = [:]
        let group = DispatchGroup()
        for ref in refs.prefix(PluginRef.maxPerApp) {
            guard let description = AudioUnitCatalog.description(for: ref) else { failed.append(ref.name); continue }
            group.enter()
            AVAudioUnit.instantiate(with: description, options: []) { node, error in
                defer { group.leave() }
                guard let node else { failed.append("\(ref.name) (\(error?.localizedDescription ?? "could not start"))"); return }
                if let state = ref.state, let plist = try? PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? [String: Any] {
                    node.auAudioUnit.fullState = plist
                }
                node.auAudioUnit.shouldBypassEffect = ref.bypassed
                built[ref.id] = node
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            var chain: [Slot] = []
            for ref in refs.prefix(PluginRef.maxPerApp) {
                if let node = built[ref.id] { chain.append(Slot(id: ref.id, node: node, bypassed: ref.bypassed)) }
            }
            do { try self.assemble(chain) } catch { failed.append("effects (\(error.localizedDescription))"); chain = [] }
            os_unfair_lock_lock(&self.lock)
            self.slots = chain
            os_unfair_lock_unlock(&self.lock)
            completion(failed)
        }
    }

    private func assemble(_ chain: [Slot]) throws {
        stop()
        guard !chain.isEmpty else { return }
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, data in
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            let n = min(Int(frameCount), self.inFrames)
            if buffers.count >= 2, let l = buffers[0].mData, let r = buffers[1].mData {
                memcpy(l, self.inL, n * MemoryLayout<Float>.size)
                memcpy(r, self.inR, n * MemoryLayout<Float>.size)
                if n < Int(frameCount) {
                    memset(l + n * MemoryLayout<Float>.size, 0, (Int(frameCount) - n) * MemoryLayout<Float>.size)
                    memset(r + n * MemoryLayout<Float>.size, 0, (Int(frameCount) - n) * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
        self.source = source
        engine.attach(source)
        var previous: AVAudioNode = source
        for slot in chain {
            engine.attach(slot.node)
            engine.connect(previous, to: slot.node, format: format)
            previous = slot.node
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        renderBlock = engine.manualRenderingBlock
        isRunning = true
    }

    func setBypassed(_ id: String, _ value: Bool) {
        os_unfair_lock_lock(&lock)
        if let i = slots.firstIndex(where: { $0.id == id }) { slots[i].bypassed = value; slots[i].node.auAudioUnit.shouldBypassEffect = value }
        os_unfair_lock_unlock(&lock)
    }

    /// The plug-ins' current settings, to be saved with the app's settings.
    func states() -> [String: Data] {
        var out: [String: Data] = [:]
        for slot in slots {
            if let state = slot.unit.fullState, let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) { out[slot.id] = data }
        }
        return out
    }

    /// Runs interleaved stereo audio through the plug-ins, in place. Called on the audio thread.
    func process(_ interleaved: UnsafeMutablePointer<Float>, frames: Int) {
        guard isRunning, let renderBlock, frames > 0, frames <= Self.maxFrames, os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        let left = planar[0], right = planar[1]
        for f in 0..<frames { left[f] = interleaved[f * 2]; right[f] = interleaved[f * 2 + 1] }
        inL = left; inR = right; inFrames = frames
        let buffers = UnsafeMutableAudioBufferListPointer(outList)
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: nil)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: nil)
        var error: OSStatus = noErr
        lastStatus = renderBlock(AVAudioFrameCount(frames), outList, &error)
        guard lastStatus == .success,
              let l = buffers[0].mData?.assumingMemoryBound(to: Float.self), let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        for f in 0..<frames { interleaved[f * 2] = l[f]; interleaved[f * 2 + 1] = r[f] }
    }
}
