import Foundation
import IOKit.hid

/// Reads what a device says about itself from the system's registry. Read only: nothing is opened for exclusive use, no report is sent,
/// and no device is taken from the system or from other apps.
enum DeviceCapabilityReader {
    static func info(of device: IOHIDDevice) -> HIDDeviceInfo {
        func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        var info = HIDDeviceInfo()
        info.vendorID = property(kIOHIDVendorIDKey) as? Int ?? 0
        info.productID = property(kIOHIDProductIDKey) as? Int ?? 0
        info.versionNumber = property(kIOHIDVersionNumberKey) as? Int
        info.manufacturer = (property(kIOHIDManufacturerKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        info.product = (property(kIOHIDProductKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        info.serial = (property(kIOHIDSerialNumberKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        info.transport = property(kIOHIDTransportKey) as? String
        info.locationID = property(kIOHIDLocationIDKey) as? Int
        info.reportIntervalMicroseconds = property(kIOHIDReportIntervalKey) as? Int

        guard let list = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return info }
        for element in list {
            let type = IOHIDElementGetType(element)
            // Collections group other elements and carry no input of their own.
            guard type != kIOHIDElementTypeCollection else { continue }
            info.elements.append(HIDElementInfo(
                usagePage: Int(IOHIDElementGetUsagePage(element)), usage: Int(IOHIDElementGetUsage(element)),
                logicalMin: IOHIDElementGetLogicalMin(element), logicalMax: IOHIDElementGetLogicalMax(element),
                isFeature: type == kIOHIDElementTypeFeature))
        }
        return info
    }

    /// Mach absolute time, as input values carry it, in nanoseconds.
    static func nanoseconds(fromMach ticks: UInt64) -> UInt64 {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return ticks &* UInt64(base.numer) / UInt64(max(base.denom, 1))
    }
}
