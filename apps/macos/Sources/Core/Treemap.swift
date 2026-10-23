import CoreGraphics
import Foundation

/// A rectangle for each item, with an area in proportion to its size, packed so the shapes stay close to square (the
/// "squarified" layout). This is how the disk map draws a folder.
enum Treemap {
    struct Item: Equatable {
        let id: String
        let size: Double
    }

    struct Tile: Equatable {
        let id: String
        let rect: CGRect
    }

    static func layout(_ items: [Item], in bounds: CGRect) -> [Tile] {
        let sorted = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = sorted.reduce(0) { $0 + $1.size }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        // Sizes become areas that exactly fill the bounds.
        let scale = Double(bounds.width * bounds.height) / total
        var remaining = sorted.map { ($0.id, $0.size * scale) }[...]
        var free = bounds
        var tiles: [Tile] = []
        while !remaining.isEmpty {
            let shortSide = Double(min(free.width, free.height))
            var row: [(String, Double)] = []
            var best = Double.infinity
            for candidate in remaining {
                let trial = row + [candidate]
                let worst = worstRatio(trial.map(\.1), side: shortSide)
                if worst <= best { row = trial; best = worst } else { break }
            }
            remaining = remaining.dropFirst(row.count)
            let rowArea = row.reduce(0) { $0 + $1.1 }
            if free.width >= free.height {
                // A column down the left edge.
                let width = CGFloat(rowArea / Double(free.height))
                var y = free.minY
                for (id, area) in row {
                    let h = CGFloat(area / Double(width))
                    tiles.append(Tile(id: id, rect: CGRect(x: free.minX, y: y, width: width, height: h)))
                    y += h
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: free.width - width, height: free.height)
            } else {
                // A row along the top edge.
                let height = CGFloat(rowArea / Double(free.width))
                var x = free.minX
                for (id, area) in row {
                    let w = CGFloat(area / Double(height))
                    tiles.append(Tile(id: id, rect: CGRect(x: x, y: free.minY, width: w, height: height)))
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: free.height - height)
            }
        }
        return tiles
    }

    /// The worst (largest) ratio of long side to short side among the tiles of a row laid along a side of this length.
    private static func worstRatio(_ areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard sum > 0, side > 0 else { return .infinity }
        let long = areas.max() ?? 0, short = areas.min() ?? 0
        let s2 = side * side
        return max(s2 * long / (sum * sum), (sum * sum) / (s2 * max(short, 1e-9)))
    }

    /// Small items are gathered into one "Smaller items" tile so the map is never a dust of unreadable slivers.
    static func grouped(_ items: [Item], minimumShare: Double = 0.012, otherID: String = "__other__") -> [Item] {
        let total = items.reduce(0) { $0 + $1.size }
        guard total > 0 else { return [] }
        let big = items.filter { $0.size / total >= minimumShare }
        let smallSum = items.filter { $0.size / total < minimumShare }.reduce(0) { $0 + $1.size }
        return smallSum > 0 ? big + [Item(id: otherID, size: smallSum)] : big
    }
}
