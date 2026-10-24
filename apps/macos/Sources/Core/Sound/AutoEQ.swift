import Foundation

/// Headphone correction from the AutoEq project's files. Its results come as a list of parametric filters (Equalizer APO's
/// `ParametricEQ.txt`) or as a curve (`GraphicEQ.txt`); Kriya's equaliser has ten bands, so the filters are worked out as a curve
/// and ten band gains are fitted to it by least squares, then refined against the real cascade of the ten bands.
enum AutoEQ {
    struct Filter: Equatable {
        enum Kind: Equatable { case peak, lowShelf, highShelf }
        var kind: Kind
        var frequency: Double
        var gainDB: Double
        var q: Double
    }

    struct Profile: Equatable {
        var preampDB: Double
        var filters: [Filter]
    }

    /// The ten gains fitted to a target, the preamp to go with them, and how far the result is from the target.
    struct Correction: Equatable, Codable {
        var gains: [Float]
        var preampDB: Float
        /// Root-mean-square difference between the ten bands' response and the target, in decibels, over 30 Hz to 16 kHz.
        var errorDB: Double
        var largestGainDB: Double { gains.map { Double(abs($0)) }.max() ?? 0 }
    }

    static let sampleRate = 48_000.0

    // MARK: Reading the files

    /// A `ParametricEQ.txt`: a `Preamp:` line and `Filter n: ON PK Fc 105 Hz Gain 2.4 dB Q 0.70` lines (PK, and LSC/HSC or LS/HS shelves).
    static func parseParametric(_ text: String) -> Profile? {
        var preamp = 0.0
        var filters: [Filter] = []
        let preampRe = try? NSRegularExpression(pattern: #"Preamp:\s*(-?[0-9.]+)\s*dB"#, options: .caseInsensitive)
        let filterRe = try? NSRegularExpression(pattern: #"Filter\s*[0-9]*:\s*ON\s+(PK|PEQ|LSC|HSC|LS|HS)\s+Fc\s+([0-9.]+)\s*Hz\s+Gain\s+(-?[0-9.]+)\s*dB(?:\s+Q\s+([0-9.]+))?"#, options: .caseInsensitive)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if let m = preampRe?.firstMatch(in: line, range: whole), let v = Double(ns.substring(with: m.range(at: 1))) { preamp = v; continue }
            guard let m = filterRe?.firstMatch(in: line, range: whole),
                  let f = Double(ns.substring(with: m.range(at: 2))), let g = Double(ns.substring(with: m.range(at: 3))), f > 0, f < 24_000, abs(g) <= 40 else { continue }
            let q = m.range(at: 4).location != NSNotFound ? (Double(ns.substring(with: m.range(at: 4))) ?? 0.707) : 0.707
            let kind: Filter.Kind
            switch ns.substring(with: m.range(at: 1)).uppercased() {
            case "LSC", "LS": kind = .lowShelf
            case "HSC", "HS": kind = .highShelf
            default: kind = .peak
            }
            filters.append(Filter(kind: kind, frequency: f, gainDB: g, q: min(max(q, 0.1), 20)))
        }
        return filters.isEmpty ? nil : Profile(preampDB: preamp, filters: filters)
    }

    /// A `GraphicEQ.txt`: `GraphicEQ: 20 -0.6; 21 -0.7; …`, a frequency and a gain for each point.
    static func parseGraphic(_ text: String) -> [(frequency: Double, gainDB: Double)]? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let points = text[text.index(after: colon)...].split(separator: ";").compactMap { pair -> (Double, Double)? in
            let parts = pair.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            guard parts.count == 2, let f = Double(parts[0]), let g = Double(parts[1]), f > 0, f < 30_000, abs(g) <= 60 else { return nil }
            return (f, g)
        }
        return points.count >= 4 ? points.sorted { $0.0 < $1.0 }.map { (frequency: $0.0, gainDB: $0.1) } : nil
    }

    // MARK: Response of filters

