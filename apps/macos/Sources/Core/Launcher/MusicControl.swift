import Foundation

/// Controlling the music apps with AppleScript: Music and Spotify. macOS has no public way to control "whatever is playing",
/// so each app is asked by name, and only if it is already running.
enum MusicControl {
    enum Player: String, CaseIterable, Identifiable {
        case music = "Music"
        case spotify = "Spotify"
        var id: String { rawValue }
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }

    enum Command: String, CaseIterable, Identifiable {
        case playPause, next, previous, nowPlaying
        var id: String { rawValue }

        var title: String {
            switch self {
            case .playPause: return "Play or pause"
            case .next: return "Next track"
            case .previous: return "Previous track"
            case .nowPlaying: return "Show what is playing"
            }
        }

        var symbol: String {
            switch self {
            case .playPause: return "playpause.fill"
            case .next: return "forward.fill"
            case .previous: return "backward.fill"
            case .nowPlaying: return "music.note"
            }
        }

        /// The command name other parts of Kriya use: `music.playpause`.
        var commandName: String { "music." + rawValue.lowercased() }
    }

    static func script(_ command: Command, player: Player) -> String {
        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .nowPlaying:
            body = """
            if player state is stopped then return ""
            return (name of current track) & "\u{1F}" & (artist of current track) & "\u{1F}" & (player state as string)
            """
        }
        return "tell application \"\(player.rawValue)\"\n\(body)\nend tell"
    }

    struct NowPlaying: Equatable {
        let title: String
        let artist: String
        let state: String
        var text: String { artist.isEmpty ? title : "\(title) — \(artist)" }
    }

    /// What the "now playing" script answered. Nil when nothing is loaded.
    static func parse(_ output: String) -> NowPlaying? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1F}")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return NowPlaying(title: parts[0], artist: parts[1], state: parts.count > 2 ? parts[2] : "")
    }

    /// The players that are running, the one playing first if that is known.
    static func running(_ bundleIDs: Set<String>) -> [Player] {
        Player.allCases.filter { bundleIDs.contains($0.bundleID) }
    }
}
