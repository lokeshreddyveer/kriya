import Foundation

/// What a sound device is and how it behaves, worked out from what Core Audio reports, for the device inspector.
struct DeviceDetails: Equatable {
    enum Transport: String {
        case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, thunderbolt, firewire, pci, virtual, aggregate, unknown

        /// From the four-character code Core Audio gives a device's transport.
        init(code: UInt32) {
            switch code {
            case 0x626C746E: self = .builtIn            // 'bltn'
            case 0x75736220: self = .usb                // 'usb '
            case 0x626C7565: self = .bluetooth          // 'blue'
            case 0x626C6561: self = .bluetoothLE        // 'blea'
            case 0x68646D69: self = .hdmi               // 'hdmi'
            case 0x64707274: self = .displayPort        // 'dprt'
            case 0x61697270: self = .airPlay            // 'airp'
            case 0x7468756E: self = .thunderbolt        // 'thun'
            case 0x31333934: self = .firewire           // '1394'
            case 0x70636920: self = .pci                // 'pci '
            case 0x76697274: self = .virtual            // 'virt'
            case 0x67727570: self = .aggregate          // 'grup'
            default: self = .unknown
            }
        }

        var title: String {
            switch self {
            case .builtIn: return "Built in"
            case .usb: return "USB"
            case .bluetooth: return "Bluetooth"
            case .bluetoothLE: return "Bluetooth LE"
            case .hdmi: return "HDMI"
            case .displayPort: return "DisplayPort"
            case .airPlay: return "AirPlay"
            case .thunderbolt: return "Thunderbolt"
            case .firewire: return "FireWire"
            case .pci: return "PCI"
            case .virtual: return "Virtual"
            case .aggregate: return "Aggregate"
            case .unknown: return "Unknown"
            }
        }

        var symbol: String {
            switch self {
            case .bluetooth, .bluetoothLE: return "headphones"
            case .usb: return "cable.connector"
            case .hdmi, .displayPort: return "display"
            case .airPlay: return "airplayaudio"
            case .builtIn: return "laptopcomputer"
            case .virtual, .aggregate: return "square.stack.3d.up"
            default: return "speaker.wave.2"
            }
        }

        /// Bluetooth adds the most delay, and says so.
        var isWireless: Bool { self == .bluetooth || self == .bluetoothLE || self == .airPlay }
    }

    var name: String
    var uid: String
    var transport: Transport
    var isOutput: Bool
    var isInput: Bool
    var sampleRate: Double
    var availableRates: [Double]
    var outputChannels: Int
    var inputChannels: Int
    var bufferFrames: Int
    /// Frames of delay the device and its streams report, plus its safety offset.
    var deviceLatencyFrames: Int
    var streamLatencyFrames: Int
    var safetyOffsetFrames: Int
    /// Whether the device has a volume control of its own, or only the software one Kriya adds.
    var hasHardwareVolume: Bool
    var hasHardwareMute: Bool
    var hasBalance: Bool
    var isHidden: Bool
    var manufacturer: String?

    /// How long sound takes to get through, in milliseconds: the device's own delay, its streams', the safety offset and one buffer.
    var latencyMilliseconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(deviceLatencyFrames + streamLatencyFrames + safetyOffsetFrames + bufferFrames) / sampleRate * 1000
    }

    var channelsText: String {
        func word(_ n: Int) -> String { n == 1 ? "mono" : n == 2 ? "stereo" : "\(n) channels" }
        var parts: [String] = []
        if isOutput { parts.append("out: \(word(outputChannels))") }
        if isInput { parts.append("in: \(word(inputChannels))") }
        return parts.joined(separator: ", ")
    }

    var rateText: String { Self.rate(sampleRate) }

    static func rate(_ hz: Double) -> String {
        hz >= 1000 ? (hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000)) kHz" : String(format: "%.1f kHz", hz / 1000)) : "\(Int(hz)) Hz"
    }

    /// A plain sentence about the delay: what it is, and whether it matters for video or playing along.
    var latencyAdvice: String {
        let ms = latencyMilliseconds
        let text = String(format: "%.0f ms", ms)
        if transport.isWireless && ms >= 100 { return "\(text). Wireless connections add delay; video apps usually adjust for it, but playing an instrument along with it will feel late." }
        if ms >= 60 { return "\(text). Noticeable when playing along; fine for listening." }
        if ms >= 20 { return "\(text). Fine for listening and video." }
        return "\(text). Low enough to play along with."
    }

    /// Lines for the inspector, in the order shown: a label and a value.
    var rows: [(label: String, value: String)] {
        var list: [(String, String)] = [
            ("Name", name), ("Connection", transport.title), ("Direction", [isOutput ? "output" : nil, isInput ? "input" : nil].compactMap { $0 }.joined(separator: " and ")),
            ("Sample rate", rateText), ("Channels", channelsText),
            ("Buffer", "\(bufferFrames) frames"), ("Delay", latencyAdvice),
            ("Volume", hasHardwareVolume ? "The device has its own volume" : "No volume of its own: Kriya's software volume is used"),
            ("Mute", hasHardwareMute ? "The device can mute itself" : "No mute of its own"),
            ("Balance", hasBalance ? "Left and right can be balanced" : "Not available"),
            ("Identifier", uid),
        ]
        if let manufacturer, !manufacturer.isEmpty { list.insert(("Made by", manufacturer), at: 2) }
        if availableRates.count > 1 { list.append(("Other rates", availableRates.map(Self.rate).joined(separator: ", "))) }
        if isHidden { list.append(("Hidden", "Not shown in the mixer")) }
        return list
    }
}
