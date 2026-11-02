import Foundation
import IOKit

/// The Mac the release check runs on (1.3.0): no interruptive device
/// command ever goes to it, whatever the allow-list says.
enum ThisMac {
    /// Its serial number, uppercased; nil when it can’t be read, and then
    /// no interruptive command is sent at all. Never logged or reported.
    static let serialNumber: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        let serial = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return serial?.isEmpty == false ? serial : nil
    }()
}
