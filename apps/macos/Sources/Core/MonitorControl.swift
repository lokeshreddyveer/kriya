import Foundation

/// DDC/CI: the standard way a computer asks an external monitor to change its brightness or input. Which settings a monitor
/// answers to depends on the monitor, so nothing here is assumed: Kriya asks first and only shows what the monitor reports.
enum DDC {
    /// The feature codes (VCP codes) this uses.
    static let brightness: UInt8 = 0x10
    static let inputSource: UInt8 = 0x60

    /// The checksum seed: the monitor's write address (0x6E) and the data address (0x51) are part of the sum but not of the data.
    private static let seed: UInt8 = 0x6E ^ 0x51

    private static func sealed(_ body: [UInt8]) -> [UInt8] { body + [body.reduce(seed, ^)] }

    /// The bytes to write after the data address to set a feature to a value.
    static func setPacket(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        sealed([0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// The bytes to write to ask for a feature's value.
    static func getRequest(_ vcp: UInt8) -> [UInt8] { sealed([0x82, 0x01, vcp]) }

    struct Reading: Equatable {
        var current: Int
        var maximum: Int
    }

    /// Reads a monitor's answer to a get request: 11 bytes with the feature code echoed and a "no error" result. Nil for anything
    /// else, including an answer to a different feature or a feature the monitor says it does not have.
    static func parseReply(_ bytes: [UInt8], vcp: UInt8) -> Reading? {
        guard bytes.count >= 11, bytes[2] == 0x02, bytes[3] == 0x00, bytes[4] == vcp else { return nil }
        let maximum = Int(bytes[6]) << 8 | Int(bytes[7])
        let current = Int(bytes[8]) << 8 | Int(bytes[9])
        guard maximum > 0 || vcp == inputSource, current >= 0 else { return nil }
        return Reading(current: current, maximum: maximum)
    }

    /// Inputs a monitor commonly lists. A monitor may use other numbers, which are shown as "Input 0x…".
    static let inputs: [(code: Int, name: String)] = [
        (0x01, "VGA 1"), (0x03, "DVI 1"), (0x0F, "DisplayPort 1"), (0x10, "DisplayPort 2"),
        (0x11, "HDMI 1"), (0x12, "HDMI 2"), (0x1B, "USB-C"),
    ]

    static func inputName(_ code: Int) -> String {
        inputs.first { $0.code == code }?.name ?? "Input 0x" + String(code, radix: 16, uppercase: true)
    }

    /// A brightness percentage as the monitor's own scale, and back.
    static func raw(fromPercent percent: Int, maximum: Int) -> UInt16 {
        UInt16(min(max(Double(percent) / 100 * Double(maximum), 0), Double(min(maximum, Int(UInt16.max)))).rounded())
    }

    static func percent(fromRaw raw: Int, maximum: Int) -> Int {
        maximum <= 0 ? 0 : min(max(Int((Double(raw) / Double(maximum) * 100).rounded()), 0), 100)
    }
}

/// One monitor's wanted settings in a preset. Either may be left out.
struct MonitorSetting: Codable, Equatable, Identifiable {
    /// The monitor's name as Kriya showed it when the preset was saved.
    var monitor: String
    var brightnessPercent: Int?
    var inputCode: Int?
    var id: String { monitor }
}

struct MonitorPreset: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var settings: [MonitorSetting]
}

enum MonitorPresets {
    static let limit = 20

    /// What a preset would change on the monitors connected now, in words, before it is applied. Monitors not connected are named
    /// as skipped.
    static func plan(_ preset: MonitorPreset, connected: [String]) -> [String] {
        preset.settings.map { setting in
            guard connected.contains(setting.monitor) else { return "\(setting.monitor): not connected, skipped" }
            var parts: [String] = []
            if let b = setting.brightnessPercent { parts.append("brightness \(min(max(b, 0), 100))%") }
            if let i = setting.inputCode { parts.append("input \(DDC.inputName(i))") }
            return "\(setting.monitor): " + (parts.isEmpty ? "nothing to change" : parts.joined(separator: ", "))
        }
    }
}
