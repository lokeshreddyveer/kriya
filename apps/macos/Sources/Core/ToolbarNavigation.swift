import Foundation

/// Moving through the selection bar with the keyboard: arrows or Tab to move, Return to run, a digit to run that one, Escape to leave.
struct ToolbarNavigator: Equatable {
    enum Key: Equatable {
        case left, right, tab, backTab, home, end, enter, escape, digit(Int)
    }

    enum Outcome: Equatable {
        case moved, choose(Int), close, ignored
    }

    let count: Int
    private(set) var index = 0

    init(count: Int) { self.count = max(count, 0) }

    mutating func handle(_ key: Key) -> Outcome {
        guard count > 0 else { return key == .escape ? .close : .ignored }
        switch key {
        case .right, .tab: index = (index + 1) % count; return .moved
        case .left, .backTab: index = (index - 1 + count) % count; return .moved
        case .home: index = 0; return .moved
        case .end: index = count - 1; return .moved
        case .enter: return .choose(index)
        case .escape: return .close
        case .digit(let n):
            // 1 to 9 run the first nine; 0 is not used.
            guard (1...min(9, count)).contains(n) else { return .ignored }
            index = n - 1
            return .choose(index)
        }
    }

    /// What is said to VoiceOver when the highlight moves.
    func announcement(titles: [String]) -> String {
        guard titles.indices.contains(index) else { return "" }
        return "\(titles[index]), \(index + 1) of \(titles.count)"
    }

    /// Maps a key press (key code and characters) to a key, or nil for anything else.
    static func key(keyCode: UInt16, characters: String?, shift: Bool) -> Key? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 48: return shift ? .backTab : .tab
        case 115: return .home
        case 119: return .end
        case 36, 76: return .enter
        case 53: return .escape
        default:
            if let c = characters, c.count == 1, let n = Int(c) { return .digit(n) }
            return nil
        }
    }
}