    /// Biquad coefficients, normalised, in the order (b0, b1, b2, a1, a2).
    static func coefficients(for filter: Filter, sampleRate: Double = sampleRate) -> (Double, Double, Double, Double, Double) {
        let A = pow(10, filter.gainDB / 40)
        let w0 = 2 * Double.pi * filter.frequency / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * filter.q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch filter.kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
            b2 = A * ((A + 1) - (A - 1) * cosw - s)
            a0 = (A + 1) + (A - 1) * cosw + s
            a1 = -2 * ((A - 1) + (A + 1) * cosw)
            a2 = (A + 1) + (A - 1) * cosw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 = A * ((A + 1) + (A - 1) * cosw - s)
            a0 = (A + 1) - (A - 1) * cosw + s
            a1 = 2 * ((A - 1) - (A + 1) * cosw)
            a2 = (A + 1) - (A - 1) * cosw - s
        }
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    /// How much one filter raises or lowers the sound at `frequency`, in decibels.
    static func magnitudeDB(_ filter: Filter, at frequency: Double, sampleRate: Double = sampleRate) -> Double {
        let (b0, b1, b2, a1, a2) = coefficients(for: filter, sampleRate: sampleRate)
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), c2 = cos(2 * w)
        let num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * c1 + 2 * b0 * b2 * c2
        let den = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * c1 + 2 * a2 * c2
        guard num > 0, den > 0 else { return 0 }
        return 10 * log10(num / den)
    }

    /// The decibel response of several filters in a row at `frequency` (decibels add).
    static func magnitudeDB(_ filters: [Filter], at frequency: Double) -> Double { filters.reduce(0) { $0 + magnitudeDB($1, at: frequency) } }

    // MARK: Fitting ten bands

    static let gridLow = 30.0, gridHigh = 16_000.0

    /// 48 points, evenly spaced in pitch, where the fit is judged.
    static let grid: [Double] = (0..<48).map { gridLow * pow(gridHigh / gridLow, Double($0) / 47) }

    /// The ten bands' filters for these gains, as Kriya's equaliser builds them.
    static func bandFilters(_ gains: [Double]) -> [Filter] {
        zip(EQBands.frequencies, gains).map { Filter(kind: .peak, frequency: Double($0), gainDB: $1, q: 1.1) }
    }

    /// Ten band gains that follow `target` (decibels at a frequency) as closely as ten bands can.
    static func fit(target: (Double) -> Double) -> (gains: [Double], errorDB: Double) {
        let want = grid.map(target)
        var gains = [Double](repeating: 0, count: EQBands.count)
        // Each band's response to one decibel of its own gain: the shape the fit adds up.
        let shapes: [[Double]] = (0..<EQBands.count).map { i in
            grid.map { magnitudeDB(Filter(kind: .peak, frequency: Double(EQBands.frequencies[i]), gainDB: 1, q: 1.1), at: $0) }
        }
        for _ in 0..<4 {
            let have = grid.map { magnitudeDB(bandFilters(gains), at: $0) }
            let residual = zip(want, have).map { $0 - $1 }
            let step = leastSquares(shapes: shapes, target: residual)
            for i in gains.indices { gains[i] = min(max(gains[i] + step[i], -Double(EQBands.limit)), Double(EQBands.limit)) }
        }
        let final = grid.map { magnitudeDB(bandFilters(gains), at: $0) }
        let error = sqrt(zip(want, final).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(grid.count))
        return (gains, error)
    }

    /// The gains that, added up as `shapes`, come closest to `target` (ridge-regularised so no band runs away).
    private static func leastSquares(shapes: [[Double]], target: [Double]) -> [Double] {
        let n = shapes.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for i in 0..<n {
            for j in 0..<n { a[i][j] = zip(shapes[i], shapes[j]).map(*).reduce(0, +) + (i == j ? 0.05 : 0) }
            a[i][n] = zip(shapes[i], target).map(*).reduce(0, +)
        }
        // Gaussian elimination with partial pivoting.
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) } ?? col
            a.swapAt(col, pivot)
            guard abs(a[col][col]) > 1e-12 else { continue }
            for row in (col + 1)..<max(n, col + 1) where row < n {
                let factor = a[row][col] / a[col][col]
                for k in col...n { a[row][k] -= factor * a[col][k] }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = a[row][n]
            for k in (row + 1)..<max(n, row + 1) where k < n { sum -= a[row][k] * x[k] }
            x[row] = abs(a[row][row]) > 1e-12 ? sum / a[row][row] : 0
        }
        return x
    }

    /// A correction from a parametric profile.
    static func correction(for profile: Profile) -> Correction {
        let fitted = fit { magnitudeDB(profile.filters, at: $0) }
        return Correction(gains: fitted.gains.map(Float.init), preampDB: preamp(profile.preampDB, gains: fitted.gains), errorDB: fitted.errorDB)
    }

    /// A correction from a curve of points (a graphic EQ file).
    static func correction(forCurve points: [(frequency: Double, gainDB: Double)]) -> Correction {
        let fitted = fit { f in interpolate(points, at: f) }
        let peak = points.map(\.gainDB).max() ?? 0
        return Correction(gains: fitted.gains.map(Float.init), preampDB: preamp(-max(peak, 0), gains: fitted.gains), errorDB: fitted.errorDB)
    }

    /// The curve's value at a frequency, straight between points on a pitch scale, held flat beyond its ends.
    static func interpolate(_ points: [(frequency: Double, gainDB: Double)], at f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.frequency { return first.gainDB }
        if f >= last.frequency { return last.gainDB }
        for i in 1..<points.count where f <= points[i].frequency {
            let (a, b) = (points[i - 1], points[i])
            let t = log(f / a.frequency) / log(b.frequency / a.frequency)
            return a.gainDB + (b.gainDB - a.gainDB) * t
        }
        return last.gainDB
    }

    /// The preamp to use: the file's own, lowered if the ten bands boost more than it allows for, so the sound cannot clip.
    private static func preamp(_ fromFile: Double, gains: [Double]) -> Float {
        let boost = grid.map { magnitudeDB(bandFilters(gains), at: $0) }.max() ?? 0
        return Float(min(fromFile, -max(boost, 0)).clamped(to: -12...12))
    }

    // MARK: Saving

    /// A correction kept against a device, with the name shown for it.
    struct Saved: Codable, Equatable {
        var name: String
        var correction: Correction
    }

    /// What "All sound" had before a correction went on, so it can be put back exactly when the correction comes off.
    struct Previous: Codable, Equatable {
        var eq: [Float]
        var preamp: Float
        var effectsBypassed: Bool
    }

    /// What is kept while a correction is on: the device it is for, and what to put back.
    struct Applied: Codable, Equatable {
        var uid: String
        var previous: Previous
    }

    // MARK: Following the output

    /// What to do with the equaliser when the output changes: put a device's correction on when it becomes the output, and take it
    /// off again when the output moves to a device that has none. `applied` is the device whose correction Kriya put on, if any.
    enum Plan: Equatable {
        case apply(String, Correction)
        case clear
    }

    static func plan(applied: String?, current: String?, corrections: [String: Correction]) -> Plan? {
        if let current, let correction = corrections[current] {
            return current == applied ? nil : .apply(current, correction)
        }
        return applied == nil ? nil : .clear
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
