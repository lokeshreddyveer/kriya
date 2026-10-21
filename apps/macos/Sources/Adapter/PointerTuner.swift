import Foundation

// These functions belong to macOS's HID event system. They are not in the public headers, but they are exported by
// IOKit and are what lets a pointer's speed be set for one device instead of the whole Mac. Kriya is distributed outside
// the App Store, where this is allowed. If the symbols ever change, the tuner does nothing and says so in the log.
@_silgen_name("IOHIDEventSystemClientCreate")
private func hidClientCreate(_ allocator: CFAllocator?) -> OpaquePointer?

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func hidClientCopyServices(_ client: OpaquePointer?) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func hidServiceCopyProperty(_ service: OpaquePointer?, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientSetProperty")
private func hidServiceSetProperty(_ service: OpaquePointer?, _ key: CFString, _ value: CFTypeRef) -> Bool

/// Sets how fast the pointer tracks for one mouse or trackpad, and puts it back afterwards.
///
/// The value uses macOS's own scale: the "Tracking speed" slider runs 0 to 3, and -1 switches acceleration off.
/// macOS stores it as a 16.16 fixed-point number, so 1.0 is 65536.
final class PointerTuner {
    private static let mouseKey = "HIDMouseAcceleration"
    private static let trackpadKey = "HIDTrackpadAcceleration"

    private var client: OpaquePointer?
    /// What each device had before Kriya changed it, so it can be restored. Keyed by "vendor:product:property".
    private var originals: [String: Int32] = [:]
    private var changed: Set<String> = []

    private func connect() -> OpaquePointer? {
        if client == nil { client = hidClientCreate(kCFAllocatorDefault) }
        if client == nil { Log.warning("Pointer", "The HID event system is not available; pointer speed will not change") }
        return client
    }

    private func services() -> [OpaquePointer] {
        guard let client = connect(), let array = hidClientCopyServices(client)?.takeRetainedValue() else { return [] }
        return (array as [AnyObject]).map { OpaquePointer(Unmanaged.passUnretained($0).toOpaque()) }
    }

    private func number(_ service: OpaquePointer, _ key: String) -> Int? {
        (hidServiceCopyProperty(service, key as CFString)?.takeRetainedValue() as? NSNumber)?.intValue
    }

    /// Applies a tracking value to every system service that belongs to this device, or restores what it had when
    /// `value` is `nil`. Returns how many services were changed.
    @discardableResult
    func apply(vendor: Int, product: Int, trackpad: Bool, value: Double?) -> Int {
        let key = trackpad ? Self.trackpadKey : Self.mouseKey
        var touched = 0
        for service in services() {
            guard number(service, "VendorID") == vendor, number(service, "ProductID") == product,
                  let current = number(service, key) else { continue }
            let identity = "\(vendor):\(product):\(key)"
            if let value {
                if originals[identity] == nil { originals[identity] = Int32(truncatingIfNeeded: current) }
                let fixed = Int32((value * 65536).rounded())
                if hidServiceSetProperty(service, key as CFString, NSNumber(value: fixed)) {
                    changed.insert(identity)
                    touched += 1
                } else {
                    Log.warning("Pointer", "macOS refused the tracking change for a device (\(vendor):\(product))")
                }
            } else if changed.contains(identity), let original = originals[identity] {
                if hidServiceSetProperty(service, key as CFString, NSNumber(value: original)) { touched += 1 }
            }
        }
        if value == nil {
            let identity = "\(vendor):\(product):\(key)"
            changed.remove(identity)
        }
        return touched
    }

    /// Puts every device back to what it had before.
    func restoreAll() {
        guard !changed.isEmpty else { return }
        for service in services() {
            guard let vendor = number(service, "VendorID"), let product = number(service, "ProductID") else { continue }
            for key in [Self.mouseKey, Self.trackpadKey] {
                let identity = "\(vendor):\(product):\(key)"
                if changed.contains(identity), let original = originals[identity] {
                    _ = hidServiceSetProperty(service, key as CFString, NSNumber(value: original))
                }
            }
        }
        changed.removeAll()
        Log.info("Pointer", "Pointer tracking restored")
    }
}
