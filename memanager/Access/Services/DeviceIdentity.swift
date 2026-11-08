import Foundation
import IOKit

/// Stable identifier of the Mac the app runs on, used to bind an owner
/// license to one machine.
protocol DeviceIdentifying {
    func deviceID() -> String?
}

/// IOPlatformUUID from the IORegistry, the same value `ioreg -rd1 -c
/// IOPlatformExpertDevice` prints and the signing tool reads.
struct IOKitDeviceIdentity: DeviceIdentifying {
    static let platformUUIDKey = "IOPlatformUUID"

    func deviceID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, IOKitDeviceIdentity.platformUUIDKey as CFString, kCFAllocatorDefault, 0),
              let value = property.takeRetainedValue() as? String, !value.isEmpty else {
            return nil
        }
        return OwnerLicenseVerifier.normalizedDeviceID(value)
    }
}

/// Test double with a chosen identifier (or none, to model a read failure).
struct FixedDeviceIdentity: DeviceIdentifying {
    let id: String?

    func deviceID() -> String? { id }
}
