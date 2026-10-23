import AppKit

extension LauncherSources {
    /// "volume 40", "volume up", and one entry for each sound output and input to switch to.
    func soundEntries(_ text: String) -> [PaletteEntry] {
        guard let audio else { return [] }
        var found: [PaletteEntry] = []
        if let request = AudioMath.request(in: text) {
            switch request {
            case .set(let percent):
                found.append(entry("audio:set", "Set the volume to \(percent)%", "Sound output", "speaker.wave.2") { audio.set(percent: percent) })
            case .up: found.append(entry("audio:up", "Turn the volume up", "Sound output", "speaker.plus") { audio.nudge(up: true) })
            case .down: found.append(entry("audio:down", "Turn the volume down", "Sound output", "speaker.minus") { audio.nudge(up: false) })
            case .mute: found.append(entry("audio:mute", "Mute or unmute the sound", "Sound output", "speaker.slash") { audio.toggleMute(input: false) })
            }
        }
        let lowered = text.lowercased()
        let words = ["output", "speaker", "headphone", "sound", "audio", "mic", "input", "switch"]
        if words.contains(where: { lowered.contains($0) }) {
            let current = (audio.defaultDevice(input: false), audio.defaultDevice(input: true))
            for device in audio.devices() {
                let isCurrent = device.isOutput ? device.id == current.0 : device.id == current.1
                found.append(entry("audio:device:\(device.id)", "\(device.isOutput ? "Play sound on" : "Use the microphone") \(device.name)", isCurrent ? "In use now" : (device.isOutput ? "Sound output" : "Sound input"), device.isOutput ? "hifispeaker" : "mic") {
                    if audio.setDefault(device) { Toast().show("\(device.isOutput ? "Sound output" : "Microphone"): \(device.name)") }
                })
            }
        }
        return found
    }

    /// Copies this Mac's address on the network when "ip" or "my ip" is typed.
    func addressEntries(_ text: String) -> [PaletteEntry] {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard ["ip", "my ip", "ip address", "local ip"].contains(lowered), let address = NetworkAddress.local() else { return [] }
        return [entry("ip:local", address, "Local address, press Return to copy", "network") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            Toast().show("Copied \(address)")
        }]
    }

    private func entry(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, run: @escaping () -> Void) -> PaletteEntry {
        var e = PaletteEntry(id: id, title: title, subtitle: subtitle, symbol: symbol, rememberable: false, run: run)
        e.queryScore = 700
        return e
    }
}

enum NetworkAddress {
    /// The first private IPv4 address of an active network interface.
    static func local() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var wifi: String?, other: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if String(cString: i.ifa_name) == "en0" { wifi = value } else if other == nil { other = value }
        }
        return wifi ?? other
    }
}
