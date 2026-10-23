import CoreLocation

/// Switches the sound output when the Mac arrives at a place. Off until turned on; the position is used on this Mac to compare
/// with the places you saved and is never stored or sent.
final class LocationAudioRunner: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationAudioRunner()
    private static let key = "placeRules.v1"
    private static let enabledKey = "placeRules.enabled"

    @Published var places: [PlaceRule] { didSet { if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: Self.key) } } }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); enabled ? start() : stop() }
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

    func start() {
        guard enabled, !started else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            problem = "Location Services are off on this Mac. Turn them on in System Settings › Privacy & Security › Location Services."
            return
        }
        started = true
        manager.requestWhenInUseAuthorization()
        manager.startMonitoringSignificantLocationChanges()
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
        started = false
        currentPlace = nil
    }

    /// Saves where the Mac is now as a place. Needs one fresh reading.
    func addCurrentPlace(named name: String, output: String) {
        pending = (name, output)
        manager.requestLocation()
    }
    private var pending: (String, String)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let here = locations.last(where: { PlaceRules.isUsable(accuracy: $0.horizontalAccuracy, age: Date().timeIntervalSince($0.timestamp)) }) else {
            problem = "The position is too old or too rough to use yet. It will be tried again when the Mac moves."
            return
        }
        problem = nil
        if let (name, output) = pending {
            pending = nil
            if places.count < PlaceRules.limit {
                places.append(PlaceRule(name: name, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude, outputContains: output))
            }
        }
        guard enabled else { return }
        let current = places.first { $0.id == currentPlaceID }
        let place = PlaceRules.place(at: here.coordinate.latitude, here.coordinate.longitude, in: places, current: current)
        guard place?.id != currentPlaceID else { return }
        currentPlaceID = place?.id
        currentPlace = place?.name
        if let place {
            let audio = AudioControl.shared
            if let device = audio.devices().first(where: { $0.isOutput && $0.name.lowercased().contains(place.outputContains.lowercased()) }), audio.setDefault(device) {
                Toast().show("At \(place.name): sound on \(device.name)")
                AuditLog.shared.record(.setting, "Sound output set to \(device.name) at \(place.name)")
            }
        }
    }
    private var currentPlaceID: String?

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        problem = (error as? CLError)?.code == .denied ? "Location is off for Kriya. Turn it on in System Settings › Privacy & Security › Location Services." : "The position could not be read."
    }
}
