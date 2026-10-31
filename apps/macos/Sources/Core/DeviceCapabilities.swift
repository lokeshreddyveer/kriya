import Foundation

// MARK: - What a device says about itself

/// One input a device offers, as its report descriptor lists it. Only the facts needed to describe the device, never its values.
struct HIDElementInfo: Equatable {
    var usagePage: Int
    var usage: Int
    var logicalMin: Int = 0
    var logicalMax: Int = 0
    /// A feature (settable) element rather than an input.
    var isFeature = false
}

/// What the system's registry says about a device. Read once, never changed: Kriya does not open a device for exclusive use or send it
/// anything.
struct HIDDeviceInfo: Equatable {
    var vendorID: Int = 0
    var productID: Int = 0
    var versionNumber: Int?
    var manufacturer: String?
    var product: String?
    var serial: String?
    var transport: String?
    var locationID: Int?
    /// How often the device reports, if it says so, in microseconds.
    var reportIntervalMicroseconds: Int?
    var elements: [HIDElementInfo] = []

    /// A device with several interfaces (a mouse and a keyboard in one receiver) is described by all of them together.
    mutating func merge(_ other: HIDDeviceInfo) {
        elements += other.elements
        versionNumber = versionNumber ?? other.versionNumber
        manufacturer = manufacturer ?? other.manufacturer
        product = product ?? other.product
        serial = serial ?? other.serial
        transport = transport ?? other.transport
        locationID = locationID ?? other.locationID
        if let interval = other.reportIntervalMicroseconds {
            reportIntervalMicroseconds = min(reportIntervalMicroseconds ?? interval, interval)
        }
    }
}

// MARK: - What it can do

enum WheelKind: String, Equatable {
    case none
    /// A wheel that reports whole steps.
    case notched
    /// A wheel that reports fractions of a step, so it can scroll smoothly.
    case highResolution
    /// Scrolling by touch (a trackpad or a Magic Mouse surface), not a wheel.
    case touch

    var title: String {
        switch self {
        case .none: return "None"
        case .notched: return "Wheel in steps"
        case .highResolution: return "High-resolution wheel"
        case .touch: return "Touch scrolling"
        }
    }
}

struct DeviceCapabilities: Equatable {
    var vendorID: Int
    var productID: Int
    var manufacturer: String?
    var product: String?
    var serial: String?
    var transport: String?
    var versionNumber: Int?
    var locationID: Int?

    /// How many buttons it lists. The highest button it can report, which may be more than the number it lists.
    var buttonCount: Int
    var highestButton: Int
    var wheel: WheelKind
    var hasVerticalWheel: Bool
    /// A sideways wheel or a tilting wheel: the input that scrolls left and right.
    var hasTilt: Bool
    var isTouch: Bool
    /// How often it says it reports, in hertz. Nil when it does not say; the measured rate is separate.
    var declaredRateHz: Int?

    /// "046D:C52B", the way vendors and the system write it.
    var idText: String { String(format: "%04X:%04X", vendorID, productID) }
}

enum DeviceCapabilityAnalyzer {
    static let buttonPage = 0x09
    static let desktopPage = 0x01
    static let consumerPage = 0x0C
    static let digitizerPage = 0x0D
    static let wheelUsage = 0x38
    static let resolutionMultiplierUsage = 0x48
    static let acPanUsage = 0x238

    static func analyze(_ info: HIDDeviceInfo) -> DeviceCapabilities {
        let inputs = info.elements.filter { !$0.isFeature }
        let buttons = Set(inputs.filter { $0.usagePage == buttonPage && $0.usage > 0 }.map(\.usage))
        let vertical = inputs.contains { $0.usagePage == desktopPage && $0.usage == wheelUsage }
        let pan = inputs.contains { $0.usagePage == consumerPage && $0.usage == acPanUsage }
        // A report that can say "half a step" has a resolution multiplier the device is told to use.
        let fine = info.elements.contains { $0.usagePage == desktopPage && $0.usage == resolutionMultiplierUsage }
        let touch = info.elements.contains { $0.usagePage == digitizerPage }

        let wheel: WheelKind
        if touch && !vertical { wheel = .touch }
        else if vertical && fine { wheel = .highResolution }
        else if vertical { wheel = .notched }
        else if touch { wheel = .touch }
        else { wheel = .none }

        return DeviceCapabilities(
            vendorID: info.vendorID, productID: info.productID, manufacturer: info.manufacturer, product: info.product,
            serial: info.serial, transport: info.transport, versionNumber: info.versionNumber, locationID: info.locationID,
            buttonCount: buttons.count, highestButton: buttons.max() ?? 0, wheel: wheel,
            hasVerticalWheel: vertical, hasTilt: pan, isTouch: touch,
            declaredRateHz: info.reportIntervalMicroseconds.flatMap { $0 > 0 ? Int((1_000_000.0 / Double($0)).rounded()) : nil }
        )
    }
}

// MARK: - Polling rate

/// Works out how often a mouse reports, from when its reports arrived. Done only on request, for one device, for a few seconds.
struct PollingRateEstimator {
    /// The rates mice are sold at. A measured rate close to one of them is shown as it.
    static let commonRates = [60, 100, 125, 250, 500, 1000, 2000, 4000, 8000]
    static let minimumSamples = 40
    /// A gap longer than this is the mouse at rest, not its rate.
    static let longestGapMs = 50.0

    private var times: [UInt64] = []

    mutating func record(nanoseconds: UInt64) { times.append(nanoseconds) }

    var sampleCount: Int { times.count }

    /// The rate in hertz, or nil when there was not enough movement to tell. Uses the middle of the gaps between reports, so a few late
    /// ones do not pull it down.
    func estimate() -> Int? {
        guard times.count >= Self.minimumSamples else { return nil }
        let sorted = times.sorted()
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let ms = Double(sorted[i] - sorted[i - 1]) / 1_000_000
            // Reports in the same instant are one report split in two, and long gaps are rest.
            if ms >= 0.05, ms <= Self.longestGapMs { gaps.append(ms) }
        }
        guard gaps.count >= Self.minimumSamples / 2 else { return nil }
        gaps.sort()
        let median = gaps[gaps.count / 2]
        let hz = 1000 / median
        return Self.snapped(hz)
    }

    /// The common rate within 12% of this one, or this one rounded.
    static func snapped(_ hz: Double) -> Int {
        guard hz.isFinite, hz > 0 else { return 0 }
        if let near = commonRates.first(where: { abs(hz - Double($0)) / Double($0) <= 0.12 }) { return near }
        return Int(hz.rounded())
    }
}
