import CoreLocation

/// Switches the sound output when the Mac arrives at a place. Off until turned on; the position is used on this Mac to compare
/// with the places you saved and is never stored or sent.
final class LocationAudioRunner: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationAudioRunner()
    private static let key = "placeRules.v1"
    private static let enabledKey = "placeRules.enabled"

    @Published var places: [PlaceRule] { didSet { if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: Self.key) } } }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); FeatureActivity.shared.changed("locationAudio", enabled ? "Turned on" : "Turned off"); enabled ? start() : stop() }
    }
    @Published private(set) var currentPlace: String?
    @Published private(set) var problem: String?

    private let manager = CLLocationManager()
    private var started = false

    private override init() {
        places = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([PlaceRule].self, from: $0) } ?? []
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Whether place tracking is really running (not only switched on).
    var isActive: Bool { started }

    func start() {
        guard enabled, !started else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            problem = "Location Services are off on this Mac. Turn them on in System Settings › Privacy & Security › Location Services."
            return
        }
        started = true
        manager.requestWhenInUseAuthorization()
        manager.startMonitoringSignificantLocationChanges()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if authorized { manager.requestLocation() }
    }

    private var authorized: Bool { manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized }

    /// Asked once the person answers the macOS prompt, or changes it later in System Settings.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            problem = "Location is off for Kriya. Turn it on in System Settings › Privacy & Security › Location Services."
        case .authorizedAlways, .authorized:
            problem = nil
            if enabled || pending != nil { manager.requestLocation() }
        default: break
        }
    }

    func stop() {
        manager.stopMonitoringSignificantLocationChanges()
        timer?.invalidate(); timer = nil
        state = PlaceSwitchState()
        started = false
        currentPlace = nil
    }

    /// Saves where the Mac is now as a place. Needs one fresh reading.
    func addCurrentPlace(named name: String, outputs: [String]) {
        pending = (name, outputs)
        manager.requestLocation()
    }
    private var pending: (String, [String])?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let here = locations.last(where: { PlaceRules.isUsable(accuracy: $0.horizontalAccuracy, age: Date().timeIntervalSince($0.timestamp)) }) else {
            problem = "The position is too old or too rough to use yet. It will be tried again when the Mac moves."
            return
        }
        problem = nil
        if let (name, outputs) = pending {
            pending = nil
            let list = outputs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if places.count < PlaceRules.limit, let first = list.first {
                places.append(PlaceRule(name: name, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude, outputContains: first, fallbacks: Array(list.dropFirst())))
            }
        }
        guard enabled else { return }
        lastPosition = here.coordinate
        evaluate()
    }

    /// Looks at the last position again. Also run by a timer, so the dwell time can pass without a new reading.
    private func evaluate() {
        guard enabled, let here = lastPosition else { return }
        let audio = AudioControl.shared
        let current = places.first { $0.id == currentPlaceID }
        let place = PlaceRules.place(at: here.latitude, here.longitude, in: places, current: current)
        currentPlaceID = place?.id
        currentPlace = place?.name
        let ours = audio.defaultOutputUID() == chosenUID
        guard let target = PlaceSwitcher.decide(&state, place: place, now: Date(), outputIsOurs: ours) else {
            note = state.overriddenID != nil ? "You chose another output here, so Kriya will leave it until you leave." : nil
            return
        }
        note = nil
        let devices = audio.devices().filter(\.isOutput)
        for wanted in target.outputs {
            if let device = devices.first(where: { $0.name.lowercased().contains(wanted.lowercased()) }), audio.setDefault(device) {
                chosenUID = device.uid
                Toast().show("At \(target.name): sound on \(device.name)")
                FeatureActivity.shared.used("locationAudio")
                AuditLog.shared.record(.setting, "Sound output set to \(device.name) at \(target.name)")
                return
            }
        }
        // None of the outputs is connected: say so once, and try again at the next reading or when one connects.
        state.appliedID = nil
        state.lastSwitch = nil
        if !warnedAbout.contains(target.id) {
            warnedAbout.insert(target.id)
            Toast().show("At \(target.name), but none of its outputs is connected.", isError: true)
            FeatureActivity.shared.failed("locationAudio", "None of the outputs for \(target.name) was connected")
        }
    }
    private var lastPosition: CLLocationCoordinate2D?
    private var state = PlaceSwitchState()
    private var chosenUID: String?
    private var warnedAbout = Set<String>()
    private var currentPlaceID: String?
    @Published private(set) var note: String?
    private var timer: Timer?

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        problem = (error as? CLError)?.code == .denied ? "Location is off for Kriya. Turn it on in System Settings › Privacy & Security › Location Services." : "The position could not be read."
    }
}
